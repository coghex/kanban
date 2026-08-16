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
    PendingReviewInteraction (..),
    ProcessClickOutcome (..),
    ProcessSelection (..),
    PullRequestDetail (..),
    PullRequestReviewSession,
    ReviewBackend (..),
    ReviewDetail (..),
    ReviewPhase (..),
    ReviewSession,
    SolveDetail (..),
    SolvePhase (..),
    SolveSession,
    openDataView,
    withSessionDetail,
  )
where


import Brick.BChan (BChan )
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import Data.Time (TimeZone, UTCTime )
import Kanban.CLI (Options (..))
import Kanban.Config (ResolvedConfig (..) )
import Kanban.Domain
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
  ( CanonicalIssueReviewResult (..),
    ReviewApproval (..),
    ReviewClient,
    ReviewEvent (..),
    ReviewQuestion (..),
    ReviewRequestId,
    ReviewStage (..)
    )
import Kanban.Solve
  ( ResumeProvenance (..),
    SolveEvent (..),
    SolveWorkflow (..),
    SolverBrand (..)
    )
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
  | DrainerButton
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
    solveSessionResumeProvenance :: ResumeProvenance
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
    pullRequestSessionResumeProvenance :: ResumeProvenance
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
    reviewSessionThreadId :: Maybe Text,
    reviewSessionTurnId :: Maybe Text,
    reviewSessionPending :: Maybe PendingReviewInteraction,
    -- | Messages the app-server rejected as steers and that could not be
    -- resent automatically, oldest first. Nothing here is ever dropped:
    -- 'applyUndeliveredSteer' only takes the input line when it is free, so a
    -- draft typed after the original send — and a second independently
    -- rejected steer — survives, and 'takeNextUndelivered' hands the queue
    -- back one message at a time as the line frees up (issue #17).
    reviewSessionUndelivered :: [Text]
  }
  deriving stock (Eq, Show)

data ReviewBackend
  = ReviewBackendStopped
  | ReviewBackendStarting
  | ReviewBackendReady ReviewClient
  | ReviewBackendFailed Text

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

-- | The card filter panel, while it is on screen.
--
-- Presentation state and nothing else: it says which checkbox the panel's own
-- keys act on, never which cards the board is showing. The criteria are
-- 'AppState.appFilterCriteria' and outlive every panel this record stands
-- for, which is what lets @f@ hide the panel without changing the view.
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
  | DirectMergeFinished Int (Either Text DirectMergeOutcome)
  | ReviewBackendStarted (Either Text ReviewClient)
  | ReviewProtocolEvent ReviewEvent
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
  | WorkerProtocolEvent WorkerDescriptor WorkerEvent
  | WorkerDiscoveryFinished [WorkerDescriptor]
  | CanonicalIssueReviewProcessStarted Int ManagedProcess
  | CanonicalIssueReviewFinished Int ReviewStage (Either Text CanonicalIssueReviewResult)

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
    appLogRoot :: FilePath,
    appProcessSelection :: ProcessSelection,
    appIncidentSelection :: IncidentSelection,
    appOverlay :: Maybe Overlay,
    appNotice :: Maybe Text,
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
    -- | The pull request a direct @m@ merge is running for, if one is. Held
    -- apart from 'appDrainerStatus', which reports the launchd service and
    -- has nothing to say about a run this dashboard started instead of it.
    appDirectMergePending :: Maybe Int,
    -- | A direct merge that actually landed, held until the board refresh it
    -- requires has run. That result is the only report an irreversible action
    -- gets, and the refresh it triggers would otherwise overwrite it before
    -- it could be read.
    appDirectMergeResult :: Maybe DirectMergeReport,
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
    appReviewBackend :: ReviewBackend,
    appReviewSessions :: Map Int ReviewSession,
    appSolveSessions :: Map Int SolveSession,
    appSolveProcesses :: Map Int ManagedProcess,
    appCanonicalReviewProcesses :: Map Int ManagedProcess,
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

-- | A landed merge's result, together with the notice it was last shown as.
--
-- The second field is what keeps the result from outliving its own report.
-- Some two dozen places clear or replace 'appNotice' -- both Esc handlers,
-- every overlay that opens, every selection move -- and each of them means
-- the user has stopped looking at this result. None of them can be asked to
-- remember that a second field exists, and a list of sites that must is a
-- list that will be incomplete again the next time one is added. Comparing
-- against what was actually put on screen needs no such list.
data DirectMergeReport = DirectMergeReport
  { directMergeReportResult :: Text,
    directMergeReportShown :: Text
  }
  deriving stock (Eq, Show)
