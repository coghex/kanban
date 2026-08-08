-- | Provider usage: decoding what Codex and Claude report, running the
-- configured external usage command, and refreshing what the board shows.
module Spec.Agent.Usage (spec) where

import Brick.BChan (newBChan, readBChan)
import qualified Data.ByteString.Char8 as ByteString
import Data.Text (Text)
import qualified Data.Text
import Data.Time (minutesToTimeZone)
import Kanban.Claude (decodeClaudeUsageText, runClaudeProvider)
import Kanban.Codex (decodeCodexUsageResponse)
import Kanban.Config
import Kanban.Domain
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.UI.Refresh (runClaudeRefresh, runCodexRefresh)
import Kanban.UI.Types (AppEvent (..))
import Kanban.UsageCommand (decodeUsageCommandDocument, runUsageCommand)
import Spec.Support.ClaudeProbe
  ( ClaudeProbeFixture (..),
    ClaudeSignalPolicy (..),
    withClaudeProbeFixture
  )
import Spec.Support.Env
  ( waitForFileToExist,
    withEnvironmentValue,
    withFakeOnPath,
    withTemporaryCacheRoot,
    writeExecutableScript
  )
import Spec.Support.Expect (isLeft, shouldMention)
import Spec.Support.Fixtures (epoch)
import Spec.Support.Json (claudeUsageOutput, codexRateLimitResponse, codexWeeklyOnlyResponse)
import Spec.Support.Process (shouldRecordASweptProcess)
import System.Directory
  ( XdgDirectory (XdgCache),
    canonicalizePath,
    createDirectoryIfMissing,
    doesFileExist,
    getXdgDirectory
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = do
  describe "Codex app-server decoding" $ do
    it "maps returned windows by duration and computes percentage left" $ do
      case decodeCodexUsageResponse epoch codexRateLimitResponse of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> do
          map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour", "week"]
          map (.usagePercentLeft) snapshot.usageWindows `shouldBe` [78, 59]
          snapshot.usageFetchedAt `shouldBe` epoch

    it "accepts an account that currently exposes only a weekly window" $ do
      case decodeCodexUsageResponse epoch codexWeeklyOnlyResponse of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["week"]

  describe "Claude /usage decoding" $ do
    it "selects the last complete screen-reader update" $ do
      case decodeClaudeUsageText (minutesToTimeZone (-420)) epoch claudeUsageOutput of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> do
          map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour", "week"]
          map (.usagePercentLeft) snapshot.usageWindows `shouldBe` [79, 86]

    it "fails closed when the interactive usage request fails" $
      decodeClaudeUsageText (minutesToTimeZone (-420)) epoch "Current session\nFailed to load usage data"
        `shouldSatisfy` isLeft

  describe "Claude usage probe termination" $ do
    it "decodes a clean-exiting probe's usage without ever needing TERM or KILL" $
      -- separateGroup=True so the wrapper's background job keeps its real
      -- stdin (bash redirects a backgrounded job's stdin to /dev/null unless
      -- job control put it in its own process group) -- the fake claude
      -- child needs the actual bytes Kanban writes to know when to exit.
      -- The descendant exits on its own once it has drained them, so
      -- escalation never needs to signal anyone.
      withClaudeProbeFixture True ClaudeExitsCleanly True $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 8000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Nothing -> expectationFailure "expected the clean-exit probe to return well within its bound"
          Just (Left providerError) -> expectationFailure ("expected a decoded snapshot, got " <> show providerError)
          Just (Right snapshot) -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour", "week"]
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"
        doesFileExist fixture.claudeProbeTermMarker `shouldReturn` False

    it "kills a reaped wrapper's INT-resistant claude child even though a pty gave it a separate session" $
      -- The wrapper has no INT handler of its own and dies immediately, well
      -- before the claude child (which ignores INT, in its own process
      -- group) does -- exactly the "leader reaped, descendant survives"
      -- shape 'script''s pty produces in production.
      withClaudeProbeFixture True ClaudeIgnoresInterrupt False $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 1000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> providerError.providerErrorKind `shouldBe` RequestTimedOut
          other -> expectationFailure ("expected a clean timeout, got " <> show other)
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"
        -- Confirms escalation actually reached TERM for the child, rather
        -- than the assertions above passing for some unrelated reason.
        doesFileExist fixture.claudeProbeTermMarker `shouldReturn` True

    it "kills an INT-resistant claude child that still shares the wrapper's own process group" $
      withClaudeProbeFixture False ClaudeIgnoresInterrupt False $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 1000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> providerError.providerErrorKind `shouldBe` RequestTimedOut
          other -> expectationFailure ("expected a clean timeout, got " <> show other)
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"
        doesFileExist fixture.claudeProbeTermMarker `shouldReturn` True

    it "reports a forced-kill failure instead of a decoded snapshot when a captured probe refuses TERM and needs SIGKILL" $
      -- Valid /usage was already captured -- the transcript decodes cleanly
      -- on its own -- but the claude child ignores both INT and TERM, so
      -- only SIGKILL ends it; the provider must report that as a failure
      -- rather than silently decode the snapshot it already has.
      withClaudeProbeFixture True ClaudeIgnoresInterruptAndTerminate True $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 8000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> do
            providerError.providerErrorKind `shouldBe` RequestFailed
            providerError.providerErrorMessage `shouldMention` "forced kill"
          other -> expectationFailure ("expected a forced-kill failure, got " <> show other)
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"

  describe "external usage-command document decoding" $ do
    it "decodes windows using the refresh clock rather than any document timestamp" $
      case decodeUsageCommandDocument epoch "{\"windows\":[{\"label\":\"5 hour\",\"pct_left\":78,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}" of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> do
          map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour"]
          map (.usagePercentLeft) snapshot.usageWindows `shouldBe` [78]
          snapshot.usageFetchedAt `shouldBe` epoch

    it "decodes every window in a multi-window document, in document order" $
      case decodeUsageCommandDocument epoch "{\"windows\":[{\"label\":\"5 hour\",\"pct_left\":78,\"resets_at\":\"2026-07-16T16:05:00Z\"},{\"label\":\"week\",\"pct_left\":41,\"resets_at\":\"2026-07-20T09:00:00Z\"}]}" of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour", "week"]

    it "rejects an empty windows array as unsupported rather than an empty snapshot" $
      case decodeUsageCommandDocument epoch "{\"windows\":[]}" of
        Left providerError -> providerError.providerErrorKind `shouldBe` UnsupportedVersion
        Right snapshot -> expectationFailure ("expected a decode failure, got " <> show snapshot)

    it "rejects malformed JSON as unsupported" $
      case decodeUsageCommandDocument epoch "not json" of
        Left providerError -> providerError.providerErrorKind `shouldBe` UnsupportedVersion
        Right snapshot -> expectationFailure ("expected a decode failure, got " <> show snapshot)

    it "rejects a pct_left outside 0-100" $
      case decodeUsageCommandDocument epoch "{\"windows\":[{\"label\":\"5 hour\",\"pct_left\":140,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}" of
        Left providerError -> providerError.providerErrorKind `shouldBe` UnsupportedVersion
        Right snapshot -> expectationFailure ("expected a decode failure, got " <> show snapshot)

    it "rejects an empty label" $
      case decodeUsageCommandDocument epoch "{\"windows\":[{\"label\":\"\",\"pct_left\":50,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}" of
        Left providerError -> providerError.providerErrorKind `shouldBe` UnsupportedVersion
        Right snapshot -> expectationFailure ("expected a decode failure, got " <> show snapshot)

    it "rejects a resets_at that is not ISO-8601 UTC" $
      case decodeUsageCommandDocument epoch "{\"windows\":[{\"label\":\"5 hour\",\"pct_left\":50,\"resets_at\":\"not-a-date\"}]}" of
        Left providerError -> providerError.providerErrorKind `shouldBe` UnsupportedVersion
        Right snapshot -> expectationFailure ("expected a decode failure, got " <> show snapshot)

    it "sanitizes a hostile label -- ANSI escape sequences reaching an arbitrary external command's stdout -- before it can reach the sidebar" $
      case decodeUsageCommandDocument epoch "{\"windows\":[{\"label\":\"\\u001b[31mALERT\\u001b[0m\",\"pct_left\":50,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}" of
        Left providerError -> expectationFailure (show providerError)
        Right snapshot -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["ALERT"]

    it "rejects a label that sanitizes down to nothing but control sequences" $
      case decodeUsageCommandDocument epoch "{\"windows\":[{\"label\":\"\\u001b[31m\\u001b[0m\",\"pct_left\":50,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}" of
        Left providerError -> providerError.providerErrorKind `shouldBe` UnsupportedVersion
        Right snapshot -> expectationFailure ("expected a decode failure, got " <> show snapshot)

  describe "external usage-command execution" $ do
    it "runs the configured argv directly and passes shell metacharacters through as a literal argument" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        scriptPath <-
          writeExecutableScript
            (temporaryRoot </> "usage-command.sh")
            ["printf '%s' '{\"windows\":[{\"label\":\"'\"$1\"'\",\"pct_left\":78,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}'"]
        let literalArgument = "5 hour; $(touch pwned) & | * ? ~ #" :: Text
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          result <- timeout 5000000 (runUsageCommand 3000000 [Data.Text.pack scriptPath, literalArgument])
          case result of
            Just (Right snapshot) -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` [literalArgument]
            other -> expectationFailure ("expected a decoded snapshot echoing the literal argument, got " <> show other)

    it "resolves a bare executable name via PATH like any other launched command" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeOnPath
          temporaryRoot
          ("kanban-usage-fixture", ["printf '%s' '{\"windows\":[{\"label\":\"5 hour\",\"pct_left\":78,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}'"])
          ( withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
              result <- timeout 5000000 (runUsageCommand 3000000 ["kanban-usage-fixture"])
              case result of
                Just (Right snapshot) -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour"]
                other -> expectationFailure ("expected PATH resolution to find the fixture, got " <> show other)
          )

    it "gives the command closed stdin rather than leaving it open to block on" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        scriptPath <-
          writeExecutableScript
            (temporaryRoot </> "usage-command.sh")
            [ "if read -r line; then",
              "  printf '%s' '{\"windows\":[{\"label\":\"got-input\",\"pct_left\":1,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}'",
              "else",
              "  printf '%s' '{\"windows\":[{\"label\":\"eof\",\"pct_left\":99,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}'",
              "fi"
            ]
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          result <- timeout 5000000 (runUsageCommand 3000000 [Data.Text.pack scriptPath])
          case result of
            Just (Right snapshot) -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["eof"]
            other -> expectationFailure ("expected the command to see immediate EOF on stdin, got " <> show other)

    it "runs from a stable application-owned scratch directory rather than the caller's own working directory" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        scriptPath <-
          writeExecutableScript
            (temporaryRoot </> "usage-command.sh")
            ["printf '%s' '{\"windows\":[{\"label\":\"'\"$PWD\"'\",\"pct_left\":1,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}'"]
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          result <- timeout 5000000 (runUsageCommand 3000000 [Data.Text.pack scriptPath])
          cacheRoot <- getXdgDirectory XdgCache "kanban"
          -- Resolved against the same symlinks the shell's own $PWD already
          -- reports (e.g. macOS's /var -> /private/var), so this compares
          -- the same notion of "where it ran" on both sides.
          expectedScratch <- canonicalizePath (cacheRoot </> "usage-command")
          case result of
            Just (Right snapshot) -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` [Data.Text.pack expectedScratch]
            other -> expectationFailure ("expected the command to run from the scratch directory, got " <> show other)

    it "fails closed as unsupported when the command's stdout is not the documented JSON" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        scriptPath <- writeExecutableScript (temporaryRoot </> "usage-command.sh") ["printf '%s' 'not json'"]
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          result <- timeout 5000000 (runUsageCommand 3000000 [Data.Text.pack scriptPath])
          case result of
            Just (Left providerError) -> providerError.providerErrorKind `shouldBe` UnsupportedVersion
            other -> expectationFailure ("expected an unsupported-version error, got " <> show other)

    it "reports a nonzero exit as a request error even when stdout carries valid JSON" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        scriptPath <-
          writeExecutableScript
            (temporaryRoot </> "usage-command.sh")
            [ "printf '%s' '{\"windows\":[{\"label\":\"5 hour\",\"pct_left\":78,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}'",
              "exit 3"
            ]
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          result <- timeout 5000000 (runUsageCommand 3000000 [Data.Text.pack scriptPath])
          case result of
            Just (Left providerError) -> do
              providerError.providerErrorKind `shouldBe` RequestFailed
              providerError.providerErrorMessage `shouldMention` "3"
            other -> expectationFailure ("expected a request-failed error, got " <> show other)

    it "reports a missing executable as not installed" $ do
      result <- timeout 5000000 (runUsageCommand 3000000 ["/nonexistent/kanban-usage-command-fixture"])
      case result of
        Just (Left providerError) -> providerError.providerErrorKind `shouldBe` ExecutableMissing
        other -> expectationFailure ("expected a not-installed error, got " <> show other)

    it "reports an unconfigured (empty) command as not installed rather than crashing" $ do
      result <- timeout 5000000 (runUsageCommand 3000000 [])
      case result of
        Just (Left providerError) -> providerError.providerErrorKind `shouldBe` ExecutableMissing
        other -> expectationFailure ("expected a not-installed error, got " <> show other)

    it "reports a scratch-directory setup failure as a request error rather than escaping the caller" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let unwritableCacheRoot = temporaryRoot </> "cache-is-a-file"
        ByteString.writeFile unwritableCacheRoot "not a directory"
        withEnvironmentValue "XDG_CACHE_HOME" unwritableCacheRoot $ do
          result <- timeout 5000000 (runUsageCommand 3000000 ["irrelevant-because-setup-fails-first"])
          case result of
            Just (Left providerError) -> providerError.providerErrorKind `shouldBe` RequestFailed
            other -> expectationFailure ("expected a request-failed error, got " <> show other)

    it "times out a sleeping command and confirms its process group is gone" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let markerPath = temporaryRoot </> "usage-command.pid"
        scriptPath <-
          writeExecutableScript
            (temporaryRoot </> "usage-command.sh")
            [ByteString.pack ("echo $$ > " <> markerPath), "sleep 60 </dev/null >/dev/null 2>&1"]
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          result <- timeout 10000000 (runUsageCommand 3000000 [Data.Text.pack scriptPath])
          case result of
            Just (Left providerError) -> providerError.providerErrorKind `shouldBe` RequestTimedOut
            other -> expectationFailure ("expected a clean timeout, got " <> show other)
        shouldRecordASweptProcess markerPath "the sleeping usage command"

    it "escalates to SIGKILL when the timed-out command ignores TERM" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let markerPath = temporaryRoot </> "usage-command.pid"
        scriptPath <-
          writeExecutableScript
            (temporaryRoot </> "usage-command.sh")
            ["trap '' TERM", ByteString.pack ("echo $$ > " <> markerPath), "sleep 60 </dev/null >/dev/null 2>&1"]
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          result <- timeout 10000000 (runUsageCommand 3000000 [Data.Text.pack scriptPath])
          case result of
            Just (Left providerError) -> providerError.providerErrorKind `shouldBe` RequestTimedOut
            other -> expectationFailure ("expected a clean timeout, got " <> show other)
        shouldRecordASweptProcess markerPath "the TERM-resistant usage command"

    it "sweeps a same-group descendant left behind after the direct process exits cleanly" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let markerPath = temporaryRoot </> "usage-command-child.pid"
        scriptPath <-
          writeExecutableScript
            (temporaryRoot </> "usage-command.sh")
            [ ByteString.pack ("sh -c 'echo $$ > " <> markerPath <> "; sleep 60' </dev/null >/dev/null 2>&1 &"),
              "printf '%s' '{\"windows\":[{\"label\":\"5 hour\",\"pct_left\":78,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}'"
            ]
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          result <- timeout 10000000 (runUsageCommand 3000000 [Data.Text.pack scriptPath])
          case result of
            Just (Right snapshot) -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour"]
            other -> expectationFailure ("expected a decoded snapshot, got " <> show other)
        waitForFileToExist markerPath 50
        shouldRecordASweptProcess markerPath "the descendant left behind"

  describe "usage refresh routing" $ do
    it "runs the configured Codex command instead of the built-in probe" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
            sentinelMarker = temporaryRoot </> "builtin-codex-invoked"
        createDirectoryIfMissing True binaryRoot
        _ <- writeExecutableScript (binaryRoot </> "codex") [ByteString.pack ("touch " <> sentinelMarker), "exit 1"]
        commandScriptPath <-
          writeExecutableScript
            (temporaryRoot </> "usage-command.sh")
            ["printf '%s' '{\"windows\":[{\"label\":\"5 hour\",\"pct_left\":78,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}'"]
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            eventChannel <- newBChan 4
            runCodexRefresh 3000000 (Just (UsageCommandConfig [Data.Text.pack commandScriptPath])) eventChannel
            event <- readBChan eventChannel
            case event of
              CodexRefreshFinished (Right snapshot) -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour"]
              CodexRefreshFinished (Left providerError) -> expectationFailure ("expected a decoded snapshot from the configured command, got " <> show providerError)
              _ -> expectationFailure "expected a CodexRefreshFinished event"
        doesFileExist sentinelMarker `shouldReturn` False

    it "runs the configured Claude command instead of the built-in probe" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
            sentinelMarker = temporaryRoot </> "builtin-claude-invoked"
        createDirectoryIfMissing True binaryRoot
        _ <- writeExecutableScript (binaryRoot </> "claude") [ByteString.pack ("touch " <> sentinelMarker), "exit 1"]
        commandScriptPath <-
          writeExecutableScript
            (temporaryRoot </> "usage-command.sh")
            ["printf '%s' '{\"windows\":[{\"label\":\"5 hour\",\"pct_left\":78,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}'"]
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $
          withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
            eventChannel <- newBChan 4
            runClaudeRefresh 3000000 (Just (UsageCommandConfig [Data.Text.pack commandScriptPath])) eventChannel
            event <- readBChan eventChannel
            case event of
              ClaudeRefreshFinished (Right snapshot) -> map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour"]
              ClaudeRefreshFinished (Left providerError) -> expectationFailure ("expected a decoded snapshot from the configured command, got " <> show providerError)
              _ -> expectationFailure "expected a ClaudeRefreshFinished event"
        doesFileExist sentinelMarker `shouldReturn` False

    it "keeps one provider's external-command failure from affecting the other" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        failingScriptPath <- writeExecutableScript (temporaryRoot </> "usage-command-failing.sh") ["printf '%s' 'not json'"]
        succeedingScriptPath <-
          writeExecutableScript
            (temporaryRoot </> "usage-command-succeeding.sh")
            ["printf '%s' '{\"windows\":[{\"label\":\"5 hour\",\"pct_left\":78,\"resets_at\":\"2026-07-16T16:05:00Z\"}]}'"]
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          eventChannel <- newBChan 4
          runCodexRefresh 3000000 (Just (UsageCommandConfig [Data.Text.pack failingScriptPath])) eventChannel
          runClaudeRefresh 3000000 (Just (UsageCommandConfig [Data.Text.pack succeedingScriptPath])) eventChannel
          firstEvent <- readBChan eventChannel
          secondEvent <- readBChan eventChannel
          case (firstEvent, secondEvent) of
            (CodexRefreshFinished (Left providerError), ClaudeRefreshFinished (Right snapshot)) -> do
              providerError.providerErrorKind `shouldBe` UnsupportedVersion
              map (.usageWindowLabel) snapshot.usageWindows `shouldBe` ["5 hour"]
            _ -> expectationFailure "expected an independent Codex failure and Claude success"
