# Code health report

A file-by-file audit of the Kanban repository, written for a reader asking two
questions:

1. **Is this project actually portable?** Kanban exists to support
   `~/work/synarchy`, but it is tracked as its own project and must be
   project-agnostic — clone it on a new machine, install it, and pick up
   in-progress work on a different repository immediately.
2. **What did the automated pipeline let through?** This repository was built
   from the ground up by an agent workflow. That produces working code with
   characteristic scars: files that grew without ever being split, logic
   duplicated across bundles that were never reconciled, and contracts recorded
   in prose instead of enforced by a test.

Findings are numbered and self-contained so they can be processed one at a time.
Each carries a severity, the evidence that established it, and what a fix would
have to do. Severity is about **the cost of leaving it alone**, not about how
broken the code is today:

- **High** — blocks the portability goal, or is a live correctness/divergence risk.
- **Medium** — real maintenance cost, will keep generating bugs, but nothing is
  wrong today.
- **Low** — hygiene and polish.

Status: **in progress.** This audit is being done deliberately, a few files at a
time, rather than in one sweep. The "Coverage log" at the bottom records exactly
what has been read so far, so the audit can resume without re-reading.

### Status markers

Each finding heading carries its disposition, so this file is the durable cursor
and `/process-report` can resume from it without conversation history:

- **`[#N]`** — linked to GitHub issue N, whether newly filed or pre-existing.
- **`[no-issue]`** — reviewed and deliberately never to be filed. Carries a
  `> **Disposition:**` note giving the evidence-backed reason and the consequence
  of leaving the code unchanged.
- **`[deferred]`** — real, should be filed, but blocked. Carries a
  `> **Deferred:**` note naming what blocks it and the concrete precondition that
  clears it. `/process-report` skips these until no unmarked finding remains, then
  promotes the first whose precondition is satisfied.
- **no marker** — unprocessed.

`[no-issue]` and `[deferred]` are not interchangeable: the first closes a finding,
the second keeps it open. Nothing here is marked `[no-issue]` merely for being
unclear.

Issue numbers appearing in prose, in a `Related` list, or inside a fix shape are
not dispositions — only a bracketed marker in a heading is.

## Status

A box is checked only for a terminal disposition — filed or closed. `[deferred]`
and unmarked findings stay unchecked, so the unchecked count is the work this
report still owes.

- [x] 1. `test/Spec.hs` is one 9,200-line module — [#148]
- [x] 2. `UI.hs` is a god-module — [#50]
- [x] 3. `AppState` has seven parallel session tables — [#51]
- [x] 4. `drain_prs.py` is 3,967 lines — [no-issue]
- [x] 5. `Worker.hs` threads fifteen mutable cells positionally — [#153]
- [x] 5a. `Review.hs` exceeds 2,000 lines — [no-issue]
- [x] 6. LaunchAgent label is a machine-wide singleton — [#147]
- [x] 6a. Launchd label defined three times — [#146]
- [x] 7. `.drain-prs.json` is repo-specific at the root — [no-issue]
- [x] 7a. Issue-reviewer install path spelled twice, in two languages — [#155]
- [x] 8. `review_pr.py` duplicated and diverged — [no-issue]
- [x] 9. `launchctl` is undeclared — [#149]
- [x] 10. Process-group hardening not swept — [no-issue]
- [x] 11. `Drainer.hs` has no platform guard — [#146]
- [x] 12. Drainer refuses to start on a dirty tree — [#145]
- [x] 12a. #15's capture fix reached two of three review runners — [#154]
- [x] 13. Repository override key matched exactly and silently — [#150]
- [x] 14. `bug`, `ui`, and `input` compiled into the theme — [#152]

**18 of 18 resolved. 0 deferred, 0 unprocessed.** Every finding has been processed.

Findings 2 and 3 were cleared by reading `src/Kanban/UI.hs` end to end. Both were
already owned by open issues (#50, #51), so neither was refiled; the read produced
two new issues instead — **#151**, a live defect that is a fifth instance of the
drift #51 describes, and **#152**, recorded here as finding 14.

Finding 5 was cleared by reading `src/Kanban/Worker.hs` end to end, and **its
original premise turned out to be wrong** — see the finding for the correction.
It produced **#153**, and split off 5a for the module it had bundled in on that
same wrong premise.

Finding 5a was closed by reading `src/Kanban/Review.hs` end to end. The size claim
did not warrant an issue, but the read produced **#154** and **#155**, recorded as
findings 12a and 7a in the parts whose patterns they belong to.

Worth recording as a pattern: three large modules have now been read closely and
produced three *different* diagnoses — `UI.hs` tangled, `Worker.hs` cohesive but
hazardously parameterized, `Review.hs` multi-subject with clean seams and two
unrelated defects. The report's structural prediction was right once and wrong
twice. Line count reliably identifies a module worth reading; it predicts nothing
about what will be found there. `GitHub.hs` (1,393 lines, in the coverage log)
should be treated as a reading prompt, not as a claim.

A second pattern, now with three instances (10, 12, 12a): this codebase reliably
fixes a defect at the sites named in the issue, and reliably leaves the same
defect standing wherever it was not enumerated. 12a is the sharpest case — #15
named two runners and fixed exactly two, and the third still carries the bug a
year of intervening work never surfaced. Issues here are better specified by
removing the alternative than by listing the call sites.

---

## Filing plan

Which findings become GitHub issues, in what order, and why that order. Wave 1 is
deliberately small: the audit is roughly a third done, and filing everything now
would flood the board with findings that later reading may reshape.

Sequencing matters here because four of these touch the same three files
(`tools/drain_prs.py`, `tools/drain_prs_service.py`, `src/Kanban/Drainer.hs`).
They are ordered so each lands cleanly on the last.

### Wave 1 — file now

| # | Filed | Working title | From | Size | Depends on |
| --- | --- | --- | --- | --- | --- |
| A | **#145** | Let the drainer start from a dirty checkout, using the autostash it already has | 12 | Small — mostly deletion | — |
| B | **#146** | Resolve the drainer's LaunchAgent through an installer-written record instead of a hardcoded label | 6a, 11 | Medium | A (same files) |
| C | **#147** | Give each repository its own drainer instead of one machine-wide singleton | 6 | **Contract change** | B |
| D | **#148** | Split `test/Spec.hs` into per-subsystem spec modules | 1 | Large — mechanical, behavior-free | — (independent) |
| ~~E~~ | absorbed | ~~Report why the drainer is unavailable instead of a raw `IOException`~~ | 11 | — | folded into B |

**Resolved along the way — where the label should live.** B was originally scoped
as "define the label once," which is impossible as stated: Haskell cannot import a
Python constant. What crosses the language boundary must be a string both sides
hardcode, an algorithm both sides implement, or data one side writes and the other
reads. Only the third survives making the label per-repository, since a derived
label would otherwise force Haskell and Python to implement identical sanitization
and length rules, with disagreement presenting as "drainer not found" while both
sides look correct in isolation.

The chosen shape: the installer writes the label and plist path into the
`config.json` record that already exists at
`~/Library/Application Support/kanban/pr-drainer/`, and `Drainer.hs` reads the
record to locate the plist — then still reads the plist itself via `plutil` for the
controller argv, so the plist stays authoritative for what launchd actually runs.
Written on the belief that `Review.hs` already used this pattern for the
issue-review backend and `Drainer.hs` was the outlier. **Finding 7a later
disproved that** — `Review.hs:546` duplicates its default across the language
boundary exactly as the drainer's label does, and #146 carries a correcting
comment. Finding 11 folded in because it rewrites the same function.

Notes on the order:

- **#145 → #146 → #147 is a strict serial chain.** All three edit
  `tools/drain_prs_service.py` and `src/Kanban/Drainer.hs`; #145 and #146 also
  both edit `tools/drain_prs.py`. Working them out of order will conflict.
- **#145 first** because it is the one blocking the maintainer's daily routine,
  and because it is subtractive — it shrinks the surface the other two modify.
- **#146 before #147.** #147 looks like a one-line label change and is not. Until
  the discovery record exists, making the label per-repository would force Haskell
  and Python to independently derive the same string.
- **#147 is a contract change**, not only an implementation change:
  `docs/design.md` Milestone 6 and `docs/pr-drainer.md:38` both state the
  singleton model as designed behavior. It is the only Wave 1 issue that edits the
  authoritative contract.
- **#148 and #149 are independent** of the chain and of each other, and can run in
  parallel with everything. #148 should land before the source-side splits in
  Part 1, since those need a suite that can be built selectively.
- **The former issue E was absorbed into #146** rather than filed. Both rewrite
  `discoverDrainerController`, so two back-to-back PRs over the same function
  would only have created a conflict.

**Resolved along the way — what identifies a drainer.** #147 keys a drainer by its
GitHub `owner/name` slug rather than its checkout path. Two clones of the same
repository then resolve to the same label, which makes it structurally impossible
to run two drainers merging the same pull requests — a failure the existing
per-path run lock cannot catch, because the two checkouts really are different
paths. The lock is kept as a second guard. The accepted cost: two checkouts of one
repository cannot be drained independently. The sharp edge for implementation is
case — `Coghex/Kanban` and `coghex/kanban` are distinct to GitHub, so a
lowercasing derivation would collapse them.

### Also filed

| Filed | Title | From | Depends on |
| --- | --- | --- | --- |
| **#149** | Declare `launchctl` and bring `tools/` into the agent-workflow contract's scanned surface | 9 | — (independent) |
| **#151** | Report a waiting issue revision as live so the processes overlay can kill it | 3 | — (must land *ahead* of #51) |
| **#152** | Stop hardcoding `bug`, `ui`, and `input` in label chip coloring | 14 | — (independent) |
| **#153** | Name the worker supervisor's mutable cells instead of threading them positionally | 5 | — (independent) |
| **#154** | Apply #15's separate exit and capture bounds to the Claude reviewer subprocess | 12a | — (independent) |
| **#155** | Resolve the canonical issue reviewer through an installer-written record instead of a duplicated default path | 7a | should share #146's record mechanism |

#149 was promoted out of Wave 2 because it was already fully evidenced, small,
and — unlike everything else remaining — independent of the #145 → #146 → #147
chain. With that chain strictly serial, the board otherwise had only #148 as
parallel work.

#151 and #152 came out of the line-by-line read of `UI.hs`. #151 is a correctness
bug rather than code health, and is deliberately *not* folded into #51: that issue
is sequenced after #50, so filing the fix inside it would park a live defect behind
two large refactors.

### Already owned by pre-existing issues

Findings 2 and 3 were not refiled. Both had open issues predating this audit:

| Existing | Title | From |
| --- | --- | --- |
| **#50** | Split the 4,340-line UI.hs along its natural seams (`reviewed:approve`) | 2 |
| **#51** | Unify the three near-identical agent-session record types — drift has already cost features | 3 |

Worth knowing before either is picked up: `UI.hs` has grown from the 4,340 lines
#50 cites to 5,706, so every approximate line range in that issue is stale.

### Wave 2 — resolved deferrals

Findings **4 and 7** were the last two deferrals. Both preconditions cleared, and
both are now closed as `[no-issue]`:

- **Blocked on sequencing** (4) — #147 landed, so the file could be re-read in
  its new shape. The read confirmed a phase-ordered module below the ~5,000-line
  Python threshold recorded by #159, with no demonstrated defect that a package
  split would prevent.
- **Premise unverified** (7) — verification showed that `.drain-prs.json` is
  already loaded from each target repository's root. The shared repositories
  table does not duplicate those drainer settings, but it does not need to.

Findings **2, 3, 5, 5a, and 8** have all left this wave, and how they left is worth
recording, because deferral earned its keep in three different ways:

- **2 and 3** were already owned by open issues (#50, #51). Reading `UI.hs` end to
  end confirmed both and produced #151 and #152. See "Already owned by pre-existing
  issues" above.
- **5 and 5a** were written from line counts. Reading disproved 5's stated premise
  outright and reduced 5a to no-issue — while turning up four defects neither had
  predicted (#153, #154, #155, and 12a). Filing either unread would have asked for
  the wrong work.
- **8** was verified rather than read-and-discarded: its central premise held, and
  two of its supporting claims did not. It is closed as an accepted risk, not as a
  refuted finding — see its Disposition note.

Findings **4, 5a, 7, 8, and 10** are closed as `[no-issue]`; each carries a
Disposition note giving the reason and the consequence of leaving the code
unchanged.

---

## Part 1 — Oversized files

The single most visible artifact of an automated build process: every file grew
by accretion, and nothing was ever split, because no agent's task was ever "make
this smaller."

### [#148] 1. `test/Spec.hs` is a 9,200-line single-file test suite

**Severity: High** — this is the largest file in the repository by a factor of
1.6, and it is the one every behavior change has to touch.

The entire Haskell test suite is one module. `kanban.cabal` declares exactly one
test target (`kanban-test`, `main-is: Spec.hs`) with no other modules in
`hs-source-dirs: test`, so there is no seam to split along — the file is 35% of
all Haskell in the project.

Consequences, all of which the pipeline is currently paying:

- Every agent working any issue recompiles and relinks the whole suite. There is
  no way to run only the tests covering the area being changed, which is exactly
  what `CLAUDE.md` asks contributors to do ("run what covers the paths you
  changed").
- Two agents on two branches touching unrelated subsystems conflict in this file
  by construction. Given the merge-conflict incidents this repo has already
  recorded, that is not hypothetical.
- The suite reportedly leaks fixture processes between tests (a worker-deadline
  test flakes under load because strays survive). A monolith makes that class of
  cross-test interference invisible — there is no module boundary that would
  have contained it.

**Fix shape:** split by the subsystem groups `CLAUDE.md` already names, e.g.
`test/DomainSpec.hs`, `test/WorkerSpec.hs`, `test/UISpec.hs`,
`test/GitHubSpec.hs`, with shared fixture helpers in `test/Support/*.hs`, and add
them to `other-modules` in the test target. This is a mechanical, behavior-free
change and should be sequenced *before* the source-side splits below, so that
those splits land against a suite that can be selectively built.

### [#50] 2. `src/Kanban/UI.hs` is a 5,706-line god-module

> **Disposition:** Already owned by #50, "Split the 4,340-line UI.hs along its
> natural seams", which is open and carries `reviewed:approve`. The full
> line-by-line read that cleared this finding's deferral confirmed the concern and
> supplied new evidence, posted to that issue rather than filed separately.

**Severity: High** — it is the widest blast radius in the codebase.

The whole module has now been read, lines 1–5,706. Two corrections to what #50
records, both material to whoever solves it:

- **The file has grown 31% since #50 was filed** — 4,340 lines then, 5,706 now.
  Every approximate line range in that issue's seam list is stale.
- **The strongest argument for the split is not size.** The module already
  contains roughly fifteen pure decision types and predicates, each carrying a
  comment saying it was extracted so it could be tested without an `EventM` or
  Brick harness — `OverlayMouseAction` (`:2358`), `ReviewDigitAction` (`:2845`),
  `ReviewCancelAction` (`:3004`), `TranscriptGeometry` (`:2658`),
  `ReviewTickArmOutcome` (`:4703`), `ReviewTickFireOutcome` (`:4723`), and the
  rest — plus two pure render seams, `CardEnv` (`:897`) and `DetailsEnv`
  (`:1894`), whose own comments say they exist to keep rendering exercisable on
  its own. The pattern is understood; it is applied inconsistently. `solveBadge`
  (`:1212`) and `reviewBadge` (`:1251`) sit beside the card code and reach into
  `AppState` directly, bypassing the `CardEnv` that was built for them and already
  carries `cardSolveSessions`. The one place the pattern was *not* applied to
  review liveness is where #151's bug lives.

Measured: 380 top-level definitions, 25 `data`/`newtype` declarations, a
~100-entry explicit export list, and a 35-field `AppState` record. It currently
holds at least six responsibilities that have nothing to do with each other:

| Responsibility | Evidence |
| --- | --- |
| Brick application wiring and the main loop | `runDashboard`, `AppEvent`, `BChan` plumbing |
| The entire application state | `AppState` (35 fields), `Name`, `Overlay` |
| Board/card rendering | `drawCardFrame`, `CardEnv`, tracker header and label-chip layout |
| Details and transcript rendering | `drawDetails`, `DetailsEnv`, `TranscriptGeometry`, `TranscriptSession` |
| Theme and attribute definitions | `themeFor`, `approvedAttr`, `pendingAttr`, `problemAttr`, `revisedAttr`, `trackerAttr`, … |
| Pure decision logic with no Brick dependency | `decideReviewTickArm`, `decideReviewTickFire`, `resolveProcessClick`, `resolveProcessSelection`, `resolveReviewDigitAction`, `resolveReviewCancelAction`, `overlayMouseAction`, `reconcileReviewSessions`, `followAfterScroll`, `transcriptShouldTail` |
| Tunable constants | `codexRefreshTimeoutMicros`, `claudeRefreshTimeoutMicros`, `githubRefreshTimeoutMicros`, `cardExcerptLimit` |

The last row of that table is the most telling. A large family of `decide*` /
`resolve*` functions was clearly factored out *specifically so it could be unit
tested without a terminal* — the right instinct — but then left in the same
module as the Brick code, so the separation exists in naming convention only and
the compiler does not enforce it.

**Fix shape:** the seams are already visible in the export list. Extract in this
order, smallest-risk first, each as its own PR:

1. `Kanban.UI.Theme` — attributes and `themeFor`. Pure, no dependencies on the rest.
2. `Kanban.UI.Decide` (or fold into existing domain modules) — the `decide*` /
   `resolve*` / `follow*` family. This is the highest-value extraction: it makes
   "this logic is terminal-independent" a compile-time fact.
3. `Kanban.UI.Card` and `Kanban.UI.Details` — rendering, keyed off the existing
   `CardEnv` / `DetailsEnv` records, which are already the right abstraction for
   this cut.
4. `Kanban.UI.State` — `AppState`, `Overlay`, `Name`, `AppEvent`.

Leave `Kanban.UI` as the app wiring plus a re-export shim so downstream imports
and the test suite do not churn.

### [#51] 3. `AppState` tracks seven parallel `Map Int` session tables

> **Disposition:** Already owned by #51, "Unify the three near-identical
> agent-session record types — drift has already cost features". The full read of
> `UI.hs` confirmed the concern, and the live defect it turned up was filed
> separately as **#151** because #51 is explicitly sequenced after #50 and a
> correctness fix must not wait on two large refactors.

**Severity: Medium** — a live correctness hazard rather than a style complaint.
The hazard is no longer hypothetical; see "Confirmed consequence" below.

Within `AppState`:

```haskell
appReviewSessions            :: Map Int ReviewSession
appSolveSessions             :: Map Int SolveSession
appSolveProcesses            :: Map Int ManagedProcess
appCanonicalReviewProcesses  :: Map Int ManagedProcess
appPullRequestReviewSessions :: Map Int PullRequestReviewSession
appPullRequestProcesses      :: Map Int ManagedProcess
```

Six maps (plus `appWorkers` / `appWorkerMonitors` as a seventh pairing) keyed by
the same issue/PR number, each of which must be inserted into and — critically —
*deleted from* in lockstep. Nothing in the type system enforces that. Every
cleanup path has to remember all six, and an agent adding a seventh session kind
has to find and update every site that sweeps the other six.

This is precisely the shape that produces "session already resolved" and orphaned
process bugs, and the export list shows the codebase already fighting it:
`pullRequestSessionAlreadyResolved`, `solveSessionAlreadyResolved`,
`reviewSessionReusable`, `pullRequestSessionReusable`, `reusableSolveSession` —
five near-identical predicates, one per table.

**Confirmed consequence (filed as #151).** "Is this review session's turn live?"
is written four times, and one copy disagrees. `reviewPhaseActive` (`:4048`) is
the canonical top-level answer; `markDisconnected` (`:4675`) and
`requestDashboardQuit` (`:2345`) agree with it; `agentSessionEntries` (`:1592`)
hand-rolls its own and omits `ReviewWaiting`. Two of those definitions share the
name `reviewSessionHasLiveTurn` while meaning different things, and both sit in
`where` clauses, so nothing warns. The result is user-visible: while a revision
agent waits on a command-approval prompt, `q` refuses to quit and tells you to
kill the session, and `x` in the processes overlay then refuses with "no live
process to kill" — even though `killReviewAgent`, directly beneath that gate, is
prepared to interrupt the turn. This is a fifth drift consequence beyond the four
#51 already lists.

**Further evidence from the full read.** The parallel structure is wider than the
maps alone:

- The same session split is enumerated **five times at the type level** —
  `AgentSessionRef` (`:414`), `TranscriptSession` (`:2629`), three `Overlay`
  constructors, three viewport `Name`s, three panel `Name`s — with hand-written
  mappings between them (`transcriptViewport`, `displayedTranscript`,
  `transcriptFollowing`, `setTranscriptFollowing`).
- **Eight function pairs are near-verbatim duplicates**, including
  `solveSessionActive` (`:3294`) and `pullRequestReviewActive` (`:4230`), whose
  bodies are byte-identical, and `pullRequestSessionAlreadyResolved` (`:3695`),
  whose doc comment reads "The pull-request analogue of
  `solveSessionAlreadyResolved`; see its documentation."
- The clincher for the fix shape: `applyUsageRefresh` (`:5276`) is *already* the
  unified, provider-parameterized version, and `appUsageFreshness` is already a
  `Map UsageProvider Freshness` — yet `startCodexRefresh` (`:4921`) and
  `startClaudeRefresh` (`:4942`) were left as two hand-written copies. The lesson
  was applied to one half of a pair and not swept, which is the same pattern
  findings 10 and 12 record elsewhere.

`agentSessionEntries` (`:1524`) is the one place that already treats all four
session kinds uniformly — and it does so by joining six maps by hand, then
applying a *different* liveness rule to each. That is the unified view existing as
a computation instead of as the storage model.

**Fix shape:** one `Map Int AgentSlot`, where `AgentSlot` carries the session
variant and its optional `ManagedProcess` together. Insertion and cleanup then
become single operations that cannot half-apply, and the five reusability
predicates collapse into one function over `AgentSlot`.

### [no-issue] 4. `tools/drain_prs.py` is a 3,967-line script

> **Disposition:** No issue — #159 considered this exact file and decided against
> it: "Python is out of scope entirely. Scripts are held to ~5,000 lines instead,
> and nothing currently exceeds it — `tools/drain_prs.py` is the largest at 3,170."
> It is 3,967 today, still below that bar. The re-read this deferral
> asked for supports that decision rather than overturning it: the file is
> phase-ordered, and its strongest candidate seam — the autostash and fast-forward
> cluster from `_relocate_untracked_files` through `_require_merged_index` — has
> exactly two non-private entry points, `sweep_snapshot_anchors` and
> `fast_forward_default_branch`, and its own 1,193-line
> `tools/test_fast_forward_stash.py`. That is the `Review.hs` outcome, not the
> `UI.hs` one.
> The stated fix shape is costlier than written: `tools/` uses flat sibling
> imports, so promoting it to a package would repoint `DRAINER_PATH`, the
> `SCRIPT_MODULES` vendoring fixture in `tools/test_single_pr_drain.py`, and
> multiple test modules, preventing no demonstrated defect. Revisit if the file
> crosses the ~5,000-line bar #159 set.

**Severity: High** — this is the component that merges pull requests, and it is
the least structured code in the repository.

**Original finding rationale, retained for context with current measurements:**
`tools/` is flat: `drain_prs.py` (3,967), `approve_issues.py` (2,344), and
`drain_prs_service.py` (2,049) are single-module programs sharing
`kanban_config.py` (702). The drainer owns the one irreversible action in the
whole pipeline — merging — and it has already produced at least one recorded
deadlock (it stripped the very label its own wait loop depended on, causing
spurious `reviewed:changes` and 3-of-3 failures).

A 3,967-line flat script is arguably a poor host for that logic: there is no
module boundary between "decide whether this PR is eligible", "repair a
conflicted branch", "wait for a check", and "merge", so a state-machine bug in
one shows up as a mystery in another.

**Fix shape:** promote `tools/` to a package (`tools/kanban_tools/` or similar)
and split the drainer along its actual phases — eligibility, conflict repair,
check-waiting, merge, incident reporting — with the merge step as the smallest,
most-tested module of the set. The Python suite is already large enough
(`test_integration.py` at 2,916 lines and `test_fast_forward_stash.py` at 1,193,
plus the other focused `test_*.py` modules) to support this refactor safely.

### [#153] 5. `src/Kanban/Worker.hs` threads fifteen mutable cells positionally

> **Disposition:** Filed as #153, after reading all 2,253 lines. **This finding's
> original premise was wrong** and is corrected below; the issue that came out of
> it is not the one this finding predicted.

**Severity: Medium** — a silent-miscompile hazard in the one module whose whole
job is defending an invariant.

**What this finding originally claimed, and why it was wrong.** It grouped
`Worker.hs` with `Review.hs` and asserted "same accretion pattern as `UI.hs` and
worth the same treatment." Reading `Worker.hs` disproved that. It is genuinely
single-subject — persistent worker supervision — with 87 top-level definitions and
comments that are the best in the repository: each race is documented alongside
the alternative designs that were rejected and why. Splitting it by responsibility
is *not* the right treatment, and an issue asking for that would have been actively
harmful. This is the case the `[deferred]` marker existed to prevent.

**What is actually wrong.** `runWorkerWithTask` (`:631-1034`) is one 404-line
function that creates fifteen mutable cells inline (`:644-671`) and threads them
positionally through its helpers. Five are `IORef Bool`, three are `MVar ()`, and
two are `IO Bool` closures. `watchdogLoop` (`:2117`) takes **fourteen positional
parameters**; `waitForOrphanResolution` (`:2002`) takes nine.

At the call site (`:943`), exchanging `claimCompletion` with `claimLeaseRelease`
compiles silently — as does exchanging `watchdogDoneVar` with
`watchdogAdjudicatedVar`, or substituting any of the five `IORef Bool` cells for
another. These are one-shot claims arbitrating who commits the terminal outcome
and who releases the lease; the module's own documentation (`:1944-1958`,
`:2108-2116`) explains at length that they must be raced *separately*, because
winning one says nothing about the other. Confusing them breaks the
one-live-worker invariant silently, on a path that only runs when a deadline
fires.

The module's most safety-critical arbitration is therefore carried on the one axis
the type checker cannot see — and that same positional list is what makes the
404-line function impractical to break up, since any extraction inherits it.

**Also filed with it: three stale comments.** In a module where comments are
effectively the specification, these are defects:

- `finalizeMissingState` (`:1244-1247`) claims a second entry path "lacking that,
  has outlived the elapsed-time grace window." It has one call site (`:1169`),
  reached only on `Just IdentityAbsent`. The comment eighty lines above
  (`:1160-1166`) correctly states the opposite.
- `supervisorLaunchIdentityPresenceWith` (`:1368-1372`) says `Nothing` makes the
  caller "fall back to its own existing time-based heuristic." Neither caller does
  — `leaseIsActive` (`:493`) treats it as active, `recoverIfWorkerStoppedWith`
  (`:1168`) returns `False`.
- Two `see 'runWorkerWith'` references (`:390`, `:1303`) point at a two-line alias;
  the behavior described lives in `runWorkerWithTask` (`:681`).

The first two both imply a lease with no recorded supervisor identity eventually
ages out. It never does — that case is deliberately and permanently unacquirable.
Defensible, but the opposite of what the comments promise.

### [no-issue] 5a. `src/Kanban/Review.hs` exceeds 2,000 lines

> **Disposition:** No issue — the size claim itself does not warrant one. All
> 2,015 lines were read. `Review.hs` is multi-subject, but each subject is small
> and coherent, and the one part that genuinely does not belong is already being
> extracted by #154. The two real defects the read found were filed as **#154**
> and **#155**, recorded as findings 12a and 7a. Leaving the remaining ~1,875
> lines unsplit costs nothing observable.

**Severity: Low**, once read.

The read produced a third distinct diagnosis, which is the point worth keeping.
`UI.hs` was tangled — one concept implemented several times in `where` clauses the
compiler cannot cross-check. `Worker.hs` was cohesive but hazardously
parameterized. `Review.hs` is neither: it holds roughly seven subjects (wire
protocol types and decoding, app-server client lifecycle, the tool registry, the
GitHub tool, the Claude tool, the canonical subprocess, and prompts/schemas) with
clean boundaries between them, and after #154 removes the generic
subprocess-running machinery the remainder is fairly described as one subject —
the Codex app-server review client.

**Noted, not filed.** The wire model identifiers are bare literals with no named
constant: `"gpt-5.4"` at `Review.hs:794`, `Solve.hs:387`, `Solve.hs:400`, and
`PullRequestFlow.hs:216`; `"claude-sonnet-5"` at `Review.hs:1656`, `Solve.hs:415`,
and `PullRequestFlow.hs:224`. `Solve.hs` does define named model constants, but for
*display* strings (`codexSolverModel = "gpt-5.4 high"`, `codexReviewerModel =
"GPT-5.6-Terra xhigh"`) — already diverged in form from the wire values, which is
how the duplication stays invisible. Changing a model means finding all seven
sites. Recorded in #154's Out of scope; it spans three modules and belongs to
whichever of them is touched next.

`GitHub.hs` (1,393) is the next tier down and remains unexamined. On the evidence
of three reads, its line count says only that it is worth opening.

---

## Part 2 — Portability and "install on a new machine"

### [#147] 6. The LaunchAgent label hardcodes a personal namespace

**Severity: High** for the project-agnostic goal.

`src/Kanban/Drainer.hs:69`:

```haskell
let plist = home </> "Library" </> "LaunchAgents" </> "com.coghex.drain-prs.plist"
```

The reverse-DNS label `com.coghex.drain-prs` is compiled into the binary. Every
installation of Kanban on every machine, for every target repository, therefore
competes for one launchd label and one plist path.

Concretely, for the stated goal: Kanban cannot run a drainer for `synarchy` and a
drainer for `kanban` on the same machine. The second install silently overwrites
the first one's plist, and `queryDrainerStatus` on either repository reports the
survivor's state.

`docs/agent-workflow-contract.md:473` registers this as a known `personal-path`
manifest entry marked `supported`, and §5 (line 496) calls the label "a
Kanban-owned convention" — so the divergence between "project-agnostic tool" and
"single hardcoded label" is *documented as intentional*. But the code itself shows
the cost. `statusFromRaw` in the same module has a dedicated state for the
collision:

```haskell
("foreign", _) -> DrainerStatus DrainerWarning "another repository is running"
```

That branch exists because one global label makes the drainer a **machine-wide
singleton**. Kanban cannot drain `synarchy` and `kanban` concurrently — not as an
oversight, but by construction, and the UI already has a warning string for it.
For the stated goal (install on a new machine, resume work on another project),
this is the design limit that matters, not the fact that `coghex` appears in a
string.

**Fix shape:** derive the label from the target repository — e.g.
`com.<owner>.kanban-drain-prs.<repo>` or a config-supplied
`drainer.launchagent_label` — and make `discoverDrainerController` resolve the
plist path from the same source. Keep reading the legacy path so an existing
install is not orphaned. Note this is a genuine design decision, not a bug fix:
per-repository drainers mean the `"foreign"` state becomes unreachable and
`docs/pr-drainer.md` needs rewriting. Worth deciding deliberately before anyone
implements it.

### [#146] 6a. The launchd label is defined three times, and the contract says it is defined once

**Severity: Medium** — a documentation claim that is verifiably false, which
makes finding 6 harder to fix than it looks.

`docs/agent-workflow-contract.md` §5 states the label and plist path are

> "a Kanban-owned convention **defined once in `tools/install_drainer.py`** and
> read the same way by `src/Kanban/Drainer.hs`."

The literal actually appears in three tracked non-documentation places:

| Location | Form |
| --- | --- |
| `tools/install_drainer.py:24` | `LABEL = "com.coghex.drain-prs"` |
| `tools/drain_prs_service.py:24` | `LABEL = "com.coghex.drain-prs"` |
| `src/Kanban/Drainer.hs:69` | inline `</>`-joined path literal |

`drain_prs_service.py` — which owns the service lifecycle and every `launchctl`
call — is a second independent definition the contract does not mention, and the
manifest row at line 473 lists only `src/Kanban/Drainer.hs` in its `files`
column, so the completeness check is not watching either Python copy.

Three definitions in two languages, one of them undocumented, is the reason
finding 6 cannot be done as a one-line change.

**Fix shape:** make one of them authoritative. The natural choice is a single
value in `tools/kanban_config.py` (already the shared Python config module) that
`install_drainer.py` and `drain_prs_service.py` both import, with the Haskell side
either reading it or having its literal pinned by a test that reads the Python
value. Then update the manifest row's `files` column to list all sites, so the
existing check enforces it.

### [no-issue] 7. `.drain-prs.json` is a tracked, repo-specific config at the root

> **Disposition:** No issue — **the finding was wrong on every substantive point.**
> `.drain-prs.json` is already per-target: `load_gate_config`
> (`tools/drain_prs.py:359`) reads `ctx.path / ".drain-prs.json"`, and `ctx.path`
> is the *target* repository's root, resolved by `get_repo_context` (`:318`) →
> `repo_root` (`:254`) → `git rev-parse --show-toplevel` in the `--path` directory
> (`:3058`). Draining `synarchy` reads `synarchy/.drain-prs.json`. The tracked
> copy at Kanban's root is Kanban's own drainer config, which is correct — Kanban
> is itself a repository that gets drained.
>
> **Consequence of leaving it unchanged:** none. There is nothing to change.

**Severity: none**, on inspection.

The finding made three claims. All three are false:

- *"Conflates Kanban's own drainer settings and the settings for draining some
  other repository."* It conflates nothing. The mechanism is per-target by
  construction, as the load path above shows.
- *"It is not clear from the layout where those are meant to live."*
  `docs/pr-drainer.md:203-211` lists `build-test` and `review-approved` as the
  defaults and then states that "a repository can change or disable those check
  names with `.drain-prs.json`", with a worked example
  (`"required_ci_check": "project-ci"`, `"required_review_check": null`).
- *"…or that this file is not global defaults."* The documentation distinguishes
  the two explicitly: the defaults live in code (`drain_prs.py:35-36`), the
  per-repository override is the file.

The proposed fix — renaming the tracked file to `.drain-prs.json.example` — would
have deleted Kanban's own working drainer configuration.

**The deferral's precondition, resolved.** `tools/kanban_config.py`'s repositories
table does *not* answer this: `RepositoryOverride` (`:98-101`) carries only
`workflow`, `limits`, and `timeouts`, and nothing in that module mentions
`required_ci_check` or `required_review_check`. But it does not need to, because
`.drain-prs.json` already covers it. The deferral asked the right question and got
an answer that closed the finding rather than shrinking it.

**One residual, deliberately not filed.** `DEFAULT_REQUIRED_CI_CHECK = "build-test"`
and `DEFAULT_REQUIRED_REVIEW_CHECK = "review-approved"` (`tools/drain_prs.py:35-36`)
are this repository's check names serving as the fallback for a target repository
with no `.drain-prs.json`, which would then wait on checks that do not exist there.
Some default is necessary, it is documented as a default, and it is overridable per
repository. Treating it as a portability bug would repeat the mistake finding 8
made with the `coghex/kanban` test vector — reading a fixed sample value as
configuration.

### [#155] 7a. The canonical issue reviewer's install path is spelled twice, in two languages

> **Disposition:** Filed as #155. Found by reading `src/Kanban/Review.hs` in full.

**Severity: Medium** — it breaks a supported install option silently, on exactly
the path this audit exists to check.

The install location is written independently in two tracked places:

- `src/Kanban/Review.hs:546` —
  `home <> "/Library/Application Support/kanban/issue-review/approve_issues.py"`
- `tools/install_issue_review.py:26-27` —
  `Path.home() / "Library" / "Application Support" / "kanban" / "issue-review"`

They agree only because both files spell the same path. The sole coupling is that
each independently honours `KANBAN_ISSUE_REVIEW_INSTALL_DIR`. No discovery record
exists: `write_config_reference` writes `install_dir/config.json`, inside the
directory a reader would need to have found already, and `install()` returns
`install_dir` only in stdout JSON that nothing retains.

`install_issue_review.py` accepts `--install-dir`. Using it produces a Kanban that
cannot find the reviewer and reports:

> Canonical issue reviewer was not found at
> `…/Library/Application Support/kanban/issue-review/approve_issues.py`.
> Run `python3 tools/install_issue_review.py` from the Kanban checkout to install
> it.

The remediation offered is the command that just succeeded. Recovery requires
knowing to export `KANBAN_ISSUE_REVIEW_INSTALL_DIR` into the dashboard's own
environment — which the installer never says, and which a desktop-launched TUI may
not inherit.

**This corrects finding 6a's own issue.** #146's Background cites
`src/Kanban/Review.hs:541` as the good example and calls `Drainer.hs` "the
outlier." Half true — it is a well-known path rather than a composed launchd label
— but the conclusion does not hold: this site duplicates its default across the
language boundary exactly as the drainer's label does. A solver following #146
today would copy it and inherit the defect. #146 needs a correcting comment.

Two smaller inconsistencies in the same function: `Kanban.Review` imports neither
`System.FilePath` nor `Kanban.Paths`, so the path is built with `<>` and literal
separators; and `:541` is the only hardcoded `Application Support` path in `src/`
or `app/`, where `Kanban.Worker` uses `getXdgDirectory XdgCache` and
`Kanban.Paths`. `Drainer.hs`'s `~/Library/LaunchAgents` is not comparable —
launchd requires a user agent plist to live there.

---

## Part 3 — Duplicated logic across the two plugin bundles

### [no-issue] 8. `review_pr.py` is duplicated, has diverged, and no test holds the shared part together

> **Disposition:** No issue — maintainer decision, 2026-07-26. The premise was
> verified and holds: no test compares the two copies. But the proposed
> enforcement (a drift test plus a planted-violation meta-test) was judged
> disproportionate to the risk. Cross-brand mirroring is instead handled by
> instructing agents to mirror an implementation across both bundles and trusting
> that. Recorded as accepted risk, not as a refuted finding.
>
> **Consequence of leaving it unchanged:** a fix applied to one copy of the ~1,200
> shared lines and not the other diverges with no signal. The blast radius is
> bounded by what is already guarded — see the two corrections below — so the
> realistic failure is an ordinary correctness bug that reproduces under one brand
> and not the other, which is confusing to debug but not silent state corruption.

**Severity: Medium**, revised down from High during verification.

**Two of this finding's original claims did not survive checking, and both are
corrected here rather than left standing.**

- The hardcoded `coghex/kanban` was called "another project-agnostic leak (see
  finding 6)." It is not. Both occurrences are a sample argument to `gate_key`
  inside the self-test — a hash test vector, where any fixed string would serve.
  It has no effect on behavior against another repository.
- The finding claimed the two brands "silently disagree about review state, and
  the only signal is a hash mismatch discovered at runtime." Not so. `gate_key` —
  the one function whose cross-copy agreement decides whether cross-brand review
  works at all — is pinned in *both* copies by the same vector
  (`assert gate_key("coghex/kanban", [], []) == "acc8ca6f35ab53bb"`), and both
  self-tests run in CI via `test_review_pr_self_test_passes_standalone`. Changing
  that algorithm in one copy fails that copy's own test, at CI time. That is what
  moved the severity from High to Medium.

The deliberate divergence is also better protected than the finding assumed, from
both directions: `tools/test_codex_plugin.py:240` forbids nested-reviewer model
flags (with a planted-violation meta-test at `:256`), and
`tools/test_claude_plugin.py:664` and `:651` assert the pinned flags and check them
against the Haskell constants.

What was genuinely unguarded, and remains so by choice, is the surrounding
coordinator logic.

Two copies of the same ~1,350-line review coordinator:

- `claude-plugin/plugins/kanban/scripts/review_pr.py` — 1,369 lines
- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py` — 1,331 lines

They differ by ~120 diff lines. The divergence is *deliberate and carefully
documented* — the Claude copy pins the nested reviewer's model and effort
(`gpt-5.6-terra` / `claude-opus-5` at `xhigh`) and can therefore report a
verified model, while the Codex copy pins nothing and publishes
`UNVERIFIED_MODEL_TOKEN`. A 19-line comment in the Claude copy explains why, and
names the other copy explicitly.

The problem is not the divergence. It is that **~1,200 lines are supposed to be
identical and nothing enforces it.**

Verified: no test opens both files. The two plugin suites total 1,833 lines and
every test in them is scoped to a single bundle.
`tools/test_agent_workflow_contract.py` comes closest and still misses it — `:333`
and `:358` are two *parallel* tests, each reading its own copy and checking it
against the contract document, never against each other.
`tools/test_repair_workflow_contract.py:442-447` asserts only that the paths exist.
`tools/test_claude_plugin.py:647` mentions `codex-plugin` in a prose comment. That
the 14 diff hunks are scattered through the file rather than confined to one config
block indicates the two copies are already edited independently in practice.

Still worth knowing, though not acted on: pinned model IDs inside a plugin bundle
are a maintenance clock. `gpt-5.6-terra` and `claude-opus-5` will age out, and when
they do the failure is a spawn error inside a nested reviewer — one of the hardest
places in this system to debug.

**Fix shape, for the record — considered and declined.** Either extract the shared
lines into one module vendored into both bundles, or add a test diffing the two
files against a declared allowlist, plus a planted-violation meta-test so the check
cannot pass by being too coarse. Drafted in full and rejected as disproportionate:
the enforcement machinery would be comparable in size to the risk it removes, in a
repository with one maintainer where agents perform the edits. The chosen mitigation
is procedural instead — agents are instructed to mirror an implementation across
both bundles.

If that mitigation is to carry the weight, it belongs somewhere agents actually
read: `CLAUDE.md`'s pipeline conventions or `docs/agent-workflow-contract.md`,
alongside the existing origin-marker and never-merge rules. Not filed; noted so the
decision is not lost.

---

## Part 4 — Gaps in the contract's own enforcement

`docs/agent-workflow-contract.md` carries a machine-checked dependency manifest,
reconciled by `tools/test_agent_workflow_contract.py` against the Haskell source
and both plugin bundles. This is genuinely good engineering and the best-designed
mechanism in the repository — it is the reason "a new external command cannot land
undocumented" is close to true. The findings below are about where its coverage
stops, which matters *because* the check is trusted.

Checked and found sound: the `SURFACE_FILES` comment claims the list is
exhaustive for `src/` with respect to
`findExecutable`/`proc`/`readProcessWithExitCode`/`readCreateProcessWithExitCode`/`getHomeDirectory`.
That claim currently holds — no unlisted module under `src/` matches those
patterns. (`Worker.hs` is not listed and does spawn processes, but only via
`createProcess`, which is not one of the scanned idioms, and its only
home-relative path is `getXdgDirectory`. It is out of scope rather than missed.)

### [#149] 9. `launchctl` is an undeclared dependency of the drainer

**Severity: Medium.**

The three scanned surfaces are `src/`, `codex-plugin/`, and `claude-plugin/`.
**`tools/` is not scanned at all** — yet it holds the drainer, the component with
the only irreversible action in the pipeline.

The concrete omission: `launchctl` is spawned from six sites across
`tools/drain_prs_service.py` (`print`, `bootout`, `bootstrap`, `kickstart`,
`kill`) and `tools/install_drainer.py:72`, and it is:

- **not** a row in the machine-checked manifest, and
- **not** in the §2.6 host-prerequisites table.

It appears only in prose at line 175. This is internally inconsistent with the
doc's own standard: `/usr/bin/plutil`, which merely *reads* the drainer's status,
gets both a manifest row (`plutil-cli`) and a §2.6 table entry, while `launchctl`
— which installs, starts, stops, and kills the service — gets neither. A reader
following §2.6 to provision a new machine would not learn that the drainer needs
`launchctl`.

**Fix shape:** add `launchctl-cli` to the manifest and a `launchctl` row to §2.6,
then add `tools/` (or at minimum `drain_prs_service.py` and `install_drainer.py`)
as a fourth scanned surface in `tools/test_agent_workflow_contract.py`. The
Python extractor already needed for `review_pr.py`'s list-literal invocations can
be reused, since these call sites have the same `run(["launchctl", …])` shape.

---

## Part 5 — Lessons learned in one place and not swept across the others

A recognizable signature of issue-at-a-time automated development: a hazard gets
diagnosed properly, fixed thoroughly at the one call site the issue named, and
the identical hazard is left standing everywhere else.

### [no-issue] 10. Process-group hardening was applied to `GitHub.hs` only

> **Disposition:** No issue — the `Drainer.hs:122` half is rewritten by #146,
> which replaces `discoverDrainerController` and its `runProcess` helper outright.
> The residual is `Repository.hs:45`'s missing timeout alone, whose realistic
> trigger is a stalled network mount and whose fix converts "hang forever" into
> "error after N seconds" — too thin to justify tracker and PR overhead. Left
> unfixed, `kanban` can hang at startup with no output on a stalled filesystem;
> that is the accepted consequence. Reasonable to revisit as a `good first issue`.

**Severity: Medium.**

`src/Kanban/GitHub.hs:257` documents the reasoning in full:

> Runs one page's `gh` as the leader of its own process group, so a fetch that
> gets abandoned can be cleaned up as a group rather than as a lone child.
> **`readProcessWithExitCode`, which this replaces, terminates only the direct
> child and never confirms it exited**: a `gh` wedged on network I/O and ignoring
> TERM, or one that has spawned a credential helper, could outlive the timeout
> that reported it dead and still be running when the next refresh starts another
> one.

That analysis is correct and general. The repository then built a whole hardened
layer around it — `Kanban.Process`, with `OwnedProcessGroup`,
`killVerifiedGroup`, `checkGroupMembership`, `membersStillInGroup` — and
`GitHub.hs`, `Review.hs`, `Solve.hs`, `PullRequestFlow.hs`, and `Worker.hs` all
spawn through the careful `createProcess` + ownership path.

Two call sites still use the idiom the comment describes as unsafe:

| Site | Issue |
| --- | --- |
| `src/Kanban/Drainer.hs:122` | `timeout` wrapped around `readProcessWithExitCode` — the exact "terminates only the direct child and never confirms it exited" shape, for a 30-second `setDrainerRunning` call that shells out to `launchctl`. |
| `src/Kanban/Repository.hs:45` | `readProcessWithExitCode "git" …` with **no timeout at all**. |

Severity is genuinely lower than for `gh`: these are short local commands, not
network fetches. But `Repository.hs`'s missing timeout has a user-visible
consequence worth naming — `resolveRepository` runs during startup, before the
TUI exists, so if `git rev-parse` or `git remote get-url` stalls (a network mount,
a credential helper on the remote URL path), `kanban` hangs at launch with no
output and no way to interrupt it cleanly.

**Fix shape:** at minimum, give `Repository.hs`'s `runGit` the same `timeout`
wrapper `Drainer.hs` already has — that is a small, self-contained change closing
the startup-hang path. Routing both through `Kanban.Process` is the more complete
fix and worth doing, but it is a larger change and should be judged against the
fact that neither command touches the network.

### [#146] 11. `Drainer.hs` has no platform guard, so a non-macOS host gets a raw exception

**Severity: Low.**

To be clear about scope first: macOS-only is a **deliberate, documented decision**,
not an oversight. `docs/workflow-setup.md:15` states "macOS is Kanban's supported
platform, and remains so here: this document describes a macOS setup path, not a
cross-platform port." So this is not a portability finding — it is an error-message
finding.

`tools/install_drainer.py:199` does it right:

```python
if sys.platform != "darwin":
    raise InstallError("The PR drainer LaunchAgent installer requires macOS.")
```

`src/Kanban/Drainer.hs:66` has no equivalent. `discoverDrainerController` calls
`/usr/bin/plutil` unconditionally, and on failure `runProcess` returns
`Left (Text.pack (show exception))` — a raw `IOException` rendering. On a Linux
host, `appDrainerController` therefore holds something like
`"/usr/bin/plutil: does not exist"`, which surfaces in the dashboard as the
drainer's status.

The same rough edge applies on macOS whenever the drainer simply is not installed
— the common case for a fresh clone. A user who has never run
`tools/install_drainer.py` sees a raw missing-file exception rather than "PR
drainer not installed; run `tools/install_drainer.py`."

**Fix shape:** in `discoverDrainerController`, distinguish three outcomes before
shelling out — not macOS, plist absent, and plist present but unreadable — and
return a purpose-written `Text` for each. This is a small change with a
disproportionate effect on how a fresh install feels, which makes it a good
candidate to do early despite the Low severity.

### [#145] 12. The drainer refuses to start on a dirty tree, using a rationale its own autostash had already made obsolete

**Severity: High** — this one blocks the maintainer's actual daily workflow, and
the fix is mostly deletion.

`tools/drain_prs.py:258`'s `require_clean_worktree` — called unconditionally from
`get_repo_context` — refuses to start if `git status --porcelain=v1
--untracked-files=all` reports anything at all. `drain_prs_service.py:405` repeats
the same check independently in `start_service`, and
`Kanban.Drainer.statusFromRaw` renders the result as
`"uncommitted changes; drainer will not start"`.

The documented rationale, from `docs/pr-drainer.md` and commit `70beb76`:

> "This keeps the drainer's post-merge fast-forward from interfering with an
> in-progress hotfix."

**That rationale was already obsolete on the day it was written.** The dates:

| Date | Commit | What landed |
| --- | --- | --- |
| 2026-07-19 | `7fb2c25`, `377cfac`, `bc27742` | The full autostash in `fast_forward_default_branch`, hardened over three review rounds |
| 2026-07-20 | `70beb76` | "Refuse drainer start from dirty checkouts" |

The autostash already handles precisely the interference the gate was added to
prevent, and handles it *carefully*: it relocates untracked files physically
rather than through git (so a concurrent `git stash` in another terminal cannot
collide), snapshots tracked changes with `git stash create` (a floating commit
that never touches the shared `refs/stash` reflog), anchors that commit at
`refs/drain-prs/autostash/<sha>` **before** the destructive `reset --hard` so it
cannot be garbage-collected, restores in a `finally`, and on failure surfaces the
snapshot into `git stash list` with copy-pasteable recovery instructions. It is
the best-engineered code in the drainer.

Three facts establish that relaxing the gate is safe rather than bold:

1. **The main checkout is never checked out.** Enumerating every `run([...],
   cwd=ctx.path)` call site shows the drainer runs no `git checkout` or `git
   switch` there at all. All per-PR work happens in separate worktrees. `git
   branch -D` deletes a merged feature branch's ref, not working-tree files.
2. **Exactly one command touches main-checkout files:** `git merge --ff-only`.
   That is the precise call the autostash wraps.
3. **Dirty-tree tolerance is already production-exercised.**
   `drain_prs_service.py` spawns `drain_prs.py` **once** as a long-lived child
   (`child.wait()`), so `require_clean_worktree` guards only the single instant of
   startup, while the autostash carries the entire multi-hour run. The drainer
   already tolerates a dirty tree for its whole operational life — it just refuses
   to *begin* in one.

The user-visible consequence is exactly backwards from what the project wants.
Kanban's one production consumer uses the drainer alongside hand-driven work on
`master`, so the common case — a couple of uncommitted doc edits — forces an
unrelated push before the drainer can start. The gate converts a handled
condition into a hard stop.

**Fix shape:** delete both dirty checks and let the existing autostash do its job.
Blast radius is well bounded — `tools/drain_prs.py`,
`tools/drain_prs_service.py`, `src/Kanban/Drainer.hs` (drop the `"dirty"` case),
`docs/pr-drainer.md` (the paragraph the gate commit added), and four tests that
currently assert the refusal:
`tools/test_drain_prs_service.py:283`, `:299`,
`tools/test_single_pr_drain.py:675`, and `test/Spec.hs:6518`. Those four should be
*inverted* rather than deleted: they become the regression tests proving the
drainer starts and merges cleanly from a dirty checkout, and that the user's
changes are still present afterward. `tools/test_fast_forward_stash.py` already
provides the fixtures for that.

One genuine caveat worth stating rather than glossing: `git merge --ff-only`
refuses if the incoming commits would overwrite a locally-modified *or* untracked
file, which is why the autostash exists. After this change a fast-forward that
collides with local edits will stash, ff, and restore — and if the restore hits a
conflict, the user's work is preserved in `git stash list` but the tree is left
mid-conflict. That is strictly better than today's behavior (refuse to run), but
it should be called out in `docs/pr-drainer.md` so the recovery path is
documented rather than discovered.

### [#154] 12a. The #15 capture fix reached two of three review subprocess runners

> **Disposition:** Filed as #154 and **merged** in 289de6d (PR #157), same day.
> Found by reading `src/Kanban/Review.hs` in full. This is the clearest instance of
> this Part's pattern in the report, because the unswept site was a live defect
> rather than latent risk — and it is now fixed: the bounded command capture was
> extracted into its own module and all three runners share it.
>
> Line references in the body below were correct for `Review.hs` as read (2,015
> lines, at 6068cc1) and no longer resolve against the current 1,953-line file.
> They are left as filed, since the issue they document is closed.

**Severity: Medium** — a false diagnostic and a discarded answer, bounded by the
affected tool being read-only.

`Kanban.Review` spawns three subprocesses. #15 replaced the
single-`timeout`-around-exit-and-capture pattern with separately bounded
`startCapture`/`awaitCommandOutcome` in two of them:

| Runner | Capture strategy |
| --- | --- |
| `runGitHubCommand` (`:1356`) | `startCapture` → `awaitCommandOutcome` → `releaseCapture` |
| `runCanonicalCommand` (`:1390`) | `startCapture` → `awaitCommandOutcome` → `releaseCapture` |
| `runAuthenticatedClaude` (`:1614`) | `captureHandle` + `takeMVar`, both inside one `timeout` |

`captureHandle` (`:1672`) is `ByteString.hGetContents`, publishing only at EOF.
The `StreamCapture` documentation the fix itself added (`:1541-1547`) describes
the hazard in fully general terms — nothing about it is GitHub-specific — and the
Claude spawn sets `create_group = True`, so descendants are expected there too.

When Claude exits but a descendant holds the stdout pipe: `waitForProcess`
returns, `takeMVar` blocks, the ten-minute timeout expires, and the result is
`Left "Claude Sonnet 5 revision agent timed out after ten minutes"` — false, since
the process exited, and lossy, since `captureHandle` publishes atomically at EOF
so every byte already read is discarded. The fixed path would have returned
`StreamTruncated` with whatever arrived.

`CommandBounds`'s own documentation (`:240-247`) calls itself "the two independent
bounds **every review subprocess** runs under." This one uses neither.

**Why it was missed, which is the reusable lesson.** #15's Background enumerated
its two runners by name and fixed exactly those. Its Out of scope excludes
worker-side handling but never mentions `runAuthenticatedClaude` — so this was an
omission, not a decision. A fix specified by naming call sites fixes those call
sites; one specified by removing the alternative fixes the class. #154 therefore
extracts the generic machinery so the shared path becomes the only path.

**Mitigating, and worth stating rather than glossing:** `kanban_run_claude` runs
`--permission-mode plan --safe-mode`, so it is read-only. No completed mutation is
misreported, and none of #15's duplicate-side-effect risk applies. The cost is a
wrong message, a lost answer, and up to ten wasted minutes.

---

## Part 6 — Configuration and per-repository setup

`Kanban.Config` is the mechanism the whole portability goal rests on: it is where
"point this at a different repository" is actually decided. The layer is good —
see the clean list below — and has exactly one hole, but it is in the worst
possible place for a tool meant to be set up on a new machine.

### [#150] 13. A `[repositories."owner/name"]` key that does not match exactly is silently ignored

**Severity: High** for the new-machine goal. Nothing is wrong with the code's
logic; the problem is that the most likely setup mistake produces no signal at
all.

Repository overrides are selected by exact string equality:

```haskell
repositoryIdentity owner name = owner <> "/" <> name

resolveConfig ownerName raw = ... where
  override = Map.findWithDefault emptyRepositoryOverride ownerName raw.rawRepositories
```

`Map Text` compares by `Ord Text` — byte equality, no case folding. Three
consequences compound:

- **No structural validation of the key.** `parseRepositories` is
  `mapOf (\_ key -> pure key) …`, which accepts *any* string as a repository
  identity. `[repositories."kanban"]` with no owner, or
  `[repositories."https://github.com/coghex/kanban"]`, parse successfully and are
  simply never selected. Compare `Kanban.Repository.parseRepositoryName`, which
  validates identities rigorously and fails closed — that validation is not
  applied to config keys.
- **No warning when a key matches nothing.** `decodeConfigText` does surface
  warnings, and a typo'd *scalar* key produces one — the test fixture's
  `unknown_top_level_key = 1` is warned about. But `mapOf` consumes every
  repository key, so a typo'd *repository identity* never becomes an unknown key.
  Kanban therefore warns about the harmless mistake and stays silent about the
  consequential one.
- **The required case comes from your git remote, not from GitHub.** Owner and
  name flow from `parseRemoteRepository`, which preserves the case in the remote
  URL and never folds the path. A checkout cloned from
  `git@github.com:Coghex/Kanban.git` needs `[repositories."Coghex/Kanban"]`; the
  same repository cloned as `coghex/kanban` needs the lowercase key. **The same
  `config.toml` can therefore work on one machine and silently do nothing on
  another** — precisely the failure the portability goal cannot tolerate.

The blast radius is the whole workflow contract. A repository override carries
`approval_label`, `changes_requested_label`, `blocked_labels`, and
`tracker_labels` — the labels the board reads state off. Silently falling back to
global defaults means the board renders confidently and wrongly, with no
indication that an entire configuration block was discarded.

This is also internally inconsistent. The same codebase deliberately case-folds
user input in two other places — `validateWorkflowLabelDistinctness` folds labels
before comparing, and `Settings.hs`'s `ChatVerbosity` parser folds the verbosity
name — so the one place that does not fold is the one that fails silently.

**Fix shape:** validate and report, in that order.

1. Validate every `[repositories.*]` key at decode time against the same identity
   rules `Kanban.Repository.parseRepositoryName` enforces. A key that cannot be an
   `owner/name` is a config error, not a table to ignore.
2. Warn — through the existing warning channel `loadRawConfig` already threads to
   `Main.hs` — when a well-formed repository key matches no selectable repository
   for this run. Word it so the near-miss is obvious, e.g. naming the resolved
   identity alongside the unmatched key.
3. Decide case explicitly. Either match case-insensitively (consistent with how
   this codebase treats every other user-supplied string), or keep exact matching
   and make the near-miss warning specifically call out a case-only difference.
   The second is safer, since GitHub identities are case-preserving.

Note what the fix cannot be: `--doctor` is not the place. `app/Main.hs` runs it
*before* configuration and repository resolution on purpose — "a fresh clone with
no configured remote still needs to be able to ask why an AI action would not
start" — and `doctorLines` reports only dependencies and action readiness. Moving
config reporting into doctor would mean giving up that property.

### [#152] 14. Three of this repository's own label names are compiled into the theme

> **Disposition:** Filed as #152. Found during the full line-by-line read of
> `UI.hs`, in its last seventy lines.

**Severity: Low** — cosmetic, with no functional consequence. It earns an issue
only because project-agnosticism is a stated requirement of this project.

`labelAttribute` (`src/Kanban/UI.hs:5631-5641`) picks a label chip's color from a
guard chain that mixes configured labels with three literal names:

```haskell
| folded == Text.toCaseFold config.approvalLabel = labelApprovalAttr
| folded == "reviewed:revised" = pendingAttr
| folded == Text.toCaseFold config.changesRequestedLabel
    || folded `Set.member` foldedBlockedLabels = labelProblemAttr
| folded == "bug" = labelProblemAttr
| folded `elem` ["ui", "input"] = labelUiAttr
| otherwise = labelDefaultAttr
```

`reviewed:revised` belongs there — it is a reserved protocol label, named by
`Kanban.Workflow.rereviewLabel` (`Workflow.hs:256`) and defended by
`Kanban.Config` (`:357-360`), which rejects any config that resolves
`approval_label` or `changes_requested_label` to it. This was checked before
filing, precisely because it looks like the same mistake and is not.

`bug`, `ui`, and `input` have no such standing. They appear nowhere in
`Kanban.Config` or `Kanban.Workflow` and have no configuration path — they are
simply this repository's own label names in the theme. On a repository that labels
defects `defect`, nothing tints; on one where `ui` means something unrelated, it
tints for a reason the user can neither discover nor change.

The boundary here was checked too: #48 deliberately left chip rendering alone when
it made blocking-label *severity* configurable, and the comment at `:5627-5630`
records that decision. #152 respects it and touches only the three unconfigurable
names.

**Related, not filed:** `Kanban.Workflow.rereviewLabel` exists as a named
constant, and at least seven sites use the bare literal `"reviewed:revised"`
instead (`UI.hs:5259`, `:5634`; `PullRequestFlow.hs:78`; `Review.hs:521`, `:1218`,
`:1271`, `:1751`). Harmless today, and the same extract-once-don't-sweep shape as
findings 10 and 12. Noted in #152's Out of scope as a separate sweep.

---

## Coverage log

What has actually been read, so the audit can resume without repeating work.

| Area | State |
| --- | --- |
| Repository inventory (file sizes, tracked-file layout, `.gitignore`) | Read fully |
| `kanban.cabal`, `cabal.project`, `.drain-prs.json` | Read fully |
| `src/Kanban/Drainer.hs` (155 lines) | **Read fully** |
| `src/Kanban/Repository.hs` (158 lines) | **Read fully** |
| `tools/test_agent_workflow_contract.py` | Read lines 1–160 (surface lists, manifest parser, regexes). Assertion bodies not read. |
| `docs/agent-workflow-contract.md` | Read §2.6, §4 manifest, §5 portable-install policy. §1–§2.5 and §3 not read. |
| `src/Kanban/UI.hs` (5,706 lines) | **Read fully, line by line** — all 380 top-level definitions. Cleared findings 2 and 3; produced #151 and #152. |
| `src/Kanban/Worker.hs` (2,253 lines) | **Read fully, line by line** — all 87 top-level definitions. Cleared finding 5, disproved its premise, produced #153, and split off 5a. |
| `src/Kanban/Review.hs` (2,015 lines at read time; **1,953 now**) | **Read fully, line by line** — all 122 top-level definitions. Closed 5a as no-issue; produced #154 and #155, recorded as findings 12a and 7a. #154 merged the same day (289de6d), extracting `Kanban.CommandCapture` and shifting every line reference in this report's Review findings. |
| `src/Kanban/Process.hs` | Export list only. |
| `tools/drain_prs.py` | Read the clean-tree gate, the autostash, `fast_forward_default_branch`, and every main-checkout command site. The other ~2,900 lines not read. |
| `tools/drain_prs_service.py` | Read the module constants, `launch_target`, `status_snapshot`, `incident_files`, `install_job`, `start_service`, and the child-spawn loop. Remainder not read. |
| `tools/install_drainer.py` | Read the header, constants, and install/config-merge surface. Remainder not read. |
| `test/Spec.hs` | Structure mapped — 330 lines of imports, 48 `describe` blocks in one `main`, 149 trailing helpers. Test bodies not read. |
| `src/Kanban/Paths.hs` | **Read fully** — landed 2026-07-26, mid-audit. |
| `src/Kanban/Config.hs` (523 lines) | **Read fully** |
| `src/Kanban/Settings.hs` (111 lines) | **Read fully** |
| `app/Main.hs` (58 lines) | **Read fully** |
| `src/Kanban/Preflight.hs` | `doctorLines` and its config-blindness only. The other ~850 lines not read. |
| `config.toml.example`, config tests in `test/Spec.hs` | Read the `[repositories.*]` surface and its override tests. |
| Plugin bundles | `review_pr.py` divergence diffed. Command/skill Markdown not read. |
| `test/Spec.hs` | Size and cabal wiring only. Contents not read. |
| Everything else in `src/`, `tools/`, `app/`, `docs/` | Not yet read |

### Verified clean, or better than expected

Worth recording so the audit does not re-suspect these, and so the report is not
read as uniformly negative:

- **Hygiene rules are holding.** `dist-newstyle/`, `__pycache__/`, profiling and
  eventlog output are all correctly ignored and untracked.
- **No absolute-path leaks.** No hardcoded `/Users/...` and no reference to
  `synarchy` anywhere in tracked files. Every portability leak found so far is a
  `coghex`-namespace *identifier*, not a machine-specific path.
- **`src/Kanban/Repository.hs` is exemplary.** Remote-URL parsing fails closed by
  design: `parseRemoteRepository` accepts only unambiguous github.com remotes,
  rejects SSH host aliases and other forges, validates both path segments as
  GitHub identifiers so punctuation cannot reach the GraphQL query built from
  them, and directs everything else to the documented `--repo OWNER/NAME` escape
  hatch. The comments explain *why* at each decision, including the subtle
  SCP-vs-port case. Nothing to fix here beyond the missing timeout in finding 10.
- **The XDG paths are right.** `Cache`, `Config`, `Settings`, `Transcript`,
  `Claude`, and `Worker` all use `getXdgDirectory Xdg{Cache,Config} "kanban"`
  rather than hand-built home paths. Only `Drainer.hs` and `Review.hs` use
  `getHomeDirectory`, and both are the deliberate macOS
  `~/Library/...` integration points.
- **The dependency manifest is real enforcement, not documentation theater.** Its
  coverage gaps are findings 6a and 9, but the mechanism itself — regex extractors
  per surface language, reconciled against a parsed table, with `mandatory` and
  `owner` columns — is better than most hand-maintained projects manage.
- **`tools/drain_prs.py`'s autostash is the best code in the repository.** See
  finding 12 for the detail. It is careful in ways that only come from having
  thought about concurrent use: it avoids `git stash` proper so it cannot collide
  with a stash the user runs in another terminal, anchors its snapshot to a ref
  before anything destructive, and fails closed — `git stash create` exits
  non-zero on an unmerged index, so `reset --hard` is unreachable during a
  conflicted merge and a user's unresolved work cannot be destroyed. Verified
  empirically, not just read.
- **Per-repository plumbing is further along than the singleton language implies.**
  The drainer's run lock is already per-checkout, and incidents already carry a
  `repo` field and filter on it. That is why #147 is a contained change rather
  than a rewrite.
- **The configuration layer is strong apart from finding 13.** Every scalar is
  validated rather than merely decoded: non-empty strings, positive integers, a
  timeout bound that specifically prevents overflow when converted to
  microseconds, and enum values that name the accepted alternatives on failure.
  `forbidRepositoryKey` actively rejects `cache`, `remote_name`, and `usage` inside
  a repository table rather than silently ignoring them. Best of all,
  `validateRawConfig` checks approval/changes-requested label distinctness for
  *every* repository override after merging, not just the global table — catching
  the case where an override sets only one of the pair and collides with the
  inherited other. That is a genuinely subtle bug class, closed deliberately.
- **`remote_name` being global-only is correct by necessity, not an oversight.**
  `app/Main.hs` must call `resolveRepository rawConfig.rawRemoteName` to *discover*
  the repository identity before `resolveConfig` can select that repository's
  override table. A per-repository `remote_name` would be needed to find the
  identity that selects it. The `--repo OWNER/NAME` flag is the escape hatch.
- **`Settings.hs` is a small, correct file.** Atomic write through
  `openBinaryTempFile` + `renameFile` under `bracketOnError`, `0600` on both the
  temporary and final path, and a schema version that is actually *checked* on
  read — with a documented policy distinguishing "written by another version"
  (silent defaults) from "claims this version and will not decode" (warn). The
  comment notes the previous version stamped a version it never read.
- **The module-splitting instinct is already present.** `src/Kanban/Paths.hs`
  landed during this audit: a small, focused module extracted to own `0700`
  enforcement across the XDG directory chain, with a comment explaining the bug
  that motivated it (`createDirectoryIfMissing` creating parents at the process
  umask). This is exactly the direction findings 1–5 argue for, applied
  unprompted.
