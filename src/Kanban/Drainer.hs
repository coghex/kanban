module Kanban.Drainer
  ( DrainerController,
    DrainerState (..),
    DrainerStatus (..),
    decodeDrainerStatus,
    discoverDrainerController,
    drainerIsRunning,
    queryDrainerStatus,
    setDrainerRunning,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:), (.:?))
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import System.Directory (getHomeDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

data DrainerController = DrainerController
  { controllerExecutable :: FilePath,
    controllerArguments :: [String]
  }
  deriving stock (Eq, Show)

data DrainerState
  = DrainerOff
  | DrainerOn
  | DrainerStarting
  | DrainerStopping
  | DrainerWarning
  | DrainerError
  deriving stock (Eq, Show)

data DrainerStatus = DrainerStatus
  { drainerState :: DrainerState,
    drainerDetail :: Text
  }
  deriving stock (Eq, Show)

data RawIncident = RawIncident
  { rawIncidentSummary :: Maybe Text
  }
  deriving stock (Eq, Show)

instance FromJSON RawIncident where
  parseJSON = withObject "PR drainer incident" $ \value ->
    RawIncident <$> value .:? "summary"

data RawStatus = RawStatus
  { rawState :: Text,
    rawIncident :: Maybe RawIncident
  }
  deriving stock (Eq, Show)

instance FromJSON RawStatus where
  parseJSON = withObject "PR drainer status" $ \value ->
    RawStatus <$> value .: "state" <*> value .:? "open_incident"

discoverDrainerController :: IO (Either Text DrainerController)
discoverDrainerController = do
  home <- getHomeDirectory
  let plist = home </> "Library" </> "LaunchAgents" </> "com.coghex.drain-prs.plist"
  result <- runProcess 3 "/usr/bin/plutil" ["-extract", "ProgramArguments", "json", "-o", "-", plist]
  pure $ do
    output <- result
    arguments <- case eitherDecode (LazyByteString.pack output) of
      Left message -> Left ("could not decode launchd ProgramArguments: " <> Text.pack message)
      Right values -> Right values
    case stripRunArgument arguments of
      executable : controllerArguments -> Right (DrainerController executable controllerArguments)
      _ -> Left "launchd ProgramArguments do not identify the PR drainer controller"

queryDrainerStatus :: DrainerController -> IO (Either Text DrainerStatus)
queryDrainerStatus controller = runController 4 controller "status"

setDrainerRunning :: DrainerController -> Bool -> IO (Either Text DrainerStatus)
setDrainerRunning controller shouldRun =
  runController 30 controller (if shouldRun then "start" else "stop")

decodeDrainerStatus :: LazyByteString.ByteString -> Either Text DrainerStatus
decodeDrainerStatus bytes = do
  rawStatus <- case eitherDecode bytes of
    Left message -> Left ("could not decode PR drainer status: " <> Text.pack message)
    Right value -> Right value
  pure (statusFromRaw rawStatus)

drainerIsRunning :: DrainerStatus -> Bool
drainerIsRunning status = case status.drainerState of
  DrainerOn -> True
  DrainerWarning -> "on" `Text.isPrefixOf` status.drainerDetail
  _ -> False

runController :: Int -> DrainerController -> String -> IO (Either Text DrainerStatus)
runController seconds controller command = do
  result <-
    runProcess
      seconds
      controller.controllerExecutable
      (controller.controllerArguments <> ["--json", command])
  pure $ result >>= decodeDrainerStatus . LazyByteString.pack

runProcess :: Int -> FilePath -> [String] -> IO (Either Text String)
runProcess seconds executable arguments = do
  attempted <- try @IOException (timeout (seconds * 1000 * 1000) (readProcessWithExitCode executable arguments ""))
  pure $ case attempted of
    Left exception -> Left (Text.pack (show exception))
    Right Nothing -> Left ("command timed out after " <> Text.pack (show seconds) <> " seconds")
    Right (Just (ExitSuccess, output, _)) -> Right output
    Right (Just (ExitFailure _, output, errors)) ->
      Left . Text.strip . Text.pack $ if null errors then output else errors

stripRunArgument :: [String] -> [String]
stripRunArgument arguments = case reverse arguments of
  "run" : rest -> reverse rest
  _ -> arguments

statusFromRaw :: RawStatus -> DrainerStatus
statusFromRaw rawStatus = case (rawStatus.rawState, rawStatus.rawIncident) of
  ("running", Nothing) -> DrainerStatus DrainerOn "on"
  ("running", Just incident) -> DrainerStatus DrainerWarning ("on · unresolved incident" <> incidentDetail incident)
  ("starting", _) -> DrainerStatus DrainerStarting "starting…"
  ("external", _) -> DrainerStatus DrainerWarning "on outside launchd"
  ("stopped", Nothing) -> DrainerStatus DrainerOff "off"
  ("stopped", Just incident) -> DrainerStatus DrainerError ("stopped · unresolved incident" <> incidentDetail incident)
  (other, _) -> DrainerStatus DrainerError ("unknown state: " <> other)

incidentDetail :: RawIncident -> Text
incidentDetail incident = maybe "" (" · " <>) incident.rawIncidentSummary
