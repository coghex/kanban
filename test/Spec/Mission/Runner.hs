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

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Kanban.Action
  ( ActionOutcome (..),
    ActionRefusal (..),
    WorkflowActionKind (SolveIssue),
    settledWorkerFailure,
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
import Kanban.Domain (Repository (..))
import Kanban.Mission
import Kanban.Ping (resolvePingBrand)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Worker (WorkerDeadline (..), WorkerId (..), WorkerSpec (..), workerDeadlineReason)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Fixtures (testOptions)
import Spec.Support.Process (deadlineFixtureSpec)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
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
  deadlineSpec
  failureVocabularySpec

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
liveChild :: Text -> MissionSessionId -> MissionSessionNode
liveChild identity parent =
  (sessionNode identity (Just parent) Nothing)
    { missionSessionOwnership =
        MissionProcessOwnership
          { missionProcessIdentity = Nothing,
            missionProcessGroup = Nothing
          },
      missionSessionObservation =
        Just
          MissionTerminalObservation
            { missionObservationAt = fixedTime,
              missionObservationOutcome = MissionObservedUnknown,
              missionObservationDetail = Just "still going"
            }
    }

issueVersion :: [Text] -> MissionTargetVersion
issueVersion labels =
  MissionTargetVersion
    { missionVersionKind = MissionTargetIssue,
      missionVersionNumber = 844,
      missionVersionUpdatedAt = Just fixedTime,
      missionVersionHead = Nothing,
      missionVersionLabels = labels,
      missionVersionState = "open"
    }

-- | Everything the fake driver was asked, and everything it will answer.
data Stage = Stage
  { stageTargets :: IORef [Either Text MissionTargetVersion],
    stageEvidence :: IORef (MissionStepEvidence -> MissionStepEvidence),
    stageDispatchResult :: IORef (Either MissionStepFailure MissionDispatchAccepted),
    stageDispatches :: IORef [MissionDispatchRequest],
    stageTerminated :: IORef [[MissionSessionId]]
  }

newStage :: IO Stage
newStage =
  Stage
    <$> newIORef (repeat (Right (issueVersion ["reviewed:approve"])))
    <*> newIORef id
    <*> newIORef (Right acceptedDispatch)
    <*> newIORef []
    <*> newIORef []

acceptedDispatch :: MissionDispatchAccepted
acceptedDispatch =
  MissionDispatchAccepted
    { missionAcceptedSession = MissionSessionId "solve-844-0001",
      missionAcceptedProviderSession = Just "provider-1",
      missionAcceptedWorker = "solve-844-0001",
      missionAcceptedDetail = "dispatched"
    }

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
                        missionEvidenceForeign = Nothing
                      }
                )
            ),
        missionDriverDispatch = \request -> do
          atomicModifyIORef' stage.stageDispatches (\seen -> (seen <> [request], ()))
          readIORef stage.stageDispatchResult,
        missionDriverTerminate = \sessions -> do
          atomicModifyIORef' stage.stageTerminated (\seen -> (seen <> [sessions], ()))
          pure (Right ())
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
              -- It holds no secret of its own, and there is nowhere for it to
              -- obtain one: the runner's secret is never written down, so an
              -- attached client's command carries no override authority
              -- however it is submitted (requirement 14).
              attachment.missionAttachmentControl.missionControlSecret `shouldBe` Nothing
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
      [ (lifecycle, missionRunnerHalt lifecycle) `shouldSatisfy` (\(_, halt) -> halt /= Nothing)
        | lifecycle <- missionLifecycles,
          lifecycle `notElem` advanceable
      ]
    sequence_
      [ (lifecycle, missionRunnerHalt lifecycle) `shouldBe` (lifecycle, Nothing)
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
      report <- runMissionWith store boardRepository theMission (stagedDriver stage)
      case report of
        Left detail -> expectationFailure (Text.unpack detail)
        Right run -> do
          run.missionRunConclusion `shouldBe` Right (MissionHaltBlocked MissionWaitingInput "it is waiting for an answer this runner cannot supply")
          missionRunSucceeded run `shouldBe` True
      readIORef stage.stageDispatches `shouldReturn` []

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

  it "reconciles a crash after the launch from the worker's own evidence" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepDispatching [MissionSessionId "solve-844-0001"]] []) $ \store stage -> do
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
      ((issueVersion ["a"]) {missionVersionUpdatedAt = Just (addUTCTime 60 fixedTime)})
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
      report <- runMissionWith store boardRepository theMission (stagedDriver stage)
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
          submitted <-
            submitMissionCommand
              controller.missionControllerControl
              "c-override"
              (MissionUserOverrideCommand theStep "it never ran; try again")
          submitted `shouldBe` Right ()
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
          _ <- submitMissionCommand controller.missionControllerControl "c-pause" (MissionPauseCommand "operator asked")
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
          _ <- submitMissionCommand controller.missionControllerControl "c-end" (MissionTerminateSubtreeCommand root "operator asked")
          iteration <- missionControllerIteration controller
          iteration `shouldBe` MissionAdvanced (MissionSubtreeTerminated root 3)
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
          _ <- submitMissionCommand controller.missionControllerControl "c-end" (MissionTerminateSubtreeCommand root "operator asked")
          first <- missionControllerIteration controller
          first `shouldBe` MissionAdvanced (MissionSubtreeTerminated root 2)
          _ <- submitMissionCommand controller.missionControllerControl "c-end" (MissionTerminateSubtreeCommand root "operator asked")
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

-- | The endpoint a client that does not own the run holds.
--
-- Taken through 'attachMissionControl' rather than built by hand, because the
-- claim being tested is that /that function/ hands out no secret.
attachToMissionAsClient :: MissionStore -> IO MissionControlEndpoint
attachToMissionAsClient store = do
  attached <- attachMissionControl store theMission
  case attached of
    Left message -> fail (Text.unpack message)
    Right endpoint -> do
      endpoint.missionControlSecret `shouldBe` Nothing
      pure endpoint

-- ---------------------------------------------------------------------------
-- Child requests
-- ---------------------------------------------------------------------------

childRequestSpec :: Spec
childRequestSpec = describe "registered child requests" $ do
  it "registers a child of a live registered parent, once" $
    withLiveParent $ \store stage controller -> do
      _ <- submitMissionCommand controller.missionControllerControl "c-child" (childRequest "r-1" theMission (MissionSessionId "solve-844-0001"))
      first <- missionControllerIteration controller
      case first of
        MissionAdvanced (MissionCommandApplied "c-child" detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "registered child"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      length <$> readIORef stage.stageDispatches `shouldReturn` 1
      -- The replay: the same parent and the same request identity, and the
      -- answer already recorded rather than a second launch.
      _ <- submitMissionCommand controller.missionControllerControl "c-child-again" (childRequest "r-1" theMission (MissionSessionId "solve-844-0001"))
      second <- missionControllerIteration controller
      case second of
        MissionAdvanced (MissionCommandApplied "c-child-again" detail) ->
          Text.unpack detail `shouldSatisfy` isInfixOf "already answered"
        other -> expectationFailure ("unexpected replay iteration: " <> show other)
      length <$> readIORef stage.stageDispatches `shouldReturn` 1
      _ <- currentSnapshot store
      pure ()

  it "rejects a request naming another mission" $
    withLiveParent $ \_ stage controller -> do
      _ <-
        submitMissionCommand
          controller.missionControllerControl
          "c-cross"
          (childRequest "r-2" (MissionId "mission-0002") (MissionSessionId "solve-844-0001"))
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
          _ <-
            submitMissionCommand
              controller.missionControllerControl
              "c-settled"
              (childRequest "r-5" theMission (MissionSessionId "solve-844-0001"))
          iteration <- missionControllerIteration controller
          case iteration of
            MissionAdvanced (MissionCommandRefused "c-settled" detail) ->
              Text.unpack detail `shouldSatisfy` isInfixOf "not a live registered session"
            other -> expectationFailure ("unexpected iteration: " <> show other)
          stopMissionController controller
      readIORef stage.stageDispatches `shouldReturn` []

  it "rejects a request naming a parent this mission never registered" $
    withLiveParent $ \_ stage controller -> do
      _ <-
        submitMissionCommand
          controller.missionControllerControl
          "c-dead"
          (childRequest "r-3" theMission (MissionSessionId "ghost-0001"))
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
-- The failure vocabulary
-- ---------------------------------------------------------------------------

failureVocabularySpec :: Spec
failureVocabularySpec = describe "the typed results a step can reach" $ do
  it "keeps all eight distinguishable" $ do
    let stale =
          MissionStaleVersion
            { missionStaleRecorded = issueVersion ["a"],
              missionStaleObserved = issueVersion ["b"]
            }
        tags = map missionStepFailureTag (missionStepFailures stale)
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

  it "refuses a dispatch the owning authority declined, without concluding the mission" $
    withMission (snapshotWith MissionRunning [stepRecord MissionStepPending []] []) $ \store stage -> do
      writeIORef stage.stageDispatchResult (Left (MissionFailureExecutable "gh is not installed"))
      iteration <- oneIteration store stage
      case iteration of
        MissionAdvanced (MissionStepBlocked step failure) -> do
          step `shouldBe` theStep
          missionStepFailureTag failure `shouldBe` "executable"
        other -> expectationFailure ("unexpected iteration: " <> show other)
      recorded <- currentInvocations store
      map (fmap missionInvocationOutcomeTag . (.missionInvocationOutcome)) recorded `shouldBe` [Just "refused"]
