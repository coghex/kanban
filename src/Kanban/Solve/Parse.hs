{-# LANGUAGE DerivingStrategies #-}

-- | Decodes one line of raw provider JSON into the session id it carries (if
-- any) and the 'StreamEvent's it produces, for both the Codex and Claude
-- wire formats. A payload this module cannot recognize falls back to
-- "Kanban.Solve.Unknown"'s bounded notice contract via 'unknownStreamEvent'
-- rather than embedding its raw JSON.
module Kanban.Solve.Parse
  ( parseSolveOutputLine,
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict', encode)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Foldable (toList)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Kanban.Solve.Event (AgentEvent (..), StreamEvent (..), UnknownStreamCategory (..), UnknownStreamKey (..))
import Kanban.Solve.Unknown (elide, maxUnknownNoticeLength, unknownNoticePrefix)
import Kanban.Text (excerpt)

data ParsedSolveOutput = ParsedSolveOutput
  { parsedSessionId :: Maybe Text,
    parsedMessages :: [StreamEvent]
  }
  deriving stock (Eq, Show)

parseSolveOutputLine :: ByteString.ByteString -> Either Text (Maybe Text, [StreamEvent])
parseSolveOutputLine bytes = do
  value <- case eitherDecodeStrict' bytes of
    Left message -> Left (Text.pack message)
    Right decoded -> Right decoded
  let parsed = parseSolveValue value
  pure (parsed.parsedSessionId, parsed.parsedMessages)

parseSolveValue :: Value -> ParsedSolveOutput
parseSolveValue value = case fieldString "type" value of
  Just "thread.started" -> ParsedSolveOutput (fieldText "thread_id" value) []
  Just "system" -> ParsedSolveOutput (fieldText "session_id" value) []
  Just "item.completed" -> ParsedSolveOutput Nothing (maybe [] parseCodexItem (fieldValue "item" value))
  Just "assistant" -> ParsedSolveOutput Nothing (maybe [] parseClaudeMessage (fieldValue "message" value))
  Just "user" -> ParsedSolveOutput Nothing (maybe [] parseClaudeMessage (fieldValue "message" value))
  Just "result" ->
    let resultText = fieldText "result" value
        usage = maybe "" (("usage: " <>) . compactValue) (fieldValue "usage" value)
     in ParsedSolveOutput (fieldText "session_id" value) (maybe [] (\message -> [recognized (agentMessage message usage)]) resultText)
  Just "turn.completed" -> ParsedSolveOutput Nothing (maybe [] (\usage -> [recognized (AgentEvent "usage" "[usage] turn complete" (compactValue usage) Nothing)]) (fieldValue "usage" value))
  Just "error" -> ParsedSolveOutput Nothing [errorOrUnknown UnknownTopLevel value]
  _ -> ParsedSolveOutput Nothing [unknownStreamEvent UnknownTopLevel value]

parseCodexItem :: Value -> [StreamEvent]
parseCodexItem item = case fieldString "type" item of
  Just "agent_message" -> maybe [] (\message -> [recognized (agentMessage message "")]) (fieldText "text" item)
  Just "reasoning" ->
    let reasoning = firstText [fieldValue "summary" item, fieldValue "text" item, fieldValue "content" item]
     in maybe [] (\message -> [recognized (AgentEvent "reasoning" "[reasoning]" message Nothing)]) reasoning
  Just "command_execution" ->
    let command = fromMaybe "" (fieldText "command" item)
        status = maybe "" (" · " <>) (fieldText "status" item)
        output = fromMaybe "" (firstText [fieldValue "aggregated_output" item, fieldValue "output" item])
     in [recognized (AgentEvent "command" ("[command] " <> command <> status) output Nothing) | not (Text.null command)]
  Just "file_change" -> [recognized (AgentEvent "file" "[files] changes applied" (compactValue item) Nothing)]
  Just "mcp_tool_call" -> toolEvent item
  Just "web_search" -> [recognized (AgentEvent "tool" "[web search] " (compactValue item) Nothing)]
  Just "todo_list" -> [recognized (AgentEvent "plan" "[plan] updated" (compactValue item) Nothing)]
  Just "error" -> [errorOrUnknown UnknownCodexItem item]
  _ -> [unknownStreamEvent UnknownCodexItem item]

parseClaudeMessage :: Value -> [StreamEvent]
parseClaudeMessage message = maybe [] (concatMap parseClaudeContent . valueList) (fieldValue "content" message)

parseClaudeContent :: Value -> [StreamEvent]
parseClaudeContent content = case fieldString "type" content of
  Just "text" -> maybe [] (\message -> [recognized (agentMessage message "")]) (fieldText "text" content)
  Just "thinking" -> maybe [] (\message -> [recognized (AgentEvent "reasoning" "[reasoning]" message Nothing)]) (firstText [fieldValue "thinking" content, fieldValue "text" content])
  Just "tool_use" -> toolEvent content
  Just "tool_result" ->
    let result = fromMaybe (compactValue content) (firstText [fieldValue "content" content, fieldValue "result" content])
     in [recognized (AgentEvent "tool-result" "[tool result]" result Nothing)]
  _ -> [unknownStreamEvent UnknownClaudeContent content]

-- | A recognized event, carrying no aggregation identity: it is emitted
-- as-is however often it repeats.
recognized :: AgentEvent -> StreamEvent
recognized = StreamEvent Nothing

-- | A recognized @error@ payload. Its full literal-string @message@ survives
-- verbatim — the one deliberate exemption from the notice bound. A payload
-- whose @message@ is missing, blank, or any non-string JSON is /not/
-- exempt: it degrades to the same bounded, aggregatable notice as any other
-- unrecognized payload instead of embedding its whole raw JSON. The check is
-- deliberately stricter than 'fieldText', which would also coerce an array,
-- object, number, or boolean into a "message".
errorOrUnknown :: UnknownStreamCategory -> Value -> StreamEvent
errorOrUnknown category value = case fieldString "message" value >>= nonEmptyText of
  Just message -> recognized (errorEvent message)
  Nothing -> unknownStreamEvent category value

-- | The bounded one-line notice an unrecognized payload contributes, tagged
-- with the identity repeated occurrences collapse under.
unknownStreamEvent :: UnknownStreamCategory -> Value -> StreamEvent
unknownStreamEvent category value =
  let key = unknownStreamKey category value
   in StreamEvent (Just key) (AgentEvent "event" (unknownNotice key value) "" Nothing)

-- | The aggregation identity of an unrecognized payload. Only a literal JSON
-- string is a usable type; everything else — missing, non-string, or blank
-- once normalized — shares the one stable placeholder key.
unknownStreamKey :: UnknownStreamCategory -> Value -> UnknownStreamKey
unknownStreamKey category value = UnknownStreamKey category usableType
  where
    usableType = case fieldString "type" value of
      Just typeText | not (Text.null (excerpt typeText)) -> Just typeText
      _ -> Nothing

-- | The whole notice for one occurrence: category tag, bounded type label,
-- and a bounded compact rendering of the payload, all on one line and
-- together within 'maxUnknownNoticeLength'. The detail lives in the summary
-- rather than 'agentEventDetail' so even the Full chat rendering — which
-- would otherwise put the detail on its own indented lines — stays one line.
unknownNotice :: UnknownStreamKey -> Value -> Text
unknownNotice key value =
  let prefix = unknownNoticePrefix key
      budget = maxUnknownNoticeLength - Text.length prefix - 1
      detail = if budget <= 0 then "" else elide budget (excerpt (boundedCompactValue budget value))
   in elide maxUnknownNoticeLength (if Text.null detail then prefix else prefix <> " " <> detail)

-- | A compact JSON rendering truncated to at least @limit@ characters
-- without ever materializing the whole encoded value: 'encode' yields a lazy
-- 'LazyByteString.ByteString', so taking a bounded byte prefix forces only
-- the chunks that prefix needs. Four bytes is UTF-8's maximum per character,
-- so the prefix always carries @limit@ characters when the value has them,
-- and 'lenientDecode' absorbs the partial character the cut may leave.
boundedCompactValue :: Int -> Value -> Text
boundedCompactValue limit =
  TextEncoding.decodeUtf8With lenientDecode
    . LazyByteString.toStrict
    . LazyByteString.take (fromIntegral (4 * max 0 limit + 4))
    . encode

toolEvent :: Value -> [StreamEvent]
toolEvent value =
  let name = fromMaybe "tool" (fieldText "name" value <|> fieldText "tool" value)
      inputValue = fieldValue "input" value <|> fieldValue "arguments" value
      input = fromMaybe "" (compactValue <$> inputValue)
      command = inputValue >>= fieldText "command"
      status = maybe "" (" · " <>) (fieldText "status" value)
   in case command of
        Just commandText
          | Text.toCaseFold name `elem` ["bash", "shell"] ->
              [recognized (AgentEvent "command" ("[command] " <> commandText <> status) input Nothing)]
        _ -> [recognized (AgentEvent "tool" ("[tool] " <> name <> status) input Nothing)]

agentMessage :: Text -> Text -> AgentEvent
agentMessage message detail = AgentEvent "message" message detail (Just message)

errorEvent :: Text -> AgentEvent
errorEvent message = AgentEvent "error" ("[error] " <> message) "" (Just message)

fieldValue :: Text -> Value -> Maybe Value
fieldValue key (Object values) = KeyMap.lookup (Key.fromText key) values
fieldValue _ _ = Nothing

fieldText :: Text -> Value -> Maybe Text
fieldText key value = fieldValue key value >>= valueText

-- | The literal JSON string at @key@, with none of 'fieldText' \'s coercion
-- of arrays, objects, numbers, and booleans — the strict reading the
-- unknown-payload contract needs, where "the payload had no textual type" and
-- "the payload had a type-shaped object" must not be confused.
--
-- Every @type@ discriminator reads through this, not 'fieldText'. Coercion
-- there would let a non-string type reach a /recognized/ branch and escape
-- the bound entirely: @{"type":["error"],"message":…}@ would forward an
-- arbitrarily large message, and @{"type":["tool_result"]}@ would fall back
-- to the whole raw payload. A non-string type is an unrecognized payload,
-- and must be bounded as one.
fieldString :: Text -> Value -> Maybe Text
fieldString key value = case fieldValue key value of
  Just (String text) -> Just text
  _ -> Nothing

valueText :: Value -> Maybe Text
valueText (String value) = Just value
valueText (Array values) = nonEmptyText (Text.intercalate "\n" (mapMaybe valueText (toList values)))
valueText (Object values) =
  firstText
    [ KeyMap.lookup "text" values,
      KeyMap.lookup "content" values,
      KeyMap.lookup "output" values,
      KeyMap.lookup "summary" values
    ]
valueText value@(Number _) = Just (compactValue value)
valueText (Bool value) = Just (if value then "true" else "false")
valueText Null = Nothing

firstText :: [Maybe Value] -> Maybe Text
firstText = foldr (\candidate fallback -> (candidate >>= valueText) <|> fallback) Nothing

valueList :: Value -> [Value]
valueList (Array values) = toList values
valueList value = [value]

nonEmptyText :: Text -> Maybe Text
nonEmptyText value | Text.null (Text.strip value) = Nothing
nonEmptyText value = Just value

compactValue :: Value -> Text
compactValue = TextEncoding.decodeUtf8With lenientDecode . LazyByteString.toStrict . encode

(<|>) :: Maybe value -> Maybe value -> Maybe value
Just value <|> _ = Just value
Nothing <|> fallback = fallback
