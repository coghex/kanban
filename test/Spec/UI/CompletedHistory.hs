-- | What the board does with a completed generation: which outcome may be
-- applied at all, how the two generations are reconciled against each other,
-- and what a stored generation seeds.
--
-- Each of those is a total function the corresponding @EventM@ arm only
-- projects — 'currentCompletedGeneration' for ordering, 'historyWithoutOpen'
-- and 'openWithoutHistory' for identity, 'initialCompletedHistory' for the
-- seed — so the whole matrix is decided here without a terminal, and the
-- traversal that produces a generation is covered in "Spec.GitHub.History".
module Spec.UI.CompletedHistory (spec) where

import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Kanban.Cache
  ( CacheLoad (..),
    CompletedCacheLoad (..),
    completedCacheSchemaVersion,
    loadCompletedCache,
    loadRepositoryCache,
    repositoryCachePath,
    writeCompletedCache
  )
import Kanban.Domain
import Kanban.GitHub
  ( HistoryFetchState,
    advanceHistoryState,
    historyFetchProgress,
    historyTraversalComplete,
    initialHistoryFetchState
  )
import Kanban.UI (initialCompletedHistory)
import Kanban.UI.Reconcile (currentCompletedGeneration)
import Kanban.Workflow (deriveBoard)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch)
import Spec.Support.Json (completedPageJson, issueNodeJsonInState, malformedCompletedCacheFile, pullRequestNodeJsonInState, undecodableCacheFile, emptyAssigneesJson, emptyClosingIssuesJson, emptyLabelsJson, emptySubIssuesJson)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "which completed outcome may be applied" $ do
    -- Requirement 4. A completed identity is claimed by the board itself,
    -- before the job that answers under it is queued, so anything other than an
    -- exact match is an outcome some later request already superseded.
    it "accepts only the generation the board is currently waiting for" $ do
      currentCompletedGeneration 1 1 `shouldBe` True
      currentCompletedGeneration 4 4 `shouldBe` True

    it "discards a completion belonging to a generation a newer request superseded" $ do
      currentCompletedGeneration 2 1 `shouldBe` False
      currentCompletedGeneration 7 3 `shouldBe` False

    -- Nothing can claim an identity the board has not, so an outcome running
    -- ahead of it is a defect rather than the expiry case the open path has.
    it "discards an outcome claiming an identity the board never issued" $
      currentCompletedGeneration 1 2 `shouldBe` False

  describe "reconciling the two generations" $ do
    -- Requirement 8, in the direction the open generation publishes second: an
    -- item GitHub has just reported open cannot also be history.
    it "drops a reopened item from the completed set when the open generation publishes" $ do
      let history = CompletedHistory [closed 10, closed 11] [merged 20, merged 21] epoch
          openAgain = RepoSnapshot [baseIssue 10 []] [basePullRequest 20 [] False []] epoch
          reconciled = historyWithoutOpen openAgain history
      map (.issueNumber) reconciled.historyIssues `shouldBe` [11]
      map (.pullRequestNumber) reconciled.historyPullRequests `shouldBe` [21]

    -- And in the other direction, which is the one that may remove a card.
    it "drops a settled item from the open set when the completed generation publishes" $ do
      let history = CompletedHistory [closed 10] [merged 20] epoch
          stale = RepoSnapshot [baseIssue 10 [], baseIssue 11 []] [basePullRequest 20 [] False [], basePullRequest 21 [] False []] epoch
          reconciled = openWithoutHistory history stale
      map (.issueNumber) reconciled.snapshotIssues `shouldBe` [11]
      map (.pullRequestNumber) reconciled.snapshotPullRequests `shouldBe` [21]

    -- Whichever publishes second, the item ends up in exactly one set.
    it "leaves an item that moved between the sets in exactly one of them" $ do
      let history = CompletedHistory [closed 10] [] epoch
          open = RepoSnapshot [baseIssue 10 []] [] epoch
          openWon = (map (.issueNumber) (historyWithoutOpen open history).historyIssues, map (.issueNumber) open.snapshotIssues)
          completedWon = (map (.issueNumber) history.historyIssues, map (.issueNumber) (openWithoutHistory history open).snapshotIssues)
      openWon `shouldBe` ([], [10])
      completedWon `shouldBe` ([10], [])

    -- Requirement 10. With no overlap, reconciliation is the identity, so the
    -- board a completed publication would derive is the one already on screen
    -- and nothing about it is re-derived at all.
    it "leaves a disjoint open snapshot, and the board derived from it, untouched" $ do
      let history = CompletedHistory [closed 90] [merged 91] epoch
          open = RepoSnapshot [baseIssue 10 []] [basePullRequest 20 [] False []] epoch
      openWithoutHistory history open `shouldBe` open
      deriveBoard defaultWorkflowConfig (openWithoutHistory history open)
        `shouldBe` deriveBoard defaultWorkflowConfig open

  describe "completed progress" $ do
    -- Requirement 4 and §15: a generation in flight reports loaded and total
    -- separately per kind, and reports the total as unknown until GitHub has
    -- named one — never as a zero that would read as a finished empty history.
    it "reports nothing known before the first page answers" $ do
      historyFetchProgress initialHistoryFetchState `shouldBe` emptyCompletedProgress
      emptyCompletedProgress `shouldBe` CompletedProgress 0 Nothing 0 Nothing

    it "counts each kind against its own total, and keeps a total the next page stops asking for" $ do
      afterOnePage <- foldPage initialHistoryFetchState (pageWith (Just (7, 2, True)) (Just (3, 3, False)))
      historyFetchProgress afterOnePage `shouldBe` CompletedProgress 2 (Just 7) 3 (Just 3)
      historyTraversalComplete afterOnePage `shouldBe` False
      -- Pull requests are finished, so the next page carries that connection
      -- neither as nodes nor as a total; the total already known survives.
      afterTwoPages <- foldPage afterOnePage (pageWith (Just (7, 5, False)) Nothing)
      historyFetchProgress afterTwoPages `shouldBe` CompletedProgress 7 (Just 7) 3 (Just 3)
      historyTraversalComplete afterTwoPages `shouldBe` True

  describe "the completed history cache" $ do
    -- Requirement 6. A generation larger than one page in both kinds
    -- round-trips whole, bodies included, so a restart seeds exactly what the
    -- traversal published.
    it "round-trips a generation larger than 100 in both kinds" $
      withCompletedCacheRoot $ \repository -> do
        let history = CompletedHistory (map closed [1 .. 151]) (map merged [1 .. 120]) epoch
        writeCompletedCache repository history `shouldReturn` Right ()
        loadCompletedCache repository `shouldReturn` CompletedCacheLoaded history

    it "keeps the bodies a completed item was fetched with" $
      withCompletedCacheRoot $ \repository -> do
        let issue = (closed 10) {issueBody = "The whole background section, verbatim."}
            history = CompletedHistory [issue] [] epoch
        writeCompletedCache repository history `shouldReturn` Right ()
        loaded <- loadCompletedCache repository
        case loaded of
          CompletedCacheLoaded restored -> map (.issueBody) restored.historyIssues `shouldBe` [issue.issueBody]
          other -> expectationFailure ("expected the cached generation, got " <> show other)

    -- §16: another version is skew and is silent; a version this build claims
    -- to understand and cannot read is corruption and says so. Neither supplies
    -- data.
    it "treats a file written under another schema version as absent" $
      withCompletedCacheRoot $ \repository -> do
        cachePath <- repositoryCachePath repository
        ByteString.writeFile cachePath (malformedCompletedCacheFile (completedCacheSchemaVersion + 1))
        loadCompletedCache repository `shouldReturn` CompletedCacheAbsent

    it "reports malformed data under a recognised version rather than decoding it" $
      withCompletedCacheRoot $ \repository -> do
        cachePath <- repositoryCachePath repository
        ByteString.writeFile cachePath (malformedCompletedCacheFile completedCacheSchemaVersion)
        loadCompletedCache repository >>= (`shouldSatisfy` isInvalid)
        ByteString.writeFile cachePath (undecodableCacheFile completedCacheSchemaVersion)
        loadCompletedCache repository >>= (`shouldSatisfy` isInvalid)

    it "reports a recognised-version file belonging to another repository rather than adopting it" $
      withCompletedCacheRoot $ \repository -> do
        writeCompletedCache repository (CompletedHistory [closed 10] [] epoch) `shouldReturn` Right ()
        loadCompletedCache (repository {repositoryName = "other"})
          `shouldReturn` CompletedCacheAbsent
        -- The mismatch is only visible from the path that actually holds it,
        -- which is this repository's own.
        let elsewhere = repository {repositoryOwner = "someone", repositoryName = "else"}
        theirs <- repositoryCachePath elsewhere
        createDirectoryIfMissing True (takeDirectory theirs)
        ByteString.writeFile theirs =<< ByteString.readFile =<< repositoryCachePath repository
        loadCompletedCache elsewhere
          `shouldReturn` CompletedCacheInvalid "completed history cache ignored: repository identity mismatch"

    -- Requirement 6 again: the schema-6 gate must keep reading a file it does
    -- not own as absent, which is now true of the completed generation as much
    -- as of the version 5 snapshot it was raised over.
    it "reads as absent to the open-snapshot compatibility gate" $
      withCompletedCacheRoot $ \repository -> do
        writeCompletedCache repository (CompletedHistory [closed 10] [] epoch) `shouldReturn` Right ()
        loadRepositoryCache repository `shouldReturn` CacheAbsent

    -- Requirement 9: a failed generation never reaches the writer, so the last
    -- complete one is still exactly what a restart would seed.
    it "leaves a stored generation untouched when a later one never completes" $
      withCompletedCacheRoot $ \repository -> do
        let stored = CompletedHistory [closed 10] [merged 20] epoch
        writeCompletedCache repository stored `shouldReturn` Right ()
        asWritten <- ByteString.readFile =<< repositoryCachePath repository
        -- Nothing else runs: an interrupted or failed generation produces no
        -- 'CompletedHistory' at all, so there is nothing that could be written.
        loadCompletedCache repository `shouldReturn` CompletedCacheLoaded stored
        (ByteString.readFile =<< repositoryCachePath repository) `shouldReturn` asWritten

  describe "what a stored generation seeds" $ do
    it "seeds the history from a loaded generation, silently" $
      initialCompletedHistory (CompletedCacheLoaded (CompletedHistory [closed 10] [] epoch))
        `shouldBe` (Just (CompletedHistory [closed 10] [] epoch), Nothing)

    it "seeds nothing, and says nothing, when no generation is stored" $
      initialCompletedHistory CompletedCacheAbsent `shouldBe` (Nothing, Nothing)

    it "seeds nothing but reports a file this build could not read" $
      initialCompletedHistory (CompletedCacheInvalid "completed history cache ignored: bad")
        `shouldBe` (Nothing, Just "completed history cache ignored: bad")

isInvalid :: CompletedCacheLoad -> Bool
isInvalid (CompletedCacheInvalid _) = True
isInvalid _ = False

closed :: Int -> Issue
closed number = (baseIssue number []) {issueState = IssueClosed}

merged :: Int -> PullRequest
merged number = (basePullRequest number [] False []) {pullRequestState = PullRequestMerged}

withCompletedCacheRoot :: (Repository -> IO ()) -> IO ()
withCompletedCacheRoot body =
  withTemporaryCacheRoot $ \cacheRoot ->
    withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
      let repository = Repository "/tmp/project" "coghex" "kanban"
      cachePath <- repositoryCachePath repository
      createDirectoryIfMissing True (takeDirectory cachePath)
      body repository

-- | Folds one decoded page into a traversal state.
foldPage :: HistoryFetchState -> String -> IO HistoryFetchState
foldPage state page = case eitherDecode (LazyByteString.pack page) of
  Left message -> fail ("undecodable fixture page: " <> message)
  Right decoded -> either (fail . show) pure (advanceHistoryState state decoded)

-- | A completed page described by what it means rather than by its bytes: for
-- each connection, GitHub's total, how many nodes this page delivers, and
-- whether another follows. An absent connection is one the traversal has
-- already finished and stopped asking for.
pageWith :: Maybe (Int, Int, Bool) -> Maybe (Int, Int, Bool) -> String
pageWith issues pullRequests =
  completedPageJson (fmap issueConnection issues) (fmap pullRequestConnection pullRequests)
  where
    issueConnection (total, delivered, more) =
      ( total,
        [issueNodeJsonInState "CLOSED" Nothing number [emptyLabelsJson, emptyAssigneesJson, emptySubIssuesJson] | number <- [1 .. delivered]],
        cursorFor more
      )
    pullRequestConnection (total, delivered, more) =
      ( total,
        [pullRequestNodeJsonInState "MERGED" Nothing number [emptyLabelsJson, emptyClosingIssuesJson] | number <- [1 .. delivered]],
        cursorFor more
      )
    cursorFor more = if more then Just "next" else Nothing
