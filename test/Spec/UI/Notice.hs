-- | The notice line's ten-second lifecycle (issue #590), driven entirely
-- through the pure transitions the event loop composes: 'noticeSet' and
-- 'noticeSetFor' as the producers, 'settleNoticeLifecycle' as the
-- classify-and-arm step 'handleEvent' runs after every event,
-- 'noticeExpiryApplied' as the 'NoticeExpired' arm, and 'noticeExpiryToArm'
-- as the decision that forks the one-shot timer. Every instant is injected
-- through 'appNow', so no example waits any wall-clock time at all.
module Spec.UI.Notice (spec) where

import Brick (hLimit)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, utc)
import Kanban.Domain
import Kanban.Drainer
  ( DirectMergeEffect (..),
    DrainerActivity (..),
    DrainerBackend (..),
    DrainerController (..),
    DrainerObservation (..),
    DrainerState (..),
    DrainerStatus (..),
  )
import Kanban.UI.Board (drawFooter)
import Kanban.UI.Events (IncidentsAction (..), applyIncidentsAction)
import Kanban.UI.Notice
import Kanban.PullRequestFlow (PullRequestAction (..), PullRequestOrigin (..))
import Kanban.Solve (ResumeProvenance (..))
import Kanban.UI.PullRequest (directMergeResultApplied, drainerToggleApplied, drainerTogglePress)
import Kanban.UI.Worker (workerSessionEnsured)
import Kanban.Worker
  ( PullRequestWorkerTask (..),
    WorkerDescriptor (..),
    WorkerId (..),
    WorkerSpec (..),
    WorkerTask (..),
  )
import Kanban.GitHub (GitHubResult (..))
import Kanban.UI.Reconcile (boardRefreshOutcomeApplied, refreshSuccessNotice, usageRefreshApplied)
import Kanban.UI.Refresh (historyPausedNotice)
import Kanban.UI (restoreStartupNotice)
import Kanban.UI.Theme (themeFor)
import Kanban.UI.Types (AppState (..), BoardRefreshOutcome (..), StartupReport (..))
import Kanban.UI.Util
  ( directMergeCarryApplied,
    noticeActivityLive,
    noticeCleared,
    noticeExpiryApplied,
    noticeSet,
    noticeSetFor,
    noticeSetOverDirectMergeResult,
    outstandingDirectMergeReport,
    settleNoticeLifecycle,
    shownNotice,
    startupReportApplied,
  )
import Spec.Support.App (testAppState)
import Spec.Support.Fixtures (epoch, testOptions)
import Spec.Support.Render (renderWidgetLines)
import Test.Hspec

spec :: Spec
spec = describe "notice lifecycle" $ do
  constantSpec
  boundarySpec
  redrawSpec
  categorySpec
  instanceSpec
  activeSpec
  inventorySpec
  armingSpec
  directMergeSpec
  durableSpec

-- | A fresh quiet dashboard state.
quietState :: IO AppState
quietState = testAppState (Board Map.empty)

-- | The startup diagnostics the launch examples carry, and the composed line
-- 'runHeldDashboard' builds from them beside the loading fragment.
startupDiagnostics :: Text.Text
startupDiagnostics = "invalid usage cache"

startupComposed :: Text.Text
startupComposed = "Loading open GitHub data · press u to update · " <> startupDiagnostics

-- | A dashboard exactly as launch leaves it: the composed startup line shown
-- as instance zero, the diagnostics carried under that instance, and the
-- startup fetch not yet claimed.
launchedWithDiagnostics :: IO AppState
launchedWithDiagnostics = do
  state <- quietState
  let line = showNotice (ActiveWhile StartupLoadRunning) startupComposed emptyNoticeState
  pure
    (at 0 state)
      { appNotice = line,
        appStartupReport = StartupReport startupDiagnostics <$> currentNoticeInstance line,
        appBoardFreshness = NotLoaded
      }

-- | The state at @delta@ seconds past the fixture epoch, which is what
-- 'handleEvent' stamping 'appNow' at the top of every event leaves behind.
at :: NominalDiffTime -> AppState -> AppState
at delta state = state {appNow = addUTCTime delta epoch}

-- | Settle as the post-event hook does, at an injected instant.
settleAt :: NominalDiffTime -> AppState -> AppState
settleAt delta = settleNoticeLifecycle . at delta

-- | Apply one fired expiry as the 'NoticeExpired' arm does, at an injected
-- instant.
expireAt :: NominalDiffTime -> Int -> AppState -> AppState
expireAt delta instanceId = noticeExpiryApplied instanceId . at delta

armed :: AppState -> Maybe (Int, UTCTime)
armed state = armedNoticeExpiry state.appNotice

shownInstance :: AppState -> Int
shownInstance state = maybe (error "no notice is displayed") id (currentNoticeInstance state.appNotice)

deadlineAt :: NominalDiffTime -> UTCTime
deadlineAt delta = addUTCTime (delta + noticeExpirySeconds) epoch

constantSpec :: Spec
constantSpec = describe "the duration" $ do
  -- The one place the number is written; every example below derives its
  -- instants from this constant rather than repeating it.
  it "pins the settled lifetime at ten seconds" $ do
    noticeExpirySeconds `shouldBe` 10
    noticeExpiryDelayMicros `shouldBe` 10 * 1000 * 1000

boundarySpec :: Spec
boundarySpec = describe "the lifetime boundary" $ do
  it "keeps a settled notice immediately before ten seconds and clears it at the boundary" $ do
    state <- quietState
    let settled = settleAt 0 (noticeSet "Terminal repainted" (at 0 state))
        i = shownInstance settled
    armed settled `shouldBe` Just (i, deadlineAt 0)
    shownNotice (expireAt 9.999 i settled) `shouldBe` Just "Terminal repainted"
    shownNotice (expireAt 10 i settled) `shouldBe` Nothing

  it "keeps the deadline the instance already earned across later events" $ do
    state <- quietState
    let settled = settleAt 0 (noticeSet "Terminal repainted" (at 0 state))
        resettled = settleAt 7 settled
    armed resettled `shouldBe` Just (shownInstance settled, deadlineAt 0)

redrawSpec :: Spec
redrawSpec = describe "the footer's rows" $ do
  -- Requirement 3: the expiry event alone reclaims every row the wrapped
  -- notice occupied. The frames compared are the very widget 'drawBase'
  -- draws and 'baseFooterRows' measures, so what expires here is what the
  -- fullscreen reservation follows.
  it "reclaims every row the notice occupied once the expiry applies" $ do
    state <- quietState
    let wrapping = Text.unwords (replicate 20 "wrap")
        settled = settleAt 0 (noticeSet wrapping (at 0 state))
        expired = expireAt 10 (shownInstance settled) settled
        footer rendered = renderWidgetLines (themeFor testOptions) 40 (hLimit 40 (drawFooter rendered))
    length (footer settled) `shouldSatisfy` (> length (footer expired))
    footer expired `shouldBe` footer (noticeCleared settled)

categorySpec :: Spec
categorySpec = describe "settled categories" $ do
  -- Requirement 2: severity, wording, and producer do not exempt a settled
  -- notice. Each example takes a real producer's own transition.
  it "gives informational, refusal, error, success, and result notices the same lifetime" $ do
    state <- quietState
    let producers :: [(String, AppState -> AppState)]
        producers =
          [ ("history paused info", noticeSet (historyPausedNotice utc epoch)),
            ("incident refusal", applyIncidentsAction ActivateSelectedIncident),
            ("drainer control error", drainerToggleApplied (Left "the job is not loaded")),
            ("drainer toggle result", drainerToggleApplied (Right runningObservation)),
            ("merge result", directMergeResultApplied 42 (DirectMergeEffect "PR #42 was not merged: declined" False))
          ]
    sequence_
      [ do
          let settled = settleAt 3 (produce (at 3 state))
          (name, shownNotice settled) `shouldSatisfy` (\(_, notice) -> notice /= Nothing)
          (name, fmap snd (armed settled)) `shouldBe` (name, Just (deadlineAt 3))
          (name, shownNotice (expireAt 13 (shownInstance settled) settled)) `shouldBe` (name, Nothing)
        | (name, produce) <- producers
      ]

  it "expires the composed startup notice ten seconds after the startup fetch settles" $ do
    launched <- launchedWithDiagnostics
    let beforeFetch = settleAt 0 launched
        loading = settleAt 1 beforeFetch {appBoardFreshness = Loading}
        fetched = settleAt 30 loading {appBoardFreshness = Fresh epoch}
    -- Composed of an in-flight fragment and settled diagnostics, the whole
    -- line rides the fetch: nothing is armed while it runs, however long.
    armed beforeFetch `shouldBe` Nothing
    armed loading `shouldBe` Nothing
    -- The last in-flight part settled, so the ten seconds start here.
    armed fetched `shouldBe` Just (shownInstance fetched, deadlineAt 30)
    shownNotice (expireAt 40 (shownInstance fetched) fetched) `shouldBe` Nothing

  it "keeps the startup diagnostics through the refreshes startup itself requests" $ do
    launched <- launchedWithDiagnostics
    -- The exact notice sequence 'startApplication' produces, through the
    -- same producers it calls: the composed startup line, the board
    -- announcement over the (empty) direct-merge carry, one usage
    -- announcement per provider, and then the restore.
    let announced =
          noticeSetFor (UsageRefreshRunning Claude) "Refreshing Claude usage…"
            . (\s -> s {appUsageFreshness = Map.insert Claude Loading s.appUsageFreshness})
            . noticeSetFor (UsageRefreshRunning Codex) "Refreshing Codex usage…"
            . (\s -> s {appUsageFreshness = Map.insert Codex Loading s.appUsageFreshness})
            . (\s -> s {appBoardFreshness = Loading})
            . noticeSetOverDirectMergeResult (ActiveWhile BoardRefreshRunning) "Refreshing GitHub…"
            $ launched
        restored = settleAt 0 (restoreStartupNotice launched.appNotice announced)
    -- The announcements landed on the line, and the restore put the whole
    -- composed startup report back — diagnostics included — as a fresh
    -- instance still riding the startup fetch, with the carry re-stamped to
    -- the instance actually displayed.
    shownNotice announced `shouldBe` Just "Refreshing Claude usage…"
    shownNotice restored `shouldBe` Just startupComposed
    armed restored `shouldBe` Nothing
    shownNotice (settleAt 15 restored) `shouldBe` Just startupComposed
    fmap (.startupReportShownInstance) restored.appStartupReport `shouldBe` Just (shownInstance restored)

  it "composes a usage result onto the startup line instead of replacing it" $ do
    launched <- launchedWithDiagnostics
    -- Claude's usage answer lands while the startup fetch is still running,
    -- through the same transition the event applies. The line keeps its
    -- loading fragment and diagnostics, gains the result, and stays active.
    let loading = launched {appBoardFreshness = Loading}
        answered = settleAt 2 (usageRefreshApplied Claude "Claude" [] (UsageSnapshot [] epoch) (at 2 loading))
    shownNotice answered `shouldBe` Just (startupComposed <> " · Claude usage refreshed")
    armed answered `shouldBe` Nothing
    shownNotice (settleAt 15 answered) `shouldBe` Just (startupComposed <> " · Claude usage refreshed")
    fmap (.startupReportShownInstance) answered.appStartupReport `shouldBe` Just (shownInstance answered)
    -- Once the diagnostics are retired, the same transition is an ordinary
    -- replacement.
    let retired = answered {appStartupReport = Nothing}
        replaced = usageRefreshApplied Claude "Claude" [] (UsageSnapshot [] epoch) retired
    shownNotice replaced `shouldBe` Just "Claude usage refreshed"

  it "composes the diagnostics onto the first publication, which takes the ordinary ten seconds" $ do
    launched <- launchedWithDiagnostics
    -- The startup fetch publishes through the real reconciliation
    -- transition, over the line still carrying the diagnostics.
    let loading = at 20 launched {appBoardFreshness = Loading}
        outcome = BoardRefreshCompleted (Right (GitHubResult (RepoSnapshot [] [] epoch) []))
        successNotice = refreshSuccessNotice (RepoSnapshot [] [] epoch) []
        published = settleAt 20 (startupReportApplied loading (directMergeCarryApplied loading (boardRefreshOutcomeApplied outcome loading)))
    shownNotice published `shouldBe` Just (successNotice <> " · " <> startupDiagnostics)
    published.appStartupReport `shouldBe` Nothing
    armed published `shouldBe` Just (shownInstance published, deadlineAt 20)
    shownNotice (expireAt 30 (shownInstance published) published) `shouldBe` Nothing
    -- A second publication finds nothing to compose: the diagnostics rode
    -- exactly one outcome.
    let again = settleAt 40 (startupReportApplied published (directMergeCarryApplied published (boardRefreshOutcomeApplied outcome (at 40 published))))
    shownNotice again `shouldBe` Just successNotice

  it "keeps the startup diagnostics when a persisted worker is discovered before the first publication" $ do
    launched <- launchedWithDiagnostics
    -- Worker discovery is forked at startup, so a recovered worker whose
    -- pull request the empty startup board cannot show answers while the
    -- fetch is still running. Its refusal composes onto the startup line —
    -- through the very transition the discovery event runs — and the
    -- diagnostics still ride to the first publication.
    let loading = launched {appBoardFreshness = Loading}
        discovered = settleAt 2 (workerSessionEnsured discoveredWorker (at 2 loading))
        absentRefusal = "Persistent worker for PR #951 is running, but the PR is absent from the cached board; press u to refresh"
    shownNotice discovered `shouldBe` Just (startupComposed <> " · " <> absentRefusal)
    armed discovered `shouldBe` Nothing
    shownNotice (settleAt 15 discovered) `shouldBe` Just (startupComposed <> " · " <> absentRefusal)
    let outcome = BoardRefreshCompleted (Right (GitHubResult (RepoSnapshot [] [] epoch) []))
        successNotice = refreshSuccessNotice (RepoSnapshot [] [] epoch) []
        atPublish = at 20 discovered
        published = settleAt 20 (startupReportApplied atPublish (directMergeCarryApplied atPublish (boardRefreshOutcomeApplied outcome atPublish)))
    shownNotice published `shouldBe` Just (successNotice <> " · " <> startupDiagnostics)
    armed published `shouldBe` Just (shownInstance published, deadlineAt 20)

  it "retires the diagnostics at the first publication once anything else ended their line" $ do
    launched <- launchedWithDiagnostics
    -- An unrelated action replaced the startup line before the fetch
    -- published — the user has stopped looking at it, so the publication
    -- must not resurrect the diagnostics.
    let loading = launched {appBoardFreshness = Loading}
        replaced = at 20 (noticeSet "Review started" loading)
        outcome = BoardRefreshCompleted (Right (GitHubResult (RepoSnapshot [] [] epoch) []))
        successNotice = refreshSuccessNotice (RepoSnapshot [] [] epoch) []
        published = settleAt 20 (startupReportApplied replaced (directMergeCarryApplied replaced (boardRefreshOutcomeApplied outcome replaced)))
    shownNotice published `shouldBe` Just successNotice
    published.appStartupReport `shouldBe` Nothing

instanceSpec :: Spec
instanceSpec = describe "instance identity" $ do
  it "gives a replacement at nine seconds a complete new lifetime" $ do
    state <- quietState
    let first = settleAt 0 (noticeSet "first" (at 0 state))
        oldInstance = shownInstance first
        second = settleAt 9 (noticeSet "second" (at 9 first))
    armed second `shouldBe` Just (shownInstance second, deadlineAt 9)
    -- The superseded instance's timer fires at its own deadline and touches
    -- nothing: the replacement is a different instance.
    shownNotice (expireAt 10 oldInstance second) `shouldBe` Just "second"
    shownNotice (expireAt 19 (shownInstance second) second) `shouldBe` Nothing

  it "never lets an older expiry clear a newer notice with identical text" $ do
    state <- quietState
    let first = settleAt 0 (noticeSet "PR drainer is on" (at 0 state))
        oldInstance = shownInstance first
        second = settleAt 4 (noticeSet "PR drainer is on" (at 4 first))
    shownInstance second `shouldSatisfy` (/= oldInstance)
    shownNotice (expireAt 10 oldInstance second) `shouldBe` Just "PR drainer is on"
    shownNotice (expireAt 14 (shownInstance second) second) `shouldBe` Nothing

  it "never lets a manually dismissed instance's expiry clear an identical successor" $ do
    state <- quietState
    let first = settleAt 0 (noticeSet "Terminal repainted" (at 0 state))
        oldInstance = shownInstance first
        -- Esc at three seconds, then the same press again at five.
        dismissed = noticeCleared (at 3 first)
        second = settleAt 5 (noticeSet "Terminal repainted" (at 5 dismissed))
    shownNotice (expireAt 10 oldInstance second) `shouldBe` Just "Terminal repainted"
    shownNotice (expireAt 15 (shownInstance second) second) `shouldBe` Nothing

  it "counts instances monotonically across clears, so an identity is never reissued" $ do
    let one = showNotice SettledNotice "a" emptyNoticeState
        two = showNotice SettledNotice "b" (clearNotice one)
    currentNoticeInstance two `shouldSatisfy` (/= currentNoticeInstance one)

activeSpec :: Spec
activeSpec = describe "active notices" $ do
  it "keeps a tracked progress notice past ten seconds, then gives its settled end the ordinary lifetime" $ do
    state <- quietState
    let loading = (at 0 state) {appBoardFreshness = Loading}
        shown = settleAt 0 (noticeSetFor BoardRefreshRunning "Refreshing GitHub…" loading)
        longRunning = settleAt 15 shown
    armed shown `shouldBe` Nothing
    armed longRunning `shouldBe` Nothing
    -- A tick with no armed deadline is stale whatever instance it names.
    shownNotice (expireAt 20 (shownInstance longRunning) longRunning) `shouldBe` Just "Refreshing GitHub…"
    -- The fetch settles without replacing its notice: requirement 8's ten
    -- seconds start at the settle, not at the display.
    let settled = settleAt 20 longRunning {appBoardFreshness = Fresh epoch}
    armed settled `shouldBe` Just (shownInstance settled, deadlineAt 20)
    shownNotice (expireAt 29.9 (shownInstance settled) settled) `shouldBe` Just "Refreshing GitHub…"
    shownNotice (expireAt 30 (shownInstance settled) settled) `shouldBe` Nothing

  it "drops a deadline armed by an earlier settle once the tracked operation resumes" $ do
    state <- quietState
    let loading = (at 0 state) {appBoardFreshness = Loading}
        shown = settleAt 0 (noticeSetFor BoardRefreshRunning "Refreshing GitHub…" loading)
        -- The fetch settles at five, arming the deadline …
        pausedAt5 = settleAt 5 shown {appBoardFreshness = Unavailable "offline"}
        -- … and the operation resumes at eight without a new notice, so the
        -- armed deadline is withdrawn and the timer already forked for it
        -- finds nothing due when it fires.
        resumed = settleAt 8 pausedAt5 {appBoardFreshness = Loading}
        resettled = settleAt 20 resumed {appBoardFreshness = Fresh epoch}
    armed pausedAt5 `shouldBe` Just (shownInstance shown, deadlineAt 5)
    armed resumed `shouldBe` Nothing
    shownNotice (expireAt 15 (shownInstance shown) resumed) `shouldBe` Just "Refreshing GitHub…"
    -- The stale first timer fires after the re-settle and is still turned
    -- away: the re-armed deadline is later than the tick's own.
    shownNotice (expireAt 15 (shownInstance shown) resettled) `shouldBe` Just "Refreshing GitHub…"
    shownNotice (expireAt 30 (shownInstance shown) resettled) `shouldBe` Nothing

  it "takes the drainer toggle from active press to settled observation through the real transitions" $ do
    state <- quietState
    let installed =
          state
            { appDrainerStatus = DrainerStatus DrainerOff "off" DrainerServiceStopped Nothing,
              appDrainerController = Right (DrainerController "/nonexistent/kanban-test-drainer" [] DrainerLaunchd)
            }
        (pressed, _) = drainerTogglePress (at 0 installed)
        busy = settleAt 0 pressed
    shownNotice busy `shouldBe` Just "Starting PR drainer…"
    armed busy `shouldBe` Nothing
    let landed = settleAt 25 (drainerToggleApplied (Right runningObservation) (at 25 busy))
    shownNotice landed `shouldBe` Just "PR drainer is on"
    armed landed `shouldBe` Just (shownInstance landed, deadlineAt 25)

inventorySpec :: Spec
inventorySpec = describe "the declared activity inventory" $ do
  -- Requirement 7's decidability: each activity is alive on exactly the
  -- tracked state 'noticeActivityLive' names for it, so whether any notice
  -- outlives ten seconds is a fact about these fields and never about its
  -- wording.
  it "keys each activity to the state that tracks it" $ do
    state <- quietState
    let live activity mutate = noticeActivityLive (mutate state) activity
    live StartupLoadRunning (\s -> s {appBoardFreshness = NotLoaded}) `shouldBe` True
    live StartupLoadRunning (\s -> s {appBoardFreshness = Loading}) `shouldBe` True
    live StartupLoadRunning (\s -> s {appBoardFreshness = Fresh epoch}) `shouldBe` False
    live StartupLoadRunning (\s -> s {appBoardFreshness = Unavailable "offline"}) `shouldBe` False
    live BoardRefreshRunning (\s -> s {appBoardFreshness = Loading}) `shouldBe` True
    live BoardRefreshRunning (\s -> s {appBoardFreshness = NotLoaded}) `shouldBe` False
    live (UsageRefreshRunning Claude) (\s -> s {appUsageFreshness = Map.singleton Claude Loading}) `shouldBe` True
    live (UsageRefreshRunning Claude) (\s -> s {appUsageFreshness = Map.singleton Codex Loading}) `shouldBe` False
    live (UsageRefreshRunning Claude) id `shouldBe` False
    live DrainerToggleRunning (\s -> s {appDrainerBusy = True}) `shouldBe` True
    live DrainerToggleRunning id `shouldBe` False
    live ApprovalToggleRunning (\s -> s {appApprovalBusy = True}) `shouldBe` True
    live ApprovalToggleRunning id `shouldBe` False
    live (DirectMergeRunning 42) (\s -> s {appDirectMergePending = Just 42}) `shouldBe` True
    live (DirectMergeRunning 42) (\s -> s {appDirectMergePending = Just 41}) `shouldBe` False
    live (DirectMergeRunning 42) id `shouldBe` False
    live QuitSettling (\s -> s {appQuitPending = True}) `shouldBe` True
    live QuitSettling id `shouldBe` False

armingSpec :: Spec
armingSpec = describe "the one-shot timer decision" $ do
  it "arms once per settled instance and never re-arms an unchanged pair" $ do
    state <- quietState
    let settled = settleAt 0 (noticeSet "Terminal repainted" (at 0 state))
        idle = settleAt 4 settled
    noticeExpiryToArm state.appNotice settled.appNotice `shouldBe` Just (shownInstance settled)
    -- A later event that leaves the pair alone forks nothing, so an idle
    -- stream of events cannot stack timers behind the first.
    noticeExpiryToArm settled.appNotice idle.appNotice `shouldBe` Nothing
    -- A replacement is a new pair and takes a timer of its own.
    let replaced = settleAt 6 (noticeSet "second" (at 6 settled))
    noticeExpiryToArm settled.appNotice replaced.appNotice `shouldBe` Just (shownInstance replaced)

  it "arms again when an active notice settles under the instance it kept" $ do
    state <- quietState
    let loading = (at 0 state) {appBoardFreshness = Loading}
        shown = settleAt 0 (noticeSetFor BoardRefreshRunning "Refreshing GitHub…" loading)
        settled = settleAt 20 shown {appBoardFreshness = Fresh epoch}
    noticeExpiryToArm loading.appNotice shown.appNotice `shouldBe` Nothing
    noticeExpiryToArm shown.appNotice settled.appNotice `shouldBe` Just (shownInstance settled)

directMergeSpec :: Spec
directMergeSpec = describe "the direct-merge carry" $ do
  let mergedEffect = DirectMergeEffect "PR #42 merged." True

  it "stays protected across the refresh it requires, then expires once settled" $ do
    state <- quietState
    -- The merge lands and its required refresh starts in the same breath, so
    -- the composed line reports an active fetch and outlives ten seconds.
    let reported = directMergeResultApplied 42 mergedEffect (at 0 state)
        composed =
          settleAt 0 $
            noticeSetOverDirectMergeResult
              (ActiveWhile BoardRefreshRunning)
              "Refreshing GitHub…"
              reported {appBoardFreshness = Loading}
    shownNotice composed `shouldBe` Just "PR #42 merged. · Refreshing GitHub…"
    armed composed `shouldBe` Nothing
    shownNotice (settleAt 15 composed) `shouldBe` Just "PR #42 merged. · Refreshing GitHub…"
    -- The refresh publishes: the carry re-fronts the result over the success
    -- notice, the refresh has run so the report is retired, and the settled
    -- line takes its ten seconds.
    let published = settleAt 20 (directMergeCarryApplied (at 20 composed) (noticeSet "Fetched 12 issues" (at 20 composed) {appBoardFreshness = Fresh epoch}))
    shownNotice published `shouldBe` Just "PR #42 merged. · Fetched 12 issues"
    published.appDirectMergeResult `shouldBe` Nothing
    armed published `shouldBe` Just (shownInstance published, deadlineAt 20)
    shownNotice (expireAt 30 (shownInstance published) published) `shouldBe` Nothing

  it "retires the carried result in the same step an expiry clears its notice" $ do
    state <- quietState
    -- The refresh could only be queued, so the plain settled result is on
    -- screen with its report still carried behind it.
    let reported = settleAt 0 (directMergeResultApplied 42 mergedEffect (at 0 state))
        expired = expireAt 10 (shownInstance reported) reported
    reported.appDirectMergeResult `shouldSatisfy` (/= Nothing)
    shownNotice expired `shouldBe` Nothing
    expired.appDirectMergeResult `shouldBe` Nothing
    -- And the refresh that later publishes cannot recreate it: timed
    -- dismissal ended the result exactly as Esc would have.
    let afterRefresh = directMergeCarryApplied expired (noticeSet "Fetched 12 issues" expired)
    shownNotice afterRefresh `shouldBe` Just "Fetched 12 issues"
    afterRefresh.appDirectMergeResult `shouldBe` Nothing

  it "never lets a later notice with identical text adopt a retired report" $ do
    state <- quietState
    let reported = directMergeResultApplied 42 mergedEffect (at 0 state)
        report = reported.appDirectMergeResult
        -- The result's own instance is outstanding …
        stillShown = outstandingDirectMergeReport (currentNoticeInstance reported.appNotice) report
        -- … but a replacement repeating the words is a different instance.
        repeated = noticeSet "PR #42 merged." reported
    stillShown `shouldBe` report
    outstandingDirectMergeReport (currentNoticeInstance repeated.appNotice) report `shouldBe` Nothing

  it "leaves an expiry belonging to a bystander notice with no claim on the report" $ do
    state <- quietState
    -- The report's notice was already replaced; the replacement expires. The
    -- stale report is not the expiring notice's to retire.
    let reported = directMergeResultApplied 42 mergedEffect (at 0 state)
        replaced = settleAt 2 (noticeSet "Review started" (at 2 reported))
        expired = expireAt 12 (shownInstance replaced) replaced
    shownNotice expired `shouldBe` Nothing
    expired.appDirectMergeResult `shouldBe` reported.appDirectMergeResult

durableSpec :: Spec
durableSpec = describe "durable state" $ do
  -- Requirement 9: expiry touches the transient line and the report behind
  -- it, and nothing else the footer, sidebar, or panels report through their
  -- own surfaces.
  it "changes nothing durable when a notice expires" $ do
    state <- quietState
    let populated =
          (at 0 state)
            { appBoardFreshness = Fresh epoch,
              appUsageFreshness = Map.singleton Claude (Fresh epoch),
              appDrainerStatus = DrainerStatus DrainerOn "on" DrainerServiceRunning Nothing,
              appDrainerIncidents = Just [],
              appDirectMergePending = Just 7,
              appQuitPending = False
            }
        settled = settleAt 0 (noticeSet "Claude usage refreshed" populated)
        expired = expireAt 10 (shownInstance settled) settled
    shownNotice expired `shouldBe` Nothing
    expired.appBoardFreshness `shouldBe` settled.appBoardFreshness
    expired.appUsageFreshness `shouldBe` settled.appUsageFreshness
    expired.appDrainerStatus `shouldBe` settled.appDrainerStatus
    expired.appDrainerIncidents `shouldBe` settled.appDrainerIncidents
    expired.appDirectMergePending `shouldBe` settled.appDirectMergePending
    expired.appCompletedStatus `shouldBe` settled.appCompletedStatus
    expired.appLastSuccessfulFetch `shouldBe` settled.appLastSuccessfulFetch

runningObservation :: DrainerObservation
runningObservation =
  DrainerObservation (DrainerStatus DrainerOn "on" DrainerServiceRunning Nothing) (Just [])

-- | A recovered persistent pull-request worker, as discovery hands one to
-- 'workerSessionEnsured'.
discoveredWorker :: WorkerDescriptor
discoveredWorker =
  WorkerDescriptor
    { workerDescriptorSpec =
        WorkerSpec
          { workerId = WorkerId "worker-1",
            workerRepository = Repository "/tmp/example-project" "example" "project",
            workerTask = PullRequestWorkerTaskKind (PullRequestWorkerTask 951 PullRequestClaude PullRequestReview),
            workerExistingSession = Nothing,
            workerExistingLogPath = Nothing,
            workerResumeProvenance = ResumeAnswer,
            workerUserMessage = "",
            workerParent = Nothing,
            workerCreatedAt = epoch,
            workerMaxRuntimeSeconds = 60,
            workerConfigPath = Nothing,
            workerWorkflowConfig = defaultWorkflowConfig,
            workerAssignment = Nothing,
            workerExpectedTarget = Nothing
          },
      workerDescriptorSpecPath = "/tmp/worker-1.spec.json",
      workerDescriptorRosterPath = "/tmp/worker-1.roster.toml",
      workerDescriptorEventPath = "/tmp/worker-1.events.jsonl",
      workerDescriptorStatePath = "/tmp/worker-1.state.json",
      workerDescriptorAckPath = "/tmp/worker-1.ack",
      workerDescriptorLeasePath = "/tmp/worker-1.lease",
      workerDescriptorLeaseOwnerPath = "/tmp/worker-1.lease.owner",
      workerDescriptorPendingTerminationPath = "/tmp/worker-1.terminating",
      workerDescriptorHandoffPath = "/tmp/worker-1.handing-off",
      workerDescriptorCommandPath = "/tmp/worker-1.commands.jsonl",
      workerDescriptorCommandAckPath = "/tmp/worker-1.command-acks.jsonl"
    }
