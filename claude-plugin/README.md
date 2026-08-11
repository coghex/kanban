# Kanban Claude plugin

This directory is a Claude Code marketplace, tracked in this repository, that
packages the Claude-side workflows Kanban invokes by name — `/solve`,
`/pr-review`, `/pr-rereview`, `/pr-revise`, and `/repair` — plus the issue-drafting and
canonical issue-review workflows a user or the review daemon invokes directly:
`/issue`, `/draft-issues`, `/autoissue`, and `/issue-review`. Since issue #229
it also packages `/process-report`, the one design/report document workflow
with a Claude counterpart. It exists so a
clean Claude Code installation can perform these actions without depending on
any developer's personal command collection. See
[docs/agent-workflow-contract.md](../docs/agent-workflow-contract.md) for the
full dependency contract these workflows implement, including the
`solve`/PR-flow authority boundaries and the canonical issue-review backend
they call into,
[docs/drafting-workflow-contract.md](../docs/drafting-workflow-contract.md)
for the drafting and issue-review responsibility matrix, and
[docs/document-workflow-contract.md](../docs/document-workflow-contract.md)
for the design and report document responsibility matrix. See
[codex-plugin/](../codex-plugin/README.md) for the equivalent Codex-side
packaging.

## Install

`claude plugin marketplace add` and `claude plugin install` both accept a
`--scope` flag (`user`, `project`, or `local`) controlling where the
resulting registration is declared. Kanban spawns `/solve`, `/pr-review`,
`/pr-rereview`, and `/pr-revise` with the *target* repository — the one
selected by `--path`, not necessarily a checkout of this repository — as the
working directory, so which scope to use depends on where that
registration needs to be discoverable from:

**Project scope, declared in the Kanban-selected repository itself.** From
the repository Kanban is pointed at (the one you actually want `/solve` and
friends available in — this can be a checkout of this repository, or any
other project Kanban manages via `--path`), add the marketplace and install
the plugin, substituting the path to your own checkout of this repository:

```console
claude plugin marketplace add /path/to/kanban/claude-plugin --scope project
claude plugin install kanban@kanban --scope project
```

This writes `.claude/settings.json` in the *target* repository (the
project-scope Claude Code convention for settings meant to be shared with
that project's team), declaring the marketplace and enabling the plugin
specifically for sessions started from that repository. Verified directly:
running the two commands above from a freshly initialized, unrelated
scratch repository (no relation to this repository) produces a
`.claude/settings.json` there with `"enabledPlugins": {"kanban@kanban":
true}`, and `claude plugin details kanban@kanban` run from that same
repository lists every packaged command. The embedded marketplace path is
specific to the machine and checkout it was added from, the same caveat
[codex-plugin/](../codex-plugin/README.md) documents for its own
git-sourced install form; commit the resulting `.claude/settings.json` to
a target repository's own tracking only if every contributor keeps this
repository at that same path, or use `--scope local` instead to keep the
registration out of that repository's tracked settings entirely.

**User scope (the default), declared once for every Claude Code session.**
From a checkout of this repository:

```console
claude plugin marketplace add ./claude-plugin
claude plugin install kanban@kanban
```

Both commands default to `user` scope when `--scope` is omitted. A
`user`-scope install is recorded once in your own Claude Code configuration
and resolved independently of the invoking working directory, so it covers
every repository Kanban might point `--path` at without a separate install
per target repository. Verified directly: after a default install from this
checkout, `claude plugin details kanban@kanban` run with the working
directory set to an unrelated scratch directory (no relation to this
repository, and not separately configured) still lists every packaged command
under `kanban@kanban`, and `claude plugin list --json` shows the install
with no `projectPath` tying it to this checkout.

Either form's manifest lives at
`claude-plugin/.claude-plugin/marketplace.json`, so the local-path forms
above are the verified, supported install paths from a checkout. Installing
is never automatic, matching the portable-install policy in
[docs/agent-workflow-contract.md §5](../docs/agent-workflow-contract.md#5-portable-install-policy).

Verify discovery:

```console
claude plugin list
```

`kanban@kanban` should be listed, and all ten workflow names should be
available as `/solve`, `/pr-review`, `/pr-rereview`, `/pr-revise`, `/issue`,
`/draft-issues`, `/autoissue`, `/issue-review`, `/repair`, and
`/process-report`.

Verified against Claude Code `2.1.216` (`claude --version`), the version
that provides the `claude plugin` / `claude plugin marketplace` subcommand
family this install path depends on. An older Claude Code release without
those subcommands cannot install this plugin.

## What's packaged

Kanban's own CLI spawns five of these by name: the first four, plus `/repair`,
which `r` selects for a Done pull request whose status is a problem (issue
#127). The other five are drafting, readiness-gate, and document workflows a
user or the review daemon invokes directly; see
[docs/drafting-workflow-contract.md](../docs/drafting-workflow-contract.md) and
[docs/document-workflow-contract.md](../docs/document-workflow-contract.md).
`/repair` is not part of either declared surface. Only those five are excluded
from the Haskell invocation-parity pinning in `tools/test_claude_plugin.py`,
which covers exactly the names Kanban's own code spawns.

| Command | Invocation | Boundary |
| --- | --- | --- |
| `commands/solve.md` | `/solve` | Claims an issue, implements it in an isolated worktree, opens a PR. Stops after opening the PR; never reviews or merges. |
| `commands/pr-review.md` | `/pr-review` | Review-only. Runs the canonical issue-gated, opposite-brand (or dual, for unknown origin) review and publishes one verdict. Never edits, labels beyond the verdict, or merges. |
| `commands/pr-rereview.md` | `/pr-rereview` | Same as `/pr-review` for a changed PR; also removes a lingering `reviewed:revised` label after publishing, the one label mutation Kanban's own invocation prompts require of a review-only workflow. |
| `commands/pr-revise.md` | `/pr-revise` | Repairs a `reviewed:changes` PR in an isolated worktree, pushes safely, then hands off to exactly one canonical rereview. Never self-approves or merges. |
| `commands/issue.md` | `/issue` | Finds, verifies, and deduplicates **exactly one** candidate and drafts it to hand-off quality. Stops for explicit signoff; never creates without it. |
| `commands/draft-issues.md` | `/draft-issues` | The **breadth** counterpart: surveys many candidates repo-wide, stops to ask which to create, then expands only those to the same bar. Claude-only — there is deliberately no Codex equivalent. |
| `commands/autoissue.md` | `/autoissue` | Delegates drafting to `/issue`, and on signoff creates the issue and immediately runs `/issue-review` with no second confirmation. Stops without reviewing if drafting stops before creation. |
| `commands/issue-review.md` | `/issue-review` | Runs the canonical opposite-agent readiness gate for one numbered issue through the portable backend. Never drafts, creates, or posts a competing verdict. |
| `commands/repair.md` | `/repair` | Diagnoses why a pull request cannot merge — merge conflict, any failed check, or a blocking label, in `pullRequestStatus` order — repairs it in the worktree already on the PR's head branch, pushes without force, and hands off to exactly one canonical rereview. Never merges, closes, or sets a verdict label; never removes a blocking label without asking. |
| `commands/process-report.md` | `/process-report` | Processes **exactly one** finding per invocation from an existing findings report: verify, deduplicate, recommend one disposition, stop for approval, then mark the report. The report file is the durable cursor, so a fresh session resumes in the right place. |

`/process-report` is user-invoked only. Kanban's CLI never spawns it, because
it has a mandatory human approval stop in the middle; see
[docs/document-workflow-contract.md §5](../docs/document-workflow-contract.md#5-one-artifact-per-invocation-and-the-approval-stop).
Its status markers are a cross-brand compatibility surface rather than local
formatting: `$process-report` in [codex-plugin/](../codex-plugin/README.md) is
its counterpart, the two variants may differ in wording, and a report started
under either brand must be resumable under the other.

No `epic` command is packaged: arc decomposition — planning a user-supplied
feature arc rather than independently hunting for discretionary work — belongs
to the `design-epic`/`process-design-doc` pipeline (see the
[document-workflow contract](../docs/document-workflow-contract.md)) and is
not part of this drafting contract. The personal `/epic` command that once
created epic trees directly was retired 2026-08-11 in that pipeline's favor.

Three document workflows are deliberately not packaged here either.
`design-epic`, `process-design-doc`, and `draft-report` are **Codex-only** — a
declared gap rather than an oversight, because authoring Claude counterparts
would be new behavior no pinned source defines, which the SHA-pinned vendoring
model of issue #118 refused to do. The asymmetry runs opposite to the
Claude-only `/draft-issues` boundary above, and is recorded the same way rather
than closed; see
[docs/document-workflow-contract.md §3.5](../docs/document-workflow-contract.md#35-declared-codex-only-asymmetry).

`pr-review`, `pr-rereview`, `pr-revise`, and `repair` all delegate publication
to the bundled coordinator at `scripts/review_pr.py`. Claude Code exposes
`${CLAUDE_PLUGIN_ROOT}` inside a plugin's own commands, so each command
resolves the coordinator directly at `${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py`
without depending on where the plugin happened to be installed, and without
depending on the [Codex plugin](../codex-plugin/README.md) being installed at
all — this plugin bundles its own copy of the same coordinator logic so it is
fully self-sufficient on a Claude-only machine. The same `pr-review:v2`
marker/label state machine runs regardless of which command an agent session
starts from. The coordinator resolves the canonical issue-review backend the same way
`Kanban.Review.resolveCanonicalIssueReviewer` does: a non-empty
`KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then the backend path
`tools/install_issue_review.py` recorded in
`~/Library/Application Support/kanban/issue-review/config.json`, then — only
when that record names none — the directory the record lives in; it never
hard-codes a personal path and never reconstructs the installer's default. None of the packaged commands set their own
model, reasoning effort, permission mode, or working directory — Kanban's own
CLI invocation pins those per action, and `tools/test_claude_plugin.py`
asserts none of the packaged manifests override them.

`/solve` bundles a second script, `scripts/trusted_issue_spec.py`, and reads the
issue's effective spec through nothing else. It fetches the complete paginated
comment timeline and exposes a comment body only for the exact, case-insensitive
logins `claude`, `codex`, and `coghex`; every other comment comes back as
metadata alone, so an untrusted body never enters the solving session's context.
Repository role, `author_association`, issue authorship, display name, and bot
status grant nothing, and the set is hardcoded, so widening it costs a reviewed
pull request. `/solve` resolves the helper at
`${CLAUDE_PLUGIN_ROOT}/scripts/trusted_issue_spec.py`, so it needs no filesystem
search and no Codex plugin, exactly like the coordinator above. The trust rule
and its deliberate divergence from the reviewer gate's association-based
arithmetic are recorded in
[docs/agent-workflow-contract.md §2.1](../docs/agent-workflow-contract.md#21-issue-solve-solve--solve).

`/issue-review` — and `/autoissue`'s immediate review handoff — resolve the
same canonical backend the same portable way, through the discovery record at
`~/Library/Application Support/kanban/issue-review/config.json` that
`python3 tools/install_issue_review.py` writes from a Kanban checkout.
They never reference the pre-migration compatibility launcher described in
[docs/agent-workflow-contract.md §3](../docs/agent-workflow-contract.md#3-migration-boundary),
and they never pin a reviewer model or display name:
selecting the opposite-agent reviewer is the backend's job, and its own
default already resolves the canonical one. The personal model pins carried by
the pre-vendoring sources were dropped for exactly that reason.

For known-origin `/pr-review`/`/pr-rereview` — the case Kanban's own
invocation always produces — the calling session already *is* the
correctly-pinned canonical reviewer, so it reviews directly and uses the
coordinator (`--self-review`) only for safe publication; no nested reviewer
is spawned, and this coordinator still cannot verify which model actually
ran that top-level session (that pin happened outside its visibility), so
it publishes `models=unspecified` for this path, matching
[docs/agent-workflow-contract.md §2.2](../docs/agent-workflow-contract.md#22-pr-review-rereview-and-revise).
Only the cross-brand handoffs of `pr-revise` and `repair` (each runs on the
PR's own origin brand but must hand off to the opposite brand) and the rare dual-review
fallback for unknown/external origin — which Kanban's own invocation never
triggers — spawn a nested `codex`/`claude` reviewer. Unlike the
self-reviewed path, this coordinator fully constructs that nested
subprocess call itself, so — for this plugin's bundled coordinator only,
per a round-2 review finding on issue #77 — it pins that nested reviewer to
the same canonical `gpt-5.6-terra`/`claude-opus-5` at `xhigh` values
`src/Kanban/PullRequestFlow.hs` already uses for Kanban's own top-level
review invocation, and binds the verified model in the published
`pr-review:v2` marker instead of `unspecified`. This is a deliberate,
reviewed divergence from §2.2's general "brand only, no pinned model"
policy for this one nested-spawn path, and from
[codex-plugin/](../codex-plugin/README.md)'s otherwise-identical
coordinator copy, which still leaves it unpinned; see
`CODEX_NESTED_REVIEW_MODEL`/`CLAUDE_NESTED_REVIEW_MODEL` in
`scripts/review_pr.py` for the exact values. Dual review runs its two
reviewers strictly one at a time, each in its own unpredictably-named,
read-only temp directory torn down before the next begins — never two
reviewers' source trees on disk at once.

## Structural and contract coverage

`tools/test_claude_plugin.py` (run by
`python3 -m unittest discover -s tools -p 'test_*.py'`, which CI already
runs) checks that:

- the marketplace and plugin manifests are valid and point at this
  directory;
- the commands directory contains exactly the ten packaged workflows, and
  the five Kanban spawns exactly match the `/`-prefixed tokens
  `src/Kanban/Solve.hs` and `src/Kanban/PullRequestFlow.hs` actually spawn —
  two separate assertions, since Kanban's Haskell code must *not* spawn the
  four drafting commands or `/process-report`;
- the three Codex-only document workflows have no counterpart here, keeping
  the declared asymmetry;
- no packaged manifest sets model/effort/permission-mode/working-directory
  configuration, and every packaged command — drafting commands included —
  declares a `description:` and no forbidden frontmatter key;
- no packaged asset references a personal absolute path or the pre-migration
  compatibility launcher path (see
  [docs/agent-workflow-contract.md §3](../docs/agent-workflow-contract.md#3-migration-boundary));
- the bundled coordinator resolves the canonical issue-review backend the
  same way Kanban's Haskell code does, and its self-test passes standalone;
- the coordinator's nested-reviewer model/effort pin matches the exact
  values `src/Kanban/PullRequestFlow.hs` uses for Kanban's own review
  invocation, so the two cannot silently drift apart.

`tools/test_agent_workflow_contract.py` reconciles this plugin's own bash
surface (all ten commands under `claude-plugin/plugins/kanban/commands/`) and
both bundled Python assets — the review coordinator and `/solve`'s
trusted-comment helper — against the same manifest in
[docs/agent-workflow-contract.md §4](../docs/agent-workflow-contract.md#4-dependency-manifest)
that the Codex plugin and Kanban's Haskell source are reconciled against,
including the user-scoped backend install path the drafting and issue-review
commands name and the `git`/`awk`/`gh`/`rg` commands `/process-report` resolves
its docs worktree, tracker state, and finding headings with.

`tools/test_trusted_issue_spec.py` pins that helper against its Codex
counterpart — the two copies must stay byte-identical — and drives both over
every signal that must grant no comment body, proving no untrusted body or
body-derived content survives serialization and that each copy resolves from its
own installed bundle while the working directory is the repository being solved.

`tools/test_repair_workflow_contract.py` pins `/repair`'s own behavioral
contract — the ordered diagnosis branches, worktree selection and safe push,
the never-merge/never-label authority limits, and the exactly-one-rereview
handoff — against both this command and its Codex counterpart, so the two
brands' copies cannot diverge.

`tools/test_drafting_workflow_contract.py` reconciles the four drafting
commands against the responsibility matrix in
[docs/drafting-workflow-contract.md](../docs/drafting-workflow-contract.md):
every declared asset must exist, no undeclared drafting command may appear,
the exact `<!-- issue-origin:claude -->` marker literal must be present in each
issue-creating command, and the Claude-only `/draft-issues` and unpackaged
arc-decomposition boundaries must remain stated. It also pins the optional
scope gate
([docs/drafting-workflow-contract.md §4](../docs/drafting-workflow-contract.md#4-scope-gate)):
`/issue`, `/draft-issues`, and `/autoissue` must state the same gate and
exemption rules as the document, each gate instruction must follow the guard
that makes it apply only when the consuming repo declares a gate, and
`/issue-review` must stay free of gate language.

`tools/test_document_workflow_contract.py` does the same for `/process-report`
against
[docs/document-workflow-contract.md](../docs/document-workflow-contract.md):
every declared asset must exist, no undeclared design or report workflow may
appear here, the document must keep stating the Codex-only asymmetry and the
design-pipeline epic-planner boundary, and the exact `[#N]`, `[no-issue]`,
`[deferred]`, `- [x]`, and `- [ ]` literals must survive in the document and in
both `process-report` variants — the surface that makes a report portable
between the brands.

## Project-scoped locations

The packaged commands live at `claude-plugin/plugins/kanban/commands/`,
discovered through this plugin's own `"commands": "./commands/"` manifest
declaration — adding a workflow needs no manifest schema change. That
project-scoped location is the surface the planned opt-in cross-project setup
work (issue #78) installs or links into other repositories; the `--scope
project` and `--scope local` install forms above are the manual equivalents
available today.
