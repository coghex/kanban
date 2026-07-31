-- | Classifying a card into its column, and normalizing an epic's collapsed
-- selection.
module Spec.Board.Workflow (spec) where

import Data.List (findIndex)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (addUTCTime)
import Kanban.Domain
import Kanban.UI (normalizeCollapsedRow, normalizeSelectedRowsAfterToggle, visibleSelectionRows)
import Kanban.Workflow (deriveBoard, entryItem)
import Spec.Support.Fixtures
  ( baseIssue,
    basePullRequest,
    entryImplementationKey,
    epoch,
    fixtureBoard,
    fixtureStandaloneEntry,
    fixtureTrackedEntry,
    isTrackerHeaderEntry,
    itemNumber,
    zeroChildDiagnostics,
    zeroChildTracker
  )
import Test.Hspec

spec :: Spec
spec = do
  describe "workflow classification" $ do
    it "keeps linked issues visible while showing their pull requests as separate cards" $ do
      let snapshot = RepoSnapshot [baseIssue 1 [], baseIssue 2 [Assignee "agent"]] [basePullRequest 10 [1] False []] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [1]
      map (itemNumber . entryItem) (Map.findWithDefault [] Active columns) `shouldBe` [2]
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing columns) `shouldBe` [10]

    it "treats a truncated non-empty assignee connection as Active" $ do
      let issue = (baseIssue 1 []) {issueAssigneeOverflow = 1}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [issue] [] epoch False False)
      map (itemNumber . entryItem) (Map.findWithDefault [] Active columns) `shouldBe` [1]

    -- An assignee connection that never arrived is not evidence of nobody
    -- working on the issue, so it must not land in the column that presents
    -- it as unclaimed work waiting to be picked up.
    it "keeps an issue whose assignees GitHub never delivered out of the backlog column" $ do
      let issue = (baseIssue 1 []) {issueDataGaps = [AssigneesUnavailable]}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [issue] [] epoch False False)
      map (itemNumber . entryItem) (Map.findWithDefault [] Active columns) `shouldBe` [1]
      Map.findWithDefault [] Issues columns `shouldBe` []

    it "keeps draft approved pull requests in Reviewing" $ do
      let pullRequest = basePullRequest 10 [] True [Label "reviewed:approve" "00ff00"]
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [] [pullRequest] epoch False False)
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing columns) `shouldBe` [10]
      Map.findWithDefault [] Done columns `shouldBe` []

    it "classifies non-draft approved pull requests as Done" $ do
      let pullRequest = basePullRequest 10 [] False [Label "reviewed:approve" "00ff00"]
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [] [pullRequest] epoch False False)
      map (itemNumber . entryItem) (Map.findWithDefault [] Done columns) `shouldBe` [10]

    it "shows labeled trackers without children as empty headers" $ do
      let tracker = (baseIssue 12 []) {issueLabels = [Label "epic" "5319e7"]}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
      case Map.findWithDefault [] Issues columns of
        [TrackerHeader rendered] -> do
          rendered.trackerIssue.issueNumber `shouldBe` 12
          rendered.trackerTotal `shouldBe` 0
          rendered.trackerDiagnostics `shouldBe` [TrackerSectionMissing]
        entries -> expectationFailure ("unexpected issue entries: " <> show entries)

    -- §8: a configured tracker label keeps the issue out of the work cards
    -- however its checklist parsed. The one malformed row here is diagnosed
    -- and dropped, so the tracker reaches 'deriveBoard' with no children of
    -- its own while #3 falls back to Standalone per §17.
    it "keeps a tracker whose checklist parsed to nothing out of every column's work cards" $ do
      let snapshot = RepoSnapshot [zeroChildTracker, baseIssue 3 []] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
          workCards = filter (not . isTrackerHeaderEntry) (concat (Map.elems columns))
      map (itemNumber . entryItem) workCards `shouldBe` [3]
      case Map.findWithDefault [] Issues columns of
        [TrackerHeader rendered, standalone] -> do
          rendered.trackerIssue.issueNumber `shouldBe` 12
          rendered.trackerTotal `shouldBe` 0
          rendered.trackerDiagnostics `shouldBe` zeroChildDiagnostics
          standalone `shouldBe` Standalone (IssueItem (baseIssue 3 []))
        entries -> expectationFailure ("unexpected issue entries: " <> show entries)

    -- A childless header is structure, not work in progress, so it has no
    -- business competing for a slot in Active just because someone is
    -- assigned to the tracker issue.
    it "places an assigned zero-child tracker in Issues rather than Active" $ do
      let tracker = zeroChildTracker {issueAssignees = [Assignee "agent"]}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
      Map.findWithDefault [] Active columns `shouldBe` []
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [12]

    it "recognizes zero-child trackers by configured label rather than a hard-coded epic" $ do
      let config = defaultWorkflowConfig {trackerLabels = Set.singleton "tracker"}
          configured = zeroChildTracker {issueNumber = 20, issueLabels = [Label "tracker" "5319e7"]}
          Board columns = deriveBoard config (RepoSnapshot [configured, zeroChildTracker] [] epoch False False)
      case Map.findWithDefault [] Issues columns of
        [TrackerHeader rendered, epicLabelled] -> do
          rendered.trackerIssue.issueNumber `shouldBe` 20
          rendered.trackerDiagnostics `shouldBe` zeroChildDiagnostics
          -- "epic" is not configured here, so that issue is ordinary work.
          epicLabelled `shouldBe` Standalone (IssueItem zeroChildTracker)
        entries -> expectationFailure ("unexpected issue entries: " <> show entries)

    it "uses an Epic: title as a tracker fallback when the issue has no labels" $ do
      let tracker = (baseIssue 12 []) {issueTitle = "Epic: Legacy tracker"}
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
      Map.findWithDefault [] Issues columns `shouldSatisfy` \case [TrackerHeader _] -> True; _ -> False

    it "keeps an open tracker visible as a header when none of its children are on the live board" $ do
      let tracker =
            (baseIssue 12 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A1: Child outside the live board"
              }
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
      Map.findWithDefault [] Issues columns `shouldBe` [TrackerHeader (Tracker tracker 1 1 Map.empty [])]

    it "sorts standalone issues awaiting rereview ahead of tracker groups and problems" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A1: Tracked"
              }
          revised = (baseIssue 3 []) {issueLabels = [Label "ReViEwEd:ReViSeD" "8250DF"]}
          problem = (baseIssue 4 []) {issueLabels = [Label "blocked" "d73a4a"]}
          snapshot = RepoSnapshot [tracker, baseIssue 2 [], revised, problem] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [3, 2, 4]

    it "promotes tracker groups containing rereview issues and puts those children first" $ do
      let revisedTracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A1: First\n- [ ] #2 — A2: Revised"
              }
          ordinaryTracker =
            (baseIssue 200 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #3 — A1: Ordinary"
              }
          revised = (baseIssue 2 []) {issueLabels = [Label "reviewed:revised" "8250DF"]}
          snapshot = RepoSnapshot [revisedTracker, ordinaryTracker, baseIssue 1 [], revised, baseIssue 3 []] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [2, 1, 3]

    it "promotes groups whose tracker issue is awaiting rereview" $ do
      let problemTracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A1: Problem"
              }
          revisedTracker =
            (baseIssue 200 [])
              { issueLabels = [Label "epic" "5319e7", Label "reviewed:revised" "8250DF"],
                issueBody = "## Children\n- [ ] #2 — A1: Revised tracker child"
              }
          problem = (baseIssue 1 []) {issueLabels = [Label "blocked" "d73a4a"]}
          snapshot = RepoSnapshot [problemTracker, revisedTracker, problem, baseIssue 2 []] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [2, 1]

    it "groups tracker children in natural implementation order" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A10: Later\n- [ ] #1 — A2: Earlier"
              }
          snapshot = RepoSnapshot [tracker, baseIssue 1 [], baseIssue 2 []] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
          entries = Map.findWithDefault [] Issues columns
      map (itemNumber . entryItem) entries `shouldBe` [1, 2]
      map entryImplementationKey entries `shouldBe` [Just "A2", Just "A10"]

    it "inherits tracker membership through a PR's linked child issue" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Phase plan\n- [ ] #1 — B1: Child"
              }
          snapshot = RepoSnapshot [tracker, baseIssue 1 []] [basePullRequest 10 [1] False []] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      case Map.findWithDefault [] Reviewing columns of
        [Tracked trackingContext item] -> do
          itemNumber item `shouldBe` 10
          trackingContext.trackingPrimary.membershipChild.trackerChildImplementationKey `shouldBe` Just "B1"
        values -> expectationFailure ("unexpected reviewing entries: " <> show values)

    it "chooses the earliest implementation key for multi-tracked PRs" $ do
      let laterTracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — B1: Child"
              }
          earlierTracker =
            (baseIssue 200 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A2: Child"
              }
          snapshot = RepoSnapshot [laterTracker, earlierTracker, baseIssue 1 []] [basePullRequest 10 [1] False []] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      case Map.findWithDefault [] Reviewing columns of
        [Tracked trackingContext _] -> do
          trackingContext.trackingPrimary.membershipTracker.trackerIssue.issueNumber `shouldBe` 200
          map (.membershipTracker.trackerIssue.issueNumber) trackingContext.trackingAdditional `shouldBe` [100]
        values -> expectationFailure ("unexpected multi-tracked entries: " <> show values)

    -- attentionKey orders on two independent booleans (problem, approved)
    -- before age, so an item carrying both a changes-requested and an
    -- approval label sits in its own tier rather than collapsing into either
    -- one alone.
    it "orders standalone issues by all four problem/approved tiers, then by age within each tier" $ do
      let older = epoch
          newer = addUTCTime 3600 epoch
          problemLabel = Label "reviewed:changes" "d73a4a"
          approvedLabel = Label "reviewed:approve" "0e8a16"
          tiered number labels createdAt = (baseIssue number []) {issueLabels = labels, issueCreatedAt = createdAt}
          bothOld = tiered 1 [problemLabel, approvedLabel] older
          bothNew = tiered 2 [problemLabel, approvedLabel] newer
          problemOld = tiered 3 [problemLabel] older
          problemNew = tiered 4 [problemLabel] newer
          approvedOld = tiered 5 [approvedLabel] older
          approvedNew = tiered 6 [approvedLabel] newer
          neitherOld = tiered 7 [] older
          neitherNew = tiered 8 [] newer
          snapshot =
            RepoSnapshot
              [neitherNew, bothOld, approvedOld, problemNew, bothNew, neitherOld, approvedNew, problemOld]
              []
              epoch
              False
              False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [1, 2, 3, 4, 5, 6, 7, 8]

    -- classifyPullRequest routes a non-draft approved PR to Done regardless
    -- of its tier, which would split the four tiers across two columns.
    -- Keeping every fixture a draft holds them all in Reviewing (drafts stay
    -- there no matter their approval label), so the same four-tier,
    -- age-ordered assertion applies to pull requests too.
    it "orders standalone pull requests by all four problem/approved tiers, then by age within each tier" $ do
      let older = epoch
          newer = addUTCTime 3600 epoch
          approvedLabel = Label "reviewed:approve" "0e8a16"
          tiered number labels mergeState createdAt =
            (basePullRequest number [] True labels) {pullRequestMergeState = mergeState, pullRequestCreatedAt = createdAt}
          bothOld = tiered 1 [approvedLabel] MergeConflicting older
          bothNew = tiered 2 [approvedLabel] MergeConflicting newer
          problemOld = tiered 3 [] MergeConflicting older
          problemNew = tiered 4 [] MergeConflicting newer
          approvedOld = tiered 5 [approvedLabel] MergeClean older
          approvedNew = tiered 6 [approvedLabel] MergeClean newer
          neitherOld = tiered 7 [] MergeClean older
          neitherNew = tiered 8 [] MergeClean newer
          snapshot =
            RepoSnapshot
              []
              [neitherNew, bothOld, approvedOld, problemNew, bothNew, neitherOld, approvedNew, problemOld]
              epoch
              False
              False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Reviewing columns) `shouldBe` [1, 2, 3, 4, 5, 6, 7, 8]

    -- trackerGroupKey reads the same two booleans off a group's tracked
    -- children rather than the tracker issue itself, so the "both" tier here
    -- comes from two different children each contributing one flag.
    it "orders tracker groups by the four problem/approved tiers, then by the tracker's own age within a tier" $ do
      let older = epoch
          newer = addUTCTime 3600 epoch
          problemLabel = Label "reviewed:changes" "d73a4a"
          approvedLabel = Label "reviewed:approve" "0e8a16"
          tracker number createdAt childrenBody =
            (baseIssue number [])
              { issueLabels = [Label "epic" "5319e7"],
                issueCreatedAt = createdAt,
                issueBody = "## Children\n" <> childrenBody
              }
          bothTracker = tracker 100 older "- [ ] #10 — A1: Problem child\n- [ ] #11 — A2: Approved child"
          problemTracker = tracker 200 older "- [ ] #12 — A1: Problem child"
          approvedTracker = tracker 300 older "- [ ] #13 — A1: Approved child"
          neitherOldTracker = tracker 400 older "- [ ] #14 — A1: Ordinary child"
          neitherNewTracker = tracker 500 newer "- [ ] #15 — A1: Ordinary child"
          children =
            [ (baseIssue 10 []) {issueLabels = [problemLabel]},
              (baseIssue 11 []) {issueLabels = [approvedLabel]},
              (baseIssue 12 []) {issueLabels = [problemLabel]},
              (baseIssue 13 []) {issueLabels = [approvedLabel]},
              baseIssue 14 [],
              baseIssue 15 []
            ]
          snapshot =
            RepoSnapshot
              ([neitherNewTracker, approvedTracker, bothTracker, neitherOldTracker, problemTracker] <> children)
              []
              epoch
              False
              False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [10, 11, 12, 13, 14, 15]

    -- trackedChildKey ranks only rereview status ahead of checklist order;
    -- isProblem never enters it, so a later child carrying a blocked label
    -- must not jump ahead of an earlier, ordinary one.
    it "keeps a later problematic child in its natural implementation position rather than promoting it" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #1 — A1: Earlier\n- [ ] #2 — A2: Later problem"
              }
          problemChild = (baseIssue 2 []) {issueLabels = [Label "blocked" "d73a4a"]}
          snapshot = RepoSnapshot [tracker, baseIssue 1 [], problemChild] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [1, 2]

    -- sortOn is stable, so standalone issues sharing an identical attention
    -- key -- no labels, the same creation time -- keep the order the
    -- snapshot listed them in rather than picking up an incidental
    -- numeric or canonical-identity ordering.
    it "preserves snapshot input order for standalone issues with equal attention keys" $ do
      let snapshot = RepoSnapshot [baseIssue 7 [], baseIssue 3 [], baseIssue 9 []] [] epoch False False
          Board columns = deriveBoard defaultWorkflowConfig snapshot
      map (itemNumber . entryItem) (Map.findWithDefault [] Issues columns) `shouldBe` [7, 3, 9]

  describe "epic collapse selection normalization" $ do
    it "moves another column's remembered row to the tracker's first row there once collapse hides it" $ do
      let issuesEntries = [fixtureTrackedEntry 100 [] 1, fixtureTrackedEntry 100 [] 2]
          activeEntries = [fixtureTrackedEntry 100 [] 3, fixtureTrackedEntry 100 [] 4]
          board = fixtureBoard [(Issues, issuesEntries), (Active, activeEntries)]
          -- Active's remembered row is #4 (row 1), a non-first child of #100.
          selectedBeforeCollapse = Map.fromList [(Issues, 0), (Active, 1)]
          expandedAfterCollapse = Set.empty
      normalizeSelectedRowsAfterToggle expandedAfterCollapse board selectedBeforeCollapse
        `shouldBe` Map.fromList [(Issues, 0), (Active, 0)]

    it "leaves a column empty of that tracker at row zero" $ do
      let board = fixtureBoard [(Issues, [fixtureTrackedEntry 100 [] 1])]
      normalizeCollapsedRow Set.empty board Done 0 `shouldBe` 0

    it "does not move a selection under a still-expanded tracker, a standalone card, or an entry only additionally tracking the collapsed epic" $ do
      let activeEntries =
            [ fixtureTrackedEntry 200 [] 6, -- row 0: unrelated, still-expanded tracker
              fixtureTrackedEntry 200 [100] 7, -- row 1: primary tracker 200; 100 is only an additional membership
              fixtureStandaloneEntry 5 -- row 2: unrelated standalone card
            ]
          board = fixtureBoard [(Active, activeEntries)]
          expandedAfterCollapse = Set.singleton 200
      normalizeCollapsedRow expandedAfterCollapse board Active 0 `shouldBe` 0
      normalizeCollapsedRow expandedAfterCollapse board Active 1 `shouldBe` 1
      normalizeCollapsedRow expandedAfterCollapse board Active 2 `shouldBe` 2

    it "leaves every column's remembered row unchanged when expanding" $ do
      let issuesEntries = [fixtureTrackedEntry 100 [] 1, fixtureTrackedEntry 100 [] 2]
          activeEntries = [fixtureStandaloneEntry 5]
          board = fixtureBoard [(Issues, issuesEntries), (Active, activeEntries)]
          selected = Map.fromList [(Issues, 1), (Active, 0)]
          expandedAfterExpand = Set.singleton 100
      normalizeSelectedRowsAfterToggle expandedAfterExpand board selected `shouldBe` selected

    it "leaves the affected column's remembered row on a visible entry, so moveCard advances past the collapsed group instead of defaulting to the top" $ do
      let activeEntries =
            [ fixtureTrackedEntry 100 [] 3, -- row 0: first child of #100, the collapsed header row
              fixtureTrackedEntry 100 [] 4, -- row 1: stale remembered row, hidden by the collapse
              fixtureStandaloneEntry 5 -- row 2: next visible target after the collapsed group
            ]
          board = fixtureBoard [(Active, activeEntries)]
          expandedAfterCollapse = Set.empty
          normalizedRow = normalizeCollapsedRow expandedAfterCollapse board Active 1
          rows = visibleSelectionRows expandedAfterCollapse board Active
          currentPosition = maybe 0 id (findIndex (== normalizedRow) rows)
      normalizedRow `shouldBe` 0
      rows `shouldBe` [0, 2]
      currentPosition `shouldBe` 0
      (rows !! (currentPosition + 1)) `shouldBe` 2
