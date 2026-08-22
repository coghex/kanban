# Kanban Claude plugin

This directory is a Claude Code marketplace, tracked in this repository, that
packages the Claude-side workflows Kanban invokes by name — `/solve`,
`/pr-review`, `/pr-rereview`, `/pr-revise`, and `/repair` — plus the issue-drafting and
canonical issue-review workflows a user or the review daemon invokes directly:
`/issue`, `/draft-issues`, `/autoissue`, `/issue-review`, and
`/issue-rereview`. Since issue #229
it also packages the design and report document workflows a user invokes
directly — `/design-epic`, `/process-design-doc`, `/draft-report`,
`/note-problem`, and `/process-report` — and since issues #393, #410, #427,
#430, and #462 the `/triage` roadmap workflow, its `/retriage` refresh, the
`/push-docs` documentation-landing workflow, the `/backlog-review` backlog
audit, and the `/project-review` history audit, each rendered into both bundles
from one authored source by `tools/render_command_sources.py`. It exists so a
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

`kanban@kanban` should be listed, and all twenty workflow names should be
available as `/solve`, `/pr-review`, `/pr-rereview`, `/pr-revise`, `/issue`,
`/draft-issues`, `/autoissue`, `/issue-review`, `/issue-rereview`, `/repair`,
`/design-epic`, `/process-design-doc`, `/draft-report`, `/note-problem`,
`/process-report`, `/triage`, `/retriage`, `/push-docs`, `/backlog-review`, and
`/project-review`.

Verified against Claude Code `2.1.216` (`claude --version`), the version
that provides the `claude plugin` / `claude plugin marketplace` subcommand
family this install path depends on. An older Claude Code release without
those subcommands cannot install this plugin.

## What's packaged

Kanban's own CLI spawns five of these by name: the first four, plus `/repair`,
which `r` selects for a Done pull request whose status is a problem (issue
#127). The other fifteen are drafting, readiness-gate, document, roadmap,
documentation-landing, backlog-audit, and history-audit workflows a user or the
review daemon invokes directly;
see
[docs/drafting-workflow-contract.md](../docs/drafting-workflow-contract.md) and
[docs/document-workflow-contract.md](../docs/document-workflow-contract.md).
`/repair` is not part of either declared surface. Only those fifteen are
excluded from the Haskell invocation-parity pinning in
`tools/test_claude_plugin.py`, which covers exactly the names Kanban's own
code spawns.

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
| `commands/issue-rereview.md` | `/issue-rereview` | Repairs one `reviewed:changes` issue's specification with explicit signoff and resubmits it through the same backend until that backend approves it. Never solves the issue, posts a verdict, or sets a verdict label. |
| `commands/repair.md` | `/repair` | Diagnoses why a pull request cannot merge — merge conflict, any failed check, or a blocking label, in `pullRequestStatus` order — repairs it in the worktree already on the PR's head branch, pushes without force, and hands off to exactly one canonical rereview. Never merges, closes, or sets a verdict label; never removes a blocking label without asking. |
| `commands/design-epic.md` | `/design-epic` | Captures and refines an epic-sized design in one durable `*_design.md` document. Creates no tracker items at all; hands off to `/process-design-doc` only once the user declares the design ready. Paired with the Codex `$design-epic` skill. |
| `commands/process-design-doc.md` | `/process-design-doc` | Turns a ready design document into tracker artifacts, the epic first and then **one** dependency-ready child per invocation, using the document's ledger as the durable cursor. Stops for approval before every tracker mutation. Paired with the Codex `$process-design-doc` skill. |
| `commands/draft-report.md` | `/draft-report` | Turns free-form notes or an audit request into one evidence-backed `*_findings.md` report, presented in full and written only after explicit approval. Files no issues and chooses no dispositions. Paired with the Codex `$draft-report` skill it is transposed from. |
| `commands/note-problem.md` | `/note-problem` | Appends **exactly one** verified observation to an existing findings report: preserve the user's wording as a claim, investigate only that claim, classify the result, and record evidence and handoff context. Stops for approval before touching the report, applies no disposition, and creates no tracker item. Paired with the Codex `$note-problem` skill. |
| `commands/process-report.md` | `/process-report` | Processes **exactly one** finding per invocation from an existing findings report: verify, deduplicate, recommend one disposition, stop for approval, then mark the report. The report file is the durable cursor, so a fresh session resumes in the right place. |
| `commands/triage.md` | `/triage` | Orders the repository's open issues into a dependency-aware roadmap — prerequisite-barrier blocks, a priority-ordered Anytime queue, and a tracker list — verifying approval readiness through the canonical backend's one-shot reconciliation. Never claims, edits, or creates an issue itself. Paired with the Codex `$triage` skill. |
| `commands/push-docs.md` | `/push-docs` | Lands user-approved documentation from the docs-wip worktree straight onto master through the tracked `tools/docs_land.sh`, which gates every path against the §7 publication classification. Named paths land exactly; with no arguments it presents the helper's inventory and lands only the approved selection. Never lands unprompted, never bypasses a refusal. Paired with the Codex `$push-docs` skill. |
| `commands/retriage.md` | `/retriage` | Refreshes a roadmap `/triage` already produced — minimal stable edits that keep its three sections, dependency-barrier blank lines, and marker vocabulary, with every approval marker recomputed through the canonical backend rather than carried forward. Renders no format of its own; reads `/triage`'s **Output Format** and **Approval Readiness** instead. Never claims, edits, or creates an issue itself. Paired with the Codex `$retriage` skill. |
| `commands/backlog-review.md` | `/backlog-review` | Audits the open issue backlog oldest-first — re-verifies each issue's premise against the current code and proposes exactly one disposition per issue (Valid / Update / Obsolete / Duplicate / Needs decision) with `file:line`, repro, or resolving-PR evidence. Skips in-flight issues, resolves the repository once and passes `-R "$REPO"` on every `gh` call, and **stops** before editing, closing, labelling, or commenting on anything until the user says which to apply. Paired with the Codex `$backlog-review` skill. |
| `commands/project-review.md` | `/project-review` | Audits merged pull requests newest-first — and, once PR history is exhausted, the older direct first-parent commits — judging each against the issue it claimed to satisfy, its commits, and the code at HEAD. **Report-only**: it never creates or edits a tracker issue, and a batch carrying at least one confirmed current finding ends in exactly one canonical findings report written to the branch-resolved `docs-wip` worktree for later `/process-report` disposition. Resolves the repository once and passes `-R "$REPO"` on every `gh` call. Paired with the Codex `$project-review` skill. |

The five document commands are user-invoked only. Kanban's CLI never spawns
one, because each has a mandatory human approval stop in the middle; see
[docs/document-workflow-contract.md §5](../docs/document-workflow-contract.md#5-one-artifact-per-invocation-and-the-approval-stop).
Its status markers are a cross-brand compatibility surface rather than local
formatting: `$process-report` in [codex-plugin/](../codex-plugin/README.md) is
its counterpart, the two variants may differ in wording, and a report started
under either brand must be resumable under the other.

No `epic` command is packaged: arc decomposition — planning a user-supplied
feature arc rather than independently hunting for discretionary work — belongs
to the `/design-epic`/`/process-design-doc` pipeline (see the
[document-workflow contract](../docs/document-workflow-contract.md)) and is
not part of this drafting contract. The personal `/epic` command that once
created epic trees directly was retired 2026-08-11 in that pipeline's favor.

Every document workflow is packaged here now. `design-epic` and
`process-design-doc` were Codex-only until issue #239 landed their
decision-authority guardrails in the tracked Codex skills, and `draft-report`
was the last one; `/design-epic`, `/process-design-doc`, and `/draft-report`
are each transposed from that brand's pinned tracked source, which is what
cleared them to ship here, and issue #328 vendored `note-problem` into both
marketplaces at once. The rule those gaps recorded still stands for whatever is
proposed next: a counterpart is transposed from a reviewed, pinned source
rather than authored from scratch, because authoring one would be new behavior
no pinned source defines — which the SHA-pinned vendoring model of issue #118
refused to do. The `/draft-issues` boundary above is now the only asymmetry
left, and it runs the other way; see
[docs/document-workflow-contract.md §3.5](../docs/document-workflow-contract.md#35-declared-codex-only-asymmetry-now-closed).

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
`tools/install_issue_review.py` recorded in its discovery record, then — only
when that record names none — the directory the record lives in; it never
hard-codes a personal path and never reconstructs the installer's default. The
record has two locations, probed in one order on every platform:
`$XDG_DATA_HOME/kanban/issue-review/config.json` — or
`~/.local/share/kanban/issue-review/config.json` when that variable is unset or
empty — first, then
`~/Library/Application Support/kanban/issue-review/config.json`. Whichever one
exists is the installation, so a macOS host that installed under XDG and a
Linux host that inherited a `~/Library` install each keep the one they have;
when neither exists the XDG candidate supplies the answer and the diagnostic
names both. None of the packaged commands set their own
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

The three document workflows that publish — `/process-design-doc`,
`/note-problem`, and `/process-report` — bundle the mechanism they delegate to,
in `scripts/publish_coordination_doc.py`, `scripts/tracker_transaction.py`, and
the `scripts/kanban_config.py` the first of those reads a repository's declared
coordination paths through. Each is a byte-identical copy of the `tools/` module
of the same name, and each command resolves the copy beside it at
`${CLAUDE_PLUGIN_ROOT}/scripts/`, never from the repository it is operating on —
which tracks none of them. That was issue #370: the commands shipped and the
modules they require did not, so all three failed closed in every repository but
Kanban's own, which is the opposite of what this plugin is for. The three travel
as a unit because each loads its siblings from beside itself, and
`tools/test_document_workflow_contract.py` holds the copies identical to their
sources, holds each command's lookup to a bundled path, and drives that lookup
against a simulated install. An edit to a `tools/` module therefore has to be
copied into both bundles in the same change; the drift failure names the exact
`cp` that repairs it.

Eligibility does not travel with the mechanism. For `coghex/kanban` it stays
[agent-workflow-contract.md §7](../docs/agent-workflow-contract.md#7-document-publication-classification)
as the publication branch itself carries it; for every other repository it is
that repository's own `workflow.coordination_paths` declaration, and declaring
none is the ordinary `not-published` outcome — the approved mutation is still
applied to the document, and the repository lands it through the pull-request
lane it already has.

`/issue-review` — and `/autoissue`'s immediate review handoff — resolve the
same canonical backend the same portable way, probing the same two discovery
record locations in the same order on every platform —
`~/.local/share/kanban/issue-review/config.json`, or `$XDG_DATA_HOME`'s
equivalent when that variable is set, and then
`~/Library/Application Support/kanban/issue-review/config.json` — for the
record `python3 tools/install_issue_review.py` writes from a Kanban checkout.
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
- the commands directory contains exactly the twenty packaged workflows,
  and the five Kanban spawns exactly match the `/`-prefixed tokens
  `src/Kanban/Solve.hs` and `src/Kanban/PullRequestFlow.hs` actually spawn —
  two separate assertions, since Kanban's Haskell code must *not* spawn the
  fifteen user-invoked commands;
- the Codex-only document-workflow set is empty, so no counterpart is withheld
  from this bundle;
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
  invocation, so the two cannot silently drift apart;
- handed an issue number, the bundled coordinator refuses it by name rather
  than surfacing `gh`'s raw resolver error, reading twice and writing nothing.

`tools/test_coordinator_parity.py` bounds how far this coordinator may differ
from [codex-plugin/](../codex-plugin/README.md)'s copy: the two are compared
line for line, and the model-pinning divergence described above is the only
difference permitted. Nothing is excluded — not a function, not a comment block
— so a fix landing in one copy only fails there, which is how the
issue-vs-pull-request number guard went eight days Codex-side only.

`tools/test_agent_workflow_contract.py` reconciles this plugin's own bash
surface (all twenty commands under `claude-plugin/plugins/kanban/commands/`) and
all five bundled Python assets — the review coordinator, `/solve`'s
trusted-comment helper, and the three document-workflow modules — against the
same manifest in
[docs/agent-workflow-contract.md §4](../docs/agent-workflow-contract.md#4-dependency-manifest)
that the Codex plugin and Kanban's Haskell source are reconciled against,
including the user-scoped backend install path the drafting, issue-review, and
issue-rereview commands name and the `git`/`awk`/`gh`/`rg` commands
`/process-report` resolves
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

`tools/test_drafting_workflow_contract.py` reconciles the five drafting
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

`tools/test_document_workflow_contract.py` does the same for `/design-epic`,
`/process-design-doc`, `/draft-report`, `/note-problem`, and `/process-report`
against
[docs/document-workflow-contract.md](../docs/document-workflow-contract.md):
every declared asset must exist, no undeclared design or report workflow may
appear here, the document must keep stating §3.5's standing rule and closure
record and the
design-pipeline epic-planner boundary, the decision-authority clauses of §5.1
must survive in both Claude design commands, and the exact `[#N]`, `[no-issue]`,
`[deferred]`, `- [x]`, and `- [ ]` literals must survive in the document and in
every cross-brand pair — the surface that makes a report or design document
portable between the brands. It also holds `/note-problem` on the publishing
side of §9 rather than the novel-document side: it writes no checked box, but
what it appends to is a report that may already be classified `coordination`.

## Project-scoped locations

The packaged commands live at `claude-plugin/plugins/kanban/commands/`,
discovered through this plugin's own `"commands": "./commands/"` manifest
declaration — adding a workflow needs no manifest schema change. That
project-scoped location is the surface the planned opt-in cross-project setup
work (issue #78) installs or links into other repositories; the `--scope
project` and `--scope local` install forms above are the manual equivalents
available today.
