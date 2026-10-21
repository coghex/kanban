-- | Managed process and fake-controller harnesses.
module Spec.Support.Process
  ( withSurvivingGroupLeader,
    withVacatedGroupLeader,
    withNonLeaderProcess,
    withManagedShell,
    managedProcessFor,
    withNonLeaderShell,
    processIdentity,
    identityForProcess,
    shouldRecordASweptProcess,
    shouldNotHaveSwept,
    readRecordedPid
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, try)
import Control.Monad (void)
import Data.List (dropWhileEnd)
import Data.Text (Text)
import qualified Data.Text
import Kanban.Process
  ( ManagedProcess,
    ProcessIdentity (..),
    identityForPid,
    killManagedProcess,
    reapManagedHandle,
    managedProcess,
    readProcessSnapshot
  )
import Spec.Support.Env (ignoringIOException)
import Spec.Support.Expect (requireJust)
import System.Posix.Signals (sigKILL, signalProcess, signalProcessGroup)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
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
    -- Reaped through the primitive that tolerates a child something else
    -- already took. A test may deliberately reap one out from under its
    -- handle (issue #692), and a teardown that raised on finding no child
    -- would fail the example that proved the production path survives it.
    stop process = do
      managedProcessFor process >>= killManagedProcess
      void (timeout 3000000 (reapManagedHandle process))

managedProcessFor :: ProcessHandle -> IO ManagedProcess
managedProcessFor process = fst <$> managedProcess process

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
      void (timeout 3000000 (reapManagedHandle process))

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

-- | The PID a fixture recorded for itself. Read only after the invocation
-- under test has returned, by which point the shell has long since written
-- it.
readRecordedPid :: FilePath -> IO Int
readRecordedPid path = do
  written <- readFile path
  requireJust ("fixture never recorded a PID in " <> path) (readMaybe (dropWhileEnd (== '\n') written))

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
