# Kanban pipeline hardening findings

A running collection of observations about the agent pipeline's operational
safety — the drainer daemon, the issue approver, and the command surfaces that
drive them — with focused repository evidence captured for later disposition
through `process-report`.

Distinct from `docs/drainer-bugs.md`, which collects behavioral findings about
how the drainer schedules and merges work. This report is about what happens
when the pipeline is interrupted, misdirected, or inspected.

Status legend: `[ ]` unprocessed · `[#N]` filed · `[no-issue]` closed without an issue · `[deferred]` blocked on a concrete precondition

> **Scope.** Eight chapters: intentional-stop safety (1-2), issue/pull-request
> number confusion (3), the two generations of the issue-review pipeline (4),
> recovery from a conflicted autostash (5), the blast radius of an approval
> incident (6), the autostash anchor's lifecycle (7), and where a fix lives
> versus where it runs (8).
>
> Two dependencies constrain filing order: chapter 2's PH-3 is specified
> against the rule PH-1 settles, and chapter 8's PH-12 is resolved by the
> migration PH-6 describes. Chapter 4 blocks nothing, but PH-6 governs
> whether the fixes recorded under PH-4 and PH-5 execute on a machine still
> running the pre-Kanban launcher.

## Status

- [ ] PH-1. Stopping the drainer clears incidents whose cause outlives the process
- [ ] PH-2. Drainer status cannot see outstanding obligations
- [ ] PH-3. An intentional stop abandons outstanding post-merge cleanup
- [x] PH-4. The canonical issue-review backend accepts pull-request numbers — [no-issue]
- [x] PH-5. Pull-request tools reject issue numbers only incidentally, and unintelligibly — [no-issue]
- [ ] PH-6. The issue-review half of the pipeline runs an untracked pre-Kanban generation
- [ ] PH-7. The issue-review daemon controller is untracked, unlike the drainer's
- [ ] PH-8. A conflicted autostash restore permanently wedges every later fast-forward
- [ ] PH-9. The wedge reports a misleading cause and never names its remedy
- [ ] PH-10. A malformed issue halts approval for every issue in the repository
- [ ] PH-11. Autostash anchor refs leak and are never reaped
- [ ] PH-12. The only executing pull-request guard is an untracked local edit

---

## Chapter 1 — What an intentional stop reports

Both findings here are about the drainer's own account of itself: what a stop
claims to have resolved, and what `status` is able to see. Neither changes what
the drainer *does*, so both are independently landable.

### PH-1. Stopping the drainer clears incidents whose cause outlives the process

> **Captured note:** when i tell the daemon to stop, it should run a quick
> cleanup first, so as not to break the pipeline when i stop the script

**Verification:** Verified with a scope correction — the shutdown itself is
already graceful and persists state, so a stop corrupts nothing. The defect is
that a stop marks *every* open incident `resolved`, including the two kinds
whose cause is not the drainer process and therefore survives it. Two of the
three kinds document their own self-clearing contract, and a stop violates both.

**Evidence:**

- `tools/drain_prs_service.py:1148` — a managed stop sends `launchctl kill
  SIGTERM`; the runner's `handle_stop` (`:1599`) forwards `SIGINT` to the
  child's process group, so `drain_prs.py`'s `KeyboardInterrupt` path runs and
  queue state is persisted. Shutdown is not the problem.
- `tools/drain_prs_service.py:1155` — on a confirmed stop, `stop_service`
  (`:1137`) calls `resolve_open_incidents(job, "Cleared when the PR drainer was
  intentionally stopped.")`.
- `tools/drain_prs_service.py:1530` — that helper rewrites every open incident
  to `status: resolved`, without consulting kind, pull request, or cleanup
  record. The claim is asserted, never established.
- `tools/drain_prs_service.py:163-165` — three kinds exist, and only one is
  about the process: `drainer-exit`, `merge-conflict`, `cleanup-pending`.
- `tools/drain_prs_service.py:1434` — a `merge-conflict` incident states its own
  contract: "Resolve the conflict on the PR branch; this incident clears itself
  once GitHub reports the PR mergeable again." Stopping the drainer does not
  make a pull request mergeable.
- `tools/drain_prs_service.py:1466` — a `cleanup-pending` incident states the
  same: "This incident clears itself once every outstanding step succeeds."
  Stopping the drainer completes no step.
- `tools/drain_prs.py:2121` — the obligation behind a `cleanup-pending`
  incident lives in `.git/drain_prs_state.json` as `pending` and
  `failed_passes`, untouched by anything in the stop path.
- `tools/drain_prs.py:2131` — the existing compensation, and proof the behavior
  is already known: cleanup incidents are re-recorded unconditionally because
  "an intentional stop clears every open incident for the repository. Trusting
  the stored id would hide an outstanding debt for good."
- Observed 2026-08-03 in `coghex/synarchy`: PR #1079 owed a fast-forward after
  9 failed passes under an open `cleanup-pending` incident. A stop at that
  moment would have reported the incident resolved over a still-wedged
  repository.

**Handoff context:**

- **Current behavior:** An intentional stop asserts a resolution it did not
  perform, for all three incident kinds. A `cleanup-pending` incident is
  re-raised only after the drainer is restarted and fails
  `CLEANUP_PASSES_BEFORE_INCIDENT` (`tools/drain_prs.py:47`, currently 3) more
  passes; a `merge-conflict` incident is re-raised only when that pull request
  is next attempted.
- **Expected behavior:** A stop should resolve only the incidents it genuinely
  ends — `drainer-exit`. Incidents whose subject is a pull request's state or a
  recorded obligation should survive the stop unchanged and continue to clear
  through their existing paths (`resolve_conflict_incident`,
  `resolve_cleanup_incident`) when the underlying cause is actually fixed.
- **Scope and constraints:** `start_service` is *not* gated on open incidents —
  `tools/drain_prs_service.py:1109` only snapshots them to detect new ones — so
  leaving them open adds no
  acknowledgement burden to an ordinary stop/start cycle. (This is unlike the
  issue-approval daemon, which does refuse to start with an open incident;
  do not carry that behavior across.) Intentional stops must remain free of
  ntfy notifications. Preserve the `tools/drain_prs.py:2131` compensation: a
  manual `ack` can still resolve an incident whose obligation is live, so the
  stored incident id must stay untrusted.
- **Remaining uncertainty:** Whether a surviving incident's `notes` should gain
  a line recording that a stop occurred while it was open, so an operator
  reading it later can tell the drainer was down rather than failing.

### PH-2. Drainer status cannot see outstanding obligations

**Verification:** Verified — `status_snapshot` never reads
`.git/drain_prs_state.json`, so outstanding post-merge debt is absent from
every status surface, including the Kanban board.

**Evidence:**

- `tools/drain_prs_service.py` — `status_snapshot` reports process state, PID,
  last activity, and open incidents. It contains no reference to the drainer
  queue state file, and therefore no path by which an obligation could reach a
  status caller.
- `tools/drain_prs.py:2121` — `failed_passes`, `pending`, and `last_error` live
  in `.git/drain_prs_state.json` and are the only durable record of debt.
- `tools/drain_prs.py:1510` — obligations are worked only from inside the
  polling loop's queue sweep, so a stopped drainer neither discharges them nor
  reports them.
- Observed 2026-08-03 in `coghex/synarchy`: with PR #1079 owing a fast-forward
  after 9 failed passes, `status` reported `state: running`; once the incident
  resolved it reported `open_incident: None`. At no point did any status
  surface name the outstanding step.

**Handoff context:**

- **Current behavior:** A stopped drainer owing five obligations is
  indistinguishable from a healthy idle one. Debt below
  `CLEANUP_PASSES_BEFORE_INCIDENT` is invisible everywhere; debt above it is
  visible only while an incident happens to be open, which PH-1 shows a stop
  will erase.
- **Expected behavior:** Status should surface outstanding obligations — at
  minimum a per-pull-request count of pending steps and the oldest
  `last_error` — so the board and the CLI both show debt without requiring an
  incident to have been raised.
- **Scope and constraints:** Status is called frequently, including by the
  board, so the read must stay cheap and strictly read-only. A missing,
  unreadable, or malformed state file must degrade to "unknown" rather than
  raising, since status is also the diagnostic used when the repository is in a
  bad state. The state file lives in the repository's `.git`, so status must
  keep working when the drainer is stopped and nothing holds its lock.
- **Remaining uncertainty:** Whether debt below the incident threshold should
  be visually distinct from an open incident on the board, or share one
  indicator.

---

## Chapter 2 — Discharging obligations on stop

Blocked on Chapter 1. PH-3 changes what a stop *does*, and its reporting
behavior is defined in terms of which incidents survive a stop — the question
PH-1 settles. Filing PH-3 first would either duplicate PH-1's decision or
hard-code the current indiscriminate clearing.

**Precondition for filing:** PH-1 has landed, so a stop's incident-handling
rule is fixed and PH-3 can be specified against it.

### PH-3. An intentional stop abandons outstanding post-merge cleanup

> **Captured note:** when i tell the daemon to stop, it should run a quick
> cleanup first, so as not to break the pipeline when i stop the script

**Verification:** Verified — `stop_service` performs no cleanup pass, so a
merged pull request's linked issue, worktree, local branch, remote branch, and
the local fast-forward are all left outstanding until the drainer is next
started.

**Evidence:**

- `tools/drain_prs_service.py:1137` — `stop_service` signals the job, polls for
  the process to exit, resolves incidents, and returns. It never invokes a
  cleanup pass nor inspects the queue state.
- `tools/drain_prs.py:1995-1998` — `plan_cleanup` records five obligation
  kinds, in dependency order: `issue`, `worktree`, `local-branch`,
  `remote-branch`, `fast-forward`.
- `tools/drain_prs.py:1510` — obligations are advanced only from the polling
  loop's queue sweep, which a stopped drainer does not run.
- The `issue` obligation is the pipeline-visible one: a merged pull request's
  linked issue stays open, so issue-selecting workflows can hand out work that
  is already implemented and merged.
- `tools/drain_prs_service.py:171` — `STOP_TIMEOUT_SECONDS` is 20, which bounds
  how long any stop-time work may take before `stop_service` reports a timeout.

**Handoff context:**

- **Current behavior:** Stop is immediate. Any obligation recorded but not yet
  discharged waits for the next start, which may be days later.
- **Expected behavior:** A stop should attempt one final cleanup pass over
  recorded obligations before exiting, within a bounded time budget, and report
  what it discharged and what it could not.
- **Scope and constraints:** The pass must stay bounded and must not hang on a
  wedged obligation — a conflicted fast-forward retried 9 times is a real
  observed case, and stop must still stop. It must discharge only recorded
  debts, never start new per-PR work such as a branch update or a merge. A
  `--pr` single-run caller must still receive exactly one JSON result on
  stdout. Whatever it fails to discharge must remain visible per PH-1 rather
  than being cleared on the way out.
- **Remaining uncertainty:** Whether a stop that cannot discharge everything
  should exit non-zero, warn, or stop silently — and whether the bound should
  be a share of `STOP_TIMEOUT_SECONDS` or a separate budget, given the stop
  path must still leave time to confirm the process actually exited.

---

## Chapter 3 — Issue and pull-request numbers are interchangeable

GitHub shares one number space between issues and pull requests. Both findings
here are about tools that take a bare number and cannot tell which kind they
were handed. Independent of chapters 1-2.

### [no-issue] PH-4. The canonical issue-review backend accepts pull-request numbers
> **Disposition:** No issue — fixed directly on 2026-08-03. `get_issue` in
> `tools/approve_issues.py` now refuses a pull request via an
> `issue_is_pull_request` url-path-segment check, covered by `--self-test`
> and by `PullRequestRejectionTests` in `tools/test_approve_issues.py`.
> Verified live against the canonical backend: `--check` on a pull request
> exits 1 having modified nothing, while a genuine issue proceeds to real
> gate evaluation. PH-6 still governs whether the machine executes this
> file; the fix is in the tracked backend regardless.

> **Captured note:** im also thinking about updating my other commands to not
> get prs and issues confused. solve shouldnt work on a pr for example

**Verification:** Verified, and escalated by what the command surface does
next. `tools/approve_issues.py` had no notion of a pull request at all, and
`gh issue view <pr>` returns a complete, valid-looking issue document for one.
Worse than a silent accept: `/solve` on a pull-request number was rejected for
an unrelated reason, and its rejection message directs the operator to press
`r` — which runs the very action that is destructive.

**Evidence** — the state as found on 2026-08-03. The first three items were
resolved by the fix recorded in the disposition above; the rest still stand,
and the `/solve` message in particular is unchanged:

- `tools/approve_issues.py` (as found) — a search for `pull_request` or
  `/pull/` returned zero matches. The backend had no concept of the other kind
  of number.
- `tools/approve_issues.py:380` — `get_issue` fetches with `gh issue view
  <number> --json number,title,body,url,state,labels,...`. Observed against
  `coghex/synarchy#1080`, a pull request: exit 0, with every requested field
  populated. The only field that betrays the kind is `url`, which reads
  `.../pull/1080` rather than `.../issues/1080`. This is where the guard now
  lives.
- `--check`, `--review` and `--rereview` all fetch through that one function,
  so none of them could distinguish the two kinds — and that funnel is why one
  guard now covers all three.
- Observed 2026-08-03 on `coghex/synarchy`: `approve_issues.py --review 1080`
  against a pull request stripped its `reviewed:approve` label about one second
  in (failing its branch-protection gate), published an `issue-review:v2`
  INVALID verdict as a comment on the pull request, and opened an
  `invalid-issue` incident. That incident halts the whole approval pipeline —
  every subsequent `--check` returns `approved: false` for every issue in the
  repository, so no new work can be claimed anywhere until it is acknowledged.
  The model's own verdict text identified the cause: "The dossier targets pull
  request #1080, not an issue awaiting specification review."
- `claude-plugin/plugins/kanban/commands/solve.md:61` — `/solve` delegates its
  entire defense to `--check`, which has no guard. A pull request awaiting
  merge carries `reviewed:approve`, so the label test it applies is satisfied;
  it is the absence of an `issue-review:v2` marker that rejects it, not its
  kind.
- `claude-plugin/plugins/kanban/commands/solve.md:64` — on that rejection
  `/solve` stops with `KANBAN_NEEDS_INPUT: This issue needs canonical review;
  press r on the issue, then retry.` Pressing `r` invokes `--review`, the
  action proven destructive above. The command surface routes an operator who
  mistyped a number directly into the failure.

**Handoff context:**

- **Current behavior:** Any of the three number-taking modes proceeds against a
  pull request as though it were an issue. `--check` fails for the wrong
  reason and advises an action that makes things worse; `--review` and
  `--rereview` mutate the pull request and halt the pipeline.
- **Expected behavior:** A pull-request number is refused up front by every
  mode, with a message naming the mistake and pointing at the pull-request
  workflow, having modified nothing.
- **Scope and constraints:** The guard belongs at the `get_issue` fetch funnel
  rather than at each entry point, so a future number-taking mode cannot forget
  it, and it must land before the label-clearing that runs early in a review.
  Discriminate on the `url` field's path *segment* (`.../pull/<n>`), never a
  substring: a repository named `pull` puts `/pull/` in the URL of every one of
  its issues. Do not verify by re-fetching with `gh pr view` (see PH-5 for why
  that is unreliable). The fix must land in `tools/approve_issues.py`, the
  tracked canonical backend — a guard added to the untracked pre-Kanban
  launcher at `~/work/approve-issues.py` protects only that machine and is
  invisible to `tools/test_approve_issues.py`.
- **Reference implementation:** A working guard was written into the untracked
  pre-Kanban launcher on 2026-08-03 and can be lifted directly. It adds an
  `issue_is_pull_request` predicate comparing the `url` path segment, enforces
  it at the end of `get_issue`, and covers both directions plus the
  repository-named-`pull` case and missing/short URLs in `--self-test`. It was
  mutation-checked (a deliberately wrong std140-style constant made the
  assertions fail) and confirmed live: `--check`, `--review` and `--rereview`
  against `coghex/synarchy#1080` all exited 1 having modified no label, posted
  no comment, and opened no incident. It is not in the repository, and per PH-6
  it is not in the file that executes.
- **Remaining uncertainty:** Whether `/solve`'s rejection message should
  distinguish "this is a pull request" from "this issue is unreviewed" itself,
  or rely entirely on the backend's message reaching the operator.

### [no-issue] PH-5. Pull-request tools reject issue numbers only incidentally, and unintelligibly
> **Disposition:** No issue — fixed directly on 2026-08-03. `pr_view` now
> catches the fetch failure and re-queries through `github_number_kind`,
> which classifies any number via `gh issue view --json url` (the one form
> that resolves both kinds), and refuses an issue number by name. The
> classification is authoritative rather than a match against gh's error
> text, and it runs only on the failure path, so a healthy review pays
> nothing. Verified live: `pr_view` on issue #1078 raises "#1078 is an
> ISSUE, not a pull request", while a real pull request still fetches and
> reaches the normal open-state check.
>
> The chapter's open question — whether to share one identity helper — is
> resolved as NO. `review_pr.py` imports only the standard library and is a
> vendored self-contained plugin asset (`docs/agent-workflow-contract.md`
> §3), so it must not import from `tools/`. The predicate is duplicated,
> with a comment at each copy saying why.

**Verification:** Verified as safe but undiagnosable — the reverse mistake
failed, but only as a side effect of which fields happen to be requested, and
the resulting message named GraphQL rather than the mistake.

**Evidence** — the state as found on 2026-08-03. The first item is what the fix
in the disposition above addresses; the second and third still stand as
constraints on any future change:

- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py:327` —
  fetches with `gh pr view <number> -R <repo> --json <fields>` where the field
  list includes real pull-request fields. Observed against `coghex/synarchy#1078`,
  an issue: exit 1, stderr `GraphQL: Could not resolve to a PullRequest with
  the number of 1078. (repository.pullRequest)`, empty stdout. The run failed
  safely, but nothing told the operator they had passed an issue number. This
  is the call the guard now wraps.
- The protection is incidental, and a naive guard would defeat it: `gh pr view
  1078 --json number` alone returns exit 0 with `{"number":1078}`. Only
  requesting a field that forces the `PullRequest` resolver produces the error,
  so a validation step that fetches just `number` would be fooled.
- `codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py:638` —
  the same script fetches linked issues with `gh issue view <number>`, which
  carries PH-4's silent-acceptance shape: were a pull-request body ever to name
  another pull request in a closing reference, that fetch would return it and
  the gate would evaluate a pull request as an issue.

**Handoff context:**

- **Current behavior:** Passing an issue number to a pull-request tool fails
  with a GraphQL resolver error. No data is mutated, so this is a
  diagnosability defect rather than a safety one.
- **Expected behavior:** The same explicit refusal PH-4 asks for, in the
  mirror direction: name the mistake, name the number, and point at the issue
  workflow.
- **Scope and constraints:** Whatever shared helper PH-4 introduces should
  serve both directions, so the two never drift into disagreeing about what
  kind a number is. The check must not rely on `gh pr view --json number`.
- **Remaining uncertainty:** Whether both directions warrant one shared
  identity helper in `tools/`, given the pull-request tools live under
  `codex-plugin/` and the issue tools under `tools/`, and the plugin
  directories may have their own vendoring rules.

---

## Chapter 4 — Two generations of the issue-review pipeline

The drainer half of the pipeline runs Kanban's tracked assets through a managed
install. The issue-review half still runs a pre-Kanban generation that predates
it: an untracked backend, an untracked launcher command, and an untracked
daemon controller, none of which the repository's tests, review, or install
machinery reach.

This chapter does not block filing PH-4, whose fix is correct regardless. It
determines whether that fix has any *effect*: a guard added to
`tools/approve_issues.py` changes nothing on a machine still executing the
pre-Kanban launcher.

### PH-6. The issue-review half of the pipeline runs an untracked pre-Kanban generation

**Verification:** Verified on this machine, and the divergence is substantial —
the canonical backend is 2137 lines and actively maintained, the launcher it is
supposed to have replaced is 2036 lines and frozen. The migration that
reconciles them is fully built and tested, and has never been run.

**Evidence:**

- `tools/install_issue_review.py:3-10` — the installer's own docstring names
  both generations: it installs "a stable Kanban-managed link to the tracked
  `tools/approve_issues.py` backend" and "optionally migrates the pre-Kanban
  compatibility launcher at `~/work/approve-issues.py`".
- `tools/install_issue_review.py:41` — `DEFAULT_LEGACY_PATH = Path.home() /
  "work" / "approve-issues.py"`, the launcher still in use.
- Observed: `~/work/approve-issues.py` is an ordinary 2036-line file, not a
  symlink. `tools/approve_issues.py` is 2137 lines; a diff reports 333 changed
  lines. The tracked file carries `import kanban_config`, the
  `KANBAN_MANAGED_ASSET` identity marker (`tools/approve_issues.py:30`), and
  Kanban-owned runtime paths; the untracked one still hardcodes an ntfy URL.
- Observed: `~/Library/Application Support/kanban/issue-review/` does not
  exist. There is no managed link and no install record, so nothing that
  resolves the backend canonically can find one.
- `claude-plugin/plugins/kanban/commands/solve.md:14-40` — the tracked `/solve`
  resolves `$BACKEND` through that install record, falling back to
  `record.parent / "approve_issues.py"`. On this machine every branch of that
  resolution names a path that does not exist.
- Observed: an untracked `~/.claude/commands/solve.md` (dated 2026-07-18)
  hardcodes `python3 "$HOME/work/approve-issues.py" ... --check`. Both
  generations of the command are installed simultaneously — the Kanban plugin
  is registered as `kanban@kanban`, project scope, 2026-07-21 — and the legacy
  user-scope command is the one that fires: a `/solve 1072` run on 2026-08-03
  in `coghex/synarchy` executed the hardcoded legacy path.
- Consequence for the repository: `tools/test_approve_issues.py` exercises a
  file that is not the one serving reviews, and any fix landed in
  `tools/approve_issues.py` — PH-4's included — is inert until the migration
  runs.

**Handoff context:**

- **Current behavior:** Reviews are served by an untracked fork. Repository
  tests and repository fixes apply to a file nothing executes.
- **Expected behavior:** The issue-review half is installed the same way the
  drainer half already is, so the executed backend is the tracked one and the
  repository's tests describe reality.
- **Scope and constraints:** The migration path exists and is bounded —
  `tools/install_issue_review.py:192` `plan_legacy_launcher`, invoked with
  `--migrate-legacy-launcher` (`:497`), backs the ordinary file up to
  `approve-issues.py.pre-kanban-backup` and replaces it with a symlink; without
  the flag it refuses and says so. Note this retires any local edit made
  directly to the launcher, preserving it only as that backup — a
  pull-request guard added there on 2026-08-03 is one such edit. The duplicate
  untracked `~/.claude/commands/*.md` generation should be retired in the same
  pass, or the legacy command will keep shadowing the plugin's.
- **Remaining uncertainty:** Whether the Kanban plugin's project scope is why
  the legacy user-scope command wins outside the kanban checkout, and therefore
  whether retiring the legacy commands is sufficient or the plugin also needs a
  wider scope. This is machine configuration rather than repository state, so
  the disposition may be an operational task rather than an issue.

### PH-7. The issue-review daemon controller is untracked, unlike the drainer's

**Verification:** Verified — the repository tracks the drainer's service
controller and ships an installer for it, but tracks no equivalent for the
issue-review daemon. That controller lives only in an agent skill directory and
hardcodes the legacy backend path.

**Evidence:**

- `tools/drain_prs_service.py` is tracked, tested by
  `tools/test_drain_prs_service.py`, and installed by `tools/install_drainer.py`
  into `~/Library/Application Support/kanban/pr-drainer/` as symlinks to the
  tracked files.
- No equivalent is tracked: a search of the repository index for an
  issue-review service controller returns nothing. `tools/install_issue_review.py`
  installs the backend only, and its docstring states it "never starts a
  daemon".
- Observed: the controller actually in use is
  `~/.codex/skills/approve-issues/scripts/approve_issues_service.py`, dated
  2026-07-19, outside any repository. It sets `APPROVER_PATH = WORK_DIR /
  "approve-issues.py"` as a constant, so the daemon cannot be pointed at a
  canonically installed backend the way the tracked commands can.
- `src/Kanban/Preflight/Environment.hs:377` — `isManagedAsset` verifies a
  backend by the identity marker it carries rather than by its location, and is
  the mechanism that would detect an unmanaged backend. It inspects the install
  path; nothing inspects what the daemon actually executes.

**Handoff context:**

- **Current behavior:** Half the daemon surface is versioned, tested, and
  installable; the other half is a loose script outside the repository. A fix
  to the issue-review daemon's lifecycle behaviour cannot be reviewed, tested,
  or shipped through the same path as the drainer's.
- **Expected behavior:** The issue-review controller is tracked alongside
  `tools/drain_prs_service.py`, installed by `tools/install_issue_review.py`
  into the same managed location, and resolves its backend through the install
  record rather than a hardcoded path — matching what the tracked command
  surface already does.
- **Scope and constraints:** The existing controller's behaviour must be
  preserved as it stands, including the single-issue lock, incident recording,
  and the refusal to start while an incident is open — that last is deliberate
  and differs from the drainer, per PH-1. Migration must not orphan the running
  launchd job, and the identity-marker convention
  (`tools/approve_issues.py:30`) should extend to the controller so
  `isManagedAsset` can verify it too.
- **Remaining uncertainty:** Whether the two daemons should converge on one
  controller implementation or stay separate with a shared library, given they
  already differ deliberately on incident-gated startup.

---

## Chapter 5 — Recovering from a conflicted autostash

The fast-forward obligation autostashes local changes in the primary checkout,
fast-forwards, and restores. When the restore conflicts, the drainer leaves the
checkout in a state that blocks its own next attempt — permanently, and while
reporting a cause that is not the real one. Observed twice: 2026-08-01 (PRs
#1041 and #1038, 26 failed passes before anyone noticed) and 2026-08-03 (PR
#1079, 9 failed passes), both in `coghex/synarchy`, both on the same file.

Independent of chapters 1-4, though PH-2 is why the wedge stays invisible for
so long and PH-1 is why stopping the drainer erases the only alarm it raises.

### PH-8. A conflicted autostash restore permanently wedges every later fast-forward

**Verification:** Verified — the failure is self-inflicted and self-sustaining.
A conflicted restore leaves unmerged entries in the index; `git stash` refuses
to run against an unmerged index; the next pass therefore fails while *taking
the snapshot*, before it ever reaches the fast-forward. Nothing detects or
clears that state, so every subsequent pass fails identically.

**Evidence:**

- `tools/drain_prs.py:1859` — restoration runs `git stash apply --index
  <sha>`. On conflict this exits non-zero having written conflict markers into
  the working tree and left **unmerged entries in the index**.
- `tools/drain_prs.py:1863-1876` — that non-zero return is handled by
  preserving the snapshot and appending a problem string. The half-applied
  conflicted state is left in place; nothing aborts, resets, or records it.
- `tools/drain_prs.py:1885` — the pass then raises "Fast-forward succeeded, but
  restoring local changes failed". Accurate, and the last time the real cause
  is stated.
- `tools/drain_prs.py:1916-1925` — the next pass begins by relocating untracked
  files, taking a `git stash create` snapshot, anchoring it, and only then
  running `reset --hard`. The snapshot step is where an unmerged index is
  fatal: git reports "Cannot save the current index state".
- `tools/drain_prs.py:1927-1934` — that failure takes the `prep_exc` branch and
  raises before any fast-forward is attempted. There is no path by which a
  later pass can clear the condition, so the obligation retries forever at the
  polling interval.
- `tools/drain_prs.py:281-295` — the repository already has a guard of exactly
  this shape. `in_progress_operation` refuses to run while a rebase, am, merge,
  cherry-pick, revert, or bisect is in progress, reasoning in its own docstring
  that "a human resolves it, so every merge in the run would fail the same
  avoidable way". A conflicted `git stash apply` creates none of those marker
  files, so the one state the drainer inflicts on itself is the one the guard
  does not cover. A search for `diff-filter=U`, `ls-files -u`, or `unmerged`
  in the drainer returns nothing.
- `tools/test_fast_forward_stash.py:253` —
  `test_conflicting_restore_recovers_snapshot_and_preserves_other_stashes`
  covers the conflicted restore, but asserts only that the user's snapshot is
  recoverable: the error message, two entries in `git stash list`, and a
  surviving anchor ref. It never inspects the index afterwards and never
  invokes `fast_forward_default_branch` a second time, so the wedge is outside
  what it proves.
- Observed 2026-08-03 in `coghex/synarchy`: resolving the one conflicted file
  and running `git add` was sufficient — the running drainer discharged the
  obligation on its next tick, roughly 15 seconds later, and logged
  "PR #1079: post-merge cleanup complete".

**Handoff context:**

- **Current behavior:** One conflicted restore stops every future fast-forward
  in that checkout until a human resolves the index by hand. Local default
  branch silently falls behind the remote, and each subsequently merged pull
  request accumulates the same undischargeable obligation.
- **Expected behavior:** Either the drainer does not leave a conflicted index
  behind — aborting the apply and relying on the preserved snapshot and anchor
  ref, which already exist for exactly this purpose — or it detects an unmerged
  index up front and refuses with the same clarity `in_progress_operation`
  already provides.
- **Scope and constraints:** The user's work is the priority and is currently
  safe in three places: `git stash list`, the `refs/drain-prs/autostash/<sha>`
  anchor, and the stage-3 blob. Any change must keep all three; recovering the
  snapshot must not become conditional on the cleanup succeeding. Aborting the
  apply discards the partial merge git computed, which may be most of the
  resolution work, so discarding it silently would be its own regression.
- **Remaining uncertainty:** Whether to prevent the state or merely detect it.
  Prevention keeps the drainer running but hands the user a conflict to resolve
  from the stash themselves; detection lets the conflicted tree stand as git
  left it but still halts the queue until a human acts. The two differ in who
  does the merge, not in whether the drainer stalls.

### PH-9. The wedge reports a misleading cause and never names its remedy

**Verification:** Verified — the accurate diagnosis is produced once, on the
pass that creates the problem, and is then overwritten by a message that blames
the user's local changes. The incident an operator eventually sees carries only
the misleading one.

**Evidence:**

- `tools/drain_prs.py:1885` — the originating pass reports "Fast-forward
  succeeded, but restoring local changes failed", which names the real event.
- `tools/drain_prs.py:1930` — every later pass reports "Local changes blocked
  fast-forward, and preparing a temporary snapshot of them failed; aborting."
  This attributes the failure to the presence of local changes. The actual
  blocker is the unmerged index the drainer itself created, and no amount of
  changing or reverting local edits will clear it.
- `tools/drain_prs.py:47` — `CLEANUP_PASSES_BEFORE_INCIDENT` is 3, so an
  incident is only raised on the fourth failure, by which point `last_error`
  holds the misleading message and the accurate one has been overwritten.
- `tools/drain_prs_service.py:1463-1466` — the incident's operator notes say
  the merge landed, that the drainer keeps retrying and keeps draining other
  pull requests, and that "This incident clears itself once every outstanding
  step succeeds." None of that is actionable here: the step cannot succeed
  without human intervention the notes never mention.
- Observed 2026-08-03: incident `incident-20260803T172400Z-49478-pr1079`
  carried `last_error` as the raw git text — "Cannot save the current index
  state", preceded by three `docs/code_health_findings.md: unmerged (<sha>)`
  lines. The remedy is to resolve that file and `git add` it; nothing in the
  incident, the notes, or the log says so.

**Handoff context:**

- **Current behavior:** The operator is told local changes are blocking a
  fast-forward, which is misleading, and is given raw git output containing the
  word "unmerged" with no interpretation.
- **Expected behavior:** A cleanup incident for a blocked fast-forward should
  name the actual blocker and the action that clears it, and the originating
  error should not be discarded by later passes that merely observe its
  consequence.
- **Scope and constraints:** Message text is cheap to change, so this can land
  independently of PH-8 and would have shortened both observed incidents. If
  PH-8 chooses prevention, this message changes again — worth sequencing after
  it, though not blocked by it. The retained original cause should not grow
  unboundedly across passes.
- **Remaining uncertainty:** Whether the drainer should carry remedy text for
  each failure mode, or whether the incident should link to a documented
  recovery procedure that covers this and similar states.

---

## Chapter 6 — Blast radius of an approval incident

The two daemons take opposite approaches to a fault. The drainer records an
incident, keeps draining every other pull request, and clears the incident when
the cause is fixed. The approver records an incident and stops approving
anything until a human acknowledges it. The second is a deliberate circuit
breaker; this chapter is about whether its radius matches the fault it trips on.

Independent of chapters 1-5.

### PH-10. A malformed issue halts approval for every issue in the repository

**Verification:** Verified — every mode of the approver consults the same
repository-wide breaker, and the only incident kind it can raise is scoped to a
single issue. The incident even records which issue caused it; the breaker
never reads that field.

**Evidence:**

- `tools/approve_issues.py:841-853` — `apply_pipeline_circuit_breaker` sets
  `approved: False` and prepends "issue approval pipeline is halted by open
  incident <id>" whenever any open incident exists for the repository,
  regardless of which issue was asked about.
- `tools/approve_issues.py:818-838` — `latest_open_pipeline_incident` matches on
  `value.get("repo") == canonical_repo`, so the radius is correctly confined to
  one repository and does not leak across checkouts.
- `tools/approve_issues.py:1649` — `open_invalid_incident`, whose docstring
  calls it "the circuit-breaker incident for one repo", is the only incident
  the backend raises, and its only `kind` is `invalid-issue` — a verdict about
  one issue's specification.
- `tools/approve_issues.py:1667-1671` — the incident record includes
  `"issue": issue_number`. The information needed to scope the halt to the
  offending issue is already persisted; nothing consults it.
- Every mode is gated, so there is no route around it: `--check` applies the
  breaker (`:2112`), `--review` (`:1506`) and `--rereview` (`:1561`) raise
  `ApproveError` before doing any work, and the polling daemon raises the same
  way (`:2147`).
- The only way out is an explicit acknowledgement. There is no self-clearing
  path, in deliberate contrast to the drainer, whose cleanup incident states
  "The drainer is still running, keeps retrying these steps, and keeps draining
  every other approved PR" and "This incident clears itself once every
  outstanding step succeeds" (`tools/drain_prs_service.py:1463-1466`).
- Observed 2026-08-03 in `coghex/synarchy`: a pull-request number passed to
  `--review` (PH-4) produced one `invalid-issue` incident. Issue #1072 —
  unrelated, already reviewed, and carrying a valid approval marker — then
  reported `approved: false` with the reason "issue approval pipeline is halted
  by open incident incident-20260803T170916Z-27540". No issue in the repository
  could be claimed until the incident was acknowledged by hand.

**Handoff context:**

- **Current behavior:** A verdict about one issue's specification stops all
  issue approval, and therefore all `/solve` work, in that repository until a
  human intervenes. The offending issue is identified in the incident but plays
  no part in what gets blocked.
- **Expected behavior:** The breaker distinguishes a fault scoped to one issue
  from one that impugns the backend or the reviewer. An `invalid-issue`
  incident naming issue N should be able to block N — which must not be
  claimable — while leaving unrelated, validly approved issues claimable.
- **Scope and constraints:** The breaker is deliberate and must survive in some
  form: an INVALID verdict can mean the reviewer itself is misbehaving, and
  halting everything is the safe reading of that. Any narrowing therefore needs
  a retained path that still halts the repository for faults that are not
  attributable to one issue. No new state is required — the `issue` field is
  already recorded. `open_invalid_incident` deliberately does not shell out to
  an external controller so that no personal Codex skill directory is required
  (`docs/agent-workflow-contract.md` §5); keep that property.
- **Remaining uncertainty:** Whether several invalid verdicts in quick
  succession should escalate from issue-scoped back to repository-wide, on the
  theory that the reviewer rather than the issues is at fault; and whether an
  incident left open for a long period should decay or nag rather than silently
  continuing to block.

---

## Chapter 7 — The autostash anchor has no lifecycle

The fast-forward autostash anchors its snapshot at
`refs/drain-prs/autostash/<sha>` before running `reset --hard`, so the user's
changes survive a crash in the window before restoration. That is sound. What
is missing is the other end: the anchor is released only on the happy path, and
nothing ever enumerates, reports, or reaps the ones left behind.

Same subsystem as chapter 5, and reachable through the same conflicted restore,
but a distinct defect: PH-8 is about the drainer blocking itself, this is about
what accumulates in the repository afterwards.

### PH-11. Autostash anchor refs leak and are never reaped

**Verification:** Verified, with live evidence in a working checkout — two
anchors exist, one of them orphaned for two days with no corresponding stash
entry. Its contents were checked against `HEAD`: it is a strictly older
revision of files that have since advanced, so no work was lost. The defect is
accumulation and ambiguity, not data loss.

**Evidence:**

- `tools/drain_prs.py:1798` — `_anchor_snapshot` writes
  `refs/drain-prs/autostash/<sha>` before anything destructive, with the
  in-code rationale that once `reset --hard` runs "this floating commit is the
  only copy of the user's changes until restoration completes".
- `tools/drain_prs.py:1876` — `_release_snapshot_anchor` is called from exactly
  one place: the `elif` branch taken when `git stash apply --index` returned
  zero. Every other outcome leaves the ref in place.
- `tools/drain_prs.py:1863-1872` — a conflicted apply deliberately keeps the
  anchor and additionally preserves the snapshot into `git stash list`. That
  belt-and-braces choice is correct; what is missing is anything that later
  reaps the anchor once the snapshot is known to be recovered.
- `tools/drain_prs.py:1945` — restoration runs in a `finally`, so an ordinary
  exception still restores and releases. A signal that terminates the process
  outright does not: `tools/drain_prs_service.py:1605` escalates the *second*
  stop signal to `SIGKILL` for the child's process group, which skips the
  `finally` entirely. This path is narrow — `stop_service` sends exactly one
  signal (`:1146`, `:1148`), `KeepAlive` is `False` (`:952`), and the runner
  only escalates on a second signal — so it requires an operator retrying
  `stop` after the 20-second timeout (`:171`) while the child sits in the
  window between `reset --hard` and restoration.
- A search of `tools/drain_prs.py` for `for-each-ref` returns zero matches:
  nothing enumerates the anchors, so no startup sweep, status surface, or
  recovery command can see them.
- Observed 2026-08-03 in `coghex/synarchy`: two anchors are present.
  `refs/drain-prs/autostash/3279dac4` has a matching `stash@{0}:
  drain-prs-autostash-recovery 3279dac4...` entry, from that morning's
  conflicted restore. `refs/drain-prs/autostash/4671c5d0` has no stash entry at
  all. Its commit message is `On master:
  drain-prs-autostash-1785613624-53303`, dated 2026-08-01 12:47, and the PID it
  names matches incidents `incident-20260801T201429Z-53303-pr1038` and
  `incident-20260801T194933Z-53303-pr1041`. Diffing it against `HEAD` shows only
  superseded content — an older `CH-11` line still marked `[deferred]: #946
  must land` where `HEAD` carries `[x] ... [#1077]`, and an older `make ci`
  bullet in `CLAUDE.md`.

**Handoff context:**

- **Current behavior:** Every abnormal restoration path leaks an anchor. They
  accumulate indefinitely, and because they are refs they pin their objects
  against garbage collection permanently. An operator inspecting
  `refs/drain-prs/autostash/` cannot distinguish a live safety net holding the
  only copy of their work from debris left by an incident resolved days ago.
- **Expected behavior:** The anchor gets a full lifecycle: reaped once its
  snapshot is provably recoverable elsewhere, and enumerable while it is not,
  so that recovery is a supported operation rather than repository archaeology.
- **Scope and constraints:** Reaping must be conservative — the anchor exists
  precisely to survive a crash, so it must never be removed on the strength of
  an assumption that restoration worked. Keeping the anchor on a conflicted
  restore is correct and must stay. A reaper must not run inside the same pass
  that may itself crash mid-window. Recovery guidance belongs with it: the
  existing wedge documentation reaches for `git cat-file -p` on stage blobs,
  which is not a procedure anyone should have to invent under pressure.
- **Remaining uncertainty:** Whether reaping belongs at drainer startup, where
  a clean working tree is evidence that restoration completed, or in an
  operator-invoked command; and whether the anchors should appear in status
  alongside the outstanding obligations of PH-2, since both answer "what does
  this checkout still owe me".

---

## Chapter 8 — Where a fix lives versus where it runs

Chapter 4 established that the issue-review half of the pipeline executes an
untracked pre-Kanban generation. This chapter records the operational
consequence, made concrete by the PH-4 fix: a repository can hold a correct,
tested, reviewed fix while the machine runs an untracked copy, and nothing in
either place can answer "is the pipeline actually protected?"

Blocked on chapter 4 in the same sense PH-3 is blocked on PH-1: PH-12 is
resolved by PH-6's migration and has no independent fix of its own.

**Precondition for filing:** PH-6 has a disposition, since PH-12's only
resolution is the migration PH-6 describes.

### PH-12. The only executing pull-request guard is an untracked local edit

**Verification:** Verified on this machine. The canonical guard landed in
`tools/approve_issues.py`, which is not the file the daemon runs; the file it
does run carries a hand-applied copy of the same guard that no repository
tracks, no test covers, and no review saw.

**Evidence:**

- The guard was applied to `~/work/approve-issues.py` on 2026-08-03, before it
  was understood that this file is not the canonical backend. It is still
  there: nine references to `issue_is_pull_request`.
- The canonical fix is a separate, later implementation in
  `tools/approve_issues.py`, committed with `--self-test` and
  `PullRequestRejectionTests` coverage.
- `~/.codex/skills/approve-issues/scripts/approve_issues_service.py` sets
  `APPROVER_PATH = WORK_DIR / "approve-issues.py"` as a constant, so the daemon
  runs the untracked file regardless of what the repository contains.
- `~/work/approve-issues.py` is still an ordinary file, not a symlink to a
  managed backend, and `~/Library/Application Support/kanban/issue-review/`
  does not exist — the migration described in PH-6 has not run.
- Therefore the tracked fix does not execute here, and the executing guard is
  the untracked one. Removing the untracked copy on the assumption that the
  tracked fix supersedes it would reinstate the exact failure of 2026-08-03
  while the repository showed a fix in place. This was proposed and rejected on
  the evidence above; it is recorded here because it is an easy and plausible
  mistake to make later.
- The two copies are independent implementations of the same rule. Nothing
  compares them, so they can diverge silently — and only one of them is
  reachable by `tools/test_approve_issues.py`.

**Handoff context:**

- **Current behavior:** Protection depends on an untracked file. The
  repository's own tests pass against a copy that does not run, so a green test
  suite is not evidence that the pipeline is guarded.
- **Expected behavior:** One implementation, in the repository, executing.
  PH-6's migration achieves this: `install_issue_review.py
  --migrate-legacy-launcher` backs the ordinary file up to
  `approve-issues.py.pre-kanban-backup` and replaces it with a symlink to the
  managed link, after which the daemon's hardcoded path resolves to the tracked
  backend and the local copy stops being live.
- **Scope and constraints:** Order matters and is the whole point — the
  untracked guard must not be removed *before* the migration makes the tracked
  one executable, or the pipeline is unprotected in the interval. After the
  migration the backup file is inert and may be deleted at leisure. Nothing
  should be deleted on the strength of a repository fix alone.
- **Remaining uncertainty:** Whether anything should detect this class of
  divergence generally — a check that the executing backend carries the
  identity marker the repository expects, which `Kanban.Preflight.Environment`
  already has the mechanism for (`isManagedAsset`) but applies to the install
  path rather than to what the daemon actually launches.
