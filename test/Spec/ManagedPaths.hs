-- | Where the two managed installations' discovery records resolve to, on
-- both platforms.
--
-- Every case here states the host operating system, the home directory, the
-- @$XDG_DATA_HOME@ value and which candidate locations are occupied, because
-- all four decide the answer and only one of them is the machine the suite
-- happens to run on. The expected paths are written out rather than
-- recomputed from the resolver, so a change to either spelling has to be
-- restated here — and they are the paths @tools\/kanban_config.py@'s
-- @issue_review_record_path@ and @drainer_record_path@ answer with for the
-- same environment, which is the agreement this module exists to hold.
module Spec.ManagedPaths (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString.Char8 as ByteString
import Kanban.Drainer (drainerRecordPath)
import Kanban.ManagedPaths
  ( ManagedComponent (..),
    managedRecordCandidates,
    managedRecordHome,
    managedRecordPath,
    managedRecordPathAt,
  )
import Spec.Support.Env
  ( withEnvironmentValue,
    withManagedRecordHome,
    withTemporaryCacheRoot,
  )
import System.Directory
  ( createDirectoryIfMissing,
    createFileLink,
    withCurrentDirectory,
  )
import System.FilePath (takeDirectory, (</>))
import Test.Hspec

-- | Every component this module resolves a record for. Written out rather
-- than derived, so a third constructor has to be added here deliberately
-- instead of silently escaping every shared case below.
everyComponent :: [ManagedComponent]
everyComponent = [DrainerComponent, IssueReviewComponent]

-- | The components whose XDG rule is the drainer's absolute-only one. The
-- issue-review resolver deliberately takes any non-empty value, so it is
-- asserted on its own wherever a relative base is in play.
absoluteOnlyComponents :: [ManagedComponent]
absoluteOnlyComponents = [DrainerComponent]

-- | The issue-review record's path, as the removed review backend resolved it.
reviewerRecordPath :: IO FilePath
reviewerRecordPath = managedRecordPath IssueReviewComponent

spec :: Spec
spec = describe "Managed discovery record locations" $ do
  describe "a host with neither location occupied" $ do
    it "answers macOS's own write path" $
      withTemporaryCacheRoot $ \home -> do
        managedRecordPathAt "darwin" home Nothing DrainerComponent
          `shouldReturn` (home <> "/Library/Application Support/kanban/pr-drainer/config.json")
        managedRecordPathAt "darwin" home Nothing IssueReviewComponent
          `shouldReturn` (home <> "/Library/Application Support/kanban/issue-review/config.json")

    it "answers the XDG data location on every other platform" $
      withTemporaryCacheRoot $ \home -> do
        managedRecordPathAt "linux" home Nothing DrainerComponent
          `shouldReturn` (home <> "/.local/share/kanban/pr-drainer/config.json")
        managedRecordPathAt "linux" home Nothing IssueReviewComponent
          `shouldReturn` (home <> "/.local/share/kanban/issue-review/config.json")

  describe "a host with an installation already on it" $ do
    it "resolves a ~/Library installation on both platforms, so nothing has to move" $
      withTemporaryCacheRoot $ \home ->
        forM_ everyComponent $ \component -> do
          let (_, libraryCandidate) = managedRecordCandidates component home Nothing
          occupy libraryCandidate
          forM_ ["darwin", "linux"] $ \hostOperatingSystem ->
            managedRecordPathAt hostOperatingSystem home Nothing component
              `shouldReturn` libraryCandidate

    it "prefers the XDG installation on both platforms when both are occupied" $
      withTemporaryCacheRoot $ \home ->
        forM_ everyComponent $ \component -> do
          let (xdgCandidate, libraryCandidate) = managedRecordCandidates component home Nothing
          occupy xdgCandidate
          occupy libraryCandidate
          forM_ ["darwin", "linux"] $ \hostOperatingSystem ->
            managedRecordPathAt hostOperatingSystem home Nothing component
              `shouldReturn` xdgCandidate

    it "reads a directory standing where the XDG record belongs as that installation" $
      withTemporaryCacheRoot $ \home ->
        forM_ everyComponent $ \component -> do
          -- Occupied but invalid is still occupied: falling through to the
          -- ~/Library installation would silently resolve one the operator
          -- did not choose, and say nothing about the record that is wrong.
          let (xdgCandidate, libraryCandidate) = managedRecordCandidates component home Nothing
          createDirectoryIfMissing True xdgCandidate
          occupy libraryCandidate
          forM_ ["darwin", "linux"] $ \hostOperatingSystem ->
            managedRecordPathAt hostOperatingSystem home Nothing component
              `shouldReturn` xdgCandidate

    it "reads a dangling link at the XDG record path as that installation" $
      withTemporaryCacheRoot $ \home ->
        forM_ everyComponent $ \component -> do
          let (xdgCandidate, libraryCandidate) = managedRecordCandidates component home Nothing
          createDirectoryIfMissing True (takeDirectory xdgCandidate)
          createFileLink (home </> "gone.json") xdgCandidate
          occupy libraryCandidate
          forM_ ["darwin", "linux"] $ \hostOperatingSystem ->
            managedRecordPathAt hostOperatingSystem home Nothing component
              `shouldReturn` xdgCandidate

  describe "the XDG base directory" $ do
    it "takes an absolute $XDG_DATA_HOME for every component" $
      withTemporaryCacheRoot $ \home -> do
        let base = home </> "data"
        managedRecordPathAt "linux" home (Just base) DrainerComponent
          `shouldReturn` (base </> "kanban" </> "pr-drainer" </> "config.json")
        managedRecordPathAt "linux" home (Just base) IssueReviewComponent
          `shouldReturn` (base </> "kanban" </> "issue-review" </> "config.json")

    it "ignores an empty $XDG_DATA_HOME for every component" $
      withTemporaryCacheRoot $ \home ->
        forM_ everyComponent $ \component ->
          managedRecordPathAt "linux" home (Just "") component
            `shouldReturn` fst (managedRecordCandidates component home Nothing)

    it "carries the components' differing rules for a relative $XDG_DATA_HOME" $
      withTemporaryCacheRoot $ \home ->
        withCurrentDirectory home $ do
          -- tools/kanban_config.py's _xdg_drainer_dir takes an absolute base
          -- only, so that the drainer's paths and the systemd unit running it
          -- read the environment identically, while _xdg_issue_review_dir
          -- takes any non-empty one. Answering the same as those modules
          -- means carrying the difference rather than picking one.
          managedRecordPathAt "linux" home (Just "relative-base") DrainerComponent
            `shouldReturn` (home <> "/.local/share/kanban/pr-drainer/config.json")
          managedRecordPathAt "linux" home (Just "relative-base") IssueReviewComponent
            `shouldReturn` "relative-base/kanban/issue-review/config.json"

    it "keeps the absolute-only rule even when the relative base is occupied" $
      withTemporaryCacheRoot $ \home ->
        withCurrentDirectory home $
          forM_ absoluteOnlyComponents $ \component -> do
            -- The rule decides which candidates exist at all, so a record
            -- somebody left under a relative base is not a candidate this
            -- probe can prefer -- unlike issue-review's, where it is.
            let (xdgCandidate, _) = managedRecordCandidates component home Nothing
            occupy "relative-base/kanban/pr-drainer/config.json"
            managedRecordPathAt "linux" home (Just "relative-base") component
              `shouldReturn` xdgCandidate

    it "probes a relative issue-review base against the working directory" $
      withTemporaryCacheRoot $ \home ->
        withCurrentDirectory home $ do
          -- The relative candidate names a real location once a working
          -- directory is fixed, so it is probed like any other and selects
          -- its installation on macOS too.
          occupy "relative-base/kanban/issue-review/config.json"
          occupy (home <> "/Library/Application Support/kanban/issue-review/config.json")
          managedRecordPathAt "darwin" home (Just "relative-base") IssueReviewComponent
            `shouldReturn` "relative-base/kanban/issue-review/config.json"

    it "spells the same namespace whether it comes from the variable or the fallback" $
      withTemporaryCacheRoot $ \home ->
        forM_ everyComponent $ \component ->
          -- One statement of the namespace is joined onto a base this process
          -- is told about and the other is the literal the §4 manifest
          -- reconciles; a drift between them would move the record for
          -- everyone whose $XDG_DATA_HOME is unset and nobody else.
          fst (managedRecordCandidates component home (Just (home </> ".local" </> "share")))
            `shouldBe` fst (managedRecordCandidates component home Nothing)

  describe "the entry points the dashboard actually calls" $ do
    it "resolves an XDG installation through $HOME and $XDG_DATA_HOME" $
      withTemporaryCacheRoot $ \home -> do
        let base = home </> "data"
            drainerRecord = base </> "kanban" </> "pr-drainer" </> "config.json"
            reviewerRecord = base </> "kanban" </> "issue-review" </> "config.json"
        occupy drainerRecord
        occupy reviewerRecord
        withManagedRecordHome home $
          withEnvironmentValue "XDG_DATA_HOME" base $ do
            drainerRecordPath `shouldReturn` drainerRecord
            reviewerRecordPath `shouldReturn` reviewerRecord

    it "resolves a ~/Library installation with no XDG base set" $
      withTemporaryCacheRoot $ \home -> do
        let drainerRecord = home <> "/Library/Application Support/kanban/pr-drainer/config.json"
            reviewerRecord = home <> "/Library/Application Support/kanban/issue-review/config.json"
        occupy drainerRecord
        occupy reviewerRecord
        withManagedRecordHome home $ do
          drainerRecordPath `shouldReturn` drainerRecord
          reviewerRecordPath `shouldReturn` reviewerRecord

    it "moves no record when any install-directory override is set" $
      withTemporaryCacheRoot $ \home ->
        withManagedRecordHome home $ do
          -- Every one of these variables relocates the install directory its
          -- record points into, and only that: the record's own path is what a
          -- dashboard that never saw --install-dir has to find the
          -- installation by.
          drainerBaseline <- drainerRecordPath
          reviewerBaseline <- reviewerRecordPath
          withEnvironmentValue "KANBAN_DRAINER_INSTALL_DIR" (home </> "moved-drainer") $
            withEnvironmentValue "KANBAN_ISSUE_REVIEW_INSTALL_DIR" (home </> "moved-review") $ do
              drainerRecordPath `shouldReturn` drainerBaseline
              reviewerRecordPath `shouldReturn` reviewerBaseline

  describe "the home a record hangs off" $
    it "anchors both components to $HOME" $
      withTemporaryCacheRoot $ \home ->
        -- tools/kanban_config.py anchors the issue-review and drainer
        -- locations to `Path.home()`, which is $HOME whenever that is set.
        withEnvironmentValue "HOME" home $ do
          managedRecordHome DrainerComponent `shouldReturn` home
          managedRecordHome IssueReviewComponent `shouldReturn` home

-- | Writes a record at @path@, creating whatever directories it needs. The
-- contents never matter here: this module is about which location is
-- selected, and what is wrong with the document found there is the reading
-- consumers' diagnostic rather than the probe's.
occupy :: FilePath -> IO ()
occupy path = do
  createDirectoryIfMissing True (takeDirectory path)
  ByteString.writeFile path "{}"
