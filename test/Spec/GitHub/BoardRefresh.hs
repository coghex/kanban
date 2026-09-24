-- | Cleaning up the gh process group a board refresh launches.
module Spec.GitHub.BoardRefresh (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, finally, try)
import Control.Monad (void)
import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Either (isRight)
import Data.Maybe (isJust)
import qualified Data.Text
import Kanban.Cache (GhGroupRecordLoad (..), ghGroupRecordLockPath, ghGroupRecordPath, loadGhGroupRecord, writeGhGroupRecord)
import Kanban.Config (ResolvedConfig (..))
import Kanban.Domain
import Kanban.GitHub
  ( FetchState (..),
    GhCleanupFailure (..),
    GhCleanupGuard (..),
    GhEntryClass (..),
    GhEntryWriter (..),
    GhFetchGuard,
    GhSpawnRegistration (..),
    GitHubResult (..),
    abandonGh,
    advanceState,
    classifyGhEntry,
    confirmsOwnGroupLeadership,
    describeGhEntry,
    fetchGitHubSnapshot,
    ghBehindBarrier,
    ghFetchCleanupFailure,
    ghGroupIsPending,
    ghGroupIsRecorded,
    groupConfirmedEmpty,
    graphqlArguments,
    newGhFetchGuard,
    newGhRecordLock,
    reclaimRecordedGhGroups,
    recordGhGroup,
    registerSpawnedGh,
    spawnRegistrationGroup
  )
import Kanban.Process
  ( OwnedProcessGroup (..),
    ProcessIdentity (..),
    identityForPid,
    readProcessSnapshot
  )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.UI.Reconcile (unverifiedRefreshNotice)
import Kanban.UI.Types (BoardRefreshOutcome (..))
import Spec.Support.Board
  ( captureBoardRefresh,
    forcedCleanupRun,
    heldOffMessage,
    readMarkerPid,
    withFakeGh,
    withUnrecordableStore
  )
import Spec.Support.Env (withEnvironmentValue, withFakeOnPath, withTemporaryCacheRoot)
import Spec.Support.Fixtures (testResolvedConfig)
import Spec.Support.Expect (countOccurrences, requireJust, shouldMention, shouldNotMention)
import Spec.Support.Json
  ( emptyAssigneesJson,
    emptyClosingIssuesJson,
    emptyGraphqlPage,
    emptyLabelsJson,
    emptySubIssuesJson,
    githubIndependentPage,
    githubPageWithErrors,
    issueNodeJson,
    pullRequestNodeJson
  )
import Spec.Support.Locale
  ( LocaleProbe (..),
    unicodeFailureText,
    unicodeIssueTitles,
    withLocaleProbe
  )
import Spec.Support.Process (withNonLeaderProcess, withSurvivingGroupLeader, withVacatedGroupLeader)
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist, findExecutable, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (Handle, hClose)
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (CreatePipe),
    createProcess,
    getPid,
    proc,
    terminateProcess,
    waitForProcess
  )
import System.Timeout (timeout)
import Test.Hspec

-- | A registered @gh@ group, handed to @action@ in whatever state @process@
-- leaves its child.
--
-- The entry is written by 'registerSpawnedGh' rather than by hand, so what an
-- example asserts about is an entry the production registration actually
-- produced. The child is torn down afterwards whatever the example did with
-- it, since one that is still running when the example ends outlives the
-- temporary root it was registered under.
withRegisteredGroup ::
  CreateProcess ->
  (Repository -> GhFetchGuard -> GhSpawnRegistration -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO ()) ->
  IO ()
withRegisteredGroup process action =
  withTemporaryCacheRoot $ \temporaryRoot ->
    withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
      let repository = Repository temporaryRoot "coghex" "kanban"
      guard <- newGhRecordLock >>= newGhFetchGuard
      spawned@(_, _, _, processHandle) <-
        createProcess process {std_in = CreatePipe, create_group = True}
      -- The census the run takes for its own spawn, so the entry carries
      -- this process as its writer exactly as a real registration does.
      census <- readProcessSnapshot
      registered <- registerSpawnedGh guard repository census spawned
      case registered of
        Left message -> expectationFailure ("the group could not be registered: " <> Data.Text.unpack message)
        Right registration ->
          action repository guard registration spawned
            `finally` ( do
                          void (try @IOException (terminateProcess processHandle))
                          void (try @IOException (waitForProcess processHandle))
                      )

-- | A registered group whose handle has already been reaped, which is the
-- state 'collect' is in between waiting on its own child and dropping that
-- child's entry. @true@ stands in for @gh@: what matters is a real child that
-- leads its own group and then exits, not anything it prints.
withReapedRegistration ::
  (Repository -> GhFetchGuard -> GhSpawnRegistration -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO ()) ->
  IO ()
withReapedRegistration action =
  withRegisteredGroup (proc "true" []) $ \repository guard registration spawned@(_, _, _, processHandle) -> do
    _ <- waitForProcess processHandle
    action repository guard registration spawned

-- | A registered group whose child is still running and still unreaped, which
-- is the state the run is in from the instant the entry is persisted until it
-- is finally waited on.
withLiveRegistration ::
  (Repository -> GhFetchGuard -> GhSpawnRegistration -> (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO ()) ->
  IO ()
withLiveRegistration = withRegisteredGroup (proc "sleep" ["30"])

-- | Runs @action@ with the directory holding the durable record sealed against
-- writes, and puts it back afterwards so the temporary tree can still be torn
-- down.
--
-- Read and traverse are left alone, so the entry stays visible to whatever
-- asserts it is still there; only unlinking and rewriting it are refused.
withSealedRecordDirectory :: IO result -> IO result
withSealedRecordDirectory action = do
  directory <- takeDirectory <$> ghGroupRecordPath (Repository "" "coghex" "kanban")
  setFileMode directory 0o500
  action `finally` setFileMode directory 0o700

spec :: Spec
spec = do
  describe "board refresh gh process group cleanup" $ do
    it "kills the abandoned gh's whole process group, credential-helper descendant included, before it publishes the timeout" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let leaderMarker = temporaryRoot </> "gh.pid"
            descendantMarker = temporaryRoot </> "helper.pid"
        -- gh itself ignores TERM, standing in for one wedged on network I/O,
        -- and the helper it spawned inherits its process group and ignores
        -- TERM too. Cleanup that only TERMed the direct child -- what
        -- readProcessWithExitCode did -- leaves both of these running.
        withFakeGh
          temporaryRoot
          [ "trap '' TERM",
            "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &",
            "printf '%s\\n' \"$!\" > " <> ByteString.pack descendantMarker,
            "printf '%s\\n' \"$$\" > " <> ByteString.pack leaderMarker,
            "while :; do sleep 1; done"
          ]
          $ do
            (outcome, snapshotWhenPublished) <- captureBoardRefresh temporaryRoot 3
            leaderPid <- readMarkerPid leaderMarker
            descendantPid <- readMarkerPid descendantMarker
            -- The snapshot was taken by the publish callback itself, so this
            -- is the process table as of the instant the outcome was
            -- published -- not merely some time afterwards.
            case snapshotWhenPublished of
              Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
              Right identities -> do
                identityForPid leaderPid identities `shouldBe` Nothing
                identityForPid descendantPid identities `shouldBe` Nothing
            case outcome of
              BoardRefreshCompleted (Left providerError) -> providerError.providerErrorKind `shouldBe` RequestTimedOut
              other -> expectationFailure ("expected a clean timeout, got " <> show other)

    it "kills a descendant that joined the group after the census, while the members it did capture were exiting" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
            lateChild = binaryRoot </> "late-child"
            descendantMarker = temporaryRoot </> "late.pid"
        createDirectoryIfMissing True binaryRoot
        ByteString.writeFile lateChild (ByteString.unlines ["#!/bin/sh", "trap '' TERM", "while :; do sleep 1; done"])
        setFileMode lateChild 0o700
        -- gh forks this one from its own TERM handler and then exits, so it
        -- joins the group strictly after the census and every captured
        -- member is gone by the time the escalation re-checks them. A
        -- verification that only looked for the identities it captured would
        -- see them all absent, call the group clean, and report an ordinary
        -- timeout with this still running.
        withFakeGh
          temporaryRoot
          [ ByteString.pack ("trap '" <> lateChild <> " </dev/null >/dev/null 2>&1 & printf \"%s\" \"$!\" > " <> descendantMarker <> "; exit 0' TERM"),
            "while :; do sleep 1; done"
          ]
          $ do
            (outcome, snapshotWhenPublished) <- captureBoardRefresh temporaryRoot 3
            descendantPid <- readMarkerPid descendantMarker
            case snapshotWhenPublished of
              Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
              Right identities -> identityForPid descendantPid identities `shouldBe` Nothing
            case outcome of
              BoardRefreshCompleted (Left providerError) -> providerError.providerErrorKind `shouldBe` RequestTimedOut
              other -> expectationFailure ("expected a clean timeout, got " <> show other)

    -- Issue #645. The entry is keyed by the pgid the registration wrote, and
    -- 'getPid' stops answering the moment the handle is reaped -- so a cleanup
    -- that asked the handle for it would skip the drop in exactly the window
    -- 'collect' opens between reaping its own handle and dropping the entry.
    -- An interruption landing there would clear the guard over an entry still
    -- on disk, and the caller would publish an ordinary timeout for it.
    --
    -- Reached directly rather than by racing a real fetch into that window:
    -- the reap and the drop are adjacent instructions, so nothing about a
    -- fetch's timing can be arranged to land between them reliably.
    it "drops the registered entry even when the handle was already reaped" $
      withReapedRegistration $ \repository guard registration spawned -> do
        let groupPid = spawnRegistrationGroup registration
        ghGroupIsRecorded guard repository groupPid `shouldReturn` True
        abandonGh guard repository (Just registration) spawned
        ghGroupIsRecorded guard repository groupPid `shouldReturn` False
        ghFetchCleanupFailure guard `shouldReturn` Nothing

    -- And when that drop cannot happen, the same window must not be reported
    -- as a clean anything: the record still names the group, which is what the
    -- next fetch holds back over. The entry is marked cleanup-pending, since
    -- unmarked it would read as this live process's own work and be skipped.
    -- (The sealed directory refuses the unlink only: the record writer puts
    -- its directory's mode back before it rewrites, so the mark still lands.)
    it "reports a reaped handle's entry it could not drop, marked pending, instead of clearing" $
      withReapedRegistration $ \repository guard registration spawned ->
        withSealedRecordDirectory $ do
          let groupPid = spawnRegistrationGroup registration
          abandonGh guard repository (Just registration) spawned
          failure <- ghFetchCleanupFailure guard
          case failure of
            Nothing -> expectationFailure "an undropped record entry was reported as a clean cleanup"
            Just cleanup -> do
              cleanup.ghCleanupMessage
                `shouldSatisfy` Data.Text.isInfixOf "durable record entry could not be dropped"
              -- Exact rather than merely conservative: the next fetch --
              -- this process's own included -- re-checks the pending entry.
              cleanup.ghCleanupGuard `shouldBe` GuardRecorded
          ghGroupIsPending guard repository groupPid `shouldReturn` True

    -- The double failure: the store that refused the drop refuses the pending
    -- mark too. Unmarked, the entry reads as this live process's own work and
    -- no fetch would re-check it, so the refusal is held in memory rather than
    -- promising a re-check that will not happen. An unobtainable record lock
    -- is what refuses both here.
    it "holds a reaped handle's entry it could neither drop nor mark pending back in memory" $
      withReapedRegistration $ \repository guard registration spawned -> do
        let groupPid = spawnRegistrationGroup registration
        lockPath <- ghGroupRecordLockPath repository
        removeFile lockPath
        createDirectory lockPath
        abandonGh guard repository (Just registration) spawned
        failure <- ghFetchCleanupFailure guard
        case failure of
          Nothing -> expectationFailure "an undropped record entry was reported as a clean cleanup"
          Just cleanup -> do
            cleanup.ghCleanupMessage
              `shouldSatisfy` Data.Text.isInfixOf "durable record entry could not be dropped"
            cleanup.ghCleanupMessage `shouldMention` "nor could it be marked for re-verification"
            cleanup.ghCleanupGuard `shouldBe` GuardInMemoryOnly
        loaded <- loadGhGroupRecord repository
        case loaded of
          GhGroupRecordLoaded [entry] -> do
            entry.ownedProcessGroupPid `shouldBe` groupPid
            entry.ownedProcessGroupCleanupPending `shouldBe` False
          other -> expectationFailure ("expected the unmarked entry to remain, got " <> show other)

    -- Persisting the entry and publishing the pgid the cleanup will name it by
    -- are two steps with an interruptible gap between them, so a deadline can
    -- land after the record is on disk and before the cleanup was ever told
    -- which group it covers. Nothing has reaped the handle that early, so the
    -- drop has to fall back to the pid it still reports -- otherwise this is
    -- the same defect again, one window earlier.
    it "drops the persisted entry when cleanup was never told the pgid" $
      withLiveRegistration $ \repository guard registration spawned -> do
        let groupPid = spawnRegistrationGroup registration
        ghGroupIsRecorded guard repository groupPid `shouldReturn` True
        abandonGh guard repository Nothing spawned
        ghGroupIsRecorded guard repository groupPid `shouldReturn` False
        ghFetchCleanupFailure guard `shouldReturn` Nothing

    it "leaves a fast gh's decoded page untouched" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeGh
          temporaryRoot
          ["printf '%s' '" <> emptyGraphqlPage <> "'"]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Right githubResult) -> do
                githubResult.githubSnapshot.snapshotIssues `shouldBe` []
                githubResult.githubSnapshot.snapshotPullRequests `shouldBe` []
              other -> expectationFailure ("expected a decoded snapshot, got " <> show other)

    -- §12's sub-issue fields are validated against the schema before the
    -- query runs, so a deployment without them answers no data at all --
    -- which would fail every refresh, for every repository, including ones
    -- that use no sub-issues. The refresh drops the selection once and
    -- carries on with checklist-only membership, saying so in the banner.
    it "degrades to checklist-only membership when GitHub does not know the sub-issue fields" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let attempts = temporaryRoot </> "gh.attempts"
        withFakeGh
          temporaryRoot
          [ ByteString.pack ("printf 'x' >> " <> attempts),
            -- The query is one argument, so the whole argv is searched for
            -- the selection rather than a fixed position in it.
            "if printf '%s' \"$*\" | grep -q subIssues; then",
            "  printf '%s\\n' \"gh: Field 'subIssues' doesn't exist on type 'Issue'\" >&2",
            "  exit 1",
            "fi",
            "printf '%s' '" <> emptyGraphqlPage <> "'"
          ]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Right githubResult) -> do
                githubResult.githubSnapshot.snapshotIssues `shouldBe` []
                githubResult.githubWarnings
                  `shouldSatisfy` any (Data.Text.isInfixOf "did not recognize native sub-issue fields")
              other -> expectationFailure ("expected the refresh to degrade rather than fail, got " <> show other)
            -- Exactly one retry: the rejected attempt and the one that
            -- succeeded without the selection.
            readFile attempts `shouldReturn` "xx"

    -- Only GitHub's validation vocabulary for a field it does not have earns
    -- the retry. An ordinary failure that happens to quote the query must
    -- still reach the board as a failure, or a transient error would silently
    -- switch native membership off for the rest of the refresh.
    it "does not retry without sub-issues for an ordinary failure that merely quotes the query" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let attempts = temporaryRoot </> "gh.attempts"
        withFakeGh
          temporaryRoot
          [ ByteString.pack ("printf 'x' >> " <> attempts),
            "printf '%s\\n' 'gh: Something went wrong while executing your query: subIssues' >&2",
            "exit 1"
          ]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Left providerError) ->
                providerError.providerErrorKind `shouldBe` RequestFailed
              other -> expectationFailure ("expected the failure to reach the board, got " <> show other)
            readFile attempts `shouldReturn` "x"

    -- The stderr is gh 2.83.1's own text for a token it was given and the
    -- API rejected, so the refresh is reporting a failure gh can really
    -- produce rather than one shaped to match the classifier.
    it "leaves a failing gh's exit status and stderr untouched" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeGh
          temporaryRoot
          [ "printf '%s\\n' 'gh: Bad credentials (HTTP 401)' >&2",
            "exit 1"
          ]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Left providerError) -> do
                providerError.providerErrorKind `shouldBe` AuthenticationRequired
                Data.Text.unpack providerError.providerErrorMessage `shouldContain` "Bad credentials (HTTP 401)"
              other -> expectationFailure ("expected a reported gh failure, got " <> show other)

    -- classifyFailure's phrase list is unit-tested on its own; this is the
    -- integration half, proving an ordinary (non-credential) gh failure
    -- reaches the board as RequestFailed rather than AuthenticationRequired.
    it "classifies a non-authentication gh failure as an ordinary request failure" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeGh
          temporaryRoot
          [ "printf '%s\\n' 'gh: GraphQL: Something went wrong while executing your query (repository)' >&2",
            "exit 1"
          ]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Left providerError) -> do
                providerError.providerErrorKind `shouldBe` RequestFailed
                Data.Text.unpack providerError.providerErrorMessage
                  `shouldContain` "Something went wrong while executing your query"
              other -> expectationFailure ("expected a reported gh failure, got " <> show other)

    -- graphqlArguments' construction is unit-tested on its own; this drives
    -- a real two-page fetch through the actual gh invocation and proves the
    -- exact argv it builds is what reaches the subprocess on both the first
    -- page and the cursor-carrying follow-up, while accumulating both
    -- connections in the order the pages arrived.
    it "observes the exact first-page and cursor-page argv gh is invoked with, and preserves page order" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
            argvLog = temporaryRoot </> "argv.log"
            counterFile = temporaryRoot </> "invocation.count"
            firstPage =
              githubPageWithErrors
                []
                (Just "cursor-1")
                [issueNodeJson 41 [emptyLabelsJson, emptyAssigneesJson]]
                [pullRequestNodeJson 9 [emptyLabelsJson, emptyClosingIssuesJson]]
            secondPage =
              githubPageWithErrors
                []
                Nothing
                [issueNodeJson 42 [emptyLabelsJson, emptyAssigneesJson]]
                [pullRequestNodeJson 10 [emptyLabelsJson, emptyClosingIssuesJson]]
            initialState = FetchState [] [] Nothing Nothing True True True []
        decodedFirstPage <- case eitherDecode (LazyByteString.pack firstPage) of
          Left message -> fail ("undecodable fixture page: " <> message)
          Right page -> pure page
        secondPageState <- case advanceState initialState decodedFirstPage of
          Left providerError -> fail ("fixture page unexpectedly failed to advance: " <> show providerError)
          Right state -> pure state
        outcome <-
          withFakeGh
            temporaryRoot
            [ "for arg in \"$@\"; do printf '%s\\037' \"$arg\" >> " <> ByteString.pack argvLog <> "; done",
              "printf '\\036' >> " <> ByteString.pack argvLog,
              "count=$(( $(cat " <> ByteString.pack counterFile <> " 2>/dev/null || echo 0) + 1 ))",
              "printf '%s' \"$count\" > " <> ByteString.pack counterFile,
              "if [ \"$count\" -eq 1 ]; then printf '%s' '"
                <> ByteString.pack firstPage
                <> "'; else printf '%s' '"
                <> ByteString.pack secondPage
                <> "'; fi"
            ]
            (fst <$> captureBoardRefresh temporaryRoot 30)
        case outcome of
          BoardRefreshCompleted (Right githubResult) -> do
            map (.issueNumber) githubResult.githubSnapshot.snapshotIssues `shouldBe` [41, 42]
            map (.pullRequestNumber) githubResult.githubSnapshot.snapshotPullRequests `shouldBe` [9, 10]
          other -> expectationFailure ("expected a decoded two-page snapshot, got " <> show other)
        recordedBytes <- ByteString.readFile argvLog
        let invocations =
              map
                (map ByteString.unpack . init . ByteString.split '\US')
                (filter (not . ByteString.null) (ByteString.split '\RS' recordedBytes))
        case invocations of
          [firstArgv, secondArgv] -> do
            firstArgv `shouldBe` graphqlArguments repository initialState
            secondArgv `shouldBe` graphqlArguments repository secondPageState
          other -> expectationFailure ("expected exactly two recorded gh invocations, got " <> show (length other))

    -- The retired caps were 250 open issues and 100 open pull requests, so
    -- both connections here are deliberately longer than that: 251 issues
    -- over three pages and 101 pull requests over two. The pull requests
    -- finish first, which is the ordinary shape of an uncapped traversal --
    -- the last page asks for issues alone, and publication waits for it.
    it "follows both open connections past the retired caps to their final pages" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let pageCounter = temporaryRoot </> "page.count"
            -- Complete nodes, sub-issue answer included, so the only thing the
            -- banner could possibly report is the traversal itself.
            issueNodes numbers = [issueNodeJson number [emptyLabelsJson, emptyAssigneesJson, emptySubIssuesJson] | number <- numbers]
            pullRequestNodes numbers = [pullRequestNodeJson number [emptyLabelsJson, emptyClosingIssuesJson] | number <- numbers]
            pages =
              [ githubIndependentPage (Just (issueNodes [1 .. 100], Just "i1")) (Just (pullRequestNodes [1 .. 100], Just "p1")),
                githubIndependentPage (Just (issueNodes [101 .. 200], Just "i2")) (Just (pullRequestNodes [101 .. 101], Nothing)),
                -- Pull requests are done, so the query stops asking for them
                -- and the page comes back without that connection at all.
                githubIndependentPage (Just (issueNodes [201 .. 251], Nothing)) Nothing
              ]
        mapM_
          (\(index, page) -> writeFile (temporaryRoot </> ("page." <> show index <> ".json")) page)
          (zip [1 :: Int ..] pages)
        withFakeGh
          temporaryRoot
          [ ByteString.pack ("page=$(cat " <> pageCounter <> " 2>/dev/null || echo 0)"),
            "page=$((page + 1))",
            ByteString.pack ("printf '%s' \"$page\" > " <> pageCounter),
            ByteString.pack ("cat " <> temporaryRoot <> "/page.$page.json")
          ]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Right githubResult) -> do
                map (.issueNumber) githubResult.githubSnapshot.snapshotIssues `shouldBe` [1 .. 251]
                map (.pullRequestNumber) githubResult.githubSnapshot.snapshotPullRequests `shouldBe` [1 .. 101]
                -- Nothing about a complete traversal is worth warning over.
                githubResult.githubWarnings `shouldBe` []
              other -> expectationFailure ("expected every open item, got " <> show other)
            readMarkerPid pageCounter `shouldReturn` 3

    -- A page finishing inside the budget is what the deadline is about, not a
    -- traversal finishing inside it: every page here answers well within the
    -- configured timeout while the whole fetch takes comfortably longer than
    -- one such interval, and it must still publish.
    it "bounds each page by the configured timeout rather than the whole multi-page traversal" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let pageCounter = temporaryRoot </> "page.count"
            pages =
              [ githubIndependentPage
                  (Just ([issueNodeJson 41 [emptyLabelsJson, emptyAssigneesJson]], Just "i1"))
                  (Just ([], Nothing)),
                githubIndependentPage
                  (Just ([issueNodeJson 42 [emptyLabelsJson, emptyAssigneesJson]], Nothing))
                  Nothing
              ]
        mapM_
          (\(index, page) -> writeFile (temporaryRoot </> ("page." <> show index <> ".json")) page)
          (zip [1 :: Int ..] pages)
        withFakeGh
          temporaryRoot
          [ ByteString.pack ("page=$(cat " <> pageCounter <> " 2>/dev/null || echo 0)"),
            "page=$((page + 1))",
            ByteString.pack ("printf '%s' \"$page\" > " <> pageCounter),
            -- Two seconds each, under a three-second budget; four seconds
            -- together, over it. A whole-traversal deadline fails this.
            "sleep 2",
            ByteString.pack ("cat " <> temporaryRoot <> "/page.$page.json")
          ]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 3
            case outcome of
              BoardRefreshCompleted (Right githubResult) ->
                map (.issueNumber) githubResult.githubSnapshot.snapshotIssues `shouldBe` [41, 42]
              other -> expectationFailure ("expected the slow-but-answering traversal to publish, got " <> show other)
            readMarkerPid pageCounter `shouldReturn` 2

    -- The output is read as bytes and decoded once, leniently, as UTF-8, so a
    -- response GitHub truncated mid-character is a page with a replacement
    -- character in it rather than an exception thrown out of the decoder --
    -- which the locale path reported as a missing executable.
    it "replaces malformed bytes inside a decoded page instead of failing the refresh" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeGh
          temporaryRoot
          -- \377 is never a legal UTF-8 byte anywhere, so it cannot be read
          -- as a lone continuation or a truncated sequence.
          [ "printf '%s\\377%s' "
              <> "'{\"data\":{\"repository\":{\"issues\":{\"nodes\":[{\"number\":41,\"title\":\"Broken "
              <> "' '"
              <> "byte\",\"body\":\"B\",\"url\":\"https://example.test/issues/41\",\"state\":\"OPEN\","
              <> "\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"2026-01-02T00:00:00Z\"}],"
              <> "\"pageInfo\":{\"hasNextPage\":false}},"
              <> "\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}'"
          ]
          $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Right githubResult) ->
                map issueTitle githubResult.githubSnapshot.snapshotIssues
                  `shouldBe` [Data.Text.pack "Broken \65533byte"]
              other -> expectationFailure ("expected a decoded snapshot, got " <> show other)

    -- The one condition that cannot be established from in here: GHC fixes
    -- the locale encoding before main runs, so this re-runs the test binary
    -- as a child under LC_ALL=C and asserts on the bytes it wrote back.
    it "decodes a non-ASCII page and a non-ASCII failure identically under a C locale" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withLocaleProbe temporaryRoot $ \probe -> do
          -- Asserted before the decodes, so a fixture that never handed the
          -- child a C locale reports that rather than passing vacuously.
          probe.localeProbeLcAll `shouldBe` Data.Text.pack "C"
          probe.localeProbeTitles `shouldBe` Data.Text.intercalate "\n" unicodeIssueTitles
          probe.localeProbeFailureKind `shouldBe` Data.Text.pack (show AuthenticationRequired)
          probe.localeProbeFailureMessage `shouldBe` unicodeFailureText

    it "re-kills a gh group recorded by an earlier run before it fetches again, then clears the record" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- Stands in for the gh a previous dashboard could not confirm dead:
        -- still alive, still ignoring TERM, recorded on disk exactly as
        -- 'abandonGh' would have left it, by a writer that has since exited.
        -- Nothing in this process has ever seen it before -- which is the
        -- point, since the concern is a restarted dashboard racing a survivor.
        withSurvivingGroupLeader $ \survivorPid ->
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            snapshot <- readProcessSnapshot
            case snapshot of
              Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
              Right identities -> do
                let members = filter ((== survivorPid) . processIdentityGroupPid) identities
                members `shouldNotBe` []
                writeGhGroupRecord repository [OwnedProcessGroup survivorPid members True (Just exitedWriter) False] `shouldReturn` Right ()
            withFakeGh
              temporaryRoot
              [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                "printf '%s' '" <> emptyGraphqlPage <> "'"
              ]
              $ do
                (outcome, _) <- captureBoardRefresh temporaryRoot 30
                case outcome of
                  BoardRefreshCompleted (Right _) -> pure ()
                  other -> expectationFailure ("expected the refresh to proceed once the survivor was reclaimed, got " <> show other)
            -- The survivor is gone, and it was dealt with by the reclaim step
            -- rather than left to race the gh this refresh went on to spawn.
            reclaimed <- readProcessSnapshot
            case reclaimed of
              Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
              Right identities -> identityForPid survivorPid identities `shouldBe` Nothing
            doesFileExist ranMarker `shouldReturn` True
            (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "empties a recorded group whose member would fork a replacement from its TERM handler, without giving it the chance" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
            lateChild = binaryRoot </> "late-child"
            descendantMarker = temporaryRoot </> "late.pid"
            repository = Repository temporaryRoot "coghex" "kanban"
        createDirectoryIfMissing True binaryRoot
        ByteString.writeFile lateChild (ByteString.unlines ["#!/bin/sh", "trap '' TERM", "while :; do sleep 1; done"])
        setFileMode lateChild 0o700
        -- This member would fork a replacement from its TERM handler and
        -- exit. Under a TERM-first escalation that newcomer is unanswerable:
        -- it appears in no census taken while ownership was provable, and the
        -- member that proved ownership is gone by the time any census could
        -- see it -- a fork and an exit being quicker than a process listing.
        --
        -- Freezing the group first removes the opening rather than racing it.
        -- SIGSTOP cannot be handled, so the trap never runs, nothing is
        -- forked, and the census taken while the group is frozen is both
        -- complete and provably ours.
        (_, _, _, recordedLeader) <-
          createProcess
            (proc "sh" ["-c", "trap '" <> lateChild <> " </dev/null >/dev/null 2>&1 & printf \"%s\" \"$!\" > " <> descendantMarker <> "; exit 0' TERM; while :; do sleep 1; done </dev/null >/dev/null 2>&1"])
              {create_group = True}
        Just leaderPid <- fmap fromIntegral <$> getPid recordedLeader
        threadDelay 200000
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          snapshot <- readProcessSnapshot
          case snapshot of
            Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
            Right identities ->
              writeGhGroupRecord repository [OwnedProcessGroup leaderPid (filter ((== leaderPid) . processIdentityGroupPid) identities) True (Just exitedWriter) False]
                `shouldReturn` Right ()
          withFakeGh temporaryRoot ["printf '%s' '" <> emptyGraphqlPage <> "'"] $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Right _) -> pure ()
              other -> expectationFailure ("expected the reclaimed group to let the fetch proceed, got " <> show other)
          reclaimed <- readProcessSnapshot
          case reclaimed of
            Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
            Right identities -> identityForPid leaderPid identities `shouldBe` Nothing
          -- The trap never ran, so there is no replacement to account for.
          doesFileExist descendantMarker `shouldReturn` False
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "refuses to spawn gh while a non-leader record's saved gh is alive in some other process group" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- The record 'abandonGh' writes when create_group did not take
        -- effect: the pgid is gh's own PID, but gh is sitting in somebody
        -- else's group, so nothing ever has that pgid. Asking only about the
        -- pgid finds an empty group and calls the record spent -- while the
        -- gh it names is still running.
        withNonLeaderProcess $ \nonLeaderPid ->
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            snapshot <- readProcessSnapshot
            identity <- case snapshot >>= maybe (Left "fixture absent from snapshot") Right . identityForPid nonLeaderPid of
              Left message -> fail (Data.Text.unpack message)
              Right identity -> pure identity
            identity.processIdentityGroupPid `shouldNotBe` nonLeaderPid
            writeGhGroupRecord repository [OwnedProcessGroup nonLeaderPid [identity] False Nothing False] `shouldReturn` Right ()
            withFakeGh
              temporaryRoot
              [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                "printf '%s' '" <> emptyGraphqlPage <> "'"
              ]
              $ do
                (outcome, _) <- captureBoardRefresh temporaryRoot 30
                heldOffMessage outcome >>= (`shouldMention` "cannot be identified as this repository's")
            doesFileExist ranMarker `shouldReturn` False
            (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` True
        -- Once the saved gh exits the record has nothing left to name, so the
        -- refusal lifts on its own.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          withFakeGh
            temporaryRoot
            [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
              "printf '%s' '" <> emptyGraphqlPage <> "'"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                BoardRefreshCompleted (Right _) -> pure ()
                other -> expectationFailure ("expected the refresh to proceed once the saved gh exited, got " <> show other)
          doesFileExist ranMarker `shouldReturn` True
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "refuses to spawn gh while an uncensused record's pgid is still occupied, rather than reading its empty membership as absent" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- What 'abandonGh' records when the process snapshot itself failed:
        -- the pgid and nothing else. Handing that to a group membership check
        -- would find no recorded members present and call the group gone --
        -- vacuously, while it is plainly still running.
        withSurvivingGroupLeader $ \survivorPid ->
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            writeGhGroupRecord repository [OwnedProcessGroup survivorPid [] False Nothing False] `shouldReturn` Right ()
            withFakeGh
              temporaryRoot
              [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                "printf '%s' '" <> emptyGraphqlPage <> "'"
              ]
              $ do
                (outcome, _) <- captureBoardRefresh temporaryRoot 30
                heldOffMessage outcome >>= (`shouldMention` "cannot be identified as this repository's")
            doesFileExist ranMarker `shouldReturn` False
            -- The record survives the refusal: nothing about this attempt
            -- made the survivor any more accounted for.
            (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` True

    it "refuses to spawn gh while an uncensused record's own identity is still alive, then proceeds once it exits" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- What 'abandonGh' records when gh turned out not to lead its own
        -- group: the identity is exact, but its pgid covers processes this
        -- dashboard never spawned, so it may be watched and never signalled.
        survivorIdentity <-
          withSurvivingGroupLeader $ \survivorPid -> do
            snapshot <- readProcessSnapshot
            case snapshot >>= maybe (Left "fixture absent from snapshot") Right . identityForPid survivorPid of
              Left message -> fail (Data.Text.unpack message)
              Right identity -> do
                withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
                  writeGhGroupRecord repository [OwnedProcessGroup survivorPid [identity] False Nothing False] `shouldReturn` Right ()
                  withFakeGh
                    temporaryRoot
                    [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                      "printf '%s' '" <> emptyGraphqlPage <> "'"
                    ]
                    $ do
                      (outcome, _) <- captureBoardRefresh temporaryRoot 30
                      heldOffMessage outcome >>= (`shouldMention` "cannot be identified as this repository's")
                  doesFileExist ranMarker `shouldReturn` False
                pure identity
        -- 'withSurvivingGroupLeader' has now killed it, so the very same
        -- record clears itself: the guard is fail-closed, not a permanent
        -- wedge.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          survivorIdentity.processIdentityCommand `shouldMention` "TERM"
          withFakeGh
            temporaryRoot
            [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
              "printf '%s' '" <> emptyGraphqlPage <> "'"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                BoardRefreshCompleted (Right _) -> pure ()
                other -> expectationFailure ("expected the refresh to proceed once the survivor exited, got " <> show other)
          doesFileExist ranMarker `shouldReturn` True
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "refuses to spawn gh at all while a recorded group cannot be read back" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          recordPath <- ghGroupRecordPath repository
          createDirectoryIfMissing True (takeDirectory recordPath)
          -- A record that cannot be decoded means "a gh of ours may be live
          -- and we cannot tell which": treating that as "nothing recorded"
          -- is precisely the overlap this guard exists to prevent.
          ByteString.writeFile recordPath "{ this is not a gh group record"
          withFakeGh
            temporaryRoot
            [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
              "printf '%s' '" <> emptyGraphqlPage <> "'"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              heldOffMessage outcome >>= (`shouldMention` "refusing to start another")
          doesFileExist ranMarker `shouldReturn` False

    it "stops the gh it just spawned when no durable guard can be written for it, leaving nothing for a restart to overlap" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        -- An unwritable record is the case where the guard cannot be
        -- persisted at all. Since it is written before gh is used for
        -- anything, the failure is caught while gh is still this process's
        -- to terminate -- rather than after a timeout, when only an
        -- in-memory gate would be left and a restart would drop it.
        withUnrecordableStore temporaryRoot $
          withFakeGh
            temporaryRoot
            ["trap '' TERM", "while :; do sleep 1; done"]
            $ do
              -- The refresh timeout is short only so that a regression here
              -- fails fast: the guard is written before gh runs, so the real
              -- path never gets near it.
              (outcome, _) <- captureBoardRefresh temporaryRoot 2
              case outcome of
                BoardRefreshCompleted (Left providerError) -> do
                  providerError.providerErrorKind `shouldBe` RequestFailed
                  providerError.providerErrorMessage `shouldMention` "could not record the gh process it started"
                other -> expectationFailure ("expected the unguarded gh to be refused, got " <> show other)
              -- Asked of the process table rather than of a marker file the
              -- fake would have to win a race to write: whether it got as far
              -- as running or was stopped before it did, nothing from this
              -- fetch may still be alive for a restart to collide with.
              snapshot <- readProcessSnapshot
              case snapshot of
                Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
                Right identities ->
                  filter (Data.Text.isInfixOf (Data.Text.pack (temporaryRoot </> "bin")) . processIdentityCommand) identities
                    `shouldBe` []

    it "treats a forced kill as a clean outcome once a snapshot shows the whole group gone, descendant included" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- ps fails for exactly as long as the verified kill needs it (three
        -- attempts, the retry budget of 'defaultProcessSnapshot') and then
        -- works again, so the forced fallback runs and its own whole-group
        -- check is the thing that gets to answer. Because that check
        -- succeeds, this is not a failed cleanup at all: proven emptiness is
        -- the ordinary result no matter which signal established it.
        (outcome, survivors) <- forcedCleanupRun temporaryRoot 2 (Just 3)
        survivors `shouldBe` []
        case outcome of
          -- Reported as an ordinary failed refresh rather than an unverified
          -- cleanup, which is the point: the group was proven empty, so there
          -- is nothing left for a later refresh to overlap and no reason to
          -- hold the board off. Whether it surfaces as the guard-write
          -- failure or as the timeout depends on which the clock reached
          -- first, and neither is a claim about surviving processes.
          BoardRefreshCompleted (Left providerError) ->
            providerError.providerErrorKind `shouldSatisfy` (`elem` [RequestFailed, RequestTimedOut])
          other -> expectationFailure ("expected a plain failure once the group was proven empty, got " <> show other)

    it "makes no claim at all while no snapshot can confirm the group, but still takes the descendant with it" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- ps never works, so whole-group absence can never be shown and
        -- nothing durable can be written either. SIGKILL still went to the
        -- group, so the TERM-ignoring descendant is gone -- but that is not
        -- evidence, and the outcome must say so rather than infer from it.
        (outcome, survivors) <- forcedCleanupRun temporaryRoot 2 Nothing
        case outcome of
          BoardRefreshUnverified failure -> failure.ghCleanupGuard `shouldBe` GuardInMemoryOnly
          other -> expectationFailure ("expected an unguarded gh, got " <> show other)
        survivors `shouldBe` []

    it "finishes cleanup even when the refresh timer fires part-way through it" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        -- One second is a legal github_seconds, and cleanup needs longer than
        -- that: two 750ms grace windows plus snapshots. The timer therefore
        -- lands inside it. 'mask' does not stop that -- every one of those
        -- waits is an interruptible point -- so cleanup abandoned half-way
        -- would leave the TERM-resistant descendant running while the fetch
        -- reported an ordinary timeout. The store is unwritable throughout,
        -- so no durable record can paper over it either.
        (outcome, survivors) <- forcedCleanupRun temporaryRoot 1 (Just 0)
        -- The property is that nothing outlived the report. Whether the
        -- refresh surfaces the timeout or the guard-write failure depends on
        -- which the clock reached first, and neither is a claim about
        -- surviving processes.
        survivors `shouldBe` []
        case outcome of
          BoardRefreshCompleted (Left providerError) ->
            providerError.providerErrorKind `shouldSatisfy` (`elem` [RequestTimedOut, RequestFailed])
          BoardRefreshUnverified _ -> pure ()
          other -> expectationFailure ("expected the refresh to report a stopped gh, got " <> show other)

    it "cleans up a descendant that outlives a gh which exited normally, rather than deferring it" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
            lingerer = binaryRoot </> "lingerer"
            descendantMarker = temporaryRoot </> "lingerer.pid"
            repository = Repository temporaryRoot "coghex" "kanban"
        createDirectoryIfMissing True binaryRoot
        ByteString.writeFile lingerer (ByteString.unlines ["#!/bin/sh", "trap '' TERM", "while :; do sleep 1; done"])
        setFileMode lingerer 0o700
        -- gh answers correctly and exits 0, but leaves a descendant behind in
        -- its group with the pipes closed, so nothing about the ordinary
        -- collect path notices. The fetch records what it found and hands the
        -- group to cleanup without reaping, which is what leaves cleanup a
        -- live PID to escalate against -- so the descendant is dealt with
        -- here rather than deferred to whatever fetch comes next.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          withFakeGh
            temporaryRoot
            [ ByteString.pack (lingerer <> " </dev/null >/dev/null 2>&1 &"),
              ByteString.pack ("printf '%s' \"$!\" > " <> descendantMarker),
              "printf '%s' '" <> emptyGraphqlPage <> "'",
              "exit 0"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                -- The fetch failed -- it did leave a group it could not
                -- account for -- but the board is not held off, because
                -- cleanup went on to prove there is nothing left to hold off
                -- for. Holding off with nothing surviving would mean never
                -- refreshing again.
                BoardRefreshCompleted (Left providerError) ->
                  providerError.providerErrorMessage `shouldMention` "could not confirm stopped"
                other -> expectationFailure ("expected the unresolved group to be reported, got " <> show other)
          descendantPid <- readMarkerPid descendantMarker
          snapshot <- readProcessSnapshot
          case snapshot of
            Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
            Right identities -> identityForPid descendantPid identities `shouldBe` Nothing
          -- Nothing survives, so nothing is left on record either.
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "finishes reclaiming a recorded group even when the refresh timer fires during it" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- Reclaim signals a process group and then confirms what it did.
        -- Two recorded groups take comfortably longer than the one-second
        -- timeout to work through, so the timer certainly fires part-way.
        -- Interrupted there, reclaim would leave groups signalled but
        -- unestablished and the record uncleared -- and, because reclaim runs
        -- before the guard holds anything, the refresh would publish an
        -- ordinary timeout over whatever it had not got to.
        withSurvivingGroupLeader $ \survivorPid ->
          withSurvivingGroupLeader $ \secondPid ->
            withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
              snapshot <- readProcessSnapshot
              case snapshot of
                Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
                Right identities -> do
                  let membersOf pid = filter ((== pid) . processIdentityGroupPid) identities
                  membersOf survivorPid `shouldNotBe` []
                  membersOf secondPid `shouldNotBe` []
                  writeGhGroupRecord
                    repository
                    [ OwnedProcessGroup survivorPid (membersOf survivorPid) True (Just exitedWriter) False,
                      OwnedProcessGroup secondPid (membersOf secondPid) True (Just exitedWriter) False
                    ]
                    `shouldReturn` Right ()
              withFakeGh
                temporaryRoot
                [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                  "printf '%s' '" <> emptyGraphqlPage <> "'"
                ]
                $ do
                  -- Whatever the refresh goes on to report -- it may well
                  -- time out, and honestly so once the groups are provably
                  -- gone -- is not the point here. Whether reclaim finished
                  -- is.
                  void (captureBoardRefresh temporaryRoot 1)
              -- Both groups gone, and the record cleared: reclaim reached its
              -- confirming census and its own conclusion, rather than being
              -- abandoned after the signals with the record still standing.
              reclaimed <- readProcessSnapshot
              case reclaimed of
                Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
                Right identities -> do
                  identityForPid survivorPid identities `shouldBe` Nothing
                  identityForPid secondPid identities `shouldBe` Nothing
              (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "reports a reclaim that refused, even when the refresh timer fired while it was shielded" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
        -- Two recorded groups: the first this repository's and killable, the
        -- second occupied by a process no saved identity matches. Working
        -- through the first outlasts the one-second timeout, so the timer is
        -- already pending when the second is refused.
        --
        -- That pending exception is delivered the instant the shield's mask
        -- lifts, before anything outside it could run -- so a refusal decided
        -- inside and published outside would simply be lost, and the refresh
        -- would report an ordinary timeout over a record it had just failed
        -- to clear.
        withSurvivingGroupLeader $ \ourPid ->
          withSurvivingGroupLeader $ \squatterPid ->
            withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
              snapshot <- readProcessSnapshot
              case snapshot of
                Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
                Right identities -> do
                  let ours = filter ((== ourPid) . processIdentityGroupPid) identities
                      departed =
                        ProcessIdentity
                          { processIdentityPid = squatterPid,
                            processIdentityParentPid = 1,
                            processIdentityGroupPid = squatterPid,
                            processIdentityStartedAt = "Thu Jan 1 00:00:00 1970",
                            processIdentityCommand = "gh api graphql"
                          }
                  ours `shouldNotBe` []
                  writeGhGroupRecord
                    repository
                    [ OwnedProcessGroup ourPid ours True (Just exitedWriter) False,
                      OwnedProcessGroup squatterPid [departed] True (Just exitedWriter) False
                    ]
                    `shouldReturn` Right ()
              withFakeGh temporaryRoot ["printf '%s' '" <> emptyGraphqlPage <> "'"] $ do
                (outcome, _) <- captureBoardRefresh temporaryRoot 1
                heldOffMessage outcome >>= (`shouldMention` "cannot be identified as this repository's")
              -- The record stands, naming the group that was refused.
              (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` True

    it "does not mistake a gh that is still exiting for a group it leaked" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
        -- Closing the output is not exiting. This gh answers, closes both
        -- streams so the drain sees EOF, and only then takes its time going
        -- away. Censusing at EOF would find the leader itself still sitting
        -- in the group and refuse a perfectly good fetch -- which is why the
        -- census waits for the leader to leave the table first.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          withFakeGh
            temporaryRoot
            [ "printf '%s' '" <> emptyGraphqlPage <> "'",
              "exec 1>&- 2>&-",
              "sleep 0.4",
              "exit 0"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                BoardRefreshCompleted (Right _) -> pure ()
                other -> expectationFailure ("expected the slow-exiting gh to be accepted, got " <> show other)
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "keeps the record when it cannot census the group of a gh that exited normally" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- gh answers and exits perfectly, but by the time its group must be
        -- censused ps has stopped working, so nothing can establish that the
        -- group is empty. Reading "no census" as "nothing there" is what would
        -- drop the guard here.
        --
        -- ps is allowed to work for the first two calls -- the pre-release
        -- leadership check and the wait for gh to leave the table -- so the
        -- failure lands on the census itself rather than on an earlier guard
        -- that would refuse for an entirely different reason.
        let psCounter = temporaryRoot </> "ps.count"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          withFakeGh temporaryRoot ["printf '%s' '" <> emptyGraphqlPage <> "'"] $ do
            createDirectoryIfMissing True binaryRoot
            ByteString.writeFile
              (binaryRoot </> "ps")
              ( ByteString.unlines
                  [ "#!/bin/sh",
                    ByteString.pack ("attempt=$(cat " <> psCounter <> " 2>/dev/null || echo 0)"),
                    "attempt=$((attempt + 1))",
                    ByteString.pack ("printf '%s' \"$attempt\" > " <> psCounter),
                    "[ \"$attempt\" -gt 2 ] && exit 1",
                    "exec /bin/ps \"$@\""
                  ]
              )
            setFileMode (binaryRoot </> "ps") 0o700
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshUnverified failure ->
                -- The inner message, not the wrapper: the wrapper reads the
                -- same whichever guard refused, which would let this pass
                -- while testing an entirely different one.
                failure.ghCleanupMessage `shouldMention` "could not confirm gh's process group was empty"
              other -> expectationFailure ("expected the uncensusable group to be reported, got " <> show other)
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` True

    it "resolves each page's group before the next page starts, so a paginated fetch never guards two at once" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
            pageCounter = temporaryRoot </> "page.count"
            recordCopy = temporaryRoot </> "record-seen"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          recordPath <- ghGroupRecordPath repository
          -- Each invocation copies the guard record as it stood when that
          -- page's gh began. One snapshot fetch runs several sequential gh
          -- processes, and page N's entry must be gone by the time page N+1
          -- exists -- otherwise an abandoned earlier page would be left
          -- unresolved while a later one was already running.
          withFakeGh
            temporaryRoot
            [ ByteString.pack ("page=$(cat " <> pageCounter <> " 2>/dev/null || echo 0)"),
              "page=$((page + 1))",
              ByteString.pack ("printf '%s' \"$page\" > " <> pageCounter),
              ByteString.pack ("cp " <> recordPath <> " " <> recordCopy <> ".$page 2>/dev/null || true"),
              "if [ \"$page\" -eq 1 ]; then",
              "  printf '%s' '{\"data\":{\"repository\":{\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"c1\"}},\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}'",
              "else",
              "  printf '%s' '{\"data\":{\"repository\":{\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}'",
              "fi"
            ]
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                BoardRefreshCompleted (Right _) -> pure ()
                other -> expectationFailure ("expected the paginated fetch to succeed, got " <> show other)
          readMarkerPid pageCounter `shouldReturn` 2
          -- Page 2 began with exactly one guarded group on record: its own.
          secondPageRecord <- ByteString.readFile (recordCopy <> ".2")
          countOccurrences "ownedProcessGroupPid" secondPageRecord `shouldBe` 1
          -- And nothing is left guarded once the fetch completes.
          doesFileExist recordPath `shouldReturn` False

    it "refuses to let a child that does not lead its own group proceed to gh at all" $ do
      -- Every pgid question this module asks -- is the group empty, who is in
      -- it, may it be signalled -- presumes the number names this fetch's own
      -- group. When create_group has not taken effect it names nothing, and a
      -- helper the child leaves behind lives somewhere the module cannot see.
      -- So leadership is established while the child is parked on the barrier
      -- and has run nothing, which is both the only moment it is certainly
      -- observable and the only moment refusing is free.
      --
      -- create_group does take effect on this platform, so the two answers are
      -- asked of the check directly.
      withSurvivingGroupLeader $ \leaderPid -> confirmsOwnGroupLeadership leaderPid `shouldReturn` Right ()
      withNonLeaderProcess $ \nonLeaderPid -> do
        outcome <- confirmsOwnGroupLeadership nonLeaderPid
        case outcome of
          Left message -> message `shouldMention` "not the leader of its own process group"
          Right () -> expectationFailure "a non-leader child was accepted as leading its own group"

    it "does not read an unoccupied pgid as proof when the process it names is not that group's leader" $
      -- The forced fallback signals the spawned PID as a process group and
      -- then asks whether that group is empty. For a child that never became
      -- its own leader the signal reaches no group at all, and the pgid it
      -- names is unoccupied precisely because it does not exist -- so pgid
      -- emptiness alone would read as a successful kill while the process is
      -- plainly still running. create_group does take effect on this
      -- platform, so this is asked of the check directly.
      withNonLeaderProcess $ \nonLeaderPid -> do
        snapshot <- readProcessSnapshot
        case snapshot >>= maybe (Left "fixture absent from snapshot") Right . identityForPid nonLeaderPid of
          Left message -> expectationFailure (Data.Text.unpack message)
          Right identity -> identity.processIdentityGroupPid `shouldNotBe` nonLeaderPid
        groupConfirmedEmpty nonLeaderPid `shouldReturn` False

    it "never lets the child reach gh when the dashboard is lost before the guard is committed" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            fakeGh = temporaryRoot </> "gh"
        ByteString.writeFile fakeGh (ByteString.unlines ["#!/bin/sh", ByteString.pack ("printf '%s' ran > " <> ranMarker)])
        setFileMode fakeGh 0o700
        -- Standing in for the dashboard dying between 'createProcess' and the
        -- record being committed: the barrier is never released, and closing
        -- the pipe is exactly what a dead parent does. The child must exit
        -- having never executed gh, so a fresh fetch has nothing to overlap
        -- and nothing to have recorded.
        (Just barrierInput, _, _, child) <-
          createProcess (uncurry proc (ghBehindBarrier fakeGh ["api", "graphql"])) {std_in = CreatePipe, create_group = True}
        hClose barrierInput
        timeout 5000000 (waitForProcess child) `shouldReturn` Just ExitSuccess
        doesFileExist ranMarker `shouldReturn` False

    it "reports a gh that is missing from PATH as an unavailable executable" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
        createDirectoryIfMissing True binaryRoot
        -- PATH carries nothing but the empty shim directory -- deliberately
        -- not the system paths, since gh is installed in one of those on some
        -- machines and the point here is that it cannot be found. Nothing on
        -- this path needs ps either: the fetch fails at resolution, before
        -- any process is spawned to census.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" binaryRoot $ do
            (findExecutable "gh" >>= (`shouldBe` Nothing))
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Left providerError) -> providerError.providerErrorKind `shouldBe` ExecutableMissing
              other -> expectationFailure ("expected a missing gh, got " <> show other)

    it "refuses to signal a recorded pgid that some unrelated process now occupies, and keeps the record until it frees up" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        -- A recycled pgid: the record's saved identities are all long gone,
        -- and the pgid it names now belongs to somebody else entirely.
        -- Signalling it would kill processes this repository never started,
        -- so the only safe answer is to refuse and keep watching.
        withSurvivingGroupLeader $ \squatterPid ->
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            let departed =
                  ProcessIdentity
                    { processIdentityPid = squatterPid,
                      processIdentityParentPid = 1,
                      processIdentityGroupPid = squatterPid,
                      processIdentityStartedAt = "Thu Jan 1 00:00:00 1970",
                      processIdentityCommand = "gh api graphql"
                    }
            writeGhGroupRecord repository [OwnedProcessGroup squatterPid [departed] True Nothing False] `shouldReturn` Right ()
            withFakeGh
              temporaryRoot
              [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
                "printf '%s' '" <> emptyGraphqlPage <> "'"
              ]
              $ do
                (outcome, _) <- captureBoardRefresh temporaryRoot 30
                heldOffMessage outcome >>= (`shouldMention` "cannot be identified as this repository's")
            doesFileExist ranMarker `shouldReturn` False
            (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` True
            -- The squatter is untouched: refusing must not mean signalling.
            reclaimed <- readProcessSnapshot
            case reclaimed of
              Left message -> expectationFailure ("could not snapshot processes: " <> Data.Text.unpack message)
              Right identities -> identityForPid squatterPid identities `shouldSatisfy` isJust
        -- With the pgid free again the record clears on the next fetch.
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          withFakeGh temporaryRoot ["printf '%s' '" <> emptyGraphqlPage <> "'"] $ do
            (outcome, _) <- captureBoardRefresh temporaryRoot 30
            case outcome of
              BoardRefreshCompleted (Right _) -> pure ()
              other -> expectationFailure ("expected the refresh to proceed once the pgid was free, got " <> show other)
          (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    it "explains the unverified gh and what happens next, without offering a restart as the fix" $ do
      -- A recorded group self-heals on the next refresh; an unrecorded one
      -- leaves this dashboard unable to refresh at all. Neither may suggest
      -- restarting, which drops only the in-memory guard and would let a new
      -- gh overlap the old one.
      let noticeFor = unverifiedRefreshNotice . GhCleanupFailure "ps exited 1"
          recorded = noticeFor GuardRecorded
          inMemory = noticeFor GuardInMemoryOnly
      mapM_ (`shouldMention` "ps exited 1") [recorded, inMemory]
      mapM_ (`shouldMention` "could not be confirmed stopped") [recorded, inMemory]
      recorded `shouldMention` "the next refresh re-checks it"
      -- Neither notice may suggest restarting. Only a recorded group has
      -- anything that survives one, and a cleanup that proved the group gone
      -- does not produce a notice at all.
      inMemory `shouldMention` "check for a stray gh process"
      mapM_ (`shouldNotMention` "restarting is safe") [recorded, inMemory]

  -- Whose gh an entry is, decided by whether the process that wrote it is still
  -- running. That decides whether a reader skips the entry as live work or
  -- reclaims it, and nothing about what may be signalled.
  describe "the writer a recorded gh belongs to" $ do
    -- The reproduction: two readers that share the record but not a lock, as a
    -- mission runner's board read and a worker's precondition reread do beside
    -- a dashboard. The first reader's gh is on the record and running when the
    -- second reads it, and it is live work, not a ghost.
    it "lets an independent reader fetch while another reader's gh is still running, and both complete" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repository = Repository temporaryRoot "coghex" "kanban"
            counter = temporaryRoot </> "gh.count"
            firstStarted = temporaryRoot </> "first-started"
            releaseFirst = temporaryRoot </> "release-first"
            fetchWith recordLock = do
              guard <- newGhFetchGuard recordLock
              fetchGitHubSnapshot guard (const (pure ())) 30 testResolvedConfig.resolvedWorkflow repository
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withFakeGh
            temporaryRoot
            [ ByteString.pack ("count=$(( $(cat " <> counter <> " 2>/dev/null || echo 0) + 1 ))"),
              ByteString.pack ("printf '%s' \"$count\" > " <> counter),
              "if [ \"$count\" -eq 1 ]; then",
              ByteString.pack ("  : > " <> firstStarted),
              ByteString.pack ("  while [ ! -e " <> releaseFirst <> " ]; do sleep 0.05; done"),
              "fi",
              "printf '%s' '" <> emptyGraphqlPage <> "'"
            ]
            $ do
              firstLock <- newGhRecordLock
              secondLock <- newGhRecordLock
              firstOutcome <- newEmptyMVar
              _ <- forkIO (fetchWith firstLock >>= putMVar firstOutcome)
              awaitPath firstStarted
              -- The first reader's gh is running and on the record.
              loadGhGroupRecord repository >>= (`shouldSatisfy` recordsExactly 1)
              second <- fetchWith secondLock
              second `shouldSatisfy` isRight
              -- Skipped, not reclaimed: the first reader's entry is still there.
              loadGhGroupRecord repository >>= (`shouldSatisfy` recordsExactly 1)
              writeFile releaseFirst ""
              first <- timeout 20000000 (takeMVar firstOutcome)
              fmap isRight first `shouldBe` Just True
              (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    -- The case writer liveness alone would get wrong: a failed cleanup whose
    -- writer is still running. Its entry is marked pending, so the writer's own
    -- next fetch re-verifies it -- refusing while the group is still occupied
    -- and clearing it once it is not -- instead of skipping it as live work.
    it "re-verifies an entry its own failed cleanup left while its writer is still running" $
      withLiveRegistration $ \repository guard registration spawned@(_, _, _, processHandle) -> do
        let groupPid = spawnRegistrationGroup registration
        -- No census, so the cleanup can neither signal nor confirm anything:
        -- it records the group pending and reports it on disk.
        withTemporaryCacheRoot $ \scratch ->
          withFakeOnPath scratch ("ps", ["exit 1"]) (abandonGh guard repository (Just registration) spawned)
        fmap ghCleanupGuard <$> ghFetchCleanupFailure guard `shouldReturn` Just GuardRecorded
        ghGroupIsPending guard repository groupPid `shouldReturn` True
        nextGuard <- newGhRecordLock >>= newGhFetchGuard
        refused <- reclaimRecordedGhGroups nextGuard repository
        refusal refused `shouldMention` "a gh this process started, whose cleanup is still pending"
        ghGroupIsPending guard repository groupPid `shouldReturn` True
        terminateProcess processHandle
        void (waitForProcess processHandle)
        reclaimRecordedGhGroups nextGuard repository `shouldReturn` Right ()
        ghGroupIsRecorded guard repository groupPid `shouldReturn` False

    it "skips and keeps a live writer's entry while it reclaims an abandoned one beside it" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withSurvivingGroupLeader $ \writerPid ->
          withVacatedGroupLeader $ \vacatedPgid ->
            withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
              let repository = Repository temporaryRoot "coghex" "kanban"
              writer <- liveIdentity writerPid
              -- The live entry's pgid is occupied, which reclaiming it would
              -- refuse over; skipping it is what lets this reader proceed.
              let live = OwnedProcessGroup writerPid [] False (Just writer) False
                  abandoned = OwnedProcessGroup vacatedPgid [departedIn vacatedPgid] True (Just exitedWriter) False
              writeGhGroupRecord repository [live, abandoned] `shouldReturn` Right ()
              guard <- newGhRecordLock >>= newGhFetchGuard
              reclaimRecordedGhGroups guard repository `shouldReturn` Right ()
              loadGhGroupRecord repository `shouldReturn` GhGroupRecordLoaded [live]
              -- The live writer's identity survives the rewrite, and the writer
              -- itself was never signalled.
              liveIdentity writerPid `shouldReturn` writer

    it "keeps a live entry and an unresolved one when it reclaims the entry between them" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withSurvivingGroupLeader $ \writerPid ->
          withSurvivingGroupLeader $ \squatterPid ->
            withVacatedGroupLeader $ \vacatedPgid ->
              withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
                let repository = Repository temporaryRoot "coghex" "kanban"
                writer <- liveIdentity writerPid
                let live = OwnedProcessGroup writerPid [] False (Just writer) False
                    abandoned = OwnedProcessGroup vacatedPgid [departedIn vacatedPgid] True (Just exitedWriter) False
                    unresolved = OwnedProcessGroup squatterPid [] False Nothing False
                writeGhGroupRecord repository [live, abandoned, unresolved] `shouldReturn` Right ()
                guard <- newGhRecordLock >>= newGhFetchGuard
                refused <- reclaimRecordedGhGroups guard repository
                refusal refused `shouldMention` "a gh recorded without a writer identity"
                loadGhGroupRecord repository `shouldReturn` GhGroupRecordLoaded [live, unresolved]

    -- The behaviour change for entries an earlier release wrote: a census is
    -- no longer licence to signal one. It is watched until nothing matches it.
    it "never signals an ownerless entry, even a censused one whose members still hold its group" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withSurvivingGroupLeader $ \survivorPid ->
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            let repository = Repository temporaryRoot "coghex" "kanban"
            snapshot <- readProcessSnapshot
            members <- case snapshot of
              Left message -> fail ("could not snapshot processes: " <> Data.Text.unpack message)
              Right identities -> pure (filter ((== survivorPid) . processIdentityGroupPid) identities)
            members `shouldNotBe` []
            writeGhGroupRecord repository [OwnedProcessGroup survivorPid members True Nothing False] `shouldReturn` Right ()
            guard <- newGhRecordLock >>= newGhFetchGuard
            refused <- reclaimRecordedGhGroups guard repository
            refusal refused `shouldMention` "a gh recorded without a writer identity"
            refusal refused `shouldNotMention` "(pid "
            void (liveIdentity survivorPid)
            (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` True

    it "names an exited writer's pid when it refuses over what that writer left" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withSurvivingGroupLeader $ \squatterPid ->
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            let repository = Repository temporaryRoot "coghex" "kanban"
            writeGhGroupRecord
              repository
              [OwnedProcessGroup squatterPid [departedIn squatterPid] True (Just exitedWriter) False]
              `shouldReturn` Right ()
            guard <- newGhRecordLock >>= newGhFetchGuard
            refused <- reclaimRecordedGhGroups guard repository
            refusal refused `shouldMention` "a gh left by a Kanban process that has exited (pid 4812)"

    -- Liveness is a pid and a start time together, and a snapshot that could
    -- not be taken proves nothing either way.
    it "matches a writer by pid and start time, and reads a failed census as unknown" $
      withSurvivingGroupLeader $ \otherPid -> do
        self <- fromIntegral <$> getProcessID
        census <- readProcessSnapshot
        other <- liveIdentity otherPid
        me <- liveIdentity self
        let entry writer markedPending = OwnedProcessGroup 4200 [] False writer markedPending
            reused = other {processIdentityStartedAt = "Thu Jan 1 00:00:00 1970"}
            earlierHolderOfMyPid = me {processIdentityStartedAt = "Thu Jan 1 00:00:00 1970"}
        classifyGhEntry self census (entry (Just other) False) `shouldBe` GhEntryActive (WrittenByOtherProcess other)
        classifyGhEntry self census (entry (Just me) False) `shouldBe` GhEntryActive WrittenByThisProcess
        classifyGhEntry self census (entry (Just other) True) `shouldBe` GhEntryCleanupPending (WrittenByOtherProcess other)
        classifyGhEntry self census (entry (Just me) True) `shouldBe` GhEntryCleanupPending WrittenByThisProcess
        classifyGhEntry self census (entry (Just reused) False) `shouldBe` GhEntryAbandoned reused
        classifyGhEntry self census (entry (Just earlierHolderOfMyPid) False) `shouldBe` GhEntryAbandoned earlierHolderOfMyPid
        classifyGhEntry self (Left "ps exited 1") (entry (Just other) False) `shouldBe` GhEntryWriterUnknown other "ps exited 1"
        classifyGhEntry self census (entry Nothing True) `shouldBe` GhEntryOwnerless

    -- The live case never has to refuse to be described, so its spellings are
    -- asked of directly.
    it "spells every class truthfully, naming a writer's pid and never inventing one" $ do
      let writer = departedIn 4812
      describeGhEntry (GhEntryActive WrittenByThisProcess) `shouldMention` "this process is still running"
      describeGhEntry (GhEntryActive (WrittenByOtherProcess writer)) `shouldMention` "another running Kanban process (pid 4812) is still running"
      describeGhEntry (GhEntryCleanupPending WrittenByThisProcess) `shouldMention` "this process started, whose cleanup is still pending"
      describeGhEntry (GhEntryCleanupPending (WrittenByOtherProcess writer)) `shouldMention` "(pid 4812) started, whose cleanup is still pending"
      describeGhEntry (GhEntryAbandoned writer) `shouldMention` "has exited (pid 4812)"
      describeGhEntry (GhEntryWriterUnknown writer "ps exited 1") `shouldMention` "could not be confirmed running or exited"
      describeGhEntry GhEntryOwnerless `shouldMention` "without a writer identity"
      describeGhEntry GhEntryOwnerless `shouldNotMention` "(pid "

    -- Writer identity classifies and does nothing else. Neither an exited
    -- writer's reused pid nor a live writer is signalled, censused, or what
    -- keeps an entry alive: each record clears because its group is empty, and
    -- the process it names is still running afterwards.
    it "never signals or consults the process an entry names as its writer" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withSurvivingGroupLeader $ \ownerPid ->
          withVacatedGroupLeader $ \departedPgid ->
            withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
              let repository = Repository temporaryRoot "coghex" "kanban"
              liveOwner <- liveIdentity ownerPid
              let exitedOwner = departedIn ownerPid
                  emptyGroup owner = OwnedProcessGroup departedPgid [departedIn departedPgid] True (Just owner) True
              mapM_
                ( \owner -> do
                    writeGhGroupRecord repository [emptyGroup owner] `shouldReturn` Right ()
                    guard <- newGhRecordLock >>= newGhFetchGuard
                    reclaimRecordedGhGroups guard repository `shouldReturn` Right ()
                    (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False
                    liveIdentity ownerPid `shouldReturn` liveOwner
                )
                [exitedOwner, liveOwner]

  describe "resolving a spawn's writer" $ do
    it "stamps a spawn's entry with this process as the spawn's own census shows it" $
      withLiveRegistration $ \repository _ registration _ -> do
        self <- fromIntegral <$> getProcessID
        case registration of
          GhSpawnRecorded groupPid writer -> do
            writer.processIdentityPid `shouldBe` self
            loadGhGroupRecord repository `shouldReturn` GhGroupRecordLoaded [OwnedProcessGroup groupPid [] False (Just writer) False]
          GhSpawnInMemory _ -> expectationFailure "a spawn whose census named this process was held in memory"

    it "keeps an entry's writer through a rewrite that does not name one, and never writes an entry without one" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository temporaryRoot "coghex" "kanban"
              writer = departedIn 4812
          guard <- newGhRecordLock >>= newGhFetchGuard
          recordGhGroup guard repository (OwnedProcessGroup 4200 [] False (Just writer) False) `shouldReturn` Right ()
          recordGhGroup guard repository (OwnedProcessGroup 4200 [departedIn 4201] True Nothing True) `shouldReturn` Right ()
          loadGhGroupRecord repository `shouldReturn` GhGroupRecordLoaded [OwnedProcessGroup 4200 [departedIn 4201] True (Just writer) True]
          refused <- recordGhGroup guard repository (OwnedProcessGroup 4300 [] False Nothing False)
          refusal refused `shouldMention` "an entry without one is never written"
          loadGhGroupRecord repository `shouldReturn` GhGroupRecordLoaded [OwnedProcessGroup 4200 [departedIn 4201] True (Just writer) True]

    it "holds a spawn in memory when its writer cannot be identified and the record is empty, then records the next spawn normally" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository temporaryRoot "coghex" "kanban"
          guard <- newGhRecordLock >>= newGhFetchGuard
          withParkedChild $ \first -> do
            held <- registerSpawnedGh guard repository (Left "ps exited 1") first
            firstPid <- childGroup first
            held `shouldBe` Right (GhSpawnInMemory firstPid)
            loadGhGroupRecord repository `shouldReturn` GhGroupRecordAbsent
          withParkedChild $ \second -> do
            census <- readProcessSnapshot
            recorded <- registerSpawnedGh guard repository census second
            self <- fromIntegral <$> getProcessID
            case recorded of
              Right (GhSpawnRecorded groupPid writer) -> do
                writer.processIdentityPid `shouldBe` self
                loadGhGroupRecord repository `shouldReturn` GhGroupRecordLoaded [OwnedProcessGroup groupPid [] False (Just writer) False]
              other -> expectationFailure ("expected the next spawn to be recorded, got " <> show other)

    it "refuses a spawn whose writer cannot be identified while the record holds anything" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository temporaryRoot "coghex" "kanban"
              existing = OwnedProcessGroup 4200 [] False (Just (departedIn 4812)) False
          writeGhGroupRecord repository [existing] `shouldReturn` Right ()
          guard <- newGhRecordLock >>= newGhFetchGuard
          withParkedChild $ \child -> do
            refused <- registerSpawnedGh guard repository (Left "ps exited 1") child
            either id (const "") refused `shouldMention` "could not identify the process starting gh"
            loadGhGroupRecord repository `shouldReturn` GhGroupRecordLoaded [existing]

    -- Whether the cleanup knew the spawn was held in memory, or was
    -- interrupted before it was told anything, a group it cannot account for
    -- stays in memory and nothing ownerless reaches the record.
    it "writes no entry when a spawn held in memory cannot be cleaned up" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository temporaryRoot "coghex" "kanban"
          mapM_
            ( \told -> withParkedChild $ \child -> do
                guard <- newGhRecordLock >>= newGhFetchGuard
                admitted <- registerSpawnedGh guard repository (Left "ps exited 1") child
                registration <- either (fail . Data.Text.unpack) pure admitted
                withFakeOnPath temporaryRoot ("ps", ["exit 1"]) $
                  abandonGh guard repository (if told then Just registration else Nothing) child
                fmap ghCleanupGuard <$> ghFetchCleanupFailure guard `shouldReturn` Just GuardInMemoryOnly
                loadGhGroupRecord repository `shouldReturn` GhGroupRecordAbsent
            )
            [True, False]

    it "never lets gh run while no process snapshot can be taken" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let ranMarker = temporaryRoot </> "gh-ran"
            repository = Repository temporaryRoot "coghex" "kanban"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withFakeGh
            temporaryRoot
            [ "printf '%s' 'ran' > " <> ByteString.pack ranMarker,
              "printf '%s' '" <> emptyGraphqlPage <> "'"
            ]
            $ withFakeOnPath temporaryRoot ("ps", ["exit 1"])
            $ do
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                BoardRefreshCompleted (Left providerError) ->
                  providerError.providerErrorMessage `shouldMention` "could not confirm gh leads its own process group"
                other -> expectationFailure ("expected the spawn to be refused, got " <> show other)
              doesFileExist ranMarker `shouldReturn` False
              (ghGroupRecordPath repository >>= doesFileExist) `shouldReturn` False

    -- End to end: the first page's writer census fails (every retry of it),
    -- its gh runs held in memory after its own leadership check, and the
    -- second page's census succeeds and is recorded as usual.
    it "recovers durable recording on the next spawn after one transient census failure" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
            repository = Repository temporaryRoot "coghex" "kanban"
            psCounter = temporaryRoot </> "ps.count"
            pageCounter = temporaryRoot </> "page.count"
            recordCopy = temporaryRoot </> "record-seen"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          recordPath <- ghGroupRecordPath repository
          withFakeGh
            temporaryRoot
            [ ByteString.pack ("page=$(cat " <> pageCounter <> " 2>/dev/null || echo 0)"),
              "page=$((page + 1))",
              ByteString.pack ("printf '%s' \"$page\" > " <> pageCounter),
              ByteString.pack ("cp " <> recordPath <> " " <> recordCopy <> ".$page 2>/dev/null || true"),
              "if [ \"$page\" -eq 1 ]; then",
              "  printf '%s' '{\"data\":{\"repository\":{\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"c1\"}},\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}'",
              "else",
              "  printf '%s' '{\"data\":{\"repository\":{\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}'",
              "fi"
            ]
            $ do
              createDirectoryIfMissing True binaryRoot
              -- Three failures: exactly the retry budget of the first page's
              -- writer census, and nothing after it.
              ByteString.writeFile
                (binaryRoot </> "ps")
                ( ByteString.unlines
                    [ "#!/bin/sh",
                      ByteString.pack ("attempt=$(cat " <> psCounter <> " 2>/dev/null || echo 0)"),
                      "attempt=$((attempt + 1))",
                      ByteString.pack ("printf '%s' \"$attempt\" > " <> psCounter),
                      "[ \"$attempt\" -le 3 ] && exit 1",
                      "exec /bin/ps \"$@\""
                    ]
                )
              setFileMode (binaryRoot </> "ps") 0o700
              (outcome, _) <- captureBoardRefresh temporaryRoot 30
              case outcome of
                BoardRefreshCompleted (Right _) -> pure ()
                other -> expectationFailure ("expected the fetch to complete, got " <> show other)
          readMarkerPid pageCounter `shouldReturn` 2
          -- Page 1 ran with nothing on the record, ownerless or otherwise.
          doesFileExist (recordCopy <> ".1") `shouldReturn` False
          -- Page 2 ran recorded, under this process as its writer.
          secondPageRecord <- ByteString.readFile (recordCopy <> ".2")
          countOccurrences "ownedProcessGroupPid" secondPageRecord `shouldBe` 1
          self <- getProcessID
          secondPageRecord `shouldSatisfy` ByteString.isInfixOf (ByteString.pack ("\"processIdentityPid\":" <> show self))
          doesFileExist recordPath `shouldReturn` False

-- | A recorded member identity for a PID, with a start time far enough in the
-- past that nothing running now can match it.
departedIn :: Int -> ProcessIdentity
departedIn processId =
  ProcessIdentity
    { processIdentityPid = processId,
      processIdentityParentPid = 1,
      processIdentityGroupPid = processId,
      processIdentityStartedAt = "Thu Jan 1 00:00:00 1970",
      processIdentityCommand = "gh api graphql"
    }

-- | A running process's own recorded identity, start time included, so a
-- record naming it survives 'matchingIdentities' the way one naming a departed
-- process cannot.
liveIdentity :: Int -> IO ProcessIdentity
liveIdentity processId = do
  snapshot <- readProcessSnapshot
  case snapshot of
    Left message -> fail ("could not snapshot processes: " <> Data.Text.unpack message)
    Right identities ->
      requireJust ("process " <> show processId <> " was gone before its identity could be read") (identityForPid processId identities)

refusal :: Either Data.Text.Text () -> Data.Text.Text
refusal = either id (const "")

-- | The writer of an entry left behind by a process that has since exited: a
-- pid whose recorded start time nothing running now can match.
exitedWriter :: ProcessIdentity
exitedWriter = departedIn 4812

recordsExactly :: Int -> GhGroupRecordLoad -> Bool
recordsExactly count (GhGroupRecordLoaded groups) = length groups == count
recordsExactly _ _ = False

-- | Waits for a fixture's marker file, failing rather than hanging.
awaitPath :: FilePath -> IO ()
awaitPath path = go (200 :: Int)
  where
    go remaining = do
      present <- doesFileExist path
      if present
        then pure ()
        else
          if remaining <= 0
            then expectationFailure (path <> " never appeared")
            else threadDelay 50000 >> go (remaining - 1)

-- | A child parked the way the run parks gh: leading its own group, with a
-- standard input to release it through. It never is released, and is killed
-- and reaped afterwards whatever the example did.
withParkedChild :: ((Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO ()) -> IO ()
withParkedChild action = do
  spawned@(_, _, _, processHandle) <-
    createProcess (proc "sleep" ["30"]) {std_in = CreatePipe, create_group = True}
  action spawned
    `finally` ( do
                  void (try @IOException (terminateProcess processHandle))
                  void (try @IOException (waitForProcess processHandle))
              )

childGroup :: (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle) -> IO Int
childGroup (_, _, _, processHandle) = maybe (fail "the parked child reported no PID") (pure . fromIntegral) =<< getPid processHandle
