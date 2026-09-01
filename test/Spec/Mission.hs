{-# LANGUAGE OverloadedStrings #-}

-- | The durable mission store: what it writes, what it refuses, and what a
-- process that shares nothing with the writer reads back.
--
-- Every example redirects @$XDG_STATE_HOME@ into a temporary directory, so
-- nothing here can see or disturb a real store, and the paths asserted about
-- are the ones a real run would resolve rather than ones the fixture handed
-- in.
--
-- Three fixtures need explaining before they are read.
--
-- An /interrupted/ write cannot be staged by asking the writer to be
-- interrupted, so each one is staged from the writer's own bytes: the record
-- is written properly first, and then the file is cut back to what an
-- interruption would have left. That keeps the fragment real — it is exactly
-- what the encoder emits — rather than something this module invented and then
-- proved the reader tolerates.
--
-- Two of the acceptance cases are about a second /process/ (see
-- "Spec.Support.MissionProbes"), and they use the probe harness rather than
-- threads.
--
-- The SHA-256 examples are FIPS 180-4's own vectors plus the three message
-- lengths that sit either side of a padding block boundary. A digest is the
-- one thing here with a published right answer, and an implementation written
-- out by hand earns being checked against it rather than against itself.
module Spec.Mission (spec) where

import Control.Monad (forM_, void)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteStringChar
import Data.List (isInfixOf, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Kanban.Domain (Repository (..))
import Kanban.Mission
  ( MissionArchiveState (..),
    MissionAttention (..),
    MissionAutonomy (MissionConfirmOnAmbiguity),
    MissionCreation (..),
    MissionDecisionPolicy (..),
    MissionDispositionRefusal (..),
    MissionEvent (..),
    MissionHolderPresence (..),
    MissionId (..),
    MissionJournalLine (..),
    MissionLeaseAcquisition (..),
    MissionLifecycle (..),
    MissionLogKind (MissionEventStreamLog, MissionRawProviderLog),
    MissionObservedOutcome (..),
    MissionPause (..),
    MissionPlanStep (..),
    MissionPresentation (..),
    MissionProcessOwnership (..),
    MissionLease (..),
    MissionLeaseOwner (..),
    MissionRead (..),
    MissionReconciliation (..),
    MissionRepository (..),
    MissionRetryCounter (..),
    MissionSealFailure (..),
    MissionSealedArchive (..),
    MissionSelector (..),
    MissionSessionDisposition (..),
    MissionSessionId (..),
    MissionSessionNode (..),
    MissionSessionTreeError (..),
    MissionSnapshot (..),
    MissionSpecification (..),
    MissionStepId (..),
    MissionStepLifecycle (..),
    MissionStepRecord (..),
    MissionStore (..),
    MissionTarget (..),
    MissionTargetKind (MissionTargetIssue),
    MissionTerminalObservation (..),
    MissionWorktreeDisposition (..),
    MissionWorktreeState (..),
    acquireMissionLease,
    acquireMissionLeaseWith,
    archiveMission,
    createMissionSpecification,
    deleteMission,
    listMissions,
    missionDispositionRefusalMessage,
    missionHolderPresence,
    missionLifecycleIsTerminal,
    missionLifecycleTag,
    missionLifecycles,
    missionSealDigestAlgorithm,
    missionSealFailureMessage,
    missionSessionDisposition,
    missionSessionTreeErrorMessage,
    missionStepLifecycleIsTerminal,
    missionStepLifecycleTag,
    missionStepLifecycles,
    missionStoreRoot,
    openMissionStore,
    readMissionJournal,
    readMissionLeaseOwner,
    readMissionSealedArchives,
    readMissionSnapshot,
    readMissionSpecification,
    recordMissionEvent,
    releaseMissionLease,
    sealMissionLog,
    validateMissionSessionTree,
    verifyMissionSealedArchive,
    sha256Hex,
    writeMissionSnapshot,
  )
import Kanban.Process (ProcessIdentity (..), defaultProcessSnapshot)
import Spec.Support.Env
  ( permissionsOf,
    withEnvironmentValue,
    withFileCreationMask,
    withTemporaryCacheRoot,
  )
import Spec.Support.MissionProbes
  ( MissionProbe (..),
    MissionProbeAction (..),
    MissionProbeOutcome (..),
    MissionProbeReadback (..),
    MissionProbeReport (..),
    MissionProbeSealOutcome (..),
    MissionProbes,
    awaitMissionReport,
    killMissionHolder,
    openMissionGate,
    releaseMissionHolder,
    withMissionProbes,
  )
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removeFile, renameFile)
import System.FilePath (takeDirectory, (</>))
import System.Environment (getEnv)
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Posix.Process (getProcessID)
import System.Process (createProcess, getPid, proc, waitForProcess)
import Test.Hspec

spec :: Spec
spec = describe "the durable mission store" $ do
  storeLocationSpec
  identitySpec
  roundTripSpec
  journalSpec
  snapshotSpec
  permissionSpec
  leaseSpec
  schemaSpec
  sealSpec
  dispositionSpec
  enumerationSpec
  sessionTreeSpec
  vocabularySpec
  digestSpec
  noProcessSpec

-- * Fixtures

boardRepository :: Repository
boardRepository = Repository {repositoryRoot = "/tmp/board", repositoryOwner = "coghex", repositoryName = "kanban"}

otherRepository :: Repository
otherRepository = Repository {repositoryRoot = "/tmp/other", repositoryOwner = "coghex", repositoryName = "elsewhere"}

theMission :: MissionId
theMission = MissionId "mission-0001"

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 8 31) (secondsToDiffTime 42)

-- | Runs @action@ against a store resolved the way a real run resolves one,
-- under a temporary state root nothing else can see.
withStore :: (FilePath -> MissionStore -> IO result) -> IO result
withStore action = withTemporaryCacheRoot $ \root ->
  withEnvironmentValue "XDG_STATE_HOME" root $ do
    opened <- openMissionStore boardRepository
    case opened of
      Left message -> fail ("could not open the mission store: " <> Text.unpack message)
      Right store -> action root store

specificationFor :: MissionRepository -> MissionId -> Text -> MissionSpecification
specificationFor repository mission request =
  MissionSpecification
    { missionSpecificationId = mission,
      missionSpecificationRepository = repository,
      missionSpecificationRequest = request,
      missionSpecificationSelector =
        MissionSelector
          { missionSelectorKind = "issues",
            missionSelectorQuery = Just "label:reviewed:approve",
            missionSelectorTargets =
              [MissionTarget {missionTargetKind = MissionTargetIssue, missionTargetNumber = 592, missionTargetTitle = Just "the store"}]
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
            { missionPlanStepId = MissionStepId "solve-592",
              missionPlanStepAction = "solve",
              missionPlanStepSummary = "take #592 to a pull request",
              missionPlanStepTarget = Nothing,
              missionPlanStepDependsOn = []
            }
        ]
    }

theSpecification :: MissionSpecification
theSpecification = specificationFor (MissionRepository "coghex" "kanban") theMission "solve the approved backlog"

snapshotWith :: MissionLifecycle -> [MissionStepRecord] -> [MissionSessionNode] -> [MissionWorktreeDisposition] -> MissionSnapshot
snapshotWith lifecycle steps sessions worktrees =
  MissionSnapshot
    { missionSnapshotId = theMission,
      missionSnapshotRepository = MissionRepository "coghex" "kanban",
      missionSnapshotLifecycle = lifecycle,
      missionSnapshotCurrentStep = Just (MissionStepId "solve-592"),
      missionSnapshotNextSteps = [MissionStepId "review-592"],
      missionSnapshotSteps = steps,
      missionSnapshotPause = MissionPause {missionPauseRequested = False, missionPauseReason = Nothing, missionPauseAt = Nothing},
      missionSnapshotAttention =
        Just
          MissionAttention
            { missionAttentionSummary = "the reviewer asked a product question",
              missionAttentionStep = Just (MissionStepId "solve-592"),
              missionAttentionRaisedAt = fixedTime
            },
      missionSnapshotPlannerSummary = Just "one issue, one review loop",
      missionSnapshotRetries = [MissionRetryCounter {missionRetryCounterStep = MissionStepId "solve-592", missionRetryCounterAttempts = 1, missionRetryCounterLastAttemptAt = Just fixedTime}],
      missionSnapshotLastReconciliation =
        Just MissionReconciliation {missionReconciliationAt = fixedTime, missionReconciliationOutcome = "agreed", missionReconciliationSteps = []},
      missionSnapshotSessions = sessions,
      missionSnapshotArchive =
        MissionArchiveState
          { missionArchivePresentation = MissionPresentationActive,
            missionArchiveWorktrees = worktrees,
            missionArchiveLastAccessedAt = Just fixedTime
          },
      missionSnapshotUpdatedAt = fixedTime
    }

runningSnapshot :: MissionSnapshot
runningSnapshot = snapshotWith MissionRunning [stepRecord MissionStepRunning] [] []

stepRecord :: MissionStepLifecycle -> MissionStepRecord
stepRecord lifecycle =
  MissionStepRecord
    { missionStepRecordId = MissionStepId "solve-592",
      missionStepRecordLifecycle = lifecycle,
      missionStepRecordSessions = [MissionSessionId "session-a"],
      missionStepRecordDetail = Nothing,
      missionStepRecordUpdatedAt = fixedTime
    }

sessionNode :: Text -> Maybe MissionSessionId -> Maybe MissionTerminalObservation -> MissionSessionNode
sessionNode identity parent observation =
  MissionSessionNode
    { missionSessionId = MissionSessionId identity,
      missionSessionMission = theMission,
      missionSessionParent = parent,
      missionSessionStep = Just (MissionStepId "solve-592"),
      missionSessionProvider = "claude",
      missionSessionProviderSessionId = Just ("provider-" <> identity),
      missionSessionOwnership = MissionProcessOwnership {missionProcessIdentity = Nothing, missionProcessGroup = Nothing},
      missionSessionLog = Nothing,
      missionSessionObservation = observation
    }

settled :: Maybe MissionTerminalObservation
settled = Just MissionTerminalObservation {missionObservationAt = fixedTime, missionObservationOutcome = MissionObservedExit 0, missionObservationDetail = Nothing}

-- | A session recorded as owning a process and never observed to end.
liveSession :: MissionSessionNode
liveSession =
  (sessionNode "session-a" Nothing Nothing)
    { missionSessionOwnership =
        MissionProcessOwnership
          { missionProcessIdentity =
              Just
                ProcessIdentity
                  { processIdentityPid = 4242,
                    processIdentityParentPid = 1,
                    processIdentityGroupPid = 4242,
                    processIdentityStartedAt = "Sun Aug 31 12:00:00 2026",
                    processIdentityCommand = "claude"
                  },
            missionProcessGroup = Nothing
          }
    }

unresolved :: Maybe MissionTerminalObservation
unresolved = Just MissionTerminalObservation {missionObservationAt = fixedTime, missionObservationOutcome = MissionObservedUnknown, missionObservationDetail = Nothing}

eventNamed :: Text -> MissionEvent
eventNamed kind =
  MissionEvent
    { missionEventAt = fixedTime,
      missionEventMission = theMission,
      missionEventRepository = MissionRepository "coghex" "kanban",
      missionEventStep = Just (MissionStepId "solve-592"),
      missionEventSession = Nothing,
      missionEventKind = kind,
      missionEventDetail = Just "recorded by the fixture"
    }

expectRight :: Show failure => Either failure value -> IO value
expectRight result = case result of
  Left failure -> fail ("expected success, got " <> show failure)
  Right value -> pure value

expectPresent :: Show value => MissionRead value -> IO value
expectPresent result = case result of
  MissionPresent value -> pure value
  other -> fail ("expected a record, got " <> show other)

-- * The store's location

storeLocationSpec :: Spec
storeLocationSpec = describe "where a repository's missions live" $ do
  it "is the repository-qualified directory under the XDG state root, not the cache" $
    withTemporaryCacheRoot $ \root ->
      withEnvironmentValue "XDG_STATE_HOME" root $ do
        resolved <- missionStoreRoot boardRepository
        resolved `shouldBe` root </> "kanban" </> "missions" </> "coghex-kanban"

  it "keeps two repositories apart" $
    withTemporaryCacheRoot $ \root ->
      withEnvironmentValue "XDG_STATE_HOME" root $ do
        board <- missionStoreRoot boardRepository
        other <- missionStoreRoot otherRepository
        board `shouldNotBe` other

  it "refuses a mission identifier that is not a single plain name, rather than writing outside the store" $
    withStore $ \_ store -> do
      forM_ ["../escape", "with/separator", "", "."] $ \name -> do
        created <- createMissionSpecification store (specificationFor (MissionRepository "coghex" "kanban") (MissionId (Text.pack name)) "escape")
        case created of
          Right outcome -> expectationFailure ("expected a refusal for " <> show name <> ", got " <> show outcome)
          Left message -> Text.unpack message `shouldSatisfy` isInfixOf "single plain name"
      -- Nothing was written anywhere, inside the store or above it.
      entries <- listDirectory store.missionStoreDirectory
      entries `shouldBe` []
      above <- listDirectory (takeDirectory (takeDirectory store.missionStoreDirectory))
      sort above `shouldBe` ["missions"]

-- * Identity

-- | The whole identity lattice, enumerated: five kinds of durable record, two
-- ways each can fail to be this store's.
--
-- Enumerated in one place on purpose. Each record is decoded on its own, so
-- for each of them where it sits and what it says about itself can be made to
-- disagree — a store restored from a backup, a directory copied to try
-- something out, a repository renamed. Checking four of the five, or one of
-- the two identities, leaves a hole that looks exactly like the ones that are
-- covered.
identitySpec :: Spec
identitySpec = describe "every durable record's own identity" $ do
  it "is refused when the record belongs to another repository, however right its mission looks" $
    withStore $ \root store -> do
      foreignRecords root store (MissionRepository "coghex" "elsewhere") theMission
      specification <- readMissionSpecification store theMission
      refusalOf specification `shouldSatisfy` mentions "another repository"
      snapshot <- readMissionSnapshot store theMission
      refusalOf snapshot `shouldSatisfy` mentions "another repository"
      (records, _) <- expectRight =<< readMissionJournal store theMission 0
      kindsOf records `shouldBe` []
      unwords (map Text.unpack (refusalsOf records)) `shouldSatisfy` isInfixOf "another repository"
      seals <- readMissionSealedArchives store theMission
      case seals of
        Left message -> Text.unpack message `shouldSatisfy` isInfixOf "another repository"
        Right entries -> expectationFailure ("expected a refusal, got " <> show (map missionSealedSession entries))
      lease <- acquireMissionLeaseWith (const (pure MissionHolderGone)) store theMission
      case lease of
        MissionLeaseHeld reason -> Text.unpack reason `shouldSatisfy` isInfixOf "another repository"
        other -> expectationFailure ("expected a refusal, got " <> show other)

  it "is refused when the record belongs to another mission" $
    withStore $ \root store -> do
      foreignRecords root store (MissionRepository "coghex" "kanban") (MissionId "mission-0002")
      specification <- readMissionSpecification store theMission
      refusalOf specification `shouldSatisfy` mentions "the mission mission-0002"
      snapshot <- readMissionSnapshot store theMission
      refusalOf snapshot `shouldSatisfy` mentions "the mission mission-0002"
      (records, _) <- expectRight =<< readMissionJournal store theMission 0
      kindsOf records `shouldBe` []
      unwords (map Text.unpack (refusalsOf records)) `shouldSatisfy` isInfixOf "the mission mission-0002"
      seals <- readMissionSealedArchives store theMission
      case seals of
        Left message -> Text.unpack message `shouldSatisfy` isInfixOf "mission-0002"
        Right entries -> expectationFailure ("expected a refusal, got " <> show (map missionSealedSession entries))
      lease <- acquireMissionLeaseWith (const (pure MissionHolderGone)) store theMission
      case lease of
        MissionLeaseHeld reason -> Text.unpack reason `shouldSatisfy` isInfixOf "mission-0002"
        other -> expectationFailure ("expected a refusal, got " <> show other)

-- | Writes one of every durable record correctly, for @owner@ and @named@, and
-- then moves each into this store's @mission-0001@ directory.
--
-- Every record is produced by the writer that owns it rather than assembled
-- here: what is being tested is a reader's refusal, and a hand-built record
-- would be testing this module's idea of the format instead.
foreignRecords :: FilePath -> MissionStore -> MissionRepository -> MissionId -> IO ()
foreignRecords root store owner named = do
  elsewhere <-
    if owner == store.missionStoreRepository
      then pure store
      else expectRight =<< openMissionStore otherRepository
  void (expectRight =<< createMissionSpecification elsewhere (specificationFor owner named "somewhere else"))
  void
    ( expectRight
        =<< writeMissionSnapshot
          elsewhere
          runningSnapshot {missionSnapshotId = named, missionSnapshotRepository = owner}
    )
  void
    ( expectRight
        =<< recordMissionEvent
          elsewhere
          (eventNamed "planned") {missionEventMission = named, missionEventRepository = owner}
    )
  let source = root </> "child.log"
  ByteString.writeFile source "a child's stream"
  void (expectRight =<< sealMissionLog elsewhere named (MissionSessionId "session-a") MissionEventStreamLog source)
  acquisition <- acquireMissionLease elsewhere named
  case acquisition of
    MissionLeaseAcquired _ -> pure ()
    other -> expectationFailure ("expected to acquire the foreign lease, got " <> show other)
  let from = elsewhere.missionStoreDirectory </> Text.unpack named.unMissionId
  createDirectoryIfMissing True (missionRoot store </> "lease")
  createDirectoryIfMissing True (missionRoot store </> "archive")
  forM_
    [ "specification.json",
      "snapshot.json",
      "events.jsonl",
      "lease" </> "owner.json",
      "archive" </> "session-a-event_stream.seal.json"
    ]
    $ \name -> renameFile (from </> name) (missionRoot store </> name)

refusalOf :: Show value => MissionRead value -> String
refusalOf result = case result of
  MissionRefused message -> Text.unpack message
  other -> "not a refusal: " <> show other

mentions :: String -> String -> Bool
mentions = isInfixOf

-- * Round-trip

roundTripSpec :: Spec
roundTripSpec = describe "a mission read back by a process that never wrote it" $
  it "round-trips its specification, its snapshot and every journal record in order" $
    withStore $ \root store -> do
      created <- expectRight =<< createMissionSpecification store theSpecification
      created `shouldBe` MissionCreated
      void (expectRight =<< writeMissionSnapshot store runningSnapshot)
      forM_ ["planned", "dispatched", "finished"] $ \kind ->
        void (expectRight =<< recordMissionEvent store (eventNamed kind))
      report <- withMissionProbes (root </> "probes")
        [ MissionProbe
            { missionProbeName = "reader",
              missionProbeStore = store.missionStoreDirectory,
              missionProbeRepository = store.missionStoreRepository,
              missionProbeMission = theMission,
              missionProbeAction = MissionProbeReadBack,
              missionProbeGate = "read"
            }
        ]
        $ \probes -> do
          openMissionGate probes "read"
          awaitMissionReport probes "reader"
      case report of
        MissionProbeReadbackReport readback -> do
          readback.readbackDiagnostics `shouldBe` []
          readback.readbackRequest `shouldBe` Just "solve the approved backlog"
          readback.readbackLifecycle `shouldBe` Just "running"
          readback.readbackEventKinds `shouldBe` ["planned", "dispatched", "finished"]
        other -> expectationFailure ("expected a readback report, got " <> show other)

-- * The journal

journalSpec :: Spec
journalSpec = describe "the append-only event journal" $ do
  it "reads a record that was still being appended once, whole, after the append completes" $
    withStore $ \_ store -> do
      forM_ ["first", "second", "third"] $ \kind ->
        void (expectRight =<< recordMissionEvent store (eventNamed kind))
      let journal = journalPath store
      complete <- ByteString.readFile journal
      -- The fragment is the writer's own bytes, cut back to where an append
      -- interrupted part way through the third record would have left it.
      let cut = ByteString.length complete - 20
          (fragmentary, remainder) = ByteString.splitAt cut complete
      ByteString.writeFile journal fragmentary
      (firstPass, offset) <- expectRight =<< readMissionJournal store theMission 0
      kindsOf firstPass `shouldBe` ["first", "second"]
      diagnosticsOf firstPass `shouldBe` []
      -- The rest of that same record, and its newline, arrive.
      ByteString.appendFile journal remainder
      (secondPass, _) <- expectRight =<< readMissionJournal store theMission offset
      kindsOf secondPass `shouldBe` ["third"]
      diagnosticsOf secondPass `shouldBe` []

  it "reports the one malformed line an unrelated append after a permanently truncated fragment makes" $
    withStore $ \_ store -> do
      void (expectRight =<< recordMissionEvent store (eventNamed "first"))
      let journal = journalPath store
      complete <- ByteString.readFile journal
      ByteString.writeFile journal (ByteString.take (ByteString.length complete - 12) complete)
      -- A whole record appended onto a fragment that will never be completed
      -- does not make two records. It makes one line, and that line is
      -- malformed rather than absent.
      void (expectRight =<< recordMissionEvent store (eventNamed "unrelated"))
      (records, _) <- expectRight =<< readMissionJournal store theMission 0
      kindsOf records `shouldBe` []
      case diagnosticsOf records of
        [message] -> do
          Text.unpack message `shouldSatisfy` isInfixOf "mission-0001"
          Text.unpack message `shouldSatisfy` isInfixOf "events.jsonl"
        other -> expectationFailure ("expected one diagnostic, got " <> show other)

  it "says nothing at all about a record written under an unrecognized schema version, and reads the ones after it" $
    withStore $ \_ store -> do
      void (expectRight =<< recordMissionEvent store (eventNamed "before"))
      let journal = journalPath store
      ByteString.appendFile journal "{\"schemaVersion\":9999,\"payload\":{}}\n"
      void (expectRight =<< recordMissionEvent store (eventNamed "after"))
      (records, offset) <- expectRight =<< readMissionJournal store theMission 0
      -- Absent means absent: three lines were consumed and two are reported,
      -- with nothing said about the third and no diagnostic standing in for
      -- it.
      length records `shouldBe` 2
      kindsOf records `shouldBe` ["before", "after"]
      diagnosticsOf records `shouldBe` []
      -- The offset still passed over it, so a reader threading the offset
      -- neither replays it nor stalls on it.
      consumed <- ByteString.length <$> ByteString.readFile journal
      offset `shouldBe` consumed

kindsOf :: [MissionJournalLine] -> [Text]
kindsOf records = [event.missionEventKind | MissionJournalEvent event <- records]

-- | Records this release could not read. Kept apart from 'refusalsOf' because
-- broken and not-ours are different answers with different repairs, and a
-- helper that merged them would let either assertion pass on the other.
diagnosticsOf :: [MissionJournalLine] -> [Text]
diagnosticsOf records = [message | MissionJournalMalformed message <- records]

-- | Records that decoded and belong to another mission or repository.
refusalsOf :: [MissionJournalLine] -> [Text]
refusalsOf records = [message | MissionJournalRefused message <- records]

journalPath :: MissionStore -> FilePath
journalPath store = store.missionStoreDirectory </> "mission-0001" </> "events.jsonl"

-- * The snapshot

snapshotSpec :: Spec
snapshotSpec = describe "replacing the snapshot" $ do
  it "leaves the previous snapshot readable and current when a replacement is interrupted before its rename" $
    withStore $ \root store -> do
      void (expectRight =<< writeMissionSnapshot store runningSnapshot)
      -- The bytes of the replacement, produced by the writer itself, left
      -- where an interruption between the write and the rename leaves them.
      let elsewhere = root </> "interrupted.json"
      void (expectRight =<< writeMissionSnapshot (MissionStore (takeDirectory elsewhere) store.missionStoreRepository) (snapshotWith MissionCompleted [] [] []))
      let snapshotFile = store.missionStoreDirectory </> "mission-0001" </> "snapshot.json"
      interrupted <- ByteString.readFile (takeDirectory elsewhere </> "mission-0001" </> "snapshot.json")
      ByteString.writeFile (snapshotFile <> ".staged-9999-interrupted") interrupted
      current <- expectPresent =<< readMissionSnapshot store theMission
      current.missionSnapshotLifecycle `shouldBe` MissionRunning

  it "replaces it whole once the write completes" $
    withStore $ \_ store -> do
      void (expectRight =<< writeMissionSnapshot store runningSnapshot)
      void (expectRight =<< writeMissionSnapshot store (snapshotWith MissionCompleted [] [] []))
      current <- expectPresent =<< readMissionSnapshot store theMission
      current.missionSnapshotLifecycle `shouldBe` MissionCompleted

  it "publishes nothing and leaves no loose file behind when a write cannot be committed" $
    withStore $ \_ store ->
      withFileCreationMask 0o000 $ do
        void (expectRight =<< recordMissionEvent store (eventNamed "first"))
        -- A target that cannot be renamed onto. The record is staged and
        -- written in full first, so this is a commit failing rather than a
        -- write never starting, which is what makes the staging file the
        -- thing at risk of being left behind.
        createDirectoryIfMissing True (missionRoot store </> "snapshot.json" </> "occupied")
        written <- writeMissionSnapshot store runningSnapshot
        case written of
          Left _ -> pure ()
          Right () -> expectationFailure "expected the snapshot write to fail"
        entries <- sort <$> listDirectory (missionRoot store)
        entries `shouldBe` ["events.jsonl", "snapshot.json"]

  it "creates the file it stages user-only, so the record it commits was never loose for an instant" $
    withStore $ \_ store ->
      withFileCreationMask 0o000 $ do
        -- Nothing tightens these files after the fact: a rename and a hard
        -- link both carry the staged inode to the final path, so the mode
        -- asserted here is the mode the staging file was created with.
        void (expectRight =<< createMissionSpecification store theSpecification)
        void (expectRight =<< writeMissionSnapshot store runningSnapshot)
        forM_ ["specification.json", "snapshot.json"] $ \name -> do
          mode <- permissionsOf (missionRoot store </> name)
          (name, mode) `shouldBe` (name, 0o600)

  it "is not blocked by a staged copy an interrupted creation left behind, and never adopts one" $
    withStore $ \_ store -> do
      void (expectRight =<< createMissionSpecification store (specificationFor (MissionRepository "coghex" "kanban") (MissionId "mission-0002") "another mission"))
      -- What a crash between staging a specification and committing it
      -- leaves: a complete-looking file that is not at the published path.
      staged <- ByteString.readFile (store.missionStoreDirectory </> "mission-0002" </> "specification.json")
      createDirectoryIfMissing True (missionRoot store)
      ByteString.writeFile (missionRoot store </> "specification.json.staged-9999-interrupted") staged
      created <- expectRight =<< createMissionSpecification store theSpecification
      created `shouldBe` MissionCreated
      stored <- expectPresent =<< readMissionSpecification store theMission
      stored.missionSpecificationRequest `shouldBe` "solve the approved backlog"

  it "refuses to write a specification twice, and leaves the first exactly as it was" $
    withStore $ \_ store -> do
      first <- expectRight =<< createMissionSpecification store theSpecification
      first `shouldBe` MissionCreated
      second <- expectRight =<< createMissionSpecification store (specificationFor (MissionRepository "coghex" "kanban") theMission "a different request")
      second `shouldBe` MissionSpecificationExists
      stored <- expectPresent =<< readMissionSpecification store theMission
      stored.missionSpecificationRequest `shouldBe` "solve the approved backlog"

-- * Permissions

permissionSpec :: Spec
permissionSpec = describe "under a permissive umask" $
  it "creates every directory it owns 0700 and every file 0600, the journal after an append included" $
    withTemporaryCacheRoot $ \root ->
      withEnvironmentValue "XDG_STATE_HOME" root $
        withFileCreationMask 0o000 $ do
          store <- expectRight =<< openMissionStore boardRepository
          void (expectRight =<< createMissionSpecification store theSpecification)
          void (expectRight =<< writeMissionSnapshot store runningSnapshot)
          void (expectRight =<< recordMissionEvent store (eventNamed "first"))
          void (expectRight =<< recordMissionEvent store (eventNamed "second"))
          let source = root </> "child.log"
          ByteString.writeFile source "a child's stream"
          void (expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog source)
          acquisition <- acquireMissionLease store theMission
          case acquisition of
            MissionLeaseAcquired lease -> releaseMissionLease lease
            other -> expectationFailure ("expected to acquire the lease, got " <> show other)
          forM_
            [ root </> "kanban",
              root </> "kanban" </> "missions",
              store.missionStoreDirectory,
              missionRoot store,
              missionRoot store </> "archive"
            ]
            $ \directory -> do
              present <- doesDirectoryExist directory
              present `shouldBe` True
              mode <- permissionsOf directory
              (directory, mode) `shouldBe` (directory, 0o700)
          archived <- listDirectory (missionRoot store </> "archive")
          forM_
            ( [ missionRoot store </> "specification.json",
                missionRoot store </> "snapshot.json",
                missionRoot store </> "events.jsonl"
              ]
                <> map ((missionRoot store </> "archive") </>) (sort archived)
            )
            $ \file -> do
              present <- doesFileExist file
              present `shouldBe` True
              mode <- permissionsOf file
              (file, mode) `shouldBe` (file, 0o600)

-- * The lease

leaseSpec :: Spec
leaseSpec = describe "the mission lease" $ do
  it "is taken by exactly one of two contending processes" $
    withStore $ \root store ->
      withMissionProbes (root </> "probes") (map (leaseProbe store "both") ["first", "second"]) $ \probes -> do
        openMissionGate probes "both"
        outcomes <- mapM (leaseOutcome probes) ["first", "second"]
        length [() | MissionProbeAcquired <- outcomes] `shouldBe` 1
        length [() | MissionProbeHeld _ <- outcomes] `shouldBe` 1

  it "passes to a successor process once its holder releases it, with the holder still running" $
    withStore $ \root store ->
      withMissionProbes
        (root </> "probes")
        [leaseProbe store "holder" "holder", leaseProbe store "successor" "successor"]
        $ \probes -> do
          openMissionGate probes "holder"
          held <- leaseOutcome probes "holder"
          held `shouldBe` MissionProbeAcquired
          releaseMissionHolder probes "holder"
          openMissionGate probes "successor"
          successor <- leaseOutcome probes "successor"
          successor `shouldBe` MissionProbeAcquired

  it "passes to a successor process once its holder is proven gone" $
    withStore $ \root store ->
      withMissionProbes
        (root </> "probes")
        [leaseProbe store "holder" "holder", leaseProbe store "successor" "successor"]
        $ \probes -> do
          openMissionGate probes "holder"
          held <- leaseOutcome probes "holder"
          held `shouldBe` MissionProbeAcquired
          killMissionHolder probes "holder"
          openMissionGate probes "successor"
          successor <- leaseOutcome probes "successor"
          successor `shouldBe` MissionProbeAcquired

  it "stays held while its holder is still running" $
    withStore $ \root store ->
      withMissionProbes
        (root </> "probes")
        [leaseProbe store "holder" "holder", leaseProbe store "intruder" "intruder"]
        $ \probes -> do
          openMissionGate probes "holder"
          held <- leaseOutcome probes "holder"
          held `shouldBe` MissionProbeAcquired
          openMissionGate probes "intruder"
          intruder <- leaseOutcome probes "intruder"
          case intruder of
            MissionProbeHeld reason -> Text.unpack reason `shouldSatisfy` isInfixOf "still running"
            other -> expectationFailure ("expected a refusal, got " <> show other)

  it "stays held for good when its owner record will not decode" $
    withStore $ \_ store -> do
      acquisition <- acquireMissionLease store theMission
      case acquisition of
        MissionLeaseAcquired _ -> pure ()
        other -> expectationFailure ("expected to acquire the lease, got " <> show other)
      ByteString.writeFile (store.missionStoreDirectory </> "mission-0001" </> "lease" </> "owner.json") "not json at all"
      second <- acquireMissionLease store theMission
      case second of
        MissionLeaseHeld reason -> Text.unpack reason `shouldSatisfy` isInfixOf "will not decode"
        other -> expectationFailure ("expected a refusal, got " <> show other)

  it "stays held for good when its owner record is gone entirely" $
    withStore $ \_ store -> do
      void (acquireMissionLease store theMission)
      removeFile (store.missionStoreDirectory </> "mission-0001" </> "lease" </> "owner.json")
      second <- acquireMissionLease store theMission
      case second of
        MissionLeaseHeld reason -> Text.unpack reason `shouldSatisfy` isInfixOf "missing"
        other -> expectationFailure ("expected a refusal, got " <> show other)

  it "names its holder to a caller that only wants to say who has it" $
    withStore $ \_ store -> do
      acquisition <- acquireMissionLease store theMission
      lease <- case acquisition of
        MissionLeaseAcquired lease -> pure lease
        other -> fail ("expected to acquire the lease, got " <> show other)
      owner <- readMissionLeaseOwner store theMission
      case owner of
        MissionPresent record -> do
          record.missionLeaseOwnerMission `shouldBe` theMission
          record.missionLeaseOwnerToken `shouldBe` lease.missionLeaseToken
        other -> expectationFailure ("expected an owner record, got " <> show other)
      releaseMissionLease lease
      afterRelease <- readMissionLeaseOwner store theMission
      afterRelease `shouldBe` MissionAbsent

  it "stays held when its owner record belongs to another mission, however gone that holder is" $
    withStore $ \_ store -> do
      void (acquireMissionLease store theMission)
      -- An owner record written for another mission, moved here. Its process
      -- says nothing about who is advancing this mission, so even a probe
      -- that reports every holder gone must not retire the lease.
      let other = MissionId "mission-0002"
      void (acquireMissionLease store other)
      renameFile
        (store.missionStoreDirectory </> "mission-0002" </> "lease" </> "owner.json")
        (missionRoot store </> "lease" </> "owner.json")
      second <-
        acquireMissionLeaseWith
          (const (pure MissionHolderGone))
          store
          theMission
      case second of
        MissionLeaseHeld reason -> do
          Text.unpack reason `shouldSatisfy` isInfixOf "owner record was refused"
          Text.unpack reason `shouldSatisfy` isInfixOf "the mission mission-0002"
        other' -> expectationFailure ("expected a refusal, got " <> show other')

  it "stays held when the liveness probe cannot answer" $
    withStore $ \_ store -> do
      void (acquireMissionLease store theMission)
      second <-
        acquireMissionLeaseWith
          (const (pure (MissionHolderUndecidable "the kernel would not say")))
          store
          theMission
      case second of
        MissionLeaseHeld reason -> Text.unpack reason `shouldSatisfy` isInfixOf "could not be checked"
        other -> expectationFailure ("expected a refusal, got " <> show other)

  it "asks the kernel about a holder, and calls only a reaped process gone" $ do
    self <- getProcessID
    running <- missionHolderPresence (fromIntegral self)
    running `shouldBe` MissionHolderPresent
    -- A real process, exited and reaped, so its identifier genuinely resolves
    -- to nothing. Reaping is what makes that an established fact rather than
    -- something this example races.
    (_, _, _, handle) <- createProcess (proc "/bin/sh" ["-c", "exit 0"])
    identifier <- getPid handle
    _ <- waitForProcess handle
    case identifier of
      Nothing -> expectationFailure "the child exited before it could be identified"
      Just pid -> do
        gone <- missionHolderPresence (fromIntegral pid)
        gone `shouldBe` MissionHolderGone

  it "refuses an identifier that would name a process group rather than a process" $
    -- Zero and negative values are process groups to kill(2), and the largest
    -- Int becomes -1 — every process — when it is narrowed to a pid_t. A
    -- corrupted record must not be able to ask any of those questions.
    forM_ [0, -1, maxBound] $ \refused -> do
      undecidable <- missionHolderPresence refused
      case undecidable of
        MissionHolderUndecidable detail -> Text.unpack detail `shouldSatisfy` isInfixOf "is not a process identifier"
        other -> expectationFailure ("expected " <> show refused <> " to be refused, got " <> show other)

  it "records the holder's own process identifier, so a successor can ask about it" $
    withStore $ \_ store -> do
      acquisition <- acquireMissionLease store theMission
      case acquisition of
        MissionLeaseAcquired _ -> pure ()
        other -> expectationFailure ("expected to acquire the lease, got " <> show other)
      owner <- readMissionLeaseOwner store theMission
      self <- getProcessID
      case owner of
        MissionPresent record -> record.missionLeaseOwnerProcessId `shouldBe` fromIntegral self
        other -> expectationFailure ("expected an owner record, got " <> show other)

leaseProbe :: MissionStore -> String -> String -> MissionProbe
leaseProbe store gate name =
  MissionProbe
    { missionProbeName = name,
      missionProbeStore = store.missionStoreDirectory,
      missionProbeRepository = store.missionStoreRepository,
      missionProbeMission = theMission,
      missionProbeAction = MissionProbeLease,
      missionProbeGate = gate
    }

sealOutcome :: MissionProbes -> String -> IO MissionProbeSealOutcome
sealOutcome probes name = do
  reported <- awaitMissionReport probes name
  case reported of
    MissionProbeSealReport outcome -> pure outcome
    other -> fail ("expected a seal report from " <> name <> ", got " <> show other)

leaseOutcome :: MissionProbes -> String -> IO MissionProbeOutcome
leaseOutcome probes name = do
  report <- awaitMissionReport probes name
  case report of
    MissionProbeLeaseReport outcome -> pure outcome
    other -> fail ("expected a lease report from " <> name <> ", got " <> show other)

-- * Schema tolerance

schemaSpec :: Spec
schemaSpec = describe "a record this release did not write" $ do
  it "reads as absent, silently, when its schema version is not recognized" $
    withStore $ \_ store -> do
      void (expectRight =<< createMissionSpecification store theSpecification)
      rewriteVersion store 9999
      result <- readMissionSpecification store theMission
      result `shouldBe` MissionAbsent

  it "is reported, naming the mission and the file, when it will not decode at all" $
    withStore $ \_ store -> do
      void (expectRight =<< createMissionSpecification store theSpecification)
      ByteString.writeFile (specificationFile store) "{ this is not json"
      result <- readMissionSpecification store theMission
      case result of
        MissionUnreadable message -> do
          Text.unpack message `shouldSatisfy` isInfixOf "mission-0001"
          Text.unpack message `shouldSatisfy` isInfixOf "specification.json"
        other -> expectationFailure ("expected a diagnostic, got " <> show other)

  it "is reported when it carries no integer schema version" $
    withStore $ \_ store -> do
      void (expectRight =<< createMissionSpecification store theSpecification)
      ByteString.writeFile (specificationFile store) "{\"schemaVersion\":\"one\"}"
      result <- readMissionSpecification store theMission
      case result of
        MissionUnreadable message -> Text.unpack message `shouldSatisfy` isInfixOf "not an integer"
        other -> expectationFailure ("expected a diagnostic, got " <> show other)

  it "is reported when its payload will not decode under a version this release does recognize" $
    withStore $ \_ store -> do
      void (expectRight =<< createMissionSpecification store theSpecification)
      ByteString.writeFile (specificationFile store) "{\"schemaVersion\":1,\"payload\":{\"missionSpecificationId\":42}}"
      result <- readMissionSpecification store theMission
      case result of
        MissionUnreadable message -> Text.unpack message `shouldSatisfy` isInfixOf "schema version 1"
        other -> expectationFailure ("expected a diagnostic, got " <> show other)

  it "is refused, not adopted, when the store reading it is another repository's" $
    withStore $ \_ store -> do
      void (expectRight =<< createMissionSpecification store theSpecification)
      void (expectRight =<< writeMissionSnapshot store runningSnapshot)
      -- The same directory, read as the store of a repository it was not
      -- written for: a store copied, restored from a backup, or read after a
      -- repository was renamed.
      let elsewhere = MissionStore store.missionStoreDirectory (MissionRepository "coghex" "elsewhere")
      specification <- readMissionSpecification elsewhere theMission
      case specification of
        MissionRefused message -> Text.unpack message `shouldSatisfy` isInfixOf "another repository"
        other -> expectationFailure ("expected a refusal, got " <> show other)
      snapshot <- readMissionSnapshot elsewhere theMission
      case snapshot of
        MissionRefused message -> Text.unpack message `shouldSatisfy` isInfixOf "another repository"
        other -> expectationFailure ("expected a refusal, got " <> show other)

  it "is refused, not adopted, when it is another mission's record sitting in this mission's directory" $
    withStore $ \_ store -> do
      -- Both records are written correctly, for the mission they name, and
      -- then moved: a store restored from a backup or a directory copied by
      -- hand is enough to do this, and adopting one would let mission-0002's
      -- terminal snapshot authorise archiving or deleting mission-0001.
      let other = MissionId "mission-0002"
      void (expectRight =<< createMissionSpecification store (specificationFor (MissionRepository "coghex" "kanban") other "another mission"))
      void (expectRight =<< writeMissionSnapshot store (runningSnapshot {missionSnapshotId = other, missionSnapshotLifecycle = MissionCompleted}))
      createDirectoryIfMissing True (missionRoot store)
      forM_ ["specification.json", "snapshot.json"] $ \name ->
        renameFile (store.missionStoreDirectory </> "mission-0002" </> name) (missionRoot store </> name)
      specification <- readMissionSpecification store theMission
      case specification of
        MissionRefused message -> Text.unpack message `shouldSatisfy` isInfixOf "mission-0002"
        other' -> expectationFailure ("expected a refusal, got " <> show other')
      snapshot <- readMissionSnapshot store theMission
      case snapshot of
        MissionRefused message -> Text.unpack message `shouldSatisfy` isInfixOf "mission-0002"
        other' -> expectationFailure ("expected a refusal, got " <> show other')
      -- And the two operations that decide from a snapshot refuse rather than
      -- act on the foreign one, however terminal it looks.
      refusalKinds <$> archiveMission store theMission >>= (`shouldBe` ["unreadable"])
      refusalKinds <$> deleteMission store theMission >>= (`shouldBe` ["unreadable"])

  it "is never written in the first place: a record naming another repository is refused by the writer" $
    withStore $ \_ store -> do
      created <- createMissionSpecification store (specificationFor (MissionRepository "coghex" "elsewhere") theMission "another repository's mission")
      case created of
        Left message -> Text.unpack message `shouldSatisfy` isInfixOf "not the one this store holds"
        Right outcome -> expectationFailure ("expected a refusal, got " <> show outcome)
      written <- writeMissionSnapshot store (runningSnapshot {missionSnapshotRepository = MissionRepository "coghex" "elsewhere"})
      case written of
        Left message -> Text.unpack message `shouldSatisfy` isInfixOf "not the one this store holds"
        Right () -> expectationFailure "expected the snapshot write to be refused"

missionRoot :: MissionStore -> FilePath
missionRoot store = store.missionStoreDirectory </> "mission-0001"

specificationFile :: MissionStore -> FilePath
specificationFile store = missionRoot store </> "specification.json"

rewriteVersion :: MissionStore -> Int -> IO ()
rewriteVersion store version = do
  existing <- ByteString.readFile (specificationFile store)
  let replaced =
        TextEncoding.encodeUtf8
          ( Text.replace "\"schemaVersion\":1" ("\"schemaVersion\":" <> Text.pack (show version)) (TextEncoding.decodeUtf8 existing)
          )
  ByteString.writeFile (specificationFile store) replaced

-- * Sealing

sealSpec :: Spec
sealSpec = describe "sealing a child's log" $ do
  it "keeps the complete stream, and its digest and byte length still verify after the source is deleted" $
    withStore $ \root store -> do
      let source = root </> "child.log"
          content = ByteStringChar.pack (concat (replicate 200 "a line of a child's stream\n"))
      ByteString.writeFile source content
      sealed <- expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog source
      sealed.missionSealedDigestAlgorithm `shouldBe` missionSealDigestAlgorithm
      sealed.missionSealedByteLength `shouldBe` fromIntegral (ByteString.length content)
      sealed.missionSealedDigest `shouldBe` sha256Hex content
      removeFile source
      void (expectRight =<< verifyMissionSealedArchive store theMission sealed)
      archived <- ByteString.readFile (store.missionStoreDirectory </> "mission-0001" </> "archive" </> sealed.missionSealedName)
      archived `shouldBe` content

  it "reports a mismatch when the archived copy is not what the seal recorded" $
    withStore $ \root store -> do
      let source = root </> "child.log"
      ByteString.writeFile source "the original"
      sealed <- expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog source
      ByteString.writeFile (store.missionStoreDirectory </> "mission-0001" </> "archive" </> sealed.missionSealedName) "not the original"
      result <- verifyMissionSealedArchive store theMission sealed
      case result of
        Left message -> Text.unpack message `shouldSatisfy` isInfixOf "seal records"
        Right () -> expectationFailure "expected the verification to fail"

  it "leaves no sealed record behind when the copy never completed, and the next attempt succeeds" $
    withStore $ \root store -> do
      let source = root </> "child.log"
      ByteString.writeFile source "the whole stream"
      -- What an interruption between the copy and its rename leaves: a
      -- partial file in the archive and no record of a seal.
      let archiveDirectory = store.missionStoreDirectory </> "mission-0001" </> "archive"
      createDirectoryIfMissing True archiveDirectory
      ByteString.writeFile (archiveDirectory </> "session-a-event_stream.log.staged-9999-interrupted") "the who"
      beforehand <- expectRight =<< readMissionSealedArchives store theMission
      beforehand `shouldBe` []
      sealed <- expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog source
      void (expectRight =<< verifyMissionSealedArchive store theMission sealed)
      afterwards <- expectRight =<< readMissionSealedArchives store theMission
      map missionSealedSession afterwards `shouldBe` [MissionSessionId "session-a"]

  it "refuses to reseal an entry that already exists, and leaves it exactly as it was" $
    withStore $ \root store -> do
      let source = root </> "child.log"
      ByteString.writeFile source "the original"
      sealed <- expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog source
      ByteString.writeFile source "something else entirely"
      again <- sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog source
      case again of
        Left (MissionSealAlreadySealed session kind) -> do
          session `shouldBe` MissionSessionId "session-a"
          kind `shouldBe` MissionEventStreamLog
        other -> expectationFailure ("expected a refusal, got " <> show other)
      stored <- expectRight =<< readMissionSealedArchives store theMission
      map missionSealedDigest stored `shouldBe` [sealed.missionSealedDigest]
      archived <- ByteString.readFile (store.missionStoreDirectory </> "mission-0001" </> "archive" </> sealed.missionSealedName)
      archived `shouldBe` "the original"

  it "keeps a session's two log kinds as separate entries" $
    withStore $ \root store -> do
      let stream = root </> "stream.log"
          raw = root </> "raw.log"
      ByteString.writeFile stream "the stream"
      ByteString.writeFile raw "the provider's own log"
      void (expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog stream)
      void (expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionRawProviderLog raw)
      stored <- expectRight =<< readMissionSealedArchives store theMission
      sort (map missionSealedName stored) `shouldBe` ["session-a-event_stream.log", "session-a-raw_provider_log.log"]

  it "verifies the archive its own session and log kind name, never the filename a record carries" $
    withStore $ \root store -> do
      let source = root </> "child.log"
      ByteString.writeFile source "the original"
      sealed <- expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog source
      -- A seal record is durable data, so a forged one can name any path at
      -- all. Reading the file it names would hash whatever was there and
      -- report success against the digest sitting beside it.
      let elsewhere = root </> "elsewhere.log"
      ByteString.writeFile elsewhere "the forged content"
      sealed.missionSealedMission `shouldBe` theMission
      forM_
        [ "../../../../elsewhere.log",
          "session-b-event_stream.log",
          "session-a-raw_provider_log.log"
        ]
        $ \forged -> do
          result <-
            verifyMissionSealedArchive
              store
              theMission
              sealed
                { missionSealedName = forged,
                  missionSealedDigest = sha256Hex "the forged content",
                  missionSealedByteLength = fromIntegral (ByteString.length ("the forged content" :: ByteString.ByteString))
                }
          case result of
            Left message -> do
              Text.unpack message `shouldSatisfy` isInfixOf "rather than"
              Text.unpack message `shouldSatisfy` isInfixOf "session-a-event_stream.log"
            Right () -> expectationFailure ("expected " <> forged <> " to be refused")

  it "cannot have its committed archive altered by a losing concurrent reseal" $
    withStore $ \root store -> do
      -- Two processes sealing the same session's log at once. Both can see no
      -- seal record; the one that loses the seal must not have replaced the
      -- winner's archive on its way there, or the winner's digest stops
      -- verifying the file it names.
      let contents = [("first", "the first process's bytes"), ("second", "the second process's bytes")]
      forM_ contents $ \(name, body) -> ByteString.writeFile (root </> name <> ".log") body
      outcomes <- withMissionProbes (root </> "probes")
        [ MissionProbe
            { missionProbeName = name,
              missionProbeStore = store.missionStoreDirectory,
              missionProbeRepository = store.missionStoreRepository,
              missionProbeMission = theMission,
              missionProbeAction = MissionProbeSealLog (root </> name <> ".log") (MissionSessionId "session-a") MissionEventStreamLog,
              missionProbeGate = "both"
            }
        | (name, _) <- contents
        ]
        $ \probes -> do
          openMissionGate probes "both"
          mapM (sealOutcome probes . fst) contents
      let sealedDigests = [digest | MissionProbeSealed digest <- outcomes]
      length sealedDigests `shouldBe` 1
      length [() | MissionProbeSealRefused _ <- outcomes] `shouldBe` 1
      -- The archive holds exactly one of the two bodies, and it is the one
      -- the winning seal records.
      archived <- ByteString.readFile (missionRoot store </> "archive" </> "session-a-event_stream.log")
      map snd contents `shouldSatisfy` elem archived
      sealedDigests `shouldBe` [sha256Hex archived]
      stored <- expectRight =<< readMissionSealedArchives store theMission
      forM_ stored (\entry -> void (expectRight =<< verifyMissionSealedArchive store theMission entry))
      map missionSealedDigest stored `shouldBe` sealedDigests

  it "completes an archive an interrupted attempt published without a seal, and seals what is actually there" $
    withStore $ \root store -> do
      let source = root </> "child.log"
      ByteString.writeFile source "the bytes the first attempt published"
      sealed <- expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog source
      -- What a crash between publishing the archive and recording the seal
      -- leaves: an archive with nothing describing it.
      removeFile (missionRoot store </> "archive" </> "session-a-event_stream.seal.json")
      ByteString.writeFile source "different bytes entirely"
      again <- expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog source
      -- The archive is immutable, so the completing seal describes what is
      -- there rather than what this attempt was handed.
      again.missionSealedDigest `shouldBe` sealed.missionSealedDigest
      void (expectRight =<< verifyMissionSealedArchive store theMission again)
      archived <- ByteString.readFile (missionRoot store </> "archive" </> "session-a-event_stream.log")
      archived `shouldBe` "the bytes the first attempt published"

  it "refuses a seal record that belongs to another mission" $
    withStore $ \root store -> do
      let source = root </> "child.log"
      ByteString.writeFile source "the original"
      sealed <- expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog source
      result <- verifyMissionSealedArchive store theMission sealed {missionSealedMission = MissionId "mission-0002"}
      case result of
        Left message -> Text.unpack message `shouldSatisfy` isInfixOf "belongs to mission mission-0002"
        Right () -> expectationFailure "expected the verification to be refused"
      -- And one sitting in this mission's archive directory is refused on the
      -- way in rather than returned.
      void (expectRight =<< createMissionSpecification store (specificationFor (MissionRepository "coghex" "kanban") (MissionId "mission-0002") "another mission"))
      other <- expectRight =<< sealMissionLog (MissionStore store.missionStoreDirectory store.missionStoreRepository) (MissionId "mission-0002") (MissionSessionId "session-b") MissionEventStreamLog source
      renameFile
        (store.missionStoreDirectory </> "mission-0002" </> "archive" </> "session-b-event_stream.seal.json")
        (missionRoot store </> "archive" </> "session-b-event_stream.seal.json")
      other.missionSealedMission `shouldBe` MissionId "mission-0002"
      listed <- readMissionSealedArchives store theMission
      case listed of
        Left message -> Text.unpack message `shouldSatisfy` isInfixOf "mission-0002"
        Right entries -> expectationFailure ("expected a refusal, got " <> show (map missionSealedSession entries))

  it "reports a source it cannot read rather than recording an empty archive" $
    withStore $ \root store -> do
      result <- sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog (root </> "not-there.log")
      case result of
        Left (MissionSealSourceUnreadable path _) -> path `shouldBe` (root </> "not-there.log")
        other -> expectationFailure ("expected a refusal, got " <> show other)
      stored <- expectRight =<< readMissionSealedArchives store theMission
      stored `shouldBe` []

-- * Archive and delete

dispositionSpec :: Spec
dispositionSpec = describe "archiving and deleting a mission" $ do
  it "archives a terminal mission, keeping its whole history readable" $
    withStore $ \_ store -> do
      void (expectRight =<< createMissionSpecification store theSpecification)
      void (expectRight =<< writeMissionSnapshot store (snapshotWith MissionCompleted [stepRecord MissionStepSucceeded] [] []))
      void (expectRight =<< recordMissionEvent store (eventNamed "finished"))
      void (expectRight =<< archiveMission store theMission)
      snapshot <- expectPresent =<< readMissionSnapshot store theMission
      snapshot.missionSnapshotArchive.missionArchivePresentation `shouldBe` MissionPresentationArchived
      specification <- expectPresent =<< readMissionSpecification store theMission
      specification.missionSpecificationRequest `shouldBe` "solve the approved backlog"
      (records, _) <- expectRight =<< readMissionJournal store theMission 0
      kindsOf records `shouldBe` ["finished"]

  it "refuses to archive a mission that has not finished" $
    withStore $ \_ store -> do
      void (expectRight =<< writeMissionSnapshot store runningSnapshot)
      result <- archiveMission store theMission
      refusalKinds result `shouldBe` ["not-terminal"]

  it "deletes a plain terminal mission" $
    withStore $ \_ store -> do
      void (expectRight =<< createMissionSpecification store theSpecification)
      void (expectRight =<< writeMissionSnapshot store (snapshotWith MissionCompleted [stepRecord MissionStepSucceeded] [sessionNode "session-a" Nothing settled] []))
      void (expectRight =<< deleteMission store theMission)
      remaining <- listMissions store
      remaining `shouldBe` []

  it "refuses to delete a mission that has not finished" $
    withStore $ \_ store -> do
      void (expectRight =<< writeMissionSnapshot store runningSnapshot)
      result <- deleteMission store theMission
      refusalKinds result `shouldBe` ["not-terminal"]

  it "refuses to delete a terminal mission whose session is recorded as still running" $
    withStore $ \_ store -> do
      void (expectRight =<< writeMissionSnapshot store (snapshotWith MissionCompleted [] [liveSession] []))
      result <- deleteMission store theMission
      refusalKinds result `shouldBe` ["live-session"]

  it "refuses to delete a terminal mission whose session left no evidence at all" $
    withStore $ \_ store -> do
      void (expectRight =<< writeMissionSnapshot store (snapshotWith MissionCompleted [] [sessionNode "session-a" Nothing Nothing] []))
      result <- deleteMission store theMission
      refusalKinds result `shouldBe` ["unverifiable-session"]

  it "refuses to delete a terminal mission whose session never learned how it ended" $
    withStore $ \_ store -> do
      void (expectRight =<< writeMissionSnapshot store (snapshotWith MissionCompleted [] [sessionNode "session-a" Nothing unresolved] []))
      result <- deleteMission store theMission
      refusalKinds result `shouldBe` ["unverifiable-session"]

  it "refuses to delete a terminal mission with a step whose outcome is unknown" $
    withStore $ \_ store -> do
      void (expectRight =<< writeMissionSnapshot store (snapshotWith MissionCompleted [stepRecord MissionStepOutcomeUnknown] [] []))
      result <- deleteMission store theMission
      refusalKinds result `shouldBe` ["outcome-unknown-step"]

  it "refuses to delete the sole recovery record for a retained worktree" $
    withStore $ \_ store -> do
      let worktree =
            MissionWorktreeDisposition
              { missionWorktreePath = "/home/someone/worktrees/coghex/kanban/issue-592",
                missionWorktreeState = MissionWorktreeRetained,
                missionWorktreeStep = Just (MissionStepId "solve-592"),
                missionWorktreeSoleRecoveryRecord = True
              }
      void (expectRight =<< writeMissionSnapshot store (snapshotWith MissionCompleted [] [] [worktree]))
      result <- deleteMission store theMission
      refusalKinds result `shouldBe` ["sole-recovery-record"]

  it "reports every reason it refused, not only the first" $
    withStore $ \_ store -> do
      let worktree =
            MissionWorktreeDisposition
              { missionWorktreePath = "/home/someone/worktrees/coghex/kanban/issue-592",
                missionWorktreeState = MissionWorktreeRetained,
                missionWorktreeStep = Nothing,
                missionWorktreeSoleRecoveryRecord = True
              }
      void (expectRight =<< writeMissionSnapshot store (snapshotWith MissionRunning [stepRecord MissionStepOutcomeUnknown] [sessionNode "session-a" Nothing unresolved] [worktree]))
      result <- deleteMission store theMission
      sort (refusalKinds result) `shouldBe` sort ["not-terminal", "unverifiable-session", "outcome-unknown-step", "sole-recovery-record"]

  it "leaves the mission on disk whenever it refuses" $
    withStore $ \_ store -> do
      void (expectRight =<< createMissionSpecification store theSpecification)
      void (expectRight =<< writeMissionSnapshot store runningSnapshot)
      void (deleteMission store theMission)
      remaining <- listMissions store
      remaining `shouldBe` [theMission]

refusalKinds :: Either [MissionDispositionRefusal] () -> [String]
refusalKinds result = case result of
  Right () -> []
  Left refusals -> map kind refusals
  where
    kind refusal = case refusal of
      MissionDispositionUnreadable _ -> "unreadable"
      MissionDispositionNotTerminal _ -> "not-terminal"
      MissionDispositionLiveSession _ -> "live-session"
      MissionDispositionUnverifiableSession _ -> "unverifiable-session"
      MissionDispositionOutcomeUnknownStep _ -> "outcome-unknown-step"
      MissionDispositionSoleRecoveryRecord _ -> "sole-recovery-record"

-- * Enumeration

enumerationSpec :: Spec
enumerationSpec = describe "enumerating a repository's missions" $ do
  it "lists them without reading a single journal" $
    withStore $ \_ store -> do
      forM_ ["mission-0001", "mission-0002"] $ \name ->
        void (expectRight =<< createMissionSpecification store (specificationFor (MissionRepository "coghex" "kanban") (MissionId (Text.pack name)) "a mission"))
      void (expectRight =<< recordMissionEvent store (eventNamed "first"))
      -- A journal nothing can read. Enumeration still lists its mission,
      -- which it could not do if it opened one.
      setFileMode (store.missionStoreDirectory </> "mission-0001" </> "events.jsonl") 0o000
      missions <- listMissions store
      missions `shouldBe` [MissionId "mission-0001", MissionId "mission-0002"]

  it "ignores a store entry that is not a plain directory, rather than following it" $
    withStore $ \root store -> do
      void (expectRight =<< createMissionSpecification store theSpecification)
      let elsewhere = root </> "elsewhere"
      createDirectoryIfMissing True (elsewhere </> "not-a-mission")
      createSymbolicLink elsewhere (store.missionStoreDirectory </> "a-link")
      createSymbolicLink (root </> "nowhere") (store.missionStoreDirectory </> "a-dangling-link")
      ByteString.writeFile (store.missionStoreDirectory </> "a-file") "not a mission either"
      missions <- listMissions store
      missions `shouldBe` [theMission]

-- * The session tree

sessionTreeSpec :: Spec
sessionTreeSpec = describe "the session tree" $ do
  it "accepts a tree with several roots and a chain of children" $
    validateMissionSessionTree
      theMission
      [ sessionNode "root-a" Nothing settled,
        sessionNode "root-b" Nothing settled,
        sessionNode "child" (Just (MissionSessionId "root-a")) settled,
        sessionNode "grandchild" (Just (MissionSessionId "child")) settled
      ]
      `shouldBe` Right ()

  it "rejects two sessions sharing one identity" $
    validateMissionSessionTree theMission [sessionNode "session-a" Nothing settled, sessionNode "session-a" Nothing settled]
      `shouldBe` Left (MissionSessionDuplicate (MissionSessionId "session-a"))

  it "rejects a child whose parent this mission has no session for" $
    validateMissionSessionTree theMission [sessionNode "child" (Just (MissionSessionId "absent")) settled]
      `shouldBe` Left (MissionSessionMissingParent (MissionSessionId "child") (MissionSessionId "absent"))

  it "rejects a child whose parent belongs to another mission" $ do
    let foreignParent = (sessionNode "parent" Nothing settled) {missionSessionMission = MissionId "mission-0002"}
    validateMissionSessionTree theMission [foreignParent, sessionNode "child" (Just (MissionSessionId "parent")) settled]
      `shouldBe` Left (MissionSessionCrossMissionParent (MissionSessionId "child") (MissionSessionId "parent"))

  it "rejects a node that records a different mission as its own" $ do
    let foreign' = (sessionNode "stranger" Nothing settled) {missionSessionMission = MissionId "mission-0002"}
    validateMissionSessionTree theMission [foreign']
      `shouldBe` Left (MissionSessionForeign (MissionSessionId "stranger") (MissionId "mission-0002"))

  it "rejects a lineage that never reaches a root" $
    validateMissionSessionTree
      theMission
      [ sessionNode "a" (Just (MissionSessionId "b")) settled,
        sessionNode "b" (Just (MissionSessionId "a")) settled
      ]
      `shouldBe` Left (MissionSessionCycle [MissionSessionId "a", MissionSessionId "b"])

  it "calls a session with no observation and no recorded process unverifiable rather than finished" $
    missionSessionDisposition (sessionNode "session-a" Nothing Nothing) `shouldBe` MissionSessionUnverifiable

  it "calls a session whose end was never established unverifiable" $
    missionSessionDisposition (sessionNode "session-a" Nothing unresolved) `shouldBe` MissionSessionUnverifiable

  it "calls an observed exit settled" $
    missionSessionDisposition (sessionNode "session-a" Nothing settled) `shouldBe` MissionSessionSettled

  it "is enforced by the writer: a snapshot whose sessions are not a tree is refused" $
    withStore $ \_ store -> do
      let looping =
            snapshotWith
              MissionRunning
              []
              [ sessionNode "a" (Just (MissionSessionId "b")) settled,
                sessionNode "b" (Just (MissionSessionId "a")) settled
              ]
              []
      written <- writeMissionSnapshot store looping
      case written of
        Left message -> do
          Text.unpack message `shouldSatisfy` isInfixOf "mission-0001"
          Text.unpack message `shouldSatisfy` isInfixOf "never reaches a root"
        Right () -> expectationFailure "expected the snapshot write to be refused"
      stored <- readMissionSnapshot store theMission
      stored `shouldBe` MissionAbsent

  it "says what it rejected, in each of the five ways a node set is not a tree" $
    map
      (fmap missionSessionTreeErrorMessage . flipEither . validateMissionSessionTree theMission)
      [ [sessionNode "a" Nothing settled, sessionNode "a" Nothing settled],
        [sessionNode "child" (Just (MissionSessionId "absent")) settled],
        [(sessionNode "parent" Nothing settled) {missionSessionMission = MissionId "other"}, sessionNode "child" (Just (MissionSessionId "parent")) settled],
        [(sessionNode "stranger" Nothing settled) {missionSessionMission = MissionId "other"}],
        [sessionNode "a" (Just (MissionSessionId "b")) settled, sessionNode "b" (Just (MissionSessionId "a")) settled]
      ]
      `shouldBe` map
        Just
        [ "two sessions share the identity \"a\"",
          "session \"child\" names the parent \"absent\", which this mission has no session for",
          "session \"child\" names the parent \"parent\", which belongs to another mission",
          "session \"stranger\" records the mission \"other\" rather than the one it was read for",
          "the sessions \"a\", \"b\" form a lineage that never reaches a root"
        ]

flipEither :: Either failure () -> Maybe failure
flipEither result = case result of
  Left failure -> Just failure
  Right () -> Nothing

-- * The recorded vocabularies

vocabularySpec :: Spec
vocabularySpec = describe "the durable lifecycle vocabularies" $ do
  it "spells every mission lifecycle the way the record does" $
    map missionLifecycleTag missionLifecycles
      `shouldBe` [ "planned",
                   "running",
                   "waiting_input",
                   "waiting_barrier",
                   "waiting_capacity",
                   "paused",
                   "interrupted",
                   "recovering",
                   "completed",
                   "failed",
                   "cancelled"
                 ]

  it "spells every step lifecycle the way the record does" $
    map missionStepLifecycleTag missionStepLifecycles
      `shouldBe` [ "pending",
                   "dispatching",
                   "running",
                   "outcome_unknown",
                   "waiting_capacity",
                   "interrupted",
                   "orphaned",
                   "recovering",
                   "succeeded",
                   "needs_changes",
                   "needs_input",
                   "failed",
                   "cancelled"
                 ]

  it "calls exactly the three finished mission lifecycles terminal" $
    [missionLifecycleTag lifecycle | lifecycle <- missionLifecycles, missionLifecycleIsTerminal lifecycle]
      `shouldBe` ["completed", "failed", "cancelled"]

  it "calls exactly the three finished step lifecycles terminal, leaving the two that are waiting out" $
    [missionStepLifecycleTag lifecycle | lifecycle <- missionStepLifecycles, missionStepLifecycleIsTerminal lifecycle]
      `shouldBe` ["succeeded", "failed", "cancelled"]

  it "says why a disposition was refused, naming what it was about" $ do
    missionDispositionRefusalMessage (MissionDispositionNotTerminal "running")
      `shouldBe` "the mission is running rather than finished"
    missionDispositionRefusalMessage (MissionDispositionLiveSession (MissionSessionId "session-a"))
      `shouldBe` "session session-a is recorded as still running"
    missionDispositionRefusalMessage (MissionDispositionUnverifiableSession (MissionSessionId "session-a"))
      `shouldBe` "session session-a cannot be proven to have finished"
    missionDispositionRefusalMessage (MissionDispositionOutcomeUnknownStep (MissionStepId "solve-592"))
      `shouldBe` "step solve-592 never learned its outcome"
    missionDispositionRefusalMessage (MissionDispositionSoleRecoveryRecord "/worktrees/issue-592")
      `shouldBe` "this is the only record of the retained worktree /worktrees/issue-592"

  it "says why a seal was refused, naming the session and the log kind" $
    missionSealFailureMessage (MissionSealAlreadySealed (MissionSessionId "session-a") MissionRawProviderLog)
      `shouldBe` "the raw_provider_log of session session-a is already sealed"

-- * Requirement 15

noProcessSpec :: Spec
noProcessSpec = describe "what the store runs" $
  it "completes every operation without spawning a single external process" $
    withStore $ \root store -> do
      -- Requirement 15 of issue #592 is that this slice spawns nothing, and
      -- the whole of it rests on that: the hand-written SHA-256 exists rather
      -- than a call to shasum, and the lease asks the kernel about its holder
      -- rather than reading a process snapshot, which runs `ps`. A recording
      -- fake for each executable the surrounding code could reach turns that
      -- claim into something a later change cannot quietly break — the log is
      -- written by the fake itself, so any spawn at all leaves evidence.
      let binaries = root </> "bin"
          spawnLog = root </> "spawned.log"
      createDirectoryIfMissing True binaries
      forM_ ["ps", "gh", "git", "codex", "claude", "shasum", "sha256sum", "sh"] $ \name -> do
        ByteString.writeFile
          (binaries </> name)
          (ByteStringChar.pack ("#!/bin/sh\nprintf '%s %s\\n' " <> name <> " \"$*\" >> " <> spawnLog <> "\n"))
        setFileMode (binaries </> name) 0o700
      originalPath <- getEnv "PATH"
      withEnvironmentValue "PATH" (binaries <> ":" <> originalPath) $ do
        void (expectRight =<< createMissionSpecification store theSpecification)
        void (expectRight =<< writeMissionSnapshot store runningSnapshot)
        void (expectRight =<< recordMissionEvent store (eventNamed "planned"))
        void (expectRight =<< readMissionJournal store theMission 0)
        void (readMissionSpecification store theMission)
        void (readMissionSnapshot store theMission)
        let source = root </> "child.log"
        ByteString.writeFile source "a child's stream"
        sealed <- expectRight =<< sealMissionLog store theMission (MissionSessionId "session-a") MissionEventStreamLog source
        void (expectRight =<< verifyMissionSealedArchive store theMission sealed)
        void (expectRight =<< readMissionSealedArchives store theMission)
        void (listMissions store)
        acquisition <- acquireMissionLease store theMission
        contended <- acquireMissionLease store theMission
        case contended of
          MissionLeaseHeld _ -> pure ()
          other -> expectationFailure ("expected the second acquisition to be refused, got " <> show other)
        case acquisition of
          MissionLeaseAcquired lease -> releaseMissionLease lease
          other -> expectationFailure ("expected to acquire the lease, got " <> show other)
        void (expectRight =<< writeMissionSnapshot store (snapshotWith MissionCompleted [] [] []))
        void (archiveMission store theMission)
        void (deleteMission store theMission)
      spawned <- doesFileExist spawnLog
      recorded <- if spawned then ByteStringChar.unpack <$> ByteString.readFile spawnLog else pure ""
      recorded `shouldBe` ""
      -- The control. Without it an empty log would be just as consistent with
      -- a fixture that could never have recorded anything, and the example
      -- above would pass while asserting nothing. This is the very call the
      -- lease used to make, and the fixture catches it.
      withEnvironmentValue "PATH" (binaries <> ":" <> originalPath) (void defaultProcessSnapshot)
      controlled <- ByteStringChar.unpack <$> ByteString.readFile spawnLog
      controlled `shouldSatisfy` isInfixOf "ps"

-- * The digest

digestSpec :: Spec
digestSpec = describe "the sealed archive's digest" $ do
  it "agrees with FIPS 180-4's own vectors" $ do
    sha256Hex "" `shouldBe` "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    sha256Hex "abc" `shouldBe` "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    sha256Hex "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
      `shouldBe` "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"

  it "agrees on the message lengths either side of a padding block boundary" $ do
    sha256Hex (ByteStringChar.replicate 55 'a') `shouldBe` "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"
    sha256Hex (ByteStringChar.replicate 56 'a') `shouldBe` "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
    sha256Hex (ByteStringChar.replicate 64 'a') `shouldBe` "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
    sha256Hex (ByteStringChar.replicate 1000 'a') `shouldBe` "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
