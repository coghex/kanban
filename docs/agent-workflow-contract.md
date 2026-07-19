# Kanban agent-workflow contract

Contract version: 1

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

It also declares the boundary between what Kanban owns today and what is
still user-machine state pending a future migration (tracked separately;
this issue does not move or change `~/work/approve-issues.py`), and the
policy any future installer for that migration must follow.

A fresh checkout can use this document to answer: "why did action X fail,"
"what do I need to install before X works," and "is path Y something Kanban
manages or something I must set up myself."

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

### 2.3 Canonical issue review, rereview, and the solve readiness gate

- **Owning source:** `src/Kanban/Review.hs`.
- **Invocation:**
  - Interactive Codex-side review/revision sessions talk to
    `codex app-server --listen stdio://`.
  - Interactive Claude-side steps run the authenticated `claude` CLI
    directly.
  - GitHub reads and label/comment mutations for the interactive session go
    through `gh`, never a raw HTTP client.
  - Synchronous canonical publication, rereview, and the read-only gate
    check solve sessions must pass before claiming an issue all run:
    `python3 ~/work/approve-issues.py --path <repository root> [--review|--rereview] <issue> --legacy-policy dual --json`.
- **Inputs:** issue number, review stage, repository root.
- **Outputs:** an `issue-review:v2` comment with the verdict, updated
  `reviewed:*` labels, and, for the gate check, a structured JSON approval
  decision.
- **Failure semantics:** `"Canonical issue reviewer was not found at
  <path>"` if `~/work/approve-issues.py` is absent; `"python3 was not found
  on PATH"`; a malformed response surfaces the backend's own error text.
- **Required authority:** the same GitHub write scope as PR review; local
  read access to the canonical backend script.
- **Durable state:** none Kanban owns beyond the GitHub comment/labels; the
  backend may keep additional state outside Kanban's tracking.
- **Mandatory/optional:** optional at the Kanban-action level (the `r` key),
  but a solve session refuses to claim an issue that has not passed the gate
  check.

### 2.4 Incident/controller capability — the PR drainer

- **Owning source:** `tools/drain_prs_service.py` (service loop and
  incident lifecycle) and `tools/install_drainer.py` (installer), surfaced
  read-only in-app by `src/Kanban/Drainer.hs`.
- **Invocation:** `launchctl` (`bootstrap`/`bootout`/`kickstart`/`print`/
  `kill`) manages the LaunchAgent. The drainer's own PR-merge loop
  (`tools/drain_prs.py`) shells out to `git` and `gh` for every repository
  operation, and, only for automated stale-head rereview and conflict-repair
  rounds, to `codex exec` and `claude -p`. These Python-tool invocations sit
  outside the manifest in §4, which reconciles the solve/PR-flow/canonical
  -review Haskell surface; they are covered by `tools/test_pure_logic.py`,
  `tools/test_drain_prs_service.py`, and `tools/test_install_drainer.py`.
- **Inputs:** repository path; the drainer LaunchAgent plist at
  `~/Library/LaunchAgents/com.coghex.drain-prs.plist`, which is an
  installer-owned convention (see §5), not a personal path.
- **Outputs:** merged PRs, a drain-state JSON file, and optional incident
  notifications.
- **Failure semantics:** an unresolved incident surfaces in Kanban's
  sidebar as `DrainerWarning`/`DrainerError` with the incident summary
  (`src/Kanban/Drainer.hs`); the service defines its own retry/backoff and
  incident rules independently of Kanban.
- **Required authority:** the same GitHub write scope, plus local launchd
  control for the signed-in user.
- **Durable state:** `~/Library/LaunchAgents/com.coghex.drain-prs.plist`;
  the installer-managed script directory at
  `~/Library/Application Support/kanban/pr-drainer`; a drain-state JSON
  file.
- **Mandatory/optional:** fully optional. The board's `d` key starts or
  stops it, and nothing in Kanban's build or normal startup path installs
  or runs it.

### 2.5 Provider executables, GitHub authentication, and host prerequisites

| Dependency | Mandatory | Why |
| --- | --- | --- |
| `codex`, `claude` | No | Only needed to exercise an AI action (solve, review, revise). |
| `script` | No | Only needed to poll Claude's usage snapshot (`src/Kanban/Claude.hs`). |
| `gh`, signed in via `gh auth login` | Yes | The board's GitHub data and every write action depend on it. |
| `git` | Yes | Repository identity, worktree creation, and status. |
| `python3` | No | Only needed for the canonical issue-review backend and the Python tool suite. |
| `ps` | Yes | Kanban's own worker/job-liveness snapshot (`src/Kanban/Worker.hs`) runs it unconditionally. |
| `/usr/bin/plutil` | No | Only needed to read the drainer's LaunchAgent status. |
| GHC + Cabal | Build-time only | Not invoked by any runtime workflow. |

## 3. Migration boundary

Kanban owns:

- The canonical issue-review backend's *invocation contract* — its path
  convention, CLI flags (`--path`, `--review`/`--rereview`,
  `--legacy-policy dual`, `--json`), and its role as the sole source a solve
  session may read for the readiness gate.
- Any runtime component required for its own supported synchronous review
  path, i.e. the code in `src/Kanban/Review.hs` that shells out to it.

Kanban does not yet own, and this issue does not move or change:

- **`~/work/approve-issues.py`** — the canonical backend's implementation.
  Flagged as a **migration target**, not a supported installation
  requirement. A future migration (tracked separately, depends on this
  issue) must leave a compatibility symlink at `~/work/approve-issues.py` so
  existing installs keep working, but that path must stop being Kanban's
  source of truth.
- **`~/.codex/skills/approve-issues/...`** — the Codex-side skill packaging
  of the same review flow. Also flagged as a migration target. It is not
  present in this repository and nothing here installs it; it is named so a
  future migration knows to account for it.

## 4. Dependency manifest

Machine-readable; parsed verbatim by `tools/test_agent_workflow_contract.py`.
Columns: `id | kind | token | files | owner | status | mandatory`.

- `kind`: `executable` (a literal command Kanban's Haskell source spawns or
  resolves) or `personal-path` (a home-relative path Kanban's Haskell source
  builds or depends on).
- `token`: the exact literal string the check searches for.
- `files`: `;`-separated repository-relative paths where the token is
  expected to appear (empty when nothing in this repository references it).
- `owner`: `kanban` (a Kanban-defined convention) or `external` (state
  outside this repository's control).
- `status`: `supported` or `migration-target`.
- `mandatory`: `yes` or `no`, matching §2.5 for executables.

```text
codex-cli | executable | codex | src/Kanban/Codex.hs;src/Kanban/Review.hs | kanban | supported | no
claude-cli | executable | claude | src/Kanban/Claude.hs;src/Kanban/Review.hs | kanban | supported | no
claude-script-wrapper | executable | script | src/Kanban/Claude.hs | kanban | supported | no
gh-cli | executable | gh | src/Kanban/GitHub.hs;src/Kanban/Review.hs | kanban | supported | yes
git-cli | executable | git | src/Kanban/Repository.hs | kanban | supported | yes
python3-cli | executable | python3 | src/Kanban/Review.hs | kanban | supported | no
ps-cli | executable | ps | src/Kanban/Process.hs | kanban | supported | yes
plutil-cli | executable | /usr/bin/plutil | src/Kanban/Drainer.hs | kanban | supported | no
approve-issues-backend | personal-path | /work/approve-issues.py | src/Kanban/Review.hs | external | migration-target | no
codex-approve-issues-skill | personal-path | ~/.codex/skills/approve-issues | | external | migration-target | no
drainer-launchagent-plist | personal-path | com.coghex.drain-prs.plist | src/Kanban/Drainer.hs | kanban | supported | no
```

## 5. Portable-install policy

- **Project-scoped assets are preferred.** Where Kanban must write outside
  the repository at all, it prefers a small, clearly namespaced footprint:
  the drainer installer's default install directory is
  `~/Library/Application Support/kanban/pr-drainer`, and its LaunchAgent
  label (`com.coghex.drain-prs`) and plist path are a Kanban-owned
  convention defined once in `tools/install_drainer.py` and read the same
  way by `src/Kanban/Drainer.hs`.
- **User-scoped installation is explicit and opt-in.** Nothing in Kanban's
  build (`cabal build all`) or normal startup path installs the drainer's
  LaunchAgent; it is only installed by running `tools/install_drainer.py`
  directly.
- **Installers must be dry-run capable, idempotent, and must never replace
  an ordinary user file.** `tools/install_drainer.py`'s `install_symlink`
  already meets this bar (see `tools/test_install_drainer.py`); any future
  installer this contract comes to cover — including a §3 migration
  installer — must meet the same bar.
- **No credential, personal model preference, private endpoint, or
  machine-specific path may be tracked as a required asset.**
  `DRAIN_PRS_CLAUDE_REVIEW_MODEL` and `KANBAN_DRAINER_NTFY_URL` are optional
  environment overrides with no tracked default value, not required
  configuration. `~/work/approve-issues.py` and
  `~/.codex/skills/approve-issues/...` are named in §3 as migration targets
  specifically because they violate this policy today; they must not be
  treated as something a fresh checkout is expected to already have.

## 6. Completeness check

`tools/test_agent_workflow_contract.py` (discovered by
`python3 -m unittest discover -s tools -p 'test_*.py'`, which CI already
runs) parses the manifest in §4 and:

- fails if the solve, PR-flow, canonical-review, or shared provider/process
  source files (`src/Kanban/Solve.hs`, `PullRequestFlow.hs`, `Review.hs`,
  `Codex.hs`, `Claude.hs`, `GitHub.hs`, `Repository.hs`, `Drainer.hs`,
  `Process.hs`) invoke a literal external command that has no matching
  `executable` manifest entry;
- fails if those same files build a home-relative path segment that has no
  matching `personal-path` manifest entry;
- fails if a manifest entry's declared `files` no longer contain its token,
  so the manifest cannot silently drift from the code it describes;
- fails if `~/work/approve-issues.py` or
  `~/.codex/skills/approve-issues/...` are missing from the manifest or not
  marked `migration-target`;
- fails if the drainer LaunchAgent plist is marked anything other than a
  `kanban`-owned `supported` path.
