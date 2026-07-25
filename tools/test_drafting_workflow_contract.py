"""Parity check for docs/drafting-workflow-contract.md.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Guards the packaging promise of issue #118: the issue-drafting and canonical
issue-review contracts are tracked plugin assets rather than owner-local
personal files, so a repository pull request can change and verify them.

Reconciles the responsibility matrix in docs/drafting-workflow-contract.md
against the tracked Claude and Codex plugin trees, so a declared asset cannot
vanish, an undeclared drafting or issue-review asset cannot appear, an
origin-marker literal cannot drift from what tools/approve_issues.py parses,
and the document cannot silently drop the Claude-only /draft-issues boundary
or the non-hunting, unpackaged /epic boundary.

Discovery, frontmatter, and no-personal-path coverage for the same assets
lives in tools/test_claude_plugin.py and tools/test_codex_plugin.py; their
external-command and user-scoped-path surface is reconciled against the §4
dependency manifest by tools/test_agent_workflow_contract.py.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = REPO_ROOT / "docs" / "drafting-workflow-contract.md"

CLAUDE_COMMANDS_ROOT = REPO_ROOT / "claude-plugin" / "plugins" / "kanban" / "commands"
CODEX_SKILLS_ROOT = REPO_ROOT / "codex-plugin" / "plugins" / "kanban" / "skills"

# Workflow names that are drafting or issue-review workflows rather than the
# solve/PR-flow workflows Kanban's own CLI spawns. Any asset under either
# plugin whose workflow name is in this set must be declared in §2.
DRAFTING_WORKFLOW_NAMES = {"issue", "draft-issues", "autoissue", "issue-review"}

EXPECTED_DECLARED_PATHS = {
    "claude-plugin/plugins/kanban/commands/issue.md",
    "claude-plugin/plugins/kanban/commands/draft-issues.md",
    "claude-plugin/plugins/kanban/commands/autoissue.md",
    "claude-plugin/plugins/kanban/commands/issue-review.md",
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md",
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md",
    "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md",
}

# The exact literals tools/approve_issues.py's ORIGIN_RE parses and
# src/Kanban/Review.hs tells reviewers to find. Raw and unescaped: an
# HTML-entity-escaped transcription would not match the parser.
CLAUDE_ORIGIN_MARKER = "<!-- issue-origin:claude -->"
CODEX_ORIGIN_MARKER = "<!-- issue-origin:codex -->"

ORIGIN_MARKER_BY_BRAND = {"claude": CLAUDE_ORIGIN_MARKER, "codex": CODEX_ORIGIN_MARKER}

# The drafting assets that actually create issues, and therefore must carry
# their brand's origin marker. The issue-review workflows never create an
# issue, so they are deliberately exempt.
ISSUE_CREATING_ASSETS = {
    "claude-plugin/plugins/kanban/commands/issue.md": "claude",
    "claude-plugin/plugins/kanban/commands/draft-issues.md": "claude",
    "claude-plugin/plugins/kanban/commands/autoissue.md": "claude",
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md": "codex",
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md": "codex",
}

AUTOISSUE_ASSETS = {
    "claude-plugin/plugins/kanban/commands/autoissue.md": "/",
    "codex-plugin/plugins/kanban/skills/autoissue/SKILL.md": "$",
}

ISSUE_REVIEW_BACKEND_ASSETS = (
    "claude-plugin/plugins/kanban/commands/issue-review.md",
    "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md",
)

# The Kanban-managed install path every packaged issue-review surface must
# resolve (docs/agent-workflow-contract.md §3), and the pre-migration
# compatibility launcher none of them may reference.
BACKEND_ENV_OVERRIDE = "KANBAN_ISSUE_REVIEW_INSTALL_DIR"
BACKEND_DEFAULT_PATH = "Library/Application Support/kanban/issue-review"
FORBIDDEN_BACKEND_PATHS = ("~/work/approve-issues", "$HOME/work/")

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


def parse_declared_assets():
    """Rows from the §2 machine-readable fence, keyed by repository-relative
    path. Anchored to the §2 heading so an unrelated ```text fence elsewhere
    in the document can never be parsed as the declared-asset list."""
    fence_match = SECTION_2_FENCE_RE.search(contract_text())
    if fence_match is None:
        raise AssertionError(
            "docs/drafting-workflow-contract.md has no ```text declared-asset "
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


def discovered_drafting_assets():
    """Every drafting or issue-review asset actually present under either
    plugin, as repository-relative paths."""
    found = set()
    for command_md in sorted(CLAUDE_COMMANDS_ROOT.glob("*.md")):
        if command_md.stem in DRAFTING_WORKFLOW_NAMES:
            found.add(command_md.relative_to(REPO_ROOT).as_posix())
    if CODEX_SKILLS_ROOT.is_dir():
        for skill_dir in sorted(CODEX_SKILLS_ROOT.iterdir()):
            if skill_dir.is_dir() and skill_dir.name in DRAFTING_WORKFLOW_NAMES:
                found.add((skill_dir / "SKILL.md").relative_to(REPO_ROOT).as_posix())
    return found


class DeclaredAssetTests(unittest.TestCase):
    def setUp(self):
        self.declared = parse_declared_assets()

    def test_declared_assets_are_exactly_the_seven_packaged_workflows(self):
        self.assertEqual(set(self.declared), EXPECTED_DECLARED_PATHS)

    def test_every_declared_asset_exists_in_the_tracked_tree(self):
        missing = [path for path in self.declared if not (REPO_ROOT / path).is_file()]
        self.assertEqual(
            missing,
            [],
            f"declared in docs/drafting-workflow-contract.md §2 but absent: {missing}",
        )

    def test_no_undeclared_drafting_or_issue_review_asset_exists(self):
        undeclared = sorted(discovered_drafting_assets() - set(self.declared))
        self.assertEqual(
            undeclared,
            [],
            "drafting/issue-review assets exist under a plugin without a §2 row "
            f"in docs/drafting-workflow-contract.md: {undeclared}",
        )

    def test_declared_brand_and_invocation_match_the_assets_own_plugin_and_name(self):
        for path, row in sorted(self.declared.items()):
            expected_prefix = "claude-plugin/" if row["brand"] == "claude" else "codex-plugin/"
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
            self.assertIn(workflow_name, DRAFTING_WORKFLOW_NAMES, path)
            stem = Path(path).parent.name if path.endswith("/SKILL.md") else Path(path).stem
            self.assertEqual(
                stem,
                workflow_name,
                f"{path} does not implement its declared invocation {row['invocation']!r}",
            )

    def test_draft_issues_is_declared_for_claude_only(self):
        draft_issues_rows = [
            row for row in self.declared.values() if row["invocation"].endswith("draft-issues")
        ]
        self.assertEqual(len(draft_issues_rows), 1)
        self.assertEqual(draft_issues_rows[0]["brand"], "claude")
        self.assertFalse(
            (CODEX_SKILLS_ROOT / "draft-issues").exists(),
            "draft-issues is a Claude-only breadth workflow; the Codex plugin must not package it",
        )

    def test_epic_is_packaged_in_neither_plugin(self):
        self.assertFalse(
            (CLAUDE_COMMANDS_ROOT / "epic.md").exists(),
            "/epic plans a user-supplied arc rather than hunting candidates; it is not packaged",
        )
        self.assertFalse(
            (CODEX_SKILLS_ROOT / "epic").exists(),
            "$epic plans a user-supplied arc rather than hunting candidates; it is not packaged",
        )


class OriginMarkerTests(unittest.TestCase):
    """The origin markers are the one drafting behavior with a repo-side
    parser: tools/approve_issues.py's ORIGIN_RE consumes them to route an
    issue to the opposite agent, and src/Kanban/Review.hs tells reviewers to
    find them. They are asserted as raw, unescaped literals so an
    HTML-entity-escaped transcription fails CI."""

    def test_approve_issues_still_parses_the_asserted_literals(self):
        origin_re_source = (REPO_ROOT / "tools" / "approve_issues.py").read_text(encoding="utf-8")
        match = re.search(r"^ORIGIN_RE = re\.compile\((.*)\)$", origin_re_source, re.MULTILINE)
        self.assertIsNotNone(match, "tools/approve_issues.py no longer defines ORIGIN_RE")
        origin_re = re.compile(r"<!--\s*issue-origin:(claude|codex)\s*-->", re.IGNORECASE)
        self.assertIsNotNone(origin_re.search(CLAUDE_ORIGIN_MARKER))
        self.assertIsNotNone(origin_re.search(CODEX_ORIGIN_MARKER))

    def test_the_document_states_both_exact_marker_literals(self):
        text = contract_text()
        for marker in (CLAUDE_ORIGIN_MARKER, CODEX_ORIGIN_MARKER):
            self.assertIn(
                marker,
                text,
                f"docs/drafting-workflow-contract.md must state the exact literal {marker}",
            )

    def test_every_issue_creating_asset_carries_its_brands_marker(self):
        for path, brand in sorted(ISSUE_CREATING_ASSETS.items()):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertIn(
                ORIGIN_MARKER_BY_BRAND[brand],
                text,
                f"{path} must instruct emitting the exact literal {ORIGIN_MARKER_BY_BRAND[brand]}",
            )

    def test_no_asset_carries_the_opposite_brands_marker(self):
        other = {"claude": CODEX_ORIGIN_MARKER, "codex": CLAUDE_ORIGIN_MARKER}
        for path, brand in sorted(ISSUE_CREATING_ASSETS.items()):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertNotIn(
                other[brand],
                text,
                f"{path} is a {brand} asset but references the opposite brand's origin marker",
            )


class DocumentedBoundaryTests(unittest.TestCase):
    """§3.2's Claude-only /draft-issues boundary and §3.5's non-hunting,
    unpackaged /epic boundary are load-bearing: they are the reason the Codex
    plugin's declared set is smaller than the Claude plugin's, and the reason
    /epic is absent from both. Asserted against whitespace-normalized,
    emphasis-stripped text so reflowing a paragraph does not fail CI."""

    def setUp(self):
        self.text = normalized(contract_text())

    def test_document_states_the_claude_only_draft_issues_boundary(self):
        self.assertIn("packaged for the Claude brand only", self.text)
        self.assertIn("there is deliberately no $draft-issues Codex skill", self.text)

    def test_document_states_the_non_hunting_unpackaged_epic_boundary(self):
        self.assertIn("/epic plans a user-specified feature arc", self.text)
        self.assertIn("It is not a discretionary candidate-hunting workflow", self.text)
        self.assertIn("not packaged in either plugin", self.text)

    def test_document_distinguishes_one_candidate_drafting_from_breadth(self):
        self.assertIn("exactly one issue per run", self.text)
        self.assertIn("breadth counterpart", self.text)

    def test_document_states_the_autoissue_sequence_and_no_second_confirmation(self):
        self.assertIn("draft -> signoff -> create -> canonical review", self.text.replace("→", "->"))
        self.assertIn("not ask for a second confirmation", self.text)
        self.assertIn("Stops without review", self.text)

    def test_document_states_the_issue_review_readiness_gate_role(self):
        self.assertIn("direct canonical readiness-gate workflows", self.text)

    def test_document_states_the_haskell_parity_exclusion(self):
        self.assertIn("user- or daemon-invoked, never spawned by Kanban's own CLI", self.text)


class AutoissueSequenceTests(unittest.TestCase):
    """Both packaged autoissue assets must preserve the delegate-draft,
    stop-before-review, create-after-signoff, review-immediately sequence the
    pinned sources define — not just the document describing it."""

    def setUp(self):
        self.sources = {
            path: normalized((REPO_ROOT / path).read_text(encoding="utf-8"))
            for path in AUTOISSUE_ASSETS
        }

    def test_autoissue_delegates_drafting_to_its_own_brands_issue_workflow(self):
        for path, sigil in sorted(AUTOISSUE_ASSETS.items()):
            text = self.sources[path]
            self.assertIn(f"Run {sigil}issue for exactly one candidate", text, path)

    def test_autoissue_stops_without_review_when_drafting_stops_before_creation(self):
        for path, sigil in sorted(AUTOISSUE_ASSETS.items()):
            text = self.sources[path]
            self.assertIn("otherwise stops before creation, stop this workflow too", text, path)
            self.assertIn("Do not run a review.", text, path)

    def test_autoissue_creates_then_immediately_reviews_without_a_second_confirmation(self):
        for path, sigil in sorted(AUTOISSUE_ASSETS.items()):
            text = self.sources[path]
            self.assertIn(f"Immediately run {sigil}issue-review", text, path)
            self.assertIn("do not ask for a second confirmation", text, path)
            self.assertIn("explicit approval of the issue draft authorizes its creation", text, path)

    def test_autoissue_preserves_its_delegates_origin_marker(self):
        for path, brand in (
            ("claude-plugin/plugins/kanban/commands/autoissue.md", "claude"),
            ("codex-plugin/plugins/kanban/skills/autoissue/SKILL.md", "codex"),
        ):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertIn(ORIGIN_MARKER_BY_BRAND[brand], text, path)


class PortableBackendTests(unittest.TestCase):
    """Requirement 6 of issue #118: the packaged issue-review workflows,
    including autoissue's immediate review handoff, must resolve the
    Kanban-managed install path rather than the pre-migration personal
    launcher."""

    def test_issue_review_assets_resolve_the_kanban_managed_install_path(self):
        for path in ISSUE_REVIEW_BACKEND_ASSETS:
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertIn(BACKEND_ENV_OVERRIDE, text, path)
            self.assertIn(BACKEND_DEFAULT_PATH, text, path)
            self.assertIn("approve_issues.py", text, path)
            self.assertIn("python3 tools/install_issue_review.py", text, path)

    def test_autoissue_assets_defer_to_the_documented_backend_contract(self):
        for path in AUTOISSUE_ASSETS:
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            self.assertIn(BACKEND_ENV_OVERRIDE, text, path)
            self.assertIn("approve_issues.py", text, path)

    def test_no_declared_asset_references_the_compatibility_launcher(self):
        offenders = []
        for path in sorted(EXPECTED_DECLARED_PATHS):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            for fragment in FORBIDDEN_BACKEND_PATHS:
                if fragment in text:
                    offenders.append(f"{path}: references {fragment!r}")
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_no_declared_asset_pins_a_reviewer_model_or_effort(self):
        # The pinned sources set APPROVE_ISSUES_CLAUDE_MODEL /
        # APPROVE_ISSUES_CLAUDE_DISPLAY_NAME to scope the reviewer model for
        # the owner's own machine. Requirement 5 of issue #118 drops that
        # personal configuration when vendoring: reviewer selection belongs
        # to tools/approve_issues.py, whose PRIMARY_CLAUDE_MODEL default
        # already selects the same reviewer.
        offenders = []
        for path in sorted(EXPECTED_DECLARED_PATHS):
            text = (REPO_ROOT / path).read_text(encoding="utf-8")
            for fragment in ("APPROVE_ISSUES_CLAUDE_MODEL", "APPROVE_ISSUES_CLAUDE_DISPLAY_NAME"):
                if fragment in text:
                    offenders.append(f"{path}: pins reviewer configuration via {fragment}")
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_approve_issues_default_reviewer_makes_the_dropped_pin_a_no_op(self):
        # Pins the claim above: dropping the personal env vars preserves
        # behavior only because the backend's own default is the same model.
        source = (REPO_ROOT / "tools" / "approve_issues.py").read_text(encoding="utf-8")
        self.assertIn('PRIMARY_CLAUDE_MODEL = "claude-fable-5"', source)
        self.assertIn('os.environ.get("APPROVE_ISSUES_CLAUDE_MODEL", PRIMARY_CLAUDE_MODEL)', source)


if __name__ == "__main__":
    unittest.main()
