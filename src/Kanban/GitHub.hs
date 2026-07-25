module Kanban.GitHub
  ( -- 'FetchState' and 'graphqlArguments' are internal, exported so the
    -- suite can assert the exact argv handed to gh without a live request.
    FetchState (..),
    GhCleanupFailure (..),
    GhCleanupGuard (..),
    GhFetchGuard,
    GitHubResult (..),
    decodeGitHubItems,
    fetchGitHubSnapshot,
    ghFetchCleanupFailure,
    graphqlArguments,
    newGhFetchGuard,
    paginationDecision,
    reclaimRecordedGhGroups,
    snapshotWarnings,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (Exception, IOException, bracketOnError, throwIO, try)
import Control.Monad (unless, void)
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
import Data.Aeson.Types (Parser)
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Lazy as LazyText
import qualified Data.Text.Lazy.Encoding as LazyTextEncoding
import Data.Time (getCurrentTime)
import Kanban.Cache (GhGroupRecordLoad (..), loadGhGroupRecord, removeGhGroupRecord, writeGhGroupRecord)
import Kanban.Config (LimitsConfig (..))
import Kanban.Domain
import Kanban.Process (OwnedProcessGroup (..), ProcessIdentity (..), defaultProcessSnapshot, identityForPid, killVerifiedGroup, matchingIdentities)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Tracker (trackerDiagnosticsForIssue)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hGetContents')
import System.Posix.Signals (sigKILL, signalProcessGroup)
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
    checkContextStartedAt :: Text,
    checkContextState :: CheckState
  }
  deriving stock (Eq, Show)

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

-- | What is keeping a possibly-live @gh@ from being overlapped, now that
-- confirming its death did not work. These are in descending order of how
-- much they can promise, and the caller has to treat them differently:
-- only the first survives this dashboard without also needing it to refuse
-- refreshing.
data GhCleanupGuard
  = -- | The group is on disk. Any later fetch re-checks it before spawning
    -- anything, in this dashboard or one started long afterwards.
    GuardRecorded
  | -- | Nothing could be recorded, so the group was killed outright — and a
    -- fresh snapshot then showed it empty, leader and descendants alike. No
    -- durable guard is needed because nothing is left to guard against. This
    -- dashboard still stops refreshing, since the store it would need to
    -- record the next one is evidently broken.
    GuardForciblyTerminated
  | -- | Nothing could be recorded and the forced kill could not be confirmed
    -- either. This dashboard's refusal to refresh is all that remains, and
    -- it is worth nothing once the dashboard exits.
    GuardInMemoryOnly
  deriving stock (Eq, Show)

newGhFetchGuard :: IO GhFetchGuard
newGhFetchGuard = GhFetchGuard <$> newIORef Nothing

ghFetchCleanupFailure :: GhFetchGuard -> IO (Maybe GhCleanupFailure)
ghFetchCleanupFailure (GhFetchGuard cleanupFailure) = readIORef cleanupFailure

fetchGitHubSnapshot :: GhFetchGuard -> LimitsConfig -> WorkflowConfig -> Repository -> IO (Either ProviderError GitHubResult)
fetchGitHubSnapshot guard limits workflowConfig repository = do
  reclaimed <- reclaimRecordedGhGroups repository
  case reclaimed of
    Left message -> pure (Left (ProviderError RequestFailed message))
    Right () -> fetchPages initialState
  where
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
  guarded <- try @GhGuardUnwritable (try @IOException (runGh guard repository (graphqlArguments limits repository state)))
  pure $ case guarded of
    Left (GhGuardUnwritable message) ->
      Left
        ProviderError
          { providerErrorKind = RequestFailed,
            providerErrorMessage = "GitHub refresh could not record the gh process it started (" <> message <> "), so it was stopped again"
          }
    Right (Left exception) ->
      Left
        ProviderError
          { providerErrorKind = ExecutableMissing,
            providerErrorMessage = Text.pack (show exception)
          }
    Right (Right (ExitFailure _, _, stderrText)) ->
      Left
        ProviderError
          { providerErrorKind = classifyFailure (Text.pack stderrText),
            providerErrorMessage = compactError stderrText
          }
    Right (Right (ExitSuccess, stdoutText, _)) ->
      case eitherDecode (LazyTextEncoding.encodeUtf8 (LazyText.pack stdoutText)) of
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
runGh :: GhFetchGuard -> Repository -> [String] -> IO (ExitCode, String, String)
runGh guard repository arguments = bracketOnError (createProcess ghProcess) (abandonGh guard repository) run
  where
    ghProcess =
      (proc "gh" arguments)
        { std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

    -- The durable guard is written before this gh is used for anything, so
    -- it exists for as long as the process does. Nothing later has to
    -- succeed for a crash, a kill, or a quit at any point from here on to
    -- leave a record behind: the only write that must work is this one, and
    -- if it does not, the gh it would have covered is terminated instead of
    -- being allowed to run unguarded.
    run spawned = do
      registered <- registerSpawnedGh repository spawned
      case registered of
        Left message -> throwIO (GhGuardUnwritable message)
        -- The PID comes from the registration, captured while gh was still
        -- unreaped: 'collect' waits on the handle, and 'getPid' goes
        -- 'Nothing' the moment it does, which would leave the entry behind.
        Right groupPid -> do
          result <- collect spawned
          -- gh has exited, so the guard covering it has nothing left to
          -- cover. A failure to drop it is harmless: the next fetch finds
          -- that pgid unoccupied and clears the record itself.
          dropGhGroup repository groupPid
          pure result

    collect (input, output, errors, processHandle) = do
      mapM_ (ignoreIOException . hClose) input
      standardOutput <- drain output
      standardError <- drain errors
      -- Both pipes are drained to EOF before the exit status is collected,
      -- exactly as 'readProcessWithExitCode' did, so a response larger than
      -- the pipe buffer cannot deadlock gh against a reader that has not run
      -- yet.
      capturedOutput <- takeMVar standardOutput >>= either throwIO pure
      capturedError <- takeMVar standardError >>= either throwIO pure
      exitCode <- waitForProcess processHandle
      pure (exitCode, capturedOutput, capturedError)

    -- Each reader owns its handle for the handle's whole life, including
    -- closing it. Closing from here instead would mean closing a handle a
    -- reader thread may still be blocked on, which takes the handle's lock
    -- and would hang the very cleanup that has to finish promptly.
    drain Nothing = newEmptyMVar >>= \captured -> putMVar captured (Right "") >> pure captured
    drain (Just handle) = do
      captured <- newEmptyMVar
      void . forkIO $ do
        text <- try @IOException (hGetContents' handle)
        ignoreIOException (hClose handle)
        putMVar captured text
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
  outcome <- killGhGroup processHandle
  case outcome of
    Left (message, unconfirmed) -> do
      guard <- guardAfterFailedCleanup repository processHandle spawnedPid unconfirmed
      writeIORef cleanupFailure (Just (GhCleanupFailure message guard))
    -- Reaping cannot block here: the group was just confirmed empty, so gh
    -- is at most an unreaped zombie. It is skipped entirely when that
    -- confirmation failed, since waiting on a gh that is still running would
    -- block this thread and the refresh would never report anything at all.
    Right () -> do
      void (try @IOException (waitForProcess processHandle))
      mapM_ (dropGhGroup repository) spawnedPid
  mapM_ (ignoreIOException . hClose) input

ghGroupIsRecorded :: Repository -> Int -> IO Bool
ghGroupIsRecorded repository groupPid =
  any ((== groupPid) . ownedProcessGroupPid) <$> recordedGhGroups repository

-- | Everything still worth trying once the verified kill has failed, in
-- descending order of what it can promise. Each rung is attempted only
-- because the one above it did not hold, and the rung that succeeds is what
-- the caller reports.
--
-- The ordering is deliberate: a durable record is worth more than a forced
-- kill, because it survives this dashboard; and a forced kill is claimed
-- only once a fresh snapshot shows the group actually empty, since
-- signalling proves nothing about a member that never appeared in a census.
-- When even that cannot be shown, the record is tried once more — the
-- filesystem may simply have been busy — before admitting that nothing
-- durable is holding the line.
guardAfterFailedCleanup :: Repository -> ProcessHandle -> Maybe Int -> OwnedProcessGroup -> IO GhCleanupGuard
guardAfterFailedCleanup repository processHandle spawnedPid unconfirmed = do
  -- Upgrading the spawn-time guard to the full census is what lets a later
  -- run re-kill the group rather than only watch it, so it is worth
  -- attempting -- but nothing depends on it succeeding, because the entry
  -- written at spawn time already covers this pgid.
  recorded <- recordAndConfirm
  if recorded
    then pure GuardRecorded
    else do
      -- Nothing is on disk and nothing was verified, so a restart would find
      -- no reason to hold back. Force is the only thing left that does not
      -- depend on either facility that just failed.
      forceKillGhGroup processHandle spawnedPid
      emptied <- groupConfirmedEmpty unconfirmed.ownedProcessGroupPid
      if emptied
        then pure GuardForciblyTerminated
        else do
          retried <- recordAndConfirm
          pure (if retried then GuardRecorded else GuardInMemoryOnly)
  where
    recordAndConfirm = do
      void (recordGhGroup repository unconfirmed)
      ghGroupIsRecorded repository unconfirmed.ownedProcessGroupPid

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
groupConfirmedEmpty :: Int -> IO Bool
groupConfirmedEmpty groupPid = do
  snapshot <- defaultProcessSnapshot
  pure $ case snapshot of
    Left _ -> False
    Right processes -> null (groupMembers groupPid processes)

forcedReapTimeoutMicros :: Int
forcedReapTimeoutMicros = 5 * 1000 * 1000

-- | Terminates the process group led by a spawned @gh@ and confirms nothing
-- from it survives. The group is censused first so the confirmation covers
-- every member: a credential helper, or any other child gh starts, inherits
-- the group, and cleanup tracking only the leader would call the group dead
-- while a descendant kept running. A failure carries the group it could not
-- account for, so the caller can hand exactly that to the durable record.
killGhGroup :: ProcessHandle -> IO (Either (Text, OwnedProcessGroup) ())
killGhGroup processHandle = do
  spawnedPid <- getPid processHandle
  case spawnedPid of
    -- No PID left to signal: the handle has already been reaped, which only
    -- happens once gh has exited and been waited on.
    Nothing -> pure (Right ())
    Just pid -> do
      let groupPid = fromIntegral pid
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
          _ -> do
            let members = groupMembers groupPid processes
            result <- killVerifiedGroup groupPid members
            pure (first (,OwnedProcessGroup groupPid members True) result)

groupMembers :: Int -> [ProcessIdentity] -> [ProcessIdentity]
groupMembers groupPid = filter ((== groupPid) . processIdentityGroupPid)

-- | Raised when the durable guard covering a freshly spawned @gh@ cannot be
-- written. It is raised rather than returned so the spawn unwinds through
-- 'abandonGh' and that @gh@ is terminated: a process this fetch started must
-- never outlive the record that would have accounted for it.
newtype GhGuardUnwritable = GhGuardUnwritable Text
  deriving stock (Show)

instance Exception GhGuardUnwritable

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
reclaimRecordedGhGroups :: Repository -> IO (Either Text ())
reclaimRecordedGhGroups repository = do
  recordLoad <- loadGhGroupRecord repository
  case recordLoad of
    GhGroupRecordAbsent -> pure (Right ())
    GhGroupRecordUnusable message -> pure (Left (refusal message))
    GhGroupRecordLoaded groups -> do
      outcomes <- traverse reclaimGhGroup groups
      case [message | Left message <- outcomes] of
        [] -> do
          cleared <- removeGhGroupRecord repository
          pure (first refusal cleared)
        message : _ -> pure (Left (refusal message))
  where
    refusal message = "a gh process from an earlier GitHub refresh could not be confirmed stopped (" <> message <> "); refusing to start another until it is"

-- | One recorded group's second chance.
--
-- A censused group is identity-pinned and this dashboard's to signal, so it
-- gets the same verified TERM-then-KILL escalation again. An uncensused one
-- never can be, so it is only ever observed: whatever still matches it
-- refuses the fetch instead of being signalled blind, and — crucially — an
-- uncensused entry is never handed to the group check, whose empty
-- membership would read as vacuously absent and clear a live survivor.
reclaimGhGroup :: OwnedProcessGroup -> IO (Either Text ())
reclaimGhGroup group
  | group.ownedProcessGroupCensused =
      killVerifiedGroup group.ownedProcessGroupPid group.ownedProcessGroupMembers
  | otherwise = do
      snapshot <- defaultProcessSnapshot
      pure $ case snapshot of
        Left message -> Left message
        Right processes
          | null (survivors processes) -> Right ()
          | otherwise ->
              Left
                ( "a gh process (pgid "
                    <> Text.pack (show group.ownedProcessGroupPid)
                    <> ") was never safely identified and something matching it is still running; it cannot be signalled from here"
                )
  where
    -- With identities recorded, those exact processes are the question, PIDs
    -- pinned to start times. Without any, the only available question is
    -- whether that pgid is occupied at all, which is deliberately the
    -- broadest reading: refusing on an unrelated squatter merely blocks
    -- refreshing, while clearing on a survivor is the overlap itself.
    survivors processes = case group.ownedProcessGroupMembers of
      [] -> groupMembers group.ownedProcessGroupPid processes
      members -> matchingIdentities processes members

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

compactError :: String -> Text
compactError rawMessage =
  let message = Text.unwords (Text.words (Text.pack rawMessage))
   in if Text.null message then "GitHub request failed" else Text.take 500 message

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
  (labels, labelOverflow) <- parseNodes parseLabel object "labels"
  (assignees, assigneeOverflow) <- parseNodes parseAssignee object "assignees"
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

parsePullRequest :: Value -> Parser PullRequest
parsePullRequest = withObject "pull request" $ \object -> do
  mergeable <- object .: "mergeable"
  mergeStateStatus <- object .: "mergeStateStatus"
  (labels, labelOverflow) <- parseNodes parseLabel object "labels"
  (linkedIssues, linkedIssueOverflow) <- parseNodes parseIssueNumber object "closingIssuesReferences"
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
      <*> parseChecks object
      <*> object .: "createdAt"
      <*> object .: "updatedAt"
      <*> pure labelOverflow
      <*> pure linkedIssueOverflow

parseNodes :: (Value -> Parser item) -> Object -> Key -> Parser ([item], Int)
parseNodes itemParser object fieldName = do
  connection <- object .: fieldName
  withObject "nested connection" parseNested connection
  where
    parseNested nested = do
      nodeValues <- nested .:? "nodes" .!= []
      totalCount <- nested .: "totalCount"
      nodes <- traverse itemParser nodeValues
      if totalCount < length nodes
        then fail "nested connection totalCount was smaller than its node list"
        else pure (nodes, totalCount - length nodes)

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

parseChecks :: Object -> Parser CheckSummary
parseChecks object = do
  rollup <- object .:? "statusCheckRollup"
  case rollup of
    Nothing -> pure ChecksNone
    Just value -> withObject "status check rollup" parseRollup value
  where
    parseRollup rollup = do
      contexts <- rollup .: "contexts"
      withObject "check contexts" parseContexts contexts
    parseContexts contexts = do
      totalCount <- contexts .: "totalCount"
      values <- contexts .:? "nodes" .!= []
      parsed <- traverse parseCheckContext values
      if totalCount > length values
        then pure ChecksUnknown
        else pure (summarizeChecks parsed)

parseCheckContext :: Value -> Parser CheckContext
parseCheckContext = withObject "status check context" $ \context -> do
  contextType <- context .: "__typename"
  case (contextType :: Text) of
    "CheckRun" -> do
      name <- context .: "name"
      status <- context .: "status"
      conclusion <- context .:? "conclusion"
      startedAt <- context .:? "startedAt" .!= ""
      completedAt <- context .:? "completedAt" .!= ""
      app <- parseCheckRunApp context
      pure
        CheckContext
          { checkContextKey = "check:" <> app <> ":" <> name,
            checkContextName = name,
            checkContextStartedAt = if Text.null startedAt then completedAt else startedAt,
            checkContextState = classifyCheckRun status conclusion
          }
    "StatusContext" -> do
      name <- context .: "context"
      state <- context .: "state"
      createdAt <- context .:? "createdAt" .!= ""
      creator <- parseStatusCreator context
      pure
        CheckContext
          { checkContextKey = "status:" <> creator <> ":" <> name,
            checkContextName = name,
            checkContextStartedAt = createdAt,
            checkContextState = classifyStatusContext state
          }
    other -> fail ("unsupported status check context type: " <> Text.unpack other)

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
    latestContext left right
      | left.checkContextStartedAt >= right.checkContextStartedAt = left
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
  where
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
