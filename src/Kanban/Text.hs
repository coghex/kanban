module Kanban.Text
  ( excerpt,
    oneLineText,
    sanitizeText,
    withoutJsonPath,
  )
where

import Data.Char (GeneralCategory (..), generalCategory, isControl, isSpace, ord)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Normalize (NormalizationMode (NFC), normalize)

sanitizeText :: Text -> Text
sanitizeText = normalize NFC . Text.filter safeCharacter . stripEscapeSequences . normalizeLineControls

-- | A card's body excerpt: the first paragraph that is content rather than
-- structure (see 'firstParagraph'), collapsed onto one line.
--
-- This reads its input as the Markdown a body is, so it belongs to bodies
-- alone. A caller that has some other external string to put on one line --
-- a provider's event type, a rendered JSON payload -- wants 'oneLineText',
-- which normalizes without deciding that any of it is structure.
excerpt :: Text -> Text
excerpt = collapseWhitespace . firstParagraph . sanitizeText

-- | External text made safe to draw on one line: sanitized, with every run of
-- whitespace collapsed to a single space and the edges trimmed.
--
-- Nothing here is Markdown-aware. A string this returns empty for held no
-- printable character to begin with, which is what lets a caller use it as a
-- blankness test over text it did not write.
oneLineText :: Text -> Text
oneLineText = collapseWhitespace . sanitizeText

-- | Drops the JSONPath Aeson prefixes a parse failure with (@Error in $: @),
-- which is noise inside a sentence already naming the one document it is
-- about, and costs sidebar width the remediation needs. Shared by the two
-- installer-written discovery records — the PR drainer's and the canonical
-- issue reviewer's — so their diagnostics read the same way.
withoutJsonPath :: Text -> Text
withoutJsonPath message = case Text.stripPrefix "Error in " message of
  Just located
    | (_, remainder) <- Text.breakOn ": " located,
      not (Text.null remainder) ->
        Text.drop 2 remainder
  _ -> message

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

-- | The first paragraph of a sanitized body that is content rather than the
-- structure the body opens with (@docs\/design.md@ §11).
--
-- Every issue filed here follows a template whose body opens with an
-- instructional HTML comment and then @## Background@, and an agent-filed one
-- opens with its origin marker, so the blank-line-delimited block this used to
-- take was the same heading or marker on card after card. Leading ATX headings
-- and leading HTML comments are skipped and the search resumes at whatever
-- follows them; a body that is nothing but those excerpts to the empty text,
-- which draws no excerpt line at all rather than a heading.
--
-- Skipping is deliberately confined to what /opens/ the body. Once a line is
-- neither heading nor comment the paragraph has begun, and everything in it is
-- taken as it stands -- a list, a fenced code block, and the heading- and
-- comment-shaped lines a fence may hold are content, not structure.
firstParagraph :: Text -> Text
firstParagraph value
  | Text.null body = ""
  | Just remainder <- afterLeadingComment body = firstParagraph remainder
  | Just remainder <- afterLeadingHeading body = firstParagraph remainder
  | otherwise = Text.strip (fst (Text.breakOn "\n\n" body))
  where
    body = dropBlankLines value

-- | The body with its leading blank lines dropped, keeping the indentation of
-- the first line that holds anything.
--
-- A line holding only whitespace decides nothing, so it is passed over without
-- being offered to either test below or taken as the start of a paragraph.
dropBlankLines :: Text -> Text
dropBlankLines value
  | not (Text.all isSpace line) = value
  | otherwise = maybe "" dropBlankLines (Text.stripPrefix "\n" remainder)
  where
    (line, remainder) = Text.breakOn "\n" value

-- | The body after an ATX heading opening it, or 'Nothing' when it opens with
-- something else.
--
-- A heading is one to six @#@ characters closed by whitespace or by the end of
-- the line. Both halves of that are load-bearing: @#123 context@ is a
-- cross-reference and @####### context@ is seven hashes, and neither is a
-- heading, so both stay content.
afterLeadingHeading :: Text -> Maybe Text
afterLeadingHeading body = do
  afterIndent <- withinStructureIndent body
  let (hashes, rest) = Text.span (== '#') afterIndent
  if opensHeading hashes rest then Just afterLine else Nothing
  where
    -- 'rest' runs to the end of the body rather than the end of the line, so
    -- its first character is the line's own terminator when the heading has no
    -- text: a newline is whitespace, and an empty 'rest' is the last line.
    opensHeading hashes rest =
      not (Text.null hashes)
        && Text.length hashes <= 6
        && (Text.null rest || isSpace (Text.head rest))
    afterLine = Text.drop 1 (Text.dropWhile (/= '\n') body)

-- | The body after an HTML comment opening it, or 'Nothing' when it opens with
-- something else.
--
-- The comment is consumed through its closing @-->@ however many lines and
-- blank lines it spans, because the issue template's instructional comment
-- holds one of each; anything left on the marker's own line resumes the search
-- where it ends. A comment that never closes consumes the rest of the body,
-- which is the fail-closed answer: the alternative prints markup its author
-- wrote to be invisible.
afterLeadingComment :: Text -> Maybe Text
afterLeadingComment body = do
  afterIndent <- withinStructureIndent body
  opened <- Text.stripPrefix "<!--" afterIndent
  let (_, closing) = Text.breakOn "-->" opened
  Just (if Text.null closing then "" else Text.drop 3 closing)

-- | The body past indentation shallow enough to still open structure, shared
-- by both tests above.
--
-- CommonMark allows up to three spaces before an ATX heading or an HTML block
-- and makes a fourth the start of an indented code block. Code is content, so
-- this stops at three rather than stripping whatever indentation is there.
withinStructureIndent :: Text -> Maybe Text
withinStructureIndent value
  | Text.length spaces <= 3 = Just rest
  | otherwise = Nothing
  where
    (spaces, rest) = Text.span (== ' ') value

collapseWhitespace :: Text -> Text
collapseWhitespace = Text.unwords . Text.words . Text.map normalizeSpace
  where
    normalizeSpace character
      | isSpace character = ' '
      | otherwise = character
