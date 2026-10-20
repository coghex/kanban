-- | The precondition a worker carries, and the bounds it and its reread run
-- under.
--
-- These examples were first written beside the mission runner that launched
-- workers and are the part of that coverage that outlived it: what a worker
-- and an issue-review host still do is take one last live reading of the
-- target before an agent turn starts, refuse the turn when it moved or could
-- not be read, and bound that reading by the configured GitHub timeout and the
-- worker itself by the deadline its specification recorded.
module Spec.Agent.WorkerPrecondition (spec) where

import Data.Aeson (eitherDecode, encode)
import qualified Data.ByteString.Char8 as ByteString
import Data.List (intercalate, isInfixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime (..), defaultTimeLocale, diffUTCTime, formatTime, fromGregorian, getCurrentTime, secondsToDiffTime)
import Kanban.Config (ResolvedConfig (..), TimeoutsConfig (..), decodeConfigText, defaultRawConfig, defaultTimeoutsConfig, resolveGlobalConfig)
import Kanban.Domain (ItemId (..), Repository (..), TargetPrecondition (..))
import Kanban.GitHub (newGhRecordLock)
import Kanban.Worker
  ( WorkerDeadline (..),
    WorkerId (..),
    WorkerSpec (..),
    preconditionReadSeconds,
    preconditionStillHolds,
    workerPreconditionRefusal,
    workerStaleTargetReason,
    workerUnverifiedTargetReason,
  )
import Spec.Support.Board (termIgnoringGh, withFakeGh)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Process (deadlineFixtureSpec, workerFixtureSpec)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "the precondition a worker carries" $ do
  deadlineSpec
  workerPreconditionSpec
  preconditionDeadlineSpec

-- ---------------------------------------------------------------------------
-- The configured deadline
-- ---------------------------------------------------------------------------

deadlineSpec :: Spec
deadlineSpec = describe "the configured action-worker deadline" $ do
  -- The bound a worker runs under is the one its own specification recorded,
  -- and a configuration edited since then cannot reach back into it: recovery
  -- decodes the specification, and the configuration is nowhere in that path.
  it "keeps the bound a running worker's specification already recorded" $ do
    let recorded = 999 :: Int
        recordedSpec = deadlineFixtureSpec boardRepository (WorkerId "solve-844-0001") 844 fixedTime recorded
        edited = (resolveGlobalConfig defaultRawConfig) {resolvedTimeouts = defaultTimeoutsConfig {timeoutsWorkerDeadlineSeconds = 60}}
    edited.resolvedTimeouts.timeoutsWorkerDeadlineSeconds `shouldBe` 60
    case eitherDecode (encode recordedSpec) of
      Left message -> expectationFailure message
      Right decoded -> (decoded :: WorkerSpec).workerMaxRuntimeSeconds `shouldBe` recorded

  it "carries the resolved value into the environment every launch runs through" $
    case decodeConfigText "[timeouts]\nworker_deadline_seconds = 3600\n" of
      Left message -> expectationFailure (Text.unpack message)
      Right (config, _) ->
        WorkerDeadline (resolveGlobalConfig config).resolvedTimeouts.timeoutsWorkerDeadlineSeconds
          `shouldBe` WorkerDeadline 3600

-- ---------------------------------------------------------------------------
-- The worker's own precondition
-- ---------------------------------------------------------------------------

workerPreconditionSpec :: Spec
workerPreconditionSpec = describe "the last reading before a turn" $ do
  it "records nothing when the launch recorded nothing" $ do
    let launched = deadlineFixtureSpec boardRepository (WorkerId "solve-844-0001") 844 fixedTime 60
    launched.workerExpectedTarget `shouldBe` Nothing
    freshLockPrecondition launched `shouldReturn` Nothing

  it "round-trips the recorded expectation through the durable specification" $ do
    let expected = issuePrecondition ["reviewed:approve"]
        launched =
          (deadlineFixtureSpec boardRepository (WorkerId "solve-844-0001") 844 fixedTime 60)
            {workerExpectedTarget = Just expected}
    case eitherDecode (encode launched) of
      Left message -> expectationFailure message
      Right decoded -> (decoded :: WorkerSpec).workerExpectedTarget `shouldBe` Just expected

  -- The last instant Kanban controls. The launch checked this in another
  -- process, possibly long ago; everything after this call is an agent session
  -- whose GitHub writes are its own.
  it "refuses the turn when the live target has moved since the launch" $
    withIsolatedGh $ \root -> do
      let expected = issuePrecondition ["reviewed:approve"]
          launched =
            (deadlineFixtureSpec boardRepository (WorkerId "solve-844-0001") 844 fixedTime 60)
              {workerExpectedTarget = Just expected}
      withFakeGh root (ghItem ["reviewed:approve", "blocked"]) $ do
        moved <- freshLockPrecondition launched
        case moved of
          Nothing -> expectationFailure "a moved target was allowed to start its turn"
          Just detail -> do
            workerPreconditionRefusal detail `shouldBe` Just workerStaleTargetReason
            Text.unpack detail `shouldSatisfy` isInfixOf "its labels changed"
      withFakeGh root (ghItem ["reviewed:approve"]) $
        freshLockPrecondition launched `shouldReturn` Nothing

  -- Fail-closed, and this is the half that matters. The mutation is permitted
  -- only if the exact recorded precondition still holds, and a target that
  -- cannot be read has not been shown to hold anything; nothing downstream
  -- carries the expectation to a later check, so starting the session anyway
  -- would act on a plan nobody has verified since the launch.
  it "refuses the turn when the reading could not be taken at all" $
    withIsolatedGh $ \root -> do
      let launched =
            (deadlineFixtureSpec boardRepository (WorkerId "solve-844-0001") 844 fixedTime 60)
              {workerExpectedTarget = Just (issuePrecondition ["reviewed:approve"])}
      withFakeGh root ["#!/bin/sh", "echo 'gh: could not connect' >&2", "exit 1"] $ do
        unverified <- freshLockPrecondition launched
        case unverified of
          Nothing -> expectationFailure "an unreadable target was allowed to start its turn"
          Just detail -> do
            workerPreconditionRefusal detail `shouldBe` Just workerUnverifiedTargetReason
            Text.unpack detail `shouldSatisfy` isInfixOf "could not connect"

  -- The two refusals stay apart because they call for different repairs: a
  -- moved target is replanned against a new reading, an unreadable one is
  -- waited on.
  it "tells the two refusals apart, and both from an ordinary failure" $ do
    workerPreconditionRefusal (workerStaleTargetReason <> ": #844 changed")
      `shouldBe` Just workerStaleTargetReason
    workerPreconditionRefusal (workerUnverifiedTargetReason <> ": gh failed")
      `shouldBe` Just workerUnverifiedTargetReason
    workerPreconditionRefusal "the provider exited 1" `shouldBe` Nothing

-- ---------------------------------------------------------------------------
-- The deadline the precondition read runs under
-- ---------------------------------------------------------------------------

-- | Issue #645. The reader's own bound is asserted in "Spec.GitHub.Precondition";
-- what is asserted here is that its caller applies one, applies the configured
-- one, and reports the overrun through the path it already has for a
-- precondition it could not verify.
--
-- The first example runs a real @gh@ that never answers, because a bound on a
-- process that always replies is not a bound. It therefore carries an outer
-- deadline: unbounded, it does not fail, it hangs, and a regression the suite
-- cannot report is not a regression the suite catches.
preconditionDeadlineSpec :: Spec
preconditionDeadlineSpec = describe "the deadline a precondition read runs under" $ do
  -- The file this launch selected sets a five-minute global budget and a
  -- one-second override for the repository being read: a reread that took the
  -- global one would outlast this example's own deadline, so only the resolved
  -- value passes.
  it "bounds the worker's reread by the repository's own configured value" $
    withIsolatedGh $ \root -> do
      configPath <- writeSplitTimeoutConfig root
      let launched =
            (deadlineFixtureSpec boardRepository (WorkerId "solve-844-0001") 844 fixedTime 60)
              { workerExpectedTarget = Just (issuePrecondition ["reviewed:approve"]),
                workerConfigPath = Just configPath
              }
      withFakeGh root termIgnoringGh $ do
        bounded <- timeout preconditionOuterDeadlineMicros $ do
          startedAt <- getCurrentTime
          refusal <- freshLockPrecondition launched
          finishedAt <- getCurrentTime
          pure (elapsedSeconds startedAt finishedAt, refusal)
        case bounded of
          Nothing ->
            expectationFailure
              "the worker's reread never ended; it is not bounded by the configured timeout"
          Just (elapsed, refusal) -> do
            elapsed `shouldSatisfy` (< 15)
            case refusal of
              Nothing -> expectationFailure "an unreadable target was allowed to start its turn"
              -- Unverified and not stale: a read that never answered has shown
              -- nothing about the target, and the two refusals call for
              -- different repairs.
              Just detail -> do
                workerPreconditionRefusal detail `shouldBe` Just workerUnverifiedTargetReason
                Text.unpack detail `shouldSatisfy` isInfixOf "1 seconds"

  -- And the resolution itself, without a process in it: the repository's
  -- override, the global it overrides, and the shipped default a launch that
  -- selected no file falls back to. One setting, resolved the way the board
  -- fetch resolves it, rather than a second one for precondition reads.
  it "resolves that budget for the repository being read, and defaults with no file" $
    withIsolatedGh $ \root -> do
      configPath <- writeSplitTimeoutConfig root
      let selecting repository = (workerFixtureSpec repository (WorkerId "solve-844-0001") 844) {workerConfigPath = Just configPath}
      preconditionReadSeconds (selecting boardRepository) `shouldReturn` 1
      preconditionReadSeconds (selecting otherRepository) `shouldReturn` 300
      preconditionReadSeconds (workerFixtureSpec boardRepository (WorkerId "solve-844-0001") 844)
        `shouldReturn` defaultTimeoutsConfig.timeoutsGithubSeconds

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

boardRepository :: Repository
boardRepository = Repository {repositoryRoot = "/tmp/board", repositoryOwner = "coghex", repositoryName = "kanban"}

-- | A repository no table in 'writeSplitTimeoutConfig' names, so it resolves
-- the global value the override exists to differ from.
otherRepository :: Repository
otherRepository = Repository {repositoryRoot = "/tmp/other", repositoryOwner = "audit-owner", repositoryName = "audit-target"}

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 9 4) (secondsToDiffTime 120)

-- | What the live item has to match: issue 844, open, with these labels.
issuePrecondition :: [Text] -> TargetPrecondition
issuePrecondition labels =
  TargetPrecondition
    { preconditionItem = IssueId 844,
      preconditionUpdatedAt = fixedTime,
      preconditionHead = Nothing,
      preconditionLabels = labels,
      preconditionState = "open"
    }

-- | One precondition reread under a record lock minted for it alone, as the
-- one reread a persistent worker process takes.
freshLockPrecondition :: WorkerSpec -> IO (Maybe Text)
freshLockPrecondition launched = do
  recordLock <- newGhRecordLock
  preconditionStillHolds recordLock launched

-- | A temporary root with @$XDG_CACHE_HOME@ and @$XDG_CONFIG_HOME@ redirected
-- into it.
--
-- Running @gh@ at all writes this repository's durable process-group record
-- under the cache root, and a record left in the real one is read by every
-- later board refresh as a previous board's leftover — which is a failure in
-- another group entirely, arriving long after the example that caused it.
--
-- The configuration root is redirected for the same kind of reason. A
-- precondition read resolves @timeouts.github_seconds@ for the repository it
-- is reading, and a launch that selected no file resolves the default path —
-- so without this an example would read whatever @config.toml@ the developer
-- running it happens to keep, and be bounded by a budget the suite never
-- chose.
withIsolatedGh :: (FilePath -> IO result) -> IO result
withIsolatedGh action = withTemporaryCacheRoot $ \root ->
  withEnvironmentValue "XDG_CACHE_HOME" (root </> "cache") $
    withEnvironmentValue "XDG_CONFIG_HOME" (root </> "config") (action root)

-- | A fake @gh issue view --json@ answering with these labels.
--
-- The state and instant match 'issuePrecondition', so the only fact that can
-- differ is the one an example varies.
ghItem :: [Text] -> [ByteString.ByteString]
ghItem labels =
  [ "#!/bin/sh",
    ByteString.pack
      ( "printf '%s' '"
          <> "{\"number\":844,\"updatedAt\":\""
          <> iso8601
          <> "\",\"state\":\"OPEN\",\"labels\":["
          <> intercalate "," ["{\"name\":\"" <> Text.unpack name <> "\"}" | name <- labels]
          <> "]}'"
      )
  ]
  where
    iso8601 = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" fixedTime

-- | A selected @config.toml@ whose repository override differs from its own
-- global timeout, which is the only shape that can tell the two apart.
writeSplitTimeoutConfig :: FilePath -> IO FilePath
writeSplitTimeoutConfig root = do
  let configPath = root </> "selected-config.toml"
  writeFile
    configPath
    ( unlines
        [ "[timeouts]",
          "github_seconds = 300",
          "",
          "[repositories.\"coghex/kanban\".timeouts]",
          "github_seconds = 1"
        ]
    )
  pure configPath

-- | How long an example waits before declaring a caller unbounded. Far above
-- the one-second budget it asserts and far below the five-minute global one
-- that budget overrides, so it is reached by an unbounded read and by one
-- bounded by the wrong value alike.
preconditionOuterDeadlineMicros :: Int
preconditionOuterDeadlineMicros = 60 * 1000 * 1000

elapsedSeconds :: UTCTime -> UTCTime -> Double
elapsedSeconds startedAt finishedAt = realToFrac (diffUTCTime finishedAt startedAt)
