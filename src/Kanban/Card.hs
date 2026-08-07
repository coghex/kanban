-- | Pure, width-aware layout for the §11 card contract.
--
-- Every function here measures terminal cells the way Vty does, so the line
-- lists produced below are exactly the rows the renderer draws. That lets a
-- card size its frame from its own content instead of a fixed constant, and it
-- keeps truncation explicit: an ellipsis appears only where text was dropped,
-- and a label chip is either rendered whole or counted in the @+N@ marker.
module Kanban.Card
  ( CardChip (..),
    boundedLines,
    chipWidth,
    displayWidth,
    elide,
    labelChipRows,
    middleExcerpt,
    overflowChipText,
    wrappedLines,
  )
where

import Data.List (unsnoc)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Graphics.Text.Width as Width

-- | The single-cell marker appended wherever content was dropped.
ellipsis :: Text
ellipsis = "…"

-- | Terminal cells occupied by a string, using Vty's width semantics.
displayWidth :: Text -> Int
displayWidth = Width.safeWctwidth

-- | Wrap to @width@ cells, keeping every word. Words wider than a whole row
-- are split rather than allowed to overrun the card border.
wrappedLines :: Int -> Text -> [Text]
wrappedLines width value
  | width <= 0 = []
  | otherwise = fill [] (filter (not . Text.null) (concatMap (splitWideWord width) (Text.words value)))
  where
    fill current [] = flush current
    fill current (word : rest)
      | null current = fill [word] rest
      | lineWidth current + 1 + displayWidth word <= width = fill (word : current) rest
      | otherwise = flush current <> fill [word] rest
    flush [] = []
    flush current = [Text.unwords (reverse current)]
    lineWidth current = sum (map displayWidth current) + length current - 1

-- | Wrap to @width@ cells and keep at most @maxLines@ rows, ending the final
-- kept row with an ellipsis when later rows were dropped.
boundedLines :: Int -> Int -> Text -> [Text]
boundedLines width maxLines value
  | width <= 0 || maxLines <= 0 = []
  | length allLines <= maxLines = allLines
  | otherwise = case splitAt (maxLines - 1) allLines of
      (kept, final : _) -> kept <> [elide width final]
      (kept, []) -> kept
  where
    allLines = wrappedLines width value

-- | Replace the tail of a line with an ellipsis that still fits @width@.
-- Only called with @width >= 1@, so the ellipsis itself always has room.
elide :: Int -> Text -> Text
elide width value = Text.stripEnd (fst (splitAtWidth (width - 1) value)) <> ellipsis

-- | Bound a line to @limit@ cells by dropping its /middle/ rather than its
-- tail, marking the gap with an ellipsis.
--
-- For diagnostic text whose beginning says what failed and whose end says
-- what to do about it, trimming the tail throws away the only actionable
-- part. Keeping both ends and dropping the restatement between them is what
-- lets a bound stay finite without deciding the reader does not need the
-- remedy.
middleExcerpt :: Int -> Text -> Text
middleExcerpt limit value
  | limit <= 0 = ""
  | displayWidth value <= limit = value
  | limit <= displayWidth ellipsis = ellipsis
  | otherwise = Text.stripEnd headPart <> ellipsis <> Text.stripStart tailPart
  where
    budget = limit - displayWidth ellipsis
    headPart = fst (splitAtWidth (budget - budget `div` 2) value)
    tailPart = takeEndWidth (budget `div` 2) value

-- | The longest suffix fitting @limit@ cells.
takeEndWidth :: Int -> Text -> Text
takeEndWidth limit value = Text.pack (go 0 [] (reverse (Text.unpack value)))
  where
    go _used acc [] = acc
    go used acc (character : rest)
      | used + Width.safeWcwidth character > limit = acc
      | otherwise = go (used + Width.safeWcwidth character) (character : acc) rest

-- | Split at the longest prefix fitting @limit@ cells.
splitAtWidth :: Int -> Text -> (Text, Text)
splitAtWidth limit value = (Text.pack (reverse taken), Text.pack remaining)
  where
    (taken, remaining) = go [] 0 (Text.unpack value)
    go acc _used [] = (acc, [])
    go acc used (character : rest)
      | used + Width.safeWcwidth character > limit = (acc, character : rest)
      | otherwise = go (character : acc) (used + Width.safeWcwidth character) rest

-- | Break a word too wide for a whole row into row-sized pieces. A single
-- character wider than the row can never be shown, so it is dropped to keep
-- the split making progress.
splitWideWord :: Int -> Text -> [Text]
splitWideWord width word
  | displayWidth word <= width = [word]
  | Text.null chunk = splitWideWord width (Text.drop 1 remaining)
  | otherwise = chunk : splitWideWord width remaining
  where
    (chunk, remaining) = splitAtWidth width word

-- | One slot in a card's label rows: a whole label chip, or the marker
-- summarizing every label the card is not showing.
data CardChip
  = LabelChip Text
  | OverflowChip Int
  deriving stock (Eq, Show)

-- | Cells a chip occupies, including the padding its renderer draws.
chipWidth :: CardChip -> Int
chipWidth (LabelChip name) = displayWidth name + 2
chipWidth (OverflowChip count) = displayWidth (overflowChipText count)

overflowChipText :: Int -> Text
overflowChipText count = "+" <> Text.pack (show count)

-- | Pack whole label chips into at most @maxRows@ rows of @width@ cells,
-- separated by a single space.
--
-- A chip is never rendered partially: one that does not fit is left out and
-- counted instead. Whenever anything is left out — locally, or by the
-- @githubOverflow@ count GitHub itself reported — a whole @+N@ marker is
-- placed, evicting trailing chips if that is the only way to make room.
labelChipRows :: Int -> Int -> [Text] -> Int -> [[CardChip]]
labelChipRows width maxRows names githubOverflow
  | width <= 0 || maxRows <= 0 = []
  | otherwise = resolve packed (omitted + max 0 githubOverflow)
  where
    (packed, omitted) = packChips width maxRows (map LabelChip names)
    resolve rows count
      | count <= 0 = rows
      | otherwise = case appendChip width maxRows rows (OverflowChip count) of
          Just marked -> marked
          Nothing -> case dropLastChip rows of
            Just fewer -> resolve fewer (count + 1)
            Nothing -> []

-- | Greedy row packing; returns the rows placed and how many chips were left
-- out, either because the rows ran out or because a chip exceeded a whole row.
packChips :: Int -> Int -> [CardChip] -> ([[CardChip]], Int)
packChips width maxRows = go [] [] 0
  where
    go finished current omitted remaining = case remaining of
      [] -> (reverse (push finished current), omitted)
      chip : rest
        | chipWidth chip > width -> go finished current (omitted + 1) rest
        | fits current chip -> go finished (chip : current) omitted rest
        | length finished + 1 < maxRows -> go (reverse current : finished) [] omitted remaining
        | otherwise -> (reverse (push finished current), omitted + length remaining)
    fits [] _ = True
    fits current chip = rowWidth (reverse current) + 1 + chipWidth chip <= width
    push finished [] = finished
    push finished current = reverse current : finished

-- | Append a chip after the last placed chip, opening a spare row if the
-- current one is full. 'Nothing' when there is no whole-chip room left.
appendChip :: Int -> Int -> [[CardChip]] -> CardChip -> Maybe [[CardChip]]
appendChip width maxRows rows chip = case unsnoc rows of
  Just (initialRows, lastRow)
    | rowWidth lastRow + 1 + chipWidth chip <= width -> Just (initialRows <> [lastRow <> [chip]])
  _
    | length rows < maxRows && chipWidth chip <= width -> Just (rows <> [[chip]])
    | otherwise -> Nothing

-- | Drop the last placed chip so the overflow marker can claim its cells.
dropLastChip :: [[CardChip]] -> Maybe [[CardChip]]
dropLastChip rows = do
  (initialRows, lastRow) <- unsnoc rows
  (kept, _) <- unsnoc lastRow
  pure (if null kept then initialRows else initialRows <> [kept])

rowWidth :: [CardChip] -> Int
rowWidth chips = sum (map chipWidth chips) + max 0 (length chips - 1)
