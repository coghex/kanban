-- | A dashboard state the pure UI transitions can be driven against, with
-- no terminal, network, or GitHub account.
--
-- Every field is a quiet default: nothing in flight. A test names only what it is about by updating the record, which
-- keeps each one readable and keeps a new 'AppState' field from rewriting
-- every test that ever built one.
module Spec.Support.App
  ( testAppState
  )
where

import Brick.BChan (newBChan)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (utc)
import Kanban.Domain
import Kanban.Filter (defaultFilterCriteria)
import Kanban.GitHub (newHistoryTraversal)
import Kanban.UI.Notice (emptyNoticeState)
import Kanban.UI.Types
  ( AppState (..),
    CompletedHistoryStatus (..),
  )
import Kanban.UI.Board (defaultExcerptsVisible, unmeasuredLayoutInputs)
import Spec.Support.Board (inertRefreshCoordinator)
import Spec.Support.Fixtures (epoch, testOptions, testResolvedConfig)

testAppState :: Board -> IO AppState
testAppState board = do
  eventChannel <- newBChan 16
  refreshCoordinator <- inertRefreshCoordinator
  historyTraversal <- newHistoryTraversal
  pure
    AppState
      { appRepository = Repository "/tmp/example-project" "example" "project",
        appBoard = board,
        -- The default criteria admit the open board unchanged, which is what
        -- lets a test that only cares about drawing or dispatch name one
        -- board. A test about the criteria themselves builds both sides with
        -- 'Kanban.UI.Filter.refreshVisibleBoard'.
        appVisibleBoard = board,
        appBoardEpoch = 0,
        -- Unmeasured, so every column draws in full: a test about the windowed
        -- body says so by applying 'Kanban.UI.Board.refreshColumnWindows'.
        appColumnWindows = Map.empty,
        appExpansionEpoch = 0,
        appLayoutEpoch = 0,
        appLayoutInputs = unmeasuredLayoutInputs testOptions testResolvedConfig,
        appFilterCriteria = defaultFilterCriteria,
        appFilterPanel = Nothing,
        appFacetCounts = Nothing,
        appUsage = Map.empty,
        appUsageFreshness = Map.empty,
        appSelectedColumn = Issues,
        appSelectedRows = Map.fromList [(column, 0) | column <- [minBound .. maxBound]],
        appEnsureSelectionVisible = False,
        appExpandedTrackers = Set.empty,
        appSearch = Nothing,
        appSidebarVisible = True,
        appExcerptsVisible = defaultExcerptsVisible,
        appOverlay = Nothing,
        appOverlayFullscreen = False,
        appNotice = emptyNoticeState,
        appBoardFreshness = Fresh epoch,
        appLastBoardRefreshStarted = Nothing,
        appOpenSnapshot = Nothing,
        appLastSuccessfulFetch = Just epoch,
        appOpenGeneration = 0,
        appHistoryTraversal = historyTraversal,
        appCompletedHistory = Nothing,
        appCompletedGeneration = 0,
        appCompletedProgress = emptyCompletedProgress,
        -- Nothing is in flight, so no criteria set is blocked on a traversal:
        -- a test about the completed blocker says so by naming this field.
        appCompletedStatus = CompletedHistoryCurrent,
        appStartupReport = Nothing,
        appBoardRefreshQueued = False,
        appRefreshCoordinator = refreshCoordinator,
        appQuitPending = False,
        appEventChannel = eventChannel,
        appNow = epoch,
        appTimeZone = utc,
        appOptions = testOptions,
        appConfig = testResolvedConfig
      }
