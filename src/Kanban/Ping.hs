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
    ownedGroupMembers,
    pingArguments,
    pingBrandName,
    pingBrandProvider,
    pingBrandRefusal,
    pingExecutableName,
    pingPrompt,
    pingRepositoryIdentity,
    pingResolvedConfig,
    pingResultLines,
    pingResultProblems,
    pingResultSucceeded,
    pingScratchDirectory,
    pingTimeoutMicros,
    resolvePingBrand,
    runPing,
    runPingMode,
    sweepOwnedGroup,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, finally, try)
import Control.Monad (void)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Data.Word (Word64)
import Data.Time (TimeZone, UTCTime, getCurrentTime, getCurrentTimeZone)
import GHC.Clock (getMonotonicTimeNSec)
import Kanban.Cache (UsageCommit (..), commitUsageSnapshots)
import Kanban.Claude (claudeEnvironment, claudeScratchDirectory)
import Kanban.Config
  ( RawConfig,
    ResolvedConfig (..),
    TimeoutsConfig (..),
    repositoryIdentity,
    resolveConfig,
    resolveGlobalConfig,
    usageSolveRoundEstimates,
  )
import Kanban.Domain (Repository (..), UsageProvider (..))
import Kanban.Models (OperatingMode, providerKey, soleAgent)
import Kanban.Paths (createPrivateDirectory)
import Kanban.Process (ProcessIdentity (..), defaultProcessSnapshot, killVerifiedGroupWith)
import Kanban.Provider (ProviderError (..))
import Kanban.Repository (parseRepositoryName, resolveRepository)
import Kanban.Usage
  ( UsageOutcome (..),
    UsageReport (..),
    fetchProviderUsage,
    renderUsageReport,
    usageProviderFor,
    usageReportProduced,
  )
import System.Directory (XdgDirectory (XdgCache), findExecutable, getXdgDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
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

-- | Why an explicit @--ping BRAND@ cannot run under this operating mode, or
-- 'Nothing' when it may.
--
-- The brand is required and intentionally selected (§5, §14), so a single-agent
-- install that is asked for the provider it does not load refuses rather than
-- redirecting: a ping is the one action that deliberately spends quota, and
-- silently starting a window on the other account would spend it on a request
-- the user did not make and report it under a brand they did not name.
--
-- Both other modes answer 'Nothing'. Dual loads whichever brand was named, and
-- no-agent is already refused ahead of this by
-- 'Kanban.CLI.launchModeRefusal' with the message that names the mode — this
-- says nothing about it rather than restating that refusal in a second
-- vocabulary.
pingBrandRefusal :: OperatingMode -> PingBrand -> Maybe Text
pingBrandRefusal mode brand = do
  provider <- soleAgent mode
  if usageProviderFor provider == pingBrandProvider brand
    then Nothing
    else
      Just
        ( "--ping "
            <> pingBrandName brand
            <> ": model roster loads only "
            <> providerKey provider
            <> ", and a ping starts a window on the brand it is asked for"
            <> " · set by agents in models.toml"
        )

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

-- | Which repository's overrides a ping applies, if any.
--
-- An explicit @--repo@ is an identity in its own right and is read as one,
-- without git and without a checkout.  Resolving it the way the dashboard does
-- would run @git rev-parse@ first and fail outside a repository, quietly
-- dropping the very override the user named — and a ping is a command people
-- run from anywhere, so that is where the flag matters most.
--
-- Only the fallback needs a repository: with no @--repo@, the invoking
-- directory is asked, and its failure is not an error, because a ping must
-- never require a checkout.  A malformed @--repo@ is a different thing from an
-- absent one and is reported rather than ignored.
pingRepositoryIdentity :: Text -> FilePath -> Maybe String -> IO (Either Text (Maybe Text))
pingRepositoryIdentity _ _ (Just explicitRepository) =
  pure (Just . uncurry repositoryIdentity <$> parseRepositoryName (Text.pack explicitRepository))
pingRepositoryIdentity remoteName path Nothing = do
  resolved <- resolveRepository remoteName path Nothing
  pure (Right (either (const Nothing) (Just . identityOf) resolved))
  where
    identityOf repository = repositoryIdentity repository.repositoryOwner repository.repositoryName

-- | The configuration a ping runs under: a repository's own timeout override
-- where 'pingRepositoryIdentity' found one, and the global table otherwise.
pingResolvedConfig :: RawConfig -> Maybe Text -> ResolvedConfig
pingResolvedConfig rawConfig = maybe (resolveGlobalConfig rawConfig) (`resolveConfig` rawConfig)

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
    -- The pinged brand's entry and nothing else is handed over: the stored
    -- map is read, merged, and replaced inside the commit's own lock, so
    -- pinging one brand never drops the other's snapshot -- including one
    -- another Kanban process committed while this refresh was still running.
    -- Only a live success is written, so a failed refresh leaves the previous
    -- cache exactly as it was.
    --
    -- The commit's two halves stay apart here. A failed write is fatal to the
    -- command (section 14); a warning about the file the merge started from is
    -- not, and is reported beside the printed result like any other.
    persist (Right snapshot)
      | mode.pingModeCache = do
          commit <- commitUsageSnapshots (Map.singleton provider snapshot)
          pure (either Just (const Nothing) commit.usageCommitResult, maybe [] (: []) commit.usageCommitWarning)
    persist _ = pure (Nothing, [])
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
          -- A new session rather than merely a new process group. A group
          -- alone would not make its membership an ownership census: any
          -- process in Kanban's own session may join a group of that session
          -- with @setpgid@, and the sweep would then treat it as the ping's.
          -- @setsid@ puts the ping in a session of its own, where the only
          -- processes that can join its group are its own descendants, and
          -- makes it that group's leader so the group id is its pid.
          new_session = True
        }

-- | Claude gets the probe's own hardening — no auto-update, telemetry, prompt
-- history, or @CLAUDE.md@ loading — because a ping runs unattended and should
-- leave no more behind than the probe does.  Codex needs nothing beyond the
-- inherited environment.
pingEnvironment :: PingBrand -> IO (Maybe [(String, String)])
pingEnvironment PingCodex = pure Nothing
pingEnvironment PingClaude = Just <$> claudeEnvironment

-- | Waits out the ping and then clears its process group, in that order and
-- never the other way around.
--
-- The leader exiting is not the same thing as the ping being over: a client
-- that forked a helper leaves it running in that group, still doing model work
-- and still spending the window this command was supposed to bound. So the
-- sweep is unconditional; when nothing survives it sends no signal at all.
--
-- The leader is deliberately left unreaped until the sweep has run. While this
-- process's own child is unreaped POSIX keeps its pid — and therefore the id of
-- the group it was made to lead — reserved to it, so a census taken in that
-- window provably names only processes Kanban started. Reaping first and
-- reading the group afterwards would leave nothing but a number, which any
-- unrelated group could by then have been given.
awaitPing :: Int -> ProcessHandle -> IO PingLaunch
awaitPing timeoutMicros processHandle = do
  exited <- watchOwnedGroup timeoutMicros processHandle
  sweepOwnedGroup processHandle
  if exited
    then PingExited <$> waitForProcess processHandle
    else do
      -- Belt and braces for an overrun: if no snapshot could be taken the
      -- sweep signalled nothing, and this stops Kanban's own unreaped child by
      -- pid, which needs no census to be safe.
      ignoreIOException (terminateProcess processHandle)
      void (timeout reapTimeoutMicros (waitForProcess processHandle))
      pure (PingTimedOut (timeoutMicros `div` 1000000))

-- | Watches the ping to its end without reaping it, reporting whether it ended
-- on its own before the deadline.
--
-- The leader's exit is detected from the process snapshot rather than by
-- waiting on the handle, because waiting reaps it and a reaped leader releases
-- the pid its group is named after. A snapshot omits a zombie, so a leader
-- that has exited but not been reaped reads as gone — which is exactly the
-- moment to stop, with the pid still reserved for the sweep that follows.
--
-- The poll backs off from 'minimumPollMicros' to 'maximumPollMicros' so a ping
-- that answers in a second is noticed promptly while a long one costs a
-- handful of snapshots rather than hundreds.
--
-- Time is measured against a monotonic deadline rather than by subtracting the
-- intervals slept, because the snapshot itself takes time and, worse, can take
-- unbounded time: @ps@ has no deadline of its own, and a hung one would
-- otherwise stop the countdown and hold the ping open past
-- @ping_*_seconds@ — the bound this loop exists to enforce. Every snapshot is
-- therefore bounded by what is left of the deadline.
--
-- A snapshot that cannot be taken is a poll that learned nothing, never a
-- reason to fall back to waiting on the handle: that wait reaps, and a reaped
-- leader takes the group's only ownership proof with it, leaving a helper
-- running with nothing able to prove it may be signalled. So a failing or
-- hanging @ps@ costs responsiveness — a ping that finished early is not
-- noticed until its deadline — rather than costing the cleanup.
watchOwnedGroup :: Int -> ProcessHandle -> IO Bool
watchOwnedGroup timeoutMicros processHandle = do
  maybePid <- getPid processHandle
  case maybePid of
    Nothing -> pure True
    Just pid -> do
      startedAt <- getMonotonicTimeNSec
      watch (fromIntegral pid) startedAt minimumPollMicros
  where
    watch leaderPid startedAt interval = do
      budget <- remainingMicros startedAt
      snapshotResult <- boundedProcessSnapshot budget
      let leaderGone = case snapshotResult of
            Just (Right snapshot) -> not (any ((== leaderPid) . (.processIdentityPid)) snapshot)
            _ -> False
      remaining <- remainingMicros startedAt
      if leaderGone
        then pure True
        else
          if remaining <= 0
            then pure False
            else do
              threadDelay (min interval remaining)
              watch leaderPid startedAt (min maximumPollMicros (interval * 2))

    remainingMicros startedAt = do
      now <- getMonotonicTimeNSec
      pure (timeoutMicros - fromIntegral ((now - startedAt) `div` 1000))

-- | A process snapshot that cannot outlast the deadline it is being taken
-- under. 'Nothing' is "no answer in time", which every caller treats exactly
-- as it treats a snapshot that failed outright.
boundedProcessSnapshot :: Int -> IO (Maybe (Either Text [ProcessIdentity]))
boundedProcessSnapshot budgetMicros
  | budgetMicros <= 0 = pure Nothing
  | otherwise = timeout (min budgetMicros maximumSnapshotMicros) defaultProcessSnapshot

ignoreIOException :: IO () -> IO ()
ignoreIOException action = void (try @IOException action)

minimumPollMicros, maximumPollMicros, maximumSnapshotMicros, blindTerminationGraceMicros, cleanupBudgetMicros :: Int
minimumPollMicros = 100 * 1000
maximumPollMicros = 2 * 1000 * 1000
maximumSnapshotMicros = 5 * 1000 * 1000
blindTerminationGraceMicros = 750 * 1000

-- | The whole cleanup's budget: three bounded snapshots and the escalation's
-- two grace windows, with room to spare. It bounds cleanup alone, not the
-- ping, whose own deadline has already passed by the time this starts.
cleanupBudgetMicros = 12 * 1000 * 1000

-- | Everything a snapshot currently shows in the ping's process group.
--
-- Membership alone is the whole census, deliberately: whoever is in this group
-- is Kanban's, because joining an existing group takes being a child of one of
-- its members, and the ping runs in a session of its own where nothing else
-- could have joined in the first place. That covers a descendant forked at any
-- depth and at any point during the run — including one whose own parent has
-- already exited, which a census pinned earlier would have missed entirely.
--
-- The filter also settles the precondition it rests on rather than assuming
-- it. A process group's id is the pid of its leader, and this asks for the
-- group whose id is the ping's own pid — which, while the ping is unreaped,
-- only the ping can hold. So if the spawn had failed to make it a group
-- leader, no group with that id would exist and this would select nothing,
-- rather than selecting whichever group it had been left in. That is also why
-- there is no separate leadership check here: @getpgid@ refuses an unreaped
-- zombie, which is exactly what the ping is by the time a clean exit is swept.
--
-- What makes reading it by group id sound is /when/ it is read, which
-- 'sweepOwnedGroup' is responsible for.
ownedGroupMembers :: Int -> [ProcessIdentity] -> [ProcessIdentity]
ownedGroupMembers groupPid snapshot =
  [process | process <- snapshot, process.processIdentityGroupPid == groupPid]

-- | Terminates whatever is still in the ping's process group.
--
-- The ownership proof is the handle itself. A group id is the leader's pid,
-- which the leader's own reaping releases, so a group read by id after that
-- point could belong to anything. 'getPid' answers 'Nothing' precisely once
-- the handle has been reaped, so asking it here is not a formality: it is what
-- confines every census to the window in which the kernel still reserves that
-- pid — and with it that group id — to Kanban's own child. Move this call
-- after the wait and it stops signalling rather than starts signalling
-- strangers.
--
-- 'killVerifiedGroup' then re-checks that membership by pid, start time, and
-- current group before each of TERM and KILL, and sends neither when nothing
-- matches.
sweepOwnedGroup :: ProcessHandle -> IO ()
sweepOwnedGroup processHandle = do
  maybePid <- getPid processHandle
  case maybePid of
    Nothing -> pure ()
    Just pid -> do
      let groupPid = fromIntegral pid
      -- One deadline for the whole cleanup, and every process-table read
      -- inside it — this census and each of the escalation's own re-checks —
      -- bounded by what is left of it. Bounding only the first read would
      -- leave a `ps` that answered once and then hung able to hold the
      -- escalation open, and with it the group it was clearing.
      deadlineAt <- cleanupDeadline
      clearOwnedGroup deadlineAt groupPid

-- | Signals the group until a snapshot shows it empty, the deadline runs out,
-- or a read stops answering.
--
-- The repetition is not belt and braces. An escalation verifies against the
-- identities the census handed it, so a member that forks a worker and exits
-- in the moment between the two reads leaves that escalation reporting the
-- group clear — every identity it was told about really is gone — while the
-- worker it never saw carries on. Re-censusing is what closes that, and it is
-- allowed to repeat because the leader is still unreaped throughout, so the
-- group remains just as provably Kanban's on the second read as on the first.
--
-- The deadline is what makes it terminate. A group that kept producing new
-- members would keep this going otherwise; when it expires, the blind
-- termination below takes the group without needing to name anyone in it.
clearOwnedGroup :: Word64 -> Int -> IO ()
clearOwnedGroup deadlineAt groupPid = do
  snapshotResult <- deadlineSnapshot deadlineAt
  case snapshotResult of
    Left _ -> terminateOwnedGroupBlind groupPid
    Right snapshot -> case ownedGroupMembers groupPid snapshot of
      [] -> pure ()
      members -> do
        escalated <- killVerifiedGroupWith (deadlineSnapshot deadlineAt) groupPid members
        case escalated of
          -- Unverified is not the same as clear: a re-check that never
          -- answered leaves the escalation unable to say the group is gone,
          -- so it finishes the job without one.
          Left _ -> terminateOwnedGroupBlind groupPid
          Right () -> do
            now <- getMonotonicTimeNSec
            if now >= deadlineAt
              then terminateOwnedGroupBlind groupPid
              else clearOwnedGroup deadlineAt groupPid

cleanupDeadline :: IO Word64
cleanupDeadline = (+ (fromIntegral cleanupBudgetMicros * 1000)) <$> getMonotonicTimeNSec

-- | A process snapshot bounded by what remains of the cleanup deadline,
-- reported as an ordinary snapshot failure when it runs out — which is what
-- every caller, 'killVerifiedGroupWith' included, already fails closed on.
deadlineSnapshot :: Word64 -> IO (Either Text [ProcessIdentity])
deadlineSnapshot deadlineAt = do
  now <- getMonotonicTimeNSec
  let remaining = if deadlineAt <= now then 0 else fromIntegral ((deadlineAt - now) `div` 1000)
  answered <- boundedProcessSnapshot remaining
  pure (fromMaybe (Left "process snapshot did not answer within the ping cleanup deadline") answered)

-- | Clears the group without a census, for when no process snapshot can be
-- taken at all.
--
-- Verification is what is lost here, not safety: the caller has already
-- established that the leader is unreaped, so this id — its pid — still names
-- either the group Kanban created for it or no group at all, and signalling a
-- group that does not exist does nothing. Without a snapshot there is no way to check who is in it or to
-- confirm they are gone afterwards, so this escalates on a timer rather than
-- on evidence — the one case where a group is signalled unverified, and the
-- alternative is leaving a helper running with no bound at all.
terminateOwnedGroupBlind :: Int -> IO ()
terminateOwnedGroupBlind groupPid = do
  signalOwnedGroup sigTERM
  threadDelay blindTerminationGraceMicros
  signalOwnedGroup sigKILL
  where
    signalOwnedGroup signal = ignoreIOException (signalProcessGroup signal (fromIntegral groupPid))

reapTimeoutMicros :: Int
reapTimeoutMicros = 2 * 1000 * 1000

-- | The refreshed window state, including every returned window's end time.
--
-- Rendered by the same pure function @kanban --usage@ and the sidebar use, so
-- one run's report cannot describe a window differently from the next.  The
-- configured solve-round estimates are passed through for that reason too: a
-- ping that printed a window without the estimate @--usage@ gives it would be
-- exactly the divergence sharing this function exists to rule out.
pingResultLines :: Map UsageProvider Int -> TimeZone -> UTCTime -> PingResult -> [Text]
pingResultLines estimates zone now result =
  maybe [] (renderUsageReport estimates zone now . singleReport result.pingResultBrand) result.pingResultRefresh

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
  mapM_ TextIO.putStrLn (pingResultLines (usageSolveRoundEstimates config.resolvedUsage) zone now result)
  pure (pingResultSucceeded result)
