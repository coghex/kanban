-- | The model roster reaching the Haskell spawn sites (MODEL-2).
--
-- Three things fail independently and are proved separately here. The launch
-- boundary refuses a roster that cannot supply the cell its routing selected,
-- whether the file was unusable or merely loads a different brand. The
-- snapshot the launcher writes beside a worker's spec is the roster the
-- detached supervisor resolves argv from, proved end to end through a real
-- supervisor and a real provider process. And the embedded review thread and
-- its @kanban_run_claude@ tool read their own two cells, each refusing on its
-- own terms.
--
-- The per-argument default-roster expectations live beside the argument
-- builders in "Spec.Agent.Solve" and "Spec.Agent.PullRequestFlow"; only what
-- crosses a boundary is here.
module Spec.Agent.Roster (spec) where

import qualified Data.ByteString.Char8 as ByteString
import Data.List (isInfixOf)
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
    RoleName (..),
    RosterDefect (..),
    RosterFailure (..),
    RosterLoadError (..),
    assignmentFor,
    decodeRoster,
    defaultRoster,
    encodeRoster,
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
import Kanban.UI.Types (AppEvent (..), AppState (..), SolvePhase (..))
import Kanban.UI.Util (resolvedRosterFor)
import Kanban.Worker
  ( WorkerId (..),
    WorkerSpec (..),
    assignmentForTask,
    descriptorForSpec,
    launchPullRequestWorker,
    launchSolveWorker,
    readWorkerRoster,
    runWorker,
    workerDirectory,
    writeWorkerRoster,
  )
import Spec.Support.App (testAppState)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Fixtures (epoch, fixtureBoard)
import Spec.Support.Process
  ( encodedValue,
    expectNoFurtherClientRequests,
    nextClientRequest,
    runBoundedClaudeCall,
    withFakeClaudeCliUsing,
    withRecordingReviewClientUsing,
    workerFixtureSpec,
    writeWorkerRosterSnapshot,
  )
import Spec.Support.Roster
  ( cellOf,
    claudeOnlyRoster,
    codexOnlyRoster,
    noAgentRoster,
    rerosteredDefaults,
  )
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
      case resolvedRosterFor (`solveAssignment` CodexSolver) (Left unusableRoster) of
        Right _ -> expectationFailure "an unusable roster must refuse the launch"
        Left message -> do
          message `shouldMention` "/home/example/.config/kanban/models.toml"
          message `shouldMention` "roles.solve.codex"

    -- A valid roster is not automatically a usable one: validation demands a
    -- cell only for loaded providers, while brand routing stays dual-mode.
    it "refuses a valid roster that does not load the provider this run's routing selected" $ do
      resolvedRosterFor (`solveAssignment` CodexSolver) (Right claudeOnlyRoster)
        `shouldSatisfy` refusalMentioning "codex"
      resolvedRosterFor (`solveAssignment` ClaudeSolver) (Right codexOnlyRoster)
        `shouldSatisfy` refusalMentioning "claude"
      resolvedRosterFor (\roster -> pullRequestAssignment roster PullRequestCodex PullRequestReview) (Right codexOnlyRoster)
        `shouldSatisfy` refusalMentioning "claude"
      resolvedRosterFor (\roster -> assignmentFor roster IssueReviewRole CodexProvider) (Right claudeOnlyRoster)
        `shouldSatisfy` refusalMentioning "codex"
      resolvedRosterFor (`solveAssignment` CodexSolver) (Right noAgentRoster)
        `shouldSatisfy` refusalMentioning "codex"

    it "hands back the roster itself once the selected cell resolves" $
      resolvedRosterFor (`solveAssignment` ClaudeSolver) (Right claudeOnlyRoster)
        `shouldBe` Right claudeOnlyRoster

    -- Requirement 5's role matrix, asserted as a matrix rather than one arm
    -- at a time, so an action added to either side has to be placed here.
    it "maps each action to the role and provider its spawn runs on" $ do
      map pullRequestRole [PullRequestReview, PullRequestRereview] `shouldBe` [PrReviewRole, PrReviewRole]
      map pullRequestRole [PullRequestRevision, PullRequestRepair] `shouldBe` [PrReviseRole, PrReviseRole]
      map providerForBrand [CodexSolver, ClaudeSolver] `shouldBe` [CodexProvider, ClaudeProvider]
      solveAssignment defaultRoster CodexSolver `shouldBe` assignmentFor defaultRoster SolveRole CodexProvider
      pullRequestAssignment defaultRoster PullRequestCodex PullRequestReview
        `shouldBe` assignmentFor defaultRoster PrReviewRole ClaudeProvider
      pullRequestAssignment defaultRoster PullRequestClaude PullRequestRepair
        `shouldBe` assignmentFor defaultRoster PrReviseRole ClaudeProvider

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
          solveLaunch <- launchSolveWorker claudeOnlyRoster repository 844 SolveOnly CodexSolver Nothing Nothing ResumeAnswer "" Nothing Nothing defaultWorkflowConfig
          reviewLaunch <- launchPullRequestWorker codexOnlyRoster repository 42 PullRequestCodex PullRequestReview Nothing Nothing ResumeAnswer "" Nothing Nothing defaultWorkflowConfig
          solveLaunch `shouldSatisfy` refusalMentioning "codex"
          reviewLaunch `shouldSatisfy` refusalMentioning "claude"
          -- No lease, no spec, no snapshot: the refusal lands before any
          -- durable trace of a worker exists.
          directory <- workerDirectory repository
          present <- doesDirectoryExist directory
          contents <- if present then listDirectory directory else pure []
          contents `shouldBe` []

    it "reads the launcher's snapshot back as the same roster, and resolves the task's cell from it" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              fixture = workerFixtureSpec repository (WorkerId "solve-844-snapshot") 844
          directory <- workerDirectory repository
          createDirectoryIfMissing True directory
          descriptor <- descriptorForSpec fixture
          writeWorkerRoster descriptor rerosteredDefaults `shouldReturn` Right ()
          readWorkerRoster descriptor `shouldReturn` Right rerosteredDefaults
          assignmentForTask rerosteredDefaults fixture.workerTask
            `shouldBe` Right (cellOf (solveAssignment rerosteredDefaults CodexSolver))

    it "refuses a supervisor whose snapshot is absent rather than loading a roster of its own" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $ do
          let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
              fixture = workerFixtureSpec repository (WorkerId "solve-845-nosnapshot") 845
          descriptor <- descriptorForSpec fixture
          absent <- readWorkerRoster descriptor
          absent `shouldSatisfy` refusalMentioning "roster snapshot"

  describe "the snapshot a detached supervisor constructs argv from" $
    it "carries a non-default cell all the way into the provider's own argv" $
      withTemporaryCacheRoot $ \temporaryRoot -> do
        arguments <- runWorkerRecordingProviderArguments temporaryRoot
        let cell = cellOf (solveAssignment rerosteredDefaults CodexSolver)
            compiled = cellOf (solveAssignment defaultRoster CodexSolver)
        cell `shouldNotBe` compiled
        arguments `shouldContain` ["--model", Data.Text.unpack cell.assignmentModel]
        arguments `shouldContain` [Data.Text.unpack ("model_reasoning_effort=\"" <> cell.assignmentEffort <> "\"")]
        arguments `shouldNotContain` ["--model", Data.Text.unpack compiled.assignmentModel]

  describe "the embedded issue review" $ do
    it "starts its thread and its turns on the roster's issue_review codex cell" $ do
      assertReviewPayloadsFrom defaultRoster
      assertReviewPayloadsFrom rerosteredDefaults
      assignmentFor rerosteredDefaults IssueReviewRole CodexProvider
        `shouldNotBe` assignmentFor defaultRoster IssueReviewRole CodexProvider

    -- Requirement 7: the Claude cell of issue_review stays unread until
    -- MODEL-13, so a Claude-only roster cannot reach this backend at all.
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

-- | Drives a real supervisor over a fake @codex@ that records its own argv,
-- against a snapshot written exactly where 'Kanban.Worker.launchWorker'
-- writes one. Nothing here re-reads a roster: the supervisor's only source
-- is the file this wrote.
runWorkerRecordingProviderArguments :: FilePath -> IO [String]
runWorkerRecordingProviderArguments temporaryRoot = do
  let repository = Repository (temporaryRoot </> "repo") "coghex" "kanban"
      binaryRoot = temporaryRoot </> "bin"
      fakeCodex = binaryRoot </> "codex"
      argumentLog = temporaryRoot </> "codex-arguments"
      specPath = temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban" </> "solve-846-argv.spec.json"
  -- The fixture's deadline is measured from its creation time, so it has to
  -- be now rather than the epoch or the watchdog cancels before the spawn.
  now <- getCurrentTime
  let fixture = (workerFixtureSpec repository (WorkerId "solve-846-argv") 846) {workerCreatedAt = now}
  createDirectory repository.repositoryRoot
  createDirectory binaryRoot
  createDirectoryIfMissing True (temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban")
  ByteString.writeFile
    fakeCodex
    ( ByteString.unlines
        [ "#!/bin/sh",
          "printf '%s\\n' \"$@\" > \"$CODEX_ARGUMENT_LOG\"",
          "printf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"done\"}}'"
        ]
    )
  setFileMode fakeCodex 0o700
  originalPath <- maybe "" id <$> lookupEnv "PATH"
  withEnvironmentValue "XDG_CACHE_HOME" temporaryRoot $
    withEnvironmentValue "CODEX_ARGUMENT_LOG" argumentLog $
      withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) $ do
        LazyByteString.writeFile specPath (encode fixture)
        writeWorkerRosterSnapshot fixture rerosteredDefaults
        runWorker specPath `shouldReturn` Right ()
        recorded <- doesFileExist argumentLog
        if recorded
          then lines <$> readFile argumentLog
          else do
            journal <- readFile (temporaryRoot </> "kanban" </> "workers" </> "coghex-kanban" </> "solve-846-argv.events.jsonl")
            expectationFailure ("the fake provider recorded no arguments; journal was:\n" <> journal)
            pure []

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
