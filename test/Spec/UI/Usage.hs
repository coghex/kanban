-- | Both of a usage window's rows against the fixed sidebar interior they
-- are budgeted against.
--
-- The reset row: that its countdown and snapshot age fit that interior for
-- every instant a provider can report, that an elapsed reset is named rather
-- than counted down to, that a snapshot restored from the cache says how old
-- it is, and that the sidebar and @kanban --usage@ state the same thing for
-- one snapshot at one instant.
--
-- The percentage row above it: that its label field, bar, and percentage
-- field spend that interior exactly, for every percentage a provider decodes
-- and every label an external usage command can supply, under each of the
-- three border styles.
--
-- The golden frames cover what the sidebar looks like with the fixture
-- snapshots. What they cannot cover is the range: a fixture is one reset
-- instant, one label, and one percentage, and the rows here are the ones that
-- stop being true off it.
--
-- Beneath the drawing sits what a refresh does to the stored snapshot.
-- 'commitRefreshedUsage' is the dashboard's whole contact with that file and
-- the only part of the refresh arm outside brick's @EventM@, which no test
-- here can drive, so it is asserted directly.
module Spec.UI.Usage (spec) where

import Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Char8 as ByteString
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text
import Data.Time (NominalDiffTime, TimeZone, UTCTime (..), addUTCTime, diffUTCTime, fromGregorian, hoursToTimeZone, secondsToDiffTime, utc)
import Kanban.CLI (BorderPolicy (..), Options (..))
import Kanban.Card (displayWidth)
import Kanban.Config (ResolvedConfig (..), UsageConfig (..), defaultUsageConfig)
import Kanban.Domain
  ( Freshness (..),
    UsageProvider (..),
    UsageSnapshot (..),
    UsageWindow (..),
  )
import Kanban.Cache
  ( UsageCacheLoad (..),
    UsageCommit (..),
    commitUsageSnapshots,
    loadUsageCache,
    usageCacheLockPath,
    usageCachePath
  )
import Kanban.UI (drawApplication)
import Kanban.UI.Reconcile (commitRefreshedUsage)
import Kanban.UI.Board
  ( usageAgeText,
    usageBarWidth,
    usageLabelField,
    usagePercentField,
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
    usageSolveRoundsLeft,
    usageSolveRoundsSuffix,
  )
import Kanban.UsageCommand (decodeUsageCommandDocument)
import Spec.Support.App (testAppState)
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Spec.Support.Fixtures (fixtureBoard)
import Spec.Support.Golden (expectGolden, goldenPath)
import Spec.Support.Render (frameRowText, renderFrameCells)
import System.Directory (createDirectory, doesFileExist, removeFile)
import Test.Hspec

spec :: Spec
spec = do
  sidebarSpec
  percentRowSpec
  refreshCommitSpec

-- | What a provider refresh commits, and what it reports back to the notice
-- line.
--
-- The dashboard holds a usage map for the process's whole lifetime, seeded
-- once at launch, and writing that map back is how a refresh in another
-- process was reverted (issue #477). What is asserted here is that this seam
-- hands over the refreshed provider alone and merges against what is actually
-- stored -- it never receives the dashboard's map at all, which is what makes
-- the old whole-map write unreachable from the arm above it.
refreshCommitSpec :: Spec
refreshCommitSpec = describe "what a dashboard usage refresh commits" $ do
  it "keeps a provider entry the dashboard never refreshed" $
    withUsageCache $ do
      commitUsageSnapshots (Map.fromList [(Claude, storedClaude)]) `shouldReturn` UsageCommit (Right ()) Nothing
      commitRefreshedUsage True Codex refreshedCodex `shouldReturn` []
      storedPercentages `shouldReturn` Map.fromList [(Codex, [71]), (Claude, [22])]

  it "writes neither the snapshot nor its lock when caching is off" $
    withUsageCache $ do
      commitRefreshedUsage False Codex refreshedCodex `shouldReturn` []
      snapshotPath <- usageCachePath
      lockPath <- usageCacheLockPath
      doesFileExist snapshotPath `shouldReturn` False
      doesFileExist lockPath `shouldReturn` False
      -- The paired positive control, so the absence above is a decision the
      -- flag made rather than something the fixture could not do anyway.
      commitRefreshedUsage True Codex refreshedCodex `shouldReturn` []
      doesFileExist snapshotPath `shouldReturn` True
      doesFileExist lockPath `shouldReturn` True

  -- The notice line carries both halves of the commit. A failed write was
  -- always reported there; the warning about a stored file the merge could
  -- not read is new, and reaches the same place for the same reason -- it is
  -- non-fatal and the user is the only one who can act on it.
  it "reports a failed commit and a corrupt stored snapshot on the notice line" $
    withUsageCache $ do
      snapshotPath <- usageCachePath
      commitUsageSnapshots (Map.fromList [(Claude, storedClaude)]) `shouldReturn` UsageCommit (Right ()) Nothing
      ByteString.writeFile snapshotPath "not JSON"
      warned <- commitRefreshedUsage True Codex refreshedCodex
      warned `shouldSatisfy` all (Data.Text.isPrefixOf "usage cache ignored: ")
      warned `shouldSatisfy` ((== 1) . length)
      lockPath <- usageCacheLockPath
      removeFile lockPath
      createDirectory lockPath
      failed <- commitRefreshedUsage True Codex refreshedCodex
      failed `shouldSatisfy` all (Data.Text.isPrefixOf "cache write failed: ")
      failed `shouldSatisfy` ((== 1) . length)

withUsageCache :: IO result -> IO result
withUsageCache action =
  withTemporaryCacheRoot $ \cacheRoot -> withEnvironmentValue "XDG_CACHE_HOME" cacheRoot action

storedPercentages :: IO (Map.Map UsageProvider [Int])
storedPercentages = do
  load <- loadUsageCache
  case load of
    UsageCacheLoaded snapshots -> pure (fmap (map (.usagePercentLeft) . (.usageWindows)) snapshots)
    other -> fail ("expected a loaded usage cache, got " <> show other)

-- | Two entries an hour apart, so the refreshed one is accepted on its own
-- stamp rather than by arriving second.
storedClaude, refreshedCodex :: UsageSnapshot
storedClaude = UsageSnapshot [UsageWindow "week" 22 goldenNow] goldenNow
refreshedCodex = UsageSnapshot [UsageWindow "week" 71 goldenNow] (addUTCTime 3600 goldenNow)

sidebarSpec :: Spec
sidebarSpec = describe "usage sidebar" $ do
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
  --
  -- The estimate is swept with it rather than in a case of its own. The
  -- suffix is the one part of this row with no bound of its own, so the
  -- combination of a long countdown and a wide count is exactly what a golden
  -- frame -- one instant, one count -- cannot rule out. Every configured
  -- estimate here is a legal one, and the counts they produce against a
  -- hundred-percent window span one, two, and three digits.
  it "fits the sidebar interior for every reset instant a provider can report, at every estimate" $ do
    let overlong =
          [ (offset, zone, estimate, row)
          | offset <- resetOffsets,
            zone <- zones,
            estimate <- estimates,
            let row = usageResetRowText estimate zone goldenNow (windowAt (addUTCTime offset goldenNow)),
            displayWidth row > usageSidebarInterior
          ]
    overlong `shouldBe` []

  -- The check above is only worth something if those estimates really do
  -- reach three digits: a sweep whose counts were all one digit would pass
  -- while saying nothing about the widest suffix.
  it "sweeps a one-, two-, and three-digit count over that interior" $
    map (`usageSolveRoundsLeft` 100) estimates `shouldBe` [Nothing, Just 1, Just 10, Just 100]

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
      let row = usageResetRowText Nothing utc goldenNow (windowAt (addUTCTime (negate offset) goldenNow))
      row `shouldSatisfy` ("due now · " `Data.Text.isPrefixOf`)

  it "never renders a negative duration in either the countdown or the age" $ do
    let signed =
          [ row
          | offset <- map negate (resetOffsets <> ageOffsets) <> resetOffsets,
            row <-
              [ usageResetRowText Nothing utc goldenNow (windowAt (addUTCTime offset goldenNow)),
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
          command = renderUsageReport Map.empty zone goldenNow (UsageReport [(Codex, UsageAvailable snapshot)])
          age = usageSnapshotAgeText (diffUTCTime goldenNow snapshot.usageFetchedAt)
          countdowns = map (usageResetCountdownText . flip diffUTCTime goldenNow . (.usageResetsAt)) snapshot.usageWindows
      for_ (("snapshot " <> age) : map ("resets " <>) countdowns) $ \fragment ->
        (name, fragment, filter (fragment `Data.Text.isInfixOf`) command) `shouldNotBe` (name, fragment, [])
      for_ (age : countdowns) $ \fragment ->
        (name, fragment, filter (fragment `Data.Text.isInfixOf`) sidebar) `shouldNotBe` (name, fragment, [])

  -- Requirement 5, and the amendment fixing the fit against the existing
  -- interior constant rather than a literal 24. The base row is held constant
  -- at 18 cells so that what varies between these cases is only the width of
  -- the suffix itself.
  it "appends the whole compact suffix, or none of it, according to what the finished row measures" $ do
    let row estimate percentLeft =
          usageResetRowText estimate utc goldenNow (UsageWindow "weekly" percentLeft (addUTCTime 1800 goldenNow))
        base = "in 30m · Thu 15:30"
    displayWidth base `shouldBe` 18
    row Nothing 63 `shouldBe` base
    row (Just 8) 63 `shouldBe` base <> " · ≈7"
    row (Just 5) 63 `shouldBe` base <> " · ≈12"
    -- Three digits need seven cells of suffix against an 18-cell base, which
    -- is one cell more than the interior has. The countdown and the reset
    -- instant are not shortened to make room; the estimate simply goes.
    displayWidth (base <> " · ≈100") `shouldBe` usageSidebarInterior + 1
    row (Just 1) 100 `shouldBe` base
    -- A window that does not buy a whole round says so.
    row (Just 80) 63 `shouldBe` base <> " · ≈0"

  -- The suffix must never be the reason a row that fitted stops fitting, and
  -- it must never be appended in part.
  it "never overflows an otherwise-fitting row, and never appends a fragment of the suffix" $ do
    let rows =
          [ (offset, estimate, percentLeft, usageResetRowText estimate utc goldenNow (windowAt' percentLeft (addUTCTime offset goldenNow)))
          | offset <- resetOffsets,
            estimate <- estimates,
            percentLeft <- [0, 7, 63, 100]
          ]
        base offset = usageResetRowText Nothing utc goldenNow (windowAt' 100 (addUTCTime offset goldenNow))
        truncated (offset, estimate, percentLeft, row) =
          row /= base offset
            && Just row /= ((base offset <>) . usageSolveRoundsSuffix <$> usageSolveRoundsLeft estimate percentLeft)
    filter truncated rows `shouldBe` []
    filter (\(_, _, _, row) -> displayWidth row > usageSidebarInterior) rows `shouldBe` []

  -- Requirement 7's consequence at the surface: the sidebar reads its count
  -- off the same derivation the printed line does, so one configured value
  -- and one remaining percentage cannot produce two answers.
  it "states the same count as kanban --usage for the same configured estimate" $ do
    let window = UsageWindow "weekly" 63 (addUTCTime 1800 goldenNow)
        snapshot = UsageSnapshot [window] goldenNow
        sidebar = usageResetRowText (Just 8) utc goldenNow window
        command = renderUsageReport (Map.singleton Codex 8) utc goldenNow (UsageReport [(Codex, UsageAvailable snapshot)])
    usageSolveRoundsLeft (Just 8) 63 `shouldBe` Just 7
    sidebar `shouldSatisfy` ("≈7" `Data.Text.isSuffixOf`)
    command `shouldSatisfy` any ("≈7 solve rounds left this window" `Data.Text.isSuffixOf`)

  -- The frames the acceptance names, drawn through 'drawApplication' and read
  -- back as the sidebar's own interior cells, so what is pinned is what the
  -- application draws rather than a reconstruction of it.
  it "draws the estimate cases the sidebar has to get right" $ do
    blocks <- traverse renderEstimateCase estimateCases
    expectGolden (goldenPath "usage-estimate-sidebar.txt") (concat blocks)

-- | Every estimate the sweep runs the reset row under: unconfigured, and the
-- three legal values whose counts against a hundred-percent window are one,
-- two, and three digits wide.
estimates :: [Maybe Int]
estimates = [Nothing, Just 100, Just 10, Just 1]

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

-- | The same window with the remaining percentage varied too, which is the
-- other input the count is derived from.
windowAt' :: Int -> UTCTime -> UsageWindow
windowAt' percentLeft resetsAt = UsageWindow "weekly" percentLeft resetsAt

-- | Each case the acceptance names, drawn as the whole application and read
-- back as the sidebar block it produced.
--
-- Every reset here is half an hour out, which makes the base row 18 cells in
-- all of them. That is deliberate: the fixtures then differ only in the
-- configured estimate and the remaining percentage, so a frame that changed
-- changed because of the estimate rather than because of a countdown.
-- Eighteen cells is also the width at which the omission case is genuine —
-- the shortest reachable base row is 17, and 17 plus a three-digit suffix is
-- exactly the interior.
--
-- A three-digit count is only reachable at a hundred percent remaining, since
-- the live decoder bounds @pct_left@ at 100 and the smallest legal estimate is
-- 1. That case's percentage row is therefore the one drawn at three digits,
-- and it fits the interior like every other: the row is composed of fixed
-- fields, so the hundred-percent case spends its three-cell decimal field
-- rather than growing a twenty-fifth cell and losing the @%@ off the end.
data EstimateCase = EstimateCase
  { estimateCaseName :: Text,
    estimateCaseEstimate :: Maybe Int,
    estimateCaseWindows :: [UsageWindow]
  }

estimateCases :: [EstimateCase]
estimateCases =
  [ EstimateCase "fitting one-digit count" (Just 8) [window 63],
    EstimateCase "fitting two-digit count, filling the interior exactly" (Just 5) [window 63],
    EstimateCase "three-digit count, omitted whole because the suffix would not fit" (Just 1) [window 100],
    EstimateCase "zero rounds, rendered rather than hidden" (Just 80) [window 63],
    EstimateCase "no configured estimate" Nothing [window 63],
    EstimateCase "configured provider reporting no windows" (Just 8) []
  ]
  where
    window percentLeft = UsageWindow "5 hour" percentLeft (addUTCTime 1800 goldenNow)

renderEstimateCase :: EstimateCase -> IO [Text]
renderEstimateCase estimateCase = do
  state <- usageState snapshots (Map.singleton Codex (Fresh goldenNow)) goldenNow
  let configured =
        state
          { appConfig =
              state.appConfig
                { resolvedUsage =
                    defaultUsageConfig {usageCodexEstimatedPercentPerSolveRound = estimateCase.estimateCaseEstimate}
                }
          }
  pure (("== " <> estimateCase.estimateCaseName <> " ==") : providerBlock Codex (sidebarInterior (sidebarFrame configured)))
  where
    snapshots = Map.singleton Codex (UsageSnapshot estimateCase.estimateCaseWindows goldenNow)

-- | The percentage row: that it spends the interior it is budgeted and no
-- more, whatever percentage a provider decodes and whatever label an external
-- usage command supplies.
--
-- Every assertion here reads the row back out of the whole drawn application,
-- because the fault this covers was invisible anywhere else. The row was
-- concatenated without being measured, Brick clipped the twenty-fifth cell --
-- the @%@ -- on the way to the terminal, and the golden frame then recorded
-- the clipped row as the expected one. So the rows are read in terminal cells
-- and past the budget rather than through 'sidebarInterior', whose
-- @Text.take usageSidebarInterior@ discards exactly the cell an overflow
-- lands in and miscounts any row holding a wide character.
percentRowSpec :: Spec
percentRowSpec = describe "usage sidebar percentage row" $ do
  -- The allocation every assertion below rests on: three fixed fields and one
  -- separator, spending 'usageSidebarInterior' exactly. Nothing on this row
  -- grows with its content, so nothing on it can push the field after it out.
  it "spends the interior on fixed fields, exactly" $
    (usageLabelField + 1 + usageBarWidth + usagePercentField) `shouldBe` usageSidebarInterior

  -- Requirements 1 and 2 across the whole range a provider can decode, under
  -- every way the sidebar is framed. 'Kanban.UsageCommand.parseUsageWindow'
  -- is what bounds @pct_left@ to 0-100, and 100 is the case whose row used to
  -- measure 25 cells and lose its @%@; a cached percentage outside that range
  -- belongs to another issue. §6's width is the same in all three styles, but
  -- 'Kanban.UI.Theme.usesOpenBorders' and @--ascii@ reach
  -- 'Kanban.UI.Board.drawUsage' by distinct compositions and ASCII swaps the
  -- bar's glyphs, so a row that fits one is not thereby known to fit the rest.
  it "draws every percentage a provider decodes complete and inside the interior" $ do
    faults <-
      traverse
        (uncurry rowFaults)
        [ (style, chunk)
        | style <- sidebarStyles,
          chunk <- sweepChunks [(defaultLabel, percentage) | percentage <- [0 .. 100]]
        ]
    concat faults `shouldBe` []

  -- Requirement 2's second half, pinned as text: the decimal is right-aligned
  -- in a field of its own, so one, two, and three digits end in the same
  -- column and the bars above and below each other stay comparable.
  it "right-aligns the decimal so one-, two-, and three-digit rows share a column" $ do
    rows <- drawnPercentRows closedBorders [(defaultLabel, percentage) | percentage <- boundaryPercentages]
    rows
      `shouldBe` [ "5 hour  [\9617\9617\9617\9617\9617\9617\9617\9617\9617\9617]  0%",
                   "5 hour  [\9608\9617\9617\9617\9617\9617\9617\9617\9617\9617]  5%",
                   "5 hour  [\9608\9608\9608\9608\9608\9608\9617\9617\9617\9617] 63%",
                   "5 hour  [\9608\9608\9608\9608\9608\9608\9608\9608\9608\9617] 94%",
                   "5 hour  [\9608\9608\9608\9608\9608\9608\9608\9608\9608\9608]100%"
                 ]

  it "draws that same range with ASCII glyphs under --ascii" $ do
    rows <- drawnPercentRows asciiBorders [(defaultLabel, percentage) | percentage <- boundaryPercentages]
    rows
      `shouldBe` [ "5 hour  [..........]  0%",
                   "5 hour  [#.........]  5%",
                   "5 hour  [######....] 63%",
                   "5 hour  [#########.] 94%",
                   "5 hour  [##########]100%"
                 ]

  -- Requirements 3 and 4, over the shapes an external command can supply:
  -- narrower than the field, exactly at it, wider than it, and one whose
  -- 'Data.Text.length' fits while its display width does not -- which is the
  -- shape that used to slip past a character-counted pad and take the bar and
  -- the percentage out of the interior with it.
  it "bounds and pads every label to the field, measured in cells" $ do
    faults <- traverse (\style -> rowFaults style [(label, 63) | label <- labelSweep]) sidebarStyles
    concat faults `shouldBe` []

  it "marks a shortened label and leaves a fitting one alone" $ do
    rows <- drawnPercentRows closedBorders [(label, 63) | label <- labelSweep]
    map labelFieldOf rows
      `shouldBe` [ "wk     ",
                   "5 hour ",
                   "weekly!",
                   "fortni\8230",
                   "\26085\26412\35486\8230",
                   "5 hour\8230"
                 ]

  -- The amendment's newline case. 'Kanban.Text.sanitizeText' keeps @\n@
  -- deliberately and Brick draws one as a row break, so a multi-line label
  -- would otherwise leave the bar and the percentage on a row of their own
  -- beneath a provider block whose height is fixed. 'drawnPercentRows' fails
  -- on the row count before it ever reaches the fields.
  it "keeps a multi-line label on one row, marked as shortened" $ do
    Data.Text.isInfixOf "\n" multiLineLabel `shouldBe` True
    rows <- drawnPercentRows closedBorders [(multiLineLabel, 63)]
    rows `shouldBe` ["5 hour\8230 [\9608\9608\9608\9608\9608\9608\9617\9617\9617\9617] 63%"]

  -- Requirement 2 read across the two surfaces: one window's remaining
  -- percentage is one figure, whichever surface states it.
  it "states the same percentage as kanban --usage for the same window" $
    for_ boundaryPercentages $ \percentage -> do
      rows <- drawnPercentRows closedBorders [(defaultLabel, percentage)]
      snapshot <- decodedSnapshot [(defaultLabel, percentage)]
      let stated = Data.Text.pack (show percentage) <> "%"
          command = renderUsageReport Map.empty utc goldenNow (UsageReport [(Codex, UsageAvailable snapshot)])
      map (Data.Text.stripStart . percentFieldOf) rows `shouldBe` [stated]
      filter (stated `Data.Text.isInfixOf`) command `shouldNotBe` []

-- | The label the percentage sweeps hold constant: a fixture label six cells
-- wide, so what varies between those rows is the percentage alone.
defaultLabel :: Text
defaultLabel = "5 hour"

-- | The percentages the field's boundaries sit on: the empty bar, the
-- narrowest single digit that still fills a cell, the fixture's own figure,
-- the widest two-digit row, and the three-digit row that used to overflow.
boundaryPercentages :: [Int]
boundaryPercentages = [0, 5, 63, 94, 100]

-- | Every shape of label the field has to answer for, each one text an
-- external usage command can supply: narrower than the field, exactly at it,
-- wider than it, wider in cells while narrower in characters, and one whose
-- remainder would have become a row of its own.
labelSweep :: [Text]
labelSweep = ["wk", defaultLabel, "weekly!", "fortnightly", "\26085\26412\35486\12391\12377", multiLineLabel]

-- | A label whose line break 'Kanban.Text.sanitizeText' keeps.
multiLineLabel :: Text
multiLineLabel = "5 hour\nand a bit"

-- | One way the sidebar is framed, and how many cells stand before its
-- interior begins. §6 fixes the sidebar at 'usageSidebarWidth' in all three,
-- but the closed box spends two of them on a border the open rules do not
-- draw at all.
data SidebarStyle = SidebarStyle
  { sidebarStyleName :: String,
    sidebarStyleOptions :: Options -> Options,
    sidebarStyleIndent :: Int
  }

sidebarStyles :: [SidebarStyle]
sidebarStyles = [closedBorders, openBorders, asciiBorders]

closedBorders, openBorders, asciiBorders :: SidebarStyle
closedBorders = SidebarStyle "closed borders" id 3
openBorders = SidebarStyle "open borders" (\options -> options {optionBorder = BorderOpen}) 1
asciiBorders = SidebarStyle "ascii" (\options -> options {optionAscii = True}) 3

-- | The percentage rows one style draws for @windows@, read out of the whole
-- application.
--
-- The row count is asserted against the windows asked for, so a sweep that
-- outgrew the sidebar's height fails here rather than quietly covering less
-- than it claims to.
drawnPercentRows :: SidebarStyle -> [(Text, Int)] -> IO [Text]
drawnPercentRows style windows = do
  snapshot <- decodedSnapshot windows
  base <- usageState (Map.singleton Codex snapshot) (Map.singleton Codex (Fresh goldenNow)) goldenNow
  let state = base {appOptions = style.sidebarStyleOptions base.appOptions}
      rows = drop 1 (providerBlock Codex (sidebarDrawn style state))
  length rows `shouldBe` 2 * length windows
  pure [row | (index, row) <- zip [0 :: Int ..] rows, even index]

-- | One thing a drawn row got wrong, named rather than counted, so a failure
-- says which field moved, in which frame, and what it moved to.
data RowFault = RowFault
  { faultStyle :: String,
    faultLabel :: Text,
    faultPercentage :: Int,
    faultField :: Text,
    faultDrawn :: Text,
    faultExpected :: Text
  }
  deriving stock (Eq, Show)

-- | Everything the rows one style drew for @windows@ got wrong.
--
-- Each field is read at the cell offset the allocation puts it at rather than
-- searched for, so this is also where "the bar starts in the same column in
-- every row" is asserted: a bar that moved is a bar whose brackets are no
-- longer at its offset's edges.
--
-- The row's own width is an equality rather than a bound. Every field on it
-- is fixed, so a row that fits by measuring less than the interior is as
-- wrong as one that overflows -- it means a field went missing.
rowFaults :: SidebarStyle -> [(Text, Int)] -> IO [RowFault]
rowFaults style windows = do
  rows <- drawnPercentRows style windows
  pure (concat (zipWith faults windows rows))
  where
    faults (label, percentage) row =
      [ RowFault style.sidebarStyleName label percentage field drawn expected
      | (field, drawn, expected) <-
          [ ("row width", cells (displayWidth row), cells usageSidebarInterior),
            ("content past the interior", dropCells usageSidebarInterior row, ""),
            ("label field width", cells (displayWidth (labelFieldOf row)), cells usageLabelField),
            ("separator", takeCells 1 (dropCells usageLabelField row), " "),
            ("bar width", cells (displayWidth (barOf row)), cells usageBarWidth),
            ("bar edges", Data.Text.take 1 (barOf row) <> Data.Text.takeEnd 1 (barOf row), "[]"),
            ("percentage", Data.Text.stripStart (percentFieldOf row), Data.Text.pack (show percentage) <> "%"),
            ("percentage field width", cells (displayWidth (percentFieldOf row)), cells usagePercentField)
          ],
        drawn /= expected
      ]
    cells = Data.Text.pack . show

labelFieldOf :: Text -> Text
labelFieldOf = takeCells usageLabelField

barOf :: Text -> Text
barOf = takeCells usageBarWidth . dropCells (usageLabelField + 1)

percentFieldOf :: Text -> Text
percentFieldOf = takeCells usagePercentField . dropCells (usageLabelField + 1 + usageBarWidth)

-- | Chunks small enough that a sweep's windows all fit the sidebar's height,
-- so 'drawnPercentRows' never has to fail its row count for a reason the
-- sweep did not mean to test.
sweepChunks :: [(Text, Int)] -> [[(Text, Int)]]
sweepChunks [] = []
sweepChunks windows = take 6 windows : sweepChunks (drop 6 windows)

-- | A snapshot of the windows an external usage command reported, produced by
-- decoding that command's own document rather than assembled by hand: the
-- label bound covered here is a bound on what
-- 'Kanban.UsageCommand.parseUsageWindow' admits, so a fixture that skipped
-- the decoder would be asserting over labels no provider can supply.
decodedSnapshot :: [(Text, Int)] -> IO UsageSnapshot
decodedSnapshot windows = either (fail . show) pure (decodeUsageCommandDocument goldenNow (Aeson.encode document))
  where
    document =
      Aeson.object
        [ "windows"
            .= [ Aeson.object
                   [ "label" .= label,
                     "pct_left" .= percentage,
                     "resets_at" .= addUTCTime 1800 goldenNow
                   ]
               | (label, percentage) <- windows
               ]
        ]

-- | Every cell the sidebar drew of one frame, from its first interior cell to
-- the last cell inside its right edge.
--
-- Deliberately not 'sidebarInterior': that projection takes
-- 'usageSidebarInterior' /characters/ off the front of a row and throws the
-- rest away, which is both the wrong measure for a row holding a wide
-- character and a guarantee that an overflowing cell is gone before any
-- assertion sees it. This one is measured in cells and reaches past the
-- budget into the sidebar's own padding, so content that escaped the interior
-- is read back rather than trimmed into agreement.
sidebarDrawn :: SidebarStyle -> AppState -> [Text]
sidebarDrawn style state =
  [ Data.Text.stripEnd (takeCells (usageSidebarWidth - style.sidebarStyleIndent) (dropCells style.sidebarStyleIndent row))
  | row <- map frameRowText (renderFrameCells (themeFor state.appOptions) (164, 48) (drawApplication state))
  ]

-- | 'Data.Text.take' and 'Data.Text.drop' measured in terminal cells, which
-- is the measure a rendered row has to be cut by: seven characters of
-- Japanese occupy fourteen columns, so cutting by characters would read
-- fourteen columns of the board beside the sidebar as part of the sidebar.
takeCells :: Int -> Text -> Text
takeCells limit = Data.Text.pack . go limit . Data.Text.unpack
  where
    go _ [] = []
    go remaining (character : rest)
      | width > remaining = []
      | otherwise = character : go (remaining - width) rest
      where
        width = displayWidth (Data.Text.singleton character)

dropCells :: Int -> Text -> Text
dropCells limit = Data.Text.pack . go limit . Data.Text.unpack
  where
    go remaining rest
      | remaining <= 0 = rest
    go _ [] = []
    go remaining (character : rest) = go (remaining - displayWidth (Data.Text.singleton character)) rest

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
