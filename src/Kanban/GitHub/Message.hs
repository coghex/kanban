-- | Turning the text @gh@ and GitHub author into the bounded, single-line
-- vocabulary section 17 renders.
--
-- Everything here is about text this build did not write: gh's stderr, the
-- messages in a GraphQL @errors@ array, and the bytes gh wrote to its pipes.
-- None of it decodes a response or runs a process, which is why it sits below
-- both.
module Kanban.GitHub.Message
  ( classifyFailure,
    compactError,
    decodeGhOutput,
    normalizeSpacing,
    partialResponseWarning,
    withGraphQLErrors,
  )
where

import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Kanban.Provider (ProviderErrorKind (..))

-- | Sorts a failed @gh@ invocation onto the vocabulary section 17 renders,
-- which for this path is the choice between @AUTH REQUIRED@ and
-- @REQUEST ERROR@.
--
-- The match is by phrase, and deliberately not by keyword. \"token\" alone
-- occurs in messages that say nothing about credentials -- a rate limiter's
-- token bucket, a cursor rejected as an invalid pagination token -- and
-- @AUTH REQUIRED@ tells a fully authenticated user to go and log in again
-- over what is usually a transient server error. Misclassifying the other way
-- costs far less: a real authentication failure reported as @REQUEST ERROR@
-- still carries gh's own message, which says what to do.
classifyFailure :: Text -> ProviderErrorKind
classifyFailure message
  | any (`Text.isInfixOf` Text.toCaseFold message) authenticationPhrases = AuthenticationRequired
  | otherwise = RequestFailed

-- | The phrases @gh@ and the GitHub API actually use when the credentials are
-- what failed, already case-folded so 'classifyFailure' can compare them
-- against a folded message.
authenticationPhrases :: [Text]
authenticationPhrases =
  [ -- gh's own remediation line, which it prints on every auth failure.
    "gh auth login",
    "authentication required",
    -- The body GitHub returns with an HTTP 401.
    "requires authentication",
    -- \"You are not logged into any GitHub hosts.\"
    "not logged into",
    -- A token that is present but rejected.
    "bad credentials"
  ]

-- | The one decoding every byte @gh@ writes goes through. GitHub's API output
-- is UTF-8 by contract, and 'lenientDecode' means a truncated or corrupted
-- response still yields a readable diagnostic instead of an exception raised
-- from inside the decoder.
decodeGhOutput :: ByteString.ByteString -> Text
decodeGhOutput = TextEncoding.decodeUtf8With lenientDecode

compactError :: Text -> Text
compactError rawMessage =
  let message = normalizeSpacing rawMessage
   in if Text.null message then "GitHub request failed" else Text.take providerMessageLimit message

-- | How much provider-authored text section 17's single status line will
-- carry. gh's stderr and GitHub's GraphQL messages are both unbounded, and
-- both share this line with the counts and the snapshot time.
providerMessageLimit :: Int
providerMessageLimit = 500

-- | Collapses the newlines and runs of spaces external text arrives with, so
-- it occupies one line rather than wrapping the banner.
normalizeSpacing :: Text -> Text
normalizeSpacing = Text.unwords . Text.words

-- | Joins a response's GraphQL error messages for display, in the order
-- GitHub reported them and under the same bound as gh's stderr.
graphQLErrorSummary :: [Text] -> Text
graphQLErrorSummary = Text.take providerMessageLimit . Text.intercalate "; "

-- | Adds the messages GitHub sent to the structural reason a response was
-- rejected. The shape complaint says what the decoder could not find; only
-- these say why GitHub did not send it.
withGraphQLErrors :: [Text] -> Text -> Text
withGraphQLErrors [] reason = reason
withGraphQLErrors messages reason = reason <> ": " <> graphQLErrorSummary messages

-- | The banner line a structurally complete response carrying errors earns.
-- The board renders the page it did deliver; this is what says the page is
-- not the whole answer.
partialResponseWarning :: [Text] -> Text
partialResponseWarning messages =
  "GitHub could not resolve part of this refresh: " <> graphQLErrorSummary messages
