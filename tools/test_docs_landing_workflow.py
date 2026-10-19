"""How the workflows land documentation with the owner's docs-push tool.

The tool itself lives outside this repository and carries its own behavioral
tests; what is reviewable here is the asset text, held to the
WriteLocationTests pattern of tools/test_drafting_workflow_contract.py: each
rule asserted against every asset that owes it, removal shown to be detected,
and a negative control over assets that must state none of it.

Pinned from the PR #792 review:

* A publishing asset lands exactly the bytes the publication helper approved
  (`--expect` with the helper's `approved_blob`), so an edit made beside the
  run never lands with it.
* Every landing keeps the landed copy in the docs worktree (`--keep`), so a
  docs worktree whose branch carries commits of its own still holds what the
  next run reads.
* docs-push publishes to the checkout's own origin, so the workflows that move
  a change's documentation off the pull-request branch do it only when that
  origin is the pull request's repository, never from a fork checkout.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

PUBLISHING_ASSETS = (
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
    "claude-plugin/plugins/kanban/commands/process-design-doc.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
    "claude-plugin/plugins/kanban/commands/note-problem.md",
    "codex-plugin/plugins/kanban/skills/note-problem/SKILL.md",
)

DRAFTING_ASSETS = (
    "claude-plugin/plugins/kanban/commands/draft-report.md",
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
    "claude-plugin/plugins/kanban/commands/design-epic.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
)

SOLVE_ASSETS = (
    "claude-plugin/plugins/kanban/commands/solve.md",
    "codex-plugin/plugins/kanban/skills/solve/SKILL.md",
    "tools/command_sources/external/solve.md",
    "grok-plugin/plugins/kanban/skills/solve/SKILL.md",
    "kimi-plugin/plugins/kanban/skills/solve/SKILL.md",
    "google-plugin/plugins/kanban/skills/solve/SKILL.md",
    "claude-copilot-plugin/plugins/kanban/skills/solve/SKILL.md",
)

PR_FIX_ASSETS = (
    "claude-plugin/plugins/kanban/commands/pr-revise.md",
    "codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md",
    "claude-plugin/plugins/kanban/commands/repair.md",
    "codex-plugin/plugins/kanban/skills/repair/SKILL.md",
    "tools/command_sources/fix.md",
    "claude-plugin/plugins/kanban/commands/fix.md",
    "codex-plugin/plugins/kanban/skills/fix/SKILL.md",
)

NEGATIVE_CONTROLS = (
    "claude-plugin/plugins/kanban/commands/triage.md",
    "codex-plugin/plugins/kanban/skills/triage/SKILL.md",
)

PUBLISHING_RULES = (
    'result="$(python3 "$publish_doc"',
    'print(json.loads(os.environ["result"])["approved_blob"])',
    'docs-push --expect "$approved_blob" --keep',
    "--expect lands exactly the bytes the helper wrote for this approval",
    "refuses when the document changed after the helper wrote it",
    "--keep leaves the landed copy in the docs worktree",
)

DRAFTING_RULES = (
    "docs-push --keep -m",
    "--keep leaves the landed copy in the docs worktree, where later runs read it",
)

SOLVE_RULES = (
    "docs-push publishes to this checkout's own origin",
    'gh repo view "$(git remote get-url origin)" --json namewithowner --jq '
    ".namewithowner names $repo",
    "from a fork checkout, commit the documentation to the branch like the code",
)

PR_FIX_RULES = (
    "or this checkout's own origin is not the pull request's base repository "
    "(a fork checkout)",
    "in either case the documentation is committed to the branch like the code",
)

ALL_RULES = PUBLISHING_RULES + DRAFTING_RULES + SOLVE_RULES + PR_FIX_RULES


def canonical(text: str) -> str:
    return re.sub(r"\s+", " ", text.replace("*", "").replace("`", "")).lower()


def read(relative_path: str) -> str:
    return canonical((REPO_ROOT / relative_path).read_text(encoding="utf-8"))


def missing(text: str, rules) -> list[str]:
    return [rule for rule in rules if rule not in text]


class DocsLandingWorkflowTests(unittest.TestCase):
    GROUPS = (
        (PUBLISHING_ASSETS, PUBLISHING_RULES),
        (DRAFTING_ASSETS, DRAFTING_RULES),
        (SOLVE_ASSETS, SOLVE_RULES),
        (PR_FIX_ASSETS, PR_FIX_RULES),
    )

    def test_every_asset_states_its_rules(self):
        for assets, rules in self.GROUPS:
            for path in assets:
                with self.subTest(path=path):
                    self.assertEqual(missing(read(path), rules), [])

    def test_removing_a_rule_is_reported(self):
        for assets, rules in self.GROUPS:
            for path in assets:
                text = read(path)
                for rule in rules:
                    with self.subTest(path=path, rule=rule):
                        self.assertEqual(missing(text.replace(rule, ""), rules), [rule])

    def test_the_rules_are_not_vacuous(self):
        for path in NEGATIVE_CONTROLS:
            with self.subTest(path=path):
                self.assertEqual(missing(read(path), ALL_RULES), list(ALL_RULES))

    def test_only_the_publishing_assets_land_against_the_approved_blob(self):
        # A drafting asset has no helper result to bind to, so it must not
        # claim an --expect it cannot supply.
        for path in DRAFTING_ASSETS + SOLVE_ASSETS + PR_FIX_ASSETS:
            with self.subTest(path=path):
                self.assertNotIn("docs-push --expect", read(path))


if __name__ == "__main__":
    unittest.main()
