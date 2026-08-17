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
import Data.IORef (readIORef, writeIORef)
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
import Data.IORef (IORef)
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
--
-- Each poll carries the transition count read immediately /before/ its query
-- was issued, not after. That is the whole point of stamping it: a query that
-- began before a toggle press returns a read of the service as it was before
-- that press, and a dashboard which let such a read settle the press would
-- show the state the toggle just changed.
monitorApprovalService :: Repository -> ApprovalController -> Int -> IORef Int -> BChan AppEvent -> IO ()
monitorApprovalService repository controller intervalMicros epoch eventChannel = forever $ do
  issuedUnder <- readIORef epoch
  observed <- queryApprovalStatus identity controller
  writeBChan eventChannel (ApprovalStatusRefreshed issuedUnder observed)
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
  Just handoff -> do
    -- Published before the controller work starts, and synchronously on the
    -- event thread, so every poll issued from here on is stamped with the new
    -- transition and every poll already in flight keeps the old one.
    liftIO (writeIORef state.appApprovalEpoch handoff.approvalHandoffTransition)
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

-- | What one poll's answer does, given the transition it was issued under.
--
-- A poll stamped with an older transition began before a press this dashboard
-- has since made. Whatever it says describes the service as it was before that
-- press, so it is discarded outright: letting it through would settle the
-- transition it never saw — clearing the busy flag on a pre-press @stopped@
-- read, which then makes the real start's completion look late and leaves the
-- board reporting off while the service runs.
--
-- A failed poll is not an authoritative observation either: it says only that
-- this end could not read the service. While a transition is still in flight it
-- therefore changes nothing, so a status query that times out beside a running
-- @start@ cannot replace the optimistic state that transition's own completion
-- is about to settle.
approvalStatusApplied :: Int -> Either Text ApprovalObservation -> AppState -> (AppState, Bool)
approvalStatusApplied issuedUnder result state
  | issuedUnder /= state.appApprovalTransition = (state, False)
  | otherwise = case result of
      Left message
        | state.appApprovalBusy -> (state, False)
        | otherwise -> (forgetObservation (approvalErrorStatus message) state, False)
      Right observation -> approvalObservationApplied observation state

-- | Drop everything the last good observation established, keeping only the
-- reason it could not be refreshed.
--
-- The cached result goes with the status, because the canonical-review
-- interlock reads it: a last observation that happened to carry a live backend
-- PID would otherwise go on refusing card reviews indefinitely, on the strength
-- of a reading this dashboard has just said it cannot vouch for. Failing open
-- there is the same choice the live check at the launch boundary makes, and for
-- the same reason — the backend's approval lock is the authority, so an
-- unreadable service must not become one that blocks all explicit work.
forgetObservation :: ApprovalStatus -> AppState -> AppState
forgetObservation status state =
  state
    { appApprovalStatus = status,
      appApprovalIncidents = Nothing,
      appApprovalResult = Nothing
    }

-- | What one start or stop's completion does.
--
-- It applies only while the optimistic transition it belongs to is still what
-- stands. Two things end that, and both mean something newer is already on
-- screen:
--
-- * another press, which bumps 'appApprovalTransition' — so a slow start's
--   completion can never restore its own optimistic state over the stop that
--   replaced it; and
-- * an authoritative poll, which clears 'appApprovalBusy' — so a completion
--   carrying a read taken /before/ that poll cannot put it back, which is how a
--   newly observed barrier would otherwise be overwritten by the running or
--   stopped answer the transition itself returned.
--
-- Either way the completion is discarded outright rather than partly applied.
-- Nothing is owed to it: the busy flag it would have cleared is already clear,
-- so control is not refused, and the status it would have written is older
-- than the one it would replace.
--
-- A completion that /is/ current clears the busy flag however it ended, so a
-- failed control operation can never leave the toggle permanently refused.
approvalToggleApplied :: Int -> Either Text ApprovalObservation -> AppState -> (AppState, Bool)
approvalToggleApplied transition result state
  | transition /= state.appApprovalTransition = (state, False)
  | not state.appApprovalBusy = (state, False)
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
        ( (forgetObservation (approvalErrorStatus message) state)
            { appApprovalBusy = False,
              appNotice = Just ("Issue approval service control failed: " <> sanitizeText message)
            },
          False
        )

applyApprovalStatus :: Int -> Either Text ApprovalObservation -> EventM Name AppState ()
applyApprovalStatus issuedUnder = withRequiredRefresh . approvalStatusApplied issuedUnder

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
