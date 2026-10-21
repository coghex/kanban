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
    optionUsage :: Bool,
    optionFresh :: Bool,
    optionJson :: Bool,
    optionAscii :: Bool,
    optionNoCache :: Bool,
    optionConfig :: Maybe FilePath
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
-- The order is @main@'s: the observational modes answer without needing
-- configuration or a repository, and 'DashboardMode' is what is left, which is
-- why it is last.
data LaunchMode
  = -- | @--glyph-test@.
    GlyphTestMode
  | -- | @--usage@.
    UsageQueryMode
  | -- | The dashboard.
    DashboardMode
  deriving stock (Eq, Show)

launchMode :: Options -> LaunchMode
launchMode options
  | options.optionGlyphTest = GlyphTestMode
  | options.optionUsage = UsageQueryMode
  | otherwise = DashboardMode

-- | Whether this invocation takes the repository's board lease.
--
-- Only the dashboard does. Every other mode either never resolves a repository
-- (@--glyph-test@ answers from the terminal) or resolves one without becoming
-- a board (@--usage@ is global). None of them writes the durable @gh@ record,
-- so none of them has anything to serialise against — and a mode that took
-- the lease would refuse to run beside an open board for no reason at all.
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
    <*> switch (long "ascii" <> help "Use ASCII borders")
    <*> switch (long "no-cache" <> help "Do not read or write snapshots")
    <*> optional
      ( strOption
          ( long "config"
              <> metavar "FILE"
              <> help "Override the global configuration path"
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
