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
import Kanban.Cache
  ( ghGroupRecordPath,
    repositoryCachePath,
    repositoryLeasePath,
    usageCacheLockPath,
  )
import Kanban.Domain (Repository (..))
import Kanban.Repository.Lease (LeaseAcquisition (..), acquireRepositoryLease, releaseRepositoryLease)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.LeaseProbes
  ( LeaseProbe (..),
    LeaseProbeOutcome (..),
    awaitLeaseOutcome,
    killLeaseHolder,
    leaseProbeEnvironment,
    leaseProbeVariable,
    openLeaseGate,
    releaseLeaseHolder,
    withLeaseProbes,
  )
import System.Directory (createDirectoryIfMissing)
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

-- | The lease resolves from the identity and the cache root alone, so the
-- checkout path is deliberately one that does not exist: an example that
-- started to depend on it would fail rather than quietly read this machine.
repositoryNamed :: Text -> Text -> Repository
repositoryNamed owner name = Repository "/nonexistent/checkout" owner name
