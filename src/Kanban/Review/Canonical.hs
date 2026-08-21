-- | The canonical issue-review gate: where the installed
-- @approve_issues.py@ backend is, how it is invoked, and how its verdict is
-- rendered. Kanban's own synchronous publishing action (the board's @r@
-- key) runs entirely through this module.
--
-- Independent of the app-server client in "Kanban.Review" — this backend is
-- a plain bounded subprocess with no thread, tool registry, or wire
-- protocol behind it.
module Kanban.Review.Canonical
  ( IssueReviewerRecord (..),
    IssueReviewerSource (..),
    canonicalCommandBounds,
    canonicalIssueReviewArguments,
    canonicalIssueReviewerPath,
    issueReviewerNotFoundMessage,
    issueReviewerRecordFromBytes,
    issueReviewerRecordPath,
    renderCanonicalIssueReviewResult,
    resolveCanonicalIssueReviewer,
    resolveCanonicalIssueReviewerAt,
    runCanonicalCommand,
    runCanonicalIssueReview,
    selectCanonicalIssueReviewer,
    selectCanonicalIssueReviewerAt,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.:!))
import qualified Data.ByteString.Char8 as ByteString
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.CommandCapture
  ( CommandBounds (..),
    CommandOutcome (..),
    StreamCaptureResult (..),
    awaitCommandOutcome,
    captureGraceMicros,
    capturedBytes,
    commandRanToCompletion,
    releaseCapture,
    renderWindow,
    startCapture,
  )
import Kanban.Domain (Repository (..))
import Kanban.ManagedPaths
  ( ManagedComponent (..),
    managedRecordPath,
    recordPathOccupied,
  )
import Kanban.Process (ManagedProcess, killManagedProcess, managedProcess)
import Kanban.Review.Diagnostics
  ( decodeClaudeBytes,
    exceptionText,
    outcomeUnknownMessage,
    renderClaudeFailureDetails,
  )
import Kanban.Review.Types
  ( CanonicalIssueReviewResult (..),
    ReviewStage (..),
    decodeCanonicalIssueReviewResult,
    reviewResultHeading,
  )
import Kanban.Text (withoutJsonPath)
import Kanban.Transcript (closeSessionLog, logMessage, logRawLine, openSessionLog)
import System.Directory (doesFileExist, findExecutable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.IO (Handle)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    proc,
  )

renderCanonicalIssueReviewResult :: ReviewStage -> CanonicalIssueReviewResult -> Text
renderCanonicalIssueReviewResult stage result =
  Text.unlines
    ( [ reviewResultHeading stage,
        "  Outcome: " <> if result.canonicalReviewApproved then "APPROVED" else "CHANGES REQUESTED",
        "  Origin: " <> result.canonicalReviewOrigin,
        "  Reviewer route: " <> fromMaybe "not reported" result.canonicalReviewRequiredReviewers,
        "  Models: " <> fromMaybe "not reported" result.canonicalReviewRequiredModels
      ]
        <> renderReasons result.canonicalReviewReasons
    )
  where
    renderReasons [] = ["  Blocking reasons: none"]
    renderReasons reasons = "  Blocking reasons:" : map ("    • " <>) reasons

-- | The vendored canonical issue-review backend inside a given install
-- directory. The only path this module composes, and it composes it with
-- 'System.FilePath' rather than an embedded separator — the directory
-- itself is never reconstructed here, it arrives from the environment or
-- from the installer's own record.
canonicalIssueReviewerPath :: FilePath -> FilePath
canonicalIssueReviewerPath installDir = installDir </> "approve_issues.py"

-- | What @tools\/install_issue_review.py@ recorded about the backend it
-- installed. Only the backend's location crosses the boundary: what the
-- reviewer is and how it is invoked belong to
-- 'canonicalIssueReviewArguments' and are never read from here.
newtype IssueReviewerRecord = IssueReviewerRecord
  { -- | The installed @approve_issues.py@, absolute. 'Nothing' is a
    -- document written before this field existed — the installer has always
    -- written a @config.json@ for @--config@, so a well-formed record with
    -- no discovery field means "installed by an older version", not
    -- "broken", and takes the compatibility fallback.
    issueReviewerRecordBackend :: Maybe FilePath
  }
  deriving stock (Eq, Show)

instance FromJSON IssueReviewerRecord where
  parseJSON = withObject "issue-review install record" $ \value ->
    -- @.:!@, not @.:?@: only an /absent/ field means "written before this
    -- field existed". An explicit @null@ is a value this installer never
    -- writes, so it is a record edited or corrupted into naming nothing —
    -- fail-closed, exactly as a wrong-typed value is, and exactly as the
    -- Python consumers read it. @.:?@ collapses those two cases into the
    -- compatibility fallback and would silently run a different install.
    IssueReviewerRecord <$> value .:! "backend_path"

-- | The document @tools\/install_issue_review.py@ records the installed
-- backend in. Deliberately not derived from
-- @KANBAN_ISSUE_REVIEW_INSTALL_DIR@: an install made with @--install-dir@
-- still has to be discoverable by a dashboard that never saw that option, so
-- the record's own path is the one thing that cannot move.
--
-- Which of the two managed locations that is, is "Kanban.ManagedPaths"'s
-- answer rather than one spelled here, exactly as
-- 'Kanban.Drainer.drainerRecordPath' takes its own from there: one Haskell
-- resolver against the one Python resolver, so a host discovers the
-- installation it has rather than the one this platform would create.
issueReviewerRecordPath :: IO FilePath
issueReviewerRecordPath = managedRecordPath IssueReviewComponent

-- | Reads the record, separating a document that cannot be used from one
-- that simply predates the discovery field. A non-absolute recorded path
-- would be resolved against whatever directory Kanban happened to be run
-- from, so it names nothing and is rejected here rather than handed on.
issueReviewerRecordFromBytes :: ByteString.ByteString -> Either Text IssueReviewerRecord
issueReviewerRecordFromBytes bytes = case eitherDecodeStrict bytes of
  Left message -> Left (withoutJsonPath (Text.pack message))
  Right record -> case record.issueReviewerRecordBackend of
    Just backend
      | not (isAbsolute backend) ->
          Left ("its recorded backend path is not absolute: " <> Text.pack backend)
    _ -> Right record

-- | Which of the three sources named the reviewer. Carried so a diagnostic
-- can say what was actually consulted: naming the default install path to
-- someone who installed elsewhere is what made the old message recommend the
-- command they had just run successfully.
data IssueReviewerSource
  = -- | @KANBAN_ISSUE_REVIEW_INSTALL_DIR@ selected this install directory.
    ReviewerFromEnvironment FilePath
  | -- | The record at this path named the backend.
    ReviewerFromRecord FilePath
  | -- | The record at this path exists but predates the discovery field, or
    -- is absent entirely, so the directory holding it is the install.
    ReviewerFromDefault FilePath
  deriving stock (Eq, Show)

-- | Select where the canonical reviewer should be, without yet asking
-- whether it is there. Preflight needs the selection alone: it tells a
-- never-installed path apart from one occupied by something else, and a
-- resolution that failed on absence would collapse that distinction.
--
-- Precedence is @KANBAN_ISSUE_REVIEW_INSTALL_DIR@, then the recorded
-- backend, then the directory the record itself lives in. An override that
-- is set selects, and a record that names a backend selects, whether or not
-- what they name exists — falling through to a lower-precedence location
-- would silently review with an installation the user did not choose.
selectCanonicalIssueReviewerAt ::
  Maybe String -> FilePath -> IO (Either Text (IssueReviewerSource, FilePath))
selectCanonicalIssueReviewerAt override recordPath = case override of
  Just installDir
    | not (null (trimmed installDir)) ->
        pure (Right (ReviewerFromEnvironment installDir, canonicalIssueReviewerPath installDir))
  _ -> do
    -- Absence is decided by 'recordPathOccupied' — whether anything occupies
    -- the path, not whether something readable does — which is the same
    -- predicate that chose this location in the first place. A directory, or
    -- a symbolic link whose target is gone, is a record that cannot be read
    -- rather than one that was never written; treating either as absent
    -- would fall through to the default backend and silently run an
    -- installation the record does not name. The installer refuses to write
    -- through a link here for the same reason. Anything present is read, and
    -- a read that fails becomes the unreadable-record diagnostic below.
    recorded <- recordPathOccupied recordPath
    if not recorded
      then pure (Right compatibilityFallback)
      else do
        contents <- try @IOException (ByteString.readFile recordPath)
        case fmap issueReviewerRecordFromBytes contents of
          Left _ -> pure (Left (unreadableRecord "it could not be read"))
          Right (Left message) -> pure (Left (unreadableRecord message))
          Right (Right record) -> pure . Right $ case record.issueReviewerRecordBackend of
            Nothing -> compatibilityFallback
            Just backend -> (ReviewerFromRecord recordPath, backend)
  where
    trimmed = Text.unpack . Text.strip . Text.pack

    compatibilityFallback =
      ( ReviewerFromDefault recordPath,
        canonicalIssueReviewerPath (takeDirectory recordPath)
      )

    unreadableRecord detail =
      "The canonical issue reviewer's install record at "
        <> Text.pack recordPath
        <> " is unreadable ("
        <> detail
        <> "). Rewrite it by running `python3 tools/install_issue_review.py` from the "
        <> "Kanban checkout, adding --install-dir if the backend lives elsewhere."

-- | 'selectCanonicalIssueReviewerAt' against the real environment.
selectCanonicalIssueReviewer :: IO (Either Text (IssueReviewerSource, FilePath))
selectCanonicalIssueReviewer = do
  override <- lookupEnv "KANBAN_ISSUE_REVIEW_INSTALL_DIR"
  recordPath <- issueReviewerRecordPath
  selectCanonicalIssueReviewerAt override recordPath

-- | Why the selected reviewer is not where it was selected from. Each source
-- gets its own repair, because the useful next step differs: an override
-- names a directory nothing installed into, a record names an install that
-- has since moved or been removed, and only the compatibility fallback is
-- repaired by the bare installer command.
issueReviewerNotFoundMessage :: IssueReviewerSource -> FilePath -> Text
issueReviewerNotFoundMessage source scriptPath =
  "Canonical issue reviewer was not found at " <> Text.pack scriptPath <> ". " <> repair
  where
    repair = case source of
      ReviewerFromEnvironment installDir ->
        "KANBAN_ISSUE_REVIEW_INSTALL_DIR selected "
          <> Text.pack installDir
          <> "; install there with `python3 tools/install_issue_review.py --install-dir "
          <> Text.pack installDir
          <> "`, or unset that variable to use the recorded installation."
      ReviewerFromRecord recordPath ->
        "The install record at "
          <> Text.pack recordPath
          <> " still names it, so the installation moved or was removed; re-run "
          <> "`python3 tools/install_issue_review.py` from the Kanban checkout with the "
          <> "--install-dir you want, which also refreshes that record."
      ReviewerFromDefault recordPath ->
        "No install directory is recorded at "
          <> Text.pack recordPath
          <> ", so this default was used. Run `python3 tools/install_issue_review.py` "
          <> "from the Kanban checkout to install and record it."

-- | Resolve the bundled canonical issue reviewer, failing with a diagnostic
-- that names what was actually consulted.
resolveCanonicalIssueReviewerAt :: Maybe String -> FilePath -> IO (Either Text FilePath)
resolveCanonicalIssueReviewerAt override recordPath = do
  selected <- selectCanonicalIssueReviewerAt override recordPath
  case selected of
    Left message -> pure (Left message)
    Right (source, scriptPath) -> do
      scriptExists <- doesFileExist scriptPath
      pure $
        if scriptExists
          then Right scriptPath
          else Left (issueReviewerNotFoundMessage source scriptPath)

resolveCanonicalIssueReviewer :: IO (Either Text FilePath)
resolveCanonicalIssueReviewer = do
  override <- lookupEnv "KANBAN_ISSUE_REVIEW_INSTALL_DIR"
  recordPath <- issueReviewerRecordPath
  resolveCanonicalIssueReviewerAt override recordPath

runCanonicalIssueReview :: Maybe FilePath -> Repository -> Int -> ReviewStage -> (ManagedProcess -> IO ()) -> IO (Either Text CanonicalIssueReviewResult)
runCanonicalIssueReview configPath repository issueNumber stage processStarted
  | stage == IssueRevision = pure (Left "Canonical issue review cannot perform specification revision")
  | otherwise = do
      resolved <- resolveCanonicalIssueReviewer
      case resolved of
        Left message -> pure (Left message)
        Right scriptPath -> do
          python <- findExecutable "python3"
          case python of
            Nothing -> pure (Left "python3 was not found on PATH")
            Just pythonPath -> do
              output <-
                runCanonicalCommand
                  canonicalCommandBounds
                  repository
                  issueNumber
                  pythonPath
                  (canonicalIssueReviewArguments scriptPath repository issueNumber stage configPath)
                  processStarted
              pure (output >>= decodeCanonicalIssueReviewResult)

-- | Explicit --repo, so the canonical reviewer always gates and mutates the
-- same repository Kanban resolved (including any --repo override), rather
-- than independently re-deriving identity from the configured remote —
-- which could diverge in a fork checkout.
canonicalIssueReviewArguments :: FilePath -> Repository -> Int -> ReviewStage -> Maybe FilePath -> [String]
canonicalIssueReviewArguments scriptPath repository issueNumber stage configPath =
  [ scriptPath,
    "--path",
    repository.repositoryRoot,
    "--repo",
    Text.unpack (repository.repositoryOwner <> "/" <> repository.repositoryName),
    stageFlag,
    show issueNumber,
    "--legacy-policy",
    "dual",
    "--json"
  ]
    <> maybe [] (\path -> ["--config", path]) configPath
  where
    stageFlag = case stage of
      InitialReview -> "--review"
      IssueRereview -> "--rereview"
      IssueRevision -> "--review"

runCanonicalCommand :: CommandBounds -> Repository -> Int -> FilePath -> [String] -> (ManagedProcess -> IO ()) -> IO (Either Text Text)
runCanonicalCommand bounds repository issueNumber executable arguments processStarted = do
  logResult <- openSessionLog repository "issue-canonical-review" issueNumber Nothing
  sessionLog <- case logResult of
    Left _ -> pure Nothing
    Right value -> logMessage value "command-started" (Text.pack executable) >> pure (Just value)
  started <- try (createProcess processSpec) :: IO (Either IOException (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle))
  case started of
    Left exception -> finishLog sessionLog >> pure (Left ("Could not start canonical issue reviewer: " <> exceptionText exception))
    Right (Nothing, Just outputHandle, Just errorHandle, processHandle) -> do
      (managed, groupLeaderProblem) <- managedProcess processHandle
      mapM_ (\value -> mapM_ (logMessage value "group-leadership-unverified") groupLeaderProblem) sessionLog
      processStarted managed
      outputCapture <- startCapture outputHandle
      errorCapture <- startCapture errorHandle
      completed <- awaitCommandOutcome bounds processHandle outputCapture errorCapture
      releaseCapture outputCapture
      releaseCapture errorCapture
      -- Sweeping the recorded process group is what makes the two giving-up
      -- paths actually bounded: a still-running reviewer, or a descendant
      -- that outlived it still holding a capture pipe, would otherwise be
      -- left behind once this call returns.
      unless (commandRanToCompletion completed) (killManagedProcess managed)
      result <- case completed of
        CommandUnfinished ->
          pure
            ( Left
                ( outcomeUnknownMessage
                    ("The canonical issue review did not exit within " <> renderWindow bounds.commandDeadlineMicros)
                    canonicalVerificationRemedy
                )
            )
        CommandExited exitCode output errors -> case (exitCode, output, errors) of
          (_, StreamUnreadable exception, _) -> pure (Left ("Could not read canonical issue review output: " <> exceptionText exception))
          -- A canonical run that exited cleanly with fully captured output
          -- has always been reported as a success even when its diagnostics
          -- could not be read; only a *failing* exit needs them.
          (ExitSuccess, StreamComplete outputBytes, _) -> do
            logCaptured sessionLog outputBytes (capturedBytes errors)
            pure (Right (decodeClaudeBytes outputBytes))
          -- Exited zero, but a surviving pipe holder kept stdout from ever
          -- reaching EOF: the prefix may look like complete JSON and still
          -- be a truncated verdict, so this is outcome-unknown rather than a
          -- success -- and, crucially, never a timeout.
          (ExitSuccess, StreamTruncated outputBytes, _) -> do
            logCaptured sessionLog outputBytes (capturedBytes errors)
            pure
              ( Left
                  ( outcomeUnknownMessage
                      ("The canonical issue review exited but its output was still incomplete after " <> renderWindow bounds.commandCaptureGraceMicros)
                      canonicalVerificationRemedy
                  )
              )
          (_, _, StreamUnreadable exception) -> pure (Left ("Could not read canonical issue review diagnostics: " <> exceptionText exception))
          (ExitFailure code, _, _) -> do
            logCaptured sessionLog (capturedBytes output) (capturedBytes errors)
            pure (Left ("Canonical issue reviewer exited with status " <> Text.pack (show code) <> renderClaudeFailureDetails (capturedBytes output) (capturedBytes errors)))
      finishLog sessionLog
      pure result
    Right _ -> finishLog sessionLog >> pure (Left "Canonical issue reviewer did not provide stdout and stderr pipes")
  where
    repositoryRoot = repository.repositoryRoot
    finishLog sessionLog = mapM_ (\value -> logMessage value "command-finished" "canonical issue review" >> closeSessionLog value) sessionLog
    logCaptured sessionLog output errors = do
      mapM_ (\value -> mapM_ (logRawLine value "stdout") (ByteString.split '\n' output)) sessionLog
      mapM_ (\value -> mapM_ (logRawLine value "stderr") (ByteString.split '\n' errors)) sessionLog
    processSpec =
      (proc executable arguments)
        { cwd = Just repositoryRoot,
          std_in = NoStream,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

-- | Remedy for the canonical gate, whose results are rendered to the TUI
-- rather than returned to any tool-calling model. It must not mention
-- rereading "with this tool": there is no model on that path to do so.
canonicalVerificationRemedy :: Text
canonicalVerificationRemedy =
  "Check the issue's current comments and labels before running the review again."

-- | Production bounds for the canonical gate: the same one-hour process
-- deadline as before, now with capture bounded separately behind it.
canonicalCommandBounds :: CommandBounds
canonicalCommandBounds =
  CommandBounds
    { commandDeadlineMicros = 60 * 60 * 1000 * 1000,
      commandCaptureGraceMicros = captureGraceMicros
    }
