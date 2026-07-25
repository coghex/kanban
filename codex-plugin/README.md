# Kanban Codex plugin

This directory is a Codex marketplace, tracked in this repository, that
packages the Codex-side workflows Kanban invokes by name — `$solve`,
`$pr-review`, `$pr-rereview`, and `$pr-revise` — plus the issue-drafting and
canonical issue-review workflows a user or the review daemon invokes directly:
`$issue`, `$autoissue`, and `$issue-review`. It exists so a clean Codex
installation can perform these actions without depending on any developer's
personal skill collection. See
[docs/agent-workflow-contract.md](../docs/agent-workflow-contract.md) for
the full dependency contract these workflows implement, including the
`solve`/PR-flow authority boundaries and the canonical issue-review backend
they call into, and
[docs/drafting-workflow-contract.md](../docs/drafting-workflow-contract.md)
for the drafting and issue-review responsibility matrix.

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

`kanban@kanban` should show as `installed, enabled`, and all seven workflow
names should be available as `$solve`, `$pr-review`, `$pr-rereview`,
`$pr-revise`, `$issue`, `$autoissue`, and `$issue-review` in any Codex session
run from this checkout.

Verified against Codex CLI `codex-cli 0.144.6` (`codex --version`), the
version that provides the `codex plugin` / `codex plugin marketplace`
subcommand family this install path depends on. An older Codex release
without those subcommands cannot install this plugin.

## What's packaged

Kanban's own CLI spawns the first four by name. The last three are drafting and
readiness-gate workflows a user or the review daemon invokes directly, which is
why they are excluded from the Haskell invocation-parity pinning in
`tools/test_codex_plugin.py`; see
[docs/drafting-workflow-contract.md](../docs/drafting-workflow-contract.md).

| Skill | Codex command | Boundary |
| --- | --- | --- |
| `skills/solve/` | `$solve` | Claims an issue, implements it in an isolated worktree, opens a PR. Stops after opening the PR; never reviews or merges. |
| `skills/pr-review/` | `$pr-review` | Review-only. Runs the canonical issue-gated, opposite-brand (or dual, for unknown origin) review and publishes one verdict. Never edits, labels beyond the verdict, or merges. |
| `skills/pr-rereview/` | `$pr-rereview` | Same as `$pr-review` for a changed PR; also removes a lingering `reviewed:revised` label after publishing, the one label mutation Kanban's own invocation prompts require of a review-only workflow. |
| `skills/pr-revise/` | `$pr-revise` | Repairs a `reviewed:changes` PR in an isolated worktree, pushes safely, then hands off to exactly one canonical rereview. Never self-approves or merges. |
| `skills/issue/` | `$issue` | Finds, verifies, and deduplicates **exactly one** candidate and drafts it to hand-off quality. Stops for explicit signoff; never creates without it. |
| `skills/autoissue/` | `$autoissue` | Delegates drafting to `$issue`, and on signoff creates the issue and immediately runs `$issue-review` with no second confirmation. Stops without reviewing if drafting stops before creation. |
| `skills/issue-review/` | `$issue-review` | Runs the canonical opposite-agent readiness gate for one numbered issue through the portable backend. Never drafts, creates, or posts a competing verdict. |

Two workflows are deliberately **not** packaged here. `draft-issues`, the
breadth counterpart to `$issue`, is Claude-only by contract — see
[claude-plugin/](../claude-plugin/README.md). `epic` decomposes a user-supplied
feature arc rather than independently hunting discretionary work, so it is not
part of the drafting contract and is packaged in neither marketplace.

`pr-review`, `pr-rereview`, and `pr-revise` all delegate publication to the
bundled coordinator at `skills/pr-review/scripts/review_pr.py`. Kanban
spawns each of these workflows with the *reviewed* repository as the
working directory, not this plugin's own install location, so the other
two skills locate the installed coordinator by searching under
`$CODEX_HOME` rather than a path relative to the current directory — the
same review logic and `pr-review:v2` marker/label state machine runs
regardless of which command an agent session starts from. The coordinator
resolves the canonical issue-review backend the same way
`Kanban.Review.canonicalIssueReviewerPath` does (`KANBAN_ISSUE_REVIEW_INSTALL_DIR`,
falling back to the Kanban-managed install directory under
`~/Library/Application Support/kanban/issue-review/`); it never hard-codes a
personal path. None of the packaged skills set their own model, reasoning
effort, sandbox, approval policy, or working directory — Kanban's own CLI
invocation pins those per action, and `tools/test_codex_plugin.py` asserts
none of the packaged manifests (or the coordinator's own nested-reviewer
invocations) override them.

`$issue-review` — and `$autoissue`'s immediate review handoff — resolve the
same canonical backend the same portable way, at
`${KANBAN_ISSUE_REVIEW_INSTALL_DIR:-$HOME/Library/Application Support/kanban/issue-review}/approve_issues.py`,
installed by `python3 tools/install_issue_review.py` from a Kanban checkout.
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
unpinned reviewer is spawned. Only `pr-revise`'s cross-brand handoff (it
runs on the PR's own origin brand but must hand off to the opposite brand)
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
- the skills directory contains exactly the seven packaged workflows, and the
  four Kanban spawns exactly match the `$`-prefixed tokens
  `src/Kanban/Solve.hs` and `src/Kanban/PullRequestFlow.hs` actually spawn —
  two separate assertions, since Kanban's Haskell code must *not* spawn the
  three drafting skills;
- `draft-issues` is absent, keeping the Claude-only breadth boundary;
- no packaged manifest sets model/effort/sandbox/approval/working-directory
  configuration, and every packaged skill — drafting skills included — has a
  `SKILL.md` whose frontmatter `name:` matches its directory;
- no packaged asset references a personal absolute path or the pre-migration
  compatibility launcher path (see
  [docs/agent-workflow-contract.md §3](../docs/agent-workflow-contract.md#3-migration-boundary));
- the bundled coordinator resolves the canonical issue-review backend the
  same way Kanban's Haskell code does, and its self-test passes standalone.

`tools/test_agent_workflow_contract.py` reconciles all seven skills' own bash
surface against the manifest in
[docs/agent-workflow-contract.md §4](../docs/agent-workflow-contract.md#4-dependency-manifest),
including the user-scoped backend install path the drafting and issue-review
skills name.

`tools/test_drafting_workflow_contract.py` reconciles the three drafting skills
against the responsibility matrix in
[docs/drafting-workflow-contract.md](../docs/drafting-workflow-contract.md):
every declared asset must exist, no undeclared drafting skill may appear, the
exact `<!-- issue-origin:codex -->` marker literal must be present in each
issue-creating skill, and the Claude-only `draft-issues` and unpackaged `epic`
boundaries must remain stated. It also pins the optional scope gate
([docs/drafting-workflow-contract.md §4](../docs/drafting-workflow-contract.md#4-scope-gate)):
`$issue` and `$autoissue` must state the same gate and exemption rules as the
document, each gate instruction must follow the guard that makes it apply only
when the consuming repo declares a gate, and `$issue-review` must stay free of
gate language.

## Project-scoped locations

The packaged skills live at `codex-plugin/plugins/kanban/skills/<name>/SKILL.md`,
discovered per-directory through this plugin's own `"skills": "./skills/"`
manifest declaration — adding a workflow needs no manifest schema change. That
project-scoped location is the surface the planned opt-in cross-project setup
work (issue #78) installs or links into other repositories; the local-path
marketplace install above is the manual equivalent available today.
