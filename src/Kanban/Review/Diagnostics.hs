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
--
-- 'missingEmbeddedReviewMessage' is here on the same terms: it is the second
-- of the two refusals a launch of the embedded issue review can end in, and
-- it is said beside the review's other shared vocabulary rather than at the
-- launch boundary that happens to discover it. The first of the two stays
-- 'Kanban.Models.assignmentUnavailableMessage', called where it always was.
module Kanban.Review.Diagnostics
  ( claudeRevisionAgent,
    decodeClaudeBytes,
    exceptionText,
    missingEmbeddedReviewMessage,
    outcomeUnknownDiagnostic,
    outcomeUnknownMessage,
    renderClaudeFailureDetails,
    reviewAssignmentDisplay,
    reviewSessionDiagnostic,
    sentenceCase,
    unsupportedReviewOperationMessage,
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
    ProviderName,
    providerKey,
    unavailableAssignmentDisplay,
  )

-- | The refusal a launch gets when the provider it resolved to has no
-- embedded issue-review backend at all.
--
-- Distinct from 'Kanban.Models.assignmentUnavailableMessage', which the same
-- launch consults first, because the causes are: that one says the operator's
-- roster cannot supply a cell, this one says Kanban itself ships no backend
-- for the provider. Both compiled providers carry one from MODEL-13 onwards,
-- so nothing an install can route to answers to it today; it stays because
-- 'Kanban.ProviderAdapter.adapterEmbeddedReview' is a field a provider may
-- lack, and the launch that reads it must say so by name rather than
-- silently doing nothing.
missingEmbeddedReviewMessage :: ProviderName -> Text
missingEmbeddedReviewMessage provider =
  "Kanban has no embedded issue-review backend for provider \""
    <> providerKey provider
    <> "\""

-- | A diagnostic about a backend's own session: which program it is, then
-- what that program did.
--
-- The backend supplies the subject and whatever read its output supplies the
-- predicate. That split is what lets a decoder which knows a protocol and
-- nothing about the provider speaking it produce a sentence naming the right
-- program: a decoder that spelled the brand itself would name it in every
-- install, including one where a different provider is running the same
-- channel.
reviewSessionDiagnostic :: Text -> Text -> Text
reviewSessionDiagnostic backendLabel detail = sentenceCase backendLabel <> " " <> detail

-- | A backend label at the start of a sentence. The labels name a program
-- (@codex app-server@), so they stay lowercase where a diagnostic mentions
-- one inline and are capitalized where one opens the sentence.
sentenceCase :: Text -> Text
sentenceCase value = Text.toUpper (Text.take 1 value) <> Text.drop 1 value

-- | The refusal an operation gets from a backend Kanban does not drive it
-- through.
--
-- Unlike every other refusal here, nothing has gone wrong: the backend is
-- healthy and the thread is running, and the operation is one a later slice
-- adds. Said once because two backends can reach it for different
-- operations, and because a refusal that named the other provider's protocol
-- -- which is what reusing that protocol's diagnostics would do -- would
-- report a program the operator is not running.
unsupportedReviewOperationMessage :: Text -> Text -> Text
unsupportedReviewOperationMessage backendLabel operation =
  "Kanban cannot " <> operation <> " on " <> backendLabel <> " yet"

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
