-- | The workflow action registry: what it declares, what it refuses, where it
-- routes, and what it will and will not call success.
--
-- Almost all of it is pure and needs no process at all. The three groups that
-- are not — dispatch, the not-yet-runner-owned refusal, and the approval-queue
-- observation — use the suite's established fixtures: fake provider
-- executables on a temporary @PATH@, a temporary cache root, and the
-- specification a launch writes as the evidence that the launch reached its
-- authority with the request's own values.
module Spec.Action.Registry (spec) where

import Control.Monad (void)
import Data.Aeson (eitherDecodeFileStrict, encode)
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (isSuffixOf, sortOn)
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (addUTCTime, getCurrentTime)
import Kanban.Action
import Kanban.ApprovalService (ApprovalActivity (..), ApprovalState (..), ApprovalStatus (..), ApprovalUnavailable (..))
import Kanban.Domain
import Kanban.Models (RecordedAssignment (..), defaultRoster)
import Kanban.Preflight
  ( IssueOrigin (..),
    PreflightAction (..),
    PreflightEnvironment,
    ProviderProbe (..),
    actionReport,
    blockingRemediation,
    preflightDiagnostic,
  )
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestOrigin (..),
    PullRequestVerdict (..),
    agentForAction,
    directPullRequestAction,
    labelPullRequestAction,
    pullRequestAssignment,
  )
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveOutcome (..),
    SolveWorkflow (..),
    SolverBrand (..),
    brandForProvider,
    solveAssignment,
  )
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
    acquireWorkerLease,
    descriptorForSpec,
    discoverWorkers,
    workerDirectory,
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import qualified Data.Map.Strict as Map
import Spec.Support.App (testAppState, testPullRequestSession, testSolveSession, withSolveSession)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch, fixtureBoard)
import Spec.Support.Preflight
  ( BackendFixture (..),
    fullyProvisionedFakes,
    probeInvocations,
    readyPreflightEnvironment,
    readyProviderProbe,
    withCodexProbe,
    withPreflightMachine,
  )
import Kanban.UI.PullRequest (pullRequestLaunchPlan)
import Kanban.UI.Solve (solveActionKind, solveLaunchPlan)
import Kanban.UI.Types
  ( AgentSession (..),
    AppState (..),
    AutoSolveProgress (..),
    AutoSolveStage (..),
    PullRequestDetail (..),
    SolveDetail (..),
    SolvePhase (..),
  )
import Spec.Support.Roster (cellOf)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory)
import System.FilePath (takeDirectory, (</>))
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe, shouldReturn, shouldSatisfy)

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

repositoryUnderTest :: Repository
repositoryUnderTest = Repository "/tmp/kanban-registry-fixture" "Coghex" "Kanban"

identityUnderTest :: Text
identityUnderTest = "coghex/kanban"

label :: Text -> Label
label name = Label name ""

originMarker :: SolverBrand -> Text
originMarker CodexSolver = "<!-- pr-origin:codex -->"
originMarker ClaudeSolver = "<!-- pr-origin:claude -->"

-- | A pull request whose body carries exactly one origin marker as its final
-- content, which is the shape routing needs.
markedPullRequest :: Int -> [Int] -> SolverBrand -> [Label] -> PullRequest
markedPullRequest number linked brand labels =
  (basePullRequest number linked False labels) {pullRequestBody = "Closes #7\n\n" <> originMarker brand}

-- | A tracker in the shape the checklist parser reads: the configured tracker
-- label, a recognized children section, and one row per child.
epicIssue :: Int -> [Int] -> Issue
epicIssue number children =
  (baseIssue number [])
    { issueLabels = [label "epic"],
      issueBody =
        Text.unlines
          ("## Children" : ["- [ ] #" <> Text.pack (show child) <> " \8212 A" <> Text.pack (show child) <> ": Child" | child <- children])
    }

catalogOf :: [Issue] -> [PullRequest] -> CatalogHistory -> TargetCatalog
catalogOf issues pullRequests history =
  TargetCatalog
    { catalogRepository = repositoryUnderTest,
      catalogIssues = issues,
      catalogPullRequests = pullRequests,
      catalogHistory = history
    }

emptyHistory :: CatalogHistory
emptyHistory = CatalogHistoryLoaded (CompletedHistory [] [] epoch)

environmentOf :: TargetCatalog -> ActionEnvironment
environmentOf catalog =
  ActionEnvironment
    { actionRepository = repositoryUnderTest,
      actionWorkflowConfig = defaultWorkflowConfig,
      actionConfigPath = Just "/tmp/kanban-registry-fixture/config.toml",
      actionRoster = Right defaultRoster,
      actionCatalog = catalog,
      actionNow = epoch
    }

resolveIn :: TargetCatalog -> ActionTargetRef -> Either ActionRefusal ActionTarget
resolveIn catalog = resolveActionTarget defaultWorkflowConfig catalog identityUnderTest

itemTarget :: Either ActionRefusal ActionTarget -> Maybe ResolvedTarget
itemTarget (Right (ActionTargetItem resolved)) = Just resolved
itemTarget _ = Nothing

refusalOf :: Either ActionRefusal a -> Maybe ActionRefusal
refusalOf (Left refusal) = Just refusal
refusalOf _ = Nothing

solveCell :: SolverBrand -> RecordedAssignment
solveCell brand = cellOf (solveAssignment defaultRoster brand)

-- | The attribution a dispatch would have recorded: what was already there,
-- when the run started, and which solver ran.
attributionOf :: [Int] -> SolverBrand -> ActionAttribution
attributionOf known brand =
  ActionAttribution
    { attributionKnownPullRequests = Set.fromList known,
      attributionStartedAt = epoch,
      attributionSolverBrand = brand
    }

spec :: Spec
spec = do
  describe "the registered action kinds" $ do
    -- Pinned by value rather than by count or distinctness: a rename that kept
    -- eight unique kinds would pass either of those and change what a durable
    -- mission record means.
    it "declares exactly the eight kinds, and spells each one the way a record does" $ do
      map workflowActionKindTag workflowActionKinds
        `shouldBe` [ "review_issue",
                     "revise_issue",
                     "solve_issue",
                     "autosolve_issue",
                     "review_pull_request",
                     "revise_pull_request",
                     "repair_pull_request",
                     "observe_approval_queue"
                   ]
      length workflowActionKinds `shouldBe` 8

    it "resolves every declared tag back to its own kind" $
      mapM_
        (\kind -> decodeWorkflowActionKind (workflowActionKindTag kind) `shouldBe` Right kind)
        workflowActionKinds

    -- Requirement 17 only exists at a decode boundary: 'WorkflowActionKind' is
    -- closed, so a caller holding one holds a registered kind. The name a
    -- mission plan step carries is where an unregistered kind can arrive, and
    -- this is where it is refused — with nothing dispatched, because no kind
    -- was produced to dispatch.
    it "rejects an unregistered action name as a typed error, naming what is declared" $ do
      decodeWorkflowActionKind "merge_pull_request"
        `shouldBe` Left (UnknownWorkflowActionKind "merge_pull_request")
      actionKindDecodeErrorMessage (UnknownWorkflowActionKind "merge_pull_request")
        `shouldSatisfy` Text.isInfixOf "repair_pull_request"

    it "reads a recorded name case-insensitively and ignores surrounding space" $
      decodeWorkflowActionKind "  Solve_Issue " `shouldBe` Right SolveIssue

    it "says which kind of target each verb takes" $ do
      mapMaybe workflowActionTargetKind [ReviewIssue, ReviseIssue, SolveIssue, AutoSolveIssue]
        `shouldBe` replicate 4 ActionTargetIssue
      mapMaybe workflowActionTargetKind [ReviewPullRequest, RevisePullRequest, RepairPullRequest]
        `shouldBe` replicate 3 ActionTargetPullRequest
      workflowActionTargetKind ObserveApprovalQueue `shouldBe` Nothing

  describe "target references" $ do
    it "reads the unqualified, explicit, and repository-wide forms" $ do
      parseActionTargetRef "123" `shouldBe` Right (TargetByNumber 123)
      parseActionTargetRef "#123" `shouldBe` Right (TargetByNumber 123)
      parseActionTargetRef "issue 123" `shouldBe` Right (TargetByKind ActionTargetIssue 123)
      parseActionTargetRef "PR #123" `shouldBe` Right (TargetByKind ActionTargetPullRequest 123)
      parseActionTargetRef "repository" `shouldBe` Right TargetRepositoryWide

    it "refuses a reference it cannot read rather than guessing a number" $ do
      parseActionTargetRef "epic 12" `shouldSatisfy` either (Text.isInfixOf "qualifier") (const False)
      parseActionTargetRef "twelve" `shouldSatisfy` either (Text.isInfixOf "target number") (const False)

    -- A digit string longer than a machine word wraps if it is read straight
    -- into an Int, so a target that cannot exist would resolve and dispatch
    -- against a real one that shares its low bits.
    it "refuses a number outside the range a target can have" $ do
      parseActionTargetRef "18446744073709551626"
        `shouldSatisfy` either (Text.isInfixOf "out of range") (const False)
      parseActionTargetRef "0" `shouldSatisfy` either (Text.isInfixOf "out of range") (const False)
      -- The largest number that is still a number, and the smallest.
      parseActionTargetRef (Text.pack (show (maxBound :: Int)))
        `shouldBe` Right (TargetByNumber maxBound)
      parseActionTargetRef "1" `shouldBe` Right (TargetByNumber 1)

  describe "resolution" $ do
    let issues = [baseIssue 10 []]
        pullRequests = [markedPullRequest 11 [10] ClaudeSolver []]
        catalog = catalogOf issues pullRequests emptyHistory

    -- GitHub gives both one number space, so an unqualified number is
    -- authoritative about which of the two it names.
    it "resolves an unqualified number to the kind that number actually names" $ do
      (.resolvedTargetKind) <$> itemTarget (resolveIn catalog (TargetByNumber 10))
        `shouldBe` Just ActionTargetIssue
      (.resolvedTargetKind) <$> itemTarget (resolveIn catalog (TargetByNumber 11))
        `shouldBe` Just ActionTargetPullRequest

    it "refuses an explicit form whose named kind is not what the number is" $
      refusalOf (resolveIn catalog (TargetByKind ActionTargetIssue 11))
        `shouldBe` Just (ActionTargetKindMismatch ActionTargetIssue ActionTargetPullRequest 11)

    it "carries the canonical repository identity, lifecycle, structure, and reach onto the record" $ do
      let resolved = itemTarget (resolveIn catalog (TargetByNumber 10))
      (.resolvedTargetRepository) <$> resolved `shouldBe` Just identityUnderTest
      (.resolvedTargetLifecycle) <$> resolved `shouldBe` Just TargetOpen
      (.resolvedTargetHistoryReach) <$> resolved `shouldBe` Just HistoryConfirmed
      (.resolvedTargetStructure) <$> resolved `shouldBe` Just TargetPlain
      (.resolvedTargetNumber) <$> resolved `shouldBe` Just 10

    -- Detectable *after* resolution is the point: neither 'Issue' nor
    -- 'PullRequest' carries a repository, so without the identity on the
    -- record a resolved target would be indistinguishable from another
    -- repository's #10.
    it "refuses a request naming another repository before any number is looked up" $
      refusalOf (resolveActionTarget defaultWorkflowConfig catalog "coghex/other" (TargetByNumber 10))
        `shouldBe` Just (ActionRepositoryMismatch "coghex/other" identityUnderTest)

    it "reports a number the read covers and does not hold as not found" $
      refusalOf (resolveIn catalog (TargetByNumber 99))
        `shouldBe` Just (ActionTargetNotFound (TargetByNumber 99))

    -- The fail-closed half. Without the completed generation, "closed or
    -- merged" and "never existed" are the same observation, and dispatching
    -- against the first is exactly what this refusal prevents.
    it "refuses a number it cannot answer for as unresolved, not as absent" $ do
      let unread = catalogOf issues pullRequests CatalogHistoryAbsent
      refusalOf (resolveIn unread (TargetByNumber 99))
        `shouldSatisfy` maybe False (Text.isInfixOf "completed generation" . actionRefusalMessage)
      catalogHistoryReach unread `shouldBe` HistoryAbsent

    it "resolves a settled number out of the completed generation and marks it settled" $ do
      let merged = (basePullRequest 12 [10] False []) {pullRequestState = PullRequestMerged}
          withHistory = catalogOf issues pullRequests (CatalogHistoryLoaded (CompletedHistory [] [merged] epoch))
      (.resolvedTargetLifecycle) <$> itemTarget (resolveIn withHistory (TargetByNumber 12))
        `shouldBe` Just TargetSettled

    -- The completed generation is newer than the record a caller is holding,
    -- so it decides, and the refusal reports that generation's own copy.
    it "settles a held record the newer completed generation has since closed" $ do
      let closed = (baseIssue 10 []) {issueState = IssueClosed}
          withHistory = catalogOf issues pullRequests (CatalogHistoryLoaded (CompletedHistory [closed] [] epoch))
          resolved = resolveHeldItem withHistory TargetPlain (IssueItem (baseIssue 10 []))
      resolved.resolvedTargetLifecycle `shouldBe` TargetSettled
      resolved.resolvedTargetItem `shouldBe` IssueItem closed

    it "classifies a tracker's structure from the hierarchy, with childlessness distinguished" $ do
      targetStructureForIssue defaultWorkflowConfig (epicIssue 20 [21, 22])
        `shouldBe` TargetTracker TrackerHasChildren
      targetStructureForIssue defaultWorkflowConfig (epicIssue 20 [])
        `shouldBe` TargetTracker TrackerChildless
      targetStructureForIssue defaultWorkflowConfig (baseIssue 20 []) `shouldBe` TargetPlain

  describe "compatibility" $ do
    let openIssue = baseIssue 10 []
        openPullRequest = markedPullRequest 11 [10] ClaudeSolver []
        catalog = catalogOf [openIssue] [openPullRequest] emptyHistory
        target ref = either (error . show) id (resolveIn catalog ref)
        refuse kind ref = actionCompatibility defaultWorkflowConfig kind (target ref)

    it "refuses an issue verb pointed at a pull request, and the reverse" $ do
      refuse SolveIssue (TargetByNumber 11)
        `shouldBe` Just (ActionTargetKindMismatch ActionTargetIssue ActionTargetPullRequest 11)
      refuse ReviewPullRequest (TargetByNumber 10)
        `shouldBe` Just (ActionTargetKindMismatch ActionTargetPullRequest ActionTargetIssue 10)

    it "refuses the repository-wide verb a number was given, and the item verbs given none" $ do
      actionCompatibility defaultWorkflowConfig ObserveApprovalQueue (target (TargetByNumber 10))
        `shouldBe` Just (ActionTargetMismatchedArity ObserveApprovalQueue)
      actionCompatibility defaultWorkflowConfig SolveIssue (ActionTargetRepositoryWide repositoryUnderTest)
        `shouldBe` Just (ActionTargetMismatchedArity SolveIssue)
      actionCompatibility defaultWorkflowConfig ObserveApprovalQueue (ActionTargetRepositoryWide repositoryUnderTest)
        `shouldBe` Nothing

    it "refuses completed work in the wording the board has always used" $ do
      let closed = (baseIssue 10 []) {issueState = IssueClosed}
          settled = resolveHeldItem catalog TargetPlain (IssueItem closed)
      actionCompatibility defaultWorkflowConfig SolveIssue (ActionTargetItem settled)
        `shouldBe` Just (ActionTargetHistorical (IssueItem closed))
      actionRefusalMessage (ActionTargetHistorical (IssueItem closed))
        `shouldSatisfy` Text.isInfixOf "completed history is read-only"

    -- Verb-scoped, deliberately. Solve and autosolve act on the epic issue
    -- itself, which is what the S and A keys have always done.
    it "refuses issue review on a childless epic while solve and autosolve accept it" $ do
      let epicCatalog = catalogOf [epicIssue 30 [], epicIssue 31 [32]] [] emptyHistory
          epicTarget number = either (error . show) id (resolveIn epicCatalog (TargetByNumber number))
      actionCompatibility defaultWorkflowConfig ReviewIssue (epicTarget 30)
        `shouldBe` Just (ActionTargetStructural StructuralTrackerHeader 30)
      actionCompatibility defaultWorkflowConfig SolveIssue (epicTarget 30) `shouldBe` Nothing
      actionCompatibility defaultWorkflowConfig AutoSolveIssue (epicTarget 30) `shouldBe` Nothing
      actionCompatibility defaultWorkflowConfig SolveIssue (epicTarget 31) `shouldBe` Nothing
      actionCompatibility defaultWorkflowConfig AutoSolveIssue (epicTarget 31) `shouldBe` Nothing

    -- "Collapsed" is a property of one dashboard's expansion set, not of a
    -- number, so the registry never derives it — but the rule still names it,
    -- because the adapter that does know supplies it.
    it "never returns the collapsed-group refusal from a hierarchy classification" $ do
      structuralActionRefusal ReviewIssue (TargetTracker TrackerChildless)
        `shouldBe` Just StructuralTrackerHeader
      structuralActionRefusal ReviewIssue (TargetTracker TrackerHasChildren) `shouldBe` Nothing
      structuralActionRefusal ReviewIssue TargetPlain `shouldBe` Nothing
      structuralRefusalMessage StructuralCollapsedGroup
        `shouldSatisfy` Text.isInfixOf "expand"

    it "refuses a pull-request verb the target's current state is not in" $ do
      let changesRequested = markedPullRequest 40 [10] ClaudeSolver [label defaultWorkflowConfig.changesRequestedLabel]
          plain = markedPullRequest 41 [10] ClaudeSolver []
          stateCatalog = catalogOf [openIssue] [changesRequested, plain] emptyHistory
          check kind number =
            actionCompatibility defaultWorkflowConfig kind (either (error . show) id (resolveIn stateCatalog (TargetByNumber number)))
      check ReviewPullRequest 40
        `shouldSatisfy` maybe False (Text.isInfixOf "revise it instead" . actionRefusalMessage)
      check RevisePullRequest 41
        `shouldSatisfy` maybe False (Text.isInfixOf "no changes-requested verdict" . actionRefusalMessage)
      check RepairPullRequest 41
        `shouldSatisfy` maybe False (Text.isInfixOf "approved Done pull request" . actionRefusalMessage)
      check ReviewPullRequest 41 `shouldBe` Nothing
      check RevisePullRequest 40 `shouldBe` Nothing

  describe "the pull-request verbs" $ do
    -- Repair is its own verb pinned to its own selector. Folding it into
    -- revision would send an approved Done pull request with a conflict to
    -- $pr-revise, which is a different workflow.
    it "binds repair to the rule that selects it, and revision to the labels" $ do
      let repairable =
            (markedPullRequest 50 [10] ClaudeSolver [label defaultWorkflowConfig.approvalLabel])
              { pullRequestMergeState = MergeConflicting,
                pullRequestReviewDecision = ReviewApproved
              }
      directPullRequestAction defaultWorkflowConfig repairable `shouldBe` PullRequestRepair
      workflowActionKindForDirectPress defaultWorkflowConfig repairable `shouldBe` RepairPullRequest
      pullRequestActionForKind defaultWorkflowConfig RepairPullRequest repairable
        `shouldBe` Right PullRequestRepair
      pullRequestActionForKind defaultWorkflowConfig RevisePullRequest repairable
        `shouldSatisfy` either (const True) (const False)
      -- Kanban's own automated progressions stay on the label-derived route,
      -- so the same pull request is a review round for autosolve.
      workflowActionKindForLabelledPullRequest defaultWorkflowConfig repairable
        `shouldBe` ReviewPullRequest
      labelPullRequestAction defaultWorkflowConfig repairable `shouldBe` PullRequestReview

    it "round-trips every pull-request action through its verb" $
      mapM_
        (\action -> pullRequestActionForKind defaultWorkflowConfig (workflowActionKindForAction action) (pullRequestFor action) `shouldBe` Right action)
        [PullRequestReview, PullRequestRereview, PullRequestRevision, PullRequestRepair]

  describe "the dashboard adapters" $ do
    -- The two board keys and the one unified pull-request key, as the verbs
    -- they select. Everything downstream of these mappings -- the preflight,
    -- the cell replay, the refusals -- is the registry's, so this is where the
    -- key and the verb are held together.
    it "selects the solve verbs the S and A keys start" $ do
      solveActionKind SolveOnly `shouldBe` SolveIssue
      solveActionKind AutoSolve `shouldBe` AutoSolveIssue

    it "selects each pull-request verb r reaches, repair included" $
      mapM_
        ( \action ->
            workflowActionKindForDirectPress defaultWorkflowConfig (pullRequestFor action)
              `shouldBe` workflowActionKindForAction action
        )
        [PullRequestReview, PullRequestRereview, PullRequestRevision, PullRequestRepair]

    -- What the S key hands the registry, from a real dashboard state: the
    -- verb, the target, the operator's brand, the cell to replay, and the
    -- session to resume. Everything after this is the registry's, so this is
    -- where the adapter's own decision is pinned.
    it "hands the registry a solve turn for the session S pressed on" $ do
      state <- withSolveSession (baseIssue 844 []) SolveRunning <$> testAppState (fixtureBoard [])
      case solveLaunchPlan state (solveCell CodexSolver) 844 SolveOnly CodexSolver (Just "session-7") ResumeAnswer "go" of
        Left refusal -> error ("expected a plan, saw " <> show refusal)
        Right (request, plan) -> do
          request.requestKind `shouldBe` SolveIssue
          plan.planKind `shouldBe` SolveIssue
          plan.planRoute `shouldBe` RouteProvider (ActionSolve CodexSolver)
          request.requestTarget `shouldBe` TargetByKind ActionTargetIssue 844
          request.requestSolverBrand `shouldBe` Just CodexSolver
          request.requestRecordedAssignment `shouldBe` Just (solveCell CodexSolver)
          request.requestExistingSession `shouldBe` Just "session-7"
          request.requestUserMessage `shouldBe` "go"
          -- A plain solve carries no loop, so it records no parent.
          request.requestParent `shouldBe` Nothing

    -- The A key differs in exactly two ways, and both are what an autosolve
    -- run needs to survive a restart: the verb, and the parent record its
    -- worker carries.
    it "hands the registry an autosolve turn carrying the run's own record" $ do
      let progress =
            AutoSolveProgress
              { autoSolveStage = AutoReviewing,
                autoSolvePullRequest = Just 900,
                autoSolveReviewRound = 2,
                autoSolveKnownPullRequests = Set.fromList [11],
                autoSolveStartedAt = epoch
              }
          looping session =
            session {sessionDetail = session.sessionDetail {solveSessionAutoProgress = Just progress}}
      base <- testAppState (fixtureBoard [])
      let state =
            base
              { appSolveSessions =
                  Map.singleton 844 (looping (testSolveSession (baseIssue 844 []) SolveRunning))
              }
      case solveLaunchPlan state (solveCell ClaudeSolver) 844 AutoSolve ClaudeSolver Nothing ResumeAutomatedChangesRequested "revise" of
        Left refusal -> error ("expected a plan, saw " <> show refusal)
        Right (request, plan) -> do
          request.requestKind `shouldBe` AutoSolveIssue
          plan.planRoute `shouldBe` RouteProvider (ActionAutoSolve ClaudeSolver)
          request.requestResumeProvenance `shouldBe` ResumeAutomatedChangesRequested
          case request.requestParent of
            Nothing -> error "expected an autosolve run to record its parent"
            Just parent -> do
              parent.workerParentIssueNumber `shouldBe` 844
              parent.workerParentReviewRound `shouldBe` 2
              parent.workerParentKnownPullRequests `shouldBe` Set.fromList [11]
              parent.workerParentPullRequest `shouldBe` Just 900
              parent.workerParentStartedAt `shouldBe` epoch

    -- Every mode r selects, repair included. The registry derives the action
    -- back from the same record the press decided from, so each verb must
    -- round-trip to the action its session recorded.
    it "hands the registry each pull-request mode r selects" $
      mapM_
        ( \action -> do
            let pullRequest = pullRequestFor action
                recorded session =
                  session {sessionDetail = session.sessionDetail {pullRequestSessionAction = action}}
            base <- testAppState (fixtureBoard [])
            let state =
                  base
                    { appPullRequestReviewSessions =
                        Map.singleton 60 (recorded (testPullRequestSession pullRequest SolveRunning))
                    }
            case pullRequestLaunchPlan state (solveCell CodexSolver) 60 action Nothing ResumeAnswer "" of
              Left refusal -> error ("expected a plan for " <> show action <> ", saw " <> show refusal)
              Right (request, plan) -> do
                request.requestKind `shouldBe` workflowActionKindForAction action
                request.requestTarget `shouldBe` TargetByKind ActionTargetPullRequest 60
                -- The route names the action the registry derived back, and
                -- the brand routing that action takes.
                plan.planRoute
                  `shouldBe` RouteProvider (ActionPullRequestFlow PullRequestClaude action)
        )
        [PullRequestReview, PullRequestRereview, PullRequestRevision, PullRequestRepair]

    -- The refusals reach the adapter too: a launch for a session that has
    -- gone, and one whose issue the completed generation has since settled,
    -- both come back as refusals rather than plans.
    it "refuses a launch the session or the completed generation has settled" $ do
      base <- testAppState (fixtureBoard [])
      either (Text.isInfixOf "no solve session" . actionRefusalMessage) (const False)
        (solveLaunchPlan base (solveCell CodexSolver) 844 SolveOnly CodexSolver Nothing ResumeAnswer "")
        `shouldBe` True
      let closed = (baseIssue 844 []) {issueState = IssueClosed}
          settled =
            (withSolveSession (baseIssue 844 []) SolveRunning base)
              {appCompletedHistory = Just (CompletedHistory [closed] [] epoch)}
      either (Text.isInfixOf "completed history is read-only" . actionRefusalMessage) (const False)
        (solveLaunchPlan settled (solveCell CodexSolver) 844 SolveOnly CodexSolver Nothing ResumeAnswer "")
        `shouldBe` True

    -- The dashboard classifies structure from what it is drawing; a headless
    -- caller from the hierarchy. Both feed the one rule, and only the first
    -- can produce the collapsed refusal.
    it "feeds the board's own structural classification into the same rule" $ do
      structuralActionRefusal ReviewIssue (TargetTracker TrackerChildless)
        `shouldBe` Just StructuralTrackerHeader
      structuralActionRefusal SolveIssue (TargetTracker TrackerChildless) `shouldBe` Nothing
      structuralActionRefusal AutoSolveIssue (TargetTracker TrackerChildless) `shouldBe` Nothing

  describe "routing" $ do
    -- Requirement 9: the registry reads the existing decision rather than
    -- restating it. This holds the two together over the whole product.
    it "agrees with agentForAction and pullRequestAssignment for every origin and action" $
      mapM_
        ( \(origin, action) -> do
            let pullRequest = pullRequestForOrigin origin action
                catalog = catalogOf [] [pullRequest] emptyHistory
                target = either (error . show) id (resolveIn catalog (TargetByNumber 60))
            actionRoute defaultWorkflowConfig (workflowActionKindForAction action) Nothing target
              `shouldBe` Right (RouteProvider (ActionPullRequestFlow origin action))
            -- The cell that route resolves through is the one
            -- 'pullRequestAssignment' hands back, and the brand recorded on it
            -- is 'agentForAction''s. Repair included: it runs on the pull
            -- request's own brand, not the reviewer's.
            brandForProvider (cellOf (pullRequestAssignment defaultRoster origin action)).recordedAssignmentProvider
              `shouldBe` agentForAction origin action
        )
        [(origin, action) | origin <- [PullRequestCodex, PullRequestClaude], action <- [PullRequestReview, PullRequestRereview, PullRequestRevision, PullRequestRepair]]

    it "routes the issue verbs by the origin marker the backend itself reads" $ do
      let claudeIssue = (baseIssue 70 []) {issueBody = "<!-- issue-origin:claude -->"}
          catalog = catalogOf [claudeIssue] [] emptyHistory
          target = either (error . show) id (resolveIn catalog (TargetByNumber 70))
      actionRoute defaultWorkflowConfig ReviewIssue Nothing target
        `shouldBe` Right (RouteProvider (ActionIssueReview IssueOriginClaude))
      actionRoute defaultWorkflowConfig ReviseIssue Nothing target
        `shouldBe` Right (RouteProvider (ActionIssueRevision IssueOriginClaude))

    it "carries the operator's solver choice into the solve routes and refuses without one" $ do
      let catalog = catalogOf [baseIssue 71 []] [] emptyHistory
          target = either (error . show) id (resolveIn catalog (TargetByNumber 71))
      actionRoute defaultWorkflowConfig SolveIssue (Just ClaudeSolver) target
        `shouldBe` Right (RouteProvider (ActionSolve ClaudeSolver))
      actionRoute defaultWorkflowConfig AutoSolveIssue (Just CodexSolver) target
        `shouldBe` Right (RouteProvider (ActionAutoSolve CodexSolver))
      actionRoute defaultWorkflowConfig SolveIssue Nothing target
        `shouldSatisfy` either (Text.isInfixOf "no solver" . actionRefusalMessage) (const False)

    it "refuses to route a pull request whose origin marker is unusable" $ do
      let ambiguous = (basePullRequest 72 [] False []) {pullRequestBody = "<!-- pr-origin:codex -->\n<!-- pr-origin:claude -->"}
          catalog = catalogOf [] [ambiguous] emptyHistory
          target = either (error . show) id (resolveIn catalog (TargetByNumber 72))
      actionRoute defaultWorkflowConfig ReviewPullRequest Nothing target
        `shouldSatisfy` either (Text.isInfixOf "both pr-origin markers" . actionRefusalMessage) (const False)

    it "routes the approval queue to no provider at all" $ do
      actionRoute defaultWorkflowConfig ObserveApprovalQueue Nothing (ActionTargetRepositoryWide repositoryUnderTest)
        `shouldBe` Right RouteApprovalQueue
      routePreflightAction RouteApprovalQueue `shouldBe` Nothing

  describe "capability" $ do
    -- Reuses 'actionReport'; this holds the two equal rather than restating
    -- the readiness model.
    it "agrees with actionReport for every applicable preflight action" $
      mapM_
        ( \action ->
            actionCapability readyPreflightEnvironment (RouteProvider action)
              `shouldBe` capabilityFromReport readyPreflightEnvironment action
        )
        everyPreflightAction

    it "blocks only the actions that reach the missing provider" $ do
      let noCodex = withCodexProbe missingProbe
      actionCapableMessage (actionCapability noCodex (RouteProvider (ActionSolve CodexSolver)))
        `shouldSatisfy` maybe False (Text.isInfixOf "codex")
      actionCapability noCodex (RouteProvider (ActionSolve ClaudeSolver)) `shouldBe` ActionCapable
      -- Autosolve drives the opposite brand's review itself, so it needs both.
      actionCapability noCodex (RouteProvider (ActionAutoSolve ClaudeSolver))
        `shouldNotBe` ActionCapable
      actionCapability noCodex (RouteProvider (ActionPullRequestFlow PullRequestClaude PullRequestReview))
        `shouldNotBe` ActionCapable
      actionCapability noCodex (RouteProvider (ActionPullRequestFlow PullRequestCodex PullRequestReview))
        `shouldBe` ActionCapable

    it "asks nothing of a provider for the queue observation" $
      actionCapability (withCodexProbe missingProbe) RouteApprovalQueue `shouldBe` ActionCapable

  describe "terminal validation" $ do
    let solveTarget = resolveHeldItem (catalogOf [baseIssue 80 []] [] emptyHistory) TargetPlain (IssueItem (baseIssue 80 []))
        withPullRequests pullRequests = environmentOf (catalogOf [baseIssue 80 []] pullRequests emptyHistory)
        opened pullRequests brand known =
          validateWorkerOutcome (withPullRequests pullRequests) SolveIssue solveTarget (attributionOf known brand) SolveCompleted

    -- Worker exit success is not action success: the same SolveCompleted
    -- produces four different answers depending on the evidence.
    it "reports a pull request only when exactly one is attributable to the run" $ do
      let mine = markedPullRequest 81 [80] ClaudeSolver []
          second = markedPullRequest 82 [80] ClaudeSolver []
          wrongOrigin = markedPullRequest 83 [80] CodexSolver []
      opened [mine] ClaudeSolver [] `shouldBe` ActionPullRequestOpened 81
      opened [] ClaudeSolver [] `shouldSatisfy` notSucceeding
      opened [mine, second] ClaudeSolver [] `shouldSatisfy` notSucceeding
      opened [wrongOrigin] ClaudeSolver [] `shouldSatisfy` notSucceeding
      -- Already on the board when the run began: not this run's result.
      opened [mine] ClaudeSolver [81] `shouldSatisfy` notSucceeding

    it "refuses to attribute a pull request opened long before the run started" $ do
      let stale = (markedPullRequest 84 [80] ClaudeSolver []) {pullRequestCreatedAt = addUTCTime (-3600) epoch}
      opened [stale] ClaudeSolver [] `shouldSatisfy` notSucceeding

    it "passes a provider's own question and failure straight through" $ do
      validateWorkerOutcome (withPullRequests []) SolveIssue solveTarget (attributionOf [] ClaudeSolver) (SolveNeedsInput "which base?")
        `shouldBe` ActionNeedsInput "which base?"
      validateWorkerOutcome (withPullRequests []) SolveIssue solveTarget (attributionOf [] ClaudeSolver) (SolveFailed "boom")
        `shouldBe` ActionFailed "boom"

    it "reports a pull-request verdict only from one actually standing on the read" $ do
      let approved = markedPullRequest 90 [80] ClaudeSolver [label defaultWorkflowConfig.approvalLabel]
          changes = markedPullRequest 90 [80] ClaudeSolver [label defaultWorkflowConfig.changesRequestedLabel]
          pending = markedPullRequest 90 [80] ClaudeSolver []
          verdictTarget = resolveHeldItem (catalogOf [] [pending] emptyHistory) TargetPlain (PullRequestItem pending)
          verdictIn pullRequests = validatedPullRequestVerdict (environmentOf (catalogOf [] pullRequests emptyHistory)) verdictTarget
      verdictIn [approved] `shouldBe` ActionPullRequestVerdict 90 PullRequestVerdictApproved
      verdictIn [changes] `shouldBe` ActionPullRequestVerdict 90 PullRequestVerdictChangesRequested
      verdictIn [pending] `shouldSatisfy` notSucceeding
      verdictIn [] `shouldSatisfy` notSucceeding
      -- Both labels at once: two canonical verdicts stand on it and neither
      -- is the one it carries. An approval-first reading would call that
      -- success.
      let contradictory =
            markedPullRequest 90 [80] ClaudeSolver
              [label defaultWorkflowConfig.approvalLabel, label defaultWorkflowConfig.changesRequestedLabel]
      verdictIn [contradictory] `shouldSatisfy` notSucceeding
      verdictIn [contradictory]
        `shouldSatisfy` (Text.isInfixOf "contradictory" . actionOutcomeMessage)

    it "calls a pending verdict, a needs-input halt, and a stop non-success" $ do
      actionOutcomeSucceeded (ActionPullRequestVerdict 1 PullRequestVerdictPending) `shouldBe` False
      actionOutcomeSucceeded (ActionNeedsInput "x") `shouldBe` False
      actionOutcomeSucceeded (ActionStopped "x") `shouldBe` False
      actionOutcomeSucceeded (ActionFailed "x") `shouldBe` False
      actionOutcomeSucceeded (ActionPullRequestOpened 1) `shouldBe` True
      actionOutcomeSucceeded (ActionPullRequestApproved 1) `shouldBe` True

  describe "observation" $ do
    -- Dispatch hands back a handle; the states a handle reports are separate
    -- from it, and only the terminal one carries a validated result.
    it "reports a running worker as nonterminal and a settled one as a result" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              catalog = (catalogOf [baseIssue 80 []] [] emptyHistory) {catalogRepository = repository}
              environment = (environmentOf catalog) {actionRepository = repository}
              target = resolveHeldItem catalog TargetPlain (IssueItem (baseIssue 80 []))
          descriptor <- writeWorkerRecord repository 80 WorkerRunning "implementing"
          observeWorkerHandle environment SolveIssue target descriptor (attributionOf [] ClaudeSolver)
            >>= (`shouldBe` ActionRunning "implementing")
          settledDescriptor <- writeWorkerRecord repository 80 (WorkerTerminal (SolveNeedsInput "which base?")) "waiting"
          observeWorkerHandle environment SolveIssue target settledDescriptor (attributionOf [] ClaudeSolver)
            >>= (`shouldBe` ActionSettled (ActionNeedsInput "which base?"))

    -- Autosolve's advertised handle must not report the opening solve as the
    -- action's result. Its only success is the approval its loop reaches, and
    -- a caller polling the handle after the solver settled would otherwise see
    -- an opened pull request and stop -- never driving the review, the
    -- revision, or the approval it asked for.
    it "never concludes an autosolve action from one finished provider turn" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              opened = markedPullRequest 81 [80] ClaudeSolver []
              catalog = (catalogOf [baseIssue 80 []] [opened] emptyHistory) {catalogRepository = repository}
              environment = (environmentOf catalog) {actionRepository = repository}
              target = resolveHeldItem catalog TargetPlain (IssueItem (baseIssue 80 []))
              attribution = attributionOf [] ClaudeSolver
          descriptor <- writeWorkerRecord repository 80 (WorkerTerminal SolveCompleted) "finished"
          -- The same worker record, observed as a solve, does report the pull
          -- request it opened. That is what makes this a contrast rather than
          -- an accident of the fixture.
          observeWorkerHandle environment SolveIssue target descriptor attribution
            >>= (`shouldBe` ActionSettled (ActionPullRequestOpened 81))
          -- Observed as an autosolve turn, the same record is not a result:
          -- the loop has a review, a revision, and an approval still to run.
          observeAutoSolveTurn environment target descriptor >>= (`shouldSatisfy` isRunning)
          -- ...and a question or a failure still ends it, wherever the loop is.
          asking <- writeWorkerRecord repository 80 (WorkerTerminal (SolveNeedsInput "which base?")) "waiting"
          observeAutoSolveTurn environment target asking
            >>= (`shouldBe` ActionSettled (ActionNeedsInput "which base?"))
          -- The validator agrees: no autosolve arm of it promotes a turn.
          validateWorkerOutcome environment AutoSolveIssue target attribution SolveCompleted
            `shouldSatisfy` notSucceeding

    it "treats an unreadable worker record as still running rather than as a result" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              catalog = (catalogOf [baseIssue 80 []] [] emptyHistory) {catalogRepository = repository}
              environment = (environmentOf catalog) {actionRepository = repository}
              target = resolveHeldItem catalog TargetPlain (IssueItem (baseIssue 80 []))
          descriptor <- descriptorFor repository 80
          observed <- observeWorkerHandle environment SolveIssue target descriptor (attributionOf [] ClaudeSolver)
          observed `shouldSatisfy` isRunning
          target.resolvedTargetNumber `shouldBe` 80

  describe "dispatch" $ do
    -- The specification is the only artifact that travels to the supervisor,
    -- so it is the evidence that the launch reached its authority with this
    -- request's own repository, target, action, config path, and cell.
    it "reaches the solve authority with exactly the values the request named" $
      withDispatchMachine $ \environment -> do
        let request =
              (actionRequest SolveIssue identityUnderTest (TargetByKind ActionTargetIssue 844))
                { requestSolverBrand = Just CodexSolver,
                  requestRecordedAssignment = Just (solveCell CodexSolver)
                }
            plan =
              either (error . show) id $
                planResolvedAction
                  defaultWorkflowConfig
                  identityUnderTest
                  SolveIssue
                  (Just CodexSolver)
                  (ActionTargetItem (resolveHeldItem environment.actionCatalog TargetPlain (IssueItem (baseIssue 844 []))))
        void (dispatchProviderTurn environment request plan)
        specifications environment.actionRepository >>= \written -> case written of
          [spec'] -> do
            spec'.workerRepository `shouldBe` environment.actionRepository
            spec'.workerConfigPath `shouldBe` environment.actionConfigPath
            spec'.workerAssignment `shouldBe` Just (solveCell CodexSolver)
            solveTaskOf spec' `shouldBe` Just (844, CodexSolver)
          other -> error ("expected exactly one worker specification, saw " <> show (length other))

    it "reaches the pull-request authority with the origin and action the verb selected" $
      withDispatchMachine $ \environment -> do
        let repairable =
              (markedPullRequest 42 [844] CodexSolver [label defaultWorkflowConfig.approvalLabel])
                { pullRequestMergeState = MergeConflicting,
                  pullRequestReviewDecision = ReviewApproved
                }
            request =
              (actionRequest RepairPullRequest identityUnderTest (TargetByKind ActionTargetPullRequest 42))
                { requestRecordedAssignment = Just (cellOf (pullRequestAssignment defaultRoster PullRequestCodex PullRequestRepair))
                }
            plan =
              either (error . show) id $
                planResolvedAction
                  defaultWorkflowConfig
                  identityUnderTest
                  RepairPullRequest
                  Nothing
                  (ActionTargetItem (resolveHeldItem environment.actionCatalog TargetPlain (PullRequestItem repairable)))
        void (dispatchProviderTurn environment request plan)
        specifications environment.actionRepository >>= \written -> case written of
          [spec'] -> pullRequestTaskOf spec' `shouldBe` Just (42, PullRequestCodex, PullRequestRepair)
          other -> error ("expected exactly one worker specification, saw " <> show (length other))

    -- Every repository has a #123. A target resolved against one and
    -- dispatched with another's environment would spawn a worker on the wrong
    -- repository entirely, while the record it came from still named the
    -- right one -- so the identity the record carries is checked again here,
    -- before anything is probed or spawned.
    -- Two advancers of one action -- a dashboard refresh and a headless
    -- runner that has taken the same run over -- can both decide the same
    -- turn is next. The worker lease is keyed by item, so exactly one of them
    -- creates it; the other must join that turn rather than start a second or
    -- report the run stopped over work that is proceeding perfectly well.
    it "joins the turn a live worker already owns instead of starting a second" $
      withDispatchMachine $ \environment -> do
        let repairable =
              (markedPullRequest 42 [844] CodexSolver [label defaultWorkflowConfig.approvalLabel])
                { pullRequestMergeState = MergeConflicting,
                  pullRequestReviewDecision = ReviewApproved
                }
        -- The turn another advancer already started: a live worker, holding
        -- this pull request's lease.
        running <- pullRequestWorkerDescriptor environment.actionRepository 42
        publishWorkerSpec running
        publishWorkerState running WorkerRunning
        acquireWorkerLease running `shouldReturn` Right ()
        let request =
              (actionRequest RepairPullRequest identityUnderTest (TargetByKind ActionTargetPullRequest 42))
                { requestRecordedAssignment = Just (cellOf (pullRequestAssignment defaultRoster PullRequestCodex PullRequestRepair))
                }
            plan =
              either (error . show) id $
                planResolvedAction
                  defaultWorkflowConfig
                  identityUnderTest
                  RepairPullRequest
                  Nothing
                  (ActionTargetItem (resolveHeldItem environment.actionCatalog TargetPlain (PullRequestItem repairable)))
        dispatched <- dispatchProviderTurn environment request plan
        -- The handle names the worker that already owns the turn...
        (actionHandleWorker =<< either (const Nothing) Just dispatched)
          `shouldSatisfy` maybe False ((== running.workerDescriptorSpecPath) . (.workerDescriptorSpecPath))
        -- ...and no second worker was specified into existence.
        written <- specifications environment.actionRepository
        map (.workerId) written `shouldBe` [running.workerDescriptorSpec.workerId]

    -- Leases are keyed by number alone, so one pull request's is held equally
    -- by a review and a repair, and one issue's by a solve and an autosolve.
    -- Joining blind would report a running review's result as a repair, or
    -- wrap a plain solve in an autosolve handle and then start review rounds
    -- for work nobody asked to review.
    it "refuses to join a turn running under a different action than the one asked for" $
      withDispatchMachine $ \environment -> do
        let repairable =
              (markedPullRequest 42 [844] CodexSolver [label defaultWorkflowConfig.approvalLabel])
                { pullRequestMergeState = MergeConflicting,
                  pullRequestReviewDecision = ReviewApproved
                }
        -- A live worker on the same pull request, but reviewing it.
        reviewing <- pullRequestWorkerDescriptor environment.actionRepository 42
        let asReview =
              reviewing
                { workerDescriptorSpec =
                    reviewing.workerDescriptorSpec
                      { workerTask =
                          PullRequestWorkerTaskKind (PullRequestWorkerTask 42 PullRequestCodex PullRequestReview)
                      }
                }
        publishWorkerSpec asReview
        publishWorkerState asReview WorkerRunning
        acquireWorkerLease asReview `shouldReturn` Right ()
        let request = actionRequest RepairPullRequest identityUnderTest (TargetByKind ActionTargetPullRequest 42)
            plan =
              either (error . show) id $
                planResolvedAction
                  defaultWorkflowConfig
                  identityUnderTest
                  RepairPullRequest
                  Nothing
                  (ActionTargetItem (resolveHeldItem environment.actionCatalog TargetPlain (PullRequestItem repairable)))
        dispatched <- dispatchProviderTurn environment request plan
        either isTurnAlreadyRunning (const False) dispatched `shouldBe` True

    -- A discoverable worker matching the requested task is not evidence that
    -- it holds the lease. A terminal worker stays discoverable until it is
    -- acknowledged, so this issue has a finished solve sitting in the cache
    -- while a live autosolve holds its lease -- and a fresh solve request must
    -- not adopt the finished one and report its result as its own.
    it "joins the lease's own owner, never a stale worker that merely matches" $
      withDispatchMachine $ \environment -> do
        stale <- solveWorkerDescriptor environment.actionRepository 844 SolveOnly
        publishWorkerSpec stale
        publishWorkerState stale (WorkerTerminal SolveCompleted)
        holder <- solveWorkerDescriptor environment.actionRepository 844 AutoSolve
        publishWorkerSpec holder
        publishWorkerState holder WorkerRunning
        acquireWorkerLease holder `shouldReturn` Right ()
        -- Both are discoverable: the stale one has not been acknowledged.
        discovered <- discoverWorkers environment.actionRepository
        map (.workerDescriptorSpec.workerId) discovered
          `shouldSatisfy` elem stale.workerDescriptorSpec.workerId
        let request =
              (actionRequest SolveIssue identityUnderTest (TargetByKind ActionTargetIssue 844))
                { requestSolverBrand = Just CodexSolver,
                  requestRecordedAssignment = Just (solveCell CodexSolver)
                }
            plan =
              either (error . show) id $
                planResolvedAction
                  defaultWorkflowConfig
                  identityUnderTest
                  SolveIssue
                  (Just CodexSolver)
                  (ActionTargetItem (resolveHeldItem environment.actionCatalog TargetPlain (IssueItem (baseIssue 844 []))))
        dispatched <- dispatchProviderTurn environment request plan
        -- The lease's owner is an autosolve worker, which is not the turn this
        -- request asked for, so there is nothing to join.
        either isTurnAlreadyRunning (const False) dispatched `shouldBe` True

    -- Fails closed the moment the holder cannot be identified: a turn is
    -- running and this dispatch does not know which worker owns it, so it
    -- refuses rather than starting another.
    it "refuses rather than starting a second turn when the holder cannot be found" $
      withDispatchMachine $ \environment -> do
        let repairable =
              (markedPullRequest 42 [844] CodexSolver [label defaultWorkflowConfig.approvalLabel])
                { pullRequestMergeState = MergeConflicting,
                  pullRequestReviewDecision = ReviewApproved
                }
        -- A lease whose owner reads as live, held by a worker discovery
        -- cannot offer: its state file is there, so the lease stands, but no
        -- specification is, so nothing can be built from it.
        running <- pullRequestWorkerDescriptor environment.actionRepository 42
        publishWorkerState running WorkerRunning
        acquireWorkerLease running `shouldReturn` Right ()
        let request = actionRequest RepairPullRequest identityUnderTest (TargetByKind ActionTargetPullRequest 42)
            plan =
              either (error . show) id $
                planResolvedAction
                  defaultWorkflowConfig
                  identityUnderTest
                  RepairPullRequest
                  Nothing
                  (ActionTargetItem (resolveHeldItem environment.actionCatalog TargetPlain (PullRequestItem repairable)))
        dispatched <- dispatchProviderTurn environment request plan
        either isTurnAlreadyRunning (const False) dispatched `shouldBe` True

    it "refuses a resolved target that belongs to another repository, spawning nothing" $
      withDispatchMachine $ \environment -> do
        let elsewhere = (catalogOf [baseIssue 844 []] [] emptyHistory) {catalogRepository = Repository "/tmp/other" "coghex" "other"}
            foreign' = resolveHeldItem elsewhere TargetPlain (IssueItem (baseIssue 844 []))
            request =
              (actionRequest SolveIssue identityUnderTest (TargetByKind ActionTargetIssue 844))
                { requestSolverBrand = Just CodexSolver,
                  requestRecordedAssignment = Just (solveCell CodexSolver)
                }
        -- The plan is refused against the identity the request names...
        planResolvedAction defaultWorkflowConfig identityUnderTest SolveIssue (Just CodexSolver) (ActionTargetItem foreign')
          `shouldBe` Left (ActionRepositoryMismatch identityUnderTest "coghex/other")
        -- ...and again at the boundary a worker crosses, against the
        -- environment it would cross into, for a plan that was built
        -- elsewhere.
        let planned =
              either (error . show) id $
                planResolvedAction defaultWorkflowConfig "coghex/other" SolveIssue (Just CodexSolver) (ActionTargetItem foreign')
        dispatched <- dispatchProviderTurn environment request planned
        either isRepositoryMismatch (const False) dispatched `shouldBe` True
        specifications environment.actionRepository >>= (`shouldBe` [])

    it "refuses before any launch when a definite local observation blocks the action" $
      withPreflightMachine [] BackendMissing $ \workingDirectory _ ->
        withEnvironmentValue "XDG_CACHE_HOME" (takeDirectory workingDirectory) $ do
          let repository = Repository workingDirectory "coghex" "kanban"
              catalog = (catalogOf [baseIssue 844 []] [] emptyHistory) {catalogRepository = repository}
              environment = (environmentOf catalog) {actionRepository = repository}
              request =
                (actionRequest SolveIssue identityUnderTest (TargetByKind ActionTargetIssue 844))
                  { requestSolverBrand = Just CodexSolver,
                    requestRecordedAssignment = Just (solveCell CodexSolver)
                  }
              plan =
                either (error . show) id $
                  planResolvedAction
                    defaultWorkflowConfig
                    identityUnderTest
                    SolveIssue
                    (Just CodexSolver)
                    (ActionTargetItem (resolveHeldItem catalog TargetPlain (IssueItem (baseIssue 844 []))))
          dispatched <- dispatchProviderTurn environment request plan
          either isCapabilityBlocked (const False) dispatched `shouldBe` True
          specifications repository >>= (`shouldBe` [])

    -- Declared, and refused at the door. Nothing is spawned and nothing is
    -- probed: the refusal precedes the capability query as well as the launch.
    it "returns the not-yet-runner-owned refusal for the two issue verbs, starting nothing" $
      withPreflightMachine fullyProvisionedFakes BackendInstalled $ \workingDirectory probeLog ->
        withEnvironmentValue "XDG_CACHE_HOME" (takeDirectory workingDirectory) $ do
          let repository = Repository workingDirectory "coghex" "kanban"
              issue = (baseIssue 844 []) {issueBody = "<!-- issue-origin:claude -->"}
              catalog = (catalogOf [issue] [] emptyHistory) {catalogRepository = repository}
              environment = (environmentOf catalog) {actionRepository = repository}
          mapM_
            ( \kind -> do
                dispatched <-
                  dispatchAction environment (actionRequest kind identityUnderTest (TargetByNumber 844))
                either Just (const Nothing) dispatched `shouldBe` Just (ActionNotRunnerOwned kind)
            )
            [ReviewIssue, ReviseIssue]
          specifications repository >>= (`shouldBe` [])
          probeInvocations probeLog >>= (`shouldBe` [])

    it "refuses an incompatible request before it reaches the not-yet-owned refusal" $
      withPreflightMachine fullyProvisionedFakes BackendInstalled $ \workingDirectory _ ->
        withEnvironmentValue "XDG_CACHE_HOME" (takeDirectory workingDirectory) $ do
          let repository = Repository workingDirectory "coghex" "kanban"
              catalog = (catalogOf [epicIssue 844 []] [] emptyHistory) {catalogRepository = repository}
              environment = (environmentOf catalog) {actionRepository = repository}
          dispatched <- dispatchAction environment (actionRequest ReviewIssue identityUnderTest (TargetByNumber 844))
          either Just (const Nothing) dispatched
            `shouldBe` Just (ActionTargetStructural StructuralTrackerHeader 844)

    -- The repository-wide action has no worker, so nothing downstream of it
    -- would notice the mismatch: a catalog for one repository and an
    -- environment naming another would have it read the wrong repository's
    -- approval controller and report that as this one's queue.
    it "refuses the queue action when the environment names another repository" $
      withPreflightMachine fullyProvisionedFakes BackendInstalled $ \workingDirectory probeLog ->
        withEnvironmentValue "XDG_CACHE_HOME" (takeDirectory workingDirectory) $ do
          let catalog = (catalogOf [] [] emptyHistory) {catalogRepository = Repository workingDirectory "coghex" "kanban"}
              -- Resolved against coghex/kanban, dispatched with an
              -- environment for coghex/other.
              environment =
                (environmentOf catalog) {actionRepository = Repository workingDirectory "coghex" "other"}
          dispatched <- dispatchAction environment (actionRequest ObserveApprovalQueue identityUnderTest TargetRepositoryWide)
          either isRepositoryMismatch (const False) dispatched `shouldBe` True
          -- Nothing was discovered and nothing was run.
          probeInvocations probeLog >>= (`shouldBe` [])

    it "hands back a queue handle without touching the service" $
      withPreflightMachine fullyProvisionedFakes BackendInstalled $ \workingDirectory probeLog ->
        withEnvironmentValue "XDG_CACHE_HOME" (takeDirectory workingDirectory) $ do
          let repository = Repository workingDirectory "coghex" "kanban"
              catalog = (catalogOf [] [] emptyHistory) {catalogRepository = repository}
              environment = (environmentOf catalog) {actionRepository = repository}
          dispatched <- dispatchAction environment (actionRequest ObserveApprovalQueue identityUnderTest TargetRepositoryWide)
          either (const Nothing) actionHandleRepository dispatched `shouldBe` Just repository
          probeInvocations probeLog >>= (`shouldBe` [])

  describe "the approval queue observation" $ do
    -- An unavailable controller is reported as unavailable rather than as a
    -- stopped service, and nothing is started or stopped either way.
    it "reports an undiscoverable controller without flattening it into a state" $
      withPreflightMachine fullyProvisionedFakes BackendInstalled $ \workingDirectory _ -> do
        let repository = Repository workingDirectory "coghex" "kanban"
        observed <- approvalQueueObservation repository
        observed `shouldSatisfy` isUndiscoverable
        approvalQueueObservationMessage observed
          `shouldSatisfy` Text.isInfixOf "issue approval service unavailable"

    -- Requirement 16: an indeterminate observation is never success. A
    -- reported failure is a successful observation of a failure; a controller
    -- that could not be discovered, or a status that could not be read, is
    -- neither a success nor a report.
    it "calls a reported status a success and an unreadable one anything but" $ do
      let reported activity =
            ActionApprovalQueueReport (ApprovalQueueReported (ApprovalStatus ApprovalOn "detail" activity Nothing Nothing) Nothing)
      actionOutcomeSucceeded (reported ApprovalServiceRunning) `shouldBe` True
      -- Including a service the controller says has failed.
      actionOutcomeSucceeded (reported ApprovalServiceChildFailure) `shouldBe` True
      actionOutcomeSucceeded (ActionApprovalQueueReport (ApprovalQueueQueryFailed "timed out"))
        `shouldBe` False
      actionOutcomeSucceeded
        (ActionApprovalQueueReport (ApprovalQueueUndiscoverable (ApprovalHostUnsupported "no manager")))
        `shouldBe` False
      approvalQueueWasReported (ApprovalQueueQueryFailed "timed out") `shouldBe` False

    it "keeps every controller state the status record distinguishes" $ do
      let reported activity detail =
            ApprovalQueueReported (ApprovalStatus ApprovalOn detail activity Nothing Nothing) Nothing
      map
        (\activity -> approvalQueueActivityOf (reported activity "detail"))
        [ ApprovalServiceRunning,
          ApprovalServiceBarrier,
          ApprovalServiceStopped,
          ApprovalServiceChildFailure,
          ApprovalServiceControllerFailure,
          ApprovalServiceUnsupported,
          ApprovalServiceUnknown
        ]
        `shouldBe` map
          Just
          [ ApprovalServiceRunning,
            ApprovalServiceBarrier,
            ApprovalServiceStopped,
            ApprovalServiceChildFailure,
            ApprovalServiceControllerFailure,
            ApprovalServiceUnsupported,
            ApprovalServiceUnknown
          ]

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

notSucceeding :: ActionOutcome -> Bool
notSucceeding = not . actionOutcomeSucceeded

isRunning :: ActionObservation -> Bool
isRunning (ActionRunning _) = True
isRunning _ = False

isCapabilityBlocked :: ActionRefusal -> Bool
isCapabilityBlocked (ActionCapabilityBlocked _ _) = True
isCapabilityBlocked _ = False

isRepositoryMismatch :: ActionRefusal -> Bool
isRepositoryMismatch (ActionRepositoryMismatch _ _) = True
isRepositoryMismatch _ = False

isTurnAlreadyRunning :: ActionRefusal -> Bool
isTurnAlreadyRunning (ActionTurnAlreadyRunning _ _) = True
isTurnAlreadyRunning _ = False

isUndiscoverable :: ApprovalQueueObservation -> Bool
isUndiscoverable (ApprovalQueueUndiscoverable _) = True
isUndiscoverable _ = False

approvalQueueActivityOf :: ApprovalQueueObservation -> Maybe ApprovalActivity
approvalQueueActivityOf (ApprovalQueueReported status _) = Just status.approvalActivity
approvalQueueActivityOf _ = Nothing

capabilityFromReport :: PreflightEnvironment -> PreflightAction -> ActionCapability
capabilityFromReport environment action =
  maybe ActionCapable (ActionIncapable . preflightDiagnostic) (blockingRemediation (actionReport environment action))

everyPreflightAction :: [PreflightAction]
everyPreflightAction =
  [ActionIssueReview origin | origin <- [IssueOriginCodex, IssueOriginClaude, IssueOriginUnmarked, IssueOriginConflicting]]
    <> [ActionIssueRevision origin | origin <- [IssueOriginCodex, IssueOriginClaude]]
    <> [ActionSolve brand | brand <- [CodexSolver, ClaudeSolver]]
    <> [ActionAutoSolve brand | brand <- [CodexSolver, ClaudeSolver]]
    <> [ ActionPullRequestFlow origin action
       | origin <- [PullRequestCodex, PullRequestClaude],
         action <- [PullRequestReview, PullRequestRereview, PullRequestRevision, PullRequestRepair]
       ]

pullRequestFor :: PullRequestAction -> PullRequest
pullRequestFor action = case action of
  PullRequestReview -> markedPullRequest 60 [] ClaudeSolver []
  PullRequestRereview -> markedPullRequest 60 [] ClaudeSolver [label "reviewed:revised"]
  PullRequestRevision -> markedPullRequest 60 [] ClaudeSolver [label defaultWorkflowConfig.changesRequestedLabel]
  PullRequestRepair ->
    (markedPullRequest 60 [] ClaudeSolver [label defaultWorkflowConfig.approvalLabel])
      { pullRequestMergeState = MergeConflicting,
        pullRequestReviewDecision = ReviewApproved
      }

pullRequestForOrigin :: PullRequestOrigin -> PullRequestAction -> PullRequest
pullRequestForOrigin origin action =
  (pullRequestFor action)
    { pullRequestNumber = 60,
      pullRequestBody = "Closes #7\n\n" <> marker
    }
  where
    marker = case origin of
      PullRequestCodex -> "<!-- pr-origin:codex -->"
      PullRequestClaude -> "<!-- pr-origin:claude -->"

-- | A provider whose executable is definitely absent, which is the one
-- observation that blocks rather than merely being unknown.
missingProbe :: ProviderProbe
missingProbe = (readyProviderProbe CodexSolver) {probeExecutable = Nothing}

-- | A fresh machine with both providers, @gh@, and the canonical backend all
-- present, a cache root of its own, and a catalog holding the issue and pull
-- request the dispatch tests act on.
withDispatchMachine :: (ActionEnvironment -> IO result) -> IO result
withDispatchMachine action =
  withPreflightMachine fullyProvisionedFakes BackendInstalled $ \workingDirectory _ ->
    withEnvironmentValue "XDG_CACHE_HOME" (takeDirectory workingDirectory) $ do
      createDirectoryIfMissing True workingDirectory
      let repository = Repository workingDirectory "coghex" "kanban"
          repairable =
            (markedPullRequest 42 [844] CodexSolver [label defaultWorkflowConfig.approvalLabel])
              { pullRequestMergeState = MergeConflicting,
                pullRequestReviewDecision = ReviewApproved
              }
          catalog =
            (catalogOf [baseIssue 844 []] [repairable] emptyHistory) {catalogRepository = repository}
      action ((environmentOf catalog) {actionRepository = repository})

-- | Every worker specification a launch left in this repository's cache.
--
-- The specification is the only artifact that travels to the detached
-- supervisor, so it is what a launch reaching its authority looks like from
-- outside. Under the suite the supervisor is the test executable and exits
-- immediately, which is why the files are the evidence rather than the
-- launch's own return value.
specifications :: Repository -> IO [WorkerSpec]
specifications repository = do
  directory <- workerDirectory repository
  present <- doesDirectoryExist directory
  names <- if present then listDirectory directory else pure []
  decoded <-
    mapM
      (eitherDecodeFileStrict . (directory </>))
      (sortOn id [name | name <- names, ".spec.json" `isSuffixOf` name])
  pure [specification | Right specification <- decoded]

solveTaskOf :: WorkerSpec -> Maybe (Int, SolverBrand)
solveTaskOf specification = case specification.workerTask of
  SolveWorkerTaskKind task -> Just (task.solveWorkerIssueNumber, task.solveWorkerBrand)
  PullRequestWorkerTaskKind _ -> Nothing

pullRequestTaskOf :: WorkerSpec -> Maybe (Int, PullRequestOrigin, PullRequestAction)
pullRequestTaskOf specification = case specification.workerTask of
  PullRequestWorkerTaskKind task ->
    Just (task.pullRequestWorkerNumber, task.pullRequestWorkerOrigin, task.pullRequestWorkerAction)
  SolveWorkerTaskKind _ -> Nothing

-- | A descriptor for a solve worker that was never launched, so a test can
-- address its durable files directly.
descriptorFor :: Repository -> Int -> IO WorkerDescriptor
descriptorFor repository issueNumber = solveWorkerDescriptor repository issueNumber SolveOnly

solveWorkerDescriptor :: Repository -> Int -> SolveWorkflow -> IO WorkerDescriptor
solveWorkerDescriptor repository issueNumber workflow = do
  directory <- workerDirectory repository
  createDirectoryIfMissing True directory
  descriptorForSpec
    WorkerSpec
      { workerId = WorkerId ("solve-" <> Text.pack (show workflow) <> "-" <> Text.pack (show issueNumber)),
        workerRepository = repository,
        workerTask = SolveWorkerTaskKind (SolveWorkerTask issueNumber workflow ClaudeSolver),
        workerExistingSession = Nothing,
        workerExistingLogPath = Nothing,
        workerResumeProvenance = ResumeAnswer,
        workerUserMessage = "",
        workerParent = Nothing,
        workerCreatedAt = epoch,
        workerMaxRuntimeSeconds = 600,
        workerConfigPath = Nothing,
        workerWorkflowConfig = defaultWorkflowConfig,
        workerAssignment = Nothing
      }

-- | A pull-request worker's descriptor, with no durable file written yet.
--
-- The three below are separate so a test can leave exactly the files a
-- scenario is about: a worker discovery can offer needs its specification,
-- while a lease only needs its owner's state to read as live.
pullRequestWorkerDescriptor :: Repository -> Int -> IO WorkerDescriptor
pullRequestWorkerDescriptor repository number = do
  descriptor <-
    descriptorForSpec
      WorkerSpec
        { workerId = WorkerId ("pr-" <> Text.pack (show number)),
          workerRepository = repository,
          workerTask = PullRequestWorkerTaskKind (PullRequestWorkerTask number PullRequestCodex PullRequestRepair),
          workerExistingSession = Nothing,
          workerExistingLogPath = Nothing,
          workerResumeProvenance = ResumeAnswer,
          workerUserMessage = "",
          workerParent = Nothing,
          workerCreatedAt = epoch,
          workerMaxRuntimeSeconds = 600,
          workerConfigPath = Nothing,
          workerWorkflowConfig = defaultWorkflowConfig,
          workerAssignment = Nothing
        }
  directory <- workerDirectory repository
  createDirectoryIfMissing True directory
  pure descriptor

publishWorkerSpec :: WorkerDescriptor -> IO ()
publishWorkerSpec descriptor =
  LazyByteString.writeFile descriptor.workerDescriptorSpecPath (encode descriptor.workerDescriptorSpec)

-- | The heartbeat is current rather than the fixture epoch: the cache
-- collects a terminal worker whose retention window has passed, and a
-- long-expired one would be swept before the test that is about discovering
-- it could look.
publishWorkerState :: WorkerDescriptor -> WorkerStatus -> IO ()
publishWorkerState descriptor status = do
  now <- getCurrentTime
  LazyByteString.writeFile
    descriptor.workerDescriptorStatePath
    ( encode
        WorkerState
          { workerStateId = descriptor.workerDescriptorSpec.workerId,
            workerStateStatus = status,
            workerStateWorkerPid = 1,
            workerStateWorkerIdentity = Nothing,
            workerStateProviderPid = Nothing,
            workerStateProviderIdentity = Nothing,
            workerStateSessionId = Nothing,
            workerStateLogPath = Nothing,
            workerStateHeartbeatAt = now,
            workerStateLastActivity = "repairing",
            workerStateKnownProcesses = []
          }
    )

-- | The durable state a supervisor would have written, hand-placed so
-- observation can be exercised against every status without one.
writeWorkerRecord :: Repository -> Int -> WorkerStatus -> Text -> IO WorkerDescriptor
writeWorkerRecord repository issueNumber status activity = do
  descriptor <- descriptorFor repository issueNumber
  directory <- workerDirectory repository
  createDirectoryIfMissing True directory
  LazyByteString.writeFile
    descriptor.workerDescriptorStatePath
    ( encode
        WorkerState
          { workerStateId = descriptor.workerDescriptorSpec.workerId,
            workerStateStatus = status,
            workerStateWorkerPid = 1,
            workerStateWorkerIdentity = Nothing,
            workerStateProviderPid = Nothing,
            workerStateProviderIdentity = Nothing,
            workerStateSessionId = Just "session-1",
            workerStateLogPath = Nothing,
            workerStateHeartbeatAt = epoch,
            workerStateLastActivity = activity,
            workerStateKnownProcesses = []
          }
    )
  pure descriptor
