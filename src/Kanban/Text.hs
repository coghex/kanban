module Kanban.Text
  ( excerpt,
    sanitizeText,
  )
where

import Data.Char (GeneralCategory (..), generalCategory, isControl, isSpace, ord)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Normalize (NormalizationMode (NFC), normalize)

sanitizeText :: Text -> Text
sanitizeText = normalize NFC . Text.filter safeCharacter . stripEscapeSequences . normalizeLineControls

excerpt :: Text -> Text
excerpt = collapseWhitespace . firstParagraph . sanitizeText

normalizeLineControls :: Text -> Text
normalizeLineControls = Text.map replaceTab . normalizeCarriageReturns
  where
    replaceTab '\t' = ' '
    replaceTab character = character

-- CRLF pairs must collapse to a single line break, not two: replacing "\r\n"
-- with "\n" first (before touching lone "\r") keeps a CRLF pair from being
-- read as a paragraph break.
normalizeCarriageReturns :: Text -> Text
normalizeCarriageReturns = Text.replace "\r" "\n" . Text.replace "\r\n" "\n"

safeCharacter :: Char -> Bool
safeCharacter '\n' = True
safeCharacter character =
  not (isControl character)
    && not (isBidiControl character)
    && generalCategory character /= Format

isBidiControl :: Char -> Bool
isBidiControl character =
  ord character `elem`
    [ 0x061C,
      0x200E,
      0x200F,
      0x202A,
      0x202B,
      0x202C,
      0x202D,
      0x202E,
      0x2066,
      0x2067,
      0x2068,
      0x2069
    ]

stripEscapeSequences :: Text -> Text
stripEscapeSequences = Text.pack . goNormal . Text.unpack
  where
    goNormal [] = []
    goNormal ('\ESC' : '[' : rest) = goCsi rest
    goNormal ('\ESC' : ']' : rest) = goOsc rest
    goNormal ('\ESC' : _ : rest) = goNormal rest
    goNormal (character : rest) = character : goNormal rest

    goCsi [] = []
    goCsi (character : rest)
      | character >= '@' && character <= '~' = goNormal rest
      | otherwise = goCsi rest

    goOsc [] = []
    goOsc ('\BEL' : rest) = goNormal rest
    goOsc ('\ESC' : '\\' : rest) = goNormal rest
    goOsc (_ : rest) = goOsc rest

firstParagraph :: Text -> Text
firstParagraph value =
  case filter (not . Text.null) (map Text.strip (Text.splitOn "\n\n" value)) of
    paragraph : _ -> paragraph
    [] -> ""

collapseWhitespace :: Text -> Text
collapseWhitespace = Text.unwords . Text.words . Text.map normalizeSpace
  where
    normalizeSpace character
      | isSpace character = ' '
      | otherwise = character
