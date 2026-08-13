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
    primaryRateLimited,
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
-- which for this path is the choice between @AUTH REQUIRED@, @RATE LIMITED@
-- and @REQUEST ERROR@.
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
  | primaryRateLimited message = RateLimited
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

-- | Whether GitHub attributed this failure to its own /primary/ rate limit.
--
-- The distinction earns a kind of its own because it is the only failure that
-- comes with a remedy the scheduler can act on: the budget returns at a time
-- GitHub reports, so the job waits rather than being reissued. That makes a
-- false positive expensive -- a refresh held back over an unrelated error --
-- so the match is against the phrases GitHub actually uses for the primary
-- limit, never a bare word such as \"token\" or \"limit\".
--
-- The secondary limit is deliberately excluded. It is a short abuse-detection
-- block with no reported reset, so it carries nothing to schedule against and
-- stays an ordinary request error; excluding it first also keeps a message
-- naming both from being read as the primary one.
primaryRateLimited :: Text -> Bool
primaryRateLimited message
  | any (`Text.isInfixOf` folded) secondaryRateLimitPhrases = False
  | otherwise = any (`Text.isInfixOf` folded) primaryRateLimitPhrases
  where
    folded = Text.toCaseFold message

-- | The phrases GitHub and @gh@ use when the primary rate limit is what
-- refused the request, already case-folded.
primaryRateLimitPhrases :: [Text]
primaryRateLimitPhrases =
  [ -- The REST and GraphQL bodies returned with an exhausted hourly budget.
    "api rate limit exceeded",
    -- GraphQL answers an exhausted budget with this error type, which travels
    -- in the message text once a rejected page's errors are folded together.
    "rate_limited"
  ]

secondaryRateLimitPhrases :: [Text]
secondaryRateLimitPhrases = ["secondary rate limit"]

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
