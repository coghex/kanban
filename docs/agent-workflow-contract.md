# Kanban agent-workflow contract

Contract version: 2

## 1. Purpose and scope

Kanban's board is fully usable without any AI provider. A smaller set of
explicit actions — issue solve, PR review/rereview/revise, canonical issue
review/rereview, the solve readiness gate, and the optional PR drainer — call
out to external executables, a canonical review backend, and (for the
drainer) a user-scoped launchd service. This document is the single
authoritative list of those external dependencies: what owns them, how
Kanban invokes them, what they return or fail with, what authority they
need, where their durable state lives, and whether they are mandatory for
Kanban to run at all or optional AI/automation add-ons.

It also declares the boundary between what Kanban owns and tracks in this
repository and what remains explicit, opt-in user-machine state (the PR
drainer's LaunchAgent; the compatibility launcher described in §3), and the
policy any installer for that state must follow.

A fresh checkout can use this document to answer: "why did action X fail,"
"what do I need to install before X works," and "is path Y something Kanban
manages or something I must set up myself."

The tracked plugins also package issue-drafting and canonical issue-review
workflows that Kanban's own CLI never spawns — a user or the review daemon
invokes them directly. Their responsibilities, boundaries, and inventory live
in [drafting-workflow-contract.md](drafting-workflow-contract.md); their
external commands and user-scoped paths are declared in §4 here, alongside
everything else.

## 2. Supported agent actions

### 2.1 Issue solve (`$solve` / `/solve`)

- **Owning source:** `src/Kanban/Solve.hs`.
- **Invocation:** resolves the `codex` or `claude` executable with
  `findExecutable`, then spawns it (`createProcess`) with solve-specific
  arguments (model/effort flags and the initial or resume solve prompt built
  by `initialSolvePrompt`/`resumeSolvePrompt`).
- **Inputs:** issue number, solver brand, optional resumed session id and
  follow-up user message.
- **Outputs:** a durable session log, worker events, and on success a pushed
  branch and an opened pull request whose body ends with
  `<!-- pr-origin:codex -->` or `<!-- pr-origin:claude -->`.
- **Failure semantics:** a missing executable surfaces
  `SolveFailed "<name> was not found on PATH"`; a session may pause with a
  trailing `KANBAN_NEEDS_INPUT: <question>` line and resumes with the same
  session id once the user answers.
- **Required authority:** the user's existing `gh auth login` (issue
  assignment, branch push, PR creation); local filesystem access to create a
  worktree.
- **Durable state:** the per-issue worktree, plus the session log file.
- **Mandatory/optional:** optional — only exercised by the `S`/`A` keys, and
  only after the user picks a provider.

### 2.2 PR review, rereview, and revise

- **Owning source:** `src/Kanban/PullRequestFlow.hs`.
- **Invocation:** resolves and spawns `codex` or `claude` the same way as
  solve, running the named canonical command: `pr-review` and `pr-rereview`
  always run on the opposite brand from the PR's origin marker; `pr-revise`
  runs on the PR's own origin brand and internally invokes exactly one
  canonical `pr-rereview` after pushing a fix.
- **Inputs:** PR number, PR origin marker, action
  (`PullRequestReview` | `PullRequestRereview` | `PullRequestRevision`),
  optional resumed session/user message.
- **Outputs:** a session log; the canonical workflow itself publishes the
  `reviewed:*` label and review comment — Kanban never sets a verdict label
  directly.
- **Failure semantics:** the same missing-executable and
  `KANBAN_NEEDS_INPUT` handoff pattern as solve.
- **Required authority:** GitHub write on the PR (labels, comments,
  pushes). No action in this surface ever merges a PR.
- **Durable state:** session log; the isolated worktree `pr-revise` works
  in.
- **Mandatory/optional:** optional — only exercised by the `r` key.
- **Cross-brand handoff model policy:** for known-origin `$pr-review`/
  `$pr-rereview` — the case Kanban's own invocation always produces, since
  every Kanban-created PR carries a `pr-origin` marker — the session Kanban
  spawns already *is* the correctly-pinned canonical reviewer (Kanban chose
  its brand via `agentForAction` and its model/effort via `codexModel`/
  `codexEffort`/`claudeModel`/`claudeEffort` before invoking it). A packaged
  workflow implementing this action must have that already-correct session
  perform the review itself and use its bundled coordinator only to publish
  the result safely (gate/head/race checks, comment, label) — not spawn a
  further, unpinned nested reviewer that would both waste and be unable to
  verify Kanban's guarantee.
  `pr-revise` is the one genuine exception: it runs on the PR's own origin
  brand, so its internal "invoke exactly one canonical `pr-rereview`" step
  must spawn the *opposite* brand from inside that session — a nested
  invocation no top-level Kanban CLI spawn is present to configure, and the
  only case (along with the dual-review fallback for unknown/external
  origin, which Kanban's own invocation never triggers) where "keep model
  selection with Kanban's invoking code and canonical workflow policy" means
  brand selection only (which of `codex`/`claude` runs), not a specific
  pinned or verified model/effort: which model backs a `codex`/`claude`
  install for canonical review purposes is then a host-configuration
  concern, the same category as `gh`/`git`/`python3` being installed and
  authenticated, not something the packaged workflow enforces or asserts
  for that one nested call. None of this weakens the same "no override"
  requirement for the top-level `$pr-review`/`$pr-rereview`/`$pr-revise`
  invocation itself, which Kanban's own CLI spawn continues to pin per
  action as documented above.

  The Claude plugin's bundled coordinator
  (`claude-plugin/plugins/kanban/scripts/review_pr.py`) is a deliberate,
  reviewed exception to this one nested-call policy: unlike the Codex
  plugin's otherwise-identical coordinator copy, it pins and verifies that
  nested reviewer to the exact `gpt-5.6-terra`/`claude-opus-5` at `xhigh`
  values `codexModel`/`claudeModel`/`codexEffort`/`claudeEffort` already use
  for `PullRequestReview`/`PullRequestRereview`, and binds the verified
  model in the published `pr-review:v2` marker instead of `unspecified`.
  See [claude-plugin/README.md](../claude-plugin/README.md) for the
  rationale; this remains a host-configuration concern for the Codex
  plugin's own nested call.

### 2.3 Canonical issue review, rereview, and the solve readiness gate

- **Owning source:** `src/Kanban/Review.hs`.
- **Invocation:**
  - Interactive Codex-side review/revision sessions talk to
    `codex app-server --listen stdio://`.
  - Interactive Claude-side steps run the authenticated `claude` CLI
    directly.
  - GitHub reads and label/comment mutations for the interactive session go
    through `gh`, never a raw HTTP client.
  - Kanban's own synchronous invocation (`runCanonicalIssueReview` in
    `src/Kanban/Review.hs`) is a **publishing** action, run when the user
    presses `r`. It resolves the backend with `resolveCanonicalIssueReviewer`,
    which never hard-codes `~/work/approve-issues.py` and never reconstructs
    the installer's default: a non-empty `KANBAN_ISSUE_REVIEW_INSTALL_DIR`
    wins, then the backend path the installer recorded, then — only when the
    record names none — the directory that record lives in (see §3 and §5).
    It then runs
    `python3 <resolved path> --path <repository root> --review|--rereview
    <issue> --legacy-policy dual --json`. It writes the `issue-review:v2`
    comment and verdict labels; Kanban's own code never runs `--check`.
  - The solve readiness gate is a separate, **read-only** invocation that
    Kanban's Haskell code does not run itself. The solve prompt
    (`src/Kanban/Solve.hs:229`) explicitly forbids the spawned solving agent
    from running `--review`/`--rereview` against `approve-issues.py`, its
    `~/work/approve-issues.py` compatibility symlink, or the installed
    `tools/approve_issues.py` backend ("Kanban's `r` workflow owns that
    gate"), and instructs it to run only the same backend's `--check` with
    `--path <repository root> --check <issue> --legacy-policy dual --json`
    itself, via its own shell access, before claiming an issue
    (`tools/approve_issues.py --help`: "`--check ISSUE` Check one issue
    gate.").
- **Inputs:** issue number, review stage or gate check, repository root.
- **Outputs:** for `--review`/`--rereview`, an `issue-review:v2` comment
  with the verdict and updated `reviewed:*` labels; for `--check`, a
  structured JSON approval decision with no GitHub mutation.
- **Failure semantics:** `"Canonical issue reviewer was not found at
  <path>. Run \`python3 tools/install_issue_review.py\` from the Kanban
  checkout to install it."` if the resolved install location is absent;
  `"python3 was not found on PATH"`; a malformed response surfaces the
  backend's own error text.
- **Required authority:** the same GitHub write scope as PR review for
  `--review`/`--rereview` (`--check` performs no GitHub write); local read
  access to the canonical backend script.
- **Durable state:** none Kanban owns beyond the GitHub comment/labels; the
  backend may keep additional state outside Kanban's tracking.
- **Mandatory/optional:** optional at the Kanban-action level (the `r` key),
  but a solve session refuses to claim an issue that has not passed the
  read-only gate check.

### 2.4 Incident/controller capability — the PR drainer

- **Owning source:** `tools/drain_prs_service.py` (incident storage and
  lifecycle, plus the service loop) and `tools/install_drainer.py`
  (installer), surfaced read-only in-app by `src/Kanban/Drainer.hs`. The
  drainer (`tools/drain_prs.py`) records and resolves its own per-pull
  -request conflict incidents through that same storage.
- **Invocation:** `launchctl` (`bootstrap`/`bootout`/`kickstart`/`print`/
  `kill`) manages the LaunchAgent. The drainer's own PR-merge loop
  (`tools/drain_prs.py`) shells out to `git` and `gh` for every repository
  operation, and, only for automated stale-head rereview rounds, to
  `codex exec`. These Python-tool invocations sit
  outside the manifest in §4, which reconciles the solve/PR-flow/canonical
  -review Haskell surface; they are covered by `tools/test_pure_logic.py`,
  `tools/test_drain_prs_service.py`, and `tools/test_install_drainer.py`.
  `tools/drain_prs.py --pr <number>` is the same merge path driven for one
  named pull request instead of the queue: it applies the identical gates,
  guards, ordering and post-merge audit, reads and mutates only that pull
  request, and is covered by `tools/test_single_pr_drain.py`.
- **Inputs:** repository path and repository identity; the repository's drainer
  LaunchAgent plist under `~/Library/LaunchAgents`, which is a Kanban-owned
  convention (see §5), not a personal path. There is one such plist per
  canonical GitHub repository, named for the label
  `tools/drain_prs_service.py` derives from that repository's normalized
  identity. Kanban names none of them: it selects this repository's entry in
  the discovery record `tools/drain_prs_service.py` writes at
  `~/Library/Application Support/kanban/pr-drainer/config.json`, resolves the
  plist path from that entry, then reads `ProgramArguments` out of the plist
  itself, which stays authoritative for what launchd will actually run. Kanban
  passes its own repository identity as `--repo OWNER/NAME` alongside
  `--path`; the controller resolves the checkout's own remote and refuses any
  identity but that one, including another remote of the same checkout, so
  neither a `kanban --repo` nor a `kanban --config` override can select or
  create another repository's drainer, or act on this checkout's job while the
  dashboard reports a different repository. The installed plist carries the
  same `--repo` for its own `run` invocation, so a shared `remote_name` changed
  after installation stops that job rather than re-pointing it: it drains
  nothing and logs the refusal until `tools/install_drainer.py` is re-run.
- **Outputs:** merged PRs, a drain-state JSON file, and optional incident
  notifications. A `--pr` run additionally writes exactly one versioned JSON
  result document to stdout — the pull request, its outcome (`merged`,
  `no_action`, or `error`), whether it merged, a stable reason drawn from a
  fixed vocabulary, and a caller-displayable message — and exits `0` for a
  completed merge, `2` for no merge, and `1` for an error. Its human log lines
  go to stderr, never stdout. `docs/pr-drainer.md` documents the schema, the
  reason vocabulary, and the exit statuses.
- **Failure semantics:** an unresolved incident surfaces in Kanban's
  sidebar as `DrainerWarning`/`DrainerError` with the incident summary
  (`src/Kanban/Drainer.hs`); the service defines its own retry/backoff and
  incident rules independently of Kanban. Every incident is attributed to the
  normalized canonical repository rather than to the checkout that raised it,
  so any clone of that repository lists, acknowledges, and clears it — only
  *running* a drainer is exclusive per identity. Incidents come in three
  kinds. A crash incident says the drainer process died and is cleared per
  repository. A merge-conflict incident says a healthy drainer stopped
  merging one pull request; it carries that pull-request number and its
  conflicting paths, is unique per open (repository, pull request), changes
  no label on the pull request it names, and resolves itself once that pull
  request is mergeable again or closed, leaving every other incident open.
  A cleanup-pending incident says a merge landed but its post-merge
  obligations — closing the linked issues, removing the matching worktree,
  deleting the head branches, fast-forwarding the default branch — are still
  outstanding after a bounded number of poll cycles; it carries that
  pull-request number and the outstanding steps, is unique per open
  (repository, pull request), never asks the drainer to exit, and resolves
  itself once every step succeeds. Only the crash kind means the drainer is
  not running.
- **Required authority:** the same GitHub write scope, plus local launchd
  control for the signed-in user.
- **Durable state:** per canonical GitHub repository — a LaunchAgent plist
  under `~/Library/LaunchAgents`, named for the label
  `tools/drain_prs_service.py` derives from that repository's normalized
  identity; a runtime directory holding the status file and incidents at
  `~/Library/Application Support/kanban/pr-drainer/runtime/<slug>`; and a log
  directory holding the service and dated logs at
  `~/Library/Logs/kanban/pr-drainer/<slug>`. Shared across repositories — the
  discovery record at
  `~/Library/Application Support/kanban/pr-drainer/config.json`, whose
  `repositories` table carries one entry per installed repository naming that
  job's label, the plist's absolute path, the checkout it was installed for,
  and that repository's optional `config_path`, and which every path that
  writes a plist refreshes from those same values without disturbing another
  repository's entry — every read-modify-write of that document happens under
  an exclusive `flock` on a sibling lock file, because installs and starts for
  different repositories run concurrently and an unserialized merge would drop
  the entry a running repository is discovered through; the global `ntfy_url`
  beside it; and the installer-managed script directory at
  `~/Library/Application Support/kanban/pr-drainer`. Per checkout — a
  versioned drain-state JSON file, which records both the approved head each
  queued pull request was cleared at and the post-merge obligations a merged
  pull request still owes, and which migrates forward from the shapes earlier
  versions wrote; and a run lock held on `.git/drain_prs.lock` — which holds
  the holder's bare PID — and then on the `.git` directory, beside a
  `.git/drain_prs.lock.owner.json` sidecar recording whether that PID is the
  polling service or a single-PR run. One lock covers both modes, so whichever
  starts second fails immediately naming the holder rather than acting. A dry
  run locks the directory alone, since it writes nothing; holding the
  directory without the file is therefore what identifies it, atomically and
  at every instant. That lock is per checkout and remains a secondary guard:
  two clones of one repository resolve to one job identity, and the second
  install or start is refused on that basis, which the lock cannot see.
- **Mandatory/optional:** fully optional. The board's `d` key starts or
  stops it, and nothing in Kanban's build or normal startup path installs
  or runs it.

### 2.5 Workflow setup and the preflight/doctor path

- **Owning source:** `tools/setup_workflows.py` (opt-in installer) and
  `src/Kanban/Preflight.hs` (readiness probing), surfaced by
  `kanban --doctor` and, per action, by the board itself. Documented for
  users in [docs/workflow-setup.md](workflow-setup.md).
- **Invocation:**
  - Setup installs the canonical issue-review backend through the same
    `tools/install_issue_review.py` primitives described in §3, and each
    provider bundle through that provider's own documented mechanism
    (`codex plugin marketplace add` / `codex plugin add`,
    `claude plugin marketplace add` / `claude plugin install`). It runs no
    other external command.
  - Preflight resolves `codex`, `claude`, `gh`, and `python3` with
    `findExecutable`, then runs only status-only probes: `--version`,
    `codex login status`, `claude auth status`, `gh auth status`, and each
    provider's `plugin list --json`. It also stats the Kanban-managed
    backend install path resolved by `canonicalIssueReviewerPath`.
- **Inputs:** for setup, the selected components, `--scope`, the Kanban
  checkout, and the target repository for a project-scoped registration;
  for preflight, the repository the board is pointed at (provider plugin
  listings are resolved relative to it).
- **Outputs:** for setup, a plan (the default) or the performed
  installation, plus a non-zero exit whenever a component needs user
  action; for preflight, a per-dependency and per-action readiness report,
  and the remediation the board substitutes for a generic agent failure.
- **Failure semantics:** setup never replaces an ordinary user file, a
  symlink it does not recognize as its own, a marketplace registered from
  another checkout, or an installed-but-disabled bundle — each is reported
  as `refused`, preserved, and paired with its recovery step. Preflight
  blocks an action only on a definite local observation; a probe it cannot
  interpret is reported as unknown and never blocks. Its per-action
  dependency set is exact and follows what each action spawns: the
  canonical gate needs both installed backend files, `gh`, and the reviewer
  the backend itself invokes (the opposite brand from the issue's origin,
  or both when unmarked under the dual policy Kanban passes); a revision
  needs the Codex coordinator and, for a Claude-origin issue, the Claude
  CLI its `kanban_run_claude` amendment authoring uses; neither needs a
  packaged bundle, since both run their providers directly. Auto-solve
  needs both brands, since it reviews its own pull request with the
  opposite one, and so do `pr-revise` and `repair`: each runs on the PR's own
  brand and spawns the opposite one for its single nested canonical rereview
  (§2.2, §2.7), which is a direct provider call and therefore needs that
  brand's executable and sign-in but not its bundle.
- **Required authority:** setup needs write access to the user's own
  provider configuration and to the Kanban-namespaced install directory.
  Preflight needs none: it is read-only and non-interactive, never starts an
  agent session or a login flow, consumes no model quota, and mutates no
  filesystem, provider-configuration, LaunchAgent, or GitHub state.
- **Durable state:** whatever each provider's own installer records, plus
  the install directory described in §3. Setup owns no state of its own.
- **Mandatory/optional:** fully optional, and never run by Kanban's build or
  startup path. The PR drainer is deliberately outside both: it keeps its
  own dedicated installer and status flow (§2.4), and neither the setup
  command nor preflight installs, starts, or reports on it.

### 2.6 Provider executables, GitHub authentication, and host prerequisites

| Dependency | Mandatory | Why |
| --- | --- | --- |
| `codex`, `claude` | No | Only needed to exercise an AI action (solve, review, revise, repair). |
| `script` | No | Only needed to poll Claude's usage snapshot (`src/Kanban/Claude.hs`). |
| `gh`, signed in via `gh auth login` | Yes | The board's GitHub data and every write action depend on it. |
| `git` | Yes | Repository identity, worktree creation, and status. |
| `python3` | No | Only needed for the canonical issue-review backend and the Python tool suite. |
| `ps` | Yes | Kanban's own worker/job-liveness snapshot (`src/Kanban/Worker.hs`) runs it unconditionally. |
| `/usr/bin/plutil` | No | Only needed to read the drainer's LaunchAgent status. |
| GHC + Cabal | Build-time only | Not invoked by any runtime workflow. |

### 2.7 Pull-request repair (`$repair` / `/repair`)

- **Owning source:** `src/Kanban/PullRequestFlow.hs` for the invocation, and
  the packaged workflows themselves
  (`codex-plugin/plugins/kanban/skills/repair/SKILL.md`,
  `claude-plugin/plugins/kanban/commands/repair.md`) for the behavior. Kanban's
  own `r` spawns it by name since issue #127, so it is pinned by the Haskell
  name-parity sets in `tools/test_codex_plugin.py` and
  `tools/test_claude_plugin.py` alongside §2.1-§2.2's workflows. It is not a
  drafting workflow, and is not part of the declared drafting surface
  ([drafting-workflow-contract.md §2](drafting-workflow-contract.md#2-declared-assets)).
- **Invocation:** user-invoked as `$repair <pr>` / `/repair <pr>`, and spawned
  by Kanban's `r` key on a pull request that is in the Done column *and*
  reporting a problem status — a merge conflict, a failed check, or a blocking
  label under a red `blocking_severity` (`src/Kanban/Workflow.hs`
  `classifyPullRequest` and `pullRequestStatus`, both required). Autosolve's own
  internal pull-request sessions keep their label-derived review/revise
  progression and never spawn it. Because it works on the pull request's own
  code, it runs on the pull request's own origin brand — the same rule as
  `pr-revise` — and therefore hands the verdict off to the opposite brand's
  canonical reviewer rather than reviewing itself (no `--self-review`).
- **Inputs:** one positive pull request number, plus the repository and
  configuration context when the caller supplies it. The resolved repository
  scopes every `gh` call (`-R <owner/name>`) rather than being inferred from
  the local checkout, and both are forwarded to the bundled coordinator through
  its own `--repo` and `--config` options, so a fork checkout or a non-default
  config path repairs and rereviews the same repository the board displays. It
  scopes pull-request *metadata* only: the head branch's fetches and pushes go
  to the head repository instead, which is not the same repository for a
  cross-repository pull request.
- **Outputs:** at most one focused commit pushed to the pull request's own head
  branch, followed by exactly one canonical rereview when — and only when — the
  push is verified to have advanced the head past the SHA recorded before
  editing. The rereview publishes the `pr-review:v2` comment and switches the
  configured verdict labels; the workflow itself never sets one.
- **Failure semantics:** it addresses the highest-priority blocking cause in
  the same order and with the same breadth as `pullRequestStatus`
  (`src/Kanban/Workflow.hs`): merge conflict against the pull request's
  recorded `baseRefName`, then any failed check in the status-check rollup
  (required or not), then a blocking label whatever the check state. "Blocking
  label" means the configured `changes_requested_label` and `blocked_labels`
  resolved from the caller's configuration including its per-repository
  override — the same pair `hasProblemLabel` consults — not a fixed string, so
  a repository with non-default labels is not mistaken for having nothing to
  repair. A failure judged pre-existing on the base branch or flaky is
  reported and stops the run rather than being worked around; a blocking label
  is reported and referred to the user, never removed; a competing update to
  the remote head stops the run instead of overwriting it; and a push whose
  rereview the coordinator rejects (no prior canonical review marker, or a
  blocked issue gate) stops with that exact reason rather than being
  compensated for with a label. A cross-repository head is fail-closed: when
  `isCrossRepository` reports a head repository other than the resolved one,
  `headRefName` names no branch of the resolved repository, so the workflow
  fetches and pushes only against the recorded head repository. Writability is
  decided by the ordinary non-force push's own outcome, never by
  `maintainerCanModify` — that field reports whether the *base* repository's
  maintainers may modify the branch, which is neither necessary nor sufficient
  for the account running the workflow, so a fork owner repairing their own
  pull request is not turned away. A push rejected for lack of write access
  stops the run with nothing changed on the remote.
- **Required authority:** GitHub read on the pull request and write to push to
  its head branch **in the head repository** — which for a fork pull request is
  not the repository the board is pointed at. It never merges, never closes an
  issue or pull request, and never adds or removes a verdict label directly.
- **Durable state:** the worktree it selects by the pull request's exact head
  branch, confirmed to track the recorded head repository's ref rather than a
  same-named local branch — a `solve` worktree at that branch is reused, dirty
  or not, rather than duplicated — or, when no worktree is on that branch, a
  new one at
  `${WORKTREES_ROOT:-$HOME/worktrees}/<owner>/<repo>/pr-<n>-<slug>`. It never
  switches the repository's primary checkout.
- **Mandatory/optional:** optional — like every other AI action, it is only
  reached by selecting it, and preflight reports its readiness per pull-request
  origin (§2.5).

## 3. Migration boundary

Kanban owns the canonical issue-review backend, fully: its path convention,
CLI flags (`--path`, `--review`/`--rereview`/`--check`, `--legacy-policy
dual`, `--json`), its JSON/comment/label output contract, its role as the
sole source of truth for both the interactive review workflow and the solve
readiness gate, and — since the vendoring migration this section now
describes — its implementation and every runtime component its supported
commands need.

- **`tools/approve_issues.py`** is the tracked source of truth. A fresh
  checkout can run its `--self-test`, `--check`, `--review`, and `--rereview`
  paths directly, with no file beneath `~/work` or
  `~/.codex/skills/approve-issues/`. Its portable runtime locations —
  `~/Library/Application Support/kanban/issue-review/` (install links),
  `~/Library/Logs/kanban/issue-review/` (daily logs), and the incident
  circuit breaker beneath that install directory's `runtime/incidents/` — are
  a namespaced Kanban footprint, not personal state, and its optional
  crash/incident notification (`KANBAN_ISSUE_REVIEW_NTFY_URL`) is a
  documented non-fatal no-op when unset, matching §5.
- **`tools/install_issue_review.py`** installs a stable Kanban-managed link
  to that tracked backend under its install directory (default
  `~/Library/Application Support/kanban/issue-review`, selectable with
  `--install-dir` or `KANBAN_ISSUE_REVIEW_INSTALL_DIR`), records that link's
  absolute path in the discovery record described in §5, in the same
  dry-run-capable, idempotent, never-overwrite-an-ordinary-file manner as
  `tools/install_drainer.py` (§5). Ownership is established by identity, not
  location: each tracked asset carries a `kanban-managed-asset:issue-review/
  <file>` marker, and the installer re-points an existing symlink only when
  it resolves to a file carrying that marker, or when it is already broken
  (the state a moved or deleted checkout leaves behind, which holds no
  content to preserve). A link resolving to any other real file is
  preserved and refused, so an unknown installation is never silently
  replaced — a path-shape test alone could not tell one apart, since any
  `.../tools/approve_issues.py` satisfies it. `src/Kanban/Review.hs`
  resolves the backend from that stable link
  (`resolveCanonicalIssueReviewer`) and fails visibly, naming this
  installer, when it has not been installed yet; `src/Kanban/Preflight.hs`
  (§2.5) treats only that same marker-carrying link as installed, and
  requires both installed files (`approve_issues.py` imports
  `kanban_config.py`), so preflight and the installer can never disagree
  about whether an install path is occupied.
- **`~/work/approve-issues.py`** is now a purely optional **compatibility
  launcher** for pre-migration automation that still invokes it directly. It
  is not Kanban's source of truth and nothing in Kanban's own code resolves
  it. `tools/install_issue_review.py --migrate-legacy-launcher` replaces it
  with a symlink to the Kanban-managed link above, backing up and reporting
  the location of any pre-existing ordinary file there; without that opt-in
  flag, an ordinary file at this path is left untouched and refused, per §5.
  A symlink already resolving to that same tracked backend through another
  install directory, or one left broken by an install directory that went
  away, is re-pointed without the opt-in; a symlink resolving to any other
  real file is preserved and refused with or without it, since a link has no
  content to back up.
- **`~/.codex/skills/approve-issues/...`** is no longer a dependency of any
  Kanban-supported command. The backend's incident handling
  (`open_invalid_incident` in `tools/approve_issues.py`) is now
  self-contained and never shells out to it. It may still be used by
  separate, unpackaged Codex-side daemon tooling outside this repository's
  contract; Kanban does not track or depend on that tooling.

## 4. Dependency manifest

Machine-readable; parsed verbatim by `tools/test_agent_workflow_contract.py`,
which also reconciles this manifest against the tracked Codex plugin's own
bash surface (`codex-plugin/plugins/kanban/skills/*/SKILL.md`) and the
tracked Claude plugin's own bash surface
(`claude-plugin/plugins/kanban/commands/*.md`) in addition to the Haskell
invocation surface — a command a packaged workflow shells out to is as
undocumented-if-missing as one Kanban's own Haskell code spawns. Those two
globs include the seven drafting and canonical issue-review assets declared in
[drafting-workflow-contract.md §2](drafting-workflow-contract.md#2-declared-assets),
whose user-scoped paths are reconciled against the `personal-path` rows below
by a markdown counterpart of the Haskell home-relative-path check.
Columns: `id | kind | token | files | owner | status | mandatory`.

- `kind`: `executable` (a literal command Kanban's Haskell source or the
  tracked Codex or Claude plugin's packaged workflows spawn or resolve) or
  `personal-path` (a home-relative path Kanban's Haskell source builds or
  depends on).
- `token`: the exact literal string the check searches for.
- `files`: `;`-separated repository-relative paths where the token is
  expected to appear (empty when nothing in this repository references it).
- `owner`: `kanban` (Kanban owns this dependency's contract, whether or not
  its implementation is tracked in this repository yet) or `external` (a
  dependency Kanban consumes but does not define, e.g. a Codex-side skill
  package).
- `status`: `supported` or `migration-target`.
- `mandatory`: `yes` or `no`, matching §2.6 for executables.

```text
codex-cli | executable | codex | src/Kanban/Codex.hs;src/Kanban/Review.hs;src/Kanban/Solve.hs;src/Kanban/PullRequestFlow.hs;src/Kanban/Preflight.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;claude-plugin/plugins/kanban/scripts/review_pr.py | kanban | supported | no
claude-cli | executable | claude | src/Kanban/Claude.hs;src/Kanban/Review.hs;src/Kanban/Solve.hs;src/Kanban/PullRequestFlow.hs;src/Kanban/Preflight.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;claude-plugin/plugins/kanban/scripts/review_pr.py | kanban | supported | no
claude-script-wrapper | executable | script | src/Kanban/Claude.hs | kanban | supported | no
gh-cli | executable | gh | src/Kanban/GitHub.hs;src/Kanban/Review.hs;src/Kanban/Preflight.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;codex-plugin/plugins/kanban/skills/issue/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;claude-plugin/plugins/kanban/commands/issue.md;claude-plugin/plugins/kanban/commands/draft-issues.md;claude-plugin/plugins/kanban/commands/repair.md;claude-plugin/plugins/kanban/scripts/review_pr.py | kanban | supported | yes
git-cli | executable | git | src/Kanban/Repository.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;codex-plugin/plugins/kanban/skills/issue-review/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;claude-plugin/plugins/kanban/commands/pr-review.md;claude-plugin/plugins/kanban/commands/pr-rereview.md;claude-plugin/plugins/kanban/commands/pr-revise.md;claude-plugin/plugins/kanban/commands/issue-review.md;claude-plugin/plugins/kanban/commands/repair.md;claude-plugin/plugins/kanban/scripts/review_pr.py | kanban | supported | yes
python3-cli | executable | python3 | src/Kanban/Review.hs;src/Kanban/Preflight.hs;codex-plugin/plugins/kanban/skills/solve/SKILL.md;codex-plugin/plugins/kanban/skills/pr-review/SKILL.md;codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md;codex-plugin/plugins/kanban/skills/issue-review/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;claude-plugin/plugins/kanban/commands/pr-review.md;claude-plugin/plugins/kanban/commands/pr-rereview.md;claude-plugin/plugins/kanban/commands/pr-revise.md;claude-plugin/plugins/kanban/commands/issue-review.md;claude-plugin/plugins/kanban/commands/repair.md | kanban | supported | no
ps-cli | executable | ps | src/Kanban/Process.hs | kanban | supported | yes
plutil-cli | executable | /usr/bin/plutil | src/Kanban/Drainer.hs | kanban | supported | no
approve-issues-backend | personal-path | /Library/Application Support/kanban/issue-review | tools/kanban_config.py | kanban | supported | no
issue-review-discovery-record | personal-path | /Library/Application Support/kanban/issue-review/config.json | src/Kanban/Review.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;claude-plugin/plugins/kanban/scripts/review_pr.py;codex-plugin/plugins/kanban/skills/issue-review/SKILL.md;claude-plugin/plugins/kanban/commands/issue-review.md;codex-plugin/plugins/kanban/skills/solve/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md | kanban | supported | no
drainer-launchagent-label | personal-path | com.coghex.drain-prs | tools/drain_prs_service.py | kanban | supported | no
drainer-discovery-record | personal-path | /Library/Application Support/kanban/pr-drainer/config.json | tools/drain_prs_service.py;src/Kanban/Drainer.hs | kanban | supported | no
find-cli | executable | find | codex-plugin/plugins/kanban/skills/pr-review/SKILL.md;codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md | kanban | supported | no
head-cli | executable | head | codex-plugin/plugins/kanban/skills/pr-review/SKILL.md;codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md | kanban | supported | no
```

`drainer-launchagent-label`'s token is the shared prefix, which is all a single
token can be: an installed job's label appends the repository's own slug to it
(`com.coghex.drain-prs.coghex.kanban`), so there is one label per canonical
GitHub repository rather than one for the account. The bare prefix is also the
label of the machine-wide singleton that predates per-repository jobs, which
`tools/drain_prs_service.py` retires rather than installs.

`find-cli` and `head-cli` are `mandatory: no`: they are only needed to locate
the installed Codex plugin's shared review coordinator from `$pr-review`,
`$pr-rereview`, `$pr-revise`, and `$repair`, themselves optional AI actions,
and every supported macOS/Linux shell already provides both. The Claude
plugin's equivalent commands need neither: Claude Code exposes
`${CLAUDE_PLUGIN_ROOT}` inside a plugin's own commands, so `/pr-review`,
`/pr-rereview`, `/pr-revise`, and `/repair` resolve their bundled coordinator
directly at
`${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py` without a filesystem search, and
that plugin bundles its own copy of the coordinator so it never depends on
the Codex plugin being installed.

## 5. Portable-install policy

- **Project-scoped assets are preferred.** Where Kanban must write outside
  the repository at all, it prefers a small, clearly namespaced footprint:
  the drainer installer's default install directory is
  `~/Library/Application Support/kanban/pr-drainer`, and its LaunchAgent
  labels and plist paths are a Kanban-owned convention rather than a personal
  one. The component that writes the plists owns the labels:
  `tools/drain_prs_service.py` derives each one from its repository's
  normalized canonical GitHub identity — resolved through the remote the
  shared Kanban configuration names, the same one the dashboard resolves its
  own repository through — renders the plist from it, builds
  every `launchctl` target from it, partitions the runtime and log paths by
  the same identity, and — from those same values — records that job's label,
  the plist's absolute path, and the checkout it was installed for under that
  repository's entry in
  `~/Library/Application Support/kanban/pr-drainer/config.json`. The
  derivation is total, produces a valid nonempty label for every supported
  `owner/name`, and is injective across distinct normalized identities, so no
  two repositories can name one job. `tools/install_drainer.py` resolves a job
  through that module rather than restating any of it, and
  `src/Kanban/Drainer.hs` derives no label at all: it selects the entry for
  the identity it resolved and reads the label and plist path out of it.
  Haskell cannot import a Python constant, so a record one side writes and the
  other reads is the only coupling here that cannot drift. Its location stays
  fixed even when `--install-dir` moves everything
  else, since a dashboard that never inherits `KANBAN_DRAINER_INSTALL_DIR`
  still has to find it: that option relocates the script links and the runtime
  state, not this document. It is one document rather than two — the
  installer's global `ntfy_url` and each repository's `config_path` live in it
  beside the records, every writer merging rather than overwriting, at both
  levels, so installing one repository can never displace another's entry —
  and an installer run folds in any
  copy an earlier `--install-dir` install left beside its script links, which
  the controller keeps reading until then. A repository with no `config_path`
  of its own runs on the shared Kanban default; the single scalar the
  pre-per-repository installer wrote is deliberately not read as a fallback,
  because doing so would let a later installation silently change the
  configuration an earlier repository's drainer restarts with.
  `tools/install_issue_review.py` follows the same convention for the
  canonical issue-review backend, and resolves the same way. Its install
  directory defaults to `~/Library/Application Support/kanban/issue-review`,
  spelled once in `tools/kanban_config.py` — the only tracked module
  installed beside the backend, so the only one both the installer and the
  installed backend can import. Every successful install, from either
  `tools/install_issue_review.py` or `tools/setup_workflows.py --component
  issue-review --apply`, writes the linked backend's absolute path as
  `backend_path` into
  `~/Library/Application Support/kanban/issue-review/config.json`, after the
  links it names have been created and never during a dry run. That
  document's location is fixed even when `--install-dir` moves the
  installation, and it is merged rather than overwritten so the `config_path`
  reference the installer has always persisted there survives beside it.
  Resolution precedence, identical in `src/Kanban/Review.hs`,
  `src/Kanban/Preflight.hs`, both packaged `review_pr.py` coordinators, and
  the packaged Codex/Claude `issue-review` and `solve` workflows: a non-empty
  `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then a recorded `backend_path`, then —
  only when that field is absent, which is exactly how an installation
  predating the record reads — the directory holding the record. A selected
  override or recorded backend that is missing fails there rather than
  falling through to a lower-precedence location, since reviewing with an
  installation the user did not choose is worse than not reviewing; a record
  that will not parse, or whose `backend_path` is wrong-typed or relative,
  is its own failure naming that document.
- **User-scoped installation is explicit and opt-in.** Nothing in Kanban's
  build (`cabal build all`) or normal startup path installs the drainer's
  LaunchAgent or the issue-review backend's stable link; the latter is only
  installed by running `tools/install_issue_review.py`, or
  `tools/setup_workflows.py --component issue-review --apply`, directly,
  and neither starts a daemon.
- **The workflow-setup command is dry-run first and component-selected.**
  `tools/setup_workflows.py` (§2.5) inspects and prints its plan unless
  `--apply` is passed, requires an explicit `--component`/`--all`
  selection, defaults to project scope, and makes a user-global provider
  registration an explicit `--scope user` choice. It installs each provider
  bundle only through that provider's own documented mechanism, and it is
  not, and must not become, an installer for the PR drainer, an approval
  daemon, models, or credentials.
- **Installers must be dry-run capable, idempotent, and must never replace
  an ordinary user file.** `tools/install_drainer.py`'s `install_symlink`
  already meets this bar (see `tools/test_install_drainer.py`);
  `tools/install_issue_review.py` meets the same bar for both its stable
  link and the optional legacy-launcher migration described in §3 (see
  `tools/test_install_issue_review.py`).
- **No credential, personal model preference, private endpoint, or
  machine-specific path may be tracked as a required asset.**
  `DRAIN_PRS_CLAUDE_REVIEW_MODEL`, `KANBAN_DRAINER_NTFY_URL`,
  `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, and `KANBAN_ISSUE_REVIEW_NTFY_URL` are
  optional environment overrides with no tracked default value, not required
  configuration.

## 6. Completeness check

`tools/test_agent_workflow_contract.py` (discovered by
`python3 -m unittest discover -s tools -p 'test_*.py'`, which CI already
runs) parses the manifest in §4 and:

- fails if the solve, PR-flow, canonical-review, or shared provider/process
  source files (`src/Kanban/Solve.hs`, `PullRequestFlow.hs`, `Review.hs`,
  `Codex.hs`, `Claude.hs`, `GitHub.hs`, `Repository.hs`, `Drainer.hs`,
  `Process.hs`) invoke a literal external command that has no matching
  `executable` manifest entry;
- fails if any of the tracked Codex plugin's packaged `SKILL.md` files
  (`codex-plugin/plugins/kanban/skills/*/SKILL.md`) or the tracked Claude
  plugin's packaged `commands/*.md` files
  (`claude-plugin/plugins/kanban/commands/*.md`) invoke a command, inside a
  fenced ```` ```bash ```` block, that has no matching `executable` manifest
  entry;
- fails if either packaged plugin's own bundled coordinator
  (`codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py` or
  `claude-plugin/plugins/kanban/scripts/review_pr.py`) invokes a command, as
  the first element of a `run`/`subprocess.run` argument list, that has no
  matching `executable` manifest entry — the coordinator is Python, not
  bash, so it is reconciled with a separate extractor from the `.md` files
  above, not exempted from coverage;
- fails if those same files build a home-relative path segment that has no
  matching `personal-path` manifest entry;
- fails if any of the seven drafting and canonical issue-review assets
  declared in
  [drafting-workflow-contract.md §2](drafting-workflow-contract.md#2-declared-assets)
  names a `$HOME/`- or `~/`-prefixed path with no matching `personal-path`
  manifest entry. All seven are scanned for external commands too; the bash
  fence extractor simply yields nothing for a prose-only contract, so an asset
  with no executable surface is covered rather than exempted;
- fails if a manifest entry's declared `files` no longer contain its token,
  so the manifest cannot silently drift from the code it describes;
- fails if the issue-review backend entry (`approve-issues-backend`) is
  missing from the manifest or is not marked `kanban`-owned and `supported`,
  or if a `codex-approve-issues-skill` entry still exists, so the manifest
  cannot silently regress to the pre-migration boundary described in §3;
- fails if the drainer LaunchAgent plist is marked anything other than a
  `kanban`-owned `supported` path.
