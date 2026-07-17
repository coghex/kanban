{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

module Kanban.Process
  ( ManagedProcess,
    ProcessIdentity (..),
    descendantProcesses,
    interruptManagedProcess,
    killManagedProcess,
    liveProcesses,
    managedProcess,
    managedProcessGroup,
    managedProcessPid,
    managedProcessStopsWithDashboard,
    readProcessSnapshot,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (void)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import System.Exit (ExitCode (..))
import System.Posix.Types (CPid)
import System.Posix.Signals (Signal, sigINT, sigKILL, sigTERM, signalProcessGroup)
import System.Process (ProcessHandle, getPid, getProcessExitCode, proc, readCreateProcessWithExitCode, terminateProcess)
import Text.Read (readMaybe)

data ProcessIdentity = ProcessIdentity
  { processIdentityPid :: Int,
    processIdentityParentPid :: Int,
    processIdentityGroupPid :: Int,
    processIdentityStartedAt :: Text,
    processIdentityCommand :: Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ManagedProcess
  = LocalManagedProcess ProcessHandle
  | PersistentManagedProcess CPid

managedProcess :: ProcessHandle -> ManagedProcess
managedProcess = LocalManagedProcess

managedProcessGroup :: CPid -> ManagedProcess
managedProcessGroup = PersistentManagedProcess

managedProcessPid :: ManagedProcess -> IO (Maybe CPid)
managedProcessPid (LocalManagedProcess processHandle) = getPid processHandle
managedProcessPid (PersistentManagedProcess processId) = pure (Just processId)

managedProcessStopsWithDashboard :: ManagedProcess -> Bool
managedProcessStopsWithDashboard (LocalManagedProcess _) = True
managedProcessStopsWithDashboard (PersistentManagedProcess _) = False

readProcessSnapshot :: IO (Either Text [ProcessIdentity])
readProcessSnapshot = do
  result <- try @IOException (readCreateProcessWithExitCode (proc "ps" ["-axo", "pid=,ppid=,pgid=,lstart=,command="]) "")
  pure $ case result of
    Left exception -> Left (Text.pack (show exception))
    Right (ExitFailure code, _, diagnostics) -> Left ("ps exited " <> Text.pack (show code) <> ": " <> Text.strip (Text.pack diagnostics))
    Right (ExitSuccess, output, _) -> Right (mapMaybeProcessLine (Text.lines (Text.pack output)))

descendantProcesses :: [Int] -> [ProcessIdentity] -> [ProcessIdentity]
descendantProcesses roots processes = filter ((`Set.member` descendants) . processIdentityPid) processes
  where
    byParent = Map.fromListWith (<>) [(process.processIdentityParentPid, [process.processIdentityPid]) | process <- processes]
    descendants = expand (Set.fromList roots) roots
    expand known [] = known
    expand known (parent : pending) =
      let children = Map.findWithDefault [] parent byParent
          unseen = filter (`Set.notMember` known) children
       in expand (foldr Set.insert known unseen) (pending <> unseen)

liveProcesses :: [ProcessIdentity] -> IO [ProcessIdentity]
liveProcesses known = do
  snapshot <- readProcessSnapshot
  pure $ case snapshot of
    Left _ -> []
    Right current ->
      let currentByPid = Map.fromList [(process.processIdentityPid, process) | process <- current]
       in [ process
            | process <- known,
              Just live <- [Map.lookup process.processIdentityPid currentByPid],
              live.processIdentityStartedAt == process.processIdentityStartedAt
          ]

mapMaybeProcessLine :: [Text] -> [ProcessIdentity]
mapMaybeProcessLine = foldr (maybe id (:)) [] . map parseProcessLine

parseProcessLine :: Text -> Maybe ProcessIdentity
parseProcessLine line = case Text.words line of
  pidText : parentText : groupText : weekday : month : day : clock : year : commandParts -> do
    pid <- readMaybe (Text.unpack pidText)
    parentPid <- readMaybe (Text.unpack parentText)
    groupPid <- readMaybe (Text.unpack groupText)
    pure
      ProcessIdentity
        { processIdentityPid = pid,
          processIdentityParentPid = parentPid,
          processIdentityGroupPid = groupPid,
          processIdentityStartedAt = Text.unwords [weekday, month, day, clock, year],
          processIdentityCommand = Text.unwords commandParts
        }
  _ -> Nothing

interruptManagedProcess :: ManagedProcess -> IO ()
interruptManagedProcess (LocalManagedProcess processHandle) = signalOwnedGroup sigINT processHandle
interruptManagedProcess (PersistentManagedProcess processId) = ignoreIOException (signalProcessGroup sigINT processId)

killManagedProcess :: ManagedProcess -> IO ()
killManagedProcess (LocalManagedProcess processHandle) = do
  exitCode <- getProcessExitCode processHandle
  case exitCode of
    Just _ -> pure ()
    Nothing -> do
      signalOwnedGroup sigTERM processHandle
      threadDelay terminationGraceMicros
      stopped <- getProcessExitCode processHandle
      case stopped of
        Just _ -> pure ()
        Nothing -> signalOwnedGroup sigKILL processHandle
killManagedProcess (PersistentManagedProcess processId) = do
  ignoreIOException (signalProcessGroup sigTERM processId)
  threadDelay terminationGraceMicros
  ignoreIOException (signalProcessGroup sigKILL processId)

signalOwnedGroup :: Signal -> ProcessHandle -> IO ()
signalOwnedGroup signal processHandle = do
  processId <- getPid processHandle
  case processId of
    Just pid -> ignoreIOException (signalProcessGroup signal pid)
    Nothing -> ignoreIOException (terminateProcess processHandle)

ignoreIOException :: IO () -> IO ()
ignoreIOException action = void (try action :: IO (Either IOException ()))

terminationGraceMicros :: Int
terminationGraceMicros = 750 * 1000
