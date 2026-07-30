-- | Temporary directories, environment variables and file modes the fixtures
-- build their hermetic scratch space from.
module Spec.Support.Env
  ( createTemporaryDirectory,
    withTemporaryCacheRoot,
    withEnvironmentValue,
    withoutEnvironmentValue,
    withFileCreationMask,
    permissionsOf,
    waitForFileToExist,
    ignoringIOException,
    installFakeExecutable,
    withFakeOnPath,
    writeExecutableScript
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, try)
import Control.Monad (void)
import qualified Data.ByteString.Char8 as ByteString
import Data.Maybe (fromMaybe)
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    getTemporaryDirectory,
    removePathForcibly
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.Posix.Files
  ( accessModes,
    fileMode,
    getFileStatus,
    intersectFileModes,
    setFileCreationMask,
    setFileMode
  )
import System.Posix.Temp (mkdtemp)
import System.Posix.Types (FileMode)

-- | Puts one shell script first on PATH under @name@, so whatever resolves
-- that name — the board's @gh@, a census's @ps@, a repository probe's
-- @git@ — drives the script instead of the real thing. The body is written
-- as bytes, so a fake can emit output no encoding would accept.
withFakeOnPath :: FilePath -> (String, [ByteString.ByteString]) -> IO result -> IO result
withFakeOnPath temporaryRoot (name, body) action = do
  let binaryRoot = temporaryRoot </> "bin"
  createDirectoryIfMissing True binaryRoot
  ByteString.writeFile (binaryRoot </> name) (ByteString.unlines ("#!/bin/sh" : body))
  setFileMode (binaryRoot </> name) 0o700
  originalPath <- fromMaybe "" <$> lookupEnv "PATH"
  withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) action

-- | Writes a standalone shell script to an exact path and marks it
-- executable, for a fixture that hands the script's own path to the code
-- under test rather than resolving it off PATH.
writeExecutableScript :: FilePath -> [ByteString.ByteString] -> IO FilePath
writeExecutableScript path body = do
  ByteString.writeFile path (ByteString.unlines ("#!/bin/sh" : body))
  setFileMode path 0o700
  pure path

installFakeExecutable :: FilePath -> (String, [ByteString.ByteString]) -> IO ()
installFakeExecutable binaryRoot (name, body) = do
  let path = binaryRoot </> name
  ByteString.writeFile
    path
    (ByteString.unlines (["#!/bin/sh", "printf '%s\\n' \"$*\" >> \"$KANBAN_TEST_PROBE_LOG\""] <> body))
  setFileMode path 0o700

-- | Runs @action@ under @mask@, restoring the process-wide umask afterwards:
-- it is shared by every later test in this (sequential) suite.
withFileCreationMask :: FileMode -> IO result -> IO result
withFileCreationMask mask action = bracket (setFileCreationMask mask) setFileCreationMask (const action)

permissionsOf :: FilePath -> IO FileMode
permissionsOf path = (`intersectFileModes` accessModes) . fileMode <$> getFileStatus path

ignoringIOException :: IO () -> IO ()
ignoringIOException action = void (try @IOException action)

withTemporaryCacheRoot :: (FilePath -> IO result) -> IO result
withTemporaryCacheRoot = bracket createTemporaryDirectory removePathForcibly

-- | Atomically allocates a fresh directory under the system temp root via
-- POSIX @mkdtemp@, so two suite processes racing this call can never observe
-- (or clobber) the same path -- unlike open-a-file/remove-it/create-a-directory,
-- which leaves the freed name up for grabs between the second and third step.
createTemporaryDirectory :: IO FilePath
createTemporaryDirectory = do
  temporaryRoot <- getTemporaryDirectory
  mkdtemp (temporaryRoot </> "kanban-cache-test-")

withEnvironmentValue :: String -> String -> IO result -> IO result
withEnvironmentValue name value action =
  bracket
    (do previous <- lookupEnv name; setEnv name value; pure previous)
    (maybe (unsetEnv name) (setEnv name))
    (const action)

withoutEnvironmentValue :: String -> IO result -> IO result
withoutEnvironmentValue name action =
  bracket
    (do previous <- lookupEnv name; unsetEnv name; pure previous)
    (maybe (pure ()) (setEnv name))
    (const action)

waitForFileToExist :: FilePath -> Int -> IO ()
waitForFileToExist path attempts = do
  exists <- doesFileExist path
  if exists
    then pure ()
    else
      if attempts <= 0
        then fail ("expected " <> path <> " to exist")
        else threadDelay 100000 >> waitForFileToExist path (attempts - 1)
