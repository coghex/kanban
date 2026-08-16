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
    usageProviderKey,
    usageProviderName,
    usageReportDocument,
    usageReportProduced,
    usageResetLocalText,
    usageRfc3339,
  )
where

import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson.Key as Key
import Data.List (intercalate)
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

-- | The human rendering: a pure function of the report, an explicitly supplied
-- current time, and the zone reset instants are stated in.
--
-- The zone is an input for the same reason the clock is.  A reset time is
-- printed as a local wall clock, and a renderer that read either from the
-- process could not be pinned by a fixture; the sidebar supplies its
-- @appTimeZone@ here for the same reason.
renderUsageReport :: TimeZone -> UTCTime -> UsageReport -> [Text]
renderUsageReport zone now report =
  intercalate [""] (map (renderEntry zone now) report.usageReportEntries)

renderEntry :: TimeZone -> UTCTime -> (UsageProvider, UsageOutcome) -> [Text]
renderEntry zone now (provider, outcome) = usageProviderName provider : body
  where
    body = case outcome of
      UsageFailed message -> ["  unavailable: " <> message]
      UsageAvailable snapshot ->
        windowLines snapshot <> ["  snapshot " <> formatUsageDuration (diffUTCTime now snapshot.usageFetchedAt) <> " old"]
    windowLines snapshot
      | null snapshot.usageWindows = ["  no usage windows reported"]
      | otherwise = map (renderWindowLine zone now (labelWidth snapshot)) snapshot.usageWindows

-- | Labels are padded to the widest one this provider reported, so the columns
-- line up without depending on anything outside the snapshot being rendered.
labelWidth :: UsageSnapshot -> Int
labelWidth snapshot = maximum (1 : map (Text.length . (.usageWindowLabel)) snapshot.usageWindows)

renderWindowLine :: TimeZone -> UTCTime -> Int -> UsageWindow -> Text
renderWindowLine zone now width window =
  "  "
    <> Text.justifyLeft width ' ' window.usageWindowLabel
    <> "  "
    <> Text.justifyRight 3 ' ' (Text.pack (show window.usagePercentLeft))
    <> "% left · resets in "
    <> formatUsageDuration (diffUTCTime window.usageResetsAt now)
    <> " ("
    <> usageResetLocalText zone window.usageResetsAt
    <> ")"

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
formatUsageDuration :: NominalDiffTime -> Text
formatUsageDuration difference
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
