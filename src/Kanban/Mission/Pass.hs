{-# LANGUAGE DerivingStrategies #-}

-- | The two machine-readable documents a scheduler pass is made of: the result
-- one mission child writes, and the report the pass itself writes.
--
-- Both live here rather than beside the code that produces them, because each
-- has two ends that must not be allowed to drift. The child result is written
-- by @kanban --mission@ and read by @kanban --mission-scheduler@; the pass
-- report is written by the scheduler and read by
-- @tools\/mission_runner_service.py@, which cannot import Haskell and
-- therefore mirrors these constants. A test holds the mirror equal to what is
-- declared here.
--
-- Three properties are contract rather than convenience.
--
-- Each document names its own @schema@ and carries an integer @version@, and a
-- reader that does not recognise the pair refuses rather than guessing at the
-- payload. That is the same rule @docs\/design.md@ §16 states for every other
-- durable record Kanban writes, applied to a document that crosses a process
-- boundary instead of a release boundary.
--
-- Every vocabulary — the child's outcomes and typed refusals, a mission's
-- disposition, a notification's state, and the pass's termination — is
-- declared exactly once, by a total case expression over a closed type. A
-- reader that admitted a tag no writer can produce would admit a typo as a
-- meaning.
--
-- The exit status is /derived/ from the termination reason, by
-- 'missionPassExitCode', and nowhere else. A supervisor that compared the
-- report against an exit code mapping of its own would have two answers to one
-- question; mirroring this one function is what makes \"the report contradicts
-- the exit status\" a thing the supervisor can detect rather than a thing it
-- can cause.
--
-- Nothing here launches a process, reads a mission store, or contacts GitHub.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Pass
  ( -- * The child result
    MissionChildResult (..),
    MissionChildOutcome (..),
    missionChildOutcomes,
    missionChildOutcomeTag,
    MissionChildRefusal (..),
    missionChildRefusals,
    missionChildRefusalTag,
    missionChildResultSchema,
    missionChildResultVersion,
    encodeMissionChildResult,
    decodeMissionChildResult,

    -- * The pass report
    MissionPassReport (..),
    MissionDispositionRecord (..),
    MissionDisposition (..),
    missionDispositions,
    missionDispositionTag,
    missionDispositionIsFailure,
    MissionAttentionRecord (..),
    MissionNotificationState (..),
    missionNotificationStates,
    missionNotificationStateTag,
    MissionPassTermination (..),
    missionPassTerminations,
    missionPassTerminationTag,
    missionPassExitCode,
    missionPassSchema,
    missionPassVersion,
    encodeMissionPassReport,
    missionPassNarration,
  )
where

import Data.Aeson (Value (Null), eitherDecodeStrict', object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as AesonTypes
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Kanban.Mission.Types
  ( MissionAttentionId (..),
    MissionId (..),
    MissionTarget (..),
    MissionTargetKind (..),
  )

-- ---------------------------------------------------------------------------
-- The child result
-- ---------------------------------------------------------------------------

-- | What one @kanban --mission@ child did, in the words the scheduler acts on.
--
-- Written only when @--mission-result@ names a file, so an operator's own
-- @--mission@ run is byte-for-byte the run it always was.
data MissionChildResult = MissionChildResult
  { missionChildResultRepository :: Text,
    missionChildResultMission :: MissionId,
    missionChildResultOutcome :: MissionChildOutcome,
    -- | Present exactly when the outcome is 'MissionChildRefused': a refusal
    -- is a /named/ thing the controller declined to do, and the whole point of
    -- this document is that the scheduler can tell one of those from a failure
    -- without reading terminal text.
    missionChildResultRefusal :: Maybe MissionChildRefusal,
    missionChildResultDetail :: Text
  }
  deriving stock (Eq, Show)

-- | The three things a mission child can have done.
--
-- \"Advanced\" covers every run the controller actually performed, including
-- one that ended with the mission waiting for somebody: the mission moved, and
-- where it moved to is a question the durable snapshot answers rather than
-- this document.
data MissionChildOutcome
  = MissionChildAdvanced
  | MissionChildRefused
  | MissionChildFailed
  deriving stock (Bounded, Enum, Eq, Ord, Show)

missionChildOutcomes :: [MissionChildOutcome]
missionChildOutcomes = [minBound .. maxBound]

missionChildOutcomeTag :: MissionChildOutcome -> Text
missionChildOutcomeTag outcome = case outcome of
  MissionChildAdvanced -> "advanced"
  MissionChildRefused -> "refused"
  MissionChildFailed -> "failed"

-- | The typed startup refusals, one per constructor of
-- "Kanban.Mission.Controller".'Kanban.Mission.Controller.MissionStartRefusal'.
--
-- One tag per refusal rather than one tag for \"refused\", because the
-- scheduler treats exactly one of them as ordinary: losing a race for the
-- advancement lease is expected contention between a pass and whatever else is
-- advancing that mission, and reporting it as a failed pass would make correct
-- behaviour look broken (requirement 6).
data MissionChildRefusal
  = MissionChildAlreadyAdvancing
  | MissionChildUnknownMission
  | MissionChildUnreadableRecord
  | MissionChildRepositoryMismatched
  | MissionChildIdentifierUnusable
  | MissionChildStoreUnusable
  deriving stock (Bounded, Enum, Eq, Ord, Show)

missionChildRefusals :: [MissionChildRefusal]
missionChildRefusals = [minBound .. maxBound]

missionChildRefusalTag :: MissionChildRefusal -> Text
missionChildRefusalTag refusal = case refusal of
  MissionChildAlreadyAdvancing -> "already_advancing"
  MissionChildUnknownMission -> "unknown_mission"
  MissionChildUnreadableRecord -> "unreadable_record"
  MissionChildRepositoryMismatched -> "repository_mismatched"
  MissionChildIdentifierUnusable -> "identifier_unusable"
  MissionChildStoreUnusable -> "store_unusable"

missionChildResultSchema :: Text
missionChildResultSchema = "kanban-mission-child-result"

missionChildResultVersion :: Int
missionChildResultVersion = 1

encodeMissionChildResult :: MissionChildResult -> LazyByteString.ByteString
encodeMissionChildResult result =
  Aeson.encode
    ( object
        [ "schema" .= missionChildResultSchema,
          "version" .= missionChildResultVersion,
          "repository" .= result.missionChildResultRepository,
          "mission" .= result.missionChildResultMission.unMissionId,
          "outcome" .= missionChildOutcomeTag result.missionChildResultOutcome,
          "refusal" .= maybe Null (Aeson.toJSON . missionChildRefusalTag) result.missionChildResultRefusal,
          "detail" .= result.missionChildResultDetail
        ]
    )

-- | The document a child wrote, or why it cannot be acted on.
--
-- Every refusal below is a refusal to guess. An unknown schema or version says
-- the writer and this reader disagree about the shape; a missing or
-- wrong-typed field says the document is not one of these at all; and a
-- @refusal@ that does not line up with the @outcome@ beside it is a document
-- whose two halves contradict each other, which is exactly the shape a reader
-- must not resolve by preferring one of them.
decodeMissionChildResult :: ByteString.ByteString -> Either Text MissionChildResult
decodeMissionChildResult bytes = case eitherDecodeStrict' bytes of
  Left message -> Left ("the mission child result will not parse: " <> Text.pack message)
  Right value -> case AesonTypes.parseEither parser value of
    Left message -> Left ("the mission child result is malformed: " <> Text.pack message)
    Right parsed -> Right parsed
  where
    parser = Aeson.withObject "mission child result" $ \document -> do
      schema <- document Aeson..: "schema"
      if schema /= missionChildResultSchema
        then fail ("unknown schema " <> show (schema :: Text) <> "; this release reads " <> show missionChildResultSchema)
        else pure ()
      version <- document Aeson..: "version"
      if version /= missionChildResultVersion
        then fail ("unknown schema version " <> show (version :: Int) <> "; this release reads " <> show missionChildResultVersion)
        else pure ()
      repository <- document Aeson..: "repository"
      mission <- document Aeson..: "mission"
      outcomeTag <- document Aeson..: "outcome"
      outcome <- case find ((== outcomeTag) . missionChildOutcomeTag) missionChildOutcomes of
        Nothing -> fail ("unknown outcome " <> show (outcomeTag :: Text))
        Just known -> pure known
      refusalTag <- document Aeson..: "refusal"
      refusal <- case refusalTag :: Maybe Text of
        Nothing -> pure Nothing
        Just tag -> case find ((== tag) . missionChildRefusalTag) missionChildRefusals of
          Nothing -> fail ("unknown refusal " <> show tag)
          Just known -> pure (Just known)
      case (outcome, refusal) of
        (MissionChildRefused, Nothing) -> fail "outcome \"refused\" names no refusal"
        (MissionChildRefused, Just _) -> pure ()
        (_, Just _) -> fail ("outcome " <> show (missionChildOutcomeTag outcome) <> " must carry no refusal")
        (_, Nothing) -> pure ()
      detail <- document Aeson..: "detail"
      pure
        MissionChildResult
          { missionChildResultRepository = repository,
            missionChildResultMission = MissionId mission,
            missionChildResultOutcome = outcome,
            missionChildResultRefusal = refusal,
            missionChildResultDetail = detail
          }

-- ---------------------------------------------------------------------------
-- The pass report
-- ---------------------------------------------------------------------------

-- | What one admitted mission's child amounted to.
--
-- Six dispositions rather than three, because a supervisor reading them has to
-- be able to tell a pass that is making progress from one that is quietly
-- doing nothing, and a mission that stopped for a person from one that broke.
data MissionDisposition
  = -- | The child ran and left the mission still advanceable.
    MissionDispositionAdvanced
  | -- | The child ran and the mission is now terminal.
    MissionDispositionSettled
  | -- | The child ran and the mission is now waiting or paused.
    MissionDispositionBlocked
  | -- | Another process held the advancement lease. Ordinary contention
    -- (requirement 6), and never a failed pass.
    MissionDispositionLeaseRefused
  | -- | Any other typed startup refusal.
    MissionDispositionRefused
  | -- | The child did not produce an account of itself that could be acted on.
    MissionDispositionFailed
  deriving stock (Bounded, Enum, Eq, Ord, Show)

missionDispositions :: [MissionDisposition]
missionDispositions = [minBound .. maxBound]

missionDispositionTag :: MissionDisposition -> Text
missionDispositionTag disposition = case disposition of
  MissionDispositionAdvanced -> "advanced"
  MissionDispositionSettled -> "settled"
  MissionDispositionBlocked -> "blocked"
  MissionDispositionLeaseRefused -> "lease_refused"
  MissionDispositionRefused -> "refused"
  MissionDispositionFailed -> "failed"

-- | Whether this disposition makes the pass a failed one.
--
-- Exactly one does. A refusal of either kind is the mission declining to be
-- advanced by this pass, which is information rather than breakage, and the
-- three ordinary outcomes are the pass working.
missionDispositionIsFailure :: MissionDisposition -> Bool
missionDispositionIsFailure disposition = case disposition of
  MissionDispositionFailed -> True
  MissionDispositionAdvanced -> False
  MissionDispositionSettled -> False
  MissionDispositionBlocked -> False
  MissionDispositionLeaseRefused -> False
  MissionDispositionRefused -> False

data MissionDispositionRecord = MissionDispositionRecord
  { missionDispositionMission :: MissionId,
    missionDispositionValue :: MissionDisposition,
    missionDispositionDetail :: Text
  }
  deriving stock (Eq, Show)

-- | What became of a notification for one attention identity.
--
-- None of the eight claims a person saw anything. A command that exits zero
-- has completed, which is all an arbitrary external program can ever
-- demonstrate to its caller (requirement 15).
data MissionNotificationState
  = -- | Notifications are off, which is the default.
    MissionNotificationDisabled
  | -- | This identity already carries a durable record, so no second attempt
    -- is made — ever, including after a restart.
    MissionNotificationSuppressed
  | -- | The command ran and exited zero.
    MissionNotificationCompleted
  | -- | The command ran and exited nonzero.
    MissionNotificationFailed
  | -- | The command outlived its bound.
    MissionNotificationTimedOut
  | -- | There was nothing runnable to launch.
    MissionNotificationLaunchFailed
  | -- | The command's outcome could not be established, or the outcome could
    -- not be recorded beside the suppression that stands.
    MissionNotificationUncertain
  | -- | Suppression could not be persisted, so nothing was launched.
    MissionNotificationRecordingFailed
  deriving stock (Bounded, Enum, Eq, Ord, Show)

missionNotificationStates :: [MissionNotificationState]
missionNotificationStates = [minBound .. maxBound]

missionNotificationStateTag :: MissionNotificationState -> Text
missionNotificationStateTag state = case state of
  MissionNotificationDisabled -> "disabled"
  MissionNotificationSuppressed -> "suppressed"
  MissionNotificationCompleted -> "completed"
  MissionNotificationFailed -> "failed"
  MissionNotificationTimedOut -> "timed_out"
  MissionNotificationLaunchFailed -> "launch_failed"
  MissionNotificationUncertain -> "uncertain"
  MissionNotificationRecordingFailed -> "recording_failed"

-- | One outstanding waiting episode this pass observed.
data MissionAttentionRecord = MissionAttentionRecord
  { missionAttentionRecordMission :: MissionId,
    missionAttentionRecordId :: MissionAttentionId,
    -- | The typed target the notification was resolved against, if the mission
    -- names one. Never a title, a path, or a summary.
    missionAttentionRecordTarget :: Maybe MissionTarget,
    missionAttentionRecordNotification :: MissionNotificationState,
    missionAttentionRecordDetail :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | How a pass ended, and the only thing its exit status is derived from.
data MissionPassTermination
  = MissionPassCompleted
  | MissionPassRefused
  | MissionPassFailed
  deriving stock (Bounded, Enum, Eq, Ord, Show)

missionPassTerminations :: [MissionPassTermination]
missionPassTerminations = [minBound .. maxBound]

missionPassTerminationTag :: MissionPassTermination -> Text
missionPassTerminationTag termination = case termination of
  MissionPassCompleted -> "completed"
  MissionPassRefused -> "refused"
  MissionPassFailed -> "failed"

-- | The exit status each termination reason is reported with.
--
-- Pinned here and mirrored in Python, so a supervisor can hold the two halves
-- of one pass against each other. @2@ for a refusal rather than some larger
-- number because that is the spelling this repository already uses for \"the
-- question was asked and the answer is no\": the canonical issue-approval
-- gate's own check exits @2@ for an issue it will not approve.
missionPassExitCode :: MissionPassTermination -> Int
missionPassExitCode termination = case termination of
  MissionPassCompleted -> 0
  MissionPassFailed -> 1
  MissionPassRefused -> 2

missionPassSchema :: Text
missionPassSchema = "kanban-mission-scheduler-pass"

missionPassVersion :: Int
missionPassVersion = 1

-- | Everything one pass did, as the one document it writes to stdout.
data MissionPassReport = MissionPassReport
  { missionPassRepository :: Text,
    missionPassStartedAt :: UTCTime,
    missionPassFinishedAt :: UTCTime,
    missionPassTermination :: MissionPassTermination,
    missionPassAdmitted :: [MissionDispositionRecord],
    missionPassAttention :: [MissionAttentionRecord],
    missionPassDetail :: Text
  }
  deriving stock (Eq, Show)

encodeMissionPassReport :: MissionPassReport -> LazyByteString.ByteString
encodeMissionPassReport report =
  Aeson.encode
    ( object
        [ "schema" .= missionPassSchema,
          "version" .= missionPassVersion,
          "repository" .= report.missionPassRepository,
          "started_at" .= stamp report.missionPassStartedAt,
          "finished_at" .= stamp report.missionPassFinishedAt,
          "termination" .= missionPassTerminationTag report.missionPassTermination,
          "exit_code" .= missionPassExitCode report.missionPassTermination,
          "admitted" .= map admitted report.missionPassAdmitted,
          "attention" .= map attention report.missionPassAttention,
          "detail" .= report.missionPassDetail
        ]
    )
  where
    stamp = Text.pack . iso8601Show

    admitted record =
      object
        [ "mission" .= record.missionDispositionMission.unMissionId,
          "disposition" .= missionDispositionTag record.missionDispositionValue,
          "detail" .= record.missionDispositionDetail
        ]

    attention record =
      object
        [ "mission" .= record.missionAttentionRecordMission.unMissionId,
          "attention_id" .= record.missionAttentionRecordId.unMissionAttentionId,
          "target" .= maybe Null target record.missionAttentionRecordTarget,
          "notification" .= missionNotificationStateTag record.missionAttentionRecordNotification,
          "detail" .= maybe Null Aeson.toJSON record.missionAttentionRecordDetail
        ]

    target value =
      object
        [ "kind" .= targetKindTag value.missionTargetKind,
          "number" .= value.missionTargetNumber
        ]

    -- The two target kinds, spelled for this document rather than borrowed
    -- from the durable record's own encoding. They agree today; stating them
    -- here is what keeps a change to the store's wire form from silently
    -- becoming a change to a notification payload an operator's command parses.
    targetKindTag kind = case kind of
      MissionTargetIssue -> "issue" :: Text
      MissionTargetPullRequest -> "pull_request"

-- | The pass, rendered for the operator's eye.
--
-- Everything here goes to stderr. Exactly one document goes to stdout, and
-- interleaving a word of narration with it is how a supervisor's parse of that
-- document starts failing (requirement 7).
missionPassNarration :: MissionPassReport -> [Text]
missionPassNarration report =
  ("mission scheduler pass for " <> report.missionPassRepository <> ": " <> missionPassTerminationTag report.missionPassTermination)
    : map admitted report.missionPassAdmitted
      <> map attention report.missionPassAttention
      <> ["  " <> report.missionPassDetail | not (Text.null report.missionPassDetail)]
  where
    admitted record =
      "  "
        <> record.missionDispositionMission.unMissionId
        <> " "
        <> missionDispositionTag record.missionDispositionValue
        <> ": "
        <> record.missionDispositionDetail

    attention record =
      "  "
        <> record.missionAttentionRecordMission.unMissionId
        <> " needs attention ("
        <> record.missionAttentionRecordId.unMissionAttentionId
        <> "); notification "
        <> missionNotificationStateTag record.missionAttentionRecordNotification
