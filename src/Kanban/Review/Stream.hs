-- | The @claude@ CLI's stream-json channel, as one pure function over one
-- output line plus the encoder for the input side (D-15).
--
-- Deliberately free of handles, processes, and client state, exactly as
-- "Kanban.Review.Types" is and for the same reason: what one record of this
-- stream /means/ is decided here, and what it does to a review session is
-- decided by the client that holds the connection it arrived on. A decoder
-- that also emitted events could not be exercised without a process.
--
-- The conversation itself is not a request-response protocol. There is no
-- handshake and no reply: the client writes user messages, and the CLI
-- streams typed JSON records until a @result@ record closes the turn.
-- Alongside it runs one narrow exchange that /is/ correlated — a
-- @control_request@ and the @control_response@ answering it by request id —
-- and interrupting a turn is the only thing this backend uses it for (D-16).
-- The five records that carry meaning for a review are the ones this module
-- names, two of them that exchange's — an answer that cannot be read still
-- settles what was waiting on it, so it is reported rather than refused.
-- Everything else the CLI emits (its hook and status notices, its rate-limit
-- reports, the aggregate @assistant@ message that repeats what the deltas
-- already carried, and the control requests it sends /this/ client) is
-- recognised and ignored rather than warned about, so a CLI release that adds
-- a record type does not fill the review panel with warnings.
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
    streamInterruptRequest,
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
  | -- | The CLI's answer to one @control_request@ this client wrote, named by
    -- the @request_id@ that request carried and saying whether the operation
    -- was performed.
    --
    -- Only the answer is decoded here. Which operation it settles, and what
    -- that settlement releases, is the client's — this module has no memory
    -- of what was asked.
    StreamControlAnswered Text (Either Text ())
  | -- | An answer to a control request that named no request, or carried
    -- nothing to read an outcome from.
    --
    -- A record rather than the 'Left' every other unreadable line is,
    -- because this one has a consequence beyond the warning it deserves: an
    -- operation is waiting on an answer, and a line that says only that one
    -- arrived and could not be read is the CLI's last word on it. Reported
    -- as its own thing so the client can settle what was waiting instead of
    -- leaving it to wait for an answer that has already been and gone.
    StreamControlUnreadable Text
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
  | -- | The turn was cut short rather than ending on its own, which on this
    -- channel is what an accepted interrupt does to it.
    --
    -- Read off the CLI's own account of the turn rather than off the
    -- client's memory of having asked for one, because the two are not the
    -- same claim: an interrupt written a moment after a turn finished is
    -- still acknowledged as a success, and a turn nothing here interrupted
    -- can still be aborted from outside. What ended the turn is the result
    -- record's to say.
    StreamTurnAborted
  | StreamTurnFailure Text
  deriving stock (Eq, Show)

-- | The one control request this backend sends: cancel whatever turn is
-- running, named by an id its answer comes back under.
--
-- The id is the caller's to choose and the caller's to match, because the
-- channel guarantees nothing about ordering between this exchange and the
-- turn it targets — the answer may arrive before or after the result record
-- of the turn it ended.
streamInterruptRequest :: Text -> Value
streamInterruptRequest requestId =
  object
    [ "type" .= ("control_request" :: Text),
      "request_id" .= requestId,
      "request" .= object ["subtype" .= ("interrupt" :: Text)]
    ]

-- | One user message, in the shape the CLI's @stream-json@ input format
-- reads. The turns this client opens are written as these and nothing else.
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
    Just "control_response" -> Right (controlResponse value)
    Just _ -> Right StreamIgnored

-- | The CLI's answer to a control request, which nests its own subtype,
-- the @request_id@ it is answering, and — on the failing branch — what went
-- wrong, under a @response@ object.
--
-- Fails closed twice over. A subtype this decoder does not know is not
-- agreement: an operation is only performed when the CLI says @success@, and
-- reading anything else as agreement is how a message would be released into
-- a turn that is still running. And an answer it cannot read at all is
-- 'StreamControlUnreadable' rather than a bare refusal to decode, because
-- the operation waiting on that answer has to hear about it.
controlResponse :: Value -> StreamRecord
controlResponse value = case objectField "response" value of
  Nothing -> StreamControlUnreadable "answered a control request with no response"
  Just response -> case fieldText "request_id" response of
    Nothing -> StreamControlUnreadable "answered a control request without naming which one"
    Just requestId -> StreamControlAnswered requestId (outcome response)
  where
    outcome response = case fieldText "subtype" response of
      Just "success" -> Right ()
      subtype -> Left (classify subtype <> reported response)
    classify (Just "error") = "refused it"
    classify (Just subtype) = "answered it with status " <> subtype
    classify Nothing = "answered it without saying whether it was performed"
    reported response = case fieldText "error" response of
      Just detail | not (Text.null detail) -> ": " <> detail
      _ -> ""

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
--
-- A turn the CLI cut short is told apart from one that failed on its own by
-- @terminal_reason@, which every result line carries: @completed@ closes a
-- turn that ran to its end, and @aborted_streaming@ one that was stopped
-- mid-stream. Checked ahead of everything else, because such a turn also
-- reports @is_error@ and an error subtype and would otherwise be
-- indistinguishable from a turn that broke.
resultOutcome :: Value -> StreamTurnResult
resultOutcome value
  | fieldText "terminal_reason" value == Just "aborted_streaming" = StreamTurnAborted
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
