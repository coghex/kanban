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
import subprocess
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


# Issue #829 retired the /push-docs workflow and the tools/docs_land.sh and
# tools/docs_land_paths.py helpers behind it. Nothing tracked may name them
# again except where the retirement is the subject.
RETIRED_LANDING_NAMES = re.compile(r"docs_land|push-docs|push_docs")

# Paths allowed to carry a retired name, and why: history that must not be
# rewritten, the publisher's frozen diagnostic (the same string in its two
# bundled copies, until the publisher is replaced), and this module, whose
# pattern above is the rejected literal.
RETIRED_NAME_EXEMPT_PATHS = (
    "CHANGELOG.md",
    "docs/product_readiness_findings.md",
    "docs/coordination/process-report-publication-removal.md",
    "tools/publish_coordination_doc.py",
    "claude-plugin/plugins/kanban/scripts/publish_coordination_doc.py",
    "codex-plugin/plugins/kanban/skills/process-report/scripts/publish_coordination_doc.py",
    "tools/test_docs_landing_workflow.py",
)
RETIRED_NAME_EXEMPT_PREFIXES = ("docs/designs/",)

def without_migration_notes(text):
    """`text` with each "Migration note" section removed: a section headed
    so explains the retirement and names the retired tools by design. It runs
    to the next heading of the same or a higher level."""
    out = []
    skipping = None
    for line in text.splitlines(keepends=True):
        heading = re.match(r"(#{1,6}) ", line)
        if heading:
            level = len(heading.group(1))
            if skipping is not None and level <= skipping:
                skipping = None
            if skipping is None and line[level:].startswith(" Migration note"):
                skipping = level
        if skipping is None:
            out.append(line)
    return "".join(out)


def retired_name_offenders(files):
    """Every `path:line` in `files` (a mapping of path to text) that names a
    retired landing-lane tool outside the exempt paths and migration notes."""
    offenders = []
    for path, text in sorted(files.items()):
        if path in RETIRED_NAME_EXEMPT_PATHS or path.startswith(
            RETIRED_NAME_EXEMPT_PREFIXES
        ):
            continue
        for number, line in enumerate(without_migration_notes(text).splitlines(), 1):
            if RETIRED_LANDING_NAMES.search(line):
                offenders.append(f"{path}:{number}")
    return offenders


def tracked_text_files():
    listing = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "ls-files", "-z"],
        capture_output=True,
        check=False,
    )
    if listing.returncode != 0:
        return None
    files = {}
    for name in listing.stdout.decode("utf-8").split("\0"):
        if not name:
            continue
        path = REPO_ROOT / name
        try:
            files[name] = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
    return files


class RetiredLandingLaneTests(unittest.TestCase):
    def test_no_tracked_asset_names_the_retired_lane(self):
        files = tracked_text_files()
        if files is None:
            self.skipTest("not a git work tree")
        self.assertEqual(retired_name_offenders(files), [])

    def test_the_scan_sees_a_retired_name_and_spares_a_migration_note(self):
        # A rule that matched nothing, or everything, would pass the test
        # above while asserting nothing.
        sample = {
            "a.md": "run tools/docs_" + "land.sh now\n",
            "b.md": "use /push" + "-docs\n",
            "c.md": "# Title\n\n## Migration note: gone\n\nthe push_" + "docs tool\n\n## Next\n\nclean\n",
            "d.md": "## Next\n\nclean\n## Migration note\nnames push" + "-docs\n### Sub\nstill push" + "-docs\n",
            "docs/designs/e.md": "push" + "-docs\n",
            "CHANGELOG.md": "push" + "-docs\n",
        }
        self.assertEqual(retired_name_offenders(sample), ["a.md:1", "b.md:1"])

    def test_the_retired_files_stay_deleted(self):
        for relative in (
            "tools/docs_" + "land.sh",
            "tools/docs_" + "land_paths.py",
            "claude-plugin/plugins/kanban/commands/push" + "-docs.md",
            "codex-plugin/plugins/kanban/skills/push" + "-docs",
        ):
            with self.subTest(path=relative):
                self.assertFalse((REPO_ROOT / relative).exists())


if __name__ == "__main__":
    unittest.main()
