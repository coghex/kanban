-- | @docs\/design.md@ §3's non-goals and §20's deferred ideas, each held
-- against a witness.
--
-- §7's key table is held by "Spec.UI.Keys" comparing its rows against
-- 'Kanban.UI.Keys.binding', and that mechanism does not transfer here: these
-- entries are prose naming capabilities, with no row-for-row implementation
-- counterpart to compare against. Neither does text matching. Four
-- contradictions accumulated in the two lists over roughly five weeks, and
-- neither of the two that were removed shared any distinctive vocabulary with
-- the specification that had contradicted it, so no keyword or anchor derived
-- from an entry would have fired on either one.
--
-- What is checkable is a /witness/ per entry: a machine-verifiable fact whose
-- truth is what the entry asserts. \"A permanent archive of merged or closed
-- work\" was witnessed by no reachable filter criteria retaining a settled
-- card; issue #319's completed-history filter broke that fact, which is
-- exactly the moment the entry became false and roughly five weeks before
-- anyone noticed. 'retiredDeclarations' keeps that witness and #424's, and the
-- suite runs them against today's code and requires them to come back broken —
-- the demonstration that a witness here has teeth rather than passing because
-- it asserts nothing.
--
-- Four rules hold the mechanism together:
--
-- * Every entry the document lists is declared, and every declaration names an
--   entry the document lists. Neither direction may be empty (requirement 2 of
--   issue #457).
-- * A declaration states the machine fact it asserts and how that fact
--   witnesses its entry. An assertion that passes without bearing on the entry
--   satisfies nothing.
-- * An entry with no machine-verifiable fact may declare itself
--   'Unwitnessed' with a reason, and 'unwitnessedProperSubset' refuses a
--   declaration set in which /every/ entry has done so.
-- * A witness reads no path @tools\/test_source_distribution.py@ excludes.
--   @docs\/design.md@ ships; the @docs\/*_design.md@ arc documents do not, so
--   a witness resting on an arc document's status ledger would error in an
--   unpacked release rather than in a checkout.
--
-- Facts are shared where two entries rest on the same one. That is not
-- duplication to be factored out: the document itself lists multi-repository
-- aggregation twice, once as a non-goal and once as a deferral, and the two
-- are true or false together. Each declaration still states its own rationale.
module Spec.Design.Witnesses (spec) where

import Control.Exception (SomeException, try)
import Data.Aeson (Value (Object), toJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.List (isInfixOf, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TextIO
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.Typeable (Typeable, typeOf)
import qualified Graphics.Vty as Vty
import Kanban.Config (decodeConfigText, defaultRawConfig)
import Kanban.Domain
  ( BoardColumn,
    CompletedHistory (..),
    RepoSnapshot (..),
    Repository (..),
    issueNumber,
    pullRequestNumber,
  )
import Kanban.Drainer (directMergeArguments)
import Kanban.Filter
  ( criteriaDataset,
    defaultFilterCriteria,
    everyFilterBox,
    toggleFilterBox,
  )
import Kanban.GitHub
  ( CoordinatorPlan (..),
    CoordinatorState (..),
    FetchState (..),
    HistoryFetchState (..),
    graphqlArguments,
    historyGraphqlArguments,
    initialCoordinatorState,
    initialHistoryFetchState,
    planCoordinator,
  )
import Kanban.Models (allProviders, allRoles)
import Kanban.Repository (parseRemoteRepository)
import Kanban.Settings (defaultSettings)
import Kanban.UI.Events (boardMouseAction, boardMousePress, mutatesSelectedWork)
import Kanban.UI.Keys (BoardAction, binding)
import Kanban.UI.Types
  ( AgentSessionRef (..),
    AppState,
    IncidentRef (..),
    Name (..),
  )
import Kanban.Worker (WorkerSpec (..))
import Spec.Design.Entries
  ( DesignEntry (..),
    designDocumentPath,
    designEntries,
    heldSections,
    distributionExclusionsPath,
    exclusionCovers,
    excludedDistributionPaths,
  )
import Spec.Support.App (testAppState)
import Spec.Support.Env (withTemporaryCacheRoot)
import Spec.Support.LeaseProbes
  ( LeaseProbe (..),
    LeaseProbeOutcome (..),
    awaitLeaseOutcome,
    openLeaseGate,
    withLeaseProbes,
  )
import Spec.Support.Fixtures (baseIssue, basePullRequest, epoch, fixtureBoard)
import System.Directory (doesDirectoryExist, doesPathExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import Test.Hspec

-- * The model

-- | What a declaration claims about one entry.
data Witness
  = -- | A machine fact, and the check that asks whether it still holds.
    Witnessed WitnessedFact
  | -- | No machine-verifiable fact witnesses this entry, and why not.
    Unwitnessed Text

-- | One executable witness.
data WitnessedFact = WitnessedFact
  { -- | The machine fact being asserted, in the terms the check asserts it.
    factStatement :: Text,
    -- | How the truth of that fact witnesses the entry. A fact that passes
    -- without bearing on the entry witnesses nothing, so this is required.
    factRationale :: Text,
    -- | Repository paths the check reads, held against the source
    -- distribution's own exclusion tuple.
    factReads :: [FilePath],
    -- | 'Nothing' while the fact holds; otherwise what it is now instead.
    factCheck :: IO (Maybe Text)
  }

-- | One entry, identified exactly as the document lists it, and its witness.
data Declaration = Declaration
  { declarationSection :: Int,
    declarationEntry :: Text,
    declarationWitness :: Witness
  }

spec :: Spec
spec = describe "docs/design.md §3 and §20" $ do
  describe "coverage" $ do
    it "declares exactly the entries the document lists" $ do
      documented <- designEntries
      coverageGaps documented declarations `shouldBe` ([], [])

    it "reports an entry no declaration covers, and a declaration covering no entry" $ do
      let documented =
            [ DesignEntry 3 "Automatic network polling.",
              DesignEntry 3 "An entry nothing declares."
            ]
          declared =
            [ Declaration 3 "Automatic network polling." (Unwitnessed "irrelevant here"),
              Declaration 20 "A declaration nothing lists." (Unwitnessed "irrelevant here")
            ]
      coverageGaps documented declared
        `shouldBe` (["3: An entry nothing declares."], ["20: A declaration nothing lists."])

    it "reads both held sections, in the proportions the declarations carry" $ do
      documented <- designEntries
      -- Derived from the declarations rather than restated as two numbers: a
      -- third copy of the counts would be a third thing to keep true. What
      -- this adds to the comparison above is that both sections were read at
      -- all, which a parser that swallowed one section's heading could
      -- otherwise satisfy by covering the other twice.
      map designEntrySection documented
        `shouldBe` concat
          [ replicate (length (filter ((== section) . declarationSection) declarations)) section
            | (section, _) <- heldSections
          ]

  describe "witnesses" $ do
    it "holds every declared witness against the current implementation" $ do
      broken <- brokenWitnesses declarations
      broken `shouldBe` []

    it "states a fact and a rationale for every witness, and a reason for every unwitnessed entry" $ do
      declarationShapeFaults declarations `shouldBe` []
      declarationShapeFaults
        [ Declaration 3 "Silent." (Unwitnessed "   "),
          Declaration 20 "Unexplained." (Witnessed (WitnessedFact "" "" [] (pure Nothing)))
        ]
        `shouldBe` [ "3: Silent. is unwitnessed with no stated reason",
                     "20: Unexplained. states no machine fact",
                     "20: Unexplained. says nothing about how its fact witnesses the entry"
                   ]

    it "refuses a declaration set that leaves every entry unwitnessed" $ do
      unwitnessedProperSubset declarations `shouldBe` Nothing
      unwitnessedProperSubset [Declaration 3 "Anything." (Unwitnessed "no fact")]
        `shouldBe` Just "every declared entry is unwitnessed, so nothing about any of them is asserted"
      unwitnessedProperSubset [] `shouldBe` Just "no entry is declared at all"

    it "reads no path the source distribution excludes" $ do
      excluded <- excludedDistributionPaths
      -- The parse found the real tuple, not an empty one that would let every
      -- path through: a document the release deliberately leaves out is
      -- covered by it.
      any (`exclusionCovers` "docs/multi_repo_boards_design.md") excluded `shouldBe` True
      -- The two files the mechanism itself opens, held against the same
      -- authority a witness's reads are.
      any (`exclusionCovers` designDocumentPath) excluded `shouldBe` False
      any (`exclusionCovers` distributionExclusionsPath) excluded `shouldBe` False
      shippedReadFaults excluded declarations >>= (`shouldBe` [])
      -- And the check has teeth: a witness resting on an arc document, the
      -- exact mistake requirement 5 of issue #457 names, is reported.
      faults <-
        shippedReadFaults
          excluded
          [ Declaration
              3
              "Resting on an arc document."
              (Witnessed (WitnessedFact "a fact" "a rationale" ["docs/multi_repo_boards_design.md"] (pure Nothing)))
          ]
      faults
        `shouldBe` [ "3: Resting on an arc document. reads docs/multi_repo_boards_design.md, which "
                       <> Text.pack distributionExclusionsPath
                       <> " excludes from the source distribution"
                   ]

  describe "a broken witness" $ do
    it "comes back broken for both entries #423 and #424 removed" $ do
      broken <- brokenWitnesses retiredDeclarations
      map fst broken `shouldBe` map declarationKey retiredDeclarations

    it "is retired only once the document no longer lists its entry" $ do
      documented <- designEntries
      let stillListed =
            [ declarationKey retired
              | retired <- retiredDeclarations,
                declarationKey retired `elem` map entryKey documented
            ]
      stillListed `shouldBe` []

-- * The mechanism

entryKey :: DesignEntry -> Text
entryKey entry = Text.pack (show entry.designEntrySection) <> ": " <> entry.designEntryItem

declarationKey :: Declaration -> Text
declarationKey declared =
  Text.pack (show declared.declarationSection) <> ": " <> declared.declarationEntry

-- | (entries no declaration covers, declarations covering no entry).
--
-- Both directions, because either one alone is a mechanism that can be
-- bypassed: an entry added to a list would skip the check, and a removed one
-- would leave a declaration asserting something about nothing.
coverageGaps :: [DesignEntry] -> [Declaration] -> ([Text], [Text])
coverageGaps documented declared = (uncovered, stale)
  where
    documentedKeys = map entryKey documented
    declaredKeys = map declarationKey declared
    uncovered = [key | key <- documentedKeys, key `notElem` declaredKeys]
    stale = [key | key <- declaredKeys, key `notElem` documentedKeys]

-- | Every declared witness that no longer holds, with what it says instead.
brokenWitnesses :: [Declaration] -> IO [(Text, Text)]
brokenWitnesses declared =
  concat
    <$> traverse
      ( \one -> case one.declarationWitness of
          Unwitnessed _ -> pure []
          Witnessed fact -> maybe [] (\why -> [(declarationKey one, why)]) <$> fact.factCheck
      )
      declared

-- | Requirement 3's negative control. A declaration set in which every entry
-- is unwitnessed asserts nothing about any of them, and must not pass.
unwitnessedProperSubset :: [Declaration] -> Maybe Text
unwitnessedProperSubset declared
  | null declared = Just "no entry is declared at all"
  | null witnessed = Just "every declared entry is unwitnessed, so nothing about any of them is asserted"
  | otherwise = Nothing
  where
    witnessed = [() | one <- declared, Witnessed _ <- [one.declarationWitness]]

-- | Declarations that skip the explanation a witness owes.
declarationShapeFaults :: [Declaration] -> [Text]
declarationShapeFaults declared =
  [ declarationKey one <> " " <> fault
    | one <- declared,
      fault <- case one.declarationWitness of
        Unwitnessed reason | Text.null (Text.strip reason) -> ["is unwitnessed with no stated reason"]
        Unwitnessed _ -> []
        Witnessed fact ->
          ["states no machine fact" | Text.null (Text.strip fact.factStatement)]
            <> ["says nothing about how its fact witnesses the entry" | Text.null (Text.strip fact.factRationale)]
  ]

-- | Declared read paths that are absent, or that the source distribution
-- excludes. A witness resting on an excluded path passes in a checkout and
-- errors in an unpacked release, which is the worse of the two failures.
shippedReadFaults :: [Text] -> [Declaration] -> IO [Text]
shippedReadFaults excluded declared =
  concat
    <$> traverse
      check
      [ (declarationKey one, path)
        | one <- declared,
          Witnessed fact <- [one.declarationWitness],
          path <- fact.factReads
      ]
  where
    check (key, path) = do
      present <- doesPathExist path
      pure $
        [key <> " reads " <> Text.pack path <> ", which is not in the checkout" | not present]
          <> [ key <> " reads " <> Text.pack path <> ", which " <> Text.pack distributionExclusionsPath <> " excludes from the source distribution"
             | any (`exclusionCovers` path) excluded
             ]

-- * The declarations

-- | Every entry §3 and §20 list, in document order.
declarations :: [Declaration]
declarations =
  [ Declaration
      3
      "A web UI, GUI, Electron application, or permanently resident daemon. An explicitly started agent may use a bounded detached worker so it can survive a dashboard restart."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "kanban.cabal declares exactly the components recorded here — the library, the one `kanban` executable, and the test suite — and the detached worker a started agent may use carries `workerMaxRuntimeSeconds :: WorkerSpec -> Int`, an unconditional bound rather than an optional or absent one.",
              factRationale =
                "A GUI, an Electron shell, or a resident daemon is a program of its own: it would be a second executable or a foreign library in this file, and there is neither. The entry's own exception is what the runtime bound holds — a worker whose spec cannot omit a finite runtime is bounded rather than permanently resident, which is the difference between the exception and the non-goal.",
              factReads = [cabalPath],
              factCheck = do
                components <- shippedComponents
                pure (everyFault [components, boundedWorkerSpec])
            }
      ),
    Declaration
      3
      "Automatic network polling."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "`planCoordinator`, the pure decision that owns every `gh` a board refresh starts, plans `PlanWait Nothing` from an idle coordinator state at every clock time it is asked at.",
              factRationale =
                "Polling is the coordinator deciding from the clock alone to run a fetch nobody requested. `PlanWait Nothing` is the plan that waits for a request rather than for a moment, so while it is what an idle coordinator answers at any time, no fetch can start unasked; a poll would have to appear here as a `PlanRun` or as a wait until a named moment.",
              factReads = [],
              factCheck = pure idleCoordinatorWaits
            }
      ),
    Declaration
      3
      "GitHub webhooks or a local HTTP server."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "The dependency set of kanban.cabal's shipped components — the library and the `kanban` executable together — is exactly the recorded set, compared whole rather than searched for known offenders.",
              factRationale =
                "A webhook receiver or a local HTTP server has to listen on a socket, and nothing in that set can: none of those packages opens one. Comparing the whole set rather than a roster of forbidden names is what makes that load-bearing — a listener could not be added under any package name without failing here first.",
              factReads = [cabalPath],
              factCheck = shippedDependencies
            }
      ),
    Declaration
      3
      "Drag-and-drop, hover actions, mouse-driven column navigation, and general pointer interaction beyond the deliberately small contract in section 7."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "`boardMouseAction`, the total decision for one pointer press, claims exactly the recorded (target, button, modifier policy) combinations, probed across every `Name` the dashboard draws, every mouse button, every board column, and six modifier combinations.",
              factRationale =
                "Hover and pointer navigation beyond §7's contract would each have to appear as a new claim in that decision — a target it answers, a button it answers, or a modifier that changes what it answers. The claimed set is compared exactly and in both directions, so any pointer meaning added or removed fails here rather than accumulating silently.",
              factReads = [],
              factCheck = pointerClaims
            }
      ),
    Declaration
      3
      "Drag-and-drop workflow mutation."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "No module under src/ mentions vty's `MouseUp`, so no pointer release is dispatched anywhere; and `boardMousePress`, the total answer to a decided press, has the type `BoardMouseAction -> AppState -> AppState`.",
              factRationale =
                "Drag-and-drop needs a press and a release to name a source and a target, and only presses are decided at all. Even a press that could be one half of a drag resolves to a pure function of the dashboard's own state, which cannot reach GitHub, so no pointer gesture mutates workflow state.",
              factReads = [sourceRoot],
              factCheck = do
                release <- noPointerRelease
                pure (everyFault [release, pureBoardPress])
            }
      ),
    Declaration
      3
      "Direct board editing and drag/drop mutation. Review and solve workflows may perform their explicitly documented GitHub mutations."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "`mutatesSelectedWork`, total in `BoardAction`, is True for exactly five actions: KillWorking, ReviewSelection, SolveSelection, AutoSolveSelection, and MergeDoneCard.",
              factRationale =
                "Those five are the review, solve and drainer workflows this entry's second sentence permits, and nothing else on the board acts on the work a card stands for — no action edits a card's title, body, labels, assignees, or column. Because the predicate is total in `BoardAction`, an action added to the table in Kanban.UI.Keys cannot reach the board without a decision here, and a sixth mutating action fails this comparison.",
              factReads = [],
              factCheck = pure mutatingActions
            }
      ),
    Declaration
      3
      "Implementing a merge. Kanban decides only whether to invoke the PR drainer's own single-pull-request path (`tools/drain_prs.py --pr`), which owns every gate, the merge itself, and the post-merge cleanup; Kanban holds no second copy of any of that, and merges nothing that path would refuse."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "`directMergeArguments`, the one argument vector Kanban builds to merge a pull request, is the resolved `drain_prs.py` path followed by `--path`, `--repo`, `--pr` and the number, with `--config` appended when one is selected.",
              factRationale =
                "Merging by any other route would mean a second argument vector — a `gh pr merge`, a `git merge`, or a GraphQL mutation — rather than this delegation. Holding the vector exactly is what keeps the decision the only thing on this side: every gate the drainer applies stays behind the script this names, and a merge implemented here would have to stop building it.",
              factReads = [],
              factCheck = pure mergeDelegation
            }
      ),
    Declaration
      3
      "Multi-repository aggregation in one running board. Each invocation represents one repository selected by its path."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "The dashboard's action inventory is exactly the recorded `BoardAction` values and its pointer claims exactly the recorded press combinations, none of which selects, cycles, or aggregates a second repository; and `criteriaDataset` has the type `FilterCriteria -> Maybe RepoSnapshot -> Maybe CompletedHistory -> Maybe RepoSnapshot`, deriving one board's dataset from at most one repository's snapshot.",
              factRationale =
                "A running board can only show a second repository if something reaches one: a key, a click, or a dataset built from more than one snapshot. All three are closed here. The witness deliberately does not assert that Kanban resolves or holds one repository — docs/multi_repo_boards_design.md's MRB-1 resolves a whole roster and MRB-2 holds per-repository state, both while these entries stand — and it changes with MRB-3, whose tab row adds the `[`, `]` and `1`-`9` bindings and a click target in the same pull request that amends this entry.",
              factReads = [],
              factCheck = do
                claims <- pointerClaims
                pure (everyFault [boardActionInventory, claims, singleRepositoryDataset])
            }
      ),
    Declaration
      3
      "Concurrent dashboard processes for one GitHub repository. Dashboard mode holds a repository-scoped lease for its lifetime and refuses a second dashboard before drawing."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "Two independent OS processes going for the lease under one cache root, released together from one rendezvous, are told between them exactly one acquisition and one refusal when they spell the same GitHub repository `Coghex/Kanban` and `coghex/kanban` — and are both told they acquired when they name `coghex-kan/ban` and `coghex/kan-ban`, the two distinct repositories the durable key this replaced mapped onto one file.",
              factRationale =
                "The entry is about processes, and nothing staged inside one can witness it: a POSIX record lock belongs to the process, so a second request from a holder is granted rather than refused and a threaded fixture would watch every contention it staged quietly succeed. Two real processes and one lock is the fact itself. The second half is what keeps the first from passing vacuously as a machine-wide lock would: the refusal has to be scoped to the repository, or a board would refuse to open beside an unrelated one.",
              factReads = [],
              factCheck = boardLeaseWitness
            }
      ),
    Declaration
      20
      "Configurable keybindings."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "`binding` has the type `BoardAction -> KeyBinding`, taking no configuration, and the settings document Kanban writes carries exactly the keys `chatVerbosity` and `schemaVersion`.",
              factRationale =
                "A configurable binding has to be read from somewhere. The one declaration site for a board key takes only the action, and the one persisted user document has no field a key could arrive in, so the table cannot be overridden. Kanban.UI.Keys already names itself as where configurable bindings would be read into; that is the signature this pins.",
              factReads = [],
              factCheck = pure (everyFault [compileTimeBindings, settingsDocumentKeys])
            }
      ),
    Declaration
      20
      "OSC 52 URL copy support for remote terminals."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "No module under src/ or app/ contains the OSC 52 introducer `]52;`, in any escape spelling, and the action inventory is exactly the recorded `BoardAction` values, none of which copies anything.",
              factRationale =
                "Emitting an OSC 52 sequence means writing that introducer, whichever way the escape byte before it is spelled, so the absence of the introducer is the absence of the emission. The closed action inventory covers the other half: support offered to the user would be reachable, and nothing on the board reaches it.",
              factReads = [sourceRoot, applicationRoot],
              factCheck = do
                escape <- noClipboardEscape
                pure (everyFault [escape, boardActionInventory])
            }
      ),
    Declaration
      20
      "Optional `gh issue view --web`/`gh pr view --web` local-only action."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "Every `gh` argument vector Kanban builds for the board begins `api graphql`, over both the open and the completed traversal and every cursor and sub-issue combination, and the action inventory is exactly the recorded `BoardAction` values.",
              factRationale =
                "`gh issue view --web` is a different subcommand, so it would be a vector that does not begin `api graphql`; and being optional and user-invoked, it would also be an action on the board. Neither exists.",
              factReads = [],
              factCheck = pure (everyFault [githubRequestsAreReads, boardActionInventory])
            }
      ),
    Declaration
      20
      "GitHub mutations such as assignment or label changes."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "Every GraphQL document Kanban sends begins `query(` and contains no `mutation`, over both traversals and every cursor and sub-issue combination; and `mutatesSelectedWork` is True for exactly the five review, solve and drainer actions.",
              factRationale =
                "An assignment or a label change is a GraphQL mutation or a mutating `gh` subcommand, and every document Kanban sends is a query. The action side is closed too: the five actions that act on a card's work all hand off to a workflow §3 names, and none of them edits an assignee or a label from the board.",
              factReads = [],
              factCheck = pure (everyFault [githubRequestsAreReads, mutatingActions])
            }
      ),
    Declaration
      20
      "Automatic refresh intervals, disabled by default if ever added."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "The configuration schema reports every cadence-shaped key probed — the refresh and poll interval spellings recorded here — as unknown and decodes to the default configuration unchanged; and an idle `planCoordinator` plans `PlanWait Nothing`.",
              factRationale =
                "An interval that could be enabled would be a configuration key, and none of these is one. The coordinator half is what makes that more than a naming argument: with no interval anywhere in the scheduler, there is no cadence for a default to disable, which is the state this entry describes.",
              factReads = [],
              factCheck = pure (everyFault [noCadenceConfiguration, idleCoordinatorWaits])
            }
      ),
    Declaration
      20
      "Multi-repository aggregation."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "The same fact §3's multi-repository entry rests on: the recorded action inventory and press claims reach no second repository, and `criteriaDataset` derives one board's dataset from at most one snapshot.",
              factRationale =
                "The deferral is of a capability a user could reach, and the two closed inventories are every way to reach one. The roster MRB-1 may add is configuration rather than a reachable board, which is why this stays green through it; MRB-3's tab bar is what breaks it, in the pull request that removes this entry.",
              factReads = [],
              factCheck = do
                claims <- pointerClaims
                pure (everyFault [boardActionInventory, claims, singleRepositoryDataset])
            }
      ),
    Declaration
      20
      "Forge adapters for non-GitHub repositories."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "`parseRemoteRepository` resolves both github.com spellings of a remote and refuses GitLab, Bitbucket, Codeberg, and a self-hosted host, naming github.com in the refusal.",
              factRationale =
                "A forge adapter starts with the repository resolving at all. While the only host this parser admits is github.com, a checkout on another forge cannot become a board, whatever else were added.",
              factReads = [],
              factCheck = pure forgeHosts
            }
      )
  ]

-- | The witnesses of the two entries #423 and #424 removed, kept and run.
--
-- Each is stated exactly as it would have been declared while its entry still
-- stood, and the suite requires both to come back /broken/ against today's
-- code. That is what distinguishes this mechanism from one that passes because
-- it asserts nothing: issue #319's completed-history filter is what broke both
-- facts, roughly five weeks before either entry was noticed and removed.
--
-- Re-adding one of these entries to the document is therefore a two-step
-- demonstration: the entry alone fails the coverage check as uncovered, and
-- moving its declaration up into 'declarations' fails the witness check.
retiredDeclarations :: [Declaration]
retiredDeclarations =
  [ Declaration
      3
      "A permanent archive of merged or closed work."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "No criteria the filter panel can reach retains a settled card: toggling any one box of `everyFilterBox` leaves a dataset holding none of a loaded completed history's items.",
              factRationale =
                "An archive of merged or closed work is, at its smallest, a board state the user can return to that still holds settled cards. While no reachable criteria retains one, Kanban keeps no such archive.",
              factReads = [],
              factCheck = pure settledCardsUnreachable
            }
      ),
    Declaration
      20
      "A merged-work history view separate from the live Done column."
      ( Witnessed
          WitnessedFact
            { factStatement =
                "`criteriaDataset` returns `Nothing` — the open generation itself, by identity — for every criteria the filter panel can reach, so no board is ever derived from a second dataset.",
              factRationale =
                "A history view separate from the live board has to be built from a dataset other than the open generation. While every reachable criteria leaves that generation alone, there is no second view for one to be separate from.",
              factReads = [],
              factCheck = pure noSecondDataset
            }
      )
  ]

-- * The facts

cabalPath :: FilePath
cabalPath = "kanban.cabal"

sourceRoot :: FilePath
sourceRoot = "src"

applicationRoot :: FilePath
applicationRoot = "app"

-- | The components kanban.cabal declares, by their whole stanza line.
shippedComponents :: IO (Maybe Text)
shippedComponents = do
  components <- cabalComponents
  pure
    ( sameAs
        "the components kanban.cabal declares"
        ["library", "executable kanban", "test-suite kanban-test"]
        (map fst components)
    )

-- | The dependency set of the two components that ship as the program.
shippedDependencies :: IO (Maybe Text)
shippedDependencies = do
  components <- cabalComponents
  let declared = concat [deps | (name, deps) <- components, name `elem` shippedComponentNames]
  pure
    ( sameAs
        "the dependency set of kanban.cabal's shipped components"
        recordedDependencies
        (dedupe (sort declared))
    )
  where
    shippedComponentNames = ["library", "executable kanban"] :: [Text]

recordedDependencies :: [Text]
recordedDependencies =
  [ "aeson",
    "base",
    "brick",
    "bytestring",
    "containers",
    "directory",
    "filepath",
    "kanban",
    "optparse-applicative",
    "process",
    "text",
    "time",
    "toml-parser",
    "transformers",
    "unicode-transforms",
    "unix",
    "vty"
  ]

-- | Each component stanza of kanban.cabal with the packages it depends on.
--
-- A dependency is a line inside a @build-depends:@ block and nowhere else.
-- Indentation alone would not do: a component's own @ghc-options@ flags are
-- indented too, and @-Wall@ is spelled exactly like a package name.
cabalComponents :: IO [(Text, [Text])]
cabalComponents = do
  contents <- TextIO.readFile cabalPath
  pure (reverse (map (fmap reverse) (walk [] False (Text.lines contents))))
  where
    walk components _ [] = components
    walk components inside (line : rest)
      | isComponentHeading line = walk ((Text.strip line, []) : components) False rest
      | Text.strip line == "build-depends:" = walk components True rest
      | not inside = walk components False rest
      | Just package <- dependencyOn line = walk (record package components) True rest
      -- A blank line, an unindented line, or a field that is not a dependency
      -- closes the block rather than being read as one.
      | otherwise = walk components False rest

    record package components = case components of
      [] -> components
      (name, deps) : others -> (name, package : deps) : others

    isComponentHeading line =
      not (Text.isPrefixOf " " line)
        && takeWhile (/= ' ') (Text.unpack (Text.strip line)) `elem` componentKeywords

    componentKeywords = ["library", "executable", "test-suite", "benchmark", "foreign-library"]

    -- The package name is the first word of an indented line; the version
    -- bound and the trailing comma are not part of it.
    dependencyOn line = case Text.words (Text.strip line) of
      package : _
        | Text.isPrefixOf " " line,
          not (Text.null named),
          Text.all isPackageCharacter named ->
            Just named
        where
          named = Text.dropWhileEnd (== ',') package
      _ -> Nothing

    isPackageCharacter character = character == '-' || character `elem` packageAlphabet
    packageAlphabet = ['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9']

-- | The bound every detached worker's spec carries.
boundedWorkerSpec :: Maybe Text
boundedWorkerSpec =
  pinnedType "a worker spec's runtime bound" workerMaxRuntimeSeconds "WorkerSpec -> Int"

-- | What an idle refresh coordinator plans, at several clock times and after
-- a generation has already been spent.
idleCoordinatorWaits :: Maybe Text
idleCoordinatorWaits
  | all (== PlanWait Nothing) plans = Nothing
  | otherwise =
      Just
        ( "an idle refresh coordinator plans "
            <> showText (filter (/= PlanWait Nothing) plans)
            <> " rather than waiting for a request"
        )
  where
    plans =
      [ snd (planCoordinator moment state)
        | moment <- probeMoments,
          state <-
            [ initialCoordinatorState,
              initialCoordinatorState {coordinatorOpenGeneration = 7}
            ]
      ]

probeMoments :: [UTCTime]
probeMoments =
  [ UTCTime (fromGregorian 1970 1 1) (secondsToDiffTime 0),
    UTCTime (fromGregorian 2026 8 21) (secondsToDiffTime 43200),
    UTCTime (fromGregorian 2099 12 31) (secondsToDiffTime 86399)
  ]

-- | Every board action, by name, in table order.
boardActionInventory :: Maybe Text
boardActionInventory =
  sameAs
    "the dashboard's board actions"
    [ "NextCard",
      "PreviousCard",
      "KillWorking",
      "PreviousColumn",
      "NextColumn",
      "FirstItem",
      "LastItem",
      "OpenSearch",
      "ShowFilter",
      "ToggleEpic",
      "ShowDetails",
      "DismissOrClose",
      "ReviewSelection",
      "SolveSelection",
      "AutoSolveSelection",
      "ShowProcesses",
      "ShowIncidents",
      "RefreshAll",
      "ToggleApproval",
      "ToggleDrainer",
      "MergeDoneCard",
      "ToggleSidebar",
      "ShowSettings",
      "ShowHelp",
      "RepaintTerminal",
      "QuitDashboard"
    ]
    (map showText everyBoardAction)

everyBoardAction :: [BoardAction]
everyBoardAction = [minBound .. maxBound]

-- | The actions that act on the work a card stands for.
mutatingActions :: Maybe Text
mutatingActions =
  sameAs
    "the board actions that act on the work a card stands for"
    ["KillWorking", "ReviewSelection", "SolveSelection", "AutoSolveSelection", "MergeDoneCard"]
    (map showText (filter mutatesSelectedWork everyBoardAction))

-- | The bindings table takes the action and nothing else.
compileTimeBindings :: Maybe Text
compileTimeBindings = pinnedType "the board's binding table" binding "BoardAction -> KeyBinding"

-- | The keys the persisted settings document carries.
settingsDocumentKeys :: Maybe Text
settingsDocumentKeys =
  sameAs "the keys the settings document carries" ["chatVerbosity", "schemaVersion"] observed
  where
    observed = case toJSON defaultSettings of
      Object fields -> sort (map (Text.pack . Key.toString) (KeyMap.keys fields))
      other -> [showText other]

-- | A decided press is a pure function of the dashboard's own state.
pureBoardPress :: Maybe Text
pureBoardPress =
  pinnedType
    "the answer to a decided pointer press"
    boardMousePress
    "BoardMouseAction -> AppState -> AppState"

-- | One board's dataset comes from at most one repository's snapshot.
singleRepositoryDataset :: Maybe Text
singleRepositoryDataset =
  pinnedType
    "the dataset a board is derived from"
    criteriaDataset
    "FilterCriteria -> Maybe RepoSnapshot -> Maybe CompletedHistory -> Maybe RepoSnapshot"

-- | The vector Kanban builds to merge one pull request.
mergeDelegation :: Maybe Text
mergeDelegation = everyFault [withoutConfig, withConfig]
  where
    repository = Repository "/checkout" "coghex" "kanban"
    drainer = "/opt/kanban/drain_prs.py"
    withoutConfig =
      sameAs
        "the merge argument vector"
        ["/opt/kanban/drain_prs.py", "--path", "/checkout", "--repo", "coghex/kanban", "--pr", "41"]
        (directMergeArguments drainer repository Nothing 41)
    withConfig =
      sameAs
        "the merge argument vector with a selected configuration"
        [ "/opt/kanban/drain_prs.py",
          "--path",
          "/checkout",
          "--repo",
          "coghex/kanban",
          "--pr",
          "41",
          "--config",
          "/etc/kanban/config.toml"
        ]
        (directMergeArguments drainer repository (Just "/etc/kanban/config.toml") 41)

-- | Every `gh` vector the board builds, over both traversals.
githubRequestsAreReads :: Maybe Text
githubRequestsAreReads = everyFault (map inspect (openVectors <> historyVectors))
  where
    repository = Repository "/checkout" "coghex" "kanban"
    openVectors =
      [ graphqlArguments repository state
        | cursor <- [Nothing, Just "cursor"],
          subIssues <- [True, False],
          let state = probeFetchState {issueCursor = cursor, pullRequestCursor = cursor, fetchSubIssues = subIssues}
      ]
    historyVectors =
      [ historyGraphqlArguments repository state
        | cursor <- [Nothing, Just "cursor"],
          let state = initialHistoryFetchState {historyIssueCursor = cursor, historyPullRequestCursor = cursor}
      ]
    inspect vector =
      everyFault
        [ sameAs "the subcommand of a gh vector" ["api", "graphql"] (take 2 vector),
          documentFault (concat [drop 6 argument | argument <- vector, take 6 argument == "query="])
        ]
    documentFault document
      | not (take 6 document == "query(") =
          Just ("a GraphQL document Kanban sends begins " <> showText (take 20 document) <> " rather than `query(`")
      | "mutation" `isInfixOf` document =
          Just "a GraphQL document Kanban sends contains a mutation"
      | otherwise = Nothing

probeFetchState :: FetchState
probeFetchState =
  FetchState
    { fetchedIssues = [],
      fetchedPullRequests = [],
      issueCursor = Nothing,
      pullRequestCursor = Nothing,
      fetchMoreIssues = True,
      fetchMorePullRequests = True,
      fetchSubIssues = True,
      fetchWarnings = []
    }

-- | Whether the configuration schema knows any cadence-shaped key.
noCadenceConfiguration :: Maybe Text
noCadenceConfiguration = everyFault (map probe cadenceKeys)
  where
    cadenceKeys =
      [ "refresh_interval",
        "refresh_interval_seconds",
        "refresh_seconds",
        "poll_interval_seconds",
        "poll_seconds",
        "auto_refresh_seconds"
      ]
    probe key = case decodeConfigText (key <> " = 60\n") of
      Left message -> Just ("the configuration schema rejected " <> key <> " outright (" <> message <> ")")
      Right (config, warnings)
        | null warnings -> Just ("the configuration schema knows the key " <> key)
        | config /= defaultRawConfig -> Just ("the key " <> key <> " changed the resolved configuration")
        | otherwise -> Nothing

-- | Which remotes resolve to a board.
forgeHosts :: Maybe Text
forgeHosts = everyFault (map probe remotes)
  where
    remotes =
      [ ("git@github.com:coghex/kanban.git", True),
        ("https://github.com/coghex/kanban.git", True),
        ("https://gitlab.com/coghex/kanban.git", False),
        ("git@bitbucket.org:coghex/kanban.git", False),
        ("https://codeberg.org/coghex/kanban.git", False),
        ("https://git.example.com/coghex/kanban.git", False)
      ]
    probe (remote, expected) = case (parseRemoteRepository remote, expected) of
      (Right _, True) -> Nothing
      (Left _, False) -> Nothing
      (Right identity, False) ->
        Just ("the remote " <> remote <> " now resolves to " <> showText identity)
      (Left message, True) ->
        Just ("the remote " <> remote <> " no longer resolves (" <> message <> ")")

-- | Whether any module under src/ dispatches a pointer release.
noPointerRelease :: IO (Maybe Text)
noPointerRelease = absentFrom "vty's MouseUp" "MouseUp" [sourceRoot]

-- | Whether anything under src/ or app/ emits an OSC 52 sequence.
noClipboardEscape :: IO (Maybe Text)
noClipboardEscape = absentFrom "the OSC 52 introducer" "]52;" [sourceRoot, applicationRoot]

-- | The pointer presses the board claims, summarized per target family and
-- button so the recorded inventory stays readable.
pointerClaims :: IO (Maybe Text)
pointerClaims = do
  state <- testAppState (fixtureBoard [])
  pure (sameAs "the pointer presses the board claims" declaredPointerClaims (claimedPresses state))

declaredPointerClaims :: [(Text, Text, Text, Text)]
declaredPointerClaims =
  sort
    [ ("ApprovalButton", "BLeft", "no modifiers", "ToggleApprovalFromClick"),
      ("CardTarget", "BLeft", "any modifiers", "SelectOrOpenCardAt"),
      ("CardTarget", "BRight", "any modifiers", "OpenRunningProcessAt"),
      ("CardTarget", "BScrollDown", "any modifiers", "ScrollColumnBy"),
      ("CardTarget", "BScrollUp", "any modifiers", "ScrollColumnBy"),
      ("ColumnViewport", "BScrollDown", "any modifiers", "ScrollColumnBy"),
      ("ColumnViewport", "BScrollUp", "any modifiers", "ScrollColumnBy"),
      ("DrainerButton", "BLeft", "no modifiers", "ToggleDrainerFromClick"),
      ("EpicTarget", "BLeft", "any modifiers", "ToggleEpicFromClick"),
      ("EpicTarget", "BScrollDown", "any modifiers", "ScrollColumnBy"),
      ("EpicTarget", "BScrollUp", "any modifiers", "ScrollColumnBy"),
      ("FilterBoxTarget", "BLeft", "any modifiers", "ToggleFilterBoxFromClick"),
      ("UpdateButton", "BLeft", "no modifiers", "RefreshAllFromClick")
    ]

-- | One row per (target family, button) the board claims anything for.
--
-- A family's row is collapsed over every board column and every probed
-- modifier combination: a claim that differed between columns, or that some
-- modifier combinations answered and others did not, is reported as @varies@
-- and matches no recorded row.
claimedPresses :: AppState -> [(Text, Text, Text, Text)]
claimedPresses state =
  sort
    [ (family, buttonName, policy, action)
      | (family, targets) <- probeTargets,
        button <- probeButtons,
        let buttonName = showText button,
        Just (policy, action) <- [classify [(modifiers, boardMouseAction state target button modifiers) | target <- targets, modifiers <- probeModifiers]]
    ]
  where
    classify results = case claimed of
      [] -> Nothing
      (_, decided) : _
        | any ((/= constructorOf decided) . constructorOf . snd) claimed ->
            Just ("varies", showText (map snd claimed))
        | length claimed == length results -> Just ("any modifiers", constructorOf decided)
        | all (null . fst) claimed -> Just ("no modifiers", constructorOf decided)
        | otherwise -> Just ("varies", showText (map fst claimed))
      where
        claimed = [(modifiers, decided) | (modifiers, Just decided) <- results]

    constructorOf = Text.takeWhile (/= ' ') . showText

-- | Every @Name@ the dashboard draws, grouped into the family a recorded row
-- names, with one target per board column where the name carries one.
probeTargets :: [(Text, [Name])]
probeTargets =
  [ ("ApprovalButton", [ApprovalButton]),
    ("BoardViewport", [BoardViewport]),
    ("CardTarget", [CardTarget column 0 | column <- everyColumn]),
    ("ColumnViewport", [ColumnViewport column | column <- everyColumn]),
    ("DetailsPanel", [DetailsPanel]),
    ("DetailsViewport", [DetailsViewport]),
    ("DrainerButton", [DrainerButton]),
    ("EpicTarget", [EpicTarget column 0 7 | column <- everyColumn]),
    ("FilterBoxTarget", [FilterBoxTarget box | box <- everyFilterBox]),
    ("IncidentTarget", [IncidentTarget (DrainerIncidentRef "drainer")]),
    ("IncidentsPanel", [IncidentsPanel]),
    ("IncidentsViewport", [IncidentsViewport]),
    ("ProcessTarget", [ProcessTarget (SolveAgent 1)]),
    ("ProcessesPanel", [ProcessesPanel]),
    ("ProcessesViewport", [ProcessesViewport]),
    ("PullRequestReviewPanel", [PullRequestReviewPanel]),
    ("PullRequestReviewViewport", [PullRequestReviewViewport]),
    ("ReviewPanel", [ReviewPanel]),
    ("ReviewViewport", [ReviewViewport]),
    ("SettingsPanel", [SettingsPanel]),
    ("SettingsRosterTarget", [SettingsRosterTarget role provider | role <- allRoles, provider <- allProviders]),
    ("SettingsViewport", [SettingsViewport]),
    ("SolvePanel", [SolvePanel]),
    ("SolveViewport", [SolveViewport]),
    ("UpdateButton", [UpdateButton])
  ]

everyColumn :: [BoardColumn]
everyColumn = [minBound .. maxBound]

probeButtons :: [Vty.Button]
probeButtons = [Vty.BLeft, Vty.BMiddle, Vty.BRight, Vty.BScrollUp, Vty.BScrollDown]

probeModifiers :: [[Vty.Modifier]]
probeModifiers =
  [ [],
    [Vty.MShift],
    [Vty.MCtrl],
    [Vty.MMeta],
    [Vty.MAlt],
    [Vty.MCtrl, Vty.MShift]
  ]

-- * The retired facts

-- | Whether any reachable criteria retains a settled card.
settledCardsUnreachable :: Maybe Text
settledCardsUnreachable = case retaining of
  [] -> Nothing
  boxes ->
    Just
      ( "the filter boxes "
          <> showText boxes
          <> " now retain settled cards a completed history supplied"
      )
  where
    retaining =
      [ box
        | box <- everyFilterBox,
          let dataset = criteriaDataset (toggleFilterBox box defaultFilterCriteria) (Just openGeneration) (Just completedGeneration),
          any retained dataset
      ]
    retained snapshot =
      any ((== 900) . issueNumber) snapshot.snapshotIssues
        || any ((== 901) . pullRequestNumber) snapshot.snapshotPullRequests

-- | Whether any reachable criteria derives a board from a second dataset.
noSecondDataset :: Maybe Text
noSecondDataset = case deriving' of
  [] -> Nothing
  boxes ->
    Just
      ( "the filter boxes "
          <> showText boxes
          <> " now derive a board from a dataset other than the open generation"
      )
  where
    deriving' =
      [ box
        | box <- everyFilterBox,
          Just _ <- [criteriaDataset (toggleFilterBox box defaultFilterCriteria) (Just openGeneration) (Just completedGeneration)]
      ]

-- | The live open generation the retired facts are probed against.
openGeneration :: RepoSnapshot
openGeneration =
  RepoSnapshot
    { snapshotIssues = [baseIssue 1 []],
      snapshotPullRequests = [basePullRequest 2 [] False []],
      snapshotFetchedAt = epoch
    }

-- | Settled work, numbered so that its presence in a dataset is unambiguous.
completedGeneration :: CompletedHistory
completedGeneration =
  CompletedHistory
    { historyIssues = [baseIssue 900 []],
      historyPullRequests = [basePullRequest 901 [] False []],
      historyFetchedAt = epoch
    }

-- * Small helpers

-- | Every fault among the clauses of one fact, joined. All of them rather
-- than the first, so a fact that broke in two places says so in one run.
everyFault :: [Maybe Text] -> Maybe Text
everyFault faults = case [fault | Just fault <- faults] of
  [] -> Nothing
  found -> Just (Text.intercalate "; " found)

-- | A fact stated as an exact comparison, reported as what it is now instead.
sameAs :: (Eq value, Show value) => Text -> value -> value -> Maybe Text
sameAs subject expected actual
  | expected == actual = Nothing
  | otherwise = Just (subject <> " is now " <> showText actual <> " rather than " <> showText expected)

-- | A fact stated as a type, compared at run time so a changed signature is
-- reported here rather than only refusing to compile.
pinnedType :: (Typeable value) => Text -> value -> Text -> Maybe Text
pinnedType subject value expected
  | actual == expected = Nothing
  | otherwise = Just (subject <> " now has the type " <> actual <> " rather than " <> expected)
  where
    actual = showText (typeOf value)

-- | A fact stated as the absence of a string from a tree of Haskell modules.
--
-- A scan that found no modules to read would report the absence of anything,
-- so too few of them is itself the fault: an empty tree is the one way this
-- shape of fact can pass while asserting nothing.
absentFrom :: Text -> Text -> [FilePath] -> IO (Maybe Text)
absentFrom subject needle roots = do
  sources <- concat <$> traverse haskellSources roots
  found <- traverse contains sources
  pure $ case [path | (path, True) <- zip sources found] of
    _ | length sources < 20 -> Just (showText roots <> " held only " <> showText (length sources) <> " Haskell modules, so the scan for " <> subject <> " read almost nothing")
    [] -> Nothing
    paths -> Just (subject <> " now appears in " <> showText paths)
  where
    contains path = Text.isInfixOf needle <$> TextIO.readFile path

-- | Every Haskell module under one root.
haskellSources :: FilePath -> IO [FilePath]
haskellSources root = do
  directory <- doesDirectoryExist root
  if not directory
    then pure [root | takeExtension root == ".hs"]
    else do
      entries <- listDirectory root
      concat <$> traverse (haskellSources . (root </>)) (sort entries)

dedupe :: (Eq value) => [value] -> [value]
dedupe = foldr (\value seen -> value : filter (/= value) seen) []

showText :: (Show value) => value -> Text
showText = Text.pack . show

-- | Two boards, one repository, two processes — and the same again for two
-- repositories that are not one.
--
-- Run rather than inspected, because the entry it witnesses is about what the
-- operating system does when two processes want the same lock, and there is no
-- artefact in the tree that states the answer. The harness is
-- "Spec.Support.LeaseProbes", the same one issue #501's acceptance rests on;
-- every probe is the suite binary run again, and each attempts the lease
-- exactly once and holds whatever it took until the parent lets it go, so
-- which of them is refused is decided by the kernel rather than by timing.
--
-- Every failure the harness raises is a broken witness rather than a crashed
-- example: a probe that never started says nothing about the lease, and this
-- must report that rather than let it stand as a pass.
boardLeaseWitness :: IO (Maybe Text)
boardLeaseWitness = do
  attempted <- try @SomeException $
    withTemporaryCacheRoot $ \root -> do
      let cache = root </> "cache"
      sameRepository <-
        withLeaseProbes
          (root </> "same")
          [ LeaseProbe "upper" (leaseWitnessRepository "Coghex" "Kanban") cache "both",
            LeaseProbe "lower" (leaseWitnessRepository "coghex" "kanban") cache "both"
          ]
          $ \probes -> do
            openLeaseGate probes "both"
            upper <- awaitLeaseOutcome probes "upper"
            lower <- awaitLeaseOutcome probes "lower"
            pure (sort [upper, lower])
      distinctRepositories <-
        withLeaseProbes
          (root </> "distinct")
          [ LeaseProbe "owner" (leaseWitnessRepository "coghex-kan" "ban") cache "both",
            LeaseProbe "name" (leaseWitnessRepository "coghex" "kan-ban") cache "both"
          ]
          $ \probes -> do
            openLeaseGate probes "both"
            owner <- awaitLeaseOutcome probes "owner"
            name <- awaitLeaseOutcome probes "name"
            pure [owner, name]
      pure (sameRepository, distinctRepositories)
  pure $ case attempted of
    Left problem -> Just ("the lease probes could not be run (" <> Text.pack (show problem) <> ")")
    Right (sameRepository, distinctRepositories)
      | sameRepository /= [ProbeAcquired, ProbeHeld] ->
          Just ("two spellings of one repository were told " <> Text.pack (show sameRepository))
      | distinctRepositories /= [ProbeAcquired, ProbeAcquired] ->
          Just ("two distinct repositories were told " <> Text.pack (show distinctRepositories))
      | otherwise -> Nothing

-- | A repository for the probes above. The checkout path is deliberately one
-- that does not exist: the lease resolves from the identity and the cache root
-- alone, so a witness that started to depend on this machine would fail rather
-- than quietly read it.
leaseWitnessRepository :: Text -> Text -> Repository
leaseWitnessRepository = Repository "/nonexistent/checkout"
