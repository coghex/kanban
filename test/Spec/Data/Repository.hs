-- | Repository identity parsing.
module Spec.Data.Repository (spec) where

import Kanban.Repository (parseRemoteRepository, parseRepositoryName)
import Spec.Support.Expect (isLeft, rejectsWithGuidance)
import Test.Hspec

spec :: Spec
spec = do
  describe "repository identity parsing" $ do
    it "parses an HTTPS GitHub remote" $
      parseRemoteRepository "https://github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
    it "parses an SSH GitHub remote" $
      parseRemoteRepository "git@github.com:coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
    it "parses explicit OWNER/NAME syntax" $
      parseRepositoryName "coghex/kanban" `shouldBe` Right ("coghex", "kanban")

    it "parses every promised GitHub remote grammar" $ do
      -- Each supported scheme, with and without the optional userinfo,
      -- numeric port, '.git' suffix, and trailing slash.
      parseRemoteRepository "https://github.com/coghex/kanban" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "https://github.com/coghex/kanban/" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "https://github.com:443/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "https://www.github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "ssh://git@github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "ssh://git@github.com:22/coghex/kanban" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "git://github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "git://github.com:9418/coghex/kanban" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "git@github.com:coghex/kanban" `shouldBe` Right ("coghex", "kanban")

    it "compares the remote host case-insensitively, as DNS does" $ do
      parseRemoteRepository "HTTPS://GitHub.COM/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
      parseRemoteRepository "git@GITHUB.com:coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")

    it "rejects a local or relative remote path instead of guessing an owner" $ do
      -- The bug this guards: a bare mirror parsed to ("team", "myrepo") and
      -- the dashboard then rendered an unrelated github.com/team/myrepo.
      parseRemoteRepository "/srv/git/team/myrepo.git" `shouldSatisfy` rejectsWithGuidance "/srv/git/team/myrepo.git"
      parseRemoteRepository "../local-fork" `shouldSatisfy` rejectsWithGuidance "../local-fork"
      parseRemoteRepository "team/myrepo" `shouldSatisfy` rejectsWithGuidance "team/myrepo"

    it "rejects remotes hosted anywhere other than github.com" $ do
      parseRemoteRepository "https://gitlab.com/coghex/kanban.git"
        `shouldSatisfy` rejectsWithGuidance "https://gitlab.com/coghex/kanban.git"
      parseRemoteRepository "https://git.corp.example.test/coghex/kanban.git"
        `shouldSatisfy` rejectsWithGuidance "git.corp.example.test"
      -- A deceptive suffix host: github.com is a label here, not the domain.
      parseRemoteRepository "https://github.com.example.test/coghex/kanban.git"
        `shouldSatisfy` rejectsWithGuidance "github.com.example.test"
      parseRemoteRepository "gh-alias:coghex/kanban" `shouldSatisfy` rejectsWithGuidance "gh-alias:coghex/kanban"

    it "rejects GitHub remotes whose path is not exactly OWNER/NAME" $ do
      parseRemoteRepository "https://github.com/coghex/kanban/tree/master"
        `shouldSatisfy` rejectsWithGuidance "tree/master"
      parseRemoteRepository "https://github.com/coghex" `shouldSatisfy` rejectsWithGuidance "https://github.com/coghex"
      -- SCP-style syntax has no port: the colon begins the path.
      parseRemoteRepository "git@github.com:22/coghex/kanban"
        `shouldSatisfy` rejectsWithGuidance "git@github.com:22/coghex/kanban"
      -- A trailing query cannot smuggle punctuation into the GraphQL query.
      parseRemoteRepository "https://github.com/coghex/kanban?owner=evil"
        `shouldSatisfy` rejectsWithGuidance "kanban?owner=evil"

    it "rejects a plaintext http remote, which is outside the supported schemes" $
      parseRemoteRepository "http://github.com/coghex/kanban.git"
        `shouldSatisfy` rejectsWithGuidance "http://github.com/coghex/kanban.git"

    it "accepts a relative OWNER/NAME only when the user supplied it explicitly" $ do
      -- Same text, different source: an inherited remote must not be
      -- trusted to name a GitHub repository, but --repo is a deliberate choice.
      parseRepositoryName "team/myrepo" `shouldBe` Right ("team", "myrepo")
      parseRemoteRepository "team/myrepo" `shouldSatisfy` rejectsWithGuidance "team/myrepo"

    it "still rejects an explicit --repo value that names no GitHub repository" $ do
      parseRepositoryName "/srv/git/team/myrepo.git" `shouldSatisfy` isLeft
      parseRepositoryName "https://gitlab.com/coghex/kanban.git" `shouldSatisfy` isLeft
      -- An explicit GitHub URL keeps working, as it did before validation.
      parseRepositoryName "https://github.com/coghex/kanban.git" `shouldBe` Right ("coghex", "kanban")
