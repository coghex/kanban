-- | The model roster reaching the Haskell spawn sites (MODEL-2) and the label
-- every surface shows for the assignment in force (MODEL-3).
--
-- Two things fail independently and are proved separately here. The embedded review thread and its
-- @kanban_run_claude@ tool, which read their own two cells and each refuse on
-- their own terms. And every surface that names an agent renders the display
-- of the assignment actually in force -- the recorded one wherever a session
-- has it, the live cell that surface's own role and provider select otherwise,
-- and no model at all when neither can be resolved.
--
module Spec.Agent.Roster (spec) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Map.Strict as Map
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text
import Kanban.Domain (defaultWorkflowConfig)
import Kanban.Models
  ( Assignment (..),
    ModelRoster (..),
    ProviderName (..),
    RoleName (..),
    assignmentFor,
    decodeRoster,
    defaultRoster,
    encodeRoster,
    providerKey,
    roleKey
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
import Spec.Support.Fixtures (fixtureReviewThread)
import Spec.Support.Process
  ( encodedValue,
    expectNoFurtherClientRequests,
    nextClientRequest,
    soleReviewConnection,
    threadOn,
    runBoundedClaudeCall,
    withFakeClaudeCliUsing,
    withRecordingReviewClientUsing,
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
import System.Directory (doesFileExist)
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
