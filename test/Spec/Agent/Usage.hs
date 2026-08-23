-- | Provider usage: decoding what Codex and Claude report, running the
-- configured external usage command, and refreshing what the board shows.
module Spec.Agent.Usage (spec) where

import Brick.BChan (newBChan, readBChan)
import qualified Data.ByteString.Char8 as ByteString
import Data.Text (Text)
import qualified Data.Text
import Data.Time (minutesToTimeZone)
import Kanban.Claude
  ( ScriptFlavor (..),
    claudeProbeArguments,
    decodeClaudeUsageText,
    fetchClaudeUsageWith,
    hostScriptFlavor,
    runClaudeProvider,
    runClaudeProviderWith,
    scriptFlavorFor,
    scriptFlavorLabel
  )
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
    ClaudeTranscript (..),
    ClaudeWrapperLifetime (..),
    withClaudeProbeFixture
  )
import Spec.Support.Env
  ( waitForFileToExist,
    withEnvironmentValue,
    withFakeOnPath,
    withTemporaryCacheRoot,
    writeExecutableScript
  )
import Spec.Support.Expect (isLeft, shouldMention, shouldNotMention)
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
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
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

  -- The probe's one BSD-userland assumption (issue #331). `script` is the
  -- only external executable Kanban composes differently per platform: the
  -- BSD form runs the trailing operands, while util-linux takes at most one
  -- file operand and needs `-c`, so the same argv there is a usage error
  -- rather than a usage probe. These assert the composed operands directly,
  -- because the fake `script` beside them answers to both dialects and so
  -- cannot fail on a wrong-flavor argv.
  describe "Claude usage probe script flavor" $ do
    it "selects the dialect from the platform alone -- darwin BSD, linux util-linux" $ do
      scriptFlavorFor "darwin" `shouldBe` BsdScript
      scriptFlavorFor "linux" `shouldBe` UtilLinuxScript

    it "composes the BSD operands macOS has always run" $
      claudeProbeArguments BsdScript "/opt/homebrew/bin/claude"
        `shouldBe` ["-q", "/dev/null", "/opt/homebrew/bin/claude", "--safe-mode", "--ax-screen-reader"]

    it "composes util-linux operands that carry one file operand and run claude through -c" $
      claudeProbeArguments UtilLinuxScript "/usr/bin/claude"
        `shouldBe` ["-q", "-c", "'/usr/bin/claude' '--safe-mode' '--ax-screen-reader'", "/dev/null"]

    -- util-linux runs its -c payload through a shell, so the resolved path
    -- is the one part of the probe an unlucky (or hostile) install location
    -- could turn into extra commands. The proof is the real shell's own
    -- argv, not the payload's spelling.
    it "keeps a shell-hostile executable path one literal word in the util-linux payload" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let hostileDirectory = temporaryRoot </> "b in; touch pwned"
            hostilePath = hostileDirectory </> "cl'aude"
            argumentLog = temporaryRoot </> "claude-argv"
        createDirectoryIfMissing True hostileDirectory
        _ <-
          writeExecutableScript
            hostilePath
            ["printf '%s\\n' \"$0\" \"$@\" > '" <> ByteString.pack argumentLog <> "'"]
        payload <- case claudeProbeArguments UtilLinuxScript hostilePath of
          ["-q", "-c", command, "/dev/null"] -> pure command
          other -> fail ("expected util-linux operands carrying one -c payload, got " <> show other)
        (_, _, _) <-
          readCreateProcessWithExitCode
            (proc "/bin/sh" ["-c", payload]) {cwd = Just temporaryRoot}
            ""
        recorded <- readFile argumentLog
        lines recorded `shouldBe` [hostilePath, "--safe-mode", "--ax-screen-reader"]
        -- The `; touch pwned` inside the directory name stayed data. A
        -- payload that concatenated the path unquoted would have run it,
        -- from the working directory set above.
        doesFileExist (temporaryRoot </> "pwned") `shouldReturn` False

    -- Requirement 3: a flavor mismatch has to be tellable apart from a
    -- missing executable, a timeout, or an unsupported screen -- which
    -- means the annotation names the dialect without flattening the kind
    -- the failing step reported.
    it "names the selected flavor on a missing claude, still as ExecutableMissing" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
        createDirectoryIfMissing True binaryRoot
        _ <- writeExecutableScript (binaryRoot </> "script") ["exit 0"]
        withEnvironmentValue "PATH" binaryRoot $ do
          result <- fetchClaudeUsageWith UtilLinuxScript 1000000
          case result of
            Left providerError -> do
              providerError.providerErrorKind `shouldBe` ExecutableMissing
              providerError.providerErrorMessage `shouldMention` "claude executable was not found"
              providerError.providerErrorMessage `shouldMention` "util-linux"
            Right snapshot -> expectationFailure ("expected a missing-executable failure, got " <> show snapshot)

    it "names the selected flavor on a missing script, still as ExecutableMissing" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let binaryRoot = temporaryRoot </> "bin"
        createDirectoryIfMissing True binaryRoot
        withEnvironmentValue "PATH" binaryRoot $ do
          result <- fetchClaudeUsageWith BsdScript 1000000
          case result of
            Left providerError -> do
              providerError.providerErrorKind `shouldBe` ExecutableMissing
              providerError.providerErrorMessage `shouldMention` "script executable was not found"
              providerError.providerErrorMessage `shouldMention` "BSD"
            Right snapshot -> expectationFailure ("expected a missing-executable failure, got " <> show snapshot)

    -- Driven through the util-linux operands on whichever host runs the
    -- suite, so the -c payload is launched for real on macOS too.
    it "names the selected flavor on a signed-out client, still as AuthenticationRequired" $
      withClaudeProbeFixture True WrapperWaitsForClaude ClaudeExitsCleanly AuthenticationFailureTranscript $ \fixture -> do
        result <- timeout 20000000 (runClaudeProviderWith UtilLinuxScript 8000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> do
            providerError.providerErrorKind `shouldBe` AuthenticationRequired
            providerError.providerErrorMessage `shouldMention` "util-linux"
            providerError.providerErrorMessage `shouldNotMention` "BSD"
          other -> expectationFailure ("expected an authentication failure, got " <> show other)

    it "names the selected flavor on an unrecognized /usage screen, still as UnsupportedVersion" $
      withClaudeProbeFixture True WrapperWaitsForClaude ClaudeExitsCleanly MissingWeeklyWindowTranscript $ \fixture -> do
        result <- timeout 20000000 (runClaudeProviderWith BsdScript 8000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> do
            providerError.providerErrorKind `shouldBe` UnsupportedVersion
            providerError.providerErrorMessage `shouldMention` "BSD"
            providerError.providerErrorMessage `shouldNotMention` "util-linux"
          other -> expectationFailure ("expected an unsupported-version failure, got " <> show other)

  describe "Claude usage probe termination" $ do
    it "decodes a clean-exiting probe's usage without ever needing TERM or KILL" $
      -- separateGroup=True so the wrapper's background job keeps its real
      -- stdin (bash redirects a backgrounded job's stdin to /dev/null unless
      -- job control put it in its own process group) -- the fake claude
      -- child needs the actual bytes Kanban writes to know when to exit.
      -- The descendant exits on its own once it has drained them, so
      -- escalation never needs to signal anyone.
      withClaudeProbeFixture True WrapperWaitsForClaude ClaudeExitsCleanly CompleteUsageTranscript $ \fixture -> do
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
      withClaudeProbeFixture True WrapperWaitsForClaude ClaudeIgnoresInterrupt NoTranscript $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 8000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> do
            providerError.providerErrorKind `shouldBe` RequestTimedOut
            -- Whichever dialect this host composed, the timeout still reads
            -- as a timeout and still says which operands produced it.
            providerError.providerErrorMessage `shouldMention` scriptFlavorLabel hostScriptFlavor
          other -> expectationFailure ("expected a clean timeout, got " <> show other)
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"
        -- Confirms escalation actually reached TERM for the child, rather
        -- than the assertions above passing for some unrelated reason.
        doesFileExist fixture.claudeProbeTermMarker `shouldReturn` True

    it "kills an INT-resistant claude child that still shares the wrapper's own process group" $
      withClaudeProbeFixture False WrapperWaitsForClaude ClaudeIgnoresInterrupt NoTranscript $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 8000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
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
      withClaudeProbeFixture True WrapperWaitsForClaude ClaudeIgnoresInterruptAndTerminate CompleteUsageTranscript $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 8000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> do
            providerError.providerErrorKind `shouldBe` RequestFailed
            providerError.providerErrorMessage `shouldMention` "forced kill"
            providerError.providerErrorMessage `shouldMention` scriptFlavorLabel hostScriptFlavor
          other -> expectationFailure ("expected a forced-kill failure, got " <> show other)
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"

    it "sweeps a reparented, separate-group claude child after the pseudo-terminal breaks under the clean-exit write" $
      -- The one return path the census-aware cleanup used not to cover. The
      -- wrapper emits a complete /usage screen and then leaves mid-session,
      -- so Kanban's ESC + "/exit" write raises a broken pipe while the claude
      -- child it launched is still alive in a process group of its own.
      -- 'withCreateProcess' reaps the wrapper it spawned and knows nothing
      -- about that child, so nothing else in the probe would sweep it: the
      -- census the escalation needs can only have been taken earlier, while
      -- the wrapper was still there to be walked through.
      withClaudeProbeFixture True WrapperExitsMidSession ClaudeIgnoresInterrupt CompleteUsageTranscript $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 8000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> do
            -- An I/O failure, classified and annotated exactly as every other
            -- probe failure is -- not a timeout, and never a snapshot decoded
            -- out of the transcript it did manage to capture.
            providerError.providerErrorKind `shouldBe` RequestFailed
            providerError.providerErrorMessage `shouldMention` scriptFlavorLabel hostScriptFlavor
          other -> expectationFailure ("expected a bounded request failure, got " <> show other)
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"
        -- Confirms the escalation reached the reparented child, rather than
        -- the sweep assertion above passing because it had exited anyway.
        doesFileExist fixture.claudeProbeTermMarker `shouldReturn` True

    it "still sweeps that child when the wrapper leaves as soon as the client is up" $
      -- The same failure, with the wrapper gone a fraction of a second after
      -- the client it launched came up rather than after a stretch of the
      -- session. Censusing the tree only once the capture is already driving
      -- the pseudo-terminal -- or, as the bug did, only once the write has
      -- failed -- is too late by then: the wrapper has gone, the child is
      -- reparented, and walking down from the wrapper's pid reaches nothing,
      -- so cleanup would escalate against a census that pins nothing below
      -- the wrapper and signal nobody.
      withClaudeProbeFixture True WrapperExitsAtStartup ClaudeIgnoresInterrupt CompleteUsageTranscript $ \fixture -> do
        result <- timeout 20000000 (runClaudeProvider 8000000 fixture.claudeProbeScriptPath fixture.claudeProbeClaudePath)
        case result of
          Just (Left providerError) -> do
            providerError.providerErrorKind `shouldBe` RequestFailed
            providerError.providerErrorMessage `shouldMention` scriptFlavorLabel hostScriptFlavor
          other -> expectationFailure ("expected a bounded request failure, got " <> show other)
        shouldRecordASweptProcess fixture.claudeProbeScriptMarker "the script wrapper"
        shouldRecordASweptProcess fixture.claudeProbeChildMarker "the claude child"
        doesFileExist fixture.claudeProbeTermMarker `shouldReturn` True

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
