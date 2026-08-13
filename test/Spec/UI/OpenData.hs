-- | The live-only open-data lifecycle: which body the board draws before a
-- generation has completed, which outcome is allowed to replace a published
-- board, and what survives the swap when one does.
--
-- Nothing here needs a terminal or an @EventM@. Each decision the dashboard
-- makes about the lifecycle is a total function the corresponding arm only
-- projects — 'openDataView' for the body, 'currentOpenGeneration' for
-- ordering, 'failureFreshness' for first-load versus later failure,
-- 'boardRefreshDispatch' for what @u@ does — so the whole matrix is covered
-- here and the frames those decisions produce are covered in
-- "Spec.UI.Golden".
module Spec.UI.OpenData (spec) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text
import Kanban.Cache (repositoryCachePath)
import Kanban.Config (ResolvedConfig (..))
import Kanban.Domain
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.UI (loadStartupCaches, startupBoard)
import Kanban.UI.Refresh (BoardRefreshDispatch (..), boardRefreshDispatch)
import Kanban.UI.Reconcile
  ( currentOpenGeneration,
    failureFreshness,
    reconcilePullRequestSessions,
    reconcileReviewSessions,
    refreshSuccessNotice
  )
import Kanban.UI.Selection (preserveSelection, refreshOverlay)
import Kanban.UI.Types
  ( AgentSession (..),
    AppState (..),
    OpenDataView (..),
    Overlay (..),
    ReviewPhase (..),
    SolvePhase (..),
    openDataView
  )
import Kanban.UI.Util (entriesForBoard, allColumns)
import Kanban.Workflow (deriveBoard)
import Spec.Support.App (testAppState, testPullRequestSession, testReviewSession)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch, testOptions, testResolvedConfig)
import Spec.Support.Json (versionFiveCacheFile)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)
import Test.Hspec

spec :: Spec
spec = do
  describe "what the board body draws" $ do
    -- Requirements 6 and 7: until one generation completes there is nothing
    -- to draw a board from, and which panel stands in for it is decided by
    -- whether anything has failed yet.
    it "shows the loading panel until a generation has either completed or failed" $ do
      openDataView Nothing NotLoaded `shouldBe` OpenDataLoading
      openDataView Nothing Loading `shouldBe` OpenDataLoading

    it "shows the unavailable panel, carrying the classified reason, once the first generation fails" $
      openDataView Nothing (Unavailable "TIMED OUT: GitHub refresh timed out after 30 seconds")
        `shouldBe` OpenDataUnavailable "TIMED OUT: GitHub refresh timed out after 30 seconds"

    -- Requirement 8: one complete generation is conclusive. Every later
    -- state, including the loading state of the refresh that is running right
    -- now and the failure it may end in, keeps that board on screen.
    it "keeps the last complete board through every later refresh state" $
      mapM_
        (\freshness -> openDataView (Just epoch) freshness `shouldBe` OpenDataBoard)
        [ NotLoaded,
          Loading,
          Fresh epoch,
          Stale epoch "REQUEST ERROR: gh fell over",
          Unavailable "AUTH REQUIRED: not signed in",
          Unsupported "UNSUPPORTED VERSION: too old"
        ]

    -- A failure is only "first load" while nothing has completed, and that is
    -- exactly the distinction the two panels rest on.
    it "records a first failure as unavailable and a later one as stale over the board it keeps" $ do
      let failed = ProviderError RequestTimedOut "GitHub refresh timed out after 30 seconds"
      failureFreshness Nothing failed
        `shouldBe` Unavailable "TIMED OUT: GitHub refresh timed out after 30 seconds"
      failureFreshness (Just epoch) failed
        `shouldBe` Stale epoch "TIMED OUT: GitHub refresh timed out after 30 seconds"

    -- §7's panel has to name the kind, not just the message: it replaces the
    -- board outright, so it is the only thing on screen that can say what
    -- went wrong.
    it "names the classified kind in the reason the unavailable panel carries" $
      mapM_
        ( \(kind, expected) ->
            failureFreshness Nothing (ProviderError kind "detail")
              `shouldBe` Unavailable (expected <> ": detail")
        )
        [ (AuthenticationRequired, "AUTH REQUIRED"),
          (ExecutableMissing, "NOT INSTALLED"),
          (RateLimited, "RATE LIMITED"),
          (RequestTimedOut, "TIMED OUT")
        ]

    -- Requirement 7: the unavailable state is recoverable. `u` reaches
    -- 'boardRefreshDispatch', and from a failed first load with no cycle in
    -- flight it starts one rather than queueing behind nothing.
    it "lets u start a fresh generation from the unavailable state" $ do
      boardRefreshDispatch (Unavailable "AUTH REQUIRED: not signed in") False `shouldBe` StartRefreshNow
      boardRefreshDispatch NotLoaded False `shouldBe` StartRefreshNow
      -- And still coalesces while one is actually running, so a held retry
      -- never starts a second cycle beside the first.
      boardRefreshDispatch (Unavailable "AUTH REQUIRED: not signed in") True `shouldBe` QueueRefreshUntilIdle
      boardRefreshDispatch Loading False `shouldBe` QueueRefreshUntilIdle

  describe "startup" $ do
    it "starts from an empty board rather than a restored one" $
      concatMap (entriesForBoard (startupBoard defaultWorkflowConfig epoch)) allColumns `shouldBe` []

    it "draws the loading panel for the state the dashboard is constructed in" $
      openDataView Nothing NotLoaded `shouldBe` OpenDataLoading

    -- Requirement 5, from the startup side: the one durable read startup makes
    -- is the usage cache. A repository snapshot an earlier release left behind
    -- is not opened at all, so it cannot be decoded, rewritten, or removed.
    it "reads no repository snapshot, leaving a schema 5 file exactly as it found it" $
      withTemporaryCacheRoot $ \cacheRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
          let repository = Repository "/tmp/project" "coghex" "kanban"
          cachePath <- repositoryCachePath repository
          createDirectoryIfMissing True (takeDirectory cachePath)
          ByteString.writeFile cachePath (versionFiveCacheFile 5)
          asFound <- ByteString.readFile cachePath
          _ <- loadStartupCaches testOptions (testResolvedConfig {resolvedCache = True})
          doesFileExist cachePath `shouldReturn` True
          ByteString.readFile cachePath `shouldReturn` asFound

  describe "publication ordering" $ do
    -- Requirement 9, and the correction that pins what "newest" means: a `u`
    -- that only managed to queue a follow-up has started no generation, so
    -- the cycle already running still publishes under its own identity.
    it "accepts the answer of the newest generation the board has seen start" $ do
      currentOpenGeneration 1 1 `shouldBe` True
      currentOpenGeneration 2 2 `shouldBe` True

    it "discards an answer from a generation a newer one has superseded" $ do
      currentOpenGeneration 2 1 `shouldBe` False
      currentOpenGeneration 5 4 `shouldBe` False

    -- An expiring request is answered under an identity that was claimed but
    -- never announced, so its outcome runs ahead of the board's own record and
    -- must still be applied rather than dropped as stale.
    it "accepts an answer claimed ahead of the last start the board heard about" $
      currentOpenGeneration 1 2 `shouldBe` True

  describe "what survives a generation swap" $ do
    -- Requirement 10: the swap is the same reconciliation a refresh has
    -- always performed. This drives the four pieces 'applyBoardRefresh'
    -- composes against a board whose rows have moved, so "preserved by
    -- identity" is asserted rather than assumed from an unchanged layout.
    it "keeps the selected item, the overlay's target, and both session associations" $ do
      let issue number labels = (baseIssue number []) {issueLabels = labels}
          approved = [Label "reviewed:approve" "2f9e44"]
          priorBoard = deriveBoard defaultWorkflowConfig (RepoSnapshot [issue 10 [], issue 20 []] [] epoch)
          -- The newer generation approves #10 and brings a second approved
          -- issue that sorts above it, so #10 moves down a row: a selection
          -- kept by index would land on a card the user never chose.
          afterSnapshot =
            RepoSnapshot
              [issue 5 approved, issue 10 approved, issue 20 []]
              [basePullRequest 30 [10] False []]
              epoch
          swappedBoard = deriveBoard defaultWorkflowConfig afterSnapshot
          rowOf board number =
            length (takeWhile ((/= Just number) . entryNumber) (entriesForBoard board Issues))
          entryNumber entry = case entry of
            Standalone (IssueItem candidate) -> Just candidate.issueNumber
            Tracked _ (IssueItem candidate) -> Just candidate.issueNumber
            _ -> Nothing
      state <- testAppState priorBoard
      let selected =
            state
              { appSelectedColumn = Issues,
                appSelectedRows = Map.insert Issues (rowOf priorBoard 10) state.appSelectedRows,
                appOverlay = Just (DetailsOverlay (IssueItem (issue 10 []))),
                appReviewSessions = Map.singleton 10 (testReviewSession (issue 10 []) ReviewWaiting),
                appPullRequestReviewSessions =
                  Map.singleton 30 (testPullRequestSession (basePullRequest 30 [10] False []) SolveRunning)
              }
          (swappedColumn, swappedRows) = preserveSelection selected swappedBoard
          (swappedOverlay, overlayNotice) = refreshOverlay swappedBoard selected.appOverlay
          swappedReviews = reconcileReviewSessions defaultWorkflowConfig afterSnapshot.snapshotIssues selected.appReviewSessions
          swappedPullRequests = reconcilePullRequestSessions afterSnapshot.snapshotPullRequests selected.appPullRequestReviewSessions
      -- The card, not the row: #10 moved, and the selection moved with it.
      swappedColumn `shouldBe` Issues
      Map.lookup Issues swappedRows `shouldBe` Just (rowOf swappedBoard 10)
      rowOf swappedBoard 10 `shouldNotBe` rowOf priorBoard 10
      -- The overlay still targets #10, now carrying the newer generation's
      -- copy of it rather than the one it was opened on.
      overlayNotice `shouldBe` Nothing
      case swappedOverlay of
        Just (DetailsOverlay (IssueItem shown)) -> do
          shown.issueNumber `shouldBe` 10
          shown.issueLabels `shouldBe` approved
        other -> expectationFailure ("expected the details overlay to survive, got " <> show other)
      -- Both live sessions stay associated with their item, and the review
      -- session sees the approval the new generation brought.
      Map.keys swappedReviews `shouldBe` [10]
      fmap (.sessionPhase) (Map.lookup 10 swappedReviews) `shouldBe` Just ReviewFinished
      Map.keys swappedPullRequests `shouldBe` [30]

  describe "the refresh banner" $ do
    -- Requirement 3: the counted sources are exact, because there is no cap
    -- for a `+` to stand for.
    it "counts both sources without a truncation marker" $
      refreshSuccessNotice
        (RepoSnapshot [baseIssue 1 [], baseIssue 2 []] [basePullRequest 3 [] False []] epoch)
        []
        `shouldBe` ("GitHub refreshed · 2 issues · 1 PR" :: Text)

    it "keeps reporting the warnings a snapshot does still carry" $
      refreshSuccessNotice (RepoSnapshot [] [] epoch) ["1 card contains something"]
        `shouldSatisfy` Data.Text.isInfixOf "1 card contains something"
