-- | The background traversal of completed history, driven through the same
-- seam the coordinator schedules: one page per call, against a fake @gh@ on
-- @PATH@ and a temporary cache root.
--
-- Everything here is about what a /page/ leaves behind — how far the traversal
-- got, what it reported, and what the coordinator is told to do next — because
-- that is the whole of the contract between this traversal and the scheduling
-- above it. What the board then does with a published generation is decided by
-- the pure functions covered in "Spec.UI.CompletedHistory".
module Spec.GitHub.History (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import qualified Data.ByteString.Char8 as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import Kanban.Domain
import Kanban.GitHub
  ( CompletedGeneration,
    CoordinatorState (..),
    GhCleanupFailure,
    GhRecordLock,
    HistoryOutcome (..),
    HistoryPageResult (..),
    HistoryTraversal,
    HoldReason (..),
    JobHold (..),
    RefreshJob (..),
    beginCompletedGeneration,
    ghFetchCleanupFailure,
    initialCoordinatorState,
    newGhFetchGuard,
    newGhRecordLock,
    newHistoryTraversal,
    runCompletedHistoryPage,
    settleHistoryJob
  )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Spec.Support.Board (withFakeGh)
import Spec.Support.Env (waitForFileToExist, withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Fixtures (epoch)
import Spec.Support.Json
  ( completedPageJson,
    emptyAssigneesJson,
    emptyClosingIssuesJson,
    emptyLabelsJson,
    emptySubIssuesJson,
    issueNodeJsonInState,
    pullRequestNodeJsonInState,
    rateLimitedGraphqlResponse
  )
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = describe "completed history traversal" $ do
  -- Requirement 1. Both connections are longer than the 100 GitHub delivers at
  -- once, and they run out at different pages -- the ordinary shape of an
  -- uncapped traversal -- so the last page asks for issues alone and only that
  -- page may report the generation whole.
  it "follows both completed connections past 100 to their final pages, reporting complete only on the last" $
    withServedPages
      [ completedPageJson
          (Just (251, closedIssues [1 .. 100], Just "i1"))
          (Just (101, settledPullRequests [1 .. 100], Just "p1")),
        completedPageJson
          (Just (251, closedIssues [101 .. 200], Just "i2"))
          (Just (101, settledPullRequests [101 .. 101], Nothing)),
        -- Pull requests are done, so the query stops asking for them and the
        -- page comes back without that connection at all.
        completedPageJson (Just (251, closedIssues [201 .. 251], Nothing)) Nothing
      ]
      $ \probe -> do
        results <- mapM (const (runPage probe)) [1 :: Int .. 3]
        results `shouldBe` [HistoryPageFetched True, HistoryPageFetched True, HistoryPageFetched False]
        reported <- readIORef probe.probeReports
        -- Every identity is the one generation nobody superseded.
        map fst reported `shouldBe` [1, 1, 1]
        case map snd reported of
          [HistoryProgressed first, HistoryProgressed second, HistoryCompleted history] -> do
            first `shouldBe` CompletedProgress 100 (Just 251) 100 (Just 101)
            second `shouldBe` CompletedProgress 200 (Just 251) 101 (Just 101)
            map (.issueNumber) history.historyIssues `shouldBe` [1 .. 251]
            map (.pullRequestNumber) history.historyPullRequests `shouldBe` [1 .. 101]
            -- Requirement 3: the lifecycle came off each item rather than off
            -- the traversal that returned it.
            map (.issueState) history.historyIssues `shouldBe` replicate 251 IssueClosed
            map (.pullRequestState) history.historyPullRequests `shouldBe` replicate 101 PullRequestMerged
          other -> expectationFailure ("expected two progress reports and one completion, got " <> show other)

  -- Requirement 1 again, from the query's side: a traversal that asked for
  -- open work would satisfy every assertion above while fetching the wrong
  -- items entirely.
  it "asks for closed issues and closed-or-merged pull requests, resuming each connection by its own cursor" $
    withServedPages
      [ completedPageJson
          (Just (2, closedIssues [1 .. 1], Just "i1"))
          (Just (1, settledPullRequests [1 .. 1], Nothing)),
        completedPageJson (Just (2, closedIssues [2 .. 2], Nothing)) Nothing
      ]
      $ \probe -> do
        _ <- runPage probe
        _ <- runPage probe
        firstArgv <- readArgv probe 1
        secondArgv <- readArgv probe 2
        firstArgv `shouldSatisfy` any ("states: [CLOSED]" `isInfixOf`)
        firstArgv `shouldSatisfy` any ("states: [CLOSED, MERGED]" `isInfixOf`)
        firstArgv `shouldSatisfy` notElem "issueCursor=i1"
        -- The second page resumes the connection that had more, and never
        -- re-asks for the one that did not.
        secondArgv `shouldSatisfy` elem "issueCursor=i1"
        secondArgv `shouldSatisfy` elem "fetchPullRequests=false"

  -- Requirement 2. A page that never answers fails on the configured per-page
  -- budget, unwinds through the same verified cleanup an open page does, and
  -- ends the traversal rather than being retried.
  it "fails a page that outran the per-page deadline, with its gh confirmed gone and no requeue" $
    withHistoryProbe 1 (const ["sleep 30", "printf '%s' 'never reached'"]) $ \probe -> do
      result <- runPage probe
      result `shouldBe` HistoryPageFailed False
      -- Nothing was left unaccounted for, so a history page never leaves the
      -- board holding off its own refreshes.
      readIORef probe.probeCleanup `shouldReturn` [Nothing]
      reported <- readIORef probe.probeReports
      case map snd reported of
        [HistoryFailed providerError] -> providerError.providerErrorKind `shouldBe` RequestTimedOut
        other -> expectationFailure ("expected one reported failure, got " <> show other)
      settledAfter result `shouldSatisfy` (not . historyIsPending)

  it "ends the traversal on an ordinary page failure rather than reissuing it" $
    withHistoryProbe 30 (const ["echo 'gh: something broke' >&2", "exit 1"]) $ \probe -> do
      result <- runPage probe
      result `shouldBe` HistoryPageFailed False
      reported <- readIORef probe.probeReports
      case map snd reported of
        [HistoryFailed _] -> pure ()
        other -> expectationFailure ("expected one reported failure, got " <> show other)
      settledAfter result `shouldSatisfy` (not . historyIsPending)

  -- Requirement 2's other half: the one failure the coordinator waits out is
  -- reissued under a hold, and the traversal picks up where the refusal
  -- interrupted it rather than paying for its earlier pages again.
  it "waits out a rate limit under a hold and resumes the interrupted page" $
    withServedPages
      [ completedPageJson (Just (2, closedIssues [1 .. 1], Just "i1")) (Just (0, [], Nothing)),
        ByteString.unpack rateLimitedGraphqlResponse,
        completedPageJson (Just (2, closedIssues [2 .. 2], Nothing)) Nothing
      ]
      $ \probe -> do
        _ <- runPage probe
        refused <- runPage probe
        refused `shouldBe` HistoryPageFailed True
        -- A refusal is not the generation ending, so nothing is reported for
        -- it: the traversal is still going to answer.
        readIORef probe.probeReports >>= \reported -> length reported `shouldBe` 1
        let held = settledAfter refused
        held `shouldSatisfy` historyIsPending
        fmap (.holdReason) (Map.lookup HistoryJob held.coordinatorHolds) `shouldBe` Just HeldForRateLimit
        _ <- runPage probe
        resumed <- readArgv probe 3
        resumed `shouldSatisfy` elem "issueCursor=i1"
        reported <- readIORef probe.probeReports
        case map snd reported of
          [HistoryProgressed _, HistoryCompleted history] ->
            map (.issueNumber) history.historyIssues `shouldBe` [1, 2]
          other -> expectationFailure ("expected the resumed traversal to complete exactly once, got " <> show other)

  -- Requirement 4. A request arriving while a page is in flight supersedes it
  -- at the page boundary: that page publishes nothing at all, and the next one
  -- starts the newest generation from its own first page.
  it "discards a page whose generation was superseded while it was in flight" $
    withPagesAnd
      [ completedPageJson (Just (2, closedIssues [1 .. 1], Just "i1")) (Just (0, [], Nothing)),
        completedPageJson (Just (1, closedIssues [7 .. 7], Nothing)) (Just (0, [], Nothing))
      ]
      ( \temporaryRoot ->
          [ ByteString.pack ("printf '%s' 'started' > " <> temporaryRoot </> "marker"),
            "sleep 1",
            ByteString.pack ("cat " <> temporaryRoot <> "/page.$page.json")
          ]
      )
      $ \probe -> do
        finished <- newEmptyMVar
        _ <- forkIO (runPage probe >>= putMVar finished)
        waitForFileToExist (probe.probeRoot </> "marker") 100
        beginCompletedGeneration probe.probeTraversal `shouldReturn` 2
        result <- takeMVar finished
        -- More work, so the newest generation is asked for straight away --
        -- and nothing at all was published for the one it replaced.
        result `shouldBe` HistoryPageFetched True
        readIORef probe.probeReports `shouldReturn` []
        _ <- runPage probe
        restarted <- readArgv probe 2
        restarted `shouldSatisfy` notElem "issueCursor=i1"
        reported <- readIORef probe.probeReports
        map fst reported `shouldBe` [2]
        case map snd reported of
          [HistoryCompleted history] -> map (.issueNumber) history.historyIssues `shouldBe` [7]
          other -> expectationFailure ("expected the newest generation to complete on its own, got " <> show other)

  -- Requirement 7. Nothing about the traversal is incremental, so an edit to
  -- an item closed or merged long ago is picked up by the ordinary next
  -- generation rather than needing one that knows to look for it.
  it "picks up an edited title on a long-closed issue and a long-merged pull request" $
    withServedPages [editedPage "As first fetched"] $ \probe -> do
      _ <- runPage probe
      -- The same items, edited on GitHub between the two generations.
      writeFile (probe.probeRoot </> "page.2.json") (editedPage "Edited long after closing")
      beginCompletedGeneration probe.probeTraversal `shouldReturn` 2
      _ <- runPage probe
      reported <- readIORef probe.probeReports
      map fst reported `shouldBe` [1, 2]
      case map snd reported of
        [HistoryCompleted first, HistoryCompleted second] -> do
          map (.issueTitle) first.historyIssues `shouldBe` ["As first fetched"]
          map (.pullRequestTitle) first.historyPullRequests `shouldBe` ["As first fetched"]
          map (.issueTitle) second.historyIssues `shouldBe` ["Edited long after closing"]
          map (.pullRequestTitle) second.historyPullRequests `shouldBe` ["Edited long after closing"]
        other -> expectationFailure ("expected two complete generations, got " <> show other)

-- | One long-closed issue and one long-merged pull request, both carrying the
-- given title, in a single complete page.
editedPage :: String -> String
editedPage title =
  completedPageJson
    (Just (1, [issueNodeJsonInState "CLOSED" (Just title) 5 completeIssueConnections], Nothing))
    (Just (1, [pullRequestNodeJsonInState "MERGED" (Just title) 9 completePullRequestConnections], Nothing))

-- | Everything one driven traversal needs, and everything it recorded.
data Probe = Probe
  { probeRoot :: FilePath,
    probeRepository :: Repository,
    probePageSeconds :: Int,
    probeTraversal :: HistoryTraversal,
    probeRecordLock :: GhRecordLock,
    -- | Every outcome reported, in order, under the generation it answered for.
    probeReports :: IORef [(CompletedGeneration, HistoryOutcome)],
    -- | Each page's cleanup verdict, in order. A background page leaving a
    -- @gh@ nobody could confirm dead is the one thing it must never do
    -- quietly.
    probeCleanup :: IORef [Maybe GhCleanupFailure]
  }

-- | Runs exactly one page, under a guard of its own — which is what the
-- coordinator gives every job it starts.
runPage :: Probe -> IO HistoryPageResult
runPage probe = do
  guard <- newGhFetchGuard probe.probeRecordLock
  result <-
    runCompletedHistoryPage
      (\generation outcome -> atomicModifyIORef' probe.probeReports (\seen -> (seen <> [(generation, outcome)], ())))
      probe.probePageSeconds
      probe.probeRepository
      probe.probeTraversal
      guard
      (const (pure ()))
  verdict <- ghFetchCleanupFailure guard
  atomicModifyIORef' probe.probeCleanup (\seen -> (seen <> [verdict], ()))
  pure result

-- | Where a finished page leaves the coordinator that was running it, so what
-- a page result /means/ to the scheduling above is asserted rather than
-- assumed. This is the coordinator's own unchanged settlement, driven with the
-- page result the traversal produced.
settledAfter :: HistoryPageResult -> CoordinatorState
settledAfter result =
  settleHistoryJob epoch (Just result) initialCoordinatorState {coordinatorRunning = Just HistoryJob}

historyIsPending :: CoordinatorState -> Bool
historyIsPending state = Map.member HistoryJob state.coordinatorPending

-- | Drives a traversal against a fake @gh@ that serves the given pages in
-- order, one per invocation, under the default page budget.
withServedPages :: [String] -> (Probe -> IO ()) -> IO ()
withServedPages pages =
  withPagesAnd pages (\temporaryRoot -> [ByteString.pack ("cat " <> temporaryRoot <> "/page.$page.json")])

-- | The same, for a fake @gh@ whose body is the point rather than the pages it
-- serves. The body is appended to the argv-recording preamble, so @$page@ is
-- already the invocation number by the time it runs.
withPagesAnd :: [String] -> (FilePath -> [ByteString.ByteString]) -> (Probe -> IO ()) -> IO ()
withPagesAnd pages ghBody body =
  withHistoryProbe 30 ghBody $ \probe -> do
    mapM_
      (\(index, page) -> writeFile (probe.probeRoot </> ("page." <> show index <> ".json")) page)
      (zip [1 :: Int ..] pages)
    body probe

withHistoryProbe :: Int -> (FilePath -> [ByteString.ByteString]) -> (Probe -> IO ()) -> IO ()
withHistoryProbe pageSeconds ghBody body =
  withTemporaryCacheRoot $ \temporaryRoot ->
    withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
      traversal <- newHistoryTraversal
      recordLock <- newGhRecordLock
      reports <- newIORef []
      cleanup <- newIORef []
      let probe =
            Probe
              { probeRoot = temporaryRoot,
                probeRepository = Repository temporaryRoot "coghex" "kanban",
                probePageSeconds = pageSeconds,
                probeTraversal = traversal,
                probeRecordLock = recordLock,
                probeReports = reports,
                probeCleanup = cleanup
              }
      withFakeGh temporaryRoot (argvRecordingPreamble temporaryRoot <> ghBody temporaryRoot) $ do
        beginCompletedGeneration traversal `shouldReturn` 1
        body probe

-- | Counts its own invocations and records the argv it was handed for that
-- page, so which items a page asked GitHub for is observable rather than
-- inferred.
argvRecordingPreamble :: FilePath -> [ByteString.ByteString]
argvRecordingPreamble temporaryRoot =
  [ ByteString.pack ("page=$(cat " <> temporaryRoot <> "/page.count 2>/dev/null || echo 0)"),
    "page=$((page + 1))",
    ByteString.pack ("printf '%s' \"$page\" > " <> temporaryRoot <> "/page.count"),
    ByteString.pack ("printf '%s\\n' \"$@\" > " <> temporaryRoot <> "/argv.$page.txt")
  ]

readArgv :: Probe -> Int -> IO [String]
readArgv probe page = lines <$> readFile (probe.probeRoot </> ("argv." <> show page <> ".txt"))

closedIssues :: [Int] -> [String]
closedIssues numbers = [issueNodeJsonInState "CLOSED" Nothing number completeIssueConnections | number <- numbers]

settledPullRequests :: [Int] -> [String]
settledPullRequests numbers =
  [pullRequestNodeJsonInState "MERGED" Nothing number completePullRequestConnections | number <- numbers]

-- | Every nested connection answered, so nothing a completed item reports is
-- an artefact of a gap.
completeIssueConnections :: [String]
completeIssueConnections = [emptyLabelsJson, emptyAssigneesJson, emptySubIssuesJson]

completePullRequestConnections :: [String]
completePullRequestConnections = [emptyLabelsJson, emptyClosingIssuesJson]
