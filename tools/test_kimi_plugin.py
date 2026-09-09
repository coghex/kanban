"""Structural coverage for the tracked Kimi plugin.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

The Kimi bundle is not a Kanban-spawned provider. It packages /solve and
/autosolve so a Kimi session (the Copilot CLI running a Kimi model) can open
a kimi-origin pull request and obtain a Codex review without invoking Claude.
These tests pin that origin, that reviewer, the vendored helpers, and the
self-review prohibition.
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
KIMI_PLUGIN = REPO_ROOT / "kimi-plugin" / "plugins" / "kanban"
CLAUDE_PLUGIN = REPO_ROOT / "claude-plugin" / "plugins" / "kanban"
GROK_COORDINATOR = (
    REPO_ROOT / "grok-plugin" / "plugins" / "kanban" / "scripts" / "review_pr.py"
)
SOLVE = KIMI_PLUGIN / "skills" / "solve" / "SKILL.md"
AUTOSOLVE = KIMI_PLUGIN / "skills" / "autosolve" / "SKILL.md"
TRUSTED_SPEC = KIMI_PLUGIN / "skills" / "solve" / "scripts" / "trusted_issue_spec.py"
COORDINATOR = KIMI_PLUGIN / "scripts" / "review_pr.py"
MODELS = KIMI_PLUGIN / "scripts" / "kanban_models.py"
PLUGIN_JSON = KIMI_PLUGIN / "plugin.json"
MARKETPLACE = REPO_ROOT / "kimi-plugin" / ".github" / "plugin" / "marketplace.json"
README = REPO_ROOT / "kimi-plugin" / "README.md"
PLUGIN_MANIFEST_PATH = "kimi-plugin/plugins/kanban/plugin.json"
MARKETPLACE_MANIFEST_PATH = "kimi-plugin/.github/plugin/marketplace.json"
SKILLS_PREFIX = "kimi-plugin/plugins/kanban/skills"
COMMAND_SIGIL = "/"
EXPECTED_SKILL_NAMES = {"solve", "autosolve"}
EXPECTED_BUNDLE_FILES = {
    "kimi-plugin/.github/plugin/marketplace.json",
    "kimi-plugin/README.md",
    "kimi-plugin/plugins/kanban/plugin.json",
    "kimi-plugin/plugins/kanban/scripts/kanban_models.py",
    "kimi-plugin/plugins/kanban/scripts/review_pr.py",
    "kimi-plugin/plugins/kanban/skills/autosolve/SKILL.md",
    "kimi-plugin/plugins/kanban/skills/solve/SKILL.md",
    "kimi-plugin/plugins/kanban/skills/solve/scripts/trusted_issue_spec.py",
}

KIMI_ORIGIN = "<!-- pr-origin:kimi -->"
CLAUDE_ORIGIN = "<!-- pr-origin:claude -->"
CODEX_ORIGIN = "<!-- pr-origin:codex -->"
GROK_ORIGIN = "<!-- pr-origin:grok -->"

COORDINATOR_LOOKUP = 'Path("scripts") / "review_pr.py"'

# The exact Python locator /autosolve's coordinator fence runs. Asserted to
# appear in the skill AND executed against a simulated install below, so a
# rewrite that keeps the prose and breaks the resolution fails here.
KIMI_COORDINATOR_PYTHON = '''import json, os, sys
from pathlib import Path

plugin_root, copilot_home = sys.argv[1], sys.argv[2]
relative = Path("scripts") / "review_pr.py"
def finish(candidate):
    if not candidate.is_file():
        raise SystemExit(f"coordinator was not found at {candidate}")
    print(candidate)
    raise SystemExit(0)
if plugin_root:
    finish(Path(plugin_root) / relative)
settings = Path(copilot_home) / "settings.json"
if os.path.lexists(settings):
    try:
        document = json.loads(settings.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"Copilot settings at {settings} are unreadable ({error}).")
    if not isinstance(document, dict):
        raise SystemExit(f"Copilot settings at {settings} are not a JSON object.")
    marketplaces = document.get("extraKnownMarketplaces")
    if marketplaces is not None and not isinstance(marketplaces, dict):
        raise SystemExit(
            f"Copilot settings at {settings} have malformed extraKnownMarketplaces."
        )
    if isinstance(marketplaces, dict) and "kanban-kimi" in marketplaces:
        entry = marketplaces["kanban-kimi"]
        if not isinstance(entry, dict):
            raise SystemExit(
                f"Copilot settings at {settings} have a malformed kanban-kimi entry."
            )
        source = entry.get("source")
        if not isinstance(source, dict) or source.get("source") != "directory":
            raise SystemExit(
                f"Copilot settings at {settings} do not name kanban-kimi as a directory source."
            )
        recorded = source.get("path")
        if not isinstance(recorded, str) or not Path(recorded).is_absolute():
            raise SystemExit(
                f"Copilot settings at {settings} do not name an absolute kanban-kimi path: {recorded!r}."
            )
        finish(Path(recorded) / "plugins" / "kanban" / relative)
matches = sorted(
    candidate
    for candidate in (Path(copilot_home) / "installed-plugins").glob(
        "kanban-*/" + relative.as_posix()
    )
    if candidate.is_file()
)
if not matches:
    raise SystemExit("coordinator was not found: $KIMI_PLUGIN_ROOT is unset, the kanban-kimi marketplace has no recorded local path, and $COPILOT_HOME/installed-plugins/kanban-* matches nothing")
if len(matches) != 1:
    raise SystemExit("ambiguous Kanban installs: " + ", ".join(str(path) for path in matches))
print(matches[0])
'''

BASH_FENCE_RE = re.compile(r"```bash\n(?P<body>.*?)\n[ \t]*```", re.DOTALL)


class PluginLayoutTests(unittest.TestCase):
    def test_the_tracked_bundle_inventory_is_exact(self):
        proc = subprocess.run(
            ["git", "ls-files", "-z", "--", "kimi-plugin"],
            cwd=REPO_ROOT,
            capture_output=True,
            check=True,
        )
        tracked = {
            path.decode("utf-8") for path in proc.stdout.split(b"\0") if path
        }
        self.assertEqual(tracked, EXPECTED_BUNDLE_FILES)

    def test_the_marketplace_lists_the_kanban_plugin(self):
        document = json.loads(MARKETPLACE.read_text(encoding="utf-8"))
        # The marketplace name differs from the plugin's on purpose: two
        # same-named user marketplaces collide at registration, and the
        # claude-plugin tree is a valid Copilot marketplace too.
        self.assertEqual(document["name"], "kanban-kimi")
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
            f"{MARKETPLACE_MANIFEST_PATH} metadata description": marketplace[
                "metadata"
            ]["description"],
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


class DocumentationTests(unittest.TestCase):
    def setUp(self):
        self.text = README.read_text(encoding="utf-8")

    def test_readme_pins_the_verified_copilot_install_mechanisms(self):
        self.assertIn("GitHub Copilot CLI 1.0.83", self.text)
        self.assertIn("--plugin-dir kimi-plugin/plugins/kanban", self.text)
        self.assertIn('plugin marketplace add "$PWD/kimi-plugin"', self.text)
        self.assertIn("plugin install kanban@kanban-kimi", self.text)
        self.assertIn(
            "extraKnownMarketplaces.kanban-kimi.source.path", self.text
        )

    def test_readme_explains_argument_and_shadowing_behavior(self):
        self.assertIn("do not substitute a `$ARGUMENTS` variable", self.text)
        self.assertIn("/solve 652", self.text)
        self.assertIn("first-found-wins", self.text)
        self.assertIn("shadow", self.text)
        self.assertIn("dedicated\n`COPILOT_HOME`", self.text)
        self.assertIn("Claude model is a canonical Claude participant", self.text)

    def test_readme_states_the_review_safety_boundary(self):
        self.assertIn("without**\n`--self-review`", self.text)
        self.assertIn("route other than `codex` is a stop", self.text)


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

    def test_review_pr_is_byte_identical_to_the_grok_coordinator(self):
        self.assertEqual(COORDINATOR.read_bytes(), GROK_COORDINATOR.read_bytes())

    def test_kanban_models_matches_the_claude_copy(self):
        self.assertEqual(
            MODELS.read_bytes(),
            (CLAUDE_PLUGIN / "scripts" / "kanban_models.py").read_bytes(),
        )


class SolveOriginTests(unittest.TestCase):
    def test_solve_stamps_kimi_origin_and_not_the_other_brands(self):
        text = SOLVE.read_text(encoding="utf-8")
        self.assertIn(KIMI_ORIGIN, text)
        self.assertNotIn(CLAUDE_ORIGIN, text)
        self.assertNotIn(CODEX_ORIGIN, text)
        self.assertNotIn(GROK_ORIGIN, text)
        self.assertIn(
            "Never stamp a Claude, Codex, or Grok origin marker from this session",
            text,
        )
        # Copilot skills receive no substituted arguments; the skill must say
        # so rather than read a $ARGUMENTS nothing sets.
        self.assertNotIn("$ARGUMENTS", text)
        self.assertIn("no substituted arguments", text)

    def test_solve_forbids_reviewing_the_pull_request(self):
        text = SOLVE.read_text(encoding="utf-8")
        self.assertIn("Do not review, label, merge, or finalize the PR", text)
        self.assertIn("never Claude", text)


class AutosolveReviewerTests(unittest.TestCase):
    def test_autosolve_requires_kimi_origin_and_codex_route(self):
        text = AUTOSOLVE.read_text(encoding="utf-8")
        self.assertIn(KIMI_ORIGIN, text)
        self.assertIn('"origin": "kimi"', text)
        self.assertIn('"route": "codex"', text)
        self.assertIn("reviewers=codex", text)
        self.assertNotIn('"$ARGUMENTS"', text)
        self.assertIn("--expected-origin kimi", text)
        self.assertIn("--expected-route codex", text)
        self.assertNotIn(CLAUDE_ORIGIN, text)
        self.assertNotIn(CODEX_ORIGIN, text)
        self.assertNotIn(GROK_ORIGIN, text)
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
        self.assertNotIn("$GROK_HOME", text)
        self.assertIn("Never fall back to a\nClaude, Codex, or Grok plugin path", text)
        self.assertIn("installed-plugins/kanban-<hash>", text)
        self.assertIn("$KIMI_PLUGIN_ROOT", text)
        self.assertIn("ambiguous Kanban installs", text)
        self.assertIn('"kanban-*/" + relative.as_posix()', text)
        self.assertIn(KIMI_COORDINATOR_PYTHON, text)


class AutosolveCoordinatorLookupTests(unittest.TestCase):
    """The autosolve coordinator locator is the same fail-closed Python as
    /solve's helper lookup, with a different relative path. String search
    cannot prove it prefers $KIMI_PLUGIN_ROOT, reads the recorded local
    marketplace path, finds one hashed install, or refuses two kanban-*
    matches — these run the fenced locator itself."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.workdir = self.root / "worked-repo"
        self.workdir.mkdir()

    def install_hashed(self, home: Path, name: str = "kanban-b0441dc6") -> Path:
        installed = home / ".copilot" / "installed-plugins" / name / "scripts"
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

    def register_local_marketplace(self, home: Path, marketplace: Path) -> None:
        copilot_home = home / ".copilot"
        copilot_home.mkdir(parents=True, exist_ok=True)
        (copilot_home / "settings.json").write_text(
            json.dumps(
                {
                    "extraKnownMarketplaces": {
                        "kanban-kimi": {
                            "source": {"source": "directory", "path": str(marketplace)}
                        }
                    }
                }
            )
            + "\n",
            encoding="utf-8",
        )

    def run_locator(self, plugin_root: str, copilot_home: str):
        return subprocess.run(
            ["python3", "-", plugin_root, copilot_home],
            input=KIMI_COORDINATOR_PYTHON,
            capture_output=True,
            text=True,
            cwd=str(self.workdir),
            timeout=60,
        )

    def test_the_autosolve_skill_declares_the_lookup_it_is_tested_with(self):
        self.assertIn(
            KIMI_COORDINATOR_PYTHON,
            AUTOSOLVE.read_text(encoding="utf-8"),
            "the Kimi autosolve skill must prefer $KIMI_PLUGIN_ROOT, then the "
            "recorded local marketplace path, else one hashed install",
        )

    def test_the_lookup_resolves_from_a_hashed_install(self):
        home = self.root / "copilot-home"
        expected = self.install_hashed(home)
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_the_lookup_resolves_from_the_recorded_local_marketplace(self):
        home = self.root / "copilot-local"
        expected = self.install_marketplace_source(self.root)
        self.register_local_marketplace(home, self.root / "marketplace")
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_a_non_directory_marketplace_source_refuses_without_glob_fallback(self):
        home = self.root / "copilot-remote"
        self.install_hashed(home)
        copilot_home = home / ".copilot"
        (copilot_home).mkdir(parents=True, exist_ok=True)
        (copilot_home / "settings.json").write_text(
            json.dumps(
                {
                    "extraKnownMarketplaces": {
                        "kanban-kimi": {
                            "source": {"source": "github", "repo": "coghex/kanban"}
                        }
                    }
                }
            )
            + "\n",
            encoding="utf-8",
        )
        proc = self.run_locator("", str(copilot_home))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("do not name kanban-kimi as a directory source", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_settings_without_a_kimi_entry_fall_through_to_the_glob(self):
        home = self.root / "copilot-unrelated-marketplace"
        expected = self.install_hashed(home)
        copilot_home = home / ".copilot"
        (copilot_home / "settings.json").write_text(
            json.dumps({"extraKnownMarketplaces": {"somewhere-else": {}}}) + "\n",
            encoding="utf-8",
        )
        proc = self.run_locator("", str(copilot_home))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_malformed_settings_refuse_without_glob_fallback(self):
        cases = {
            "invalid-json": "{",
            "non-object": json.dumps([]),
            "marketplaces-not-object": json.dumps({"extraKnownMarketplaces": []}),
            "entry-not-object": json.dumps(
                {"extraKnownMarketplaces": {"kanban-kimi": []}}
            ),
            "source-not-directory": json.dumps(
                {
                    "extraKnownMarketplaces": {
                        "kanban-kimi": {"source": {"source": "github"}}
                    }
                }
            ),
            "relative-path": json.dumps(
                {
                    "extraKnownMarketplaces": {
                        "kanban-kimi": {
                            "source": {"source": "directory", "path": "relative"}
                        }
                    }
                }
            ),
        }
        for name, contents in cases.items():
            with self.subTest(case=name):
                home = self.root / f"copilot-malformed-{name}"
                self.install_hashed(home)
                settings = home / ".copilot" / "settings.json"
                settings.write_text(contents + "\n", encoding="utf-8")
                proc = self.run_locator("", str(home / ".copilot"))
                self.assertNotEqual(proc.returncode, 0, proc.stdout)
                self.assertIn("Copilot settings", proc.stderr)
                self.assertEqual(proc.stdout.strip(), "")

    def test_a_dangling_settings_symlink_refuses_without_glob_fallback(self):
        home = self.root / "copilot-dangling-settings"
        self.install_hashed(home)
        settings = home / ".copilot" / "settings.json"
        settings.symlink_to(settings.with_name("missing-settings.json"))
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("Copilot settings", proc.stderr)
        self.assertIn("unreadable", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_a_recorded_marketplace_missing_the_helper_refuses_without_fallback(self):
        home = self.root / "copilot-marketplace-missing-helper"
        self.install_hashed(home)
        marketplace = self.root / "empty-marketplace"
        marketplace.mkdir()
        self.register_local_marketplace(home, marketplace)
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("coordinator was not found at", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_the_lookup_uses_plugin_root_for_a_marketplace_source_outside_home(self):
        home = self.root / "copilot-empty-home"
        home.mkdir()
        expected = self.install_marketplace_source(self.root)
        plugin_root = expected.parents[1]  # .../plugins/kanban
        proc = self.run_locator(str(plugin_root), str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_plugin_root_wins_over_a_hashed_install(self):
        home = self.root / "copilot-both"
        self.install_hashed(home)
        expected = self.install_marketplace_source(self.root)
        plugin_root = expected.parents[1]
        proc = self.run_locator(str(plugin_root), str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_the_lookup_fails_closed_when_two_kanban_installs_match(self):
        home = self.root / "copilot-ambiguous"
        first = self.install_hashed(home)
        self.install_hashed(home, "kanban-aaaaaaaa")
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("ambiguous Kanban installs", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")
        self.assertTrue(first.is_file())

    def test_the_lookup_ignores_a_competing_plugin_with_the_same_relative_path(self):
        home = self.root / "copilot-competitor"
        expected = self.install_hashed(home)
        other = (
            home
            / ".copilot"
            / "installed-plugins"
            / "otherplugin-deadbeef"
            / "scripts"
            / "review_pr.py"
        )
        other.parent.mkdir(parents=True)
        other.write_text("print('other')\n", encoding="utf-8")
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_the_lookup_fails_closed_when_no_install_matches(self):
        home = self.root / "copilot-empty"
        (home / ".copilot" / "installed-plugins").mkdir(parents=True)
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("coordinator was not found:", proc.stderr)
        self.assertIn("$KIMI_PLUGIN_ROOT is unset", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_plugin_root_fails_closed_when_the_relative_path_is_missing(self):
        home = self.root / "copilot-missing"
        home.mkdir()
        plugin_root = self.root / "marketplace" / "plugins" / "kanban"
        plugin_root.mkdir(parents=True)
        proc = self.run_locator(str(plugin_root), str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("coordinator was not found at", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")


def load_kimi_review_pr():
    spec = importlib.util.spec_from_file_location(
        "kanban_kimi_plugin_review_pr", COORDINATOR
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
        self.module = load_kimi_review_pr()
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

    def pr(self, origin, *, cross_repository=False):
        body = "summary\n\n"
        if origin is not None:
            body += f"<!-- pr-origin:{origin} -->\n"
        return {
            "url": "https://github.com/coghex/kanban/pull/7",
            "headRefOid": "a" * 40,
            "body": body,
            "isCrossRepository": cross_repository,
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
            origin="claude", expected_origin="kimi", expected_route="codex"
        )
        self.assert_mismatch(code, result, "claude", "codex")
        self.assertIn("no reviewer was spawned", result["error"])

    def test_an_unknown_origin_refuses_before_the_dual_route_can_spawn_claude(self):
        code, result = self.run_workflow(
            origin=None, expected_origin="kimi", expected_route="codex"
        )
        self.assert_mismatch(code, result, "unknown", "codex+claude")
        self.assertIn("no reviewer was spawned", result["error"])

    def test_a_route_only_drift_refuses_before_spawning_claude(self):
        single = self.module.kanban_models().SINGLE_AGENT_MODE
        with mock.patch.object(
            self.module, "operating_mode", return_value=(single, ("claude",))
        ):
            code, result = self.run_workflow(
                origin="kimi", expected_origin="kimi", expected_route="codex"
            )
        self.assert_mismatch(code, result, "kimi", "claude")
        self.assertIn("does not match --expected-route", result["error"])
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
                        self.pr("kimi"),
                        gate,
                        [self.module.CODEX_REVIEWER],
                        [{"verdict": "APPROVE", "summary": "ok", "blocking_concerns": []}],
                        {"pr": 7},
                        allow_no_issue=True,
                        expected_origin="kimi",
                        expected_route="codex",
                    )
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "route_mismatch")
        self.assertEqual(result["origin"], "unknown")
        self.assertEqual(self.calls, [])

    def test_publication_refuses_a_route_only_drift_before_writing(self):
        kimi_pr = self.pr("kimi")
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
        single = self.module.kanban_models().SINGLE_AGENT_MODE
        with mock.patch.object(self.module, "pr_view", return_value=kimi_pr):
            with mock.patch.object(
                self.module, "operating_mode", return_value=(single, ("claude",))
            ):
                with mock.patch.object(self.module, "gate_status", return_value=gate):
                    with mock.patch.object(
                        self.module, "resolve_workflow_labels", return_value=("a", "c")
                    ):
                        code, result = self.module.publish_results(
                            Path("/fake-repo"),
                            "coghex/kanban",
                            7,
                            kimi_pr,
                            gate,
                            [self.module.CODEX_REVIEWER],
                            [
                                {
                                    "verdict": "APPROVE",
                                    "summary": "ok",
                                    "blocking_concerns": [],
                                }
                            ],
                            {"pr": 7},
                            allow_no_issue=True,
                            expected_origin="kimi",
                            expected_route="codex",
                        )
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "route_mismatch")
        self.assertEqual(result["origin"], "kimi")
        self.assertEqual(result["route"], "claude")
        self.assertIn("does not match --expected-route", result["error"])
        self.assertEqual(self.calls, [])

    def test_publication_refuses_origin_drift_on_a_later_reread(self):
        kimi_pr = self.pr("kimi")
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
            self.module, "pr_view", side_effect=[kimi_pr, drifted]
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
                            kimi_pr,
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
                            expected_origin="kimi",
                            expected_route="codex",
                        )
        self.assertIn("does not match --expected-origin", str(raised.exception))
        self.assertEqual(self.calls, [])

    def test_a_matching_kimi_codex_binding_is_not_a_mismatch(self):
        with mock.patch.object(self.module, "pr_view", return_value=self.pr("kimi")):
            with mock.patch.object(self.module, "collect_context") as collect:
                collect.side_effect = RuntimeError("stop after the binding check")
                with self.assertRaises(RuntimeError):
                    self.module.workflow(
                        Path("/fake-repo"),
                        7,
                        rereview=False,
                        dry_run=False,
                        allow_no_issue=True,
                        expected_origin="kimi",
                        expected_route="codex",
                    )
                collect.assert_called()

    def test_pr_origin_keeps_cross_repository_external_markers(self):
        self.assertEqual(
            self.module.pr_origin(self.pr("kimi", cross_repository=True)),
            "kimi",
        )
        self.assertIsNone(
            self.module.pr_origin(self.pr("claude", cross_repository=True))
        )
        self.assertIsNone(
            self.module.pr_origin(self.pr("codex", cross_repository=True))
        )
        self.assertEqual(
            self.module.pr_origin(self.pr("grok", cross_repository=True)),
            "grok",
        )
        self.assertEqual(
            self.module.pr_origin(self.pr("kimi", cross_repository=False)),
            "kimi",
        )

    def test_a_cross_repository_kimi_origin_still_routes_to_codex(self):
        # /solve opens a fork PR with --head <push-owner>:<branch>, which GitHub
        # reports as isCrossRepository. That must not wipe a kimi marker: the
        # unknown dual-mode route is codex+claude, and /autosolve refuses it.
        with mock.patch.object(
            self.module,
            "pr_view",
            return_value=self.pr("kimi", cross_repository=True),
        ):
            with mock.patch.object(self.module, "collect_context") as collect:
                collect.side_effect = RuntimeError("stop after the binding check")
                with self.assertRaises(RuntimeError):
                    self.module.workflow(
                        Path("/fake-repo"),
                        7,
                        rereview=False,
                        dry_run=False,
                        allow_no_issue=True,
                        expected_origin="kimi",
                        expected_route="codex",
                    )
                collect.assert_called()
                self.assertEqual(self.calls, [])

    def test_a_cross_repository_non_kimi_marker_stays_unknown(self):
        code, result = self.run_workflow_cross(
            origin="claude", expected_origin="kimi", expected_route="codex"
        )
        self.assert_mismatch(code, result, "unknown", "codex+claude")
        self.assertIn("no reviewer was spawned", result["error"])

    def run_workflow_cross(self, origin, expected_origin, expected_route):
        with mock.patch.object(
            self.module,
            "pr_view",
            return_value=self.pr(origin, cross_repository=True),
        ):
            return self.module.workflow(
                Path("/fake-repo"),
                7,
                rereview=False,
                dry_run=False,
                allow_no_issue=True,
                expected_origin=expected_origin,
                expected_route=expected_route,
            )


# The whole tracked Kimi tree, not just plugins/kanban/: marketplace.json
# and kimi-plugin/README.md live outside that inner prefix and still ship.
BUNDLE_PREFIX = "kimi-plugin"
ORIGINAL_BUNDLE_VERSION = "1.0.0"
BUNDLE_README_PATH = "kimi-plugin/README.md"


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
                    "name": "kanban-kimi",
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
        # marketplace.json lives under kimi-plugin/.github/plugin/, outside
        # plugins/kanban/. A prefix that stopped at the inner plugin directory
        # would miss this edit and leave the gate green.
        self.marketplace.write_text(
            json.dumps(
                {
                    "name": "kanban-kimi",
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
                    "name": "kanban-kimi",
                    "description": "revised",
                    "plugins": [{"name": "kanban", "version": "1.1.0"}],
                }
            )
            + "\n",
            encoding="utf-8",
        )
        self.write_manifest("1.1.0")
        self.assertEqual(self.failures(), [])


if __name__ == "__main__":
    unittest.main()
