-- | The model roster reaching the Haskell spawn sites (MODEL-2), the
-- assignment a launch records so a session's whole life runs on it (MODEL-7),
-- and the label every surface shows for it (MODEL-3).
--
-- Six things fail independently and are proved separately here. The launch
-- boundary refuses a roster that cannot supply the cell its routing selected,
-- whether the file was unusable or merely loads a different brand. The
-- assignment that launch resolves is recorded in the worker specification and
-- is the only thing the detached supervisor constructs argv from, proved end
-- to end through a real supervisor and a real provider process. A launch that
-- resumes an existing provider session replays what that session's previous
-- worker recorded and consults no roster at all. The embedded review thread
-- and its @kanban_run_claude@ tool read their own two cells, each refusing on
-- its own terms. And an assignment edited on the settings screen (MODEL-5)
-- travels the whole way: one decoded key press, the @models.toml@ it wrote,
-- and the provider the next launch reaches. And, last, every surface that
-- names an agent renders the display of the assignment actually in force --
-- the recorded one wherever a session has it, the live cell that surface's
-- own role and provider select otherwise, and no model at all when neither
-- can be resolved.
--
-- The per-argument default-roster expectations live beside the argument
-- builders in "Spec.Agent.Solve" and "Spec.Agent.PullRequestFlow"; only what
-- crosses a boundary is here.
module Spec.Agent.Roster (spec) where

import qualified Data.ByteString.Char8 as ByteString
import Control.Monad (void)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.List (isInfixOf, isSuffixOf, sort)
import Brick (BrickEvent (..))
import Brick.BChan (newBChan, readBChan)
import qualified Graphics.Vty as Vty
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import qualified Data.Text
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Kanban.Domain (Repository (..), defaultWorkflowConfig)
import Kanban.Models
  ( Assignment (..),
    ModelRoster (..),
    ProviderName (..),
    RecordedAssignment (..),
    RoleName (..),
    RosterDefect (..),
    RosterFailure (..),
    RosterLoadError (..),
    assignmentFor,
    decodeRoster,
    defaultRoster,
    encodeRoster,
    loadModelRoster,
    providerKey,
    recordAssignment,
    recordedAssignmentCell,
    roleKey,
    rosterPath,
    saveModelRoster,
  )
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestFlowEvent (..),
    PullRequestOrigin (..),
    pullRequestAssignment,
    pullRequestRole,
  )
import Kanban.Review
  ( CommandBounds (..),
    ReviewClient,
    ReviewEvent (..),
    authenticatedClaudeArguments,
    beginIssueReview,
    claudeStartedEvent,
    claudeTool,
    issueReviseAssignment,
    reviewDeveloperInstructions,
    sendReviewMessage,
  )
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveWorkflow (..),
    SolverBrand (..),
    providerForBrand,
    solveArguments,
    solveAssignment,
  )
import Kanban.Solve (SolveEvent (..), SolveOutcome (..))
import Kanban.UI.Overlay (solveChooserDisplay)
import Kanban.UI.PullRequest (failPullRequestLaunch, freshPullRequestTranscript, pullRequestStartRefusal)
import Kanban.UI.Review (claudeTranscriptStart)
import Kanban.UI.Session (agentSessionEntries, pullRequestSessionReusable, solvePhaseActive)
import Kanban.UI.Settings
  ( RosterWrite (..),
    SettingsOutcome (..),
    applyRosterWrite,
    openSettings,
    settingsInput,
    settingsOutcome,
  )
import Kanban.UI.Solve (failSolveLaunch, freshSolveTranscript)
import Kanban.UI.Types (AgentSession (..), AgentSessionEntry (..), AppEvent (..), AppState (..), ChatTranscript (..), Name, PullRequestDetail (..), SolveDetail (..), SolvePhase (..), SolveSession, withModelRoster)
import Kanban.UI.Util (launchAssignment, pullRequestSessionLabel, resolvedRosterCellFor, solveReviewerDisplay, solveSessionLabel)
import Kanban.UI.Worker (recoveredAutoSolveParentSession, recoveredPullRequestSession, recoveredSolveSession)
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerId (..),
    WorkerParent (..),
    WorkerSpec (..),
    WorkerTask (..),
    descriptorForSpec,
    launchPullRequestWorker,
    launchSolveWorker,
    runWorker,
    workerDirectory,
  )
import Spec.Support.App (testAppState, testPullRequestSession, testSolveSession)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch, fixtureBoard, fixtureReviewThread)
import Spec.Support.Process
  ( encodedValue,
    expectNoFurtherClientRequests,
    nextClientRequest,
    soleReviewConnection,
    threadOn,
    runBoundedClaudeCall,
    withFakeClaudeCliUsing,
    withRecordingReviewClientUsing,
    workerFixtureSpec,
  )
import Spec.Support.Expect (requireLeft, requireRight, shouldNotMention)
import Spec.Support.Roster
  ( cellOf,
    claudeOnlyRoster,
    distinctDisplays,
    codexOnlyRoster,
    noAgentRoster,
    rerosteredDefaults,
  )
import Data.Aeson (Value (..), eitherDecode, toJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import Test.Hspec

spec :: Spec
spec = do
  -- Every non-default assertion below is only worth as much as the fixture
  -- behind it: a roster no file could ever produce would prove the spawn
  -- sites read something the operator cannot actually set. These are the
  -- rosters a real models.toml can hold.
  describe "the fixtures the non-default assertions rest on" $
    it "are rosters the loader would accept from a file" $
      mapM_
        (\roster -> decodeRoster (encodeRoster roster) `shouldBe` Right roster)
        [rerosteredDefaults, distinctDisplays, claudeOnlyRoster, codexOnlyRoster, noAgentRoster]

  describe "the roster a spawn boundary is allowed to launch against" $ do
    -- D-3: a present-but-unusable file refuses and names itself. This is the
    -- total decision the three EventM launch arms are projections of.
    it "refuses a present-but-unusable roster with a message naming the file and the defect" $
      case resolvedRosterCellFor (`solveAssignment` CodexSolver) (Left unusableRoster) of
        Right _ -> expectationFailure "an unusable roster must refuse the launch"
        Left message -> do
          message `shouldMention` "/home/example/.config/kanban/models.toml"
          message `shouldMention` "roles.solve.codex"

    -- A valid roster is not automatically a usable one: validation demands a
    -- cell only for loaded providers, and a run's routing can still select
    -- one it has nothing for.
    --
    -- Which roster reaches that state differs by surface. A solve's brand is
    -- the caller's, so a reduced roster asked for the other brand still
    -- refuses; a pull-request action's provider is the mode's, and
    -- single-agent routes it to the one loaded (issue #589), so the roster
    -- that refuses there is a dual one missing the cell its own routing
    -- selects.
    it "refuses a valid roster that does not load the provider this run's routing selected" $ do
      resolvedRosterCellFor (`solveAssignment` CodexSolver) (Right claudeOnlyRoster)
        `shouldSatisfy` refusalMentioning "codex"
      resolvedRosterCellFor (`solveAssignment` ClaudeSolver) (Right codexOnlyRoster)
        `shouldSatisfy` refusalMentioning "claude"
      resolvedRosterCellFor (\roster -> pullRequestAssignment roster PullRequestCodex PullRequestReview) (Right (withoutCell PrReviewRole ClaudeProvider))
        `shouldSatisfy` refusalMentioning "claude"
      resolvedRosterCellFor (\roster -> assignmentFor roster IssueReviewRole CodexProvider) (Right claudeOnlyRoster)
        `shouldSatisfy` refusalMentioning "codex"
      resolvedRosterCellFor (`solveAssignment` CodexSolver) (Right noAgentRoster)
        `shouldSatisfy` refusalMentioning "codex"

    it "hands back the roster and the cell it resolved once the selected cell resolves" $
      resolvedRosterCellFor (`solveAssignment` ClaudeSolver) (Right claudeOnlyRoster)
        `shouldBe` Right (claudeOnlyRoster, cellOf (solveAssignment claudeOnlyRoster ClaudeSolver))

    -- MODEL-2's role matrix, asserted as a matrix rather than one arm
    -- at a time, so an action added to either side has to be placed here.
    it "maps each action to the role and provider its spawn runs on" $ do
      map pullRequestRole [PullRequestReview, PullRequestRereview] `shouldBe` [PrReviewRole, PrReviewRole]
      map pullRequestRole [PullRequestRevision, PullRequestRepair] `shouldBe` [PrReviseRole, PrReviseRole]
      map providerForBrand [CodexSolver, ClaudeSolver] `shouldBe` [CodexProvider, ClaudeProvider]
      -- The provider is part of what resolves, not something a later caller
      -- recomputes, so each row names the provider its cell was read for.
      solveAssignment defaultRoster CodexSolver
        `shouldBe` (recordAssignment CodexProvider <$> assignmentFor defaultRoster SolveRole CodexProvider)
      pullRequestAssignment defaultRoster PullRequestCodex PullRequestReview
        `shouldBe` (recordAssignment ClaudeProvider <$> assignmentFor defaultRoster PrReviewRole ClaudeProvider)
      pullRequestAssignment defaultRoster PullRequestClaude PullRequestRepair
        `shouldBe` (recordAssignment ClaudeProvider <$> assignmentFor defaultRoster PrReviseRole ClaudeProvider)

  -- A launch boundary is reached with a session already inserted, and
  -- 'solvePhaseActive' counts 'SolveStarting' as live work. A refusal that
  -- only set a notice would strand that session: reopened by the reuse
  -- predicates rather than retried, and never terminalized.
  describe "what a refused launch leaves behind" $ do
    it "settles the solve session with the same diagnostic-then-terminal pair a failed preflight sends" $ do
      let message = "model roster /home/example/.config/kanban/models.toml is invalid"
      channel <- newBChan 4
      failSolveLaunch channel 844 message
      delivered <- (,) <$> readBChan channel <*> readBChan channel
      case delivered of
        (SolveProtocolEvent (SolveDiagnostic diagnosed diagnostic), SolveProtocolEvent (SolveProcessFinished settled (SolveFailed reason))) ->
          [(diagnosed, diagnostic), (settled, reason)] `shouldBe` [(844, message), (844, message)]
        _ -> expectationFailure "expected a solve diagnostic followed by a terminal failure"

    it "settles the pull-request session the same way" $ do
      let message = "model roster does not load provider \"claude\""
      channel <- newBChan 4
      failPullRequestLaunch channel 468 message
      delivered <- (,) <$> readBChan channel <*> readBChan channel
      case delivered of
        (PullRequestProtocolEvent (PullRequestFlowDiagnostic diagnosed diagnostic), PullRequestProtocolEvent (PullRequestProcessFinished settled (SolveFailed reason))) ->
          [(diagnosed, diagnostic), (settled, reason)] `shouldBe` [(468, message), (468, message)]
        _ -> expectationFailure "expected a pull-request diagnostic followed by a terminal failure"

    -- The press that has not created a session yet refuses before it does,
    -- so nothing is left for the reuse predicate to hand back.
    it "refuses a pull-request press before any session exists" $ do
      state <- testAppState (fixtureBoard [])
      let rostered = withModelRoster (Right (withoutCell PrReviewRole ClaudeProvider)) state
      pullRequestStartRefusal rostered PullRequestCodex PullRequestReview
        `shouldSatisfy` maybe False (Data.Text.isInfixOf "claude")
      -- Revision reads pr_revise rather than pr_review, and this roster's
      -- hole is only in the reviewer's cell, so the same press is allowed
      -- through.
      pullRequestStartRefusal rostered PullRequestCodex PullRequestRevision `shouldBe` Nothing

    -- Why that pair is the fix rather than a nicety. A session left at
    -- 'SolveStarting' counts as live, and live is the disjunct that makes the
    -- reuse predicates hand it back whatever the caller now asks for; a
    -- settled one gives way as soon as the request differs.
    it "lands the session in the phase the reuse predicates stop treating as live" $ do
      solvePhaseActive SolveStarting `shouldBe` True
      solvePhaseActive SolveFailedPhase `shouldBe` False
      pullRequestSessionReusable False (solvePhaseActive SolveStarting) PullRequestReview PullRequestRevision epoch laterThanEpoch
        `shouldBe` True
      pullRequestSessionReusable False (solvePhaseActive SolveFailedPhase) PullRequestReview PullRequestRevision epoch laterThanEpoch
        `shouldBe` False

  describe "the worker launch boundary" $ do
    it "starts no worker at all when the roster cannot supply the task's cell" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              solveDecision = launchAssignment Nothing (`solveAssignment` CodexSolver) (Right claudeOnlyRoster)
              reviewDecision = launchAssignment Nothing (\roster -> pullRequestAssignment roster PullRequestCodex PullRequestReview) (Right (withoutCell PrReviewRole ClaudeProvider))
          solveDecision `shouldSatisfy` refusalMentioning "codex"
          reviewDecision `shouldSatisfy` refusalMentioning "claude"
          -- The launch is reached only on the 'Right', which is the shape
          -- both EventM arms have; on the 'Left' nothing downstream runs.
          mapM_
            (\assignment -> void (launchSolveWorker assignment repository 844 SolveOnly CodexSolver Nothing Nothing ResumeAnswer "" Nothing Nothing defaultWorkflowConfig))
            solveDecision
          mapM_
            (\assignment -> void (launchPullRequestWorker assignment repository 42 PullRequestCodex PullRequestReview Nothing Nothing ResumeAnswer "" Nothing Nothing defaultWorkflowConfig))
            reviewDecision
          -- No lease, no spec, no directory entry: the refusal lands before
          -- any durable trace of a worker exists.
          directory <- workerDirectory repository
          present <- doesDirectoryExist directory
          contents <- if present then listDirectory directory else pure []
          contents `shouldBe` []

    -- What the launch leaves on disk is the whole point of this slice: the
    -- specification is the only thing that travels to the supervisor, and
    -- the second artifact that used to describe the same cell is gone.
    --
    -- Asserted on the files rather than on the launch's return value on
    -- purpose. The supervisor a launch spawns is 'getExecutablePath', which
    -- under the suite is the test executable rather than the dashboard, so
    -- the launch always reports a supervisor that exited before
    -- initializing; the specification is written before that spawn is even
    -- attempted, which is exactly the artifact under test.
    it "records the cell it launched against in the spec, and writes no roster snapshot beside it" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repositoryRoot = temporaryRoot </> "repo"
              repository = Repository repositoryRoot "coghex" "kanban"
              solveCellUnderTest = cellOf (solveAssignment rerosteredDefaults CodexSolver)
              reviewCellUnderTest = cellOf (pullRequestAssignment rerosteredDefaults PullRequestCodex PullRequestReview)
          createDirectory repositoryRoot
          void (launchSolveWorker solveCellUnderTest repository 844 SolveOnly CodexSolver Nothing Nothing ResumeAnswer "" Nothing Nothing defaultWorkflowConfig)
          void (launchPullRequestWorker reviewCellUnderTest repository 42 PullRequestCodex PullRequestReview Nothing Nothing ResumeAnswer "" Nothing Nothing defaultWorkflowConfig)
          directory <- workerDirectory repository
          contents <- listDirectory directory
          -- The retired artifact: no launch writes one of these any more.
          filter (".roster.toml" `isSuffixOf`) contents `shouldBe` []
          recorded <- mapM (recordedAssignmentIn directory) (sort (filter (".spec.json" `isSuffixOf`) contents))
          -- Both launch boundaries, each recording what it resolved.
          recorded `shouldBe` [Right reviewCellUnderTest, Right solveCellUnderTest]

    -- A specification written before MODEL-7 still decodes, and its
    -- supervisor then refuses rather than resolving a cell of its own or
    -- reaching for the compiled defaults.
    it "decodes a spec written without either recorded assignment" $ do
      let parent = autoSolveParent (Just (cellOf (solveAssignment rerosteredDefaults ClaudeSolver)))
          fixture =
            (workerFixtureSpec (Repository "/tmp/repo" "coghex" "kanban") (WorkerId "solve-845-legacy") 845)
              {workerParent = Just parent}
      -- Both fields are populated here, so a decoder that dropped either one
      -- could not produce the expectation below by accident.
      fixture.workerAssignment `shouldNotBe` Nothing
      parent.workerParentSolverAssignment `shouldNotBe` Nothing
      decodeLegacySpec fixture
        `shouldBe` Right
          fixture
            { workerAssignment = Nothing,
              workerParent = Just parent {workerParentSolverAssignment = Nothing}
            }

    it "refuses a supervisor whose spec records no assignment rather than resolving a cell of its own" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            fixture =
              (workerFixtureSpec repository (WorkerId "solve-845-noassignment") 845)
                { workerCreatedAt = now,
                  workerAssignment = Nothing
                }
        run <- runWorkerFromSpec temporaryRoot fixture "solve-845-noassignment"
        -- Neither brand was spawned, and the journal says why, naming the file.
        (run.runCodexArguments, run.runClaudeArguments) `shouldBe` (Nothing, Nothing)
        run.runJournal `shouldSatisfy` isInfixOf "records no model assignment"
        run.runJournal `shouldSatisfy` isInfixOf "solve-845-noassignment.spec.json"

  describe "the assignment a detached supervisor constructs argv from" $ do
    it "carries a non-default cell all the way into the provider's own argv" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spawned = cellOf (solveAssignment rerosteredDefaults CodexSolver)
            fixture =
              (workerFixtureSpec repository (WorkerId "solve-846-argv") 846)
                { workerCreatedAt = now,
                  workerAssignment = Just spawned
                }
        run <- runWorkerFromSpec temporaryRoot fixture "solve-846-argv"
        assertProviderRanOn spawned (cellOf (solveAssignment defaultRoster CodexSolver)) run.runCodexArguments run.runJournal
        run.runCodexArguments
          `shouldCarryArgument` Data.Text.unpack ("model_reasoning_effort=\"" <> (recordedAssignmentCell spawned).assignmentEffort <> "\"")

    -- End to end: the cell is resolved at spawn, the operator's roster then
    -- changes underneath it, and the resumed launch still reaches the
    -- provider with the spawn-time model rather than the edited one.
    it "replays the spawn-time cell on a resume the roster no longer agrees with" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            spawned = cellOf (solveAssignment rerosteredDefaults CodexSolver)
            edited = defaultRoster
            replayed = launchAssignment (Just spawned) (`solveAssignment` CodexSolver) (Right edited)
        replayed `shouldBe` Right spawned
        replayed `shouldNotBe` Right (cellOf (solveAssignment edited CodexSolver))
        case replayed of
          Left message -> expectationFailure ("the resume was refused: " <> Data.Text.unpack message)
          Right assignment -> do
            let fixture =
                  (workerFixtureSpec repository (WorkerId "solve-847-resume") 847)
                    { workerCreatedAt = now,
                      workerExistingSession = Just "spawn-time-session",
                      workerAssignment = Just assignment
                    }
            run <- runWorkerFromSpec temporaryRoot fixture "solve-847-resume"
            assertProviderRanOn spawned (cellOf (solveAssignment edited CodexSolver)) run.runCodexArguments run.runJournal

    -- The recorded provider is authoritative too, not just the model and
    -- effort. Proved with a specification whose recorded provider disagrees
    -- with the brand this task's routing selects today, which is the only
    -- state the two implementations differ on: recompute from the routing
    -- and @codex@ runs, obey the record and @claude@ does.
    it "spawns the brand the record names rather than the one the task routes to" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            task = PullRequestWorkerTask 850 PullRequestClaude PullRequestReview
            routed = cellOf (pullRequestAssignment defaultRoster PullRequestClaude PullRequestReview)
            recorded = cellOf (pullRequestAssignment rerosteredDefaults PullRequestClaude PullRequestRevision)
            fixture =
              (workerFixtureSpec repository (WorkerId "pr-850-provider") 850)
                { workerCreatedAt = now,
                  workerTask = PullRequestWorkerTaskKind task,
                  workerAssignment = Just recorded
                }
        -- The fixture is only worth anything if the two really do disagree.
        routed.recordedAssignmentProvider `shouldBe` CodexProvider
        recorded.recordedAssignmentProvider `shouldBe` ClaudeProvider
        run <- runWorkerFromSpec temporaryRoot fixture "pr-850-provider"
        run.runCodexArguments `shouldBe` Nothing
        assertProviderRanOn recorded routed run.runClaudeArguments run.runJournal
        run.runClaudeArguments
          `shouldCarryArgument` Data.Text.unpack (recordedAssignmentCell recorded).assignmentEffort

  -- Replay, refusal, and the legacy migration, as the one total decision
  -- both EventM launch arms are projections of. Both task kinds are asserted,
  -- because the solve and pull-request boundaries are separate code.
  describe "what a resume runs on" $ do
    it "replays a recorded assignment for either task kind, whatever the roster now says" $
      mapM_
        ( \(recorded, cell) -> do
            -- A roster that no longer carries the recorded model...
            launchAssignment (Just recorded) cell (Right defaultRoster) `shouldBe` Right recorded
            -- ...one that no longer loads the provider at all...
            launchAssignment (Just recorded) cell (Right noAgentRoster) `shouldBe` Right recorded
            -- ...and a file that has become unusable since the spawn.
            launchAssignment (Just recorded) cell (Left unusableRoster) `shouldBe` Right recorded
        )
        [ (cellOf (solveAssignment rerosteredDefaults CodexSolver), (`solveAssignment` CodexSolver)),
          ( cellOf (pullRequestAssignment rerosteredDefaults PullRequestCodex PullRequestReview),
            \roster -> pullRequestAssignment roster PullRequestCodex PullRequestReview
          )
        ]

    it "refuses on exactly a fresh launch's terms when the session recorded nothing" $
      mapM_
        ( \(cell, missing) -> do
            launchAssignment Nothing cell (Left unusableRoster)
              `shouldSatisfy` refusalMentioning "/home/example/.config/kanban/models.toml"
            launchAssignment Nothing cell (Right missing) `shouldSatisfy` refusalMentioning "model roster"
            launchAssignment Nothing cell (Right rerosteredDefaults)
              `shouldBe` (either (Left . const "unreachable") Right (cell rerosteredDefaults))
        )
        [ ((`solveAssignment` CodexSolver), claudeOnlyRoster),
          (\roster -> pullRequestAssignment roster PullRequestCodex PullRequestReview, withoutCell PrReviewRole ClaudeProvider)
        ]

    -- An autosolve pull-request worker's reattach restores the /solver's/
    -- session too, from the descriptor of the reviewer. Every value that
    -- identifies the solver has to come from 'WorkerParent': taking the
    -- recorded assignment off that descriptor instead pairs the solver's own
    -- resumable session id with the reviewer's provider, so the revision
    -- this restart is heading for launches the wrong brand.
    it "restores the solver's own assignment when an autosolve PR worker is reattached" $ do
      let repository = Repository "/tmp/repo" "coghex" "kanban"
          solverCell = cellOf (solveAssignment rerosteredDefaults ClaudeSolver)
          reviewerCell = cellOf (pullRequestAssignment rerosteredDefaults PullRequestClaude PullRequestReview)
          task = PullRequestWorkerTask 851 PullRequestClaude PullRequestReview
          parent = autoSolveParent (Just solverCell)
          reviewerSpec =
            (workerFixtureSpec repository (WorkerId "pr-851-autosolve") 851)
              { workerTask = PullRequestWorkerTaskKind task,
                workerParent = Just parent,
                workerAssignment = Just reviewerCell
              }
      -- The fixture only proves anything while the two really do differ.
      solverCell `shouldNotBe` reviewerCell
      state <- testAppState (fixtureBoard [])
      descriptor <- descriptorForSpec reviewerSpec
      let restored = recoveredAutoSolveParentSession state descriptor (baseIssue 851 []) parent task
      -- The resumable id and the cell have to name the same agent.
      (restored.sessionDetail.solveSessionAssignment, restored.sessionDetail.solveSessionId)
        `shouldBe` (parent.workerParentSolverAssignment, parent.workerParentSolverSession)
      -- ...and so does the text this session opens with. The detail is
      -- overridden after the shared builder runs, so a transcript built from
      -- the descriptor would keep naming the reviewer while everything else
      -- named the solver -- which the assertion above cannot see.
      restored.sessionTranscript.fullTranscript
        `shouldMention` ("solver: claude · " <> solverCell.recordedAssignmentDisplay)
      restored.sessionTranscript.fullTranscript
        `shouldNotMention` reviewerCell.recordedAssignmentDisplay
      -- ...and the revision this restart is heading for replays exactly that.
      launchAssignment restored.sessionDetail.solveSessionAssignment (`solveAssignment` ClaudeSolver) (Left unusableRoster)
        `shouldBe` Right solverCell
      -- The reviewer's own session is unaffected and still carries its cell.
      (recoveredPullRequestSession state.appModelRoster 0 descriptor (basePullRequest 851 [] False []) task).sessionDetail.pullRequestSessionAssignment
        `shouldBe` Just reviewerCell

    -- A session reattached from a pre-MODEL-7 specification carries no
    -- assignment, resolves once on its first resume, and every resume after
    -- that replays what it recorded -- proved by making the roster unusable
    -- for the second one.
    it "gains an assignment on the first resume of a legacy session, then replays it" $ do
      let repository = Repository "/tmp/repo" "coghex" "kanban"
          solveTask = SolveWorkerTask 848 SolveOnly CodexSolver
          pullRequestTask = PullRequestWorkerTask 849 PullRequestCodex PullRequestReview
          legacySolve = (workerFixtureSpec repository (WorkerId "solve-848-legacy") 848) {workerAssignment = Nothing}
          legacyPullRequest = legacySolve {workerId = WorkerId "pr-849-legacy", workerTask = PullRequestWorkerTaskKind pullRequestTask}
      state <- testAppState (fixtureBoard [])
      solveDescriptor <- descriptorForSpec legacySolve
      pullRequestDescriptor <- descriptorForSpec legacyPullRequest
      -- What the reattach reads off each legacy specification.
      (recoveredSolveSession state legacySolve.workerAssignment solveDescriptor (baseIssue 848 []) solveTask).sessionDetail.solveSessionAssignment
        `shouldBe` Nothing
      (recoveredPullRequestSession state.appModelRoster 0 pullRequestDescriptor (basePullRequest 849 [] False []) pullRequestTask).sessionDetail.pullRequestSessionAssignment
        `shouldBe` Nothing
      mapM_
        ( \cell -> do
            let first = launchAssignment Nothing cell (Right rerosteredDefaults)
            first `shouldBe` (either (Left . const "unreachable") Right (cell rerosteredDefaults))
            case first of
              Left message -> expectationFailure ("the first resume was refused: " <> Data.Text.unpack message)
              Right recorded -> launchAssignment (Just recorded) cell (Left unusableRoster) `shouldBe` Right recorded
        )
        [ (`solveAssignment` CodexSolver),
          \roster -> pullRequestAssignment roster PullRequestCodex PullRequestReview
        ]

  -- The settings screen and the spawn sites, end to end. Every step is the
  -- real one: the key is decoded by the overlay's own decoder, the roster it
  -- proposes is written by 'saveModelRoster', the file that produced is read
  -- back by the loader, and the next worker is a real detached supervisor
  -- over a fake @codex@ that records its own argv. Nothing between the press
  -- and that argv is stood in for.
  describe "an assignment edited on the settings screen" $
    it "reaches models.toml, the loader, and the next spawned provider" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CONFIG_HOME" (temporaryRoot </> "config") $ do
          now <- getCurrentTime
          -- Opening the overlay focuses the first row, which is the solve
          -- codex cell the launch below resolves.
          opened <- openSettings <$> testAppState (fixtureBoard [])
          opened.appSettingsFocus `shouldBe` Just (SolveRole, CodexProvider)
          let pressed = settingsInput (VtyEvent (Vty.EvKey (Vty.KChar 'l') []) :: BrickEvent Name AppEvent)
          write <- case settingsOutcome pressed opened.appModelRoster opened.appSettingsFocus of
            SettingsRosterWrite proposal -> pure proposal
            other -> fail ("the press earned no roster write: " <> show other)
          saved <- saveModelRoster write.rosterWriteRoster
          saved `shouldBe` Right ()
          let edited = applyRosterWrite saved write opened
          edited.appModelRoster `shouldBe` Right write.rosterWriteRoster

          -- The exact file: byte for byte what the encoder produces, and a
          -- roster the loader accepts back unchanged.
          path <- rosterPath
          written <- readFile path
          written `shouldBe` Data.Text.unpack (encodeRoster write.rosterWriteRoster)
          loadModelRoster `shouldReturn` Right write.rosterWriteRoster

          -- And the next launch runs on it. The rejected cell is the compiled
          -- default the press moved off, so this fails if anything downstream
          -- resolved the defaults instead of the saved roster.
          spawned <- case edited.appModelRoster of
            Right roster -> pure (cellOf (solveAssignment roster CodexSolver))
            Left failure -> fail ("the edited roster did not load: " <> show failure)
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              fixture =
                (workerFixtureSpec repository (WorkerId "solve-852-settings") 852)
                  { workerCreatedAt = now,
                    workerAssignment = Just spawned
                  }
          run <- runWorkerFromSpec temporaryRoot fixture "solve-852-settings"
          assertProviderRanOn spawned (cellOf (solveAssignment defaultRoster CodexSolver)) run.runCodexArguments run.runJournal

  describe "the embedded issue review" $ do
    it "starts its thread and its turns on the roster's issue_review codex cell" $ do
      assertReviewPayloadsFrom defaultRoster
      assertReviewPayloadsFrom rerosteredDefaults
      assignmentFor rerosteredDefaults IssueReviewRole CodexProvider
        `shouldNotBe` assignmentFor defaultRoster IssueReviewRole CodexProvider

    -- The cell a client resolves is its own backend's, and this fixture's
    -- backend is the app-server's, so a Claude-only roster cannot reach it
    -- at all. The Claude backend's own refusal on a Codex-only roster is
    -- the mirror of this, in "Spec.Agent.ClaudeReview".
    it "writes nothing to the app-server when the roster loads no codex provider" $
      withRecordingReviewClientUsing claudeOnlyRoster $ \client wire _ -> do
        started <- beginIssueReview client 844
        started `shouldSatisfy` refusalMentioning "codex"
        expectNoFurtherClientRequests wire

  describe "the kanban_run_claude tool" $ do
    it "spawns the roster's issue_revise claude cell" $
      withFakeClaudeCliUsing rerosteredDefaults recordArgumentsScript fastBounds $ \markerPath client -> do
        answered <- runBoundedClaudeCall boundedCallMicros client "review this"
        answered `shouldSatisfy` either (const False) (const True)
        recorded <- lines <$> readFile markerPath
        let cell = cellOf (issueReviseAssignment rerosteredDefaults)
        cell `shouldNotBe` cellOf (issueReviseAssignment defaultRoster)
        recorded `shouldBe` authenticatedClaudeArguments cell
        recorded `shouldContain` ["--model", Data.Text.unpack cell.assignmentModel]
        recorded `shouldContain` ["--effort", Data.Text.unpack cell.assignmentEffort]

    it "refuses without spawning anything when the roster loads no claude provider" $
      withFakeClaudeCliUsing codexOnlyRoster recordArgumentsScript fastBounds $ \markerPath client -> do
        result <- runBoundedClaudeCall boundedCallMicros client "review this"
        result `shouldSatisfy` refusalMentioning "claude"
        doesFileExist markerPath `shouldReturn` False

  -- MODEL-3. Everything above proves which cell a spawn *runs* on; this
  -- proves the user is shown the same cell. Read against 'distinctDisplays'
  -- rather than the compiled defaults, because the defaults share a display
  -- across the very pairs a wrong-cell wiring would confuse.
  describe "the model a surface displays" $ do
    let roster = Right distinctDisplays
        displayOf role provider = "display:" <> roleKey role <> "." <> providerKey provider

    it "renders the cell its own role and provider select, on every surface" $ do
      -- Chooser row 1 is solve.codex and row 2 is solve.claude.
      solveChooserDisplay roster CodexSolver `shouldBe` displayOf SolveRole CodexProvider
      solveChooserDisplay roster ClaudeSolver `shouldBe` displayOf SolveRole ClaudeProvider

      -- A solve session names its own brand's solve cell...
      solveSessionLabel roster (solveSessionOn CodexSolver Nothing)
        `shouldBe` ("codex · " <> displayOf SolveRole CodexProvider)
      solveSessionLabel roster (solveSessionOn ClaudeSolver Nothing)
        `shouldBe` ("claude · " <> displayOf SolveRole ClaudeProvider)

      -- ...while the reviewer line beside it names the *opposite* brand's
      -- pr_review cell, which is the one thing a same-cell wiring would miss.
      solveReviewerDisplay roster CodexSolver `shouldBe` displayOf PrReviewRole ClaudeProvider
      solveReviewerDisplay roster ClaudeSolver `shouldBe` displayOf PrReviewRole CodexProvider

      -- Review and rereview take pr_review; revision and repair take
      -- pr_revise, which is the conflation this slice ends.
      mapM_
        ( \action ->
            pullRequestSessionLabel Nothing PullRequestClaude action CodexSolver roster
              `shouldBe` ("codex · " <> displayOf PrReviewRole CodexProvider)
        )
        [PullRequestReview, PullRequestRereview]
      mapM_
        ( \action ->
            pullRequestSessionLabel Nothing PullRequestClaude action ClaudeSolver roster
              `shouldBe` ("claude · " <> displayOf PrReviseRole ClaudeProvider)
        )
        [PullRequestRevision, PullRequestRepair]
      pullRequestSessionLabel Nothing PullRequestCodex PullRequestRevision CodexSolver roster
        `shouldBe` ("codex · " <> displayOf PrReviseRole CodexProvider)

      -- The transcript a fresh session opens with, both kinds.
      freshSolveTranscript roster AutoSolve CodexSolver
        `shouldMention` ("solver: codex · " <> displayOf SolveRole CodexProvider)
      freshSolveTranscript roster AutoSolve CodexSolver
        `shouldMention` ("reviewer: " <> displayOf PrReviewRole ClaudeProvider)
      freshPullRequestTranscript roster PullRequestClaude PullRequestRevision ClaudeSolver
        `shouldMention` ("agent: claude · " <> displayOf PrReviseRole ClaudeProvider)

      -- Review prose: the coordinator's own identity is issue_review.codex,
      -- and every Claude clause is issue_revise.claude.
      let instructions = reviewDeveloperInstructions defaultWorkflowConfig distinctDisplays CodexProvider
      -- Each clause separately, so one of them still reading a literal
      -- cannot hide behind another that reads the roster.
      instructions `shouldMention` ("authored by you as " <> displayOf IssueReviewRole CodexProvider)
      instructions `shouldMention` ("unmarked issues default to you as " <> displayOf IssueReviewRole CodexProvider)
      instructions `shouldMention` ("Whenever revision requires Claude " <> displayOf IssueReviseRole ClaudeProvider)
      instructions `shouldMention` ("authored by Claude " <> displayOf IssueReviseRole ClaudeProvider)
      encodedValue (claudeTool distinctDisplays)
        `shouldMention` ("Claude " <> displayOf IssueReviseRole ClaudeProvider)

    -- The backend keeps the roster it was started on for its whole life while
    -- the settings overlay moves what the dashboard holds, so the two diverge
    -- the moment a cell is edited mid-session. The line announcing a tool call
    -- has to name what that tool will really spawn, which is the snapshot of
    -- the client running it.
    it "announces the tool call on the roster of the client actually running it" $ do
      withRecordingReviewClientUsing distinctDisplays $ \client _ _ -> do
        claudeStartDisplay client `shouldBe` displayOf IssueReviseRole ClaudeProvider
        -- The dashboard's own roster carries a different display for that
        -- same cell, and none of it reaches the event.
        claudeStartDisplay client
          `shouldNotBe` (cellOf (issueReviseAssignment defaultRoster)).assignmentDisplay
      -- It says unavailable on exactly the rosters the tool refuses on.
      withRecordingReviewClientUsing codexOnlyRoster $ \client _ _ -> do
        claudeStartDisplay client `shouldBe` "model roster unavailable"
        issueReviseAssignment codexOnlyRoster `shouldSatisfy` either (const True) (const False)

    -- The tool runs in a fork, so the stop or restart of a backend can be
    -- applied before the start event it raced. A line that resolved the cell
    -- when the event was /handled/ would then name a replacement client's
    -- assignment, or none at all, for a call still running on the roster the
    -- emitting client captured. Binding the display at emission is what makes
    -- the interleaving unobservable.
    it "keeps the announced assignment through a backend torn down or replaced under it" $
      withRecordingReviewClientUsing distinctDisplays $ \running _ _ ->
        withRecordingReviewClientUsing defaultRoster $ \replacement _ _ -> do
          runningThread <- threadOn <$> soleReviewConnection running <*> pure "thread-1"
          let started = claudeStartedEvent running runningThread
          -- The two clients really do disagree, so the assertion can tell them
          -- apart at all.
          claudeStartDisplay replacement `shouldNotBe` claudeStartDisplay running
          case started of
            ReviewClaudeStarted thread display -> do
              thread `shouldBe` runningThread
              -- Whatever the backend has become by the time this is handled --
              -- stopped, failed, or this second client -- the event still
              -- carries the first one's cell, and the line renders that.
              display `shouldBe` displayOf IssueReviseRole ClaudeProvider
              claudeTranscriptStart display
                `shouldMention` ("Starting authenticated " <> displayOf IssueReviseRole ClaudeProvider)
              claudeTranscriptStart display `shouldMention` "[sonnet]"
              claudeTranscriptStart display `shouldNotMention` claudeStartDisplay replacement
              claudeTranscriptStart display `shouldNotMention` "model roster unavailable"
            other -> expectationFailure ("expected a Claude start event, got " <> show other)

    it "renders the recorded cell on a solve session's own surfaces, fresh and recovered" $ do
      let recorded = cellOf (solveAssignment distinctDisplays ClaudeSolver)
          task = SolveWorkerTask 853 SolveOnly ClaudeSolver
          repository = Repository "/tmp/repo" "coghex" "kanban"
          fixture = (workerFixtureSpec repository (WorkerId "solve-853") 853) {workerTask = SolveWorkerTaskKind task, workerAssignment = Just recorded}
      state <- withModelRoster roster <$> testAppState (fixtureBoard [])
      descriptor <- descriptorForSpec fixture
      let recovered = recoveredSolveSession state fixture.workerAssignment descriptor (baseIssue 853 []) task
      recovered.sessionTranscript.fullTranscript
        `shouldMention` ("solver: claude · " <> displayOf SolveRole ClaudeProvider)
      -- The header over that recovered session says the same thing.
      solveSessionLabel roster recovered
        `shouldBe` ("claude · " <> displayOf SolveRole ClaudeProvider)

    it "renders the recorded cell on a pull-request session's own surfaces, fresh and recovered" $ do
      let recorded = cellOf (pullRequestAssignment distinctDisplays PullRequestClaude PullRequestRevision)
          task = PullRequestWorkerTask 854 PullRequestClaude PullRequestRevision
          repository = Repository "/tmp/repo" "coghex" "kanban"
          fixture = (workerFixtureSpec repository (WorkerId "pr-854") 854) {workerTask = PullRequestWorkerTaskKind task, workerAssignment = Just recorded}
      descriptor <- descriptorForSpec fixture
      let recovered = recoveredPullRequestSession roster 0 descriptor (basePullRequest 854 [] False []) task
      recovered.sessionTranscript.fullTranscript
        `shouldMention` ("agent: claude · " <> displayOf PrReviseRole ClaudeProvider)

    it "renders the recorded cell on attached process rows and unattached worker rows" $ do
      let solveCell = cellOf (solveAssignment distinctDisplays ClaudeSolver)
          reviewCell = cellOf (pullRequestAssignment distinctDisplays PullRequestClaude PullRequestReview)
          repository = Repository "/tmp/repo" "coghex" "kanban"
          workerTask = SolveWorkerTask 857 SolveOnly ClaudeSolver
          workerSpec =
            (workerFixtureSpec repository (WorkerId "solve-857") 857)
              { workerTask = SolveWorkerTaskKind workerTask,
                workerAssignment = Just solveCell
              }
      descriptor <- descriptorForSpec workerSpec
      base <- testAppState (fixtureBoard [])
      let attachedSolve = (testSolveSession (baseIssue 855 []) SolveRunning) {sessionDetail = (testSolveSession (baseIssue 855 []) SolveRunning).sessionDetail {solveSessionAssignment = Just solveCell}}
          attachedPullRequest =
            let session = testPullRequestSession (basePullRequest 856 [] False []) SolveRunning
             in session {sessionDetail = session.sessionDetail {pullRequestSessionAssignment = Just reviewCell}}
          state =
            (withModelRoster roster base)
              { appSolveSessions = Map.fromList [(855, attachedSolve)],
                appPullRequestReviewSessions = Map.fromList [(856, attachedPullRequest)],
                appWorkers = Map.fromList [(WorkerId "solve-857", descriptor)]
              }
          providers = map (.agentSessionProvider) (agentSessionEntries state)
      -- One row per session plus the unattached worker's own row, each naming
      -- the cell that session or specification actually holds.
      providers
        `shouldMatchList` [ "claude · " <> displayOf SolveRole ClaudeProvider,
                            "codex · " <> displayOf PrReviewRole CodexProvider,
                            "claude · " <> displayOf SolveRole ClaudeProvider
                          ]

    -- D-7's ordering, on the display rather than on argv: a record outlives
    -- the roster it was read from, and only a session that has none resolves.
    it "keeps a recorded display through a changed and then an unusable roster" $ do
      let recorded = cellOf (solveAssignment distinctDisplays CodexSolver)
          session = solveSessionOn CodexSolver (Just recorded)
      recorded `shouldNotBe` cellOf (solveAssignment defaultRoster CodexSolver)
      solveSessionLabel (Right defaultRoster) session
        `shouldBe` ("codex · " <> displayOf SolveRole CodexProvider)
      solveSessionLabel (Left unusableRoster) session
        `shouldBe` ("codex · " <> displayOf SolveRole CodexProvider)
      solveSessionLabel (Right codexOnlyRoster) session
        `shouldBe` ("codex · " <> displayOf SolveRole CodexProvider)
      -- The legacy session beside it has nothing to replay and resolves live.
      solveSessionLabel (Right defaultRoster) (solveSessionOn CodexSolver Nothing)
        `shouldBe` ("codex · " <> (cellOf (solveAssignment defaultRoster CodexSolver)).recordedAssignmentDisplay)

    -- Requirement 5. Two shapes reach it: a file that will not load at all,
    -- and a valid roster that simply does not carry the brand this surface
    -- names. Neither may answer with a compiled default.
    it "names no model where the roster cannot supply the cell" $ do
      let unresolvable =
            [ solveChooserDisplay (Left unusableRoster) CodexSolver,
              solveChooserDisplay (Right claudeOnlyRoster) CodexSolver,
              -- The reviewer a Claude solve hands to in dual mode is
              -- pr_review.codex, and this roster loads Codex without
              -- carrying that cell.
              solveReviewerDisplay (Right (withoutCell PrReviewRole CodexProvider)) ClaudeSolver,
              solveSessionLabel (Left unusableRoster) (solveSessionOn CodexSolver Nothing),
              solveSessionLabel (Right claudeOnlyRoster) (solveSessionOn CodexSolver Nothing),
              pullRequestSessionLabel Nothing PullRequestClaude PullRequestReview CodexSolver (Right (withoutCell PrReviewRole CodexProvider)),
              freshSolveTranscript (Left unusableRoster) AutoSolve CodexSolver,
              freshPullRequestTranscript (Right (withoutCell PrReviewRole CodexProvider)) PullRequestClaude PullRequestReview CodexSolver
            ]
      mapM_ (`shouldMention` "model roster unavailable") unresolvable
      mapM_ (\rendered -> mapM_ (rendered `shouldNotMention`) namedModels) unresolvable

    -- The non-visual arm: prose cannot be dimmed, so it says so instead, and
    -- the Codex identity clauses beside it stay resolved because
    -- 'startReviewClient' refuses to build a client without that cell.
    --
    -- The roster that reaches it is a dual one whose Claude revision cell is
    -- missing, not a Codex-only one: an install that does not /load/ Claude
    -- describes no handoff at all (issue #589), so it is a loaded-but-
    -- unresolvable cell that leaves prose with a model to name and none to
    -- put there.
    it "states the Claude assignment is unavailable in review prose without naming a model" $ do
      let instructions = reviewDeveloperInstructions defaultWorkflowConfig unassignedClaudeRevision CodexProvider
          description = encodedValue (claudeTool unassignedClaudeRevision)
      instructions `shouldMention` "model roster unavailable"
      description `shouldMention` "model roster unavailable"
      mapM_ (\rendered -> mapM_ (rendered `shouldNotMention`) claudeModels) [instructions, description]
      -- ...and the Codex clauses still name their own cell.
      instructions
        `shouldMention` ("authored by you as " <> (cellOf (assignmentFor unassignedClaudeRevision IssueReviewRole CodexProvider)).assignmentDisplay)

    it "names the spawned cell in every kanban_run_claude diagnostic" $ do
      let display = (cellOf (issueReviseAssignment distinctDisplays)).assignmentDisplay
      withFakeClaudeCliUsing distinctDisplays ["sleep 30 &", "printf 'boom\\n' >&2", "exit 3"] fastBounds $ \_ client -> do
        message <- requireLeft "expected a nonzero claude exit to fail" =<< runBoundedClaudeCall boundedCallMicros client "review"
        message `shouldMention` ("Claude " <> display <> " exited with status 3")
      withFakeClaudeCliUsing distinctDisplays ["sleep 30 &", "echo $! > \"$CLAUDE_CHILD_MARKER\"", "printf '%s' 'partial'", "exit 0"] fastBounds $ \_ client -> do
        output <- requireRight "expected a truncated capture to stay a success" =<< runBoundedClaudeCall boundedCallMicros client "review"
        output `shouldMention` ("Claude " <> display <> " exited successfully")
      withFakeClaudeCliUsing distinctDisplays ["echo $$ > \"$CLAUDE_CHILD_MARKER\"", "sleep 30"] fastBounds $ \_ client -> do
        message <- requireLeft "expected a claude reviewer past its deadline to time out" =<< runBoundedClaudeCall boundedCallMicros client "review"
        message `shouldBe` ("Claude " <> display <> " revision agent timed out after ten minutes")

    -- The two Kanban.Solve surfaces that had no assertion at all before this
    -- slice, and would therefore have passed the src/ literal grep on a
    -- wrong-cell or leftover-shim wiring.
    it "names the resolved cell in the solver prompt and the invocation log" $ do
      let cell = recordedAssignmentCell (cellOf (solveAssignment distinctDisplays CodexSolver))
          arguments =
            solveArguments 858 SolveOnly CodexSolver Nothing (Repository "/tmp/repo" "coghex" "kanban") defaultWorkflowConfig cell Nothing ResumeAnswer ""
      unwords arguments
        `shouldContain` Data.Text.unpack ("You are the canonical codex · " <> displayOf SolveRole CodexProvider <> " solver")
      withTemporaryCacheRoot $ \temporaryRoot -> do
        now <- getCurrentTime
        let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
            recorded = cellOf (solveAssignment distinctDisplays ClaudeSolver)
            fixture =
              (workerFixtureSpec repository (WorkerId "solve-859") 859)
                { workerCreatedAt = now,
                  workerTask = SolveWorkerTaskKind (SolveWorkerTask 859 SolveOnly ClaudeSolver),
                  workerAssignment = Just recorded
                }
        run <- runWorkerFromSpec temporaryRoot fixture "solve-859"
        run.runSessionLog
          `shouldContain` Data.Text.unpack ("claude · " <> displayOf SolveRole ClaudeProvider <> " · solve")

    -- Requirement 6: the wording changes this slice does and does not make,
    -- pinned against the compiled defaults so an unintended one is a failure.
    it "keeps every default label byte-identical except the two this slice corrects" $ do
      let defaults = Right defaultRoster
      solveChooserDisplay defaults CodexSolver `shouldBe` "gpt-5.4 high"
      solveChooserDisplay defaults ClaudeSolver `shouldBe` "Sonnet 5 high"
      solveSessionLabel defaults (solveSessionOn CodexSolver Nothing) `shouldBe` "codex · gpt-5.4 high"
      solveReviewerDisplay defaults CodexSolver `shouldBe` "Opus 5 xhigh"
      solveReviewerDisplay defaults ClaudeSolver `shouldBe` "GPT-5.6-Terra xhigh"
      pullRequestSessionLabel Nothing PullRequestClaude PullRequestReview CodexSolver defaults
        `shouldBe` "codex · GPT-5.6-Terra xhigh"
      withRecordingReviewClientUsing defaultRoster $ \client _ _ ->
        claudeTranscriptStart (claudeStartDisplay client)
          `shouldBe` "\n[sonnet] Starting authenticated Sonnet 5 high…\n"
      -- The PR-revision label is the correction: the flow has always spawned
      -- pr_revise, while the label read solve.claude and said "Sonnet 5 high".
      pullRequestSessionLabel Nothing PullRequestClaude PullRequestRevision ClaudeSolver defaults
        `shouldBe` "claude · Sonnet 5 xhigh"
      pullRequestSessionLabel Nothing PullRequestClaude PullRequestRepair ClaudeSolver defaults
        `shouldBe` "claude · Sonnet 5 xhigh"
      -- And the prose correction: one spelling of the codex cell, the
      -- roster's own, where the literal said "GPT-5.4 high".
      reviewDeveloperInstructions defaultWorkflowConfig defaultRoster CodexProvider
        `shouldMention` "authored by you as gpt-5.4 high; Claude-origin amendment content is authored by Claude Sonnet 5 high; unmarked issues default to you as gpt-5.4 high."
      encodedValue (claudeTool defaultRoster)
        `shouldMention` "Run the authenticated Claude Sonnet 5 high specification-revision agent"


-- | The display the event 'Kanban.Review.claudeStartedEvent' raises carries,
-- read back out of the event itself rather than recomputed, so these
-- assertions cannot pass against a payload the emitter never built.
claudeStartDisplay :: ReviewClient -> Text
claudeStartDisplay client = case claudeStartedEvent client (fixtureReviewThread "thread-probe") of
  ReviewClaudeStarted _ display -> display
  other -> error ("expected a Claude start event, got " <> show other)

-- | A solve session on one brand, optionally carrying a recorded assignment,
-- which is the only thing its label surfaces read besides the roster.
solveSessionOn :: SolverBrand -> Maybe RecordedAssignment -> SolveSession
solveSessionOn brand recorded =
  let session = testSolveSession (baseIssue 855 []) SolveRunning
   in session
        { sessionDetail =
            session.sessionDetail
              { solveSessionBrand = brand,
                solveSessionAssignment = recorded
              }
        }

-- | Every model name the compiled defaults carry. A surface that could not
-- resolve its cell must contain none of them: naming any one would be the
-- fallback to 'defaultRoster' requirement 5 forbids.
namedModels :: [Text]
namedModels =
  [ assignment.assignmentDisplay
  | assignment <- Map.elems defaultRoster.rosterAssignments
  ]

-- | A dual roster that loads both providers and still cannot supply one named
-- cell -- 'UnassignedCell' rather than 'UnloadedProvider'.
--
-- The shape every refusal in this module needs now that single-agent mode
-- routes each pull-request action to the provider it loads (issue #589): a
-- reduced roster no longer misses the cell its own routing selects, so the
-- roster that does is a dual one with a hole in it. A validated file cannot
-- reach this state; a value edited in process can, and the refusal has to
-- survive it.
withoutCell :: RoleName -> ProviderName -> ModelRoster
withoutCell role provider =
  defaultRoster {rosterAssignments = Map.delete (role, provider) defaultRoster.rosterAssignments}

-- | The one that leaves review prose describing a handoff whose model it
-- cannot name, which is what the unavailable wording exists for.
unassignedClaudeRevision :: ModelRoster
unassignedClaudeRevision = withoutCell IssueReviseRole ClaudeProvider

-- | The subset of those a Claude-naming review string must not fall back to.
claudeModels :: [Text]
claudeModels =
  [ assignment.assignmentDisplay
  | ((_, provider), assignment) <- Map.toList defaultRoster.rosterAssignments,
    provider == ClaudeProvider
  ]

-- | What one supervisor run spawned: the argv each brand's fake executable
-- recorded, 'Nothing' for one that was never run at all, and the durable
-- journal. Both brands are reported because which executable a run reaches is
-- itself under test — an arm proving the recorded provider won has to see
-- that the other brand stayed untouched.
data ProviderRun = ProviderRun
  { runCodexArguments :: Maybe [String],
    runClaudeArguments :: Maybe [String],
    runJournal :: String,
    -- | Every full session log the run opened, concatenated. The
    -- @invocation-started@ line the supervisor writes there is the one solve
    -- surface that reaches no argv and no event, so it is read from the file
    -- the run really produced rather than from a re-derived string.
    runSessionLog :: String
  }

-- | Drives a real supervisor over fake @codex@ and @claude@ executables that
-- record their own argv, from a specification written exactly where
-- 'Kanban.Worker.launchWorker' writes one. Nothing here writes or reads a
-- roster: the supervisor's only source is the assignment inside that
-- specification.
runWorkerFromSpec :: FilePath -> WorkerSpec -> String -> IO ProviderRun
runWorkerFromSpec temporaryRoot fixture identifier = do
  let repository = fixture.workerRepository
      binaryRoot = temporaryRoot </> "bin"
      codexLog = temporaryRoot </> "codex-arguments"
      claudeLog = temporaryRoot </> "claude-arguments"
      workerRoot = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban"
      specPath = workerRoot </> identifier <> ".spec.json"
      eventPath = workerRoot </> identifier <> ".events.jsonl"
  createDirectory repository.repositoryRoot
  createDirectory binaryRoot
  createDirectoryIfMissing True workerRoot
  writeFakeProvider
    (binaryRoot </> "codex")
    "CODEX_ARGUMENT_LOG"
    "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}"
  writeFakeProvider
    (binaryRoot </> "claude")
    "CLAUDE_ARGUMENT_LOG"
    "{\"type\":\"result\",\"subtype\":\"success\",\"result\":\"done\"}"
  originalPath <- maybe "" id <$> lookupEnv "PATH"
  withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
    withEnvironmentValue "CODEX_ARGUMENT_LOG" codexLog $
      withEnvironmentValue "CLAUDE_ARGUMENT_LOG" claudeLog $
        withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
          LazyByteString.writeFile specPath (encode fixture)
          runWorker specPath `shouldReturn` Right ()
          ProviderRun
            <$> recordedArguments codexLog
            <*> recordedArguments claudeLog
            <*> readFile eventPath
            <*> sessionLogs (temporaryRoot </> "kanban" </> "logs")
  where
    recordedArguments path = do
      present <- doesFileExist path
      if present then Just . lines <$> readFile path else pure Nothing
    sessionLogs logRoot = do
      present <- doesDirectoryExist logRoot
      if not present
        then pure ""
        else do
          directories <- listDirectory logRoot
          concat <$> mapM (\directory -> logsIn (logRoot </> directory)) directories
    logsIn directory = do
      entries <- listDirectory directory
      concat <$> mapM (readFile . (directory </>)) entries

writeFakeProvider :: FilePath -> ByteString.ByteString -> ByteString.ByteString -> IO ()
writeFakeProvider path logVariable completionLine = do
  ByteString.writeFile
    path
    ( ByteString.unlines
        [ "#!/bin/sh",
          "printf '%s\\n' \"$@\" > \"$" <> logVariable <> "\"",
          "printf '%s\\n' '" <> completionLine <> "'"
        ]
    )
  setFileMode path 0o700

-- | The provider ran on @expected@ rather than on the cell @rejected@ names.
-- The journal travels with the assertion so a run that never spawned reports
-- why instead of failing on an empty list.
assertProviderRanOn :: RecordedAssignment -> RecordedAssignment -> Maybe [String] -> String -> Expectation
assertProviderRanOn expected rejected arguments journal = case arguments of
  Nothing -> expectationFailure ("the fake provider recorded no arguments; journal was:\n" <> journal)
  Just recorded -> do
    let cell = recordedAssignmentCell expected
        other = recordedAssignmentCell rejected
    cell `shouldNotBe` other
    recorded `shouldContain` ["--model", Data.Text.unpack cell.assignmentModel]
    recorded `shouldNotContain` ["--model", Data.Text.unpack other.assignmentModel]

-- | One exact argv entry a run must carry. The effort reaches argv in a
-- different shape per brand -- inside a @--config@ pair for Codex, as the
-- @--effort@ value for Claude -- so each arm names its own rather than
-- sharing a match loose enough to pass on prompt text that happens to
-- contain the word.
shouldCarryArgument :: Maybe [String] -> String -> Expectation
shouldCarryArgument arguments argument = fromMaybe [] arguments `shouldContain` [argument]

-- | The assignment the specification at @directory\/name@ records, or why
-- there is not one. Read off disk rather than off the descriptor a launch
-- returned, so this is the document a separate supervisor process meets.
recordedAssignmentIn :: FilePath -> FilePath -> IO (Either String RecordedAssignment)
recordedAssignmentIn directory name = do
  decoded <- (eitherDecode <$> LazyByteString.readFile (directory </> name)) :: IO (Either String WorkerSpec)
  pure (decoded >>= maybe (Left (name <> " records no assignment")) Right . (.workerAssignment))

-- | The autosolve parent a discovered pull-request worker carries: the
-- solver's own brand, resumable session, log, and — the field under test —
-- the cell that solver was launched on.
autoSolveParent :: Maybe RecordedAssignment -> WorkerParent
autoSolveParent assignment =
  WorkerParent
    { workerParentIssueNumber = 851,
      workerParentReviewRound = 1,
      workerParentSolverBrand = ClaudeSolver,
      workerParentSolverSession = Just "solver-session",
      workerParentSolverLogPath = Just "/tmp/solver.jsonl",
      workerParentStartedAt = epoch,
      workerParentKnownPullRequests = mempty,
      workerParentPullRequest = Nothing,
      workerParentSolverAssignment = assignment
    }

-- | The same specification as written by a release that predates the two
-- recorded-assignment fields: its own encoding with those keys removed, so
-- this is the document master leaves on disk rather than an invented one.
decodeLegacySpec :: WorkerSpec -> Either String WorkerSpec
decodeLegacySpec written = eitherDecode (encode (withoutAssignments (toJSON written)))
  where
    withoutAssignments value = case value of
      Object fields ->
        Object
          ( KeyMap.mapWithKey stripParent (KeyMap.delete "workerAssignment" fields)
          )
      other -> other
    stripParent key value
      | key /= "workerParent" = value
      | Object fields <- value = Object (KeyMap.delete "workerParentSolverAssignment" fields)
      | otherwise = value

assertReviewPayloadsFrom :: ModelRoster -> IO ()
assertReviewPayloadsFrom roster =
  withRecordingReviewClientUsing roster $ \client wire _ -> do
    let cell = cellOf (assignmentFor roster IssueReviewRole CodexProvider)
    connection <- soleReviewConnection client
    beginIssueReview client 844 `shouldReturn` Right ()
    (threadMethod, threadParams) <- nextClientRequest wire
    threadMethod `shouldBe` "thread/start"
    encodedValue threadParams `shouldMention` ("\"model\":\"" <> cell.assignmentModel <> "\"")
    sendReviewMessage client (threadOn connection "thread-1") Nothing "carry on" `shouldReturn` Right ()
    (turnMethod, turnParams) <- nextClientRequest wire
    turnMethod `shouldBe` "turn/start"
    encodedValue turnParams `shouldMention` ("\"effort\":\"" <> cell.assignmentEffort <> "\"")

-- | The fake @claude@ every tool arm above runs: it records its own argv at
-- the harness's marker path, so the arm that must not spawn can prove the
-- file was never created.
recordArgumentsScript :: [ByteString.ByteString]
recordArgumentsScript =
  [ "printf '%s\\n' \"$@\" > \"$CLAUDE_CHILD_MARKER\"",
    "printf '%s' 'done'"
  ]

-- | Far under the production ten minutes, and far over what a fake costs.
fastBounds :: CommandBounds
fastBounds = CommandBounds {commandDeadlineMicros = 3000000, commandCaptureGraceMicros = 400000}

boundedCallMicros :: Int
boundedCallMicros = 20000000

-- | Any instant after 'epoch': what a pull request updated since the session
-- was launched for it looks like.
laterThanEpoch :: UTCTime
laterThanEpoch = addUTCTime 60 epoch

unusableRoster :: RosterLoadError
unusableRoster =
  RosterLoadError
    "/home/example/.config/kanban/models.toml"
    (RosterInvalid [MissingAssignment SolveRole CodexProvider])

refusalMentioning :: String -> Either Text value -> Bool
refusalMentioning needle result = case result of
  Left message -> needle `isInfixOf` Data.Text.unpack message
  Right _ -> False

shouldMention :: Text -> Text -> Expectation
shouldMention subject needle =
  Data.Text.unpack subject `shouldSatisfy` isInfixOf (Data.Text.unpack needle)
