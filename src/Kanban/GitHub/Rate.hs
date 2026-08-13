-- | What GitHub says a refresh's budget is, and what background work may do
-- with it.
--
-- A rate report is external text like everything else in this layer, so it is
-- read leniently and never fails a page: a response that omits the field, or
-- answers it with something this build cannot reason about, leaves the budget
-- simply unknown. Only a complete, self-consistent report is a sample at all,
-- which is what lets every consumer treat 'Just' as trustworthy without
-- re-checking it.
module Kanban.GitHub.Rate
  ( HistoryRateVerdict (..),
    RateSample (..),
    foregroundRateReserve,
    historyRateVerdict,
    rateSampleFromResponse,
    usableRateSample,
  )
where

import Control.Applicative (optional)
import Control.Monad (join)
import Data.Aeson (FromJSON (parseJSON), Value, decodeStrict, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString as ByteString
import Data.Time (UTCTime)

-- | One page's rate report, exactly as GitHub gave it: what the page cost,
-- what is left of the budget, and when that budget returns.
data RateSample = RateSample
  { rateSampleCost :: Int,
    rateSampleRemaining :: Int,
    rateSampleResetAt :: UTCTime
  }
  deriving stock (Eq, Show)

instance FromJSON RateSample where
  parseJSON = withObject "rateLimit" $ \object ->
    RateSample
      <$> object .: "cost"
      <*> object .: "remaining"
      <*> object .: "resetAt"

-- | Whether a decoded report is usable at all.
--
-- A negative cost or remaining is not a budget this build can subtract
-- against, and treating one as a number would let a nonsense response pause
-- background work forever. Reset time needs no check here: a value that is not
-- a timestamp never decodes into a sample in the first place.
usableRateSample :: RateSample -> Maybe RateSample
usableRateSample sample
  | sample.rateSampleCost < 0 = Nothing
  | sample.rateSampleRemaining < 0 = Nothing
  | otherwise = Just sample

-- | Reads the rate report out of one @gh api graphql@ response body.
--
-- Every failure below is an absent sample rather than an error: the body may
-- not be JSON at all (gh printed a diagnostic), may carry no @data@ (a
-- validation or rate-limit rejection), may omit @rateLimit@ (a deployment
-- that does not report one), or may answer it with a malformed object. None of
-- those is a reason to fail a refresh that GitHub otherwise answered.
rateSampleFromResponse :: ByteString.ByteString -> Maybe RateSample
rateSampleFromResponse body = decodeStrict body >>= rateSampleIn

rateSampleIn :: Value -> Maybe RateSample
rateSampleIn root = join (parseMaybe rateLimitParser root) >>= usableRateSample
  where
    rateLimitParser = withObject "GraphQL response" $ \response ->
      fmap join . optional $ do
        responseData <- response .: "data"
        flip (withObject "data") responseData $ \payload ->
          optional (payload .: "rateLimit")

-- | The budget held back for foreground work, in GitHub's own GraphQL points.
--
-- Background history is the only thing this reserve is enforced against, and
-- it exists so that a traversal running for minutes cannot spend the budget
-- the next @u@ needs. The size is one comfortable foreground refresh at the
-- configured caps — 250 issues and 100 pull requests with their nested
-- connections — rounded up, since the point of a reserve is to be spent by a
-- refresh that has not been asked for yet. It is deliberately a constant with
-- no configuration key: a value a user could lower to zero would silently
-- retire the guarantee.
foregroundRateReserve :: Int
foregroundRateReserve = 200

-- | Whether background history may issue its next page.
data HistoryRateVerdict
  = HistoryMayRun
  | -- | The reserve would be spent by another page, so history waits until
    -- GitHub says the budget returns.
    HistoryPausedUntil UTCTime
  deriving stock (Eq, Show)

-- | The reserve decision, taken against the newest report a page produced.
--
-- An unknown budget runs: section 13 keeps a refresh working against a
-- deployment that reports no rate metadata at all, and pausing on silence
-- would stop history for good there. The comparison is @<=@ rather than @<@
-- because the reserve is the balance that must survive: a page allowed to
-- spend down to it has already spent the last reserved point.
historyRateVerdict :: Maybe RateSample -> HistoryRateVerdict
historyRateVerdict Nothing = HistoryMayRun
historyRateVerdict (Just sample)
  | sample.rateSampleRemaining <= foregroundRateReserve = HistoryPausedUntil sample.rateSampleResetAt
  | otherwise = HistoryMayRun
