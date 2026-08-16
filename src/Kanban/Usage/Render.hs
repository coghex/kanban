-- | The pure half of the usage surface: turning acquired snapshots into the
-- lines @kanban --usage@ prints, and into the machine-readable document it
-- emits under @--json@.  Nothing here performs IO or depends on Brick, so the
-- sidebar can render from exactly these functions rather than a second copy of
-- the same arithmetic.
module Kanban.Usage.Render
  ( UsageOutcome (..),
    UsageReport (..),
    formatUsageDuration,
    renderUsageReport,
    usageDurationDayBound,
    usageProviderKey,
    usageProviderName,
    usageReportDocument,
    usageReportProduced,
    usageResetCountdownText,
    usageResetLocalText,
    usageRfc3339,
    usageSnapshotAgeText,
    usageSolveRoundsLeft,
    usageSolveRoundsSuffix,
    usageSolveRoundsText,
  )
where

import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson.Key as Key
import Data.List (intercalate)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (NominalDiffTime, TimeZone, UTCTime, defaultTimeLocale, diffUTCTime, formatTime, utcToZonedTime)
import Kanban.Domain (UsageProvider (..), UsageSnapshot (..), UsageWindow (..))

-- | What the selected acquisition path produced for one provider.  A failure
-- is carried rather than dropped, so one provider's error can be printed
-- beside the other's windows and represented explicitly in the JSON document
-- instead of leaving that provider missing.
data UsageOutcome
  = UsageAvailable UsageSnapshot
  | UsageFailed Text
  deriving stock (Eq, Show)

-- | One run's outcome for every provider, in the order it is reported.
newtype UsageReport = UsageReport {usageReportEntries :: [(UsageProvider, UsageOutcome)]}
  deriving stock (Eq, Show)

-- | Whether any provider produced windows, which is the mode's exit status.
--
-- An empty snapshot is not a provider that produced windows, however it
-- reached here: 'Kanban.UsageCommand.decodeUsageCommandDocument' already
-- rejects an empty live document, but the generic cache decoder establishes no
-- such invariant, so a usage file written by another release can still decode
-- to one.
usageReportProduced :: UsageReport -> Bool
usageReportProduced report = any (produced . snd) report.usageReportEntries
  where
    produced (UsageAvailable snapshot) = not (null snapshot.usageWindows)
    produced (UsageFailed _) = False

-- | The human rendering: a pure function of the report, the configured
-- per-provider solve-round estimates, an explicitly supplied current time, and
-- the zone reset instants are stated in.
--
-- The zone is an input for the same reason the clock is.  A reset time is
-- printed as a local wall clock, and a renderer that read either from the
-- process could not be pinned by a fixture; the sidebar supplies its
-- @appTimeZone@ here for the same reason.  The estimates are an input on those
-- same terms: they come from resolved configuration, and a renderer that read
-- that itself could not be pinned either.  A provider absent from the map
-- configured no estimate and renders none.
renderUsageReport :: Map UsageProvider Int -> TimeZone -> UTCTime -> UsageReport -> [Text]
renderUsageReport estimates zone now report =
  intercalate [""] (map (renderEntry estimates zone now) report.usageReportEntries)

renderEntry :: Map UsageProvider Int -> TimeZone -> UTCTime -> (UsageProvider, UsageOutcome) -> [Text]
renderEntry estimates zone now (provider, outcome) = usageProviderName provider : body
  where
    estimate = Map.lookup provider estimates
    body = case outcome of
      UsageFailed message -> ["  unavailable: " <> message]
      UsageAvailable snapshot ->
        windowLines snapshot <> ["  snapshot " <> usageSnapshotAgeText (diffUTCTime now snapshot.usageFetchedAt)]
    windowLines snapshot
      | null snapshot.usageWindows = ["  no usage windows reported"]
      | otherwise = map (renderWindowLine estimate zone now (labelWidth snapshot)) snapshot.usageWindows

-- | Labels are padded to the widest one this provider reported, so the columns
-- line up without depending on anything outside the snapshot being rendered.
labelWidth :: UsageSnapshot -> Int
labelWidth snapshot = maximum (1 : map (Text.length . (.usageWindowLabel)) snapshot.usageWindows)

-- | One window's line.  The estimate is appended to the window it describes
-- rather than given a line of its own, because a provider commonly reports
-- more than one window and a line standing alone would not say which of them
-- it counted.  Nothing before the estimate changes: the label padding, the
-- percentage column, the countdown, and the parenthesized reset time are what
-- they were, and an unconfigured provider's line ends where it always did.
renderWindowLine :: Maybe Int -> TimeZone -> UTCTime -> Int -> UsageWindow -> Text
renderWindowLine estimate zone now width window =
  "  "
    <> Text.justifyLeft width ' ' window.usageWindowLabel
    <> "  "
    <> Text.justifyRight 3 ' ' (Text.pack (show window.usagePercentLeft))
    <> "% left · resets "
    <> usageResetCountdownText (diffUTCTime window.usageResetsAt now)
    <> " ("
    <> usageResetLocalText zone window.usageResetsAt
    <> ")"
    <> maybe "" ((" · " <>) . usageSolveRoundsText) (usageSolveRoundsLeft estimate window.usagePercentLeft)

-- | How many whole solve rounds a window's remaining percentage buys, given
-- what one round is configured to cost for that provider.  This is the one
-- derivation both surfaces read the count off: the sidebar's compact suffix
-- and the printed line state the same number for the same inputs because
-- neither computes it.
--
-- Integer division rounds down, so a remaining percentage that does not cover
-- one whole round is zero rounds rather than a fraction of one — and zero is a
-- real answer that renders, not an absent estimate.
--
-- The remaining percentage is clamped at zero first.  Only the live
-- external-command decoder bounds @pct_left@ to 0-100; a snapshot decoded from
-- the cache carries whatever was written there, and Haskell's 'div' rounds
-- toward negative infinity, so an out-of-range stored value would otherwise
-- render as a negative number of rounds.  A non-positive estimate is treated
-- as unconfigured for the same class of reason: configuration rejects it, and
-- dividing by it here would be an arithmetic exception rather than a rendering
-- fault.
usageSolveRoundsLeft :: Maybe Int -> Int -> Maybe Int
usageSolveRoundsLeft estimate percentLeft = do
  percentPerRound <- estimate
  if percentPerRound <= 0 then Nothing else Just (max 0 percentLeft `div` percentPerRound)

-- | The estimate as @kanban --usage@ and @kanban --ping@ state it, where there
-- is no width to budget and the count can be spelled out.
usageSolveRoundsText :: Int -> Text
usageSolveRoundsText rounds = "≈" <> Text.pack (show rounds) <> " solve rounds left this window"

-- | The estimate as the sidebar appends it to a reset row, where there is not
-- room to spell it out.  The leading separator is part of the suffix: the
-- caller either appends the whole thing or none of it, and measuring the
-- separator with the count is what makes that decision honest.
usageSolveRoundsSuffix :: Int -> Text
usageSolveRoundsSuffix rounds = " · ≈" <> Text.pack (show rounds)

-- | How long until a window resets, in the one wording both the @--usage@
-- line and the sidebar's reset row state it in.
--
-- A reset instant already behind the clock is named rather than counted down
-- to. 'formatUsageDuration' clamps at zero, so an elapsed reset would
-- otherwise read @in 0s@ — a countdown to an instant that has passed, which
-- says something false about a window whose reset is overdue.
usageResetCountdownText :: NominalDiffTime -> Text
usageResetCountdownText remaining
  | remaining <= 0 = "due now"
  | otherwise = "in " <> formatUsageDuration remaining

-- | How old the snapshot being displayed is, in the one wording both surfaces
-- state it in.
usageSnapshotAgeText :: NominalDiffTime -> Text
usageSnapshotAgeText age = formatUsageDuration age <> " old"

-- | A reset instant as a local wall clock, in the same shape the sidebar
-- already prints.
usageResetLocalText :: TimeZone -> UTCTime -> Text
usageResetLocalText zone instant =
  Text.pack (formatTime defaultTimeLocale "%a %H:%M" (utcToZonedTime zone instant))

-- | Durations are clamped at zero.  A reset instant already in the past and a
-- snapshot stamped ahead of the supplied clock are both reachable states —
-- 'UsageWindow' and 'UsageSnapshot' store unrestricted 'UTCTime' values, and
-- the clock is an input rather than the one that wrote them — and neither
-- should ever render as a negative countdown or a negative age.
--
-- They are bounded above for the same reason they are clamped below: nothing
-- restricts how distant a decoded @resets_at@ may be, so a duration counted
-- out in full would widen without limit.  Past 'usageDurationDayBound' days
-- the count gives way to a bound, which caps this at the seven cells of
-- @99d 23h@ — the figure the sidebar's fixed interior is budgeted against.
formatUsageDuration :: NominalDiffTime -> Text
formatUsageDuration difference
  | days > usageDurationDayBound = ">" <> Text.pack (show usageDurationDayBound) <> "d"
  | days > 0 = Text.pack (show days) <> "d " <> Text.pack (show hours) <> "h"
  | hours > 0 = Text.pack (show hours) <> "h " <> Text.pack (show minutes) <> "m"
  | minutes > 0 = Text.pack (show minutes) <> "m"
  | otherwise = Text.pack (show seconds) <> "s"
  where
    total = max 0 (truncate difference) :: Integer
    days = total `div` 86400
    hours = (total `mod` 86400) `div` 3600
    minutes = (total `mod` 3600) `div` 60
    seconds = total `mod` 60

-- | The largest number of whole days 'formatUsageDuration' counts out before
-- reporting a bound instead.
usageDurationDayBound :: Integer
usageDurationDayBound = 99

-- | The @--json@ document.  Its shape is a contract for scripts: lowercase
-- provider keys, an explicit @status@ discriminator so a failed provider is
-- present rather than missing, and absolute RFC 3339 UTC timestamps that need
-- no knowledge of the reader's zone.
usageReportDocument :: UsageReport -> Value
usageReportDocument report =
  object
    [ "schema_version" .= (1 :: Int),
      "providers" .= object (map entry report.usageReportEntries)
    ]
  where
    entry (provider, outcome) = Key.fromText (usageProviderKey provider) .= outcomeValue outcome
    outcomeValue (UsageFailed message) =
      object ["status" .= ("error" :: Text), "error" .= message]
    outcomeValue (UsageAvailable snapshot) =
      object
        [ "status" .= ("ok" :: Text),
          "fetched_at" .= usageRfc3339 snapshot.usageFetchedAt,
          "windows" .= map windowValue snapshot.usageWindows
        ]
    windowValue window =
      object
        [ "label" .= window.usageWindowLabel,
          "pct_left" .= window.usagePercentLeft,
          "resets_at" .= usageRfc3339 window.usageResetsAt
        ]

-- | Whole seconds in UTC, rather than aeson's own encoding, so the document
-- carries one timestamp spelling regardless of whether the instant it came
-- from happened to have a fractional part.
usageRfc3339 :: UTCTime -> Text
usageRfc3339 = Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | The provider's key in the JSON document.
usageProviderKey :: UsageProvider -> Text
usageProviderKey Codex = "codex"
usageProviderKey Claude = "claude"

-- | The provider's heading in the human rendering.
usageProviderName :: UsageProvider -> Text
usageProviderName Codex = "Codex"
usageProviderName Claude = "Claude"
