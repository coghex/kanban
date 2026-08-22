-- | What the review session's dynamic tools actually run: the @gh@
-- invocations behind @kanban_github_issue@ and the authenticated @claude@
-- invocation behind @kanban_run_claude@, with the argument builders,
-- production bounds, and outcome rendering each needs.
--
-- Dispatch stays in "Kanban.Review" — deciding that a wire request is a
-- tool call, and answering it, is app-server protocol work. This module is
-- reached only through a 'ReviewClient', which is why it sits above
-- "Kanban.Review.Client".
module Kanban.Review.Tools
  ( claudeCommandBounds,
    githubActionSummary,
    githubCommandBounds,
    githubIssueCommentArguments,
    githubIssueEditArguments,
    githubIssueViewArguments,
    githubLabelCreateArguments,
    authenticatedClaudeArguments,
    issueReviseAssignment,
    runAuthenticatedClaude,
    runGitHubIssueTool,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Kanban.CommandCapture
  ( CommandBounds (..),
    CommandOutcome (..),
    StreamCaptureResult (..),
    awaitCommandOutcome,
    captureGraceMicros,
    capturedBytes,
    releaseCapture,
    renderWindow,
    startCapture,
  )
import Kanban.Models
  ( Assignment (..),
    AssignmentUnavailable,
    ModelRoster,
    ProviderName (..),
    RoleName (..),
    assignmentFor,
    assignmentUnavailableMessage,
  )
import Kanban.Process (killManagedProcess, managedProcess)
import Kanban.Review.Client (ReviewClient (..), attachToolProcess)
import Kanban.Review.Diagnostics
  ( decodeClaudeBytes,
    exceptionText,
    outcomeUnknownMessage,
    renderClaudeFailureDetails,
  )
import Kanban.Review.Types
  ( GitHubIssueOperation (..),
    GitHubIssueToolRequest (..),
    ReviewEvent (..),
  )
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    proc,
  )

githubActionSummary :: GitHubIssueToolRequest -> Text
githubActionSummary request = case request.githubToolOperation of
  GitHubIssueRead -> "Reading issue #" <> Text.pack (show request.githubToolIssue) <> " and its comments…"
  GitHubIssueUpdate ->
    "Updating issue #"
      <> Text.pack (show request.githubToolIssue)
      <> mutationSummary
  where
    mutationSummary
      | request.githubToolComment /= Nothing = " comment and review labels…"
      | otherwise = " review labels…"

runGitHubIssueTool :: ReviewClient -> Int -> GitHubIssueToolRequest -> IO (Either Text Text)
runGitHubIssueTool client key request = do
  executable <- findExecutable "gh"
  case executable of
    Nothing -> pure (Left "GitHub CLI was not found on PATH")
    Just ghPath -> case request.githubToolOperation of
      GitHubIssueRead -> fmap readOutcome (runGitHubCommand client key ghPath (githubIssueViewArguments client.reviewRepositorySlug request.githubToolIssue) "")
      GitHubIssueUpdate -> runGitHubIssueUpdate client key ghPath request
  where
    -- A read has no side effect to reconcile, so an unobserved read is an
    -- ordinary failure the model may simply reissue -- it must not carry the
    -- verify-current-state-before-retry instruction the mutations below
    -- need, which would only tell the model to redo the read it just failed.
    readOutcome (GitHubCommandSucceeded output) = Right output
    readOutcome (GitHubCommandFailed message) = Left message
    readOutcome (GitHubCommandUnobserved observation) =
      Left (observation <> " while reading issue #" <> Text.pack (show request.githubToolIssue) <> ".")

-- | Explicit --repo on every GitHub CLI invocation below, so the dashboard's
-- resolved repository identity (which may come from an explicit --repo
-- override, e.g. reviewing upstream from a fork checkout) is never silently
-- re-derived by `gh` from the checkout's own remote.
githubIssueViewArguments :: Text -> Int -> [String]
githubIssueViewArguments repo issueNumber =
  [ "issue",
    "view",
    show issueNumber,
    "--repo",
    Text.unpack repo,
    "--json",
    "number,title,body,url,state,labels,comments"
  ]

githubIssueCommentArguments :: Text -> Int -> [String]
githubIssueCommentArguments repo issueNumber =
  ["issue", "comment", show issueNumber, "--repo", Text.unpack repo, "--body-file", "-"]

githubLabelCreateArguments :: Text -> [String]
githubLabelCreateArguments repo =
  [ "label",
    "create",
    "reviewed:revised",
    "--repo",
    Text.unpack repo,
    "--color",
    "8250DF",
    "--description",
    "Specification amended and awaiting opposite-brand rereview",
    "--force"
  ]

githubIssueEditArguments :: Text -> GitHubIssueToolRequest -> [String]
githubIssueEditArguments repo request = baseArguments <> addArguments <> removeArguments
  where
    baseArguments = ["issue", "edit", show request.githubToolIssue, "--repo", Text.unpack repo]
    addArguments
      | null request.githubToolAddLabels = []
      | otherwise = ["--add-label", Text.unpack (Text.intercalate "," request.githubToolAddLabels)]
    removeArguments
      | null request.githubToolRemoveLabels = []
      | otherwise = ["--remove-label", Text.unpack (Text.intercalate "," request.githubToolRemoveLabels)]

-- | Why one step of a multi-step GitHub update did not complete. The
-- distinction is the whole point of issue #15: a definite failure did not
-- mutate anything, whereas an unobserved step may well have landed, so it
-- must never be described as failed and must always tell the model to check
-- current state before it retries.
data MutationFailure
  = MutationFailed Text
  | MutationUnobserved Text

runGitHubIssueUpdate :: ReviewClient -> Int -> FilePath -> GitHubIssueToolRequest -> IO (Either Text Text)
runGitHubIssueUpdate client key ghPath request = do
  commentResult <- case request.githubToolComment of
    Nothing -> pure (Right Nothing)
    Just comment -> do
      outcome <- runGitHubCommand client key ghPath (githubIssueCommentArguments client.reviewRepositorySlug request.githubToolIssue) comment
      pure $ case mutationOutcome outcome of
        Right commentUrl -> Right (Just (Text.strip commentUrl))
        Left failure -> Left (renderMutationFailure Nothing "posting the issue comment" failure)
  case commentResult of
    Left message -> pure (Left message)
    Right commentUrl -> do
      labelResult <- ensureRevisedLabel client key ghPath request.githubToolAddLabels
      case labelResult of
        Left failure -> pure (Left (renderMutationFailure commentUrl "creating the reviewed:revised label" failure))
        Right () -> do
          edited <- applyReviewLabels client key ghPath request
          pure $ case edited of
            Left failure -> Left (renderMutationFailure commentUrl "updating the issue labels" failure)
            Right _ -> Right (githubUpdateResult commentUrl request)

ensureRevisedLabel :: ReviewClient -> Int -> FilePath -> [Text] -> IO (Either MutationFailure ())
ensureRevisedLabel client key ghPath labels
  | "reviewed:revised" `notElem` labels = pure (Right ())
  | otherwise = fmap (fmap (const ()) . mutationOutcome) (runGitHubCommand client key ghPath (githubLabelCreateArguments client.reviewRepositorySlug) "")

applyReviewLabels :: ReviewClient -> Int -> FilePath -> GitHubIssueToolRequest -> IO (Either MutationFailure Text)
applyReviewLabels client key ghPath request
  | null request.githubToolAddLabels && null request.githubToolRemoveLabels = pure (Right "")
  | otherwise = fmap mutationOutcome (runGitHubCommand client key ghPath (githubIssueEditArguments client.reviewRepositorySlug request) "")

mutationOutcome :: GitHubCommandOutcome -> Either MutationFailure Text
mutationOutcome (GitHubCommandSucceeded output) = Right output
mutationOutcome (GitHubCommandFailed message) = Left (MutationFailed message)
mutationOutcome (GitHubCommandUnobserved observation) = Left (MutationUnobserved observation)

githubUpdateResult :: Maybe Text -> GitHubIssueToolRequest -> Text
githubUpdateResult commentUrl request =
  TextEncoding.decodeUtf8
    . LazyByteString.toStrict
    . encode
    $ object
      [ "issue" .= request.githubToolIssue,
        "commentUrl" .= commentUrl,
        "addedLabels" .= request.githubToolAddLabels,
        "removedLabels" .= request.githubToolRemoveLabels
      ]

-- | The model-facing message for a GitHub update that did not run to
-- completion, keeping whatever is already *known* to have landed (the
-- comment URL) attached so a retry cannot silently repost it.
--
-- A definite failure keeps the existing "…, but <step> failed" wording. An
-- unobserved step deliberately does not: saying it failed would contradict
-- the very thing the message goes on to state, that the mutation may
-- already have completed. Those carry 'githubVerificationRemedy' instead,
-- so the model re-reads the issue through this same tool before deciding
-- whether there is anything left to retry.
renderMutationFailure :: Maybe Text -> Text -> MutationFailure -> Text
renderMutationFailure commentUrl step failure = case (commentUrl, failure) of
  (Nothing, MutationFailed message) -> message
  (Nothing, MutationUnobserved observation) -> unobservedDetail observation
  (Just url, MutationFailed message) ->
    "The issue comment was posted at " <> url <> ", but " <> step <> " failed: " <> message
  (Just url, MutationUnobserved observation) ->
    "The issue comment was posted at " <> url <> ". " <> unobservedDetail observation
  where
    unobservedDetail observation = outcomeUnknownMessage (observation <> " while " <> step) githubVerificationRemedy

-- | Remedy for the @kanban_github_issue@ paths, whose diagnostics are read
-- by the revision agent through the tool protocol: it holds the very tool
-- that can settle the question, so it is told to use it before retrying.
githubVerificationRemedy :: Text
githubVerificationRemedy =
  "Re-read the issue and its labels with this tool to confirm the current state before retrying anything."

-- | Spawns one @gh@ invocation and attaches it to the invocation-wide
-- reservation `key` (see 'Kanban.Review.Client.withReservedToolSlot').
-- Regardless of how this process finishes -- naturally (success or its own
-- failure), a broken input pipe, or a timeout -- it is always swept with
-- 'killManagedProcess' before returning: a leader that already exited on
-- its own can still have left a same-group child behind, and this is the
-- one point where every exit path funnels through the same recorded-pgid
-- termination, whether or not this is the last subprocess of a multi-step
-- update.
runGitHubCommand :: ReviewClient -> Int -> FilePath -> [String] -> Text -> IO GitHubCommandOutcome
runGitHubCommand client key ghPath arguments input = do
  started <- try (createProcess processSpec) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
  case started of
    Left exception -> pure (GitHubCommandFailed ("Could not start GitHub CLI: " <> exceptionText exception))
    Right (Just inputHandle, Just outputHandle, Just errorHandle, processHandle) -> do
      (managed, groupLeaderProblem) <- managedProcess processHandle
      mapM_ (\problem -> client.reviewEventSink (ReviewProtocolWarning ("process group leadership: " <> problem))) groupLeaderProblem
      attached <- attachToolProcess client.reviewToolRegistry key managed
      if not attached
        then killManagedProcess managed >> pure (GitHubCommandFailed "Review client is shutting down")
        else do
          outputCapture <- startCapture outputHandle
          errorCapture <- startCapture errorHandle
          written <- try (ByteString.hPutStr inputHandle (TextEncoding.encodeUtf8 input) >> hClose inputHandle) :: IO (Either IOException ())
          result <- case written of
            Left exception -> pure (GitHubCommandFailed ("Could not send input to GitHub CLI: " <> exceptionText exception))
            Right () -> renderGitHubCommandResult bounds <$> awaitCommandOutcome bounds processHandle outputCapture errorCapture
          releaseCapture outputCapture
          releaseCapture errorCapture
          killManagedProcess managed
          pure result
    Right _ -> pure (GitHubCommandFailed "GitHub CLI did not provide all three standard streams")
  where
    bounds = client.reviewCommandBounds
    processSpec =
      (proc ghPath arguments)
        { cwd = Just client.reviewRepositoryRoot,
          std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

-- | How one @gh@ invocation actually ended. 'GitHubCommandUnobserved'
-- carries only the neutral *observation* -- what the runner saw -- because
-- the runner alone cannot tell a harmless read from a mutation; the
-- verify-before-retry remedy is chosen by the callers above it.
data GitHubCommandOutcome
  = GitHubCommandSucceeded Text
  | GitHubCommandFailed Text
  | GitHubCommandUnobserved Text

renderGitHubCommandResult :: CommandBounds -> CommandOutcome -> GitHubCommandOutcome
renderGitHubCommandResult bounds outcome = case outcome of
  CommandUnfinished ->
    GitHubCommandUnobserved ("The GitHub CLI did not exit within " <> renderWindow bounds.commandDeadlineMicros)
  CommandExited exitCode output errors -> case (exitCode, output, errors) of
    (_, StreamUnreadable exception, _) -> GitHubCommandFailed ("Could not read GitHub CLI output: " <> exceptionText exception)
    (_, _, StreamUnreadable exception) -> GitHubCommandFailed ("Could not read GitHub CLI diagnostics: " <> exceptionText exception)
    -- An *observed* nonzero exit stays a nonzero-exit failure whatever the
    -- capture did: the command definitely did not do what was asked, so
    -- there is nothing unknown about its outcome.
    (ExitFailure code, _, _) ->
      GitHubCommandFailed
        ( "GitHub CLI exited with status "
            <> Text.pack (show code)
            <> renderClaudeFailureDetails (capturedBytes output) (capturedBytes errors)
        )
    -- Incomplete stdout is unknown even when the captured prefix happens to
    -- parse -- callers read it as a comment URL or a JSON verdict, and a
    -- truncated one of either is worse than no answer. Incomplete *stderr*
    -- alone never invalidates a clean exit with complete stdout.
    (ExitSuccess, StreamTruncated _, _) ->
      GitHubCommandUnobserved ("The GitHub CLI exited but its output was still incomplete after " <> renderWindow bounds.commandCaptureGraceMicros)
    (ExitSuccess, StreamComplete outputBytes, _) -> GitHubCommandSucceeded (decodeClaudeBytes outputBytes)

-- | Spawns the authenticated Claude CLI and attaches it to the
-- invocation-wide reservation `key` (see
-- 'Kanban.Review.Client.withReservedToolSlot'). As in 'runGitHubCommand',
-- every exit path -- natural completion, a broken input pipe, or a timeout
-- -- is swept with 'killManagedProcess' before returning, so a leader that
-- already exited on its own can't leave a same-group child unsignalled.
--
-- The cell is resolved before the CLI is even looked for: a roster that
-- loads no Claude provider must spawn nothing here rather than fall back to
-- the compiled default. The refusal is this tool's, not the whole review's —
-- a Codex-only install still reviews, it just cannot reach this tool.
runAuthenticatedClaude :: ReviewClient -> Int -> Text -> IO (Either Text Text)
runAuthenticatedClaude client key prompt = case issueReviseAssignment client.reviewModelRoster of
  Left unavailable -> pure (Left (assignmentUnavailableMessage unavailable))
  Right assignment -> runResolvedAuthenticatedClaude client key prompt assignment

-- | The cell @kanban_run_claude@ runs on: the revision role's Claude
-- provider, which 'Kanban.Models.roleApplicability' already makes the only
-- one it can run on.
issueReviseAssignment :: ModelRoster -> Either AssignmentUnavailable Assignment
issueReviseAssignment roster = assignmentFor roster IssueReviseRole ClaudeProvider

-- | The argv @kanban_run_claude@ spawns, from a resolved assignment.
authenticatedClaudeArguments :: Assignment -> [String]
authenticatedClaudeArguments assignment =
  [ "--print",
    "--model",
    Text.unpack assignment.assignmentModel,
    "--effort",
    Text.unpack assignment.assignmentEffort,
    "--permission-mode",
    "plan",
    "--safe-mode",
    "--no-session-persistence"
  ]

runResolvedAuthenticatedClaude :: ReviewClient -> Int -> Text -> Assignment -> IO (Either Text Text)
runResolvedAuthenticatedClaude client key prompt assignment = do
  executable <- findExecutable "claude"
  case executable of
    Nothing -> pure (Left "Claude CLI was not found on PATH")
    Just claudePath -> do
      started <- try (createProcess (claudeProcess claudePath)) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
      case started of
        Left exception -> pure (Left ("Could not start authenticated Claude CLI: " <> exceptionText exception))
        Right (Just inputHandle, Just outputHandle, Just errorHandle, processHandle) -> do
          (managed, groupLeaderProblem) <- managedProcess processHandle
          mapM_ (\problem -> client.reviewEventSink (ReviewProtocolWarning ("process group leadership: " <> problem))) groupLeaderProblem
          attached <- attachToolProcess client.reviewToolRegistry key managed
          if not attached
            then killManagedProcess managed >> pure (Left "Review client is shutting down")
            else do
              outputCapture <- startCapture outputHandle
              errorCapture <- startCapture errorHandle
              written <- try (ByteString.hPutStr inputHandle (TextEncoding.encodeUtf8 prompt) >> hClose inputHandle) :: IO (Either IOException ())
              result <- case written of
                Left exception -> pure (Left ("Could not send the reviewer prompt to Claude: " <> exceptionText exception))
                Right () -> renderClaudeResult bounds <$> awaitCommandOutcome bounds processHandle outputCapture errorCapture
              releaseCapture outputCapture
              releaseCapture errorCapture
              killManagedProcess managed
              pure result
        Right _ -> pure (Left "Claude CLI did not provide all three standard streams")
  where
    bounds = client.reviewClaudeBounds
    claudeProcess claudePath = (proc claudePath (authenticatedClaudeArguments assignment))
        { cwd = Just client.reviewRepositoryRoot,
          std_in = CreatePipe,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

-- | The Claude reviewer's rendering, in the same precedence the pre-#154
-- capture used: an unreadable stream keeps its own error, an *observed*
-- nonzero exit stays a nonzero-exit failure whatever the capture managed,
-- and a clean exit with complete stdout round-trips unchanged even when
-- only stderr is still held open.
--
-- The one new case is a clean exit whose stdout never reached EOF. That is
-- deliberately still a 'Right': unlike 'runGitHubCommand' and
-- 'Kanban.Review.Canonical.runCanonicalCommand', whose truncated output is
-- read as a comment URL or a JSON verdict that a prefix would silently
-- corrupt, this output is prose handed back to the reviewing model, which
-- can use a partial answer and is told plainly that it is partial.
--
-- It deliberately does *not* carry the outcome-unknown marker. That marker
-- says the outcome is unknown and may already have completed, which is
-- exactly what 'CommandExited' rules out here -- the exit was observed. Nor
-- is there a side effect to re-check: @kanban_run_claude@ runs Claude under
-- @--permission-mode plan --safe-mode@, so both existing remedies
-- ('githubVerificationRemedy',
-- 'Kanban.Review.Canonical.canonicalVerificationRemedy') would be telling
-- the model to verify something that cannot have changed.
renderClaudeResult :: CommandBounds -> CommandOutcome -> Either Text Text
renderClaudeResult bounds outcome = case outcome of
  CommandUnfinished -> Left claudeReviewerTimeoutMessage
  CommandExited exitCode output errors -> case (exitCode, output, errors) of
    (_, StreamUnreadable exception, _) -> Left ("Could not read Claude reviewer output: " <> exceptionText exception)
    (_, _, StreamUnreadable exception) -> Left ("Could not read Claude reviewer diagnostics: " <> exceptionText exception)
    (ExitFailure code, _, _) ->
      Left
        ( "Claude Sonnet 5 exited with status "
            <> Text.pack (show code)
            <> renderClaudeFailureDetails (capturedBytes output) (capturedBytes errors)
        )
    (ExitSuccess, StreamTruncated outputBytes, _) ->
      Right (renderIncompleteClaudeOutput bounds (decodeClaudeBytes outputBytes))
    (ExitSuccess, StreamComplete outputBytes, _)
      | Text.null renderedOutput -> Left "Claude returned no reviewer output"
      | otherwise -> Right renderedOutput
      where
        renderedOutput = decodeClaudeBytes outputBytes

-- | What the reviewing model is handed when Claude exited cleanly but a
-- surviving pipe holder kept its stdout from reaching EOF. Whatever arrived
-- before the grace expired is kept -- it is the answer, just an unfinished
-- one -- and an empty prefix says so rather than claiming Claude produced
-- no output, which is what a discarded capture would look like.
renderIncompleteClaudeOutput :: CommandBounds -> Text -> Text
renderIncompleteClaudeOutput bounds captured
  | Text.null captured =
      "[Incomplete output: Claude Sonnet 5 exited successfully, but nothing had been captured from its output "
        <> grace
        <> "]"
  | otherwise =
      captured
        <> "\n\n[Incomplete output: Claude Sonnet 5 exited successfully, but its output was still incomplete "
        <> grace
        <> " The text above is the part that was captured.]"
  where
    grace = "after " <> renderWindow bounds.commandCaptureGraceMicros <> "."

-- | The diagnostic a Claude reviewer run that outlived its own process
-- deadline has always returned. Held as a constant, and phrased for the
-- production deadline, because 'claudeCommandBounds' is what production
-- runs under; the injected bounds behind it exist only so a test can reach
-- this path without waiting ten minutes for it.
claudeReviewerTimeoutMessage :: Text
claudeReviewerTimeoutMessage = "Claude Sonnet 5 revision agent timed out after ten minutes"

-- | Production bounds for the authenticated Claude reviewer: the same
-- ten-minute process deadline as before, with capture bounded separately
-- behind it (issue #154).
claudeCommandBounds :: CommandBounds
claudeCommandBounds =
  CommandBounds
    { commandDeadlineMicros = 10 * 60 * 1000 * 1000,
      commandCaptureGraceMicros = captureGraceMicros
    }

-- | Production bounds for every @gh@ invocation: the same 30-second process
-- deadline as before, with capture bounded separately behind it.
githubCommandBounds :: CommandBounds
githubCommandBounds =
  CommandBounds
    { commandDeadlineMicros = 30 * 1000 * 1000,
      commandCaptureGraceMicros = captureGraceMicros
    }
