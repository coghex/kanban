"""Where the solve family puts a verdict or evidence write-up (issue #823).

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

A verdict or evidence write-up records finished work from the moment it is
written, so it goes under docs/archive/, which consuming repositories hide from
search; design notes and contracts are updated where they live. Nothing said so,
and a repository's searches filled with history as a result: in hetoimasia,
11,230 of 14,741 matches for one common word came from records.

There is no behavioral prompt-testing harness, so the reviewable property is the
asset text itself, exactly as WriteLocationTests in
tools/test_drafting_workflow_contract.py treats the drafting workflows' write
locations.
"""

import unittest

from test_drafting_workflow_contract import REPO_ROOT, canonical

# Every solve-family asset that lands documentation, or hands it to solve, in
# every bundle that ships it. An asset rendered from tools/command_sources/ is
# listed by its output; test_render_command_sources.py holds output to source.
ARCHIVE_RULE_ASSETS = (
    "claude-plugin/plugins/kanban/commands/solve.md",
    "claude-plugin/plugins/kanban/commands/autosolve.md",
    "claude-plugin/plugins/kanban/commands/pr-revise.md",
    "claude-plugin/plugins/kanban/commands/fix.md",
    "codex-plugin/plugins/kanban/skills/solve/SKILL.md",
    "codex-plugin/plugins/kanban/skills/autosolve/SKILL.md",
    "codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md",
    "codex-plugin/plugins/kanban/skills/fix/SKILL.md",
    "grok-plugin/plugins/kanban/skills/solve/SKILL.md",
    "grok-plugin/plugins/kanban/skills/autosolve/SKILL.md",
    "kimi-plugin/plugins/kanban/skills/solve/SKILL.md",
    "kimi-plugin/plugins/kanban/skills/autosolve/SKILL.md",
    "google-plugin/plugins/kanban/skills/solve/SKILL.md",
    "google-plugin/plugins/kanban/skills/autosolve/SKILL.md",
    "claude-copilot-plugin/plugins/kanban/skills/solve/SKILL.md",
    "claude-copilot-plugin/plugins/kanban/skills/autosolve/SKILL.md",
)

# The document workflows land documents too, but theirs are live while they
# are worked: moving a finished report or design is #824's, not this rule's.
# They must not state it, which keeps the rules below from passing vacuously.
NOT_ARCHIVE_RULE_ASSETS = (
    "claude-plugin/plugins/kanban/commands/design-epic.md",
    "claude-plugin/plugins/kanban/commands/draft-report.md",
    "claude-plugin/plugins/kanban/commands/note-problem.md",
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "claude-plugin/plugins/kanban/commands/process-design-doc.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
    "codex-plugin/plugins/kanban/skills/note-problem/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
)

# Lowercase: compared against canonical() output.
ARCHIVE_RULES = (
    # Where a record goes, and what keeps the issue's own choice.
    "unless the spec names its path, a verdict or evidence write-up goes under docs/archive/",
    # What does not move.
    "design notes and contracts are updated where they live",
    # The destination changes; what may land, and how, does not.
    "that decides only where the file goes, not how it lands",
)


def archive_rule_findings(assets, rules):
    """Every (asset, rule) pair whose canonicalized text omits the rule."""
    return [
        f"{path}: missing archive rule {rule!r}"
        for path, text in assets.items()
        for rule in rules
        if rule not in text
    ]


def read(paths):
    return {path: canonical((REPO_ROOT / path).read_text(encoding="utf-8")) for path in paths}


class ArchiveRecordLocationTests(unittest.TestCase):
    def setUp(self):
        self.assets = read(ARCHIVE_RULE_ASSETS)

    def test_every_solve_family_asset_states_every_rule(self):
        missing = archive_rule_findings(self.assets, ARCHIVE_RULES)
        self.assertEqual(missing, [], "\n".join(missing))

    def test_dropping_a_rule_from_one_asset_is_reported(self):
        # Removal from any single asset must fail the same predicate the
        # presence check drives, so a later edit cannot quietly drop one.
        for path in ARCHIVE_RULE_ASSETS:
            for rule in ARCHIVE_RULES:
                mutated = dict(self.assets)
                mutated[path] = mutated[path].replace(rule, "")
                self.assertIn(
                    f"{path}: missing archive rule {rule!r}",
                    archive_rule_findings(mutated, ARCHIVE_RULES),
                )

    def test_the_rules_are_not_vacuous(self):
        offenders = [
            f"{path} now states {rule!r}; move it to ARCHIVE_RULE_ASSETS if that is intended"
            for path, text in read(NOT_ARCHIVE_RULE_ASSETS).items()
            for rule in ARCHIVE_RULES
            if rule in text
        ]
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_the_external_autosolve_refusal_survives(self):
        # The external bundles ship no landing helper, and the rule must not
        # read as one: their documentation-only stop still stands.
        for brand in ("grok", "kimi", "google", "claude-copilot"):
            text = canonical(
                (
                    REPO_ROOT / f"{brand}-plugin/plugins/kanban/skills/autosolve/SKILL.md"
                ).read_text(encoding="utf-8")
            )
            self.assertIn("it opens no landing this bundle does not ship", text, brand)
            self.assertIn("do not invent a landing", text, brand)


if __name__ == "__main__":
    unittest.main()
