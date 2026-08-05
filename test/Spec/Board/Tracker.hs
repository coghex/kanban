-- | Tracker headers and the checklists their bodies carry.
module Spec.Board.Tracker (spec) where

import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text
import Kanban.Config
import Kanban.Domain
import Kanban.GitHub (snapshotWarnings)
import Kanban.Tracker
  ( implementationSortKey,
    parseTrackerBody,
    parseTrackerChildren,
    renderTrackerDiagnostic,
    trackerDiagnosticsForIssue
  )
import Kanban.UI.Selection (normalizeCollapsedRow, refreshOverlay, visibleSelectionRows)
import Kanban.UI.Theme (itemHasAmberWarning, pendingAttr, trackerAttr, trackerHeaderAttribute)
import Kanban.UI.Types (Overlay (..))
import Kanban.Workflow (deriveBoard, entryItem)
import Spec.Support.Fixtures
  ( baseIssue,
    entryImplementationKey,
    epoch,
    fixtureTracker,
    foreignSubIssue,
    isStandaloneIssue,
    isTrackerHeaderEntry,
    itemNumber,
    localSubIssue,
    nativeTrackerIssue,
    testOptions,
    withSubIssues,
    withSubIssuesLackingSummary,
    zeroChildDiagnostics,
    zeroChildTracker
  )
import Spec.Support.Render (cardInterior, detailsRows, renderCard, renderDetails)
import Test.Hspec

spec :: Spec
spec = do
  -- A tracker with no children has no child card to be reached through, so
  -- the header itself has to carry every interaction §12 and §17 promise.
  describe "zero-child tracker headers" $ do
    it "is a keyboard focus target with no epic expanded" $ do
      let board = deriveBoard defaultWorkflowConfig (RepoSnapshot [zeroChildTracker, baseIssue 3 []] [] epoch False False)
      visibleSelectionRows Set.empty board Issues `shouldBe` [0, 1]
      normalizeCollapsedRow Set.empty board Issues 0 `shouldBe` 0

    it "draws amber while a tracker that parsed cleanly keeps the ordinary accent" $ do
      let Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [zeroChildTracker] [] epoch False False)
      case Map.findWithDefault [] Issues columns of
        [TrackerHeader rendered] -> trackerHeaderAttribute rendered `shouldBe` pendingAttr
        entries -> expectationFailure ("unexpected issue entries: " <> show entries)
      trackerHeaderAttribute (fixtureTracker 100) `shouldBe` trackerAttr

    it "keeps its details overlay open across a refresh while the tracker issue stays open" $ do
      let board = deriveBoard defaultWorkflowConfig (RepoSnapshot [zeroChildTracker] [] epoch False False)
          closed = deriveBoard defaultWorkflowConfig (RepoSnapshot [] [] epoch False False)
          overlay = Just (DetailsOverlay (IssueItem zeroChildTracker))
      refreshOverlay board overlay `shouldBe` (overlay, Nothing)
      refreshOverlay closed overlay `shouldBe` (Nothing, Just "Details closed because that item is no longer open")

    -- The overlay reads the diagnostics 'deriveBoard' attached to the header
    -- rather than re-parsing the body, so a tracker recognized only by a
    -- non-default configured label still explains itself here even though a
    -- re-parse under the default config would not recognize it at all.
    it "lists the diagnostics the derived tracker retained rather than a re-parse" $ do
      let config = defaultWorkflowConfig {trackerLabels = Set.singleton "tracker"}
          tracker = zeroChildTracker {issueLabels = [Label "tracker" "5319e7"]}
          board = deriveBoard config (RepoSnapshot [tracker] [] epoch False False)
      detailsRows (renderDetails board (IssueItem tracker)) "Tracker warnings"
        `shouldBe` map (("• " <>) . renderTrackerDiagnostic) zeroChildDiagnostics

  -- §12's second membership source. It applies only where the checklist
  -- yields nothing, and it changes what a tracker's progress counts, so the
  -- assertions below are about those two boundaries and the diagnostics that
  -- must stop being drawn once the second source answers.
  describe "native sub-issue membership" $ do
    let board issues pullRequests = deriveBoard defaultWorkflowConfig (RepoSnapshot issues pullRequests epoch False False)
        issueColumn (Board columns) = Map.findWithDefault [] Issues columns
        trackerOf (Tracked tracking _) = Just tracking.trackingPrimary.membershipTracker
        trackerOf (TrackerHeader tracker) = Just tracker
        trackerOf (Standalone _) = Nothing
        firstTrackingRow entry = take 1 (map Data.Text.strip (cardInterior (renderCard testOptions False entry 46)))

    it "renders a native-only tracker's local children in the order GitHub returned" $ do
      let tracker = nativeTrackerIssue 700 [localSubIssue 12 False, localSubIssue 10 False, localSubIssue 11 False] 0 3
          entries = issueColumn (board (tracker : [baseIssue number [] | number <- [10, 11, 12]]) [])
      map (itemNumber . entryItem) entries `shouldBe` [12, 10, 11]
      map entryImplementationKey entries `shouldBe` [Nothing, Nothing, Nothing]
      trackerDiagnosticsForIssue defaultWorkflowConfig tracker `shouldBe` []

    -- The positional label a keyless checklist child already gets. It is the
    -- child's place in GitHub's list, not an implementation key inferred from
    -- anything, which is what requirement 4 forbids.
    it "labels native children by their position in GitHub's list" $ do
      let tracker = nativeTrackerIssue 700 [localSubIssue 12 False, localSubIssue 10 False] 0 2
          entries = issueColumn (board (tracker : [baseIssue number [] | number <- [10, 12]]) [])
      concatMap firstTrackingRow entries `shouldBe` ["step 1 · tracker #700", "step 2 · tracker #700"]

    -- Precedence is decided on what the body parsed to, not on the children
    -- that survive visibility pruning: a checklist whose every child is off
    -- the board is still a checklist, and must not silently become native.
    it "keeps a checklist authoritative even once pruning has emptied it" $ do
      let tracker =
            withSubIssues
              [localSubIssue 10 False]
              0
              1
              (baseIssue 700 []) {issueLabels = [Label "epic" "5319e7"], issueBody = "## Children\n- [ ] #99 — A1: Off the board"}
          entries = issueColumn (board [tracker, baseIssue 10 []] [])
      entries `shouldSatisfy` any (isStandaloneIssue 10)
      case filter isTrackerHeaderEntry entries >>= maybe [] pure . trackerOf of
        [rendered] -> do
          rendered.trackerSource `shouldBe` ChecklistMembership
          (rendered.trackerCompleted, rendered.trackerTotal) `shouldBe` (1, 1)
        rendered -> expectationFailure ("unexpected tracker headers: " <> show rendered)

    -- GitHub counts every sub-issue it has, including the closed and the
    -- foreign ones, so the off-board completion adjustment checklist
    -- membership needs would push the displayed progress past the number
    -- GitHub reported.
    it "takes native progress from GitHub's summary and never re-counts an off-board child" $ do
      let tracker = nativeTrackerIssue 700 [localSubIssue 10 False, localSubIssue 11 False, localSubIssue 12 True] 1 3
      case issueColumn (board [tracker, baseIssue 10 []] []) >>= maybe [] pure . trackerOf of
        [rendered] -> do
          rendered.trackerSource `shouldBe` NativeMembership
          (rendered.trackerCompleted, rendered.trackerTotal) `shouldBe` (1, 3)
          Map.keys rendered.trackerChildren `shouldBe` [10]
        rendered -> expectationFailure ("unexpected trackers: " <> show rendered)

    it "never lets a cross-repository child claim the same-numbered local issue" $ do
      let tracker = nativeTrackerIssue 700 [foreignSubIssue 10 False] 0 1
          entries = issueColumn (board [tracker, baseIssue 10 []] [])
      entries `shouldSatisfy` any (isStandaloneIssue 10)
      case filter isTrackerHeaderEntry entries >>= maybe [] pure . trackerOf of
        [rendered] -> do
          Map.keys rendered.trackerChildren `shouldBe` []
          (rendered.trackerCompleted, rendered.trackerTotal) `shouldBe` (0, 1)
          rendered.trackerDiagnostics `shouldBe` []
        rendered -> expectationFailure ("unexpected tracker headers: " <> show rendered)

    it "keeps the empty-child-list diagnostic only when GitHub reported no sub-issues at all" $ do
      trackerDiagnosticsForIssue defaultWorkflowConfig (nativeTrackerIssue 700 [] 0 0)
        `shouldBe` [TrackerSectionMissing]

    -- A partial-error response can null the summary and leave the
    -- relationships, and those children still belong under their tracker: the
    -- alternative is scattering the group across the board over a missing
    -- count. Progress falls back to the relationships that did arrive rather
    -- than rendering 0/0 above visible children.
    it "keeps native children whose summary never arrived, and counts them" $ do
      let tracker =
            withSubIssuesLackingSummary
              [localSubIssue 10 False, localSubIssue 11 True]
              (baseIssue 700 []) {issueLabels = [Label "epic" "5319e7"], issueBody = "Background only, with no child list."}
          entries = issueColumn (board [tracker, baseIssue 10 []] [])
      map (itemNumber . entryItem) entries `shouldBe` [10]
      case entries >>= maybe [] pure . trackerOf of
        [rendered] -> do
          rendered.trackerSource `shouldBe` NativeMembership
          (rendered.trackerCompleted, rendered.trackerTotal) `shouldBe` (1, 2)
          rendered.trackerDiagnostics `shouldBe` []
        rendered -> expectationFailure ("unexpected trackers: " <> show rendered)
      -- The card still says the answer was incomplete.
      snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [tracker, baseIssue 10 []] [] epoch False False)
        `shouldSatisfy` any (Data.Text.isInfixOf "Issue #700: incomplete data")

    -- An answer that never arrived is an unverified absence. Reporting it as
    -- a tracker with no child list would present a fetch failure as a
    -- statement about the tracker's contents.
    it "does not diagnose a missing child list when GitHub's answer never arrived" $ do
      let tracker =
            (nativeTrackerIssue 700 [] 0 0)
              { issueSubIssues = SubIssuesUnreported,
                issueDataGaps = [SubIssuesUnavailable]
              }
      trackerDiagnosticsForIssue defaultWorkflowConfig tracker `shouldBe` []
      snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
        `shouldSatisfy` any (Data.Text.isInfixOf "Issue #700: incomplete data")

    -- Suppression is narrow: it removes the two diagnostics that say there is
    -- no child list, and nothing that reports malformed checklist content.
    it "keeps genuine malformed-checklist diagnostics under native membership" $ do
      let tracker =
            withSubIssues
              [localSubIssue 10 False]
              0
              1
              (baseIssue 700 []) {issueLabels = [Label "epic" "5319e7"], issueBody = "## Children\n- [?] #3 — A1: Malformed"}
      trackerDiagnosticsForIssue defaultWorkflowConfig tracker `shouldBe` [TrackerMalformedCheckbox 2]

    -- 'trackerDiagnosticsForIssue' feeds four independent surfaces, so
    -- suppression is asserted at all four rather than at whichever one is
    -- easiest to reach.
    it "stops warning at every diagnostic surface once native membership answers" $ do
      let native = nativeTrackerIssue 700 [localSubIssue 10 False] 0 1
          checklistless = (baseIssue 700 []) {issueLabels = [Label "epic" "5319e7"], issueBody = "Background only, with no child list."}
          bannerFor tracker = snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [tracker, baseIssue 10 []] [] epoch False False)
          cardRowsFor tracker = cardInterior (renderCard testOptions False (Standalone (IssueItem tracker)) 46)
          overlayRowsFor tracker = detailsRows (renderDetails (board [tracker, baseIssue 10 []] []) (IssueItem tracker)) "Tracker warnings"
          missingChecklists = Data.Text.isInfixOf "malformed or missing child checklists"
          trackerRow = Data.Text.isInfixOf "TRACKER ·"
      -- The refresh banner, the card's inline rows, the details overlay, and
      -- the amber styling, with the same tracker before and after GitHub's
      -- relationships arrive.
      bannerFor checklistless `shouldSatisfy` any missingChecklists
      bannerFor native `shouldNotSatisfy` any missingChecklists
      cardRowsFor checklistless `shouldSatisfy` any trackerRow
      cardRowsFor native `shouldNotSatisfy` any trackerRow
      overlayRowsFor checklistless `shouldSatisfy` not . null
      overlayRowsFor native `shouldBe` []
      itemHasAmberWarning defaultWorkflowConfig (IssueItem checklistless) `shouldBe` True
      itemHasAmberWarning defaultWorkflowConfig (IssueItem native) `shouldBe` False

  describe "tracker checklist parsing" $ do
    let keysUnderChildren rows = map (.trackerChildImplementationKey) (parseTrackerChildren [] ("## Children\n" <> rows))

    it "parses supported checkboxes, progress, and natural keys only in tracker sections" $ do
      let body =
            "## Related\n- [ ] #99 — A1: Ignore\n"
              <> "## Children\n### Phase A\n- [ ] #2 — **A10:** Later\n- [x] **#1 — A2: Earlier**\n"
              <> "External prerequisite:\n- [ ] #77 — A3: Ignore\n"
          children = parseTrackerChildren [] body
      map (.trackerChildIssueNumber) children `shouldBe` [2, 1]
      map (.trackerChildComplete) children `shouldBe` [False, True]
      map (.trackerChildImplementationKey) (sortOn implementationSortKey children) `shouldBe` [Just "A2", Just "A10"]

    -- The key occupies a fixed position in every documented form, so it is read
    -- there rather than found by scanning the item text for a key-shaped word.
    it "recognizes an implementation key only in the two documented key positions" $ do
      keysUnderChildren "- [ ] #756 — **A1:** Define the persistence contract.\n" `shouldBe` [Just "A1"]
      keysUnderChildren "- [ ] #742 — A1: Modal ownership with debug pass-through\n" `shouldBe` [Just "A1"]
      keysUnderChildren "- [x] **#88 — Data-driven location definitions**\n" `shouldBe` [Nothing]
      keysUnderChildren "- [x] **#1 — A2: Earlier**\n" `shouldBe` [Just "A2"]
      keysUnderChildren "- [ ] A1: #742 — Key ahead of the reference\n" `shouldBe` [Just "A1"]
      keysUnderChildren "- [ ] **A1:** #742 — Emphasized ahead of the reference\n" `shouldBe` [Just "A1"]
      keysUnderChildren "- [ ] _A1:_ #742 — Underscored ahead of the reference\n" `shouldBe` [Just "A1"]
      keysUnderChildren "- [ ] #742 - A1: ASCII hyphen separator\n" `shouldBe` [Just "A1"]
      keysUnderChildren "- [ ] #742 – A1: En dash separator\n" `shouldBe` [Just "A1"]
      -- The separator is part of the after-reference position, so a key that
      -- merely follows the reference is not in it.
      keysUnderChildren "- [ ] #742 A1: No separator after the reference\n" `shouldBe` [Nothing]

    it "leaves key-shaped words elsewhere in a child title keyless" $ do
      keysUnderChildren "- [x] **#88 — Move assets to S3 storage**\n" `shouldBe` [Nothing]
      keysUnderChildren "- [ ] #742 — Prepare the V2 save envelope\n" `shouldBe` [Nothing]
      keysUnderChildren "- [ ] #5 — Raise the macOS26 build floor\n" `shouldBe` [Nothing]
      keysUnderChildren "- [ ] #6 — Pin CI to GHC2024\n" `shouldBe` [Nothing]
      -- The after-reference position belongs to the leading reference alone; a
      -- later one embedded in the title must not open a second key position.
      keysUnderChildren "- [ ] #88 — Discuss #99 — A1: detail\n" `shouldBe` [Nothing]

    it "sorts keys naturally ahead of keyless children, which keep checklist order" $ do
      let body =
            "## Children\n"
              <> "- [ ] #1 — B1: Fourth key\n"
              <> "- [ ] #2 — Prepare the V2 save envelope\n"
              <> "- [ ] #3 — A10: Third key\n"
              <> "- [ ] #4 — Move assets to S3 storage\n"
              <> "- [ ] #5 — A1: First key\n"
              <> "- [ ] #6 — A2: Second key\n"
              <> "- [ ] #7 — A1: Ties the first key, later in the checklist\n"
          ordered = sortOn implementationSortKey (parseTrackerChildren [] body)
      map (.trackerChildImplementationKey) ordered
        `shouldBe` [Just "A1", Just "A1", Just "A2", Just "A10", Just "B1", Nothing, Nothing]
      map (.trackerChildIssueNumber) ordered `shouldBe` [5, 7, 6, 3, 1, 2, 4]

    it "reports structural checklist loss while retaining valid children" $ do
      let body = "## Children\n- [ ] #2 — A1: Valid\n- [ ] missing reference\n- [?] #3\n- [x] #2 — duplicate"
          (children, diagnostics) = parseTrackerBody [] body
      map (.trackerChildIssueNumber) children `shouldBe` [2]
      diagnostics
        `shouldBe` [ TrackerIssueReferenceMissing 3,
                     TrackerMalformedCheckbox 4,
                     TrackerDuplicateChild 5 2
                   ]

    it "keeps children from malformed rows standalone on the board" $ do
      let tracker =
            (baseIssue 100 [])
              { issueLabels = [Label "epic" "5319e7"],
                issueBody = "## Children\n- [ ] #2 — A1: Valid\n- [?] #3 — A2: Malformed"
              }
          Board columns = deriveBoard defaultWorkflowConfig (RepoSnapshot [tracker, baseIssue 2 [], baseIssue 3 []] [] epoch False False)
          entries = Map.findWithDefault [] Issues columns
      entries `shouldSatisfy` any (isStandaloneIssue 3)

    it "diagnoses a labeled tracker without a tracker section" $ do
      let body = "## Context\n- [ ] #2 — A1: Not authoritative"
          tracker = (baseIssue 100 []) {issueLabels = [Label "epic" "5319e7"], issueBody = body}
      snd (parseTrackerBody [] body) `shouldBe` [TrackerSectionMissing]
      snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [tracker] [] epoch False False)
        `shouldSatisfy` any (Data.Text.isInfixOf "1 tracker")

    it "recognizes a configured additional tracker-section heading" $ do
      let body = "## Milestones\n- [ ] #2 — A1: Valid"
      snd (parseTrackerBody [] body) `shouldBe` [TrackerSectionMissing]
      snd (parseTrackerBody ["Milestones"] body) `shouldBe` []
      map (.trackerChildIssueNumber) (parseTrackerChildren ["Milestones"] body) `shouldBe` [2]
      map (.trackerChildIssueNumber) (parseTrackerChildren [] body) `shouldBe` []

    it "recognizes a tracker heading that explicitly names children" $ do
      let body = "## Remaining core work — children filed\n- [ ] #2 — A1: Valid"
      map (.trackerChildIssueNumber) (parseTrackerChildren [] body) `shouldBe` [2]

    it "recognizes bare Phase, prefixed Phases, and Phase breakdown as tracker sections" $ do
      let childrenOf body = map (.trackerChildIssueNumber) (parseTrackerChildren [] body)
      childrenOf "## Phase\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Phases\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Phases (ordered)\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      let breakdown = "## Phase breakdown\n- [ ] #2 — A1: Valid"
      childrenOf breakdown `shouldBe` [2]
      snd (parseTrackerBody [] breakdown) `shouldBe` []

    it "keeps every documented heading form recognized: Children, Children (ordered), Phase plan, Phase 1, and Phase A" $ do
      let childrenOf body = map (.trackerChildIssueNumber) (parseTrackerChildren [] body)
      childrenOf "## Children\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Children (ordered)\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Phase plan\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Phase 1\n- [ ] #2 — A1: Valid" `shouldBe` [2]
      childrenOf "## Phase A\n- [ ] #2 — A1: Valid" `shouldBe` [2]

    it "does not recognize a heading that merely starts with the word phase, such as Phased rollout" $ do
      let body = "## Phased rollout\n- [ ] #2 — A1: Ignored"
      parseTrackerChildren [] body `shouldBe` []
      snd (parseTrackerBody [] body) `shouldBe` [TrackerSectionMissing]

    it "keeps every documented checklist format parsing around prose that merely opens with an excluded word" $ do
      let surrounded sentence =
            "## Children\n"
              <> sentence
              <> "\n- [ ] #756 — **A1:** Define the persistence contract.\n"
              <> "- [ ] #742 — A1: Modal ownership with debug pass-through\n"
              <> sentence
              <> "\n- [x] **#88 — Data-driven location definitions**\n"
          childrenOf body = map (.trackerChildIssueNumber) (parseTrackerChildren [] body)
      childrenOf (surrounded "Related discussion happens in #100.") `shouldBe` [756, 742, 88]
      childrenOf (surrounded "External prerequisite work already landed.") `shouldBe` [756, 742, 88]
      childrenOf (surrounded "Out of scope items are tracked elsewhere.") `shouldBe` [756, 742, 88]
      snd (parseTrackerBody [] (surrounded "Related discussion happens in #100.")) `shouldBe` []

    it "excludes checklists under bare, bold, and underscored excluded pseudo-headings" $ do
      let excludedBy label = "## Children\n- [ ] #1 — A1: Kept\n" <> label <> "\n- [ ] #99 — A2: Ignored\n"
          childrenOf body = map (.trackerChildIssueNumber) (parseTrackerChildren [] body)
      childrenOf (excludedBy "Related:") `shouldBe` [1]
      childrenOf (excludedBy "**Related:**") `shouldBe` [1]
      childrenOf (excludedBy "**Related**:") `shouldBe` [1]
      childrenOf (excludedBy "_Related:_") `shouldBe` [1]
      childrenOf (excludedBy "*External prerequisites:*") `shouldBe` [1]
      childrenOf (excludedBy "__Out of scope__") `shouldBe` [1]

    it "ends a pseudo-heading exclusion at the next pseudo-heading or a deeper real heading" $ do
      let resumedBy resumption =
            "## Children\n- [ ] #1 — A1: Kept\n**Related:**\n- [ ] #99 — Ignored\n"
              <> resumption
              <> "\n- [ ] #2 — A2: Kept\n"
          childrenOf body = map (.trackerChildIssueNumber) (parseTrackerChildren [] body)
      childrenOf (resumedBy "**Remaining:**") `shouldBe` [1, 2]
      childrenOf (resumedBy "### Remaining") `shouldBe` [1, 2]
      childrenOf (resumedBy "## Remaining") `shouldBe` [1]

    it "leaves checklist diagnostics unreported inside an excluded pseudo-heading subsection" $ do
      let body = "## Children\n**Related:**\n- [ ] no reference\n- [?] #3\n- [ ] #2 — A1: Ignored\n"
      parseTrackerBody [] body `shouldBe` ([], [TrackerChildrenMissing])
