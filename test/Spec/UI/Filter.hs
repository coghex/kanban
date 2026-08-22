-- | What the filter criteria admit, how settled history renders once they
-- admit it, and what refuses to act on it.
--
-- Every question here is decided by a total function the @EventM@ arms only
-- project — 'visibleBoardFor' for the view, 'deriveBoard' for column and
-- order, 'readOnlyHistoryGate' and 'directMergeDecision' for the refusals — so
-- the whole matrix is settled without a terminal, a network, or a GitHub
-- account.
module Spec.UI.Filter (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (addUTCTime)
import Kanban.Domain
import Kanban.Drainer
  ( DirectMergeDecision (..),
    DrainerActivity (..),
    DrainerState (..),
    DrainerStatus (..),
    directMergeDecision,
  )
import Kanban.Filter
  ( FilterCriteria (..),
    KindFacet (..),
    LifecycleFacet (..),
    StructureFacet (..),
    WorkflowFacet (..),
    defaultFilterCriteria,
    everyFacetValue,
    itemWorkflowFacet,
    visibleBoardFor,
  )
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..))
import Kanban.Solve (ResumeProvenance (..), SolveWorkflow (..), SolverBrand (..))
import Kanban.Tracker (trackerFromIssue)
import Kanban.UI.AutoSolve (boardPullRequestNumbers)
import Kanban.Review (ReviewStage (..))
import Kanban.UI.Board (trackerHeaderText)
import Kanban.UI.Events (mutatesSelectedWork, readOnlyHistoryGate, settledSessionRefusal)
import Kanban.UI.Filter (readOnlyHistoryRefusal, readOnlyHistoryRefusalFor, refreshVisibleBoard)
import Kanban.UI.Review (deferredRevisionLaunches)
import Kanban.UI.Keys (BoardAction (..))
import Kanban.UI.Search (entriesFor, selectableRows)
import Kanban.UI.Selection (selectedEntry)
import Kanban.UI.Session (agentSessionSubject, locateBoardWork)
import Kanban.UI.Types
import Kanban.UI.Util (entriesForBoard, itemMetadata)
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerTask (..),
  )
import Kanban.Workflow (deriveBoard, entryItem, itemLifecycleBadge)
import Spec.Support.App (testAppState, testReviewSession)
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch, itemNumber)
import Test.Hspec

spec :: Spec
spec = do
  defaultsSpec
  admittedSpec
  orderingSpec
  attentionSpec
  refusalSpec
  openAuthoritySpec
  addressingSpec

-- ---------------------------------------------------------------------------

-- | Requirement 3. Under the defaults the application behaves exactly as it
-- did before a completed generation could reach a card at all.
defaultsSpec :: Spec
defaultsSpec = describe "the default filter criteria" $ do
  it "hides Closed and checks everything else" $ do
    defaultFilterCriteria.filterLifecycle `shouldBe` Set.singleton LifecycleOpen
    defaultFilterCriteria.filterKind `shouldBe` everyFacetValue
    defaultFilterCriteria.filterWorkflow `shouldBe` everyFacetValue
    defaultFilterCriteria.filterStructure `shouldBe` everyFacetValue

  it "leaves every column identical to the board derived without any history" $
    sequence_
      [ (column, entriesForBoard (visible openBoard mixedHistory) column)
          `shouldBe` (column, entriesForBoard (deriveBoard workflow openSnapshot) column)
        | column <- allBoardColumns
      ]

  it "admits the open board itself whatever history is in memory" $ do
    visible openBoard mixedHistory `shouldBe` openBoard
    visible openBoard Nothing `shouldBe` openBoard

  -- Requirement 1. Criteria are process-lifetime state, so recomputing the
  -- view a refresh or a publication produces cannot disturb them.
  it "leaves the criteria themselves untouched when the view is recomputed" $ do
    settled <- settledState
    (refreshVisibleBoard settled).appFilterCriteria `shouldBe` defaultFilterCriteria
    let admitted = admitClosed settled
    (refreshVisibleBoard admitted).appFilterCriteria `shouldBe` everyLifecycle
    (refreshVisibleBoard admitted).appVisibleBoard `shouldBe` admitted.appVisibleBoard

  -- Requirement 8's live case: the closed epic is simply not in the dataset,
  -- so its open child is a 'Standalone' card exactly as it is today.
  it "renders a closed epic's surviving open child as Standalone" $ do
    let board = visibleFrom defaultFilterCriteria childOnlySnapshot closedEpicHistory
    map summarize (entriesForBoard board Issues) `shouldBe` [("standalone", 811)]

-- ---------------------------------------------------------------------------

-- | Requirements 4, 5 and 8: where settled cards land once Closed is checked.
admittedSpec :: Spec
admittedSpec = describe "criteria admitting completed history" $ do
  it "renders closed issues in Issues however many assignees they kept" $ do
    let board = withClosed openBoard mixedHistory
    numbersIn board Issues `shouldBe` [800, 940, 941]
    -- #941 is closed with the assignee it was worked under still on it, which
    -- is Active's rule for live work and says nothing about history.
    numbersIn board Active `shouldBe` [801]

  it "renders closed and merged pull requests in Done and never in Reviewing" $ do
    let board = withClosed openBoard mixedHistory
    numbersIn board Reviewing `shouldBe` [820]
    numbersIn board Done `shouldBe` [830, 951, 950]

  -- The approval predicate does not decide this: a merged pull request that
  -- never carried an approval label still goes to Done, and so does a draft
  -- one that was closed unmerged.
  it "sends a settled pull request to Done whatever its draft or approval state" $ do
    let history = CompletedHistory [] [mergedPullRequest 960, closedDraftPullRequest 961] epoch
        board = withClosed openBoard (Just history)
    numbersIn board Reviewing `shouldBe` [820]
    -- Both settled at the same instant, so the stable tie-break decides.
    numbersIn board Done `shouldBe` [830, 960, 961]

  -- Requirement 4 and 5's badges, which §11 puts on the metadata row rather
  -- than in the heading search matches against.
  it "badges a settled card CLOSED or MERGED, and a live one not at all" $ do
    itemLifecycleBadge (IssueItem (closedIssue 940)) `shouldBe` Just "CLOSED"
    itemLifecycleBadge (PullRequestItem (closedPullRequest 950)) `shouldBe` Just "CLOSED"
    itemLifecycleBadge (PullRequestItem (mergedPullRequest 951)) `shouldBe` Just "MERGED"
    itemLifecycleBadge (IssueItem (baseIssue 800 [])) `shouldBe` Nothing
    itemMetadata epoch (IssueItem (closedIssue 940))
      `shouldBe` "CLOSED · unassigned · updated now"
    itemMetadata epoch (PullRequestItem (mergedPullRequest 951))
      `shouldBe` "MERGED · UNLINKED · agent → master · updated now"
    itemMetadata epoch (IssueItem (baseIssue 800 [])) `shouldBe` "unassigned · updated now"

  -- Requirement 8. The epic is closed and its child is open; admitting the
  -- history is what lets both reach tracker recognition together.
  it "keeps a completed tracker a tracker, grouping the open child it kept" $ do
    let board = visibleFrom everyLifecycle childOnlySnapshot closedEpicHistory
    map summarize (entriesForBoard board Issues) `shouldBe` [("tracked", 811)]
    trackerNumbers (entriesForBoard board Issues) `shouldBe` [Just 810]

  -- Requirement 8's badge. A header is built from the tracker rather than from
  -- a card, so it never passes through the metadata row the badge otherwise
  -- leads; it has to reach the header line itself, populated group or not.
  it "carries CLOSED on a completed epic's own header line" $ do
    let settledTracker = trackerFor (closed (epicIssue 810 [811]))
        liveTracker = trackerFor (epicIssue 870 [871])
    trackerHeaderText False True settledTracker
      `shouldBe` "▾ #810  Issue 810  CLOSED  0/1 complete"
    trackerHeaderText False False settledTracker
      `shouldBe` "▸ #810  Issue 810  CLOSED  0/1 complete"
    -- ASCII mode changes the disclosure glyph and nothing about the badge.
    trackerHeaderText True True settledTracker
      `shouldBe` "v #810  Issue 810  CLOSED  0/1 complete"
    -- A live epic's header is exactly what it always was.
    trackerHeaderText False True liveTracker
      `shouldBe` "▾ #870  Issue 870  0/1 complete"

  -- The other half of requirement 8, which is what makes requirement 3 true
  -- for this shape: hide the header and the child is the Standalone card the
  -- board renders today.
  it "falls the same child back to Standalone when the criteria hide its epic" $ do
    let hidden =
          visibleFrom
            everyLifecycle {filterWorkflow = Set.singleton WorkflowApproved}
            childOnlySnapshot
            (Just (CompletedHistory [approvedClosedEpic] [] epoch))
        shown =
          visibleFrom
            everyLifecycle {filterWorkflow = everyFacetValue}
            childOnlySnapshot
            (Just (CompletedHistory [approvedClosedEpic] [] epoch))
    -- The epic is approved and the child is not, so a workflow facet holding
    -- only Approved keeps the epic and drops the child; adding the child back
    -- regroups it.
    map summarize (entriesForBoard hidden Issues) `shouldBe` [("header", 810)]
    map summarize (entriesForBoard shown Issues) `shouldBe` [("tracked", 811)]

  -- A header counts the children it holds, so a child the criteria hid must
  -- leave the tracker rather than stay a permanently unreachable pending
  -- entry the header keeps counting (§12).
  it "folds a child the criteria hid into its tracker's checklist progress" $ do
    let snapshot = RepoSnapshot [approvedEpic 870 [871, 872], baseIssue 871 [], baseIssue 872 []] [] epoch
        -- Only #871 is approved, so an Approved-only workflow facet keeps the
        -- epic and that child while hiding #872.
        approvedChild = (baseIssue 871 []) {issueLabels = [Label "reviewed:approve" "0e8a16"]}
        narrowed = snapshot {snapshotIssues = [approvedEpic 870 [871, 872], approvedChild, baseIssue 872 []]}
        unfiltered = visibleFrom everyLifecycle narrowed Nothing
        filtered =
          visibleFrom everyLifecycle {filterWorkflow = Set.singleton WorkflowApproved} narrowed Nothing
    numbersIn unfiltered Issues `shouldBe` [871, 872]
    map trackerProgress (entriesForBoard unfiltered Issues) `shouldBe` [Just (0, 2), Just (0, 2)]
    -- #872 is gone, and the header no longer counts a row nothing draws.
    numbersIn filtered Issues `shouldBe` [871]
    map trackerProgress (entriesForBoard filtered Issues) `shouldBe` [Just (1, 2)]

  it "folds every child into progress when the criteria leave a tracker alone" $ do
    let snapshot = RepoSnapshot [approvedEpic 870 [871], baseIssue 871 []] [] epoch
        filtered =
          visibleFrom everyLifecycle {filterWorkflow = Set.singleton WorkflowApproved} snapshot Nothing
    map summarize (entriesForBoard filtered Issues) `shouldBe` [("header", 870)]
    map trackerProgress (entriesForBoard filtered Issues) `shouldBe` [Just (1, 1)]

  -- A group's membership is not confined to one column: an epic holds an
  -- unassigned child in Issues and an assigned one in Active. Repairing per
  -- column would report each column's own child as the only survivor and
  -- fold the other — still on screen — into completed progress.
  it "repairs a tracker spanning columns from every column at once" $ do
    let filtered =
          visibleFrom everyLifecycle {filterKind = Set.singleton KindIssues} crossColumnSnapshot Nothing
    numbersIn filtered Issues `shouldBe` [871]
    numbersIn filtered Active `shouldBe` [872]
    -- Both children are still drawn, so neither is folded into progress in
    -- either column, and both headers report the same tracker.
    map trackerProgress (entriesForBoard filtered Issues) `shouldBe` [Just (0, 2)]
    map trackerProgress (entriesForBoard filtered Active) `shouldBe` [Just (0, 2)]

  -- The other half of the same mistake: a group that lost its rows in one
  -- column but kept them in another must not sprout an orphan header there.
  it "draws no header in a column a spanning group merely lost its rows in" $ do
    let filtered =
          visibleFrom
            everyLifecycle {filterWorkflow = Set.singleton WorkflowApproved}
            crossColumnSnapshot
            Nothing
    -- Only #872, in Active, is approved. Issues lost its only child of the
    -- group and must show nothing rather than a second header for it.
    numbersIn filtered Active `shouldBe` [872]
    map trackerProgress (entriesForBoard filtered Active) `shouldBe` [Just (1, 2)]
    entriesForBoard filtered Issues `shouldBe` []

  it "draws exactly one header, in the leftmost column, when a spanning group loses every row" $ do
    let filtered =
          visibleFrom
            everyLifecycle {filterWorkflow = Set.singleton WorkflowApproved}
            spanningChangesSnapshot
            Nothing
    -- The epic is approved and both its children carry changes-requested, so
    -- the tracker survives with nothing under it in either column and is
    -- represented once rather than once per column it lost rows in.
    map summarize (entriesForBoard filtered Issues) `shouldBe` [("header", 870)]
    map trackerProgress (entriesForBoard filtered Issues) `shouldBe` [Just (2, 2)]
    concat [entriesForBoard filtered column | column <- [Active, Reviewing, Done]] `shouldBe` []

  -- A child whose epic the criteria hide is a standalone card, and §12 puts
  -- every group ahead of every standalone card.
  it "moves a demoted child behind the groups it no longer belongs to" $ do
    let snapshot =
          RepoSnapshot
            [ (epicIssue 870 [871]) {issueLabels = [Label "epic" "5319e7", Label "reviewed:changes" "b60205"]},
              baseIssue 871 [],
              approvedEpic 875 [876],
              baseIssue 876 []
            ]
            []
            epoch
        -- #870 carries changes-requested, so an Approved-or-Other facet hides
        -- that epic while keeping its child and the whole of #875's group.
        filtered =
          visibleFrom
            everyLifecycle {filterWorkflow = Set.fromList [WorkflowApproved, WorkflowOther]}
            snapshot
            Nothing
    map summarize (entriesForBoard filtered Issues)
      `shouldBe` [("tracked", 876), ("standalone", 871)]

  -- Values are ORed inside a facet and the facets ANDed, so an empty facet is
  -- a real empty result rather than an implicit reset.
  it "shows only settled work with Open unchecked, and nothing at all with neither" $ do
    let settledOnly = visibleWith everyLifecycle {filterLifecycle = Set.singleton LifecycleClosed} openBoard openSnapshot mixedHistory
        neither = visibleWith defaultFilterCriteria {filterLifecycle = Set.empty} openBoard openSnapshot mixedHistory
    numbersIn settledOnly Issues `shouldBe` [940, 941]
    concat [entriesForBoard neither column | column <- allBoardColumns] `shouldBe` []

  -- The workflow facet is exclusive by strongest-state precedence, which is
  -- what makes its four values exhaustive rather than overlapping.
  it "classifies each card into exactly one workflow category, strongest first" $ do
    itemWorkflowFacet workflow (IssueItem (labelled 1 ["reviewed:changes", "reviewed:approve"]))
      `shouldBe` WorkflowChanges
    itemWorkflowFacet workflow (IssueItem (labelled 2 ["blocked"])) `shouldBe` WorkflowProblems
    itemWorkflowFacet workflow (IssueItem (labelled 3 ["reviewed:approve"])) `shouldBe` WorkflowApproved
    itemWorkflowFacet workflow (IssueItem (labelled 4 [])) `shouldBe` WorkflowOther

-- ---------------------------------------------------------------------------

-- | Requirement 6. Implementation order stays authoritative inside a group,
-- and newest-updated ordering applies only to the settled blocks.
orderingSpec :: Spec
orderingSpec = describe "ordering with settled cards" $ do
  it "orders every child of a mixed group by implementation order, not by lifecycle" $ do
    let snapshot = RepoSnapshot [orderedEpic, baseIssue 862 []] [] epoch
        history = CompletedHistory [closedIssue 861, closedIssue 863] [] epoch
        board = visibleFrom everyLifecycle snapshot (Just history)
    numbersIn board Issues `shouldBe` [861, 862, 863]

  it "puts settled standalone cards after every open one, newest updated first" $ do
    let snapshot = RepoSnapshot [baseIssue 800 [], baseIssue 802 []] [] epoch
        history =
          CompletedHistory
            [updatedAfter 60 (closedIssue 940), updatedAfter 600 (closedIssue 941), updatedAfter 300 (closedIssue 942)]
            []
            epoch
        board = visibleFrom everyLifecycle snapshot (Just history)
    numbersIn board Issues `shouldBe` [800, 802, 941, 942, 940]

  -- Two wholly completed groups whose recency differs, which is what proves
  -- their relative order rather than only their placement after open groups.
  it "puts wholly completed groups after open ones, newest updated first" $ do
    let snapshot = RepoSnapshot [epicIssue 870 [871], baseIssue 871 [], baseIssue 879 []] [] epoch
        history =
          CompletedHistory
            [ closed (epicIssue 880 [881]),
              updatedAfter 120 (closedIssue 881),
              closed (epicIssue 890 [891]),
              updatedAfter 900 (closedIssue 891)
            ]
            []
            epoch
        board = visibleFrom everyLifecycle snapshot (Just history)
    -- The live group leads, then #890's group (updated 900s in) ahead of
    -- #880's (120s in), and the open standalone card sits between the group
    -- and standalone partitions exactly as §12 already places it.
    trackerNumbers (entriesForBoard board Issues)
      `shouldBe` [Just 870, Just 890, Just 880, Nothing]
    numbersIn board Issues `shouldBe` [871, 891, 881, 879]

  -- "Wholly completed" is a property of the whole group rather than of one
  -- column's slice of it: a live member anywhere keeps the group live.
  it "keeps a group holding any open member out of the settled block" $ do
    let snapshot = RepoSnapshot [baseIssue 811 [], baseIssue 879 []] [] epoch
        board = visibleFrom everyLifecycle snapshot closedEpicHistory
    -- #810 is closed but #811 is not, so the group stays ahead of the open
    -- standalone card rather than dropping behind it.
    trackerNumbers (entriesForBoard board Issues) `shouldBe` [Just 810, Nothing]
    numbersIn board Issues `shouldBe` [811, 879]

-- ---------------------------------------------------------------------------

-- | Requirement 7. A settled card is attention-neutral, and keeps the status
-- treatment its labels earned.
attentionSpec :: Spec
attentionSpec = describe "settled cards and attention" $ do
  it "never promotes itself out of the settled block, whatever it carries" $ do
    let snapshot = RepoSnapshot [baseIssue 800 []] [] epoch
        history =
          CompletedHistory
            [ updatedAfter 300 (labelledClosed 940 ["reviewed:revised"]),
              updatedAfter 200 (labelledClosed 941 ["blocked"]),
              updatedAfter 100 (labelledClosed 942 ["reviewed:approve"])
            ]
            []
            epoch
        board = visibleFrom everyLifecycle snapshot (Just history)
    -- The live card leads, and the three settled ones are ordered by recency
    -- rather than by the attention tiers those labels would otherwise buy.
    numbersIn board Issues `shouldBe` [800, 940, 941, 942]

  it "never promotes the group it belongs to" $ do
    let snapshot = RepoSnapshot [epicIssue 870 [871], baseIssue 871 [], epicIssue 875 [876, 877], baseIssue 876 []] [] epoch
        -- #877 is a settled, blocked, revised child of the later epic. If it
        -- promoted, #875's group would jump ahead of #870's.
        history = CompletedHistory [labelledClosed 877 ["blocked", "reviewed:revised"]] [] epoch
        board = visibleFrom everyLifecycle snapshot (Just history)
    trackerNumbers (entriesForBoard board Issues) `shouldBe` [Just 870, Just 875, Just 875]
    numbersIn board Issues `shouldBe` [871, 876, 877]

  it "keeps the workflow category its labels earned" $ do
    itemWorkflowFacet workflow (IssueItem (labelledClosed 941 ["blocked"])) `shouldBe` WorkflowProblems
    itemWorkflowFacet workflow (IssueItem (labelledClosed 942 ["reviewed:approve"])) `shouldBe` WorkflowApproved

-- ---------------------------------------------------------------------------

-- | Requirement 9. Every settled mutating action refuses a completed card,
-- launches nothing, and leaves reading it alone.
refusalSpec :: Spec
refusalSpec = describe "read-only history refusals" $ do
  it "names exactly the mutating bindings" $
    filter mutatesSelectedWork [minBound .. maxBound]
      `shouldBe` [KillWorking, ReviewSelection, SolveSelection, AutoSolveSelection, MergeDoneCard]

  it "declines every mutating binding on a completed issue and a completed pull request" $ do
    settled <- settledState
    sequence_
      [ (action, itemNumber item, readOnlyHistoryGate (selecting item settled) action)
          `shouldBe` (action, itemNumber item, Just (expectedNotice item))
        | action <- filter mutatesSelectedWork [minBound .. maxBound],
          item <- [IssueItem (closedIssue 940), PullRequestItem (mergedPullRequest 951)]
      ]

  it "declines them from a details overlay held open on a settled card too" $ do
    settled <- settledState
    let overlaid item = (admitClosed settled) {appOverlay = Just (DetailsOverlay item)}
    sequence_
      [ readOnlyHistoryGate (overlaid item) action `shouldBe` Just (expectedNotice item)
        | action <- filter mutatesSelectedWork [minBound .. maxBound],
          item <- [IssueItem (closedIssue 940), PullRequestItem (mergedPullRequest 951)]
      ]

  it "leaves every reading binding alone, and the card itself selectable" $ do
    settled <- settledState
    let selected = selecting (IssueItem (closedIssue 940)) settled
    sequence_
      [ (action, readOnlyHistoryGate selected action) `shouldBe` (action, Nothing)
        | action <- filter (not . mutatesSelectedWork) [minBound .. maxBound]
      ]
    (entryItem <$> selectedEntry selected) `shouldBe` Just (IssueItem (closedIssue 940))

  -- The launch boundary. A chooser, an overlay, and a reusable session each
  -- hold an item captured before a refresh, so the refusal is re-asked
  -- against the newest completed generation rather than trusted from it.
  it "refuses an item that was live when it was captured and has since settled" $ do
    settled <- settledState
    readOnlyHistoryRefusal settled (IssueItem (baseIssue 940 []))
      `shouldBe` Just (expectedNotice (IssueItem (closedIssue 940)))
    plain <- testAppState openBoard
    readOnlyHistoryRefusal plain (IssueItem (baseIssue 940 [])) `shouldBe` Nothing

  -- The processes overlay reaches every kill route without going through a
  -- card, so it has to ask the same question keyed by session identity — and
  -- a persistent worker names its target only through the task it was
  -- created for.
  it "refuses every processes-overlay row whose work has settled" $ do
    settled <- settledState
    sequence_
      [ (label, settledSessionRefusal settled reference) `shouldBe` (label, Just notice)
        | (label, reference, notice) <-
            [ ("solve" :: String, SolveAgent 940, expectedNotice (IssueItem (closedIssue 940))),
              ("review", ReviewAgent 941, expectedNotice (IssueItem (closedIssue 941))),
              ("pull request", PullRequestAgent 951, expectedNotice (PullRequestItem (mergedPullRequest 951)))
            ]
      ]
    sequence_
      [ settledSessionRefusal settled reference `shouldBe` Nothing
        | reference <- [SolveAgent 800, ReviewAgent 801, PullRequestAgent 820, PullRequestAgent 830]
      ]

  it "resolves a persistent worker's row through the task it was created for" $ do
    settled <- settledState
    let solveWorker = withWorker (solveWorkerOn 940) settled
        pullRequestWorker = withWorker (pullRequestWorkerOn 951) settled
        liveWorker = withWorker (solveWorkerOn 800) settled
    agentSessionSubject solveWorker (WorkerAgent testWorkerId) `shouldBe` Just (IssueId 940)
    agentSessionSubject pullRequestWorker (WorkerAgent testWorkerId) `shouldBe` Just (PullRequestId 951)
    settledSessionRefusal solveWorker (WorkerAgent testWorkerId)
      `shouldBe` Just (expectedNotice (IssueItem (closedIssue 940)))
    settledSessionRefusal pullRequestWorker (WorkerAgent testWorkerId)
      `shouldBe` Just (expectedNotice (PullRequestItem (mergedPullRequest 951)))
    settledSessionRefusal liveWorker (WorkerAgent testWorkerId) `shouldBe` Nothing
    -- A worker no longer registered names no work, so there is nothing left
    -- to refuse rather than a refusal invented for it.
    agentSessionSubject settled (WorkerAgent testWorkerId) `shouldBe` Nothing
    settledSessionRefusal settled (WorkerAgent testWorkerId) `shouldBe` Nothing

  -- A session overlay left open across a refresh is the other stale case: it
  -- goes on accepting input for work that has since settled, and its answer
  -- would resume a worker against history. The guard is on the shared session
  -- table, so no overlay kind can skip it — and it covers Ctrl-C as well as
  -- Enter, because §8 refuses every termination boundary and not only the
  -- board's kill binding.
  it "refuses to resume any session overlay whose work has settled" $ do
    settled <- settledState
    sequence_
      [ (label, readOnlyHistoryRefusalFor settled subject) `shouldBe` (label, Just notice)
        | (label, subject, notice) <-
            [ ("solve" :: String, IssueId 940, expectedNotice (IssueItem (closedIssue 940))),
              ("review", IssueId 941, expectedNotice (IssueItem (closedIssue 941))),
              ("pull request", PullRequestId 951, expectedNotice (PullRequestItem (mergedPullRequest 951)))
            ]
      ]
    -- Live work still resumes.
    sequence_
      [ readOnlyHistoryRefusalFor settled subject `shouldBe` Nothing
        | subject <- [IssueId 800, IssueId 801, PullRequestId 820, PullRequestId 830]
      ]

  -- The deferred launch boundary. A revision session is created while the
  -- review backend is still starting, so the turn it is waiting for is
  -- started an arbitrary time later — long enough for a refresh to settle the
  -- issue underneath it.
  it "starts no deferred revision turn for an issue that settled while the backend started" $ do
    settled <- settledState
    let waiting number = withRevisionSession number settled
        (liveLaunches, settledLaunches) = deferredRevisionLaunches (waiting 800)
        (staleLaunches, staleRefusals) = deferredRevisionLaunches (waiting 940)
    -- The issue is still live, so its turn is started and nothing refused.
    map (.issueNumber) liveLaunches `shouldBe` [800]
    settledLaunches `shouldBe` []
    -- The issue settled while the backend was starting, so no turn is
    -- started — and the session is refused rather than left waiting for one.
    staleLaunches `shouldBe` []
    staleRefusals `shouldBe` [(940, expectedNotice (IssueItem (closedIssue 940)))]

  it "leaves a revision session that already has its turn alone" $ do
    settled <- settledState
    let running = withRunningRevisionSession 940 settled
    deferredRevisionLaunches running `shouldBe` ([], [])

  -- The merge chain, refused at the launch decision itself rather than only
  -- at the key press: it outranks the wrong-kind, in-flight and
  -- drainer-state answers this same function would otherwise give.
  it "refuses a settled card at the direct-merge decision, ahead of every other cause" $ do
    directMergeDecision workflow Nothing idleDrainer (Just (PullRequestItem (mergedPullRequest 951)))
      `shouldBe` RefuseDirectMerge (expectedNotice (PullRequestItem (mergedPullRequest 951)))
    directMergeDecision workflow Nothing idleDrainer (Just (IssueItem (closedIssue 940)))
      `shouldBe` RefuseDirectMerge (expectedNotice (IssueItem (closedIssue 940)))
    directMergeDecision workflow (Just 5) busyDrainer (Just (PullRequestItem (mergedPullRequest 951)))
      `shouldBe` RefuseDirectMerge (expectedNotice (PullRequestItem (mergedPullRequest 951)))

  it "still merges an approved live pull request" $
    directMergeDecision workflow Nothing idleDrainer (Just (PullRequestItem approvedLivePullRequest))
      `shouldBe` RunDirectMerge 830

-- ---------------------------------------------------------------------------

-- | Requirement 10. Live workflow behavior reads open data, so turning Closed
-- on changes nothing about any of it.
openAuthoritySpec :: Spec
openAuthoritySpec = describe "the open-only authority" $ do
  it "leaves the autosolve baseline identical with Closed admitted" $ do
    hidden <- settledState
    let admitted = admitClosed hidden
    boardPullRequestNumbers admitted.appBoard `shouldBe` boardPullRequestNumbers hidden.appBoard
    boardPullRequestNumbers admitted.appBoard `shouldBe` Set.fromList [820, 830]

  it "leaves worker and session item resolution identical with Closed admitted" $ do
    hidden <- settledState
    let admitted = admitClosed hidden
    admitted.appBoard `shouldBe` hidden.appBoard
    -- The settled pull request is admitted to the view and stays absent from
    -- the authority those resolutions read.
    numbersIn admitted.appVisibleBoard Done `shouldBe` [830, 951, 950]
    locateBoardWork admitted.appBoard (PullRequestId 951) `shouldBe` Nothing
    locateBoardWork hidden.appBoard (PullRequestId 951) `shouldBe` Nothing
    sequence_
      [ locateBoardWork admitted.appBoard target `shouldBe` locateBoardWork hidden.appBoard target
        | target <- [IssueId 800, IssueId 801, IssueId 940, PullRequestId 820, PullRequestId 830]
      ]

-- ---------------------------------------------------------------------------

-- | Requirement 11. No visible row resolves to a different entry, at every
-- criteria combination.
addressingSpec :: Spec
addressingSpec = describe "row addressing under criteria" $
  it "resolves every selectable row to the entry drawn there" $ do
    settled <- settledState
    sequence_
      [ (describeCriteria criteria, column, row, selectedEntry seated)
          `shouldBe` (describeCriteria criteria, column, row, Just drawn)
        | criteria <- criteriaCombinations,
          let state = refreshVisibleBoard settled {appFilterCriteria = criteria},
          column <- allBoardColumns,
          (row, drawn) <- zip [0 ..] (entriesFor state column),
          row `elem` selectableRows state column,
          let seated =
                state
                  { appSelectedColumn = column,
                    appSelectedRows = Map.insert column row state.appSelectedRows
                  }
      ]

-- ---------------------------------------------------------------------------
-- Fixtures

-- | The same workflow configuration 'testAppState' holds, so a board derived
-- here and one the dashboard recomputes cannot disagree.
workflow :: WorkflowConfig
workflow = defaultWorkflowConfig

allBoardColumns :: [BoardColumn]
allBoardColumns = [minBound .. maxBound]

-- | The open generation every case starts from: a backlog issue, an assigned
-- one, a pull request under review, and an approved one in Done.
openSnapshot :: RepoSnapshot
openSnapshot =
  RepoSnapshot
    [baseIssue 800 [], baseIssue 801 [Assignee "agent"]]
    [basePullRequest 820 [] False [], approvedLivePullRequest]
    epoch

openBoard :: Board
openBoard = deriveBoard workflow openSnapshot

approvedLivePullRequest :: PullRequest
approvedLivePullRequest = basePullRequest 830 [] False [Label "reviewed:approve" "0e8a16"]

-- | Two closed issues — one still carrying the assignee it was worked under —
-- a closed pull request, and a merged one. The merged one is the more
-- recently updated of the two, which is the order Done must put them in.
mixedHistory :: Maybe CompletedHistory
mixedHistory =
  Just
    ( CompletedHistory
        [closedIssue 940, (closedIssue 941) {issueAssignees = [Assignee "agent"]}]
        [closedPullRequest 950, updatedPullRequestAfter 300 (mergedPullRequest 951)]
        epoch
    )

-- | The child of an epic that closed ahead of it, which is the shape
-- requirement 8 turns on.
childOnlySnapshot :: RepoSnapshot
childOnlySnapshot = RepoSnapshot [baseIssue 811 []] [] epoch

closedEpicHistory :: Maybe CompletedHistory
closedEpicHistory = Just (CompletedHistory [closed (epicIssue 810 [811])] [] epoch)

approvedClosedEpic :: Issue
approvedClosedEpic =
  (closed (epicIssue 810 [811])) {issueLabels = [Label "epic" "5319e7", Label "reviewed:approve" "0e8a16"]}

-- | An epic whose checklist names the given children in implementation order.
epicIssue :: Int -> [Int] -> Issue
epicIssue number children =
  (baseIssue number [])
    { issueLabels = [Label "epic" "5319e7"],
      issueBody =
        "## Children\n"
          <> Text.concat
            [ "- [ ] #" <> showNumber child <> " — A" <> showNumber (order + 1) <> ": step\n"
              | (order, child) <- zip [0 :: Int ..] children
            ]
    }

-- | Three children in implementation order, the outer two of which a case
-- then closes.
orderedEpic :: Issue
orderedEpic = epicIssue 860 [861, 862, 863]

-- | An epic the approval predicate admits, so a workflow facet can keep it
-- while hiding one of its children.
approvedEpic :: Int -> [Int] -> Issue
approvedEpic number children =
  (epicIssue number children)
    { issueLabels = [Label "epic" "5319e7", Label "reviewed:approve" "0e8a16"]
    }

-- | One epic whose two children sit in different columns: #871 is unassigned
-- and lands in Issues, #872 is assigned and lands in Active. Only #872 is
-- approved, which is what lets a workflow facet keep one column's child while
-- dropping the other's.
crossColumnSnapshot :: RepoSnapshot
crossColumnSnapshot =
  RepoSnapshot
    [ approvedEpic 870 [871, 872],
      baseIssue 871 [],
      (baseIssue 872 [Assignee "agent"]) {issueLabels = [Label "reviewed:approve" "0e8a16"]}
    ]
    []
    epoch

-- | The same two-column group with both children carrying changes-requested,
-- so an Approved-only facet keeps the epic and hides every row of it.
spanningChangesSnapshot :: RepoSnapshot
spanningChangesSnapshot =
  RepoSnapshot
    [ approvedEpic 870 [871, 872],
      (baseIssue 871 []) {issueLabels = [Label "reviewed:changes" "b60205"]},
      (baseIssue 872 [Assignee "agent"]) {issueLabels = [Label "reviewed:changes" "b60205"]}
    ]
    []
    epoch

-- | The tracker one epic issue yields, for the header line it draws.
trackerFor :: Issue -> Tracker
trackerFor issue = case trackerFromIssue workflow issue of
  Just tracker -> tracker
  Nothing -> error ("fixture issue #" <> show issue.issueNumber <> " is not a tracker")

-- | The completed/total an entry's own tracker reports, if it has one.
trackerProgress :: ColumnEntry -> Maybe (Int, Int)
trackerProgress (Tracked tracking _) = Just (progress tracking.trackingPrimary.membershipTracker)
  where
    progress tracker = (tracker.trackerCompleted, tracker.trackerTotal)
trackerProgress (TrackerHeader tracker) = Just (tracker.trackerCompleted, tracker.trackerTotal)
trackerProgress (Standalone _) = Nothing

closed :: Issue -> Issue
closed issue = issue {issueState = IssueClosed}

closedIssue :: Int -> Issue
closedIssue number = closed (baseIssue number [])

labelled :: Int -> [Text] -> Issue
labelled number names = (baseIssue number []) {issueLabels = [Label name "cccccc" | name <- names]}

labelledClosed :: Int -> [Text] -> Issue
labelledClosed number names = closed (labelled number names)

closedPullRequest :: Int -> PullRequest
closedPullRequest number = (basePullRequest number [] False []) {pullRequestState = PullRequestClosed}

mergedPullRequest :: Int -> PullRequest
mergedPullRequest number = (basePullRequest number [] False []) {pullRequestState = PullRequestMerged}

closedDraftPullRequest :: Int -> PullRequest
closedDraftPullRequest number = (basePullRequest number [] True []) {pullRequestState = PullRequestClosed}

updatedAfter :: Int -> Issue -> Issue
updatedAfter seconds issue = issue {issueUpdatedAt = addUTCTime (fromIntegral seconds) epoch}

updatedPullRequestAfter :: Int -> PullRequest -> PullRequest
updatedPullRequestAfter seconds pullRequest =
  pullRequest {pullRequestUpdatedAt = addUTCTime (fromIntegral seconds) epoch}

idleDrainer :: DrainerStatus
idleDrainer = DrainerStatus DrainerOff "off" DrainerServiceStopped Nothing

busyDrainer :: DrainerStatus
busyDrainer = DrainerStatus DrainerOn "running" DrainerServiceRunning Nothing

everyLifecycle :: FilterCriteria
everyLifecycle = defaultFilterCriteria {filterLifecycle = everyFacetValue}

visible :: Board -> Maybe CompletedHistory -> Board
visible board = visibleWith defaultFilterCriteria board openSnapshot

withClosed :: Board -> Maybe CompletedHistory -> Board
withClosed board = visibleWith everyLifecycle board openSnapshot

-- | The visible board for a snapshot of this case's own, whose open board is
-- derived here so the two sides cannot disagree.
visibleFrom :: FilterCriteria -> RepoSnapshot -> Maybe CompletedHistory -> Board
visibleFrom criteria snapshot = visibleWith criteria (deriveBoard workflow snapshot) snapshot

visibleWith :: FilterCriteria -> Board -> RepoSnapshot -> Maybe CompletedHistory -> Board
visibleWith criteria board snapshot history =
  visibleBoardFor workflow criteria board (Just snapshot) history

-- | A dashboard holding both generations, with the history hidden.
settledState :: IO AppState
settledState = do
  state <- testAppState openBoard
  pure
    ( refreshVisibleBoard
        state {appOpenSnapshot = Just openSnapshot, appCompletedHistory = mixedHistory}
    )

admitClosed :: AppState -> AppState
admitClosed state = refreshVisibleBoard state {appFilterCriteria = everyLifecycle}

-- | The dashboard with one persistent worker registered, which is the only
-- processes-overlay row that names its work through a task rather than
-- through the number it is keyed by.
withWorker :: WorkerTask -> AppState -> AppState
withWorker task state =
  state {appWorkers = Map.singleton testWorkerId (testWorkerDescriptor task)}

testWorkerId :: WorkerId
testWorkerId = WorkerId "worker-1"

-- | A revision session in the state a backend that is still starting leaves
-- behind: created, waiting, and with no turn of its own yet.
withRevisionSession :: Int -> AppState -> AppState
withRevisionSession issueNumber = withReviewSessionDetail issueNumber Nothing

-- | The same session once its turn has been started, which a later backend
-- start must not launch a second time.
withRunningRevisionSession :: Int -> AppState -> AppState
withRunningRevisionSession issueNumber = withReviewSessionDetail issueNumber (Just "thread-1")

withReviewSessionDetail :: Int -> Maybe Text -> AppState -> AppState
withReviewSessionDetail issueNumber threadId state =
  state {appReviewSessions = Map.singleton issueNumber session}
  where
    base = testReviewSession (baseIssue issueNumber []) ReviewStarting
    session =
      base
        { sessionDetail =
            base.sessionDetail
              { reviewSessionStage = IssueRevision,
                reviewSessionThreadId = threadId
              }
        }

solveWorkerOn :: Int -> WorkerTask
solveWorkerOn issueNumber = SolveWorkerTaskKind (SolveWorkerTask issueNumber SolveOnly ClaudeSolver)

pullRequestWorkerOn :: Int -> WorkerTask
pullRequestWorkerOn number =
  PullRequestWorkerTaskKind (PullRequestWorkerTask number PullRequestClaude PullRequestReview)

testWorkerDescriptor :: WorkerTask -> WorkerDescriptor
testWorkerDescriptor task =
  WorkerDescriptor
    { workerDescriptorSpec =
        WorkerSpec
          { workerId = testWorkerId,
            workerRepository = Repository "/tmp/example-project" "example" "project",
            workerTask = task,
            workerExistingSession = Nothing,
            workerExistingLogPath = Nothing,
            workerResumeProvenance = ResumeAnswer,
            workerUserMessage = "",
            workerParent = Nothing,
            workerCreatedAt = epoch,
            workerMaxRuntimeSeconds = 60,
            workerConfigPath = Nothing,
            workerWorkflowConfig = defaultWorkflowConfig
          },
      workerDescriptorSpecPath = "/tmp/worker-1.spec.json",
      workerDescriptorRosterPath = "/tmp/worker-1.roster.toml",
      workerDescriptorEventPath = "/tmp/worker-1.events.jsonl",
      workerDescriptorStatePath = "/tmp/worker-1.state.json",
      workerDescriptorAckPath = "/tmp/worker-1.ack",
      workerDescriptorLeasePath = "/tmp/worker-1.lease",
      workerDescriptorLeaseOwnerPath = "/tmp/worker-1.lease.owner",
      workerDescriptorPendingTerminationPath = "/tmp/worker-1.terminating"
    }

-- | The dashboard with @item@ selected, at whichever column and row it drew.
-- Located by identity, because the card the board holds is the one the
-- generation delivered rather than the literal a case names.
selecting :: BoardItem -> AppState -> AppState
selecting item state = case located of
  Just (column, row) ->
    admitted
      { appSelectedColumn = column,
        appSelectedRows = Map.insert column row admitted.appSelectedRows
      }
  Nothing -> admitted
  where
    admitted = admitClosed state
    located = case matches of
      value : _ -> Just value
      [] -> Nothing
    matches =
      [ (column, row)
        | column <- allBoardColumns,
          (row, entry) <- zip [0 ..] (entriesFor admitted column),
          itemId (entryItem entry) == itemId item
      ]

expectedNotice :: BoardItem -> Text
expectedNotice (IssueItem issue) =
  "Issue #" <> showNumber issue.issueNumber <> " is closed; completed history is read-only"
expectedNotice (PullRequestItem pullRequest) =
  "PR #"
    <> showNumber pullRequest.pullRequestNumber
    <> " is "
    <> (if pullRequest.pullRequestState == PullRequestMerged then "merged" else "closed")
    <> "; completed history is read-only"

-- | Criteria that between them exercise every facet, including the empty ones
-- an edit can leave behind.
criteriaCombinations :: [FilterCriteria]
criteriaCombinations =
  [ defaultFilterCriteria,
    everyLifecycle,
    defaultFilterCriteria {filterLifecycle = Set.singleton LifecycleClosed},
    everyLifecycle {filterKind = Set.singleton KindIssues},
    everyLifecycle {filterKind = Set.singleton KindPullRequests},
    everyLifecycle {filterWorkflow = Set.singleton WorkflowApproved},
    everyLifecycle {filterWorkflow = Set.singleton WorkflowOther},
    everyLifecycle {filterStructure = Set.singleton StructureStandalone},
    everyLifecycle {filterStructure = Set.singleton StructureEpicGroups},
    defaultFilterCriteria {filterLifecycle = Set.empty},
    everyLifecycle {filterKind = Set.empty},
    everyLifecycle {filterWorkflow = Set.empty},
    everyLifecycle {filterStructure = Set.empty}
  ]

describeCriteria :: FilterCriteria -> String
describeCriteria criteria =
  show
    ( Set.toList criteria.filterLifecycle,
      Set.toList criteria.filterKind,
      Set.toList criteria.filterWorkflow,
      Set.toList criteria.filterStructure
    )

numbersIn :: Board -> BoardColumn -> [Int]
numbersIn board column = map (itemNumber . entryItem) (entriesForBoard board column)

summarize :: ColumnEntry -> (String, Int)
summarize entry = (shape entry, itemNumber (entryItem entry))
  where
    shape (Standalone _) = "standalone"
    shape (Tracked _ _) = "tracked"
    shape (TrackerHeader _) = "header"

trackerNumbers :: [ColumnEntry] -> [Maybe Int]
trackerNumbers = map primaryTracker
  where
    primaryTracker (Tracked tracking _) = Just tracking.trackingPrimary.membershipTracker.trackerIssue.issueNumber
    primaryTracker (TrackerHeader tracker) = Just tracker.trackerIssue.issueNumber
    primaryTracker (Standalone _) = Nothing

showNumber :: Int -> Text
showNumber = Text.pack . show
