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
  ( RawConfig,
    ResolvedConfig (..),
    TimeoutsConfig (..),
    UsageCommandConfig (..),
    UsageConfig (..),
    decodeConfigText,
    defaultTimeoutsConfig,
  )
import Kanban.Domain (UsageProvider (..), UsageSnapshot (..), UsageWindow (..))
import Kanban.Ping
  ( PingBrand (..),
    PingLaunch (..),
    PingMode (..),
    PingResult (..),
    ownedGroupMembers,
    pingArguments,
    pingPrompt,
    pingRepositoryIdentity,
    pingResolvedConfig,
    pingResultLines,
    pingResultProblems,
    pingResultSucceeded,
    pingScratchDirectory,
    pingTimeoutMicros,
    resolvePingBrand,
    runPing,
    sweepOwnedGroup,
  )
import Kanban.Preflight (gatherPreflightEnvironment)
import Kanban.Process (ProcessIdentity (..))
import Kanban.Usage (UsageAcquisition (..), acquireUsageReport)
import Options.Applicative (defaultPrefs, execParserPure, getParseResult)
import Spec.Support.Env
  ( createTemporaryDirectory,
    waitForFileToExist,
    withEnvironmentValue,
    withTemporaryCacheRoot,
    writeExecutableScript,
  )
import Spec.Support.Fixtures (fullFixtureToml, testResolvedConfig)
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
import System.Posix.Signals (nullSignal, sigKILL, signalProcess)
import System.Posix.Types (ProcessID)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (NoStream),
    createProcess,
    proc,
    waitForProcess,
  )
import Test.Hspec
import Text.Read (readMaybe)

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
          -- Shared with the probe so Claude's session state lands in one
          -- place outside the user's project. What keeps the ping off the
          -- client's folder-trust prompt is the non-interactive invocation,
          -- which the cold-cache case below exercises directly.
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

    -- The first ping on a machine creates its own scratch directory, so
    -- nothing about the run may depend on that directory having been used
    -- before. Claude is the brand that would notice: its client asks about
    -- folder trust, and the non-interactive invocation is what keeps this off
    -- that prompt rather than any earlier probe having answered it.
    it "runs the same ping on a cold cache where the scratch directory has never existed" $
      withPingRoot $ \root -> do
        scratch <- pingScratchDirectory PingClaude
        doesDirectoryExist scratch `shouldReturn` False
        result <- runPing (PingMode PingClaude False) =<< refreshingConfig root
        doesDirectoryExist scratch `shouldReturn` True
        result.pingResultLaunch `shouldBe` PingExited ExitSuccess
        pingsRecorded root `shouldReturn` [("claude", unwords (pingArguments PingClaude))]
        refreshesRecorded root `shouldReturn` ["claude"]

    it "answers from a directory that is not a Git repository at all" $
      withPingRoot $ \root -> do
        outsideRepository <- createTemporaryDirectory
        config <- refreshingConfig root
        result <- withCurrentDirectory outsideRepository (runPing (PingMode PingCodex False) config)
        removePathForcibly outsideRepository
        pingResultSucceeded result `shouldBe` True

  -- A leader that exits is not a ping that is over. The client is free to fork
  -- a helper that keeps working — and keeps spending the window this command
  -- exists to bound — so the group has to be swept however the leader ended.
  describe "what a ping leaves running" $ do
    it "kills a helper that outlived a ping whose leader exited successfully" $
      withPingRoot $ \root ->
        withEnvironmentValue pingModeVariable "orphan" $ do
          result <- runPing (PingMode PingCodex False) =<< refreshingConfig root
          result.pingResultLaunch `shouldBe` PingExited ExitSuccess
          helper <- helperPid root
          processAlive helper `shouldReturn` False

    it "kills a helper that outlived a ping that timed out" $
      withPingRoot $ \root ->
        withEnvironmentValue pingModeVariable "orphan-hang" $ do
          config <- refreshingConfig root
          result <- runPing (PingMode PingCodex False) config {resolvedTimeouts = timedTimeouts 1 1}
          result.pingResultLaunch `shouldBe` PingTimedOut 1
          helper <- helperPid root
          processAlive helper `shouldReturn` False

    -- A descendant whose own parent has already exited was never a child of
    -- the leader and would be absent from any census pinned at spawn, but it
    -- is still in the group and still spending the window.
    it "kills a grandchild whose parent exited before the leader did" $
      withPingRoot $ \root ->
        withEnvironmentValue pingModeVariable "chain" $ do
          result <- runPing (PingMode PingCodex False) =<< refreshingConfig root
          result.pingResultLaunch `shouldBe` PingExited ExitSuccess
          helper <- helperPid root
          processAlive helper `shouldReturn` False

    -- Without a process snapshot there is no census, but the leader is still
    -- unreaped and Kanban still made it this group's leader, so the id is
    -- still provably Kanban's and the group is still cleared. Losing `ps`
    -- costs the ability to notice an early exit, never the cleanup.
    it "kills a helper after a clean exit even when no process snapshot can be taken" $
      withPingRoot $ \root ->
        withEnvironmentValue pingModeVariable "orphan" $
          withFailingProcessSnapshot root $ do
            config <- refreshingConfig root
            result <- runPing (PingMode PingCodex False) config {resolvedTimeouts = timedTimeouts 2 2}
            helper <- helperPid root
            processAlive helper `shouldReturn` False
            -- Blind to the leader's exit, the deadline is what ends the wait.
            result.pingResultLaunch `shouldBe` PingTimedOut 2

    it "kills a helper after a timeout even when no process snapshot can be taken" $
      withPingRoot $ \root ->
        withEnvironmentValue pingModeVariable "orphan-hang" $
          withFailingProcessSnapshot root $ do
            config <- refreshingConfig root
            result <- runPing (PingMode PingCodex False) config {resolvedTimeouts = timedTimeouts 1 1}
            result.pingResultLaunch `shouldBe` PingTimedOut 1
            helper <- helperPid root
            processAlive helper `shouldReturn` False

    it "takes the whole group and nothing outside it" $
      ownedGroupMembers 500 mixedSnapshot
        `shouldBe` [ leader 500 "Thu Aug 15 10:00:00 2026",
                     member 501 500 "Thu Aug 15 10:00:01 2026"
                   ]

    -- The one thing that makes reading a group by its numeric id sound is
    -- that the leader is still unreaped, because that is what reserves the
    -- pid the id is named after. Once the handle is reaped the id could name
    -- anything, so the sweep must refuse rather than signal — even though
    -- refusing means leaving this helper running.
    it "refuses to signal a group whose leader has already been reaped" $
      withPingRoot $ \root -> do
        (handle, helper) <- spawnReapedGroupLeader root
        sweepOwnedGroup handle
        processAlive helper `shouldReturn` True
        signalProcess sigKILL helper

  describe "the configuration a ping runs under" $ do
    -- Requirement 11: a ping needs no checkout, but where repository context
    -- does exist its timeout override applies on the ordinary terms.
    it "applies the repository's ping override when an identity was established" $ do
      let resolved = pingResolvedConfig pingFixtureConfig (Just "coghex/kanban")
      resolved.resolvedTimeouts.timeoutsPingClaudeSeconds `shouldBe` 150
      pingTimeoutMicros PingClaude resolved `shouldBe` 150000000
      -- The key the repository table leaves unset still inherits the global.
      resolved.resolvedTimeouts.timeoutsPingCodexSeconds `shouldBe` 130

    it "falls back to the global table when no identity could be established" $ do
      let resolved = pingResolvedConfig pingFixtureConfig Nothing
      resolved.resolvedTimeouts.timeoutsPingClaudeSeconds `shouldBe` 140
      resolved.resolvedTimeouts.timeoutsPingCodexSeconds `shouldBe` 130
      pingTimeoutMicros PingClaude resolved `shouldBe` 140000000

    -- --repo names a repository outright. Resolving it the way the dashboard
    -- does would run `git rev-parse` first and fail here, silently dropping
    -- the override the user asked for — and running a ping from outside any
    -- checkout is exactly when the flag is worth having.
    it "honors an explicit --repo from a directory that is not a checkout" $ do
      outsideRepository <- createTemporaryDirectory
      identity <- pingRepositoryIdentity "origin" outsideRepository (Just "coghex/kanban")
      removePathForcibly outsideRepository
      identity `shouldBe` Right (Just "coghex/kanban")
      let resolved = pingResolvedConfig pingFixtureConfig (either (const Nothing) id identity)
      pingTimeoutMicros PingClaude resolved `shouldBe` 150000000

    it "accepts the GitHub URL forms --repo already takes" $ do
      outsideRepository <- createTemporaryDirectory
      identity <- pingRepositoryIdentity "origin" outsideRepository (Just "https://github.com/coghex/kanban")
      removePathForcibly outsideRepository
      identity `shouldBe` Right (Just "coghex/kanban")

    -- A missing checkout is not an error; an explicit argument that names no
    -- repository at all is a different thing and is reported rather than
    -- quietly ignored.
    it "establishes no identity outside a checkout when --repo was not given" $ do
      outsideRepository <- createTemporaryDirectory
      identity <- pingRepositoryIdentity "origin" outsideRepository Nothing
      removePathForcibly outsideRepository
      identity `shouldBe` Right Nothing

    it "reports a --repo that names no repository" $ do
      identity <- pingRepositoryIdentity "origin" "." (Just "not a repository")
      identity `shouldSatisfy` either (const True) (const False)

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
          -- A helper in the launched process group that outlives its leader,
          -- which is the survivor the sweep has to reach.
          "  orphan) sh -c 'sleep 30' & printf '%s' \"$!\" > \"" <> ByteString.pack (helperPidFile root) <> "\" ;;",
          "  orphan-hang) sh -c 'sleep 30' & printf '%s' \"$!\" > \"" <> ByteString.pack (helperPidFile root) <> "\"; sleep 30 ;;",
          -- A grandchild whose own parent exits immediately: it stays in the
          -- group with no surviving ancestor but the leader.
          "  chain) sh -c 'sh -c \"exec sleep 30\" & printf \"%s\" \"$!\" > \"" <> ByteString.pack (helperPidFile root) <> "\"' ; sleep 1 ;;",
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

-- | A process snapshot entry, in the shape 'Kanban.Process' parses from @ps@.
member :: Int -> Int -> Text -> ProcessIdentity
member pid groupPid startedAt =
  ProcessIdentity
    { processIdentityPid = pid,
      processIdentityParentPid = 1,
      processIdentityGroupPid = groupPid,
      processIdentityStartedAt = startedAt,
      processIdentityCommand = "provider"
    }

leader :: Int -> Text -> ProcessIdentity
leader pid = member pid pid

-- | The ping's group beside unrelated processes, including one whose own pid
-- matches the group's members but whose group is somebody else's.
mixedSnapshot :: [ProcessIdentity]
mixedSnapshot =
  [ leader 500 "Thu Aug 15 10:00:00 2026",
    member 501 500 "Thu Aug 15 10:00:01 2026",
    leader 700 "Thu Aug 15 10:00:02 2026",
    member 502 700 "Thu Aug 15 10:00:03 2026"
  ]

-- | Puts a @ps@ that refuses to answer ahead of the real one, so every process
-- snapshot fails the way it would on a machine whose @ps@ is unusable.
withFailingProcessSnapshot :: FilePath -> IO result -> IO result
withFailingProcessSnapshot root action = do
  let binaryRoot = root </> "bin"
  _ <- writeExecutableScript (binaryRoot </> "ps") ["echo 'ps is unavailable' >&2", "exit 1"]
  action

-- | A process group whose leader has been waited on, leaving a helper running
-- and the group id no longer provably Kanban's.
spawnReapedGroupLeader :: FilePath -> IO (ProcessHandle, ProcessID)
spawnReapedGroupLeader root = do
  script <-
    writeExecutableScript
      (root </> "reaped-leader.sh")
      [ByteString.pack ("sh -c 'exec sleep 30' & printf '%s' \"$!\" > \"" <> helperPidFile root <> "\"")]
  (_, _, _, handle) <-
    createProcess (proc script []) {std_in = NoStream, std_out = NoStream, std_err = NoStream, create_group = True}
  _ <- waitForProcess handle
  helper <- helperPid root
  pure (handle, helper)

-- | The shared full-file fixture, whose global block sets both ping timeouts
-- and whose @coghex/kanban@ table overrides only the Claude one.
pingFixtureConfig :: RawConfig
pingFixtureConfig = case decodeConfigText fullFixtureToml of
  Right (config, _) -> config
  Left message -> error ("ping fixture configuration did not decode: " <> Text.unpack message)

helperPidFile :: FilePath -> FilePath
helperPidFile root = root </> "helper.pid"

-- | The pid of the helper the fake forked into the launched process group.
-- Written by the fake before its leader exits, so it is there to read whether
-- the leader ended on its own or was terminated.
helperPid :: FilePath -> IO ProcessID
helperPid root = do
  waitForFileToExist (helperPidFile root) 50
  recorded <- readFile' (helperPidFile root)
  case readMaybe (filter (/= '\n') recorded) of
    Just pid -> pure (fromInteger pid)
    Nothing -> fail ("helper pid file did not hold a pid: " <> show recorded)

-- | Whether a pid still names a live process, asked the way the shell's
-- @kill -0@ does. A swept helper is killed and reaped by its new parent, so it
-- stops existing rather than lingering as a zombie this could mistake for
-- alive.
processAlive :: ProcessID -> IO Bool
processAlive pid = either (const False) (const True) <$> try @IOException (signalProcess nullSignal pid)

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
