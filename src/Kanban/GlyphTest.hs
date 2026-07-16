module Kanban.GlyphTest
  ( runGlyphTest,
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text

data GlyphSample = GlyphSample
  { sampleCode :: Text,
    sampleGlyph :: Text,
    sampleName :: Text
  }

runGlyphTest :: IO ()
runGlyphTest = do
  Text.putStrLn "Vertical continuity test"
  Text.putStrLn "Look for the thinnest column with no gaps between rows."
  Text.putStrLn ""
  mapM_ renderGroup (chunksOf 6 samples)
  Text.putStrLn "DEC uses the terminal's alternate line-drawing character set."
  Text.putStrLn "BG is a one-cell background-color rail and should be continuous."

renderGroup :: [GlyphSample] -> IO ()
renderGroup group = do
  Text.putStrLn (Text.concat (map (centerText . (.sampleCode)) group))
  mapM_ (const (Text.putStrLn (Text.concat (map (centerGlyph . (.sampleGlyph)) group)))) [1 :: Int .. 10]
  Text.putStrLn (Text.concat (map (centerText . shortName . (.sampleName)) group))
  Text.putStrLn ""

centerText :: Text -> Text
centerText value = centerCell (Text.length value) value

centerGlyph :: Text -> Text
centerGlyph = centerCell 1

centerCell :: Int -> Text -> Text
centerCell visibleWidth value =
  Text.replicate leftPadding " " <> value <> Text.replicate rightPadding " "
  where
    cellWidth = 12
    leftPadding = (cellWidth - visibleWidth) `div` 2
    rightPadding = cellWidth - visibleWidth - leftPadding

shortName :: Text -> Text
shortName = Text.take 11

chunksOf :: Int -> [value] -> [[value]]
chunksOf _ [] = []
chunksOf chunkSize values = take chunkSize values : chunksOf chunkSize (drop chunkSize values)

samples :: [GlyphSample]
samples =
  [ GlyphSample "U+2502" "│" "box light",
    GlyphSample "U+2503" "┃" "box heavy",
    GlyphSample "U+2551" "║" "box double",
    GlyphSample "U+23D0" "⏐" "vertical extension",
    GlyphSample "U+2758" "❘" "light vertical bar",
    GlyphSample "U+FFE8" "￨" "halfwidth vertical",
    GlyphSample "U+258F" "▏" "left one eighth",
    GlyphSample "U+2595" "▕" "right one eighth",
    GlyphSample "U+239C" "⎜" "left parenthesis extension",
    GlyphSample "U+239F" "⎟" "right parenthesis extension",
    GlyphSample "U+23AA" "⎪" "curly bracket extension",
    GlyphSample "DEC" "\ESC(0x\ESC(B" "terminal native",
    GlyphSample "BG" "\ESC[47m \ESC[0m" "background rail"
  ]
