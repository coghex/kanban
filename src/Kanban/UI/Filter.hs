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
  )
where

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
  | Just settled <- settledInHistory = Just (readOnlyHistoryNotice settled)
  | otherwise = Nothing
  where
    settledInHistory = do
      history <- state.appCompletedHistory
      case item of
        IssueItem issue ->
          IssueItem <$> lookupBy (.issueNumber) issue.issueNumber history.historyIssues
        PullRequestItem pullRequest ->
          PullRequestItem <$> lookupBy (.pullRequestNumber) pullRequest.pullRequestNumber history.historyPullRequests
    lookupBy number target = safeHead . filter ((== target) . number)
    safeHead [] = Nothing
    safeHead (value : _) = Just value
