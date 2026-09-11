-- | @w@, and the page opener behind it (issue #663).
--
-- Two halves, deliberately kept apart. "Kanban.Browser" is asked which
-- executable an environment and a platform select and what running it does,
-- against shell scripts standing in for @open@, @xdg-open@, and a @$BROWSER@
-- of the user's own; the dashboard is asked what the key reaches and what it
-- leaves alone, through brick's own event loop.
--
-- No case here runs a real browser, and the platform half of the choice is
-- checked for both platforms from whichever one the suite is on:
-- 'chooseOpener' takes the operating-system name rather than reading it, and
-- 'openPageWith' takes the opener rather than choosing one, so the Linux
-- answer is reachable from macOS and the other way round.
--
-- Two fixture notes worth stating once:
--
--   * 'Spec.Support.Env.withFakeOnPath' appends the host's own @PATH@, so it
--     can put an executable in front of the real one but can never establish
--     that a name resolves to nothing. Every case here sets @PATH@ to one
--     directory it built instead, which is what makes a missing opener a fact
--     about the fixture rather than about what happens to be installed.
--   * The child's standard streams are asserted through their effects rather
--     than by comparing file descriptors, which a shell cannot portably ask
--     about. An opener reading one to EOF and writing far more than a pipe
--     holds without blocking is exactly what an inherited stream would have
--     cost the dashboard.
module Spec.UI.Browser (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Control.Monad (unless)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import qualified Graphics.Vty as Vty
import Kanban.Browser
  ( OpenFailure (..),
    Opener (..),
    browserVariable,
    chooseOpener,
    openFailureNotice,
    openPage,
    openPageWith,
    openerName,
    platformOpener,
    resolveOpener,
    runOpener,
  )
import Kanban.Domain
import Kanban.Filter (FilterCriteria (..), LifecycleFacet (..))
import Kanban.GitHub (GitHubResult (..))
import Kanban.UI.Events (BoardActionGate (..), blockedByCompletedLoad, boardActionGate, mutatesSelectedWork)
import Kanban.UI.Keys (BoardAction (..), requiresLoadedAgent)
import Kanban.UI.Session (selectedReviewItem)
import Kanban.UI.Types
import Kanban.UI.Util (entriesForBoard, itemUrl, selectedRow, shownNotice)
import Kanban.Workflow (entryItem)
import Spec.Support.App (testAppState)
import Spec.Support.Dashboard (DashboardRun (..), ScriptStep (..), quitStep, runDashboardScript)
import Spec.Support.Env
  ( waitForFileToExist,
    withEnvironmentValue,
    withTemporaryCacheRoot,
    withoutEnvironmentValue,
  )
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch, fixtureBoard)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import qualified System.Info
import qualified System.Posix.Env as Posix
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "opening a card's GitHub page" $ do
  chooserSpec
  openerSpec
  keySpec

-- ---------------------------------------------------------------------------
-- Which executable
-- ---------------------------------------------------------------------------

-- | Requirement 2 and the review's reading of it, as one pure decision.
chooserSpec :: Spec
chooserSpec = describe "choosing the opener" $ do
  it "names the opener each platform supplies, and none for one it does not know" $ do
    platformOpener "darwin" `shouldBe` Just "open"
    platformOpener "linux" `shouldBe` Just "xdg-open"
    sequence_
      [ (osName, platformOpener osName) `shouldBe` (osName, Nothing)
        | osName <- ["mingw32", "freebsd", "openbsd", ""]
      ]

  it "falls to the platform's opener when $BROWSER is unset, on either platform" $ do
    chooseOpener Nothing "darwin" `shouldBe` PlatformOpener "open"
    chooseOpener Nothing "linux" `shouldBe` PlatformOpener "xdg-open"
    chooseOpener Nothing "mingw32" `shouldBe` NoOpener

  -- $BROWSER outranks the platform on every platform, which is what makes the
  -- preference a rule rather than a macOS accident.
  it "prefers $BROWSER wherever it is set" $
    sequence_
      [ (osName, chooseOpener (Just "kanban-test-browser") osName)
          `shouldBe` (osName, ConfiguredOpener "kanban-test-browser")
        | osName <- ["darwin", "linux", "mingw32"]
      ]

  -- The review's clarification. An explicitly set value is the user's answer
  -- whatever it says, so an empty one is kept rather than discarded: it names
  -- no executable, and requirement 4 is what it earns.
  it "keeps an empty $BROWSER as the explicit value it is" $ do
    chooseOpener (Just "") "darwin" `shouldBe` ConfiguredOpener ""
    openerName (ConfiguredOpener "") `shouldBe` Nothing
    openerName NoOpener `shouldBe` Nothing
    openerName (ConfiguredOpener "firefox") `shouldBe` Just "firefox"
    openerName (PlatformOpener "xdg-open") `shouldBe` Just "xdg-open"

  -- A value is one executable: a name or a path, never a command line. Each
  -- of these resolves to nothing rather than being split, expanded, or
  -- substituted into, which is what requirement 4 then reports.
  it "treats $BROWSER as one executable rather than shell syntax" $
    withTemporaryCacheRoot $ \root -> do
      binaries <- fakeBinaries root []
      withEnvironmentValue "PATH" binaries $
        sequence_
          [ do
              outcome <- resolveOpener (ConfiguredOpener value)
              (value, outcome) `shouldBe` (value, Left (OpenerUnresolved (ConfiguredOpener value)))
            | value <-
                [ "firefox %s",
                  "firefox --new-tab",
                  "firefox:chromium",
                  "firefox && chromium",
                  "~/bin/firefox"
                ]
          ]

-- ---------------------------------------------------------------------------
-- Running it
-- ---------------------------------------------------------------------------

openerSpec :: Spec
openerSpec = describe "running the opener" $ do
  -- Both platform branches, run for real against a fake of each name, so
  -- neither is asserted only as a string.
  it "hands the URL to each platform's own opener as its sole argument" $
    withTemporaryCacheRoot $ \root ->
      sequence_
        [ do
            let logPath = root </> ("sole-" <> name)
            binaries <- fakeBinaries root [(name, recordingOpener logPath 0)]
            outcome <- openedWith (PlatformOpener (Text.pack name)) binaries cardUrl
            (name, outcome) `shouldBe` (name, Nothing)
            recordedBy logPath `shouldReturn` [Recorded 1 cardUrl]
          | name <- ["open", "xdg-open"]
        ]

  it "hands a pull request's URL the same way" $
    withTemporaryCacheRoot $ \root -> do
      let logPath = root </> "pull-request"
      binaries <- fakeBinaries root [(hostOpenerName, recordingOpener logPath 0)]
      outcome <- openedOnPath binaries Nothing pullRequestCardUrl
      outcome `shouldBe` Nothing
      recordedBy logPath `shouldReturn` [Recorded 1 pullRequestCardUrl]

  -- The negative control the preference needs: the platform's own opener is
  -- right there on PATH, and is left alone.
  it "runs $BROWSER instead of the platform opener, which stays untouched" $
    withTemporaryCacheRoot $ \root -> do
      let configuredLog = root </> "configured"
          platformLog = root </> "platform"
      binaries <-
        fakeBinaries
          root
          [ ("kanban-test-browser", recordingOpener configuredLog 0),
            (hostOpenerName, recordingOpener platformLog 0)
          ]
      outcome <- openedOnPath binaries (Just "kanban-test-browser") cardUrl
      outcome `shouldBe` Nothing
      recordedBy configuredLog `shouldReturn` [Recorded 1 cardUrl]
      recordedBy platformLog `shouldReturn` []

  -- A path rather than a name, from a directory that is not on PATH at all,
  -- so what resolves it is the path itself.
  it "takes a $BROWSER that is a path to an executable" $
    withTemporaryCacheRoot $ \root -> do
      let logPath = root </> "by-path"
      elsewhere <- fakeBinaries (root </> "elsewhere") [("chosen", recordingOpener logPath 0)]
      empty <- fakeBinaries root []
      outcome <- openedOnPath empty (Just (Text.pack (elsewhere </> "chosen"))) cardUrl
      outcome `shouldBe` Nothing
      recordedBy logPath `shouldReturn` [Recorded 1 cardUrl]

  -- Requirement 4, first shape. PATH holds nothing at all, so this is the
  -- answer for an opener that is genuinely absent rather than merely shadowed.
  it "reports an opener that is not there, and names the URL" $
    withTemporaryCacheRoot $ \root -> do
      empty <- fakeBinaries root []
      outcome <- openedOnPath empty Nothing cardUrl
      outcome `shouldBe` Just (OpenerUnresolved (chooseOpener Nothing System.Info.os))
      noticeFor cardUrl outcome `shouldSatisfy` Text.isInfixOf cardUrl

  it "reports an explicitly empty $BROWSER rather than falling back to the platform's" $
    withTemporaryCacheRoot $ \root -> do
      let platformLog = root </> "platform"
      binaries <- fakeBinaries root [(hostOpenerName, recordingOpener platformLog 0)]
      outcome <- openedOnPath binaries (Just "") cardUrl
      outcome `shouldBe` Just (OpenerUnresolved (ConfiguredOpener ""))
      recordedBy platformLog `shouldReturn` []
      noticeFor cardUrl outcome `shouldSatisfy` Text.isInfixOf "empty value"
      noticeFor cardUrl outcome `shouldSatisfy` Text.isInfixOf cardUrl

  it "reports a $BROWSER that names nothing, and leaves the platform opener alone" $
    withTemporaryCacheRoot $ \root -> do
      let platformLog = root </> "platform"
      binaries <- fakeBinaries root [(hostOpenerName, recordingOpener platformLog 0)]
      outcome <- openedOnPath binaries (Just "kanban-test-absent-opener") cardUrl
      outcome `shouldBe` Just (OpenerUnresolved (ConfiguredOpener "kanban-test-absent-opener"))
      recordedBy platformLog `shouldReturn` []
      noticeFor cardUrl outcome `shouldSatisfy` Text.isInfixOf "kanban-test-absent-opener"

  -- Requirement 4's second shape, and the review's separate case for it. The
  -- executable resolved — which is what makes this a spawn failure rather than
  -- the absence above — and was gone by the time it was run, which is the one
  -- window no amount of checking beforehand can close.
  it "reports a resolved opener that could not be spawned" $
    withTemporaryCacheRoot $ \root -> do
      binaries <- fakeBinaries root [("vanishing", recordingOpener (root </> "never") 0)]
      let vanishing = binaries </> "vanishing"
      resolveOpener (ConfiguredOpener (Text.pack vanishing)) `shouldReturn` Right vanishing
      removeFile vanishing
      outcome <- runOpener vanishing cardUrl
      outcome `shouldSatisfy` spawnFailure
      noticeFor cardUrl outcome `shouldSatisfy` Text.isInfixOf cardUrl
      noticeFor cardUrl outcome `shouldSatisfy` Text.isInfixOf "could not be started"
      recordedBy (root </> "never") `shouldReturn` []

  -- Requirement 4's third shape. The opener ran, so the URL did reach it, and
  -- the notice is owed all the same.
  it "reports an opener that ran and exited non-zero" $
    withTemporaryCacheRoot $ \root -> do
      let logPath = root </> "refused"
      binaries <- fakeBinaries root [(hostOpenerName, recordingOpener logPath 3)]
      outcome <- openedOnPath binaries Nothing cardUrl
      outcome `shouldBe` Just (OpenerRefused (ExitFailure 3))
      recordedBy logPath `shouldReturn` [Recorded 1 cardUrl]
      noticeFor cardUrl outcome `shouldSatisfy` Text.isInfixOf "status 3"
      noticeFor cardUrl outcome `shouldSatisfy` Text.isInfixOf cardUrl

  -- The review's stream requirement, asserted through what an inherited stream
  -- would actually cost: an opener reading the dashboard's input would wait
  -- for a key that never comes, and one writing more than a pipe holds would
  -- block forever on a reader that is busy drawing frames.
  it "gives the opener neither the dashboard's input nor its display" $
    withTemporaryCacheRoot $ \root -> do
      let logPath = root </> "streams"
      binaries <- fakeBinaries root [(hostOpenerName, noisyOpener logPath)]
      outcome <- openedOnPath binaries Nothing cardUrl
      outcome `shouldBe` Nothing
      logLines logPath `shouldReturn` ["stdin=eof", "wrote=512k", "finished"]

-- ---------------------------------------------------------------------------
-- The key
-- ---------------------------------------------------------------------------

keySpec :: Spec
keySpec = describe "the w binding" $ do
  -- The review's classification, as the three total predicates that decide
  -- where a binding is live, and the gate they compose into.
  it "is available without an agent, mutates nothing, and is inert under the blocker" $ do
    requiresLoadedAgent OpenCardPage `shouldBe` False
    mutatesSelectedWork OpenCardPage `shouldBe` False
    blockedByCompletedLoad OpenCardPage `shouldBe` True
    plain <- boardState
    boardActionGate plain OpenCardPage `shouldBe` DispatchBoardAction
    boardActionGate (blockedOnCompletedLoad plain) OpenCardPage `shouldBe` IgnoreBoardAction

  it "opens the selected issue's own page" $
    launching id (`shouldBe` [Recorded 1 cardUrl])

  it "opens the selected pull request's own page" $
    launching (selecting Active) (`shouldBe` [Recorded 1 pullRequestCardUrl])

  -- Requirement 1's epic clause: a collapsed group's row stands for the epic,
  -- so that is the page it opens rather than the child drawn on it.
  it "opens a collapsed epic's own issue" $
    launching (selecting Reviewing) (`shouldBe` [Recorded 1 epicUrl])

  -- The overlay dispatches against what it is showing. The board selection is
  -- deliberately a different card, so a launch that read the selection instead
  -- would open the wrong page rather than the same one twice.
  it "opens the card a details overlay is showing, not the one selected behind it" $
    launching
      (\state -> (selecting Active state) {appOverlay = Just (DetailsOverlay (IssueItem epicIssue))})
      (`shouldBe` [Recorded 1 epicUrl])

  -- The negative control comes with its own positive half, in one example: a
  -- fixture that recorded nothing either way would pass the empty board's
  -- assertion by being broken.
  it "launches nothing at all with no card selected" $
    withTemporaryCacheRoot $ \root -> do
      let logPath = root </> "empty-selection"
      binaries <- fakeBinaries root [(hostOpenerName, recordingOpener logPath 0)]
      populated <- boardState
      _ <- pressingW binaries populated []
      waitForFileToExist logPath 100
      recordedBy logPath `shouldReturn` [Recorded 1 cardUrl]
      empty <- testAppState (fixtureBoard [])
      _ <- pressingW binaries empty []
      -- There is nothing to wait for, so what is waited out is the round trip
      -- the press above has already been seen to take.
      threadDelay 250000
      recordedBy logPath `shouldReturn` [Recorded 1 cardUrl]

  -- Requirement 3, and the review's controlled-slow-opener case for it. The
  -- opener cannot exit until a file appears that nothing creates until the
  -- script has finished, so a script that ran to the end is one that ran while
  -- the opener was still going.
  it "returns before the opener exits, leaving the board and a refresh alone" $
    withTemporaryCacheRoot $ \root -> do
      let logPath = root </> "slow"
          releasePath = root </> "release"
          afterwards = [refreshedTo [401, 402, 403], Press (Vty.EvKey (Vty.KChar 'j') [])]
      binaries <- fakeBinaries root [(hostOpenerName, heldOpener logPath releasePath)]
      state <- boardState
      pressed <- pressingW binaries state afterwards
      -- It started, and with nothing having released it, it has not finished:
      -- every step after the press ran while it was still running.
      waitForFileToExist logPath 100
      logLines logPath `shouldReturn` [cardUrl]
      -- And the dashboard behind it is the one that never pressed the key: the
      -- delivered refresh landed, the selection still moves, and nothing was
      -- said.
      untouched <- boardState >>= \quiet -> runDashboardScript frameRegion id quiet (afterwards <> [quitStep])
      boardShape pressed `shouldBe` boardShape untouched
      boardShape pressed `shouldBe` ([401, 402, 403], 1, Nothing)
      writeFile releasePath ""
      waitForLine logPath "finished" 100

  -- The review's requirement that a late failure name the page it was launched
  -- for. The selection has moved to another card by the time the outcome
  -- arrives, and the notice still names the first one.
  it "names the URL the launch was made for, however the selection has moved" $ do
    state <- boardState
    run <-
      runDashboardScript
        frameRegion
        id
        state
        [ Press (Vty.EvKey (Vty.KChar 'j') []),
          Deliver (PageOpenFinished cardUrl (Just (OpenerUnresolved NoOpener))),
          quitStep
        ]
    itemUrl <$> selectedReviewItem run.runState `shouldBe` Just otherCardUrl
    shownNotice run.runState `shouldBe` Just (openFailureNotice cardUrl (OpenerUnresolved NoOpener))
    shownNotice run.runState `shouldSatisfy` maybe False (Text.isInfixOf cardUrl)
    shownNotice run.runState `shouldSatisfy` maybe False (not . Text.isInfixOf otherCardUrl)

  it "shows nothing at all when the launch finished cleanly" $ do
    state <- boardState
    run <-
      runDashboardScript frameRegion id state [Deliver (PageOpenFinished cardUrl Nothing), quitStep]
    shownNotice run.runState `shouldBe` Nothing

-- ---------------------------------------------------------------------------
-- Driving the opener
-- ---------------------------------------------------------------------------

-- | 'openPage' under a @PATH@ holding exactly @binaries@ and the given
-- @$BROWSER@, waited out. The variable is set or cleared explicitly rather
-- than inherited, so a developer's own @$BROWSER@ decides nothing here.
openedOnPath :: FilePath -> Maybe Text -> Text -> IO (Maybe OpenFailure)
openedOnPath binaries configured url =
  withEnvironmentValue "PATH" binaries $
    withBrowser configured $
      awaitOutcome (openPage url)

-- | 'openPageWith' for an opener the caller named, under the same isolated
-- @PATH@. What it adds over 'openedOnPath' is the platform branch this host is
-- not: @xdg-open@ runs here on macOS because the fixture put it on @PATH@ and
-- the caller asked for it, not because the platform chose it.
openedWith :: Opener -> FilePath -> Text -> IO (Maybe OpenFailure)
openedWith chosen binaries url =
  withEnvironmentValue "PATH" binaries (awaitOutcome (openPageWith chosen url))

-- | One launch, waited out. The report arrives on the thread 'openPage'
-- forked, which is the whole point of it, so it is taken rather than returned
-- — and bounded, so an opener that never reports fails the example instead of
-- hanging the suite.
awaitOutcome :: ((Maybe OpenFailure -> IO ()) -> IO ()) -> IO (Maybe OpenFailure)
awaitOutcome launch = do
  reported <- newEmptyMVar
  launch (putMVar reported)
  settled <- timeout openTimeoutMicros (takeMVar reported)
  maybe (fail "the opener reported no outcome within its bound") pure settled

openTimeoutMicros :: Int
openTimeoutMicros = 30 * 1000 * 1000

-- | Run @action@ with @$BROWSER@ set to exactly @configured@, or cleared.
--
-- Through @setenv(3)@ rather than "System.Environment"'s 'setEnv', which
-- unsets a variable it is handed an empty value for. An explicitly empty
-- @$BROWSER@ is one of the cases requirement 4 covers, so a fixture that
-- could not express one would be asserting the unset case twice.
withBrowser :: Maybe Text -> IO result -> IO result
withBrowser configured action = bracket claim restore (const action)
  where
    claim = Posix.getEnv browserVariable <* apply
    apply = maybe (Posix.unsetEnv browserVariable) (\value -> Posix.setEnv browserVariable (Text.unpack value) True) configured
    restore = maybe (Posix.unsetEnv browserVariable) (\value -> Posix.setEnv browserVariable value True)

noticeFor :: Text -> Maybe OpenFailure -> Text
noticeFor url = maybe "" (openFailureNotice url)

spawnFailure :: Maybe OpenFailure -> Bool
spawnFailure (Just (OpenerNotStarted _)) = True
spawnFailure _ = False

-- ---------------------------------------------------------------------------
-- Driving the key
-- ---------------------------------------------------------------------------

-- | Press @w@ on a board this example arranged, and read back what the fake
-- opener was handed.
launching :: (AppState -> AppState) -> ([Recorded] -> Expectation) -> Expectation
launching arrange check =
  withTemporaryCacheRoot $ \root -> do
    let logPath = root </> "launch"
    binaries <- fakeBinaries root [(hostOpenerName, recordingOpener logPath 0)]
    state <- arrange <$> boardState
    _ <- pressingW binaries state []
    waitForFileToExist logPath 100
    recordedBy logPath >>= check

-- | One scripted dashboard run whose first step is @w@, with @binaries@ the
-- only directory on @PATH@ and @$BROWSER@ cleared.
pressingW :: FilePath -> AppState -> [ScriptStep] -> IO DashboardRun
pressingW binaries state afterwards =
  withEnvironmentValue "PATH" binaries $
    withoutEnvironmentValue browserVariable $
      runDashboardScript
        frameRegion
        id
        state
        ([Press (Vty.EvKey (Vty.KChar 'w') [])] <> afterwards <> [quitStep])

-- | What a run ended up showing: the Issues column's numbers, the row selected
-- in it, and whatever the footer is saying.
boardShape :: DashboardRun -> ([Int], Int, Maybe Text)
boardShape run =
  ( mapMaybe itemNumber (entriesForBoard run.runState.appBoard Issues),
    selectedRow run.runState Issues,
    shownNotice run.runState
  )
  where
    itemNumber entry = case entryItem entry of
      IssueItem issue -> Just issue.issueNumber
      PullRequestItem _ -> Nothing

-- | A finished refresh publishing exactly @numbers@ as standalone issues,
-- which is how a board changes underneath a key press that is still in flight.
refreshedTo :: [Int] -> ScriptStep
refreshedTo numbers =
  Deliver
    ( BoardRefreshFinished
        0
        (BoardRefreshCompleted (Right (GitHubResult (RepoSnapshot (map (`baseIssue` []) numbers) [] epoch) [])))
    )

frameRegion :: (Int, Int)
frameRegion = (140, 44)

-- ---------------------------------------------------------------------------
-- The board these cases press on
-- ---------------------------------------------------------------------------

cardUrl, otherCardUrl, pullRequestCardUrl, epicUrl :: Text
cardUrl = "https://github.test/example/project/issues/901"
otherCardUrl = "https://github.test/example/project/issues/902"
pullRequestCardUrl = "https://github.test/example/project/pull/823"
epicUrl = "https://github.test/example/project/issues/700"

-- | Four cards, one per column that matters here, each with a URL of its own
-- so a launch that opened the wrong one cannot look like a launch that opened
-- the right one.
boardState :: IO AppState
boardState = do
  state <- testAppState board
  pure state {appExpandedTrackers = Set.empty}
  where
    board =
      fixtureBoard
        [ (Issues, [Standalone (IssueItem selectedIssue), Standalone (IssueItem otherIssue)]),
          (Active, [Standalone (PullRequestItem pullRequestCard)]),
          (Reviewing, [collapsedEpicEntry])
        ]

selectedIssue, otherIssue, epicIssue, childIssue :: Issue
selectedIssue = (baseIssue 901 []) {issueUrl = cardUrl}
otherIssue = (baseIssue 902 []) {issueUrl = otherCardUrl}
epicIssue = (baseIssue 700 []) {issueUrl = epicUrl}
childIssue = (baseIssue 711 []) {issueUrl = "https://github.test/example/project/issues/711"}

pullRequestCard :: PullRequest
pullRequestCard = (basePullRequest 823 [901] False []) {pullRequestUrl = pullRequestCardUrl}

-- | An epic with one child. Left out of 'appExpandedTrackers' above, so the
-- row the board draws is the group's rather than the child's.
collapsedEpicEntry :: ColumnEntry
collapsedEpicEntry =
  Tracked
    (TrackingContext (TrackerMembership epicTracker (TrackerChild 711 Nothing 0 False)) [])
    (IssueItem childIssue)

epicTracker :: Tracker
epicTracker = Tracker epicIssue ChecklistMembership 0 0 Map.empty []

selecting :: BoardColumn -> AppState -> AppState
selecting column state = state {appSelectedColumn = column}

-- | The state the completed-history blocker is up in: Closed admitted, and a
-- generation still running behind it, so no card is drawn at all.
blockedOnCompletedLoad :: AppState -> AppState
blockedOnCompletedLoad state =
  state
    { appFilterCriteria =
        state.appFilterCriteria
          {filterLifecycle = Set.insert LifecycleClosed state.appFilterCriteria.filterLifecycle},
      appCompletedStatus = CompletedHistoryLoading
    }

-- ---------------------------------------------------------------------------
-- The fakes
-- ---------------------------------------------------------------------------

-- | The platform opener this host would choose, which is the name a fake has
-- to answer to for 'openPage' to find it.
hostOpenerName :: String
hostOpenerName = maybe "kanban-test-unknown-platform" Text.unpack (platformOpener System.Info.os)

-- | Write @scripts@ into @directory@ as executables and hand back the
-- directory, which is what every case here uses as the whole of @PATH@.
fakeBinaries :: FilePath -> [(String, [ByteString.ByteString])] -> IO FilePath
fakeBinaries directory scripts = do
  createDirectoryIfMissing True directory
  mapM_ install scripts
  pure directory
  where
    install (name, body) = do
      ByteString.writeFile (directory </> name) (ByteString.unlines ("#!/bin/sh" : body))
      setFileMode (directory </> name) 0o700

-- | The first line of every fake below.
--
-- A child inherits the @PATH@ its parent was launched under, and every case
-- here launches under a @PATH@ holding nothing but the fixture's own
-- directory — which is what makes a missing opener a missing opener. A fake
-- that needs @sleep@ or @dd@ would find neither, so it says where the
-- ordinary ones live. Each fake that depends on one also records whether it
-- actually ran, so a fixture whose helper went missing fails loudly instead
-- of quietly asserting nothing.
systemPath :: ByteString.ByteString
systemPath = "PATH=/usr/bin:/bin; export PATH"

-- | An opener that records how many arguments it was given and what the first
-- one was, then exits with @status@.
recordingOpener :: FilePath -> Int -> [ByteString.ByteString]
recordingOpener logPath status =
  [ systemPath,
    "printf 'count=%s\\n' \"$#\" >> " <> quotedPath logPath,
    "printf 'argument=%s\\n' \"$1\" >> " <> quotedPath logPath,
    "exit " <> ByteString.pack (show status)
  ]

-- | An opener that does what a real one is entitled to do: read its input, and
-- write far more than a pipe would hold, before it finishes.
noisyOpener :: FilePath -> [ByteString.ByteString]
noisyOpener logPath =
  [ systemPath,
    "if IFS= read -r ignored; then",
    "  printf 'stdin=read\\n' >> " <> quotedPath logPath,
    "else",
    "  printf 'stdin=eof\\n' >> " <> quotedPath logPath,
    "fi",
    "if dd if=/dev/zero bs=1024 count=256 2>/dev/null &&",
    "   dd if=/dev/zero bs=1024 count=256 2>/dev/null >&2; then",
    "  printf 'wrote=512k\\n' >> " <> quotedPath logPath,
    "else",
    "  printf 'wrote=failed\\n' >> " <> quotedPath logPath,
    "fi",
    "printf 'finished\\n' >> " <> quotedPath logPath
  ]

-- | An opener that records the URL immediately and then cannot exit until
-- @releasePath@ exists. The attempt bound is a stuck-test guard rather than a
-- timing assumption: nothing here waits for it to elapse, and a @sleep@ that
-- did not run says so rather than letting the hold collapse into a spin.
heldOpener :: FilePath -> FilePath -> [ByteString.ByteString]
heldOpener logPath releasePath =
  [ systemPath,
    "printf '%s\\n' \"$1\" >> " <> quotedPath logPath,
    "attempts=0",
    "while [ ! -e " <> quotedPath releasePath <> " ] && [ \"$attempts\" -lt 600 ]; do",
    "  attempts=$((attempts + 1))",
    "  sleep 0.05 || {",
    "    printf 'no-sleep\\n' >> " <> quotedPath logPath,
    "    break",
    "  }",
    "done",
    "printf 'finished\\n' >> " <> quotedPath logPath
  ]

quotedPath :: FilePath -> ByteString.ByteString
quotedPath path = "'" <> ByteString.pack path <> "'"

-- | One invocation a 'recordingOpener' wrote down.
data Recorded = Recorded
  { recordedCount :: Int,
    recordedArgument :: Text
  }
  deriving stock (Eq, Show)

recordedBy :: FilePath -> IO [Recorded]
recordedBy logPath = pairs <$> logLines logPath
  where
    pairs (count : argument : rest)
      | Just counted <- Text.stripPrefix "count=" count,
        Just given <- Text.stripPrefix "argument=" argument =
          Recorded (read (Text.unpack counted)) given : pairs rest
    pairs _ = []

logLines :: FilePath -> IO [Text]
logLines logPath = do
  present <- doesFileExist logPath
  if present then Text.lines <$> TextIO.readFile logPath else pure []

-- | Wait for a line to appear in a log the fixture is still writing.
waitForLine :: FilePath -> Text -> Int -> IO ()
waitForLine logPath needle attempts = do
  written <- logLines logPath
  unless (needle `elem` written) $
    if attempts <= 0
      then expectationFailure ("expected " <> show needle <> " in " <> logPath <> ", which holds " <> show written)
      else threadDelay 100000 >> waitForLine logPath needle (attempts - 1)
