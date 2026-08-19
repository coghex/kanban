# Kanban agent-workflow contract

Contract version: 2

## 1. Purpose and scope

Kanban's board is fully usable without any AI provider. A smaller set of
explicit actions — issue solve, PR review/rereview/revise/repair, canonical
issue
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
- **Inputs:** issue number, solver brand, Kanban's resolved repository identity
  (`Kanban.Repository.resolveRepository`'s `owner/name`, whether it came from an
  explicit `--repo` or from the configured `remote_name`), the optional
  `--config` path, and an optional resumed session id with its follow-up user
  message.
- **Repository scope:** the resolved identity — not the worked checkout's own
  remote — scopes every GitHub issue and pull-request operation of the run:
  issue selection, the read-only canonical gate check and the vendored
  trusted-comment spec fetch (both by `--repo <owner>/<name>`), the issue claim
  and its release, the open-pull-request collision search, and pull-request
  creation (all by `-R <owner>/<name>`). `initialSolvePrompt` states it and
  `resumeSolvePrompt` restates it, so a session resumed after context
  truncation cannot silently fall back to checkout derivation for the
  operations it still owns. It also names the worktree directory,
  `${WORKTREES_ROOT:-$HOME/worktrees}/<owner>/<repo>/issue-<n>-<slug>` — the
  convention §2.7 records for repair — while `git worktree list` remains the
  sole collision and interrupted-work recovery source, so a worktree registered
  under an earlier path still resolves. As in §2.7 the identity scopes
  pull-request *metadata* only: the implementation branch still goes to the
  worked checkout's own push remote, and the worktree still branches from that
  checkout's `origin/<default-branch>`, which for a fork checkout is the fork's
  copy of the base branch rather than the resolved repository's. When those are
  different repositories the pull request is opened cross-repository — `-R
  <resolved owner/name>` with an owner-qualified `--head <push-owner>:<branch>`
  — against the resolved repository's branch of that same base name; a pull
  request GitHub cannot open that way (unrelated repositories, no fork
  relationship) stops the run with the pushed branch reported, never falling
  back to the push remote's repository. A run that cannot establish or preserve
  one identity stops before its first issue mutation — the claim — and reports,
  rather than re-deriving one from the checkout; that stop is distinct from the
  canonical-gate refusal, whose single-line `KANBAN_NEEDS_INPUT` spelling is
  fixed. A directly invoked workflow given no identity resolves one once from
  its own checkout and is bound by it for the rest of the run.
- **Comment trust boundary:** both tracked solve workflows
  (`codex-plugin/plugins/kanban/skills/solve/SKILL.md` and
  `claude-plugin/plugins/kanban/commands/solve.md`) fetch the issue's effective
  spec exclusively through their own bundle's vendored `trusted_issue_spec.py`
  (`codex-plugin/plugins/kanban/skills/solve/scripts/trusted_issue_spec.py`,
  `claude-plugin/plugins/kanban/scripts/trusted_issue_spec.py`). Each copy
  retrieves the complete paginated timeline in deterministic chronological
  order and serializes a comment body only for the exact, case-insensitive
  logins `claude`, `codex`, and `coghex`; every other comment is returned as
  metadata alone — id, author, timestamp, url — with no body and no
  body-derived content of any kind. Repository role, `author_association`,
  issue authorship, display name, bot status, and a lookalike login such as
  `codex-bot` or `coghex-helper` grant nothing, and the trusted set is
  hardcoded in the tracked helper so widening it costs a reviewed pull request.
  The workflows forbid `gh issue view`, the raw comments endpoint, GraphQL, and
  every other unfiltered source: only the helper's own internal fetch may read
  the untrusted bodies it drops. Each copy is a vendored self-contained asset
  per §3 — standard library only, no import from `tools/` — carries a
  standalone `--self-test`, and declares its `gh` surface in §4. The Codex
  skill locates its copy under `$CODEX_HOME` the way its PR-flow skills locate
  their coordinator; the Claude command resolves its own at
  `${CLAUDE_PLUGIN_ROOT}/scripts/trusted_issue_spec.py`. Neither resolves a
  checkout-relative or personal-skill path, because Kanban spawns the workflow
  with the worked repository as the working directory. The packaged
  `issue-rereview` assets
  ([drafting-workflow-contract.md §3.6](drafting-workflow-contract.md#36-the-repair-loop-issue-rereview-and-issue-rereview))
  read the timeline through the same two vendored copies, resolved the same
  two ways and under the identical no-unfiltered-fallback rule; they are the
  only other consumers, and they add no third copy.
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

That solve-agent trust boundary is deliberately narrower than, and independent
of, the reviewer gate's arithmetic in `tools/approve_issues.py`; the two answer
different questions and are not meant to converge.
`is_spec_relevant_comment` decides which comments a **published approval is
bound to**, so it counts a comment as spec-relevant when its
`author_association` is `OWNER`, `MEMBER`, or `COLLABORATOR` *or* when its
author is the issue's own reporter — including a reporter whose association is
`NONE`, the case that function's standalone self-test pins. That is the right
rule there: an unprivileged drive-by comment must not invalidate a published
approval merely by existing, while a reporter's own follow-up must re-open the
gate rather than be silently ignored. The helper answers a different question —
whose text may steer an agent that is about to write code — and there issue
authorship earns nothing. The two rules therefore cross: a reporter comment can
be inside the gate's fingerprint, changing the `spec` hash and forcing a fresh
review, while its body never reaches the solve agent. That outcome is intended.
The reviewer reads such a comment and either carries what matters into its own
`issue-review:v2` comment — authored by a trusted login, and so visible to the
solver — or it does not, and the solver proceeds from the body plus trusted
amendments alone. Nothing in the solve path may widen its own view to match the
gate's, and nothing in this boundary changes the gate's association-based
arithmetic, which §2.3 owns.

### 2.2 PR review, rereview, revise, and repair

- **Owning source:** `src/Kanban/PullRequestFlow.hs`.
- **Invocation:** resolves and spawns `codex` or `claude` the same way as
  solve, running the named canonical command: `pr-review` and `pr-rereview`
  always run on the opposite brand from the PR's origin marker; `pr-revise`
  and `repair` run on the PR's own origin brand and each internally invokes
  exactly one canonical `pr-rereview` after pushing a fix. `authoredOnOwnBrand`
  is the single predicate that decides which side of that split an action is
  on, and brand routing, model selection, and preflight all read it. Which of
  the four the `r` key selects is §7 of `docs/design.md`; `repair`'s own
  behavior is §2.7 below.
- **Who may self-review:** the bundled coordinator's `--self-review` skips the
  nested reviewer spawn and lets the calling session review directly, which is
  sound only when Kanban spawned that session as the opposite-brand reviewer —
  the `pr-review`/`pr-rereview` side of the split above. The coordinator cannot
  observe who invoked it, so the caller declares its own brand through
  `--self-review-as` and the coordinator refuses any single-reviewer route
  whose declaration is absent or is not the routed reviewer's brand, returning
  `self_review_refused` having published nothing and changed no label. This is
  the same rule §2.7 states for `repair` and `pr-revise`, which run on the
  pull request's own origin brand and therefore never pass the flag; stating it
  here as a checked precondition is what keeps a session that reached
  `pr-review` on its own pull request — an auto-solve loop reviewing the PR it
  just opened — from reviewing its own work under the opposite brand's name.
  An unknown or external origin routes to both brands, where `--self-review`
  stays non-operative as it always has rather than being refused.
- **Inputs:** PR number, PR origin marker, action
  (`PullRequestReview` | `PullRequestRereview` | `PullRequestRevision` |
  `PullRequestRepair`),
  optional resumed session/user message.
- **Outputs:** a session log; the canonical workflow itself publishes the
  `reviewed:*` label and review comment, and an approval marks a draft PR ready
  for review so it enters Done without waiting for CI — Kanban never sets a
  verdict label or changes draft state directly.
- **Failure semantics:** the same missing-executable and
  `KANBAN_NEEDS_INPUT` handoff pattern as solve.
- **Required authority:** GitHub write on the PR (labels, comments, draft
  readiness, pushes). No action in this surface ever merges a PR.
- **Durable state:** session log; the isolated worktree `pr-revise` works in,
  and the head-branch worktree `repair` selects or creates (§2.7).
- **Mandatory/optional:** optional — only exercised by the `r` key.
- **Cross-brand handoff model policy:** for known-origin `$pr-review`/
  `$pr-rereview` — the case Kanban's own invocation always produces, since
  every Kanban-created PR carries a `pr-origin` marker — the session Kanban
  spawns already *is* the correctly-pinned canonical reviewer (Kanban chose
  its brand via `agentForAction` and its model/effort via `codexModel`/
  `codexEffort`/`claudeModel`/`claudeEffort` before invoking it). A packaged
  workflow implementing this action must have that already-correct session
  perform the review itself and use its bundled coordinator only to publish
  the result safely (gate/head/race checks, comment, label, and approval-only
  draft readiness) — not spawn a
  further, unpinned nested reviewer that would both waste and be unable to
  verify Kanban's guarantee.
  `pr-revise` and `repair` are the genuine exceptions: each runs on the PR's
  own origin brand, so its internal "invoke exactly one canonical
  `pr-rereview`" step
  must spawn the *opposite* brand from inside that session — a nested
  invocation no top-level Kanban CLI spawn is present to configure, and the
  only cases (along with the dual-review fallback for unknown/external
  origin, which Kanban's own invocation never triggers) where "keep model
  selection with Kanban's invoking code and canonical workflow policy" means
  brand selection only (which of `codex`/`claude` runs), not a specific
  pinned or verified model/effort: which model backs a `codex`/`claude`
  install for canonical review purposes is then a host-configuration
  concern, the same category as `gh`/`git`/`python3` being installed and
  authenticated, not something the packaged workflow enforces or asserts
  for that one nested call. None of this weakens the same "no override"
  requirement for the top-level
  `$pr-review`/`$pr-rereview`/`$pr-revise`/`$repair`
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

- **Owning source:** `src/Kanban/Review.hs` and the focused modules behind
  it — `src/Kanban/Review/Canonical.hs` (backend resolution and invocation),
  `src/Kanban/Review/Tools.hs` (the `gh` and `claude` tool runners), and
  `src/Kanban/Review/Prompts.hs` (the developer instructions and tool schemas).
- **Invocation:**
  - Interactive Codex-side review/revision sessions talk to
    `codex app-server --listen stdio://`.
  - Interactive Claude-side steps run the authenticated `claude` CLI
    directly.
  - GitHub reads and label/comment mutations for the interactive session go
    through `gh`, never a raw HTTP client.
  - Kanban's own synchronous invocation (`runCanonicalIssueReview` in
    `src/Kanban/Review/Canonical.hs`) is a **publishing** action, run when the user
    presses `r`. It resolves the backend with `resolveCanonicalIssueReviewer`,
    which never hard-codes `~/work/approve-issues.py` and never reconstructs
    the installer's default: a non-empty `KANBAN_ISSUE_REVIEW_INSTALL_DIR`
    wins, then the backend path the installer recorded, then — only when the
    record names none — the directory that record lives in (see §3 and §5).
    It then runs the single-issue form
    `python3 <resolved path> --path <repository root> --review|--rereview
    <issue> --legacy-policy dual --json`. It writes the `issue-review:v2`
    comment and verdict labels; Kanban's own code never runs `--check`.
  - The backend's manual `--review` form also accepts two or more issue
    numbers. It processes that explicit list from left to right under one
    approval lock, stops normally at the first `CHANGES_REQUESTED` verdict,
    and never starts the remaining numbers. A model failure, invalid verdict,
    incident, or indeterminate non-approval is terminal rather than permission
    to cross the affected issue. One issue retains the original result shape;
    a batch returns ordered per-issue results plus the processed, remaining,
    and stopped-at issue numbers.
  - The backend's `--review-queue` form advances the live open backlog by one
    issue per invocation. It is mutually exclusive with `--check`, `--review`,
    and `--rereview`, shares their single mutual-exclusion diagnostic, and
    **requires `--json`**; without it the command exits non-zero with a usage
    error before any GitHub call, so no log line can share stdout with the
    result document. It is mutually exclusive with `--self-test` as well —
    that mode returns early and exits zero, which would both bypass the
    `--json` refusal and put non-JSON text on the stdout a controller parses;
    the other three modes' handling of `--self-test` is unchanged. Every
    combination is resolved before the repository context, so a refusal costs
    no GitHub call and writes nothing to stdout. It considers open issues in ascending **issue number**
    (not the legacy daemon's `(createdAt, number)`), over an inventory it has
    proven complete, skips an issue whose complete canonical gate is already
    approved, and stops at the first issue holding a current
    `CHANGES_REQUESTED` verdict — whether that verdict predated the invocation
    or was published by it. No higher-numbered issue is read or reviewed past
    that barrier. At most one issue receives model work per invocation, and it
    is re-read from GitHub and reclassified afterwards rather than trusted from
    the in-process result. Every `issue-review:v2` publication detail is the
    single-issue path's; this mode adds ordering, bounded scope, and a result
    document.
  - The solve readiness gate is a separate, **read-only** invocation that
    Kanban's Haskell code does not run itself. The solve prompt
    (`src/Kanban/Solve.hs:251`) explicitly forbids the spawned solving agent
    from running `--review`/`--rereview` against `approve-issues.py`, its
    `~/work/approve-issues.py` compatibility symlink, or the installed
    `tools/approve_issues.py` backend ("Kanban's `r` workflow owns that
    gate"), and instructs it to run only the same backend's `--check` with
    `--path <repository root> --check <issue> --legacy-policy dual --json`
    itself, via its own shell access, before claiming an issue
    (`tools/approve_issues.py --help`: "`--check ISSUE` Check one issue
    gate.").
- **Inputs:** issue number or explicit ordered initial-review list, review stage
  or gate check, repository root. `--review-queue` takes no issue number: the
  live backlog is its input.
- **Outputs:** for `--review`/`--rereview`, an `issue-review:v2` comment
  with the verdict and updated `reviewed:*` labels; a multi-issue `--review`
  additionally returns one ordered batch JSON result; for `--check`, a
  structured JSON approval decision with no GitHub mutation. `--review-queue`
  writes exactly one bounded JSON document to stdout, versioned the way
  `tools/drain_prs.py` versions its single-PR result, carrying exactly the
  fields `schema` (`"approve-issues-review-queue"`), `version` (`1`),
  `outcome`, `issue`, `model_called`, and `message` (a non-empty
  caller-displayable string):

  | `outcome` | `issue` | meaning |
  | --- | --- | --- |
  | `idle` | `null` | no open issue needs review and no barrier was found |
  | `advanced` | issue number | that issue was reviewed and a re-read confirmed it holds a current approval |
  | `changes_requested` | issue number | the pass stopped at that ordered barrier |
  | `retry` | issue number | the specification changed during review, so no verdict was published |
  | `busy` | `null` | the canonical lock was held by another owner; `message` names it as `describe_lock_owner` does |

  All five are ordinary completions and **exit zero**; a `busy` invocation
  makes no GitHub mutation. The document is validated before it is printed —
  an unknown schema or version, a missing or additional field, a mistyped or
  Boolean-as-integer value, an issue number on `idle`/`busy`, a non-positive
  one on the other three, an `advanced` without a confirmed current approval,
  or a `model_called` claim disagreeing with whether a model actually ran are
  all refused rather than emitted.
- **Failure semantics:** `"Canonical issue reviewer was not found at
  <path>. Run \`python3 tools/install_issue_review.py\` from the Kanban
  checkout to install it."` if the resolved install location is absent;
  `"python3 was not found on PATH"`; a malformed response surfaces the
  backend's own error text. For `--review-queue`, an `INVALID` latest marker
  (whatever its fingerprint), a repository-wide **or** reached issue-scoped
  pipeline incident, a GitHub or model failure, an inventory it cannot prove
  complete, and any indeterminate post-review state are failures: a non-zero
  exit with diagnostics on stderr and **no** document on stdout that a caller
  could read as `idle`, `advanced`, `retry`, or `busy`. An interruption is a
  failure for this mode wherever in the run it lands — loading configuration,
  resolving the repository, the pass itself, or writing the document — unlike
  the daemon's deliberate zero-exit Ctrl-C: an aborted pass is none of the
  five outcomes, and a controller would otherwise read the silence as success.
  The document itself is written in a single call, so a caller never reads a
  truncated one.
- **Required authority:** the same GitHub write scope as PR review for
  `--review`/`--rereview` and for the one issue `--review-queue` reviews
  (`--check` performs no GitHub write); local read
  access to the canonical backend script.
- **Durable state:** none Kanban owns beyond the GitHub comment/labels; the
  backend may keep additional state outside Kanban's tracking.
  `--review-queue` takes the canonical `approve_issues.lock` for the one
  issue it reviews and releases it before the process exits on every outcome,
  failures included. That lock lives in the repository's *shared* Git
  directory — `.git/` in an ordinary checkout, and the primary checkout's
  `.git/` for a linked worktree, whose own `.git` is a file — so every
  checkout of one repository contends for it rather than each taking its own. It never holds that lock across issues, and never takes
  it at all for a pass that turns out to be idle or barriered.
- **Mandatory/optional:** optional at the Kanban-action level (the `r` key),
  but a solve session refuses to claim an issue that has not passed the
  read-only gate check.

### 2.4 Incident/controller capability — the PR drainer

- **Owning source:** `tools/drain_prs_service.py` (incident storage and
  lifecycle, plus the service loop), `tools/service_manager.py` (the one
  service-manager boundary both of the others reach their host's manager
  through), and
  `tools/install_drainer.py` (installer), surfaced in-app by
  `src/Kanban/Drainer.hs`. The
  drainer (`tools/drain_prs.py`) records and resolves its own per-pull
  -request conflict incidents through that same storage. Kanban's in-app
  surface is read-only for everything the *service* owns — status, incidents,
  logs — and adds exactly two mutations: starting or stopping the installed job
  through the controller, and running `tools/drain_prs.py --pr` once for one
  selected pull request. It owns neither merge policy nor cleanup; every gate,
  the merge, and the post-merge obligations stay with `tools/drain_prs.py`.
- **Backend selection:** `tools/service_manager.select_backend` decides which
  service manager a host's drainer is managed by, and it is the only place
  that decides. It selects launchd on a macOS host that has `launchctl`,
  systemd on a host whose `systemctl --user` reaches a live user manager, and
  refuses a host that is neither with a message naming that condition rather
  than naming macOS. The order makes an ambiguous host — a macOS machine that
  also has `systemctl` installed — resolve the same way every time, and the
  probe answers before anything is written, so a host that cannot be managed
  never gets a half-installed drainer. The refusal is the installer's only
  platform refusal: `tools/install_drainer.py` does not consult `sys.platform`
  at all. Every backend implements the whole
  `ServiceManagerBackend` interface — naming, definition rendering and
  writing, load, uninstall, liveness, kick, stop, and the legacy-singleton
  operations — so a caller can never need one verb the seam does not expose.
  The systemd backend reports no legacy singleton, because the machine-wide
  job that per-repository jobs replaced only ever existed under launchd.
- **Invocation:** `launchctl` (`bootstrap`/`bootout`/`kickstart`/`print`/
  `kill`) manages the LaunchAgent on macOS, and `systemctl --user`
  (`daemon-reload`/`reset-failed`/`start`/`stop`/`show`) manages the user unit
  on Linux. Both are spawned only by `tools/service_manager.py`
  — the controller and the installer both reach their host's manager through
  that backend, and neither builds a `launchctl` or `systemctl` argument
  vector, reads either one's output, or writes or parses a plist or a unit
  file. The drainer's own PR-merge loop
  (`tools/drain_prs.py`) shells out to `git` and `gh` for every repository
  operation, and, only for automated stale-head rereview rounds, to
  `codex exec`. Every executable these Python tools spawn is declared in the
  §4 manifest and reconciled against it the same way the Haskell and
  packaged-workflow surfaces are: every non-test module under `tools/` is a
  scanned surface, so `launchctl` and `systemctl` each carry both a manifest
  row and a §2.6
  host-prerequisite entry. That surface is executable-only. The home-relative
  paths these modules build are neither asserted nor scanned from here: some
  have `personal-path` rows (the drainer's install directory, its discovery
  record, its log root, its LaunchAgent label), others deliberately have none
  yet (`~/Library/LaunchAgents`, `~/.config/systemd/user`, the legacy
  `~/work/approve-issues.py` launcher), and reconciling them is #146's work,
  not this surface's. Their behavior stays covered by
  `tools/test_pure_logic.py`, `tools/test_drain_prs_service.py`,
  `tools/test_service_manager.py`, and `tools/test_install_drainer.py`.
  `tools/drain_prs.py --pr <number>` is the same merge path driven for one
  named pull request instead of the queue: it applies the identical gates,
  guards, ordering and post-merge audit, reads and mutates only that pull
  request, and is covered by `tools/test_single_pr_drain.py`.
  `src/Kanban/Drainer.hs` spawns that entry point directly, as
  `python3 <install dir>/drain_prs.py --path <root> --repo OWNER/NAME --pr
  <number> [--config <path>]`, for the board's `m` key. The script is resolved
  from the Kanban-managed install directory — `KANBAN_DRAINER_INSTALL_DIR`,
  then the directory the discovered service definition runs its controller
  from, then
  the directory holding the discovery record — rather than from the repository
  checkout, so an install made with `--install-dir` stays usable by a dashboard
  that inherits none of the installer's environment. A source that is present
  but names no resolvable directory — a relative override, or a definition
  that does not run its controller from an absolute path — fails there rather
  than falling through to the next source, since falling through would merge
  with a different installation than the one configured and say nothing. A
  missing installation is reported with a remediation naming
  `tools/install_drainer.py` and the directory actually consulted, never as a
  failed merge. The result that run writes is accepted only after it is
  established to be this contract's document for the pull request that was
  asked about — schema, a version Kanban reads, the selected number, a known
  outcome, and no contradiction between the outcome, the merge flag, and the
  dry-run flag — since resolving a path means whatever is installed there
  answers, and a claimed merge is both shown to the user and acted on.
- **Inputs:** repository path and repository identity; the repository's own
  service definition — a LaunchAgent plist under `~/Library/LaunchAgents` on
  macOS, a unit file under `~/.config/systemd/user` on Linux — each of which is
  a Kanban-owned convention (see §5), not a personal path. There is one such
  definition per
  canonical GitHub repository, named for the identifier
  `tools/service_manager.py` derives from that repository's normalized
  identity. Kanban names none of them: it selects this repository's entry in
  the discovery record `tools/drain_prs_service.py` writes — at that module's
  own resolved location, which is `~/Library/Application Support/kanban/pr-drainer/config.json`
  on macOS and the XDG one on Linux (§5) — resolves the
  definition's path from that entry, then reads the command out of the
  definition itself — `ProgramArguments` from the plist through
  `/usr/bin/plutil`, `ExecStart` from the unit file read directly — which stays
  authoritative for what the service manager will actually run. Which location
  that is, is the controller's answer and not yet the dashboard's:
  `src/Kanban/Drainer.hs` still spells the macOS one itself, so until PATH-3
  gives it the same resolver a Linux host discovers an XDG-installed drainer
  from the Python side and not from the board. That window is deliberate and
  bounded — `docs/managed_paths_design.md` accepts it — rather than a
  disagreement about where the record is. That entry is a
  discriminated union: it names the `backend` that wrote it, and carries that
  backend's own `launchd_label`/`plist_path` or `systemd_unit`/`unit_path`.
  An entry naming no backend at all is the shape written before that field
  existed, which makes it launchd's and is why a macOS drainer installed before
  this survives with no reinstall and no manual edit; an unknown backend name,
  an entry mixing one backend's keys with the other's, and an entry naming a
  backend without its identifier or an absolute definition path all fail closed
  with reinstall guidance rather than being resolved as launchd. So does a
  record describing the manager the reading host does not have, which is a
  record that travelled between hosts rather than an install. Kanban
  passes its own repository identity as `--repo OWNER/NAME` alongside
  `--path`; the controller resolves the checkout's own remote and refuses any
  identity but that one, including another remote of the same checkout, so
  neither a `kanban --repo` nor a `kanban --config` override can select or
  create another repository's drainer, or act on this checkout's job while the
  dashboard reports a different repository. The installed definition carries
  the
  same `--repo` for its own `run` invocation, so a shared `remote_name` changed
  after installation stops that job rather than re-pointing it: it drains
  nothing and logs the refusal until `tools/install_drainer.py` is re-run.
  A `--pr` run takes the same three inputs — the dashboard's resolved checkout
  as `--path`, its identity as `--repo OWNER/NAME`, and the active absolute
  `--config` when one is set — plus the pull-request number. It resolves the
  checkout's own remote and refuses any other identity before reading the pull
  request, for the same reason the controller does: a pull-request number does
  not survive a disagreement about which repository is meant.
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
  incident rules independently of Kanban. A `--pr` run Kanban started reports
  only into that action's own notice, never into the sidebar's drainer status,
  which describes the service this ran instead of. Its declined-reason text is
  presented as the run wrote it rather than replaced by a generic message, and
  a run whose merge landed before it failed is reported as merged *and* as
  unfinished, because the post-merge obligations follow an irreversible merge.
  Kanban invokes it only when the service is known stopped with no open
  incident, and only one such run may be in flight per dashboard; the drainer's
  own per-repository run lock is the cross-process guard behind that, reported
  as the `run_locked` reason. Every incident is attributed to the
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
- **Required authority:** the same GitHub write scope, plus local control of
  the signed-in user's own service manager — launchd's GUI domain on macOS,
  that user's systemd manager on Linux. Neither requires root, and neither
  backend installs anything system-wide.
- **Durable state:** per canonical GitHub repository — one service definition,
  a LaunchAgent plist under `~/Library/LaunchAgents` or a unit file under
  `~/.config/systemd/user`, named for the identifier
  `tools/service_manager.py` derives from that repository's normalized
  identity; a runtime directory holding the status file and incidents at
  `<install-dir>/runtime/<slug>`; and a log
  directory holding the service and dated logs at
  `<log-root>/<slug>`. Shared across repositories — the
  discovery record at `<record-dir>/config.json`, whose
  `repositories` table carries one entry per installed repository naming the
  backend that wrote it, that job's identifier, the definition's absolute path,
  the checkout it was installed for,
  and that repository's optional `config_path`, and which every path that
  writes a definition refreshes from those same values without disturbing
  another
  repository's entry — every read-modify-write of that document happens under
  an exclusive `flock` on a sibling lock file, and installing a job holds that
  same lock across the whole of it: the definition write, the record write, and
  the manager load are one critical section rather than three, so two installs
  cannot interleave into a job the record names from one run and the disk
  describes from another. Mutual exclusion, not a transaction — nothing is
  rolled back, and a step that fails fails where it stands. That span is every
  transition that writes into an installation, from its first write rather than
  from the record edit it ends with: an install covers `ensure_dirs`, retiring
  the machine-wide singleton and the definition write; a start covers its own
  gates and reaches on across its kick, since the instant between installing a
  job and kicking it is one in which the job is installed and not yet running;
  an uninstall covers the definition removal as well as the record edit; an
  incident acknowledgement covers its single atomic rewrite; and the
  service-manager `run` path takes it for its startup check alone. A gate
  evaluated outside the lock is one that can be true when it is read and false
  when it is acted on, so none of them are. The stabilization wait a start
  performs after its kick is outside it, so the lock is never held against the
  process it is waiting for.

  Each of those transitions — install, start, uninstall, run, stop, and
  incident acknowledgement, which is every one that writes into an
  installation — asks first whether the installation is still the one this
  process is bound to, and refuses if it is not. Managed paths are
  resolved once, when a component starts, and a controller cannot re-derive
  them for its own use — so a process that is running when a later run moves or
  removes an installation would otherwise rebuild exactly what that run took
  away, and leave its repository's job naming a controller that no longer
  exists. Two signals answer it, in order: a relocation marker, a JSON document
  named by a shared constant that a mover leaves in the directory it takes
  apart, naming where the installation went — looked for in the bound install
  directory *and* in the bound discovery record's directory, because
  `--install-dir` makes those two different places — and, for the case no
  marker survives, whether the bound record or install directory is still the
  one this host resolves. Reading the marker is total: absent, unreadable, not
  an object, or naming no destination is not a relocation. The `run` path
  refuses by printing rather than logging, because logging creates the
  directories it logs into.

  A running controller also holds an exclusive lock on `controller.lock` inside
  its own runtime directory, taken inside that same startup span — while the
  record's lock is held no mover can be running, so the gate's answer is still
  true when this is taken, and from then on a mover fences on it and refuses
  instead. It is held for the process's whole life and never unlinked once
  created, on the same terms as the record's own lock. It is deliberately not
  the drainer's run lock: `drain_prs.py` takes the checkout's `.git` rendezvous
  non-blockingly and the controller supervises a child that does exactly that,
  so a controller holding the drainer's lock would make every run it supervises
  fail immediately. Two objects, both held at once. Any run that moves or
  removes an installation fences on both.

  Which lock a transition needs follows from how long it lives. A bounded one
  holds the record's lock across its gate and its writes together, because a
  mover holds that same lock for its whole transition and is thereby excluded.
  One that outlives any lock it could hold takes the controller lock as well.
  A stop is both at once and is the awkward case: signalling the runner is what
  makes the runner release *its* controller lock, so from that instant nothing
  fences a mover out — and everything a stop does afterwards, resolving that
  repository's crash incidents above all, is a write. So a stop re-takes the
  record's lock once the runner is gone, re-asks the gate, and takes the
  controller lock itself for the writes that follow. The lock is re-entrant
  within a thread so that span can contain the record write that would
  otherwise block against it, and leaving a nested acquisition releases
  nothing — only the outermost holder does, so another process stays blocked
  until the transition really ends. It is needed at all because installs and
  starts for
  different repositories run concurrently and an unserialized merge would drop
  the entry a running repository is discovered through; the global `ntfy_url`
  beside it; and the installer-managed script directory `<install-dir>`, which
  is `<record-dir>` itself unless an override moved it.

  `<record-dir>` and `<log-root>` are this platform's own conventions,
  resolved for every Python component by `tools/kanban_config.py` — the
  dashboard's own resolver has not joined them yet, which is the bounded
  window §4's input contract describes above — and declared as
  `personal-path` rows in §4: on macOS
  `~/Library/Application Support/kanban/pr-drainer` and
  `~/Library/Logs/kanban/pr-drainer`, and on Linux `$XDG_DATA_HOME` and
  `$XDG_STATE_HOME`'s `kanban/pr-drainer` — `~/.local/share` and
  `~/.local/state` when the variable is unset, empty, or not absolute.
  Discovery probes the XDG location first and the `~/Library` location second
  on both platforms and takes the first whose record exists, so an installation
  that already exists never has to move; only when neither is occupied is the
  answer this platform's write path. `<install-dir>` is a third name only
  because `--install-dir` and `KANBAN_DRAINER_INSTALL_DIR` exist: they relocate
  the script directory and the runtime root beneath it, and move neither the
  discovery record nor the log root. With no override in play `<install-dir>`
  *is* `<record-dir>`, which is why the record is a fixed location a dashboard
  that inherits no environment can still find, while the scripts beside it are
  not.
  Per checkout — a
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
  Uninstalling is repository-scoped and goes through the same seam:
  `drain_prs_service.py uninstall` refuses while the drainer is running, then
  unloads the stopped job, deletes its definition, and removes that one entry
  from the discovery record — leaving every sibling repository's entry, the
  global `ntfy_url`, the shared script links, and this repository's own runtime
  state, logs, and open incidents exactly as they were, since an uninstall is
  not an acknowledgement.
- **Mandatory/optional:** fully optional. The board's `d` key starts or
  stops it and its `m` key runs one `--pr` merge, and nothing in Kanban's
  build or normal startup path installs or runs it. With nothing installed,
  both keys report the installer rather than failing opaquely. A host with no
  supported service manager cannot install one at all, and says so.

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
    `claude plugin marketplace add` / `claude plugin install`). Refreshing an
    installed Codex bundle is that same mechanism and nothing else:
    `codex plugin remove kanban@kanban` followed by
    `codex plugin add kanban@kanban`, in that order, because the Codex CLI has
    no plugin update command for a local-source marketplace. Setup never
    writes into or deletes from a provider's own cache directly. Its only
    other external command is a read-only `git` — `ls-files` and
    `check-ignore` against the checkout — to establish what the tracked
    bundle is.
  - Setup additionally inspects the *content* the Codex provider installed,
    not only its `plugin list --json` registration. Codex installs
    `kanban@kanban` by copying the tracked bundle into
    `$CODEX_HOME/plugins/cache/kanban/kanban/<version>` — `~/.codex` when
    `CODEX_HOME` is empty or unset, and `<version>` as declared by
    `codex-plugin/plugins/kanban/.codex-plugin/plugin.json`, never whichever
    version happens to be cached. The tracked bundle is defined by the
    Git-tracked content under `codex-plugin/plugins/kanban`; an installed
    bundle that is missing a tracked path, holds a byte-different copy of
    one, or carries a path the tracked bundle does not define, is reported as
    `repair` with those bundle-relative paths grouped as missing, different,
    and extra. A path there is a directory as well as a file — a directory
    holding no file at all is still installed content, and a file-only
    inventory would read a left-behind or emptied skill directory as
    convergence — reported with a trailing slash, at the root of a nested
    run, and only when no extra file beneath it already names it. The
    checkout's own ignore rules apply to both sides, so an
    interpreter artefact such as `__pycache__/` is never divergence in either
    direction — counting one would plan a repair that could not converge. The
    `claude-plugin` component has no counterpart state: its marketplace
    serves the tracked bundle live from the repository directory.
  - Preflight resolves `codex`, `claude`, `gh`, and `python3` with
    `findExecutable`, then runs only status-only probes: `--version`,
    `codex login status`, `claude auth status`, `gh auth status`, and each
    provider's `plugin list --json`. It also stats the Kanban-managed
    backend install path resolved by `canonicalIssueReviewerPath`.
- **Inputs:** for setup, the selected components, `--scope`, the Kanban
  checkout, the target repository for a project-scoped registration, and —
  for the Codex bundle comparison — `CODEX_HOME` and the version the tracked
  `plugin.json` declares; for preflight, the repository the board is pointed
  at (provider plugin listings are resolved relative to it).
- **Outputs:** for setup, a plan (the default) or the performed
  installation, plus a non-zero exit whenever a component needs user
  action; for preflight, a per-dependency and per-action readiness report,
  and the remediation the board substitutes for a generic agent failure.
  "Needs user action" is `refused`, `unavailable`, `failed`, and a `repair`
  that is still pending — an ordinary fresh-install plan exits 0, and so
  does a `repair` that the same `--apply` run converged.
- **Failure semantics:** setup never replaces an ordinary user file, a
  symlink it does not recognize as its own, a marketplace registered from
  another checkout, or an installed-but-disabled bundle — each is reported
  as `refused`, preserved, and paired with its recovery step; both of those
  provider refusals keep precedence over any bundle refresh and run no
  command. A provider cache that cannot be read — a path that is not a
  directory, one that cannot be traversed, or a tracked manifest declaring no
  version to name it by — is `unavailable` rather than stale, so an
  installation setup cannot inspect is never reinstalled over. After a
  refresh, setup re-runs the same comparison that planned it: commands that
  exited 0 but left the bundle still diverging are reported as `failed`,
  because a provider's exit status is not evidence that the cache converged.
  Preflight blocks an action only on a definite local observation; a probe it
  cannot interpret is reported as unknown and never blocks. Its per-action
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
- **Durable state:** whatever each provider's own installer records —
  including the bundle copy Codex caches under `CODEX_HOME`, which setup
  reads and refreshes only through `codex plugin remove`/`add` — plus the
  install directory described in §3. Setup owns no state of its own.
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
| `ps` | Yes | Kanban's own worker/job-liveness snapshot (`src/Kanban/Process.hs`, which `src/Kanban/Worker.hs` consumes rather than spawns) runs it unconditionally. |
| `launchctl` | No | Only needed to install and control the optional drainer's LaunchAgent on macOS; `/usr/bin/plutil` below only reads the job it installs. |
| `/usr/bin/plutil` | No | Only needed to read the drainer's LaunchAgent status on macOS. |
| `systemctl`, with a live `systemctl --user` session | No | The Linux counterpart of the two rows above: only needed to install and control the optional drainer's user unit. Kanban reads that unit's own file directly, so Linux needs no reader alongside it. |
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
CLI flags (`--path`, `--review ISSUE [ISSUE ...]`/`--rereview`/`--check`/
`--review-queue`, `--legacy-policy dual`, `--json`), its JSON/comment/label
output contract, its
role as the
sole source of truth for both the interactive review workflow and the solve
readiness gate, and — since the vendoring migration this section now
describes — its implementation and every runtime component its supported
commands need.

- **`tools/approve_issues.py`** is the tracked source of truth. A fresh
  checkout can run its `--self-test`, `--check`, `--review`, `--rereview`, and
  `--review-queue`
  paths directly, with no file beneath `~/work` or
  `~/.codex/skills/approve-issues/`. Its portable runtime locations — the
  install links under `~/Library/Application Support/kanban/issue-review/` on
  macOS and `$XDG_DATA_HOME/kanban/issue-review/`
  (`~/.local/share/kanban/issue-review/` when that variable is unset)
  elsewhere, the daily logs under `~/Library/Logs/kanban/issue-review/` on
  macOS and `$XDG_STATE_HOME/kanban/issue-review/`
  (`~/.local/state/kanban/issue-review/` when unset) elsewhere, and the
  incident circuit breaker beneath that install directory's
  `runtime/incidents/` — are a namespaced Kanban footprint, not personal
  state, and its optional crash/incident notification
  (`KANBAN_ISSUE_REVIEW_NTFY_URL`) is a documented non-fatal no-op when
  unset, matching §5.
- **`tools/install_issue_review.py`** installs a stable Kanban-managed link
  to that tracked backend under its install directory (default
  `~/Library/Application Support/kanban/issue-review` on macOS and
  `$XDG_DATA_HOME/kanban/issue-review` elsewhere, selectable with
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
  `.../tools/approve_issues.py` satisfies it. `src/Kanban/Review/Canonical.hs`
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
  Its blast radius is one issue. An `invalid-issue` incident blocks the
  issue its `issue` field names — `--check`, `--review` and `--rereview`
  for that number, and that number alone in the polling daemon's queue —
  while every other issue in the repository keeps its ordinary verdict and
  the daemon keeps running and approving them. `--review-queue` is the one
  exception, and deliberately so: its ordering is positional, so it fails the
  whole pass when its ascending scan *reaches* the named issue rather than
  skipping past an issue whose canonical state is known to be untrustworthy.
  A scoped incident on a higher-numbered issue still costs it nothing, because
  the scan returns a decision before it gets there. An incident whose scope is
  indeterminate — the field absent, null, or anything but a positive
  integer, which is every record written before incidents carried a scope —
  instead halts the whole repository and refuses the daemon's start, as all
  incidents once did. Incidents are matched on the resolved repository path
  and so never reach another checkout, and acknowledgement remains external
  to the backend: it has no resolve path, and a record stops applying when
  its JSON file is edited or removed.

## 4. Dependency manifest

Machine-readable; parsed verbatim by `tools/test_agent_workflow_contract.py`,
which also reconciles this manifest against the tracked Codex plugin's own
bash surface (`codex-plugin/plugins/kanban/skills/*/SKILL.md`) and the
tracked Claude plugin's own bash surface
(`claude-plugin/plugins/kanban/commands/*.md`), and every non-test Python
module under `tools/`, in addition to the Haskell invocation surface — a
command a packaged workflow or a repository tool shells out to is as
undocumented-if-missing as one Kanban's own Haskell code spawns. Each plugin
surface is an enumerated list in that module rather than a glob, so a packaged
asset reaches the scan only by being listed: the nine drafting, canonical
issue-review, and issue-rereview assets declared in
[drafting-workflow-contract.md §2](drafting-workflow-contract.md#2-declared-assets)
and the seven design and report document workflows declared in
[document-workflow-contract.md §2](document-workflow-contract.md#2-declared-assets)
are all members, and the check reconciles both declared sets against those
lists so a vendored asset cannot be declared without being scanned. Their
user-scoped paths are reconciled against the `personal-path` rows below by a
markdown counterpart of the Haskell home-relative-path check.
Columns: `id | kind | token | files | owner | status | mandatory`.

- `kind`: `executable` (a literal command Kanban's Haskell source, the tracked
  Codex or Claude plugin's packaged workflows, or a non-test module under
  `tools/` spawns or resolves) or `personal-path` (a home-relative path
  Kanban's Haskell source builds or depends on).
- `token`: the exact literal string the check searches for.
- `files`: `;`-separated repository-relative paths where the token is
  expected to appear (empty when nothing in this repository references it).
- `owner`: `kanban` (Kanban owns this dependency's contract, whether or not
  its implementation is tracked in this repository yet) or `external` (a
  dependency Kanban consumes but does not define, e.g. a Codex-side skill
  package).
- `status`: `supported` or `migration-target`.
- `mandatory`: `yes` or `no`, matching §2.6 for executables.

A `files` entry covers a bundle's byte-identical vendored copy of the module it
names without listing it again. Issue #370 vendored `kanban_config.py` into both
plugin bundles beside the document mechanism that reads it, and the copies are
held byte-identical to `tools/kanban_config.py` by
`tools/test_document_workflow_contract.py`. Being identical by test is what
makes a copy a copy rather than a second definition, which is the property these
rows exist to protect — the managed locations that module writes down are still
stated once, and a copy that drifted from that statement would fail before it
could be installed anywhere. An executable a vendored copy spawns is not covered
by the same rule and is listed per copy, because that surface is scanned per
file rather than per definition.

```text
codex-cli | executable | codex | src/Kanban/Codex.hs;src/Kanban/Review.hs;src/Kanban/Solve.hs;src/Kanban/PullRequestFlow.hs;src/Kanban/Preflight/Environment.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;claude-plugin/plugins/kanban/scripts/review_pr.py | kanban | supported | no
claude-cli | executable | claude | src/Kanban/Claude.hs;src/Kanban/Review/Tools.hs;src/Kanban/Solve.hs;src/Kanban/PullRequestFlow.hs;src/Kanban/Preflight/Environment.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;claude-plugin/plugins/kanban/scripts/review_pr.py | kanban | supported | no
claude-script-wrapper | executable | script | src/Kanban/Claude.hs | kanban | supported | no
gh-cli | executable | gh | src/Kanban/GitHub/Run.hs;src/Kanban/Review/Tools.hs;src/Kanban/Preflight/Environment.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;codex-plugin/plugins/kanban/skills/solve/scripts/trusted_issue_spec.py;codex-plugin/plugins/kanban/skills/issue/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;codex-plugin/plugins/kanban/skills/design-epic/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/draft-report/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;claude-plugin/plugins/kanban/commands/issue.md;claude-plugin/plugins/kanban/commands/issue-rereview.md;claude-plugin/plugins/kanban/commands/draft-issues.md;claude-plugin/plugins/kanban/commands/repair.md;claude-plugin/plugins/kanban/commands/design-epic.md;claude-plugin/plugins/kanban/commands/process-design-doc.md;claude-plugin/plugins/kanban/commands/draft-report.md;claude-plugin/plugins/kanban/commands/note-problem.md;claude-plugin/plugins/kanban/commands/process-report.md;claude-plugin/plugins/kanban/scripts/review_pr.py;claude-plugin/plugins/kanban/scripts/trusted_issue_spec.py | kanban | supported | yes
git-cli | executable | git | src/Kanban/Repository.hs;tools/setup_workflows.py;tools/plugin_bundle_gate.py;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;codex-plugin/plugins/kanban/skills/issue-review/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;codex-plugin/plugins/kanban/skills/design-epic/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/draft-report/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;claude-plugin/plugins/kanban/commands/pr-review.md;claude-plugin/plugins/kanban/commands/pr-rereview.md;claude-plugin/plugins/kanban/commands/pr-revise.md;claude-plugin/plugins/kanban/commands/issue-review.md;claude-plugin/plugins/kanban/commands/issue-rereview.md;claude-plugin/plugins/kanban/commands/repair.md;claude-plugin/plugins/kanban/commands/design-epic.md;claude-plugin/plugins/kanban/commands/process-design-doc.md;claude-plugin/plugins/kanban/commands/draft-report.md;claude-plugin/plugins/kanban/commands/note-problem.md;claude-plugin/plugins/kanban/commands/process-report.md;claude-plugin/plugins/kanban/scripts/review_pr.py;tools/publish_coordination_doc.py;tools/tracker_transaction.py;codex-plugin/plugins/kanban/skills/process-report/scripts/publish_coordination_doc.py;codex-plugin/plugins/kanban/skills/process-report/scripts/tracker_transaction.py;claude-plugin/plugins/kanban/scripts/publish_coordination_doc.py;claude-plugin/plugins/kanban/scripts/tracker_transaction.py | kanban | supported | yes
python3-cli | executable | python3 | src/Kanban/Review/Canonical.hs;src/Kanban/Preflight/Environment.hs;src/Kanban/Drainer.hs;codex-plugin/plugins/kanban/skills/solve/SKILL.md;codex-plugin/plugins/kanban/skills/pr-review/SKILL.md;codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md;codex-plugin/plugins/kanban/skills/issue-review/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;claude-plugin/plugins/kanban/commands/pr-review.md;claude-plugin/plugins/kanban/commands/pr-rereview.md;claude-plugin/plugins/kanban/commands/pr-revise.md;claude-plugin/plugins/kanban/commands/issue-review.md;claude-plugin/plugins/kanban/commands/issue-rereview.md;claude-plugin/plugins/kanban/commands/repair.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;claude-plugin/plugins/kanban/commands/process-report.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;claude-plugin/plugins/kanban/commands/process-design-doc.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;claude-plugin/plugins/kanban/commands/note-problem.md | kanban | supported | no
ps-cli | executable | ps | src/Kanban/Process.hs | kanban | supported | yes
plutil-cli | executable | /usr/bin/plutil | src/Kanban/Drainer.hs | kanban | supported | no
launchctl-cli | executable | launchctl | tools/service_manager.py | kanban | supported | no
systemctl-cli | executable | systemctl | tools/service_manager.py | kanban | supported | no
approve-issues-backend | personal-path | /Library/Application Support/kanban/issue-review | tools/kanban_config.py | kanban | supported | no
approve-issues-backend-xdg | personal-path | /.local/share/kanban/issue-review | tools/kanban_config.py | kanban | supported | no
issue-review-log-dir | personal-path | /Library/Logs/kanban/issue-review | tools/kanban_config.py | kanban | supported | no
issue-review-log-dir-xdg | personal-path | /.local/state/kanban/issue-review | tools/kanban_config.py | kanban | supported | no
issue-review-discovery-record | personal-path | /Library/Application Support/kanban/issue-review/config.json | src/Kanban/Review/Canonical.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;claude-plugin/plugins/kanban/scripts/review_pr.py;codex-plugin/plugins/kanban/skills/issue-review/SKILL.md;claude-plugin/plugins/kanban/commands/issue-review.md;codex-plugin/plugins/kanban/skills/solve/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md;claude-plugin/plugins/kanban/commands/issue-rereview.md | kanban | supported | no
drainer-launchagent-label | personal-path | com.coghex.drain-prs | tools/service_manager.py | kanban | supported | no
drainer-discovery-record | personal-path | /Library/Application Support/kanban/pr-drainer/config.json | tools/kanban_config.py;src/Kanban/Drainer.hs | kanban | supported | no
drainer-discovery-record-xdg | personal-path | /.local/share/kanban/pr-drainer/config.json | tools/kanban_config.py | kanban | supported | no
drainer-install-dir | personal-path | /Library/Application Support/kanban/pr-drainer | tools/kanban_config.py;src/Kanban/Drainer.hs | kanban | supported | no
drainer-install-dir-xdg | personal-path | /.local/share/kanban/pr-drainer | tools/kanban_config.py | kanban | supported | no
drainer-log-dir | personal-path | /Library/Logs/kanban/pr-drainer | tools/kanban_config.py | kanban | supported | no
drainer-log-dir-xdg | personal-path | /.local/state/kanban/pr-drainer | tools/kanban_config.py | kanban | supported | no
find-cli | executable | find | codex-plugin/plugins/kanban/skills/solve/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;codex-plugin/plugins/kanban/skills/pr-review/SKILL.md;codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md | kanban | supported | no
head-cli | executable | head | codex-plugin/plugins/kanban/skills/solve/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;codex-plugin/plugins/kanban/skills/pr-review/SKILL.md;codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md | kanban | supported | no
codex-plugin-cache-root | personal-path | /.codex | codex-plugin/plugins/kanban/skills/solve/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;codex-plugin/plugins/kanban/skills/pr-review/SKILL.md;codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md | external | supported | no
awk-cli | executable | awk | codex-plugin/plugins/kanban/skills/design-epic/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/draft-report/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;claude-plugin/plugins/kanban/commands/design-epic.md;claude-plugin/plugins/kanban/commands/process-design-doc.md;claude-plugin/plugins/kanban/commands/draft-report.md;claude-plugin/plugins/kanban/commands/note-problem.md;claude-plugin/plugins/kanban/commands/process-report.md | kanban | supported | no
rg-cli | executable | rg | codex-plugin/plugins/kanban/skills/process-report/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;claude-plugin/plugins/kanban/commands/process-report.md;claude-plugin/plugins/kanban/commands/note-problem.md | kanban | supported | no
```

The four issue-review `personal-path` rows are two locations times two
platform conventions, not four locations. `approve-issues-backend` and
`approve-issues-backend-xdg` are the install directory as macOS and the XDG
data directory spell it; `issue-review-log-dir` and
`issue-review-log-dir-xdg` are the log directory as macOS and the XDG state
directory spell it. A row's `token` is one exact literal, which is the shape
both reconciliations here rely on, so a location with two spellings needs two
rows rather than one row naming a choice — and adding a managed path with only
one platform's row leaves the other's spelling undeclared. All four declare
`tools/kanban_config.py` because that module is where each is written down,
once: §5 describes which of them is a fresh install's write default on a given
host, and which existing installation a probe prefers. The log directory moves
only with `approve_issues.py --log-dir`, never with `--install-dir` or
`KANBAN_ISSUE_REVIEW_INSTALL_DIR`, so it needs no relocation rule of the kind
`drainer-install-dir` documents below.

The six drainer `personal-path` rows are three locations times two platform
conventions, on exactly the terms the issue-review rows above follow.
`drainer-install-dir` is the directory the installer links the drainer, the
controller and the configuration parser into, and the default Kanban resolves
`drain_prs.py` inside for the board's `m` key; `drainer-install-dir-xdg` is the
same directory as the XDG data directory spells it.
`drainer-discovery-record` and `drainer-discovery-record-xdg` are the record
inside each. The install directory is listed separately from the record because
the two move independently: `--install-dir` relocates this directory, while the
record's own path is fixed precisely so a dashboard that inherited no
environment can still find an install that moved. `drainer-log-dir` and
`drainer-log-dir-xdg` are the log root as macOS and the XDG *state* directory
spell it; it moves with neither `--install-dir` nor
`KANBAN_DRAINER_INSTALL_DIR`, so like the issue-review log directory it needs no
relocation rule.

Every one of the six declares `tools/kanban_config.py`, because that module is
where each is written down, once, for both platforms — the controller, the
installer and the drainer all resolve through it rather than spelling a path of
their own. §5 describes which of them is a fresh install's write default on a
given host and which existing installation the probe prefers. The two `~/Library`
rows also declare `src/Kanban/Drainer.hs`, which still spells that location
itself: the dashboard's own resolver joins this arc separately, so until it does
a Linux host discovers an XDG-installed drainer from the Python side and not yet
from the board.

`drainer-launchagent-label`'s token is the shared prefix, which is all a single
token can be: an installed job's identifier appends the repository's own slug
to it (`com.coghex.drain-prs.coghex.kanban`, plus a `.service` suffix on
systemd), so there is one identifier per canonical
GitHub repository rather than one for the account. The bare prefix is also the
label of the machine-wide singleton that predates per-repository jobs, which
`tools/service_manager.py` retires rather than installs, and which only ever
existed under launchd. The identifier belongs to
that module because it is the service manager's: it is the backend
that names, writes, and targets a job, and every other component reads the
identifier from it or out of the discovery record rather than restating it.

`codex-plugin-cache-root` is the only user-scoped path this repository declares
that Kanban does not own: `$CODEX_HOME` (default `~/.codex`) is Codex's own
directory, and the Codex bundle's `find`-based lookups below are rooted at the
`plugins/cache` tree inside it. It is `external`/`mandatory: no` for that
reason — Kanban never creates it, and every workflow that consults it is an
optional user- or Kanban-invoked action. The Claude bundle declares no
counterpart, for the reason the next paragraph gives.

`find-cli` and `head-cli` are `mandatory: no`: they are only needed to locate
one of the installed Codex plugin's own vendored scripts from inside a workflow
whose working directory is the worked repository rather than the plugin's own
install location — the shared review coordinator for `$pr-review`,
`$pr-rereview`, `$pr-revise`, and `$repair`, the trusted-comment issue-spec
helper for `$solve` (§2.1) and `$issue-rereview`, and the publication and
tracker-transaction modules for `$process-report`, `$process-design-doc`, and
`$note-problem` — themselves optional AI
actions, and every supported macOS/Linux shell already provides both. The Claude plugin's equivalent workflows need neither: Claude
Code exposes `${CLAUDE_PLUGIN_ROOT}` inside a plugin's own commands, so
`/pr-review`, `/pr-rereview`, `/pr-revise`, and `/repair` resolve their bundled
coordinator directly at `${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py`,
`/solve` and `/issue-rereview` their bundled helper at
`${CLAUDE_PLUGIN_ROOT}/scripts/trusted_issue_spec.py`, and the three document
workflows their bundled mechanism at
`${CLAUDE_PLUGIN_ROOT}/scripts/publish_coordination_doc.py` and
`${CLAUDE_PLUGIN_ROOT}/scripts/tracker_transaction.py`, without a filesystem
search. That plugin bundles its own copy of each, so it never depends on the
Codex plugin being installed, and it declares no `personal-path` row of its
own because it names no home-relative bundle path at all.

`awk-cli` and `rg-cli` are `mandatory: no` because nothing outside the
document workflows declared in
[document-workflow-contract.md §2](document-workflow-contract.md#2-declared-assets)
needs either, and those workflows are optional user-invoked actions. Every one
of the ten resolves its docs worktree by branch with
`git worktree list --porcelain | awk ...`, which is why `awk` is a dependency
of all ten and of nothing else here; like `find` and `head`, every supported
macOS/Linux shell already provides it. `rg` is the exception: both
`process-report` variants name ripgrep to list a report's finding headings —
inside a fenced block in the Claude command, in prose in the Codex skill — and
both `note-problem` variants name it in prose to locate the implementation an
observation is about. It is the one entry in this manifest that a stock system
may genuinely lack. That costs an installation without it those four workflows'
search step and nothing else, which is what `mandatory: no` records.

## 5. Portable-install policy

- **Project-scoped assets are preferred.** Where Kanban must write outside
  the repository at all, it prefers a small, clearly namespaced footprint:
  the drainer installer's default install directory is this platform's own
  `kanban/pr-drainer` — `~/Library/Application Support` on macOS, the XDG data
  directory elsewhere — and its job identifiers
  and definition paths — LaunchAgent labels and plists under
  `~/Library/LaunchAgents`, unit names and files under
  `~/.config/systemd/user` — are a Kanban-owned convention rather than a
  personal one. The component that writes the definitions owns the
  identifiers, and that is the
  service-manager backend:
  `tools/drain_prs_service.py` resolves each repository's normalized canonical
  GitHub identity — through the remote the shared Kanban configuration names,
  the same one the dashboard resolves its own repository through — and
  `tools/service_manager.py` derives that job's identifier from it, renders and
  writes the definition, and builds every manager target from the same
  identifier. One slug names the identifier and the runtime and log directories
  together, and both backends hold it to the same escaping and length
  discipline, so a repository names one job whichever host it is installed on.
  The controller partitions the runtime and log paths by that identity and —
  from those same values — records the backend that wrote the entry, the job's
  identifier, the definition's absolute path,
  and the checkout it was installed for under that repository's entry in the
  discovery record, which is in the directory this platform resolves rather
  than in whichever one the script links were installed to. The
  derivation is total, produces a valid nonempty label for every supported
  `owner/name`, and is injective across distinct normalized identities, so no
  two repositories can name one job. `tools/install_drainer.py` resolves a job
  through those two modules rather than restating any of it, and
  `src/Kanban/Drainer.hs` derives no identifier at all: it selects the entry
  for the identity it resolved and reads the backend, the identifier, and the
  definition path out of it.
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
  The drainer's own three managed locations are spelled once in
  `tools/kanban_config.py`, the only tracked module installed beside the
  controller and therefore the only one both the installer and the installed
  controller can import. Its install directory — the discovery record and the
  runtime root with it — defaults to
  `~/Library/Application Support/kanban/pr-drainer` on macOS and to
  `$XDG_DATA_HOME/kanban/pr-drainer` elsewhere; its log root defaults to
  `~/Library/Logs/kanban/pr-drainer` and `$XDG_STATE_HOME/kanban/pr-drainer` on
  the same terms. Either XDG variable is honoured only when it names an
  absolute directory, which is systemd's own rule for `$XDG_CONFIG_HOME`, so
  the drainer's managed paths and the unit that runs it read the environment
  identically; unset, empty, and relative all fall back to `~/.local/share` and
  `~/.local/state`. Those are *write* defaults, and resolving an installation
  that already exists probes the XDG location first and the `~/Library`
  location second on both platforms, exactly as the issue-review probe below
  does and with the same occupied-but-invalid rule.
  An installation that already exists is never moved: the probe finds it where
  it is, on either spelling, and a host that inherited a `~/Library`
  installation keeps it. Relocating one to this platform's own convention is
  #367, taking over one already at that location is #368, and carrying across
  what a writer installs at a relocated location is #369.
  The installed definition carries `$XDG_DATA_HOME` and `$XDG_STATE_HOME`
  alongside `KANBAN_DRAINER_INSTALL_DIR` whenever they are absolute, because
  that option pins the install directory and the runtime root beneath it but
  not the record or the log root, and a user manager need not export what the
  operator installed under; a job started without them would resolve
  `~/.local` and write a second record nothing reads.
  `tools/install_issue_review.py` follows the same convention for the
  canonical issue-review backend, and resolves the same way. Its install
  directory defaults to `~/Library/Application Support/kanban/issue-review`
  on macOS and to `$XDG_DATA_HOME/kanban/issue-review` — `~/.local/share`
  when that variable is unset — on every other platform; its log directory
  defaults to `~/Library/Logs/kanban/issue-review` and
  `$XDG_STATE_HOME/kanban/issue-review` (`~/.local/state` when unset) on the
  same terms. All four are spelled once in `tools/kanban_config.py` — the
  only tracked module installed beside the backend, so the only one both the
  installer and the installed backend can import, and therefore the only
  place a platform's answer can be given. Those are *write* defaults, which
  decide where a fresh install goes and nothing else: resolving an
  installation that already exists probes the XDG location first and the
  `~/Library` location second on both platforms and takes whichever holds a
  discovery record, so no install made under either convention has to move
  and none is migrated. A higher-precedence candidate that is occupied but
  invalid — a dangling symlink, a directory where the record belongs —
  selects that installation rather than being read as absent, leaving the
  record's own contract below to report what is wrong with it. Every
  successful install, from either `tools/install_issue_review.py` or
  `tools/setup_workflows.py --component issue-review --apply`, writes the
  linked backend's absolute path as `backend_path` into that resolved
  directory's `config.json`, after the links it names have been created and
  never during a dry run. That document's location is fixed even when
  `--install-dir` moves the installation — `--install-dir` and
  `KANBAN_ISSUE_REVIEW_INSTALL_DIR` relocate the installation alone, never
  the record and never the log directory — and it is merged rather than
  overwritten so the `config_path` reference the installer has always
  persisted there survives beside it. Runtime and incident state stay
  relative to the install directory the backend resolves *for itself* on
  every platform, so `KANBAN_ISSUE_REVIEW_INSTALL_DIR` moves them along with
  the scripts. A bare `--install-dir` install moves the links alone: the
  backend it placed there resolves its own directory through the record and
  the environment, never through the option it was installed with, and that
  is unchanged by the per-platform defaults.
  Resolution precedence, identical in `src/Kanban/Review/Canonical.hs`,
  `src/Kanban/Preflight.hs`, both packaged `review_pr.py` coordinators, and
  the packaged Codex/Claude `issue-review` and `solve` workflows: a non-empty
  `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then a recorded `backend_path`, then —
  only when that field is absent, which is exactly how an installation
  predating the record reads — the directory holding the record. A selected
  override or recorded backend that is missing fails there rather than
  falling through to a lower-precedence location, since reviewing with an
  installation the user did not choose is worse than not reviewing; a record
  that will not parse, or whose `backend_path` is wrong-typed or relative,
  is its own failure naming that document. The per-platform defaults above
  are so far the Python side's alone: `tools/kanban_config.py` and every
  component that imports it — `tools/approve_issues.py`,
  `tools/install_issue_review.py`, `tools/setup_workflows.py`, and
  `tools/approve_issues_service.py` — resolve both conventions, while the
  Haskell resolution point and the vendored plugin assets listed above still
  name the `~/Library` record location only and therefore do not yet discover
  an XDG-defaulted install on a non-macOS host. Closing that is the remaining
  work of the portability arc (#347), not a licence for a second spelling in
  the meantime.
- **User-scoped installation is explicit and opt-in.** Nothing in Kanban's
  build (`cabal build all`) or normal startup path installs the drainer's job
  or the issue-review backend's stable link; the installed definition is
  loaded but never started, never enabled, and carries no `[Install]` section
  on systemd, so no login brings a drainer up on its own; the latter is only
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
  daemon, models, or credentials. That constraint holds for repair as much as
  for installation: an installed Codex bundle that has fallen behind the
  tracked one is refreshed by `codex plugin remove kanban@kanban` then
  `codex plugin add kanban@kanban` (§2.5), never by writing into or deleting
  from the provider's cache, and the comparison that plans it reads only
  Kanban's own installed bundle — nothing else under `CODEX_HOME` is
  inspected or reported.
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
  `Codex.hs`, `Claude.hs`, `GitHub/Run.hs`, `Repository.hs`, `Drainer.hs`,
  `Process.hs`) invoke a literal external command that has no matching
  `executable` manifest entry — `GitHub/Run.hs` rather than `GitHub.hs`
  because the split in #160 left `Kanban.GitHub` a re-export façade and moved
  the `gh` spawn into `Kanban.GitHub.Run`, which is the only module under
  `src/Kanban/GitHub/` that resolves or starts an executable;
- fails if any of the tracked Codex plugin's packaged `SKILL.md` files or the
  tracked Claude plugin's packaged `commands/*.md` files invoke a command,
  inside a fenced ```` ```bash ```` block, that has no matching `executable`
  manifest entry — each of those two surfaces is the enumerated list named in
  §4 (`PLUGIN_SURFACE_FILES` and `CLAUDE_PLUGIN_SURFACE_FILES` in that module)
  rather than a directory glob, so a newly packaged asset is scanned only once
  it is added to its list;
- fails if either packaged plugin's own bundled coordinator
  (`codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py` or
  `claude-plugin/plugins/kanban/scripts/review_pr.py`) invokes a command, as
  the first element of a `run`/`subprocess.run` argument list, that has no
  matching `executable` manifest entry — the coordinator is Python, not
  bash, so it is reconciled with a separate extractor from the `.md` files
  above, not exempted from coverage;
- fails if any of the Haskell source files in the first bullet build a
  home-relative path segment that has no matching `personal-path` manifest
  entry;
- fails if a non-test Python module under `tools/` invokes a command, as the
  first element of a literal argument list in either Python quote style
  passed to `subprocess.run`/`Popen` or to any of these modules' own
  `run`-family wrappers (`run`, `run_command`, `run_json`, and anything else
  spelled `run`, matched as a family so the next wrapper is covered before it
  is written), that has no matching
  `executable` manifest entry — that is how `launchctl` is held to the same
  standard as `/usr/bin/plutil`, which merely reads the job `launchctl`
  installs. This surface is discovered rather than enumerated, so a tool
  module added later is scanned as soon as it lands; `test_*.py` modules and
  `tools/fake_cli.py` — that one path, not every module sharing its name —
  are excluded because they construct fake executables rather than depend on
  real ones. It is executable-only: the home-relative
  paths these modules build are not scanned, so the bullet above does not
  extend to `tools/`;
- fails if any of the nine drafting, canonical issue-review, and
  issue-rereview assets declared in
  [drafting-workflow-contract.md §2](drafting-workflow-contract.md#2-declared-assets)
  names a `$HOME/`- or `~/`-prefixed path with no matching `personal-path`
  manifest entry. All nine are scanned for external commands too; the bash
  fence extractor simply yields nothing for a prose-only contract, so an asset
  with no executable surface is covered rather than exempted;
- fails, identically, for the seven design and report document workflows
  declared in
  [document-workflow-contract.md §2](document-workflow-contract.md#2-declared-assets),
  and additionally fails if that document declares an asset no plugin surface
  list scans, or if the commands recovered from one of those seven stop matching
  what this manifest declares for it — so the scan cannot silently narrow to
  nothing while still reporting no undocumented command;
- fails if a manifest entry's declared `files` no longer contain its token,
  so the manifest cannot silently drift from the code it describes;
- fails if the issue-review backend entry (`approve-issues-backend`) is
  missing from the manifest or is not marked `kanban`-owned and `supported`,
  or if a `codex-approve-issues-skill` entry still exists, so the manifest
  cannot silently regress to the pre-migration boundary described in §3;
- fails if the drainer LaunchAgent label entry (`drainer-launchagent-label`)
  is missing from the manifest or is marked anything other than a
  `kanban`-owned `supported` `personal-path`. What that entry declares is the
  shared label prefix described above, not the plist file: the plist's own
  directory has no manifest row, because §5 keeps its paths and labels as a
  Kanban-owned convention rather than a personal path.

Both machine-readable fences in this document are parsed anchored to their own
heading — §4's to `## 4. Dependency manifest` and §7's to
`## 7. Document publication classification` — so neither parser can capture the
other's rows, and a third fence added later cannot silently displace either.

## 7. Document publication classification

Every tracked Markdown file in this repository takes exactly one publication
lane:

- `coordination` — a coordination record: a findings, code-health, or design
  document and its status ledger, whose content no runtime, installer, or test
  reads.
  Eligible for direct publication to `master`, bypassing the pull-request lane.
- `pr-atomic` — a document that lands atomically with its implementation
  through the pull-request lane, because changing it on its own can invalidate
  the tree.

Anything unclassified is `pr-atomic` to every consumer. An unknown document is
never direct-master eligible: the table below is an allowlist for the
`coordination` lane alone, so a tracked Markdown file matching no row is a
check failure rather than a document that publishes directly.

The sixteen `coordination` documents are
`docs/card_filter_design.md`, `docs/claude_document_workflows_design.md`,
`docs/code-health-report.md`, `docs/document_workflow_findings.md`,
`docs/drainer-bugs.md`, `docs/issue_approval_queue_design.md`,
`docs/issue_search_design.md`,
`docs/linux_portability_design.md`, `docs/managed_paths_design.md`,
`docs/multi_repo_boards_design.md`,
`docs/pipeline-hardening.md`, `docs/public_release_design.md`,
`docs/ui-bugs.md`, `docs/usage_awareness_design.md`,
`docs/workflow_audit_findings.md`, and
`docs/workflow_command_vendoring_design.md`. **Every other tracked
Markdown file in this repository is `pr-atomic`.** Those two sentences are the
human-readable answer to "which lane does this document take", and
`tools/test_document_classification.py` reconciles them against the rows below,
so placing a known document never requires reading the machine-readable table.

This classification is Kanban's own. It describes this repository and nothing
else. A consuming repository declares its own coordination paths through the
drainer configuration key `workflow.coordination_paths`
([pr-drainer.md](pr-drainer.md#merging-past-a-coordination-only-base-advance)),
which ships empty; Kanban never infers a consuming repository's classes from
file extension or directory, and never applies the rows below to another
repository's tree.

Machine-readable; parsed verbatim by `tools/test_document_classification.py`.
Columns: `path | class | reasons`.

A row naming a directory ends with `/` and covers the tracked Markdown files
beneath it, matched by whole path component rather than by string prefix: the
`codex-plugin/` row covers
`codex-plugin/plugins/kanban/skills/solve/SKILL.md` and never a sibling
directory such as `codex-plugin-old/`. That component boundary is the point of
a directory row — it is a statement about one tracked component, not about
every name that happens to begin the same way. Non-Markdown files beneath a
declared directory are outside this classification entirely: it classifies
documents, not bundle assets.

`reasons` is a `;`-separated set rather than a single choice, because a
document is frequently `pr-atomic` for more than one of these at once and
recording only one would understate what a change to it can break:

- `test-parsed` — a tracked test reads this file's content as data, so editing
  it alone can fail `build-test`.
- `release-document` — `tools/test_source_distribution.py` declares this file
  in a release inventory (`RELEASE_DOCUMENTS`, `RELEASE_ROOT_FILES`, or a tree
  in `RELEASE_TREES`), so editing it alone changes what ships.
- `implementation-coupled` — `CLAUDE.md`'s "The contract" section requires this
  file to stay consistent with behavior in the same pull request.
- `audit-report` — a findings, code-health, or design document carrying its
  own status ledger, which `tools/test_source_distribution.py` lists in
  `EXCLUDED_TRACKED_PATHS`. This is the only reason that admits the
  `coordination` lane.

```text
AGENTS.md | pr-atomic | release-document;implementation-coupled
CHANGELOG.md | pr-atomic | release-document
CLAUDE.md | pr-atomic | release-document;implementation-coupled
README.md | pr-atomic | release-document
claude-plugin/ | pr-atomic | test-parsed;release-document
codex-plugin/ | pr-atomic | test-parsed;release-document
docs/README.md | pr-atomic | release-document
docs/agent-workflow-contract.md | pr-atomic | test-parsed;release-document;implementation-coupled
docs/bugs.md | pr-atomic | release-document
docs/card_filter_design.md | coordination | audit-report
docs/claude_document_workflows_design.md | coordination | audit-report
docs/code-health-report.md | coordination | audit-report
docs/design.md | pr-atomic | test-parsed;release-document;implementation-coupled
docs/development.md | pr-atomic | release-document
docs/document-workflow-contract.md | pr-atomic | test-parsed;release-document
docs/document_workflow_findings.md | coordination | audit-report
docs/drafting-workflow-contract.md | pr-atomic | test-parsed;release-document
docs/drainer-bugs.md | coordination | audit-report
docs/issue_approval_queue_design.md | coordination | audit-report
docs/issue_search_design.md | coordination | audit-report
docs/linux_portability_design.md | coordination | audit-report
docs/managed_paths_design.md | coordination | audit-report
docs/media/README.md | pr-atomic | test-parsed;release-document
docs/multi_repo_boards_design.md | coordination | audit-report
docs/pipeline-hardening.md | coordination | audit-report
docs/pr-drainer.md | pr-atomic | release-document
docs/public_release_design.md | coordination | audit-report
docs/ui-bugs.md | coordination | audit-report
docs/usage_awareness_design.md | coordination | audit-report
docs/user-guide.md | pr-atomic | release-document
docs/workflow-setup.md | pr-atomic | release-document
docs/workflow_audit_findings.md | coordination | audit-report
docs/workflow_command_vendoring_design.md | coordination | audit-report
```

The six `test-parsed` rows name what actually parses them:
`tools/test_agent_workflow_contract.py` reads §4 of this document (and
`tools/test_document_classification.py` reads §7),
`test/Spec/UI/Keys.hs` reads the binding table in `docs/design.md` §7,
`tools/test_document_workflow_contract.py` and
`tools/test_drafting_workflow_contract.py` read their own contracts' §2 asset
tables, and `tools/test_claude_plugin.py` and `tools/test_codex_plugin.py` read
the frontmatter and body of every packaged workflow under `claude-plugin/` and
`codex-plugin/`.

`docs/design.md` and `docs/agent-workflow-contract.md` are the two documents
that are `test-parsed` and `implementation-coupled` at once: `CLAUDE.md` names
both as authoritative contracts, and each is also read as data. Neither
rationale supersedes the other, which is why the row records both.

`AGENTS.md` is the Codex entry point for the same contract: a repository-relative
symlink to `CLAUDE.md`, so one session-instruction document serves both brands
with no second copy to drift.
`tools/test_repository_contract_alias.py` follows it and compares its bytes with
`CLAUDE.md`'s, and `tools/test_source_distribution.py` repeats that comparison
inside the unpacked archive. Its row therefore mirrors `CLAUDE.md`'s exactly: it
ships, and it is the same implementation-coupled contract read through a second
name.

### 7.1 Classification check

`tools/test_document_classification.py` (discovered by
`python3 -m unittest discover -s tools -p 'test_*.py'`, which CI already runs)
parses the table in §7 and:

- fails if a Git-tracked `*.md` path matches no row, so an added document
  cannot reach `master` without a stated lane. The subject inventory is
  `git ls-files '*.md'`, not a restated list, so a new document is classified
  or reported the moment it is tracked;
- fails if a declared path is absent from the tree — a file row whose file is
  gone, or a directory row whose directory is gone;
- fails if a tracked Markdown path matches two rows, so no document can carry
  two lanes;
- fails if a row names a class outside `coordination`/`pr-atomic`, states no
  reason, or states a reason outside the vocabulary above;
- fails if a `coordination` row cites any reason other than `audit-report`, or
  if a `pr-atomic` row cites `audit-report`;
- fails if an entry in `RELEASE_DOCUMENTS` in `tools/test_source_distribution.py`
  does not classify `pr-atomic`, and if a path declaring `release-document`
  appears in no release inventory there or appears in
  `EXCLUDED_TRACKED_PATHS`. The release lists are an independent corroboration
  reconciled against this table, never the source the classes are derived
  from: publication policy and release packaging must stay free to diverge;
- fails if the prose sentences above name a different `coordination` set than
  the rows do, so the human-readable answer cannot drift from the
  machine-readable one;
- fails if `CLAUDE.md` stops pointing contributors at this section, or stops
  stating the fail-closed default.
