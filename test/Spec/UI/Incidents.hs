-- | The incidents panel: which sources contribute to it, how it tells an
-- unanswered source from an empty one, how a row keeps its identity across a
-- refresh, and where activating one takes the user.
module Spec.UI.Incidents (spec) where

import Brick (BrickEvent (..), Location (..))
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import qualified Graphics.Vty as Vty
import Kanban.Domain
import Kanban.Drainer (DrainerActivity (..), DrainerIncident (..), DrainerState (..), DrainerStatus (..))
import Kanban.UI.Events (IncidentsAction (..), applyIncidentsAction, incidentsAction)
import Kanban.Models (OperatingMode (..))
import Kanban.UI.Keys (BindingScope (..), BoardAction (..), boardAction)
import Kanban.UI.Overlay (InteriorExtent (..), OverlayGeometry (..), drawIncidents, drawOverlay, overlayGeometryFor)
import Kanban.UI.Session
  ( BoardWorkLocation (..),
    drainerSourceState,
    incidentEntries,
    incidentSourceLabel,
    locateBoardWork,
    resolveIncidentActivation,
    resolveIncidentClick,
    resolveIncidentSelection,
    reviewIncidentPhase,
    solveIncidentPhase,
  )
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types
  ( AgentSessionRef (..),
    AppState (..),
    DrainerSourceState (..),
    IncidentClickOutcome (..),
    IncidentEntry (..),
    IncidentRef (..),
    IncidentSelection (..),
    IncidentSource (..),
    Name (..),
    Overlay (..),
    ReviewPhase (..),
    SolvePhase (..),
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

-- | Which extent an incidents panel is drawn at, which since issue #543 is
-- what decides the width a row is measured against.
data PanelExtent = WindowedPanel | FullscreenPanel
  deriving stock (Eq, Show)

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

    it "carries the failure a stuck cleanup recorded, leaving the row stating the step" $ do
      state <- reportingState [(cleanupIncident 1079) {incidentError = Just recordedRefusal}]
      case incidentEntries state of
        [entry] -> do
          -- The row keeps saying which step is stuck, unchanged...
          entry.incidentEntryDetail `shouldBe` "PR #1079 merged but its cleanup keeps failing."
          -- ...and why it is stuck travels as the note the panel wraps below
          -- it, where it has the width to be read.
          entry.incidentEntryNote `shouldBe` Just recordedRefusal
        entries -> expectationFailure ("expected one cleanup row, got " <> show (length entries))

    it "adds nothing at all for a cleanup incident with no usable recorded failure" $ do
      -- Missing, explicit null (both decode to Nothing), empty, whitespace
      -- only, and emptied by sanitization. Each renders exactly as a cleanup
      -- incident does today: no note, no separator, no placeholder.
      let bare = "PR #1079 merged but its cleanup keeps failing."
      entries <-
        traverse
          (fmap incidentEntries . reportingState . pure)
          [ cleanupIncident 1079,
            (cleanupIncident 1079) {incidentError = Just ""},
            (cleanupIncident 1079) {incidentError = Just "   \n\t  "},
            (cleanupIncident 1079) {incidentError = Just "\ESC[31m\ESC[0m\x202E\x202C"}
          ]
      map (map (.incidentEntryDetail)) entries `shouldBe` replicate 4 [bare]
      map (map (.incidentEntryNote)) entries `shouldBe` replicate 4 [Nothing]

    it "projects a hostile or over-long recorded failure onto one sanitized logical line" $ do
      let hostile = "cleanup failed:\ESC]0;title\BEL\n\n\x200E\&fast-forward\trefused\r\non branch\n"
          overLong = Data.Text.replicate 40 "fast-forwarding the default branch refused. "
      hostileNote <- rowNote ((cleanupIncident 1079) {incidentError = Just hostile})
      longNote <- rowNote ((cleanupIncident 1079) {incidentError = Just overLong})

      -- §11: nothing reaching the terminal carries an escape sequence, a
      -- bidirectional override, or a format control, and the logical line
      -- breaks sanitizeText preserves are collapsed so the renderer wraps to
      -- the width it has rather than to breaks in the drainer's text.
      hostileNote `shouldSatisfy` Data.Text.all safeCharacter
      hostileNote `shouldSatisfy` Data.Text.all (/= '\n')
      hostileNote `shouldBe` "cleanup failed: fast-forward refused on branch"

      -- Ordinary length is carried whole -- what the row can show is decided
      -- when it is drawn, not by trimming here.
      hostileNote `shouldSatisfy` not . Data.Text.isInfixOf "…"
      longNote `shouldBe` Data.Text.strip overLong

      -- A pathological value is capped, and what a cap gives up is the
      -- middle: both ends survive, because the drainer puts the remedy at the
      -- end and a tail-trimming bound would throw exactly it away.
      let runaway = "OPENING. " <> Data.Text.replicate 400 "filler filler filler. " <> "CLOSING."
      capped <- rowNote ((cleanupIncident 1079) {incidentError = Just runaway})
      Data.Text.length capped `shouldSatisfy` (< Data.Text.length runaway)
      capped `shouldSatisfy` Data.Text.isPrefixOf "OPENING."
      capped `shouldSatisfy` Data.Text.isSuffixOf "CLOSING."
      capped `shouldSatisfy` Data.Text.isInfixOf "…"

    it "leaves a crash or conflict incident unchanged whatever its document carries" $ do
      -- The field belongs to the cleanup kind's contract. A crash or conflict
      -- document that unexpectedly carries one is rendered from the fields its
      -- own kind defines, exactly as before, and earns no note.
      crash <- rowEntry crashIncident {incidentError = Just recordedRefusal}
      conflict <- rowEntry ((conflictIncident 42) {incidentError = Just recordedRefusal})
      crash.incidentEntryDetail `shouldBe` crashDetail
      conflict.incidentEntryDetail `shouldBe` "PR #42 has a merge conflict in README."
      map (.incidentEntryNote) [crash, conflict] `shouldBe` [Nothing, Nothing]

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
      -- #77 is not on this board: closed since, or never on it.
      state <- withSolveSession (baseIssue 77 []) SolveFailedPhase <$> navigationState
      let moved = state {appSelectedColumn = Done, appSelectedRows = Map.insert Done 0 state.appSelectedRows}
          activated = activateFirstRow moved
      activated.appSelectedColumn `shouldBe` Done
      activated.appSelectedRows `shouldBe` moved.appSelectedRows
      activated.appExpandedTrackers `shouldBe` Set.empty
      activated.appNotice `shouldBe` Just "Issue #77 is not on the current board"
      -- The session is still worth opening.
      activated.appOverlay `shouldBe` Just (SolveOverlay 77)

    it "reports an absent pull request without opening any session" $ do
      state <- reportingState [conflictIncident 903]
      let activated = activateFirstRow state
      activated.appSelectedColumn `shouldBe` Issues
      activated.appSelectedRows `shouldBe` state.appSelectedRows
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
      -- The board's own @i@ is a base-board binding declared once in
      -- "Kanban.UI.Keys"; this module's policy starts at the open panel.
      boardAction BoardScope (Vty.EvKey (Vty.KChar 'i') []) `shouldBe` Just ShowIncidents
      incidentsAction Nothing (key (Vty.KChar 'i')) `shouldBe` Nothing
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

    it "shows the recorded cause and remedy through the real fixed-width panel" $ do
      -- The point of the whole change. A real cleanup summary already
      -- overruns the 96-cell panel interior on its own, so on the row itself
      -- this text would be elided away before its first word. Through
      -- drawOverlay -- the fixed width an operator actually gets -- the
      -- blocker and the action that clears it are both readable.
      state <-
        reportingState
          [ (cleanupIncident 1079)
              { incidentSummary =
                  Just
                    "PR #1079 merged, but its post-merge cleanup keeps failing: \
                    \fast-forwarding the default branch.",
                incidentError = Just recordedRefusal
              }
          ]
      let rendered = overlayLinesAt 164 (applyIncidentsAction OpenIncidentsPanel state)
          continuation = Data.Text.unwords (filter (Data.Text.isInfixOf "↳") rendered <> noteTail rendered)
          noteTail = filter (\row -> Data.Text.isInfixOf "git add" row || Data.Text.isInfixOf "fast-forward:" row)

      -- The row still states the step that is stuck.
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "post-merge cleanup keeps failing")
      -- And the note states the blocker and the remedy, both reachable.
      continuation `shouldSatisfy` Data.Text.isInfixOf "Local changes are not what blocked this"
      continuation `shouldSatisfy` Data.Text.isInfixOf "`git add` them"
      continuation `shouldSatisfy` Data.Text.isInfixOf "src/Kanban/UI.hs"
      -- The note wrapped to the panel rather than being emitted as one line
      -- wider than it: the marked first line stops short of the path, which
      -- a later line carries.
      let marked = filter (Data.Text.isInfixOf "↳") rendered
      marked `shouldSatisfy` ((== 1) . length)
      marked `shouldSatisfy` all (not . Data.Text.isInfixOf "src/Kanban/UI.hs")
      map Data.Text.length marked `shouldSatisfy` all (<= panelInterior WindowedPanel 164)

    it "keeps the blocker and remedy of a production-shaped error under a deep checkout" $ do
      -- Exactly what the drainer records: advance_pending_cleanup prefixes the
      -- failing step, and _require_merged_index's refusal restates the failure
      -- around the checkout's absolute path before it reaches the actionable
      -- half. A deep path pushes that half further out, which is precisely
      -- where a tail-trimming bound would drop it.
      let checkout = "/Users/vincentcoghlan/worktrees/coghex/kanban/issue-217-cleanup-incident-cause"
          recorded =
            "fast-forwarding the default branch: Refusing to fast-forward master: the index in "
              <> checkout
              <> " holds unmerged entries, so no snapshot of local changes can be taken. \
                 \Local changes are not what blocked this. Resolve these paths and `git add` \
                 \them, and the next ordinary pass discharges the fast-forward: \
                 \docs/code_health_findings.md, docs/pipeline-hardening.md"
      state <-
        reportingState
          [ (cleanupIncident 1079)
              { incidentSummary =
                  Just
                    "PR #1079 merged, but its post-merge cleanup keeps failing: \
                    \fast-forwarding the default branch.",
                incidentError = Just recorded
              }
          ]
      let rendered = Data.Text.unwords (overlayLinesAt 164 (applyIncidentsAction OpenIncidentsPanel state))
      -- The actionable half survives: what to do, and to which paths.
      rendered `shouldSatisfy` Data.Text.isInfixOf "blocked this"
      rendered `shouldSatisfy` Data.Text.isInfixOf "Resolve these paths and `git add` them"
      rendered `shouldSatisfy` Data.Text.isInfixOf "docs/code_health_findings.md"
      rendered `shouldSatisfy` Data.Text.isInfixOf "docs/pipeline-hardening.md"
      -- What it gave up to fit is the middle, and it says so.
      rendered `shouldSatisfy` Data.Text.isInfixOf "…"
      rendered `shouldSatisfy` Data.Text.isInfixOf "fast-forwarding the default branch:"

    it "gives a note no more of the shared panel than its allowance" $ do
      -- The panel's height belongs to every incident. A runaway recorded
      -- failure is capped and says so rather than pushing other rows out.
      state <-
        reportingState
          [ (cleanupIncident 1079)
              { incidentError = Just (Data.Text.replicate 40 "fast-forwarding the default branch refused. ")
              }
          ]
      let rendered = overlayLinesAt 164 (applyIncidentsAction OpenIncidentsPanel state)
          noteRows = filter (Data.Text.isInfixOf "fast-forwarding") rendered
      length noteRows `shouldSatisfy` (<= 3)
      Data.Text.concat noteRows `shouldSatisfy` Data.Text.isInfixOf "…"

    it "adds only its own lines, leaving every other row alone at any supported width" $ do
      -- The three widths the golden frames pin: wide, board minimum, and
      -- narrow. A note takes the lines it wraps to and nothing else: no other
      -- entry's row may move, change, or re-wrap because one incident gained
      -- a recorded failure.
      bare <- solveSessionOn <$> reportingState [cleanupIncident 1079, crashIncident]
      loaded <-
        solveSessionOn
          <$> reportingState
            [ (cleanupIncident 1079) {incidentError = Just recordedRefusal},
              crashIncident
            ]
      let opened = applyIncidentsAction OpenIncidentsPanel
          -- The panel is a fixed-height viewport, so a note spends one of its
          -- blank rows. Comparing the rows that carry text is what isolates
          -- "the note added its own lines" from "the padding shrank by one".
          written = filter (not . Data.Text.null)
          isNote = Data.Text.isPrefixOf "  "
      for_ [200, 164, 36] $ \width -> do
        let without = panelLinesAt width (opened bare)
            with = panelLinesAt width (opened loaded)
        -- Nothing overruns the width it was given.
        map Data.Text.length with `shouldSatisfy` all (<= width)
        -- Dropping the lines the note introduced leaves exactly the panel
        -- that was there before it: same rows, same order, same wrapping.
        written (filter (not . isNote) with) `shouldBe` written without
        -- The note is additive, never a replacement.
        length (written with) `shouldSatisfy` (> length (written without))

    it "elides a row the real panel cannot fit, rather than cropping it silently" $ do
      -- The panel's width is the overlay's, not the terminal's. Drawing
      -- through drawIncidents alone bypasses that limit; this goes through
      -- drawOverlay, where a real cleanup summary already overruns the panel
      -- before any recorded failure is added to it.
      --
      -- Since issue #543 that width is no longer one number: windowed the
      -- panel is the fixed 100-cell box it always was, and fullscreen it is
      -- the terminal less the frame on each side. Each extent is measured
      -- against the width it actually gets, which is what a single
      -- 'incidentsPanelWidth' literal stopped being able to say.
      state <-
        reportingState
          [ (cleanupIncident 1079)
              { incidentSummary =
                  Just
                    "PR #1079 merged, but its post-merge cleanup keeps failing: \
                    \fast-forwarding the default branch.",
                incidentError = Just recordedRefusal
              }
          ]
      let opened = applyIncidentsAction OpenIncidentsPanel state
      for_ [(extent, width) | extent <- bothExtents, width <- [200, 164]] $ \(extent, width) -> do
        let interior = panelInterior extent width
        case filter (Data.Text.isInfixOf "PR #1079") (overlayLinesAtExtent extent width opened) of
          [row] -> do
            -- Whatever the extent, the row fits the panel the overlay
            -- actually drew rather than running past its border.
            (extent, width, Data.Text.length row <= interior) `shouldBe` (extent, width, True)
          rows -> expectationFailure ("expected one cleanup row at " <> show (extent, width) <> ", got " <> show (length rows))

      -- The windowed panel is where this summary is elided at all, which is
      -- what the fixed 100-cell box has always done to it...
      panelInterior FullscreenPanel 200 `shouldSatisfy` (> panelInterior WindowedPanel 200)
      filter (Data.Text.isInfixOf "PR #1079") (overlayLinesAtExtent WindowedPanel 200 opened)
        `shouldSatisfy` all (Data.Text.isSuffixOf "…")
      -- ...and the fullscreen panel is wide enough to carry the whole of it,
      -- which is the point of growing the box.
      filter (Data.Text.isInfixOf "PR #1079") (overlayLinesAtExtent FullscreenPanel 200 opened)
        `shouldSatisfy` all (Data.Text.isSuffixOf "pr drainer")

      -- A row the windowed panel does fit keeps every character, and gains no
      -- ellipsis, at either extent.
      short <- reportingState [conflictIncident 42]
      for_ bothExtents $ \extent ->
        case filter (Data.Text.isInfixOf "PR #42") (overlayLinesAtExtent extent 200 (applyIncidentsAction OpenIncidentsPanel short)) of
          [row] -> do
            (extent, Data.Text.isSuffixOf "pr drainer" row) `shouldBe` (extent, True)
            (extent, Data.Text.isInfixOf "…" row) `shouldBe` (extent, False)
          rows -> expectationFailure ("expected one conflict row at " <> show extent <> ", got " <> show (length rows))

    it "elides against the fullscreen width once the panel is grown to it" $ do
      -- A summary that fits the windowed panel is not the interesting case;
      -- this one overruns it, so the two extents must disagree about whether
      -- it needs an ellipsis at all. That is precisely what a fixed
      -- 'incidentsPanelWidth' could not express.
      state <-
        reportingState
          [ (conflictIncident 77)
              { incidentSummary = Just (Data.Text.replicate 6 "a merge conflict the windowed panel cannot fit ")
              }
          ]
      let opened = applyIncidentsAction OpenIncidentsPanel state
          rowAt extent = filter (Data.Text.isInfixOf "PR #77") (overlayLinesAtExtent extent 200 opened)
      case (rowAt WindowedPanel, rowAt FullscreenPanel) of
        ([windowed], [full]) -> do
          -- Both are elided at 200 cells, but the fullscreen row carries
          -- strictly more of the summary before its ellipsis.
          windowed `shouldSatisfy` Data.Text.isSuffixOf "…"
          full `shouldSatisfy` Data.Text.isSuffixOf "…"
          Data.Text.length full `shouldSatisfy` (> Data.Text.length windowed)
          Data.Text.length windowed `shouldSatisfy` (<= panelInterior WindowedPanel 200)
          Data.Text.length full `shouldSatisfy` (<= panelInterior FullscreenPanel 200)
        rows -> expectationFailure ("expected one conflict row at each extent, got " <> show rows)

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

    panelLines = panelLinesAt 96

    panelLinesAt width state = renderWidgetLines (themeFor testOptions) width (drawIncidents BoundedInterior state)

    -- Through the real overlay, which is where the panel's width and its
    -- border and padding are applied. The frame the overlay draws around each
    -- row is stripped so what is left is the row's own cells.
    overlayLinesAt = overlayLinesAtExtent WindowedPanel

    -- The two extents the panel can be drawn at since issue #543, and the
    -- interior a row gets at each.
    bothExtents = [WindowedPanel, FullscreenPanel]

    -- Taken from the geometry the overlay itself draws through rather than
    -- from a literal: windowed that is the fixed box the panel has always
    -- declared, and fullscreen it is the terminal less the frame column on
    -- each side, floored at the windowed width. The operating mode is only
    -- consulted for the help overlay's measured box, so any of them answers
    -- for this one.
    panelInterior extent width =
      (overlayGeometryFor DualMode IncidentsOverlay (extent == FullscreenPanel) width 80 0).overlayGeometryWidth
        - panelChrome

    -- The border the box draws and the padding inside it, one cell each side
    -- of each.
    panelChrome = 4

    overlayLinesAtExtent extent width state =
      map
        (Data.Text.dropAround (`elem` (" │┃|" :: String)))
        ( renderWidgetLines
            (themeFor testOptions)
            width
            (drawOverlay state {appOverlayFullscreen = extent == FullscreenPanel} IncidentsOverlay)
        )

    -- The single row an incident produces, which is what the kind-specific
    -- assertions above are about.
    rowEntry incident = do
      state <- reportingState [incident]
      case incidentEntries state of
        [entry] -> pure entry
        entries -> do
          expectationFailure ("expected one row, got " <> show (length entries))
          pure (entryNamed "unreachable")

    rowNote incident = do
      entry <- rowEntry incident
      case entry.incidentEntryNote of
        Just note -> pure note
        Nothing -> do
          expectationFailure "expected the row to carry a recorded failure"
          pure ""

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
          incidentEntryDetail = "incident " <> name,
          incidentEntryNote = Nothing
        }

    conflictIncident number =
      DrainerIncident
        { incidentId = "incident-conflict-" <> showNumber number,
          incidentKind = "merge-conflict",
          incidentSummary = Just ("PR #" <> showNumber number <> " has a merge conflict in README."),
          incidentPullRequest = Just number,
          incidentLastPullRequest = Nothing,
          incidentActivity = Nothing,
          incidentError = Nothing
        }

    cleanupIncident number =
      (conflictIncident number)
        { incidentId = "incident-cleanup-" <> showNumber number,
          incidentKind = "cleanup-pending",
          incidentSummary = Just ("PR #" <> showNumber number <> " merged but its cleanup keeps failing.")
        }

    -- The refusal #200 words, which is the whole point of showing the field:
    -- it names the blocker and the action that clears it.
    recordedRefusal =
      "Local changes are not what blocked this. Resolve these paths and `git add` \
      \them, and the next ordinary pass discharges the fast-forward: src/Kanban/UI.hs"

    crashIncident =
      DrainerIncident
        { incidentId = "incident-crash",
          incidentKind = "drainer-exit",
          incidentSummary = Just "drain_prs.py exited unexpectedly with code 1",
          incidentPullRequest = Nothing,
          incidentLastPullRequest = Just 7,
          incidentActivity = Just "merging PR #7",
          incidentError = Nothing
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
