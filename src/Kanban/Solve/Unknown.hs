-- | The bounded, aggregated accounting of unrecognized provider payloads: an
-- invocation-scoped counter that admits a key's first few occurrences and
-- collapses the rest into one summary, plus the shared notice-formatting
-- primitives both the per-occurrence notice ("Kanban.Solve.Parse") and this
-- module's own aggregate summary render through. Separated from
-- "Kanban.Solve.Parse" because everything here is free of the provider JSON
-- 'Data.Aeson.Value' shape: it only ever sees an 'UnknownStreamKey' already
-- computed by the parser.
module Kanban.Solve.Unknown
  ( UnknownAggregator,
    elide,
    emitStreamEvent,
    maxUnknownNoticeLength,
    maxUnknownTypeLength,
    newUnknownAggregator,
    sealUnknownAggregates,
    unknownNoticePrefix,
    unknownNoticeSamples,
  )
where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Monad (when)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Solve.Event (AgentEvent (..), StreamEvent (..), UnknownStreamCategory (..), UnknownStreamKey (..))
import Kanban.Text (excerpt)

-- | The deterministic ceiling on an entire unknown-payload notice — category
-- tag, type label, separator, and bounded detail together, not just the
-- detail. A provider that starts emitting a chatty unrecognized event type
-- therefore costs a fixed number of characters per occurrence in the worker
-- journal and replayed transcript instead of its whole payload.
maxUnknownNoticeLength :: Int
maxUnknownNoticeLength = 200

-- | The short fixed width an unknown payload's type label is normalized and
-- truncated to before the detail is appended, so a pathological type string
-- cannot by itself consume the whole notice budget.
maxUnknownTypeLength :: Int
maxUnknownTypeLength = 48

-- | How many occurrences of one unknown key are reported individually before
-- the remainder only accumulate a count, redeemed as a single aggregate
-- summary when the invocation ends. Keeping a few samples preserves the
-- payload variation worth seeing; suppressing the rest is what makes a
-- chatty type cost O(1) per invocation instead of O(n).
unknownNoticeSamples :: Int
unknownNoticeSamples = 3

-- | The stable label a payload with no usable @type@ is reported and
-- aggregated under, so such payloads still produce a deterministic bounded
-- notice rather than being dropped or falling back to their raw JSON.
unknownTypePlaceholder :: Text
unknownTypePlaceholder = "unknown"

-- | Invocation-local aggregation state. Its lifetime is exactly one provider
-- invocation and its worker journal: nothing is carried across a resume, and
-- no entry is ever rewritten, which is what keeps this compatible with the
-- append-only journal.
data UnknownAggregator = UnknownAggregator (MVar ()) (IORef UnknownTally)

-- | An aggregator's counts plus whether it has been sealed.
data UnknownTally = UnknownTally
  { unknownTallyCounts :: Map UnknownStreamKey Int,
    unknownTallySealed :: Bool
  }

newUnknownAggregator :: IO UnknownAggregator
newUnknownAggregator = UnknownAggregator <$> newMVar () <*> newIORef (UnknownTally Map.empty False)

-- | Passes one parsed event to @emitEvent@, or withholds it. Recognized
-- events always go straight through, sealed or not. An unknown notice is
-- emitted for its key's first 'unknownNoticeSamples' occurrences and
-- withheld afterwards, its count accumulating for 'sealUnknownAggregates'.
--
-- Deciding /and emitting/ happen under the aggregator's lock, which
-- 'sealUnknownAggregates' also takes, because the two halves cannot be
-- allowed to straddle a seal. Were emission left to the caller, a stream
-- thread could be descheduled between "admitted" and "written" while a
-- supervisor sealed, wrote the aggregate, and wrote the terminal envelope —
-- landing that sample after the envelope, where replay stops, or losing it
-- to the cancellation that follows. Under one lock a sample is either
-- wholly written before the seal or never admitted at all.
emitStreamEvent :: UnknownAggregator -> (AgentEvent -> IO ()) -> StreamEvent -> IO ()
emitStreamEvent _ emitEvent (StreamEvent Nothing agentEvent) = emitEvent agentEvent
emitStreamEvent (UnknownAggregator lock tally) emitEvent (StreamEvent (Just key) agentEvent) =
  withMVar lock $ \() -> do
    current <- readIORef tally
    if current.unknownTallySealed
      then pure ()
      else do
        let total = Map.findWithDefault 0 key current.unknownTallyCounts + 1
        writeIORef tally current {unknownTallyCounts = Map.insert key total current.unknownTallyCounts}
        when (total <= unknownNoticeSamples) (emitEvent agentEvent)

-- | Seals the aggregator and writes, through @emitEvent@, the one aggregate
-- summary each key with suppressed occurrences contributes.
--
-- Sealing is what makes this safe to call from a supervisor that is about to
-- cancel the stream loop still feeding the aggregator. Without it, that loop
-- could drain buffered provider output after the summary was written: fresh
-- occurrences would restart from zero and be emitted /after/ the final
-- summary — possibly after the terminal envelope, where replay stops — and
-- any they suppressed would die with the cancelled thread, counted but never
-- reported. Sealed, every later unknown notice is refused, so the summary is
-- final for the invocation. Recognized output is untouched.
--
-- Sealing and writing happen under the lock 'emitStreamEvent' also holds,
-- which is what makes the seal a real boundary rather than an instant. It
-- covers both directions. Inbound, it waits out a sample already being
-- written, so a sample admitted before the seal can never trail it. Outbound,
-- the summaries are written before the lock is released, so the /other/
-- caller of this — the flow and its supervisor both call it, and only the
-- first finds anything to report — cannot observe an already-sealed
-- aggregator, conclude there is nothing to write, and terminalize while the
-- winner's summaries are still in flight. When this returns, every unknown
-- notice this invocation will ever produce has already been written.
--
-- Callers seal before the invocation's terminal event, which is the whole
-- point: replay stops at that envelope.
sealUnknownAggregates :: UnknownAggregator -> (AgentEvent -> IO ()) -> IO ()
sealUnknownAggregates (UnknownAggregator lock tally) emitEvent =
  withMVar lock $ \() -> do
    current <- readIORef tally
    writeIORef tally (UnknownTally Map.empty True)
    mapM_
      emitEvent
      [ AgentEvent "event" (unknownAggregateNotice key total) "" Nothing
        | (key, total) <- Map.toAscList current.unknownTallyCounts,
          total > unknownNoticeSamples
      ]

-- | The single summary a key with suppressed occurrences leaves behind,
-- reporting how many times it occurred in total.
unknownAggregateNotice :: UnknownStreamKey -> Int -> Text
unknownAggregateNotice key total = elide maxUnknownNoticeLength (unknownNoticePrefix key <> " ×" <> Text.pack (show total))

-- | The category tag and normalized, bounded type label shared by a key's
-- per-occurrence notices and its aggregate summary.
unknownNoticePrefix :: UnknownStreamKey -> Text
unknownNoticePrefix (UnknownStreamKey category usableType) = categoryTag category <> label
  where
    label = maybe unknownTypePlaceholder (elide maxUnknownTypeLength . excerpt) usableType

categoryTag :: UnknownStreamCategory -> Text
categoryTag UnknownTopLevel = "[event] "
categoryTag UnknownCodexItem = "[item] "
categoryTag UnknownClaudeContent = "[content] "

-- | Truncates to at most @limit@ characters, marking any loss with a single
-- ellipsis so a bounded notice never reads as a complete payload. The length
-- probe drops at most @limit@ characters rather than measuring the whole
-- value, so an oversized input is never fully traversed.
elide :: Int -> Text -> Text
elide limit value
  | limit <= 0 = ""
  | Text.null (Text.drop limit value) = value
  | otherwise = Text.take (limit - 1) value <> "…"
