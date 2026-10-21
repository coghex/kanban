-- | What a Kanban whose roster loads no provider does with the one surface
-- that still needs one (issue #521, narrowed by issue #546 and by the removal
-- of the agent screens).
--
-- Which bindings the mode hides is "Spec.UI.Keys", and what the board then
-- looks like is "Spec.UI.Golden". What is here is everything the mode changes
-- behind the drawing: the key press that still dispatches and is refused, the
-- usage probes that are not spawned, and the two run-and-exit modes that
-- refuse before they run.
--
-- Every one of those is a total function the corresponding @EventM@ arm only
-- projects -- 'boardActionGate' and 'settleBoardAction' for a press,
-- 'usageRefreshProviders' for the probes, and 'launchModeRefusal' for the
-- command line -- so the whole matrix is settled with no terminal, no
-- subprocess, and no provider account.
module Spec.OperatingMode (spec) where

import Data.List (isInfixOf)
import qualified Data.Set as Set
import Data.Text (Text)
import Kanban.ApprovalService (ApprovalActivity (..), ApprovalState (..), ApprovalStatus (..))
import Kanban.CLI (LaunchMode (..), Options (..), launchMode, launchModeNeedsProvider, launchModeRefusal, optionsParserInfo)
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
    loadedOperatingMode,
    noAgentModeMessage,
    operatingModeFor,
  )
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure, renderFailure)
import Kanban.UI.Events
  ( BoardActionGate (..),
    blockedByCompletedLoad,
    boardActionGate,
    mutatesSelectedWork,
    settleBoardAction,
  )
import Kanban.UI.Keys (BoardAction (..), KeyBinding (..), binding, bindingEvent, boardAction)
import Kanban.UI.Refresh (usageRefreshProviders)
import Kanban.UI.Types
  ( AppState (..),
    CompletedHistoryStatus (..),
    Overlay (..),
  )
import Kanban.UI.Util (selectedRow, shownNotice)
import Spec.Support.App (testAppState)
import Spec.Support.Fixtures (baseIssue, fixtureBoard, testOptions)
import Spec.Support.Roster (claudeOnlyRoster, noAgentRoster)
import System.Exit (ExitCode (..))
import Test.Hspec

spec :: Spec
spec = describe "no-agent operating mode" $ do
  dispatchSpec
  probeSpec
  commandLineSpec

-- ---------------------------------------------------------------------------
-- The keyboard
-- ---------------------------------------------------------------------------

dispatchSpec :: Spec
dispatchSpec = describe "the binding it refuses" $ do
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
    single <- (\state -> state {appOperatingMode = loadedOperatingMode (Right claudeOnlyRoster)}) <$> quietState
    sequence_
      [ (name, action, boardActionGate state action) `shouldBe` (name, action, DispatchBoardAction)
        | (name, state) <- [("dual" :: String, dual), ("single-agent", single)],
          action <- [minBound .. maxBound]
      ]

  -- `a` is refused with the roster's own words whatever the card in front of
  -- the user: neither card gate claims it, so on a board that loads a provider
  -- the very states that settle a card leave it dispatching.
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

  -- The mission modes are gone, not merely unselected: the parser turns each
  -- spelling away as an option it does not know, so no invocation can reach a
  -- process that claims a mission or sweeps a repository's. @app/Main.hs@
  -- parses before it dispatches, which makes this the boundary that stops a
  -- launch.
  it "refuses each removed mission option as an unknown one" $
    sequence_
      [ (arguments, refusal) `shouldBe` (arguments, Just (ExitFailure 1, True))
        | arguments <-
            [ ["--mission", "mission-0001"],
              ["--mission-scheduler"],
              ["--mission-result", "/tmp/result.json"],
              ["--mission-invocation", "invocation-1"]
            ],
          let refusal = case execParserPure defaultPrefs optionsParserInfo arguments of
                Failure failure ->
                  let (message, code) = renderFailure failure "kanban"
                   in Just (code, "Invalid option" `isInfixOf` message)
                _ -> Nothing
      ]

  it "lists none of them in --help" $
    case execParserPure defaultPrefs optionsParserInfo ["--help"] of
      Failure failure -> fst (renderFailure failure "kanban") `shouldNotSatisfy` isInfixOf "mission"
      _ -> expectationFailure "--help did not render help"

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

-- | The binding the mode takes off a board: the issue approval service's,
-- which resolves @issue_gate@ models and can do nothing without a provider.
-- The solve and review keys were the other three until their screens were
-- removed.
agentBindings :: [BoardAction]
agentBindings = [ToggleApproval]

-- | An ordinary dashboard on the compiled roster: dual, nothing open, nothing
-- in flight.
quietState :: IO AppState
quietState = testAppState (fixtureBoard [])

-- | The same dashboard with a roster that loads no provider.
noAgentState :: IO AppState
noAgentState = (\state -> state {appOperatingMode = loadedOperatingMode (Right noAgentRoster)}) <$> quietState

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
-- disturb: services on their way up, and a card selected in a column other
-- than the first.
populatedNoAgentState :: IO AppState
populatedNoAgentState = do
  quiet <- noAgentState
  pure
    quiet
      { appApprovalStatus = ApprovalStatus ApprovalStarting "starting…" ApprovalServiceStopped Nothing Nothing,
        appApprovalBusy = True,
        appApprovalTransition = 3,
        appDrainerStatus = DrainerStatus DrainerOn "running" DrainerServiceRunning Nothing,
        appSelectedColumn = Active
      }

-- | Everything requirement 2 says a refused press leaves alone: overlay,
-- approval and drainer state, plus the board selection the press was taken
-- from.
data SurfaceFacts = SurfaceFacts
  { factsOverlay :: Maybe Overlay,
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
      factsApprovalState = state.appApprovalStatus.approvalState,
      factsApprovalDetail = state.appApprovalStatus.approvalDetail,
      factsApprovalBusy = state.appApprovalBusy,
      factsApprovalTransition = state.appApprovalTransition,
      factsDrainerState = state.appDrainerStatus.drainerState,
      factsDrainerBusy = state.appDrainerBusy,
      factsSelectedColumn = state.appSelectedColumn,
      factsSelectedRow = selectedRow state state.appSelectedColumn
    }
