-- | What a Kanban whose roster loads no provider does with the surfaces that
-- drive an agent (issue #521).
--
-- Which bindings the mode hides is "Spec.UI.Keys", and what the board then
-- looks like is "Spec.UI.Golden". What is here is everything the mode changes
-- behind the drawing: the key press that still dispatches and is refused, the
-- board card's right click that is the second route to the same overlays, the
-- usage probes that are not spawned, and the two run-and-exit modes that
-- refuse before they run.
--
-- Every one of those is a total function the corresponding @EventM@ arm only
-- projects — 'boardActionGate' and 'settleBoardAction' for a press,
-- 'runningProcessClickRefusal' and 'applyRunningProcessClick' for the mouse,
-- 'usageRefreshProviders' for the probes, and 'launchModeRefusal' for the
-- command line — so the whole matrix is settled with no terminal, no
-- subprocess, and no provider account.
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
import Kanban.UI.Events
  ( BoardActionGate (..),
    applyRunningProcessClick,
    boardActionGate,
    runningProcessClickRefusal,
    settleBoardAction,
  )
import Kanban.UI.Keys (BoardAction (..), KeyBinding (..), binding, bindingEvent, boardAction)
import Kanban.UI.Refresh (usageRefreshProviders)
import Kanban.UI.Types
  ( AppState (..),
    CompletedHistoryStatus (..),
    Overlay (..),
    ReviewPhase (..),
    SolvePhase (..),
    withModelRoster,
  )
import Kanban.UI.Util (selectedRow)
import Kanban.Workflow (readOnlyHistoryNotice)
import Spec.Support.App (testAppState, withPullRequestSession, withReviewSession, withSolveSession)
import Spec.Support.Fixtures (baseIssue, basePullRequest, fixtureBoard, testOptions)
import Spec.Support.Roster (claudeOnlyRoster, noAgentRoster)
import Test.Hspec

spec :: Spec
spec = describe "no-agent operating mode" $ do
  dispatchSpec
  mouseSpec
  probeSpec
  commandLineSpec

-- ---------------------------------------------------------------------------
-- The keyboard
-- ---------------------------------------------------------------------------

dispatchSpec :: Spec
dispatchSpec = describe "the six bindings it refuses" $ do
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

  -- Requirement 2's second half, taken against a dashboard that has one of
  -- everything the refusal must not touch.
  it "changes the notice and nothing else" $ do
    populated <- populatedNoAgentState
    sequence_
      [ (action, surfaceFacts (refused populated action)) `shouldBe` (action, surfaceFacts populated)
        | action <- agentBindings
      ]
    sequence_
      [ (action, (refused populated action).appNotice) `shouldBe` (action, Just noAgentModeMessage)
        | action <- agentBindings
      ]

-- | One refused press, carried out the way 'Kanban.UI.Events.applyBoardAction'
-- carries it out: the gate's decision, then the whole of what that decision
-- does to the state.
refused :: AppState -> BoardAction -> AppState
refused state action = settleBoardAction (boardActionGate state action) state

-- ---------------------------------------------------------------------------
-- The mouse
-- ---------------------------------------------------------------------------

mouseSpec :: Spec
mouseSpec = describe "the right click that is a second route" $ do
  -- Requirement 3 with the review's amendment. `p` refusing closes the
  -- inspector, but a right click on a card opens a live agent overlay
  -- directly, so it owes the same refusal or the mode would be reachable
  -- around the keyboard entirely.
  it "opens the live session on a board that loads a provider" $ do
    dual <- liveSessionState
    (applyRunningProcessClick Issues 0 dual).appOverlay `shouldBe` Just (ReviewOverlay liveIssueNumber)
    runningProcessClickRefusal dual `shouldBe` Nothing

  it "refuses with the same words instead, and opens nothing" $ do
    quiet <- withModelRoster (Right noAgentRoster) <$> liveSessionState
    let clicked = applyRunningProcessClick Issues 0 quiet
    runningProcessClickRefusal quiet `shouldBe` Just noAgentModeMessage
    clicked.appOverlay `shouldBe` Nothing
    clicked.appNotice `shouldBe` Just noAgentModeMessage
    -- Still a click: it selects the card it landed on, as it always did.
    clicked.appSelectedColumn `shouldBe` Issues
    selectedRow clicked Issues `shouldBe` 0
    -- And it leaves the session it declined to show exactly where it was.
    Map.keys clicked.appReviewSessions `shouldBe` [liveIssueNumber]

  -- The press with nothing live under it was never opening an agent overlay,
  -- so the mode has nothing to refuse and it keeps selecting as before.
  it "leaves a card with no live session selecting, and says nothing" $ do
    quiet <- withModelRoster (Right noAgentRoster) <$> liveSessionState
    let clicked = applyRunningProcessClick Issues 1 quiet
    clicked.appOverlay `shouldBe` Nothing
    clicked.appNotice `shouldBe` Nothing
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

  -- The negative control, and the out-of-scope boundary: narrowing
  -- single-agent to the brand it loads is MODEL-10's question, not this
  -- slice's, so both loaded modes still probe both providers in file order.
  it "probes both providers in every mode that loads one" $
    sequence_
      [ (name, usageRefreshProviders (operatingModeFor roster)) `shouldBe` (name, [Codex, Claude])
        | (name, roster) <- [("dual" :: String, defaultRoster), ("single-agent", claudeOnlyRoster)]
      ]

-- ---------------------------------------------------------------------------
-- The command line
-- ---------------------------------------------------------------------------

commandLineSpec :: Spec
commandLineSpec = describe "the run-and-exit modes it refuses" $ do
  -- Requirement 6. @app/Main.hs@ is not built by this suite, so the decision
  -- is here and that module only reports what it answered.
  it "names exactly the two modes that reach a provider" $
    map launchModeNeedsProvider everyMode `shouldBe` [False, False, False, True, True, False]

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

-- | The six bindings the mode takes off a board, in table order.
agentBindings :: [BoardAction]
agentBindings =
  [ KillWorking,
    ReviewSelection,
    SolveSelection,
    AutoSolveSelection,
    ShowProcesses,
    ToggleApproval
  ]

-- | The four of them that both other gates also have an answer for, which is
-- what makes the two precedence cases about ordering rather than about a gate
-- that was never going to fire.
settledMutations :: [BoardAction]
settledMutations = [KillWorking, ReviewSelection, SolveSelection, AutoSolveSelection]

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
