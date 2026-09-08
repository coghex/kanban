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
module Spec.GitHub.Precondition (spec) where

import qualified Data.ByteString.Char8 as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Kanban.Domain (ItemId (..), Repository (..), TargetPrecondition (..))
import Kanban.GitHub (newGhFetchGuard, newGhRecordLock, observeTargetPrecondition)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Spec.Support.Env
  ( withEnvironmentValue,
    withFakeOnPath,
    withTemporaryCacheRoot
  )
import System.Directory (createDirectoryIfMissing, withCurrentDirectory)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Process (callProcess, readProcessWithExitCode)
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
  where
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
withFixture action =
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
      . withFakeOnPath root ("gh", resolvingGh)
      $ action Fixture {fixtureRoot = root, fixtureResponses = responses, fixtureArgv = argv}

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
observe :: Fixture -> ItemId -> IO (Either ProviderError TargetPrecondition)
observe fixture item = do
  recordLock <- newGhRecordLock
  guard <- newGhFetchGuard recordLock
  observeTargetPrecondition guard (Repository (fixtureRoot fixture) "coghex" "kanban") item

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
