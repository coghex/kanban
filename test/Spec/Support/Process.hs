-- | Managed process, worker and review client harnesses.
module Spec.Support.Process
  ( withSurvivingGroupLeader,
    withVacatedGroupLeader,
    withNonLeaderProcess,
    withManagedShell,
    managedProcessFor,
    detachedEscapedDescendantCommand,
    withNonLeaderShell,
    processIdentity,
    identityForProcess,
    runningWorkerState,
    isDiagnosticEvent,
    isWorkerFailedEvent,
    chattyProviderLines,
    chattyProvider,
    runChattyWorker,
    assertBoundedWorkerSurfaces,
    admitTelemetry,
    rawTelemetryLines,
    singleNotice,
    aggregatedNotices,
    isSolveSessionIdentifiedEvent,
    isSolveOutputEvent,
    isPullRequestSessionIdentifiedEvent,
    isPullRequestFlowOutputEvent,
    workerFixtureSpec,
    workerFixtureAssignment,
    deadlineFixtureSpec,
    waitForWorkerState,
    isOrphaned,
    isTerminal,
    withRecordingReviewClient,
    withRecordingReviewClientUsing,
    withTwoConnectionReviewClient,
    TwoConnectionClient (..),
    withFakeReviewClient,
    soleReviewConnection,
    threadOn,
    readRecordedPids,
    shouldHaveBeenSwept,
    nextClientRequest,
    nextClientLine,
    twoConnectionsOf,
    waitForConnectionStops,
    turnCompletions,
    startFailures,
    expectNoFurtherClientRequests,
    encodedValue,
    undeliveredSteers,
    protocolWarnings,
    plainChatTranscript,
    withFakeGitHubCli,
    runBoundedGitHubTool,
    withFakeClaudeCli,
    withFakeClaudeCliUsing,
    runBoundedClaudeCall,
    shouldRecordASweptProcess,
    shouldNotHaveSwept,
    readRecordedPid,
    withFakeCanonicalReviewer,
    runBoundedCanonicalCommand,
    canonicalSessionLogText,
    fakeController,
    fakeApprovalController
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, throwIO, try)
import Control.Monad (void)
import Data.Aeson (Value (..), eitherDecode, encode)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.IORef (IORef, modifyIORef, newIORef, readIORef)
import Data.List (dropWhileEnd, find, findIndex, findIndices)
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time (UTCTime (..))
import Kanban.Domain
import Kanban.ApprovalService (ApprovalBackend (..), ApprovalController (..))
import Kanban.Drainer (DrainerBackend (..), DrainerController (..))
import Kanban.Process
  ( ManagedProcess,
    ProcessIdentity (..),
    identityForPid,
    killManagedProcess,
    managedProcess,
    readProcessSnapshot
  )
import Kanban.Models (ModelRoster, RecordedAssignment, defaultRoster)
import Kanban.PullRequestFlow (PullRequestFlowEvent (..))
import Kanban.Review
  ( CommandBounds (..),
    ConnectionId,
    EmbeddedReviewBackend (..),
    GitHubIssueToolRequest (..),
    ReviewClient,
    ReviewConnection (..),
    ReviewEvent (..),
    ReviewProcessShape,
    ReviewThreadId (..),
    ReviewWireMessage (..),
    addRecordingReviewConnectionForTesting,
    connectionId,
    decodeReviewWireMessage,
    newRecordingReviewClientForTesting,
    newReviewClientForTesting,
    reviewConnectionsForTesting,
    runAuthenticatedClaude,
    startResolvedReviewClient,
    runCanonicalCommand,
    runGitHubIssueTool,
    stopReviewClient,
    withReservedToolSlot
  )
import Kanban.Solve
  ( AgentEvent (..),
    ResumeProvenance (..),
    SolveEvent (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    StreamEvent (..),
    UnknownAggregator,
    emitStreamEvent,
    sealUnknownAggregates,
    maxUnknownNoticeLength,
    newUnknownAggregator,
    parseSolveOutputLine,
    solveAssignment,
    unknownNoticeSamples
  )
import Kanban.UI.Types (ChatTranscript (..))
import Kanban.Worker
  ( SolveWorkerTask (..),
    WorkerEvent (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
    discoverWorkerHistory,
    monitorWorker,
    runWorker
  )
import Spec.Support.Env (ignoringIOException, withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Expect (requireJust)
import Spec.Support.Fixtures (epoch, fixtureReviewThread)
import Spec.Support.Roster (cellOf)
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (Handle, hClose)
import System.Posix.Files (setFileMode)
import System.Posix.Signals (sigKILL, signalProcess, signalProcessGroup)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    getPid,
    proc,
    terminateProcess,
    waitForProcess
  )
import System.Timeout (timeout)
import Test.Hspec
import Text.Read (readMaybe)

-- | A TERM-ignoring process leading its own group, handed to the action by
-- PID. Its standard streams go to @\/dev\/null@ and the group is force-killed
-- on the way out whatever the action did, so a failing assertion can never
-- leave a survivor holding the test runner's pipes open — the exact stray
-- fixture the code under test exists to prevent.
withSurvivingGroupLeader :: (Int -> IO result) -> IO result
withSurvivingGroupLeader =
  bracket spawn (\(leaderPid, _) -> ignoringIOException (signalProcessGroup sigKILL (fromIntegral leaderPid)))
    . (. fst)
  where
    spawn = do
      (_, _, _, leader) <-
        createProcess
          (proc "sh" ["-c", "trap '' TERM; while :; do sleep 1; done </dev/null >/dev/null 2>&1"])
            {create_group = True}
      leaderPid <- maybe (fail "surviving fixture reported no PID") (pure . fromIntegral) =<< getPid leader
      threadDelay 200000
      pure (leaderPid :: Int, leader)

-- | A process group id nothing occupies, established rather than guessed.
--
-- A record entry naming a group that is genuinely empty is the only shape in
-- which reclaim /clears/ rather than refuses, and picking a number and hoping
-- would make every example resting on that a coin toss. So a real group leader
-- is started, killed, and — crucially — reaped, because a zombie still holds
-- its PID and still appears in @ps@; the group is then confirmed empty from a
-- fresh census before the number is handed on.
withVacatedGroupLeader :: (Int -> IO result) -> IO result
withVacatedGroupLeader action = do
  (_, _, _, leader) <-
    createProcess (proc "sh" ["-c", "exec sleep 30"]) {create_group = True}
  leaderPid <- maybe (fail "vacated fixture reported no PID") (pure . fromIntegral) =<< getPid leader
  terminateProcess leader
  void (timeout 5000000 (waitForProcess leader))
  awaitVacated (leaderPid :: Int) (50 :: Int)
  action leaderPid
  where
    awaitVacated groupPid remaining = do
      snapshot <- readProcessSnapshot
      case snapshot of
        Left message -> fail ("could not snapshot processes: " <> Data.Text.unpack message)
        Right identities
          | not (any ((== groupPid) . processIdentityGroupPid) identities),
            Nothing <- identityForPid groupPid identities ->
              pure ()
          | remaining <= 0 -> fail ("process group " <> show groupPid <> " never emptied")
          | otherwise -> threadDelay 100000 >> awaitVacated groupPid (remaining - 1)

-- | Like 'withSurvivingGroupLeader', but deliberately /not/ its own group
-- leader — it stays in this test process's group — so its PID and its PGID
-- differ. That is the shape @create_group@ failing to take effect would
-- leave behind, and the only one where asking about a PGID says nothing
-- about the process itself.
withNonLeaderProcess :: (Int -> IO result) -> IO result
withNonLeaderProcess =
  bracket spawn (\(pid, _) -> ignoringIOException (signalProcess sigKILL (fromIntegral pid)))
    . (. fst)
  where
    spawn = do
      (_, _, _, child) <-
        createProcess
          (proc "sh" ["-c", "trap '' TERM; while :; do sleep 1; done </dev/null >/dev/null 2>&1"])
            {create_group = False}
      childPid <- maybe (fail "non-leader fixture reported no PID") (pure . fromIntegral) =<< getPid child
      threadDelay 200000
      pure (childPid :: Int, child)

-- | The bystander half of a sweep assertion.
--
-- A census, a group sweep or a "leaves no survivor" check is entitled to take
-- exactly what it recorded and nothing else, and a snapshot showing its own
-- fixtures gone says nothing about the second half of that. So the examples
-- that make one run it beside a 'withSurvivingGroupLeader' process nothing
-- under test ever recorded — the same TERM-ignoring shape, in a group of its
-- own — and read this from the very snapshot the emptiness was read from. A
-- sweep that matched on what a process /looks/ like, or that reached past the
-- identities it owns, takes the bystander with the rest and fails here.
--
-- It is deliberately asked of a snapshot rather than of the live process: a
-- swept bystander is a zombie until this process reaps it, and a zombie is
-- absent from a snapshot for exactly the reason a killed process is.
shouldNotHaveSwept :: [ProcessIdentity] -> Int -> Expectation
shouldNotHaveSwept snapshot bystander = case identityForPid bystander snapshot of
  Just _ -> pure ()
  Nothing ->
    expectationFailure
      ( "the sweep also took process "
          <> show bystander
          <> ", which nothing under test had recorded"
      )

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

-- | How many occurrences of the unrecognized @telemetry@ type
-- 'chattyProvider' streams. Comfortably past 'unknownNoticeSamples', so a
-- run proves collapsing rather than merely staying under the sample budget.
chattyProviderLines :: Int
chattyProviderLines = 40

-- | A fake provider that streams 'chattyProviderLines' occurrences of one
-- unrecognized event type, each with a payload far larger than a bounded
-- notice, then a recognized agent message. @tailCommands@ can keep it alive
-- afterwards so a test can interrupt it deterministically once that
-- recognized sentinel proves every telemetry line has been read.
chattyProvider :: ByteString.ByteString -> ByteString.ByteString -> [ByteString.ByteString] -> ByteString.ByteString
chattyProvider sessionId sentinel tailCommands =
  ByteString.unlines
    ( [ "#!/bin/sh",
        "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"" <> sessionId <> "\"}'",
        "i=0",
        "while [ $i -lt " <> ByteString.pack (show chattyProviderLines) <> " ]; do",
        "  printf '{\"type\":\"telemetry\",\"tick\":%s,\"blob\":\"" <> ByteString.pack (replicate 400 'x') <> "\"}\\n' \"$i\"",
        "  i=$((i + 1))",
        "done",
        "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"" <> sentinel <> "\"}}'"
      ]
        <> tailCommands
    )

-- | Drives a real worker — the real supervisor, the real solve or PR flow,
-- and a real provider process — over a 'chattyProvider' run, then reports
-- the three surfaces the bound has to hold on: the durable worker journal,
-- what a replay of that journal delivers, and how many raw provider lines
-- the session log kept. Collecting sinks would prove none of these; only
-- 'appendWorkerEvent' and 'monitorWorker' running for real do.
runChattyWorker :: FilePath -> WorkerSpec -> String -> IO ([ByteString.ByteString], [AgentEvent], Int)
runChattyWorker temporaryRoot spec identifier = do
  let repository = spec.workerRepository
      binaryRoot = temporaryRoot </> "bin"
      fakeCodex = binaryRoot </> "codex"
      workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
      specPath = workerRoot </> identifier <> ".spec.json"
      statePath = workerRoot </> identifier <> ".state.json"
      eventPath = workerRoot </> identifier <> ".events.jsonl"
  createDirectory repository.repositoryRoot
  createDirectory binaryRoot
  createDirectoryIfMissing True workerRoot
  ByteString.writeFile fakeCodex (chattyProvider "chatty-worker-session" "Created PR #999" [])
  setFileMode fakeCodex 0o700
  LazyByteString.writeFile specPath (encode spec)
  originalPath <- maybe "" id <$> lookupEnv "PATH"
  withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
    withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
      runWorker specPath `shouldReturn` Right ()
      journal <- ByteString.lines <$> ByteString.readFile eventPath
      replayed <- newIORef []
      descriptors <- discoverWorkerHistory repository
      case find ((== spec.workerId) . (.workerId) . (.workerDescriptorSpec)) descriptors of
        Nothing -> throwIO (userError "worker was not discoverable for replay")
        Just descriptor -> void (timeout 15000000 (monitorWorker descriptor (\_ _ event -> modifyIORef replayed (event :))))
      replayedEvents <- reverse <$> readIORef replayed
      stateBytes <- LazyByteString.readFile statePath
      logPath <- case eitherDecode stateBytes :: Either String WorkerState of
        Right state -> requireJust "worker state recorded no session log path" state.workerStateLogPath
        Left message -> throwIO (userError ("undecodable worker state: " <> message))
      rawCount <- rawTelemetryLines [logPath]
      pure (journal, [agentEvent | WorkerAgentOutput agentEvent <- replayedEvents], rawCount)

-- | The bound, asserted on all three of a real worker's surfaces at once:
-- the journal holds only the samples and one summary, ordered before the
-- terminal envelope; replay delivers exactly those same bounded notices; and
-- the session log still holds every raw provider line.
assertBoundedWorkerSurfaces :: ([ByteString.ByteString], [AgentEvent], Int) -> IO ()
assertBoundedWorkerSurfaces (journal, replayedOutputs, rawCount) = do
  let noticeIndices = findIndices (ByteString.isInfixOf "[event] telemetry") journal
      terminalIndex = findIndex (ByteString.isInfixOf "WorkerFinished") journal
  length noticeIndices `shouldBe` unknownNoticeSamples + 1
  case (reverse noticeIndices, terminalIndex) of
    (lastNotice : _, Just terminal) -> lastNotice `shouldSatisfy` (< terminal)
    _ -> expectationFailure "expected bounded notices and a terminal envelope in the worker journal"
  let replayedNotices = [agentEvent.agentEventSummary | agentEvent <- replayedOutputs, Data.Text.isPrefixOf "[event] telemetry" agentEvent.agentEventSummary]
  length replayedNotices `shouldBe` unknownNoticeSamples + 1
  replayedNotices `shouldSatisfy` all ((<= maxUnknownNoticeLength) . Data.Text.length)
  last replayedNotices `shouldBe` "[event] telemetry ×" <> Data.Text.pack (show chattyProviderLines)
  rawCount `shouldBe` chattyProviderLines

-- | Pushes @count@ occurrences of one unrecognized event type through a
-- supervisor's shared aggregator, emitting whatever it admits — the stream
-- loop's half of the deadline tests, without needing a real provider whose
-- output would race the deadline unpredictably.
admitTelemetry :: UnknownAggregator -> (WorkerEvent -> IO ()) -> Int -> IO ()
admitTelemetry aggregator emit count = mapM_ (const admitOne) [1 .. count]
  where
    admitOne = case parseSolveOutputLine "{\"type\":\"telemetry\",\"tick\":1}" of
      Left message -> throwIO (userError ("unparsable fixture line: " <> Data.Text.unpack message))
      Right (_, streamEvents) -> mapM_ (emitStreamEvent aggregator (emit . WorkerAgentOutput)) streamEvents

-- | How many raw stdout records a 'chattyProvider' run left in its session
-- log, given the log paths the invocation reported opening. The §16 contract
-- is that this stays at full fidelity no matter how aggressively the parsed
-- notices are bounded and collapsed.
rawTelemetryLines :: [FilePath] -> IO Int
rawTelemetryLines [path] = do
  contents <- ByteString.readFile path
  pure (length (filter (ByteString.isInfixOf "\\\"telemetry\\\"") (ByteString.lines contents)))
rawTelemetryLines paths = throwIO (userError ("expected exactly one opened session log, got " <> show paths))

-- | The single agent event one provider line parses into. Anything else is
-- a broken fixture rather than an assertion worth reporting, so it aborts
-- the example with the shape actually produced.
singleNotice :: ByteString.ByteString -> IO AgentEvent
singleNotice line = case parseSolveOutputLine line of
  Right (_, [streamEvent]) -> pure streamEvent.streamEventAgent
  result -> throwIO (userError ("expected exactly one parsed event from " <> show line <> ", got " <> show result))

-- | Runs provider lines through one invocation's unknown-payload aggregator
-- and returns the notice summaries that invocation would journal: the events
-- it admitted, in order, followed by the aggregate summaries it flushes
-- before its terminal event. This is the pure-side stand-in for a full
-- provider run, so aggregation boundaries can be asserted without spawning
-- hundreds of lines through a real process.
aggregatedNotices :: [String] -> IO [Text]
aggregatedNotices providerLines = do
  aggregator <- newUnknownAggregator
  admitted <- concat <$> traverse (admitLine aggregator) providerLines
  summaries <- newIORef []
  sealUnknownAggregates aggregator (\agentEvent -> modifyIORef summaries (agentEvent :))
  flushed <- reverse <$> readIORef summaries
  pure (map (.agentEventSummary) (admitted <> flushed))
  where
    admitLine aggregator line = case parseSolveOutputLine (ByteString.pack line) of
      Left message -> throwIO (userError ("unparsable fixture line " <> line <> ": " <> Data.Text.unpack message))
      Right (_, events) -> do
        admitted <- newIORef []
        mapM_ (emitStreamEvent aggregator (\agentEvent -> modifyIORef admitted (agentEvent :))) events
        reverse <$> readIORef admitted

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

-- | The cell every hand-built fixture spec records: the compiled default
-- for the solve task 'workerFixtureSpec' carries. A supervisor takes its
-- assignment from the specification it is handed and resolves nothing of its
-- own, so a fixture that writes the spec by hand has to record one or the
-- run refuses before it spawns.
workerFixtureAssignment :: RecordedAssignment
workerFixtureAssignment = cellOf (solveAssignment defaultRoster CodexSolver)

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
      workerWorkflowConfig = defaultWorkflowConfig,
      workerAssignment = Just workerFixtureAssignment
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

-- | A review client whose app-server stdin is a pipe this test reads, plus
-- the events its sink recorded in order, so a response driven in through
-- 'handleWireMessage' can be judged by both what it writes back and what it
-- tells the session (issue #17).
withRecordingReviewClient :: (ReviewClient -> Handle -> IORef [ReviewEvent] -> IO result) -> IO result
withRecordingReviewClient = withRecordingReviewClientUsing defaultRoster

-- | As 'withRecordingReviewClient', but against a chosen roster, so a test
-- can prove a non-default cell reaches the wire payloads the review thread
-- constructs.
withRecordingReviewClientUsing :: ModelRoster -> (ReviewClient -> Handle -> IORef [ReviewEvent] -> IO result) -> IO result
withRecordingReviewClientUsing roster action = do
  events <- newIORef []
  bracket
    (newRecordingReviewClientForTesting roster (\event -> modifyIORef events (<> [event])))
    (\(client, wire) -> stopReviewClient client >> hClose wire)
    (\(client, wire) -> action client wire events)

-- | The one connection a testing review client holds.
--
-- A wire message is dispatched against the connection it arrived on, so a
-- test that drives one needs that connection; the single-connection fixtures
-- have exactly one, and this says so out loud rather than picking whichever
-- the pool lists first.
soleReviewConnection :: ReviewClient -> IO ReviewConnection
soleReviewConnection client = do
  connections <- reviewConnectionsForTesting client
  case connections of
    [connection] -> pure connection
    other -> fail ("expected the testing review client to hold exactly one connection, it held " <> show (length other))

-- | A review thread on a live fixture connection: the provider's own id
-- paired with the connection serving it, which is the only identity a review
-- map is keyed by.
threadOn :: ReviewConnection -> Text -> ReviewThreadId
threadOn connection = ReviewThreadId (connectionId connection)

-- | A review client holding two independent recording connections.
--
-- What it makes observable is everything a single-connection client could
-- not express: the same provider thread id, or the same server-request id,
-- arriving on both must reach two separate sets of state, and an answer must
-- go back only to the connection that asked.
data TwoConnectionClient = TwoConnectionClient
  { twoConnectionClient :: ReviewClient,
    firstConnection :: ReviewConnection,
    firstWire :: Handle,
    secondConnection :: ReviewConnection,
    secondWire :: Handle,
    twoConnectionEvents :: IORef [ReviewEvent]
  }

withTwoConnectionReviewClient :: (TwoConnectionClient -> IO result) -> IO result
withTwoConnectionReviewClient action = do
  events <- newIORef []
  bracket
    ( do
        (client, firstHandle) <- newRecordingReviewClientForTesting defaultRoster (\event -> modifyIORef events (<> [event]))
        first <- soleReviewConnection client
        (second, secondHandle) <- addRecordingReviewConnectionForTesting client
        pure (TwoConnectionClient client first firstHandle second secondHandle events)
    )
    (\fixture -> stopReviewClient fixture.twoConnectionClient >> hClose fixture.firstWire >> hClose fixture.secondWire)
    action

-- | A backend whose provider is a fake executable on disk: it records its own
-- pid, answers the initialize handshake the client waits for, and then drains
-- its stdin until the client closes it.
--
-- Deliberately no further protocol. What a test built on this is about is
-- connection /shape/ — how many processes two reviews occupy, which
-- connection a response resolves against, and whether shutdown reaps every
-- one — and a fake that also spoke the thread and turn protocol would answer
-- those questions no better while being able to get them wrong.
withFakeReviewBackend :: ReviewProcessShape -> (FilePath -> Repository -> EmbeddedReviewBackend -> IO result) -> IO result
withFakeReviewBackend processShape action =
  withTemporaryCacheRoot $ \temporaryRoot -> do
    let repositoryRoot = temporaryRoot </> "repo"
        spawnLog = temporaryRoot </> "spawned-pids"
        fakeProvider = temporaryRoot </> "fake-app-server"
    createDirectory repositoryRoot
    ByteString.writeFile
      fakeProvider
      ( ByteString.unlines
          [ "#!/bin/sh",
            "echo \"$$\" >> \"" <> ByteString.pack spawnLog <> "\"",
            "printf '%s\\n' '{\"id\":1,\"result\":{}}'",
            -- Draining stdin is what keeps a client that writes a large
            -- 'thread/start' from blocking on a full pipe, and reaching EOF
            -- on it is how this exits when the client closes that end.
            "cat >/dev/null"
          ]
      )
    setFileMode fakeProvider 0o700
    withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
      action
        spawnLog
        (Repository repositoryRoot "coghex" "kanban")
        EmbeddedReviewBackend
          { backendLabel = "fake app-server",
            backendProcessShape = processShape,
            backendProcess = \root ->
              (proc fakeProvider [])
                { cwd = Just root,
                  std_in = CreatePipe,
                  std_out = CreatePipe,
                  std_err = CreatePipe,
                  create_group = True
                }
          }

-- | A live review client on that fake backend, plus the pid log its provider
-- writes to and the events its sink recorded in order.
--
-- Shutdown is bracketed even though several of these tests call it
-- themselves and assert on what it left: it is idempotent, and a failed
-- assertion partway through must not leave fake providers running.
withFakeReviewClient :: ReviewProcessShape -> (FilePath -> ReviewClient -> IORef [ReviewEvent] -> IO result) -> IO result
withFakeReviewClient processShape action =
  withFakeReviewBackend processShape $ \spawnLog repository backend -> do
    events <- newIORef []
    bracket
      (startFakeReviewClient backend repository (\event -> modifyIORef events (<> [event])))
      stopReviewClient
      (\client -> action spawnLog client events)

startFakeReviewClient :: EmbeddedReviewBackend -> Repository -> (ReviewEvent -> IO ()) -> IO ReviewClient
startFakeReviewClient backend repository eventSink = do
  started <- startResolvedReviewClient backend defaultRoster defaultWorkflowConfig repository eventSink
  case started of
    Right client -> pure client
    Left message -> fail ("the fake review backend did not start: " <> Data.Text.unpack message)

-- | Every pid a fake provider recorded, in spawn order. An absent log is no
-- spawn rather than an error, so a test may assert on both.
readRecordedPids :: FilePath -> IO [Int]
readRecordedPids path = do
  exists <- doesFileExist path
  if not exists
    then pure []
    else do
      written <- readFile path
      mapM (\line -> requireJust ("a fake provider recorded an unreadable pid in " <> path) (readMaybe line)) (lines written)

-- | Asserts a recorded process is gone. A killed process is already absent
-- from this snapshot even before its parent reaps it, so no wait is needed.
shouldHaveBeenSwept :: Int -> String -> Expectation
shouldHaveBeenSwept pid description = do
  snapshot <- readProcessSnapshot
  case snapshot of
    Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
    Right identities ->
      case identityForPid pid identities of
        Nothing -> pure ()
        Just _ -> expectationFailure ("expected " <> description <> " (pid " <> show pid <> ") to have been terminated")

-- | The next request the client wrote to its app-server, as method and
-- params. Bounded so a missing write fails the test instead of hanging it.
nextClientRequest :: Handle -> IO (Text, Value)
nextClientRequest wire = do
  line <- requireJust "the client wrote no request to its app-server" =<< timeout 2000000 (ByteString.hGetLine wire)
  case decodeReviewWireMessage (LazyByteString.fromStrict line) of
    Right (WireRequest _ method params) -> pure (method, params)
    other -> fail ("expected a client request on the wire, got " <> show other)

-- | The next line the client wrote to one connection, raw.
--
-- A response to a server-originated request is asserted this way rather than
-- decoded: what these tests are about is which pipe carried it, and a raw
-- line cannot be read off the wrong one by a decoder that happens to accept
-- both.
nextClientLine :: Handle -> IO Text
nextClientLine wire = do
  line <- requireJust "the client wrote nothing to this connection" =<< timeout 2000000 (ByteString.hGetLine wire)
  pure (TextEncoding.decodeUtf8 line)

-- | Every write happens synchronously inside the handler under test, so by
-- the time it returns the pipe holds everything it is ever going to hold;
-- this waits a further moment only to keep the assertion honest under load.
expectNoFurtherClientRequests :: Handle -> IO ()
expectNoFurtherClientRequests wire = do
  extra <- timeout 200000 (ByteString.hGetLine wire)
  case extra of
    Nothing -> pure ()
    Just line -> expectationFailure ("expected no further app-server traffic, got " <> show line)

encodedValue :: Value -> Text
encodedValue = Data.Text.pack . LazyByteString.unpack . encode

-- | The two connections a client holds, in the order the pool allocated
-- them, so a test can name "the first review's" and "the second review's"
-- rather than whichever comes back first.
twoConnectionsOf :: ReviewClient -> IO (ReviewConnection, ReviewConnection)
twoConnectionsOf client = do
  connections <- reviewConnectionsForTesting client
  case connections of
    [first, second] -> pure (first, second)
    other -> fail ("expected the review client to hold two connections, it held " <> show (length other))

-- | Wait until at least @wanted@ connections have been reported as stopped,
-- returning every such report so far. Bounded so a report that never arrives
-- fails the test instead of hanging it.
waitForConnectionStops :: IORef [ReviewEvent] -> Int -> IO [(ConnectionId, Text)]
waitForConnectionStops events wanted = go (200 :: Int)
  where
    go remaining = do
      stops <- connectionStops <$> readIORef events
      if length stops >= wanted
        then pure stops
        else
          if remaining <= 0
            then fail ("expected " <> show wanted <> " connection stop report(s), saw " <> show (length stops))
            else threadDelay 25000 >> go (remaining - 1)
    connectionStops recorded = [(connection, message) | ReviewConnectionStopped connection message <- recorded]

-- | Every review reported as having failed to start, as issue number and
-- message.
startFailures :: [ReviewEvent] -> [(Int, Text)]
startFailures recorded = [(issueNumber, message) | ReviewStartFailed issueNumber message <- recorded]

turnCompletions :: [ReviewEvent] -> [ReviewEvent]
turnCompletions = filter isCompletion
  where
    isCompletion ReviewTurnCompleted {} = True
    isCompletion _ = False

undeliveredSteers :: [ReviewEvent] -> [ReviewEvent]
undeliveredSteers = filter isUndelivered
  where
    isUndelivered ReviewSteerUndelivered {} = True
    isUndelivered _ = False

protocolWarnings :: [ReviewEvent] -> [ReviewEvent]
protocolWarnings = filter isWarning
  where
    isWarning ReviewProtocolWarning {} = True
    isWarning _ = False

plainChatTranscript :: Text -> ChatTranscript
plainChatTranscript value = ChatTranscript value value value

-- | A 'DrainerController' pointing at a shell script, so the invocation path
-- can be driven with a chosen exit code, streams, and staying power. The
-- controller's own arguments are dropped on the floor by the script; what is
-- under test is how the invocation reads what comes back, not the wire.
fakeController :: FilePath -> [ByteString.ByteString] -> IO DrainerController
fakeController temporaryRoot scriptLines = do
  let scriptPath = temporaryRoot </> "drain-prs-controller"
  ByteString.writeFile scriptPath (ByteString.unlines ("#!/bin/sh" : scriptLines))
  setFileMode scriptPath 0o700
  pure (DrainerController scriptPath [] DrainerLaunchd)

-- | The same fixture for the issue approval service, written to its own file
-- so a test may stand one of each up in one temporary directory without either
-- overwriting the other.
fakeApprovalController :: FilePath -> [ByteString.ByteString] -> IO ApprovalController
fakeApprovalController temporaryRoot scriptLines = do
  let scriptPath = temporaryRoot </> "approve-issues-controller"
  ByteString.writeFile scriptPath (ByteString.unlines ("#!/bin/sh" : scriptLines))
  setFileMode scriptPath 0o700
  pure (ApprovalController scriptPath [] ApprovalLaunchd)

-- | The PID a fixture recorded for itself. Read only after the invocation
-- under test has returned, by which point the shell has long since written
-- it.
readRecordedPid :: FilePath -> IO Int
readRecordedPid path = do
  written <- readFile path
  requireJust ("fixture never recorded a PID in " <> path) (readMaybe (dropWhileEnd (== '\n') written))

-- | A fake @gh@ on a temporary PATH plus a review client wired to the given
-- 'CommandBounds', so the deadline and capture-grace paths are reachable
-- without waiting out the production 30 s.
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
        (newReviewClientForTesting defaultRoster bounds repositoryRoot "coghex/kanban" (const (pure ())))
        stopReviewClient
        action

runBoundedGitHubTool :: Int -> ReviewClient -> GitHubIssueToolRequest -> IO (Either Text Text)
runBoundedGitHubTool boundMicros client request = do
  outcome <- timeout boundMicros (withReservedToolSlot client (fixtureReviewThread "thread-1") (\key -> runGitHubIssueTool client key request))
  requireJust "the GitHub tool call did not return within its bounded window" outcome

-- | A fake @claude@ on a temporary PATH plus a review client whose Claude
-- bounds are the given ones, so 'runAuthenticatedClaude''s deadline and
-- capture-grace paths are reachable without waiting out the production ten
-- minutes. The action is handed @$CLAUDE_CHILD_MARKER@ -- the
-- path the script is expected to record a PID at when the test needs to see
-- that the spawned process group was swept.
withFakeClaudeCli :: [ByteString.ByteString] -> CommandBounds -> (FilePath -> ReviewClient -> IO result) -> IO result
withFakeClaudeCli = withFakeClaudeCliUsing defaultRoster

-- | As 'withFakeClaudeCli', but against a chosen roster, so a test can prove
-- a non-default @issue_revise.claude@ cell reaches the argv the tool spawns.
withFakeClaudeCliUsing :: ModelRoster -> [ByteString.ByteString] -> CommandBounds -> (FilePath -> ReviewClient -> IO result) -> IO result
withFakeClaudeCliUsing roster scriptLines bounds action =
  withTemporaryCacheRoot $ \temporaryRoot -> do
    let repositoryRoot = temporaryRoot </> "repo"
        binaryRoot = temporaryRoot </> "bin"
        fakeClaude = binaryRoot </> "claude"
        markerPath = temporaryRoot </> "claude-child.pid"
    createDirectory repositoryRoot
    createDirectory binaryRoot
    -- Drain stdin first, as the real `claude --print` does.
    -- 'runAuthenticatedClaude' always writes the prompt and closes its end,
    -- so a fake that exited without reading would leave that write to fail
    -- with EPIPE at the flush -- a fixture artifact that says nothing about
    -- the capture bounds under test, and one whose timing differs by
    -- platform. Same reason as 'withFakeGitHubCli' above.
    ByteString.writeFile fakeClaude (ByteString.unlines ("#!/bin/sh" : "cat >/dev/null" : scriptLines))
    setFileMode fakeClaude 0o700
    originalPath <- maybe "" id <$> lookupEnv "PATH"
    withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $
      withEnvironmentValue "CLAUDE_CHILD_MARKER" markerPath $
        bracket
          (newReviewClientForTesting roster bounds repositoryRoot "coghex/kanban" (const (pure ())))
          stopReviewClient
          (action markerPath)

runBoundedClaudeCall :: Int -> ReviewClient -> Text -> IO (Either Text Text)
runBoundedClaudeCall boundMicros client prompt = do
  outcome <- timeout boundMicros (withReservedToolSlot client (fixtureReviewThread "thread-1") (\key -> runAuthenticatedClaude client key prompt))
  requireJust "the Claude reviewer call did not return within its bounded window" outcome

-- | Asserts the process a fixture recorded is gone by the time the runner
-- returned, which is how a test sees the spawned process group swept. A
-- killed process is already absent from this snapshot even before its parent
-- reaps it, so no wait is needed here.
shouldRecordASweptProcess :: FilePath -> String -> Expectation
shouldRecordASweptProcess markerPath description = do
  pid <- readRecordedPid markerPath
  snapshot <- readProcessSnapshot
  case snapshot of
    Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
    Right identities ->
      case identityForPid pid identities of
        Nothing -> pure ()
        Just _ -> expectationFailure ("expected " <> description <> " (pid " <> show pid <> ") to have been terminated")

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

isOrphaned :: WorkerState -> Bool
isOrphaned state = case state.workerStateStatus of
  WorkerOrphaned _ -> True
  _ -> False

isTerminal :: WorkerState -> Bool
isTerminal state = case state.workerStateStatus of
  WorkerTerminal _ -> True
  _ -> False
