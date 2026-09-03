module Kanban.CLI
  ( BorderPolicy (..),
    ColorPolicy (..),
    LaunchMode (..),
    Options (..),
    acquiresRepositoryLease,
    launchMode,
    launchModeNeedsProvider,
    launchModeRefusal,
    optionsParserInfo,
  )
where

import Data.Text (Text)
import Kanban.Models
  ( ModelRoster,
    RosterLoadError,
    agentsLoaded,
    loadedOperatingMode,
    noAgentModeMessage,
  )
import Kanban.ReviewToolServer (reviewToolServerFlag)
import Options.Applicative

data ColorPolicy = ColorAuto | ColorTruecolor | Color256 | ColorNever
  deriving stock (Eq, Show)

data BorderPolicy = BorderOpen | BorderBox
  deriving stock (Eq, Show)

data Options = Options
  { optionPath :: FilePath,
    optionRepo :: Maybe String,
    optionColor :: ColorPolicy,
    optionBorder :: BorderPolicy,
    optionGlyphTest :: Bool,
    optionDoctor :: Bool,
    optionUsage :: Bool,
    optionFresh :: Bool,
    optionJson :: Bool,
    -- | Every @--ping@ occurrence, in order, still unvalidated.  Collected as
    -- a list rather than a 'Maybe' so that supplying the flag twice — with
    -- two brands or the same one — reaches 'Kanban.Ping.resolvePingBrand' as
    -- the error it is, instead of one occurrence silently winning.
    optionPing :: [String],
    optionAscii :: Bool,
    optionNoCache :: Bool,
    optionConfig :: Maybe FilePath,
    optionWorkerSpec :: Maybe FilePath,
    optionReviewTools :: Maybe FilePath
  }
  deriving stock (Eq, Show)

-- | Which of @kanban@'s modes an invocation selects.
--
-- One decision rather than a cascade of guards in @main@, and in the library
-- rather than beside it, because two things now turn on it and neither can be
-- asserted about a module the test suite does not build:
-- @test-suite kanban-test@ compiles @test\/@ against the library and declares
-- no build-tool dependency on @executable kanban@, so a mode selection written
-- only in @app\/Main.hs@ is unreachable from every example.
--
-- The order is @main@'s, and it is not arbitrary: neither a worker nor the
-- re-entered review tool server is a dashboard
-- at all, the observational modes answer without needing configuration or a
-- repository, and a ping — the only one that spends quota — yields to every
-- one of them (§5). 'DashboardMode' is what is left, which is why it is last.
data LaunchMode
  = -- | @--worker@, carrying the spec path it names.
    WorkerMode FilePath
  | -- | @--review-tools@, carrying the endpoint directory it proxies over:
    -- Kanban re-entered as the stdio MCP server a review session's
    -- @claude@ spawns (D-15). Internal machinery exactly as the worker
    -- mode is — only a launch this process itself built ever invokes it —
    -- and it loads no roster, resolves no repository, reads no
    -- configuration, and takes no lease: everything a tool call needs
    -- lives in the parent on the other end of the endpoint.
    ReviewToolServerMode FilePath
  | -- | @--glyph-test@.
    GlyphTestMode
  | -- | @--doctor@.
    DoctorMode
  | -- | @--usage@.
    UsageQueryMode
  | -- | @--ping@, still unvalidated: 'Kanban.Ping.resolvePingBrand' decides
    -- whether the occurrences name one brand, and a malformed one refuses
    -- ahead of every mode here.
    PingQueryMode
  | -- | The dashboard.
    DashboardMode
  deriving stock (Eq, Show)

launchMode :: Options -> LaunchMode
launchMode options = case (options.optionWorkerSpec, options.optionReviewTools) of
  (Just workerSpec, _) -> WorkerMode workerSpec
  (Nothing, Just endpointDirectory) -> ReviewToolServerMode endpointDirectory
  (Nothing, Nothing)
    | options.optionGlyphTest -> GlyphTestMode
    | options.optionDoctor -> DoctorMode
    | options.optionUsage -> UsageQueryMode
    | not (null options.optionPing) -> PingQueryMode
    | otherwise -> DashboardMode

-- | Whether this mode reaches a model provider, and so has nothing to do when
-- the roster loads none.
--
-- Total in 'LaunchMode', so a mode added above cannot run without a decision
-- about whether a Kanban that spawns nothing may take it.
--
-- Only the two provider modes do. @--usage@ reads the loaded providers'
-- account status and @--ping@ spends quota on one, so both answer about
-- something a no-agent install does not have. Which providers those are is
-- the mode's own question and is asked past this gate:
-- 'Kanban.Usage.usageProviders' narrows the report and
-- 'Kanban.Ping.pingBrandRefusal' refuses a brand a single-agent install does
-- not load, both of which need a provider set this refusal has already
-- established is non-empty. Nothing else is: a worker replays the
-- assignment its own specification recorded and consults no roster at all,
-- the review tool server proxies to a parent that resolved everything
-- before launching it and likewise consults no roster,
-- @--doctor@ is the read-only mode that exists to say /why/ an AI action would
-- not start and so must answer in exactly this case, @--glyph-test@ asks the
-- terminal rather than a provider, and the dashboard is a board-only Kanban in
-- this mode rather than a refused one.
launchModeNeedsProvider :: LaunchMode -> Bool
launchModeNeedsProvider mode = case mode of
  UsageQueryMode -> True
  PingQueryMode -> True
  WorkerMode _ -> False
  ReviewToolServerMode _ -> False
  GlyphTestMode -> False
  DoctorMode -> False
  DashboardMode -> False

-- | What a mode says instead of running, given the roster the invocation
-- loaded, or 'Nothing' when it may run.
--
-- The complete load result rather than a mode, because 'loadedOperatingMode'
-- is where a @models.toml@ that will not load at all becomes no-agent: a
-- @Left@ has no @agents@ list to count, and refusing it here is what keeps an
-- unusable file from being answered as though it had loaded two providers.
--
-- A malformed @--ping@ never reaches this. @app\/Main.hs@ resolves the brand
-- ahead of mode selection precisely so an unknown or repeated one is reported
-- as itself (§5), and this decision is asked only after that refusal has had
-- its chance.
launchModeRefusal :: LaunchMode -> Either RosterLoadError ModelRoster -> Maybe Text
launchModeRefusal mode loaded
  | launchModeNeedsProvider mode,
    not (agentsLoaded (loadedOperatingMode loaded)) =
      Just noAgentModeMessage
  | otherwise = Nothing

-- | Whether this invocation takes the repository's board lease.
--
-- Only the dashboard does. Every other mode either never resolves a repository
-- (a worker is handed its own spec; the review tool server is handed its
-- endpoint; @--glyph-test@ and @--doctor@ answer from
-- the terminal and the environment) or resolves one without becoming a board
-- (@--usage@ is global, and @--ping@ starts a quota window and exits). None of
-- them writes the durable @gh@ record, so none of them has anything to
-- serialise against — and a mode that took the lease would refuse to run
-- beside an open board for no reason at all.
acquiresRepositoryLease :: Options -> Bool
acquiresRepositoryLease = (== DashboardMode) . launchMode

optionsParserInfo :: ParserInfo Options
optionsParserInfo =
  info
    (optionsParser <**> helper <**> versionOption)
    ( fullDesc
        <> header "kanban — an event-driven GitHub workflow dashboard"
        <> progDesc "Show repository work and on-demand AI usage in the terminal"
    )

optionsParser :: Parser Options
optionsParser =
  Options
    <$> strOption
      ( long "path"
          <> metavar "DIR"
          <> value "."
          <> showDefault
          <> help "Repository path (defaults to the current directory)"
      )
    <*> optional
      ( strOption
          ( long "repo"
              <> metavar "OWNER/NAME"
              <> help "Explicit GitHub repository; skips remote resolution"
          )
      )
    <*> option
      (eitherReader parseColorPolicy)
      ( long "color"
          <> metavar "auto|truecolor|256|never"
          <> value ColorAuto
          <> showDefaultWith (const "auto")
          <> help "Terminal color policy"
      )
    <*> option
      (eitherReader parseBorderPolicy)
      ( long "border"
          <> metavar "box|open"
          <> value BorderBox
          <> showDefaultWith (const "box")
          <> help "Border renderer"
      )
    <*> switch
      ( long "glyph-test"
          <> help "Print vertical-line candidates without starting the dashboard"
      )
    <*> switch
      ( long "doctor"
          <> help "Report AI-action readiness read-only, then exit without starting the dashboard"
      )
    <*> switch
      ( long "usage"
          <> help "Print the loaded providers' usage windows, then exit without starting the dashboard"
      )
    <*> switch
      ( long "fresh"
          <> help "With --usage, probe every loaded provider live instead of reading the cache"
      )
    <*> switch
      ( long "json"
          <> help "With --usage, write a machine-readable document instead of the human rendering"
      )
    <*> many
      ( strOption
          ( long "ping"
              <> metavar "codex|claude"
              <> help "Start the named provider's usage window with one deliberate model request, then exit"
          )
      )
    <*> switch (long "ascii" <> help "Use ASCII borders")
    <*> switch (long "no-cache" <> help "Do not read or write snapshots")
    <*> optional
      ( strOption
          ( long "config"
              <> metavar "FILE"
              <> help "Override the global configuration path"
          )
      )
    <*> optional
      ( strOption
          ( long "worker-spec"
              <> metavar "FILE"
              <> internal
          )
      )
    <*> optional
      ( strOption
          ( long reviewToolServerFlag
              <> metavar "DIR"
              <> internal
          )
      )

parseColorPolicy :: String -> Either String ColorPolicy
parseColorPolicy "auto" = Right ColorAuto
parseColorPolicy "truecolor" = Right ColorTruecolor
parseColorPolicy "256" = Right Color256
parseColorPolicy "never" = Right ColorNever
parseColorPolicy input = Left ("unknown color policy: " <> input)

parseBorderPolicy :: String -> Either String BorderPolicy
parseBorderPolicy "open" = Right BorderOpen
parseBorderPolicy "box" = Right BorderBox
parseBorderPolicy input = Left ("unknown border policy: " <> input)

versionOption :: Parser (a -> a)
versionOption = infoOption "kanban 1.1.0.0" (long "version" <> help "Show version")
