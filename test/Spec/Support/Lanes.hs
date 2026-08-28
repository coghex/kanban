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
-- Four things hold that shape down, all of them in the runner rather than in
-- a convention a spec has to observe:
--
--   * 'laneConfig' pins hspec to a single job, so a lane cannot run two of its
--     own examples at once whatever any spec is annotated with;
--   * 'checkAssignment' refuses to start the suite at all if any example is
--     marked parallelizable, so annotating one is a failure rather than a
--     silent race;
--   * 'checkAssignment' also refuses an assignment that separates two groups
--     declared to need one lane between them — see 'Colocation' — so a
--     rebalancing that would let such a pair overlap fails at startup rather
--     than intermittently afterwards;
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
-- That is the whole list of what a lane shares with its siblings, so nothing
-- above holds one group to another group's lane. What a lane does not contain
-- is a group's own effect on the machine, and a pair of groups has been
-- measured interfering that way: the suite's assignment therefore decides
-- balance /and/, for the pairs declared as a 'Colocation', safety. Those
-- declarations live beside the assignment they constrain — in this suite,
-- beside @suiteGroups@ in "Main" — carrying the measurement that justifies
-- each one, and 'checkAssignment' refuses to start a suite that separates a
-- declared pair.
module Spec.Support.Lanes
  ( Lane (..),
    SuiteGroup (..),
    Colocation (..),
    allLanes,
    laneName,
    laneVariable,
    laneReportVariable,
    runSuiteInLanes,
    assignmentRefusals,
    countExamples,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, mask_, onException, try)
import Control.Monad (filterM, forM_, unless)
import qualified Data.ByteString.Char8 as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find, intercalate, nub, sort)
import Data.Maybe (isNothing)
import GHC.Clock (getMonotonicTime)
import Kanban.Process
  ( ProcessIdentity (..),
    descendantProcesses,
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
    Pid,
    ProcessHandle,
    StdStream (..),
    createProcess,
    getPid,
    getProcessExitCode,
    proc,
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
-- name claims: membership is decided by measured cost and by the declared
-- 'Colocation' constraints, not by a taxonomy. Five lanes hold the suite's
-- waiting evenly enough that the longest is within about a tenth of the
-- average, and the groups whose cost is computing — the great majority of the
-- examples, and under two seconds between them — ride along wherever there is
-- room.
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

-- | Two groups that must run in one lane, and the measurement that says so.
--
-- A lane contains the state a group establishes for itself, but not a group's
-- effect on the machine the whole suite is running on. Where two groups have
-- been measured interfering across that gap, putting them in one lane
-- serialises them, and this is how that placement is stated: as a constraint
-- 'checkAssignment' enforces rather than a comment a rebalancing can pass by.
--
-- A declaration belongs beside the assignment it constrains, so that whoever
-- moves a group reads it, and it is the only place the pair is stated —
-- everything else, this module included, refers to it. 'colocationReason' is
-- printed verbatim when the suite refuses to start, so it has to say why the
-- two cannot overlap without sending the reader anywhere else.
--
-- Only a pair whose interference has actually been measured belongs here. A
-- constraint added speculatively costs the packing freedom of a real one and
-- earns none of its safety.
data Colocation = Colocation
  { colocationFirst :: String,
    colocationSecond :: String,
    colocationReason :: String
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
--
-- The co-location constraints travel with the assignment because they
-- constrain it: only the runner half checks them, since a lane runs the groups
-- it was handed rather than deciding where any of them belongs.
runSuiteInLanes :: [SuiteGroup] -> [Colocation] -> IO ()
runSuiteInLanes groups colocations =
  lookupEnv laneVariable
    >>= maybe (runEveryLane groups colocations) (runOneLane groups)

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
runEveryLane :: [SuiteGroup] -> [Colocation] -> IO ()
runEveryLane groups colocations = do
  expected <- checkAssignment groups colocations
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
      -- The list of lanes the runner is still answerable for. Membership is
      -- exactly the claim "this PID is still ours to signal", and both edges of
      -- it are taken atomically: see 'reapLane' for why leaving is, and 'start'
      -- just below for why joining is.
      launched <- newIORef []
      let start lane = mask_ $ do
            -- Spawning and joining the list are one uninterruptible step. There
            -- is nothing interruptible between 'createProcess' returning and the
            -- write below, so there is no instant in which a lane exists and the
            -- runner does not know it has to bring it down. Anything that has to
            -- block belongs after this, when the lane is already accounted for.
            running <- startLane self arguments inherited root lane
            modifyIORef' launched (running :)
            pure running
          -- Reported as each is reaped rather than at the end, which is also
          -- why the lanes are reaped in their own order: what a run prints does
          -- not depend on which lane happened to finish first.
          collect running = do
            outcome <- collectLane launched running
            reportLane outcome
            pure outcome
      (mapM start allLanes >>= mapM collect)
        `onException` (readIORef launched >>= abandonLanes launched)
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
abandonLanes :: IORef [RunningLane] -> [RunningLane] -> IO ()
abandonLanes launched running = do
  -- Surveyed before anything is asked to stop, and that order is the point: a
  -- lane's fixtures are only reachable as its descendants while the lane is
  -- alive to be walked from. A lane that then unwinds cleanly and still leaves
  -- one behind would otherwise leave it orphaned and unfindable.
  standing <- mapM (surveyLane launched) running
  mapM_ (interruptLane launched . standingLane) standing
  awaitLanes launched running
  mapM_ (sweepLane launched) standing
  mapM_ dumpLane (reverse running)

-- | A lane and everything it had started at the moment it was asked to stop.
data StandingLane = StandingLane
  { standingLane :: RunningLane,
    standingTree :: [ProcessIdentity]
  }

surveyLane :: IORef [RunningLane] -> RunningLane -> IO StandingLane
surveyLane launched running = do
  pid <- laneStillOurs launched running
  snapshot <- readProcessSnapshot
  let live = either (const []) id snapshot
  pure . StandingLane running $
    maybe [] (\identifier -> descendantProcesses [fromIntegral identifier] live) pid

-- | How long the lanes are given, between them, to unwind after being asked
-- to. Generous next to how long unwinding takes — a bracket kills its fixture
-- as the exception passes through it — because being wrong costs a process
-- left running on the host.
abandonSeconds :: Double
abandonSeconds = 10

-- | Asks one lane to unwind. Aimed at the lane itself rather than its group:
-- what has to run is the lane's own finalizers, and its fixtures are reached
-- by those and by nothing else.
interruptLane :: IORef [RunningLane] -> RunningLane -> IO ()
interruptLane launched running = do
  pid <- laneStillOurs launched running
  forM_ pid $ \identifier -> ignoringIOException (signalProcess sigINT identifier)

-- | Waits for the lanes to finish unwinding, on one deadline between them
-- rather than one each, since they were all asked at once.
awaitLanes :: IORef [RunningLane] -> [RunningLane] -> IO ()
awaitLanes launched running = do
  deadline <- (+ abandonSeconds) <$> getMonotonicTime
  let poll = do
        alive <- filterM (fmap isNothing . reapLane launched) running
        now <- getMonotonicTime
        unless (null alive || now >= deadline) (threadDelay pollMicroseconds >> poll)
  poll

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

collectLane :: IORef [RunningLane] -> RunningLane -> IO LaneOutcome
collectLane launched running = do
  code <- waitForLane launched running
  output <- ByteString.readFile (runningOutput running)
  report <- readLaneReport (runningReport running)
  pure (LaneOutcome (runningLane running) code output report)

waitForLane :: IORef [RunningLane] -> RunningLane -> IO ExitCode
waitForLane launched running =
  reapLane launched running
    >>= maybe (threadDelay pollMicroseconds >> waitForLane launched running) pure

-- | Reaps a lane if it has finished, and takes it off the runner's list in the
-- same breath.
--
-- Those two are one uninterruptible step, and the reap is the non-blocking
-- 'getProcessExitCode' rather than a blocking wait precisely so that it can be:
-- a blocking wait reaps inside itself and can be interrupted before it says so,
-- leaving a handle that still names a PID nothing owns any more. A lane's PID
-- is the runner's to signal only until something reaps it, after which the host
-- may hand it — and the process group it names — to anything at all. Membership
-- of the list /is/ that claim, and it stops being true and stops being claimed
-- at the same instant.
reapLane :: IORef [RunningLane] -> RunningLane -> IO (Maybe ExitCode)
reapLane launched running = mask_ $ do
  code <- getProcessExitCode (runningHandle running)
  forM_ code (const (modifyIORef' launched (filter ((/= runningLane running) . runningLane))))
  pure code

-- | How often a lane is asked whether it has finished: nothing next to the tens
-- of seconds a lane takes, and the price of a reap the runner's list can be
-- kept honest across.
pollMicroseconds :: Int
pollMicroseconds = 50000

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
sweepLane :: IORef [RunningLane] -> StandingLane -> IO ()
sweepLane launched standing = do
  pid <- laneStillOurs launched (standingLane standing)
  snapshot <- readProcessSnapshot
  let live = either (const []) id snapshot
      descendants = maybe [] (\identifier -> descendantProcesses [fromIntegral identifier] live) pid
      -- Whatever the lane had when it was surveyed and still holds the same PID
      -- and start time, plus whatever it has started since. The first half is
      -- what outlives the lane itself; the second is what a lane that never
      -- unwound is still holding.
      survivors = matchingIdentities live (standingTree standing) <> descendants
  forM_ survivors $ \survivor ->
    ignoringIOException (signalProcess sigKILL (fromIntegral survivor.processIdentityPid))
  forM_ pid $ \identifier ->
    ignoringIOException (signalProcessGroup sigKILL identifier)

-- | The lane's PID, and only while the runner is still answerable for it.
--
-- Every signal this module aims at a lane goes through here. A PID names the
-- lane only until something reaps it, and 'reapLane' is the one thing that
-- does, taking the lane off the list in the same uninterruptible step; so a
-- lane still on the list has not been reaped, its PID has not been released,
-- and neither has the process group its own session named after it. A lane that
-- has left the list is never signalled, whatever its handle still says.
laneStillOurs :: IORef [RunningLane] -> RunningLane -> IO (Maybe Pid)
laneStillOurs launched running = do
  answerable <- elem (runningLane running) . map runningLane <$> readIORef launched
  if answerable then getPid (runningHandle running) else pure Nothing

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
--
-- The work is split in two because the halves cost different things to test.
-- 'assignmentRefusals' reads names and lanes only, so a test can put a
-- synthetic assignment through the real check without building anyone's spec
-- tree; 'countExamples' needs a tree, and building the suite's own runs every
-- @runIO@ in it, so a test gives it a tree of its own instead.
checkAssignment :: [SuiteGroup] -> [Colocation] -> IO Int
checkAssignment groups colocations = do
  forM_ (take 1 (assignmentRefusals groups colocations)) die
  counted <- countExamples (mapM_ suiteGroupSpec groups)
  either die pure counted

-- | Every reason to refuse this assignment, worst first, decided from the
-- groups' names and lanes alone. Empty means the assignment is allowed.
--
-- The order matters: two groups sharing a name is reported before anything
-- else because it is what makes a co-location endpoint ambiguous, so a reader
-- is told the cause rather than one of its symptoms.
assignmentRefusals :: [SuiteGroup] -> [Colocation] -> [String]
assignmentRefusals groups colocations =
  concat [duplicateNames, emptyLanes, colocationFaults]
  where
    duplicateNames =
      let repeated =
            nub [name | (name, count) <- tally (map suiteGroupName groups), count > (1 :: Int)]
       in [ "suite groups share a name, so one of them cannot be reported: " <> unwords repeated
            | not (null repeated)
          ]
    emptyLanes =
      [ "lane " <> laneName lane <> " has no groups, so the assignment no longer matches the lanes"
        | lane <- allLanes,
          null (groupsIn groups lane)
      ]
    colocationFaults = concatMap (colocationRefusal groups) colocations

-- | Why this assignment cannot honour one declared co-location, if it cannot.
--
-- A pair is refused for being separated, and also for naming an endpoint this
-- assignment does not resolve to exactly one group: a rename or a removal
-- would otherwise leave the declaration matching nothing and enforcing
-- nothing, which is the failure a constraint exists to prevent, arrived at
-- quietly. Either way the message names both groups and carries the
-- declaration's own reason, so it is actionable without opening this file.
colocationRefusal :: [SuiteGroup] -> Colocation -> [String]
colocationRefusal groups colocation =
  case (resolve (colocationFirst colocation), resolve (colocationSecond colocation)) of
    (Left fault, _) -> [unresolved fault]
    (_, Left fault) -> [unresolved fault]
    (Right firstLane, Right secondLane)
      | firstLane == secondLane -> []
      | otherwise -> [separated firstLane secondLane]
  where
    resolve name = case filter ((== name) . suiteGroupName) groups of
      [group] -> Right (suiteGroupLane group)
      [] -> Left (show name <> " is not a group of this suite")
      matched -> Left (show name <> " names " <> show (length matched) <> " groups of this suite, not one")
    pair =
      show (colocationFirst colocation) <> " and " <> show (colocationSecond colocation)
    separated firstLane secondLane =
      pair
        <> " must run in the same lane, but they are assigned to lane "
        <> laneName firstLane
        <> " and lane "
        <> laneName secondLane
        <> ", which run at the same time. "
        <> colocationReason colocation
    unresolved fault =
      "the declaration that "
        <> pair
        <> " must run in the same lane cannot be enforced, because "
        <> fault
        <> ". Repair the declaration rather than dropping it: "
        <> colocationReason colocation

-- | How many examples a spec tree holds, or why it may not be run at all.
--
-- Evaluating the tree is what finds a parallelizable example, and is also the
-- only way to count what the lanes will have to account for between them, so
-- the two answers come from one evaluation.
countExamples :: Spec -> IO (Either String Int)
countExamples spec = do
  (_, forest) <- evalSpec defaultConfig spec
  let items = forestItems forest
      parallelized = sort [path | (path, item) <- items, itemIsParallelizable item == Just True]
  pure $
    if null parallelized
      then Right (length items)
      else
        Left
          ( "these examples are marked parallelizable, which would run one beside another in a single process:\n  "
              <> intercalate "\n  " parallelized
          )

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
