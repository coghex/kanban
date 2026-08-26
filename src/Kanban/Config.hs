{-# LANGUAGE DerivingStrategies #-}

module Kanban.Config
  ( LimitsConfig (..),
    TimeoutsConfig (..),
    UsageCommandConfig (..),
    UsageConfig (..),
    WorkflowOverride (..),
    LimitsOverride (..),
    TimeoutsOverride (..),
    RepositoryOverride (..),
    RawConfig (..),
    ResolvedConfig (..),
    defaultLimitsConfig,
    defaultTimeoutsConfig,
    defaultUsageConfig,
    defaultRawConfig,
    emptyWorkflowOverride,
    emptyLimitsOverride,
    emptyTimeoutsOverride,
    emptyRepositoryOverride,
    defaultConfigPath,
    decodeConfigText,
    loadRawConfig,
    cacheEnabled,
    resolveConfig,
    resolveGlobalConfig,
    repositoryIdentity,
    asciiLowercase,
    configuredRepositoryPaths,
    resolveConfigPathOption,
    usageSolveRoundEstimate,
    usageSolveRoundEstimates,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (join)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, toLower)
import Data.List (intercalate)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Kanban.CLI (Options (..))
import Kanban.Domain
  ( ApprovalMode (..),
    BlockingSeverity (..),
    UsageProvider (..),
    WorkflowConfig (..),
    defaultWorkflowConfig,
  )
import System.Directory (XdgDirectory (XdgConfig), doesFileExist, getXdgDirectory, makeAbsolute)
import System.FilePath (isAbsolute, (</>))
import Toml
  ( Position,
    Result (..),
    Table' (..),
    Value' (..),
    parse,
    prettyMatchMessage,
    valueAnn,
  )
import Toml.Schema
  ( Matcher,
    ParseTable,
    failAt,
    failTableAt,
    fromValue,
    getTable,
    listOf,
    mapOf,
    optKey,
    optKeyOf,
    parseTable,
    parseTableFromValue,
    runMatcher,
  )
import Toml.Syntax (startPos)

-- | Rendered-card excerpt height. There are no open-connection caps to
-- configure: a refresh follows both open connections to their end (§13).
newtype LimitsConfig = LimitsConfig
  { limitsExcerptLines :: Int
  }
  deriving stock (Eq, Show)

defaultLimitsConfig :: LimitsConfig
defaultLimitsConfig =
  LimitsConfig
    { limitsExcerptLines = 3
    }

-- | Provider timeouts, in whole seconds.
--
-- The ping fields are separate from 'timeoutsCodexSeconds' and
-- 'timeoutsClaudeSeconds' on purpose: those two bound an account-status read,
-- which is a different and much shorter operation than the model round trip a
-- deliberate ping submits (§14).
data TimeoutsConfig = TimeoutsConfig
  { timeoutsGithubSeconds :: Int,
    timeoutsCodexSeconds :: Int,
    timeoutsClaudeSeconds :: Int,
    timeoutsPingCodexSeconds :: Int,
    timeoutsPingClaudeSeconds :: Int
  }
  deriving stock (Eq, Show)

defaultTimeoutsConfig :: TimeoutsConfig
defaultTimeoutsConfig =
  TimeoutsConfig
    { timeoutsGithubSeconds = 30,
      timeoutsCodexSeconds = 10,
      timeoutsClaudeSeconds = 45,
      timeoutsPingCodexSeconds = 120,
      timeoutsPingClaudeSeconds = 120
    }

-- | An external usage-provider command: executable followed by literal
-- arguments, launched directly without a shell. Parsed and validated now;
-- execution is a follow-up.
newtype UsageCommandConfig = UsageCommandConfig {usageCommandArgv :: [Text]}
  deriving stock (Eq, Show)

-- | One provider's usage configuration.  The estimate is a sibling of the
-- command rather than part of it: a table carrying only
-- @estimated_percent_per_solve_round@ is valid, and the estimate then
-- describes whatever windows the built-in probe reports.
data UsageConfig = UsageConfig
  { usageCodexCommand :: Maybe UsageCommandConfig,
    usageCodexEstimatedPercentPerSolveRound :: Maybe Int,
    usageClaudeCommand :: Maybe UsageCommandConfig,
    usageClaudeEstimatedPercentPerSolveRound :: Maybe Int
  }
  deriving stock (Eq, Show)

defaultUsageConfig :: UsageConfig
defaultUsageConfig =
  UsageConfig
    { usageCodexCommand = Nothing,
      usageCodexEstimatedPercentPerSolveRound = Nothing,
      usageClaudeCommand = Nothing,
      usageClaudeEstimatedPercentPerSolveRound = Nothing
    }

-- | The percentage one solve round is configured to cost for this provider,
-- if any.  Nothing is the unconfigured case, which renders no estimate at
-- all rather than assuming a default cost.
usageSolveRoundEstimate :: UsageConfig -> UsageProvider -> Maybe Int
usageSolveRoundEstimate usage Codex = usage.usageCodexEstimatedPercentPerSolveRound
usageSolveRoundEstimate usage Claude = usage.usageClaudeEstimatedPercentPerSolveRound

-- | Every configured estimate, keyed by provider, in the shape the renderers
-- take it in.  A provider that configured none is absent rather than present
-- with a zero, so the two states stay distinguishable downstream.
usageSolveRoundEstimates :: UsageConfig -> Map UsageProvider Int
usageSolveRoundEstimates usage =
  Map.fromList
    [ (provider, estimate)
    | provider <- [Codex, Claude],
      Just estimate <- [usageSolveRoundEstimate usage provider]
    ]

-- | Per-field overrides for '[workflow]', decoded identically at the global
-- and per-repository level. Global values apply defaults for any field left
-- 'Nothing'; a repository override only replaces the fields it sets.
data WorkflowOverride = WorkflowOverride
  { overrideApprovalLabel :: Maybe Text,
    overrideChangesRequestedLabel :: Maybe Text,
    overrideBlockedLabels :: Maybe (Set Text),
    overrideTrackerLabels :: Maybe (Set Text),
    overrideAdditionalTrackerSectionHeadings :: Maybe [Text],
    overrideApprovalMode :: Maybe ApprovalMode,
    overrideBlockingSeverity :: Maybe BlockingSeverity,
    overrideProblemStyleLabels :: Maybe (Set Text),
    overrideUiStyleLabels :: Maybe (Set Text),
    overrideCoordinationPaths :: Maybe (Set Text),
    overrideDirectPublicationPaths :: Maybe (Set Text)
  }
  deriving stock (Eq, Show)

emptyWorkflowOverride :: WorkflowOverride
emptyWorkflowOverride =
  WorkflowOverride
    { overrideApprovalLabel = Nothing,
      overrideChangesRequestedLabel = Nothing,
      overrideBlockedLabels = Nothing,
      overrideTrackerLabels = Nothing,
      overrideAdditionalTrackerSectionHeadings = Nothing,
      overrideApprovalMode = Nothing,
      overrideBlockingSeverity = Nothing,
      overrideProblemStyleLabels = Nothing,
      overrideUiStyleLabels = Nothing,
      overrideCoordinationPaths = Nothing,
      overrideDirectPublicationPaths = Nothing
    }

newtype LimitsOverride = LimitsOverride
  { overrideExcerptLines :: Maybe Int
  }
  deriving stock (Eq, Show)

emptyLimitsOverride :: LimitsOverride
emptyLimitsOverride =
  LimitsOverride
    { overrideExcerptLines = Nothing
    }

data TimeoutsOverride = TimeoutsOverride
  { overrideGithubSeconds :: Maybe Int,
    overrideCodexSeconds :: Maybe Int,
    overrideClaudeSeconds :: Maybe Int,
    overridePingCodexSeconds :: Maybe Int,
    overridePingClaudeSeconds :: Maybe Int
  }
  deriving stock (Eq, Show)

emptyTimeoutsOverride :: TimeoutsOverride
emptyTimeoutsOverride =
  TimeoutsOverride
    { overrideGithubSeconds = Nothing,
      overrideCodexSeconds = Nothing,
      overrideClaudeSeconds = Nothing,
      overridePingCodexSeconds = Nothing,
      overridePingClaudeSeconds = Nothing
    }

-- | A single '[repositories."owner/name"]' table. Only workflow, limits, and
-- timeouts may be overridden per repository; 'cache', 'remote_name', and
-- 'usage' are global-only and rejected here. The fourth key, 'path', is not
-- an override at all: it declares where this repository is checked out on
-- this machine, and is what makes the table a member of the repository
-- roster ('configuredRepositoryPaths').
data RepositoryOverride = RepositoryOverride
  { repositoryOverrideWorkflow :: WorkflowOverride,
    repositoryOverrideLimits :: LimitsOverride,
    repositoryOverrideTimeouts :: TimeoutsOverride,
    repositoryOverridePath :: Maybe FilePath
  }
  deriving stock (Eq, Show)

emptyRepositoryOverride :: RepositoryOverride
emptyRepositoryOverride =
  RepositoryOverride
    { repositoryOverrideWorkflow = emptyWorkflowOverride,
      repositoryOverrideLimits = emptyLimitsOverride,
      repositoryOverrideTimeouts = emptyTimeoutsOverride,
      repositoryOverridePath = Nothing
    }

-- | The fully decoded configuration file: global defaults plus every
-- repository override table, before a specific repository is selected.
data RawConfig = RawConfig
  { rawCache :: Bool,
    rawRemoteName :: Text,
    rawWorkflow :: WorkflowConfig,
    rawLimits :: LimitsConfig,
    rawTimeouts :: TimeoutsConfig,
    rawUsage :: UsageConfig,
    rawRepositories :: Map Text RepositoryOverride
  }
  deriving stock (Eq, Show)

defaultRawConfig :: RawConfig
defaultRawConfig =
  RawConfig
    { rawCache = True,
      rawRemoteName = "origin",
      rawWorkflow = defaultWorkflowConfig,
      rawLimits = defaultLimitsConfig,
      rawTimeouts = defaultTimeoutsConfig,
      rawUsage = defaultUsageConfig,
      rawRepositories = Map.empty
    }

-- | Global configuration with a single repository's override table merged
-- in. This is what the rest of the application consumes.
data ResolvedConfig = ResolvedConfig
  { resolvedCache :: Bool,
    resolvedRemoteName :: Text,
    resolvedWorkflow :: WorkflowConfig,
    resolvedLimits :: LimitsConfig,
    resolvedTimeouts :: TimeoutsConfig,
    resolvedUsage :: UsageConfig
  }
  deriving stock (Eq, Show)

-- | The resolved @OWNER\/NAME@ identity, spelled as the remote or @--repo@
-- spelled it.  'resolveConfig' folds it to lowercase before selecting a
-- @[repositories.*]@ table, so a @Coghex\/Kanban@ clone still selects the
-- canonical @coghex\/kanban@ key; the identity itself keeps its case for the
-- GitHub queries, cache paths, and display built from it.
repositoryIdentity :: Text -> Text -> Text
repositoryIdentity owner name = owner <> "/" <> name

-- | The configured half of the repository roster: exactly the
-- @[repositories."owner\/name"]@ tables that set a @path@, each paired with
-- the absolute checkout the parser already accepted, in canonical key order.
--
-- A table that sets no @path@ contributes nothing here and keeps its present
-- meaning -- an override table for whichever repository the session opens --
-- so no existing configuration gains a roster entry on upgrade.  The keys
-- are canonical lowercase by construction ('isCanonicalRepositoryKey'), and
-- each one is the identity its entry is keyed, queried, and reported under;
-- 'Kanban.Repository.resolveRepositoryRoster' is what turns this list into a
-- roster, and the launch checkout's own membership is its business rather
-- than the configuration's.
configuredRepositoryPaths :: RawConfig -> [(Text, FilePath)]
configuredRepositoryPaths raw =
  [ (key, path)
    | (key, override) <- Map.toList raw.rawRepositories,
      Just path <- [override.repositoryOverridePath]
  ]

-- | ASCII-only case folding.  'Data.Text.toLower' would apply Unicode
-- mappings that @tools\/kanban_config.py@ need not reproduce; under this
-- mapping a non-ASCII identity simply matches no canonical key, which is the
-- correct outcome on both sides.
asciiLowercase :: Text -> Text
asciiLowercase = Text.map lowerAscii
  where
    lowerAscii character
      | isAsciiUpper character = toLower character
      | otherwise = character

-- | Whether snapshot caching is on for this run: @--no-cache@ or a global
-- @cache = false@ each turn it off, and the flag always wins.  Every reader
-- and writer of a snapshot answers from here so a run cannot have caching off
-- for one cache and on for another.
cacheEnabled :: Options -> ResolvedConfig -> Bool
cacheEnabled options config = not options.optionNoCache && config.resolvedCache

-- | Resolution with no repository in play, for the run-and-exit modes that
-- never resolve one.  Every group keeps its global value: usage commands are
-- global already, and with no @owner/name@ there is nothing for a repository
-- override to be keyed by.
resolveGlobalConfig :: RawConfig -> ResolvedConfig
resolveGlobalConfig raw =
  ResolvedConfig
    { resolvedCache = raw.rawCache,
      resolvedRemoteName = raw.rawRemoteName,
      resolvedWorkflow = raw.rawWorkflow,
      resolvedLimits = raw.rawLimits,
      resolvedTimeouts = raw.rawTimeouts,
      resolvedUsage = raw.rawUsage
    }

resolveConfig :: Text -> RawConfig -> ResolvedConfig
resolveConfig ownerName raw =
  ResolvedConfig
    { resolvedCache = raw.rawCache,
      resolvedRemoteName = raw.rawRemoteName,
      resolvedWorkflow = applyWorkflowOverride raw.rawWorkflow override.repositoryOverrideWorkflow,
      resolvedLimits = applyLimitsOverride raw.rawLimits override.repositoryOverrideLimits,
      resolvedTimeouts = applyTimeoutsOverride raw.rawTimeouts override.repositoryOverrideTimeouts,
      resolvedUsage = raw.rawUsage
    }
  where
    -- Override keys are canonical lowercase, so the lookup is the one place
    -- the identity is folded.  Normalizing any further would relocate cache
    -- files and change the identity GitHub is queried and displayed under.
    override = Map.findWithDefault emptyRepositoryOverride (asciiLowercase ownerName) raw.rawRepositories

applyWorkflowOverride :: WorkflowConfig -> WorkflowOverride -> WorkflowConfig
applyWorkflowOverride base override =
  base
    { approvalLabel = fromMaybe base.approvalLabel override.overrideApprovalLabel,
      changesRequestedLabel = fromMaybe base.changesRequestedLabel override.overrideChangesRequestedLabel,
      blockedLabels = fromMaybe base.blockedLabels override.overrideBlockedLabels,
      trackerLabels = fromMaybe base.trackerLabels override.overrideTrackerLabels,
      additionalTrackerSectionHeadings =
        fromMaybe base.additionalTrackerSectionHeadings override.overrideAdditionalTrackerSectionHeadings,
      approvalMode = fromMaybe base.approvalMode override.overrideApprovalMode,
      blockingSeverity = fromMaybe base.blockingSeverity override.overrideBlockingSeverity,
      problemStyleLabels = fromMaybe base.problemStyleLabels override.overrideProblemStyleLabels,
      uiStyleLabels = fromMaybe base.uiStyleLabels override.overrideUiStyleLabels,
      coordinationPaths = fromMaybe base.coordinationPaths override.overrideCoordinationPaths,
      directPublicationPaths =
        fromMaybe base.directPublicationPaths override.overrideDirectPublicationPaths
    }

applyLimitsOverride :: LimitsConfig -> LimitsOverride -> LimitsConfig
applyLimitsOverride base override =
  base
    { limitsExcerptLines = fromMaybe base.limitsExcerptLines override.overrideExcerptLines
    }

applyTimeoutsOverride :: TimeoutsConfig -> TimeoutsOverride -> TimeoutsConfig
applyTimeoutsOverride base override =
  base
    { timeoutsGithubSeconds = fromMaybe base.timeoutsGithubSeconds override.overrideGithubSeconds,
      timeoutsCodexSeconds = fromMaybe base.timeoutsCodexSeconds override.overrideCodexSeconds,
      timeoutsClaudeSeconds = fromMaybe base.timeoutsClaudeSeconds override.overrideClaudeSeconds,
      timeoutsPingCodexSeconds = fromMaybe base.timeoutsPingCodexSeconds override.overridePingCodexSeconds,
      timeoutsPingClaudeSeconds = fromMaybe base.timeoutsPingClaudeSeconds override.overridePingClaudeSeconds
    }

--------------------------------------------------------------------------------
-- Loading

defaultConfigPath :: IO FilePath
defaultConfigPath = do
  configRoot <- getXdgDirectory XdgConfig "kanban"
  pure (configRoot </> "config.toml")

-- | Resolve an explicit @--config@ option (if any) to an absolute path,
-- against the current process's own directory, before it is forwarded to a
-- canonical issue-review or pull-request worker that runs from the target
-- repository's directory instead — a relative path would otherwise name a
-- different (or missing) file once read from there.
resolveConfigPathOption :: Maybe FilePath -> IO (Maybe FilePath)
resolveConfigPathOption = traverse makeAbsolute

-- | Load and decode the configuration file at the given path, or the default
-- path when 'Nothing'. A missing file silently yields 'defaultRawConfig'. A
-- malformed file, or a known key with an invalid value, is reported as an
-- error naming the file and the full key path; unknown keys are reported as
-- warnings and do not prevent loading.
loadRawConfig :: Maybe FilePath -> IO (Either Text (RawConfig, [Text]))
loadRawConfig explicitPath = do
  path <- maybe defaultConfigPath pure explicitPath
  exists <- doesFileExist path
  if not exists
    then pure (Right (defaultRawConfig, []))
    else do
      readResult <- try @IOException (TextIO.readFile path)
      pure $ case readResult of
        Left exception ->
          Left ("could not read configuration file " <> Text.pack path <> ": " <> Text.pack (show exception))
        Right contents -> case decodeConfigText contents of
          Left message -> Left ("configuration file " <> Text.pack path <> " " <> message)
          Right (config, warnings) ->
            Right (config, map (\message -> "configuration file " <> Text.pack path <> ": " <> message) warnings)

-- | Pure decoding entry point, exercised directly by tests: parse TOML
-- syntax and semantics, then match it against the stable configuration
-- schema, returning any unknown-key warnings alongside the result.
decodeConfigText :: Text -> Either Text (RawConfig, [Text])
decodeConfigText input =
  case parse input of
    Left syntaxError -> Left (Text.pack ("is invalid: " <> syntaxError))
    Right table -> case runMatcher (parseTable rawConfigParser startPos table) of
      Failure errors -> Left (Text.pack ("is invalid: " <> intercalate "; " (map prettyMatchMessage errors)))
      Success warnings config -> case validateRawConfig config of
        Left message -> Left ("is invalid: " <> message)
        Right () -> Right (config, map (Text.pack . prettyMatchMessage) warnings)

-- | The resolved approval and changes-requested labels must be distinct
-- from each other and from the fixed 'reviewed:revised' protocol label,
-- for every selectable repository, not merely the global table: a
-- repository override that only sets one of the two labels can still
-- collide once merged with the global value of the other.
validateRawConfig :: RawConfig -> Either Text ()
validateRawConfig raw = do
  validateWorkflowLabelDistinctness "workflow" raw.rawWorkflow
  mapM_
    ( \(name, override) ->
        validateWorkflowLabelDistinctness
          ("repositories.\"" <> name <> "\".workflow")
          (applyWorkflowOverride raw.rawWorkflow override.repositoryOverrideWorkflow)
    )
    (Map.toList raw.rawRepositories)

validateWorkflowLabelDistinctness :: Text -> WorkflowConfig -> Either Text ()
validateWorkflowLabelDistinctness context config
  | foldedApproval == foldedChanges =
      Left
        ( context
            <> ".approval_label and "
            <> context
            <> ".changes_requested_label must not resolve to the same label ("
            <> config.approvalLabel
            <> ")"
        )
  | foldedApproval == "reviewed:revised" =
      Left (context <> ".approval_label must not resolve to the reserved reviewed:revised label")
  | foldedChanges == "reviewed:revised" =
      Left (context <> ".changes_requested_label must not resolve to the reserved reviewed:revised label")
  | otherwise = Right ()
  where
    foldedApproval = Text.toCaseFold config.approvalLabel
    foldedChanges = Text.toCaseFold config.changesRequestedLabel

rawConfigParser :: ParseTable Position RawConfig
rawConfigParser = do
  cache <- optKey "cache"
  remoteName <- optKeyOf "remote_name" parseNonEmptyText
  workflowOverride <- optKeyOf "workflow" (parseTableFromValue workflowOverrideParser)
  limitsOverride <- optKeyOf "limits" (parseTableFromValue limitsOverrideParser)
  timeoutsOverride <- optKeyOf "timeouts" (parseTableFromValue timeoutsOverrideParser)
  usage <- optKeyOf "usage" (parseTableFromValue usageConfigParser)
  repositories <- optKeyOf "repositories" parseRepositories
  pure
    RawConfig
      { rawCache = fromMaybe True cache,
        rawRemoteName = fromMaybe "origin" remoteName,
        rawWorkflow = applyWorkflowOverride defaultWorkflowConfig (fromMaybe emptyWorkflowOverride workflowOverride),
        rawLimits = applyLimitsOverride defaultLimitsConfig (fromMaybe emptyLimitsOverride limitsOverride),
        rawTimeouts = applyTimeoutsOverride defaultTimeoutsConfig (fromMaybe emptyTimeoutsOverride timeoutsOverride),
        rawUsage = fromMaybe defaultUsageConfig usage,
        rawRepositories = fromMaybe Map.empty repositories
      }

workflowOverrideParser :: ParseTable Position WorkflowOverride
workflowOverrideParser = do
  approvalLabelValue <- optKeyOf "approval_label" parseNonEmptyText
  changesRequestedLabelValue <- optKeyOf "changes_requested_label" parseNonEmptyText
  blockedLabelsValue <- optKeyOf "blocked_labels" parseLabelSet
  trackerLabelsValue <- optKeyOf "tracker_labels" parseLabelSet
  headingsValue <- optKeyOf "additional_tracker_section_headings" parseNonEmptyTextList
  approvalModeValue <- optKeyOf "approval_mode" parseApprovalMode
  blockingSeverityValue <- optKeyOf "blocking_severity" parseBlockingSeverity
  problemStyleLabelsValue <- optKeyOf "problem_style_labels" parseLabelSet
  uiStyleLabelsValue <- optKeyOf "ui_style_labels" parseLabelSet
  coordinationPathsValue <- optKeyOf "coordination_paths" parseNonEmptyTextSet
  directPublicationPathsValue <- optKeyOf "direct_publication_paths" parseNonEmptyTextSet
  pure
    WorkflowOverride
      { overrideApprovalLabel = approvalLabelValue,
        overrideChangesRequestedLabel = changesRequestedLabelValue,
        overrideBlockedLabels = blockedLabelsValue,
        overrideTrackerLabels = trackerLabelsValue,
        overrideAdditionalTrackerSectionHeadings = headingsValue,
        overrideApprovalMode = approvalModeValue,
        overrideBlockingSeverity = blockingSeverityValue,
        overrideProblemStyleLabels = problemStyleLabelsValue,
        overrideUiStyleLabels = uiStyleLabelsValue,
        overrideCoordinationPaths = coordinationPathsValue,
        overrideDirectPublicationPaths = directPublicationPathsValue
      }

limitsOverrideParser :: ParseTable Position LimitsOverride
limitsOverrideParser = do
  excerptLinesValue <- optKeyOf "excerpt_lines" parsePositiveBoundedInt
  pure
    LimitsOverride
      { overrideExcerptLines = excerptLinesValue
      }

timeoutsOverrideParser :: ParseTable Position TimeoutsOverride
timeoutsOverrideParser = do
  githubSecondsValue <- optKeyOf "github_seconds" parsePositiveTimeoutSeconds
  codexSecondsValue <- optKeyOf "codex_seconds" parsePositiveTimeoutSeconds
  claudeSecondsValue <- optKeyOf "claude_seconds" parsePositiveTimeoutSeconds
  pingCodexSecondsValue <- optKeyOf "ping_codex_seconds" parsePositiveTimeoutSeconds
  pingClaudeSecondsValue <- optKeyOf "ping_claude_seconds" parsePositiveTimeoutSeconds
  pure
    TimeoutsOverride
      { overrideGithubSeconds = githubSecondsValue,
        overrideCodexSeconds = codexSecondsValue,
        overrideClaudeSeconds = claudeSecondsValue,
        overridePingCodexSeconds = pingCodexSecondsValue,
        overridePingClaudeSeconds = pingClaudeSecondsValue
      }

usageConfigParser :: ParseTable Position UsageConfig
usageConfigParser = do
  codex <- optKeyOf "codex" (parseTableFromValue usageProviderTableParser)
  claude <- optKeyOf "claude" (parseTableFromValue usageProviderTableParser)
  pure
    UsageConfig
      { usageCodexCommand = join (fst <$> codex),
        usageCodexEstimatedPercentPerSolveRound = join (snd <$> codex),
        usageClaudeCommand = join (fst <$> claude),
        usageClaudeEstimatedPercentPerSolveRound = join (snd <$> claude)
      }

-- | Both keys a provider table may carry, each optional and neither gating
-- the other: an estimate without a command configures the built-in probe's
-- windows, and a command without an estimate renders none.
usageProviderTableParser :: ParseTable Position (Maybe UsageCommandConfig, Maybe Int)
usageProviderTableParser = do
  command <- optKeyOf "command" parseCommandArgv
  estimate <- optKeyOf "estimated_percent_per_solve_round" parseSolveRoundPercent
  pure (command, estimate)

parseRepositories :: Value' Position -> Matcher Position (Map Text RepositoryOverride)
parseRepositories = mapOf parseRepositoryKey (\_ value -> parseTableFromValue repositoryOverrideParser value)

-- | A repository override key is a configuration identifier, not another
-- spelling of @--repo@ input: exactly one canonical lowercase GitHub
-- @owner\/name@ pair.  'Kanban.Repository.parseRepositoryName' stays
-- deliberately broader, because the user typed that value for this
-- invocation; a key admitted here but never selectable would instead sit in
-- the file doing nothing.  The message names the key itself: this runs
-- before the parser descends into the table, so the rendered scope is only
-- @repositories@.
parseRepositoryKey :: Position -> Text -> Matcher Position Text
parseRepositoryKey location key
  | isCanonicalRepositoryKey key = pure key
  | otherwise =
      failAt
        location
        ( "repositories.\""
            <> Text.unpack key
            <> "\" is not a canonical repository key;"
            <> " expected lowercase OWNER/NAME such as \"coghex/kanban\""
        )

-- | Two non-empty segments of lowercase ASCII identifier characters around
-- exactly one @\/@.  That rejects uppercase, surrounding whitespace, URL and
-- SCP remote syntax, repeated or extra slashes, and a missing segment by
-- character and shape alone; a @.git@ suffix needs its own rejection because
-- every character in it is otherwise legal.
isCanonicalRepositoryKey :: Text -> Bool
isCanonicalRepositoryKey key = case Text.splitOn "/" key of
  [owner, name] ->
    isCanonicalSegment owner && isCanonicalSegment name && not (".git" `Text.isSuffixOf` name)
  _ -> False
  where
    isCanonicalSegment segment = not (Text.null segment) && Text.all isCanonicalKeyCharacter segment

isCanonicalKeyCharacter :: Char -> Bool
isCanonicalKeyCharacter character =
  isAsciiLower character || isDigit character || character `elem` ("._-" :: String)

repositoryOverrideParser :: ParseTable Position RepositoryOverride
repositoryOverrideParser = do
  workflowOverride <- optKeyOf "workflow" (parseTableFromValue workflowOverrideParser)
  limitsOverride <- optKeyOf "limits" (parseTableFromValue limitsOverrideParser)
  timeoutsOverride <- optKeyOf "timeouts" (parseTableFromValue timeoutsOverrideParser)
  checkoutPath <- optKeyOf "path" parseCheckoutPath
  mapM_ forbidRepositoryKey ["cache", "remote_name", "usage"]
  pure
    RepositoryOverride
      { repositoryOverrideWorkflow = fromMaybe emptyWorkflowOverride workflowOverride,
        repositoryOverrideLimits = fromMaybe emptyLimitsOverride limitsOverride,
        repositoryOverrideTimeouts = fromMaybe emptyTimeoutsOverride timeoutsOverride,
        repositoryOverridePath = checkoutPath
      }

-- | A roster @path@ names one checkout on this machine, and is validated as
-- the literal string the file carries -- before any expansion or resolution,
-- so @~\/work\/repo@ is a non-absolute value rather than a home-relative
-- one, because nothing here expands it.  A relative value has no defensible
-- meaning to degrade into: the file is read from a fixed XDG location but
-- consumed by workers running from other directories, so the same file would
-- name different checkouts depending on where kanban was launched --
-- exactly the hazard 'resolveConfigPathOption' documents for @--config@.
-- That is why this is the one roster mistake that is a load-time error
-- rather than a degraded entry (section 16).  Everything else about the
-- path -- whether it exists, is a Git checkout, or agrees with the key --
-- is resolution's business, not the schema's.
parseCheckoutPath :: Value' l -> Matcher l FilePath
parseCheckoutPath value = do
  text <- parseNonEmptyText value
  let candidate = Text.unpack text
  if isAbsolute candidate
    then pure candidate
    else failAt (valueAnn value) "must be an absolute path to a checkout"

forbidRepositoryKey :: Text -> ParseTable Position ()
forbidRepositoryKey key = do
  MkTable currentTable <- getTable
  case Map.lookup key currentTable of
    Nothing -> pure ()
    Just (location, _) ->
      failTableAt location (Text.unpack key <> " is not valid in a repository override; it is global-only")

--------------------------------------------------------------------------------
-- Value-level validation

parseNonEmptyText :: Value' l -> Matcher l Text
parseNonEmptyText value = do
  text <- fromValue value
  if Text.null text
    then failAt (valueAnn value) "must be a non-empty string"
    else pure text

parseNonEmptyTextList :: Value' l -> Matcher l [Text]
parseNonEmptyTextList = listOf (\_ value -> parseNonEmptyText value)

parseNonEmptyTextSet :: Value' l -> Matcher l (Set Text)
parseNonEmptyTextSet value = Set.fromList <$> parseNonEmptyTextList value

-- | Labels validate exactly as any other set of non-empty strings does; the
-- separate name is only so a label key reads as one at its use site.
parseLabelSet :: Value' l -> Matcher l (Set Text)
parseLabelSet = parseNonEmptyTextSet

parseApprovalMode :: Value' l -> Matcher l ApprovalMode
parseApprovalMode value = do
  text <- fromValue value
  case (text :: Text) of
    "label" -> pure ApprovalByLabel
    "review" -> pure ApprovalByReview
    "either" -> pure ApprovalByEither
    other ->
      failAt (valueAnn value) ("invalid approval_mode " <> show other <> "; expected \"label\", \"review\", or \"either\"")

parseBlockingSeverity :: Value' l -> Matcher l BlockingSeverity
parseBlockingSeverity value = do
  text <- fromValue value
  case (text :: Text) of
    "red" -> pure SeverityRed
    "amber" -> pure SeverityAmber
    other -> failAt (valueAnn value) ("invalid blocking_severity " <> show other <> "; expected \"red\" or \"amber\"")

parsePositiveBoundedInt :: Value' l -> Matcher l Int
parsePositiveBoundedInt value = do
  number <- fromValue value
  if number <= (0 :: Int)
    then failAt (valueAnn value) "must be a positive integer"
    else pure number

-- | A timeout in whole seconds must additionally stay small enough to
-- convert to microseconds ('System.Timeout.timeout' takes an 'Int') without
-- overflowing.
parsePositiveTimeoutSeconds :: Value' l -> Matcher l Int
parsePositiveTimeoutSeconds value = do
  number <- parsePositiveBoundedInt value
  if number > maxBound `div` microsecondsPerSecond
    then failAt (valueAnn value) "must not be large enough to overflow when converted to microseconds"
    else pure number
  where
    microsecondsPerSecond = 1000000 :: Int

-- | The estimated percentage one solve round consumes: a whole percentage of
-- a window, so anything outside 1 through 100 is a configuration error rather
-- than a value silently clamped.  Zero in particular has to be rejected here,
-- because the round count divides by it.
parseSolveRoundPercent :: Value' l -> Matcher l Int
parseSolveRoundPercent value = do
  number <- fromValue value
  if number < 1 || number > (100 :: Int)
    then failAt (valueAnn value) "must be a whole percentage from 1 through 100"
    else pure number

parseCommandArgv :: Value' l -> Matcher l UsageCommandConfig
parseCommandArgv value = do
  argv <- listOf (\_ element -> fromValue element) value
  case argv of
    [] -> failAt (valueAnn value) "command must be a non-empty array"
    (executable : _)
      | Text.null executable -> failAt (valueAnn value) "command executable must be a non-empty string"
    _ -> pure (UsageCommandConfig argv)
