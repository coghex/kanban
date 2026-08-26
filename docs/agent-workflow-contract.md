# Kanban agent-workflow contract

Contract version: 2

## 1. Purpose and scope

Kanban's board is fully usable without any AI provider. A smaller set of
explicit actions — issue solve, PR review/rereview/revise/repair, canonical
issue
review/rereview, the solve readiness gate, and the two optional background
services, the PR drainer and the issue approval service — call
out to external executables, a canonical review backend, and (for the two
services) a user-scoped launchd job or systemd user unit. This document is the single
authoritative list of those external dependencies: what owns them, how
Kanban invokes them, what they return or fail with, what authority they
need, where their durable state lives, and whether they are mandatory for
Kanban to run at all or optional AI/automation add-ons.

It also declares the boundary between what Kanban owns and tracks in this
repository and what remains explicit, opt-in user-machine state (each managed
service's own job definition; the compatibility launcher described in §3), and
the policy any installer for that state must follow.

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
  its brand via `agentForAction` and its model/effort from the model roster's
  `pr_review`/`pr_revise` cell for that brand — `src/Kanban/Models.hs`, whose
  compiled defaults the tracked `models.toml.example` mirrors — before
  invoking it, refusing to spawn at all if the roster cannot supply that
  cell). A packaged workflow implementing this action must have that
  already-correct session
  perform the review itself and use its bundled coordinator only to publish
  the result safely (gate/head/race checks, comment, label, and approval-only
  draft readiness) — not spawn a further, unpinned nested reviewer that would
  both waste and be unable to verify Kanban's guarantee.
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
  values the `roles.pr_review.codex` and `roles.pr_review.claude` cells of
  `models.toml.example` declare — the cells Kanban's own
  `PullRequestReview`/`PullRequestRereview` spawns resolve — and binds the
  verified model in the published `pr-review:v2` marker instead of
  `unspecified`. Since issue #483 the exception's *mechanism* is roster
  resolution rather than a pinned constant, and the exception itself is
  unchanged: that coordinator loads a byte-identical copy of
  `tools/kanban_models.py` from beside itself -- never from `tools/`, which an
  installed bundle has no sibling of -- and resolves those two cells through
  it, keeping its four constants as the compiled fallbacks that reader is
  handed on a host carrying no `~/.config/kanban/models.toml`. A roster file
  that is present and will not load refuses the nested review instead of
  spawning those fallbacks, because this coordinator publishes the model it
  spawned as verified fact. The Codex bundle ships no copy of that reader and
  passes no model or effort at all, which `tools/test_codex_plugin.py` asserts
  rather than assumes.
  `tools/test_claude_plugin.py` holds the coordinator's
  compiled fallbacks against those cells, so the two lanes still cannot
  silently diverge.
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
  - **Which model the backend reviews with** comes from the model roster's
    `roles.issue_gate.codex` and `roles.issue_gate.claude` cells, read through
    `tools/kanban_models.py` (issue #483). Precedence has three layers:
    the compiled defaults, which equal the tracked `models.toml.example`; then
    `~/.config/kanban/models.toml` (or `$XDG_CONFIG_HOME`) when one exists;
    then the environment, which wins outright. The environment layer is
    complete — `APPROVE_ISSUES_CODEX_MODEL`, `APPROVE_ISSUES_CODEX_EFFORT`,
    `APPROVE_ISSUES_CLAUDE_MODEL`, and `APPROVE_ISSUES_CLAUDE_EFFORT`, one
    model and one effort variable per provider — so an operator cannot move a
    model from the environment and be left running the file's effort. All four
    are optional overrides with no tracked default, like every variable §5
    names.
    A roster file that is *absent* is silently the compiled defaults, which is
    the fresh-install path. A roster file that is present and unreadable,
    unparseable, foreign-versioned, or invalid makes this backend **perform no
    review at all**: it exits non-zero naming the file and the defect, writes
    nothing to stdout, and never falls back to the defaults, because an
    operator who edited the file to change a model must never have a reviewer
    quietly run on the one they believed they replaced. The reviewer display
    names in published comments are deliberately *not* roster-derived: they
    are a reviewer persona this backend parses back out of historical markers,
    and they keep their own `APPROVE_ISSUES_CODEX_DISPLAY_NAME` /
    `APPROVE_ISSUES_CLAUDE_DISPLAY_NAME` overrides.
    The resolved assignment is what a published marker's `models=` field
    records and what §2.3.1's reconciliation accepts as current, so changing
    either half of it retires standing approvals and forces rereview.
    `tools/drain_prs.py` resolves `roles.drain_rereview.codex` the same way for
    its stale-head rereview, re-read once per drain cycle so a roster edit
    takes effect without restarting the managed service; a roster it cannot
    resolve stops that drainer where it stands rather than rereviewing on a
    model it cannot claim.
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

#### 2.3.1 Stale-approval reconciliation (`--reconcile-approvals`)

A raw `reviewed:approve` label is not evidence that an issue is approved now.
Canonical approval binds an issue to its current specification fingerprint
through the latest `issue-review:v2` marker, and the backend removes a stale
verdict label only once an issue enters `process_issue` — so until review
begins, a label can advertise readiness to any label-only reader against a
specification no reviewer saw. `--reconcile-approvals` is the bounded authority
that corrects that, and it is the only one: label-only consumers do not
reimplement the removal, and `--check` remains read-only.

- **Authority.** `python3 tools/approve_issues.py --path <root> --repo
  <owner/name> --reconcile-approvals [<issue>...] --legacy-policy dual --json`.
  It joins `--check`, `--review`, `--rereview`, and `--review-queue` in one
  mutual-exclusion set sharing their diagnostic, is mutually exclusive with
  `--self-test`, and requires `--json`. Every one of those refusals is resolved
  before the repository context loads, so a rejected invocation costs no GitHub
  call and writes nothing to stdout. It performs **no** model call — the
  `MODEL_INVOCATIONS` counter reads zero across a run — publishes no review
  comment, and manufactures no verdict.
- **Decision.** An approval label is removed only when no marker exists at all,
  when the mismatch is one of specification, origin, reviewer route, or accepted
  model, or when a marker that does match carries a verdict other than
  `APPROVE`. The decision comes from the `marker_matches` comparison and the
  marker `verdict` value `current_gate_status` itself keys on, never from that
  function's human-readable `reasons` strings, and there is no second freshness
  calculation. Repository-base movement alone never invalidates an approval:
  `marker_matches` compares `spec`, `origin`, `reviewers`, and `models` and
  never reads a marker's `base=`, which stays supporting review context.

  The reviewer set is resolved through `expected_reviewers_for_record` *before*
  that comparison rather than through `review_record_matches`, which collapses a
  record it cannot resolve — an unknown `mode`, a rereview marker with no
  matching parent, a trigger disagreeing with its parent's verdicts — into the
  same `False` a specification mismatch produces. The gate is right to refuse
  both, but only one of them is evidence that an approval went stale: removing a
  label because a record could not be *read* is a fail-open mutation. An
  unresolvable record, or one resolving to no reviewer, is reported as
  unverified and mutates nothing.
- **What is never a removal cause.** An emptied reviewer set — unmarked legacy
  provenance under `--legacy-policy hold` — makes `marker_matches` answer False
  for *every* marker including a current one, so it is reported as unverified
  rather than acted on. A blocking pipeline incident, a non-`OPEN` issue, and a
  present `reviewed:changes` label each refuse the gate while leaving the marker
  current; those mutate nothing and are reported with the gate's own `reasons`.
  An `INVALID` latest marker is reported as a per-issue unverified outcome
  carrying the marker's `comment_url`, exactly as `--check` reports rather than
  escalates: raising `InvalidIssueError` here would open a repository
  circuit-breaker incident as a side effect of rendering a roadmap.
- **Candidate selection.** Given no issue numbers, the mode reconciles every
  open issue carrying the configured approval label, and it selects them under
  the lock from an inventory that refuses to be truncated. Selection is the
  backend's rather than the caller's for two reasons: the candidate set is
  defined by `workflow.approval_label`, which the backend has already resolved,
  so a caller choosing candidates would have to restate that label and would
  silently reconcile nothing in a repository that overrides it; and a set chosen
  before the lock could change before any decision ran. The result names the
  label it decided against in `approval_label`, so a consumer reports the
  repository's own label rather than assuming the default.
- **Locking.** The canonical `approve_issues.lock` is acquired at most once for
  the whole invocation, whatever the number of issues, and released on every
  exit path including failure and interruption. Every issue and comment read
  that a decision rests on is taken *after* acquisition, so a stale pre-lock
  observation can never remove an approval that became current concurrently.
  After a removal the issue is re-read and the result verified — the label
  really gone, and the specification fingerprint byte-identical, since
  `spec_fingerprint` excludes the three verdict labels — before success is
  reported.
- **Result.** Exactly one bounded, versioned JSON document, written to stdout in
  a single call, carrying exactly `schema`
  (`"approve-issues-reconcile-approvals"`), `version` (`1`), `outcome`,
  `message`, and `issues`: one entry per requested issue, in the order
  requested, each carrying exactly `issue`, `outcome`, `label_removed`,
  `approved`, `reasons`, and `detail`; plus `approval_label`, the configured
  label this pass decided against.

  | `outcome` | meaning |
  | --- | --- |
  | `reconciled` | every requested issue was examined under the lock |
  | `busy` | the lock was held elsewhere; nothing was read or written |

  | entry `outcome` | `label_removed` | `approved` | meaning |
  | --- | --- | --- | --- |
  | `unlabeled` | `false` | Boolean | the approval label is absent |
  | `current` | `false` | Boolean | the label is backed by a current `APPROVE` marker |
  | `removed` | `true` | `false` | the label was stale and was removed |
  | `unverified` | either | `null` | nothing could be established; `detail` says what |

  Both top-level outcomes are ordinary completions and **exit zero**, `busy`
  included. The document is validated before it is printed, on the terms
  `--review-queue`'s already follows: an unknown schema or version, a missing or
  additional field at either level, an `approval_label` disagreeing with the one
  the run decided against, a mistyped or Boolean-as-integer value, an
  entry set that does not match the requested issues in order, a `removed` that
  claims approval or omits `label_removed`, an `unverified` carrying an
  `approved` Boolean or no `detail`, or any model invocation at all are refused
  rather than emitted.
- **Failure semantics.** Fail closed outside the scoped `busy` liveness
  exception. A missing backend, a GitHub read or write failure, a malformed
  result, or an unverifiable post-mutation state is a per-issue `unverified`
  entry or a non-zero exit with diagnostics on stderr and no document a caller
  could read as success — never a claimed removal and never an unverified
  readiness answer. An interruption is a failure for this mode wherever in the
  run it lands, for the reason `--review-queue`'s is. A consumer renders no
  readiness marker for an issue it could not verify, and never presents such an
  issue as ready to solve. A validated top-level `busy` document is the sole
  exception: although the backend read and mutated nothing under the held lock,
  triage and retriage may render the document's non-empty `approval_label` from
  their verified-complete open-issue snapshot. That display-only fallback
  claims no reconciliation or removal; the later solve gate remains
  authoritative and may refuse a stale label. Every other failure still closes,
  including an invalid or missing `approval_label` in a `busy` document.
- **Consumers.** The rendered triage assets
  (`claude-plugin/plugins/kanban/commands/triage.md`,
  `codex-plugin/plugins/kanban/skills/triage/SKILL.md`) are the first, and the
  rendered retriage assets
  (`claude-plugin/plugins/kanban/commands/retriage.md`,
  `codex-plugin/plugins/kanban/skills/retriage/SKILL.md`) the second. For a
  `reconciled` document, all four render their readiness marker from each
  entry's post-reconciliation `approved`. For a `busy` document requested with
  no issue numbers, its empty `issues` array claims no reconciliation; the four
  instead render exact matches for its validated `approval_label` from the
  verified-complete open-issue snapshot. They must disclose that label-backed
  fallback once per answer, immediately after the repository/count line, while
  it remains advisory and display-only. Neither
  outcome is followed by a second `--check`, which would reopen the
  read-then-decide window the lock closes. They pass no issue numbers and name
  no candidate label, so a repository configuring its own approval label is
  reconciled and rendered exactly as the default one is. Retriage additionally
  recomputes every marker on each run rather than carrying one forward from the
  roadmap it is editing, including during the `busy` fallback.

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
  on Linux. Managing a job is `tools/service_manager.py`'s alone
  — the controller and the installer both reach their host's manager through
  that backend, and neither builds a `launchctl` or `systemctl` argument
  vector, reads either one's output, or writes or parses a plist or a unit
  file. `launchctl` is spawned nowhere else in the tree; the one `systemctl`
  spawn outside that backend is the §2.8 dashboard's read-only user-manager
  version probe, which manages no job. The drainer's own PR-merge loop
  (`tools/drain_prs.py`) shells out to `git` and `gh` for every repository
  operation, and, only for automated stale-head rereview rounds, to
  `codex exec`. Every executable these Python tools spawn is declared in the
  §4 manifest and reconciled against it the same way the Haskell and
  packaged-workflow surfaces are: every non-test module under `tools/` is a
  scanned surface, so `launchctl` and `systemctl` each carry both a manifest
  row and a §2.6
  host-prerequisite entry. That surface is executable-only. The home-relative
  paths these modules build are mostly neither asserted nor scanned from here:
  some have `personal-path` rows (the drainer's install directory, its discovery
  record, its log root, its LaunchAgent label, and — since the approval
  service's own scan below — the two directories
  `tools/service_manager.py` writes definitions into,
  `~/Library/LaunchAgents` and `~/.config/systemd/user`), while others
  deliberately still have none (the legacy `~/work/approve-issues.py`
  launcher), and reconciling the remainder is #146's work, not this surface's.
  The one Python surface that *is* scanned for home-relative paths is §2.8's
  three approval-service modules, `tools/service_manager.py` among them.
  Their behavior stays covered by
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
  that is, the dashboard answers the same way the controller does:
  `src/Kanban/ManagedPaths.hs` probes the XDG location and then the
  `~/Library` one, on both platforms, exactly as `tools/kanban_config.py`
  does, so a Linux host discovers an XDG-installed drainer from the board and
  from the Python side alike. `src/Kanban/Drainer.hs` spells neither location:
  it asks that resolver, which is the one place either is written down on this
  side of the boundary. That entry is a
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
  service-manager `run` path takes it for its startup check alone. No transition *acts*
  on a gate evaluated outside the lock, because such an answer can be true when
  it is read and false when it is acted on; the authoritative check is always
  the one taken inside. That is not the same as forbidding a check outside it,
  and the paragraph below requires one: a cheap unlocked preflight that refuses
  without touching anything is the only way a refusal can leave the
  installation as it found it, since taking the lock is itself a write. The stabilization wait a start
  performs after its kick is outside it, so the lock is never held against the
  process it is waiting for.

  Each of those transitions — install, start, uninstall, run, stop, and
  incident acknowledgement, which is every *controller* transition that writes
  into an installation — asks first whether the installation is still the one this
  process is bound to, and refuses if it is not. It asks twice: once with no
  lock held at all, because taking the lock is itself a write into the
  installation — it creates the record's parent directory, chmods it, and
  creates the lock file beside it — and again inside, where the answer is
  authoritative because no mover can be running. A gate that only ran under
  the lock would mutate the very installation it was about to refuse, which
  for the `run` path is the difference between a clean preflight refusal and
  one that rebuilt part of what a mover removed. Managed paths are
  resolved once, when a component starts, and a controller cannot re-derive
  them for its own use — so a process that is running when a later run moves or
  removes an installation would otherwise rebuild exactly what that run took
  away, and leave its repository's job naming a controller that no longer
  exists. Two signals answer it, in order: a relocation marker, a JSON document
  named by a shared constant that a mover leaves in the directory it takes
  apart, naming where the installation went — and named in the refusal
  alongside that destination, so an operator with two bound locations is told
  which one moved — looked for in the bound install
  directory *and* in the bound discovery record's directory, because
  `--install-dir` makes those two different places — and, for the case no
  marker survives, whether the bound record or install directory is still the
  one this host resolves. Reading the marker is total: absent, unreadable, not
  an object, or naming no destination is not a relocation. The `run` path
  refuses by printing rather than logging, because logging creates the
  directories it logs into.

  Every write to the discovery record's `repositories` table carries that same
  gate itself, not only the transitions that perform one. Holding the record's
  lock across a whole transition serializes a queued writer rather than
  stopping it: such a writer wakes *after* a mover has taken the installation
  apart, on the far side of any reconciliation that mover could have run, and a
  refusal that lived only in its caller would be one a caller could be outside
  of. So the merge and the removal that mutate that table each ask the gate
  before and inside the record's own lock, which makes the refusal a property
  of the write. A transition that already holds the lock re-enters it, and asks
  the gate again for nothing.

  The drainer's own writes are deliberately not among them.
  `tools/drain_prs.py` records conflict and cleanup incidents into the
  installation through `record_conflict_incident` and
  `record_cleanup_incident`, in its standalone `--pr` mode as much as under a
  controller, and neither is gated here. It does not need to be: a drainer run
  takes the checkout's own run lock as soon as the git directory is known and
  before any log line, state read, or GitHub call, and a run that moves or
  removes an installation fences on exactly that lock for every recorded
  repository — so a drainer cannot be writing while a mover is running, in
  either order. Gating those writes as well would add a second answer to a
  question the fence already settles.

  A running controller also holds an exclusive lock on `controller.lock` inside
  its own runtime directory, taken inside that same startup span — while the
  record's lock is held no mover can be running, so the gate's answer is still
  true when this is taken, and from then on a mover fences on it and refuses
  instead. It is held for the process's whole life and never unlinked once
  created, on the same terms as the record's own lock. It is deliberately not
  the drainer's run lock: `drain_prs.py` takes the checkout's `.git` rendezvous
  non-blockingly and the controller supervises a child that does exactly that,
  so a controller holding the drainer's lock would make every run it supervises
  fail immediately. Two objects, both held at once.

  What a mover owes in return is symmetrical and is part of this contract
  rather than each mover's own invention. It fences on *both* lock kinds — the
  discovery record's and the controller's — at every location it writes into
  or removes from, source and destination alike, and it keeps holding them
  across a rollback, because an undo writes to exactly the locations the
  transition did. And the marker it leaves is a tombstone rather than a
  notice: a valid one refuses every gated transition unconditionally, with no
  expiry and no best-effort reading, until the run that makes that location a
  live installation again removes or invalidates it. A mover that took a
  location apart and left a marker behind has therefore said something
  permanent about it, which is what lets a controller bound there refuse
  without having to reason about how long ago the move happened.

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
  resolved for every Python component by `tools/kanban_config.py` and, for
  the record the dashboard reads, by that module's Haskell counterpart
  `src/Kanban/ManagedPaths.hs` — the two agree by construction, each spelling
  both platforms' locations once — and declared as
  `personal-path` rows in §4: on macOS
  `~/Library/Application Support/kanban/pr-drainer` and
  `~/Library/Logs/kanban/pr-drainer`, and on Linux `$XDG_DATA_HOME` and
  `$XDG_STATE_HOME`'s `kanban/pr-drainer` — `~/.local/share` and
  `~/.local/state` when the variable is unset, empty, or not absolute.
  Discovery probes the XDG location first and the `~/Library` location second
  on both platforms and takes the first whose record exists; only when neither
  is occupied is the answer this platform's write path. A macOS installation is
  therefore never moved, and a `~/Library` installation on any other platform is
  moved exactly once, by the installer's own relocation described in §5. `<install-dir>` is a third name only
  because `--install-dir` and `KANBAN_DRAINER_INSTALL_DIR` exist: they relocate
  the script directory and the runtime root beneath it, and move neither the
  discovery record nor the log root. The variable is how an installed component
  resolves the installation it belongs to; it is not how the *installer* picks
  where to write. `tools/install_drainer.py`'s destination is `--install-dir`
  alone, defaulting to `<record-dir>` on macOS and to this platform's own
  convention elsewhere, so a host that merely exports the variable is not
  thereby installing somewhere custom — which is what would otherwise leave a
  `~/Library` installation unrelocated forever. With no override in play `<install-dir>`
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
| `launchctl` | No | Only needed to install and control an optional service's LaunchAgent on macOS — the PR drainer's (§2.4) or the issue approval service's (§2.8); `/usr/bin/plutil` below only reads the jobs it installs. |
| `/usr/bin/plutil` | No | Only needed to read those two services' LaunchAgent definitions on macOS. |
| `systemctl`, with a live `systemctl --user` session | No | The Linux counterpart of the two rows above: only needed to install and control either optional service's user unit. Kanban reads that unit's own file directly, so Linux needs no reader alongside it. |
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

### 2.8 Incident/controller capability — the issue approval service

Operator documentation: [docs/issue-approval.md](issue-approval.md).

- **Owning source:** `tools/approve_issues_service.py` (the foreground `run`
  that supervises repeated backend passes, the durable status, barrier and
  incident documents, and the `install`/`start`/`stop`/`uninstall` job
  operations), `tools/install_issue_approval.py` (installation safety — the
  managed links, the controller-copy match, and the canonical backend it
  resolves but never installs), and `tools/service_manager.py` (the same one
  service-manager boundary §2.4 names), surfaced in-app by
  `src/Kanban/ApprovalService.hs`. Kanban's in-app surface is read-only for
  everything the service owns — status, the barrier, incidents — and adds
  exactly one mutation: starting or stopping the installed job through the
  controller. It owns no review policy whatever.
- **Backend selection:** the same `tools/service_manager.select_backend`
  probe §2.4 describes, constructed for the `issue-approval`
  `ServiceNamespace` instead of the drainer's. That namespace is what keeps the
  two services' identifiers, definitions and legacy questions from ever
  colliding: neither can name, load, unload, or acknowledge the other's job,
  and this one reports no machine-wide singleton at all, because its jobs have
  always been per-repository. `tools/install_issue_approval.py` consults
  `sys.platform` no more than `tools/install_drainer.py` does — its only
  platform refusal is the selection's — and within that selection the platform
  name gates the launchd branch alone and is not sufficient even there, so a
  Linux host with a live `systemctl --user` session installs exactly as a macOS
  host does.
- **Invocation:** the controller never imports the reviewer. Every pass is a
  child process running the *installed* canonical backend — resolved through the
  §2.3 record, in the §3 precedence — as
  `<interpreter> <backend> --path <root> --repo OWNER/NAME --legacy-policy <policy>
  --log-dir <job log dir> --json --review-queue [--config <path>]`, where the
  interpreter is the controller's own `sys.executable` rather than whatever
  `python3` the manager's `PATH` resolves — falling back to that spelling only
  for an embedded interpreter reporting none — and a
  barrier poll is the same vector with `--check <issue>` instead. Each is
  spawned in a new session so the whole process group can be signalled, since
  the backend spawns `gh` and a reviewer model of its own. Exactly one bounded
  JSON document crosses back, and the schema and version it must carry are
  mirrored in the controller rather than imported, held equal to the backend's
  by `tools/test_approve_issues_service.py`. Managing a job is
  `tools/service_manager.py`'s alone, exactly as in §2.4: it is the only
  component that spawns `launchctl` at all, and the only one that spawns
  `systemctl --user` to act on a unit. One other component reaches these
  commands without managing anything. `src/Kanban/ApprovalService.hs` — the
  in-app dashboard, which installs and controls nothing — detects the host's
  manager: it probes for both with `findExecutable`, and where it finds
  `systemctl` it spawns `systemctl --user show --property Version --value`
  through `runGroupedProcess` to learn whether this account's user manager
  answers at all, mirroring the installer's own probe so the two agree about
  which hosts have a service. That is why the `launchctl-cli` and
  `systemctl-cli` rows in §4 name that module alongside the backend, as the
  `plutil-cli` row already does, and why it is a scanned Haskell surface: the
  §6 executable check recovers both names from it, and the same listing puts
  the discovery-record location it builds into the home-relative
  reconciliation, which is what holds the dashboard and the controller to one
  answer about where the record is. Unlike §2.4, the home-relative paths this
  service's three Python modules build *are* reconciled from
  here: `tools/test_agent_workflow_contract.py` resolves each parsed module for
  every chain of literal path segments reaching a home root — following a name
  to whatever it was bound to, and a nullary helper to what it returns, because
  that is how both `root / "systemd" / "user"` and
  `service_root() / "runtime"` are actually written — and requires a
  `personal-path` row in §4 for each one, matched exactly rather than by
  containment so a location beneath a declared root is not absorbed into that
  root's row. What it recovers from each module is
  pinned, so the scan cannot pass by discovering nothing, and a module it cannot
  parse fails rather than reporting none.
- **Inputs:** repository path and repository identity, resolved exactly as §2.4
  resolves the drainer's — through the remote the *shared* Kanban configuration
  names, never through the repository's own `--config`, which would otherwise
  decide the identity that was used to find it. The repository's own `--config`
  is persisted in its record entry and carried into the definition, so a start
  from an empty environment still runs with it. Kanban passes its own identity
  as `--repo OWNER/NAME` beside `--path`, and the controller refuses any
  identity but the checkout's own. The installed definition carries the same
  `--repo`, so a shared `remote_name` changed after installation stops that job
  rather than re-pointing it. The service definition is a LaunchAgent plist
  under `~/Library/LaunchAgents` or a unit file under `~/.config/systemd/user`,
  one per canonical GitHub repository, named for the identifier
  `tools/service_manager.py` derives from that repository's normalized identity.
  Those two directories are the *manager's* rather than this service's, and are
  not anchored to the passwd home at all: that module
  resolves them through `Path.home()`, which honours `$HOME`, and on systemd
  through `$XDG_CONFIG_HOME` as well — with no option involved and nothing to
  opt into. A command run under a redirected `$HOME`
  therefore writes a definition the record — which does not move — could not
  then name. (The shared script links can also sit off the passwd home, but
  only because `--install-dir` or `KANBAN_ISSUE_APPROVAL_INSTALL_DIR` was given
  a path that puts them there; see the Durable state bullet below for the three
  groups in full.)
  Kanban names none of them: it selects this repository's entry in the discovery
  record, resolves the definition's path from it, and reads the command out of
  the definition itself. That entry is a discriminated union on `backend` in the
  shape §2.4 describes, with one difference: an entry naming **no** backend is
  refused rather than read as launchd, because this service's installer has
  written the discriminator since its first release, so an entry without one was
  not written by it.
- **Outputs:** canonical review verdicts, published entirely by the backend —
  review comments, `reviewed:approve`/`reviewed:changes` labels, and the
  versioned review marker §2.3 defines. Nothing the controller writes is on
  GitHub, and what it writes locally depends on which operation it is running.
  A `run` writes its own runtime documents and log lines and nothing else.
  `install`, `start` — which refreshes the installation before it kicks the
  job — and `uninstall` additionally write, rewrite or remove the service
  definition and this repository's entry in the discovery record, which is the
  whole of what "loads a stopped job" means here. `status` writes a document to
  stdout under `--json` and is otherwise read-only:
  it creates no directory, rewrites no document, and opens or resolves no
  incident. `ack` rewrites one incident record and nothing else.
- **Failure semantics:** two incident kinds, both attributed to the canonical
  repository rather than to the checkout that raised them. An
  `issue-changes-requested` incident is **warning** severity: the ordered
  barrier, a healthy service waiting for a specification repair it must not
  perform, unique per open (repository, issue). An `approval-error` incident is
  **error** severity: a run that ended on a backend pass it could not act on, or
  on a controller fault. The barrier's authority is its own `barrier.json`
  record rather than that warning, so an acknowledgement resolves the incident
  for bookkeeping and leaves the queue barriered — only a current canonical
  approval of that issue removes the record. Ordinary contention for the
  canonical approval lock is not a failure at all: it is the backend's fifth
  normal `busy` outcome, which the controller backs off on. The one refusal that
  is deliberately never automated is the untracked background approval daemon:
  if it holds the canonical lock, install and start refuse with a diagnostic
  naming it, and this service never adopts, migrates, or terminates it.
- **Required authority:** the same GitHub write scope the canonical review needs
  and the provider sign-in it calls models with, plus local control of the
  signed-in user's own service manager — launchd's GUI domain on macOS, that
  user's systemd manager on Linux. Neither requires root, and nothing is
  installed system-wide. The controller takes no authority of its own: every
  GitHub mutation is the backend's, made under the operator's own `gh` login.
- **Durable state:** per account, in three groups that answer "what moves this?"
  differently. Enumerated rather than quantified, because the answer is not the
  same for all of them and a blanket statement would be wrong for two.

  **Anchored and immovable.** Four locations — the discovery record, the runtime
  tree, the lock directory, and the log root — hang off one root resolved from
  the **passwd** home directory rather than from `$HOME`, and no option and no
  environment variable moves any of them. That is what the identity lock keeping
  two clones of one repository from both running depends on: a root a
  process-controlled input could move would let two runs both start. They are
  four of the `issue-approval` `personal-path` rows in §4, and none of the four
  has an XDG spelling on any platform. The discovery record is at
  `~/Library/Application Support/kanban/issue-approval/config.json`, whose
  `repositories` table carries one entry per installed repository; the runtime
  tree is one directory per identity
  under `runtime/<slug>` holding `status.json`, an `incidents/` directory, and —
  only while the queue is barriered — `barrier.json`, whose absence is what an
  unbarriered queue *is*; the lock directory holds each identity's run lock
  and transition lock and each installation's link lock; and the log root holds
  one directory per
  identity under `~/Library/Logs/kanban/issue-approval` carrying the
  controller's `service.log`, the manager's `service.out`/`service.err`, and the
  backend's own dated logs, which the controller redirects there so two
  repositories' logs stay apart.

  **Movable by option.** The shared script links, the fifth such row, default
  beside the record and are what `--install-dir` and
  `KANBAN_ISSUE_APPROVAL_INSTALL_DIR` place elsewhere, expanding a leading `~`
  through `$HOME` as any path does — so a custom link location can be
  `$HOME`-dependent, where the four above never are and the definition
  directories always are. Nothing above
  follows them, unlike the drainer, whose runtime tree lives under its install
  directory and moves with it.

  **Not this service's to anchor.** The installed service definition is durable
  state too, and it is the *manager's*: `tools/service_manager.py` resolves its
  directory through `Path.home()` and, on systemd, `$XDG_CONFIG_HOME`, as the
  Inputs bullet above describes. A redirected environment moves it while the
  record that names it stays put, which is why that bullet says not to run a
  transition under one.

  Per checkout, in the repository's shared Git
  directory: `.git/kanban_issue_approval_run.lock`, this checkout's own run
  lock, beside the backend's `.git/approve_issues.lock`, which the controller
  **probes but never holds**: `approval_lock_owner` tries the same non-blocking
  exclusive `flock` the backend takes and releases it again immediately when it
  succeeds, reading the owner's metadata without truncating it when it does
  not — so asking who holds that lock never becomes holding it. The backend
  takes it for real, for one issue's review. Two run locks rather than one, because neither
  location sees both ways a second run arrives: the identity lock catches two
  clones of one repository, which share no Git directory, and the checkout lock
  catches one checkout started twice under identities that do not match. Every
  read-modify-write of the discovery record happens under an exclusive `flock`
  on a sibling lock file, and every job transition holds that installation's
  link lock before this identity's transition lock — always in that order, so
  two transitions can never deadlock. An uninstall removes the definition, the
  manager's hold on it, and that one record entry, and deliberately leaves the
  runtime state, logs, and open incidents behind: they are the record of what
  the service did, and an uninstall is not an acknowledgement.
- **Mandatory/optional:** fully optional. The board's `a` key starts or stops
  it, `tools/setup_workflows.py` has no component for it by design, and nothing
  in Kanban's build or normal startup path installs or runs it. Installation
  loads a stopped job and starts nothing, at install or at login. With nothing
  installed the key reports the installer rather than failing opaquely, and a
  host with no supported service manager is reported as its own condition rather
  than as a missing installation.

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
  requires all three installed files (`approve_issues.py` imports both
  `kanban_config.py` and `kanban_models.py` at module scope), so preflight and
  the installer can never disagree about whether an install path is occupied.
  `tools/install_issue_approval.py` verifies the same three beside the backend
  it resolves before it will make a service job, since a service with no
  reviewer it can start is not an installation.
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
(`claude-plugin/plugins/kanban/commands/*.md`), every non-test Python
module under `tools/`, and the repository's enumerated shell helpers —
today `tools/docs_land.sh` — in addition to the Haskell invocation surface: a
command a packaged workflow or a repository tool shells out to is as
undocumented-if-missing as one Kanban's own Haskell code spawns. Each plugin
surface is an enumerated list in that module rather than a glob, so a packaged
asset reaches the scan only by being listed: the nine drafting, canonical
issue-review, and issue-rereview assets declared in
[drafting-workflow-contract.md §2](drafting-workflow-contract.md#2-declared-assets)
and the ten design and report document workflows declared in
[document-workflow-contract.md §2](document-workflow-contract.md#2-declared-assets)
are all members, and the check reconciles both declared sets against those
lists so a vendored asset cannot be declared without being scanned. Their
user-scoped paths are reconciled against the `personal-path` rows below by a
markdown counterpart of the Haskell home-relative-path check.
Columns: `id | kind | token | files | owner | status | mandatory`.

- `kind`: `executable` (a literal command Kanban's Haskell source, the tracked
  Codex or Claude plugin's packaged workflows, or a non-test module under
  `tools/` spawns or resolves) or `personal-path` (a home-relative path
  Kanban's Haskell source, a packaged markdown workflow, or one of the
  issue-approval modules scanned below builds or depends on).
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
`tools/test_document_workflow_contract.py`. Issue #483 vendored
`kanban_models.py` into the Claude bundle alone on the same terms, held
byte-identical by `tools/test_claude_plugin.py`; it appears in no row below
because it writes down no managed location of its own. Being identical by test is what
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
gh-cli | executable | gh | src/Kanban/GitHub/Run.hs;src/Kanban/Review/Tools.hs;src/Kanban/Preflight/Environment.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;codex-plugin/plugins/kanban/skills/solve/scripts/trusted_issue_spec.py;codex-plugin/plugins/kanban/skills/issue/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;codex-plugin/plugins/kanban/skills/design-epic/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/draft-report/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;codex-plugin/plugins/kanban/skills/triage/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;claude-plugin/plugins/kanban/commands/issue.md;claude-plugin/plugins/kanban/commands/issue-rereview.md;claude-plugin/plugins/kanban/commands/draft-issues.md;claude-plugin/plugins/kanban/commands/repair.md;claude-plugin/plugins/kanban/commands/design-epic.md;claude-plugin/plugins/kanban/commands/process-design-doc.md;claude-plugin/plugins/kanban/commands/draft-report.md;claude-plugin/plugins/kanban/commands/note-problem.md;claude-plugin/plugins/kanban/commands/process-report.md;claude-plugin/plugins/kanban/commands/triage.md;claude-plugin/plugins/kanban/scripts/review_pr.py;codex-plugin/plugins/kanban/skills/retriage/SKILL.md;claude-plugin/plugins/kanban/commands/retriage.md;claude-plugin/plugins/kanban/scripts/trusted_issue_spec.py;codex-plugin/plugins/kanban/skills/backlog-review/SKILL.md;claude-plugin/plugins/kanban/commands/backlog-review.md;codex-plugin/plugins/kanban/skills/project-review/SKILL.md;claude-plugin/plugins/kanban/commands/project-review.md | kanban | supported | yes
git-cli | executable | git | src/Kanban/Repository.hs;tools/setup_workflows.py;tools/plugin_bundle_gate.py;tools/docs_land.sh;tools/docs_land_paths.py;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;codex-plugin/plugins/kanban/skills/issue-review/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;codex-plugin/plugins/kanban/skills/design-epic/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/draft-report/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;codex-plugin/plugins/kanban/skills/triage/SKILL.md;codex-plugin/plugins/kanban/skills/push-docs/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;claude-plugin/plugins/kanban/commands/pr-review.md;claude-plugin/plugins/kanban/commands/pr-rereview.md;claude-plugin/plugins/kanban/commands/pr-revise.md;claude-plugin/plugins/kanban/commands/issue-review.md;claude-plugin/plugins/kanban/commands/issue-rereview.md;claude-plugin/plugins/kanban/commands/repair.md;claude-plugin/plugins/kanban/commands/design-epic.md;claude-plugin/plugins/kanban/commands/process-design-doc.md;claude-plugin/plugins/kanban/commands/draft-report.md;claude-plugin/plugins/kanban/commands/note-problem.md;claude-plugin/plugins/kanban/commands/process-report.md;claude-plugin/plugins/kanban/commands/triage.md;claude-plugin/plugins/kanban/commands/push-docs.md;claude-plugin/plugins/kanban/scripts/review_pr.py;tools/publish_coordination_doc.py;tools/tracker_transaction.py;codex-plugin/plugins/kanban/skills/process-report/scripts/publish_coordination_doc.py;codex-plugin/plugins/kanban/skills/process-report/scripts/tracker_transaction.py;claude-plugin/plugins/kanban/scripts/publish_coordination_doc.py;claude-plugin/plugins/kanban/scripts/tracker_transaction.py;codex-plugin/plugins/kanban/skills/retriage/SKILL.md;claude-plugin/plugins/kanban/commands/retriage.md;codex-plugin/plugins/kanban/skills/backlog-review/SKILL.md;claude-plugin/plugins/kanban/commands/backlog-review.md;codex-plugin/plugins/kanban/skills/project-review/SKILL.md;claude-plugin/plugins/kanban/commands/project-review.md;codex-plugin/plugins/kanban/skills/drain-prs/SKILL.md;claude-plugin/plugins/kanban/commands/drain-prs.md | kanban | supported | yes
python3-cli | executable | python3 | src/Kanban/Review/Canonical.hs;src/Kanban/Preflight/Environment.hs;src/Kanban/Drainer.hs;tools/docs_land.sh;codex-plugin/plugins/kanban/skills/solve/SKILL.md;codex-plugin/plugins/kanban/skills/pr-review/SKILL.md;codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md;codex-plugin/plugins/kanban/skills/issue-review/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;claude-plugin/plugins/kanban/commands/pr-review.md;claude-plugin/plugins/kanban/commands/pr-rereview.md;claude-plugin/plugins/kanban/commands/pr-revise.md;claude-plugin/plugins/kanban/commands/issue-review.md;claude-plugin/plugins/kanban/commands/issue-rereview.md;claude-plugin/plugins/kanban/commands/repair.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;claude-plugin/plugins/kanban/commands/process-report.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;claude-plugin/plugins/kanban/commands/process-design-doc.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;claude-plugin/plugins/kanban/commands/note-problem.md;codex-plugin/plugins/kanban/skills/triage/SKILL.md;claude-plugin/plugins/kanban/commands/triage.md;codex-plugin/plugins/kanban/skills/retriage/SKILL.md;claude-plugin/plugins/kanban/commands/retriage.md;codex-plugin/plugins/kanban/skills/drain-prs/SKILL.md;claude-plugin/plugins/kanban/commands/drain-prs.md | kanban | supported | no
ps-cli | executable | ps | src/Kanban/Process.hs | kanban | supported | yes
plutil-cli | executable | /usr/bin/plutil | src/Kanban/Drainer.hs;src/Kanban/ApprovalService.hs | kanban | supported | no
launchctl-cli | executable | launchctl | tools/service_manager.py;src/Kanban/ApprovalService.hs | kanban | supported | no
systemctl-cli | executable | systemctl | tools/service_manager.py;src/Kanban/ApprovalService.hs | kanban | supported | no
approve-issues-backend | personal-path | /Library/Application Support/kanban/issue-review | tools/kanban_config.py | kanban | supported | no
approve-issues-backend-xdg | personal-path | /.local/share/kanban/issue-review | tools/kanban_config.py | kanban | supported | no
issue-review-log-dir | personal-path | /Library/Logs/kanban/issue-review | tools/kanban_config.py | kanban | supported | no
issue-review-log-dir-xdg | personal-path | /.local/state/kanban/issue-review | tools/kanban_config.py | kanban | supported | no
issue-review-discovery-record | personal-path | /Library/Application Support/kanban/issue-review/config.json | src/Kanban/ManagedPaths.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;claude-plugin/plugins/kanban/scripts/review_pr.py;codex-plugin/plugins/kanban/skills/issue-review/SKILL.md;claude-plugin/plugins/kanban/commands/issue-review.md;codex-plugin/plugins/kanban/skills/solve/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md;claude-plugin/plugins/kanban/commands/issue-rereview.md;codex-plugin/plugins/kanban/skills/triage/SKILL.md;claude-plugin/plugins/kanban/commands/triage.md;codex-plugin/plugins/kanban/skills/retriage/SKILL.md;claude-plugin/plugins/kanban/commands/retriage.md | kanban | supported | no
issue-review-discovery-record-xdg | personal-path | /.local/share/kanban/issue-review/config.json | src/Kanban/ManagedPaths.hs;codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py;claude-plugin/plugins/kanban/scripts/review_pr.py;codex-plugin/plugins/kanban/skills/issue-review/SKILL.md;claude-plugin/plugins/kanban/commands/issue-review.md;codex-plugin/plugins/kanban/skills/solve/SKILL.md;claude-plugin/plugins/kanban/commands/solve.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md;claude-plugin/plugins/kanban/commands/issue-rereview.md;codex-plugin/plugins/kanban/skills/triage/SKILL.md;claude-plugin/plugins/kanban/commands/triage.md;codex-plugin/plugins/kanban/skills/retriage/SKILL.md;claude-plugin/plugins/kanban/commands/retriage.md | kanban | supported | no
drainer-launchagent-label | personal-path | com.coghex.drain-prs | tools/service_manager.py | kanban | supported | no
drainer-discovery-record | personal-path | /Library/Application Support/kanban/pr-drainer/config.json | tools/kanban_config.py;src/Kanban/ManagedPaths.hs | kanban | supported | no
drainer-discovery-record-xdg | personal-path | /.local/share/kanban/pr-drainer/config.json | tools/kanban_config.py;src/Kanban/ManagedPaths.hs | kanban | supported | no
drainer-install-dir | personal-path | /Library/Application Support/kanban/pr-drainer | tools/kanban_config.py;src/Kanban/ManagedPaths.hs;codex-plugin/plugins/kanban/skills/drain-prs/SKILL.md;claude-plugin/plugins/kanban/commands/drain-prs.md | kanban | supported | no
drainer-install-dir-xdg | personal-path | /.local/share/kanban/pr-drainer | tools/kanban_config.py;src/Kanban/ManagedPaths.hs;codex-plugin/plugins/kanban/skills/drain-prs/SKILL.md;claude-plugin/plugins/kanban/commands/drain-prs.md | kanban | supported | no
drainer-log-dir | personal-path | /Library/Logs/kanban/pr-drainer | tools/kanban_config.py | kanban | supported | no
drainer-log-dir-xdg | personal-path | /.local/state/kanban/pr-drainer | tools/kanban_config.py | kanban | supported | no
issue-approval-job-label | personal-path | com.coghex.issue-approval | tools/service_manager.py | kanban | supported | no
issue-approval-install-dir | personal-path | /Library/Application Support/kanban/issue-approval | docs/issue-approval.md | kanban | supported | no
issue-approval-discovery-record | personal-path | /Library/Application Support/kanban/issue-approval/config.json | docs/issue-approval.md;src/Kanban/ApprovalService.hs | kanban | supported | no
issue-approval-runtime-dir | personal-path | /Library/Application Support/kanban/issue-approval/runtime | docs/issue-approval.md | kanban | supported | no
issue-approval-lock-dir | personal-path | /Library/Application Support/kanban/issue-approval/locks | docs/issue-approval.md | kanban | supported | no
issue-approval-log-dir | personal-path | /Library/Logs/kanban/issue-approval | docs/issue-approval.md | kanban | supported | no
managed-job-path-entry | personal-path | /.local/bin | docs/issue-approval.md | kanban | supported | no
launchagents-dir | personal-path | /Library/LaunchAgents | tools/service_manager.py | kanban | supported | no
systemd-user-unit-dir | personal-path | /.config/systemd/user | tools/service_manager.py | kanban | supported | no
find-cli | executable | find | codex-plugin/plugins/kanban/skills/solve/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;codex-plugin/plugins/kanban/skills/pr-review/SKILL.md;codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md | kanban | supported | no
head-cli | executable | head | codex-plugin/plugins/kanban/skills/solve/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;codex-plugin/plugins/kanban/skills/pr-review/SKILL.md;codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md | kanban | supported | no
codex-plugin-cache-root | personal-path | /.codex | codex-plugin/plugins/kanban/skills/solve/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;codex-plugin/plugins/kanban/skills/pr-review/SKILL.md;codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md;codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md;codex-plugin/plugins/kanban/skills/repair/SKILL.md;codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md | external | supported | no
awk-cli | executable | awk | tools/docs_land.sh;codex-plugin/plugins/kanban/skills/design-epic/SKILL.md;codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md;codex-plugin/plugins/kanban/skills/draft-report/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;codex-plugin/plugins/kanban/skills/process-report/SKILL.md;claude-plugin/plugins/kanban/commands/design-epic.md;claude-plugin/plugins/kanban/commands/process-design-doc.md;claude-plugin/plugins/kanban/commands/draft-report.md;claude-plugin/plugins/kanban/commands/note-problem.md;claude-plugin/plugins/kanban/commands/process-report.md;codex-plugin/plugins/kanban/skills/retriage/SKILL.md;claude-plugin/plugins/kanban/commands/retriage.md;codex-plugin/plugins/kanban/skills/backlog-review/SKILL.md;claude-plugin/plugins/kanban/commands/backlog-review.md;codex-plugin/plugins/kanban/skills/project-review/SKILL.md;claude-plugin/plugins/kanban/commands/project-review.md | kanban | supported | no
rg-cli | executable | rg | codex-plugin/plugins/kanban/skills/process-report/SKILL.md;codex-plugin/plugins/kanban/skills/note-problem/SKILL.md;claude-plugin/plugins/kanban/commands/process-report.md;claude-plugin/plugins/kanban/commands/note-problem.md | kanban | supported | no
sed-cli | executable | sed | tools/docs_land.sh;codex-plugin/plugins/kanban/skills/retriage/SKILL.md;claude-plugin/plugins/kanban/commands/retriage.md;codex-plugin/plugins/kanban/skills/backlog-review/SKILL.md;claude-plugin/plugins/kanban/commands/backlog-review.md;codex-plugin/plugins/kanban/skills/project-review/SKILL.md;claude-plugin/plugins/kanban/commands/project-review.md;codex-plugin/plugins/kanban/skills/drain-prs/SKILL.md;claude-plugin/plugins/kanban/commands/drain-prs.md | kanban | supported | no
tr-cli | executable | tr | tools/docs_land.sh | kanban | supported | no
grep-cli | executable | grep | tools/docs_land.sh | kanban | supported | no
mktemp-cli | executable | mktemp | tools/docs_land.sh | kanban | supported | no
dirname-cli | executable | dirname | tools/docs_land.sh | kanban | supported | no
```

The six issue-review `personal-path` rows are three locations times two
platform conventions, not six locations. `approve-issues-backend` and
`approve-issues-backend-xdg` are the install directory as macOS and the XDG
data directory spell it; `issue-review-log-dir` and
`issue-review-log-dir-xdg` are the log directory as macOS and the XDG state
directory spell it; `issue-review-discovery-record` and
`issue-review-discovery-record-xdg` are the record inside each install
directory. A row's `token` is one exact literal, which is the shape
both reconciliations here rely on, so a location with two spellings needs two
rows rather than one row naming a choice — and adding a managed path with only
one platform's row leaves the other's spelling undeclared. The four install
and log rows declare `tools/kanban_config.py` because that module is where
each is written down, once: §5 describes which of them is a fresh install's
write default on a given host, and which existing installation a probe
prefers. The two record rows declare `src/Kanban/ManagedPaths.hs` instead,
because that is where the record's own path is spelled whole:
`tools/kanban_config.py` composes it from the install directory above and a
separate file name, so it carries neither literal, while the Haskell resolver
spells each one for the same reason this manifest needs it spelled — a
reconciliation matches a literal, not an expression. Both record rows also
carry the same twelve packaged assets, because since issue #445 each of them
resolves the record by probing the two locations in that one order rather than
naming the macOS one: the ten Markdown workflow assets whose `bash` fence
resolves the backend, and both pull-request coordinators. An asset that spells
both literals is declared against both rows, so neither spelling can be
reverted in one asset while the other row still passes. The log directory moves
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
spell it; no option moves it, so unlike `drainer-install-dir` it has no
override rule — but it is still carried by the one relocation §5 describes,
because a host left logging to both roots would have one of them frozen as
history.

All six rows stay declared on every platform, including the `~/Library` three
on a host that will never install there again: they are what a non-macOS
relocation moves *from*, so the spelling has to stay policed for as long as any
component can still read it.

Every one of the six declares `tools/kanban_config.py`, because that module is
where each is written down, once, for both platforms — the controller, the
installer and the drainer all resolve through it rather than spelling a path of
their own. §5 describes which of them is a fresh install's write default on a
given host and which existing installation the probe prefers. The four record
and install-directory rows also declare `src/Kanban/ManagedPaths.hs`, which is
`tools/kanban_config.py`'s Haskell counterpart: the dashboard resolves the record through
one resolver of its own rather than spelling a location in each reader, and
that resolver probes the same two locations in the same order, so a Linux host
discovers an XDG-installed drainer from the board and from the Python side
alike. Both platforms' rows name it, because both spellings live there. The two
log rows do not, and need not: no Haskell consumer reads a drainer log.

Since issue #511 the two install-directory rows additionally name the two
rendered `drain-prs` workflow assets, the first packaged consumers any drainer
location has had. Each resolves the controller by probing those two directories
in that one order rather than spelling the macOS path, so both spellings are
policed in the bundle exactly as they already are in `tools/kanban_config.py`,
and an asset that reverted to a hardcoded path would fail the declaration it
carries. The record and log rows gain no such consumer, and the distinction is
exact: the assets test `$DRAINER/config.json` for existence to choose between
the two install directories, never reading the record's contents and never
spelling its path, and neither reads a drainer log at all. The location each
one actually names is the install directory itself, which is why those are the
two rows they join.

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

The five issue-approval `personal-path` rows and `issue-approval-job-label` are
what this service's own controller owns; the definition directories it also
writes into are the manager's and carry their own rows below. Unlike the
drainer's, these five have **no
XDG sibling**: `tools/approve_issues_service.py` resolves each of them from the
account's passwd home directory with no XDG rule of any kind, so one spelling is
the complete declaration on macOS and on Linux alike. `issue-approval-install-dir`
is the service root, which is also the record's directory, the *default*
install directory — `--install-dir` and `KANBAN_ISSUE_APPROVAL_INSTALL_DIR`
place the shared script links elsewhere and move nothing else, and a
`~` in either expands through `$HOME` like any path — and the parent of the
other two trees;
`issue-approval-discovery-record` is the record inside it, whose own path
`--install-dir` deliberately cannot move; `issue-approval-runtime-dir` is the
runtime root, one directory per identity beneath it holding that identity's
status document, barrier record, and incident directory;
`issue-approval-lock-dir` holds the per-identity run and transition locks and
the per-installation link lock; and `issue-approval-log-dir` is the log root,
which no option moves. Migrating the two `~/Library` roots to XDG data and state
locations remains future work, which is why no `-xdg` row exists to pair with
them yet.

`managed-job-path-entry` is not state at all: it is the one home-relative entry
of the fixed `PATH` both managed services' job definitions carry, declared
because a job's ability to find `gh`, `codex`, and `claude` depends on it, and
found by the scan below in `tools/approve_issues_service.py`.
`tools/drain_prs_service.py` builds the same entry for the drainer's own
definitions and is not on that scan's surface, so this one row covers a location
two modules write and one of them is policed for.

Four of the five — `issue-approval-install-dir`, `issue-approval-runtime-dir`,
`issue-approval-lock-dir`, and `issue-approval-log-dir` — declare
`docs/issue-approval.md` alone, and that is a statement about how the controller
spells them rather than about who owns them. It composes each location segment
by segment —
`account_home() / "Library" / "Application Support" / "kanban" / "issue-approval"`,
and the trees beneath it through a nullary helper each, as
`service_root() / "runtime"` and its siblings — so no tracked source carries any
of those four composed literals for a `files` entry to be grounded in, and the
guide is the one place in this repository where they are written down.

`issue-approval-discovery-record` is the fifth, and the exception: it names
`src/Kanban/ApprovalService.hs` beside the guide. The controller composes that
location exactly as it composes the other four, but unlike them it has a second
consumer — the in-app dashboard §2.8 names — and `approvalRecordPath` there
builds it as one literal joined to the account's home directory. So the record's
spelling *is* carried in tracked source, and the row is grounded in it. Because
the literal is joined rather than absolute it omits the row's leading separator,
so the function writes the row's own spelling out in a comment beside it — the
one place the two forms are reconciled, and a line whose deletion fails the
grounding check rather than quietly unhooking the row from its consumer. The
sibling `issue-review-discovery-record` and `drainer-discovery-record` rows, and
their `-xdg` counterparts, name `src/Kanban/ManagedPaths.hs` on the same terms —
there the literal carries the leading separator, so no reconciling comment is
needed.

What holds the composition to these rows is the Python home-relative-path scan
in `tools/test_agent_workflow_contract.py`, which resolves
`tools/approve_issues_service.py`, `tools/install_issue_approval.py`, and
`tools/service_manager.py` as parsed modules — following a name to its binding
and a helper to its return — and reconciles every chain that reaches a home root
against the `personal-path` tokens here. It is the counterpart of the Haskell and
markdown scans above, over a third surface that spells its paths in neither of
their shapes, and it is what makes each of these five rows load-bearing: change
any one of these locations without changing its row and the scan reports the new
one. `issue-approval-discovery-record` answers to the Haskell scan as well,
since `src/Kanban/ApprovalService.hs` joined that surface: moving the record in
either consumer without changing the row is reported, which is what keeps the
dashboard and the controller from disagreeing about where it is.

That last property needs one rule the literal scans do not have. Those recover
whatever the source wrote down, which is routinely a file *inside* a declared
directory, so a token containing the segment or contained by it both count. The
resolved scan recovers a maximal chain, so every segment it yields is a location
in its own right — and absorbing one into an ancestor's row would make every row
below a declared directory decorative, since renaming `runtime/` to anything at
all would still sit under the service root. So it requires an exact row, keeping
containment in one direction only: a segment a *longer* declared location is
built through — the `~/.config` half of `systemd-user-unit-dir` — is covered by
that location's row, because the complete location still has to match on its
own.

`launchagents-dir` and `systemd-user-unit-dir` are the manager-owned locations
both services' definitions are written into: a LaunchAgent plist under
`~/Library/LaunchAgents`, a user unit under `~/.config/systemd/user`
(`$XDG_CONFIG_HOME/systemd/user` when that variable names an absolute
directory). Both carry `owner: kanban`, on the same footing as
`drainer-launchagent-label`: what lives there is a Kanban-owned convention in
the §5 sense, even though the directory itself is the service manager's rather
than Kanban's. They are declared now because `tools/service_manager.py` builds
both and the scan above reads that module — which is what §2.4 said was still
outstanding. The systemd row's token is the `~/.config` spelling because
that is the one a row's single exact literal can be; the XDG branch resolves to
whatever `$XDG_CONFIG_HOME` names, which no literal can declare. Both are
`tools/service_manager.py`'s alone: it is the only module that may name a
service-manager artifact at all.

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
and the documentation-landing helper below
needs either, and those are optional user-invoked actions. Every one
of the ten resolves its docs worktree by branch with
`git worktree list --porcelain | awk ...`, which is why `awk` is a dependency
of all ten — and of `tools/docs_land.sh`, which resolves its worktrees the
same way; like `find` and `head`, every supported
macOS/Linux shell already provides it. `rg` is the exception: both
`process-report` variants name ripgrep to list a report's finding headings —
inside a fenced block in the Claude command, in prose in the Codex skill — and
both `note-problem` variants name it in prose to locate the implementation an
observation is about. It is the one entry in this manifest that a stock system
may genuinely lack. That costs an installation without it those four workflows'
search step and nothing else, which is what `mandatory: no` records.

`sed-cli`, `tr-cli`, `grep-cli`, `mktemp-cli`, and `dirname-cli` are the
documentation-landing helper's own utilities (issue #410): `tools/docs_land.sh`
resolves its worktrees, formats its occupant reports, and stages its temporary
path lists with them, and it also spawns `git`, `awk`, and `python3` — the
last to reach `tools/docs_land_paths.py`, which itself spawns only `git`. All
are `mandatory: no` because landing documentation is an optional user-invoked
action, and every supported macOS/Linux shell already provides these
utilities.

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
  `tools/kanban_config.py`, the tracked module installed beside the controller
  that both the installer and the installed controller can import.
  `tools/kanban_models.py` is installed beside it too, since issue #483, but it
  writes down no managed location: it reads the model roster from the XDG
  configuration root and nothing else. Its install directory — the discovery record and the
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
  A macOS installation is never moved: its own convention is where it already
  is. On every other platform a `~/Library` installation is moved exactly once,
  by `tools/install_drainer.py` on its next default run. The relocation is
  attempted only when this platform is not macOS — asked as the platform
  question, never inferred from two directories differing — the run's
  destination is this platform's own convention, and the `~/Library` location
  holds a discovery record. `--install-dir` decides that destination and is
  what the installed controller is spawned with, so the relocation resolves its
  own managed paths from that same selection; a custom destination installs
  there and relocates nothing, and an inherited `KANBAN_DRAINER_INSTALL_DIR`
  never decides it. A platform default that resolves to the `~/Library`
  directory itself, because an absolute XDG root names it, is not a reason to
  skip such a host: whether this platform takes an installation over and
  whether taking it over *moves* anything are two questions, and answering the
  first by comparing the two directories reads that host as macOS. Such a run
  takes the installation over in place instead, on the terms below.
  What moves is the whole shared installation, because nothing less of it can
  move on its own: the two discovery records merge with the destination winning
  per key at both the top level and the `repositories` table and the merged
  document is written durably at the destination first; the script links are
  installed there; every recorded repository's runtime tree is carried, found
  through the install directory its *own* definition names, since
  `--install-dir` moves runtime state without moving the record; its log tree
  is carried to the destination log root; and its definition is rewritten from
  the destination's paths and reloaded, since every definition embeds the
  controller path, the install-directory environment, the working directory and
  the log paths, and removing the installation without rewriting them would
  strand every sibling repository. A tree already at its destination is
  preserved in place rather than moved onto itself.
  The whole transition — from the read that decides which repositories exist
  through the removal that takes the controller they name away — runs under the
  legacy record's own lock, which is taken only when something is removed and
  never during a dry run. It also holds, for that whole span, both of the
  locks §2.4 requires a mover to fence on: every recorded checkout's own
  `drain_prs.py` run lock, taken through `drain_prs.acquire_lock`'s dry-run
  shape so it writes nothing into a checkout the installer has no business
  modifying, and every controller lock that already exists at either end of
  each repository's runtime move. The controller lock is the one neither
  liveness signal can see — `run_service` takes it inside its own
  record-locked startup transaction and keeps it for the process's life,
  before it has spawned any drainer, so such a process is neither a managed
  running job nor a holder of the checkout's run lock. Only an existing lock
  file is taken, because creating one would be this run mutating an
  installation it may yet refuse, and none can appear underneath it: acquiring
  that lock needs the discovery record's lock, which this transition holds
  throughout. Reading a PID file is a snapshot,
  and the record locks exclude no drainer at all because a drainer never takes
  them, so without that fence a run starting one instant after the liveness
  check would drain a checkout whose runtime tree was being moved and whose
  controller was being removed — and whatever it wrote would not be in a plan
  computed before it existed. It refuses before mutating anything, and the refusal
  fails the run rather than installing at the destination, when: any recorded
  repository's managed job or checkout drainer is live, or its checkout's run
  lock cannot be taken; a repository appears that the fence does not cover; any recorded entry
  cannot be recovered exactly — its canonical identity, its checkout, this
  host's derived identifier and definition path, and the install directory its
  own definition names; either discovery record is present but unreadable, not
  an object, or has a non-table `repositories`; a distinct source tree would be
  moved onto a destination runtime or log tree that already exists; a
  repository has a runtime tree at the `~/Library` location *and* at the
  install directory its own definition names, which is one repository with two
  runtime trees and one destination; a
  per-repository runtime or log path is present and is not a directory, at
  either end, since carrying one would satisfy "the tree arrived" and strand
  the next controller on it; a path it writes through is not a regular file; or the `~/Library` install directory
  holds an entry this installer did not put there — decided by what an entry
  *is*, with the expected relative name selecting each managed slot and its
  required object type proving ownership, so the five script links must be
  symlinks, the record and its lock plain files, `runtime/` a plain directory,
  and `__pycache__` recognized only when it holds nothing but plain `.pyc`
  files.
  Every mutation registers its undo before it runs, and any failure runs them
  in reverse — definitions restored byte for byte and reloaded, trees moved
  back, the destination record restored, created directories removed while
  empty, modes put back, and the process's managed paths rebound — totally over
  exception types, never abandoning the remaining actions, and reporting what
  it could not undo beside the original failure. A tree move is safe to fail
  partway: a copy that fails takes its incomplete destination with it and
  leaves the source untouched, and a copy that lands makes the destination
  authoritative, so if the source then survives both are kept and reported
  rather than one being chosen. The lock file is never unlinked, because a
  writer may be queued on its inode — which is why the `~/Library` directory
  containing it survives the removal it otherwise completes, and why a marker
  naming the destination is written into that directory before anything is
  taken out of it. A controller bound to the old location cannot re-resolve
  its own managed paths, so that marker is how it learns it is stale; §2.4
  describes the transitions that refuse on it. Removal happens
  only once every recorded repository is usable through the destination.
  Those locks serialize every writer queued on them, so a queued writer fails
  without recording anything: it resumes into a location whose record is gone,
  reads that marker under the same lock, and refuses before it writes. They
  cannot stop one either, only serialize it: a queued writer is guaranteed to
  wake *after* everything done while those locks are held, so it wakes into a
  location whose installation is gone and recreates what it needs there.
  §2.4's write-level gate is what refuses such a writer running *this* code;
  the reconciliation below is what that gate cannot cover, because the
  installed controller a pre-XDG host is running is an older copy that predates
  it — which is the same premise that puts the installation at `~/Library` in
  the first place.
  What answers that writer is not timing but never letting it take the lock.
  A run closes the legacy record's lock file against every opener but its own
  for the whole of its span: it opens its own descriptor, takes the lock on it,
  closes the mode, and keeps that one descriptor rather than reopening a file
  it has closed. The order is the mechanism, not an implementation detail. A
  run that loosened the mode first, so `document_lock` could open the file
  `O_RDWR` the ordinary way, would be handing a stale transition the lock in
  exactly that window — so a closed lock is opened read-only, which it still
  permits, and the mode is only ever loosened by a run that already holds the
  lock. A location an earlier run left closed is where that matters, since it
  is the only one whose lock a later run cannot open the ordinary way at
  all. From
  that instant the set of processes that can ever contend for that lock is
  fixed, and the plan proves it empty immediately afterwards. A run that finds
  it is not empty refuses, before anything has moved — so the process holding
  that descriptor goes on to act against the installation it was invoked
  against, an ordinary transition serialized by this very lock as it always
  was, rather than a stale one acting on a location that moved while it waited.
  A host that cannot be asked is refused on the same terms, since relocating on
  an unanswered precondition leaves the host moved with the question still
  open. That is the prevention this arc selects, and it is available only
  there: once the installation has moved, every answer left is a repair,
  because a service manager's definition directory is the installation's own,
  shared with the job just relocated, and cannot be closed without closing the
  installation.
  So no transition at that location begins while a relocation runs. `install`,
  `start`, `uninstall` and `stop` all enter `document_lock` before they read or
  write anything, as does every discovery-record write, and `document_lock`
  opens that file `O_RDWR` and refuses with `Refusing unsafe config lock path`
  when the open fails. `uninstall_job` is why this matters and not merely
  tidies: it creates no directory at all, so nothing else stands in front of
  the definition it unlinks.
  The reconciliation therefore runs inside that lock rather than handing it
  over, because there is nobody to hand it to. What it is for is the writers
  that never wanted the lock: `ensure_dirs` creates a repository's runtime,
  incident and log trees under no lock at all, and `atomic_write_json` creates
  a missing parent on its own, so a controller bound here can still lay trees
  down right up until the seals go down. Those passes stay bounded, so a writer
  that keeps laying them down ends the sweep rather than holding an installer
  open, and its record half stands as what answers a location that acquired a
  record some other way.
  A run whose final scan finds the location clear closes it. The emptied record
  path and the runtime root are each occupied by a symlink to the relocation
  marker beside them, and the lock keeps the mode it has had since before the
  plan. All three refusals live in code that predates this whole arc, which is
  the only kind that reaches a controller predating it: `update_json_document`
  has refused a record path that is present and not a regular file since the
  commit that introduced the record, `ensure_dirs` cannot make a directory
  beneath a path that is not one, and `document_lock` cannot open a file it has
  no permission to open. So a stale invocation returns non-success before it
  creates, removes or modifies the legacy runtime tree, the legacy log tree,
  the corresponding trees at the destination, or the repository's on-disk
  service definition, and the definition the service manager holds stays the
  relocated one. Every transition that reaches a closed path raises, so every
  one of those returns non-success. Two do not reach one. A `stop` in a copy
  predating #367 enters no transaction at all: it reads its snapshot and, since
  the status file it would read is under the sealed runtime root, finds nothing
  running and returns its "already stopped" result — a read that changes no
  protected artifact and asks the service manager for nothing, so there is
  nothing for a bound to refuse and requiring non-success of it would be
  requiring a filesystem object to change what a read does. That branch is also
  the only one it can take from an emptied location, since a relocation refuses
  outright while any managed job or checkout drainer is running; a stop that
  would signal the manager or write incident state is refused and diagnosed
  like every other transition. `run_service` is the other, and only in part: it
  is what a service manager launches, so it catches its own startup refusals
  and answers with an exit code. A controller from this change onward answers a failing
  one, because a run that reported success would be telling that manager, and
  Kanban reading the job's state through it, that a drainer ran for a
  repository whose installation moved out from under it — and every definition
  this installer writes carries `Restart=no` and `KeepAlive=false`, so that
  failed exit marks the job failed rather than starting a restart loop. A
  controller predating the change answers a clean one, and nothing reaches
  that: no bound outside a process changes what it does with an exception it
  already caught, which is the same limit requirement 4 is stated around. What
  is reachable there is what matters and is guaranteed — it refuses at the
  closed lock, names it, and writes nothing at all.
  Each bound is a fact about the path rather than a permission
  on a directory a stale invocation writes through, because `ensure_dirs`
  chmods the install directory on every attempt and would reset that kind of
  guard on the very invocation it is meant to stop; the lock's own mode is not
  reachable that way, since nothing chmods it but the run that closed it.
  Following either seal finds the marker rather than a document, so a reader
  bound to that location learns where the installation went instead of finding
  an empty one, and the closed lock carries the same notice as its own content
  — written through the run's own descriptor, and readable, since what a
  transition may not do is open it for *writing*. That is the whole
  operator-facing failure available here: a controller predating this arc
  renders a fault as the path it could not use, and the path it names is one of
  these three, so what they lead to carries the rest — that the installation
  was relocated, the legacy location and the destination by name, and the exact
  action that resolves it, which is to run the command again against the
  installation this host now resolves and, where the installed copy predates
  that resolution, to re-run `tools/install_drainer.py` against the
  destination.
  Before it declares the location closed the run asks its last question again:
  it reads the set of processes holding that lock open, out of `/proc` — the
  platform that relocates is the platform that has one, since a relocation
  never happens on macOS and a host with no service manager never reaches one.
  Empty is a proof rather than a hope, since the mode has been closed since
  before the plan and nothing can have joined the set. A set that is not empty,
  and a host that cannot be asked, are both states the run may not call closed:
  the lock stays closed either way, and the run reports which process still
  holds it, or that it could not be ruled out, and fails the install rather
  than telling an operator there is nothing to stop. A process this user may
  not inspect is not one of ours, since the installation, its lock and every
  controller that opens it are user-scoped.
  A location this run could not finish reconciling is deliberately left open,
  because the operator has to see it as it stands and the re-run that follows
  their reconciliation is what closes it; a path that could not be closed at
  all fails the install on the same terms as unresolved state, and is named in
  that failure. Being closed is a reason for a later run to do nothing only
  when every one of those paths is closed and the location holds nothing else:
  a sealed location that still holds trees, or one whose paths an earlier run
  could not close, is planned and reconciled exactly as an unsealed one is,
  which is what stops a seal from making such state permanently invisible. The
  two seals are managed entries no run removes, and neither is reported as a
  stray or as a late write.
  That answer has to survive the run, or the repair it prints is advice the
  re-run ignores. Both seals are objects a later run can see and the lock's
  mode is a bit it can read, but whether the run that closed it was in a
  position to prove nothing could still take it is a question only that run
  could ask — so it writes its answer into the relocation marker beside the
  location, and the disposition reads it there. A location whose marker does
  not say closing finished, and one whose lock has been reopened, are both
  locations a later run acts on; an installation an installer predating this
  bound sealed says nothing either way, which is how such a host is finished.
  What that run performs is not a relocation, since nothing is left to move: it
  is the closing half on its own, over the repositories the destination record
  names, reopening the lock only for as long as it holds it, putting back any
  definition that went missing while the location stood open, and closing and
  recording it once nothing is left holding the lock. Recovering those
  repositories deliberately does not insist on their definitions, unlike the
  recovery a relocation performs: a missing definition is the state this run
  exists to repair, and insisting on one would refuse over exactly that.
  A per-repository tree no record names is carried too. Two things leave one: a
  controller that wrote its trees before a refused record write, and an
  uninstall, which deliberately leaves a repository's runtime state, logs and
  incidents behind. Neither can be recovered *as* a repository, because there
  is no entry to read a checkout, an identifier or a definition out of, and
  neither may be left at a location nothing looks at again — so the roots the
  removal kept are descended into rather than skipped, and what is under them
  is moved to the roots the installation now uses.
  Which repository such a tree belongs to is recovered only from validated
  on-disk evidence, never guessed and never spelled as the directory name. A
  reversible slug is authoritative only when it decodes to a canonical GitHub
  identity *and* re-encoding that identity through the installation's own
  resolver reproduces the slug exactly, which is a host question rather than a
  spelling one: a slug the service manager could not carry as an identifier is
  one this host files under a hash instead. A hash-only slug is attributed only
  from a canonical `repository` field in the tree's own `status.json` or an
  incident document there, with every identity present agreeing and the slug
  derived from it reproducing the directory; a log tree, which carries no such
  document, uses the validated identity of the runtime tree filed under the
  exact same slug. Mutable checkout state and the global service definition are
  never identity evidence. Missing evidence may be supplied by another of those
  sources, but evidence that is present and malformed or that disagrees is
  never skipped past: it, a hash-only slug with no structured identity, and a
  slug this host would spell differently all leave the state where it was
  written, reported by slug and by the reason attribution failed. Every
  repository the report names is a canonical identity — never a slug, and never
  null — and every collision or failure attributable to one names it beside the
  slug the state is filed under, while an unattributed entry carries a null
  repository beside its own slug in the data and renders that slug and reason,
  never the null, in the repair and the failure an operator reads.
  One already at its destination is the collision every other tree's is, kept
  and named rather than chosen between. No fence is taken for such a tree and
  none is available: a repository no record names is one this installation can
  neither discover nor control, so nothing is running it.
  Whoever was waiting takes the lock; it keeps the checkout
  and controller fences the whole time, so no drainer or controller can start
  against a tree it is about to move, and it fences any repository it recovers
  that the transition had not — once per lock, because a second acquisition of
  one this process holds would block against this very process. Each pass
  merges the record found there into the destination's on the same
  destination-wins-per-key terms
  at both levels, carries each runtime and log tree it brought, rewrites and
  reloads every definition it names against this installation, and clears the
  location again on exactly the ownership terms the removal asks: an entry this
  installer did not create is kept and named, and then nothing at that location
  is removed at all. The sweep is bounded rather than looped, at three passes,
  so a writer that keeps taking that lock cannot hold an installer open; one
  that arrives after the final look is past any installer that terminates at
  all, which is the write-level gate's half of this rather than the sweep's.
  A tree a distinct tree already exists at the destination for is the one case
  nothing here resolves: both copies are kept and both are named, per tree
  rather than per repository, so a repository whose runtime collided and whose
  logs did not still has its logs carried and no status file, incident or log
  is chosen between. A repository's runtime tree at the `~/Library` location is
  a source in its own right, asked for independently of the install directory
  its definition names: a run that kept such a tree rewrote that definition to
  the destination, and a plan that asked only what the definition named would
  report success over exactly the tree the remediation told the operator to
  reconcile. Anything left unresolved — a collision, an entry this
  installer did not create, an entry that cannot be recovered, or a writer still
  winning at the bound — preserves the location exactly as it stands and fails
  the install rather than reporting success, naming every affected repository
  and every retained path in the default and `--json` command modes alike. The
  remediation distinguishes the two cases it can be in, because a re-run
  resolves no kept tree — it refuses over exactly the trees it still finds in
  both places and keeps the rest a second time — while a location that merely
  came back with nothing in two places is one a re-run does resolve. The
  installer's own writes — the managed links, the migrated configuration, the
  notification endpoint, and this repository's
  `config_path` entry — are made under the discovery record's lock and behind
  the same staleness refusal §2.4 describes, so a run whose installation moved
  between its import and its writes refuses outright rather than recording into
  a location nothing resolves or handing the installed controller a directory
  that is gone. It ends before the installed controller is spawned, which takes
  that lock in its own process.
  A run whose destination is the location the installation is already at takes
  it over in place. There is one discovery record rather than two, so nothing
  is merged, nothing is removed, no marker is written, and no lock is held
  between two records — with one document the lock such a run would hold is the
  one the installer's own record write goes on to ask for, and that write keeps
  it. What can still be out of date is each repository's definition, since it
  embeds the log paths and the XDG context this host resolves and a pre-XDG one
  carried neither. Staleness is decided per repository, as the bytes
  `render_definition` produces for it against the bytes installed, and against
  the run's *final* install-directory selection: an explicit `--install-dir`
  beats an inherited `KANBAN_DRAINER_INSTALL_DIR` both for the desired bytes
  and for the decision. Exactly the stale definitions are rewritten and
  reloaded, and each such repository's log tree is carried to the log root this
  host resolves — the one managed location `KANBAN_DRAINER_INSTALL_DIR` does
  not pin, so an absolute `$XDG_STATE_HOME` naming `~/Library/Logs` makes that
  root its own destination and the tree is preserved in place rather than
  refused as an occupied one. An installation with nothing stale is not a
  migration: it reports the same nothing-migrated answer a host with no
  `~/Library` installation gets, having read one document, taken no lock, moved
  nothing and created nothing. That answer still carries what the run
  accounted for — which repositories were already current, and which recorded
  entries could not be recovered — and its reason narrows when there is an
  unrecoverable entry, since a definition this run could not read is not one it
  may report as current.
  The guards are scoped to that stale set rather than to every recorded
  repository, and that scoping is load-bearing rather than an optimization:
  they are refusals, so a run that treated a settled sibling as affected would
  refuse an ordinary install whenever any other repository's drainer happened
  to be running. A stale repository is fenced exactly as the relocation fences
  one — its checkout's run lock and any controller lock that already exists,
  under the one record's own lock, which is what keeps a controller from
  taking one underneath the run — and a live drainer, managed job or controller
  for a stale repository refuses before anything is written. A recorded entry
  that cannot be recovered is neither refused nor rewritten: this run takes
  nothing apart, so an entry it cannot recover is one it cannot show to be
  affected, and the repository is left exactly as it stands and named in the
  report — in the nothing-migrated answer as much as in a takeover's, since
  that is the run such an entry is most likely to be the whole of. Every mutation registers its undo first on the same terms as the
  relocation's, so a failure puts every definition and every tree back and
  removes the log root it created. `--dry-run` reports the whole takeover, or
  the nothing-migrated answer, without taking a lock.
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
  are resolved by both native resolution points: `tools/kanban_config.py` and
  every component that imports it — `tools/approve_issues.py`,
  `tools/install_issue_review.py`, `tools/setup_workflows.py`, and
  `tools/approve_issues_service.py` — and `src/Kanban/ManagedPaths.hs`, which
  is where the Haskell side's record location is now resolved and the only
  place either platform's spelling of it is written down on that side. The
  twelve vendored plugin assets listed above probe the same two record
  locations in the same order since issue #445, so an XDG-defaulted install is
  discovered on every host, but they reach that answer without importing
  either resolution point: neither a `bash` fence nor the Codex bundle's
  per-skill vendoring can, so each spells the two literals itself and §4's two
  record rows declare all twelve against both. One difference from the
  resolvers is deliberate: with *neither* record occupied a packaged asset
  resolves the XDG candidate on every platform and reports both locations as
  consulted, rather than branching to this platform's write default, because
  nothing it can execute should have to decide which platform it is on.
- **The issue approval service follows the same policy with one deliberate
  difference.** Its footprint is the `kanban/issue-approval` namespace, its job
  identifiers and definition paths are derived through the same
  `tools/service_manager.py` boundary from the same normalized canonical
  identity, and its record is likewise a fixed location `--install-dir` cannot
  move. What differs is the per-platform half: the drainer's three managed
  locations take each platform's own convention, while this service's take
  macOS's on every platform — `tools/approve_issues_service.py` resolves its
  service root and log root from the account's passwd home directory with no
  XDG rule at all, and its runtime root and locks are siblings of the record
  rather than living under the install directory, so `--install-dir` and
  `KANBAN_ISSUE_APPROVAL_INSTALL_DIR` move the script links alone. The
  definition directories are the exception in the other direction: they are the
  service manager's, resolved through `Path.home()` and, on systemd,
  `$XDG_CONFIG_HOME`, so a redirected environment relocates them with nothing
  opted into. A custom link directory spelled with `~`
  expands through `$HOME` too, but only because an operator named it that way,
  and the record, runtime tree, locks and log root never do.
  Only the
  systemd unit location is XDG-aware, because that is systemd's own rule about
  where it searches. Bringing those two roots onto this section's per-platform
  convention is outstanding work of the same portability arc, and until then
  one spelling is the whole declaration — see §2.8 and the `issue-approval`
  rows in §4.
- **User-scoped installation is explicit and opt-in.** Nothing in Kanban's
  build (`cabal build all`) or normal startup path installs either managed
  service's job or the issue-review backend's stable link; each installed
  definition is
  loaded but never started, never enabled, and carries no `[Install]` section
  on systemd, so no login brings a drainer or an approval service up on its
  own; the backend is only
  installed by running `tools/install_issue_review.py`, or
  `tools/setup_workflows.py --component issue-review --apply`, directly,
  and neither starts a daemon. The approval service has no
  `tools/setup_workflows.py` component at all, by design: it is installed only
  by running `tools/install_issue_approval.py` for one repository.
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
  `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, `KANBAN_ISSUE_REVIEW_NTFY_URL`, and the
  four `APPROVE_ISSUES_*_MODEL` / `APPROVE_ISSUES_*_EFFORT` overrides §2.3
  documents are optional environment overrides with no tracked default value,
  not required configuration.
- **A new tracked module under `tools/` does not reach a live install by
  itself.** Both service installations link a fixed module set beside the
  script they install, resolved when that install was made, so a module added
  to either set requires rerunning its installer —
  `python3 tools/install_drainer.py` for the PR drainer, and
  `python3 tools/install_issue_review.py` for the canonical issue-review
  backend (`tools/install_issue_approval.py` deliberately installs no backend
  of its own; it resolves and verifies the one that installer made). Until
  then the installed script fails at import against the module set it was
  installed with. Issue #483's `tools/kanban_models.py` joined both sets.

## 6. Completeness check

`tools/test_agent_workflow_contract.py` (discovered by
`python3 -m unittest discover -s tools -p 'test_*.py'`, which CI already
runs) parses the manifest in §4 and:

- fails if the solve, PR-flow, canonical-review, shared provider/process, or
  issue-approval-dashboard source files (`src/Kanban/Solve.hs`,
  `PullRequestFlow.hs`, `Preflight/Environment.hs`, `Review.hs`,
  `Review/Canonical.hs`, `Review/Tools.hs`, `Codex.hs`, `Claude.hs`,
  `GitHub/Run.hs`, `Repository.hs`, `Drainer.hs`, `ManagedPaths.hs`,
  `ApprovalService.hs`, `Process.hs`) invoke a literal external command that
  has no matching `executable` manifest entry — `GitHub/Run.hs` rather than
  `GitHub.hs`
  because the split in #160 left `Kanban.GitHub` a re-export façade and moved
  the `gh` spawn into `Kanban.GitHub.Run`, which is the only module under
  `src/Kanban/GitHub/` that resolves or starts an executable;
  `ManagedPaths.hs` because the two managed discovery records' locations moved
  there out of `Drainer.hs` and `Review/Canonical.hs`, which is what the
  bullet below has to see them in; and `ApprovalService.hs` because it is the
  §2.8 dashboard, which the same bullet has to see the issue-approval discovery
  record in and which resolves `launchctl` and `systemctl` for its
  host-backend detection. That list is exhaustive for `src/` over the call
  shapes these extractors recognise — a literal name passed to
  `proc`/`findExecutable`/`readProcessWithExitCode`, a literal name passed to
  `Kanban.Drainer`'s timed `runProcess` helper, a `findExecutable` argument a
  `case` or `if` binds to string literals, and a location spelled as one
  literal hung off a `getHomeDirectory` result. Four other modules call one of
  those functions and are deliberately out, because none of them writes a name
  or a path any extractor could recover: `ServiceProcess.hs`,
  `UsageCommand.hs`, and `Worker.hs` are spawn helpers that pass `proc` an
  executable *value* their caller computed, and `Ping.hs` resolves
  `findExecutable (pingExecutableName brand)`, whose argument is a
  two-equation top-level function rather than the `case`/`if` binding the
  indirect extractor reads, and builds its scratch directory with
  `getXdgDirectory` rather than `getHomeDirectory`. Listing any of the four
  would add a member the extractors recover nothing from, which is a surface
  entry that scans nothing rather than coverage; the `codex` and `claude` that
  `Ping.hs` and `Worker.hs` ultimately run carry `executable` rows grounded in
  the scanned modules that do spell them;
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
  real ones. That discovered surface is executable-only; the home-relative
  paths a `tools/` module builds are reconciled only for the three named in
  the next bullet;
- fails if `tools/approve_issues_service.py`,
  `tools/install_issue_approval.py`, or `tools/service_manager.py` — §2.8's
  owning sources — builds a home-relative path that has no matching
  `personal-path` manifest entry. These are Python, so they need an extractor
  of their own beside the Haskell one, and it resolves the parsed module rather
  than matching text, because the shape it has to recover is not local to one
  expression: `root / "systemd" / "user"` reaches a home root only through a
  binding a line earlier, and `service_root() / "runtime"` only through a
  nullary helper, so an extractor that stopped at either would recover a
  prefix and let an undeclared tail past. It follows both, recognizes a home
  root as `account_home()`, `Path.home()`, a `HOME` name, an `os.environ` read
  of one, or an `expanduser()` call, and also recovers a `~/`- or
  `$HOME/`-prefixed literal, joining the result into the same slash-prefixed
  shape the Haskell and markdown scans compare. Quote style and line wrapping
  are not distinctions the parsed tree makes. What it recovers from each of the
  three is pinned, so a refactor that stops matching fails here rather than
  passing with an empty discovered set — including the pin that the installer
  builds none of its own — and fixture regressions prove that an undeclared
  segment is reported, that a tail hung off a binding or a helper is recovered
  whole, that a location beneath a declared root is not absorbed into that
  root's row, and that a module which cannot be parsed fails rather than
  reporting nothing. Because what it recovers is a maximal chain rather than
  whatever a source happened to write, it reconciles more strictly than the two
  scans above: an exact row, or a row whose location this segment is built
  through. This surface is an enumerated list rather than every
  module under `tools/`, so extending it to another module is a deliberate
  edit;
- fails if any of the nine drafting, canonical issue-review, and
  issue-rereview assets declared in
  [drafting-workflow-contract.md §2](drafting-workflow-contract.md#2-declared-assets)
  names a `$HOME/`- or `~/`-prefixed path with no matching `personal-path`
  manifest entry. All nine are scanned for external commands too; the bash
  fence extractor simply yields nothing for a prose-only contract, so an asset
  with no executable surface is covered rather than exempted;
- fails, identically, for the ten design and report document workflows
  declared in
  [document-workflow-contract.md §2](document-workflow-contract.md#2-declared-assets),
  and additionally fails if that document declares an asset no plugin surface
  list scans, or if the commands recovered from one of those ten stop matching
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
  shared label prefix described above, not the plist file. The plist's own
  directory now has a row of its own — `launchagents-dir`, beside
  `systemd-user-unit-dir` — added when the scan above reached
  `tools/service_manager.py`; both stay `kanban`-owned, because §5 keeps what
  Kanban writes there a Kanban-owned convention rather than a personal path.

Both machine-readable fences in this document are parsed anchored to their own
heading — §4's to `## 4. Dependency manifest` and §7's to
`## 7. Document publication classification` — so neither parser can capture the
other's rows, and a third fence added later cannot silently displace either.

## 7. Document publication classification

Every tracked Markdown file in this repository takes exactly one publication
lane:

- `coordination` — a coordination record whose content no runtime, installer,
  or test reads: a findings, code-health, or design document and its status
  ledger, or a free-form note or roadmap sketch under a declared coordination
  directory.
  Eligible for direct publication to `master`, bypassing the pull-request lane.
- `pr-atomic` — a document that lands atomically with its implementation
  through the pull-request lane, because changing it on its own can invalidate
  the tree.

Anything unclassified is `pr-atomic` to every consumer. An unknown document is
never direct-master eligible: the table below is an allowlist for the
`coordination` lane alone, so a tracked Markdown file matching no row is a
check failure rather than a document that publishes directly.

The `coordination` documents are
`docs/card_filter_design.md`, `docs/claude_document_workflows_design.md`,
`docs/code-health-report.md`, `docs/document_workflow_findings.md`,
`docs/drainer-bugs.md`, `docs/gh_record_authority_design.md`,
`docs/issue_approval_queue_design.md`, `docs/issue_search_design.md`,
`docs/linux_portability_design.md`, `docs/managed_paths_design.md`,
`docs/model_settings_design.md`,
`docs/multi_repo_boards_design.md`,
`docs/overlay_focus_fullscreen_design.md`,
`docs/pipeline-hardening.md`, `docs/product_readiness_findings.md`,
`docs/project_review_183-170.md`, `docs/project_review_195-185.md`,
`docs/project_review_218-196.md`, `docs/project_review_244-219.md`,
`docs/project_review_271-251.md`,
`docs/project_review_297-272.md`, `docs/project_review_314-299.md`,
`docs/project_review_342-317.md`, `docs/project_review_386-361.md`,
`docs/project_review_442-411.md`, `docs/project_review_456-446.md`,
`docs/project_review_463-455.md`,
`docs/public_release_design.md`, `docs/superagent_design.md`,
`docs/ui-bugs.md`, `docs/usage_awareness_design.md`,
`docs/workflow_audit_findings.md`,
`docs/workflow_command_vendoring_design.md`, and — through its directory row,
with no declaration per file — every tracked Markdown file under
`docs/coordination/`. **Every other tracked
Markdown file in this repository is `pr-atomic`.** Those two sentences are the
human-readable answer to "which lane does this document take", and
`tools/test_document_classification.py` reconciles them against the rows below,
so placing a known document never requires reading the machine-readable table.

This classification is Kanban's own. It describes this repository and nothing
else. A consuming repository declares its own coordination paths through the
drainer configuration key `workflow.coordination_paths`
([pr-drainer.md](pr-drainer.md#merging-past-a-coordination-only-base-advance)),
which ships empty — exact file paths, or whole directories through a
trailing-slash entry matched by the same whole-component rule the rows below
use; Kanban never infers a consuming repository's classes from
file extension or directory, and never applies the rows below to another
repository's tree.

Machine-readable; parsed verbatim by `tools/test_document_classification.py`.
Columns: `path | class | reasons`.

A row naming a directory ends with `/` and covers the tracked Markdown files
beneath it, matched by whole path component rather than by string prefix: the
`codex-plugin/` row covers
`codex-plugin/plugins/kanban/skills/solve/SKILL.md` and never a sibling
directory such as `codex-plugin-old/`, just as the `docs/coordination/` row
covers `docs/coordination/scratch-note.md` and never
`docs/coordination-old/scratch-note.md`. That component boundary is the point
of a directory row — it is a statement about one tracked component, not about
every name that happens to begin the same way. Non-Markdown files beneath a
declared directory are outside this classification entirely: it classifies
documents, not bundle assets.

Two consumers deliberately read a directory declaration more widely than this
classification does: a trailing-slash entry in
`tools/test_source_distribution.py`'s `EXCLUDED_TRACKED_PATHS` and in
`workflow.coordination_paths` covers every tracked descendant whatever its
extension, because what ships in a release archive and what a base advance
touched are questions about files rather than documents. The rows below stay
a statement about tracked Markdown alone, and the configuration
reconciliation in `tools/test_document_classification.py` compares coverage
over exactly that subject, so the difference is a recorded decision rather
than drift between the row and the configuration. Because that comparison
cannot see an entry covering no tracked Markdown at all, the reconciliation
also holds every configured entry to being one of the coordination
declarations below: a configured `src/` would be invisible to both the
coverage and the test-parsed checks while the drainer honoured it for every
file beneath `src/`, and is reported instead.

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
  `EXCLUDED_TRACKED_PATHS`.
- `coordination-note` — a free-form note, roadmap sketch, or other
  non-authoritative coordination document whose content no runtime,
  installer, or test reads, covered by an `EXCLUDED_TRACKED_PATHS`
  declaration the same way. `audit-report` and `coordination-note` are the
  only reasons that admit the `coordination` lane, and neither is valid on a
  `pr-atomic` row.

```text
.github/ISSUE_TEMPLATE/ | pr-atomic | test-parsed
.github/pull_request_template.md | pr-atomic | test-parsed;release-document
AGENTS.md | pr-atomic | release-document;implementation-coupled
CHANGELOG.md | pr-atomic | release-document
CLAUDE.md | pr-atomic | release-document;implementation-coupled
CONTRIBUTING.md | pr-atomic | release-document
README.md | pr-atomic | release-document
SECURITY.md | pr-atomic | release-document
claude-plugin/ | pr-atomic | test-parsed;release-document
codex-plugin/ | pr-atomic | test-parsed;release-document
docs/README.md | pr-atomic | release-document
docs/agent-workflow-contract.md | pr-atomic | test-parsed;release-document;implementation-coupled
docs/bugs.md | pr-atomic | release-document
docs/card_filter_design.md | coordination | audit-report
docs/claude_document_workflows_design.md | coordination | audit-report
docs/code-health-report.md | coordination | audit-report
docs/coordination/ | coordination | coordination-note
docs/design.md | pr-atomic | test-parsed;release-document;implementation-coupled
docs/development.md | pr-atomic | release-document
docs/document-workflow-contract.md | pr-atomic | test-parsed;release-document
docs/document_workflow_findings.md | coordination | audit-report
docs/drafting-workflow-contract.md | pr-atomic | test-parsed;release-document
docs/drainer-bugs.md | coordination | audit-report
docs/gh_record_authority_design.md | coordination | audit-report
docs/issue-approval.md | pr-atomic | release-document
docs/issue_approval_queue_design.md | coordination | audit-report
docs/issue_search_design.md | coordination | audit-report
docs/linux_portability_design.md | coordination | audit-report
docs/managed_paths_design.md | coordination | audit-report
docs/media/README.md | pr-atomic | test-parsed;release-document
docs/model_settings_design.md | coordination | audit-report
docs/multi_repo_boards_design.md | coordination | audit-report
docs/overlay_focus_fullscreen_design.md | coordination | audit-report
docs/pipeline-hardening.md | coordination | audit-report
docs/pr-drainer.md | pr-atomic | release-document
docs/product_readiness_findings.md | coordination | audit-report
docs/project_review_183-170.md | coordination | audit-report
docs/project_review_195-185.md | coordination | audit-report
docs/project_review_218-196.md | coordination | audit-report
docs/project_review_244-219.md | coordination | audit-report
docs/project_review_271-251.md | coordination | audit-report
docs/project_review_297-272.md | coordination | audit-report
docs/project_review_314-299.md | coordination | audit-report
docs/project_review_342-317.md | coordination | audit-report
docs/project_review_386-361.md | coordination | audit-report
docs/project_review_442-411.md | coordination | audit-report
docs/project_review_456-446.md | coordination | audit-report
docs/project_review_463-455.md | coordination | audit-report
docs/public_release_design.md | coordination | audit-report
docs/superagent_design.md | coordination | audit-report
docs/ui-bugs.md | coordination | audit-report
docs/usage_awareness_design.md | coordination | audit-report
docs/user-guide.md | pr-atomic | release-document
docs/workflow-setup.md | pr-atomic | release-document
docs/workflow_audit_findings.md | coordination | audit-report
docs/workflow_command_vendoring_design.md | coordination | audit-report
tools/ | pr-atomic | test-parsed;release-document
```

The ten `test-parsed` rows name what actually parses them:
`tools/test_issue_templates.py` reads the frontmatter, headings, and `Children`
checklist of both templates under `.github/ISSUE_TEMPLATE/`,
`tools/test_pull_request_template.py` and `test/Spec/Agent/PullRequestFlow.hs`
read `.github/pull_request_template.md` and run the three parsers that route on
a pull-request origin marker over it, so a marker pasted into that template's
explanatory comment fails `build-test` rather than routing every agent-authored
pull request to both brands,
`tools/test_agent_workflow_contract.py` reads §4 of this document (and
`tools/test_document_classification.py` reads §7),
`test/Spec/UI/Keys.hs` reads the binding table in `docs/design.md` §7,
`tools/test_document_workflow_contract.py` and
`tools/test_drafting_workflow_contract.py` read their own contracts' §2 asset
tables, `tools/test_board_screenshot.py` reconciles the regeneration procedure
in `docs/media/README.md` against the renderer's own constants,
`tools/test_claude_plugin.py` and `tools/test_codex_plugin.py` read
the frontmatter and body of every packaged workflow under `claude-plugin/` and
`codex-plugin/`, and `tools/test_render_command_sources.py` reads the authored
command sources under `tools/command_sources/` and byte-compares the Markdown
rendered from them.

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
- fails if a `coordination` row cites any reason outside `audit-report` and
  `coordination-note`, or if a `pr-atomic` row cites either of those reasons;
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
