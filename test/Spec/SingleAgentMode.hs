-- | What a Kanban whose roster loads exactly one provider reads (issue #589):
-- the usage probes and the sidebar blocks they feed.
--
-- The mirror of "Spec.OperatingMode", which covers the mode that loads none.
-- Where that module asks what a board refuses, this one asks what a board
-- reads.
--
-- Two variants throughout, never one standing in for the other. A Codex-only
-- install and a Claude-only install are the same mode and opposite answers,
-- and an assertion made against one alone would pass on a probe set that still
-- named a brand rather than reading the roster.
--
-- Dual mode is the negative control in every section: the same probes and the
-- same blocks.
--
-- Everything here is a pure function the corresponding @EventM@ arm or @IO@
-- entry point only projects -- 'usageProviders' for the probes -- so the whole
-- matrix is settled with no terminal, no subprocess, and no provider account.
module Spec.SingleAgentMode (spec) where

import qualified Data.Text
import Kanban.Domain (UsageProvider (..))
import Kanban.Models
  ( ModelRoster (..),
    OperatingMode (..),
    ProviderName (..),
    defaultRoster,
    loadedOperatingMode,
    operatingModeFor,
  )
import Kanban.UI.Board (drawBase, usageSidebarWidth)
import Kanban.UI.Refresh (usageRefreshProviders)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types (AppState (..))
import Kanban.Usage (usageProviders)
import Spec.Support.App (testAppState)
import Spec.Support.Fixtures (fixtureBoard, testOptions)
import Spec.Support.Render (renderWidgetLines)
import Spec.Support.Roster (claudeOnlyRoster, codexOnlyRoster)
import Test.Hspec

spec :: Spec
spec = describe "single-agent operating mode" $ do
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
