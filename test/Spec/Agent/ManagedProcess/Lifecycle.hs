-- | The @managed agent processes@ group: signal delivery to a managed process
-- and its group, the process census, and the verified group kill.
module Spec.Agent.ManagedProcess.Lifecycle (examples) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (void)
import Data.IORef (modifyIORef, newIORef, readIORef)
import Data.Maybe (isJust)
import qualified Data.Text
import Kanban.Process
  ( IdentityPresence (..),
    ProcessIdentity (..),
    checkGroupMembershipWith,
    descendantProcesses,
    identityForPid,
    interruptManagedProcess,
    killManagedProcess,
    killVerifiedGroupWith,
    reapManagedHandle,
    managedProcess,
    matchingIdentities,
    membersStillInGroup,
    readProcessSnapshot
  )
import Spec.Support.Env (withTemporaryCacheRoot)
import Spec.Support.Expect (requireJust)
import Spec.Support.Process
  ( identityForProcess,
    managedProcessFor,
    processIdentity,
    shouldNotHaveSwept,
    withManagedShell,
    withNonLeaderShell,
    withSurvivingGroupLeader
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Process (ProcessStatus (..), getProcessStatus)
import System.Posix.Signals (sigKILL, signalProcessGroup)
import System.Process
  ( CreateProcess (..),
    createProcess,
    getPid,
    getProcessExitCode,
    proc,
    waitForProcess
  )
import System.Timeout (timeout)
import Test.Hspec

examples :: Spec
examples = do
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

    -- Issue #692. A wait that finds no child to collect used to raise out of
    -- a reap whose whole purpose was to leave nothing behind. The state is
    -- reachable from outside this handle -- a child collected by anything
    -- that is not a wait on the handle itself leaves it there -- and reaching
    -- it is not a failure of the request that got there.
    --
    -- Produced out of band rather than by racing anything, so the case is
    -- exercised every run and so that what it exercises is unambiguous:
    -- collecting the child directly leaves this process with no such child to
    -- wait for, which is the state under test. This says nothing about how
    -- two waits on one handle behave -- the test above waits twice on one
    -- handle in sequence and gets the recorded status back.
    it "reports no exit status, rather than raising, when the child is already collected" $
      withManagedShell "exit 7" $ \process -> do
        managed <- managedProcessFor process
        pid <- getPid process >>= requireJust "the managed shell reported no pid"
        getProcessStatus True False pid `shouldReturn` Just (Exited (ExitFailure 7))
        timeout 3000000 (reapManagedHandle process) `shouldReturn` Just Nothing
        -- And the primitive every caller shares survives the same outcome,
        -- which is the escape this issue was filed for.
        timeout 3000000 (killManagedProcess managed) `shouldReturn` Just ()

    -- Concurrency coverage rather than a claim about it: a wait and a
    -- termination run together against one live handle, and what is asserted
    -- is only that both finish and neither raises. Which of them collects the
    -- child, and whether the other is answered from the recorded status or
    -- finds none, is deliberately not asserted -- that is the scheduler's,
    -- and the forced case above is where the no-child outcome is actually
    -- pinned down.
    --
    -- Both outcomes are captured rather than assumed, because a thread that
    -- died is otherwise indistinguishable from one that finished, and the
    -- whole thing is bounded so a wait that never returns fails instead of
    -- hanging.
    it "runs a wait and a termination together against one live handle without either raising" $
      withManagedShell "sleep 30" $ \process -> do
        managed <- managedProcessFor process
        waiting <- newEmptyMVar
        terminating <- newEmptyMVar
        void (forkIO (try @SomeException (reapManagedHandle process) >>= putMVar waiting))
        void (forkIO (try @SomeException (killManagedProcess managed) >>= putMVar terminating))
        outcomes <- timeout 20000000 ((,) <$> takeMVar waiting <*> takeMVar terminating)
        case outcomes of
          Nothing -> expectationFailure "the concurrent wait and termination did not both finish"
          Just (Left failure, _) -> expectationFailure ("the wait raised: " <> show failure)
          Just (_, Left failure) -> expectationFailure ("the termination raised: " <> show failure)
          Just (Right _, Right ()) -> pure ()

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
      -- A second process of the same shape, in a group of its own and
      -- recorded by nothing here: the group kill below has to reach this
      -- managed group and no further.
      withSurvivingGroupLeader $ \bystanderPid ->
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
            Right identities -> do
              identityForPid childPid identities `shouldBe` Nothing
              identities `shouldNotHaveSwept` bystanderPid

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
