{-# LANGUAGE DerivingStrategies #-}

-- | Telling somebody that a mission is waiting on them: which target the
-- attention is about, what the configured command is handed, and the durable
-- record that stops it being handed the same thing twice.
--
-- Delivery here is /at most once per attention identity/, and the asymmetry is
-- deliberate. An arbitrary external command and a durable file are two
-- operations with no transaction between them, so one of the two failure
-- directions has to be chosen: record the suppression first and a crash before
-- the launch loses a notification, or record it afterwards and a crash after a
-- successful launch repeats one. Requirement 15 of issue #666 chooses the
-- first, on the grounds that an operator who was not told about a waiting
-- mission still has the mission sitting in @waiting_input@ where the dashboard,
-- the pass report and the durable record all go on showing it, while an
-- operator whose desktop notifies them twice an hour for a week has been given
-- a reason to switch notifications off.
--
-- So: the record is created with @O_CREAT | O_EXCL@ before anything is
-- launched, its existence alone suppresses the identity for good, and no
-- outcome — a launch that failed, a command that timed out, a nonzero exit, an
-- outcome nobody could establish, or a restart — ever makes the identity
-- eligible again. A /different/ episode is a different identity and gets its
-- own one attempt.
--
-- Nothing here claims delivery. A command that exits zero has completed, which
-- is the most an arbitrary program can demonstrate to its caller; whether a
-- desktop drew anything is outside every observation this process can make.
--
-- What the command is told is bounded on purpose: the repository, the typed
-- target, and that attention is required. No title, no summary, no
-- recommendation, no path. A notification command is frequently a shell
-- one-liner piped into something that logs, and the mission's own text is the
-- part most likely to carry a tracker title, a reviewer's wording, or a
-- checkout path.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Notify
  ( missionNotificationTarget,
    missionNotificationArguments,
    missionNotificationDigest,
    missionNotificationTimeoutMicros,
    MissionNotificationAttempt (..),
    attemptMissionNotification,
    runMissionNotificationCommand,
  )
where

import Control.Exception (IOException, try)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time (getCurrentTime)
import Kanban.CommandCapture
  ( CommandBounds (..),
    CommandOutcome (..),
    awaitCommandOutcome,
    captureGraceMicros,
    capturedBytes,
    decodeCommandText,
    releaseCapture,
    startCapture,
  )
import Kanban.Mission.Digest (sha256Hex)
import Kanban.Mission.Pass
  ( MissionNotificationState (..),
    missionNotificationStateTag,
  )
import Kanban.Mission.Paths
  ( MissionStore (..),
    createMissionRecord,
    ensureMissionDirectory,
    missionNotificationDirectory,
    missionNotificationPath,
    withMissionRoot,
    writeMissionRecord,
  )
import Kanban.Mission.Types
  ( MissionAttention (..),
    MissionAttentionId (..),
    MissionId (..),
    MissionNotificationRecord (..),
    MissionPlanStep (..),
    MissionSelector (..),
    MissionSpecification (..),
    MissionTarget (..),
    MissionTargetKind (..),
    missionNotificationSchemaVersion,
  )
import Kanban.Paths (createPrivateDirectory)
import Kanban.Text (sanitizeText)
import System.Directory (XdgDirectory (XdgCache), getXdgDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (CreatePipe, NoStream),
    createProcess,
    proc,
  )

-- | Which tracker item this waiting episode is about, if the mission names
-- one.
--
-- Resolved from typed records and never from text. The step the attention
-- names comes first, because a mission waiting inside one step is waiting
-- about that step's own target; failing that, the selector's target list is
-- what the mission was created for, and its first entry is the one a
-- notification can name. A mission whose selector resolved to nothing — a
-- query that matched no item, or a mission created from a bare request —
-- notifies with no target at all rather than inventing one.
missionNotificationTarget :: MissionSpecification -> MissionAttention -> Maybe MissionTarget
missionNotificationTarget specification attention =
  case stepTarget of
    Just target -> Just target
    Nothing -> listToMaybe specification.missionSpecificationSelector.missionSelectorTargets
  where
    stepTarget = do
      step <- attention.missionAttentionStep
      planStep <- lookupStep step
      planStep.missionPlanStepTarget

    lookupStep step =
      listToMaybe
        [ planStep
        | planStep <- specification.missionSpecificationPlan,
          planStep.missionPlanStepId == step
        ]

-- | The three arguments appended to the configured command, in order.
--
-- Positional and fixed, so a one-line shell wrapper can read them as @$1@,
-- @$2@ and @$3@ without parsing anything. The target is @none@ rather than an
-- empty string when there is none, because an empty argument is easy to lose
-- through a shell and a word is not.
missionNotificationArguments :: Text -> Maybe MissionTarget -> [Text]
missionNotificationArguments repository target =
  [ repository,
    maybe "none" rendered target,
    "attention-required"
  ]
  where
    rendered value = kindTag value.missionTargetKind <> "#" <> Text.pack (show value.missionTargetNumber)
    kindTag kind = case kind of
      MissionTargetIssue -> "issue"
      MissionTargetPullRequest -> "pull_request"

-- | The file name one attention identity's record is kept under.
--
-- A digest, because the identity spells a repository, a mission and a
-- timestamp and is therefore not a path component. "Kanban.Mission.Digest"'s
-- hash rather than a library's, for the reason that module exists: this slice
-- spawns no process to compute one.
missionNotificationDigest :: MissionAttentionId -> Text
missionNotificationDigest identity =
  Text.take 32 (sha256Hex (TextEncoding.encodeUtf8 identity.unMissionAttentionId))

-- | How long a notification command may take.
--
-- A compiled bound rather than a configured one: this is a desktop
-- notification, not a workflow step, and a command that has not answered in
-- ten seconds is not going to. Bounding it is what stops one misconfigured
-- command from holding a scheduler pass open indefinitely.
missionNotificationTimeoutMicros :: Int
missionNotificationTimeoutMicros = 10 * 1000 * 1000

-- | What one attempt amounted to.
data MissionNotificationAttempt = MissionNotificationAttempt
  { missionNotificationAttemptState :: MissionNotificationState,
    missionNotificationAttemptDetail :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | Suppress this identity durably, then — only if this call is the one that
-- suppressed it — run the command.
--
-- The ordering is the whole contract, and every failure below preserves it:
--
--   [the record already exists] somebody has already had this identity's one
--     attempt, and nothing is launched. \"Exists\" is the filesystem's answer,
--     so a record this release cannot decode suppresses exactly as a readable
--     one does.
--   [the record cannot be created] nothing is launched, and the failure is
--     reported as itself. Launching over a suppression that did not land is
--     how one identity gets notified on every pass for ever.
--   [the record was created] the command runs, and its outcome is written back
--     into the record that already stands. A write that fails there leaves the
--     suppression in place and reports the outcome as uncertain, which is the
--     safe direction: the identity stays used up.
attemptMissionNotification ::
  ([Text] -> IO MissionNotificationAttempt) ->
  MissionStore ->
  MissionId ->
  MissionAttentionId ->
  [Text] ->
  IO MissionNotificationAttempt
attemptMissionNotification runCommand store mission identity argv = do
  resolved <-
    withMissionRoot store mission Left $ \root ->
      pure ((,) <$> missionNotificationDirectory root mission <*> missionNotificationPath root mission digest)
  case resolved of
    Left message -> pure (recordingFailed message)
    Right (directory, path) -> do
      prepared <- ensureMissionDirectory directory
      case prepared of
        Left message -> pure (recordingFailed message)
        Right () -> do
          now <- getCurrentTime
          created <- createMissionRecord path missionNotificationSchemaVersion (pending now)
          case created of
            Left message -> pure (recordingFailed message)
            Right False -> pure (MissionNotificationAttempt MissionNotificationSuppressed Nothing)
            Right True -> do
              attempt <- runCommand argv
              written <-
                writeMissionRecord
                  path
                  missionNotificationSchemaVersion
                  (settled now attempt)
              pure $ case written of
                Right () -> attempt
                Left message ->
                  MissionNotificationAttempt
                    MissionNotificationUncertain
                    ( Just
                        ( "the command reported "
                            <> missionNotificationStateTag attempt.missionNotificationAttemptState
                            <> " and the outcome could not be recorded: "
                            <> message
                        )
                    )
  where
    digest = missionNotificationDigest identity

    pending now =
      MissionNotificationRecord
        { missionNotificationRecordMission = mission,
          missionNotificationRecordRepository = store.missionStoreRepository,
          missionNotificationRecordAttention = identity,
          missionNotificationRecordSuppressedAt = now,
          missionNotificationRecordOutcome = Nothing,
          missionNotificationRecordDetail = Nothing
        }

    settled now attempt =
      (pending now)
        { missionNotificationRecordOutcome = Just (missionNotificationStateTag attempt.missionNotificationAttemptState),
          missionNotificationRecordDetail = attempt.missionNotificationAttemptDetail
        }

    recordingFailed message =
      MissionNotificationAttempt
        MissionNotificationRecordingFailed
        (Just ("the notification suppression record could not be written, so nothing was launched: " <> message))

-- | Runs the configured command, bounded, and says only what was observed.
--
-- The process shape is "Kanban.UsageCommand"'s: direct exec with ordinary
-- @PATH@ resolution, no shell, closed stdin, both streams captured rather than
-- inherited, and its own process group. Captured rather than inherited matters
-- twice over here — the scheduler's stdout carries exactly one JSON document,
-- and a notification command that wrote to it would corrupt the very report
-- this attempt is about to appear in.
runMissionNotificationCommand :: Int -> [Text] -> IO MissionNotificationAttempt
runMissionNotificationCommand _ [] =
  pure
    ( MissionNotificationAttempt
        MissionNotificationLaunchFailed
        (Just "the notification command is empty")
    )
runMissionNotificationCommand timeoutMicros (executable : arguments) = do
  scratch <- try @IOException prepareScratch
  case scratch of
    Left exception ->
      pure
        ( MissionNotificationAttempt
            MissionNotificationUncertain
            (Just ("the notification command's scratch directory could not be prepared: " <> Text.pack (show exception)))
        )
    Right directory -> do
      started <- try @IOException (createProcess (spec directory))
      case started of
        Left exception ->
          pure
            ( MissionNotificationAttempt
                MissionNotificationLaunchFailed
                (Just (Text.pack (show exception)))
            )
        Right (_, Just outputHandle, Just errorHandle, processHandle) ->
          observe processHandle outputHandle errorHandle
        Right _ ->
          pure
            ( MissionNotificationAttempt
                MissionNotificationUncertain
                (Just "the notification command did not provide stdout and stderr pipes")
            )
  where
    prepareScratch = do
      cacheRoot <- getXdgDirectory XdgCache "kanban"
      let directory = cacheRoot </> "mission-notify"
      createPrivateDirectory XdgCache directory
      pure directory

    spec directory =
      (proc (Text.unpack executable) (map Text.unpack arguments))
        { cwd = Just directory,
          std_in = NoStream,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }

    observe :: ProcessHandle -> Handle -> Handle -> IO MissionNotificationAttempt
    observe processHandle outputHandle errorHandle = do
      outputCapture <- startCapture outputHandle
      errorCapture <- startCapture errorHandle
      let bounds = CommandBounds {commandDeadlineMicros = timeoutMicros, commandCaptureGraceMicros = captureGraceMicros}
      completed <- awaitCommandOutcome bounds processHandle outputCapture errorCapture
      releaseCapture outputCapture
      releaseCapture errorCapture
      pure $ case completed of
        CommandUnfinished ->
          MissionNotificationAttempt
            MissionNotificationTimedOut
            (Just "the notification command outlived its bound")
        CommandExited ExitSuccess _ _ ->
          MissionNotificationAttempt
            MissionNotificationCompleted
            -- Said outright rather than left to be inferred: a zero exit is
            -- the command finishing, and nothing in this process observed a
            -- notification being displayed.
            (Just "the notification command completed; delivery is not established")
        CommandExited (ExitFailure code) _ errors ->
          MissionNotificationAttempt
            MissionNotificationFailed
            (Just ("the notification command exited with status " <> Text.pack (show code) <> excerpt errors))

    excerpt captured
      | Text.null trimmed = ""
      | otherwise = ": " <> trimmed
      where
        trimmed = Text.strip (Text.take 300 (sanitizeText (decodeCommandText (capturedBytes captured))))
