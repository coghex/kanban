-- | The incidents panel: which sources contribute to it, how it tells an
-- unanswered source from an empty one, how a row keeps its identity across a
-- refresh, and where activating one takes the user.
module Spec.UI.Incidents (spec) where

import Brick (BrickEvent (..), Location (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import qualified Graphics.Vty as Vty
import Kanban.Domain
import Kanban.Drainer (DrainerActivity (..), DrainerIncident (..), DrainerState (..), DrainerStatus (..))
import Kanban.UI
  ( AgentSessionRef (..),
    AppState (..),
    BoardWorkLocation (..),
    DrainerSourceState (..),
    IncidentClickOutcome (..),
    IncidentEntry (..),
    IncidentRef (..),
    IncidentSelection (..),
    IncidentSource (..),
    IncidentsAction (..),
    Name (..),
    Overlay (..),
    ReviewPhase (..),
    SolvePhase (..),
    applyIncidentsAction,
    drainerSourceState,
    drawIncidents,
    incidentEntries,
    incidentSourceLabel,
    incidentsAction,
    locateBoardWork,
    resolveIncidentActivation,
    resolveIncidentClick,
    resolveIncidentSelection,
    reviewIncidentPhase,
    solveIncidentPhase,
    themeFor
  )
import Spec.Support.App
  ( testAppState,
    withPullRequestSession,
    withReviewSession,
    withSolveSession
  )
import Spec.Support.Fixtures
  ( baseIssue,
    basePullRequest,
    fixtureBoard,
    fixtureStandaloneEntry,
    fixtureTracker,
    fixtureTrackedEntry,
    testOptions
  )
import Spec.Support.Render (renderWidgetLines)
import Test.Hspec

spec :: Spec
spec = do
  describe "incident panel sources" $ do
    it "tells a verified-empty drainer apart from one that has not answered" $ do
      drainerSourceState (DrainerStatus DrainerOn "on" DrainerServiceRunning Nothing) (Just []) `shouldBe` DrainerSourceReported []
      -- The first poll has not landed yet.
      drainerSourceState (DrainerStatus DrainerStarting "checking…" DrainerServiceUnknown Nothing) Nothing
        `shouldBe` DrainerSourceChecking
      -- A start or stop this dashboard issued is still in flight.
      drainerSourceState (DrainerStatus DrainerStopping "stopping…" DrainerServiceStopping Nothing) Nothing
        `shouldBe` DrainerSourceChecking
      -- A query failure, a decode failure, and the controller discovery that
      -- precedes both all land here as a DrainerError status with no set.
      drainerSourceState (DrainerStatus DrainerError "the PR drainer is not installed" DrainerServiceUnknown Nothing) Nothing
        `shouldBe` DrainerSourceUnavailable "the PR drainer is not installed"
      -- A running drainer whose response carried no incident set at all is
      -- still an unanswered source, not an empty one.
      drainerSourceState (DrainerStatus DrainerOn "on" DrainerServiceRunning Nothing) Nothing
        `shouldBe` DrainerSourceUnavailable "on"

    it "lists every open drainer incident, not only the newest" $ do
      state <- reportingState [conflictIncident 42, cleanupIncident 43, crashIncident]
      map (.incidentEntryRef) (incidentEntries state)
        `shouldBe` [ DrainerIncidentRef "incident-conflict-42",
                     DrainerIncidentRef "incident-cleanup-43",
                     DrainerIncidentRef "incident-crash"
                   ]

    it "keeps session rows while the drainer source is being checked or is unavailable" $ do
      checking <- solveSessionOn <$> unansweredState (DrainerStatus DrainerStarting "checking…" DrainerServiceUnknown Nothing)
      unavailable <- solveSessionOn <$> unansweredState (DrainerStatus DrainerError "not installed" DrainerServiceUnknown Nothing)
      map (.incidentEntryRef) (incidentEntries checking)
        `shouldBe` [SessionIncidentRef (SolveAgent 10)]
      map (.incidentEntryRef) (incidentEntries unavailable)
        `shouldBe` [SessionIncidentRef (SolveAgent 10)]

  describe "incident panel session filtering" $ do
    it "qualifies exactly the enumerated solve and pull-request phases" $ do
      filter solveIncidentPhase everySolvePhase
        `shouldBe` [SolveAttention, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
      -- The adjacent active and completed phases are all excluded.
      filter (not . solveIncidentPhase) everySolvePhase
        `shouldBe` [SolveStarting, SolveRunning, SolveInterrupting, SolveFinished]

    it "qualifies exactly the enumerated review phases" $ do
      filter reviewIncidentPhase everyReviewPhase
        `shouldBe` [ReviewWaiting, ReviewNeedsChanges, ReviewFailed]
      -- ReviewRevised and ReviewInterrupted are terminal states the user
      -- already knows about; the rest are active or completed.
      filter (not . reviewIncidentPhase) everyReviewPhase
        `shouldBe` [ReviewStarting, ReviewRunning, ReviewFinished, ReviewRevised, ReviewInterrupted]

    it "builds a row for every qualifying session and none for the rest" $ do
      mapM_
        ( \phase -> do
            state <- withSolveSession (baseIssue 10 []) phase <$> emptyState
            map (.incidentEntryRef) (incidentEntries state)
              `shouldBe` [SessionIncidentRef (SolveAgent 10)]
        )
        (filter solveIncidentPhase everySolvePhase)
      mapM_
        ( \phase -> do
            state <- withSolveSession (baseIssue 10 []) phase <$> emptyState
            incidentEntries state `shouldBe` []
        )
        (filter (not . solveIncidentPhase) everySolvePhase)
      mapM_
        ( \phase -> do
            state <- withPullRequestSession (basePullRequest 42 [] False []) phase <$> emptyState
            map (.incidentEntryRef) (incidentEntries state)
              `shouldBe` [SessionIncidentRef (PullRequestAgent 42)]
        )
        (filter solveIncidentPhase everySolvePhase)
      mapM_
        ( \phase -> do
            state <- withPullRequestSession (basePullRequest 42 [] False []) phase <$> emptyState
            incidentEntries state `shouldBe` []
        )
        (filter (not . solveIncidentPhase) everySolvePhase)
      mapM_
        ( \phase -> do
            state <- withReviewSession (baseIssue 11 []) phase <$> emptyState
            map (.incidentEntryRef) (incidentEntries state)
              `shouldBe` [SessionIncidentRef (ReviewAgent 11)]
        )
        (filter reviewIncidentPhase everyReviewPhase)
      mapM_
        ( \phase -> do
            state <- withReviewSession (baseIssue 11 []) phase <$> emptyState
            incidentEntries state `shouldBe` []
        )
        (filter (not . reviewIncidentPhase) everyReviewPhase)

  describe "incident panel row content" $ do
    it "names the work, what happened, and the source of every row" $ do
      state <- solveSessionOn <$> reportingState [conflictIncident 42]
      case incidentEntries state of
        [drainer, session] -> do
          drainer.incidentEntrySubject `shouldBe` "PR #42 — PR 42"
          drainer.incidentEntryDetail `shouldBe` "PR #42 has a merge conflict in README."
          incidentSourceLabel drainer.incidentEntrySource `shouldBe` "pr drainer"
          session.incidentEntrySubject `shouldBe` "issue #10 — Issue 10"
          session.incidentEntryDetail `shouldBe` "failed · solve activity"
          incidentSourceLabel session.incidentEntrySource `shouldBe` "kanban session"
        entries -> expectationFailure ("expected one row per source, got " <> show (length entries))

    it "sanitizes every title, summary, and activity it renders" $ do
      let hostileTitle = "Fix \ESC[31mthe\ESC[0m \x202Ereversed\x202C thing"
          hostileSummary = "PR #42 broke:\ESC]0;title\BEL \x200Ehidden"
          hostileActivity = "waiting\ESC[2K on \x061Cinput"
          hostileIncident =
            (conflictIncident 42)
              { incidentSummary = Just hostileSummary,
                incidentActivity = Just hostileActivity,
                incidentKind = "drainer-exit",
                incidentPullRequest = Nothing,
                incidentLastPullRequest = Nothing
              }
      state <-
        withSolveSession ((baseIssue 10 []) {issueTitle = hostileTitle}) SolveFailedPhase
          <$> reportingState [hostileIncident]
      let rendered =
            concatMap
              (\entry -> [entry.incidentEntrySubject, entry.incidentEntryDetail])
              (incidentEntries state)
      -- Nothing reaching the terminal may carry an escape sequence, a
      -- bidirectional override, or a format control (docs/design.md §11).
      mapM_ (`shouldSatisfy` Data.Text.all safeCharacter) rendered
      -- The readable text survives the stripping.
      Data.Text.concat rendered `shouldSatisfy` Data.Text.isInfixOf "reversed"
      Data.Text.concat rendered `shouldSatisfy` Data.Text.isInfixOf "hidden"
      -- And the source label the row is stamped with is clean by
      -- construction, not by chance.
      mapM_
        (\entry -> incidentSourceLabel entry.incidentEntrySource `shouldSatisfy` Data.Text.all safeCharacter)
        (incidentEntries state)

    it "renders a supervisor crash from its real diagnostic fields" $ do
      state <- reportingState [crashIncident]
      case incidentEntries state of
        [entry] -> do
          entry.incidentEntrySubject `shouldBe` "drainer supervisor"
          entry.incidentEntryDetail `shouldBe` crashDetail
          -- Cardless: its last_pr is a diagnostic, never a target.
          entry.incidentEntryWork `shouldBe` Nothing
        entries -> expectationFailure ("expected one crash row, got " <> show (length entries))

  describe "incident panel number-based board navigation" $ do
    it "recognizes every shape the board can hold a number in" $ do
      locateBoardWork navigationBoard (IssueId 10)
        `shouldBe` Just (BoardWorkLocation Issues 3 Nothing)
      locateBoardWork navigationBoard (PullRequestId 42)
        `shouldBe` Just (BoardWorkLocation Reviewing 0 Nothing)
      -- A childless tracker is its own header entry.
      locateBoardWork navigationBoard (IssueId 700)
        `shouldBe` Just (BoardWorkLocation Issues 0 Nothing)
      -- A tracker with visible children has no card of its own; its group's
      -- first row is where its header is drawn.
      locateBoardWork navigationBoard (IssueId 800)
        `shouldBe` Just (BoardWorkLocation Issues 1 Nothing)
      -- A child is present whether or not its tracker is open, and reports
      -- the tracker that has to be expanded for it to be seen.
      locateBoardWork navigationBoard (IssueId 812)
        `shouldBe` Just (BoardWorkLocation Issues 2 (Just 800))
      locateBoardWork navigationBoard (IssueId 999) `shouldBe` Nothing
      locateBoardWork navigationBoard (PullRequestId 999) `shouldBe` Nothing

    it "expands a collapsed tracker so the child it selects is visible" $ do
      state <- withSolveSession (baseIssue 812 []) SolveFailedPhase <$> navigationState
      let activated = activateFirstRow state
      activated.appSelectedColumn `shouldBe` Issues
      Map.lookup Issues activated.appSelectedRows `shouldBe` Just 2
      activated.appExpandedTrackers `shouldBe` Set.fromList [800]

    it "targets a represented tracker's header rather than reporting it absent" $ do
      state <- withReviewSession (baseIssue 800 []) ReviewFailed <$> navigationState
      let activated = activateFirstRow state
      Map.lookup Issues activated.appSelectedRows `shouldBe` Just 1
      -- Nothing is expanded: a group header is drawn open or closed.
      activated.appExpandedTrackers `shouldBe` Set.empty
      activated.appNotice `shouldBe` Nothing

  describe "incident panel activation" $ do
    it "selects the card a drainer incident names, opening no session Kanban does not hold" $ do
      state <- reportingState [conflictIncident 42]
      let activated = activateFirstRow state
      activated.appSelectedColumn `shouldBe` Reviewing
      Map.lookup Reviewing activated.appSelectedRows `shouldBe` Just 0
      activated.appOverlay `shouldBe` Nothing
      activated.appNotice `shouldBe` Nothing

    it "selects the card and opens the session for a qualifying session row" $ do
      solve <- withSolveSession (baseIssue 10 []) SolveAttention <$> navigationState
      (activateFirstRow solve).appOverlay `shouldBe` Just (SolveOverlay 10)
      Map.lookup Issues (activateFirstRow solve).appSelectedRows `shouldBe` Just 3

      review <- withReviewSession (baseIssue 10 []) ReviewWaiting <$> navigationState
      (activateFirstRow review).appOverlay `shouldBe` Just (ReviewOverlay 10)

      pullRequest <- withPullRequestSession (basePullRequest 42 [] False []) SolveKilledPhase <$> navigationState
      let activated = activateFirstRow pullRequest
      activated.appOverlay `shouldBe` Just (PullRequestReviewOverlay 42)
      activated.appSelectedColumn `shouldBe` Reviewing

    it "opens the session of work the board no longer shows, and moves nothing" $ do
      -- #77 is not on this board: truncated off it, or closed since.
      state <- withSolveSession (baseIssue 77 []) SolveFailedPhase <$> navigationState
      let moved = state {appSelectedColumn = Done, appSelectedRows = Map.insert Done 0 state.appSelectedRows}
          activated = activateFirstRow moved
      activated.appSelectedColumn `shouldBe` Done
      activated.appSelectedRows `shouldBe` moved.appSelectedRows
      activated.appExpandedTrackers `shouldBe` Set.empty
      activated.appNotice `shouldBe` Just "Issue #77 is not on the current board"
      -- The session is still worth opening.
      activated.appOverlay `shouldBe` Just (SolveOverlay 77)

    it "reports a truncated pull request's absence without opening any session" $ do
      state <- reportingState [conflictIncident 903]
      let truncated = state {appPullRequestsTruncated = True}
          activated = activateFirstRow truncated
      activated.appSelectedColumn `shouldBe` Issues
      activated.appSelectedRows `shouldBe` truncated.appSelectedRows
      activated.appExpandedTrackers `shouldBe` Set.empty
      activated.appNotice `shouldBe` Just "PR #903 is not on the current board"
      activated.appOverlay `shouldBe` Nothing

    it "reports a supervisor crash and navigates nowhere" $ do
      state <- reportingState [crashIncident]
      let activated = activateFirstRow state
      activated.appSelectedColumn `shouldBe` Issues
      activated.appSelectedRows `shouldBe` state.appSelectedRows
      activated.appExpandedTrackers `shouldBe` Set.empty
      activated.appOverlay `shouldBe` Nothing
      activated.appNotice `shouldBe` Just ("drainer supervisor · " <> crashDetail)

    it "changes no incident, session, or GitHub state when opened or activated" $ do
      base <-
        withSolveSession (baseIssue 10 []) SolveFailedPhase
          . withReviewSession (baseIssue 800 []) ReviewNeedsChanges
          . withPullRequestSession (basePullRequest 42 [] False []) SolveAttention
          <$> reportingState [conflictIncident 42, crashIncident]
      let opened = applyIncidentsAction OpenIncidentsPanel base
          references = map (.incidentEntryRef) (incidentEntries opened)
          activations = [activateRow reference opened | reference <- references]
      -- Both drainer kinds and all three session kinds, so no activation
      -- path is left unexercised.
      length references `shouldBe` 5
      mapM_
        ( \state -> do
            state.appDrainerIncidents `shouldBe` base.appDrainerIncidents
            state.appSolveSessions `shouldBe` base.appSolveSessions
            state.appReviewSessions `shouldBe` base.appReviewSessions
            state.appPullRequestReviewSessions `shouldBe` base.appPullRequestReviewSessions
            state.appBoard `shouldBe` base.appBoard
            Map.size state.appSolveProcesses `shouldBe` 0
            Map.size state.appPullRequestProcesses `shouldBe` 0
            Map.size state.appCanonicalReviewProcesses `shouldBe` 0
        )
        (opened : activations)

  describe "incident panel selection identity" $ do
    it "follows a tracked identity through a reordered list" $ do
      let selection = IncidentSelection (Just (namedRef "c")) 2
      resolveIncidentSelection (reverse threeEntries) selection
        `shouldBe` IncidentSelection (Just (namedRef "c")) 0
      resolveIncidentSelection [entryNamed "b", entryNamed "c"] selection
        `shouldBe` IncidentSelection (Just (namedRef "c")) 1

    it "keeps a highlight when the tracked identity disappears" $
      resolveIncidentSelection [entryNamed "a", entryNamed "b"] (IncidentSelection (Just (namedRef "c")) 2)
        `shouldBe` IncidentSelection (Just (namedRef "b")) 1

    it "activates nothing when the tracked identity disappears" $ do
      -- The highlight above moved onto "b". Activation must not follow it:
      -- the user aimed at "c".
      resolveIncidentActivation emptyBoard [entryNamed "a", entryNamed "b"] (namedRef "c")
        `shouldBe` Nothing
      state <- reportingState [conflictIncident 42]
      let stale = state {appIncidentSelection = IncidentSelection (Just (namedRef "gone")) 0}
          activated = applyIncidentsAction ActivateSelectedIncident stale
      activated.appNotice `shouldBe` Just "That incident is no longer listed"
      activated.appSelectedRows `shouldBe` stale.appSelectedRows
      activated.appSelectedColumn `shouldBe` stale.appSelectedColumn
      activated.appOverlay `shouldBe` stale.appOverlay

    it "activates the row it highlighted after a refresh filled an empty panel" $ do
      -- Opened over an empty list, the selection names nothing. A drainer
      -- poll then lands the first incident while the panel is open, and the
      -- panel draws that row highlighted — so Enter has to act on it rather
      -- than report the stale "nothing selected" the open left behind.
      state <- reportingState []
      let opened = applyIncidentsAction OpenIncidentsPanel state
      opened.appIncidentSelection `shouldBe` IncidentSelection Nothing 0
      panelLines opened `shouldSatisfy` any (Data.Text.isInfixOf "Nothing needs attention.")

      let refreshed = opened {appDrainerIncidents = Just [conflictIncident 42]}
      -- What the panel highlights, which is what activation must agree with.
      resolveIncidentSelection (incidentEntries refreshed) refreshed.appIncidentSelection
        `shouldBe` IncidentSelection (Just (DrainerIncidentRef "incident-conflict-42")) 0
      let activated = applyIncidentsAction ActivateSelectedIncident refreshed
      activated.appNotice `shouldBe` Nothing
      activated.appSelectedColumn `shouldBe` Reviewing
      Map.lookup Reviewing activated.appSelectedRows `shouldBe` Just 0

      -- Still nothing to act on when the refresh brought nothing.
      (applyIncidentsAction ActivateSelectedIncident opened).appNotice
        `shouldBe` Just "No incident is selected"

    it "resolves a click by the identity rendered into the row" $ do
      let selection = IncidentSelection (Just (namedRef "a")) 0
      resolveIncidentClick threeEntries selection (namedRef "b")
        `shouldBe` IncidentClickSelect (IncidentSelection (Just (namedRef "b")) 1)
      resolveIncidentClick threeEntries selection (namedRef "a") `shouldBe` IncidentClickOpen
      -- The clicked row left the list between render and dispatch.
      resolveIncidentClick threeEntries selection (namedRef "gone") `shouldBe` IncidentClickIgnored

  describe "incident panel events" $ do
    it "opens on i from the board and closes on Esc" $ do
      state <- solveSessionOn <$> navigationState
      incidentsAction Nothing (key (Vty.KChar 'i')) `shouldBe` Just OpenIncidentsPanel
      let opened = applyIncidentsAction OpenIncidentsPanel state
      opened.appOverlay `shouldBe` Just IncidentsOverlay
      opened.appIncidentSelection `shouldBe` IncidentSelection (Just (SessionIncidentRef (SolveAgent 10))) 0
      panelLines opened `shouldSatisfy` any (Data.Text.isInfixOf "issue #10")

      incidentsAction (Just IncidentsOverlay) (key Vty.KEsc) `shouldBe` Just CloseIncidentsPanel
      (applyIncidentsAction CloseIncidentsPanel opened).appOverlay `shouldBe` Nothing

    it "leaves every other context's keys alone" $ do
      incidentsAction (Just ProcessesOverlay) (key (Vty.KChar 'i')) `shouldBe` Nothing
      incidentsAction (Just HelpOverlay) (key (Vty.KChar 'i')) `shouldBe` Nothing
      incidentsAction Nothing (key (Vty.KChar 'p')) `shouldBe` Nothing

    it "maps its own keys and mouse events to panel actions" $ do
      let open = incidentsAction (Just IncidentsOverlay)
      open (key (Vty.KChar 'j')) `shouldBe` Just (MoveIncidentSelection 1)
      open (key Vty.KDown) `shouldBe` Just (MoveIncidentSelection 1)
      open (key (Vty.KChar 'k')) `shouldBe` Just (MoveIncidentSelection (-1))
      open (key Vty.KUp) `shouldBe` Just (MoveIncidentSelection (-1))
      open (key Vty.KEnter) `shouldBe` Just ActivateSelectedIncident
      open (wheel IncidentsPanel Vty.BScrollDown) `shouldBe` Just (ScrollIncidentsPanel 3)
      open (wheel IncidentsPanel Vty.BScrollUp) `shouldBe` Just (ScrollIncidentsPanel (-3))
      -- A wheel over a row lands on the row's own name, and still scrolls.
      open (wheel (IncidentTarget (namedRef "a")) Vty.BScrollDown)
        `shouldBe` Just (ScrollIncidentsPanel 3)
      open (MouseDown (IncidentTarget (namedRef "a")) Vty.BLeft [] (Location (0, 0)))
        `shouldBe` Just (ClickIncidentRow (namedRef "a"))
      open (key (Vty.KChar 'z')) `shouldBe` Just IgnoreIncidentsEvent

    it "moves the keyboard selection within the list's bounds" $ do
      opened <- threeRowPanel
      let down = applyIncidentsAction (MoveIncidentSelection 1)
          up = applyIncidentsAction (MoveIncidentSelection (-1))
      (down opened).appIncidentSelection.incidentSelectionRow `shouldBe` 1
      (down (down (down (down opened)))).appIncidentSelection.incidentSelectionRow `shouldBe` 2
      (up opened).appIncidentSelection.incidentSelectionRow `shouldBe` 0

    it "selects on the first click of a row and activates on the second" $ do
      opened <- threeRowPanel
      let sessionRow = (incidentEntries opened !! 2).incidentEntryRef
          selected = applyIncidentsAction (ClickIncidentRow sessionRow) opened
      selected.appIncidentSelection `shouldBe` IncidentSelection (Just sessionRow) 2
      selected.appOverlay `shouldBe` Just IncidentsOverlay
      (applyIncidentsAction (ClickIncidentRow sessionRow) selected).appOverlay
        `shouldBe` Just (SolveOverlay 10)

  describe "incident panel rendering" $ do
    it "claims nothing needs attention only from a verified-empty drainer" $ do
      empty <- emptyState
      panelLines (applyIncidentsAction OpenIncidentsPanel empty)
        `shouldSatisfy` any (Data.Text.isInfixOf "Nothing needs attention.")

    it "says the drainer source is being checked or unavailable instead" $ do
      checking <- unansweredState (DrainerStatus DrainerStarting "checking…" DrainerServiceUnknown Nothing)
      let checkingLines = panelLines (applyIncidentsAction OpenIncidentsPanel checking)
      checkingLines `shouldSatisfy` any (Data.Text.isInfixOf "checking for open incidents")
      checkingLines `shouldSatisfy` not . any (Data.Text.isInfixOf "Nothing needs attention.")

      unavailable <- unansweredState (DrainerStatus DrainerError "the PR drainer is not installed" DrainerServiceUnknown Nothing)
      let unavailableLines = panelLines (applyIncidentsAction OpenIncidentsPanel unavailable)
      unavailableLines
        `shouldSatisfy` any (Data.Text.isInfixOf "open incidents unavailable · the PR drainer is not installed")
      unavailableLines `shouldSatisfy` not . any (Data.Text.isInfixOf "Nothing needs attention.")

      -- A controller that answered without reporting a set at all is the
      -- same unanswered source, and must not be described as though the
      -- drainer itself were unreachable.
      legacy <- unansweredState (DrainerStatus DrainerOn "on" DrainerServiceRunning Nothing)
      panelLines (applyIncidentsAction OpenIncidentsPanel legacy)
        `shouldSatisfy` any (Data.Text.isInfixOf "PR drainer: open incidents unavailable · on")

    it "renders every row with its subject, detail, and source" $ do
      state <- solveSessionOn <$> reportingState [conflictIncident 42]
      let rendered = panelLines (applyIncidentsAction OpenIncidentsPanel state)
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "PR drainer: 1 open incident")
      rendered
        `shouldSatisfy` any (Data.Text.isInfixOf "PR #42 — PR 42 · PR #42 has a merge conflict in README. · pr drainer")
      rendered
        `shouldSatisfy` any (Data.Text.isInfixOf "issue #10 — Issue 10 · failed · solve activity · kanban session")

    it "scrolls a list longer than the panel, keeping the selected row shown" $ do
      state <- reportingState [conflictIncident number | number <- [1 .. 40]]
      let opened = applyIncidentsAction OpenIncidentsPanel state
          atLastRow = iterate (applyIncidentsAction (MoveIncidentSelection 1)) opened !! 39
          top = panelLines opened
          bottom = panelLines atLastRow
      length (incidentEntries opened) `shouldBe` 40
      atLastRow.appIncidentSelection.incidentSelectionRow `shouldBe` 39
      -- More rows than the viewport can hold, so it is clipped rather than
      -- grown, and the selection decides which end is shown.
      length top `shouldSatisfy` (< 40)
      top `shouldSatisfy` any (Data.Text.isInfixOf "PR #1 ")
      top `shouldSatisfy` not . any (Data.Text.isInfixOf "PR #40 ")
      bottom `shouldSatisfy` any (Data.Text.isInfixOf "PR #40 ")
      bottom `shouldSatisfy` not . any (Data.Text.isInfixOf "PR #1 ")
  where
    key stroke = VtyEvent (Vty.EvKey stroke [])
    wheel name button = MouseDown name button [] (Location (0, 0))

    emptyBoard = fixtureBoard []

    -- A board holding a number in each of the four recognized shapes: a
    -- childless tracker header, a tracker represented by its children, one
    -- of those children, an ordinary issue, and an ordinary pull request.
    navigationBoard =
      fixtureBoard
        [ ( Issues,
            [ TrackerHeader (fixtureTracker 700),
              fixtureTrackedEntry 800 [] 811,
              fixtureTrackedEntry 800 [] 812,
              fixtureStandaloneEntry 10
            ]
          ),
          (Reviewing, [Standalone (PullRequestItem (basePullRequest 42 [] False []))])
        ]

    emptyState = testAppState emptyBoard
    navigationState = testAppState navigationBoard

    reportingState incidents = do
      state <- navigationState
      pure state {appDrainerIncidents = Just incidents}

    unansweredState status = do
      state <- emptyState
      pure state {appDrainerStatus = status, appDrainerIncidents = Nothing}

    solveSessionOn = withSolveSession (baseIssue 10 []) SolveFailedPhase

    -- Two drainer rows and one session row, opened and ready for input.
    threeRowPanel = do
      state <- reportingState [conflictIncident 42, crashIncident]
      pure (applyIncidentsAction OpenIncidentsPanel (solveSessionOn state))

    -- Activate the first row, the way pressing Enter on a freshly opened
    -- panel does.
    activateFirstRow state =
      applyIncidentsAction ActivateSelectedIncident (applyIncidentsAction OpenIncidentsPanel state)

    activateRow reference state =
      applyIncidentsAction
        ActivateSelectedIncident
        state {appIncidentSelection = IncidentSelection (Just reference) 0}

    panelLines state = renderWidgetLines (themeFor testOptions) 96 (drawIncidents state)

    safeCharacter character = character `notElem` ("\ESC\BEL\x202E\x202C\x200E\x061C" :: String)

    namedRef = DrainerIncidentRef
    threeEntries = map entryNamed ["a", "b", "c"]

    entryNamed name =
      IncidentEntry
        { incidentEntryRef = namedRef name,
          incidentEntrySource = DrainerSource,
          incidentEntryWork = Nothing,
          incidentEntrySession = Nothing,
          incidentEntrySubject = "drainer supervisor",
          incidentEntryDetail = "incident " <> name
        }

    conflictIncident number =
      DrainerIncident
        { incidentId = "incident-conflict-" <> showNumber number,
          incidentKind = "merge-conflict",
          incidentSummary = Just ("PR #" <> showNumber number <> " has a merge conflict in README."),
          incidentPullRequest = Just number,
          incidentLastPullRequest = Nothing,
          incidentActivity = Nothing
        }

    cleanupIncident number =
      (conflictIncident number)
        { incidentId = "incident-cleanup-" <> showNumber number,
          incidentKind = "cleanup-pending",
          incidentSummary = Just ("PR #" <> showNumber number <> " merged but its cleanup keeps failing.")
        }

    crashIncident =
      DrainerIncident
        { incidentId = "incident-crash",
          incidentKind = "drainer-exit",
          incidentSummary = Just "drain_prs.py exited unexpectedly with code 1",
          incidentPullRequest = Nothing,
          incidentLastPullRequest = Just 7,
          incidentActivity = Just "merging PR #7"
        }

    crashDetail =
      "drain_prs.py exited unexpectedly with code 1 · last activity: merging PR #7 \
      \· last logged PR #7, not a navigation target"

    showNumber :: Int -> Text
    showNumber = Data.Text.pack . show

    everySolvePhase =
      [ SolveStarting,
        SolveRunning,
        SolveInterrupting,
        SolveAttention,
        SolveFinished,
        SolveFailedPhase,
        SolveKilledPhase,
        SolveOrphanedPhase
      ]

    everyReviewPhase =
      [ ReviewStarting,
        ReviewRunning,
        ReviewWaiting,
        ReviewFinished,
        ReviewNeedsChanges,
        ReviewFailed,
        ReviewRevised,
        ReviewInterrupted
      ]
