"""Structural and contract coverage for the tracked Codex plugin.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Guards the packaging promise of issue #76: a clean Codex installation can
add codex-plugin/ as a project-scoped marketplace and discover exactly the
four workflows Kanban invokes by name ($solve, $pr-review, $pr-rereview,
$pr-revise), none of which may set its own model/effort/sandbox/approval/
working-directory configuration, depend on an untracked personal path, or
drift from the invocation strings src/Kanban/Solve.hs and
src/Kanban/PullRequestFlow.hs actually spawn.
"""

from __future__ import annotations

import json
import py_compile
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
CODEX_PLUGIN_ROOT = REPO_ROOT / "codex-plugin"
MARKETPLACE_MANIFEST = CODEX_PLUGIN_ROOT / ".agents" / "plugins" / "marketplace.json"
PLUGIN_ROOT = CODEX_PLUGIN_ROOT / "plugins" / "kanban"
PLUGIN_MANIFEST = PLUGIN_ROOT / ".codex-plugin" / "plugin.json"
SKILLS_ROOT = PLUGIN_ROOT / "skills"
REVIEW_COORDINATOR = SKILLS_ROOT / "pr-review" / "scripts" / "review_pr.py"

SOLVE_HS = REPO_ROOT / "src" / "Kanban" / "Solve.hs"
PR_FLOW_HS = REPO_ROOT / "src" / "Kanban" / "PullRequestFlow.hs"
UI_HS = REPO_ROOT / "src" / "Kanban" / "UI.hs"
REVIEW_HS = REPO_ROOT / "src" / "Kanban" / "Review.hs"

EXPECTED_SKILL_NAMES = {"solve", "pr-review", "pr-rereview", "pr-revise"}

# Keys that would let a packaged manifest silently override the model,
# reasoning effort, sandbox/approval policy, or working directory Kanban's
# own CLI spawn already pins (docs/agent-workflow-contract.md §2.1-§2.2).
FORBIDDEN_MANIFEST_KEYS = {
    "model",
    "models",
    "reasoning_effort",
    "reasoningEffort",
    "sandbox",
    "approval",
    "approvalPolicy",
    "approval_policy",
    "cwd",
    "workingDirectory",
    "working_directory",
}

# Personal, non-namespaced path fragments that must never appear in a
# tracked packaged asset. Kanban's own home-relative convention (e.g.
# `Library/Application Support/kanban/...`) is namespaced and allowed; see
# docs/agent-workflow-contract.md §5.
FORBIDDEN_PATH_FRAGMENTS = (
    "/Users/",
    "$HOME/work/",
    "~/work/approve-issues",
    "/.codex/skills/",
)

SKILL_FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
FRONTMATTER_FIELD_RE = re.compile(r"^name:\s*(\S+)\s*$", re.MULTILINE)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def iter_tracked_plugin_files():
    for path in CODEX_PLUGIN_ROOT.rglob("*"):
        if path.is_file():
            yield path


def find_forbidden_keys(value: Any, path: str = "") -> list[str]:
    hits: list[str] = []
    if isinstance(value, dict):
        for key, nested in value.items():
            if key in FORBIDDEN_MANIFEST_KEYS:
                hits.append(f"{path}/{key}" if path else key)
            hits.extend(find_forbidden_keys(nested, f"{path}/{key}"))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            hits.extend(find_forbidden_keys(item, f"{path}[{index}]"))
    return hits


class MarketplaceAndPluginManifestTests(unittest.TestCase):
    def test_marketplace_manifest_points_at_the_tracked_plugin_directory(self):
        data = load_json(MARKETPLACE_MANIFEST)
        plugins = data.get("plugins")
        self.assertIsInstance(plugins, list)
        kanban_entries = [item for item in plugins if item.get("name") == "kanban"]
        self.assertEqual(len(kanban_entries), 1, "marketplace.json must declare exactly one kanban plugin entry")
        source = kanban_entries[0]["source"]
        self.assertEqual(source["source"], "local")
        marketplace_root = MARKETPLACE_MANIFEST.parent.parent.parent
        self.assertEqual(marketplace_root, CODEX_PLUGIN_ROOT)
        resolved = (marketplace_root / source["path"]).resolve()
        self.assertEqual(resolved, PLUGIN_ROOT)

    def test_plugin_manifest_is_valid_and_declares_no_forbidden_configuration(self):
        data = load_json(PLUGIN_MANIFEST)
        self.assertEqual(data.get("name"), "kanban")
        self.assertEqual(data.get("skills"), "./skills/")
        self.assertNotIn("mcpServers", data, "the packaged plugin must not declare an MCP server dependency")
        hits = find_forbidden_keys(data)
        self.assertEqual(hits, [], f"plugin.json must not set model/effort/sandbox/approval/cwd config: {hits}")

    def test_marketplace_manifest_declares_no_forbidden_configuration(self):
        data = load_json(MARKETPLACE_MANIFEST)
        hits = find_forbidden_keys(data)
        self.assertEqual(hits, [], f"marketplace.json must not set model/effort/sandbox/approval/cwd config: {hits}")


class SkillDiscoveryTests(unittest.TestCase):
    def test_skills_directory_contains_exactly_the_four_packaged_workflows(self):
        found = {path.name for path in SKILLS_ROOT.iterdir() if path.is_dir()}
        self.assertEqual(found, EXPECTED_SKILL_NAMES)

    def test_each_skill_has_a_skill_md_whose_frontmatter_name_matches_its_directory(self):
        for name in EXPECTED_SKILL_NAMES:
            skill_md = SKILLS_ROOT / name / "SKILL.md"
            self.assertTrue(skill_md.is_file(), f"missing {skill_md}")
            text = skill_md.read_text(encoding="utf-8")
            match = SKILL_FRONTMATTER_RE.match(text)
            self.assertIsNotNone(match, f"{skill_md} must open with a --- frontmatter block")
            field = FRONTMATTER_FIELD_RE.search(match.group(1))
            self.assertIsNotNone(field, f"{skill_md} frontmatter must declare name:")
            self.assertEqual(field.group(1), name)


class WorkflowNameParityTests(unittest.TestCase):
    """Pins the packaged skill names to the exact tokens Kanban's Haskell
    invocation code spawns, so a rename on either side fails this test
    instead of failing silently at runtime."""

    def test_codex_workflow_tokens_match_packaged_skill_names(self):
        solve_source = SOLVE_HS.read_text(encoding="utf-8")
        solve_tokens = set(re.findall(r'workflowName \w+ CodexSolver = "\$([\w-]+)"', solve_source))
        self.assertEqual(solve_tokens, {"solve"}, "src/Kanban/Solve.hs workflowName Codex tokens changed")

        pr_flow_source = PR_FLOW_HS.read_text(encoding="utf-8")
        pr_flow_tokens = set(re.findall(r'commandName "([\w-]+)"', pr_flow_source))
        self.assertEqual(
            pr_flow_tokens,
            {"pr-review", "pr-rereview", "pr-revise"},
            "src/Kanban/PullRequestFlow.hs commandName tokens changed",
        )

        ui_source = UI_HS.read_text(encoding="utf-8")
        ui_tokens = set(re.findall(r'commandName "([\w-]+)"', ui_source))
        self.assertLessEqual(ui_tokens, pr_flow_tokens, "src/Kanban/UI.hs invokes a command PullRequestFlow.hs does not")

        all_tokens = solve_tokens | pr_flow_tokens
        self.assertEqual(all_tokens, EXPECTED_SKILL_NAMES)


class NoPersonalPathTests(unittest.TestCase):
    def test_no_packaged_asset_references_a_personal_or_untracked_path(self):
        offenders = []
        for path in iter_tracked_plugin_files():
            if path.suffix in {".pyc"} or "__pycache__" in path.parts:
                offenders.append(f"{path}: compiled/cache artifact must not be tracked")
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for fragment in FORBIDDEN_PATH_FRAGMENTS:
                if fragment in text:
                    offenders.append(f"{path}: contains forbidden path fragment {fragment!r}")
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_no_agents_yaml_or_other_untracked_personal_skill_convention(self):
        stray = list(SKILLS_ROOT.rglob("agents"))
        self.assertEqual(stray, [], f"packaged skills must not carry personal agents/*.yaml interface files: {stray}")


class IssueReviewBackendResolutionTests(unittest.TestCase):
    """The coordinator's approver_path() must resolve the canonical
    issue-review backend the same way Kanban.Review.canonicalIssueReviewerPath
    does, never a personal ~/work/approve-issues.py default."""

    def test_review_pr_matches_the_haskell_canonical_resolution(self):
        review_hs_source = REVIEW_HS.read_text(encoding="utf-8")
        self.assertIn('lookupEnv "KANBAN_ISSUE_REVIEW_INSTALL_DIR"', review_hs_source)
        self.assertIn("Library/Application Support/kanban/issue-review/approve_issues.py", review_hs_source)

        coordinator_source = REVIEW_COORDINATOR.read_text(encoding="utf-8")
        self.assertIn('os.environ.get("KANBAN_ISSUE_REVIEW_INSTALL_DIR")', coordinator_source)
        for segment in ('"Library"', '"Application Support"', '"kanban"', '"issue-review"'):
            self.assertIn(segment, coordinator_source, f"approver_path() must build the canonical {segment} segment")
        self.assertIn("approve_issues.py", coordinator_source)
        self.assertNotIn('"work" / "approve-issues.py"', coordinator_source)
        self.assertIn("python3 tools/install_issue_review.py", coordinator_source)

    def test_solve_gate_check_matches_the_haskell_canonical_resolution(self):
        # solve can run against any repository Kanban is pointed at, so its
        # gate check must resolve the Kanban-managed install location
        # rather than assume the repository under review tracks
        # tools/approve_issues.py itself.
        solve_source = (SKILLS_ROOT / "solve" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn("KANBAN_ISSUE_REVIEW_INSTALL_DIR", solve_source)
        self.assertIn("Library/Application Support/kanban/issue-review/approve_issues.py", solve_source)
        self.assertIn("python3 tools/install_issue_review.py", solve_source)


class SolveGateEscalationTests(unittest.TestCase):
    """solve must escalate with the exact terminal line Kanban's own
    invocation prompt uses (src/Kanban/Solve.hs), not a paraphrase, so
    Kanban's KANBAN_NEEDS_INPUT handling recognizes it."""

    ESCALATION_TEXT = "KANBAN_NEEDS_INPUT: This issue needs canonical review; press r on the issue, then retry."

    def test_escalation_text_matches_solve_hs_verbatim(self):
        solve_hs_source = SOLVE_HS.read_text(encoding="utf-8")
        self.assertIn(self.ESCALATION_TEXT, solve_hs_source)

        solve_skill_source = (SKILLS_ROOT / "solve" / "SKILL.md").read_text(encoding="utf-8")
        self.assertIn(self.ESCALATION_TEXT, solve_skill_source)


class ReviewCoordinatorSelfTestTests(unittest.TestCase):
    def test_review_pr_self_test_passes_standalone(self):
        proc = subprocess.run(
            [sys.executable, "-B", str(REVIEW_COORDINATOR), "--self-test"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("self-test passed", proc.stdout)

    def test_review_pr_compiles(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfile = Path(tmp) / "review_pr.pyc"
            py_compile.compile(str(REVIEW_COORDINATOR), cfile=str(cfile), doraise=True)


COORDINATOR_LOOKUP = (
    'find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" '
    "-path '*/kanban/*/skills/pr-review/scripts/review_pr.py'"
)


class SharedCoordinatorReferenceTests(unittest.TestCase):
    """All three PR-flow skills locate the installed coordinator by
    searching under $CODEX_HOME rather than a path relative to the current
    directory: Kanban spawns these workflows with the *reviewed* repository
    as the working directory, not this plugin's own install location, so a
    cwd- or skill-relative path cannot resolve. Confirm the exact lookup
    command each SKILL.md uses actually finds the coordinator against a
    simulated install layout, not just that some string is present."""

    def test_pr_review_family_locates_the_coordinator_via_codex_home(self):
        for name in ("pr-review", "pr-rereview", "pr-revise"):
            text = (SKILLS_ROOT / name / "SKILL.md").read_text(encoding="utf-8")
            self.assertIn(COORDINATOR_LOOKUP, text, f"{name}/SKILL.md must locate the coordinator under $CODEX_HOME")

    def test_the_codex_home_lookup_command_resolves_against_a_simulated_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_codex_home = Path(tmp) / "fake-codex-home"
            installed = fake_codex_home / "plugins" / "cache" / "kanban" / "kanban" / "1.0.0" / "skills" / "pr-review" / "scripts" / "review_pr.py"
            installed.parent.mkdir(parents=True)
            installed.write_text("# stand-in for the installed coordinator\n", encoding="utf-8")
            proc = subprocess.run(
                [
                    "find",
                    str(fake_codex_home / "plugins" / "cache"),
                    "-path",
                    "*/kanban/*/skills/pr-review/scripts/review_pr.py",
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            found = [line for line in proc.stdout.splitlines() if line]
            self.assertEqual(found, [str(installed)])


if __name__ == "__main__":
    unittest.main()
