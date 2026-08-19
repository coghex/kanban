-- | The lanes the suite runs in, and the runner that drives them.
--
-- Most of this suite's wall clock is spent waiting rather than computing: a
-- TERM-to-KILL grace period, a provider probe that never exits, a service
-- invocation that has to be proven timed out. Those waits can overlap. What
-- they cannot do is share a process.
--
-- Every expensive example here establishes what it drives through state that
-- belongs to the process rather than to the example:
--
--   * environment variables, through 'Spec.Support.Env.withEnvironmentValue'
--     and the @PATH@ that 'Spec.Support.Env.withFakeOnPath' puts a fake
--     executable on;
--   * the working directory, through @withCurrentDirectory@ in
--     "Spec.Agent.Ping" and "Spec.Agent.UsageMode";
--   * the file-creation mask, through 'Spec.Support.Env.withFileCreationMask';
--   * the SIGTERM and SIGINT dispositions a managed worker installs and
--     restores ("Kanban.Worker");
--   * the process tree itself, which every census, group sweep and
--     \"leaves no survivor\" assertion reads.
--
-- Each of those is per-process. Two examples sharing one process share all of
-- them, and the loser of a restore race writes the other's value back. So the
-- unit of concurrency here is a /lane/: a separate suite process, in a session
-- of its own, running its own groups one at a time. Two lanes share none of
-- that state, and — because a lane is a session leader — one lane's group
-- sweep cannot reach another lane's children and one lane's census cannot find
-- them among its own descendants.
--
-- Three things hold that shape down, all of them in the runner rather than in
-- a convention a spec has to observe:
--
--   * 'laneConfig' pins hspec to a single job, so a lane cannot run two of its
--     own examples at once whatever any spec is annotated with;
--   * 'checkAssignment' refuses to start the suite at all if any example is
--     marked parallelizable, so annotating one is a failure rather than a
--     silent race;
--   * 'summarize' holds the lanes to the example count 'checkAssignment' read
--     off the suite's own spec tree, so a lane that dies, never reports, or
--     turns out to hold the wrong groups fails the run instead of quietly
--     shrinking it.
--
-- Concurrency is between lanes and nowhere else, and no future test has to
-- remember that.
--
-- What a lane still shares with its siblings, and why each is safe:
--
--   * The machine's temporary root. Every scratch directory is allocated by
--     'Spec.Support.Env.createTemporaryDirectory', which is POSIX @mkdtemp@
--     precisely so that two suite processes racing it cannot be handed the
--     same path.
--   * The real XDG cache and the real home directory. Every example that
--     writes under either pins @XDG_CACHE_HOME@ at a scratch root of its own
--     first; the handful that read @HOME@ read a path, not a file. So no lane
--     writes anywhere another lane reads — and a new example that did would
--     be leaking outside its own scratch space with or without lanes.
--   * The host's process table, which every lane's @ps@ can see all of. Seeing
--     is harmless: a census filters a snapshot down to identities its own
--     example recorded, matched by start time as well as PID. Killing is what
--     had to be contained, and the session boundary contains it — a group
--     signal reaches a process group, and no live process of another lane's
--     session can be in a group this lane recorded.
--
-- That is the whole list, so no group is held to another group's lane and
-- nothing here is a constraint a future group has to be told about. What
-- 'suiteGroups' does decide is balance, not safety.
module Spec.Support.Lanes
  ( Lane (..),
    SuiteGroup (..),
    allLanes,
    laneName,
    laneVariable,
    laneReportVariable,
    runSuiteInLanes,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, onException, try)
import Control.Monad (filterM, forM_, unless, when)
import qualified Data.ByteString.Char8 as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (find, intercalate, nub, sort)
import Data.Maybe (isNothing)
import qualified Data.Text as Text
import GHC.Clock (getMonotonicTime)
import Kanban.Process
  ( ProcessIdentity (..),
    descendantProcesses,
    identityForPid,
    matchingIdentities,
    readProcessSnapshot,
  )
import Numeric (showFFloat)
import Spec.Support.Env (createTemporaryDirectory, ignoringIOException)
import System.Directory (removePathForcibly)
import System.Environment (getArgs, getEnvironment, getExecutablePath, lookupEnv, withArgs)
import System.Exit (ExitCode (..), die, exitFailure, exitSuccess)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode, WriteMode), hIsTerminalDevice, openFile, readFile', stdout)
import System.Posix.Process (getProcessGroupID, getProcessID)
import System.Posix.Signals (sigINT, sigKILL, signalProcess, signalProcessGroup)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    getPid,
    getProcessExitCode,
    proc,
    waitForProcess,
  )
import Test.Hspec (Spec)
import Test.Hspec.Core.Runner
  ( Config (..),
    Summary (..),
    defaultConfig,
    evalSpec,
    evaluateResult,
    readConfig,
    runSpecForest,
    toSummary,
  )
import Test.Hspec.Core.Spec (Item (..), SpecTree, Tree (..))
import Text.Read (readMaybe)

-- | One suite process. Every group names the lane it runs in, so a group
-- cannot be added without deciding what it is allowed to overlap with.
--
-- Each lane is named after the group that dominates it, and that is all the
-- name claims: membership is a packing decision taken from measured cost, not
-- a taxonomy. Five lanes hold the suite's waiting evenly enough that the
-- longest is within about a tenth of the average, and the groups whose cost is
-- computing — the great majority of the examples, and under two seconds
-- between them — ride along wherever there is room.
data Lane
  = DeadlineLane
  | SupervisionLane
  | LifecycleLane
  | PingLane
  | UsageLane
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | A top-level group of the suite and the lane it belongs to.
data SuiteGroup = SuiteGroup
  { suiteGroupName :: String,
    suiteGroupLane :: Lane,
    suiteGroupSpec :: Spec
  }

allLanes :: [Lane]
allLanes = [minBound .. maxBound]

laneName :: Lane -> String
laneName lane = case lane of
  DeadlineLane -> "deadline"
  SupervisionLane -> "supervision"
  LifecycleLane -> "lifecycle"
  PingLane -> "ping"
  UsageLane -> "usage"

laneNamed :: String -> Maybe Lane
laneNamed name = find ((== name) . laneName) allLanes

-- | Set on a lane and nothing else: its presence is what tells a suite process
-- it is one lane rather than the runner, which is also what stops a lane from
-- starting lanes of its own.
laneVariable :: String
laneVariable = "KANBAN_TEST_LANE"

-- | Where a lane records what it ran, for the runner to add up. Set by the
-- runner only, so a lane started by hand —
--
-- > KANBAN_TEST_LANE=deadline cabal run kanban-test
--
-- — reports to nobody and is not held to the session the runner would have
-- given it.
laneReportVariable :: String
laneReportVariable = "KANBAN_TEST_LANE_REPORT"

-- | The suite's entry point. Runs one lane when this process is a lane, and
-- otherwise runs every lane and adds up what they ran.
runSuiteInLanes :: [SuiteGroup] -> IO ()
runSuiteInLanes groups =
  lookupEnv laneVariable >>= maybe (runEveryLane groups) (runOneLane groups)

-- * One lane

-- | The lane half: this process runs one lane's groups, one at a time.
runOneLane :: [SuiteGroup] -> String -> IO ()
runOneLane groups name = do
  lane <- case laneNamed name of
    Nothing ->
      die
        ( laneVariable
            <> " names no lane: "
            <> show name
            <> " (the lanes are "
            <> unwords (map laneName allLanes)
            <> ")"
        )
    Just lane -> pure lane
  report <- lookupEnv laneReportVariable
  forM_ report (const (requireOwnSession lane))
  (defaults, forest) <- evalSpec defaultConfig (mapM_ suiteGroupSpec (groupsIn groups lane))
  config <- laneConfig lane <$> (getArgs >>= readConfig defaults)
  started <- getMonotonicTime
  result <- withArgs [] (runSpecForest forest config)
  elapsed <- subtract started <$> getMonotonicTime
  let summary = toSummary result
  forM_ report $ \path ->
    writeFile
      path
      ( unwords
          [ show (summaryExamples summary),
            show (summaryFailures summary),
            show (length (forestItems forest)),
            show elapsed
          ]
      )
  evaluateResult result

-- | What a lane is run under, whatever the command line, a config file or
-- @HSPEC_OPTIONS@ asked for.
--
-- One job, because overlap between lanes is the point of this harness and
-- overlap /inside/ one is the race it exists to rule out. And a failure report
-- of its own, because that file is the one piece of hspec's state that
-- outlives the process: five lanes writing the path @--failure-report@ named
-- would leave one lane's failures standing for all five.
laneConfig :: Lane -> Config -> Config
laneConfig lane config =
  config
    { configConcurrentJobs = Just 1,
      configFailureReport = fmap (<> ("." <> laneName lane)) (configFailureReport config)
    }

-- | A lane the runner started leads its own process group, because it was
-- started in a session of its own. That is what keeps a group sweep in one
-- lane away from another lane's children, so a lane that somehow did not get
-- one refuses to run rather than sweeping into its siblings.
requireOwnSession :: Lane -> IO ()
requireOwnSession lane = do
  self <- getProcessID
  group <- getProcessGroupID
  unless (self == group) $
    die
      ( "lane "
          <> laneName lane
          <> " was started without a session of its own (process "
          <> show self
          <> " is in group "
          <> show group
          <> "), so its process assertions could reach another lane"
      )

-- * Every lane

-- | The runner half: start every lane at once, then report them in order.
runEveryLane :: [SuiteGroup] -> IO ()
runEveryLane groups = do
  expected <- checkAssignment groups
  self <- getExecutablePath
  supplied <- getArgs
  -- A lane writes to a file, so it would decide there is no terminal to colour
  -- for. The runner knows better, and a supplied flag still wins by coming
  -- later on the command line.
  colored <- hIsTerminalDevice stdout
  let arguments = ["--color" | colored] <> supplied
  inherited <- getEnvironment
  -- Said before anything is spawned, so a run that goes on to hang has already
  -- named what it is waiting for.
  putStrLn ("Running " <> show (length allLanes) <> " lanes: " <> unwords (map laneName allLanes))
  started <- getMonotonicTime
  outcomes <-
    bracket createTemporaryDirectory removePathForcibly $ \root -> do
      -- Recorded as they start rather than after the last one, so a lane that
      -- fails to start leaves no siblings of its own running behind it.
      launched <- newIORef []
      let start lane = do
            running <- startLane self arguments inherited root lane
            modifyIORef' launched (running :)
            pure running
          -- Reported as each is reaped rather than at the end, which is also
          -- why the lanes are reaped in their own order: what a run prints
          -- does not depend on which lane happened to finish first. A reaped
          -- lane drops off the list at the same moment, so an interrupt after
          -- it neither reports it twice nor signals a group its PID no longer
          -- names.
          collect running = do
            outcome <- collectLane running
            modifyIORef' launched (filter ((/= runningLane running) . runningLane))
            reportLane outcome
            pure outcome
      (mapM start allLanes >>= mapM collect)
        `onException` (readIORef launched >>= abandonLanes)
  elapsed <- subtract started <$> getMonotonicTime
  summarize expected elapsed outcomes

-- | Brings every lane still running down, then prints how far each had got.
--
-- Asking is not the same as killing here, and the difference is the whole
-- point. A lane's fixtures put TERM-resistant processes in groups — and
-- sessions — of their own on purpose, so a signal aimed at the lane's own
-- group does not reach them and nothing but the fixture's own bracket ever
-- will. So each lane is first asked to unwind, through the SIGINT its runtime
-- delivers to its main thread as an interrupt, which is what runs those
-- brackets; only what is still standing after that is killed by group. A lane
-- killed outright would leave every such fixture running on the host.
abandonLanes :: [RunningLane] -> IO ()
abandonLanes running = do
  -- Surveyed before anything is asked to stop, and that order is the point: a
  -- lane's fixtures are only reachable as its descendants while the lane is
  -- alive to be walked from. A lane that then unwinds cleanly and still leaves
  -- one behind would otherwise leave it orphaned and unfindable.
  standing <- mapM surveyLane running
  mapM_ (interruptLane . standingLane) standing
  awaitLanes running
  mapM_ sweepLane standing
  mapM_ dumpLane (reverse running)

-- | A lane and everything it had started at the moment it was asked to stop.
data StandingLane = StandingLane
  { standingLane :: RunningLane,
    standingTree :: [ProcessIdentity]
  }

surveyLane :: RunningLane -> IO StandingLane
surveyLane running = StandingLane running . maybe [] snd <$> laneStanding running

-- | How long the lanes are given, between them, to unwind after being asked
-- to. Generous next to how long unwinding takes — a bracket kills its fixture
-- as the exception passes through it — because being wrong costs a process
-- left running on the host.
abandonSeconds :: Double
abandonSeconds = 10

-- | Asks one lane to unwind. Aimed at the lane itself rather than its group:
-- what has to run is the lane's own finalizers, and its fixtures are reached
-- by those and by nothing else.
interruptLane :: RunningLane -> IO ()
interruptLane running = do
  standing <- laneStanding running
  forM_ standing $ \(identity, _) ->
    ignoringIOException (signalProcess sigINT (fromIntegral identity.processIdentityPid))

-- | Waits for the lanes to finish unwinding, on one deadline between them
-- rather than one each, since they were all asked at once.
awaitLanes :: [RunningLane] -> IO ()
awaitLanes running = do
  deadline <- (+ abandonSeconds) <$> getMonotonicTime
  let poll = do
        alive <- filterM stillRunning running
        now <- getMonotonicTime
        unless (null alive || now >= deadline) (threadDelay 100000 >> poll)
  poll

stillRunning :: RunningLane -> IO Bool
stillRunning = fmap isNothing . getProcessExitCode . runningHandle

dumpLane :: RunningLane -> IO ()
dumpLane running = do
  ByteString.putStrLn (ByteString.pack ("== lane " <> laneName (runningLane running) <> ": abandoned"))
  ignoringIOException (ByteString.readFile (runningOutput running) >>= ByteString.putStr)

-- | 'runningIdentity' is what the lane was when it started, and it is the only
-- thing a signal is ever aimed through. A PID stops being ours the moment the
-- lane is reaped, and the host is free to hand it — and so the process group it
-- names — to something unrelated; 'Nothing' means the runner could not record
-- one, which is read as "do not signal" rather than as "signal anyway".
data RunningLane = RunningLane
  { runningLane :: Lane,
    runningHandle :: ProcessHandle,
    runningOutput :: FilePath,
    runningReport :: FilePath,
    runningIdentity :: Maybe ProcessIdentity
  }

data LaneOutcome = LaneOutcome
  { outcomeLane :: Lane,
    outcomeExit :: ExitCode,
    outcomeOutput :: ByteString.ByteString,
    outcomeReport :: Maybe LaneReport
  }

-- | What one lane ran. 'reportDeclared' is how many examples that lane /holds/,
-- before any @--match@ narrowed the run down, so the runner can say whether the
-- lanes between them hold the whole suite without having to know what was
-- filtered.
data LaneReport = LaneReport
  { reportExamples :: Int,
    reportFailures :: Int,
    reportDeclared :: Int,
    reportSeconds :: Double
  }

startLane :: FilePath -> [String] -> [(String, String)] -> FilePath -> Lane -> IO RunningLane
startLane self arguments inherited root lane = do
  let outputPath = root </> (laneName lane <> ".output")
      reportPath = root </> (laneName lane <> ".report")
      carried = [entry | entry@(name, _) <- inherited, name /= laneVariable, name /= laneReportVariable]
      environment = carried <> [(laneVariable, laneName lane), (laneReportVariable, reportPath)]
  output <- openFile outputPath WriteMode
  -- Reading from nothing rather than from the runner's own standard input: a
  -- lane has no controlling terminal, and a fixture that read an inherited one
  -- would be stopped on SIGTTIN instead of seeing the end of input it expects.
  input <- openFile "/dev/null" ReadMode
  (_, _, _, handle) <-
    createProcess
      (proc self arguments)
        { env = Just environment,
          std_in = UseHandle input,
          std_out = UseHandle output,
          std_err = UseHandle output,
          -- The isolation boundary itself: a session of its own puts every
          -- process this lane starts outside what another lane can reach with
          -- a group signal or find among its own descendants.
          new_session = True
        }
  RunningLane lane handle outputPath reportPath <$> recordLaneIdentity lane handle

-- | The identity of a lane that has just been started, taken while its PID is
-- still unambiguously ours because nothing has reaped it yet.
--
-- 'Nothing' means the lane is already gone — a lane holding nothing a
-- @--match@ selected finishes in under a millisecond — which needs no signal
-- and can take none. A snapshot that could not be taken at all is a different
-- answer: the runner cannot promise to bring this lane down, so it takes the
-- one chance it is sure of and refuses to run.
recordLaneIdentity :: Lane -> ProcessHandle -> IO (Maybe ProcessIdentity)
recordLaneIdentity lane handle = do
  pid <- getPid handle
  case pid of
    Nothing -> pure Nothing
    Just identifier -> do
      snapshot <- readProcessSnapshot
      case snapshot of
        Right live -> pure (identityForPid (fromIntegral identifier) live)
        Left message -> do
          ignoringIOException (signalProcessGroup sigKILL identifier)
          die
            ( "lane "
                <> laneName lane
                <> " could not be identified, so it could not be promised an end: "
                <> Text.unpack message
            )

collectLane :: RunningLane -> IO LaneOutcome
collectLane running = do
  code <- waitForProcess (runningHandle running)
  output <- ByteString.readFile (runningOutput running)
  report <- readLaneReport (runningReport running)
  pure (LaneOutcome (runningLane running) code output report)

-- | What a lane recorded, or 'Nothing' if it never got that far. Read as the
-- runner's only evidence that a lane ran at all, so an unreadable or
-- unparseable record is the absence of one rather than an empty result.
readLaneReport :: FilePath -> IO (Maybe LaneReport)
readLaneReport path = do
  recorded <- try @IOException (readFile' path)
  pure $ case fmap words recorded of
    Right [examples, failures, declared, elapsed] ->
      LaneReport
        <$> readMaybe examples
        <*> readMaybe failures
        <*> readMaybe declared
        <*> readMaybe elapsed
    _ -> Nothing

-- | Kills whatever is left of a lane that did not unwind: everything it
-- started, and then its own process group.
--
-- Its own group is not enough on its own. A fixture that put itself in a group
-- — or a session — of its own is exactly the one whose only other cleaner was
-- the bracket the lane never got to run, so what is swept is the lane's whole
-- descendant tree, read from one snapshot taken while the lane is still alive
-- to be walked from. After the lane dies its children are reparented and no
-- walk can find them again, which is why the tree is taken first and signalled
-- second.
sweepLane :: StandingLane -> IO ()
sweepLane standing = do
  snapshot <- readProcessSnapshot
  case snapshot of
    Left _ -> pure ()
    Right live -> do
      let current = stillItself live (runningIdentity (standingLane standing))
          descendants = maybe [] (\identity -> descendantProcesses [identity.processIdentityPid] live) current
          -- Whatever the lane had when it was surveyed and still holds the
          -- same PID and start time, plus whatever it has started since. The
          -- first half is what survives the lane itself; the second is what a
          -- lane that never unwound is still holding.
          survivors = matchingIdentities live (standingTree standing) <> descendants
      forM_ survivors $ \survivor ->
        ignoringIOException (signalProcess sigKILL (fromIntegral survivor.processIdentityPid))
      forM_ current $ \identity ->
        ignoringIOException (signalProcessGroup sigKILL (fromIntegral identity.processIdentityGroupPid))

-- | The lane as it is right now — and everything it has started — but only if
-- it is still the process the runner started: same PID, same start time.
--
-- Every signal this module sends goes through here, because a lane's PID is
-- the runner's to use only until the lane is reaped, and the reap can happen
-- inside 'waitForProcess' or 'getProcessExitCode' an instant before an
-- interrupt is delivered, leaving a handle that still reports the PID that now
-- belongs to somebody else. Answers 'Nothing' when the lane is already gone,
-- when its identity was never recorded, and when a snapshot cannot be taken at
-- all: not being able to tell is not permission to signal.
laneStanding :: RunningLane -> IO (Maybe (ProcessIdentity, [ProcessIdentity]))
laneStanding running = do
  snapshot <- readProcessSnapshot
  pure $ case snapshot of
    Left _ -> Nothing
    Right live -> do
      current <- stillItself live (runningIdentity running)
      Just (current, descendantProcesses [current.processIdentityPid] live)

-- | The recorded process as this snapshot has it, and only if the snapshot
-- still shows the same start time against the same PID.
stillItself :: [ProcessIdentity] -> Maybe ProcessIdentity -> Maybe ProcessIdentity
stillItself live recorded = do
  known <- recorded
  current <- identityForPid known.processIdentityPid live
  if current.processIdentityStartedAt == known.processIdentityStartedAt then Just current else Nothing

reportLane :: LaneOutcome -> IO ()
reportLane outcome = do
  ByteString.putStrLn
    (ByteString.pack ("== lane " <> laneName (outcomeLane outcome) <> ": " <> describeLane outcome))
  ByteString.putStr (outcomeOutput outcome)

describeLane :: LaneOutcome -> String
describeLane outcome = case outcomeReport outcome of
  Nothing -> "recorded no result, exited " <> show (outcomeExit outcome)
  Just report ->
    show (reportExamples report)
      <> " examples, "
      <> show (reportFailures report)
      <> " failures in "
      <> seconds (reportSeconds report)

-- | The one summary the whole run is read from. @expected@ is the suite's own
-- example count, taken from its spec tree by 'checkAssignment'; the lanes have
-- to hold exactly that many between them, which is checked against what each
-- lane /holds/ rather than what it ran, so a @--match@ narrowing the run cannot
-- turn the check off.
summarize :: Int -> Double -> [LaneOutcome] -> IO ()
summarize expected elapsed outcomes = do
  let reports = [report | Just report <- map outcomeReport outcomes]
      examples = sum (map reportExamples reports)
      failures = sum (map reportFailures reports)
      silent = [outcomeLane outcome | outcome <- outcomes, missingReport outcome]
      crashed =
        [ outcomeLane outcome
          | outcome <- outcomes,
            outcomeExit outcome /= ExitSuccess,
            Just report <- [outcomeReport outcome],
            reportFailures report == 0
        ]
      declared = sum (map reportDeclared reports)
      short = [declared | null silent, declared /= expected]
  putStrLn ""
  putStrLn ("Lanes finished in " <> seconds elapsed)
  putStrLn (show examples <> " examples, " <> show failures <> " failures")
  forM_ silent $ \lane ->
    putStrLn ("lane " <> laneName lane <> " recorded no result at all")
  forM_ crashed $ \lane ->
    putStrLn ("lane " <> laneName lane <> " failed without reporting a failing example")
  forM_ short $ \held ->
    putStrLn ("the lanes hold " <> show held <> " of the suite's " <> show expected <> " examples")
  if failures == 0 && null silent && null crashed && null short
    then exitSuccess
    else exitFailure

missingReport :: LaneOutcome -> Bool
missingReport outcome = case outcomeReport outcome of
  Nothing -> True
  Just _ -> False

seconds :: Double -> String
seconds value = showFFloat (Just 2) value " seconds"

-- * The assignment

-- | Refuses to start a suite whose lanes cannot hold what this harness
-- promises, and answers how many examples the whole suite has so the runner
-- can say whether the lanes between them hold it.
checkAssignment :: [SuiteGroup] -> IO Int
checkAssignment groups = do
  let names = map suiteGroupName groups
      repeated = nub [name | (name, count) <- tally names, count > (1 :: Int)]
  unless (null repeated) $
    die ("suite groups share a name, so one of them cannot be reported: " <> unwords repeated)
  forM_ allLanes $ \lane ->
    when (null (groupsIn groups lane)) $
      die ("lane " <> laneName lane <> " has no groups, so the assignment no longer matches the lanes")
  (_, forest) <- evalSpec defaultConfig (mapM_ suiteGroupSpec groups)
  let items = forestItems forest
      parallelized = sort [path | (path, item) <- items, itemIsParallelizable item == Just True]
  unless (null parallelized) $
    die
      ( "these examples are marked parallelizable, which would run one beside another in a single process:\n  "
          <> intercalate "\n  " parallelized
      )
  pure (length items)

groupsIn :: [SuiteGroup] -> Lane -> [SuiteGroup]
groupsIn groups lane = filter ((== lane) . suiteGroupLane) groups

tally :: [String] -> [(String, Int)]
tally names = [(name, length (filter (== name) names)) | name <- nub names]

forestItems :: [SpecTree ()] -> [(String, Item ())]
forestItems = concatMap (treeItems "")

treeItems :: String -> SpecTree () -> [(String, Item ())]
treeItems path tree = case tree of
  Node label children -> concatMap (treeItems (path <> "/" <> label)) children
  NodeWithCleanup _ _ children -> concatMap (treeItems path) children
  Leaf item -> [(path <> "/" <> itemRequirement item, item)]
