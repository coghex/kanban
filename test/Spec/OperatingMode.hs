-- | What a Kanban whose roster loads no provider does with the surfaces that
-- drive an agent (issue #521, narrowed by issue #546).
--
-- Which bindings the mode hides is "Spec.UI.Keys", and what the board then
-- looks like is "Spec.UI.Golden". What is here is everything the mode changes
-- behind the drawing: the key press that still dispatches and is refused, the
-- usage probes that are not spawned, and the two run-and-exit modes that
-- refuse before they run. Beside them is the other half of the mode's
-- contract — the work such a board inherits from worker discovery, which it
-- must still be able to inspect, open, and terminate, and which the board
-- card's right click is the second route to.
--
-- Every one of those is a total function the corresponding @EventM@ arm only
-- projects — 'boardActionGate' and 'settleBoardAction' for a press,
-- 'runningProcessClickRefusal' and 'applyRunningProcessClick' for the mouse,
-- 'agentSessionEntries' and the two @workerFor@ lookups for the inspector and
-- the kill route, 'usageRefreshProviders' for the probes, and
-- 'launchModeRefusal' for the command line — so the whole matrix is settled
-- with no terminal, no subprocess, and no provider account.
module Spec.OperatingMode (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Kanban.ApprovalService (ApprovalActivity (..), ApprovalState (..), ApprovalStatus (..))
import Kanban.CLI (LaunchMode (..), Options (..), launchMode, launchModeNeedsProvider, launchModeRefusal)
import Kanban.Domain
import Kanban.Drainer (DrainerActivity (..), DrainerState (..), DrainerStatus (..))
import Kanban.Filter (FilterCriteria (..), LifecycleFacet (..))
import Kanban.Models
  ( RosterDefect (..),
    RosterFailure (..),
    RosterLoadError (..),
    ProviderName (..),
    RoleName (..),
    defaultRoster,
    noAgentModeMessage,
    operatingModeFor,
  )
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..))
import Kanban.Solve (SolveWorkflow (..), SolverBrand (..))
import Kanban.UI.Events
  ( BoardActionGate (..),
    applyRunningProcessClick,
    blockedByCompletedLoad,
    boardActionGate,
    mutatesSelectedWork,
    readOnlyHistoryGate,
    runningProcessClickRefusal,
    settleBoardAction,
    settledSessionRefusal,
  )
import Kanban.UI.Keys (BoardAction (..), KeyBinding (..), binding, bindingEvent, boardAction)
import Kanban.UI.Refresh (usageRefreshProviders)
import Kanban.UI.Session
  ( agentSessionEntries,
    pullRequestWorkerFor,
    resolveProcessSelection,
    solveWorkerFor,
  )
import Kanban.UI.Types
  ( AgentSessionEntry (..),
    AgentSessionRef (..),
    AppState (..),
    CompletedHistoryStatus (..),
    Overlay (..),
    ProcessSelection (..),
    ReviewPhase (..),
    SolvePhase (..),
    withModelRoster,
  )
import Kanban.UI.Util (selectedRow, shownNotice)
import Kanban.UI.Worker (recoveredPullRequestSession, recoveredSolveSession)
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerTask (..),
    descriptorForSpec,
  )
import Kanban.Workflow (readOnlyHistoryNotice)
import Spec.Support.App (testAppState, withPullRequestSession, withReviewSession, withSolveSession)
import Spec.Support.Fixtures (baseIssue, basePullRequest, fixtureBoard, testOptions)
import Spec.Support.Process (workerFixtureSpec)
import Spec.Support.Roster (claudeOnlyRoster, noAgentRoster)
import Test.Hspec

spec :: Spec
spec = describe "no-agent operating mode" $ do
  dispatchSpec
  recoverySpec
  mouseSpec
  probeSpec
  commandLineSpec

-- ---------------------------------------------------------------------------
-- The keyboard
-- ---------------------------------------------------------------------------

dispatchSpec :: Spec
dispatchSpec = describe "the four bindings it refuses" $ do
  -- Requirement 2's first half. The keys are hidden, not removed: the table
  -- in "Kanban.UI.Keys" is what dispatch resolves against and it carries no
  -- mode at all, so a press still arrives at its own action and meets the
  -- gate rather than falling through to whatever comes next.
  it "still resolves every hidden key to its own action, in every scope" $
    sequence_
      [ (candidate.bindingAction, scope, boardAction scope (bindingEvent pressed))
          `shouldBe` (candidate.bindingAction, scope, Just candidate.bindingAction)
        | action <- agentBindings,
          let candidate = binding action,
          scope <- candidate.bindingScopes,
          pressed <- candidate.bindingKeys
      ]

  it "refuses each of them with the roster's own words" $ do
    quiet <- noAgentState
    sequence_
      [ (action, boardActionGate quiet action) `shouldBe` (action, RefuseBoardAction noAgentModeMessage)
        | action <- agentBindings
      ]

  -- The negative control on the other side of the same gate: everything else
  -- dispatches, so a gate that refused the whole table could not pass above.
  it "leaves every other binding dispatching" $ do
    quiet <- noAgentState
    sequence_
      [ (action, boardActionGate quiet action) `shouldBe` (action, DispatchBoardAction)
        | action <- [minBound .. maxBound],
          action `notElem` agentBindings
      ]

  it "leaves a board that loads a provider dispatching all of them" $ do
    dual <- quietState
    single <- withModelRoster (Right claudeOnlyRoster) <$> quietState
    sequence_
      [ (name, action, boardActionGate state action) `shouldBe` (name, action, DispatchBoardAction)
        | (name, state) <- [("dual" :: String, dual), ("single-agent", single)],
          action <- [minBound .. maxBound]
      ]

  -- The review's precedence amendment, on the settled-history gate. The same
  -- press on the same card answers with the history notice on a board that
  -- loads a provider, so this is about which of the two refusals wins rather
  -- than about one of them being absent.
  it "outranks the settled-history refusal on a card the history has closed" $ do
    dual <- overlaidOnSettledCard <$> quietState
    quiet <- overlaidOnSettledCard <$> noAgentState
    sequence_
      [ (action, boardActionGate dual action)
          `shouldBe` (action, RefuseBoardAction (readOnlyHistoryNotice settledItem))
        | action <- settledMutations
      ]
    sequence_
      [ (action, boardActionGate quiet action) `shouldBe` (action, RefuseBoardAction noAgentModeMessage)
        | action <- settledMutations
      ]

  -- And the other gate, which makes a press inert and says nothing at all.
  -- Refusing it silently is exactly what requirement 2 forbids, so the mode
  -- has to be asked first here too.
  it "outranks the completed-history blocker, which would say nothing" $ do
    dual <- blockedOnCompletedLoad <$> quietState
    quiet <- blockedOnCompletedLoad <$> noAgentState
    sequence_
      [ (action, boardActionGate dual action) `shouldBe` (action, IgnoreBoardAction)
        | action <- settledMutations
      ]
    sequence_
      [ (action, boardActionGate quiet action) `shouldBe` (action, RefuseBoardAction noAgentModeMessage)
        | action <- settledMutations
      ]

  -- Issue #546 requirement 5. `x` is the one binding that moved out of the
  -- mode's reach and into these two gates', so the card's own answer is now
  -- the only one it has -- word for word the answer a board that loads a
  -- provider gives, which is what the dual side proves is not a coincidence.
  it "answers x on a settled card with the history notice, as a loaded board does" $ do
    dual <- overlaidOnSettledCard <$> quietState
    quiet <- overlaidOnSettledCard <$> noAgentState
    sequence_
      [ (name, boardActionGate state KillWorking)
          `shouldBe` (name, RefuseBoardAction (readOnlyHistoryNotice settledItem))
        | (name, state) <- [("dual" :: String, dual), ("no-agent", quiet)]
      ]

  it "answers x behind a loading completed generation the same way in both" $ do
    dual <- blockedOnCompletedLoad <$> quietState
    quiet <- blockedOnCompletedLoad <$> noAgentState
    sequence_
      [ (name, boardActionGate state KillWorking) `shouldBe` (name, IgnoreBoardAction)
        | (name, state) <- [("dual" :: String, dual), ("no-agent", quiet)]
      ]

  -- The review's other precedence amendment. `a` is refused with the same
  -- words as the other three but is absent from 'settledMutations', and this
  -- is why: neither card gate claims it, so on a board that loads a provider
  -- the very states that refuse the other three leave this one dispatching.
  -- Without that, its absence above would read as an oversight.
  it "refuses a with no competing card gate to outrank" $ do
    quiet <- noAgentState
    settledQuiet <- overlaidOnSettledCard <$> noAgentState
    blockedQuiet <- blockedOnCompletedLoad <$> noAgentState
    settledDual <- overlaidOnSettledCard <$> quietState
    blockedDual <- blockedOnCompletedLoad <$> quietState
    blockedByCompletedLoad ToggleApproval `shouldBe` False
    mutatesSelectedWork ToggleApproval `shouldBe` False
    sequence_
      [ (name, boardActionGate state ToggleApproval)
          `shouldBe` (name, RefuseBoardAction noAgentModeMessage)
        | (name, state) <- [("plain" :: String, quiet), ("settled", settledQuiet), ("loading", blockedQuiet)]
      ]
    sequence_
      [ (name, boardActionGate state ToggleApproval) `shouldBe` (name, DispatchBoardAction)
        | (name, state) <- [("settled" :: String, settledDual), ("loading", blockedDual)]
      ]

  -- And the handoff that refusal must not make, on a dashboard whose approval
  -- service is mid-transition: the state 'Kanban.UI.Events.toggleApproval'
  -- would move is exactly what a refused press leaves alone.
  it "hands nothing to the approval service when it refuses a" $ do
    populated <- populatedNoAgentState
    let pressed = refused populated ToggleApproval
    pressed.appApprovalStatus `shouldBe` populated.appApprovalStatus
    pressed.appApprovalBusy `shouldBe` populated.appApprovalBusy
    pressed.appApprovalTransition `shouldBe` populated.appApprovalTransition
    shownNotice pressed `shouldBe` Just noAgentModeMessage

  -- Requirement 2's second half, taken against a dashboard that has one of
  -- everything the refusal must not touch.
  it "changes the notice and nothing else" $ do
    populated <- populatedNoAgentState
    sequence_
      [ (action, surfaceFacts (refused populated action)) `shouldBe` (action, surfaceFacts populated)
        | action <- agentBindings
      ]
    sequence_
      [ (action, shownNotice (refused populated action)) `shouldBe` (action, Just noAgentModeMessage)
        | action <- agentBindings
      ]

-- | One refused press, carried out the way 'Kanban.UI.Events.applyBoardAction'
-- carries it out: the gate's decision, then the whole of what that decision
-- does to the state.
refused :: AppState -> BoardAction -> AppState
refused state action = settleBoardAction (boardActionGate state action) state

-- ---------------------------------------------------------------------------
-- The work it inherits
-- ---------------------------------------------------------------------------

recoverySpec :: Spec
recoverySpec = describe "the persistent work it inherits" $ do
  -- Issue #546 requirement 4, first part. Worker discovery does not consult
  -- the roster, so this dashboard has exactly the state a restart under an
  -- empty @agents@ list leaves behind, and `p` must reach it.
  it "lists both discovered workers in the inspector, live" $ do
    (quiet, _, _) <- attachedWorkerState
    let entries = agentSessionEntries quiet
    map (.agentSessionRef) entries
      `shouldMatchList` [SolveAgent recoveredIssueNumber, PullRequestAgent recoveredPullRequestNumber]
    map (.agentSessionLive) entries `shouldBe` [True, True]
    -- What `p` selects when the inspector opens: a row that exists, so
    -- 'Kanban.UI.Events.openSelectedAgentSession' has an entry to act on
    -- rather than the no-selection notice.
    (resolveProcessSelection entries quiet.appProcessSelection).processSelectionRow `shouldSatisfy` (< length entries)

  -- The review's fixture clarification, as the control that gives the
  -- assertion above its teeth. Attachment reconstructs a session only when
  -- the cached board still carries the worker's issue or PR; without that
  -- metadata each worker is left as a 'WorkerAgent' row, which opens nothing
  -- and reports a refresh notice instead. Both fixtures register the same two
  -- descriptors, so the board metadata is the only difference between them.
  it "leaves a worker whose card is off the board unattached instead" $ do
    (stranded, _, _) <- discoveredWorkerState (fixtureBoard [])
    map (.agentSessionRef) (agentSessionEntries stranded)
      `shouldMatchList` [WorkerAgent solveWorkerId, WorkerAgent pullRequestWorkerId]
    (quiet, _, _) <- attachedWorkerState
    filter isUnattachedWorker (map (.agentSessionRef) (agentSessionEntries quiet)) `shouldBe` []

  -- Requirement 4's overlays, through the pure route both ways in: the right
  -- click on the card (requirement 3), which resolves the same overlay
  -- 'Kanban.UI.Events.openSelectedAgentSession' opens for the matching row.
  it "opens each recovered session's overlay from its card" $ do
    (quiet, _, _) <- attachedWorkerState
    (applyRunningProcessClick Active 0 quiet).appOverlay
      `shouldBe` Just (SolveOverlay recoveredIssueNumber)
    (applyRunningProcessClick Reviewing 0 quiet).appOverlay
      `shouldBe` Just (PullRequestReviewOverlay recoveredPullRequestNumber)
    runningProcessClickRefusal quiet `shouldBe` Nothing

  -- Requirement 4's kill route, held to the boundary the review's second
  -- clarification draws: what is asserted is that `x` arrives at the existing
  -- worker termination with the right descriptor in hand. Authority,
  -- TERM/KILL escalation, survivor verification, and lease retention are
  -- unchanged by this issue and stay covered by
  -- "Spec.Agent.ManagedProcess.Lifecycle".
  it "routes x to the worker termination boundary for the selected card" $ do
    (quiet, solveDescriptor, pullRequestDescriptor) <- attachedWorkerState
    sequence_
      [ (name, boardActionGate (selecting column 0 quiet) KillWorking)
          `shouldBe` (name, DispatchBoardAction)
        | (name, column) <- [("solve" :: String, Active), ("pr", Reviewing)]
      ]
    -- Neither card is history, so 'killItemWorkingProcess' passes its own
    -- re-ask of that gate and reaches 'killLiveItemWorkingProcess'...
    sequence_
      [ (name, readOnlyHistoryGate (selecting column 0 quiet) KillWorking) `shouldBe` (name, Nothing)
        | (name, column) <- [("solve" :: String, Active), ("pr", Reviewing)]
      ]
    -- ...which hands `terminateWorker` exactly these descriptors.
    solveWorkerFor quiet recoveredIssueNumber `shouldBe` Just solveDescriptor
    pullRequestWorkerFor quiet recoveredPullRequestNumber `shouldBe` Just pullRequestDescriptor

  -- And the inspector's own `x`, which reaches the same termination through a
  -- row rather than a card. 'Kanban.UI.Events.killSelectedAgentSession' asks
  -- these two questions before it acts, and both have to answer for a
  -- recovered worker or the row would report history or no live process.
  it "routes the inspector's x to the same boundary" $ do
    (quiet, _, _) <- attachedWorkerState
    sequence_
      [ (entry.agentSessionRef, settledSessionRefusal quiet entry.agentSessionRef, entry.agentSessionLive)
          `shouldBe` (entry.agentSessionRef, Nothing, True)
        | entry <- agentSessionEntries quiet
      ]

  -- The out-of-scope boundary restated as an assertion: nothing about this
  -- board starts a provider. The usage probes stay empty and the four
  -- creation surfaces stay refused with a live worker under the selection,
  -- which is the state that would most plausibly have talked one of them
  -- into launching.
  it "still starts nothing on a board carrying both workers" $ do
    (quiet, _, _) <- attachedWorkerState
    usageRefreshProviders quiet.appOperatingMode `shouldBe` []
    sequence_
      [ (name, action, boardActionGate (selecting column 0 quiet) action)
          `shouldBe` (name, action, RefuseBoardAction noAgentModeMessage)
        | (name, column) <- [("solve" :: String, Active), ("pr", Reviewing)],
          action <- agentBindings
      ]

-- ---------------------------------------------------------------------------
-- The mouse
-- ---------------------------------------------------------------------------

mouseSpec :: Spec
mouseSpec = describe "the right click that is a second route" $ do
  -- Requirement 3. The gesture opens exactly the overlays `p` and then Enter
  -- open, so since issue #546 it is an inspection route rather than one that
  -- starts work, and it borrows 'ShowProcesses' rather than 'ReviewSelection'
  -- from the gate. It opened and was then refused while both bindings sat on
  -- the same side of it; only the first half of that survives.
  it "opens the live session on a board that loads a provider" $ do
    dual <- liveSessionState
    (applyRunningProcessClick Issues 0 dual).appOverlay `shouldBe` Just (ReviewOverlay liveIssueNumber)
    runningProcessClickRefusal dual `shouldBe` Nothing

  it "opens it on a board that loads none, and says nothing" $ do
    quiet <- withModelRoster (Right noAgentRoster) <$> liveSessionState
    let clicked = applyRunningProcessClick Issues 0 quiet
    runningProcessClickRefusal quiet `shouldBe` Nothing
    clicked.appOverlay `shouldBe` Just (ReviewOverlay liveIssueNumber)
    shownNotice clicked `shouldBe` Nothing
    -- Still a click: it selects the card it landed on, as it always did.
    clicked.appSelectedColumn `shouldBe` Issues
    selectedRow clicked Issues `shouldBe` 0
    -- And it leaves the session it opened exactly where it was.
    Map.keys clicked.appReviewSessions `shouldBe` [liveIssueNumber]

  -- The press with nothing live under it was never opening an agent overlay,
  -- so it keeps selecting as before in every mode.
  it "leaves a card with no live session selecting, and says nothing" $ do
    quiet <- withModelRoster (Right noAgentRoster) <$> liveSessionState
    let clicked = applyRunningProcessClick Issues 1 quiet
    clicked.appOverlay `shouldBe` Nothing
    shownNotice clicked `shouldBe` Nothing
    selectedRow clicked Issues `shouldBe` 1

-- ---------------------------------------------------------------------------
-- The usage probes
-- ---------------------------------------------------------------------------

probeSpec :: Spec
probeSpec = describe "the usage probes it does not spawn" $ do
  -- Requirement 5. Startup, `u`, and the sidebar's ↻ all reach
  -- 'Kanban.UI.Refresh.startUsageRefreshes', and this is the whole of what it
  -- decides, so covering it covers all three.
  it "probes no provider at all with none loaded" $
    usageRefreshProviders (operatingModeFor noAgentRoster) `shouldBe` []

  -- The negative control. Dual still probes both, in file order; what
  -- single-agent narrows it to is "Spec.SingleAgentMode"'s question, and the
  -- boundary between the two modes is here.
  it "probes both providers in dual mode, and one in single-agent" $
    sequence_
      [ (name, usageRefreshProviders (operatingModeFor roster)) `shouldBe` (name, expected)
        | (name, roster, expected) <-
            [ ("dual" :: String, defaultRoster, [Codex, Claude]),
              ("single-agent", claudeOnlyRoster, [Claude])
            ]
      ]

-- ---------------------------------------------------------------------------
-- The command line
-- ---------------------------------------------------------------------------

commandLineSpec :: Spec
commandLineSpec = describe "the run-and-exit modes it refuses" $ do
  -- Requirement 6. @app/Main.hs@ is not built by this suite, so the decision
  -- is here and that module only reports what it answered.
  it "names exactly the two modes that reach a provider" $
    map launchModeNeedsProvider everyMode `shouldBe` [False, False, False, False, True, True, False]

  it "refuses --usage and --ping with the roster's own words" $
    sequence_
      [ (mode, launchModeRefusal mode (Right noAgentRoster)) `shouldBe` (mode, Just noAgentModeMessage)
        | mode <- [UsageQueryMode, PingQueryMode]
      ]

  -- The review's amendment: an unusable @models.toml@ is no-agent through
  -- 'Kanban.Models.loadedOperatingMode', so the refusal has to reach a 'Left'
  -- and not only a valid roster with an empty @agents@ list.
  it "refuses a models.toml that will not load at all" $
    sequence_
      [ (mode, launchModeRefusal mode (Left unusableRoster)) `shouldBe` (mode, Just noAgentModeMessage)
        | mode <- [UsageQueryMode, PingQueryMode]
      ]

  it "leaves both of them running on a roster that loads a provider" $
    sequence_
      [ (name, mode, launchModeRefusal mode (Right roster)) `shouldBe` (name, mode, Nothing)
        | (name, roster) <- [("dual" :: String, defaultRoster), ("single-agent", claudeOnlyRoster)],
          mode <- [UsageQueryMode, PingQueryMode]
      ]

  -- Everything else answers about the terminal, its own recorded
  -- specification, or the board, so none of it is refused — `--doctor` least
  -- of all, since saying why an AI action would not start is what it is for.
  it "refuses no other mode, whatever the roster" $
    sequence_
      [ (mode, launchModeRefusal mode loaded) `shouldBe` (mode, Nothing)
        | mode <- everyMode,
          mode `notElem` [UsageQueryMode, PingQueryMode],
          loaded <- [Right noAgentRoster, Left unusableRoster, Right defaultRoster]
      ]

-- | Every mode, in 'launchMode''s own selection order, taken through that
-- function rather than written out, so the list cannot claim an order the
-- selector does not have.
everyMode :: [LaunchMode]
everyMode =
  map
    launchMode
    [ testOptions {optionWorkerSpec = Just "/tmp/spec.json"},
      testOptions {optionReviewTools = Just "/tmp/endpoint"},
      testOptions {optionGlyphTest = True},
      testOptions {optionDoctor = True},
      testOptions {optionUsage = True},
      testOptions {optionPing = ["codex"]},
      testOptions
    ]

-- | A present @models.toml@ the loader refused, which is the state
-- 'Kanban.Models.loadedOperatingMode' maps to no-agent without an @agents@
-- list to count.
unusableRoster :: RosterLoadError
unusableRoster =
  RosterLoadError
    "/fixture/home/.config/kanban/models.toml"
    (RosterInvalid [UnknownModel PrReviewRole CodexProvider "gpt-5.9"])

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

-- | The four bindings the mode takes off a board, in table order. @x@ and
-- @p@ were among them until issue #546 and are covered by 'recoverySpec'
-- instead.
agentBindings :: [BoardAction]
agentBindings =
  [ ReviewSelection,
    SolveSelection,
    AutoSolveSelection,
    ToggleApproval
  ]

-- | The three of them that both other gates also have an answer for, which is
-- what makes the two precedence cases about ordering rather than about a gate
-- that was never going to fire.
--
-- @a@ is the fourth refused binding and is deliberately absent:
-- 'Kanban.UI.Events.blockedByCompletedLoad' and
-- 'Kanban.UI.Events.mutatesSelectedWork' are both 'False' for it, so it has
-- no competing answer for the ordering to be about, and it is covered on its
-- own below instead. @x@ is absent for the opposite reason -- since issue
-- \#546 the mode has nothing to say about that key, so the two gates here
-- give the only answer there is, which is what 'settledKillNotice' asserts.
settledMutations :: [BoardAction]
settledMutations = [ReviewSelection, SolveSelection, AutoSolveSelection]

-- | An ordinary dashboard on the compiled roster: dual, nothing open, nothing
-- in flight.
quietState :: IO AppState
quietState = testAppState (fixtureBoard [])

-- | The same dashboard with a roster that loads no provider.
noAgentState :: IO AppState
noAgentState = withModelRoster (Right noAgentRoster) <$> quietState

-- | The card a completed generation has settled, held open in a details
-- overlay — which is where 'Kanban.UI.Events.readOnlyHistoryGate' finds its
-- subject without a board rebuild.
settledItem :: BoardItem
settledItem = IssueItem ((baseIssue 940 []) {issueState = IssueClosed})

overlaidOnSettledCard :: AppState -> AppState
overlaidOnSettledCard state = state {appOverlay = Just (DetailsOverlay settledItem)}

-- | The state the completed-history blocker is up in: Closed admitted, and a
-- generation still running behind it.
blockedOnCompletedLoad :: AppState -> AppState
blockedOnCompletedLoad state =
  state
    { appFilterCriteria =
        state.appFilterCriteria
          {filterLifecycle = Set.insert LifecycleClosed state.appFilterCriteria.filterLifecycle},
      appCompletedStatus = CompletedHistoryLoading
    }

-- | A no-agent dashboard carrying one of everything a refused press must not
-- disturb: a session of each kind, a service on its way up, and a card
-- selected in a column other than the first.
populatedNoAgentState :: IO AppState
populatedNoAgentState = do
  quiet <- noAgentState
  pure
    . withSolveSession (baseIssue 902 []) SolveRunning
    . withPullRequestSession (basePullRequest 823 [901] False []) SolveRunning
    . withReviewSession (baseIssue 901 []) ReviewRunning
    $ quiet
      { appApprovalStatus = ApprovalStatus ApprovalStarting "starting…" ApprovalServiceStopped Nothing Nothing,
        appApprovalBusy = True,
        appApprovalTransition = 3,
        appDrainerStatus = DrainerStatus DrainerOn "running" DrainerServiceRunning Nothing,
        appSelectedColumn = Active
      }

-- | Everything requirement 2 says a refused press leaves alone: session,
-- chooser, overlay, process, and approval state, plus the board selection the
-- press was taken from.
data SurfaceFacts = SurfaceFacts
  { factsOverlay :: Maybe Overlay,
    factsSolveSessions :: [Int],
    factsReviewSessions :: [Int],
    factsPullRequestSessions :: [Int],
    factsSolveProcesses :: [Int],
    factsCanonicalReviewProcesses :: [Int],
    factsPullRequestProcesses :: [Int],
    factsApprovalState :: ApprovalState,
    factsApprovalDetail :: Text,
    factsApprovalBusy :: Bool,
    factsApprovalTransition :: Int,
    factsDrainerState :: DrainerState,
    factsDrainerBusy :: Bool,
    factsSelectedColumn :: BoardColumn,
    factsSelectedRow :: Int
  }
  deriving stock (Eq, Show)

surfaceFacts :: AppState -> SurfaceFacts
surfaceFacts state =
  SurfaceFacts
    { factsOverlay = state.appOverlay,
      factsSolveSessions = Map.keys state.appSolveSessions,
      factsReviewSessions = Map.keys state.appReviewSessions,
      factsPullRequestSessions = Map.keys state.appPullRequestReviewSessions,
      factsSolveProcesses = Map.keys state.appSolveProcesses,
      factsCanonicalReviewProcesses = Map.keys state.appCanonicalReviewProcesses,
      factsPullRequestProcesses = Map.keys state.appPullRequestProcesses,
      factsApprovalState = state.appApprovalStatus.approvalState,
      factsApprovalDetail = state.appApprovalStatus.approvalDetail,
      factsApprovalBusy = state.appApprovalBusy,
      factsApprovalTransition = state.appApprovalTransition,
      factsDrainerState = state.appDrainerStatus.drainerState,
      factsDrainerBusy = state.appDrainerBusy,
      factsSelectedColumn = state.appSelectedColumn,
      factsSelectedRow = selectedRow state state.appSelectedColumn
    }

-- | The issue and the PR a previous run left persistent workers on, which
-- this dashboard inherits with no provider loaded.
recoveredIssueNumber, recoveredPullRequestNumber :: Int
recoveredIssueNumber = 902
recoveredPullRequestNumber = 823

recoveredIssue :: Issue
recoveredIssue = baseIssue recoveredIssueNumber []

recoveredPullRequest :: PullRequest
recoveredPullRequest = basePullRequest recoveredPullRequestNumber [recoveredIssueNumber] False []

recoveredSolveTask :: SolveWorkerTask
recoveredSolveTask = SolveWorkerTask recoveredIssueNumber SolveOnly ClaudeSolver

recoveredPullRequestTask :: PullRequestWorkerTask
recoveredPullRequestTask = PullRequestWorkerTask recoveredPullRequestNumber PullRequestClaude PullRequestReview

solveWorkerId, pullRequestWorkerId :: WorkerId
solveWorkerId = WorkerId "solve-902-recovered"
pullRequestWorkerId = WorkerId "pr-823-recovered"

-- | The board a restart reads back out of the snapshot cache, carrying the
-- card each worker names. The review's fixture clarification is about exactly
-- this: without these two entries attachment reconstructs no session at all.
recoveredWorkerBoard :: Board
recoveredWorkerBoard =
  fixtureBoard
    [ (Active, [Standalone (IssueItem recoveredIssue)]),
      (Reviewing, [Standalone (PullRequestItem recoveredPullRequest)])
    ]

-- | A no-agent dashboard with both workers registered and nothing else done
-- with them — what 'Kanban.UI.Worker.attachDiscoveredWorker' leaves behind
-- before 'Kanban.UI.Worker.ensureWorkerSession' looks for their cards. The
-- board is a parameter because whether that lookup finds anything is the one
-- thing the two fixtures below differ on.
discoveredWorkerState :: Board -> IO (AppState, WorkerDescriptor, WorkerDescriptor)
discoveredWorkerState board = do
  quiet <- withModelRoster (Right noAgentRoster) <$> testAppState board
  solveDescriptor <- descriptorForSpec (workerSpecFor solveWorkerId (SolveWorkerTaskKind recoveredSolveTask) recoveredIssueNumber)
  pullRequestDescriptor <- descriptorForSpec (workerSpecFor pullRequestWorkerId (PullRequestWorkerTaskKind recoveredPullRequestTask) recoveredPullRequestNumber)
  pure
    ( quiet
        { appWorkers =
            Map.fromList
              [ (solveWorkerId, solveDescriptor),
                (pullRequestWorkerId, pullRequestDescriptor)
              ]
        },
      solveDescriptor,
      pullRequestDescriptor
    )
  where
    workerSpecFor identifier task number =
      (workerFixtureSpec (Repository "/tmp/example-project" "example" "project") identifier number) {workerTask = task}

-- | The same dashboard once attachment has reconstructed a session for each
-- worker, which is the state requirement 4 is about.
--
-- The two sessions are built through the very constructors
-- 'Kanban.UI.Worker.ensureWorkerSession' inserts, on the descriptors
-- discovery produced, rather than written out by hand: that arm runs in
-- brick's 'EventM', which no test in this suite can drive, so this is the
-- same route "Spec.Agent.Roster" takes to the same state.
attachedWorkerState :: IO (AppState, WorkerDescriptor, WorkerDescriptor)
attachedWorkerState = do
  (registered, solveDescriptor, pullRequestDescriptor) <- discoveredWorkerState recoveredWorkerBoard
  pure
    ( registered
        { appSolveSessions =
            Map.singleton
              recoveredIssueNumber
              ( recoveredSolveSession
                  registered
                  solveDescriptor.workerDescriptorSpec.workerAssignment
                  solveDescriptor
                  recoveredIssue
                  recoveredSolveTask
              ),
          appPullRequestReviewSessions =
            Map.singleton
              recoveredPullRequestNumber
              (recoveredPullRequestSession registered.appModelRoster 0 pullRequestDescriptor recoveredPullRequest recoveredPullRequestTask)
        },
      solveDescriptor,
      pullRequestDescriptor
    )

isUnattachedWorker :: AgentSessionRef -> Bool
isUnattachedWorker (WorkerAgent _) = True
isUnattachedWorker _ = False

-- | The board selection a press is taken from, which is what
-- 'Kanban.UI.Events.readOnlyHistoryGate' resolves its subject out of when no
-- details overlay is open.
selecting :: BoardColumn -> Int -> AppState -> AppState
selecting column row state =
  state
    { appSelectedColumn = column,
      appSelectedRows = Map.insert column row state.appSelectedRows
    }

liveIssueNumber :: Int
liveIssueNumber = 901

-- | Two cards in Issues, the first of them carrying a live issue review — the
-- session a right click opens an overlay for — and the second carrying
-- nothing, which is the press that only selects.
liveSessionState :: IO AppState
liveSessionState = do
  state <- testAppState (fixtureBoard [(Issues, [Standalone (IssueItem liveIssue), Standalone (IssueItem quietIssue)])])
  pure (withReviewSession liveIssue ReviewRunning state)
  where
    liveIssue = baseIssue liveIssueNumber []
    quietIssue = baseIssue 902 []
