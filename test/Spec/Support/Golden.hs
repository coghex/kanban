-- | Checked-in frames: where they live, how a mismatch is reported, and the
-- one explicit switch that rewrites them.
--
-- Regeneration is deliberately not a fallback. A golden that rewrites itself
-- whenever it disagrees records nothing, so an ordinary @cabal test@ run only
-- ever reads: the frames are rewritten when — and only when —
-- 'goldenUpdateVariable' is set in the environment.
module Spec.Support.Golden
  ( goldenPath,
    expectGolden,
    attributeGrid
  )
where

import Control.Monad (unless)
import qualified Data.ByteString as ByteString
import Data.Bits ((.&.))
import Data.List (findIndex)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word8)
import qualified Graphics.Vty.Attributes as Vty
import Spec.Support.Render (FrameCell (..))
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import Test.Hspec (Expectation, expectationFailure)

-- | Golden frames are read relative to the package root, which is where
-- @cabal test@ starts the suite.
goldenPath :: FilePath -> FilePath
goldenPath name = "test" </> "golden" </> name

-- | Set this — to anything non-empty — to rewrite every golden frame the
-- suite renders instead of comparing against them.
goldenUpdateVariable :: String
goldenUpdateVariable = "KANBAN_UPDATE_GOLDENS"

regenerationHint :: String
regenerationHint =
  "regenerate the checked-in frames with:\n"
    <> "  "
    <> goldenUpdateVariable
    <> "=1 cabal test kanban-test\n"
    <> "then read the resulting diff before committing it."

-- | Compare @rendered@ with the golden frame at @path@, or rewrite that file
-- when 'goldenUpdateVariable' is set.
expectGolden :: FilePath -> [Text] -> Expectation
expectGolden path rendered = do
  requested <- lookupEnv goldenUpdateVariable
  case requested of
    Just value | not (null value) -> do
      createDirectoryIfMissing True (takeDirectory path)
      ByteString.writeFile path (TextEncoding.encodeUtf8 (Data.Text.unlines rendered))
    _ -> do
      present <- doesFileExist path
      if not present
        then
          expectationFailure $
            "no golden frame at "
              <> path
              <> " (a relative path, so the suite has to run from the package root, which is where cabal test starts it)\n"
              <> regenerationHint
        else do
          golden <- Data.Text.lines . TextEncoding.decodeUtf8With lenientDecode <$> ByteString.readFile path
          unless (golden == rendered) (expectationFailure (goldenDiff path golden rendered))

-- | A mismatch as a line-oriented diff: which file disagreed, how the two
-- differ in size, and the differing rows themselves with the column the
-- difference starts at, so a border or budget regression can be read off the
-- failure rather than reproduced by hand.
goldenDiff :: FilePath -> [Text] -> [Text] -> String
goldenDiff path golden rendered =
  unlines $
    [ "golden frame mismatch: " <> path,
      "  golden " <> show (length golden) <> " row(s), rendered " <> show (length rendered) <> " row(s), " <> show (length differing) <> " row(s) differ"
    ]
      <> concatMap describeRow (take shownRows differing)
      <> ["  (" <> show (length differing - shownRows) <> " further differing row(s) suppressed)" | length differing > shownRows]
      <> [regenerationHint]
  where
    shownRows = 12
    height = max (length golden) (length rendered)
    row rows index = if index < length rows then Just (rows !! index) else Nothing
    differing = [(index, row golden index, row rendered index) | index <- [0 .. height - 1], row golden index /= row rendered index]
    describeRow (index, goldenRow, renderedRow) =
      [ "  row " <> show (index + 1) <> firstDifference goldenRow renderedRow,
        "    golden   |" <> maybe "<missing>" Data.Text.unpack goldenRow,
        "    rendered |" <> maybe "<missing>" Data.Text.unpack renderedRow
      ]
    firstDifference (Just goldenRow) (Just renderedRow) =
      case findIndex id (zipWith (/=) (Data.Text.unpack goldenRow) (Data.Text.unpack renderedRow)) of
        Just column -> " (first difference at column " <> show (column + 1) <> ")"
        Nothing -> " (rows differ in length)"
    firstDifference _ _ = ""

-- | A frame's attributes as a reviewable grid: one token per cell over a
-- legend naming every attribute the frame used, in the order it first used
-- it. Glyphs the character golden cannot tell apart -- the selected card's
-- left and right edges are the same @\'│\'@ -- differ here.
attributeGrid :: [[FrameCell]] -> [Text]
attributeGrid rows =
  ["# " <> Data.Text.singleton assigned <> "  " <> description | (description, assigned) <- legend]
    <> ["#"]
    <> [Data.Text.pack [tokenFor cell | cell <- row] | row <- rows]
  where
    legend = reverse (foldl assign [] [describeAttribute (frameCellAttribute cell) | row <- rows, cell <- row])
    assign seen description
      | description `elem` map fst seen = seen
      | description == defaultDescription = (description, defaultToken) : seen
      | otherwise = (description, token (length (filter ((/= defaultToken) . snd) seen))) : seen
    token index = case drop index tokenAlphabet of
      character : _ -> character
      [] -> error ("a frame used more than " <> show (length tokenAlphabet) <> " non-default attributes")
    tokens = Map.fromList legend
    tokenFor cell = fromMaybe '?' (Map.lookup (describeAttribute (frameCellAttribute cell)) tokens)

defaultDescription :: Text
defaultDescription = describeAttribute Vty.defAttr

-- | The default attribute always takes @.@, so the untouched parts of a frame
-- stay legible; everything else is assigned in first-appearance order.
defaultToken :: Char
defaultToken = '.'

tokenAlphabet :: [Char]
tokenAlphabet = ['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9']

describeAttribute :: Vty.Attr -> Text
describeAttribute attribute =
  "fore=" <> describeColor attribute.attrForeColor
    <> " back="
    <> describeColor attribute.attrBackColor
    <> " style="
    <> describeStyle attribute.attrStyle
    <> case attribute.attrURL of
      Vty.SetTo url -> " url=" <> url
      _ -> ""

describeColor :: Vty.MaybeDefault Vty.Color -> Text
describeColor Vty.Default = "default"
describeColor Vty.KeepCurrent = "keep"
describeColor (Vty.SetTo color) = colorName color

colorName :: Vty.Color -> Text
colorName (Vty.ISOColor index) = fromMaybe ("iso" <> Data.Text.pack (show index)) (lookup index isoColorNames)
colorName (Vty.Color240 index) = "color240:" <> Data.Text.pack (show index)
colorName (Vty.RGBColor red green blue) =
  "rgb:" <> Data.Text.intercalate "," (map (Data.Text.pack . show) [red, green, blue])

isoColorNames :: [(Word8, Text)]
isoColorNames =
  zip
    [0 ..]
    [ "black",
      "red",
      "green",
      "yellow",
      "blue",
      "magenta",
      "cyan",
      "white",
      "brightBlack",
      "brightRed",
      "brightGreen",
      "brightYellow",
      "brightBlue",
      "brightMagenta",
      "brightCyan",
      "brightWhite"
    ]

describeStyle :: Vty.MaybeDefault Vty.Style -> Text
describeStyle Vty.Default = "default"
describeStyle Vty.KeepCurrent = "keep"
describeStyle (Vty.SetTo style)
  | null named = "none"
  | otherwise = Data.Text.intercalate "+" named
  where
    named = [name | (bit, name) <- styleNames, style .&. bit /= 0]

styleNames :: [(Vty.Style, Text)]
styleNames =
  [ (Vty.standout, "standout"),
    (Vty.underline, "underline"),
    (Vty.reverseVideo, "reverseVideo"),
    (Vty.blink, "blink"),
    (Vty.dim, "dim"),
    (Vty.bold, "bold"),
    (Vty.italic, "italic"),
    (Vty.strikethrough, "strikethrough")
  ]
