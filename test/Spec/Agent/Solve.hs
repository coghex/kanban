-- | The solve workflow's process protocol.
module Spec.Agent.Solve (spec) where

import Control.Exception (throwIO)
import qualified Data.ByteString.Char8 as ByteString
import Data.Char (isControl)
import Data.IORef (modifyIORef, newIORef, readIORef, writeIORef)
import Data.List (findIndex, sort)
import qualified Data.Text
import Kanban.Domain
import Kanban.Process
  ( identityForPid,
    killManagedProcess,
    managedProcessPid,
    matchingIdentities,
    readProcessSnapshot
  )
import Kanban.Settings (ChatVerbosity (..))
import Kanban.Solve
  ( AgentEvent (..),
    ResumeProvenance (..),
    SolveEvent (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    StreamEvent (..),
    maxUnknownNoticeLength,
    newUnknownAggregator,
    parseSolveOutputLine,
    renderAgentEvent,
    resumeProvenanceHeader,
    runSolve,
    runSolveWith,
    solveArguments,
    unknownNoticeSamples
  )
import Kanban.StreamReader (handleReadLine)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Process
  ( aggregatedNotices,
    chattyProvider,
    chattyProviderLines,
    isSolveOutputEvent,
    isSolveSessionIdentifiedEvent,
    rawTelemetryLines,
    singleNotice
  )
import System.Directory (createDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = do
  describe "solve process protocol" $ do
    it "launches each solver with its pinned model and effort, including the separately constructed Codex resume branch" $ do
      let codexArguments = solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer ""
          claudeArguments = solveArguments 844 SolveOnly ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer ""
          codexResumeArguments = solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeAnswer "pick option B"
      codexArguments `shouldContain` ["--model", "gpt-5.4"]
      codexArguments `shouldContain` ["model_reasoning_effort=\"high\""]
      codexArguments `shouldContain` ["model_reasoning_summary=\"detailed\""]
      claudeArguments `shouldContain` ["--model", "claude-sonnet-5"]
      claudeArguments `shouldContain` ["--effort", "high"]
      codexResumeArguments `shouldContain` ["--model", "gpt-5.4"]
      codexResumeArguments `shouldContain` ["model_reasoning_effort=\"high\""]
      codexResumeArguments `shouldContain` ["model_reasoning_summary=\"detailed\""]
      codexResumeArguments `shouldContain` ["approval_policy=\"never\""]

    it "runs the ordinary solve command for both S and Kanban-owned A orchestration" $ do
      let codexSolvePrompt = last (solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          codexAutoSolvePrompt = last (solveArguments 844 AutoSolve CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          claudeSolvePrompt = last (solveArguments 844 SolveOnly ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          claudeAutoSolvePrompt = last (solveArguments 844 AutoSolve ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      codexSolvePrompt `shouldContain` "$solve"
      codexAutoSolvePrompt `shouldContain` "$solve"
      codexAutoSolvePrompt `shouldNotContain` "$autosolve"
      codexAutoSolvePrompt `shouldContain` "Kanban owns the bounded review/fix loop"
      claudeSolvePrompt `shouldContain` "/solve"
      claudeAutoSolvePrompt `shouldContain` "/solve"
      claudeAutoSolvePrompt `shouldNotContain` "/autosolve"
      codexSolvePrompt `shouldContain` "Do not run issue-review"

    it "passes a configured --config path through to the read-only gate-check instruction" $ do
      let promptWithConfig = last (solveArguments 844 SolveOnly CodexSolver (Just "/tmp/kanban/custom.toml") (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          promptWithoutConfig = last (solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      promptWithConfig `shouldContain` "Pass --config /tmp/kanban/custom.toml to the read-only v2 gate check"
      promptWithoutConfig `shouldNotContain` "Pass --config"

    it "always passes Kanban's own resolved --repo to the read-only gate-check instruction, even without a fork override" $ do
      let forkRepository = Repository "/tmp/fork" "upstream-owner" "upstream-repo"
          forkPrompt = last (solveArguments 844 SolveOnly CodexSolver Nothing forkRepository defaultWorkflowConfig Nothing ResumeAnswer "")
      forkPrompt `shouldContain` "Pass --repo upstream-owner/upstream-repo to the read-only v2 gate check"

    it "recovers an interrupted same-issue worktree instead of treating it as a collision" $ do
      -- Short distinguishing substrings rather than whole sentences, so this
      -- fails when the underlying instruction is lost or reversed but not on
      -- an unrelated copy edit to the surrounding prose.
      let solvePrompt = last (solveArguments 782 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      solvePrompt `shouldContain` "issue #782"
      solvePrompt `shouldContain` "not a collision"
      solvePrompt `shouldContain` "inspect `git status`"
      solvePrompt `shouldContain` "Do not discard, reset, or overwrite"
      solvePrompt `shouldContain` "when no same-issue worktree exists"

    it "frames a resumed solve prompt with the true provenance of the resumed message instead of always claiming a user answer" $ do
      let answerPrompt = last (solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeAnswer "pick option B")
          interruptPrompt = last (solveArguments 844 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeInterruptGuidance "focus on the other file instead")
          automatedPrompt = last (solveArguments 844 AutoSolve CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeAutomatedChangesRequested "Kanban received CHANGES_REQUESTED for PR #900")
      answerPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeAnswer)
      answerPrompt `shouldContain` "KANBAN_NEEDS_INPUT"
      interruptPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeInterruptGuidance)
      interruptPrompt `shouldNotContain` "The user answered"
      interruptPrompt `shouldContain` "KANBAN_NEEDS_INPUT"
      automatedPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeAutomatedChangesRequested)
      automatedPrompt `shouldNotContain` "The user answered"
      automatedPrompt `shouldContain` "KANBAN_NEEDS_INPUT"

    it "names the configured changes-requested label in the automated resume header instead of the literal default" $ do
      let customConfig = defaultWorkflowConfig {changesRequestedLabel = "needs-work"}
          customAutomatedPrompt = last (solveArguments 844 AutoSolve CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") customConfig (Just "session-1") ResumeAutomatedChangesRequested "Kanban received CHANGES_REQUESTED for PR #900")
      customAutomatedPrompt `shouldContain` "the PR received needs-work"
      customAutomatedPrompt `shouldNotContain` "the PR received reviewed:changes"

    it "extracts Codex session ids and readable agent output" $ do
      parseSolveOutputLine "{\"type\":\"thread.started\",\"thread_id\":\"019f-session\"}"
        `shouldBe` Right (Just "019f-session", [])
      parseSolveOutputLine "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #42\"}}"
        `shouldBe` Right (Nothing, [StreamEvent Nothing (AgentEvent "message" "Created PR #42" "" (Just "Created PR #42"))])

    it "extracts Claude session ids and assistant text" $ do
      parseSolveOutputLine "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"claude-session\"}"
        `shouldBe` Right (Just "claude-session", [])
      parseSolveOutputLine "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Working in issue-42\"}]}}"
        `shouldBe` Right (Nothing, [StreamEvent Nothing (AgentEvent "message" "Working in issue-42" "" (Just "Working in issue-42"))])

    it "promotes Claude Bash tools to visible running commands while retaining full input" $ do
      let toolLine = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git status --short\"}}]}}"
      case parseSolveOutputLine toolLine of
        Right (_, [streamEvent]) -> do
          let agentEvent = streamEvent.streamEventAgent
          agentEvent.agentEventKind `shouldBe` "command"
          renderAgentEvent CompactChat agentEvent `shouldBe` Just "[command] git status --short"
          renderAgentEvent StandardChat agentEvent `shouldSatisfy` maybe False (Data.Text.isInfixOf "git status --short")
          renderAgentEvent FullChat agentEvent `shouldSatisfy` maybe False (Data.Text.isInfixOf "command")
        result -> expectationFailure ("unexpected parsed tool event: " <> show result)

    it "bounds every unrecognized payload to a single-line notice instead of embedding its whole JSON" $ do
      -- One chatty unrecognized type per parser fallback, each carrying a
      -- payload far larger than the notice budget.
      let blob = Data.Text.replicate 400 "0123456789"
          topLevel = "{\"type\":\"telemetry\",\"blob\":\"" <> Data.Text.unpack blob <> "\"}"
          item = "{\"type\":\"item.completed\",\"item\":{\"type\":\"heartbeat\",\"blob\":\"" <> Data.Text.unpack blob <> "\"}}"
          content = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"telemetry_delta\",\"blob\":\"" <> Data.Text.unpack blob <> "\"}]}}"
      notices <- traverse (\(line, tag) -> (,) tag <$> singleNotice (ByteString.pack line)) [(topLevel, "[event] telemetry"), (item, "[item] heartbeat"), (content, "[content] telemetry_delta")]
      mapM_
        ( \(tag, agentEvent) -> do
            let summary = agentEvent.agentEventSummary
            summary `shouldSatisfy` Data.Text.isPrefixOf tag
            Data.Text.length summary `shouldSatisfy` (<= maxUnknownNoticeLength)
            Data.Text.lines summary `shouldSatisfy` ((== 1) . length)
            -- A prefix of the payload is kept for diagnosis; the payload
            -- itself never is.
            summary `shouldSatisfy` Data.Text.isInfixOf "0123456789"
            summary `shouldNotSatisfy` Data.Text.isInfixOf blob
            -- The detail lives inside the one-line summary, so even the Full
            -- rendering (which would otherwise indent a detail onto its own
            -- lines) stays one bounded line.
            agentEvent.agentEventDetail `shouldBe` ""
            case renderAgentEvent FullChat agentEvent of
              Nothing -> expectationFailure "expected the Full rendering to keep the unknown notice"
              Just rendered -> do
                rendered `shouldBe` summary
                Data.Text.length rendered `shouldSatisfy` (<= maxUnknownNoticeLength)
        )
        notices

    it "gives a missing, non-string, blank, multi-line, or overlong type a bounded one-line label" $ do
      -- Every shape of unusable or hostile 'type' across all three
      -- fallbacks. None may escape the whole-notice bound or the one-line
      -- rule, and none may be dropped.
      let payloads =
            [ "{\"detail\":\"no type at all\"}",
              "{\"type\":42,\"detail\":\"numeric type\"}",
              "{\"type\":{\"nested\":\"object\"},\"detail\":\"object type\"}",
              "{\"type\":[\"array\"],\"detail\":\"array type\"}",
              "{\"type\":\"   \",\"detail\":\"blank type\"}",
              "{\"type\":\"first\\nsecond\\rthird\\ttab\",\"detail\":\"multi-line type\"}",
              "{\"type\":\"bell\\u0007bidi\\u202e\",\"detail\":\"control type\"}",
              "{\"type\":\"" <> replicate 500 'z' <> "\",\"detail\":\"overlong type\"}"
            ]
          wrapped payload =
            [ ByteString.pack payload,
              ByteString.pack ("{\"type\":\"item.completed\",\"item\":" <> payload <> "}"),
              ByteString.pack ("{\"type\":\"assistant\",\"message\":{\"content\":[" <> payload <> "]}}")
            ]
      mapM_
        ( \line -> do
            agentEvent <- singleNotice line
            let summary = agentEvent.agentEventSummary
            summary `shouldSatisfy` (not . Data.Text.null)
            Data.Text.length summary `shouldSatisfy` (<= maxUnknownNoticeLength)
            Data.Text.lines summary `shouldSatisfy` ((== 1) . length)
            summary `shouldSatisfy` Data.Text.all (not . isControl)
        )
        (concatMap wrapped payloads)

    it "treats a non-string type naming a recognized type as unrecognized rather than letting it reach an unbounded branch" $ do
      -- A permissive type discriminator would coerce these into recognized
      -- branches and hand back exactly what the bound exists to prevent: an
      -- unbounded 'error' message, and 'tool_result' 's whole-payload
      -- fallback. Only a literal JSON string names a recognized type.
      let blob = Data.Text.replicate 400 "0123456789"
          coerced = ["[\"error\"]", "{\"text\":\"error\"}", "[\"tool_result\"]", "{\"text\":\"agent_message\"}", "[\"assistant\"]"]
          payload typeValue = "{\"type\":" <> typeValue <> ",\"message\":\"" <> Data.Text.unpack blob <> "\",\"text\":\"" <> Data.Text.unpack blob <> "\",\"content\":\"" <> Data.Text.unpack blob <> "\"}"
          wrapped typeValue =
            [ ByteString.pack (payload typeValue),
              ByteString.pack ("{\"type\":\"item.completed\",\"item\":" <> payload typeValue <> "}"),
              ByteString.pack ("{\"type\":\"assistant\",\"message\":{\"content\":[" <> payload typeValue <> "]}}")
            ]
      mapM_
        ( \line -> do
            agentEvent <- singleNotice line
            agentEvent.agentEventKind `shouldBe` "event"
            agentEvent.agentEventSummary `shouldSatisfy` Data.Text.isInfixOf "unknown"
            Data.Text.length agentEvent.agentEventSummary `shouldSatisfy` (<= maxUnknownNoticeLength)
            agentEvent.agentEventSummary `shouldNotSatisfy` Data.Text.isInfixOf blob
            agentEvent.agentEventDetail `shouldBe` ""
        )
        (concatMap wrapped coerced)

    it "reports the first three occurrences of an unknown key and collapses the rest into one counted summary" $ do
      -- The exact boundary: three occurrences are all reported and leave no
      -- summary behind; a fourth suppresses itself and redeems the key as a
      -- single total-count summary.
      let telemetry = "{\"type\":\"telemetry\",\"n\":1}"
      atBoundary <- aggregatedNotices (replicate unknownNoticeSamples telemetry)
      length atBoundary `shouldBe` unknownNoticeSamples
      atBoundary `shouldSatisfy` all (Data.Text.isPrefixOf "[event] telemetry ")
      atBoundary `shouldSatisfy` all (not . Data.Text.isInfixOf "×")

      pastBoundary <- aggregatedNotices (replicate (unknownNoticeSamples + 1) telemetry)
      length pastBoundary `shouldBe` unknownNoticeSamples + 1
      last pastBoundary `shouldBe` "[event] telemetry ×4"

      -- A chatty type stays O(1) per invocation however long it runs.
      chatty <- aggregatedNotices (replicate 418 telemetry)
      length chatty `shouldBe` unknownNoticeSamples + 1
      last chatty `shouldBe` "[event] telemetry ×418"

    it "counts each category, type, and prefix-sharing type apart, and lets recognized events pass between repeats" $ do
      -- 'foo' arriving as a top-level event, a Codex item, and a Claude
      -- content block is three independent keys, not one; two distinct long
      -- types that share a bounded display prefix are two keys, not one; and
      -- recognized output interleaved with the repeats neither resets a
      -- count nor is itself suppressed.
      let longPrefix = replicate 60 'p'
          typeA = longPrefix <> "-alpha"
          typeB = longPrefix <> "-beta"
          eventFoo = "{\"type\":\"foo\"}"
          itemFoo = "{\"type\":\"item.completed\",\"item\":{\"type\":\"foo\"}}"
          contentFoo = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"foo\"}]}}"
          recognizedLine = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"still working\"}}"
          longA = "{\"type\":\"" <> typeA <> "\"}"
          longB = "{\"type\":\"" <> typeB <> "\"}"
      notices <-
        aggregatedNotices
          ( concat (replicate 5 [eventFoo, itemFoo, contentFoo])
              <> [recognizedLine]
              <> concat (replicate 5 [eventFoo, itemFoo, contentFoo])
              <> replicate 5 longA
              <> replicate 7 longB
          )
      let summaries = filter (Data.Text.isInfixOf "×") notices
      -- Each of the five keys is counted on its own; the interleaved
      -- recognized event did not restart 'foo' at one.
      sort summaries
        `shouldBe` sort
          [ "[content] foo ×10",
            "[event] " <> Data.Text.pack (take 47 typeA) <> "… ×5",
            "[event] " <> Data.Text.pack (take 47 typeB) <> "… ×7",
            "[event] foo ×10",
            "[item] foo ×10"
          ]
      notices `shouldSatisfy` elem "still working"

    it "keeps a textual error message in full while bounding an error payload that has no usable message" $ do
      -- The one exemption stays: a literal string 'message' is never
      -- truncated. Anything else about an 'error' payload — missing,
      -- non-string, or blank message — is bounded like any other
      -- unrecognized payload rather than embedding the raw JSON.
      let longMessage = Data.Text.replicate 120 "failure detail "
          textualError = ByteString.pack ("{\"type\":\"error\",\"message\":\"" <> Data.Text.unpack longMessage <> "\"}")
          textualItemError = ByteString.pack ("{\"type\":\"item.completed\",\"item\":{\"type\":\"error\",\"message\":\"" <> Data.Text.unpack longMessage <> "\"}}")
      mapM_
        ( \line -> do
            agentEvent <- singleNotice line
            agentEvent.agentEventKind `shouldBe` "error"
            agentEvent.agentEventSummary `shouldBe` "[error] " <> longMessage
            agentEvent.agentEventOutcomeText `shouldBe` Just longMessage
        )
        [textualError, textualItemError]

      let blob = Data.Text.replicate 400 "0123456789"
          unusable suffix = "{\"type\":\"error\"," <> suffix <> ",\"blob\":\"" <> Data.Text.unpack blob <> "\"}"
          messageShapes = map unusable ["\"detail\":\"no message\"", "\"message\":123", "\"message\":{\"text\":\"coerced\"}", "\"message\":\"  \""]
      mapM_
        ( \payload ->
            mapM_
              ( \line -> do
                  agentEvent <- singleNotice line
                  agentEvent.agentEventKind `shouldBe` "event"
                  Data.Text.length agentEvent.agentEventSummary `shouldSatisfy` (<= maxUnknownNoticeLength)
                  agentEvent.agentEventSummary `shouldNotSatisfy` Data.Text.isInfixOf blob
              )
              [ByteString.pack payload, ByteString.pack ("{\"type\":\"item.completed\",\"item\":" <> payload <> "}")]
        )
        messageShapes

    it "identifies the session before forwarding agent output, and reports normal completion" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"stream-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #999\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            aggregator <- newUnknownAggregator
            runSolve repository 900 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            case (findIndex isSolveSessionIdentifiedEvent collected, findIndex isSolveOutputEvent collected) of
              (Just sessionIndex, Just outputIndex) -> sessionIndex `shouldSatisfy` (< outputIndex)
              _ -> expectationFailure "expected both a session-identified and an output event"
            case reverse collected of
              (SolveProcessFinished _ SolveCompleted : _) -> pure ()
              (SolveProcessFinished _ (SolveFailed message) : _) -> expectationFailure ("expected completion, got failure: " <> Data.Text.unpack message)
              (SolveProcessFinished _ (SolveNeedsInput question) : _) -> expectationFailure ("expected completion, got needs-input: " <> Data.Text.unpack question)
              _ -> expectationFailure "expected the final event to be SolveProcessFinished"

    it "reports a needs-input outcome when the agent's last message carries the KANBAN_NEEDS_INPUT marker" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"needs-input-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"KANBAN_NEEDS_INPUT: which branch?\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            aggregator <- newUnknownAggregator
            runSolve repository 901 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            case reverse collected of
              (SolveProcessFinished _ (SolveNeedsInput question) : _) -> question `shouldBe` "which branch?"
              _ -> expectationFailure "expected a needs-input terminal outcome"

    it "signals stderr-reader completion (and returns) even when diagnostic delivery for a stderr line throws" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile
          fakeCodex
          ( ByteString.unlines
              [ "#!/bin/sh",
                "echo 'stderr-poison-line' >&2",
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"stderr-poison-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Created PR #999\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            let poisonedSink event = case event of
                  SolveDiagnostic _ message
                    | Data.Text.isInfixOf "stderr-poison-line" message -> throwIO (userError "diagnostic delivery exploded")
                  _ -> pure ()
            aggregator <- newUnknownAggregator
            timeout 10000000 (runSolve repository 902 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator poisonedSink) `shouldReturn` Just ()

    it "terminates the still-live provider and forces a failed terminal outcome when the stdout reader's read primitive keeps failing" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        -- A provider that just sleeps, kept alive so 'runSolveWith' has a
        -- real, still-live process to terminate. The stdout-only-failing
        -- read primitive below drives that path's abandonment
        -- deterministically; what the provider would otherwise have
        -- written on stdout is irrelevant, since the stdout reader never
        -- actually calls through to a real read here.
        ByteString.writeFile fakeCodex (ByteString.unlines ["#!/bin/sh", "sleep 30"])
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            spawnedIdentity <- newIORef Nothing
            let sink event = do
                  modifyIORef events (event :)
                  case event of
                    SolveProcessStarted _ _ managed -> do
                      maybePid <- managedProcessPid managed
                      case maybePid of
                        Nothing -> pure ()
                        Just pid -> do
                          snapshot <- readProcessSnapshot
                          case snapshot of
                            Right identities -> writeIORef spawnedIdentity (identityForPid (fromIntegral pid) identities)
                            Left _ -> pure ()
                    _ -> pure ()
                -- Fails only the stdout handle; the stderr reader keeps
                -- using the real primitive (and so completes normally once
                -- the provider is killed), so the failed terminal outcome
                -- below can only be attributed to the stdout path, not a
                -- race with stderr's own abandonment.
                stdoutOnlyFails tag handle
                  | tag == "stdout" = pure (Left (userError "simulated persistent stdout read failure"))
                  | otherwise = handleReadLine handle
            aggregator <- newUnknownAggregator
            timeout 20000000 (runSolveWith stdoutOnlyFails repository 906 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator sink) `shouldReturn` Just ()
            collected <- reverse <$> readIORef events
            let stdoutAbandonments = [message | SolveDiagnostic _ message <- collected, Data.Text.isInfixOf "stdout stream reader gave up" message]
            stdoutAbandonments `shouldSatisfy` (not . null)
            case reverse collected of
              (SolveProcessFinished _ (SolveFailed _) : _) -> pure ()
              _ -> expectationFailure "expected a failed terminal outcome after the stdout reader was abandoned"
            identity <- readIORef spawnedIdentity
            case identity of
              Nothing -> expectationFailure "expected to capture the spawned provider's process identity"
              Just recorded -> do
                snapshotAfter <- readProcessSnapshot
                case snapshotAfter of
                  Left message -> expectationFailure ("could not verify process death: " <> Data.Text.unpack message)
                  Right identities -> matchingIdentities identities [recorded] `shouldBe` []

    it "records every raw line of a chatty unknown event type while forwarding only bounded, collapsed notices" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile fakeCodex (chattyProvider "unknown-stream-session" "Created PR #999" [])
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            aggregator <- newUnknownAggregator
            runSolve repository 907 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            -- Only a constant number of records reach the sink the worker
            -- journals: the samples plus one counted summary, however many
            -- occurrences the provider streamed.
            let notices = [agentEvent | SolveOutput _ agentEvent <- collected, Data.Text.isPrefixOf "[event] telemetry" agentEvent.agentEventSummary]
            length notices `shouldBe` unknownNoticeSamples + 1
            notices `shouldSatisfy` all ((<= maxUnknownNoticeLength) . Data.Text.length . (.agentEventSummary))
            -- The summary lands before the terminal event, which is where
            -- replay stops reading the journal.
            case reverse collected of
              (SolveProcessFinished _ SolveCompleted : SolveOutput _ summary : _) ->
                summary.agentEventSummary `shouldBe` "[event] telemetry ×" <> Data.Text.pack (show chattyProviderLines)
              _ -> expectationFailure "expected the aggregate summary immediately before the terminal event"
            -- Full fidelity still lives in the session log, untouched.
            rawTelemetryLines [path | SolveLogOpened _ path <- collected] `shouldReturn` chattyProviderLines

    it "still emits exactly one aggregate summary when the provider is interrupted mid-stream" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        -- The provider stays alive after its chatty burst, so the kill below
        -- lands as a real interruption rather than racing a normal exit. The
        -- sentinel is only reached once every telemetry line before it has
        -- already been read and aggregated, which is what makes the expected
        -- count deterministic.
        ByteString.writeFile fakeCodex (chattyProvider "interrupted-stream-session" "READY" ["sleep 30"])
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            managedRef <- newIORef Nothing
            let sink event = do
                  modifyIORef events (event :)
                  case event of
                    SolveProcessStarted _ _ managed -> writeIORef managedRef (Just managed)
                    SolveOutput _ agentEvent
                      | agentEvent.agentEventSummary == "READY" -> readIORef managedRef >>= mapM_ killManagedProcess
                    _ -> pure ()
            aggregator <- newUnknownAggregator
            timeout 20000000 (runSolve repository 908 SolveOnly CodexSolver Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator sink) `shouldReturn` Just ()
            collected <- reverse <$> readIORef events
            [agentEvent.agentEventSummary | SolveOutput _ agentEvent <- collected, Data.Text.isInfixOf "×" agentEvent.agentEventSummary]
              `shouldBe` ["[event] telemetry ×" <> Data.Text.pack (show chattyProviderLines)]
            case reverse collected of
              (SolveProcessFinished _ (SolveFailed _) : SolveOutput _ summary : _) ->
                summary.agentEventSummary `shouldBe` "[event] telemetry ×" <> Data.Text.pack (show chattyProviderLines)
              _ -> expectationFailure "expected the aggregate summary immediately before the interrupted terminal event"
            rawTelemetryLines [path | SolveLogOpened _ path <- collected] `shouldReturn` chattyProviderLines
