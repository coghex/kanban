-- | Preflight probes and the hermetic fresh machine their scenarios run against.
module Spec.Support.Preflight
  ( isNotAuthenticated,
    isUnknownAuth,
    isUnknownBundle,
    isUnknownVersion,
    readyProviderProbe,
    readyPreflightEnvironment,
    withCodexProbe,
    withClaudeProbe,
    blockedProblems,
    isConflictingBackend,
    isMissingBackend,
    isReadyBackend,
    fullyProvisionedFakes,
    BackendFixture (..),
    withPreflightMachine,
    machineSnapshot,
    probeInvocations,
    allowedProbeInvocations,
    readyCodexFake,
    signedOutCodexFake,
    bundlelessCodexFake,
    readyClaudeFake,
    readyGitHubFake,
    signedOutGitHubFake,
    python3Fake
  )
where

import qualified Data.ByteString.Char8 as ByteString
import Data.List (sortOn)
import Kanban.Preflight
  ( AuthObservation (..),
    BundleObservation (..),
    GitHubObservation (..),
    PreflightAction (..),
    PreflightCheck (..),
    PreflightEnvironment (..),
    PreflightProblem (..),
    PreflightReport (..),
    PreflightStatus (..),
    ProviderProbe (..),
    ReviewBackendObservation (..),
    VersionObservation (..),
    actionReport
  )
import Kanban.Solve (SolverBrand (..))
import Spec.Support.Env (installFakeExecutable, withEnvironmentValue, withTemporaryCacheRoot)
import System.Directory (createDirectoryIfMissing, createFileLink, doesFileExist, listDirectory)
import System.FilePath (takeDirectory, (</>))

isNotAuthenticated :: AuthObservation -> Bool
isNotAuthenticated (AuthNotAuthenticated _) = True
isNotAuthenticated _ = False

isUnknownAuth :: AuthObservation -> Bool
isUnknownAuth (AuthUnknown _) = True
isUnknownAuth _ = False

isUnknownBundle :: BundleObservation -> Bool
isUnknownBundle (BundleUnknown _) = True
isUnknownBundle _ = False

isUnknownVersion :: VersionObservation -> Bool
isUnknownVersion (VersionUnknown _) = True
isUnknownVersion _ = False

readyProviderProbe :: SolverBrand -> ProviderProbe
readyProviderProbe brand =
  ProviderProbe
    { probeBrand = brand,
      probeExecutable = Just "/fixture/bin/agent",
      probeVersion = VersionSupported "9.9.9",
      probeAuth = AuthAuthenticated,
      probeBundle = BundleEnabled
    }

readyPreflightEnvironment :: PreflightEnvironment
readyPreflightEnvironment =
  PreflightEnvironment
    { environmentCodex = readyProviderProbe CodexSolver,
      environmentClaude = readyProviderProbe ClaudeSolver,
      environmentGitHub = GitHubReady,
      environmentReviewBackend = ReviewBackendReadyAt "/fixture/approve_issues.py"
    }

withCodexProbe :: ProviderProbe -> PreflightEnvironment
withCodexProbe probe = readyPreflightEnvironment {environmentCodex = probe}

withClaudeProbe :: ProviderProbe -> PreflightEnvironment
withClaudeProbe probe = readyPreflightEnvironment {environmentClaude = probe}

blockedProblems :: PreflightEnvironment -> PreflightAction -> [PreflightProblem]
blockedProblems environment action =
  [ problem
    | check <- (actionReport environment action).reportChecks,
      PreflightBlocked problem _ _ <- [check.checkStatus]
  ]

isConflictingBackend :: ReviewBackendObservation -> Bool
isConflictingBackend (ReviewBackendConflicting _ _) = True
isConflictingBackend _ = False

isMissingBackend :: ReviewBackendObservation -> Bool
isMissingBackend (ReviewBackendMissing _) = True
isMissingBackend _ = False

isReadyBackend :: ReviewBackendObservation -> Bool
isReadyBackend (ReviewBackendReadyAt _) = True
isReadyBackend _ = False

-- | Every executable a fully provisioned machine resolves, so a backend
-- scenario is only ever about the backend.
fullyProvisionedFakes :: [(String, [ByteString.ByteString])]
fullyProvisionedFakes = [readyCodexFake, readyClaudeFake, readyGitHubFake, python3Fake]

-- | What the Kanban-managed canonical review backend's install directory
-- holds on the fresh machine a scenario probes. Only 'BackendInstalled' is
-- what @tools\/install_issue_review.py@ actually produces: a symlink, per
-- installed asset, to a checkout file carrying that asset's identity
-- marker. Every other constructor is a state setup would refuse.
data BackendFixture
  = BackendInstalled
  | BackendMissing
  | BackendOccupied
  | BackendOrdinaryFile
  | BackendDanglingLink
  | BackendForeignLink
  | BackendCompanionMissing

-- | A hermetic fresh machine: a PATH holding only the fake executables the
-- scenario installs, a Kanban install directory it populates, and a log
-- every fake appends its argument vector to so a test can assert nothing
-- beyond a status-only probe was ever run. No credentials, network access,
-- or model call is involved.
withPreflightMachine ::
  [(String, [ByteString.ByteString])] ->
  BackendFixture ->
  (FilePath -> FilePath -> IO result) ->
  IO result
withPreflightMachine executables backend action =
  withTemporaryCacheRoot $ \temporaryRoot -> do
    let binaryRoot = temporaryRoot </> "bin"
        installRoot = temporaryRoot </> "issue-review"
        workingDirectory = temporaryRoot </> "repo"
        probeLog = temporaryRoot </> "probes.log"
        backendPath = installRoot </> "approve_issues.py"
    mapM_ (createDirectoryIfMissing True) [binaryRoot, installRoot, workingDirectory]
    mapM_ (installFakeExecutable binaryRoot) executables
    let installAsset name = do
          let checkoutFile = temporaryRoot </> ("checkout-" <> name)
          ByteString.writeFile
            checkoutFile
            (ByteString.pack ("# kanban-managed-asset:issue-review/" <> name <> "\n"))
          createFileLink checkoutFile (installRoot </> name)
        installCompanion = installAsset "kanban_config.py"
    case backend of
      BackendInstalled -> installAsset "approve_issues.py" >> installCompanion
      BackendMissing -> pure ()
      BackendOccupied -> createDirectoryIfMissing True backendPath >> installCompanion
      BackendOrdinaryFile -> ByteString.writeFile backendPath "#!/usr/bin/env python3\n" >> installCompanion
      BackendDanglingLink -> createFileLink (temporaryRoot </> "gone.py") backendPath >> installCompanion
      BackendForeignLink -> do
        -- A perfectly good script that simply is not Kanban's: readable,
        -- resolvable, and sitting under a plausible tools/ path.
        let foreign_ = temporaryRoot </> "elsewhere" </> "tools"
        createDirectoryIfMissing True foreign_
        ByteString.writeFile (foreign_ </> "approve_issues.py") "#!/usr/bin/env python3\nprint('not kanban')\n"
        createFileLink (foreign_ </> "approve_issues.py") backendPath
        installCompanion
      BackendCompanionMissing -> installAsset "approve_issues.py"
    withEnvironmentValue "PATH" binaryRoot $
      withEnvironmentValue "KANBAN_ISSUE_REVIEW_INSTALL_DIR" installRoot $
        withEnvironmentValue "KANBAN_TEST_PROBE_LOG" probeLog $
          action workingDirectory probeLog

-- | Everything on the fresh machine a probe could have written to,
-- snapshotted so a test can prove the doctor path changed none of it.
machineSnapshot :: FilePath -> IO [(FilePath, [FilePath])]
machineSnapshot workingDirectory = do
  let temporaryRoot = takeDirectory workingDirectory
  mapM
    (\name -> (,) name . sortOn id <$> listDirectory (temporaryRoot </> name))
    ["bin", "issue-review", "repo"]

probeInvocations :: FilePath -> IO [String]
probeInvocations probeLog = do
  present <- doesFileExist probeLog
  if present then lines <$> readFile probeLog else pure []

-- | Exactly the status-only argument vectors 'gatherPreflightEnvironment'
-- is allowed to run. Anything else — an agent session, a login flow, a
-- write — would show up here as an unrecognized invocation.
allowedProbeInvocations :: [String]
allowedProbeInvocations =
  ["--version", "login status", "auth status", "plugin list --json"]

readyCodexFake :: (String, [ByteString.ByteString])
readyCodexFake =
  ( "codex",
    [ "case \"$*\" in",
      "  '--version') printf 'codex-cli 0.144.6\\n' ;;",
      "  'login status') printf 'Logged in using ChatGPT\\n' ;;",
      "  'plugin list --json') printf '%s\\n' '{\"installed\":[{\"pluginId\":\"kanban@kanban\",\"installed\":true,\"enabled\":true}]}' ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

signedOutCodexFake :: (String, [ByteString.ByteString])
signedOutCodexFake =
  ( "codex",
    [ "case \"$*\" in",
      "  '--version') printf 'codex-cli 0.144.6\\n' ;;",
      "  'login status') printf 'Not logged in\\n'; exit 1 ;;",
      "  'plugin list --json') printf '%s\\n' '{\"installed\":[{\"pluginId\":\"kanban@kanban\",\"installed\":true,\"enabled\":true}]}' ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

bundlelessCodexFake :: (String, [ByteString.ByteString])
bundlelessCodexFake =
  ( "codex",
    [ "case \"$*\" in",
      "  '--version') printf 'codex-cli 0.144.6\\n' ;;",
      "  'login status') printf 'Logged in using ChatGPT\\n' ;;",
      "  'plugin list --json') printf '%s\\n' '{\"installed\":[]}' ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

readyClaudeFake :: (String, [ByteString.ByteString])
readyClaudeFake =
  ( "claude",
    [ "case \"$*\" in",
      "  '--version') printf '2.1.220 (Claude Code)\\n' ;;",
      "  'auth status') printf '%s\\n' '{\"loggedIn\": true}' ;;",
      "  'plugin list --json') printf '%s\\n' '[{\"id\":\"kanban@kanban\",\"enabled\":true}]' ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

readyGitHubFake :: (String, [ByteString.ByteString])
readyGitHubFake =
  ( "gh",
    [ "case \"$*\" in",
      "  'auth status') printf 'Logged in to github.com\\n' ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

signedOutGitHubFake :: (String, [ByteString.ByteString])
signedOutGitHubFake =
  ( "gh",
    [ "case \"$*\" in",
      "  'auth status') printf 'You are not logged into any GitHub hosts\\n'; exit 1 ;;",
      "  *) exit 1 ;;",
      "esac"
    ]
  )

-- | Only ever resolved, never run: the canonical review backend's
-- interpreter has to exist for the backend check to be about the backend.
python3Fake :: (String, [ByteString.ByteString])
python3Fake = ("python3", ["exit 0"])
