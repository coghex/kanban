module Kanban.CLI
  ( BorderPolicy (..),
    ColorPolicy (..),
    LaunchMode (..),
    Options (..),
    acquiresRepositoryLease,
    launchMode,
    optionsParserInfo,
  )
where

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
    optionWorkerSpec :: Maybe FilePath
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
-- The order is @main@'s, and it is not arbitrary: a worker is not a dashboard
-- at all, the observational modes answer without needing configuration or a
-- repository, and a ping — the only one that spends quota — yields to every
-- one of them (§5). 'DashboardMode' is what is left, which is why it is last.
data LaunchMode
  = -- | @--worker@, carrying the spec path it names.
    WorkerMode FilePath
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
launchMode options = case options.optionWorkerSpec of
  Just workerSpec -> WorkerMode workerSpec
  Nothing
    | options.optionGlyphTest -> GlyphTestMode
    | options.optionDoctor -> DoctorMode
    | options.optionUsage -> UsageQueryMode
    | not (null options.optionPing) -> PingQueryMode
    | otherwise -> DashboardMode

-- | Whether this invocation takes the repository's board lease.
--
-- Only the dashboard does. Every other mode either never resolves a repository
-- (a worker is handed its own spec; @--glyph-test@ and @--doctor@ answer from
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
          <> help "Print Codex and Claude usage windows, then exit without starting the dashboard"
      )
    <*> switch
      ( long "fresh"
          <> help "With --usage, probe both providers live instead of reading the cache"
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
versionOption = infoOption "kanban 1.0.0.0" (long "version" <> help "Show version")
