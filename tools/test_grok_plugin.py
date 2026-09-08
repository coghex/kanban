"""Structural coverage for the tracked Grok plugin.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

The Grok bundle is not a Kanban-spawned provider. It packages /solve and
/autosolve so a Grok session can open a grok-origin pull request and obtain a
Codex review without invoking Claude. These tests pin that origin, that
reviewer, the vendored helpers, and the self-review prohibition.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
GROK_PLUGIN = REPO_ROOT / "grok-plugin" / "plugins" / "kanban"
CLAUDE_PLUGIN = REPO_ROOT / "claude-plugin" / "plugins" / "kanban"
SOLVE = GROK_PLUGIN / "skills" / "solve" / "SKILL.md"
AUTOSOLVE = GROK_PLUGIN / "skills" / "autosolve" / "SKILL.md"
TRUSTED_SPEC = GROK_PLUGIN / "skills" / "solve" / "scripts" / "trusted_issue_spec.py"
COORDINATOR = GROK_PLUGIN / "scripts" / "review_pr.py"
MODELS = GROK_PLUGIN / "scripts" / "kanban_models.py"
PLUGIN_JSON = GROK_PLUGIN / "plugin.json"
MARKETPLACE = REPO_ROOT / "grok-plugin" / ".grok-plugin" / "marketplace.json"

GROK_ORIGIN = "<!-- pr-origin:grok -->"
CLAUDE_ORIGIN = "<!-- pr-origin:claude -->"
CODEX_ORIGIN = "<!-- pr-origin:codex -->"

COORDINATOR_LOOKUP = (
    'find "${GROK_HOME:-$HOME/.grok}" -path \'*/kanban/scripts/review_pr.py\' '
    "2>/dev/null | head -n1"
)

BASH_FENCE_RE = re.compile(r"```bash\n(?P<body>.*?)\n[ \t]*```", re.DOTALL)


class PluginLayoutTests(unittest.TestCase):
    def test_the_marketplace_lists_the_kanban_plugin(self):
        document = json.loads(MARKETPLACE.read_text(encoding="utf-8"))
        names = [plugin["name"] for plugin in document["plugins"]]
        self.assertEqual(names, ["kanban"])
        self.assertEqual(document["plugins"][0]["source"], "./plugins/kanban")

    def test_the_plugin_manifest_declares_version_1_0_0(self):
        document = json.loads(PLUGIN_JSON.read_text(encoding="utf-8"))
        self.assertEqual(document["name"], "kanban")
        self.assertEqual(document["version"], "1.0.0")

    def test_solve_and_autosolve_skills_exist(self):
        self.assertTrue(SOLVE.is_file())
        self.assertTrue(AUTOSOLVE.is_file())
        for path, name in ((SOLVE, "solve"), (AUTOSOLVE, "autosolve")):
            text = path.read_text(encoding="utf-8")
            self.assertIn(f"name: {name}", text)
            self.assertIn("description:", text)


class VendoredHelperTests(unittest.TestCase):
    def test_trusted_issue_spec_matches_the_claude_copy(self):
        self.assertEqual(
            TRUSTED_SPEC.read_bytes(),
            (CLAUDE_PLUGIN / "scripts" / "trusted_issue_spec.py").read_bytes(),
        )

    def test_review_pr_matches_the_claude_copy(self):
        self.assertEqual(
            COORDINATOR.read_bytes(),
            (CLAUDE_PLUGIN / "scripts" / "review_pr.py").read_bytes(),
        )

    def test_kanban_models_matches_the_claude_copy(self):
        self.assertEqual(
            MODELS.read_bytes(),
            (CLAUDE_PLUGIN / "scripts" / "kanban_models.py").read_bytes(),
        )


class SolveOriginTests(unittest.TestCase):
    def test_solve_stamps_grok_origin_and_not_the_other_brands(self):
        text = SOLVE.read_text(encoding="utf-8")
        self.assertIn(GROK_ORIGIN, text)
        self.assertNotIn(CLAUDE_ORIGIN, text)
        self.assertNotIn(CODEX_ORIGIN, text)
        self.assertIn("Never stamp a Claude or Codex origin marker from this session", text)

    def test_solve_forbids_reviewing_the_pull_request(self):
        text = SOLVE.read_text(encoding="utf-8")
        self.assertIn("Do not review, label, merge, or finalize the PR", text)
        self.assertIn("never Claude", text)


class AutosolveReviewerTests(unittest.TestCase):
    def test_autosolve_requires_grok_origin_and_codex_route(self):
        text = AUTOSOLVE.read_text(encoding="utf-8")
        self.assertIn(GROK_ORIGIN, text)
        self.assertIn('"origin": "grok"', text)
        self.assertIn('"route": "codex"', text)
        self.assertIn("reviewers=codex", text)
        self.assertNotIn(CLAUDE_ORIGIN, text)
        self.assertNotIn(CODEX_ORIGIN, text)

    def test_autosolve_never_invokes_claude(self):
        text = AUTOSOLVE.read_text(encoding="utf-8")
        self.assertIn("spawn, invoke, or impersonate Claude", text)
        self.assertIn("Do not invoke Claude", text)
        self.assertIn("continuing would invoke Claude", text)
        self.assertNotIn("obtain a fresh **Claude** review", text)
        self.assertIn(
            "A marker\nreading `reviewers=claude` is also a publication failure",
            text,
        )

    def test_autosolve_omits_self_review_from_every_executable_fence(self):
        text = AUTOSOLVE.read_text(encoding="utf-8")
        self.assertIn("Never pass `--self-review`", text)
        for fence in BASH_FENCE_RE.finditer(text):
            body = fence.group("body")
            self.assertNotIn("--self-review", body, body)

    def test_autosolve_locates_this_bundle_coordinator(self):
        text = AUTOSOLVE.read_text(encoding="utf-8")
        self.assertIn(COORDINATOR_LOOKUP, text)
        self.assertIn('python3 "$COORDINATOR"', text)
        self.assertNotIn("${CLAUDE_PLUGIN_ROOT}", text)
        self.assertNotIn("$CODEX_HOME", text)
        self.assertIn("Never fall back to a\nClaude or Codex plugin path", text)
