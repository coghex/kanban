-- | What a dashboard does before it is a dashboard: take the repository, bring
-- its durable @gh@ record under the canonical key, and find out who it is.
--
-- "Kanban.Repository.Lease" builds the authority; this composes the three
-- things a board has to have settled before it draws anything, in the one
-- order that is safe:
--
--   1. /The lease first/. Everything below reads and rewrites the repository's
--      durable record, which is precisely what two boards must never do at
--      once. Acquiring last, or acquiring after a refresh had started, would
--      leave the window this authority exists to close.
--   2. /Then the record/. A record written by a release before the canonical
--      key sits at a lossy, case-preserving path, so a board that only ever
--      read the canonical one could spawn @gh@ beside a @gh@ an earlier board
--      recorded and never confirmed dead. Migration happens under the lease
--      and before the first refresh, which is the only interval in which
--      nothing else is writing either file.
--   3. /Then the owner/. Purely so a later message can say whose leftover it
--      is talking about. Failing to capture it is not a failure of anything:
--      the board holds the lease either way.
--
-- Every refusal here is fatal to startup and none of them is negotiable.
-- Proceeding without the lease would restore the defect; proceeding past a
-- record that cannot be read would spawn @gh@ beside one that may still be
-- running. Only contention is reported as another board — 'BoardLeaseUnusable'
-- becomes an unusable-lease diagnostic, never a claim about a board that may
-- not exist.
module Kanban.Repository.Authority
  ( BoardAuthority (..),
    acquireBoardAuthority,
    boardLeaseDiagnostic,
    releaseBoardAuthority,
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Cache (migrateGhGroupRecord, normalizedRepositoryIdentity)
import Kanban.Domain (Repository)
import Kanban.Process (ProcessIdentity, currentProcessIdentity)
import Kanban.Repository.Lease
  ( BoardLeaseOutcome (..),
    RepositoryLease,
    acquireBoardLease,
    releaseRepositoryLease,
  )

-- | One repository, held by this board.
data BoardAuthority = BoardAuthority
  { -- | Held for the process's lifetime. Nothing but the kernel takes it back.
    authorityLease :: RepositoryLease,
    -- | This board, for the entries it goes on to write. 'Nothing' when no
    -- process snapshot could name it, which is informational only.
    authorityOwner :: Maybe ProcessIdentity,
    -- | What went wrong on the way in without threatening a recorded group —
    -- a migrated file that would not unlink is the case there is one of. The
    -- board opens and says so; it does not refuse.
    authorityNotices :: [Text]
  }

-- | Takes the repository, or says why this board may not open on it.
acquireBoardAuthority :: Repository -> IO (Either Text BoardAuthority)
acquireBoardAuthority repository = do
  outcome <- acquireBoardLease repository
  case boardLeaseDiagnostic repository outcome of
    Left message -> pure (Left message)
    Right lease -> do
      migrated <- migrateGhGroupRecord repository
      case migrated of
        -- Given back rather than held. The refusal is this process exiting, so
        -- keeping the lease would cost nothing in this run and would leave the
        -- repository unavailable for the several milliseconds between the
        -- diagnostic and the exit — but releasing it says, in the one place a
        -- reader would look, that a board which never opened holds nothing.
        Left message -> do
          releaseRepositoryLease lease
          pure (Left message)
        Right notices -> do
          owner <- currentProcessIdentity
          pure (Right (BoardAuthority lease owner notices))

-- | Gives the repository back. Only for a board that is finished with it: the
-- kernel does this for a board that dies.
releaseBoardAuthority :: BoardAuthority -> IO ()
releaseBoardAuthority authority = releaseRepositoryLease authority.authorityLease

-- | What one lease outcome means to a user, decided without doing anything.
--
-- Pure so that the one message a second board ever sees can be asserted
-- exactly, rather than inferred from a run that has to stage two processes to
-- produce it. The contention case is the only one that names a PID and the
-- only one that speaks of another board, which is the distinction
-- 'BoardLeaseUnusable' exists to preserve: a cache root that cannot be written
-- must never be reported as somebody else's board.
boardLeaseDiagnostic :: Repository -> BoardLeaseOutcome -> Either Text RepositoryLease
boardLeaseDiagnostic repository outcome = case outcome of
  BoardLeaseAcquired lease -> Right lease
  BoardLeaseContended _ holder ->
    Left
      ( "another Kanban board is already open on "
          <> normalizedRepositoryIdentity repository
          <> " (pid "
          <> Text.pack (show holder)
          <> ").\nClose it before opening another."
      )
  BoardLeaseUnusable path detail ->
    Left
      ( "the board lease at "
          <> Text.pack path
          <> " could not be established ("
          <> detail
          <> "), so this repository cannot be opened"
      )
