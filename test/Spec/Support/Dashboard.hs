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
-- scripted sequence and keeping every picture it paints. What comes back is
-- what the terminal was shown and the state the dashboard ended in.
--
-- Steps are fed one at a time, each waited for until the frame it causes has
-- been painted, so a script's order is the order the dashboard saw and a
-- keyboard press and an application event can be interleaved exactly. Nothing
-- here waits on a duration.
--
-- The one thing it does not run is the application's own start event, which
-- enables the mouse and starts this launch's GitHub and usage refreshes. A
-- suite that started those would be a network test; the mouse matters only for
-- a terminal that has to be told to send presses, and these are injected
-- straight into the input channel.
module Spec.Support.Dashboard
  ( DashboardRun (..),
    ScriptStep (..),
    runDashboardScript,
    quitStep,
  )
where

import Brick (App (..), modify)
import Brick.BChan (writeBChan)
import Brick.Main (customMain)
import Control.Concurrent (forkIO)
import Control.Concurrent.STM
  ( TChan,
    TVar,
    atomically,
    check,
    modifyTVar',
    newTChanIO,
    newTVarIO,
    readTVar,
    writeTChan,
  )
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Graphics.Vty as Vty
import qualified Graphics.Vty.Output.Mock as Vty
import Kanban.UI (dashboardApplication)
import Kanban.UI.Types (AppEvent, AppState (..))
import Spec.Support.Render (FrameCell, pictureCells)
import System.Timeout (timeout)

-- | What one scripted run left behind.
data DashboardRun = DashboardRun
  { -- | Every frame the dashboard painted, oldest first, as the cells the
    -- terminal would have shown at whatever size it was when that frame was
    -- painted.
    runFrames :: [[[FrameCell]]],
    -- | The state it ended in.
    runState :: AppState
  }

-- | One thing a script does to a running dashboard.
data ScriptStep
  = -- | A terminal event: a key, or a mouse press at a screen position.
    Press Vty.Event
  | -- | An application event, delivered on the dashboard's own channel --
    -- a finished refresh, a worker's report, a notice expiring.
    Deliver AppEvent
  | -- | A terminal of a new size. The bounds move before the resize event, so
    -- brick reads the new ones exactly as it would from a real terminal.
    Resize (Int, Int)

-- | Run @steps@ against @initial@ on a terminal of @region@, ending with the
-- quit the caller must supply.
--
-- @adjust@ is applied to the state after every event, before the next frame is
-- drawn. It exists for exactly one purpose: running the same script twice,
-- once as the dashboard behaves and once with a preparation suppressed, so the
-- two can be compared frame for frame.
runDashboardScript :: (Int, Int) -> (AppState -> AppState) -> AppState -> [ScriptStep] -> IO DashboardRun
runDashboardScript region adjust initial steps = do
  channel <- newTChanIO
  bounds <- newIORef region
  (_, mock) <- Vty.mockTerminal region
  vty <- Vty.mkVtyFromPair (scriptedInput channel) (quietOutput bounds mock)
  painted <- newIORef []
  paintCount <- newTVarIO (0 :: Int)
  let capturing =
        vty
          { Vty.update = \picture -> do
              -- The size is read here rather than at the end, because a script
              -- may have resized the terminal and a picture painted for one
              -- size cannot be read back at another.
              painting <- readIORef bounds
              modifyIORef' painted ((painting, picture) :)
              atomically (modifyTVar' paintCount (+ 1))
              Vty.update vty picture
          }
      application =
        dashboardApplication
          { appStartEvent = pure (),
            appHandleEvent = \event -> dashboardApplication.appHandleEvent event >> modify adjust
          }
  stalled <- newIORef Nothing
  _ <- forkIO (feed channel bounds paintCount stalled initial steps)
  final <- timeout runTimeoutMicros (customMain capturing (pure capturing) (Just initial.appEventChannel) application initial)
  pictures <- readIORef painted
  Vty.shutdown capturing
  reason <- readIORef stalled
  case (reason, final) of
    (Just message, _) -> fail message
    (Nothing, Nothing) -> fail "the dashboard did not halt on the script's last step"
    (Nothing, Just ended) ->
      pure DashboardRun {runFrames = map (uncurry pictureCells) (reverse pictures), runState = ended}

-- | Feed the script one step at a time, waiting after each for the frame it
-- causes. The last step is not waited for: it is the quit, and a halted
-- dashboard paints nothing more.
feed :: TChan Vty.InternalEvent -> IORef (Int, Int) -> TVar Int -> IORef (Maybe String) -> AppState -> [ScriptStep] -> IO ()
feed channel bounds paintCount stalled state steps = do
  -- The dashboard paints once before it reads anything. Waiting for that frame
  -- first is what aligns the counter with the script: without it the loop
  -- below counts the startup frame as the first step's, runs a step ahead
  -- forever, and can move the terminal's size while a frame for an earlier
  -- step is still being painted.
  started <- awaitPaint 0
  if started then go steps else stall
  where
    go [] = pure ()
    go (step : remaining) = do
      before <- atomically (readTVar paintCount)
      apply step
      painted <- if null remaining then pure True else awaitPaint before
      if painted then go remaining else stall
    -- Say why, then let the dashboard halt: a feeder that simply stopped would
    -- leave the loop blocked on an empty channel and the example hanging
    -- instead of failing.
    stall = do
      writeIORef stalled (Just "the dashboard painted no frame for a scripted step")
      apply quitStep
    apply = \case
      Press event -> atomically (writeTChan channel (Vty.InputEvent event))
      Deliver event -> writeBChan state.appEventChannel event
      Resize region -> do
        writeIORef bounds region
        atomically (writeTChan channel (Vty.InputEvent (uncurry Vty.EvResize region)))
    -- Bounded so a step that paints nothing fails the example rather than
    -- hanging the suite. Nothing here depends on how long a frame takes: the
    -- wait ends the moment one is painted, and this only decides how long a
    -- dashboard that has stopped painting is given before it is called stuck.
    awaitPaint before = do
      settled <- timeout paintTimeoutMicros (atomically (readTVar paintCount >>= check . (> before)))
      pure (maybe False (const True) settled)

paintTimeoutMicros, runTimeoutMicros :: Int
paintTimeoutMicros = 30 * 1000 * 1000

runTimeoutMicros = 120 * 1000 * 1000

-- | The step that ends a script. A dashboard with nothing queued halts on it
-- immediately, which is what lets the loop return rather than block on an
-- empty input channel.
quitStep :: ScriptStep
quitStep = Press (Vty.EvKey (Vty.KChar 'q') [])

-- | The mock terminal, with two changes: it stops narrating every write to
-- stdout, and it reports whatever bounds the script last set rather than the
-- one size it was built with.
quietOutput :: IORef (Int, Int) -> Vty.Output -> Vty.Output
quietOutput bounds output =
  output
    { Vty.outputByteBuffer = const (pure ()),
      Vty.displayBounds = readIORef bounds
    }

-- | An input interface that only replays what is written to its channel. Vty
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
