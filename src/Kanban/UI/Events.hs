module Kanban.UI.Events
  ( BoardMouseAction (..),
    IncidentsAction (..),
    OverlayMouseAction (..),
    QuitDecision (..),
    applyCardClick,
    applyIncidentsAction,
    applyRunningProcessClick,
    blockedByCompletedLoad,
    boardMouseAction,
    boardMousePress,
    handleEvent,
    incidentsAction,
    killSelectionNotice,
    mutatesSelectedWork,
    settledSessionRefusal,
    overlayMouseAction,
    quitDecision,
    readOnlyHistoryGate,
    stoppingGitHubWorkNotice,
  )
where


import Brick
import Brick.BChan (writeBChan)
import Control.Concurrent (forkIO )
import Control.Monad (void, when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (getCurrentTime )
import qualified Graphics.Vty as Vty
import Kanban.Domain
import Kanban.GitHub
  ( GhCleanupFailure (..),
    GhCleanupGuard (..),
    coordinatorMustSettle,
    shutdownRefreshCoordinator
    )
import Kanban.Process (killManagedProcess )
import Kanban.Review
  ( interruptReview,
    killReviewTools
    )
import Kanban.Solve
  ( SolveWorkflow (..),
    SolverBrand (..)
    )
import Kanban.Settings
  ( ChatVerbosity (..),
    Settings (..),
    saveSettings,
    verbosityLabel
  )
import Kanban.Workflow (entryItem )
import Kanban.Worker
  ( terminateWorker
    )
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
    readOnlyHistoryRefusalFor,
    toggleFilterBoxFromClick,
    toggleFilterPanel,
  )
import Kanban.UI.Keys
import Kanban.UI.SessionCore
import Kanban.UI.State
import Kanban.UI.Transcript
import Kanban.UI.Search
import Kanban.UI.Selection
import Kanban.UI.Session
import Kanban.UI.SessionEvents
import Kanban.UI.Refresh
import Kanban.UI.Solve
import Kanban.UI.Approval
import Kanban.UI.PullRequest
import Kanban.UI.Review
import Kanban.UI.Worker
import Kanban.UI.Reconcile

handleEvent :: BrickEvent Name AppEvent -> EventM Name AppState ()
handleEvent event = do
  now <- liftIO getCurrentTime
  modify (\state -> state {appNow = now})
  state <- get
  case (state.appOverlay, event) of
    (_, AppEvent (BoardRefreshFinished generation result)) -> applyBoardRefresh generation result
    (_, AppEvent (BoardRefreshStarted generation)) -> markBoardRefreshRunning generation
    -- The notice reports the pause once; the status is what outlives it, so
    -- the footer and the completed blocker still say so after the next press
    -- clears the line.
    (_, AppEvent (BoardHistoryPaused resetAt)) -> do
      modify (\current -> current {appCompletedStatus = CompletedHistoryPaused resetAt})
      setNotice (historyPausedNotice state.appTimeZone resetAt)
    (_, AppEvent (BoardHistoryUpdated generation historyOutcome)) -> applyBoardHistory generation historyOutcome
    (_, AppEvent (BoardRefreshShutdownFinished verdict)) -> completeDashboardQuit verdict
    (_, AppEvent (CodexRefreshFinished result)) -> applyCodexRefresh result
    (_, AppEvent (ClaudeRefreshFinished result)) -> applyClaudeRefresh result
    (_, AppEvent (DrainerStatusRefreshed result)) -> applyDrainerStatus result
    (_, AppEvent (DrainerToggleFinished result)) -> applyDrainerToggle result
    (_, AppEvent (ApprovalStatusRefreshed result)) -> applyApprovalStatus result
    (_, AppEvent (ApprovalToggleFinished transition result)) -> applyApprovalToggle transition result
    (_, AppEvent (DirectMergeFinished number result)) -> applyDirectMerge number result
    (_, AppEvent (ReviewBackendStarted result)) -> applyReviewBackendStarted result
    (_, AppEvent (ReviewProtocolEvent reviewEvent)) -> applyReviewEvent reviewEvent
    (_, AppEvent (ReviewAnimationTick issueNumber generation)) -> applySessionTick reviewSessionOps issueNumber generation
    (_, AppEvent (SolveProtocolEvent solveEvent)) -> applySolveEvent solveEvent
    (_, AppEvent (SolveAnimationTick issueNumber generation)) -> applySessionTick solveSessionOps issueNumber generation
    (_, AppEvent SolveBoardRefreshRequested) -> startBoardRefresh
    (_, AppEvent (PullRequestProtocolEvent flowEvent)) -> applyPullRequestFlowEvent flowEvent
    (_, AppEvent (PullRequestAnimationTick number generation)) -> applySessionTick pullRequestSessionOps number generation
    (_, AppEvent (WorkerRegistered descriptor)) -> registerWorker descriptor
    (_, AppEvent (WorkerProtocolEvent descriptor workerEvent)) -> applyWorkerProtocolEvent descriptor workerEvent
    (_, AppEvent (WorkerDiscoveryFinished descriptors)) -> mapM_ attachDiscoveredWorker descriptors
    (_, AppEvent (CanonicalIssueReviewProcessStarted issueNumber process)) -> do
      modify (\current -> current {appCanonicalReviewProcesses = Map.insert issueNumber process current.appCanonicalReviewProcesses})
      modifyReviewSession issueNumber (\session -> session {sessionActivity = "reviewing issue"})
      armReviewTick issueNumber
    (_, AppEvent (CanonicalIssueReviewFinished issueNumber stage result)) -> applyCanonicalIssueReview issueNumber stage result
    -- The help overlay answers nothing of its own, so its scoped bindings can
    -- be resolved before the overlays below, which do.
    (Just HelpOverlay, VtyEvent keyEvent)
      | Just action <- boardAction HelpScope keyEvent -> applyBoardAction action
    (Just SettingsOverlay, VtyEvent (Vty.EvKey (Vty.KChar '1') [])) -> chooseChatVerbosity CompactChat
    (Just SettingsOverlay, VtyEvent (Vty.EvKey (Vty.KChar '2') [])) -> chooseChatVerbosity StandardChat
    (Just SettingsOverlay, VtyEvent (Vty.EvKey (Vty.KChar '3') [])) -> chooseChatVerbosity FullChat
    (Just SettingsOverlay, VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just SettingsOverlay, _) -> pure ()
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey Vty.KDown [])) -> moveProcessSelection 1
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey (Vty.KChar 'j') [])) -> moveProcessSelection 1
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey Vty.KUp [])) -> moveProcessSelection (-1)
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey (Vty.KChar 'k') [])) -> moveProcessSelection (-1)
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey Vty.KEnter [])) -> openSelectedAgentSession
    (Just ProcessesOverlay, VtyEvent (Vty.EvKey (Vty.KChar 'x') [])) -> killSelectedAgentSession
    (Just ProcessesOverlay, MouseDown ProcessesPanel Vty.BScrollUp _ _) -> scrollProcesses (-3)
    (Just ProcessesOverlay, MouseDown ProcessesPanel Vty.BScrollDown _ _) -> scrollProcesses 3
    (Just ProcessesOverlay, MouseDown (ProcessTarget ref) Vty.BLeft _ _) -> selectOrOpenAgentSession ref
    (Just ProcessesOverlay, MouseDown ProcessesPanel _ _ _) -> pure ()
    (Just ProcessesOverlay, _) -> pure ()
    (overlay, incidentEvent)
      | Just action <- incidentsAction overlay incidentEvent -> handleIncidentsAction action
    (Just (ReviewOverlay _), VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just (ReviewOverlay issueNumber), mouseEvent)
      | Just action <- overlayMouseAction ReviewPanel mouseEvent -> applyOverlayMouseAction (scrollTranscript (ReviewTranscript issueNumber)) action
    (Just (ReviewOverlay issueNumber), reviewInputEvent) ->
      handleSessionOverlayEvent reviewSessionOps reviewInputHooks issueNumber reviewInputEvent
    (Just (SolveChooser workflow issue), VtyEvent (Vty.EvKey (Vty.KChar '1') [])) -> startIssueSolve issue workflow CodexSolver
    (Just (SolveChooser workflow issue), VtyEvent (Vty.EvKey (Vty.KChar '2') [])) -> startIssueSolve issue workflow ClaudeSolver
    (Just (SolveChooser _ _), VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just (SolveChooser _ _), _) -> pure ()
    (Just (SolveOverlay _), VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just (SolveOverlay issueNumber), mouseEvent)
      | Just action <- overlayMouseAction SolvePanel mouseEvent -> applyOverlayMouseAction (scrollTranscript (SolveTranscript issueNumber)) action
    (Just (SolveOverlay issueNumber), solveInputEvent) ->
      handleSessionOverlayEvent solveSessionOps solveInputHooks issueNumber solveInputEvent
    (Just (PullRequestReviewOverlay _), VtyEvent (Vty.EvKey Vty.KEsc [])) -> closeOverlay
    (Just (PullRequestReviewOverlay number), mouseEvent)
      | Just action <- overlayMouseAction PullRequestReviewPanel mouseEvent -> applyOverlayMouseAction (scrollTranscript (PullRequestTranscript number)) action
    (Just (PullRequestReviewOverlay number), inputEvent) ->
      handleSessionOverlayEvent pullRequestSessionOps pullRequestInputHooks number inputEvent
    (Just (DetailsOverlay _), VtyEvent keyEvent)
      | Just action <- boardAction DetailsScope keyEvent -> applyBoardAction action
    (Just (DetailsOverlay _), mouseEvent)
      | Just action <- overlayMouseAction DetailsPanel mouseEvent -> applyOverlayMouseAction scrollDetails action
    -- What is left for an overlay that answered none of the above. Esc is the
    -- fallback for one that neither handles it itself nor appears as a
    -- 'BindingScope'; the scrolling keys are live for the help and details
    -- overlays, which the table deliberately does not claim @j@ and @k@ in.
    (Just _, VtyEvent (Vty.EvKey Vty.KEsc [])) -> modify (\current -> current {appOverlay = Nothing, appNotice = Nothing})
    (Just _, VtyEvent (Vty.EvKey Vty.KDown [])) -> vScrollBy (viewportScroll DetailsViewport) 1
    (Just _, VtyEvent (Vty.EvKey (Vty.KChar 'j') [])) -> vScrollBy (viewportScroll DetailsViewport) 1
    (Just _, VtyEvent (Vty.EvKey Vty.KUp [])) -> vScrollBy (viewportScroll DetailsViewport) (-1)
    (Just _, VtyEvent (Vty.EvKey (Vty.KChar 'k') [])) -> vScrollBy (viewportScroll DetailsViewport) (-1)
    (Just _, _) -> pure ()
    -- A focused filter panel and a live search each decode the base board's
    -- key presses ahead of the table, so a printable key edits a checkbox or
    -- types into the query instead of firing the binding that letter
    -- ordinarily carries. The panel outranks the search because focus moves
    -- between the two explicitly -- `s` yields it and `f` takes it back --
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
  | RefreshAllFromClick
  | ToggleFilterBoxFromClick FilterBox
  | ToggleEpicFromClick BoardColumn Int Int
  | SelectOrOpenCardAt BoardColumn Int
  | OpenRunningProcessAt BoardColumn Int
  | ScrollColumnBy BoardColumn Int
  deriving stock (Eq, Show)

-- | The press's meaning, or 'Nothing' when the board claims nothing for it.
--
-- A live search outranks every column press: a left or right press aimed at
-- any column but the searched one moves the search there and does nothing
-- else, wherever in that column it landed. It does not outrank the two sidebar
-- controls or a filter checkbox, none of which is a column target at all and
-- all of which are answered first, and it claims neither the wheel — which
-- retargets nothing, so it keeps scrolling whatever is under the pointer — nor
-- the middle button.
--
-- Both sidebar controls take a plain left press and nothing else. A middle,
-- right, wheel, or modifier-carrying press over one falls through every arm
-- below, which name only column targets, and the board claims nothing for it.
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
  (UpdateButton, Vty.BLeft, []) -> Just RefreshAllFromClick
  (FilterBoxTarget box, Vty.BLeft, _) -> Just (ToggleFilterBoxFromClick box)
  _ | completedCardsBlocked state -> Nothing
  _ | Just column <- searchMouseTransfer state name button -> Just (TransferSearch column)
  (EpicTarget column _ _, Vty.BScrollUp, _) -> Just (ScrollColumnBy column (-3))
  (EpicTarget column _ _, Vty.BScrollDown, _) -> Just (ScrollColumnBy column 3)
  (EpicTarget column row trackerNumber, Vty.BLeft, _) -> Just (ToggleEpicFromClick column row trackerNumber)
  (CardTarget column row, Vty.BRight, _) -> Just (OpenRunningProcessAt column row)
  (CardTarget column row, Vty.BLeft, _) -> Just (SelectOrOpenCardAt column row)
  (CardTarget column _, Vty.BScrollUp, _) -> Just (ScrollColumnBy column (-3))
  (CardTarget column _, Vty.BScrollDown, _) -> Just (ScrollColumnBy column 3)
  (ColumnViewport column, Vty.BScrollUp, _) -> Just (ScrollColumnBy column (-3))
  (ColumnViewport column, Vty.BScrollDown, _) -> Just (ScrollColumnBy column 3)
  _ -> Nothing

-- | What one decided press does to the dashboard. Total in
-- 'BoardMouseAction', so a press cannot be given a meaning above without its
-- effect being decided here — and pure, so the effect a press has can be
-- taken and inspected without a terminal, a viewport, or a subprocess.
boardMousePress :: BoardMouseAction -> AppState -> AppState
boardMousePress = \case
  TransferSearch column -> transferSearchTo column
  ToggleDrainerFromClick -> fst . drainerTogglePress
  -- The update is not a state transition of its own. Every mark it leaves —
  -- the loading freshness, the notice, the coalesced follow-up — is made by
  -- the same 'startAllRefreshes' the key reaches, which is where a press made
  -- during a cycle in flight is decided.
  RefreshAllFromClick -> id
  ToggleFilterBoxFromClick box -> toggleFilterBoxFromClick box
  ToggleEpicFromClick column row trackerNumber -> toggleTrackerState column row trackerNumber
  SelectOrOpenCardAt column row -> applyCardClick column row
  OpenRunningProcessAt column row -> applyRunningProcessClick column row
  -- Scrolling a viewport is not a state change; all the state carries is that
  -- this frame must not drag the selection back into view.
  ScrollColumnBy _ _ -> \state -> state {appEnsureSelectionVisible = False}

-- | Carries out one decided press: its effect on the state, and then the
-- four things that are not state — the viewport scroll, the controller
-- handoff a drainer press makes, the update an update press starts, and the
-- transcript a newly opened session overlay has to be shown the tail of.
applyBoardMouseAction :: BoardMouseAction -> EventM Name AppState ()
applyBoardMouseAction action = do
  before <- get
  modify (boardMousePress action)
  case action of
    ScrollColumnBy column amount -> vScrollBy (viewportScroll (ColumnViewport column)) amount
    ToggleDrainerFromClick -> runDrainerToggleHandoff before
    -- The key's own dispatch, not a second call to whatever it happens to
    -- reach today, so the click cannot acquire a refresh path of its own.
    RefreshAllFromClick -> applyBoardAction RefreshAll
    OpenRunningProcessAt _ _ -> do
      after <- get
      when (after.appOverlay /= before.appOverlay) $ do
        presentTranscriptTail
        armVisibleReviewTicks
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
  if completedCardsBlocked state && blockedByCompletedLoad action
    then pure ()
    else case readOnlyHistoryGate state action of
      Just notice -> setNotice notice
      Nothing -> dispatchBoardAction action

-- | Which bindings the completed-history blocker makes inert.
--
-- Everything that reaches a card does: the blocker draws none, so a press that
-- moved, opened, or acted on one would be resolving a selection left over from
-- the frame before it. Nothing else is touched — the filter panel that put the
-- blocker up, the footer, help, options, refresh, the drainer, the sidebar,
-- @Esc@, @q@, and @Ctrl-C@ all stay exactly as usable as they were.
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
  ReviewSelection -> True
  SolveSelection -> True
  AutoSolveSelection -> True
  MergeDoneCard -> True
  KillWorking -> True
  ShowFilter -> False
  DismissOrClose -> False
  ShowProcesses -> False
  ShowIncidents -> False
  RefreshAll -> False
  ToggleDrainer -> False
  ToggleSidebar -> False
  ShowSettings -> False
  ShowHelp -> False
  RepaintTerminal -> False
  QuitDashboard -> False

-- | Whether the card in front of the user puts this action out of reach, and
-- what to say instead.
--
-- One decision covering every mutating binding, taken before any of them
-- resolves a target, so a completed card refuses ahead of the wrong-kind,
-- approval, drainer-state, structural, reusable-session and process-presence
-- errors each arm would otherwise report. Each arm re-asks it at its own
-- launch or termination boundary, which is what a chooser, an overlay, or a
-- session opened before a refresh needs; this is what makes the key press
-- itself refuse.
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
      _ -> selectedReviewItem state

-- | Which bindings act on the work a card stands for rather than only reading
-- it or moving around it.
--
-- Total in 'BoardAction' on purpose: a binding added to the table in
-- "Kanban.UI.Keys" cannot reach the board without a decision here about
-- whether settled history is allowed to reach it.
mutatesSelectedWork :: BoardAction -> Bool
mutatesSelectedWork = \case
  ReviewSelection -> True
  SolveSelection -> True
  AutoSolveSelection -> True
  MergeDoneCard -> True
  KillWorking -> True
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
  DismissOrClose -> False
  ShowProcesses -> False
  ShowIncidents -> False
  RefreshAll -> False
  ToggleDrainer -> False
  ToggleSidebar -> False
  ShowSettings -> False
  ShowHelp -> False
  RepaintTerminal -> False
  QuitDashboard -> False

dispatchBoardAction :: BoardAction -> EventM Name AppState ()
dispatchBoardAction = \case
  NextCard -> moveCard 1
  PreviousCard -> moveCard (-1)
  KillWorking -> onSelection killItemWorkingProcess killSelectedWorkingProcess
  PreviousColumn -> moveColumn (-1)
  NextColumn -> moveColumn 1
  FirstItem -> selectBoundary False
  LastItem -> selectBoundary True
  ToggleEpic -> toggleSelectedTracker
  ShowDetails -> openSelectedDetails
  DismissOrClose -> closeOverlay
  ReviewSelection -> onSelection startItemReview startSelectedReview
  SolveSelection -> onSelection (openItemSolveChooser SolveOnly) (openSelectedSolveChooser SolveOnly)
  AutoSolveSelection -> onSelection (openItemSolveChooser AutoSolve) (openSelectedSolveChooser AutoSolve)
  ShowProcesses -> openProcesses
  ShowIncidents -> handleIncidentsAction OpenIncidentsPanel
  RefreshAll -> startAllRefreshes
  ToggleDrainer -> toggleDrainer
  MergeDoneCard -> onSelection mergeItemDoneCard mergeSelectedDoneCard
  ToggleSidebar -> modify (\current -> current {appSidebarVisible = not current.appSidebarVisible})
  ShowSettings -> modify (\current -> current {appOverlay = Just SettingsOverlay, appNotice = Nothing})
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
-- transition and search only ends beneath it, and @f@, which is the filter
-- panel's own transition for the same reason.
handleSearchInput :: SearchInput -> EventM Name AppState ()
handleSearchInput SearchOpenDetails = modify openSearchResult
handleSearchInput SearchFocusFilter = modify focusFilterPanel
handleSearchInput input = modify (applySearchInput input)

-- | The quit key's decision.
--
-- A live interactive review still refuses the quit exactly as it did, and is
-- asked first: it is the one refusal the user can act on. Everything past it
-- is about the @gh@ this dashboard owns. With nothing queued or running there
-- is nothing to stop and the halt is immediate, which is what keeps an
-- ordinary quit instant; otherwise the queued work is cancelled and the
-- running fetch is put through the same verified cleanup a refresh timeout
-- puts it through, and the dashboard stops only once that has reached a
-- verdict.
requestDashboardQuit :: EventM Name AppState ()
requestDashboardQuit = do
  state <- get
  let liveInteractiveReviews =
        liveReviewSessions
          (reviewBackendReady state.appReviewBackend)
          (Map.keysSet state.appCanonicalReviewProcesses)
          state.appReviewSessions
  if not (null liveInteractiveReviews)
    then
      modify
        ( \current ->
            current
              { appOverlay = Nothing,
                appNotice =
                  Just
                    ( "Finish or kill the non-persistent issue review"
                        <> (if length liveInteractiveReviews == 1 then " " else "s ")
                        <> Text.intercalate ", " (map (("#" <>) . showText) liveInteractiveReviews)
                        <> " before quitting; solve and PR workers may be safely left running"
                    )
              }
        )
    else
      if state.appQuitPending
        then setNotice stoppingGitHubWorkNotice
        else do
          mustSettle <- liftIO (coordinatorMustSettle state.appRefreshCoordinator)
          if not mustSettle
            then halt
            else do
              modify (\current -> current {appOverlay = Nothing, appQuitPending = True, appNotice = Just stoppingGitHubWorkNotice})
              void . liftIO . forkIO $
                shutdownRefreshCoordinator state.appRefreshCoordinator
                  >>= writeBChan state.appEventChannel . BoardRefreshShutdownFinished

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
  QuitHeldBack notice -> modify (\current -> current {appQuitPending = False, appNotice = Just notice})

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

overlayMouseAction :: Name -> BrickEvent Name AppEvent -> Maybe OverlayMouseAction
overlayMouseAction panel event = case event of
  MouseDown _ Vty.BScrollUp _ _ -> Just (OverlayMouseScroll (-3))
  MouseDown _ Vty.BScrollDown _ _ -> Just (OverlayMouseScroll 3)
  VtyEvent (Vty.EvMouseDown _ _ Vty.BScrollUp _) -> Just (OverlayMouseScroll (-3))
  VtyEvent (Vty.EvMouseDown _ _ Vty.BScrollDown _) -> Just (OverlayMouseScroll 3)
  MouseDown name Vty.BRight _ _
    | name == panel -> Just OverlayMouseClose
  MouseDown name _ _ _
    | name == panel -> Just OverlayMouseNoOp
  MouseDown _ _ _ _ -> Just OverlayMouseClose
  VtyEvent (Vty.EvMouseDown _ _ _ _) -> Just OverlayMouseClose
  _ -> Nothing

applyOverlayMouseAction :: (Int -> EventM Name AppState ()) -> OverlayMouseAction -> EventM Name AppState ()
applyOverlayMouseAction scrollOverlay = \case
  OverlayMouseScroll amount -> scrollOverlay amount
  OverlayMouseClose -> closeOverlay
  OverlayMouseNoOp -> pure ()

chooseChatVerbosity :: ChatVerbosity -> EventM Name AppState ()
chooseChatVerbosity verbosity = do
  state <- get
  let settings = state.appSettings {settingsChatVerbosity = verbosity}
  result <- liftIO (saveSettings settings)
  case result of
    Left message -> setNotice message
    Right () ->
      modify
        ( \current ->
            current
              { appSettings = settings,
                appNotice = Just ("Chat output set to " <> Text.toLower (verbosityLabel verbosity) <> " · full logs remain unchanged")
              }
        )

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
    state
      { appOverlay = Just IncidentsOverlay,
        appIncidentSelection = resolveIncidentSelection entries state.appIncidentSelection,
        appNotice = Nothing
      }
  CloseIncidentsPanel -> state {appOverlay = Nothing, appNotice = Nothing}
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

    activate Nothing = state {appNotice = Just "No incident is selected"}
    -- Resolved against the visible view: activation moves the selection to a
    -- row, and a row is an index into what the criteria are showing.
    activate (Just reference) = case resolveIncidentActivation state.appVisibleBoard entries reference of
      -- The row went away between the last render and this key press. The
      -- panel stays open with nothing acted on, rather than sending the user
      -- to whichever incident took its place.
      Nothing -> state {appNotice = Just "That incident is no longer listed"}
      Just activation -> applyIncidentActivation activation state

applyIncidentActivation :: IncidentActivation -> AppState -> AppState
applyIncidentActivation activation state =
  selectWork
    state
      { appOverlay = activation.incidentActivationSession >>= sessionOverlayFor,
        appNotice = activation.incidentActivationNotice
      }
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
            appEnsureSelectionVisible = True
          }

sessionOverlayFor :: AgentSessionRef -> Maybe Overlay
sessionOverlayFor (SolveAgent issueNumber) = Just (SolveOverlay issueNumber)
sessionOverlayFor (PullRequestAgent number) = Just (PullRequestReviewOverlay number)
sessionOverlayFor (ReviewAgent issueNumber) = Just (ReviewOverlay issueNumber)
sessionOverlayFor (WorkerAgent _) = Nothing

-- | Dispatches one panel action, adding the two effects the pure transition
-- cannot express: the viewport scroll a wheel event asks for, and settling a
-- session overlay that activation just opened at its live tail.
handleIncidentsAction :: IncidentsAction -> EventM Name AppState ()
handleIncidentsAction action = do
  before <- get
  modify (applyIncidentsAction action)
  case action of
    ScrollIncidentsPanel amount -> vScrollBy (viewportScroll IncidentsViewport) amount
    _ -> pure ()
  after <- get
  when (after.appOverlay /= before.appOverlay) $ case after.appOverlay of
    Just (ReviewOverlay _) -> presentTranscriptTail >> armVisibleReviewTicks
    Just (SolveOverlay _) -> presentTranscriptTail
    Just (PullRequestReviewOverlay _) -> presentTranscriptTail
    _ -> pure ()

openProcesses :: EventM Name AppState ()
openProcesses = do
  state <- get
  let resolved = resolveProcessSelection (agentSessionEntries state) state.appProcessSelection
  modify
    ( \current ->
        current
          { appOverlay = Just ProcessesOverlay,
            appProcessSelection = resolved,
            appNotice = Nothing
          }
    )

moveProcessSelection :: Int -> EventM Name AppState ()
moveProcessSelection amount = do
  state <- get
  let entries = agentSessionEntries state
      resolved = resolveProcessSelection entries state.appProcessSelection
      maximumIndex = max 0 (length entries - 1)
      nextIndex = max 0 (min maximumIndex (resolved.processSelectionRow + amount))
      nextSelection = ProcessSelection (agentSessionRef <$> safeIndex nextIndex entries) nextIndex
  modify (\current -> current {appProcessSelection = nextSelection})

scrollProcesses :: Int -> EventM Name AppState ()
scrollProcesses amount = do
  moveProcessSelection amount
  vScrollBy (viewportScroll ProcessesViewport) amount

selectOrOpenAgentSession :: AgentSessionRef -> EventM Name AppState ()
selectOrOpenAgentSession clickedRef = do
  state <- get
  case resolveProcessClick (agentSessionEntries state) state.appProcessSelection clickedRef of
    ProcessClickIgnored -> pure ()
    ProcessClickOpen -> openSelectedAgentSession
    ProcessClickSelect selection -> modify (\current -> current {appProcessSelection = selection})

openSelectedAgentSession :: EventM Name AppState ()
openSelectedAgentSession = do
  state <- get
  let entries = agentSessionEntries state
      resolved = resolveProcessSelection entries state.appProcessSelection
  modify (\current -> current {appProcessSelection = resolved})
  case safeIndex resolved.processSelectionRow entries of
    Nothing -> setNotice "No agent session is selected"
    Just entry -> case entry.agentSessionRef of
      SolveAgent issueNumber -> do
        modify (\current -> current {appOverlay = Just (SolveOverlay issueNumber), appNotice = Nothing})
        presentTranscriptTail
      PullRequestAgent number -> do
        modify (\current -> current {appOverlay = Just (PullRequestReviewOverlay number), appNotice = Nothing})
        presentTranscriptTail
      ReviewAgent issueNumber -> do
        modify (\current -> current {appOverlay = Just (ReviewOverlay issueNumber), appNotice = Nothing})
        presentTranscriptTail
        armVisibleReviewTicks
      WorkerAgent _ -> setNotice ("This persistent worker is waiting for its issue or PR metadata; press " <> actionKeyText RefreshAll <> " to refresh the board")

killSelectedAgentSession :: EventM Name AppState ()
killSelectedAgentSession = do
  state <- get
  let entries = agentSessionEntries state
      resolved = resolveProcessSelection entries state.appProcessSelection
  modify (\current -> current {appProcessSelection = resolved})
  case safeIndex resolved.processSelectionRow entries of
    Nothing -> setNotice "No agent session is selected"
    Just entry
      -- The processes overlay reaches every kill route without going through
      -- a card, so the read-only-history refusal has to be asked here too, and
      -- ahead of the process-presence answer below: a session left over from
      -- work that has since closed or merged is history, whatever it still
      -- holds open.
      | Just notice <- settledSessionRefusal state entry.agentSessionRef -> setNotice notice
      | not entry.agentSessionLive -> setNotice (entry.agentSessionLabel <> " has no live process to kill")
      | otherwise -> case entry.agentSessionRef of
          SolveAgent issueNumber -> killSolveAgent issueNumber
          PullRequestAgent number -> case Map.lookup number state.appPullRequestReviewSessions of
            Nothing -> setNotice "PR session is no longer available"
            Just session -> killItemWorkingProcess (PullRequestItem session.sessionDetail.pullRequestSessionPullRequest)
          ReviewAgent issueNumber -> killReviewAgent issueNumber
          WorkerAgent identifier -> case Map.lookup identifier state.appWorkers of
            Nothing -> setNotice "Persistent worker is no longer available"
            Just descriptor -> do
              modify
                ( \current ->
                    current
                      { appWorkers = Map.delete identifier current.appWorkers,
                        appWorkerMonitors = Set.delete identifier current.appWorkerMonitors
                      }
                )
              void . liftIO . forkIO $ terminateWorker descriptor
              setNotice ("Killing " <> entry.agentSessionLabel <> " and its process tree…")

-- | Whether one agent session names work the completed generation has
-- settled, and what to say instead of acting on it.
--
-- The processes overlay is keyed by session rather than by card, so this is
-- how a row reaches the same refusal every board and overlay route already
-- asks for. A worker whose descriptor is gone names no work at all, which is
-- the one case there is nothing left to refuse.
settledSessionRefusal :: AppState -> AgentSessionRef -> Maybe Text
settledSessionRefusal state reference =
  agentSessionSubject state reference >>= readOnlyHistoryRefusalFor state

killSolveAgent :: Int -> EventM Name AppState ()
killSolveAgent issueNumber = do
  state <- get
  case (solveWorkerFor state issueNumber, Map.lookup issueNumber state.appSolveProcesses) of
    (Nothing, Nothing) -> setNotice ("Solve #" <> showText issueNumber <> " has no live process to kill")
    (worker, process) -> do
      appendToSolveSession issueNumber
        ( \session ->
            session
              { sessionPhase = SolveKilledPhase,
                sessionActivity = "killing process tree",
                sessionTranscript = appendTranscript session.sessionTranscript "\n[killed by user]\n"
              }
        )
      void . liftIO . forkIO $ case worker of
        Just descriptor -> terminateWorker descriptor
        Nothing -> mapM_ killManagedProcess process
      setNotice ("Killing solve #" <> showText issueNumber <> " and its process tree…")

killReviewAgent :: Int -> EventM Name AppState ()
killReviewAgent issueNumber = do
  state <- get
  let canonicalProcess = Map.lookup issueNumber state.appCanonicalReviewProcesses
      activeTurn = do
        session <- Map.lookup issueNumber state.appReviewSessions
        client <- case state.appReviewBackend of
          ReviewBackendReady value -> Just value
          _ -> Nothing
        threadId <- session.sessionDetail.reviewSessionThreadId
        turnId <- session.sessionDetail.reviewSessionTurnId
        if reviewTurnInterruptible session.sessionDetail.reviewSessionStage session.sessionPhase
          then Just (client, threadId, turnId)
          else Nothing
  case (canonicalProcess, activeTurn) of
    (Nothing, Nothing) -> setNotice ("Issue review #" <> showText issueNumber <> " has no live process to kill")
    _ -> do
      appendToReviewSession issueNumber
        ( \session ->
            session
              { sessionPhase = ReviewFailed,
                sessionActivity = "killing process tree",
                sessionTranscript = appendTranscript session.sessionTranscript "\n[killed by user]\n"
              }
        )
      mapM_ (\process -> void . liftIO . forkIO $ killManagedProcess process) canonicalProcess
      case activeTurn of
        Nothing -> pure ()
        Just (client, threadId, turnId) -> do
          void . liftIO . forkIO $ killReviewTools client threadId
          void (liftIO (interruptReview client threadId turnId))
      setNotice ("Killing issue review #" <> showText issueNumber <> " and its process tree…")

killSelectedWorkingProcess :: EventM Name AppState ()
killSelectedWorkingProcess = do
  state <- get
  case selectedReviewItem state of
    Nothing -> setNotice killSelectionNotice
    Just item -> killItemWorkingProcess item

-- | Shown when the kill binding is pressed with nothing killable selected. It
-- has to name that binding itself: @k@ is the select-previous binding, so a
-- reader who obeys a notice naming @k@ moves the selection instead of
-- retrying the kill. Naming it from the table is what keeps the two from
-- disagreeing again.
killSelectionNotice :: Text
killSelectionNotice = "Select a working issue or PR before pressing " <> actionKeyText KillWorking

-- | The termination boundary. Read-only history is refused ahead of the
-- process-presence check, so a settled card reports what it is rather than
-- that it has no live process — and a session left running against work that
-- has since closed is stopped through its own row, not through history.
killItemWorkingProcess :: BoardItem -> EventM Name AppState ()
killItemWorkingProcess item = do
  state <- get
  case readOnlyHistoryRefusal state item of
    Just notice -> setNotice notice
    Nothing -> killLiveItemWorkingProcess item

killLiveItemWorkingProcess :: BoardItem -> EventM Name AppState ()
killLiveItemWorkingProcess (PullRequestItem pullRequest) = do
  state <- get
  let number = pullRequest.pullRequestNumber
  case (pullRequestWorkerFor state number, Map.lookup number state.appPullRequestProcesses) of
    (Nothing, Nothing) -> setNotice ("PR #" <> showText number <> " has no live process to kill")
    (worker, process) -> do
      appendToPullRequestSession number
        ( \session ->
            session
              { sessionPhase = SolveKilledPhase,
                sessionActivity = "killing process tree",
                sessionTranscript = appendTranscript session.sessionTranscript "\n[killed by user]\n"
              }
        )
      void . liftIO . forkIO $ case worker of
        Just descriptor -> terminateWorker descriptor
        Nothing -> mapM_ killManagedProcess process
      setNotice ("Killing PR workflow #" <> showText number <> " and its process tree…")
killLiveItemWorkingProcess (IssueItem issue) = do
  state <- get
  let issueNumber = issue.issueNumber
      solveProcess = Map.lookup issueNumber state.appSolveProcesses
      solveWorker = solveWorkerFor state issueNumber
      canonicalProcess = Map.lookup issueNumber state.appCanonicalReviewProcesses
      reviewSession = Map.lookup issueNumber state.appReviewSessions
      activeReview = reviewSession >>= activeReviewTurn state
  case (solveWorker, solveProcess, canonicalProcess, activeReview) of
    (Nothing, Nothing, Nothing, Nothing) -> setNotice ("Issue #" <> showText issueNumber <> " has no live process to kill")
    _ -> do
      case (solveWorker, solveProcess) of
        (Nothing, Nothing) -> pure ()
        (worker, process) -> do
          appendToSolveSession issueNumber
            ( \session ->
                session
                  { sessionPhase = SolveKilledPhase,
                    sessionActivity = "killing process tree",
                    sessionTranscript = appendTranscript session.sessionTranscript "\n[killed by user]\n"
                  }
            )
          void . liftIO . forkIO $ case worker of
            Just descriptor -> terminateWorker descriptor
            Nothing -> mapM_ killManagedProcess process
      case canonicalProcess of
        Nothing -> pure ()
        Just process -> do
          appendToReviewSession issueNumber
            ( \session ->
                session
                  { sessionPhase = ReviewFailed,
                    sessionActivity = "killing process tree",
                    sessionTranscript = appendTranscript session.sessionTranscript "\n[killed by user]\n"
                  }
            )
          void . liftIO . forkIO $ killManagedProcess process
      reviewInterruption <- case activeReview of
        Nothing -> pure (Right ())
        Just (client, threadId, turnId) -> do
          void . liftIO . forkIO $ killReviewTools client threadId
          liftIO (interruptReview client threadId turnId)
      case reviewInterruption of
        Left message -> setNotice ("Process-tree kill started, but review interruption failed: " <> message)
        Right () -> setNotice ("Killing work for issue #" <> showText issueNumber <> " and its process tree…")
  where
    activeReviewTurn state session
      | reviewSessionActive session,
        ReviewBackendReady client <- state.appReviewBackend,
        Just threadId <- session.sessionDetail.reviewSessionThreadId,
        Just turnId <- session.sessionDetail.reviewSessionTurnId = Just (client, threadId, turnId)
      | otherwise = Nothing

scrollDetails :: Int -> EventM Name AppState ()
scrollDetails = vScrollBy (viewportScroll DetailsViewport)

-- | The kind-specific half of each overlay's key table: what Enter submits,
-- what Ctrl-C interrupts, and -- for the review overlay alone -- what a
-- numbered choice answers. Everything else the three overlays do with a key
-- press is 'handleSessionOverlayEvent'.
solveInputHooks :: SessionInputHooks
solveInputHooks =
  noSessionInputHooks
    { sessionHookSubmit = submitSolveInput,
      sessionHookInterrupt = interruptSolveSession,
      sessionHookSubject = IssueId
    }

pullRequestInputHooks :: SessionInputHooks
pullRequestInputHooks =
  noSessionInputHooks
    { sessionHookSubmit = submitPullRequestInput,
      sessionHookInterrupt = interruptPullRequestSession,
      sessionHookSubject = PullRequestId
    }

reviewInputHooks :: SessionInputHooks
reviewInputHooks =
  SessionInputHooks
    { sessionHookSubmit = submitReviewInput,
      sessionHookInterrupt = cancelReviewSession,
      sessionHookChoice = chooseReviewOption,
      sessionHookSubject = IssueId
    }

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
            (state {appOverlay = Just (DetailsOverlay (entryItem entry)), appNotice = Nothing})
        Nothing -> state
  | otherwise = selectCardOnly column row state

-- | What a right click on a board card does: select it, and open its live
-- session's overlay if it has one. Opening one ends a live search on the
-- identity it opened, the same way Enter and a details click do.
applyRunningProcessClick :: BoardColumn -> Int -> AppState -> AppState
applyRunningProcessClick column row state = case clicked >>= runningProcessOverlay state . entryItem of
  Nothing -> selectedState
  Just overlay -> closeSearchOn (anchorAt state column row) (selectedState {appOverlay = Just overlay})
  where
    clicked = safeIndex row (entriesFor state column)
    selectedState = selectCardOnly column row state

selectCardOnly :: BoardColumn -> Int -> AppState -> AppState
selectCardOnly column row state =
  state
    { appSelectedColumn = column,
      appSelectedRows = Map.insert column row state.appSelectedRows,
      appEnsureSelectionVisible = True,
      appNotice = Nothing
    }

runningProcessOverlay :: AppState -> BoardItem -> Maybe Overlay
runningProcessOverlay state (PullRequestItem pullRequest)
  | Map.member pullRequest.pullRequestNumber state.appPullRequestProcesses || pullRequestWorkerFor state pullRequest.pullRequestNumber /= Nothing =
      Just (PullRequestReviewOverlay pullRequest.pullRequestNumber)
  | otherwise = Nothing
runningProcessOverlay state (IssueItem issue)
  | issueReviewIsActive = Just (ReviewOverlay issueNumber)
  | Map.member issueNumber state.appSolveProcesses || solveWorkerFor state issueNumber /= Nothing = Just (SolveOverlay issueNumber)
  | Just pullRequestNumber <- boundAutoSolvePullRequest,
    Map.member pullRequestNumber state.appPullRequestProcesses =
      Just (PullRequestReviewOverlay pullRequestNumber)
  | otherwise = Nothing
  where
    issueNumber = issue.issueNumber
    issueReviewIsActive =
      Map.member issueNumber state.appCanonicalReviewProcesses
        || maybe False reviewSessionActive (Map.lookup issueNumber state.appReviewSessions)
    boundAutoSolvePullRequest = do
      session <- Map.lookup issueNumber state.appSolveSessions
      progress <- session.sessionDetail.solveSessionAutoProgress
      progress.autoSolvePullRequest
