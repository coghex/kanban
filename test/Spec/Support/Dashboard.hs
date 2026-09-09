-- | Driving the real dashboard through brick's own event loop, with no
-- terminal.
--
-- Everything else in this suite renders one frame from one state. Some
-- behavior is not in one frame: a column's scroll offset lives in brick's
-- viewport state, survives from frame to frame, and is what a wheel press
-- moves. A test that renders states in isolation always starts that offset at
-- zero, so it can never show what a scrolled board draws or what a click on it
-- resolves to.
--
-- So this runs 'Kanban.UI.dashboardApplication' -- the production draw,
-- dispatch, cursor policy, and theme -- over a mock terminal, feeding it a
-- scripted list of vty events and keeping every picture it paints. What comes
-- back is what the terminal was shown and the state the dashboard ended in.
--
-- The one thing it does not run is the application's own start event, which
-- enables the mouse and starts this launch's GitHub and usage refreshes. A
-- suite that started those would be a network test; the mouse matters only for
-- a terminal that has to be told to send presses, and these are injected
-- straight into the input channel.
module Spec.Support.Dashboard
  ( DashboardRun (..),
    runDashboardScript,
    quitKey,
  )
where

import Brick (App (..), modify)
import Brick.Main (customMain)
import Control.Concurrent.STM (TChan, atomically, newTChanIO, writeTChan)
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Graphics.Vty as Vty
import qualified Graphics.Vty.Output.Mock as Vty
import Kanban.UI (dashboardApplication)
import Kanban.UI.Types (AppState)
import Spec.Support.Render (FrameCell, pictureCells)

-- | What one scripted run left behind.
data DashboardRun = DashboardRun
  { -- | Every frame the dashboard painted, oldest first, as the cells a
    -- terminal of the scripted size would have shown.
    runFrames :: [[[FrameCell]]],
    -- | The state it ended in.
    runState :: AppState
  }

-- | Run @events@ against @initial@ on a terminal of @region@, ending with the
-- quit the caller must supply.
--
-- @adjust@ is applied to the state after every event, before the next frame is
-- drawn. It exists for exactly one purpose: running the same script twice,
-- once as the dashboard behaves and once with a preparation suppressed, so the
-- two can be compared frame for frame.
runDashboardScript :: (Int, Int) -> (AppState -> AppState) -> AppState -> [Vty.Event] -> IO DashboardRun
runDashboardScript region adjust initial events = do
  channel <- newTChanIO
  mapM_ (atomically . writeTChan channel . Vty.InputEvent) events
  (_, output) <- Vty.mockTerminal region
  vty <- Vty.mkVtyFromPair (scriptedInput channel) output
  painted <- newIORef []
  let capturing = vty {Vty.update = \picture -> modifyIORef' painted (picture :) >> Vty.update vty picture}
      application =
        dashboardApplication
          { appStartEvent = pure (),
            appHandleEvent = \event -> dashboardApplication.appHandleEvent event >> modify adjust
          }
  final <- customMain capturing (pure capturing) Nothing application initial
  pictures <- readIORef painted
  Vty.shutdown capturing
  pure DashboardRun {runFrames = map (pictureCells region) (reverse pictures), runState = final}

-- | The event that ends a script. A dashboard with nothing queued halts on it
-- immediately, which is what lets the loop above return rather than block on
-- an empty input channel.
quitKey :: Vty.Event
quitKey = Vty.EvKey (Vty.KChar 'q') []

-- | An input interface that only replays what was written to its channel. Vty
-- reads events from there and nowhere else, so no terminal is opened and
-- nothing is restored on shutdown.
scriptedInput :: TChan Vty.InternalEvent -> Vty.Input
scriptedInput channel =
  Vty.Input
    { Vty.eventChannel = channel,
      Vty.shutdownInput = pure (),
      Vty.restoreInputState = pure (),
      Vty.inputLogMsg = const (pure ())
    }
