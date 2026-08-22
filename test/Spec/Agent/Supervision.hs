-- | Ownership, deadlines and capture bounds for the subprocesses the review
-- and worker layers supervise.
module Spec.Agent.Supervision (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (void)
import qualified Data.ByteString.Char8 as ByteString
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text
import Kanban.Models (defaultRoster)
import Kanban.Process (killManagedProcess)
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..))
import Kanban.Review
  ( CommandBounds (..),
    GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    attachToolProcess,
    drainToolRegistry,
    killThreadToolProcesses,
    newReviewClientForTesting,
    newToolRegistry,
    releaseToolSlot,
    reserveToolSlot,
    githubCommandBounds,
    runGitHubIssueTool,
    stopReviewClient,
    withReservedToolSlot
  )
import Kanban.Solve (ResumeProvenance (..), SolveOutcome (..), SolveWorkflow (..), SolverBrand (..))
import Kanban.UI.Events (killSelectionNotice)
import Kanban.UI.Review (canonicalReviewActivity, canonicalReviewNotice)
import Kanban.UI.Session (sessionAlreadyResolved)
import Kanban.UI.SessionCore (newAgentSession)
import Kanban.UI.Types
  ( ChatTranscript (..),
    PullRequestDetail (..),
    PullRequestReviewSession,
    SolveDetail (..),
    SolvePhase (..),
    SolveSession,
  )
import Kanban.UI.Util (failureActivity)
import Kanban.UI.Worker (orphanMessage)
import Kanban.Worker (workerDeadlineReason)
import Spec.Support.Env (waitForFileToExist, withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Expect (requireJust, requireLeft, requireRight, shouldMention, shouldNotMention)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch)
import Spec.Support.Process
  ( canonicalSessionLogText,
    managedProcessFor,
    runBoundedCanonicalCommand,
    runBoundedClaudeCall,
    runBoundedGitHubTool,
    shouldRecordASweptProcess,
    withFakeCanonicalReviewer,
    withFakeClaudeCli,
    withFakeGitHubCli,
    withManagedShell
  )
import System.Directory (createDirectory)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Process (getProcessExitCode, waitForProcess)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = do
  describe "review tool process ownership" $ do
    it "keeps two overlapping same-thread invocations independently killable" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \processA ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \processB -> do
          registry <- newToolRegistry
          keyA <- requireJust "expected a reservation for invocation A" =<< reserveToolSlot registry "thread-1"
          keyB <- requireJust "expected a reservation for invocation B" =<< reserveToolSlot registry "thread-1"
          managedA <- managedProcessFor processA
          managedB <- managedProcessFor processB
          -- Under the old threadId-keyed map, the second `insert` here would
          -- have overwritten the first entry, leaving invocation A unkillable.
          attachToolProcess registry keyA managedA `shouldReturn` True
          attachToolProcess registry keyB managedB `shouldReturn` True
          killThreadToolProcesses registry "thread-1"
          timeout 3000000 (waitForProcess processA) `shouldReturn` Just (ExitFailure (-9))
          timeout 3000000 (waitForProcess processB) `shouldReturn` Just (ExitFailure (-9))

    it "leaves a same-thread sibling registered once one overlapping invocation completes" $
      withManagedShell "true" $ \quickProcess ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \longProcess -> do
          registry <- newToolRegistry
          keyA <- requireJust "expected a reservation for the quick invocation" =<< reserveToolSlot registry "thread-1"
          keyB <- requireJust "expected a reservation for the long invocation" =<< reserveToolSlot registry "thread-1"
          quickManaged <- managedProcessFor quickProcess
          longManaged <- managedProcessFor longProcess
          attachToolProcess registry keyA quickManaged `shouldReturn` True
          attachToolProcess registry keyB longManaged `shouldReturn` True
          -- Invocation A completes naturally and deregisters itself, exactly
          -- as 'runAuthenticatedClaude'/'runGitHubCommand' do after success --
          -- under the old threadId-keyed map this `delete` would have
          -- untracked invocation B too.
          timeout 3000000 (waitForProcess quickProcess) `shouldReturn` Just ExitSuccess
          releaseToolSlot registry keyA
          remaining <- drainToolRegistry registry
          length remaining `shouldBe` 1
          mapM_ killManagedProcess remaining
          timeout 3000000 (waitForProcess longProcess) `shouldReturn` Just (ExitFailure (-9))

    it "kills every invocation owned by a thread without disturbing another thread's entry" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \processA ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \processB ->
          withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \otherThreadProcess -> do
            registry <- newToolRegistry
            keyA <- requireJust "expected a reservation for thread-1's first invocation" =<< reserveToolSlot registry "thread-1"
            keyB <- requireJust "expected a reservation for thread-1's second invocation" =<< reserveToolSlot registry "thread-1"
            otherKey <- requireJust "expected a reservation for thread-2" =<< reserveToolSlot registry "thread-2"
            managedA <- managedProcessFor processA
            managedB <- managedProcessFor processB
            otherManaged <- managedProcessFor otherThreadProcess
            attachToolProcess registry keyA managedA `shouldReturn` True
            attachToolProcess registry keyB managedB `shouldReturn` True
            attachToolProcess registry otherKey otherManaged `shouldReturn` True
            killThreadToolProcesses registry "thread-1"
            timeout 3000000 (waitForProcess processA) `shouldReturn` Just (ExitFailure (-9))
            timeout 3000000 (waitForProcess processB) `shouldReturn` Just (ExitFailure (-9))
            getProcessExitCode otherThreadProcess `shouldReturn` Nothing
            remaining <- drainToolRegistry registry
            length remaining `shouldBe` 1

    it "never lets a spawn that races full client shutdown escape the shutdown drain" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        registry <- newToolRegistry
        key <- requireJust "expected a reservation before shutdown begins" =<< reserveToolSlot registry "thread-1"
        -- Shutdown begins (and finds nothing to drain yet, since the process
        -- has not spawned/attached) while the reservation is still pending.
        drained <- drainToolRegistry registry
        length drained `shouldBe` 0
        managed <- managedProcessFor process
        -- The spawn that raced shutdown discovers its reservation is gone
        -- and must kill what it just started itself.
        attachToolProcess registry key managed `shouldReturn` False
        killManagedProcess managed
        timeout 3000000 (waitForProcess process) `shouldReturn` Just (ExitFailure (-9))
        -- The registry stays closed: no later invocation can register either.
        reserveToolSlot registry "thread-1" `shouldReturn` Nothing

    it "never lets a spawn that races same-thread cancellation escape, while leaving the registry open for later work" $
      withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \process -> do
        registry <- newToolRegistry
        key <- requireJust "expected a reservation before the cancellation lands" =<< reserveToolSlot registry "thread-1"
        killThreadToolProcesses registry "thread-1"
        managed <- managedProcessFor process
        attachToolProcess registry key managed `shouldReturn` False
        killManagedProcess managed
        timeout 3000000 (waitForProcess process) `shouldReturn` Just (ExitFailure (-9))
        -- Unlike full shutdown, a per-thread cancellation does not close the
        -- registry: later work on the same thread still registers normally.
        laterReservation <- reserveToolSlot registry "thread-1"
        laterReservation `shouldSatisfy` isJust

    it "still fences a same-thread cancellation landing between the sequential gh subprocesses of one GitHub update" $
      withManagedShell "true" $ \firstProcess ->
        withManagedShell "trap '' TERM; while :; do sleep 1; done" $ \secondProcess -> do
          registry <- newToolRegistry
          -- One reservation spans the *whole* multi-step GitHub update, the
          -- same way 'withReservedToolSlot' holds a single key across every
          -- subprocess of 'runGitHubIssueUpdate' (e.g. the issue comment,
          -- then the label edit) -- not one reservation per subprocess.
          key <- requireJust "expected a reservation for the whole update" =<< reserveToolSlot registry "thread-1"
          -- Subprocess 1 (e.g. the issue comment) runs to completion
          -- normally and its leader is swept, but the reservation itself is
          -- not released yet, since more subprocesses may still follow.
          managedOne <- managedProcessFor firstProcess
          attachToolProcess registry key managedOne `shouldReturn` True
          timeout 3000000 (waitForProcess firstProcess) `shouldReturn` Just ExitSuccess
          killManagedProcess managedOne
          -- A same-thread cancellation lands in the gap before subprocess 2
          -- (e.g. the label edit) ever spawns.
          killThreadToolProcesses registry "thread-1"
          -- Subprocess 2 reuses that very same reservation key and finds it
          -- already drained, so it must kill what it just spawned itself
          -- instead of running as though the cancellation never happened.
          managedTwo <- managedProcessFor secondProcess
          attachToolProcess registry key managedTwo `shouldReturn` False
          killManagedProcess managedTwo
          timeout 3000000 (waitForProcess secondProcess) `shouldReturn` Just (ExitFailure (-9))

    it "terminates a fake gh invocation that is still in flight when the client shuts down" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        let repositoryRoot = temporaryRoot </> "repo"
            binaryRoot = temporaryRoot </> "bin"
            fakeGh = binaryRoot </> "gh"
            markerPath = temporaryRoot </> "gh-started"
        createDirectory repositoryRoot
        createDirectory binaryRoot
        ByteString.writeFile
          fakeGh
          ( ByteString.unlines
              [ "#!/bin/sh",
                "touch \"$STARTED_MARKER\"",
                "trap '' TERM",
                "while :; do sleep 1; done"
              ]
          )
        setFileMode fakeGh 0o700
        originalPath <- maybe "" id <$> lookupEnv "PATH"
        withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $
          withEnvironmentValue "STARTED_MARKER" markerPath $ do
            client <- newReviewClientForTesting defaultRoster githubCommandBounds repositoryRoot "coghex/kanban" (const (pure ()))
            finished <- newEmptyMVar
            let request = GitHubIssueToolRequest GitHubIssueRead 844 Nothing [] []
            void . forkIO $ withReservedToolSlot client "thread-1" (\key -> runGitHubIssueTool client key request) >>= putMVar finished
            waitForFileToExist markerPath 50
            stopReviewClient client
            result <- timeout 5000000 (takeMVar finished)
            case result of
              Just (Left _) -> pure ()
              other -> expectationFailure ("expected the in-flight gh call to fail once the client shut down, got " <> show other)

  describe "review subprocess deadline and capture bounds" $ do
    let injectedBounds = CommandBounds {commandDeadlineMicros = 3000000, commandCaptureGraceMicros = 400000}
        -- Every call below runs under this bound. It is generous next to
        -- what these calls actually cost -- the injected deadline plus the
        -- injected capture grace plus 'killManagedProcess'' own 750 ms
        -- termination grace, twice over for the two-subprocess updates --
        -- so a loaded CI runner cannot trip it. What matters is that it
        -- stays far under the 30 s the pipe-holding children in these
        -- fixtures live for: a runner that still waited on a capture worker
        -- it cannot unblock would hang until then, and so trips this bound
        -- instead of quietly passing once the child finally exits.
        boundedCallMicros = 10000000
        commentUrl = "https://example.invalid/coghex/kanban/issues/15#issuecomment-7"
        postComment = "printf '%s\\n' '" <> ByteString.pack (Data.Text.unpack commentUrl) <> "'"

    it "round-trips an ordinary fast gh read unchanged" $
      withFakeGitHubCli ["printf '%s' '{\"number\":15}'"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueRead 15 Nothing [] [])
        result `shouldBe` Right "{\"number\":15}"

    it "reports a mutation whose stdout a forked child holds open past the deadline as outcome-unknown, never as a timeout" $
      withFakeGitHubCli ["sleep 30 &", postComment, "exit 0"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueUpdate 15 (Just "body") [] [])
        message <- requireLeft "expected the truncated comment post to be reported as outcome-unknown" result
        message `shouldMention` "outcome is unknown"
        message `shouldMention` "may already have completed"
        message `shouldMention` "posting the issue comment"
        message `shouldMention` "with this tool"
        message `shouldNotMention` "timed out"

    it "still succeeds when only stderr is held open past the deadline and stdout arrived complete" $
      withFakeGitHubCli ["sleep 30 >/dev/null &", postComment, "exit 0"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueUpdate 15 (Just "body") [] [])
        output <- requireRight "expected a clean exit with complete stdout to succeed despite unfinished stderr capture" result
        output `shouldMention` commentUrl

    it "keeps an observed nonzero exit a nonzero-exit failure even when capture is still held open" $
      withFakeGitHubCli ["sleep 30 &", "printf 'boom\\n' >&2", "exit 3"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueRead 15 Nothing [] [])
        message <- requireLeft "expected a nonzero exit to stay a nonzero-exit failure" result
        message `shouldMention` "exited with status 3"
        message `shouldNotMention` "outcome is unknown"

    it "tells the model to verify current state before retrying when a comment post outlives the deadline" $
      withFakeGitHubCli ["sleep 30"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueUpdate 15 (Just "body") [] [])
        message <- requireLeft "expected an unfinished comment post to be reported as outcome-unknown" result
        message `shouldMention` "did not exit within"
        message `shouldMention` "outcome is unknown"
        message `shouldMention` "Re-read the issue and its labels with this tool"

    it "leaves an ordinary read unaffected, reporting a plain failure with no verify-before-retry instruction" $
      withFakeGitHubCli ["sleep 30"] injectedBounds $ \client -> do
        result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueRead 15 Nothing [] [])
        message <- requireLeft "expected an unfinished read to fail" result
        message `shouldMention` "reading issue #15"
        message `shouldNotMention` "with this tool"
        message `shouldNotMention` "may already have completed"

    it "preserves a known-successful comment when the following label edit's outcome is unknown, without calling it failed" $
      withFakeGitHubCli
        [ "if [ \"$1\" = \"issue\" ] && [ \"$2\" = \"comment\" ]; then",
          postComment,
          "exit 0",
          "fi",
          "sleep 30"
        ]
        injectedBounds
        $ \client -> do
          result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueUpdate 15 (Just "body") ["reviewed:approve"] ["reviewed:changes"])
          message <- requireLeft "expected the unfinished label edit to be reported as outcome-unknown" result
          message `shouldMention` ("The issue comment was posted at " <> commentUrl)
          message `shouldMention` "updating the issue labels"
          message `shouldMention` "outcome is unknown"
          message `shouldMention` "with this tool"
          message `shouldNotMention` "failed"

    it "reports the forced reviewed:revised label creation as outcome-unknown when it outlives the deadline" $
      withFakeGitHubCli
        [ "if [ \"$1\" = \"issue\" ] && [ \"$2\" = \"comment\" ]; then",
          postComment,
          "exit 0",
          "fi",
          "sleep 30"
        ]
        injectedBounds
        $ \client -> do
          result <- runBoundedGitHubTool boundedCallMicros client (GitHubIssueToolRequest GitHubIssueUpdate 15 (Just "body") ["reviewed:revised"] [])
          message <- requireLeft "expected the unfinished label creation to be reported as outcome-unknown" result
          message `shouldMention` ("The issue comment was posted at " <> commentUrl)
          message `shouldMention` "creating the reviewed:revised label"
          message `shouldMention` "outcome is unknown"
          message `shouldNotMention` "failed"

    it "round-trips a fast canonical review unchanged, still logging both captured streams" $
      withFakeCanonicalReviewer ["printf '%s' '{\"approved\":true}'", "printf 'reviewer diagnostic\\n' >&2"] $ \cacheRoot repository reviewerPath -> do
        result <- runBoundedCanonicalCommand boundedCallMicros injectedBounds repository reviewerPath
        result `shouldBe` Right "{\"approved\":true}"
        logged <- canonicalSessionLogText cacheRoot
        logged `shouldSatisfy` isInfixOf "{\\\"approved\\\":true}"
        logged `shouldSatisfy` isInfixOf "reviewer diagnostic"

    it "reports a canonical review whose stdout a forked child holds open as outcome-unknown, never as a timeout" $
      withFakeCanonicalReviewer ["sleep 30 &", "printf '%s' '{\"approved\":true}'"] $ \_ repository reviewerPath -> do
        result <- runBoundedCanonicalCommand boundedCallMicros injectedBounds repository reviewerPath
        message <- requireLeft "expected truncated canonical stdout to be reported as outcome-unknown" result
        message `shouldMention` "still incomplete after"
        message `shouldMention` "outcome is unknown"
        message `shouldNotMention` "timed out"

    it "still decodes a canonical review whose stderr alone is held open past the deadline" $
      withFakeCanonicalReviewer ["sleep 30 >/dev/null &", "printf '%s' '{\"approved\":true}'"] $ \_ repository reviewerPath -> do
        result <- runBoundedCanonicalCommand boundedCallMicros injectedBounds repository reviewerPath
        result `shouldBe` Right "{\"approved\":true}"

    it "gives canonical outcome-unknown guidance without any same-tool reread instruction" $
      withFakeCanonicalReviewer ["sleep 30"] $ \_ repository reviewerPath -> do
        result <- runBoundedCanonicalCommand boundedCallMicros injectedBounds repository reviewerPath
        message <- requireLeft "expected an unfinished canonical review to be reported as outcome-unknown" result
        message `shouldMention` "did not exit within"
        message `shouldMention` "outcome is unknown"
        message `shouldMention` "Check the issue's current comments and labels"
        message `shouldNotMention` "this tool"

    it "renders a canonical outcome-unknown result to the operator without claiming the review failed" $ do
      unknown <-
        withFakeCanonicalReviewer ["sleep 30"] $ \_ repository reviewerPath ->
          requireLeft "expected an unfinished canonical review to be reported as outcome-unknown"
            =<< runBoundedCanonicalCommand boundedCallMicros injectedBounds repository reviewerPath
      canonicalReviewActivity unknown `shouldBe` "outcome unknown"
      canonicalReviewNotice unknown `shouldNotMention` "failed"
      canonicalReviewNotice unknown `shouldMention` "could not be observed"
      canonicalReviewActivity "python3 was not found on PATH" `shouldBe` "failed"
      canonicalReviewNotice "python3 was not found on PATH" `shouldBe` "Canonical issue review failed: python3 was not found on PATH"

    -- The Claude reviewer was the third short-lived runner in this module and
    -- the one #15 never enumerated, so it kept the very hGetContents-plus-
    -- takeMVar shape that fix existed to remove (issue #154). Its answer is
    -- prose read by a model rather than a URL or a JSON verdict, so unlike the
    -- two runners above a truncated capture stays a *success* carrying what
    -- arrived -- but it is never a timeout, and never outcome-unknown.
    it "round-trips an ordinary fast claude reviewer call unchanged" $
      withFakeClaudeCli ["printf '%s' 'reviewer answer'"] injectedBounds $ \_ client -> do
        result <- runBoundedClaudeCall boundedCallMicros client "review this"
        result `shouldBe` Right "reviewer answer"

    it "returns the prefix captured before the grace expired when a forked child holds claude's stdout open, never a timeout" $
      withFakeClaudeCli
        [ "sleep 30 &",
          "echo $! > \"$CLAUDE_CHILD_MARKER\"",
          "printf '%s' 'partial verdict'",
          "exit 0"
        ]
        injectedBounds
        $ \markerPath client -> do
          result <- runBoundedClaudeCall boundedCallMicros client "review this"
          output <- requireRight "expected a clean exit with truncated stdout to keep what was captured" result
          output `shouldMention` "partial verdict"
          output `shouldMention` "Incomplete output"
          output `shouldMention` "still incomplete after"
          output `shouldNotMention` "timed out"
          -- The marker this path must not carry: 'CommandExited' already
          -- established the exit, and the run is read-only, so there is
          -- neither an unknown outcome nor anything to re-verify.
          output `shouldNotMention` "outcome is unknown"
          output `shouldNotMention` "may already have completed"
          markerPath `shouldRecordASweptProcess` "the child holding claude's stdout open"

    it "describes an incomplete capture that yielded nothing as incomplete rather than as no output" $
      withFakeClaudeCli
        [ "sleep 30 &",
          "echo $! > \"$CLAUDE_CHILD_MARKER\"",
          "exit 0"
        ]
        injectedBounds
        $ \_ client -> do
          result <- runBoundedClaudeCall boundedCallMicros client "review this"
          output <- requireRight "expected an empty truncated capture to still be reported as incomplete" result
          output `shouldMention` "Incomplete output"
          output `shouldMention` "nothing had been captured"
          output `shouldNotMention` "Claude returned no reviewer output"
          output `shouldNotMention` "timed out"

    it "still reports a claude reviewer that outlives its own deadline as a timeout, sweeping its process group" $
      withFakeClaudeCli ["echo $$ > \"$CLAUDE_CHILD_MARKER\"", "sleep 30"] injectedBounds $ \markerPath client -> do
        result <- runBoundedClaudeCall boundedCallMicros client "review this"
        message <- requireLeft "expected a claude reviewer past its deadline to time out" result
        message `shouldBe` "Claude Sonnet 5 revision agent timed out after ten minutes"
        markerPath `shouldRecordASweptProcess` "the claude reviewer that outlived its deadline"

    it "still succeeds unchanged when only claude's stderr is held open past the grace" $
      withFakeClaudeCli ["sleep 30 >/dev/null &", "printf '%s' 'complete verdict'", "exit 0"] injectedBounds $ \_ client -> do
        result <- runBoundedClaudeCall boundedCallMicros client "review this"
        result `shouldBe` Right "complete verdict"

    it "keeps an observed nonzero claude exit a status failure carrying whatever prefixes were captured" $
      withFakeClaudeCli ["sleep 30 &", "printf 'boom\\n' >&2", "exit 3"] injectedBounds $ \_ client -> do
        result <- runBoundedClaudeCall boundedCallMicros client "review this"
        message <- requireLeft "expected a nonzero claude exit to stay a nonzero-exit failure" result
        message `shouldMention` "Claude Sonnet 5 exited with status 3"
        message `shouldMention` "boom"
        message `shouldNotMention` "Incomplete output"
        message `shouldNotMention` "timed out"

  describe "persistent worker deadline UI projections" $ do
    it "renders the deadline reason distinctly from a generic provider failure" $ do
      failureActivity workerDeadlineReason `shouldBe` "deadline exceeded"
      failureActivity "some other unexpected failure" `shouldBe` "failed"

    it "renders the deadline reason distinctly for orphan-pending subprocesses, for both solve and PR workers" $ do
      orphanMessage (SolveFailed workerDeadlineReason) "2" "the solver"
        `shouldBe` "deadline exceeded; 2 subprocesses survived termination; press x to terminate the orphaned process tree"
      orphanMessage SolveCompleted "2" "the solver"
        `shouldBe` "2 subprocesses survived the solver; press x to terminate the orphaned process tree"
      orphanMessage (SolveFailed workerDeadlineReason) "1" "the PR agent"
        `shouldBe` "deadline exceeded; 1 subprocesses survived termination; press x to terminate the orphaned process tree"
      orphanMessage SolveCompleted "1" "the PR agent"
        `shouldBe` "1 subprocesses survived the PR agent; press x to terminate the orphaned process tree"

    it "tells an operator with nothing selected to press the kill binding rather than the select-previous binding" $ do
      -- The board dispatches the kill on 'x'; 'k' selects the previous card,
      -- so a notice naming 'k' silently moves the selection instead. The Esc
      -- and Ctrl-L halves of this keyboard-contract fix dispatch in brick's
      -- 'EventM' (and Ctrl-L needs a live Vty handle), which no unit test
      -- here can drive; they stay covered by the manual checks in the PR.
      killSelectionNotice `shouldMention` "pressing x"
      killSelectionNotice `shouldNotMention` "pressing k"
      killSelectionNotice `shouldBe` "Select a working issue or PR before pressing x"

    it "suppresses a late WorkerAgentOutput/WorkerDiagnostic projection once a solve or PR session has already resolved" $ do
      -- 'applyWorkerProtocolEvent' cannot be exercised directly in a unit
      -- test (it runs in brick's 'EventM', which exposes no way to run an
      -- action against a plain state outside a live Vty event loop); this
      -- instead directly covers 'sessionAlreadyResolved', the pure
      -- predicate solve and PR sessions now share, which
      -- decides whether a trailing 'WorkerAgentOutput'/'WorkerDiagnostic'
      -- event -- which 'streamOutput'/'streamDiagnostics' can still emit
      -- after the watchdog has already committed 'WorkerOrphansDetected' or
      -- 'WorkerFinished' -- gets applied at all.
      let solveSessionWith :: SolvePhase -> SolveSession
          solveSessionWith phase =
            newAgentSession
              0
              phase
              "thinking"
              (Just epoch)
              (ChatTranscript "" "" "")
              SolveDetail
                { solveSessionIssue = baseIssue 787 [],
                  solveSessionWorkflow = SolveOnly,
                  solveSessionBrand = CodexSolver,
                  solveSessionId = Nothing,
                  solveSessionAutoProgress = Nothing,
                  solveSessionResumeProvenance = ResumeAnswer
                }
          solveSessionsWith phase = Map.fromList [(787, solveSessionWith phase)]
      mapM_
        (\phase -> sessionAlreadyResolved 787 (solveSessionsWith phase) `shouldBe` True)
        [SolveFinished, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
      mapM_
        (\phase -> sessionAlreadyResolved 787 (solveSessionsWith phase) `shouldBe` False)
        [SolveStarting, SolveRunning, SolveInterrupting, SolveAttention]
      sessionAlreadyResolved 999 (solveSessionsWith SolveFinished) `shouldBe` False
      let pullRequestSessionWith :: SolvePhase -> PullRequestReviewSession
          pullRequestSessionWith phase =
            newAgentSession
              0
              phase
              "thinking"
              (Just epoch)
              (ChatTranscript "" "" "")
              PullRequestDetail
                { pullRequestSessionPullRequest = basePullRequest 826 [] False [],
                  pullRequestSessionOrigin = PullRequestCodex,
                  pullRequestSessionAction = PullRequestReview,
                  pullRequestSessionLaunchedForUpdatedAt = epoch,
                  pullRequestSessionBrand = CodexSolver,
                  pullRequestSessionId = Nothing,
                  pullRequestSessionResumeProvenance = ResumeAnswer
                }
          pullRequestSessionsWith phase = Map.fromList [(826, pullRequestSessionWith phase)]
      mapM_
        (\phase -> sessionAlreadyResolved 826 (pullRequestSessionsWith phase) `shouldBe` True)
        [SolveFinished, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
      mapM_
        (\phase -> sessionAlreadyResolved 826 (pullRequestSessionsWith phase) `shouldBe` False)
        [SolveStarting, SolveRunning, SolveInterrupting, SolveAttention]
      sessionAlreadyResolved 999 (pullRequestSessionsWith SolveFinished) `shouldBe` False
