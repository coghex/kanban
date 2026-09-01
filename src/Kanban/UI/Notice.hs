-- | The notice line's lifecycle, as an abstract state machine.
--
-- 'NoticeState' exports no constructor, so the only values of it anywhere are
-- the ones 'emptyNoticeState' and the transitions below produce. That is
-- what makes "no producer bypasses the lifecycle" a property of the types
-- rather than of review discipline: an @appNotice = ...@ that does not go
-- through 'showNotice' or 'clearNotice' has nothing to put on the right-hand
-- side (issue #590 requirement 13).
--
-- Every displayed notice is an /instance/: the text shown plus an identity no
-- other instance of this process ever reuses, taken from a serial that only
-- counts up. Replacing, composing, or repeating a notice therefore always
-- creates a new instance, even with identical text, and an expiry armed for an
-- older instance finds nothing it is allowed to touch (requirements 4 and 5).
--
-- A notice is either settled or active. Settled is the default and means the
-- message reports something finished: it earns a deadline ten seconds after
-- 'settleNotice' first sees it, and the tick 'noticeExpiryDue' admits clears
-- it once that deadline has passed. Active means the message explicitly
-- reports an operation the application still tracks in progress, named by a
-- 'NoticeActivity' whose liveness the caller decides; while the activity is
-- live no deadline is armed, and the settle that follows the activity's end
-- starts the ordinary ten seconds (requirements 7 and 8).
module Kanban.UI.Notice
  ( NoticeState,
    NoticeLife (..),
    NoticeActivity (..),
    emptyNoticeState,
    showNotice,
    clearNotice,
    settleNotice,
    noticeExpiryDue,
    noticeExpiryToArm,
    currentNotice,
    currentNoticeInstance,
    currentNoticeLife,
    armedNoticeExpiry,
    noticeExpirySeconds,
    noticeExpiryDelayMicros,
  )
where


import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Kanban.Domain (UsageProvider (..))

-- | How long a settled notice stays on screen when nothing clears or replaces
-- it first. A fixed application behavior, not a configuration setting (issue
-- #590 requirement 12), and the one place the number is written.
noticeExpirySeconds :: NominalDiffTime
noticeExpirySeconds = 10

-- | The same duration, as the delay handed to the one-shot timer thread that
-- delivers the expiry event.
noticeExpiryDelayMicros :: Int
noticeExpiryDelayMicros = round (realToFrac noticeExpirySeconds * 1000000 :: Double)

-- | Whether a notice reports something finished or something still running.
data NoticeLife
  = -- | The message reports a settled fact. It expires ten seconds after it
    -- is first seen settled.
    SettledNotice
  | -- | The message explicitly reports the named operation as in progress.
    -- It outlives the ten seconds for as long as the caller's liveness answer
    -- for that activity is true, and settles the moment it is not.
    ActiveWhile NoticeActivity
  deriving stock (Eq, Show)

-- | The declared inventory of tracked operations a notice may stay alive on
-- (issue #590 requirement 7). One constructor per operation the application
-- tracks in its own state; what state keeps each alive is
-- 'Kanban.UI.Util.noticeActivityLive', the inventory's one reader. A notice
-- produced without naming one of these is settled by construction.
data NoticeActivity
  = -- | The startup composed notice: it names the first open-data fetch,
    -- which is in flight until the first generation settles one way or the
    -- other.
    StartupLoadRunning
  | -- | @Refreshing GitHub…@ and the report that one is already running:
    -- alive while the board itself says a fetch is loading.
    BoardRefreshRunning
  | -- | One provider's @Refreshing … usage…@, alive while that provider's
    -- freshness says so.
    UsageRefreshRunning UsageProvider
  | -- | The PR drainer's optimistic start/stop report, alive until the
    -- toggle's observation lands.
    DrainerToggleRunning
  | -- | The issue approval service's optimistic start/stop report, alive
    -- until the toggle's observation lands.
    ApprovalToggleRunning
  | -- | @Merging PR #n…@, alive while that pull request's direct merge is
    -- pending.
    DirectMergeRunning Int
  | -- | @Stopping GitHub work…@, alive while the quit is waiting for the
    -- coordinator's cleanup verdict.
    QuitSettling
  deriving stock (Eq, Show)

-- | One displayed notice instance. Internal: nothing outside this module can
-- build or edit one.
data Notice = Notice
  { noticeText :: Text,
    noticeInstance :: Int,
    noticeLife :: NoticeLife,
    -- | When the instance expires, once 'settleNotice' has seen it settled.
    -- 'Nothing' while it is active or not yet settled.
    noticeDeadline :: Maybe UTCTime
  }
  deriving stock (Eq, Show)

-- | The notice line's whole state: what is on it, and the serial the next
-- instance takes. The serial never goes backwards — above all not when the
-- line is cleared — which is what keeps a dismissed instance's identity from
-- ever being handed to a newer notice (requirement 5).
data NoticeState = NoticeState
  { noticeCurrent :: Maybe Notice,
    noticeSerial :: Int
  }
  deriving stock (Eq, Show)

emptyNoticeState :: NoticeState
emptyNoticeState = NoticeState Nothing 0

-- | Display one notice: a fresh instance, with no deadline until
-- 'settleNotice' classifies it against the state of the world.
showNotice :: NoticeLife -> Text -> NoticeState -> NoticeState
showNotice life message state =
  NoticeState
    { noticeCurrent = Just (Notice message state.noticeSerial life Nothing),
      noticeSerial = state.noticeSerial + 1
    }

-- | Take whatever is displayed off the line. The instance is retired for
-- good: its identity is never reissued, so an expiry still queued for it can
-- only miss.
clearNotice :: NoticeState -> NoticeState
clearNotice state = state {noticeCurrent = Nothing}

-- | Classify the displayed notice against the caller's answer for each
-- tracked activity, run after every event. An active notice whose activity is
-- live carries no deadline; anything else — settled from birth, or active
-- with its operation finished — gets the ten-second deadline the instant this
-- first sees it, and keeps the deadline it already has after that.
settleNotice :: UTCTime -> (NoticeActivity -> Bool) -> NoticeState -> NoticeState
settleNotice now live state = state {noticeCurrent = settle <$> state.noticeCurrent}
  where
    settle notice
      | ActiveWhile activity <- notice.noticeLife, live activity = notice {noticeDeadline = Nothing}
      | Nothing <- notice.noticeDeadline = notice {noticeDeadline = Just (addUTCTime noticeExpirySeconds now)}
      | otherwise = notice

-- | Whether the expiry that just fired for @instanceId@ is the one the
-- displayed notice is waiting for: same instance, a deadline armed, and the
-- deadline reached. Anything else — a replaced or dismissed instance, an
-- identical-text successor under a new identity, a deadline re-armed later
-- than the tick that fired — is a stale timer with no claim on the line.
noticeExpiryDue :: Int -> UTCTime -> NoticeState -> Bool
noticeExpiryDue instanceId now state = case state.noticeCurrent of
  Just notice
    | notice.noticeInstance == instanceId,
      Just deadline <- notice.noticeDeadline ->
        now >= deadline
  _ -> False

-- | The one-shot timer an event's outcome requires, if it requires one: the
-- instance to arm, exactly when this settle armed a deadline the state did
-- not carry before it. An unchanged armed pair keeps the timer it already
-- has, so an idle event never stacks a second thread behind the first.
noticeExpiryToArm :: NoticeState -> NoticeState -> Maybe Int
noticeExpiryToArm before after = case armedNoticeExpiry after of
  Just armed | armedNoticeExpiry before /= Just armed -> Just (fst armed)
  _ -> Nothing

-- | The deadline the displayed notice is waiting out, with the instance it
-- belongs to, when one is armed.
armedNoticeExpiry :: NoticeState -> Maybe (Int, UTCTime)
armedNoticeExpiry state = do
  notice <- state.noticeCurrent
  deadline <- notice.noticeDeadline
  pure (notice.noticeInstance, deadline)

-- | What the footer draws.
currentNotice :: NoticeState -> Maybe Text
currentNotice state = (.noticeText) <$> state.noticeCurrent

-- | The displayed instance's identity, which is what the direct-merge carry
-- compares instead of text ('Kanban.UI.Util.outstandingDirectMergeReport').
currentNoticeInstance :: NoticeState -> Maybe Int
currentNoticeInstance state = (.noticeInstance) <$> state.noticeCurrent

-- | How the displayed notice was classified when it was shown.
currentNoticeLife :: NoticeState -> Maybe NoticeLife
currentNoticeLife state = (.noticeLife) <$> state.noticeCurrent
