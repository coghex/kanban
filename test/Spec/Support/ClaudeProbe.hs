-- | Fixture executables simulating the Claude usage probe's real process
-- tree (a `script` pty wrapper and the `claude` child it runs), so
-- 'Kanban.Claude.runClaudeProvider''s termination escalation can be driven
-- against a real, killable process tree instead of asserted about in the
-- abstract.
module Spec.Support.ClaudeProbe
  ( ClaudeSignalPolicy (..),
    ClaudeProbeFixture (..),
    ClaudeTranscript (..),
    ClaudeWrapperLifetime (..),
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

-- | How long the fake `script` stays around. A real `script` outlives the
-- client it launched, which is what keeps a `claude` its pty put in a
-- session of its own reachable by walking down from the wrapper's pid. The
-- other shape is the one the exception path has to survive: the wrapper
-- leaves mid-session, the child it launched is reparented, and Kanban's next
-- write to the pseudo-terminal fails.
data ClaudeWrapperLifetime
  = -- | Waits for the `claude` child, as a real `script` does.
    WrapperWaitsForClaude
  | -- | Leaves while the child is still running, so Kanban's end of the
    -- pseudo-terminal breaks under whatever it writes next. It stays up
    -- through the client's startup first, which is what a real `script`
    -- does for the whole session: a wrapper that vanished before the probe
    -- had ever seen the tree it launched would be an unrecoverable case
    -- rather than this one, since nothing could have censused the child
    -- through it. Pair it with a policy whose child outlives the wrapper --
    -- with 'ClaudeExitsCleanly' there would be nothing left to reparent,
    -- and its tail would sit waiting on bytes that never reach the stdin
    -- this shape gives it.
    WrapperExitsMidSession
  | -- | As 'WrapperExitsMidSession', but gone as soon as the client it
    -- launched is actually up, rather than after a stretch of the session.
    -- The departure is ordered against the child's own first act, not
    -- against the clock, because how long a fixture wrapper takes to be
    -- scheduled, start a shell and fork is neither small nor predictable --
    -- around a quarter of a second was observed on an ordinary macOS test
    -- run -- so a wall-clock delay measured from launch says nothing about
    -- how much of the client's lifetime the wrapper actually shares. What
    -- it does hold to is the far end of that: a probe that leaves censusing
    -- until it is driving the pseudo-terminal, or until the write fails,
    -- has lost the child by then.
    WrapperExitsAtStartup
  deriving stock (Eq, Show)

-- | What the fake `claude` puts on the pseudo-terminal before its tail
-- behavior takes over. Each shape drives one of 'Kanban.Provider'\'s error
-- classifications through the real capture loop, so a test can show the
-- flavor annotation naming the dialect without flattening the kind the
-- failing step reported.
data ClaudeTranscript
  = -- | Nothing at all: capture can only end by timing out.
    NoTranscript
  | -- | The screen-reader prompt and a complete, decodable @/usage@ screen.
    CompleteUsageTranscript
  | -- | A client that has been signed out, which capture recognizes as a
    -- failure without waiting for the quiet period.
    AuthenticationFailureTranscript
  | -- | A screen naming both windows but resetting both of them at a
    -- clock time, so it carries two five-hour windows and no weekly one --
    -- complete enough to end capture, not decodable into a snapshot.
    MissingWeeklyWindowTranscript
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
-- create_group-only signal never reaches. `wrapperLifetime` decides whether
-- the wrapper stays for the whole session or leaves the child behind
-- part-way through it; the two knobs are independent, and it is their
-- combination -- a separately grouped child whose wrapper has gone -- that
-- nothing reachable from the wrapper's pid can find afterwards.
withClaudeProbeFixture :: Bool -> ClaudeWrapperLifetime -> ClaudeSignalPolicy -> ClaudeTranscript -> (ClaudeProbeFixture -> IO result) -> IO result
withClaudeProbeFixture separateGroup wrapperLifetime signalPolicy transcript action =
  withTemporaryCacheRoot $ \temporaryRoot -> do
    let binaryRoot = temporaryRoot </> "bin"
        scriptPath = binaryRoot </> "script"
        claudePath = binaryRoot </> "claude"
        scriptMarker = temporaryRoot </> "script.pid"
        childMarker = temporaryRoot </> "claude-child.pid"
        termMarker = temporaryRoot </> "claude-term-received"
    createDirectoryIfMissing True binaryRoot
    ByteString.writeFile scriptPath (ByteString.unlines (fakeScriptBody scriptMarker childMarker separateGroup wrapperLifetime))
    setFileMode scriptPath 0o700
    ByteString.writeFile claudePath (ByteString.unlines (fakeClaudeBody childMarker termMarker signalPolicy transcript))
    setFileMode claudePath 0o700
    action (ClaudeProbeFixture scriptPath claudePath scriptMarker childMarker termMarker)

-- | Stands in for a real `script`, in whichever dialect
-- 'Kanban.Claude.claudeProbeArguments' composed for the host: it records
-- its own pid, then runs the `claude` the operands name as a child,
-- optionally under job-control monitor mode so the child gets a process
-- group of its own -- the same effect `script`'s pty gets for free via
-- `forkpty`'s implicit `setsid` -- and then either waits for that child or,
-- per `wrapperLifetime`, leaves without it.
--
-- Accepting both dialects is what keeps the termination tests below running
-- against whichever one the host selects, on macOS and on Linux alike. It is
-- deliberately *not* the proof that the right dialect was selected: a fake
-- that answers to both cannot fail on a wrong-flavor argv, so that proof
-- lives in the direct assertions on 'Kanban.Claude.claudeProbeArguments' and
-- 'Kanban.Claude.scriptFlavorFor' instead.
--
-- util-linux hands its @-c@ payload to a shell, so this does too, rather
-- than word-splitting the payload itself -- otherwise the fixture would
-- accept a payload no real `script` could run.
fakeScriptBody :: FilePath -> FilePath -> Bool -> ClaudeWrapperLifetime -> [ByteString.ByteString]
fakeScriptBody scriptMarkerPath childMarkerPath separateGroup wrapperLifetime =
  [ "#!/bin/bash",
    "printf '%s' \"$$\" > " <> quoted scriptMarkerPath,
    "if [ \"$2\" = '-c' ]; then",
    -- util-linux: script -q -c COMMAND FILE
    "  probeCommand=(/bin/sh -c \"$3\")",
    "else",
    -- BSD: script -q FILE COMMAND [ARG...]
    "  shift 2",
    "  probeCommand=(\"$@\")",
    "fi"
  ]
    <> ["set -m" | separateGroup]
    <> [ "\"${probeCommand[@]}\"" <> childStandardInput <> " &",
         "childPid=$!"
       ]
    <> ["set +m" | separateGroup]
    <> case wrapperLifetime of
      WrapperWaitsForClaude -> ["wait \"$childPid\""]
      -- Both leaving shapes are gone well inside the quiet period the
      -- capture waits out before it writes the exit request, so the write
      -- reliably fails, which is the failure they exist to produce.
      WrapperExitsMidSession -> ["sleep 1", "exit 0"]
      -- The child's pid marker is its own first act, so waiting for that
      -- file dates this departure from when the client came up rather than
      -- from whenever this wrapper happened to be scheduled. The settle
      -- after it is a few times what one census attempt costs -- enough
      -- that a probe censusing from launch has certainly taken one with
      -- both alive, and far short of the seconds a probe that waits for the
      -- capture would need.
      WrapperExitsAtStartup ->
        [ "while [ ! -s " <> quoted childMarkerPath <> " ]; do sleep 0.02; done",
          "sleep 0.3",
          "exit 0"
        ]
  where
    -- A real `script` is the only reader of Kanban's end: it owns the
    -- pseudo-terminal and hands the client a slave of its own, so the
    -- client never holds the pipe and the wrapper's exit alone breaks it.
    -- Here the child would inherit that very descriptor, and so would every
    -- process the dialect's payload puts in between -- which is not a fixed
    -- set. The util-linux payload runs through `/bin/sh`, and whether that
    -- shell execs the command or stays around waiting for it is the shell's
    -- own choice: bash execs, dash forks and waits, so on a dash host an
    -- `sh -c` outlives the wrapper still holding the pipe open and the
    -- write the shape exists to break instead succeeds. Handing the child
    -- its own stdin restores the production shape exactly -- one reader,
    -- the wrapper -- on any host and either dialect. The waiting shape
    -- keeps the inherited descriptor, because its child is the one that has
    -- to see the bytes Kanban writes.
    childStandardInput = case wrapperLifetime of
      WrapperWaitsForClaude -> ""
      WrapperExitsMidSession -> " </dev/null"
      WrapperExitsAtStartup -> " </dev/null"

-- | Stands in for real `claude --safe-mode --ax-screen-reader` running
-- inside `script`'s pty: records its own pid, emits whichever screen the
-- transcript names, then either drains the exact byte count Kanban's
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
fakeClaudeBody :: FilePath -> FilePath -> ClaudeSignalPolicy -> ClaudeTranscript -> [ByteString.ByteString]
fakeClaudeBody childMarkerPath termMarkerPath signalPolicy transcript =
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
    -- Every emitting shape opens with the screen-reader prompt, so the
    -- capture loop answers each of them with the same "/usage\r" and the
    -- byte count the clean-exit tail drains stays one number.
    outputLines = case transcript of
      NoTranscript -> []
      CompleteUsageTranscript ->
        [ "printf '$\\n'",
          "printf 'Current session\\n5%% used\\nResets 8:40pm (America/Los_Angeles)\\n'",
          "printf 'Current week\\n10%% used\\nResets Jul 22 at 11pm (America/Los_Angeles)\\n'"
        ]
      AuthenticationFailureTranscript ->
        [ "printf '$\\n'",
          "printf 'Not logged in\\n'"
        ]
      MissingWeeklyWindowTranscript ->
        [ "printf '$\\n'",
          "printf 'Current session\\n5%% used\\nResets 8:40pm (America/Los_Angeles)\\n'",
          "printf 'Current week\\n10%% used\\nResets 9:40pm (America/Los_Angeles)\\n'"
        ]
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
