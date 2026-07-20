# Kanban Codex plugin

This directory is a Codex marketplace, tracked in this repository, that
packages the Codex-side workflows Kanban invokes by name: `$solve`,
`$pr-review`, `$pr-rereview`, and `$pr-revise`. It exists so a clean Codex
installation can perform these actions without depending on any developer's
personal skill collection. See
[docs/agent-workflow-contract.md](../docs/agent-workflow-contract.md) for
the full dependency contract these workflows implement, including the
`solve`/PR-flow authority boundaries and the canonical issue-review backend
they call into.

Claude packaging is a separate, not-yet-implemented phase; nothing here
covers `/solve` or the other Claude-side commands.

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

`kanban@kanban` should show as `installed, enabled`, and the four workflow
names should be available as `$solve`, `$pr-review`, `$pr-rereview`, and
`$pr-revise` in any Codex session run from this checkout.

Verified against Codex CLI `codex-cli 0.144.6` (`codex --version`), the
version that provides the `codex plugin` / `codex plugin marketplace`
subcommand family this install path depends on. An older Codex release
without those subcommands cannot install this plugin.

## What's packaged

| Skill | Codex command | Boundary |
| --- | --- | --- |
| `skills/solve/` | `$solve` | Claims an issue, implements it in an isolated worktree, opens a PR. Stops after opening the PR; never reviews or merges. |
| `skills/pr-review/` | `$pr-review` | Review-only. Runs the canonical issue-gated, opposite-brand (or dual, for unknown origin) review and publishes one verdict. Never edits, labels beyond the verdict, or merges. |
| `skills/pr-rereview/` | `$pr-rereview` | Same as `$pr-review` for a changed PR; also removes a lingering `reviewed:revised` label after publishing, the one label mutation Kanban's own invocation prompts require of a review-only workflow. |
| `skills/pr-revise/` | `$pr-revise` | Repairs a `reviewed:changes` PR in an isolated worktree, pushes safely, then hands off to exactly one canonical rereview. Never self-approves or merges. |

`pr-review`, `pr-rereview`, and `pr-revise` all delegate their actual
review-verdict publication to the bundled coordinator at
`skills/pr-review/scripts/review_pr.py`, referenced by the other two skills
through a portable sibling-relative path so the same review logic — and the
same `pr-review:v2` marker/label state machine — runs regardless of which
command an agent session starts from. The coordinator resolves the
canonical issue-review backend the same way
`Kanban.Review.canonicalIssueReviewerPath` does (`KANBAN_ISSUE_REVIEW_INSTALL_DIR`,
falling back to the Kanban-managed install directory under
`~/Library/Application Support/kanban/issue-review/`); it never hard-codes a
personal path. None of the four skills set their own model, reasoning
effort, sandbox, approval policy, or working directory — Kanban's own CLI
invocation pins those per action, and `tools/test_codex_plugin.py` asserts
none of the packaged manifests override them.

## Structural and contract coverage

`tools/test_codex_plugin.py` (run by
`python3 -m unittest discover -s tools -p 'test_*.py'`, which CI already
runs) checks that:

- the marketplace and plugin manifests are valid and point at this
  directory;
- the four packaged skill names exactly match the `$`-prefixed tokens
  `src/Kanban/Solve.hs` and `src/Kanban/PullRequestFlow.hs` actually spawn;
- no packaged manifest sets model/effort/sandbox/approval/working-directory
  configuration;
- no packaged asset references a personal absolute path or the pre-migration
  compatibility launcher path (see
  [docs/agent-workflow-contract.md §3](../docs/agent-workflow-contract.md#3-migration-boundary));
- the bundled coordinator resolves the canonical issue-review backend the
  same way Kanban's Haskell code does, and its self-test passes standalone.
