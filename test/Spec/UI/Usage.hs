-- | The usage sidebar's countdown and snapshot age: that both fit the fixed
-- interior for every instant a provider can report, that an elapsed reset is
-- named rather than counted down to, that a snapshot restored from the cache
-- says how old it is, and that the sidebar and @kanban --usage@ state the
-- same thing for one snapshot at one instant.
--
-- The golden frames cover what the sidebar looks like with the fixture
-- snapshots. What they cannot cover is the range: a fixture is one reset
-- instant, and the rows here are the ones that stop being true off it.
module Spec.UI.Usage (spec) where

import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text
import Data.Time (NominalDiffTime, TimeZone, UTCTime (..), addUTCTime, diffUTCTime, fromGregorian, hoursToTimeZone, secondsToDiffTime, utc)
import Kanban.Card (displayWidth)
import Kanban.Domain
  ( Freshness (..),
    UsageProvider (..),
    UsageSnapshot (..),
    UsageWindow (..),
  )
import Kanban.UI (drawApplication)
import Kanban.UI.Board
  ( usageAgeText,
    usageResetRowText,
    usageSidebarInterior,
    usageSidebarWidth,
  )
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types (AppState (..))
import Kanban.Usage.Render
  ( UsageOutcome (..),
    UsageReport (..),
    renderUsageReport,
    usageResetCountdownText,
    usageSnapshotAgeText,
  )
import Spec.Support.App (testAppState)
import Spec.Support.Fixtures (fixtureBoard)
import Spec.Support.Render (frameRowText, renderFrameCells)
import Test.Hspec

spec :: Spec
spec = describe "usage sidebar" $ do
  -- §6 fixes the sidebar at 28 cells and derives the 164-cell four-column
  -- threshold from it, so the countdown has to be paid for out of the
  -- existing rows rather than out of the width.
  it "keeps the sidebar 28 cells wide" $ do
    rows <- sidebarFrame <$> loadedState goldenNow
    let heading = headRow " USAGE " rows
    boxWidth heading `shouldBe` Just usageSidebarWidth
    usageSidebarWidth `shouldBe` 28

  -- Requirement 1: the countdown takes the reset row's indent rather than a
  -- row of its own, so a provider's block is exactly as tall as it was.
  it "draws one reset row per window, carrying the countdown and the wall clock together" $ do
    interior <- providerBlock Codex . sidebarInterior . sidebarFrame <$> loadedState goldenNow
    interior
      `shouldBe` [ "Codex          3h 0m old",
                   "5 hour  [██████░░░░] 63%",
                   "in 1h 5m · Thu 16:05",
                   "week    [████░░░░░░] 41%",
                   "in 4d 18h · Tue 09:00"
                 ]

  -- Requirement 2. A window's reset instant is whatever the provider
  -- reported: 'Kanban.UsageCommand.decodeUsageCommandDocument' bounds no
  -- decoded timestamp, so the row has to fit for a reset a century out as
  -- much as for one this afternoon.
  it "fits the sidebar interior for every reset instant a provider can report" $ do
    let overlong =
          [ (offset, zone, row)
          | offset <- resetOffsets,
            zone <- zones,
            let row = usageResetRowText zone goldenNow (windowAt (addUTCTime offset goldenNow)),
            displayWidth row > usageSidebarInterior
          ]
    overlong `shouldBe` []

  it "fits the sidebar interior for every snapshot age, beside the longer provider name" $ do
    let overlong =
          [ (offset, row)
          | offset <- ageOffsets,
            let row = "Claude " <> usageAgeText goldenNow (snapshotFetchedAt (addUTCTime (negate offset) goldenNow)),
            displayWidth row > usageSidebarInterior
          ]
    overlong `shouldBe` []

  -- Requirement 3: 'formatUsageDuration' clamps at zero, so without an
  -- explicit elapsed state a reset three days behind the clock would read
  -- "in 0s" -- not negative, but a countdown to an instant that has passed.
  it "names an elapsed reset rather than counting down to it" $ do
    for_ elapsedOffsets $ \offset -> do
      let row = usageResetRowText utc goldenNow (windowAt (addUTCTime (negate offset) goldenNow))
      row `shouldSatisfy` ("due now · " `Data.Text.isPrefixOf`)

  it "never renders a negative duration in either the countdown or the age" $ do
    let signed =
          [ row
          | offset <- map negate (resetOffsets <> ageOffsets) <> resetOffsets,
            row <-
              [ usageResetRowText utc goldenNow (windowAt (addUTCTime offset goldenNow)),
                usageAgeText goldenNow (snapshotFetchedAt (addUTCTime offset goldenNow))
              ],
            "-" `Data.Text.isInfixOf` row
          ]
    signed `shouldBe` []

  -- Requirement 4. 'Kanban.UI.initialUsageState' labels a snapshot restored
  -- from the cache @Fresh@ at whatever instant it was written, so a board
  -- opened on numbers days old is the case a Freshness-gated age would hide.
  it "shows the age of a cached snapshot the startup path labelled Fresh" $ do
    let writtenAt = addUTCTime (negate (3 * 86400)) goldenNow
        snapshot = snapshotFetchedAt writtenAt
    state <- usageState (Map.singleton Codex snapshot) (Map.singleton Codex (Fresh writtenAt)) goldenNow
    providerBlock Codex (sidebarInterior (sidebarFrame state))
      `shouldSatisfy` any ("3d 0h old" `Data.Text.isSuffixOf`)

  -- Requirement 7, and the amendment that reads the unchanged row count
  -- against the same freshness state: the conditional rows stay conditional.
  it "keeps the refreshing and stale rows a snapshot's freshness still qualifies it with" $ do
    let snapshot = snapshotFetchedAt (addUTCTime (negate 1800) goldenNow)
    loading <- usageState (Map.singleton Codex snapshot) (Map.singleton Codex Loading) goldenNow
    stale <- usageState (Map.singleton Codex snapshot) (Map.singleton Codex (Stale goldenNow "codex timed out")) goldenNow
    last (providerBlock Codex (sidebarInterior (sidebarFrame loading))) `shouldBe` "refreshing…"
    providerBlock Codex (sidebarInterior (sidebarFrame stale)) `shouldSatisfy` any ("stale · codex" `Data.Text.isPrefixOf`)

  it "still states a provider's status, and no age, when it has no snapshot" $ do
    state <- usageState Map.empty (Map.singleton Codex (Unavailable "codex is not installed")) goldenNow
    providerBlock Codex (sidebarInterior (sidebarFrame state))
      `shouldBe` ["Codex", "codex is not installed"]

  -- Requirement 5. Both surfaces read the countdown and the age off
  -- "Kanban.Usage.Render", so one snapshot at one instant in one zone cannot
  -- be described two ways.
  it "states the same countdown and age as kanban --usage for one snapshot at one instant" $
    for_ agreementCases $ \(name, zone, snapshot) -> do
      state <- usageState (Map.singleton Codex snapshot) (Map.singleton Codex (Fresh snapshot.usageFetchedAt)) goldenNow
      let sidebar = providerBlock Codex (sidebarInterior (sidebarFrame state {appTimeZone = zone}))
          command = renderUsageReport zone goldenNow (UsageReport [(Codex, UsageAvailable snapshot)])
          age = usageSnapshotAgeText (diffUTCTime goldenNow snapshot.usageFetchedAt)
          countdowns = map (usageResetCountdownText . flip diffUTCTime goldenNow . (.usageResetsAt)) snapshot.usageWindows
      for_ (("snapshot " <> age) : map ("resets " <>) countdowns) $ \fragment ->
        (name, fragment, filter (fragment `Data.Text.isInfixOf`) command) `shouldNotBe` (name, fragment, [])
      for_ (age : countdowns) $ \fragment ->
        (name, fragment, filter (fragment `Data.Text.isInfixOf`) sidebar) `shouldNotBe` (name, fragment, [])

-- | One snapshot per way the two surfaces could drift apart: an ordinary
-- future reset, one already elapsed, and one far enough out to hit the
-- duration bound.
agreementCases :: [(String, TimeZone, UsageSnapshot)]
agreementCases =
  [ ("ordinary", hoursToTimeZone 2, snapshot [(65 * 60), (4 * 86400)] 1800),
    ("elapsed", utc, snapshot [negate (3 * 86400)] 3600),
    ("bounded", hoursToTimeZone (-7), snapshot [500 * 86400] (400 * 86400))
  ]
  where
    snapshot offsets age =
      UsageSnapshot
        { usageWindows = [windowAt (addUTCTime offset goldenNow) | offset <- offsets],
          usageFetchedAt = addUTCTime (negate age) goldenNow
        }

-- | How far ahead of the frame a reset can be. The bound past 99 days and the
-- boundaries either side of it matter more than the values in between.
resetOffsets :: [NominalDiffTime]
resetOffsets =
  [ 0,
    1,
    59,
    60,
    3599,
    3600,
    86399,
    86400,
    99 * 86400 + 86399,
    100 * 86400,
    365 * 86400,
    100 * 365 * 86400
  ]

ageOffsets :: [NominalDiffTime]
ageOffsets = resetOffsets

-- | How far behind the frame an already-passed reset can be.
elapsedOffsets :: [NominalDiffTime]
elapsedOffsets = [0, 1, 3600, 3 * 86400, 500 * 86400]

-- | Reset instants are stated as a local wall clock, so the zone is swept too.
zones :: [TimeZone]
zones = [utc, hoursToTimeZone 14, hoursToTimeZone (-12)]

-- | A window whose label and percentage are the widest the reset row has to
-- coexist with; only its reset instant varies.
windowAt :: UTCTime -> UsageWindow
windowAt resetsAt = UsageWindow "weekly" 100 resetsAt

snapshotFetchedAt :: UTCTime -> UsageSnapshot
snapshotFetchedAt fetchedAt =
  UsageSnapshot {usageWindows = [windowAt (addUTCTime 3600 fetchedAt)], usageFetchedAt = fetchedAt}

-- | The state the row-by-row expectation above is written against: the
-- fixture snapshots, fetched three hours before the frame is drawn.
loadedState :: UTCTime -> IO AppState
loadedState now = usageState fixtureSnapshots (Map.map (Fresh . (.usageFetchedAt)) fixtureSnapshots) now

fixtureSnapshots :: Map.Map UsageProvider UsageSnapshot
fixtureSnapshots =
  Map.singleton
    Codex
    UsageSnapshot
      { usageWindows =
          [ UsageWindow "5 hour" 63 (UTCTime (fromGregorian 2026 7 16) (secondsToDiffTime (16 * 3600 + 5 * 60))),
            UsageWindow "week" 41 (UTCTime (fromGregorian 2026 7 21) (secondsToDiffTime (9 * 3600)))
          ],
        usageFetchedAt = UTCTime (fromGregorian 2026 7 16) (secondsToDiffTime (12 * 3600))
      }

usageState :: Map.Map UsageProvider UsageSnapshot -> Map.Map UsageProvider Freshness -> UTCTime -> IO AppState
usageState snapshots freshness now = do
  state <- testAppState (fixtureBoard [])
  pure state {appUsage = snapshots, appUsageFreshness = freshness, appNow = now, appTimeZone = utc}

-- | The instant every frame here is drawn for.
goldenNow :: UTCTime
goldenNow = UTCTime (fromGregorian 2026 7 16) (secondsToDiffTime (15 * 3600))

-- | The whole application drawn the way 'Kanban.UI.runDashboard' hands it to
-- Brick, at the four-column minimum §6 names, read back as rows of text.
sidebarFrame :: AppState -> [Text]
sidebarFrame state =
  map frameRowText (renderFrameCells (themeFor state.appOptions) (164, 48) (drawApplication state))

-- | Just the sidebar's content cells: past the shell border, the sidebar box
-- border, and the one-cell padding, for the interior those leave.
sidebarInterior :: [Text] -> [Text]
sidebarInterior = map (Data.Text.stripEnd . Data.Text.take usageSidebarInterior . Data.Text.drop 3)

-- | The rows one provider's block drew: its name and everything under it
-- until the next provider or the drainer control. There is no blank row to
-- stop at -- the spacer between the providers is an empty 'Brick.txt', which
-- draws nothing at all -- so the next heading is the boundary.
providerBlock :: UsageProvider -> [Text] -> [Text]
providerBlock provider rows = heading : takeWhile continues (drop 1 block)
  where
    name = case provider of
      Codex -> "Codex"
      Claude -> "Claude"
    block = dropWhile (not . (name `Data.Text.isPrefixOf`)) rows
    heading = case block of
      [] -> "«" <> name <> " never drew»"
      row : _ -> row
    continues row =
      not (Data.Text.null row)
        && not (Data.Text.any (`elem` ("┏┃┗" :: String)) row)
        && not (any (`Data.Text.isPrefixOf` row) ["Codex", "Claude"])

headRow :: Text -> [Text] -> Text
headRow needle rows = case filter (needle `Data.Text.isInfixOf`) rows of
  row : _ -> row
  [] -> "«no row containing " <> needle <> "»"

-- | The width of the first box drawn on a row, corner to corner.
boxWidth :: Text -> Maybe Int
boxWidth row = do
  start <- Data.Text.findIndex (== '┏') row
  end <- Data.Text.findIndex (== '┓') row
  pure (end - start + 1)
