{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Missions that start agents, and a worker cache that holds them (issue
-- #746).
--
-- The agent ceiling is counted from the worker cache, so every fixture here
-- produces its state through that cache: a mission's dispatch writes the
-- worker specification and state a real launch writes, with the invocation a
-- real launch writes into it, and ending an agent rewrites that state as
-- terminal. Nothing records "an agent is running" anywhere the production
-- count does not already read.
--
-- A fixture worker records no process identity. That is deliberate and
-- sufficient: a nonterminal worker with no recorded identity is one the
-- ceiling must count as live whatever a process snapshot says, and a
-- terminal one with none is over, so no example depends on what else is
-- running on the machine.
--
-- The probe half is the test binary run again, as "Spec.Support.MissionProbes"
-- runs it: some of what the ceiling promises is about two /processes/ — two
-- mission steps that both reach a dispatch, a holder that is killed with a
-- slot in hand — and a thread shares the process identifier that decides
-- whether a holder is gone.
module Spec.Support.AgentSlots
  ( slotRepository,
    otherCheckout,
    withSlotRoots,
    putAgentMission,
    putAgentMissionSteps,
    agentStep,
    agentWorker,
    writeAgentWorker,
    finishAgentWorker,
    missionAgentsNow,
    slotAdmission,
    agentDriver,
    agentDriverFor,
    stepAgentMission,
    stepAgentMissionIn,
    agentPass,

    -- * Probes
    admissionProbeVariable,
    runAdmissionProbe,
    AdmissionProbeMode (..),
    AdmissionProbe,
    startAdmissionProbe,
    startAdmissionProbeFor,
    openAdmissionGate,
    awaitAdmissionResult,
    killAdmissionProbe,
    stopAdmissionProbe,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (forM, forever, unless, void)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict, encode, encodeFile)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime, secondsToDiffTime)
import GHC.Generics (Generic)
import Kanban.Config (MissionAgentCeiling (..), MissionsConfig (..), defaultMissionsConfig)
import Kanban.Domain (Repository (..))
import Kanban.Mission
import Kanban.Solve (SolveOutcome (..))
import Kanban.Worker
  ( WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
    descriptorForSpec,
    readWorkerState,
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Process (runningWorkerState, workerFixtureSpec)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (getExecutablePath, getEnvironment)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory, (</>))
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (NoStream),
    createProcess,
    proc,
    terminateProcess,
    waitForProcess,
  )
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Stores and missions
-- ---------------------------------------------------------------------------

slotRepository :: Repository
slotRepository = Repository {repositoryRoot = "/tmp/slot-checkout", repositoryOwner = "coghex", repositoryName = "kanban"}

-- | The same repository, checked out somewhere else.
otherCheckout :: Repository
otherCheckout = slotRepository {repositoryRoot = "/tmp/another-slot-checkout"}

-- | A mission store and a worker cache under one temporary root, and nothing
-- else's.
withSlotRoots :: (MissionStore -> IO result) -> IO result
withSlotRoots action = withTemporaryCacheRoot $ \root ->
  withEnvironmentValue "XDG_STATE_HOME" (root </> "state") $
    withEnvironmentValue "XDG_CACHE_HOME" (root </> "cache") $ do
      opened <- openMissionStore slotRepository
      case opened of
        Left message -> fail ("could not open the mission store: " <> Text.unpack message)
        Right store -> action store

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 9 28) (secondsToDiffTime 60)

-- | The one step every agent mission here plans: a solve, which starts an
-- agent. It names no target, so nothing reads GitHub on its way to the slot.
agentStep :: MissionStepId
agentStep = MissionStepId "solve"

-- | A running mission whose next transition is its one solve.
putAgentMission :: MissionStore -> Text -> IO MissionId
putAgentMission store name = putAgentMissionSteps store name [(agentStep, [])]

-- | A running mission of solves, each pending, each depending on the steps
-- named beside it.
putAgentMissionSteps :: MissionStore -> Text -> [(MissionStepId, [MissionStepId])] -> IO MissionId
putAgentMissionSteps store name steps = do
  let mission = MissionId name
  created <- createMissionSpecification store (specification mission)
  case created of
    Left message -> fail ("could not write the specification: " <> Text.unpack message)
    Right _ -> pure ()
  written <- writeMissionSnapshot store (snapshot mission)
  case written of
    Left message -> fail ("could not write the snapshot: " <> Text.unpack message)
    Right () -> pure mission
  where
    specification mission =
      MissionSpecification
        { missionSpecificationId = mission,
          missionSpecificationRepository = store.missionStoreRepository,
          missionSpecificationRequest = "solve something",
          missionSpecificationSelector =
            MissionSelector
              { missionSelectorKind = "issues",
                missionSelectorQuery = Nothing,
                missionSelectorTargets = []
              },
          missionSpecificationPolicy =
            MissionDecisionPolicy
              { missionDecisionAutonomy = MissionConfirmOnAmbiguity,
                missionDecisionMaxReviewRounds = 5,
                missionDecisionStopOnFailure = True
              },
          missionSpecificationCreatedAt = fixedTime,
          missionSpecificationPlan =
            [ MissionPlanStep
                { missionPlanStepId = step,
                  missionPlanStepAction = "solve_issue",
                  missionPlanStepSummary = "solve it",
                  missionPlanStepTarget = Nothing,
                  missionPlanStepDependsOn = dependencies
                }
            | (step, dependencies) <- steps
            ]
        }
    snapshot mission =
      MissionSnapshot
        { missionSnapshotId = mission,
          missionSnapshotRepository = store.missionStoreRepository,
          missionSnapshotLifecycle = MissionRunning,
          missionSnapshotCurrentStep = Nothing,
          missionSnapshotNextSteps = [],
          missionSnapshotSteps =
            [ MissionStepRecord
                { missionStepRecordId = step,
                  missionStepRecordLifecycle = MissionStepPending,
                  missionStepRecordSessions = [],
                  missionStepRecordDetail = Nothing,
                  missionStepRecordUpdatedAt = fixedTime,
                  missionStepRecordCapacity = Nothing
                }
            | (step, _) <- steps
            ],
          missionSnapshotPause = MissionPause {missionPauseRequested = False, missionPauseReason = Nothing, missionPauseAt = Nothing},
          missionSnapshotAttention = Nothing,
          missionSnapshotPlannerSummary = Nothing,
          missionSnapshotRetries = [],
          missionSnapshotLastReconciliation = Nothing,
          missionSnapshotSessions = [],
          missionSnapshotArchive =
            MissionArchiveState
              { missionArchivePresentation = MissionPresentationActive,
                missionArchiveWorktrees = [],
                missionArchiveLastAccessedAt = Nothing
              },
          missionSnapshotUpdatedAt = fixedTime
        }

-- ---------------------------------------------------------------------------
-- The worker cache
-- ---------------------------------------------------------------------------

-- | Where a worker with this identifier lives, whatever it holds.
agentWorker :: Repository -> Text -> IO WorkerDescriptor
agentWorker repository identifier = descriptorForSpec (workerFixtureSpec repository (WorkerId identifier) 844)

-- | A worker as a launch leaves it: a specification naming @invocation@ (the
-- mark only a mission launch writes) and, when @status@ says so, a state.
writeAgentWorker :: Repository -> Text -> Maybe Text -> WorkerTask -> Maybe WorkerStatus -> IO WorkerDescriptor
writeAgentWorker repository identifier invocation task status = do
  let spec = (workerFixtureSpec repository (WorkerId identifier) 844) {workerInvocation = invocation, workerTask = task}
  descriptor <- descriptorForSpec spec
  createDirectoryIfMissing True (takeDirectory descriptor.workerDescriptorSpecPath)
  LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode spec)
  mapM_ (\value -> LazyByteString.writeFile descriptor.workerDescriptorStatePath (encode ((runningWorkerState (WorkerId identifier) 999999 Nothing) {workerStateStatus = value}))) status
  pure descriptor

-- | Ends one agent: its state becomes terminal, with nothing left running.
finishAgentWorker :: WorkerDescriptor -> IO ()
finishAgentWorker descriptor =
  LazyByteString.writeFile
    descriptor.workerDescriptorStatePath
    (encode ((runningWorkerState descriptor.workerDescriptorSpec.workerId 999999 Nothing) {workerStateStatus = WorkerTerminal SolveCompleted}))

-- | How many mission agents the production count says are live.
missionAgentsNow :: IO Int
missionAgentsNow = do
  observed <- observeMissionAgents slotRepository
  case observed of
    Left message -> fail ("the agents could not be counted: " <> Text.unpack message)
    Right occupants -> pure (missionAgentsLive occupants)

-- ---------------------------------------------------------------------------
-- A driver whose one effect is a worker record
-- ---------------------------------------------------------------------------

-- | Production admission over the real worker cache, waiting briefly.
slotAdmission :: MissionAdmissionSeams
slotAdmission = (liveMissionAdmissionSeams slotRepository) {missionAdmissionPollMicros = 20 * 1000, missionAdmissionPolls = 250}

-- | A driver that claims real slots and launches by writing a worker.
--
-- The worker it writes is named for the mission and the invocation, so each
-- launch is a worker of its own and a second launch of one invocation would
-- be the same worker rather than another.
agentDriver :: Int -> MissionStore -> MissionId -> IO MissionDriver
agentDriver = agentDriverFor slotRepository

-- | 'agentDriver' for a checkout of the repository spelled and rooted as
-- @repository@ says.
agentDriverFor :: Repository -> Int -> MissionStore -> MissionId -> IO MissionDriver
agentDriverFor repository agentCeiling store mission =
  pure
    MissionDriver
      { missionDriverInventory = pure (Right (MissionInventory [] [])),
        missionDriverObserveTarget = \_ -> pure (Left "no target in this fixture"),
        missionDriverStepEvidence = \_ record -> do
          readings <- forM record.missionStepRecordSessions reading
          pure
            ( Right
                MissionStepEvidence
                  { missionEvidenceStep = record.missionStepRecordId,
                    missionEvidenceLifecycle = record.missionStepRecordLifecycle,
                    missionEvidenceInvocation = Nothing,
                    missionEvidenceWorker = listToMaybe (concat readings),
                    missionEvidenceSatisfied = Nothing,
                    missionEvidenceDeparted = Nothing,
                    missionEvidenceForeign = Nothing
                  }
            ),
        missionDriverObserveSession = \session _ -> do
          descriptor <- agentWorker repository session.unMissionSessionId
          state <- readWorkerState descriptor
          now <- getCurrentTime
          pure $ case state of
            Right recorded
              | WorkerTerminal _ <- recorded.workerStateStatus ->
                  Right (Just (MissionTerminalObservation now (MissionObservedExit 0) (Just "it finished")))
            _ -> Right Nothing,
        missionDriverAdoptInvocation = \invocation -> do
          descriptor <- agentWorker repository (workerFor invocation)
          present <- doesFileExist descriptor.workerDescriptorSpecPath
          pure (Right (if present then Just (MissionSessionId (workerFor invocation)) else Nothing)),
        missionDriverDispatch = \request -> do
          let identifier = workerFor request.missionDispatchInvocation
          _ <- writeAgentWorker repository identifier (Just request.missionDispatchInvocation.unMissionInvocationId) solveTask (Just WorkerRunning)
          pure
            ( Right
                MissionDispatchAccepted
                  { missionAcceptedSession = MissionSessionId identifier,
                    missionAcceptedProviderSession = Nothing,
                    missionAcceptedWorker = identifier,
                    missionAcceptedDetail = "launched",
                    missionAcceptedOutcome = Nothing
                  }
            ),
        missionDriverClaimSlot = \_ invocation -> do
          decision <- claimMissionAgentSlot admission store agentCeiling mission invocation.unMissionInvocationId
          pure $ case decision of
            MissionAgentSlotGranted -> MissionSlotClaimed
            MissionAgentSlotHeld reason -> MissionSlotWaiting reason
            MissionAgentSlotUndecided detail -> MissionSlotUndecided detail,
        missionDriverSettleSlot = \invocation -> void (settleMissionAgentSlot admission store invocation.unMissionInvocationId),
        missionDriverTerminate = \_ -> pure (Right []),
        missionDriverSealSession = \_ -> pure []
      }
  where
    admission = (liveMissionAdmissionSeams repository) {missionAdmissionPollMicros = 20 * 1000, missionAdmissionPolls = 250}
    solveTask = (workerFixtureSpec repository (WorkerId "any") 844).workerTask
    workerFor invocation = "agent-" <> mission.unMissionId <> "-" <> Text.takeEnd 12 (Text.filter (/= '-') invocation.unMissionInvocationId)
    reading session = do
      descriptor <- agentWorker repository session.unMissionSessionId
      state <- readWorkerState descriptor
      pure $ case state of
        Left _ -> []
        Right recorded ->
          [ MissionWorkerReading
              { missionWorkerSession = session,
                missionWorkerLive = case recorded.workerStateStatus of
                  WorkerTerminal _ -> False
                  _ -> True,
                missionWorkerCompatible = True,
                missionWorkerTerminal = case recorded.workerStateStatus of
                  WorkerTerminal _ -> Just (MissionWorkerSucceeded "it finished")
                  _ -> Nothing,
                missionWorkerProviderSession = Nothing
              }
          ]

-- | One scheduled step of one mission under @agentCeiling@.
stepAgentMission :: Int -> MissionStore -> MissionId -> IO MissionIteration
stepAgentMission = stepAgentMissionIn slotRepository

-- | 'stepAgentMission' from a checkout of @repository@.
stepAgentMissionIn :: Repository -> Int -> MissionStore -> MissionId -> IO MissionIteration
stepAgentMissionIn repository agentCeiling store mission = do
  stepped <- runMissionStepWith store repository mission (agentDriverFor repository agentCeiling)
  case stepped of
    Left refusal -> fail ("the mission refused to start: " <> Text.unpack (missionStartRefusalMessage refusal))
    Right report -> pure report.missionStepIteration

-- | One real scheduler pass whose children are these steps, taken in this
-- process one after another in the order the pass hands them over.
--
-- Everything but the spawn is production: which missions are runnable, the
-- rotation order, the entrants, the withdrawals, and the count the report
-- carries.
agentPass :: Int -> MissionStore -> IO MissionPassReport
agentPass agentCeiling store =
  runMissionSchedulerPass
    MissionSchedulerSeams
      { missionSchedulerNow = getCurrentTime,
        missionSchedulerLeaseHeld = missionLeaseHeld store,
        missionSchedulerAdvance = \admitted settled ->
          forM admitted $ \mission -> do
            stepped <- runMissionStepWith store slotRepository mission (agentDriver agentCeiling)
            settled mission
            pure (mission, Right (missionChildResultOf "in-process" "coghex/kanban" mission stepped)),
        missionSchedulerExpect = expectMissionAgents slotAdmission store,
        missionSchedulerWithdraw = \mission -> void (withdrawExpectedMission slotAdmission store mission),
        missionSchedulerAgents = fmap missionAgentsLive <$> observeMissionAgents slotRepository,
        missionSchedulerNotify = \_ -> fail "no notification in this fixture",
        missionSchedulerSeal = \_ -> pure []
      }
    defaultMissionsConfig {missionsAgentCeiling = MissionAgentCeiling agentCeiling}
    store
    slotRepository

-- ---------------------------------------------------------------------------
-- Probes
-- ---------------------------------------------------------------------------

admissionProbeVariable :: String
admissionProbeVariable = "KANBAN_ADMISSION_PROBE"

-- | What one probe process does once its gate opens.
data AdmissionProbeMode
  = -- | One scheduled step of its mission, through 'agentDriver'.
    ProbeStep
  | -- | Claim a slot and hold it, launching nothing, until killed.
    ProbeClaimAndHold
  | -- | Claim a slot, launch its worker, and die before giving the slot back.
    ProbeLaunchAndHold
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ProbePlan = ProbePlan
  { planMode :: AdmissionProbeMode,
    -- | The checkout this probe is: its root and its spelling of the
    -- repository.
    planRoot :: FilePath,
    planOwner :: Text,
    planName :: Text,
    planMission :: Text,
    planCeiling :: Int,
    planStarted :: FilePath,
    planGate :: FilePath,
    planResult :: FilePath
  }
  deriving stock (Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data AdmissionProbe = AdmissionProbe
  { probeHandle :: ProcessHandle,
    probePlan :: ProbePlan
  }

-- | The probe half, reached from @main@ when 'admissionProbeVariable' names a
-- plan. The store and the cache are the environment it inherited.
runAdmissionProbe :: FilePath -> IO ()
runAdmissionProbe planPath = do
  decoded <- eitherDecodeFileStrict planPath :: IO (Either String ProbePlan)
  plan <- either (\message -> fail ("unreadable probe plan: " <> message)) pure decoded
  let repository = Repository {repositoryRoot = plan.planRoot, repositoryOwner = plan.planOwner, repositoryName = plan.planName}
  opened <- openMissionStore repository
  store <- either (\message -> fail (Text.unpack message)) pure opened
  writeFile plan.planStarted "started"
  awaitFile plan.planGate
  let mission = MissionId plan.planMission
  case plan.planMode of
    ProbeStep -> do
      iteration <- stepAgentMissionIn repository plan.planCeiling store mission
      writeFile plan.planResult $ case iteration of
        MissionAdvanced (MissionStepDispatched {}) -> "dispatched"
        MissionHeldForSlot reason -> "held: " <> Text.unpack reason
        other -> "other: " <> show other
      exitWith ExitSuccess
    ProbeClaimAndHold -> do
      decision <- claimMissionAgentSlot slotAdmission store plan.planCeiling mission ("probe-" <> plan.planMission)
      writeFile plan.planResult (show decision)
      forever (threadDelay 1000000)
    ProbeLaunchAndHold -> do
      let invocation = "probe-" <> plan.planMission
      decision <- claimMissionAgentSlot slotAdmission store plan.planCeiling mission invocation
      unless (decision == MissionAgentSlotGranted) $ do
        writeFile plan.planResult (show decision)
        exitWith (ExitFailure 3)
      _ <- writeAgentWorker slotRepository ("agent-" <> invocation) (Just invocation) (workerFixtureSpec slotRepository (WorkerId "any") 844).workerTask (Just WorkerRunning)
      writeFile plan.planResult (show decision)
      forever (threadDelay 1000000)

-- | Starts one probe and waits until it is at its gate.
startAdmissionProbe :: FilePath -> AdmissionProbeMode -> Text -> Int -> IO AdmissionProbe
startAdmissionProbe = startAdmissionProbeFor slotRepository

-- | 'startAdmissionProbe' for a probe that is a checkout of @repository@.
startAdmissionProbeFor :: Repository -> FilePath -> AdmissionProbeMode -> Text -> Int -> IO AdmissionProbe
startAdmissionProbeFor repository directory mode mission agentCeiling = do
  let base = directory </> Text.unpack mission
      plan =
        ProbePlan
          { planMode = mode,
            planRoot = repository.repositoryRoot,
            planOwner = repository.repositoryOwner,
            planName = repository.repositoryName,
            planMission = mission,
            planCeiling = agentCeiling,
            planStarted = base <> ".started",
            planGate = directory </> "gate",
            planResult = base <> ".result"
          }
      planPath = base <> ".plan.json"
  encodeFile planPath plan
  executable <- getExecutablePath
  environment <- getEnvironment
  (_, _, _, handle) <-
    createProcess
      (proc executable [])
        { env = Just ((admissionProbeVariable, planPath) : filter ((/= admissionProbeVariable) . fst) environment),
          std_in = NoStream,
          std_out = NoStream
        }
  awaitFile plan.planStarted
  pure (AdmissionProbe handle plan)

-- | Opens the one gate every probe in @directory@ waits at.
openAdmissionGate :: FilePath -> IO ()
openAdmissionGate directory = writeFile (directory </> "gate") "open"

awaitAdmissionResult :: AdmissionProbe -> IO String
awaitAdmissionResult probe = do
  awaitFile probe.probePlan.planResult
  -- Written in one call; read again until it is not empty, so a read that
  -- lands between the create and the write is not taken for an answer.
  let settledRead remaining = do
        contents <- readFile probe.probePlan.planResult
        if null contents && remaining > (0 :: Int)
          then threadDelay 20000 >> settledRead (remaining - 1)
          else pure contents
  settledRead 250

-- | Ends a probe with a signal and reaps it, so its process identifier names
-- nothing afterwards.
killAdmissionProbe :: AdmissionProbe -> IO ()
killAdmissionProbe probe = do
  terminateProcess probe.probeHandle
  void (timeout 10000000 (waitForProcess probe.probeHandle))

-- | Waits for a probe that exits on its own.
stopAdmissionProbe :: AdmissionProbe -> IO ExitCode
stopAdmissionProbe probe = do
  finished <- timeout 60000000 (waitForProcess probe.probeHandle)
  case finished of
    Just code -> pure code
    Nothing -> do
      killAdmissionProbe probe
      fail "an admission probe did not finish"

awaitFile :: FilePath -> IO ()
awaitFile path = go (3000 :: Int)
  where
    go remaining = do
      present <- try @IOException (doesFileExist path)
      case present of
        Right True -> pure ()
        _
          | remaining <= 0 -> fail ("timed out waiting for " <> path)
          | otherwise -> threadDelay 20000 >> go (remaining - 1)
