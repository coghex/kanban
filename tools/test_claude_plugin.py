"""Structural and contract coverage for the tracked Claude plugin.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Guards the packaging promise of issue #77: a clean Claude Code installation
can add claude-plugin/ as a marketplace and discover exactly the four
workflows Kanban invokes by name (/solve, /pr-review, /pr-rereview,
/pr-revise), none of which may set its own model/effort/permission-mode/
working-directory configuration, depend on an untracked personal path, or
drift from the invocation strings src/Kanban/Solve.hs and
src/Kanban/PullRequestFlow.hs actually spawn. The bundled coordinator is a
tracked copy of the Codex plugin's coordinator (issue #76), tested here
standalone so the Claude bundle's own coverage never requires the Codex
plugin's assets to exist.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
CLAUDE_PLUGIN_ROOT = REPO_ROOT / "claude-plugin"
MARKETPLACE_MANIFEST = CLAUDE_PLUGIN_ROOT / ".claude-plugin" / "marketplace.json"
PLUGIN_ROOT = CLAUDE_PLUGIN_ROOT / "plugins" / "kanban"
PLUGIN_MANIFEST = PLUGIN_ROOT / ".claude-plugin" / "plugin.json"
COMMANDS_ROOT = PLUGIN_ROOT / "commands"
REVIEW_COORDINATOR = PLUGIN_ROOT / "scripts" / "review_pr.py"

SOLVE_HS = REPO_ROOT / "src" / "Kanban" / "Solve.hs"
PR_FLOW_HS = REPO_ROOT / "src" / "Kanban" / "PullRequestFlow.hs"
UI_HS = REPO_ROOT / "src" / "Kanban" / "UI.hs"
REVIEW_HS = REPO_ROOT / "src" / "Kanban" / "Review.hs"

EXPECTED_COMMAND_NAMES = {"solve", "pr-review", "pr-rereview", "pr-revise"}

# Keys that would let a packaged command's frontmatter or manifest silently
# override the model, reasoning effort, permission mode, or working
# directory Kanban's own CLI spawn already pins
# (docs/agent-workflow-contract.md §2.1-§2.2). Claude Code's own command
# frontmatter genuinely supports `model:` (see the personal
# ~/.claude/commands/pr-revise.md this issue replaces, which set
# `model: "claude-sonnet-5"` and `effort: "xhigh"`), so this is a real risk
# to guard, not just defense in depth.
FORBIDDEN_FRONTMATTER_KEYS = {
    "model",
    "effort",
    "reasoning_effort",
    "reasoningEffort",
    "sandbox",
    "approval",
    "approvalPolicy",
    "approval_policy",
    "permission-mode",
    "permissionMode",
    "cwd",
    "workingDirectory",
    "working_directory",
}

FORBIDDEN_MANIFEST_KEYS = FORBIDDEN_FRONTMATTER_KEYS

# Personal, non-namespaced path fragments that must never appear in a
# tracked packaged asset. Kanban's own home-relative convention (e.g.
# `Library/Application Support/kanban/...`) is namespaced and allowed; see
# docs/agent-workflow-contract.md §5.
FORBIDDEN_PATH_FRAGMENTS = (
    "/Users/",
    "$HOME/work/",
    "~/work/approve-issues",
    "/.codex/skills/",
    "/.claude/commands/",
)

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
FRONTMATTER_KEY_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*):", re.MULTILINE)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def iter_tracked_plugin_files():
    for path in CLAUDE_PLUGIN_ROOT.rglob("*"):
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


def frontmatter_keys(text: str) -> set[str]:
    match = FRONTMATTER_RE.match(text)
    if match is None:
        return set()
    return {key.lower() for key in FRONTMATTER_KEY_RE.findall(match.group(1))}


class MarketplaceAndPluginManifestTests(unittest.TestCase):
    def test_marketplace_manifest_points_at_the_tracked_plugin_directory(self):
        data = load_json(MARKETPLACE_MANIFEST)
        plugins = data.get("plugins")
        self.assertIsInstance(plugins, list)
        kanban_entries = [item for item in plugins if item.get("name") == "kanban"]
        self.assertEqual(len(kanban_entries), 1, "marketplace.json must declare exactly one kanban plugin entry")
        source = kanban_entries[0]["source"]
        self.assertIsInstance(source, str, "local plugin source must be a plain relative path string")
        marketplace_root = MARKETPLACE_MANIFEST.parent.parent
        self.assertEqual(marketplace_root, CLAUDE_PLUGIN_ROOT)
        resolved = (marketplace_root / source).resolve()
        self.assertEqual(resolved, PLUGIN_ROOT)

    def test_plugin_manifest_is_valid_and_declares_no_forbidden_configuration(self):
        data = load_json(PLUGIN_MANIFEST)
        self.assertEqual(data.get("name"), "kanban")
        self.assertEqual(data.get("commands"), "./commands/")
        self.assertNotIn("mcpServers", data, "the packaged plugin must not declare an MCP server dependency")
        self.assertNotIn("skills", data, "issue #77 packages workflows as commands, not skills")
        hits = find_forbidden_keys(data)
        self.assertEqual(hits, [], f"plugin.json must not set model/effort/sandbox/approval/cwd config: {hits}")

    def test_marketplace_manifest_declares_no_forbidden_configuration(self):
        data = load_json(MARKETPLACE_MANIFEST)
        hits = find_forbidden_keys(data)
        self.assertEqual(hits, [], f"marketplace.json must not set model/effort/sandbox/approval/cwd config: {hits}")


class CommandDiscoveryTests(unittest.TestCase):
    def test_commands_directory_contains_exactly_the_four_packaged_workflows(self):
        found = {path.stem for path in COMMANDS_ROOT.glob("*.md")}
        self.assertEqual(found, EXPECTED_COMMAND_NAMES)

    def test_each_command_declares_a_description_and_no_forbidden_frontmatter(self):
        for name in EXPECTED_COMMAND_NAMES:
            command_md = COMMANDS_ROOT / f"{name}.md"
            self.assertTrue(command_md.is_file(), f"missing {command_md}")
            text = command_md.read_text(encoding="utf-8")
            match = FRONTMATTER_RE.match(text)
            self.assertIsNotNone(match, f"{command_md} must open with a --- frontmatter block")
            keys = frontmatter_keys(text)
            self.assertIn("description", keys, f"{command_md} frontmatter must declare description:")
            forbidden_lower = {key.lower() for key in FORBIDDEN_FRONTMATTER_KEYS}
            hits = keys & forbidden_lower
            self.assertEqual(hits, set(), f"{command_md} frontmatter must not set: {hits}")


class WorkflowNameParityTests(unittest.TestCase):
    """Pins the packaged command names to the exact `/`-prefixed tokens
    Kanban's Haskell invocation code spawns for the Claude brand, so a
    rename on either side fails this test instead of failing silently at
    runtime."""

    def test_claude_workflow_tokens_match_packaged_command_names(self):
        solve_source = SOLVE_HS.read_text(encoding="utf-8")
        solve_tokens = set(re.findall(r'workflowName \w+ ClaudeSolver = "/([\w-]+)"', solve_source))
        self.assertEqual(solve_tokens, {"solve"}, "src/Kanban/Solve.hs workflowName Claude tokens changed")

        pr_flow_source = PR_FLOW_HS.read_text(encoding="utf-8")
        self.assertIn(
            'commandName name = if brand == CodexSolver then "$" <> name else "/" <> name',
            pr_flow_source,
            "src/Kanban/PullRequestFlow.hs commandName no longer prefixes the Claude brand with /",
        )
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
        self.assertEqual(all_tokens, EXPECTED_COMMAND_NAMES)


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
        solve_source = (COMMANDS_ROOT / "solve.md").read_text(encoding="utf-8")
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

        solve_command_source = (COMMANDS_ROOT / "solve.md").read_text(encoding="utf-8")
        self.assertIn(self.ESCALATION_TEXT, solve_command_source)


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


class ClaudePluginRootReferenceTests(unittest.TestCase):
    """All three PR-flow commands locate the bundled coordinator via
    ${CLAUDE_PLUGIN_ROOT}, the portable path Claude Code substitutes to this
    plugin's own install location regardless of the invoking working
    directory (Kanban spawns these commands with the *reviewed* repository
    as the working directory, not this plugin's own install location)."""

    def test_pr_review_family_locates_the_coordinator_via_claude_plugin_root(self):
        for name in ("pr-review", "pr-rereview", "pr-revise"):
            text = (COMMANDS_ROOT / f"{name}.md").read_text(encoding="utf-8")
            self.assertIn(
                '"${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py"',
                text,
                f"{name}.md must locate the coordinator via ${{CLAUDE_PLUGIN_ROOT}}",
            )

    def test_the_referenced_coordinator_path_exists_relative_to_the_plugin_root(self):
        # ${CLAUDE_PLUGIN_ROOT} resolves to PLUGIN_ROOT at runtime; confirm
        # the literal relative path every command references actually
        # exists there, so a rename of scripts/review_pr.py would fail
        # this test rather than only failing at runtime.
        resolved = PLUGIN_ROOT / "scripts" / "review_pr.py"
        self.assertEqual(resolved, REVIEW_COORDINATOR)
        self.assertTrue(resolved.is_file())


if __name__ == "__main__":
    unittest.main()
