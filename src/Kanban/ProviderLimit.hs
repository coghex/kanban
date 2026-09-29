{-# LANGUAGE DerivingStrategies #-}

-- | Whether a failed agent session hit a provider limit, decided only from
-- the provider's own structured evidence (issue #752, design D-18).
--
-- A mission that meets a rate limit or an exhausted usage quota should wait
-- for it to lift and take the same turn again; everything else — a failed
-- login, a missing executable, a broken configuration, depleted credits —
-- needs a person, and retrying it only repeats the failure. The two are told
-- apart here, and the rule for telling them apart is the whole of this
-- module:
--
-- * __Claude.__ The session's final @result@ says @is_error@, and either its
--   latest @rate_limit_event@ is @rejected@ without overage covering it, or it
--   recorded no such event and the @result@'s @api_error_status@ is 429.
--   @allowed_warning@ never counts, and neither does a @rejected@ status that
--   overage covers.
-- * __Codex.__ The session's turn failed, and the account's rate-limit
--   snapshot, read after the failure, names a rate or usage limit. A session
--   run on the app server may instead name @usageLimitExceeded@ or
--   @rateLimitExceeded@ as its failed turn's @codexErrorInfo@, which is
--   sufficient on its own.
-- * __Depleted credits__ — Codex's @*_credits_depleted@, or a Claude
--   @rejected@ status whose overage is disabled @out_of_credits@ — are named
--   as such and stop the mission, whatever else the evidence says.
--
-- /No error text is ever read./ A sentence a provider printed is exactly what
-- an authentication failure and a quota both print, and matching one is the
-- fail-open path that would retry a broken login for ever. Every judgement
-- below is over a field a provider's schema defines, and anything this module
-- cannot recognise — an unknown status, an unknown reached type, a snapshot
-- that will not read — is 'ProviderLimitUnidentified', which concludes the
-- failure exactly as it concluded before this module existed.
module Kanban.ProviderLimit
  ( ProviderLimit (..),
    claudeSessionLimit,
    codexTurnFailed,
    codexSessionLimit,
    readProviderStream,
    ProviderLimitSeams (..),
    liveProviderLimitSeams,
    settledProviderFailure,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (Object, Value (..), decodeStrict, (.:?))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser, parseMaybe)
import qualified Data.ByteString.Char8 as ByteString
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Kanban.Action.Types (ActionOutcome (..), settledWorkerFailure)
import Kanban.Codex (CodexAccountLimit (..), fetchCodexAccountLimit)
import Kanban.Models (ProviderName (..), RecordedAssignment (..))
import Kanban.Provider (ProviderError (..))
import Kanban.ProviderAdapter (providerForBrand)
import Kanban.Worker
  ( SolveWorkerTask (..),
    WorkerDescriptor (..),
    WorkerSpec (..),
    WorkerState (..),
    WorkerTask (..),
  )

-- | What one failed session's evidence establishes.
data ProviderLimit
  = -- | A positively identified rate or usage limit, and the time the
    -- provider said it resets, when it said one.
    ProviderLimitReached (Maybe UTCTime) Text
  | -- | Credits have run out. No reset time is coming; somebody has to act on
    -- billing.
    ProviderCreditsDepleted Text
  | -- | Nothing here identifies a limit.
    ProviderLimitUnidentified
  deriving stock (Eq, Show)

-- ---------------------------------------------------------------------------
-- The recorded stream
-- ---------------------------------------------------------------------------

-- | The provider's stdout events from the latest invocation a session log
-- records.
--
-- The log is the one "Kanban.Transcript" writes for every solve and
-- pull-request invocation: one JSON record per line, a provider line carried
-- verbatim under @raw@ with the stream it came from, and Kanban's own records
-- under @event@. A resumed session appends to the same file, so only what
-- follows the last @invocation-started@ record is this turn's evidence; an
-- earlier turn's rate-limit event is not a statement about this one.
--
-- A line that does not decode is passed over rather than failing the read: a
-- provider may print anything on stdout, and one unparseable line says nothing
-- about the structured ones around it.
readProviderStream :: FilePath -> IO (Either Text [Value])
readProviderStream path = do
  contents <- try @IOException (ByteString.readFile path)
  pure $ case contents of
    Left exception -> Left ("the session log could not be read: " <> Text.pack (show exception))
    Right bytes -> Right (mapMaybe providerLine (latestInvocation (mapMaybe decodeStrict (ByteString.lines bytes))))
  where
    -- Accumulated newest-first and reversed once, so a long session's log is
    -- read in one linear pass rather than copied again on every line.
    latestInvocation = reverse . foldl' (\kept record -> if invocationStarted record then [] else record : kept) []
    invocationStarted record = field "stream" record == Just "kanban" && field "event" record == Just "invocation-started"
    providerLine record
      | field "stream" record == Just "stdout",
        Just raw <- field "raw" record =
          decodeStrict (TextEncoding.encodeUtf8 raw)
      | otherwise = Nothing
    field :: Text -> Value -> Maybe Text
    field name = parseMaybe (withObjectField name)

withObjectField :: Text -> Value -> Parser Text
withObjectField name value = case value of
  Object fields -> maybe (fail "absent") textOf (KeyMap.lookup (keyOf name) fields)
  _ -> fail "not an object"
  where
    textOf (String text) = pure text
    textOf _ = fail "not text"

-- ---------------------------------------------------------------------------
-- Claude
-- ---------------------------------------------------------------------------

-- | A Claude session's evidence, read off its stream-json events.
claudeSessionLimit :: [Value] -> ProviderLimit
claudeSessionLimit events = case lastOf "result" of
  Just result
    | boolField "is_error" result == Just True -> case lastOf "rate_limit_event" of
        Just event -> rateLimitEvent (objectField "rate_limit_info" event)
        Nothing
          | integerField "api_error_status" result == Just 429 ->
              ProviderLimitReached Nothing "claude's API refused the turn with HTTP 429 and recorded no rate-limit event"
          | otherwise -> ProviderLimitUnidentified
  _ -> ProviderLimitUnidentified
  where
    lastOf kind = case [event | Object event <- events, textField "type" event == Just kind] of
      [] -> Nothing
      found -> Just (last found)
    rateLimitEvent Nothing = ProviderLimitUnidentified
    rateLimitEvent (Just info) = case textField "status" info of
      Just "rejected"
        | textField "overageStatus" info `elem` [Just "allowed", Just "allowed_warning"] -> ProviderLimitUnidentified
        | textField "overageDisabledReason" info == Just "out_of_credits" ->
            ProviderCreditsDepleted "claude rejected the turn at its rate limit and overage is disabled because the account is out of credits"
        | otherwise ->
            ProviderLimitReached
              (posixSecondsToUTCTime . fromInteger <$> integerField "resetsAt" info)
              ( "claude rejected the turn at its "
                  <> maybe "" (<> " ") (textField "rateLimitType" info)
                  <> "rate limit"
              )
      -- @allowed@, @allowed_warning@, and anything this release does not
      -- know. The latest event is the account's standing when the turn ended,
      -- and none of these says the turn was refused for capacity.
      _ -> ProviderLimitUnidentified

-- ---------------------------------------------------------------------------
-- Codex
-- ---------------------------------------------------------------------------

-- | Whether a Codex session's recorded stream shows its turn failing.
--
-- The precondition for asking the account at all. The snapshot describes the
-- account, not the session: read after a launch that never reached the
-- provider, or after a session somebody cancelled, it would attribute
-- somebody else's limit to a failure that had nothing to do with it. A
-- @codex exec@ turn that failed says @turn.failed@; an app-server turn says so
-- in its completed turn's status.
codexTurnFailed :: [Value] -> Bool
codexTurnFailed events = any execFailed events || not (null (appServerFailures events))
  where
    execFailed (Object event) = textField "type" event == Just "turn.failed"
    execFailed _ = False

-- | A Codex session's evidence: its stream, and the account snapshot read
-- after it failed.
--
-- Depleted credits outrank everything, including direct evidence of a limit,
-- because a limit that credits would have covered is not one waiting will
-- clear. Direct evidence is sufficient without the snapshot, and an
-- unreadable snapshot does not take it away; the snapshot still supplies the
-- limiting window's reset when it can.
codexSessionLimit :: [Value] -> Either Text CodexAccountLimit -> ProviderLimit
codexSessionLimit events snapshot
  | not (codexTurnFailed events) = ProviderLimitUnidentified
  | Just depleted <- reached, depleted `elem` creditsDepleted =
      ProviderCreditsDepleted ("the codex account reports " <> depleted)
  | Just limit <- reached, limit `elem` limitsReached =
      ProviderLimitReached resetsAt ("the codex account reports " <> limit)
  | (info : _) <- directEvidence =
      ProviderLimitReached resetsAt ("the codex turn failed with " <> info)
  | otherwise = ProviderLimitUnidentified
  where
    readable = either (const Nothing) Just snapshot
    reached = readable >>= (.codexLimitReachedType)
    resetsAt = readable >>= (.codexLimitResetsAt)
    directEvidence = filter (`elem` ["usageLimitExceeded", "rateLimitExceeded"]) (appServerFailures events)
    limitsReached = ["rate_limit_reached", "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached"]
    creditsDepleted = ["workspace_owner_credits_depleted", "workspace_member_credits_depleted"]

-- | Every failed app-server turn in a stream, by the @codexErrorInfo@ it
-- carried — the empty string for a failed turn that named none, so a failure
-- is still counted as one.
appServerFailures :: [Value] -> [Text]
appServerFailures events =
  [ maybe "" id (errorInfo turn)
  | Object event <- events,
    textField "method" event == Just "turn/completed",
    Just params <- [objectField "params" event],
    Just turn <- [objectField "turn" params],
    textField "status" turn == Just "failed"
  ]
  where
    -- Only the bare-string variants: every structured one carries an HTTP
    -- failure, and none of those is a limit this rule identifies.
    errorInfo turn = objectField "error" turn >>= textField "codexErrorInfo"

-- ---------------------------------------------------------------------------
-- A settled worker
-- ---------------------------------------------------------------------------

-- | The one read this module makes beyond a worker's own files.
data ProviderLimitSeams = ProviderLimitSeams
  { providerLimitCodexAccount :: IO (Either Text CodexAccountLimit)
  }

-- | The account read through the Codex app server, bounded like the usage
-- read it shares its exchange with.
liveProviderLimitSeams :: Int -> ProviderLimitSeams
liveProviderLimitSeams timeoutMicros =
  ProviderLimitSeams
    { providerLimitCodexAccount = either (Left . (.providerErrorMessage)) Right <$> fetchCodexAccountLimit timeoutMicros
    }

-- | A settled worker's failure, typed with what its provider recorded.
--
-- 'settledWorkerFailure' first, and only its generic answer is looked into
-- further: a deadline, a moved or unverifiable target, and everything else it
-- already names keep the outcome they had, whatever a provider log beside
-- them says. What remains is asked of the worker's own recorded stream — and,
-- for Codex, of the account — and concludes as a capacity limit only when
-- that evidence identifies one.
--
-- A worker with no recorded provider, or no session log, or a log that cannot
-- be read, has no evidence to offer and fails as it always did.
settledProviderFailure :: ProviderLimitSeams -> WorkerDescriptor -> WorkerState -> Text -> IO ActionOutcome
settledProviderFailure seams descriptor state detail = case settledWorkerFailure detail of
  ActionFailed _ -> case (workerProvider descriptor.workerDescriptorSpec, state.workerStateLogPath) of
    (Just provider, Just path) -> do
      stream <- readProviderStream path
      case stream of
        Left _ -> pure (ActionFailed detail)
        Right events -> concluded <$> limitOf provider events
    _ -> pure (ActionFailed detail)
  typed -> pure typed
  where
    limitOf ClaudeProvider events = pure (claudeSessionLimit events)
    limitOf CodexProvider events
      | codexTurnFailed events = codexSessionLimit events <$> seams.providerLimitCodexAccount
      | otherwise = pure ProviderLimitUnidentified
    concluded limit = case limit of
      ProviderLimitReached resetsAt evidence -> ActionCapacityLimited resetsAt (evidence <> ": " <> detail)
      ProviderCreditsDepleted evidence -> ActionFailed ("credits are depleted: " <> evidence <> ": " <> detail)
      ProviderLimitUnidentified -> ActionFailed detail

-- | The provider a worker's session ran on, when its record says.
--
-- The recorded assignment is the launch's own account of which provider it
-- started, so it wins; a solve written before assignments were recorded still
-- names its brand. Every other worker kind — the review host and its issue
-- actions, which run the canonical review scripts' own providers — has no
-- session of its own this module can read.
workerProvider :: WorkerSpec -> Maybe ProviderName
workerProvider spec = case spec.workerTask of
  SolveWorkerTaskKind task -> Just (maybe (providerForBrand task.solveWorkerBrand) (.recordedAssignmentProvider) spec.workerAssignment)
  PullRequestWorkerTaskKind _ -> (.recordedAssignmentProvider) <$> spec.workerAssignment
  IssueHostWorkerTaskKind _ -> Nothing
  IssueActionWorkerTaskKind _ -> Nothing

-- ---------------------------------------------------------------------------
-- Field access
-- ---------------------------------------------------------------------------

textField :: Text -> Object -> Maybe Text
textField name object = case KeyMap.lookup (keyOf name) object of
  Just (String text) -> Just text
  _ -> Nothing

boolField :: Text -> Object -> Maybe Bool
boolField name object = case KeyMap.lookup (keyOf name) object of
  Just (Bool value) -> Just value
  _ -> Nothing

integerField :: Text -> Object -> Maybe Integer
integerField name object = parseMaybe (\fields -> fields .:? keyOf name) object >>= id

objectField :: Text -> Object -> Maybe Object
objectField name object = case KeyMap.lookup (keyOf name) object of
  Just (Object inner) -> Just inner
  _ -> Nothing

keyOf :: Text -> Key.Key
keyOf = Key.fromText
