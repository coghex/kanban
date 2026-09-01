module Kanban.UI.Session
  ( BoardWorkLocation (..),
    EpicReviewRefusal (..),
    dashboardItemStructure,
    IncidentActivation (..),
    ReviewTarget (..),
    agentSessionEntries,
    agentSessionSubject,
    drainerSourceState,
    incidentEntries,
    incidentSourceLabel,
    incidentsFooterHints,
    itemReviewRefusal,
    liveReviewSessions,
    locateBoardWork,
    processesFooterHints,
    pullRequestSessionReusable,
    pullRequestWorkerFor,
    resolveIncidentActivation,
    resolveIncidentClick,
    resolveIncidentSelection,
    resolveProcessClick,
    resolveProcessSelection,
    reusableSolveSession,
    reviewAgentSessionEntry,
    reviewBackendReady,
    reviewIncidentPhase,
    reviewOverlayVisible,
    reviewSessionActive,
    reviewSessionInputLive,
    reviewSessionLive,
    reviewSessionMode,
    reviewSessionReusable,
    reviewTurnInterruptible,
    selectedReviewIssue,
    selectedReviewItem,
    selectedReviewTarget,
    sessionAlreadyResolved,
    solveIncidentPhase,
    solvePhaseActive,
    solveSessionInputLive,
    solveSessionMode,
    solveProcessStatus,
    solveWorkerFor,
  )
where


import Data.List (find, findIndex, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, diffUTCTime )
import Kanban.Action
  ( StructuralRefusal (..),
    TargetStructure (..),
    TrackerChildren (..),
    WorkflowActionKind (..),
    structuralActionRefusal,
  )
import Kanban.Card (middleExcerpt)
import Kanban.Domain
import Kanban.Drainer
  ( DrainerIncident (..),
    DrainerState (..),
    DrainerStatus (..),
    cleanupIncidentKind,
    crashIncidentKind
    )
import Kanban.PullRequestFlow
  ( PullRequestAction (..),
    agentForAction
    )
import Kanban.Review
  ( ReviewStage (..),
    ReviewThreadId (..)
    )
import Kanban.Solve
  ( SolveWorkflow (..),
    solveAssignment
  )
import Kanban.Text (sanitizeText)
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerSpec (..),
    WorkerTask (..)
    )
import Kanban.UI.Keys (BoardAction (..), binding, footerHint)
import Kanban.UI.SessionCore (liveSessionMode)
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.Selection

-- | The single "is this review session live?" decision, shared by the
-- processes-overlay rows ('reviewAgentSessionEntry'), the @x@ gate that
-- dispatches on them ('killSelectedAgentSession'), and the dashboard quit
-- guard ('liveReviewSessions'). Live means /currently killable/: the
-- session has a kill target 'killReviewAgent' can actually act on, so the
-- overlay never reports a row live that the kill would then refuse, and @q@
-- is never refused for a session nothing can stop (issue #151).
--
-- 'reviewPhaseActive' still expresses phase semantics elsewhere in the UI,
-- but it is not this decision. A canonical stage is inserted before its
-- process is registered, and an 'IssueRevision' session is phase-active
-- before its backend is ready and before it has both IDs; in those startup
-- intervals there is no kill target, so the session is not live and does
-- not block quitting.
reviewSessionLive :: Bool -> Bool -> ReviewSession -> Bool
reviewSessionLive backendReady hasCanonicalProcess session =
  hasCanonicalProcess || hasInterruptibleTurn
  where
    hasInterruptibleTurn =
      backendReady
        && isJust session.sessionDetail.reviewSessionThreadId
        && isJust session.sessionDetail.reviewSessionTurnId
        && reviewTurnInterruptible session.sessionDetail.reviewSessionStage session.sessionPhase

-- | The stage/phase half of "has an interruptible turn", shared with
-- 'killReviewAgent' so the liveness gate and the kill it dispatches to
-- cannot drift apart. Only an 'IssueRevision' session runs on the shared
-- review backend ('startIssueReview' sends every other stage down the
-- canonical subprocess path), and only a phase-active one still owns a turn
-- that backend can interrupt: 'killReviewAgent' leaves a killed session
-- 'ReviewFailed' with its turn ID intact until the turn-completion handler
-- clears it, so without the phase condition a just-killed session would
-- stay live and keep refusing @q@.
reviewTurnInterruptible :: ReviewStage -> ReviewPhase -> Bool
reviewTurnInterruptible stage phase = stage == IssueRevision && reviewPhaseActive phase

reviewBackendReady :: ReviewBackend -> Bool
reviewBackendReady backend = case backend of
  ReviewBackendReady _ -> True
  _ -> False

-- | One processes-overlay row for a review session. Split out of
-- 'agentSessionEntries' so the row a user actually sees -- in particular
-- its liveness, which the @x@ gate dispatches on -- is decided by the
-- shared 'reviewSessionLive' and is testable without an 'AppState'.
reviewAgentSessionEntry :: Bool -> Bool -> Int -> ReviewSession -> AgentSessionEntry
reviewAgentSessionEntry backendReady hasCanonicalProcess issueNumber session =
  AgentSessionEntry
    { agentSessionRef = ReviewAgent issueNumber,
      agentSessionLabel = "issue " <> Text.toLower (reviewStageLabel session.sessionDetail.reviewSessionStage) <> " #" <> showText issueNumber,
      agentSessionProvider = reviewProvider session.sessionDetail.reviewSessionStage,
      agentSessionStatus = reviewProcessStatus session.sessionPhase,
      agentSessionActivity = session.sessionActivity,
      -- The provider's own thread id, not the connection-qualified pair: it
      -- is what the provider's own logs and the transcript name, so
      -- qualifying it here would move what every review row displays.
      agentSessionId = shortSessionId . (.reviewThreadProvider) <$> session.sessionDetail.reviewSessionThreadId,
      agentSessionLive = reviewSessionLive backendReady hasCanonicalProcess session,
      agentSessionProblem = session.sessionPhase == ReviewFailed
    }

agentSessionEntries :: AppState -> [AgentSessionEntry]
agentSessionEntries state = sortOn sortKey (solveEntries <> pullRequestEntries <> reviewEntries <> unattachedWorkerEntries)
  where
    sortKey entry = (not entry.agentSessionLive, entry.agentSessionLabel)
    solveEntries =
      [ AgentSessionEntry
          { agentSessionRef = SolveAgent issueNumber,
            agentSessionLabel = Text.toLower (workflowTitle session.sessionDetail.solveSessionWorkflow) <> " #" <> showText issueNumber,
            agentSessionProvider = solveSessionLabel state.appModelRoster session,
            agentSessionStatus = persistentProcessStatus state.appNow worker (solveProcessStatus session.sessionPhase),
            agentSessionActivity = timedActivity state.appNow isLive session.sessionActivityStartedAt session.sessionActivity,
            agentSessionId = shortSessionId <$> session.sessionDetail.solveSessionId,
            agentSessionLive = isLive,
            agentSessionProblem = session.sessionPhase `elem` [SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
          }
        | (issueNumber, session) <- Map.toList state.appSolveSessions
        , let worker = solveWorkerFor state issueNumber
        , let isLive = Map.member issueNumber state.appSolveProcesses || worker /= Nothing
      ]
    pullRequestEntries =
      [ AgentSessionEntry
          { agentSessionRef = PullRequestAgent number,
            agentSessionLabel = "pr " <> pullRequestActionText session.sessionDetail.pullRequestSessionAction <> " #" <> showText number,
            agentSessionProvider =
              pullRequestSessionLabel
                session.sessionDetail.pullRequestSessionAssignment
                session.sessionDetail.pullRequestSessionOrigin
                session.sessionDetail.pullRequestSessionAction
                session.sessionDetail.pullRequestSessionBrand
                state.appModelRoster,
            agentSessionStatus = persistentProcessStatus state.appNow worker (solveProcessStatus session.sessionPhase),
            agentSessionActivity = timedActivity state.appNow isLive session.sessionActivityStartedAt session.sessionActivity,
            agentSessionId = shortSessionId <$> session.sessionDetail.pullRequestSessionId,
            agentSessionLive = isLive,
            agentSessionProblem = session.sessionPhase `elem` [SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]
          }
        | (number, session) <- Map.toList state.appPullRequestReviewSessions
        , let worker = pullRequestWorkerFor state number
        , let isLive = Map.member number state.appPullRequestProcesses || worker /= Nothing
      ]
    reviewEntries =
      [ reviewAgentSessionEntry
          (reviewBackendReady state.appReviewBackend)
          (Map.member issueNumber state.appCanonicalReviewProcesses)
          issueNumber
          session
        | (issueNumber, session) <- Map.toList state.appReviewSessions
      ]
    unattachedWorkerEntries =
      [ AgentSessionEntry
          { agentSessionRef = WorkerAgent identifier,
            agentSessionLabel = workerTaskLabel descriptor.workerDescriptorSpec.workerTask,
            agentSessionProvider = workerTaskProvider descriptor.workerDescriptorSpec,
            agentSessionStatus = persistentProcessStatus state.appNow (Just descriptor) "starting",
            agentSessionActivity = "waiting for board metadata",
            agentSessionId = Nothing,
            agentSessionLive = True,
            agentSessionProblem = False
          }
        | (identifier, descriptor) <- Map.toList state.appWorkers,
          not (workerHasSession descriptor)
      ]
    workerHasSession descriptor = case descriptor.workerDescriptorSpec.workerTask of
      SolveWorkerTaskKind task -> Map.member task.solveWorkerIssueNumber state.appSolveSessions
      PullRequestWorkerTaskKind task -> Map.member task.pullRequestWorkerNumber state.appPullRequestReviewSessions
    workerTaskLabel (SolveWorkerTaskKind task) = Text.toLower (workflowTitle task.solveWorkerWorkflow) <> " #" <> showText task.solveWorkerIssueNumber
    workerTaskLabel (PullRequestWorkerTaskKind task) = "pr " <> pullRequestActionText task.pullRequestWorkerAction <> " #" <> showText task.pullRequestWorkerNumber
    -- Read from the whole specification, not just its task: the row names
    -- the assignment that worker recorded, and only a specification written
    -- before that field existed falls through to the live cell.
    workerTaskProvider spec = case spec.workerTask of
      SolveWorkerTaskKind task ->
        agentSessionLabelFor
          task.solveWorkerBrand
          spec.workerAssignment
          (`solveAssignment` task.solveWorkerBrand)
          state.appModelRoster
      PullRequestWorkerTaskKind task ->
        pullRequestSessionLabel
          spec.workerAssignment
          task.pullRequestWorkerOrigin
          task.pullRequestWorkerAction
          (agentForAction task.pullRequestWorkerOrigin task.pullRequestWorkerAction)
          state.appModelRoster

-- | The chips the base footer shows while the processes overlay is open.
--
-- Declared here, beside the entry list and the selection resolver those keys
-- move, rather than at the drawing site: @j@, @k@, and the arrows step the
-- selection 'resolveProcessSelection' keeps, @Enter@ opens the session the
-- selected row names, and @x@ kills its process tree. The arms that carry
-- those out are in "Kanban.UI.Events" and name this list in their own
-- comment, so a key added there has one row to add here and nowhere else.
--
-- Carries no @docs\/design.md@ §7 contract: §7 documents the panel's keys
-- inside the @p@ row's description, and this is the cheat sheet for them, so
-- it stays out of 'Kanban.UI.Overlay.helpLines' and out of the inventory
-- 'Spec.UI.Keys' holds §7 to.
processesFooterHints :: [Text]
processesFooterHints =
  [ "j/↓ next",
    "k/↑ previous",
    "Enter open session",
    "x kill process tree",
    "wheel scroll",
    -- Projected from the one declaration site rather than written out, for
    -- the same reason 'settingsFooterHints' projects it: @f@ is a base-table
    -- binding the shared arm answers ahead of this panel's own keys.
    footerHint (binding ToggleFullscreen),
    "Esc close"
  ]

-- | Resolves a processes-overlay selection against the current entries: if
-- the tracked identity is still present, follow it to its (possibly
-- reordered) row; otherwise clamp the last-known row into the new list and
-- adopt whatever entry now sits there as the new canonical identity, so a
-- later reorder follows that fallback instead of re-clamping a vanished ref.
resolveProcessSelection :: [AgentSessionEntry] -> ProcessSelection -> ProcessSelection
resolveProcessSelection entries selection =
  case selection.processSelectionRef of
    Just ref
      | Just index <- findIndex ((== ref) . agentSessionRef) entries ->
          ProcessSelection (Just ref) index
    _ ->
      let clampedRow = max 0 (min selection.processSelectionRow (length entries - 1))
       in ProcessSelection (agentSessionRef <$> safeIndex clampedRow entries) clampedRow

-- | Resolves a processes-overlay click by the identity that was rendered
-- into the clicked row, so a reorder between render and dispatch can't
-- redirect the click to a different session at the same position.
resolveProcessClick :: [AgentSessionEntry] -> ProcessSelection -> AgentSessionRef -> ProcessClickOutcome
resolveProcessClick entries selection clickedRef =
  case findIndex ((== clickedRef) . agentSessionRef) entries of
    Nothing -> ProcessClickIgnored
    Just clickedIndex
      | (resolveProcessSelection entries selection).processSelectionRef == Just clickedRef -> ProcessClickOpen
      | otherwise -> ProcessClickSelect (ProcessSelection (Just clickedRef) clickedIndex)

-- | The solve and pull-request phases that need a human. Written out rather
-- than derived from 'agentSessionProblem', which is the /processes/
-- overlay's narrower "this went wrong" marker and deliberately excludes
-- 'SolveAttention': a session waiting for an answer is not a problem, but it
-- is exactly the kind of thing this panel exists to surface (issue #128).
solveIncidentPhase :: SolvePhase -> Bool
solveIncidentPhase phase =
  phase `elem` [SolveAttention, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]

-- | The review phases that need a human. Written out rather than derived
-- from 'reviewPhaseActive' or 'agentSessionProblem', both of which encode
-- different questions: 'ReviewWaiting' is phase-active (the turn is still
-- alive) yet is precisely a session waiting on the user, while
-- 'ReviewRevised' and 'ReviewInterrupted' are terminal states the user
-- already knows about and does not need chasing.
reviewIncidentPhase :: ReviewPhase -> Bool
reviewIncidentPhase phase =
  phase `elem` [ReviewWaiting, ReviewNeedsChanges, ReviewFailed]

-- | What the drainer source can say for itself, from the last observation
-- and the status it produced. The set is the authority: a controller that
-- reported one is a source that answered, whatever its state, and a
-- controller that reported none has not answered at all — whether because
-- the first poll has not landed, because the invocation or its decode
-- failed, because discovery never found a controller, or because a start or
-- stop is in flight.
drainerSourceState :: DrainerStatus -> Maybe [DrainerIncident] -> DrainerSourceState
drainerSourceState status incidents = case incidents of
  Just reported -> DrainerSourceReported reported
  Nothing
    | status.drainerState `elem` [DrainerStarting, DrainerStopping] -> DrainerSourceChecking
    | otherwise -> DrainerSourceUnavailable status.drainerDetail

incidentSourceLabel :: IncidentSource -> Text
incidentSourceLabel DrainerSource = "pr drainer"
incidentSourceLabel SessionSource = "kanban session"

-- | Every row the incidents panel lists, in a stable order: the drainer's
-- own incidents newest first as the service returned them, then Kanban's
-- qualifying sessions by kind and number. Order is presentational only —
-- 'IncidentRef' is what selection and activation resolve against — so a
-- refresh that reorders this list cannot redirect either.
incidentEntries :: AppState -> [IncidentEntry]
incidentEntries state = drainerEntries <> solveEntries <> pullRequestEntries <> reviewEntries
  where
    drainerEntries = case drainerSourceState state.appDrainerStatus state.appDrainerIncidents of
      DrainerSourceReported incidents -> map (drainerIncidentEntry state) incidents
      DrainerSourceChecking -> []
      DrainerSourceUnavailable _ -> []
    solveEntries =
      [ sessionIncidentEntry
          (SolveAgent issueNumber)
          (IssueId issueNumber)
          (workSubject "issue" issueNumber session.sessionDetail.solveSessionIssue.issueTitle)
          (solveProcessStatus session.sessionPhase)
          session.sessionActivity
        | (issueNumber, session) <- Map.toList state.appSolveSessions,
          solveIncidentPhase session.sessionPhase
      ]
    pullRequestEntries =
      [ sessionIncidentEntry
          (PullRequestAgent number)
          (PullRequestId number)
          (workSubject "PR" number session.sessionDetail.pullRequestSessionPullRequest.pullRequestTitle)
          (solveProcessStatus session.sessionPhase)
          session.sessionActivity
        | (number, session) <- Map.toList state.appPullRequestReviewSessions,
          solveIncidentPhase session.sessionPhase
      ]
    reviewEntries =
      [ sessionIncidentEntry
          (ReviewAgent issueNumber)
          (IssueId issueNumber)
          (workSubject "issue" issueNumber session.sessionDetail.reviewSessionIssue.issueTitle)
          (reviewProcessStatus session.sessionPhase)
          session.sessionActivity
        | (issueNumber, session) <- Map.toList state.appReviewSessions,
          reviewIncidentPhase session.sessionPhase
      ]
    sessionIncidentEntry reference work subject status activity =
      IncidentEntry
        { incidentEntryRef = SessionIncidentRef reference,
          incidentEntrySource = SessionSource,
          incidentEntryWork = Just work,
          incidentEntrySession = Just reference,
          incidentEntrySubject = subject,
          incidentEntryDetail = status <> " · " <> sanitizeText activity,
          incidentEntryNote = Nothing
        }

-- | One drainer incident as a row. The session is looked up rather than
-- carried by the incident: the drainer knows nothing about Kanban's live
-- sessions, but a pull request it is stuck on may well be one this dashboard
-- is already running an agent against, and that agent's overlay is the
-- fastest thing to reach.
drainerIncidentEntry :: AppState -> DrainerIncident -> IncidentEntry
drainerIncidentEntry state incident =
  IncidentEntry
    { incidentEntryRef = DrainerIncidentRef incident.incidentId,
      incidentEntrySource = DrainerSource,
      incidentEntryWork = work,
      incidentEntrySession = session,
      incidentEntrySubject = subject,
      incidentEntryDetail = Text.intercalate " · " (summary : diagnostics),
      incidentEntryNote = recordedFailure incident
    }
  where
    -- Only the authoritative field. 'incidentLastPullRequest' is inferred by
    -- the service from a log line and names whichever pull request was
    -- mentioned last, not what the incident is about, so it never becomes a
    -- navigation target — a supervisor crash stays cardless.
    work = PullRequestId <$> incident.incidentPullRequest
    session = do
      number <- incident.incidentPullRequest
      if Map.member number state.appPullRequestReviewSessions
        then Just (PullRequestAgent number)
        else Nothing
    subject = case incident.incidentPullRequest of
      Just number -> workSubject "PR" number (boardItemTitle state.appBoard (PullRequestId number))
      Nothing -> "drainer supervisor"
    summary =
      maybe
        ("open " <> sanitizeText incident.incidentKind <> " incident")
        sanitizeText
        incident.incidentSummary
    -- A crash records more than its exit status, and the fields it does
    -- record are what makes a cardless row worth reading.
    diagnostics =
      ["last activity: " <> sanitizeText activity | Just activity <- [incident.incidentActivity]]
        <> [ "last logged PR #" <> showText number <> ", not a navigation target"
             | Just number <- [incident.incidentLastPullRequest],
               incident.incidentKind == crashIncidentKind
           ]

-- | The failure the drainer recorded for a stuck post-merge cleanup, as the
-- one logical line the panel wraps beneath that incident's row.
--
-- The row's own line states the step that is stuck; this states why, and —
-- since #200 words the refusal that way — the action that clears it. The
-- panel is a fixed 100 cells and a cleanup summary alone already overruns
-- it, so on the row itself this text would always be elided away before its
-- first word: a blocker and a remedy an operator can never read are not
-- stated at all. It is given its own wrapped line instead.
--
-- Read only for 'cleanupIncidentKind'. Every other kind's row is built from
-- the fields it is defined to carry, so a stray @last_error@ on a crash or
-- conflict incident changes nothing.
--
-- 'boundedLines' at one line does the whole projection, and its shape is
-- what makes the absent cases free: 'sanitizeText' preserves logical
-- newlines, so collapsing to a single line here is what lets the renderer
-- wrap to the width it actually has. Text that is missing, empty,
-- whitespace-only, or emptied by sanitization yields no line at all, hence
-- no note, and the row renders exactly as it did before the field existed.
recordedFailure :: DrainerIncident -> Maybe Text
recordedFailure incident
  | incident.incidentKind /= cleanupIncidentKind = Nothing
  | otherwise = do
      recorded <- incident.incidentError
      -- Collapsed to one logical line first, and only then bounded. Bounding
      -- a value that still holds the line breaks 'sanitizeText' preserves
      -- would measure the wrong thing, and bounding before the collapse is
      -- how a tail gets trimmed off before anything can choose to keep it.
      case Text.unwords (Text.words (sanitizeText recorded)) of
        "" -> Nothing
        collapsed -> Just (middleExcerpt incidentErrorWidth collapsed)

-- | The cap on a recorded failure's carried text.
--
-- Generous, and applied by dropping the middle rather than the tail. The
-- value the drainer records is a step prefix followed by the whole refusal
-- text, which restates what failed at arbitrary length — it embeds the
-- checkout's absolute path — before reaching "Local changes are not what
-- blocked this", the @git add@ remedy, and the paths to act on. A cap that
-- trimmed the tail would therefore discard exactly the part this row exists
-- to show, and the more deeply nested the checkout the more certainly it
-- would. The cap keeps a pathological error finite; it never decides which
-- end matters.
incidentErrorWidth :: Int
incidentErrorWidth = 4000

-- | "PR #42 — Fix the thing", or just "PR #42" when no title is known.
workSubject :: Text -> Int -> Text -> Text
workSubject noun number title
  | Text.null trimmed = heading
  | otherwise = heading <> " — " <> trimmed
  where
    heading = noun <> " #" <> showText number
    trimmed = Text.strip (sanitizeText title)

boardItemTitle :: Board -> ItemId -> Text
boardItemTitle board target = maybe "" (\(_, _, item) -> itemTitle item) (findItem board target)

-- | The chips the base footer shows while the incidents panel is open, for
-- the same reason 'processesFooterHints' sits beside its own resolver.
--
-- The panel's whole key policy is 'Kanban.UI.Events.incidentsAction', which
-- points back here; §7 documents these keys inside the @i@ row's description
-- and gains no rows of its own from them.
incidentsFooterHints :: [Text]
incidentsFooterHints =
  [ "j/↓ next",
    "k/↑ previous",
    "Enter go to the work",
    "wheel scroll",
    footerHint (binding ToggleFullscreen),
    "Esc close"
  ]

-- | Resolves an incidents-panel selection against the current rows, exactly
-- as 'resolveProcessSelection' does: follow the tracked identity to wherever
-- it now sits, and otherwise clamp the last-known row so the panel still has
-- something highlighted.
--
-- Only the highlight is clamped. Activation deliberately does not go through
-- this: see 'resolveIncidentActivation'.
resolveIncidentSelection :: [IncidentEntry] -> IncidentSelection -> IncidentSelection
resolveIncidentSelection entries selection =
  case selection.incidentSelectionRef of
    Just reference
      | Just index <- findIndex ((== reference) . incidentEntryRef) entries ->
          IncidentSelection (Just reference) index
    _ ->
      let clampedRow = max 0 (min selection.incidentSelectionRow (length entries - 1))
       in IncidentSelection (incidentEntryRef <$> safeIndex clampedRow entries) clampedRow

-- | Resolves a click by the identity that was rendered into the clicked row,
-- so a refresh between render and dispatch cannot redirect it to whatever
-- now occupies that position.
resolveIncidentClick :: [IncidentEntry] -> IncidentSelection -> IncidentRef -> IncidentClickOutcome
resolveIncidentClick entries selection clickedRef =
  case findIndex ((== clickedRef) . incidentEntryRef) entries of
    Nothing -> IncidentClickIgnored
    Just clickedIndex
      | (resolveIncidentSelection entries selection).incidentSelectionRef == Just clickedRef ->
          IncidentClickOpen
      | otherwise -> IncidentClickSelect (IncidentSelection (Just clickedRef) clickedIndex)

-- | Where the board holds a numbered piece of work, and which tracker has to
-- be expanded for that row to be visible.
data BoardWorkLocation = BoardWorkLocation
  { boardWorkColumn :: BoardColumn,
    boardWorkRow :: Int,
    boardWorkExpands :: Maybe Int
  }
  deriving stock (Eq, Show)

-- | The board work one agent session acts on, as the identity a lifecycle
-- question is asked with.
--
-- Every session is keyed by a number already, except a persistent worker,
-- which is keyed by its own identifier and names its target through the task
-- it was created for. 'Nothing' means the worker is no longer registered, so
-- there is nothing left to act on either way.
agentSessionSubject :: AppState -> AgentSessionRef -> Maybe ItemId
agentSessionSubject _ (SolveAgent issueNumber) = Just (IssueId issueNumber)
agentSessionSubject _ (ReviewAgent issueNumber) = Just (IssueId issueNumber)
agentSessionSubject _ (PullRequestAgent number) = Just (PullRequestId number)
agentSessionSubject state (WorkerAgent identifier) = do
  descriptor <- Map.lookup identifier state.appWorkers
  pure $ case descriptor.workerDescriptorSpec.workerTask of
    SolveWorkerTaskKind task -> IssueId task.solveWorkerIssueNumber
    PullRequestWorkerTaskKind task -> PullRequestId task.pullRequestWorkerNumber

-- | Finds the row a number names, in the four shapes the board can hold it.
--
-- 'findEntryWithLocation' covers the first three: an ordinary issue or pull
-- request, a childless tracker (whose header entry /is/ its issue), and a
-- child of a tracker — which is present in the column whether or not its
-- tracker is expanded, so it is found here and reported with the tracker
-- that has to be opened for it to be seen.
--
-- The fourth has no entry of its own at all. A tracker with visible children
-- is rendered as the header of their group instead of as a card, so its
-- issue number appears on the board only through those children; the
-- fallback below finds the group's first row, which is the row that header
-- is drawn at. Without it the epic every child belongs to would report as
-- absent from a board plainly showing it.
locateBoardWork :: Board -> ItemId -> Maybe BoardWorkLocation
locateBoardWork board target = case findEntryWithLocation board target of
  Just (column, row, entry) -> Just (BoardWorkLocation column row (hiddenBeneath entry))
  Nothing -> case target of
    IssueId number -> firstColumnWith (representsTracker number)
    PullRequestId _ -> Nothing
  where
    -- Only a tracked child can be hidden. A tracker header is drawn whether
    -- its group is open or closed, so selecting one never has to expand it.
    hiddenBeneath (Tracked context _) = Just (primaryTrackerNumber context)
    hiddenBeneath (Standalone _) = Nothing
    hiddenBeneath (TrackerHeader _) = Nothing

    representsTracker number (Tracked context _) = primaryTrackerNumber context == number
    representsTracker _ (Standalone _) = False
    representsTracker _ (TrackerHeader _) = False

    firstColumnWith matches = go allColumns
      where
        go [] = Nothing
        go (column : rest) = case findIndex matches (entriesForBoard board column) of
          Just row -> Just (BoardWorkLocation column row Nothing)
          Nothing -> go rest

-- | Everything activating one row does, decided before anything changes.
data IncidentActivation = IncidentActivation
  { incidentActivationWork :: Maybe BoardWorkLocation,
    incidentActivationSession :: Maybe AgentSessionRef,
    incidentActivationNotice :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | What activating the row with this identity does, or 'Nothing' when the
-- list no longer holds it.
--
-- Keyed on an identity the caller names — the tracked selection for a key
-- press, the clicked row's own for a click — and never on a row position.
-- 'resolveIncidentSelection' clamps a vanished selection onto a neighbour so
-- the panel keeps a highlight, and adopting that neighbour here is exactly
-- the redirection this panel must not perform: an incident that disappeared
-- between the last render and this key press refuses rather than sending the
-- user to whatever moved into its place.
resolveIncidentActivation :: Board -> [IncidentEntry] -> IncidentRef -> Maybe IncidentActivation
resolveIncidentActivation board entries reference = activation <$> matching
  where
    matching = find ((== reference) . incidentEntryRef) entries
    activation entry = case entry.incidentEntryWork of
      -- Cardless by construction: the entry never named authoritative work,
      -- so there is nothing to look for and nothing to leave unchanged
      -- except by saying what happened.
      Nothing ->
        IncidentActivation
          Nothing
          entry.incidentEntrySession
          (Just (entry.incidentEntrySubject <> " · " <> entry.incidentEntryDetail))
      Just work -> case locateBoardWork board work of
        Just location -> IncidentActivation (Just location) entry.incidentEntrySession Nothing
        -- Absent from this board, or truncated off it. Either way there is
        -- no row to select, and moving the selection somewhere else would be
        -- worse than saying so.
        Nothing -> IncidentActivation Nothing entry.incidentEntrySession (Just (workAbsentNotice work))

workAbsentNotice :: ItemId -> Text
workAbsentNotice (IssueId number) = "Issue #" <> showText number <> " is not on the current board"
workAbsentNotice (PullRequestId number) = "PR #" <> showText number <> " is not on the current board"

solveProcessStatus :: SolvePhase -> Text
solveProcessStatus SolveStarting = "starting"
solveProcessStatus SolveRunning = "running"
solveProcessStatus SolveInterrupting = "interrupting"
solveProcessStatus SolveAttention = "waiting for input"
solveProcessStatus SolveFinished = "finished"
solveProcessStatus SolveFailedPhase = "failed"
solveProcessStatus SolveKilledPhase = "killed"
solveProcessStatus SolveOrphanedPhase = "orphaned"

reviewProcessStatus :: ReviewPhase -> Text
reviewProcessStatus ReviewStarting = "starting"
reviewProcessStatus ReviewRunning = "running"
reviewProcessStatus ReviewWaiting = "waiting for input"
reviewProcessStatus ReviewFinished = "finished"
reviewProcessStatus ReviewNeedsChanges = "changes requested"
reviewProcessStatus ReviewFailed = "failed"
reviewProcessStatus ReviewRevised = "awaiting rereview"
reviewProcessStatus ReviewInterrupted = "interrupted"

persistentProcessStatus :: UTCTime -> Maybe WorkerDescriptor -> Text -> Text
persistentProcessStatus _ Nothing status = status
persistentProcessStatus now (Just descriptor) status =
  status <> " · persistent · max " <> remainingText
  where
    spec = descriptor.workerDescriptorSpec
    elapsed = max 0 (floor (diffUTCTime now spec.workerCreatedAt) :: Int)
    remaining = max 0 (spec.workerMaxRuntimeSeconds - elapsed)
    remainingText
      | remaining >= 3600 = showText ((remaining + 3599) `div` 3600) <> "h"
      | remaining >= 60 = showText ((remaining + 59) `div` 60) <> "m"
      | otherwise = showText remaining <> "s"

reviewStageLabel :: ReviewStage -> Text
reviewStageLabel InitialReview = "review"
reviewStageLabel IssueRevision = "revision"
reviewStageLabel IssueRereview = "rereview"

reviewProvider :: ReviewStage -> Text
reviewProvider IssueRevision = "codex coordinator"
reviewProvider _ = "canonical reviewer"

-- | The review sessions the quit guard refuses to leave running: exactly
-- those the shared 'reviewSessionLive' decision reports live, so the guard
-- and the processes overlay cannot disagree about the same session.
liveReviewSessions :: Bool -> Set Int -> Map Int ReviewSession -> [Int]
liveReviewSessions backendReady canonicalProcesses sessions =
  [ issueNumber
    | (issueNumber, session) <- Map.toList sessions,
      reviewSessionLive backendReady (Set.member issueNumber canonicalProcesses) session
  ]

-- | The session a solve request for `issueNumber` must reuse rather than
-- replace: one that is still running, or a finished one from the very
-- workflow being requested. Only a terminal session belonging to a
-- /different/ workflow may be replaced.
--
-- Both the moment the chooser opens and the moment a chooser digit launches
-- consult this, because they are not the same moment: persistent-worker
-- discovery ('ensureWorkerSession') can attach a recovered session for the
-- issue while the chooser sits open, and a launch that only trusted the
-- chooser-open answer would overwrite that recovered session's transcript,
-- log path, and session id with an empty one — leaving the overlay showing a
-- record the live worker's events no longer belong to.
reusableSolveSession :: SolveWorkflow -> Int -> Map Int SolveSession -> Maybe SolveSession
reusableSolveSession workflow issueNumber sessions = do
  session <- Map.lookup issueNumber sessions
  if solvePhaseActive session.sessionPhase || session.sessionDetail.solveSessionWorkflow == workflow
    then Just session
    else Nothing

-- | Whether a solve-phase session still has work in hand. Solve and PR
-- sessions share 'SolvePhase' and always answered this identically, in two
-- byte-identical functions; the phase is the whole input, so one is enough.
solvePhaseActive :: SolvePhase -> Bool
solvePhaseActive phase = phase `elem` [SolveStarting, SolveRunning, SolveAttention, SolveOrphanedPhase]

-- | A provider that only registers (via 'WorkerProviderStarted') after the
-- watchdog has already committed a deadline outcome — orphaning or
-- finishing the session — must not have that late arrival revert the
-- session back to a running/thinking projection: the underlying worker is
-- already stopped or being cleaned up regardless of what this late event
-- claims, so resurrecting "running" here would be actively misleading
-- about what is actually happening.
isResolvedSolvePhase :: SolvePhase -> Bool
isResolvedSolvePhase phase = phase `elem` [SolveFinished, SolveFailedPhase, SolveKilledPhase, SolveOrphanedPhase]

-- | Whether a nonterminal solve projection (a fresh "started" event, but
-- also agent output/diagnostic text) arriving for this issue right now
-- should be dropped because the session has already resolved.
-- 'streamOutput'/'streamDiagnostics' run in their own thread reading a pipe
-- to EOF, independent of the worker's own lifecycle: buffered stdout/stderr
-- can still surface after the watchdog has already committed
-- 'WorkerOrphansDetected' or 'WorkerFinished'. Applying a late output or
-- diagnostic event unconditionally would overwrite the just-set
-- deadline/orphan activity text with generic "thinking"/"diagnostic output"
-- copy, hiding the very state this revision exists to surface. A missing
-- session (never seen before) is never considered resolved, matching the
-- prior unconditional behavior for a session's first event. Solve and PR
-- sessions ask this of the same phase type and answered it in two
-- byte-identical functions, so one polymorphic definition serves both.
sessionAlreadyResolved :: Int -> Map Int (AgentSession SolvePhase detail) -> Bool
sessionAlreadyResolved key sessions = maybe False (isResolvedSolvePhase . (.sessionPhase)) (Map.lookup key sessions)

-- | Whether a solve or pull-request session still has something behind it to
-- read text typed into its draft (issue #515). This is what pins a session to
-- normal mode and makes @i@ a no-op on it.
--
-- These two kinds read typed text in exactly one phase. 'submitSolveInput' and
-- its pull-request counterpart refuse every phase but 'SolveAttention' —
-- "this solve session is not waiting for input" — and 'drawSolveInput' draws
-- the @>@ line in that phase alone. So a running or interrupting session has
-- no more of a reader than a finished one does: insert mode there would edit
-- a draft that is neither visible nor sendable. Unlike a review session, there
-- is no undelivered-steer queue behind these to hold a mid-turn draft
-- ('applyUndeliveredSteer' is the app-server path and belongs to review), so
-- the answer is the phase that waits for input and nothing else.
solveSessionInputLive :: SolvePhase -> Bool
solveSessionInputLive phase = phase == SolveAttention

-- | The mode a solve or pull-request session actually behaves and draws in.
-- One spelling of the derivation, so the overlay's badge, its hint line, and
-- the decoder cannot end up with two opinions about the same session.
solveSessionMode :: AgentSession SolvePhase detail -> SessionMode
solveSessionMode session = liveSessionMode (solveSessionInputLive session.sessionPhase) session.sessionMode

-- | The same for a review session, whose liveness needs its stage too.
reviewSessionMode :: ReviewSession -> SessionMode
reviewSessionMode session =
  liveSessionMode
    (reviewSessionInputLive session.sessionDetail.reviewSessionStage session.sessionPhase)
    session.sessionMode

-- | The same question for a review session, which takes /two/ answers rather
-- than one because its stage decides as much as its phase.
--
-- A canonical stage never reads typed text at all: it runs
-- @approve_issues.py@ as a subprocess and has no app-server thread, so it
-- carries no thread id for 'sendReviewFeedback' to send on and can never be
-- handed a question or an approval. Ctrl-C kills its process and only a fresh
-- @r@ starts another.
--
-- An app-server revision reads text until it settles — with one exception
-- that is the whole reason this is not just a terminal-phase list.
-- 'reviewSessionReusable' deliberately keeps an interrupted revision
-- resumable, and §7 promises guidance after an interrupt, so
-- 'ReviewInterrupted' is terminal for a canonical stage and merely paused for
-- a revision.
reviewSessionInputLive :: ReviewStage -> ReviewPhase -> Bool
reviewSessionInputLive stage phase
  | stage /= IssueRevision = False
  | phase == ReviewInterrupted = True
  | otherwise = phase `notElem` [ReviewFinished, ReviewNeedsChanges, ReviewFailed, ReviewRevised]

reviewPhaseActive :: ReviewPhase -> Bool
reviewPhaseActive phase = phase `elem` [ReviewStarting, ReviewRunning, ReviewWaiting]

reviewSessionActive :: ReviewSession -> Bool
reviewSessionActive session = reviewPhaseActive session.sessionPhase

-- | Whether pressing 'r' should just reopen an existing review session
-- rather than launch a fresh label-derived stage. A live turn is always
-- reused, as is a finished/failed session whose recorded stage still
-- matches what the labels currently request. A cancelled canonical stage
-- ('ReviewInterrupted') is the exception: once its process has actually
-- finished (no live entry in 'appCanonicalReviewProcesses' remains), 'r'
-- must launch a genuinely fresh stage even though the stage is unchanged,
-- rather than reopen the stale interrupted overlay -- but while that kill
-- is still in flight, reusing the existing session avoids racing a second
-- process launch against the first invocation's still-pending completion.
-- An interrupted app-server revision remains resumable, so it follows the
-- ordinary same-stage reuse rule instead.
reviewSessionReusable :: ReviewPhase -> ReviewStage -> ReviewStage -> Bool -> Bool
reviewSessionReusable phase sessionStage requestedStage hasLiveCanonicalProcess
  | phase == ReviewInterrupted, sessionStage /= IssueRevision = hasLiveCanonicalProcess
  | reviewPhaseActive phase = True
  | sessionStage == requestedStage = True
  | otherwise = False

-- | Whether pressing r should reuse a tracked session's overlay rather than
-- launch a fresh action. An active session is always reused. A finished
-- session is only reused when the recomputed action still matches AND the
-- PR has not changed since that action was launched -- otherwise a fresh
-- canonical round is needed even if the recomputed action repeats, e.g. a
-- second reviewed:changes verdict after pr-revise's own rereview.
pullRequestSessionReusable :: Bool -> Bool -> PullRequestAction -> PullRequestAction -> UTCTime -> UTCTime -> Bool
pullRequestSessionReusable forceFresh active sessionAction currentAction launchedForUpdatedAt currentUpdatedAt =
  not forceFresh && (active || (sessionAction == currentAction && launchedForUpdatedAt == currentUpdatedAt))

-- | Whether the review overlay -- and therefore every session's tab within
-- it, including a thread-less canonical stage -- is currently on screen.
-- Ticks are the only thing driving periodic redraws for review animation,
-- so gating them on this keeps a closed or backgrounded review from
-- redrawing at all (docs/design.md section 7).
reviewOverlayVisible :: Maybe Overlay -> Bool
reviewOverlayVisible (Just (ReviewOverlay _)) = True
reviewOverlayVisible _ = False

solveWorkerFor :: AppState -> Int -> Maybe WorkerDescriptor
solveWorkerFor state issueNumber =
  find matches (Map.elems state.appWorkers)
  where
    matches descriptor = case descriptor.workerDescriptorSpec.workerTask of
      SolveWorkerTaskKind task -> task.solveWorkerIssueNumber == issueNumber
      PullRequestWorkerTaskKind _ -> False

pullRequestWorkerFor :: AppState -> Int -> Maybe WorkerDescriptor
pullRequestWorkerFor state number =
  find matches (Map.elems state.appWorkers)
  where
    matches descriptor = case descriptor.workerDescriptorSpec.workerTask of
      PullRequestWorkerTaskKind task -> task.pullRequestWorkerNumber == number
      SolveWorkerTaskKind _ -> False

selectedReviewIssue :: AppState -> Maybe Issue
selectedReviewIssue state = selectedReviewItem state >>= boardItemIssue
  where
    boardItemIssue (IssueItem issue) = Just issue
    boardItemIssue (PullRequestItem _) = Nothing

selectedReviewItem :: AppState -> Maybe BoardItem
selectedReviewItem state = case selectedEntry state of
  Just (Tracked context item)
    | primaryTrackerNumber context `Set.notMember` state.appExpandedTrackers ->
        Just (IssueItem context.trackingPrimary.membershipTracker.trackerIssue)
    | otherwise -> Just item
  Just (Standalone item) -> Just item
  Just (TrackerHeader tracker) -> Just (IssueItem tracker.trackerIssue)
  Nothing -> Nothing

-- | Why the review key refuses a selection 'selectedReviewItem' still
-- promotes to a tracker's own issue.
--
-- An epic is structure rather than reviewable work: it carries no
-- Requirements or Acceptance for the canonical @issue-review:v2@ gate to
-- read, so a session started against one only ever leaves a badge on a
-- header. Solve, autosolve, and the kill binding keep the promotion — they
-- act on the epic issue deliberately — which is why this is a separate
-- resolution rather than a change to 'selectedReviewItem'.
data EpicReviewRefusal
  = -- | A collapsed tracker. Its children are reviewable, but only once the
    -- header is expanded and one of them can be selected.
    CollapsedEpicGroup
  | -- | A 'TrackerHeader': a tracker with no visible children at all, so
    -- there is no child to redirect to.
    StructuralEpicHeader
  deriving stock (Eq, Show)

-- | What pressing the review key on the board acts on.
data ReviewTarget
  = ReviewTargetItem BoardItem
  | ReviewTargetRefused EpicReviewRefusal
  | ReviewTargetNone
  deriving stock (Eq, Show)

-- | The board selection resolved for review. This deliberately diverges from
-- 'selectedReviewItem' on the two epic-header shapes and agrees with it
-- everywhere else.
selectedReviewTarget :: AppState -> ReviewTarget
selectedReviewTarget state = case selectedEntry state of
  Just (Tracked context item)
    | primaryTrackerNumber context `Set.notMember` state.appExpandedTrackers ->
        ReviewTargetRefused CollapsedEpicGroup
    | otherwise -> ReviewTargetItem item
  Just (Standalone item) -> ReviewTargetItem item
  Just (TrackerHeader _) -> ReviewTargetRefused StructuralEpicHeader
  Nothing -> ReviewTargetNone

-- | The same refusal for an item a details overlay already holds, where the
-- board selection has been resolved away and only the 'BoardItem' is left.
-- An empty header's overlay is the reachable case: 'openSelectedDetails'
-- answers a collapsed group with a notice instead of opening one, so a
-- tracker with visible children never reaches an overlay of its own.
itemReviewRefusal :: AppState -> BoardItem -> Maybe EpicReviewRefusal
itemReviewRefusal state item =
  epicRefusal <$> structuralActionRefusal ReviewIssue (dashboardItemStructure state item)
  where
    epicRefusal StructuralTrackerHeader = StructuralEpicHeader
    epicRefusal StructuralCollapsedGroup = CollapsedEpicGroup

-- | The structure this board is drawing an item with, in the registry's own
-- vocabulary.
--
-- Taken from the visible board rather than from the tracker hierarchy because
-- that is the fact the dashboard's refusal has always been about: an epic
-- whose children are all filtered away is drawn as a header with nothing to
-- redirect to, whatever its checklist says. A headless caller has no board, so
-- it classifies from the hierarchy instead ('targetStructureForIssue') and
-- both feed the one rule above.
dashboardItemStructure :: AppState -> BoardItem -> TargetStructure
dashboardItemStructure state (IssueItem issue)
  | any headerFor (concat (Map.elems state.appVisibleBoard.boardColumns)) = TargetTracker TrackerChildless
  | otherwise = TargetPlain
  where
    headerFor (TrackerHeader tracker) = tracker.trackerIssue.issueNumber == issue.issueNumber
    headerFor _ = False
dashboardItemStructure _ (PullRequestItem _) = TargetPlain
