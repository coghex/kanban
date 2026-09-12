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
  ( missionNotificationTargets,
    missionNotificationArguments,
    missionNotificationDigest,
    missionNotificationTimeoutMicros,
    MissionNotificationAttempt (..),
    attemptMissionNotification,
    runMissionNotificationCommand,
  )
where

import Control.Exception (IOException, bracket, try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
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
import Kanban.Process (ManagedProcess, managedProcess, sweepCommandGroup)
import Kanban.Text (sanitizeText)
import System.Directory (XdgDirectory (XdgCache), getXdgDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle)
import System.Posix.Signals
  ( Handler (CatchOnce, Default),
    installHandler,
    raiseSignal,
    sigINT,
    sigTERM,
  )
import System.Process
  ( CreateProcess (..),
    Pid,
    ProcessHandle,
    StdStream (CreatePipe, NoStream),
    createProcess,
    getPid,
    proc,
  )

-- | Which tracker items this waiting episode is about.
--
-- Resolved from typed records and never from text. The step the attention
-- names comes first, because a mission waiting inside one step is waiting
-- about that step's own target and nothing else; failing that, the selector's
-- targets are what the mission was created for, and /all/ of them are the
-- answer. Keeping only the first would silently drop the rest of a mission
-- created for several items, which is the ordinary case for a selector.
--
-- Empty when the mission names none — a step with no target and a selector
-- that resolved to nothing, which is what a mission created from a bare
-- request looks like. That is a real answer rather than a failure, and the
-- notification still fires; what it may never be is the answer given for a
-- specification nobody could read, which is why the caller resolves the
-- specification before calling this rather than defaulting on its behalf.
missionNotificationTargets :: MissionSpecification -> MissionAttention -> [MissionTarget]
missionNotificationTargets specification attention =
  case stepTarget of
    Just target -> [target]
    Nothing -> specification.missionSpecificationSelector.missionSelectorTargets
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

-- | The arguments appended to the configured command, in order.
--
-- Two fixed positions and then the targets: @$1@ is the repository and @$2@ is
-- the word @attention-required@, so a one-line shell wrapper can read both
-- without counting anything, and @$3@ onward are however many typed items the
-- mission named — none, one, or several.
--
-- Variadic at the /end/ for that reason. A target in the middle would move the
-- indication's position with the number of targets, which is exactly the shape
-- that makes a positional contract unreadable.
--
-- A mission that names no target appends nothing at all rather than a sentinel
-- word. An absent target is absent: spelling it @none@ would put an untyped
-- value where typed ones go, and a command that split on the target's own
-- @kind#number@ shape would have to special-case it.
missionNotificationArguments :: Text -> [MissionTarget] -> [Text]
missionNotificationArguments repository targets =
  [repository, "attention-required"] <> map rendered targets
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

-- | Runs @body@ with an intentional stop performing @sweep@ first.
--
-- Installed for the life of one command and restored afterwards, rather than
-- held for the whole process: a notification is the only thing this process
-- starts in a group of its own, and only one is ever in flight at a time
-- because attention is observed one mission after another. So the window that
-- needs covering is exactly this call.
--
-- It is installed /before/ the spawn and released only after the final sweep,
-- which is what makes that window the whole of the command's life rather than
-- most of it: a handler established after the spawn leaves the setup between
-- them unguarded, and one released before the sweep leaves the teardown
-- unguarded, and a stop landing in either of those would end this process with
-- the command still running in a group nothing else can reach. Before the
-- spawn the sweep has nothing recorded and does nothing, which is the right
-- answer there.
--
-- The handler sweeps and then lets the signal do what it was sent to do: the
-- default disposition is restored and the signal re-raised, so this process
-- still dies of it rather than absorbing it and carrying on past a stop.
--
-- 'CatchOnce' because a second signal must not re-enter a sweep that is
-- already running. An operator who asks twice is obeyed by the supervisor's
-- own escalation, which kills the group outright — and that escalation is why
-- this is best effort rather than a guarantee: a @SIGKILL@ runs no handler,
-- and the sweep then depends on the grace period the supervisor waits out
-- first.
withStopSweep :: IO () -> IO a -> IO a
withStopSweep sweep body = bracket install restore (const body)
  where
    stops = [sigTERM, sigINT]

    install = mapM (\signal -> (,) signal <$> installHandler signal (CatchOnce (handle signal)) Nothing) stops

    restore = mapM_ (\(signal, previous) -> installHandler signal previous Nothing)

    handle signal = do
      sweep
      _ <- installHandler signal Default Nothing
      raiseSignal signal

-- | Runs the configured command, bounded, and says only what was observed.
--
-- The process shape is "Kanban.UsageCommand"'s: direct exec with ordinary
-- @PATH@ resolution, no shell, closed stdin, both streams captured rather than
-- inherited, and its own process group. Captured rather than inherited matters
-- twice over here — the scheduler's stdout carries exactly one JSON document,
-- and a notification command that wrote to it would corrupt the very report
-- this attempt is about to appear in.
--
-- And the group is swept on every path out, which is the other half of the
-- bound. 'awaitCommandOutcome' decides how long the command /may/ take and
-- ends nothing when that runs out, and releasing the captures closes pipes
-- rather than processes — so a command that outlived its deadline is still
-- running when this returns, and so is anything it backgrounded before
-- exiting cleanly. A pass that left those behind would accumulate one stuck
-- notifier per waiting episode on a host whose notifier hangs.
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
      -- What a stop has to end, recorded the moment there is anything to
      -- record. The handler is installed *before* the spawn and stays
      -- installed through the final sweep, so there is no interval — not
      -- starting the captures, not releasing them, not sweeping — in which a
      -- signal would find the previous disposition in place and leave the
      -- command behind. Until the spawn there is nothing to end, so the
      -- handler reads an empty box and does nothing.
      live <- newIORef Nothing
      withStopSweep (readIORef live >>= mapM_ (uncurry sweepCommandGroup)) $ do
        started <- try @IOException (createProcess (spec directory))
        case started of
          Left exception ->
            pure
              ( MissionNotificationAttempt
                  MissionNotificationLaunchFailed
                  (Just (Text.pack (show exception)))
              )
          Right (_, Just outputHandle, Just errorHandle, processHandle) ->
            observe live processHandle outputHandle errorHandle
          Right (_, _, _, processHandle) -> do
            -- No pipes to capture, and still a process this call created: it
            -- is recorded and swept like any other rather than abandoned.
            (managed, _) <- managedProcess processHandle
            rootPid <- getPid processHandle
            writeIORef live (Just (rootPid, managed))
            sweepCommandGroup rootPid managed
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

    observe :: IORef (Maybe (Maybe Pid, ManagedProcess)) -> ProcessHandle -> Handle -> Handle -> IO MissionNotificationAttempt
    observe live processHandle outputHandle errorHandle = do
      -- Captured before anything can reap the leader: 'getPid' goes 'Nothing'
      -- the moment a clean exit reaps it below, so the identifier the sweep
      -- needs is taken now while it is guaranteed available.
      (managed, _groupLeaderProblem) <- managedProcess processHandle
      rootPid <- getPid processHandle
      -- Recorded before the captures start, so every step from here on is
      -- covered by the handler installed above.
      writeIORef live (Just (rootPid, managed))
      outputCapture <- startCapture outputHandle
      errorCapture <- startCapture errorHandle
      let bounds = CommandBounds {commandDeadlineMicros = timeoutMicros, commandCaptureGraceMicros = captureGraceMicros}
      completed <- awaitCommandOutcome bounds processHandle outputCapture errorCapture
      releaseCapture outputCapture
      releaseCapture errorCapture
      sweepCommandGroup rootPid managed
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
