"""Parity check for docs/document-workflow-contract.md.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Guards the packaging promise of issue #229, the design/report counterpart of
what issue #118 did for drafting: the design-document and findings-report
contracts are tracked plugin assets rather than owner-local personal files, so
a repository pull request can change and verify them.

Reconciles the responsibility matrix in docs/document-workflow-contract.md
against the tracked Claude and Codex plugin trees, so a declared asset cannot
vanish, an undeclared design or report workflow cannot appear, the document
cannot silently drop the declared Codex-only asymmetry or the
$design-epic//epic boundary, and the status vocabulary the two process-report
variants must share cannot drift. The two variants are deliberately not
reconciled into one text (requirement 3 of issue #229): what is pinned here is
the surface a report started by one brand and resumed by the other depends on,
not their wording.

Discovery, frontmatter, and no-personal-path coverage for the same assets lives
in tools/test_claude_plugin.py and tools/test_codex_plugin.py; their
external-command surface is reconciled against the §4 dependency manifest by
tools/test_agent_workflow_contract.py.
"""

from __future__ import annotations

import re
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = REPO_ROOT / "docs" / "document-workflow-contract.md"

CLAUDE_COMMANDS_ROOT = REPO_ROOT / "claude-plugin" / "plugins" / "kanban" / "commands"
CODEX_SKILLS_ROOT = REPO_ROOT / "codex-plugin" / "plugins" / "kanban" / "skills"

# Workflow names that belong to the design/report document lifecycle rather
# than to the solve/PR-flow workflows Kanban's own CLI spawns or the drafting
# set docs/drafting-workflow-contract.md §2 declares. Any asset under either
# plugin whose workflow name is in this set must be declared in §2 of this
# contract.
DOCUMENT_WORKFLOW_NAMES = {
    "design-epic",
    "process-design-doc",
    "draft-report",
    "process-report",
}

EXPECTED_DECLARED_PATHS = {
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
    "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
}

# The three workflows §3.5 declares Codex-only. The Claude plugin must not grow
# a counterpart under this contract: authoring one would be new behavior no
# pinned source defines.
CODEX_ONLY_WORKFLOWS = ("design-epic", "process-design-doc", "draft-report")

# The marker vocabulary every declared asset states, as raw literals: these are
# the interface between two runs, two brands, and two sessions, so an
# HTML-entity-escaped or reworded transcription is drift, not formatting.
STATUS_MARKER_LITERALS = ("[#N]", "[no-issue]", "[deferred]")

# The status-checklist form. Both are required of every asset that applies a
# disposition; $design-epic and $draft-report never write a terminal marker, so
# they carry only the unchecked form (§4).
CHECKED_FORM = "- [x]"
UNCHECKED_FORM = "- [ ]"

DISPOSITION_APPLYING_ASSETS = (
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "codex-plugin/plugins/kanban/skills/process-design-doc/SKILL.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
)

# The one cross-brand pair in this contract, and therefore the only place a
# report started by one brand can stop being resumable by the other.
PROCESS_REPORT_ASSETS = (
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
)

# §5's boundaries, asserted against both process-report variants as well as the
# document. Lowercase: compared against canonical() output, because the same
# rule legitimately starts a sentence in one variant and appears mid-sentence
# in the other.
PROCESS_REPORT_SHARED_BOUNDARIES = (
    "process exactly one finding",
    "stop for explicit approval",
    "only after explicit approval",
    "stop after this one finding",
    "the one-at-a-time rule is what keeps each disposition individually approved",
)

# Boundaries and asymmetries the document itself must keep stating. Compared
# against normalized() output, so reflowing a paragraph or bolding a phrase
# does not fail CI.
CONTRACT_STATEMENTS = {
    "haskell-parity-exclusion": "user-invoked and never spawned by Kanban's CLI",
    "codex-only-asymmetry": (
        "$design-epic, $process-design-doc, and $draft-report are Codex-only"
    ),
    "codex-only-has-no-counterpart": "No Claude counterpart exists",
    "codex-only-is-declared": "a declared gap rather than an oversight",
    "design-epic-creates-nothing": (
        "$design-epic produces a durable design document and creates no tracker items"
    ),
    "epic-stays-unpackaged": "remains unpackaged in both plugins",
    "one-artifact-per-invocation": "One artifact per invocation",
    "stop-for-explicit-approval": "Stop for explicit approval",
}

DECLARED_ASSET_ROW_RE = re.compile(
    r"^(?P<brand>claude|codex)\s*\|\s*(?P<invocation>[/$][\w-]+)\s*\|\s*(?P<path>\S+)$"
)

SECTION_2_FENCE_RE = re.compile(
    r"^##\s*2\.\s*Declared assets\s*$.*?```text\n(?P<body>.*?)\n```",
    re.DOTALL | re.MULTILINE,
)


def contract_text() -> str:
    return CONTRACT_PATH.read_text(encoding="utf-8")


def normalized(text: str) -> str:
    """Collapse whitespace and drop markdown emphasis so an assertion on a
    documented boundary survives reflowing a paragraph or bolding a word."""
    return re.sub(r"\s+", " ", text.replace("*", "").replace("`", ""))


def canonical(text: str) -> str:
    """normalized() plus case folding, for prose asserted across files where
    the same rule legitimately starts a sentence in one and appears
    mid-sentence in another."""
    return normalized(text).lower()


def parse_declared_assets(text=None):
    """Rows from the §2 machine-readable fence, keyed by repository-relative
    path. Anchored to the §2 heading so an unrelated ```text fence elsewhere in
    the document can never be parsed as the declared-asset list."""
    fence_match = SECTION_2_FENCE_RE.search(contract_text() if text is None else text)
    if fence_match is None:
        raise AssertionError(
            "docs/document-workflow-contract.md has no ```text declared-asset "
            "fence under its '## 2. Declared assets' heading"
        )
    rows = {}
    for line in fence_match.group("body").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = DECLARED_ASSET_ROW_RE.match(line)
        if match is None:
            raise AssertionError(f"unparseable declared-asset row: {line!r}")
        row = match.groupdict()
        if row["path"] in rows:
            raise AssertionError(f"duplicate declared-asset row for {row['path']!r}")
        rows[row["path"]] = row
    return rows


def discovered_document_assets(
    claude_commands_root=CLAUDE_COMMANDS_ROOT,
    codex_skills_root=CODEX_SKILLS_ROOT,
    repo_root=REPO_ROOT,
):
    """Every design or report document workflow actually present under either
    plugin, as repository-relative paths. Parameterized by root so the
    load-bearing tests below can drive it against a planted tree rather than
    only against the tree that already passes."""
    found = set()
    if claude_commands_root.is_dir():
        for command_md in sorted(claude_commands_root.glob("*.md")):
            if command_md.stem in DOCUMENT_WORKFLOW_NAMES:
                found.add(command_md.relative_to(repo_root).as_posix())
    if codex_skills_root.is_dir():
        for skill_dir in sorted(codex_skills_root.iterdir()):
            if skill_dir.is_dir() and skill_dir.name in DOCUMENT_WORKFLOW_NAMES:
                found.add((skill_dir / "SKILL.md").relative_to(repo_root).as_posix())
    return found


def missing_declared_assets(declared, repo_root=REPO_ROOT):
    return sorted(path for path in declared if not (repo_root / path).is_file())


def missing_contract_statements(text):
    """The §-level boundaries `text` no longer states, by key."""
    document = normalized(text)
    return sorted(
        key
        for key, statement in CONTRACT_STATEMENTS.items()
        if statement not in document
    )


def missing_marker_literals(text):
    """The exact §4 status literals `text` no longer states."""
    return [
        literal
        for literal in (*STATUS_MARKER_LITERALS, CHECKED_FORM, UNCHECKED_FORM)
        if literal not in text
    ]


class DeclaredAssetTests(unittest.TestCase):
    def setUp(self):
        self.declared = parse_declared_assets()

    def test_declared_assets_are_exactly_the_five_packaged_workflows(self):
        self.assertEqual(set(self.declared), EXPECTED_DECLARED_PATHS)

    def test_every_declared_asset_exists_in_the_tracked_tree(self):
        missing = missing_declared_assets(self.declared)
        self.assertEqual(
            missing,
            [],
            f"declared in docs/document-workflow-contract.md §2 but absent: {missing}",
        )

    def test_a_deleted_declared_asset_is_reported(self):
        # The absence check is load-bearing rather than decorative: point it at
        # a tree where a declared asset is gone and it names that asset.
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            for path in EXPECTED_DECLARED_PATHS - {
                "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md"
            }:
                target = repo_root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("---\nname: x\n---\n", encoding="utf-8")
            self.assertEqual(
                missing_declared_assets(self.declared, repo_root=repo_root),
                ["codex-plugin/plugins/kanban/skills/draft-report/SKILL.md"],
            )

    def test_no_undeclared_document_workflow_asset_exists(self):
        undeclared = sorted(discovered_document_assets() - set(self.declared))
        self.assertEqual(
            undeclared,
            [],
            "design/report document workflows exist under a plugin without a §2 "
            f"row in docs/document-workflow-contract.md: {undeclared}",
        )

    def test_an_undeclared_asset_added_to_either_plugin_is_reported(self):
        # The realistic regression this guards is a Claude counterpart to one
        # of the Codex-only workflows appearing without §3.5 being revisited.
        with tempfile.TemporaryDirectory() as temp_dir:
            repo_root = Path(temp_dir)
            commands = repo_root / "claude-plugin" / "plugins" / "kanban" / "commands"
            skills = repo_root / "codex-plugin" / "plugins" / "kanban" / "skills"
            commands.mkdir(parents=True)
            (skills / "draft-report").mkdir(parents=True)
            (commands / "design-epic.md").write_text("---\n---\n", encoding="utf-8")
            (commands / "solve.md").write_text("---\n---\n", encoding="utf-8")
            (skills / "draft-report" / "SKILL.md").write_text("x\n", encoding="utf-8")
            found = discovered_document_assets(
                claude_commands_root=commands,
                codex_skills_root=skills,
                repo_root=repo_root,
            )
        self.assertEqual(
            sorted(found - EXPECTED_DECLARED_PATHS),
            ["claude-plugin/plugins/kanban/commands/design-epic.md"],
        )

    def test_declared_brand_and_invocation_match_the_assets_own_plugin_and_name(self):
        for path, row in sorted(self.declared.items()):
            expected_prefix = (
                "claude-plugin/" if row["brand"] == "claude" else "codex-plugin/"
            )
            self.assertTrue(
                path.startswith(expected_prefix),
                f"{path} is declared brand {row['brand']!r} but lives under the other plugin",
            )
            expected_sigil = "/" if row["brand"] == "claude" else "$"
            self.assertTrue(
                row["invocation"].startswith(expected_sigil),
                f"{path}: {row['brand']} invocation must start with {expected_sigil!r}",
            )
            workflow_name = row["invocation"][1:]
            self.assertIn(workflow_name, DOCUMENT_WORKFLOW_NAMES, path)
            stem = (
                Path(path).parent.name
                if path.endswith("/SKILL.md")
                else Path(path).stem
            )
            self.assertEqual(
                stem,
                workflow_name,
                f"{path} does not implement its declared invocation {row['invocation']!r}",
            )

    def test_the_three_codex_only_workflows_are_declared_for_codex_alone(self):
        for name in CODEX_ONLY_WORKFLOWS:
            rows = [
                row
                for row in self.declared.values()
                if row["invocation"][1:] == name
            ]
            self.assertEqual(len(rows), 1, name)
            self.assertEqual(rows[0]["brand"], "codex", name)
            self.assertFalse(
                (CLAUDE_COMMANDS_ROOT / f"{name}.md").exists(),
                f"{name} is Codex-only (docs/document-workflow-contract.md §3.5); "
                "the Claude plugin must not package a counterpart",
            )

    def test_process_report_is_the_only_cross_brand_pair(self):
        by_workflow = {}
        for row in self.declared.values():
            by_workflow.setdefault(row["invocation"][1:], set()).add(row["brand"])
        self.assertEqual(by_workflow["process-report"], {"claude", "codex"})
        self.assertEqual(
            sorted(name for name, brands in by_workflow.items() if len(brands) > 1),
            ["process-report"],
        )


class DocumentedBoundaryTests(unittest.TestCase):
    """§3.5's declared Codex-only asymmetry, §3.6's design-pipeline
    epic-planner boundary, §1's Haskell invocation-parity exclusion, and §5's
    two processing boundaries are load-bearing: they are the reason the Claude
    plugin's declared set here is one asset rather than five, the reason an
    epic asset is still packaged in neither plugin, and the reason Kanban's
    CLI never spawns any of these."""

    def test_document_states_every_declared_boundary(self):
        self.assertEqual(missing_contract_statements(contract_text()), [])

    def test_removing_a_boundary_statement_is_reported(self):
        # Each statement is checked, not just present somewhere: mutate one at
        # a time and confirm exactly that key is reported.
        text = contract_text()
        for key, statement in CONTRACT_STATEMENTS.items():
            with self.subTest(statement=key):
                mutated = normalized(text).replace(statement, "")
                self.assertEqual(missing_contract_statements(mutated), [key])

    def test_document_distinguishes_capture_from_processing(self):
        document = normalized(contract_text())
        self.assertIn("One artifact per invocation", document)
        self.assertIn("the durable cursor", document)


class SharedStatusVocabularyTests(unittest.TestCase):
    """Requirement 5 of issue #229: the marker vocabulary is the compatibility
    surface between two runs, two brands, and two sessions, so it is asserted
    as raw, unescaped literals in the document and in the packaged assets
    themselves — not only in the prose describing them."""

    def test_the_document_states_every_exact_literal(self):
        self.assertEqual(missing_marker_literals(contract_text()), [])

    def test_dropping_a_literal_from_the_document_is_reported(self):
        text = contract_text()
        for literal in (*STATUS_MARKER_LITERALS, CHECKED_FORM, UNCHECKED_FORM):
            with self.subTest(literal=literal):
                mutated = text.replace(literal, "<removed>")
                self.assertEqual(missing_marker_literals(mutated), [literal])

    def test_every_declared_asset_states_the_marker_vocabulary(self):
        missing = []
        for path in sorted(EXPECTED_DECLARED_PATHS):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            for literal in STATUS_MARKER_LITERALS:
                if literal not in text:
                    missing.append(f"{path}: missing exact status literal {literal!r}")
            if UNCHECKED_FORM not in text:
                missing.append(f"{path}: missing exact checklist form {UNCHECKED_FORM!r}")
        self.assertEqual(missing, [], "\n".join(missing))

    def test_every_disposition_applying_asset_states_the_checked_form(self):
        for path in DISPOSITION_APPLYING_ASSETS:
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertIn(
                CHECKED_FORM,
                text,
                f"{path} applies terminal dispositions and must state the exact "
                f"checklist form {CHECKED_FORM!r}",
            )

    def test_the_capture_workflows_never_write_a_checked_box(self):
        # §4: $design-epic and $draft-report apply no disposition, so a checked
        # box in a document they just produced would be a bug. This is the
        # other half of the assertion above, not decoration: without it, the
        # checked form could quietly spread to the workflows that must not
        # write one.
        for path in (
            "codex-plugin/plugins/kanban/skills/design-epic/SKILL.md",
            "codex-plugin/plugins/kanban/skills/draft-report/SKILL.md",
        ):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertNotIn(
                CHECKED_FORM,
                text,
                f"{path} creates a document rather than processing one; it must "
                "not write a terminal checklist entry",
            )

    def test_both_process_report_variants_state_the_same_shared_surface(self):
        variants = {
            path: (REPO_ROOT / path).read_text(encoding="utf-8")
            for path in PROCESS_REPORT_ASSETS
        }
        differences = []
        for path, text in sorted(variants.items()):
            for literal in (*STATUS_MARKER_LITERALS, CHECKED_FORM, UNCHECKED_FORM):
                if literal not in text:
                    differences.append(f"{path}: missing shared literal {literal!r}")
            canonical_text = canonical(text)
            for boundary in PROCESS_REPORT_SHARED_BOUNDARIES:
                if boundary not in canonical_text:
                    differences.append(f"{path}: missing shared boundary {boundary!r}")
        self.assertEqual(
            differences,
            [],
            "the two process-report variants may differ in wording, but not on "
            "the surface docs/document-workflow-contract.md §4-§5 pins:\n"
            + "\n".join(differences),
        )


if __name__ == "__main__":
    unittest.main()
