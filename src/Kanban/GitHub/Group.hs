-- | Terminating the process group a @gh@ leads, and proving what became of
-- it.
--
-- Every question here is asked of a pgid and answered from a fresh process
-- snapshot: is this process the leader of its own group, who is still in the
-- group, is the group empty. Nothing in this module knows about the fetch
-- guard or the durable record — it establishes the facts those are written
-- from, which is why it sits underneath them.
module Kanban.GitHub.Group
  ( confirmsOwnGroupLeadership,
    forceKillGhGroup,
    freezeThenKillOwnedGroup,
    groupCleanupPasses,
    groupConfirmedEmpty,
    groupMembers,
    ignoreIOException,
    killGhGroup,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (void)
import Data.Text (Text)
import Kanban.Process (OwnedProcessGroup (..), ProcessIdentity (..), defaultProcessSnapshot, identityForPid, killVerifiedGroup, matchingIdentities, membersStillInGroup)
import System.Posix.Signals (sigCONT, sigKILL, sigSTOP, signalProcessGroup)
import System.Process (ProcessHandle, getPid, waitForProcess)
import System.Timeout (timeout)

ignoreIOException :: IO () -> IO ()
ignoreIOException action = void (try @IOException action)

groupMembers :: Int -> [ProcessIdentity] -> [ProcessIdentity]
groupMembers groupPid = filter ((== groupPid) . processIdentityGroupPid)

-- | Whether the process named by `groupPid` is alive and is the leader of the
-- process group of the same number.
--
-- Every later question this module asks of a pgid — is the group empty, who
-- is in it, is it safe to signal — presumes the number names this fetch's own
-- group. When @create_group@ has not taken effect it does not: the child sits
-- in some inherited group, that pgid names nothing, and "the group is empty"
-- becomes true for the worst possible reason while a helper the child left
-- behind runs on somewhere this module cannot see. Establishing leadership
-- once, before anything runs, is what makes all of those questions sound.
confirmsOwnGroupLeadership :: Int -> IO (Either Text ())
confirmsOwnGroupLeadership groupPid = do
  snapshot <- defaultProcessSnapshot
  pure $ case snapshot of
    Left message -> Left ("could not confirm gh leads its own process group: " <> message)
    Right processes -> case identityForPid groupPid processes of
      Nothing -> Left "gh was gone before it could be confirmed to lead its own process group"
      Just leader
        | leader.processIdentityGroupPid == groupPid -> Right ()
        | otherwise -> Left "gh is not the leader of its own process group, so nothing it leaves behind could be accounted for"

-- | Whether a fresh snapshot shows nothing left in the group at all — not
-- the leader, and not any descendant that inherited it.
--
-- This is what stands behind a claim that the group is gone, and it is
-- deliberately about the /whole/ group: reaping the leader says nothing
-- about a credential helper still wedged in uninterruptible I\/O, which
-- would survive long enough to be running when a restarted dashboard
-- spawned its own gh. A snapshot that cannot be taken answers 'False',
-- because "could not look" is not "nothing there".
groupConfirmedEmpty :: Int -> IO Bool
groupConfirmedEmpty groupPid = do
  snapshot <- defaultProcessSnapshot
  pure $ case snapshot of
    Left _ -> False
    -- The spawned PID is asked about separately from its pgid, and that is
    -- the whole point. If @create_group@ never took effect, gh sits in some
    -- other group: signalling this pgid reached nothing, and finding this
    -- pgid unoccupied says nothing either -- it names no group at all. Only
    -- gh's own PID being absent rules that out.
    Right processes -> null (groupMembers groupPid processes) && identityForPid groupPid processes == Nothing

-- | Terminates the process group led by a spawned @gh@ and confirms nothing
-- from it survives. The group is censused first so the confirmation covers
-- every member: a credential helper, or any other child gh starts, inherits
-- the group, and cleanup tracking only the leader would call the group dead
-- while a descendant kept running. A failure carries the group it could not
-- account for, so the caller can hand exactly that to the durable record.
killGhGroup :: ProcessHandle -> IO (Either (Text, OwnedProcessGroup) Bool)
killGhGroup processHandle = do
  spawnedPid <- getPid processHandle
  case spawnedPid of
    -- No PID left to signal: the handle has already been reaped, which only
    -- happens once gh has exited and been waited on. Nothing was established
    -- here -- there was nothing left to establish it against -- and 'False'
    -- says so, because a finding another step made must not be discarded on
    -- the strength of a check that never happened.
    Nothing -> pure (Right False)
    Just pid -> escalate (fromIntegral pid) groupCleanupPasses
  where
    -- Re-censusing between escalations is what makes this about the group
    -- rather than about a list of PIDs. 'killVerifiedGroup' confirms only
    -- the identities handed to it, so a process forked into the group after
    -- the census -- during the TERM grace window, say, by a gh that then
    -- exits -- is invisible to it: every captured member would be gone, it
    -- would report success, and the newcomer would still be running. Asking
    -- the group again, and only stopping when a fresh census shows it empty,
    -- catches exactly that.
    escalate groupPid passesLeft = do
      snapshot <- defaultProcessSnapshot
      case snapshot of
        -- Without a snapshot nothing pins these PIDs, so the group is
        -- recorded uncensused: a later run may watch that pgid until it is
        -- empty, but must never signal it, because by then the PIDs could
        -- belong to anything.
        Left message -> pure (Left (message, OwnedProcessGroup groupPid [] False Nothing))
        Right processes -> case identityForPid groupPid processes of
          -- A live gh that is not its own group leader means @create_group@
          -- did not take effect, and its pgid now names processes this fetch
          -- never spawned -- so it must not be signalled. Its own identity is
          -- known and exact, though, so it is recorded uncensused and watched
          -- until that identity is gone.
          Just leader
            | leader.processIdentityGroupPid /= groupPid ->
                pure
                  ( Left
                      ( "gh is not the leader of its own process group, so its group cannot be terminated safely",
                        OwnedProcessGroup groupPid [leader] False Nothing
                      )
                  )
          _ -> case groupMembers groupPid processes of
            -- The only successful ending: the group, asked afresh, has
            -- nobody left in it -- and this time that was actually checked.
            [] -> pure (Right True)
            members
              | passesLeft <= 0 ->
                  pure (Left ("gh's process group kept gaining members faster than they could be terminated", OwnedProcessGroup groupPid members True Nothing))
              | otherwise -> do
                  result <- killVerifiedGroup groupPid members
                  case result of
                    Left message -> pure (Left (message, OwnedProcessGroup groupPid members True Nothing))
                    Right () -> escalate groupPid (passesLeft - 1)

-- | How many census-then-escalate rounds a group gets before its survivors
-- are handed to the durable record instead. More than one because a member
-- can join while the census is being acted on; bounded because something
-- forking faster than it can be killed is a problem to be recorded and
-- refused, not looped on forever.
groupCleanupPasses :: Int
groupCleanupPasses = 3

-- | SIGKILL the group outright and reap the leader.
--
-- Neither step consults the process table or the filesystem, which is
-- precisely why this is still available when both of those have failed.
-- SIGKILL cannot be caught, blocked, or deferred, so it reaches every member
-- the group currently has, and waiting on the leader — this fetch's own
-- child — clears it out of the process table rather than leaving a zombie
-- behind. The wait is bounded, so a process wedged in an uninterruptible
-- state cannot strand the refresh.
--
-- Delivering the signal is all this does. Whether it worked is a separate
-- question, and 'groupConfirmedEmpty' is the only thing that answers it.
forceKillGhGroup :: ProcessHandle -> Maybe Int -> IO ()
forceKillGhGroup processHandle spawnedPid = do
  mapM_ (ignoreIOException . signalProcessGroup sigKILL . fromIntegral) spawnedPid
  void (timeout forcedReapTimeoutMicros (try @IOException (waitForProcess processHandle)))

forcedReapTimeoutMicros :: Int
forcedReapTimeoutMicros = 5 * 1000 * 1000

-- | Empties a process group that has just been proven to be this
-- repository's, by freezing it before looking at it.
--
-- The problem this solves is that a census and a signal cannot be made
-- simultaneous. 'killVerifiedGroup' answers only for the identities it was
-- handed, and TERM invites exactly the behaviour that defeats that: a member
-- whose handler forks a replacement and exits leaves a process that is
-- genuinely ours but appears in no list, and by the time any census could
-- notice it, the member that proved ownership is gone. Polling faster does
-- not fix it -- a fork and an exit are quicker than a process listing.
--
-- SIGSTOP does fix it, because it cannot be caught, blocked, or handled.
-- Once the group is frozen it cannot fork, cannot exit, and therefore cannot
-- empty, so its pgid cannot be reissued: the census that follows is complete
-- and every member in it is provably ours. SIGKILL then applies to that exact
-- set, and is equally uncatchable, so nothing survives to be missed.
--
-- Reclaim is where this belongs and TERM is not: this group was already asked
-- to stop gracefully by the fetch that abandoned it. Skipping the courtesy
-- second time is also what stops a TERM handler from forking anything new.
freezeThenKillOwnedGroup :: Int -> [ProcessIdentity] -> IO (Either Text [ProcessIdentity])
freezeThenKillOwnedGroup groupPid known = do
  ignoreIOException (signalProcessGroup sigSTOP (fromIntegral groupPid))
  frozen <- defaultProcessSnapshot
  case frozen of
    Left message -> release ("could not census the frozen gh process group: " <> message)
    Right processes
      -- Ownership was proven from a snapshot taken before the freeze, and the
      -- group could have emptied and its pgid been reissued in between. The
      -- frozen census is the one that decides: nothing can join or leave the
      -- group now, so a recorded identity still sitting in this exact group
      -- is a fact rather than a recollection. Without one, the group belongs
      -- to somebody else and is released untouched.
      | null (membersStillInGroup groupPid processes known) ->
          release "the gh process group was no longer this repository's once frozen, so it was left alone"
      | otherwise -> killFrozen (groupMembers groupPid processes)
  where
    -- Nothing was killed, so nothing may be left frozen either.
    release message = do
      ignoreIOException (signalProcessGroup sigCONT (fromIntegral groupPid))
      pure (Left message)

    killFrozen members = do
      ignoreIOException (signalProcessGroup sigKILL (fromIntegral groupPid))
      threadDelay terminationGraceMicros
      settled <- defaultProcessSnapshot
      pure $ case settled of
        Left message -> Left ("could not confirm the gh process group was emptied: " <> message)
        Right after
          | null (matchingIdentities after members) && null (groupMembers groupPid after) -> Right members
          | otherwise -> Left "the gh process group did not empty after SIGKILL"

terminationGraceMicros :: Int
terminationGraceMicros = 750 * 1000
