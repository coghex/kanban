-- | The dashboard's lifecycle for the persistent issue approval service:
-- the poll it runs, the toggle seam a control invokes, and what an
-- observation does to the state.
--
-- Held apart from "Kanban.UI.PullRequest", which owns the PR drainer's, for
-- the reason the two domains are apart: a shared handler would be one place
-- where either service's observation could be written into the other's field.
--
-- Every transition here is a pure function on 'AppState' with a thin
-- 'EventM' wrapper over it, exactly as the drainer's toggle press is. That is
-- what lets a transition race, a stale completion, and an unsupported host be
-- exercised with no terminal, no controller subprocess, and no service
-- installed — and it leaves the wrappers with only the two things that are not
-- state: the fork a press hands off, and the board refresh a result requires.
--
-- Nothing here draws, binds a key, or claims a click. The control that reaches
-- 'toggleApprovalService' is IAQ-5's; this is the seam it will reach through.
module Kanban.UI.Approval
  ( ApprovalHandoff (..),
    applyApprovalStatus,
    applyApprovalToggle,
    approvalErrorStatus,
    approvalObservationApplied,
    approvalStatusApplied,
    approvalToggleApplied,
    approvalTogglePress,
    monitorApprovalService,
    runApprovalToggleHandoff,
    toggleApprovalService,
  )
where

import Brick
import Brick.BChan (BChan, writeBChan)
import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Kanban.ApprovalService
  ( ApprovalActivity (..),
    ApprovalController,
    ApprovalObservation (..),
    ApprovalState (..),
    ApprovalStatus (..),
    ApprovalToggle (..),
    approvalRefreshRequired,
    approvalToggle,
    approvalUnavailableMessage,
    queryApprovalStatus,
    setApprovalServiceRunning,
  )
import Kanban.Domain (Repository)
import Kanban.Drainer (normalizedRepositoryIdentity)
import Kanban.Text (sanitizeText)
import Kanban.UI.Refresh (requireBoardRefresh)
import Kanban.UI.Types

-- | The controller work one toggle press hands off, and which transition it
-- belongs to.
data ApprovalHandoff = ApprovalHandoff
  { approvalHandoffController :: ApprovalController,
    -- | Whether the service is being started, rather than stopped.
    approvalHandoffStart :: Bool,
    approvalHandoffTransition :: Int
  }

-- | Polls one repository's approval controller on the cadence its caller
-- names, posting each observation to the event channel. The identity is what
-- every decode is validated against, so an observation recorded for another
-- repository is refused rather than shown (requirement 2).
monitorApprovalService :: Repository -> ApprovalController -> Int -> BChan AppEvent -> IO ()
monitorApprovalService repository controller intervalMicros eventChannel = forever $ do
  queryApprovalStatus identity controller >>= writeBChan eventChannel . ApprovalStatusRefreshed
  threadDelay intervalMicros
  where
    identity = normalizedRepositoryIdentity repository

-- | What pressing the approval toggle does to the dashboard, and the
-- controller work it hands off — which this deliberately does not run.
--
-- Splitting the two is what lets the press be exercised: every observable
-- effect of the toggle is the state this returns, so a test can take the press
-- on an unsupported host, or with no installation, and establish that no
-- controller subprocess could have been spawned (requirement 10).
approvalTogglePress :: AppState -> (AppState, Maybe ApprovalHandoff)
approvalTogglePress state = case approvalToggle state.appApprovalBusy state.appApprovalStatus of
  ApprovalToggleBusy notice -> (noticed notice, Nothing)
  decision -> case state.appApprovalController of
    Left unavailable ->
      ( noticed
          ( "Issue approval service control unavailable: "
              <> sanitizeText (approvalUnavailableMessage unavailable)
          ),
        Nothing
      )
    Right controller ->
      let shouldRun = decision == StartApprovalService
          transition = state.appApprovalTransition + 1
          -- The durable barrier is carried through the transition and the live
          -- incident set is not. A barrier is a record on disk that a stop
          -- cannot resolve (requirement 7), while the incident set describes a
          -- service that is being started or stopped underneath it.
          optimistic
            | shouldRun =
                ApprovalStatus
                  ApprovalStarting
                  "starting…"
                  ApprovalServiceStarting
                  state.appApprovalStatus.approvalBarrierIssue
                  Nothing
            | otherwise =
                ApprovalStatus
                  ApprovalStopping
                  "stopping…"
                  ApprovalServiceStopping
                  state.appApprovalStatus.approvalBarrierIssue
                  Nothing
       in ( state
              { appApprovalStatus = optimistic,
                appApprovalIncidents = Nothing,
                appApprovalBusy = True,
                appApprovalTransition = transition,
                appNotice =
                  Just
                    ( if shouldRun
                        then "Starting issue approval service…"
                        else "Stopping issue approval service…"
                    )
              },
            Just (ApprovalHandoff controller shouldRun transition)
          )
  where
    noticed notice = state {appNotice = Just notice}

toggleApprovalService :: EventM Name AppState ()
toggleApprovalService = do
  state <- get
  put (fst (approvalTogglePress state))
  runApprovalToggleHandoff state

-- | Start the controller work a press handed off, if it handed any off. Read
-- off the state the press was taken from, so the decision is made once.
runApprovalToggleHandoff :: AppState -> EventM Name AppState ()
runApprovalToggleHandoff state = case snd (approvalTogglePress state) of
  Nothing -> pure ()
  Just handoff ->
    void
      . liftIO
      . forkIO
      $ setApprovalServiceRunning
        (normalizedRepositoryIdentity state.appRepository)
        handoff.approvalHandoffController
        handoff.approvalHandoffStart
        >>= writeBChan state.appEventChannel . ApprovalToggleFinished handoff.approvalHandoffTransition

-- | What one authoritative observation does to the state, and whether it
-- reports a result the board has to be refreshed for.
--
-- The observation supersedes any optimistic transition and clears the busy
-- flag, which is what keeps control from staying refused after a start or stop
-- this dashboard can no longer hear back about. The refresh verdict is
-- returned rather than acted on here, so the whole decision is inspectable
-- without a coordinator.
approvalObservationApplied :: ApprovalObservation -> AppState -> (AppState, Bool)
approvalObservationApplied observation state =
  ( state
      { appApprovalStatus = observation.observedApprovalStatus,
        appApprovalIncidents = observation.observedApprovalIncidents,
        appApprovalBusy = False,
        appApprovalResult = Just observation.observedApprovalResult
      },
    approvalRefreshRequired state.appApprovalResult observation.observedApprovalResult
  )

-- | What one poll's answer does.
--
-- A failed poll is not an authoritative observation: it says only that this
-- end could not read the service. While a transition this dashboard started is
-- still in flight it therefore changes nothing, so a status query that times
-- out beside a running @start@ cannot replace the optimistic state that
-- transition's own completion is about to settle.
approvalStatusApplied :: Either Text ApprovalObservation -> AppState -> (AppState, Bool)
approvalStatusApplied result state = case result of
  Left message
    | state.appApprovalBusy -> (state, False)
    | otherwise ->
        ( state
            { appApprovalStatus = approvalErrorStatus message,
              appApprovalIncidents = Nothing
            },
          False
        )
  Right observation -> approvalObservationApplied observation state

-- | What one start or stop's completion does.
--
-- A completion belonging to a superseded transition is discarded outright: it
-- must neither restore the optimistic state a newer press replaced nor
-- overwrite an observation newer than itself. A completion that /is/ current
-- clears the busy flag however it ended, so a failed control operation can
-- never leave the toggle permanently refused; and it replaces the status only
-- while this transition's own optimistic state is still what stands, since a
-- poll that has already superseded it holds the newer answer.
approvalToggleApplied :: Int -> Either Text ApprovalObservation -> AppState -> (AppState, Bool)
approvalToggleApplied transition result state
  | transition /= state.appApprovalTransition = (state, False)
  | otherwise = case result of
      Right observation ->
        let (applied, refresh) = approvalObservationApplied observation state
         in ( applied
                { appNotice =
                    Just
                      ( "Issue approval service is "
                          <> observation.observedApprovalStatus.approvalDetail
                      )
                },
              refresh
            )
      Left message ->
        ( ( if state.appApprovalBusy
              then
                state
                  { appApprovalStatus = approvalErrorStatus message,
                    appApprovalIncidents = Nothing
                  }
              else state
          )
            { appApprovalBusy = False,
              appNotice = Just ("Issue approval service control failed: " <> sanitizeText message)
            },
          False
        )

applyApprovalStatus :: Either Text ApprovalObservation -> EventM Name AppState ()
applyApprovalStatus = withRequiredRefresh . approvalStatusApplied

applyApprovalToggle :: Int -> Either Text ApprovalObservation -> EventM Name AppState ()
applyApprovalToggle transition = withRequiredRefresh . approvalToggleApplied transition

-- | Carries out one decided transition: the state it produces, and then the
-- board refresh it asks for.
--
-- The refresh is /required/ rather than merely started, so a fetch already in
-- flight leaves a follow-up behind instead of swallowing the request: that
-- fetch may have read GitHub before the service's review landed
-- (requirement 9).
withRequiredRefresh :: (AppState -> (AppState, Bool)) -> EventM Name AppState ()
withRequiredRefresh decide = do
  state <- get
  let (applied, refresh) = decide state
  put applied
  when refresh requireBoardRefresh

-- | A controller that could not be discovered, run, or decoded leaves the
-- service's actual state unknown — never "off" — so nothing that may only act
-- against a settled stop can act on this.
approvalErrorStatus :: Text -> ApprovalStatus
approvalErrorStatus message =
  ApprovalStatus ApprovalError (sanitizeText message) ApprovalServiceUnknown Nothing Nothing
