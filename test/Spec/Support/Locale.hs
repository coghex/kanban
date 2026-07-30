-- | The C\/POSIX locale probe.
--
-- The @gh@ path is supposed to be independent of the environment's locale,
-- and that cannot be asserted from inside a test process that was started
-- under a UTF-8 one. GHC fixes the locale encoding at startup from
-- @setlocale@, so exporting @LC_ALL=C@ into a fake @gh@'s environment — or
-- even into this process's own — proves nothing: the decoder the suite would
-- exercise was chosen before @main@ ran, and the CI invocation
-- (@.github/workflows/ci.yml@) does not establish a C locale either.
--
-- So the probe re-runs the test binary as a child under @LC_ALL=C@. That
-- child takes the branch in @main@ that leads here instead of to hspec,
-- drives real board refreshes against fake @gh@ executables emitting
-- non-ASCII UTF-8, and writes what it decoded to files as raw bytes. The
-- parent — still under its own ordinary locale — reads those bytes back and
-- makes the assertions. Nothing non-ASCII is ever handed to the child's
-- stdout, which under an ASCII locale would fail on the way out and say
-- nothing about the code under test.
--
-- How much the C locale actually changes is platform-dependent; see
-- 'LocaleProbe' for which platform this reproduces the original failure on
-- and what covers the rest.
module Spec.Support.Locale
  ( LocaleProbe (..),
    localeProbeVariable,
    runLocaleProbe,
    unicodeCheckoutName,
    unicodeFailureText,
    unicodeIssueTitles,
    withLocaleProbe
  )
where

import Control.Monad (unless, void)
import qualified Data.ByteString as ByteString
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text
import qualified Data.Text.Encoding as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import qualified GHC.Foreign
import GHC.IO.Encoding (getFileSystemEncoding, getLocaleEncoding)
import Kanban.Domain (Issue (..), RepoSnapshot (..), Repository (..))
import Kanban.GitHub (GitHubResult (..))
import Kanban.Provider (ProviderError (..))
import Kanban.Repository (resolveRepository)
import Kanban.UI (BoardRefreshOutcome (..))
import Spec.Support.Board (captureBoardRefresh, withFakeGh)
import Spec.Support.Env (withEnvironmentValue)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), withFile)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)

-- | What one C-locale child decoded, carried back to the parent as text the
-- parent decoded itself from bytes the child wrote.
--
-- 'localeProbeRepositoryIdentity' and 'localeProbeRepositoryRoot' come from
-- the second half of the same child: a real checkout whose path is valid
-- UTF-8 the C locale cannot decode, resolved through
-- 'Kanban.Repository.resolveRepository' and then handed back to git as a
-- @-C@ argument. The root is what git answered on that second call, so it
-- is evidence the resolved value still names the checkout rather than
-- merely evidence of what it looked like.
--
-- 'localeProbeEncoding' is recorded rather than asserted, and the reason is
-- worth stating: GHC derives the locale encoding from the environment on
-- Linux — where CI runs, and where a C locale really does hand the old code
-- an ASCII decoder that threw on the first accented title — but hardcodes
-- UTF-8 on Darwin, where no environment can reach it. So this probe
-- reproduces the original failure on the platform the gate runs on and is
-- merely a decoding check on the other, and a failure message that prints the
-- encoding says which of the two it was. What holds the byte-level regression
-- down on every platform is the malformed-byte test beside it, which needs no
-- particular locale to fail.
data LocaleProbe = LocaleProbe
  { localeProbeTitles :: Text,
    localeProbeFailureKind :: Text,
    localeProbeFailureMessage :: Text,
    localeProbeRepositoryIdentity :: Text,
    localeProbeRepositoryRoot :: Text,
    localeProbeLcAll :: Text,
    localeProbeEncoding :: Text
  }
  deriving stock (Eq, Show)

-- | Set on the child and nothing else: its presence is what tells @main@ it
-- is the probe rather than the suite, which is also what stops the child from
-- forking a probe of its own.
localeProbeVariable :: String
localeProbeVariable = "KANBAN_GH_LOCALE_PROBE"

-- | The parent half. Runs the test binary again under a C locale and hands
-- back what it decoded.
withLocaleProbe :: FilePath -> (LocaleProbe -> IO result) -> IO result
withLocaleProbe temporaryRoot action = do
  let probeRoot = temporaryRoot </> "locale-probe"
  createDirectoryIfMissing True probeRoot
  self <- getExecutablePath
  inherited <- getEnvironment
  -- Every locale variable is dropped before the C ones go on, so a machine
  -- that exports LC_CTYPE separately from LANG cannot leave the child in a
  -- UTF-8 locale and quietly turn this into a test of nothing.
  let carried = filter (not . overridden . fst) inherited
      overridden name = "LC_" `isPrefixOf` name || name == "LANG" || name == localeProbeVariable
      childEnvironment = carried <> [("LC_ALL", "C"), ("LC_CTYPE", "C"), ("LANG", "C"), (localeProbeVariable, probeRoot)]
  exitCode <-
    withFile (probeRoot </> "stdout.log") WriteMode $ \outputLog ->
      withFile (probeRoot </> "stderr.log") WriteMode $ \errorLog -> do
        (_, _, _, child) <-
          createProcess
            (proc self [])
              { env = Just childEnvironment,
                std_out = UseHandle outputLog,
                std_err = UseHandle errorLog
              }
        waitForProcess child
  diagnostics <- readProbeBytes (probeRoot </> "stderr.log")
  unless (exitCode == ExitSuccess) $
    fail ("the C-locale probe exited with " <> show exitCode <> ": " <> Data.Text.unpack diagnostics)
  probe <-
    LocaleProbe
      <$> readProbeText probeRoot "titles" diagnostics
      <*> readProbeText probeRoot "failure-kind" diagnostics
      <*> readProbeText probeRoot "failure-message" diagnostics
      <*> readProbeText probeRoot "repository-identity" diagnostics
      <*> readProbeText probeRoot "repository-root" diagnostics
      <*> readProbeText probeRoot "lc-all" diagnostics
      <*> readProbeText probeRoot "encoding" diagnostics
  action probe

-- | The child half, reached from @main@ when 'localeProbeVariable' is set.
-- Assertions deliberately stay in the parent: this only records.
runLocaleProbe :: FilePath -> IO ()
runLocaleProbe probeRoot = do
  let cacheRoot = probeRoot </> "cache"
      successRoot = probeRoot </> "success"
      failureRoot = probeRoot </> "failure"
  mapM_ (createDirectoryIfMissing True) [cacheRoot, successRoot, failureRoot]
  -- Recorded first, so a fixture that failed to hand the child a C locale at
  -- all is reported as exactly that rather than as a passing decode.
  lcAll <- lookupEnv "LC_ALL"
  writeProbeText probeRoot "lc-all" (Data.Text.pack (fromMaybe "" lcAll))
  writeProbeText probeRoot "encoding" . Data.Text.pack . show =<< getLocaleEncoding
  withEnvironmentValue "XDG_CACHE_HOME" cacheRoot $ do
    -- A healthy, authenticated gh answering with non-ASCII issue titles. The
    -- locale-decoding path threw an invalid-byte IOException here and the
    -- board reported the executable as missing.
    successOutcome <-
      withFakeGh successRoot ["printf '%s' '" <> unicodeGraphqlPage <> "'"] $
        fst <$> captureBoardRefresh successRoot 30
    writeProbeText probeRoot "titles" (decodedTitles successOutcome)
    -- The same question of the failure path, whose stderr was converted from
    -- a locale-decoded String before it was ever classified.
    failureOutcome <-
      withFakeGh
        failureRoot
        [ "printf '%s\\n' '" <> unicodeFailureMessage <> "' >&2",
          "exit 1"
        ]
        $ fst <$> captureBoardRefresh failureRoot 30
    let (kind, message) = reportedFailure failureOutcome
    writeProbeText probeRoot "failure-kind" kind
    writeProbeText probeRoot "failure-message" message
  recordRepositoryResolution probeRoot

-- | The repository half of the same child: a real checkout whose path is
-- ordinary UTF-8 the C locale cannot decode, resolved and then put back to
-- work. Handing the resolved root back to git as a @-C@ argument is the
-- part that matters — a root carrying replacement characters would read
-- plausibly and name nothing — so what is recorded is git's own answer
-- about the root, not the root's textual form.
recordRepositoryResolution :: FilePath -> IO ()
recordRepositoryResolution probeRoot = do
  -- Built from bytes, because a C-locale child cannot write a non-ASCII
  -- FilePath literal at all: its own encoder would refuse it on the way out.
  checkout <- pathFromBytes (TextEncoding.encodeUtf8 (Data.Text.pack probeRoot) <> unicodeCheckoutSuffix)
  createDirectoryIfMissing True checkout
  mapM_
    (runGitFixture Inherit checkout)
    [ ["init", "--quiet"],
      ["remote", "add", "origin", "https://github.com/coghex/kanban.git"]
    ]
  resolved <- resolveRepository (Data.Text.pack "origin") checkout Nothing
  case resolved of
    Left message -> do
      writeProbeText probeRoot "repository-identity" ("unresolved: " <> message)
      writeProbeText probeRoot "repository-root" Data.Text.empty
    Right repository -> do
      writeProbeText probeRoot "repository-identity" (repository.repositoryOwner <> "/" <> repository.repositoryName)
      withFile (probeRoot </> "repository-root") WriteMode $ \sink ->
        runGitFixture (UseHandle sink) repository.repositoryRoot ["rev-parse", "--show-toplevel"]

runGitFixture :: StdStream -> FilePath -> [String] -> IO ()
runGitFixture sink path arguments = do
  (_, _, _, child) <- createProcess (proc "git" (["-C", path] <> arguments)) {std_out = sink}
  void (waitForProcess child)

-- | Bytes to the 'FilePath' GHC itself would produce for them, through the
-- very filesystem encoding 'System.Process' encodes a path back out with.
pathFromBytes :: ByteString.ByteString -> IO FilePath
pathFromBytes bytes = do
  encoding <- getFileSystemEncoding
  ByteString.useAsCStringLen bytes (GHC.Foreign.peekCStringLen encoding)

-- | An outcome that is not a decoded snapshot is recorded verbatim rather
-- than dropped, so the parent's mismatch names what actually happened.
decodedTitles :: BoardRefreshOutcome -> Text
decodedTitles (BoardRefreshCompleted (Right result)) =
  Data.Text.intercalate "\n" (map issueTitle result.githubSnapshot.snapshotIssues)
decodedTitles other = "unexpected outcome: " <> Data.Text.pack (show other)

reportedFailure :: BoardRefreshOutcome -> (Text, Text)
reportedFailure (BoardRefreshCompleted (Left providerError)) =
  (Data.Text.pack (show providerError.providerErrorKind), providerError.providerErrorMessage)
reportedFailure other = ("unexpected outcome", Data.Text.pack (show other))

writeProbeText :: FilePath -> FilePath -> Text -> IO ()
writeProbeText probeRoot name = ByteString.writeFile (probeRoot </> name) . TextEncoding.encodeUtf8

readProbeText :: FilePath -> FilePath -> Text -> IO Text
readProbeText probeRoot name diagnostics = do
  let path = probeRoot </> name
  written <- doesFileExist path
  unless written $
    fail ("the C-locale probe recorded no " <> name <> ": " <> Data.Text.unpack diagnostics)
  readProbeBytes path

-- | Read as bytes and decoded here, never through 'readFile': the parent's
-- own locale must not get a say in what the child is judged to have decoded.
readProbeBytes :: FilePath -> IO Text
readProbeBytes path = TextEncoding.decodeUtf8With lenientDecode <$> ByteString.readFile path

-- | Titles carrying accented Latin, an em dash and a non-Latin script, none
-- of which survive a C-locale decode. Written as escapes so the fixture says
-- exactly which code points it means regardless of how this file is read.
unicodeIssueTitles :: [Text]
unicodeIssueTitles =
  [ Data.Text.pack "Caf\233 refresh \8212 na\239ve decode",
    Data.Text.pack "\1055\1088\1080\1074\1077\1090 \955 \8730"
  ]

-- | A checkout directory named the way a great many really are: accented
-- Latin, valid UTF-8, and undecodable under a C locale.
unicodeCheckoutName :: Text
unicodeCheckoutName = Data.Text.pack "caf\233-checkout"

unicodeCheckoutSuffix :: ByteString.ByteString
unicodeCheckoutSuffix = TextEncoding.encodeUtf8 ("/" <> unicodeCheckoutName)

-- | A refusal gh reports in a non-ASCII language, carrying one of the phrases
-- 'Kanban.GitHub.classifyFailure' recognizes. That phrase is ASCII, so what
-- the assertion on the message proves is the decoding: a locale-decoded stderr
-- never reached the classifier at all, it threw.
unicodeFailureText :: Text
unicodeFailureText = Data.Text.pack "gh: Bad credentials (HTTP 401) \8212 v\233rifiez le jeton"

unicodeFailureMessage :: ByteString.ByteString
unicodeFailureMessage = TextEncoding.encodeUtf8 unicodeFailureText

-- | Two issues whose titles are the ones above, in a page shaped like the one
-- the fetch's GraphQL query asks for.
unicodeGraphqlPage :: ByteString.ByteString
unicodeGraphqlPage =
  TextEncoding.encodeUtf8 . Data.Text.concat $
    [ "{\"data\":{\"repository\":{\"issues\":{\"nodes\":[",
      Data.Text.intercalate "," (zipWith issueNode [41 :: Int, 42] unicodeIssueTitles),
      "],\"pageInfo\":{\"hasNextPage\":false}},",
      "\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}"
    ]
  where
    issueNode number title =
      Data.Text.concat
        [ "{\"number\":",
          Data.Text.pack (show number),
          ",\"title\":\"",
          title,
          "\",\"body\":\"B\",\"url\":\"https://example.test/issues/",
          Data.Text.pack (show number),
          "\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"updatedAt\":\"2026-01-02T00:00:00Z\"}"
        ]
