{-# LANGUAGE OverloadedStrings #-}

-- | The foreground mission runner: what it advances, what it refuses, and what
-- it does with the durable state a crash leaves behind (issue #595).
--
-- Every example here runs against a real mission store under a temporary
-- @$XDG_STATE_HOME@, with the controller's one contact with the outside world
-- — its 'MissionDriver' — staged. That split is the point of the module under
-- test: nothing below starts a process, reads GitHub, or draws a frame, and
-- everything below still exercises the code a real run executes.
--
-- The crash examples are worth reading first, because they are staged the way
-- "Spec.Mission" stages an interrupted write: not by interrupting anything,
-- but by /constructing the durable state a crash would have left/ and then
-- asking a fresh controller what it does with it. There are three such states
-- and they are deliberately different files:
--
--   * nothing journaled and a pending step — the crash happened before the
--     invocation record;
--   * an invocation opened and never closed, with no worker — the crash
--     happened after the record was flushed and before the launch;
--   * an invocation opened and closed, with a worker that settled — the crash
--     happened after the launch and before the result was recorded.
--
-- What separates the second from the third is exactly what requirement 7 turns
-- on: the second may have had an effect nobody observed, and must never be
-- retried on the strength of the record alone.
module Spec.Mission.Runner (spec) where

import qualified Data.ByteString.Char8 as ByteString
import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_, join)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate, isInfixOf, nub)
import Data.Text (Text)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Time (UTCTime (..), addUTCTime, defaultTimeLocale, formatTime, fromGregorian, secondsToDiffTime)
import Kanban.Action
  ( ActionAttribution (..),
    ActionHandle (..),
    ActionOutcome (..),
    ActionRefusal (..),
    ActionTargetKind (..),
    ResolvedTarget (..),
    WorkflowActionKind (..),
    ActionTarget (..),
    ActionTargetRef (..),
    CatalogHistory (..),
    TargetCatalog (..),
    actionHandleKind,
    observableActionHandle,
    resolveActionTarget,
    WorkflowActionKind (SolveIssue),
    settledWorkerFailure,
    targetPreconditionHolds,
    targetPreconditionMessage,
  )
import Kanban.CLI (LaunchMode (..), Options (..), launchMode)
import Data.Aeson (eitherDecode, encode)
import Kanban.Config
  ( RawConfig (..),
    ResolvedConfig (..),
    TimeoutsConfig (..),
    decodeConfigText,
    defaultRawConfig,
    defaultTimeoutsConfig,
    defaultWorkerDeadlineSeconds,
    maximumWorkerDeadlineSeconds,
    resolveGlobalConfig,
  )
import Kanban.Domain (Issue (..), IssueState (..), NativeSubIssues (..), Repository (..), defaultWorkflowConfig)
import Kanban.Mission
import Kanban.Ping (resolvePingBrand)
import Kanban.Process (ProcessIdentity (..))
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Worker
  ( IssueActionWorkerTask (..),
    IssueHostWorkerTask (..),
    WorkerDeadline (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerParent (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
    descriptorForSpec,
    workerDirectory,
    writePrivateJson,
    writeState,
    preconditionStillHolds,
    workerDeadlineReason,
    workerPreconditionRefusal,
    workerStaleTargetReason,
    workerUnverifiedTargetReason,
  )
import Spec.Support.Board (withFakeGh)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Json (emptyAssigneesJson, emptyLabelsJson, emptySubIssuesJson, githubIndependentPage, issueNodeJson)
import Spec.Support.Fixtures (testOptions, testResolvedConfig)
import Kanban.Preflight (IssueOrigin (..))
import Kanban.Review (ReviewStage (..))
import Kanban.Solve (SolverBrand (..), SolveOutcome (..))
import Spec.Support.Process (deadlineFixtureSpec, runningWorkerState, workerFixtureSpec)
import System.Directory (doesFileExist, listDirectory)
import Kanban.Paths (createPrivateDirectory)
import System.Directory (XdgDirectory (XdgCache))
import System.Posix.Files (setFileMode)
import System.FilePath ((</>))
import qualified Data.Text.IO as TextIO
import System.IO (BufferMode (LineBuffering), Handle, IOMode (ReadMode), hClose, hIsTerminalDevice, hSetBuffering, withFile)
import System.Process (createPipe)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "the foreground mission runner" $ do
  launchModeSpec
  selectionSpec
  startupSpec
  leaseSpec
  reconciliationSpec
  crashRecoverySpec
  preconditionSpec
  continuationSpec
  commandSpec
  childRequestSpec
  consoleSpec
  preconditionBoundarySpec
  deadlineSpec
  workerPreconditionSpec
  failureVocabularySpec
  openEffectRecoverySpec
  directionSpec
  registryJudgementSpec

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

boardRepository :: Repository
boardRepository = Repository {repositoryRoot = "/tmp/board", repositoryOwner = "coghex", repositoryName = "kanban"}

theMission :: MissionId
theMission = MissionId "mission-0595"

theStep :: MissionStepId
theStep = MissionStepId "solve-844"

theTarget :: MissionTarget
theTarget = MissionTarget {missionTargetKind = MissionTargetIssue, missionTargetNumber = 844, missionTargetTitle = Just "the issue"}

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 9 4) (secondsToDiffTime 120)

theSpecification :: MissionSpecification
theSpecification =
  MissionSpecification
    { missionSpecificationId = theMission,
      missionSpecificationRepository = MissionRepository "coghex" "kanban",
      missionSpecificationRequest = "take #844 to a reviewed pull request",
      missionSpecificationSelector =
        MissionSelector
          { missionSelectorKind = "issues",
            missionSelectorQuery = Nothing,
            missionSelectorTargets = [theTarget]
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
            { missionPlanStepId = theStep,
              missionPlanStepAction = "solve_issue",
              missionPlanStepSummary = "take #844 to a pull request",
              missionPlanStepTarget = Just theTarget,
              missionPlanStepDependsOn = []
            }
        ]
    }

snapshotWith :: MissionLifecycle -> [MissionStepRecord] -> [MissionSessionNode] -> MissionSnapshot
snapshotWith lifecycle steps sessions =
  MissionSnapshot
    { missionSnapshotId = theMission,
      missionSnapshotRepository = MissionRepository "coghex" "kanban",
      missionSnapshotLifecycle = lifecycle,
      missionSnapshotCurrentStep = Nothing,
      missionSnapshotNextSteps = [],
      missionSnapshotSteps = steps,
      missionSnapshotPause = MissionPause {missionPauseRequested = False, missionPauseReason = Nothing, missionPauseAt = Nothing},
      missionSnapshotAttention = Nothing,
      missionSnapshotPlannerSummary = Just "one issue, one solve",
      missionSnapshotRetries = [],
      missionSnapshotLastReconciliation = Nothing,
      missionSnapshotSessions = sessions,
      missionSnapshotArchive =
        MissionArchiveState
          { missionArchivePresentation = MissionPresentationActive,
            missionArchiveWorktrees = [],
            missionArchiveLastAccessedAt = Nothing
          },
      missionSnapshotUpdatedAt = fixedTime
    }

stepRecord :: MissionStepLifecycle -> [MissionSessionId] -> MissionStepRecord
stepRecord lifecycle sessions =
  MissionStepRecord
    { missionStepRecordId = theStep,
      missionStepRecordLifecycle = lifecycle,
      missionStepRecordSessions = sessions,
      missionStepRecordDetail = Nothing,
      missionStepRecordUpdatedAt = fixedTime
    }

sessionNode :: Text -> Maybe MissionSessionId -> Maybe MissionTerminalObservation -> MissionSessionNode
sessionNode identity parent observation =
  MissionSessionNode
    { missionSessionId = MissionSessionId identity,
      missionSessionMission = theMission,
      missionSessionParent = parent,
      missionSessionStep = Just theStep,
      missionSessionProvider = "claude",
      missionSessionProviderSessionId = Just ("provider-" <> identity),
      missionSessionOwnership = MissionProcessOwnership {missionProcessIdentity = Nothing, missionProcessGroup = Nothing},
      missionSessionLog = Nothing,
      missionSessionObservation = observation
    }

settledObservation :: Maybe MissionTerminalObservation
settledObservation =
  Just
    MissionTerminalObservation
      { missionObservationAt = fixedTime,
        missionObservationOutcome = MissionObservedExit 0,
        missionObservationDetail = Nothing
      }

-- | A session recorded as owning a process and never observed to end, which is
-- 'MissionSessionLive' to 'missionSessionDisposition'.
--
-- The recorded ownership is what makes it live rather than merely
-- unaccounted-for, and the two are not interchangeable: a live child is work in
-- progress its parent waits for, and one carrying an /unknown/ observation is a
-- child the evidence pass asked about and could not answer for. See
-- 'unverifiableChild'.
liveChild :: Text -> MissionSessionId -> MissionSessionNode
liveChild identity parent =
  (sessionNode identity (Just parent) Nothing)
    { missionSessionOwnership =
        MissionProcessOwnership
          { missionProcessIdentity = Just (childProcessIdentity identity),
            missionProcessGroup = Nothing
          }
    }

-- | The session the staged driver produces for a child request, derived the
-- way 'acceptedDispatch' derives it: from the step the launch invents.
childSessionFor :: MissionSessionId -> Text -> MissionSessionId
childSessionFor parent requestId =
  MissionSessionId ((childStepId parent requestId).unMissionStepId <> "-0001")

childProcessIdentity :: Text -> ProcessIdentity
childProcessIdentity identity =
  ProcessIdentity
    { processIdentityPid = 4242,
      processIdentityParentPid = 1,
      processIdentityGroupPid = 4242,
      processIdentityStartedAt = "0",
      processIdentityCommand = identity
    }

-- | A child the evidence pass looked at and could not establish the end of.
unverifiableChild :: Text -> MissionSessionId -> MissionSessionNode
unverifiableChild identity parent =
  (sessionNode identity (Just parent) Nothing)
    { missionSessionObservation =
        Just
          MissionTerminalObservation
            { missionObservationAt = fixedTime,
              missionObservationOutcome = MissionObservedUnknown,
              missionObservationDetail = Just "its worker record has been collected"
            }
    }

issueVersion :: [Text] -> MissionTargetVersion
issueVersion labels =
  MissionTargetVersion
    { missionVersionKind = MissionTargetIssue,
      missionVersionNumber = 844,
      missionVersionUpdatedAt = fixedTime,
      missionVersionHead = Nothing,
      missionVersionLabels = labels,
      missionVersionState = "open"
    }

-- | Everything the fake driver was asked, and everything it will answer.
data Stage = Stage
  { stageTargets :: IORef [Either Text MissionTargetVersion],
    stageEvidence :: IORef (MissionStepEvidence -> MissionStepEvidence),
    -- | A function of the request, so a child request produces a session of
    -- its own rather than the one its parent already registered.
    stageDispatchResult :: IORef (MissionDispatchRequest -> Either MissionStepFailure MissionDispatchAccepted),
    stageDispatches :: IORef [MissionDispatchRequest],
    -- | Run inside the driver's dispatch, which is the one moment between a
    -- launch's opening record and its closing one.
    stageOnDispatch :: IORef (IO ()),
    stageTerminated :: IORef [[MissionSessionId]],
    -- | The sessions a termination will report it could not signal.
    stageUnreached :: IORef [MissionSessionId],
    -- | The sessions the driver will report an observation for.
    stageSessions :: IORef [MissionSessionId],
    -- | The observation it reports for them. Settled by default; an example
    -- that cares about an unverifiable reading chooses its own.
    stageObservation :: IORef MissionTerminalObservation,
    -- | The worker each invocation will be found to have launched.
    stageAdoptions :: IORef [(MissionInvocationId, MissionSessionId)]
  }

newStage :: IO Stage
newStage =
  Stage
    <$> newIORef (repeat (Right (issueVersion ["reviewed:approve"])))
    <*> newIORef id
    <*> newIORef (Right . acceptedDispatch)
    <*> newIORef []
    <*> newIORef (pure ())
    <*> newIORef []
    <*> newIORef []
    <*> newIORef []
    <*> newIORef endedObservation
    <*> newIORef []

endedObservation :: MissionTerminalObservation
endedObservation =
  MissionTerminalObservation
    { missionObservationAt = fixedTime,
      missionObservationOutcome = MissionObservedExit 0,
      missionObservationDetail = Just "it completed"
    }

acceptedDispatch :: MissionDispatchRequest -> MissionDispatchAccepted
acceptedDispatch request =
  MissionDispatchAccepted
    { missionAcceptedSession = MissionSessionId session,
      missionAcceptedProviderSession = Just "provider-1",
      missionAcceptedWorker = session,
      missionAcceptedDetail = "dispatched",
      missionAcceptedOutcome = Nothing
    }
  where
    session = request.missionDispatchStep.missionPlanStepId.unMissionStepId <> "-0001"

stagedDriver :: Stage -> MissionStore -> MissionId -> IO MissionDriver
stagedDriver stage _ _ =
  pure
    MissionDriver
      { missionDriverInventory = pure (Right (MissionInventory [theMission] ["solve-844-0001"])),
        missionDriverObserveTarget = \_ ->
          atomicModifyIORef' stage.stageTargets $ \answers -> case answers of
            (answer : rest) -> (rest, answer)
            [] -> ([], Right (issueVersion ["reviewed:approve"])),
        missionDriverStepEvidence = \_ record -> do
          decorate <- readIORef stage.stageEvidence
          pure
            ( Right
                ( decorate
                    MissionStepEvidence
                      { missionEvidenceStep = record.missionStepRecordId,
                        missionEvidenceLifecycle = record.missionStepRecordLifecycle,
                        missionEvidenceInvocation = Nothing,
                        missionEvidenceWorker = Nothing,
                        missionEvidenceSatisfied = Nothing,
                        missionEvidenceDeparted = Nothing,
                        missionEvidenceForeign = Nothing
                      }
                )
            ),
        missionDriverObserveSession = \session _ -> do
          settled <- readIORef stage.stageSessions
          observation <- readIORef stage.stageObservation
          pure (Right (if session `elem` settled then Just observation else Nothing)),
        missionDriverAdoptInvocation = \invocation -> do
          launched <- readIORef stage.stageAdoptions
          pure (Right (lookup invocation launched)),
        missionDriverDispatch = \request -> do
          atomicModifyIORef' stage.stageDispatches (\seen -> (seen <> [request], ()))
          join (readIORef stage.stageOnDispatch)
          ($ request) <$> readIORef stage.stageDispatchResult,
        missionDriverTerminate = \sessions -> do
          atomicModifyIORef' stage.stageTerminated (\seen -> (seen <> [sessions], ()))
          unreached <- readIORef stage.stageUnreached
          pure (Right unreached)
      }

-- | A store, a specification, and a snapshot, under a state root nothing else
-- can see.
withMission :: MissionSnapshot -> (MissionStore -> Stage -> IO result) -> IO result
withMission snapshot action = withTemporaryCacheRoot $ \root ->
  withEnvironmentValue "XDG_STATE_HOME" root $ do
    opened <- openMissionStore boardRepository
    case opened of
      Left message -> fail ("could not open the mission store: " <> Text.unpack message)
      Right store -> do
        created <- createMissionSpecification store theSpecification
        created `shouldBe` Right MissionCreated
        written <- writeMissionSnapshot store snapshot
        written `shouldBe` Right ()
        stage <- newStage
        action store stage

-- | Iterations until one satisfies the predicate, or the bound is reached.
--
-- The session pass records one observation per iteration by design, so a
-- termination that has to read three of them takes three passes before the
-- record it is waiting on can be closed. Bounded so a test that never reaches
-- its answer fails rather than spins.
iterateUntil :: MissionController -> (MissionIteration -> Bool) -> IO MissionIteration
iterateUntil controller reached = go (12 :: Int) []
  where
    go 0 seen = fail ("no iteration satisfied the predicate: " <> show (reverse seen))
    go remaining seen = do
      iteration <- missionControllerIteration controller
      if reached iteration then pure iteration else go (remaining - 1) (iteration : seen)

-- | One controller iteration against a staged driver.
oneIteration :: MissionStore -> Stage -> IO MissionIteration
oneIteration store stage = do
  started <- startMissionController store boardRepository theMission (stagedDriver stage)
  case started of
    Left refusal -> fail ("the controller refused to start: " <> Text.unpack (missionStartRefusalMessage refusal))
    Right controller -> do
      iteration <- missionControllerIteration controller
      stopMissionController controller
      pure iteration

currentSnapshot :: MissionStore -> IO MissionSnapshot
currentSnapshot store = do
  readBack <- readMissionSnapshot store theMission
  case readBack of
    MissionPresent snapshot -> pure snapshot
    other -> fail ("the snapshot did not read back: " <> show (() <$ other))

currentInvocations :: MissionStore -> IO [MissionInvocationState]
currentInvocations store = case missionInvocationPath store.missionStoreDirectory theMission of
  Left message -> fail (Text.unpack message)
  Right path -> do
    recorded <- readMissionInvocations theMission store.missionStoreRepository path
    either (fail . Text.unpack) pure recorded

stepLifecycle :: MissionSnapshot -> Maybe MissionStepLifecycle
stepLifecycle snapshot = (.missionStepRecordLifecycle) <$> missionStepRecordFor theStep snapshot

-- | The parent every registered child in these examples is asked for by.
theParent :: MissionSessionId
theParent = MissionSessionId "solve-844-0001"

-- | The invocation identity 'launchChild' mints for this fixture's parent,
-- taken from the controller's own minting so the two cannot drift apart.
childInvocationFor :: Text -> MissionInvocationId
childInvocationFor = childInvocationId theParent

-- | The durable state a crash around a registered child's launch leaves: the
-- opening record, its step invented from the request, and the lineage the
-- session write was going to carry.
openChildInvocation :: MissionStore -> Text -> IO ()
openChildInvocation store requestId = writeInvocation store $
  MissionInvocation
    { missionInvocationId = childInvocationFor requestId,
      missionInvocationMission = theMission,
      missionInvocationRepository = MissionRepository "coghex" "kanban",
      missionInvocationStep = childStepId theParent requestId,
      missionInvocationAction = "review_pull_request",
      missionInvocationTarget = Nothing,
      missionInvocationVersion = Nothing,
      missionInvocationEffect = MissionEffectDispatch "review_pull_request",
      missionInvocationParent = Just theParent.unMissionSessionId,
      missionInvocationAt = fixedTime
    }

-- | The same for a subtree termination.
openTerminationInvocation :: MissionStore -> Text -> IO ()
openTerminationInvocation store commandId = writeInvocation store $
  MissionInvocation
    { missionInvocationId = MissionInvocationId ("terminate-" <> commandId),
      missionInvocationMission = theMission,
      missionInvocationRepository = MissionRepository "coghex" "kanban",
      missionInvocationStep = MissionStepId "-",
      missionInvocationAction = "terminate_subtree",
      missionInvocationTarget = Nothing,
      missionInvocationVersion = Nothing,
      missionInvocationEffect = MissionEffectTerminateSubtree theParent.unMissionSessionId,
      missionInvocationParent = Nothing,
      missionInvocationAt = fixedTime
    }

writeInvocation :: MissionStore -> MissionInvocation -> IO ()
writeInvocation store record = case missionInvocationPath store.missionStoreDirectory theMission of
  Left message -> fail (Text.unpack message)
  Right path -> do
    written <- recordMissionInvocation path record
    written `shouldBe` Right ()

concludeInvocation :: MissionStore -> MissionInvocationId -> MissionInvocationOutcome -> IO ()
concludeInvocation store identity outcome = case missionInvocationPath store.missionStoreDirectory theMission of
  Left message -> fail (Text.unpack message)
  Right path -> do
    concluded <- concludeMissionInvocation path identity outcome fixedTime
    concluded `shouldBe` Right ()

outcomeTags :: MissionStore -> IO [Maybe Text]
outcomeTags store = map (fmap missionInvocationOutcomeTag . (.missionInvocationOutcome)) <$> currentInvocations store

-- | A snapshot whose only registered session is the live parent, with the
-- step it belongs to still running.
withRegisteredParent :: (MissionStore -> Stage -> IO result) -> IO result
withRegisteredParent =
  withMission
    ( snapshotWith
        MissionRunning
        [stepRecord MissionStepRunning [theParent]]
        [sessionNode "solve-844-0001" Nothing Nothing]
    )

-- ---------------------------------------------------------------------------
-- Launch mode
-- ---------------------------------------------------------------------------

launchModeSpec :: Spec
launchModeSpec = describe "the launch mode it is selected by" $ do
  it "sits immediately before the dashboard and yields to every explicit mode" $ do
    launchMode testOptions {optionMission = Just "mission-0595"} `shouldBe` MissionMode "mission-0595"
    launchMode testOptions {optionMission = Just "m", optionWorkerSpec = Just "/tmp/spec.json"}
      `shouldBe` WorkerMode "/tmp/spec.json"
    launchMode testOptions {optionMission = Just "m", optionReviewTools = Just "/tmp/endpoint"}
      `shouldBe` ReviewToolServerMode "/tmp/endpoint"
    launchMode testOptions {optionMission = Just "m", optionGlyphTest = True} `shouldBe` GlyphTestMode
    launchMode testOptions {optionMission = Just "m", optionDoctor = True} `shouldBe` DoctorMode
    launchMode testOptions {optionMission = Just "m", optionUsage = True} `shouldBe` UsageQueryMode
    launchMode testOptions {optionMission = Just "m", optionPing = ["codex"]} `shouldBe` PingQueryMode

  -- Requirement 3's second half. @app/Main.hs@ resolves the brand ahead of
  -- mode selection, so the two halves asserted here are what makes a
  -- malformed --ping refuse even when a mission is named: the brand does not
  -- resolve, and mission mode never wins the selection anyway.
  it "leaves a malformed --ping refused ahead of a mission argument" $ do
    launchMode testOptions {optionMission = Just "m", optionPing = ["nope"]} `shouldBe` PingQueryMode
    resolvePingBrand ["nope"] `shouldSatisfy` either (const True) (const False)
    launchMode testOptions {optionMission = Just "m", optionPing = ["codex", "claude"]} `shouldBe` PingQueryMode
    resolvePingBrand ["codex", "claude"] `shouldSatisfy` either (const True) (const False)

-- ---------------------------------------------------------------------------
-- Selection
-- ---------------------------------------------------------------------------

selectionSpec :: Spec
selectionSpec = describe "which mission it runs" $ do
  it "requires an identifier" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \_ _ -> do
      refused <- runMissionMode testOptions runnerConfig boardRepository "   "
      refused `shouldBe` Left "--mission takes the identifier of exactly one mission"

  it "refuses a malformed identifier rather than resolving one" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      started <- startMissionController store boardRepository (MissionId "../elsewhere") (stagedDriver stage)
      case started of
        Right _ -> expectationFailure "a traversing identifier started a controller"
        Left refusal -> do
          case refusal of
            MissionIdentifierUnusable identifier _ -> identifier `shouldBe` "../elsewhere"
            other -> expectationFailure ("unexpected refusal: " <> show other)
          Text.unpack (missionStartRefusalMessage refusal)
            `shouldSatisfy` isInfixOf "is not a single plain name"

  it "refuses an unknown identifier" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      started <- startMissionController store boardRepository (MissionId "mission-9999") (stagedDriver stage)
      case started of
        Right _ -> expectationFailure "an unknown mission started a controller"
        Left refusal -> refusal `shouldBe` MissionUnknown (MissionId "mission-9999")

  -- Requirement 2's fourth refusal, and the proof for requirement 2's third
  -- clause: the mission this store holds is right there, and a runner pointed
  -- at another repository refuses instead of advancing it.
  it "refuses a mission recorded against another repository, and substitutes nothing" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      let elsewhere = boardRepository {repositoryName = "elsewhere"}
      started <- startMissionController store elsewhere theMission (stagedDriver stage)
      case started of
        Right _ -> expectationFailure "a foreign repository started a controller"
        Left refusal -> do
          refusal
            `shouldBe` MissionRepositoryMismatched
              theMission
              (MissionRepository "coghex" "kanban")
              (MissionRepository "coghex" "elsewhere")
          -- Nothing was dispatched for the mission that /is/ there.
          readIORef stage.stageDispatches `shouldReturn` []

  -- Requirement 2's third clause outright: two missions exist and the one that
  -- was not named stays exactly where it was.
  it "never advances a mission other than the one it was named" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      let other = theSpecification {missionSpecificationId = MissionId "mission-0002"}
      createMissionSpecification store other `shouldReturn` Right MissionCreated
      otherWritten <-
        writeMissionSnapshot
          store
          ((snapshotWith MissionRunning [stepRecord MissionStepPending []] []) {missionSnapshotId = MissionId "mission-0002"})
      otherWritten `shouldBe` Right ()
      _ <- oneIteration store stage
      untouched <- readMissionSnapshot store (MissionId "mission-0002")
      case untouched of
        MissionPresent snapshot -> stepLifecycle snapshot `shouldBe` Just MissionStepPending
        _ -> expectationFailure "the other mission's snapshot did not read back"

runnerConfig :: ResolvedConfig
runnerConfig = resolveGlobalConfig defaultRawConfig

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

startupSpec :: Spec
startupSpec = describe "the order it starts in" $ do
  -- Requirement 6's first three stages, proved by what a refusal leaves
  -- behind. Identity is validated before the lease is claimed, so a run
  -- pointed at the wrong repository leaves no lease standing — which the next
  -- correctly-pointed run demonstrates by taking it.
  it "validates identity before it claims the lease" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      let elsewhere = boardRepository {repositoryName = "elsewhere"}
      refused <- startMissionController store elsewhere theMission (stagedDriver stage)
      case refused of
        Right _ -> expectationFailure "a foreign repository started a controller"
        Left _ -> pure ()
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure ("a lease was left held: " <> Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> stopMissionController controller

  -- Requirement 17: everything in the repository is inventoried for validation
  -- and conflict detection, and the runner still advances only what it was
  -- named. The second half is 'never advances a mission other than the one it
  -- was named' above; this is the first.
  it "inventories the repository without selecting from it" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          controller.missionControllerInventory.missionInventoryMissions `shouldBe` [theMission]
          controller.missionControllerInventory.missionInventoryWorkers `shouldBe` ["solve-844-0001"]
          controller.missionControllerMission `shouldBe` theMission
          stopMissionController controller

  -- Requirement 6's fourth stage. What the record could not settle is reported
  -- at startup rather than discovered when something tries to act on it.
  it "reports the invocations the record never saw the end of" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepDispatching []] []) $ \store stage -> do
      openInvocation store
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          map ((.missionInvocationId) . (.missionInvocationRecord)) controller.missionControllerUnresolved
            `shouldBe` [MissionInvocationId "solve-844-1"]
          stopMissionController controller
      journal <- readMissionJournal store theMission 0
      case journal of
        Left message -> expectationFailure (Text.unpack message)
        Right (lines', _) ->
          [detail | MissionJournalEvent event <- lines', event.missionEventKind == "controller_started", Just detail <- [event.missionEventDetail]]
            `shouldSatisfy` any (isInfixOf "1 invocation(s) with no recorded outcome" . Text.unpack)

-- ---------------------------------------------------------------------------
-- The lease
-- ---------------------------------------------------------------------------

leaseSpec :: Spec
leaseSpec = describe "the advancement lease" $ do
  it "refuses a second controller while the first holds it" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      first <- startMissionController store boardRepository theMission (stagedDriver stage)
      case first of
        Left refusal -> expectationFailure ("the first controller refused: " <> Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          second <- startMissionController store boardRepository theMission (stagedDriver stage)
          case second of
            Right _ -> expectationFailure "a second controller took the advancement lease"
            Left refusal -> case refusal of
              MissionAlreadyAdvancing mission _ -> mission `shouldBe` theMission
              other -> expectationFailure ("unexpected refusal: " <> show other)
          stopMissionController controller

  -- Requirement 4's read-and-steer half. The attachment reads the same durable
  -- record and submits commands; what it does not do is compete, which is why
  -- it succeeds while the controller is holding the lease.
  it "lets a dashboard attach and steer while the controller holds it" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      first <- startMissionController store boardRepository theMission (stagedDriver stage)
      case first of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          attached <- attachToMission store boardRepository theMission
          case attached of
            Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
            Right attachment -> do
              attachment.missionAttachmentSnapshot.missionSnapshotLifecycle `shouldBe` MissionRunning
              submitted <- submitMissionCommand attachment.missionAttachmentControl "c-1" (MissionPauseCommand "operator asked")
              submitted `shouldBe` Right ()
          stopMissionController controller
      -- And it dispatched nothing. It holds no driver at all, which is what
      -- makes requirement 4's "must not independently dispatch work" a
      -- property of the type rather than a discipline.
      readIORef stage.stageDispatches `shouldReturn` []

  it "releases the lease when the controller stops, so the next run may take it" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      first <- startMissionController store boardRepository theMission (stagedDriver stage)
      case first of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> stopMissionController controller
      second <- startMissionController store boardRepository theMission (stagedDriver stage)
      case second of
        Left refusal -> expectationFailure ("the lease was not released: " <> Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> stopMissionController controller

-- ---------------------------------------------------------------------------
-- Reconciliation
-- ---------------------------------------------------------------------------

reconciliationSpec :: Spec
reconciliationSpec = describe "what it makes of live evidence" $ do
  it "classifies each of requirement 9's five readings distinctly" $ do
    let base =
          MissionStepEvidence
            { missionEvidenceStep = theStep,
              missionEvidenceLifecycle = MissionStepRunning,
              missionEvidenceInvocation = Nothing,
              missionEvidenceWorker = Nothing,
              missionEvidenceSatisfied = Nothing,
              missionEvidenceDeparted = Nothing,
              missionEvidenceForeign = Nothing
            }
        reading live compatible conclusion =
          MissionWorkerReading
            { missionWorkerSession = MissionSessionId "solve-844-0001",
              missionWorkerLive = live,
              missionWorkerCompatible = compatible,
              missionWorkerTerminal = conclusion,
              missionWorkerProviderSession = Just "provider-1"
            }
    missionExternalWorkTag (classifyMissionWork base {missionEvidenceSatisfied = Just "landed"})
      `shouldBe` "satisfied_externally"
    missionExternalWorkTag (classifyMissionWork base {missionEvidenceWorker = Just (reading True True Nothing)})
      `shouldBe` "attachable"
    missionExternalWorkTag (classifyMissionWork base {missionEvidenceWorker = Just (reading True False Nothing)})
      `shouldBe` "conflicting"
    missionExternalWorkTag (classifyMissionWork base {missionEvidenceForeign = Just "somebody else's worker"})
      `shouldBe` "conflicting"
    missionExternalWorkTag
      ( classifyMissionWork
          base {missionEvidenceWorker = Just (reading False True (Just (MissionWorkerFailed (MissionFailureGeneric "died"))))}
      )
      `shouldBe` "external_failure"

  -- Requirement 9's fourth reading, which is requirement 7's unknown outcome:
  -- an invocation was journaled and nothing conclusive can be found for it.
  it "reads an unresolved invocation with no worker as an unknown outcome" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepDispatching []] []) $ \store stage -> do
      openInvocation store
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled step lifecycle _) -> do
          step `shouldBe` theStep
          lifecycle `shouldBe` MissionStepOutcomeUnknown
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

  it "reattaches to a compatible live worker instead of launching another" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepDispatching [MissionSessionId "solve-844-0001"]] []) $ \store stage -> do
      writeIORef stage.stageEvidence $ \evidence ->
        evidence
          { missionEvidenceWorker =
              Just
                MissionWorkerReading
                  { missionWorkerSession = MissionSessionId "solve-844-0001",
                    missionWorkerLive = True,
                    missionWorkerCompatible = True,
                    missionWorkerTerminal = Nothing,
                    missionWorkerProviderSession = Just "provider-1"
                  }
          }
      iteration <- oneIteration store stage
      iteration `shouldBe` MissionAdvanced (MissionStepAttached theStep (MissionSessionId "solve-844-0001"))
      readIORef stage.stageDispatches `shouldReturn` []
      snapshot <- currentSnapshot store
      stepLifecycle snapshot `shouldBe` Just MissionStepRunning

  -- Requirement 11's accounting reads the session tree and nothing else, so a
  -- worker recorded only as an identifier on a step record is a worker no
  -- child can name as its parent, no termination can reach, and no parent has
  -- to wait for.
  it "registers the session a dispatch produced in the mission's own tree" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      _ <- oneIteration store stage
      snapshot <- currentSnapshot store
      map (.missionSessionId) snapshot.missionSnapshotSessions
        `shouldBe` [MissionSessionId "solve-844-0001"]
      map (.missionSessionParent) snapshot.missionSnapshotSessions `shouldBe` [Nothing]
      map (.missionSessionStep) snapshot.missionSnapshotSessions `shouldBe` [Just theStep]
      map (.missionSessionProviderSessionId) snapshot.missionSnapshotSessions `shouldBe` [Just "provider-1"]
      -- Freshly registered and never observed, so nothing proves it is gone.
      map missionSessionDisposition snapshot.missionSnapshotSessions
        `shouldBe` [MissionSessionUnverifiable]

  -- The other half of the same rule: the tree has to be able to reach a
  -- settled state, and only an observation can put it there.
  it "records the end of a registered session when its worker settles" $ do
    let sessions = [sessionNode "solve-844-0001" Nothing Nothing]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [MissionSessionId "solve-844-0001"]] sessions) $ \store stage -> do
      writeIORef stage.stageSessions [MissionSessionId "solve-844-0001"]
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionSessionEnded session detail) -> do
          session `shouldBe` MissionSessionId "solve-844-0001"
          detail `shouldBe` "it completed"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      snapshot <- currentSnapshot store
      map missionSessionDisposition snapshot.missionSnapshotSessions `shouldBe` [MissionSessionSettled]

  -- Requirement 4's blocker, stated as a loop that does not happen: a running
  -- step whose worker cannot be found anywhere and whose result did not land
  -- is an outcome nobody observed, not a step to wait on for ever.
  it "stops waiting on a running step nothing can be found for" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [MissionSessionId "solve-844-0001"]] []) $ \store stage -> do
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled step MissionStepOutcomeUnknown detail) -> do
          step `shouldBe` theStep
          Text.unpack detail `shouldSatisfy` isInfixOf "no live worker"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

  -- An open read covers open work, so a closed issue nobody solved and a
  -- finished one are equally absent from it. Reading that absence as success
  -- is how a mission would report work nobody did.
  it "reads a target that left the open read as unresolved, never as landed" $ do
    let base =
          MissionStepEvidence
            { missionEvidenceStep = theStep,
              missionEvidenceLifecycle = MissionStepRunning,
              missionEvidenceInvocation = Nothing,
              missionEvidenceWorker = Nothing,
              missionEvidenceSatisfied = Nothing,
              missionEvidenceDeparted = Just "#844 has left this repository's open read",
              missionEvidenceForeign = Nothing
            }
    missionExternalWorkTag (classifyMissionWork base) `shouldBe` "outcome_unknown"
    -- Positive evidence still wins, and is the only thing that does.
    missionExternalWorkTag (classifyMissionWork base {missionEvidenceSatisfied = Just "PR #900 links it"})
      `shouldBe` "satisfied_externally"

  it "carries a departed target through to a mission waiting for input" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning []] []) $ \store stage -> do
      writeIORef stage.stageEvidence $ \evidence ->
        evidence {missionEvidenceDeparted = Just "#844 has left this repository's open read"}
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled _ MissionStepOutcomeUnknown _) -> pure ()
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

  it "pauses on live work it did not register" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning []] []) $ \store stage -> do
      writeIORef stage.stageEvidence $ \evidence ->
        evidence {missionEvidenceForeign = Just "worker solve-844-0009 is registered against #844"}
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionLifecycleSet MissionPaused _) -> pure ()
        other -> expectationFailure ("unexpected iteration: " <> show other)
      snapshot <- currentSnapshot store
      snapshot.missionSnapshotLifecycle `shouldBe` MissionPaused
      readIORef stage.stageDispatches `shouldReturn` []

  it "records a landed external result rather than repeating it" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning []] []) $ \store stage -> do
      writeIORef stage.stageEvidence $ \evidence ->
        evidence {missionEvidenceSatisfied = Just "PR #900 already links #844"}
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled step MissionStepSucceeded detail) -> do
          step `shouldBe` theStep
          detail `shouldBe` "PR #900 already links #844"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

  -- Requirement 11's last sentence. The step's own worker settled and the
  -- board says the work landed, and the step still may not be called finished
  -- while a session it registered is unaccounted for.
  it "keeps an owning step nonterminal while a registered child survives" $ do
    let parent = MissionSessionId "solve-844-0001"
        sessions = [sessionNode "solve-844-0001" Nothing settledObservation, liveChild "child-1" parent]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [parent]] sessions) $ \store stage -> do
      writeIORef stage.stageEvidence $ \evidence ->
        evidence {missionEvidenceSatisfied = Just "PR #900 already links #844"}
      iteration <- oneIteration store stage
      case iteration of
        MissionAwaiting _ -> pure ()
        other -> expectationFailure ("the parent settled while its child was live: " <> show other)
      snapshot <- currentSnapshot store
      stepLifecycle snapshot `shouldBe` Just MissionStepRunning

  -- The blocked set requirement 1 names, enumerated rather than derived, and
  -- the proof the runner is not resident: every lifecycle it cannot advance
  -- from ends the run instead of being idled in.
  it "halts rather than idling on every lifecycle it cannot advance" $ do
    let advanceable = [MissionPlanned, MissionRunning, MissionRecovering]
        blocked = [MissionWaitingInput, MissionWaitingBarrier, MissionWaitingCapacity, MissionPaused, MissionInterrupted]
    filter missionLifecycleBlocks missionLifecycles `shouldBe` blocked
    filter missionLifecycleAdvances missionLifecycles `shouldBe` advanceable
    sequence_
      [ (lifecycle, missionRunnerHalt (snapshotWith lifecycle [] []) []) `shouldSatisfy` (\(_, halt) -> halt /= Nothing)
        | lifecycle <- missionLifecycles,
          lifecycle `notElem` advanceable
      ]
    sequence_
      [ (lifecycle, missionRunnerHalt (snapshotWith lifecycle [] []) []) `shouldBe` (lifecycle, Nothing)
        | lifecycle <- advanceable
      ]

  -- A step cancelled because its dependency failed accompanies that failure
  -- in every such mission, so reading the cancellation first would report
  -- every failed mission as cancelled.
  it "reports a mission whose step failed as failed, not cancelled" $ do
    let failedThenCancelled =
          snapshotWith
            MissionRunning
            [ stepRecord MissionStepFailed [],
              (stepRecord MissionStepCancelled []) {missionStepRecordId = MissionStepId "review-844"}
            ]
            []
    settledMissionLifecycle failedThenCancelled `shouldBe` Just MissionFailed
    settledMissionLifecycle (snapshotWith MissionRunning [stepRecord MissionStepCancelled []] [])
      `shouldBe` Just MissionCancelled
    settledMissionLifecycle (snapshotWith MissionRunning [stepRecord MissionStepSucceeded []] [])
      `shouldBe` Just MissionCompleted
    settledMissionLifecycle (snapshotWith MissionRunning [stepRecord MissionStepNeedsInput []] [])
      `shouldBe` Nothing

  it "ends the foreground run when the mission is waiting for input" $
    withMission (snapshotWith MissionWaitingInput [stepRecord MissionStepNeedsInput []] []) $ \store stage -> do
      report <- runMissionWith Nothing store boardRepository theMission (stagedDriver stage)
      case report of
        Left detail -> expectationFailure (Text.unpack detail)
        Right run -> do
          run.missionRunConclusion `shouldBe` Right (MissionHaltBlocked MissionWaitingInput "it is waiting for an answer this runner cannot supply")
          missionRunSucceeded run `shouldBe` True
      readIORef stage.stageDispatches `shouldReturn` []

-- | The invocation 'openInvocation' writes, as the reader returns it.
openInvocationState :: MissionInvocationState
openInvocationState =
  MissionInvocationState
    { missionInvocationRecord =
        MissionInvocation
          { missionInvocationId = MissionInvocationId "solve-844-1",
            missionInvocationMission = theMission,
            missionInvocationRepository = MissionRepository "coghex" "kanban",
            missionInvocationStep = theStep,
            missionInvocationAction = "solve_issue",
            missionInvocationTarget = Just theTarget,
            missionInvocationVersion = Just (issueVersion ["reviewed:approve"]),
            missionInvocationEffect = MissionEffectDispatch "solve_issue",
            missionInvocationParent = Nothing,
            missionInvocationAt = fixedTime
          },
      missionInvocationOutcome = Nothing
    }

-- | Closes the invocation 'openInvocation' wrote.
concludeOpenInvocation :: MissionStore -> MissionInvocationOutcome -> IO ()
concludeOpenInvocation store outcome = case missionInvocationPath store.missionStoreDirectory theMission of
  Left message -> fail (Text.unpack message)
  Right path -> do
    concluded <- concludeMissionInvocation path (MissionInvocationId "solve-844-1") outcome fixedTime
    concluded `shouldBe` Right ()

-- | The durable state a crash between the invocation record and the launch
-- leaves: one opened invocation and no conclusion.
openInvocation :: MissionStore -> IO ()
openInvocation store = case missionInvocationPath store.missionStoreDirectory theMission of
  Left message -> fail (Text.unpack message)
  Right path -> do
    written <-
      recordMissionInvocation
        path
        MissionInvocation
          { missionInvocationId = MissionInvocationId "solve-844-1",
            missionInvocationMission = theMission,
            missionInvocationRepository = MissionRepository "coghex" "kanban",
            missionInvocationStep = theStep,
            missionInvocationAction = "solve_issue",
            missionInvocationTarget = Just theTarget,
            missionInvocationVersion = Just (issueVersion ["reviewed:approve"]),
            missionInvocationEffect = MissionEffectDispatch "solve_issue",
            missionInvocationParent = Nothing,
            missionInvocationAt = fixedTime
          }
    written `shouldBe` Right ()

-- ---------------------------------------------------------------------------
-- Crash recovery
-- ---------------------------------------------------------------------------

crashRecoverySpec :: Spec
crashRecoverySpec = describe "the durable state a crash leaves" $ do
  it "dispatches exactly once when the crash landed before the invocation record" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      currentInvocations store `shouldReturn` []
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepDispatched step _ session) -> do
          step `shouldBe` theStep
          session `shouldBe` MissionSessionId "solve-844-0001"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      dispatched <- readIORef stage.stageDispatches
      length dispatched `shouldBe` 1
      recorded <- currentInvocations store
      map (fmap missionInvocationOutcomeTag . (.missionInvocationOutcome)) recorded
        `shouldBe` [Just "dispatched"]

  -- The exact window requirement 3 names. The record is on disk, the launch
  -- never happened or may have, and nothing here may guess which.
  it "reports an unknown outcome, and never relaunches, after the record was flushed" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepDispatching []] []) $ \store stage -> do
      openInvocation store
      first <- oneIteration store stage
      case first of
        MissionAdvanced (MissionStepReconciled _ MissionStepOutcomeUnknown _) -> pure ()
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []
      -- And a second pass does not change its mind either: the mission stops
      -- for direction rather than retrying.
      second <- oneIteration store stage
      case second of
        MissionAdvanced (MissionLifecycleSet MissionWaitingInput _) -> pure ()
        other -> expectationFailure ("unexpected second iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []
      recorded <- currentInvocations store
      map missionInvocationResolved recorded `shouldBe` [False]

  -- The window between the invocation record and the `dispatching` write. The
  -- step record is exactly what a run that never dispatched would have left,
  -- so only the invocation file knows better — and dispatching again would
  -- repeat an effect that may already have happened.
  it "never re-dispatches a pending step whose invocation was already journaled" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      openInvocation store
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled step MissionStepOutcomeUnknown detail) -> do
          step `shouldBe` theStep
          Text.unpack detail `shouldSatisfy` isInfixOf "no worker records it"
        other -> expectationFailure ("a journaled invocation was dispatched again: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

  it "classifies that window purely, from the record alone" $ do
    let stillPending = snapshotWith MissionRunning [stepRecord MissionStepPending []] []
        alreadyRunning = snapshotWith MissionRunning [stepRecord MissionStepRunning []] []
        open = openInvocationState
    (.missionOpenDispatchStep) <$> unresolvedDispatchOf [open] theSpecification stillPending
      `shouldBe` Just theStep
    unresolvedDispatchOf [open] theSpecification alreadyRunning `shouldBe` Nothing
    unresolvedDispatchOf [] theSpecification stillPending `shouldBe` Nothing

  -- The window between the driver returning and the snapshot write. The
  -- invocation's conclusion already names the worker, and it is written first
  -- precisely so this repair has something to work from; without it the next
  -- run finds a live worker it started and pauses the mission as foreign work.
  it "adopts a worker its invocation records but the snapshot never registered" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepDispatching []] []) $ \store stage -> do
      openInvocation store
      concludeOpenInvocation store (MissionInvocationDispatched "solve-844-0001")
      iteration <- oneIteration store stage
      iteration `shouldBe` MissionAdvanced (MissionStepAttached theStep (MissionSessionId "solve-844-0001"))
      readIORef stage.stageDispatches `shouldReturn` []
      snapshot <- currentSnapshot store
      map (.missionSessionId) snapshot.missionSnapshotSessions
        `shouldBe` [MissionSessionId "solve-844-0001"]
      missionStepRecordFor theStep snapshot
        `shouldSatisfy` maybe False ((== [MissionSessionId "solve-844-0001"]) . (.missionStepRecordSessions))

  it "classifies that window purely too" $ do
    let dispatching = snapshotWith MissionRunning [stepRecord MissionStepDispatching []] []
        -- Registration is the session tree, which is where a child's is too.
        registered =
          snapshotWith
            MissionRunning
            [stepRecord MissionStepDispatching [MissionSessionId "solve-844-0001"]]
            [sessionNode "solve-844-0001" Nothing Nothing]
        settled = snapshotWith MissionRunning [stepRecord MissionStepSucceeded []] []
        closed = openInvocationState {missionInvocationOutcome = Just (MissionInvocationDispatched "solve-844-0001")}
    dispatchedButUnregistered [closed] dispatching
      `shouldBe` Just (theStep, MissionSessionId "solve-844-0001", Nothing)
    dispatchedButUnregistered [closed] registered `shouldBe` Nothing
    dispatchedButUnregistered [closed] settled `shouldBe` Nothing
    dispatchedButUnregistered [openInvocationState] dispatching `shouldBe` Nothing

  -- The narrowest window of the three: the driver launched a worker and the
  -- controller died before recording which. The launch wrote the invocation's
  -- identity into that worker's own specification, so the two find each other
  -- again and the mission adopts its own worker instead of pausing on it.
  it "adopts the worker an open invocation launched, rather than pausing on it" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepDispatching []] []) $ \store stage -> do
      openInvocation store
      writeIORef stage.stageAdoptions [(MissionInvocationId "solve-844-1", MissionSessionId "solve-844-0001")]
      iteration <- oneIteration store stage
      iteration `shouldBe` MissionAdvanced (MissionStepAttached theStep (MissionSessionId "solve-844-0001"))
      readIORef stage.stageDispatches `shouldReturn` []
      -- The invocation is closed with what it turned out to have launched, so
      -- the next run reads an ordinary dispatched record rather than this
      -- window again.
      recorded <- currentInvocations store
      map (fmap missionInvocationOutcomeTag . (.missionInvocationOutcome)) recorded `shouldBe` [Just "dispatched"]
      snapshot <- currentSnapshot store
      map (.missionSessionId) snapshot.missionSnapshotSessions
        `shouldBe` [MissionSessionId "solve-844-0001"]

  it "falls back to an unknown outcome when no worker records the invocation" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepDispatching []] []) $ \store stage -> do
      openInvocation store
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled _ MissionStepOutcomeUnknown detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "no worker records it"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

  it "reconciles a crash after the launch from the worker's own evidence" $
    -- The registration landed whole: one snapshot write puts the session on
    -- the step record and in the session tree, so a crash after it leaves
    -- both.
    withMission
      ( snapshotWith
          MissionRunning
          [stepRecord MissionStepDispatching [MissionSessionId "solve-844-0001"]]
          [sessionNode "solve-844-0001" Nothing settledObservation]
      )
      $ \store stage -> do
      openInvocation store
      case missionInvocationPath store.missionStoreDirectory theMission of
        Left message -> fail (Text.unpack message)
        Right path -> do
          concluded <-
            concludeMissionInvocation path (MissionInvocationId "solve-844-1") (MissionInvocationDispatched "solve-844-0001") fixedTime
          concluded `shouldBe` Right ()
      writeIORef stage.stageEvidence $ \evidence ->
        evidence
          { missionEvidenceWorker =
              Just
                MissionWorkerReading
                  { missionWorkerSession = MissionSessionId "solve-844-0001",
                    missionWorkerLive = False,
                    missionWorkerCompatible = True,
                    missionWorkerTerminal = Just (MissionWorkerSucceeded "the registered worker completed"),
                    missionWorkerProviderSession = Just "provider-1"
                  },
            missionEvidenceSatisfied = Just "PR #900 already links #844"
          }
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled _ MissionStepSucceeded _) -> pure ()
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

  it "reads a dead worker whose result landed as satisfied rather than failed" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [MissionSessionId "solve-844-0001"]] []) $ \store stage -> do
      writeIORef stage.stageEvidence $ \evidence ->
        evidence
          { missionEvidenceWorker =
              Just
                MissionWorkerReading
                  { missionWorkerSession = MissionSessionId "solve-844-0001",
                    missionWorkerLive = False,
                    missionWorkerCompatible = True,
                    missionWorkerTerminal = Nothing,
                    missionWorkerProviderSession = Nothing
                  },
            missionEvidenceSatisfied = Just "PR #900 already links #844"
          }
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled _ MissionStepSucceeded _) -> pure ()
        other -> expectationFailure ("unexpected iteration: " <> show other)

-- ---------------------------------------------------------------------------
-- Preconditions
-- ---------------------------------------------------------------------------

preconditionSpec :: Spec
preconditionSpec = describe "the exact-version precondition" $ do
  it "holds only when every recorded fact still agrees" $ do
    missionVersionHolds (issueVersion ["a", "b"]) (issueVersion ["b", "a"]) `shouldBe` True
    missionVersionHolds (issueVersion ["a"]) (issueVersion ["a", "b"]) `shouldBe` False
    missionVersionHolds (issueVersion ["a"]) ((issueVersion ["a"]) {missionVersionState = "closed"}) `shouldBe` False
    missionVersionHolds
      (issueVersion ["a"])
      ((issueVersion ["a"]) {missionVersionUpdatedAt = addUTCTime 60 fixedTime})
      `shouldBe` False

  -- Requirement 8's whole point: the target moves between the plan and the
  -- effect, and nothing is mutated.
  it "refuses the effect when the target moved after the plan was journaled" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      writeIORef
        stage.stageTargets
        [ Right (issueVersion ["reviewed:approve"]),
          Right (issueVersion ["reviewed:approve", "blocked"])
        ]
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled step MissionStepPending detail) -> do
          step `shouldBe` theStep
          Text.unpack detail `shouldSatisfy` isInfixOf "stale version"
          Text.unpack detail `shouldSatisfy` isInfixOf "nothing was mutated"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []
      recorded <- currentInvocations store
      map (fmap missionInvocationOutcomeTag . (.missionInvocationOutcome)) recorded `shouldBe` [Just "stale_version"]

  -- The other side of the boundary. When the target cannot be reread nothing
  -- is dispatched, so the invocation is resolved as never having happened and
  -- the step goes back to pending. The run ends rather than asking a network
  -- that is down once per iteration, and the mission's own lifecycle is left
  -- exactly as it was, so the next run plans again instead of halting on a
  -- state this one wrote about somebody's connection.
  it "dispatches nothing, and stops, when the precondition cannot be reread" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      writeIORef stage.stageTargets [Right (issueVersion ["reviewed:approve"]), Left "GitHub is unreachable"]
      iteration <- oneIteration store stage
      case iteration of
        MissionControllerFailed detail -> detail `shouldBe` "GitHub is unreachable"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []
      recorded <- currentInvocations store
      map (fmap missionInvocationOutcomeTag . (.missionInvocationOutcome)) recorded `shouldBe` [Just "abandoned"]
      snapshot <- currentSnapshot store
      stepLifecycle snapshot `shouldBe` Just MissionStepPending
      snapshot.missionSnapshotLifecycle `shouldBe` MissionRunning

  -- And the run reports it as a run that could not establish what it needed,
  -- rather than as a mission that concluded anything.
  it "reports an unreadable precondition as a stopped run" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      writeIORef stage.stageTargets [Right (issueVersion ["reviewed:approve"]), Left "GitHub is unreachable"]
      report <- runMissionWith Nothing store boardRepository theMission (stagedDriver stage)
      case report of
        Left detail -> expectationFailure (Text.unpack detail)
        Right run -> do
          run.missionRunConclusion `shouldBe` Left "GitHub is unreachable"
          missionRunSucceeded run `shouldBe` False

  it "journals the observed version before the effect is attempted" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      _ <- oneIteration store stage
      recorded <- currentInvocations store
      map ((.missionInvocationVersion) . (.missionInvocationRecord)) recorded
        `shouldBe` [Just (issueVersion ["reviewed:approve"])]
      map ((.missionInvocationAction) . (.missionInvocationRecord)) recorded `shouldBe` ["solve_issue"]
      map (missionIntendedEffectTag . (.missionInvocationEffect) . (.missionInvocationRecord)) recorded
        `shouldBe` ["dispatch:solve_issue"]

-- ---------------------------------------------------------------------------
-- Continuation
-- ---------------------------------------------------------------------------

continuationSpec :: Spec
continuationSpec = describe "how a step's next turn continues" $ do
  it "resumes the recorded provider session when there is one" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] [sessionNode "solve-844-0001" Nothing settledObservation]) $ \store stage -> do
      _ <- oneIteration store stage
      dispatched <- readIORef stage.stageDispatches
      map (.missionDispatchContinuation) dispatched `shouldBe` [MissionResumeSession "provider-solve-844-0001"]

  it "briefs a fresh session, bounded, when the recorded one cannot be resumed" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      _ <- oneIteration store stage
      dispatched <- readIORef stage.stageDispatches
      case map (.missionDispatchContinuation) dispatched of
        [MissionFreshSession brief] -> do
          Text.length brief `shouldSatisfy` (<= missionRecoveryBriefLimit)
          Text.unpack brief `shouldSatisfy` isInfixOf "take #844 to a reviewed pull request"
          Text.unpack brief `shouldSatisfy` isInfixOf "Immediate task: take #844 to a pull request"
        other -> expectationFailure ("unexpected continuation: " <> show other)

  it "keeps a brief inside its bound however much has settled" $ do
    let noisy = snapshotWith MissionRunning [stepRecord MissionStepSucceeded [] | _ <- [1 :: Int .. 400]] []
        brief = case theSpecification.missionSpecificationPlan of
          (step : _) -> missionRecoveryBrief theSpecification noisy step
          [] -> ""
    Text.length brief `shouldSatisfy` (<= missionRecoveryBriefLimit + 20)
    Text.unpack brief `shouldSatisfy` isInfixOf "brief truncated"

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

commandSpec :: Spec
commandSpec = describe "the runner-owned control channel" $ do
  it "records a user override submitted on the runner's own channel" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepOutcomeUnknown []] []) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          submitConsoleCommand controller "c-override" (MissionUserOverrideCommand theStep "it never ran; try again")
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionCommandApplied commandId _) -> commandId `shouldBe` "c-override"
            other -> expectationFailure ("unexpected iteration: " <> show other)
          stopMissionController controller
      snapshot <- currentSnapshot store
      stepLifecycle snapshot `shouldBe` Just MissionStepPending

  -- Requirement 14, and correction seven of the approving review: an attached
  -- client's input is durable and ordinary, and confers no override authority.
  it "refuses a user override submitted by an attached client" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepOutcomeUnknown []] []) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          attached <- attachToMissionAsClient store
          submitted <- submitMissionCommand attached "c-forged" (MissionUserOverrideCommand theStep "resolve it")
          submitted `shouldBe` Right ()
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionCommandRefused commandId detail) -> do
              commandId `shouldBe` "c-forged"
              Text.unpack detail `shouldSatisfy` isInfixOf "cannot record a user_override"
            other -> expectationFailure ("unexpected iteration: " <> show other)
          stopMissionController controller
      snapshot <- currentSnapshot store
      stepLifecycle snapshot `shouldBe` Just MissionStepOutcomeUnknown

  -- A file this release cannot read is left where it is, in case a newer one
  -- wrote it, and is therefore met again on every iteration. Reporting it
  -- again each time would fill the journal with one complaint.
  it "reports an unusable command file once, and leaves it alone" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning []] []) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          let junk = controller.missionControllerControl.missionControlRequests </> "broken.json"
          writeFile junk "{ this is not a command"
          _ <- missionControllerIteration controller
          _ <- missionControllerIteration controller
          _ <- missionControllerIteration controller
          stopMissionController controller
          doesFileExist junk `shouldReturn` True
      journal <- readMissionJournal store theMission 0
      case journal of
        Left message -> expectationFailure (Text.unpack message)
        Right (lines', _) ->
          length [() | MissionJournalEvent event <- lines', event.missionEventKind == "command_rejected"]
            `shouldBe` 1

  -- Round 2's blocker: a credential durable enough for a second process to
  -- present is durable enough for a third to copy, and the store is this
  -- user's — as is every provider session running under it. So there is no
  -- credential: the authenticated path never becomes a file at all, and every
  -- file is an ordinary operator command whoever wrote it.
  it "writes no credential into a submitted command, and grants none by file" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepOutcomeUnknown []] []) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          -- Submitted through the controller's own endpoint, which is the most
          -- privileged handle anything holds.
          submitted <-
            submitMissionCommand
              controller.missionControllerControl
              "c-file"
              (MissionUserOverrideCommand theStep "let me in")
          submitted `shouldBe` Right ()
          written <- listDirectory controller.missionControllerControl.missionControlRequests
          contents <- mapM (readFile . (controller.missionControllerControl.missionControlRequests </>)) written
          -- Nothing in the store looks like a secret, because none was minted.
          concat contents `shouldSatisfy` not . isInfixOf "secret"
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionCommandRefused "c-file" detail) ->
              Text.unpack detail `shouldSatisfy` isInfixOf "cannot record a user_override"
            other -> expectationFailure ("a file command took override authority: " <> show other)
          stopMissionController controller
      snapshot <- currentSnapshot store
      stepLifecycle snapshot `shouldBe` Just MissionStepOutcomeUnknown

  it "distinguishes the two authorities" $ do
    map missionCommandAuthorityTag [MissionRunnerAuthenticated, MissionAttachedClient] `shouldBe` ["runner", "attached"]
    map overrideAuthorized [MissionRunnerAuthenticated, MissionAttachedClient] `shouldBe` [True, False]

  -- Requirement 11's first sentence, asserted as the absence of an effect.
  it "pauses without terminating a single registered descendant" $ do
    let sessions = [sessionNode "solve-844-0001" Nothing Nothing, liveChild "child-1" (MissionSessionId "solve-844-0001")]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [MissionSessionId "solve-844-0001"]] sessions) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          submitConsoleCommand controller "c-pause" (MissionPauseCommand "operator asked")
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionCommandApplied "c-pause" _) -> pure ()
            other -> expectationFailure ("unexpected iteration: " <> show other)
          stopMissionController controller
      readIORef stage.stageTerminated `shouldReturn` []
      snapshot <- currentSnapshot store
      snapshot.missionSnapshotLifecycle `shouldBe` MissionPaused
      snapshot.missionSnapshotPause.missionPauseRequested `shouldBe` True

  it "ends a whole registered subtree only on an explicit authenticated command" $ do
    let root = MissionSessionId "solve-844-0001"
        sessions =
          [ sessionNode "solve-844-0001" Nothing Nothing,
            liveChild "child-1" root,
            liveChild "grandchild-1" (MissionSessionId "child-1")
          ]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [root]] sessions) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          submitConsoleCommand controller "c-end" (MissionTerminateSubtreeCommand root "operator asked")
          iteration <- missionControllerIteration controller
          -- Signalling is not ending: this pass reports what it asked for.
          case iteration of
            MissionAdvanced (MissionCommandApplied "c-end" detail) ->
              Text.unpack detail `shouldSatisfy` isInfixOf "its end is not yet established"
            other -> expectationFailure ("unexpected iteration: " <> show other)
          -- And once the sessions are observed to have ended, the pass that
          -- reads them is what says the subtree is terminated.
          writeIORef
            stage.stageSessions
            [root, MissionSessionId "child-1", MissionSessionId "grandchild-1"]
          -- The session pass records one observation per iteration, so the
          -- record it is waiting on closes once all three have been read.
          verified <- iterateUntil controller (isSubtreeTerminated root)
          verified `shouldBe` MissionAdvanced (MissionSubtreeTerminated root 3)
          stopMissionController controller
      terminated <- readIORef stage.stageTerminated
      terminated
        `shouldBe` [[MissionSessionId "solve-844-0001", MissionSessionId "child-1", MissionSessionId "grandchild-1"]]
      -- Journaled before the signal, which is what makes an interrupted
      -- termination recoverable rather than invisible.
      recorded <- currentInvocations store
      map (missionIntendedEffectTag . (.missionInvocationEffect) . (.missionInvocationRecord)) recorded
        `shouldBe` ["terminate:solve-844-0001"]

  -- The same command id arriving twice — a client that retried, or a run that
  -- died between journaling the answer and removing the file. Signalling the
  -- subtree a second time would journal a second account of one operator
  -- command.
  it "answers a replayed termination from its own record instead of repeating it" $ do
    let root = MissionSessionId "solve-844-0001"
        sessions = [sessionNode "solve-844-0001" Nothing Nothing, liveChild "child-1" root]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [root]] sessions) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          submitConsoleCommand controller "c-end" (MissionTerminateSubtreeCommand root "operator asked")
          first <- missionControllerIteration controller
          case first of
            MissionAdvanced (MissionCommandApplied "c-end" detail) ->
              Text.unpack detail `shouldSatisfy` isInfixOf "signalled the subtree"
            other -> expectationFailure ("unexpected iteration: " <> show other)
          submitConsoleCommand controller "c-end" (MissionTerminateSubtreeCommand root "operator asked")
          second <- missionControllerIteration controller
          case second of
            MissionAdvanced (MissionCommandApplied "c-end" detail) ->
              Text.unpack detail `shouldSatisfy` isInfixOf "already terminated"
            other -> expectationFailure ("unexpected replay iteration: " <> show other)
          stopMissionController controller
      length <$> readIORef stage.stageTerminated `shouldReturn` 1

  it "refuses a subtree termination from an attached client" $ do
    let root = MissionSessionId "solve-844-0001"
        sessions = [sessionNode "solve-844-0001" Nothing Nothing]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [root]] sessions) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          attached <- attachToMissionAsClient store
          _ <- submitMissionCommand attached "c-end" (MissionTerminateSubtreeCommand root "let me in")
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionCommandRefused "c-end" _) -> pure ()
            other -> expectationFailure ("unexpected iteration: " <> show other)
          stopMissionController controller
      readIORef stage.stageTerminated `shouldReturn` []

  it "computes the whole registered subtree, not one level of it" $ do
    let root = MissionSessionId "solve-844-0001"
        sessions =
          [ sessionNode "solve-844-0001" Nothing Nothing,
            liveChild "child-1" root,
            liveChild "grandchild-1" (MissionSessionId "child-1")
          ]
        snapshot = snapshotWith MissionRunning [stepRecord MissionStepRunning [root]] sessions
    map (.missionSessionId) (missionSessionSubtree snapshot root)
      `shouldBe` [root, MissionSessionId "child-1", MissionSessionId "grandchild-1"]

-- | The endpoint a client holds.
--
-- There is only one kind: a file channel carries no authority at all, so this
-- is the same endpoint the runner itself would open and every command written
-- through it is an ordinary operator command.
attachToMissionAsClient :: MissionStore -> IO MissionControlEndpoint
attachToMissionAsClient store = do
  attached <- openMissionControl store theMission
  case attached of
    Left message -> fail (Text.unpack message)
    Right endpoint -> pure endpoint

-- ---------------------------------------------------------------------------
-- Child requests
-- ---------------------------------------------------------------------------

childRequestSpec :: Spec
childRequestSpec = describe "registered child requests" $ do
  it "registers a child of a live registered parent, once" $
    withLiveParent $ \store stage controller -> do
      submitConsoleCommand controller "c-child" (childRequest "r-1" theMission (MissionSessionId "solve-844-0001"))
      first <- missionControllerIteration controller
      case first of
        MissionAdvanced (MissionCommandApplied "c-child" detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "registered child"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      length <$> readIORef stage.stageDispatches `shouldReturn` 1
      -- The replay: the same parent and the same request identity, and the
      -- answer already recorded rather than a second launch.
      submitConsoleCommand controller "c-child-again" (childRequest "r-1" theMission (MissionSessionId "solve-844-0001"))
      second <- missionControllerIteration controller
      case second of
        MissionAdvanced (MissionCommandApplied "c-child-again" detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "already answered"
        other -> expectationFailure ("unexpected replay iteration: " <> show other)
      length <$> readIORef stage.stageDispatches `shouldReturn` 1
      _ <- currentSnapshot store
      pure ()

  -- Requirement 12's child is an external effect like any other, so it takes
  -- the same discipline: its target is observed, journaled, and rechecked.
  it "journals a target-bearing child's observed version before launching it" $
    withLiveParent $ \store stage controller -> do
      submitConsoleCommand controller "c-target" (targetedChildRequest "r-9" theMission (MissionSessionId "solve-844-0001"))
      iteration <- missionControllerIteration controller
      case iteration of
        MissionAdvanced (MissionCommandApplied "c-target" _) -> pure ()
        other -> expectationFailure ("unexpected iteration: " <> show other)
      recorded <- currentInvocations store
      map ((.missionInvocationVersion) . (.missionInvocationRecord)) recorded
        `shouldBe` [Just (issueVersion ["reviewed:approve"])]
      dispatched <- readIORef stage.stageDispatches
      map (.missionDispatchVersion) dispatched `shouldBe` [Just (issueVersion ["reviewed:approve"])]

  it "refuses a child whose target moved between the plan and the launch" $
    withLiveParent $ \_ stage controller -> do
      writeIORef
        stage.stageTargets
        [Right (issueVersion ["reviewed:approve"]), Right (issueVersion ["reviewed:approve", "blocked"])]
      submitConsoleCommand controller "c-stale" (targetedChildRequest "r-10" theMission (MissionSessionId "solve-844-0001"))
      iteration <- missionControllerIteration controller
      case iteration of
        MissionAdvanced (MissionCommandRefused "c-stale" detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "stale version"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

  it "puts a registered child in the tree under the parent that asked for it" $
    withLiveParent $ \store _ controller -> do
      submitConsoleCommand controller "c-lineage" (childRequest "r-11" theMission (MissionSessionId "solve-844-0001"))
      _ <- missionControllerIteration controller
      snapshot <- currentSnapshot store
      [ (node.missionSessionId, node.missionSessionParent)
        | node <- snapshot.missionSnapshotSessions,
          node.missionSessionParent /= Nothing
        ]
        `shouldBe` [(childSessionFor theParent "r-11", Just theParent)]

  it "rejects a request naming another mission" $
    withLiveParent $ \_ stage controller -> do
      submitConsoleCommand controller "c-cross" (childRequest "r-2" (MissionId "mission-0002") (MissionSessionId "solve-844-0001"))
      iteration <- missionControllerIteration controller
      case iteration of
        MissionAdvanced (MissionCommandRefused "c-cross" detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "names mission mission-0002"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

  -- Registration is not enough: a session that has already ended is exactly
  -- the parent a forged request would claim, because its identifier is still
  -- in the record.
  it "rejects a request whose registered parent has already settled" $ do
    let sessions = [sessionNode "solve-844-0001" Nothing settledObservation]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [MissionSessionId "solve-844-0001"]] sessions) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          submitConsoleCommand controller "c-settled" (childRequest "r-5" theMission (MissionSessionId "solve-844-0001"))
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionCommandRefused "c-settled" detail) ->
              Text.unpack detail `shouldSatisfy` isInfixOf "not a live registered session"
            other -> expectationFailure ("unexpected iteration: " <> show other)
          stopMissionController controller
      readIORef stage.stageDispatches `shouldReturn` []

  it "rejects a request naming a parent this mission never registered" $
    withLiveParent $ \_ stage controller -> do
      submitConsoleCommand controller "c-dead" (childRequest "r-3" theMission (MissionSessionId "ghost-0001"))
      iteration <- missionControllerIteration controller
      case iteration of
        MissionAdvanced (MissionCommandRefused "c-dead" detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "not a live registered session"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

  it "rejects a request that did not arrive on the runner's own channel" $
    withLiveParent $ \store stage controller -> do
      attached <- attachToMissionAsClient store
      _ <- submitMissionCommand attached "c-forged" (childRequest "r-4" theMission (MissionSessionId "solve-844-0001"))
      iteration <- missionControllerIteration controller
      case iteration of
        MissionAdvanced (MissionCommandRefused "c-forged" detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "authenticated channel"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

childRequest :: Text -> MissionId -> MissionSessionId -> MissionCommandPayload
childRequest requestId mission parent =
  MissionChildRequestCommand
    MissionChildRequest
      { missionChildRequestId = requestId,
        missionChildRequestMission = mission,
        missionChildRequestParent = parent,
        missionChildRequestAction = "review_pull_request",
        missionChildRequestTarget = Nothing
      }

-- | The same request with a target, which is what brings the precondition
-- discipline into play.
targetedChildRequest :: Text -> MissionId -> MissionSessionId -> MissionCommandPayload
targetedChildRequest requestId mission parent = case childRequest requestId mission parent of
  MissionChildRequestCommand request ->
    MissionChildRequestCommand request {missionChildRequestTarget = Just theTarget}
  other -> other

withLiveParent :: (MissionStore -> Stage -> MissionController -> IO ()) -> IO ()
withLiveParent action = do
  let sessions = [sessionNode "solve-844-0001" Nothing Nothing]
  withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [MissionSessionId "solve-844-0001"]] sessions) $ \store stage -> do
    started <- startMissionController store boardRepository theMission (stagedDriver stage)
    case started of
      Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
      Right controller -> do
        action store stage controller
        stopMissionController controller

-- ---------------------------------------------------------------------------
-- The runner's own console
-- ---------------------------------------------------------------------------

consoleSpec :: Spec
consoleSpec = describe "the runner's own console" $ do
  it "parses every verb the grammar admits" $ do
    parse "pause the operator asked" `shouldBe` Right (MissionPauseCommand "the operator asked")
    parse "pause" `shouldBe` Right (MissionPauseCommand "the operator paused it")
    parse "resume" `shouldBe` Right MissionResumeCommand
    parse "override solve-844 it never ran"
      `shouldBe` Right (MissionUserOverrideCommand theStep "it never ran")
    parse "terminate solve-844-0001 enough"
      `shouldBe` Right (MissionTerminateSubtreeCommand (MissionSessionId "solve-844-0001") "enough")
    parse "child r-1 solve-844-0001 review_pull_request"
      `shouldBe` Right (childRequest "r-1" theMission (MissionSessionId "solve-844-0001"))

  it "reports a line it cannot turn into a command" $ do
    parse "" `shouldSatisfy` either (isInfixOf "empty" . Text.unpack) (const False)
    parse "merge 613" `shouldSatisfy` either (isInfixOf "unknown command merge" . Text.unpack) (const False)

  -- The production path requirement 3's blocker was about: a line typed at the
  -- runner's own console reaches the controller as an authenticated command.
  it "submits a console line through the endpoint the runner owns" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepOutcomeUnknown []] []) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          withConsole "override solve-844 it never ran\n" $ \handle ->
            drainMissionConsoleWith (pure True) handle controller
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionCommandApplied _ detail) ->
              Text.unpack detail `shouldSatisfy` isInfixOf "user override on solve-844"
            other -> expectationFailure ("unexpected iteration: " <> show other)
          stopMissionController controller
      snapshot <- currentSnapshot store
      stepLifecycle snapshot `shouldBe` Just MissionStepPending

  -- And the boundary that makes it authority rather than a formality: a handle
  -- that is not this process's terminal is some other process's output, which
  -- requirement 14 excludes by name.
  it "reads nothing from a handle that is not this process's terminal" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepOutcomeUnknown []] []) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          withConsole "override solve-844 let me in\n" $ \handle ->
            drainMissionConsoleWith (hIsTerminalDevice handle) handle controller
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionLifecycleSet MissionWaitingInput _) -> pure ()
            other -> expectationFailure ("a redirected handle was read as a console: " <> show other)
          stopMissionController controller
      snapshot <- currentSnapshot store
      stepLifecycle snapshot `shouldBe` Just MissionStepOutcomeUnknown

  it "journals a console line it could not parse rather than dropping it" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning []] []) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          withConsole "merge 613\n" $ \handle -> drainMissionConsoleWith (pure True) handle controller
          stopMissionController controller
      journal <- readMissionJournal store theMission 0
      case journal of
        Left message -> expectationFailure (Text.unpack message)
        Right (lines', _) ->
          [detail | MissionJournalEvent event <- lines', event.missionEventKind == "console_rejected", Just detail <- [event.missionEventDetail]]
            `shouldSatisfy` any (isInfixOf "merge 613" . Text.unpack)
  where
    parse = parseMissionConsoleCommand theMission

-- | A readable handle carrying exactly this text, which is not a terminal.
withConsole :: String -> (Handle -> IO result) -> IO result
withConsole typed action = withTemporaryCacheRoot $ \root -> do
  let path = root </> "console"
  writeFile path typed
  withFile path ReadMode action

-- ---------------------------------------------------------------------------
-- The precondition boundary
-- ---------------------------------------------------------------------------

preconditionBoundarySpec :: Spec
preconditionBoundarySpec = describe "the precondition the owning action enforces" $ do
  -- Requirement 8's boundary is the registry's, not only the controller's: the
  -- recorded expectation travels on the request so the owning action can
  -- compare it against its own read at the last instruction before the spawn.
  -- A dispatch that carried no version would leave that comparison with
  -- nothing to make.
  it "carries the recorded version onto every dispatched request" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      _ <- oneIteration store stage
      dispatched <- readIORef stage.stageDispatches
      map (.missionDispatchVersion) dispatched
        `shouldBe` [Just (issueVersion ["reviewed:approve"])]

  it "round-trips between the durable record and the registry's vocabulary" $ do
    let version = issueVersion ["reviewed:approve", "enhancement"]
    missionVersionOf (preconditionOf version) `shouldBe` version

  it "holds only when every fact still agrees" $ do
    let recorded = preconditionOf (issueVersion ["a", "b"])
    targetPreconditionHolds recorded (preconditionOf (issueVersion ["b", "a"])) `shouldBe` True
    targetPreconditionHolds recorded (preconditionOf (issueVersion ["a"])) `shouldBe` False
    targetPreconditionHolds recorded (preconditionOf ((issueVersion ["a", "b"]) {missionVersionState = "closed"}))
      `shouldBe` False
    Text.unpack (targetPreconditionMessage recorded (preconditionOf (issueVersion ["a"])))
      `shouldSatisfy` isInfixOf "nothing was dispatched"

-- ---------------------------------------------------------------------------
-- The configured deadline
-- ---------------------------------------------------------------------------

deadlineSpec :: Spec
deadlineSpec = describe "the configured action-worker deadline" $ do
  it "preserves the four-hour default when the setting is omitted" $ do
    defaultWorkerDeadlineSeconds `shouldBe` 14400
    defaultTimeoutsConfig.timeoutsWorkerDeadlineSeconds `shouldBe` 14400
    case decodeConfigText "[timeouts]\ngithub_seconds = 30\n" of
      Left message -> expectationFailure (Text.unpack message)
      Right (config, _) -> config.rawTimeouts.timeoutsWorkerDeadlineSeconds `shouldBe` 14400

  it "documents one finite maximum and rejects everything outside the range" $ do
    maximumWorkerDeadlineSeconds `shouldBe` 7 * 24 * 60 * 60
    sequence_
      [ (value, decodeConfigText ("[timeouts]\nworker_deadline_seconds = " <> value <> "\n"))
          `shouldSatisfy` (\(_, decoded) -> either (const True) (const False) decoded)
        | value <- ["0", "-1", Text.pack (show (maximumWorkerDeadlineSeconds + 1))]
      ]
    case decodeConfigText ("[timeouts]\nworker_deadline_seconds = " <> Text.pack (show maximumWorkerDeadlineSeconds) <> "\n") of
      Left message -> expectationFailure (Text.unpack message)
      Right (config, _) -> config.rawTimeouts.timeoutsWorkerDeadlineSeconds `shouldBe` maximumWorkerDeadlineSeconds

  it "names the ceiling in the message an over-maximum value fails with" $
    case decodeConfigText ("[timeouts]\nworker_deadline_seconds = " <> Text.pack (show (maximumWorkerDeadlineSeconds + 1)) <> "\n") of
      Right _ -> expectationFailure "an over-maximum deadline loaded"
      Left message -> Text.unpack message `shouldSatisfy` isInfixOf (show maximumWorkerDeadlineSeconds)

  -- Requirement 15's last clause. The bound a worker runs under is the one its
  -- own specification recorded, and a configuration edited since then cannot
  -- reach back into it: recovery decodes the specification, and the
  -- configuration is nowhere in that path.
  it "keeps the bound a running worker's specification already recorded" $ do
    let recorded = 999 :: Int
        recordedSpec = deadlineFixtureSpec boardRepository (WorkerId "solve-844-0001") 844 fixedTime recorded
        edited = runnerConfig {resolvedTimeouts = defaultTimeoutsConfig {timeoutsWorkerDeadlineSeconds = 60}}
    edited.resolvedTimeouts.timeoutsWorkerDeadlineSeconds `shouldBe` 60
    case eitherDecode (encode recordedSpec) of
      Left message -> expectationFailure message
      Right decoded -> (decoded :: WorkerSpec).workerMaxRuntimeSeconds `shouldBe` recorded

  it "carries the resolved value into the environment every launch runs through" $
    case decodeConfigText "[timeouts]\nworker_deadline_seconds = 3600\n" of
      Left message -> expectationFailure (Text.unpack message)
      Right (config, _) ->
        WorkerDeadline (resolveGlobalConfig config).resolvedTimeouts.timeoutsWorkerDeadlineSeconds
          `shouldBe` WorkerDeadline 3600

-- ---------------------------------------------------------------------------
-- The worker's own precondition
-- ---------------------------------------------------------------------------

workerPreconditionSpec :: Spec
workerPreconditionSpec = describe "the precondition a worker carries" $ do
  it "records nothing when the launch recorded nothing" $ do
    let launched = deadlineFixtureSpec boardRepository (WorkerId "solve-844-0001") 844 fixedTime 60
    launched.workerExpectedTarget `shouldBe` Nothing
    preconditionStillHolds launched `shouldReturn` Nothing

  it "round-trips the recorded expectation through the durable specification" $ do
    let expected = preconditionOf (issueVersion ["reviewed:approve"])
        launched =
          (deadlineFixtureSpec boardRepository (WorkerId "solve-844-0001") 844 fixedTime 60)
            {workerExpectedTarget = Just expected}
    case eitherDecode (encode launched) of
      Left message -> expectationFailure message
      Right decoded -> (decoded :: WorkerSpec).workerExpectedTarget `shouldBe` Just expected

  -- The last instant Kanban controls. The launch checked this in another
  -- process, possibly long ago; everything after this call is an agent session
  -- whose GitHub writes are its own.
  it "refuses the turn when the live target has moved since the launch" $
    withIsolatedGh $ \root -> do
      let expected = preconditionOf (issueVersion ["reviewed:approve"])
          launched =
            (deadlineFixtureSpec boardRepository (WorkerId "solve-844-0001") 844 fixedTime 60)
              {workerExpectedTarget = Just expected}
      withFakeGh root (ghItem ["reviewed:approve", "blocked"]) $ do
        moved <- preconditionStillHolds launched
        case moved of
          Nothing -> expectationFailure "a moved target was allowed to start its turn"
          Just detail -> do
            workerPreconditionRefusal detail `shouldBe` Just workerStaleTargetReason
            Text.unpack detail `shouldSatisfy` isInfixOf "its labels changed"
      withFakeGh root (ghItem ["reviewed:approve"]) $
        preconditionStillHolds launched `shouldReturn` Nothing

  -- Fail-closed, and this is the half that matters. Requirement 8 permits the
  -- mutation only if the exact recorded precondition still holds, and a target
  -- that cannot be read has not been shown to hold anything; nothing
  -- downstream carries the expectation to a later check, so starting the
  -- session anyway would act on a plan nobody has verified since the launch.
  it "refuses the turn when the reading could not be taken at all" $
    withIsolatedGh $ \root -> do
      let launched =
            (deadlineFixtureSpec boardRepository (WorkerId "solve-844-0001") 844 fixedTime 60)
              {workerExpectedTarget = Just (preconditionOf (issueVersion ["reviewed:approve"]))}
      withFakeGh root ["#!/bin/sh", "echo 'gh: could not connect' >&2", "exit 1"] $ do
        unverified <- preconditionStillHolds launched
        case unverified of
          Nothing -> expectationFailure "an unreadable target was allowed to start its turn"
          Just detail -> do
            workerPreconditionRefusal detail `shouldBe` Just workerUnverifiedTargetReason
            Text.unpack detail `shouldSatisfy` isInfixOf "could not connect"

  -- The two refusals stay apart because they call for different repairs: a
  -- moved target is replanned against a new reading, an unreadable one is
  -- waited on.
  it "tells the two refusals apart, and both from an ordinary failure" $ do
    workerPreconditionRefusal (workerStaleTargetReason <> ": #844 changed")
      `shouldBe` Just workerStaleTargetReason
    workerPreconditionRefusal (workerUnverifiedTargetReason <> ": gh failed")
      `shouldBe` Just workerUnverifiedTargetReason
    workerPreconditionRefusal "the provider exited 1" `shouldBe` Nothing
    -- And the stale one types all the way through to a replannable step.
    (missionStepFailureTag <$> missionFailureFromOutcome (settledWorkerFailure (workerStaleTargetReason <> ": #844 changed")))
      `shouldBe` Just "stale_version"

-- | A temporary root with @$XDG_CACHE_HOME@ redirected into it.
--
-- Running @gh@ at all writes this repository's durable process-group record
-- under the cache root, and a record left in the real one is read by every
-- later board refresh as a previous board's leftover — which is a failure in
-- another group entirely, arriving long after the example that caused it.
withIsolatedGh :: (FilePath -> IO result) -> IO result
withIsolatedGh action = withTemporaryCacheRoot $ \root ->
  withEnvironmentValue "XDG_CACHE_HOME" (root </> "cache") (action root)

-- | A fake @gh issue view --json@ answering with these labels.
--
-- The state and instant match 'issueVersion', so the only fact that can differ
-- is the one an example varies.
ghItem :: [Text] -> [ByteString.ByteString]
ghItem = ghItemIn "OPEN"

-- | The same, in a lifecycle state an example chooses.
--
-- @gh@ spells these @OPEN@, @CLOSED@, and @MERGED@; the read under test is
-- what lowercases them, so the fixture must not do it here.
ghItemIn :: String -> [Text] -> [ByteString.ByteString]
ghItemIn state labels =
  [ "#!/bin/sh",
    ByteString.pack
      ( "printf '%s' '"
          <> "{\"number\":844,\"updatedAt\":\""
          <> iso8601
          <> "\",\"state\":\""
          <> state
          <> "\",\"labels\":["
          <> intercalate "," ["{\"name\":\"" <> Text.unpack name <> "\"}" | name <- labels]
          <> "]}'"
      )
  ]
  where
    iso8601 = formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" fixedTime

-- ---------------------------------------------------------------------------
-- The failure vocabulary
-- ---------------------------------------------------------------------------

failureVocabularySpec :: Spec
failureVocabularySpec = describe "the typed results a step can reach" $ do
  it "keeps all eight distinguishable" $ do
    let tags = map missionStepFailureTag missionStepFailures
    tags
      `shouldBe` [ "deadline",
                   "authentication",
                   "configuration",
                   "executable",
                   "capacity",
                   "stale_version",
                   "outcome_unknown",
                   "failed"
                 ]
    length tags `shouldBe` length (foldr (\tag seen -> if tag `elem` seen then seen else tag : seen) [] tags)

  -- Requirement 16: the deadline is its own result, reached from the very
  -- sentence the watchdog writes, and never mistaken for a generic failure.
  it "reads a deadline out of a settled worker and nothing else out of it" $ do
    settledWorkerFailure workerDeadlineReason `shouldBe` ActionDeadlineExceeded workerDeadlineReason
    settledWorkerFailure "the provider exited 1" `shouldBe` ActionFailed "the provider exited 1"
    (missionStepFailureTag <$> missionFailureFromOutcome (settledWorkerFailure workerDeadlineReason))
      `shouldBe` Just "deadline"
    (missionStepFailureTag <$> missionFailureFromOutcome (settledWorkerFailure "the provider exited 1"))
      `shouldBe` Just "failed"
    (missionStepFailureTag <$> missionFailureFromOutcome (ActionStopped "no evidence"))
      `shouldBe` Just "outcome_unknown"
    missionFailureFromOutcome (ActionPullRequestOpened 900) `shouldBe` Nothing

  it "reads authentication, executable, and capacity out of the provider layer" $ do
    let failureFor kind = missionStepFailureTag (missionFailureFromProviderError (ProviderError kind "detail"))
    failureFor AuthenticationRequired `shouldBe` "authentication"
    failureFor ExecutableMissing `shouldBe` "executable"
    failureFor RateLimited `shouldBe` "capacity"
    failureFor RequestFailed `shouldBe` "failed"

  it "reads configuration and executable out of a registry refusal" $ do
    missionStepFailureTag (missionFailureFromRefusal (ActionRoutingUnavailable SolveIssue "no cell")) `shouldBe` "configuration"
    missionStepFailureTag (missionFailureFromRefusal (ActionCapabilityBlocked SolveIssue "gh is not installed")) `shouldBe` "executable"
    missionStepFailureTag (missionFailureFromRefusal (ActionDispatchFailed SolveIssue "the supervisor failed")) `shouldBe` "failed"

  it "lands an unknown outcome in its own step lifecycle, not in failed" $ do
    missionStepFailureLifecycle (MissionFailureOutcomeUnknown "") `shouldBe` MissionStepOutcomeUnknown
    missionStepFailureLifecycle (MissionFailureDeadline "") `shouldBe` MissionStepFailed
    missionStepFailureLifecycle (MissionFailureGeneric "") `shouldBe` MissionStepFailed

  -- Requirement 8's typed result must survive the trip through the registry's
  -- refusal vocabulary. Falling through to the generic arm would have made a
  -- race that mutated nothing look like work that failed.
  it "keeps a stale refusal typed, and returns the step to a replannable state" $ do
    let recorded = preconditionOf (issueVersion ["reviewed:approve"])
        observed = preconditionOf (issueVersion ["reviewed:approve", "blocked"])
        failure = missionFailureFromRefusal (ActionTargetStale SolveIssue recorded observed)
    missionStepFailureTag failure `shouldBe` "stale_version"
    missionStepFailureLifecycle failure `shouldBe` MissionStepPending
    Text.unpack (missionStepFailureMessage failure) `shouldSatisfy` isInfixOf "nothing was dispatched"
    -- And the other failures still land where they did.
    missionStepFailureLifecycle (MissionFailureGeneric "") `shouldBe` MissionStepFailed
    missionStepFailureLifecycle (MissionFailureOutcomeUnknown "") `shouldBe` MissionStepOutcomeUnknown

  it "refuses a dispatch the owning authority declined, without concluding the mission" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      writeIORef stage.stageDispatchResult (const (Left (MissionFailureExecutable "gh is not installed")))
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepBlocked step failure) -> do
          step `shouldBe` theStep
          missionStepFailureTag failure `shouldBe` "executable"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      recorded <- currentInvocations store
      map (fmap missionInvocationOutcomeTag . (.missionInvocationOutcome)) recorded `shouldBe` [Just "refused"]

-- ---------------------------------------------------------------------------
-- The effects that have no step record
-- ---------------------------------------------------------------------------

-- | The two external effects a plan step's recovery cannot speak for.
--
-- A registered child's step is invented from the request and appears in no
-- plan, and nothing writes a step record for it; a subtree termination has no
-- step at all. Both are journaled before they happen like every other effect,
-- so both leave a crash window — the child's around its launch, the
-- termination's after its signal — and neither can be resolved by writing an
-- unknown outcome onto a step record that does not exist.
openEffectRecoverySpec :: Spec
openEffectRecoverySpec = describe "an open effect with no step record" $ do
  -- The window between the driver returning and the snapshot write. For a
  -- child that write is the only record of its existence, so without the
  -- lineage on the invocation the launched child would be a session under no
  -- parent, reached by no termination and waited for by nobody.
  it "puts a launched child back under its parent after a crash before the write" $
    withRegisteredParent $ \store stage -> do
      openChildInvocation store "r-20"
      concludeInvocation store (childInvocationFor "r-20") (MissionInvocationDispatched "child-r-20-0001")
      iteration <- oneIteration store stage
      iteration
        `shouldBe` MissionAdvanced
          (MissionStepAttached (childStepId theParent "r-20") (MissionSessionId "child-r-20-0001"))
      readIORef stage.stageDispatches `shouldReturn` []
      snapshot <- currentSnapshot store
      [ (node.missionSessionId, node.missionSessionParent)
        | node <- snapshot.missionSnapshotSessions,
          node.missionSessionParent /= Nothing
        ]
        `shouldBe` [(MissionSessionId "child-r-20-0001", Just theParent)]

  -- The narrower window: the record was flushed, the launch may or may not
  -- have happened, and the worker itself is the evidence. It carries the
  -- invocation identity, so the mission adopts its own child rather than
  -- treating it as work somebody else started.
  it "adopts the child an open invocation launched, and registers its lineage" $
    withRegisteredParent $ \store stage -> do
      openChildInvocation store "r-21"
      writeIORef stage.stageAdoptions [(childInvocationFor "r-21", MissionSessionId "child-r-21-0001")]
      iteration <- oneIteration store stage
      iteration
        `shouldBe` MissionAdvanced
          (MissionStepAttached (childStepId theParent "r-21") (MissionSessionId "child-r-21-0001"))
      readIORef stage.stageDispatches `shouldReturn` []
      snapshot <- currentSnapshot store
      [ (node.missionSessionId, node.missionSessionParent)
        | node <- snapshot.missionSnapshotSessions,
          node.missionSessionParent /= Nothing
        ]
        `shouldBe` [(MissionSessionId "child-r-21-0001", Just theParent)]
      outcomeTags store `shouldReturn` [Just "dispatched"]

  -- And when no worker names it, the answer is the one requirement 7 allows:
  -- stop for direction. Closing the record is what keeps the next iteration
  -- from asking the same question of the same absent evidence for ever, and it
  -- licenses nothing — the child is never launched a second time.
  it "halts for direction when nothing records the child an open invocation may have launched" $
    withRegisteredParent $ \store stage -> do
      openChildInvocation store "r-22"
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionLifecycleSet MissionWaitingInput detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "no worker records it"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []
      outcomeTags store `shouldReturn` [Just "outcome_unknown"]
      snapshot <- currentSnapshot store
      snapshot.missionSnapshotLifecycle `shouldBe` MissionWaitingInput
      -- A second run reads the halt rather than reopening the question.
      second <- oneIteration store stage
      second `shouldBe` MissionStopped (MissionHaltIndeterminate MissionWaitingInput "it is waiting for an answer this runner cannot supply")
      readIORef stage.stageDispatches `shouldReturn` []

  it "classifies a child's open launch purely, and never a plan step's as one" $ do
    let snapshot =
          snapshotWith
            MissionRunning
            [stepRecord MissionStepRunning [theParent]]
            [sessionNode "solve-844-0001" Nothing Nothing]
        childState =
          MissionInvocationState
            { missionInvocationRecord =
                MissionInvocation
                  { missionInvocationId = childInvocationFor "r-23",
                    missionInvocationMission = theMission,
                    missionInvocationRepository = MissionRepository "coghex" "kanban",
                    missionInvocationStep = childStepId theParent "r-23",
                    missionInvocationAction = "review_pull_request",
                    missionInvocationTarget = Nothing,
                    missionInvocationVersion = Nothing,
                    missionInvocationEffect = MissionEffectDispatch "review_pull_request",
                    missionInvocationParent = Just theParent.unMissionSessionId,
                    missionInvocationAt = fixedTime
                  },
              missionInvocationOutcome = Nothing
            }
    case unresolvedDispatchOf [childState] theSpecification snapshot of
      Nothing -> expectationFailure "a child's open launch was not recognized"
      Just dispatch -> do
        dispatch.missionOpenDispatchStep `shouldBe` childStepId theParent "r-23"
        dispatch.missionOpenDispatchParent `shouldBe` Just theParent
        missionOpenDispatchIsChild snapshot dispatch `shouldBe` True
    -- The plan step's own window still reads as a plan step's, so the two
    -- resolutions never trade places.
    let planSnapshot = snapshotWith MissionRunning [stepRecord MissionStepPending []] []
    case unresolvedDispatchOf [openInvocationState] theSpecification planSnapshot of
      Nothing -> expectationFailure "the plan step's open launch was not recognized"
      Just dispatch -> do
        dispatch.missionOpenDispatchParent `shouldBe` Nothing
        missionOpenDispatchIsChild planSnapshot dispatch `shouldBe` False
    -- And a child whose session is already in the tree is not an open launch
    -- at all, whatever its record says.
    dispatchedButUnregistered
      [childState {missionInvocationOutcome = Just (MissionInvocationDispatched "child-r-23-0001")}]
      snapshot
      `shouldBe` Just (childStepId theParent "r-23", MissionSessionId "child-r-23-0001", Just theParent)

  -- The termination's own crash window, and the dangerous one: the signal may
  -- already have been delivered, so the one answer never available is "do it
  -- again". Nothing in the record says whether it was, so the sessions
  -- themselves are asked.
  it "closes an open termination the registered sessions can be shown to have ended" $ do
    -- Already observed to have ended, so the ordinary session pass has nothing
    -- of its own to record and the open termination is what this iteration
    -- meets.
    let sessions =
          [ sessionNode "solve-844-0001" Nothing settledObservation,
            sessionNode "child-1" (Just theParent) settledObservation
          ]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] sessions) $ \store stage -> do
      openTerminationInvocation store "c-end"
      writeIORef stage.stageSessions [theParent, MissionSessionId "child-1"]
      iteration <- oneIteration store stage
      iteration `shouldBe` MissionAdvanced (MissionSubtreeTerminated theParent 2)
      outcomeTags store `shouldReturn` [Just "completed"]
      readIORef stage.stageTerminated `shouldReturn` []

  it "halts for direction on an open termination the sessions cannot settle" $ do
    let sessions = [sessionNode "solve-844-0001" Nothing Nothing, liveChild "child-1" theParent]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] sessions) $ \store stage -> do
      -- Looked at, and unanswerable — which is a different thing from not
      -- having finished yet, and the only one that stops the mission.
      writeIORef stage.stageSessions [theParent, MissionSessionId "child-1"]
      writeIORef
        stage.stageObservation
        MissionTerminalObservation
          { missionObservationAt = fixedTime,
            missionObservationOutcome = MissionObservedUnknown,
            missionObservationDetail = Just "its worker record has been collected"
          }
      openTerminationInvocation store "c-end"
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      iteration <- case started of
        Left refusal -> fail ("the controller refused to start: " <> Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          reached <- iterateUntil controller isWaitingInput
          stopMissionController controller
          pure reached
      case iteration of
        MissionAdvanced (MissionLifecycleSet MissionWaitingInput detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "whether the signal was delivered is unknown"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      outcomeTags store `shouldReturn` [Just "outcome_unknown"]
      -- The signal is never repeated, on this pass or the next.
      readIORef stage.stageTerminated `shouldReturn` []
      second <- oneIteration store stage
      second `shouldBe` MissionStopped (MissionHaltIndeterminate MissionWaitingInput "it is waiting for an answer this runner cannot supply")
      readIORef stage.stageTerminated `shouldReturn` []

  -- An effect closed as unknown is the mission's one indeterminate record, and
  -- the two effects that carry it have no step to write it on. A run that read
  -- only the steps would exit zero over exactly the launches nobody can
  -- account for.
  it "reports a run that closed a child as unknown as a failure, not a blocked stop" $
    withRegisteredParent $ \store stage -> do
      openChildInvocation store "r-60"
      report <- runMissionWith Nothing store boardRepository theMission (stagedDriver stage)
      case report of
        Left detail -> expectationFailure (Text.unpack detail)
        Right run -> do
          run.missionRunConclusion
            `shouldSatisfy` either (const False) missionHaltIsIndeterminate
          missionRunSucceeded run `shouldBe` False
      outcomeTags store `shouldReturn` [Just "outcome_unknown"]

  -- And the operator can resolve it, which is the other half: a record closed
  -- as unknown that no direction could reach would hold the mission for good.
  it "lets an authenticated override release a launch closed as unknown" $
    withRegisteredParent $ \store stage -> do
      openChildInvocation store "r-61"
      _ <- oneIteration store stage
      outcomeTags store `shouldReturn` [Just "outcome_unknown"]
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          submitConsoleCommand
            controller
            "c-resolve"
            (MissionUserOverrideCommand (childStepId theParent "r-61") "it never ran")
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionCommandApplied "c-resolve" _) -> pure ()
            other -> expectationFailure ("unexpected iteration: " <> show other)
          stopMissionController controller
      -- The file keeps both lines; the later one is the one that stands.
      outcomeTags store `shouldReturn` [Just "abandoned"]

  -- A termination that could not reach every registered session is not a
  -- termination. Claiming one would put in the durable record, as fact, that a
  -- descendant was ended when nothing signalled it.
  it "does not close a termination that never reached the whole subtree" $ do
    let root = MissionSessionId "solve-844-0001"
        sessions = [sessionNode "solve-844-0001" Nothing Nothing, liveChild "child-1" root]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [root]] sessions) $ \store stage -> do
      writeIORef stage.stageUnreached [MissionSessionId "child-1"]
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          submitConsoleCommand controller "c-end" (MissionTerminateSubtreeCommand root "operator asked")
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionCommandApplied "c-end" detail) ->
              Text.unpack detail `shouldSatisfy` isInfixOf "its end is not yet established"
            MissionAdvanced (MissionSubtreeTerminated _ _) ->
              expectationFailure "a partial termination was reported as a whole one"
            other -> expectationFailure ("unexpected iteration: " <> show other)
          stopMissionController controller
      -- The record stays open, so the next pass reconciles it from the
      -- sessions rather than believing this one.
      outcomeTags store `shouldReturn` [Nothing]

  -- The live half: a session whose worker record cannot be found was not
  -- signalled by this call, and saying so is the only thing that keeps the
  -- controller from recording a termination that did not happen.
  it "reports the registered sessions a real termination could not signal" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] []) $ \store _ -> do
      driver <- liveMissionDriver testOptions testResolvedConfig boardRepository store theMission
      stageWorker (workerFixtureSpec boardRepository (WorkerId "solve-844-0001") 844)
      terminated <-
        driver.missionDriverTerminate [theParent, MissionSessionId "child-collected-0001"]
      terminated `shouldBe` Right [MissionSessionId "child-collected-0001"]

  -- The case the whole three-way answer exists for. `terminateWorker` asks a
  -- worker to stop and returns: an ordinary one may be pending termination for
  -- a while yet, and an issue action's child is a queued command its host has
  -- still to act on. A session that was reached and has not ended is work in
  -- progress, so the run waits for it — and must not report the subtree ended,
  -- nor halt the mission for a shutdown that is proceeding normally.
  it "waits on a signalled session that has not finished ending" $ do
    let sessions = [sessionNode "solve-844-0001" Nothing Nothing, liveChild "child-1" theParent]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] sessions) $ \store stage -> do
      openTerminationInvocation store "c-end"
      -- Nothing has ended yet: every observation comes back "not terminal".
      writeIORef stage.stageSessions []
      iteration <- oneIteration store stage
      case iteration of
        MissionAwaiting detail ->
          Text.unpack detail `shouldSatisfy` isInfixOf "has not finished ending"
        other -> expectationFailure ("a shutdown in progress was not waited on: " <> show other)
      -- The record stays open, so nothing has been claimed about it either
      -- way, and the mission has not been stopped.
      outcomeTags store `shouldReturn` [Nothing]
      snapshot <- currentSnapshot store
      snapshot.missionSnapshotLifecycle `shouldBe` MissionRunning

  it "recognizes an open termination and nothing else as one" $ do
    let terminationState effect outcome =
          MissionInvocationState
            { missionInvocationRecord =
                MissionInvocation
                  { missionInvocationId = MissionInvocationId "terminate-c-end",
                    missionInvocationMission = theMission,
                    missionInvocationRepository = MissionRepository "coghex" "kanban",
                    missionInvocationStep = MissionStepId "-",
                    missionInvocationAction = "terminate_subtree",
                    missionInvocationTarget = Nothing,
                    missionInvocationVersion = Nothing,
                    missionInvocationEffect = effect,
                    missionInvocationParent = Nothing,
                    missionInvocationAt = fixedTime
                  },
              missionInvocationOutcome = outcome
            }
        open = terminationState (MissionEffectTerminateSubtree "solve-844-0001") Nothing
        closed = terminationState (MissionEffectTerminateSubtree "solve-844-0001") (Just (MissionInvocationCompleted "done"))
    unresolvedTerminationOf [open] `shouldBe` Just (MissionInvocationId "terminate-c-end", theParent)
    unresolvedTerminationOf [closed] `shouldBe` Nothing
    unresolvedTerminationOf [openInvocationState] `shouldBe` Nothing

  -- A worker's terminal artifacts are collectable after their retention
  -- whatever the worker did, so the record of a child that failed, stopped to
  -- ask, or was never observed is gone by exactly the route a completed one's
  -- is. Reading the absence as a clean exit would hand a parent the one thing
  -- it waits for on no evidence at all.
  it "reads a collected worker record as unknown rather than as a clean exit" $
    withRegisteredParent $ \store _ -> do
      driver <- liveMissionDriver testOptions testResolvedConfig boardRepository store theMission
      observed <- driver.missionDriverObserveSession (MissionSessionId "child-collected-0001") Nothing
      case observed of
        Right (Just observation) -> do
          observation.missionObservationOutcome `shouldBe` MissionObservedUnknown
          missionSessionDisposition (sessionNode "child-collected-0001" (Just theParent) (Just observation))
            `shouldBe` MissionSessionUnverifiable
        other -> expectationFailure ("unexpected observation: " <> show (fmap (fmap (.missionObservationOutcome)) other))

  it "keeps a parent nonterminal over a child whose record was collected" $ do
    let collected =
          MissionTerminalObservation
            { missionObservationAt = fixedTime,
              missionObservationOutcome = MissionObservedUnknown,
              missionObservationDetail = Just "its worker record has been collected; how it ended is unrecorded"
            }
        sessions =
          [ sessionNode "solve-844-0001" Nothing settledObservation,
            sessionNode "child-1" (Just theParent) (Just collected)
          ]
        snapshot = snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] sessions
    stepHasUnsettledDescendants snapshot theStep `shouldBe` True
    -- And the same parent over a child that was observed to end may settle.
    let ended = sessions >>= \node ->
          [ if node.missionSessionId == MissionSessionId "child-1"
              then node {missionSessionObservation = settledObservation}
              else node
          ]
    stepHasUnsettledDescendants (snapshot {missionSnapshotSessions = ended}) theStep `shouldBe` False

  -- A step's session list accumulates, so a replanned step carries its
  -- abandoned attempt and its replacement. Answering from the first reading
  -- available would let the terminal old worker conclude a step whose
  -- replacement is still running, and the reconciliation that followed would
  -- launch a third beside it.
  it "answers a replanned step from its live session, not its oldest one" $ do
    let old =
          MissionWorkerReading
            { missionWorkerSession = MissionSessionId "solve-844-0001",
              missionWorkerLive = False,
              missionWorkerCompatible = True,
              missionWorkerTerminal = Just (MissionWorkerSucceeded "the registered worker completed"),
              missionWorkerProviderSession = Just "provider-1"
            }
        replacement =
          MissionWorkerReading
            { missionWorkerSession = MissionSessionId "solve-844-0002",
              missionWorkerLive = True,
              missionWorkerCompatible = True,
              missionWorkerTerminal = Nothing,
              missionWorkerProviderSession = Just "provider-2"
            }
        opaque = replacement {missionWorkerSession = MissionSessionId "solve-844-0003", missionWorkerCompatible = False}
    decidingWorkerReading [old, replacement] `shouldBe` Just replacement
    -- A compatible live session outranks an opaque one whichever order they
    -- were registered in.
    decidingWorkerReading [opaque, replacement] `shouldBe` Just replacement
    decidingWorkerReading [replacement, opaque] `shouldBe` Just replacement
    -- With nothing live, the most recent terminal attempt answers.
    decidingWorkerReading [old, old {missionWorkerSession = MissionSessionId "solve-844-0004"}]
      `shouldBe` Just (old {missionWorkerSession = MissionSessionId "solve-844-0004"})
    decidingWorkerReading [] `shouldBe` Nothing

  -- The other half of the worker's fail-closed precondition. A turn refused
  -- because the target could not be read at all mutated nothing and learned
  -- nothing, and the documented repair is to wait for a reading — so it must
  -- not reach the mission as a permanently failed step.
  it "reconciles an unreadable-target refusal to an unknown outcome, not a failure" $ do
    let refusal = workerUnverifiedTargetReason <> ": gh: could not connect"
    settledWorkerFailure refusal `shouldBe` ActionStopped refusal
    (missionStepFailureTag <$> missionFailureFromOutcome (settledWorkerFailure refusal))
      `shouldBe` Just "outcome_unknown"
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] []) $ \store stage -> do
      writeIORef stage.stageEvidence $ \evidence ->
        evidence
          { missionEvidenceWorker =
              Just
                MissionWorkerReading
                  { missionWorkerSession = theParent,
                    missionWorkerLive = False,
                    missionWorkerCompatible = True,
                    -- Exactly the conclusion the live driver derives from a
                    -- worker that settled with this sentence.
                    missionWorkerTerminal =
                      Just
                        ( MissionWorkerFailed
                            ( maybe
                                (MissionFailureGeneric refusal)
                                id
                                (missionFailureFromOutcome (settledWorkerFailure refusal))
                            )
                        ),
                    missionWorkerProviderSession = Nothing
                  }
          }
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled step MissionStepOutcomeUnknown detail) -> do
          step `shouldBe` theStep
          Text.unpack detail `shouldSatisfy` isInfixOf "could not be reread"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      readIORef stage.stageDispatches `shouldReturn` []

-- ---------------------------------------------------------------------------
-- Direction
-- ---------------------------------------------------------------------------

-- | The half of requirement 14 a run has to stay alive for.
--
-- An unknown outcome is resolvable by authenticated direction and by nothing
-- else, and the only authenticated channel is this run's own terminal. A run
-- that wrote @waiting_input@ and exited on the next pass therefore closed the
-- one door out of the state it had just entered: the operator learned of it
-- from a report printed after the process was gone, and a later run exited for
-- the same reason before they could answer.
directionSpec :: Spec
directionSpec = describe "directing a run that has blocked" $ do
  it "asks the operator what to do, and acts on the answer" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      -- A launch this store never saw the end of, which is what drives the
      -- mission into waiting_input a couple of passes from now.
      openInvocation store
      (readEnd, writeEnd) <- createPipe
      hSetBuffering writeEnd LineBuffering
      asked <- newEmptyMVar
      said <- newIORef []
      finished <- newEmptyMVar
      let console =
            MissionConsole
              { missionConsoleInput = readEnd,
                missionConsoleIsTerminal = pure True,
                missionConsoleAnnounce = \spoken -> do
                  atomicModifyIORef' said (\seen -> (seen <> [spoken], ()))
                  putMVar asked spoken
              }
      _ <-
        forkIO
          ( runMissionWith (Just console) store boardRepository theMission (stagedDriver stage)
              >>= putMVar finished
          )
      -- It says what it is stuck on before it waits, which is the whole point:
      -- an operator cannot answer a question nobody asked.
      firstAsk <- awaitConsole asked
      Text.unpack firstAsk `shouldSatisfy` isInfixOf "waiting for an answer"
      Text.unpack firstAsk `shouldSatisfy` isInfixOf "detach"
      TextIO.hPutStrLn writeEnd "override solve-844 it never ran"
      -- The override resolves the step; the mission is still blocked, so it
      -- asks again rather than assuming that was the whole answer.
      _ <- awaitConsole asked
      TextIO.hPutStrLn writeEnd "resume"
      -- Resumed, the freed step is dispatchable again — which is only true
      -- because the override reached the invocation file as well as the step
      -- record.
      _ <- awaitConsole asked
      hClose writeEnd
      report <- awaitConsole finished
      case report of
        Left detail -> expectationFailure (Text.unpack detail)
        Right run -> do
          run.missionRunConclusion
            `shouldBe` Right (MissionHaltIndeterminate MissionWaitingInput "it is waiting for an answer this runner cannot supply")
          map missionTransitionMessage run.missionRunTransitions
            `shouldSatisfy` any (isInfixOf "user override on solve-844" . Text.unpack)
          -- And the run says so: a mission stopped on a step nothing could
          -- establish the outcome of is never reported as a success (§16).
          missionRunSucceeded run `shouldBe` False
      length <$> readIORef stage.stageDispatches `shouldReturn` 1
      length <$> readIORef said `shouldReturn` 3

  -- End of input is an answer, and so is saying so. Neither may be mistaken
  -- for a line to parse.
  it "ends the run on a closed console, and on the word for it" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      openInvocation store
      forM_ ["", "detach\n", "QUIT\n"] $ \typed -> do
        said <- newIORef []
        report <- withConsole typed $ \handle ->
          runMissionWith (Just (spokenConsole handle said)) store boardRepository theMission (stagedDriver stage)
        case report of
          Left detail -> expectationFailure (Text.unpack detail)
          Right run ->
            run.missionRunConclusion
              `shouldBe` Right (MissionHaltIndeterminate MissionWaitingInput "it is waiting for an answer this runner cannot supply")
        readIORef stage.stageDispatches `shouldReturn` []

  -- The exclusion that makes the prompt authority rather than a formality. A
  -- handle that is not this process's terminal is another process's output,
  -- and a run reading direction off it would be taking orders from whatever
  -- wrote the pipe.
  it "never prompts a handle that is not this process's terminal" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      openInvocation store
      said <- newIORef []
      report <- withConsole "override solve-844 let me in\n" $ \handle ->
        runMissionWith
          (Just ((spokenConsole handle said) {missionConsoleIsTerminal = pure False}))
          store
          boardRepository
          theMission
          (stagedDriver stage)
      case report of
        Left detail -> expectationFailure (Text.unpack detail)
        Right run ->
          run.missionRunConclusion
            `shouldBe` Right (MissionHaltIndeterminate MissionWaitingInput "it is waiting for an answer this runner cannot supply")
      readIORef said `shouldReturn` []
      readIORef stage.stageDispatches `shouldReturn` []

  -- A terminal mission is over, and no console makes it otherwise.
  it "does not prompt on a mission that has finished" $
    withMission (snapshotWith MissionCompleted [stepRecord MissionStepSucceeded []] []) $ \store stage -> do
      said <- newIORef []
      report <- withConsole "resume\n" $ \handle ->
        runMissionWith (Just (spokenConsole handle said)) store boardRepository theMission (stagedDriver stage)
      case report of
        Left detail -> expectationFailure (Text.unpack detail)
        Right run -> run.missionRunConclusion `shouldBe` Right (MissionHaltTerminal MissionCompleted)
      readIORef said `shouldReturn` []

  it "releases the step's open launch on the operator's word, and only then" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepOutcomeUnknown []] []) $ \store stage -> do
      openInvocation store
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          -- A pause is direction too, and it resolves nothing: only the
          -- override says the effect never happened.
          submitConsoleCommand controller "c-pause" (MissionPauseCommand "not yet")
          _ <- missionControllerIteration controller
          outcomeTags store `shouldReturn` [Nothing]
          submitConsoleCommand controller "c-free" (MissionUserOverrideCommand theStep "it never ran")
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionCommandApplied "c-free" _) -> pure ()
            other -> expectationFailure ("unexpected iteration: " <> show other)
          stopMissionController controller
      outcomeTags store `shouldReturn` [Just "abandoned"]
      snapshot <- currentSnapshot store
      stepLifecycle snapshot `shouldBe` Just MissionStepPending

  -- A child line that names no target resolves to the whole repository, which
  -- every item-scoped action refuses; so the grammar has to be able to say
  -- which item, and the item has to survive all the way to the dispatch.
  it "carries the item a console child line named through to the dispatch" $
    withLiveParent $ \_ stage controller -> do
      case parseMissionConsoleCommand theMission "child r-30 solve-844-0001 review_pull_request pr#900" of
        Left detail -> expectationFailure (Text.unpack detail)
        Right payload -> submitConsoleCommand controller "c-target" payload
      iteration <- missionControllerIteration controller
      case iteration of
        MissionAdvanced (MissionCommandApplied "c-target" detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "registered child"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      dispatched <- readIORef stage.stageDispatches
      map (fmap targetPair . (.missionDispatchTarget)) dispatched
        `shouldBe` [Just (MissionTargetPullRequest, 900)]

  it "parses the item a child line names, and refuses a spelling it cannot" $ do
    targetOf "child r-1 solve-844-0001 review_issue issue#844"
      `shouldBe` Right (Just (MissionTargetIssue, 844))
    targetOf "child r-1 solve-844-0001 review_pull_request PR#900"
      `shouldBe` Right (Just (MissionTargetPullRequest, 900))
    -- No target is still a request: an action that works on the repository
    -- rather than on one item takes none.
    targetOf "child r-1 solve-844-0001 report_approval_queue" `shouldBe` Right Nothing
    parseConsoleTarget "issue#844" `shouldBe` Right (MissionTarget MissionTargetIssue 844 Nothing)
    mapM_
      (\spelled -> parseConsoleTarget spelled `shouldSatisfy` either (isInfixOf "issue#<number>" . Text.unpack) (const False))
      ["900", "pr#0", "pr#nine", "branch#900", "pr#", "#900", "pr#900#2"]

  -- Requirement 8's reread has to be able to see a target that reached a
  -- terminal state, which is the most ordinary reason a plan is out of date. A
  -- read that only covers open work reports the commonest staleness there is
  -- as a target it could not resolve.
  it "reads a target that closed since the plan as a fact, not as an absence" $
    withIsolatedGh $ \root ->
      withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store _ -> do
        driver <- liveMissionDriver testOptions testResolvedConfig boardRepository store theMission
        withFakeGh root (ghItemIn "CLOSED" ["reviewed:approve"]) $ do
          observed <- driver.missionDriverObserveTarget theTarget
          case observed of
            Left detail -> expectationFailure ("a closed target could not be read: " <> Text.unpack detail)
            Right version -> do
              version.missionVersionState `shouldBe` "closed"
              version.missionVersionNumber `shouldBe` 844
              -- And that is what makes it a stale plan rather than a failure.
              missionVersionHolds (issueVersion ["reviewed:approve"]) version `shouldBe` False
        withFakeGh root (ghItemIn "OPEN" ["reviewed:approve"]) $ do
          unchanged <- driver.missionDriverObserveTarget theTarget
          fmap (missionVersionHolds (issueVersion ["reviewed:approve"])) unchanged `shouldBe` Right True

  -- A launch registers its session before the provider has named its own, so
  -- the identity a resume needs only appears in the worker's durable state
  -- afterwards. Without learning it, every continuation briefs a fresh session
  -- over a conversation that was there to be continued.
  it "learns a fresh launch's provider session, and resumes it on the next turn" $ do
    let unnamed = (sessionNode "solve-844-0001" Nothing Nothing) {missionSessionProviderSessionId = Nothing}
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] [unnamed]) $ \store stage -> do
      writeIORef stage.stageEvidence $ \evidence ->
        evidence
          { missionEvidenceWorker =
              Just
                MissionWorkerReading
                  { missionWorkerSession = theParent,
                    missionWorkerLive = False,
                    missionWorkerCompatible = True,
                    missionWorkerTerminal = Just (MissionWorkerFailed (MissionFailureStaleVersion "#844 changed")),
                    missionWorkerProviderSession = Just "provider-live"
                  }
          }
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          first <- missionControllerIteration controller
          case first of
            MissionAdvanced (MissionStepReconciled _ MissionStepPending _) -> pure ()
            other -> expectationFailure ("unexpected iteration: " <> show other)
          learned <- currentSnapshot store
          map (.missionSessionProviderSessionId) learned.missionSnapshotSessions
            `shouldBe` [Just "provider-live"]
          -- The turn after it: the dispatch continues that session rather than
          -- briefing a new one.
          writeIORef stage.stageEvidence id
          _ <- missionControllerIteration controller
          dispatched <- readIORef stage.stageDispatches
          map (.missionDispatchContinuation) dispatched
            `shouldBe` [MissionResumeSession "provider-live"]
          stopMissionController controller

-- | A console over a handle, collecting whatever the run says.
spokenConsole :: Handle -> IORef [Text] -> MissionConsole
spokenConsole handle said =
  MissionConsole
    { missionConsoleInput = handle,
      missionConsoleIsTerminal = pure True,
      missionConsoleAnnounce = \spoken -> atomicModifyIORef' said (\seen -> (seen <> [spoken], ()))
    }

-- | Waits for the run to say something, rather than for a wall clock.
--
-- The bound is a deadlock guard and nothing else: every wait here is answered
-- by the run itself, so a timeout means the handshake broke, not that the
-- machine was slow.
awaitConsole :: MVar result -> IO result
awaitConsole slot = do
  taken <- timeout (30 * 1000 * 1000) (takeMVar slot)
  case taken of
    Just result -> pure result
    Nothing -> fail "the run neither asked for direction nor finished"

targetPair :: MissionTarget -> (MissionTargetKind, Int)
targetPair target = (target.missionTargetKind, target.missionTargetNumber)

targetOf :: Text -> Either Text (Maybe (MissionTargetKind, Int))
targetOf line = case parseMissionConsoleCommand theMission line of
  Left detail -> Left detail
  Right (MissionChildRequestCommand request) -> Right (targetPair <$> request.missionChildRequestTarget)
  Right other -> Left ("not a child request: " <> Text.pack (show other))

-- ---------------------------------------------------------------------------
-- Whose judgement a result is
-- ---------------------------------------------------------------------------

-- | The registry decides what a finished worker achieved, not this module.
--
-- A clean exit says only that the process ended. Whether a solve produced an
-- attributable pull request, and whether an issue action published a verdict
-- at all, are questions with action-specific answers that
-- @validateWorkerOutcome@ and @observeIssueActionHandle@ already decide — so a
-- mission that read the worker state itself and called @SolveCompleted@ a
-- success would report a solve that opened nothing, and a canonical review
-- that published nothing, as work done.
registryJudgementSpec :: Spec
registryJudgementSpec = describe "who judges a finished worker" $ do
  it "rebuilds a provider turn's handle from what its own record wrote down" $ do
    descriptor <- descriptorForSpec (attributedSpec (WorkerId "solve-844-0001"))
    case observableActionHandle SolveIssue resolvedIssue descriptor of
      Just (WorkerActionHandle kind _ held attribution) -> do
        kind `shouldBe` SolveIssue
        held.workerDescriptorSpec.workerId `shouldBe` WorkerId "solve-844-0001"
        -- The baseline is the one that run began from, never this caller's.
        attributionKnownPullRequests attribution `shouldBe` Set.fromList [900, 901]
        attributionSolverBrand attribution `shouldBe` ClaudeSolver
      other -> expectationFailure ("unexpected handle: " <> show (fmap actionHandleKind other))

  -- The absence is the fail-closed half. A run whose record cannot say what
  -- baseline it began from is one no other caller may speak for: judging it
  -- against a baseline taken now would credit it with a pull request somebody
  -- else opened, or refuse it the one it opened itself.
  it "refuses to rebuild a handle the worker's record cannot supply" $ do
    unattributed <- descriptorForSpec (workerFixtureSpec boardRepository (WorkerId "solve-844-0002") 844)
    (actionHandleKind <$> observableActionHandle SolveIssue resolvedIssue unattributed)
      `shouldBe` Nothing
    -- And the repository's review host owns no action of its own.
    host <-
      descriptorForSpec
        ( (workerFixtureSpec boardRepository (WorkerId "issue-host-0001") 844)
            {workerTask = IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")}
        )
    (actionHandleKind <$> observableActionHandle ReviewIssue resolvedIssue host) `shouldBe` Nothing

  -- An issue action's handle carries the stage, because the stage is what
  -- decides which published evidence its result is read from.
  it "carries the stage an issue action's own record names" $ do
    descriptor <-
      descriptorForSpec
        ( (workerFixtureSpec boardRepository (WorkerId "issue-844-0001") 844)
            { workerTask =
                IssueActionWorkerTaskKind
                  ( IssueActionWorkerTask
                      { issueActionIssueNumber = 844,
                        issueActionStage = IssueRereview,
                        issueActionHost = WorkerId "issue-host-0001",
                        issueActionOrigin = IssueOriginClaude
                      }
                  )
            }
        )
    case observableActionHandle ReviewIssue resolvedIssue descriptor of
      Just (IssueActionHandle kind _ stage _) -> do
        kind `shouldBe` ReviewIssue
        stage `shouldBe` IssueRereview
      other -> expectationFailure ("unexpected handle: " <> show (fmap actionHandleKind other))

  -- The end of it, through the driver a real run uses: a worker that exited
  -- cleanly with nothing to attribute its result to is not a success.
  it "never reads a clean exit as success when nothing can validate it" $
    withIsolatedGh $ \root ->
      withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] []) $ \store _ -> do
        stageWorker (workerFixtureSpec boardRepository (WorkerId "solve-844-0001") 844)
        driver <- liveMissionDriver testOptions testResolvedConfig boardRepository store theMission
        withFakeGh root (ghBoardWith [issueNodeJson 844 [emptyLabelsJson, emptyAssigneesJson, emptySubIssuesJson]]) $ do
          gathered <- driver.missionDriverStepEvidence thePlanStep (stepRecord MissionStepRunning [theParent])
          case gathered of
            Left detail -> expectationFailure (Text.unpack detail)
            Right evidence -> case evidence.missionEvidenceWorker >>= (.missionWorkerTerminal) of
              Just (MissionWorkerFailed failure) -> do
                missionStepFailureTag failure `shouldBe` "outcome_unknown"
                -- The target resolved; what is missing is the baseline its
                -- result would have to be judged against.
                Text.unpack (missionStepFailureMessage failure)
                  `shouldSatisfy` isInfixOf "recorded no attribution"
              other -> expectationFailure ("a clean exit was judged " <> show other)

  -- Requirement 8's boundary has a second half a controller reread cannot
  -- cover: the registry resolves against a board read of open work, so a
  -- target that closes or merges between the reread and the dispatch does not
  -- resolve at all. \"Could not resolve\" reaching the mission as a generic
  -- failure is the collapse the typed stale result exists to prevent — nothing
  -- was mutated, and the plan simply needs recomputing.
  it "retypes a target that vanished at the dispatch as a stale plan" $
    withIsolatedGh $ \root ->
      withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store _ -> do
        driver <- liveMissionDriver testOptions testResolvedConfig boardRepository store theMission
        -- The board no longer covers #844, and the item read says why.
        withFakeGh root (ghBoardAndItem [] (ghItemIn "CLOSED" ["reviewed:approve"])) $ do
          dispatched <-
            driver.missionDriverDispatch
              MissionDispatchRequest
                { missionDispatchStep = thePlanStep,
                  missionDispatchTarget = Just theTarget,
                  missionDispatchVersion = Just (issueVersion ["reviewed:approve"]),
                  missionDispatchContinuation = MissionFreshSession "brief",
                  missionDispatchInvocation = MissionInvocationId "solve-844-1"
                }
          case dispatched of
            Right accepted -> expectationFailure ("a vanished target was dispatched: " <> show accepted.missionAcceptedWorker)
            Left failure -> do
              missionStepFailureTag failure `shouldBe` "stale_version"
              -- Which is a replannable step, not a verdict on the work.
              missionStepFailureLifecycle failure `shouldBe` MissionStepPending

  -- A target that genuinely cannot be read stays the registry's refusal: this
  -- retyping is evidence-driven, and an unreadable item establishes nothing.
  it "leaves a refusal alone when the item read cannot establish a change" $
    withIsolatedGh $ \root ->
      withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store _ -> do
        driver <- liveMissionDriver testOptions testResolvedConfig boardRepository store theMission
        withFakeGh root (ghBoardAndItem [] ["#!/bin/sh", "exit 1"]) $ do
          dispatched <-
            driver.missionDriverDispatch
              MissionDispatchRequest
                { missionDispatchStep = thePlanStep,
                  missionDispatchTarget = Just theTarget,
                  missionDispatchVersion = Just (issueVersion ["reviewed:approve"]),
                  missionDispatchContinuation = MissionFreshSession "brief",
                  missionDispatchInvocation = MissionInvocationId "solve-844-2"
                }
          case dispatched of
            Right accepted -> expectationFailure ("an unresolvable target was dispatched: " <> show accepted.missionAcceptedWorker)
            Left failure -> missionStepFailureTag failure `shouldNotBe` "stale_version"

  -- A registered action that owns no worker is answered as it is asked. A
  -- session registered for one would name a worker no later pass could find,
  -- and the step would settle as an unknown outcome having thrown the answer
  -- away.
  -- The live half: the registry's own approval-queue action owns no worker,
  -- so the driver has to answer it as it dispatches it or the answer is gone.
  it "answers the registry's workerless action as it dispatches it" $
    withIsolatedGh $ \root ->
      withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store _ -> do
        driver <- liveMissionDriver testOptions testResolvedConfig boardRepository store theMission
        withFakeGh root (ghBoardWith []) $ do
          dispatched <-
            driver.missionDriverDispatch
              MissionDispatchRequest
                { missionDispatchStep = queueStep,
                  missionDispatchTarget = Nothing,
                  missionDispatchVersion = Nothing,
                  missionDispatchContinuation = MissionFreshSession "brief",
                  missionDispatchInvocation = MissionInvocationId "queue-1"
                }
          case dispatched of
            Left failure -> expectationFailure ("the queue read was refused: " <> Text.unpack (missionStepFailureMessage failure))
            Right accepted ->
              -- Whatever the queue said, it said it now. What must never
              -- happen is a session registered for a worker that does not
              -- exist and an answer thrown away with it.
              accepted.missionAcceptedOutcome `shouldSatisfy` (/= Nothing)

  it "settles an action that owns no worker in the iteration that dispatched it" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      writeIORef stage.stageDispatchResult $ \_ ->
        Right
          MissionDispatchAccepted
            { missionAcceptedSession = MissionSessionId "observation",
              missionAcceptedProviderSession = Nothing,
              missionAcceptedWorker = "observation",
              missionAcceptedDetail = "this action owns no worker",
              missionAcceptedOutcome = Just (MissionWorkerSucceeded "the approval queue is idle")
            }
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled step MissionStepSucceeded detail) -> do
          step `shouldBe` theStep
          detail `shouldBe` "the approval queue is idle"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      -- Nothing was registered for it, because there is nothing to observe.
      snapshot <- currentSnapshot store
      snapshot.missionSnapshotSessions `shouldBe` []
      outcomeTags store `shouldReturn` [Just "completed"]

  -- A child request reaches the same registered actions a plan step does,
  -- including the one that owns no worker. Recording an invented session for
  -- it leaves the parent waiting on a worker no pass can find and throws the
  -- answer away.
  it "answers a child request whose action owns no worker, without registering one" $
    withLiveParent $ \store stage controller -> do
      writeIORef stage.stageDispatchResult $ \_ ->
        Right
          MissionDispatchAccepted
            { missionAcceptedSession = MissionSessionId "observation",
              missionAcceptedProviderSession = Nothing,
              missionAcceptedWorker = "observation",
              missionAcceptedDetail = "this action owns no worker",
              missionAcceptedOutcome = Just (MissionWorkerSucceeded "the approval queue is idle")
            }
      submitConsoleCommand controller "c-queue" (childRequest "r-40" theMission theParent)
      iteration <- missionControllerIteration controller
      case iteration of
        MissionAdvanced (MissionCommandApplied "c-queue" detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "the approval queue is idle"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      snapshot <- currentSnapshot store
      -- No child node, because there is no child: the parent has nothing to
      -- wait for.
      [node.missionSessionId | node <- snapshot.missionSnapshotSessions, node.missionSessionParent /= Nothing]
        `shouldBe` []
      outcomeTags store `shouldReturn` [Just "completed"]

  -- The pair a child request is deduplicated by has to survive being written
  -- down. Joining the two with a separator does not: both halves are
  -- free-form words the console grammar accepts, so two different requests
  -- from two different parents could mint one identity — and the second would
  -- be answered with the first one's child instead of being launched.
  it "tells two child requests apart when their parent and request ids overlap" $ do
    childInvocationId (MissionSessionId "x-y") "z"
      `shouldNotBe` childInvocationId (MissionSessionId "x") "y-z"
    -- And the same pair still mints the same identity, which is what makes a
    -- replay a replay.
    childInvocationId (MissionSessionId "x-y") "z"
      `shouldBe` childInvocationId (MissionSessionId "x-y") "z"

  it "launches both of a colliding pair rather than replaying one for the other" $ do
    let parents =
          [ sessionNode "x-y" Nothing Nothing,
            (sessionNode "x" Nothing Nothing) {missionSessionId = MissionSessionId "x"}
          ]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] parents) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          submitConsoleCommand controller "c-a" (childRequest "z" theMission (MissionSessionId "x-y"))
          _ <- missionControllerIteration controller
          submitConsoleCommand controller "c-b" (childRequest "y-z" theMission (MissionSessionId "x"))
          second <- missionControllerIteration controller
          case second of
            MissionAdvanced (MissionCommandApplied "c-b" detail) ->
              Text.unpack detail `shouldSatisfy` isInfixOf "registered child"
            other -> expectationFailure ("the second request was not launched: " <> show other)
          stopMissionController controller
      length <$> readIORef stage.stageDispatches `shouldReturn` 2

  -- A registered child is an action too. Its clean exit says its process
  -- ended, not that it did what it was asked, and a mission that recorded the
  -- one as the other would put an unearned result in its own account of
  -- itself — and settle the parent over it.
  it "judges a registered child's end through the registry, not its exit code" $
    withIsolatedGh $ \root ->
      withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] []) $ \store _ -> do
        stageWorker (workerFixtureSpec boardRepository (WorkerId "child-r-50-0001") 844)
        driver <- liveMissionDriver testOptions testResolvedConfig boardRepository store theMission
        withFakeGh root (ghBoardWith [issueNodeJson 844 [emptyLabelsJson, emptyAssigneesJson, emptySubIssuesJson]]) $ do
          observed <-
            driver.missionDriverObserveSession
              (MissionSessionId "child-r-50-0001")
              (Just childPlanStep)
          case observed of
            Right (Just observation) -> do
              observation.missionObservationOutcome `shouldBe` MissionObservedUnknown
              -- And for the registry's reason, not for want of a step: this
              -- child was identified, its action was run, and what it
              -- achieved is what could not be established.
              fmap Text.unpack observation.missionObservationDetail
                `shouldSatisfy` maybe False (isInfixOf "recorded no attribution")
              -- Which keeps the parent waiting rather than settling over it.
              missionSessionDisposition (sessionNode "child-r-50-0001" (Just theParent) (Just observation))
                `shouldBe` MissionSessionUnverifiable
            other -> expectationFailure ("a child's clean exit was judged " <> show (fmap (fmap (.missionObservationOutcome)) other))

  -- And a session nothing can say anything about is unknown rather than
  -- settled, for the same reason.
  it "reads a session it cannot identify as unknown rather than as an exit" $
    withIsolatedGh $ \root ->
      withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] []) $ \store _ -> do
        stageWorker (workerFixtureSpec boardRepository (WorkerId "child-r-51-0001") 844)
        driver <- liveMissionDriver testOptions testResolvedConfig boardRepository store theMission
        withFakeGh root (ghBoardWith []) $ do
          observed <- driver.missionDriverObserveSession (MissionSessionId "child-r-51-0001") Nothing
          case observed of
            Right (Just observation) -> do
              observation.missionObservationOutcome `shouldBe` MissionObservedUnknown
              fmap Text.unpack observation.missionObservationDetail
                `shouldSatisfy` maybe False (isInfixOf "nothing records what this session was doing")
            other -> expectationFailure ("an unidentifiable session was judged " <> show (fmap (fmap (.missionObservationOutcome)) other))

  -- The pass that records these must not write the same answer for ever. An
  -- unverifiable session is never settled, so it stays in the set the pass
  -- walks, and only a change is news.
  it "records an unverifiable session once, not on every pass" $ do
    let collected =
          MissionTerminalObservation
            { missionObservationAt = fixedTime,
              missionObservationOutcome = MissionObservedUnknown,
              missionObservationDetail = Just "its worker record has been collected; how it ended is unrecorded"
            }
        node = sessionNode "solve-844-0001" Nothing (Just collected)
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] [node]) $ \store stage -> do
      -- The driver keeps saying the same thing, because nothing has changed.
      writeIORef stage.stageSessions [theParent]
      writeIORef stage.stageObservation collected
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionSessionEnded session _) ->
              expectationFailure ("the same observation was recorded again for " <> show session)
            _ -> pure ()
          -- And a reading that /has/ changed is still news.
          writeIORef stage.stageObservation endedObservation
          upgraded <- missionControllerIteration controller
          case upgraded of
            MissionAdvanced (MissionSessionEnded session _) -> session `shouldBe` theParent
            other -> expectationFailure ("a changed observation was not recorded: " <> show other)
          stopMissionController controller

  -- Two live parents may each validly ask for request @r-1@. Their invocation
  -- identities differ, but a step named for the request alone would give both
  -- children one name — and the pass that later asks what a session was doing
  -- finds the invocation /by step/, so the second child would be judged
  -- against the first one's action and target.
  it "names a child's step by the pair that asked for it, not the request alone" $ do
    childStepId (MissionSessionId "parent-a") "r-1"
      `shouldNotBe` childStepId (MissionSessionId "parent-b") "r-1"
    childStepId (MissionSessionId "x-y") "z" `shouldNotBe` childStepId (MissionSessionId "x") "y-z"
    childStepId (MissionSessionId "parent-a") "r-1" `shouldBe` childStepId (MissionSessionId "parent-a") "r-1"

  it "gives two parents asking the same request id their own steps and sessions" $ do
    let parents =
          [ sessionNode "parent-a" Nothing Nothing,
            (sessionNode "parent-b" Nothing Nothing) {missionSessionId = MissionSessionId "parent-b"}
          ]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] parents) $ \store stage -> do
      started <- startMissionController store boardRepository theMission (stagedDriver stage)
      case started of
        Left refusal -> expectationFailure (Text.unpack (missionStartRefusalMessage refusal))
        Right controller -> do
          submitConsoleCommand controller "c-a" (childRequest "r-1" theMission (MissionSessionId "parent-a"))
          _ <- missionControllerIteration controller
          submitConsoleCommand controller "c-b" (childRequest "r-1" theMission (MissionSessionId "parent-b"))
          _ <- missionControllerIteration controller
          stopMissionController controller
      snapshot <- currentSnapshot store
      -- Two children, each under its own parent and each with a step of its
      -- own, so neither is judged against the other's action.
      [ (node.missionSessionId, node.missionSessionParent, node.missionSessionStep)
        | node <- snapshot.missionSnapshotSessions,
          node.missionSessionParent /= Nothing
        ]
        `shouldBe` [ ( childSessionFor (MissionSessionId "parent-a") "r-1",
                       Just (MissionSessionId "parent-a"),
                       Just (childStepId (MissionSessionId "parent-a") "r-1")
                     ),
                     ( childSessionFor (MissionSessionId "parent-b") "r-1",
                       Just (MissionSessionId "parent-b"),
                       Just (childStepId (MissionSessionId "parent-b") "r-1")
                     )
                   ]

  -- A child's failure is typed before it is recorded, exactly as a plan step's
  -- is. The worker's own two precondition refusals are the ones that must not
  -- collapse: neither mutated anything, and they call for different repairs.
  it "types a child's precondition refusals rather than recording a bare failure" $
    withIsolatedGh $ \root ->
      withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] []) $ \store _ -> do
        driver <- liveMissionDriver testOptions testResolvedConfig boardRepository store theMission
        withFakeGh root (ghBoardWith []) $ do
          -- Unreadable: nothing was established, so the child is unverifiable
          -- and its parent keeps waiting.
          unreadable <- refusedChildEnd driver (workerUnverifiedTargetReason <> ": gh: could not connect")
          fst unreadable `shouldBe` MissionObservedUnknown
          Text.unpack (snd unreadable) `shouldSatisfy` isInfixOf "could not be reread"
          -- Moved: the turn is over and mutated nothing, so the session ended
          -- and the message says the plan is out of date.
          moved <- refusedChildEnd driver (workerStaleTargetReason <> ": #844 changed")
          fst moved `shouldBe` MissionObservedExit 1
          Text.unpack (snd moved) `shouldSatisfy` isInfixOf "stale version"
          -- And an ordinary failure is still an ordinary failure.
          plain <- refusedChildEnd driver "the provider exited 1"
          fst plain `shouldBe` MissionObservedExit 1

  -- The other half of that pair: an unverifiable child has to reach a state,
  -- not hold its parent open for ever. A foreground runner that waits on
  -- evidence which is never coming is a process that never ends.
  it "stops a step for direction when its child cannot be shown to have ended" $ do
    let sessions =
          [ sessionNode "solve-844-0001" Nothing settledObservation,
            unverifiableChild "child-1" theParent
          ]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] sessions) $ \store stage -> do
      writeIORef stage.stageEvidence $ \evidence ->
        evidence {missionEvidenceSatisfied = Just "PR #900 already links #844"}
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepReconciled step MissionStepOutcomeUnknown detail) -> do
          step `shouldBe` theStep
          Text.unpack detail `shouldSatisfy` isInfixOf "child-1"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      -- Which is a lifecycle the run stops on rather than polls in.
      snapshot <- currentSnapshot store
      blockedMissionLifecycle snapshot `shouldSatisfy` maybe False ((== MissionWaitingInput) . fst)

  -- And a child that is genuinely running still holds its parent open, which
  -- is the wait requirement 11 asks for.
  it "keeps waiting on a child that is running rather than unaccounted for" $ do
    let sessions = [sessionNode "solve-844-0001" Nothing settledObservation, liveChild "child-1" theParent]
    withMission (snapshotWith MissionRunning [stepRecord MissionStepRunning [theParent]] sessions) $ \store stage -> do
      writeIORef stage.stageEvidence $ \evidence ->
        evidence {missionEvidenceSatisfied = Just "PR #900 already links #844"}
      iteration <- oneIteration store stage
      case iteration of
        MissionAwaiting _ -> pure ()
        other -> expectationFailure ("the parent did not wait on a live child: " <> show other)
      snapshot <- currentSnapshot store
      stepLifecycle snapshot `shouldBe` Just MissionStepRunning

  -- The identity a launch is recovered by has to be unique to that launch.
  -- Two dispatches of one step inside a single clock tick are the case: an
  -- identity resting on the process id and the clock alone would be the same
  -- for both, and the journal would then read one effect where there were two.
  it "mints a fresh identity for every launch, however fast they follow" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      -- Two dispatches of the same step, the second after the first was
      -- reconciled back to pending by a stale target.
      first <- oneIteration store stage
      case first of
        MissionAdvanced (MissionStepDispatched _ _ _) -> pure ()
        other -> expectationFailure ("the first dispatch did not happen: " <> show other)
      writeIORef stage.stageEvidence $ \evidence ->
        evidence
          { missionEvidenceWorker =
              Just
                MissionWorkerReading
                  { missionWorkerSession = theParent,
                    missionWorkerLive = False,
                    missionWorkerCompatible = True,
                    missionWorkerTerminal = Just (MissionWorkerFailed (MissionFailureStaleVersion "#844 changed")),
                    missionWorkerProviderSession = Nothing
                  }
          }
      _ <- oneIteration store stage
      writeIORef stage.stageEvidence id
      second <- oneIteration store stage
      case second of
        MissionAdvanced (MissionStepDispatched _ _ _) -> pure ()
        other -> expectationFailure ("the second dispatch did not happen: " <> show other)
      recorded <- currentInvocations store
      let identities = map ((.missionInvocationId) . (.missionInvocationRecord)) recorded
      length identities `shouldBe` 2
      -- Distinct, and therefore both readable: the file keeps two effects.
      length (nub identities) `shouldBe` 2
      -- And distinct in the counter rather than only in the instant, which is
      -- what makes them distinct when the instant is the same. A counter taken
      -- from anything the snapshot holds repeats across retries of one step;
      -- this one is read off the record, so the second launch counts one
      -- higher than the first.
      map counterOf identities `shouldBe` ["0", "1"]

  -- And the counter comes off the record rather than off anything a snapshot
  -- happens to hold, so it advances with each launch instead of repeating.
  it "counts a launch's sequence off the durable record" $ do
    missionInvocationSequence [] `shouldBe` 0
    missionInvocationSequence [openInvocationState] `shouldBe` 1
    missionInvocationSequence [openInvocationState, openInvocationState] `shouldBe` 2

  -- A file that did collapse two effects into one identity is one no reader
  -- may interpret: keeping the first and dropping the second would hand the
  -- second one's closure to the first.
  it "refuses a journal that opened two invocations under one identity" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store _ -> do
      openInvocation store
      openInvocation store
      case missionInvocationPath store.missionStoreDirectory theMission of
        Left message -> expectationFailure (Text.unpack message)
        Right path -> do
          reread <- readMissionInvocations theMission store.missionStoreRepository path
          case reread of
            Right states -> expectationFailure ("two openings were collapsed into " <> show (length states))
            Left detail -> Text.unpack detail `shouldSatisfy` isInfixOf "under one identity"

  -- The closing record is durable state like any other. Discarding a failure
  -- to write it left the step recorded as running beside a launch the file
  -- still called open — and nothing revisits a running step's invocation, so
  -- the mission could complete over a record that never closed.
  it "stops the run when a launch's conclusion cannot be written" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      -- Sealed at the one moment that matters: after the opening record
      -- reached the disk and before the closing one is attempted.
      writeIORef stage.stageOnDispatch (() <$ sealInvocationJournal store)
      iteration <- oneIteration store stage
      case iteration of
        MissionControllerFailed _ -> pure ()
        other -> expectationFailure ("a lost conclusion was not reported: " <> show other)
      case missionInvocationPath store.missionStoreDirectory theMission of
        Left message -> expectationFailure (Text.unpack message)
        Right path -> unsealInvocationJournal path
      -- And the step is left where the crash windows already expect to find
      -- it, rather than as work the mission believes is under way.
      snapshot <- currentSnapshot store
      stepLifecycle snapshot `shouldSatisfy` (/= Just MissionStepRunning)

isSubtreeTerminated :: MissionSessionId -> MissionIteration -> Bool
isSubtreeTerminated root iteration = case iteration of
  MissionAdvanced (MissionSubtreeTerminated ended _) -> ended == root
  _ -> False

isWaitingInput :: MissionIteration -> Bool
isWaitingInput iteration = case iteration of
  MissionAdvanced (MissionLifecycleSet MissionWaitingInput _) -> True
  _ -> False

-- | Makes the invocation journal unappendable, the way a read-only state
-- directory does, and gives back what is needed to undo it.
sealInvocationJournal :: MissionStore -> IO FilePath
sealInvocationJournal store = case missionInvocationPath store.missionStoreDirectory theMission of
  Left message -> fail (Text.unpack message)
  Right path -> do
    -- The journal itself, made unwritable. The opening record has already
    -- created it, so the close is the next thing to open it for append — and
    -- that open fails, which is the failure this example is about. Whatever
    -- takes the write away (a permission change, a full filesystem) reaches
    -- the writer the same way.
    setFileMode path 0o400
    pure path

unsealInvocationJournal :: FilePath -> IO ()
unsealInvocationJournal path = setFileMode path 0o600

-- | The counter an invocation identity ends with, which is the part a mint
-- taken from a moving number contributes.
counterOf :: MissionInvocationId -> Text
counterOf identity = case reverse (Text.splitOn "-" identity.unMissionInvocationId) of
  (final : _) -> final
  [] -> ""

-- | The end the live driver judges for a child whose worker refused its turn
-- with this sentence.
refusedChildEnd :: MissionDriver -> Text -> IO (MissionObservedOutcome, Text)
refusedChildEnd driver detail = do
  let identifier = WorkerId ("child-" <> Text.filter (\c -> c /= ' ' && c /= ':') (Text.take 12 detail))
  stageRefusedWorker identifier detail
  observed <- driver.missionDriverObserveSession (MissionSessionId identifier.unWorkerId) (Just childPlanStep)
  case observed of
    Right (Just observation) ->
      pure (observation.missionObservationOutcome, maybe "" id observation.missionObservationDetail)
    other -> fail ("the refused child was not judged: " <> show (fmap (fmap (.missionObservationOutcome)) other))

-- | A worker that settled with a refusal, put where discovery finds it.
stageRefusedWorker :: WorkerId -> Text -> IO ()
stageRefusedWorker identifier detail = do
  let staged = workerFixtureSpec boardRepository identifier 844
  descriptor <- descriptorForSpec staged
  directory <- workerDirectory staged.workerRepository
  createPrivateDirectory XdgCache directory
  writeState
    descriptor
    ((runningWorkerState identifier 1 Nothing) {workerStateStatus = WorkerTerminal (SolveFailed detail)})
  written <- writePrivateJson descriptor.workerDescriptorSpecPath staged
  written `shouldBe` Right ()

-- | The step a registered child's launch invents for it.
childPlanStep :: MissionPlanStep
childPlanStep =
  MissionPlanStep
    { missionPlanStepId = MissionStepId "child-r-50",
      missionPlanStepAction = "solve_issue",
      missionPlanStepSummary = "a registered child",
      missionPlanStepTarget = Just theTarget,
      missionPlanStepDependsOn = []
    }

-- | A fake @gh@ answering the board read with these issue nodes.
ghBoardWith :: [String] -> [ByteString.ByteString]
ghBoardWith nodes =
  [ "#!/bin/sh",
    ByteString.pack ("printf '%s' '" <> boardPage nodes <> "'")
  ]

-- | The registered repository-wide action that owns no worker.
queueStep :: MissionPlanStep
queueStep =
  MissionPlanStep
    { missionPlanStepId = MissionStepId "queue",
      missionPlanStepAction = "observe_approval_queue",
      missionPlanStepSummary = "read the approval queue",
      missionPlanStepTarget = Nothing,
      missionPlanStepDependsOn = []
    }

boardPage :: [String] -> String
boardPage nodes = githubIndependentPage (Just (nodes, Nothing)) (Just ([], Nothing))

-- | A fake @gh@ that answers the board read and the single-item read
-- differently, which is the whole point of the race under test: the board no
-- longer covers the target and the item read says exactly why.
ghBoardAndItem :: [String] -> [ByteString.ByteString] -> [ByteString.ByteString]
ghBoardAndItem nodes itemScript =
  [ "#!/bin/sh",
    "case \"$1\" in",
    "  issue|pr)"
  ]
    <> map ("    " <>) (drop 1 itemScript)
    <> [ "    ;;",
         ByteString.pack ("  *) printf '%s' '" <> boardPage nodes <> "' ;;"),
         "esac"
       ]

-- | A solve worker whose record says what its run began from.
attributedSpec :: WorkerId -> WorkerSpec
attributedSpec identifier =
  (workerFixtureSpec boardRepository identifier 844)
    { workerParent =
        Just
          WorkerParent
            { workerParentIssueNumber = 844,
              workerParentReviewRound = 0,
              workerParentSolverBrand = ClaudeSolver,
              workerParentSolverSession = Nothing,
              workerParentSolverLogPath = Nothing,
              workerParentStartedAt = fixedTime,
              workerParentKnownPullRequests = Set.fromList [900, 901],
              workerParentPullRequest = Nothing,
              workerParentSolverAssignment = Nothing
            }
    }

-- | Puts a finished worker where discovery finds it, through the two writes
-- the launcher itself makes.
stageWorker :: WorkerSpec -> IO ()
stageWorker staged = do
  descriptor <- descriptorForSpec staged
  directory <- workerDirectory staged.workerRepository
  createPrivateDirectory XdgCache directory
  writeState descriptor (completedState staged.workerId)
  written <- writePrivateJson descriptor.workerDescriptorSpecPath staged
  written `shouldBe` Right ()

completedState :: WorkerId -> WorkerState
completedState identifier =
  (runningWorkerState identifier 1 Nothing) {workerStateStatus = WorkerTerminal SolveCompleted}

-- | The one step this mission's plan holds.
thePlanStep :: MissionPlanStep
thePlanStep = case theSpecification.missionSpecificationPlan of
  (step : _) -> step
  [] -> error "the fixture specification lost its plan"

-- | The resolution a handle is rebuilt against, produced by the registry's own
-- resolution rather than assembled here.
resolvedIssue :: ResolvedTarget
resolvedIssue =
  case resolveActionTarget defaultWorkflowConfig catalog "coghex/kanban" (TargetByKind ActionTargetIssue 844) of
    Right (ActionTargetItem resolved) -> resolved
    other -> error ("the fixture issue did not resolve: " <> show (() <$ other))
  where
    catalog =
      TargetCatalog
        { catalogRepository = boardRepository,
          catalogIssues = [missionFixtureIssue],
          catalogPullRequests = [],
          catalogHistory = CatalogHistoryAbsent
        }

missionFixtureIssue :: Issue
missionFixtureIssue =
  Issue
    { issueNumber = 844,
      issueTitle = "the fixture issue",
      issueBody = "",
      issueUrl = "https://github.com/coghex/kanban/issues/844",
      issueState = IssueOpen,
      issueLabels = [],
      issueAssignees = [],
      issueCreatedAt = fixedTime,
      issueUpdatedAt = fixedTime,
      issueLabelOverflow = 0,
      issueAssigneeOverflow = 0,
      issueSubIssues = SubIssuesNotRequested,
      issueDataGaps = []
    }
