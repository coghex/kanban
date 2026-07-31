-- | Routing a pull request to its review, rereview or revision workflow.
module Spec.Agent.PullRequestFlow (spec) where

import Control.Exception (throwIO)
import qualified Data.ByteString.Char8 as ByteString
import Data.IORef (modifyIORef, newIORef, readIORef, writeIORef)
import Data.List (findIndex)
import qualified Data.Text
import Data.Time (UTCTime (..), fromGregorian)
import Kanban.Domain
import Kanban.Process (identityForPid, managedProcessPid, matchingIdentities, readProcessSnapshot)
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestFlowEvent (..),
    PullRequestOrigin (..),
    PullRequestVerdict (..),
    actionForLabels,
    agentForAction,
    originFromBody,
    pullRequestArguments,
    pullRequestVerdictForLabels,
    runPullRequestFlow,
    runPullRequestFlowWith
  )
import Kanban.Solve
  ( AgentEvent (..),
    ResumeProvenance (..),
    SolveOutcome (..),
    SolverBrand (..),
    maxUnknownNoticeLength,
    newUnknownAggregator,
    resumeProvenanceHeader,
    unknownNoticeSamples
  )
import Kanban.StreamReader (handleReadLine)
import Kanban.UI (pullRequestSessionReusable, autoSolveRevisionPrompt)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Process
  ( chattyProvider,
    chattyProviderLines,
    isPullRequestFlowOutputEvent,
    isPullRequestSessionIdentifiedEvent,
    rawTelemetryLines
  )
import System.Directory (createDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = do
  describe "pull request review/revision routing" $ do
    it "requires one unambiguous PR origin marker" $ do
      originFromBody "body\n<!-- pr-origin:codex -->" `shouldBe` Right PullRequestCodex
      originFromBody "body\n<!-- pr-origin:claude -->" `shouldBe` Right PullRequestClaude
      originFromBody "body" `shouldBe` Left "PR body has no valid pr-origin marker"

    it "advances review, revision, and rereview from durable labels" $ do
      actionForLabels defaultWorkflowConfig [] `shouldBe` PullRequestReview
      actionForLabels defaultWorkflowConfig ["reviewed:changes"] `shouldBe` PullRequestRevision
      actionForLabels defaultWorkflowConfig ["reviewed:changes", "reviewed:revised"] `shouldBe` PullRequestRereview
      actionForLabels defaultWorkflowConfig ["reviewed:revised"] `shouldBe` PullRequestRereview

    it "advances to revision from a configured changes-requested label" $
      actionForLabels (defaultWorkflowConfig {changesRequestedLabel = "needs-work"}) ["needs-work"] `shouldBe` PullRequestRevision

    it "uses the opposite brand to review and the origin brand to revise" $ do
      agentForAction PullRequestCodex PullRequestReview `shouldBe` ClaudeSolver
      agentForAction PullRequestCodex PullRequestRevision `shouldBe` CodexSolver
      agentForAction PullRequestClaude PullRequestReview `shouldBe` CodexSolver
      agentForAction PullRequestClaude PullRequestRevision `shouldBe` ClaudeSolver

    it "pins canonical reviewer and reviser models" $ do
      pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "" `shouldContain` ["--model", "claude-opus-5", "--effort", "xhigh"]
      pullRequestArguments 42 PullRequestCodex PullRequestRevision CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "" `shouldContain` ["--model", "gpt-5.4", "--config", "model_reasoning_effort=\"high\""]
      pullRequestArguments 42 PullRequestClaude PullRequestRevision ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "" `shouldContain` ["--model", "claude-sonnet-5", "--effort", "xhigh"]
      pullRequestArguments 42 PullRequestClaude PullRequestRereview CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "" `shouldContain` ["--model", "gpt-5.6-terra", "--config", "model_reasoning_effort=\"xhigh\""]

    it "routes r-key revisions through canonical pr-revise instead of the legacy manual-label prompt" $ do
      let codexOriginRevisionPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestRevision CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          claudeOriginRevisionPrompt = last (pullRequestArguments 42 PullRequestClaude PullRequestRevision ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      codexOriginRevisionPrompt `shouldContain` "$pr-revise"
      claudeOriginRevisionPrompt `shouldContain` "/pr-revise"
      codexOriginRevisionPrompt `shouldNotContain` "pr-review:v1"
      claudeOriginRevisionPrompt `shouldNotContain` "pr-review:v1"
      codexOriginRevisionPrompt `shouldNotContain` "create reviewed:revised"
      codexOriginRevisionPrompt `shouldContain` "leave reviewed:approve, reviewed:changes, and reviewed:revised to the canonical review coordinator"

    it "builds the revision prompt's coordinator-owned labels from the configured workflow labels, not literals" $ do
      let customConfig = defaultWorkflowConfig {approvalLabel = "lgtm", changesRequestedLabel = "needs-work"}
          customPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestRevision CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") customConfig Nothing ResumeAnswer "")
      customPrompt `shouldContain` "leave lgtm, needs-work, and reviewed:revised to the canonical review coordinator"
      customPrompt `shouldNotContain` "reviewed:approve, reviewed:changes"

    it "tells a spawned reviewer to pass the dashboard's selected --config to the canonical coordinator, but only when one is configured" $ do
      let configuredPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver (Just "/tmp/custom-config.toml") (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          defaultPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      configuredPrompt `shouldContain` "--config /tmp/custom-config.toml"
      defaultPrompt `shouldNotContain` "--config"

    it "always tells a spawned reviewer to pass Kanban's own resolved --repo to the canonical coordinator, even without a fork override" $ do
      let forkRepository = Repository "/tmp/fork" "upstream-owner" "upstream-repo"
          forkPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing forkRepository defaultWorkflowConfig Nothing ResumeAnswer "")
      forkPrompt `shouldContain` "Pass --repo upstream-owner/upstream-repo to"

    it "tells a resumed autosolve pr-revise to pass the dashboard's selected --config, but only when one is configured" $ do
      let repository = Repository "/tmp/repo" "coghex" "kanban"
          configuredPrompt = Data.Text.unpack (autoSolveRevisionPrompt defaultWorkflowConfig (Just "/tmp/custom-config.toml") repository ClaudeSolver 42 1)
          defaultPrompt = Data.Text.unpack (autoSolveRevisionPrompt defaultWorkflowConfig Nothing repository ClaudeSolver 42 1)
      configuredPrompt `shouldContain` "--config /tmp/custom-config.toml"
      defaultPrompt `shouldNotContain` "--config"

    it "always tells a resumed autosolve pr-revise to pass Kanban's own resolved --repo, even without a fork override" $ do
      let forkRepository = Repository "/tmp/fork" "upstream-owner" "upstream-repo"
          forkPrompt = Data.Text.unpack (autoSolveRevisionPrompt defaultWorkflowConfig Nothing forkRepository ClaudeSolver 42 1)
      forkPrompt `shouldContain` "Pass --repo upstream-owner/upstream-repo to"

    it "never asks the initial review prompt to remove a label only rereview can see, but keeps that instruction in rereview" $ do
      let initialReviewPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          rereviewPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestRereview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      initialReviewPrompt `shouldNotContain` "reviewed:revised"
      rereviewPrompt `shouldContain` "Remove reviewed:revised after successfully publishing the verdict"

    it "frames a resumed PR prompt with the true provenance of the resumed message instead of always claiming a user answer" $ do
      let answerPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeAnswer "looks good")
          interruptPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeInterruptGuidance "check the other file too")
      answerPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeAnswer)
      answerPrompt `shouldContain` "KANBAN_NEEDS_INPUT"
      interruptPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeInterruptGuidance)
      interruptPrompt `shouldNotContain` "The user answered"
      interruptPrompt `shouldContain` "KANBAN_NEEDS_INPUT"

    it "names the configured changes-requested label in a resumed PR revision's automated-handoff header" $ do
      let customConfig = defaultWorkflowConfig {changesRequestedLabel = "needs-work"}
          customAutomatedPrompt = last (pullRequestArguments 42 PullRequestCodex PullRequestRevision CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") customConfig (Just "session-1") ResumeAutomatedChangesRequested "Kanban received CHANGES_REQUESTED for PR #900")
      customAutomatedPrompt `shouldContain` "the PR received needs-work"
      customAutomatedPrompt `shouldNotContain` "the PR received reviewed:changes"

    it "derives a pure post-revision verdict from current labels instead of waiting on a reviewed:revised handoff" $ do
      pullRequestVerdictForLabels defaultWorkflowConfig [] `shouldBe` PullRequestVerdictPending
      pullRequestVerdictForLabels defaultWorkflowConfig ["reviewed:revised"] `shouldBe` PullRequestVerdictPending
      pullRequestVerdictForLabels defaultWorkflowConfig ["reviewed:approve"] `shouldBe` PullRequestVerdictApproved
      pullRequestVerdictForLabels defaultWorkflowConfig ["reviewed:changes"] `shouldBe` PullRequestVerdictChangesRequested

    it "derives a post-revision verdict using a configured approval label" $
      pullRequestVerdictForLabels (defaultWorkflowConfig {approvalLabel = "lgtm"}) ["lgtm"] `shouldBe` PullRequestVerdictApproved

    it "starts a fresh r-key revision round instead of reopening a finished one when the PR changed since it launched" $ do
      let launchedAt = UTCTime (fromGregorian 2026 7 18) 0
          unchanged = launchedAt
          afterFreshVerdict = UTCTime (fromGregorian 2026 7 19) 0
      -- A finished PullRequestRevision session addressing the same unchanged
      -- state (no new push, comment, or label change) is safely reused.
      pullRequestSessionReusable False False PullRequestRevision PullRequestRevision launchedAt unchanged `shouldBe` True
      -- pr-revise's own canonical rereview lands a fresh reviewed:changes
      -- verdict, so the recomputed action repeats (PullRequestRevision) but
      -- the PR has changed since this session launched: it must not reuse
      -- the finished session and instead start another canonical round.
      pullRequestSessionReusable False False PullRequestRevision PullRequestRevision launchedAt afterFreshVerdict `shouldBe` False
      -- A still-active session is always reused regardless of PR changes.
      pullRequestSessionReusable False True PullRequestRevision PullRequestRevision launchedAt afterFreshVerdict `shouldBe` True
      -- forceFresh always starts a new session.
      pullRequestSessionReusable True False PullRequestRevision PullRequestRevision launchedAt unchanged `shouldBe` False

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
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"pr-stream-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Reviewed\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            aggregator <- newUnknownAggregator
            runPullRequestFlow repository 904 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            case (findIndex isPullRequestSessionIdentifiedEvent collected, findIndex isPullRequestFlowOutputEvent collected) of
              (Just sessionIndex, Just outputIndex) -> sessionIndex `shouldSatisfy` (< outputIndex)
              _ -> expectationFailure "expected both a session-identified and an output event"
            case reverse collected of
              (PullRequestProcessFinished _ SolveCompleted : _) -> pure ()
              (PullRequestProcessFinished _ (SolveFailed message) : _) -> expectationFailure ("expected completion, got failure: " <> Data.Text.unpack message)
              (PullRequestProcessFinished _ (SolveNeedsInput question) : _) -> expectationFailure ("expected completion, got needs-input: " <> Data.Text.unpack question)
              _ -> expectationFailure "expected the final event to be PullRequestProcessFinished"

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
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"pr-needs-input-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"KANBAN_NEEDS_INPUT: which reviewer wins?\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            aggregator <- newUnknownAggregator
            runPullRequestFlow repository 905 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            case reverse collected of
              (PullRequestProcessFinished _ (SolveNeedsInput question) : _) -> question `shouldBe` "which reviewer wins?"
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
                "printf '%s\\n' '{\"type\":\"thread.started\",\"thread_id\":\"pr-stderr-poison-session\"}'",
                "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Reviewed\"}}'"
              ]
          )
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            let poisonedSink event = case event of
                  PullRequestFlowDiagnostic _ message
                    | Data.Text.isInfixOf "stderr-poison-line" message -> throwIO (userError "diagnostic delivery exploded")
                  _ -> pure ()
            aggregator <- newUnknownAggregator
            timeout 10000000 (runPullRequestFlow repository 903 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator poisonedSink) `shouldReturn` Just ()

    it "terminates the still-live provider and forces a failed terminal outcome when the stdout reader's read primitive keeps failing" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        -- A provider that just sleeps, kept alive so
        -- 'runPullRequestFlowWith' has a real, still-live process to
        -- terminate. The stdout-only-failing read primitive below drives
        -- that path's abandonment deterministically; what the provider
        -- would otherwise have written on stdout is irrelevant, since the
        -- stdout reader never actually calls through to a real read here.
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
                    PullRequestProcessStarted _ _ _ managed -> do
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
            timeout 20000000 (runPullRequestFlowWith stdoutOnlyFails repository 907 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator sink) `shouldReturn` Just ()
            collected <- reverse <$> readIORef events
            let stdoutAbandonments = [message | PullRequestFlowDiagnostic _ message <- collected, Data.Text.isInfixOf "stdout stream reader gave up" message]
            stdoutAbandonments `shouldSatisfy` (not . null)
            case reverse collected of
              (PullRequestProcessFinished _ (SolveFailed _) : _) -> pure ()
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
        -- The PR flow owns its own stdout loop, so it needs its own proof
        -- that the shared parser's bounding and this flow's own aggregation
        -- are wired together the same way the solve flow's are.
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeCodex = binaryRoot </> "codex"
            repository = Repository repositoryRoot "coghex" "kanban"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile fakeCodex (chattyProvider "pr-unknown-stream-session" "Reviewed" [])
        setFileMode fakeCodex 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
          withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
            events <- newIORef []
            aggregator <- newUnknownAggregator
            runPullRequestFlow repository 908 PullRequestClaude PullRequestReview Nothing defaultWorkflowConfig Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            let notices = [agentEvent | PullRequestFlowOutput _ agentEvent <- collected, Data.Text.isPrefixOf "[event] telemetry" agentEvent.agentEventSummary]
            length notices `shouldBe` unknownNoticeSamples + 1
            notices `shouldSatisfy` all ((<= maxUnknownNoticeLength) . Data.Text.length . (.agentEventSummary))
            case reverse collected of
              (PullRequestProcessFinished _ SolveCompleted : PullRequestFlowOutput _ summary : _) ->
                summary.agentEventSummary `shouldBe` "[event] telemetry ×" <> Data.Text.pack (show chattyProviderLines)
              _ -> expectationFailure "expected the aggregate summary immediately before the terminal event"
            rawTelemetryLines [path | PullRequestLogOpened _ path <- collected] `shouldReturn` chattyProviderLines
