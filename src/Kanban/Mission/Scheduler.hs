{-# LANGUAGE DerivingStrategies #-}

-- | One repository-wide scheduler pass: @kanban --mission-scheduler@.
--
-- A pass looks at every mission this repository's store holds, admits at most
-- two runnable ones, advances each through its own @kanban --mission@ child,
-- waits for every child it launched, observes whatever attention is
-- outstanding anywhere in the repository, and writes exactly one JSON report
-- before exiting. It is not a daemon: repeating passes and deciding how long
-- to wait between them belong to @tools\/mission_runner_service.py@, which
-- supervises this process rather than living inside it.
--
-- Four boundaries are worth stating, because each is a thing this module
-- deliberately does not do.
--
-- /It reaches no network./ Everything the runnable set is computed from — a
-- lifecycle, a pause, an advancement lease — is a durable record on this
-- machine, so a pass with nothing to advance costs a directory listing and a
-- few reads and makes no GitHub request at all (requirement 13). The GitHub
-- traffic a mission needs happens inside the child that advances it, where it
-- always did.
--
-- /It decides nothing a mission child decides./ Admission picks which missions
-- get a child; what that child then does — planning, dispatch, reconciliation,
-- reattachment, termination — is "Kanban.Mission.Controller"'s, unchanged and
-- unconsulted from here. This module never writes a snapshot, never journals an
-- event, and never takes an advancement lease: it reads the lease to decide
-- whether launching a child is worth it, and the child takes it.
--
-- /It adds no authority./ A pass cannot merge a pull request, cannot apply a
-- verdict label, and cannot report an indeterminate result as a success, for
-- the plain reason that it performs no effect of its own. Everything it
-- reports is what a child or a durable record told it.
--
-- /It never blocks on a person./ A mission that stops for the operator is
-- reported as blocked and, if notifications are configured, notified about
-- once; the pass then ends. A scheduler that waited would be a daemon holding
-- an advancement lease open (§3).
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Scheduler
  ( MissionSchedulerSeams (..),
    missionAdmissionCeiling,
    missionIsRunnable,
    runMissionSchedulerPass,
    advanceMissions,
    liveMissionSchedulerSeams,
    runMissionSchedulerMode,
  )
where

import Control.Exception (IOException, bracket, try)
import Control.Monad (filterM, forM)
import Data.List (nub, sortOn)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, getCurrentTime)
import Kanban.CLI (Options (..))
import Kanban.CommandCapture (StreamCapture, releaseCapture, startCapture)
import Kanban.Config
  ( MissionNotificationCommand (..),
    MissionNotificationConfig (..),
    MissionsConfig (..),
    ResolvedConfig (..),
    missionNotificationRefusal,
    repositoryIdentity,
  )
import Kanban.Domain (Repository (..))
import Kanban.Mission.Lease (missionLeaseHeld)
import Kanban.Mission.Notify
  ( MissionNotificationAttempt (..),
    attemptMissionNotification,
    missionNotificationArguments,
    missionNotificationTargets,
    missionNotificationTimeoutMicros,
    runMissionNotificationCommand,
  )
import Kanban.Mission.Pass
  ( MissionAttentionRecord (..),
    MissionChildOutcome (..),
    MissionChildRefusal (..),
    MissionChildResult (..),
    MissionDisposition (..),
    MissionDispositionRecord (..),
    MissionNotificationState (..),
    MissionPassReport (..),
    MissionPassTermination (..),
    decodeMissionChildResult,
    missionDispositionIsFailure,
    missionPassExitCode,
  )
import Kanban.Mission.Paths (MissionRead (..), MissionStore (..))
import Kanban.Mission.Store (listMissions, readMissionSnapshot, readMissionSpecification)
import Kanban.Mission.Types
  ( MissionAttention (..),
    MissionId (..),
    MissionLifecycle (..),
    MissionPause (..),
    MissionSnapshot (..),
    missionLifecycleIsTerminal,
  )
import Kanban.Paths (createPrivateDirectory)
import System.Directory
  ( XdgDirectory (XdgCache),
    createDirectory,
    getXdgDirectory,
    removeDirectoryRecursive,
    removePathForcibly,
  )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), hClose, openFile)
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Files (getSymbolicLinkStatus, setFileMode)
import System.Posix.Process (getProcessID)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (CreatePipe, UseHandle),
    createProcess,
    proc,
    waitForProcess,
  )
import qualified Data.ByteString as ByteString

-- | How many missions one pass may advance.
--
-- A compiled two, with no configuration surface, exactly as requirement 3
-- asks. It is a starting point rather than a considered capacity: fair
-- rotation, a configurable ceiling, and priority for a direct operator command
-- are RUN-5's, and a setting shipped before any of them would be a setting
-- whose meaning changes when they arrive.
missionAdmissionCeiling :: Int
missionAdmissionCeiling = 2

-- | Whether this mission is one a pass may advance.
--
-- Three exclusions and no more. A terminal mission has stopped for good; a
-- paused one was stopped by a person and resuming it is theirs to ask for; and
-- the three waiting states are all waits on something a pass cannot supply —
-- an operator's answer, another mission's barrier, or capacity that is not
-- there. Everything else, including 'MissionInterrupted' and
-- 'MissionRecovering', is runnable, because reattaching to a live worker and
-- reconciling an interrupted run are exactly the work a child does.
missionIsRunnable :: MissionSnapshot -> Bool
missionIsRunnable snapshot =
  not (missionLifecycleIsTerminal snapshot.missionSnapshotLifecycle)
    && not snapshot.missionSnapshotPause.missionPauseRequested
    && snapshot.missionSnapshotLifecycle `notElem` waiting
  where
    waiting = [MissionWaitingInput, MissionWaitingBarrier, MissionWaitingCapacity, MissionPaused]

-- | Everything a pass reaches outside its own arithmetic.
--
-- The seam a fixture replaces. Advancement and notification are the two things
-- that leave this process, and both are injected whole rather than mocked
-- piecemeal, so a test drives the real admission, the real lease decision, the
-- real disposition derivation, and the real suppression record while nothing
-- is spawned.
data MissionSchedulerSeams = MissionSchedulerSeams
  { missionSchedulerNow :: IO UTCTime,
    -- | Whether a mission's advancement lease is held, and by what. Production
    -- is "Kanban.Mission.Lease".'Kanban.Mission.Lease.missionLeaseHeld', which
    -- is the same holder-liveness rule an acquisition uses.
    missionSchedulerLeaseHeld :: MissionId -> IO (Maybe Text),
    -- | Advances every admitted mission and returns each one's account of
    -- itself, in the order they were handed over. A pass does not return until
    -- this does, so \"wait for every child launched\" is this function's
    -- promise rather than a rule spread across callers.
    missionSchedulerAdvance :: [MissionId] -> IO [(MissionId, Either Text MissionChildResult)],
    -- | Runs the configured notification command. Reached only for an
    -- attention identity whose suppression record this pass just created.
    missionSchedulerNotify :: [Text] -> IO MissionNotificationAttempt
  }

-- | One pass, start to finish.
runMissionSchedulerPass :: MissionSchedulerSeams -> MissionsConfig -> MissionStore -> Repository -> IO MissionPassReport
runMissionSchedulerPass seams missions store repository = do
  startedAt <- seams.missionSchedulerNow
  case missionNotificationRefusal notifications of
    -- Ahead of everything, and a refusal rather than a degraded pass: an
    -- operator who asked to be told about waiting missions and cannot be is
    -- owed that as an answer, not a pass that quietly advanced two missions
    -- and said nothing about the third that is waiting for them.
    Just message -> refuse startedAt message
    Nothing -> do
      (inventory, unreadable) <- readInventory store
      candidates <- admissible seams inventory
      let admitted = take missionAdmissionCeiling candidates
      advanced <- if null admitted then pure [] else seams.missionSchedulerAdvance admitted
      dispositions <- forM advanced $ \(mission, outcome) -> do
        -- Re-read after the child, never before: the child is what moved the
        -- mission, and the snapshot it left is the only account of where it
        -- got to that this process did not have to infer.
        settled <- readMissionSnapshot store mission
        pure (disposition mission outcome settled)
      -- Every mission, not only the admitted ones (requirement 13): a mission
      -- that is waiting is precisely the one nobody is advancing, and it is
      -- the one somebody needs to hear about.
      (outstanding, unreadableAfter) <- readInventory store
      observed <- mapM (observeAttention seams notifications store repository) outstanding
      finishedAt <- seams.missionSchedulerNow
      let attention = catMaybes (map fst observed)
          indeterminate = nub (unreadable <> unreadableAfter <> catMaybes (map snd observed))
          failures = filter (missionDispositionIsFailure . (.missionDispositionValue)) dispositions
          -- Either kind of trouble fails the pass. A record nobody can read is
          -- not a quieter problem than a child that broke: both leave a
          -- mission whose state this pass cannot account for, and a supervisor
          -- has to hear about it rather than see a healthy idle repository.
          failed = not (null failures) || not (null indeterminate)
      pure
        MissionPassReport
          { missionPassRepository = identity,
            missionPassStartedAt = startedAt,
            missionPassFinishedAt = finishedAt,
            missionPassTermination = if failed then MissionPassFailed else MissionPassCompleted,
            missionPassAdmitted = dispositions,
            missionPassAttention = attention,
            missionPassDetail = summary (length inventory) dispositions attention failures indeterminate
          }
  where
    notifications = missions.missionsNotifications
    identity = repositoryIdentity repository.repositoryOwner repository.repositoryName

    refuse startedAt message = do
      finishedAt <- seams.missionSchedulerNow
      pure
        MissionPassReport
          { missionPassRepository = identity,
            missionPassStartedAt = startedAt,
            missionPassFinishedAt = finishedAt,
            missionPassTermination = MissionPassRefused,
            missionPassAdmitted = [],
            missionPassAttention = [],
            missionPassDetail = "this pass advanced nothing: " <> message
          }

    summary total dispositions attention failures indeterminate =
      Text.intercalate "; " $
        [ Text.pack (show (length dispositions)) <> " of " <> Text.pack (show total) <> " missions admitted",
          Text.pack (show (length attention)) <> " waiting on a person",
          Text.pack (show (length failures)) <> " failed"
        ]
          <> indeterminate

-- | Every mission whose snapshot this store will hand over, and every mission
-- whose snapshot it would not.
--
-- The split is the whole point. §16's silence rule is about a record that is
-- /absent/ — missing, or written under a schema version this release does not
-- know — and a reader is right to carry on past one of those. It says nothing
-- about a record that is there and does not decode, or one that decodes and
-- names another repository: those are mission state nobody can account for,
-- and a pass that dropped them would report a completed idle repository over a
-- mission that may well be mid-flight. So they are collected and reported, and
-- the pass they appear in is a failed one.
--
-- Sorted by identifier so two passes over one unchanged store admit the same
-- two missions — fair rotation is RUN-5's, and until it exists a stable order
-- is better than an arbitrary one.
readInventory :: MissionStore -> IO ([(MissionId, MissionSnapshot)], [Text])
readInventory store = do
  missions <- listMissions store
  loaded <- forM (sortOn (.unMissionId) missions) $ \mission -> do
    snapshot <- readMissionSnapshot store mission
    pure $ case snapshot of
      MissionPresent present -> (Just (mission, present), Nothing)
      MissionAbsent -> (Nothing, Nothing)
      MissionUnreadable detail ->
        (Nothing, Just ("mission " <> mission.unMissionId <> " has an unreadable snapshot: " <> detail))
      MissionRefused detail ->
        (Nothing, Just ("mission " <> mission.unMissionId <> " has a snapshot this store refused: " <> detail))
  pure (catMaybes (map fst loaded), catMaybes (map snd loaded))

-- | The runnable missions nothing else is already advancing, in order.
--
-- The lease read comes after the runnable test and before the ceiling, which
-- is what makes a skipped mission cost no admission slot: a repository with
-- three runnable missions, one of them already being advanced by a dashboard,
-- admits the other two rather than one of them and a refusal.
admissible :: MissionSchedulerSeams -> [(MissionId, MissionSnapshot)] -> IO [MissionId]
admissible seams inventory =
  filterM free [mission | (mission, snapshot) <- inventory, missionIsRunnable snapshot]
  where
    free mission = null <$> seams.missionSchedulerLeaseHeld mission

-- | What one admitted mission's child amounted to.
--
-- Three inputs, in a fixed precedence. A child that produced no usable account
-- of itself has failed, whatever its exit status implied. A typed refusal is
-- read from the child's own document, so losing the lease to somebody who
-- acquired it after this pass selected the mission is ordinary contention
-- rather than a failure (requirement 6). Only a child that reports having
-- advanced is then classified from the durable snapshot it left, because where
-- a mission got to is the snapshot's answer and not the child's.
disposition :: MissionId -> Either Text MissionChildResult -> MissionRead MissionSnapshot -> MissionDispositionRecord
disposition mission outcome settled = case outcome of
  Left detail -> record MissionDispositionFailed detail
  Right result -> case result.missionChildResultOutcome of
    MissionChildFailed -> record MissionDispositionFailed result.missionChildResultDetail
    MissionChildRefused -> case result.missionChildResultRefusal of
      Just MissionChildAlreadyAdvancing -> record MissionDispositionLeaseRefused result.missionChildResultDetail
      _ -> record MissionDispositionRefused result.missionChildResultDetail
    MissionChildAdvanced -> case settled of
      MissionPresent snapshot
        | missionLifecycleIsTerminal snapshot.missionSnapshotLifecycle ->
            record MissionDispositionSettled result.missionChildResultDetail
        | not (missionIsRunnable snapshot) ->
            record MissionDispositionBlocked result.missionChildResultDetail
        | otherwise -> record MissionDispositionAdvanced result.missionChildResultDetail
      -- The child says it advanced the mission and the store will not say
      -- where to. That is a contradiction between two records rather than a
      -- run that went well, and it is reported as the failure it is.
      _ ->
        record
          MissionDispositionFailed
          ( result.missionChildResultDetail
              <> "; the mission's own snapshot could not be read afterwards, so where it got to is unknown"
          )
  where
    record value detail =
      MissionDispositionRecord
        { missionDispositionMission = mission,
          missionDispositionValue = value,
          missionDispositionDetail = detail
        }

-- | One mission's outstanding attention, and what was done about it.
--
-- Nothing is done about it at all when notifications are off, which is the
-- default: the episode is still reported, because the pass report is how a
-- supervisor and an operator find out that a mission is waiting, and that is
-- true whether or not anything rang.
observeAttention ::
  MissionSchedulerSeams ->
  MissionNotificationConfig ->
  MissionStore ->
  Repository ->
  (MissionId, MissionSnapshot) ->
  IO (Maybe MissionAttentionRecord, Maybe Text)
observeAttention seams notifications store repository (mission, snapshot) =
  case snapshot.missionSnapshotAttention of
    Nothing -> pure (Nothing, Nothing)
    Just attention -> do
      specification <- readMissionSpecification store mission
      case specification of
        MissionPresent present -> do
          let targets = missionNotificationTargets present attention
          (state, detail) <- notify attention targets
          pure (Just (record attention targets state detail), Nothing)
        -- No specification, no targets — and therefore no notification. An
        -- empty target list is what a mission that genuinely names nothing
        -- produces, so sending one on this reading would spend the episode's
        -- single, permanent attempt on a payload asserting the mission is
        -- about no item at all. The episode is still reported, so nothing is
        -- hidden; what is withheld is the claim.
        other -> do
          let reason = unresolvedReason other
          pure
            ( Just (record attention [] MissionNotificationUnresolved (Just reason)),
              Just ("mission " <> mission.unMissionId <> " needs attention and " <> reason)
            )
  where
    identity = repositoryIdentity repository.repositoryOwner repository.repositoryName

    record attention targets state detail =
      MissionAttentionRecord
        { missionAttentionRecordMission = mission,
          missionAttentionRecordId = attention.missionAttentionId,
          missionAttentionRecordTargets = targets,
          missionAttentionRecordNotification = state,
          missionAttentionRecordDetail = detail
        }

    -- Absent is reported beside the other two rather than passed over. §16's
    -- silence rule lets a reader carry on past a record it cannot recognise;
    -- it does not make a mission that is waiting on somebody, and whose
    -- specification this release cannot read, a mission nobody need hear
    -- about.
    unresolvedReason other = case other of
      MissionUnreadable detail -> "its specification will not decode (" <> detail <> "), so no target could be resolved"
      MissionRefused detail -> "its specification was refused (" <> detail <> "), so no target could be resolved"
      _ -> "its specification is missing or was written by another release, so no target could be resolved"

    notify attention targets = case (notifications.missionNotificationEnabled, notifications.missionNotificationCommand) of
      (True, Just command) -> do
        attempt <-
          attemptMissionNotification
            seams.missionSchedulerNotify
            store
            mission
            attention.missionAttentionId
            (command.missionNotificationArgv <> missionNotificationArguments identity targets)
        pure (attempt.missionNotificationAttemptState, attempt.missionNotificationAttemptDetail)
      -- Unreachable: 'missionNotificationRefusal' has already refused the pass
      -- for an enabled configuration with no command. Written out rather than
      -- folded into the disabled arm so that an enabled notification can never
      -- silently read as a switched-off one.
      (True, Nothing) -> pure (MissionNotificationRecordingFailed, Just "notifications are enabled and no command is configured")
      (False, _) -> pure (MissionNotificationDisabled, Nothing)

-- ---------------------------------------------------------------------------
-- The live pass
-- ---------------------------------------------------------------------------

-- | The seams that reach real children and a real command.
liveMissionSchedulerSeams :: Options -> Repository -> MissionStore -> FilePath -> IO MissionSchedulerSeams
liveMissionSchedulerSeams options repository store scratch = do
  executable <- getExecutablePath
  pure
    MissionSchedulerSeams
      { missionSchedulerNow = getCurrentTime,
        missionSchedulerLeaseHeld = missionLeaseHeld store,
        missionSchedulerAdvance = advanceMissions executable options repository scratch,
        missionSchedulerNotify = runMissionNotificationCommand missionNotificationTimeoutMicros
      }

-- | Launches one child per admitted mission, then waits for all of them.
--
-- Launched first and waited for afterwards, so two admitted missions really do
-- advance side by side; a loop that waited for each child before starting the
-- next would make the ceiling of two a ceiling of one with extra steps.
--
-- Every child is waited for, including the ones started after a launch that
-- failed, because a pass that returned while a mission child it started was
-- still running would leave that child outside the supervision its wrapper
-- provides (requirement 11).
advanceMissions :: FilePath -> Options -> Repository -> FilePath -> [MissionId] -> IO [(MissionId, Either Text MissionChildResult)]
advanceMissions executable options repository scratch admitted = do
  launched <- mapM launch (zip [0 :: Int ..] admitted)
  mapM await launched
  where
    identity = repositoryIdentity repository.repositoryOwner repository.repositoryName

    launch (index, mission) = do
      let resultPath = scratch </> ("child-" <> show index <> ".json")
      -- The result document is read back by path, and a document that was
      -- already there is indistinguishable from one this child wrote. That is
      -- not hypothetical: a pass that was killed leaves its children's
      -- documents behind, and a later pass whose scratch directory resolved to
      -- the same place would read one of them as the account of a child that
      -- in fact wrote nothing — a stale @already_advancing@ beside a fresh
      -- non-zero exit reads as ordinary contention, which is a successful
      -- pass over a mission that failed. So the path is cleared and its
      -- absence established before anything is started, and a path that
      -- cannot be cleared refuses the launch rather than being launched over.
      cleared <- clearResultPath resultPath
      case cleared of
        Left detail -> pure (LaunchRefused mission detail)
        Right () -> start mission resultPath

    start mission resultPath = do
      started <-
        try @IOException
          ( bracket (openFile "/dev/null" ReadMode) hClose $ \devNull ->
              createProcess (childProcess devNull mission resultPath)
          )
      case started of
        Left exception -> pure (LaunchRefused mission (Text.pack (show exception)))
        Right (_, Just outputHandle, Just errorHandle, processHandle) -> do
          outputCapture <- startCapture outputHandle
          errorCapture <- startCapture errorHandle
          pure (LaunchedChild mission resultPath processHandle outputCapture errorCapture)
        -- Unreachable while both streams are piped above, and still waited for
        -- rather than abandoned: a child this process started is a child it
        -- must not return in front of, whatever it failed to give back.
        Right (_, _, _, processHandle) -> do
          _ <- waitForProcess processHandle
          pure (LaunchRefused mission "the mission child did not provide stdout and stderr pipes")

    childProcess devNull mission resultPath =
      (proc executable (childArguments mission resultPath))
        { -- The checkout travels as the working directory rather than as
          -- @--path@, because a directory name that is not representable in
          -- the process's own argument encoding survives the first and not the
          -- second, and @--path@ defaults to the invoking directory anyway.
          cwd = Just repository.repositoryRoot,
          -- A real, readable, non-terminal descriptor rather than a closed
          -- one: @kanban --mission@ decides whether it has an operator by
          -- asking 'System.IO.hIsTerminalDevice' about standard input, and a
          -- closed descriptor makes that question raise rather than answer
          -- (requirement 5).
          std_in = UseHandle devNull,
          -- Captured rather than inherited, so nothing a child writes can
          -- reach the single JSON document this pass puts on its own stdout.
          std_out = CreatePipe,
          std_err = CreatePipe,
          -- Deliberately left alone. The child stays in this process's
          -- session, which is what lets the wrapper's signal to that session's
          -- process group reach every mission child of the active pass
          -- (requirement 11).
          create_group = False
        }

    childArguments mission resultPath =
      [ "--mission",
        Text.unpack mission.unMissionId,
        "--mission-result",
        resultPath,
        "--repo",
        Text.unpack identity
      ]
        <> maybe [] (\path -> ["--config", path]) options.optionConfig

    await (LaunchRefused mission detail) =
      pure (mission, Left ("the mission child could not be started: " <> detail))
    await (LaunchedChild mission resultPath processHandle outputCapture errorCapture) = do
      exitCode <- waitForProcess processHandle
      releaseCapture outputCapture
      releaseCapture errorCapture
      readChildResult identity mission resultPath exitCode

-- | Removes whatever occupies a child's result path, and proves it is gone.
--
-- Two steps rather than one, because a removal that fails is exactly the case
-- that matters: @removePathForcibly@ succeeds on a path that was never there,
-- so its success says nothing, and the question this has to answer is whether
-- the path is empty /now/.
clearResultPath :: FilePath -> IO (Either Text ())
clearResultPath path = do
  _ <- try @IOException (removePathForcibly path)
  occupied <- try @IOException (getSymbolicLinkStatus path)
  pure $ case occupied of
    Left _ -> Right ()
    Right _ ->
      Left
        ( "the result path "
            <> Text.pack path
            <> " was already occupied and could not be cleared, so this mission was not started"
        )

-- | One launched mission child, or the reason there is none to wait for.
--
-- A type rather than a tuple with an 'Either' in it, so the waiting arm cannot
-- be written to reach for a capture that a refused launch never produced.
data LaunchedChild
  = LaunchedChild MissionId FilePath ProcessHandle StreamCapture StreamCapture
  | LaunchRefused MissionId Text

-- | The child's own account of itself, checked against the status it exited
-- with.
--
-- Both, rather than either. A document that is absent, unreadable, or about
-- another mission leaves the pass with nothing it may act on, whatever the
-- exit status said; and a document that disagrees with the exit status is two
-- records contradicting each other, which is reported rather than resolved by
-- preferring one.
readChildResult :: Text -> MissionId -> FilePath -> ExitCode -> IO (MissionId, Either Text MissionChildResult)
readChildResult identity mission resultPath exitCode = do
  loaded <- try @IOException (ByteString.readFile resultPath)
  pure . (,) mission $ case loaded of
    Left exception ->
      Left
        ( "the mission child "
            <> exited
            <> " and wrote no result document ("
            <> Text.pack (show exception)
            <> ")"
        )
    Right bytes -> case decodeMissionChildResult bytes of
      Left message -> Left (message <> "; the child " <> exited)
      Right result
        | result.missionChildResultMission /= mission ->
            Left
              ( "the mission child wrote a result for "
                  <> result.missionChildResultMission.unMissionId
                  <> " while advancing "
                  <> mission.unMissionId
              )
        -- The mission identifier alone does not identify a mission: two
        -- repositories may spell one the same way, and every durable record in
        -- the store is repository-qualified for exactly that reason. A result
        -- naming another repository is somebody else's account of somebody
        -- else's work, and accepting it would let it decide this mission's
        -- disposition.
        | result.missionChildResultRepository /= identity ->
            Left
              ( "the mission child wrote a result for "
                  <> result.missionChildResultRepository
                  <> " while this pass is advancing "
                  <> identity
              )
        | not (agreesWithExit result) ->
            Left
              ( "the mission child reported "
                  <> Text.pack (show result.missionChildResultOutcome)
                  <> " and "
                  <> exited
              )
        | otherwise -> Right result
  where
    exited = case exitCode of
      ExitSuccess -> "exited successfully"
      ExitFailure code -> "exited with status " <> Text.pack (show code)

    -- @kanban --mission@ exits zero for a run it completed and non-zero for
    -- everything else, refusals included, and that is the behaviour this
    -- extension preserves rather than changes.
    agreesWithExit result = case (result.missionChildResultOutcome, exitCode) of
      (MissionChildAdvanced, ExitSuccess) -> True
      (MissionChildAdvanced, ExitFailure _) -> False
      (_, ExitSuccess) -> False
      (_, ExitFailure _) -> True

-- | @kanban --mission-scheduler@, from the command line down.
--
-- Returns the report and the status it is to be reported with; writing the
-- document and exiting is @app\/Main.hs@'s, which is the only part of this
-- that the test suite cannot compile.
runMissionSchedulerMode :: Options -> ResolvedConfig -> Repository -> MissionStore -> IO (MissionPassReport, Int)
runMissionSchedulerMode options config repository store = do
  prepared <- newPassScratchDirectory
  report <- case prepared of
    Left exception -> do
      now <- getCurrentTime
      pure
        MissionPassReport
          { missionPassRepository = repositoryIdentity repository.repositoryOwner repository.repositoryName,
            missionPassStartedAt = now,
            missionPassFinishedAt = now,
            missionPassTermination = MissionPassFailed,
            missionPassAdmitted = [],
            missionPassAttention = [],
            missionPassDetail = "this pass could not prepare its scratch directory: " <> Text.pack (show exception)
          }
    Right scratch -> do
      seams <- liveMissionSchedulerSeams options repository store scratch
      runMissionSchedulerPass seams config.resolvedMissions store repository
  -- Every child has been waited for by now, so nothing is still writing in
  -- there. A removal that fails is left alone: the directory's name is unique
  -- to this pass, so a leftover collides with nothing and reporting it would
  -- put a word about a cache directory into a document about missions.
  mapM_ (\scratch -> try @IOException (removeDirectoryRecursive scratch) :: IO (Either IOException ())) prepared
  pure (report, missionPassExitCode report.missionPassTermination)

-- | A directory this pass's children leave their result documents in, which
-- no other pass has ever used.
--
-- Under the cache root rather than in the mission store: these are transient
-- handoffs between one process and its own children, they are removed when the
-- pass ends, and a mission's own directory is durable state that a crashed
-- pass has no business littering.
--
-- Created with @createDirectory@ rather than @createDirectoryIfMissing@, and
-- that is the whole point of it. A name built from the process identifier
-- alone is /reused/ — the kernel recycles identifiers, and a pass that was
-- killed leaves its children's documents behind — so a later pass could open a
-- directory that already held a @child-0.json@ and read it as the account of
-- a child that wrote nothing. An exclusive create cannot return a directory
-- that was already there, so the only way to get one is to have made it.
--
-- The token is the time and the identifier together, the spelling
-- "Kanban.Mission.Lease" uses for the same purpose; a collision is retried a
-- bounded number of times rather than assumed away.
newPassScratchDirectory :: IO (Either IOException FilePath)
newPassScratchDirectory = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  let root = cacheRoot </> "mission-scheduler"
  prepared <- try @IOException (createPrivateDirectory XdgCache root)
  case prepared of
    Left exception -> pure (Left exception)
    Right () -> attempt root (8 :: Int)
  where
    attempt root remaining = do
      token <- passToken
      let directory = root </> token
      created <- try @IOException (createDirectory directory)
      case created of
        Right () -> do
          _ <- try @IOException (setFileMode directory 0o700) :: IO (Either IOException ())
          pure (Right directory)
        Left exception
          | isAlreadyExistsError exception, remaining > 0 -> attempt root (remaining - 1)
          | otherwise -> pure (Left exception)

    passToken = do
      now <- getCurrentTime
      processId <- getProcessID
      pure (filter (`notElem` ("-:. TZ" :: String)) (show now) <> "-" <> show processId)
