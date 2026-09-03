module Kanban.UI.Types
  ( AgentSession (..),
    AgentSessionEntry (..),
    AgentSessionRef (..),
    AppEvent (..),
    AppState (..),
    AutoSolveProgress (..),
    AutoSolveStage (..),
    BoardRefreshOutcome (..),
    ChatTranscript (..),
    ColumnSearch (..),
    CompletedGeneration,
    CompletedHistoryStatus (..),
    DirectMergeReport (..),
    DrainerSourceState (..),
    FilterPanel (..),
    IncidentClickOutcome (..),
    IncidentEntry (..),
    IncidentRef (..),
    IncidentSelection (..),
    IncidentSource (..),
    Name (..),
    OpenDataView (..),
    OpenGeneration,
    Overlay (..),
    OverlaySurface (..),
    overlayHonorsFullscreen,
    overlaySurface,
    PendingReviewInteraction (..),
    ProcessClickOutcome (..),
    ProcessSelection (..),
    PullRequestDetail (..),
    PullRequestReviewSession,
    ReviewDetail (..),
    ReviewPhase (..),
    ReviewSession,
    SessionMode (..),
    SolveDetail (..),
    SolvePhase (..),
    SolveSession,
    StartupReport (..),
    openDataView,
    withModelRoster,
    withSessionDetail,
  )
where


import Brick.BChan (BChan )
import Data.IORef (IORef)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import Data.Time (TimeZone, UTCTime )
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
import Kanban.ApprovalService
  ( ApprovalController,
    ApprovalIncident (..),
    ApprovalObservation (..),
    ApprovalResult,
    ApprovalStatus (..),
    ApprovalUnavailable,
  )
import Kanban.Drainer
  ( DirectMergeOutcome,
    DrainerController,
    DrainerIncident (..),
    DrainerObservation (..),
    DrainerStatus (..)
    )
import Kanban.Filter (FilterBox, FilterCriteria)
import Kanban.GitHub
  ( CompletedGeneration,
    GhCleanupFailure (..),
    GitHubResult (..),
    HistoryOutcome (..),
    HistoryTraversal,
    OpenGeneration,
    RefreshCoordinator
    )
import Kanban.Process (ManagedProcess )
import Kanban.Provider (ProviderError (..) )
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    PullRequestFlowEvent (..),
    PullRequestOrigin (..)
    )
import Kanban.Review
  ( ReviewApproval (..),
    ReviewQuestion (..),
    ReviewRequestId,
    ReviewStage (..),
    ReviewThreadId
    )
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveEvent (..),
    SolveWorkflow (..),
    SolverBrand (..)
    )
import Kanban.Models (ModelRoster, OperatingMode, ProviderName, RecordedAssignment, RoleName, RosterLoadError, loadedOperatingMode)
import Kanban.UI.Notice (NoticeState)
import Kanban.Settings
  ( Settings (..)
    )
import Kanban.Worker
  ( WorkerDescriptor (..),
    WorkerEvent (..),
    WorkerId
    )

data Name
  = BoardViewport
  | ColumnViewport BoardColumn
  | DetailsViewport
  | ReviewViewport
  | SolveViewport
  | PullRequestReviewViewport
  | ProcessesViewport
  | IncidentsViewport
  | SettingsViewport
  | CardTarget BoardColumn Int
  | EpicTarget BoardColumn Int Int
  | -- | One checkbox of the card filter panel. Named by the box rather than
    -- by a row and column, so a click resolves to the value it was drawn for
    -- however the chips wrapped at the current width.
    FilterBoxTarget FilterBox
  | DetailsPanel
  | ReviewPanel
  | SolvePanel
  | PullRequestReviewPanel
  | ProcessesPanel
  | ProcessTarget AgentSessionRef
  | IncidentsPanel
  | IncidentTarget IncidentRef
  | SettingsPanel
  | -- | One roster assignment of the settings overlay. Named by the
    -- @(role, provider)@ cell it was drawn for rather than by a row index,
    -- for the reason 'FilterBoxTarget' is: a click then resolves to the
    -- assignment under the pointer however the list happened to be scrolled.
    SettingsRosterTarget RoleName ProviderName
  | DrainerButton
  | -- | The usage sidebar's issue approval service control, drawn directly
    -- above 'DrainerButton'. Its own name rather than a shared service
    -- target, for the reason "Kanban.UI.Approval" keeps the two lifecycles
    -- apart: one name would be one place a press meant for either service
    -- could reach the other.
    ApprovalButton
  | -- | The usage sidebar's update control. Registered only while the
    -- sidebar is drawn, so a collapsed sidebar leaves no extent for a press
    -- to land on and the control is unclickable exactly when it is invisible.
    UpdateButton
  deriving stock (Eq, Ord, Show)

data Overlay
  = HelpOverlay
  | SettingsOverlay
  | ProcessesOverlay
  | IncidentsOverlay
  | DetailsOverlay BoardItem
  | ReviewOverlay Int
  | SolveChooser SolveWorkflow Issue
  | SolveOverlay Int
  | PullRequestReviewOverlay Int
  deriving stock (Eq, Show)

-- | Which /surface/ an overlay is, with the subject it happens to be showing
-- dropped.
--
-- The fullscreen flag ('appOverlayFullscreen') is reset when the open overlay
-- is replaced by a genuinely different one and preserved when the same
-- surface is merely re-pointed, which is the distinction 'Overlay' equality
-- cannot draw: @Tab@ moves a session overlay from one session to the next
-- ('Kanban.UI.SessionEvents.cycleSession') and a refresh re-points a details
-- overlay at the same card's newer record ('Kanban.UI.Reconcile.refreshOverlay'),
-- and neither is a new surface for the user. Incidents-Enter jumping straight
-- into a live session is, and resets.
data OverlaySurface
  = HelpSurface
  | SettingsSurface
  | ProcessesSurface
  | IncidentsSurface
  | DetailsSurface
  | ReviewSurface
  | SolveChooserSurface
  | SolveSurface
  | PullRequestReviewSurface
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The surface one overlay is. Total in 'Overlay' so an overlay added later
-- cannot reach the screen without a decision about which surface it is, and
-- therefore about what a transition into it does to fullscreen.
overlaySurface :: Overlay -> OverlaySurface
overlaySurface = \case
  HelpOverlay -> HelpSurface
  SettingsOverlay -> SettingsSurface
  ProcessesOverlay -> ProcessesSurface
  IncidentsOverlay -> IncidentsSurface
  DetailsOverlay _ -> DetailsSurface
  ReviewOverlay _ -> ReviewSurface
  SolveChooser _ _ -> SolveChooserSurface
  SolveOverlay _ -> SolveSurface
  PullRequestReviewOverlay _ -> PullRequestReviewSurface

-- | Whether this overlay honors the fullscreen toggle at all.
--
-- Every surface except the Codex\/Claude solve chooser, which is a 42x10
-- box holding two rows and gains nothing from the screen
-- (@docs\/overlay_focus_fullscreen_design.md@ D-4). Total in
-- 'OverlaySurface' for the same reason 'overlaySurface' is total in
-- 'Overlay'.
overlayHonorsFullscreen :: Overlay -> Bool
overlayHonorsFullscreen overlay = case overlaySurface overlay of
  SolveChooserSurface -> False
  HelpSurface -> True
  SettingsSurface -> True
  ProcessesSurface -> True
  IncidentsSurface -> True
  DetailsSurface -> True
  ReviewSurface -> True
  SolveSurface -> True
  PullRequestReviewSurface -> True

data SolvePhase
  = SolveStarting
  | SolveRunning
  | SolveInterrupting
  | SolveAttention
  | SolveFinished
  | SolveFailedPhase
  | SolveKilledPhase
  | SolveOrphanedPhase
  deriving stock (Eq, Show)

data AutoSolveStage
  = AutoImplementing
  | AutoDiscoveringPullRequest
  | AutoReviewing
  | AutoRevising
  | AutoAwaitingRereview
  | AutoSolveComplete
  | AutoSolveStopped
  deriving stock (Eq, Show)

data AutoSolveProgress = AutoSolveProgress
  { autoSolveStage :: AutoSolveStage,
    autoSolvePullRequest :: Maybe Int,
    autoSolveReviewRound :: Int,
    autoSolveKnownPullRequests :: Set Int,
    autoSolveStartedAt :: UTCTime
  }
  deriving stock (Eq, Show)

data ChatTranscript = ChatTranscript
  { compactTranscript :: Text,
    standardTranscript :: Text,
    fullTranscript :: Text
  }
  deriving stock (Eq, Show)

-- | Which of a session overlay's two input modes the session is in.
--
-- Normal is where a plain letter is a command — scrolling the transcript,
-- closing the overlay, entering insert — and insert is where it is text for
-- the agent. The value is per /session/ rather than per overlay, so @Tab@
-- shows the next session in whatever mode that session was left in, beside
-- the draft the mode governs (docs\/design.md section 7).
data SessionMode
  = SessionNormal
  | SessionInsert
  deriving stock (Eq, Show)

-- | One agent session, whatever kind of agent it runs.
--
-- Everything above 'sessionDetail' is the shared core the three kinds used to
-- keep three hand-maintained copies of, and is where every behavior that is
-- not genuinely kind-specific now lives exactly once: status presentation,
-- transcript growth and follow state, input editing, the animation tick
-- chain, and the base overlay dispatch (issue #51). Only 'sessionDetail'
-- differs by kind, and only the hooks that read it may differ with it.
data AgentSession phase detail = AgentSession
  { sessionPhase :: phase,
    sessionActivity :: Text,
    -- | When 'sessionActivity' began, for the elapsed suffix the solve and
    -- pull-request presentations put beside it. 'Nothing' for a kind that
    -- shows no elapsed time -- which is what keeps this shared field from
    -- introducing one where there was none.
    sessionActivityStartedAt :: Maybe UTCTime,
    -- | The provider's full JSONL log, once the agent reports opening one.
    -- 'Nothing' for a kind that has no such log of its own.
    sessionLogPath :: Maybe FilePath,
    sessionTranscript :: ChatTranscript,
    sessionInput :: Text,
    -- | Whether a printable key edits 'sessionInput' or acts as a normal-mode
    -- command. Every session opens in 'SessionNormal'. A session with nothing
    -- left to read typed text behaves as normal whatever this holds, so a
    -- phase settling underneath an insert-mode session cannot strand it in a
    -- mode its overlay no longer honours -- see
    -- 'Kanban.UI.SessionCore.liveSessionMode'.
    sessionMode :: SessionMode,
    sessionSpinnerFrame :: Int,
    -- | Identifies the current tick chain. A fired tick only advances the
    -- frame and reschedules itself when it still carries this generation;
    -- bumped only when a new chain is actually armed (see
    -- 'Kanban.UI.SessionCore.decideSessionTickArm'), never on every trigger,
    -- so concurrent triggers for the same running turn coalesce onto one
    -- chain.
    sessionTickGeneration :: Int,
    -- | Whether a tick chain is currently in flight for
    -- 'sessionTickGeneration', so a repeated trigger (e.g. an answered
    -- question followed by the backend's matching turn notification) is
    -- absorbed instead of arming a second chain.
    sessionTickArmed :: Bool,
    -- | See 'TranscriptSession': whether this transcript still follows the
    -- live tail, or the user has scrolled back into it and must be left
    -- where they are.
    sessionFollowing :: Bool,
    sessionDetail :: detail
  }
  deriving stock (Eq, Show)

-- | Update the kind-specific half of a session, leaving the shared core
-- alone. The core is updated with ordinary record syntax, which works
-- uniformly across all three kinds precisely because they share this type.
withSessionDetail :: (detail -> detail) -> AgentSession phase detail -> AgentSession phase detail
withSessionDetail update session = session {sessionDetail = update session.sessionDetail}

type SolveSession = AgentSession SolvePhase SolveDetail

data SolveDetail = SolveDetail
  { solveSessionIssue :: Issue,
    solveSessionWorkflow :: SolveWorkflow,
    solveSessionBrand :: SolverBrand,
    solveSessionId :: Maybe Text,
    solveSessionAutoProgress :: Maybe AutoSolveProgress,
    -- | Why the session last entered 'SolveAttention', so 'submitSolveInput'
    -- can tell a real answer to a 'KANBAN_NEEDS_INPUT' question apart from
    -- guidance typed after an interrupt -- both land in the same phase and
    -- are submitted through the same key -- and frame the resumed prompt
    -- accordingly. Meaningless while not in 'SolveAttention'.
    solveSessionResumeProvenance :: ResumeProvenance,
    -- | The model assignment this session's last worker recorded, which
    -- every later launch for the same provider session replays rather than
    -- resolving again (D-7). 'Nothing' before the first launch of a fresh
    -- session, and on a session recovered from a worker specification
    -- written before the field existed; either way the next launch resolves
    -- once and records the result here.
    solveSessionAssignment :: Maybe RecordedAssignment
  }
  deriving stock (Eq, Show)

type PullRequestReviewSession = AgentSession SolvePhase PullRequestDetail

data PullRequestDetail = PullRequestDetail
  { pullRequestSessionPullRequest :: PullRequest,
    pullRequestSessionOrigin :: PullRequestOrigin,
    pullRequestSessionAction :: PullRequestAction,
    -- | The PR's @updatedAt@ when this action was launched, so a finished
    -- session with the same recomputed action (e.g. a second
    -- reviewed:changes verdict after pr-revise's own rereview) can be told
    -- apart from one still addressing the state it was launched for.
    pullRequestSessionLaunchedForUpdatedAt :: UTCTime,
    pullRequestSessionBrand :: SolverBrand,
    pullRequestSessionId :: Maybe Text,
    -- | See 'solveSessionResumeProvenance'; the PR flow's own resume path
    -- has the same answer-vs-interrupt ambiguity.
    pullRequestSessionResumeProvenance :: ResumeProvenance,
    -- | See 'solveSessionAssignment'; both task kinds share one worker
    -- specification and therefore one replay rule.
    pullRequestSessionAssignment :: Maybe RecordedAssignment
  }
  deriving stock (Eq, Show)

data ReviewPhase
  = ReviewStarting
  | ReviewRunning
  | ReviewWaiting
  | ReviewFinished
  | ReviewNeedsChanges
  | ReviewFailed
  | ReviewRevised
  | ReviewInterrupted
  deriving stock (Eq, Show)

data PendingReviewInteraction
  = PendingReviewQuestion ReviewRequestId ReviewQuestion
  | PendingReviewApproval ReviewRequestId ReviewApproval
  deriving stock (Eq, Show)

type ReviewSession = AgentSession ReviewPhase ReviewDetail

data ReviewDetail = ReviewDetail
  { reviewSessionIssue :: Issue,
    reviewSessionStage :: ReviewStage,
    -- | The review thread this session is running on, once the provider has
    -- created one: the connection serving it plus the provider's own id for
    -- it. Both halves are needed, because two connections may name a thread
    -- the same and only the pair says which session an event belongs to.
    reviewSessionThreadId :: Maybe ReviewThreadId,
    reviewSessionTurnId :: Maybe Text,
    reviewSessionPending :: Maybe PendingReviewInteraction,
    -- | Messages the app-server rejected as steers and that could not be
    -- resent automatically, oldest first. Nothing here is ever dropped:
    -- 'applyUndeliveredSteer' only takes the input line when it is free, so a
    -- draft typed after the original send — and a second independently
    -- rejected steer — survives, and 'takeNextUndelivered' hands the queue
    -- back one message at a time as the line frees up (issue #17).
    reviewSessionUndelivered :: [Text],
    -- | The handed-back message currently sitting on the input line, if the
    -- line is holding one rather than a draft the user typed.
    --
    -- Needed because the queue above drains /onto/ the line as soon as the
    -- line is free, so by the time Enter is pressed a recovered steer is no
    -- longer in the queue and is indistinguishable from fresh text. Which of
    -- the two it is decides which durable command the submission becomes — a
    -- deliberate resend of a refused steer, or new feedback (issue #17,
    -- SAG-10 requirement 9) — and the evidence a review leaves should say
    -- which of those happened.
    reviewSessionRestored :: Maybe Text
  }
  deriving stock (Eq, Show)

data AgentSessionRef
  = SolveAgent Int
  | PullRequestAgent Int
  | ReviewAgent Int
  | WorkerAgent WorkerId
  deriving stock (Eq, Ord, Show)

-- | Tracks the processes overlay selection by stable session identity
-- (falling back to a row position only while no entry with that identity
-- is present), so draw and actions always resolve the same target.
data ProcessSelection = ProcessSelection
  { processSelectionRef :: Maybe AgentSessionRef,
    processSelectionRow :: Int
  }
  deriving stock (Eq, Show)

data ProcessClickOutcome
  = ProcessClickSelect ProcessSelection
  | ProcessClickOpen
  | ProcessClickIgnored
  deriving stock (Eq, Show)

data AgentSessionEntry = AgentSessionEntry
  { agentSessionRef :: AgentSessionRef,
    agentSessionLabel :: Text,
    agentSessionProvider :: Text,
    agentSessionStatus :: Text,
    agentSessionActivity :: Text,
    agentSessionId :: Maybe Text,
    agentSessionLive :: Bool,
    agentSessionProblem :: Bool
  }
  deriving stock (Eq, Show)

-- | Which of the incidents panel's sources a row came from. New sources are
-- expected — every automated stage that can stop needing a human is a
-- candidate — so the panel is written against this list rather than against
-- the two members it starts with: a source contributes 'IncidentEntry'
-- values and a label, and nothing else about the panel changes.
data IncidentSource
  = DrainerSource
  | SessionSource
  deriving stock (Eq, Ord, Show)

-- | A row's identity, qualified by the source that minted it, so two sources
-- can never collide on one identifier. Drainer rows carry the service's own
-- incident ID and session rows the existing 'AgentSessionRef'; both survive a
-- refresh that inserts, removes, or reorders rows, which is what keeps a
-- keyboard or mouse action pointed at the incident it was aimed at.
data IncidentRef
  = DrainerIncidentRef Text
  | SessionIncidentRef AgentSessionRef
  deriving stock (Eq, Ord, Show)

-- | One row of the incidents panel: what it concerns, what happened, and
-- where it came from.
--
-- 'incidentEntryWork' is the /authoritative/ board target and is the only
-- thing activation navigates by. An entry with no authoritative target — a
-- supervisor crash, whose @last_pr@ is an inferred diagnostic — is cardless
-- by construction rather than by a check at activation time.
data IncidentEntry = IncidentEntry
  { incidentEntryRef :: IncidentRef,
    incidentEntrySource :: IncidentSource,
    incidentEntryWork :: Maybe ItemId,
    -- | The session overlay activation should open, when Kanban holds one
    -- for this entry. Independent of 'incidentEntryWork': a drainer incident
    -- names work without a session, and a session whose card has been
    -- truncated off the board still has an overlay worth opening.
    incidentEntrySession :: Maybe AgentSessionRef,
    incidentEntrySubject :: Text,
    incidentEntryDetail :: Text,
    -- | Text too long for the row to state, which the panel wraps beneath it
    -- rather than eliding away. Only what an operator has to act on earns
    -- this: a row's own line is the summary, and a continuation line costs
    -- panel height every other entry shares.
    incidentEntryNote :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | Tracks the incidents panel selection by stable source-qualified
-- identity, exactly as 'ProcessSelection' does for the processes overlay.
data IncidentSelection = IncidentSelection
  { incidentSelectionRef :: Maybe IncidentRef,
    incidentSelectionRow :: Int
  }
  deriving stock (Eq, Show)

data IncidentClickOutcome
  = IncidentClickSelect IncidentSelection
  | IncidentClickOpen
  | IncidentClickIgnored
  deriving stock (Eq, Show)

-- | What the drainer source can currently say about itself, kept separate
-- from the answer it gives so that "no incidents" and "no answer" cannot be
-- confused.
--
-- Only 'DrainerSourceReported' is an observation: the controller ran, its
-- response decoded, and it listed exactly these incidents. Everything else
-- means this side does not know, and the panel says so instead of claiming
-- that nothing needs attention.
data DrainerSourceState
  = DrainerSourceChecking
  | DrainerSourceUnavailable Text
  | DrainerSourceReported [DrainerIncident]
  deriving stock (Eq, Show)

-- | How a board refresh ended. 'BoardRefreshUnverified' is not just another
-- failure: the @gh@ process group the refresh spawned could not be confirmed
-- gone, so no second @gh@ may be started alongside one that may still be
-- running. Which guard enforces that depends on 'ghCleanupGuard' — see
-- 'applyBoardRefresh'.
data BoardRefreshOutcome
  = BoardRefreshCompleted (Either ProviderError GitHubResult)
  | BoardRefreshUnverified GhCleanupFailure
  deriving stock (Eq, Show)

-- | What the board body draws.
--
-- Open cards are live-only, so before the first complete generation publishes
-- there is nothing to draw a board from — not a cache, not a partial page set
-- — and the body is a panel instead. Which panel is the same first-load
-- distinction 'Kanban.UI.Reconcile.failureFreshness' already makes: a failure
-- with no complete generation behind it is 'Unavailable', and a failure with
-- one is 'Stale' over a board that stays exactly where it was.
data OpenDataView
  = -- | No generation has completed and none has failed yet.
    OpenDataLoading
  | -- | The first live generation failed, carrying its classified reason.
    OpenDataUnavailable Text
  | -- | A complete generation has published, and its board is what the
    -- columns draw.
    OpenDataBoard
  deriving stock (Eq, Show)

-- | Decided from when the newest complete generation was fetched and how the
-- board's freshness currently reads, and from nothing else.
--
-- A recorded fetch is conclusive: from then on every state — loading, stale,
-- failed — keeps the last complete board (§15), so only the freshness marker
-- and the notice change. With no recorded fetch there is no board to keep,
-- and the freshness says which panel stands in for one.
openDataView :: Maybe UTCTime -> Freshness -> OpenDataView
openDataView (Just _) _ = OpenDataBoard
openDataView Nothing freshness = case freshness of
  NotLoaded -> OpenDataLoading
  Loading -> OpenDataLoading
  -- Neither is reachable with no fetch on record — both are set beside one —
  -- but a board is only ever drawn from a generation this state has seen
  -- complete, so the panel is the honest answer rather than empty columns.
  Fresh _ -> OpenDataLoading
  Stale _ reason -> OpenDataUnavailable reason
  Unavailable reason -> OpenDataUnavailable reason
  Unsupported reason -> OpenDataUnavailable reason

-- | Seat a roster and the operating mode it derives, together.
--
-- The one way 'appModelRoster' moves after startup, so no state can hold a
-- mode its roster does not derive: 'Kanban.UI.Settings.applyRosterWrite'
-- routes a successful save through this, and the dashboard's own startup
-- record is built from 'Kanban.Models.loadedOperatingMode' over the same
-- load. Fixtures use it for the same reason.
withModelRoster :: Either RosterLoadError ModelRoster -> AppState -> AppState
withModelRoster roster state =
  state {appModelRoster = roster, appOperatingMode = loadedOperatingMode roster}

-- | The card filter panel, while it is on screen.
--
-- Presentation state and nothing else: it says which checkbox the panel's own
-- keys act on, never which cards the board is showing. The criteria are
-- 'AppState.appFilterCriteria' and outlive every panel this record stands
-- for, which is what lets @F@ hide the panel without changing the view.
data FilterPanel = FilterPanel
  { filterPanelBox :: FilterBox,
    -- | Whether the panel has handed focus to a live search.
    --
    -- Only meaningful while one is live: the panel takes focus back on its own
    -- when the search ends, so no close path — @s@, @Esc@, a click that opened
    -- details, a transfer, a refresh — has to remember that the panel is
    -- underneath it. 'Kanban.UI.Filter.focusedFilterPanel' is the one reader.
    filterPanelYielded :: Bool
  }
  deriving stock (Eq, Show)

-- | Where the repository's completed generation stands (§15).
--
-- A state rather than a notice: 'appNotice' is cleared by any of two dozen
-- unrelated presses, so a pause reported only there disappears the moment the
-- user moves the selection. The footer, the checkbox counts, and the
-- completed-history blocker all read this instead.
data CompletedHistoryStatus
  = -- | A generation is running, and 'appCompletedProgress' says how far.
    CompletedHistoryLoading
  | -- | Background history yielded the reserve foreground work is held back
    -- for, and resumes no earlier than the instant GitHub reported.
    CompletedHistoryPaused UTCTime
  | -- | A generation published in full, and 'appCompletedHistory' is it.
    CompletedHistoryCurrent
  | -- | A generation failed over a complete history that still stands, which
    -- is what the board keeps showing (§15).
    CompletedHistoryStale Text
  | -- | A generation failed with no complete history behind it, so there is
    -- no settled work to fall back to at all.
    CompletedHistoryFailed Text
  deriving stock (Eq, Show)

data AppEvent
  = -- | One open generation's answer, under the identity that generation was
    -- started with. An outcome older than the newest generation the board has
    -- seen start is discarded rather than applied: the board it would replace
    -- is already the newer one's to publish.
    BoardRefreshFinished OpenGeneration BoardRefreshOutcome
  | -- | The coordinator has taken the owner for a foreground cycle, whoever
    -- asked for it. The board records that a refresh is running so a press
    -- arriving during one it did not start still coalesces rather than
    -- starting a second, and records its identity as the newest generation.
    BoardRefreshStarted OpenGeneration
  | -- | Background history yielded the budget reserved for foreground work,
    -- and resumes no earlier than the moment GitHub reported.
    BoardHistoryPaused UTCTime
  | -- | What one completed page meant, under the generation it answers for.
    -- An outcome older than the newest generation the board has claimed is
    -- discarded, exactly as a superseded open outcome is: the history it
    -- describes is one nobody asked for any more.
    BoardHistoryUpdated CompletedGeneration HistoryOutcome
  | -- | The coordinator finished cancelling everything a quit asked it to,
    -- carrying the cleanup verdict for whatever @gh@ it had running. Whether
    -- the dashboard may actually stop is decided from that verdict, not from
    -- the fact that the cancellation ran.
    BoardRefreshShutdownFinished (Maybe GhCleanupFailure)
  | CodexRefreshFinished (Either ProviderError UsageSnapshot)
  | ClaudeRefreshFinished (Either ProviderError UsageSnapshot)
  | DrainerStatusRefreshed (Either Text DrainerObservation)
  | DrainerToggleFinished (Either Text DrainerObservation)
  | -- | The transition generation current when this poll's controller query
    -- was /issued/, then its result. A poll that began before a toggle press
    -- carries a read taken before it, so it is discarded rather than allowed
    -- to settle a transition it never saw.
    ApprovalStatusRefreshed Int (Either Text ApprovalObservation)
  | -- | The transition generation the completed toggle belongs to, then its
    -- result. A completion whose generation another press has superseded is
    -- discarded rather than applied, so a slow start cannot restore its
    -- optimistic state over the stop that replaced it.
    ApprovalToggleFinished Int (Either Text ApprovalObservation)
  | DirectMergeFinished Int (Either Text DirectMergeOutcome)
  | -- | Session key, then the tick chain's generation. Every kind carries a
    -- generation so a superseded chain's queued tick is dropped rather than
    -- rearming alongside its replacement (issue #30, extended to solve and
    -- pull-request sessions by issue #51).
    ReviewAnimationTick Int Int
  | SolveProtocolEvent SolveEvent
  | SolveAnimationTick Int Int
  | SolveBoardRefreshRequested
  | PullRequestProtocolEvent PullRequestFlowEvent
  | PullRequestAnimationTick Int Int
  | WorkerRegistered WorkerDescriptor
  | -- | The registry refused an issue review or revision this dashboard
    -- asked for. The session the press created is already open, so the
    -- refusal is carried back to settle it rather than left to a launch that
    -- will never happen.
    IssueActionRefused Int Text
  | WorkerProtocolEvent WorkerDescriptor WorkerEvent
  | WorkerDiscoveryFinished [WorkerDescriptor]
  | -- | A displayed notice instance's ten seconds elapsed. It carries the
    -- instance identity the timer was armed for, on the same superseded-
    -- generation reasoning as the animation ticks above: an expiry belonging
    -- to a replaced or dismissed instance — even one whose text a newer
    -- notice repeats — finds a different identity displayed and is dropped
    -- rather than allowed to clear it (issue #590 requirement 5).
    NoticeExpired Int

data AppState = AppState
  { appRepository :: Repository,
    -- | The board derived from the open generation alone.
    --
    -- This is the open-only authority, and the distinction from
    -- 'appVisibleBoard' is load-bearing: the autosolve baseline and worker and
    -- session item resolution read live work whatever the filter criteria say,
    -- so a completed item can never enter a solve, review, or worker decision.
    -- Nothing view-facing reads it — see 'Kanban.UI.Search.entriesFor'.
    appBoard :: Board,
    -- | The board the current 'appFilterCriteria' admit, which is what every
    -- row the user can see is an index into. Under the default criteria it is
    -- 'appBoard' itself.
    --
    -- Kept beside the criteria rather than recomputed per read because a
    -- column's entries are asked for once per card drawn, and re-deriving a
    -- whole repository's history that often would cost more than holding it.
    -- 'Kanban.UI.Filter.refreshVisibleBoard' is the one place it is set.
    appVisibleBoard :: Board,
    -- | Which cards the board is showing, as four independent facets
    -- ("Kanban.Filter"). Process-lifetime state: it starts at
    -- 'Kanban.Filter.defaultFilterCriteria' every launch, survives every
    -- refresh, overlay and dismissal, and is never serialized.
    appFilterCriteria :: FilterCriteria,
    -- | The panel those criteria are edited through, while it is showing.
    -- Hiding it leaves 'appFilterCriteria' exactly as it was, which is what
    -- makes a non-default filter something the footer has to announce.
    appFilterPanel :: Maybe FilterPanel,
    appUsage :: Map UsageProvider UsageSnapshot,
    appUsageFreshness :: Map UsageProvider Freshness,
    appSelectedColumn :: BoardColumn,
    appSelectedRows :: Map BoardColumn Int,
    appEnsureSelectionVisible :: Bool,
    appExpandedTrackers :: Set Int,
    -- | The live column-scoped card search, if one is open. See
    -- "Kanban.UI.Search": every consumer of a column's entries reads the view
    -- this filters, so a row the user can see never dispatches to a different
    -- underlying card.
    appSearch :: Maybe ColumnSearch,
    appSidebarVisible :: Bool,
    appSettings :: Settings,
    -- | The model roster in force, as the typed success-or-error value
    -- 'Kanban.Models.loadModelRoster' produced at startup — and afterwards
    -- whatever the settings overlay last saved, which it moves here only on a
    -- successful 'Kanban.Models.saveModelRoster'
    -- ('Kanban.UI.Settings.applyRosterWrite').
    -- Every agent-starting path unwraps it through
    -- 'Kanban.UI.Util.resolvedRosterCellFor' (MODEL-2): the 'Right' resolves
    -- the cell that run's routing selected, and the 'Left' refuses the spawn
    -- naming the file and the defect (D-3), which is why an unusable file
    -- must stay an error here rather than collapse into the compiled
    -- defaults. A resume of a session that already recorded its assignment
    -- reads neither half (MODEL-7); see 'Kanban.UI.Util.launchAssignment'.
    appModelRoster :: Either RosterLoadError ModelRoster,
    -- | The operating mode the roster beside it derives (D-8): dual for two
    -- loaded providers, single-agent for one, no-agent for none or for a
    -- roster that would not load at all.
    --
    -- Retained rather than derived per read because it is a property of the
    -- roster in force, and 'withModelRoster' is what keeps the pair honest:
    -- the startup load seats both, and the one edit that can move the roster
    -- to a different provider set — @d@ replacing an unusable file with the
    -- compiled defaults — moves both through the same function. A mode that
    -- disagreed with 'appModelRoster' would be a lie on the very screen that
    -- shows it.
    --
    -- Nothing branches on it yet. The settings overlay reads it to draw one
    -- read-only line and nothing else does; the spawn, draw, and
    -- key-visibility decisions keyed on the mode are later slices of epic
    -- #412, which thread it to where they need it.
    appOperatingMode :: OperatingMode,
    -- | Which roster assignment the settings overlay has focused, or
    -- 'Nothing' when it has no row to focus: an unusable roster, or a valid
    -- one that loads no provider. Presentation state like every other
    -- selection here — opening the overlay seats it on the first row, and a
    -- cell the roster stops carrying resolves back to the first row through
    -- 'Kanban.UI.Settings.resolvedSettingsFocus' rather than focusing
    -- nothing.
    appSettingsFocus :: Maybe (RoleName, ProviderName),
    appLogRoot :: FilePath,
    appProcessSelection :: ProcessSelection,
    appIncidentSelection :: IncidentSelection,
    appOverlay :: Maybe Overlay,
    -- | Whether the open overlay is drawn fullscreen rather than in its
    -- windowed box. One flag for whichever overlay is open, never a per-kind
    -- memory: an overlay opens windowed whatever the previous one was
    -- (@docs\/overlay_focus_fullscreen_design.md@ D-1, D-5), which
    -- 'Kanban.UI.State.settleOverlayFullscreen' enforces after every event
    -- rather than at each of the many sites that assign 'appOverlay'.
    appOverlayFullscreen :: Bool,
    -- | The transient footer line, as the abstract lifecycle state
    -- "Kanban.UI.Notice" alone can move: every producer shows a notice
    -- through its transitions, every settled instance expires ten seconds
    -- after it settles, and 'Kanban.UI.Util.settleNoticeLifecycle' — run
    -- after every event — is what classifies the displayed instance against
    -- the tracked operations in 'Kanban.UI.Util.noticeActivityLive'.
    appNotice :: NoticeState,
    appBoardFreshness :: Freshness,
    -- | The newest complete open generation, kept beside the board it derived.
    -- The board alone cannot answer requirement 8: reconciling a completed
    -- generation against the open one means removing items and deriving again,
    -- and a derived board has already folded its items into columns, trackers,
    -- and order. 'Nothing' until the first open generation publishes.
    appOpenSnapshot :: Maybe RepoSnapshot,
    -- | When the newest complete open generation was fetched, and 'Nothing'
    -- until one has published. It is what separates a first load — which
    -- shows §7's centered loading and unavailable panels and no cards at all
    -- — from every refresh after it, which keeps the last complete board.
    appLastSuccessfulFetch :: Maybe UTCTime,
    -- | The newest open generation the coordinator has told this board about.
    -- An outcome arriving under an older identity is discarded.
    appOpenGeneration :: OpenGeneration,
    -- | The repository's completed traversal: the accumulator a history page
    -- resumes from, and the identity every launch and @u@ claims before
    -- queueing one (§15).
    appHistoryTraversal :: HistoryTraversal,
    -- | The newest complete completed generation, reconciled against the open
    -- one, or 'Nothing' when none stands — no cache to seed from and none
    -- fetched yet, which is simply an absent history rather than a failure.
    --
    -- The criteria decide whether any of it reaches the board: with @Closed@
    -- unchecked it is held here and drawn nowhere.
    appCompletedHistory :: Maybe CompletedHistory,
    -- | The newest completed generation the user has asked for. It is claimed
    -- before the history job is queued, so an outcome carrying an older
    -- identity is one the request that superseded it already answered for.
    appCompletedGeneration :: CompletedGeneration,
    -- | How far the completed generation in flight has got, counted separately
    -- for issues and pull requests. Held apart from the open generation's
    -- freshness on purpose: the two run on different schedules, and a history
    -- still loading says nothing about whether the open board is current.
    appCompletedProgress :: CompletedProgress,
    -- | Where the completed generation stands, including why it ended without
    -- completing if it did. It never disturbs 'appCompletedHistory': a failed
    -- generation leaves the last complete one exactly where it was (§15),
    -- which is the difference between 'CompletedHistoryStale' and
    -- 'CompletedHistoryFailed'.
    appCompletedStatus :: CompletedHistoryStatus,
    appDrainerController :: Either Text DrainerController,
    appDrainerStatus :: DrainerStatus,
    -- | The last observed set of open incidents, or 'Nothing' whenever no
    -- successful observation stands: before the first poll answers, after a
    -- query or decode failure, while a start or stop is in flight, and when
    -- the controller reported no such set at all. See 'DrainerSourceState'.
    appDrainerIncidents :: Maybe [DrainerIncident],
    appDrainerBusy :: Bool,
    -- | The issue approval service's controller, or why there is none. An
    -- unsupported host is kept apart from every other failure so nothing
    -- downstream can offer control the host cannot honour (requirement 10).
    appApprovalController :: Either ApprovalUnavailable ApprovalController,
    -- | The approval service's last observation, held apart from
    -- 'appDrainerStatus' so neither service's state can overwrite the other's.
    appApprovalStatus :: ApprovalStatus,
    -- | The last observed set of the approval service's open incidents, or
    -- 'Nothing' whenever no successful observation stands, on the same
    -- reasoning as 'appDrainerIncidents'.
    appApprovalIncidents :: Maybe [ApprovalIncident],
    appApprovalBusy :: Bool,
    -- | Which start or stop of the approval service this dashboard is waiting
    -- on. Bumped by every press, and carried by the handoff, so a completion
    -- can say which transition it belongs to.
    appApprovalTransition :: Int,
    -- | The same count, in a cell the status monitor can read.
    --
    -- The monitor is a plain 'IO' loop with no view of this record, and the
    -- press that bumps 'appApprovalTransition' is a pure transition that
    -- cannot write to one. This is the seam between them: the press's handoff
    -- publishes the new count here, and the monitor stamps each poll with
    -- whatever it reads immediately before issuing that poll's query. That is
    -- what lets a poll say which transition it predates.
    appApprovalEpoch :: IORef Int,
    -- | The result identity the last applied observation carried, which is what
    -- keeps one service result from requiring a board refresh twice. 'Nothing'
    -- until the first observation establishes a baseline.
    appApprovalResult :: Maybe ApprovalResult,
    -- | The pull request a direct @m@ merge is running for, if one is. Held
    -- apart from 'appDrainerStatus', which reports the launchd service and
    -- has nothing to say about a run this dashboard started instead of it.
    appDirectMergePending :: Maybe Int,
    -- | A direct merge that actually landed, held until the board refresh it
    -- requires has run. That result is the only report an irreversible action
    -- gets, and the refresh it triggers would otherwise overwrite it before
    -- it could be read.
    appDirectMergeResult :: Maybe DirectMergeReport,
    -- | The startup line's one-time diagnostics, carried until the first
    -- open outcome publishes. 'Nothing' from birth when startup had nothing
    -- to report, and 'Nothing' for good once the first outcome composes the
    -- diagnostics onto its own notice — or finds them already dismissed.
    -- See 'DirectMergeReport' for why the carrier records the notice
    -- instance it was last shown as.
    appStartupReport :: Maybe StartupReport,
    -- | A board refresh that could not start because a cycle was already in
    -- flight. An in-flight fetch may have read GitHub before a change this
    -- dashboard made landed, so it does not satisfy a request that has to
    -- observe one; and a plain @u@ during a cycle wants the newest state, not
    -- the one already being fetched. Either way the request waits here — one
    -- flag, so any number of presses leave exactly one follow-up — and starts
    -- once the running cycle publishes.
    appBoardRefreshQueued :: Bool,
    -- | The one coordinator that owns every @gh@ a board refresh starts for
    -- this repository, its durable group record, and the order its jobs run
    -- in (§15).
    appRefreshCoordinator :: RefreshCoordinator BoardRefreshOutcome,
    -- | Whether a quit is waiting for the coordinator to finish cancelling
    -- its work. A further quit while this is set reports the wait rather than
    -- commanding a second cancellation.
    appQuitPending :: Bool,
    appReviewSessions :: Map Int ReviewSession,
    -- | Text an issue's review still owes a send, held apart from any one
    -- session: a message a failed interrupt handed back (D-16), or a draft
    -- its user never got to send, belonging to an issue whose current
    -- session cannot send it.
    --
    -- Outside the session because sessions are replaced wholesale and the
    -- replacement is whatever the labels ask for — a revision that publishes
    -- its verdict moves them to a canonical stage, which runs the gate as a
    -- subprocess and has no thread at all. Carried into one of those the text
    -- would look kept while being unreachable; dropped at that press it would
    -- be lost to the one keystroke the user made to carry on. Held here it
    -- survives every stage in between and is handed to the next session that
    -- can actually send it.
    appReviewUndelivered :: Map Int [Text],
    appSolveSessions :: Map Int SolveSession,
    appSolveProcesses :: Map Int ManagedProcess,
    appPullRequestReviewSessions :: Map Int PullRequestReviewSession,
    appPullRequestProcesses :: Map Int ManagedProcess,
    appWorkers :: Map WorkerId WorkerDescriptor,
    appWorkerMonitors :: Set WorkerId,
    appEventChannel :: BChan AppEvent,
    appNow :: UTCTime,
    appTimeZone :: TimeZone,
    appOptions :: Options,
    appConfig :: ResolvedConfig
  }

-- | A live card search over one board column: which column it filters, and
-- the query typed into that column's search box so far.
--
-- Presentation state and nothing else. 'AppState' has no serialization
-- instances, so a query cannot reach the snapshot cache or a board snapshot,
-- and a restart never restores one.
data ColumnSearch = ColumnSearch
  { searchColumn :: BoardColumn,
    searchQuery :: Text
  }
  deriving stock (Eq, Show)

-- | A landed merge's result, together with the identity of the notice
-- instance it was last shown as.
--
-- The second field is what keeps the result from outliving its own report.
-- Some two dozen places clear or replace 'appNotice' -- both Esc handlers,
-- every overlay that opens, every selection move, and now the ten-second
-- expiry -- and each of them means the user has stopped looking at this
-- result. None of them can be asked to remember that a second field exists,
-- and a list of sites that must is a list that will be incomplete again the
-- next time one is added. Comparing against the instance actually put on
-- screen needs no such list -- and unlike the text comparison it replaced,
-- it cannot let a later notice that happens to repeat the same words adopt a
-- retired report, because an instance identity is never reissued.
data DirectMergeReport = DirectMergeReport
  { directMergeReportResult :: Text,
    directMergeReportShownInstance :: Int
  }
  deriving stock (Eq, Show)

-- | The startup diagnostics — an invalid cache, a settings problem, an
-- authority notice, a degraded roster entry — together with the identity of
-- the notice instance they were last shown as.
--
-- These fragments are reported nowhere else, so they ride the startup line
-- until the first open generation publishes: an event notice arriving during
-- the load composes onto the line rather than replacing it
-- ('Kanban.UI.Util.noticeSetOverStartupReport'), and the first outcome
-- composes them onto its own settled notice for the ordinary ten seconds
-- ('Kanban.UI.Util.startupReportApplied'), which also retires the carry for
-- good. The instance comparison is the same rule 'DirectMergeReport' states:
-- a carry is honoured only while what is on screen is still the instance it
-- last wrote, so a manual dismissal or an unrelated action's replacement
-- retires the diagnostics rather than letting a later publish resurrect them.
data StartupReport = StartupReport
  { startupReportDiagnostics :: Text,
    startupReportShownInstance :: Int
  }
  deriving stock (Eq, Show)
