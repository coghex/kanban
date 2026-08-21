-- | Where the two managed installations' discovery records are, on this
-- platform and on the one it is not.
--
-- The Haskell counterpart of @tools\/kanban_config.py@, and the whole of it:
-- every other module obtains a record's location from here rather than
-- spelling one, so the dashboard and the Python components cannot disagree
-- about which installation a host has. Two resolution points exist across
-- the repository, one per language — the packaged plugin assets that resolve
-- the issue-review record independently cannot import either and are their
-- own arc.
--
-- Both records are discovered the same way: the XDG location first and the
-- @~\/Library@ location second, on both platforms, taking the first that is
-- occupied. Nothing an operator already installed has to move, and only when
-- neither is occupied is the answer this platform's own write default. That
-- is @installed_issue_review_dir@ and @installed_drainer_dir@ in
-- @tools\/kanban_config.py@, and answering the same as those is what this
-- module is for.
module Kanban.ManagedPaths
  ( ManagedComponent (..),
    managedRecordCandidates,
    managedRecordPath,
    managedRecordPathAt,
    managedRecordWriteDefault,
    recordPathOccupied,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (guard)
import System.Directory (doesPathExist, getHomeDirectory, pathIsSymbolicLink)
import System.Environment (lookupEnv)
import System.FilePath (isAbsolute, joinPath, (</>))
import System.Info (os)

-- | Which managed installation's record is being located. The two are
-- separate installations with separate installers, and — see
-- 'usableXdgBase' — separate rules for reading the XDG base directory, so
-- they are asked about one at a time rather than resolved together.
data ManagedComponent
  = -- | What @tools\/install_issue_review.py@ recorded, read by
    -- "Kanban.Review.Canonical".
    IssueReviewComponent
  | -- | What @tools\/install_drainer.py@ and @tools\/drain_prs_service.py@
    -- recorded, read by "Kanban.Drainer".
    DrainerComponent
  deriving stock (Eq, Show)

-- | Both locations a component's record can be, in probe order: the XDG one
-- first and the @~\/Library@ one second, on every platform.
--
-- Parameterised by the home directory and by @$XDG_DATA_HOME@ rather than
-- reading either, so a fixture can ask what a host it is not running on
-- would answer.
managedRecordCandidates :: ManagedComponent -> FilePath -> Maybe String -> (FilePath, FilePath)
managedRecordCandidates component home xdgDataHome =
  (xdgRecordPath component home xdgDataHome, libraryRecordPath component home)

-- | Where a /fresh/ install of this component writes its record on a host
-- running this operating system: this platform's own convention and only
-- that. The answer when neither candidate above is occupied, which is what
-- @default_issue_review_install_dir@ and @default_drainer_install_dir@ are
-- to their probes.
managedRecordWriteDefault :: String -> ManagedComponent -> FilePath -> Maybe String -> FilePath
managedRecordWriteDefault hostOperatingSystem component home xdgDataHome
  | hostOperatingSystem == "darwin" = libraryRecordPath component home
  | otherwise = xdgRecordPath component home xdgDataHome

-- | The @~\/Library@ location, named on every platform: macOS's own write
-- path, and on any other host the location an installation made before the
-- portability arc is still at, which is why the probe keeps looking there.
--
-- Spelled as one literal per component, exactly as @tools\/kanban_config.py@
-- spells its own: each is a @personal-path@ token in
-- @docs\/agent-workflow-contract.md@ §4 declaring this file, and that
-- reconciliation matches a literal rather than an expression.
libraryRecordPath :: ManagedComponent -> FilePath -> FilePath
libraryRecordPath IssueReviewComponent home =
  home <> "/Library/Application Support/kanban/issue-review/config.json"
libraryRecordPath DrainerComponent home =
  home <> "/Library/Application Support/kanban/pr-drainer/config.json"

-- | The XDG data location: this component's namespace under @$XDG_DATA_HOME@
-- when that variable is usable by this component's rule, and the
-- conventional home-relative directory when it is not.
xdgRecordPath :: ManagedComponent -> FilePath -> Maybe String -> FilePath
xdgRecordPath component home xdgDataHome = case usableXdgBase component xdgDataHome of
  Just base -> base </> joinPath (recordNamespace component)
  Nothing -> homeRelativeXdgRecordPath component home

-- | The home-relative spelling of the location above, for the branch where
-- @$XDG_DATA_HOME@ names no base directory this component will take. One
-- literal per component for the same manifest reason 'libraryRecordPath'
-- gives; 'Spec.ManagedPaths' pins it against 'recordNamespace' so the two
-- statements of the namespace cannot drift apart.
homeRelativeXdgRecordPath :: ManagedComponent -> FilePath -> FilePath
homeRelativeXdgRecordPath IssueReviewComponent home =
  home <> "/.local/share/kanban/issue-review/config.json"
homeRelativeXdgRecordPath DrainerComponent home =
  home <> "/.local/share/kanban/pr-drainer/config.json"

-- | The record's path below whichever base directory it hangs off, as path
-- segments rather than as a literal, because they are joined onto a base
-- this process is told about instead of one it spells.
recordNamespace :: ManagedComponent -> [FilePath]
recordNamespace IssueReviewComponent = ["kanban", "issue-review", "config.json"]
recordNamespace DrainerComponent = ["kanban", "pr-drainer", "config.json"]

-- | The XDG base directory this component accepts, or nothing when it
-- accepts none and the home-relative fallback applies.
--
-- The two rules differ deliberately, and carrying the difference is what
-- makes this module answer what @tools\/kanban_config.py@ answers:
-- @_xdg_issue_review_dir@ takes any non-empty value, while @_xdg_drainer_dir@
-- takes one only when it is absolute, so that the drainer's managed paths and
-- the systemd unit that runs it read the environment identically. A relative
-- value therefore selects the XDG location for issue-review and the
-- @~\/.local\/share@ fallback for the drainer. Picking one rule for both here
-- would make the board disagree with the installer about where one of the two
-- put its record.
usableXdgBase :: ManagedComponent -> Maybe String -> Maybe FilePath
usableXdgBase component xdgDataHome = do
  base <- xdgDataHome
  guard (not (null base))
  case component of
    IssueReviewComponent -> pure base
    DrainerComponent -> base <$ guard (isAbsolute base)

-- | Whether anything at all occupies a record's path, including an entry
-- that cannot be followed to a file.
--
-- Deliberately not @doesFileExist@ or @doesPathExist@ alone: both answer "is
-- there something readable here", and the question this has to answer is
-- "was a record ever written here", whose only fail-closed reading of a
-- directory or a dangling link is yes. Reading a higher-precedence candidate
-- as absent because it is invalid would resolve the lower-precedence
-- installation and say nothing; what is actually wrong with the record stays
-- for the readers that then open it. 'doesPathExist' follows links, so a
-- dangling one needs the @lstat@ that 'pathIsSymbolicLink' does — and it
-- throws when nothing is there at all, which is the genuinely absent case.
-- @os.path.lexists@ is what the Python probes use for this, for these
-- reasons.
recordPathOccupied :: FilePath -> IO Bool
recordPathOccupied path = do
  present <- doesPathExist path
  if present
    then pure True
    else either (const False) id <$> try @IOException (pathIsSymbolicLink path)

-- | 'managedRecordPath' parameterised by the host operating system, the home
-- directory and @$XDG_DATA_HOME@, so every branch is exercisable off any one
-- host. Only the occupancy probe reaches the filesystem.
managedRecordPathAt :: String -> FilePath -> Maybe String -> ManagedComponent -> IO FilePath
managedRecordPathAt hostOperatingSystem home xdgDataHome component = do
  let (xdgCandidate, libraryCandidate) = managedRecordCandidates component home xdgDataHome
  xdgOccupied <- recordPathOccupied xdgCandidate
  if xdgOccupied
    then pure xdgCandidate
    else do
      libraryOccupied <- recordPathOccupied libraryCandidate
      pure $
        if libraryOccupied
          then libraryCandidate
          else managedRecordWriteDefault hostOperatingSystem component home xdgDataHome

-- | Where this host's record for @component@ is, against the real
-- environment.
--
-- Neither @KANBAN_ISSUE_REVIEW_INSTALL_DIR@ nor @KANBAN_DRAINER_INSTALL_DIR@
-- is read here, and neither may be: each relocates the install directory its
-- record points into, while the record's own path is the one thing that
-- cannot move — that is what lets a dashboard which never saw @--install-dir@
-- discover an installation made with it.
managedRecordPath :: ManagedComponent -> IO FilePath
managedRecordPath component = do
  home <- getHomeDirectory
  xdgDataHome <- lookupEnv "XDG_DATA_HOME"
  managedRecordPathAt os home xdgDataHome component
