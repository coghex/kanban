-- | The dashboard's lifecycle for the PR drainer: the toggle seam its control
-- invokes, what an observation does to the state, and the direct merge of one
-- approved pull request through the drainer's own single-pull-request path.
--
-- Held apart from "Kanban.UI.Approval", which owns the issue approval
-- service's, for the reason the two domains are apart: a shared handler would
-- be one place where either service's observation could be written into the
-- other's field.
module Kanban.UI.Drainer
  ( applyDirectMerge,
    applyDrainerStatus,
    applyDrainerToggle,
    directMergeResultApplied,
    drainerErrorStatus,
    drainerToggleApplied,
    drainerTogglePress,
    mergeItemDoneCard,
    mergeSelectedDoneCard,
    runDrainerToggleHandoff,
    toggleDrainer,
  )
where

import Brick
import Brick.BChan (writeBChan)
import Control.Concurrent (forkIO)
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..))
import Kanban.Domain
import Kanban.Drainer
  ( DirectMergeDecision (..),
    DirectMergeEffect (..),
    DirectMergeOutcome,
    DrainerActivity (..),
    DrainerController,
    DrainerIncident (..),
    DrainerObservation (..),
    DrainerState (..),
    DrainerStatus (..),
    DrainerToggle (..),
    directMergeDecision,
    directMergeEffect,
    drainerToggle,
    resolveSinglePullRequestDrainer,
    runDirectMerge,
    setDrainerRunning
  )
import Kanban.Text (sanitizeText)
import Kanban.UI.Filter (readOnlyHistoryRefusal)
import Kanban.UI.Notice (NoticeActivity (..))
import Kanban.UI.Refresh
import Kanban.UI.Selection
import Kanban.UI.State
import Kanban.UI.Types
import Kanban.UI.Util

-- | What pressing the drainer toggle does to the dashboard, and the
-- controller work it hands off — which this deliberately does not run.
--
-- Splitting the two is what lets the press be exercised: every observable
-- effect of the toggle is the state this returns, so a test can take the
-- press without a controller subprocess ever being spawned, and dispatch has
-- no second copy of it to drift from.
drainerTogglePress :: AppState -> (AppState, Maybe (DrainerController, Bool))
drainerTogglePress state = case drainerToggle state.appDrainerBusy state.appDrainerStatus of
  DrainerToggleBusy notice -> (noticed notice, Nothing)
  decision -> case state.appDrainerController of
    Left message -> (noticed ("PR drainer control unavailable: " <> sanitizeText message), Nothing)
    Right controller ->
      let shouldRun = decision == StartDrainer
          transition =
            if shouldRun
              then DrainerStatus DrainerStarting "starting…" DrainerServiceStarting Nothing
              else DrainerStatus DrainerStopping "stopping…" DrainerServiceStopping Nothing
       in ( noticeSetFor
              DrainerToggleRunning
              (if shouldRun then "Starting PR drainer…" else "Stopping PR drainer…")
              state
                { appDrainerStatus = transition,
                  -- Mid-transition, the last poll's set describes a drainer
                  -- that is being started or stopped underneath it.
                  appDrainerIncidents = Nothing,
                  appDrainerBusy = True
                },
            Just (controller, shouldRun)
          )
  where
    noticed notice = noticeSet notice state

toggleDrainer :: EventM Name AppState ()
toggleDrainer = do
  state <- get
  put (fst (drainerTogglePress state))
  runDrainerToggleHandoff state

-- | Start the controller work a press handed off, if it handed any off. Read
-- off the state the press was taken from, so the decision is made once.
runDrainerToggleHandoff :: AppState -> EventM Name AppState ()
runDrainerToggleHandoff state = case snd (drainerTogglePress state) of
  Nothing -> pure ()
  Just (controller, shouldRun) ->
    void
      . liftIO
      . forkIO
      $ setDrainerRunning controller shouldRun >>= writeBChan state.appEventChannel . DrainerToggleFinished

applyDrainerStatus :: Either Text DrainerObservation -> EventM Name AppState ()
applyDrainerStatus result = modify $ \state ->
  if state.appDrainerBusy
    then state
    else
      state
        { appDrainerStatus = observedStatusOr result,
          appDrainerIncidents = observedIncidentsOr result
        }

applyDrainerToggle :: Either Text DrainerObservation -> EventM Name AppState ()
applyDrainerToggle = modify . drainerToggleApplied

-- | What one toggle's observation does to the state: the settled status, and
-- the settled notice reporting it. Pure so the suite can take the
-- active-to-settled transition the drainer notice makes without brick.
drainerToggleApplied :: Either Text DrainerObservation -> AppState -> AppState
drainerToggleApplied result state =
  let status = observedStatusOr result
      notice = case result of
        Left message -> "PR drainer control failed: " <> sanitizeText message
        Right _ -> "PR drainer is " <> status.drainerDetail
   in noticeSet
        notice
        state
          { appDrainerStatus = status,
            appDrainerIncidents = observedIncidentsOr result,
            appDrainerBusy = False
          }

observedStatusOr :: Either Text DrainerObservation -> DrainerStatus
observedStatusOr = either drainerErrorStatus (.observedStatus)

-- | A failed invocation observed no incidents at all, which is not the same
-- as observing none: the previous poll's set is dropped rather than left
-- standing as though it were still current.
observedIncidentsOr :: Either Text DrainerObservation -> Maybe [DrainerIncident]
observedIncidentsOr = either (const Nothing) (.observedIncidents)

-- | A controller that could not be discovered, run, or decoded leaves the
-- service's actual state unknown — never "off" — so nothing that may only act
-- against a settled stop can act on this.
drainerErrorStatus :: Text -> DrainerStatus
drainerErrorStatus message =
  DrainerStatus DrainerError (sanitizeText message) DrainerServiceUnknown Nothing

-- | @m@ on the board, which acts on the selected card.
mergeSelectedDoneCard :: EventM Name AppState ()
mergeSelectedDoneCard = get >>= mergeDoneCard . selectedItem

-- | @m@ on the details overlay, which acts on the card that overlay is for.
mergeItemDoneCard :: BoardItem -> EventM Name AppState ()
mergeItemDoneCard = mergeDoneCard . Just

-- | Merge one approved pull request by running the PR drainer's own
-- single-pull-request path. Kanban decides only whether to invoke it: every
-- gate re-read, the head check, the merge itself, and the branch, worktree
-- and linked-issue cleanup belong to that path and are not restated here.
--
-- The run is forked, so the interface keeps redrawing while it works, and
-- 'appDirectMergePending' is set before the fork so a second @m@ finds it and
-- refuses rather than starting a second process against the same repository.
-- | The selection is re-read against the newest completed generation before
-- 'directMergeDecision' is asked at all, because a details overlay can be
-- holding a pull request that merged since it opened. The decision refuses a
-- settled item on its own too, so a stale card cannot reach the drainer by
-- either door.
mergeDoneCard :: Maybe BoardItem -> EventM Name AppState ()
mergeDoneCard selection = do
  state <- get
  case selection >>= readOnlyHistoryRefusal state of
    Just notice -> setNotice (sanitizeText ("Not merging: " <> notice))
    Nothing -> runMergeDecision selection

runMergeDecision :: Maybe BoardItem -> EventM Name AppState ()
runMergeDecision selection = do
  state <- get
  case directMergeDecision state.appConfig.resolvedWorkflow state.appDirectMergePending state.appDrainerStatus selection of
    RefuseDirectMerge refusal -> setNotice (sanitizeText ("Not merging: " <> refusal))
    RunDirectMerge number -> do
      resolved <- liftIO (resolveSinglePullRequestDrainer (rightOrNothing state.appDrainerController))
      case resolved of
        Left message ->
          setNotice (sanitizeText ("Cannot merge PR #" <> showText number <> ": " <> message))
        Right scriptPath -> do
          modify
            ( \current ->
                noticeSetFor
                  (DirectMergeRunning number)
                  ("Merging PR #" <> showText number <> " through the PR drainer…")
                  current {appDirectMergePending = Just number}
            )
          void
            . liftIO
            . forkIO
            $ runDirectMerge scriptPath state.appRepository state.appOptions.optionConfig number
              >>= writeBChan state.appEventChannel . DirectMergeFinished number

-- | Publish what one direct merge did. It touches the action's own notice and
-- pending flag and nothing else: 'appDrainerStatus' describes the launchd
-- service, which this ran instead of and did not change, and letting a merge
-- result write there would leave the sidebar reporting an action rather than
-- a service.
applyDirectMerge :: Int -> Either Text DirectMergeOutcome -> EventM Name AppState ()
applyDirectMerge number result = do
  let effect = directMergeEffect number result
  modify (directMergeResultApplied number effect)
  when effect.directMergeRefreshesBoard requireBoardRefresh

-- | What one merge's result does to the state, split from the refresh it
-- then requires so the suite can take the transition without brick. The
-- result notice itself is settled — the merge has landed or declined either
-- way — and the report behind it records the instance it was shown as, which
-- is what keeps the carry to that very report.
directMergeResultApplied :: Int -> DirectMergeEffect -> AppState -> AppState
directMergeResultApplied number effect state =
  let noticed =
        noticeSet
          effect.directMergeNotice
          state
            { appDirectMergePending =
                if state.appDirectMergePending == Just number then Nothing else state.appDirectMergePending
            }
   in noticed
        { -- Outstanding only when a refresh follows. A declined run reports
          -- itself and nothing overwrites it, and clearing here is also what
          -- retires the previous merge's result.
          appDirectMergeResult =
            if effect.directMergeRefreshesBoard
              then Just (recordDirectMergeShown noticed (DirectMergeReport effect.directMergeNotice 0))
              else Nothing
        }

