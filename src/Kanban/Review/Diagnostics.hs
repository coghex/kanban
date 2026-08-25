-- | How the review workflow describes an external command that did not
-- finish the way it was asked to. Shared by the canonical gate
-- ("Kanban.Review.Canonical") and the dynamic tools
-- ("Kanban.Review.Tools"), which run different subprocesses but must agree
-- on the vocabulary — in particular on 'outcomeUnknownMessage', whose
-- marker is what tells a definite failure apart from an unobserved one.
--
-- 'claudeRevisionAgent' and 'reviewAssignmentDisplay' are here for the same
-- reason, shared one module wider with "Kanban.Review.Prompts": the text
-- handed /to/ the reviewing model and the text handed /back/ by a tool name
-- the same agent, and a second spelling of either is how a roster edit comes
-- to move one and not the other.
module Kanban.Review.Diagnostics
  ( claudeRevisionAgent,
    decodeClaudeBytes,
    exceptionText,
    outcomeUnknownDiagnostic,
    outcomeUnknownMessage,
    renderClaudeFailureDetails,
    reviewAssignmentDisplay,
  )
where

import Control.Exception (Exception, displayException)
import qualified Data.ByteString.Char8 as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Kanban.Models
  ( Assignment (..),
    AssignmentUnavailable,
    unavailableAssignmentDisplay,
  )

-- | How every review string names the agent @kanban_run_claude@ runs: the
-- unversioned brand, then the model-and-effort of the @issue_revise.claude@
-- assignment in force.
--
-- The brand stays a literal on purpose (docs\/design.md §7, requirement 2):
-- it identifies which provider is being spoken about and no roster edit can
-- falsify it. Only the portion after it comes from the roster.
claudeRevisionAgent :: Text -> Text
claudeRevisionAgent display = "Claude " <> display

-- | The model-and-effort portion a review string substitutes for the cell it
-- resolved, or a parenthesised statement that the roster cannot supply one.
--
-- Review text is prose read by a model rather than a Brick widget, so an
-- unresolvable cell cannot be dimmed; it is said instead. Naming no model is
-- the invariant that matters — a fallback to the compiled default would tell
-- the reviewing model it is talking to an agent this install cannot run.
reviewAssignmentDisplay :: Either AssignmentUnavailable Assignment -> Text
reviewAssignmentDisplay =
  either (const ("(" <> unavailableAssignmentDisplay <> ")")) (.assignmentDisplay)

-- | The shape shared by every "this side effect may already have landed"
-- diagnostic: what was actually observed, the 'outcomeUnknownMarker' that
-- makes such a result recognisable as distinct from a definite failure, and
-- the instruction for confirming real state before anything is retried.
outcomeUnknownMessage :: Text -> Text -> Text
outcomeUnknownMessage observation remedy = observation <> outcomeUnknownMarker <> " " <> remedy

outcomeUnknownMarker :: Text
outcomeUnknownMarker = ", so its outcome is unknown and it may already have completed."

-- | Whether a review diagnostic describes an unobserved outcome rather than
-- a definite failure, so a caller rendering it (the TUI's canonical-review
-- projection) never tells the operator that something failed when all that
-- actually failed was observing it.
outcomeUnknownDiagnostic :: Text -> Bool
outcomeUnknownDiagnostic = Text.isInfixOf outcomeUnknownMarker

renderClaudeFailureDetails :: ByteString.ByteString -> ByteString.ByteString -> Text
renderClaudeFailureDetails output errors =
  case filter (not . Text.null) [decodeClaudeBytes errors, decodeClaudeBytes output] of
    [] -> ""
    messages -> ": " <> Text.take claudeDiagnosticLimit (Text.intercalate "\n" messages)

decodeClaudeBytes :: ByteString.ByteString -> Text
decodeClaudeBytes = Text.strip . TextEncoding.decodeUtf8With lenientDecode

exceptionText :: Exception exception => exception -> Text
exceptionText = Text.pack . displayException

claudeDiagnosticLimit :: Int
claudeDiagnosticLimit = 4000
