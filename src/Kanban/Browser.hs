-- | Handing one URL to whatever opens pages on this machine.
--
-- The board already retains every issue's and pull request's own GitHub URL
-- ('Kanban.Domain.issueUrl', 'Kanban.Domain.pullRequestUrl'), so opening the
-- selected card's page costs no GitHub request and nothing here talks to
-- GitHub at all. What it does is resolve one executable and run it with the
-- URL as its sole argument.
--
-- Three decisions are worth stating, because each is a rule rather than an
-- implementation detail:
--
-- * @$BROWSER@ is /one executable/ — a name to look up along @PATH@, or a
--   path to one. It is never shell syntax, never a list of fallbacks, and
--   never a template a URL is substituted into. An explicitly set value that
--   does not resolve fails as itself rather than quietly falling back to the
--   platform's opener, because a user who set the variable asked for that
--   program; an empty value is an explicit value too.
-- * The URL is one @argv@ element and goes nowhere near a shell, so nothing
--   in it can be read as syntax whatever GitHub returned.
-- * The child gets none of this process's standard streams. An opener that
--   printed would scribble over the board and one that read would take the
--   dashboard's keys, and some of them do both. It gets @\/dev\/null@ on all
--   three rather than nothing at all: @process@'s @NoStream@ /closes/ the
--   descriptor, and an opener that then wrote a warning would be handed
--   @EBADF@ and could exit non-zero over a page that had opened perfectly
--   well.
--
-- Nothing here blocks: 'openPage' returns as soon as it has forked, and the
-- resolution, the spawn, and the wait for the opener to exit all happen on
-- that thread. A successful launch says nothing; every failure is reported
-- with the URL that was launched, so the notice a caller raises names the
-- page the user asked for rather than whatever is selected by the time the
-- opener gives up.
module Kanban.Browser
  ( -- * Which executable
    Opener (..),
    browserVariable,
    platformOpener,
    chooseOpener,
    openerName,

    -- * Running it
    OpenFailure (..),
    openPage,
    openPageWith,
    resolveOpener,
    runOpener,

    -- * Saying what went wrong
    openFailureNotice,
  )
where

import Control.Concurrent (forkIO)
import Control.Exception (IOException, bracket, try)
import Control.Monad (void)
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Text (sanitizeText)
import System.Directory (doesFileExist, executable, findExecutable, getPermissions)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (isPathSeparator)
import System.IO (Handle, IOMode (ReadMode, WriteMode), hClose, openFile)
import qualified System.Info
import System.Process
  ( CreateProcess (..),
    StdStream (UseHandle),
    createProcess,
    proc,
    waitForProcess,
  )

-- | The environment variable that names the user's own opener.
browserVariable :: String
browserVariable = "BROWSER"

-- | Which executable is asked to open a page.
data Opener
  = -- | @$BROWSER@ was set, so its value is the executable — one name or one
    -- path, taken verbatim. An empty value is still an explicitly set one and
    -- is kept here rather than discarded, so 'openFailureNotice' can say that
    -- is what happened.
    ConfiguredOpener Text
  | -- | @$BROWSER@ was unset and this platform has an opener of its own.
    PlatformOpener Text
  | -- | @$BROWSER@ was unset and this platform has no opener Kanban knows.
    NoOpener
  deriving stock (Eq, Show)

-- | The opener a platform supplies, by the name @System.Info.os@ reports for
-- it.
--
-- Takes the operating-system name rather than reading it, which is what lets
-- both branches be checked from either host: the Linux answer is not
-- otherwise reachable from a macOS runner, and a platform that has neither
-- answers 'Nothing' instead of being handed a name that cannot exist there.
platformOpener :: String -> Maybe Text
platformOpener = \case
  "darwin" -> Just "open"
  "linux" -> Just "xdg-open"
  _ -> Nothing

-- | The opener one environment and one platform select, in that order of
-- precedence.
chooseOpener :: Maybe Text -> String -> Opener
chooseOpener (Just configured) _ = ConfiguredOpener configured
chooseOpener Nothing osName = maybe NoOpener PlatformOpener (platformOpener osName)

-- | The executable an opener names, or 'Nothing' when it names none at all.
-- An empty @$BROWSER@ names none, which is why it is not simply the value.
openerName :: Opener -> Maybe Text
openerName = \case
  ConfiguredOpener name | not (Text.null name) -> Just name
  ConfiguredOpener _ -> Nothing
  PlatformOpener name -> Just name
  NoOpener -> Nothing

-- | Why a page did not open. The three shapes are deliberately distinct: an
-- opener that could not be found, one that could not be started, and one that
-- ran and refused.
data OpenFailure
  = -- | Nothing executable answered to the opener's name, or it named none.
    OpenerUnresolved Opener
  | -- | The executable was there and the spawn itself failed.
    OpenerNotStarted Text
  | -- | The opener ran and exited non-zero.
    OpenerRefused ExitCode
  deriving stock (Eq, Show)

-- | Open one URL through this environment's opener, without blocking.
--
-- @report@ is called exactly once, from the forked thread, with 'Nothing' for
-- a clean launch and the failure otherwise. It is handed nothing but that
-- outcome: the URL belongs to the caller, which is what keeps a late failure
-- naming the page it was launched for.
openPage :: Text -> (Maybe OpenFailure -> IO ()) -> IO ()
openPage url report = do
  configured <- lookupEnv browserVariable
  openPageWith (chooseOpener (Text.pack <$> configured) System.Info.os) url report

-- | 'openPage' against an opener chosen by the caller.
--
-- The attempt is guarded as a whole, not only where a failure is expected: a
-- caller has one report to raise a notice from, and an unanticipated 'IOException'
-- anywhere on this thread would otherwise leave the user with a page that did
-- not open and nothing said about it.
openPageWith :: Opener -> Text -> (Maybe OpenFailure -> IO ()) -> IO ()
openPageWith chosen url report =
  void (forkIO (try (attemptPage chosen url) >>= report . either unexpected id))
  where
    unexpected problem = Just (OpenerNotStarted (Text.pack (show (problem :: IOException))))

-- | The whole attempt, on the thread 'openPageWith' forked: resolve, spawn,
-- wait.
attemptPage :: Opener -> Text -> IO (Maybe OpenFailure)
attemptPage chosen url = do
  resolved <- resolveOpener chosen
  either (pure . Just) (`runOpener` url) resolved

-- | Where an opener's executable is, or why it cannot be used.
--
-- A value carrying a path separator is a path and is checked as one; anything
-- else is a bare name looked up along @PATH@. Either way the answer is an
-- executable file that existed a moment ago — nothing can promise more than
-- that, which is why 'runOpener' still reports a spawn that fails anyway.
resolveOpener :: Opener -> IO (Either OpenFailure FilePath)
resolveOpener chosen = case openerName chosen of
  Nothing -> pure (Left (OpenerUnresolved chosen))
  Just name -> maybe (Left (OpenerUnresolved chosen)) Right <$> locateExecutable name

locateExecutable :: Text -> IO (Maybe FilePath)
locateExecutable name
  | Text.any isPathSeparator name = do
      let path = Text.unpack name
      usable <- executableFile path
      pure (if usable then Just path else Nothing)
  | otherwise = findExecutable (Text.unpack name)

-- | Whether @path@ is a file this process may execute. Every way of asking
-- that can fail — the path can vanish between the two questions — and a
-- failure means the same thing as a @False@ here: not something to run.
executableFile :: FilePath -> IO Bool
executableFile path = either (\(_ :: IOException) -> False) id <$> try ask
  where
    ask = do
      present <- doesFileExist path
      if present then executable <$> getPermissions path else pure False

-- | Run one resolved opener against one URL and wait for it to exit. Blocks,
-- which is why only 'attemptPage' calls it.
runOpener :: FilePath -> Text -> IO (Maybe OpenFailure)
runOpener executable url = do
  spawned <- try (withNullStreams spawn)
  case spawned of
    Left problem -> pure (Just (OpenerNotStarted (Text.pack (show (problem :: IOException)))))
    Right handle -> do
      code <- waitForProcess handle
      pure (case code of ExitSuccess -> Nothing; refused -> Just (OpenerRefused refused))
  where
    spawn (input, output, errors) = do
      (_, _, _, handle) <-
        createProcess
          (proc executable [Text.unpack url])
            { std_in = UseHandle input,
              std_out = UseHandle output,
              std_err = UseHandle errors
            }
      pure handle

-- | Three handles on the null device, for the child's three standard streams.
--
-- Held open only across the spawn, which is where they are duplicated into the
-- child; @createProcess@ closes this process's copies itself, so the brackets
-- are covering a spawn that never happened rather than the ordinary path.
withNullStreams :: ((Handle, Handle, Handle) -> IO result) -> IO result
withNullStreams use =
  withNull ReadMode $ \input ->
    withNull WriteMode $ \output ->
      withNull WriteMode $ \errors ->
        use (input, output, errors)
  where
    withNull mode = bracket (openFile nullDevice mode) closeQuietly
    closeQuietly handle = void (try @IOException (hClose handle))

nullDevice :: FilePath
nullDevice = "/dev/null"

-- | What to tell the user about a page that did not open, carrying the URL so
-- it can still be copied out of the notice line.
--
-- Both the URL and the spawn's own diagnostic are external text — one came
-- from GitHub and the other from the operating system — so both are sanitized
-- before they reach a line the dashboard draws.
openFailureNotice :: Text -> OpenFailure -> Text
openFailureNotice url failure = "Could not open " <> sanitizeText url <> " — " <> reason
  where
    reason = case failure of
      OpenerUnresolved NoOpener ->
        "no page opener is known for this platform; set " <> variable <> " to one executable"
      OpenerUnresolved (ConfiguredOpener name)
        | Text.null name -> variable <> " is set to an empty value"
        | otherwise -> variable <> " names " <> quoted name <> ", which is not an executable on PATH"
      OpenerUnresolved (PlatformOpener name) -> quoted name <> " is not an executable on PATH"
      OpenerNotStarted problem -> "the opener could not be started (" <> sanitizeText problem <> ")"
      OpenerRefused (ExitFailure status)
        | status < 0 -> "the opener was killed by signal " <> Text.pack (show (negate status))
        | otherwise -> "the opener exited with status " <> Text.pack (show status)
      OpenerRefused ExitSuccess -> "the opener reported no failure"
    variable = "$" <> Text.pack browserVariable
    quoted name = "`" <> sanitizeText name <> "`"
