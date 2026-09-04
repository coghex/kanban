{-# LANGUAGE OverloadedStrings #-}

-- | Whether a launch's recorded target still holds, asked at the moment the
-- work it authorized is about to begin (issue #595, requirement 8).
--
-- Its own module because two boundaries need it and neither may import the
-- other: the persistent worker starts a solve or pull-request session, and the
-- repository review host starts a canonical review or a revision. Both act on
-- a target some earlier process checked and then wrote down, and both are the
-- last instant Kanban controls before an agent begins mutating that target.
--
-- The rule is fail-closed in both directions, and the failed-read half is the
-- one worth stating. Requirement 8 permits the mutation /only if/ the exact
-- recorded precondition still holds, and a target that cannot be read has not
-- been shown to hold anything; nothing downstream carries the expectation to a
-- later check, so starting the session anyway would be acting on a plan nobody
-- has verified since the launch.
--
-- The two refusals stay distinct because they call for different repairs: a
-- moved target is replanned against a new reading, an unreadable one is waited
-- on. Collapsing them would send the first repair to the second problem.
--
-- This module is internal — "Kanban.Worker" re-exports it.
module Kanban.Worker.Precondition
  ( preconditionStillHolds,
    workerStaleTargetReason,
    workerUnverifiedTargetReason,
    workerPreconditionRefusal,
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Domain
  ( TargetPrecondition (..),
    targetPreconditionHolds,
    targetPreconditionMessage,
  )
import Kanban.GitHub.Guard (newGhFetchGuard, newGhRecordLock)
import Kanban.GitHub.Precondition (observeTargetPrecondition)
import Kanban.Provider (ProviderError (..))
import Kanban.Worker.Types (WorkerSpec (..))

-- | The recorded expectation reread against live GitHub, or 'Nothing' when
-- there is nothing to check or it still holds.
--
-- A specification that recorded no expectation checks nothing and reads
-- nothing: a dashboard press acts on the item the operator is looking at and
-- has nothing older to be stale against.
preconditionStillHolds :: WorkerSpec -> IO (Maybe Text)
preconditionStillHolds spec = case spec.workerExpectedTarget of
  Nothing -> pure Nothing
  Just expected -> do
    recordLock <- newGhRecordLock
    guard <- newGhFetchGuard recordLock
    observed <- observeTargetPrecondition guard spec.workerRepository expected.preconditionItem
    pure $ case observed of
      Left failure -> Just (workerUnverifiedTargetReason <> ": " <> failure.providerErrorMessage)
      Right live
        | targetPreconditionHolds expected live -> Nothing
        | otherwise -> Just (workerStaleTargetReason <> ": " <> targetPreconditionMessage expected live)

-- | The canonical opening of the sentence a worker refuses its turn with when
-- its recorded target has demonstrably moved.
--
-- A prefix rather than a whole message, because the reading that moved is what
-- makes the refusal actionable and it differs every time. One spelling, read
-- by 'Kanban.Action.Types.settledWorkerFailure' to type the outcome, so the
-- two cannot drift apart.
workerStaleTargetReason :: Text
workerStaleTargetReason = "the recorded target moved before this turn began"

-- | The same for a target this worker could not read at all.
workerUnverifiedTargetReason :: Text
workerUnverifiedTargetReason = "this launch's recorded target could not be reread, so its precondition is unverified"

-- | Which of the two precondition refusals a settled worker's sentence is, if
-- it is one at all.
workerPreconditionRefusal :: Text -> Maybe Text
workerPreconditionRefusal detail
  | workerStaleTargetReason `Text.isPrefixOf` detail = Just workerStaleTargetReason
  | workerUnverifiedTargetReason `Text.isPrefixOf` detail = Just workerUnverifiedTargetReason
  | otherwise = Nothing
