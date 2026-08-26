module Kanban.UI.Overlay
  ( drawIncidents,
    drawOverlay,
    drawUndeliveredSteers,
    helpLines,
    mouseHelpEntries,
    reviewPhaseLabel,
    solveChooserDisplay,
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
import Kanban.Card (boundedLines, displayWidth, elide, wrappedLines)
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
    solveAssignment
  )
import Kanban.Settings
  ( ChatVerbosity (..),
    Settings (..),
    verbosityDescription,
    verbosityLabel
  )
import Kanban.Models (ModelRoster, OperatingMode, RecordedAssignment (..), RosterLoadError, rosterErrorMessage)
import Kanban.Text (sanitizeText)
import Kanban.UI.Keys
  ( BoardAction (..),
    HelpEntry (..),
    actionKeyText,
    bindingHelpEntry,
    gestureHelpEntry,
    helpRows,
    modeBoardBindings,
  )
import Kanban.UI.SessionCore (sessionInputHelp)
import Kanban.UI.Settings
  ( RosterRow (..),
    noProvidersMessage,
    operatingModeLine,
    resolvedSettingsFocus,
    rosterRowCell,
    rosterRowText,
    rosterRecoveryHint,
    settingsRosterRows
  )
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
      HelpOverlay -> drawHelp state
      SettingsOverlay -> drawSettings state
      ProcessesOverlay -> drawProcesses state
      IncidentsOverlay -> drawIncidents state
      DetailsOverlay item -> viewport DetailsViewport Vertical (drawDetails (detailsEnv state) item)
      ReviewOverlay issueNumber -> drawReview state issueNumber
      SolveChooser _ issue -> drawSolveChooser state issue
      SolveOverlay issueNumber -> drawSolve state issueNumber
      PullRequestReviewOverlay number -> drawPullRequestReview state number
  where
    -- The rows the help overlay is about to draw, which is what both of its
    -- dimensions are measured from. Taken once here rather than twice below,
    -- because the list follows the operating mode and a box sized from a
    -- different one would clip its own contents.
    rows = helpLines state.appOperatingMode
    overlayWidth = case overlay of
      SolveChooser _ _ -> 42
      SettingsOverlay -> 68
      ProcessesOverlay -> 100
      IncidentsOverlay -> 100
      -- Wide enough for the list it draws, for the same reason its height is:
      -- a description added to the table has to widen the box rather than be
      -- silently cut off inside it. A terminal narrower than this still clips
      -- the overlay, which is the overlay system's existing policy.
      HelpOverlay -> maximum (1 : map Text.length rows) + 4
      _ -> 88
    overlayHeight = case overlay of
      SolveChooser _ _ -> 10
      -- Tall enough for the verbosity radio above and 'settingsRosterHeight'
      -- rows of roster below it, plus the two rules and the footer between
      -- them. The roster itself is bounded rather than sized to the list, so
      -- a role or provider added later scrolls instead of growing this.
      SettingsOverlay -> 35
      ProcessesOverlay -> 32
      -- Tall enough for the list it draws, so a binding added to the table
      -- cannot silently push a row past the border: the two rows 'padAll'
      -- adds and the two the border takes are the whole difference.
      HelpOverlay -> length rows + 4
      _ -> 32
    panelExtent = case overlay of
      HelpOverlay -> id
      SettingsOverlay -> clickable SettingsPanel
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

drawHelp :: AppState -> Widget Name
drawHelp state = vBox (map txt (helpLines state.appOperatingMode))

-- | The complete binding list, in three blocks: every base-board binding in
-- §7's order, then the bindings a live-agent overlay adds, then the mouse.
--
-- Nothing here is a key hint this module wrote down. The board rows come from
-- the table in "Kanban.UI.Keys" and the overlay rows from beside the decoder
-- that answers them in "Kanban.UI.SessionCore", so the overlay cannot claim a
-- binding that dispatch does not have — which is exactly how it came to omit
-- @?@, its own binding, before this list was derived.
--
-- The board block follows the operating mode through 'modeBoardBindings', so
-- a board that loads no provider lists none of the six agent bindings here
-- either -- the help overlay and the footer hide the same set, because both
-- project from that one decision.
--
-- The session block does not, deliberately. Those keys belong to a live-agent
-- overlay's own decoder rather than to the base board, and hiding a row that
-- describes an overlay no press can open in that mode is a wider change than
-- this one: the six bindings above are what the mode decides.
helpLines :: OperatingMode -> [Text]
helpLines mode =
  helpRows (map bindingHelpEntry (modeBoardBindings mode) <> sessionInputHelp <> mouseHelpEntries)

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
      hBorder,
      withAttr cardTitleAttr (txt "Agent models"),
      withAttr dimAttr (txtWrap (operatingModeLine state.appOperatingMode)),
      drawRoster state
    ]
  where
    selected = state.appSettings.settingsChatVerbosity
    drawChoice key verbosity =
      let attribute = if verbosity == selected then selectedAttr else neutralAttr
       in withAttr attribute (txt (Text.singleton key <> ") " <> verbosityLabel verbosity))
            <=> padLeft (Pad 3) (withAttr dimAttr (txtWrap (verbosityDescription verbosity)))

-- | The roster section: one row per @(role, provider)@ assignment, inside a
-- bounded viewport.
--
-- Bounded in both directions on purpose. Vertically, because the compiled
-- roster already fills more than the panel can show and a role or provider
-- added later must scroll rather than render past the border; horizontally,
-- because the model IDs are user-supplied text and a long one has to be
-- elided at the interior the panel really has rather than cropped silently
-- by the viewport.
drawRoster :: AppState -> Widget Name
drawRoster state =
  vLimit settingsRosterHeight
    . viewport SettingsViewport Vertical
    $ case state.appModelRoster of
      -- The defect replaces the rows rather than sitting beside fabricated
      -- ones, and says what the one available action would do to the file
      -- before the key is pressed.
      Left loadError ->
        vBox
          [ withAttr problemAttr (txtWrap (rosterErrorMessage loadError)),
            padTop (Pad 1) (withAttr dimAttr (txtWrap rosterRecoveryHint))
          ]
      Right _
        | null rows -> withAttr dimAttr (txtWrap noProvidersMessage)
        | otherwise -> vBox (map drawRow rows)
  where
    rows = settingsRosterRows state.appModelRoster
    focused = resolvedSettingsFocus state.appModelRoster state.appSettingsFocus
    drawRow row =
      let selected = Just (rosterRowCell row) == focused
          attribute
            | selected = selectedAttr
            | row.rosterRowIsDefault = dimAttr
            | otherwise = neutralAttr
          widget =
            clickable
              (SettingsRosterTarget row.rosterRowRole row.rosterRowProvider)
              (withAttr attribute (elidedRow (rosterRowText row)))
       in if selected then visible widget else widget

-- | One already-laid-out row, elided at the width the panel really has.
--
-- Distinct from 'elidedLine' on purpose. That one re-flows the text first,
-- which is right for a row built out of single-spaced fields and wrong here:
-- a roster row is columns, and wrapping collapses the runs of spaces the
-- columns are made of. So this measures and cuts instead, and cuts only when
-- there is something to cut — 'elide' appends its ellipsis unconditionally.
elidedRow :: Text -> Widget Name
elidedRow line = Widget Fixed Fixed $ do
  context <- getContext
  let width = availWidth context
  render (txt (if width <= 0 then "" else if displayWidth line <= width then line else elide width line))

-- | How many roster rows the settings panel shows at once. Fewer than the
-- compiled thirteen, so the viewport the rows live in is exercised by the
-- default roster rather than only by a future one.
settingsRosterHeight :: Int
settingsRosterHeight = 10

drawProcesses :: AppState -> Widget Name
drawProcesses state =
  vBox
    [ withAttr dimAttr (txt ("tracked sessions: " <> showText (length entries) <> " · live processes: " <> showText (length (filter (.agentSessionLive) entries)))),
      txt "",
      vLimit 23
        . viewport ProcessesViewport Vertical
        $ if null entries
          then withAttr dimAttr (txt "No agent sessions have been started.")
          else vBox (zipWith drawEntry [0 :: Int ..] entries)
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
          else vBox (zipWith drawEntry [0 :: Int ..] entries)
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
-- Bounded in height as well as width. A note is one incident's detail while
-- the panel's rows are shared, so it may take at most 'incidentNoteLines'.
-- What is dropped to fit is the /middle/: a drainer's recorded failure opens
-- by restating what failed and closes with the blocker, the remedy and the
-- paths to act on, so trimming the tail would keep only the part the row
-- already said. The first line and the last are kept, and the gap between
-- them is marked.
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
          rows = keepEnds body (wrappedLines body note)
      render (vBox [txt (indent <> prefix <> row) | (prefix, row) <- zip (marker : repeat continuation) rows])
    keepEnds body rows
      | length rows <= incidentNoteLines = rows
      | otherwise = case rows of
          first : _ -> elide body first : drop (length rows - (incidentNoteLines - 1)) rows
          [] -> []

-- | How many continuation lines one note may take. A note belongs to a
-- single incident while the panel's height is shared, so three lines is the
-- whole allowance.
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

-- | The two brands a solve may be started on, each under the @solve@ cell it
-- would actually run: row 1 @solve.codex@, row 2 @solve.claude@.
--
-- Drawn before any refusal, which is why each row resolves independently and
-- neither falls back to the compiled default. A roster that will not load, or
-- one that loads only the other brand, reaches this overlay unchanged --
-- 'Kanban.UI.Solve.solveStartDecision' refuses on the digit press, not on the
-- key that opened the chooser -- so the row for the brand it cannot supply
-- says so rather than naming a model no spawn would use.
drawSolveChooser :: AppState -> Issue -> Widget Name
drawSolveChooser state issue =
  vBox
    [ withAttr cardTitleAttr (txtWrap (sanitizeText issue.issueTitle)),
      txt "",
      txt "1) codex",
      withAttr dimAttr (txt ("   " <> solveChooserDisplay state.appModelRoster CodexSolver)),
      txt "2) claude",
      withAttr dimAttr (txt ("   " <> solveChooserDisplay state.appModelRoster ClaudeSolver))
    ]

-- | One chooser row's model line: the @solve@ cell that row's brand would
-- run, resolved live because no session exists yet to have recorded one.
solveChooserDisplay :: Either RosterLoadError ModelRoster -> SolverBrand -> Text
solveChooserDisplay rosterResult brand =
  liveAssignmentDisplay (.recordedAssignmentDisplay) (`solveAssignment` brand) rosterResult

drawSolve :: AppState -> Int -> Widget Name
drawSolve state issueNumber = case Map.lookup issueNumber state.appSolveSessions of
  Nothing -> withAttr problemAttr (txt "Solve session is no longer available")
  Just session ->
    let transcript = transcriptFor state.appSettings.settingsChatVerbosity session.sessionTranscript
     in
    vBox
      [ drawSessionMode (solveSessionMode session)
          <+> txt "  "
          <+> drawSessionTabs solveSessionAttribute (solvePhaseGlyph state) issueNumber state.appSolveSessions,
        withAttr (solveSessionAttribute session) (txt (solvePhaseLabel state.appModelRoster session)),
        drawLiveActivity state (Map.member issueNumber state.appSolveProcesses) session.sessionSpinnerFrame session.sessionActivityStartedAt session.sessionActivity,
        case session.sessionDetail.solveSessionWorkflow of
          SolveOnly -> emptyWidget
          AutoSolve -> withAttr dimAttr (txt ("reviewer: " <> solveReviewerDisplay state.appModelRoster session.sessionDetail.solveSessionBrand)),
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
        drawSolveInput session
      ]

solvePhaseLabel :: Either RosterLoadError ModelRoster -> SolveSession -> Text
solvePhaseLabel rosterResult session = case session.sessionPhase of
  SolveStarting -> "Starting " <> workflowTitle session.sessionDetail.solveSessionWorkflow <> " with " <> solveSessionLabel rosterResult session <> "…"
  SolveRunning -> solveSessionLabel rosterResult session <> " is " <> workflowActivity session.sessionDetail.solveSessionWorkflow
  SolveInterrupting -> "Interrupting the current solver turn…"
  SolveAttention -> "Needs your input"
  SolveFinished -> "Solve workflow finished"
  SolveFailedPhase -> "Solve workflow failed"
  SolveKilledPhase -> "Solve workflow killed"
  SolveOrphanedPhase -> "Solve workflow has orphaned subprocesses"

workflowActivity :: SolveWorkflow -> Text
workflowActivity SolveOnly = "solving"
workflowActivity AutoSolve = "autosolving"

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
      [ drawSessionMode (solveSessionMode session)
          <+> txt "  "
          <+> drawSessionTabs pullRequestSessionAttribute (pullRequestPhaseGlyph state) number state.appPullRequestReviewSessions,
        withAttr (pullRequestSessionAttribute session) (txt (pullRequestPhaseLabel session)),
        drawLiveActivity state (Map.member number state.appPullRequestProcesses) session.sessionSpinnerFrame session.sessionActivityStartedAt session.sessionActivity,
        withAttr dimAttr (txt ("agent: " <> pullRequestSessionLabel session.sessionDetail.pullRequestSessionAssignment session.sessionDetail.pullRequestSessionOrigin session.sessionDetail.pullRequestSessionAction session.sessionDetail.pullRequestSessionBrand state.appModelRoster)),
        maybe emptyWidget (withAttr dimAttr . txt . ("full log: " <>) . Text.pack) session.sessionLogPath,
        txt "",
        vLimit 19 . clickable PullRequestReviewViewport . viewport PullRequestReviewViewport Vertical . padRight Max $
          if Text.null transcript then withAttr dimAttr (txt "Waiting for agent output…") else txtWrap transcript,
        hBorder,
        if session.sessionPhase == SolveAttention
          then padTop (Pad 1) . withAttr attentionAttr . txtWrap $ "> " <> session.sessionInput <> "█"
          else emptyWidget
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
      [ drawSessionMode (reviewSessionMode session)
          <+> txt "  "
          <+> drawSessionTabs (reviewPhaseAttribute . (.sessionPhase)) (reviewPhaseGlyph state) issueNumber state.appReviewSessions,
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
        drawReviewInput session
      ]

-- | The mode badge every session overlay carries for the session it is
-- showing (issue #515). Its argument comes from 'solveSessionMode' or
-- 'reviewSessionMode', so a session with nothing left to read what it types
-- shows @[N]@ whatever its stored mode holds -- the same derivation the key
-- decoder and the digit path use, rather than a third opinion about it.
drawSessionMode :: SessionMode -> Widget Name
drawSessionMode = \case
  SessionNormal -> withAttr dimAttr (txt "[N]")
  SessionInsert -> withAttr insertModeAttr (txt "[I]")

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
          <> [withAttr dimAttr (txt "Press a choice number, or i to type a response when permitted.")]
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
