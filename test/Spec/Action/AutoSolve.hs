-- | The complete autosolve action, driven headlessly.
--
-- The point of these examples is that the whole loop — solver, discovery, the
-- opposite-brand review, the resumed solver, the canonical rereview, and the
-- approval — runs with no @AppState@, no @EventM@, and no Brick refresh. What
-- stands in for the machine is the same seam 'Kanban.Worker.runWorkerWithTask'
-- uses for its task: the two things the loop does to the world are injected,
-- so a scripted world of durable worker records and refreshed snapshots drives
-- the real progression.
--
-- Every stage decision below is 'Kanban.UI.AutoSolve.decideAutoSolve''s. What
-- is under test is the adapter around it — that its observation is rebuilt
-- from durable records rather than from dashboard state, that the turns it
-- starts are the registry's, and that no later provider turn starts before the
-- previous one has settled.
module Spec.Action.AutoSolve (spec) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM)
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Action
import Kanban.Domain
import Kanban.Models (defaultRoster)
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..))
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
  )
import Kanban.UI.AutoSolve
  ( AutoSolveHalt (..),
    AutoSolveObservation (..),
    AutoSolveRevision (..),
    autoSolveRevisionTurn,
  )
import Kanban.UI.Types (AutoSolveProgress (..), AutoSolveStage (..), SolvePhase (..))
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerParent (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerStatus (..),
    WorkerTask (..),
    acknowledgeWorker,
    descriptorForSpec,
    discoverWorkers,
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Data.Time (UTCTime, addUTCTime)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

-- ---------------------------------------------------------------------------
-- The scripted world
-- ---------------------------------------------------------------------------

-- | Which durable worker record a scripted state belongs to.
data Role = Solver | Reviewer | Resumed
  deriving stock (Eq, Show)

-- | One tick's evidence: what the refreshed snapshot holds, and what each
-- worker's durable record says.
data World = World
  { worldPullRequests :: [PullRequest],
    worldWorkers :: [(Role, WorkerState)]
  }

-- | One dispatch the loop made, in the shape the assertions read.
data DispatchRecord = DispatchRecord
  { dispatchedKind :: WorkflowActionKind,
    dispatchedTarget :: ActionTargetRef,
    dispatchedProvenance :: ResumeProvenance,
    dispatchedSession :: Maybe Text,
    dispatchedMessage :: Text,
    dispatchedParentRound :: Maybe Int
  }
  deriving stock (Eq, Show)

data Loop = Loop
  { loopTurns :: AutoSolveTurns,
    loopDriver :: AutoSolveDriver,
    loopDispatches :: IORef [DispatchRecord],
    loopEnvironment :: ActionEnvironment,
    loopStart :: AutoSolveState,
    loopReviewerDescriptor :: WorkerDescriptor,
    -- | An autosolve handle for the initial solver, carrying a cursor wired
    -- to this fixture's turns -- the shape a real dispatch returns.
    loopAutoSolveHandle :: IO ActionHandle,
    -- | Hold every dispatch open for this many microseconds.
    loopSlowDispatch :: Int -> IO (),
    -- | Install one world without going through the driver, for the
    -- single-tick examples.
    loopSetWorld :: World -> IO ()
  }

issueUnderLoop :: Int
issueUnderLoop = 50

pullRequestUnderLoop :: Int
pullRequestUnderLoop = 101

label :: Text -> Label
label name = Label name ""

-- | A pull request linked to the loop's issue, carrying one origin marker as
-- its final content — the shape routing and discovery both need.
linkedPullRequest :: Int -> SolverBrand -> [Label] -> PullRequest
linkedPullRequest number brand labels =
  (basePullRequest number [issueUnderLoop] False labels)
    {pullRequestBody = "Closes #50\n\n" <> marker}
  where
    marker = case brand of
      CodexSolver -> "<!-- pr-origin:codex -->"
      ClaudeSolver -> "<!-- pr-origin:claude -->"

workerRecord :: WorkerStatus -> Maybe Text -> WorkerState
workerRecord status session =
  WorkerState
    { workerStateId = WorkerId "fixture",
      workerStateStatus = status,
      workerStateWorkerPid = 1,
      workerStateWorkerIdentity = Nothing,
      workerStateProviderPid = Nothing,
      workerStateProviderIdentity = Nothing,
      workerStateSessionId = session,
      workerStateLogPath = Nothing,
      workerStateHeartbeatAt = epoch,
      workerStateLastActivity = "working",
      workerStateKnownProcesses = []
    }

running :: WorkerState
running = workerRecord WorkerRunning (Just "session-1")

completed :: WorkerState
completed = workerRecord (WorkerTerminal SolveCompleted) (Just "session-1")

descriptorNamed :: Repository -> Text -> Int -> IO WorkerDescriptor
descriptorNamed repository name issueNumber =
  descriptorCarrying
    repository
    name
    (SolveWorkerTaskKind (SolveWorkerTask issueNumber AutoSolve ClaudeSolver))
    Nothing
    epoch

descriptorCarrying :: Repository -> Text -> WorkerTask -> Maybe WorkerParent -> UTCTime -> IO WorkerDescriptor
descriptorCarrying repository name task parent createdAt =
  descriptorForSpec
    WorkerSpec
      { workerId = WorkerId name,
        workerRepository = repository,
        workerTask = task,
        workerExistingSession = Nothing,
        workerExistingLogPath = Nothing,
        workerResumeProvenance = ResumeAnswer,
        workerUserMessage = "",
        workerParent = parent,
        workerCreatedAt = createdAt,
        workerMaxRuntimeSeconds = 600,
        workerConfigPath = Nothing,
        workerWorkflowConfig = defaultWorkflowConfig,
        workerAssignment = Nothing
      }

-- | Write a worker's durable specification and state, as a launch and its
-- supervisor would.
persistWorker :: WorkerDescriptor -> WorkerState -> IO ()
persistWorker descriptor state = do
  createDirectoryIfMissing True (takeDirectory descriptor.workerDescriptorSpecPath)
  LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)
  LazyByteString.writeFile descriptor.workerDescriptorStatePath (encode state)

-- | The baseline record an autosolve launch writes on the solver it starts:
-- what the board held when the run began, and when that was.
baselineParent :: Set.Set Int -> WorkerParent
baselineParent known =
  (reviewParent 0) {workerParentKnownPullRequests = known, workerParentPullRequest = Nothing}

-- | The parent record a dashboard-launched autosolve writes on the review
-- worker it starts: everything about the /solver/ that launched it.
reviewParent :: Int -> WorkerParent
reviewParent reviewRound =
  WorkerParent
    { workerParentIssueNumber = issueUnderLoop,
      workerParentReviewRound = reviewRound,
      workerParentSolverBrand = ClaudeSolver,
      workerParentSolverSession = Just "session-1",
      workerParentSolverLogPath = Nothing,
      workerParentStartedAt = epoch,
      workerParentKnownPullRequests = Set.fromList [7],
      workerParentPullRequest = Just pullRequestUnderLoop,
      workerParentSolverAssignment = Nothing
    }

-- | A loop wired to a scripted world.
--
-- Worlds are consumed one per refresh and the last one repeats, so a loop that
-- has not settled by the end of the script keeps observing the final state
-- rather than falling off it. Every dispatch is recorded and answered with the
-- next descriptor from a fixed pool, which is what lets the assertions say
-- exactly which provider turns were started and in what order.
withLoop :: [World] -> (Loop -> IO result) -> IO result
withLoop worlds action =
  withTemporaryCacheRoot $ \temporaryRoot ->
    withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
      let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
      solver <- descriptorNamed repository "solve-initial" issueUnderLoop
      reviewer <- descriptorNamed repository "pr-review" pullRequestUnderLoop
      resumed <- descriptorNamed repository "solve-resumed" issueUnderLoop
      remaining <- newIORef worlds
      current <- newIORef (World [] [])
      dispatches <- newIORef []
      dispatchDelay <- newIORef 0
      pool <- newIORef [reviewer, resumed]
      turnsBox <- newIORef Nothing
      let autoSolveHandleWith descriptor = do
            held <- readIORef turnsBox
            case held of
              Nothing -> error "the fixture's turns were not installed"
              Just installed ->
                AutoSolveActionHandle targetUnderLoop descriptor attributionUnderLoop
                  <$> autoSolveCursorFor installed (initialAutoSolveState targetUnderLoop descriptor attributionUnderLoop)
          pathFor Solver = solver.workerDescriptorSpecPath
          pathFor Reviewer = reviewer.workerDescriptorSpecPath
          pathFor Resumed = resumed.workerDescriptorSpecPath
          refresh = do
            next <- atomicModifyIORef' remaining $ \queued -> case queued of
              [] -> ([], Nothing)
              [final] -> ([final], Just final)
              first : rest -> (rest, Just first)
            case next of
              Nothing -> pure (Left "the scripted world ran out")
              Just world -> do
                writeIORef current world
                pure (Right (RepoSnapshot [baseIssue issueUnderLoop []] world.worldPullRequests epoch))
          lookupState descriptor = do
            world <- readIORef current
            pure $ case [recorded | (role, recorded) <- world.worldWorkers, pathFor role == descriptor.workerDescriptorSpecPath] of
              [] -> Left "no durable record"
              recorded : _ -> Right recorded
          dispatch _ request = do
            -- Slow on purpose. Two observations that each decided from the
            -- same state would both be inside here at once, which is the race
            -- the cursor's lock exists to close; without it this window is
            -- what makes the duplicate turn reliable rather than lucky.
            readIORef dispatchDelay >>= threadDelay
            modifyIORef' dispatches (<> [recordOf request])
            handed <- atomicModifyIORef' pool $ \available -> case available of
              [] -> ([], Nothing)
              next : rest -> (rest, Just next)
            case handed of
              Nothing -> pure (Left (ActionDispatchFailed request.requestKind "the fixture ran out of workers"))
              Just descriptor
                | request.requestKind == AutoSolveIssue ->
                    Right <$> autoSolveHandleWith descriptor
                | otherwise ->
                    pure (Right (WorkerActionHandle request.requestKind targetUnderLoop descriptor attributionUnderLoop))
      let installedTurns = AutoSolveTurns dispatch lookupState
      writeIORef turnsBox (Just installedTurns)
      action
        Loop
          { loopTurns = installedTurns,
            loopDriver =
              AutoSolveDriver
                { driverRefresh = refresh,
                  driverHistory = CatalogHistoryLoaded (CompletedHistory [] [] epoch),
                  driverWait = pure (),
                  driverSteps = 12
                },
            loopDispatches = dispatches,
            loopEnvironment = environmentFor repository,
            loopStart =
              AutoSolveState
                { autoSolveActionTarget = targetUnderLoop,
                  autoSolveActionAttribution = attributionUnderLoop,
                  autoSolveActionProgress = progressAt AutoImplementing 0 Nothing,
                  autoSolveActionSolver = AutoSolveSolverWorker solver,
                  autoSolveActionReviewer = Nothing
                },
            loopReviewerDescriptor = reviewer,
            loopAutoSolveHandle = autoSolveHandleWith solver,
            loopSlowDispatch = writeIORef dispatchDelay,
            loopSetWorld = writeIORef current
          }

recordOf :: ActionRequest -> DispatchRecord
recordOf request =
  DispatchRecord
    { dispatchedKind = request.requestKind,
      dispatchedTarget = request.requestTarget,
      dispatchedProvenance = request.requestResumeProvenance,
      dispatchedSession = request.requestExistingSession,
      dispatchedMessage = request.requestUserMessage,
      dispatchedParentRound = (.workerParentReviewRound) <$> request.requestParent
    }

environmentFor :: Repository -> ActionEnvironment
environmentFor repository =
  ActionEnvironment
    { actionRepository = repository,
      actionWorkflowConfig = defaultWorkflowConfig,
      actionConfigPath = Nothing,
      actionRoster = Right defaultRoster,
      actionCatalog =
        TargetCatalog
          { catalogRepository = repository,
            catalogIssues = [baseIssue issueUnderLoop []],
            catalogPullRequests = [],
            catalogHistory = CatalogHistoryLoaded (CompletedHistory [] [] epoch)
          },
      actionNow = epoch
    }

targetUnderLoop :: ResolvedTarget
targetUnderLoop =
  ResolvedTarget
    { resolvedTargetRepository = "coghex/kanban",
      resolvedTargetKind = ActionTargetIssue,
      resolvedTargetNumber = issueUnderLoop,
      resolvedTargetLifecycle = TargetOpen,
      resolvedTargetHistoryReach = HistoryConfirmed,
      resolvedTargetStructure = TargetPlain,
      resolvedTargetItem = IssueItem (baseIssue issueUnderLoop [])
    }

attributionUnderLoop :: ActionAttribution
attributionUnderLoop =
  ActionAttribution
    { attributionKnownPullRequests = Set.empty,
      attributionStartedAt = epoch,
      attributionSolverBrand = ClaudeSolver
    }

progressAt :: AutoSolveStage -> Int -> Maybe Int -> AutoSolveProgress
progressAt stage reviewRound bound =
  AutoSolveProgress
    { autoSolveStage = stage,
      autoSolvePullRequest = bound,
      autoSolveReviewRound = reviewRound,
      autoSolveKnownPullRequests = Set.empty,
      autoSolveStartedAt = epoch
    }

-- | One tick against one hand-placed world, with the loop in a chosen state.
--
-- Returns the tick's answer and every dispatch it made, which together are
-- what each single-stage example is about.
tickWith :: World -> AutoSolveProgress -> Bool -> IO (Either ActionOutcome (), [DispatchRecord])
tickWith world progress bindReviewer =
  withLoop [] $ \loop -> do
    loop.loopSetWorld world
    let state =
          loop.loopStart
            { autoSolveActionProgress = progress,
              autoSolveActionReviewer = if bindReviewer then Just loop.loopReviewerDescriptor else Nothing
            }
        environment =
          loop.loopEnvironment
            { actionCatalog = loop.loopEnvironment.actionCatalog {catalogPullRequests = world.worldPullRequests}
            }
    advanced <- advanceAutoSolveAction loop.loopTurns environment state
    recorded <- readIORef loop.loopDispatches
    pure (either Left (const (Right ())) advanced, recorded)

-- | The tick's terminal answer alone.
outcomeOf :: World -> AutoSolveProgress -> Bool -> IO (Either ActionOutcome ())
outcomeOf world progress bindReviewer = fst <$> tickWith world progress bindReviewer

notSucceeding :: ActionOutcome -> Bool
notSucceeding = not . actionOutcomeSucceeded

-- | The loop's environment with one world's pull requests as its read.
withPullRequests :: Loop -> [PullRequest] -> ActionEnvironment
withPullRequests loop pullRequests =
  loop.loopEnvironment
    {actionCatalog = loop.loopEnvironment.actionCatalog {catalogPullRequests = pullRequests}}

isRunningObservation :: ActionObservation -> Bool
isRunningObservation (ActionRunning _) = True
isRunningObservation (ActionSettled _) = False

isHold :: AutoSolveMove -> Bool
isHold (AutoSolveHold _) = True
isHold _ = False

isHoldWithActivity :: AutoSolveMove -> Bool
isHoldWithActivity (AutoSolveHold (Just _)) = True
isHoldWithActivity _ = False

stoppedFor :: Text -> Either ActionOutcome () -> Bool
stoppedFor fragment = either (Text.isInfixOf fragment . actionOutcomeMessage) (const False)

spec :: Spec
spec = do
  describe "the headless autosolve loop" $ do
    -- The whole arc, with both providers driven in sequence and nothing but
    -- durable records and refreshed snapshots to drive it.
    it "runs solver, opposite-brand review, resumed solver, and rereview to approval" $
      withLoop wholeArc $ \loop -> do
        outcome <- runAutoSolveActionWith loop.loopTurns loop.loopEnvironment loop.loopDriver loop.loopStart
        outcome `shouldBe` ActionPullRequestApproved pullRequestUnderLoop
        actionOutcomeSucceeded outcome `shouldBe` True
        recorded <- readIORef loop.loopDispatches
        -- Exactly two provider turns, in order and never overlapping: the
        -- review only after the solver settled, the revision only after the
        -- review settled.
        map (.dispatchedKind) recorded `shouldBe` [ReviewPullRequest, AutoSolveIssue]
        map (.dispatchedTarget) recorded
          `shouldBe` [ TargetByKind ActionTargetPullRequest pullRequestUnderLoop,
                       TargetByKind ActionTargetIssue issueUnderLoop
                     ]
        map (.dispatchedParentRound) recorded `shouldBe` [Just 1, Just 1]
        case recorded of
          [_, revision] -> do
            revision.dispatchedProvenance `shouldBe` ResumeAutomatedChangesRequested
            revision.dispatchedSession `shouldBe` Just "session-1"
            revision.dispatchedMessage `shouldSatisfy` Text.isInfixOf "pr-revise"
            revision.dispatchedMessage `shouldSatisfy` Text.isInfixOf "CHANGES_REQUESTED"
          _ -> error "expected exactly two dispatches"

    -- Requirement 12's sequential guarantee, from both sides.
    it "starts no second review while the first one is still running" $ do
      let world = World [linkedPullRequest pullRequestUnderLoop ClaudeSolver []] [(Solver, completed), (Reviewer, running)]
      (first, firstDispatches) <- tickWith world (progressAt AutoReviewing 1 (Just pullRequestUnderLoop)) True
      first `shouldBe` Right ()
      firstDispatches `shouldBe` []

    it "holds a revision back while the solver it would resume is still live" $ do
      let world =
            World
              [linkedPullRequest pullRequestUnderLoop ClaudeSolver [label defaultWorkflowConfig.changesRequestedLabel]]
              [(Solver, running), (Reviewer, completed)]
      (advanced, recorded) <- tickWith world (progressAt AutoReviewing 1 (Just pullRequestUnderLoop)) True
      advanced `shouldBe` Right ()
      recorded `shouldBe` []

    it "starts the review round the discovery bound, and only that one" $ do
      let world = World [linkedPullRequest pullRequestUnderLoop ClaudeSolver []] [(Solver, completed)]
      (advanced, recorded) <- tickWith world (progressAt AutoDiscoveringPullRequest 0 Nothing) False
      advanced `shouldBe` Right ()
      map (.dispatchedKind) recorded `shouldBe` [ReviewPullRequest]

  describe "what the loop refuses to call success" $ do
    let discovering = progressAt AutoDiscoveringPullRequest 0 Nothing
        discoveryWorld pullRequests = World pullRequests [(Solver, completed)]

    it "stops rather than binding a pull request it cannot attribute" $ do
      let mine = linkedPullRequest pullRequestUnderLoop ClaudeSolver []
          second = linkedPullRequest 102 ClaudeSolver []
          theirs = linkedPullRequest 103 CodexSolver []
      -- Two candidates, and a candidate the other brand opened: neither is an
      -- answer, and neither becomes one by being the only thing on the board.
      outcomeOf (discoveryWorld [mine, second]) discovering False
        >>= (`shouldSatisfy` stoppedFor "multiple new linked PRs")
      outcomeOf (discoveryWorld [theirs]) discovering False
        >>= (`shouldSatisfy` stoppedFor "wrong origin marker")
      -- None yet is not a failure; the loop waits.
      outcomeOf (discoveryWorld []) discovering False >>= (`shouldBe` Right ())

    it "stops at the five-round bound rather than revising a sixth time" $
      outcomeOf
        (World [changesRequestedPullRequest] [(Solver, completed), (Reviewer, completed)])
        (progressAt AutoReviewing 5 (Just pullRequestUnderLoop))
        True
        >>= (`shouldSatisfy` stoppedFor "5 review rounds")

    it "stops when the original solver returned no resumable session" $
      outcomeOf
        (World [changesRequestedPullRequest] [(Solver, workerRecord (WorkerTerminal SolveCompleted) Nothing), (Reviewer, completed)])
        (progressAt AutoReviewing 1 (Just pullRequestUnderLoop))
        True
        >>= (`shouldSatisfy` stoppedFor "resumable session")

    it "reports a solver that asked a question and one that failed as themselves" $ do
      outcomeOf (World [] [(Solver, workerRecord (WorkerTerminal (SolveNeedsInput "which base?")) Nothing)]) (progressAt AutoImplementing 0 Nothing) False
        >>= (`shouldBe` Left (ActionNeedsInput "which base?"))
      outcomeOf (World [] [(Solver, workerRecord (WorkerTerminal (SolveFailed "boom")) Nothing)]) (progressAt AutoImplementing 0 Nothing) False
        >>= (`shouldBe` Left (ActionFailed "boom"))

    -- The canonical coordinator switches exactly one label, so a pull request
    -- carrying both has had two contradictory verdicts published on it and
    -- nothing about it is settled. Completing the run on the approval would
    -- be reading a broken review state as a good one.
    it "stops on a pull request carrying two contradictory verdicts" $ do
      let contradictory =
            linkedPullRequest
              pullRequestUnderLoop
              ClaudeSolver
              [label defaultWorkflowConfig.approvalLabel, label defaultWorkflowConfig.changesRequestedLabel]
      -- After the review round...
      outcomeOf
        (World [contradictory] [(Solver, completed), (Reviewer, completed)])
        (progressAt AutoReviewing 1 (Just pullRequestUnderLoop))
        True
        >>= (`shouldSatisfy` stoppedFor "contradictory")
      -- ...and after the revision's canonical rereview.
      outcomeOf
        (World [contradictory] [(Resumed, completed)])
        (progressAt AutoAwaitingRereview 1 (Just pullRequestUnderLoop))
        False
        >>= (`shouldSatisfy` stoppedFor "contradictory")

    it "reports a failed review as a failure rather than as a verdict" $
      outcomeOf
        (World [changesRequestedPullRequest] [(Solver, completed), (Reviewer, workerRecord (WorkerTerminal (SolveFailed "review died")) Nothing)])
        (progressAt AutoReviewing 1 (Just pullRequestUnderLoop))
        True
        >>= (`shouldSatisfy` stoppedFor "review failed")

    it "stops when the bound pull request leaves the read" $
      outcomeOf
        (World [] [(Solver, completed), (Reviewer, running)])
        (progressAt AutoReviewing 1 (Just pullRequestUnderLoop))
        True
        >>= (`shouldSatisfy` stoppedFor "disappeared")

    it "waits, rather than concluding, while the rereview verdict is still pending" $
      outcomeOf
        (World [linkedPullRequest pullRequestUnderLoop ClaudeSolver []] [(Resumed, completed)])
        (progressAt AutoAwaitingRereview 1 (Just pullRequestUnderLoop))
        False
        >>= (`shouldBe` Right ())

    it "completes on the approval the canonical rereview published" $
      outcomeOf
        (World [linkedPullRequest pullRequestUnderLoop ClaudeSolver [label defaultWorkflowConfig.approvalLabel]] [(Resumed, completed)])
        (progressAt AutoAwaitingRereview 1 (Just pullRequestUnderLoop))
        False
        >>= (`shouldBe` Left (ActionPullRequestApproved pullRequestUnderLoop))

  -- The rule that keeps one advancer per action, stated where both surfaces
  -- read it: a dashboard refresh and a headless tick run the same decision,
  -- and the decision itself is what refuses to start a turn beside a live
  -- one. Repeated observations of an unchanged world therefore start nothing.
  describe "one turn at a time, however often it is observed" $ do
    it "starts no second review across repeated refreshes of the same world" $ do
      let world = World [linkedPullRequest pullRequestUnderLoop ClaudeSolver []] [(Solver, completed), (Reviewer, running)]
          reviewing = progressAt AutoReviewing 1 (Just pullRequestUnderLoop)
      results <- mapM (const (tickWith world reviewing True)) [1 :: Int .. 3]
      map fst results `shouldBe` replicate 3 (Right ())
      concatMap snd results `shouldBe` []

    it "starts no second solver turn across repeated refreshes of the same world" $ do
      let world = World [changesRequestedPullRequest] [(Solver, running), (Reviewer, completed)]
          reviewing = progressAt AutoReviewing 1 (Just pullRequestUnderLoop)
      results <- mapM (const (tickWith world reviewing True)) [1 :: Int .. 3]
      map fst results `shouldBe` replicate 3 (Right ())
      concatMap snd results `shouldBe` []

    -- The reviewer that stopped to ask. The dashboard reports it and waits,
    -- because someone is there to answer; headlessly nobody is, so waiting
    -- would spend the budget and end as a budget stop that says nothing.
    it "ends the action with the reviewer's own question rather than a budget stop" $ do
      let asking = workerRecord (WorkerTerminal (SolveNeedsInput "which base branch?")) Nothing
          world = World [linkedPullRequest pullRequestUnderLoop ClaudeSolver []] [(Solver, completed), (Reviewer, asking)]
      outcomeOf world (progressAt AutoReviewing 1 (Just pullRequestUnderLoop)) True
        >>= (`shouldBe` Left (ActionNeedsInput "which base branch?"))
      settledReviewTurn (Just (WorkerTerminal (SolveNeedsInput "?")))
        `shouldBe` Just (ActionNeedsInput "?")
      settledReviewTurn (Just (WorkerTerminal SolveCompleted)) `shouldBe` Nothing
      settledReviewTurn (Just WorkerRunning) `shouldBe` Nothing
      settledReviewTurn Nothing `shouldBe` Nothing

    it "runs the loop to its budget only when nothing has settled" $
      withLoop [World [] [(Solver, running)]] $ \loop -> do
        outcome <-
          runAutoSolveActionWith
            loop.loopTurns
            loop.loopEnvironment
            loop.loopDriver {driverSteps = 3}
            loop.loopStart
        outcome `shouldSatisfy` notSucceeding
        readIORef loop.loopDispatches >>= (`shouldBe` [])

  -- Requirement 12's "the same action, not two": a runner takes over what a
  -- dashboard press launched by reading the records that press left behind.
  describe "taking over an action the dashboard launched" $ do
    it "rebuilds the loop's state from the durable records alone" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
          solver <-
            descriptorCarrying
              repository
              "solve-initial"
              (SolveWorkerTaskKind (SolveWorkerTask issueUnderLoop AutoSolve ClaudeSolver))
              Nothing
              epoch
          reviewer <-
            descriptorCarrying
              repository
              "pr-review"
              (PullRequestWorkerTaskKind (PullRequestWorkerTask pullRequestUnderLoop PullRequestClaude PullRequestReview))
              (Just (reviewParent 1))
              (addUTCTime 60 epoch)
          case autoSolveStateFromWorkers targetUnderLoop (Set.fromList [9]) [solver, reviewer] of
            Nothing -> error "expected the durable records to rebuild an action"
            Just recovered -> do
              -- The review worker is the round in flight, and the parent
              -- record it carries is where the round, the run's start, and
              -- the pull requests discovery must not bind come from.
              recovered.autoSolveActionProgress.autoSolveStage `shouldBe` AutoReviewing
              recovered.autoSolveActionProgress.autoSolvePullRequest `shouldBe` Just pullRequestUnderLoop
              recovered.autoSolveActionProgress.autoSolveReviewRound `shouldBe` 1
              recovered.autoSolveActionProgress.autoSolveKnownPullRequests `shouldBe` Set.fromList [7]
              recovered.autoSolveActionAttribution.attributionSolverBrand `shouldBe` ClaudeSolver
              (.workerDescriptorSpecPath) <$> recovered.autoSolveActionReviewer
                `shouldBe` Just reviewer.workerDescriptorSpecPath
              ((.workerDescriptorSpecPath) <$> autoSolveSolverWorker recovered.autoSolveActionSolver)
                `shouldBe` Just solver.workerDescriptorSpecPath

    -- The pull request the run is looping over is not history when a revision
    -- starts: dropping it left the rereview arm with nothing bound, and it
    -- halts on that, so a run whose pull request was approved would stop.
    it "keeps the bound pull request through a recovered revision, to its approval" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
          reviewer <-
            descriptorCarrying
              repository
              "pr-review"
              (PullRequestWorkerTaskKind (PullRequestWorkerTask pullRequestUnderLoop PullRequestClaude PullRequestReview))
              (Just (reviewParent 1))
              (addUTCTime 60 epoch)
          resumed <-
            descriptorCarrying
              repository
              "solve-resumed"
              (SolveWorkerTaskKind (SolveWorkerTask issueUnderLoop AutoSolve ClaudeSolver))
              Nothing
              (addUTCTime 120 epoch)
          case autoSolveStateFromWorkers targetUnderLoop Set.empty [reviewer, resumed] of
            Nothing -> error "expected the durable records to rebuild an action"
            Just recovered -> do
              recovered.autoSolveActionProgress.autoSolvePullRequest
                `shouldBe` Just pullRequestUnderLoop
              -- ...and that recovered action reaches its approval: the
              -- revision settles, the loop moves to the rereview, and the
              -- verdict standing on the pull request completes it.
              let approvedPullRequest =
                    linkedPullRequest pullRequestUnderLoop ClaudeSolver [label defaultWorkflowConfig.approvalLabel]
              withLoop [] $ \loop -> do
                -- The recovered action's solver, standing in as this
                -- fixture's, has settled: the revision is done and the
                -- canonical rereview it invoked has published its verdict.
                loop.loopSetWorld (World [approvedPullRequest] [(Solver, completed)])
                advanced <-
                  advanceAutoSolveAction
                    loop.loopTurns
                    (withPullRequests loop [approvedPullRequest])
                    recovered {autoSolveActionSolver = loop.loopStart.autoSolveActionSolver}
                either Just (const Nothing) advanced
                  `shouldBe` Just (ActionPullRequestApproved pullRequestUnderLoop)

    -- The interval after the opening solve finished and before any review
    -- worker exists: the only record of what the board held when the run
    -- started is the solver's own, and without it the pull request the run
    -- just opened is already in the baseline and never binds.
    it "recovers the run's baseline from the solver's own record, before any reviewer exists" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              opened = linkedPullRequest pullRequestUnderLoop ClaudeSolver []
          solver <-
            descriptorCarrying
              repository
              "solve-initial"
              (SolveWorkerTaskKind (SolveWorkerTask issueUnderLoop AutoSolve ClaudeSolver))
              (Just (baselineParent Set.empty))
              epoch
          case autoSolveStateFromWorkers targetUnderLoop (Set.fromList [pullRequestUnderLoop]) [solver] of
            Nothing -> error "expected the durable records to rebuild an action"
            Just recovered -> do
              -- The board now holds the pull request the run opened; the
              -- baseline must not.
              recovered.autoSolveActionProgress.autoSolveKnownPullRequests `shouldBe` Set.empty
              recovered.autoSolveActionAttribution.attributionKnownPullRequests `shouldBe` Set.empty
              recovered.autoSolveActionProgress.autoSolveStage `shouldBe` AutoImplementing
              -- ...so the finished solver's pull request binds and its review
              -- round starts, rather than the loop waiting for one that has
              -- already arrived.
              withLoop [] $ \loop -> do
                loop.loopSetWorld (World [opened] [(Solver, completed)])
                advanced <-
                  advanceAutoSolveAction
                    loop.loopTurns
                    (withPullRequests loop [opened])
                    recovered {autoSolveActionSolver = loop.loopStart.autoSolveActionSolver}
                either (const Nothing) (Just . (.autoSolveActionProgress.autoSolvePullRequest)) advanced
                  `shouldBe` Just (Just pullRequestUnderLoop)
                map (.dispatchedKind) <$> readIORef loop.loopDispatches
                  >>= (`shouldBe` [ReviewPullRequest])

    it "reads a solver newer than its review as the revision the loop moved on to" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
          reviewer <-
            descriptorCarrying
              repository
              "pr-review"
              (PullRequestWorkerTaskKind (PullRequestWorkerTask pullRequestUnderLoop PullRequestClaude PullRequestReview))
              (Just (reviewParent 1))
              (addUTCTime 60 epoch)
          resumed <-
            descriptorCarrying
              repository
              "solve-resumed"
              (SolveWorkerTaskKind (SolveWorkerTask issueUnderLoop AutoSolve ClaudeSolver))
              Nothing
              (addUTCTime 120 epoch)
          case autoSolveStateFromWorkers targetUnderLoop Set.empty [reviewer, resumed] of
            Nothing -> error "expected the durable records to rebuild an action"
            Just recovered -> do
              recovered.autoSolveActionProgress.autoSolveStage `shouldBe` AutoRevising
              recovered.autoSolveActionReviewer `shouldBe` Nothing
              recovered.autoSolveActionProgress.autoSolvePullRequest
                `shouldBe` Just pullRequestUnderLoop
              ((.workerDescriptorSpecPath) <$> autoSolveSolverWorker recovered.autoSolveActionSolver)
                `shouldBe` Just resumed.workerDescriptorSpecPath

    -- The ordinary shape of a dashboard-launched run once its review round
    -- has started: starting that round acknowledges the finished solver, and
    -- the cache collects an acknowledged worker a newer one supersedes, so
    -- `discoverWorkers` no longer offers it at all. A recovery that needed
    -- that descriptor could take over almost no real run.
    it "takes over a run whose finished solver has been acknowledged and collected" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              approvedPullRequest =
                linkedPullRequest pullRequestUnderLoop ClaudeSolver [label defaultWorkflowConfig.approvalLabel]
          solver <-
            descriptorCarrying
              repository
              "solve-initial"
              (SolveWorkerTaskKind (SolveWorkerTask issueUnderLoop AutoSolve ClaudeSolver))
              (Just (baselineParent Set.empty))
              epoch
          reviewer <-
            descriptorCarrying
              repository
              "pr-review"
              (PullRequestWorkerTaskKind (PullRequestWorkerTask pullRequestUnderLoop PullRequestClaude PullRequestReview))
              (Just (reviewParent 1))
              (addUTCTime 60 epoch)
          persistWorker solver (workerRecord (WorkerTerminal SolveCompleted) (Just "session-1"))
          acknowledgeWorker solver
          persistWorker reviewer (workerRecord WorkerRunning Nothing)
          -- The control: discovery really does drop the solver, so the
          -- recovery below is answering the case this is about.
          discovered <- discoverWorkers repository
          map (.workerDescriptorSpecPath) discovered `shouldBe` [reviewer.workerDescriptorSpecPath]
          recovered <- recoverAutoSolveState repository targetUnderLoop (Set.fromList [pullRequestUnderLoop])
          case recovered of
            Nothing -> error "expected the review worker's parent to rebuild the action"
            Just held -> do
              held.autoSolveActionProgress.autoSolveStage `shouldBe` AutoReviewing
              held.autoSolveActionProgress.autoSolvePullRequest `shouldBe` Just pullRequestUnderLoop
              held.autoSolveActionProgress.autoSolveReviewRound `shouldBe` 1
              -- The baseline is the run's, taken from the review worker's
              -- parent record, and not the board's: the board holds the pull
              -- request this run opened and the baseline must not.
              held.autoSolveActionProgress.autoSolveKnownPullRequests `shouldBe` Set.fromList [7]
              held.autoSolveActionAttribution.attributionSolverBrand `shouldBe` ClaudeSolver
              -- The solver is nameable and resumable from the parent alone.
              autoSolveSolverWorker held.autoSolveActionSolver `shouldBe` Nothing
              case held.autoSolveActionSolver of
                AutoSolveSolverRecorded record ->
                  record.recordedSolverSession `shouldBe` Just "session-1"
                other -> error ("expected a recorded solver, saw " <> show other)
              ((.workerDescriptorSpecPath) <$> held.autoSolveActionReviewer)
                `shouldBe` Just reviewer.workerDescriptorSpecPath
              -- ...and it runs: the review settles and the verdict standing on
              -- the pull request completes the action, with no solver worker
              -- anywhere.
              let turns =
                    AutoSolveTurns
                      (\_ request -> pure (Left (ActionDispatchFailed request.requestKind "no turn should start")))
                      ( \descriptor ->
                          pure
                            ( if descriptor.workerDescriptorSpecPath == reviewer.workerDescriptorSpecPath
                                then Right (workerRecord (WorkerTerminal SolveCompleted) Nothing)
                                else Left "the solver's artifacts were collected"
                            )
                      )
                  environment =
                    (environmentFor repository)
                      { actionCatalog =
                          (environmentFor repository).actionCatalog {catalogPullRequests = [approvedPullRequest]}
                      }
              advanced <- advanceAutoSolveAction turns environment held
              either Just (const Nothing) advanced
                `shouldBe` Just (ActionPullRequestApproved pullRequestUnderLoop)

    it "takes over nothing when no autosolve solver worker is discoverable" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
          solveOnly <-
            descriptorCarrying
              repository
              "solve-only"
              (SolveWorkerTaskKind (SolveWorkerTask issueUnderLoop SolveOnly ClaudeSolver))
              Nothing
              epoch
          maybe True (const False) (autoSolveStateFromWorkers targetUnderLoop Set.empty [solveOnly])
            `shouldBe` True

  -- The revision turn has one declaration, which both surfaces start.
  describe "the resumed-solver turn" $ do
    it "carries the provenance and prompt an automated revision resumes under" $ do
      let repository = Repository "/tmp/kanban" "coghex" "kanban"
      case autoSolveRevisionTurn defaultWorkflowConfig Nothing repository ClaudeSolver (Just "session-1") pullRequestUnderLoop 2 of
        Nothing -> error "expected a revision turn"
        Just turn -> do
          turn.autoSolveRevisionSession `shouldBe` "session-1"
          turn.autoSolveRevisionProvenance `shouldBe` ResumeAutomatedChangesRequested
          turn.autoSolveRevisionMessage `shouldSatisfy` Text.isInfixOf "review round 2"
          turn.autoSolveRevisionMessage `shouldSatisfy` Text.isInfixOf "pr-revise"

    it "starts nothing when the solver returned no resumable session" $
      autoSolveRevisionTurn defaultWorkflowConfig Nothing (Repository "/tmp/kanban" "coghex" "kanban") ClaudeSolver Nothing pullRequestUnderLoop 1
        `shouldBe` Nothing

  -- Requirement 12's dispatch-to-approval path. Observing the action is what
  -- advances it, so the ordinary handle-then-observe shape reaches the
  -- approval rather than stalling on whichever turn is in flight.
  describe "observing a dispatched action to its approval" $ do
    -- The handle a dispatch returns is the progressing thing: observing it is
    -- what advances the loop, so the ordinary dispatch-then-observe path
    -- reaches the approval rather than reporting the turn in flight forever.
    it "advances the loop a tick per observation of the handle, settling on the approval" $
      withLoop [] $ \loop -> do
        handle <- loop.loopAutoSolveHandle
        observations <- forM wholeArc $ \world -> do
          loop.loopSetWorld world
          observeAction (withPullRequests loop world.worldPullRequests) handle
        last observations `shouldBe` ActionSettled (ActionPullRequestApproved pullRequestUnderLoop)
        -- ...and nothing before it claimed a result. A handle that reported
        -- the opening solve's pull request would settle here instead.
        all isRunningObservation (init observations) `shouldBe` True
        map (.dispatchedKind) <$> readIORef loop.loopDispatches
          >>= (`shouldBe` [ReviewPullRequest, AutoSolveIssue])

    -- Requirement 12's sequential guarantee, against the one thing that can
    -- break it now that observing advances the loop: two observations of the
    -- same handle at once. Each would decide from the same freshly finished
    -- solve, bind the pull request it opened, and start a review for it.
    it "starts one review round when two observations of one handle race" $
      withLoop [] $ \loop -> do
        handle <- loop.loopAutoSolveHandle
        let opened = linkedPullRequest pullRequestUnderLoop ClaudeSolver []
        loop.loopSetWorld (World [opened] [(Solver, completed)])
        loop.loopSlowDispatch 100000
        first <- newEmptyMVar
        second <- newEmptyMVar
        mapM_
          (\done -> forkIO (observeAction (withPullRequests loop [opened]) handle >>= putMVar done))
          [first, second]
        observations <- mapM takeMVar [first, second]
        all isRunningObservation observations `shouldBe` True
        -- One review round, not two. The second observation decided from the
        -- first one's result rather than from the state it started with.
        map (.dispatchedKind) <$> readIORef loop.loopDispatches
          >>= (`shouldBe` [ReviewPullRequest])

    it "names the loop's own place while it runs" $
      withLoop [] $ \loop -> do
        handle <- loop.loopAutoSolveHandle
        loop.loopSetWorld (World [] [(Solver, running)])
        observed <- observeAction (withPullRequests loop []) handle
        observed `shouldBe` ActionRunning "implementing"
        actionHandleKind handle `shouldBe` AutoSolveIssue

  -- An unreadable review record is not "no review". Reading it as one is how
  -- a second reviewer would be launched beside the first.
  describe "a reviewer whose record cannot be read" $ do
    it "waits rather than starting a second review round" $ do
      let world = World [linkedPullRequest pullRequestUnderLoop ClaudeSolver []] [(Solver, completed)]
      (advanced, recorded) <- tickWith world (progressAt AutoReviewing 1 (Just pullRequestUnderLoop)) True
      advanced `shouldBe` Right ()
      recorded `shouldBe` []

    it "reports an unreadable record as a starting review, not as an absent one" $ do
      reviewPhaseForRecord (Left "no durable record") `shouldBe` SolveStarting
      reviewPhaseForRecord (Right running) `shouldBe` SolveRunning
      reviewPhaseForRecord (Right completed) `shouldBe` SolveFinished

  -- The one reading of a decision both surfaces take their move from.
  describe "the shared tick" $ do
    it "carries the activity a surface shows while the loop holds" $
      (tickOf (observing []) (progressAt AutoDiscoveringPullRequest 0 Nothing)).tickMove
        `shouldSatisfy` isHoldWithActivity

    it "announces only the observation that bound the pull request" $ do
      let bound = linkedPullRequest pullRequestUnderLoop ClaudeSolver []
          discovery = tickOf (observing [bound]) (progressAt AutoDiscoveringPullRequest 0 Nothing)
          alreadyBound = tickOf (observing [bound]) (progressAt AutoReviewing 1 (Just pullRequestUnderLoop))
      discovery.tickMove `shouldBe` AutoSolveReviewRound pullRequestUnderLoop True
      discovery.tickProgress.autoSolveReviewRound `shouldBe` 1
      discovery.tickProgress.autoSolvePullRequest `shouldBe` Just pullRequestUnderLoop
      alreadyBound.tickMove `shouldBe` AutoSolveReviewRound pullRequestUnderLoop False

    it "carries the whole revision turn on the arm that asks for one" $ do
      let observation =
            (observing [changesRequestedPullRequest]) {autoSolveReviewPhase = Just SolveFinished}
          tick = tickOf observation (progressAt AutoReviewing 1 (Just pullRequestUnderLoop))
      case tick.tickMove of
        AutoSolveRevisionRound number turn -> do
          number `shouldBe` pullRequestUnderLoop
          turn.autoSolveRevisionSession `shouldBe` "session-1"
          turn.autoSolveRevisionProvenance `shouldBe` ResumeAutomatedChangesRequested
          turn.autoSolveRevisionMessage `shouldSatisfy` Text.isInfixOf "pr-revise"
        other -> error ("expected a revision round, saw " <> show other)
      tick.tickProgress.autoSolveStage `shouldBe` AutoRevising

    it "advances the progress each conclusion retires the loop with" $ do
      let approvedPullRequest = linkedPullRequest pullRequestUnderLoop ClaudeSolver [label defaultWorkflowConfig.approvalLabel]
          approved =
            tickOf
              ((observing [approvedPullRequest]) {autoSolveReviewPhase = Just SolveFinished})
              (progressAt AutoReviewing 1 (Just pullRequestUnderLoop))
          bounded =
            tickOf
              ((observing [changesRequestedPullRequest]) {autoSolveReviewPhase = Just SolveFinished})
              (progressAt AutoReviewing 5 (Just pullRequestUnderLoop))
      approved.tickMove `shouldBe` AutoSolveConcluded (AutoSolveConcludedApproved pullRequestUnderLoop)
      approved.tickProgress.autoSolveStage `shouldBe` AutoSolveComplete
      autoSolveConclusionOutcome (AutoSolveConcludedApproved pullRequestUnderLoop)
        `shouldBe` ActionPullRequestApproved pullRequestUnderLoop
      bounded.tickProgress.autoSolveStage `shouldBe` AutoSolveStopped
      case bounded.tickMove of
        AutoSolveConcluded (AutoSolveConcludedHalted halt reason) -> do
          halt `shouldBe` AutoSolveHaltStopped
          reason `shouldSatisfy` Text.isInfixOf "5 review rounds"
        other -> error ("expected a halt, saw " <> show other)

    -- The regression the exactly-one-advancer rule needs on the dashboard's
    -- side: a refresh arriving while a turn is live starts nothing, however
    -- many refreshes arrive.
    it "starts nothing on a refresh that arrives while a turn is live" $ do
      let bound = linkedPullRequest pullRequestUnderLoop ClaudeSolver []
          reviewing = progressAt AutoReviewing 1 (Just pullRequestUnderLoop)
          duringReview = (observing [bound]) {autoSolveReviewPhase = Just SolveRunning}
          duringRevision =
            (observing [changesRequestedPullRequest])
              { autoSolveReviewPhase = Just SolveFinished,
                autoSolveSolverRunning = True
              }
      map (\observation -> (tickOf observation reviewing).tickMove) [duringReview, duringRevision, duringReview]
        `shouldSatisfy` all isHold

  describe "reading a worker's durable record" $ do
    it "maps every recorded status onto the phase the loop decides from" $
      map
        reviewPhaseForWorker
        [ WorkerStarting,
          WorkerRunning,
          WorkerOrphaned SolveCompleted,
          WorkerTerminal SolveCompleted,
          WorkerTerminal (SolveNeedsInput "?"),
          WorkerTerminal (SolveFailed "!")
        ]
        `shouldBe` [SolveStarting, SolveRunning, SolveOrphanedPhase, SolveFinished, SolveAttention, SolveFailedPhase]

    -- Fails closed on both edges: an unreadable record and an orphaned worker
    -- both count as live, because launching a second provider turn beside a
    -- running one is the mistake that matters.
    it "counts an unreadable record and an orphaned worker as live" $ do
      workerStatusIsLive (Left "unreadable") `shouldBe` True
      workerStatusIsLive (Right (workerRecord (WorkerOrphaned SolveCompleted) Nothing)) `shouldBe` True
      workerStatusIsLive (Right running) `shouldBe` True
      workerStatusIsLive (Right completed) `shouldBe` False

-- | The six observations one complete run makes, from a solver still working
-- to the approval its canonical rereview published.
wholeArc :: [World]
wholeArc =
  [ -- The solver is still working.
    World [] [(Solver, running)],
    -- It finished, and the pull request it opened is on the board.
    World [mine []] [(Solver, completed)],
    -- The review round is under way.
    World [mine []] [(Solver, completed), (Reviewer, running)],
    -- The review published CHANGES_REQUESTED.
    World [mine [label defaultWorkflowConfig.changesRequestedLabel]] [(Solver, completed), (Reviewer, completed)],
    -- The resumed solver is revising.
    World [mine [label defaultWorkflowConfig.changesRequestedLabel]] [(Resumed, running)],
    -- The revision finished and its canonical rereview approved.
    World [mine [label defaultWorkflowConfig.approvalLabel]] [(Resumed, completed)]
  ]
  where
    mine = linkedPullRequest pullRequestUnderLoop ClaudeSolver

-- | An observation with nothing happening, refined per example.
observing :: [PullRequest] -> AutoSolveObservation
observing pullRequests =
  AutoSolveObservation
    { autoSolveIssueNumber = issueUnderLoop,
      autoSolveWorkflowConfig = defaultWorkflowConfig,
      autoSolveSolverBrand = ClaudeSolver,
      autoSolveSolverSession = Just "session-1",
      autoSolveSolverRunning = False,
      autoSolveSnapshotPullRequests = pullRequests,
      autoSolveReviewPhase = Nothing
    }

tickOf :: AutoSolveObservation -> AutoSolveProgress -> AutoSolveTick
tickOf =
  autoSolveTick defaultWorkflowConfig Nothing (Repository "/tmp/kanban" "coghex" "kanban")

changesRequestedPullRequest :: PullRequest
changesRequestedPullRequest =
  linkedPullRequest pullRequestUnderLoop ClaudeSolver [label defaultWorkflowConfig.changesRequestedLabel]
