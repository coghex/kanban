module Kanban.UI.Theme
  ( approvedAttr,
    approvedInteriorAttr,
    attentionAttr,
    cardBorderStyle,
    cardInteriorAttribute,
    cardTitleAttr,
    checkStateAttribute,
    columnHeadingAttr,
    dimAttr,
    drainerSourceAttr,
    drainerStatusAttr,
    footerAttr,
    headingAttr,
    innerBorderStyle,
    itemHasAmberWarning,
    labelApprovalAttr,
    labelAttribute,
    labelDefaultAttr,
    labelProblemAttr,
    labelUiAttr,
    linkAttr,
    neutralAttr,
    noticeAttr,
    pendingAttr,
    problemAttr,
    providerAttr,
    pullRequestCardAttribute,
    pullRequestSessionAttribute,
    readyAttr,
    reviewPhaseAttribute,
    reviewingAttr,
    revisedAttr,
    selectedAttr,
    selectedTitleAttr,
    shellBorderStyle,
    solveSessionAttribute,
    statusTextAttr,
    themeFor,
    titleAttr,
    trackerAttr,
    trackerHeaderAttribute,
    usageStatusAttribute,
    usesOpenBorders,
  )
where


import Brick
import Brick.Widgets.Border.Style (BorderStyle (..), ascii, unicode, unicodeBold)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Graphics.Vty as Vty
import Kanban.CLI (BorderPolicy (..), ColorPolicy (..), Options (..))
import Kanban.Domain
import Kanban.Drainer
  ( DrainerState (..),
    DrainerStatus (..)
    )
import Kanban.Solve
  ( SolveWorkflow (..)
    )
import Kanban.Tracker (trackerDiagnosticsForIssue)
import Kanban.Workflow (CardStatus (..), isProblem, pullRequestStatus, rereviewLabel)
import Kanban.UI.Types

drainerStatusAttr :: DrainerStatus -> AttrName
drainerStatusAttr status = case status.drainerState of
  DrainerOff -> neutralAttr
  DrainerOn -> readyAttr
  DrainerStarting -> pendingAttr
  DrainerStopping -> pendingAttr
  DrainerWarning -> pendingAttr
  DrainerError -> problemAttr

usageStatusAttribute :: Freshness -> AttrName
usageStatusAttribute Loading = noticeAttr
usageStatusAttribute (Stale _ _) = pendingAttr
usageStatusAttribute (Unavailable _) = problemAttr
usageStatusAttribute (Unsupported _) = dimAttr
usageStatusAttribute _ = dimAttr

-- | A tracker header carries its own parse state: amber whenever the tracker
-- produced diagnostics -- including the childless header, whose diagnostic is
-- the only thing on the board saying why it has no children -- and the
-- ordinary tracker accent otherwise.
trackerHeaderAttribute :: Tracker -> AttrName
trackerHeaderAttribute tracker
  | null tracker.trackerDiagnostics = trackerAttr
  | otherwise = pendingAttr

pullRequestCardAttribute :: WorkflowConfig -> PullRequest -> AttrName
pullRequestCardAttribute config pullRequest
  | StatusProblem _ <- status = problemAttr
  | itemHasAmberWarning config (PullRequestItem pullRequest) = pendingAttr
  | StatusPending _ <- status = pendingAttr
  | StatusReady <- status = readyAttr
  | otherwise = neutralAttr
  where
    status = pullRequestStatus config pullRequest

-- | Whether a card's interior wash should read as approved: mirrors
-- 'cardStatusAttribute' rather than a raw 'isApproved' check, so an
-- approved-but-pending or amber-blocked pull request's interior does not
-- disagree with its own border.
cardInteriorAttribute :: AttrName -> AttrName
cardInteriorAttribute statusAttribute
  | statusAttribute == approvedAttr || statusAttribute == readyAttr = approvedInteriorAttr
  | otherwise = neutralAttr

statusTextAttr :: WorkflowConfig -> BoardItem -> AttrName
statusTextAttr config item
  | isProblem config item = problemAttr
  | itemHasAmberWarning config item = pendingAttr
statusTextAttr config (PullRequestItem pullRequest) = case pullRequestStatus config pullRequest of
  StatusPending _ -> pendingAttr
  StatusReady -> readyAttr
  StatusProblem _ -> problemAttr
  StatusNeutral -> dimAttr
statusTextAttr _ _ = dimAttr

solveSessionAttribute :: SolveSession -> AttrName
solveSessionAttribute session = case session.solveSessionPhase of
  SolveAttention -> attentionAttr
  SolveInterrupting -> pendingAttr
  SolveFailedPhase -> problemAttr
  SolveKilledPhase -> problemAttr
  SolveOrphanedPhase -> problemAttr
  SolveFinished -> neutralAttr
  _
    | session.solveSessionWorkflow == AutoSolve -> activeAttr
    | otherwise -> neutralAttr

pullRequestSessionAttribute :: PullRequestReviewSession -> AttrName
pullRequestSessionAttribute session = case session.pullRequestSessionPhase of
  SolveAttention -> attentionAttr
  SolveInterrupting -> pendingAttr
  SolveFailedPhase -> problemAttr
  SolveKilledPhase -> problemAttr
  SolveOrphanedPhase -> problemAttr
  SolveFinished -> readyAttr
  _ -> reviewingAttr

reviewPhaseAttribute :: ReviewPhase -> AttrName
reviewPhaseAttribute phase = case phase of
  ReviewStarting -> trackerAttr
  ReviewRunning -> trackerAttr
  ReviewWaiting -> pendingAttr
  ReviewFinished -> readyAttr
  ReviewNeedsChanges -> pendingAttr
  ReviewFailed -> problemAttr
  ReviewRevised -> revisedAttr
  ReviewInterrupted -> dimAttr

drainerSourceAttr :: DrainerSourceState -> AttrName
drainerSourceAttr source = case source of
  DrainerSourceReported [] -> dimAttr
  DrainerSourceReported _ -> problemAttr
  DrainerSourceChecking -> pendingAttr
  DrainerSourceUnavailable _ -> pendingAttr

checkStateAttribute :: CheckState -> AttrName
checkStateAttribute CheckPassed = dimAttr
checkStateAttribute CheckPending = pendingAttr
checkStateAttribute CheckFailed = problemAttr

shellBorderStyle :: AppState -> BorderStyle
shellBorderStyle state
  | state.appOptions.optionAscii = ascii
  | otherwise = doubleBorderStyle

innerBorderStyle :: AppState -> BorderStyle
innerBorderStyle state
  | state.appOptions.optionAscii = ascii
  | otherwise = unicodeBold

usesOpenBorders :: AppState -> Bool
usesOpenBorders state =
  not state.appOptions.optionAscii
    && state.appOptions.optionBorder == BorderOpen

cardBorderStyle :: Options -> BorderStyle
cardBorderStyle options
  | options.optionAscii = ascii
  | otherwise = unicode

doubleBorderStyle :: BorderStyle
doubleBorderStyle =
  BorderStyle
    { bsCornerTL = '╔',
      bsCornerTR = '╗',
      bsCornerBR = '╝',
      bsCornerBL = '╚',
      bsIntersectFull = '╬',
      bsIntersectL = '╠',
      bsIntersectR = '╣',
      bsIntersectT = '╦',
      bsIntersectB = '╩',
      bsHorizontal = '═',
      bsVertical = '║'
    }

themeFor :: Options -> AttrMap
themeFor options
  | options.optionColor == ColorNever = attrMap Vty.defAttr [(name, Vty.defAttr) | name <- allAttributeNames]
  | otherwise =
      attrMap
        Vty.defAttr
        [ (titleAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (headingAttr, foreground Vty.brightWhite `Vty.withStyle` Vty.bold),
          (providerAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (footerAttr, foreground Vty.brightBlack),
          (noticeAttr, foreground Vty.yellow),
          (dimAttr, foreground Vty.brightBlack),
          (neutralAttr, foreground Vty.white),
          (selectedAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (approvedAttr, foreground Vty.brightGreen `Vty.withStyle` Vty.bold),
          (approvedInteriorAttr, onColor Vty.black Vty.green),
          (pendingAttr, foreground Vty.yellow),
          (attentionAttr, foreground (Vty.rgbColor (255 :: Int) 165 0) `Vty.withStyle` Vty.bold),
          (readyAttr, foreground Vty.brightGreen),
          (problemAttr, foreground Vty.brightRed `Vty.withStyle` Vty.bold),
          (trackerAttr, foreground (Vty.rgbColor (128 :: Int) 90 213) `Vty.withStyle` Vty.bold),
          (revisedAttr, foreground (Vty.rgbColor (130 :: Int) 80 223) `Vty.withStyle` Vty.bold),
          (cardTitleAttr, Vty.defAttr `Vty.withStyle` Vty.bold),
          (selectedTitleAttr, foreground Vty.brightCyan `Vty.withStyle` Vty.bold),
          (linkAttr, foreground Vty.brightBlue),
          (labelDefaultAttr, onColor Vty.black Vty.brightWhite),
          (labelApprovalAttr, onColor Vty.black Vty.brightGreen),
          (labelProblemAttr, onColor Vty.brightWhite Vty.red),
          (labelUiAttr, onColor Vty.brightWhite Vty.blue),
          (issuesAttr, foreground Vty.brightWhite),
          (activeAttr, foreground Vty.brightBlue),
          (reviewingAttr, foreground Vty.yellow),
          (doneAttr, foreground Vty.brightGreen)
        ]
  where
    foreground = Vty.withForeColor Vty.defAttr
    onColor textColor background = Vty.withBackColor (Vty.withForeColor Vty.defAttr textColor) background

columnHeadingAttr :: BoardColumn -> AttrName
columnHeadingAttr Issues = issuesAttr
columnHeadingAttr Active = activeAttr
columnHeadingAttr Reviewing = reviewingAttr
columnHeadingAttr Done = doneAttr

-- | Configurable blocking severity governs pull-request status color and
-- sorting (via 'Kanban.Workflow.pullRequestStatus') only; the label chip
-- itself always renders the changes-requested/blocked label as a problem,
-- matching unchanged issue-card treatment.
--
-- Precedence runs approval, the reserved rereview label, changes-requested
-- and blocked, then the two display-only configured collections, then the
-- default. The protocol names come first so no styling configuration can
-- disguise a workflow state, and problem styling precedes UI styling so a
-- name listed in both collections resolves deterministically.
labelAttribute :: WorkflowConfig -> Text -> AttrName
labelAttribute config name
  | folded == Text.toCaseFold config.approvalLabel = labelApprovalAttr
  | folded == Text.toCaseFold rereviewLabel = pendingAttr
  | folded == Text.toCaseFold config.changesRequestedLabel || folded `Set.member` foldedBlockedLabels = labelProblemAttr
  | folded `Set.member` foldedCaseless config.problemStyleLabels = labelProblemAttr
  | folded `Set.member` foldedCaseless config.uiStyleLabels = labelUiAttr
  | otherwise = labelDefaultAttr
  where
    folded = Text.toCaseFold name
    foldedBlockedLabels = foldedCaseless config.blockedLabels
    foldedCaseless = Set.map Text.toCaseFold

titleAttr, headingAttr, providerAttr, footerAttr, noticeAttr, dimAttr :: AttrName
neutralAttr, selectedAttr, approvedAttr, approvedInteriorAttr, pendingAttr, attentionAttr, readyAttr, problemAttr :: AttrName
trackerAttr :: AttrName
revisedAttr :: AttrName
cardTitleAttr, selectedTitleAttr, linkAttr, labelDefaultAttr, labelApprovalAttr, labelProblemAttr, labelUiAttr :: AttrName
issuesAttr, activeAttr, reviewingAttr, doneAttr :: AttrName
titleAttr = attrName "title"
headingAttr = attrName "heading"
providerAttr = attrName "provider"
footerAttr = attrName "footer"
noticeAttr = attrName "notice"
dimAttr = attrName "dim"
neutralAttr = attrName "status.neutral"
selectedAttr = attrName "status.selected"
approvedAttr = attrName "status.approved"
approvedInteriorAttr = attrName "interior.approved"
pendingAttr = attrName "status.pending"
attentionAttr = attrName "status.attention"
readyAttr = attrName "status.ready"
problemAttr = attrName "status.problem"
trackerAttr = attrName "tracker"
revisedAttr = attrName "status.revised"
cardTitleAttr = attrName "card.title"
selectedTitleAttr = attrName "card.title.selected"
linkAttr = attrName "link"
labelDefaultAttr = attrName "label.default"
labelApprovalAttr = attrName "label.approval"
labelProblemAttr = attrName "label.problem"
labelUiAttr = attrName "label.ui"
issuesAttr = attrName "column.issues"
activeAttr = attrName "column.active"
reviewingAttr = attrName "column.reviewing"
doneAttr = attrName "column.done"

allAttributeNames :: [AttrName]
allAttributeNames =
  [ titleAttr,
    headingAttr,
    providerAttr,
    footerAttr,
    noticeAttr,
    dimAttr,
    neutralAttr,
    selectedAttr,
    approvedAttr,
    approvedInteriorAttr,
    pendingAttr,
    attentionAttr,
    readyAttr,
    problemAttr,
    trackerAttr,
    revisedAttr,
    cardTitleAttr,
    selectedTitleAttr,
    linkAttr,
    labelDefaultAttr,
    labelApprovalAttr,
    labelProblemAttr,
    labelUiAttr,
    issuesAttr,
    activeAttr,
    reviewingAttr,
    doneAttr
  ]

itemHasAmberWarning :: WorkflowConfig -> BoardItem -> Bool
itemHasAmberWarning config (IssueItem issue) =
  issue.issueLabelOverflow > 0
    || issue.issueAssigneeOverflow > 0
    || not (null issue.issueDataGaps)
    || not (null (trackerDiagnosticsForIssue config issue))
itemHasAmberWarning _ (PullRequestItem pullRequest) =
  pullRequest.pullRequestLabelOverflow > 0
    || pullRequest.pullRequestLinkedIssueOverflow > 0
    || not (null pullRequest.pullRequestDataGaps)
