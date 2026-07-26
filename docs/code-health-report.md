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
This is the pattern `Review.hs:541` already uses for the issue-review backend;
`Drainer.hs` was the outlier. Finding 11 folded in because it rewrites the same
function.

Notes on the order:

- **A first** because it is the one blocking the maintainer's daily routine, and
  because it is subtractive — it shrinks the surface B and C then modify.
- **B before C.** C looks like a one-line change and is not: the label literal
  lives in three places, and the contract doc wrongly claims it lives in one.
  Consolidating first turns C into an actual one-place change.
- **C is a design issue, not a bug fix.** Per-repository drainers make
  `statusFromRaw`'s `"foreign"` state unreachable and require rewriting
  `docs/pr-drainer.md`'s single-drainer model. It should be filed for discussion,
  not handed straight to a solve agent.
- **D is independent** and can run in parallel with A–C — it touches no drainer
  file. It should be filed early regardless of when it is worked, because every
  later refactor in Part 1 lands against it.
- **E last** of the drainer group, since it edits the same `Drainer.hs` function
  region A touches.

**Resolved along the way — what identifies a drainer.** #147 keys a drainer by its
GitHub `owner/name` slug rather than its checkout path. Two clones of the same
repository then resolve to the same label, which makes it structurally impossible
to run two drainers merging the same pull requests — a failure the existing
per-path run lock cannot catch, because the two checkouts really are different
paths. The lock is kept as a second guard. The accepted cost: two checkouts of one
repository cannot be drained independently. The sharp edge for implementation is
case — `Coghex/Kanban` and `coghex/kanban` are distinct to GitHub, so a
lowercasing derivation would collapse them.

### Wave 2 — hold until the audit is further along

Findings 2, 3, 4, 5, 7, 8, 9, and 10. Each is real and each has its fix shape
written down above, but none blocks daily work, and several will read differently
once `Worker.hs`, `Review.hs`, `Config.hs`, and the plugin Markdown have been
gone through. Finding 8 (the duplicated `review_pr.py`) is the strongest Wave 2
candidate to promote early if the divergence starts causing trouble.

---

## Part 1 — Oversized files

The single most visible artifact of an automated build process: every file grew
by accretion, and nothing was ever split, because no agent's task was ever "make
this smaller."

### 1. `test/Spec.hs` is a 9,200-line single-file test suite

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

### 2. `src/Kanban/UI.hs` is a 5,705-line god-module

**Severity: High** — it is the widest blast radius in the codebase.

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

### 3. `AppState` tracks seven parallel `Map Int` session tables

**Severity: Medium** — a live correctness hazard rather than a style complaint.

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

**Fix shape:** one `Map Int AgentSlot`, where `AgentSlot` carries the session
variant and its optional `ManagedProcess` together. Insertion and cleanup then
become single operations that cannot half-apply, and the five reusability
predicates collapse into one function over `AgentSlot`.

### 4. `tools/drain_prs.py` is a 3,152-line script

**Severity: High** — this is the component that merges pull requests, and it is
the least structured code in the repository.

`tools/` is flat: `drain_prs.py` (3,152), `approve_issues.py` (2,138), and
`drain_prs_service.py` (1,048) are single-module programs sharing only
`kanban_config.py` (493). The drainer owns the one irreversible action in the
whole pipeline — merging — and it has already produced at least one recorded
deadlock (it stripped the very label its own wait loop depended on, causing
spurious `reviewed:changes` and 3-of-3 failures).

A 3,000-line flat script is a poor host for that logic: there is no module
boundary between "decide whether this PR is eligible", "repair a conflicted
branch", "wait for a check", and "merge", so a state-machine bug in one shows up
as a mystery in another.

**Fix shape:** promote `tools/` to a package (`tools/kanban_tools/` or similar)
and split the drainer along its actual phases — eligibility, conflict repair,
check-waiting, merge, incident reporting — with the merge step as the smallest,
most-tested module of the set. The Python suite is already large enough
(`test_integration.py` at 2,038 lines, plus eight other `test_*.py`) to support
this refactor safely.

### 5. `src/Kanban/Worker.hs` and `src/Kanban/Review.hs` exceed 2,000 lines

**Severity: Medium.**

`Worker.hs` (2,255) and `Review.hs` (2,015) are the next tier down, followed by
`GitHub.hs` (1,393). Same accretion pattern as `UI.hs` and worth the same
treatment, but lower priority: their responsibilities are at least
single-subject, so they are large rather than tangled. Deferred pending a closer
read — see the coverage log.

---

## Part 2 — Portability and "install on a new machine"

### 6. The LaunchAgent label hardcodes a personal namespace

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

### 6a. The launchd label is defined three times, and the contract says it is defined once

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

### 7. `.drain-prs.json` is a tracked, repo-specific config at the root

**Severity: Medium.**

```json
{
  "required_ci_check": "build-test",
  "required_review_check": "review-approved"
}
```

These are the check names of *this* repository's CI. They are committed to the
root of the tool that is supposed to be repository-agnostic, which conflates two
distinct things: Kanban's own drainer settings, and the settings the drainer
should use when draining some *other* repository. A new-machine install pointed
at `synarchy` needs check names from `synarchy`, and it is not clear from the
layout where those are meant to live or that this file is not global defaults.

**Fix shape:** decide and document which of the two it is. If it is per-target
config, it belongs alongside the target repository (or in Kanban's per-repository
config directory), and the tracked copy at the root should be renamed to
`.drain-prs.json.example`. If they really are intended as defaults, say so in
`docs/pr-drainer.md` and give them non-repo-specific values.

---

## Part 3 — Duplicated logic across the two plugin bundles

### 8. `review_pr.py` is duplicated, has diverged, and no test holds the shared part together

**Severity: High.**

Two copies of the same ~1,350-line review coordinator:

- `claude-plugin/plugins/kanban/scripts/review_pr.py` — 1,369 lines
- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py` — 1,331 lines

They differ by ~120 diff lines. The divergence is *deliberate and carefully
documented* — the Claude copy pins the nested reviewer's model and effort
(`gpt-5.6-terra` / `claude-opus-5` at `xhigh`) and can therefore report a
verified model, while the Codex copy pins nothing and publishes
`UNVERIFIED_MODEL_TOKEN`. A 19-line comment in the Claude copy explains why, and
names the other copy explicitly.

The problem is not the divergence. It is that **~1,230 lines are supposed to be
identical and nothing enforces it.** Both copies contain the same inline
self-test asserting `gate_key("coghex/kanban", [], []) == "acc8ca6f35ab53bb"` —
a gate-key hash that must match across bundles for cross-brand review to work at
all. If an agent fixes a bug in one copy and not the other, the two brands
silently disagree about review state, and the only signal is a hash mismatch
discovered at runtime.

Two further notes:

- The hardcoded `coghex/kanban` in that self-test assertion is another
  project-agnostic leak (see finding 6): the test vector is keyed to this
  specific repository.
- Pinned model IDs inside a plugin bundle are a maintenance clock. `gpt-5.6-terra`
  and `claude-opus-5` will age out, and when they do the failure is a spawn error
  inside a nested reviewer — one of the hardest places in this system to debug.

**Fix shape:** extract the ~1,230 shared lines into one module vendored into both
bundles by a build/sync step, with the intended divergence reduced to a small
per-bundle config block (`PIN_NESTED_MODEL = True/False` plus the IDs). Then add
a test that fails if the shared portion drifts — the existing
`tools/test_codex_plugin.py` and `tools/test_claude_plugin.py` are the natural
homes. If vendoring is rejected, the minimum acceptable substitute is a test that
diffs the two files and asserts the diff is *exactly* the known-good divergence.

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

### 9. `launchctl` is an undeclared dependency of the drainer

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

### 10. Process-group hardening was applied to `GitHub.hs` only

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

### 11. `Drainer.hs` has no platform guard, so a non-macOS host gets a raw exception

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

### 12. The drainer refuses to start on a dirty tree, using a rationale its own autostash had already made obsolete

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
| `src/Kanban/UI.hs` | Structure only — exports, type declarations, `AppState`. Bodies not read. |
| `src/Kanban/Process.hs` | Export list only. |
| `tools/drain_prs.py` | Read the clean-tree gate, the autostash, `fast_forward_default_branch`, and every main-checkout command site. The other ~2,900 lines not read. |
| `tools/drain_prs_service.py` | Read the module constants, `launch_target`, `status_snapshot`, `incident_files`, `install_job`, `start_service`, and the child-spawn loop. Remainder not read. |
| `tools/install_drainer.py` | Read the header, constants, and install/config-merge surface. Remainder not read. |
| `test/Spec.hs` | Structure mapped — 330 lines of imports, 48 `describe` blocks in one `main`, 149 trailing helpers. Test bodies not read. |
| `src/Kanban/Paths.hs` | **Read fully** — landed 2026-07-26, mid-audit. |
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
- **The module-splitting instinct is already present.** `src/Kanban/Paths.hs`
  landed during this audit: a small, focused module extracted to own `0700`
  enforcement across the XDG directory chain, with a comment explaining the bug
  that motivated it (`createDirectoryIfMissing` creating parents at the process
  umask). This is exactly the direction findings 1–5 argue for, applied
  unprompted.
