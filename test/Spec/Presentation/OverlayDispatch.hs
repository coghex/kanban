-- | Overlay selection resolution and mouse dispatch.
module Spec.Presentation.OverlayDispatch (spec) where

import Brick (BrickEvent (..), Location (..))
import qualified Graphics.Vty as Vty
import Kanban.Domain
import Kanban.UI
  ( AgentSessionEntry (..),
    AgentSessionRef (..),
    Name (..),
    OverlayMouseAction (..),
    ProcessClickOutcome (..),
    ProcessSelection (..),
    overlayMouseAction,
    resolveProcessClick,
    resolveProcessSelection
  )
import Kanban.Worker (WorkerId (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "processes overlay selection resolution" $ do
    let sessionEntry ref =
          AgentSessionEntry
            { agentSessionRef = ref,
              agentSessionLabel = "label",
              agentSessionProvider = "provider",
              agentSessionStatus = "status",
              agentSessionActivity = "activity",
              agentSessionId = Nothing,
              agentSessionLive = True,
              agentSessionProblem = False
            }
        solve = sessionEntry . SolveAgent

    it "keeps the clamped entry as the target when the list shrinks past the selection" $ do
      let selection = ProcessSelection (Just (SolveAgent 5)) 4
          shrunk = [solve 1, solve 2]
      resolveProcessSelection shrunk selection `shouldBe` ProcessSelection (Just (SolveAgent 2)) 1

    it "follows the selected identity across a reorder instead of the row" $ do
      let selection = ProcessSelection (Just (SolveAgent 2)) 1
          reordered = [solve 2, solve 1, solve 3]
      resolveProcessSelection reordered selection `shouldBe` ProcessSelection (Just (SolveAgent 2)) 0

    it "falls back to the nearest remaining row when the selected session disappears" $ do
      let selection = ProcessSelection (Just (WorkerAgent (WorkerId "w1"))) 2
          remaining = [solve 1, solve 2]
      resolveProcessSelection remaining selection `shouldBe` ProcessSelection (Just (SolveAgent 2)) 1

    it "resolves to no selection when no sessions remain" $
      resolveProcessSelection [] (ProcessSelection (Just (SolveAgent 1)) 0) `shouldBe` ProcessSelection Nothing 0

    it "adopts the fallback entry as canonical so a later reorder follows it, not the vanished identity" $ do
      let selection = ProcessSelection (Just (WorkerAgent (WorkerId "w1"))) 2
          afterDisappearance = [solve 1, solve 2, solve 3]
          afterReorder = [solve 3, solve 2, solve 1]
          resolvedOnce = resolveProcessSelection afterDisappearance selection
          resolvedTwice = resolveProcessSelection afterReorder resolvedOnce
      resolvedOnce `shouldBe` ProcessSelection (Just (SolveAgent 3)) 2
      resolvedTwice `shouldBe` ProcessSelection (Just (SolveAgent 3)) 0

    it "resolves a click by the identity rendered at that row, not the row itself, across a pre-dispatch reorder" $ do
      let selection = ProcessSelection (Just (SolveAgent 1)) 0
          reorderedBeforeDispatch = [solve 3, solve 1, solve 2]
      resolveProcessClick reorderedBeforeDispatch selection (SolveAgent 2)
        `shouldBe` ProcessClickSelect (ProcessSelection (Just (SolveAgent 2)) 2)
      resolveProcessClick reorderedBeforeDispatch selection (SolveAgent 1)
        `shouldBe` ProcessClickOpen
      resolveProcessClick [solve 1, solve 2] selection (SolveAgent 9)
        `shouldBe` ProcessClickIgnored

  describe "overlay mouse dispatch" $ do
    let backgroundCard = CardTarget Issues 0
        zeroLoc = Location (0, 0)
        rawWheel button = VtyEvent (Vty.EvMouseDown 0 0 button [])
        overlays =
          [ ("review overlay", ReviewPanel, ReviewViewport),
            ("solve overlay", SolvePanel, SolveViewport),
            ("pull request review overlay", PullRequestReviewPanel, PullRequestReviewViewport),
            ("details overlay", DetailsPanel, DetailsViewport)
          ]

    mapM_
      ( \(label, panel, viewport) -> describe label $ do
          it "scrolls, without closing, when the wheel lands on a background clickable" $ do
            overlayMouseAction panel (MouseDown backgroundCard Vty.BScrollUp [] zeroLoc) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (MouseDown backgroundCard Vty.BScrollDown [] zeroLoc) `shouldBe` Just (OverlayMouseScroll 3)

          it "scrolls on a raw Vty wheel event that carries no Brick name at all" $ do
            overlayMouseAction panel (rawWheel Vty.BScrollUp) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (rawWheel Vty.BScrollDown) `shouldBe` Just (OverlayMouseScroll 3)

          it "scrolls when the wheel lands on the overlay's own viewport or panel" $ do
            overlayMouseAction panel (MouseDown viewport Vty.BScrollUp [] zeroLoc) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (MouseDown viewport Vty.BScrollDown [] zeroLoc) `shouldBe` Just (OverlayMouseScroll 3)
            overlayMouseAction panel (MouseDown panel Vty.BScrollUp [] zeroLoc) `shouldBe` Just (OverlayMouseScroll (-3))
            overlayMouseAction panel (MouseDown panel Vty.BScrollDown [] zeroLoc) `shouldBe` Just (OverlayMouseScroll 3)

          it "closes on an outside click, left or right, named or raw" $ do
            overlayMouseAction panel (MouseDown backgroundCard Vty.BLeft [] zeroLoc) `shouldBe` Just OverlayMouseClose
            overlayMouseAction panel (MouseDown backgroundCard Vty.BRight [] zeroLoc) `shouldBe` Just OverlayMouseClose
            overlayMouseAction panel (rawWheel Vty.BLeft) `shouldBe` Just OverlayMouseClose

          it "closes the panel on a right click but leaves a left click on the panel inert" $ do
            overlayMouseAction panel (MouseDown panel Vty.BRight [] zeroLoc) `shouldBe` Just OverlayMouseClose
            overlayMouseAction panel (MouseDown panel Vty.BLeft [] zeroLoc) `shouldBe` Just OverlayMouseNoOp
       )
       overlays
