-- | The @kanban --usage@ run-and-exit mode: the pure rendering fixtures are
-- pinned against, and the acquisition policy deciding which providers are
-- spawned and what reaches the snapshot cache.
module Spec.Agent.UsageMode (spec) where

import Control.Exception (IOException, try)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, hoursToTimeZone)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Kanban.CLI (Options (..), optionsParserInfo)
import Kanban.Cache (UsageCacheLoad (..), loadUsageCache, writeUsageCache)
import Kanban.Config
  ( RawConfig (..),
    ResolvedConfig (..),
    TimeoutsConfig (..),
    TimeoutsOverride (..),
    RepositoryOverride (..),
    UsageCommandConfig (..),
    UsageConfig (..),
    defaultRawConfig,
    defaultUsageConfig,
    emptyRepositoryOverride,
    resolveGlobalConfig,
    usageSolveRoundEstimates,
  )
import Kanban.Domain (UsageProvider (..), UsageSnapshot (..), UsageWindow (..))
import Kanban.Usage
  ( UsageAcquisition (..),
    UsageOutcome (..),
    UsageReport (..),
    acquireUsageReport,
    formatUsageDuration,
    renderUsageReport,
    usageDurationDayBound,
    usageReportDocument,
    usageReportProduced,
    usageSolveRoundsLeft,
  )
import Options.Applicative (defaultPrefs, execParserPure, getParseResult)
import Spec.Support.Env (createTemporaryDirectory, withEnvironmentValue, withTemporaryCacheRoot, writeExecutableScript)
import Spec.Support.Fixtures (testResolvedConfig)
import System.Directory (removePathForcibly, withCurrentDirectory)
import System.FilePath ((</>))
import System.IO (readFile')
import Test.Hspec

spec :: Spec
spec = do
  describe "usage rendering against an explicitly supplied clock and zone" $ do
    it "states each window's percent left, countdown, and local reset wall clock" $
      renderUsageReport noEstimates (hoursToTimeZone 2) (instant "2026-07-16T12:00:00Z") (availableReport twoWindowSnapshot)
        `shouldBe` [ "Codex",
                     "  5 hour   63% left · resets in 4h 5m (Thu 18:05)",
                     "  weekly   41% left · resets in 3d 21h (Mon 11:00)",
                     "  snapshot 30m old"
                   ]

    it "restates the same instants in a different zone without changing the countdown" $
      renderUsageReport noEstimates (hoursToTimeZone (-7)) (instant "2026-07-16T12:00:00Z") (availableReport twoWindowSnapshot)
        `shouldBe` [ "Codex",
                     "  5 hour   63% left · resets in 4h 5m (Thu 09:05)",
                     "  weekly   41% left · resets in 3d 21h (Mon 02:00)",
                     "  snapshot 30m old"
                   ]

    -- 'UsageWindow' and 'UsageSnapshot' store unrestricted instants and the
    -- clock is an input, so both directions are reachable rather than
    -- hypothetical.
    it "names a reset instant already in the past rather than counting down to it" $
      renderUsageReport noEstimates (hoursToTimeZone 0) (instant "2026-07-16T12:00:00Z") (availableReport expiredSnapshot)
        `shouldBe` [ "Codex",
                     "  5 hour   63% left · resets due now (Thu 09:00)",
                     "  snapshot 1h 0m old"
                   ]

    it "clamps a snapshot stamped ahead of the supplied clock to a zero age" $
      renderUsageReport noEstimates (hoursToTimeZone 0) (instant "2026-07-16T12:00:00Z") (availableReport aheadSnapshot)
        `shouldBe` [ "Codex",
                     "  5 hour   63% left · resets in 5h 0m (Thu 17:00)",
                     "  snapshot 0s old"
                   ]

    it "formats each duration scale down to seconds" $ do
      formatUsageDuration 0 `shouldBe` "0s"
      formatUsageDuration 45 `shouldBe` "45s"
      formatUsageDuration 90 `shouldBe` "1m"
      formatUsageDuration 3600 `shouldBe` "1h 0m"
      formatUsageDuration 100000 `shouldBe` "1d 3h"
      formatUsageDuration (-5000) `shouldBe` "0s"

    -- Nothing bounds a decoded @resets_at@, and the sidebar draws this into a
    -- fixed interior, so the count gives way to a bound rather than widening
    -- with the number of days.
    it "reports a bound instead of counting out an unbounded number of days" $ do
      formatUsageDuration (fromInteger (usageDurationDayBound * 86400 + 86399)) `shouldBe` "99d 23h"
      formatUsageDuration (fromInteger ((usageDurationDayBound + 1) * 86400)) `shouldBe` ">99d"
      formatUsageDuration (fromInteger (36500 * 86400)) `shouldBe` ">99d"

    it "prints a failing provider's own line without disturbing the other's windows" $
      renderUsageReport noEstimates (hoursToTimeZone 0) (instant "2026-07-16T12:00:00Z") partialReport
        `shouldBe` [ "Codex",
                     "  5 hour   63% left · resets in 5h 0m (Thu 17:00)",
                     "  snapshot 1h 0m old",
                     "",
                     "Claude",
                     "  unavailable: codex app-server is not installed"
                   ]

  describe "the configured solve-round estimate" $ do
    -- The count is integer division rounded down, and a remaining percentage
    -- that does not cover one whole round is zero rounds rather than an
    -- absent estimate: zero is the answer the user is asking for.
    it "divides the remaining percentage by the configured cost, rounding down" $ do
      usageSolveRoundsLeft (Just 8) 63 `shouldBe` Just 7
      usageSolveRoundsLeft (Just 8) 64 `shouldBe` Just 8
      usageSolveRoundsLeft (Just 8) 7 `shouldBe` Just 0
      usageSolveRoundsLeft (Just 1) 100 `shouldBe` Just 100
      usageSolveRoundsLeft (Just 100) 100 `shouldBe` Just 1

    it "renders nothing at all for a provider that configured no estimate" $
      usageSolveRoundsLeft Nothing 63 `shouldBe` Nothing

    -- Only the live decoder bounds pct_left to 0-100. A snapshot decoded from
    -- the cache carries whatever was stored, and 'div' rounds toward negative
    -- infinity, so an out-of-range value would otherwise read as a negative
    -- number of rounds.
    it "never counts a negative number of rounds from an out-of-range stored percentage" $ do
      usageSolveRoundsLeft (Just 8) (-1) `shouldBe` Just 0
      usageSolveRoundsLeft (Just 8) (-200) `shouldBe` Just 0

    it "prints the count against the window it describes, leaving the rest of the line unchanged" $
      renderUsageReport (Map.singleton Codex 8) (hoursToTimeZone 2) (instant "2026-07-16T12:00:00Z") (availableReport twoWindowSnapshot)
        `shouldBe` [ "Codex",
                     "  5 hour   63% left · resets in 4h 5m (Thu 18:05) · ≈7 solve rounds left this window",
                     "  weekly   41% left · resets in 3d 21h (Mon 11:00) · ≈5 solve rounds left this window",
                     "  snapshot 30m old"
                   ]

    it "prints a zero count rather than hiding a window that buys less than one round" $
      renderUsageReport (Map.singleton Codex 80) (hoursToTimeZone 0) (instant "2026-07-16T12:00:00Z") (availableReport oneWindowSnapshot)
        `shouldBe` [ "Codex",
                     "  5 hour   63% left · resets in 5h 0m (Thu 17:00) · ≈0 solve rounds left this window",
                     "  snapshot 1h 0m old"
                   ]

    -- Requirement 6: an unconfigured provider and a provider with no window
    -- data both render exactly what they rendered before the key existed.
    it "adds nothing for the provider that configured no estimate, or for one reporting no windows" $ do
      renderUsageReport (Map.singleton Claude 8) (hoursToTimeZone 0) (instant "2026-07-16T12:00:00Z") partialReport
        `shouldBe` [ "Codex",
                     "  5 hour   63% left · resets in 5h 0m (Thu 17:00)",
                     "  snapshot 1h 0m old",
                     "",
                     "Claude",
                     "  unavailable: codex app-server is not installed"
                   ]
      renderUsageReport (Map.singleton Codex 8) (hoursToTimeZone 0) (instant "2026-07-16T12:00:00Z") emptyWindowReport
        `shouldBe` [ "Codex",
                     "  no usage windows reported",
                     "  snapshot 30m old"
                   ]

    -- The estimate is a sibling of the command, so configuration that sets
    -- only one of them still reaches the renderer with the other absent.
    it "carries each provider's configured estimate through to the renderer's input, and no other" $ do
      usageSolveRoundEstimates defaultUsageConfig `shouldBe` Map.empty
      usageSolveRoundEstimates defaultUsageConfig {usageCodexEstimatedPercentPerSolveRound = Just 8}
        `shouldBe` Map.singleton Codex 8
      usageSolveRoundEstimates
        defaultUsageConfig
          { usageCodexEstimatedPercentPerSolveRound = Just 8,
            usageClaudeEstimatedPercentPerSolveRound = Just 12
          }
        `shouldBe` Map.fromList [(Codex, 8), (Claude, 12)]

    -- Requirement 8, and the amendment pinning the script contract: the
    -- document gains no field and keeps schema_version 1.
    it "leaves the --json document untouched" $
      decode (encode (usageReportDocument (availableReport oneWindowSnapshot)))
        `shouldBe` Just
          ( object
              [ "schema_version" .= (1 :: Int),
                "providers"
                  .= object
                    [ "codex"
                        .= object
                          [ "status" .= ("ok" :: Text),
                            "fetched_at" .= ("2026-07-16T11:00:00Z" :: Text),
                            "windows"
                              .= [ object
                                     [ "label" .= ("5 hour" :: Text),
                                       "pct_left" .= (63 :: Int),
                                       "resets_at" .= ("2026-07-16T17:00:00Z" :: Text)
                                     ]
                                 ]
                          ]
                    ]
              ]
          )

  describe "the exit status the mode reports" $ do
    it "succeeds when at least one provider produced windows" $
      usageReportProduced partialReport `shouldBe` True

    it "fails when every provider failed" $
      usageReportProduced (UsageReport [(Codex, UsageFailed "nope"), (Claude, UsageFailed "nope")]) `shouldBe` False

    -- The live decoder rejects an empty document, but the generic cache
    -- decoder establishes no such invariant, so a usage file written by
    -- another release can still decode to one.
    it "does not count an empty snapshot as a provider that produced windows" $
      usageReportProduced (UsageReport [(Codex, UsageAvailable (UsageSnapshot [] (instant "2026-07-16T11:30:00Z")))])
        `shouldBe` False

  describe "the --json document" $ do
    it "represents a failed provider explicitly rather than omitting it" $
      decode (encode (usageReportDocument partialReport))
        `shouldBe` Just
          ( object
              [ "schema_version" .= (1 :: Int),
                "providers"
                  .= object
                    [ "codex"
                        .= object
                          [ "status" .= ("ok" :: Text),
                            "fetched_at" .= ("2026-07-16T11:00:00Z" :: Text),
                            "windows"
                              .= [ object
                                     [ "label" .= ("5 hour" :: Text),
                                       "pct_left" .= (63 :: Int),
                                       "resets_at" .= ("2026-07-16T17:00:00Z" :: Text)
                                     ]
                                 ]
                          ],
                      "claude"
                        .= object
                          [ "status" .= ("error" :: Text),
                            "error" .= ("codex app-server is not installed" :: Text)
                          ]
                    ]
              ]
          )

    it "keys providers in lowercase so a script can address them by a stable name" $
      case decode (encode (usageReportDocument partialReport)) of
        Just (Object document) -> case KeyMap.lookup "providers" document of
          Just (Object providers) -> KeyMap.keys providers `shouldMatchList` ["codex", "claude"]
          other -> expectationFailure ("expected a providers object, got " <> show other)
        other -> expectationFailure ("expected a JSON object, got " <> show other)

  describe "the options the mode is selected by" $ do
    it "defaults to the dashboard with none of the usage switches set" $
      case parseOptions [] of
        Just options -> (options.optionUsage, options.optionFresh, options.optionJson) `shouldBe` (False, False, False)
        Nothing -> expectationFailure "expected the empty argument list to parse"

    it "accepts --usage with its --fresh and --json modifiers" $
      case parseOptions ["--usage", "--fresh", "--json"] of
        Just options -> (options.optionUsage, options.optionFresh, options.optionJson) `shouldBe` (True, True, True)
        Nothing -> expectationFailure "expected --usage --fresh --json to parse"

    it "accepts --config for a mode that resolves no repository" $
      case parseOptions ["--usage", "--config", "/somewhere/config.toml"] of
        Just options -> options.optionConfig `shouldBe` Just "/somewhere/config.toml"
        Nothing -> expectationFailure "expected --usage --config to parse"

  describe "configuration resolved without a repository" $ do
    it "keeps the global usage commands, timeouts, and cache setting" $ do
      let resolved = resolveGlobalConfig globalOnlyRawConfig
      resolved.resolvedUsage.usageCodexCommand `shouldBe` Just (UsageCommandConfig ["global-codex"])
      resolved.resolvedTimeouts `shouldBe` TimeoutsConfig 5 7 9 11 13
      resolved.resolvedCache `shouldBe` False

    -- The mode resolves no @owner/name@, so there is nothing for an override
    -- to be keyed by; a repository-scoped timeout must not leak in.
    it "applies no repository override" $
      (resolveGlobalConfig overriddenRawConfig).resolvedTimeouts `shouldBe` TimeoutsConfig 5 7 9 11 13

  describe "acquisition against real provider commands" $ do
    it "answers from a directory that is not a Git repository at all" $
      withUsageCacheRoot $ \root -> do
        codexScript <- recordingProvider root "codex" 71
        claudeScript <- recordingProvider root "claude" 22
        outsideRepository <- createTemporaryDirectory
        report <-
          withCurrentDirectory outsideRepository $
            fst <$> acquireUsageReport UsageCacheFirst False (configuredWith codexScript claudeScript)
        removePathForcibly outsideRepository
        reportWindows report
          `shouldBe` [ (Codex, Right [("codex-window", 71)]),
                       (Claude, Right [("claude-window", 22)])
                     ]


    it "runs the command configured for each provider rather than the built-in probe" $
      withUsageCacheRoot $ \root -> do
        codexScript <- recordingProvider root "codex" 71
        claudeScript <- recordingProvider root "claude" 22
        (report, warnings) <- acquireUsageReport UsageCacheFirst False (configuredWith codexScript claudeScript)
        warnings `shouldBe` []
        reportWindows report
          `shouldBe` [ (Codex, Right [("codex-window", 71)]),
                       (Claude, Right [("claude-window", 22)])
                     ]

    -- Paired with the cold-cache case below on purpose: a "did not spawn"
    -- assertion is only meaningful once the same fake, writing the same
    -- record through the same path, has been shown to record a spawn it did
    -- make.
    it "prints a cached snapshot without spawning that provider" $
      withUsageCacheRoot $ \root -> do
        codexScript <- recordingProvider root "codex" 71
        claudeScript <- recordingProvider root "claude" 22
        seedCache (Map.fromList [(Codex, cachedSnapshot), (Claude, cachedSnapshot)])
        (report, _) <- acquireUsageReport UsageCacheFirst True (configuredWith codexScript claudeScript)
        reportWindows report
          `shouldBe` [ (Codex, Right [("cached", 12)]),
                       (Claude, Right [("cached", 12)])
                     ]
        spawnsRecorded root `shouldReturn` []

    it "probes a provider live when the cache holds nothing for it" $
      withUsageCacheRoot $ \root -> do
        codexScript <- recordingProvider root "codex" 71
        claudeScript <- recordingProvider root "claude" 22
        seedCache (Map.fromList [(Codex, cachedSnapshot)])
        (report, _) <- acquireUsageReport UsageCacheFirst True (configuredWith codexScript claudeScript)
        reportWindows report
          `shouldBe` [ (Codex, Right [("cached", 12)]),
                       (Claude, Right [("claude-window", 22)])
                     ]
        spawnsRecorded root `shouldReturn` ["claude"]

    it "treats an empty cached snapshot as nothing to print and probes live instead" $
      withUsageCacheRoot $ \root -> do
        codexScript <- recordingProvider root "codex" 71
        claudeScript <- recordingProvider root "claude" 22
        seedCache (Map.fromList [(Codex, UsageSnapshot [] (instant "2026-07-16T11:30:00Z")), (Claude, cachedSnapshot)])
        (report, _) <- acquireUsageReport UsageCacheFirst True (configuredWith codexScript claudeScript)
        reportWindows report
          `shouldBe` [ (Codex, Right [("codex-window", 71)]),
                       (Claude, Right [("cached", 12)])
                     ]
        spawnsRecorded root `shouldReturn` ["codex"]

    it "probes both providers live under --fresh even with a warm cache" $
      withUsageCacheRoot $ \root -> do
        codexScript <- recordingProvider root "codex" 71
        claudeScript <- recordingProvider root "claude" 22
        seedCache (Map.fromList [(Codex, cachedSnapshot), (Claude, cachedSnapshot)])
        (report, _) <- acquireUsageReport UsageForceFresh True (configuredWith codexScript claudeScript)
        reportWindows report
          `shouldBe` [ (Codex, Right [("codex-window", 71)]),
                       (Claude, Right [("claude-window", 22)])
                     ]
        spawnsRecorded root `shouldReturn` ["codex", "claude"]

    it "reports one provider's failure without suppressing the other's windows" $
      withUsageCacheRoot $ \root -> do
        codexScript <- recordingProvider root "codex" 71
        (report, _) <- acquireUsageReport UsageCacheFirst False (configuredWith codexScript "/nonexistent/kanban-usage-mode-fixture")
        case reportWindows report of
          [(Codex, Right windows), (Claude, Left message)] -> do
            windows `shouldBe` [("codex-window", 71)]
            message `shouldSatisfy` (not . Text.null)
          other -> expectationFailure ("expected Codex windows beside a Claude failure, got " <> show other)

  describe "what the acquisition path writes back to the snapshot cache" $ do
    it "writes a live result obtained on a cold cache" $
      withUsageCacheRoot $ \root -> do
        codexScript <- recordingProvider root "codex" 71
        claudeScript <- recordingProvider root "claude" 22
        _ <- acquireUsageReport UsageCacheFirst True (configuredWith codexScript claudeScript)
        stored <- storedCache
        fmap (map (.usagePercentLeft) . (.usageWindows)) stored `shouldBe` Map.fromList [(Codex, [71]), (Claude, [22])]

    it "preserves a failed provider's last good snapshot instead of erasing it" $
      withUsageCacheRoot $ \root -> do
        codexScript <- recordingProvider root "codex" 71
        seedCache (Map.fromList [(Claude, cachedSnapshot)])
        _ <- acquireUsageReport UsageForceFresh True (configuredWith codexScript "/nonexistent/kanban-usage-mode-fixture")
        stored <- storedCache
        fmap (map (.usagePercentLeft) . (.usageWindows)) stored `shouldBe` Map.fromList [(Codex, [71]), (Claude, [12])]

    -- The forced-live report describes the probe that just ran; the retained
    -- disk copy is a separate question from what was printed.
    it "reports the failure under --fresh even though the cache keeps the older snapshot" $
      withUsageCacheRoot $ \root -> do
        codexScript <- recordingProvider root "codex" 71
        seedCache (Map.fromList [(Claude, cachedSnapshot)])
        (report, _) <- acquireUsageReport UsageForceFresh True (configuredWith codexScript "/nonexistent/kanban-usage-mode-fixture")
        case lookup Claude report.usageReportEntries of
          Just (UsageFailed _) -> pure ()
          other -> expectationFailure ("expected the live failure to be reported, got " <> show other)

    it "neither reads nor writes the snapshot cache when caching is off" $
      withUsageCacheRoot $ \root -> do
        codexScript <- recordingProvider root "codex" 71
        claudeScript <- recordingProvider root "claude" 22
        seedCache (Map.fromList [(Codex, cachedSnapshot), (Claude, cachedSnapshot)])
        (report, _) <- acquireUsageReport UsageForceFresh False (configuredWith codexScript claudeScript)
        reportWindows report
          `shouldBe` [ (Codex, Right [("codex-window", 71)]),
                       (Claude, Right [("claude-window", 22)])
                     ]
        stored <- storedCache
        fmap (map (.usagePercentLeft) . (.usageWindows)) stored `shouldBe` Map.fromList [(Codex, [12]), (Claude, [12])]

parseOptions :: [String] -> Maybe Options
parseOptions arguments = getParseResult (execParserPure defaultPrefs optionsParserInfo arguments)

-- | Global-only configuration: no repository section for an override to come
-- from, which is the state the mode resolves against.
globalOnlyRawConfig :: RawConfig
globalOnlyRawConfig =
  defaultRawConfig
    { rawCache = False,
      rawTimeouts = TimeoutsConfig 5 7 9 11 13,
      rawUsage = defaultUsageConfig {usageCodexCommand = Just (UsageCommandConfig ["global-codex"])}
    }

-- | The same configuration carrying a repository-scoped timeout override,
-- which this mode must not pick up.
overriddenRawConfig :: RawConfig
overriddenRawConfig =
  globalOnlyRawConfig
    { rawRepositories =
        Map.singleton
          "coghex/kanban"
          emptyRepositoryOverride {repositoryOverrideTimeouts = TimeoutsOverride (Just 60) (Just 61) (Just 62) (Just 63) (Just 64)}
    }

-- | Both providers pointed at real executables, on top of the shared resolved
-- configuration fixture.
configuredWith :: FilePath -> FilePath -> ResolvedConfig
configuredWith codexScript claudeScript =
  testResolvedConfig
    { resolvedUsage =
        defaultUsageConfig
          { usageCodexCommand = Just (UsageCommandConfig [Text.pack codexScript]),
            usageClaudeCommand = Just (UsageCommandConfig [Text.pack claudeScript])
          }
    }

-- | No provider configured an estimate, which is what every case that is not
-- about the estimate renders under.
noEstimates :: Map.Map UsageProvider Int
noEstimates = Map.empty

-- | A provider command that both answers and leaves evidence it ran, so a
-- "did not spawn" assertion rests on a recording mechanism the neighbouring
-- cold-cache cases have already shown to work.
recordingProvider :: FilePath -> String -> Int -> IO FilePath
recordingProvider root name percentLeft =
  writeExecutableScript
    (root </> (name <> "-usage.sh"))
    [ ByteString.pack ("echo " <> name <> " >> " <> spawnLog root),
      ByteString.pack
        ( "printf '%s' '{\"windows\":[{\"label\":\""
            <> name
            <> "-window\",\"pct_left\":"
            <> show percentLeft
            <> ",\"resets_at\":\"2026-07-16T17:00:00Z\"}]}'"
        )
    ]

spawnLog :: FilePath -> FilePath
spawnLog root = root </> "spawns.log"

-- | An absent log is no spawns, which is the state the cache-hit cases assert.
spawnsRecorded :: FilePath -> IO [String]
spawnsRecorded root = do
  recorded <- try @IOException (readFile' (spawnLog root))
  pure (either (const []) lines recorded)

-- | The cache is seeded through the writer the application itself uses, so the
-- fixture cannot drift from the schema the loader expects.
seedCache :: Map.Map UsageProvider UsageSnapshot -> IO ()
seedCache snapshots = do
  outcome <- writeUsageCache snapshots
  either (expectationFailure . Text.unpack) pure outcome

storedCache :: IO (Map.Map UsageProvider UsageSnapshot)
storedCache = do
  load <- loadUsageCache
  case load of
    UsageCacheLoaded snapshots -> pure snapshots
    UsageCacheAbsent -> pure Map.empty
    UsageCacheInvalid message -> Map.empty <$ expectationFailure (Text.unpack message)

-- | Both the snapshot cache and a usage command's scratch directory hang off
-- the XDG cache root, so pinning it is what keeps a run hermetic.
withUsageCacheRoot :: (FilePath -> IO result) -> IO result
withUsageCacheRoot action =
  withTemporaryCacheRoot $ \root -> withEnvironmentValue "XDG_CACHE_HOME" root (action root)

-- | Each provider's outcome reduced to what a caller would act on.
reportWindows :: UsageReport -> [(UsageProvider, Either Text [(Text, Int)])]
reportWindows report = map (fmap outcome) report.usageReportEntries
  where
    outcome (UsageFailed message) = Left message
    outcome (UsageAvailable snapshot) =
      Right (map (\window -> (window.usageWindowLabel, window.usagePercentLeft)) snapshot.usageWindows)

availableReport :: UsageSnapshot -> UsageReport
availableReport snapshot = UsageReport [(Codex, UsageAvailable snapshot)]

-- | A provider that answered with no windows at all. Reachable from the cache
-- decoder, which establishes no non-empty invariant, and the case an estimate
-- has nothing to be derived from.
emptyWindowReport :: UsageReport
emptyWindowReport = UsageReport [(Codex, UsageAvailable (UsageSnapshot [] (instant "2026-07-16T11:30:00Z")))]

partialReport :: UsageReport
partialReport =
  UsageReport
    [ (Codex, UsageAvailable oneWindowSnapshot),
      (Claude, UsageFailed "codex app-server is not installed")
    ]

twoWindowSnapshot :: UsageSnapshot
twoWindowSnapshot =
  UsageSnapshot
    [ UsageWindow "5 hour" 63 (instant "2026-07-16T16:05:00Z"),
      UsageWindow "weekly" 41 (instant "2026-07-20T09:00:00Z")
    ]
    (instant "2026-07-16T11:30:00Z")

oneWindowSnapshot :: UsageSnapshot
oneWindowSnapshot =
  UsageSnapshot [UsageWindow "5 hour" 63 (instant "2026-07-16T17:00:00Z")] (instant "2026-07-16T11:00:00Z")

expiredSnapshot :: UsageSnapshot
expiredSnapshot =
  UsageSnapshot [UsageWindow "5 hour" 63 (instant "2026-07-16T09:00:00Z")] (instant "2026-07-16T11:00:00Z")

aheadSnapshot :: UsageSnapshot
aheadSnapshot =
  UsageSnapshot [UsageWindow "5 hour" 63 (instant "2026-07-16T17:00:00Z")] (instant "2026-07-16T12:30:00Z")

cachedSnapshot :: UsageSnapshot
cachedSnapshot =
  UsageSnapshot [UsageWindow "cached" 12 (instant "2026-07-16T17:00:00Z")] (instant "2026-07-16T11:30:00Z")

instant :: String -> UTCTime
instant text = case iso8601ParseM text of
  Just parsed -> parsed
  Nothing -> error ("fixture instant is not ISO 8601: " <> text)
