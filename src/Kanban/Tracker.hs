module Kanban.Tracker
  ( implementationSortKey,
    membershipSortKey,
    parseTrackerBody,
    parseTrackerChildren,
    renderTrackerDiagnostic,
    trackerDiagnosticsForIssue,
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
    trackerHeadingSeen :: Bool,
    nextChecklistOrder :: Int,
    parsedChildren :: [TrackerChild],
    parseDiagnostics :: [TrackerDiagnostic]
  }

-- | Resolves §12's ordered membership sources for one issue.
--
-- The checklist is authoritative whenever it yields a child, and that test is
-- made on what 'parseTrackerBody' read out of the body -- not on the children
-- that survive later visibility pruning, which can empty a checklist tracker
-- entirely and would otherwise flip it to native membership.
--
-- Only a tracker whose checklist yields nothing falls back to GitHub's native
-- sub-issues, and only a native answer GitHub positively reported as empty
-- lets the existing empty-child-list diagnostics stand: an answer that never
-- arrived is an unverified absence, and one that did arrive is the second
-- source rather than a missing checklist to warn about.
trackerFromIssue :: WorkflowConfig -> Issue -> Maybe Tracker
trackerFromIssue config issue
  | not (isTrackerIssue config issue) = Nothing
  | not (null checklistChildren) = Just (checklistTracker diagnostics)
  | otherwise = Just $ case issue.issueSubIssues of
      SubIssuesReported relationships
        | nativeMembershipPresent relationships -> nativeTracker relationships
        | otherwise -> checklistTracker diagnostics
      SubIssuesUnreported -> checklistTracker (filter (not . isEmptyChildListDiagnostic) diagnostics)
      SubIssuesNotRequested -> checklistTracker diagnostics
  where
    (checklistChildren, diagnostics) = parseTrackerBody config.additionalTrackerSectionHeadings issue.issueBody
    childMap children = Map.fromList [(child.trackerChildIssueNumber, child) | child <- children]
    checklistTracker trackerDiagnostics =
      Tracker
        { trackerIssue = issue,
          trackerSource = ChecklistMembership,
          trackerCompleted = length (filter (.trackerChildComplete) checklistChildren),
          trackerTotal = length checklistChildren,
          trackerChildren = childMap checklistChildren,
          trackerDiagnostics = trackerDiagnostics
        }
    -- Progress is GitHub's own summary rather than a count of the children
    -- below, which is what keeps requirement 6 true when a child is closed or
    -- lives in another repository: such a child is counted once, by GitHub,
    -- and never again here.
    nativeTracker relationships =
      Tracker
        { trackerIssue = issue,
          trackerSource = NativeMembership,
          trackerCompleted = relationships.subIssuesCompleted,
          trackerTotal = relationships.subIssuesTotal,
          trackerChildren = childMap (nativeChildren relationships),
          trackerDiagnostics = filter (not . isEmptyChildListDiagnostic) diagnostics
        }

-- | Whether GitHub reported any native sub-issue relationship at all. A
-- tracker with none has neither §12 source and keeps its ordinary
-- empty-child-list diagnostics; one whose only children are closed or foreign
-- still has native membership, and says so through GitHub's counts instead.
nativeMembershipPresent :: SubIssueRelationships -> Bool
nativeMembershipPresent relationships =
  not (null relationships.subIssuesChildren)
    || relationships.subIssuesOmitted > 0
    || relationships.subIssuesTotal > 0

-- | The children a native tracker can actually render: this repository's own,
-- in the order GitHub returned them.
--
-- Native children carry no implementation key -- inventing one from a title is
-- out of scope -- so their position in GitHub's list becomes the
-- checklist-order fallback 'implementationSortKey' sorts on, and the same
-- positional @step N@ label a keyless checklist child already gets. A child in
-- another repository is dropped before the numbering, because it can never be
-- a card here and is not a step of this repository's list.
nativeChildren :: SubIssueRelationships -> [TrackerChild]
nativeChildren relationships =
  [ TrackerChild
      { trackerChildIssueNumber = link.subIssueNumber,
        trackerChildImplementationKey = Nothing,
        trackerChildChecklistOrder = order,
        trackerChildComplete = link.subIssueClosed
      }
    | (order, link) <- zip [0 ..] (filter ownedHere relationships.subIssuesChildren)
  ]
  where
    ownedHere link = link.subIssueRepository == relationships.subIssuesRepository

-- | The two diagnostics that say a tracker has no child list at all, as
-- opposed to the row-level ones that report malformed checklist content.
-- Native membership and an unverified native answer both suppress these and
-- neither suppresses the others.
isEmptyChildListDiagnostic :: TrackerDiagnostic -> Bool
isEmptyChildListDiagnostic TrackerSectionMissing = True
isEmptyChildListDiagnostic TrackerChildrenMissing = True
isEmptyChildListDiagnostic (TrackerMalformedCheckbox _) = False
isEmptyChildListDiagnostic (TrackerIssueReferenceMissing _) = False
isEmptyChildListDiagnostic (TrackerDuplicateChild _ _) = False

parseTrackerChildren :: [Text] -> Text -> [TrackerChild]
parseTrackerChildren additionalHeadings = fst . parseTrackerBody additionalHeadings

parseTrackerBody :: [Text] -> Text -> ([TrackerChild], [TrackerDiagnostic])
parseTrackerBody additionalHeadings body =
  (reverse finalState.parsedChildren, finalizeDiagnostics finalState)
  where
    initialState = ParseState Nothing False False 0 [] []
    finalState = foldl' (parseLine additionalHeadings) initialState (zip [1 ..] (Text.lines body))
    finalizeDiagnostics state
      | not state.trackerHeadingSeen = [TrackerSectionMissing]
      | null state.parsedChildren = reverse state.parseDiagnostics <> [TrackerChildrenMissing]
      | otherwise = reverse state.parseDiagnostics

parseLine :: [Text] -> ParseState -> (Int, Text) -> ParseState
parseLine additionalHeadings state (lineNumber, rawLine) = case parseHeading rawLine of
  Just (level, heading)
    | isTrackerHeading additionalHeadings heading -> state {activeHeadingLevel = Just level, sectionExcluded = False, trackerHeadingSeen = True}
    | otherwise -> case state.activeHeadingLevel of
        Just activeLevel
          | level <= activeLevel -> state {activeHeadingLevel = Nothing, sectionExcluded = False}
          | otherwise -> state {sectionExcluded = isExcludedSubsection heading}
        Nothing -> state
  Nothing
    | state.activeHeadingLevel == Nothing -> state
    | isPseudoHeading rawLine -> state {sectionExcluded = isExcludedSubsection rawLine}
    | state.sectionExcluded -> state
    | otherwise -> parseChecklist lineNumber state rawLine

parseChecklist :: Int -> ParseState -> Text -> ParseState
parseChecklist lineNumber state line = case stripCheckbox line of
  Nothing
    | looksLikeCheckbox line -> addDiagnostic (TrackerMalformedCheckbox lineNumber) state
    | otherwise -> state
  Just (complete, contents) -> case findIssueNumber contents of
    Nothing -> addDiagnostic (TrackerIssueReferenceMissing lineNumber) state
    Just issueNumber
      | issueNumber `Set.member` existingNumbers -> addDiagnostic (TrackerDuplicateChild lineNumber issueNumber) state
      | otherwise ->
          state
            { nextChecklistOrder = state.nextChecklistOrder + 1,
              parsedChildren =
                TrackerChild
                  { trackerChildIssueNumber = issueNumber,
                    trackerChildImplementationKey = findImplementationKey contents,
                    trackerChildChecklistOrder = state.nextChecklistOrder,
                    trackerChildComplete = complete
                  }
                  : state.parsedChildren
            }
  where
    existingNumbers = Set.fromList (map (.trackerChildIssueNumber) state.parsedChildren)

addDiagnostic :: TrackerDiagnostic -> ParseState -> ParseState
addDiagnostic diagnostic state = state {parseDiagnostics = diagnostic : state.parseDiagnostics}

looksLikeCheckbox :: Text -> Bool
looksLikeCheckbox rawLine = case Text.stripPrefix "-" stripped <|> Text.stripPrefix "*" stripped of
  Just afterBullet -> "[" `Text.isPrefixOf` Text.stripStart afterBullet
  Nothing -> False
  where
    stripped = Text.dropWhile isSpace rawLine

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
findIssueNumber = fmap fst . splitIssueReference

-- The first issue reference in the text, paired with everything following its
-- digits. Splitting rather than only reporting the number lets the key parser
-- anchor on the leading reference instead of scanning the whole item.
splitIssueReference :: Text -> Maybe (Int, Text)
splitIssueReference text = case Text.breakOn "#" text of
  (_, suffix)
    | Text.null suffix -> Nothing
    | otherwise ->
        let afterHash = Text.drop 1 suffix
            (digits, rest) = Text.span isDigit afterHash
         in case parsePositiveInt digits of
              Just number -> Just (number, rest)
              Nothing -> splitIssueReference afterHash

-- docs/design.md section 12 puts the implementation key in one of two fixed
-- positions: immediately after the leading child reference and its separator,
-- or ahead of that reference at the item's start. Scanning every word instead,
-- as this once did, promoted ordinary title words such as "S3" or "V2" -- and
-- the "OS26" fragment of "macOS26" -- to keys, which sorted those children
-- ahead of their keyless siblings and could pick the wrong primary tracker.
findImplementationKey :: Text -> Maybe Text
findImplementationKey contents =
  keyAtStart contents <|> (keyAtStart =<< (afterSeparator . snd =<< splitIssueReference contents))
  where
    -- The separator is part of the position rather than optional spacing, so a
    -- key that merely follows the reference is not in the after-reference one.
    afterSeparator text =
      let (separators, rest) = Text.span isKeySeparator (Text.stripStart text)
       in if Text.null separators then Nothing else Just (Text.stripStart rest)

-- A key is recognized only when it opens the text and is closed by a colon, as
-- in "A1:", "**A1:**", or "_A1:_". Emphasis is skipped on either side of the
-- token so both key-local emphasis and a whole item wrapped in it parse.
keyAtStart :: Text -> Maybe Text
keyAtStart text =
  if ":" `Text.isPrefixOf` Text.dropWhile isEmphasisMarker afterCandidate
    then parseKeyToken candidate
    else Nothing
  where
    start = Text.dropWhile isEmphasisMarker (Text.stripStart text)
    candidate = Text.takeWhile isKeyCharacter start
    afterCandidate = Text.drop (Text.length candidate) start
    isKeyCharacter character = isAsciiUpper character || isDigit character

-- The dash variants ordinary Markdown uses between a reference and its title:
-- ASCII hyphen, en dash, and em dash.
isKeySeparator :: Char -> Bool
isKeySeparator character = character == '-' || character == '–' || character == '—'

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

isTrackerHeading :: [Text] -> Text -> Bool
isTrackerHeading additionalHeadings rawHeading =
  normalized == "children"
    || "children " `Text.isPrefixOf` normalized
    || "children" `elem` Text.words normalized
    || normalized == "phase plan"
    || "phase plan " `Text.isPrefixOf` normalized
    || normalized == "phase"
    || normalized == "phases"
    || "phases " `Text.isPrefixOf` normalized
    || normalized == "phase breakdown"
    || isNumberedPhase rawHeading
    || normalized `elem` map normalizeHeading additionalHeadings
  where
    normalized = normalizeHeading rawHeading

-- Case is checked against the punctuation-stripped heading rather than
-- 'normalized', since case-folding would turn the "Phase A" letter suffix
-- into 'a' before 'isAsciiUpper' ever saw it.
isNumberedPhase :: Text -> Bool
isNumberedPhase rawHeading = case stripPrefixCaseFold "phase " (stripHeadingPunctuation rawHeading) of
  Nothing -> False
  Just suffix -> case Text.uncons suffix of
    Just (character, _) -> isDigit character || isAsciiUpper character
    Nothing -> False

stripPrefixCaseFold :: Text -> Text -> Maybe Text
stripPrefixCaseFold prefix text
  | Text.toCaseFold prefix `Text.isPrefixOf` Text.toCaseFold text = Just (Text.drop (Text.length prefix) text)
  | otherwise = Nothing

stripHeadingPunctuation :: Text -> Text
stripHeadingPunctuation = Text.unwords . Text.words . Text.filter (\character -> character /= ':' && character /= '#')

-- Inside a tracker section, a pseudo-heading is a label line that reads as a
-- sub-heading without being a Markdown one: a whole-line label ending in a
-- colon, or one wholly wrapped in emphasis. Checklist rows and other list items
-- are content rather than labels, and prose that merely opens with an excluded
-- word is not a label either, so neither can change the exclusion state.
isPseudoHeading :: Text -> Bool
isPseudoHeading rawLine =
  not (Text.null trimmed)
    && not (looksLikeCheckbox rawLine)
    && not (isListItem trimmed)
    && (":" `Text.isSuffixOf` trimmed || isEmphasized trimmed)
  where
    trimmed = Text.strip rawLine

isListItem :: Text -> Bool
isListItem trimmed = case Text.uncons trimmed of
  Just (marker, rest) -> isBulletMarker marker && Text.all isSpace (Text.take 1 rest)
  Nothing -> False
  where
    isBulletMarker character = character == '-' || character == '*' || character == '+'

-- Balanced surrounding emphasis, as in "**Related:**", "_Related:_", or
-- "__Remaining__". A colon outside the closing marker ("**Related**:") is
-- already caught by the trailing-colon form.
isEmphasized :: Text -> Bool
isEmphasized trimmed =
  not (Text.null opening)
    && Text.all (== Text.head opening) opening
    && closing == opening
    && not (Text.null inner)
  where
    opening = Text.takeWhile isEmphasisMarker trimmed
    body = Text.drop (Text.length opening) trimmed
    closing = Text.takeWhileEnd isEmphasisMarker body
    inner = Text.dropWhileEnd isEmphasisMarker body

isEmphasisMarker :: Char -> Bool
isEmphasisMarker character = character == '*' || character == '_'

isExcludedSubsection :: Text -> Bool
isExcludedSubsection value =
  any (`Text.isPrefixOf` normalizeHeading value) ["external prerequisite", "related", "out of scope"]

-- Emphasis markers are dropped alongside colons and hashes so a bold or
-- underscored label matches the same excluded prefixes as its plain form.
normalizeHeading :: Text -> Text
normalizeHeading = Text.unwords . Text.words . Text.toCaseFold . Text.filter (not . isHeadingDecoration)
  where
    isHeadingDecoration character = character == ':' || character == '#' || isEmphasisMarker character

hasTrackerLabel :: WorkflowConfig -> [Label] -> Bool
hasTrackerLabel config labels =
  not
    . Set.null
    $ Set.intersection
      (Set.map Text.toCaseFold config.trackerLabels)
      (Set.fromList (map (Text.toCaseFold . (.labelName)) labels))

isTrackerIssue :: WorkflowConfig -> Issue -> Bool
isTrackerIssue config issue =
  hasTrackerLabel config issue.issueLabels
    || (null issue.issueLabels && hasTrackerTitleHint issue.issueTitle)

hasTrackerTitleHint :: Text -> Bool
hasTrackerTitleHint title =
  "epic:" `Text.isPrefixOf` normalized
    || "[epic]" `Text.isPrefixOf` normalized
  where
    normalized = Text.toCaseFold (Text.stripStart title)

-- | The diagnostics every surface outside 'deriveBoard' asks for: the refresh
-- banner's malformed-tracker count, a card's inline rows, the details overlay,
-- and the amber problem styling that decides a card's border.
--
-- It resolves membership through 'trackerFromIssue' rather than re-parsing the
-- body, so all four agree with the header the board drew -- and a tracker whose
-- membership is native is not warned at any of them merely for having no
-- checklist.
trackerDiagnosticsForIssue :: WorkflowConfig -> Issue -> [TrackerDiagnostic]
trackerDiagnosticsForIssue config issue = maybe [] (.trackerDiagnostics) (trackerFromIssue config issue)

renderTrackerDiagnostic :: TrackerDiagnostic -> Text
renderTrackerDiagnostic TrackerSectionMissing = "missing a Children or Phase section"
renderTrackerDiagnostic TrackerChildrenMissing = "tracker section has no valid child issues"
renderTrackerDiagnostic (TrackerMalformedCheckbox lineNumber) = "line " <> showText lineNumber <> ": malformed checklist checkbox"
renderTrackerDiagnostic (TrackerIssueReferenceMissing lineNumber) = "line " <> showText lineNumber <> ": checklist item has no issue reference"
renderTrackerDiagnostic (TrackerDuplicateChild lineNumber issueNumber) =
  "line " <> showText lineNumber <> ": duplicate child #" <> showText issueNumber

showText :: Show value => value -> Text
showText = Text.pack . show

(<|>) :: Maybe value -> Maybe value -> Maybe value
Just value <|> _ = Just value
Nothing <|> other = other
