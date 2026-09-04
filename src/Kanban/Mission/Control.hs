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
-- There are two paths, and they are different /mechanisms/ rather than one
-- mechanism with a credential in it.
--
-- The authenticated path never touches the filesystem. A line typed at the
-- runner's own terminal is turned into a command inside the running process
-- and handed straight to its controller, so there is no artefact for anything
-- else to read, copy, or replay. That is the whole of what makes it
-- authenticated: not a token it presents, but the fact that no other process
-- can put anything on it.
--
-- A credential would have undone exactly that. Any token durable enough for a
-- second process to present is durable enough for a third to copy — the store
-- is this user's, and so is every provider session running under it — so a
-- secret written beside the requests would have handed override authority to
-- precisely the processes requirement 14 excludes by name. There is therefore
-- no secret anywhere in this module.
--
-- The unauthenticated path is 'control\/requests\/', and it is deliberately
-- open: an attached dashboard is a legitimate client with no advancement
-- lease, its input is durable and ordinary, and it confers no override
-- authority. Every command that arrives as a file is that kind, whoever wrote
-- it, because a file cannot establish who did.
--
-- The same rule is what makes a registered child request answerable. A request
-- names the parent it claims and the mission it claims, and both are checked
-- against durable state rather than believed: a parent that is not a live
-- registered session of /this/ mission is a forgery whatever channel it came
-- in on, and a request identity already answered returns the answer it already
-- has instead of launching a second child.
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
    submitMissionCommand,
    runnerCommand,
    readMissionCommands,
    consumeMissionCommand,
    overrideAuthorized,
    parseMissionConsoleCommand,
    parseConsoleTarget,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Read (decimal)
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
    MissionTargetKind (..),
    missionCommandSchemaVersion,
  )
import System.Directory (removeFile)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

-- | Where commands are left, and the secret that separates the runner's own
-- console from every other client.
data MissionControlEndpoint = MissionControlEndpoint
  { missionControlMission :: MissionId,
    missionControlDirectoryPath :: FilePath,
    missionControlRequests :: FilePath
  }
  deriving stock (Eq, Show)

-- | Which of the two classes a command arrived in.
data MissionCommandAuthority
  = -- | Built inside the running controller's own process from its own
    -- terminal. Nothing on disk carries this authority, so nothing on disk can
    -- claim it.
    MissionRunnerAuthenticated
  | -- | Arrived as a file. Durable, ordinary, and powerless over an override
    -- or an unknown outcome — whoever wrote it, because a file cannot
    -- establish who did.
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

-- | One line typed at the runner's own console.
--
-- A grammar rather than free text, and a small one: every verb here is an
-- authority the channel grants, so a line that does not parse is reported back
-- rather than guessed at. Pure, so the whole vocabulary is exercisable without
-- a terminal.
--
--   [@pause \<reason\>@] stop dispatching; terminate nothing.
--   [@resume@] start dispatching again.
--   [@override \<step\> \<detail\>@] resolve an unknown outcome and replan
--     the step (requirement 14).
--   [@terminate \<session\> \<reason\>@] end that registered subtree
--     (requirement 11).
--   [@child \<request\> \<parent\> \<action\> [\<target\>]@] register and launch
--     a child of a live registered session (requirement 12). The target is
--     written @issue#844@ or @pr#900@ and is optional: an action that works on
--     the repository rather than on one item takes none, and an item-scoped
--     action given none is refused by the registry with the target it wanted
--     named, rather than silently resolved to the whole repository.
parseMissionConsoleCommand :: MissionId -> Text -> Either Text MissionCommandPayload
parseMissionConsoleCommand mission line = case Text.words (Text.strip line) of
  [] -> Left "an empty line is not a command"
  ("pause" : rest) -> Right (MissionPauseCommand (joined rest "the operator paused it"))
  ["resume"] -> Right MissionResumeCommand
  ("override" : step : rest)
    | not (Text.null step) ->
        Right (MissionUserOverrideCommand (MissionStepId step) (joined rest "the operator resolved it"))
  ("terminate" : session : rest)
    | not (Text.null session) ->
        Right
          ( MissionTerminateSubtreeCommand
              (MissionSessionId session)
              (joined rest "the operator ended it")
          )
  ["child", requestId, parent, action] -> Right (childRequest requestId parent action Nothing)
  ["child", requestId, parent, action, target] ->
    (childRequest requestId parent action . Just) <$> parseConsoleTarget target
  (verb : _) ->
    Left
      ( "unknown command "
          <> verb
          <> "; expected pause, resume, override, terminate, or child"
      )
  where
    joined [] fallback = fallback
    joined parts _ = Text.unwords parts
    childRequest requestId parent action target =
      MissionChildRequestCommand
        MissionChildRequest
          { missionChildRequestId = requestId,
            missionChildRequestMission = mission,
            missionChildRequestParent = MissionSessionId parent,
            missionChildRequestAction = action,
            missionChildRequestTarget = target
          }

-- | The item a console line names, written the way a person writes it.
--
-- @issue#844@ and @pr#900@, and nothing looser. Every repository has an issue
-- \#844 and a pull request \#844 and they are not the same item, so the kind is
-- part of the spelling rather than something the registry is left to guess;
-- and a number that is not one is refused here, where the operator can see the
-- refusal, rather than resolved into a target nobody asked for.
parseConsoleTarget :: Text -> Either Text MissionTarget
parseConsoleTarget spelled = case Text.breakOn "#" spelled of
  (kind, rest)
    | Just number <- Text.stripPrefix "#" rest,
      Just resolved <- lookup (Text.toLower kind) kinds,
      Right (value, "") <- decimal number,
      value > 0 ->
        Right MissionTarget {missionTargetKind = resolved, missionTargetNumber = value, missionTargetTitle = Nothing}
  _ ->
    Left
      ( "a child's target is written issue#<number> or pr#<number>, not "
          <> spelled
      )
  where
    kinds =
      [ ("issue", MissionTargetIssue),
        ("issues", MissionTargetIssue),
        ("pr", MissionTargetPullRequest),
        ("pull", MissionTargetPullRequest)
      ]

-- | The wire record a client writes.
data MissionCommandFile = MissionCommandFile
  { missionCommandFileId :: Text,
    missionCommandFileMission :: MissionId,
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
    -- | The file it arrived as, and 'Nothing' for one built in this process.
    -- An in-process command has nothing to consume afterwards, which is the
    -- same absence that makes it unforgeable.
    missionCommandPath :: Maybe FilePath
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
        pure
          ( MissionControlEndpoint
              { missionControlMission = mission,
                missionControlDirectoryPath = directory,
                missionControlRequests = requests
              }
              <$ preparedRequests
          )

-- | One command built inside the controller's own process.
--
-- The only way to produce a 'MissionRunnerAuthenticated' command, and it takes
-- no secret because it takes no channel: a caller that can call this is
-- already running inside the controller.
runnerCommand :: Text -> MissionCommandPayload -> IO MissionSubmittedCommand
runnerCommand commandId payload = do
  now <- getCurrentTime
  pure
    MissionSubmittedCommand
      { missionCommandId = commandId,
        missionCommandAuthority = MissionRunnerAuthenticated,
        missionCommandPayload = payload,
        missionCommandSubmittedAt = now,
        missionCommandPath = Nothing
      }

-- | Writes one command into the endpoint's request directory.
--
-- Always an ordinary operator command, whoever calls it. There is no
-- authenticated spelling of this function, because a file is the one thing
-- that cannot establish who wrote it.
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
          missionCommandFilePayload = payload,
          missionCommandFileSubmittedAt = now
        }
  case written of
    Left message -> pure (Left message)
    Right () -> do
      ignoreFileOperation (setFileMode path 0o600)
      pure (Right ())

-- | Every command waiting at the endpoint, oldest submission first, all of
-- them unauthenticated.
--
-- A file that will not decode or names another mission is not silently
-- dropped: each is a rejection with a reason.
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
                    missionCommandAuthority = MissionAttachedClient,
                    missionCommandPayload = file.missionCommandFilePayload,
                    missionCommandSubmittedAt = file.missionCommandFileSubmittedAt,
                    missionCommandPath = Just path
                  }

-- | Removes a command's file once it has been answered durably.
--
-- Answered /durably/ is the ordering that matters: the journal entry recording
-- what the command did is written first, so a crash here leaves a command that
-- is read again and recognized as already applied by its identity, rather than
-- one whose answer nobody can find.
consumeMissionCommand :: MissionSubmittedCommand -> IO ()
consumeMissionCommand command =
  mapM_ (ignoreFileOperation . removeFile) command.missionCommandPath

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
