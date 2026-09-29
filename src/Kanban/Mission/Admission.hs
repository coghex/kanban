{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE InterruptibleFFI #-}

-- | The repository's agent ceiling and the rotation that shares it (D-4 as
-- amended, D-8; issue #746).
--
-- At most a configured number of mission-dispatched agents — two unless
-- @[missions] agent_ceiling@ says otherwise — may be live at once for one
-- repository, counted across every mission, every pass, and every checkout of
-- that repository. A mission that wants to start one asks here first; a
-- mission that only watches its own live worker, settles a step, or records a
-- result never does, so the ceiling can never hold those back.
--
-- Three records decide an answer, and each is read under one lock.
--
-- /Occupancy/ is counted from the worker cache rather than from anything a
-- mission wrote: a worker whose specification names a mission invocation is
-- a mission's agent, and it is live until its own records prove otherwise.
-- The proof is "Kanban.Worker.Lease"'s — a recorded identity a snapshot no
-- longer finds, a terminal state, an acknowledged launch that never started —
-- and every doubt reads as occupied. A worker the board launched names no
-- invocation and is never counted; the repository's shared review host names
-- none either, while each issue action a mission launched onto it does.
--
-- /Reservations/ cover the one window the cache cannot: between a slot being
-- granted and the worker it was granted for writing its specification. A
-- reservation is keyed by the invocation the launch will write into that
-- specification, so once the worker is there the two are one agent rather
-- than two, and a reservation whose holder died is dropped without releasing
-- anything a surviving worker still occupies.
--
-- /The rotation/ is the sequence of successful admissions. A mission's place
-- in it is the number of its latest one, so the mission admitted longest ago
-- — or never — goes first, and a launch that failed or joined somebody else's
-- worker leaves its mission's place exactly where it was. Missions that are
-- about to ask wait in line as /entrants/: a scheduler pass enters every
-- mission it launches a child for, in rotation order, before any child
-- starts, so which child reaches the lock first decides nothing. A slot a
-- mission ahead of this one may still take is left for it; a slot nobody
-- ahead can take is used, which is what keeps the rotation work-conserving.
--
-- This module adds no authority and weakens none. The per-target worker lease
-- and the canonical approval lock still decide, beneath it, whether a granted
-- launch may happen at all; a refusal there simply returns the slot.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Admission
  ( -- * Occupancy
    MissionAgentOccupant (..),
    observeMissionAgents,
    observeMissionAgentsWith,
    missionAgentsLive,

    -- * Admission
    MissionAdmissionSeams (..),
    liveMissionAdmissionSeams,
    MissionAgentSlotDecision (..),
    claimMissionAgentSlot,
    settleMissionAgentSlot,
    expectMissionAgents,
    withdrawExpectedMission,

    -- * The durable record
    MissionAdmissionState (..),
    MissionAdmissionReservation (..),
    MissionAdmissionEntrant (..),
    emptyMissionAdmissionState,
    readMissionAdmissionState,
    missionAdmissionStatePath,
    missionAdmissionSchemaVersion,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, allowInterrupt, bracket, try)
import Control.Monad (unless, void, when)
import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeStrict', encode, object, withObject, (.:), (.=))
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, isJust, isNothing, mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, getCurrentTime)
import Foreign.C.Error (eINTR, getErrno, throwErrno)
import Foreign.C.Types (CInt (..))
import Kanban.Config (asciiLowercase)
import Kanban.Domain (Repository (..))
import Kanban.Mission.Lease (MissionHolderPresence (..), missionHolderPresence)
import Kanban.Mission.Paths (MissionStore (..))
import Kanban.Mission.Types (MissionId (..))
import Kanban.Paths (createPrivateDirectory)
import Kanban.Process (IdentityPresence (..), ProcessIdentity, checkIdentityPresenceWith, defaultProcessSnapshot)
import Kanban.Worker.Paths (IssueActionClaim (..), decodeFile, descriptorForSpec, readIssueActionClaim, safePathComponent, workerDirectory)
import Kanban.Worker.Types
  ( WorkerDescriptor (..),
    WorkerLease (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
  )
import System.Directory (XdgDirectory (XdgState), doesDirectoryExist, doesFileExist, listDirectory, renameFile)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (setFileMode)
import System.Posix.IO (OpenFileFlags (..), OpenMode (ReadWrite), closeFd, defaultFileFlags, openFd)
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd (..))

-- ---------------------------------------------------------------------------
-- Occupancy
-- ---------------------------------------------------------------------------

-- | One mission-dispatched worker the cache holds, or one record the cache
-- holds that nothing could attribute.
data MissionAgentOccupant = MissionAgentOccupant
  { -- | The specification's file name, which is what names the worker even
    -- when the specification itself will not decode.
    missionOccupantRecord :: FilePath,
    -- | The mission invocation the worker's specification names. 'Nothing'
    -- only for a specification that will not decode, which cannot be told
    -- apart from a mission's agent and is therefore counted as one.
    missionOccupantInvocation :: Maybe Text,
    -- | Whether it holds a slot now.
    missionOccupantLive :: Bool,
    -- | Whether its launch got as far as starting it: a state was written.
    -- Only such a launch is an admission the rotation counts.
    missionOccupantStarted :: Bool
  }
  deriving stock (Eq, Show)

-- | Every mission agent this repository's worker cache holds, whichever
-- checkout launched it.
observeMissionAgents :: Repository -> IO (Either Text [MissionAgentOccupant])
observeMissionAgents = observeMissionAgentsWith defaultProcessSnapshot

-- | 'observeMissionAgents' with the process snapshot injected.
--
-- Read straight from the directory rather than through
-- 'Kanban.Worker.discoverWorkerHistory', and for two reasons that each would
-- let a slot be counted free that is not. That function keeps only workers
-- launched from the very checkout asking, while a repository's ceiling spans
-- every checkout of it; and it drops a specification that will not decode,
-- which here is a record nobody can prove is not an agent. The worker
-- directory is already one per repository identity, so a second checkout's
-- workers are here to be counted — beside, possibly, another repository's
-- whose name happens to fold the same way, which the identity comparison
-- below leaves out.
--
-- A directory that cannot be listed is a 'Left': an occupancy nobody could
-- read is not an empty one.
observeMissionAgentsWith :: IO (Either Text [ProcessIdentity]) -> Repository -> IO (Either Text [MissionAgentOccupant])
observeMissionAgentsWith takeFreshSnapshot repository = do
  -- One process snapshot for the whole observation, taken only if some
  -- worker's records need one: a claim observes on every poll, and a
  -- snapshot per worker per poll would be a @ps@ per worker per poll.
  memo <- newIORef Nothing
  let takeSnapshot = do
        cached <- readIORef memo
        case cached of
          Just snapshot -> pure snapshot
          Nothing -> do
            snapshot <- takeFreshSnapshot
            writeIORef memo (Just snapshot)
            pure snapshot
  directories <- workerDirectoriesOf repository
  case directories of
    Left detail -> pure (Left detail)
    Right found -> do
      scanned <- mapM (scan takeSnapshot) found
      pure (concat <$> sequence scanned)
  where
    isSpecification entry = safePathComponent entry && ".spec.json" `Text.isSuffixOf` Text.pack entry

    scan takeSnapshot directory = do
      listed <- try @IOException (listDirectory directory)
      case listed of
        Left exception
          | isDoesNotExistError exception -> pure (Right [])
          | otherwise -> pure (Left (unlistable directory exception))
        Right entries ->
          Right . catMaybes
            <$> mapM (occupantFrom takeSnapshot directory) [entry | entry <- entries, isSpecification entry]

    occupantFrom takeSnapshot directory entry = do
      decoded <- decodeFile (directory </> entry) :: IO (Either Text WorkerSpec)
      case decoded of
        -- Removed between the listing and the read: a record something has
        -- already collected is not an agent.
        Left _ -> do
          stillThere <- doesFileExist (directory </> entry)
          pure $
            if stillThere
              then Just (MissionAgentOccupant entry Nothing True False)
              else Nothing
        Right spec
          | not (sameRepository spec.workerRepository) -> pure Nothing
          | otherwise -> case (spec.workerInvocation, spec.workerTask) of
              (Nothing, _) -> pure Nothing
              -- A host is never an agent of its own; the children it runs are.
              (_, IssueHostWorkerTaskKind _) -> pure Nothing
              (Just invocation, _) -> do
                descriptor <- descriptorForSpec spec
                live <- workerOccupies takeSnapshot descriptor
                -- A launch that started wrote a state: a solve or
                -- pull-request launch waits for its supervisor's state before
                -- it reports success, and an issue action's is written before
                -- its specification. A launch that failed to start leaves its
                -- specification acknowledged and no state beside it.
                started <- doesFileExist descriptor.workerDescriptorStatePath
                pure (Just (MissionAgentOccupant entry (Just invocation) live started))

    sameRepository other =
      asciiLowercase other.repositoryOwner == asciiLowercase repository.repositoryOwner
        && asciiLowercase other.repositoryName == asciiLowercase repository.repositoryName

-- | Every worker directory that may hold this repository's workers.
--
-- The directory is named from the owner and name as a checkout spelled them,
-- and a remote or @--repo@ may spell one repository @Coghex\/Kanban@ in one
-- checkout and @coghex\/kanban@ in another. GitHub treats those as one
-- repository and so does the ceiling, so every sibling whose name folds to
-- this one's is read; the identity each specification records is what
-- decides whether a worker in one of them is this repository's.
workerDirectoriesOf :: Repository -> IO (Either Text [FilePath])
workerDirectoriesOf repository = do
  directory <- workerDirectory repository
  let root = takeDirectory directory
      wanted = foldName (takeFileName directory)
  present <- try @IOException (doesDirectoryExist root)
  case present of
    Left exception -> pure (Left (unlistable root exception))
    Right False -> pure (Right [])
    Right True -> do
      listed <- try @IOException (listDirectory root)
      pure $ case listed of
        Left exception
          | isDoesNotExistError exception -> Right []
          | otherwise -> Left (unlistable root exception)
        Right entries -> Right [root </> entry | entry <- entries, safePathComponent entry, foldName entry == wanted]
  where
    foldName = Text.unpack . asciiLowercase . Text.pack

unlistable :: FilePath -> IOException -> Text
unlistable directory exception =
  "the worker cache " <> Text.pack directory <> " could not be read, so the agents live in it could not be counted: " <> Text.pack (show exception)

-- | Whether one mission worker still holds a slot.
--
-- Every doubt is an occupied slot. That is the same side
-- "Kanban.Worker.Lease" falls on for the same kind of question, and for the
-- same reason: a slot counted free that was not is a third agent, while a slot
-- counted occupied that was not costs one pass's wait.
workerOccupies :: IO (Either Text [ProcessIdentity]) -> WorkerDescriptor -> IO Bool
workerOccupies takeSnapshot descriptor = do
  stateRead <- readState descriptor.workerDescriptorStatePath
  case descriptor.workerDescriptorSpec.workerTask of
    -- An issue action has no supervisor of its own: the worker identity its
    -- state records is its host's, and a host that died leaves its unfinished
    -- children to be re-homed and run by the next one. So an unfinished action
    -- is live whatever its host's process says.
    --
    -- Without a state it is live too. Its launch writes the state before the
    -- specification and does not stop on a state it failed to write, so a
    -- host can adopt and run an action whose state is missing; a launch
    -- that really failed removes the specification itself, and then there
    -- is nothing here to count.
    --
    -- Terminal is not the end of it either. What the action ran on the host's
    -- behalf — a canonical review's subprocess — is recorded as its own, and
    -- a termination that could not be confirmed can leave one running beside
    -- a terminal state. The host's identity is left out: it outlives every
    -- action by design.
    --
    -- The one proof that an unfinished action will never run is its launch's
    -- withdrawal claim: a host turns away every action that carries one.
    IssueActionWorkerTaskKind _ -> do
      claim <- readIssueActionClaim descriptor
      case claim of
        Right (Just ClaimedByWithdrawal) -> pure False
        _ -> issueActionLive stateRead
    _ -> case stateRead of
      StateUnreadable -> pure True
      StateRead state -> case state.workerStateStatus of
        -- A terminal write has already verified that nothing it recorded
        -- survives; asked again anyway, as the lease asks it, because a
        -- surviving identity is an agent whatever the label says.
        WorkerTerminal _
          | null (identities state) -> pure False
          | otherwise -> (/= IdentityAbsent) <$> checkIdentityPresenceWith takeSnapshot (identities state)
        _ -> recordedIdentitiesLive state
      StateAbsent -> do
        -- No state yet. A launch that could not start its supervisor
        -- acknowledges the worker before it gives the lease back, so an
        -- acknowledged worker with no state never ran.
        acknowledged <- doesFileExist descriptor.workerDescriptorAckPath
        if acknowledged then pure False else launchStillLive
  where
    issueActionLive stateRead = case stateRead of
      StateAbsent -> pure True
      StateUnreadable -> pure True
      StateRead state -> case state.workerStateStatus of
        -- A settle that could not show its gate's tree ended keeps the
        -- gate's pid on the terminal state; one with no identity beside it
        -- is a process nothing can ever check, so its slot stays taken.
        WorkerTerminal _
          | isJust state.workerStateProviderPid && isNothing state.workerStateProviderIdentity -> pure True
          | null (ownedProcesses state) -> pure False
          | otherwise -> (/= IdentityAbsent) <$> checkIdentityPresenceWith takeSnapshot (ownedProcesses state)
        _ -> pure True

    ownedProcesses state = maybe [] (: []) state.workerStateProviderIdentity <> state.workerStateKnownProcesses

    identities state =
      maybe [] (: []) state.workerStateWorkerIdentity
        <> maybe [] (: []) state.workerStateProviderIdentity
        <> state.workerStateKnownProcesses

    -- 'Kanban.Worker.Lease.recordedIdentitiesActive', with the snapshot
    -- injected: an unverified identity, a surviving one, and a snapshot that
    -- could not be taken all keep the slot, and so does a user termination
    -- the supervisor never got to finish.
    recordedIdentitiesLive state = case state.workerStateWorkerIdentity of
      Nothing -> pure True
      Just _ -> do
        presence <- checkIdentityPresenceWith takeSnapshot (identities state)
        case presence of
          IdentityAbsent -> doesFileExist descriptor.workerDescriptorPendingTerminationPath
          _ -> pure True

    -- The supervisor identity the launch recorded on the item's lease is the
    -- only evidence there is before a state file exists. A lease some other
    -- worker now holds says this launch's supervisor is gone: a lease is only
    -- ever given up by a worker that finished or retired as provably dead.
    launchStillLive = do
      lease <- decodeFile descriptor.workerDescriptorLeaseOwnerPath :: IO (Either Text WorkerLease)
      case lease of
        Left _ -> do
          leased <- doesDirectoryExist descriptor.workerDescriptorLeasePath
          pure leased
        Right owner
          | owner.workerLeaseId /= descriptor.workerDescriptorSpec.workerId -> pure False
          | otherwise -> case owner.workerLeaseSupervisorIdentity of
              Nothing -> pure True
              Just identity -> (/= IdentityAbsent) <$> checkIdentityPresenceWith takeSnapshot [identity]

-- | The invocations whose launch started a worker, which is what the rotation
-- counts as an admission.
startedInvocations :: [MissionAgentOccupant] -> Set.Set Text
startedInvocations occupants =
  Set.fromList [invocation | MissionAgentOccupant {missionOccupantInvocation = Just invocation, missionOccupantStarted = True} <- occupants]

-- | How many slots the occupants hold, before any reservation.
missionAgentsLive :: [MissionAgentOccupant] -> Int
missionAgentsLive occupants =
  Set.size (Set.fromList [invocation | MissionAgentOccupant {missionOccupantInvocation = Just invocation, missionOccupantLive = True} <- occupants])
    + length [() | MissionAgentOccupant {missionOccupantInvocation = Nothing, missionOccupantLive = True} <- occupants]

-- | A worker state file: there, there and unreadable, or absent.
data StateRead = StateAbsent | StateUnreadable | StateRead WorkerState

readState :: FilePath -> IO StateRead
readState path = do
  exists <- doesFileExist path
  if not exists
    then pure StateAbsent
    else do
      decoded <- decodeFile path
      pure (either (const StateUnreadable) StateRead decoded)

-- ---------------------------------------------------------------------------
-- The durable record
-- ---------------------------------------------------------------------------

-- | Everything admission remembers between one claim and the next.
data MissionAdmissionState = MissionAdmissionState
  { -- | How many admissions have succeeded, ever. The next one is numbered
    -- one past it.
    missionAdmissionSequence :: Int,
    -- | Each mission's latest successful admission, by that number. A mission
    -- absent here has never been admitted and goes before every one that has.
    missionAdmissionRotation :: Map Text Int,
    missionAdmissionReservations :: [MissionAdmissionReservation],
    missionAdmissionEntrants :: [MissionAdmissionEntrant]
  }
  deriving stock (Eq, Show)

-- | A slot granted for one launch whose worker may not have written its
-- specification yet.
data MissionAdmissionReservation = MissionAdmissionReservation
  { missionReservationInvocation :: Text,
    missionReservationMission :: MissionId,
    -- | The process the slot was granted to. A reservation outlives nothing:
    -- once this process is gone, whatever it launched is counted from its
    -- own records.
    missionReservationHolder :: Int,
    missionReservationAt :: UTCTime
  }
  deriving stock (Eq, Show)

-- | A mission waiting its turn, and the process it is waiting through: the
-- pass that is about to launch its child, or the child at the lock.
data MissionAdmissionEntrant = MissionAdmissionEntrant
  { missionEntrantMission :: MissionId,
    missionEntrantHolder :: Int,
    missionEntrantAt :: UTCTime
  }
  deriving stock (Eq, Show)

emptyMissionAdmissionState :: MissionAdmissionState
emptyMissionAdmissionState = MissionAdmissionState 0 Map.empty [] []

missionAdmissionSchema :: Text
missionAdmissionSchema = "kanban-mission-admission"

missionAdmissionSchemaVersion :: Int
missionAdmissionSchemaVersion = 1

instance ToJSON MissionAdmissionState where
  toJSON state =
    object
      [ "schema" .= missionAdmissionSchema,
        "version" .= missionAdmissionSchemaVersion,
        "sequence" .= state.missionAdmissionSequence,
        "rotation" .= state.missionAdmissionRotation,
        "reservations" .= map reservation state.missionAdmissionReservations,
        "entrants" .= map entrant state.missionAdmissionEntrants
      ]
    where
      reservation value =
        object
          [ "invocation" .= value.missionReservationInvocation,
            "mission" .= value.missionReservationMission.unMissionId,
            "holder" .= value.missionReservationHolder,
            "at" .= value.missionReservationAt
          ]
      entrant value =
        object
          [ "mission" .= value.missionEntrantMission.unMissionId,
            "holder" .= value.missionEntrantHolder,
            "at" .= value.missionEntrantAt
          ]

instance FromJSON MissionAdmissionState where
  parseJSON = withObject "mission admission state" $ \document -> do
    schema <- document .: "schema"
    when (schema /= missionAdmissionSchema) $
      fail ("unknown schema " <> show (schema :: Text))
    version <- document .: "version"
    when (version /= missionAdmissionSchemaVersion) $
      fail ("unknown schema version " <> show (version :: Int))
    MissionAdmissionState
      <$> document .: "sequence"
      <*> document .: "rotation"
      <*> (document .: "reservations" >>= mapM reservation)
      <*> (document .: "entrants" >>= mapM entrant)
    where
      reservation = withObject "reservation" $ \value ->
        MissionAdmissionReservation
          <$> value .: "invocation"
          <*> (MissionId <$> value .: "mission")
          <*> value .: "holder"
          <*> value .: "at"
      entrant = withObject "entrant" $ \value ->
        MissionAdmissionEntrant
          <$> (MissionId <$> value .: "mission")
          <*> value .: "holder"
          <*> value .: "at"

-- | @\<missions\>\/.admission\/\<owner\>\/\<repo\>\/state.json@.
--
-- Beside the mission store rather than in it — see
-- 'Kanban.Mission.Paths.missionStoreAdmissionDirectory' — and keyed as that
-- store is, once per canonical repository identity and shared by every
-- checkout of it, which is exactly the scope D-4 and D-14 give the ceiling.
-- In the state root rather than the cache, because the rotation is what a
-- restarted runner resumes from.
missionAdmissionStatePath :: MissionStore -> FilePath
missionAdmissionStatePath store = store.missionStoreAdmissionDirectory </> "state.json"

missionAdmissionLockPath :: MissionStore -> FilePath
missionAdmissionLockPath store = store.missionStoreAdmissionDirectory </> "lock"

-- | The record as it stands, with no lock held: for a reader that decides
-- nothing, such as a test or a report.
readMissionAdmissionState :: MissionStore -> IO (Either Text MissionAdmissionState)
readMissionAdmissionState store = readAdmissionFile (missionAdmissionStatePath store)

readAdmissionFile :: FilePath -> IO (Either Text MissionAdmissionState)
readAdmissionFile path = do
  loaded <- try @IOException (ByteString.readFile path)
  pure $ case loaded of
    Left exception
      | isDoesNotExistError exception -> Right emptyMissionAdmissionState
      | otherwise -> Left (unreadable (Text.pack (show exception)))
    Right bytes -> case eitherDecodeStrict' bytes of
      Left message -> Left (unreadable (Text.pack message))
      Right state -> Right state
  where
    -- Not read as empty. An empty record would forget every reservation in
    -- flight, and a slot granted and forgotten is a slot granted twice.
    unreadable detail =
      "the agent admission record " <> Text.pack path <> " could not be read, so no slot can be granted against it: " <> detail

writeAdmissionFile :: FilePath -> MissionAdmissionState -> IO (Either Text ())
writeAdmissionFile path state = do
  let staging = path <> ".tmp"
  written <- try @IOException $ do
    LazyByteString.writeFile staging (encode state)
    setFileMode staging 0o600
    renameFile staging path
  pure (either (Left . ("the agent admission record could not be written: " <>) . Text.pack . show) Right written)

-- ---------------------------------------------------------------------------
-- Admission
-- ---------------------------------------------------------------------------

-- | Everything admission reaches outside its own record.
data MissionAdmissionSeams = MissionAdmissionSeams
  { missionAdmissionOccupants :: IO (Either Text [MissionAgentOccupant]),
    -- | Whether a recorded holder may still be running. 'False' only when it
    -- is provably gone.
    missionAdmissionHolderAlive :: Int -> IO Bool,
    missionAdmissionNow :: IO UTCTime,
    missionAdmissionSelf :: IO Int,
    -- | How long one wait for a mission ahead lasts, and how many of them a
    -- claim will make before it stops waiting.
    missionAdmissionPollMicros :: Int,
    missionAdmissionPolls :: Int
  }

-- | The seams that read this machine.
--
-- A holder is asked about with @kill(pid, 0)@, which is the mission lease's own
-- liveness rule and shares its bias: a recycled identifier reads as the
-- holder, so a dead holder's reservation can outlive it, and never the
-- reverse.
--
-- A claim waits for missions ahead of it for at most two minutes. Those are
-- children of a pass taking one transition each, so the bound is never
-- reached in ordinary operation; it is there so that a wait can never become
-- a pass that does not end.
liveMissionAdmissionSeams :: Repository -> MissionAdmissionSeams
liveMissionAdmissionSeams repository =
  MissionAdmissionSeams
    { missionAdmissionOccupants = observeMissionAgents repository,
      missionAdmissionHolderAlive = \holder -> (/= MissionHolderGone) <$> missionHolderPresence holder,
      missionAdmissionNow = getCurrentTime,
      missionAdmissionSelf = fromIntegral <$> getProcessID,
      missionAdmissionPollMicros = 250 * 1000,
      missionAdmissionPolls = 480
    }

-- | What a claim came to.
data MissionAgentSlotDecision
  = -- | A slot is reserved for this invocation until
    -- 'settleMissionAgentSlot' is called with it.
    MissionAgentSlotGranted
  | -- | Every slot is in use, or spoken for by a mission ahead in the
    -- rotation. Nothing was reserved; ask again later.
    MissionAgentSlotHeld Text
  | -- | Nothing could be decided: the lock, the record, or the worker cache
    -- could not be read. Nothing was reserved.
    MissionAgentSlotUndecided Text
  deriving stock (Eq, Show)

-- | Asks for one slot for one launch.
--
-- Granted when fewer slots are in use than the ceiling allows by more than the
-- number of missions ahead of this one that are waiting for one. Held at once
-- when every slot is in use and no launch is still in flight. Otherwise it
-- waits — for the missions ahead to take their slots, or for a launch in
-- flight to show whether it needed its slot after all — and asks again.
claimMissionAgentSlot :: MissionAdmissionSeams -> MissionStore -> Int -> MissionId -> Text -> IO MissionAgentSlotDecision
claimMissionAgentSlot seams store agentCeiling mission invocation = attempt seams.missionAdmissionPolls
  where
    attempt remaining = do
      step <- withAdmission seams store (decide remaining)
      case step of
        Left detail -> pure (MissionAgentSlotUndecided detail)
        Right (Just decision) -> pure decision
        Right Nothing -> do
          threadDelay seams.missionAdmissionPollMicros
          attempt (remaining - 1)

    decide remaining occupants state = do
      self <- seams.missionAdmissionSelf
      now <- seams.missionAdmissionNow
      let visible = Set.fromList (mapMaybe (.missionOccupantInvocation) occupants)
          liveInvocations = Set.fromList [invocation' | MissionAgentOccupant {missionOccupantInvocation = Just invocation', missionOccupantLive = True} <- occupants]
          -- A reservation whose worker is not there yet is a launch in flight
          -- and holds its slot; one whose worker is there is that worker,
          -- counted once as whatever the worker's own records say.
          inFlight = [reservation | reservation <- state.missionAdmissionReservations, not (Set.member reservation.missionReservationInvocation visible)]
          inUse = missionAgentsLive occupants + Set.size (Set.fromList (map (.missionReservationInvocation) inFlight) `Set.difference` liveInvocations)
          free = agentCeiling - inUse
          ahead = nub [entrant.missionEntrantMission | entrant <- state.missionAdmissionEntrants, entrant.missionEntrantMission /= mission, rankOf state entrant.missionEntrantMission < rankOf state mission]
          withoutMine = filter ((/= mission) . (.missionEntrantMission)) state.missionAdmissionEntrants
          counted = Text.pack (show inUse) <> " of " <> Text.pack (show agentCeiling) <> " agent slots are in use"
      pure $
        if free > length ahead
          then
            ( Just
                state
                  { missionAdmissionReservations =
                      state.missionAdmissionReservations
                        <> [MissionAdmissionReservation invocation mission self now],
                    missionAdmissionEntrants = withoutMine
                  },
              Just MissionAgentSlotGranted
            )
          else
            if (free > 0 || not (null inFlight)) && remaining > 0
              then
                -- Waiting in line: entered, so a mission behind this one
                -- leaves this one's slot alone.
                ( if any (\entrant -> entrant.missionEntrantMission == mission && entrant.missionEntrantHolder == self) state.missionAdmissionEntrants
                    then Nothing
                    else Just state {missionAdmissionEntrants = state.missionAdmissionEntrants <> [MissionAdmissionEntrant mission self now]},
                  Nothing
                )
              else
                ( Just state {missionAdmissionEntrants = withoutMine},
                  Just
                    ( MissionAgentSlotHeld
                        ( if free > 0
                            then counted <> ", and every free one is being left for a mission ahead of this one in the rotation"
                            else counted
                        )
                    )
                )

-- | Returns a claimed slot once the launch it was claimed for has an outcome.
--
-- The reservation goes whatever happened, because once the launch is over the
-- worker it produced — if it produced one — is counted from its own records.
-- Whether it produced one is also what decides the rotation: a mission moves
-- to the back only when a worker naming this very invocation exists. A launch
-- that was refused, went stale, or joined a worker somebody else started
-- leaves its mission's place alone.
settleMissionAgentSlot :: MissionAdmissionSeams -> MissionStore -> Text -> IO (Either Text ())
settleMissionAgentSlot seams store invocation =
  withAdmission seams store $ \occupants state -> do
    let (settled, kept) = foldr split ([], []) state.missionAdmissionReservations
        split reservation (matched, others)
          | reservation.missionReservationInvocation == invocation = (reservation : matched, others)
          | otherwise = (matched, reservation : others)
        launched = [reservation.missionReservationMission | reservation <- settled, Set.member invocation (startedInvocations occupants)]
    pure
      ( if null settled then Nothing else Just (foldr admitted state {missionAdmissionReservations = kept} launched),
        ()
      )

-- | Enters the missions a pass is about to advance, and returns them in the
-- order the rotation serves them.
--
-- The order is the one the pass launches and waits for its children in. That
-- is what makes a wait safe: a child only ever waits for missions ahead of it,
-- and the pass withdraws each of those as soon as its child is done.
expectMissionAgents :: MissionAdmissionSeams -> MissionStore -> [MissionId] -> IO (Either Text [MissionId])
expectMissionAgents seams store missions =
  withAdmission seams store $ \_ state -> do
    self <- seams.missionAdmissionSelf
    now <- seams.missionAdmissionNow
    let entered = [MissionAdmissionEntrant mission self now | mission <- missions]
        ordered = sortOn (rankOf state) missions
    pure (Just state {missionAdmissionEntrants = state.missionAdmissionEntrants <> entered}, ordered)

-- | Withdraws what this process entered for one mission.
withdrawExpectedMission :: MissionAdmissionSeams -> MissionStore -> MissionId -> IO (Either Text ())
withdrawExpectedMission seams store mission =
  withAdmission seams store $ \_ state -> do
    self <- seams.missionAdmissionSelf
    let kept = [entrant | entrant <- state.missionAdmissionEntrants, not (entrant.missionEntrantMission == mission && entrant.missionEntrantHolder == self)]
    pure
      ( if length kept == length state.missionAdmissionEntrants then Nothing else Just state {missionAdmissionEntrants = kept},
        ()
      )

-- | A mission's place in the rotation: never admitted first, then the one
-- admitted longest ago, and the identifier between two that tie.
rankOf :: MissionAdmissionState -> MissionId -> (Int, Text)
rankOf state mission = (Map.findWithDefault (-1) mission.unMissionId state.missionAdmissionRotation, mission.unMissionId)

-- | Moves a mission to the back of the rotation.
admitted :: MissionId -> MissionAdmissionState -> MissionAdmissionState
admitted mission state =
  state
    { missionAdmissionSequence = next,
      missionAdmissionRotation = Map.insert mission.unMissionId next state.missionAdmissionRotation
    }
  where
    next = state.missionAdmissionSequence + 1

-- | One read-decide-write of the record, under the lock, with the worker
-- cache read inside it and every record a gone process left dropped first.
--
-- The decision returns the record to write, or 'Nothing' to leave it as it
-- was. Nothing is decided when the cache or the record cannot be read.
withAdmission ::
  MissionAdmissionSeams ->
  MissionStore ->
  ([MissionAgentOccupant] -> MissionAdmissionState -> IO (Maybe MissionAdmissionState, result)) ->
  IO (Either Text result)
withAdmission seams store decide =
  withAdmissionLock store $ do
    loaded <- readAdmissionFile (missionAdmissionStatePath store)
    case loaded of
      Left detail -> pure (Left detail)
      Right state -> do
        observed <- seams.missionAdmissionOccupants
        case observed of
          Left detail -> pure (Left detail)
          Right occupants -> do
            (pruned, changed) <- prune seams occupants state
            (decided, result) <- decide occupants pruned
            case (decided, changed) of
              (Nothing, False) -> pure (Right result)
              _ -> do
                written <- writeAdmissionFile (missionAdmissionStatePath store) (maybe pruned id decided)
                pure (result <$ written)

-- | Drops every reservation and entrant whose holder is provably gone.
--
-- A dropped reservation still counts as an admission when its worker exists:
-- the holder died after the launch it was granted for succeeded, and the
-- rotation is a record of launches rather than of the processes that made
-- them.
prune :: MissionAdmissionSeams -> [MissionAgentOccupant] -> MissionAdmissionState -> IO (MissionAdmissionState, Bool)
prune seams occupants state = do
  reservations <- mapM (\reservation -> (,) reservation <$> seams.missionAdmissionHolderAlive reservation.missionReservationHolder) state.missionAdmissionReservations
  entrants <- mapM (\entrant -> (,) entrant <$> seams.missionAdmissionHolderAlive entrant.missionEntrantHolder) state.missionAdmissionEntrants
  let started = startedInvocations occupants
      -- A launch whose worker is there and live but has not yet written its
      -- state is still starting: its launcher died, and its supervisor may
      -- not have. Dropping it would forget an admission that is still to
      -- happen, so it is kept, holder gone, until the worker either starts —
      -- and is counted — or is shown not to be running.
      starting =
        Set.fromList
          [ invocation
          | MissionAgentOccupant {missionOccupantInvocation = Just invocation, missionOccupantLive = True, missionOccupantStarted = False} <- occupants
          ]
      kept (reservation, alive) =
        alive || Set.member reservation.missionReservationInvocation starting
      gone = [reservation | (reservation, False) <- reservations, not (Set.member reservation.missionReservationInvocation starting)]
      launched = [reservation.missionReservationMission | reservation <- gone, Set.member reservation.missionReservationInvocation started]
      pruned =
        foldr
          admitted
          state
            { missionAdmissionReservations = [reservation | entry@(reservation, _) <- reservations, kept entry],
              missionAdmissionEntrants = [entrant | (entrant, True) <- entrants]
            }
          launched
      changed = not (null gone) || any (not . snd) entrants
  pure (pruned, changed)

-- | Runs an action holding the admission lock.
--
-- A @flock@ on a bare, close-on-exec descriptor, for the reasons
-- 'Kanban.Cache.withGhGroupRecordLock' gives: it queues a second opener in
-- this process as it queues one in another, the kernel releases it for a
-- holder that dies, and a spawned agent never inherits it. Every @EINTR@ lets
-- a pending exception through before the wait resumes.
withAdmissionLock :: MissionStore -> IO (Either Text result) -> IO (Either Text result)
withAdmissionLock store action = do
  let lockPath = missionAdmissionLockPath store
  bracket (try @IOException (openLock lockPath)) (either (const (pure ())) closeFd) $ \opened ->
    case opened of
      Left exception -> pure (Left (lockFailed exception))
      Right descriptor ->
        bracket (try @IOException (flockExclusive descriptor)) (either (const (pure ())) (const (flockRelease descriptor))) $ \taken ->
          case taken of
            Left exception -> pure (Left (lockFailed exception))
            Right () -> action
  where
    lockFailed exception = "the agent admission lock could not be taken: " <> Text.pack (show exception)

    openLock lockPath = do
      let directory = takeDirectory lockPath
      present <- doesDirectoryExist directory
      unless present (createPrivateDirectory XdgState directory)
      openFd lockPath ReadWrite defaultFileFlags {creat = Just 0o600, cloexec = True}

    flockExclusive (Fd descriptor) = do
      result <- c_admissionFlock descriptor admissionLockExclusive
      when (result == -1) $ do
        errno <- getErrno
        if errno == eINTR
          then allowInterrupt >> flockExclusive (Fd descriptor)
          else throwErrno "flock"

    flockRelease (Fd descriptor) = void (c_admissionFlock descriptor admissionLockUnlock)

foreign import capi interruptible "sys/file.h flock"
  c_admissionFlock :: CInt -> CInt -> IO CInt

foreign import capi "sys/file.h value LOCK_EX"
  admissionLockExclusive :: CInt

foreign import capi "sys/file.h value LOCK_UN"
  admissionLockUnlock :: CInt
