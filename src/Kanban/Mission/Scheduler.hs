{-# LANGUAGE DerivingStrategies #-}

-- | One repository-wide scheduler pass: @kanban --mission-scheduler@.
--
-- A pass looks at every mission this repository's store holds, admits every
-- runnable one, advances each by at most one transition through its own
-- @kanban --mission@ child, waits for every child it launched, observes
-- whatever attention is outstanding anywhere in the repository, and writes
-- exactly one JSON report before exiting.
--
-- What a pass does not limit is how many missions it advances; what the
-- repository limits is how many agents missions have running
-- ("Kanban.Mission.Admission", issue #746). A child whose one transition
-- would start an agent asks for a slot, and a child whose transition only
-- watches, settles, or records never does — so a mission watching its live
-- worker is never starved by missions waiting to start one. The pass enters
-- every mission it is about to advance in the rotation first, and launches
-- and waits for the children in the rotation's order, which is what makes the
-- rotation, rather than which child reaches the lock first, decide who gets a
-- free slot. It is not a daemon: repeating passes and deciding how long
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
-- whether launching a child is worth it, and the child takes it. The one thing
-- it writes into a mission's store is the session-log archive (D-11), which is
-- immutable, append-only, and never read by anything deciding what a mission
-- does next — so every mission's finished sessions are sealed on every pass,
-- whatever its lifecycle, and none of them becomes admissible for it.
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
    missionIsRunnable,
    runMissionSchedulerPass,
    advanceMissions,
    launchWatched,
    liveMissionSchedulerSeams,
    sealMissionSessions,
    runMissionSchedulerMode,
    runMissionSchedulerCommand,
    missionPassSetupRepository,
    emitMissionPassReport,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, SomeException, bracket, finally, throwIO, try)
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
    RawConfig (..),
    ResolvedConfig (..),
    loadRawConfig,
    missionAgentCeilingValue,
    missionNotificationRefusal,
    repositoryIdentity,
    resolveConfig,
    resolveConfigPathOption,
  )
import Kanban.Domain (Repository (..))
import Kanban.Mission.Admission
  ( expectMissionAgents,
    liveMissionAdmissionSeams,
    missionAgentsLive,
    observeMissionAgents,
    withdrawExpectedMission,
  )
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
  ( MissionAgentCount (..),
    MissionAttentionRecord (..),
    MissionChildOutcome (..),
    MissionChildRefusal (..),
    MissionChildResult (..),
    MissionDisposition (..),
    MissionDispositionRecord (..),
    MissionNotificationState (..),
    MissionPassReport (..),
    MissionPassTermination (..),
    decodeMissionChildResult,
    encodeMissionPassReport,
    missionDispositionIsFailure,
    missionPassExitCode,
    missionPassNarration,
    missionPassSetupFailure,
    missionPassUnresolvedRepository,
  )
import Kanban.Mission.Paths (MissionRead (..), MissionStore (..), openMissionStore)
import Kanban.Mission.Seal (sealMissionSessionLogs)
import Kanban.Mission.Store (listMissionsStrictly, readMissionSnapshot, readMissionSpecification)
import Kanban.Mission.Types
  ( MissionAttention (..),
    MissionId (..),
    MissionLifecycle (..),
    MissionPause (..),
    MissionSessionNode (..),
    MissionSnapshot (..),
    missionLifecycleIsTerminal,
  )
import Kanban.Paths (createPrivateDirectory)
import Kanban.Worker (discoverWorkerHistory)
import Kanban.Repository (parseRepositoryName, resolveRepository)
import System.Directory
  ( XdgDirectory (XdgCache),
    createDirectory,
    getXdgDirectory,
    removeDirectoryRecursive,
    removePathForcibly,
  )
import qualified Data.ByteString.Lazy.Char8 as LazyChar8
import qualified Data.Text.IO as TextIO
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), hClose, openFile, stderr)
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

-- | Whether this mission is one a pass may advance.
--
-- Four exclusions and no more. A terminal mission has stopped for good; a
-- paused one was stopped by a person and resuming it is theirs to ask for; the
-- three waiting states are all waits on something a pass cannot supply — an
-- operator's answer, another mission's barrier, or capacity that is not there;
-- and an interrupted one had a step cut off mid-flight, which D-3 (as amended)
-- hands to the operator's @override@ and never to a later pass or a restarted
-- service. Everything else, including 'MissionRecovering', is runnable,
-- because reattaching to a live worker is exactly the work a child does.
missionIsRunnable :: MissionSnapshot -> Bool
missionIsRunnable snapshot =
  not (missionLifecycleIsTerminal snapshot.missionSnapshotLifecycle)
    && not snapshot.missionSnapshotPause.missionPauseRequested
    && snapshot.missionSnapshotLifecycle `notElem` waiting
  where
    waiting = [MissionWaitingInput, MissionWaitingBarrier, MissionWaitingCapacity, MissionPaused, MissionInterrupted]

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
    --
    -- The action it is handed is to be run for each mission as soon as that
    -- mission's child is done, and before the next one is waited for: it
    -- withdraws the mission's place in the rotation, which a mission behind
    -- it may be waiting on.
    missionSchedulerAdvance :: [MissionId] -> (MissionId -> IO ()) -> IO [(MissionId, Either Text MissionChildResult)],
    -- | Enters the missions about to be advanced in the agent rotation, and
    -- returns them in the order it serves them ("Kanban.Mission.Admission").
    missionSchedulerExpect :: [MissionId] -> IO (Either Text [MissionId]),
    -- | Withdraws what 'missionSchedulerExpect' entered for one mission.
    missionSchedulerWithdraw :: MissionId -> IO (),
    -- | How many mission-dispatched agents are live in this repository.
    missionSchedulerAgents :: IO (Either Text Int),
    -- | Runs the configured notification command. Reached only for an
    -- attention identity whose suppression record this pass just created.
    missionSchedulerNotify :: [Text] -> IO MissionNotificationAttempt,
    -- | Seals whatever the given missions' finished sessions still owe the
    -- archive, and says what could not be sealed. Handed every mission this
    -- pass could read — terminal, blocked, paused, and interrupted ones
    -- included — because a session's logs are owed whatever became of the
    -- mission that started it, and the worker cache keeps them until they
    -- are paid.
    missionSchedulerSeal :: [(MissionId, MissionSnapshot)] -> IO [Text]
  }

-- | One pass, start to finish.
runMissionSchedulerPass :: MissionSchedulerSeams -> MissionsConfig -> MissionStore -> Repository -> IO MissionPassReport
runMissionSchedulerPass seams missions store repository = do
  startedAt <- seams.missionSchedulerNow
  case missionNotificationRefusal notifications of
    -- Ahead of everything, and a refusal rather than a degraded pass: an
    -- operator who asked to be told about waiting missions and cannot be is
    -- owed that as an answer, not a pass that quietly advanced its missions
    -- and said nothing about the one that is waiting for them.
    Just message -> refuse startedAt message
    -- Refused for the same reason, and by name: a ceiling that is not a
    -- positive whole number is one no child could start an agent under, and
    -- a pass that advanced everything else would leave every mission that
    -- needs an agent looking merely held back.
    Nothing -> case missionAgentCeilingValue missions of
      Left message -> refuse startedAt message
      Right agentCeiling -> pass startedAt agentCeiling
  where
    notifications = missions.missionsNotifications
    identity = repositoryIdentity repository.repositoryOwner repository.repositoryName

    pass startedAt agentCeiling = do
      (inventory, unreadable) <- readInventory store
      candidates <- admissible seams inventory
      -- Every runnable mission nothing else is advancing, in the rotation's
      -- order. A rotation record nobody can read is not a reason to advance
      -- nothing — a mission watching its live worker needs no slot — but it
      -- is state nobody can account for, and it fails the pass.
      entered <- if null candidates then pure (Right []) else seams.missionSchedulerExpect candidates
      let (admitted, unordered) = case entered of
            Right ordered -> (ordered, [])
            Left detail -> (candidates, ["the agent rotation could not be entered, so missions were advanced in identifier order: " <> detail])
      advanced <-
        if null admitted
          then pure []
          -- Withdrawn again once every child is done, whatever became of
          -- them, so a place this pass entered never outlives it.
          else seams.missionSchedulerAdvance admitted seams.missionSchedulerWithdraw `finally` mapM_ seams.missionSchedulerWithdraw admitted
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
      -- After the children, so a session one of them just watched end is
      -- sealed in the same pass. Reported and never counted as a failure: a
      -- log that could not be archived this time is retried by the next pass,
      -- and a supervisor that stopped the service over it would be stopping
      -- every mission's progress for the sake of one mission's history.
      unsealed <- seams.missionSchedulerSeal outstanding
      -- Counted after the children, so the count includes whatever they just
      -- started (requirement 9).
      agents <- seams.missionSchedulerAgents
      finishedAt <- seams.missionSchedulerNow
      let attention = catMaybes (map fst observed)
          uncounted = either (\detail -> ["the live agents could not be counted: " <> detail]) (const []) agents
          indeterminate = nub (unreadable <> unordered <> unreadableAfter <> catMaybes (map snd observed) <> uncounted)
          failures = filter (missionDispositionIsFailure . (.missionDispositionValue)) dispositions
          -- Either kind of trouble fails the pass. A record nobody can read is
          -- not a quieter problem than a child that broke: both leave a
          -- mission whose state this pass cannot account for, and a supervisor
          -- has to hear about it rather than see a healthy idle repository.
          failed = not (null failures) || not (null indeterminate)
          counted = either (const Nothing) (\live -> Just (MissionAgentCount live agentCeiling)) agents
      pure
        MissionPassReport
          { missionPassRepository = identity,
            missionPassStartedAt = startedAt,
            missionPassFinishedAt = finishedAt,
            missionPassTermination = if failed then MissionPassFailed else MissionPassCompleted,
            missionPassAdmitted = dispositions,
            missionPassAttention = attention,
            missionPassAgents = counted,
            missionPassDetail = summary (length inventory) dispositions attention failures counted indeterminate unsealed
          }

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
            missionPassAgents = Nothing,
            missionPassDetail = "this pass advanced nothing: " <> message
          }

    summary total dispositions attention failures counted indeterminate unsealed =
      Text.intercalate "; " $
        [ Text.pack (show (length dispositions)) <> " of " <> Text.pack (show total) <> " missions admitted",
          Text.pack (show (length attention)) <> " waiting on a person",
          Text.pack (show (length failures)) <> " failed",
          Text.pack (show (length [() | record <- dispositions, record.missionDispositionValue == MissionDispositionDeferred]))
            <> " held back by the agent ceiling"
        ]
          <> [ Text.pack (show count.missionAgentCountLive)
                 <> " of "
                 <> Text.pack (show count.missionAgentCountCeiling)
                 <> " agent slots in use"
             | Just count <- [counted]
             ]
          <> indeterminate
          <> unsealed

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
-- Sorted by identifier, which is the order the rotation breaks a tie in and
-- the order a pass falls back to when the rotation cannot be read.
readInventory :: MissionStore -> IO ([(MissionId, MissionSnapshot)], [Text])
readInventory store = do
  -- The strict enumeration, because the ordinary one is built for a caller
  -- looking for missions rather than reporting on a repository: it reads a
  -- store directory it could not list as an empty one, and drops an entry it
  -- could not stat or an identifier that resolves to no root. Each of those is
  -- durable state nobody can account for, and a pass that enumerated its way
  -- past them would exit zero over \"0 of 0 missions\".
  (missions, unenumerable) <- listMissionsStrictly store
  loaded <- forM (sortOn (.unMissionId) missions) $ \mission -> do
    snapshot <- readMissionSnapshot store mission
    pure $ case snapshot of
      MissionPresent present -> (Just (mission, present), Nothing)
      MissionAbsent -> (Nothing, Nothing)
      MissionUnreadable detail ->
        (Nothing, Just ("mission " <> mission.unMissionId <> " has an unreadable snapshot: " <> detail))
      MissionRefused detail ->
        (Nothing, Just ("mission " <> mission.unMissionId <> " has a snapshot this store refused: " <> detail))
  pure (catMaybes (map fst loaded), unenumerable <> catMaybes (map snd loaded))

-- | The runnable missions nothing else is already advancing, in order.
--
-- The lease read comes after the runnable test, so a mission a dashboard is
-- already advancing is neither launched nor entered in the rotation: it
-- could not use a slot this pass, and a place in line it cannot take would
-- only hold back the missions behind it.
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
    MissionChildAwaiting -> record MissionDispositionAwaiting result.missionChildResultDetail
    MissionChildDeferred -> record MissionDispositionDeferred result.missionChildResultDetail
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
        missionSchedulerExpect = expectMissionAgents admission store,
        missionSchedulerWithdraw = \mission -> () <$ withdrawExpectedMission admission store mission,
        missionSchedulerAgents = fmap missionAgentsLive <$> observeMissionAgents repository,
        missionSchedulerNotify = runMissionNotificationCommand missionNotificationTimeoutMicros,
        missionSchedulerSeal = sealMissionSessions repository store
      }
  where
    admission = liveMissionAdmissionSeams repository

-- | Seals every finished session of every mission handed over.
--
-- The worker records are read once for the whole pass. What is sealed is
-- decided per session by 'sealMissionSessionLogs', which leaves a session whose
-- worker is still running, or whose logs are already sealed, exactly as it is.
sealMissionSessions :: Repository -> MissionStore -> [(MissionId, MissionSnapshot)] -> IO [Text]
sealMissionSessions repository store missions = do
  workers <- discoverWorkerHistory repository
  concat
    <$> sequence
      [ sealMissionSessionLogs store mission workers node.missionSessionId
      | (mission, snapshot) <- missions,
        node <- snapshot.missionSnapshotSessions
      ]

-- | Launches one child per admitted mission, then waits for all of them.
--
-- Launched first and waited for afterwards, so admitted missions really do
-- advance side by side; a loop that waited for each child before starting the
-- next would serialize every mission's step behind every other's.
--
-- Each child is waited for on its own thread, started as soon as that child
-- is ('launchWatched'), and its mission's place in the rotation is withdrawn
-- the moment that child exits (@settled@) — whatever the children launched
-- before it are still doing, and while later ones are still being launched. A child that finished without
-- wanting a slot must not go on standing in line in front of one that does
-- while a slower child ahead of both is still running: that would leave a
-- free slot idle for nobody. The accounts are still returned in the order the
-- missions were handed over.
--
-- Every child is waited for, including the ones started after a launch that
-- failed, because a pass that returned while a mission child it started was
-- still running would leave that child outside the supervision its wrapper
-- provides (requirement 11).
advanceMissions :: FilePath -> Options -> Repository -> FilePath -> [MissionId] -> (MissionId -> IO ()) -> IO [(MissionId, Either Text MissionChildResult)]
advanceMissions executable options repository scratch admitted settled =
  launchWatched launch watch (zip [0 :: Int ..] admitted)
  where
    -- The withdrawal runs whatever the wait came to.
    watch child = do
      result <- try @SomeException (await child)
      settled (childMission child)
      either throwIO pure result

    childMission (LaunchedChild mission _ _ _ _ _) = mission
    childMission (LaunchRefused mission _) = mission

    identity = repositoryIdentity repository.repositoryOwner repository.repositoryName

    launch (index, mission) = do
      let resultPath = scratch </> ("child-" <> show index <> ".json")
      -- Minted before anything is created, and handed to the child, so this
      -- launch and its account are bound by something the filesystem cannot
      -- reproduce. The result path alone binds nothing: a document an earlier
      -- pass left, or one this pass's own earlier launch left, sits exactly
      -- where this launch's would.
      invocation <- newLaunchIdentity index
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
        Right () -> start mission resultPath invocation

    start mission resultPath invocation = do
      started <-
        try @IOException
          ( bracket (openFile "/dev/null" ReadMode) hClose $ \devNull ->
              createProcess (childProcess devNull mission resultPath invocation)
          )
      case started of
        Left exception -> pure (LaunchRefused mission (Text.pack (show exception)))
        Right (_, Just outputHandle, Just errorHandle, processHandle) -> do
          outputCapture <- startCapture outputHandle
          errorCapture <- startCapture errorHandle
          pure (LaunchedChild mission resultPath invocation processHandle outputCapture errorCapture)
        -- Unreachable while both streams are piped above, and still waited for
        -- rather than abandoned: a child this process started is a child it
        -- must not return in front of, whatever it failed to give back.
        Right (_, _, _, processHandle) -> do
          _ <- waitForProcess processHandle
          pure (LaunchRefused mission "the mission child did not provide stdout and stderr pipes")

    childProcess devNull mission resultPath invocation =
      (proc executable (childArguments mission resultPath invocation))
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

    childArguments mission resultPath invocation =
      [ "--mission",
        Text.unpack mission.unMissionId,
        "--mission-result",
        resultPath,
        "--mission-invocation",
        Text.unpack invocation,
        "--repo",
        Text.unpack identity
      ]
        <> maybe [] (\path -> ["--config", path]) options.optionConfig

    await (LaunchRefused mission detail) =
      pure (mission, Left ("the mission child could not be started: " <> detail))
    await (LaunchedChild mission resultPath invocation processHandle outputCapture errorCapture) = do
      exitCode <- waitForProcess processHandle
      releaseCapture outputCapture
      releaseCapture errorCapture
      readChildResult identity invocation mission resultPath exitCode

-- | Starts each item in order, handing each to a watcher of its own the
-- moment it is started, and returns the watchers' results in order.
--
-- The watcher starts before the next item does, and that is the point: a
-- child that exits while a later child is still being launched has its
-- place in the rotation withdrawn then, not once every launch is over.
-- An exception a watcher raised is raised here, once every watcher before
-- it has answered.
launchWatched :: (item -> IO started) -> (started -> IO result) -> [item] -> IO [result]
launchWatched start watch items = do
  waiting <- mapM (\item -> start item >>= watchApart) items
  mapM (\done -> takeMVar done >>= either throwIO pure) waiting
  where
    watchApart started = do
      done <- newEmptyMVar
      _ <- forkIO (try @SomeException (watch started) >>= putMVar done)
      pure done

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
  = LaunchedChild MissionId FilePath Text ProcessHandle StreamCapture StreamCapture
  | LaunchRefused MissionId Text

-- | A name for one launch that no other launch can hold.
--
-- The moment, this process, and the launch's place in the pass, which is the
-- spelling "Kanban.Mission.Lease" uses for a token that has only to differ.
-- Two launches of one pass differ by index, and two passes by time and
-- process identifier — including a pass whose identifier the kernel later
-- recycles, because the moment is in there too.
newLaunchIdentity :: Int -> IO Text
newLaunchIdentity index = do
  now <- getCurrentTime
  processId <- getProcessID
  pure
    ( Text.filter (`notElem` ("-:. TZ" :: String)) (Text.pack (show now))
        <> "-"
        <> Text.pack (show processId)
        <> "-"
        <> Text.pack (show index)
    )

-- | The child's own account of itself, checked against the status it exited
-- with.
--
-- Both, rather than either. A document that is absent, unreadable, or about
-- another mission leaves the pass with nothing it may act on, whatever the
-- exit status said; and a document that disagrees with the exit status is two
-- records contradicting each other, which is reported rather than resolved by
-- preferring one.
readChildResult :: Text -> Text -> MissionId -> FilePath -> ExitCode -> IO (MissionId, Either Text MissionChildResult)
readChildResult identity invocation mission resultPath exitCode = do
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
        -- Checked before the mission and the repository, because it is the
        -- only one of the three that distinguishes this launch from another
        -- launch of the very same mission in the very same repository — a
        -- stale document from a previous pass, or from this pass's own earlier
        -- attempt, matches both of those perfectly.
        | result.missionChildResultInvocation /= invocation ->
            Left
              ( "the mission child wrote a result for launch "
                  <> result.missionChildResultInvocation
                  <> " while this launch is "
                  <> invocation
              )
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

    -- @kanban --mission@ exits zero for a step it completed — a wait
    -- included — and non-zero for everything else, refusals included.
    agreesWithExit result = case (result.missionChildResultOutcome, exitCode) of
      (MissionChildAdvanced, ExitSuccess) -> True
      (MissionChildAwaiting, ExitSuccess) -> True
      (MissionChildDeferred, ExitSuccess) -> True
      (MissionChildAdvanced, ExitFailure _) -> False
      (MissionChildAwaiting, ExitFailure _) -> False
      (MissionChildDeferred, ExitFailure _) -> False
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
        ( missionPassSetupFailure
            (repositoryIdentity repository.repositoryOwner repository.repositoryName)
            now
            ("this pass could not prepare its scratch directory: " <> Text.pack (show exception))
        )
    Right scratch -> do
      seams <- liveMissionSchedulerSeams options repository store scratch
      runMissionSchedulerPass seams config.resolvedMissions store repository
  -- Every child has been waited for by now, so nothing is still writing in
  -- there. A removal that fails is left alone: the directory's name is unique
  -- to this pass, so a leftover collides with nothing and reporting it would
  -- put a word about a cache directory into a document about missions.
  mapM_ (\scratch -> try @IOException (removeDirectoryRecursive scratch) :: IO (Either IOException ())) prepared
  pure (report, missionPassExitCode report.missionPassTermination)

-- | @kanban --mission-scheduler@ from the parsed invocation down, setup
-- included.
--
-- Requirement 7 and §5 give the supervisor above this process exactly one
-- thing to read: one versioned document naming a termination, and an exit
-- status derived from that termination and from nothing else. A failure
-- before the pass starts is not an exception to that rule. A configuration
-- that will not load, a checkout that resolves to no repository, and a
-- mission store that will not open each end the pass before it admits
-- anything — and a process that answered one of those on stderr and exited
-- would hand the supervisor an unparseable pass, recorded as an incident
-- naming nothing rather than as the failure it was actually told about.
--
-- So every one of them takes the same route out as a pass that ran: a report,
-- narrated to stderr and written once to stdout by 'emitMissionPassReport',
-- and an exit status 'missionPassExitCode' derives. This lives here rather
-- than in @app\/Main.hs@ because that module is not built by the test suite,
-- and the shape of a setup failure is precisely what the suite has to be able
-- to see.
--
-- The @--config@ resolution is inside rather than above for the same reason:
-- it consults the working directory, which can be gone, and an uncaught
-- exception there is a pass with no document at all.
runMissionSchedulerCommand :: Options -> IO (MissionPassReport, Int)
runMissionSchedulerCommand parsedOptions = do
  resolved <- try @IOException (resolveConfigPathOption parsedOptions.optionConfig)
  case resolved of
    Left exception ->
      setupFailure ("the --config path could not be resolved: " <> Text.pack (show exception))
    Right absoluteConfigPath -> do
      let options = parsedOptions {optionConfig = absoluteConfigPath}
      configResult <- loadRawConfig options.optionConfig
      case configResult of
        Left message -> setupFailure message
        Right (rawConfig, warnings) -> do
          mapM_ (\warning -> TextIO.hPutStrLn stderr ("kanban: warning: " <> warning)) warnings
          repositoryResult <- resolveRepository rawConfig.rawRemoteName options.optionPath options.optionRepo
          case repositoryResult of
            Left message -> setupFailure message
            Right repository -> do
              let ownerName = repositoryIdentity repository.repositoryOwner repository.repositoryName
                  resolvedConfig = resolveConfig ownerName rawConfig
              opened <- openMissionStore repository
              case opened of
                -- Named from the repository this resolved to rather than from
                -- the invocation, because by here the two can differ: an
                -- invocation with no @--repo@ has just learned its identity
                -- from the checkout's own remote.
                Left detail -> do
                  now <- getCurrentTime
                  finish (missionPassSetupFailure ownerName now detail)
                Right store -> runMissionSchedulerMode options resolvedConfig repository store
  where
    setupFailure detail = do
      now <- getCurrentTime
      finish (missionPassSetupFailure (missionPassSetupRepository parsedOptions.optionRepo) now detail)

    finish report = pure (report, missionPassExitCode report.missionPassTermination)

-- | The repository a failure before resolution names.
--
-- The invocation's own @--repo@, when it names one. That is the identity the
-- caller asserted and the one it will compare this document against — the
-- supervisor hands every pass the spelling it recorded — and it is also
-- exactly what 'resolveRepository' would have produced had it got that far,
-- since an explicit @--repo@ is parsed and used verbatim rather than
-- reconciled against the checkout.
--
-- Absent, or present and not a repository name at all, leaves nothing to
-- name. The second case matters more than it looks: a @--repo@ that will not
-- parse is itself one of the reasons resolution fails, so \"whatever was
-- typed\" would put a non-identity in the field that identifies the document.
-- 'missionPassUnresolvedRepository' goes there instead, and a reader
-- comparing it against the repository it asked about refuses.
missionPassSetupRepository :: Maybe String -> Text
missionPassSetupRepository requested = case requested of
  Nothing -> missionPassUnresolvedRepository
  Just spelling -> case parseRepositoryName (Text.pack spelling) of
    Left _ -> missionPassUnresolvedRepository
    Right (owner, name) -> repositoryIdentity owner name

-- | Writes one pass report: every word of narration to stderr, exactly one
-- JSON document to stdout.
--
-- The pairing is the point. Narration and document are emitted together, in
-- that order, from one place, so there is no invocation that narrates without
-- reporting and none that reports twice.
emitMissionPassReport :: MissionPassReport -> IO ()
emitMissionPassReport report = do
  mapM_ (TextIO.hPutStrLn stderr) (missionPassNarration report)
  LazyChar8.putStrLn (encodeMissionPassReport report)

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
