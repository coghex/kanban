-- | Where the dashboard's filter criteria meet its state: one transition that
-- recomputes the board those criteria admit.
--
-- Every input to 'Kanban.Filter.visibleBoardFor' lives in 'AppState', so this
-- is the single place 'appVisibleBoard' is written. Anything that replaces the
-- open board, the open snapshot, the completed history, or the criteria
-- themselves ends by applying this, and nothing else has to know how the four
-- combine.
module Kanban.UI.Filter
  ( refreshVisibleBoard,
    readOnlyHistoryRefusal,
    readOnlyHistoryRefusalFor,
  )
where

import Data.List (find)
import Data.Text (Text)
import Kanban.Domain
import Kanban.Filter (visibleBoardFor)
import Kanban.Config (ResolvedConfig (..))
import Kanban.UI.Types
import Kanban.Workflow (itemCompleted, readOnlyHistoryNotice)

-- | Recompute what the criteria admit from the datasets currently held.
refreshVisibleBoard :: AppState -> AppState
refreshVisibleBoard state =
  state
    { appVisibleBoard =
        visibleBoardFor
          state.appConfig.resolvedWorkflow
          state.appFilterCriteria
          state.appBoard
          state.appOpenSnapshot
          state.appCompletedHistory
    }

-- | Why a mutating action must decline this item, or 'Nothing' when it may
-- proceed.
--
-- The item a caller holds is not trusted on its own. A details overlay, a
-- solve chooser, and a reusable session can each have been opened while the
-- work was live and still be on screen after a refresh settled it, so the
-- newest completed generation is asked too. That is what makes this safe to
-- call at a launch boundary as well as at the key press that reached it.
readOnlyHistoryRefusal :: AppState -> BoardItem -> Maybe Text
readOnlyHistoryRefusal state item
  | itemCompleted item = Just (readOnlyHistoryNotice item)
  | otherwise = readOnlyHistoryRefusalFor state (itemId item)

-- | The same refusal for work named only by its number.
--
-- A session, a worker, and an overlay's resumable turn are all keyed by the
-- issue or pull-request number rather than by a card, so a launch boundary
-- reached from one of them has nothing but the number to ask with. The answer
-- comes from the newest completed generation either way, which is what makes
-- this the same question 'readOnlyHistoryRefusal' asks.
readOnlyHistoryRefusalFor :: AppState -> ItemId -> Maybe Text
readOnlyHistoryRefusalFor state target = readOnlyHistoryNotice <$> settledItem state target

-- | The item the completed generation holds under this identity, if it holds
-- one at all.
settledItem :: AppState -> ItemId -> Maybe BoardItem
settledItem state target = do
  history <- state.appCompletedHistory
  case target of
    IssueId number ->
      IssueItem <$> find ((== number) . (.issueNumber)) history.historyIssues
    PullRequestId number ->
      PullRequestItem <$> find ((== number) . (.pullRequestNumber)) history.historyPullRequests
