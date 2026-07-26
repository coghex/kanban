-- | Directory creation for the application's own state under the XDG roots.
--
-- §16 requires @0700@ on the directories Kanban creates, and the cache holds
-- issue and pull request bodies from private repositories, so the mode is
-- protecting real content rather than satisfying a convention.
module Kanban.Paths
  ( createPrivateDirectory,
    privateDirectoryChain,
  )
where

import Control.Monad (forM_)
import System.Directory (XdgDirectory, createDirectoryIfMissing, getXdgDirectory)
import System.FilePath (dropTrailingPathSeparator, takeDirectory)
import System.Posix.Files (setFileMode)

-- | Creates @directory@ and forces @0700@ on every level of it this
-- application owns, not merely the leaf.
--
-- 'createDirectoryIfMissing' creates missing parents with the process umask,
-- so chmodding the leaf alone left @~\/.cache\/kanban@ at whichever mode the
-- writer that happened to run first was given. Applying the mode to the whole
-- chain on every write also tightens a directory an earlier version left
-- loose.
--
-- The XDG root itself is shared with every other application, so it keeps
-- whatever mode it already had.
createPrivateDirectory :: XdgDirectory -> FilePath -> IO ()
createPrivateDirectory xdgDirectory directory = do
  root <- getXdgDirectory xdgDirectory ""
  createDirectoryIfMissing True directory
  forM_ (privateDirectoryChain root directory) (`setFileMode` 0o700)

-- | The path segments from @root@ (exclusive) down to @directory@
-- (inclusive), outermost first.
--
-- Empty when @directory@ does not sit below @root@: a path we cannot place is
-- left alone rather than having @0700@ walked all the way up to the
-- filesystem root.
privateDirectoryChain :: FilePath -> FilePath -> [FilePath]
privateDirectoryChain root directory = maybe [] reverse (climb directory)
  where
    target = dropTrailingPathSeparator root
    climb current
      | dropTrailingPathSeparator current == target = Just []
      | parent == current = Nothing
      | otherwise = (current :) <$> climb parent
      where
        parent = takeDirectory current
