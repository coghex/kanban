-- | The model roster reaching the Haskell spawn sites (MODEL-2), and the
-- assignment a launch records so a session's whole life runs on it (MODEL-7).
--
-- Four things fail independently and are proved separately here. The launch
-- boundary refuses a roster that cannot supply the cell its routing selected,
-- whether the file was unusable or merely loads a different brand. The
-- assignment that launch resolves is recorded in the worker specification and
-- is the only thing the detached supervisor constructs argv from, proved end
-- to end through a real supervisor and a real provider process. A launch that
-- resumes an existing provider session replays what that session's previous
-- worker recorded and consults no roster at all. And the embedded review
-- thread and its @kanban_run_claude@ tool read their own two cells, each
-- refusing on its own terms.
--
-- The per-argument default-roster expectations live beside the argument
-- builders in "Spec.Agent.Solve" and "Spec.Agent.PullRequestFlow"; only what
-- crosses a boundary is here.
module Spec.Agent.Roster (spec) where

import qualified Data.ByteString.Char8 as ByteString
import Control.Monad (void)
import Data.Maybe (fromMaybe)
import Data.List (isInfixOf, isSuffixOf, sort)
import Brick.BChan (newBChan, readBChan)
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import qualified Data.Text
import Data.Aeson (encode)
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Kanban.Domain (Repository (..), defaultWorkflowConfig)
import Kanban.Models
  ( Assignment (..),
    ModelRoster,
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
    recordAssignment,
    recordedAssignmentCell,
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
    authenticatedClaudeArguments,
    beginIssueReview,
    issueReviseAssignment,
    sendReviewMessage,
  )
import Kanban.Solve (ResumeProvenance (..), SolveWorkflow (..), SolverBrand (..), providerForBrand, solveAssignment)
import Kanban.Solve (SolveEvent (..), SolveOutcome (..))
import Kanban.UI.PullRequest (failPullRequestLaunch, pullRequestStartRefusal)
import Kanban.UI.Session (pullRequestSessionReusable, solvePhaseActive)
import Kanban.UI.Solve (failSolveLaunch)
import Kanban.UI.Types (AgentSession (..), AppEvent (..), AppState (..), PullRequestDetail (..), SolveDetail (..), SolvePhase (..))
import Kanban.UI.Util (launchAssignment, resolvedRosterCellFor)
import Kanban.UI.Worker (recoveredPullRequestSession, recoveredSolveSession)
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerTask (..),
    descriptorForSpec,
    launchPullRequestWorker,
    launchSolveWorker,
    runWorker,
    workerDirectory,
  )
import Spec.Support.App (testAppState)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch, fixtureBoard)
import Spec.Support.Process
  ( encodedValue,
    expectNoFurtherClientRequests,
    nextClientRequest,
    runBoundedClaudeCall,
    withFakeClaudeCliUsing,
    withRecordingReviewClientUsing,
    workerFixtureSpec,
  )
import Spec.Support.Roster
  ( cellOf,
    claudeOnlyRoster,
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
        [rerosteredDefaults, claudeOnlyRoster, codexOnlyRoster, noAgentRoster]

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
    -- cell only for loaded providers, while brand routing stays dual-mode.
    it "refuses a valid roster that does not load the provider this run's routing selected" $ do
      resolvedRosterCellFor (`solveAssignment` CodexSolver) (Right claudeOnlyRoster)
        `shouldSatisfy` refusalMentioning "codex"
      resolvedRosterCellFor (`solveAssignment` ClaudeSolver) (Right codexOnlyRoster)
        `shouldSatisfy` refusalMentioning "claude"
      resolvedRosterCellFor (\roster -> pullRequestAssignment roster PullRequestCodex PullRequestReview) (Right codexOnlyRoster)
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
      let rostered = state {appModelRoster = Right codexOnlyRoster}
      pullRequestStartRefusal rostered PullRequestCodex PullRequestReview
        `shouldSatisfy` maybe False (Data.Text.isInfixOf "claude")
      -- Revision runs on the pull request's own Codex brand, which this
      -- roster does load, so the same press is allowed through.
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
              reviewDecision = launchAssignment Nothing (\roster -> pullRequestAssignment roster PullRequestCodex PullRequestReview) (Right codexOnlyRoster)
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
    it "decodes a spec written without the recorded assignment" $ do
      let fixture = workerFixtureSpec (Repository "/tmp/repo" "coghex" "kanban") (WorkerId "solve-845-legacy") 845
      fixture.workerAssignment `shouldSatisfy` maybe False (const True)
      decodeLegacySpec fixture `shouldBe` Right (fixture {workerAssignment = Nothing})

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
          (\roster -> pullRequestAssignment roster PullRequestCodex PullRequestReview, codexOnlyRoster)
        ]

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
      (recoveredSolveSession state solveDescriptor (baseIssue 848 []) solveTask).sessionDetail.solveSessionAssignment
        `shouldBe` Nothing
      (recoveredPullRequestSession 0 pullRequestDescriptor (basePullRequest 849 [] False []) pullRequestTask).sessionDetail.pullRequestSessionAssignment
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

  describe "the embedded issue review" $ do
    it "starts its thread and its turns on the roster's issue_review codex cell" $ do
      assertReviewPayloadsFrom defaultRoster
      assertReviewPayloadsFrom rerosteredDefaults
      assignmentFor rerosteredDefaults IssueReviewRole CodexProvider
        `shouldNotBe` assignmentFor defaultRoster IssueReviewRole CodexProvider

    -- The Claude cell of issue_review stays unread until MODEL-13, so a
    -- Claude-only roster cannot reach this backend at all.
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

-- | What one supervisor run spawned: the argv each brand's fake executable
-- recorded, 'Nothing' for one that was never run at all, and the durable
-- journal. Both brands are reported because which executable a run reaches is
-- itself under test — an arm proving the recorded provider won has to see
-- that the other brand stayed untouched.
data ProviderRun = ProviderRun
  { runCodexArguments :: Maybe [String],
    runClaudeArguments :: Maybe [String],
    runJournal :: String
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
  where
    recordedArguments path = do
      present <- doesFileExist path
      if present then Just . lines <$> readFile path else pure Nothing

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

-- | The same specification as written by a release that predates
-- 'workerAssignment': its own encoding with that one key removed, so this is
-- the document master leaves on disk rather than an invented one.
decodeLegacySpec :: WorkerSpec -> Either String WorkerSpec
decodeLegacySpec written = eitherDecode (encode (withoutAssignment (toJSON written)))
  where
    withoutAssignment value = case value of
      Object fields -> Object (KeyMap.delete "workerAssignment" fields)
      other -> other

assertReviewPayloadsFrom :: ModelRoster -> IO ()
assertReviewPayloadsFrom roster =
  withRecordingReviewClientUsing roster $ \client wire _ -> do
    let cell = cellOf (assignmentFor roster IssueReviewRole CodexProvider)
    beginIssueReview client 844 `shouldReturn` Right ()
    (threadMethod, threadParams) <- nextClientRequest wire
    threadMethod `shouldBe` "thread/start"
    encodedValue threadParams `shouldMention` ("\"model\":\"" <> cell.assignmentModel <> "\"")
    sendReviewMessage client "thread-1" Nothing "carry on" `shouldReturn` Right ()
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
