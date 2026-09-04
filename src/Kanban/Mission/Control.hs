{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The channel a running controller takes direction on, and the one place
-- that decides whether a command carries authority (issue #595, requirements
-- 12 and 14).
--
-- Everything a mission runs is text: a provider writes text, a repository
-- holds text, GitHub serves text, and every one of those reaches the runner
-- through a session it started. Requirement 14's rule is that none of it may
-- ever /become/ a command. That is not a property of the words — @pause the
-- mission@ is the same string whoever wrote it — so it has to be a property of
-- the path the words arrived on.
--
-- The path is a directory the runner creates for exactly one run, plus a secret
-- that run mints /in memory and never writes anywhere/. A command file naming
-- that secret can only have been written by the endpoint value the runner is
-- holding — which is the runner's own console and nothing else. Both authorities
-- are accepted and both become durable, and that is deliberate: an attached
-- dashboard is a legitimate client with no advancement lease, so its input is
-- recorded as an ordinary operator command and simply confers no override
-- authority. Only the authenticated half may record a @user_override@ or
-- resolve an @outcome_unknown@.
--
-- The secret staying out of the filesystem is what makes that separation hold.
-- Writing it beside the requests would hand it to every process that can read
-- the store — which is every attached client, and every provider session
-- running as this user — and the distinction the whole module exists for would
-- be a formality. An attached client therefore cannot obtain it at all:
-- 'attachMissionControl' does not look for one, because there is nothing on
-- disk for it to find.
--
-- The same rule is what makes a registered child request answerable. A request
-- names the parent it claims and the mission it claims, and both are checked
-- against durable state rather than believed: a parent that is not a live
-- registered session of /this/ mission is a forgery whatever channel it came
-- in on, and a request identity already answered returns the answer it already
-- has instead of launching a second child.
--
-- What this stops is exactly what requirement 14 names: provider output,
-- repository content, GitHub content, and unauthenticated process input can
-- each produce a command file — the directory is this user's and so are they —
-- and none of them can produce one that carries this run's secret. The window
-- a submitted command spends on disk before the runner consumes it is the only
-- place the secret exists outside the runner's own memory, under a @0700@
-- directory, and it closes on the next iteration.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Control
  ( MissionControlEndpoint (..),
    MissionCommandAuthority (..),
    missionCommandAuthorityTag,
    MissionCommandPayload (..),
    missionCommandPayloadTag,
    MissionChildRequest (..),
    MissionSubmittedCommand (..),
    MissionCommandRejection (..),
    missionCommandRejectionMessage,
    MissionCommandRead (..),
    openMissionControl,
    attachMissionControl,
    submitMissionCommand,
    readMissionCommands,
    consumeMissionCommand,
    overrideAuthorized,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Kanban.Mission.Paths
  ( MissionStore (..),
    ensureMissionDirectory,
    ignoreFileOperation,
    listMissionEntries,
    missionControlDirectory,
    missionControlRequestDirectory,
    readMissionRecord,
    MissionRead (..),
    writeMissionRecord,
  )
import Kanban.Mission.Types
  ( MissionId (..),
    MissionSessionId (..),
    MissionStepId (..),
    MissionTarget (..),
    missionCommandSchemaVersion,
  )
import System.Directory (removeFile)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)

-- | Where commands are left, and the secret that separates the runner's own
-- console from every other client.
data MissionControlEndpoint = MissionControlEndpoint
  { missionControlMission :: MissionId,
    missionControlDirectoryPath :: FilePath,
    missionControlRequests :: FilePath,
    -- | 'Just' for the runner that minted it, and 'Nothing' for every client
    -- that attached to the endpoint without owning it — which is precisely
    -- the client whose commands confer no override authority. There is no
    -- third case and no way to acquire one: the secret is never written down.
    missionControlSecret :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | Which of the two classes a command arrived in.
data MissionCommandAuthority
  = -- | Submitted on the channel this runner owns, naming this run's secret.
    MissionRunnerAuthenticated
  | -- | Submitted by some other client. Durable, ordinary, and powerless over
    -- an override or an unknown outcome.
    MissionAttachedClient
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

missionCommandAuthorityTag :: MissionCommandAuthority -> Text
missionCommandAuthorityTag MissionRunnerAuthenticated = "runner"
missionCommandAuthorityTag MissionAttachedClient = "attached"

-- | A child a live session asked the runner to register and launch on its
-- behalf.
--
-- The mission is named by the request rather than assumed from the endpoint it
-- arrived at, because assuming it is what makes a cross-mission forgery
-- unrepresentable /and/ undetectable: a request that names another mission is
-- a request this runner must refuse out loud, not one it silently reads as its
-- own.
data MissionChildRequest = MissionChildRequest
  { missionChildRequestId :: Text,
    missionChildRequestMission :: MissionId,
    missionChildRequestParent :: MissionSessionId,
    missionChildRequestAction :: Text,
    missionChildRequestTarget :: Maybe MissionTarget
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Everything a client may ask for.
data MissionCommandPayload
  = MissionPauseCommand Text
  | MissionResumeCommand
  | -- | Direction that resolves an @outcome_unknown@ or overrides a decision.
    -- Requires 'MissionRunnerAuthenticated' (requirement 14).
    MissionUserOverrideCommand MissionStepId Text
  | -- | End the registered subtree rooted at this session, explicitly and
    -- recursively (requirement 11).
    MissionTerminateSubtreeCommand MissionSessionId Text
  | MissionChildRequestCommand MissionChildRequest
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

missionCommandPayloadTag :: MissionCommandPayload -> Text
missionCommandPayloadTag payload = case payload of
  MissionPauseCommand _ -> "pause"
  MissionResumeCommand -> "resume"
  MissionUserOverrideCommand _ _ -> "user_override"
  MissionTerminateSubtreeCommand _ _ -> "terminate_subtree"
  MissionChildRequestCommand _ -> "child_request"

-- | Whether a command of this class may record a @user_override@ or resolve an
-- @outcome_unknown@.
--
-- One predicate, asked at the one place either of those happens, so
-- requirement 14's rule cannot be true of one path and forgotten on the other.
overrideAuthorized :: MissionCommandAuthority -> Bool
overrideAuthorized MissionRunnerAuthenticated = True
overrideAuthorized MissionAttachedClient = False

-- | The wire record a client writes.
data MissionCommandFile = MissionCommandFile
  { missionCommandFileId :: Text,
    missionCommandFileMission :: MissionId,
    missionCommandFileSecret :: Maybe Text,
    missionCommandFilePayload :: MissionCommandPayload,
    missionCommandFileSubmittedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One command the runner may act on, with the class it arrived in and the
-- file it came from so it can be consumed exactly once.
data MissionSubmittedCommand = MissionSubmittedCommand
  { missionCommandId :: Text,
    missionCommandAuthority :: MissionCommandAuthority,
    missionCommandPayload :: MissionCommandPayload,
    missionCommandSubmittedAt :: UTCTime,
    missionCommandPath :: FilePath
  }
  deriving stock (Eq, Show)

-- | A file in the request directory that is not a command for this mission.
data MissionCommandRejection = MissionCommandRejection
  { missionRejectionPath :: FilePath,
    missionRejectionReason :: Text
  }
  deriving stock (Eq, Show)

missionCommandRejectionMessage :: MissionCommandRejection -> Text
missionCommandRejectionMessage rejection =
  Text.pack rejection.missionRejectionPath <> ": " <> rejection.missionRejectionReason

-- | What one pass over the request directory found.
data MissionCommandRead = MissionCommandRead
  { missionCommandsAccepted :: [MissionSubmittedCommand],
    missionCommandsRejected :: [MissionCommandRejection]
  }
  deriving stock (Eq, Show)

-- | Creates this run's endpoint and mints its secret.
--
-- The secret is replaced on every open, so an endpoint an earlier run left
-- behind confers nothing on a client still holding its token: authority is
-- scoped to the run that is actually advancing the mission, which is the only
-- run whose console can be \"connected to this runner\".
openMissionControl :: MissionStore -> MissionId -> IO (Either Text MissionControlEndpoint)
openMissionControl store mission = case endpointPaths store mission of
  Left message -> pure (Left message)
  Right (directory, requests) -> do
    prepared <- ensureMissionDirectory directory
    case prepared of
      Left message -> pure (Left message)
      Right () -> do
        preparedRequests <- ensureMissionDirectory requests
        case preparedRequests of
          Left message -> pure (Left message)
          Right () -> do
            secret <- newControlSecret
            pure
              ( Right
                  MissionControlEndpoint
                    { missionControlMission = mission,
                      missionControlDirectoryPath = directory,
                      missionControlRequests = requests,
                      missionControlSecret = Just secret
                    }
              )

-- | Opens the endpoint as a client rather than as its owner.
--
-- Always without a secret, and that is the enforcement rather than a default:
-- there is no argument, environment variable, or file that would give one, so
-- an attached dashboard cannot become the runner's console by trying harder.
-- What it can do is everything requirement 4 asks of it — read the durable
-- record and submit ordinary durable operator commands.
attachMissionControl :: MissionStore -> MissionId -> IO (Either Text MissionControlEndpoint)
attachMissionControl store mission = case endpointPaths store mission of
  Left message -> pure (Left message)
  Right (directory, requests) ->
    pure
      ( Right
          MissionControlEndpoint
            { missionControlMission = mission,
              missionControlDirectoryPath = directory,
              missionControlRequests = requests,
              missionControlSecret = Nothing
            }
      )

-- | Writes one command into the endpoint's request directory.
--
-- The secret the endpoint holds travels with it, so an owner's submission is
-- authenticated and a client's is not, without either caller choosing which it
-- is.
submitMissionCommand :: MissionControlEndpoint -> Text -> MissionCommandPayload -> IO (Either Text ())
submitMissionCommand endpoint commandId payload = do
  now <- getCurrentTime
  let path = endpoint.missionControlRequests </> commandFileName commandId
  written <-
    writeMissionRecord
      path
      missionCommandSchemaVersion
      MissionCommandFile
        { missionCommandFileId = commandId,
          missionCommandFileMission = endpoint.missionControlMission,
          missionCommandFileSecret = endpoint.missionControlSecret,
          missionCommandFilePayload = payload,
          missionCommandFileSubmittedAt = now
        }
  case written of
    Left message -> pure (Left message)
    Right () -> do
      ignoreFileOperation (setFileMode path 0o600)
      pure (Right ())

-- | Every command waiting at the endpoint, oldest submission first.
--
-- A file that will not decode, names another mission, or carries a secret this
-- run did not mint is not silently dropped. The first two are rejections with
-- a reason; the third is an ordinary attached-client command, because a wrong
-- secret and no secret say the same thing — this did not come from the console
-- connected to this runner.
readMissionCommands :: MissionControlEndpoint -> IO MissionCommandRead
readMissionCommands endpoint = do
  entries <- listMissionEntries endpoint.missionControlRequests
  results <- mapM classify [endpoint.missionControlRequests </> entry | entry <- entries]
  let accepted = [command | Right command <- results]
      rejected = [rejection | Left rejection <- results]
  pure
    MissionCommandRead
      { missionCommandsAccepted = sortOn (.missionCommandSubmittedAt) accepted,
        missionCommandsRejected = rejected
      }
  where
    classify path = do
      decoded <- readMissionRecord endpoint.missionControlMission [missionCommandSchemaVersion] path
      pure $ case decoded of
        MissionAbsent -> Left (MissionCommandRejection path "no command this release recognizes")
        MissionRefused message -> Left (MissionCommandRejection path message)
        MissionUnreadable message -> Left (MissionCommandRejection path message)
        MissionPresent file
          | (file :: MissionCommandFile).missionCommandFileMission /= endpoint.missionControlMission ->
              Left
                ( MissionCommandRejection
                    path
                    ( "names mission "
                        <> file.missionCommandFileMission.unMissionId
                        <> " rather than "
                        <> endpoint.missionControlMission.unMissionId
                    )
                )
          | otherwise ->
              Right
                MissionSubmittedCommand
                  { missionCommandId = file.missionCommandFileId,
                    missionCommandAuthority = authorityOf file,
                    missionCommandPayload = file.missionCommandFilePayload,
                    missionCommandSubmittedAt = file.missionCommandFileSubmittedAt,
                    missionCommandPath = path
                  }
    authorityOf file = case (endpoint.missionControlSecret, file.missionCommandFileSecret) of
      (Just held, Just presented) | held == presented -> MissionRunnerAuthenticated
      _ -> MissionAttachedClient

-- | Removes a command's file once it has been answered durably.
--
-- Answered /durably/ is the ordering that matters: the journal entry recording
-- what the command did is written first, so a crash here leaves a command that
-- is read again and recognized as already applied by its identity, rather than
-- one whose answer nobody can find.
consumeMissionCommand :: MissionSubmittedCommand -> IO ()
consumeMissionCommand command = ignoreFileOperation (removeFile command.missionCommandPath)

endpointPaths :: MissionStore -> MissionId -> Either Text (FilePath, FilePath)
endpointPaths store mission =
  (,)
    <$> missionControlDirectory store.missionStoreDirectory mission
    <*> missionControlRequestDirectory store.missionStoreDirectory mission

-- | A file name that is one plain component whatever the identifier says.
commandFileName :: Text -> FilePath
commandFileName commandId = Text.unpack (Text.map safe commandId) <> ".json"
  where
    safe character
      | character `elem` ("/\\\NUL." :: String) = '-'
      | otherwise = character

-- | The run's secret, minted in memory and never written down.
--
-- Drawn from the same place the mission lease draws its token: this process's
-- identity and the instant it was taken. It has to separate this run's console
-- from every other writer, and nothing more — it is not a credential anyone
-- can present, because there is nowhere to obtain it from.
newControlSecret :: IO Text
newControlSecret = do
  processId <- getProcessID
  now <- getCurrentTime
  pure (Text.pack (show (toInteger processId)) <> "-" <> Text.pack (filter (`notElem` (" :-." :: String)) (show now)))
