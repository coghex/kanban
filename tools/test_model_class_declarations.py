"""Every Claude command and Codex skill declares the model class it runs in.

The owner chooses models by class (S, A, B), not by name: a workflow says which
class of session it needs, and the owner's `modelclass` resolves the class to
whatever models are current. Each workflow asset carries exactly one class line,
and this file pins which class each workflow is in, so a new command that ships
without one, or a class that changes by accident, fails here.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
CLAUDE_COMMANDS = REPO_ROOT / "claude-plugin" / "plugins" / "kanban" / "commands"
CODEX_SKILLS = REPO_ROOT / "codex-plugin" / "plugins" / "kanban" / "skills"
COMMAND_SOURCES = REPO_ROOT / "tools" / "command_sources"

CLASS_LINE = re.compile(
    r"^Run this in a \*\*Class (?P<cls>[A-Z])\*\* session "
    r"\(see the `model-classes` skill\)\.$",
    re.MULTILINE,
)

EXPECTED_CLASS = {
    # S: the hardest judgment calls -- drafting, design, and canonical review.
    "issue": "S", "autoissue": "S", "draft-issues": "S", "design-epic": "S",
    "draft-report": "S", "issue-review": "S", "issue-rereview": "S",
    "pr-review": "S", "pr-rereview": "S", "project-review": "S",
    "auto-project-review": "S",
    # A: most work -- implementing, repairing, processing.
    "solve": "A", "autosolve": "A", "pr-revise": "A", "fix": "A", "repair": "A",
    "process-design-doc": "A", "process-report": "A", "note-problem": "A",
    "backlog-review": "A",
    # B: narrow, well-specified, operational work.
    "triage": "B", "retriage": "B", "drain-prs": "B", "finalize": "B",
    "janitor": "B", "push-docs": "B",
}


def declared_classes(path: Path) -> list[str]:
    return [m.group("cls") for m in CLASS_LINE.finditer(path.read_text())]


class ModelClassDeclarationTests(unittest.TestCase):
    def assert_declares(self, path: Path, name: str) -> None:
        self.assertIn(name, EXPECTED_CLASS, f"{path} has no expected class; add it")
        self.assertEqual(
            declared_classes(path), [EXPECTED_CLASS[name]],
            f"{path.relative_to(REPO_ROOT)} must declare exactly one Class "
            f"{EXPECTED_CLASS[name]} line",
        )

    def test_every_claude_command_declares_its_class(self):
        commands = sorted(CLAUDE_COMMANDS.glob("*.md"))
        self.assertTrue(commands)
        for path in commands:
            with self.subTest(command=path.stem):
                self.assert_declares(path, path.stem)

    def test_every_codex_skill_declares_its_class(self):
        skills = sorted(CODEX_SKILLS.glob("*/SKILL.md"))
        self.assertTrue(skills)
        for path in skills:
            with self.subTest(skill=path.parent.name):
                self.assert_declares(path, path.parent.name)

    def test_every_rendered_source_declares_the_class_its_outputs_carry(self):
        sources = sorted(COMMAND_SOURCES.glob("*.md"))
        for path in sources:
            if path.stem == "fixture-command":
                continue
            with self.subTest(source=path.stem):
                self.assert_declares(path, path.stem)

    def test_assets_outside_the_claude_and_codex_bundles_declare_nothing(self):
        # Negative control: the rule must not pass by matching everything. The
        # renderer's fixture and the external brands' sources carry no class.
        controls = [COMMAND_SOURCES / "fixture-command.md",
                    *sorted((COMMAND_SOURCES / "external").glob("*.md"))]
        self.assertTrue(all(p.exists() for p in controls))
        for path in controls:
            with self.subTest(control=path.name):
                self.assertEqual(declared_classes(path), [])

    def test_the_expected_table_names_no_retired_workflow(self):
        shipped = {p.stem for p in CLAUDE_COMMANDS.glob("*.md")}
        shipped |= {p.parent.name for p in CODEX_SKILLS.glob("*/SKILL.md")}
        self.assertEqual(sorted(set(EXPECTED_CLASS) - shipped), [])


if __name__ == "__main__":
    unittest.main()
