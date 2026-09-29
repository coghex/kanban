{-# LANGUAGE OverloadedStrings #-}

-- | Whether a failed agent session hit a provider limit (issue #752, design
-- D-18).
--
-- Two halves. The rule itself is exercised over schema-shaped provider events
-- written out here, one example per clause of D-18 and one per value that
-- must /not/ count. The mechanism is exercised the way a mission meets it: a
-- fake @claude@ or @codex@ on a temporary @PATH@ runs through the real
-- 'runSolve', which records its stream in the real session log, and the
-- settled worker that log belongs to is typed through
-- 'settledProviderFailure' — with a fake Codex app server answering the
-- account read through the real 'fetchCodexAccountLimit' exchange. No network
-- and no real account is involved.
module Spec.ProviderLimit (spec) where

import Data.Aeson (Value, eitherDecodeStrict)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyChar8
import Data.IORef (modifyIORef, newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Kanban.Action (ActionOutcome (..), settledWorkerFailure)
import Kanban.Codex (CodexAccountLimit (..), decodeCodexAccountLimit)
import Kanban.Domain (Repository (..), defaultWorkflowConfig)
import Kanban.Models (defaultRoster, recordedAssignmentCell)
import Kanban.Provider (ProviderError (..))
import Kanban.ProviderLimit
import Kanban.Solve (ResumeProvenance (..), SolveEvent (..), SolveOutcome (..), SolveWorkflow (..), SolverBrand (..), newUnknownAggregator, runSolve, solveAssignment)
import Kanban.Worker
  ( SolveWorkerTask (..),
    WorkerDescriptor,
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
    descriptorForSpec,
    workerDeadlineReason,
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Process (runningWorkerState, workerFixtureSpec)
import Spec.Support.Roster (cellOf)
import System.Directory (createDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import Test.Hspec

spec :: Spec
spec = describe "provider-limit evidence (issue #752)" $ do
  claudeSpec
  codexSpec
  snapshotSpec
  mechanismSpec

-- ---------------------------------------------------------------------------
-- Claude
-- ---------------------------------------------------------------------------

events :: [String] -> [Value]
events = map (either error id . eitherDecodeStrict . ByteString.pack)

resetEpoch :: Integer
resetEpoch = 1790000000

resetTime :: UTCTime
resetTime = posixSecondsToUTCTime (fromInteger resetEpoch)

rateLimitEvent :: String -> String -> String
rateLimitEvent status extra =
  "{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\""
    <> status
    <> "\",\"resetsAt\":"
    <> show resetEpoch
    <> ",\"rateLimitType\":\"five_hour\""
    <> extra
    <> "},\"session_id\":\"s\"}"

errorResult :: String -> String
errorResult status = "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":true,\"api_error_status\":" <> status <> ",\"result\":\"anything at all\",\"session_id\":\"s\"}"

successResult :: String
successResult = "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"done\",\"session_id\":\"s\"}"

isReached :: Maybe UTCTime -> ProviderLimit -> Bool
isReached expected (ProviderLimitReached resetsAt _) = resetsAt == expected
isReached _ _ = False

isDepleted :: ProviderLimit -> Bool
isDepleted (ProviderCreditsDepleted _) = True
isDepleted _ = False

claudeSpec :: Spec
claudeSpec = describe "a Claude session" $ do
  it "counts a rejected event overage does not cover, retrying at its resetsAt" $ do
    claudeSessionLimit (events [rateLimitEvent "rejected" ",\"overageStatus\":\"rejected\"", errorResult "429"])
      `shouldSatisfy` isReached (Just resetTime)
    -- No overage status at all is overage not covering it either.
    claudeSessionLimit (events [rateLimitEvent "rejected" "", errorResult "null"])
      `shouldSatisfy` isReached (Just resetTime)

  it "counts a rejected event with no reset time, which the caller backs off" $
    claudeSessionLimit
      (events ["{\"type\":\"rate_limit_event\",\"rate_limit_info\":{\"status\":\"rejected\"}}", errorResult "null"])
      `shouldSatisfy` isReached Nothing

  it "counts a bare 429 only when the session recorded no rate-limit event" $ do
    claudeSessionLimit (events [errorResult "429"]) `shouldSatisfy` isReached Nothing
    claudeSessionLimit (events [rateLimitEvent "allowed" "", errorResult "429"]) `shouldBe` ProviderLimitUnidentified

  it "never counts allowed_warning, however the turn ended" $ do
    claudeSessionLimit (events [rateLimitEvent "allowed_warning" "", errorResult "429"]) `shouldBe` ProviderLimitUnidentified
    claudeSessionLimit (events [rateLimitEvent "allowed_warning" "", successResult]) `shouldBe` ProviderLimitUnidentified

  it "reads the latest event, not the worst one" $ do
    claudeSessionLimit (events [rateLimitEvent "rejected" "", rateLimitEvent "allowed_warning" "", errorResult "429"])
      `shouldBe` ProviderLimitUnidentified
    claudeSessionLimit (events [rateLimitEvent "allowed_warning" "", rateLimitEvent "rejected" "", errorResult "null"])
      `shouldSatisfy` isReached (Just resetTime)

  it "does not count a rejection overage covers" $ do
    claudeSessionLimit (events [rateLimitEvent "rejected" ",\"overageStatus\":\"allowed\"", errorResult "429"])
      `shouldBe` ProviderLimitUnidentified
    claudeSessionLimit (events [rateLimitEvent "rejected" ",\"overageStatus\":\"allowed_warning\"", errorResult "429"])
      `shouldBe` ProviderLimitUnidentified

  it "names depleted credits rather than waiting on them" $
    claudeSessionLimit
      (events [rateLimitEvent "rejected" ",\"overageStatus\":\"rejected\",\"overageDisabledReason\":\"out_of_credits\"", errorResult "429"])
      `shouldSatisfy` isDepleted

  it "does not count a session that did not end in error, or never ended" $ do
    claudeSessionLimit (events [rateLimitEvent "rejected" "", successResult]) `shouldBe` ProviderLimitUnidentified
    claudeSessionLimit (events [rateLimitEvent "rejected" ""]) `shouldBe` ProviderLimitUnidentified

  it "does not count an authentication failure, or a status it does not recognise" $ do
    claudeSessionLimit (events [errorResult "401"]) `shouldBe` ProviderLimitUnidentified
    claudeSessionLimit (events [errorResult "null"]) `shouldBe` ProviderLimitUnidentified
    claudeSessionLimit (events [rateLimitEvent "throttled_somehow" "", errorResult "429"]) `shouldBe` ProviderLimitUnidentified

-- ---------------------------------------------------------------------------
-- Codex
-- ---------------------------------------------------------------------------

execFailure :: [Value]
execFailure =
  events
    [ "{\"type\":\"thread.started\",\"thread_id\":\"t\"}",
      "{\"type\":\"turn.started\"}",
      "{\"type\":\"turn.failed\",\"error\":{\"message\":\"You've hit your usage limit.\"}}"
    ]

appServerFailure :: String -> [Value]
appServerFailure info =
  events
    [ "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"t\",\"turn\":{\"id\":\"u\",\"items\":[],\"status\":\"failed\",\"error\":{\"message\":\"m\",\"codexErrorInfo\":\""
        <> info
        <> "\"}}}}"
    ]

reached :: Text -> Maybe UTCTime -> Either Text CodexAccountLimit
reached kind resetsAt = Right (CodexAccountLimit (Just kind) resetsAt)

codexSpec :: Spec
codexSpec = describe "a Codex session" $ do
  it "counts the three limit types the account snapshot names, retrying at the limiting window's reset" $
    mapM_
      (\kind -> codexSessionLimit execFailure (reached kind (Just resetTime)) `shouldSatisfy` isReached (Just resetTime))
      ["rate_limit_reached", "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached"]

  it "backs off a limit whose windows name no usable reset" $
    codexSessionLimit execFailure (reached "rate_limit_reached" Nothing) `shouldSatisfy` isReached Nothing

  it "names depleted credits, even beside direct evidence of a limit" $ do
    codexSessionLimit execFailure (reached "workspace_owner_credits_depleted" Nothing) `shouldSatisfy` isDepleted
    codexSessionLimit execFailure (reached "workspace_member_credits_depleted" Nothing) `shouldSatisfy` isDepleted
    codexSessionLimit (appServerFailure "usageLimitExceeded") (reached "workspace_owner_credits_depleted" Nothing)
      `shouldSatisfy` isDepleted

  it "does not count a snapshot that reports no limit, cannot be read, or names one it does not know" $ do
    codexSessionLimit execFailure (Right (CodexAccountLimit Nothing Nothing)) `shouldBe` ProviderLimitUnidentified
    codexSessionLimit execFailure (Left "timed out") `shouldBe` ProviderLimitUnidentified
    codexSessionLimit execFailure (reached "some_new_limit" (Just resetTime)) `shouldBe` ProviderLimitUnidentified

  it "asks the account only about a turn that failed" $ do
    codexTurnFailed execFailure `shouldBe` True
    codexTurnFailed (events ["{\"type\":\"thread.started\",\"thread_id\":\"t\"}"]) `shouldBe` False
    codexSessionLimit (events ["{\"type\":\"thread.started\",\"thread_id\":\"t\"}"]) (reached "rate_limit_reached" (Just resetTime))
      `shouldBe` ProviderLimitUnidentified

  it "takes an app-server turn's codexErrorInfo as direct evidence, with or without a readable snapshot" $ do
    codexSessionLimit (appServerFailure "usageLimitExceeded") (Left "unreadable") `shouldSatisfy` isReached Nothing
    codexSessionLimit (appServerFailure "rateLimitExceeded") (Right (CodexAccountLimit Nothing (Just resetTime)))
      `shouldSatisfy` isReached (Just resetTime)
    codexSessionLimit (appServerFailure "unauthorized") (Left "unreadable") `shouldBe` ProviderLimitUnidentified

  it "reads only the final turn, never an earlier turn's limit" $ do
    -- An earlier turn met a limit; the final one failed for another reason.
    let laterFailure = appServerFailure "rateLimitExceeded" <> appServerFailure "unauthorized"
    codexSessionLimit laterFailure (Left "unreadable") `shouldBe` ProviderLimitUnidentified
    codexSessionLimit laterFailure (Right (CodexAccountLimit Nothing (Just resetTime))) `shouldBe` ProviderLimitUnidentified
    -- And the other way round: the final turn's limit is the one that counts.
    codexSessionLimit (appServerFailure "unauthorized" <> appServerFailure "usageLimitExceeded") (Left "unreadable")
      `shouldSatisfy` isReached Nothing
    -- A failed turn followed by one that completed is not a failed session.
    let recovered = execFailure <> events ["{\"type\":\"turn.completed\",\"usage\":{}}"]
    codexTurnFailed recovered `shouldBe` False
    codexSessionLimit recovered (reached "rate_limit_reached" (Just resetTime)) `shouldBe` ProviderLimitUnidentified

-- ---------------------------------------------------------------------------
-- The account snapshot
-- ---------------------------------------------------------------------------

window :: Int -> Integer -> String
window used resets = "{\"usedPercent\":" <> show used <> ",\"windowDurationMins\":300,\"resetsAt\":" <> show resets <> "}"

snapshotResponse :: String -> String
snapshotResponse body = "{\"id\":1,\"result\":{\"rateLimits\":" <> body <> "}}"

decoded :: String -> Either Text CodexAccountLimit
decoded = either (Left . (.providerErrorMessage)) Right . decodeCodexAccountLimit . LazyChar8.pack

snapshotSpec :: Spec
snapshotSpec = describe "the Codex account snapshot" $ do
  it "reads the reached type, and null as none" $ do
    decoded (snapshotResponse ("{\"rateLimitReachedType\":\"rate_limit_reached\",\"primary\":" <> window 100 resetEpoch <> "}"))
      `shouldBe` reached "rate_limit_reached" (Just resetTime)
    decoded (snapshotResponse ("{\"rateLimitReachedType\":null,\"primary\":" <> window 40 resetEpoch <> "}"))
      `shouldBe` Right (CodexAccountLimit Nothing Nothing)

  it "disregards a window with room left and takes the latest exhausted reset" $ do
    decoded (snapshotResponse ("{\"primary\":" <> window 40 (resetEpoch - 100) <> ",\"secondary\":" <> window 100 resetEpoch <> "}"))
      `shouldBe` Right (CodexAccountLimit Nothing (Just resetTime))
    decoded (snapshotResponse ("{\"primary\":" <> window 100 (resetEpoch - 100) <> ",\"secondary\":" <> window 100 resetEpoch <> "}"))
      `shouldBe` Right (CodexAccountLimit Nothing (Just resetTime))

  it "reads the codex bucket, not an unrelated one" $
    decoded
      ( "{\"id\":1,\"result\":{\"rateLimits\":{\"rateLimitReachedType\":\"rate_limit_reached\",\"primary\":"
          <> window 100 resetEpoch
          <> "},\"rateLimitsByLimitId\":{\"codex\":{\"primary\":"
          <> window 10 resetEpoch
          <> "}}}}"
      )
      `shouldBe` Right (CodexAccountLimit Nothing Nothing)

  it "refuses a response it cannot decode rather than reading it as no limit" $ do
    decoded "not json" `shouldSatisfy` either (const True) (const False)
    decoded "{\"id\":1,\"error\":{\"message\":\"login required\"}}" `shouldSatisfy` either (const True) (const False)

-- ---------------------------------------------------------------------------
-- The mechanism
-- ---------------------------------------------------------------------------

-- | A fake provider that prints the given lines on stdout and exits 1, and —
-- for Codex — answers the app-server account read with the given response.
writeFakeProvider :: FilePath -> String -> [String] -> Maybe String -> IO ()
writeFakeProvider binaryRoot name streamLines snapshot = do
  let path = binaryRoot </> name
  writeFile
    path
    ( unlines
        ( ["#!/bin/sh"]
            <> case snapshot of
              Nothing -> []
              Just response ->
                [ "if [ \"$1\" = app-server ]; then",
                  "  read -r initialize",
                  "  printf '%s\\n' '{\"id\":0,\"result\":{}}'",
                  "  read -r initialized",
                  "  read -r request",
                  "  printf '%s\\n' '" <> response <> "'",
                  "  exit 0",
                  "fi"
                ]
            <> ["printf '%s\\n' '" <> line <> "'" | line <- streamLines]
            <> ["exit 1"]
        )
    )
  setFileMode path 0o700

-- | Runs one solve against the fake provider through the real reader and
-- session log, and hands back the settled worker a mission would read.
settledSolve :: FilePath -> SolverBrand -> IO (WorkerDescriptor, WorkerState, Text)
settledSolve temporaryRoot brand = do
  let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
  createDirectory repository.repositoryRoot
  recorded <- newIORef []
  aggregator <- newUnknownAggregator
  runSolve
    repository
    844
    SolveOnly
    brand
    Nothing
    defaultWorkflowConfig
    (recordedAssignmentCell (cellOf (solveAssignment defaultRoster brand)))
    Nothing
    Nothing
    ResumeAnswer
    ""
    aggregator
    (\event -> modifyIORef recorded (event :))
  seen <- readIORef recorded
  let logPath = case [path | SolveLogOpened _ path <- seen] of
        (path : _) -> Just path
        [] -> Nothing
      detail = case [message | SolveProcessFinished _ (SolveFailed message) <- seen] of
        (message : _) -> message
        [] -> error "the fake provider's session did not fail"
      identifier = WorkerId "limit-worker"
      workerSpec =
        (workerFixtureSpec repository identifier 844)
          { workerTask = SolveWorkerTaskKind (SolveWorkerTask 844 SolveOnly brand),
            workerAssignment = Just (cellOf (solveAssignment defaultRoster brand))
          }
      state = (runningWorkerState identifier 999999 Nothing) {workerStateStatus = WorkerTerminal (SolveFailed detail), workerStateLogPath = logPath}
  descriptor <- descriptorForSpec workerSpec
  pure (descriptor, state, detail)

withFakeProvider :: String -> [String] -> Maybe String -> (FilePath -> IO result) -> IO result
withFakeProvider name streamLines snapshot action =
  withTemporaryCacheRoot $ \temporaryRoot -> do
    let binaryRoot = temporaryRoot </> "bin"
    createDirectory binaryRoot
    writeFakeProvider binaryRoot name streamLines snapshot
    originalPath <- maybe "" id <$> lookupEnv "PATH"
    withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
      withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $
        action temporaryRoot

seams :: ProviderLimitSeams
seams = liveProviderLimitSeams (10 * 1000 * 1000)

isCapacity :: Maybe UTCTime -> ActionOutcome -> Bool
isCapacity expected (ActionCapacityLimited resetsAt _) = resetsAt == expected
isCapacity _ _ = False

mechanismSpec :: Spec
mechanismSpec = describe "a settled worker's recorded session" $ do
  it "types a Claude session rejected at an uncovered limit as a capacity limit with its reset time" $
    withFakeProvider "claude" [rateLimitEvent "rejected" ",\"overageStatus\":\"rejected\"", errorResult "429"] Nothing $ \root -> do
      (descriptor, state, detail) <- settledSolve root ClaudeSolver
      settledProviderFailure seams descriptor state detail >>= (`shouldSatisfy` isCapacity (Just resetTime))
      -- The board reads the same worker through the registry's own
      -- observation, which is unchanged: it still reports the failure.
      settledWorkerFailure detail `shouldBe` ActionFailed detail

  it "types a Claude 429 with no rate-limit event as a capacity limit the mission backs off" $
    withFakeProvider "claude" [errorResult "429"] Nothing $ \root -> do
      (descriptor, state, detail) <- settledSolve root ClaudeSolver
      settledProviderFailure seams descriptor state detail >>= (`shouldSatisfy` isCapacity Nothing)

  it "reads only the latest invocation a resumed session log records" $
    withFakeProvider "claude" [errorResult "401"] Nothing $ \root -> do
      (descriptor, state, detail) <- settledSolve root ClaudeSolver
      -- An earlier turn of the same log, rejected at a limit, prepended: its
      -- rate-limit event is not evidence about the turn that just failed, and
      -- read as one it would turn this authentication failure into a wait.
      case state.workerStateLogPath of
        Nothing -> expectationFailure "the solve recorded no session log"
        Just path -> do
          current <- ByteString.readFile path
          ByteString.writeFile
            path
            ( ByteString.unlines
                [ "{\"stream\":\"kanban\",\"event\":\"invocation-started\",\"message\":\"earlier\"}",
                  "{\"stream\":\"stdout\",\"raw\":" <> ByteString.pack (show (rateLimitEvent "rejected" "")) <> "}"
                ]
                <> current
            )
          settledProviderFailure seams descriptor state detail `shouldReturn` ActionFailed detail

  it "types a Codex session as a capacity limit when the account read after it reports one" $
    withFakeProvider
      "codex"
      [ "{\"type\":\"thread.started\",\"thread_id\":\"t\"}",
        "{\"type\":\"turn.failed\",\"error\":{\"message\":\"anything\"}}"
      ]
      (Just (snapshotResponse ("{\"rateLimitReachedType\":\"rate_limit_reached\",\"primary\":" <> window 100 resetEpoch <> "}")))
      $ \root -> do
        (descriptor, state, detail) <- settledSolve root CodexSolver
        settledProviderFailure seams descriptor state detail >>= (`shouldSatisfy` isCapacity (Just resetTime))

  it "fails a Codex session exactly as before when the account reports no limit" $
    withFakeProvider
      "codex"
      ["{\"type\":\"turn.failed\",\"error\":{\"message\":\"You've hit your usage limit.\"}}"]
      (Just (snapshotResponse ("{\"primary\":" <> window 20 resetEpoch <> "}")))
      $ \root -> do
        (descriptor, state, detail) <- settledSolve root CodexSolver
        settledProviderFailure seams descriptor state detail `shouldReturn` ActionFailed detail

  it "fails a Codex session exactly as before when the account cannot be read" $
    withFakeProvider
      "codex"
      ["{\"type\":\"turn.failed\",\"error\":{\"message\":\"anything\"}}"]
      (Just "this is not the app server you are looking for")
      $ \root -> do
        (descriptor, state, detail) <- settledSolve root CodexSolver
        settledProviderFailure seams descriptor state detail `shouldReturn` ActionFailed detail

  it "names depleted Codex credits in the failure detail" $
    withFakeProvider
      "codex"
      ["{\"type\":\"turn.failed\",\"error\":{\"message\":\"anything\"}}"]
      (Just (snapshotResponse "{\"rateLimitReachedType\":\"workspace_member_credits_depleted\"}"))
      $ \root -> do
        (descriptor, state, detail) <- settledSolve root CodexSolver
        outcome <- settledProviderFailure seams descriptor state detail
        case outcome of
          ActionFailed message -> message `shouldSatisfy` Text.isPrefixOf "credits are depleted"
          other -> expectationFailure ("expected a failure naming credits, got " <> show other)

  it "never asks the account about a Codex session whose turn did not fail, such as one a user killed" $
    withFakeProvider
      "codex"
      ["{\"type\":\"thread.started\",\"thread_id\":\"t\"}"]
      (Just (snapshotResponse ("{\"rateLimitReachedType\":\"rate_limit_reached\",\"primary\":" <> window 100 resetEpoch <> "}")))
      $ \root -> do
        (descriptor, state, _) <- settledSolve root CodexSolver
        settledProviderFailure seams descriptor state "killed by user" `shouldReturn` ActionFailed "killed by user"

  it "keeps a deadline a deadline, whatever the provider recorded beside it" $
    withFakeProvider "claude" [errorResult "429"] Nothing $ \root -> do
      (descriptor, state, _) <- settledSolve root ClaudeSolver
      settledProviderFailure seams descriptor state workerDeadlineReason
        `shouldReturn` ActionDeadlineExceeded workerDeadlineReason

  it "fails a worker with no session log exactly as before" $
    withFakeProvider "claude" [errorResult "429"] Nothing $ \root -> do
      (descriptor, state, detail) <- settledSolve root ClaudeSolver
      settledProviderFailure seams descriptor state {workerStateLogPath = Nothing} detail `shouldReturn` ActionFailed detail
