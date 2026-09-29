{-# LANGUAGE OverloadedStrings #-}

-- | The repository's agent ceiling and the rotation that shares it (issue
-- #746).
--
-- Four layers, each driven through the one below it rather than beside it:
-- what the worker cache says is running; what a claim is granted against that;
-- what a mission step does when it is held; and what repeated scheduler passes
-- amount to. The occupancy every example counts is the production count over
-- worker records a fixture launch wrote, never a number an example asserted.
--
-- The claims that are about /processes/ — two steps reaching a dispatch at
-- once, a holder killed with a slot in hand — are made against separate OS
-- processes ("Spec.Support.AgentSlots"'s probes), because a thread shares the
-- process identifier that decides whether a holder is gone.
module Spec.Mission.Admission (spec) where

import Control.Monad (forM, forM_)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy as LazyByteString
import qualified Data.Map.Strict as Map
import Data.List (isInfixOf, isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (getCurrentTime)
import Kanban.Config
  ( MissionAgentCeiling (..),
    MissionsConfig (..),
    RawConfig (..),
    ResolvedConfig (..),
    decodeConfigText,
    defaultMissionAgentCeiling,
    defaultMissionsConfig,
    missionAgentCeilingRefusal,
  )
import Kanban.Domain (Repository (..))
import Kanban.GitHub (newGhRecordLock)
import Kanban.Mission
import Kanban.Preflight (IssueOrigin (..))
import Kanban.Process (ProcessIdentity (..))
import Kanban.Review (ReviewStage (..))
import Kanban.Solve (SolveOutcome (..))
import Kanban.Worker
  ( IssueActionClaim (..),
    IssueActionClaimOutcome (..),
    IssueActionWorkerTask (..),
    claimIssueAction,
    IssueHostWorkerTask (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
  )
import Spec.Support.AgentSlots
import Spec.Support.Env (withTemporaryCacheRoot)
import Spec.Support.Fixtures (testOptions, testResolvedConfig)
import Spec.Support.Process (runningWorkerState, workerFixtureSpec)
import System.Directory (createDirectory)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import Test.Hspec

spec :: Spec
spec = describe "the repository agent ceiling" $ do
  occupancySpec
  claimSpec
  rotationSpec
  stepSpec
  passSpec
  configurationSpec
  processSpec

-- ---------------------------------------------------------------------------
-- Occupancy
-- ---------------------------------------------------------------------------

occupancySpec :: Spec
occupancySpec = describe "what the worker cache says is running" $ do
  it "counts a live mission worker once and a terminal one not at all" $
    withSlotRoots $ \_ -> do
      _ <- writeAgentWorker slotRepository "live" (Just "invocation-live") solveTask (Just WorkerRunning)
      _ <- writeAgentWorker slotRepository "starting" (Just "invocation-starting") solveTask (Just WorkerStarting)
      _ <- writeAgentWorker slotRepository "done" (Just "invocation-done") solveTask (Just (WorkerTerminal SolveCompleted))
      missionAgentsNow `shouldReturn` 2

  -- Requirement 3: a worker nobody's mission launched names no invocation,
  -- and neither counts nor is waited for.
  it "never counts a worker the board launched" $
    withSlotRoots $ \_ -> do
      _ <- writeAgentWorker slotRepository "from-the-board" Nothing solveTask (Just WorkerRunning)
      missionAgentsNow `shouldReturn` 0

  -- The host is shared by every issue review in the repository, the board's
  -- included, and is no agent of its own. Each action a mission launched on
  -- it is one until it is terminal — whatever its host's process says, since
  -- an action outlives a host that died and is re-homed by the next one.
  it "counts each issue action a mission launched and never the host that runs it" $
    withSlotRoots $ \_ -> do
      _ <- writeAgentWorker slotRepository "host" Nothing (IssueHostWorkerTaskKind (IssueHostWorkerTask "coghex/kanban")) (Just WorkerRunning)
      _ <- writeAgentWorker slotRepository "action-live" (Just "invocation-review") (reviewTask 12) (Just WorkerRunning)
      _ <- writeAgentWorker slotRepository "action-waiting" (Just "invocation-waiting") (reviewTask 13) (Just WorkerStarting)
      _ <- writeAgentWorker slotRepository "action-done" (Just "invocation-reviewed") (reviewTask 14) (Just (WorkerTerminal SolveCompleted))
      _ <- writeAgentWorker slotRepository "action-from-the-board" Nothing (reviewTask 15) (Just WorkerRunning)
      missionAgentsNow `shouldReturn` 2

  -- An issue action runs on its host, whose process outlives it, so it is
  -- judged by what it ran itself: a canonical review's subprocess left
  -- running beside a terminal state still holds the slot. And an action
  -- whose state never landed may still be running on its host.
  it "keeps an issue action's slot while a process it ran survives, or while it has no state" $
    withSlotRoots $ \_ -> do
      descriptor <- writeAgentWorker slotRepository "action-ended" (Just "invocation-ended") (reviewTask 21) Nothing
      LazyByteString.writeFile
        descriptor.workerDescriptorStatePath
        ( encode
            ( (runningWorkerState (WorkerId "action-ended") 999999 (Just (identity 60)))
                { workerStateStatus = WorkerTerminal SolveCompleted,
                  workerStateKnownProcesses = [identity 61]
                }
            )
        )
      _ <- writeAgentWorker slotRepository "action-stateless" (Just "invocation-stateless") (reviewTask 22) Nothing
      let counted snapshot = do
            observed <- observeMissionAgentsWith (pure snapshot) slotRepository
            either (fail . Text.unpack) (pure . missionAgentsLive) observed
      -- The host (60) being alive is not what keeps it; the review (61) is.
      counted (Right [identity 60, identity 61]) `shouldReturn` 2
      counted (Right [identity 60]) `shouldReturn` 1
      counted (Left "ps would not run") `shouldReturn` 2

  -- A settle that could not show its gate ended leaves the gate's pid on the
  -- terminal state; with no identity beside it nothing can ever show it gone.
  it "keeps a terminal issue action's slot while its gate was never identified" $
    withSlotRoots $ \_ -> do
      unidentified <- writeAgentWorker slotRepository "action-unidentified" (Just "invocation-unidentified") (reviewTask 24) Nothing
      LazyByteString.writeFile
        unidentified.workerDescriptorStatePath
        (encode ((runningWorkerState (WorkerId "action-unidentified") 999999 Nothing) {workerStateStatus = WorkerTerminal SolveCompleted, workerStateProviderPid = Just 4242}))
      identified <- writeAgentWorker slotRepository "action-identified" (Just "invocation-identified") (reviewTask 25) Nothing
      LazyByteString.writeFile
        identified.workerDescriptorStatePath
        ( encode
            ( (runningWorkerState (WorkerId "action-identified") 999999 Nothing)
                { workerStateStatus = WorkerTerminal SolveCompleted,
                  workerStateProviderPid = Just 4343,
                  workerStateProviderIdentity = Just (identity 4343)
                }
            )
        )
      counted <- observeMissionAgentsWith (pure (Right [])) slotRepository
      fmap missionAgentsLive counted `shouldBe` Right 1

  -- A withdrawn action is the one unfinished action no host will ever run,
  -- so its slot is free even while its records wait to be removed.
  it "frees an issue action whose launch withdrew it" $
    withSlotRoots $ \_ -> do
      descriptor <- writeAgentWorker slotRepository "action-withdrawn" (Just "invocation-withdrawn") (reviewTask 23) (Just WorkerStarting)
      missionAgentsNow `shouldReturn` 1
      claimIssueAction descriptor ClaimedByWithdrawal `shouldReturn` IssueActionClaimWon
      missionAgentsNow `shouldReturn` 0

  -- GitHub treats the two spellings as one repository, and a remote or --repo
  -- may use either in different checkouts.
  it "shares one ceiling between two spellings of one repository" $
    withSlotRoots $ \store -> do
      let shouting = Repository {repositoryRoot = "/tmp/a-third-checkout", repositoryOwner = "Coghex", repositoryName = "Kanban"}
      reopened <- openMissionStore shouting
      loud <- either (fail . Text.unpack) pure reopened
      missionAdmissionStatePath loud `shouldBe` missionAdmissionStatePath store
      _ <- writeAgentWorker shouting "shouted" (Just "invocation-shouted") solveTask (Just WorkerRunning)
      missionAgentsNow `shouldReturn` 1
      let brief = slotAdmission {missionAdmissionPolls = 2}
      held <- claimMissionAgentSlot brief loud 1 (MissionId "loud") "loud-1"
      held `shouldSatisfy` heldSaying "1 of 1"
      _ <- claimMissionAgentSlot brief store 2 (MissionId "quiet") "quiet-1"
      loudly <- claimMissionAgentSlot brief loud 2 (MissionId "loud") "loud-2"
      loudly `shouldSatisfy` heldSaying "2 of 2"

  it "counts the same repository's workers from another checkout, and not another repository's" $
    withSlotRoots $ \_ -> do
      _ <- writeAgentWorker otherCheckout "elsewhere" (Just "invocation-elsewhere") solveTask (Just WorkerRunning)
      -- Another repository's record in this very directory, which is where a
      -- name that folds the same way puts one.
      stranger <- writeAgentWorker slotRepository "foreign" (Just "invocation-foreign") solveTask (Just WorkerRunning)
      LazyByteString.writeFile
        stranger.workerDescriptorSpecPath
        (encode stranger.workerDescriptorSpec {workerRepository = slotRepository {repositoryOwner = "someone", repositoryName = "else"}})
      missionAgentsNow `shouldReturn` 1

  it "counts a record it cannot read as an agent" $
    withSlotRoots $ \_ -> do
      descriptor <- agentWorker slotRepository "garbled"
      _ <- writeAgentWorker slotRepository "garbled" (Just "invocation-garbled") solveTask Nothing
      writeFile descriptor.workerDescriptorSpecPath "{ not a specification"
      missionAgentsNow `shouldReturn` 1
      -- And a state that will not decode beside a readable specification.
      _ <- writeAgentWorker slotRepository "garbled-state" (Just "invocation-garbled-state") solveTask Nothing
      stateless <- agentWorker slotRepository "garbled-state"
      writeFile stateless.workerDescriptorStatePath "{ not a state"
      missionAgentsNow `shouldReturn` 2

  -- A recorded process is the evidence, and only its proven absence frees the
  -- slot: a snapshot that finds it, and a snapshot that could not be taken,
  -- both keep it — for a running worker, for an orphan whose supervisor is
  -- gone and whose agent is not, and for a terminal record whose descendant
  -- somehow survives.
  it "frees a worker's slot only when its recorded processes are shown gone" $
    withSlotRoots $ \_ -> do
      _ <- writeAgentWorkerWith "running" (Just (identity 41)) [] WorkerRunning
      -- An orphan's supervisor is gone by definition; the agent it left
      -- behind is what keeps the slot.
      _ <- writeAgentWorkerWith "orphaned" (Just (identity 51)) [identity 42] (WorkerOrphaned SolveCompleted)
      _ <- writeAgentWorkerWith "finished" Nothing [identity 43] (WorkerTerminal SolveCompleted)
      _ <- writeAgentWorkerWith "orphan-gone" (Just (identity 54)) [identity 44] (WorkerOrphaned SolveCompleted)
      -- And one that recorded no supervisor at all, which nothing can prove
      -- gone: the worker lease reads it as live, and so does this.
      _ <- writeAgentWorkerWith "unverified" Nothing [] WorkerRunning
      let counted snapshot = do
            observed <- observeMissionAgentsWith (pure snapshot) slotRepository
            either (fail . Text.unpack) (pure . missionAgentsLive) observed
      counted (Right [identity 41, identity 42, identity 43]) `shouldReturn` 4
      counted (Right [identity 42]) `shouldReturn` 2
      counted (Right []) `shouldReturn` 1
      counted (Left "ps would not run") `shouldReturn` 5

  -- Before a state exists, a launch is judged by its item lease: an
  -- acknowledged launch never started, a lease some other worker now holds
  -- means this one is over, and a lease still naming this worker with no
  -- recorded supervisor is a start that nothing can prove has failed.
  it "judges a launch with no state yet by its acknowledgement and its lease" $
    withSlotRoots $ \_ -> do
      acknowledged <- writeAgentWorker slotRepository "acknowledged" (Just "invocation-ack") solveTask Nothing
      writeFile acknowledged.workerDescriptorAckPath "handled\n"
      missionAgentsNow `shouldReturn` 0
      starting <- writeAgentWorker slotRepository "starting-up" (Just "invocation-starting-up") solveTask Nothing
      missionAgentsNow `shouldReturn` 0
      createDirectory starting.workerDescriptorLeasePath
      writeLeaseOwner starting "starting-up"
      missionAgentsNow `shouldReturn` 1
      writeLeaseOwner starting "somebody-later"
      missionAgentsNow `shouldReturn` 0
      -- An acknowledgement is not proof: a launch acknowledges a supervisor
      -- it could not see exit and keeps its lease for exactly that case.
      stalled <- writeAgentWorker slotRepository "stalled-alive" (Just "invocation-stalled-alive") solveTask Nothing
      writeFile stalled.workerDescriptorAckPath "handled\n"
      -- The same item's lease, now naming this launch.
      writeLeaseOwner stalled "stalled-alive"
      missionAgentsNow `shouldReturn` 1

-- ---------------------------------------------------------------------------
-- Claims
-- ---------------------------------------------------------------------------

claimSpec :: Spec
claimSpec = describe "a claim for one slot" $ do
  it "is granted up to the ceiling, and held after it with the count in the reason" $
    withSlotRoots $ \store -> do
      let admission = quiet []
      claimMissionAgentSlot admission store 2 (MissionId "a") "a-1" `shouldReturn` MissionAgentSlotGranted
      claimMissionAgentSlot admission store 2 (MissionId "b") "b-1" `shouldReturn` MissionAgentSlotGranted
      held <- claimMissionAgentSlot admission store 2 (MissionId "c") "c-1"
      held `shouldSatisfy` heldSaying "2 of 2 agent slots are in use"

  -- The reservation covers only the window before the worker writes its
  -- specification; once it has, the two are one agent.
  it "counts a reservation and the worker it launched once" $
    withSlotRoots $ \store -> do
      claimMissionAgentSlot (quiet []) store 2 (MissionId "a") "a-1" `shouldReturn` MissionAgentSlotGranted
      claimMissionAgentSlot (quiet [occupant "a-1" True]) store 2 (MissionId "b") "b-1" `shouldReturn` MissionAgentSlotGranted

  -- The clarification's handoff rule: a slot is given back whatever the
  -- launch came to, and only a launch that produced this invocation's worker
  -- moves its mission to the back of the rotation.
  it "is given back by settling, which counts only a launch that produced a worker" $
    withSlotRoots $ \store -> do
      claimMissionAgentSlot (quiet []) store 1 (MissionId "refused") "refused-1" `shouldReturn` MissionAgentSlotGranted
      settleMissionAgentSlot (quiet []) store "refused-1" `shouldReturn` Right ()
      claimMissionAgentSlot (quiet []) store 1 (MissionId "launched") "launched-1" `shouldReturn` MissionAgentSlotGranted
      settleMissionAgentSlot (quiet [occupant "launched-1" True]) store "launched-1" `shouldReturn` Right ()
      state <- readMissionAdmissionState store
      fmap (.missionAdmissionRotation) state `shouldBe` Right (Map.fromList [("launched", 1)])
      fmap (.missionAdmissionReservations) state `shouldBe` Right []

  -- A launch that failed to start leaves its specification acknowledged and
  -- no state; it started no agent, so it is no admission either.
  it "moves a mission back only for a launch that started its worker" $
    withSlotRoots $ \store -> do
      claimMissionAgentSlot slotAdmission store 2 (MissionId "stalled") "stalled-1" `shouldReturn` MissionAgentSlotGranted
      stalled <- writeAgentWorker slotRepository "stalled" (Just "stalled-1") solveTask Nothing
      writeFile stalled.workerDescriptorAckPath "handled\n"
      settleMissionAgentSlot slotAdmission store "stalled-1" `shouldReturn` Right ()
      claimMissionAgentSlot slotAdmission store 2 (MissionId "started") "started-1" `shouldReturn` MissionAgentSlotGranted
      _ <- writeAgentWorker slotRepository "started" (Just "started-1") solveTask (Just WorkerRunning)
      settleMissionAgentSlot slotAdmission store "started-1" `shouldReturn` Right ()
      state <- readMissionAdmissionState store
      fmap (Map.toList . (.missionAdmissionRotation)) state `shouldBe` Right [("started", 1)]
      missionAgentsNow `shouldReturn` 1

  -- Round 7: a launcher that died after spawning its supervisor and before the
  -- supervisor's first state leaves a worker that is still starting. Its
  -- reservation outlives the launcher until the start is either counted or
  -- shown not to have happened.
  it "keeps a gone holder's reservation while its worker is still starting, and counts the start" $
    withSlotRoots $ \store -> do
      let departed = slotAdmission {missionAdmissionSelf = pure 424242}
          survivor = slotAdmission {missionAdmissionHolderAlive = pure . (/= 424242)}
      claimMissionAgentSlot departed store 3 (MissionId "slow-start") "slow-1" `shouldReturn` MissionAgentSlotGranted
      starting <- writeAgentWorker slotRepository "slow-start" (Just "slow-1") solveTask Nothing
      createDirectory starting.workerDescriptorLeasePath
      writeLeaseOwner starting "slow-start"
      claimMissionAgentSlot survivor store 3 (MissionId "other") "other-1" `shouldReturn` MissionAgentSlotGranted
      earlier <- readMissionAdmissionState store
      fmap (map (.missionReservationInvocation) . (.missionAdmissionReservations)) earlier `shouldBe` Right ["slow-1", "other-1"]
      fmap (.missionAdmissionRotation) earlier `shouldBe` Right Map.empty
      -- The supervisor writes its first state: the start happened.
      LazyByteString.writeFile starting.workerDescriptorStatePath (encode (runningWorkerState (WorkerId "slow-start") 999999 Nothing))
      claimMissionAgentSlot survivor store 3 (MissionId "third") "third-1" `shouldReturn` MissionAgentSlotGranted
      later <- readMissionAdmissionState store
      fmap (Map.toList . (.missionAdmissionRotation)) later `shouldBe` Right [("slow-start", 1)]
      fmap (map (.missionReservationInvocation) . (.missionAdmissionReservations)) later `shouldBe` Right ["other-1", "third-1"]

  -- Two launches whose holders both died after their workers started: a
  -- restart records them in the order they were granted, so the one granted
  -- first is not handed the back of the line ahead of the one granted after.
  it "records gone holders' admissions in the order they were granted" $
    withSlotRoots $ \store -> do
      -- Both granted while their holder still lives, then pruned together.
      let departed = (quiet []) {missionAdmissionSelf = pure 424242, missionAdmissionHolderAlive = const (pure True)}
          survivor = (quiet [occupant "first-1" True, occupant "second-1" True]) {missionAdmissionHolderAlive = pure . (/= 424242)}
      claimMissionAgentSlot departed store 3 (MissionId "first") "first-1" `shouldReturn` MissionAgentSlotGranted
      claimMissionAgentSlot departed store 3 (MissionId "second") "second-1" `shouldReturn` MissionAgentSlotGranted
      claimMissionAgentSlot survivor store 3 (MissionId "third") "third-1" `shouldReturn` MissionAgentSlotGranted
      state <- readMissionAdmissionState store
      fmap (Map.toList . (.missionAdmissionRotation)) state `shouldBe` Right [("first", 1), ("second", 2)]

  it "drops a gone holder's reservation, and counts its launch when its worker exists" $
    withSlotRoots $ \store -> do
      let departed = (quiet []) {missionAdmissionSelf = pure 424242}
      claimMissionAgentSlot departed store 2 (MissionId "crashed-early") "early-1" `shouldReturn` MissionAgentSlotGranted
      claimMissionAgentSlot departed store 2 (MissionId "crashed-late") "late-1" `shouldReturn` MissionAgentSlotGranted
      -- Everything a process numbered 424242 held is gone now; the late
      -- one's worker exists and still occupies its slot.
      let survivor = (quiet [occupant "late-1" True]) {missionAdmissionHolderAlive = pure . (/= 424242)}
      claimMissionAgentSlot survivor store 2 (MissionId "next") "next-1" `shouldReturn` MissionAgentSlotGranted
      held <- claimMissionAgentSlot survivor store 2 (MissionId "after") "after-1"
      held `shouldSatisfy` heldSaying "2 of 2 agent slots are in use"
      state <- readMissionAdmissionState store
      fmap (Map.toList . (.missionAdmissionRotation)) state `shouldBe` Right [("crashed-late", 1)]

  -- The clarification's first correction: lowering the setting below what is
  -- running stops new agents, and ends none.
  it "admits nothing under a ceiling lowered below what is running until it falls below" $
    withSlotRoots $ \store -> do
      held <- claimMissionAgentSlot (quiet [occupant "x" True, occupant "y" True, occupant "z" True]) store 2 (MissionId "a") "a-1"
      held `shouldSatisfy` heldSaying "3 of 2 agent slots are in use"
      claimMissionAgentSlot (quiet [occupant "x" True, occupant "y" False, occupant "z" False]) store 2 (MissionId "a") "a-1"
        `shouldReturn` MissionAgentSlotGranted

  -- Every name inside the mission store is a mission's, and any plain name
  -- can be one: a record kept in there would be enumerated as a mission, and
  -- a mission named after it would share its directory.
  it "keeps its record out of the mission namespace" $
    withSlotRoots $ \store -> do
      named <- putAgentMission store "admission"
      claimMissionAgentSlot (quiet []) store 2 named "admission-1" `shouldReturn` MissionAgentSlotGranted
      (listed, unenumerable) <- listMissionsStrictly store
      (listed, unenumerable) `shouldBe` ([named], [])
      takeDirectory (missionAdmissionStatePath store) `shouldNotBe` store.missionStoreDirectory
      takeDirectory (takeDirectory (missionAdmissionStatePath store)) `shouldNotBe` store.missionStoreDirectory

  it "decides nothing over a record or a cache it cannot read" $
    withSlotRoots $ \store -> do
      unread <- claimMissionAgentSlot (quiet []) {missionAdmissionOccupants = pure (Left "the cache is gone")} store 2 (MissionId "a") "a-1"
      unread `shouldSatisfy` undecided
      writeFile (missionAdmissionStatePath store) "{ not a record"
      garbled <- claimMissionAgentSlot (quiet []) store 2 (MissionId "a") "a-1"
      garbled `shouldSatisfy` undecided

-- ---------------------------------------------------------------------------
-- Rotation
-- ---------------------------------------------------------------------------

rotationSpec :: Spec
rotationSpec = describe "the rotation" $ do
  -- A free slot a mission ahead may still take is left for it, so which
  -- process reaches the lock first decides nothing: here the mission behind
  -- asks first and waits its turn out.
  it "leaves a free slot for a mission ahead that has not asked yet" $
    withSlotRoots $ \store -> do
      let admission = quiet []
      expectMissionAgents admission store [MissionId "b", MissionId "a"] `shouldReturn` Right [MissionId "a", MissionId "b"]
      behind <- claimMissionAgentSlot admission store 1 (MissionId "b") "b-1"
      behind `shouldSatisfy` heldSaying "left for a mission ahead"
      claimMissionAgentSlot admission store 1 (MissionId "a") "a-1" `shouldReturn` MissionAgentSlotGranted

  -- Work-conserving: a slot nobody ahead can use is used, and a withdrawn
  -- mission holds nothing.
  it "uses a slot no mission ahead can take" $
    withSlotRoots $ \store -> do
      let admission = quiet []
      _ <- expectMissionAgents admission store [MissionId "a", MissionId "b"]
      claimMissionAgentSlot admission store 2 (MissionId "b") "b-1" `shouldReturn` MissionAgentSlotGranted
      claimMissionAgentSlot admission store 3 (MissionId "c") "c-1" `shouldReturn` MissionAgentSlotGranted
      withdrawExpectedMission admission store (MissionId "a") `shouldReturn` Right ()
      claimMissionAgentSlot admission store 3 (MissionId "d") "d-1" `shouldReturn` MissionAgentSlotGranted

  -- D-8's one admission per mission per rotation, durably: the order is the
  -- record's, so a runner that starts again — here, admission over a store
  -- opened afresh — serves the missions in the same order.
  it "serves the mission admitted longest ago first, and resumes that order after a restart" $
    withSlotRoots $ \store -> do
      forM_ [("b", "b-1"), ("a", "a-1")] $ \(mission, invocation) -> do
        claimMissionAgentSlot (quiet []) store 5 (MissionId mission) invocation `shouldReturn` MissionAgentSlotGranted
        settleMissionAgentSlot (quiet [occupant invocation True]) store invocation `shouldReturn` Right ()
      reopened <- openMissionStore slotRepository
      restarted <- either (fail . Text.unpack) pure reopened
      expectMissionAgents (quiet []) restarted [MissionId "a", MissionId "b", MissionId "c"]
        `shouldReturn` Right [MissionId "c", MissionId "b", MissionId "a"]

-- ---------------------------------------------------------------------------
-- One mission step
-- ---------------------------------------------------------------------------

stepSpec :: Spec
stepSpec = describe "a mission step under the ceiling" $ do
  -- Requirement 5 and the clarification on retryable work: a held dispatch
  -- journals nothing, marks nothing, fails nothing, and leaves the mission
  -- runnable — so the same step is simply dispatched when a slot frees.
  it "holds a dispatch it has no slot for, recording nothing, and starts it once a slot frees" $
    withSlotRoots $ \store -> do
      first <- putAgentMission store "first"
      second <- putAgentMission store "second"
      stepAgentMission 1 store first >>= (`shouldSatisfy` dispatched)
      held <- stepAgentMission 1 store second
      held `shouldSatisfy` heldBack
      snapshot <- readMissionSnapshot store second
      fmap (map (.missionStepRecordLifecycle) . (.missionSnapshotSteps)) snapshot `shouldBe` MissionPresent [MissionStepPending]
      fmap missionIsRunnable snapshot `shouldBe` MissionPresent True
      missionAgentsNow `shouldReturn` 1
      workers <- agentWorkersOf first
      mapM_ finishAgentWorker workers
      stepAgentMission 1 store second >>= (`shouldSatisfy` dispatched)
      missionAgentsNow `shouldReturn` 1

  -- Requirement 5's other half: watching a live worker, and recording that
  -- one ended, start nothing and are never held.
  it "never holds a transition that starts no agent" $
    withSlotRoots $ \store -> do
      first <- putAgentMission store "first"
      second <- putAgentMission store "second"
      stepAgentMission 1 store first >>= (`shouldSatisfy` dispatched)
      stepAgentMission 1 store first >>= (`shouldSatisfy` awaiting)
      mapM_ finishAgentWorker =<< agentWorkersOf first
      stepAgentMission 1 store second >>= (`shouldSatisfy` dispatched)
      -- Every slot is taken again, and the first mission still records that
      -- its session ended.
      ended <- stepAgentMission 1 store first
      ended `shouldSatisfy` sessionEnded

  it "reports a step held back as deferred, and a step watching its worker as awaiting" $ do
    let result iteration = missionChildResultOf "launch" "coghex/kanban" (MissionId "m") (Right (MissionStepReport (MissionId "m") iteration))
    (result (MissionHeldForSlot "no slot")).missionChildResultOutcome `shouldBe` MissionChildDeferred
    (result (MissionAwaiting "live")).missionChildResultOutcome `shouldBe` MissionChildAwaiting
    missionStepSucceeded (MissionStepReport (MissionId "m") (MissionHeldForSlot "no slot")) `shouldBe` True
    (result (MissionControllerFailed "broke")).missionChildResultOutcome `shouldBe` MissionChildFailed

-- ---------------------------------------------------------------------------
-- Passes
-- ---------------------------------------------------------------------------

passSpec :: Spec
passSpec = describe "successive scheduler passes" $ do
  -- The first acceptance case: five missions ready to start agents that stay
  -- live, and no pass ever leaves more than two of them running.
  it "never leave more than two agents live, and start the third once a slot frees" $
    withSlotRoots $ \store -> do
      missions@(firstMission : _) <- forM ["m1", "m2", "m3", "m4", "m5"] (putAgentMission store)
      first <- agentPass 2 store
      dispositionsOf first `shouldBe` [MissionDispositionAdvanced, MissionDispositionAdvanced, MissionDispositionDeferred, MissionDispositionDeferred, MissionDispositionDeferred]
      first.missionPassAgents `shouldBe` Just (MissionAgentCount 2 2)
      first.missionPassTermination `shouldBe` MissionPassCompleted
      second <- agentPass 2 store
      second.missionPassAgents `shouldBe` Just (MissionAgentCount 2 2)
      missionAgentsNow `shouldReturn` 2
      mapM_ finishAgentWorker =<< agentWorkersOf firstMission
      third <- agentPass 2 store
      third.missionPassAgents `shouldBe` Just (MissionAgentCount 2 2)
      workersByMission <- mapM agentWorkersOf missions
      map (not . null) workersByMission `shouldBe` [True, True, True, False, False]

  -- The rotation acceptance case: two missions that both want the one slot
  -- in the same pass take it in turn — the one admitted longer ago first,
  -- whichever of them the identifier order would favour.
  it "hand a contended slot to each contending mission in turn" $
    withSlotRoots $ \store -> do
      let solves = [(MissionStepId "first", []), (MissionStepId "second", [])]
      alpha <- putAgentMissionSteps store "alpha" solves
      beta <- putAgentMissionSteps store "beta" solves
      -- Alpha has had a turn: its agent ran and ended, and its next
      -- transition is its second solve, exactly like beta's first.
      stepAgentMission 1 store alpha >>= (`shouldSatisfy` dispatched)
      mapM_ finishAgentWorker =<< agentWorkersOf alpha
      stepAgentMission 1 store alpha >>= (`shouldSatisfy` sessionEnded)
      stepAgentMission 1 store alpha >>= (`shouldSatisfy` reconciled)
      contended <- agentPass 1 store
      map (.missionDispositionMission) contended.missionPassAdmitted `shouldBe` [beta, alpha]
      dispositionsOf contended `shouldBe` [MissionDispositionAdvanced, MissionDispositionDeferred]
      map length <$> mapM liveAgentsOf [alpha, beta] `shouldReturn` [0, 1]
      -- Beta's turn is over; now both want the slot again, and it is alpha's.
      mapM_ finishAgentWorker =<< agentWorkersOf beta
      stepAgentMission 1 store beta >>= (`shouldSatisfy` sessionEnded)
      stepAgentMission 1 store beta >>= (`shouldSatisfy` reconciled)
      again <- agentPass 1 store
      map (.missionDispositionMission) again.missionPassAdmitted `shouldBe` [alpha, beta]
      dispositionsOf again `shouldBe` [MissionDispositionAdvanced, MissionDispositionDeferred]
      map length <$> mapM liveAgentsOf [alpha, beta] `shouldReturn` [1, 0]

  it "skip a mission that is waiting, and let a lone runnable mission use every free slot" $
    withSlotRoots $ \store -> do
      waiting <- putAgentMission store "a-waiting"
      snapshot <- readMissionSnapshot store waiting
      case snapshot of
        MissionPresent present -> writeMissionSnapshot store present {missionSnapshotLifecycle = MissionWaitingInput} `shouldReturn` Right ()
        _ -> expectationFailure "the waiting mission's snapshot did not read back"
      lone <- putAgentMissionSteps store "lone" [(MissionStepId "one", []), (MissionStepId "two", [])]
      _ <- agentPass 2 store
      _ <- agentPass 2 store
      map length <$> mapM agentWorkersOf [waiting, lone] `shouldReturn` [0, 2]
      missionAgentsNow `shouldReturn` 2

  -- Requirement 3's second half: work the board started takes no slot a
  -- mission could use, and nothing about a mission's slot delays it.
  it "count nothing the board launched" $
    withSlotRoots $ \store -> do
      _ <- writeAgentWorker slotRepository "from-the-board" Nothing solveTask (Just WorkerRunning)
      mission <- putAgentMission store "m1"
      report <- agentPass 1 store
      dispositionsOf report `shouldBe` [MissionDispositionAdvanced]
      map length <$> mapM agentWorkersOf [mission] `shouldReturn` [1]

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

configurationSpec :: Spec
configurationSpec = describe "the configured ceiling" $ do
  it "defaults to two and takes a positive whole number" $ do
    ceilingOf "" `shouldBe` Right (MissionAgentCeiling defaultMissionAgentCeiling)
    defaultMissionAgentCeiling `shouldBe` 2
    ceilingOf "[missions]\nagent_ceiling = 5\n" `shouldBe` Right (MissionAgentCeiling 5)

  it "refuses zero, a negative number, a fraction, and anything else by name" $
    forM_ ["0", "-1", "1.5", "\"two\"", "true"] $ \written -> do
      let configured = ceilingOf ("[missions]\nagent_ceiling = " <> written <> "\n")
      (written, fmap (fmap (Text.isInfixOf "missions.agent_ceiling") . refusalOf) configured) `shouldBe` (written, Right (Just True))

  it "raises and lowers the ceiling a pass applies" $
    forM_ [(1, 1), (3, 3)] $ \(agentCeiling, started) ->
      withSlotRoots $ \store -> do
        missions <- forM ["m1", "m2", "m3", "m4"] (putAgentMission store)
        report <- agentPass agentCeiling store
        report.missionPassAgents `shouldBe` Just (MissionAgentCount started agentCeiling)
        length . filter (not . null) <$> mapM agentWorkersOf missions `shouldReturn` started

  it "refuses a pass under an unusable ceiling rather than advancing anything" $
    withSlotRoots $ \store -> do
      _ <- putAgentMission store "m1"
      report <-
        runMissionSchedulerPass
          (inertSeams store)
          defaultMissionsConfig {missionsAgentCeiling = MissionAgentCeilingInvalid "0"}
          store
          slotRepository
      report.missionPassTermination `shouldBe` MissionPassRefused
      ("missions.agent_ceiling" `Text.isInfixOf` report.missionPassDetail) `shouldBe` True

  -- The live driver's own decision, which is the only one a real run uses:
  -- an action that starts no agent asks for nothing, and one that does is
  -- refused by name under an unusable ceiling rather than let through.
  it "asks for a slot only for an action that starts an agent, and never under an unusable ceiling" $
    withSlotRoots $ \store -> do
      recordLock <- newGhRecordLock
      let unusable = testResolvedConfig {resolvedMissions = defaultMissionsConfig {missionsAgentCeiling = MissionAgentCeilingInvalid "-1"}}
      driver <- liveMissionDriver testOptions unusable recordLock slotRepository store (MissionId "m1")
      let stepFor action = MissionPlanStep (MissionStepId "s") action "a step" Nothing []
      driver.missionDriverClaimSlot (stepFor "observe_approval_queue") (MissionInvocationId "i-1") `shouldReturn` MissionSlotNotNeeded
      driver.missionDriverClaimSlot (stepFor "no_such_action") (MissionInvocationId "i-2") `shouldReturn` MissionSlotNotNeeded
      refused <- driver.missionDriverClaimSlot (stepFor "solve_issue") (MissionInvocationId "i-3")
      refused `shouldSatisfy` \claim -> case claim of
        MissionSlotUndecided detail -> "missions.agent_ceiling" `Text.isInfixOf` detail
        _ -> False
  where
    ceilingOf text = (.missionsAgentCeiling) . (.rawMissions) . fst <$> decodeConfigText text
    refusalOf configured = missionAgentCeilingRefusal defaultMissionsConfig {missionsAgentCeiling = configured}

-- ---------------------------------------------------------------------------
-- Separate processes
-- ---------------------------------------------------------------------------

processSpec :: Spec
processSpec = describe "separate processes" $ do
  -- The second acceptance case: two mission steps in two processes reach a
  -- dispatch together with one slot free, and exactly one agent starts.
  it "start exactly one agent between two steps that reach one free slot together" $
    withSlotRoots $ \store -> withTemporaryCacheRoot $ \probes -> do
      _ <- putAgentMission store "left"
      _ <- putAgentMission store "right"
      left <- startAdmissionProbe probes ProbeStep "left" 1
      right <- startAdmissionProbe probes ProbeStep "right" 1
      openAdmissionGate probes
      results <- mapM awaitAdmissionResult [left, right]
      mapM stopAdmissionProbe [left, right] `shouldReturn` [ExitSuccess, ExitSuccess]
      filter (== "dispatched") results `shouldBe` ["dispatched"]
      filter ("held" `isPrefixOf`) results `shouldSatisfy` ((== 1) . length)
      missionAgentsNow `shouldReturn` 1

  -- The same, from two checkouts that spell the repository differently: one
  -- ceiling, one lock, one occupancy between them.
  it "start exactly one agent between two checkouts that spell the repository differently" $
    withSlotRoots $ \lower -> withTemporaryCacheRoot $ \probes -> do
      let shouting = Repository {repositoryRoot = "/tmp/a-shouting-checkout", repositoryOwner = "Coghex", repositoryName = "Kanban"}
      reopened <- openMissionStore shouting
      upper <- either (fail . Text.unpack) pure reopened
      _ <- putAgentMission lower "quiet-one"
      _ <- putAgentMission upper "loud-one"
      quietProbe <- startAdmissionProbe probes ProbeStep "quiet-one" 1
      loudProbe <- startAdmissionProbeFor shouting probes ProbeStep "loud-one" 1
      openAdmissionGate probes
      results <- mapM awaitAdmissionResult [quietProbe, loudProbe]
      mapM stopAdmissionProbe [quietProbe, loudProbe] `shouldReturn` [ExitSuccess, ExitSuccess]
      filter (== "dispatched") results `shouldBe` ["dispatched"]
      -- The one held back saw the other's agent, whichever spelling it was.
      filter ("held" `isPrefixOf`) results `shouldSatisfy` all ("1 of 1 agent slots are in use" `isInfixOf`)
      filter ("held" `isPrefixOf`) results `shouldSatisfy` ((== 1) . length)
      missionAgentsNow `shouldReturn` 1
      observed <- observeMissionAgents shouting
      fmap missionAgentsLive observed `shouldBe` Right 1

  -- The clarification's interruption cases. A holder killed before it
  -- launched anything leaves its slot to be reused; one killed after its
  -- worker exists leaves that worker counted, once, and its launch recorded
  -- in the rotation.
  it "reuse a slot whose holder died before launching, and never one whose worker survived it" $
    withSlotRoots $ \store -> withTemporaryCacheRoot $ \probes -> do
      createDirectory (probes </> "holder")
      createDirectory (probes </> "launcher")
      -- One at a time, so which of them holds what is staged rather than won.
      holder <- startAdmissionProbe (probes </> "holder") ProbeClaimAndHold "holder" 1
      openAdmissionGate (probes </> "holder")
      awaitAdmissionResult holder `shouldReturn` show MissionAgentSlotGranted
      launcher <- startAdmissionProbe (probes </> "launcher") ProbeLaunchAndHold "launcher" 2
      openAdmissionGate (probes </> "launcher")
      awaitAdmissionResult launcher `shouldReturn` show MissionAgentSlotGranted
      let brief = slotAdmission {missionAdmissionPolls = 3}
      claimMissionAgentSlot brief store 2 (MissionId "waiting") "waiting-1" >>= (`shouldSatisfy` heldSaying "2 of 2")
      killAdmissionProbe holder
      killAdmissionProbe launcher
      claimMissionAgentSlot brief store 2 (MissionId "waiting") "waiting-1" `shouldReturn` MissionAgentSlotGranted
      claimMissionAgentSlot brief store 2 (MissionId "another") "another-1" >>= (`shouldSatisfy` heldSaying "2 of 2")
      state <- readMissionAdmissionState store
      fmap (Map.member "launcher" . (.missionAdmissionRotation)) state `shouldBe` Right True
      fmap (Map.member "holder" . (.missionAdmissionRotation)) state `shouldBe` Right False

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

solveTask :: WorkerTask
solveTask = (workerFixtureSpec slotRepository (WorkerId "any") 844).workerTask

reviewTask :: Int -> WorkerTask
reviewTask issue = IssueActionWorkerTaskKind (IssueActionWorkerTask issue InitialReview (WorkerId "host") IssueOriginClaude)

identity :: Int -> ProcessIdentity
identity processId =
  ProcessIdentity
    { processIdentityPid = processId,
      processIdentityParentPid = 1,
      processIdentityGroupPid = processId,
      processIdentityStartedAt = "Mon Sep 28 12:00:00 2026",
      processIdentityCommand = "an agent"
    }

-- | A mission worker whose state records these identities.
writeAgentWorkerWith :: Text -> Maybe ProcessIdentity -> [ProcessIdentity] -> WorkerStatus -> IO WorkerDescriptor
writeAgentWorkerWith name supervisor known status = do
  descriptor <- writeAgentWorker slotRepository name (Just ("invocation-" <> name)) solveTask Nothing
  LazyByteString.writeFile
    descriptor.workerDescriptorStatePath
    ( encode
        ( (runningWorkerState (WorkerId name) 999999 supervisor)
            { workerStateStatus = status,
              workerStateKnownProcesses = known
            }
        )
    )
  pure descriptor

writeLeaseOwner :: WorkerDescriptor -> Text -> IO ()
writeLeaseOwner descriptor owner = do
  now <- getCurrentTime
  LazyByteString.writeFile
    descriptor.workerDescriptorLeaseOwnerPath
    (encode (object ["workerLeaseId" .= WorkerId owner, "workerLeaseCreatedAt" .= now]))

-- | Admission whose worker cache holds exactly these occupants.
quiet :: [MissionAgentOccupant] -> MissionAdmissionSeams
quiet occupants =
  slotAdmission
    { missionAdmissionOccupants = pure (Right occupants),
      missionAdmissionPollMicros = 1000,
      missionAdmissionPolls = 5
    }

occupant :: Text -> Bool -> MissionAgentOccupant
occupant invocation live = MissionAgentOccupant (Text.unpack invocation <> ".spec.json") (Just invocation) live True

heldSaying :: Text -> MissionAgentSlotDecision -> Bool
heldSaying fragment decision = case decision of
  MissionAgentSlotHeld reason -> fragment `Text.isInfixOf` reason
  _ -> False

undecided :: MissionAgentSlotDecision -> Bool
undecided decision = case decision of
  MissionAgentSlotUndecided _ -> True
  _ -> False

dispatched :: MissionIteration -> Bool
dispatched iteration = case iteration of
  MissionAdvanced (MissionStepDispatched {}) -> True
  _ -> False

heldBack :: MissionIteration -> Bool
heldBack iteration = case iteration of
  MissionHeldForSlot _ -> True
  _ -> False

awaiting :: MissionIteration -> Bool
awaiting iteration = case iteration of
  MissionAwaiting _ -> True
  _ -> False

reconciled :: MissionIteration -> Bool
reconciled iteration = case iteration of
  MissionAdvanced (MissionStepReconciled {}) -> True
  _ -> False

sessionEnded :: MissionIteration -> Bool
sessionEnded iteration = case iteration of
  MissionAdvanced (MissionSessionEnded _ _) -> True
  _ -> False

dispositionsOf :: MissionPassReport -> [MissionDisposition]
dispositionsOf report = map (.missionDispositionValue) report.missionPassAdmitted

-- | Every worker a mission's launches wrote, live or not.
agentWorkersOf :: MissionId -> IO [WorkerDescriptor]
agentWorkersOf mission = do
  observed <- observeMissionAgents slotRepository
  occupants <- either (fail . Text.unpack) pure observed
  descriptors <-
    mapM
      (\found -> agentWorker slotRepository (Text.dropEnd (Text.length ".spec.json") (Text.pack found.missionOccupantRecord)))
      occupants
  pure [descriptor | descriptor <- descriptors, ("agent-" <> mission.unMissionId <> "-") `Text.isPrefixOf` descriptor.workerDescriptorSpec.workerId.unWorkerId]

-- | The ones among them still running.
liveAgentsOf :: MissionId -> IO [WorkerDescriptor]
liveAgentsOf mission = do
  observed <- observeMissionAgents slotRepository
  occupants <- either (fail . Text.unpack) pure observed
  let live = [Text.dropEnd (Text.length ".spec.json") (Text.pack found.missionOccupantRecord) | found <- occupants, found.missionOccupantLive]
  filter (\descriptor -> descriptor.workerDescriptorSpec.workerId.unWorkerId `elem` live) <$> agentWorkersOf mission

inertSeams :: MissionStore -> MissionSchedulerSeams
inertSeams store =
  MissionSchedulerSeams
    { missionSchedulerNow = getCurrentTime,
      missionSchedulerLeaseHeld = missionLeaseHeld store,
      missionSchedulerAdvance = \_ _ -> fail "a refused pass advances nothing",
      missionSchedulerExpect = \_ -> fail "a refused pass enters nothing",
      missionSchedulerWithdraw = \_ -> pure (),
      missionSchedulerAgents = fail "a refused pass counts nothing",
      missionSchedulerNotify = \_ -> fail "a refused pass notifies nothing",
      missionSchedulerSeal = \_ -> fail "a refused pass seals nothing"
    }
