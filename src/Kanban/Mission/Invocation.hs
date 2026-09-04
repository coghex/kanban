{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The record a controller writes /before/ it does anything the outside world
-- can see, and reads back to find out what it was in the middle of.
--
-- A mission's event journal says what happened. This one says what was about
-- to happen, which is a different question and the only one a crash can be
-- recovered from: a process that dies between deciding to launch a solver and
-- launching it leaves no event, no worker, and no pull request, and nothing in
-- the durable record distinguishes that from never having decided at all. An
-- invocation record closes exactly that window (issue #595, requirement 5).
--
-- Four properties make it usable for recovery, and each is a discipline rather
-- than a convention:
--
--   [written first] The opening record is appended and @fsync@'d before the
--     effect is attempted. An append that has not reached the disk is not a
--     record a power loss leaves behind, and this is the one file in the
--     mission store whose whole purpose is to be readable after exactly that.
--   [stable identity] The identity is minted with the record and never
--     re-derived. Recovery deduplicates by it, so an identity a second run
--     would compute differently is an identity that deduplicates nothing.
--   [exact preconditions] The observation the effect was authorized against
--     travels with it, so a later run can ask whether that authorization still
--     holds instead of guessing from the current state alone (requirement 8).
--   [closed separately] The outcome is a second record rather than a rewrite,
--     because rewriting would need the file to be mutable in place and an
--     interrupted rewrite is precisely the state this file exists to survive.
--
-- An opening record with no closing record is not a failure. It is the
-- @outcome_unknown@ requirement 7 names: something may have happened, and only
-- fresh evidence about the target — never a blind retry — may resolve it.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Invocation
  ( MissionInvocationId (..),
    MissionTargetVersion (..),
    MissionIntendedEffect (..),
    missionIntendedEffectTag,
    MissionInvocation (..),
    MissionInvocationOutcome (..),
    missionInvocationOutcomeTag,
    MissionStaleVersion (..),
    missionStaleVersionMessage,
    missionVersionHolds,
    MissionInvocationState (..),
    missionInvocationResolved,
    missionInvocationFor,
    unresolvedMissionInvocations,
    newMissionInvocationId,
    recordMissionInvocation,
    concludeMissionInvocation,
    readMissionInvocations,
  )
where

import Control.Exception (IOException, bracket, onException, try)
import Data.Aeson
  ( FromJSON (..),
    Result (Error, Success),
    ToJSON (..),
    Value (Object),
    eitherDecodeStrict',
    encode,
    fromJSON,
  )
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Kanban.Mission.Types
  ( MissionEnvelope (..),
    MissionId (..),
    MissionRepository,
    MissionStepId (..),
    MissionTarget (..),
    MissionTargetKind,
    missionInvocationSchemaVersion,
    missionRepositoryMatches,
  )
import Kanban.Worker (consumeJournalLines)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (setFdMode)
import System.Posix.IO (OpenFileFlags (append, creat), OpenMode (WriteOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.IO.ByteString (fdWrite)
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd)
import System.Posix.Unistd (fileSynchronise)

-- | One attempted effect, named once and for good.
newtype MissionInvocationId = MissionInvocationId {unMissionInvocationId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The exact live facts an effect was authorized against.
--
-- Recorded whole rather than as a single opaque fingerprint, so a mismatch can
-- say /which/ fact moved. Requirement 8 asks for an exact precondition, and
-- 'missionVersionHolds' is that exactness: every field must agree, with the
-- labels compared as a sorted set because GitHub's ordering is not a fact
-- about the issue.
data MissionTargetVersion = MissionTargetVersion
  { missionVersionKind :: MissionTargetKind,
    missionVersionNumber :: Int,
    -- | The item's own last-update instant, which is what moves for a body
    -- edit, a label change, or a comment.
    missionVersionUpdatedAt :: UTCTime,
    -- | A pull request's head commit. 'Nothing' for an issue.
    missionVersionHead :: Maybe Text,
    missionVersionLabels :: [Text],
    -- | @open@, @closed@, or @merged@ — the lifecycle word the board derives,
    -- carried so a target that became terminal is a precondition failure
    -- rather than something to notice later.
    missionVersionState :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether the recorded precondition still describes the live observation.
--
-- Equality on everything, with labels normalized. Anything weaker would let an
-- effect proceed against a target that changed in a way the plan was never
-- checked against, which is the blind overwrite requirement 8 exists to make
-- impossible.
missionVersionHolds :: MissionTargetVersion -> MissionTargetVersion -> Bool
missionVersionHolds recorded observed = normalize recorded == normalize observed
  where
    normalize version = version {missionVersionLabels = sort version.missionVersionLabels}

-- | A precondition that no longer holds, carrying both readings.
data MissionStaleVersion = MissionStaleVersion
  { missionStaleRecorded :: MissionTargetVersion,
    missionStaleObserved :: MissionTargetVersion
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

missionStaleVersionMessage :: MissionStaleVersion -> Text
missionStaleVersionMessage stale =
  "#"
    <> Text.pack (show stale.missionStaleRecorded.missionVersionNumber)
    <> " changed after this effect was planned ("
    <> Text.intercalate ", " differences
    <> "); nothing was mutated"
  where
    recorded = stale.missionStaleRecorded
    observed = stale.missionStaleObserved
    differences =
      concat
        [ ["state " <> recorded.missionVersionState <> " → " <> observed.missionVersionState | recorded.missionVersionState /= observed.missionVersionState],
          ["it was updated" | recorded.missionVersionUpdatedAt /= observed.missionVersionUpdatedAt],
          ["head " <> renderText recorded.missionVersionHead <> " → " <> renderText observed.missionVersionHead | recorded.missionVersionHead /= observed.missionVersionHead],
          ["labels changed" | sort recorded.missionVersionLabels /= sort observed.missionVersionLabels],
          ["a different item" | recorded.missionVersionNumber /= observed.missionVersionNumber || recorded.missionVersionKind /= observed.missionVersionKind]
        ]
    renderText = maybe "none" id

-- | What the effect was going to be.
--
-- Two, because the controller has two ways of reaching outside itself: it
-- starts registered work, and it ends registered work. Everything else it does
-- is a write to its own durable record, which the mission journal already
-- covers and which no outside authority can observe.
data MissionIntendedEffect
  = -- | Launch the named registry action against the recorded target.
    MissionEffectDispatch Text
  | -- | Signal the registered subtree rooted at the recorded session.
    MissionEffectTerminateSubtree Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

missionIntendedEffectTag :: MissionIntendedEffect -> Text
missionIntendedEffectTag (MissionEffectDispatch action) = "dispatch:" <> action
missionIntendedEffectTag (MissionEffectTerminateSubtree session) = "terminate:" <> session

-- | The five things requirement 5 asks to be durable before an effect, plus
-- the identity that ties them together and the instant that orders them.
data MissionInvocation = MissionInvocation
  { missionInvocationId :: MissionInvocationId,
    missionInvocationMission :: MissionId,
    missionInvocationRepository :: MissionRepository,
    missionInvocationStep :: MissionStepId,
    -- | The owning action: which registered authority this effect belongs to.
    missionInvocationAction :: Text,
    missionInvocationTarget :: Maybe MissionTarget,
    missionInvocationVersion :: Maybe MissionTargetVersion,
    missionInvocationEffect :: MissionIntendedEffect,
    missionInvocationAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | How an invocation ended, once something conclusive was observed.
data MissionInvocationOutcome
  = -- | The effect happened and named this durable child.
    MissionInvocationDispatched Text
  | MissionInvocationCompleted Text
  | -- | The owning authority declined before doing anything.
    MissionInvocationRefused Text
  | -- | The precondition had moved; nothing was mutated (requirement 8).
    MissionInvocationStale MissionStaleVersion
  | -- | Resolved as never having happened: on fresh evidence, on
    -- authenticated direction (requirement 7), or because the controller can
    -- see for itself that the effect was never attempted — the precondition
    -- read failed, or the durable marker that precedes a launch could not be
    -- written, and in neither case did anything reach the owning authority.
    MissionInvocationAbandoned Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

missionInvocationOutcomeTag :: MissionInvocationOutcome -> Text
missionInvocationOutcomeTag outcome = case outcome of
  MissionInvocationDispatched _ -> "dispatched"
  MissionInvocationCompleted _ -> "completed"
  MissionInvocationRefused _ -> "refused"
  MissionInvocationStale _ -> "stale_version"
  MissionInvocationAbandoned _ -> "abandoned"

-- | One invocation as the whole file describes it.
data MissionInvocationState = MissionInvocationState
  { missionInvocationRecord :: MissionInvocation,
    missionInvocationOutcome :: Maybe MissionInvocationOutcome
  }
  deriving stock (Eq, Show)

missionInvocationResolved :: MissionInvocationState -> Bool
missionInvocationResolved = isJust . (.missionInvocationOutcome)

missionInvocationFor :: MissionInvocationId -> [MissionInvocationState] -> Maybe MissionInvocationState
missionInvocationFor identity states =
  case [state | state <- states, state.missionInvocationRecord.missionInvocationId == identity] of
    (state : _) -> Just state
    [] -> Nothing

-- | Every invocation this store never saw the end of, oldest first.
--
-- The set recovery has to answer for. Requirement 7 forbids retrying any of
-- them on the strength of the record alone.
unresolvedMissionInvocations :: [MissionInvocationState] -> [MissionInvocationState]
unresolvedMissionInvocations = filter (not . missionInvocationResolved)

-- | A new identity: this process, this instant, and a counter the caller
-- supplies, so two invocations minted in one clock tick still differ.
newMissionInvocationId :: MissionStepId -> Int -> IO MissionInvocationId
newMissionInvocationId step sequenceNumber = do
  processId <- getProcessID
  now <- getCurrentTime
  pure
    ( MissionInvocationId
        ( Text.intercalate
            "-"
            [ step.unMissionStepId,
              Text.pack (show (toInteger processId)),
              Text.pack (formatInstant now),
              Text.pack (show sequenceNumber)
            ]
        )
    )
  where
    formatInstant = filter (`notElem` (" :-." :: String)) . show

-- | Appends the opening record and waits for it to reach the disk.
--
-- The @fsync@ is the whole difference between this and the event journal.
-- Requirement 5 asks for a /durably flushed/ record, and an append that is
-- still in the page cache is a record that a power loss removes — leaving
-- exactly the untracked effect the record exists to prevent.
recordMissionInvocation :: FilePath -> MissionInvocation -> IO (Either Text ())
recordMissionInvocation path invocation = appendRecord path (MissionInvocationOpened invocation)

-- | Appends the closing record for an identity already opened.
concludeMissionInvocation :: FilePath -> MissionInvocationId -> MissionInvocationOutcome -> UTCTime -> IO (Either Text ())
concludeMissionInvocation path identity outcome at = appendRecord path (MissionInvocationClosed identity outcome at)

-- | Both halves of the file, as one wire vocabulary.
data MissionInvocationRecord
  = MissionInvocationOpened MissionInvocation
  | MissionInvocationClosed MissionInvocationId MissionInvocationOutcome UTCTime
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

appendRecord :: FilePath -> MissionInvocationRecord -> IO (Either Text ())
appendRecord path record = do
  let line = LazyByteString.toStrict (encode (MissionEnvelope missionInvocationSchemaVersion record) <> "\n")
  result <-
    try @IOException
      ( bracket (openPrivateAppendDescriptor path) closeFd $ \descriptor -> do
          written <- fdWrite descriptor line
          fileSynchronise descriptor
          pure written
      )
  pure $ case result of
    Left exception -> Left (Text.pack (show exception))
    Right written
      | fromIntegral written == ByteString.length line -> Right ()
      | otherwise ->
          Left
            ( "only "
                <> Text.pack (show (toInteger written))
                <> " of "
                <> Text.pack (show (ByteString.length line))
                <> " bytes of an invocation record reached "
                <> Text.pack path
            )

-- | @0600@ on creation and reasserted on the descriptor, exactly as the event
-- journal's opener does it (§16).
openPrivateAppendDescriptor :: FilePath -> IO Fd
openPrivateAppendDescriptor path = do
  descriptor <- openFd path WriteOnly defaultFileFlags {append = True, creat = Just 0o600}
  onException (setFdMode descriptor 0o600) (closeFd descriptor)
  pure descriptor

-- | Every invocation this mission has recorded, oldest first, with the
-- outcome each one reached.
--
-- Deduplicated by identity on the way through: a record replayed by a
-- retried append contributes nothing new, and the /last/ closing record for an
-- identity wins, because an outcome resolved on later evidence supersedes an
-- earlier reading. Lines this release does not recognize are absent rather
-- than fatal, like every other mission record (§16); lines belonging to
-- another mission or repository are refused and reported, because a store
-- restored from a backup must not hand this run somebody else's history.
readMissionInvocations :: MissionId -> MissionRepository -> FilePath -> IO (Either Text [MissionInvocationState])
readMissionInvocations mission repository path = do
  contentResult <- try @IOException (ByteString.readFile path)
  pure $ case contentResult of
    Left exception
      | isDoesNotExistError exception -> Right []
      | otherwise -> Left (Text.pack (show exception))
    Right content -> assemble (fst (consumeJournalLines 0 content))
  where
    assemble = fmap ordered . foldl' step (Right (Map.empty, [] :: [MissionInvocationId]))
    ordered (states, order) = [state | identity <- reverse order, Just state <- [Map.lookup identity states]]
    step accumulator line = do
      (states, order) <- accumulator
      case decodeLine line of
        Nothing -> Right (states, order)
        Just (Left message) -> Left message
        Just (Right (MissionInvocationOpened invocation))
          | Map.member invocation.missionInvocationId states -> Right (states, order)
          | otherwise ->
              Right
                ( Map.insert
                    invocation.missionInvocationId
                    (MissionInvocationState invocation Nothing)
                    states,
                  invocation.missionInvocationId : order
                )
        Just (Right (MissionInvocationClosed identity outcome _)) ->
          Right (Map.adjust (\state -> state {missionInvocationOutcome = Just outcome}) identity states, order)
    decodeLine line = case eitherDecodeStrict' line of
      Left message -> Just (Left ("an invocation record in " <> Text.pack path <> " will not decode: " <> Text.pack message))
      Right value -> case value of
        Object fields -> case fromJSON (Object fields) :: Result (MissionEnvelope Value) of
          Error message -> Just (Left ("an invocation record in " <> Text.pack path <> " will not decode: " <> Text.pack message))
          Success envelope
            | envelope.missionEnvelopeSchemaVersion /= missionInvocationSchemaVersion -> Nothing
            | otherwise -> case fromJSON envelope.missionEnvelopePayload :: Result MissionInvocationRecord of
                Error message -> Just (Left ("an invocation record in " <> Text.pack path <> " will not decode: " <> Text.pack message))
                Success record -> Just (belongsHere record)
        _ -> Just (Left ("an invocation record in " <> Text.pack path <> " is not an object"))
    belongsHere record@(MissionInvocationOpened invocation)
      | invocation.missionInvocationMission /= mission =
          Left
            ( "an invocation record in "
                <> Text.pack path
                <> " belongs to mission "
                <> invocation.missionInvocationMission.unMissionId
            )
      | not (missionRepositoryMatches repository invocation.missionInvocationRepository) =
          Left ("an invocation record in " <> Text.pack path <> " belongs to another repository")
      | otherwise = Right record
    belongsHere record = Right record
