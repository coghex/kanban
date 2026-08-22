-- | The entries @docs\/design.md@ §3 and §20 list, read out of the document,
-- and the source-distribution authority a witness's file reads are held
-- against.
--
-- Parsed rather than restated, for the reason "Spec.UI.Keys" parses §7's key
-- table: a second hand-copied inventory of the document would recreate the
-- drift the check exists to catch. The /declaration/ side in
-- "Spec.Design.Witnesses" does restate each entry, and that is the coupling
-- itself — an entry reworded, added, or removed in the document no longer
-- matches its declaration, so its witness has to be re-affirmed against the
-- new wording rather than silently outliving it.
--
-- An entry's identity is its section number together with its complete
-- normalized Markdown list item, continuation lines included. Both sections
-- carry multiline bullets, so a first-line or keyword identity would let two
-- entries collide and would leave a reworded tail uncovered.
module Spec.Design.Entries
  ( -- * The document's entries
    DesignEntry (..),
    designDocumentPath,
    designEntries,
    heldSections,

    -- * What the source distribution excludes
    distributionExclusionsPath,
    excludedDistributionPaths,
    exclusionCovers,
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO

-- | One entry of one held section.
data DesignEntry = DesignEntry
  { designEntrySection :: Int,
    -- | The complete list item, its continuation lines folded in and every
    -- run of whitespace collapsed to one space. The leading @- @ is dropped;
    -- nothing else about the wording is.
    designEntryItem :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | The document, at the path the suite's working directory makes it. Ships
-- in the source distribution as @extra-doc-files@, which is what lets this
-- check run from an unpacked archive as well as from a checkout.
designDocumentPath :: FilePath
designDocumentPath = "docs/design.md"

-- | The two sections held, each by its exact heading line. A heading that
-- moves or is reworded fails the read rather than quietly yielding no
-- entries, so a renumbered section cannot empty the check.
heldSections :: [(Int, Text)]
heldSections =
  [ (3, "## 3. Non-goals"),
    (20, "## 20. Deferred ideas")
  ]

-- | Every entry both held sections list, in document order.
designEntries :: IO [DesignEntry]
designEntries = do
  contents <- TextIO.readFile designDocumentPath
  let documentLines = Text.lines contents
  either fail (pure . concat) (traverse (sectionEntries documentLines) heldSections)

-- | One section's entries: everything between its heading and the next @## @
-- heading. A section that yields nothing is an error rather than an empty
-- list — the mechanism asserting nothing is exactly the failure it exists to
-- prevent.
sectionEntries :: [Text] -> (Int, Text) -> Either String [DesignEntry]
sectionEntries documentLines (number, heading) = case dropWhile (/= heading) documentLines of
  [] ->
    Left
      ( designDocumentPath
          <> " has no line "
          <> show heading
          <> ", so section "
          <> show number
          <> "'s entries could not be read"
      )
  _ : body -> do
    items <- listItems (takeWhile (not . Text.isPrefixOf "## ") body)
    if null items
      then Left (designDocumentPath <> " section " <> show number <> " lists no entries")
      else Right (map (DesignEntry number) items)

-- | The top-level list items of one section's body, normalized.
--
-- A blank line, a new item, or unindented prose ends the item being read; an
-- indented line continues it. A nested list item is refused rather than
-- folded into its parent: neither section has one today, and silently
-- swallowing one would change an entry's identity without anything saying so.
listItems :: [Text] -> Either String [Text]
listItems = go [] []
  where
    go done current [] = Right (reverse (flush done current))
    go done current (line : rest)
      | Just item <- Text.stripPrefix "- " line = go (flush done current) [item] rest
      | Text.null stripped = go (flush done current) [] rest
      | indented, Text.isPrefixOf "- " stripped =
          Left
            ( designDocumentPath
                <> " has a nested list item in a held section ("
                <> Text.unpack stripped
                <> "), which this parser deliberately does not model"
            )
      | indented, not (null current) = go done (current <> [stripped]) rest
      | otherwise = go (flush done current) [] rest
      where
        stripped = Text.strip line
        indented = Text.isPrefixOf " " line

    flush done [] = done
    flush done current = normalize (Text.unwords current) : done

    normalize = Text.unwords . Text.words

-- | The module whose tuple decides what the source distribution leaves out.
-- Ships whole, under the @tools\/**\/*.py@ glob.
distributionExclusionsPath :: FilePath
distributionExclusionsPath = "tools/test_source_distribution.py"

-- | @EXCLUDED_TRACKED_PATHS@, read from that tuple rather than restated here.
--
-- Consulting the real authority is the point: a second copy of the list would
-- go stale exactly when a document's publication lane changed, which is when
-- a witness reading it would start erroring in an unpacked release. The read
-- fails closed — a missing tuple, or an implausibly short one, is an error
-- rather than an empty exclusion set that would let every path through.
excludedDistributionPaths :: IO [Text]
excludedDistributionPaths = do
  contents <- TextIO.readFile distributionExclusionsPath
  case dropWhile (not . Text.isPrefixOf "EXCLUDED_TRACKED_PATHS = (") (Text.lines contents) of
    [] ->
      fail
        ( distributionExclusionsPath
            <> " no longer declares EXCLUDED_TRACKED_PATHS, so no witness's reads can be held against it"
        )
    _ : body -> do
      let entries = concatMap quotedStrings (takeWhile (/= ")") body)
      if length entries < 10
        then
          fail
            ( distributionExclusionsPath
                <> " declared only "
                <> show (length entries)
                <> " excluded paths, which is too few to be that tuple; the parse is broken rather than the tuple"
            )
        else pure entries

-- | Every double-quoted literal on one line of the tuple, ignoring comments.
quotedStrings :: Text -> [Text]
quotedStrings line
  | Text.isPrefixOf "#" (Text.stripStart line) = []
  | otherwise = go line
  where
    go remaining = case Text.breakOn "\"" remaining of
      (_, opened)
        | Text.null opened -> []
        | otherwise -> case Text.breakOn "\"" (Text.drop 1 opened) of
            (_, closed) | Text.null closed -> []
            (value, closed) -> value : go (Text.drop 1 closed)

-- | Whether one @EXCLUDED_TRACKED_PATHS@ entry covers a path, mirroring that
-- module's own @excluded_entry_covers@: an entry ending in @\/@ covers every
-- descendant compared by whole path component, and anything else names one
-- file exactly. Nothing here is a glob or a bare string prefix.
exclusionCovers :: Text -> FilePath -> Bool
exclusionCovers entry path
  | not (Text.isSuffixOf "/" entry) = entry == Text.pack path
  | otherwise = not (null prefix) && take (length prefix) components == prefix
  where
    prefix = components' (Text.dropWhileEnd (== '/') entry)
    components = components' (Text.pack path)
    components' = filter (not . Text.null) . Text.splitOn "/"
