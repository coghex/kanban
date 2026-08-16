# Kanban Codex plugin

This directory is a Codex marketplace, tracked in this repository, that
packages the Codex-side workflows Kanban invokes by name — `$solve`,
`$pr-review`, `$pr-rereview`, `$pr-revise`, and `$repair` — plus the issue-drafting and
canonical issue-review workflows a user or the review daemon invokes directly:
`$issue`, `$autoissue`, and `$issue-review`. Since issue #229 it also packages
the design and report document workflows a user invokes directly — `$design-epic`,
`$process-design-doc`, `$draft-report`, `$note-problem`, and `$process-report`.
It exists so a
clean Codex installation can perform these actions without depending on any
developer's personal skill collection. See
[docs/agent-workflow-contract.md](../docs/agent-workflow-contract.md) for
the full dependency contract these workflows implement, including the
`solve`/PR-flow authority boundaries and the canonical issue-review backend
they call into,
[docs/drafting-workflow-contract.md](../docs/drafting-workflow-contract.md)
for the drafting and issue-review responsibility matrix, and
[docs/document-workflow-contract.md](../docs/document-workflow-contract.md)
for the design and report document responsibility matrix.

Claude packaging is a separate marketplace tracked at
[claude-plugin/](../claude-plugin/README.md); nothing here covers `/solve` or
the other Claude-side commands. That marketplace also packages one workflow
this one deliberately does not: `/draft-issues`, the breadth counterpart to
`$issue`, is Claude-only by contract.

## Install

From a checkout of this repository, add the marketplace and install the
plugin in project scope:

```console
codex plugin marketplace add ./codex-plugin
codex plugin add kanban@kanban
```

`codex plugin marketplace add` also accepts a `owner/repo[@ref]` GitHub
reference or a Git URL as its marketplace source, but this marketplace's
manifest lives at `codex-plugin/.agents/plugins/marketplace.json` rather
than at the repository root, so a git-sourced install needs the marketplace
root pointed at that subdirectory; the local-path form above is the
verified, supported install path from a checkout. Installing registers the
marketplace and plugin in your own `$CODEX_HOME/config.toml` (by default
`~/.codex/config.toml`) — installation is per-user and explicit, never
automatic, matching the portable-install policy in
[docs/agent-workflow-contract.md §5](../docs/agent-workflow-contract.md#5-portable-install-policy).

Verify discovery:

```console
codex plugin list
```

`kanban@kanban` should show as `installed, enabled`, and all fourteen workflow
names should be available as `$solve`, `$pr-review`, `$pr-rereview`,
`$pr-revise`, `$issue`, `$autoissue`, `$issue-review`, `$issue-rereview`,
`$repair`, `$design-epic`, `$process-design-doc`, `$draft-report`,
`$note-problem`, and `$process-report` in any Codex session run from this
checkout.

Verified against Codex CLI `codex-cli 0.144.6` (`codex --version`), the
version that provides the `codex plugin` / `codex plugin marketplace`
subcommand family this install path depends on. An older Codex release
without those subcommands cannot install this plugin.

## What's packaged

Kanban's own CLI spawns five of these by name: the first four, plus `$repair`,
which `r` selects for a Done pull request whose status is a problem (issue
#127). The other eight are drafting, readiness-gate, repair, and document
workflows a user or the review daemon invokes directly; see
[docs/drafting-workflow-contract.md](../docs/drafting-workflow-contract.md) and
[docs/document-workflow-contract.md](../docs/document-workflow-contract.md).
`$repair` is not part of either declared surface. Only those eight are excluded
from the Haskell invocation-parity pinning in `tools/test_codex_plugin.py`,
which covers exactly the names Kanban's own code spawns.

| Skill | Codex command | Boundary |
| --- | --- | --- |
| `skills/solve/` | `$solve` | Claims an issue, implements it in an isolated worktree, opens a PR. Stops after opening the PR; never reviews or merges. |
| `skills/pr-review/` | `$pr-review` | Review-only. Runs the canonical issue-gated, opposite-brand (or dual, for unknown origin) review and publishes one verdict. Never edits, labels beyond the verdict, or merges. |
| `skills/pr-rereview/` | `$pr-rereview` | Same as `$pr-review` for a changed PR; also removes a lingering `reviewed:revised` label after publishing, the one label mutation Kanban's own invocation prompts require of a review-only workflow. |
| `skills/pr-revise/` | `$pr-revise` | Repairs a `reviewed:changes` PR in an isolated worktree, pushes safely, then hands off to exactly one canonical rereview. Never self-approves or merges. |
| `skills/issue/` | `$issue` | Finds, verifies, and deduplicates **exactly one** candidate and drafts it to hand-off quality. Stops for explicit signoff; never creates without it. |
| `skills/autoissue/` | `$autoissue` | Delegates drafting to `$issue`, and on signoff creates the issue and immediately runs `$issue-review` with no second confirmation. Stops without reviewing if drafting stops before creation. |
| `skills/issue-review/` | `$issue-review` | Runs the canonical opposite-agent readiness gate for one numbered issue through the portable backend. Never drafts, creates, or posts a competing verdict. |
| `skills/issue-rereview/` | `$issue-rereview` | Repairs one `reviewed:changes` issue's specification with explicit signoff and resubmits it through the same backend until that backend approves it. Never solves the issue, posts a verdict, or sets a verdict label. |
| `skills/repair/` | `$repair` | Diagnoses why a pull request cannot merge — merge conflict, any failed check, or a blocking label, in `pullRequestStatus` order — repairs it in the worktree already on the PR's head branch, pushes without force, and hands off to exactly one canonical rereview. Never merges, closes, or sets a verdict label; never removes a blocking label without asking. |
| `skills/design-epic/` | `$design-epic` | Captures and refines an epic-sized design in one durable `*_design.md` document. Creates no tracker items at all; hands off to `$process-design-doc` only once the user declares the design ready. Paired with the Claude `/design-epic` command. |
| `skills/process-design-doc/` | `$process-design-doc` | Turns a ready design document into tracker artifacts, the epic first and then **one** dependency-ready child per invocation, using the document's ledger as the durable cursor. Stops for approval before every tracker mutation. Paired with the Claude `/process-design-doc` command. |
| `skills/draft-report/` | `$draft-report` | Turns free-form notes or an audit request into one evidence-backed `*_findings.md` report, presented in full and written only after explicit approval. Files no issues and chooses no dispositions. Paired with the Claude `/draft-report` command. |
| `skills/note-problem/` | `$note-problem` | Appends **exactly one** verified observation to an existing findings report: preserve the user's wording as a claim, investigate only that claim, classify the result, and record evidence and handoff context. Stops for approval before touching the report, applies no disposition, and creates no tracker item. Paired with the Claude `/note-problem` command. |
| `skills/process-report/` | `$process-report` | Processes **exactly one** finding per invocation from an existing report: verify, deduplicate, recommend one disposition, stop for approval, then mark the report. Paired with the Claude `/process-report` command. |

The five document workflows are user-invoked only. Kanban's CLI never spawns
one, because each has a mandatory human approval stop in the middle; see
[docs/document-workflow-contract.md §5](../docs/document-workflow-contract.md#5-one-artifact-per-invocation-and-the-approval-stop).

Two workflows are deliberately **not** packaged here. `draft-issues`, the
breadth counterpart to `$issue`, is Claude-only by contract — see
[claude-plugin/](../claude-plugin/README.md). And no `epic` asset exists in
either marketplace: arc decomposition — a user-supplied feature arc rather
than independently hunted discretionary work — belongs to `$design-epic`,
which captures the arc as a durable design document, with
`$process-design-doc` filing its slices; the personal `/epic` command that
once created epic trees directly was retired 2026-08-11 in that pipeline's
favor.

No document workflow is Codex-only any more. `$design-epic` and
`$process-design-doc` were, until issue #239 landed their decision-authority
guardrails here and issue #241 transposed the Claude commands from that pinned
source; `$draft-report` was the last one, and issue #328 transposed
`/draft-report` from this skill the same way while vendoring `$note-problem`
into both marketplaces at once. All five document workflows are now cross-brand
pairs. The rule that made those gaps declared rather than accidental still
stands for whatever is proposed next: a counterpart is transposed from a
reviewed, pinned source, never authored from scratch, which is what the
SHA-pinned vendoring model of issue #118 required. See
[docs/document-workflow-contract.md §3.5](../docs/document-workflow-contract.md#35-declared-codex-only-asymmetry-now-closed).

`pr-review`, `pr-rereview`, `pr-revise`, and `repair` all delegate publication
to the bundled coordinator at `skills/pr-review/scripts/review_pr.py`. Kanban
spawns each of these workflows with the *reviewed* repository as the
working directory, not this plugin's own install location, so the other
three skills locate the installed coordinator by searching under
`$CODEX_HOME` rather than a path relative to the current directory — the
same review logic and `pr-review:v2` marker/label state machine runs
regardless of which command an agent session starts from. The coordinator
resolves the canonical issue-review backend the same way
`Kanban.Review.resolveCanonicalIssueReviewer` does: a non-empty
`KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then the backend path
`tools/install_issue_review.py` recorded in
`~/Library/Application Support/kanban/issue-review/config.json`, then — only
when that record names none — the directory the record lives in; it never
hard-codes a personal path and never reconstructs the installer's default. None of the packaged skills set their own model, reasoning
effort, sandbox, approval policy, or working directory — Kanban's own CLI
invocation pins those per action, and `tools/test_codex_plugin.py` asserts
none of the packaged manifests (or the coordinator's own nested-reviewer
invocations) override them.

`$solve` bundles a second script, `skills/solve/scripts/trusted_issue_spec.py`,
and reads the issue's effective spec through nothing else. It fetches the
complete paginated comment timeline and exposes a comment body only for the
exact, case-insensitive logins `claude`, `codex`, and `coghex`; every other
comment comes back as metadata alone, so an untrusted body never enters the
solving session's context. Repository role, `author_association`, issue
authorship, display name, and bot status grant nothing, and the set is
hardcoded, so widening it costs a reviewed pull request. `$solve` locates this
helper under `$CODEX_HOME` exactly the way the PR-flow skills locate the
coordinator, and for the same reason. The trust rule and its deliberate
divergence from the reviewer gate's association-based arithmetic are recorded in
[docs/agent-workflow-contract.md §2.1](../docs/agent-workflow-contract.md#21-issue-solve-solve--solve).

`$issue-review` — and `$autoissue`'s immediate review handoff — resolve the
same canonical backend the same portable way, through the discovery record at
`~/Library/Application Support/kanban/issue-review/config.json` that
`python3 tools/install_issue_review.py` writes from a Kanban checkout.
They never reference the pre-migration compatibility launcher described in
[docs/agent-workflow-contract.md §3](../docs/agent-workflow-contract.md#3-migration-boundary),
and they never pin a reviewer model or display name:
selecting the opposite-agent reviewer is the backend's job, and its own default
already resolves the canonical one. The personal model pins carried by the
pre-vendoring sources were dropped for exactly that reason.

For known-origin `$pr-review`/`$pr-rereview` — the case Kanban's own
invocation always produces — the calling session already *is* the
correctly-pinned canonical reviewer, so it reviews directly and uses the
coordinator (`--self-review`) only for safe publication; no nested,
unpinned reviewer is spawned. Only the cross-brand handoffs of `pr-revise`
and `repair` (each runs on the PR's own origin brand but must hand off to the
opposite brand)
and the rare dual-review fallback for unknown/external origin — which
Kanban's own invocation never triggers — spawn a nested `codex`/`claude`
reviewer, and that nested call selects brand only, deferring to whatever
model that installation defaults to; see
[docs/agent-workflow-contract.md §2.2](../docs/agent-workflow-contract.md#22-pr-review-rereview-and-revise)
for why. Dual review runs its two reviewers strictly one at a time, each
in its own unpredictably-named, read-only temp directory torn down before
the next begins — never two reviewers' source trees on disk at once.

## Structural and contract coverage

`tools/test_codex_plugin.py` (run by
`python3 -m unittest discover -s tools -p 'test_*.py'`, which CI already
runs) checks that:

- the marketplace and plugin manifests are valid and point at this
  directory;
- the skills directory contains exactly the thirteen packaged workflows, and
  the five Kanban spawns exactly match the `$`-prefixed tokens
  `src/Kanban/Solve.hs` and `src/Kanban/PullRequestFlow.hs` actually spawn —
  two separate assertions, since Kanban's Haskell code must *not* spawn the
  four drafting or four document skills;
- `draft-issues` is absent, keeping the Claude-only breadth boundary;
- no packaged manifest sets model/effort/sandbox/approval/working-directory
  configuration, and every packaged skill — drafting skills included — has a
  `SKILL.md` whose frontmatter `name:` matches its directory;
- no packaged asset references a personal absolute path or the pre-migration
  compatibility launcher path (see
  [docs/agent-workflow-contract.md §3](../docs/agent-workflow-contract.md#3-migration-boundary));
- the bundled coordinator resolves the canonical issue-review backend the
  same way Kanban's Haskell code does, and its self-test passes standalone;
- handed an issue number, the bundled coordinator refuses it by name rather
  than surfacing `gh`'s raw resolver error, reading twice and writing nothing.

`tools/test_coordinator_parity.py` bounds how far this coordinator may differ
from [claude-plugin/](../claude-plugin/README.md)'s copy: the two are compared
line for line, and only the nested-reviewer model-pinning exception of
[docs/agent-workflow-contract.md §2.2](../docs/agent-workflow-contract.md) is
permitted. Nothing is excluded — not a function, not a comment block — so a fix
landing in one copy only fails there, which is how the issue-vs-pull-request
number guard went eight days Codex-side only.

`tools/test_trusted_issue_spec.py` pins `$solve`'s bundled trusted-comment
helper against its Claude counterpart — the two copies must stay byte-identical
— and drives both over every signal that must grant no comment body, proving no
untrusted body or body-derived content survives serialization and that each copy
resolves from its own installed bundle while the working directory is the
repository being solved. `$issue-rereview` reads the issue timeline through
that same copy and adds none of its own.

`tools/test_agent_workflow_contract.py` reconciles all thirteen skills' own bash
surface against the manifest in
[docs/agent-workflow-contract.md §4](../docs/agent-workflow-contract.md#4-dependency-manifest),
including the user-scoped backend install path the drafting, issue-review, and
issue-rereview skills name, the `$CODEX_HOME` cache root `$issue-rereview`
searches for its vendored helper,
the `git`/`awk`/`gh` commands the document skills resolve their
docs worktree and tracker state with, and the `gh` surface of both bundled
Python assets — the review coordinator and `$solve`'s trusted-comment helper.

`tools/test_repair_workflow_contract.py` pins `$repair`'s own behavioral
contract — the ordered diagnosis branches, worktree selection and safe push,
the never-merge/never-label authority limits, and the exactly-one-rereview
handoff — against both this skill and its Claude counterpart, so the two
brands' copies cannot diverge.

`tools/test_drafting_workflow_contract.py` reconciles the three drafting skills
against the responsibility matrix in
[docs/drafting-workflow-contract.md](../docs/drafting-workflow-contract.md):
every declared asset must exist, no undeclared drafting skill may appear, the
exact `<!-- issue-origin:codex -->` marker literal must be present in each
issue-creating skill, and the Claude-only `draft-issues` and unpackaged
arc-decomposition boundaries must remain stated. It also pins the optional
scope gate
([docs/drafting-workflow-contract.md §4](../docs/drafting-workflow-contract.md#4-scope-gate)):
`$issue` and `$autoissue` must state the same gate and exemption rules as the
document, each gate instruction must follow the guard that makes it apply only
when the consuming repo declares a gate, and `$issue-review` must stay free of
gate language.

`tools/test_document_workflow_contract.py` does the same for the four document
skills against
[docs/document-workflow-contract.md](../docs/document-workflow-contract.md):
every declared asset must exist, no undeclared design or report workflow may
appear, the document must keep stating §3.5's standing rule and closure record, the
design-pair closure record, and the
design-pipeline epic-planner boundary, and the exact `[#N]`, `[no-issue]`,
`[deferred]`, `- [x]`, and `- [ ]` literals must survive in the document and in
the assets — including in all five cross-brand pairs, whose halves may differ
in wording but not on the surface that makes a report or design document
started under one brand resumable under the other.

## Project-scoped locations

The packaged skills live at `codex-plugin/plugins/kanban/skills/<name>/SKILL.md`,
discovered per-directory through this plugin's own `"skills": "./skills/"`
manifest declaration — adding a workflow needs no manifest schema change. That
project-scoped location is the surface the planned opt-in cross-project setup
work (issue #78) installs or links into other repositories; the local-path
marketplace install above is the manual equivalent available today.
