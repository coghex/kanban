-- | A mission's append-only event journal: how a record is appended and how a
-- reader consumes what has been appended without ever replaying or dropping
-- one.
--
-- Both directions live here for the reason "Kanban.Worker.Journal" keeps its
-- own two halves together: the single-write append and the byte-offset
-- consumption are two halves of one guarantee, and separating them leaves each
-- half's comments explaining an invariant the other one enforces.
--
-- The splitting rule itself is not restated here. 'consumeJournalLines' is
-- imported from the worker journal, which is where issue #8 established it and
-- where its proofs live; a mission journal that re-implemented the same
-- byte-offset arithmetic would be a second chance to get it wrong. What is
-- new here is the envelope: every appended record carries its own
-- @schemaVersion@, so a line another release wrote reads as absent instead of
-- stopping the read, while a genuinely malformed line is reported.
--
-- The append handle's @0600@ discipline is applied here rather than shared,
-- because the worker journal's opener is internal to that seam. It is the same
-- policy — @docs\/design.md@ §16's, established by issue #19 — and the comment
-- on 'openPrivateAppendHandle' below states it once for this store.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Journal
  ( appendMissionEvent,
    readMissionJournalSince,
    decodeMissionJournalLine,
    MissionJournalLine (..),
  )
where

import Control.Exception (IOException, onException, try)
import Data.Aeson (Result (Error, Success), Value (Object), eitherDecodeStrict', encode, fromJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Mission.Types
  ( MissionEnvelope (..),
    MissionEvent,
    MissionId (..),
    missionEventSchemaVersion,
  )
import Kanban.Worker (consumeJournalLines)
import System.IO (BufferMode (LineBuffering), Handle, hClose, hSetBinaryMode, hSetBuffering)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (setFdMode)
import System.Posix.IO (OpenFileFlags (append, creat), OpenMode (WriteOnly), closeFd, defaultFileFlags, fdToHandle, openFd)

-- | Appends one event as a single complete line.
--
-- One write of envelope-plus-newline, so a concurrent reader observes a whole
-- record or nothing of it rather than a record split across two writes. The
-- handle is opened and closed around the append so a reader always sees a
-- flushed record and a long-lived mission never retains a deleted journal's
-- inode.
appendMissionEvent :: FilePath -> MissionEvent -> IO (Either Text ())
appendMissionEvent path event = do
  result <- try @IOException $ do
    handle <- openPrivateAppendHandle path
    hSetBuffering handle LineBuffering
    LazyByteString.hPut handle (encode (MissionEnvelope missionEventSchemaVersion event) <> "\n")
    hClose handle
  pure (either (Left . Text.pack . show) Right result)

-- | Opens a mission journal for appending under §16's user-only file mode,
-- whatever the ambient umask and whichever release created the file.
--
-- @O_CREAT@ with an explicit mode closes the umask gap for a new journal, and
-- the mode is reapplied on the descriptor just opened so a journal an earlier
-- release left loose is tightened /before/ this call appends more private
-- bytes to it, rather than whenever some future rewrite that never comes
-- happens along.
openPrivateAppendHandle :: FilePath -> IO Handle
openPrivateAppendHandle path = do
  journalFd <- openFd path WriteOnly defaultFileFlags {append = True, creat = Just 0o600}
  handle <- onException (setFdMode journalFd 0o600 >> fdToHandle journalFd) (closeFd journalFd)
  hSetBinaryMode handle True
  pure handle

-- | Reads the journal's full current contents and consumes the complete lines
-- appended since @consumedBytes@, returning the new offset.
--
-- An unterminated trailing fragment is left unconsumed, so the /same/ record
-- is read once — whole — after the append that was in flight completes. A
-- journal that does not exist yet is an empty read rather than a failure: that
-- is the ordinary state before a mission's first event. Any other read failure
-- is surfaced so the caller can retry without moving the offset.
readMissionJournalSince :: FilePath -> Int -> IO (Either Text ([ByteString.ByteString], Int))
readMissionJournalSince path consumedBytes = do
  contentResult <- try @IOException (ByteString.readFile path)
  pure $ case contentResult of
    Left exception
      | isDoesNotExistError exception -> Right ([], consumedBytes)
      | otherwise -> Left (Text.pack (show exception))
    Right content -> Right (consumeJournalLines consumedBytes content)

-- | What one complete journal line turned out to be.
data MissionJournalLine
  = -- | A record this release recognizes.
    MissionJournalEvent MissionEvent
  | -- | A complete line carrying a @schemaVersion@ this release does not
    -- recognize. Absent on §16's terms, and — this is the part that matters
    -- for a journal rather than a snapshot — absent for this line only: the
    -- lines after it are still examined.
    MissionJournalUnknownVersion Int
  | -- | Malformed JSON, no integer @schemaVersion@, or a payload that will
    -- not decode under a version this release does recognize. Names the
    -- mission.
    MissionJournalMalformed Text
  deriving stock (Eq, Show)

-- | Decides one complete line, reading its version before its payload for the
-- reason "Kanban.Mission.Paths" does.
decodeMissionJournalLine :: MissionId -> ByteString.ByteString -> MissionJournalLine
decodeMissionJournalLine mission line = case eitherDecodeStrict' line :: Either String Value of
  Left message -> malformed ("is not JSON (" <> Text.pack message <> ")")
  Right (Object fields) -> case KeyMap.lookup "schemaVersion" fields of
    Nothing -> malformed "carries no schemaVersion"
    Just versionValue -> case fromJSON versionValue :: Result Int of
      Error _ -> malformed "carries a schemaVersion that is not an integer"
      Success version
        | version /= missionEventSchemaVersion -> MissionJournalUnknownVersion version
        | otherwise -> case eitherDecodeStrict' line of
            Left message ->
              malformed
                ( "did not decode under schema version "
                    <> Text.pack (show version)
                    <> " ("
                    <> Text.pack message
                    <> ")"
                )
            Right envelope -> MissionJournalEvent (missionEnvelopePayload (envelope :: MissionEnvelope MissionEvent))
  Right _ -> malformed "is not a JSON object"
  where
    malformed detail = MissionJournalMalformed ("mission " <> mission.unMissionId <> ": a journal record " <> detail)
