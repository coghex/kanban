module Kanban.UI.Events
  ( BoardActionGate (..),
    BoardMouseAction (..),
    IncidentsAction (..),
    OverlayExtent (..),
    OverlayMouseAction (..),
    QuitDecision (..),
    QuitRequest (..),
    dashboardQuitRequest,
    applyCardClick,
    applyIncidentsAction,
    blockedByCompletedLoad,
    boardActionGate,
    boardMouseAction,
    boardMousePress,
    handleEvent,
    incidentsAction,
    mutatesSelectedWork,
    settleBoardAction,
    overlayExtent,
    overlayMouseAction,
    quitDecision,
    readOnlyHistoryGate,
    stoppingGitHubWorkNotice,
  )
where


import Brick
import Brick.BChan (writeBChan)
import Control.Concurrent (forkIO )
import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (getCurrentTime )
import qualified Graphics.Vty as Vty
import Kanban.Browser (OpenFailure, openFailureNotice, openPage)
import Kanban.Domain
import Kanban.GitHub
  ( GhCleanupFailure (..),
    GhCleanupGuard (..),
    coordinatorMustSettle,
    shutdownRefreshCoordinator
    )
import Kanban.Workflow (entryItem )
import Kanban.UI.Board (columnScrollStep, refreshColumnWindows)
import Kanban.UI.Notice (NoticeActivity (..))
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.Filter (FilterBox)
import Kanban.UI.Filter
  ( applyFilterInput,
    completedCardsBlocked,
    filterInput,
    focusFilterPanel,
    focusedFilterPanel,
    focusedSearch,
    readOnlyHistoryRefusal,
    settleFacetCounts,
    toggleFilterBoxFromClick,
    toggleFilterPanel,
  )
import Kanban.UI.Keys
import Kanban.UI.State
import Kanban.UI.Search
import Kanban.UI.Selection
import Kanban.UI.Incidents
import Kanban.UI.Refresh
import Kanban.UI.Approval
import Kanban.UI.Drainer
import Kanban.UI.Reconcile

-- | Every event the dashboard receives, and the one place the fullscreen flag
-- is settled.
--
-- 'settleOverlayFullscreen' is applied to whatever the dispatch below left
-- behind, against the overlay that was open before it. Doing it here rather
-- than beside every assignment to 'appOverlay' is what makes an overlay
-- opened from another one -- the incidents panel's Enter into a live session,
-- a solve session handing off to its PR review -- come back windowed without
-- every such transition having to remember to say so.
handleEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleEvent event = do
  now <- liftIO getCurrentTime
  modify (\state -> state {appNow = now})
  before <- get
  dispatchEvent event
  modify (settleOverlayFullscreen before.appOverlay)
  -- The notice line's settle is the same shape for the same reason: whatever
  -- the dispatch above showed, replaced, or left alone is classified and
  -- armed here, once, rather than beside every one of the many sites that
  -- produce a notice ('Kanban.UI.State.settleNoticeExpiry').
  settleNoticeExpiry before.appNotice
  -- And the board's own settle, for a third time the same shape: every event
  -- can change what a column shows, and the column layout each frame draws
  -- from is prepared here once rather than rebuilt by the frame (issue #640).
  settleColumnWindows

-- | Prepare each column's layout for the frame this event is about to
-- produce.
--
-- The geometry is brick's own, read back from the frame before this one:
-- 'lookupViewport' answers with the width a column was given and the offset
-- it ended at. Taking it from brick rather than recomputing it is what keeps
-- the measurement at the width the column is actually drawn at -- a
-- responsive width this would otherwise have to derive a second time, and
-- could derive differently.
--
-- The rows the viewport shows are deliberately not taken from here. That one
-- number the frame reads from its own render context, because a viewport that
-- grew between two frames crops rows past anything a recorded height could
-- have been widened around.
--
-- Reading the offset back is why the frame covers a set of offsets rather
-- than one: this is the previous frame's, and the frame it prepares can be
-- cropped a wheel press or a scroll-into-view away from it.
settleColumnWindows :: EventM Name AppState ()
settleColumnWindows = do
  geometry <- traverse columnGeometry allColumns
  -- The filter panel's figures settle with them, and for the same reason:
  -- each is a count over the complete datasets, and a frame that worked them
  -- out would pay for the whole board on every redraw the panel is up for.
  modify (settleFacetCounts . refreshColumnWindows geometry)
  where
    columnGeometry column = do
      measured <- lookupViewport (ColumnViewport column)
      pure (column, fmap dimensions measured)
    dimensions measured = (fst (_vpSize measured), _vpTop measured)

dispatchEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
dispatchEvent event = do
  state <- get
  case (state.appOverlay, event) of
    -- Handle terminal focus before any overlay consumes the event. Refreshing
    -- preserves the open overlay and draft, and losing focus starts no work.
    (_, VtyEvent Vty.EvGainedFocus) -> startFocusRefresh
    (_, VtyEvent Vty.EvLostFocus) -> pure ()
    (_, AppEvent (BoardRefreshFinished generation result)) -> applyBoardRefresh generation result
    (_, AppEvent (BoardRefreshStarted generation)) -> markBoardRefreshRunning generation
    -- The notice reports the pause once; the status is what outlives it, so
    -- the footer and the completed blocker still say so after the next press
    -- clears the line.
    (_, AppEvent (BoardHistoryPaused resetAt)) -> do
      modify (\current -> current {appCompletedStatus = CompletedHistoryPaused resetAt})
      modify (noticeSetOverStartupReport (historyPausedNotice state.appTimeZone resetAt))
    (_, AppEvent (BoardHistoryUpdated generation historyOutcome)) -> applyBoardHistory generation historyOutcome
    (_, AppEvent (BoardRefreshShutdownFinished verdict)) -> completeDashboardQuit verdict
    (_, AppEvent (CodexRefreshFinished result)) -> applyCodexRefresh result
    (_, AppEvent (ClaudeRefreshFinished result)) -> applyClaudeRefresh result
    (_, AppEvent (DrainerStatusRefreshed result)) -> applyDrainerStatus result
    (_, AppEvent (DrainerToggleFinished result)) -> applyDrainerToggle result
    (_, AppEvent (ApprovalStatusRefreshed issuedUnder result)) -> applyApprovalStatus issuedUnder result
    (_, AppEvent (ApprovalToggleFinished transition result)) -> applyApprovalToggle transition result
    (_, AppEvent (DirectMergeFinished number result)) -> applyDirectMerge number result
    -- The tick clears only the instance it was armed for, and only once that
    -- instance's deadline has actually passed; everything else about the
    -- decision is 'Kanban.UI.Util.noticeExpiryApplied''s.
    (_, AppEvent (NoticeExpired instanceId)) -> modify (noticeExpiryApplied instanceId)
    (_, AppEvent (PageOpenFinished url outcome)) -> reportPageOpen url outcome
    -- @f@ is the one binding live in every overlay, so it is resolved once
    -- here rather than in each overlay's own arms below. It has to come first:
    -- the incidents panel answers /every/ event it receives, so a letter
    -- reaching it is a letter it has swallowed.
    (Just _, VtyEvent keyEvent)
      | Just ToggleFullscreen <- boardAction OverlayScope keyEvent ->
          modify toggleOverlayFullscreen
    -- The help overlay answers nothing of its own, so its scoped bindings can
    -- be resolved before the overlays below, which do.
    (Just HelpOverlay, VtyEvent keyEvent)
      | Just action <- boardAction HelpScope keyEvent -> applyBoardAction action
    (overlay, incidentEvent)
      | Just action <- incidentsAction overlay incidentEvent -> handleIncidentsAction action
    (Just (DetailsOverlay _), VtyEvent keyEvent)
      | Just action <- boardAction DetailsScope keyEvent -> applyBoardAction action
    (Just (DetailsOverlay _), mouseEvent)
      | Just action <- overlayMouseAction (overlayExtent state) DetailsPanel mouseEvent -> applyOverlayMouseAction scrollDetails action
    -- What is left for an overlay that answered none of the above. Esc is the
    -- fallback for one that neither handles it itself nor appears as a
    -- 'BindingScope'; the scrolling keys are live for the help and details
    -- overlays, which the table deliberately does not claim @j@ and @k@ in.
    (Just _, VtyEvent (Vty.EvKey Vty.KEsc [])) -> modify (\current -> noticeCleared current {appOverlay = Nothing})
    (Just _, VtyEvent (Vty.EvKey Vty.KDown [])) -> vScrollBy (viewportScroll DetailsViewport) 1
    (Just _, VtyEvent (Vty.EvKey (Vty.KChar 'j') [])) -> vScrollBy (viewportScroll DetailsViewport) 1
    (Just _, VtyEvent (Vty.EvKey Vty.KUp [])) -> vScrollBy (viewportScroll DetailsViewport) (-1)
    (Just _, VtyEvent (Vty.EvKey (Vty.KChar 'k') [])) -> vScrollBy (viewportScroll DetailsViewport) (-1)
    (Just _, _) -> pure ()
    -- A focused filter panel and a live search each decode the base board's
    -- key presses ahead of the table, so a printable key edits a checkbox or
    -- types into the query instead of firing the binding that letter
    -- ordinarily carries. The panel outranks the search because focus moves
    -- between the two explicitly -- `s` yields it and `F` takes it back --
    -- rather than being inferred from which is on screen. Neither claims
    -- anything carrying Ctrl, Meta, or Alt, and nothing either declines
    -- reaches the table below with anything but its ordinary meaning.
    (Nothing, VtyEvent keyEvent)
      | Just input <- filterInput (focusedFilterPanel state) keyEvent -> modify (applyFilterInput input)
    (Nothing, VtyEvent keyEvent)
      | Just input <- searchInput (focusedSearch state) keyEvent -> handleSearchInput input
    (Nothing, VtyEvent keyEvent)
      | Just action <- boardAction BoardScope keyEvent -> applyBoardAction action
    (Nothing, MouseDown name button modifiers _)
      | Just action <- boardMouseAction state name button modifiers -> applyBoardMouseAction action
    _ -> pure ()

-- | What one mouse press on the base board means.
--
-- The whole precedence, decided in one place rather than spread over the arms
-- that carry it out, for the same reason the key table in "Kanban.UI.Keys"
-- is: a press whose meaning depends on what else is open — and under a live
-- search every column press does — cannot be reasoned about, or tested, one
-- arm at a time.
data BoardMouseAction
  = -- | Move the live search to this column, consuming the press.
    TransferSearch BoardColumn
  | ToggleDrainerFromClick
  | ToggleApprovalFromClick
  | RefreshAllFromClick
  | ToggleFilterBoxFromClick FilterBox
  | ToggleEpicFromClick BoardColumn Int Int
  | SelectOrOpenCardAt BoardColumn Int
  | SelectCardOnlyAt BoardColumn Int
  | ScrollColumnBy BoardColumn Int
  deriving stock (Eq, Show)

-- | The press's meaning, or 'Nothing' when the board claims nothing for it.
--
-- A live search outranks every column press: a left or right press aimed at
-- any column but the searched one moves the search there and does nothing
-- else, wherever in that column it landed. It does not outrank the three
-- sidebar controls or a filter checkbox, none of which is a column target at
-- all and all of which are answered first, and it claims neither the wheel —
-- which retargets nothing, so it keeps scrolling whatever is under the
-- pointer — nor the middle button.
--
-- All three sidebar controls take a plain left press and nothing else. A
-- middle, right, wheel, or modifier-carrying press over one falls through
-- every arm below, which name only column targets, and the board claims
-- nothing for it.
--
-- The completed-history blocker outranks every /card/ press and nothing else.
-- No column is drawn under it, so a @CardTarget@, @EpicTarget@, or
-- @ColumnViewport@ press arriving there names a row from a frame that is no
-- longer on screen; resolving one would act on whatever the criteria have
-- since put at that index. The sidebar controls and the filter panel are drawn
-- through the blocker and keep working.
boardMouseAction :: AppState -> Name -> Vty.Button -> [Vty.Modifier] -> Maybe BoardMouseAction
boardMouseAction state name button modifiers = case (name, button, modifiers) of
  (DrainerButton, Vty.BLeft, []) -> Just ToggleDrainerFromClick
  (ApprovalButton, Vty.BLeft, []) -> Just ToggleApprovalFromClick
  (UpdateButton, Vty.BLeft, []) -> Just RefreshAllFromClick
  (FilterBoxTarget box, Vty.BLeft, _) -> Just (ToggleFilterBoxFromClick box)
  _ | completedCardsBlocked state -> Nothing
  _ | Just column <- searchMouseTransfer state name button -> Just (TransferSearch column)
  (EpicTarget column _ _, Vty.BScrollUp, _) -> Just (ScrollColumnBy column (-columnScrollStep))
  (EpicTarget column _ _, Vty.BScrollDown, _) -> Just (ScrollColumnBy column columnScrollStep)
  (EpicTarget column row trackerNumber, Vty.BLeft, _) -> Just (ToggleEpicFromClick column row trackerNumber)
  (CardTarget column row, Vty.BRight, _) -> Just (SelectCardOnlyAt column row)
  (CardTarget column row, Vty.BLeft, _) -> Just (SelectOrOpenCardAt column row)
  (CardTarget column _, Vty.BScrollUp, _) -> Just (ScrollColumnBy column (-columnScrollStep))
  (CardTarget column _, Vty.BScrollDown, _) -> Just (ScrollColumnBy column columnScrollStep)
  (ColumnViewport column, Vty.BScrollUp, _) -> Just (ScrollColumnBy column (-columnScrollStep))
  (ColumnViewport column, Vty.BScrollDown, _) -> Just (ScrollColumnBy column columnScrollStep)
  _ -> Nothing

-- | What one decided press does to the dashboard. Total in
-- 'BoardMouseAction', so a press cannot be given a meaning above without its
-- effect being decided here — and pure, so the effect a press has can be
-- taken and inspected without a terminal, a viewport, or a subprocess.
boardMousePress :: BoardMouseAction -> AppState -> AppState
boardMousePress = \case
  TransferSearch column -> transferSearchTo column
  ToggleDrainerFromClick -> fst . drainerTogglePress
  -- The key's own pure core, not a second decision: 'toggleApprovalService'
  -- is exactly this half of 'approvalTogglePress' followed by the handoff
  -- 'applyBoardMouseAction' runs below, so the click cannot acquire a toggle
  -- policy of its own.
  ToggleApprovalFromClick -> fst . approvalTogglePress
  -- The update is not a state transition of its own. Every mark it leaves —
  -- the loading freshness, the notice, the coalesced follow-up — is made by
  -- the same 'startAllRefreshes' the key reaches, which is where a press made
  -- during a cycle in flight is decided.
  RefreshAllFromClick -> id
  ToggleFilterBoxFromClick box -> toggleFilterBoxFromClick box
  ToggleEpicFromClick column row trackerNumber -> toggleTrackerState column row trackerNumber
  SelectOrOpenCardAt column row -> applyCardClick column row
  SelectCardOnlyAt column row -> selectCardOnly column row
  -- Scrolling a viewport is not a state change; all the state carries is that
  -- this frame must not drag the selection back into view.
  ScrollColumnBy _ _ -> \state -> state {appEnsureSelectionVisible = False}

-- | Carries out one decided press: its effect on the state, and then the
-- four things that are not state — the viewport scroll, the controller
-- handoff a drainer press makes, the controller handoff an approval press
-- makes, and the update an update press starts.
applyBoardMouseAction :: BoardMouseAction -> EventM Name AppState ()
applyBoardMouseAction action = do
  before <- get
  modify (boardMousePress action)
  case action of
    ScrollColumnBy column amount -> vScrollBy (viewportScroll (ColumnViewport column)) amount
    ToggleDrainerFromClick -> runDrainerToggleHandoff before
    -- Read off the state the press was taken from, which is what makes this
    -- the same handoff the key path runs: 'toggleApprovalService' decides
    -- from the pre-press state too.
    ToggleApprovalFromClick -> runApprovalToggleHandoff before
    -- The key's own dispatch, not a second call to whatever it happens to
    -- reach today, so the click cannot acquire a refresh path of its own.
    RefreshAllFromClick -> applyBoardAction RefreshAll
    _ -> pure ()

-- | Carries out one binding from "Kanban.UI.Keys". Total in 'BoardAction', so
-- a binding cannot be added to that table without deciding here what pressing
-- it does.
--
-- The scope it fired in is not a parameter: the five actions that are live
-- from a card's details overlay as well as from the board act on whichever
-- selection is in front of the user, and that is exactly what the open
-- overlay says.
applyBoardAction :: BoardAction -> EventM Name AppState ()
applyBoardAction action = do
  state <- get
  case boardActionGate state action of
    DispatchBoardAction -> dispatchBoardAction action
    IgnoreBoardAction -> pure ()
    RefuseBoardAction notice -> setNotice notice

-- | What happens to a press before 'dispatchBoardAction' could see it.
data BoardActionGate
  = -- | Nothing is in the way; the arm runs.
    DispatchBoardAction
  | -- | The press is inert and says nothing.
    IgnoreBoardAction
  | -- | The press is refused, with this notice instead.
    RefuseBoardAction Text
  deriving stock (Eq, Show)

-- | Everything that can stand between a key press and its arm, as one pure
-- decision, in the order the three are asked.
--
-- The operating mode is asked first, and that ordering is the contract rather
-- than an accident: the two gates below it resolve the card in front of the
-- user, and a board that spawns nothing must refuse `a` with the reason that
-- is actually true of it -- the roster loads no provider -- however the
-- selection happens to be sitting. Settled history and the completed-history
-- blocker are facts about /that card/, and they are the right answer only once
-- there is a mode in which the key could work at all.
--
-- Pure, and the whole of what 'applyBoardAction' decides, so a press can be
-- taken and inspected without a terminal.
boardActionGate :: AppState -> BoardAction -> BoardActionGate
boardActionGate state action
  | Just refusal <- agentSurfaceRefusal state.appOperatingMode action = RefuseBoardAction refusal
  | completedCardsBlocked state && blockedByCompletedLoad action = IgnoreBoardAction
  | Just notice <- readOnlyHistoryGate state action = RefuseBoardAction notice
  | otherwise = DispatchBoardAction

-- | What a press the gate settled does to the state, and the whole of it.
--
-- A refusal writes one field and nothing else -- no overlay opens, no process
-- is spawned or killed, and the approval service is neither started nor
-- stopped -- because that is what
-- 'Kanban.UI.State.setNotice', the arm above, does. Written out here so the
-- suite can take a populated dashboard through a refused press and hold every
-- one of those to it.
settleBoardAction :: BoardActionGate -> AppState -> AppState
settleBoardAction gate = case gate of
  DispatchBoardAction -> id
  IgnoreBoardAction -> id
  RefuseBoardAction notice -> noticeSet notice

-- | Which bindings the completed-history blocker makes inert.
--
-- Everything that reaches a card does: the blocker draws none, so a press that
-- moved, opened, or acted on one would be resolving a selection left over from
-- the frame before it. Nothing else is touched — the filter panel that put the
-- blocker up, the footer, help, options, refresh, the drainer, the issue
-- approval service, the sidebar, @Esc@, @q@, and @Ctrl-C@ all stay exactly as
-- usable as they were.
--
-- Total in 'BoardAction' for the same reason 'mutatesSelectedWork' is: a
-- binding added to the table in "Kanban.UI.Keys" cannot reach the board
-- without a decision about whether a card-free surface may dispatch it.
blockedByCompletedLoad :: BoardAction -> Bool
blockedByCompletedLoad = \case
  NextCard -> True
  PreviousCard -> True
  PreviousColumn -> True
  NextColumn -> True
  FirstItem -> True
  LastItem -> True
  OpenSearch -> True
  ToggleEpic -> True
  ShowDetails -> True
  OpenCardPage -> True
  MergeDoneCard -> True
  ShowFilter -> False
  -- Reaches no card: it resizes whichever overlay is already open, and the
  -- blocker is a board-side surface with no overlay over it in the first
  -- place.
  ToggleFullscreen -> False
  DismissOrClose -> False
  ShowIncidents -> False
  RefreshAll -> False
  ToggleApproval -> False
  ToggleDrainer -> False
  ToggleSidebar -> False
  -- Reaches no card either: it changes how every card is laid out, and a
  -- blocker that is drawing none of them still has a footer, a filter panel,
  -- and a board to come back to.
  ToggleExcerpts -> False
  ShowHelp -> False
  RepaintTerminal -> False
  QuitDashboard -> False

-- | Whether the card in front of the user puts this action out of reach, and
-- what to say instead.
--
-- One decision covering every mutating binding, taken before any of them
-- resolves a target, so a completed card refuses ahead of the wrong-kind,
-- approval and drainer-state errors each arm would otherwise report. The arm
-- re-asks it at its own boundary, which is what an overlay opened before a
-- refresh needs; this is what makes the key press itself refuse.
readOnlyHistoryGate :: AppState -> BoardAction -> Maybe Text
readOnlyHistoryGate state action
  | mutatesSelectedWork action = subject >>= readOnlyHistoryRefusal state
  | otherwise = Nothing
  where
    -- Exactly what the arms below act on: the item a details overlay is open
    -- for, and otherwise the board's own selection, promoted to the epic a
    -- collapsed group draws.
    subject = case state.appOverlay of
      Just (DetailsOverlay item) -> Just item
      _ -> selectedBoardItem state

-- | Which bindings act on the work a card stands for rather than only reading
-- it or moving around it.
--
-- Total in 'BoardAction' on purpose: a binding added to the table in
-- "Kanban.UI.Keys" cannot reach the board without a decision here about
-- whether settled history is allowed to reach it.
mutatesSelectedWork :: BoardAction -> Bool
mutatesSelectedWork = \case
  MergeDoneCard -> True
  NextCard -> False
  PreviousCard -> False
  PreviousColumn -> False
  NextColumn -> False
  FirstItem -> False
  LastItem -> False
  OpenSearch -> False
  ShowFilter -> False
  ToggleEpic -> False
  ShowDetails -> False
  OpenCardPage -> False
  ToggleFullscreen -> False
  DismissOrClose -> False
  ShowIncidents -> False
  RefreshAll -> False
  ToggleApproval -> False
  ToggleDrainer -> False
  ToggleSidebar -> False
  ToggleExcerpts -> False
  ShowHelp -> False
  RepaintTerminal -> False
  QuitDashboard -> False

dispatchBoardAction :: BoardAction -> EventM Name AppState ()
dispatchBoardAction = \case
  NextCard -> moveCard 1
  PreviousCard -> moveCard (-1)
  PreviousColumn -> moveColumn (-1)
  NextColumn -> moveColumn 1
  FirstItem -> selectBoundary False
  LastItem -> selectBoundary True
  ToggleEpic -> toggleSelectedTracker
  ShowDetails -> openSelectedDetails
  OpenCardPage -> onSelection openItemPage openSelectedPage
  ToggleFullscreen -> modify toggleOverlayFullscreen
  DismissOrClose -> closeOverlay
  ShowIncidents -> handleIncidentsAction OpenIncidentsPanel
  RefreshAll -> startAllRefreshes
  ToggleApproval -> toggleApprovalService
  ToggleDrainer -> toggleDrainer
  MergeDoneCard -> onSelection mergeItemDoneCard mergeSelectedDoneCard
  ToggleSidebar -> modify (\current -> current {appSidebarVisible = not current.appSidebarVisible})
  ToggleExcerpts -> modify toggleCardExcerpts
  OpenSearch -> modify openSearch
  ShowFilter -> modify toggleFilterPanel
  ShowHelp -> modify (\current -> current {appOverlay = Just HelpOverlay})
  RepaintTerminal -> forceTerminalRepaint
  QuitDashboard -> requestDashboardQuit
  where
    onSelection onItem onBoard = do
      state <- get
      case state.appOverlay of
        Just (DetailsOverlay item) -> onItem item
        _ -> onBoard

-- | Carries out one decoded search key press. Every input is a pure
-- transition: 'applySearchInput' decides all but Enter, which is
-- 'openSearchResult' because opening a card's details is the board's own
-- transition and search only ends beneath it, and @F@, which is the filter
-- panel's own transition for the same reason.
handleSearchInput :: SearchInput -> EventM Name AppState ()
handleSearchInput SearchOpenDetails = modify openSearchResult
handleSearchInput SearchFocusFilter = modify focusFilterPanel
handleSearchInput input = modify (applySearchInput input)

-- | The quit key's decision.
--
-- Nothing about an agent is involved: the dashboard starts none, and quitting
-- never waits on, signals, or mentions one.
--
-- The @gh@ this dashboard owns is what the decision is about. With nothing queued or
-- running there is nothing to stop and the halt is immediate, which is what
-- keeps an ordinary quit instant; otherwise the queued work is cancelled and
-- the running fetch is put through the same verified cleanup a refresh
-- timeout puts it through, and the dashboard stops only once that has reached
-- a verdict.
requestDashboardQuit :: EventM Name AppState ()
requestDashboardQuit = do
  state <- get
  mustSettle <- liftIO (coordinatorMustSettle state.appRefreshCoordinator)
  case dashboardQuitRequest state mustSettle of
    QuitAlreadySettling -> setNoticeFor QuitSettling stoppingGitHubWorkNotice
    QuitImmediate -> halt
    QuitMustSettle -> do
      modify (\current -> noticeSetFor QuitSettling stoppingGitHubWorkNotice current {appOverlay = Nothing, appQuitPending = True})
      void . liftIO . forkIO $
        shutdownRefreshCoordinator state.appRefreshCoordinator
          >>= writeBChan state.appEventChannel . BoardRefreshShutdownFinished

-- | What the quit key does, as a value.
--
-- Pure so the decision is assertable without a terminal. The coordinator's
-- answer is a parameter rather than read here because it is the one input
-- that needs IO.
data QuitRequest
  = -- | A settle this dashboard already started.
    QuitAlreadySettling
  | -- | Nothing is queued or running, so the halt is immediate.
    QuitImmediate
  | -- | GitHub work has to be stopped first.
    QuitMustSettle
  deriving stock (Eq, Show)

dashboardQuitRequest :: AppState -> Bool -> QuitRequest
dashboardQuitRequest state mustSettle
  | state.appQuitPending = QuitAlreadySettling
  | mustSettle = QuitMustSettle
  | otherwise = QuitImmediate

stoppingGitHubWorkNotice :: Text
stoppingGitHubWorkNotice = "Stopping GitHub work…"

-- | What a finished cancellation lets the dashboard do.
data QuitDecision
  = QuitHalts
  | -- | The dashboard stays up, and says why.
    QuitHeldBack Text
  deriving stock (Eq, Show)

-- | Whether the cleanup verdict leaves anything ambiguous behind.
--
-- A cleanup that proved the group gone, and one that could not but wrote the
-- group to the durable record, both leave nothing ambiguous: the first because
-- there is nothing left, the second because the next run of the dashboard
-- re-checks the record before it spawns anything. An in-memory-only guard is
-- neither — it is a possibly-live @gh@ whose only remaining guard is this
-- process's own refusal to start another. Stopping there would drop exactly
-- that, so the quit is refused and says so; and because the coordinator stays
-- cancelled, this dashboard starts no further @gh@ either.
quitDecision :: Maybe GhCleanupFailure -> QuitDecision
quitDecision Nothing = QuitHalts
quitDecision (Just failure) = case failure.ghCleanupGuard of
  GuardRecorded -> QuitHalts
  GuardInMemoryOnly ->
    QuitHeldBack
      ( "Not quitting: a gh process this dashboard started could not be confirmed stopped ("
          <> failure.ghCleanupMessage
          <> ") and nothing durable records it, so this process's refusal is all that holds the next one back"
          <> " -- stop the stray gh, then end this dashboard from outside"
      )

completeDashboardQuit :: Maybe GhCleanupFailure -> EventM Name AppState ()
completeDashboardQuit verdict = case quitDecision verdict of
  QuitHalts -> halt
  QuitHeldBack notice -> modify (\current -> noticeSet notice current {appQuitPending = False})

-- | Whether the overlay a click landed over is drawn windowed or fullscreen,
-- which is the whole of what the mouse policy below needs to know about it.
data OverlayExtent
  = WindowedOverlay
  | FullscreenOverlay
  deriving stock (Eq, Show)

-- | The extent the open overlay is currently drawn at.
overlayExtent :: AppState -> OverlayExtent
overlayExtent state
  | state.appOverlayFullscreen = FullscreenOverlay
  | otherwise = WindowedOverlay

-- | The decision a content overlay's shared mouse policy reaches for a given
-- event, independent of how that decision gets carried out. Wheel events
-- always resolve to a scroll regardless of which name they land on
-- (background card, the panel, or the viewport itself) and never close the
-- overlay; any other click outside the panel closes it, matching the
-- outside-click contract. Pure so the policy can be unit tested without a
-- running EventM.
data OverlayMouseAction
  = OverlayMouseScroll Int
  | OverlayMouseClose
  | OverlayMouseNoOp
  deriving stock (Eq, Show)

-- | The same policy, told which extent the overlay is drawn at.
--
-- A fullscreen box withdraws exactly one gesture: the plain outside click that
-- closes a windowed overlay (@docs\/overlay_focus_fullscreen_design.md@
-- D-17). What is left beside and below such a box is the application's own
-- frame and its footer rather than the board the windowed gesture is aimed
-- past, and a stray press at the very edge of the screen would otherwise throw
-- away a panel the user has just made as big as they could.
--
-- The right click is /not/ that gesture and keeps today's meaning at both
-- extents, which is what section 7 means by listing it among a fullscreen
-- overlay's exits. It is hoisted above the panel test on purpose: a click
-- inside a panel is reported against whichever extent brick finds innermost
-- there, and for the details and session overlays that is the scrolling
-- viewport rather than the panel, so a right click over the content has always
-- arrived here unnamed. Deciding it by button rather than by name is what
-- makes "right-click closes" true of the whole box instead of only its border.
overlayMouseAction :: OverlayExtent -> Name -> BrickEvent Name AppEvent -> Maybe OverlayMouseAction
overlayMouseAction extent panel event = case event of
  MouseDown _ Vty.BScrollUp _ _ -> Just (OverlayMouseScroll (-3))
  MouseDown _ Vty.BScrollDown _ _ -> Just (OverlayMouseScroll 3)
  VtyEvent (Vty.EvMouseDown _ _ Vty.BScrollUp _) -> Just (OverlayMouseScroll (-3))
  VtyEvent (Vty.EvMouseDown _ _ Vty.BScrollDown _) -> Just (OverlayMouseScroll 3)
  MouseDown _ Vty.BRight _ _ -> Just OverlayMouseClose
  VtyEvent (Vty.EvMouseDown _ _ Vty.BRight _) -> Just OverlayMouseClose
  MouseDown name _ _ _
    | name == panel -> Just OverlayMouseNoOp
  MouseDown _ _ _ _ -> Just outsideClick
  VtyEvent (Vty.EvMouseDown _ _ _ _) -> Just outsideClick
  _ -> Nothing
  where
    outsideClick = case extent of
      WindowedOverlay -> OverlayMouseClose
      FullscreenOverlay -> OverlayMouseNoOp

applyOverlayMouseAction :: (Int -> EventM Name AppState ()) -> OverlayMouseAction -> EventM Name AppState ()
applyOverlayMouseAction scrollOverlay = \case
  OverlayMouseScroll amount -> scrollOverlay amount
  OverlayMouseClose -> closeOverlay
  OverlayMouseNoOp -> pure ()

-- | What one event does to the incidents panel. Separated from the dispatch
-- that carries it out so the whole interaction — opening the panel, moving,
-- clicking, activating, closing — is decided by pure code that needs no
-- terminal (docs\/design.md §18).
data IncidentsAction
  = OpenIncidentsPanel
  | CloseIncidentsPanel
  | MoveIncidentSelection Int
  | ScrollIncidentsPanel Int
  | ActivateSelectedIncident
  | ClickIncidentRow IncidentRef
  | IgnoreIncidentsEvent
  deriving stock (Eq, Show)

-- | The panel's event policy while it is open: it consumes its own keys and
-- mouse events. 'Nothing' means the event is not the panel's business and the
-- dashboard's other bindings decide it — including the @i@ that opens the
-- panel in the first place, which is a base-board binding like any other and
-- is declared once in "Kanban.UI.Keys" rather than a second time here.
--
-- What this answers is named for the user by 'incidentsFooterHints', which
-- the base footer draws while the panel is open (issue #525), so a key added
-- or dropped here owes that list a row.
incidentsAction :: Maybe Overlay -> BrickEvent Name AppEvent -> Maybe IncidentsAction
incidentsAction (Just IncidentsOverlay) event = Just $ case event of
  VtyEvent (Vty.EvKey Vty.KEsc []) -> CloseIncidentsPanel
  VtyEvent (Vty.EvKey Vty.KDown []) -> MoveIncidentSelection 1
  VtyEvent (Vty.EvKey (Vty.KChar 'j') []) -> MoveIncidentSelection 1
  VtyEvent (Vty.EvKey Vty.KUp []) -> MoveIncidentSelection (-1)
  VtyEvent (Vty.EvKey (Vty.KChar 'k') []) -> MoveIncidentSelection (-1)
  VtyEvent (Vty.EvKey Vty.KEnter []) -> ActivateSelectedIncident
  -- Wheel events resolve to a scroll wherever they land: the rows are
  -- clickable, so a wheel over one is reported against the row rather than
  -- against the panel.
  MouseDown _ Vty.BScrollUp _ _ -> ScrollIncidentsPanel (-3)
  MouseDown _ Vty.BScrollDown _ _ -> ScrollIncidentsPanel 3
  MouseDown (IncidentTarget reference) Vty.BLeft _ _ -> ClickIncidentRow reference
  _ -> IgnoreIncidentsEvent
incidentsAction _ _ = Nothing

-- | Carries out one 'IncidentsAction'. Read-only with respect to everything
-- the panel lists: it moves the dashboard's own selection and overlay and
-- touches no incident, session, or GitHub state.
applyIncidentsAction :: IncidentsAction -> AppState -> AppState
applyIncidentsAction action state = case action of
  OpenIncidentsPanel ->
    noticeCleared
      state
        { appOverlay = Just IncidentsOverlay,
          appIncidentSelection = resolveIncidentSelection entries state.appIncidentSelection
        }
  CloseIncidentsPanel -> noticeCleared state {appOverlay = Nothing}
  MoveIncidentSelection amount -> state {appIncidentSelection = movedSelection amount}
  ScrollIncidentsPanel amount -> state {appIncidentSelection = movedSelection amount}
  ActivateSelectedIncident -> activate (activationTarget state.appIncidentSelection)
  ClickIncidentRow clickedRef -> case resolveIncidentClick entries state.appIncidentSelection clickedRef of
    IncidentClickIgnored -> state
    IncidentClickOpen -> activate (Just clickedRef)
    IncidentClickSelect selection -> state {appIncidentSelection = selection}
  IgnoreIncidentsEvent -> state
  where
    entries = incidentEntries state

    -- Which identity a key press aims at, which is not always the one
    -- stored. A selection that already names a row keeps that name even
    -- after the row disappears: that is what stops a refresh from handing
    -- the key press to whatever moved into its place. A selection that
    -- names nothing has no such claim to protect — it is what a panel
    -- opened over an empty list leaves behind — and a poll that lands the
    -- first row while the panel is open makes 'drawIncidents' resolve and
    -- highlight it. Resolving here too is what keeps Enter acting on the
    -- row the user can see highlighted.
    activationTarget selection = case selection.incidentSelectionRef of
      Just reference -> Just reference
      Nothing -> (resolveIncidentSelection entries selection).incidentSelectionRef

    movedSelection amount =
      let resolved = resolveIncidentSelection entries state.appIncidentSelection
          maximumIndex = max 0 (length entries - 1)
          nextIndex = max 0 (min maximumIndex (resolved.incidentSelectionRow + amount))
       in IncidentSelection (incidentEntryRef <$> safeIndex nextIndex entries) nextIndex

    activate Nothing = noticeSet "No incident is selected" state
    -- Resolved against the visible view: activation moves the selection to a
    -- row, and a row is an index into what the criteria are showing.
    activate (Just reference) = case resolveIncidentActivation state.appVisibleBoard entries reference of
      -- The row went away between the last render and this key press. The
      -- panel stays open with nothing acted on, rather than sending the user
      -- to whichever incident took its place.
      Nothing -> noticeSet "That incident is no longer listed" state
      Just activation -> applyIncidentActivation activation state

applyIncidentActivation :: IncidentActivation -> AppState -> AppState
applyIncidentActivation activation state =
  maybe noticeCleared noticeSet activation.incidentActivationNotice
    . selectWork
    $ state {appOverlay = Nothing}
  where
    selectWork current = case activation.incidentActivationWork of
      -- No row to go to: column, row, and tracker expansion are all left
      -- exactly as they were.
      Nothing -> current
      Just location ->
        current
          { appSelectedColumn = location.boardWorkColumn,
            appSelectedRows = Map.insert location.boardWorkColumn location.boardWorkRow current.appSelectedRows,
            appExpandedTrackers = maybe id Set.insert location.boardWorkExpands current.appExpandedTrackers,
            -- With the set, for the reason 'Kanban.UI.Types.appExpansionEpoch'
            -- states. Bumped whether or not this reveal expands anything: a
            -- counter that moves without the set costs one column measurement,
            -- while a set that moves without the counter draws a stale one.
            appExpansionEpoch = current.appExpansionEpoch + 1,
            appEnsureSelectionVisible = True
          }

-- | Dispatches one panel action, adding the one effect the pure transition
-- cannot express: the viewport scroll a wheel event asks for.
handleIncidentsAction :: IncidentsAction -> EventM Name AppState ()
handleIncidentsAction action = do
  modify (applyIncidentsAction action)
  case action of
    ScrollIncidentsPanel amount -> vScrollBy (viewportScroll IncidentsViewport) amount
    _ -> pure ()

-- | Open the board selection's own GitHub page, promoted to the epic a
-- collapsed group draws exactly as the keys that act on a card are
-- ('Kanban.UI.Selection.selectedBoardItem').
--
-- Nothing at all when there is no selection: an empty column has no page, and
-- there is no launch to make for one.
openSelectedPage :: EventM Name AppState ()
openSelectedPage = do
  state <- get
  mapM_ openItemPage (selectedBoardItem state)

-- | Hand one card's retained URL to the platform's opener.
--
-- 'Kanban.Browser.openPage' forks before it resolves anything, so this
-- returns while the opener is still starting: the board, the selection, and a
-- refresh in flight are all untouched, and the outcome arrives later as a
-- 'PageOpenFinished' carrying the URL this launch was made for rather than
-- whatever is selected by then.
openItemPage :: BoardItem -> EventM Name AppState ()
openItemPage item = do
  state <- get
  let url = itemUrl item
  liftIO (openPage url (writeBChan state.appEventChannel . PageOpenFinished url))

-- | What one finished launch says. A clean one says nothing: the page is up
-- in another window, and announcing that would be noise over the board.
reportPageOpen :: Text -> Maybe OpenFailure -> EventM Name AppState ()
reportPageOpen _ Nothing = pure ()
reportPageOpen url (Just failure) = setNotice (openFailureNotice url failure)

scrollDetails :: Int -> EventM Name AppState ()
scrollDetails = vScrollBy (viewportScroll DetailsViewport)

-- | What a left click on a board card does. A click that only selects leaves a
-- live search running; one that opens details ends it, on the identity it
-- opened, exactly as Enter does.
applyCardClick :: BoardColumn -> Int -> AppState -> AppState
applyCardClick column row state
  | state.appSelectedColumn == column && selectedRow state column == row =
      case safeIndex row (entriesFor state column) of
        Just entry ->
          closeSearchOn
            (anchorAt state column row)
            (noticeCleared state {appOverlay = Just (DetailsOverlay (entryItem entry))})
        Nothing -> state
  | otherwise = selectCardOnly column row state

selectCardOnly :: BoardColumn -> Int -> AppState -> AppState
selectCardOnly column row state =
  noticeCleared
    state
      { appSelectedColumn = column,
        appSelectedRows = Map.insert column row state.appSelectedRows,
        appEnsureSelectionVisible = True
      }
