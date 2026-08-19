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

import Control.Exception (IOException, bracket, onException, try)
import Control.Monad (forM_, unless, when)
import qualified Data.ByteString.Char8 as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (find, intercalate, nub, sort)
import GHC.Clock (getMonotonicTime)
import Numeric (showFFloat)
import Spec.Support.Env (createTemporaryDirectory, ignoringIOException)
import System.Directory (removePathForcibly)
import System.Environment (getArgs, getEnvironment, getExecutablePath, lookupEnv, withArgs)
import System.Exit (ExitCode (..), die, exitFailure, exitSuccess)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode, WriteMode), hIsTerminalDevice, openFile, readFile', stdout)
import System.Posix.Process (getProcessGroupID, getProcessID)
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    getPid,
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

-- | Kills every lane still running and prints how far each had got, in that
-- order: the runner is coming down and the lanes would otherwise outlive it,
-- and a run interrupted because it looked stuck is exactly the one whose
-- partial output is worth having.
abandonLanes :: [RunningLane] -> IO ()
abandonLanes running = do
  mapM_ sweepLane running
  mapM_ dumpLane (reverse running)

dumpLane :: RunningLane -> IO ()
dumpLane running = do
  ByteString.putStrLn (ByteString.pack ("== lane " <> laneName (runningLane running) <> ": abandoned"))
  ignoringIOException (ByteString.readFile (runningOutput running) >>= ByteString.putStr)

data RunningLane = RunningLane
  { runningLane :: Lane,
    runningHandle :: ProcessHandle,
    runningOutput :: FilePath,
    runningReport :: FilePath
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
  pure (RunningLane lane handle outputPath reportPath)

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

-- | Kills a lane and everything it started, through the process group its own
-- session gave it.
--
-- Only ever reached while the lanes are still running, because the runner
-- itself is coming down. A lane that has already exited is deliberately not
-- swept: its group ID is its own former PID, which the host is free to hand to
-- an unrelated process the moment the group empties, and signalling that is
-- the mistake every identity check in "Kanban.Process" exists to avoid.
sweepLane :: RunningLane -> IO ()
sweepLane running = do
  pid <- getPid (runningHandle running)
  forM_ pid $ \identifier ->
    ignoringIOException (signalProcessGroup sigKILL identifier)

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
