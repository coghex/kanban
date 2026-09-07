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
-- The append descriptor's @0600@ discipline is applied here rather than
-- shared, because the worker journal's opener is internal to that seam. It is
-- the same policy — @docs\/design.md@ §16's, established by issue #19 — and the
-- comment on 'openPrivateAppendDescriptor' below states it once for this
-- store.
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

import Control.Exception (IOException, bracket, onException, try)
import Data.Aeson (Result (Error, Success), Value (Object), eitherDecodeStrict', encode, fromJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Mission.Types
  ( MissionEnvelope (..),
    MissionEvent (..),
    MissionId (..),
    MissionRepository,
    missionEventSchemaVersion,
    missionRepositoryMatches,
  )
import Kanban.Worker (consumeJournalLines)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (setFdMode)
import System.Posix.IO (OpenFileFlags (append, creat), OpenMode (WriteOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.IO.ByteString (fdWrite)
import System.Posix.Types (Fd)

-- | Appends one event as a single complete line.
--
-- One @write(2)@ of the whole line, newline included, onto a descriptor opened
-- @O_APPEND@ — which is what makes the append atomic against every other
-- writer, so a concurrent reader observes a whole record or nothing of it.
--
-- The single call is the point, and it is why this does not go through a
-- 'Handle'. @hPut@ writes a lazy ByteString one chunk at a time, and an
-- encoded event is several chunks as soon as it outgrows the encoder's buffer,
-- with the newline always a chunk of its own. Each chunk is then its own
-- @write@, and @O_APPEND@ makes each of /those/ atomic rather than the
-- sequence: a second process appending between two of them merges the two
-- records into one malformed line, and both are lost once a reader has
-- advanced past it. Building the line strictly first and writing it once
-- closes that, whatever an event's size.
--
-- A short write is reported rather than resumed. Continuing would append the
-- remainder after whatever another writer had appended in the meantime, which
-- is the very splice this avoids; leaving it as an unterminated fragment is
-- what the reader already knows how to ignore.
appendMissionEvent :: FilePath -> MissionEvent -> IO (Either Text ())
appendMissionEvent path event = do
  let line = LazyByteString.toStrict (encode (MissionEnvelope missionEventSchemaVersion event) <> "\n")
  result <-
    try @IOException
      (bracket (openPrivateAppendDescriptor path) closeFd (`fdWrite` line))
  pure $ case result of
    Left exception -> Left (Text.pack (show exception))
    Right written
      | fromIntegral written == ByteString.length line -> Right ()
      | otherwise ->
          Left
            ( "only "
                <> Text.pack (show (toInteger written))
                <> " of "
                <> Text.pack (show (ByteString.length line))
                <> " bytes of a record reached "
                <> Text.pack path
            )

-- | Opens a mission journal for appending under §16's user-only file mode,
-- whatever the ambient umask and whichever release created the file.
--
-- @O_CREAT@ with an explicit mode closes the umask gap for a new journal, and
-- the mode is reapplied on the descriptor just opened so a journal an earlier
-- release left loose is tightened /before/ this call appends more private
-- bytes to it, rather than whenever some future rewrite that never comes
-- happens along.
openPrivateAppendDescriptor :: FilePath -> IO Fd
openPrivateAppendDescriptor path = do
  descriptor <- openFd path WriteOnly defaultFileFlags {append = True, creat = Just 0o600}
  onException (setFdMode descriptor 0o600) (closeFd descriptor)
  pure descriptor

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
    --
    -- No caller ever sees one. @readMissionJournal@ drops these before it
    -- returns, keeping the byte offset it advanced, because \"absent,
    -- silently\" means absent: a reader told about a record it cannot
    -- understand would have to decide what to do about it, and there is
    -- nothing to decide. The case exists here because this is where the
    -- decision is made, and because it is what separates a line another
    -- release wrote from a line that is broken.
    MissionJournalUnknownVersion Int
  | -- | Malformed JSON, no integer @schemaVersion@, or a payload that will
    -- not decode under a version this release does recognize. Names the
    -- mission and the file.
    MissionJournalMalformed Text
  | -- | A record that decodes perfectly well and belongs to another mission
    -- or another repository. Reported rather than emitted, and kept apart
    -- from 'MissionJournalMalformed' because it is not broken: the repair is
    -- to find out how it got here, not to fix its contents.
    MissionJournalRefused Text
  deriving stock (Eq, Show)

-- | Decides one complete line, reading its version before its payload for the
-- reason "Kanban.Mission.Paths" does.
--
-- Takes the journal's path so a diagnostic can name the file as well as the
-- mission: requirement 11 of issue #592 asks for both, and a mission's records
-- are spread over four files, so \"mission-0001 has a malformed record\" does
-- not say which one to look at.
decodeMissionJournalLine :: MissionId -> MissionRepository -> FilePath -> ByteString.ByteString -> MissionJournalLine
decodeMissionJournalLine mission repository path line = case eitherDecodeStrict' line :: Either String Value of
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
            Right envelope -> identified (missionEnvelopePayload (envelope :: MissionEnvelope MissionEvent))
  Right _ -> malformed "is not a JSON object"
  where
    malformed detail =
      MissionJournalMalformed
        ("mission " <> mission.unMissionId <> ": a record in " <> Text.pack path <> " " <> detail)
    -- Where the line sits and what it says about itself can be made to
    -- disagree: a journal restored from a backup, a directory copied by hand.
    -- Emitting such an event would attribute one mission's history to
    -- another, so it is reported and not delivered.
    identified event
      | event.missionEventMission /= mission =
          refused ("the mission " <> event.missionEventMission.unMissionId)
      | not (missionRepositoryMatches event.missionEventRepository repository) =
          refused "another repository"
      | otherwise = MissionJournalEvent event
    refused subject =
      MissionJournalRefused
        ("mission " <> mission.unMissionId <> ": a record in " <> Text.pack path <> " is recorded against " <> subject)
