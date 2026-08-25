-- | The repository-scoped lease: one repository, one holder, and no staleness
-- rule of Kanban's own.
--
-- Issue #501 names six acceptance signals. Five of them — contention, a killed
-- holder, two repositories under one cache root, one repository under two, and
-- an ordinary release — are about what one process observes of another, and
-- not one can be staged inside a single process. A POSIX record lock belongs
-- to the process, so the process that already holds one is granted it again
-- rather than refused, and a single-process version of any of the five would
-- pass while demonstrating the opposite of what it claimed.
-- "Spec.Support.LeaseProbes" is what makes the second process available, and
-- says more about the shape.
--
-- The sixth needs no second process and appears twice, once for a lock file
-- that cannot be opened and once for a directory that cannot be created,
-- because both are the same distinction: a lock file that cannot be used is
-- not a lock file somebody else is holding. That distinction is not cosmetic.
-- @F_SETLK@ reports contention as @EACCES@ or @EAGAIN@ depending on the
-- platform, and @EACCES@ is also what an ordinary permission failure raises —
-- so a classifier reading @errno@ without knowing which call produced it would
-- report an unusable cache as another board holding the repository, which is
-- the one thing a future startup refusal must never say.
--
-- The rest are requirements with no signal of their own. Two of them are about
-- the lease seen from inside one process, where @F_SETLK@ is no help
-- whatsoever: it grants the holder's second request rather than refusing it,
-- so a second acquisition has to be refused by Kanban, and a lease value left
-- over from an earlier acquisition must not be able to release the one that
-- replaced it. The other two are that the lease file is keyed and is shared
-- with nothing, and that a probe carries exactly one marker onward so that a
-- suite cannot start inside a suite.
module Spec.Repository.Lease (spec) where

import qualified Data.ByteString.Char8 as ByteString
import Data.List (isPrefixOf, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Kanban.Cache
  ( GhGroupRecordLoad (..),
    ghGroupRecordPath,
    ghGroupRecordSchemaVersion,
    loadGhGroupRecord,
    migrateGhGroupRecord,
    repositoryCachePath,
    repositoryLeasePath,
    usageCacheLockPath,
  )
import Kanban.Domain (Repository (..))
import Kanban.Process (OwnedProcessGroup (..))
import Kanban.Repository.Lease
  ( BoardLeaseOutcome (..),
    LeaseAcquisition (..),
    LeaseHolder (..),
    acquireBoardLease,
    acquireBoardLeaseWith,
    acquireRepositoryLease,
    boardLeaseAttempts,
    releaseRepositoryLease,
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.LeaseProbes
  ( LeaseProbe (..),
    LeaseProbeOutcome (..),
    awaitLeaseOutcome,
    killLeaseHolder,
    leaseHolderPid,
    leaseProbeEnvironment,
    leaseProbeVariable,
    openLeaseGate,
    releaseLeaseHolder,
    withLeaseProbes,
  )
import Data.IORef (newIORef, readIORef, writeIORef)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import System.Posix.Files (setFileMode)
import Test.Hspec

spec :: Spec
spec = do
  describe "the lease file" $ do
    -- Requirement 1. One resolution point, keyed by the repository's identity
    -- and the cache root and by nothing else.
    it "is one file per repository under the cache root" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          board <- repositoryLeasePath boardRepository
          other <- repositoryLeasePath otherRepository
          board `shouldNotBe` other
          takeDirectory board `shouldBe` takeDirectory other

    it "is a different file under a different cache root" $
      withTemporaryCacheRoot $ \root -> do
        here <- withEnvironmentValue "XDG_CACHE_HOME" (root </> "here") (repositoryLeasePath boardRepository)
        there <- withEnvironmentValue "XDG_CACHE_HOME" (root </> "there") (repositoryLeasePath boardRepository)
        here `shouldNotBe` there

    -- Requirement 4. POSIX drops every lock a process holds on a file the
    -- moment that process closes any descriptor referring to it, so a lease
    -- taken on a file some other code path opens and closes would be released
    -- by that code path without either of them knowing. The lease can only be
    -- safe on a file nothing else touches, and the first thing that has to be
    -- true of such a file is that it is not one of the files Kanban already
    -- reads, writes, replaces or locks under the same cache root.
    it "is none of the files Kanban already opens under that root" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          lease <- repositoryLeasePath boardRepository
          record <- ghGroupRecordPath boardRepository
          snapshot <- repositoryCachePath boardRepository
          usageLock <- usageCacheLockPath
          lease `shouldNotSatisfy` (`elem` [record, snapshot, usageLock])

  describe "acquiring the lease" $ do
    -- Acceptance 1. Two boards, one repository, one cache root, released
    -- together from the rendezvous. Neither probe lets go on its own, so
    -- whichever reaches the lock first is still holding it while the other
    -- tries: exactly one can be told it acquired.
    it "gives the repository to exactly one of two boards contending for it" $
      withTemporaryCacheRoot $ \root ->
        withLeaseProbes
          (root </> "probes")
          [ LeaseProbe "first" boardRepository (root </> "cache") "both",
            LeaseProbe "second" boardRepository (root </> "cache") "both"
          ]
          $ \probes -> do
            openLeaseGate probes "both"
            first <- awaitLeaseOutcome probes "first"
            second <- awaitLeaseOutcome probes "second"
            sort [first, second] `shouldBe` [ProbeAcquired, ProbeHeld]

    -- Acceptance 3. The authority is over a repository, never over the
    -- machine: a single global lock would pass the example above and fail
    -- this one.
    it "does not serialise two repositories under one cache root" $
      withTemporaryCacheRoot $ \root ->
        withLeaseProbes
          (root </> "probes")
          [ LeaseProbe "board" boardRepository (root </> "cache") "both",
            LeaseProbe "other" otherRepository (root </> "cache") "both"
          ]
          $ \probes -> do
            openLeaseGate probes "both"
            board <- awaitLeaseOutcome probes "board"
            other <- awaitLeaseOutcome probes "other"
            [board, other] `shouldBe` [ProbeAcquired, ProbeAcquired]

    -- Acceptance 4. The other half of the key. Two roots are two
    -- installations' worth of state, and a lease keyed on the repository alone
    -- would have them contend over a file neither of them shares.
    it "does not serialise one repository under two cache roots" $
      withTemporaryCacheRoot $ \root ->
        withLeaseProbes
          (root </> "probes")
          [ LeaseProbe "here" boardRepository (root </> "cache-here") "both",
            LeaseProbe "there" boardRepository (root </> "cache-there") "both"
          ]
          $ \probes -> do
            openLeaseGate probes "both"
            here <- awaitLeaseOutcome probes "here"
            there <- awaitLeaseOutcome probes "there"
            [here, there] `shouldBe` [ProbeAcquired, ProbeAcquired]

    -- Acceptance 5. The intruder is what keeps this from passing vacuously:
    -- it establishes that the lease really was held under these exact
    -- conditions, so the successor's acquisition can only be the release. And
    -- the holder is still running when the successor takes it, so process exit
    -- cannot be the explanation either.
    it "hands the repository on after an ordinary release" $
      withTemporaryCacheRoot $ \root ->
        withLeaseProbes
          (root </> "probes")
          [ LeaseProbe "holder" boardRepository (root </> "cache") "holder",
            LeaseProbe "intruder" boardRepository (root </> "cache") "intruder",
            LeaseProbe "successor" boardRepository (root </> "cache") "successor"
          ]
          $ \probes -> do
            openLeaseGate probes "holder"
            awaitLeaseOutcome probes "holder" `shouldReturn` ProbeAcquired
            openLeaseGate probes "intruder"
            awaitLeaseOutcome probes "intruder" `shouldReturn` ProbeHeld
            releaseLeaseHolder probes "holder"
            openLeaseGate probes "successor"
            awaitLeaseOutcome probes "successor" `shouldReturn` ProbeAcquired

    -- Acceptance 2. Requirement 6's whole recovery story: the kernel frees the
    -- lock, with nothing Kanban-side deciding the holder went stale and no
    -- human clearing anything. The kill lands only after the holder has
    -- reported that it actually holds the lease, and the intruder proves the
    -- lease was still being refused an instant before — otherwise a holder
    -- that had crashed at startup would produce the same successor.
    it "hands the repository on the moment a holder is killed" $
      withTemporaryCacheRoot $ \root ->
        withLeaseProbes
          (root </> "probes")
          [ LeaseProbe "holder" boardRepository (root </> "cache") "holder",
            LeaseProbe "intruder" boardRepository (root </> "cache") "intruder",
            LeaseProbe "successor" boardRepository (root </> "cache") "successor"
          ]
          $ \probes -> do
            openLeaseGate probes "holder"
            awaitLeaseOutcome probes "holder" `shouldReturn` ProbeAcquired
            openLeaseGate probes "intruder"
            awaitLeaseOutcome probes "intruder" `shouldReturn` ProbeHeld
            killLeaseHolder probes "holder"
            openLeaseGate probes "successor"
            awaitLeaseOutcome probes "successor" `shouldReturn` ProbeAcquired

    -- The same repository, twice, inside one process. @F_SETLK@ belongs to the
    -- process, so the kernel grants a second request from the holder rather
    -- than refusing it, and every one of that process's locks on the file goes
    -- the moment /any/ descriptor referring to it is closed. Two lease values
    -- in one process would therefore mean that letting either one go frees the
    -- repository while the other still reports that it holds it — this
    -- authority's own defect, moved indoors. The intruder is what shows the
    -- refusal changed nothing about the lease that is really held, and the
    -- successor is what shows the release still works afterwards.
    it "refuses a second acquisition inside the process already holding it" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" (root </> "cache") $ do
          path <- repositoryLeasePath boardRepository
          taken <- acquireRepositoryLease boardRepository
          case taken of
            LeaseAcquired lease ->
              withLeaseProbes
                (root </> "probes")
                [ LeaseProbe "intruder" boardRepository (root </> "cache") "intruder",
                  LeaseProbe "successor" boardRepository (root </> "cache") "successor"
                ]
                $ \probes -> do
                  acquireRepositoryLease boardRepository `shouldReturn` LeaseHeld path
                  openLeaseGate probes "intruder"
                  awaitLeaseOutcome probes "intruder" `shouldReturn` ProbeHeld
                  releaseRepositoryLease lease
                  openLeaseGate probes "successor"
                  awaitLeaseOutcome probes "successor" `shouldReturn` ProbeAcquired
            other -> expectationFailure ("expected the lease to be acquired, and it was " <> show other)

    -- The same hazard from the other side. A descriptor number is reused, so a
    -- second release of a lease already given up would close whatever now
    -- answers to that number — and if a later acquisition of the same
    -- repository is what answers to it, that release would silently free a
    -- lease its holder still believes in.
    it "ignores a release of a lease it has already given up" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" (root </> "cache") $ do
          taken <- acquireRepositoryLease boardRepository
          case taken of
            LeaseAcquired lease -> do
              releaseRepositoryLease lease
              retaken <- acquireRepositoryLease boardRepository
              case retaken of
                LeaseAcquired live ->
                  withLeaseProbes
                    (root </> "probes")
                    [LeaseProbe "intruder" boardRepository (root </> "cache") "intruder"]
                    $ \probes -> do
                      releaseRepositoryLease lease
                      openLeaseGate probes "intruder"
                      awaitLeaseOutcome probes "intruder" `shouldReturn` ProbeHeld
                      releaseRepositoryLease live
                other -> expectationFailure ("expected the lease to be retaken, and it was " <> show other)
            other -> expectationFailure ("expected the lease to be acquired, and it was " <> show other)

    -- Acceptance 6, at the open. @EACCES@ is the errno Linux also raises for
    -- a lock conflict, so a lease file this process may not open is the exact
    -- case in which classifying on errno alone — without knowing that only
    -- @F_SETLK@'s own failure can be contention — would announce that another
    -- board holds the repository.
    it "reports a lease file it may not open as unusable rather than as held" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          path <- repositoryLeasePath boardRepository
          createDirectoryIfMissing True (takeDirectory path)
          ByteString.writeFile path ""
          setFileMode path 0o000
          acquisition <- acquireRepositoryLease boardRepository
          case acquisition of
            LeaseUnusable reported _ -> reported `shouldBe` path
            other -> expectationFailure ("expected the lease to be unusable, and it was " <> show other)

    -- Acceptance 6 again, one step earlier: the directory the lease file lives
    -- in cannot be made at all. Requirement 3 covers creating, opening and
    -- locking, and this is the create.
    it "reports a lease directory it cannot create as unusable rather than as held" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          path <- repositoryLeasePath boardRepository
          createDirectoryIfMissing True (takeDirectory (takeDirectory path))
          ByteString.writeFile (takeDirectory path) "not a directory"
          acquisition <- acquireRepositoryLease boardRepository
          case acquisition of
            LeaseUnusable reported _ -> reported `shouldBe` path
            other -> expectationFailure ("expected the lease to be unusable, and it was " <> show other)

  -- The authority a dashboard actually takes: the same lock, plus the answer a
  -- refusal has to be built from. Every example below needs a second process
  -- for the same reason the ones above do -- a POSIX record lock belongs to
  -- the process, so a holder asked about its own lock is told nobody holds it.
  describe "a dashboard taking its repository" $ do
    -- The canonical key seen from where it matters. Two spellings of one
    -- GitHub repository, two independent processes, one lock: exactly one may
    -- be told it acquired. Under the case-preserving key this replaced, both
    -- would have been.
    it "makes two spellings of one repository contend" $
      withTemporaryCacheRoot $ \root ->
        withLeaseProbes
          (root </> "probes")
          [ LeaseProbe "upper" upperSpelling (root </> "cache") "both",
            LeaseProbe "lower" lowerSpelling (root </> "cache") "both"
          ]
          $ \probes -> do
            openLeaseGate probes "both"
            upper <- awaitLeaseOutcome probes "upper"
            lower <- awaitLeaseOutcome probes "lower"
            sort [upper, lower] `shouldBe` [ProbeAcquired, ProbeHeld]

    -- The other half of the key. These two repositories are the pair the old
    -- lossy mapping collapsed onto one file, so under it this example would
    -- have watched two unrelated boards refuse each other.
    it "does not make two repositories the old key confused contend" $
      withTemporaryCacheRoot $ \root ->
        withLeaseProbes
          (root </> "probes")
          [ LeaseProbe "owner" hyphenOwner (root </> "cache") "both",
            LeaseProbe "name" hyphenName (root </> "cache") "both"
          ]
          $ \probes -> do
            openLeaseGate probes "both"
            owner <- awaitLeaseOutcome probes "owner"
            name <- awaitLeaseOutcome probes "name"
            [owner, name] `shouldBe` [ProbeAcquired, ProbeAcquired]

    -- The refusal itself, made by this process against a holder it can name
    -- independently. The PID is the harness's record of the child it started,
    -- so what is compared is what @F_GETLK@ reported against who is really
    -- there.
    it "names the process holding the repository" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" (root </> "cache") $
          withLeaseProbes
            (root </> "probes")
            [LeaseProbe "holder" boardRepository (root </> "cache") "holder"]
            $ \probes -> do
              openLeaseGate probes "holder"
              awaitLeaseOutcome probes "holder" `shouldReturn` ProbeAcquired
              holder <- leaseHolderPid probes "holder"
              path <- repositoryLeasePath boardRepository
              acquireBoardLease boardRepository `shouldReturn` BoardLeaseContended path holder

    -- The same refusal reached from the other spelling, which is what the
    -- two-terminal acceptance check does.
    it "names the holder even when the two boards spell the repository differently" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" (root </> "cache") $
          withLeaseProbes
            (root </> "probes")
            [LeaseProbe "holder" upperSpelling (root </> "cache") "holder"]
            $ \probes -> do
              openLeaseGate probes "holder"
              awaitLeaseOutcome probes "holder" `shouldReturn` ProbeAcquired
              holder <- leaseHolderPid probes "holder"
              path <- repositoryLeasePath lowerSpelling
              acquireBoardLease lowerSpelling `shouldReturn` BoardLeaseContended path holder

    -- A fresh installation has no gh-groups directory at all, and the lease
    -- file is the first thing ever written into it. Without the acquisition
    -- creating that directory the board would refuse to open on every machine
    -- it had never run on.
    it "opens on a cache root that has never held a record" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" (root </> "cache") $ do
          path <- repositoryLeasePath boardRepository
          doesFileExist path `shouldReturn` False
          outcome <- acquireBoardLease boardRepository
          case outcome of
            BoardLeaseAcquired lease -> do
              doesFileExist path `shouldReturn` True
              releaseRepositoryLease lease
            other -> expectationFailure ("expected the repository to be taken, and it was " <> show other)

    -- The migration runs under the lease and scans the directory the lease
    -- file lives in. POSIX drops every lock a process holds on a file the
    -- moment it closes any descriptor on it, so a scan that so much as opened
    -- the lock would free the repository silently -- and the only way to see
    -- that is to ask another process afterwards.
    it "still holds the repository after migrating an older record beside it" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" (root </> "cache") $ do
          taken <- acquireBoardLease boardRepository
          case taken of
            BoardLeaseAcquired lease -> do
              record <- ghGroupRecordPath boardRepository
              writeLegacyRecord (takeDirectory record) "coghex-kanban.json"
              migrateGhGroupRecord boardRepository `shouldReturn` Right []
              loadGhGroupRecord boardRepository `shouldReturn` GhGroupRecordLoaded [OwnedProcessGroup 4242 [] False Nothing]
              withLeaseProbes
                (root </> "probes")
                [LeaseProbe "intruder" boardRepository (root </> "cache") "intruder"]
                $ \probes -> do
                  openLeaseGate probes "intruder"
                  awaitLeaseOutcome probes "intruder" `shouldReturn` ProbeHeld
              releaseRepositoryLease lease
            other -> expectationFailure ("expected the repository to be taken, and it was " <> show other)

    -- Acceptance 6 at the startup level: an unusable lease is not a board.
    it "reports a lease it cannot open as unusable rather than as a second board" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          path <- repositoryLeasePath boardRepository
          createDirectoryIfMissing True (takeDirectory path)
          ByteString.writeFile path ""
          setFileMode path 0o000
          outcome <- acquireBoardLease boardRepository
          case outcome of
            BoardLeaseUnusable reported _ -> reported `shouldBe` path
            other -> expectationFailure ("expected the lease to be unusable, and it was " <> show other)

  -- The race between the refusal and the question it raises. @F_SETLK@ says
  -- "somebody" and @F_GETLK@ is asked "who", and a holder that let go in
  -- between makes the second answer "nobody" -- which is neither a refusal to
  -- print nor a lease to assume is free. Both answers are supplied here
  -- because staging that interleaving against a real holder would be waiting
  -- for a coincidence.
  describe "a conflict whose holder has already gone" $ do
    it "attempts the lock again rather than refusing without a holder" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          attempts <- newIORef (0 :: Int)
          path <- repositoryLeasePath boardRepository
          -- The third attempt is a real acquisition, so what the retry ends in
          -- is a lease that was actually taken rather than a value assembled
          -- for the example.
          let attempt = do
                taken <- readIORef attempts
                writeIORef attempts (taken + 1)
                if taken >= 2 then acquireRepositoryLease boardRepository else pure (LeaseHeld path)
          outcome <- acquireBoardLeaseWith boardLeaseAttempts attempt (const (pure (Right HeldByNobody)))
          case outcome of
            BoardLeaseAcquired lease -> releaseRepositoryLease lease
            other -> expectationFailure ("expected the retry to end in an acquisition, and it was " <> show other)
          readIORef attempts `shouldReturn` 3

    -- Bounded, and what exhausting the bound costs. Startup fails, because a
    -- board that never established the lease has not established that it is
    -- alone -- and the message is an acquisition failure, never a refusal with
    -- nothing in the parentheses.
    it "fails the acquisition once the bound is spent, without naming a holder" $ do
      attempts <- newIORef (0 :: Int)
      let attempt = do
            taken <- readIORef attempts
            writeIORef attempts (taken + 1)
            pure (LeaseHeld "/tmp/board.lock")
      outcome <- acquireBoardLeaseWith 3 attempt (const (pure (Right HeldByNobody)))
      case outcome of
        BoardLeaseUnusable path detail -> do
          path `shouldBe` "/tmp/board.lock"
          detail `shouldSatisfy` Text.isInfixOf "no holder could be identified"
        other -> expectationFailure ("expected the acquisition to fail, and it was " <> show other)
      readIORef attempts `shouldReturn` 3

    it "stops the moment a holder can be named" $ do
      attempts <- newIORef (0 :: Int)
      let attempt = do
            taken <- readIORef attempts
            writeIORef attempts (taken + 1)
            pure (LeaseHeld "/tmp/board.lock")
      outcome <- acquireBoardLeaseWith boardLeaseAttempts attempt (const (pure (Right (HeldBy 4812))))
      outcome `shouldBe` BoardLeaseContended "/tmp/board.lock" 4812
      readIORef attempts `shouldReturn` 1

    -- Every acquisition error other than confirmed contention is fatal, and a
    -- query that cannot answer is one of them.
    it "treats a holder query that fails as an unusable lease" $ do
      outcome <- acquireBoardLeaseWith boardLeaseAttempts (pure (LeaseHeld "/tmp/board.lock")) (const (pure (Left "getLock refused")))
      outcome `shouldBe` BoardLeaseUnusable "/tmp/board.lock" "getLock refused"

    -- A board inside this process is not "another Kanban board", and saying
    -- so would put this process's own PID in a message telling the user to
    -- close it.
    it "treats a lease this process already holds as unusable, not as contention" $ do
      outcome <- acquireBoardLeaseWith boardLeaseAttempts (pure (LeaseHeld "/tmp/board.lock")) (const (pure (Right HeldByThisProcess)))
      case outcome of
        BoardLeaseUnusable _ detail -> detail `shouldSatisfy` Text.isInfixOf "a board in this process"
        other -> expectationFailure ("expected the acquisition to fail, and it was " <> show other)

  -- Requirement 8. A probe is the suite binary run again, so the environment
  -- it is handed decides which branch of @main@ it takes. Carrying the
  -- parent's markers onward would let a probe re-enter the lane runner or
  -- start probes of its own; either would spawn a suite inside a suite.
  describe "the probe environment" $
    it "carries exactly one Kanban marker onward, and it is the probe's own" $ do
      let carried =
            leaseProbeEnvironment
              [ ("PATH", "/usr/bin"),
                ("KANBAN_TEST_LANE", "ping"),
                ("KANBAN_TEST_LANE_REPORT", "/tmp/report"),
                ("KANBAN_USAGE_WRITER_PROBE", "/tmp/writer-plan.json"),
                (leaseProbeVariable, "/tmp/somebody-elses-plan.json")
              ]
              "/tmp/this-probe-plan.json"
      lookup "PATH" carried `shouldBe` Just "/usr/bin"
      filter (("KANBAN_" `isPrefixOf`) . fst) carried
        `shouldBe` [(leaseProbeVariable, "/tmp/this-probe-plan.json")]

-- | Two repositories that differ in owner and in name, so an example asserting
-- that they do not share a lease is not resting on either half alone.
boardRepository, otherRepository :: Repository
boardRepository = repositoryNamed "coghex" "kanban"
otherRepository = repositoryNamed "someone" "elses"

-- | One GitHub repository under two spellings, and the two repositories the
-- key this replaced mapped onto one file.
upperSpelling, lowerSpelling, hyphenOwner, hyphenName :: Repository
upperSpelling = repositoryNamed "Coghex" "Kanban"
lowerSpelling = repositoryNamed "coghex" "kanban"
hyphenOwner = repositoryNamed "coghex-kan" "ban"
hyphenName = repositoryNamed "coghex" "kan-ban"

-- | A record exactly as a release before the canonical key wrote one.
writeLegacyRecord :: FilePath -> FilePath -> IO ()
writeLegacyRecord directory name = do
  createDirectoryIfMissing True directory
  LazyByteString.writeFile
    (directory </> name)
    ( encode
        ( object
            [ "ghGroupSchemaVersion" .= ghGroupRecordSchemaVersion,
              "ghGroupRepositoryKey" .= ("coghex/kanban" :: Text),
              "ghGroupGroups" .= [OwnedProcessGroup 4242 [] False Nothing]
            ]
        )
    )

-- | The lease resolves from the identity and the cache root alone, so the
-- checkout path is deliberately one that does not exist: an example that
-- started to depend on it would fail rather than quietly read this machine.
repositoryNamed :: Text -> Text -> Repository
repositoryNamed owner name = Repository "/nonexistent/checkout" owner name
