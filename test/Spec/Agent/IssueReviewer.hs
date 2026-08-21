-- | Discovering the canonical issue reviewer's installation.
module Spec.Agent.IssueReviewer (spec) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Text
import Kanban.Review
  ( IssueReviewerSource (..),
    issueReviewerRecordPath,
    resolveCanonicalIssueReviewerAt,
    selectCanonicalIssueReviewerAt,
    resolveCanonicalIssueReviewer
  )
import Spec.Support.Env (withManagedRecordHome, withTemporaryCacheRoot)
import Spec.Support.Expect (shouldMention, shouldNotMention)
import System.Directory (createDirectoryIfMissing, createFileLink)
import System.FilePath (takeDirectory, (</>))
import Test.Hspec

spec :: Spec
spec = do
  describe "canonical issue reviewer discovery" $ do
    -- Every case here is a temporary directory and a fixture record: no
    -- install, no terminal, no network, no GitHub account. The record path
    -- is a parameter precisely so the real one is never read or written.
    let recordDocument backend = ByteString.pack ("{\"backend_path\":\"" <> backend <> "\"}")
        installBackendAt directory = do
          createDirectoryIfMissing True directory
          writeFile (directory </> "approve_issues.py") "#!/usr/bin/env python3\n"
          pure (directory </> "approve_issues.py")
        failureFor = either id (\path -> "unexpectedly resolved " <> Data.Text.pack path)

    it "prefers KANBAN_ISSUE_REVIEW_INSTALL_DIR over a record naming somewhere else" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        recorded <- installBackendAt (root </> "recorded")
        selected <- installBackendAt (root </> "selected")
        ByteString.writeFile recordPath (recordDocument recorded)
        resolveCanonicalIssueReviewerAt (Just (root </> "selected")) recordPath
          `shouldReturn` Right selected

    -- A blank override is how an unset variable often reaches a process
    -- through a wrapper script; treating it as a selection would resolve
    -- "/approve_issues.py".
    it "ignores a blank override rather than selecting the filesystem root" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        recorded <- installBackendAt (root </> "recorded")
        ByteString.writeFile recordPath (recordDocument recorded)
        resolveCanonicalIssueReviewerAt (Just "   ") recordPath `shouldReturn` Right recorded

    it "resolves the backend the record names, wherever the installer put it" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        recorded <- installBackendAt (root </> "somewhere-else")
        ByteString.writeFile recordPath (recordDocument recorded)
        resolveCanonicalIssueReviewerAt Nothing recordPath `shouldReturn` Right recorded

    it "falls back to the record's own directory when no record was written" $
      withTemporaryCacheRoot $ \root -> do
        installed <- installBackendAt root
        resolveCanonicalIssueReviewerAt Nothing (root </> "config.json")
          `shouldReturn` Right installed

    -- What an install predating the discovery field actually looks like: the
    -- config.json the installer has always written for --config, well-formed
    -- and simply without the new key. That is an upgrade, not a fault.
    it "falls back for a legacy document carrying only a config reference" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        installed <- installBackendAt root
        ByteString.writeFile recordPath "{\"config_path\":\"/Users/example/.config/kanban/config.toml\"}"
        resolveCanonicalIssueReviewerAt Nothing recordPath `shouldReturn` Right installed

    it "reports a missing override without falling through to a recorded install" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        recorded <- installBackendAt (root </> "recorded")
        ByteString.writeFile recordPath (recordDocument recorded)
        outcome <- resolveCanonicalIssueReviewerAt (Just (root </> "empty")) recordPath
        failureFor outcome `shouldMention` "was not found at"
        failureFor outcome `shouldMention` "KANBAN_ISSUE_REVIEW_INSTALL_DIR selected"
        failureFor outcome `shouldNotMention` Data.Text.pack recorded

    it "reports a stale record when the backend it names is gone" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        _ <- installBackendAt root
        ByteString.writeFile recordPath (recordDocument (root </> "moved" </> "approve_issues.py"))
        outcome <- resolveCanonicalIssueReviewerAt Nothing recordPath
        failureFor outcome `shouldMention` "was not found at"
        failureFor outcome `shouldMention` Data.Text.pack recordPath
        failureFor outcome `shouldMention` "moved or was removed"

    -- The old diagnostic named only the default path and recommended the
    -- installer command; someone who had just run it successfully got no
    -- new information. Every branch now names the document consulted.
    it "names the record consulted when nothing is installed at the fallback" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        outcome <- resolveCanonicalIssueReviewerAt Nothing recordPath
        failureFor outcome `shouldMention` "was not found at"
        failureFor outcome `shouldMention` Data.Text.pack recordPath
        failureFor outcome `shouldMention` "No install directory is recorded at"

    it "distinguishes an unreadable record from an absent one" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
        _ <- installBackendAt root
        ByteString.writeFile recordPath "{\"backend_path\": "
        outcome <- resolveCanonicalIssueReviewerAt Nothing recordPath
        failureFor outcome `shouldMention` "is unreadable"
        failureFor outcome `shouldMention` Data.Text.pack recordPath
        failureFor outcome `shouldNotMention` "Error in $"
        -- A record it cannot read must not quietly resolve the installation
        -- sitting beside it: that is the case where the two could disagree.
        failureFor outcome `shouldNotMention` "was not found at"

    it "rejects a recorded backend path that names nothing resolvable" $
      withTemporaryCacheRoot $ \root -> do
        -- An install sits beside the record in every case, so a resolver that
        -- fell through to the compatibility default would succeed here rather
        -- than fail: that is the fail-open this pins shut.
        _ <- installBackendAt root
        let recordPath = root </> "config.json"
            rejects document = do
              ByteString.writeFile recordPath document
              outcome <- resolveCanonicalIssueReviewerAt Nothing recordPath
              failureFor outcome `shouldMention` "is unreadable"
              failureFor outcome `shouldNotMention` "was not found at"
        rejects "[\"/opt/approve_issues.py\"]"
        rejects "{\"backend_path\":42}"
        rejects (recordDocument "opt/kanban-review/approve_issues.py")
        -- An explicit null is a value the installer never writes, so it is a
        -- record corrupted into naming nothing -- not the absent field that
        -- means "installed before the record existed".
        rejects "{\"backend_path\":null}"

    it "treats a record link whose target is gone as unreadable, not absent" $
      withTemporaryCacheRoot $ \root -> do
        -- doesPathExist follows the link, so the dangling one it cannot
        -- follow reads as "nothing here" unless the link itself is stat-ed.
        -- The installer refuses to write through a link at this path, so a
        -- reader that ran the fallback instead would disagree with it.
        installed <- installBackendAt root
        let recordPath = root </> "config.json"
        createFileLink (root </> "gone.json") recordPath
        outcome <- resolveCanonicalIssueReviewerAt Nothing recordPath
        failureFor outcome `shouldMention` "is unreadable"
        failureFor outcome `shouldMention` Data.Text.pack recordPath
        failureFor outcome `shouldNotMention` Data.Text.pack installed

    it "treats a record path occupied by a directory as unreadable, not absent" $
      withTemporaryCacheRoot $ \root -> do
        -- Python's read raises rather than reporting "missing", so a
        -- doesFileExist test here would fall through to the default backend
        -- while every other consumer refused.
        installed <- installBackendAt root
        let recordPath = root </> "config.json"
        createDirectoryIfMissing True recordPath
        outcome <- resolveCanonicalIssueReviewerAt Nothing recordPath
        failureFor outcome `shouldMention` "is unreadable"
        failureFor outcome `shouldMention` Data.Text.pack recordPath
        failureFor outcome `shouldNotMention` Data.Text.pack installed

    -- The environment entry point for the no-override path, kept hermetic by
    -- redirecting HOME and clearing $XDG_DATA_HOME: it must reach the
    -- installer's record rather than the pre-migration ~/work launcher the
    -- vendoring migration removed. The record seeded under `~/Library` is the
    -- only occupied location, so this is what macOS and Linux both answer;
    -- an empty host's platform-dependent answer is "Spec.ManagedPaths"'s.
    it "consults the installer's record, not ~/work, when no override is set" $
      withTemporaryCacheRoot $ \root ->
        withManagedRecordHome root $ do
          let recordPath = root </> "Library/Application Support/kanban/issue-review/config.json"
          createDirectoryIfMissing True (takeDirectory recordPath)
          ByteString.writeFile recordPath "{}"
          resolved <- issueReviewerRecordPath
          resolved `shouldBe` recordPath
          outcome <- resolveCanonicalIssueReviewer
          failureFor outcome `shouldMention` "was not found at"
          failureFor outcome `shouldMention` Data.Text.pack recordPath
          failureFor outcome `shouldNotMention` "/work/approve-issues.py"

    it "selects without asking whether the backend is there, so preflight can classify it" $
      withTemporaryCacheRoot $ \root -> do
        let recordPath = root </> "config.json"
            absent = root </> "gone" </> "approve_issues.py"
        ByteString.writeFile recordPath (recordDocument absent)
        selectCanonicalIssueReviewerAt Nothing recordPath
          `shouldReturn` Right (ReviewerFromRecord recordPath, absent)
