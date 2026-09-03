-- | What a Kanban whose roster loads exactly one provider routes to it
-- (issue #589).
--
-- The mirror of "Spec.OperatingMode", which covers the mode that loads none.
-- Where that module asks what a board refuses, this one asks what a board
-- /selects/: every pull-request action, the embedded review's backend and the
-- prose it runs under, a fresh solve, the usage probes and the sidebar blocks
-- they feed, @--ping@'s brand, and the preflight checks each of those
-- actually depends on.
--
-- Two variants throughout, never one standing in for the other. A Codex-only
-- install and a Claude-only install are the same mode and opposite answers,
-- and an assertion made against one alone would pass on routing that still
-- named a brand rather than reading the roster.
--
-- Dual mode is the negative control in every section, because requirement 9
-- is that it does not move: the same routing, the same cells, the same
-- probes.
--
-- Everything here is a pure function the corresponding @EventM@ arm or @IO@
-- entry point only projects -- 'agentForAction' and 'pullRequestAssignment'
-- for routing, 'recordedPullRequestBrand' for a worker that already exists,
-- 'embeddedReviewProvider' for the review backend, 'solveChooserDecision' for
-- the chooser, 'usageProviders' for the probes, 'pingBrandRefusal' for the
-- command line, and 'actionReport' for readiness -- so the whole matrix is
-- settled with no terminal, no subprocess, and no provider account.
module Spec.SingleAgentMode (spec) where

import Data.Aeson (Value (..))
import qualified Data.Map.Strict as Map
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Text (Text)
import qualified Data.Text
import Kanban.Domain (UsageProvider (..), defaultWorkflowConfig)
import Kanban.Models
  ( Assignment (..),
    AssignmentUnavailable,
    ModelRoster (..),
    OperatingMode (..),
    ProviderName (..),
    RecordedAssignment (..),
    RoleName (..),
    assignmentFor,
    defaultRoster,
    operatingModeFor,
    providerKey,
    recordAssignment,
  )
import Kanban.Ping (PingBrand (..), pingBrandName, pingBrandRefusal)
import Kanban.Preflight
  ( IssueOrigin (..),
    PreflightAction (..),
    PreflightProblem (..),
    ProviderProbe (..),
  )
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestOrigin (..),
    agentForAction,
    expectedPullRequestOrigin,
    pullRequestAssignment,
    recordedPullRequestBrand,
    solveReviewerAssignment,
  )
import Kanban.Review (EmbeddedReviewBackend (..), claudeToolName, embeddedReviewCell, embeddedReviewProvider, githubToolName, questionToolName, reviewDeveloperInstructions)
import Kanban.Solve (ProviderAdapter (..), SolverBrand (..), adapterFor, providerForBrand)
import Kanban.UI.Board (drawBase, usageSidebarWidth)
import Kanban.UI.Refresh (usageRefreshProviders)
import Kanban.UI.Solve (SolveChooserDecision (..), solveChooserDecision)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types (withModelRoster)
import Kanban.Usage (usageProviders)
import Spec.Support.App (testAppState)
import Spec.Support.Fixtures (fixtureBoard, testOptions)
import Spec.Support.Preflight (blockedProblemsIn, blockedProblemsWith, readyPreflightEnvironment, readyProviderProbe, withClaudeProbe, withCodexProbe)
import Spec.Support.Render (renderWidgetLines)
import Spec.Support.Roster (cellOf, claudeOnlyRoster, codexOnlyRoster)
import Test.Hspec

spec :: Spec
spec = describe "single-agent operating mode" $ do
  routingSpec
  workerSpec
  reviewSpec
  solveSpec
  usageSpec
  pingSpec
  preflightSpec

-- ---------------------------------------------------------------------------
-- The two installs
-- ---------------------------------------------------------------------------

-- | One install the mode has: the roster that derives it, the provider it
-- loads, the brand that provider spawns, and the other brand, which nothing
-- in this mode may reach.
--
-- Every section iterates this rather than naming a brand, so an arm that
-- passed by hard-coding one would fail on the other.
data Variant = Variant
  { variantName :: String,
    variantRoster :: ModelRoster,
    variantProvider :: ProviderName,
    variantBrand :: SolverBrand,
    variantUnloaded :: SolverBrand
  }

variants :: [Variant]
variants =
  [ Variant "codex-only" codexOnlyRoster CodexProvider CodexSolver ClaudeSolver,
    Variant "claude-only" claudeOnlyRoster ClaudeProvider ClaudeSolver CodexSolver
  ]

-- | The mode a variant's own roster derives, taken through 'operatingModeFor'
-- rather than written as a constructor, so a fixture that stopped deriving
-- single-agent fails here instead of being asserted against a mode it does
-- not have.
variantMode :: Variant -> OperatingMode
variantMode = operatingModeFor . variantRoster

-- | Every pull-request route, as origin and action.
everyRoute :: [(PullRequestOrigin, PullRequestAction)]
everyRoute =
  [ (origin, action)
  | origin <- [PullRequestCodex, PullRequestClaude],
    action <- [PullRequestReview, PullRequestRereview, PullRequestRevision, PullRequestRepair]
  ]

-- | Which roster role an action reads, written out rather than reached
-- through 'Kanban.PullRequestFlow.pullRequestRole', so this is a control over
-- that split rather than a restatement of it.
roleOfAction :: PullRequestAction -> RoleName
roleOfAction PullRequestRevision = PrReviseRole
roleOfAction PullRequestRepair = PrReviseRole
roleOfAction PullRequestReview = PrReviewRole
roleOfAction PullRequestRereview = PrReviewRole

-- ---------------------------------------------------------------------------
-- Pull-request routing
-- ---------------------------------------------------------------------------

routingSpec :: Spec
routingSpec = describe "the pull-request actions it collapses" $ do
  -- Requirement 2, and the review's first spec addition: both origins crossed
  -- with all four actions, for both singleton rosters. The origin marker is
  -- still written in this mode (requirement 5, D-12); what changes is that
  -- routing stops reading it.
  it "runs every action of every origin on the one loaded provider" $
    sequence_
      [ (variant.variantName, origin, action, agentForAction (variantMode variant) origin action)
          `shouldBe` (variant.variantName, origin, action, variant.variantBrand)
      | variant <- variants,
        (origin, action) <- everyRoute
      ]

  -- The cell as well as the brand. A launch records the provider it resolved
  -- through, so routing that moved without the lookup moving with it would
  -- spawn one provider on the other's model -- and the role still splits
  -- authored work from the canonical gate, which the mode does not collapse.
  it "resolves each action's cell on that provider, in the role the action takes" $
    sequence_
      [ (variant.variantName, origin, action, pullRequestAssignment variant.variantRoster origin action)
          `shouldBe` (variant.variantName, origin, action, cellFor variant (roleOfAction action))
      | variant <- variants,
        (origin, action) <- everyRoute
      ]

  -- The negative control. Requirement 9: dual routing is untouched, so the
  -- same matrix still crosses brands exactly as it did.
  it "leaves dual mode crossing brands on the same matrix" $
    sequence_
      [ (origin, action, agentForAction DualMode origin action) `shouldBe` (origin, action, expected)
      | (origin, action) <- everyRoute,
        let expected = case (origin, action) of
              (PullRequestCodex, PullRequestReview) -> ClaudeSolver
              (PullRequestCodex, PullRequestRereview) -> ClaudeSolver
              (PullRequestCodex, _) -> CodexSolver
              (PullRequestClaude, PullRequestReview) -> CodexSolver
              (PullRequestClaude, PullRequestRereview) -> CodexSolver
              (PullRequestClaude, _) -> ClaudeSolver
      ]

  -- Requirement 5 and D-12: the marker a solve stamps is unchanged, and it is
  -- the routing above that stops reading it. Asserted together with that
  -- routing, because the pair is the requirement: a mode that stopped writing
  -- markers would leave every pull request it opened unroutable by any install
  -- that later loads both providers.
  it "still expects the solving brand's own origin marker, and then ignores it" $
    sequence_
      [ (variant.variantName, expectedPullRequestOrigin variant.variantBrand, routed)
          `shouldBe` (variant.variantName, stamped variant, variant.variantBrand)
      | variant <- variants,
        let routed = agentForAction (variantMode variant) (opposite (stamped variant)) PullRequestReview
      ]

  -- Requirement 7 on the one reviewer identity a solve session shows before
  -- any review has started: an autosolve run in this mode hands its pull
  -- request to the provider it loads, whichever brand it solved on, so the
  -- name it carries is that provider's pr_review cell.
  it "names the loaded provider as the reviewer an autosolve run will use" $
    sequence_
      [ (variant.variantName, brand, solveReviewerAssignment variant.variantRoster brand)
          `shouldBe` (variant.variantName, brand, cellFor variant PrReviewRole)
      | variant <- variants,
        brand <- [CodexSolver, ClaudeSolver]
      ]

-- | The marker a solve on this install's provider stamps, written out rather
-- than reached through 'expectedPullRequestOrigin', so the assertion above is
-- a control over that function rather than a restatement of it.
stamped :: Variant -> PullRequestOrigin
stamped variant = case variant.variantProvider of
  CodexProvider -> PullRequestCodex
  ClaudeProvider -> PullRequestClaude

-- | The marker this install would /not/ stamp, which is what a routing that
-- still read markers would send to the unloaded brand.
opposite :: PullRequestOrigin -> PullRequestOrigin
opposite PullRequestCodex = PullRequestClaude
opposite PullRequestClaude = PullRequestCodex

-- | The recorded cell an install's own provider takes for one role, resolved
-- from the roster under test rather than written as a model name.
cellFor :: Variant -> RoleName -> Either AssignmentUnavailable RecordedAssignment
cellFor variant role =
  recordAssignment variant.variantProvider
    <$> assignmentFor variant.variantRoster role variant.variantProvider

-- ---------------------------------------------------------------------------
-- Workers that already exist
-- ---------------------------------------------------------------------------

workerSpec :: Spec
workerSpec = describe "the workers it does not relabel" $ do
  -- The review's third spec addition, and D-7. A worker's provider is
  -- whatever its own specification recorded: the process rows, the recovered
  -- session, and every protocol event read the record, so a models.toml
  -- edited between the launch and the event -- including one that moved the
  -- install between modes -- cannot rename the process that is still running.
  it "replays a running worker's recorded provider, whatever the live mode says" $
    sequence_
      [ (mode', origin, action, provider, recordedPullRequestBrand mode' (Just recorded) origin action)
          `shouldBe` (mode', origin, action, provider, brandOf provider)
      | mode' <- DualMode : NoAgentMode : map variantMode variants,
        (origin, action) <- everyRoute,
        provider <- [CodexProvider, ClaudeProvider],
        let recorded = recordAssignment provider (cellOf (assignmentFor defaultRoster (roleOfAction action) provider))
      ]

  -- The fallback, and only the fallback: a specification written before the
  -- record existed has nothing to replay, so it takes the live routing its
  -- mode gives -- which in single-agent is the loaded provider.
  it "falls back to live routing only for a record that names no assignment" $
    sequence_
      [ (variant.variantName, origin, action, recordedPullRequestBrand (variantMode variant) Nothing origin action)
          `shouldBe` (variant.variantName, origin, action, variant.variantBrand)
      | variant <- variants,
        (origin, action) <- everyRoute
      ]

  it "falls back to dual routing in dual mode, unchanged" $
    sequence_
      [ (origin, action, recordedPullRequestBrand DualMode Nothing origin action)
          `shouldBe` (origin, action, agentForAction DualMode origin action)
      | (origin, action) <- everyRoute
      ]
  where
    brandOf CodexProvider = CodexSolver
    brandOf ClaudeProvider = ClaudeSolver

-- ---------------------------------------------------------------------------
-- The embedded issue review
-- ---------------------------------------------------------------------------

reviewSpec :: Spec
reviewSpec = describe "the embedded review it starts" $ do
  -- Requirement 3, in both variants: the Codex app-server in a Codex-only
  -- install and the stream-json session (#586) in a Claude-only one. The
  -- backend is asserted rather than only the provider, because it is the
  -- backend that decides the process shape and the protocol.
  it "starts the loaded provider's own backend in each variant" $
    sequence_
      [ (variant.variantName, backendLabelFor (variantMode variant))
          `shouldBe` (variant.variantName, Just (expectedLabel variant))
      | variant <- variants
      ]

  it "leaves dual mode on the Codex app-server" $
    map backendLabelFor [DualMode, NoAgentMode] `shouldBe` [Just "codex app-server", Just "codex app-server"]

  -- The boundary that resolves a cell and refuses before starting anything.
  -- It must ask about the provider the spawn will actually route to: a
  -- boundary fixed on Codex refuses a Claude-only install for want of a cell
  -- it would never have run on, and its backend never starts at all.
  --
  -- The repository review host is what starts that backend now (SAG-10), and
  -- it consults this very function to do it — so the boundary and the spawn
  -- are one expression rather than two that agree today.
  --
  -- Asserted as the same cell 'Kanban.Review.startReviewClient' resolves,
  -- rather than as "some Right", so a boundary that started resolving a
  -- different provider's cell would fail here even while still succeeding.
  it "resolves the launch boundary's cell on the provider the spawn will route to" $
    sequence_
      [ (variant.variantName, embeddedReviewCell variant.variantRoster)
          `shouldBe` ( variant.variantName,
                       Right (cellOf (assignmentFor variant.variantRoster IssueReviewRole variant.variantProvider))
                     )
      | variant <- variants
      ]

  it "leaves that boundary on issue_review.codex in dual mode" $
    embeddedReviewCell defaultRoster
      `shouldBe` Right (cellOf (assignmentFor defaultRoster IssueReviewRole CodexProvider))

  -- The negative control the pair above needs: the boundary still refuses,
  -- and still names the provider it was asking about, when the routed cell is
  -- genuinely absent.
  it "still refuses when the routed provider has no issue_review cell" $
    embeddedReviewCell noIssueReviewClaude
      `shouldSatisfy` either (Data.Text.isInfixOf "claude") (const False)

  -- The integration half the pure arms cannot cover -- a Claude-only install
  -- started through the real routing, reaching the real stream-json backend
  -- and running a turn on it -- lives in "Spec.Agent.ClaudeReview", beside
  -- the fake CLI and the launch assertions it needs.

  -- Requirement 7 on the coordinator's own identity. A thread told it is
  -- issue_review.codex while running on Claude would be telling the reviewing
  -- model it is something it is not.
  it "names the running coordinator's own cell in its instructions" $
    sequence_
      [ (variant.variantName, coordinatorDisplay variant `Data.Text.isInfixOf` instructionsFor variant)
          `shouldBe` (variant.variantName, True)
      | variant <- variants
      ]

  -- The other half of requirement 7: a single-provider install describes no
  -- handoff. A Claude-only thread has no kanban_run_claude tool at all, and a
  -- Codex-only one loads no Claude agent to reach through it, so an
  -- instruction to call it would describe work that could only be refused.
  --
  -- The directive rather than the bare tool name, because the prose that
  -- replaces it says outright that the tool is not there, and a name-only
  -- search cannot tell an instruction from its own denial.
  it "instructs no cross-brand handoff in either variant" $
    sequence_
      [ (variant.variantName, ("you MUST call " <> claudeToolName) `Data.Text.isInfixOf` instructionsFor variant)
          `shouldBe` (variant.variantName, False)
      | variant <- variants
      ]

  it "says the coordinator authors every amendment itself, and that the tool is absent" $
    sequence_
      [ (variant.variantName, map (`Data.Text.isInfixOf` instructionsFor variant) claims)
          `shouldBe` (variant.variantName, [True, True])
      | variant <- variants,
        let claims = ["author every amendment yourself", "There is no " <> claudeToolName <> " tool in this thread"]
      ]

  -- The negative control: dual mode still describes the handoff, and still
  -- registers the tool that performs it.
  it "leaves dual mode describing the handoff and registering its tool" $ do
    let dual = reviewDeveloperInstructions defaultWorkflowConfig defaultRoster CodexProvider
    claudeToolName `Data.Text.isInfixOf` dual `shouldBe` True
    "REVISION switches back to the issue author's brand" `Data.Text.isInfixOf` dual `shouldBe` True

  -- The tool registry, not only the prose. The review's sixth spec addition
  -- asks the client to resolve its tools from the loaded provider, and a
  -- registered tool nothing describes is the same defect the other way round.
  --
  -- The names rather than the count, so a tool quietly swapped for another
  -- cannot pass by leaving the list the same length.
  it "registers the nested revision tool only where the handoff exists" $ do
    map (toolNamesOf defaultRoster) [CodexProvider, ClaudeProvider]
      `shouldBe` [ [Just questionToolName, Just claudeToolName, Just githubToolName],
                   [Just questionToolName, Just githubToolName]
                 ]
    sequence_
      [ (variant.variantName, toolNamesOf variant.variantRoster variant.variantProvider)
          `shouldBe` (variant.variantName, [Just questionToolName, Just githubToolName])
      | variant <- variants
      ]
  where
    backendLabelFor :: OperatingMode -> Maybe Text
    backendLabelFor mode =
      (.backendLabel) <$> (adapterFor (embeddedReviewProvider mode)).adapterEmbeddedReview
    expectedLabel variant = case variant.variantProvider of
      CodexProvider -> "codex app-server"
      ClaudeProvider -> "claude stream-json session"
    instructionsFor variant =
      reviewDeveloperInstructions
        defaultWorkflowConfig
        variant.variantRoster
        (embeddedReviewProvider (variantMode variant))
    coordinatorDisplay variant =
      (cellOf (assignmentFor variant.variantRoster IssueReviewRole variant.variantProvider)).assignmentDisplay
    -- A roster that loads Claude and carries no issue_review cell for it, so
    -- the boundary's refusal is about an absent cell rather than an unloaded
    -- provider.
    noIssueReviewClaude =
      claudeOnlyRoster
        { rosterAssignments = Map.delete (IssueReviewRole, ClaudeProvider) claudeOnlyRoster.rosterAssignments
        }
    toolNamesOf roster provider =
      map toolName ((adapterFor provider).adapterReviewTools roster defaultWorkflowConfig)
    toolName (Object fields) = case KeyMap.lookup (Key.fromString "name") fields of
      Just (String value) -> Just value
      _ -> Nothing
    toolName _ = Nothing

-- ---------------------------------------------------------------------------
-- Starting a solve
-- ---------------------------------------------------------------------------

solveSpec :: Spec
solveSpec = describe "the chooser it does not open" $ do
  -- Requirement 4. There is nothing to choose between, so a fresh solve
  -- starts on the loaded provider rather than showing a box whose only live
  -- digit is the brand this install already runs on.
  it "starts a fresh solve on the loaded provider without asking" $
    sequence_
      [ (variant.variantName, solveChooserDecision (variantMode variant))
          `shouldBe` (variant.variantName, SolveChooserAuto variant.variantBrand)
      | variant <- variants
      ]

  -- The negative control, and the boundary the review's seventh spec addition
  -- draws: dual mode still presents both rows, and no-agent -- whose bindings
  -- 'Kanban.UI.Keys.availableIn' has already refused -- is not turned into a
  -- silent launch by this arm.
  it "still opens the chooser in dual and no-agent mode" $
    map solveChooserDecision [DualMode, NoAgentMode]
      `shouldBe` [SolveChooserOpen, SolveChooserOpen]

-- ---------------------------------------------------------------------------
-- The usage surfaces
-- ---------------------------------------------------------------------------

usageSpec :: Spec
usageSpec = describe "the usage accounts it reads" $ do
  -- Requirement 6 and the review's fourth spec addition. One list serves the
  -- startup refresh, `u`, the sidebar's ↻, the sidebar's own blocks, and both
  -- the cached and the forced-live @--usage@, so covering it covers all of
  -- them: the other brand's account is not this install's to spend a request
  -- on.
  it "reads only the loaded provider's account" $
    sequence_
      [ (variant.variantName, usageProviders (variantMode variant))
          `shouldBe` (variant.variantName, [expectedAccount variant])
      | variant <- variants
      ]

  it "reads both in dual mode and none with no provider loaded" $
    map usageProviders [DualMode, NoAgentMode] `shouldBe` [[Codex, Claude], []]

  -- The refresh helper is that same list, not a second one, which is what
  -- keeps a probe from being started for a block the sidebar never draws.
  it "starts a refresh for exactly the accounts it reads" $
    sequence_
      [ (mode', usageRefreshProviders mode') `shouldBe` (mode', usageProviders mode')
      | mode' <- DualMode : NoAgentMode : map variantMode variants
      ]

  -- And the drawing. A cached entry for the unloaded brand may still sit on
  -- disk; what it must not do is appear in the sidebar as though this install
  -- had read it.
  it "draws a sidebar block for the loaded provider alone" $
    sequence_
      [ do
          board <- testAppState (fixtureBoard [])
          let drawn = sidebarText (withModelRoster (Right variant.variantRoster) board)
          (variant.variantName, accountName (expectedAccount variant) `Data.Text.isInfixOf` drawn)
            `shouldBe` (variant.variantName, True)
          (variant.variantName, accountName (unloadedAccount variant) `Data.Text.isInfixOf` drawn)
            `shouldBe` (variant.variantName, False)
      | variant <- variants
      ]

  it "draws both blocks in dual mode" $ do
    board <- testAppState (fixtureBoard [])
    let drawn = sidebarText (withModelRoster (Right defaultRoster) board)
    map (`Data.Text.isInfixOf` drawn) ["Codex", "Claude"] `shouldBe` [True, True]
  where
    expectedAccount variant = case variant.variantProvider of
      CodexProvider -> Codex
      ClaudeProvider -> Claude
    unloadedAccount variant = case variant.variantProvider of
      CodexProvider -> Claude
      ClaudeProvider -> Codex
    accountName Codex = "Codex"
    accountName Claude = "Claude"
    -- Only the sidebar's own columns, so a provider name appearing in a card
    -- or the footer cannot answer for a block that was never drawn.
    sidebarText state =
      Data.Text.unlines
        (map (Data.Text.take usageSidebarWidth) (renderWidgetLines (themeFor testOptions) 200 (drawBase state)))

-- ---------------------------------------------------------------------------
-- The command line
-- ---------------------------------------------------------------------------

pingSpec :: Spec
pingSpec = describe "the ping it refuses" $ do
  -- The review's third correction and fifth spec addition. A ping is the one
  -- action that deliberately spends quota (§14), and its brand is required
  -- and intentionally selected (§5), so an install asked for the provider it
  -- does not load refuses rather than redirecting the window.
  it "runs the loaded brand and refuses the other, naming both" $
    sequence_
      [ (variant.variantName, brand, named <$> refusal) `shouldBe` (variant.variantName, brand, expected)
      | variant <- variants,
        brand <- [PingCodex, PingClaude],
        let refusal = pingBrandRefusal (variantMode variant) brand
            -- Both halves of the message: the brand that was asked for, so
            -- the operator knows which invocation was refused, and the
            -- provider this install does load, so they know what to ask for
            -- instead. A refusal naming only one of them cannot be acted on.
            named message =
              ( pingBrandName brand `Data.Text.isInfixOf` message,
                providerKey variant.variantProvider `Data.Text.isInfixOf` message
              )
            expected = if brandOfPing brand == variant.variantBrand then Nothing else Just (True, True)
      ]

  -- Dual loads whichever brand was named; no-agent is refused before this by
  -- 'Kanban.CLI.launchModeRefusal' with the message that names the mode, so
  -- this says nothing about it rather than restating that refusal.
  it "refuses neither brand in dual or no-agent mode" $
    sequence_
      [ (mode', brand, pingBrandRefusal mode' brand) `shouldBe` (mode', brand, Nothing)
      | mode' <- [DualMode, NoAgentMode],
        brand <- [PingCodex, PingClaude]
      ]
  where
    brandOfPing PingCodex = CodexSolver
    brandOfPing PingClaude = ClaudeSolver

-- ---------------------------------------------------------------------------
-- Readiness
-- ---------------------------------------------------------------------------

preflightSpec :: Spec
preflightSpec = describe "the executables it does not require" $ do
  -- The review's second spec addition. A check is a claim that this machine
  -- must be able to run a specific executable, and this mode never spawns the
  -- brand it does not load, so blocking on a missing one would refuse actions
  -- the install is perfectly able to run.
  it "blocks on nothing when only the loaded provider is installed" $
    sequence_
      [ (variant.variantName, action, blockedProblemsIn (without variant) (variantMode variant) action)
          `shouldBe` (variant.variantName, action, [])
      | variant <- variants,
        action <- modeSensitiveActions variant
      ]

  -- The positive half: the provider it /does/ load is still required, so this
  -- is a narrowing of the check set rather than its removal.
  it "still blocks when the loaded provider is missing" $
    sequence_
      [ (variant.variantName, action, blockedProblemsIn (withoutLoaded variant) (variantMode variant) action)
          `shouldBe` (variant.variantName, action, [ExecutableUnavailable])
      | variant <- variants,
        action <- modeSensitiveActions variant
      ]

  -- The other half of D-7, and the one the two arms above create the room for:
  -- a session that already exists spawns the provider its own specification
  -- recorded, whatever the mode now routes to, so its readiness has to be
  -- about that provider and not about the routed one.
  --
  -- Without this the two correct rules meeting produce a hole: preflight
  -- clears the loaded provider while the launch replays the other one, and a
  -- resumed worker reaches an executable nothing probed. Every route is
  -- crossed with a record naming the brand this install does /not/ load,
  -- because that is the only combination in which the two answers differ.
  it "checks the provider a recorded assignment will really launch, not the routed one" $
    sequence_
      [ (variant.variantName, origin, action, blocked)
          `shouldBe` (variant.variantName, origin, action, [ExecutableUnavailable])
      | variant <- variants,
        (origin, action) <- everyRoute,
        -- The install loads its own provider and has only that executable;
        -- the resumed worker's record names the other one.
        let blocked =
              blockedProblemsWith
                (without variant)
                (variantMode variant)
                (Just (recordedOn variant.variantUnloaded action))
                (ActionPullRequestFlow origin action)
      ]

  -- The control that keeps the arm above from passing on any missing probe:
  -- the same recorded launch, on a machine that does have that executable, is
  -- ready -- so it is the record's own provider being probed rather than
  -- readiness having simply become stricter.
  it "clears that same recorded launch when its own provider is installed" $
    sequence_
      [ (variant.variantName, origin, action, blocked)
          `shouldBe` (variant.variantName, origin, action, [])
      | variant <- variants,
        (origin, action) <- everyRoute,
        let blocked =
              blockedProblemsWith
                readyPreflightEnvironment
                (variantMode variant)
                (Just (recordedOn variant.variantUnloaded action))
                (ActionPullRequestFlow origin action)
      ]

  -- A fresh action has no record, so it still asks the mode -- which is what
  -- every arm above this one covers, restated here as the boundary between
  -- the two.
  it "still asks the mode when nothing was recorded" $
    sequence_
      [ (variant.variantName, action, blockedProblemsWith (without variant) (variantMode variant) Nothing action)
          `shouldBe` (variant.variantName, action, [])
      | variant <- variants,
        action <- modeSensitiveActions variant
      ]

  -- The negative control. Dual mode still requires both, so an autosolve run
  -- or a Codex-origin review on a machine with no Claude is still blocked.
  it "still requires both brands in dual mode" $ do
    blockedProblemsIn withoutClaude DualMode (ActionAutoSolve CodexSolver) `shouldBe` [ExecutableUnavailable]
    blockedProblemsIn withoutClaude DualMode (ActionPullRequestFlow PullRequestCodex PullRequestReview)
      `shouldBe` [ExecutableUnavailable]
    blockedProblemsIn withoutClaude DualMode (ActionIssueReview IssueOriginUnmarked)
      `shouldBe` [ExecutableUnavailable]
    -- A Claude-origin revision authors its amendment through
    -- kanban_run_claude, so dual mode still needs that CLI for it.
    blockedProblemsIn withoutClaude DualMode (ActionIssueRevision IssueOriginClaude)
      `shouldBe` [ExecutableUnavailable]
  where
    -- Every action whose provider set the mode moves: the canonical issue
    -- review, the embedded revision -- whose coordinator and whose amendment
    -- author both collapse onto the loaded provider -- an autosolve run's own
    -- review of its pull request, the four pull-request actions of both
    -- origins, and the nested rereview a revision or repair spawns from
    -- inside its own session.
    --
    -- Every issue origin for the two issue-side actions, because in dual mode
    -- the origin is what picks the second brand, and this mode is where that
    -- second brand stops existing.
    --
    -- The autosolve run is the loaded brand's, because a solve's brand is the
    -- caller's choice rather than the mode's -- the chooser auto-selects the
    -- loaded provider, and a run recorded on the other brand is still owed a
    -- block for the executable it really would spawn.
    modeSensitiveActions variant =
      [ActionIssueReview origin | origin <- issueOrigins]
        <> [ActionIssueRevision origin | origin <- issueOrigins]
        <> [ActionAutoSolve variant.variantBrand]
        <> [ActionPullRequestFlow origin action | (origin, action) <- everyRoute]
    issueOrigins = [IssueOriginCodex, IssueOriginClaude, IssueOriginUnmarked]
    -- What a worker created before the roster moved recorded: that brand's
    -- own cell for the role the action takes, built the way a launch builds
    -- it rather than as a bare provider name.
    recordedOn brand action =
      recordAssignment
        (providerForBrand brand)
        (cellOf (assignmentFor defaultRoster (roleOfAction action) (providerForBrand brand)))
    without variant = probeless variant.variantUnloaded
    withoutLoaded variant = probeless variant.variantBrand
    withoutClaude = probeless ClaudeSolver
    probeless CodexSolver = withCodexProbe missing
    probeless ClaudeSolver = withClaudeProbe missing
    missing = (readyProviderProbe CodexSolver) {probeExecutable = Nothing}
