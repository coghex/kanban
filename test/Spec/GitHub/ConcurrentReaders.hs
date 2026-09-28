-- | One @gh@ record lock per reader process (issue #742), and the arc's proof
-- that a dashboard, a mission runner, and a worker read one repository
-- together (epic #642, GHR-3).
--
-- Every example here runs its readers as processes of their own, through
-- "Spec.Support.ReaderProbes", because each claim is about a process: three
-- readers that share nothing but the files under the cache root, a refusal
-- that has to outlive one read within the process that took it, and a runner
-- that dies with its @gh@'s group still running.
module Spec.GitHub.ConcurrentReaders (spec) where

import Control.Exception (IOException, finally, try)
import Control.Monad (forM, forM_, void)
import qualified Data.ByteString.Char8 as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Text as Text
import Kanban.Cache (GhGroupRecordLoad (..), ghGroupRecordPath, loadGhGroupRecord)
import Kanban.Domain (Repository (..))
import Kanban.Process (OwnedProcessGroup (..), ProcessIdentity (..))
import Kanban.UI.Types (BoardRefreshOutcome (..))
import Kanban.Worker (workerPreconditionRefusal, workerUnverifiedTargetReason)
import Spec.Support.Board (captureBoardRefresh)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot, writeExecutableScript)
import Spec.Support.ReaderProbes
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Posix.Signals (nullSignal, sigKILL, signalProcess)
import System.Process (getPid, waitForProcess)
import Test.Hspec

spec :: Spec
spec = describe "one gh record lock per reader process" $ do
  -- The arc's promised proof. Each reader holds the lock its kind of process
  -- holds for its whole life, and each one's gh is held until all three have
  -- started, so the three are provably reading at once: every reclaim any of
  -- them takes finds the other two's entries on the record, from processes
  -- that are running and still hold their claims. Those are live work, never
  -- ghosts, so nothing refuses and nothing is signalled.
  it "lets a dashboard, a mission runner, and a worker read one repository at once from separate processes" $
    withReaderFixture 3 $ \fixture -> do
      probes <-
        forM
          [("dashboard", DashboardReader), ("runner", RunnerBoardReader), ("worker", WorkerReader)]
          (\(name, role) -> startIn fixture name role [] [])
      outcomes <- mapM awaitReaderOutcome probes
      forM_ (zip probes outcomes) $ \(probe, outcome) ->
        case outcome.readerOutcomeSteps of
          [step] -> (probe.readerProbeName, step.readerStepSucceeded, step.readerStepDetail) `shouldBe` (probe.readerProbeName, True, "")
          steps -> expectationFailure (probe.readerProbeName <> " took an unexpected set of reads: " <> show steps)
      markers <- listDirectory fixture.fixtureMarkers
      -- One gh each, every one of which answered, and none of which was sent
      -- TERM -- which is where any reader signalling another's healthy gh
      -- would have had to start.
      length (filter ("started." `isPrefixOf`) markers) `shouldBe` 3
      length (filter ("finished." `isPrefixOf`) markers) `shouldBe` 3
      filter ("signalled." `isPrefixOf`) markers `shouldBe` []
      -- And every entry left the record with the gh it named.
      recordAfter fixture >>= (`shouldSatisfy` recordHoldsNothing)

  describe "a refusal one read holds back" $ do
    -- Each of these is one reader process. Its first read runs where its gh
    -- can neither be recorded nor confirmed gone, which is the production
    -- path to a verdict only this process's memory holds. Every failure is
    -- then restored before the later reads, and the last read -- the control
    -- -- runs in that restored environment under a lock nothing has read
    -- through and succeeds: so a later read turned away here is turned away
    -- by this process's lock and by nothing ambient.
    it "turns away a runner's later target observation and board read after its board read" $
      void (latchedWithin (LatchSequence ReadBoard [ReadTarget, ReadBoard]))

    it "turns away a runner's later board read and target observation after its target observation" $
      void (latchedWithin (LatchSequence ReadTarget [ReadBoard, ReadTarget]))

    -- The issue-review host rereads the precondition of every child it
    -- adopts through its one lock, so a group one child's reread held back
    -- turns away the next child's -- as the unverified refusal the host
    -- already routes a failed reread to, not as a target that moved.
    it "turns away an issue-review host's later precondition rereads after one held a group back" $ do
      steps <- latchedWithin (LatchSequence ReadPrecondition [ReadPrecondition, ReadPrecondition])
      forM_ (consumersOf steps) $ \step ->
        workerPreconditionRefusal step.readerStepDetail `shouldBe` Just workerUnverifiedTargetReason

  -- A runner killed while its gh's group is still running leaves that group
  -- to whoever reads next. What makes a group reclaimable rather than only
  -- watched is a census (design Hazard B: a group recorded while its gh is
  -- still running is never signalled by anybody), and the runner writes one
  -- when its gh exits and leaves a process behind in the group. The runner is
  -- killed right after that, while its own cleanup of the survivor is held
  -- on its first process snapshot. The next dashboard refresh finds the entry
  -- of a writer that has exited and reclaims it with the existing verified
  -- escalation: the survivor ignores TERM, so only the KILL empties the group.
  it "reclaims, on the next dashboard refresh, the group an abandoned runner's gh left running" $
    withReaderFixture 1 $ \fixture -> do
      let survivorPath = fixture.fixtureRoot </> "survivor.pid"
          heldPath = fixture.fixtureRoot </> "ps-held.pid"
          psBin = fixture.fixtureRoot </> "ps-bin"
      recordPath <- withEnvironmentValue "XDG_CACHE_HOME" fixture.fixtureCache (ghGroupRecordPath fixture.fixtureRepository)
      void $ writeExecutableScript
        (fixture.fixtureGhBin </> "gh")
        ( [ "if [ -n \"$READER_LEAVE_SURVIVOR\" ]; then",
            ByteString.pack ("  sh -c 'trap \"\" TERM; echo $$ > " <> survivorPath <> "; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &"),
            ByteString.pack ("  while [ ! -s " <> survivorPath <> " ]; do sleep 0.05; done"),
            "fi"
          ]
            <> readerFakeGh fixture.fixtureMarkers 1
        )
      createDirectoryIfMissing True psBin
      void $
        writeExecutableScript
          (psBin </> "ps")
          [ ByteString.pack ("if grep -Eq '\"ownedProcessGroupCensused\" *: *true' " <> recordPath <> " 2>/dev/null; then"),
            ByteString.pack ("  echo $$ > " <> heldPath),
            "  exec sleep 120",
            "fi",
            "exec /bin/ps \"$@\""
          ]
      survivor <- newIORef (Nothing :: Maybe Int)
      heldPs <- newIORef (Nothing :: Maybe Int)
      let killRecorded ref = readIORef ref >>= mapM_ (\pid -> void (try @IOException (signalProcess sigKILL (fromIntegral pid))))
      ( do
          runner <- startIn fixture "runner" RunnerBoardReader [psBin] [("READER_LEAVE_SURVIVOR", "1")]
          awaitProbeFile runner "hold its own cleanup of the group its gh left" heldPath
          readPid heldPath >>= writeIORef heldPs . Just
          survivorPid <- readPid survivorPath
          writeIORef survivor (Just survivorPid)
          -- The staging is what it claims: one censused entry, marked
          -- pending, written by the runner, naming the group the survivor is
          -- still in.
          runnerPid <- fmap fromIntegral <$> getPid runner.readerProbeHandle
          recorded <- recordAfter fixture
          case recorded of
            GhGroupRecordLoaded [entry] -> do
              entry.ownedProcessGroupCensused `shouldBe` True
              entry.ownedProcessGroupCleanupPending `shouldBe` True
              fmap (.processIdentityPid) entry.ownedProcessGroupOwner `shouldBe` runnerPid
              map (.processIdentityPid) entry.ownedProcessGroupMembers `shouldContain` [survivorPid]
            other -> expectationFailure ("the runner did not leave one censused entry: " <> show other)
          -- Abandoned: killed outright, so nothing it would have done next
          -- happens, and the snapshot it was held on goes with it.
          mapM_ (signalProcess sigKILL . fromIntegral) runnerPid
          void (waitForProcess runner.readerProbeHandle)
          killRecorded heldPs
          alive survivorPid `shouldReturn` True
          (outcome, _) <-
            withEnvironmentValue "XDG_CACHE_HOME" fixture.fixtureCache $ do
              original <- fromMaybe "" <$> lookupEnv "PATH"
              withEnvironmentValue "PATH" (fixture.fixtureGhBin <> ":" <> original) $
                captureBoardRefresh fixture.fixtureRoot 30
          case outcome of
            BoardRefreshCompleted (Right _) -> pure ()
            other -> expectationFailure ("the dashboard did not reclaim the abandoned group and refresh: " <> show other)
          alive survivorPid `shouldReturn` False
          recordAfter fixture >>= (`shouldSatisfy` recordHoldsNothing)
        )
        `finally` (killRecorded survivor >> killRecorded heldPs)
  where
    alive :: Int -> IO Bool
    alive pid = either (const False) (const True) <$> try @IOException (signalProcess nullSignal (fromIntegral pid))

    readPid :: FilePath -> IO Int
    readPid path = read . filter (`notElem` (" \n" :: String)) <$> readFile path

-- | Runs one reader process's latch sequence and asserts what every such
-- sequence owes: the first read failed, every later read was refused before it
-- started a gh -- as the in-memory case, with nothing on the durable record to
-- refuse over -- and the control read in the same environment succeeded. The
-- steps come back for anything an example asserts beyond that.
latchedWithin :: ReaderRole -> IO [ReaderStep]
latchedWithin role = withReaderFixture 1 $ \fixture -> do
  probe <- startIn fixture "latch" role [] []
  outcome <- awaitReaderOutcome probe
  let steps = outcome.readerOutcomeSteps
  case steps of
    source : _ -> source.readerStepSucceeded `shouldBe` False
    [] -> expectationFailure "the probe took no reads"
  forM_ (consumersOf steps) $ \step -> do
    (step.readerStepLabel, step.readerStepSucceeded, step.readerStepSpawned) `shouldBe` (step.readerStepLabel, False, 0)
    Text.unpack step.readerStepDetail `shouldContain` "refusing to start another until it is"
  case reverse steps of
    control : _ -> do
      (control.readerStepLabel, control.readerStepSucceeded, control.readerStepSpawned) `shouldBe` (control.readerStepLabel, True, 1)
    [] -> pure ()
  -- Nothing durable holds the group back: the refusals were this process's
  -- memory, which is what makes them the in-memory case.
  outcome.readerOutcomeRecordEmpty `shouldBe` True
  pure steps

-- | The reads between the first and the control.
consumersOf :: [ReaderStep] -> [ReaderStep]
consumersOf steps = drop 1 (take (length steps - 1) steps)

data ReaderFixture = ReaderFixture
  { fixtureRoot :: FilePath,
    fixtureRepository :: Repository,
    fixtureCache :: FilePath,
    fixtureConfig :: FilePath,
    fixtureMarkers :: FilePath,
    fixtureGhBin :: FilePath,
    fixtureProbes :: IORef [ReaderProbe]
  }

-- | A temporary root with its own cache, configuration, marker directory, and
-- a fake @gh@ that holds until @quorum@ of its kind have started. Every probe
-- started through it is reaped on the way out, whatever the example did.
withReaderFixture :: Int -> (ReaderFixture -> IO result) -> IO result
withReaderFixture quorum body = withTemporaryCacheRoot $ \root -> do
  probes <- newIORef []
  let fixture =
        ReaderFixture
          { fixtureRoot = root,
            fixtureRepository = Repository root "coghex" "kanban",
            fixtureCache = root </> "cache",
            fixtureConfig = root </> "config",
            fixtureMarkers = root </> "markers",
            fixtureGhBin = root </> "gh-bin",
            fixtureProbes = probes
          }
  mapM_ (createDirectoryIfMissing True) [fixture.fixtureCache, fixture.fixtureConfig, fixture.fixtureMarkers, fixture.fixtureGhBin]
  void (writeExecutableScript (fixture.fixtureGhBin </> "gh") (readerFakeGh fixture.fixtureMarkers quorum))
  body fixture `finally` (readIORef probes >>= mapM_ reapReaderProbe)

startIn :: ReaderFixture -> String -> ReaderRole -> [FilePath] -> [(String, String)] -> IO ReaderProbe
startIn fixture name role leading extra = do
  probe <-
    startReaderProbe
      (fixture.fixtureRoot </> "probes")
      name
      role
      fixture.fixtureRepository
      fixture.fixtureCache
      fixture.fixtureConfig
      fixture.fixtureMarkers
      (leading <> [fixture.fixtureGhBin])
      extra
  modifyIORef' fixture.fixtureProbes (probe :)
  pure probe

recordAfter :: ReaderFixture -> IO GhGroupRecordLoad
recordAfter fixture = withEnvironmentValue "XDG_CACHE_HOME" fixture.fixtureCache (loadGhGroupRecord fixture.fixtureRepository)

recordHoldsNothing :: GhGroupRecordLoad -> Bool
recordHoldsNothing GhGroupRecordAbsent = True
recordHoldsNothing (GhGroupRecordLoaded []) = True
recordHoldsNothing _ = False
