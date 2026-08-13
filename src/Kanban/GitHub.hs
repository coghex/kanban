-- | The GitHub provider's public surface.
--
-- The implementation lives in the modules below, layered so that each one
-- only depends on the ones under it: 'Kanban.GitHub.Message' (external text),
-- 'Kanban.GitHub.Warnings' (a snapshot's banner lines),
-- 'Kanban.GitHub.Decode' (the GraphQL response), 'Kanban.GitHub.Group'
-- (process-group facts), 'Kanban.GitHub.Guard' (the cleanup verdict and its
-- durable record), 'Kanban.GitHub.Run' (running @gh@), and
-- 'Kanban.GitHub.Fetch' (the snapshot fetch that composes them). This module
-- re-exports what the rest of the build and the suite use, so no call site
-- outside it names an implementation module.
module Kanban.GitHub
  ( -- 'FetchState', 'advanceState', 'classifyFailure', 'compactError' and
    -- 'graphqlArguments' are internal, exported so the suite can assert the
    -- exact argv handed to gh, the way one decoded page advances the fetch,
    -- and how a failed one is classified and reported, all without a live
    -- request.
    FetchState (..),
    GhCleanupFailure (..),
    GhCleanupGuard (..),
    ghBehindBarrier,
    confirmsOwnGroupLeadership,
    groupConfirmedEmpty,
    GhFailurePhase (..),
    GhFetchGuard,
    GhRecordLock,
    GitHubResult (..),
    RateObserver,
    advanceState,
    classifyFailure,
    compactError,
    decodeGitHubItems,
    fetchGitHubSnapshot,
    ghFailureKind,
    ghFetchCleanupFailure,
    graphqlArguments,
    newGhFetchGuard,
    newGhRecordLock,
    paginationDecision,
    reclaimRecordedGhGroups,
    setCleanupFailure,
    snapshotWarnings,

    -- * The repository's refresh coordinator
    CoordinatorNotice (..),
    CoordinatorPlan (..),
    CoordinatorState (..),
    HistoryPageResult (..),
    HistoryRateVerdict (..),
    HoldReason (..),
    JobHold (..),
    OpenRefreshResult (..),
    PendingJob (..),
    RateSample (..),
    RefreshCoordinator,
    RefreshJob (..),
    RefreshRunner (..),
    beginCoordinatorShutdown,
    coordinatorHasWork,
    finishCoordinatorJob,
    foregroundRateReserve,
    historyRateVerdict,
    holdCoordinatorJob,
    initialCoordinatorState,
    newRefreshCoordinator,
    observeRateSample,
    planCoordinator,
    queueCoordinatorJob,
    rateLimitFallbackHold,
    rateLimitHoldUntil,
    rateSampleFromResponse,
    requestRefreshJob,
    shutdownRefreshCoordinator,
    usableRateSample,
  )
where

import Kanban.GitHub.Coordinator
  ( CoordinatorNotice (..),
    CoordinatorPlan (..),
    CoordinatorState (..),
    HistoryPageResult (..),
    HoldReason (..),
    JobHold (..),
    OpenRefreshResult (..),
    PendingJob (..),
    RefreshCoordinator,
    RefreshJob (..),
    RefreshRunner (..),
    beginCoordinatorShutdown,
    coordinatorHasWork,
    finishCoordinatorJob,
    holdCoordinatorJob,
    initialCoordinatorState,
    newRefreshCoordinator,
    observeRateSample,
    planCoordinator,
    queueCoordinatorJob,
    rateLimitFallbackHold,
    rateLimitHoldUntil,
    requestRefreshJob,
    shutdownRefreshCoordinator,
  )
import Kanban.GitHub.Fetch (FetchState (..), GitHubResult (..), RateObserver, advanceState, decodeGitHubItems, fetchGitHubSnapshot, graphqlArguments, paginationDecision)
import Kanban.GitHub.Group (confirmsOwnGroupLeadership, groupConfirmedEmpty)
import Kanban.GitHub.Guard (GhCleanupFailure (..), GhCleanupGuard (..), GhFetchGuard, GhRecordLock, ghFetchCleanupFailure, newGhFetchGuard, newGhRecordLock, reclaimRecordedGhGroups, setCleanupFailure)
import Kanban.GitHub.Message (classifyFailure, compactError)
import Kanban.GitHub.Rate (HistoryRateVerdict (..), RateSample (..), foregroundRateReserve, historyRateVerdict, rateSampleFromResponse, usableRateSample)
import Kanban.GitHub.Run (GhFailurePhase (..), ghBehindBarrier, ghFailureKind)
import Kanban.GitHub.Warnings (snapshotWarnings)
