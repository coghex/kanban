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
-- The read is bounded by @timeouts.github_seconds@, resolved for the
-- repository being read out of the launch's own selected configuration file.
-- This is the last thing standing between a launch and an agent session, and
-- it runs on the supervisor's own thread: a @gh@ that never answers would hold
-- the turn open with nothing started and nothing refused. An overrun is the
-- unreadable refusal, never the moved one -- a read that never answered has
-- shown nothing about the target.
--
-- This module is internal — "Kanban.Worker" re-exports it.
module Kanban.Worker.Precondition
  ( preconditionStillHolds,
    preconditionReadSeconds,
    workerStaleTargetReason,
    workerUnverifiedTargetReason,
    workerPreconditionRefusal,
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Config
  ( ResolvedConfig (..),
    TimeoutsConfig (..),
    defaultTimeoutsConfig,
    loadRawConfig,
    repositoryIdentity,
    resolveConfig,
  )
import Kanban.Domain
  ( Repository (..),
    TargetPrecondition (..),
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
    readSeconds <- preconditionReadSeconds spec
    recordLock <- newGhRecordLock
    guard <- newGhFetchGuard recordLock
    observed <- observeTargetPrecondition guard readSeconds spec.workerRepository expected.preconditionItem
    pure $ case observed of
      Left failure -> Just (workerUnverifiedTargetReason <> ": " <> failure.providerErrorMessage)
      Right live
        | targetPreconditionHolds expected live -> Nothing
        | otherwise -> Just (workerStaleTargetReason <> ": " <> targetPreconditionMessage expected live)

-- | How long this worker's reread may take: @timeouts.github_seconds@,
-- resolved for the repository being read out of the launch's own selected
-- configuration file (issue #645, requirement 3).
--
-- The same setting the board fetch bounds a page with, resolved the same way,
-- because a precondition read is one @gh@ request like any other and a second
-- setting for it would be a second thing to get wrong. The specification is
-- what says which file: 'workerConfigPath' records the @--config@ the launch
-- selected, already absolute, so a detached supervisor started from another
-- directory resolves the same file the dashboard did, and 'Nothing' means the
-- default path exactly as it does everywhere else.
--
-- A configuration that will not load falls back to the shipped default rather
-- than refusing the turn. A malformed file is not evidence about the target,
-- and the failure it would have to be reported as -- an unverified
-- precondition -- is indistinguishable from the network one, while the read it
-- would replace is the unbounded wait this bound exists to prevent.
preconditionReadSeconds :: WorkerSpec -> IO Int
preconditionReadSeconds spec = do
  loaded <- loadRawConfig spec.workerConfigPath
  pure $ case loaded of
    Left _ -> defaultTimeoutsConfig.timeoutsGithubSeconds
    Right (raw, _) -> (resolveConfig identity raw).resolvedTimeouts.timeoutsGithubSeconds
  where
    identity =
      repositoryIdentity spec.workerRepository.repositoryOwner spec.workerRepository.repositoryName

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
