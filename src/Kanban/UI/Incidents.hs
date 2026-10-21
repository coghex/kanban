-- | The incidents panel's rows, selection and activation.
--
-- The panel lists the PR drainer's open incidents and nothing else. Everything
-- here is pure on 'AppState': the rows, the stable-identity selection, and the
-- board work activating a row goes to, so the whole interaction can be decided
-- without a terminal ('Kanban.UI.Events.applyIncidentsAction' carries it out).
module Kanban.UI.Incidents
  ( BoardWorkLocation (..),
    IncidentActivation (..),
    drainerSourceState,
    incidentEntries,
    incidentSourceLabel,
    incidentsFooterHints,
    locateBoardWork,
    resolveIncidentActivation,
    resolveIncidentClick,
    resolveIncidentSelection,
  )
where

import Data.List (find, findIndex)
import qualified Data.Text as Text
import Data.Text (Text)
import Kanban.Card (middleExcerpt)
import Kanban.Domain
import Kanban.Drainer
  ( DrainerIncident (..),
    DrainerState (..),
    DrainerStatus (..),
    cleanupIncidentKind,
    crashIncidentKind
    )
import Kanban.Text (sanitizeText)
import Kanban.UI.Keys (BoardAction (..), binding, footerHint)
import Kanban.UI.Selection
import Kanban.UI.Types
import Kanban.UI.Util

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


-- | Every row the incidents panel lists: the drainer's own incidents, newest
-- first as the service returned them. Order is presentational only --
-- 'IncidentRef' is what selection and activation resolve against -- so a
-- refresh that reorders this list cannot redirect either.
incidentEntries :: AppState -> [IncidentEntry]
incidentEntries state =
  case drainerSourceState state.appDrainerStatus state.appDrainerIncidents of
    DrainerSourceReported incidents -> map (drainerIncidentEntry state) incidents
    DrainerSourceChecking -> []
    DrainerSourceUnavailable _ -> []

-- | One drainer incident as a row.
drainerIncidentEntry :: AppState -> DrainerIncident -> IncidentEntry
drainerIncidentEntry state incident =
  IncidentEntry
    { incidentEntryRef = DrainerIncidentRef incident.incidentId,
      incidentEntrySource = DrainerSource,
      incidentEntryWork = work,
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
-- the same reason the panel's resolver sits beside it.
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

-- | Resolves an incidents-panel selection against the current rows by stable
-- identity: follow the tracked identity to wherever it now sits, and otherwise clamp the last-known row so the panel still has
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
          (Just (entry.incidentEntrySubject <> " · " <> entry.incidentEntryDetail))
      Just work -> case locateBoardWork board work of
        Just location -> IncidentActivation (Just location) Nothing
        -- Absent from this board, or truncated off it. Either way there is
        -- no row to select, and moving the selection somewhere else would be
        -- worse than saying so.
        Nothing -> IncidentActivation Nothing (Just (workAbsentNotice work))

workAbsentNotice :: ItemId -> Text
workAbsentNotice (IssueId number) = "Issue #" <> showText number <> " is not on the current board"
workAbsentNotice (PullRequestId number) = "PR #" <> showText number <> " is not on the current board"
