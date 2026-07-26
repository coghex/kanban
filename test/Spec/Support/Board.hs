-- | The board refresh cleanup harness.
module Spec.Support.Board
  ( forcedCleanupRun,
    withFakeGh,
    captureBoardRefresh,
    heldOffMessage,
    readMarkerPid
  )
where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import qualified Data.ByteString.Char8 as ByteString
import Data.Text (Text)
import qualified Data.Text
import Kanban.Config
import Kanban.Domain
import Kanban.GitHub (GhCleanupFailure (..), GhCleanupGuard (..))
import Kanban.Process (ProcessIdentity (..), readProcessSnapshot)
import Kanban.UI (BoardRefreshOutcome (..), runBoardRefreshWith)
import Spec.Support.Env (withEnvironmentValue)
import Spec.Support.Fixtures (testOptions, testResolvedConfig)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)
import Test.Hspec

-- | Drives a board refresh in which both facilities the ordinary guards rest
-- on are broken at once: the cache is unwritable, so no durable record can be
-- made, and @ps@ fails, so no kill can be verified. That combination is what
-- forces the last-resort path.
--
-- @psFailures@ is how many @ps@ invocations fail before the real one takes
-- over ('Nothing' fails every one). The fake gh spawns a TERM-ignoring
-- descendant into its own group, so what comes back — the published outcome,
-- and anything of this fixture's still alive once the real @ps@ is back —
-- answers both halves of the question: what the guard claimed, and whether
-- the descendant actually died.
forcedCleanupRun :: FilePath -> Int -> Maybe Int -> IO (BoardRefreshOutcome, [ProcessIdentity])
forcedCleanupRun temporaryRoot githubSeconds psFailures = do
  let unwritableCacheRoot = temporaryRoot </> "cache-is-a-file"
      binaryRoot = temporaryRoot </> "bin"
      psCounter = temporaryRoot </> "ps.count"
  ByteString.writeFile unwritableCacheRoot "not a directory"
  outcome <-
    withEnvironmentValue "XDG_CACHE_HOME" unwritableCacheRoot $
      withFakeGh
        temporaryRoot
        [ "trap '' TERM",
          "sh -c 'trap \"\" TERM; while :; do sleep 1; done' </dev/null >/dev/null 2>&1 &",
          "while :; do sleep 1; done"
        ]
        $ do
          createDirectoryIfMissing True binaryRoot
          ByteString.writeFile
            (binaryRoot </> "ps")
            ( ByteString.unlines
                [ "#!/bin/sh",
                  ByteString.pack ("attempt=$(cat " <> psCounter <> " 2>/dev/null || echo 0)"),
                  "attempt=$((attempt + 1))",
                  ByteString.pack ("printf '%s' \"$attempt\" > " <> psCounter),
                  ByteString.pack ("[ " <> maybe "1 -eq 1" (\n -> "\"$attempt\" -le " <> show n) psFailures <> " ] && exit 1"),
                  "exec /bin/ps \"$@\""
                ]
            )
          setFileMode (binaryRoot </> "ps") 0o700
          fst <$> captureBoardRefresh temporaryRoot githubSeconds
  -- Asked with the real ps, now that the fake is off PATH again.
  snapshot <- readProcessSnapshot
  case snapshot of
    Left message -> fail ("could not snapshot processes: " <> Data.Text.unpack message)
    Right identities ->
      pure (outcome, filter (Data.Text.isInfixOf (Data.Text.pack binaryRoot) . processIdentityCommand) identities)

-- | Puts a shell script named @gh@ first on PATH, so a board refresh drives
-- it instead of the real thing.
withFakeGh :: FilePath -> [ByteString.ByteString] -> IO result -> IO result
withFakeGh temporaryRoot body action = do
  let binaryRoot = temporaryRoot </> "bin"
  createDirectoryIfMissing True binaryRoot
  ByteString.writeFile (binaryRoot </> "gh") (ByteString.unlines ("#!/bin/sh" : body))
  setFileMode (binaryRoot </> "gh") 0o700
  originalPath <- maybe "" id <$> lookupEnv "PATH"
  withEnvironmentValue "PATH" (binaryRoot <> ":" <> originalPath) action

-- | Runs a board refresh against whatever @gh@ is on PATH and reports both
-- the published outcome and the process table as of the exact moment it was
-- published -- the only way to prove an abandoned gh was already gone by
-- then, rather than merely gone by the time an assertion got around to
-- looking.
captureBoardRefresh :: FilePath -> Int -> IO (BoardRefreshOutcome, Either Text [ProcessIdentity])
captureBoardRefresh temporaryRoot githubSeconds = do
  published <- newEmptyMVar
  runBoardRefreshWith
    (\outcome -> readProcessSnapshot >>= putMVar published . (,) outcome)
    testOptions
    testResolvedConfig
      { resolvedCache = False,
        resolvedTimeouts = defaultTimeoutsConfig {timeoutsGithubSeconds = githubSeconds}
      }
    (Repository temporaryRoot "coghex" "kanban")
  takeMVar published

-- | The message from an outcome that declined to fetch, insisting it was
-- reported as an unverified cleanup rather than an ordinary failed refresh.
-- The distinction is the whole point: a refusal means a gh may still be
-- running, so the board has to hold off rather than age into a failure and
-- let the next refresh through.
heldOffMessage :: BoardRefreshOutcome -> IO Text
heldOffMessage (BoardRefreshUnverified failure) = do
  failure.ghCleanupGuard `shouldBe` GuardRecorded
  pure failure.ghCleanupMessage
heldOffMessage other = do
  expectationFailure ("expected the fetch to be held off, got " <> show other)
  pure ""

readMarkerPid :: FilePath -> IO Int
readMarkerPid markerPath = do
  markerText <- readFile markerPath
  pure (read (filter (`notElem` (" \n" :: String)) markerText))
