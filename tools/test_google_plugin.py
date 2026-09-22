"""Structural coverage for the tracked Google plugin.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

The Google bundle is not a Kanban-spawned provider. It packages /solve and
/autosolve so a Google session (the Copilot CLI running a Gemini model) can open
a google-origin pull request and obtain a Codex review without invoking Claude.
These tests pin that origin, that reviewer, the vendored helpers, the
self-review prohibition, and the terminal wording, which must assign merge
authority where `docs/agent-workflow-contract.md` §2.10 assigns it and must
name no workflow this bundle does not ship.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import plugin_bundle_gate
# The solve locator is declared and unit-tested beside the other four
# trusted-helper lookups; importing it here is what lets the real-CLI
# fixtures below run BOTH of this bundle's locators against one install
# rather than keeping a second copy of the same fenced Python.
import test_trusted_issue_spec

REPO_ROOT = Path(__file__).resolve().parent.parent
GOOGLE_PLUGIN = REPO_ROOT / "google-plugin" / "plugins" / "kanban"
CLAUDE_PLUGIN = REPO_ROOT / "claude-plugin" / "plugins" / "kanban"
GROK_COORDINATOR = (
    REPO_ROOT / "grok-plugin" / "plugins" / "kanban" / "scripts" / "review_pr.py"
)
SOLVE = GOOGLE_PLUGIN / "skills" / "solve" / "SKILL.md"
AUTOSOLVE = GOOGLE_PLUGIN / "skills" / "autosolve" / "SKILL.md"
TRUSTED_SPEC = GOOGLE_PLUGIN / "skills" / "solve" / "scripts" / "trusted_issue_spec.py"
COORDINATOR = GOOGLE_PLUGIN / "scripts" / "review_pr.py"
MODELS = GOOGLE_PLUGIN / "scripts" / "kanban_models.py"
PLUGIN_JSON = GOOGLE_PLUGIN / "plugin.json"
MARKETPLACE = REPO_ROOT / "google-plugin" / ".github" / "plugin" / "marketplace.json"
README = REPO_ROOT / "google-plugin" / "README.md"
PLUGIN_MANIFEST_PATH = "google-plugin/plugins/kanban/plugin.json"
MARKETPLACE_MANIFEST_PATH = "google-plugin/.github/plugin/marketplace.json"
SKILLS_PREFIX = "google-plugin/plugins/kanban/skills"
COMMAND_SIGIL = "/"
EXPECTED_SKILL_NAMES = {"solve", "autosolve"}
EXPECTED_BUNDLE_FILES = {
    "google-plugin/.github/plugin/marketplace.json",
    "google-plugin/README.md",
    "google-plugin/plugins/kanban/plugin.json",
    "google-plugin/plugins/kanban/scripts/kanban_models.py",
    "google-plugin/plugins/kanban/scripts/review_pr.py",
    "google-plugin/plugins/kanban/skills/autosolve/SKILL.md",
    "google-plugin/plugins/kanban/skills/solve/SKILL.md",
    "google-plugin/plugins/kanban/skills/solve/scripts/trusted_issue_spec.py",
}

GOOGLE_ORIGIN = "<!-- pr-origin:google -->"
CLAUDE_ORIGIN = "<!-- pr-origin:claude -->"
CODEX_ORIGIN = "<!-- pr-origin:codex -->"
GROK_ORIGIN = "<!-- pr-origin:grok -->"
KIMI_ORIGIN = "<!-- pr-origin:kimi -->"

COORDINATOR_LOOKUP = 'Path("scripts") / "review_pr.py"'

# The exact Python locator /autosolve's coordinator fence runs. Asserted to
# appear in the skill AND executed against a simulated install below, so a
# rewrite that keeps the prose and breaks the resolution fails here.
GOOGLE_COORDINATOR_PYTHON = '''import json, os, sys
from pathlib import Path

plugin_root, copilot_home = sys.argv[1], sys.argv[2]
relative = Path("scripts") / "review_pr.py"
marketplace, plugin, bundle = "kanban-google", "kanban", "google-plugin-plugins-kanban"
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
    if isinstance(marketplaces, dict) and marketplace in marketplaces:
        entry = marketplaces[marketplace]
        if not isinstance(entry, dict):
            raise SystemExit(
                f"Copilot settings at {settings} have a malformed {marketplace} entry."
            )
        source = entry.get("source")
        if not isinstance(source, dict):
            raise SystemExit(
                f"Copilot settings at {settings} have a malformed {marketplace} source."
            )
        kind = source.get("source")
        if kind == "directory":
            recorded = source.get("path")
            if not isinstance(recorded, str) or not Path(recorded).is_absolute():
                raise SystemExit(
                    f"Copilot settings at {settings} do not name an absolute {marketplace} path: {recorded!r}."
                )
            finish(Path(recorded) / "plugins" / plugin / relative)
        locates = {"github": "repo", "git": "url", "url": "url"}.get(kind)
        if locates is None:
            raise SystemExit(
                f"Copilot settings at {settings} name an unsupported {marketplace} source kind: {kind!r}."
            )
        located = source.get(locates)
        if not isinstance(located, str) or not located.strip():
            raise SystemExit(
                f"Copilot settings at {settings} do not name a {locates} for the {kind} {marketplace} source: {located!r}."
            )
installed = Path(copilot_home) / "installed-plugins"
def installs_this_bundle(name):
    repository, separator, subdirectory = name.rpartition("--")
    return separator == "--" and subdirectory == bundle and "--" in repository
roots = []
from_marketplace = installed / marketplace / plugin
if from_marketplace.is_dir():
    roots.append(from_marketplace)
direct = installed / "_direct"
if direct.is_dir():
    roots += sorted(
        child
        for child in direct.iterdir()
        if child.is_dir() and installs_this_bundle(child.name)
    )
if not roots:
    raise SystemExit(f"coordinator was not found: $GOOGLE_PLUGIN_ROOT is unset, the {marketplace} marketplace has no recorded local path, and neither {from_marketplace} nor {direct}/<owner>--<repo>--{bundle} exists")
if len(roots) != 1:
    raise SystemExit("ambiguous Kanban installs: " + ", ".join(str(root) for root in roots))
finish(roots[0] / relative)
'''

# The entry name `copilot plugin install coghex/kanban:google-plugin/plugins/kanban` writes under
# `$COPILOT_HOME/installed-plugins/_direct/`, observed with GitHub Copilot
# CLI 1.0.85 and re-pinned against the real CLI by RealCopilotInstallTests:
# <owner>--<repo>--<bundle path>, the path's separators flattened.
DIRECT_ENTRY = "coghex--kanban--google-plugin-plugins-kanban"
GOOGLE_BUNDLE = REPO_ROOT / "google-plugin"
COPILOT_CLI = shutil.which("copilot")

BASH_FENCE_RE = re.compile(r"```bash\n(?P<body>.*?)\n[ \t]*```", re.DOTALL)

# Issue #699's rule, as a function so the planted control below drives exactly
# what the assets are held to. Both sigils: these three assets were hand-copied
# from the Claude rendering, and a Codex-spelled `$finalize` names a workflow
# this bundle ships just as little as `/finalize` does.
FINALIZE_REFERENCE_RE = re.compile(r"[/$]finalize\b")


def finalize_references(text: str) -> list[str]:
    return FINALIZE_REFERENCE_RE.findall(text)


# The two claims issue #699 retired from every autosolve asset. Both
# contradicted `docs/agent-workflow-contract.md` §2.10, which gives ordinary
# merge authority to the PR drainer and makes manual finalization the user's
# own fallback for when that drainer cannot be used. Written flat, and matched
# against whitespace-collapsed text, because the source wrapped both across
# lines -- a line-oriented search finds neither.
RETIRED_TERMINAL_PHRASES = (
    "the merge is a deliberate manual step the user takes",
    "run /finalize when ready.",
)


class PluginLayoutTests(unittest.TestCase):
    def test_the_tracked_bundle_inventory_is_exact(self):
        proc = subprocess.run(
            ["git", "ls-files", "-z", "--", "google-plugin"],
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
        self.assertEqual(document["name"], "kanban-google")
        names = [plugin["name"] for plugin in document["plugins"]]
        self.assertEqual(names, ["kanban"])
        self.assertEqual(document["plugins"][0]["source"], "./plugins/kanban")

    def test_the_plugin_manifest_declares_version_1_3_0(self):
        document = json.loads(PLUGIN_JSON.read_text(encoding="utf-8"))
        self.assertEqual(document["name"], "kanban")
        self.assertEqual(document["version"], "1.3.0")

    def test_solve_and_autosolve_skills_exist(self):
        self.assertTrue(SOLVE.is_file())
        self.assertTrue(AUTOSOLVE.is_file())
        for path, name in ((SOLVE, "solve"), (AUTOSOLVE, "autosolve")):
            text = path.read_text(encoding="utf-8")
            self.assertIn(f"name: {name}", text)
            self.assertIn("description:", text)


class ManifestListingParityTests(unittest.TestCase):
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
        self.assertIn("GitHub Copilot CLI 1.0.85", self.text)
        self.assertIn("--plugin-dir google-plugin/plugins/kanban", self.text)
        self.assertIn('plugin marketplace add "$PWD/google-plugin"', self.text)
        self.assertIn("plugin install kanban@kanban-google", self.text)
        self.assertIn(
            "extraKnownMarketplaces.kanban-google.source.path", self.text
        )

    def test_readme_states_the_observed_install_contract(self):
        # Requirement 5: what each supported install path records, where it
        # puts files, and that a remote marketplace registration is not
        # available while the manifest stays in a subdirectory.
        self.assertIn(
            "copilot plugin install coghex/kanban:google-plugin/plugins/kanban",
            self.text,
        )
        self.assertIn(
            "installed-plugins/_direct/coghex--kanban--google-plugin-plugins-kanban/",
            self.text,
        )
        self.assertIn("installed-plugins/kanban-google/kanban/", self.text)
        self.assertIn("*remote* marketplace\nregistration of it is not available", self.text)
        self.assertIn("`cache_path`", self.text)
        self.assertIn("`enabledPlugins`", self.text)
        self.assertNotIn("installed-plugins/kanban-*", self.text)
        self.assertIn("gemini-3.8-flash", self.text)

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
    def test_solve_stamps_google_origin_and_not_the_other_brands(self):
        text = SOLVE.read_text(encoding="utf-8")
        self.assertIn(GOOGLE_ORIGIN, text)
        self.assertNotIn(CLAUDE_ORIGIN, text)
        self.assertNotIn(CODEX_ORIGIN, text)
        self.assertNotIn(GROK_ORIGIN, text)
        self.assertNotIn(KIMI_ORIGIN, text)
        self.assertIn(
            "Never stamp a Claude, Codex, Grok, or Kimi origin marker from this session",
            text,
        )
        self.assertNotIn("$ARGUMENTS", text)
        self.assertIn("no substituted arguments", text)

    def test_solve_forbids_reviewing_the_pull_request(self):
        text = SOLVE.read_text(encoding="utf-8")
        self.assertIn("Do not review, label, merge, or finalize the PR", text)
        self.assertIn("never Claude", text)


class AutosolveReviewerTests(unittest.TestCase):
    def test_autosolve_requires_google_origin_and_codex_route(self):
        text = AUTOSOLVE.read_text(encoding="utf-8")
        self.assertIn(GOOGLE_ORIGIN, text)
        self.assertIn('"origin": "google"', text)
        self.assertIn('"route": "codex"', text)
        self.assertIn("reviewers=codex", text)
        self.assertNotIn('"$ARGUMENTS"', text)
        self.assertIn("--expected-origin google", text)
        self.assertIn("--expected-route codex", text)
        self.assertNotIn(CLAUDE_ORIGIN, text)
        self.assertNotIn(CODEX_ORIGIN, text)
        self.assertNotIn(GROK_ORIGIN, text)
        self.assertNotIn(KIMI_ORIGIN, text)
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
        self.assertNotIn("$KIMI_PLUGIN_ROOT", text)
        self.assertIn("Never fall back to a\nClaude, Codex, Grok, or Kimi plugin path", text)
        self.assertNotIn("installed-plugins/kanban-<hash>", text)
        self.assertNotIn("kanban-*", text)
        self.assertIn("$GOOGLE_PLUGIN_ROOT", text)
        self.assertIn("ambiguous Kanban installs", text)
        self.assertIn("`kanban-google/kanban/`", text)
        self.assertIn("`_direct/<owner>--<repo>--google-plugin-plugins-kanban/`", text)
        self.assertIn('installed / marketplace / plugin', text)
        self.assertIn('installed / "_direct"', text)
        self.assertIn(GOOGLE_COORDINATOR_PYTHON, text)


class AutosolveTerminalBehaviorTests(unittest.TestCase):
    """Issue #699. This bundle ships exactly `solve` and `autosolve`, so
    `/finalize` is not a workflow a Google session can run -- and the
    hand-copied §7 both named it and called the merge "a deliberate manual step
    the user takes", which contradicts `docs/agent-workflow-contract.md` §2.10.
    The prohibition is unchanged: this workflow still merges nothing, labels
    nothing, finalizes nothing, and drives no drainer."""

    def squashed(self) -> str:
        return re.sub(r"\s+", " ", AUTOSOLVE.read_text(encoding="utf-8"))

    def test_the_prohibition_and_the_contract_division_are_both_stated(self):
        squashed = self.squashed()
        self.assertIn("at approval; never merge or finalize.", squashed)
        self.assertIn(
            "This workflow never merges, never labels, never finalizes, and "
            "never controls the drainer.",
            squashed,
        )
        self.assertIn(
            "Where a repository's PR drainer is installed, that drainer owns "
            "merging eligible approved pull requests",
            squashed,
        )
        # The drainer is optional, so the asset may not promise a merge.
        self.assertIn(
            "it is optional, and a repository may have none, so approval here "
            "promises no merge at all",
            squashed,
        )
        self.assertIn(
            "Manual finalization is the user's own fallback for when the "
            "drainer cannot be used, and this bundle ships no such workflow "
            "for this session to run.",
            squashed,
        )

    def test_the_approved_closing_line_directs_the_reader_to_no_merge(self):
        squashed = self.squashed()
        self.assertIn(
            "PR #<pr> approved after <k> inline review round(s) — this run "
            "merges nothing.",
            squashed,
        )
        for phrase in RETIRED_TERMINAL_PHRASES:
            with self.subTest(phrase=phrase):
                self.assertNotIn(phrase, squashed)

    def test_the_asset_names_no_finalize_workflow_this_bundle_lacks(self):
        # The shipped set is derived, not restated: were this bundle ever to
        # gain a finalize skill, this test would have to be revisited rather
        # than silently keep forbidding a workflow that had become real.
        shipped = plugin_bundle_gate.tracked_skill_names(REPO_ROOT, SKILLS_PREFIX)
        self.assertNotIn("finalize", shipped)
        self.assertEqual(
            finalize_references(AUTOSOLVE.read_text(encoding="utf-8")), []
        )

    def test_the_unshipped_reference_rule_detects_a_planted_mention(self):
        # The control for the negative assertion above.
        planted = (
            AUTOSOLVE.read_text(encoding="utf-8") + "\nrun /finalize when ready.\n"
        )
        self.assertEqual(finalize_references(planted), ["/finalize"])


class AutosolveCoordinatorLookupTests(unittest.TestCase):
    """The autosolve coordinator locator is the same fail-closed Python as
    /solve's helper lookup, with a different relative path. String search
    cannot prove it prefers $GOOGLE_PLUGIN_ROOT, reads the recorded local
    marketplace path, resolves the two copied layouts the Copilot CLI really
    creates, or refuses an ambiguous or wrong-brand candidate — these run the
    fenced locator itself."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.workdir = self.root / "worked-repo"
        self.workdir.mkdir()

    def plant(self, root: Path) -> Path:
        target = root / "scripts" / "review_pr.py"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("print('coordinator')\n", encoding="utf-8")
        return target

    def install_direct(self, home: Path, name: str = DIRECT_ENTRY) -> Path:
        """The direct-install layout, under the entry name the CLI produces.

        `DIRECT_ENTRY` is not invented here: it is what
        `copilot plugin install coghex/kanban:google-plugin/plugins/kanban`
        writes, pinned against the real CLI by `RealCopilotInstallTests`
        below so these CLI-independent cases cannot drift onto a name no
        install produces.
        """
        return self.plant(
            home / ".copilot" / "installed-plugins" / "_direct" / name
        )

    def install_marketplace_layout(
        self, home: Path, marketplace: str = "kanban-google", plugin: str = "kanban"
    ) -> Path:
        """The documented `installed-plugins/<marketplace>/<plugin>/` layout."""
        return self.plant(
            home / ".copilot" / "installed-plugins" / marketplace / plugin
        )

    def install_marketplace_source(self, root: Path) -> Path:
        return self.plant(root / "marketplace" / "plugins" / "kanban")

    def register_local_marketplace(self, home: Path, marketplace: Path) -> None:
        self.write_settings(
            home,
            {
                "extraKnownMarketplaces": {
                    "kanban-google": {
                        "source": {"source": "directory", "path": str(marketplace)}
                    }
                }
            },
        )

    def write_settings(self, home: Path, document) -> Path:
        copilot_home = home / ".copilot"
        copilot_home.mkdir(parents=True, exist_ok=True)
        settings = copilot_home / "settings.json"
        settings.write_text(json.dumps(document) + "\n", encoding="utf-8")
        return settings

    def run_locator(self, plugin_root: str, copilot_home: str):
        return subprocess.run(
            ["python3", "-", plugin_root, copilot_home],
            input=GOOGLE_COORDINATOR_PYTHON,
            capture_output=True,
            text=True,
            cwd=str(self.workdir),
            timeout=60,
        )

    def test_the_autosolve_skill_declares_the_lookup_it_is_tested_with(self):
        self.assertIn(
            GOOGLE_COORDINATOR_PYTHON,
            AUTOSOLVE.read_text(encoding="utf-8"),
            "the Google autosolve skill must prefer $GOOGLE_PLUGIN_ROOT, then the "
            "recorded local marketplace path, then the copied install layouts",
        )

    def test_the_lookup_resolves_from_a_direct_install(self):
        home = self.root / "copilot-direct"
        expected = self.install_direct(home)
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_the_lookup_resolves_from_the_documented_marketplace_layout(self):
        home = self.root / "copilot-marketplace-layout"
        expected = self.install_marketplace_layout(home)
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

    def test_a_remote_marketplace_source_reaches_the_copied_install_layouts(self):
        # Requirement 4: a recognized remote kind may not terminate discovery
        # the way the shipped locator did. `github` locates its marketplace by
        # `repo` and the two URL kinds by `url`, per the CLI's plugin reference
        # and the `source` record Copilot CLI 1.0.85 writes into its own
        # config.json for a repository install.
        for kind, record in (
            ("github", {"repo": "coghex/kanban"}),
            ("git", {"url": "https://example.com/marketplace.git"}),
            ("url", {"url": "ssh://git@example.com/marketplace.git"}),
        ):
            with self.subTest(kind=kind):
                home = self.root / f"copilot-remote-{kind}"
                expected = self.install_direct(home)
                self.write_settings(
                    home,
                    {
                        "extraKnownMarketplaces": {
                            "kanban-google": {"source": {"source": kind, **record}}
                        }
                    },
                )
                proc = self.run_locator("", str(home / ".copilot"))
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_a_malformed_remote_marketplace_source_refuses_without_fallback(self):
        # A recognized kind is not by itself a well-formed record: one naming
        # no marketplace to have been installed from is malformed, and refuses
        # terminally rather than falling through to a copied install.
        for name, record in (
            ("github-without-repo", {"source": "github"}),
            ("github-repo-not-a-string", {"source": "github", "repo": ["x"]}),
            ("github-blank-repo", {"source": "github", "repo": "   "}),
            ("github-carrying-only-a-url", {"source": "github", "url": "https://x"}),
            ("git-without-url", {"source": "git"}),
            ("git-url-not-a-string", {"source": "git", "url": 7}),
            ("url-without-url", {"source": "url"}),
        ):
            with self.subTest(case=name):
                home = self.root / f"copilot-malformed-remote-{name}"
                self.install_direct(home)
                self.write_settings(
                    home,
                    {"extraKnownMarketplaces": {"kanban-google": {"source": record}}},
                )
                proc = self.run_locator("", str(home / ".copilot"))
                self.assertNotEqual(proc.returncode, 0, proc.stdout)
                self.assertIn(
                    f"for the {record['source']} kanban-google source", proc.stderr
                )
                self.assertEqual(proc.stdout.strip(), "")

    def test_an_unsupported_marketplace_source_kind_refuses_without_fallback(self):
        home = self.root / "copilot-unsupported-source"
        self.install_direct(home)
        self.write_settings(
            home,
            {
                "extraKnownMarketplaces": {
                    "kanban-google": {"source": {"source": "carrier-pigeon"}}
                }
            },
        )
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("unsupported kanban-google source kind", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_settings_without_a_google_entry_fall_through_to_the_copied_layouts(self):
        home = self.root / "copilot-unrelated-marketplace"
        expected = self.install_direct(home)
        self.write_settings(home, {"extraKnownMarketplaces": {"somewhere-else": {}}})
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_malformed_settings_refuse_without_fallback(self):
        cases = {
            "invalid-json": "{",
            "non-object": json.dumps([]),
            "marketplaces-not-object": json.dumps({"extraKnownMarketplaces": []}),
            "entry-not-object": json.dumps(
                {"extraKnownMarketplaces": {"kanban-google": []}}
            ),
            "source-not-object": json.dumps(
                {"extraKnownMarketplaces": {"kanban-google": {"source": "directory"}}}
            ),
            "relative-path": json.dumps(
                {
                    "extraKnownMarketplaces": {
                        "kanban-google": {
                            "source": {"source": "directory", "path": "relative"}
                        }
                    }
                }
            ),
        }
        for name, contents in cases.items():
            with self.subTest(case=name):
                home = self.root / f"copilot-malformed-{name}"
                self.install_direct(home)
                settings = home / ".copilot" / "settings.json"
                settings.write_text(contents + "\n", encoding="utf-8")
                proc = self.run_locator("", str(home / ".copilot"))
                self.assertNotEqual(proc.returncode, 0, proc.stdout)
                self.assertIn("Copilot settings", proc.stderr)
                self.assertEqual(proc.stdout.strip(), "")

    def test_a_dangling_settings_symlink_refuses_without_fallback(self):
        home = self.root / "copilot-dangling-settings"
        self.install_direct(home)
        settings = home / ".copilot" / "settings.json"
        settings.symlink_to(settings.with_name("missing-settings.json"))
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("Copilot settings", proc.stderr)
        self.assertIn("unreadable", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_a_recorded_marketplace_missing_the_helper_refuses_without_fallback(self):
        home = self.root / "copilot-marketplace-missing-helper"
        self.install_direct(home)
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

    def test_plugin_root_wins_over_both_copied_layouts(self):
        home = self.root / "copilot-both"
        self.install_direct(home)
        self.install_marketplace_layout(home)
        expected = self.install_marketplace_source(self.root)
        plugin_root = expected.parents[1]
        proc = self.run_locator(str(plugin_root), str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_the_lookup_fails_closed_when_both_copied_layouts_are_eligible(self):
        home = self.root / "copilot-ambiguous-layouts"
        direct = self.install_direct(home)
        layout = self.install_marketplace_layout(home)
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("ambiguous Kanban installs", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")
        self.assertTrue(direct.is_file() and layout.is_file())

    def test_the_lookup_fails_closed_when_two_direct_installs_match(self):
        home = self.root / "copilot-ambiguous-direct"
        first = self.install_direct(home)
        self.install_direct(home, "someone--fork--google-plugin-plugins-kanban")
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("ambiguous Kanban installs", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")
        self.assertTrue(first.is_file())

    def test_a_sole_candidate_missing_the_coordinator_refuses(self):
        # Requirement 2 and the review's addition: roots are identified before
        # the helper is looked for, so an empty install refuses rather than
        # silently leaving the candidate set empty.
        home = self.root / "copilot-missing-coordinator"
        root = home / ".copilot" / "installed-plugins" / "_direct" / DIRECT_ENTRY
        root.mkdir(parents=True)
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("coordinator was not found at", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_an_empty_candidate_does_not_lose_silently_to_a_competitor(self):
        home = self.root / "copilot-missing-and-competing"
        (home / ".copilot" / "installed-plugins" / "_direct" / DIRECT_ENTRY).mkdir(
            parents=True
        )
        self.install_marketplace_layout(home)
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("ambiguous Kanban installs", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_a_wrong_brand_install_is_not_adopted(self):
        home = self.root / "copilot-wrong-brand"
        self.install_direct(home, "coghex--kanban--kimi-plugin-plugins-kanban")
        self.install_marketplace_layout(home, marketplace="kanban-kimi")
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("coordinator was not found:", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_a_mixed_brand_home_resolves_this_bundle_alone(self):
        home = self.root / "copilot-mixed-brand"
        expected = self.install_direct(home)
        self.install_direct(
            home, "coghex--kanban--kimi-plugin-plugins-kanban"
        )
        self.install_marketplace_layout(home, marketplace="kanban-kimi")
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_a_bare_plugin_named_direct_entry_is_not_adopted(self):
        # A local-path `copilot plugin install <dir>` names its entry after the
        # plugin alone, and both Copilot bundles declare the plugin name
        # `kanban`. That identifies no bundle, so it is refused rather than
        # guessed at; `RealCopilotInstallTests` pins that entry name too.
        home = self.root / "copilot-bare-plugin-entry"
        self.install_direct(home, "kanban")
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("coordinator was not found:", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_the_lookup_ignores_a_competing_plugin_with_the_same_relative_path(self):
        home = self.root / "copilot-competitor"
        expected = self.install_direct(home)
        self.plant(
            home / ".copilot" / "installed-plugins" / "otherplugin" / "kanban"
        )
        self.plant(
            home
            / ".copilot"
            / "installed-plugins"
            / "_direct"
            / "someone--other--tools-plugins-kanban"
        )
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_the_lookup_fails_closed_when_no_install_matches(self):
        home = self.root / "copilot-empty"
        (home / ".copilot" / "installed-plugins").mkdir(parents=True)
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("coordinator was not found:", proc.stderr)
        self.assertIn("$GOOGLE_PLUGIN_ROOT is unset", proc.stderr)
        self.assertNotIn("installed-plugins/kanban-*", proc.stderr)
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


# Output substrings that mean the repository install could not be attempted —
# no network, no credential, or GitHub refusing service — as opposed to the
# install contract having changed. Only these turn that one CLI-dependent test
# into a skip; every other failure of every CLI command below is a failure.
UNAVAILABLE_SIGNALS = (
    "could not resolve",
    "getaddrinfo",
    "enotfound",
    "econnrefused",
    "econnreset",
    "etimedout",
    "network",
    "offline",
    "unreachable",
    "connection refused",
    "timed out",
    "certificate",
    "tls",
    "proxy",
    "authentication",
    "unauthorized",
    "credential",
    "not logged in",
    "rate limit",
    " 401",
    " 403",
    " 429",
    " 502",
    " 503",
    " 504",
)

# Both locators this bundle ships, as (what each calls the thing it looks for,
# the fenced Python that looks for it, the path it must resolve inside an
# install root). RealCopilotInstallTests runs every one of them against each
# install the real CLI produces.
BUNDLE_LOCATORS = (
    ("coordinator", GOOGLE_COORDINATOR_PYTHON, Path("scripts") / "review_pr.py"),
    (
        "trusted helper",
        test_trusted_issue_spec.GOOGLE_HELPER_PYTHON,
        Path("skills") / "solve" / "scripts" / "trusted_issue_spec.py",
    ),
)

class RealCopilotInstallTests(unittest.TestCase):
    """Produce the copied install with the real CLI, never by hand.

    Verified with GitHub Copilot CLI 1.0.85. These skip explicitly when the
    CLI is absent, which is how CI runs them; what they exist for is to pin
    the entry names `AutosolveCoordinatorLookupTests` builds its
    CLI-independent fixtures from, so a passing suite can never assert
    discovery against a directory no install produces.

    Once the CLI is present, a failing install is a failure, not a skip: a
    rejected bundle path or a changed install contract is exactly what these
    exist to catch. The one exception is the repository install, which needs
    the network and a credential; it skips only when the CLI's own output
    carries one of `UNAVAILABLE_SIGNALS`, and fails on anything else.

    Every case runs both of this bundle's locators, solve's and autosolve's,
    against the one install: a layout that resolves the coordinator and not
    the trusted-comment helper is half a discovery.
    """

    def setUp(self):
        if COPILOT_CLI is None:
            self.skipTest("the GitHub Copilot CLI is not installed")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "copilot-home"
        self.home.mkdir()
        # A directory that is not a Kanban checkout, so nothing resolves from
        # the working directory, and an isolated cache beside the isolated
        # COPILOT_HOME.
        self.workdir = self.root / "elsewhere"
        self.workdir.mkdir()

    def install(self, *arguments):
        return subprocess.run(
            [COPILOT_CLI, "plugin", "install", *arguments],
            capture_output=True,
            text=True,
            cwd=str(self.workdir),
            env={
                **os.environ,
                "COPILOT_HOME": str(self.home),
                "XDG_CACHE_HOME": str(self.root / "cache"),
            },
            timeout=300,
            stdin=subprocess.DEVNULL,
        )

    def run_locator(self, source: str, plugin_root: str = ""):
        return subprocess.run(
            ["python3", "-", plugin_root, str(self.home)],
            input=source,
            capture_output=True,
            text=True,
            cwd=str(self.workdir),
            timeout=60,
        )

    def unavailable(self, proc):
        """The signal, if the CLI could not attempt the install at all."""
        output = f"{proc.stdout}\n{proc.stderr}".lower()
        return next(
            (signal for signal in UNAVAILABLE_SIGNALS if signal in output), None
        )

    def test_a_repository_direct_install_produces_the_pinned_entry_and_resolves(self):
        proc = self.install("coghex/kanban:google-plugin/plugins/kanban")
        if proc.returncode != 0:
            signal = self.unavailable(proc)
            report = proc.stderr.strip() or proc.stdout.strip()
            if signal is None:
                self.fail(
                    "copilot plugin install failed for a reason that is not the "
                    f"repository being unreachable: {report}"
                )
            self.skipTest(
                f"copilot plugin install could not reach the repository ({signal!r}): "
                f"{report}"
            )
        entries = sorted(
            child.name
            for child in (self.home / "installed-plugins" / "_direct").iterdir()
        )
        self.assertEqual(entries, [DIRECT_ENTRY], entries)
        root = self.home / "installed-plugins" / "_direct" / DIRECT_ENTRY
        for noun, source, relative in BUNDLE_LOCATORS:
            with self.subTest(locator=noun):
                located = self.run_locator(source)
                self.assertEqual(located.returncode, 0, located.stderr)
                self.assertEqual(located.stdout.strip(), str(root / relative))

    def test_a_local_direct_install_produces_a_bare_entry_the_lookup_refuses(self):
        proc = self.install(str(GOOGLE_PLUGIN))
        self.assertEqual(
            proc.returncode,
            0,
            "copilot plugin install rejected the local bundle path: "
            f"{proc.stderr.strip() or proc.stdout.strip()}",
        )
        entries = sorted(
            child.name
            for child in (self.home / "installed-plugins" / "_direct").iterdir()
        )
        self.assertEqual(entries, ["kanban"], entries)
        for noun, source, _relative in BUNDLE_LOCATORS:
            with self.subTest(locator=noun):
                located = self.run_locator(source)
                self.assertNotEqual(located.returncode, 0, located.stdout)
                self.assertIn(f"{noun} was not found:", located.stderr)

    def test_a_local_marketplace_install_records_a_directory_source(self):
        marketplace = subprocess.run(
            [COPILOT_CLI, "plugin", "marketplace", "add", str(GOOGLE_BUNDLE)],
            capture_output=True,
            text=True,
            cwd=str(self.workdir),
            env={
                **os.environ,
                "COPILOT_HOME": str(self.home),
                "XDG_CACHE_HOME": str(self.root / "cache"),
            },
            timeout=300,
            stdin=subprocess.DEVNULL,
        )
        self.assertEqual(
            marketplace.returncode,
            0,
            "copilot plugin marketplace add failed: "
            f"{marketplace.stderr.strip() or marketplace.stdout.strip()}",
        )
        installed = self.install("kanban@kanban-google")
        self.assertEqual(installed.returncode, 0, installed.stderr)
        settings = json.loads(
            (self.home / "settings.json").read_text(encoding="utf-8")
        )
        source = settings["extraKnownMarketplaces"]["kanban-google"]["source"]
        self.assertEqual(source["source"], "directory")
        self.assertEqual(Path(source["path"]), GOOGLE_BUNDLE)
        # Nothing is copied for a directory marketplace, which is why the
        # recorded path is the only thing that resolves this install.
        self.assertFalse((self.home / "installed-plugins").exists())
        for noun, source, relative in BUNDLE_LOCATORS:
            with self.subTest(locator=noun):
                located = self.run_locator(source)
                self.assertEqual(located.returncode, 0, located.stderr)
                self.assertEqual(
                    located.stdout.strip(), str(GOOGLE_PLUGIN / relative)
                )


def load_google_review_pr():
    spec = importlib.util.spec_from_file_location(
        "kanban_google_plugin_review_pr", COORDINATOR
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ExpectedRouteBindingTests(unittest.TestCase):
    def setUp(self):
        self.module = load_google_review_pr()
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
            origin="claude", expected_origin="google", expected_route="codex"
        )
        self.assert_mismatch(code, result, "claude", "codex")
        self.assertIn("no reviewer was spawned", result["error"])

    def test_an_unknown_origin_refuses_before_the_dual_route_can_spawn_claude(self):
        code, result = self.run_workflow(
            origin=None, expected_origin="google", expected_route="codex"
        )
        self.assert_mismatch(code, result, "unknown", "codex+claude")
        self.assertIn("no reviewer was spawned", result["error"])

    def test_a_route_only_drift_refuses_before_spawning_claude(self):
        single = self.module.kanban_models().SINGLE_AGENT_MODE
        with mock.patch.object(
            self.module, "operating_mode", return_value=(single, ("claude",))
        ):
            code, result = self.run_workflow(
                origin="google", expected_origin="google", expected_route="codex"
            )
        self.assert_mismatch(code, result, "google", "claude")
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
                        self.pr("google"),
                        gate,
                        [self.module.CODEX_REVIEWER],
                        [{"verdict": "APPROVE", "summary": "ok", "blocking_concerns": []}],
                        {"pr": 7},
                        allow_no_issue=True,
                        expected_origin="google",
                        expected_route="codex",
                    )
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "route_mismatch")
        self.assertEqual(result["origin"], "unknown")
        self.assertEqual(self.calls, [])

    def test_publication_refuses_a_route_only_drift_before_writing(self):
        google_pr = self.pr("google")
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
        with mock.patch.object(self.module, "pr_view", return_value=google_pr):
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
                            google_pr,
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
                            expected_origin="google",
                            expected_route="codex",
                        )
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "route_mismatch")
        self.assertEqual(result["origin"], "google")
        self.assertEqual(result["route"], "claude")
        self.assertIn("does not match --expected-route", result["error"])
        self.assertEqual(self.calls, [])

    def test_publication_refuses_origin_drift_on_a_later_reread(self):
        google_pr = self.pr("google")
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
            self.module, "pr_view", side_effect=[google_pr, drifted]
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
                            google_pr,
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
                            expected_origin="google",
                            expected_route="codex",
                        )
        self.assertIn("does not match --expected-origin", str(raised.exception))
        self.assertEqual(self.calls, [])

    def test_a_matching_google_codex_binding_is_not_a_mismatch(self):
        with mock.patch.object(self.module, "pr_view", return_value=self.pr("google")):
            with mock.patch.object(self.module, "collect_context") as collect:
                collect.side_effect = RuntimeError("stop after the binding check")
                with self.assertRaises(RuntimeError):
                    self.module.workflow(
                        Path("/fake-repo"),
                        7,
                        rereview=False,
                        dry_run=False,
                        allow_no_issue=True,
                        expected_origin="google",
                        expected_route="codex",
                    )
                collect.assert_called()

    def test_pr_origin_keeps_cross_repository_external_markers(self):
        self.assertEqual(
            self.module.pr_origin(self.pr("google", cross_repository=True)),
            "google",
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
            self.module.pr_origin(self.pr("kimi", cross_repository=True)),
            "kimi",
        )
        self.assertEqual(
            self.module.pr_origin(self.pr("google", cross_repository=False)),
            "google",
        )

    def test_a_cross_repository_google_origin_still_routes_to_codex(self):
        with mock.patch.object(
            self.module,
            "pr_view",
            return_value=self.pr("google", cross_repository=True),
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
                        expected_origin="google",
                        expected_route="codex",
                    )
                collect.assert_called()
                self.assertEqual(self.calls, [])

    def test_a_cross_repository_non_google_marker_stays_unknown(self):
        code, result = self.run_workflow_cross(
            origin="claude", expected_origin="google", expected_route="codex"
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


BUNDLE_PREFIX = "google-plugin"
ORIGINAL_BUNDLE_VERSION = "1.0.0"
BUNDLE_README_PATH = "google-plugin/README.md"


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
                    "name": "kanban-google",
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
        self.marketplace.write_text(
            json.dumps(
                {
                    "name": "kanban-google",
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
                    "name": "kanban-google",
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
