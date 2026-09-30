-- | Terminal focus updates, with a synthetic monotonic clock for cooldown
-- boundaries and the real dashboard loop for dispatch and overlay handling.
module Spec.UI.FocusRefresh (spec) where

import Data.Foldable (for_)
import Control.Exception (finally)
import Control.Monad (void)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Time (addUTCTime)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import qualified Graphics.Vty as Vty
import qualified Graphics.Vty.Output.Mock as Mock
import Kanban.Domain (Freshness (..))
import Kanban.GitHub (shutdownRefreshCoordinator)
import Kanban.UI (enableFocusIfSupported)
import Kanban.UI.Refresh (focusRefreshDue)
import Kanban.UI.Types (AppEvent (..), AppState (..), Overlay (..), withModelRoster)
import Spec.Support.App (testAppState)
import Spec.Support.Dashboard (DashboardRun (..), ScriptStep (..), quitStep, runDashboardScript)
import Spec.Support.Fixtures (epoch, fixtureBoard)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Roster (noAgentRoster)
import Spec.Support.Render (frameRowText)
import Test.Hspec

spec :: Spec
spec = around_ isolatedCache $ describe "terminal focus refresh" $ do
  it "enables focus reporting only on a supporting terminal backend" $ do
    (_, output) <- Mock.mockTerminal (80, 24)
    modes <- newIORef []
    let recording supported = output
          { Vty.supportsMode = const supported,
            Vty.setMode = \mode enabled -> modifyIORef' modes (<> [(mode, enabled)])
          }
    enableFocusIfSupported (recording False)
    readIORef modes `shouldReturn` []
    enableFocusIfSupported (recording True)
    readIORef modes `shouldReturn` [(Vty.Focus, True)]

  it "allows a first refresh and opens the cooldown at exactly 60 seconds" $ do
    state <- boardState
    focusRefreshDue 0 state False `shouldBe` True
    let updated = state {appLastBoardRefreshStarted = Just second}
    for_ [second, 60 * second, 61 * second - 1] $ \now ->
      focusRefreshDue now updated False `shouldBe` False
    focusRefreshDue (61 * second) updated False `shouldBe` True

  it "does not shorten the cooldown when the wall clock moves" $ do
    state <- boardState
    let updated = state {appLastBoardRefreshStarted = Just second}
    for_ [addUTCTime (-3600) epoch, addUTCTime 3600 epoch] $ \wallClock -> do
      focusRefreshDue (60 * second) updated {appNow = wallClock} False `shouldBe` False
      focusRefreshDue (61 * second) updated {appNow = wallClock} False `shouldBe` True

  it "does not underflow when handed an earlier monotonic timestamp" $ do
    state <- boardState
    focusRefreshDue 0 state {appLastBoardRefreshStarted = Just second} False `shouldBe` False

  it "skips a running refresh before either progress signal has caught up" $ do
    state <- boardState
    focusRefreshDue (120 * second) state {appBoardFreshness = Loading} False `shouldBe` False
    focusRefreshDue (120 * second) state True `shouldBe` False

  it "skips a queued workflow refresh and dashboard shutdown" $ do
    state <- boardState
    focusRefreshDue (120 * second) state {appBoardRefreshQueued = True} False `shouldBe` False
    focusRefreshDue (120 * second) state {appQuitPending = True} False `shouldBe` False

  it "can retry a failed refresh after the cooldown" $ do
    state <- boardState
    focusRefreshDue (120 * second) state
      { appBoardFreshness = Unavailable "offline",
        appLastBoardRefreshStarted = Just second
      } False `shouldBe` True

  it "dispatches gained focus and coalesces repeated focus without queuing" $ do
    state <- boardState
    result <- run state
      [ Press Vty.EvGainedFocus,
        Press Vty.EvLostFocus,
        Press Vty.EvGainedFocus,
        quitStep
      ]
    result.runState.appLastBoardRefreshStarted `shouldSatisfy` (/= Nothing)
    result.runState.appBoardRefreshQueued `shouldBe` False

  it "does nothing on lost focus or a resize" $ do
    state <- boardState
    result <- run state [Press Vty.EvLostFocus, Resize (100, 30), quitStep]
    result.runState.appLastBoardRefreshStarted `shouldBe` Nothing
    result.runState.appBoardRefreshQueued `shouldBe` False

  it "ignores focus in the cooldown" $ do
    state <- boardState
    now <- getMonotonicTimeNSec
    let recent = state {appLastBoardRefreshStarted = Just now}
    result <- run recent [Press Vty.EvGainedFocus, quitStep]
    result.runState.appLastBoardRefreshStarted `shouldBe` Just now
    result.runState.appUsageFreshness `shouldBe` state.appUsageFreshness
    result.runState.appBoardFreshness `shouldBe` state.appBoardFreshness

  it "handles focus before settings consumes events and keeps the overlay open" $ do
    state <- boardState
    let steps = [Press Vty.EvGainedFocus, Press (Vty.EvKey Vty.KEsc []), quitStep]
    -- The first frame after focus must still draw settings; the state after
    -- its explicit dismissal confirms no focus event closed it implicitly.
    result <- run state {appOverlay = Just SettingsOverlay} steps
    result.runState.appLastBoardRefreshStarted `shouldSatisfy` (/= Nothing)
    result.runState.appOverlay `shouldBe` Nothing
    map (any (Text.isInfixOf " SETTINGS " . frameRowText)) (take 2 result.runFrames)
      `shouldBe` [True, True]
    focusRefreshDue 0 state {appOverlay = Just SettingsOverlay} False `shouldBe` True

  it "lets manual refresh bypass the focus cooldown" $ do
    state <- boardState
    now <- getMonotonicTimeNSec
    let recent = state {appLastBoardRefreshStarted = Just now}
    result <- run recent [Press (Vty.EvKey (Vty.KChar 'u') []), quitStep]
    result.runState.appLastBoardRefreshStarted `shouldSatisfy` (> Just now)

  it "counts a coordinator retry toward the focus cooldown" $ do
    state <- boardState
    result <- run state [Deliver (BoardRefreshStarted 1), Press Vty.EvGainedFocus, quitStep]
    result.runState.appLastBoardRefreshStarted `shouldSatisfy` (/= Nothing)
    result.runState.appBoardRefreshQueued `shouldBe` False

second :: Word64
second = 1000 * 1000 * 1000

boardState :: IO AppState
boardState = withModelRoster (Right noAgentRoster) <$> testAppState (fixtureBoard [])

run :: AppState -> [ScriptStep] -> IO DashboardRun
run state steps =
  runDashboardScript (120, 40) id state steps
    `finally` void (shutdownRefreshCoordinator state.appRefreshCoordinator)

-- The scripted events request real coordinator jobs with fixture runners.
-- Keep their durable gh guard away from the developer and concurrent lanes,
-- and settle them before the temporary cache is removed.
isolatedCache :: IO () -> IO ()
isolatedCache action =
  withTemporaryCacheRoot $ \root ->
    withEnvironmentValue "XDG_CACHE_HOME" root action
