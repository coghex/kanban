-- | The autosolve loop's stage advancement, kept clear of Brick.
--
-- Everything that decides /what the loop does next/ lives here as a pure
-- function over an 'AutoSolveObservation' and the session's
-- 'AutoSolveProgress', returning an 'AutoSolveDecision' that names an effect
-- without performing one. That is what makes the parts worth pinning —
-- binding a discovered pull request to the run that produced it, the
-- approve/changes label handoffs, and the five-round bound — exercisable
-- without an @EventM@ or a Brick harness.
--
-- 'Kanban.UI.Reconcile' is the adapter: it gathers the observation, runs the
-- decision, and renders the notices. It keeps no stage or round state of its
-- own, so the progression cannot drift between the two.
module Kanban.UI.AutoSolve
  ( AutoSolveCompletion (..),
    AutoSolveDecision (..),
    AutoSolveHalt (..),
    AutoSolveHandoff (..),
    AutoSolveObservation (..),
    AutoSolveRevision (..),
    autoSolveRevisionTurn,
    autoSolveAfterCompletion,
    autoSolveCompleted,
    autoSolveCompletionNotice,
    autoSolveReviewLimit,
    autoSolveRevisionPrompt,
    autoSolveStopped,
    boardPullRequestNumbers,
    decideAutoSolve,
    expectedPullRequestOrigin,
    findSnapshotPullRequest,
    initialAutoSolveProgress,
    newAutoSolvePullRequests,
    pullRequestHasLabel,
    recoveredAutoSolveProgress,
  )
where

import Data.List (find)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, addUTCTime)
import Kanban.Domain
import Kanban.PullRequestFlow
  ( PullRequestVerdict (..),
    expectedPullRequestOrigin,
    originFromBody,
    pullRequestVerdictEvidence,
  )
import Kanban.Solve (ResumeProvenance (..), SolveWorkflow (..), SolverBrand (..))
import Kanban.UI.Keys (BoardAction (..), actionKeyText)
import Kanban.UI.Types (AutoSolveProgress (..), AutoSolveStage (..), SolvePhase (..))
import Kanban.UI.Util (allColumns, entriesForBoard, showText)
import Kanban.Worker (WorkerParent (..))
import Kanban.Workflow (entryItem)

-- | Everything one board refresh observes about a single autosolve session.
-- The adapter gathers it so the decisions below read no @AppState@.
data AutoSolveObservation = AutoSolveObservation
  { autoSolveIssueNumber :: Int,
    autoSolveWorkflowConfig :: WorkflowConfig,
    autoSolveSolverBrand :: SolverBrand,
    -- | The solver's resumable session id, when it returned one. Without it
    -- a revision cannot be resumed and the loop has to stop.
    autoSolveSolverSession :: Maybe Text,
    -- | Whether a solve process is already running for this issue, which
    -- holds a revision back rather than launching a second one alongside it.
    autoSolveSolverRunning :: Bool,
    -- | The refreshed snapshot's pull requests.
    autoSolveSnapshotPullRequests :: [PullRequest],
    -- | The phase of the PR review session Kanban holds for the bound pull
    -- request, when it holds one at all.
    autoSolveReviewPhase :: Maybe SolvePhase
  }
  deriving stock (Eq, Show)

-- | Whether a halt reads as a stop the user can pick up or as a failure.
data AutoSolveHalt
  = AutoSolveHaltStopped
  | AutoSolveHaltFailed
  deriving stock (Eq, Show)

-- | What one observation of an autosolve session should do. Every
-- constructor names an effect for the adapter to run; none performs one, and
-- the progress a constructor carries is the loop's new state.
data AutoSolveDecision
  = -- | This stage has nothing to observe.
    AutoSolveWait
  | -- | Stay on this stage; only the activity line changes.
    AutoSolveWaitingOn Text
  | -- | Start the review the already-bound pull request is missing, leaving
    -- the recorded stage and round alone.
    AutoSolveStartReview Int
  | -- | A newly linked pull request was bound; open its first review round.
    AutoSolveOpenReview Int AutoSolveProgress
  | -- | Resume the original solver against a changes-requested verdict.
    AutoSolveRevise Int AutoSolveProgress
  | -- | The bound pull request is approved and the loop is done.
    AutoSolveApprove Int
  | -- | The loop cannot continue without a human.
    AutoSolveHalted AutoSolveHalt Text
  deriving stock (Eq, Show)

-- | Advance one autosolve session against a refreshed snapshot. Stages a
-- refresh does not drive — implementing, revising, and the two terminal
-- stages — observe nothing and wait.
decideAutoSolve :: AutoSolveObservation -> AutoSolveProgress -> AutoSolveDecision
decideAutoSolve observation progress = case progress.autoSolveStage of
  AutoDiscoveringPullRequest -> decideDiscovery observation progress
  AutoReviewing -> decideReview observation progress
  AutoAwaitingRereview -> decideRereview observation progress
  _ -> AutoSolveWait

-- | Bind the pull request the finished implementation opened. Exactly one
-- new linked pull request carrying the solver's own origin marker is the
-- only unambiguous answer; anything else stops for a human rather than
-- guessing which pull request this run produced.
decideDiscovery :: AutoSolveObservation -> AutoSolveProgress -> AutoSolveDecision
decideDiscovery observation progress =
  case newAutoSolvePullRequests observation.autoSolveIssueNumber progress observation.autoSolveSnapshotPullRequests of
    [] -> AutoSolveWaitingOn ("waiting for linked PR; press " <> actionKeyText RefreshAll <> " to retry")
    [pullRequest] -> case originFromBody pullRequest.pullRequestBody of
      Right origin
        | origin == expectedPullRequestOrigin observation.autoSolveSolverBrand ->
            AutoSolveOpenReview
              pullRequest.pullRequestNumber
              progress
                { autoSolveStage = AutoReviewing,
                  autoSolvePullRequest = Just pullRequest.pullRequestNumber,
                  autoSolveReviewRound = 1
                }
      Right _ -> AutoSolveHalted AutoSolveHaltStopped "new linked PR has the wrong origin marker for the selected solver"
      Left message -> AutoSolveHalted AutoSolveHaltStopped ("new linked PR cannot be reviewed: " <> message)
    _ -> AutoSolveHalted AutoSolveHaltStopped "multiple new linked PRs appeared; choose the intended PR manually"

decideReview :: AutoSolveObservation -> AutoSolveProgress -> AutoSolveDecision
decideReview observation progress = case boundPullRequest observation progress of
  Nothing -> AutoSolveHalted AutoSolveHaltStopped "the autosolve PR disappeared before review completed"
  Just pullRequest -> case observation.autoSolveReviewPhase of
    Nothing -> AutoSolveStartReview pullRequest.pullRequestNumber
    Just SolveFailedPhase -> AutoSolveHalted AutoSolveHaltFailed ("PR #" <> showText pullRequest.pullRequestNumber <> " review failed; press " <> actionKeyText ShowProcesses <> " to inspect it")
    Just SolveKilledPhase -> AutoSolveHalted AutoSolveHaltFailed ("PR #" <> showText pullRequest.pullRequestNumber <> " review was killed")
    Just SolveAttention -> AutoSolveWaitingOn ("PR review needs input; press " <> actionKeyText ShowProcesses)
    Just SolveFinished -> case verdictEvidence config pullRequest of
      -- Two contradictory verdicts stand on it, so the review settled
      -- nothing. Stopping is the only honest move: an approval-first reading
      -- would complete the run on a pull request whose review state is
      -- broken.
      Left reason -> AutoSolveHalted AutoSolveHaltStopped ("PR #" <> showText pullRequest.pullRequestNumber <> " " <> reason)
      Right PullRequestVerdictApproved -> AutoSolveApprove pullRequest.pullRequestNumber
      Right PullRequestVerdictChangesRequested -> decideRevision observation progress pullRequest
      Right PullRequestVerdictPending ->
        AutoSolveWaitingOn ("waiting for review verdict; press " <> actionKeyText RefreshAll <> " to retry")
    Just _ -> AutoSolveWaitingOn ("reviewing PR #" <> showText pullRequest.pullRequestNumber)
  where
    config = observation.autoSolveWorkflowConfig

-- | pr-revise invokes the canonical rereview itself, so once the resumed
-- solver's revision finishes the fresh verdict already stands on the pull
-- request as approved or changes-requested; this never waits on a
-- Kanban-created reviewed:revised label.
decideRereview :: AutoSolveObservation -> AutoSolveProgress -> AutoSolveDecision
decideRereview observation progress = case boundPullRequest observation progress of
  Nothing -> AutoSolveHalted AutoSolveHaltStopped "the autosolve PR disappeared after revision"
  Just pullRequest ->
    case verdictEvidence observation.autoSolveWorkflowConfig pullRequest of
      Left reason -> AutoSolveHalted AutoSolveHaltStopped ("PR #" <> showText pullRequest.pullRequestNumber <> " " <> reason)
      Right PullRequestVerdictApproved -> AutoSolveApprove pullRequest.pullRequestNumber
      Right PullRequestVerdictChangesRequested ->
        decideRevision observation (progress {autoSolveReviewRound = progress.autoSolveReviewRound + 1}) pullRequest
      Right PullRequestVerdictPending ->
        AutoSolveWaitingOn ("waiting for the canonical rereview verdict; press " <> actionKeyText RefreshAll <> " to retry")

-- | The five-round bound, and the two conditions that make a revision
-- impossible or premature.
decideRevision :: AutoSolveObservation -> AutoSolveProgress -> PullRequest -> AutoSolveDecision
decideRevision observation progress pullRequest
  | progress.autoSolveReviewRound >= autoSolveReviewLimit =
      AutoSolveHalted
        AutoSolveHaltStopped
        ( "PR #"
            <> showText pullRequest.pullRequestNumber
            <> " still has requested changes after "
            <> showText autoSolveReviewLimit
            <> " review rounds"
        )
  | Nothing <- observation.autoSolveSolverSession =
      AutoSolveHalted AutoSolveHaltStopped "the original solver did not return a resumable session id"
  | observation.autoSolveSolverRunning = AutoSolveWait
  | otherwise = AutoSolveRevise pullRequest.pullRequestNumber progress {autoSolveStage = AutoRevising}

-- | The one canonical verdict a pull request carries, or why it carries none.
-- Both verdict arms above read it, so neither can settle a run on a pull
-- request whose review state contradicts itself.
verdictEvidence :: WorkflowConfig -> PullRequest -> Either Text PullRequestVerdict
verdictEvidence config pullRequest =
  pullRequestVerdictEvidence config (map (.labelName) pullRequest.pullRequestLabels)

boundPullRequest :: AutoSolveObservation -> AutoSolveProgress -> Maybe PullRequest
boundPullRequest observation progress =
  progress.autoSolvePullRequest
    >>= \number -> find ((== number) . (.pullRequestNumber)) observation.autoSolveSnapshotPullRequests

-- | Pull requests that appeared for this issue after the loop started, which
-- is what discovery binds to. Pull requests the board already carried when
-- the run began, and any opened well before it, are not this run's result.
newAutoSolvePullRequests :: Int -> AutoSolveProgress -> [PullRequest] -> [PullRequest]
newAutoSolvePullRequests issueNumber progress pullRequests =
  [ pullRequest
    | pullRequest <- pullRequests,
      issueNumber `elem` pullRequest.pullRequestLinkedIssues,
      pullRequest.pullRequestNumber `Set.notMember` progress.autoSolveKnownPullRequests,
      pullRequest.pullRequestCreatedAt >= addUTCTime (-300) progress.autoSolveStartedAt
  ]

-- | Which handoff a finished solver run makes: the implementation hands the
-- loop to discovery, a revision hands it to the canonical rereview verdict.
data AutoSolveHandoff
  = AutoSolveToDiscovery
  | AutoSolveToRereview
  deriving stock (Eq, Show)

-- | How a finished solver run moves the loop on: the handoff it makes, the
-- stage it enters, and what the session says while it waits.
data AutoSolveCompletion = AutoSolveCompletion
  { autoSolveCompletionHandoff :: AutoSolveHandoff,
    autoSolveCompletionProgress :: AutoSolveProgress,
    autoSolveCompletionActivity :: Text
  }
  deriving stock (Eq, Show)

-- | 'Nothing' when this run is not one the loop continues past, which
-- settles the session instead.
autoSolveAfterCompletion :: AutoSolveProgress -> Maybe AutoSolveCompletion
autoSolveAfterCompletion progress = case progress.autoSolveStage of
  AutoImplementing ->
    Just
      AutoSolveCompletion
        { autoSolveCompletionHandoff = AutoSolveToDiscovery,
          autoSolveCompletionProgress = progress {autoSolveStage = AutoDiscoveringPullRequest},
          autoSolveCompletionActivity = "discovering pull request"
        }
  AutoRevising ->
    Just
      AutoSolveCompletion
        { autoSolveCompletionHandoff = AutoSolveToRereview,
          autoSolveCompletionProgress = progress {autoSolveStage = AutoAwaitingRereview},
          autoSolveCompletionActivity = "waiting for revised PR state"
        }
  _ -> Nothing

-- | What the dashboard reports when a solver run hands the loop on.
autoSolveCompletionNotice :: Int -> AutoSolveHandoff -> Text
autoSolveCompletionNotice issueNumber AutoSolveToDiscovery =
  "Implementation for #" <> showText issueNumber <> " finished; discovering its new PR…"
autoSolveCompletionNotice issueNumber AutoSolveToRereview =
  "Revision for #" <> showText issueNumber <> " finished; waiting for the revised PR state…"

-- | Park the loop, for a solver run that failed or was killed.
autoSolveStopped :: AutoSolveProgress -> AutoSolveProgress
autoSolveStopped progress = progress {autoSolveStage = AutoSolveStopped}

-- | Retire the loop, for the approval it was driving towards.
autoSolveCompleted :: AutoSolveProgress -> AutoSolveProgress
autoSolveCompleted progress = progress {autoSolveStage = AutoSolveComplete}

-- | The loop a fresh solve starts with, if it is an autosolve at all.
initialAutoSolveProgress :: SolveWorkflow -> Set Int -> UTCTime -> Maybe AutoSolveProgress
initialAutoSolveProgress SolveOnly _ _ = Nothing
initialAutoSolveProgress AutoSolve known startedAt =
  Just
    AutoSolveProgress
      { autoSolveStage = AutoImplementing,
        autoSolvePullRequest = Nothing,
        autoSolveReviewRound = 0,
        autoSolveKnownPullRequests = known,
        autoSolveStartedAt = startedAt
      }

-- | The loop a reattached persistent worker resumes. The durable parent
-- record is authoritative wherever it exists: its round is what tells an
-- implementation run apart from a revision, its recorded start and known pull
-- requests are what keep discovery from binding a pull request this run did
-- not open, and its bound pull request is what a run reattached mid-revision
-- would otherwise have no way to learn -- discovery only ever binds a /new/
-- one, so a restored revision without it reaches its rereview with nothing
-- bound and halts on a pull request that is still there.
recoveredAutoSolveProgress :: SolveWorkflow -> Maybe WorkerParent -> Set Int -> UTCTime -> Maybe AutoSolveProgress
recoveredAutoSolveProgress SolveOnly _ _ _ = Nothing
recoveredAutoSolveProgress AutoSolve parent boardPullRequests createdAt =
  let reviewRound = maybe 0 (.workerParentReviewRound) parent
   in Just
        AutoSolveProgress
          { autoSolveStage = if reviewRound == 0 then AutoImplementing else AutoRevising,
            autoSolvePullRequest = parent >>= (.workerParentPullRequest),
            autoSolveReviewRound = reviewRound,
            autoSolveKnownPullRequests = maybe boardPullRequests (.workerParentKnownPullRequests) parent,
            autoSolveStartedAt = maybe createdAt (.workerParentStartedAt) parent
          }

-- | Everything the resumed-solver turn of one revision round is: which
-- provider session to resume, under what provenance, and what to tell it.
--
-- Declared here, beside the decision that asks for it, because two surfaces
-- start that turn -- the dashboard's refresh adapter and the plain-IO action
-- registry -- and a second construction of it is how the two would come to
-- resume under a different provenance or with a different prompt.
data AutoSolveRevision = AutoSolveRevision
  { autoSolveRevisionSession :: Text,
    autoSolveRevisionProvenance :: ResumeProvenance,
    autoSolveRevisionMessage :: Text
  }
  deriving stock (Eq, Show)

-- | The turn a revision round starts, or 'Nothing' when the original solver
-- returned no resumable session id.
--
-- 'decideRevision' has already halted on that absence by the time either
-- surface gets here, so the 'Nothing' is a totality guarantee rather than a
-- reachable path: a caller that arrived without a session starts nothing
-- instead of opening a fresh provider session that would not carry the
-- solve's own context.
autoSolveRevisionTurn :: WorkflowConfig -> Maybe FilePath -> Repository -> SolverBrand -> Maybe Text -> Int -> Int -> Maybe AutoSolveRevision
autoSolveRevisionTurn config configPath repository brand sessionId pullRequestNumber reviewRound =
  (\session -> AutoSolveRevision session ResumeAutomatedChangesRequested prompt) <$> sessionId
  where
    prompt = autoSolveRevisionPrompt config configPath repository brand pullRequestNumber reviewRound

autoSolveRevisionPrompt :: WorkflowConfig -> Maybe FilePath -> Repository -> SolverBrand -> Int -> Int -> Text
autoSolveRevisionPrompt config configPath repository brand pullRequestNumber reviewRound =
  Text.unlines
    ( [ "Kanban received CHANGES_REQUESTED for PR #" <> showText pullRequestNumber <> " in review round " <> showText reviewRound <> ".",
        "Resume the existing solve context and run " <> commandName "pr-revise" <> " for PR #" <> showText pullRequestNumber <> ".",
        "Use the canonical revise-and-rereview workflow: act only on a current canonical CHANGES_REQUESTED verdict for this head, rerouting stale feedback through canonical rereview before editing; work only in a clean isolated worktree and never overwrite a concurrently updated head; after pushing, wait for required CI on the pushed head, then invoke exactly one canonical PR rereview.",
        "Never merge, and leave "
          <> config.approvalLabel
          <> ", "
          <> config.changesRequestedLabel
          <> ", and reviewed:revised to the canonical review coordinator."
      ]
        <> configLines
    )
  where
    commandName name = if brand == CodexSolver then "$" <> name else "/" <> name
    -- Explicit --repo always accompanies pr-revise, not only when a custom
    -- --config is set: Kanban's own resolved repository (which may come
    -- from an explicit --repo override, e.g. reviewing upstream from a fork
    -- checkout) must never be silently re-derived by pr-revise from the
    -- checkout's configured remote instead.
    configLines =
      [ "Pass --repo " <> repository.repositoryOwner <> "/" <> repository.repositoryName <> " to " <> commandName "pr-revise" <> " so it resolves the same repository as this dashboard."
      ]
        <> case configPath of
          Nothing -> []
          Just path -> ["Pass --config " <> Text.pack path <> " to " <> commandName "pr-revise" <> " so it resolves this dashboard's configured workflow labels."]

autoSolveReviewLimit :: Int
autoSolveReviewLimit = 5

findSnapshotPullRequest :: RepoSnapshot -> Int -> Maybe PullRequest
findSnapshotPullRequest snapshot number =
  find ((== number) . (.pullRequestNumber)) snapshot.snapshotPullRequests

pullRequestHasLabel :: Text -> PullRequest -> Bool
pullRequestHasLabel labelName pullRequest =
  any ((== Text.toCaseFold labelName) . Text.toCaseFold . (.labelName)) pullRequest.pullRequestLabels

boardPullRequestNumbers :: Board -> Set Int
boardPullRequestNumbers board =
  Set.fromList
    [ pullRequest.pullRequestNumber
      | column <- allColumns,
        entry <- entriesForBoard board column,
        PullRequestItem pullRequest <- [entryItem entry]
    ]
