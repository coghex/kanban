-- | Capturing subprocess output as bytes rather than as decoded text.
module Spec.Agent.Capture (spec) where

import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Text
import Kanban.Domain
import Kanban.Preflight
  ( AuthObservation (..),
    GitHubObservation (..),
    PreflightEnvironment (..),
    ProviderProbe (..),
    VersionObservation (..),
    gatherPreflightEnvironment
  )
import Kanban.Process (ProcessIdentity (..), readProcessSnapshot)
import Kanban.Repository (resolveRepository)
import Spec.Support.Env (withFakeOnPath, withTemporaryCacheRoot)
import Spec.Support.Locale (LocaleProbe (..), unicodeCheckoutName, withLocaleProbe)
import Spec.Support.Preflight
  ( BackendFixture (..),
    hangingGitHubFake,
    python3Fake,
    readyClaudeFake,
    readyGitHubFake,
    undecodableCodexFake,
    withPreflightMachine
  )
import System.FilePath ((</>))
import Test.Hspec

spec :: Spec
spec = do
  -- One defect class at the three remaining call sites that captured a
  -- child's output as locale-decoded text: the process census, repository
  -- resolution and the provider preflight probes (issue #172). Each of
  -- these was a healthy child whose output raised an invalid-byte
  -- IOException on the way in, before the call site's own handling of the
  -- exit status ever ran. \377 is illegal UTF-8 under every locale, so the
  -- malformed-byte cases here reproduce the failure without needing one;
  -- the C-locale half of the repository case is in the locale probe, which
  -- has to re-run the test binary to establish a locale at all.
  describe "byte-safe subprocess capture" $ do
    -- A git that answers the two questions 'resolveRepository' asks: where
    -- the checkout is, and what the remote URL is. The URL is a printf
    -- format, so a fixture can put a byte no encoding accepts inside it.
    --
    -- The marker check is the fixture refusing to answer from anywhere but
    -- the checkout. resolveRepository conveys the directory as a cwd rather
    -- than as an argument -- the only channel that survives a path the
    -- locale cannot encode -- and a fixture that simply ignored the
    -- directory would answer just as happily from nowhere in particular.
    let checkoutMarker = "kanban-fixture-checkout"
        gitRemoteFake remoteUrl =
          ( "git",
            [ "[ -f ./" <> ByteString.pack checkoutMarker <> " ] || "
                <> "{ printf 'fake git: not started in the checkout\\n' >&2; exit 9; }",
              "case \"$*\" in",
              "  'rev-parse --show-toplevel') pwd -P ;;",
              "  'remote get-url origin') printf '" <> remoteUrl <> "\\n' ;;",
              "  *) exit 1 ;;",
              "esac"
            ]
          )

    it "keeps a ps row whose command carries an undecodable byte, in its original order" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeOnPath
          temporaryRoot
          ( "ps",
            [ "printf ' 101 100 101 S Mon Jan  1 00:00:01 2026 /usr/bin/first\\n'",
              "printf ' 102 100 101 S Mon Jan  1 00:00:02 2026 /usr/bin/broken-\\377-command\\n'",
              -- A zombie and an unparseable row, both of which the census
              -- already drops: replacement decoding must not start letting
              -- them in.
              "printf ' 103 100 101 Z Mon Jan  1 00:00:03 2026 /usr/bin/zombie\\n'",
              "printf 'ps: this row is not a process\\n'",
              "printf ' 104 100 101 S Mon Jan  1 00:00:04 2026 /usr/bin/last\\n'"
            ]
          )
          $ do
            snapshot <- readProcessSnapshot
            case snapshot of
              Left message -> expectationFailure ("expected a census, got " <> Data.Text.unpack message)
              Right identities -> do
                map processIdentityPid identities `shouldBe` [101, 102, 104]
                map processIdentityCommand identities
                  `shouldBe` [ Data.Text.pack "/usr/bin/first",
                               Data.Text.pack "/usr/bin/broken-\65533-command",
                               Data.Text.pack "/usr/bin/last"
                             ]

    -- The fail-closed contract of issue #10: a census that could not be
    -- taken stays a reported failure and never becomes an empty -- and so
    -- reassuring -- survivor list.
    it "still reports a failing ps as a census failure rather than an empty snapshot" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeOnPath
          temporaryRoot
          ("ps", ["printf '%s\\n' 'ps: illegal option -- q' >&2", "exit 3"])
          $ do
            snapshot <- readProcessSnapshot
            case snapshot of
              Right identities -> expectationFailure ("expected a census failure, got " <> show identities)
              Left message -> do
                Data.Text.unpack message `shouldContain` "ps exited 3"
                Data.Text.unpack message `shouldContain` "illegal option"

    it "hands a remote carrying an undecodable byte to the remote parser" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeOnPath temporaryRoot (gitRemoteFake "https://u\\377ser@github.com/coghex/kanban.git") $ do
          ByteString.writeFile (temporaryRoot </> checkoutMarker) ""
          -- The byte lands in the URL's optional userinfo, which the parser
          -- drops: the identity is decided by the parser on what it was
          -- given, exactly as it would have been for wholly decodable
          -- output.
          result <- resolveRepository "origin" temporaryRoot Nothing
          case result of
            Left message -> expectationFailure ("expected a resolved repository, got " <> Data.Text.unpack message)
            Right repository -> do
              repository.repositoryOwner `shouldBe` "coghex"
              repository.repositoryName `shouldBe` "kanban"

    it "rejects an undecodable remote identity semantically rather than as a git failure" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeOnPath temporaryRoot (gitRemoteFake "https://github.com/coghex/kanb\\377an.git") $ do
          ByteString.writeFile (temporaryRoot </> checkoutMarker) ""
          -- Here the byte lands inside the repository name, which git ran
          -- perfectly well to report. The existing ASCII-only identity rule
          -- still refuses it -- and says so about the remote, not about git.
          result <- resolveRepository "origin" temporaryRoot Nothing
          case result of
            Right repository -> expectationFailure ("expected a rejected remote, got " <> show repository)
            Left message -> do
              Data.Text.unpack message `shouldContain` "cannot derive OWNER/NAME from remote URL"
              Data.Text.unpack message `shouldContain` "kanb\65533an"

    it "preserves a failing git's own diagnostic" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withFakeOnPath
          temporaryRoot
          ("git", ["printf '%s\\n' 'fatal: not a git repository (or any of the parent directories)' >&2", "exit 128"])
          $ do
            result <- resolveRepository "origin" temporaryRoot Nothing
            case result of
              Right repository -> expectationFailure ("expected a git failure, got " <> show repository)
              Left message -> do
                Data.Text.unpack message `shouldContain` "git could not identify a repository"
                Data.Text.unpack message `shouldContain` "fatal: not a git repository"

    -- The condition that cannot be established from in here, for the same
    -- reason the gh probe beside this one re-execs: GHC fixes the locale
    -- encoding before main runs. A repository root is a path rather than a
    -- diagnostic, so what the child proves is that the resolved value still
    -- reaches the real checkout, not merely that it decoded to something.
    it "resolves a repository whose path a C locale cannot decode, and the root still reaches it" $
      withTemporaryCacheRoot $ \temporaryRoot ->
        withLocaleProbe temporaryRoot $ \probe -> do
          probe.localeProbeLcAll `shouldBe` Data.Text.pack "C"
          probe.localeProbeRepositoryIdentity `shouldBe` Data.Text.pack "coghex/kanban"
          -- git's own answer when the resolved root was handed back to it.
          Data.Text.unpack (Data.Text.strip probe.localeProbeRepositoryRoot)
            `shouldEndWith` ("/" <> Data.Text.unpack unicodeCheckoutName)

    it "hands a provider probe's real exit status and replacement-decoded output to the classifier" $
      withPreflightMachine [undecodableCodexFake, readyClaudeFake, readyGitHubFake, python3Fake] BackendInstalled $
        \root _ -> do
          environment <- gatherPreflightEnvironment root
          -- Both classifications are reached only by reading what codex
          -- actually printed and what it actually exited with; a decoder
          -- failure would have replaced each with an unknown.
          environment.environmentCodex.probeVersion `shouldBe` VersionSupported (Data.Text.pack "0.144.6")
          environment.environmentCodex.probeAuth
            `shouldBe` AuthNotAuthenticated (Data.Text.pack "codex login status exited 1 (Not logged in\65533)")

    it "still times out a provider probe that never exits" $
      withPreflightMachine [hangingGitHubFake, python3Fake] BackendInstalled $ \root _ -> do
        environment <- gatherPreflightEnvironment root
        case environment.environmentGitHub of
          GitHubUnknown message -> Data.Text.unpack message `shouldContain` "timed out"
          other -> expectationFailure ("expected a timed-out probe, got " <> show other)
