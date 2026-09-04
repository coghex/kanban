{-# LANGUAGE DerivingStrategies #-}

-- | One mission, advanced one transition at a time, in plain 'IO'.
--
-- This is the half of the mission runner that has no terminal and no provider
-- (issue #595, requirement 1). Brick is not imported here and neither is
-- anything that spawns a process: what reaches outside is a 'MissionDriver'
-- the caller supplies, which "Kanban.Mission.Runner" builds over the workflow
-- action registry and a fixture builds out of whatever it wants to stage.
--
-- Three rules shape everything below.
--
-- /One transition per iteration./ An iteration may reconcile a step, or
-- dispatch one, or apply one command, or move the mission's lifecycle — never
-- two. That is what makes a crash between any two of them recoverable: each
-- iteration leaves the durable record in a state the next one can read without
-- knowing anything about the run that wrote it.
--
-- /The journal goes first./ Every effect is preceded by an invocation record
-- that is appended and flushed to disk, and followed by a second record
-- concluding it. An opening record with no conclusion is the @outcome_unknown@
-- of requirement 7 — something may have happened — and nothing here ever
-- retries one on the strength of the record alone.
--
-- /The precondition is rechecked at the boundary./ The version an effect was
-- planned against is recorded when it is planned, and reread immediately
-- before the effect is attempted (requirement 8). A target that moved in
-- between produces a typed stale-version result and no mutation at all, which
-- the next iteration replans from.
--
-- What this module deliberately does not do: choose which mission to advance,
-- arbitrate between missions, merge anything, apply a verdict label, or treat
-- an indeterminate result as a success. The first two belong to SAG-9; the
-- last three belong to nobody.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Controller
  ( -- * The driver
    MissionDriver (..),
    MissionInventory (..),
    MissionDispatchRequest (..),
    MissionDispatchAccepted (..),

    -- * Starting and attaching
    MissionStartRefusal (..),
    missionStartRefusalMessage,
    MissionController (..),
    MissionAttachment (..),
    startMissionController,
    attachToMission,
    stopMissionController,

    -- * Advancing
    MissionTransition (..),
    missionTransitionMessage,
    MissionIteration (..),
    missionControllerIteration,
    submitConsoleCommand,
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, getCurrentTime)
import Kanban.Domain (Repository (..))
import Kanban.Mission.Control
  ( MissionChildRequest (..),
    MissionCommandPayload (..),
    MissionCommandRead (..),
    MissionCommandRejection (..),
    MissionControlEndpoint (..),
    MissionSubmittedCommand (..),
    consumeMissionCommand,
    missionCommandAuthorityTag,
    missionCommandPayloadTag,
    missionCommandRejectionMessage,
    openMissionControl,
    overrideAuthorized,
    readMissionCommands,
    runnerCommand,
  )
import Kanban.Mission.Invocation
  ( missionStaleVersionMessage,
    MissionIntendedEffect (..),
    MissionInvocation (..),
    MissionInvocationId (..),
    MissionInvocationOutcome (..),
    MissionInvocationState (..),
    MissionStaleVersion (..),
    MissionTargetVersion (..),
    concludeMissionInvocation,
    missionInvocationFor,
    missionVersionHolds,
    newMissionInvocationId,
    readMissionInvocations,
    recordMissionInvocation,
    unresolvedMissionInvocations,
  )
import Kanban.Mission.Lease
  ( MissionLease,
    MissionLeaseAcquisition (..),
    acquireMissionLease,
    releaseMissionLease,
  )
import Kanban.Mission.Paths (MissionRead (..), MissionStore (..), missionDirectory, missionInvocationPath)
import Kanban.Mission.Reconcile
  ( dispatchedButUnregistered,
    unresolvedDispatchOf,
    MissionContinuation (..),
    MissionExternalWork (..),
    MissionHalt,
    MissionStepEvidence (..),
    MissionStepFailure (..),
    MissionWorkerReading (..),
    blockedMissionLifecycle,
    cancelledByDependency,
    classifyMissionWork,
    missionContinuation,
    missionRunnerHalt,
    missionSessionSubtree,
    missionStepFailureLifecycle,
    missionStepFailureMessage,
    missionStepRecordFor,
    nextDispatchableStep,
    settledMissionLifecycle,
    stepHasUnsettledDescendants,
  )
import Kanban.Mission.Store (readMissionSnapshot, readMissionSpecification, recordMissionEvent, writeMissionSnapshot)
import Kanban.Mission.Types
  ( MissionEvent (..),
    MissionId (..),
    MissionLifecycle (..),
    MissionPause (..),
    MissionPlanStep (..),
    MissionProcessOwnership (..),
    MissionReconciliation (..),
    MissionRepository (..),
    MissionSessionDisposition (..),
    MissionSessionId (..),
    MissionSessionNode (..),
    MissionTerminalObservation (..),
    MissionSnapshot (..),
    MissionSpecification (..),
    MissionStepId (..),
    MissionStepLifecycle (..),
    MissionStepRecord (..),
    MissionTarget (..),
    missionLifecycleTag,
    missionRepository,
    missionRepositoryMatches,
    missionSessionDisposition,
    missionStepLifecycleTag,
  )

-- ---------------------------------------------------------------------------
-- The driver
-- ---------------------------------------------------------------------------

-- | Everything the mission startup pass inventories.
--
-- Requirement 17 permits this and bounds it in the same sentence: a runner may
-- look at every mission and worker in the repository to validate its own state
-- and detect conflicts, and may advance only the mission it was named. The
-- inventory is therefore a value the controller /reads/ and never a set it
-- chooses from.
data MissionInventory = MissionInventory
  { missionInventoryMissions :: [MissionId],
    missionInventoryWorkers :: [Text]
  }
  deriving stock (Eq, Show)

-- | One planned effect, with the precondition it was planned against.
data MissionDispatchRequest = MissionDispatchRequest
  { missionDispatchStep :: MissionPlanStep,
    missionDispatchTarget :: Maybe MissionTarget,
    missionDispatchVersion :: Maybe MissionTargetVersion,
    missionDispatchContinuation :: MissionContinuation,
    missionDispatchInvocation :: MissionInvocationId
  }
  deriving stock (Eq, Show)

-- | What the owning authority gave back when it accepted one.
data MissionDispatchAccepted = MissionDispatchAccepted
  { missionAcceptedSession :: MissionSessionId,
    missionAcceptedProviderSession :: Maybe Text,
    missionAcceptedWorker :: Text,
    missionAcceptedDetail :: Text
  }
  deriving stock (Eq, Show)

-- | The controller's whole contact with the outside world.
--
-- Five operations, each one of them a question the durable record cannot
-- answer: what else exists on this machine, what the live target says, what a
-- step's own worker and session say, how to start registered work, and how to
-- end it. Everything else the controller does is a read or a write of its own
-- mission's files.
data MissionDriver = MissionDriver
  { missionDriverInventory :: IO (Either Text MissionInventory),
    -- | The live reading of one target: the exact precondition record, taken
    -- fresh. Called when a plan is made and again immediately before the
    -- effect, which is the whole of requirement 8's boundary check.
    missionDriverObserveTarget :: MissionTarget -> IO (Either Text MissionTargetVersion),
    -- | What live evidence says about one step, assembled by the caller so the
    -- classification stays pure.
    missionDriverStepEvidence :: MissionPlanStep -> MissionStepRecord -> IO (Either Text MissionStepEvidence),
    -- | Whether one registered session has ended, and with what.
    --
    -- Separate from the step evidence because a mission's session tree is not
    -- a projection of its plan: a registered child has a node and a parent and
    -- no plan step of its own, and requirement 11's accounting is over that
    -- tree. 'Nothing' means it has not ended, which keeps its parent
    -- nonterminal — as does a reading that could not be taken at all.
    missionDriverObserveSession :: MissionSessionId -> IO (Either Text (Maybe MissionTerminalObservation)),
    -- | The session an invocation actually launched, if one exists.
    --
    -- The other half of requirement 5's recoverability. An invocation is
    -- journaled, dispatched, and only then concluded with the worker it got;
    -- a crash in that window leaves an invocation naming no worker and a
    -- worker this mission started but has not recorded — which, without this,
    -- the next run reads as somebody else's live work and pauses on. The
    -- launch writes the invocation's identity into the worker's own
    -- specification, so the association survives the crash that lost the
    -- conclusion.
    missionDriverAdoptInvocation :: MissionInvocationId -> IO (Either Text (Maybe MissionSessionId)),
    missionDriverDispatch :: MissionDispatchRequest -> IO (Either MissionStepFailure MissionDispatchAccepted),
    -- | Ends exactly the registered sessions named, which the controller has
    -- already journaled and which is already the complete subtree.
    missionDriverTerminate :: [MissionSessionId] -> IO (Either Text ())
  }

-- ---------------------------------------------------------------------------
-- Starting and attaching
-- ---------------------------------------------------------------------------

-- | Every way a named mission cannot be run.
--
-- Requirement 2's four refusals are the first four, and none of them ever
-- resolves to a different mission: a runner told to advance a mission it
-- cannot have says so and stops, because substituting another one is how a
-- typo spends an agent budget on work nobody asked for.
data MissionStartRefusal
  = -- | The identifier cannot name a mission directory at all.
    MissionIdentifierUnusable Text Text
  | -- | Well-formed, and this repository's store holds no such mission.
    MissionUnknown MissionId
  | -- | A durable record will not decode under a version this release knows.
    MissionRecordUnreadable MissionId Text
  | -- | The mission's own specification names another repository.
    MissionRepositoryMismatched MissionId MissionRepository MissionRepository
  | -- | Another controller holds the advancement lease.
    MissionAlreadyAdvancing MissionId Text
  | -- | The store or the control endpoint could not be prepared.
    MissionStoreUnusable Text
  deriving stock (Eq, Show)

missionStartRefusalMessage :: MissionStartRefusal -> Text
missionStartRefusalMessage refusal = case refusal of
  MissionIdentifierUnusable identifier detail ->
    "mission " <> quoted identifier <> " cannot be run: " <> detail
  MissionUnknown mission ->
    "mission " <> quoted mission.unMissionId <> " does not exist in this repository's mission store"
  MissionRecordUnreadable mission detail ->
    "mission " <> quoted mission.unMissionId <> " has an unreadable durable record: " <> detail
  MissionRepositoryMismatched mission held requested ->
    "mission "
      <> quoted mission.unMissionId
      <> " belongs to "
      <> renderRepository held
      <> " and this run resolved "
      <> renderRepository requested
  MissionAlreadyAdvancing mission detail ->
    "mission " <> quoted mission.unMissionId <> " is already being advanced: " <> detail
  MissionStoreUnusable detail -> detail
  where
    renderRepository repository = repository.missionRepositoryOwner <> "/" <> repository.missionRepositoryName
    quoted value = "\"" <> value <> "\""

-- | A mission this process holds the advancement lease on.
data MissionController = MissionController
  { missionControllerStore :: MissionStore,
    missionControllerMission :: MissionId,
    missionControllerSpecification :: MissionSpecification,
    missionControllerLease :: MissionLease,
    missionControllerControl :: MissionControlEndpoint,
    missionControllerDriver :: MissionDriver,
    missionControllerInvocations :: FilePath,
    -- | Everything else on this machine, read once at startup for validation
    -- and conflict detection and never selected from (requirement 17).
    missionControllerInventory :: MissionInventory,
    -- | The invocations this store had never seen the end of when the run
    -- started. Reported, never retried.
    missionControllerUnresolved :: [MissionInvocationState],
    -- | Commands this process built from its own console, waiting to be
    -- applied.
    --
    -- In memory and nowhere else, which is the whole of what makes them
    -- authenticated: nothing on disk carries this authority, so nothing on
    -- disk can claim it. The cost is that a console line typed and not yet
    -- applied does not survive a crash, which is the right trade for a line
    -- someone can simply type again.
    missionControllerConsole :: IORef [MissionSubmittedCommand],
    -- | Command files this run has already reported as unusable.
    --
    -- A file that will not decode is left exactly where it is — it may be a
    -- command a newer release wrote, and deleting it would be this release
    -- deciding what another one meant — so it is found again on every
    -- iteration. Without this it would also be journaled again on every
    -- iteration, and a single malformed file would fill the journal for as
    -- long as the run lasted.
    missionControllerReported :: IORef (Set FilePath)
  }

-- | A mission this process is only watching.
--
-- No lease, and no driver: an attachment reads the durable record and may
-- submit commands, and requirement 4's rule is that it competes for nothing.
-- The absence of a 'MissionLease' field is the enforcement — there is no value
-- here an attached client could release, because there is none it took.
data MissionAttachment = MissionAttachment
  { missionAttachmentStore :: MissionStore,
    missionAttachmentMission :: MissionId,
    missionAttachmentSpecification :: MissionSpecification,
    missionAttachmentSnapshot :: MissionSnapshot,
    missionAttachmentControl :: MissionControlEndpoint
  }

-- | Requirement 6's startup, in requirement 6's order.
--
-- The order is not a preference. Identity is validated before the mission is
-- loaded, because a store belonging to another repository must not have its
-- records read as this one's; the lease is claimed before anything is
-- discovered, because discovery that races another controller's advancement
-- describes a state neither of them is in; and the inventory is taken after
-- the lease, for the same reason.
startMissionController :: MissionStore -> Repository -> MissionId -> (MissionStore -> MissionId -> IO MissionDriver) -> IO (Either MissionStartRefusal MissionController)
startMissionController store repository mission buildDriver = do
  -- 1 and 2: identity and schemas, then the explicitly selected mission.
  loaded <- loadMissionRecords store repository mission
  case loaded of
    Left refusal -> pure (Left refusal)
    Right (specification, _) -> do
      -- 3: the mission's own advancement lease. Never the board lease: a
      -- runner draws no board and serialises against no `gh` record, so it
      -- takes nothing that would refuse to run beside an open dashboard.
      acquisition <- acquireMissionLease store mission
      case acquisition of
        MissionLeaseHeld detail -> pure (Left (MissionAlreadyAdvancing mission detail))
        MissionLeaseUnusable detail -> pure (Left (MissionStoreUnusable detail))
        MissionLeaseAcquired lease -> do
          opened <- openMissionControl store mission
          case opened of
            Left detail -> releaseMissionLease lease >> pure (Left (MissionStoreUnusable detail))
            Right endpoint -> case missionInvocationPath store.missionStoreDirectory mission of
              Left detail -> releaseMissionLease lease >> pure (Left (MissionStoreUnusable detail))
              Right invocationPath -> do
                driver <- buildDriver store mission
                -- 4: recorded workers, processes, provider sessions, and
                -- invocation records.
                inventoried <- driver.missionDriverInventory
                invocations <- readMissionInvocations mission store.missionStoreRepository invocationPath
                case (inventoried, invocations) of
                  (Left detail, _) -> releaseMissionLease lease >> pure (Left (MissionStoreUnusable detail))
                  (_, Left detail) -> releaseMissionLease lease >> pure (Left (MissionRecordUnreadable mission detail))
                  (Right inventory, Right recorded) -> do
                    reported <- newIORef Set.empty
                    console <- newIORef []
                    now <- getCurrentTime
                    _ <-
                      recordMissionEvent
                        store
                        ( missionEvent
                            mission
                            store.missionStoreRepository
                            now
                            "controller_started"
                            ( Just
                                ( "inventoried "
                                    <> countOf inventory.missionInventoryMissions
                                    <> " mission(s) and "
                                    <> countOf inventory.missionInventoryWorkers
                                    <> " worker(s); "
                                    <> countOf (unresolvedMissionInvocations recorded)
                                    <> " invocation(s) with no recorded outcome"
                                )
                            )
                        )
                    pure
                      ( Right
                          MissionController
                            { missionControllerStore = store,
                              missionControllerMission = mission,
                              missionControllerSpecification = specification,
                              missionControllerLease = lease,
                              missionControllerControl = endpoint,
                              missionControllerDriver = driver,
                              missionControllerInvocations = invocationPath,
                              missionControllerInventory = inventory,
                              missionControllerUnresolved = unresolvedMissionInvocations recorded,
                              missionControllerConsole = console,
                              missionControllerReported = reported
                            }
                      )
  where
    countOf values = Text.pack (show (length values))

-- | The read-and-steer half of requirement 4.
--
-- Performs the same validation and load a controller does, opens the control
-- endpoint as a client rather than as its owner, and takes no lease. A second
-- controller is refused by 'startMissionController'; an attachment is not
-- refused at all, because it competes for nothing.
attachToMission :: MissionStore -> Repository -> MissionId -> IO (Either MissionStartRefusal MissionAttachment)
attachToMission store repository mission = do
  loaded <- loadMissionRecords store repository mission
  case loaded of
    Left refusal -> pure (Left refusal)
    Right (specification, snapshot) -> do
      attached <- openMissionControl store mission
      pure $ case attached of
        Left detail -> Left (MissionStoreUnusable detail)
        Right endpoint ->
          Right
            MissionAttachment
              { missionAttachmentStore = store,
                missionAttachmentMission = mission,
                missionAttachmentSpecification = specification,
                missionAttachmentSnapshot = snapshot,
                missionAttachmentControl = endpoint
              }

-- | Releases the advancement lease.
--
-- The control secret needs no retiring: it lives in this process's memory and
-- goes with it. What is left behind is the request directory, which is
-- deliberate — a command submitted and not yet acted on is durable state, and
-- the next run reads it as an ordinary attached client's command, because that
-- run mints a secret of its own and this one's is gone.
stopMissionController :: MissionController -> IO ()
stopMissionController controller = releaseMissionLease controller.missionControllerLease

-- | Stages 1 and 2 of requirement 6, shared by both attachment kinds.
loadMissionRecords :: MissionStore -> Repository -> MissionId -> IO (Either MissionStartRefusal (MissionSpecification, MissionSnapshot))
loadMissionRecords store repository mission = case missionDirectory store.missionStoreDirectory mission of
  -- Asked first, and asked of the identifier rather than of the read it would
  -- produce. An identifier that cannot name a directory makes every path below
  -- unreadable, and reporting that as an unreadable record would tell the
  -- person who mistyped it that their mission is corrupt (requirement 2).
  Left detail -> pure (Left (MissionIdentifierUnusable mission.unMissionId detail))
  Right _ -> loadResolvedMissionRecords store repository mission

loadResolvedMissionRecords :: MissionStore -> Repository -> MissionId -> IO (Either MissionStartRefusal (MissionSpecification, MissionSnapshot))
loadResolvedMissionRecords store repository mission = do
  specificationRead <- readMissionSpecification store mission
  case specificationRead of
    MissionAbsent -> pure (Left (MissionUnknown mission))
    MissionUnreadable detail -> pure (Left (MissionRecordUnreadable mission detail))
    MissionRefused detail -> pure (Left (MissionRecordUnreadable mission detail))
    MissionPresent specification
      | not (missionRepositoryMatches (missionRepository repository) specification.missionSpecificationRepository) ->
          pure
            ( Left
                ( MissionRepositoryMismatched
                    mission
                    specification.missionSpecificationRepository
                    (missionRepository repository)
                )
            )
      | otherwise -> do
          snapshotRead <- readMissionSnapshot store mission
          pure $ case snapshotRead of
            MissionAbsent -> Left (MissionUnknown mission)
            MissionUnreadable detail -> Left (MissionRecordUnreadable mission detail)
            MissionRefused detail -> Left (MissionRecordUnreadable mission detail)
            MissionPresent snapshot -> Right (specification, snapshot)

-- ---------------------------------------------------------------------------
-- Advancing
-- ---------------------------------------------------------------------------

-- | The one thing an iteration did.
data MissionTransition
  = MissionCommandApplied Text Text
  | MissionCommandRefused Text Text
  | MissionStepReconciled MissionStepId MissionStepLifecycle Text
  | MissionStepAttached MissionStepId MissionSessionId
  | MissionStepDispatched MissionStepId MissionInvocationId MissionSessionId
  | MissionStepBlocked MissionStepId MissionStepFailure
  | MissionSessionEnded MissionSessionId Text
  | MissionSubtreeTerminated MissionSessionId Int
  | MissionLifecycleSet MissionLifecycle Text
  deriving stock (Eq, Show)

missionTransitionMessage :: MissionTransition -> Text
missionTransitionMessage transition = case transition of
  MissionCommandApplied commandId detail -> "applied command " <> commandId <> ": " <> detail
  MissionCommandRefused commandId detail -> "refused command " <> commandId <> ": " <> detail
  MissionStepReconciled step lifecycle detail ->
    step.unMissionStepId <> " → " <> missionStepLifecycleTag lifecycle <> " (" <> detail <> ")"
  MissionStepAttached step session ->
    step.unMissionStepId <> " reattached to session " <> session.unMissionSessionId
  MissionStepDispatched step invocation session ->
    step.unMissionStepId
      <> " dispatched as "
      <> invocation.unMissionInvocationId
      <> " on session "
      <> session.unMissionSessionId
  MissionStepBlocked step failure ->
    step.unMissionStepId <> " blocked: " <> missionStepFailureMessage failure
  MissionSessionEnded session detail ->
    "session " <> session.unMissionSessionId <> " settled: " <> detail
  MissionSubtreeTerminated session count ->
    "terminated " <> Text.pack (show count) <> " registered session(s) under " <> session.unMissionSessionId
  MissionLifecycleSet lifecycle detail -> "mission " <> missionLifecycleTag lifecycle <> ": " <> detail

-- | What one iteration produced.
data MissionIteration
  = MissionAdvanced MissionTransition
  | -- | Registered work is live and nothing else is eligible. The runner waits
    -- and asks again; it does not spin, because the thing it is waiting for is
    -- bounded by that worker's own recorded deadline.
    MissionAwaiting Text
  | MissionStopped MissionHalt
  | -- | This run could not establish what it needed to decide: a durable
    -- record it could not read or write, or live evidence it could not
    -- obtain. Never a mission outcome — nothing is concluded from a failure to
    -- find out — and never a lifecycle written to the mission, so a network
    -- that was down for one run does not become a state every later run halts
    -- on.
    MissionControllerFailed Text
  deriving stock (Eq, Show)

-- | One iteration, advancing at most one eligible transition.
missionControllerIteration :: MissionController -> IO MissionIteration
missionControllerIteration controller = do
  snapshotRead <- readMissionSnapshot controller.missionControllerStore controller.missionControllerMission
  case snapshotRead of
    MissionAbsent -> pure (MissionControllerFailed "this mission's snapshot has gone")
    MissionUnreadable detail -> pure (MissionControllerFailed detail)
    MissionRefused detail -> pure (MissionControllerFailed detail)
    MissionPresent snapshot -> do
      -- The runner's own console first, and not as a preference: it is the
      -- only channel that can resolve an unknown outcome or lift a pause, so a
      -- queue of file commands must not be able to delay it.
      typed <- takeConsoleCommand controller
      case typed of
        Just command -> applyCommand controller snapshot command
        Nothing -> do
          commands <- readMissionCommands controller.missionControllerControl
          mapM_ (journalRejectionOnce controller) commands.missionCommandsRejected
          case commands.missionCommandsAccepted of
            (command : _) -> applyCommand controller snapshot command
            [] -> case missionRunnerHalt snapshot.missionSnapshotLifecycle of
              Just halt -> pure (MissionStopped halt)
              Nothing -> advance controller snapshot

-- | Queues one command built inside this process, with runner authority.
--
-- The one way to produce an authenticated command, and it is a function call
-- rather than a channel: a caller that can reach it is already inside the
-- controller.
submitConsoleCommand :: MissionController -> Text -> MissionCommandPayload -> IO ()
submitConsoleCommand controller commandId payload = do
  command <- runnerCommand commandId payload
  atomicModifyIORef' controller.missionControllerConsole (\queued -> (queued <> [command], ()))

takeConsoleCommand :: MissionController -> IO (Maybe MissionSubmittedCommand)
takeConsoleCommand controller =
  atomicModifyIORef' controller.missionControllerConsole $ \queued -> case queued of
    [] -> ([], Nothing)
    (command : rest) -> (rest, Just command)

-- | Reconcile, then dispatch, then settle — the first of the three that has
-- something to do.
advance :: MissionController -> MissionSnapshot -> IO MissionIteration
advance controller snapshot = do
  observed <- observeOneSession controller snapshot
  case observed of
    Just iteration -> pure iteration
    Nothing -> advanceSteps controller snapshot

-- | Reconcile, then dispatch, then settle.
advanceSteps :: MissionController -> MissionSnapshot -> IO MissionIteration
advanceSteps controller snapshot = do
  -- Both crash windows are answered from the invocation file before anything
  -- else looks at the step records, because in both of them the step record is
  -- exactly what a run that never dispatched would have left and only the
  -- invocation file knows better.
  recorded <-
    readMissionInvocations
      controller.missionControllerMission
      controller.missionControllerStore.missionStoreRepository
      controller.missionControllerInvocations
  case recorded of
    Left detail -> pure (MissionControllerFailed detail)
    Right states -> case dispatchedButUnregistered states snapshot of
      Just (step, session) -> registerDispatchedSession controller snapshot step session
      Nothing -> case unresolvedDispatchOf states controller.missionControllerSpecification snapshot of
        Just (step, invocation) -> resolveOpenInvocation controller snapshot step invocation
        Nothing -> advanceReconciled controller snapshot

-- | What to make of an invocation this store never saw the end of.
--
-- Asked of the launch itself rather than guessed at. If a worker's own
-- specification names this invocation then the effect happened, the worker is
-- this mission's, and the right answer is to adopt it — which is what the
-- association exists for. Only when no such worker can be found is the outcome
-- genuinely unknown, and requirement 7 is explicit that such a step is
-- resolved by direction or fresh evidence and never by trying again.
resolveOpenInvocation :: MissionController -> MissionSnapshot -> MissionStepId -> MissionInvocationId -> IO MissionIteration
resolveOpenInvocation controller snapshot step invocation = do
  adopted <- controller.missionControllerDriver.missionDriverAdoptInvocation invocation
  case adopted of
    Left detail -> pure (MissionControllerFailed detail)
    Right (Just session) -> do
      now <- getCurrentTime
      _ <-
        concludeMissionInvocation
          controller.missionControllerInvocations
          invocation
          (MissionInvocationDispatched session.unMissionSessionId)
          now
      registerDispatchedSession controller snapshot step session
    Right Nothing ->
      applyStepLifecycle
        controller
        snapshot
        step
        MissionStepOutcomeUnknown
        ( "invocation "
            <> invocation.unMissionInvocationId
            <> " was journaled and no worker records it; whether its effect happened is unknown"
        )

-- | Adopts a worker an invocation records but the snapshot never registered.
--
-- A repair rather than a reattachment: the next pass reattaches through the
-- ordinary evidence path once the session is in the tree where that path can
-- see it.
registerDispatchedSession :: MissionController -> MissionSnapshot -> MissionStepId -> MissionSessionId -> IO MissionIteration
registerDispatchedSession controller snapshot step session = do
  written <-
    writeStep
      controller
      snapshot
      step
      MissionStepRunning
      ("adopted session " <> session.unMissionSessionId <> " from its invocation record")
      (Just (session, Nothing, Nothing))
  pure $ case written of
    Left detail -> MissionControllerFailed detail
    Right () -> MissionAdvanced (MissionStepAttached step session)

advanceReconciled :: MissionController -> MissionSnapshot -> IO MissionIteration
advanceReconciled controller snapshot = do
  reconciled <- reconcileOneStep controller snapshot
  case reconciled of
    Just iteration -> pure iteration
    Nothing -> case cancelledByDependency controller.missionControllerSpecification snapshot of
      Just (step, dependency) ->
        applyStepLifecycle
          controller
          snapshot
          step.missionPlanStepId
          MissionStepCancelled
          ("its dependency " <> dependency.unMissionStepId <> " did not succeed")
      Nothing -> case nextDispatchableStep controller.missionControllerSpecification snapshot of
        Just step -> dispatchStep controller snapshot step
        Nothing
          | anyLive snapshot -> pure (MissionAwaiting "registered work is live")
          | otherwise -> settle controller snapshot

-- | Records the end of the first registered session that has one.
--
-- The mission's session tree is what requirement 11's accounting reads, and
-- nothing else updates it: a step record says which sessions a step started,
-- but only this pass can say that one of them has stopped. Without it a
-- registered child would stay unsettled for ever and its parent could never
-- terminalize — which is the same deadlock, wearing the safeguard's clothes.
--
-- One session per iteration, like every other transition here.
observeOneSession :: MissionController -> MissionSnapshot -> IO (Maybe MissionIteration)
observeOneSession controller snapshot = go unsettled
  where
    unsettled =
      [ node
      | node <- snapshot.missionSnapshotSessions,
        missionSessionDisposition node /= MissionSessionSettled
      ]
    go [] = pure Nothing
    go (node : rest) = do
      reading <- controller.missionControllerDriver.missionDriverObserveSession node.missionSessionId
      case reading of
        Left detail -> pure (Just (MissionControllerFailed detail))
        Right Nothing -> go rest
        Right (Just observation) ->
          Just <$> recordSessionObservation controller snapshot node observation

-- | Writes one session's terminal observation into the snapshot.
recordSessionObservation :: MissionController -> MissionSnapshot -> MissionSessionNode -> MissionTerminalObservation -> IO MissionIteration
recordSessionObservation controller snapshot node observation = do
  now <- getCurrentTime
  let updated =
        snapshot
          { missionSnapshotSessions = map recordOn snapshot.missionSnapshotSessions,
            missionSnapshotUpdatedAt = now
          }
      recordOn candidate
        | candidate.missionSessionId /= node.missionSessionId = candidate
        | otherwise = candidate {missionSessionObservation = Just observation}
  written <- writeMissionSnapshot controller.missionControllerStore updated
  case written of
    Left detail -> pure (MissionControllerFailed detail)
    Right () -> do
      _ <-
        recordMissionEvent
          controller.missionControllerStore
          ( ( missionEvent
                controller.missionControllerMission
                controller.missionControllerStore.missionStoreRepository
                now
                "session_settled"
                observation.missionObservationDetail
            )
              {missionEventSession = Just node.missionSessionId}
          )
      pure
        ( MissionAdvanced
            ( MissionSessionEnded
                node.missionSessionId
                (maybe "it ended" id observation.missionObservationDetail)
            )
        )

-- | Whether any step is still under way.
anyLive :: MissionSnapshot -> Bool
anyLive snapshot =
  any
    ((`elem` [MissionStepDispatching, MissionStepRunning, MissionStepRecovering]) . (.missionStepRecordLifecycle))
    snapshot.missionSnapshotSteps

-- | The first step whose durable lifecycle disagrees with live evidence.
--
-- One step per iteration, deliberately: the classification of the second may
-- depend on what the first wrote, and reconciling both against one reading is
-- how a controller acts on a state that never existed.
reconcileOneStep :: MissionController -> MissionSnapshot -> IO (Maybe MissionIteration)
reconcileOneStep controller snapshot = go candidates
  where
    -- Plan order, which is the immutable record of what was asked for. Taking
    -- it from the snapshot instead would let a rewritten snapshot decide which
    -- step a pass reconciles first.
    candidates =
      [ step
      | step <- controller.missionControllerSpecification.missionSpecificationPlan,
        Just record <- [missionStepRecordFor step.missionPlanStepId snapshot],
        record.missionStepRecordLifecycle
          `elem` [MissionStepDispatching, MissionStepRunning, MissionStepRecovering, MissionStepOutcomeUnknown]
      ]
    -- The invocation record is this module's to supply, not the driver's.
    -- Requirement 7's unknown outcome is a fact about what /this/ controller
    -- journaled before it acted, and a driver that could decide it would be a
    -- second opinion about the one file that is meant to settle the question.
    withInvocation states evidence =
      evidence
        { missionEvidenceInvocation =
            case [ state
                 | state <- reverse states,
                   state.missionInvocationRecord.missionInvocationStep == evidence.missionEvidenceStep
                 ] of
              (state : _) -> Just state
              [] -> Nothing
        }
    go [] = pure Nothing
    go (step : rest) = case missionStepRecordFor step.missionPlanStepId snapshot of
      Nothing -> go rest
      Just record -> do
        gathered <- controller.missionControllerDriver.missionDriverStepEvidence step record
        recorded <-
          readMissionInvocations
            controller.missionControllerMission
            controller.missionControllerStore.missionStoreRepository
            controller.missionControllerInvocations
        case (gathered, recorded) of
          (Left detail, _) -> pure (Just (MissionControllerFailed detail))
          (_, Left detail) -> pure (Just (MissionControllerFailed detail))
          (Right gatheredEvidence, Right states) -> case classifyMissionWork (withInvocation states gatheredEvidence) of
            MissionWorkAttachable reading
              | record.missionStepRecordLifecycle == MissionStepRunning -> go rest
              | otherwise ->
                  Just
                    <$> applyAttachment controller snapshot step.missionPlanStepId reading
            MissionWorkLanded detail
              | stepHasUnsettledDescendants snapshot step.missionPlanStepId ->
                  -- Requirement 11: an owning action stays nonterminal while a
                  -- registered child is still live or unverifiable. Settling it
                  -- here would orphan that child out of the mission's account
                  -- of itself.
                  go rest
              | otherwise ->
                  Just
                    <$> applyStepLifecycle controller snapshot step.missionPlanStepId MissionStepSucceeded detail
            MissionWorkFailedExternally failure ->
              Just
                <$> applyStepLifecycle
                  controller
                  snapshot
                  step.missionPlanStepId
                  (missionStepFailureLifecycle failure)
                  (missionStepFailureMessage failure)
            MissionWorkNeedsInput detail
              | record.missionStepRecordLifecycle == MissionStepNeedsInput -> go rest
              | otherwise ->
                  Just
                    <$> applyStepLifecycle controller snapshot step.missionPlanStepId MissionStepNeedsInput detail
            MissionWorkConflicting detail -> do
              iteration <- applyMissionLifecycle controller snapshot MissionPaused detail
              pure (Just iteration)
            MissionWorkUnresolved detail
              | record.missionStepRecordLifecycle == MissionStepOutcomeUnknown -> go rest
              | otherwise ->
                  Just
                    <$> applyStepLifecycle controller snapshot step.missionPlanStepId MissionStepOutcomeUnknown detail
            -- Nothing outside this mission has anything to say about a step
            -- that is already under way. That is not a step to wait on: its
            -- worker is not live (a live one classifies as attachable), no
            -- result landed, and no invocation explains it — the record it was
            -- dispatched against is simply gone. Leaving it running is what
            -- made the foreground runner wait for ever on a worker nobody
            -- could find.
            MissionWorkUnobserved
              | record.missionStepRecordLifecycle == MissionStepOutcomeUnknown -> go rest
              | otherwise ->
                  Just
                    <$> applyStepLifecycle
                      controller
                      snapshot
                      step.missionPlanStepId
                      MissionStepOutcomeUnknown
                      "no live worker, no recorded result, and no evidence of what became of it"

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

-- | Journal the intent, recheck the precondition, then act.
--
-- The order is requirement 5's and requirement 8's, and it is the only order
-- that satisfies both. The record has to exist before the effect, so a crash
-- in between leaves an invocation nobody saw the end of; and the precondition
-- has to be rechecked after the record and before the effect, so nothing is
-- mutated against a target that moved while the plan was being written down.
dispatchStep :: MissionController -> MissionSnapshot -> MissionPlanStep -> IO MissionIteration
dispatchStep controller snapshot step = do
  planned <- observePlannedVersion controller step
  case planned of
    Left detail -> pure (MissionControllerFailed detail)
    Right plannedVersion -> do
      invocation <- newMissionInvocationId step.missionPlanStepId (length snapshot.missionSnapshotSteps)
      now <- getCurrentTime
      journaled <-
        recordMissionInvocation
          controller.missionControllerInvocations
          MissionInvocation
            { missionInvocationId = invocation,
              missionInvocationMission = controller.missionControllerMission,
              missionInvocationRepository = controller.missionControllerStore.missionStoreRepository,
              missionInvocationStep = step.missionPlanStepId,
              missionInvocationAction = step.missionPlanStepAction,
              missionInvocationTarget = step.missionPlanStepTarget,
              missionInvocationVersion = plannedVersion,
              missionInvocationEffect = MissionEffectDispatch step.missionPlanStepAction,
              missionInvocationAt = now
            }
      case journaled of
        Left detail -> pure (MissionControllerFailed detail)
        Right () -> do
          -- The durable marker that says an effect was about to be attempted.
          -- If it cannot be written the effect must not be attempted either:
          -- a launch whose step still reads @pending@ is a launch the next run
          -- would make a second time.
          marked <- applyStepLifecycleSilently controller snapshot step.missionPlanStepId MissionStepDispatching "journaled before launch"
          case marked of
            Left detail -> do
              now' <- getCurrentTime
              _ <-
                concludeMissionInvocation
                  controller.missionControllerInvocations
                  invocation
                  (MissionInvocationAbandoned ("the dispatching state could not be recorded: " <> detail))
                  now'
              pure (MissionControllerFailed detail)
            Right () -> performDispatch controller snapshot step invocation plannedVersion

-- | The precondition read, taken when the plan is made.
observePlannedVersion :: MissionController -> MissionPlanStep -> IO (Either Text (Maybe MissionTargetVersion))
observePlannedVersion controller step = case step.missionPlanStepTarget of
  Nothing -> pure (Right Nothing)
  Just target -> fmap Just <$> controller.missionControllerDriver.missionDriverObserveTarget target

-- | The recheck and the effect, in that order and with nothing between them.
performDispatch :: MissionController -> MissionSnapshot -> MissionPlanStep -> MissionInvocationId -> Maybe MissionTargetVersion -> IO MissionIteration
performDispatch controller snapshot step invocation plannedVersion = do
  rechecked <- observePlannedVersion controller step
  case rechecked of
    Left detail -> concludeUnattempted controller snapshot invocation step detail
    Right currentVersion -> case (plannedVersion, currentVersion) of
      (Just recorded, Just observed)
        | not (missionVersionHolds recorded observed) -> do
            let stale = MissionStaleVersion {missionStaleRecorded = recorded, missionStaleObserved = observed}
            now <- getCurrentTime
            _ <- concludeMissionInvocation controller.missionControllerInvocations invocation (MissionInvocationStale stale) now
            applyStepLifecycle
              controller
              snapshot
              step.missionPlanStepId
              MissionStepPending
              (missionStepFailureMessage (MissionFailureStaleVersion (missionStaleVersionMessage stale)))
      _ -> do
        let reading = liveReadingFor snapshot step.missionPlanStepId
        accepted <-
          controller.missionControllerDriver.missionDriverDispatch
            MissionDispatchRequest
              { missionDispatchStep = step,
                missionDispatchTarget = step.missionPlanStepTarget,
                missionDispatchVersion = currentVersion,
                missionDispatchContinuation =
                  missionContinuation controller.missionControllerSpecification snapshot step reading,
                missionDispatchInvocation = invocation
              }
        now <- getCurrentTime
        case accepted of
          Left failure -> do
            _ <-
              concludeMissionInvocation
                controller.missionControllerInvocations
                invocation
                (MissionInvocationRefused (missionStepFailureMessage failure))
                now
            iteration <-
              applyStepLifecycle
                controller
                snapshot
                step.missionPlanStepId
                (missionStepFailureLifecycle failure)
                (missionStepFailureMessage failure)
            pure $ case iteration of
              MissionAdvanced _ -> MissionAdvanced (MissionStepBlocked step.missionPlanStepId failure)
              other -> other
          Right acceptance -> do
            _ <-
              concludeMissionInvocation
                controller.missionControllerInvocations
                invocation
                (MissionInvocationDispatched acceptance.missionAcceptedWorker)
                now
            written <-
              writeStep
                controller
                snapshot
                step.missionPlanStepId
                MissionStepRunning
                acceptance.missionAcceptedDetail
                ( Just
                    ( acceptance.missionAcceptedSession,
                      Nothing,
                      acceptance.missionAcceptedProviderSession
                    )
                )
            pure $ case written of
              Left detail -> MissionControllerFailed detail
              Right () ->
                MissionAdvanced
                  (MissionStepDispatched step.missionPlanStepId invocation acceptance.missionAcceptedSession)

-- | An invocation whose effect was never attempted, because the precondition
-- could not be reread.
--
-- The durable record has to be left saying what is true: nothing happened —
-- this controller can see it never called the driver — so the invocation is
-- abandoned rather than left unresolved, and the step goes back to @pending@
-- for a later run to plan again from a fresh reading.
--
-- The mission's own lifecycle is deliberately left alone. Writing a blocked
-- lifecycle here would make a transient unreachable network into a state every
-- later run halts on until somebody clears it, which is a much longer outage
-- than the one that caused it. The run ends instead, reported as a run that
-- could not establish what it needed; the mission is exactly where it was, and
-- the next run starts by taking the reading this one could not.
concludeUnattempted :: MissionController -> MissionSnapshot -> MissionInvocationId -> MissionPlanStep -> Text -> IO MissionIteration
concludeUnattempted controller snapshot invocation step detail = do
  now <- getCurrentTime
  _ <- concludeMissionInvocation controller.missionControllerInvocations invocation (MissionInvocationAbandoned detail) now
  written <-
    writeStep
      controller
      snapshot
      step.missionPlanStepId
      MissionStepPending
      ("nothing was dispatched; the precondition could not be reread: " <> detail)
      Nothing
  pure (MissionControllerFailed (either id (const detail) written))

-- | The session a step already owns, if the snapshot records one.
liveReadingFor :: MissionSnapshot -> MissionStepId -> Maybe MissionWorkerReading
liveReadingFor snapshot step =
  case [node | node <- snapshot.missionSnapshotSessions, node.missionSessionStep == Just step] of
    (node : _) ->
      Just
        MissionWorkerReading
          { missionWorkerSession = node.missionSessionId,
            missionWorkerLive = False,
            missionWorkerCompatible = True,
            missionWorkerTerminal = Nothing,
            missionWorkerProviderSession = node.missionSessionProviderSessionId
          }
    [] -> Nothing

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

-- | Applies exactly one command, and journals what it did before consuming it.
--
-- The ordering matters because the two steps can be separated by a crash. The
-- journal entry is written first, so a run that dies before the file is
-- removed leaves an account of what was done; the file is still there, so the
-- next run applies the command again. What makes that safe is a property of
-- each command rather than of this ordering: a pause, a resume, and an
-- override are writes of a state the second application reaches identically,
-- and the two commands that reach outside — a subtree termination and a child
-- request — are each deduplicated by an invocation identity derived from the
-- command, so a second application finds the first one's record and returns
-- what it already did.
applyCommand :: MissionController -> MissionSnapshot -> MissionSubmittedCommand -> IO MissionIteration
applyCommand controller snapshot command = case command.missionCommandPayload of
  MissionPauseCommand reason -> do
    -- Requirement 11: a pause stops dispatch and terminates nothing. The
    -- registered descendants are deliberately left exactly as they are.
    iteration <- applyMissionLifecycle controller snapshot MissionPaused reason
    finish iteration ("paused: " <> reason)
  MissionResumeCommand -> do
    iteration <- applyMissionLifecycle controller snapshot MissionRunning "resumed"
    finish iteration "resumed"
  MissionUserOverrideCommand step detail
    | not (overrideAuthorized command.missionCommandAuthority) -> do
        refused <-
          refuse
            command
            ( "a "
                <> missionCommandAuthorityTag command.missionCommandAuthority
                <> " client cannot record a user_override or resolve an unknown outcome"
            )
        pure refused
    | otherwise -> do
        iteration <- applyStepLifecycle controller snapshot step MissionStepPending ("user override: " <> detail)
        finish iteration ("user override on " <> step.unMissionStepId)
  MissionTerminateSubtreeCommand session reason
    | not (overrideAuthorized command.missionCommandAuthority) ->
        refuse command "only the runner's own console may terminate a registered subtree"
    | otherwise -> terminateSubtree controller snapshot command session reason
  MissionChildRequestCommand request -> registerChild controller snapshot command request
  where
    finish iteration detail = do
      journalCommand controller command detail
      consumeMissionCommand command
      pure $ case iteration of
        MissionAdvanced _ -> MissionAdvanced (MissionCommandApplied command.missionCommandId detail)
        other -> other
    refuse submitted detail = do
      journalCommand controller submitted ("refused: " <> detail)
      consumeMissionCommand submitted
      pure (MissionAdvanced (MissionCommandRefused submitted.missionCommandId detail))

-- | Requirement 11's explicit, journaled, recursive termination.
terminateSubtree :: MissionController -> MissionSnapshot -> MissionSubmittedCommand -> MissionSessionId -> Text -> IO MissionIteration
terminateSubtree controller snapshot command session reason = do
  recorded <-
    readMissionInvocations
      controller.missionControllerMission
      controller.missionControllerStore.missionStoreRepository
      controller.missionControllerInvocations
  case recorded of
    Left detail -> pure (MissionControllerFailed detail)
    Right states -> case missionInvocationFor (terminationInvocation command) states of
      -- A replay of a termination this controller already performed. Signalling
      -- the subtree again would journal a second account of one operator
      -- command, which is the duplicate the invocation identity exists to
      -- prevent.
      Just _ -> do
        journalCommand controller command "replay of a termination already performed"
        consumeMissionCommand command
        pure
          ( MissionAdvanced
              (MissionCommandApplied command.missionCommandId "the subtree was already terminated")
          )
      Nothing -> performTermination controller snapshot command session reason

terminationInvocation :: MissionSubmittedCommand -> MissionInvocationId
terminationInvocation command = MissionInvocationId ("terminate-" <> command.missionCommandId)

performTermination :: MissionController -> MissionSnapshot -> MissionSubmittedCommand -> MissionSessionId -> Text -> IO MissionIteration
performTermination controller snapshot command session reason = do
  let subtree = missionSessionSubtree snapshot session
      identities = map (.missionSessionId) subtree
  now <- getCurrentTime
  let invocation = terminationInvocation command
  journaled <-
    recordMissionInvocation
      controller.missionControllerInvocations
      MissionInvocation
        { missionInvocationId = invocation,
          missionInvocationMission = controller.missionControllerMission,
          missionInvocationRepository = controller.missionControllerStore.missionStoreRepository,
          missionInvocationStep = MissionStepId "-",
          missionInvocationAction = "terminate_subtree",
          missionInvocationTarget = Nothing,
          missionInvocationVersion = Nothing,
          missionInvocationEffect = MissionEffectTerminateSubtree session.unMissionSessionId,
          missionInvocationAt = now
        }
  case journaled of
    Left detail -> pure (MissionControllerFailed detail)
    Right () -> do
      journalCommand
        controller
        command
        ( "terminating "
            <> Text.pack (show (length identities))
            <> " registered session(s) under "
            <> session.unMissionSessionId
            <> ": "
            <> reason
        )
      terminated <- controller.missionControllerDriver.missionDriverTerminate identities
      concluded <- getCurrentTime
      _ <-
        concludeMissionInvocation
          controller.missionControllerInvocations
          invocation
          ( case terminated of
              Left detail -> MissionInvocationRefused detail
              Right () -> MissionInvocationCompleted ("ended " <> Text.pack (show (length identities)) <> " session(s)")
          )
          concluded
      consumeMissionCommand command
      pure $ case terminated of
        Left detail -> MissionControllerFailed detail
        Right () -> MissionAdvanced (MissionSubtreeTerminated session (length identities))

-- | Requirement 12's registered child request.
--
-- Four checks, and the order matters. The channel decides whether the request
-- may be believed at all; the mission it names decides whether it is this
-- mission's request; the parent it names is checked against the live
-- registered session tree; and only then is the request identity looked up, so
-- a replay returns the child it already produced instead of launching a second
-- one.
registerChild :: MissionController -> MissionSnapshot -> MissionSubmittedCommand -> MissionChildRequest -> IO MissionIteration
registerChild controller snapshot command request
  | not (overrideAuthorized command.missionCommandAuthority) =
      refuseChild "a child request must arrive on the runner's own authenticated channel"
  | request.missionChildRequestMission /= controller.missionControllerMission =
      refuseChild
        ( "the request names mission "
            <> request.missionChildRequestMission.unMissionId
            <> " rather than "
            <> controller.missionControllerMission.unMissionId
        )
  | not parentIsLive =
      refuseChild
        ( "its parent session "
            <> request.missionChildRequestParent.unMissionSessionId
            <> " is not a live registered session of this mission"
        )
  | otherwise = do
      recorded <-
        readMissionInvocations
          controller.missionControllerMission
          controller.missionControllerStore.missionStoreRepository
          controller.missionControllerInvocations
      case recorded of
        Left detail -> pure (MissionControllerFailed detail)
        Right states -> case missionInvocationFor childInvocation states of
          Just existing -> do
            journalCommand
              controller
              command
              ( "replay of child request "
                  <> request.missionChildRequestId
                  <> "; returning "
                  <> renderExisting existing
              )
            consumeMissionCommand command
            pure
              ( MissionAdvanced
                  ( MissionCommandApplied
                      command.missionCommandId
                      ("child request already answered: " <> renderExisting existing)
                  )
              )
          Nothing -> launchChild controller snapshot command request childInvocation
  where
    childInvocation =
      MissionInvocationId
        ( "child-"
            <> request.missionChildRequestParent.unMissionSessionId
            <> "-"
            <> request.missionChildRequestId
        )
    -- Registered /and/ not settled. Registration alone would let a session
    -- that has already ended keep spawning children, which is the dead-parent
    -- forgery requirement 12 names; and an unverifiable session counts as
    -- surviving, because nothing proves it is gone.
    parentIsLive =
      any
        ( \node ->
            node.missionSessionId == request.missionChildRequestParent
              && missionSessionDisposition node /= MissionSessionSettled
        )
        (concatMap (missionSessionSubtree snapshot) roots)
    roots = map (.missionSessionId) [node | node <- snapshot.missionSnapshotSessions, node.missionSessionParent == Nothing]
    renderExisting existing = case existing.missionInvocationOutcome of
      Just (MissionInvocationDispatched worker) -> "child " <> worker
      Just outcome -> Text.pack (show outcome)
      Nothing -> "an invocation whose outcome is not yet recorded"
    refuseChild detail = do
      journalCommand controller command ("refused child request: " <> detail)
      consumeMissionCommand command
      pure (MissionAdvanced (MissionCommandRefused command.missionCommandId detail))

-- | The launch itself, with the same journal-then-act ordering every other
-- effect uses.
-- A child is an external effect like any other, so it takes the same
-- discipline: its target is observed, the observation is journaled with the
-- invocation, and the reading is rechecked and carried to the owning action's
-- own boundary. Exempting it because the request came from inside the mission
-- would put the one dispatch a provider can ask for outside the precondition
-- every other dispatch obeys.
launchChild :: MissionController -> MissionSnapshot -> MissionSubmittedCommand -> MissionChildRequest -> MissionInvocationId -> IO MissionIteration
launchChild controller snapshot command request invocation = do
  let step =
        MissionPlanStep
          { missionPlanStepId = MissionStepId ("child-" <> request.missionChildRequestId),
            missionPlanStepAction = request.missionChildRequestAction,
            missionPlanStepSummary = "a registered child of " <> request.missionChildRequestParent.unMissionSessionId,
            missionPlanStepTarget = request.missionChildRequestTarget,
            missionPlanStepDependsOn = []
          }
  planned <- observePlannedVersion controller step
  case planned of
    Left detail -> do
      journalCommand controller command ("the child's target could not be read: " <> detail)
      consumeMissionCommand command
      pure (MissionAdvanced (MissionCommandRefused command.missionCommandId detail))
    Right plannedVersion -> launchPlannedChild controller snapshot command request invocation step plannedVersion

launchPlannedChild :: MissionController -> MissionSnapshot -> MissionSubmittedCommand -> MissionChildRequest -> MissionInvocationId -> MissionPlanStep -> Maybe MissionTargetVersion -> IO MissionIteration
launchPlannedChild controller snapshot command request invocation step plannedVersion = do
  now <- getCurrentTime
  journaled <-
    recordMissionInvocation
      controller.missionControllerInvocations
      MissionInvocation
        { missionInvocationId = invocation,
          missionInvocationMission = controller.missionControllerMission,
          missionInvocationRepository = controller.missionControllerStore.missionStoreRepository,
          missionInvocationStep = step.missionPlanStepId,
          missionInvocationAction = request.missionChildRequestAction,
          missionInvocationTarget = request.missionChildRequestTarget,
          missionInvocationVersion = plannedVersion,
          missionInvocationEffect = MissionEffectDispatch request.missionChildRequestAction,
          missionInvocationAt = now
        }
  case journaled of
    Left detail -> pure (MissionControllerFailed detail)
    Right () -> do
      rechecked <- observePlannedVersion controller step
      accepted <- case (plannedVersion, rechecked) of
        (_, Left detail) -> pure (Left (MissionFailureOutcomeUnknown detail))
        (Just recorded, Right (Just observed))
          | not (missionVersionHolds recorded observed) ->
              pure
                ( Left
                    ( MissionFailureStaleVersion
                        (missionStaleVersionMessage (MissionStaleVersion recorded observed))
                    )
                )
        (_, Right currentVersion) ->
          controller.missionControllerDriver.missionDriverDispatch
            MissionDispatchRequest
              { missionDispatchStep = step,
                missionDispatchTarget = request.missionChildRequestTarget,
                missionDispatchVersion = currentVersion,
                missionDispatchContinuation =
                  missionContinuation controller.missionControllerSpecification snapshot step Nothing,
                missionDispatchInvocation = invocation
              }
      concluded <- getCurrentTime
      case accepted of
        Left failure -> do
          _ <-
            concludeMissionInvocation
              controller.missionControllerInvocations
              invocation
              (MissionInvocationRefused (missionStepFailureMessage failure))
              concluded
          journalCommand controller command ("child request failed: " <> missionStepFailureMessage failure)
          consumeMissionCommand command
          pure (MissionAdvanced (MissionCommandRefused command.missionCommandId (missionStepFailureMessage failure)))
        Right acceptance -> do
          _ <-
            concludeMissionInvocation
              controller.missionControllerInvocations
              invocation
              (MissionInvocationDispatched acceptance.missionAcceptedWorker)
              concluded
          -- The child joins the session tree under the parent that asked for
          -- it. Without the lineage it would be a session nothing accounts
          -- for: no termination would reach it and no parent would wait.
          written <-
            writeStep
              controller
              snapshot
              step.missionPlanStepId
              MissionStepRunning
              acceptance.missionAcceptedDetail
              ( Just
                  ( acceptance.missionAcceptedSession,
                    Just request.missionChildRequestParent,
                    acceptance.missionAcceptedProviderSession
                  )
              )
          journalCommand controller command ("registered child " <> acceptance.missionAcceptedWorker)
          consumeMissionCommand command
          pure $ case written of
            Left detail -> MissionControllerFailed detail
            Right () ->
              MissionAdvanced
                ( MissionCommandApplied
                    command.missionCommandId
                    ("registered child " <> acceptance.missionAcceptedWorker)
                )

-- ---------------------------------------------------------------------------
-- Writing the record
-- ---------------------------------------------------------------------------

settle :: MissionController -> MissionSnapshot -> IO MissionIteration
settle controller snapshot = case settledMissionLifecycle snapshot of
  Just lifecycle -> applyMissionLifecycle controller snapshot lifecycle "every step settled"
  Nothing -> case blockedMissionLifecycle snapshot of
    Just (lifecycle, detail) -> applyMissionLifecycle controller snapshot lifecycle detail
    Nothing -> pure (MissionAwaiting "no step is eligible and none is live")

applyAttachment :: MissionController -> MissionSnapshot -> MissionStepId -> MissionWorkerReading -> IO MissionIteration
applyAttachment controller snapshot step reading = do
  written <-
    writeStep
      controller
      snapshot
      step
      MissionStepRunning
      ("reattached to session " <> reading.missionWorkerSession.unMissionSessionId)
      (Just (reading.missionWorkerSession, Nothing, reading.missionWorkerProviderSession))
  pure $ case written of
    Left detail -> MissionControllerFailed detail
    Right () -> MissionAdvanced (MissionStepAttached step reading.missionWorkerSession)

applyStepLifecycle :: MissionController -> MissionSnapshot -> MissionStepId -> MissionStepLifecycle -> Text -> IO MissionIteration
applyStepLifecycle controller snapshot step lifecycle detail = do
  written <- writeStep controller snapshot step lifecycle detail Nothing
  pure $ case written of
    Left message -> MissionControllerFailed message
    Right () -> MissionAdvanced (MissionStepReconciled step lifecycle detail)

-- | The same write, for the intermediate state a dispatch passes through.
--
-- Not a transition: an iteration reports the one thing it achieved, and
-- @dispatching@ is a state the same iteration leaves behind. It is still
-- durable, because a crash between it and the launch is exactly the window the
-- invocation record and this lifecycle together describe.
applyStepLifecycleSilently :: MissionController -> MissionSnapshot -> MissionStepId -> MissionStepLifecycle -> Text -> IO (Either Text ())
applyStepLifecycleSilently controller snapshot step lifecycle detail =
  writeStep controller snapshot step lifecycle detail Nothing

applyMissionLifecycle :: MissionController -> MissionSnapshot -> MissionLifecycle -> Text -> IO MissionIteration
applyMissionLifecycle controller snapshot lifecycle detail = do
  now <- getCurrentTime
  let updated =
        snapshot
          { missionSnapshotLifecycle = lifecycle,
            missionSnapshotPause =
              if lifecycle == MissionPaused
                then MissionPause {missionPauseRequested = True, missionPauseReason = Just detail, missionPauseAt = Just now}
                else snapshot.missionSnapshotPause {missionPauseRequested = False},
            missionSnapshotLastReconciliation =
              Just
                MissionReconciliation
                  { missionReconciliationAt = now,
                    missionReconciliationOutcome = detail,
                    missionReconciliationSteps = []
                  },
            missionSnapshotUpdatedAt = now
          }
  written <- writeMissionSnapshot controller.missionControllerStore updated
  case written of
    Left message -> pure (MissionControllerFailed message)
    Right () -> do
      _ <-
        recordMissionEvent
          controller.missionControllerStore
          (missionEvent controller.missionControllerMission controller.missionControllerStore.missionStoreRepository now (missionLifecycleTag lifecycle) (Just detail))
      pure (MissionAdvanced (MissionLifecycleSet lifecycle detail))

-- | Adds the session a dispatch produced to the mission's own session tree.
--
-- Registering it is what makes it a mission session at all. Parent validation,
-- subtree termination, and unsettled-descendant accounting every one of them
-- read this tree and nothing else, so a worker recorded only as an identifier
-- on a step record is a worker no child can name as its parent, no termination
-- can reach, and no parent has to wait for. The lineage travels with the
-- registration for the same reason: a child's parent link is the only thing
-- that puts it inside a subtree.
--
-- Idempotent by identity, because a step that is reattached to a session it
-- already registered must not gain a second node for it.
registerSession :: MissionController -> MissionStepId -> Maybe (MissionSessionId, Maybe MissionSessionId, Maybe Text) -> [MissionSessionNode] -> [MissionSessionNode]
registerSession _ _ Nothing nodes = nodes
registerSession controller step (Just (identity, parent, providerSession)) nodes
  | any ((== identity) . (.missionSessionId)) nodes = nodes
  | otherwise = nodes <> [node]
  where
    node =
      MissionSessionNode
        { missionSessionId = identity,
          missionSessionMission = controller.missionControllerMission,
          missionSessionParent = parent,
          missionSessionStep = Just step,
          missionSessionProvider = "registry",
          missionSessionProviderSessionId = providerSession,
          -- Nothing recorded proves it is gone, which is exactly right for a
          -- session that has just been started: 'missionSessionDisposition'
          -- reads it as unverifiable, so a parent waits for it until the
          -- session pass observes it end.
          missionSessionOwnership = MissionProcessOwnership {missionProcessIdentity = Nothing, missionProcessGroup = Nothing},
          missionSessionLog = Nothing,
          missionSessionObservation = Nothing
        }

-- | Replaces one step record and journals the change.
--
-- The snapshot is written before the journal line, because the snapshot is
-- what the next iteration decides from and the journal is what a reader
-- replays: a crash between them loses a line of narration rather than a state.
writeStep :: MissionController -> MissionSnapshot -> MissionStepId -> MissionStepLifecycle -> Text -> Maybe (MissionSessionId, Maybe MissionSessionId, Maybe Text) -> IO (Either Text ())
writeStep controller snapshot step lifecycle detail registration = do
  now <- getCurrentTime
  let session = (\(identity, _, _) -> identity) <$> registration
      updated =
        snapshot
          { missionSnapshotSessions = registerSession controller step registration snapshot.missionSnapshotSessions,
            missionSnapshotSteps = map replace snapshot.missionSnapshotSteps,
            missionSnapshotCurrentStep = Just step,
            missionSnapshotLastReconciliation =
              Just
                MissionReconciliation
                  { missionReconciliationAt = now,
                    missionReconciliationOutcome = missionStepLifecycleTag lifecycle,
                    missionReconciliationSteps = [step]
                  },
            missionSnapshotUpdatedAt = now
          }
      replace record
        | record.missionStepRecordId /= step = record
        | otherwise =
            record
              { missionStepRecordLifecycle = lifecycle,
                missionStepRecordDetail = Just detail,
                missionStepRecordSessions =
                  case session of
                    Nothing -> record.missionStepRecordSessions
                    Just identity
                      | identity `elem` record.missionStepRecordSessions -> record.missionStepRecordSessions
                      | otherwise -> record.missionStepRecordSessions <> [identity],
                missionStepRecordUpdatedAt = now
              }
  written <- writeMissionSnapshot controller.missionControllerStore updated
  case written of
    Left message -> pure (Left message)
    Right () -> do
      _ <-
        recordMissionEvent
          controller.missionControllerStore
          ( ( missionEvent
                controller.missionControllerMission
                controller.missionControllerStore.missionStoreRepository
                now
                ("step_" <> missionStepLifecycleTag lifecycle)
                (Just detail)
            )
              { missionEventStep = Just step,
                missionEventSession = session
              }
          )
      pure (Right ())

journalCommand :: MissionController -> MissionSubmittedCommand -> Text -> IO ()
journalCommand controller command detail = do
  now <- getCurrentTime
  _ <-
    recordMissionEvent
      controller.missionControllerStore
      ( missionEvent
          controller.missionControllerMission
          controller.missionControllerStore.missionStoreRepository
          now
          ("command_" <> missionCommandPayloadTag command.missionCommandPayload)
          ( Just
              ( command.missionCommandId
                  <> " ("
                  <> missionCommandAuthorityTag command.missionCommandAuthority
                  <> "): "
                  <> detail
              )
          )
      )
  pure ()

-- | Journals an unusable command file the first time this run meets it.
journalRejectionOnce :: MissionController -> MissionCommandRejection -> IO ()
journalRejectionOnce controller rejection = do
  fresh <-
    atomicModifyIORef'
      controller.missionControllerReported
      ( \seen ->
          if Set.member rejection.missionRejectionPath seen
            then (seen, False)
            else (Set.insert rejection.missionRejectionPath seen, True)
      )
  if fresh then journalRejection controller rejection else pure ()

journalRejection :: MissionController -> MissionCommandRejection -> IO ()
journalRejection controller rejection = do
  now <- getCurrentTime
  _ <-
    recordMissionEvent
      controller.missionControllerStore
      ( missionEvent
          controller.missionControllerMission
          controller.missionControllerStore.missionStoreRepository
          now
          "command_rejected"
          (Just (missionCommandRejectionMessage rejection))
      )
  pure ()

missionEvent :: MissionId -> MissionRepository -> UTCTime -> Text -> Maybe Text -> MissionEvent
missionEvent mission repository now kind detail =
  MissionEvent
    { missionEventMission = mission,
      missionEventRepository = repository,
      missionEventAt = now,
      missionEventStep = Nothing,
      missionEventSession = Nothing,
      missionEventKind = kind,
      missionEventDetail = detail
    }
