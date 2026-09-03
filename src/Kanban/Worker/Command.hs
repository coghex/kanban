{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The durable dashboard-to-child input protocol (SAG-10, requirement 9).
--
-- The worker event journal carries one direction only: a supervisor tells
-- whoever is watching what happened. Everything a person does to a review —
-- answering a question, deciding an approval request, steering a turn,
-- resending a steer the provider refused, interrupting the active turn,
-- killing the whole action — used to travel the other way as a direct call
-- from Brick into an in-memory @ReviewClient@. A review that outlives its
-- dashboard has no such call to make, so those inputs become records too.
--
-- Two files, because they have two different writers. A dashboard appends to
-- @.commands.jsonl@ and never acknowledges; the host that owns the child
-- appends to @.command-acks.jsonl@ and never issues. Neither ever rewrites
-- the other's file, so no lock spans processes and a torn read is a record
-- that has not arrived yet rather than one that half-arrived.
--
-- The acknowledgement ledger is also the deduplication ledger, and that is
-- the whole of what makes delivery exactly-once across a restart. A command
-- is applied when its id has no acknowledgement; applying it writes one. A
-- host restarted mid-batch re-reads both files and skips what it already
-- acknowledged, and a command appended twice — a deliberate retry, a
-- duplicated replay — is applied on its first occurrence and skipped
-- thereafter, because after the first the ledger names it.
--
-- This module is internal — "Kanban.Worker" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Worker.Command
  ( ReviewCommandId (..),
    ReviewCommandPayload (..),
    ReviewCommand (..),
    ReviewCommandOutcome (..),
    ReviewCommandAcknowledgement (..),
    newReviewCommandId,
    reviewCommandPayloadSummary,
    appendReviewCommand,
    readReviewCommands,
    acknowledgeReviewCommand,
    readReviewCommandAcknowledgements,
    undeliveredReviewCommands,
    reviewCommandAcknowledgement,
    acknowledgementFor,
    reviewCommandSettled,
  )
where

import Control.Exception (IOException, onException, try)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict', encode)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as ByteString8
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (find)
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Kanban.Review (ReviewAnswer, ReviewRequestId, ReviewThreadId)
import Kanban.Worker.Types (WorkerDescriptor (..), WorkerId (..))
import System.IO (Handle, hClose)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (setFdMode)
import System.Posix.IO (OpenFileFlags (append, creat), OpenMode (WriteOnly), closeFd, defaultFileFlags, fdToHandle, openFd)
import System.Posix.Process (getProcessID)

-- | A command's identity, and the only thing deduplication is keyed by.
--
-- Allocated by the dashboard that issues the command, from its own pid and
-- the clock, so two dashboards writing to one child's journal at the same
-- instant cannot collide — and so an id survives being read back, compared,
-- and acknowledged by a process that never saw the press.
newtype ReviewCommandId = ReviewCommandId {unReviewCommandId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

newReviewCommandId :: IO ReviewCommandId
newReviewCommandId = do
  now <- getCurrentTime
  pid <- getProcessID
  pure (ReviewCommandId (timestampKey now <> "-" <> Text.pack (show pid)))
  where
    timestampKey = Text.filter (`notElem` ("-:.TZ " :: String)) . Text.pack . show

-- | Every input the review overlay can send, and no others.
--
-- Closed for the reason 'Kanban.Action.Types.WorkflowActionKind' is: a
-- seventh input is a compile error in the host that has to apply it, not a
-- record it silently ignores.
--
-- Each carries what the /overlay/ showed, alongside what the provider needs,
-- because the transcript entry a delivered command writes is part of the
-- evidence a later dashboard replays. Re-deriving that text in the host would
-- be a second phrasing of what the user was already shown.
data ReviewCommandPayload
  = -- | An answer to a structured question, with the text to show for it.
    AnswerReviewQuestion ReviewRequestId ReviewAnswer Text
  | -- | An approval decision: accepted, and whether for the whole session.
    -- The two flags are the once\/session\/decline triple the overlay offers,
    -- spelled the way 'Kanban.Review.approveReviewAction' takes them.
    AnswerReviewApproval ReviewRequestId Bool Bool Text
  | -- | Ordinary feedback or turn steering.
    SendReviewFeedback Text
  | -- | A deliberate resend of a steer the provider refused. Distinct from
    -- feedback because it is the recovery of a specific earlier message
    -- (issue #17), and reporting it as a fresh one would lose that.
    ResendReviewSteer Text
  | -- | Interrupt the active turn. Not termination: an interrupted
    -- interactive revision stays resumable, and its child is untouched.
    InterruptReviewTurn
  | -- | End the whole child action and settle what it owns.
    TerminateIssueAction
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | How a command reads in a diagnostic, and in the acknowledgement a
-- rejection carries.
reviewCommandPayloadSummary :: ReviewCommandPayload -> Text
reviewCommandPayloadSummary payload = case payload of
  AnswerReviewQuestion {} -> "question answer"
  AnswerReviewApproval {} -> "approval decision"
  SendReviewFeedback _ -> "feedback"
  ResendReviewSteer _ -> "resent steer"
  InterruptReviewTurn -> "turn interrupt"
  TerminateIssueAction -> "termination"

-- | One command, addressed to one child action.
--
-- The thread, turn, and request identity travel with the command rather than
-- being resolved when it is applied. A command written while a turn was
-- running and read after a new one started must reach the turn the user meant
-- — a stale interrupt that lands on the /next/ turn is worse than one that is
-- refused — so the host compares what the command names against what the
-- child currently holds and rejects a mismatch rather than retargeting it.
data ReviewCommand = ReviewCommand
  { reviewCommandId :: ReviewCommandId,
    -- | The child this is for. A command whose target is not this child is
    -- another child's business even when both are read from one directory.
    reviewCommandTarget :: WorkerId,
    reviewCommandIssue :: Int,
    reviewCommandThread :: Maybe ReviewThreadId,
    reviewCommandTurn :: Maybe Text,
    reviewCommandIssuedAt :: UTCTime,
    reviewCommandPayload :: ReviewCommandPayload
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What the owning live session did with a command.
--
-- A rejection is as durable as an acceptance and as final: it says the
-- command was seen, considered, and not applied, which is what stops a
-- refused steer being retried forever by a dashboard that cannot tell
-- "rejected" from "not read yet".
--
-- 'ReviewCommandClaimed' is the one that makes delivery exactly-once rather
-- than at-least-once. It is written /before/ the command is applied, so a
-- host that dies between applying and recording the result has still left a
-- record that stops the next pass applying it again — which is what a steer
-- being sent twice to a provider looks like from the other end. It is
-- superseded by the real outcome the moment that lands; a claim still
-- standing afterwards is an attempt whose result was never observed, and is
-- reported as exactly that rather than guessed either way.
data ReviewCommandOutcome
  = ReviewCommandClaimed
  | ReviewCommandAccepted
  | ReviewCommandRejected Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether an acknowledgement is the final word on its command.
reviewCommandSettled :: ReviewCommandOutcome -> Bool
reviewCommandSettled ReviewCommandClaimed = False
reviewCommandSettled ReviewCommandAccepted = True
reviewCommandSettled (ReviewCommandRejected _) = True

data ReviewCommandAcknowledgement = ReviewCommandAcknowledgement
  { acknowledgedCommandId :: ReviewCommandId,
    acknowledgedAt :: UTCTime,
    acknowledgedOutcome :: ReviewCommandOutcome
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

reviewCommandAcknowledgement :: ReviewCommand -> ReviewCommandOutcome -> IO ReviewCommandAcknowledgement
reviewCommandAcknowledgement command outcome = do
  now <- getCurrentTime
  pure (ReviewCommandAcknowledgement command.reviewCommandId now outcome)

appendReviewCommand :: WorkerDescriptor -> ReviewCommand -> IO (Either Text ())
appendReviewCommand descriptor = appendRecord descriptor.workerDescriptorCommandPath

acknowledgeReviewCommand :: WorkerDescriptor -> ReviewCommandAcknowledgement -> IO (Either Text ())
acknowledgeReviewCommand descriptor = appendRecord descriptor.workerDescriptorCommandAckPath

readReviewCommands :: WorkerDescriptor -> IO [ReviewCommand]
readReviewCommands descriptor = readRecords descriptor.workerDescriptorCommandPath

readReviewCommandAcknowledgements :: WorkerDescriptor -> IO [ReviewCommandAcknowledgement]
readReviewCommandAcknowledgements descriptor = readRecords descriptor.workerDescriptorCommandAckPath

-- | The commands still owed an answer, oldest first, each appearing once.
--
-- Both halves of deduplication are here rather than split between this and
-- its caller. Acknowledged ids are dropped because the ledger says they were
-- applied; a repeated id within the remainder is dropped after its first
-- occurrence because nothing has acknowledged it /yet/ and applying it twice
-- in one pass would be the same double delivery a restart is protected from.
undeliveredReviewCommands :: [ReviewCommand] -> [ReviewCommandAcknowledgement] -> [ReviewCommand]
undeliveredReviewCommands commands acknowledgements = go Set.empty commands
  where
    settled = Set.fromList (map (.acknowledgedCommandId) acknowledgements)
    go _ [] = []
    go seen (command : remaining)
      | Set.member identity settled || Set.member identity seen = go seen remaining
      | otherwise = command : go (Set.insert identity seen) remaining
      where
        identity = command.reviewCommandId

-- | One record, one @write(2)@.
--
-- The lazy-'LazyByteString.hPut' spelling the event journal uses emits each
-- lazy chunk as its own write, so @O_APPEND@ keeps a /chunk/ whole rather
-- than a record; a command large enough to be chunked — a long steer — could
-- be interleaved with a concurrent append and read back as two broken lines.
-- Forcing the encoded record strict first is what makes the append atomic for
-- any record the pipe buffer can hold.
appendRecord :: ToJSON record => FilePath -> record -> IO (Either Text ())
appendRecord path record = do
  written <- try @IOException $ do
    handle <- openPrivateAppendHandle path
    ByteString.hPut handle (LazyByteString.toStrict (encode record) <> "\n")
    hClose handle
  pure (either (Left . Text.pack . show) Right written)

-- | Whole lines only. An unterminated trailing fragment is an append still in
-- flight, so it is left for the next read rather than reported as a record
-- that will not decode — the same rule 'Kanban.Worker.Journal' reads its own
-- journal by, for the same reason.
readRecords :: FromJSON record => FilePath -> IO [record]
readRecords path = do
  contents <- try @IOException (ByteString.readFile path)
  pure $ case contents of
    Left failure | isDoesNotExistError failure -> []
    Left _ -> []
    Right bytes -> mapMaybe decodeRecord (completeLines bytes)
  where
    decodeRecord line = either (const Nothing) Just (eitherDecodeStrict' line)
    completeLines bytes = case ByteString.elemIndexEnd newline bytes of
      Nothing -> []
      Just lastNewline ->
        filter (not . ByteString.null) (ByteString.split newline (ByteString.take (lastNewline + 1) bytes))
    newline = ByteString.head (ByteString8.pack "\n")

-- | The same user-only creation the event journal opens under: a command
-- carries a person's typed guidance and a review's request payloads, which is
-- exactly as private as the transcript beside it.
openPrivateAppendHandle :: FilePath -> IO Handle
openPrivateAppendHandle path = do
  commandFd <- openFd path WriteOnly defaultFileFlags {append = True, creat = Just 0o600}
  onException (setFdMode commandFd 0o600 >> fdToHandle commandFd) (closeFd commandFd)

-- | Whether one command has settled, and how.
--
-- What a dashboard asks after submitting one. A command with no
-- acknowledgement has not been read yet; a rejected one is the account of why
-- what the user typed never reached the provider, and is the only thing that
-- can put a message back on their input line rather than leaving it looking
-- delivered.
--
-- The /last/ record for an id, because a command is claimed before it is
-- applied and its real outcome appended after. Reading the first would report
-- every settled command as still in flight.
acknowledgementFor :: ReviewCommandId -> [ReviewCommandAcknowledgement] -> Maybe ReviewCommandAcknowledgement
acknowledgementFor identity acknowledgements =
  find ((== identity) . (.acknowledgedCommandId)) (reverse acknowledgements)
