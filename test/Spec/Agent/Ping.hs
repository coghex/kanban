-- | @kanban --ping BRAND@: the one action that deliberately spends quota.
--
-- One recorder underpins the whole module.  Fake @codex@ and @claude@
-- executables sit first on @PATH@ and append every argument list they are
-- launched with to a single log, so "exactly one ping ran" and "no ping ran"
-- are the same measurement taken on the same mechanism rather than two
-- assertions that could both be vacuous.  A ping is told apart from the probe
-- that legitimately spawns the same executable by its recorded arguments — the
-- fixed prompt appears in one and never in the other.
module Spec.Agent.Ping (spec) where

import Control.Exception (IOException, try)
import qualified Data.ByteString.Char8 as ByteString
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (TimeZone, UTCTime, hoursToTimeZone)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Kanban.CLI (Options (..), optionsParserInfo)
import Kanban.Cache (UsageCacheLoad (..), loadUsageCache, writeUsageCache)
import Kanban.Claude (claudeScratchDirectory)
import Kanban.Config
  ( ResolvedConfig (..),
    TimeoutsConfig (..),
    UsageCommandConfig (..),
    UsageConfig (..),
    defaultTimeoutsConfig,
  )
import Kanban.Domain (UsageProvider (..), UsageSnapshot (..), UsageWindow (..))
import Kanban.Ping
  ( PingBrand (..),
    PingLaunch (..),
    PingMode (..),
    PingResult (..),
    pingArguments,
    pingPrompt,
    pingResultLines,
    pingResultProblems,
    pingResultSucceeded,
    pingScratchDirectory,
    pingTimeoutMicros,
    resolvePingBrand,
    runPing,
  )
import Kanban.Preflight (gatherPreflightEnvironment)
import Kanban.Usage (UsageAcquisition (..), acquireUsageReport)
import Options.Applicative (defaultPrefs, execParserPure, getParseResult)
import Spec.Support.Env (createTemporaryDirectory, withEnvironmentValue, withTemporaryCacheRoot, writeExecutableScript)
import Spec.Support.Fixtures (testResolvedConfig)
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    removePathForcibly,
    withCurrentDirectory,
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (readFile')
import Test.Hspec

spec :: Spec
spec = do
  describe "selecting a brand to ping" $ do
    it "leaves the dashboard selected when --ping is absent" $
      fmap (.optionPing) (parseOptions []) `shouldBe` Just []

    it "accepts each brand by name" $ do
      fmap (.optionPing) (parseOptions ["--ping", "codex"]) `shouldBe` Just ["codex"]
      resolvePingBrand ["codex"] `shouldBe` Right PingCodex
      resolvePingBrand ["claude"] `shouldBe` Right PingClaude

    -- optparse-applicative refuses the flag without its argument, so the
    -- "omitted brand" error never has to be recovered from further in.
    it "rejects --ping with no brand at all" $
      parseOptions ["--ping"] `shouldBe` Nothing

    it "rejects a brand it does not know" $
      resolvePingBrand ["gpt"] `shouldSatisfy` refusedNaming "gpt"

    -- Collected as a list rather than a last-one-wins option precisely so
    -- this is reachable: a repeat must be refused, not silently resolved.
    it "keeps every occurrence so a repeated flag is refused rather than resolved" $ do
      fmap (.optionPing) (parseOptions ["--ping", "codex", "--ping", "claude"])
        `shouldBe` Just ["codex", "claude"]
      resolvePingBrand ["codex", "claude"] `shouldSatisfy` refused
      resolvePingBrand ["codex", "codex"] `shouldSatisfy` refused

    it "rejects an empty selection" $
      resolvePingBrand [] `shouldSatisfy` refused

  describe "the invocation a ping is allowed to make" $ do
    it "sends one fixed prompt" $ do
      pingPrompt `shouldBe` "Reply OK."
      filter (== pingPrompt) (pingArguments PingCodex) `shouldBe` [pingPrompt]
      filter (== pingPrompt) (pingArguments PingClaude) `shouldBe` [pingPrompt]

    it "asks each client for its minimum effort" $ do
      pingArguments PingCodex `shouldContain` ["model_reasoning_effort=\"minimal\""]
      pingArguments PingClaude `shouldContain` ["--effort", "low"]

    it "asks for non-mutating permissions" $ do
      pingArguments PingCodex `shouldContain` ["--sandbox", "read-only"]
      pingArguments PingClaude `shouldContain` ["--permission-mode", "plan"]

    -- The solve invocation is the shape a ping must never grow into: it runs
    -- in the user's repository with approvals and the sandbox switched off,
    -- because it is there to change files.
    it "carries none of the bypass vocabulary the solve invocation uses" $
      mapM_
        (\brand -> mapM_ (\forbidden -> pingArguments brand `shouldNotContain` [forbidden]) bypassArguments)
        [PingCodex, PingClaude]

    it "runs from a private Kanban directory under the cache root rather than a checkout" $
      withTemporaryCacheRoot $ \root ->
        withEnvironmentValue "XDG_CACHE_HOME" root $ do
          codexScratch <- pingScratchDirectory PingCodex
          claudeScratch <- pingScratchDirectory PingClaude
          codexScratch `shouldSatisfy` (root `isInfixOf`)
          claudeScratch `shouldSatisfy` (root `isInfixOf`)
          -- The Claude client asks whether it may trust a folder the first
          -- time it runs there; sharing the probe's settled directory is what
          -- keeps a non-interactive ping off that prompt.
          claudeScratch `shouldBe` (root </> "kanban" </> "claude-probe")
          probeScratch <- claudeScratchDirectory
          claudeScratch `shouldBe` probeScratch

    it "bounds the model round trip by its own configured timeout" $ do
      pingTimeoutMicros PingCodex (timedConfig 7 9) `shouldBe` 7000000
      pingTimeoutMicros PingClaude (timedConfig 7 9) `shouldBe` 9000000
      defaultTimeoutsConfig.timeoutsPingCodexSeconds `shouldBe` 120
      defaultTimeoutsConfig.timeoutsPingClaudeSeconds `shouldBe` 120

  describe "what one explicit ping launches" $ do
    it "runs one ping for the selected brand and none for the other" $
      withPingRoot $ \root -> do
        result <- runPing (PingMode PingCodex False) =<< refreshingConfig root
        result.pingResultLaunch `shouldBe` PingExited ExitSuccess
        pingsRecorded root `shouldReturn` [("codex", unwords (pingArguments PingCodex))]
        refreshesRecorded root `shouldReturn` ["codex"]

    it "runs the Claude ping the same way" $
      withPingRoot $ \root -> do
        result <- runPing (PingMode PingClaude False) =<< refreshingConfig root
        result.pingResultLaunch `shouldBe` PingExited ExitSuccess
        pingsRecorded root `shouldReturn` [("claude", unwords (pingArguments PingClaude))]
        refreshesRecorded root `shouldReturn` ["claude"]

    -- The refresh legitimately spawns the same executable when it uses the
    -- built-in probe, so "exactly one ping" can only ever be a claim about
    -- recorded arguments. Both invocations land in one log here to show the
    -- recorder distinguishes them rather than counting launches.
    it "stays one ping even when the refresh spawns the same executable" $
      withPingRoot $ \root -> do
        _ <- runPing (PingMode PingCodex False) probeRefreshConfig
        pingsRecorded root `shouldReturn` [("codex", unwords (pingArguments PingCodex))]
        nonPingLaunches root `shouldReturn` [("codex", "app-server --stdio")]

    it "answers from a directory that is not a Git repository at all" $
      withPingRoot $ \root -> do
        outsideRepository <- createTemporaryDirectory
        config <- refreshingConfig root
        result <- withCurrentDirectory outsideRepository (runPing (PingMode PingCodex False) config)
        removePathForcibly outsideRepository
        pingResultSucceeded result `shouldBe` True

  describe "the refresh a launched ping owes" $ do
    it "refreshes once after a ping that succeeded" $
      withPingRoot $ \root -> do
        result <- runPing (PingMode PingCodex False) =<< refreshingConfig root
        refreshesRecorded root `shouldReturn` ["codex"]
        pingResultSucceeded result `shouldBe` True

    it "refreshes once after a ping that exited non-zero, which may already have spent quota" $
      withPingRoot $ \root ->
        withEnvironmentValue pingModeVariable "fail" $ do
          result <- runPing (PingMode PingCodex False) =<< refreshingConfig root
          result.pingResultLaunch `shouldBe` PingExited (ExitFailure 3)
          refreshesRecorded root `shouldReturn` ["codex"]
          length <$> pingsRecorded root `shouldReturn` 1

    it "refreshes once after a ping that timed out, which may already have spent quota" $
      withPingRoot $ \root ->
        withEnvironmentValue pingModeVariable "hang" $ do
          config <- refreshingConfig root
          result <- runPing (PingMode PingCodex False) config {resolvedTimeouts = timedTimeouts 1 1}
          result.pingResultLaunch `shouldBe` PingTimedOut 1
          refreshesRecorded root `shouldReturn` ["codex"]
          length <$> pingsRecorded root `shouldReturn` 1

    -- Nothing ran, so nothing can have been charged, so there is nothing to
    -- report a new window for.
    it "refreshes not at all when the executable could not be started" $
      withPingRoot $ \root ->
        withEnvironmentValue "PATH" "/nonexistent/kanban-ping-fixture" $ do
          result <- runPing (PingMode PingCodex False) =<< refreshingConfig root
          result.pingResultLaunch `shouldSatisfy` notStarted
          result.pingResultRefresh `shouldBe` Nothing
          refreshesRecorded root `shouldReturn` []
          pingsRecorded root `shouldReturn` []

  describe "what the command exits with" $ do
    it "succeeds only when the ping, the refresh, and the storage all did" $
      withPingRoot $ \root -> do
        result <- runPing (PingMode PingCodex True) =<< refreshingConfig root
        pingResultSucceeded result `shouldBe` True
        pingResultProblems result `shouldBe` []

    it "fails a ping that exited non-zero even though its refresh succeeded" $
      withPingRoot $ \root ->
        withEnvironmentValue pingModeVariable "fail" $ do
          result <- runPing (PingMode PingCodex True) =<< refreshingConfig root
          result.pingResultRefresh `shouldSatisfy` refreshProduced
          pingResultSucceeded result `shouldBe` False
          Text.concat (pingResultProblems result) `shouldSatisfy` Text.isInfixOf "exited 3"

    it "fails a ping that could not be started, and says no refresh ran" $
      withPingRoot $ \root ->
        withEnvironmentValue "PATH" "/nonexistent/kanban-ping-fixture" $ do
          result <- runPing (PingMode PingCodex True) =<< refreshingConfig root
          pingResultSucceeded result `shouldBe` False
          Text.concat (pingResultProblems result) `shouldSatisfy` Text.isInfixOf "no usage refresh ran"

    it "fails when the refresh failed" $
      withPingRoot $ \root -> do
        result <- runPing (PingMode PingCodex True) =<< failingRefreshConfig root
        result.pingResultLaunch `shouldBe` PingExited ExitSuccess
        refreshesRecorded root `shouldReturn` ["codex"]
        pingResultSucceeded result `shouldBe` False

    -- Printed and still fatal: the user was told what the window looks like,
    -- and also that the next run will not remember it.
    it "fails when the refreshed result could not be stored, having printed it anyway" $
      withPingRoot $ \root -> do
        blockUsageCachePath root
        result <- runPing (PingMode PingCodex True) =<< refreshingConfig root
        result.pingResultCacheError `shouldSatisfy` (/= Nothing)
        pingResultSucceeded result `shouldBe` False
        pingResultLines zone now result `shouldSatisfy` any (Text.isInfixOf "% left")
        -- The failed write replaced nothing that was already there.
        doesDirectoryExist (usageCachePath root) `shouldReturn` True

    it "never retries a ping that failed" $
      withPingRoot $ \root ->
        withEnvironmentValue pingModeVariable "fail" $ do
          _ <- runPing (PingMode PingCodex True) =<< refreshingConfig root
          length <$> pingsRecorded root `shouldReturn` 1

  describe "what the refreshed state reports" $ do
    it "prints every returned window with the wall clock it ends at" $
      withPingRoot $ \root -> do
        result <- runPing (PingMode PingCodex False) =<< refreshingConfig root
        pingResultLines zone now result
          `shouldBe` [ "Codex",
                       "  codex-window   71% left · resets in 5h 0m (Thu 17:00)",
                       "  snapshot 0s old"
                     ]

    it "prints the failing provider's own line when the refresh failed" $
      withPingRoot $ \root -> do
        result <- runPing (PingMode PingCodex False) =<< failingRefreshConfig root
        pingResultLines zone now result `shouldSatisfy` any (Text.isInfixOf "unavailable")

  describe "what a ping does to the snapshot cache" $ do
    it "merges the pinged brand into the stored map without dropping the other" $
      withPingRoot $ \root -> do
        seedCache (Map.fromList [(Codex, cachedSnapshot), (Claude, cachedSnapshot)])
        _ <- runPing (PingMode PingCodex True) =<< refreshingConfig root
        storedPercentages `shouldReturn` Map.fromList [(Codex, [71]), (Claude, [12])]

    it "retains the previous cache when the refresh failed" $
      withPingRoot $ \root -> do
        seedCache (Map.fromList [(Codex, cachedSnapshot), (Claude, cachedSnapshot)])
        _ <- runPing (PingMode PingCodex True) =<< failingRefreshConfig root
        storedPercentages `shouldReturn` Map.fromList [(Codex, [12]), (Claude, [12])]

    -- Paired with the merge case above on purpose: a "did not write"
    -- assertion means nothing until the same fixture, through the same
    -- writer, has been shown to write.
    it "neither reads nor writes the cache when caching is off, and still pings, refreshes, and reports" $
      withPingRoot $ \root -> do
        seedCache (Map.fromList [(Codex, cachedSnapshot), (Claude, cachedSnapshot)])
        result <- runPing (PingMode PingCodex False) =<< refreshingConfig root
        pingsRecorded root `shouldReturn` [("codex", unwords (pingArguments PingCodex))]
        refreshesRecorded root `shouldReturn` ["codex"]
        pingResultLines zone now result `shouldSatisfy` any (Text.isInfixOf "codex-window")
        -- Deliberately disabled persistence is not a failure.
        pingResultSucceeded result `shouldBe` True
        storedPercentages `shouldReturn` Map.fromList [(Codex, [12]), (Claude, [12])]

  describe "the paths that must never ping" $ do
    -- The same recorder that counted exactly one ping above counts none here.
    -- These paths do spawn providers — that is what makes the measurement
    -- real — so the assertion is about pings, not about launches.
    it "launches no ping from a usage acquisition, which is what --usage, startup, and u all run" $
      withPingRoot $ \root -> do
        config <- refreshingConfig root
        _ <- acquireUsageReport UsageForceFresh False config
        refreshesRecorded root `shouldReturn` ["codex", "claude"]
        pingsRecorded root `shouldReturn` []

    it "launches no ping from the readiness gathering behind --doctor and preflight" $
      withPingRoot $ \root -> do
        _ <- gatherPreflightEnvironment "."
        pingsRecorded root `shouldReturn` []

    -- Release verification is the same account-status probe path, which
    -- decision D-2 requires to submit no model prompt at all.
    it "launches no ping from the built-in probes release verification exercises" $
      withPingRoot $ \root -> do
        _ <- acquireUsageReport UsageForceFresh False probeRefreshConfig
        nonPingLaunches root `shouldNotReturn` []
        pingsRecorded root `shouldReturn` []

parseOptions :: [String] -> Maybe Options
parseOptions arguments = getParseResult (execParserPure defaultPrefs optionsParserInfo arguments)

refused :: Either Text PingBrand -> Bool
refused = either (const True) (const False)

refusedNaming :: Text -> Either Text PingBrand -> Bool
refusedNaming needle = either (Text.isInfixOf needle) (const False)

notStarted :: PingLaunch -> Bool
notStarted (PingNotStarted _) = True
notStarted _ = False

refreshProduced :: Maybe outcome -> Bool
refreshProduced = maybe False (const True)

-- | The arguments "Kanban.Solve" hands a provider so it can rewrite the user's
-- checkout. A ping must contain none of them.
bypassArguments :: [String]
bypassArguments =
  [ "--dangerously-bypass-approvals-and-sandbox",
    "bypassPermissions",
    "--permission-mode=bypassPermissions",
    "--full-auto",
    "acceptEdits"
  ]

timedConfig :: Int -> Int -> ResolvedConfig
timedConfig codexSeconds claudeSeconds =
  testResolvedConfig {resolvedTimeouts = timedTimeouts codexSeconds claudeSeconds}

timedTimeouts :: Int -> Int -> TimeoutsConfig
timedTimeouts codexSeconds claudeSeconds =
  defaultTimeoutsConfig
    { timeoutsPingCodexSeconds = codexSeconds,
      timeoutsPingClaudeSeconds = claudeSeconds
    }

-- | Pins the XDG cache root — the snapshot cache and both ping scratch
-- directories hang off it — and puts the recording provider fakes first on
-- @PATH@, so nothing a ping touches escapes the fixture.
withPingRoot :: (FilePath -> IO result) -> IO result
withPingRoot action =
  withTemporaryCacheRoot $ \root ->
    withEnvironmentValue "XDG_CACHE_HOME" root $
      withEnvironmentValue invocationLogVariable (invocationLog root) $ do
        binaryRoot <- installRecordingProviders root
        originalPath <- fromMaybe "" <$> lookupEnv "PATH"
        withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) (action root)

-- | Fake @codex@ and @claude@ clients that record the exact argument list they
-- were launched with. @KANBAN_PING_TEST_MODE@ chooses how the launched process
-- then ends, so a failing and a hanging client are the same recorder as a
-- succeeding one.
installRecordingProviders :: FilePath -> IO FilePath
installRecordingProviders root = do
  let binaryRoot = root </> "bin"
  createDirectoryIfMissing True binaryRoot
  mapM_ (writeRecorder binaryRoot) ["codex", "claude"]
  pure binaryRoot
  where
    writeRecorder binaryRoot name =
      writeExecutableScript
        (binaryRoot </> name)
        [ ByteString.pack ("printf '%s\\t%s\\n' " <> name <> " \"$*\" >> \"$" <> invocationLogVariable <> "\""),
          "case \"${KANBAN_PING_TEST_MODE:-ok}\" in",
          "  fail) exit 3 ;;",
          "  hang) sleep 30 ;;",
          "esac",
          "exit 0"
        ]

-- | A configured usage command for each provider, recording into the same log
-- so one measurement covers pings and refreshes alike. Requirement 10: the
-- external command replaces the refresh and never the ping.
refreshingConfig :: FilePath -> IO ResolvedConfig
refreshingConfig root = do
  codexCommand <- refreshCommand root "codex" 71
  claudeCommand <- refreshCommand root "claude" 22
  pure (configuredWith codexCommand claudeCommand)

-- | The same recording refresh commands, emitting output no decoder accepts.
failingRefreshConfig :: FilePath -> IO ResolvedConfig
failingRefreshConfig root = do
  codexCommand <- brokenRefreshCommand root "codex"
  claudeCommand <- brokenRefreshCommand root "claude"
  pure (configuredWith codexCommand claudeCommand)

-- | No configured command at all, so the refresh runs the built-in probe and
-- spawns the brand's own executable a second time. The probe timeouts are
-- shortened because the fakes here answer no protocol at all and the point of
-- the case is what got launched, not what came back.
probeRefreshConfig :: ResolvedConfig
probeRefreshConfig =
  testResolvedConfig
    { resolvedTimeouts =
        defaultTimeoutsConfig {timeoutsCodexSeconds = 3, timeoutsClaudeSeconds = 3}
    }

configuredWith :: FilePath -> FilePath -> ResolvedConfig
configuredWith codexCommand claudeCommand =
  testResolvedConfig
    { resolvedUsage =
        UsageConfig
          { usageCodexCommand = Just (UsageCommandConfig [Text.pack codexCommand]),
            usageClaudeCommand = Just (UsageCommandConfig [Text.pack claudeCommand])
          }
    }

refreshCommand :: FilePath -> String -> Int -> IO FilePath
refreshCommand root name percentLeft =
  writeExecutableScript
    (root </> (name <> "-refresh.sh"))
    [ recordRefresh name,
      ByteString.pack
        ( "printf '%s' '{\"windows\":[{\"label\":\""
            <> name
            <> "-window\",\"pct_left\":"
            <> show percentLeft
            <> ",\"resets_at\":\"2026-07-16T17:00:00Z\"}]}'"
        )
    ]

brokenRefreshCommand :: FilePath -> String -> IO FilePath
brokenRefreshCommand root name =
  writeExecutableScript
    (root </> (name <> "-broken-refresh.sh"))
    [recordRefresh name, "printf '%s' 'not a usage document'"]

recordRefresh :: String -> ByteString.ByteString
recordRefresh name =
  ByteString.pack ("printf '%s\\t%s\\n' " <> name <> "-refresh \"$*\" >> \"$" <> invocationLogVariable <> "\"")

invocationLogVariable, pingModeVariable :: String
invocationLogVariable = "KANBAN_PING_TEST_LOG"
pingModeVariable = "KANBAN_PING_TEST_MODE"

invocationLog :: FilePath -> FilePath
invocationLog root = root </> "invocations.log"

-- | Every recorded launch as @(executable, joined arguments)@. An absent log
-- is no launches, which is the state the never-ping cases assert.
recordedInvocations :: FilePath -> IO [(Text, Text)]
recordedInvocations root = do
  recorded <- try @IOException (readFile' (invocationLog root))
  pure (map split (either (const []) lines recorded))
  where
    split line = let (name, rest) = Text.breakOn "\t" (Text.pack line) in (name, Text.drop 1 rest)

-- | A ping is exactly a provider launch carrying the fixed prompt; the probe
-- that spawns the same executable never carries it.
pingsRecorded :: FilePath -> IO [(String, String)]
pingsRecorded root = map render . filter (isPing . snd) <$> recordedInvocations root
  where
    render (name, arguments) = (Text.unpack name, Text.unpack arguments)

nonPingLaunches :: FilePath -> IO [(String, String)]
nonPingLaunches root =
  map render . filter (\(name, arguments) -> not (isPing arguments) && not ("-refresh" `Text.isSuffixOf` name))
    <$> recordedInvocations root
  where
    render (name, arguments) = (Text.unpack name, Text.unpack arguments)

refreshesRecorded :: FilePath -> IO [String]
refreshesRecorded root =
  map (Text.unpack . fst . Text.breakOn "-refresh" . fst)
    . filter (("-refresh" `Text.isSuffixOf`) . fst)
    <$> recordedInvocations root

isPing :: Text -> Bool
isPing = Text.isInfixOf (Text.pack pingPrompt)

usageCachePath :: FilePath -> FilePath
usageCachePath root = root </> "kanban" </> "usage.json"

-- | Occupies the snapshot file's own path with a directory, so the writer's
-- atomic rename cannot complete. Nothing else about the cache root changes,
-- and the blocked path is still there afterwards to prove the failed write
-- replaced nothing.
blockUsageCachePath :: FilePath -> IO ()
blockUsageCachePath root = createDirectoryIfMissing True (usageCachePath root)

seedCache :: Map.Map UsageProvider UsageSnapshot -> IO ()
seedCache snapshots = do
  outcome <- writeUsageCache snapshots
  either (expectationFailure . Text.unpack) pure outcome

storedPercentages :: IO (Map.Map UsageProvider [Int])
storedPercentages = do
  load <- loadUsageCache
  case load of
    UsageCacheLoaded snapshots -> pure (fmap (map (.usagePercentLeft) . (.usageWindows)) snapshots)
    UsageCacheAbsent -> pure Map.empty
    UsageCacheInvalid message -> Map.empty <$ expectationFailure (Text.unpack message)

cachedSnapshot :: UsageSnapshot
cachedSnapshot =
  UsageSnapshot [UsageWindow "cached" 12 (instant "2026-07-16T17:00:00Z")] (instant "2026-07-16T11:30:00Z")

-- | The refresh stamps its snapshot with the real clock, so the rendering is
-- pinned against a zone and an instant chosen to make the fixture's own reset
-- time land on a stable wall clock and its snapshot age read as fresh.
zone :: TimeZone
zone = hoursToTimeZone 0

now :: UTCTime
now = instant "2026-07-16T12:00:00Z"

instant :: String -> UTCTime
instant text = case iso8601ParseM text of
  Just parsed -> parsed
  Nothing -> error ("fixture instant is not ISO 8601: " <> text)
