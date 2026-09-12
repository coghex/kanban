{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | An independent process running @kanban --mission-scheduler@ from argv,
-- so what reaches stdout and what the process exits with can both be observed
-- (issue #666, requirement 7).
--
-- The claim requirement 7 makes is about a /process/: exactly one JSON
-- document on standard output, every word of narration on standard error, and
-- an exit status derived from the document's own termination. None of that is
-- observable from inside the process making it — a function that returns a
-- report has not yet written anything, and one that exits cannot be called
-- from a test at all — and @app\/Main.hs@ is not built by this suite.
--
-- So the shape is "Spec.Support.MissionProbes"'s: a marker in the child's
-- environment diverts this suite's own binary out of hspec and into
-- 'runSchedulerProbe', which parses a real argv with the real parser and then
-- runs exactly the three steps @main@ runs for that mode. The parent reads the
-- two streams and the status. What is deliberately /not/ shared with @main@ is
-- the parse: an argv that reached a different mode would make every assertion
-- below vacuous, so this refuses one rather than reporting on it.
module Spec.Support.SchedulerProbe
  ( schedulerProbeVariable,
    runSchedulerProbe,
    SchedulerRun (..),
    runSchedulerCommand,
  )
where

import Control.Monad (unless)
import Kanban.CLI (LaunchMode (..), launchMode, optionsParserInfo)
import Kanban.Mission (emitMissionPassReport, missionPassExitCode, missionPassTermination, runMissionSchedulerCommand)
import Options.Applicative (defaultPrefs, execParserPure, handleParseResult)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)
import System.Process (readCreateProcessWithExitCode, proc, env)

schedulerProbeVariable :: String
schedulerProbeVariable = "KANBAN_SCHEDULER_PROBE"

-- | The probe half, reached from @main@ when 'schedulerProbeVariable' is set.
--
-- The value is the argv, one argument per line, because an environment
-- variable is the only channel into a process this suite re-enters and the
-- arguments this mode takes are all plain ASCII.
runSchedulerProbe :: String -> IO ()
runSchedulerProbe encoded = do
  options <- handleParseResult (execParserPure defaultPrefs optionsParserInfo (lines encoded))
  unless (launchMode options == MissionSchedulerMode) $ do
    hPutStrLn stderr "this argv does not select the mission scheduler"
    exitWith (ExitFailure 111)
  -- Exactly what @app\/Main.hs@'s 'MissionSchedulerMode' arm does, in the
  -- same order. A difference here would make this probe a statement about
  -- itself.
  (report, status) <- runSchedulerStep options
  emitMissionPassReport report
  exitWith (if status == 0 then ExitSuccess else ExitFailure status)
  where
    runSchedulerStep options = do
      (report, status) <- runMissionSchedulerCommand options
      -- The status the document itself names, asserted rather than trusted:
      -- the one thing a supervisor cannot recover if these two disagree is
      -- which of them was right.
      unless (status == missionPassExitCode (missionPassTermination report)) $ do
        hPutStrLn stderr "the pass reported a status its termination does not name"
        exitWith (ExitFailure 112)
      pure (report, status)

-- | One probe run: the two streams, unmixed, and how it ended.
data SchedulerRun = SchedulerRun
  { schedulerRunExit :: ExitCode,
    schedulerRunStdout :: String,
    schedulerRunStderr :: String
  }
  deriving stock (Eq, Show)

-- | Runs @kanban --mission-scheduler@ in its own process with @argv@ and the
-- given environment, and hands back everything it produced.
--
-- The environment is given in full rather than extended, because what several
-- of these examples stage is a broken @$XDG_STATE_HOME@ or @$HOME@, and an
-- inherited one would quietly answer instead.
runSchedulerCommand :: [(String, String)] -> [String] -> IO SchedulerRun
runSchedulerCommand environment argv = do
  executable <- getExecutablePath
  (exitCode, out, err) <-
    readCreateProcessWithExitCode
      (proc executable []) {env = Just ((schedulerProbeVariable, unlines argv) : environment)}
      ""
  pure (SchedulerRun exitCode out err)
