{-# LANGUAGE OverloadedStrings #-}

-- | The repository mission scheduler: what one pass admits, what it refuses,
-- what it reports, and who it tells (issue #666).
--
-- Every example runs against a real mission store under a temporary
-- @$XDG_STATE_HOME@. The two things a pass does outside its own arithmetic —
-- advancing a mission through a child, and running an operator's notification
-- command — are the injected 'MissionSchedulerSeams', so the admission rule,
-- the lease decision, the disposition derivation and the whole durable
-- suppression record are the production code in every example below and
-- nothing is spawned.
--
-- Three groups deliberately do spawn, and each proves something no staged seam
-- can. 'advanceMissions' is driven against a fake @kanban@ so that the child's
-- working directory, its arguments, its standard input, and the isolation of
-- its output are observed rather than asserted about. The attention examples
-- drive 'applyMissionLifecycle' — the one function every real transition into
-- @waiting_input@ goes through — rather than constructing a snapshot with an
-- attention record already in it, because \"the transition creates the
-- identity\" is precisely what a hand-built record would assume. And the
-- notification examples create the suppression record through
-- 'attemptMissionNotification' itself, so an at-most-once claim is made about
-- the mechanism rather than about a fixture.
module Spec.Mission.Scheduler (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (IOException, SomeException, try)
import Control.Monad (forM_, void)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, nub, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime, secondsToDiffTime)
import Kanban.Config
  ( MissionNotificationCommand (..),
    MissionNotificationConfig (..),
    MissionsConfig (..),
    RawConfig (..),
    decodeConfigText,
    defaultMissionNotificationConfig,
    defaultMissionsConfig,
    missionNotificationRefusal,
  )
import Kanban.CLI (Options (..))
import Kanban.Domain (Repository (..))
import Kanban.Mission
import Spec.Support.Fixtures (testOptions)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hClose, hPutStrLn, openFile)
import System.Posix.Files (setFileMode)
import System.Posix.Signals (nullSignal, signalProcess)
import Test.Hspec

spec :: Spec
spec = describe "the repository mission scheduler" $ do
  admissionSpec
  leaseSpec
  dispositionSpec
  passContractSpec
  childResultSpec
  childExecutionSpec
  attentionSpec
  notificationSpec
  configurationSpec

-- ---------------------------------------------------------------------------
-- Admission
-- ---------------------------------------------------------------------------

admissionSpec :: Spec
admissionSpec = describe "which missions one pass admits" $ do
  -- Requirements 2 and 3.
  it "admits at most two of three runnable missions" $
    withStore $ \store -> do
      forM_ ["mission-a", "mission-b", "mission-c"] $ \mission ->
        putMission store mission MissionRunning
      (report, advanced) <- passWith store defaultMissionsConfig id
      readIORef advanced `shouldReturn` [[MissionId "mission-a", MissionId "mission-b"]]
      map (.missionDispositionMission) report.missionPassAdmitted
        `shouldBe` [MissionId "mission-a", MissionId "mission-b"]
      missionAdmissionCeiling `shouldBe` 2

  -- Requirement 2's exclusions, one lifecycle at a time rather than as a set,
  -- so a rule that admitted one of them would name which.
  it "advances no terminal, paused, or waiting mission" $
    forM_ notRunnable $ \lifecycle ->
      withStore $ \store -> do
        putMission store "mission-a" lifecycle
        (report, advanced) <- passWith store defaultMissionsConfig id
        seen <- readIORef advanced
        (lifecycle, seen) `shouldBe` (lifecycle, [])
        (lifecycle, report.missionPassAdmitted) `shouldBe` (lifecycle, [])
        (lifecycle, report.missionPassTermination) `shouldBe` (lifecycle, MissionPassCompleted)

  -- A pause is recorded on the snapshot's pause record as well as through the
  -- @paused@ lifecycle, and either alone has to exclude the mission: a mission
  -- somebody paused while it was running carries the request before the
  -- lifecycle catches up.
  it "advances no mission whose pause was requested" $
    withStore $ \store -> do
      putMissionWith store "mission-a" MissionRunning $ \snapshot ->
        snapshot {missionSnapshotPause = MissionPause {missionPauseRequested = True, missionPauseReason = Just "by hand", missionPauseAt = Nothing}}
      (_, advanced) <- passWith store defaultMissionsConfig id
      readIORef advanced `shouldReturn` []

  -- Requirement 13: an idle pass launches nothing at all, which is what makes
  -- \"and makes no GitHub request\" true by construction rather than by
  -- inspection — the only GitHub a pass can reach is inside a child.
  it "launches nothing when no mission is runnable" $
    withStore $ \store -> do
      putMission store "mission-a" MissionCompleted
      putMission store "mission-b" MissionWaitingBarrier
      (report, advanced) <- passWith store defaultMissionsConfig id
      readIORef advanced `shouldReturn` []
      report.missionPassAdmitted `shouldBe` []

notRunnable :: [MissionLifecycle]
notRunnable =
  [ MissionCompleted,
    MissionFailed,
    MissionCancelled,
    MissionPaused,
    MissionWaitingInput,
    MissionWaitingBarrier,
    MissionWaitingCapacity
  ]

-- ---------------------------------------------------------------------------
-- The advancement lease
-- ---------------------------------------------------------------------------

leaseSpec :: Spec
leaseSpec = describe "a mission another process is already advancing" $ do
  -- Requirement 2, and the review's amendment: a skipped mission must not eat
  -- one of the two slots, or a repository with a dashboard attached to one
  -- mission would advance one fewer than it can.
  it "is skipped without consuming an admission slot" $
    withStore $ \store -> do
      forM_ ["mission-a", "mission-b", "mission-c"] $ \mission ->
        putMission store mission MissionRunning
      (report, advanced) <- passWith store defaultMissionsConfig $ \seams ->
        seams {missionSchedulerLeaseHeld = \mission -> pure (if mission == MissionId "mission-a" then Just "held" else Nothing)}
      readIORef advanced `shouldReturn` [[MissionId "mission-b", MissionId "mission-c"]]
      map (.missionDispositionMission) report.missionPassAdmitted
        `shouldBe` [MissionId "mission-b", MissionId "mission-c"]

  -- The read-only decision is the acquisition's own, so an owner whose
  -- liveness cannot be established keeps the lease here exactly as it does
  -- there. Driven through the real store and the real owner record, with only
  -- the kernel probe staged.
  it "counts a holder that cannot be checked as holding it" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      acquired <- acquireMissionLease store (MissionId "mission-a")
      case acquired of
        MissionLeaseAcquired _ -> do
          missionLeaseHeldWith (const (pure (MissionHolderUndecidable "probe failed"))) store (MissionId "mission-a")
            `shouldReturn` Just "mission mission-a is already being advanced: its holder could not be checked (probe failed)"
          held <- missionLeaseHeldWith (const (pure MissionHolderGone)) store (MissionId "mission-a")
          held `shouldBe` Nothing
        other -> expectationFailure ("the lease was not acquired: " <> show other)

  it "reads an unheld mission as free" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      missionLeaseHeld store (MissionId "mission-a") `shouldReturn` Nothing

  -- Only the kernel saying there is nothing at the path admits the mission.
  -- A lease this account cannot even look at is a lease whose occupancy is
  -- undecided, and an undecided lease is held — the same direction an
  -- unverifiable holder fails in. Staged by making the mission's own directory
  -- unsearchable, which is what an `lstat` of the lease inside it meets.
  it "counts a lease it cannot inspect as held" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      case missionDirectory store.missionStoreDirectory (MissionId "mission-a") of
        Left message -> expectationFailure (Text.unpack message)
        Right directory -> do
          setFileMode directory 0o000
          held <- missionLeaseHeld store (MissionId "mission-a")
          setFileMode directory 0o700
          case held of
            Nothing -> expectationFailure "an uninspectable lease was read as free"
            Just reason -> ("could not be inspected" `Text.isInfixOf` reason) `shouldBe` True

  it "does not admit a mission whose lease it cannot inspect" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      putMission store "mission-b" MissionRunning
      case missionDirectory store.missionStoreDirectory (MissionId "mission-a") of
        Left message -> expectationFailure (Text.unpack message)
        Right directory -> do
          setFileMode directory 0o000
          (_, advanced) <- passWith store defaultMissionsConfig id
          setFileMode directory 0o700
          readIORef advanced `shouldReturn` [[MissionId "mission-b"]]

  -- Requirement 6. The lease was free when the mission was selected and taken
  -- by somebody else before the child started, so the child refuses; that is
  -- contention between two correct processes and the pass says so rather than
  -- failing.
  it "reports a lease lost after selection as contention rather than failure" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      (report, _) <- passWith store defaultMissionsConfig $ \seams ->
        seams
          { missionSchedulerAdvance = \admitted ->
              pure [(mission, Right (childRefusal mission MissionChildAlreadyAdvancing)) | mission <- admitted]
          }
      map (.missionDispositionValue) report.missionPassAdmitted `shouldBe` [MissionDispositionLeaseRefused]
      report.missionPassTermination `shouldBe` MissionPassCompleted
      missionPassExitCode report.missionPassTermination `shouldBe` 0

  it "reports every other typed refusal as a refusal too" $
    forM_ [MissionChildUnknownMission, MissionChildUnreadableRecord, MissionChildRepositoryMismatched, MissionChildIdentifierUnusable, MissionChildStoreUnusable] $ \refusal ->
      withStore $ \store -> do
        putMission store "mission-a" MissionRunning
        (report, _) <- passWith store defaultMissionsConfig $ \seams ->
          seams {missionSchedulerAdvance = \admitted -> pure [(mission, Right (childRefusal mission refusal)) | mission <- admitted]}
        (refusal, map (.missionDispositionValue) report.missionPassAdmitted) `shouldBe` (refusal, [MissionDispositionRefused])
        (refusal, report.missionPassTermination) `shouldBe` (refusal, MissionPassCompleted)

-- ---------------------------------------------------------------------------
-- Dispositions
-- ---------------------------------------------------------------------------

dispositionSpec :: Spec
dispositionSpec = describe "what a pass makes of a child that ran" $ do
  -- Requirement 4's \"and durable mission records\": where the mission got to
  -- is read from the snapshot the child left, never from the child's word for
  -- it. The child reports the same thing in all three examples.
  it "classifies an advanced child from the snapshot it left behind" $
    forM_ [(MissionRunning, MissionDispositionAdvanced), (MissionCompleted, MissionDispositionSettled), (MissionWaitingInput, MissionDispositionBlocked)] $ \(settledAs, expected) ->
      withStore $ \store -> do
        putMission store "mission-a" MissionRunning
        (report, _) <- passWith store defaultMissionsConfig $ \seams ->
          seams
            { missionSchedulerAdvance = \admitted -> do
                forM_ admitted $ \mission -> putMission store (Text.unpack mission.unMissionId) settledAs
                pure [(mission, Right (childAdvanced mission)) | mission <- admitted]
            }
        (settledAs, map (.missionDispositionValue) report.missionPassAdmitted) `shouldBe` (settledAs, [expected])

  it "fails the pass when a child failed" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      (report, _) <- passWith store defaultMissionsConfig $ \seams ->
        seams {missionSchedulerAdvance = \admitted -> pure [(mission, Left "the child died") | mission <- admitted]}
      map (.missionDispositionValue) report.missionPassAdmitted `shouldBe` [MissionDispositionFailed]
      report.missionPassTermination `shouldBe` MissionPassFailed
      missionPassExitCode report.missionPassTermination `shouldBe` 1

  -- A child claiming to have advanced a mission whose snapshot then will not
  -- read is two records contradicting each other. Reporting it as an advance
  -- would put a mission nobody can locate behind a green pass.
  it "fails a child that advanced a mission whose snapshot then vanished" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      (report, _) <- passWith store defaultMissionsConfig $ \seams ->
        seams
          { missionSchedulerAdvance = \admitted -> do
              forM_ admitted (removeSnapshot store)
              pure [(mission, Right (childAdvanced mission)) | mission <- admitted]
          }
      map (.missionDispositionValue) report.missionPassAdmitted `shouldBe` [MissionDispositionFailed]
      report.missionPassTermination `shouldBe` MissionPassFailed

  it "names exactly one failing disposition" $
    filter missionDispositionIsFailure missionDispositions `shouldBe` [MissionDispositionFailed]

  -- §16's silence rule covers a record that is *absent* — missing, or written
  -- under a version this release does not know. A record that is there and
  -- will not decode is mission state nobody can account for, and a pass that
  -- dropped it would report a healthy idle repository over a mission that may
  -- be mid-flight.
  it "fails the pass on a snapshot that will not decode" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      corruptSnapshot store (MissionId "mission-a")
      (report, advanced) <- passWith store defaultMissionsConfig id
      readIORef advanced `shouldReturn` []
      report.missionPassTermination `shouldBe` MissionPassFailed
      ("unreadable snapshot" `Text.isInfixOf` report.missionPassDetail) `shouldBe` True

  -- Written by editing the file rather than through 'writeMissionSnapshot',
  -- because that writer refuses to produce this record at all -- which is the
  -- point. A snapshot naming another repository arrives by restore, by a
  -- directory somebody copied, or by a repository that was renamed, and the
  -- reader's refusal exists for exactly those. Staging it through the writer
  -- would be staging a state this release cannot reach.
  it "fails the pass on a snapshot recorded against another repository" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      disownSnapshot store (MissionId "mission-a")
      (report, _) <- passWith store defaultMissionsConfig id
      report.missionPassTermination `shouldBe` MissionPassFailed

  -- Enumeration, not decoding. `listMissions` reads a store directory it could
  -- not list as an empty one, which is the right answer for a caller looking
  -- for a mission and the wrong one for a pass reporting on a repository: it
  -- would exit zero over "0 of 0 missions" while every mission in there was
  -- unreachable.
  it "fails the pass on a store directory it cannot enumerate" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      setFileMode store.missionStoreDirectory 0o000
      (report, advanced) <- passWith store defaultMissionsConfig id
      setFileMode store.missionStoreDirectory 0o700
      readIORef advanced `shouldReturn` []
      report.missionPassTermination `shouldBe` MissionPassFailed
      ("could not be listed" `Text.isInfixOf` report.missionPassDetail) `shouldBe` True

  -- And an identifier the store will not resolve to a root at all: a mission
  -- recorded under both the current and the pre-#615 ambiguous root is
  -- refused rather than addressed, and `listMissions` drops it.
  it "fails the pass on a mission whose root cannot be resolved" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      stageRootCollision store (MissionId "mission-a")
      (report, _) <- passWith store defaultMissionsConfig id
      report.missionPassTermination `shouldBe` MissionPassFailed
      report.missionPassAdmitted `shouldBe` []

  -- The negative control: an absent snapshot really is silent, so the examples
  -- above are about decoding and enumeration rather than about a quiet store.
  it "stays completed when a listed mission has no snapshot at all" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      removeSnapshot store (MissionId "mission-a")
      (report, _) <- passWith store defaultMissionsConfig id
      report.missionPassTermination `shouldBe` MissionPassCompleted
      report.missionPassAdmitted `shouldBe` []

-- ---------------------------------------------------------------------------
-- The pass contract
-- ---------------------------------------------------------------------------

passContractSpec :: Spec
passContractSpec = describe "the pass report" $ do
  -- Requirements 7 and 9, and the review's exit-status mirror: the three
  -- terminations, the three statuses, and the one function that maps between
  -- them.
  it "pins its schema, its version, and its exit statuses" $ do
    missionPassSchema `shouldBe` "kanban-mission-scheduler-pass"
    missionPassVersion `shouldBe` 1
    map missionPassTerminationTag missionPassTerminations `shouldBe` ["completed", "refused", "failed"]
    map missionPassExitCode missionPassTerminations `shouldBe` [0, 2, 1]

  it "pins the disposition and notification vocabularies" $ do
    map missionDispositionTag missionDispositions
      `shouldBe` ["advanced", "settled", "blocked", "lease_refused", "refused", "failed"]
    map missionNotificationStateTag missionNotificationStates
      `shouldBe` [ "disabled",
                   "suppressed",
                   "completed",
                   "failed",
                   "timed_out",
                   "launch_failed",
                   "uncertain",
                   "recording_failed",
                   "unresolved"
                 ]

  it "carries the repository, the admitted missions, and the attention it saw" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      putMissionWith store "mission-b" MissionWaitingInput $ \snapshot ->
        snapshot {missionSnapshotAttention = Just (attentionRecord (MissionId "mission-b"))}
      (report, _) <- passWith store defaultMissionsConfig id
      report.missionPassRepository `shouldBe` "coghex/kanban"
      map (.missionDispositionMission) report.missionPassAdmitted `shouldBe` [MissionId "mission-a"]
      map (.missionAttentionRecordMission) report.missionPassAttention `shouldBe` [MissionId "mission-b"]
      let encoded = ByteString.unpack (LazyByteString.toStrict (encodeMissionPassReport report))
      forM_ ["\"schema\"", "\"version\"", "\"repository\"", "\"termination\"", "\"admitted\"", "\"attention\"", "\"started_at\"", "\"finished_at\""] $ \field ->
        (field, field `isInfixOf` encoded) `shouldBe` (field, True)

  it "narrates to a list that never carries the document" $
    withStore $ \store -> do
      putMission store "mission-a" MissionRunning
      (report, _) <- passWith store defaultMissionsConfig id
      let narration = Text.unpack (Text.unlines (missionPassNarration report))
      ("\"schema\"" `isInfixOf` narration) `shouldBe` False
      ("mission scheduler pass for coghex/kanban" `isInfixOf` narration) `shouldBe` True

-- ---------------------------------------------------------------------------
-- The child result document
-- ---------------------------------------------------------------------------

childResultSpec :: Spec
childResultSpec = describe "the child result document" $ do
  it "pins its schema and version" $ do
    missionChildResultSchema `shouldBe` "kanban-mission-child-result"
    missionChildResultVersion `shouldBe` 1
    map missionChildOutcomeTag missionChildOutcomes `shouldBe` ["advanced", "refused", "failed"]
    sort (map missionChildRefusalTag missionChildRefusals)
      `shouldBe` sort
        [ "already_advancing",
          "unknown_mission",
          "unreadable_record",
          "repository_mismatched",
          "identifier_unusable",
          "store_unusable"
        ]

  it "round-trips every outcome it can carry" $ do
    forM_ missionChildRefusals $ \refusal ->
      decodeMissionChildResult (LazyByteString.toStrict (encodeMissionChildResult (childRefusal (MissionId "mission-a") refusal)))
        `shouldBe` Right (childRefusal (MissionId "mission-a") refusal)
    decodeMissionChildResult (LazyByteString.toStrict (encodeMissionChildResult (childAdvanced (MissionId "mission-a"))))
      `shouldBe` Right (childAdvanced (MissionId "mission-a"))

  -- Requirement 9's refusals, one malformed document at a time. None of them
  -- may decode: a reader that accepted any of these would be acting on a
  -- document it could not have understood.
  it "refuses every shape it was not built to read" $
    forM_ malformedChildResults $ \(label, document) -> do
      let decoded = decodeMissionChildResult (ByteString.pack document)
      (label, either (const False) (const True) decoded) `shouldBe` (label :: String, False)

malformedChildResults :: [(String, String)]
malformedChildResults =
  [ ("not json", "{"),
    ("not an object", "[]"),
    ("empty", ""),
    ("unknown schema", "{\"schema\":\"something-else\",\"version\":1,\"repository\":\"coghex/kanban\",\"mission\":\"mission-a\",\"outcome\":\"advanced\",\"refusal\":null,\"detail\":\"\"}"),
    ("unknown version", "{\"schema\":\"kanban-mission-child-result\",\"version\":2,\"repository\":\"coghex/kanban\",\"mission\":\"mission-a\",\"outcome\":\"advanced\",\"refusal\":null,\"detail\":\"\"}"),
    ("missing outcome", "{\"schema\":\"kanban-mission-child-result\",\"version\":1,\"repository\":\"coghex/kanban\",\"mission\":\"mission-a\",\"refusal\":null,\"detail\":\"\"}"),
    ("missing mission", "{\"schema\":\"kanban-mission-child-result\",\"version\":1,\"repository\":\"coghex/kanban\",\"outcome\":\"advanced\",\"refusal\":null,\"detail\":\"\"}"),
    ("wrong-typed version", "{\"schema\":\"kanban-mission-child-result\",\"version\":\"1\",\"repository\":\"coghex/kanban\",\"mission\":\"mission-a\",\"outcome\":\"advanced\",\"refusal\":null,\"detail\":\"\"}"),
    ("unknown outcome", "{\"schema\":\"kanban-mission-child-result\",\"version\":1,\"repository\":\"coghex/kanban\",\"mission\":\"mission-a\",\"outcome\":\"nearly\",\"refusal\":null,\"detail\":\"\"}"),
    ("unknown refusal", "{\"schema\":\"kanban-mission-child-result\",\"version\":1,\"repository\":\"coghex/kanban\",\"mission\":\"mission-a\",\"outcome\":\"refused\",\"refusal\":\"because\",\"detail\":\"\"}"),
    ("refused with no refusal", "{\"schema\":\"kanban-mission-child-result\",\"version\":1,\"repository\":\"coghex/kanban\",\"mission\":\"mission-a\",\"outcome\":\"refused\",\"refusal\":null,\"detail\":\"\"}"),
    ("advanced with a refusal", "{\"schema\":\"kanban-mission-child-result\",\"version\":1,\"repository\":\"coghex/kanban\",\"mission\":\"mission-a\",\"outcome\":\"advanced\",\"refusal\":\"already_advancing\",\"detail\":\"\"}")
  ]

-- ---------------------------------------------------------------------------
-- Real children
-- ---------------------------------------------------------------------------

childExecutionSpec :: Spec
childExecutionSpec = describe "the child a pass actually launches" $ do
  -- Requirement 5, and the review's verification anchor. The checkout has a
  -- space in it and so does the configuration path, and the fake records what
  -- it was handed rather than being asserted about from this side.
  it "runs in the checkout with a non-terminal stdin and the configured repository" $
    withStore $ \store ->
      withScratch $ \scratch -> do
        let checkout = scratch </> "a checkout"
            configuration = scratch </> "a config.toml"
            transcript = scratch </> "transcript"
        createDirectoryIfMissing True checkout
        writeFile configuration "cache = true\n"
        fake <- writeFakeKanban scratch (recordingScript transcript "advanced" 0)
        putMission store "mission-a" MissionRunning
        results <-
          advanceMissions
            fake
            testOptions {optionConfig = Just configuration}
            boardRepository {repositoryRoot = checkout}
            scratch
            [MissionId "mission-a"]
        map (fmap (.missionChildResultOutcome) . snd) results `shouldBe` [Right MissionChildAdvanced]
        recorded <- lines <$> readFile transcript
        -- The checkout travels as the working directory, so a name with a
        -- space in it reaches the child intact and unquoted. Proved by what
        -- the child left in its own directory rather than by comparing the
        -- path it printed, which a symlinked temporary root would resolve.
        doesFileExist (checkout </> "ran here") `shouldReturn` True
        "stdin-is-a-terminal=no" `elem` recorded `shouldBe` True
        ("config=" <> configuration) `elem` recorded `shouldBe` True
        "repo=coghex/kanban" `elem` recorded `shouldBe` True
        "mission=mission-a" `elem` recorded `shouldBe` True

  -- Requirement 7: the pass writes one document and the children write
  -- whatever they like. A child's chatter reaching the report stream would be
  -- a supervisor's parse failure rather than a visible bug, so it is the
  -- isolation that is asserted.
  it "keeps a chattering child's output out of the result it returns" $
    withStore $ \store ->
      withScratch $ \scratch -> do
        fake <- writeFakeKanban scratch (chatteringScript "advanced" 0)
        putMission store "mission-a" MissionRunning
        results <- advanceMissions fake testOptions (checkoutIn scratch) scratch [MissionId "mission-a"]
        case map snd results of
          [Right result] -> do
            ("NOISE" `Text.isInfixOf` result.missionChildResultDetail) `shouldBe` False
            result.missionChildResultOutcome `shouldBe` MissionChildAdvanced
          other -> expectationFailure ("unexpected results: " <> show other)

  -- A pass that was killed leaves its children's documents behind. Nothing
  -- about the path says which pass wrote one, so a document that was already
  -- there must never be read as the account of a child that wrote nothing —
  -- and this is the shape that matters most, because a stale
  -- @already_advancing@ beside a fresh non-zero exit agrees with itself and
  -- reads as ordinary contention, which is a *successful* pass over a mission
  -- that failed.
  it "never reads a result document it did not just see written" $
    withStore $ \store ->
      withScratch $ \scratch -> do
        writeFile (scratch </> "child-0.json") staleRefusalDocument
        fake <- writeFakeKanban scratch "#!/bin/sh\nexit 1\n"
        putMission store "mission-a" MissionRunning
        results <- advanceMissions fake testOptions (checkoutIn scratch) scratch [MissionId "mission-a"]
        case map snd results of
          [Left message] -> ("wrote no result document" `Text.isInfixOf` message) `shouldBe` True
          other -> expectationFailure ("a stale document was accepted: " <> show other)

  -- And the disposition that stale document would have produced, so the
  -- example above is pinned to the outcome it prevents rather than merely to a
  -- message.
  it "fails the pass a stale contention document would have made succeed" $
    withStore $ \store ->
      withScratch $ \scratch -> do
        writeFile (scratch </> "child-0.json") staleRefusalDocument
        fake <- writeFakeKanban scratch "#!/bin/sh\nexit 1\n"
        putMission store "mission-a" MissionRunning
        results <- advanceMissions fake testOptions (checkoutIn scratch) scratch [MissionId "mission-a"]
        let report = disposedPass store results
        report >>= \dispositions -> map (.missionDispositionValue) dispositions `shouldBe` [MissionDispositionFailed]

  it "fails a child that wrote no result document" $
    withStore $ \store ->
      withScratch $ \scratch -> do
        fake <- writeFakeKanban scratch "#!/bin/sh\nexit 0\n"
        putMission store "mission-a" MissionRunning
        results <- advanceMissions fake testOptions (checkoutIn scratch) scratch [MissionId "mission-a"]
        case map snd results of
          [Left message] -> ("wrote no result document" `Text.isInfixOf` message) `shouldBe` True
          other -> expectationFailure ("unexpected results: " <> show other)

  it "fails a child whose document is truncated" $
    withStore $ \store ->
      withScratch $ \scratch -> do
        fake <- writeFakeKanban scratch "#!/bin/sh\nprintf '{\"schema\":\"kanban-mission' > \"$4\"\nexit 0\n"
        putMission store "mission-a" MissionRunning
        results <- advanceMissions fake testOptions (checkoutIn scratch) scratch [MissionId "mission-a"]
        case map snd results of
          [Left message] -> ("will not parse" `Text.isInfixOf` message) `shouldBe` True
          other -> expectationFailure ("unexpected results: " <> show other)

  it "fails a child whose document names another mission" $
    withStore $ \store ->
      withScratch $ \scratch -> do
        fake <- writeFakeKanban scratch (resultScript "mission-elsewhere" "coghex/kanban" "advanced" 0)
        putMission store "mission-a" MissionRunning
        results <- advanceMissions fake testOptions (checkoutIn scratch) scratch [MissionId "mission-a"]
        case map snd results of
          [Left message] -> ("wrote a result for mission-elsewhere" `Text.isInfixOf` message) `shouldBe` True
          other -> expectationFailure ("unexpected results: " <> show other)

  -- Requirement 9's contradiction case at the child boundary: a document
  -- saying the mission advanced beside a non-zero exit, and the reverse.
  -- A mission identifier does not identify a mission: two repositories may
  -- spell one the same way, which is why every durable record in the store is
  -- repository-qualified. A result from somebody else's repository must not
  -- decide this mission's disposition.
  it "fails a child whose document names another repository" $
    withStore $ \store ->
      withScratch $ \scratch -> do
        fake <- writeFakeKanban scratch (resultScript "mission-a" "someone/else" "advanced" 0)
        putMission store "mission-a" MissionRunning
        results <- advanceMissions fake testOptions (checkoutIn scratch) scratch [MissionId "mission-a"]
        case map snd results of
          [Left message] -> ("someone/else" `Text.isInfixOf` message) `shouldBe` True
          other -> expectationFailure ("a foreign result was accepted: " <> show other)

  it "fails a child whose document contradicts its exit status" $
    withStore $ \store ->
      withScratch $ \scratch ->
        forM_ [("advanced", 1 :: Int), ("failed", 0)] $ \(outcome, status) -> do
          fake <- writeFakeKanban scratch (resultScript "mission-a" "coghex/kanban" outcome status)
          putMission store "mission-a" MissionRunning
          results <- advanceMissions fake testOptions (checkoutIn scratch) scratch [MissionId "mission-a"]
          case map snd results of
            [Left message] -> (outcome, "reported" `Text.isInfixOf` message) `shouldBe` (outcome, True)
            other -> expectationFailure ("unexpected results for " <> outcome <> ": " <> show other)

  it "waits for every child it launched" $
    withStore $ \store ->
      withScratch $ \scratch -> do
        let marker = scratch </> "slow-finished"
        fake <- writeFakeKanban scratch (slowScript marker)
        forM_ ["mission-a", "mission-b"] $ \mission -> putMission store mission MissionRunning
        results <- advanceMissions fake testOptions (checkoutIn scratch) scratch [MissionId "mission-a", MissionId "mission-b"]
        length results `shouldBe` 2
        -- Written by the child just before it exits, so its presence the
        -- instant `advanceMissions` returns is the wait rather than a race.
        doesFileExist marker `shouldReturn` True

  it "reports a launch that could not happen without abandoning the others" $
    withStore $ \store ->
      withScratch $ \scratch -> do
        forM_ ["mission-a", "mission-b"] $ \mission -> putMission store mission MissionRunning
        results <- advanceMissions (scratch </> "no-such-executable") testOptions (checkoutIn scratch) scratch [MissionId "mission-a", MissionId "mission-b"]
        map fst results `shouldBe` [MissionId "mission-a", MissionId "mission-b"]
        forM_ (map snd results) $ \outcome -> case outcome of
          Left message -> ("could not be started" `Text.isInfixOf` message) `shouldBe` True
          Right result -> expectationFailure ("a child ran: " <> show result)

-- ---------------------------------------------------------------------------
-- Attention
-- ---------------------------------------------------------------------------

attentionSpec :: Spec
attentionSpec = describe "the attention a waiting mission raises" $ do
  -- Requirement 12, through the one function every real transition into
  -- @waiting_input@ goes through. Constructing a snapshot with an attention
  -- record in it would assume exactly what this is asserting.
  it "is created by a real transition into waiting_input" $
    withController $ \store controller -> do
      snapshot <- currentSnapshot store (MissionId "mission-a")
      void (applyMissionLifecycle controller snapshot MissionWaitingInput "the reviewer asked a question")
      raised <- currentSnapshot store (MissionId "mission-a")
      case raised.missionSnapshotAttention of
        Nothing -> expectationFailure "the transition raised no attention"
        Just attention -> do
          attention.missionAttentionSummary `shouldBe` "the reviewer asked a question"
          -- Repository-qualified, so two repositories spelling a mission the
          -- same way never share an identity.
          ("coghex/kanban#mission-a@" `Text.isPrefixOf` attention.missionAttentionId.unMissionAttentionId) `shouldBe` True

  it "survives a repeated observation of the same episode" $
    withController $ \store controller -> do
      snapshot <- currentSnapshot store (MissionId "mission-a")
      void (applyMissionLifecycle controller snapshot MissionWaitingInput "the reviewer asked a question")
      first <- currentSnapshot store (MissionId "mission-a")
      void (applyMissionLifecycle controller first MissionWaitingInput "the reviewer is still waiting")
      second <- currentSnapshot store (MissionId "mission-a")
      ((.missionAttentionId) <$> first.missionSnapshotAttention)
        `shouldBe` ((.missionAttentionId) <$> second.missionSnapshotAttention)
      -- The identity is the episode's; what it is waiting on is allowed to be
      -- restated.
      ((.missionAttentionSummary) <$> second.missionSnapshotAttention)
        `shouldBe` Just "the reviewer is still waiting"

  it "is cleared when the mission stops waiting" $
    withController $ \store controller -> do
      snapshot <- currentSnapshot store (MissionId "mission-a")
      void (applyMissionLifecycle controller snapshot MissionWaitingInput "the reviewer asked a question")
      waiting <- currentSnapshot store (MissionId "mission-a")
      void (applyMissionLifecycle controller waiting MissionRunning "answered")
      running <- currentSnapshot store (MissionId "mission-a")
      running.missionSnapshotAttention `shouldBe` Nothing

  -- Requirement 12's \"a later distinct episode receives a new identity\": the
  -- mission leaves @waiting_input@ and comes back, which is the definition the
  -- review pinned.
  it "gives a later episode a new identity" $
    withController $ \store controller -> do
      snapshot <- currentSnapshot store (MissionId "mission-a")
      void (applyMissionLifecycle controller snapshot MissionWaitingInput "first question")
      first <- currentSnapshot store (MissionId "mission-a")
      void (applyMissionLifecycle controller first MissionRunning "answered")
      running <- currentSnapshot store (MissionId "mission-a")
      void (applyMissionLifecycle controller running MissionWaitingInput "second question")
      second <- currentSnapshot store (MissionId "mission-a")
      let identities = [(.missionAttentionId) <$> first.missionSnapshotAttention, (.missionAttentionId) <$> second.missionSnapshotAttention]
      length (nub identities) `shouldBe` 2

  -- The three other waits are not operator-required, so none of them raises
  -- attention and each of them ends an episode that was open.
  it "raises none for a barrier, a capacity wait, or a pause" $
    forM_ [MissionWaitingBarrier, MissionWaitingCapacity, MissionPaused] $ \lifecycle ->
      withController $ \store controller -> do
        snapshot <- currentSnapshot store (MissionId "mission-a")
        void (applyMissionLifecycle controller snapshot lifecycle "not the operator's")
        quiet <- currentSnapshot store (MissionId "mission-a")
        (lifecycle, quiet.missionSnapshotAttention) `shouldBe` (lifecycle, Nothing)

  -- Requirement 12's target resolution, as the review corrected it: the step's
  -- own target first, the selector's list next, and nothing at all when a
  -- mission names neither.
  it "resolves the step's target first, and only that one" $
    -- The step's own target is what the mission is waiting about, so the
    -- selector's other items are not also the subject of this episode.
    missionNotificationTargets
      theSpecification {missionSpecificationSelector = selectorOver [theTarget, theSecondTarget]}
      (attentionOn (Just theStep))
      `shouldBe` [theTarget]

  it "falls back to the selector's targets when the step names none" $
    missionNotificationTargets
      theSpecification {missionSpecificationPlan = [stepWithoutTarget]}
      (attentionOn (Just theStep))
      `shouldBe` [theTarget]

  -- Every one of them, not the first. A selector that matched three items is
  -- a mission about three items, and dropping two would quietly narrow what an
  -- operator is told to look at.
  it "keeps every selector target rather than the first" $
    missionNotificationTargets
      theSpecification
        { missionSpecificationPlan = [stepWithoutTarget],
          missionSpecificationSelector = selectorOver [theTarget, theSecondTarget]
        }
      (attentionOn (Just theStep))
      `shouldBe` [theTarget, theSecondTarget]

  it "resolves the selector's targets when the attention names no step" $
    missionNotificationTargets theSpecification (attentionOn Nothing) `shouldBe` [theTarget]

  it "resolves no target at all when the mission names none" $
    missionNotificationTargets
      theSpecification
        { missionSpecificationPlan = [stepWithoutTarget],
          missionSpecificationSelector = selectorOver []
        }
      (attentionOn (Just theStep))
      `shouldBe` []

  -- An unreadable specification is not a mission that names no item: those two
  -- look identical downstream, and notifying on the second reading would spend
  -- this episode's single permanent attempt asserting the mission is about
  -- nothing. Nothing is launched, the episode is still reported, and the pass
  -- fails because mission state could not be accounted for.
  it "launches nothing for an episode whose specification will not read" $
    forM_ ["unreadable", "refused", "absent"] $ \shape ->
      withWaitingMission $ \store -> do
        breakSpecification store (MissionId "mission-a") shape
        invocations <- newIORef []
        (report, _) <- passWith store (enabledWith (Just ["notify"])) $ \seams ->
          seams {missionSchedulerNotify = recordingNotifier invocations (MissionNotificationAttempt MissionNotificationCompleted Nothing)}
        (shape, ) <$> readIORef invocations `shouldReturn` (shape, [])
        (shape, map (.missionAttentionRecordNotification) report.missionPassAttention)
          `shouldBe` (shape, [MissionNotificationUnresolved])
        (shape, map (.missionAttentionRecordTargets) report.missionPassAttention)
          `shouldBe` (shape, [[]])
        (shape, report.missionPassTermination) `shouldBe` (shape, MissionPassFailed)

  -- And the episode is still eligible afterwards: nothing was suppressed, so a
  -- repaired specification gets the attempt this pass withheld.
  it "leaves an unresolved episode eligible for its attempt" $
    withWaitingMission $ \store -> do
      breakSpecification store (MissionId "mission-a") "unreadable"
      invocations <- newIORef []
      _ <- passWith store (enabledWith (Just ["notify"])) $ \seams ->
        seams {missionSchedulerNotify = recordingNotifier invocations (MissionNotificationAttempt MissionNotificationCompleted Nothing)}
      restoreSpecification store (MissionId "mission-a")
      (report, _) <- passWith store (enabledWith (Just ["notify"])) $ \seams ->
        seams {missionSchedulerNotify = recordingNotifier invocations (MissionNotificationAttempt MissionNotificationCompleted Nothing)}
      length <$> readIORef invocations `shouldReturn` 1
      map (.missionAttentionRecordNotification) report.missionPassAttention
        `shouldBe` [MissionNotificationCompleted]

  -- Requirement 13: a waiting mission is not admitted and is still observed,
  -- which is the pairing the review asked for explicitly.
  it "is observed for a mission no pass would advance" $
    withStore $ \store -> do
      putMissionWith store "mission-a" MissionWaitingInput $ \snapshot ->
        snapshot {missionSnapshotAttention = Just (attentionRecord (MissionId "mission-a"))}
      (report, advanced) <- passWith store defaultMissionsConfig id
      readIORef advanced `shouldReturn` []
      map (.missionAttentionRecordMission) report.missionPassAttention `shouldBe` [MissionId "mission-a"]

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------

notificationSpec :: Spec
notificationSpec = describe "telling somebody a mission is waiting" $ do
  -- Requirement 14's default. Off, and off means the command is never reached
  -- rather than reached and ignored.
  it "runs nothing when notifications are off" $
    withWaitingMission $ \store -> do
      (report, invocations) <- passRecordingNotifications store defaultMissionsConfig
      readIORef invocations `shouldReturn` []
      map (.missionAttentionRecordNotification) report.missionPassAttention `shouldBe` [MissionNotificationDisabled]

  -- Requirement 14's named configuration refusal, and requirement 7's refused
  -- termination: nothing is advanced and the reason is reported.
  it "refuses the pass when notifications are enabled with no command" $
    withWaitingMission $ \store -> do
      putMission store "mission-b" MissionRunning
      (report, advanced) <- passWith store (enabledWith Nothing) id
      readIORef advanced `shouldReturn` []
      report.missionPassTermination `shouldBe` MissionPassRefused
      missionPassExitCode report.missionPassTermination `shouldBe` 2
      ("nothing to run" `Text.isInfixOf` report.missionPassDetail) `shouldBe` True

  -- Requirement 14's payload. Three appended arguments and no fourth: no
  -- title, no summary, no path.
  it "hands the command only the repository, the target, and that attention is required" $
    withWaitingMission $ \store -> do
      (_, invocations) <- passRecordingNotifications store (enabledWith (Just ["notify", "--now"]))
      readIORef invocations
        `shouldReturn` [["notify", "--now", "coghex/kanban", "attention-required", "issue#844"]]

  -- A mission that names nothing appends nothing. The two fixed positions stay
  -- where they are, so a wrapper reading `$1` and `$2` is unaffected by how
  -- many items there turn out to be — which is the whole reason the variadic
  -- part is last.
  it "appends no target argument at all when the mission names none" $
    missionNotificationArguments "coghex/kanban" []
      `shouldBe` ["coghex/kanban", "attention-required"]

  it "appends one argument per target, in order" $
    missionNotificationArguments
      "coghex/kanban"
      [theTarget, theTarget {missionTargetKind = MissionTargetPullRequest, missionTargetNumber = 7}]
      `shouldBe` ["coghex/kanban", "attention-required", "issue#844", "pull_request#7"]

  -- Requirement 15's whole point. Two passes over one unchanged episode, and
  -- the second reaches nothing.
  it "attempts one identity at most once across repeated passes" $
    withWaitingMission $ \store -> do
      (_, invocations) <- passRecordingNotifications store (enabledWith (Just ["notify"]))
      second <- passRecordingNotificationsInto store (enabledWith (Just ["notify"])) invocations
      length <$> readIORef invocations `shouldReturn` 1
      map (.missionAttentionRecordNotification) second.missionPassAttention `shouldBe` [MissionNotificationSuppressed]

  -- The same identity observed by two passes at once. Only one of them may
  -- create the record, so only one of them may launch anything.
  it "attempts one identity at most once across concurrent observations" $
    withWaitingMission $ \store -> do
      invocations <- newIORef []
      done <- newEmptyMVar
      forM_ [1 :: Int, 2] $ \_ ->
        void . forkIO $ do
          _ <- passRecordingNotificationsInto store (enabledWith (Just ["notify"])) invocations
          putMVar done ()
      forM_ [1 :: Int, 2] (const (takeMVar done))
      length <$> readIORef invocations `shouldReturn` 1

  -- Requirement 15's accepted loss, staged as the durable state a crash
  -- between the record and the launch leaves: a suppression with no outcome.
  -- A restart must not read that as an attempt still owed.
  it "never retries an identity whose attempt died before it launched" $
    withWaitingMission $ \store -> do
      -- The crash staged where it really happens: the suppression record has
      -- been created and the launch is what dies, so the record stands with no
      -- outcome against it. Nothing here is hand-built.
      crashed <-
        try @SomeException
          ( attemptMissionNotification
              (\_ -> ioError (userError "the process died here"))
              store
              (MissionId "mission-a")
              (attentionRecord (MissionId "mission-a")).missionAttentionId
              ["notify"]
          )
      either (const (pure ())) (\attempt -> expectationFailure ("the crash did not propagate: " <> show attempt)) crashed
      (report, later) <- passRecordingNotifications store (enabledWith (Just ["notify"]))
      readIORef later `shouldReturn` []
      map (.missionAttentionRecordNotification) report.missionPassAttention `shouldBe` [MissionNotificationSuppressed]

  -- The other half of requirement 15's crash pair: the command ran and the
  -- outcome could not be written. The identity stays used up, and the attempt
  -- says so rather than claiming the outcome it observed.
  it "never retries an identity whose outcome could not be recorded" $
    withWaitingMission $ \store -> do
      attempt <-
        attemptMissionNotification
          (\_ -> occupyNotificationRecord store (MissionId "mission-a") >> pure (MissionNotificationAttempt MissionNotificationCompleted Nothing))
          store
          (MissionId "mission-a")
          (attentionRecord (MissionId "mission-a")).missionAttentionId
          ["notify"]
      attempt.missionNotificationAttemptState `shouldBe` MissionNotificationUncertain
      (report, later) <- passRecordingNotifications store (enabledWith (Just ["notify"]))
      readIORef later `shouldReturn` []
      map (.missionAttentionRecordNotification) report.missionPassAttention `shouldBe` [MissionNotificationSuppressed]

  it "never retries an identity whose record says the attempt failed" $
    withWaitingMission $ \store -> do
      invocations <- newIORef []
      attempt <-
        attemptMissionNotification
          (recordingNotifier invocations (MissionNotificationAttempt MissionNotificationLaunchFailed (Just "no such file")))
          store
          (MissionId "mission-a")
          (attentionRecord (MissionId "mission-a")).missionAttentionId
          ["notify"]
      attempt.missionNotificationAttemptState `shouldBe` MissionNotificationLaunchFailed
      (report, later) <- passRecordingNotifications store (enabledWith (Just ["notify"]))
      readIORef later `shouldReturn` []
      map (.missionAttentionRecordNotification) report.missionPassAttention `shouldBe` [MissionNotificationSuppressed]

  -- Requirement 15's \"if suppression cannot be persisted, do not launch\".
  -- An unwritable notifications directory is the staging, and nothing is run.
  it "launches nothing when the suppression record cannot be written" $
    withWaitingMission $ \store -> do
      sealNotificationDirectory store (MissionId "mission-a")
      invocations <- newIORef []
      attempt <-
        attemptMissionNotification
          (recordingNotifier invocations (MissionNotificationAttempt MissionNotificationCompleted Nothing))
          store
          (MissionId "mission-a")
          (attentionRecord (MissionId "mission-a")).missionAttentionId
          ["notify"]
      readIORef invocations `shouldReturn` []
      attempt.missionNotificationAttemptState `shouldBe` MissionNotificationRecordingFailed

  -- Requirement 15's \"record known failures and uncertain outcomes without
  -- claiming delivery\", one state at a time, and the attention is still
  -- outstanding after each.
  it "reports every unsuccessful outcome without resolving the attention" $
    forM_ [MissionNotificationFailed, MissionNotificationTimedOut, MissionNotificationLaunchFailed, MissionNotificationUncertain] $ \state ->
      withWaitingMission $ \store -> do
        invocations <- newIORef []
        (report, _) <- passWith store (enabledWith (Just ["notify"])) $ \seams ->
          seams {missionSchedulerNotify = recordingNotifier invocations (MissionNotificationAttempt state Nothing)}
        (state, map (.missionAttentionRecordNotification) report.missionPassAttention) `shouldBe` (state, [state])
        outstanding <- currentSnapshot store (MissionId "mission-a")
        (state, (.missionAttentionId) <$> outstanding.missionSnapshotAttention)
          `shouldBe` (state, Just (attentionRecord (MissionId "mission-a")).missionAttentionId)

  -- Requirement 15 again: a notification that failed stops nothing. The other
  -- mission is still admitted and the pass still completes.
  it "goes on scheduling after a notification command failed" $
    withWaitingMission $ \store -> do
      putMission store "mission-b" MissionRunning
      invocations <- newIORef []
      (report, advanced) <- passWith store (enabledWith (Just ["notify"])) $ \seams ->
        seams {missionSchedulerNotify = recordingNotifier invocations (MissionNotificationAttempt MissionNotificationLaunchFailed (Just "no such file"))}
      readIORef advanced `shouldReturn` [[MissionId "mission-b"]]
      report.missionPassTermination `shouldBe` MissionPassCompleted

  -- A zero exit is the command completing. Said so in the record, so nothing
  -- downstream can read it as proof that a person saw anything.
  it "claims completion rather than delivery on a zero exit" $
    withScratch $ \scratch -> do
      marker <- pure (scratch </> "ran")
      command <- writeFakeKanban scratch ("#!/bin/sh\ntouch \"" <> marker <> "\"\nexit 0\n")
      attempt <- runMissionNotificationCommand missionNotificationTimeoutMicros [Text.pack command, "coghex/kanban", "issue#844", "attention-required"]
      attempt.missionNotificationAttemptState `shouldBe` MissionNotificationCompleted
      doesFileExist marker `shouldReturn` True
      case attempt.missionNotificationAttemptDetail of
        Just detail -> ("delivery is not established" `Text.isInfixOf` detail) `shouldBe` True
        Nothing -> expectationFailure "a completed attempt said nothing about delivery"

  it "reports a nonzero exit as a failure" $
    withScratch $ \scratch -> do
      command <- writeFakeKanban scratch "#!/bin/sh\necho 'no notifier here' >&2\nexit 3\n"
      attempt <- runMissionNotificationCommand missionNotificationTimeoutMicros [Text.pack command]
      attempt.missionNotificationAttemptState `shouldBe` MissionNotificationFailed

  it "reports a command that outlived its bound" $
    withScratch $ \scratch -> do
      command <- writeFakeKanban scratch "#!/bin/sh\nsleep 30\n"
      attempt <- runMissionNotificationCommand (200 * 1000) [Text.pack command]
      attempt.missionNotificationAttemptState `shouldBe` MissionNotificationTimedOut

  it "reports a command there was nothing to launch" $
    withScratch $ \scratch -> do
      attempt <- runMissionNotificationCommand missionNotificationTimeoutMicros [Text.pack (scratch </> "no-such-notifier")]
      attempt.missionNotificationAttemptState `shouldBe` MissionNotificationLaunchFailed

  it "refuses an empty command rather than launching a shell" $ do
    attempt <- runMissionNotificationCommand missionNotificationTimeoutMicros []
    attempt.missionNotificationAttemptState `shouldBe` MissionNotificationLaunchFailed

  -- The bound decides how long the command *may* take and ends nothing when it
  -- expires, so without the sweep a notifier that hangs is still running when
  -- the pass has finished with it — one stuck process per waiting episode.
  -- Staged against a command that ignores SIGTERM, so what this proves is the
  -- escalation rather than the command's cooperation.
  it "ends a command that outlived its bound" $
    withScratch $ \scratch -> do
      let marker = scratch </> "stubborn.pid"
      command <-
        writeFakeKanban
          scratch
          ( unlines
              [ "#!/bin/sh",
                "trap '' TERM INT",
                "echo $$ > " <> show marker,
                "sleep 120"
              ]
          )
      attempt <- runMissionNotificationCommand (300 * 1000) [Text.pack command]
      attempt.missionNotificationAttemptState `shouldBe` MissionNotificationTimedOut
      recorded <- read . takeWhile (/= '\n') <$> readFile marker
      awaitGone recorded

  -- And a command that exits cleanly having backgrounded something: the group
  -- outlives the leader, so a sweep that only looked at the direct child would
  -- leave the descendant running.
  it "ends a descendant a command left behind" $
    withScratch $ \scratch -> do
      let marker = scratch </> "descendant.pid"
      command <-
        writeFakeKanban
          scratch
          ( unlines
              [ "#!/bin/sh",
                "( trap '' TERM INT; echo $$ > " <> show marker <> "; sleep 120 ) &",
                "while [ ! -s " <> show marker <> " ]; do sleep 0.02; done",
                "exit 0"
              ]
          )
      attempt <- runMissionNotificationCommand missionNotificationTimeoutMicros [Text.pack command]
      attempt.missionNotificationAttemptState `shouldBe` MissionNotificationCompleted
      recorded <- read . takeWhile (/= '\n') <$> readFile marker
      awaitGone recorded

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

configurationSpec :: Spec
configurationSpec = describe "the notification configuration" $ do
  it "is off with no command by default" $ do
    defaultMissionNotificationConfig.missionNotificationEnabled `shouldBe` False
    defaultMissionNotificationConfig.missionNotificationCommand `shouldBe` Nothing
    missionNotificationRefusal defaultMissionNotificationConfig `shouldBe` Nothing

  it "decodes the documented table" $
    case decodeConfigText "[missions.notifications]\nenabled = true\ncommand = [\"notify-send\", \"kanban\"]\n" of
      Left message -> expectationFailure (Text.unpack message)
      Right (config, warnings) -> do
        warnings `shouldBe` []
        config.rawMissions.missionsNotifications.missionNotificationEnabled `shouldBe` True
        config.rawMissions.missionsNotifications.missionNotificationCommand
          `shouldBe` Just (MissionNotificationCommand ["notify-send", "kanban"])

  -- Requirement 16: unknown keys warn, exactly as every other table's do,
  -- rather than failing the load or being silently accepted.
  it "warns about an unknown key rather than failing" $
    case decodeConfigText "[missions.notifications]\nenabled = false\nwhenever = true\n" of
      Left message -> expectationFailure (Text.unpack message)
      Right (config, warnings) -> do
        length warnings `shouldBe` 1
        config.rawMissions.missionsNotifications.missionNotificationEnabled `shouldBe` False

  it "refuses an empty command array" $
    case decodeConfigText "[missions.notifications]\ncommand = []\n" of
      Left message -> ("non-empty" `Text.isInfixOf` message) `shouldBe` True
      Right _ -> expectationFailure "an empty command array was accepted"

  it "names the refusal an enabled table with no command earns" $
    missionNotificationRefusal (MissionNotificationConfig True Nothing)
      `shouldBe` Just "missions.notifications.enabled is true and missions.notifications.command is not set, so there is nothing to run"

  -- A command written down and left switched off is how an operator tries one
  -- out, so it must not become a refusal.
  it "leaves a configured command switched off without refusing" $
    missionNotificationRefusal (MissionNotificationConfig False (Just (MissionNotificationCommand ["notify"]))) `shouldBe` Nothing

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

boardRepository :: Repository
boardRepository = Repository {repositoryRoot = "/tmp/board", repositoryOwner = "coghex", repositoryName = "kanban"}

-- | The same repository, rooted somewhere that exists.
--
-- Every example that really spawns needs one: a working directory that is not
-- there is refused by @posix_spawn@ before the executable is even considered,
-- which would fail these for a reason none of them is about.
checkoutIn :: FilePath -> Repository
checkoutIn root = boardRepository {repositoryRoot = root}

theStep :: MissionStepId
theStep = MissionStepId "solve-844"

-- | The selector a specification carries, over whatever targets a test names.
selectorOver :: [MissionTarget] -> MissionSelector
selectorOver targets =
  MissionSelector
    { missionSelectorKind = "issues",
      missionSelectorQuery = Nothing,
      missionSelectorTargets = targets
    }

theSecondTarget :: MissionTarget
theSecondTarget =
  MissionTarget
    { missionTargetKind = MissionTargetIssue,
      missionTargetNumber = 845,
      missionTargetTitle = Just "the other issue"
    }

theTarget :: MissionTarget
theTarget = MissionTarget {missionTargetKind = MissionTargetIssue, missionTargetNumber = 844, missionTargetTitle = Just "the issue"}

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 9 11) (secondsToDiffTime 120)

theSpecification :: MissionSpecification
theSpecification = specificationFor (MissionId "mission-a")

specificationFor :: MissionId -> MissionSpecification
specificationFor mission =
  MissionSpecification
    { missionSpecificationId = mission,
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

stepWithoutTarget :: MissionPlanStep
stepWithoutTarget =
  MissionPlanStep
    { missionPlanStepId = theStep,
      missionPlanStepAction = "solve_issue",
      missionPlanStepSummary = "take #844 to a pull request",
      missionPlanStepTarget = Nothing,
      missionPlanStepDependsOn = []
    }

attentionOn :: Maybe MissionStepId -> MissionAttention
attentionOn step =
  MissionAttention
    { missionAttentionId = missionAttentionIdentity (MissionRepository "coghex" "kanban") (MissionId "mission-a") fixedTime,
      missionAttentionSummary = "the reviewer asked a question",
      missionAttentionStep = step,
      missionAttentionRaisedAt = fixedTime
    }

attentionRecord :: MissionId -> MissionAttention
attentionRecord mission =
  MissionAttention
    { missionAttentionId = missionAttentionIdentity (MissionRepository "coghex" "kanban") mission fixedTime,
      missionAttentionSummary = "the reviewer asked a question",
      missionAttentionStep = Just theStep,
      missionAttentionRaisedAt = fixedTime
    }

snapshotFor :: MissionId -> MissionLifecycle -> MissionSnapshot
snapshotFor mission lifecycle =
  MissionSnapshot
    { missionSnapshotId = mission,
      missionSnapshotRepository = MissionRepository "coghex" "kanban",
      missionSnapshotLifecycle = lifecycle,
      missionSnapshotCurrentStep = Just theStep,
      missionSnapshotNextSteps = [],
      missionSnapshotSteps = [],
      missionSnapshotPause = MissionPause {missionPauseRequested = False, missionPauseReason = Nothing, missionPauseAt = Nothing},
      missionSnapshotAttention = Nothing,
      missionSnapshotPlannerSummary = Just "one issue, one solve",
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

childAdvanced :: MissionId -> MissionChildResult
childAdvanced mission =
  MissionChildResult
    { missionChildResultRepository = "coghex/kanban",
      missionChildResultMission = mission,
      missionChildResultOutcome = MissionChildAdvanced,
      missionChildResultRefusal = Nothing,
      missionChildResultDetail = "the mission stopped for now"
    }

childRefusal :: MissionId -> MissionChildRefusal -> MissionChildResult
childRefusal mission refusal =
  MissionChildResult
    { missionChildResultRepository = "coghex/kanban",
      missionChildResultMission = mission,
      missionChildResultOutcome = MissionChildRefused,
      missionChildResultRefusal = Just refusal,
      missionChildResultDetail = "refused"
    }

enabledWith :: Maybe [Text] -> MissionsConfig
enabledWith argv =
  MissionsConfig
    { missionsNotifications =
        MissionNotificationConfig
          { missionNotificationEnabled = True,
            missionNotificationCommand = MissionNotificationCommand <$> argv
          }
    }

-- | A store under a temporary state root.
withStore :: (MissionStore -> IO result) -> IO result
withStore action =
  withScratch $ \root ->
    withEnvironmentValue "XDG_STATE_HOME" root $ do
      opened <- openMissionStore boardRepository
      case opened of
        Left message -> fail ("could not open the mission store: " <> Text.unpack message)
        Right store -> action store

-- | A store holding exactly one mission that is waiting on a person.
withWaitingMission :: (MissionStore -> IO result) -> IO result
withWaitingMission action = withStore $ \store -> do
  putMissionWith store "mission-a" MissionWaitingInput $ \snapshot ->
    snapshot {missionSnapshotAttention = Just (attentionRecord (MissionId "mission-a"))}
  action store

-- | A real controller over a real store, with a driver that reaches nothing.
--
-- Enough to exercise 'applyMissionLifecycle', which is the only thing the
-- attention examples need: nothing below dispatches, observes, or terminates.
withController :: (MissionStore -> MissionController -> IO result) -> IO result
withController action = withStore $ \store -> do
  putMission store "mission-a" MissionRunning
  started <- startMissionController store boardRepository (MissionId "mission-a") (\_ _ -> pure inertDriver)
  case started of
    Left refusal -> fail ("the controller refused to start: " <> Text.unpack (missionStartRefusalMessage refusal))
    Right controller -> do
      result <- action store controller
      stopMissionController controller
      pure result

inertDriver :: MissionDriver
inertDriver =
  MissionDriver
    { missionDriverInventory = pure (Right (MissionInventory [] [])),
      missionDriverObserveTarget = \_ -> pure (Left "no target reader in this fixture"),
      missionDriverStepEvidence = \_ _ -> pure (Left "no evidence reader in this fixture"),
      missionDriverObserveSession = \_ _ -> pure (Right Nothing),
      missionDriverAdoptInvocation = \_ -> pure (Right Nothing),
      missionDriverDispatch = \_ -> fail "this fixture dispatches nothing",
      missionDriverTerminate = \_ -> pure (Right [])
    }

putMission :: MissionStore -> String -> MissionLifecycle -> IO ()
putMission store mission lifecycle = putMissionWith store mission lifecycle id

putMissionWith :: MissionStore -> String -> MissionLifecycle -> (MissionSnapshot -> MissionSnapshot) -> IO ()
putMissionWith store mission lifecycle adjust = do
  let identifier = MissionId (Text.pack mission)
  created <- createMissionSpecification store (specificationFor identifier)
  case created of
    Left message -> fail ("could not write the specification: " <> Text.unpack message)
    Right _ -> pure ()
  written <- writeMissionSnapshot store (adjust (snapshotFor identifier lifecycle))
  case written of
    Left message -> fail ("could not write the snapshot: " <> Text.unpack message)
    Right () -> pure ()

currentSnapshot :: MissionStore -> MissionId -> IO MissionSnapshot
currentSnapshot store mission = do
  readBack <- readMissionSnapshot store mission
  case readBack of
    MissionPresent snapshot -> pure snapshot
    other -> fail ("the snapshot did not read back: " <> show (() <$ other))

-- | One identifier recorded under both the current root and the ambiguous one
-- a release before #615 wrote to, which 'missionRoot' refuses to resolve.
--
-- Built by writing the legacy history through the writers that own it, rooted
-- at that directory, which is how the release that produced this state
-- produced it.
stageRootCollision :: MissionStore -> MissionId -> IO ()
stageRootCollision store mission = do
  let legacy =
        store
          { missionStoreDirectory = store.missionStoreLegacyDirectory,
            -- Its own legacy root is a name that does not exist, so this
            -- writer lands at the ambiguous directory rather than resolving
            -- away from it — exactly as the release that wrote one did.
            missionStoreLegacyDirectory = store.missionStoreLegacyDirectory </> "no-legacy-root-here"
          }
  created <- createMissionSpecification legacy (specificationFor mission)
  created `shouldBe` Right MissionCreated
  written <- writeMissionSnapshot legacy (snapshotFor mission MissionRunning)
  written `shouldBe` Right ()

-- | A snapshot that decodes and names another repository, which this store
-- refuses rather than adopts.
disownSnapshot :: MissionStore -> MissionId -> IO ()
disownSnapshot store mission =
  case missionDirectory store.missionStoreDirectory mission of
    Left message -> fail (Text.unpack message)
    Right directory -> rewriteOwner (directory </> "snapshot.json")

-- | A snapshot that is there and will not decode, which is a different thing
-- from one that is missing.
corruptSnapshot :: MissionStore -> MissionId -> IO ()
corruptSnapshot store mission =
  case missionDirectory store.missionStoreDirectory mission of
    Left message -> fail (Text.unpack message)
    Right directory -> writeFile (directory </> "snapshot.json") "{\"schemaVersion\":1,\"payload\":\"not a snapshot\"}"

-- | The three ways a specification can fail to hand itself over.
breakSpecification :: MissionStore -> MissionId -> String -> IO ()
breakSpecification store mission shape =
  case missionDirectory store.missionStoreDirectory mission of
    Left message -> fail (Text.unpack message)
    Right directory -> case shape of
      "absent" -> removeFile (directory </> "specification.json")
      "unreadable" -> writeFile (directory </> "specification.json") "{\"schemaVersion\":1,\"payload\":\"not a specification\"}"
      -- Decodes perfectly and belongs to another repository, which this store
      -- refuses rather than adopts.
      _ -> rewriteOwner (directory </> "specification.json")

-- | Reassigns one durable record to another owner, in place.
--
-- The record goes on decoding; what changes is who it says it belongs to,
-- which is the one thing the reader's identity check is for.
rewriteOwner :: FilePath -> IO ()
rewriteOwner path = do
  contents <- readFile path
  length contents `seq` writeFile path (replace "\"missionRepositoryOwner\":\"coghex\"" "\"missionRepositoryOwner\":\"someone\"" contents)
  where
    replace needle replacement haystack = go haystack
      where
        go [] = []
        go rest@(character : remaining)
          | take (length needle) rest == needle = replacement <> go (drop (length needle) rest)
          | otherwise = character : go remaining

-- | Puts a readable specification back, so a later pass can resolve it.
restoreSpecification :: MissionStore -> MissionId -> IO ()
restoreSpecification store mission =
  case missionDirectory store.missionStoreDirectory mission of
    Left message -> fail (Text.unpack message)
    Right directory -> do
      removeFile (directory </> "specification.json")
      created <- createMissionSpecification store (specificationFor mission)
      created `shouldBe` Right MissionCreated

removeSnapshot :: MissionStore -> MissionId -> IO ()
removeSnapshot store mission =
  case missionDirectory store.missionStoreDirectory mission of
    Left message -> fail (Text.unpack message)
    Right directory -> removeFile (directory </> "snapshot.json")

-- | A notifications directory that cannot be created, because something else
-- already occupies the name.
--
-- A mode change would not do: every mission directory is created through
-- 'Kanban.Paths.createPrivateDirectory', which walks the chain back to @0700@
-- on the way in, so a sealed directory would unseal itself.
sealNotificationDirectory :: MissionStore -> MissionId -> IO ()
sealNotificationDirectory store mission =
  case missionDirectory store.missionStoreDirectory mission of
    Left message -> fail (Text.unpack message)
    Right directory -> do
      createDirectoryIfMissing True directory
      writeFile (directory </> "notifications") "not a directory\n"

-- | The record directory replaced by a file after the record itself was
-- created, which is what makes the outcome write — a staged rename into that
-- directory — fail while the suppression stands.
occupyNotificationRecord :: MissionStore -> MissionId -> IO ()
occupyNotificationRecord store mission =
  case missionDirectory store.missionStoreDirectory mission of
    Left message -> fail (Text.unpack message)
    Right directory -> setFileMode (directory </> "notifications") 0o500

passWith ::
  MissionStore ->
  MissionsConfig ->
  (MissionSchedulerSeams -> MissionSchedulerSeams) ->
  IO (MissionPassReport, IORef [[MissionId]])
passWith store missions adjust = do
  advanced <- newIORef []
  let base =
        MissionSchedulerSeams
          { missionSchedulerNow = getCurrentTime,
            missionSchedulerLeaseHeld = missionLeaseHeld store,
            missionSchedulerAdvance = \admitted -> pure [(mission, Right (childAdvanced mission)) | mission <- admitted],
            missionSchedulerNotify = \_ -> fail "this example runs no notification command"
          }
      adjusted = adjust base
      -- Wrapped after the example's own adjustment, so what is recorded is
      -- what the pass really asked for rather than what this fixture would
      -- have done with it.
      recorded =
        adjusted
          { missionSchedulerAdvance = \admitted -> do
              atomicModifyIORef' advanced (\seen -> (seen <> [admitted], ()))
              adjusted.missionSchedulerAdvance admitted
          }
  report <- runMissionSchedulerPass recorded missions store boardRepository
  pure (report, advanced)

passRecordingNotifications :: MissionStore -> MissionsConfig -> IO (MissionPassReport, IORef [[Text]])
passRecordingNotifications store missions = do
  invocations <- newIORef []
  report <- passRecordingNotificationsInto store missions invocations
  pure (report, invocations)

passRecordingNotificationsInto :: MissionStore -> MissionsConfig -> IORef [[Text]] -> IO MissionPassReport
passRecordingNotificationsInto store missions invocations =
  runMissionSchedulerPass
    MissionSchedulerSeams
      { missionSchedulerNow = getCurrentTime,
        missionSchedulerLeaseHeld = missionLeaseHeld store,
        missionSchedulerAdvance = \admitted -> pure [(mission, Right (childAdvanced mission)) | mission <- admitted],
        missionSchedulerNotify = recordingNotifier invocations (MissionNotificationAttempt MissionNotificationCompleted Nothing)
      }
    missions
    store
    boardRepository

recordingNotifier :: IORef [[Text]] -> MissionNotificationAttempt -> [Text] -> IO MissionNotificationAttempt
recordingNotifier invocations attempt argv = do
  atomicModifyIORef' invocations (\seen -> (seen <> [argv], ()))
  pure attempt

-- ---------------------------------------------------------------------------
-- Fake executables
-- ---------------------------------------------------------------------------

-- | A result document a previous pass's child left in a reused scratch
-- directory: well-formed, about the mission this pass is advancing, and
-- agreeing with the non-zero status a child that wrote nothing exits with.
staleRefusalDocument :: String
staleRefusalDocument =
  "{\"schema\":\"kanban-mission-child-result\",\"version\":1,"
    <> "\"repository\":\"coghex/kanban\",\"mission\":\"mission-a\","
    <> "\"outcome\":\"refused\",\"refusal\":\"already_advancing\","
    <> "\"detail\":\"from a pass that is long gone\"}"

-- | The dispositions a pass would draw from these child results.
disposedPass :: MissionStore -> [(MissionId, Either Text MissionChildResult)] -> IO [MissionDispositionRecord]
disposedPass store results = do
  report <-
    runMissionSchedulerPass
      MissionSchedulerSeams
        { missionSchedulerNow = getCurrentTime,
          missionSchedulerLeaseHeld = missionLeaseHeld store,
          missionSchedulerAdvance = \_ -> pure results,
          missionSchedulerNotify = \_ -> fail "this example runs no notification command"
        }
      defaultMissionsConfig
      store
      boardRepository
  pure report.missionPassAdmitted

-- | A stand-in for @kanban@ on the scheduler's own child path.
writeFakeKanban :: FilePath -> String -> IO FilePath
writeFakeKanban directory body = do
  let path = directory </> "fake-kanban"
  handle <- openFile path WriteMode
  hPutStrLn handle body
  hClose handle
  setFileMode path 0o700
  pure path

-- | The argument positions the scheduler's own child invocation fixes:
-- @--mission <id> --mission-result <path> --repo <owner/name> [--config <path>]@.
recordingScript :: FilePath -> String -> Int -> String
recordingScript transcript outcome status =
  unlines
    [ "#!/bin/sh",
      "{",
      "  echo \"cwd=$(pwd)\"",
      "  echo \"mission=$2\"",
      "  echo \"repo=$6\"",
      "  echo \"config=$8\"",
      "  if [ -t 0 ]; then echo 'stdin-is-a-terminal=yes'; else echo 'stdin-is-a-terminal=no'; fi",
      "} >> " <> show transcript,
      "touch './ran here'",
      resultLine "\"$2\"" "coghex/kanban" outcome,
      "exit " <> show status
    ]

chatteringScript :: String -> Int -> String
chatteringScript outcome status =
  unlines
    [ "#!/bin/sh",
      "echo 'NOISE on stdout'",
      "echo 'NOISE on stderr' >&2",
      resultLine "\"$2\"" "coghex/kanban" outcome,
      "exit " <> show status
    ]

resultScript :: String -> String -> String -> Int -> String
resultScript mission repository outcome status =
  unlines
    [ "#!/bin/sh",
      resultLine (show mission) repository outcome,
      "exit " <> show status
    ]

slowScript :: FilePath -> String
slowScript marker =
  unlines
    [ "#!/bin/sh",
      "sleep 1",
      resultLine "\"$2\"" "coghex/kanban" "advanced",
      "touch " <> show marker,
      "exit 0"
    ]

resultLine :: String -> String -> String -> String
resultLine mission repository outcome =
  "printf '%s' '"
    <> "{\"schema\":\"kanban-mission-child-result\",\"version\":1,\"repository\":\""
    <> repository
    <> "\",\"mission\":\"'"
    <> mission
    <> "'\",\"outcome\":\""
    <> outcome
    <> "\",\"refusal\":null,\"detail\":\"from the fake\"}' > \"$4\""

-- ---------------------------------------------------------------------------
-- Environment
-- ---------------------------------------------------------------------------

withScratch :: (FilePath -> IO result) -> IO result
withScratch = withTemporaryCacheRoot

-- | Waits for one process identifier to stop resolving.
--
-- Bounded, and a failure rather than a spin: the sweep signals and escalates,
-- so \"it is gone\" is reached after a grace period rather than instantly, and
-- a sweep that did nothing has to fail here rather than hang.
awaitGone :: Int -> IO ()
awaitGone processId = go (600 :: Int)
  where
    go 0 = expectationFailure ("process " <> show processId <> " outlived the command that started it")
    go remaining = do
      alive <- try @IOException (signalProcess nullSignal (fromIntegral processId))
      case alive of
        Left _ -> pure ()
        Right () -> threadDelay 20000 >> go (remaining - 1)
