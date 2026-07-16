module Kanban.Tracker
  ( implementationSortKey,
    membershipSortKey,
    parseTrackerChildren,
    trackerFromIssue,
  )
where

import Data.Char (isAsciiUpper, isDigit, isSpace)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain

data ParseState = ParseState
  { activeHeadingLevel :: Maybe Int,
    sectionExcluded :: Bool,
    nextChecklistOrder :: Int,
    parsedChildren :: [TrackerChild]
  }

trackerFromIssue :: WorkflowConfig -> Issue -> Maybe Tracker
trackerFromIssue config issue
  | not (hasTrackerLabel config issue.issueLabels) = Nothing
  | otherwise =
      let children = parseTrackerChildren issue.issueBody
          childMap = Map.fromList [(child.trackerChildIssueNumber, child) | child <- children]
       in Just
            Tracker
              { trackerIssue = issue,
                trackerCompleted = length (filter (.trackerChildComplete) children),
                trackerTotal = length children,
                trackerChildren = childMap
              }

parseTrackerChildren :: Text -> [TrackerChild]
parseTrackerChildren body =
  reverse . (.parsedChildren) $ foldl' parseLine initialState (Text.lines body)
  where
    initialState = ParseState Nothing False 0 []

parseLine :: ParseState -> Text -> ParseState
parseLine state rawLine = case parseHeading rawLine of
  Just (level, heading)
    | isTrackerHeading heading -> state {activeHeadingLevel = Just level, sectionExcluded = False}
    | otherwise -> case state.activeHeadingLevel of
        Just activeLevel
          | level <= activeLevel -> state {activeHeadingLevel = Nothing, sectionExcluded = False}
          | otherwise -> state {sectionExcluded = isExcludedSubsection heading}
        Nothing -> state
  Nothing
    | isExcludedSubsection rawLine && state.activeHeadingLevel /= Nothing -> state {sectionExcluded = True}
    | state.activeHeadingLevel /= Nothing && not state.sectionExcluded -> parseChecklist state rawLine
    | otherwise -> state

parseChecklist :: ParseState -> Text -> ParseState
parseChecklist state line = case parseChecklistItem state.nextChecklistOrder line of
  Nothing -> state
  Just child
    | child.trackerChildIssueNumber `Set.member` existingNumbers -> state
    | otherwise ->
        state
          { nextChecklistOrder = state.nextChecklistOrder + 1,
            parsedChildren = child : state.parsedChildren
          }
  where
    existingNumbers = Set.fromList (map (.trackerChildIssueNumber) state.parsedChildren)

parseChecklistItem :: Int -> Text -> Maybe TrackerChild
parseChecklistItem order line = do
  (complete, contents) <- stripCheckbox line
  issueNumber <- findIssueNumber contents
  pure
    TrackerChild
      { trackerChildIssueNumber = issueNumber,
        trackerChildImplementationKey = findImplementationKey contents,
        trackerChildChecklistOrder = order,
        trackerChildComplete = complete
      }

stripCheckbox :: Text -> Maybe (Bool, Text)
stripCheckbox rawLine = do
  afterBullet <- Text.stripPrefix "-" stripped <|> Text.stripPrefix "*" stripped
  let checkbox = Text.stripStart afterBullet
  status <- Text.uncons =<< Text.stripPrefix "[" checkbox
  let (mark, afterMark) = status
  afterClose <- Text.stripPrefix "]" afterMark
  complete <- case mark of
    ' ' -> Just False
    'x' -> Just True
    'X' -> Just True
    _ -> Nothing
  pure (complete, Text.stripStart afterClose)
  where
    stripped = Text.dropWhile isSpace rawLine

findIssueNumber :: Text -> Maybe Int
findIssueNumber text = case Text.breakOn "#" text of
  (_, suffix)
    | Text.null suffix -> Nothing
    | otherwise ->
        let digits = Text.takeWhile isDigit (Text.drop 1 suffix)
         in parsePositiveInt digits <|> findIssueNumber (Text.drop 1 suffix)

findImplementationKey :: Text -> Maybe Text
findImplementationKey = firstJust . map parseKeyToken . Text.words . Text.map normalizeKeyCharacter
  where
    normalizeKeyCharacter character
      | isAsciiUpper character || isDigit character = character
      | otherwise = ' '

parseKeyToken :: Text -> Maybe Text
parseKeyToken token =
  let (letters, digits) = Text.span isAsciiUpper token
   in if Text.null letters || Text.length letters > 2 || Text.null digits || not (Text.all isDigit digits)
        then Nothing
        else token <$ parsePositiveInt digits

implementationSortKey :: TrackerChild -> (Int, Text, Int, Int)
implementationSortKey child = case child.trackerChildImplementationKey >>= splitKey of
  Just (letters, number) -> (0, letters, number, child.trackerChildChecklistOrder)
  Nothing -> (1, "", 0, child.trackerChildChecklistOrder)

membershipSortKey :: TrackerMembership -> (Int, Text, Int, Int, Int, Int)
membershipSortKey membership =
  let child = membership.membershipChild
      (kind, letters, number, order) = implementationSortKey child
   in (kind, letters, number, membership.membershipTracker.trackerIssue.issueNumber, child.trackerChildIssueNumber, order)

splitKey :: Text -> Maybe (Text, Int)
splitKey key = do
  let (letters, digits) = Text.span isAsciiUpper key
  number <- parsePositiveInt digits
  pure (letters, number)

parsePositiveInt :: Text -> Maybe Int
parsePositiveInt value = case reads (Text.unpack value) of
  [(number, "")]
    | number > 0 -> Just number
  _ -> Nothing

parseHeading :: Text -> Maybe (Int, Text)
parseHeading rawLine =
  let stripped = Text.stripStart rawLine
      hashes = Text.takeWhile (== '#') stripped
      heading = Text.strip (Text.drop (Text.length hashes) stripped)
   in if Text.null hashes || Text.null heading
        then Nothing
        else Just (Text.length hashes, heading)

isTrackerHeading :: Text -> Bool
isTrackerHeading rawHeading =
  normalized == "children"
    || "children " `Text.isPrefixOf` normalized
    || normalized == "phase plan"
    || "phase plan " `Text.isPrefixOf` normalized
    || isNumberedPhase normalized
  where
    normalized = normalizeHeading rawHeading

isNumberedPhase :: Text -> Bool
isNumberedPhase heading = case Text.stripPrefix "phase " heading of
  Nothing -> False
  Just suffix -> case Text.uncons suffix of
    Just (character, _) -> isDigit character || isAsciiUpper character
    Nothing -> False

isExcludedSubsection :: Text -> Bool
isExcludedSubsection value =
  any (`Text.isPrefixOf` normalizeHeading value) ["external prerequisite", "related", "out of scope"]

normalizeHeading :: Text -> Text
normalizeHeading = Text.unwords . Text.words . Text.toCaseFold . Text.filter (\character -> character /= ':' && character /= '#')

hasTrackerLabel :: WorkflowConfig -> [Label] -> Bool
hasTrackerLabel config labels =
  not
    . Set.null
    $ Set.intersection
      (Set.map Text.toCaseFold config.trackerLabels)
      (Set.fromList (map (Text.toCaseFold . (.labelName)) labels))

firstJust :: [Maybe value] -> Maybe value
firstJust = caseMap
  where
    caseMap [] = Nothing
    caseMap (Just value : _) = Just value
    caseMap (Nothing : rest) = caseMap rest

(<|>) :: Maybe value -> Maybe value -> Maybe value
Just value <|> _ = Just value
Nothing <|> other = other
