-- | The exclusive authority one process takes over one repository.
--
-- Kanban's durable @gh@ process-group record is a shared file: two boards on
-- one repository resolve one 'Kanban.Cache.ghGroupRecordPath' and guard it
-- with an @MVar@ each, which is no guard at all across processes. The lease
-- here is the authority that closes that — a repository-keyed lock a second
-- process cannot take while a first holds it.
--
-- Four properties are the whole of it, and each is a decision rather than an
-- accident:
--
--   * /Repository-keyed/. The lock file is
--     'Kanban.Cache.repositoryLeasePath', which resolves from the
--     repository's identity and the XDG cache root and from nothing else. Two
--     boards on one repository contend; two repositories do not. Serialising
--     the machine instead would stop one process from watching two
--     repositories at once, which is a thing it is meant to do.
--
--   * /Non-blocking/. 'setLock' is POSIX @F_SETLK@, which reports a conflict
--     rather than waiting for it; 'System.Posix.IO.waitToSetLock' is
--     deliberately not used. A board that cannot have the repository is told
--     so immediately, because the answer it needs is whose it is, not a queue
--     position behind a process that may outlive it.
--
--   * /Held for as long as it is held/. The descriptor the lock lives on is
--     opened by 'acquireRepositoryLease' and closed by
--     'releaseRepositoryLease' and by nothing else. POSIX releases /every/
--     lock a process holds on a file the moment that process closes /any/
--     descriptor referring to it, so an unrelated open-and-close of this path
--     anywhere in the process would drop a held lease silently. That is why
--     the path carries no payload, why nothing outside this module is given
--     the descriptor, and why 'heldLeases' below keeps exactly one of them per
--     path.
--
--   * /No staleness rule of its own/. There is no PID file, no heartbeat, no
--     timeout, and no way for one process to reclaim, break, or remove
--     another's lease. A holder that dies — for any reason, including
--     @SIGKILL@ — has its locks released by the kernel, which is the whole
--     recovery story. The lock file is created when absent and never unlinked:
--     unlinking it would let the next process lock a fresh inode under the
--     same name while the first still held the old one.
--
-- Contention is a distinct outcome from failure, not a shade of it.
-- 'acquireRepositoryLease' returns 'LeaseHeld' for a lease already held and
-- for the conflict @F_SETLK@ itself reported; a cache root that cannot be
-- created, a file that cannot be opened, and any other locking failure are
-- 'LeaseUnusable', so no caller can ever announce that another board holds the
-- repository because the cache root was read-only.
--
-- The kernel cannot answer \"is this repository already taken?\" on its own,
-- which is why 'heldLeases' exists. A POSIX record lock belongs to the
-- /process/: the process that already holds one is granted it again rather
-- than refused, so without a register two boards inside one process would each
-- be handed a lease, and the first of them to let go would free the repository
-- while the other still believed it held it — the very defect this authority
-- exists to close, moved indoors. The register is a module-level value rather
-- than something a caller creates because a caller-created one is exactly the
-- mistake being fixed: @newGhRecordLock@ mints an 'Control.Concurrent.MVar.MVar'
-- per board coordinator, and two coordinators therefore share no lock at all.
module Kanban.Repository.Lease
  ( LeaseAcquisition (..),
    RepositoryLease,
    acquireRepositoryLease,
    leaseFile,
    releaseRepositoryLease,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Exception (IOException, mask_, onException, try)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Foreign.C.Error (Errno (Errno), eACCES, eAGAIN, eWOULDBLOCK)
import Foreign.C.Types (CInt)
import GHC.IO.Exception (ioe_errno)
import Kanban.Cache (repositoryLeasePath)
import Kanban.Domain (Repository)
import Kanban.Paths (createPrivateDirectory)
import System.Directory (XdgDirectory (XdgCache))
import System.FilePath (takeDirectory)
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files (setFdMode)
import System.Posix.IO
  ( FileLock,
    LockRequest (Unlock, WriteLock),
    OpenFileFlags (..),
    OpenMode (ReadWrite),
    closeFd,
    defaultFileFlags,
    openFd,
    setLock,
  )
import System.Posix.Types (Fd)

-- | A lease this process holds.
--
-- Opaque, and deliberately not the descriptor. The descriptor is the lock —
-- closing it releases every lock this process has on the file, wherever the
-- close happens — so it lives in 'heldLeases', where there is exactly one of
-- it per path and only 'releaseRepositoryLease' can reach it. What the holder
-- carries is the name of what it holds: 'leaseFile' is exported because naming
-- the path is useful in a diagnostic and cannot drop anything.
data RepositoryLease = RepositoryLease
  { leaseFile :: FilePath,
    leaseToken :: Integer
  }
  deriving stock (Eq, Show)

-- | Every lease path this process holds, the descriptor it is held on, and
-- which acquisition holds it.
--
-- Process-wide because that is the scope a POSIX record lock has. It is both
-- the register that refuses a second acquisition of a repository this process
-- already holds and the sole owner of the descriptors.
--
-- The token is what makes a 'RepositoryLease' name an /acquisition/ rather
-- than a path. Paths repeat: a repository released and taken again resolves
-- the same file, and a stale lease value from the first acquisition would
-- otherwise release the second one — the same silent release the register
-- exists to stop, arriving by the door the register itself opened. Only the
-- acquisition the register still names can give the lease up; every other
-- release is a no-op.
data LeaseRegister = LeaseRegister
  { registerNextToken :: !Integer,
    registerHeld :: !(Map FilePath (Integer, Fd))
  }

heldLeases :: MVar LeaseRegister
heldLeases = unsafePerformIO (newMVar (LeaseRegister 0 Map.empty))
{-# NOINLINE heldLeases #-}

-- | How an attempt on a repository's lease turned out.
--
-- Three cases rather than a success and a message, because the difference
-- between the second and the third is the difference between "another board
-- has this repository" and "this machine's cache is broken", and a caller
-- that had to tell them apart by reading text would eventually tell a user the
-- first when the truth was the second.
data LeaseAcquisition
  = -- | Taken. Held until 'releaseRepositoryLease' or this process exits.
    LeaseAcquired RepositoryLease
  | -- | The lease on this path is already held — by another process, or by
    -- a board inside this one. Nothing waited.
    LeaseHeld FilePath
  | -- | The lease could not be established at all, for a reason that is not
    -- contention: the directory could not be created, the file could not be
    -- opened, or the lock failed for something other than a conflict.
    LeaseUnusable FilePath Text
  deriving stock (Eq, Show)

-- | Takes the repository's lease if it is free, and reports rather than waits
-- if it is not.
--
-- The whole file is locked from offset zero, which is the conventional
-- whole-file record lock and the region a later 'System.Posix.IO.getLock'
-- must ask about to find this holder.
--
-- Every path that does not hand back a live lease closes the descriptor it
-- opened. The body runs under 'mask_' so that no asynchronous exception can
-- arrive between the open and the decision about what to do with it: without
-- it, a lease could be taken and then abandoned still locked, which nothing
-- short of process exit would undo.
--
-- Resolving the path is outside all of that, exactly as every other caller of
-- a "Kanban.Cache" path does it: a failure there is a failure to work out
-- /which/ file, and both of the outcomes that report a failure name the file
-- they were talking about.
acquireRepositoryLease :: Repository -> IO LeaseAcquisition
acquireRepositoryLease repository = do
  path <- repositoryLeasePath repository
  modifyMVar heldLeases $ \register -> mask_ $
    -- Asked before the kernel is, because the kernel would say yes. The whole
    -- attempt is inside the register's own lock, so two threads cannot both
    -- find the path free and both be granted it.
    if Map.member path register.registerHeld
      then pure (register, LeaseHeld path)
      else do
        attempt <- try @IOException $ do
          createPrivateDirectory XdgCache (takeDirectory path)
          descriptor <- openLeaseFile path
          taken <- try @IOException (setLock descriptor wholeFileLock) `onException` closeFd descriptor
          case taken of
            Right () -> pure (Right descriptor)
            -- The close is allowed to fail without changing the answer. What
            -- the caller must not be told is that the lock failed for some
            -- reason other than a conflict when a conflict is precisely what
            -- happened, and the descriptor being closed here holds nothing
            -- either way -- the lock it was opened for is the one refused.
            Left conflict -> do
              _ <- try @IOException (closeFd descriptor)
              pure (Left conflict)
        pure $ case attempt of
          -- Raised by the directory creation or the open, never by the lock:
          -- the lock's own failure is the 'Left' below. Requirement: an
          -- unwritable cache root is never reported as another board holding
          -- the repository.
          Left exception -> (register, LeaseUnusable path (diagnostic exception))
          Right (Right descriptor) ->
            ( LeaseRegister
                (register.registerNextToken + 1)
                (Map.insert path (register.registerNextToken, descriptor) register.registerHeld),
              LeaseAcquired (RepositoryLease path register.registerNextToken)
            )
          Right (Left exception)
            | conflictingLock exception -> (register, LeaseHeld path)
            | otherwise -> (register, LeaseUnusable path (diagnostic exception))

-- | Gives the lease up, making it immediately available to another process.
--
-- The unlock is the explicit half and the close is the half that cannot fail
-- to work: POSIX releases the process's locks on the file when the descriptor
-- goes, so a refused or unsupported @F_SETLK@ @Unlock@ still leaves the lease
-- free. Masked so that the descriptor is closed even if this is interrupted,
-- and the unlock's own failure is swallowed for the same reason — it would
-- otherwise skip the close and strand the lease for the life of the process.
--
-- A lease already given up is a no-op rather than a second close, and so is a
-- lease whose path the register now holds under a later acquisition. Both are
-- the same mistake: the descriptor number the stale value was held on may by
-- then belong to something else entirely — including this repository's next
-- lease — and closing it would be the silent release this authority exists to
-- stop, arriving from the caller's side.
--
-- The entry is dropped only once the close has been made: a close that failed
-- leaves the lease registered, because forgetting a descriptor that may still
-- be holding the lock is the worse of the two answers.
releaseRepositoryLease :: RepositoryLease -> IO ()
releaseRepositoryLease lease = modifyMVar_ heldLeases $ \register -> mask_ $
  case Map.lookup lease.leaseFile register.registerHeld of
    Just (token, descriptor) | token == lease.leaseToken -> do
      _ <- try @IOException (setLock descriptor releaseWholeFile)
      closeFd descriptor
      pure register {registerHeld = Map.delete lease.leaseFile register.registerHeld}
    _ -> pure register

-- | Opens the lock file, creating it private.
--
-- The mode is forced through the descriptor on every acquisition for the
-- reasons 'Kanban.Cache.usageCacheLockPath' 's opener gives: an @O_CREAT@ mode
-- is still reduced by the process umask, a file an earlier release left at
-- another mode is not re-created by the open that finds it, and setting it on
-- the descriptor rather than the path keeps a concurrent replacement of the
-- name from receiving the chmod.
--
-- Close-on-exec matters more here than anywhere else in this application. A
-- POSIX record lock belongs to the process, and a descriptor inherited across
-- @exec@ keeps the file open in the child — so a solve worker or a @gh@ run
-- spawned while a board held its lease would keep that file open for its own
-- lifetime, and the board's own release would no longer free the lock the
-- child's descriptor still refers to.
openLeaseFile :: FilePath -> IO Fd
openLeaseFile path = do
  descriptor <- openFd path ReadWrite defaultFileFlags {creat = Just 0o600, cloexec = True}
  setFdMode descriptor 0o600 `onException` closeFd descriptor
  pure descriptor

wholeFileLock, releaseWholeFile :: FileLock
wholeFileLock = (WriteLock, AbsoluteSeek, 0, 0)
releaseWholeFile = (Unlock, AbsoluteSeek, 0, 0)

-- | Whether the failure @F_SETLK@ reported is another process's lock.
--
-- Decided on @errno@ rather than on the message, because the message is the
-- generic one GHC derives from the same @errno@ — macOS renders the conflict
-- as @resource exhausted (Resource temporarily unavailable)@, which no
-- reasonable text rule would classify as contention.
--
-- POSIX allows @F_SETLK@ to report a conflict as either @EACCES@ or @EAGAIN@
-- and implementations differ: macOS raises @EAGAIN@, Linux may raise either.
-- @EWOULDBLOCK@ is the same value as @EAGAIN@ on both, and is named for the
-- reader rather than for the comparison.
--
-- Everything else is left to 'LeaseUnusable'. Nothing else this function
-- classifies can reach it: it is applied only to what 'setLock' itself threw,
-- so an @EACCES@ from opening the file — the one errno a conflict shares with
-- an ordinary permission failure — is never offered to it.
conflictingLock :: IOException -> Bool
conflictingLock exception = maybe False (`elem` conflictErrnos) (ioe_errno exception)

conflictErrnos :: [CInt]
conflictErrnos = [code | Errno code <- [eACCES, eAGAIN, eWOULDBLOCK]]

diagnostic :: IOException -> Text
diagnostic exception = Text.pack (show exception)
