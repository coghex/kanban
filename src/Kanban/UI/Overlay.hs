module Kanban.UI.Overlay
  ( drawIncidents,
    drawOverlay,
    drawUndeliveredSteers,
    helpLines,
    mouseHelpEntries,
    reviewPhaseLabel,
    solveReviewerLabel,
  )
where


import Brick
import Brick.Widgets.Border (borderWithLabel, hBorder )
import Brick.Widgets.Center (centerLayer)
import Data.List (intersperse)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.CLI (Options (..))
import Kanban.Card (boundedLines)
import Kanban.Domain
import Kanban.Review
  ( ReviewApproval (..),
    ReviewChoice (..),
    ReviewQuestion (..),
    ReviewStage (..)
    )
import Kanban.Solve
  ( SolveWorkflow (..),
    SolverBrand (..),
    claudeReviewerModel,
    claudeSolverModel,
    codexReviewerModel,
    codexSolverModel,
    solverLabel
  )
import Kanban.Settings
  ( ChatVerbosity (..),
    Settings (..),
    verbosityDescription,
    verbosityLabel
  )
import Kanban.Text (sanitizeText)
import Kanban.UI.Keys
  ( BoardAction (..),
    HelpEntry (..),
    actionKeyText,
    bindingHelpEntry,
    boardBindings,
    gestureHelpEntry,
    helpRows,
  )
import Kanban.UI.SessionCore (sessionInputHelp)
import Kanban.UI.Types
import Kanban.UI.Util
import Kanban.UI.Theme
import Kanban.UI.State
import Kanban.UI.Session
import Kanban.UI.Details
import Kanban.UI.Board

drawOverlay :: AppState -> Overlay -> Widget Name
drawOverlay state overlay =
  centerLayer
    . panelExtent
    . hLimit overlayWidth
    . vLimit overlayHeight
    . withBorderStyle (innerBorderStyle state)
    . borderWithLabel (withAttr headingAttr (txt overlayTitle))
    . padAll 1
    $ case overlay of
      HelpOverlay -> drawHelp
      SettingsOverlay -> drawSettings state
      ProcessesOverlay -> drawProcesses state
      IncidentsOverlay -> drawIncidents state
      DetailsOverlay item -> viewport DetailsViewport Vertical (drawDetails (detailsEnv state) item)
      ReviewOverlay issueNumber -> drawReview state issueNumber
      SolveChooser _ issue -> drawSolveChooser issue
      SolveOverlay issueNumber -> drawSolve state issueNumber
      PullRequestReviewOverlay number -> drawPullRequestReview state number
  where
    overlayWidth = case overlay of
      SolveChooser _ _ -> 42
      SettingsOverlay -> 68
      ProcessesOverlay -> 100
      IncidentsOverlay -> 100
      -- Wide enough for the list it draws, for the same reason its height is:
      -- a description added to the table has to widen the box rather than be
      -- silently cut off inside it. A terminal narrower than this still clips
      -- the overlay, which is the overlay system's existing policy.
      HelpOverlay -> maximum (1 : map Text.length helpLines) + 4
      _ -> 88
    overlayHeight = case overlay of
      SolveChooser _ _ -> 10
      SettingsOverlay -> 19
      ProcessesOverlay -> 32
      -- Tall enough for the list it draws, so a binding added to the table
      -- cannot silently push a row past the border: the two rows 'padAll'
      -- adds and the two the border takes are the whole difference.
      HelpOverlay -> length helpLines + 4
      _ -> 32
    panelExtent = case overlay of
      HelpOverlay -> id
      SettingsOverlay -> id
      ProcessesOverlay -> clickable ProcessesPanel
      IncidentsOverlay -> clickable IncidentsPanel
      DetailsOverlay _ -> clickable DetailsPanel
      ReviewOverlay _ -> clickable ReviewPanel
      SolveChooser _ _ -> id
      SolveOverlay _ -> clickable SolvePanel
      PullRequestReviewOverlay _ -> clickable PullRequestReviewPanel
    overlayTitle = case overlay of
      HelpOverlay -> " HELP "
      SettingsOverlay -> " SETTINGS "
      ProcessesOverlay -> " PROCESSES "
      IncidentsOverlay -> " NEEDS ATTENTION "
      DetailsOverlay item -> " " <> itemHeading item <> " "
      ReviewOverlay issueNumber -> " " <> reviewOverlayTitle state issueNumber <> " #" <> showText issueNumber <> " "
      SolveChooser workflow issue -> " " <> workflowTitle workflow <> " #" <> showText issue.issueNumber <> " "
      SolveOverlay issueNumber -> " SOLVE #" <> showText issueNumber <> " "
      PullRequestReviewOverlay number -> " PR #" <> showText number <> " REVIEW/REVISE "

reviewOverlayTitle :: AppState -> Int -> Text
reviewOverlayTitle state issueNumber = case (.sessionDetail.reviewSessionStage) <$> Map.lookup issueNumber state.appReviewSessions of
  Just InitialReview -> "REVIEW"
  Just IssueRevision -> "REVISION"
  Just IssueRereview -> "REREVIEW"
  Nothing -> "REVIEW"

drawHelp :: Widget Name
drawHelp = vBox (map txt helpLines)

-- | The complete binding list, in three blocks: every base-board binding in
-- §7's order, then the bindings a live-agent overlay adds, then the mouse.
--
-- Nothing here is a key hint this module wrote down. The board rows come from
-- the table in "Kanban.UI.Keys" and the overlay rows from beside the decoder
-- that answers them in "Kanban.UI.SessionCore", so the overlay cannot claim a
-- binding that dispatch does not have — which is exactly how it came to omit
-- @?@, its own binding, before this list was derived.
helpLines :: [Text]
helpLines = helpRows (map bindingHelpEntry boardBindings <> sessionInputHelp <> mouseHelpEntries)

-- | The gestures no key covers, so no binding defines them. Mouse policy
-- lives in @Kanban.UI.Events@ rather than in a table, and this is prose about
-- it, not a key hint.
mouseHelpEntries :: [HelpEntry]
mouseHelpEntries =
  [ gestureHelpEntry "left click" "select card; click selected card for details",
    gestureHelpEntry "mouse wheel" "scroll column under pointer",
    gestureHelpEntry "right/outside click" "close card details"
  ]

drawSettings :: AppState -> Widget Name
drawSettings state =
  vBox
    [ withAttr cardTitleAttr (txt "Chat output verbosity"),
      txt "",
      drawChoice '1' CompactChat,
      txt "",
      drawChoice '2' StandardChat,
      txt "",
      drawChoice '3' FullChat,
      txt "",
      withAttr dimAttr (txtWrap "Full JSONL logs are always recorded at maximum provider verbosity; this setting changes only the on-screen transcript."),
      withAttr dimAttr (txtWrap ("Log directory: " <> Text.pack state.appLogRoot)),
      withAttr footerAttr (txt "1/2/3 select  Esc close")
    ]
  where
    selected = state.appSettings.settingsChatVerbosity
    drawChoice key verbosity =
      let attribute = if verbosity == selected then selectedAttr else neutralAttr
       in withAttr attribute (txt (Text.singleton key <> ") " <> verbosityLabel verbosity))
            <=> padLeft (Pad 3) (withAttr dimAttr (txtWrap (verbosityDescription verbosity)))

drawProcesses :: AppState -> Widget Name
drawProcesses state =
  vBox
    [ withAttr dimAttr (txt ("tracked sessions: " <> showText (length entries) <> " · live processes: " <> showText (length (filter (.agentSessionLive) entries)))),
      txt "",
      vLimit 23
        . viewport ProcessesViewport Vertical
        $ if null entries
          then withAttr dimAttr (txt "No agent sessions have been started.")
          else vBox (zipWith drawEntry [0 :: Int ..] entries),
      hBorder,
      withAttr footerAttr (txt "j/↓ next  k/↑ previous  Enter open session  x kill process tree  wheel scroll  Esc close")
    ]
  where
    entries = agentSessionEntries state
    selectedIndex = (resolveProcessSelection entries state.appProcessSelection).processSelectionRow
    drawEntry index entry =
      let selected = index == selectedIndex
          attribute
            | selected = selectedAttr
            | entry.agentSessionProblem = problemAttr
            | entry.agentSessionLive = reviewingAttr
            | otherwise = dimAttr
          glyph
            | state.appOptions.optionAscii = if entry.agentSessionLive then "*" else "-"
            | entry.agentSessionLive = "●"
            | entry.agentSessionProblem = "×"
            | otherwise = "○"
          sessionText = maybe "" (" · id " <>) entry.agentSessionId
          line =
            glyph
              <> " "
              <> entry.agentSessionLabel
              <> " · "
              <> entry.agentSessionProvider
              <> " · "
              <> entry.agentSessionStatus
              <> " · "
              <> entry.agentSessionActivity
              <> sessionText
          widget = clickable (ProcessTarget entry.agentSessionRef) (withAttr attribute (txt line))
       in if selected then visible widget else widget

drawIncidents :: AppState -> Widget Name
drawIncidents state =
  vBox
    [ withAttr (drainerSourceAttr source) (txtWrap (drainerSourceSummary source)),
      txt "",
      vLimit 23
        . viewport IncidentsViewport Vertical
        $ if null entries
          then withAttr dimAttr (txtWrap (emptyStateText source))
          else vBox (zipWith drawEntry [0 :: Int ..] entries),
      hBorder,
      withAttr footerAttr (txt "j/↓ next  k/↑ previous  Enter go to the work  wheel scroll  Esc close")
    ]
  where
    entries = incidentEntries state
    source = drainerSourceState state.appDrainerStatus state.appDrainerIncidents
    selectedIndex = (resolveIncidentSelection entries state.appIncidentSelection).incidentSelectionRow
    glyph = if state.appOptions.optionAscii then "!" else "×"
    drawEntry index entry =
      let selected = index == selectedIndex
          attribute = if selected then selectedAttr else problemAttr
          line =
            glyph
              <> " "
              <> entry.incidentEntrySubject
              <> " · "
              <> entry.incidentEntryDetail
              <> " · "
              <> incidentSourceLabel entry.incidentEntrySource
          note = maybe [] (noteLines state) entry.incidentEntryNote
          widget =
            clickable
              (IncidentTarget entry.incidentEntryRef)
              (vBox (withAttr attribute (elidedLine line) : note))
       in if selected then visible widget else widget

-- | An entry's note as the continuation lines drawn under its row.
--
-- Wrapped rather than elided: the note exists because the text is worth
-- reading whole, and a row that has already spent the panel's width on its
-- subject and summary would elide it away before its first word. The
-- continuation is indented and marked so it reads as belonging to the row
-- above rather than as an entry of its own, and it is part of the same
-- clickable widget, so clicking it selects the incident it belongs to.
--
-- Bounded in height as well as width. A note is one incident's detail, and
-- the panel's rows are shared: 'boundedLines' caps it at
-- 'incidentNoteLines', ending the last kept line with an ellipsis when
-- anything was dropped.
noteLines :: AppState -> Text -> [Widget Name]
noteLines state note = [withAttr dimAttr (Widget Fixed Fixed draw)]
  where
    marker = if state.appOptions.optionAscii then "-> " else "↳ "
    indent = "    "
    -- The marker sits on the first line only; later lines align under its
    -- text rather than repeating it.
    continuation = Text.replicate (Text.length marker) " "
    draw = do
      context <- getContext
      let body = max 1 (availWidth context - Text.length indent - Text.length marker)
          rows = boundedLines body incidentNoteLines note
      render (vBox [txt (indent <> prefix <> row) | (prefix, row) <- zip (marker : repeat continuation) rows])

-- | How many continuation lines one note may take before it is elided. A
-- note belongs to a single incident while the panel's height is shared, so
-- three lines is the whole allowance.
incidentNoteLines :: Int
incidentNoteLines = 3

-- | One row's text, elided to the width the panel actually gives it.
--
-- The panel is a fixed-width overlay, so a row longer than it is cropped by
-- the viewport. Cropping alone is silent: it takes the tail of the line away
-- with nothing to say it did, which reads as a row that simply ends there.
-- Measuring at render time instead keeps the §11 promise that an ellipsis
-- appears wherever text was dropped, and it is the width the panel really
-- has rather than a constant restated here.
--
-- Still exactly one row: 'boundedLines' at one line either returns the whole
-- line or its elided head, and an empty line yields no row rather than a
-- blank one.
elidedLine :: Text -> Widget Name
elidedLine line = Widget Fixed Fixed $ do
  context <- getContext
  render (txt (Text.concat (boundedLines (availWidth context) 1 line)))

-- | The overall "nothing needs attention" claim is only ever made from a
-- drainer observation that reported no incidents. With the source still
-- being checked or unavailable, the panel can only speak for the sessions it
-- holds itself, and says exactly that.
emptyStateText :: DrainerSourceState -> Text
emptyStateText source = case source of
  DrainerSourceReported _ -> "Nothing needs attention."
  DrainerSourceChecking -> "No Kanban session needs attention; the PR drainer has not answered yet."
  DrainerSourceUnavailable _ -> "No Kanban session needs attention; the PR drainer's open incidents are unavailable."

-- | Says which of the source's states produced the list above, so an empty
-- panel is never read as a verdict the drainer did not give. The detail is
-- the status's own, which is a remediation when the controller could not be
-- reached and simply names its state when the controller answered without
-- reporting a set at all — hence "open incidents unavailable" rather than a
-- bare "unavailable", which would contradict a drainer plainly reported on.
drainerSourceSummary :: DrainerSourceState -> Text
drainerSourceSummary source = case source of
  DrainerSourceReported incidents ->
    "PR drainer: "
      <> showText (length incidents)
      <> " open incident"
      <> (if length incidents == 1 then "" else "s")
  DrainerSourceChecking -> "PR drainer: checking for open incidents…"
  DrainerSourceUnavailable detail -> "PR drainer: open incidents unavailable · " <> sanitizeText detail

drawSolveChooser :: Issue -> Widget Name
drawSolveChooser issue =
  vBox
    [ withAttr cardTitleAttr (txtWrap (sanitizeText issue.issueTitle)),
      txt "",
      txt "1) codex",
      withAttr dimAttr (txt ("   " <> codexSolverModel)),
      txt "2) claude",
      withAttr dimAttr (txt ("   " <> claudeSolverModel)),
      txt "",
      withAttr footerAttr (txt "Esc cancel")
    ]

drawSolve :: AppState -> Int -> Widget Name
drawSolve state issueNumber = case Map.lookup issueNumber state.appSolveSessions of
  Nothing -> withAttr problemAttr (txt "Solve session is no longer available")
  Just session ->
    let transcript = transcriptFor state.appSettings.settingsChatVerbosity session.sessionTranscript
     in
    vBox
      [ drawSessionTabs solveSessionAttribute (solvePhaseGlyph state) issueNumber state.appSolveSessions,
        withAttr (solveSessionAttribute session) (txt (solvePhaseLabel session)),
        drawLiveActivity state (Map.member issueNumber state.appSolveProcesses) session.sessionSpinnerFrame session.sessionActivityStartedAt session.sessionActivity,
        case session.sessionDetail.solveSessionWorkflow of
          SolveOnly -> emptyWidget
          AutoSolve -> withAttr dimAttr (txt ("reviewer: " <> solveReviewerLabel session.sessionDetail.solveSessionBrand)),
        maybe emptyWidget (withAttr dimAttr . txt . ("full log: " <>) . Text.pack) session.sessionLogPath,
        txt "",
        vLimit 19
          . clickable SolveViewport
          . viewport SolveViewport Vertical
          . padRight Max
          $ if Text.null transcript
            then withAttr dimAttr (txt "Waiting for solver output…")
            else txtWrap transcript,
        hBorder,
        drawSolveInput session,
        withAttr footerAttr (txt "Esc hide  Tab next session  Ctrl-C interrupt  Enter answer  arrows/wheel scroll")
      ]

solvePhaseLabel :: SolveSession -> Text
solvePhaseLabel session = case session.sessionPhase of
  SolveStarting -> "Starting " <> workflowTitle session.sessionDetail.solveSessionWorkflow <> " with " <> solverLabel session.sessionDetail.solveSessionBrand <> "…"
  SolveRunning -> solverLabel session.sessionDetail.solveSessionBrand <> " is " <> workflowActivity session.sessionDetail.solveSessionWorkflow
  SolveInterrupting -> "Interrupting the current solver turn…"
  SolveAttention -> "Needs your input"
  SolveFinished -> "Solve workflow finished"
  SolveFailedPhase -> "Solve workflow failed"
  SolveKilledPhase -> "Solve workflow killed"
  SolveOrphanedPhase -> "Solve workflow has orphaned subprocesses"

workflowActivity :: SolveWorkflow -> Text
workflowActivity SolveOnly = "solving"
workflowActivity AutoSolve = "autosolving"

solveReviewerLabel :: SolverBrand -> Text
solveReviewerLabel CodexSolver = claudeReviewerModel
solveReviewerLabel ClaudeSolver = codexReviewerModel

drawSolveInput :: SolveSession -> Widget Name
drawSolveInput session
  | session.sessionPhase == SolveAttention,
    Just progress <- session.sessionDetail.solveSessionAutoProgress,
    progress.autoSolveStage == AutoReviewing =
      padTop (Pad 1)
        . withAttr attentionAttr
        . txtWrap
        $ "The PR agent needs input. Press Enter to open that session, or use " <> actionKeyText ShowProcesses <> " processes."
drawSolveInput session
  | session.sessionPhase == SolveAttention =
      padTop (Pad 1)
        . withAttr attentionAttr
        . txtWrap
        $ "> " <> session.sessionInput <> "█"
  | otherwise = emptyWidget

drawPullRequestReview :: AppState -> Int -> Widget Name
drawPullRequestReview state number = case Map.lookup number state.appPullRequestReviewSessions of
  Nothing -> withAttr problemAttr (txt "PR review/revision session is no longer available")
  Just session ->
    let transcript = transcriptFor state.appSettings.settingsChatVerbosity session.sessionTranscript
     in
    vBox
      [ drawSessionTabs pullRequestSessionAttribute (pullRequestPhaseGlyph state) number state.appPullRequestReviewSessions,
        withAttr (pullRequestSessionAttribute session) (txt (pullRequestPhaseLabel session)),
        drawLiveActivity state (Map.member number state.appPullRequestProcesses) session.sessionSpinnerFrame session.sessionActivityStartedAt session.sessionActivity,
        withAttr dimAttr (txt ("agent: " <> pullRequestAgentLabel session.sessionDetail.pullRequestSessionAction session.sessionDetail.pullRequestSessionBrand)),
        maybe emptyWidget (withAttr dimAttr . txt . ("full log: " <>) . Text.pack) session.sessionLogPath,
        txt "",
        vLimit 19 . clickable PullRequestReviewViewport . viewport PullRequestReviewViewport Vertical . padRight Max $
          if Text.null transcript then withAttr dimAttr (txt "Waiting for agent output…") else txtWrap transcript,
        hBorder,
        if session.sessionPhase == SolveAttention
          then padTop (Pad 1) . withAttr attentionAttr . txtWrap $ "> " <> session.sessionInput <> "█"
          else emptyWidget,
        withAttr footerAttr (txt "Esc hide  Tab next session  Ctrl-C interrupt  Enter answer  arrows/wheel scroll")
      ]

pullRequestPhaseLabel :: PullRequestReviewSession -> Text
pullRequestPhaseLabel session = case session.sessionPhase of
  SolveStarting -> "Starting PR " <> pullRequestActionText session.sessionDetail.pullRequestSessionAction <> "…"
  SolveRunning -> "PR " <> pullRequestActionText session.sessionDetail.pullRequestSessionAction <> " in progress"
  SolveInterrupting -> "Interrupting the current PR agent turn…"
  SolveAttention -> "PR workflow needs your input"
  SolveFinished -> "PR " <> pullRequestActionText session.sessionDetail.pullRequestSessionAction <> " finished"
  SolveFailedPhase -> "PR " <> pullRequestActionText session.sessionDetail.pullRequestSessionAction <> " failed"
  SolveKilledPhase -> "PR " <> pullRequestActionText session.sessionDetail.pullRequestSessionAction <> " killed"
  SolveOrphanedPhase -> "PR " <> pullRequestActionText session.sessionDetail.pullRequestSessionAction <> " has orphaned subprocesses"

drawReview :: AppState -> Int -> Widget Name
drawReview state issueNumber = case Map.lookup issueNumber state.appReviewSessions of
  Nothing -> withAttr problemAttr (txt "Review session is no longer available")
  Just session ->
    let transcript = transcriptFor state.appSettings.settingsChatVerbosity session.sessionTranscript
     in
    vBox
      [ drawSessionTabs (reviewPhaseAttribute . (.sessionPhase)) (reviewPhaseGlyph state) issueNumber state.appReviewSessions,
        txt "",
        withAttr (reviewPhaseAttribute session.sessionPhase) (txt (reviewPhaseLabel session)),
        txt "",
        vLimit 17
          . clickable ReviewViewport
          . viewport ReviewViewport Vertical
          . padRight Max
          $ if Text.null transcript
            then withAttr dimAttr (txt "Waiting for Codex output…")
            else txtWrap transcript,
        hBorder,
        drawPendingInteraction session,
        drawUndeliveredSteers session,
        drawReviewInput session,
        withAttr footerAttr (txt "Esc hide  Tab next session  Enter send  Ctrl-C interrupt  arrows/wheel scroll")
      ]

-- | The strip of tabs every session overlay carries, one per in-memory
-- session of that kind, in the same ascending numeric order @Tab@ cycles
-- through (docs\/design.md section 7). Only the colour and badge of a tab
-- are kind-specific, so those are the parameters and the strip itself exists
-- once -- which is what the solve and PR overlays had silently lost.
drawSessionTabs ::
  (AgentSession phase detail -> AttrName) ->
  (AgentSession phase detail -> Text) ->
  Int ->
  Map Int (AgentSession phase detail) ->
  Widget Name
drawSessionTabs attribute glyph selectedKey sessions =
  hBox
    . intersperse (txt "  ")
    $ map drawTab (Map.toAscList sessions)
  where
    drawTab (key, session) =
      withAttr
        (if key == selectedKey then selectedAttr else attribute session)
        (txt ("#" <> showText key <> " " <> glyph session))

reviewPhaseLabel :: ReviewSession -> Text
reviewPhaseLabel session = case session.sessionPhase of
  ReviewStarting -> "Starting " <> stageActivity session.sessionDetail.reviewSessionStage <> " session…"
  ReviewRunning -> stageActivity session.sessionDetail.reviewSessionStage <> " in progress"
  ReviewWaiting -> "Waiting for your response"
  ReviewFinished -> case session.sessionDetail.reviewSessionStage of
    IssueRevision -> "Specification amendment posted · Esc, then r for rereview"
    _ -> "Review completed"
  ReviewNeedsChanges -> case session.sessionDetail.reviewSessionStage of
    IssueRevision -> "Specification revision remains blocked"
    _ -> "Review completed with changes requested"
  ReviewFailed -> stageActivity session.sessionDetail.reviewSessionStage <> " failed"
  ReviewRevised -> "Specification revised · awaiting opposite-brand rereview"
  ReviewInterrupted -> stageActivity session.sessionDetail.reviewSessionStage <> " interrupted"
  where
    stageActivity InitialReview = "review"
    stageActivity IssueRevision = "revision"
    stageActivity IssueRereview = "rereview"

drawPendingInteraction :: ReviewSession -> Widget Name
drawPendingInteraction session = case session.sessionDetail.reviewSessionPending of
  Nothing -> emptyWidget
  Just (PendingReviewQuestion _ question) ->
    vBox
      ( [ withAttr pendingAttr (txtWrap question.reviewQuestionHeader),
          txtWrap question.reviewQuestionText
        ]
          <> zipWith drawChoice [1 :: Int ..] question.reviewQuestionChoices
          <> [withAttr dimAttr (txt "Press a choice number, or type a response when permitted.")]
      )
  Just (PendingReviewApproval _ approval) ->
    vBox
      [ withAttr pendingAttr (txt (if approval.reviewApprovalFileChange then "FILE CHANGE APPROVAL" else "COMMAND APPROVAL")),
        maybe emptyWidget txtWrap approval.reviewApprovalCommand,
        maybe emptyWidget (withAttr dimAttr . txtWrap) approval.reviewApprovalReason,
        txt "1  Allow this action once",
        txt "2  Allow similar actions for this review session",
        txt "3  Decline and return an error to the agent"
      ]
  where
    drawChoice index choice =
      txt (showText index <> "  " <> choice.reviewChoiceLabel)
        <+> if Text.null choice.reviewChoiceDescription
          then emptyWidget
          else withAttr dimAttr (txtWrap (" — " <> choice.reviewChoiceDescription))

-- | The messages a rejected steer could not put back on the input line,
-- shown above it so an undelivered message is recoverable from the session
-- itself rather than only from a transient notice (issue #17). The one that
-- did make it onto the input line needs no entry here: it is already visible
-- there, and its transcript note says it was not delivered.
drawUndeliveredSteers :: ReviewSession -> Widget Name
drawUndeliveredSteers session = case session.sessionDetail.reviewSessionUndelivered of
  [] -> emptyWidget
  messages ->
    vBox
      ( withAttr problemAttr (txt "NOT DELIVERED — sending the current message brings the next one back")
          : map (txtWrap . ("  " <>)) messages
      )

drawReviewInput :: ReviewSession -> Widget Name
drawReviewInput session =
  padTop (Pad 1)
    . withAttr neutralAttr
    . txtWrap
    $ "> " <> session.sessionInput <> "█"
