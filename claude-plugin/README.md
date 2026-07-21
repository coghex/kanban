# Kanban Claude plugin

This directory is a Claude Code marketplace, tracked in this repository, that
packages the Claude-side workflows Kanban invokes by name: `/solve`,
`/pr-review`, `/pr-rereview`, and `/pr-revise`. It exists so a clean Claude
Code installation can perform these actions without depending on any
developer's personal command collection. See
[docs/agent-workflow-contract.md](../docs/agent-workflow-contract.md) for the
full dependency contract these workflows implement, including the
`solve`/PR-flow authority boundaries and the canonical issue-review backend
they call into. See [codex-plugin/](../codex-plugin/README.md) for the
equivalent Codex-side packaging.

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
repository lists all four commands. The embedded marketplace path is
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
repository, and not separately configured) still lists all four commands
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

`kanban@kanban` should be listed, and the four workflow names should be
available as `/solve`, `/pr-review`, `/pr-rereview`, and `/pr-revise`.

Verified against Claude Code `2.1.216` (`claude --version`), the version
that provides the `claude plugin` / `claude plugin marketplace` subcommand
family this install path depends on. An older Claude Code release without
those subcommands cannot install this plugin.

## What's packaged

| Command | Invocation | Boundary |
| --- | --- | --- |
| `commands/solve.md` | `/solve` | Claims an issue, implements it in an isolated worktree, opens a PR. Stops after opening the PR; never reviews or merges. |
| `commands/pr-review.md` | `/pr-review` | Review-only. Runs the canonical issue-gated, opposite-brand (or dual, for unknown origin) review and publishes one verdict. Never edits, labels beyond the verdict, or merges. |
| `commands/pr-rereview.md` | `/pr-rereview` | Same as `/pr-review` for a changed PR; also removes a lingering `reviewed:revised` label after publishing, the one label mutation Kanban's own invocation prompts require of a review-only workflow. |
| `commands/pr-revise.md` | `/pr-revise` | Repairs a `reviewed:changes` PR in an isolated worktree, pushes safely, then hands off to exactly one canonical rereview. Never self-approves or merges. |

`pr-review`, `pr-rereview`, and `pr-revise` all delegate publication to the
bundled coordinator at `scripts/review_pr.py`. Claude Code exposes
`${CLAUDE_PLUGIN_ROOT}` inside a plugin's own commands, so each command
resolves the coordinator directly at `${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py`
without depending on where the plugin happened to be installed, and without
depending on the [Codex plugin](../codex-plugin/README.md) being installed at
all — this plugin bundles its own copy of the same coordinator logic so it is
fully self-sufficient on a Claude-only machine. The same `pr-review:v2`
marker/label state machine runs regardless of which command an agent session
starts from. The coordinator resolves the canonical issue-review backend the
same way `Kanban.Review.canonicalIssueReviewerPath` does
(`KANBAN_ISSUE_REVIEW_INSTALL_DIR`, falling back to the Kanban-managed install
directory under `~/Library/Application Support/kanban/issue-review/`); it
never hard-codes a personal path. None of the four commands set their own
model, reasoning effort, permission mode, or working directory — Kanban's own
CLI invocation pins those per action, and `tools/test_claude_plugin.py`
asserts none of the packaged manifests (or the coordinator's own nested-
reviewer invocations) override them.

For known-origin `/pr-review`/`/pr-rereview` — the case Kanban's own
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

`tools/test_claude_plugin.py` (run by
`python3 -m unittest discover -s tools -p 'test_*.py'`, which CI already
runs) checks that:

- the marketplace and plugin manifests are valid and point at this
  directory;
- the four packaged command names exactly match the `/`-prefixed tokens
  `src/Kanban/Solve.hs` and `src/Kanban/PullRequestFlow.hs` actually spawn;
- no packaged manifest sets model/effort/permission-mode/working-directory
  configuration;
- no packaged asset references a personal absolute path or the pre-migration
  compatibility launcher path (see
  [docs/agent-workflow-contract.md §3](../docs/agent-workflow-contract.md#3-migration-boundary));
- the bundled coordinator resolves the canonical issue-review backend the
  same way Kanban's Haskell code does, and its self-test passes standalone.

`tools/test_agent_workflow_contract.py` reconciles this plugin's own bash
surface (`claude-plugin/plugins/kanban/commands/*.md`) and bundled
coordinator against the same manifest in
[docs/agent-workflow-contract.md §4](../docs/agent-workflow-contract.md#4-dependency-manifest)
that the Codex plugin and Kanban's Haskell source are reconciled against.
