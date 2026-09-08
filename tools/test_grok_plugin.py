"""Structural coverage for the tracked Grok plugin.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

The Grok bundle is not a Kanban-spawned provider. It packages /solve and
/autosolve so a Grok session can open a grok-origin pull request and obtain a
Codex review without invoking Claude. These tests pin that origin, that
reviewer, the vendored helpers, and the self-review prohibition.
"""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import plugin_bundle_gate

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
PLUGIN_MANIFEST_PATH = "grok-plugin/plugins/kanban/plugin.json"
MARKETPLACE_MANIFEST_PATH = "grok-plugin/.grok-plugin/marketplace.json"
SKILLS_PREFIX = "grok-plugin/plugins/kanban/skills"
COMMAND_SIGIL = "/"
EXPECTED_SKILL_NAMES = {"solve", "autosolve"}

GROK_ORIGIN = "<!-- pr-origin:grok -->"
CLAUDE_ORIGIN = "<!-- pr-origin:claude -->"
CODEX_ORIGIN = "<!-- pr-origin:codex -->"

COORDINATOR_LOOKUP = 'Path("scripts") / "review_pr.py"'

# The exact Python locator /autosolve's coordinator fence runs. Asserted to
# appear in the skill AND executed against a simulated install below, so a
# rewrite that keeps the prose and breaks the resolution fails here.
GROK_COORDINATOR_PYTHON = '''import sys
from pathlib import Path

plugin_root, grok_home = sys.argv[1], sys.argv[2]
relative = Path("scripts") / "review_pr.py"
if plugin_root:
    candidate = Path(plugin_root) / relative
    if not candidate.is_file():
        raise SystemExit(f"coordinator was not found at {candidate}")
    print(candidate)
    raise SystemExit(0)
matches = sorted((Path(grok_home) / "installed-plugins").glob("kanban-*/" + relative.as_posix()))
if not matches:
    raise SystemExit("coordinator was not found under $GROK_HOME/installed-plugins/kanban-*")
if len(matches) != 1:
    raise SystemExit("ambiguous Kanban installs: " + ", ".join(str(path) for path in matches))
print(matches[0])
'''

BASH_FENCE_RE = re.compile(r"```bash\n(?P<body>.*?)\n[ \t]*```", re.DOTALL)


class PluginLayoutTests(unittest.TestCase):
    def test_the_marketplace_lists_the_kanban_plugin(self):
        document = json.loads(MARKETPLACE.read_text(encoding="utf-8"))
        names = [plugin["name"] for plugin in document["plugins"]]
        self.assertEqual(names, ["kanban"])
        self.assertEqual(document["plugins"][0]["source"], "./plugins/kanban")

    def test_the_plugin_manifest_declares_version_1_0_5(self):
        document = json.loads(PLUGIN_JSON.read_text(encoding="utf-8"))
        self.assertEqual(document["name"], "kanban")
        self.assertEqual(document["version"], "1.0.5")

    def test_solve_and_autosolve_skills_exist(self):
        self.assertTrue(SOLVE.is_file())
        self.assertTrue(AUTOSOLVE.is_file())
        for path, name in ((SOLVE, "solve"), (AUTOSOLVE, "autosolve")):
            text = path.read_text(encoding="utf-8")
            self.assertIn(f"name: {name}", text)
            self.assertIn("description:", text)


class ManifestListingParityTests(unittest.TestCase):
    """Manifest descriptions enumerate the workflows this bundle ships.

    The shipped set is derived from tracked SKILL.md files rather than
    restated as a constant, so adding a skill with only a version bump
    fails unless every enumerating description names it.
    """

    def shipped(self) -> set[str]:
        return plugin_bundle_gate.tracked_skill_names(REPO_ROOT, SKILLS_PREFIX)

    def enumerating_surfaces(self) -> dict[str, str]:
        marketplace = json.loads(MARKETPLACE.read_text(encoding="utf-8"))
        return {
            f"{PLUGIN_MANIFEST_PATH} description": json.loads(
                PLUGIN_JSON.read_text(encoding="utf-8")
            )["description"],
            f"{MARKETPLACE_MANIFEST_PATH} description": marketplace["description"],
            f"{MARKETPLACE_MANIFEST_PATH} plugin-entry description": marketplace[
                "plugins"
            ][0]["description"],
        }

    def test_the_tracked_skill_files_are_the_pinned_discovery_set(self):
        self.assertEqual(self.shipped(), EXPECTED_SKILL_NAMES)

    def test_every_enumerating_description_names_exactly_the_shipped_skills(self):
        shipped = self.shipped()
        failures = []
        for surface, text in self.enumerating_surfaces().items():
            failures.extend(
                plugin_bundle_gate.parity_failures(
                    surface,
                    plugin_bundle_gate.workflow_identifiers(text, COMMAND_SIGIL),
                    shipped,
                )
            )
        self.assertEqual(failures, [], "\n".join(failures))

    def test_the_parity_check_detects_a_planted_omission_and_a_planted_extra(self):
        shipped = self.shipped()
        for surface, text in self.enumerating_surfaces().items():
            with self.subTest(surface=surface):
                omitted = text.replace("/autosolve", "")
                self.assertNotEqual(omitted, text, "the planted omission changed nothing")
                failures = plugin_bundle_gate.parity_failures(
                    surface,
                    plugin_bundle_gate.workflow_identifiers(omitted, COMMAND_SIGIL),
                    shipped,
                )
                self.assertEqual(len(failures), 1, failures)
                self.assertIn("omits shipped workflow(s): autosolve", failures[0])

                spurious = f"{text} It also ships /retired-skill."
                failures = plugin_bundle_gate.parity_failures(
                    surface,
                    plugin_bundle_gate.workflow_identifiers(spurious, COMMAND_SIGIL),
                    shipped,
                )
                self.assertEqual(len(failures), 1, failures)
                self.assertIn(
                    "names workflow(s) the bundle does not ship: retired-skill",
                    failures[0],
                )


class VendoredHelperTests(unittest.TestCase):
    def test_trusted_issue_spec_matches_the_claude_copy(self):
        self.assertEqual(
            TRUSTED_SPEC.read_bytes(),
            (CLAUDE_PLUGIN / "scripts" / "trusted_issue_spec.py").read_bytes(),
        )

    def test_review_pr_carries_expected_route_binding(self):
        text = COORDINATOR.read_text(encoding="utf-8")
        self.assertIn("--expected-origin", text)
        self.assertIn("--expected-route", text)
        self.assertIn("route_mismatch", text)

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
        self.assertIn("$ARGUMENTS", text)

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
        self.assertIn("ISSUE=\"$ARGUMENTS\"", text)
        self.assertIn("--expected-origin grok", text)
        self.assertIn("--expected-route codex", text)
        self.assertNotIn(CLAUDE_ORIGIN, text)
        self.assertNotIn(CODEX_ORIGIN, text)
        self.assertIn("does not package /push-docs", text)
        self.assertNotIn("land it\n  with /push-docs", text)
        self.assertIn("Do\n  not reclaim the issue", text)

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
        self.assertIn("installed-plugins/kanban-<hash>", text)
        self.assertIn("$GROK_PLUGIN_ROOT", text)
        self.assertIn("ambiguous Kanban installs", text)
        self.assertIn('glob("kanban-*/" + relative.as_posix())', text)
        self.assertIn(GROK_COORDINATOR_PYTHON, text)


class AutosolveCoordinatorLookupTests(unittest.TestCase):
    """The autosolve coordinator locator is the same fail-closed Python as
    /solve's helper lookup, with a different relative path. String search
    cannot prove it prefers $GROK_PLUGIN_ROOT, finds one hashed install, or
    refuses two kanban-* matches — these run the fenced locator itself."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.workdir = self.root / "worked-repo"
        self.workdir.mkdir()

    def install_hashed(self, home: Path, name: str = "kanban-b0441dc6") -> Path:
        installed = home / ".grok" / "installed-plugins" / name / "scripts"
        installed.mkdir(parents=True)
        target = installed / "review_pr.py"
        target.write_text("print('coordinator')\n", encoding="utf-8")
        return target

    def install_marketplace_source(self, root: Path) -> Path:
        installed = root / "marketplace" / "plugins" / "kanban" / "scripts"
        installed.mkdir(parents=True)
        target = installed / "review_pr.py"
        target.write_text("print('coordinator')\n", encoding="utf-8")
        return target

    def run_locator(self, plugin_root: str, grok_home: str):
        return subprocess.run(
            ["python3", "-", plugin_root, grok_home],
            input=GROK_COORDINATOR_PYTHON,
            capture_output=True,
            text=True,
            cwd=str(self.workdir),
            timeout=60,
        )

    def test_the_autosolve_skill_declares_the_lookup_it_is_tested_with(self):
        self.assertIn(
            GROK_COORDINATOR_PYTHON,
            AUTOSOLVE.read_text(encoding="utf-8"),
            "the Grok autosolve skill must prefer $GROK_PLUGIN_ROOT, else one hashed install",
        )

    def test_the_lookup_resolves_from_a_hashed_install(self):
        home = self.root / "grok-home"
        expected = self.install_hashed(home)
        proc = self.run_locator("", str(home / ".grok"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_the_lookup_uses_plugin_root_for_a_marketplace_source_outside_home(self):
        home = self.root / "grok-empty-home"
        home.mkdir()
        expected = self.install_marketplace_source(self.root)
        plugin_root = expected.parents[1]  # .../plugins/kanban
        proc = self.run_locator(str(plugin_root), str(home / ".grok"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_plugin_root_wins_over_a_hashed_install(self):
        home = self.root / "grok-both"
        self.install_hashed(home)
        expected = self.install_marketplace_source(self.root)
        plugin_root = expected.parents[1]
        proc = self.run_locator(str(plugin_root), str(home / ".grok"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_the_lookup_fails_closed_when_two_kanban_installs_match(self):
        home = self.root / "grok-ambiguous"
        first = self.install_hashed(home)
        self.install_hashed(home, "kanban-aaaaaaaa")
        proc = self.run_locator("", str(home / ".grok"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("ambiguous Kanban installs", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")
        self.assertTrue(first.is_file())

    def test_the_lookup_ignores_a_competing_plugin_with_the_same_relative_path(self):
        home = self.root / "grok-competitor"
        expected = self.install_hashed(home)
        other = (
            home
            / ".grok"
            / "installed-plugins"
            / "otherplugin-deadbeef"
            / "scripts"
            / "review_pr.py"
        )
        other.parent.mkdir(parents=True)
        other.write_text("print('other')\n", encoding="utf-8")
        proc = self.run_locator("", str(home / ".grok"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_the_lookup_fails_closed_when_no_install_matches(self):
        home = self.root / "grok-empty"
        (home / ".grok" / "installed-plugins").mkdir(parents=True)
        proc = self.run_locator("", str(home / ".grok"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn(
            "coordinator was not found under $GROK_HOME/installed-plugins/kanban-*",
            proc.stderr,
        )
        self.assertEqual(proc.stdout.strip(), "")

    def test_plugin_root_fails_closed_when_the_relative_path_is_missing(self):
        home = self.root / "grok-missing"
        home.mkdir()
        plugin_root = self.root / "marketplace" / "plugins" / "kanban"
        plugin_root.mkdir(parents=True)
        proc = self.run_locator(str(plugin_root), str(home / ".grok"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("coordinator was not found at", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")


def load_grok_review_pr():
    spec = importlib.util.spec_from_file_location(
        "kanban_grok_plugin_review_pr", COORDINATOR
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ExpectedRouteBindingTests(unittest.TestCase):
    """Behavioral coverage for --expected-origin/--expected-route.

    A string search can pass while the flags are parsed and ignored. These
    drive workflow() with a live origin/route that disagrees, and prove
    collect_context, reviewer spawn (including Claude), and publication are
    not reached.
    """

    def setUp(self):
        self.module = load_grok_review_pr()
        self.calls = []
        dual = self.module.kanban_models().DUAL_MODE
        self.operating = mock.patch.object(
            self.module, "operating_mode", return_value=(dual, ("codex", "claude"))
        )
        self.operating.start()
        self.addCleanup(self.operating.stop)
        self.resolve = mock.patch.object(
            self.module, "resolve_repository", return_value="coghex/kanban"
        )
        self.resolve.start()
        self.addCleanup(self.resolve.stop)
        self.gate = mock.patch.object(
            self.module,
            "gate_status",
            return_value={
                "allow_no_issue": True,
                "approved": True,
                "checks": [],
                "invalid_links": [],
                "issues": [],
                "key": "deadbeef",
                "overridden_issues": [],
                "override_issue_gate": False,
                "override_reason": None,
            },
        )
        self.gate.start()
        self.addCleanup(self.gate.stop)
        for name in (
            "collect_context",
            "invoke_codex",
            "invoke_claude",
            "invoke_reviewer",
            "run_reviews",
            "set_verdict_label",
            "post_comment",
        ):
            if hasattr(self.module, name):
                patched = mock.patch.object(
                    self.module, name, side_effect=self._forbidden(name)
                )
                patched.start()
                self.addCleanup(patched.stop)

    def _forbidden(self, name):
        def wrapped(*args, **kwargs):
            self.calls.append(name)
            raise AssertionError(f"{name} must not run on route_mismatch")

        return wrapped

    def pr(self, origin):
        body = "summary\n\n"
        if origin is not None:
            body += f"<!-- pr-origin:{origin} -->\n"
        return {
            "url": "https://github.com/coghex/kanban/pull/7",
            "headRefOid": "a" * 40,
            "body": body,
            "isCrossRepository": False,
            "closingIssuesReferences": [],
            "isDraft": False,
        }

    def run_workflow(self, origin, expected_origin, expected_route):
        with mock.patch.object(self.module, "pr_view", return_value=self.pr(origin)):
            return self.module.workflow(
                Path("/fake-repo"),
                7,
                rereview=False,
                dry_run=False,
                allow_no_issue=True,
                expected_origin=expected_origin,
                expected_route=expected_route,
            )

    def assert_mismatch(self, code, result, origin, route):
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "route_mismatch")
        self.assertEqual(result["origin"], origin)
        self.assertEqual(result["route"], route)
        self.assertEqual(self.calls, [])

    def test_a_drifted_origin_refuses_before_spawning_claude(self):
        code, result = self.run_workflow(
            origin="claude", expected_origin="grok", expected_route="codex"
        )
        self.assert_mismatch(code, result, "claude", "codex")
        self.assertIn("no reviewer was spawned", result["error"])

    def test_an_unknown_origin_refuses_before_the_dual_route_can_spawn_claude(self):
        code, result = self.run_workflow(
            origin=None, expected_origin="grok", expected_route="codex"
        )
        self.assert_mismatch(code, result, "unknown", "codex+claude")
        self.assertIn("no reviewer was spawned", result["error"])

    def test_publication_refuses_if_origin_drifts_after_review(self):
        drifted = self.pr(None)
        gate = {
            "allow_no_issue": True,
            "approved": True,
            "checks": [],
            "invalid_links": [],
            "issues": [],
            "key": "deadbeef",
            "overridden_issues": [],
            "override_issue_gate": False,
            "override_reason": None,
        }
        with mock.patch.object(self.module, "pr_view", return_value=drifted):
            with mock.patch.object(self.module, "gate_status", return_value=gate):
                with mock.patch.object(
                    self.module, "resolve_workflow_labels", return_value=("a", "c")
                ):
                    code, result = self.module.publish_results(
                        Path("/fake-repo"),
                        "coghex/kanban",
                        7,
                        self.pr("grok"),
                        gate,
                        [self.module.CODEX_REVIEWER],
                        [{"verdict": "APPROVE", "summary": "ok", "blocking_concerns": []}],
                        {"pr": 7},
                        allow_no_issue=True,
                        expected_origin="grok",
                        expected_route="codex",
                    )
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "route_mismatch")
        self.assertEqual(result["origin"], "unknown")
        self.assertEqual(self.calls, [])

    def test_publication_refuses_origin_drift_on_a_later_reread(self):
        grok_pr = self.pr("grok")
        drifted = self.pr(None)
        gate = {
            "allow_no_issue": True,
            "approved": True,
            "checks": [],
            "invalid_links": [],
            "issues": [],
            "key": "deadbeef",
            "overridden_issues": [],
            "override_issue_gate": False,
            "override_reason": None,
        }
        with mock.patch.object(
            self.module, "pr_view", side_effect=[grok_pr, drifted]
        ):
            with mock.patch.object(self.module, "gate_status", return_value=gate):
                with mock.patch.object(
                    self.module, "resolve_workflow_labels", return_value=("a", "c")
                ):
                    with self.assertRaises(self.module.WorkflowError) as raised:
                        self.module.publish_results(
                            Path("/fake-repo"),
                            "coghex/kanban",
                            7,
                            grok_pr,
                            gate,
                            [self.module.CODEX_REVIEWER],
                            [
                                {
                                    "display_name": "Codex",
                                    "reviewer": "codex",
                                    "verdict": "APPROVE",
                                    "summary": "ok",
                                    "blocking_concerns": [],
                                }
                            ],
                            {"pr": 7},
                            allow_no_issue=True,
                            expected_origin="grok",
                            expected_route="codex",
                        )
        self.assertIn("does not match --expected-origin", str(raised.exception))
        self.assertEqual(self.calls, [])

    def test_a_matching_grok_codex_binding_is_not_a_mismatch(self):
        with mock.patch.object(self.module, "pr_view", return_value=self.pr("grok")):
            with mock.patch.object(self.module, "collect_context") as collect:
                collect.side_effect = RuntimeError("stop after the binding check")
                with self.assertRaises(RuntimeError):
                    self.module.workflow(
                        Path("/fake-repo"),
                        7,
                        rereview=False,
                        dry_run=False,
                        allow_no_issue=True,
                        expected_origin="grok",
                        expected_route="codex",
                    )
                collect.assert_called()


# The whole tracked Grok tree, not just plugins/kanban/: marketplace.json
# and grok-plugin/README.md live outside that inner prefix and still ship.
BUNDLE_PREFIX = "grok-plugin"
ORIGINAL_BUNDLE_VERSION = "1.0.0"
BUNDLE_README_PATH = "grok-plugin/README.md"


class BundleVersionGateTests(unittest.TestCase):
    def test_the_marketplace_plugin_version_matches_the_manifest(self):
        plugin = json.loads(PLUGIN_JSON.read_text(encoding="utf-8"))
        marketplace = json.loads(MARKETPLACE.read_text(encoding="utf-8"))
        self.assertEqual(marketplace["plugins"][0]["version"], plugin["version"])

    def test_the_tracked_tree_owes_no_version_bump(self):
        failures = plugin_bundle_gate.bundle_version_failures(
            REPO_ROOT, BUNDLE_PREFIX, BUNDLE_PREFIX, PLUGIN_MANIFEST_PATH
        )
        self.assertEqual(failures, [], "\n".join(failures))


class PlantedBundleVersionGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "checkout"
        self.root.mkdir(parents=True)
        self.manifest = self.root / PLUGIN_MANIFEST_PATH
        self.skill = self.root / SKILLS_PREFIX / "solve" / "SKILL.md"
        self.marketplace = self.root / MARKETPLACE_MANIFEST_PATH
        self.bundle_readme = self.root / BUNDLE_README_PATH
        self.git("init", "-b", "master")
        self.git("config", "user.email", "bundle-gate@example.invalid")
        self.git("config", "user.name", "Bundle Gate Fixture")
        self.git("config", "commit.gpgsign", "false")
        (self.root / ".gitignore").write_text("__pycache__/\n", encoding="utf-8")
        self.write_manifest(ORIGINAL_BUNDLE_VERSION)
        self.marketplace.parent.mkdir(parents=True, exist_ok=True)
        self.marketplace.write_text(
            json.dumps(
                {
                    "name": "kanban",
                    "plugins": [{"name": "kanban", "version": ORIGINAL_BUNDLE_VERSION}],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.bundle_readme.parent.mkdir(parents=True, exist_ok=True)
        self.bundle_readme.write_text("fixture readme\n", encoding="utf-8")
        self.skill.parent.mkdir(parents=True, exist_ok=True)
        self.skill.write_text("---\nname: solve\n---\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-m", "baseline bundle")
        self.git("checkout", "-q", "-b", "work")

    def git(self, *args: str):
        subprocess.run(
            ["git", *args], cwd=self.root, capture_output=True, text=True, check=True
        )

    def write_manifest(self, version: str):
        self.manifest.parent.mkdir(parents=True, exist_ok=True)
        self.manifest.write_text(
            json.dumps({"name": "kanban", "version": version}) + "\n", encoding="utf-8"
        )

    def failures(self):
        return plugin_bundle_gate.bundle_version_failures(
            self.root, BUNDLE_PREFIX, BUNDLE_PREFIX, PLUGIN_MANIFEST_PATH
        )

    def test_a_committed_content_change_without_a_bump_fails(self):
        self.skill.write_text("---\nname: solve\n---\nrevised\n", encoding="utf-8")
        self.git("commit", "-am", "revise the packaged skill")
        failures = self.failures()
        self.assertEqual(len(failures), 1)
        self.assertIn(plugin_bundle_gate.VERSION_BUMP_INSTRUCTION, failures[0])
        self.assertIn(f"{SKILLS_PREFIX}/solve/SKILL.md", failures[0])

    def test_an_outer_tree_marketplace_change_without_a_bump_fails(self):
        # marketplace.json lives under grok-plugin/.grok-plugin/, outside
        # plugins/kanban/. A prefix that stopped at the inner plugin directory
        # would miss this edit and leave the gate green.
        self.marketplace.write_text(
            json.dumps(
                {
                    "name": "kanban",
                    "description": "revised",
                    "plugins": [{"name": "kanban", "version": ORIGINAL_BUNDLE_VERSION}],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        failures = self.failures()
        self.assertEqual(len(failures), 1)
        self.assertIn(plugin_bundle_gate.VERSION_BUMP_INSTRUCTION, failures[0])
        self.assertIn(MARKETPLACE_MANIFEST_PATH, failures[0])

    def test_an_outer_tree_readme_change_without_a_bump_fails(self):
        self.bundle_readme.write_text("revised readme\n", encoding="utf-8")
        failures = self.failures()
        self.assertEqual(len(failures), 1)
        self.assertIn(plugin_bundle_gate.VERSION_BUMP_INSTRUCTION, failures[0])
        self.assertIn(BUNDLE_README_PATH, failures[0])

    def test_a_change_outside_the_bundle_owes_nothing(self):
        (self.root / "README.md").write_text("unrelated\n", encoding="utf-8")
        self.git("add", "-A")
        self.git("commit", "-m", "unrelated change")
        self.assertEqual(self.failures(), [])

    def test_content_and_version_changing_together_pass(self):
        self.skill.write_text("---\nname: solve\n---\nrevised\n", encoding="utf-8")
        self.marketplace.write_text(
            json.dumps(
                {
                    "name": "kanban",
                    "description": "revised",
                    "plugins": [{"name": "kanban", "version": "1.1.0"}],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.write_manifest("1.1.0")
        self.assertEqual(self.failures(), [])
