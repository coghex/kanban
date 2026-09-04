-- | Routing a pull request to its review, rereview or revision workflow.
module Spec.Agent.PullRequestFlow (spec) where

import Control.Exception (throwIO)
import qualified Data.ByteString.Char8 as ByteString
import Data.IORef (modifyIORef, newIORef, readIORef, writeIORef)
import Data.List (findIndex)
import qualified Data.Text
import qualified Data.Text.IO as TextIO
import Data.Time (UTCTime (..), fromGregorian)
import Kanban.Domain
import Kanban.Models (Assignment (..), ModelRoster, OperatingMode (..), defaultRoster, recordedAssignmentCell)
import Kanban.Process (identityForPid, managedProcessPid, matchingIdentities, readProcessSnapshot)
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestFlowEvent (..),
    PullRequestOrigin (..),
    PullRequestVerdict (..),
    actionForLabels,
    agentForAction,
    directPullRequestAction,
    labelPullRequestAction,
    originFromBody,
    pullRequestArguments,
    pullRequestAssignment,
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
import Kanban.UI.AutoSolve (autoSolveRevisionPrompt)
import Kanban.UI.Session (pullRequestSessionReusable)
import Kanban.UI.Types (AgentSession (..), ChatTranscript (..), PullRequestDetail (..))
import Kanban.UI.Worker (recoveredPullRequestSession)
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerTask (..),
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Roster (cellOf, rerosteredDefaults)
import Spec.Support.Fixtures (basePullRequest, epoch)
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

    -- Issue #494. `originFromBody` counts each marker across the whole body
    -- with no awareness of HTML comments, so a marker pasted into the
    -- template's own ORIGIN COMMENT -- the mistake that comment warns
    -- against -- would make every agent-authored body opened from it
    -- ambiguous. The literals above cannot see that; the tracked file is read
    -- here instead, the way "Spec.UI.Keys" reads @docs\/design.md@ and
    -- @tools\/test_pull_request_template.py@ reads this same file for the two
    -- packaged coordinators' parser.
    it "reads no origin from the tracked pull-request template" $ do
      template <- TextIO.readFile pullRequestTemplatePath
      (pullRequestTemplatePath, originFromBody template)
        `shouldBe` (pullRequestTemplatePath, Left "PR body has no valid pr-origin marker")

    -- The negative control for the assertion above, and the body an agent
    -- actually opens: with its own trailing marker the template must resolve
    -- to exactly one brand. A stray marker anywhere above would make this a
    -- duplicate instead.
    it "reads the appended marker on a body opened from that template" $ do
      template <- TextIO.readFile pullRequestTemplatePath
      let opened = Data.Text.stripEnd template <> "\n\n<!-- pr-origin:claude -->\n"
      (pullRequestTemplatePath, originFromBody opened)
        `shouldBe` (pullRequestTemplatePath, Right PullRequestClaude)

    it "advances review, revision, and rereview from durable labels" $ do
      actionForLabels defaultWorkflowConfig [] `shouldBe` PullRequestReview
      actionForLabels defaultWorkflowConfig ["reviewed:changes"] `shouldBe` PullRequestRevision
      actionForLabels defaultWorkflowConfig ["reviewed:changes", "reviewed:revised"] `shouldBe` PullRequestRereview
      actionForLabels defaultWorkflowConfig ["reviewed:revised"] `shouldBe` PullRequestRereview

    it "advances to revision from a configured changes-requested label" $
      actionForLabels (defaultWorkflowConfig {changesRequestedLabel = "needs-work"}) ["needs-work"] `shouldBe` PullRequestRevision

    it "uses the opposite brand to review and the origin brand to revise or repair" $ do
      agentForAction DualMode PullRequestCodex PullRequestReview `shouldBe` ClaudeSolver
      agentForAction DualMode PullRequestCodex PullRequestRevision `shouldBe` CodexSolver
      agentForAction DualMode PullRequestClaude PullRequestReview `shouldBe` CodexSolver
      agentForAction DualMode PullRequestClaude PullRequestRevision `shouldBe` ClaudeSolver
      -- Repair works on the PR's own code, so like revision it launches on
      -- the PR's own origin brand rather than the reviewer's.
      agentForAction DualMode PullRequestCodex PullRequestRepair `shouldBe` CodexSolver
      agentForAction DualMode PullRequestClaude PullRequestRepair `shouldBe` ClaudeSolver

    -- The fourth derived meaning of r: a Done card whose status is a problem
    -- needs its own code worked on, not another review round. Both halves of
    -- that condition are load-bearing, so each repair cause is paired with
    -- the near-miss that must NOT select repair.
    it "selects repair for every problem cause on a Done pull request" $ do
      directPullRequestAction defaultWorkflowConfig (approvedFixture {pullRequestMergeState = MergeConflicting})
        `shouldBe` PullRequestRepair
      directPullRequestAction defaultWorkflowConfig (approvedFixture {pullRequestChecks = ChecksFailed 1 3 []})
        `shouldBe` PullRequestRepair
      -- A blocking label under the default red severity, from either
      -- configured collection rather than a built-in name.
      directPullRequestAction defaultWorkflowConfig (withLabels [approvalLabelChip, Label "blocked" "b60205"])
        `shouldBe` PullRequestRepair
      directPullRequestAction
        (defaultWorkflowConfig {changesRequestedLabel = "needs-work"})
        (withLabels [approvalLabelChip, Label "needs-work" "b60205"])
        `shouldBe` PullRequestRepair

    it "leaves r unchanged for a problem pull request that is not in Done" $ do
      -- Unapproved: pullRequestStatus reports the conflict, but the card is
      -- in Reviewing, where the label-derived action still applies.
      directPullRequestAction defaultWorkflowConfig ((basePullRequest 900 [] False []) {pullRequestMergeState = MergeConflicting})
        `shouldBe` PullRequestReview
      -- Approved but still a draft, which classifyPullRequest keeps out of
      -- Done however the review landed.
      directPullRequestAction defaultWorkflowConfig (approvedFixture {pullRequestDraft = True, pullRequestMergeState = MergeConflicting})
        `shouldBe` PullRequestReview

    it "keeps the label-derived action for a Done pull request with no problem status" $ do
      directPullRequestAction defaultWorkflowConfig approvedFixture `shouldBe` PullRequestReview
      directPullRequestAction defaultWorkflowConfig (withLabels [approvalLabelChip, Label "reviewed:revised" "1d76db"])
        `shouldBe` PullRequestRereview
      -- Amber severity demotes a blocking label to pending, so this Done card
      -- has no problem status and keeps whatever its labels derive — which
      -- here is revision, reached through ApprovalByReview while the
      -- configured changes-requested label is still on the pull request.
      let amberByReview = defaultWorkflowConfig {approvalMode = ApprovalByReview, blockingSeverity = SeverityAmber}
          reviewApprovedWithChanges =
            (basePullRequest 900 [] False [Label "reviewed:changes" "b60205"])
              { pullRequestReviewDecision = ReviewApproved
              }
      directPullRequestAction amberByReview reviewApprovedWithChanges `shouldBe` PullRequestRevision

    -- Autosolve drives its own review/revise progression through the same PR
    -- session starter, and must keep doing exactly that: a repair launch
    -- there would abandon the loop's round accounting mid-flight.
    it "never derives repair for Kanban's own automated label-driven progression" $ do
      labelPullRequestAction defaultWorkflowConfig (approvedFixture {pullRequestMergeState = MergeConflicting})
        `shouldBe` PullRequestReview
      labelPullRequestAction defaultWorkflowConfig (withLabels [approvalLabelChip, Label "reviewed:changes" "b60205"])
        `shouldBe` PullRequestRevision

    it "pins canonical reviewer and reviser models" $ mapM_ (assertRosterDrivenArguments defaultRoster) migratedRoutes

    -- Byte-identity under the defaults (the arm above) only means something
    -- if argv is genuinely derived from the cell, so every migrated route is
    -- asserted a second time against a roster whose cells all differ.
    it "carries a non-default roster's cells into every migrated pull-request route" $ do
      mapM_ (assertRosterDrivenArguments rerosteredDefaults) migratedRoutes
      [pullRequestCell rerosteredDefaults origin action | (origin, action, _) <- migratedRoutes]
        `shouldNotBe` [pullRequestCell defaultRoster origin action | (origin, action, _) <- migratedRoutes]

    it "invokes the packaged repair workflow on the PR's own brand, with the author-side model pairing" $ do
      let repository = Repository "/tmp/repo" "coghex" "kanban"
          codexOriginArguments = pullRequestArgumentsOn defaultRoster 42 PullRequestCodex PullRequestRepair CodexSolver Nothing repository defaultWorkflowConfig Nothing ResumeAnswer ""
          claudeOriginArguments = pullRequestArgumentsOn defaultRoster 42 PullRequestClaude PullRequestRepair ClaudeSolver Nothing repository defaultWorkflowConfig Nothing ResumeAnswer ""
      codexOriginArguments `shouldContain` codexFlags (pullRequestCell defaultRoster PullRequestCodex PullRequestRepair)
      claudeOriginArguments `shouldContain` claudeFlags (pullRequestCell defaultRoster PullRequestClaude PullRequestRepair)
      -- Each brand's own invocation token, and the repair coordinator rather
      -- than the review family named as the target of --repo.
      last codexOriginArguments `shouldContain` "$repair"
      last claudeOriginArguments `shouldContain` "/repair"
      last codexOriginArguments `shouldContain` "Pass --repo coghex/kanban to $repair"
      last codexOriginArguments `shouldNotContain` "$pr-review"
      last codexOriginArguments `shouldContain` "leave reviewed:approve, reviewed:changes, and reviewed:revised to the canonical review coordinator"
      last claudeOriginArguments `shouldContain` "never remove a blocking label yourself"

    it "keeps a resumed repair session on the repair workflow" $ do
      let resumedPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestClaude PullRequestRepair ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeAnswer "use the base branch")
      resumedPrompt `shouldContain` "Continue the same repair workflow"
      resumedPrompt `shouldContain` "KANBAN_NEEDS_INPUT"

    it "reattaches a persisted repair worker as a repair session on the PR's own brand" $ do
      let task = PullRequestWorkerTask 900 PullRequestClaude PullRequestRepair
          descriptor = repairWorkerDescriptor task
          session = recoveredPullRequestSession (Right defaultRoster) 0 descriptor approvedFixture task
      session.sessionDetail.pullRequestSessionAction `shouldBe` PullRequestRepair
      session.sessionDetail.pullRequestSessionOrigin `shouldBe` PullRequestClaude
      session.sessionDetail.pullRequestSessionBrand `shouldBe` ClaudeSolver
      session.sessionTranscript.fullTranscript `shouldSatisfy` Data.Text.isInfixOf "reattached persistent PR repair worker"

    it "routes r-key revisions through canonical pr-revise instead of the legacy manual-label prompt" $ do
      let codexOriginRevisionPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestCodex PullRequestRevision CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          claudeOriginRevisionPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestClaude PullRequestRevision ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      codexOriginRevisionPrompt `shouldContain` "$pr-revise"
      claudeOriginRevisionPrompt `shouldContain` "/pr-revise"
      codexOriginRevisionPrompt `shouldNotContain` "pr-review:v1"
      claudeOriginRevisionPrompt `shouldNotContain` "pr-review:v1"
      codexOriginRevisionPrompt `shouldNotContain` "create reviewed:revised"
      codexOriginRevisionPrompt `shouldContain` "leave reviewed:approve, reviewed:changes, and reviewed:revised to the canonical review coordinator"

    it "builds the revision prompt's coordinator-owned labels from the configured workflow labels, not literals" $ do
      let customConfig = defaultWorkflowConfig {approvalLabel = "lgtm", changesRequestedLabel = "needs-work"}
          customPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestCodex PullRequestRevision CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") customConfig Nothing ResumeAnswer "")
      customPrompt `shouldContain` "leave lgtm, needs-work, and reviewed:revised to the canonical review coordinator"
      customPrompt `shouldNotContain` "reviewed:approve, reviewed:changes"

    it "tells a spawned reviewer to pass the dashboard's selected --config to the canonical coordinator, but only when one is configured" $ do
      let configuredPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestCodex PullRequestReview ClaudeSolver (Just "/tmp/custom-config.toml") (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          defaultPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      configuredPrompt `shouldContain` "--config /tmp/custom-config.toml"
      defaultPrompt `shouldNotContain` "--config"

    it "always tells a spawned reviewer to pass Kanban's own resolved --repo to the canonical coordinator, even without a fork override" $ do
      let forkRepository = Repository "/tmp/fork" "upstream-owner" "upstream-repo"
          forkPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing forkRepository defaultWorkflowConfig Nothing ResumeAnswer "")
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
      let initialReviewPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
          rereviewPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestCodex PullRequestRereview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer "")
      initialReviewPrompt `shouldNotContain` "reviewed:revised"
      rereviewPrompt `shouldContain` "Remove reviewed:revised after successfully publishing the verdict"

    it "frames a resumed PR prompt with the true provenance of the resumed message instead of always claiming a user answer" $ do
      let answerPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeAnswer "looks good")
          interruptPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestCodex PullRequestReview ClaudeSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig (Just "session-1") ResumeInterruptGuidance "check the other file too")
      answerPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeAnswer)
      answerPrompt `shouldContain` "KANBAN_NEEDS_INPUT"
      interruptPrompt `shouldContain` Data.Text.unpack (resumeProvenanceHeader defaultWorkflowConfig ResumeInterruptGuidance)
      interruptPrompt `shouldNotContain` "The user answered"
      interruptPrompt `shouldContain` "KANBAN_NEEDS_INPUT"

    it "names the configured changes-requested label in a resumed PR revision's automated-handoff header" $ do
      let customConfig = defaultWorkflowConfig {changesRequestedLabel = "needs-work"}
          customAutomatedPrompt = last (pullRequestArgumentsOn defaultRoster 42 PullRequestCodex PullRequestRevision CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") customConfig (Just "session-1") ResumeAutomatedChangesRequested "Kanban received CHANGES_REQUESTED for PR #900")
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
            runPullRequestFlow repository 904 PullRequestClaude PullRequestReview CodexSolver Nothing defaultWorkflowConfig (pullRequestCell defaultRoster PullRequestClaude PullRequestReview) Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
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
            runPullRequestFlow repository 905 PullRequestClaude PullRequestReview CodexSolver Nothing defaultWorkflowConfig (pullRequestCell defaultRoster PullRequestClaude PullRequestReview) Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
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
            timeout 10000000 (runPullRequestFlow repository 903 PullRequestClaude PullRequestReview CodexSolver Nothing defaultWorkflowConfig (pullRequestCell defaultRoster PullRequestClaude PullRequestReview) Nothing Nothing ResumeAnswer "" aggregator poisonedSink) `shouldReturn` Just ()

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
            timeout 20000000 (runPullRequestFlowWith stdoutOnlyFails repository 907 PullRequestClaude PullRequestReview CodexSolver Nothing defaultWorkflowConfig (pullRequestCell defaultRoster PullRequestClaude PullRequestReview) Nothing Nothing ResumeAnswer "" aggregator sink) `shouldReturn` Just ()
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
            runPullRequestFlow repository 908 PullRequestClaude PullRequestReview CodexSolver Nothing defaultWorkflowConfig (pullRequestCell defaultRoster PullRequestClaude PullRequestReview) Nothing Nothing ResumeAnswer "" aggregator (\event -> modifyIORef events (event :))
            collected <- reverse <$> readIORef events
            let notices = [agentEvent | PullRequestFlowOutput _ agentEvent <- collected, Data.Text.isPrefixOf "[event] telemetry" agentEvent.agentEventSummary]
            length notices `shouldBe` unknownNoticeSamples + 1
            notices `shouldSatisfy` all ((<= maxUnknownNoticeLength) . Data.Text.length . (.agentEventSummary))
            case reverse collected of
              (PullRequestProcessFinished _ SolveCompleted : PullRequestFlowOutput _ summary : _) ->
                summary.agentEventSummary `shouldBe` "[event] telemetry ×" <> Data.Text.pack (show chattyProviderLines)
              _ -> expectationFailure "expected the aggregate summary immediately before the terminal event"
            rawTelemetryLines [path | PullRequestLogOpened _ path <- collected] `shouldReturn` chattyProviderLines

-- | The tracked template GitHub pre-fills a new pull-request body with. Bound
-- here so a failing origin example names the file rather than only the parser
-- result. Paired with @tools\/test_pull_request_template.py@, which runs both
-- packaged coordinators' parser over the same file.
pullRequestTemplatePath :: FilePath
pullRequestTemplatePath = ".github/pull_request_template.md"

-- | An approved, non-draft pull request: in Done under the default
-- label-based approval mode, with nothing wrong with it yet.
approvedFixture :: PullRequest
approvedFixture = basePullRequest 900 [] False [approvalLabelChip]

approvalLabelChip :: Label
approvalLabelChip = Label "reviewed:approve" "0e8a16"

withLabels :: [Label] -> PullRequest
withLabels labels = approvedFixture {pullRequestLabels = labels}

-- | A discovered persistent worker carrying the given PR task, which is all
-- 'recoveredPullRequestSession' reads: the paths are never touched by the
-- pure reattach it performs.
repairWorkerDescriptor :: PullRequestWorkerTask -> WorkerDescriptor
repairWorkerDescriptor task =
  WorkerDescriptor
    { workerDescriptorSpec =
        WorkerSpec
          { workerId = WorkerId "pr-900-repair",
            workerRepository = Repository "/tmp/repo" "coghex" "kanban",
            workerTask = PullRequestWorkerTaskKind task,
            workerExistingSession = Just "repair-session",
            workerExistingLogPath = Just "/tmp/repair.jsonl",
            workerResumeProvenance = ResumeAnswer,
            workerUserMessage = "",
            workerParent = Nothing,
            workerCreatedAt = epoch,
            workerMaxRuntimeSeconds = 60,
            workerConfigPath = Nothing,
            workerWorkflowConfig = defaultWorkflowConfig,
            -- A worker whose spec predates the recorded field: what the
            -- reattach reads, and what its first resume then resolves once
            -- and records.
            workerAssignment = Nothing,
            workerExpectedTarget = Nothing
          },
      workerDescriptorSpecPath = "/tmp/pr-900-repair.spec.json",
      workerDescriptorRosterPath = "/tmp/pr-900-repair.roster.toml",
      workerDescriptorEventPath = "/tmp/pr-900-repair.events.jsonl",
      workerDescriptorStatePath = "/tmp/pr-900-repair.state.json",
      workerDescriptorAckPath = "/tmp/pr-900-repair.ack",
      workerDescriptorLeasePath = "/tmp/pr-900-repair.lease",
      workerDescriptorLeaseOwnerPath = "/tmp/pr-900-repair.lease.owner",
      workerDescriptorPendingTerminationPath = "/tmp/pr-900-repair.terminating",
      workerDescriptorHandoffPath = "/tmp/pr-900-repair.handing-off",
      workerDescriptorCommandPath = "/tmp/pr-900-repair.commands.jsonl",
      workerDescriptorCommandAckPath = "/tmp/pr-900-repair.command-acks.jsonl"
    }

-- | Every route this slice migrated to the roster, with the brand
-- 'agentForAction' routes it to. Enumerated once so the default-roster and
-- non-default-roster arms cannot cover different sets.
migratedRoutes :: [(PullRequestOrigin, PullRequestAction, SolverBrand)]
migratedRoutes =
  [ (PullRequestCodex, PullRequestReview, ClaudeSolver),
    (PullRequestCodex, PullRequestRevision, CodexSolver),
    (PullRequestClaude, PullRequestRevision, ClaudeSolver),
    (PullRequestClaude, PullRequestRereview, CodexSolver),
    (PullRequestCodex, PullRequestRepair, CodexSolver),
    (PullRequestClaude, PullRequestRepair, ClaudeSolver)
  ]

assertRosterDrivenArguments :: ModelRoster -> (PullRequestOrigin, PullRequestAction, SolverBrand) -> Expectation
assertRosterDrivenArguments roster (origin, action, brand) = do
  agentForAction DualMode origin action `shouldBe` brand
  let arguments = pullRequestArgumentsOn roster 42 origin action brand Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig Nothing ResumeAnswer ""
      cell = pullRequestCell roster origin action
  arguments `shouldContain` (if brand == CodexSolver then codexFlags cell else claudeFlags cell)

codexFlags :: Assignment -> [String]
codexFlags cell =
  [ "--model",
    Data.Text.unpack cell.assignmentModel,
    "--config",
    Data.Text.unpack ("model_reasoning_effort=\"" <> cell.assignmentEffort <> "\"")
  ]

claudeFlags :: Assignment -> [String]
claudeFlags cell = ["--model", Data.Text.unpack cell.assignmentModel, "--effort", Data.Text.unpack cell.assignmentEffort]

-- | The one wrapper every argv assertion goes through, taking the roster
-- explicitly so no expectation can silently read a compiled literal.
pullRequestArgumentsOn :: ModelRoster -> Int -> PullRequestOrigin -> PullRequestAction -> SolverBrand -> Maybe FilePath -> Repository -> WorkflowConfig -> Maybe Data.Text.Text -> ResumeProvenance -> Data.Text.Text -> [String]
pullRequestArgumentsOn roster number origin action brand configPath repository config =
  pullRequestArguments number origin action brand configPath repository config (pullRequestCell roster origin action)

pullRequestCell :: ModelRoster -> PullRequestOrigin -> PullRequestAction -> Assignment
pullRequestCell roster origin action = recordedAssignmentCell (cellOf (pullRequestAssignment roster origin action))
