-- | The @claude@ CLI's stream-json channel, as one pure function over one
-- output line plus the encoder for the input side (D-15).
--
-- Deliberately free of handles, processes, and client state, exactly as
-- "Kanban.Review.Types" is and for the same reason: what one record of this
-- stream /means/ is decided here, and what it does to a review session is
-- decided by the client that holds the connection it arrived on. A decoder
-- that also emitted events could not be exercised without a process.
--
-- The channel is not a request-response protocol. There is no handshake, no
-- request id, and no reply: the client writes user messages, and the CLI
-- streams typed JSON records until a @result@ record closes the turn. The
-- three that carry meaning for a review are the ones this module names —
-- everything else the CLI emits (its hook and status notices, its rate-limit
-- reports, the aggregate @assistant@ message that repeats what the deltas
-- already carried) is recognised and ignored rather than warned about, so a
-- CLI release that adds a record type does not fill the review panel with
-- warnings.
--
-- Ignoring the aggregate @assistant@ record is the one that has to be said
-- out loud: it repeats the whole of the text and thinking the deltas
-- streamed a moment earlier, so a decoder that took both would render every
-- transcript twice.
--
-- Every diagnostic here is the /predicate/ of a sentence whose subject the
-- backend supplies, and is completed by
-- 'Kanban.Review.Diagnostics.reviewSessionDiagnostic'. This module knows the
-- channel and not who is speaking it, so a message that named a brand here
-- would name it in every install, including one where a different provider
-- runs the same channel.
module Kanban.Review.Stream
  ( StreamRecord (..),
    StreamTurnResult (..),
    decodeStreamRecord,
    streamUserMessage,
  )
where

import Data.Aeson
  ( Value (..),
    eitherDecode,
    encode,
    object,
    (.=),
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Kanban.Review.Types (ReviewOutputKind (..), ReviewResult, decodeReviewResult)

-- | What one line of the CLI's output means to a review.
data StreamRecord
  = -- | A turn has opened, carrying the session id every turn on this
    -- process shares and the id of this turn alone.
    --
    -- The CLI re-emits its @system@ \/ @init@ record at the head of every
    -- turn, so this is both how a review's thread first becomes nameable and
    -- how each later turn on the same process announces itself. Which of the
    -- two it is belongs to the client — only it knows whether a review is
    -- still waiting for its thread.
    StreamTurnOpened Text Text
  | -- | One streamed piece of the transcript.
    StreamDelta ReviewOutputKind Text
  | -- | The turn is over, and either produced its structured verdict or did
    -- not.
    StreamTurnClosed StreamTurnResult
  | -- | A record this backend has no use for.
    StreamIgnored
  deriving stock (Eq, Show)

-- | How a turn ended.
--
-- A verdict is only a verdict once it has been decoded: the CLI enforces the
-- schema through a synthetic tool the model is pushed to call, and a turn
-- that ended without calling it, or whose call did not satisfy the schema,
-- has produced no result at all. Making that a failure here rather than an
-- absent verdict at the client is what stops it being reported as a turn
-- that succeeded and said nothing.
data StreamTurnResult
  = -- | The structured verdict, and the JSON it was decoded from.
    StreamVerdict Text ReviewResult
  | StreamTurnFailure Text
  deriving stock (Eq, Show)

-- | One user message, in the shape the CLI's @stream-json@ input format
-- reads. The only thing this client ever writes.
streamUserMessage :: Text -> Value
streamUserMessage message =
  object
    [ "type" .= ("user" :: Text),
      "message"
        .= object
          [ "role" .= ("user" :: Text),
            "content" .= [object ["type" .= ("text" :: Text), "text" .= message]]
          ]
    ]

-- | Read one output line. 'Left' is a line this decoder could not make sense
-- of at all, which the client reports as a protocol warning and reads on
-- from; every line it /can/ make sense of, including the many it has no use
-- for, is a 'Right'.
decodeStreamRecord :: LazyByteString.ByteString -> Either Text StreamRecord
decodeStreamRecord line = case eitherDecode line of
  Left message -> Left ("wrote a line that is not JSON: " <> Text.pack message)
  Right value -> case fieldText "type" value of
    Nothing -> Left "wrote a line naming no record type"
    Just "system" -> systemRecord value
    Just "stream_event" -> streamEventRecord value
    Just "result" -> Right (StreamTurnClosed (resultOutcome value))
    Just _ -> Right StreamIgnored

-- | @system@ records announce the turn's start and then narrate it. Only the
-- @init@ subtype opens a turn; the rest — the hook notices a machine's own
-- configuration produces, the status and token-estimate ticks — say nothing
-- a review session needs.
systemRecord :: Value -> Either Text StreamRecord
systemRecord value = case fieldText "subtype" value of
  Just "init" -> case (fieldText "session_id" value, fieldText "uuid" value) of
    (Just sessionId, Just turnId)
      | not (Text.null sessionId), not (Text.null turnId) -> Right (StreamTurnOpened sessionId turnId)
    _ -> Left "opened a turn without naming its session and its turn"
  _ -> Right StreamIgnored

-- | The transcript. Text becomes the agent's message and thinking becomes its
-- reasoning, which is the same split the app-server's own delta
-- notifications carry. The other deltas a content block produces — the
-- signature closing a thinking block, the partial JSON of the verdict tool's
-- arguments — are machinery rather than transcript.
streamEventRecord :: Value -> Either Text StreamRecord
streamEventRecord value = case objectField "event" value of
  Nothing -> Left "sent a stream event carrying no event"
  Just event
    | fieldText "type" event /= Just "content_block_delta" -> Right StreamIgnored
    | otherwise -> case objectField "delta" event of
        Nothing -> Left "sent a content block delta carrying no delta"
        Just delta -> case fieldText "type" delta of
          Just "text_delta" -> delta `emits` (AgentOutput, "text")
          Just "thinking_delta" -> delta `emits` (ReasoningOutput, "thinking")
          _ -> Right StreamIgnored
  where
    emits delta (outputKind, key) = case fieldText key delta of
      Nothing -> Left ("sent a " <> key <> " delta carrying no " <> key)
      Just text -> Right (StreamDelta outputKind text)

-- | The turn's result line.
--
-- A successful run still has to have produced the verdict: @structured_output@
-- is what the @--json-schema@ launch flag asks for, and a turn that ended
-- without it — because the model never called the synthetic tool, or the CLI
-- stopped it first — completed without reviewing anything.
resultOutcome :: Value -> StreamTurnResult
resultOutcome value
  | fieldText "subtype" value /= Just "success" = StreamTurnFailure failureMessage
  | fieldBool "is_error" value == Just True = StreamTurnFailure failureMessage
  | otherwise = case objectField "structured_output" value of
      Nothing -> StreamTurnFailure "ended its turn without the structured review verdict"
      Just structured ->
        let rendered = TextEncoding.decodeUtf8 (LazyByteString.toStrict (encode structured))
         in case decodeReviewResult rendered of
              Left message -> StreamTurnFailure ("returned a review verdict that does not satisfy the schema: " <> message)
              Right result -> StreamVerdict rendered result
  where
    -- What the CLI says went wrong, preferring its own message over the
    -- subtype that classifies it, and falling back to the subtype when there
    -- is no message to quote.
    failureMessage = case filter (not . Text.null) [reported, classification] of
      message : _ -> message
      [] -> "ended its turn without a result"
    reported = case fieldText "result" value of
      Just message | not (Text.null message) -> "ended its turn with an error: " <> message
      _ -> ""
    classification = case fieldText "subtype" value of
      Just subtype -> "ended its turn with status " <> subtype
      Nothing -> ""

fieldText :: Text -> Value -> Maybe Text
fieldText key value = case objectField key value of
  Just (String text) -> Just text
  _ -> Nothing

fieldBool :: Text -> Value -> Maybe Bool
fieldBool key value = case objectField key value of
  Just (Bool flag) -> Just flag
  _ -> Nothing

objectField :: Text -> Value -> Maybe Value
objectField key (Object value) = KeyMap.lookup (Key.fromText key) value
objectField _ _ = Nothing
