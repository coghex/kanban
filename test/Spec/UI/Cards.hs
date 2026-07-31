-- | What a card and the details overlay render, and how that text is budgeted,
-- reflowed and tinted.
module Spec.UI.Cards (spec) where

import Data.Aeson (eitherDecode, encode, object, (.=))
import Data.List (nub)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text
import Kanban.CLI (ColorPolicy (..), Options (..))
import Kanban.Card (CardChip (..), boundedLines, displayWidth, labelChipRows)
import Kanban.Domain
import Kanban.UI
  ( labelApprovalAttr,
    labelAttribute,
    labelDefaultAttr,
    labelProblemAttr,
    labelUiAttr,
    itemHasAmberWarning,
    mergeExplanation,
    mergeText,
    pendingAttr,
    pullRequestCardAttribute
  )
import Kanban.Workflow (orderCardLabels, rereviewLabel)
import Spec.Support.Fixtures
  ( baseIssue,
    basePullRequest,
    cardFixtureDiagnosticEntry,
    cardFixtureEntry,
    cardFixtureLongKeyTrackedEntry,
    cardFixturePullRequestEntry,
    cardFixtureTrackedEntry,
    detailsFixtureBoard,
    detailsFixtureIssue,
    detailsFixturePullRequest,
    fixtureBoard,
    testOptions
  )
import Spec.Support.Render
  ( cardBorderColumns,
    cardInterior,
    detailsRows,
    detailsText,
    renderCard,
    renderDetails,
    renderDetailsAt
  )
import Test.Hspec

spec :: Spec
spec = do
  describe "card line budgeting" $ do
    it "keeps a wrapped excerpt within its line budget and marks the truncation" $ do
      boundedLines 10 3 "alpha beta gamma delta epsilon zeta" `shouldBe` ["alpha beta", "gamma", "delta…"]
      boundedLines 10 3 "alpha beta gamma delta" `shouldBe` ["alpha beta", "gamma", "delta"]

    it "leaves text that fits untouched, so an ellipsis only ever means dropped content" $ do
      boundedLines 10 3 "alpha beta gamma" `shouldBe` ["alpha beta", "gamma"]
      boundedLines 10 2 "" `shouldBe` []

    it "reflows to the width it is given rather than to a fixed layout" $ do
      boundedLines 5 3 "alpha beta gamma delta" `shouldBe` ["alpha", "beta", "gamm…"]
      boundedLines 22 3 "alpha beta gamma delta" `shouldBe` ["alpha beta gamma delta"]

    it "caps a title at two lines the same way, so it cannot crowd out the excerpt" $
      boundedLines 12 2 "#812  Modal input leaks through the overlay"
        `shouldBe` ["#812 Modal", "input leaks…"]

    it "measures display cells, not characters, so wide glyphs cannot overrun the border" $ do
      boundedLines 5 3 (Data.Text.replicate 8 "漢") `shouldBe` ["漢漢", "漢漢", "漢漢…"]
      map displayWidth (boundedLines 5 3 (Data.Text.replicate 8 "漢")) `shouldBe` [4, 4, 5]

    it "packs whole label chips into two rows and counts the rest into +N" $
      labelChipRows 20 2 ["alpha", "beta", "gamma", "delta", "epsilon"] 0
        `shouldBe` [ [LabelChip "alpha", LabelChip "beta"],
                     [LabelChip "gamma", LabelChip "delta", OverflowChip 1]
                   ]

    it "adds the overflow GitHub itself reported to the chips it could not place" $ do
      labelChipRows 20 2 ["alpha", "beta"] 4 `shouldBe` [[LabelChip "alpha", LabelChip "beta", OverflowChip 4]]
      labelChipRows 20 2 ["alpha", "beta", "gamma", "delta", "epsilon"] 3
        `shouldBe` [ [LabelChip "alpha", LabelChip "beta"],
                     [LabelChip "gamma", LabelChip "delta", OverflowChip 4]
                   ]

    it "omits and counts a chip too wide for a whole row rather than cropping it" $
      labelChipRows 10 2 ["a-very-long-label", "beta"] 0 `shouldBe` [[LabelChip "beta", OverflowChip 1]]

    it "gives the marker a spare row when the last one is full" $
      labelChipRows 16 2 ["alpha", "beta"] 1 `shouldBe` [[LabelChip "alpha", LabelChip "beta"], [OverflowChip 1]]

    it "evicts a trailing chip when that is the only way to show a whole marker" $
      labelChipRows 16 1 ["alpha", "beta"] 1 `shouldBe` [[LabelChip "alpha", OverflowChip 2]]

    it "orders workflow-status labels first and the remaining labels alphabetically" $ do
      let labels =
            [ Label "ui" "5319e7",
              Label "bug" "d73a4a",
              Label "reviewed:approve" "2f9e44",
              Label "Blocked" "b60205",
              Label "architecture" "0e8a16"
            ]
      map (.labelName) (orderCardLabels defaultWorkflowConfig labels)
        `shouldBe` ["reviewed:approve", "Blocked", "architecture", "bug", "ui"]

  describe "rendered cards" $ do
    it "shows every §11 element inside a frame sized to its own content" $ do
      let rendered = renderCard testOptions False cardFixtureEntry 46
      map Data.Text.strip (cardInterior rendered)
        `shouldBe` [ "#812 Modal input leaks through the overlay",
                     "and reaches the board beneath it",
                     "reviewed:approve   architecture   bug",
                     "code-health   input   ui  +2",
                     "@claude-agent · updated now",
                     "Empty modal areas currently allow pointer",
                     "events to reach lower pages, which is",
                     "visible whenever a dialog overlaps the…"
                   ]
      map displayWidth rendered `shouldBe` replicate (length rendered) 46
      cardBorderColumns rendered `shouldBe` (["╭"] <> replicate 8 "│" <> ["╰"], ["╮"] <> replicate 8 "│" <> ["╯"])

    -- An item missing data reaches the same amber incomplete treatment the
    -- overflow markers use, and its card says what it does not know rather
    -- than asserting the absence as a fact.
    it "renders an item with missing data amber, without claiming it is unassigned or unlinked" $ do
      let issue = (baseIssue 812 []) {issueDataGaps = [AssigneesUnavailable]}
          pullRequest = (basePullRequest 823 [] False []) {pullRequestDataGaps = [LinkedIssuesUnavailable]}
      itemHasAmberWarning defaultWorkflowConfig (IssueItem issue) `shouldBe` True
      itemHasAmberWarning defaultWorkflowConfig (PullRequestItem pullRequest) `shouldBe` True
      pullRequestCardAttribute defaultWorkflowConfig pullRequest `shouldBe` pendingAttr
      let issueCard = renderCard testOptions False (Standalone (IssueItem issue)) 46
      issueCard `shouldSatisfy` any (Data.Text.isInfixOf "assignees unknown")
      issueCard `shouldSatisfy` not . any (Data.Text.isInfixOf "unassigned")
      let pullRequestCard = renderCard testOptions False (Standalone (PullRequestItem pullRequest)) 46
      pullRequestCard `shouldSatisfy` any (Data.Text.isInfixOf "LINKS UNKNOWN")
      pullRequestCard `shouldSatisfy` not . any (Data.Text.isInfixOf "UNLINKED")

    it "reflows the same card, including its truncation markers, at a narrower width" $ do
      let rendered = renderCard testOptions False cardFixtureEntry 34
      map Data.Text.strip (cardInterior rendered)
        `shouldBe` [ "#812 Modal input leaks through",
                     "the overlay and reaches the…",
                     "reviewed:approve",
                     "architecture   bug  +5",
                     "@claude-agent · updated now",
                     "Empty modal areas currently",
                     "allow pointer events to reach",
                     "lower pages, which is visible…"
                   ]
      map displayWidth rendered `shouldBe` replicate (length rendered) 34
      cardBorderColumns rendered `shouldBe` (["╭"] <> replicate 8 "│" <> ["╰"], ["╮"] <> replicate 8 "│" <> ["╯"])

    it "grows the frame for a tracked card's tracker-context row" $ do
      let rendered = renderCard testOptions True cardFixtureTrackedEntry 46
      take 1 (map Data.Text.strip (cardInterior rendered)) `shouldBe` ["F2 · tracker #700 · MULTI-TRACKED"]
      length rendered `shouldBe` length (renderCard testOptions False cardFixtureEntry 46) + 1
      map displayWidth rendered `shouldBe` replicate (length rendered) 46
      cardBorderColumns rendered `shouldBe` (["╭"] <> replicate 9 "│" <> ["╰"], ["╮"] <> replicate 9 "│" <> ["╯"])

    it "wraps a long tracker reference across rows rather than dropping its tail" $ do
      let rendered = renderCard testOptions False cardFixtureLongKeyTrackedEntry 32
      take 2 (map Data.Text.strip (cardInterior rendered))
        `shouldBe` ["phase-two-renderer-contract", "· tracker #700"]
      map displayWidth rendered `shouldBe` replicate (length rendered) 32

    it "moves the multi-tracked warning to its own row when it no longer shares one" $ do
      let rendered = renderCard testOptions False cardFixtureTrackedEntry 32
      take 2 (map Data.Text.strip (cardInterior rendered)) `shouldBe` ["F2 · tracker #700", "MULTI-TRACKED"]
      length rendered `shouldBe` length (renderCard testOptions False cardFixtureEntry 32) + 2

    it "keeps every tracker diagnostic on the card, not just the first" $ do
      let rendered = renderCard testOptions False cardFixtureDiagnosticEntry 46
      drop 6 (map Data.Text.strip (cardInterior rendered))
        `shouldBe` [ "TRACKER · line 3: checklist item has no",
                     "issue reference",
                     "TRACKER · line 4: malformed checklist",
                     "checkbox",
                     "TRACKER · line 5: duplicate child #2"
                   ]
      map displayWidth rendered `shouldBe` replicate (length rendered) 46

    it "keeps a pull request's CI and merge status row visible" $ do
      let rendered = renderCard testOptions False cardFixturePullRequestEntry 46
      map Data.Text.strip (cardInterior rendered)
        `shouldBe` [ "PR #823 Route Shift-wheel through the",
                     "modal-aware ownership path",
                     "reviewed:approve   input",
                     "#812 · agent → master · updated now",
                     "Routes Shift-wheel through the same",
                     "modal-aware ownership path as ordinary",
                     "wheel events.",
                     "✓ CI 14/14 · clean"
                   ]
      map displayWidth rendered `shouldBe` replicate (length rendered) 46

    it "sizes a sparse card to its own content rather than to a fixed height" $ do
      let rendered = renderCard testOptions False (Standalone (IssueItem (baseIssue 5 []))) 46
      map Data.Text.strip (cardInterior rendered) `shouldBe` ["#5 Issue 5", "unassigned · updated now", "Body"]
      cardBorderColumns rendered `shouldBe` (["╭"] <> replicate 3 "│" <> ["╰"], ["╮"] <> replicate 3 "│" <> ["╯"])

    it "lays a card out identically under the ASCII and no-color options" $ do
      let rendered = renderCard testOptions False cardFixtureEntry 46
          asciiCard = renderCard (testOptions {optionAscii = True}) False cardFixtureEntry 46
          monochrome = renderCard (testOptions {optionColor = ColorNever}) False cardFixtureEntry 46
      cardInterior asciiCard `shouldBe` cardInterior rendered
      monochrome `shouldBe` rendered
      cardBorderColumns asciiCard `shouldBe` (["+"] <> replicate 8 "|" <> ["+"], ["+"] <> replicate 8 "|" <> ["+"])

  describe "details overlay §11 contract" $ do
    it "shows every §11 field for a pull request, including branches, links, merge explanation, and individual checks" $ do
      let rendered = renderDetails detailsFixtureBoard (PullRequestItem detailsFixturePullRequest)
      -- Heading, labels and their GitHub-reported overflow.
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "#823")
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "Route Shift-wheel through the modal-aware path")
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "reviewed:approve")
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "+2 labels omitted")
      -- A PR retains its author, so that is the person the overlay names.
      detailsText rendered "Author" `shouldBe` Just "@agent"
      detailsText rendered "Branches" `shouldBe` Just "issue-36-details → master"
      detailsText rendered "Linked issues" `shouldBe` Just "#36, #812 · +3 omitted"
      detailsText rendered "Mergeability"
        `shouldBe` Just "behind — the base has advanced past this head; update the branch before merging"
      -- Every non-passing check is named individually, beside a truthful
      -- passed count -- not folded into the card's aggregate glyph.
      detailsRows rendered "Checks"
        `shouldBe` [ "9/12 passed",
                     "• integration-suite — failed",
                     "• docs-lint — pending"
                   ]
      detailsRows rendered "Timestamps"
        `shouldBe` [ "created 2026-01-01 00:00 UTC",
                     "updated 2026-01-02 00:00 UTC · 3h ago"
                   ]
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "Routes Shift-wheel through the modal-aware ownership path.")
      detailsText rendered "URL" `shouldBe` Just "https://example.test/pull/823"

    -- The overlay is where a user goes to find out what the amber card means,
    -- so it is the last place that may present missing data as a verdict.
    it "says an item's assignees and links are unknown when GitHub never delivered them" $ do
      let issue = (baseIssue 36 []) {issueDataGaps = [AssigneesUnavailable]}
          pullRequest = (basePullRequest 823 [] False []) {pullRequestDataGaps = [LinkedIssuesUnavailable]}
      detailsText (renderDetails detailsFixtureBoard (IssueItem issue)) "Assignees" `shouldBe` Just "assignees unknown"
      detailsText (renderDetails detailsFixtureBoard (PullRequestItem pullRequest)) "Linked issues" `shouldBe` Just "LINKS UNKNOWN"

    it "shows the issue-side §11 fields, deriving linked pull requests from the retained snapshot" $ do
      let rendered = renderDetails detailsFixtureBoard (IssueItem detailsFixtureIssue)
      -- An issue retains assignees rather than an author.
      detailsText rendered "Assignees" `shouldBe` Just "@worker, @second +1"
      -- GitHub reports the link on the PR side only; the reverse direction is
      -- a lookup over the pull requests the snapshot already retained.
      detailsText rendered "Linked pull requests" `shouldBe` Just "#823, #851"
      detailsRows rendered "Timestamps"
        `shouldBe` [ "created 2026-01-01 00:00 UTC",
                     "updated 2026-01-02 00:00 UTC · 3h ago"
                   ]
      rendered `shouldSatisfy` any (Data.Text.isInfixOf "under #900")
      detailsText rendered "URL" `shouldBe` Just "https://example.test/issues/36"
      -- Branches, mergeability, and checks cannot apply to an issue, so their
      -- sections are absent rather than present and blank.
      rendered `shouldSatisfy` all (not . Data.Text.isPrefixOf "Branches")
      rendered `shouldSatisfy` all (not . Data.Text.isPrefixOf "Mergeability")
      rendered `shouldSatisfy` all (not . Data.Text.isPrefixOf "Checks")

    -- The overlay's viewport only scrolls vertically, so anything a single
    -- chip row pushed past the right edge would be unreachable, not merely
    -- off-screen. §11 requires every retained label plus the exact overflow
    -- count, so the chips have to wrap instead.
    it "wraps label chips at a narrow width rather than cropping labels out of reach" $ do
      let many =
            detailsFixturePullRequest
              { pullRequestLabels = [Label name "2f9e44" | name <- ["reviewed:approve", "input", "ui", "code-health", "architecture"]],
                pullRequestLabelOverflow = 2
              }
          rendered = renderDetailsAt 30 detailsFixtureBoard (PullRequestItem many)
          labelBlock = takeWhile (/= "Metadata") rendered
      mapM_ (\name -> labelBlock `shouldSatisfy` any (Data.Text.isInfixOf name)) ["reviewed:approve", "input", "ui", "code-health", "architecture"]
      labelBlock `shouldSatisfy` any (Data.Text.isInfixOf "+2 labels omitted")
      -- Wrapping, not overrunning: no row exceeds the width it was given.
      map displayWidth rendered `shouldSatisfy` all (<= 30)

    it "counts a label too wide for a whole row in the overflow marker instead of dropping it silently" $ do
      let oversized =
            detailsFixturePullRequest
              { pullRequestLabels = [Label (Data.Text.replicate 40 "x") "2f9e44", Label "ui" "0075ca"],
                pullRequestLabelOverflow = 1
              }
          rendered = renderDetailsAt 20 detailsFixtureBoard (PullRequestItem oversized)
          labelBlock = takeWhile (/= "Metadata") rendered
      labelBlock `shouldSatisfy` any (Data.Text.isInfixOf "ui")
      labelBlock `shouldSatisfy` any (Data.Text.isInfixOf "+2 labels omitted")

    it "reports a rollup past the context cap as unknown instead of listing the nodes it did see" $ do
      let unknownChecks = detailsFixturePullRequest {pullRequestChecks = ChecksUnknown}
      detailsRows (renderDetails detailsFixtureBoard (PullRequestItem unknownChecks)) "Checks"
        `shouldBe` ["unknown — the rollup exceeded the retained context cap"]

    it "gives a complete rollup with nothing outstanding a truthful summary and no empty detail rows" $ do
      let passed = detailsFixturePullRequest {pullRequestChecks = ChecksPassed 12}
          none = detailsFixturePullRequest {pullRequestChecks = ChecksNone}
      detailsRows (renderDetails detailsFixtureBoard (PullRequestItem passed)) "Checks" `shouldBe` ["12/12 passed"]
      detailsRows (renderDetails detailsFixtureBoard (PullRequestItem none)) "Checks" `shouldBe` ["no checks configured"]

    it "says 'none' rather than nothing when an item genuinely has no links" $ do
      let unlinked = basePullRequest 999 [] False []
      detailsText (renderDetails detailsFixtureBoard (PullRequestItem unlinked)) "Linked issues" `shouldBe` Just "none"
      detailsText (renderDetails detailsFixtureBoard (IssueItem (baseIssue 404 []))) "Linked pull requests" `shouldBe` Just "none"

    it "explains every merge state the decoder can produce, always leading with the card's own word" $ do
      let states = [MergeClean, MergeBehind, MergeBlocked, MergeProtected, MergeConflicting, MergeUnstable, MergeUnknown]
          explanations = map mergeExplanation states
          explain state = detailsText (renderDetails detailsFixtureBoard (PullRequestItem (detailsFixturePullRequest {pullRequestMergeState = state}))) "Mergeability"
      explanations `shouldSatisfy` all (not . Data.Text.null)
      length (nub explanations) `shouldBe` length states
      -- §9's vocabulary is what the overlay leads with, so its sentence can
      -- never disagree with the word the card already showed.
      map explain states `shouldBe` map (\state -> Just (mergeText state <> " — " <> mergeExplanation state)) states

  -- The card frame pre-wraps its title and excerpt with Kanban.Card's own
  -- 'boundedLines'/'displayWidth' (already covered directly), but the details
  -- overlay hands its title and body to Brick's own 'txtWrap'. These render
  -- through that production Brick/Vty path -- not a duplicate width
  -- algorithm -- and stay separate from the full golden-frame scope of #55.
  describe "Unicode rendering through Brick's own reflow" $ do
    -- A CJK title has no whitespace for txtWrap to break on, so it emits the
    -- title as one unbroken line; the frame then relies on Vty to clip that
    -- line to the width it was given rather than reflow it onto more rows.
    -- This is the "clipping" half of the wrapping-or-clipping contract, and
    -- it holds regardless: no row may ever exceed the given width.
    it "clips an unbroken CJK title to the given width rather than overrunning it" $ do
      let wideTitle = Data.Text.replicate 40 "漢"
          issue = (baseIssue 5 []) {issueTitle = wideTitle}
          rendered = renderDetailsAt 20 (fixtureBoard []) (IssueItem issue)
      map displayWidth rendered `shouldSatisfy` all (<= 20)
      Data.Text.count "漢" (Data.Text.concat rendered) `shouldBe` 20 `div` 2

    it "renders a base-plus-combining-mark title intact through the same path" $ do
      let combiningTitle = "5\817"
          issue = (baseIssue 6 []) {issueTitle = combiningTitle}
          rendered = renderDetailsAt 40 (fixtureBoard []) (IssueItem issue)
      rendered `shouldSatisfy` any (Data.Text.isInfixOf combiningTitle)

  describe "label chip color" $ do
    it "leaves an unconfigured repository's own label vocabulary at the default attribute" $ do
      -- The names Kanban used to compile in. With nothing configured they are
      -- ordinary labels, which is the whole point of the configuration.
      map (labelAttribute defaultWorkflowConfig) ["bug", "ui", "input"]
        `shouldBe` replicate 3 labelDefaultAttr

    it "gives a configured name its configured attribute in either styling collection" $ do
      let config =
            defaultWorkflowConfig
              { problemStyleLabels = Set.fromList ["defect"],
                uiStyleLabels = Set.fromList ["interface"]
              }
      labelAttribute config "defect" `shouldBe` labelProblemAttr
      labelAttribute config "interface" `shouldBe` labelUiAttr
      labelAttribute config "unlisted" `shouldBe` labelDefaultAttr

    it "matches a configured styling name case-insensitively, as every other label comparison does" $ do
      let config =
            defaultWorkflowConfig
              { problemStyleLabels = Set.fromList ["Defect"],
                uiStyleLabels = Set.fromList ["INTERFACE"]
              }
      labelAttribute config "DEFECT" `shouldBe` labelProblemAttr
      labelAttribute config "defect" `shouldBe` labelProblemAttr
      labelAttribute config "interface" `shouldBe` labelUiAttr

    it "keeps approval, changes-requested, blocked, and the reserved rereview label unchanged" $ do
      labelAttribute defaultWorkflowConfig defaultWorkflowConfig.approvalLabel `shouldBe` labelApprovalAttr
      labelAttribute defaultWorkflowConfig defaultWorkflowConfig.changesRequestedLabel `shouldBe` labelProblemAttr
      labelAttribute defaultWorkflowConfig "blocked" `shouldBe` labelProblemAttr
      labelAttribute defaultWorkflowConfig rereviewLabel `shouldBe` pendingAttr
      labelAttribute defaultWorkflowConfig "REVIEWED:REVISED" `shouldBe` pendingAttr
      let renamed =
            defaultWorkflowConfig
              { approvalLabel = "lgtm",
                changesRequestedLabel = "needs-work",
                blockedLabels = Set.fromList ["on-hold"]
              }
      labelAttribute renamed "LGTM" `shouldBe` labelApprovalAttr
      labelAttribute renamed "Needs-Work" `shouldBe` labelProblemAttr
      labelAttribute renamed "on-hold" `shouldBe` labelProblemAttr
      labelAttribute renamed "blocked" `shouldBe` labelDefaultAttr

    it "resolves the documented precedence, so styling configuration cannot disguise a workflow state" $ do
      -- Every protocol name also listed for styling keeps its protocol color,
      -- and a name in both styling collections resolves to problem.
      let config =
            defaultWorkflowConfig
              { problemStyleLabels =
                  Set.fromList
                    [ defaultWorkflowConfig.approvalLabel,
                      rereviewLabel,
                      "both"
                    ],
                uiStyleLabels =
                  Set.fromList
                    [ defaultWorkflowConfig.approvalLabel,
                      defaultWorkflowConfig.changesRequestedLabel,
                      rereviewLabel,
                      "blocked",
                      "both"
                    ]
              }
      labelAttribute config defaultWorkflowConfig.approvalLabel `shouldBe` labelApprovalAttr
      labelAttribute config rereviewLabel `shouldBe` pendingAttr
      labelAttribute config defaultWorkflowConfig.changesRequestedLabel `shouldBe` labelProblemAttr
      labelAttribute config "blocked" `shouldBe` labelProblemAttr
      labelAttribute config "both" `shouldBe` labelProblemAttr

    -- A worker spec persists a whole WorkflowConfig, and Kanban.Worker's
    -- manual instance delegates the nested object to this one, so a spec
    -- written before the styling collections existed decodes only if they
    -- default rather than being required.
    it "decodes a durable workflow configuration written before the styling collections existed" $ do
      let legacy =
            object
              [ "approvalLabel" .= ("lgtm" :: Text),
                "changesRequestedLabel" .= ("needs-work" :: Text),
                "blockedLabels" .= Set.fromList ["blocked" :: Text],
                "trackerLabels" .= Set.fromList ["epic" :: Text],
                "additionalTrackerSectionHeadings" .= ([] :: [Text]),
                "approvalMode" .= ApprovalByLabel,
                "blockingSeverity" .= SeverityRed
              ]
      eitherDecode (encode legacy)
        `shouldBe` Right
          defaultWorkflowConfig
            { approvalLabel = "lgtm",
              changesRequestedLabel = "needs-work"
            }
