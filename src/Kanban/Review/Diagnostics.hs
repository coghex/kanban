-- | How the review workflow describes an external command that did not
-- finish the way it was asked to. Shared by the canonical gate
-- ("Kanban.Review.Canonical") and the dynamic tools
-- ("Kanban.Review.Tools"), which run different subprocesses but must agree
-- on the vocabulary — in particular on 'outcomeUnknownMessage', whose
-- marker is what tells a definite failure apart from an unobserved one.
module Kanban.Review.Diagnostics
  ( decodeClaudeBytes,
    exceptionText,
    outcomeUnknownDiagnostic,
    outcomeUnknownMessage,
    renderClaudeFailureDetails,
  )
where

import Control.Exception (Exception, displayException)
import qualified Data.ByteString.Char8 as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)

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
