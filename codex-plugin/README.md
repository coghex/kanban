# Kanban Codex plugin

This directory is a Codex marketplace, tracked in this repository, that
packages the Codex-side workflows Kanban invokes by name — `$solve`,
`$pr-review`, `$pr-rereview`, `$pr-revise`, and `$repair` — plus the issue-drafting and
canonical issue-review workflows a user or the review daemon invokes directly:
`$issue`, `$autoissue`, `$issue-review`, and `$issue-rereview`. Since issue
#229 it also packages
the design and report document workflows a user invokes directly — `$design-epic`,
`$process-design-doc`, `$draft-report`, `$note-problem`, and `$process-report` —
and since issues #393, #410, #427, #430, #462, #511, and #544 the `$triage`
roadmap
workflow, its `$retriage` refresh, the `$push-docs` documentation-landing
workflow, the `$backlog-review` backlog audit, the `$project-review` history
audit, the `$drain-prs` drainer control surface, the `$fix`
approved-pull-request workflow, and the `$finalize` manual merge fallback, each
rendered into both bundles from one authored source by `tools/render_command_sources.py`.
`$finalize` is the one of those with no personal Codex copy to reconcile
against: the single Claude copy was the source, and this skill is what
rendering it produced.
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

`kanban@kanban` should show as `installed, enabled`, and all twenty-two workflow
names should be available as `$solve`, `$pr-review`, `$pr-rereview`,
`$pr-revise`, `$issue`, `$autoissue`, `$issue-review`, `$issue-rereview`,
`$repair`, `$design-epic`, `$process-design-doc`, `$draft-report`,
`$note-problem`, `$process-report`, `$triage`, `$retriage`, `$push-docs`,
`$backlog-review`, `$project-review`, `$drain-prs`, `$fix`, and `$finalize` in
any Codex session run
from this checkout.

Verified against Codex CLI `codex-cli 0.144.6` (`codex --version`), the
version that provides the `codex plugin` / `codex plugin marketplace`
subcommand family this install path depends on. An older Codex release
without those subcommands cannot install this plugin.

## What's packaged

Kanban's own CLI spawns five of these by name: the first four, plus `$repair`,
which `r` selects for a Done pull request whose status is a problem (issue
#127). The other seventeen are drafting, readiness-gate, document, roadmap,
documentation-landing, backlog-audit, history-audit, drainer-control,
approved-pull-request, and manual-finalization workflows a user or the review
daemon invokes directly;
see
[docs/drafting-workflow-contract.md](../docs/drafting-workflow-contract.md) and
[docs/document-workflow-contract.md](../docs/document-workflow-contract.md).
`$repair` is not part of either declared surface. Only those seventeen are
excluded from the Haskell invocation-parity pinning in
`tools/test_codex_plugin.py`, which covers exactly the names Kanban's own
code spawns.

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
| `skills/triage/` | `$triage` | Orders the repository's open issues into a dependency-aware roadmap — prerequisite-barrier blocks, a priority-ordered Anytime queue, and a tracker list — verifying approval readiness through the canonical backend's one-shot reconciliation. Never claims, edits, or creates an issue itself. Paired with the Claude `/triage` command. |
| `skills/push-docs/` | `$push-docs` | Lands user-approved documentation from the docs-wip worktree straight onto master through the tracked `tools/docs_land.sh`, which gates every path against the §7 publication classification. Named paths land exactly; with no arguments it presents the helper's inventory and lands only the approved selection. Never lands unprompted, never bypasses a refusal. Paired with the Claude `/push-docs` command. |
| `skills/retriage/` | `$retriage` | Refreshes a roadmap `$triage` already produced — minimal stable edits that keep its three sections, dependency-barrier blank lines, and marker vocabulary, with every approval marker recomputed through the canonical backend rather than carried forward. Renders no format of its own; reads `$triage`'s **Output Format** and **Approval Readiness** instead. Never claims, edits, or creates an issue itself. Paired with the Claude `/retriage` command. |
| `skills/backlog-review/` | `$backlog-review` | Audits the open issue backlog oldest-first — re-verifies each issue's premise against the current code and proposes exactly one disposition per issue (Valid / Update / Obsolete / Duplicate / Needs decision) with `file:line`, repro, or resolving-PR evidence. Skips in-flight issues, resolves the repository once and passes `-R "$REPO"` on every `gh` call, and **stops** before editing, closing, labelling, or commenting on anything until the user says which to apply. Paired with the Claude `/backlog-review` command. |
| `skills/project-review/` | `$project-review` | Audits merged pull requests newest-first — and, once PR history is exhausted, the older direct first-parent commits — judging each against the issue it claimed to satisfy, its commits, and the code at HEAD. **Report-only**: it never creates or edits a tracker issue, and a batch carrying at least one confirmed current finding ends in exactly one canonical findings report written to the branch-resolved `docs-wip` worktree for later `$process-report` disposition. Resolves the repository once and passes `-R "$REPO"` on every `gh` call. Paired with the Claude `/project-review` command. |
| `skills/drain-prs/` | `$drain-prs` | Controls and recovers this repository's service-managed approved-PR drainer through its installed controller — `status`, `install`, `start`, `stop`, `restart`, `logs`, `incident`, `ack`, and `recover`. Resolves the controller from `KANBAN_DRAINER_INSTALL_DIR`, the XDG data root, then `~/Library/Application Support` rather than a hardcoded path, and passes both `--path "$ROOT"` and `--repo "$REPO"` on every invocation. Resolves the repository identity through the remote the shared Kanban configuration's `remote_name` names, so a fork checkout whose board is pointed at upstream asserts the upstream identity the controller expects. Makes no GitHub call of its own, creates no second watcher, and runs only on an explicit request. Paired with the Claude `/drain-prs` command. |
| `skills/fix/` | `$fix` | Clears the one remaining obstacle in front of an **already-approved** pull request. Refuses any pull request that is not approved under the configured `approval_mode`, refuses one whose `pr-origin` marker names the other brand, and never removes a blocking label to proceed. Resolves a merge conflict, updates a branch that is behind its base, and fixes a failed check in the pull request's own worktree before handing off one canonical rereview. Fails closed rather than guessing: a check rollup that cannot be read completely, a `BLOCKED` or `UNSTABLE` merge state, and a still-running check each stop the run without mutating anything. **Never retries a check** — `tools/drain_prs.py` remains the only component that reruns one. Runs only on an explicit request to fix or unblock: asking why a pull request cannot merge is answered by reporting the obstacle and stopping. Paired with the Claude `/fix` command. |
| `skills/finalize/` | `$finalize` | Legacy **manual fallback** for merging one named reviewed pull request when the service-managed PR drainer cannot be used. Never the ordinary merge path and never taken on an agent's own initiative: `tools/drain_prs.py` keeps owning eligible merges. Resolves the repository once and passes `-R "$REPO"` on every `gh` call. Its gate fails closed — it resolves the authenticated login, reads the whole paginated comment feed, and requires the globally newest marker that login published (`pr-review:v2`, with the legacy `pr-review:v1` spelling still honoured) to name the current `headRefOid` with `verdict=APPROVE` and a `reviewers=` set that excludes the pull request's own brand, alongside `reviewed:approve` present, `reviewed:changes` absent, `mergeable` exactly `MERGEABLE`, a merge state Kanban's own `mergeStateReady` calls ready (so `BEHIND` and `UNSTABLE` refuse), and every check successful. Any refusal merges nothing, closes nothing, removes no worktree, and deletes no branch. Merges with `--admin --merge --match-head-commit`, never `--squash` or `--rebase`, and cleans up only after GitHub confirms the merge, as one `&&` chain that a first failure ends — never deleting a cross-repository head here, never fast-forwarding a primary checkout that is not on the pull request's base branch, identifying both the branch deletions and the worktree it removes by the reviewed head rather than by a name or a path pattern, and deleting a remote branch only when pushing to `origin` really reaches the pull request's own repository. Paired with the Claude `/finalize` command. |

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
names both. None of the packaged skills set their own model, reasoning
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

The three document workflows that publish — `$process-design-doc`,
`$note-problem`, and `$process-report` — bundle the mechanism they delegate to,
at `skills/process-report/scripts/publish_coordination_doc.py`,
`skills/process-report/scripts/tracker_transaction.py`, and the
`skills/process-report/scripts/kanban_config.py` the first of those reads a
repository's declared coordination paths through. Each is a byte-identical copy
of the `tools/` module of the same name. All three skills locate the installed
copies by searching under `$CODEX_HOME` — the same lookup, and the same reason,
as the PR-flow skills' search for the coordinator — and never resolve them from
the repository being worked, which tracks none of them. That was issue #370: the
skills shipped and the modules they require did not, so all three failed closed
in every repository but Kanban's own, which is the opposite of what this plugin
is for. The three modules travel as a unit because each loads its siblings from
beside itself, and `tools/test_document_workflow_contract.py` holds the copies
identical to their sources, holds each skill's lookup to a bundled path, and
runs that `find` against a simulated install. An edit to a `tools/` module
therefore has to be copied into both bundles in the same change; the drift
failure names the exact `cp` that repairs it.

Eligibility does not travel with the mechanism. For `coghex/kanban` it stays
[agent-workflow-contract.md §7](../docs/agent-workflow-contract.md#7-document-publication-classification)
as the publication branch itself carries it; for every other repository it is
that repository's own `workflow.direct_publication_paths` declaration.
Declaring none is the ordinary `not-published` outcome — the approved mutation
is still applied to the document, and the repository lands it through the
pull-request lane it already has. The drainer's separate
`workflow.coordination_paths` declaration grants no publication lane.

`$issue-review` — and `$autoissue`'s immediate review handoff — resolve the
same canonical backend the same portable way, probing the same two discovery
record locations in the same order on every platform —
`~/.local/share/kanban/issue-review/config.json`, or `$XDG_DATA_HOME`'s
equivalent when that variable is set, and then
`~/Library/Application Support/kanban/issue-review/config.json` — for the
record `python3 tools/install_issue_review.py` writes from a Kanban checkout.
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
- the skills directory contains exactly the twenty-two packaged workflows, and
  the five Kanban spawns exactly match the `$`-prefixed tokens
  `src/Kanban/Solve.hs` and `src/Kanban/PullRequestFlow.hs` actually spawn —
  two separate assertions, since Kanban's Haskell code must *not* spawn the
  seventeen user-invoked skills;
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

`tools/test_agent_workflow_contract.py` reconciles all twenty-two skills' own bash
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

`tools/test_drafting_workflow_contract.py` reconciles the four drafting skills
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

`tools/test_document_workflow_contract.py` does the same for the five document
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
