{-# LANGUAGE OverloadedStrings #-}

-- | The one-item precondition read, against a fake @gh@ on @PATH@.
--
-- Two properties are asserted here and neither can be asserted from a pure
-- test, because both are about the argument vector that reaches @gh@ and the
-- environment it resolves in. The fake stands in for the real thing's
-- repository resolution exactly where it matters: given @--repo@ it answers
-- about that repository, and given none it falls back to the invoking
-- directory's @origin@ remote and fails outright when there is not one — which
-- is what a repository-unbound read is at the mercy of.
--
-- So every example below distinguishes a bound read from an unbound one by its
-- result rather than only by its argv: outside a checkout an unbound read
-- fails, and inside a checkout naming a different repository it succeeds with
-- the wrong item's answer.
--
-- The deadline examples need a live @gh@ for the same kind of reason. What
-- @timeouts.github_seconds@ has to bound is a process that has stopped
-- answering, and no pure test has one. The two overrun examples run a fake
-- that ignores TERM and never replies, and assert the three facts a bound read
-- owes -- it ended, it said it timed out, and the process group it walked away
-- from is gone from the machine and from the durable record; the example
-- beside them runs one that replies late but inside the budget, which is the
-- half a bound must leave alone. A regression in the first two does not
-- return a wrong answer, it returns none at all, so each carries an outer
-- deadline of its own: on a reader without the bound it must fail rather than
-- hang the suite.
module Spec.GitHub.Precondition (spec) where

import qualified Data.ByteString.Char8 as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime (..), diffUTCTime, fromGregorian, getCurrentTime, secondsToDiffTime)
import Kanban.Domain (ItemId (..), Repository (..), TargetPrecondition (..))
import Kanban.GitHub (GhFetchGuard, ghGroupIsRecorded, newGhFetchGuard, newGhRecordLock, observeTargetPrecondition)
import Kanban.Process (defaultProcessSnapshot, identityForPid)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Spec.Support.Board (readMarkerPid)
import Spec.Support.Env
  ( withEnvironmentValue,
    withFakeOnPath,
    withTemporaryCacheRoot
  )
import System.Directory (createDirectoryIfMissing, withCurrentDirectory)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (callProcess, readProcessWithExitCode)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "the one-item precondition read" $ do
  -- Requirement 1, the non-checkout half. The fake gh has no remote to fall
  -- back on here, so an unbound read cannot answer at all: this example fails
  -- on a reader that does not name the repository itself.
  it "names the resolved repository when reading an issue from outside any checkout" $
    withFixture $ \fixture -> do
      writeResponse fixture "coghex/kanban" liveIssueBody
      outsideAnyCheckout $ do
        observed <- observe fixture (IssueId 844)
        observed `shouldBe` Right liveIssuePrecondition
      argv <- capturedArguments fixture
      argv `shouldBe` ["issue", "view", "844", "--repo", "coghex/kanban", "--json", "number,updatedAt,labels,state"]

  it "names the resolved repository when reading a pull request from outside any checkout" $
    withFixture $ \fixture -> do
      writeResponse fixture "coghex/kanban" livePullRequestBody
      outsideAnyCheckout $ do
        observed <- observe fixture (PullRequestId 655)
        observed `shouldBe` Right livePullRequestPrecondition
      argv <- capturedArguments fixture
      argv
        `shouldBe` ["pr", "view", "655", "--repo", "coghex/kanban", "--json", "number,updatedAt,labels,state,headRefOid"]

  -- Requirement 1, the conflicting-checkout half. Here an unbound read does
  -- answer -- with the other repository's item -- so only the returned
  -- precondition separates the two readings, which is exactly the confusion
  -- the audit reproduced.
  it "reads the resolved repository's issue from a checkout whose remote names another" $
    withFixture $ \fixture -> do
      writeResponse fixture "coghex/kanban" liveIssueBody
      writeResponse fixture "audit-owner/audit-target" otherRepositoryIssueBody
      checkout <- checkoutOf fixture "https://github.com/audit-owner/audit-target.git"
      withCurrentDirectory checkout $ do
        observed <- observe fixture (IssueId 844)
        observed `shouldBe` Right liveIssuePrecondition
      argv <- capturedArguments fixture
      argv `shouldContain` ["--repo", "coghex/kanban"]

  it "reads the resolved repository's pull request from a checkout whose remote names another" $
    withFixture $ \fixture -> do
      writeResponse fixture "coghex/kanban" livePullRequestBody
      writeResponse fixture "audit-owner/audit-target" otherRepositoryPullRequestBody
      checkout <- checkoutOf fixture "https://github.com/audit-owner/audit-target.git"
      withCurrentDirectory checkout $ do
        observed <- observe fixture (PullRequestId 655)
        observed `shouldBe` Right livePullRequestPrecondition
      argv <- capturedArguments fixture
      argv `shouldContain` ["--repo", "coghex/kanban"]

  -- Requirement 2. Both numbers are named because both are needed to act on
  -- it, and the kind is InvalidResponse rather than anything a caller could
  -- read as the target having gone.
  it "refuses an issue response naming another number, naming both" $
    withFixture $ \fixture -> do
      writeResponse fixture "coghex/kanban" (issueBodyNumbered "999")
      insideMatchingCheckout fixture $ do
        observed <- observe fixture (IssueId 844)
        refusal <- invalidResponse observed
        refusal `shouldSatisfy` Text.isInfixOf "999"
        refusal `shouldSatisfy` Text.isInfixOf "issue #844"

  it "refuses a pull-request response naming another number, naming both" $
    withFixture $ \fixture -> do
      writeResponse fixture "coghex/kanban" (pullRequestBodyNumbered "999")
      insideMatchingCheckout fixture $ do
        observed <- observe fixture (PullRequestId 655)
        refusal <- invalidResponse observed
        refusal `shouldSatisfy` Text.isInfixOf "999"
        refusal `shouldSatisfy` Text.isInfixOf "pull request #655"

  -- Requirement 2 again, for the responses that identify the item as nothing
  -- at all. An unverified identity is the same failure as a verified wrong
  -- one; only the message differs.
  it "refuses an issue response whose number is missing, null, or not a number" $
    mapM_ refusesUnidentifiedIssue ["", "\"number\": null,", "\"number\": \"844\","]

  -- Issue #645, requirements 1, 2 and 5. Both item forms, because they are two
  -- argument vectors and a bound applied to only one of them is a bound on
  -- neither in practice.
  it "ends a non-answering issue read within the configured timeout, cleaned up" $
    boundsANonAnsweringRead (IssueId 844) "issue #844"

  it "ends a non-answering pull-request read within the configured timeout, cleaned up" $
    boundsANonAnsweringRead (PullRequestId 655) "pull request #655"

  -- Requirement 4, with teeth. This gh answers a whole second after it is
  -- asked -- comfortably inside a ten-second budget and comfortably outside a
  -- budget computed in milliseconds -- so a bound applied at the wrong scale
  -- fails here rather than passing on an instant fixture.
  it "leaves a read that answers inside the budget untouched" $
    withFixtureRunning slowResolvingGh $ \fixture -> do
      writeResponse fixture "coghex/kanban" liveIssueBody
      outsideAnyCheckout $ do
        observed <- observeWithin 10 fixture (IssueId 844)
        observed `shouldBe` Right liveIssuePrecondition
  where
    -- One non-answering read, and everything it owes afterwards.
    --
    -- The outer deadline is this example's own, not the reader's: on a reader
    -- that never gives up, the read below returns nothing at all, and without
    -- this the suite would stop here rather than report it. It is set far
    -- above the bound being asserted so that only an unbounded read can reach
    -- it.
    boundsANonAnsweringRead item subject =
      withFixtureRunning hangingGh $ \fixture -> do
        bounded <- timeout outerDeadlineMicros $ do
          startedAt <- getCurrentTime
          (guard, observed) <- observingWithin 1 fixture item
          finishedAt <- getCurrentTime
          pure (realToFrac (diffUTCTime finishedAt startedAt) :: Double, guard, observed)
        case bounded of
          Nothing -> expectationFailure "the read never ended; it is not bounded by the configured timeout"
          Just (elapsed, guard, observed) -> do
            -- The budget plus the cleanup that follows it, which section 13
            -- allows to finish afterwards. Well under it rather than at it,
            -- because a cleanup that has to escalate is still nothing like an
            -- unbounded wait.
            elapsed `shouldSatisfy` (< 15)
            case observed of
              Right precondition ->
                expectationFailure ("a gh that never answered produced " <> show precondition)
              Left failure -> do
                -- RequestTimedOut and not RequestFailed: requirement 2 keeps
                -- this apart from the target having moved or gone, and the
                -- kind is what a caller reads.
                failure.providerErrorKind `shouldBe` RequestTimedOut
                failure.providerErrorMessage `shouldSatisfy` Text.isInfixOf subject
                failure.providerErrorMessage `shouldSatisfy` Text.isInfixOf "1 seconds"
            -- Cleaned up the way an interrupted page's group is: gone from the
            -- machine, leader and the descendant that inherited its group
            -- alike, and gone from the durable record with it.
            leaderPid <- readMarkerPid (fixtureRoot fixture </> "gh.pid")
            descendantPid <- readMarkerPid (fixtureRoot fixture </> "helper.pid")
            snapshot <- defaultProcessSnapshot
            case snapshot of
              Left message -> expectationFailure ("could not snapshot processes: " <> Text.unpack message)
              Right identities -> do
                identityForPid leaderPid identities `shouldBe` Nothing
                identityForPid descendantPid identities `shouldBe` Nothing
            ghGroupIsRecorded guard (readRepository fixture) leaderPid `shouldReturn` False

    refusesUnidentifiedIssue numberField =
      withFixture $ \fixture -> do
        writeResponse fixture "coghex/kanban" (issueBodyWithNumberField numberField)
        insideMatchingCheckout fixture $ do
          observed <- observe fixture (IssueId 844)
          _ <- invalidResponse observed
          pure ()

-- The fixture

-- | Everything one example's read happens inside: a scratch root, a cache root
-- of its own so the durable @gh@ record lands there, the fake @gh@ first on
-- PATH, and the two files that fake reads and writes.
data Fixture = Fixture
  { fixtureRoot :: FilePath,
    fixtureResponses :: FilePath,
    fixtureArgv :: FilePath
  }

withFixture :: (Fixture -> IO ()) -> IO ()
withFixture = withFixtureRunning resolvingGh

-- | The same fixture with the fake @gh@ chosen by the example.
--
-- The scratch root is bracketed by 'withTemporaryCacheRoot' and the @PATH@
-- entry by 'withFakeOnPath', so a deadline example that fails -- or whose own
-- outer deadline fires -- still tears both down rather than leaving a fake
-- @gh@ ahead of the real one for whatever runs next.
withFixtureRunning :: [ByteString.ByteString] -> (Fixture -> IO ()) -> IO ()
withFixtureRunning ghBody action =
  withTemporaryCacheRoot $ \root -> do
    let responses = root </> "responses"
        argv = root </> "argv"
        cache = root </> "cache"
    createDirectoryIfMissing True responses
    createDirectoryIfMissing True cache
    writeFile argv ""
    withEnvironmentValue "XDG_CACHE_HOME" cache
      . withEnvironmentValue "KANBAN_TEST_GH_RESPONSES" responses
      . withEnvironmentValue "KANBAN_TEST_GH_ARGV" argv
      . withEnvironmentValue "KANBAN_TEST_GH_ROOT" root
      . withFakeOnPath root ("gh", ghBody)
      $ action Fixture {fixtureRoot = root, fixtureResponses = responses, fixtureArgv = argv}

-- | 'resolvingGh', a whole second late.
slowResolvingGh :: [ByteString.ByteString]
slowResolvingGh = "sleep 1" : resolvingGh

-- | How long an example waits before declaring the reader unbounded. Three
-- times the elapsed bound it asserts, so a read that merely took its cleanup's
-- full allowance still reports the assertion rather than this.
outerDeadlineMicros :: Int
outerDeadlineMicros = 45 * 1000 * 1000

-- | A @gh@ that answers nothing, ignores TERM, and leaves a descendant in its
-- own process group doing the same -- the wedged request the deadline exists
-- to catch, and the group cleanup has to account for both members.
--
-- 'Spec.Support.Board.termIgnoringGh' with the two pids written down, which is
-- the only thing added: both are recorded before it settles in to wait, so an
-- example can ask the process table about them after the read has reported.
hangingGh :: [ByteString.ByteString]
hangingGh =
  [ "trap '' TERM",
    "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &",
    "printf '%s\\n' \"$!\" > \"$KANBAN_TEST_GH_ROOT/helper.pid\"",
    "printf '%s\\n' \"$$\" > \"$KANBAN_TEST_GH_ROOT/gh.pid\"",
    "while :; do sleep 1; done"
  ]

-- | A @gh@ that resolves its repository the way the real one does: from
-- @--repo@ when it is given one, and otherwise from the invoking directory's
-- @origin@ remote, with nothing to answer from when there is neither.
--
-- It records its whole argument vector one argument per line before doing any
-- of that, so an example can assert what was asked as well as what came back.
resolvingGh :: [ByteString.ByteString]
resolvingGh =
  [ "printf '%s\\n' \"$@\" >> \"$KANBAN_TEST_GH_ARGV\"",
    "repository=''",
    "previous=''",
    "for argument in \"$@\"; do",
    "  if [ \"$previous\" = '--repo' ]; then repository=\"$argument\"; fi",
    "  previous=\"$argument\"",
    "done",
    "if [ -z \"$repository\" ]; then",
    "  url=$(git remote get-url origin 2>/dev/null)",
    "  if [ -z \"$url\" ]; then",
    "    echo 'failed to run git: fatal: not a git repository' >&2",
    "    exit 1",
    "  fi",
    "  repository=\"$(basename \"$(dirname \"$url\")\")/$(basename \"$url\" .git)\"",
    "fi",
    "body=\"$KANBAN_TEST_GH_RESPONSES/$(printf '%s' \"$repository\" | tr '/' '~').json\"",
    "if [ ! -f \"$body\" ]; then",
    "  echo \"could not resolve to a Repository: $repository\" >&2",
    "  exit 1",
    "fi",
    "cat \"$body\""
  ]

-- | The read itself, against the identity the dashboard resolved -- which is
-- deliberately not the identity of any directory the example runs in.
--
-- Thirty seconds is the shipped default, so the examples that are not about
-- the deadline read under exactly the budget a stock installation gives them.
observe :: Fixture -> ItemId -> IO (Either ProviderError TargetPrecondition)
observe = observeWithin 30

observeWithin :: Int -> Fixture -> ItemId -> IO (Either ProviderError TargetPrecondition)
observeWithin readSeconds fixture item = snd <$> observingWithin readSeconds fixture item

-- | The same, handing back the guard the read ran under, because what its
-- cleanup did to the durable record is half of what an interrupted read owes.
observingWithin :: Int -> Fixture -> ItemId -> IO (GhFetchGuard, Either ProviderError TargetPrecondition)
observingWithin readSeconds fixture item = do
  recordLock <- newGhRecordLock
  guard <- newGhFetchGuard recordLock
  observed <- observeTargetPrecondition guard readSeconds (readRepository fixture) item
  pure (guard, observed)

-- | The identity every read in this module is asked about.
readRepository :: Fixture -> Repository
readRepository fixture = Repository (fixtureRoot fixture) "coghex" "kanban"

writeResponse :: Fixture -> String -> String -> IO ()
writeResponse fixture repository body =
  writeFile (fixtureResponses fixture </> map slashToTilde repository <> ".json") body
  where
    slashToTilde character = if character == '/' then '~' else character

capturedArguments :: Fixture -> IO [String]
capturedArguments fixture = lines <$> readFile (fixtureArgv fixture)

-- | A directory that is no checkout, entered for the duration of the read.
--
-- The premise is checked rather than assumed. @gh@'s fallback walks upwards,
-- so a scratch directory that happened to sit under a checkout would resolve
-- that checkout's remote instead -- and if that remote were this repository's
-- own, an unbound read would answer correctly and the example would pass on
-- the very reader it exists to fail.
outsideAnyCheckout :: IO result -> IO result
outsideAnyCheckout action =
  withTemporaryCacheRoot $ \directory ->
    withCurrentDirectory directory $ do
      (code, _, _) <- readProcessWithExitCode "git" ["rev-parse", "--show-toplevel"] ""
      code `shouldNotBe` ExitSuccess
      action

-- | A checkout whose own @origin@ names the repository being read, so a read
-- that ignored @--repo@ would resolve the same repository a bound one does.
--
-- The identity refusals below run here deliberately. Run from outside a
-- checkout they would fail on a repository-unbound reader too, but on the
-- binding rather than on the identity check they exist to hold -- and a test
-- that cannot fail for its own reason is not holding anything.
insideMatchingCheckout :: Fixture -> IO result -> IO result
insideMatchingCheckout fixture action = do
  checkout <- checkoutOf fixture "https://github.com/coghex/kanban.git"
  withCurrentDirectory checkout action

-- | A real checkout whose @origin@ names @url@, for the conflicting-checkout
-- half of requirement 1.
checkoutOf :: Fixture -> String -> IO FilePath
checkoutOf fixture url = do
  let checkout = fixtureRoot fixture </> "conflicting-checkout"
  createDirectoryIfMissing True checkout
  callProcess "git" ["-C", checkout, "init", "--quiet"]
  callProcess "git" ["-C", checkout, "remote", "add", "origin", url]
  pure checkout

-- | The message of a refusal that is an invalid response, insisting on that
-- kind: a caller reads any other kind as the target itself being unreachable
-- or gone, and an answer about the wrong item says nothing either way.
invalidResponse :: Either ProviderError TargetPrecondition -> IO Text
invalidResponse (Left failure) = do
  providerErrorKind failure `shouldBe` InvalidResponse
  pure (providerErrorMessage failure)
invalidResponse (Right precondition) = do
  expectationFailure ("expected the response to be refused, got " <> show precondition)
  pure ""

-- The responses

liveIssueBody :: String
liveIssueBody = issueBodyNumbered "844"

issueBodyNumbered :: String -> String
issueBodyNumbered number = issueBodyWithNumberField ("\"number\": " <> number <> ",")

issueBodyWithNumberField :: String -> String
issueBodyWithNumberField numberField =
  "{"
    <> numberField
    <> "\"updatedAt\": \"2026-09-07T12:00:00Z\","
    <> "\"state\": \"OPEN\","
    <> "\"labels\": [{\"name\": \"bug\"}, {\"name\": \"agent-workflows\"}]"
    <> "}"

livePullRequestBody :: String
livePullRequestBody = pullRequestBodyNumbered "655"

pullRequestBodyNumbered :: String -> String
pullRequestBodyNumbered number =
  "{\"number\": "
    <> number
    <> ",\"updatedAt\": \"2026-09-07T13:30:00Z\","
    <> "\"state\": \"MERGED\","
    <> "\"labels\": [{\"name\": \"reviewed:approve\"}],"
    <> "\"headRefOid\": \"0f1e2d3c4b5a\""
    <> "}"

otherRepositoryIssueBody :: String
otherRepositoryIssueBody =
  "{\"number\": 844,\"updatedAt\": \"2019-01-01T00:00:00Z\","
    <> "\"state\": \"CLOSED\",\"labels\": [{\"name\": \"answered-by-the-wrong-repository\"}]}"

otherRepositoryPullRequestBody :: String
otherRepositoryPullRequestBody =
  "{\"number\": 655,\"updatedAt\": \"2019-01-01T00:00:00Z\","
    <> "\"state\": \"CLOSED\",\"labels\": [{\"name\": \"answered-by-the-wrong-repository\"}],"
    <> "\"headRefOid\": \"ffffffffffff\"}"

-- | What the reader must make of 'liveIssueBody': the requested identity, the
-- response's timestamp, its labels sorted, and its state folded to the
-- spelling a board item is compared in.
liveIssuePrecondition :: TargetPrecondition
liveIssuePrecondition =
  TargetPrecondition
    { preconditionItem = IssueId 844,
      preconditionUpdatedAt = UTCTime (fromGregorian 2026 9 7) (secondsToDiffTime (12 * 3600)),
      preconditionHead = Nothing,
      preconditionLabels = ["agent-workflows", "bug"],
      preconditionState = "open"
    }

-- | The same for 'livePullRequestBody', which also carries a head commit.
livePullRequestPrecondition :: TargetPrecondition
livePullRequestPrecondition =
  TargetPrecondition
    { preconditionItem = PullRequestId 655,
      preconditionUpdatedAt = UTCTime (fromGregorian 2026 9 7) (secondsToDiffTime (13 * 3600 + 30 * 60)),
      preconditionHead = Just "0f1e2d3c4b5a",
      preconditionLabels = ["reviewed:approve"],
      preconditionState = "merged"
    }
