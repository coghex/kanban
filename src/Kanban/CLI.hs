module Kanban.CLI
  ( BorderPolicy (..),
    ColorPolicy (..),
    Options (..),
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
    optionAscii :: Bool,
    optionNoCache :: Bool,
    optionConfig :: Maybe FilePath
  }
  deriving stock (Eq, Show)

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
versionOption = infoOption "kanban 0.1.0.0" (long "version" <> help "Show version")
