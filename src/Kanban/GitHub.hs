module Kanban.GitHub
  ( -- 'FetchState' and 'graphqlArguments' are internal, exported so the
    -- suite can assert the exact argv handed to gh without a live request.
    FetchState (..),
    GhCleanupFailure (..),
    GhCleanupGuard (..),
    ghBehindBarrier,
    confirmsOwnGroupLeadership,
    groupConfirmedEmpty,
    GhFailurePhase (..),
    GhFetchGuard,
    GitHubResult (..),
    decodeGitHubItems,
    fetchGitHubSnapshot,
    ghFailureKind,
    ghFetchCleanupFailure,
    graphqlArguments,
    newGhFetchGuard,
    paginationDecision,
    reclaimRecordedGhGroups,
    snapshotWarnings,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO, forkIOWithUnmask, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Exception (Exception, IOException, bracketOnError, finally, throwIO, try, uninterruptibleMask_)
import Control.Monad (unless, void, when)
import Data.Aeson
  ( FromJSON (parseJSON),
    Object,
    Value,
    eitherDecode,
    withObject,
    (.:),
    (.:?),
    (.!=),
  )
import Data.Aeson.Key (Key)
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (getCurrentTime)
import Kanban.Cache (GhGroupRecordLoad (..), loadGhGroupRecord, removeGhGroupRecord, writeGhGroupRecord)
import Kanban.Config (LimitsConfig (..))
import Kanban.Domain
import Kanban.Process (OwnedProcessGroup (..), ProcessIdentity (..), defaultProcessSnapshot, identityForPid, killVerifiedGroup, matchingIdentities, membersStillInGroup)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Tracker (trackerDiagnosticsForIssue)
import System.Exit (ExitCode (..))
import System.Directory (findExecutable)
import System.IO (Handle, hClose, hFlush, hPutStrLn)
import System.IO.Error (doesNotExistErrorType, isDoesNotExistError, isPermissionError, mkIOError)
import System.Posix.Signals (sigCONT, sigKILL, sigSTOP, signalProcess, signalProcessGroup)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (CreatePipe),
    createProcess,
    getPid,
    proc,
    waitForProcess,
  )
import System.Timeout (timeout)

data GitHubResult = GitHubResult
  { githubSnapshot :: RepoSnapshot,
    githubWarnings :: [Text]
  }
  deriving stock (Eq, Show)

data PageInfo = PageInfo
  { pageHasNext :: Bool,
    pageEndCursor :: Maybe Text
  }
  deriving stock (Eq, Show)

data Connection item = Connection
  { connectionNodes :: [item],
    connectionPageInfo :: PageInfo
  }
  deriving stock (Eq, Show)

data GitHubPage = GitHubPage
  { pageIssues :: Maybe (Connection Issue),
    pagePullRequests :: Maybe (Connection PullRequest)
  }
  deriving stock (Eq, Show)

data FetchState = FetchState
  { fetchedIssues :: [Issue],
    fetchedPullRequests :: [PullRequest],
    issueCursor :: Maybe Text,
    pullRequestCursor :: Maybe Text,
    fetchMoreIssues :: Bool,
    fetchMorePullRequests :: Bool,
    issuesTruncated :: Bool,
    pullRequestsTruncated :: Bool
  }

-- | One decoded rollup context. 'checkContextKey' is the deduplication
-- identity (app/name, or status creator/context), which is deliberately not
-- the name shown to the user: 'checkContextName' keeps the plain name GitHub
-- reported so the details overlay can list it.
data CheckContext = CheckContext
  { checkContextKey :: Text,
    checkContextName :: Text,
    checkContextRecency :: CheckRecency,
    checkContextState :: CheckState
  }
  deriving stock (Eq, Show)

-- | Where a rollup context ranks among the others sharing its dedup key, from
-- oldest to newest. A missing timestamp gets a rank of its own rather than the
-- empty string it used to be defaulted to, because the two context kinds mean
-- opposite things by one: a check run with neither @startedAt@ nor
-- @completedAt@ is a rerun GitHub has only just been asked for, which is
-- exactly the entry the dedup exists to prefer over the failure it supersedes,
-- while a status context with no @createdAt@ told us nothing about its age and
-- must not displace one that did. The @check:@ and @status:@ prefixes
-- 'parseCheckContext' builds keys from keep the kinds in separate dedup keys,
-- so the two rules never compete with each other.
data CheckRecency
  = -- | A status context that arrived without a @createdAt@.
    RecencyUndated
  | -- | The context's own timestamp. GitHub reports fixed-format UTC ISO-8601,
    -- so comparing the text lexicographically orders them chronologically.
    RecencyAt Text
  | -- | A check run that has neither started nor completed.
    RecencyUnstarted
  deriving stock (Eq, Ord, Show)

pageLimit :: Int
pageLimit = 100

-- | Records whether the @gh@ process group an abandoned board fetch left
-- running could actually be confirmed dead.
--
-- 'fetchGitHubSnapshot' is meant to be run under 'System.Timeout.timeout',
-- so it is abandoned by an asynchronous exception rather than by returning a
-- value: the unwinding is where the still-running @gh@ gets cleaned up, and
-- this is the only channel through which the outcome of that cleanup can
-- reach the caller. 'Just' means the group may still be live, so the caller
-- must not report an ordinary clean timeout.
newtype GhFetchGuard = GhFetchGuard (IORef (Maybe GhCleanupFailure))

-- | A cleanup that could not confirm its @gh@ group is gone.
data GhCleanupFailure = GhCleanupFailure
  { ghCleanupMessage :: Text,
    ghCleanupGuard :: GhCleanupGuard
  }
  deriving stock (Eq, Show)

-- | What is keeping a possibly-live @gh@ from being overlapped, now that its
-- death could not be confirmed.
--
-- There is deliberately no third state for "killed but unproven". Whether a
-- signal was sent is not evidence; only a fresh snapshot showing the group
-- gone is, and a cleanup that has that does not report a failure at all. So
-- the only question left here is whether the guard outlives this dashboard.
data GhCleanupGuard
  = -- | The group is on disk. Any later fetch re-checks it before spawning
    -- anything, in this dashboard or one started long afterwards.
    GuardRecorded
  | -- | Nothing could be recorded. This dashboard's refusal to refresh is all
    -- that remains, and it is worth nothing once the dashboard exits — so
    -- this is the one case that must never suggest a restart.
    GuardInMemoryOnly
  deriving stock (Eq, Show)

newGhFetchGuard :: IO GhFetchGuard
newGhFetchGuard = GhFetchGuard <$> newIORef Nothing

ghFetchCleanupFailure :: GhFetchGuard -> IO (Maybe GhCleanupFailure)
ghFetchCleanupFailure (GhFetchGuard cleanupFailure) = readIORef cleanupFailure

setCleanupFailure :: GhFetchGuard -> GhCleanupFailure -> IO ()
setCleanupFailure (GhFetchGuard cleanupFailure) = writeIORef cleanupFailure . Just

clearCleanupFailure :: GhFetchGuard -> IO ()
clearCleanupFailure (GhFetchGuard cleanupFailure) = writeIORef cleanupFailure Nothing

fetchGitHubSnapshot :: GhFetchGuard -> LimitsConfig -> WorkflowConfig -> Repository -> IO (Either ProviderError GitHubResult)
fetchGitHubSnapshot guard limits workflowConfig repository = do
  -- Reclaim signals process groups and then confirms what it did, so it is
  -- held to the same rule as cleanup: the refresh timer may not land between
  -- those halves. Without that, a timeout arriving mid-freeze would leave the
  -- record on disk, the guard unset, and the board publishing an ordinary
  -- timeout over a group nothing had established anything about.
  -- Reclaim publishes its own outcome from inside the shield rather than
  -- having it read off afterwards. A refresh timeout pending while this waits
  -- is delivered the instant the mask lifts -- before any code out here could
  -- run -- so anything decided in between would be lost and the refresh would
  -- report an ordinary timeout over a record it had just failed to clear.
  reclaimed <- uninterruptiblyBounded reclaimInterrupted (reclaimRecordedGhGroups guard repository)
  case reclaimed of
    Left message -> pure (Left (ProviderError RequestFailed message))
    Right () -> fetchPages initialState
  where
    reclaimInterrupted = Left "reclaiming a gh process group left by an earlier GitHub refresh did not run to completion"

    initialState = FetchState [] [] Nothing Nothing True True False False

    fetchPages state
      | not state.fetchMoreIssues && not state.fetchMorePullRequests = do
          fetchedAt <- getCurrentTime
          let repoSnapshot =
                RepoSnapshot
                  state.fetchedIssues
                  state.fetchedPullRequests
                  fetchedAt
                  state.issuesTruncated
                  state.pullRequestsTruncated
          pure (Right (GitHubResult repoSnapshot (snapshotWarnings limits workflowConfig repoSnapshot)))
      | otherwise = do
          pageResult <- fetchPage guard limits repository state
          case pageResult of
            Left providerError -> pure (Left providerError)
            Right page -> case advanceState limits state page of
              Left providerError -> pure (Left providerError)
              Right nextState -> fetchPages nextState

decodeGitHubItems :: LazyByteString.ByteString -> Either String ([Issue], [PullRequest])
decodeGitHubItems input = do
  page <- (eitherDecode input :: Either String GitHubPage)
  pure
    ( maybe [] (.connectionNodes) page.pageIssues,
      maybe [] (.connectionNodes) page.pagePullRequests
    )

fetchPage :: GhFetchGuard -> LimitsConfig -> Repository -> FetchState -> IO (Either ProviderError GitHubPage)
fetchPage guard limits repository state = do
  -- The unwritable-guard failure is deliberately not folded in with the
  -- IOExceptions below: those mean gh could not be run, while this means gh
  -- ran and was then stopped again because nothing durable could account for
  -- it. Reporting it as a missing executable would send the user looking in
  -- entirely the wrong place.
  guarded <- try @GhFetchAborted (try @GhProcessFailed (runGh guard repository (graphqlArguments limits repository state)))
  pure $ case guarded of
    Left (GhGuardUnwritable message) ->
      Left
        ProviderError
          { providerErrorKind = RequestFailed,
            providerErrorMessage = "GitHub refresh could not record the gh process it started (" <> message <> "), so it was stopped again"
          }
    Left (GhGroupUnresolved message) ->
      Left
        ProviderError
          { providerErrorKind = RequestFailed,
            providerErrorMessage = "GitHub refresh left a gh process group it could not confirm stopped (" <> message <> ")"
          }
    Right (Left (GhProcessFailed phase exception)) ->
      Left
        ProviderError
          { providerErrorKind = ghFailureKind phase exception,
            providerErrorMessage = Text.pack (show exception)
          }
    Right (Right (ExitFailure _, _, standardError)) ->
      let stderrText = decodeGhOutput standardError
       in Left
            ProviderError
              { providerErrorKind = classifyFailure stderrText,
                providerErrorMessage = compactError stderrText
              }
    Right (Right (ExitSuccess, standardOutput, _)) ->
      case eitherDecode (LazyByteString.fromStrict (TextEncoding.encodeUtf8 (decodeGhOutput standardOutput))) of
        Left message ->
          Left
            ProviderError
              { providerErrorKind = InvalidResponse,
                providerErrorMessage = "GitHub returned invalid JSON: " <> Text.pack message
              }
        Right page -> Right page

-- | Runs one page's @gh@ as the leader of its own process group, so a fetch
-- that gets abandoned can be cleaned up as a group rather than as a lone
-- child. 'readProcessWithExitCode', which this replaces, terminates only the
-- direct child and never confirms it exited: a @gh@ wedged on network I\/O
-- and ignoring TERM, or one that has spawned a credential helper, could
-- outlive the timeout that reported it dead and still be running when the
-- next refresh starts another one.
--
-- Every 'IOException' the run can raise leaves here tagged with the half it
-- came out of, because that — not the exception's own text — is what decides
-- whether the user is told @gh@ is missing. Resolution and spawning are the
-- only places where a failure can still mean "there is no @gh@ to run"; once
-- the child exists, @gh@ demonstrably launched, and an exception is about
-- this run rather than about the installation.
runGh :: GhFetchGuard -> Repository -> [String] -> IO (ExitCode, ByteString.ByteString, ByteString.ByteString)
runGh guard repository arguments = afterLaunch $ do
  resolved <- duringLaunch (findExecutable "gh")
  case resolved of
    Nothing -> duringLaunch (ioError (mkIOError doesNotExistErrorType "gh" Nothing (Just "gh")))
    Just ghPath -> bracketOnError (duringLaunch (createProcess (ghProcess ghPath))) cleanUp run
  where
    -- 'GhProcessFailed' is not an 'IOException', so a launch failure tagged
    -- here passes straight back out through 'afterLaunch' rather than being
    -- caught and retagged as one. That is what keeps the outer tag total —
    -- covering the cleanup handler too — without it ever overwriting a phase
    -- already established.
    duringLaunch = taggedAs GhLaunching
    afterLaunch = taggedAs GhRunning

    taggedAs phase action = try @IOException action >>= either (throwIO . GhProcessFailed phase) pure

    cleanUp spawned = uninterruptibleCleanup (abandonGh guard repository spawned)

    ghProcess ghPath =
      (uncurry proc (ghBehindBarrier ghPath arguments))
        { std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

    -- The child exists but has not run @gh@ yet, and cannot until this
    -- releases it. So the durable guard is not merely written early -- there
    -- is no instant at which a @gh@ is running that the record does not
    -- already cover. Losing the dashboard anywhere in here closes the pipe,
    -- the barrier reads EOF, and the child exits without ever having
    -- executed anything.
    run spawned@(input, _, _, _) = do
      registered <- registerSpawnedGh repository spawned
      case registered of
        Left message -> throwIO (GhGuardUnwritable message)
        -- The PID comes from the registration, captured while the child was
        -- still unreaped: 'collect' waits on the handle, and 'getPid' goes
        -- 'Nothing' the moment it does, which would leave the entry behind.
        Right groupPid -> do
          -- Asked while the child is alive and still parked on the barrier,
          -- which is the one moment it is guaranteed observable and has done
          -- nothing yet. Everything downstream reasons about the pgid as if
          -- it named this fetch's group; that is only true if the child
          -- actually leads it, and this is where that becomes a fact rather
          -- than an assumption.
          --
          -- Refusing here costs nothing, because gh has not run: there are no
          -- descendants to account for and nothing to clean up but the parked
          -- shell itself, which is killed by PID -- the one identity that is
          -- meaningful when the group is not ours.
          leads <- confirmsOwnGroupLeadership groupPid
          case leads of
            Left message -> do
              ignoreIOException (signalProcess sigKILL (fromIntegral groupPid))
              void (try @IOException (waitForProcess processHandleOf))
              throwIO (GhGroupUnresolved message)
            Right () -> do
              released <- releaseBarrier input
              case released of
                Left message -> throwIO (GhGuardUnwritable message)
                Right () -> collect groupPid spawned
      where
        (_, _, _, processHandleOf) = spawned

    -- Writing the go-ahead is also what hands gh its (immediately closed)
    -- standard input, so the barrier costs the child nothing it would
    -- otherwise have had.
    releaseBarrier Nothing = pure (Left "gh was started without a standard input to release it through")
    releaseBarrier (Just input) = do
      written <- try @IOException (hPutStrLn input "" >> hFlush input)
      pure (first (Text.pack . show) written)

    collect groupPid (input, output, errors, processHandle) = do
      mapM_ (ignoreIOException . hClose) input
      standardOutput <- drain output
      standardError <- drain errors
      -- Both pipes are drained to EOF before the exit status is collected,
      -- exactly as 'readProcessWithExitCode' did, so a response larger than
      -- the pipe buffer cannot deadlock gh against a reader that has not run
      -- yet.
      capturedOutput <- takeMVar standardOutput >>= either throwIO pure
      capturedError <- takeMVar standardError >>= either throwIO pure
      settled <- settleGroup groupPid
      case settled of
        -- gh has exited and nothing it led is left, so the guard covering it
        -- has nothing left to cover.
        Right () -> do
          exitCode <- waitForProcess processHandle
          dropGhGroup repository groupPid
          pure (exitCode, capturedOutput, capturedError)
        -- A member outlived the process that led it -- closing the pipes is
        -- not exiting, and a descendant can do the first without the second.
        -- The record stays, naming what is left, so the next fetch reclaims
        -- it with the full ownership machinery instead of starting a gh
        -- beside it.
        --
        -- The finding is published to the guard before the handle is reaped,
        -- and that order is deliberate: reaping is exactly what makes this
        -- group unfindable from the cleanup path, where 'getPid' turns
        -- 'Nothing' and there is no longer anything to census. A refresh
        -- timeout arriving from here on would otherwise find nothing amiss
        -- and report an ordinary timeout over a descendant this already knew
        -- about.
        Left (message, survivors) -> do
          setCleanupFailure guard (GhCleanupFailure message GuardInMemoryOnly)
          void (recordGhGroup repository (OwnedProcessGroup groupPid survivors True))
          recorded <- ghGroupIsRecorded repository groupPid
          setCleanupFailure guard (GhCleanupFailure message (if recorded then GuardRecorded else GuardInMemoryOnly))
          -- Deliberately not reaped. Reaping is what frees the PID and with
          -- it the pgid, and the cleanup this throw is about to trigger needs
          -- both: with them it can escalate against the survivors and prove
          -- what became of them, and only a cleanup that proves the group
          -- empty is allowed to take this finding back off the guard.
          throwIO (GhGroupUnresolved message)

    -- Establishes what became of the group, entirely before the handle is
    -- reaped. That ordering is the whole argument: until the leader is waited
    -- on, its PID stays allocated, so the pgid cannot be reissued and
    -- everything the census finds in it is genuinely this fetch's.
    --
    -- Waiting for the leader to leave the live process table first matters
    -- just as much as the census that follows. A leader that is still running
    -- can still fork, so a census taken while it lives says nothing about a
    -- descendant appearing a moment later; one taken after it has exited --
    -- but before it is reaped -- cannot be overtaken that way. A zombie is
    -- excluded from the table yet still holds its PID, which is exactly the
    -- window this needs.
    settleGroup groupPid = do
      departed <- awaitLeaderDeparture groupPid leaderDeparturePolls
      case departed of
        Left message -> pure (Left (message, []))
        Right () -> do
          snapshot <- defaultProcessSnapshot
          pure $ case snapshot of
            -- No census is not an empty group. Refusing here costs a refresh;
            -- assuming would cost the guarantee.
            Left message -> Left ("could not confirm gh's process group was empty: " <> message, [])
            Right processes -> case groupMembers groupPid processes of
              [] -> Right ()
              survivors ->
                Left
                  ( "gh exited but "
                      <> Text.pack (show (length survivors))
                      <> " process(es) it led (pgid "
                      <> Text.pack (show groupPid)
                      <> ") are still running",
                    survivors
                  )

    awaitLeaderDeparture groupPid pollsLeft = do
      snapshot <- defaultProcessSnapshot
      case snapshot of
        Left message -> pure (Left ("could not watch for gh's exit: " <> message))
        Right processes
          | identityForPid groupPid processes == Nothing -> pure (Right ())
          | pollsLeft <= (0 :: Int) -> pure (Left "gh closed its output but was still running when its process group had to be settled")
          | otherwise -> threadDelay leaderDeparturePollMicros >> awaitLeaderDeparture groupPid (pollsLeft - 1)

    -- Each reader owns its handle for the handle's whole life, including
    -- closing it. Closing from here instead would mean closing a handle a
    -- reader thread may still be blocked on, which takes the handle's lock
    -- and would hang the very cleanup that has to finish promptly.
    --
    -- Bytes, not locale-decoded text. 'hGetContents'' would have run @gh@'s
    -- output through whatever encoding the environment happened to name, so
    -- a non-ASCII issue title under a C or POSIX locale — the everyday case
    -- over SSH, cron and launchd — threw an invalid-byte 'IOException' out
    -- of a perfectly healthy fetch. Reading raw and decoding once, leniently,
    -- as UTF-8 keeps both the success and the failure paths independent of
    -- the environment.
    drain Nothing = newEmptyMVar >>= \captured -> putMVar captured (Right ByteString.empty) >> pure captured
    drain (Just handle) = do
      captured <- newEmptyMVar
      void . forkIO $ do
        bytes <- try @IOException (ByteString.hGetContents handle)
        ignoreIOException (hClose handle)
        putMVar captured bytes
      pure captured

-- | Cleans up the @gh@ an abandoned fetch walked away from: TERM, then KILL,
-- the whole process group it leads, confirmed against a fresh process
-- snapshot rather than assumed from the act of signalling. A group that
-- could not be terminated or could not be confirmed gone is both recorded on
-- the guard — a possibly-live @gh@ is not a clean timeout and must not be
-- reported as one — and written to the durable record, so the very next
-- fetch re-verifies it before spawning anything, even if the dashboard is
-- restarted in between.
abandonGh :: GhFetchGuard -> Repository -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO ()
abandonGh (GhFetchGuard cleanupFailure) repository (input, _, _, processHandle) = do
  -- Captured before anything reaps the handle, since 'getPid' goes 'Nothing'
  -- the moment it is reaped and the guard entry is keyed by this PID.
  spawnedPid <- fmap fromIntegral <$> getPid processHandle
  -- A finding already on the guard was established by the fetch itself, which
  -- knew things this cleanup no longer can -- above all when the leader has
  -- already been reaped and there is nothing left here to census. It is never
  -- overwritten and never cleared; this cleanup only ever adds one.
  alreadyReported <- isJust <$> readIORef cleanupFailure
  -- Written before any of the work below, all of which can be cut short by
  -- the cleanup budget running out. Whatever happens after this point, the
  -- fetch cannot end up reporting an ordinary clean timeout for a gh whose
  -- death was never actually established.
  unless alreadyReported (writeIORef cleanupFailure (Just (GhCleanupFailure "gh cleanup did not run to completion" GuardInMemoryOnly)))
  outcome <- killGhGroup processHandle
  resolved <- case outcome of
    Right proven -> pure (Right proven)
    Left (message, unconfirmed) -> do
      -- Upgrading the spawn-time guard to the full census is what lets a
      -- later run re-kill the group rather than only watch it, so it is
      -- worth attempting -- but nothing depends on it succeeding, because
      -- the entry written at spawn time already covers this pgid.
      recorded <- recordAndConfirm unconfirmed
      if recorded
        then pure (Left (GhCleanupFailure message GuardRecorded))
        else do
          -- Nothing on disk and nothing verified, so a restart would find no
          -- reason to hold back. Force is all that is left that depends on
          -- neither facility -- but it settles nothing by itself: only a
          -- snapshot showing the group actually empty does, and if it does,
          -- this was not a failed cleanup at all.
          forceKillGhGroup processHandle spawnedPid
          emptied <- groupConfirmedEmpty unconfirmed.ownedProcessGroupPid
          if emptied
            then pure (Right True)
            else do
              retried <- recordAndConfirm unconfirmed
              pure (Left (GhCleanupFailure message (if retried then GuardRecorded else GuardInMemoryOnly)))
  case resolved of
    Left failure -> unless alreadyReported (writeIORef cleanupFailure (Just failure))
    -- Reaping cannot block here: the group has been confirmed empty, so gh
    -- is at most an unreaped zombie. It is skipped entirely when that
    -- confirmation failed, since waiting on a gh that is still running would
    -- block this thread and the refresh would never report anything at all.
    Right proven -> do
      void (try @IOException (waitForProcess processHandle))
      mapM_ (dropGhGroup repository) spawnedPid
      -- A finding this cleanup did not make is retracted only by evidence
      -- this cleanup did make: proving the group empty. Otherwise the fetch's
      -- own finding stands, since it saw things no longer observable here.
      --
      -- Retracting on `proven` matters as much as keeping it otherwise. A
      -- cleanup that has just emptied the group and dropped its record has
      -- left nothing to hold off for, and a board held off for nothing would
      -- never refresh again.
      when (proven || not alreadyReported) (writeIORef cleanupFailure Nothing)
  mapM_ (ignoreIOException . hClose) input
  where
    recordAndConfirm unconfirmed = do
      void (recordGhGroup repository unconfirmed)
      ghGroupIsRecorded repository unconfirmed.ownedProcessGroupPid

-- | Runs a cleanup that must not be cut short by the refresh timer.
--
-- 'bracketOnError' masks its handler, but 'mask' still admits an exception
-- at every interruptible point, and this cleanup is little else: two grace
-- windows and several subprocess waits. A refresh timeout landing in one of
-- them would abandon the work half-done — signalled but never confirmed,
-- nothing recorded — and the fetch would go on to report an ordinary
-- timeout for a process that is still running.
--
-- So the work happens on a thread of its own, where the timer's exception
-- cannot reach it, and this thread waits for it without accepting exceptions
-- either. That wait cannot outlast the worker, and the worker holds itself
-- to a budget, so refusing interruption here does not mean waiting forever.
uninterruptibleCleanup :: IO () -> IO ()
uninterruptibleCleanup = uninterruptiblyBounded ()

-- | Runs an action where the refresh timer cannot reach it, and waits for it
-- without accepting exceptions either.
--
-- Anything that signals a process group and then has to confirm what it did
-- belongs in here. Interrupted between those two halves it leaves the worst
-- of both: processes signalled, nothing established, and -- since the caller
-- never hears about it -- an ordinary timeout published over whatever
-- survived. The work is bounded by its own budget, so refusing interruption
-- does not mean waiting forever; if that budget runs out the caller is told
-- so through `whenInterrupted` rather than by silence.
uninterruptiblyBounded :: a -> IO a -> IO a
uninterruptiblyBounded whenInterrupted action = do
  finished <- newEmptyMVar
  void
    ( forkIOWithUnmask
        ( \unmask ->
            (timeout cleanupBudgetMicros (unmask action) >>= putMVar finished . fromMaybe whenInterrupted)
              `finally` void (tryPutMVar finished whenInterrupted)
        )
    )
  uninterruptibleMask_ (takeMVar finished)

-- | Comfortably longer than a cleanup that is behaving: three escalation
-- rounds of grace windows and snapshots, plus the forced fallback's own
-- bounded reap. It exists only so that a cleanup wedged on something
-- unexpected cannot hold the refresh thread indefinitely.
cleanupBudgetMicros :: Int
cleanupBudgetMicros = 30 * 1000 * 1000

-- | How long a gh that has closed its output gets to actually exit before its
-- group is called unsettled. Draining to EOF normally means it is already
-- gone, so this is a margin rather than a wait.
leaderDeparturePolls :: Int
leaderDeparturePolls = 20

leaderDeparturePollMicros :: Int
leaderDeparturePollMicros = 50 * 1000

ghGroupIsRecorded :: Repository -> Int -> IO Bool
ghGroupIsRecorded repository groupPid =
  any ((== groupPid) . ownedProcessGroupPid) <$> recordedGhGroups repository

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

-- | Whether a fresh snapshot shows nothing left in the group at all — not
-- the leader, and not any descendant that inherited it.
--
-- This is what stands behind a claim that the group is gone, and it is
-- deliberately about the /whole/ group: reaping the leader says nothing
-- about a credential helper still wedged in uninterruptible I\/O, which
-- would survive long enough to be running when a restarted dashboard
-- spawned its own gh. A snapshot that cannot be taken answers 'False',
-- because "could not look" is not "nothing there".
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

forcedReapTimeoutMicros :: Int
forcedReapTimeoutMicros = 5 * 1000 * 1000

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
        Left message -> pure (Left (message, OwnedProcessGroup groupPid [] False))
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
                        OwnedProcessGroup groupPid [leader] False
                      )
                  )
          _ -> case groupMembers groupPid processes of
            -- The only successful ending: the group, asked afresh, has
            -- nobody left in it -- and this time that was actually checked.
            [] -> pure (Right True)
            members
              | passesLeft <= 0 ->
                  pure (Left ("gh's process group kept gaining members faster than they could be terminated", OwnedProcessGroup groupPid members True))
              | otherwise -> do
                  result <- killVerifiedGroup groupPid members
                  case result of
                    Left message -> pure (Left (message, OwnedProcessGroup groupPid members True))
                    Right () -> escalate groupPid (passesLeft - 1)

-- | How many census-then-escalate rounds a group gets before its survivors
-- are handed to the durable record instead. More than one because a member
-- can join while the census is being acted on; bounded because something
-- forking faster than it can be killed is a problem to be recorded and
-- refused, not looped on forever.
groupCleanupPasses :: Int
groupCleanupPasses = 3

groupMembers :: Int -> [ProcessIdentity] -> [ProcessIdentity]
groupMembers groupPid = filter ((== groupPid) . processIdentityGroupPid)

-- | The argv that starts @gh@ behind a barrier: a shell that waits for a
-- line on standard input and only then replaces itself with @gh@.
--
-- This is what makes the durable guard genuinely a /pre/-spawn guard. Writing
-- the record straight after 'createProcess' would still leave a window —
-- short, but real — in which @gh@ is running and nothing on disk names it, so
-- losing the dashboard there would strand it unguarded. Here the child cannot
-- reach @gh@ until the record is committed, and because the wait ends on EOF
-- as well as on input, a parent that dies in that window closes the pipe and
-- the child exits without ever executing anything.
--
-- @exec@ matters: the shell is replaced rather than forked, so the PID and
-- process group the record names are exactly the ones @gh@ ends up running
-- under.
-- The executable is resolved by the parent rather than left to the shell's
-- @exec@, so a missing or non-executable @gh@ is still reported as
-- 'ExecutableMissing' from the spawn site instead of arriving later as an
-- indistinguishable nonzero exit from inside the barrier.
ghBehindBarrier :: FilePath -> [String] -> (FilePath, [String])
ghBehindBarrier ghPath arguments = ("sh", ["-c", "read -r _release_ || exit 0; exec \"$0\" \"$@\"", ghPath] <> arguments)

-- | Raised when the durable guard covering a freshly spawned @gh@ cannot be
-- written. It is raised rather than returned so the spawn unwinds through
-- 'abandonGh' and that @gh@ is terminated: a process this fetch started must
-- never outlive the record that would have accounted for it.
data GhFetchAborted
  = -- | The durable guard covering a freshly spawned @gh@ could not be
    -- written, so that @gh@ was stopped rather than left running unguarded.
    GhGuardUnwritable Text
  | -- | @gh@ finished, but something it led did not, and the group could not
    -- be confirmed empty. The record is left in place for a later fetch to
    -- reclaim rather than this one carrying on beside it.
    GhGroupUnresolved Text
  deriving stock (Show)

instance Exception GhFetchAborted

-- | An 'IOException' raised somewhere in the @gh@ path, carrying the phase it
-- escaped from. The phase travels with it because the exception alone cannot
-- answer the only question the board asks of it: whether the user should be
-- sent to install @gh@.
data GhProcessFailed = GhProcessFailed GhFailurePhase IOException
  deriving stock (Show)

instance Exception GhProcessFailed

-- | Which half of a @gh@ run a failure came out of.
data GhFailurePhase
  = -- | No child exists yet: @gh@ is still being resolved on @PATH@ or
    -- spawned. This is the only phase in which "there is no runnable @gh@"
    -- is still a possible explanation.
    GhLaunching
  | -- | The child was created, so @gh@ launched. Anything that goes wrong
    -- from here — a read that fails mid-response, a pipe that breaks, a
    -- descriptor limit — is about this request, not about the installation.
    GhRunning
  deriving stock (Eq, Show)

-- | Maps one @gh@ failure onto the vocabulary §17 renders. 'ExecutableMissing'
-- becomes @NOT INSTALLED@, which is only ever the truth for a launch that
-- failed because there was nothing to launch: no such file, or a file that
-- cannot be executed. Every other launch error — a descriptor limit, a fork
-- failure — and every post-launch error is 'RequestFailed', so a working,
-- authenticated @gh@ is never reported as absent.
ghFailureKind :: GhFailurePhase -> IOException -> ProviderErrorKind
ghFailureKind GhLaunching exception
  | isDoesNotExistError exception = ExecutableMissing
  | isPermissionError exception = ExecutableMissing
  | otherwise = RequestFailed
ghFailureKind GhRunning _ = RequestFailed

-- | Writes the guard for a @gh@ that has just been spawned, before it is
-- used for anything. The entry names only the process group, because that is
-- all that is known this early and all a later run needs: an uncensused
-- entry is watched until its pgid is unoccupied, which is exactly the
-- question "did that gh outlive us?".
registerSpawnedGh :: Repository -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO (Either Text Int)
registerSpawnedGh repository (_, _, _, processHandle) = do
  spawnedPid <- getPid processHandle
  case spawnedPid of
    Nothing -> pure (Left "gh reported no process id, so no guard could be written for it")
    Just pid -> do
      let groupPid = fromIntegral pid
      written <- recordGhGroup repository (OwnedProcessGroup groupPid [] False)
      pure (groupPid <$ written)

-- | Replaces whatever is recorded for a group with `group`, keeping every
-- other repository entry.
recordGhGroup :: Repository -> OwnedProcessGroup -> IO (Either Text ())
recordGhGroup repository group = do
  existing <- recordedGhGroups repository
  writeGhGroupRecord repository (group : withoutGroup group.ownedProcessGroupPid existing)

dropGhGroup :: Repository -> Int -> IO ()
dropGhGroup repository groupPid = do
  existing <- recordedGhGroups repository
  case withoutGroup groupPid existing of
    [] -> void (removeGhGroupRecord repository)
    remaining -> void (writeGhGroupRecord repository remaining)

withoutGroup :: Int -> [OwnedProcessGroup] -> [OwnedProcessGroup]
withoutGroup groupPid = filter ((/= groupPid) . ownedProcessGroupPid)

recordedGhGroups :: Repository -> IO [OwnedProcessGroup]
recordedGhGroups repository = do
  existing <- loadGhGroupRecord repository
  pure $ case existing of
    GhGroupRecordLoaded groups -> groups
    _ -> []

-- | Re-verifies, and where it is safe to do so re-kills, every @gh@ group a
-- previous fetch failed to confirm dead — including ones recorded by an
-- earlier run of the dashboard, which is the whole reason the record is on
-- disk. The record is cleared only once every entry is provably accounted
-- for; anything else refuses the fetch outright, so a new @gh@ is never
-- spawned alongside one that may still be running.
reclaimRecordedGhGroups :: GhFetchGuard -> Repository -> IO (Either Text ())
reclaimRecordedGhGroups guard repository = do
  recordLoad <- loadGhGroupRecord repository
  case recordLoad of
    GhGroupRecordAbsent -> pure (Right ())
    GhGroupRecordUnusable message -> refuse message
    GhGroupRecordLoaded groups -> do
      -- A record exists from here on, so every exit other than clearing it
      -- has to leave the guard set. It is set now, pessimistically, because
      -- the exits that matter most are the ones that never reach a `case`:
      -- the budget expiring, or this whole reclaim being abandoned.
      setCleanupFailure guard (GhCleanupFailure (refusalText interrupted) GuardRecorded)
      outcomes <- traverse reclaimGhGroup groups
      case [message | Left message <- outcomes] of
        [] -> do
          cleared <- removeGhGroupRecord repository
          case cleared of
            Left message -> refuse message
            Right () -> do
              clearCleanupFailure guard
              pure (Right ())
        message : _ -> refuse message
  where
    refuse message = do
      setCleanupFailure guard (GhCleanupFailure (refusalText message) GuardRecorded)
      pure (Left (refusalText message))

    interrupted = "reclaiming it did not run to completion"

    refusalText message = "a gh process from an earlier GitHub refresh could not be confirmed stopped (" <> message <> "); refusing to start another until it is"

-- | One recorded group's second chance.
--
-- A censused group is identity-pinned and this dashboard's to signal, so it
-- gets the same verified TERM-then-KILL escalation again. An uncensused one
-- never can be, so it is only ever observed: whatever still matches it
-- refuses the fetch instead of being signalled blind, and — crucially — an
-- uncensused entry is never handed to the group check, whose empty
-- membership would read as vacuously absent and clear a live survivor.
reclaimGhGroup :: OwnedProcessGroup -> IO (Either Text ())
reclaimGhGroup group = go group.ownedProcessGroupMembers groupCleanupPasses
  where
    groupPid = group.ownedProcessGroupPid

    -- `known` grows as the reclaim proceeds, and it is what every signal is
    -- justified by. A flag saying "ownership was proven earlier" would not
    -- do: between two rounds the group can empty and its pgid be reissued, so
    -- an earlier proof says nothing about who is in it now. Identities do
    -- survive that, because a reused PID never matches a recorded start time.
    --
    -- Members are adopted into `known` only from a census taken while
    -- ownership was proven; at that instant everything in the group is
    -- descended from what this repository started, so a descendant forked
    -- from a member's TERM handler becomes provably ours and stays killable
    -- after its parent exits.
    go known passesLeft = do
      snapshot <- defaultProcessSnapshot
      case snapshot of
        Left message -> pure (Left message)
        Right processes -> do
          let occupants = groupMembers groupPid processes
              -- Saved identities are asked about by identity, never by
              -- group. The record written when gh turned out not to lead its
              -- own group names a pgid that was never this repository's, so
              -- looking only at that pgid finds nothing and would call the
              -- record spent while the gh it names is still running.
              savedAlive = matchingIdentities processes known
          case occupants <> savedAlive of
            -- Nothing in the group and nothing the record names: the only
            -- ending that clears it, and the reason this is asked of a fresh
            -- census rather than inferred from the recorded members going
            -- away.
            [] -> pure (Right ())
            survivors
              | not (provablyOurs processes known) -> pure (Left (unprovable (length survivors)))
              | passesLeft <= 0 -> pure (Left exhausted)
              | otherwise -> do
                  result <- freezeThenKillOwnedGroup groupPid known
                  case result of
                    Left message -> pure (Left message)
                    Right adopted -> go (known <> adopted) (passesLeft - 1)

    -- An uncensused record never pins anything, so its group can only ever
    -- be watched; a censused one is ours to signal exactly while one of the
    -- identities known to be ours is still holding its PID, start time, and
    -- group.
    provablyOurs processes known =
      group.ownedProcessGroupCensused
        && not (null (membersStillInGroup groupPid processes known))

    unprovable surviving =
      "a gh from an earlier GitHub refresh (pgid "
        <> Text.pack (show groupPid)
        <> ") still accounts for "
        <> Text.pack (show surviving)
        <> " running process(es) that cannot be identified as this repository's, so they cannot be signalled from here"

    exhausted =
      "a gh process group from an earlier GitHub refresh (pgid "
        <> Text.pack (show groupPid)
        <> ") kept gaining members faster than they could be terminated"

ignoreIOException :: IO () -> IO ()
ignoreIOException action = void (try @IOException action)

advanceState :: LimitsConfig -> FetchState -> GitHubPage -> Either ProviderError FetchState
advanceState limits previous page = do
  issueConnection <- requireConnection "issues" previous.fetchMoreIssues page.pageIssues
  pullRequestConnection <- requireConnection "pull requests" previous.fetchMorePullRequests page.pagePullRequests
  let newIssues = maybe [] (.connectionNodes) issueConnection
      newPullRequests = maybe [] (.connectionNodes) pullRequestConnection
      allIssues = take issueLimit (previous.fetchedIssues <> newIssues)
      allPullRequests = take pullRequestLimit (previous.fetchedPullRequests <> newPullRequests)
  (moreIssues, nextIssueCursor, truncatedIssues) <-
    advanceConnection issueLimit (length allIssues) previous.fetchMoreIssues issueConnection
  (morePullRequests, nextPullRequestCursor, truncatedPullRequests) <-
    advanceConnection pullRequestLimit (length allPullRequests) previous.fetchMorePullRequests pullRequestConnection
  pure
    FetchState
      { fetchedIssues = allIssues,
        fetchedPullRequests = allPullRequests,
        issueCursor = nextIssueCursor,
        pullRequestCursor = nextPullRequestCursor,
        fetchMoreIssues = moreIssues,
        fetchMorePullRequests = morePullRequests,
        issuesTruncated = previous.issuesTruncated || truncatedIssues,
        pullRequestsTruncated = previous.pullRequestsTruncated || truncatedPullRequests
      }
  where
    issueLimit = limits.limitsMaxOpenIssues
    pullRequestLimit = limits.limitsMaxOpenPullRequests

requireConnection :: Text -> Bool -> Maybe (Connection item) -> Either ProviderError (Maybe (Connection item))
requireConnection _ False connection = Right connection
requireConnection connectionName True Nothing =
  Left
    ProviderError
      { providerErrorKind = InvalidResponse,
        providerErrorMessage = "GitHub response omitted the " <> connectionName <> " connection"
      }
requireConnection _ True connection = Right connection

advanceConnection :: Int -> Int -> Bool -> Maybe (Connection item) -> Either ProviderError (Bool, Maybe Text, Bool)
advanceConnection _ _ False _ = Right (False, Nothing, False)
advanceConnection limit currentCount True (Just connection) =
  paginationDecision limit currentCount pageInfo.pageHasNext pageInfo.pageEndCursor
  where
    pageInfo = connection.connectionPageInfo
advanceConnection _ _ True Nothing =
  Left (ProviderError InvalidResponse "GitHub response omitted a requested connection")

paginationDecision :: Int -> Int -> Bool -> Maybe Text -> Either ProviderError (Bool, Maybe Text, Bool)
paginationDecision _ _ False _ = Right (False, Nothing, False)
paginationDecision limit currentCount True _
  | currentCount >= limit = Right (False, Nothing, True)
paginationDecision _ _ True Nothing =
  Left
    ProviderError
      { providerErrorKind = InvalidResponse,
        providerErrorMessage = "GitHub pagination indicated another page without a cursor"
      }
paginationDecision _ _ True (Just cursor) = Right (True, Just cursor, False)

-- | Builds the @gh api graphql@ argument vector.  GraphQL @String!@
-- variables go through @-f@, gh's always-raw flag, because @-F@ coerces
-- all-digit values to Int and @true@/@false@ to Boolean: an owner or
-- repository named @12345@ would otherwise be sent as an Int and rejected
-- for every page of every refresh.  Only the genuinely typed variables --
-- the @Int!@ page sizes and @Boolean!@ fetch controls -- keep @-F@.
graphqlArguments :: LimitsConfig -> Repository -> FetchState -> [String]
graphqlArguments limits repository state =
  [ "api",
    "graphql",
    "-f",
    "owner=" <> Text.unpack repository.repositoryOwner,
    "-f",
    "name=" <> Text.unpack repository.repositoryName,
    "-F",
    "issuePageSize=" <> show issuePageSize,
    "-F",
    "pullRequestPageSize=" <> show pullRequestPageSize,
    "-F",
    "fetchIssues=" <> boolText state.fetchMoreIssues,
    "-F",
    "fetchPullRequests=" <> boolText state.fetchMorePullRequests
  ]
    <> cursorArgument "issueCursor" state.issueCursor
    <> cursorArgument "pullRequestCursor" state.pullRequestCursor
    <> ["-f", "query=" <> Text.unpack graphqlQuery]
  where
    issuePageSize = max 1 (min pageLimit (limits.limitsMaxOpenIssues - length state.fetchedIssues))
    pullRequestPageSize = max 1 (min pageLimit (limits.limitsMaxOpenPullRequests - length state.fetchedPullRequests))

-- | Cursors are declared @String@ and are opaque to us, so they are passed
-- raw as well; an all-digit cursor would otherwise corrupt pagination the
-- same way.  An absent cursor stays omitted, which is what makes a request
-- the first page.
cursorArgument :: String -> Maybe Text -> [String]
cursorArgument _ Nothing = []
cursorArgument name (Just cursor) = ["-f", name <> "=" <> Text.unpack cursor]

boolText :: Bool -> String
boolText True = "true"
boolText False = "false"

classifyFailure :: Text -> ProviderErrorKind
classifyFailure message
  | any (`Text.isInfixOf` Text.toCaseFold message) ["authentication", "not logged", "oauth", "token"] = AuthenticationRequired
  | otherwise = RequestFailed

compactError :: Text -> Text
compactError rawMessage =
  let message = Text.unwords (Text.words rawMessage)
   in if Text.null message then "GitHub request failed" else Text.take 500 message

-- | The one decoding every byte @gh@ writes goes through. GitHub's API output
-- is UTF-8 by contract, and 'lenientDecode' means a truncated or corrupted
-- response still yields a readable diagnostic instead of an exception raised
-- from inside the decoder.
decodeGhOutput :: ByteString.ByteString -> Text
decodeGhOutput = TextEncoding.decodeUtf8With lenientDecode

instance FromJSON GitHubPage where
  parseJSON = withObject "GraphQL response" $ \root -> do
    errors <- root .:? "errors" .!= ([] :: [Value])
    unless (null errors) (fail "GitHub GraphQL response contained errors")
    dataObject <- root .: "data"
    repositoryValue <- dataObject .:? "repository"
    repositoryObject <- maybe (fail "GitHub repository was not found") pure repositoryValue
    withObject "repository" parseRepositoryPage repositoryObject
    where
      parseRepositoryPage repositoryObject =
        GitHubPage
          <$> parseOptionalConnection parseIssue repositoryObject "issues"
          <*> parseOptionalConnection parsePullRequest repositoryObject "pullRequests"

instance FromJSON PageInfo where
  parseJSON = withObject "pageInfo" $ \object ->
    PageInfo
      <$> object .: "hasNextPage"
      <*> object .:? "endCursor"

parseOptionalConnection :: (Value -> Parser item) -> Object -> Key -> Parser (Maybe (Connection item))
parseOptionalConnection itemParser object fieldName = do
  value <- object .:? fieldName
  traverse (parseConnection itemParser) value

parseConnection :: (Value -> Parser item) -> Value -> Parser (Connection item)
parseConnection itemParser = withObject "connection" $ \object -> do
  nodes <- object .:? "nodes" .!= []
  Connection
    <$> traverse itemParser nodes
    <*> object .: "pageInfo"

parseLabel :: Value -> Parser Label
parseLabel = withObject "label" $ \object ->
  Label
    <$> object .: "name"
    <*> object .: "color"

parseAssignee :: Value -> Parser Assignee
parseAssignee = withObject "assignee" $ \object -> Assignee <$> object .: "login"

parseIssue :: Value -> Parser Issue
parseIssue = withObject "issue" $ \object -> do
  (labels, labelOverflow, labelGaps) <- parseNodes parseLabel object "labels" LabelsUnavailable
  (assignees, assigneeOverflow, assigneeGaps) <- parseNodes parseAssignee object "assignees" AssigneesUnavailable
  Issue
    <$> object .: "number"
    <*> object .: "title"
    <*> object .:? "body" .!= ""
    <*> object .: "url"
    <*> pure labels
    <*> pure assignees
    <*> object .: "createdAt"
    <*> object .: "updatedAt"
    <*> pure labelOverflow
    <*> pure assigneeOverflow
    <*> pure (labelGaps <> assigneeGaps)

parsePullRequest :: Value -> Parser PullRequest
parsePullRequest = withObject "pull request" $ \object -> do
  mergeable <- object .: "mergeable"
  mergeStateStatus <- object .: "mergeStateStatus"
  (labels, labelOverflow, labelGaps) <- parseNodes parseLabel object "labels" LabelsUnavailable
  (linkedIssues, linkedIssueOverflow, linkedIssueGaps) <- parseNodes parseIssueNumber object "closingIssuesReferences" LinkedIssuesUnavailable
  (checks, checkGaps) <- parseChecks object
  PullRequest
      <$> object .: "number"
      <*> object .: "title"
      <*> object .:? "body" .!= ""
      <*> object .: "url"
      <*> pure labels
      <*> parseAuthor object
      <*> object .: "isDraft"
      <*> object .: "baseRefName"
      <*> object .: "headRefName"
      <*> pure linkedIssues
      <*> (parseReviewDecision <$> object .:? "reviewDecision")
      <*> pure (parseMergeState mergeable mergeStateStatus)
      <*> pure checks
      <*> object .: "createdAt"
      <*> object .: "updatedAt"
      <*> pure labelOverflow
      <*> pure linkedIssueOverflow
      <*> pure (labelGaps <> linkedIssueGaps <> checkGaps)

-- | A nested connection, plus the 'DataGap' to record if GitHub did not supply
-- it. @labels@, @assignees@, and @closingIssuesReferences@ are all nullable in
-- GitHub's schema, and a partial-error response nulls out exactly the fields
-- that errored, so an absent or null connection is one item's missing data
-- rather than a broken page: it decodes as no nodes and a gap on that item.
--
-- A connection that /is/ present stays strict. Malformed nodes, a missing or
-- non-numeric @totalCount@, and a @totalCount@ below the node list all still
-- fail the decode -- those describe a response this build cannot reason about
-- at all, not a field GitHub declined to deliver.
parseNodes :: (Value -> Parser item) -> Object -> Key -> DataGap -> Parser ([item], Int, [DataGap])
parseNodes itemParser object fieldName gap = do
  connection <- object .:? fieldName
  case connection of
    Nothing -> pure ([], 0, [gap])
    Just value -> withObject "nested connection" parseNested value
  where
    parseNested nested = do
      nodeValues <- nested .:? "nodes" .!= []
      totalCount <- nested .: "totalCount"
      nodes <- traverse itemParser nodeValues
      if totalCount < length nodes
        then fail "nested connection totalCount was smaller than its node list"
        else pure (nodes, totalCount - length nodes, [])

parseIssueNumber :: Value -> Parser Int
parseIssueNumber = withObject "issue reference" (.: "number")

parseAuthor :: Object -> Parser Text
parseAuthor object = do
  author <- object .:? "author"
  case author of
    Nothing -> pure "ghost"
    Just value -> withObject "author" (\actor -> actor .: "login") value

parseReviewDecision :: Maybe Text -> ReviewDecision
parseReviewDecision (Just "APPROVED") = ReviewApproved
parseReviewDecision (Just "CHANGES_REQUESTED") = ReviewChangesRequested
parseReviewDecision (Just "REVIEW_REQUIRED") = ReviewRequired
parseReviewDecision _ = ReviewUnknown

parseMergeState :: Text -> Text -> MergeState
parseMergeState "CONFLICTING" _ = MergeConflicting
parseMergeState _ "DIRTY" = MergeConflicting
parseMergeState _ "CLEAN" = MergeClean
parseMergeState _ "BEHIND" = MergeBehind
parseMergeState "MERGEABLE" "BLOCKED" = MergeProtected
parseMergeState _ "BLOCKED" = MergeBlocked
parseMergeState _ "UNSTABLE" = MergeUnstable
parseMergeState _ _ = MergeUnknown

-- | The rollup summary, plus 'ChecksUndecodable' when a context in it could
-- not be read. The rollup's own structure stays strict -- a missing
-- @contexts@ object or @totalCount@ is a malformed response, not a degraded
-- item -- but an individual context this build does not understand fails
-- closed the way §13 already fails a rollup past the context cap: the whole
-- summary becomes 'ChecksUnknown' rather than aborting the page it arrived on.
--
-- The cap is checked before any context is decoded, so a capped rollup keeps
-- its existing meaning exactly and never picks up a gap: its summary is
-- unknown because GitHub reported more contexts than were requested, which is
-- the documented cap behavior and not an anomaly to warn about.
parseChecks :: Object -> Parser (CheckSummary, [DataGap])
parseChecks object = do
  rollup <- object .:? "statusCheckRollup"
  case rollup of
    Nothing -> pure (ChecksNone, [])
    Just value -> withObject "status check rollup" parseRollup value
  where
    parseRollup rollup = do
      contexts <- rollup .: "contexts"
      withObject "check contexts" parseContexts contexts
    parseContexts contexts = do
      totalCount <- contexts .: "totalCount"
      values <- contexts .:? "nodes" .!= []
      if totalCount > length values
        then pure (ChecksUnknown, [])
        else case traverse (parseEither parseCheckContext) values of
          Left _ -> pure (ChecksUnknown, [ChecksUndecodable])
          Right parsed -> pure (summarizeChecks parsed, [])

parseCheckContext :: Value -> Parser CheckContext
parseCheckContext = withObject "status check context" $ \context -> do
  contextType <- context .: "__typename"
  case (contextType :: Text) of
    "CheckRun" -> do
      name <- context .: "name"
      status <- context .: "status"
      conclusion <- context .:? "conclusion"
      startedAt <- optionalTimestamp <$> context .:? "startedAt"
      completedAt <- optionalTimestamp <$> context .:? "completedAt"
      app <- parseCheckRunApp context
      pure
        CheckContext
          { checkContextKey = "check:" <> app <> ":" <> name,
            checkContextName = name,
            -- A run reporting only @completedAt@ has still run, so that
            -- timestamp stays its effective one; only a run with neither is
            -- the just-requested rerun 'RecencyUnstarted' means.
            checkContextRecency = maybe RecencyUnstarted RecencyAt (startedAt <|> completedAt),
            checkContextState = classifyCheckRun status conclusion
          }
    "StatusContext" -> do
      name <- context .: "context"
      state <- context .: "state"
      createdAt <- optionalTimestamp <$> context .:? "createdAt"
      creator <- parseStatusCreator context
      pure
        CheckContext
          { checkContextKey = "status:" <> creator <> ":" <> name,
            checkContextName = name,
            checkContextRecency = maybe RecencyUndated RecencyAt createdAt,
            checkContextState = classifyStatusContext state
          }
    other -> fail ("unsupported status check context type: " <> Text.unpack other)

-- | GitHub reports a timestamp it has no value for as JSON null, and can leave
-- the field off entirely; treat an empty string the same way so \"not stamped
-- yet\" reaches 'CheckRecency' as one representation rather than three.
optionalTimestamp :: Maybe Text -> Maybe Text
optionalTimestamp (Just timestamp) | not (Text.null timestamp) = Just timestamp
optionalTimestamp _ = Nothing

parseCheckRunApp :: Object -> Parser Text
parseCheckRunApp context = do
  suite <- context .:? "checkSuite"
  case suite of
    Nothing -> pure "unknown"
    Just value -> withObject "check suite" parseSuite value
  where
    parseSuite suite = do
      app <- suite .:? "app"
      case app of
        Nothing -> pure "unknown"
        Just value -> withObject "check app" (\object -> object .:? "slug" .!= "unknown") value

parseStatusCreator :: Object -> Parser Text
parseStatusCreator context = do
  creator <- context .:? "creator"
  case creator of
    Nothing -> pure "unknown"
    Just value -> withObject "status creator" (\object -> object .:? "login" .!= "unknown") value

classifyCheckRun :: Text -> Maybe Text -> CheckState
classifyCheckRun "COMPLETED" (Just conclusion)
  | conclusion `elem` ["SUCCESS", "NEUTRAL", "SKIPPED"] = CheckPassed
  | otherwise = CheckFailed
classifyCheckRun _ _ = CheckPending

classifyStatusContext :: Text -> CheckState
classifyStatusContext "SUCCESS" = CheckPassed
classifyStatusContext "PENDING" = CheckPending
classifyStatusContext "EXPECTED" = CheckPending
classifyStatusContext _ = CheckFailed

-- | Fold the rollup into the aggregate counts the board colors read, keeping
-- the deduplicated checks that did not pass so the details overlay can name
-- them. Detail comes from exactly the same @latest@ selection as the counts,
-- so a superseded failure can never be listed beside a passing aggregate.
summarizeChecks :: [CheckContext] -> CheckSummary
summarizeChecks [] = ChecksNone
summarizeChecks contexts
  | any ((== CheckFailed) . (.checkContextState)) latest = ChecksFailed passed total outstanding
  | any ((== CheckPending) . (.checkContextState)) latest = ChecksPending passed total outstanding
  | otherwise = ChecksPassed total
  where
    latest = Map.elems (Map.fromListWith latestContext [(context.checkContextKey, context) | context <- contexts])
    total = length latest
    passed = length (filter ((== CheckPassed) . (.checkContextState)) latest)
    outstanding =
      [ CheckDetail context.checkContextName context.checkContextState
        | context <- latest,
          context.checkContextState /= CheckPassed
      ]
    -- The authoritative dedup comparator. 'CheckRecency' carries the rule for
    -- a context with no timestamp -- newest for a check run, oldest for a
    -- status context -- so all this decides is the tie: equal recencies keep
    -- @left@, which 'Map.fromListWith' hands the entry appearing later in the
    -- decoded @contexts.nodes@ order.
    latestContext left right
      | left.checkContextRecency >= right.checkContextRecency = left
      | otherwise = right

graphqlQuery :: Text
graphqlQuery =
  Text.unlines
    [ "query(",
      "  $owner: String!,",
      "  $name: String!,",
      "  $issueCursor: String,",
      "  $pullRequestCursor: String,",
      "  $issuePageSize: Int!,",
      "  $pullRequestPageSize: Int!,",
      "  $fetchIssues: Boolean!,",
      "  $fetchPullRequests: Boolean!",
      ") {",
      "  repository(owner: $owner, name: $name) {",
      "    issues(first: $issuePageSize, after: $issueCursor, states: OPEN) @include(if: $fetchIssues) {",
      "      nodes {",
      "        number title body url createdAt updatedAt",
      "        labels(first: 20) { totalCount nodes { name color } }",
      "        assignees(first: 10) { totalCount nodes { login } }",
      "      }",
      "      pageInfo { hasNextPage endCursor }",
      "    }",
      "    pullRequests(first: $pullRequestPageSize, after: $pullRequestCursor, states: OPEN) @include(if: $fetchPullRequests) {",
      "      nodes {",
      "        number title body url createdAt updatedAt isDraft",
      "        baseRefName headRefName author { login }",
      "        labels(first: 20) { totalCount nodes { name color } }",
      "        closingIssuesReferences(first: 20) { totalCount nodes { number } }",
      "        reviewDecision mergeable mergeStateStatus",
      "        statusCheckRollup {",
      "          contexts(first: 100) {",
      "            totalCount",
      "            nodes {",
      "              __typename",
      "              ... on CheckRun { name status conclusion startedAt completedAt checkSuite { app { slug } } }",
      "              ... on StatusContext { context state createdAt creator { login } }",
      "            }",
      "          }",
      "        }",
      "      }",
      "      pageInfo { hasNextPage endCursor }",
      "    }",
      "  }",
      "}"
    ]

snapshotWarnings :: LimitsConfig -> WorkflowConfig -> RepoSnapshot -> [Text]
snapshotWarnings limits workflowConfig snapshot =
  [showText limits.limitsMaxOpenIssues <> "+ open issues; board is truncated" | snapshot.snapshotIssuesTruncated]
    <> [showText limits.limitsMaxOpenPullRequests <> "+ open pull requests; board is truncated" | snapshot.snapshotPullRequestsTruncated]
    <> [ nestedCountText nestedOverflowItems
           <> " contain truncated labels, assignees, or linked issues; +N markers show omitted values"
       | nestedOverflowItems > 0
       ]
    <> [ trackerCountText malformedTrackers
           <> " have malformed or missing child checklists; amber diagnostics show the cause"
       | malformedTrackers > 0
       ]
    <> [incompleteText incompleteItems | not (null incompleteItems)]
  where
    -- Named rather than counted: the amber marker on a degraded card says
    -- something is missing, and this is what says which card. The banner is a
    -- single line, so past a few names it counts the rest with the same +N
    -- vocabulary the overflow indicators use -- visibly truncated, never
    -- silently.
    incompleteItems =
      [ "Issue #" <> showText issue.issueNumber
        | issue <- snapshot.snapshotIssues,
          not (null issue.issueDataGaps)
      ]
        <> [ "PR #" <> showText pullRequest.pullRequestNumber
             | pullRequest <- snapshot.snapshotPullRequests,
               not (null pullRequest.pullRequestDataGaps)
           ]
    incompleteText names =
      Text.intercalate ", " (take incompleteNameLimit names)
        <> (if length names > incompleteNameLimit then " +" <> showText (length names - incompleteNameLimit) <> " more" else "")
        <> ": incomplete data; GitHub did not deliver every field, and the amber cards show which"
    incompleteNameLimit = 3 :: Int
    nestedOverflowItems =
      length (filter issueHasOverflow snapshot.snapshotIssues)
        + length (filter pullRequestHasOverflow snapshot.snapshotPullRequests)
    issueHasOverflow issue = issue.issueLabelOverflow > 0 || issue.issueAssigneeOverflow > 0
    pullRequestHasOverflow pullRequest = pullRequest.pullRequestLabelOverflow > 0 || pullRequest.pullRequestLinkedIssueOverflow > 0
    malformedTrackers =
      length
        ( filter
            (not . null . trackerDiagnosticsForIssue workflowConfig)
            snapshot.snapshotIssues
        )
    nestedCountText 1 = "1 card"
    nestedCountText count = showText count <> " cards"
    trackerCountText 1 = "1 tracker"
    trackerCountText count = showText count <> " trackers"

showText :: Show value => value -> Text
showText = Text.pack . show
