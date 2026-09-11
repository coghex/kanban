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
import Kanban.UI.Board (trackerHeaderText)
import Kanban.UI.Events (mutatesSelectedWork, readOnlyHistoryGate, settledSessionRefusal)
import Kanban.UI.Filter (readOnlyHistoryRefusal, readOnlyHistoryRefusalFor, refreshVisibleBoard)
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
import Spec.Support.App (testAppState)
import Spec.Support.Fixtures
  ( baseIssue,
    basePullRequest,
    detailsFixtureIssue,
    detailsFixtureSnapshot,
    detailsFixtureUpdatedAt,
    epoch,
    itemNumber,
    localSubIssue,
    nativeTrackerIssue,
    withSubIssuesLackingSummary
  )
import Spec.Support.Render (detailsText, renderDetailsForState)
import Test.Hspec

spec :: Spec
spec = do
  defaultsSpec
  admittedSpec
  progressSpec
  orderingSpec
  attentionSpec
  refusalSpec
  openAuthoritySpec
  addressingSpec
  detailsLinkSpec

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

  -- A child the criteria hid must leave the tracker rather than stay a
  -- permanently unreachable entry a group holds a row for. What must not
  -- follow it out is the progress its header reports: that pair is a fact
  -- about the retained data, and both children are open in it either way
  -- (§12).
  it "drops a child the criteria hid without moving its tracker's progress" $ do
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
    -- #872 is gone from the group, and the header reports what it did before.
    numbersIn filtered Issues `shouldBe` [871]
    map trackerProgress (entriesForBoard filtered Issues) `shouldBe` [Just (0, 2)]

  it "keeps a collapsed tracker's progress when the criteria leave it alone" $ do
    let snapshot = RepoSnapshot [approvedEpic 870 [871], baseIssue 871 []] [] epoch
        filtered =
          visibleFrom everyLifecycle {filterWorkflow = Set.singleton WorkflowApproved} snapshot Nothing
    map summarize (entriesForBoard filtered Issues) `shouldBe` [("header", 870)]
    map trackerProgress (entriesForBoard filtered Issues) `shouldBe` [Just (0, 1)]

  -- A group's membership is not confined to one column: an epic holds an
  -- unassigned child in Issues and an assigned one in Active. Repairing per
  -- column would report each column's own child as the only survivor and drop
  -- the other — still on screen — from the group it is drawn under.
  it "repairs a tracker spanning columns from every column at once" $ do
    let filtered =
          visibleFrom everyLifecycle {filterKind = Set.singleton KindIssues} crossColumnSnapshot Nothing
    numbersIn filtered Issues `shouldBe` [871]
    numbersIn filtered Active `shouldBe` [872]
    -- Both children are still drawn, and both columns' headers report the one
    -- pair the retained data yields for the tracker they share.
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
    -- #871 left the group and stayed open, so it is still one of the two the
    -- header counts.
    map trackerProgress (entriesForBoard filtered Active) `shouldBe` [Just (0, 2)]
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
    map trackerProgress (entriesForBoard filtered Issues) `shouldBe` [Just (0, 2)]
    concat [entriesForBoard filtered column | column <- [Active, Reviewing, Done]] `shouldBe` []

  -- A child whose epic the criteria hide is sorted by its own number.
  it "sorts a demoted child among surviving groups by its own number" $ do
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
      `shouldBe` [("standalone", 871), ("tracked", 876)]

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

-- | #662. A tracker's completed/total pair is a fact about the retained data,
-- so it reads the same under every combination of criteria — while the
-- membership beside it goes on narrowing to what a view can reach (§12).
--
-- Every case asserts both halves: the pair that must not move, and the rows
-- and headers that must go on behaving as they did.
progressSpec :: Spec
progressSpec = describe "tracker progress across the criteria" $ do
  -- #662's own reproduction table, with the correction its review carried:
  -- the two rows whose #872 is open both read 0/2, and the two whose #872 has
  -- closed both read 1/2. Only #872's lifecycle moves the pair; unchecking
  -- Problems to hide it and checking Closed to draw it move nothing.
  it "reads one pair for a checklist group whatever the criteria admit" $ do
    let blockedChild = (baseIssue 872 []) {issueLabels = [Label "blocked" "b60205"]}
        openSide = RepoSnapshot [epicIssue 870 [871, 872], baseIssue 871 [], blockedChild] [] epoch
        closedSide = RepoSnapshot [epicIssue 870 [871, 872], baseIssue 871 []] [] epoch
        closedChildHistory = Just (CompletedHistory [closed (baseIssue 872 [])] [] epoch)
        hidden = visibleFrom withoutProblems openSide Nothing
        settled = visibleFrom everyLifecycle closedSide closedChildHistory
    -- #872 open, labelled blocked, and drawn.
    progressAcross (visibleFrom defaultFilterCriteria openSide Nothing) `shouldBe` [(0, 2)]
    -- #872 open, labelled blocked, and hidden by the workflow facet.
    progressAcross hidden `shouldBe` [(0, 2)]
    numbersIn hidden Issues `shouldBe` [871]
    -- #872 closed, retained as completed history, and not drawn.
    progressAcross (visibleFrom defaultFilterCriteria closedSide closedChildHistory) `shouldBe` [(1, 2)]
    -- #872 closed and drawn as a completed card.
    progressAcross settled `shouldBe` [(1, 2)]
    numbersIn settled Issues `shouldBe` [871, 872]

  -- The kind facet reaches a group's rows through its pull requests, and a
  -- checklist child the board knows only through one is where it used to move
  -- progress: 'deriveBoard' counts a pull request's linked issues as
  -- reachable, so the child stayed in the tracker until hiding pull requests
  -- took its only row away. No retained dataset holds #872's own issue, so it
  -- counts complete throughout — a linked pull request groups a child without
  -- establishing that child's lifecycle.
  it "keeps progress when the kind facet takes away a child's only row" $ do
    let snapshot =
          RepoSnapshot
            [epicIssue 870 [871, 872], baseIssue 871 []]
            [basePullRequest 880 [872] False []]
            epoch
        issuesOnly = defaultFilterCriteria {filterKind = Set.singleton KindIssues}
        drawn = visibleFrom defaultFilterCriteria snapshot Nothing
        withoutPullRequests = visibleFrom issuesOnly snapshot Nothing
    numbersIn drawn Reviewing `shouldBe` [880]
    trackerNumbers (entriesForBoard drawn Reviewing) `shouldBe` [Just 870]
    progressAcross drawn `shouldBe` [(1, 2)]
    entriesForBoard withoutPullRequests Reviewing `shouldBe` []
    numbersIn withoutPullRequests Issues `shouldBe` [871]
    progressAcross withoutPullRequests `shouldBe` [(1, 2)]

  -- Requirement 3's off-board reference, which goes on counting as complete:
  -- #999 was never fetched, so no retained dataset can report it open.
  it "counts a reference no retained dataset holds as complete" $ do
    let snapshot = RepoSnapshot [epicIssue 870 [871, 999], baseIssue 871 []] [] epoch
    progressAcross (visibleFrom defaultFilterCriteria snapshot Nothing) `shouldBe` [(1, 2)]
    progressAcross (visibleFrom everyLifecycle snapshot mixedHistory) `shouldBe` [(1, 2)]

  -- A checked box and a closed issue are two reasons for one child to be
  -- complete, not two completions.
  it "counts a child that is both checked and closed exactly once" $ do
    let snapshot = RepoSnapshot [markedEpic 870 [(871, True), (872, False)], baseIssue 872 []] [] epoch
        history = Just (CompletedHistory [closed (baseIssue 871 [])] [] epoch)
    progressAcross (visibleFrom defaultFilterCriteria snapshot history) `shouldBe` [(1, 2)]
    progressAcross (visibleFrom everyLifecycle snapshot history) `shouldBe` [(1, 2)]

  -- The lifecycle facet selects which generations a board is derived from, so
  -- a board drawn from the completed one alone holds no record of a
  -- checklist's open children. They are open in the retained data all the
  -- same, and the criteria that hid them say nothing about that.
  it "keeps an open child incomplete under a completed-history-only view" $ do
    let closedOnly = defaultFilterCriteria {filterLifecycle = Set.singleton LifecycleClosed}
        headerOnly = visibleFrom closedOnly childOnlySnapshot closedEpicHistory
    map summarize (entriesForBoard headerOnly Issues) `shouldBe` [("header", 810)]
    progressAcross headerOnly `shouldBe` [(0, 1)]
    -- The same tracker with its child drawn beside it reports the same pair.
    progressAcross (visibleFrom everyLifecycle childOnlySnapshot closedEpicHistory) `shouldBe` [(0, 1)]

  -- Requirement 4. GitHub already counts every sub-issue the tracker has, so
  -- nothing about a view may reach those numbers either.
  it "leaves a native tracker's reported counts alone under every facet" $ do
    let tracker = nativeTrackerIssue 870 [localSubIssue 871 False, localSubIssue 872 False] 1 3
        blockedChild = (baseIssue 872 []) {issueLabels = [Label "blocked" "b60205"]}
        snapshot = RepoSnapshot [tracker, baseIssue 871 [], blockedChild] [] epoch
        hidden = visibleFrom withoutProblems snapshot Nothing
    progressAcross (visibleFrom defaultFilterCriteria snapshot Nothing) `shouldBe` [(1, 3)]
    progressAcross hidden `shouldBe` [(1, 3)]
    numbersIn hidden Issues `shouldBe` [871]
    progressAcross (visibleFrom everyLifecycle snapshot mixedHistory) `shouldBe` [(1, 3)]

  -- The other native pair: the one derived from the relationships that did
  -- arrive when GitHub's summary did not. It is as much a dataset fact as the
  -- reported one, so the criteria may not move it either.
  it "leaves a native tracker's missing-summary fallback alone under every facet" $ do
    let tracker =
          withSubIssuesLackingSummary
            [localSubIssue 871 False, localSubIssue 872 False, localSubIssue 873 True]
            (baseIssue 870 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "Background only, with no child list."
              }
        blockedChild = (baseIssue 872 []) {issueLabels = [Label "blocked" "b60205"]}
        snapshot = RepoSnapshot [tracker, baseIssue 871 [], blockedChild] [] epoch
        history = Just (CompletedHistory [closed (baseIssue 873 [])] [] epoch)
        hidden = visibleFrom withoutProblems snapshot history
    progressAcross (visibleFrom defaultFilterCriteria snapshot history) `shouldBe` [(1, 3)]
    progressAcross hidden `shouldBe` [(1, 3)]
    numbersIn hidden Issues `shouldBe` [871]
    progressAcross (visibleFrom everyLifecycle snapshot history) `shouldBe` [(1, 3)]

  -- Requirement 1's spanning case read as one board rather than one column:
  -- every header the group draws, wherever it draws it, reports one pair.
  it "reads one pair in every column a spanning group appears in" $ do
    let across criteria = progressAcross (visibleFrom criteria crossColumnSnapshot Nothing)
    across defaultFilterCriteria `shouldBe` [(0, 2)]
    across everyLifecycle {filterKind = Set.singleton KindIssues} `shouldBe` [(0, 2)]
    across everyLifecycle {filterWorkflow = Set.singleton WorkflowApproved} `shouldBe` [(0, 2)]
    across withoutProblems `shouldBe` [(0, 2)]

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
              updatedAfter 900 (closedIssue 891),
              updatedAfter 300 (closedIssue 889)
            ]
            []
            epoch
        board = visibleFrom everyLifecycle snapshot (Just history)
    -- All live work leads, followed by completed groups in recency order.
    trackerNumbers (entriesForBoard board Issues)
      `shouldBe` [Just 870, Nothing, Just 890, Nothing, Just 880]
    numbersIn board Issues `shouldBe` [871, 879, 891, 889, 881]

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

  -- The deferred revision launch boundary is gone with the dashboard's own
  -- review backend (SAG-10): a review is dispatched to the repository host
  -- immediately, there is no queue of sessions waiting for a client to come
  -- up, and the read-only-history refusal is the registry's own
  -- 'Kanban.Action.Types.ActionTargetHistorical' — worded by the very
  -- 'readOnlyHistoryNotice' asserted above.

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

-- | Issue #647. An issue's linked pull requests are a property of the data
-- the session retains, so no criteria set may take one away.
--
-- Every case renders through the production
-- 'Kanban.UI.Details.detailsEnv' wiring rather than a hand-built environment.
-- The defect was exactly at that boundary — the overlay was handed
-- 'appVisibleBoard' and had nothing else to scan — so a renderer-only test
-- naming one board could not have caught it, and could not catch its return.
detailsLinkSpec :: Spec
detailsLinkSpec = describe "an issue's linked pull requests under the criteria" $ do
  it "lists both retained pull requests with the pull-request kind unchecked" $ do
    state <-
      detailsState
        detailsFixtureSnapshot
        Nothing
        defaultFilterCriteria {filterKind = Set.singleton KindIssues}
    -- The criteria really did take them off the view, so the section can only
    -- be answering from the retained generation.
    boardPullRequestNumbers state.appVisibleBoard `shouldBe` Set.empty
    linkedPullRequestsText state `shouldBe` Just "#823, #851"
    -- Requirement 4: tracker context still resolves against that same view.
    renderDetailsForState state (IssueItem detailsFixtureIssue)
      `shouldSatisfy` any (Text.isInfixOf "under #900")

  it "lists a pull request a workflow facet hid, without disturbing the tracker context" $ do
    let hidden = basePullRequest 861 [36] False [Label "reviewed:changes" "d93f0b"]
        snapshot = detailsFixtureSnapshot {snapshotPullRequests = [hidden]}
    -- Named rather than assumed: the facet the criteria below uncheck is the
    -- one this pull request is classified into, and it is a facet the issue
    -- and its tracker are not in, so only the pull request leaves the view.
    itemWorkflowFacet workflow (PullRequestItem hidden) `shouldBe` WorkflowChanges
    state <-
      detailsState
        snapshot
        Nothing
        defaultFilterCriteria {filterWorkflow = Set.delete WorkflowChanges everyFacetValue}
    boardPullRequestNumbers state.appVisibleBoard `shouldBe` Set.empty
    linkedPullRequestsText state `shouldBe` Just "#861"
    renderDetailsForState state (IssueItem detailsFixtureIssue)
      `shouldSatisfy` any (Text.isInfixOf "under #900")

  it "lists a merged pull request retained only as completed history, with Closed unchecked" $ do
    let merged = (basePullRequest 851 [36] False []) {pullRequestState = PullRequestMerged}
        snapshot = detailsFixtureSnapshot {snapshotPullRequests = []}
    state <- detailsState snapshot (Just (CompletedHistory [] [merged] epoch)) defaultFilterCriteria
    -- Closed is unchecked under the defaults, so that history reaches no
    -- column at all — and the link survives anyway.
    state.appFilterCriteria.filterLifecycle `shouldBe` Set.singleton LifecycleOpen
    boardPullRequestNumbers state.appVisibleBoard `shouldBe` Set.empty
    linkedPullRequestsText state `shouldBe` Just "#851"

  it "keeps listing it while that completed generation is stale rather than current" $ do
    let merged = (basePullRequest 851 [36] False []) {pullRequestState = PullRequestMerged}
        snapshot = detailsFixtureSnapshot {snapshotPullRequests = []}
    state <- detailsState snapshot (Just (CompletedHistory [] [merged] epoch)) defaultFilterCriteria
    -- §15 keeps a complete history exactly where it was when a later
    -- generation fails, and the overlay reads it on the same terms.
    linkedPullRequestsText state {appCompletedStatus = CompletedHistoryStale "generation failed"}
      `shouldBe` Just "#851"

  it "contributes nothing from a completed generation that is not retained" $ do
    state <- detailsState (detailsFixtureSnapshot {snapshotPullRequests = []}) Nothing defaultFilterCriteria
    linkedPullRequestsText state `shouldBe` Just "none"

  it "presents both retained generations as one ascending list" $ do
    let merged = (basePullRequest 700 [36] False []) {pullRequestState = PullRequestMerged}
    state <-
      detailsState
        detailsFixtureSnapshot
        (Just (CompletedHistory [] [merged] epoch))
        defaultFilterCriteria {filterKind = Set.singleton KindIssues}
    linkedPullRequestsText state `shouldBe` Just "#700, #823, #851"

-- | A dashboard holding one open generation and an optional completed one,
-- with the criteria applied by the production 'refreshVisibleBoard' rather
-- than by a board a test filtered itself.
detailsState :: RepoSnapshot -> Maybe CompletedHistory -> FilterCriteria -> IO AppState
detailsState snapshot history criteria = do
  state <- testAppState (deriveBoard workflow snapshot)
  pure
    ( refreshVisibleBoard
        state
          { appOpenSnapshot = Just snapshot,
            appCompletedHistory = history,
            appFilterCriteria = criteria,
            -- The instant the details fixtures' relative ages are quoted
            -- from, so the overlay's other sections read as they do elsewhere.
            appNow = addUTCTime (3 * 3600) detailsFixtureUpdatedAt
          }
    )

linkedPullRequestsText :: AppState -> Maybe Text
linkedPullRequestsText state =
  detailsText (renderDetailsForState state (IssueItem detailsFixtureIssue)) "Linked pull requests"

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

-- | An epic whose checklist names the given children in implementation order,
-- every box unchecked.
epicIssue :: Int -> [Int] -> Issue
epicIssue number children = markedEpic number [(child, False) | child <- children]

-- | The same, with each child's checkbox as its pair supplies it.
markedEpic :: Int -> [(Int, Bool)] -> Issue
markedEpic number children =
  (baseIssue number [])
    { issueLabels = [Label "epic" "5319e7"],
      issueBody =
        "## Children\n"
          <> Text.concat
            [ "- [" <> mark done <> "] #" <> showNumber child <> " — A" <> showNumber (order + 1) <> ": step\n"
              | (order, (child, done)) <- zip [0 :: Int ..] children
            ]
    }
  where
    mark done = if done then "x" else " "

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

-- | Every distinct completed/total pair the board's trackers report, over
-- every column and every row of a group.
--
-- Distinct rather than per row, because the question these cases ask is
-- whether one tracker reports one pair: a board whose columns disagree, or
-- whose group's rows disagree with its header, yields two.
progressAcross :: Board -> [(Int, Int)]
progressAcross board =
  Set.toList
    (Set.fromList [pair | column <- allBoardColumns, Just pair <- map trackerProgress (entriesForBoard board column)])

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

-- | The defaults with the Problems box unchecked, which is how a case hides
-- one @blocked@ child while leaving its epic and its siblings drawn.
withoutProblems :: FilterCriteria
withoutProblems = defaultFilterCriteria {filterWorkflow = Set.delete WorkflowProblems everyFacetValue}

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
            workerWorkflowConfig = defaultWorkflowConfig,
            workerAssignment = Nothing,
            workerExpectedTarget = Nothing,
            workerInvocation = Nothing
          },
      workerDescriptorSpecPath = "/tmp/worker-1.spec.json",
      workerDescriptorRosterPath = "/tmp/worker-1.roster.toml",
      workerDescriptorEventPath = "/tmp/worker-1.events.jsonl",
      workerDescriptorStatePath = "/tmp/worker-1.state.json",
      workerDescriptorAckPath = "/tmp/worker-1.ack",
      workerDescriptorLeasePath = "/tmp/worker-1.lease",
      workerDescriptorLeaseOwnerPath = "/tmp/worker-1.lease.owner",
      workerDescriptorPendingTerminationPath = "/tmp/worker-1.terminating",
      workerDescriptorHandoffPath = "/tmp/worker-1.handing-off",
      workerDescriptorCommandPath = "/tmp/worker-1.commands.jsonl",
      workerDescriptorCommandAckPath = "/tmp/worker-1.command-acks.jsonl"
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
