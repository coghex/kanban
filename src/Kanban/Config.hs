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
    resolveConfig,
    repositoryIdentity,
    resolveConfigPathOption,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (join)
import Data.List (intercalate)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Kanban.Domain
  ( ApprovalMode (..),
    BlockingSeverity (..),
    WorkflowConfig (..),
    defaultWorkflowConfig,
  )
import System.Directory (XdgDirectory (XdgConfig), doesFileExist, getXdgDirectory, makeAbsolute)
import System.FilePath ((</>))
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

-- | GitHub fetch caps and rendered-card excerpt height.
data LimitsConfig = LimitsConfig
  { limitsMaxOpenIssues :: Int,
    limitsMaxOpenPullRequests :: Int,
    limitsExcerptLines :: Int
  }
  deriving stock (Eq, Show)

defaultLimitsConfig :: LimitsConfig
defaultLimitsConfig =
  LimitsConfig
    { limitsMaxOpenIssues = 250,
      limitsMaxOpenPullRequests = 100,
      limitsExcerptLines = 3
    }

-- | Provider timeouts, in whole seconds.
data TimeoutsConfig = TimeoutsConfig
  { timeoutsGithubSeconds :: Int,
    timeoutsCodexSeconds :: Int,
    timeoutsClaudeSeconds :: Int
  }
  deriving stock (Eq, Show)

defaultTimeoutsConfig :: TimeoutsConfig
defaultTimeoutsConfig =
  TimeoutsConfig
    { timeoutsGithubSeconds = 30,
      timeoutsCodexSeconds = 10,
      timeoutsClaudeSeconds = 45
    }

-- | An external usage-provider command: executable followed by literal
-- arguments, launched directly without a shell. Parsed and validated now;
-- execution is a follow-up.
newtype UsageCommandConfig = UsageCommandConfig {usageCommandArgv :: [Text]}
  deriving stock (Eq, Show)

data UsageConfig = UsageConfig
  { usageCodexCommand :: Maybe UsageCommandConfig,
    usageClaudeCommand :: Maybe UsageCommandConfig
  }
  deriving stock (Eq, Show)

defaultUsageConfig :: UsageConfig
defaultUsageConfig = UsageConfig {usageCodexCommand = Nothing, usageClaudeCommand = Nothing}

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
    overrideBlockingSeverity :: Maybe BlockingSeverity
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
      overrideBlockingSeverity = Nothing
    }

data LimitsOverride = LimitsOverride
  { overrideMaxOpenIssues :: Maybe Int,
    overrideMaxOpenPullRequests :: Maybe Int,
    overrideExcerptLines :: Maybe Int
  }
  deriving stock (Eq, Show)

emptyLimitsOverride :: LimitsOverride
emptyLimitsOverride =
  LimitsOverride
    { overrideMaxOpenIssues = Nothing,
      overrideMaxOpenPullRequests = Nothing,
      overrideExcerptLines = Nothing
    }

data TimeoutsOverride = TimeoutsOverride
  { overrideGithubSeconds :: Maybe Int,
    overrideCodexSeconds :: Maybe Int,
    overrideClaudeSeconds :: Maybe Int
  }
  deriving stock (Eq, Show)

emptyTimeoutsOverride :: TimeoutsOverride
emptyTimeoutsOverride =
  TimeoutsOverride
    { overrideGithubSeconds = Nothing,
      overrideCodexSeconds = Nothing,
      overrideClaudeSeconds = Nothing
    }

-- | A single '[repositories."owner/name"]' table. Only workflow, limits, and
-- timeouts may be overridden per repository; 'cache', 'remote_name', and
-- 'usage' are global-only and rejected here.
data RepositoryOverride = RepositoryOverride
  { repositoryOverrideWorkflow :: WorkflowOverride,
    repositoryOverrideLimits :: LimitsOverride,
    repositoryOverrideTimeouts :: TimeoutsOverride
  }
  deriving stock (Eq, Show)

emptyRepositoryOverride :: RepositoryOverride
emptyRepositoryOverride =
  RepositoryOverride
    { repositoryOverrideWorkflow = emptyWorkflowOverride,
      repositoryOverrideLimits = emptyLimitsOverride,
      repositoryOverrideTimeouts = emptyTimeoutsOverride
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

-- | The exact, case-sensitive key used to select a '[repositories.*]' table.
repositoryIdentity :: Text -> Text -> Text
repositoryIdentity owner name = owner <> "/" <> name

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
    override = Map.findWithDefault emptyRepositoryOverride ownerName raw.rawRepositories

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
      blockingSeverity = fromMaybe base.blockingSeverity override.overrideBlockingSeverity
    }

applyLimitsOverride :: LimitsConfig -> LimitsOverride -> LimitsConfig
applyLimitsOverride base override =
  base
    { limitsMaxOpenIssues = fromMaybe base.limitsMaxOpenIssues override.overrideMaxOpenIssues,
      limitsMaxOpenPullRequests = fromMaybe base.limitsMaxOpenPullRequests override.overrideMaxOpenPullRequests,
      limitsExcerptLines = fromMaybe base.limitsExcerptLines override.overrideExcerptLines
    }

applyTimeoutsOverride :: TimeoutsConfig -> TimeoutsOverride -> TimeoutsConfig
applyTimeoutsOverride base override =
  base
    { timeoutsGithubSeconds = fromMaybe base.timeoutsGithubSeconds override.overrideGithubSeconds,
      timeoutsCodexSeconds = fromMaybe base.timeoutsCodexSeconds override.overrideCodexSeconds,
      timeoutsClaudeSeconds = fromMaybe base.timeoutsClaudeSeconds override.overrideClaudeSeconds
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
      Success warnings config -> Right (config, map (Text.pack . prettyMatchMessage) warnings)

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
  pure
    WorkflowOverride
      { overrideApprovalLabel = approvalLabelValue,
        overrideChangesRequestedLabel = changesRequestedLabelValue,
        overrideBlockedLabels = blockedLabelsValue,
        overrideTrackerLabels = trackerLabelsValue,
        overrideAdditionalTrackerSectionHeadings = headingsValue,
        overrideApprovalMode = approvalModeValue,
        overrideBlockingSeverity = blockingSeverityValue
      }

limitsOverrideParser :: ParseTable Position LimitsOverride
limitsOverrideParser = do
  maxOpenIssuesValue <- optKeyOf "max_open_issues" parsePositiveBoundedInt
  maxOpenPullRequestsValue <- optKeyOf "max_open_pull_requests" parsePositiveBoundedInt
  excerptLinesValue <- optKeyOf "excerpt_lines" parsePositiveBoundedInt
  pure
    LimitsOverride
      { overrideMaxOpenIssues = maxOpenIssuesValue,
        overrideMaxOpenPullRequests = maxOpenPullRequestsValue,
        overrideExcerptLines = excerptLinesValue
      }

timeoutsOverrideParser :: ParseTable Position TimeoutsOverride
timeoutsOverrideParser = do
  githubSecondsValue <- optKeyOf "github_seconds" parsePositiveTimeoutSeconds
  codexSecondsValue <- optKeyOf "codex_seconds" parsePositiveTimeoutSeconds
  claudeSecondsValue <- optKeyOf "claude_seconds" parsePositiveTimeoutSeconds
  pure
    TimeoutsOverride
      { overrideGithubSeconds = githubSecondsValue,
        overrideCodexSeconds = codexSecondsValue,
        overrideClaudeSeconds = claudeSecondsValue
      }

usageConfigParser :: ParseTable Position UsageConfig
usageConfigParser = do
  codexCommand <- optKeyOf "codex" (parseTableFromValue usageCommandTableParser)
  claudeCommand <- optKeyOf "claude" (parseTableFromValue usageCommandTableParser)
  pure UsageConfig {usageCodexCommand = join codexCommand, usageClaudeCommand = join claudeCommand}

usageCommandTableParser :: ParseTable Position (Maybe UsageCommandConfig)
usageCommandTableParser = optKeyOf "command" parseCommandArgv

parseRepositories :: Value' Position -> Matcher Position (Map Text RepositoryOverride)
parseRepositories = mapOf (\_ key -> pure key) (\_ value -> parseTableFromValue repositoryOverrideParser value)

repositoryOverrideParser :: ParseTable Position RepositoryOverride
repositoryOverrideParser = do
  workflowOverride <- optKeyOf "workflow" (parseTableFromValue workflowOverrideParser)
  limitsOverride <- optKeyOf "limits" (parseTableFromValue limitsOverrideParser)
  timeoutsOverride <- optKeyOf "timeouts" (parseTableFromValue timeoutsOverrideParser)
  mapM_ forbidRepositoryKey ["cache", "remote_name", "usage"]
  pure
    RepositoryOverride
      { repositoryOverrideWorkflow = fromMaybe emptyWorkflowOverride workflowOverride,
        repositoryOverrideLimits = fromMaybe emptyLimitsOverride limitsOverride,
        repositoryOverrideTimeouts = fromMaybe emptyTimeoutsOverride timeoutsOverride
      }

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

parseLabelSet :: Value' l -> Matcher l (Set Text)
parseLabelSet value = Set.fromList <$> parseNonEmptyTextList value

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

parseCommandArgv :: Value' l -> Matcher l UsageCommandConfig
parseCommandArgv value = do
  argv <- listOf (\_ element -> fromValue element) value
  case argv of
    [] -> failAt (valueAnn value) "command must be a non-empty array"
    (executable : _)
      | Text.null executable -> failAt (valueAnn value) "command executable must be a non-empty string"
    _ -> pure (UsageCommandConfig argv)
