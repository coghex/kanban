-- | Fixture executables simulating the Claude usage probe's real process
-- tree (a `script` pty wrapper and the `claude` child it runs), so
-- 'Kanban.Claude.runClaudeProvider''s termination escalation can be driven
-- against a real, killable process tree instead of asserted about in the
-- abstract.
module Spec.Support.ClaudeProbe
  ( ClaudeSignalPolicy (..),
    ClaudeProbeFixture (..),
    withClaudeProbeFixture,
  )
where

import qualified Data.ByteString.Char8 as ByteString
import Spec.Support.Env (withTemporaryCacheRoot)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

-- | How the fake `claude` child responds to the escalation's first two
-- signals. SIGKILL is never trappable, so every policy still eventually
-- dies.
data ClaudeSignalPolicy
  = -- | Exits on its own once it has "seen" the exit request; the fast path.
    ClaudeExitsCleanly
  | -- | Ignores INT (standing in for a wedged Claude Code busy in a
    -- spinner), but has no TERM handler of its own, so the default
    -- disposition ends it as soon as TERM is delivered.
    ClaudeIgnoresInterrupt
  | -- | Ignores both INT and TERM, so only SIGKILL can end it.
    ClaudeIgnoresInterruptAndTerminate
  deriving stock (Eq, Show)

data ClaudeProbeFixture = ClaudeProbeFixture
  { claudeProbeScriptPath :: FilePath,
    claudeProbeClaudePath :: FilePath,
    claudeProbeScriptMarker :: FilePath,
    claudeProbeChildMarker :: FilePath,
    -- | Written by the `claude` child's own TERM trap, for policies where
    -- TERM is expected to end it (every policy except one that ignores TERM
    -- outright) -- so a test can assert not just that the process died, but
    -- specifically whether TERM was what ended it, distinguishing "never
    -- needed" from "received and survived."
    claudeProbeTermMarker :: FilePath
  }

-- | Writes a fake `script`+`claude` pair under a fresh temporary root and
-- hands their paths (plus the marker files each records its own pid to) to
-- `action`. `separateGroup` toggles between the `claude` child sharing its
-- wrapper's process group (the ordinary "create_group took effect and
-- nothing else changed it" case) and one placed in a session/group of its
-- own -- what `script`'s pty actually does in production, and the shape a
-- create_group-only signal never reaches.
withClaudeProbeFixture :: Bool -> ClaudeSignalPolicy -> Bool -> (ClaudeProbeFixture -> IO result) -> IO result
withClaudeProbeFixture separateGroup signalPolicy emitValidUsage action =
  withTemporaryCacheRoot $ \temporaryRoot -> do
    let binaryRoot = temporaryRoot </> "bin"
        scriptPath = binaryRoot </> "script"
        claudePath = binaryRoot </> "claude"
        scriptMarker = temporaryRoot </> "script.pid"
        childMarker = temporaryRoot </> "claude-child.pid"
        termMarker = temporaryRoot </> "claude-term-received"
    createDirectoryIfMissing True binaryRoot
    ByteString.writeFile scriptPath (ByteString.unlines (fakeScriptBody scriptMarker separateGroup))
    setFileMode scriptPath 0o700
    ByteString.writeFile claudePath (ByteString.unlines (fakeClaudeBody childMarker termMarker signalPolicy emitValidUsage))
    setFileMode claudePath 0o700
    action (ClaudeProbeFixture scriptPath claudePath scriptMarker childMarker termMarker)

-- | Stands in for real `script -q /dev/null <claude> --safe-mode
-- --ax-screen-reader`: records its own pid, then runs the given `claude`
-- path as a child, optionally under job-control monitor mode so the child
-- gets a process group of its own -- the same effect `script`'s pty gets
-- for free via `forkpty`'s implicit `setsid`.
fakeScriptBody :: FilePath -> Bool -> [ByteString.ByteString]
fakeScriptBody scriptMarkerPath separateGroup =
  [ "#!/bin/bash",
    "printf '%s' \"$$\" > " <> quoted scriptMarkerPath,
    "shift 2",
    "claudePath=\"$1\"",
    "shift"
  ]
    <> ["set -m" | separateGroup]
    <> [ "\"$claudePath\" \"$@\" &",
         "childPid=$!"
       ]
    <> ["set +m" | separateGroup]
    <> ["wait \"$childPid\""]

-- | Stands in for real `claude --safe-mode --ax-screen-reader` running
-- inside `script`'s pty: records its own pid, optionally emits a decodable
-- `/usage` transcript, then either drains the exact byte count Kanban's
-- ESC+`/exit` writes before exiting on its own, or loops under whichever
-- signal-ignoring trap the policy names.
--
-- Every policy except the one that ignores TERM outright traps it to record
-- receipt (into @termMarkerPath@) before ending itself the same way the
-- default disposition would -- so a test can tell "TERM was never sent"
-- apart from "TERM arrived and this happened to die anyway".
--
-- The clean-exit tail deliberately keeps stdout open (blocked in `dd`)
-- rather than exiting the moment output is printed: 'captureUsage' only
-- writes the exit request once its own capture has already returned, so a
-- fake that closed its output pipe any earlier would race a real Claude
-- session's output never closing on its own, hitting a decode path this
-- fixture is not testing.
fakeClaudeBody :: FilePath -> FilePath -> ClaudeSignalPolicy -> Bool -> [ByteString.ByteString]
fakeClaudeBody childMarkerPath termMarkerPath signalPolicy emitValidUsage =
  [ "#!/bin/bash",
    "printf '%s' \"$$\" > " <> quoted childMarkerPath
  ]
    <> trapLines
    <> outputLines
    <> tailLines
  where
    recordTermThenExit = "trap 'printf 1 > " <> quoted termMarkerPath <> "; exit 143' TERM"
    trapLines = case signalPolicy of
      ClaudeExitsCleanly -> [recordTermThenExit]
      ClaudeIgnoresInterrupt -> ["trap '' INT", recordTermThenExit]
      ClaudeIgnoresInterruptAndTerminate -> ["trap '' INT", "trap '' TERM"]
    outputLines
      | emitValidUsage =
          [ "printf '$\\n'",
            "printf 'Current session\\n5%% used\\nResets 8:40pm (America/Los_Angeles)\\n'",
            "printf 'Current week\\n10%% used\\nResets Jul 22 at 11pm (America/Los_Angeles)\\n'"
          ]
      | otherwise = []
    tailLines = case signalPolicy of
      -- 14 bytes: 'respondToScreen' answers the "$" prompt above with
      -- "/usage\r" (7 bytes) as soon as it appears in the transcript, well
      -- before 'requestCleanExit' later writes its own ESC + "/exit\r" (7
      -- more) -- both must be drained, or this would exit the moment the
      -- first one arrives rather than waiting for the real exit request.
      ClaudeExitsCleanly -> ["dd bs=1 count=14 of=/dev/null 2>/dev/null", "exit 0"]
      _ -> ["while :; do sleep 1; done"]

quoted :: FilePath -> ByteString.ByteString
quoted path = "'" <> ByteString.pack path <> "'"
