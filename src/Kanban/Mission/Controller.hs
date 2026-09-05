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
    childInvocationId,
    childStepId,
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (find)
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
    missionInvocationSequence,
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
  ( MissionContinuation (..),
    MissionExternalWork (..),
    MissionHalt,
    MissionOpenDispatch (..),
    MissionStepEvidence (..),
    MissionStepFailure (..),
    MissionWorkerConclusion (..),
    MissionWorkerReading (..),
    blockedMissionLifecycle,
    cancelledByDependency,
    classifyMissionWork,
    dispatchedButUnregistered,
    missionContinuation,
    missionOpenDispatchIsChild,
    missionRunnerHalt,
    missionSessionSubtree,
    missionStepFailureLifecycle,
    missionStepFailureMessage,
    missionStepRecordFor,
    nextDispatchableStep,
    settledMissionLifecycle,
    stepHasUnsettledDescendants,
    stepUnverifiableDescendant,
    unresolvedDispatchOf,
    unresolvedTerminationOf,
  )
import Kanban.Mission.Store (readMissionSnapshot, readMissionSpecification, recordMissionEvent, writeMissionSnapshot)
import Kanban.Mission.Types
  ( MissionEvent (..),
    MissionId (..),
    MissionLifecycle (..),
    MissionPause (..),
    MissionObservedOutcome (..),
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
    missionAcceptedDetail :: Text,
    -- | The result, where the action had one the moment it was asked.
    --
    -- Not every registered action owns a worker. The approval-queue read is
    -- answered by its own controller as the dispatch is made, so it leaves no
    -- durable child for a later pass to observe — and a mission that
    -- registered an invented session for it would spend every later iteration
    -- looking for a worker that was never going to exist, and settle the step
    -- as an unknown outcome having thrown the answer away.
    --
    -- 'Nothing' for every action that does own a worker, which is the ordinary
    -- case: its result is the worker's to reach and the evidence pass reads it
    -- later.
    missionAcceptedOutcome :: Maybe MissionWorkerConclusion
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
    --
    -- The step travels with it because what a session /achieved/ is an
    -- action-specific question, and a registered child has no step record for
    -- the evidence pass to ask it through: the controller reconstructs the
    -- child's action and target from the invocation that launched it, so the
    -- same registry validation reaches a child as reaches a plan step.
    -- 'Nothing' where nothing records what the session was doing at all.
    missionDriverObserveSession :: MissionSessionId -> Maybe MissionPlanStep -> IO (Either Text (Maybe MissionTerminalObservation)),
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
    missionDriverTerminate :: [MissionSessionId] -> IO (Either Text [MissionSessionId])
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
            [] -> do
              recorded <-
                readMissionInvocations
                  controller.missionControllerMission
                  controller.missionControllerStore.missionStoreRepository
                  controller.missionControllerInvocations
              case recorded of
                Left detail -> pure (MissionControllerFailed detail)
                Right states -> case missionRunnerHalt snapshot states of
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
  -- Every crash window is answered from the invocation file before anything
  -- else looks at the step records, because in each of them the step record is
  -- exactly what a run that never dispatched would have left — and for the two
  -- effects with no step record at all, the invocation file is the only place
  -- they were ever described.
  recorded <-
    readMissionInvocations
      controller.missionControllerMission
      controller.missionControllerStore.missionStoreRepository
      controller.missionControllerInvocations
  case recorded of
    Left detail -> pure (MissionControllerFailed detail)
    -- The termination first, because it is the one open effect that may
    -- already have ended the very sessions the passes below would otherwise
    -- read as live work to wait on.
    Right states -> case unresolvedTerminationOf states of
      Just (invocation, session) -> resolveOpenTermination controller snapshot invocation session
      Nothing -> case dispatchedButUnregistered states snapshot of
        Just (step, session, parent) -> registerDispatchedSession controller snapshot step session parent
        Nothing -> case unresolvedDispatchOf states controller.missionControllerSpecification snapshot of
          Just dispatch -> resolveOpenInvocation controller snapshot dispatch
          Nothing -> advanceReconciled controller snapshot

-- | What to make of an invocation this store never saw the end of.
--
-- Asked of the launch itself rather than guessed at. If a worker's own
-- specification names this invocation then the effect happened, the worker is
-- this mission's, and the right answer is to adopt it — which is what the
-- association exists for. Only when no such worker can be found is the outcome
-- genuinely unknown, and requirement 7 is explicit that such a step is
-- resolved by direction or fresh evidence and never by trying again.
resolveOpenInvocation :: MissionController -> MissionSnapshot -> MissionOpenDispatch -> IO MissionIteration
resolveOpenInvocation controller snapshot dispatch = do
  adopted <- controller.missionControllerDriver.missionDriverAdoptInvocation invocation
  case adopted of
    Left detail -> pure (MissionControllerFailed detail)
    Right (Just session) -> do
      now <- getCurrentTime
      closing controller invocation (MissionInvocationDispatched session.unMissionSessionId) now $
        registerDispatchedSession controller snapshot step session dispatch.missionOpenDispatchParent
    Right Nothing
      -- A registered child, whose unknown outcome has no step record to be
      -- written on. Closing the invocation is what stops the next iteration
      -- asking the same question of the same absent evidence for ever, and the
      -- halt beside it is what requirement 7 asks for instead of a retry: the
      -- launch may have happened, so only authenticated direction resolves it.
      | missionOpenDispatchIsChild snapshot dispatch -> do
          now <- getCurrentTime
          closing controller invocation (MissionInvocationUnknown unknownDetail) now $
            applyMissionLifecycle controller snapshot MissionWaitingInput unknownDetail
      | otherwise ->
          applyStepLifecycle
            controller
            snapshot
            step
            MissionStepOutcomeUnknown
            unknownDetail
  where
    invocation = dispatch.missionOpenDispatchInvocation
    step = dispatch.missionOpenDispatchStep
    unknownDetail =
      "invocation "
        <> invocation.unMissionInvocationId
        <> " was journaled and no worker records it; whether its effect happened is unknown"

-- | What to make of a subtree termination whose record is still open.
--
-- Every termination passes through here, not only one a crash interrupted,
-- because signalling is not ending. @terminateWorker@ asks a worker to stop
-- and returns; an ordinary one may be pending termination for a while yet, and
-- an issue action's child is only a queued command its host has still to act
-- on. A controller that closed the record when the signal was sent would be
-- recording, durably and as fact, that a subtree had ended at the moment it
-- was asked to.
--
-- So the sessions themselves are what closes it, and there are three answers
-- rather than two:
--
--   [every one ended] the termination demonstrably did what it was for, and
--     the record says so.
--   [one has not ended yet] a signalled worker that is still shutting down is
--     work in progress; this waits for it, exactly as it waits for any other
--     live registered work, bounded by that worker's own recorded deadline.
--   [one cannot be established] its record has been collected, or its
--     observation came back unknown. No further evidence is coming, so the
--     record is closed as unknown and the mission halts for authenticated
--     direction rather than carrying an effect nobody can account for.
--
-- The middle answer is the one this needs to have. Without it a normal
-- termination would halt the mission a moment after the signal, every time,
-- for the crime of not having finished yet.
--
-- A subtree with nothing in it closes the record too, and that is not the
-- vacuous case it looks like: nothing ever removes a node from the session
-- tree, so an empty subtree is a termination that had nothing registered to
-- signal rather than evidence that has gone missing.
resolveOpenTermination :: MissionController -> MissionSnapshot -> MissionInvocationId -> MissionSessionId -> IO MissionIteration
resolveOpenTermination controller snapshot invocation root = do
  observations <- mapM observe (missionSessionSubtree snapshot root)
  now <- getCurrentTime
  case sequence observations of
    Left unreadable -> pure (MissionControllerFailed unreadable)
    Right observed
      | all (== SubtreeMemberEnded) observed ->
          closing
            controller
            invocation
            (MissionInvocationCompleted ("every registered session under " <> root.unMissionSessionId <> " has ended"))
            now
            -- Reported as the termination it is rather than as a repair: the
            -- subtree is ended, and this iteration is what established it.
            (pure (MissionAdvanced (MissionSubtreeTerminated root (length observed))))
      | SubtreeMemberUnverifiable `elem` observed ->
          closing controller invocation (MissionInvocationUnknown detail) now $
            applyMissionLifecycle controller snapshot MissionWaitingInput detail
      | otherwise ->
          pure
            ( MissionAwaiting
                ( "the subtree under "
                    <> root.unMissionSessionId
                    <> " was signalled and has not finished ending"
                )
            )
  where
    detail =
      "termination "
        <> invocation.unMissionInvocationId
        <> " was journaled and the subtree under "
        <> root.unMissionSessionId
        <> " cannot be shown to have ended; whether the signal was delivered is unknown"
    -- Where one member of the subtree has got to.
    --
    -- The distinction the three answers above are made of: a session with no
    -- terminal observation yet has not ended and may still be ending, while
    -- one whose observation came back 'MissionObservedUnknown' is the honest
    -- \"its record is gone and nothing says how it went\" — which proves
    -- nothing about a signal and never will.
    observe node = do
      observed <- controller.missionControllerDriver.missionDriverObserveSession node.missionSessionId Nothing
      pure $ case observed of
        Left failure -> Left failure
        Right Nothing -> Right SubtreeMemberPending
        Right (Just observation) -> Right (case observation.missionObservationOutcome of
          MissionObservedExit _ -> SubtreeMemberEnded
          MissionObservedSignalled _ -> SubtreeMemberEnded
          MissionObservedUnknown -> SubtreeMemberUnverifiable)

-- | Where one member of a signalled subtree has got to.
--
-- Three rather than two, because \"has not ended\" and \"cannot be shown to
-- have ended\" call for opposite answers: the first is waited for and the
-- second stops the mission.
data SubtreeMember
  = SubtreeMemberEnded
  | SubtreeMemberPending
  | SubtreeMemberUnverifiable
  deriving stock (Eq, Show)

-- | Adopts a worker an invocation records but the snapshot never registered.
--
-- A repair rather than a reattachment: the next pass reattaches through the
-- ordinary evidence path once the session is in the tree where that path can
-- see it. The lineage comes from the invocation rather than from the snapshot,
-- because for a registered child the snapshot is exactly what does not have
-- it yet.
registerDispatchedSession :: MissionController -> MissionSnapshot -> MissionStepId -> MissionSessionId -> Maybe MissionSessionId -> IO MissionIteration
registerDispatchedSession controller snapshot step session parent = do
  written <-
    writeStep
      controller
      snapshot
      step
      MissionStepRunning
      ("adopted session " <> session.unMissionSessionId <> " from its invocation record")
      (Just (session, parent, Nothing))
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
observeOneSession controller snapshot = do
  recorded <-
    readMissionInvocations
      controller.missionControllerMission
      controller.missionControllerStore.missionStoreRepository
      controller.missionControllerInvocations
  case recorded of
    Left detail -> pure (Just (MissionControllerFailed detail))
    Right states -> go states unsettled
  where
    unsettled =
      [ node
      | node <- snapshot.missionSnapshotSessions,
        missionSessionDisposition node /= MissionSessionSettled
      ]
    go _ [] = pure Nothing
    go states (node : rest) = do
      reading <-
        controller.missionControllerDriver.missionDriverObserveSession
          node.missionSessionId
          (stepBehind states node)
      case reading of
        Left detail -> pure (Just (MissionControllerFailed detail))
        Right Nothing -> go states rest
        Right (Just observation)
          -- Already recorded, and unchanged. Writing it again would be a
          -- transition every iteration for ever: an unverifiable session is
          -- never settled, so it stays in the set this pass walks, and only
          -- the /change/ is news.
          | Just observation.missionObservationOutcome
              == ((.missionObservationOutcome) <$> node.missionSessionObservation) ->
              go states rest
          | otherwise -> Just <$> recordSessionObservation controller snapshot node observation

    -- What this session was doing, so its result can be judged the way a plan
    -- step's is.
    --
    -- A plan step for a session the plan started, and for a registered child
    -- the step its own launch invented — reconstructed from the invocation
    -- that recorded it, which is the only place a child's action and target
    -- were ever written down.
    stepBehind states node = do
      step <- node.missionSessionStep
      case find ((== step) . (.missionPlanStepId)) controller.missionControllerSpecification.missionSpecificationPlan of
        Just planned -> Just planned
        Nothing -> case [ state.missionInvocationRecord
                        | state <- states,
                          state.missionInvocationRecord.missionInvocationStep == step
                        ] of
          (record : _) ->
            Just
              MissionPlanStep
                { missionPlanStepId = step,
                  missionPlanStepAction = record.missionInvocationAction,
                  missionPlanStepSummary = "a registered child",
                  missionPlanStepTarget = record.missionInvocationTarget,
                  missionPlanStepDependsOn = []
                }
          [] -> Nothing

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
              -- Requirement 11: an owning action stays nonterminal while a
              -- registered child is still live or unverifiable. Settling it
              -- here would orphan that child out of the mission's account of
              -- itself.
              --
              -- Which of the two it is decides whether this is waiting or
              -- being stuck. A live child is work in progress and its parent
              -- waits, bounded by that child's own deadline; a child nothing
              -- can prove is gone is a wait that no evidence will ever end, so
              -- the step reaches the lifecycle that says as much and the run
              -- stops for direction instead of polling for ever.
              | Just unverifiable <- stepUnverifiableDescendant snapshot step.missionPlanStepId ->
                  Just
                    <$> applyStepOutcome
                      controller
                      snapshot
                      gatheredEvidence
                      step.missionPlanStepId
                      MissionStepOutcomeUnknown
                      ( "its result landed, and its registered child "
                          <> unverifiable.unMissionSessionId
                          <> " cannot be shown to have ended"
                      )
              | stepHasUnsettledDescendants snapshot step.missionPlanStepId -> go rest
              | otherwise ->
                  Just
                    <$> applyStepOutcome controller snapshot gatheredEvidence step.missionPlanStepId MissionStepSucceeded detail
            MissionWorkFailedExternally failure ->
              Just
                <$> applyStepOutcome
                  controller
                  snapshot
                  gatheredEvidence
                  step.missionPlanStepId
                  (missionStepFailureLifecycle failure)
                  (missionStepFailureMessage failure)
            MissionWorkNeedsInput detail
              | record.missionStepRecordLifecycle == MissionStepNeedsInput -> go rest
              | otherwise ->
                  Just
                    <$> applyStepOutcome controller snapshot gatheredEvidence step.missionPlanStepId MissionStepNeedsInput detail
            MissionWorkConflicting detail -> do
              iteration <- applyMissionLifecycle controller snapshot MissionPaused detail
              pure (Just iteration)
            MissionWorkUnresolved detail
              | record.missionStepRecordLifecycle == MissionStepOutcomeUnknown -> go rest
              | otherwise ->
                  Just
                    <$> applyStepOutcome controller snapshot gatheredEvidence step.missionPlanStepId MissionStepOutcomeUnknown detail
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
                    <$> applyStepOutcome
                      controller
                      snapshot
                      gatheredEvidence
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
  recorded <-
    readMissionInvocations
      controller.missionControllerMission
      controller.missionControllerStore.missionStoreRepository
      controller.missionControllerInvocations
  case (planned, recorded) of
    (Left detail, _) -> pure (MissionControllerFailed detail)
    (_, Left detail) -> pure (MissionControllerFailed detail)
    (Right plannedVersion, Right states) -> do
      -- Counted off the durable record rather than off anything this snapshot
      -- happens to hold. The plan's size does not move between one dispatch of
      -- a step and the next, so an identity resting on it rests on the process
      -- id and the clock alone — and two dispatches inside one tick would mint
      -- one identity for two effects, which the journal then reads as a single
      -- one.
      invocation <- newMissionInvocationId step.missionPlanStepId (missionInvocationSequence states)
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
              -- A plan step is nobody's child.
              missionInvocationParent = Nothing,
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
            closing controller invocation (MissionInvocationStale stale) now $
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
          Left failure -> closing controller invocation (MissionInvocationRefused (missionStepFailureMessage failure)) now $ do
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
          -- An action answered as it was asked. There is no worker to
          -- register and nothing for a later pass to observe, so the result is
          -- written here or it is lost.
          Right acceptance
            | Just conclusion <- acceptance.missionAcceptedOutcome ->
                closing
                  controller
                  invocation
                  (MissionInvocationCompleted (missionConclusionDetail conclusion))
                  now
                  ( applyStepLifecycle
                      controller
                      snapshot
                      step.missionPlanStepId
                      (missionConclusionLifecycle conclusion)
                      (missionConclusionDetail conclusion)
                  )
          Right acceptance -> closing controller invocation (MissionInvocationDispatched acceptance.missionAcceptedWorker) now $ do
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

-- | Closes an invocation, and stops the run if that record cannot be written.
--
-- Discarding the failure is what let a step be written as @running@ beside a
-- launch the file still calls open. Nothing revisits a running step's
-- invocation — the recovery pass only reads @pending@ and @dispatching@ ones —
-- so the mission could go on to complete over a record that never closed, and
-- the journal would carry an effect nobody ever saw the end of into every
-- later run.
--
-- Stopping instead leaves the step exactly where the crash windows already
-- expect to find it, which is the point: the next run reads the same open
-- invocation the same way and closes it from the worker the launch created.
closing :: MissionController -> MissionInvocationId -> MissionInvocationOutcome -> UTCTime -> IO MissionIteration -> IO MissionIteration
closing controller invocation outcome at continue = do
  closed <- concludeMissionInvocation controller.missionControllerInvocations invocation outcome at
  case closed of
    Left detail -> pure (MissionControllerFailed detail)
    Right () -> continue

-- | Which step lifecycle a conclusion reached without a worker lands in.
--
-- The same three answers 'classifyMissionWork' reaches for a worker that
-- settled, spelled once so an action answered synchronously and one observed
-- later cannot disagree about what its result meant.
missionConclusionLifecycle :: MissionWorkerConclusion -> MissionStepLifecycle
missionConclusionLifecycle conclusion = case conclusion of
  MissionWorkerSucceeded _ -> MissionStepSucceeded
  MissionWorkerNeedsInput _ -> MissionStepNeedsInput
  MissionWorkerFailed failure -> missionStepFailureLifecycle failure

missionConclusionDetail :: MissionWorkerConclusion -> Text
missionConclusionDetail conclusion = case conclusion of
  MissionWorkerSucceeded detail -> detail
  MissionWorkerNeedsInput detail -> detail
  MissionWorkerFailed failure -> missionStepFailureMessage failure

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
        -- The override has to reach the invocation file, not just the step
        -- record. An open invocation for this step is what the recovery pass
        -- reads /before/ anything looks at step lifecycles, so a step handed
        -- back to @pending@ while its launch is still unresolved is taken
        -- straight back to @outcome_unknown@ on the very next iteration and
        -- the operator's direction is undone by the safeguard meant to wait
        -- for it. Requirement 7 names authenticated direction as one of the
        -- two things that may resolve such a record, and this is it.
        released <- releaseOpenInvocations controller step detail
        case released of
          Left message -> pure (MissionControllerFailed message)
          Right () -> do
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

-- | Closes every launch of one step that this store never saw the end of,
-- on the operator's word.
--
-- 'MissionInvocationAbandoned' rather than an unknown outcome, and the
-- difference is the authority: an unknown outcome is what a run writes when it
-- looked and could not tell, and this is a person who /can/ tell saying the
-- effect never happened and the step may be planned again. Nothing else in
-- this module may write it for a dispatch, which is why the override is the
-- only path here.
releaseOpenInvocations :: MissionController -> MissionStepId -> Text -> IO (Either Text ())
releaseOpenInvocations controller step detail = do
  recorded <-
    readMissionInvocations
      controller.missionControllerMission
      controller.missionControllerStore.missionStoreRepository
      controller.missionControllerInvocations
  case recorded of
    Left message -> pure (Left message)
    Right states -> do
      now <- getCurrentTime
      results <-
        mapM
          ( \state ->
              concludeMissionInvocation
                controller.missionControllerInvocations
                state.missionInvocationRecord.missionInvocationId
                (MissionInvocationAbandoned ("user override: " <> detail))
                now
          )
          [ state
          | state <- states,
            releasable state,
            state.missionInvocationRecord.missionInvocationStep == step
          ]
      pure (sequence_ results)
  where
    -- Open, or closed as an outcome nobody could establish. The second is the
    -- one the operator most needs to be able to reach: a run that closed a
    -- launch as unknown has said it cannot tell what happened, and if that
    -- record could not then be resolved the mission would be stuck on it for
    -- good. Appending the operator's answer over it is what the file is for —
    -- it keeps both lines, and the later one is the one that stands.
    releasable state = case state.missionInvocationOutcome of
      Nothing -> True
      Just (MissionInvocationUnknown _) -> True
      Just _ -> False

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
          missionInvocationParent = Nothing,
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
      case terminated of
        Left detail -> do
          -- The one conclusion whose failure is not propagated, because this
          -- record has a recovery path of its own: an open termination is what
          -- 'resolveOpenTermination' reads on the next run, and it reconciles
          -- it from the sessions themselves. Stopping here instead would leave
          -- the command file unconsumed as well, and a replayed termination is
          -- answered from this same record — so failing would trade a
          -- recoverable record for two.
          _ <- concludeMissionInvocation controller.missionControllerInvocations invocation (MissionInvocationRefused detail) concluded
          consumeMissionCommand command
          pure (MissionControllerFailed detail)
        -- Signalled, which is not the same as ended. @terminateWorker@ asks a
        -- worker to stop and returns; an ordinary one may be pending
        -- termination for a while yet, and an issue action's child is a
        -- queued command its host has still to act on. Closing the record
        -- here would put in the durable journal, as fact, that a subtree
        -- ended at the moment it was asked to.
        --
        -- So the record stays open whatever the driver reached, and
        -- 'resolveOpenTermination' — which the very next iteration runs, and
        -- which reads the sessions themselves — is what closes it: completed
        -- once they have all ended, waiting while any is still ending, and
        -- unknown if one cannot be shown to have ended at all.
        Right unreached -> do
          journalCommand
            controller
            command
            ( "signalled "
                <> Text.pack (show (length identities - length unreached))
                <> " of "
                <> Text.pack (show (length identities))
                <> " registered session(s)"
                <> ( if null unreached
                       then ""
                       else "; " <> Text.intercalate ", " (map (.unMissionSessionId) unreached) <> " could not be reached"
                   )
            )
          consumeMissionCommand command
          pure
            ( MissionAdvanced
                ( MissionCommandApplied
                    command.missionCommandId
                    ("signalled the subtree under " <> session.unMissionSessionId <> "; its end is not yet established")
                )
            )

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
    childInvocation = childInvocationId request.missionChildRequestParent request.missionChildRequestId
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

-- | The step a registered child's launch invents for it, named by the pair
-- that asked for it.
--
-- The pair, encoded so it can be taken apart again. Joining the two with a
-- separator does not do that: both halves are free-form words from the console
-- grammar, so parent @x-y@ asking for request @z@ and parent @x@ asking for
-- request @y-z@ would flatten to one name. Length-prefixing the parent says
-- exactly where it ends, which makes the encoding injective and still leaves
-- the name readable in the journal.
--
-- The request identity alone is not enough, and neither half of that is
-- theoretical: two live parents may each validly ask for request @r-1@. A step
-- named for the request alone would give both children one name, and the pass
-- that later asks what a session was doing — which finds the invocation by
-- step — would judge the second child against the first one's action and
-- target.
childStepId :: MissionSessionId -> Text -> MissionStepId
childStepId parent requestId =
  MissionStepId
    ( "child-"
        <> Text.pack (show (Text.length parent.unMissionSessionId))
        <> "-"
        <> parent.unMissionSessionId
        <> "-"
        <> requestId
    )

-- | The identity a child request is deduplicated by: its step's name, which
-- already encodes exactly the pair the deduplication is over.
childInvocationId :: MissionSessionId -> Text -> MissionInvocationId
childInvocationId parent requestId = MissionInvocationId (childStepId parent requestId).unMissionStepId

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
          { missionPlanStepId = childStepId request.missionChildRequestParent request.missionChildRequestId,
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
          -- Written before the launch because it is what recovery needs after
          -- one: the session node carrying this link is the very write a crash
          -- here loses, and a child put back without it is a session no
          -- termination reaches and no parent waits for.
          missionInvocationParent = Just request.missionChildRequestParent.unMissionSessionId,
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
        Left failure -> closing controller invocation (MissionInvocationRefused (missionStepFailureMessage failure)) concluded $ do
          journalCommand controller command ("child request failed: " <> missionStepFailureMessage failure)
          consumeMissionCommand command
          pure (MissionAdvanced (MissionCommandRefused command.missionCommandId (missionStepFailureMessage failure)))
        -- The same action that answers as it is asked, reached through a
        -- child request instead of a plan step. Registering the invented
        -- session a worker-owning launch produces would leave the parent
        -- waiting on a worker no pass can find, and throw away the answer
        -- that already exists.
        Right acceptance
          | Just conclusion <- acceptance.missionAcceptedOutcome ->
              closing controller invocation (MissionInvocationCompleted (missionConclusionDetail conclusion)) concluded $ do
                journalCommand controller command ("child request answered: " <> missionConclusionDetail conclusion)
                consumeMissionCommand command
                pure
                  ( MissionAdvanced
                      ( MissionCommandApplied
                          command.missionCommandId
                          ("child request answered: " <> missionConclusionDetail conclusion)
                      )
                  )
        Right acceptance -> closing controller invocation (MissionInvocationDispatched acceptance.missionAcceptedWorker) concluded $ do
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

-- | The same write, carrying what this pass learned about the session behind
-- the step.
--
-- Every reconciliation has just read the live worker, and a fresh launch's
-- provider session is only knowable from that read: the launch itself
-- registered the session before the provider had named its own. Recording it
-- in the write the reconciliation was making anyway is what lets a later turn
-- of the same step resume the conversation instead of starting another one,
-- and costs no extra transition to do it.
applyStepOutcome :: MissionController -> MissionSnapshot -> MissionStepEvidence -> MissionStepId -> MissionStepLifecycle -> Text -> IO MissionIteration
applyStepOutcome controller snapshot evidence step lifecycle detail = do
  written <- writeStep controller snapshot step lifecycle detail (learnedSession evidence)
  pure $ case written of
    Left message -> MissionControllerFailed message
    Right () -> MissionAdvanced (MissionStepReconciled step lifecycle detail)

-- | The session identity a piece of evidence can teach the snapshot.
--
-- No parent: this is a session the mission already registered, and its lineage
-- was settled when it was.
learnedSession :: MissionStepEvidence -> Maybe (MissionSessionId, Maybe MissionSessionId, Maybe Text)
learnedSession evidence = do
  reading <- evidence.missionEvidenceWorker
  pure (reading.missionWorkerSession, Nothing, reading.missionWorkerProviderSession)

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
  | any ((== identity) . (.missionSessionId)) nodes = map learn nodes
  | otherwise = nodes <> [node]
  where
    -- Idempotent, but not inert. A launch registers the session before the
    -- provider has named its own, and that name only appears in the worker's
    -- durable state some time later — so the node this mission holds would
    -- never learn it, and requirement 13's resume would brief a fresh session
    -- every time even though there was one to continue.
    --
    -- Filling in an absence only. A node that already names a provider session
    -- keeps it: a different name is a different session, and quietly
    -- rewriting it would change which conversation a resume continues.
    learn candidate
      | candidate.missionSessionId /= identity = candidate
      | candidate.missionSessionProviderSessionId /= Nothing = candidate
      | otherwise = candidate {missionSessionProviderSessionId = providerSession}
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
