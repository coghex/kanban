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
import Data.Text (Text)
import Data.Time (getCurrentTime)
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
    assignmentFor,
    decodeRoster,
    defaultRoster,
    encodeRoster,
    providerKey,
    recordAssignment,
    recordedAssignmentCell,
    roleKey
  )
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestOrigin (..),
    pullRequestAssignment,
    pullRequestRole
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
    sendReviewMessage
  )
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerId (..),
    WorkerParent (..),
    WorkerSpec (..),
    WorkerTask (..),
    WorkerDeadline (..),
    launchPullRequestWorker,
    launchSolveWorker,
    runWorker,
    workerDirectory
  )
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveWorkflow (..),
    SolverBrand (..),
    providerForBrand,
    solveArguments,
    solveAssignment,
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Fixtures (epoch, fixtureReviewThread)
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

  describe "the role and provider a spawn runs on" $ do
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

  describe "the worker launch boundary" $ do
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
          void (launchSolveWorker solveCellUnderTest repository 844 SolveOnly CodexSolver Nothing Nothing ResumeAnswer "" Nothing Nothing defaultWorkflowConfig (WorkerDeadline 600) Nothing Nothing)
          void (launchPullRequestWorker reviewCellUnderTest repository 42 PullRequestCodex PullRequestReview Nothing Nothing ResumeAnswer "" Nothing Nothing defaultWorkflowConfig (WorkerDeadline 600) Nothing Nothing)
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

  describe "the embedded issue review" $ do
    it "starts its thread and its turns on the roster's issue_review codex cell" $ do
      assertReviewPayloadsFrom defaultRoster
      assertReviewPayloadsFrom rerosteredDefaults
      assignmentFor rerosteredDefaults IssueReviewRole CodexProvider
        `shouldNotBe` assignmentFor defaultRoster IssueReviewRole CodexProvider

    -- Requirement 7 of #614. The case above resolves its expectation from the
    -- same roster the payload came from, so it passes on any pair of values.
    -- The compiled default is therefore pinned separately, and on the payload
    -- the app-server actually receives rather than on the cell.
    it "carries the compiled issue_review codex assignment into those payloads" $
      withRecordingReviewClientUsing defaultRoster $ \client wire _ -> do
        connection <- soleReviewConnection client
        fmap (() <$) (beginIssueReview client 844) `shouldReturn` Right ()
        (_, threadParams) <- nextClientRequest wire
        encodedValue threadParams `shouldMention` "\"model\":\"gpt-6-astra\""
        sendReviewMessage client (threadOn connection "thread-1") Nothing "carry on" `shouldReturn` Right ()
        (_, turnParams) <- nextClientRequest wire
        encodedValue turnParams `shouldMention` "\"effort\":\"xhigh\""

    -- The cell a client resolves is its own backend's, and this fixture's
    -- backend is the app-server's, so a Claude-only roster cannot reach it
    -- at all. The Claude backend's own refusal on a Codex-only roster is
    -- the mirror of this, in "Spec.Agent.ClaudeReview".
    it "writes nothing to the app-server when the roster loads no codex provider" $
      withRecordingReviewClientUsing claudeOnlyRoster $ \client wire _ -> do
        started <- ((() <$) <$> beginIssueReview client 844)
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

    -- The same split as the review payload above: that case reads its
    -- expectation off the roster it spawned from, so the compiled default the
    -- tool really runs on is pinned here.
    it "carries the compiled issue_revise claude assignment into that argv" $
      withFakeClaudeCliUsing defaultRoster recordArgumentsScript fastBounds $ \markerPath client -> do
        answered <- runBoundedClaudeCall boundedCallMicros client "review this"
        answered `shouldSatisfy` either (const False) (const True)
        recorded <- lines <$> readFile markerPath
        recorded `shouldContain` ["--model", "claude-fable-5-1"]
        recorded `shouldContain` ["--effort", "high"]

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
    let displayOf role provider = "display:" <> roleKey role <> "." <> providerKey provider

    it "renders the cell its own role and provider select, in the review prose and the tool description" $ do
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
              -- carries the first one's cell.
              display `shouldBe` displayOf IssueReviseRole ClaudeProvider
            other -> expectationFailure ("expected a Claude start event, got " <> show other)

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

    -- Requirement 6: the wording change this slice makes, pinned against the
    -- compiled defaults so an unintended one is a failure.
    it "keeps the default review prose byte-identical except the correction this slice makes" $ do
      -- And the prose correction: one spelling of the codex cell, the
      -- roster's own, where the literal said "GPT-5.4 high", without reviving
      -- the Kimi or Google amendment path the board and registry refuse.
      let instructions = reviewDeveloperInstructions defaultWorkflowConfig defaultRoster CodexProvider
      instructions
        `shouldMention` "authored by you as GPT-6-Astra xhigh; Claude-origin amendment content is authored by Claude Fable 5.1 high; unmarked issues default to you as GPT-6-Astra xhigh."
      instructions
        `shouldMention` "If the live issue body declares <!-- issue-origin:kimi --> and the live labels select REVISION, STOP immediately."
      instructions
        `shouldMention` "If the live issue body declares <!-- issue-origin:google --> and the live labels select REVISION, STOP immediately."
      instructions `shouldNotMention` "kimi-origin amendment content is authored by you"
      instructions `shouldNotMention` "google-origin amendment content is authored by you"
      encodedValue (claudeTool defaultRoster)
        `shouldMention` "Run the authenticated Claude Fable 5.1 high specification-revision agent"

-- | The display the event 'Kanban.Review.claudeStartedEvent' raises carries,
-- read back out of the event itself rather than recomputed, so these
-- assertions cannot pass against a payload the emitter never built.
claudeStartDisplay :: ReviewClient -> Text
claudeStartDisplay client = case claudeStartedEvent client (fixtureReviewThread "thread-probe") of
  ReviewClaudeStarted _ display -> display
  other -> error ("expected a Claude start event, got " <> show other)

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
    fmap (() <$) (beginIssueReview client 844) `shouldReturn` Right ()
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

shouldMention :: Text -> Text -> Expectation
shouldMention subject needle =
  Data.Text.unpack subject `shouldSatisfy` isInfixOf (Data.Text.unpack needle)

refusalMentioning :: String -> Either Text value -> Bool
refusalMentioning needle result = case result of
  Left message -> needle `isInfixOf` Data.Text.unpack message
  Right _ -> False
