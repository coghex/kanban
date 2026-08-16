-- | @kanban --ping BRAND@: the one Kanban action that deliberately submits a
-- model prompt and consumes quota (§14's deliberate-consumption class).
--
-- Everything else that touches a provider is an observer.  The account-status
-- probes behind the sidebar, @u@, @kanban --usage@, @--doctor@, preflight, and
-- release verification submit no prompt at all, and decision D-2 keeps it that
-- way; a ping is the deliberate opposite, and runs only when a user asks for
-- it by name.  Nothing in this module is reachable from any other path.
--
-- The ping itself is not a usage read.  It starts a rolling window, and the
-- window state that answers "what did that buy me?" comes from the ordinary
-- refresh that follows it — routed through "Kanban.Usage" so a configured
-- @[usage.codex]@ or @[usage.claude]@ command replaces the built-in probe here
-- exactly as it does everywhere else.  That external command replaces only the
-- refresh; it never becomes the ping.
module Kanban.Ping
  ( PingBrand (..),
    PingLaunch (..),
    PingMode (..),
    PingResult (..),
    pingArguments,
    pingBrandName,
    pingBrandProvider,
    pingExecutableName,
    pingPrompt,
    ownedGroupToSweep,
    pingResultLines,
    pingResultProblems,
    pingResultSucceeded,
    pingResolvedConfig,
    pingScratchDirectory,
    pingTimeoutMicros,
    resolvePingBrand,
    runPing,
    runPingMode,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, finally, try)
import Control.Monad (unless, void)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Data.Time (TimeZone, UTCTime, getCurrentTime, getCurrentTimeZone)
import Kanban.Cache (UsageCacheLoad (..), loadUsageCache, writeUsageCache)
import Kanban.Claude (claudeEnvironment, claudeScratchDirectory)
import Kanban.Config
  ( RawConfig,
    ResolvedConfig (..),
    TimeoutsConfig (..),
    repositoryIdentity,
    resolveConfig,
    resolveGlobalConfig,
  )
import Kanban.Domain (Repository (..), UsageProvider (..))
import Kanban.Paths (createPrivateDirectory)
import Kanban.Process (ProcessIdentity (..), defaultProcessSnapshot, killVerifiedGroup, membersStillInGroup)
import Kanban.Provider (ProviderError (..))
import Kanban.Usage
  ( UsageOutcome (..),
    UsageReport (..),
    fetchProviderUsage,
    renderUsageReport,
    usageReportProduced,
  )
import System.Directory (XdgDirectory (XdgCache), findExecutable, getXdgDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (NoStream),
    cleanupProcess,
    createProcess,
    getPid,
    proc,
    terminateProcess,
    waitForProcess,
  )
import System.Timeout (timeout)

-- | Which provider a ping is aimed at.  Held apart from 'UsageProvider'
-- because a ping is selected by an argument the user types, and that spelling
-- is a command-line contract rather than an internal enumeration.
data PingBrand = PingCodex | PingClaude
  deriving stock (Eq, Show)

pingBrandProvider :: PingBrand -> UsageProvider
pingBrandProvider PingCodex = Codex
pingBrandProvider PingClaude = Claude

-- | The brand as the user spells it on the command line.
pingBrandName :: PingBrand -> Text
pingBrandName PingCodex = "codex"
pingBrandName PingClaude = "claude"

-- | Turns every @--ping@ occurrence into the one brand to ping, or into the
-- reason there is no such brand.
--
-- A ping is deliberate, so every ambiguous spelling of the request is refused
-- rather than resolved: no occurrence at all, an unknown brand, and more than
-- one occurrence — @--ping codex --ping claude@ and the repeated
-- @--ping codex --ping codex@ alike — are all errors, and the caller launches
-- nothing.  Anything less would let a typo pick a provider and spend quota on
-- it.
resolvePingBrand :: [String] -> Either Text PingBrand
resolvePingBrand [] = Left "--ping requires a brand: codex or claude"
resolvePingBrand [single] = parsePingBrand single
resolvePingBrand _ = Left "--ping accepts one brand and may be supplied only once"

parsePingBrand :: String -> Either Text PingBrand
parsePingBrand "codex" = Right PingCodex
parsePingBrand "claude" = Right PingClaude
parsePingBrand other = Left ("unknown ping brand: " <> Text.pack other <> " (expected codex or claude)")

-- | The one prompt a ping ever sends.  Fixed rather than configurable: its
-- job is to start a window at the smallest defensible cost, and a prompt the
-- user could grow is a prompt whose cost Kanban could not describe.
pingPrompt :: String
pingPrompt = "Reply OK."

pingExecutableName :: PingBrand -> String
pingExecutableName PingCodex = "codex"
pingExecutableName PingClaude = "claude"

-- | The provider invocation, and the thing that distinguishes a ping from the
-- probe that runs beside it: both spawn the same executable, so a recorder
-- tells them apart by these arguments and nothing else.
--
-- Deliberately unlike "Kanban.Solve"'s invocation, which is the shape a ping
-- must not copy: that one runs in the user's repository under
-- @--dangerously-bypass-approvals-and-sandbox@ / @bypassPermissions@ because
-- it is there to change files.  A ping changes nothing, so it asks for the
-- minimum effort each client offers and the most restrictive permissions that
-- still let a model answer.  @--skip-git-repo-check@ is what lets Codex run
-- from the scratch directory below, which is deliberately not a checkout.
--
-- @--print@ is load-bearing beyond producing output: the Claude client
-- documents the workspace-trust dialog as skipped in non-interactive mode, so
-- a ping in a directory the client has never seen answers rather than stalling
-- at a prompt it has no way to reach.
pingArguments :: PingBrand -> [String]
pingArguments PingCodex =
  [ "exec",
    "--sandbox",
    "read-only",
    "--skip-git-repo-check",
    "--config",
    "model_reasoning_effort=\"minimal\"",
    pingPrompt
  ]
pingArguments PingClaude =
  [ "--print",
    "--effort",
    "low",
    "--permission-mode",
    "plan",
    pingPrompt
  ]

-- | A private Kanban-owned directory under the XDG cache root, never the
-- user's repository.
--
-- Claude reuses the probe's own scratch directory rather than getting a fresh
-- one of its own, so the two Kanban-launched Claude processes leave their
-- session state in one place outside the user's project (§14).
--
-- Nothing about the ping's correctness rests on that directory having been
-- used before, and it must not: the very first @kanban --ping claude@ on a
-- cold cache creates this directory itself, so any guarantee that reads "the
-- probe already answered the trust prompt here" would be false exactly when it
-- was needed.  What actually keeps the ping off that prompt is the invocation:
-- @--print@ is non-interactive and the client documents the workspace-trust
-- dialog as skipped in that mode, and 'launchPing' additionally gives the
-- process no input to wait on.
pingScratchDirectory :: PingBrand -> IO FilePath
pingScratchDirectory PingClaude = claudeScratchDirectory
pingScratchDirectory PingCodex = do
  cacheRoot <- getXdgDirectory XdgCache "kanban"
  pure (cacheRoot </> "codex-ping")

-- | The configuration a ping runs under.
--
-- A ping never requires a checkout, so repository resolution is an opportunity
-- rather than a prerequisite: when the caller managed to resolve one — from
-- @--repo@, or from the directory it was invoked in — the ping timeouts obey
-- that repository's @[repositories."owner/name".timeouts]@ override under the
-- ordinary inheritance rules, and when it did not, the global table applies
-- and the run proceeds exactly as before.  Taking the resolution result rather
-- than performing it keeps that failure non-fatal by construction.
pingResolvedConfig :: RawConfig -> Either Text Repository -> ResolvedConfig
pingResolvedConfig rawConfig (Right repository) =
  resolveConfig (repositoryIdentity repository.repositoryOwner repository.repositoryName) rawConfig
pingResolvedConfig rawConfig (Left _) = resolveGlobalConfig rawConfig

-- | The model round trip's own bound.  Separate from the account-status
-- timeouts, which are sized for reading a number rather than for waiting on a
-- model.
pingTimeoutMicros :: PingBrand -> ResolvedConfig -> Int
pingTimeoutMicros PingCodex config = config.resolvedTimeouts.timeoutsPingCodexSeconds * 1000000
pingTimeoutMicros PingClaude config = config.resolvedTimeouts.timeoutsPingClaudeSeconds * 1000000

-- | How far a ping got.  The distinction that matters is whether a process
-- ever ran: one that started may have consumed quota however it ended, and one
-- that never started cannot have.
data PingLaunch
  = -- | The executable was missing, or the spawn itself failed.  Nothing ran.
    PingNotStarted Text
  | PingExited ExitCode
  | -- | Carries the deadline it passed, in whole seconds, so the report can
    -- name the configured bound the user would raise.
    PingTimedOut Int
  deriving stock (Eq, Show)

data PingMode = PingMode
  { pingModeBrand :: PingBrand,
    -- | The effective snapshot-caching decision — @--no-cache@ or a global
    -- @cache = false@ turns it off.  It governs @usage.json@ alone: neither
    -- setting suppresses the ping, the refresh, or the printed result, and
    -- persistence that was deliberately switched off is not a failure.
    pingModeCache :: Bool
  }
  deriving stock (Eq, Show)

-- | Everything one run produced, kept apart from how it is printed so the
-- decisions below it — what to show, and what to exit with — stay pure.
data PingResult = PingResult
  { pingResultBrand :: PingBrand,
    pingResultLaunch :: PingLaunch,
    -- | 'Nothing' only when no process ever started, which is the single case
    -- that owes no refresh.
    pingResultRefresh :: Maybe UsageOutcome,
    pingResultCacheError :: Maybe Text,
    pingResultWarnings :: [Text]
  }
  deriving stock (Eq, Show)

-- | One ping, then the one refresh it owes.
--
-- Exactly one refresh follows any process that started, whether it succeeded,
-- exited non-zero, or timed out, because all three may already have spent
-- quota and the user asked to be told what the window looks like now.  A ping
-- that never started is the one case that skips it, and nothing is ever
-- retried: a second attempt would be a second charge the user did not ask for.
runPing :: PingMode -> ResolvedConfig -> IO PingResult
runPing mode config = do
  launch <- launchPing (pingTimeoutMicros brand config) brand
  case launch of
    PingNotStarted _ -> pure (PingResult brand launch Nothing Nothing [])
    _ -> do
      refreshed <- fetchProviderUsage config provider
      (cacheError, warnings) <- persist refreshed
      pure (PingResult brand launch (Just (outcomeOf refreshed)) cacheError warnings)
  where
    brand = mode.pingModeBrand
    provider = pingBrandProvider brand
    -- Merged into whatever is already stored rather than replacing it, so
    -- pinging one brand never drops the other's snapshot; the writer's own
    -- atomic replacement keeps the file from being observed half-written.
    -- Only a live success is written, so a failed refresh leaves the previous
    -- cache exactly as it was.
    persist (Right snapshot)
      | mode.pingModeCache = do
          (existing, warnings) <- loadExisting
          stored <- writeUsageCache (Map.insert provider snapshot existing)
          pure (either Just (const Nothing) stored, warnings)
    persist _ = pure (Nothing, [])
    loadExisting = do
      load <- loadUsageCache
      pure $ case load of
        UsageCacheAbsent -> (Map.empty, [])
        UsageCacheInvalid message -> (Map.empty, [message])
        UsageCacheLoaded snapshots -> (snapshots, [])
    outcomeOf = either (UsageFailed . (.providerErrorMessage)) UsageAvailable

launchPing :: Int -> PingBrand -> IO PingLaunch
launchPing timeoutMicros brand = do
  scratchDirectory <- pingScratchDirectory brand
  createPrivateDirectory XdgCache scratchDirectory
  environment <- pingEnvironment brand
  found <- findExecutable (pingExecutableName brand)
  case found of
    Nothing -> pure (PingNotStarted (Text.pack (pingExecutableName brand) <> " was not found on PATH"))
    Just executablePath -> do
      -- Only the spawn is inside the 'try'.  An 'IOException' raised after a
      -- process exists would mean a ping that ran, and reporting that as
      -- "never started" would skip the refresh a possibly-charged window is
      -- owed.
      spawned <- try @IOException (createProcess (pingProcess executablePath scratchDirectory environment))
      case spawned of
        Left exception -> pure (PingNotStarted (Text.pack (show exception)))
        Right handles@(_, _, _, processHandle) ->
          awaitPing timeoutMicros processHandle `finally` cleanupProcess handles
  where
    pingProcess executablePath scratchDirectory environment =
      (proc executablePath (pingArguments brand))
        { cwd = Just scratchDirectory,
          env = environment,
          -- No input to wait on, so a client that did somehow ask a question
          -- reads end-of-file and ends rather than holding the whole timeout.
          std_in = NoStream,
          std_out = NoStream,
          std_err = NoStream,
          create_group = True
        }

-- | Claude gets the probe's own hardening — no auto-update, telemetry, prompt
-- history, or @CLAUDE.md@ loading — because a ping runs unattended and should
-- leave no more behind than the probe does.  Codex needs nothing beyond the
-- inherited environment.
pingEnvironment :: PingBrand -> IO (Maybe [(String, String)])
pingEnvironment PingCodex = pure Nothing
pingEnvironment PingClaude = Just <$> claudeEnvironment

-- | Waits out the model round trip, then sweeps the process group Kanban
-- created for this ping — on every path, not only after a timeout.
--
-- The leader exiting is not the same thing as the ping being over. A client
-- that forked a helper leaves it running in that group, still doing model work
-- and still spending the window this command was supposed to bound, whether
-- the leader exited cleanly, exited non-zero, or was terminated. So the sweep
-- is unconditional; when nothing survives it sends no signal at all, because
-- 'killVerifiedGroup' checks membership before each phase.
-- | Waits out the ping and then clears its process group, in that order and
-- never the other way around.
--
-- The leader is deliberately left unreaped until the sweep has run. While this
-- process's own child is unreaped POSIX keeps its pid — and therefore the id of
-- the group it was made to lead — reserved to it, so a census taken in that
-- window provably names only processes Kanban started. Reaping first and
-- reading the group afterwards would leave nothing but a number, which any
-- unrelated group could by then have been given.
awaitPing :: Int -> ProcessHandle -> IO PingLaunch
awaitPing timeoutMicros processHandle = do
  watched <- watchOwnedGroup timeoutMicros processHandle
  case watched of
    PingWatchExited owned -> do
      -- Anything still in the group is a helper outliving its leader and
      -- still spending the window.
      sweepOwnedGroup owned
      PingExited <$> waitForProcess processHandle
    PingWatchOverran owned -> do
      case owned of
        Just _ -> sweepOwnedGroup owned
        -- No census to prove a group by, so fall back to the one signal that
        -- needs no proof: this process's own still-unreaped child, by pid
        -- alone. Leaving an overrunning client running would be worse.
        Nothing -> ignoreIOException (terminateProcess processHandle)
      void (timeout reapTimeoutMicros (waitForProcess processHandle))
      pure (PingTimedOut (timeoutMicros `div` 1000000))

-- | How the wait ended, carrying the census taken while ownership still held.
data PingWatch
  = PingWatchExited (Maybe (Int, [ProcessIdentity]))
  | PingWatchOverran (Maybe (Int, [ProcessIdentity]))

-- | Watches the ping to its end without reaping it, keeping a census of its
-- process group current as it goes.
--
-- The leader's exit is detected from the process snapshot rather than by
-- waiting on the handle, because waiting would reap it and end the ownership
-- guarantee this whole census depends on. A snapshot omits a zombie, so a
-- leader that has exited but not been reaped reads as gone — which is exactly
-- the moment to stop, with a census that still holds every helper it forked.
--
-- The poll backs off from 'minimumPollMicros' to 'maximumPollMicros' so a ping
-- that answers in a second is noticed promptly while a long one costs a
-- handful of snapshots rather than hundreds.
watchOwnedGroup :: Int -> ProcessHandle -> IO PingWatch
watchOwnedGroup timeoutMicros processHandle = do
  maybePid <- getPid processHandle
  case maybePid of
    Nothing -> pure (PingWatchExited Nothing)
    Just pid -> watch (fromIntegral pid) minimumPollMicros timeoutMicros
  where
    watch groupPid interval remaining = do
      snapshotResult <- defaultProcessSnapshot
      case snapshotResult of
        -- Without a snapshot there is no census to signal a group against, so
        -- this degrades to the plain bounded wait rather than guessing.
        Left _ -> do
          finished <- timeout (max 0 remaining) (waitForProcess processHandle)
          pure (maybe (PingWatchOverran Nothing) (const (PingWatchExited Nothing)) finished)
        Right snapshot -> do
          let members = [process | process <- snapshot, process.processIdentityGroupPid == groupPid]
              census = Just (groupPid, members)
          if not (any ((== groupPid) . (.processIdentityPid)) members)
            then pure (PingWatchExited census)
            else
              if remaining <= 0
                then pure (PingWatchOverran census)
                else do
                  let slept = min interval remaining
                  threadDelay slept
                  watch groupPid (min maximumPollMicros (interval * 2)) (remaining - slept)

ignoreIOException :: IO () -> IO ()
ignoreIOException action = void (try @IOException action)

minimumPollMicros, maximumPollMicros :: Int
minimumPollMicros = 100 * 1000
maximumPollMicros = 2 * 1000 * 1000

-- | Which processes a sweep may verify against, or none at all when this group
-- can no longer be proven to be Kanban's.
--
-- Ownership is re-established from the pinned identities, never from the group
-- id alone: at least one process pinned while the leader was unreaped must
-- still be in this group, with the same pid and start time. A group that
-- emptied and had its id reissued to an unrelated process group matches
-- nothing, so that group is never signalled — which is the point, since by
-- then the numeric id says nothing about who owns it.
--
-- Once that proof holds the group is provably the original, so the rest of its
-- current membership is added: joining an existing group takes being a child
-- of one of its members, so those are Kanban's too, and they are exactly the
-- helpers forked after the pin that a sweep verified against the pinned list
-- alone would signal but never confirm dead.
ownedGroupToSweep :: Int -> [ProcessIdentity] -> [ProcessIdentity] -> [ProcessIdentity]
ownedGroupToSweep groupPid pinned snapshot
  | null (membersStillInGroup groupPid snapshot pinned) = []
  | otherwise = pinned <> [process | process <- currentMembers, process `notElem` pinned]
  where
    currentMembers = [process | process <- snapshot, process.processIdentityGroupPid == groupPid]

sweepOwnedGroup :: Maybe (Int, [ProcessIdentity]) -> IO ()
sweepOwnedGroup Nothing = pure ()
sweepOwnedGroup (Just (groupPid, pinned)) = do
  snapshotResult <- defaultProcessSnapshot
  case snapshotResult of
    Left _ -> pure ()
    Right snapshot -> do
      let members = ownedGroupToSweep groupPid pinned snapshot
      unless (null members) (void (killVerifiedGroup groupPid members))

reapTimeoutMicros :: Int
reapTimeoutMicros = 2 * 1000 * 1000

-- | The refreshed window state, including every returned window's end time.
--
-- Rendered by the same pure function @kanban --usage@ and the sidebar use, so
-- one run's report cannot describe a window differently from the next.
pingResultLines :: TimeZone -> UTCTime -> PingResult -> [Text]
pingResultLines zone now result =
  maybe [] (renderUsageReport zone now . singleReport result.pingResultBrand) result.pingResultRefresh

-- | What went wrong, in the user's terms.  A refresh failure is absent here on
-- purpose: 'pingResultLines' already prints it as that provider's own line.
pingResultProblems :: PingResult -> [Text]
pingResultProblems result = launchProblem result.pingResultLaunch <> cacheProblem
  where
    brandName = pingBrandName result.pingResultBrand
    launchProblem (PingExited ExitSuccess) = []
    launchProblem (PingNotStarted message) =
      ["the " <> brandName <> " ping could not be started (" <> message <> "); no usage refresh ran"]
    launchProblem (PingExited (ExitFailure code)) =
      [ "the "
          <> brandName
          <> " ping exited "
          <> Text.pack (show code)
          <> "; it may already have consumed quota, so the window below was refreshed anyway"
      ]
    launchProblem (PingTimedOut seconds) =
      [ "the "
          <> brandName
          <> " ping timed out after "
          <> Text.pack (show seconds)
          <> " seconds; it may already have consumed quota, so the window below was refreshed anyway"
      ]
    cacheProblem = maybe [] (\message -> ["the usage cache was not updated: " <> message]) result.pingResultCacheError

-- | The command's exit status.  Every failure the run can carry is fatal, and
-- independently so: a ping that failed stays a failure even when the refresh
-- that followed it succeeded, and a refresh that was printed still fails the
-- command when it could not be stored.
pingResultSucceeded :: PingResult -> Bool
pingResultSucceeded result =
  launched result.pingResultLaunch
    && maybe False refreshed result.pingResultRefresh
    && null result.pingResultCacheError
  where
    launched (PingExited ExitSuccess) = True
    launched _ = False
    refreshed outcome = usageReportProduced (singleReport result.pingResultBrand outcome)

singleReport :: PingBrand -> UsageOutcome -> UsageReport
singleReport brand outcome = UsageReport [(pingBrandProvider brand, outcome)]

-- | The whole run-and-exit mode, returning whether it succeeded so the caller
-- can set the exit status.
--
-- Diagnostics and warnings go to standard error, leaving standard output
-- carrying the refreshed window state alone.
runPingMode :: PingMode -> ResolvedConfig -> IO Bool
runPingMode mode config = do
  result <- runPing mode config
  mapM_ (\warning -> hPutStrLn stderr ("kanban: warning: " <> Text.unpack warning)) result.pingResultWarnings
  mapM_ (\problem -> hPutStrLn stderr ("kanban: " <> Text.unpack problem)) (pingResultProblems result)
  zone <- getCurrentTimeZone
  now <- getCurrentTime
  mapM_ TextIO.putStrLn (pingResultLines zone now result)
  pure (pingResultSucceeded result)
