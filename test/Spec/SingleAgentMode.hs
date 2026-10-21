-- | What a Kanban whose roster loads exactly one provider reads (issue #589):
-- the embedded review's backend and the prose it runs under, and the usage
-- probes and sidebar blocks they feed.
--
-- The mirror of "Spec.OperatingMode", which covers the mode that loads none.
-- Where that module asks what a board refuses, this one asks what a board
-- /selects/.
--
-- Two variants throughout, never one standing in for the other. A Codex-only
-- install and a Claude-only install are the same mode and opposite answers,
-- and an assertion made against one alone would pass on routing that still
-- named a brand rather than reading the roster.
--
-- Dual mode is the negative control in every section, because requirement 9
-- is that it does not move: the same cells, the same probes.
--
-- Everything here is a pure function the corresponding @EventM@ arm or @IO@
-- entry point only projects -- 'embeddedReviewProvider' for the review
-- backend and 'usageProviders' for the probes -- so the whole matrix is
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
    ModelRoster (..),
    OperatingMode (..),
    ProviderName (..),
    RoleName (..),
    assignmentFor,
    defaultRoster,
    loadedOperatingMode,
    operatingModeFor,
  )
import Kanban.Review (EmbeddedReviewBackend (..), claudeToolName, embeddedReviewCell, embeddedReviewProvider, githubToolName, questionToolName, reviewDeveloperInstructions)
import Kanban.ProviderAdapter (ProviderAdapter (..), adapterFor)
import Kanban.UI.Board (drawBase, usageSidebarWidth)
import Kanban.UI.Refresh (usageRefreshProviders)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types (AppState (..))
import Kanban.Usage (usageProviders)
import Spec.Support.App (testAppState)
import Spec.Support.Fixtures (fixtureBoard, testOptions)
import Spec.Support.Render (renderWidgetLines)
import Spec.Support.Roster (cellOf, claudeOnlyRoster, codexOnlyRoster)
import Test.Hspec

spec :: Spec
spec = describe "single-agent operating mode" $ do
  reviewSpec
  usageSpec

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
    variantProvider :: ProviderName
  }

variants :: [Variant]
variants =
  [ Variant "codex-only" codexOnlyRoster CodexProvider,
    Variant "claude-only" claudeOnlyRoster ClaudeProvider
  ]

-- | The mode a variant's own roster derives, taken through 'operatingModeFor'
-- rather than written as a constructor, so a fixture that stopped deriving
-- single-agent fails here instead of being asserted against a mode it does
-- not have.
variantMode :: Variant -> OperatingMode
variantMode = operatingModeFor . variantRoster

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

  it "says the coordinator authors every supported amendment itself, refuses Kimi and Google, and has no handoff tool" $
    sequence_
      [ (variant.variantName, map (`Data.Text.isInfixOf` instructionsFor variant) claims)
          `shouldBe` (variant.variantName, [True, True, True, True])
      | variant <- variants,
        let claims =
              [ "you author each Codex-origin, Claude-origin, or unmarked amendment yourself",
                "Kimi-origin issue revision is not a board action",
                "Google-origin issue revision is not a board action",
                "There is no " <> claudeToolName <> " tool in this thread"
              ]
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
          let drawn = sidebarText (board {appOperatingMode = loadedOperatingMode (Right variant.variantRoster)})
          (variant.variantName, accountName (expectedAccount variant) `Data.Text.isInfixOf` drawn)
            `shouldBe` (variant.variantName, True)
          (variant.variantName, accountName (unloadedAccount variant) `Data.Text.isInfixOf` drawn)
            `shouldBe` (variant.variantName, False)
      | variant <- variants
      ]

  it "draws both blocks in dual mode" $ do
    board <- testAppState (fixtureBoard [])
    let drawn = sidebarText (board {appOperatingMode = loadedOperatingMode (Right defaultRoster)})
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
