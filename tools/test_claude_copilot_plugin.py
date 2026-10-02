"""Structural coverage for the tracked Claude-on-Copilot plugin.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

Issue #722. A bundle's brand is the model its session runs, not the executable
hosting it (D-0 of `docs/coordination/external_workflow_authoring_design.md`),
so a Copilot CLI session running a Claude model is a Claude participant -- and
until this bundle it had none of its own to load, only the Kimi and Google
ones, whose skills stamp another brand's origin. This bundle packages /solve
and /autosolve for that session: it opens a claude-origin pull request and
obtains a Codex review without spawning another Claude session.

These tests mirror tools/test_kimi_plugin.py: they pin the brand, the origin
marker, the marketplace name, the plugin-root variable, the forbidden
frontmatter keys, the vendored helpers and their discovery from an unrelated
worked repository, the self-review prohibition, and the terminal wording. What
differs from the Kimi bundle is pinned too: the Claude session is not told to
refuse its own brand, and a fork pull request -- where every bundled
coordinator reads a claude marker as an unknown origin -- stops the autosolve
run instead of reaching the dual route.
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
CLAUDE_COPILOT_PLUGIN = REPO_ROOT / "claude-copilot-plugin" / "plugins" / "kanban"
CLAUDE_PLUGIN = REPO_ROOT / "claude-plugin" / "plugins" / "kanban"
GROK_COORDINATOR = (
    REPO_ROOT / "grok-plugin" / "plugins" / "kanban" / "scripts" / "review_pr.py"
)
SOLVE = CLAUDE_COPILOT_PLUGIN / "skills" / "solve" / "SKILL.md"
AUTOSOLVE = CLAUDE_COPILOT_PLUGIN / "skills" / "autosolve" / "SKILL.md"
TRUSTED_SPEC = CLAUDE_COPILOT_PLUGIN / "skills" / "solve" / "scripts" / "trusted_issue_spec.py"
COORDINATOR = CLAUDE_COPILOT_PLUGIN / "scripts" / "review_pr.py"
MODELS = CLAUDE_COPILOT_PLUGIN / "scripts" / "kanban_models.py"
PLUGIN_JSON = CLAUDE_COPILOT_PLUGIN / "plugin.json"
MARKETPLACE = REPO_ROOT / "claude-copilot-plugin" / ".github" / "plugin" / "marketplace.json"
README = REPO_ROOT / "claude-copilot-plugin" / "README.md"
PLUGIN_MANIFEST_PATH = "claude-copilot-plugin/plugins/kanban/plugin.json"
MARKETPLACE_MANIFEST_PATH = "claude-copilot-plugin/.github/plugin/marketplace.json"
SKILLS_PREFIX = "claude-copilot-plugin/plugins/kanban/skills"
COMMAND_SIGIL = "/"
EXPECTED_SKILL_NAMES = {"solve", "autosolve"}
EXPECTED_BUNDLE_FILES = {
    "claude-copilot-plugin/.github/plugin/marketplace.json",
    "claude-copilot-plugin/README.md",
    "claude-copilot-plugin/plugins/kanban/plugin.json",
    "claude-copilot-plugin/plugins/kanban/scripts/kanban_models.py",
    "claude-copilot-plugin/plugins/kanban/scripts/review_pr.py",
    "claude-copilot-plugin/plugins/kanban/skills/autosolve/SKILL.md",
    "claude-copilot-plugin/plugins/kanban/skills/solve/SKILL.md",
    "claude-copilot-plugin/plugins/kanban/skills/solve/scripts/trusted_issue_spec.py",
}

CLAUDE_ORIGIN = "<!-- pr-origin:claude -->"
OTHER_ORIGINS = (
    "<!-- pr-origin:codex -->",
    "<!-- pr-origin:grok -->",
    "<!-- pr-origin:kimi -->",
    "<!-- pr-origin:google -->",
)

# Keys that would override the model, effort, or permission mode a session was
# launched with -- the same set tools/test_claude_plugin.py forbids in Claude
# Code's bundle, and the renderer refuses before a file is written.
FORBIDDEN_FRONTMATTER_KEYS = (
    "model",
    "effort",
    "reasoning-effort",
    "permission-mode",
    "allowed-tools",
)

COORDINATOR_LOOKUP = 'Path("scripts") / "review_pr.py"'

# The exact Python locator /autosolve's coordinator fence runs. Asserted to
# appear in the skill AND executed against a simulated install below, so a
# rewrite that keeps the prose and breaks the resolution fails here.
CLAUDE_COPILOT_COORDINATOR_PYTHON = '''import json, os, sys
from pathlib import Path

plugin_root, copilot_home = sys.argv[1], sys.argv[2]
relative = Path("scripts") / "review_pr.py"
marketplace, plugin, bundle = "kanban-claude", "kanban", "claude-copilot-plugin-plugins-kanban"
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
    raise SystemExit(f"coordinator was not found: $CLAUDE_COPILOT_PLUGIN_ROOT is unset, the {marketplace} marketplace has no recorded local path, and neither {from_marketplace} nor {direct}/<owner>--<repo>--{bundle} exists")
if len(roots) != 1:
    raise SystemExit("ambiguous Kanban installs: " + ", ".join(str(root) for root in roots))
finish(roots[0] / relative)
'''

# The entry name `copilot plugin install coghex/kanban:claude-copilot-plugin/plugins/kanban`
# writes under `$COPILOT_HOME/installed-plugins/_direct/`: <owner>--<repo>--<bundle
# path>, the path's separators flattened -- the rule tools/test_kimi_plugin.py
# and tools/test_google_plugin.py pin against the real CLI for their bundles,
# and RealCopilotInstallTests below re-pins for this one once it is published
# on the default branch the CLI installs from.
DIRECT_ENTRY = "coghex--kanban--claude-copilot-plugin-plugins-kanban"
CLAUDE_COPILOT_BUNDLE = REPO_ROOT / "claude-copilot-plugin"
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
            ["git", "ls-files", "-z", "--", "claude-copilot-plugin"],
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
        self.assertEqual(document["name"], "kanban-claude")
        names = [plugin["name"] for plugin in document["plugins"]]
        self.assertEqual(names, ["kanban"])
        self.assertEqual(document["plugins"][0]["source"], "./plugins/kanban")

    def test_the_plugin_manifest_declares_version_1_0_0(self):
        document = json.loads(PLUGIN_JSON.read_text(encoding="utf-8"))
        self.assertEqual(document["name"], "kanban")
        self.assertEqual(document["version"], "1.0.1")

    def test_solve_and_autosolve_skills_exist(self):
        self.assertTrue(SOLVE.is_file())
        self.assertTrue(AUTOSOLVE.is_file())
        for path, name in ((SOLVE, "solve"), (AUTOSOLVE, "autosolve")):
            text = path.read_text(encoding="utf-8")
            self.assertIn(f"name: {name}", text)
            self.assertIn("description:", text)

    def test_the_skills_declare_only_name_and_description(self):
        # The Copilot loader reads `name` and `description`; any key that
        # would override the launched model, effort, or permission mode is
        # forbidden outright, and so is Claude Code's `argument-hint`, which
        # names a substitution Copilot does not perform.
        for path in (SOLVE, AUTOSOLVE):
            text = path.read_text(encoding="utf-8")
            match = re.match(r"\A---\n(?P<front>.*?)\n---\n", text, re.DOTALL)
            self.assertIsNotNone(match, path)
            keys = [line.split(":", 1)[0] for line in match.group("front").splitlines()]
            with self.subTest(skill=path.parent.name):
                self.assertEqual(keys, ["name", "description"])
                for key in FORBIDDEN_FRONTMATTER_KEYS:
                    self.assertNotIn(key, keys)

    def test_the_forbidden_key_rule_detects_a_planted_key(self):
        # The control for the assertion above.
        planted = SOLVE.read_text(encoding="utf-8").replace(
            "name: solve\n", "name: solve\nmodel: claude-opus-5.5\n", 1
        )
        match = re.match(r"\A---\n(?P<front>.*?)\n---\n", planted, re.DOTALL)
        keys = [line.split(":", 1)[0] for line in match.group("front").splitlines()]
        self.assertIn("model", keys)


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
        self.squashed = re.sub(r"\s+", " ", self.text)

    def test_readme_states_the_tested_launch(self):
        # Requirement 4: the launch line the issue records as executed.
        self.assertIn("GitHub Copilot CLI 1.0.88", self.text)
        self.assertIn(
            "COPILOT_HOME=$HOME/.copilot-claude \\\n"
            "  CLAUDE_COPILOT_PLUGIN_ROOT=$PWD/claude-copilot-plugin/plugins/kanban \\\n"
            "  copilot --model claude-opus-5.5 --plugin-dir claude-copilot-plugin/plugins/kanban",
            self.text,
        )
        self.assertIn('plugin marketplace add "$PWD/claude-copilot-plugin"', self.text)
        self.assertIn("plugin install kanban@kanban-claude", self.text)
        self.assertIn("extraKnownMarketplaces.kanban-claude.source.path", self.text)

    def test_readme_repeats_d0_for_this_brand(self):
        # Requirement 4: the brand is the model, not the host, so this session
        # stamps claude on what it opens and on what it newly authors.
        self.assertIn(
            "A bundle's brand is the model the session runs, not the executable "
            "hosting it",
            self.squashed,
        )
        self.assertIn("`<!-- pr-origin:claude -->`", self.text)
        self.assertIn("`issue-origin:claude`", self.text)
        self.assertIn("must not load the Kimi or Google bundle", self.squashed)
        self.assertIn("not a sixth origin", self.squashed)

    def test_readme_decides_the_naming_question(self):
        # Requirement 2: shadowing is decided, not left open, and the decision
        # names what is and is not distinct.
        self.assertIn("first-found-wins", self.text)
        self.assertIn("shadow", self.text)
        self.assertIn(
            "the operator enables exactly one Copilot Kanban bundle at a time",
            self.squashed,
        )
        self.assertIn("dedicated `COPILOT_HOME`", self.squashed)
        self.assertIn("marketplace, `kanban-claude`", self.squashed)
        self.assertIn("`$CLAUDE_COPILOT_PLUGIN_ROOT`", self.text)

    def test_readme_states_the_observed_install_contract(self):
        self.assertIn(
            "copilot plugin install coghex/kanban:claude-copilot-plugin/plugins/kanban",
            self.text,
        )
        self.assertIn(
            "installed-plugins/_direct/coghex--kanban--claude-copilot-plugin-plugins-kanban/",
            self.text,
        )
        self.assertIn("installed-plugins/kanban-claude/kanban/", self.text)
        self.assertIn("*remote* marketplace\nregistration of it is not available", self.text)
        self.assertIn("`cache_path`", self.text)
        self.assertNotIn("installed-plugins/kanban-*", self.text)

    def test_readme_explains_argument_behavior(self):
        self.assertIn("do not substitute a `$ARGUMENTS` variable", self.text)
        self.assertIn("/solve 652", self.text)

    def test_readme_states_the_review_safety_boundary(self):
        self.assertIn("without**\n`--self-review`", self.text)
        self.assertIn("route other than `codex` is a stop", self.text)
        self.assertIn("A fork pull request is the one case that stops", self.squashed)


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
    def test_solve_stamps_claude_origin_and_not_the_other_brands(self):
        text = SOLVE.read_text(encoding="utf-8")
        self.assertIn(CLAUDE_ORIGIN, text)
        for origin in OTHER_ORIGINS:
            self.assertNotIn(origin, text)
        self.assertIn(
            "Never stamp a Codex, Grok, Kimi, or Google origin marker from this session",
            text,
        )
        # Copilot skills receive no substituted arguments; the skill must say
        # so rather than read a $ARGUMENTS nothing sets.
        self.assertNotIn("$ARGUMENTS", text)
        self.assertIn("no substituted arguments", text)

    def test_solve_names_the_brand_and_its_sibling_refusals(self):
        # Requirement 5 and the review's correction: every other brand is a
        # sibling to refuse, Claude Code's bundle is refused as another host,
        # and nothing tells this Claude session to refuse Claude.
        text = SOLVE.read_text(encoding="utf-8")
        self.assertIn("This is the Claude brand on the Copilot CLI", text)
        self.assertIn("never follow a Codex, Grok, Kimi, or Google solve skill", text)
        self.assertIn("never follow Claude Code's solve command, which is packaged for a different host", text)
        self.assertNotIn("never follow a Claude", text)
        self.assertIn('bundle = "claude"', text)

    def test_solve_forbids_reviewing_the_pull_request(self):
        text = SOLVE.read_text(encoding="utf-8")
        self.assertIn("Do not review, label, merge, or finalize the PR", text)
        self.assertIn(
            "reviewed by Codex, never by this session and never by any other Claude session",
            text,
        )
        squashed = re.sub(r"\s+", " ", text)
        self.assertIn(
            "the review is Codex's to perform, never this session's or another "
            "Claude session's",
            squashed,
        )
        self.assertNotIn("never Claude's", squashed)


class AutosolveReviewerTests(unittest.TestCase):
    def test_autosolve_requires_claude_origin_and_codex_route(self):
        text = AUTOSOLVE.read_text(encoding="utf-8")
        self.assertIn(CLAUDE_ORIGIN, text)
        self.assertIn('"origin": "claude"', text)
        self.assertIn('"route": "codex"', text)
        self.assertIn("reviewers=codex", text)
        self.assertNotIn('"$ARGUMENTS"', text)
        self.assertIn("--expected-origin claude", text)
        self.assertIn("--expected-route codex", text)
        for origin in OTHER_ORIGINS:
            self.assertNotIn(origin, text)
        self.assertIn("does not package /push-docs", text)
        self.assertNotIn("land it\n  with /push-docs", text)
        self.assertIn("Do\n  not reclaim the issue", text)

    def test_autosolve_never_spawns_another_claude_session(self):
        text = AUTOSOLVE.read_text(encoding="utf-8")
        self.assertIn("It must never spawn or invoke another Claude session", text)
        self.assertIn("Do not spawn another\nClaude session for any step of this loop.", text)
        self.assertIn("continuing would spawn\na Claude reviewer on a Claude-origin pull request", text)
        self.assertIn("do not start another Claude session to revise.", text)
        self.assertIn(
            "This session's own brand is `claude`, so a marker reading `reviewers=claude`",
            text,
        )
        self.assertNotIn("obtain a fresh **Claude** review", text)

    def test_autosolve_carries_no_identity_text_a_claude_session_contradicts(self):
        # The review's correction: adapt the Kimi safety guarantees without
        # retaining the Kimi identity text.
        text = AUTOSOLVE.read_text(encoding="utf-8")
        for phrase in (
            "never invoke Claude.",
            "spawn, invoke, or impersonate Claude",
            "Do not invoke Claude",
            "do not invoke Claude",
            "continuing would invoke Claude",
            "do not ask Claude to revise",
            "Claude revises in this same session",
        ):
            self.assertNotIn(phrase, text)

    def test_autosolve_omits_self_review_from_every_executable_fence(self):
        text = AUTOSOLVE.read_text(encoding="utf-8")
        self.assertIn("Never pass `--self-review`", text)
        for fence in BASH_FENCE_RE.finditer(text):
            body = fence.group("body")
            self.assertNotIn("--self-review", body, body)

    def test_autosolve_stops_on_a_fork_pull_request_before_any_review(self):
        # The review's addition: a claude marker on a fork pull request reads
        # as unknown to every bundled coordinator, so the run must stop there
        # rather than inherit the Kimi promise that its marker survives.
        text = AUTOSOLVE.read_text(encoding="utf-8")
        squashed = re.sub(r"\s+", " ", text)
        fence = 'gh pr view "$PR" -R "$REPO" --json body,isCrossRepository'
        self.assertIn(fence, text)
        self.assertNotIn("the bundled coordinator reads that marker even when GitHub reports", text)
        self.assertIn(
            "The bundled coordinator keeps only a grok, kimi, or google marker when "
            "GitHub reports `isCrossRepository`",
            squashed,
        )
        self.assertIn("do not run step 5", squashed)
        self.assertLess(text.index(fence), text.index("## 5. The review loop"))
        self.assertIn(
            "PR #<pr> is a fork pull request whose claude origin this bundle cannot "
            "route to Codex — needs your input.",
            squashed,
        )

    def test_autosolve_locates_this_bundle_coordinator(self):
        text = AUTOSOLVE.read_text(encoding="utf-8")
        self.assertIn(COORDINATOR_LOOKUP, text)
        self.assertIn('python3 "$COORDINATOR"', text)
        self.assertNotIn("$CODEX_HOME", text)
        self.assertNotIn("$GROK_HOME", text)
        self.assertIn(
            "Never fall back to\nClaude Code's plugin path, a Codex, Grok, Kimi, or Google plugin path",
            text,
        )
        # Claude Code's own variable is named only in that refusal; no
        # executable fence reads it.
        for fence in BASH_FENCE_RE.finditer(text):
            self.assertIsNone(
                re.search(r"\bCLAUDE_PLUGIN_ROOT\b", fence.group("body")), fence.group("body")
            )
        self.assertNotIn("installed-plugins/kanban-<hash>", text)
        self.assertNotIn("kanban-*", text)
        self.assertIn("$CLAUDE_COPILOT_PLUGIN_ROOT", text)
        self.assertIn("ambiguous Kanban installs", text)
        self.assertIn("`kanban-claude/kanban/`", text)
        self.assertIn("`_direct/<owner>--<repo>--claude-copilot-plugin-plugins-kanban/`", text)
        self.assertIn('installed / marketplace / plugin', text)
        self.assertIn('installed / "_direct"', text)
        self.assertIn(CLAUDE_COPILOT_COORDINATOR_PYTHON, text)


class AutosolveTerminalBehaviorTests(unittest.TestCase):
    """Issue #699. This bundle ships exactly `solve` and `autosolve`, so
    `/finalize` is not a workflow this bundle's session can run -- and the
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


def locator_fence(skill: Path, variable: str) -> str:
    """The shell that assigns `variable` in `skill`, exactly as shipped, up to
    the `)"` closing its command substitution -- so running it exercises the
    `${CLAUDE_COPILOT_PLUGIN_ROOT:-}` and `${COPILOT_HOME:-...}` expansions
    along with the Python, and never the helper or coordinator it locates."""
    text = skill.read_text(encoding="utf-8")
    opening = f'{variable}="$(python3 - '
    fences = [f.group("body") for f in BASH_FENCE_RE.finditer(text) if opening in f.group("body")]
    assert len(fences) == 1, f"{skill} carries {len(fences)} {variable} locators"
    body = fences[0]
    return body[: body.index('\n)"') + 3]


class LocatorMatrix:
    """Both locators this bundle ships, run through one matrix.

    The autosolve coordinator locator is the same fail-closed Python as
    /solve's helper lookup, with a different relative path. String search
    cannot prove either prefers $CLAUDE_COPILOT_PLUGIN_ROOT, reads the recorded
    local marketplace path, resolves the two copied layouts the Copilot CLI
    really creates, or refuses an ambiguous or wrong-brand candidate -- these
    run the fenced locator itself, from a working directory that is an
    unrelated worked repository rather than this checkout.
    """

    NOUN: str
    SOURCE: str
    RELATIVE: Path
    SKILL: Path
    VARIABLE: str

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.workdir = self.root / "worked-repo"
        self.workdir.mkdir()

    def plant(self, root: Path) -> Path:
        target = root / self.RELATIVE
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(f"print({self.NOUN!r})\n", encoding="utf-8")
        return target

    def install_direct(self, home: Path, name: str = DIRECT_ENTRY) -> Path:
        """The direct-install layout, under the entry name the CLI produces.

        `DIRECT_ENTRY` is not invented here: it is what
        `copilot plugin install coghex/kanban:claude-copilot-plugin/plugins/kanban`
        writes, pinned against the real CLI by `RealCopilotInstallTests`
        below so these CLI-independent cases cannot drift onto a name no
        install produces.
        """
        return self.plant(
            home / ".copilot" / "installed-plugins" / "_direct" / name
        )

    def install_marketplace_layout(
        self, home: Path, marketplace: str = "kanban-claude", plugin: str = "kanban"
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
                    "kanban-claude": {
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
            input=self.SOURCE,
            capture_output=True,
            text=True,
            cwd=str(self.workdir),
            timeout=60,
        )

    def run_fence(self, environment: dict[str, str]):
        """The shipped shell fence, under exactly `environment` plus a PATH."""
        script = locator_fence(self.SKILL, self.VARIABLE) + f'\nprintf %s "${self.VARIABLE}"\n'
        return subprocess.run(
            ["bash", "-c", script],
            capture_output=True,
            text=True,
            cwd=str(self.workdir),
            env={"PATH": os.environ.get("PATH", ""), **environment},
            timeout=60,
        )

    def test_the_skill_declares_the_lookup_it_is_tested_with(self):
        self.assertIn(
            self.SOURCE,
            self.SKILL.read_text(encoding="utf-8"),
            f"{self.SKILL} must prefer $CLAUDE_COPILOT_PLUGIN_ROOT, then the "
            "recorded local marketplace path, then the copied install layouts",
        )
        self.assertIn(self.SOURCE, locator_fence(self.SKILL, self.VARIABLE))

    def test_the_fence_resolves_this_bundle_through_the_launch_variable(self):
        # The README's --plugin-dir launch exports the variable; the fence
        # must resolve the tracked file through it from an unrelated worked
        # repository, with an empty Copilot home beside it.
        proc = self.run_fence(
            {
                "HOME": str(self.root / "home"),
                "COPILOT_HOME": str(self.root / "empty-copilot"),
                "CLAUDE_COPILOT_PLUGIN_ROOT": str(CLAUDE_COPILOT_PLUGIN),
            }
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, str(CLAUDE_COPILOT_PLUGIN / self.RELATIVE))
        self.assertTrue((CLAUDE_COPILOT_PLUGIN / self.RELATIVE).is_file())

    def test_the_fence_never_adopts_claude_codes_plugin_root(self):
        # A Copilot session launched from inside Claude Code inherits Claude
        # Code's variable. It names another host's bundle, and the fence must
        # not read it: with nothing else installed, discovery refuses.
        proc = self.run_fence(
            {
                "HOME": str(self.root / "home"),
                "COPILOT_HOME": str(self.root / "empty-copilot"),
                "CLAUDE_PLUGIN_ROOT": str(CLAUDE_PLUGIN),
            }
        )
        self.assertEqual(proc.stdout, "")
        self.assertIn(f"{self.NOUN} was not found:", proc.stderr)
        self.assertIn("$CLAUDE_COPILOT_PLUGIN_ROOT is unset", proc.stderr)

    def test_claude_code_and_the_sibling_copilot_bundles_are_not_adopted(self):
        # Refusal to adopt another bundle: Claude Code's marketplace installed
        # into Copilot, and the Kimi and Google bundles, in both copied
        # layouts, all beside an empty home for this one.
        home = self.root / "copilot-other-bundles"
        for bundle in ("claude-plugin", "kimi-plugin", "google-plugin"):
            self.install_direct(home, f"coghex--kanban--{bundle}-plugins-kanban")
        for marketplace in ("kanban", "kanban-kimi", "kanban-google"):
            self.install_marketplace_layout(home, marketplace=marketplace)
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn(f"{self.NOUN} was not found:", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_a_home_holding_every_bundle_resolves_this_one_alone(self):
        home = self.root / "copilot-every-bundle"
        expected = self.install_direct(home)
        for bundle in ("claude-plugin", "kimi-plugin", "google-plugin"):
            self.install_direct(home, f"coghex--kanban--{bundle}-plugins-kanban")
        for marketplace in ("kanban", "kanban-kimi", "kanban-google"):
            self.install_marketplace_layout(home, marketplace=marketplace)
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

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
                            "kanban-claude": {"source": {"source": kind, **record}}
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
                    {"extraKnownMarketplaces": {"kanban-claude": {"source": record}}},
                )
                proc = self.run_locator("", str(home / ".copilot"))
                self.assertNotEqual(proc.returncode, 0, proc.stdout)
                self.assertIn(
                    f"for the {record['source']} kanban-claude source", proc.stderr
                )
                self.assertEqual(proc.stdout.strip(), "")

    def test_an_unsupported_marketplace_source_kind_refuses_without_fallback(self):
        home = self.root / "copilot-unsupported-source"
        self.install_direct(home)
        self.write_settings(
            home,
            {
                "extraKnownMarketplaces": {
                    "kanban-claude": {"source": {"source": "carrier-pigeon"}}
                }
            },
        )
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("unsupported kanban-claude source kind", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_settings_without_a_kanban_claude_entry_fall_through_to_the_copied_layouts(self):
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
                {"extraKnownMarketplaces": {"kanban-claude": []}}
            ),
            "source-not-object": json.dumps(
                {"extraKnownMarketplaces": {"kanban-claude": {"source": "directory"}}}
            ),
            "relative-path": json.dumps(
                {
                    "extraKnownMarketplaces": {
                        "kanban-claude": {
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
        self.assertIn(f"{self.NOUN} was not found at", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_the_lookup_uses_plugin_root_for_a_marketplace_source_outside_home(self):
        home = self.root / "copilot-empty-home"
        home.mkdir()
        expected = self.install_marketplace_source(self.root)
        plugin_root = expected.parents[len(self.RELATIVE.parts) - 1]  # .../plugins/kanban
        proc = self.run_locator(str(plugin_root), str(home / ".copilot"))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), str(expected), proc.stderr)

    def test_plugin_root_wins_over_both_copied_layouts(self):
        home = self.root / "copilot-both"
        self.install_direct(home)
        self.install_marketplace_layout(home)
        expected = self.install_marketplace_source(self.root)
        plugin_root = expected.parents[len(self.RELATIVE.parts) - 1]
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
        self.install_direct(home, "someone--fork--claude-copilot-plugin-plugins-kanban")
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
        self.assertIn(f"{self.NOUN} was not found at", proc.stderr)
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
        self.install_direct(home, "coghex--kanban--google-plugin-plugins-kanban")
        self.install_marketplace_layout(home, marketplace="kanban-google")
        proc = self.run_locator("", str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn(f"{self.NOUN} was not found:", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_a_mixed_brand_home_resolves_this_bundle_alone(self):
        home = self.root / "copilot-mixed-brand"
        expected = self.install_direct(home)
        self.install_direct(
            home, "coghex--kanban--google-plugin-plugins-kanban"
        )
        self.install_marketplace_layout(home, marketplace="kanban-google")
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
        self.assertIn(f"{self.NOUN} was not found:", proc.stderr)
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
        self.assertIn(f"{self.NOUN} was not found:", proc.stderr)
        self.assertIn("$CLAUDE_COPILOT_PLUGIN_ROOT is unset", proc.stderr)
        self.assertNotIn("installed-plugins/kanban-*", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")

    def test_plugin_root_fails_closed_when_the_relative_path_is_missing(self):
        home = self.root / "copilot-missing"
        home.mkdir()
        plugin_root = self.root / "marketplace" / "plugins" / "kanban"
        plugin_root.mkdir(parents=True)
        proc = self.run_locator(str(plugin_root), str(home / ".copilot"))
        self.assertNotEqual(proc.returncode, 0, proc.stdout)
        self.assertIn(f"{self.NOUN} was not found at", proc.stderr)
        self.assertEqual(proc.stdout.strip(), "")


class AutosolveCoordinatorLookupTests(LocatorMatrix, unittest.TestCase):
    NOUN = "coordinator"
    SOURCE = CLAUDE_COPILOT_COORDINATOR_PYTHON
    RELATIVE = Path("scripts") / "review_pr.py"
    SKILL = AUTOSOLVE
    VARIABLE = "COORDINATOR"


class SolveTrustedHelperLookupTests(LocatorMatrix, unittest.TestCase):
    NOUN = "trusted helper"
    SOURCE = test_trusted_issue_spec.CLAUDE_COPILOT_HELPER_PYTHON
    RELATIVE = Path("skills") / "solve" / "scripts" / "trusted_issue_spec.py"
    SKILL = SOLVE
    VARIABLE = "TRUSTED_SPEC"


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
    ("coordinator", CLAUDE_COPILOT_COORDINATOR_PYTHON, Path("scripts") / "review_pr.py"),
    (
        "trusted helper",
        test_trusted_issue_spec.CLAUDE_COPILOT_HELPER_PYTHON,
        Path("skills") / "solve" / "scripts" / "trusted_issue_spec.py",
    ),
)

class RealCopilotInstallTests(unittest.TestCase):
    """Produce the copied install with the real CLI, never by hand.

    Verified with GitHub Copilot CLI 1.0.88. These skip explicitly when the
    CLI is absent, which is how CI runs them; what they exist for is to pin
    the entry names `LocatorMatrix` builds its CLI-independent fixtures from,
    so a passing suite can never assert discovery against a directory no
    install produces.

    Once the CLI is present, a failing install is a failure, not a skip: a
    rejected bundle path or a changed install contract is exactly what these
    exist to catch. The exception is the repository install, which installs
    from the repository's default branch over the network with a credential.
    It skips while that branch does not carry this bundle yet -- the state of
    the pull request that adds it -- and otherwise only when the CLI's own
    output carries one of `UNAVAILABLE_SIGNALS`, failing on anything else.

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
        published = subprocess.run(
            [
                "git",
                "cat-file",
                "-e",
                "refs/remotes/origin/master:claude-copilot-plugin/plugins/kanban/plugin.json",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
        )
        if published.returncode != 0:
            self.skipTest(
                "the default branch does not carry claude-copilot-plugin/ yet, so "
                "a repository install has nothing to fetch"
            )
        proc = self.install("coghex/kanban:claude-copilot-plugin/plugins/kanban")
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
        proc = self.install(str(CLAUDE_COPILOT_PLUGIN))
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
            [COPILOT_CLI, "plugin", "marketplace", "add", str(CLAUDE_COPILOT_BUNDLE)],
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
        installed = self.install("kanban@kanban-claude")
        self.assertEqual(installed.returncode, 0, installed.stderr)
        settings = json.loads(
            (self.home / "settings.json").read_text(encoding="utf-8")
        )
        source = settings["extraKnownMarketplaces"]["kanban-claude"]["source"]
        self.assertEqual(source["source"], "directory")
        self.assertEqual(Path(source["path"]), CLAUDE_COPILOT_BUNDLE)
        # Nothing is copied for a directory marketplace, which is why the
        # recorded path is the only thing that resolves this install.
        self.assertFalse((self.home / "installed-plugins").exists())
        for noun, source, relative in BUNDLE_LOCATORS:
            with self.subTest(locator=noun):
                located = self.run_locator(source)
                self.assertEqual(located.returncode, 0, located.stderr)
                self.assertEqual(
                    located.stdout.strip(), str(CLAUDE_COPILOT_PLUGIN / relative)
                )


def load_claude_copilot_review_pr():
    spec = importlib.util.spec_from_file_location(
        "kanban_claude_copilot_plugin_review_pr", COORDINATOR
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
        self.module = load_claude_copilot_review_pr()
        # No owner directive is in force on these fixtures' pull requests;
        # the lookup reads GitHub, which nothing here may reach.
        directives = mock.patch.object(
            self.module, "owner_directive_state", return_value={"directives": [], "carried": [], "carried_from": None, "supplied": None}
        )
        directives.start()
        self.addCleanup(directives.stop)
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
            origin="kimi", expected_origin="claude", expected_route="codex"
        )
        self.assert_mismatch(code, result, "kimi", "codex")
        self.assertIn("no reviewer was spawned", result["error"])

    def test_an_unknown_origin_refuses_before_the_dual_route_can_spawn_claude(self):
        code, result = self.run_workflow(
            origin=None, expected_origin="claude", expected_route="codex"
        )
        self.assert_mismatch(code, result, "unknown", "codex+claude")
        self.assertIn("no reviewer was spawned", result["error"])

    def test_a_route_only_drift_refuses_before_spawning_claude(self):
        single = self.module.kanban_models().SINGLE_AGENT_MODE
        with mock.patch.object(
            self.module, "operating_mode", return_value=(single, ("claude",))
        ):
            code, result = self.run_workflow(
                origin="claude", expected_origin="claude", expected_route="codex"
            )
        self.assert_mismatch(code, result, "claude", "claude")
        self.assertIn("does not match --expected-route", result["error"])
        self.assertIn("no reviewer was spawned", result["error"])

    def gate_result(self):
        return {
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

    def publish(self, pr, results):
        return self.module.publish_results(
            Path("/fake-repo"),
            "coghex/kanban",
            7,
            pr,
            self.gate_result(),
            [self.module.CODEX_REVIEWER],
            results,
            {"pr": 7},
            allow_no_issue=True,
            expected_origin="claude",
            expected_route="codex",
        )

    def test_publication_refuses_if_origin_drifts_after_review(self):
        with mock.patch.object(self.module, "pr_view", return_value=self.pr(None)):
            with mock.patch.object(self.module, "gate_status", return_value=self.gate_result()):
                with mock.patch.object(
                    self.module, "resolve_workflow_labels", return_value=("a", "c")
                ):
                    code, result = self.publish(
                        self.pr("claude"),
                        [{"verdict": "APPROVE", "summary": "ok", "blocking_concerns": []}],
                    )
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "route_mismatch")
        self.assertEqual(result["origin"], "unknown")
        self.assertEqual(self.calls, [])

    def test_publication_refuses_a_route_only_drift_before_writing(self):
        claude_pr = self.pr("claude")
        single = self.module.kanban_models().SINGLE_AGENT_MODE
        with mock.patch.object(self.module, "pr_view", return_value=claude_pr):
            with mock.patch.object(
                self.module, "operating_mode", return_value=(single, ("claude",))
            ):
                with mock.patch.object(self.module, "gate_status", return_value=self.gate_result()):
                    with mock.patch.object(
                        self.module, "resolve_workflow_labels", return_value=("a", "c")
                    ):
                        code, result = self.publish(
                            claude_pr,
                            [{"verdict": "APPROVE", "summary": "ok", "blocking_concerns": []}],
                        )
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "route_mismatch")
        self.assertEqual(result["origin"], "claude")
        self.assertEqual(result["route"], "claude")
        self.assertIn("does not match --expected-route", result["error"])
        self.assertEqual(self.calls, [])

    def test_publication_refuses_origin_drift_on_a_later_reread(self):
        claude_pr = self.pr("claude")
        with mock.patch.object(
            self.module, "pr_view", side_effect=[claude_pr, self.pr(None)]
        ):
            with mock.patch.object(self.module, "gate_status", return_value=self.gate_result()):
                with mock.patch.object(
                    self.module, "resolve_workflow_labels", return_value=("a", "c")
                ):
                    with self.assertRaises(self.module.WorkflowError) as raised:
                        self.publish(
                            claude_pr,
                            [
                                {
                                    "display_name": "Codex",
                                    "reviewer": "codex",
                                    "verdict": "APPROVE",
                                    "summary": "ok",
                                    "blocking_concerns": [],
                                }
                            ],
                        )
        self.assertIn("does not match --expected-origin", str(raised.exception))
        self.assertEqual(self.calls, [])

    def test_a_matching_claude_codex_binding_is_not_a_mismatch(self):
        with mock.patch.object(self.module, "pr_view", return_value=self.pr("claude")):
            with mock.patch.object(self.module, "collect_context") as collect:
                collect.side_effect = RuntimeError("stop after the binding check")
                with self.assertRaises(RuntimeError):
                    self.module.workflow(
                        Path("/fake-repo"),
                        7,
                        rereview=False,
                        dry_run=False,
                        allow_no_issue=True,
                        expected_origin="claude",
                        expected_route="codex",
                    )
                collect.assert_called()

    def test_pr_origin_drops_a_claude_marker_on_a_fork_and_keeps_the_external_ones(self):
        # The coordinator this bundle vendors is byte-identical to Grok's, and
        # keeps only grok, kimi, and google on a fork; this bundle's own marker
        # is the one that does not survive there.
        self.assertIsNone(
            self.module.pr_origin(self.pr("claude", cross_repository=True))
        )
        self.assertEqual(
            self.module.pr_origin(self.pr("claude", cross_repository=False)),
            "claude",
        )
        for external in ("grok", "kimi", "google"):
            self.assertEqual(
                self.module.pr_origin(self.pr(external, cross_repository=True)),
                external,
            )
        self.assertIsNone(
            self.module.pr_origin(self.pr("codex", cross_repository=True))
        )

    def test_a_fork_claude_pull_request_is_refused_before_any_spawn(self):
        # What the autosolve's step 4 stop exists for, proved at the
        # coordinator: were a fork pull request to reach the real round, the
        # expected-origin binding would still refuse it before a reviewer is
        # spawned, because its claude marker reads as unknown on the dual route.
        code, result = self.run_workflow_cross(
            origin="claude", expected_origin="claude", expected_route="codex"
        )
        self.assert_mismatch(code, result, "unknown", "codex+claude")
        self.assertIn("no reviewer was spawned", result["error"])

    def test_a_fork_claude_pull_request_dry_run_reports_the_dual_route(self):
        # The dry run step 5 reads: the same fork pull request is reported as
        # unknown on a route that is not codex, which the asset makes a stop.
        with mock.patch.object(
            self.module, "pr_view", return_value=self.pr("claude", cross_repository=True)
        ):
            code, result = self.module.workflow(
                Path("/fake-repo"),
                7,
                rereview=False,
                dry_run=True,
                allow_no_issue=True,
            )
        self.assertEqual(result["origin"], "unknown")
        self.assertNotEqual(result["route"], "codex")
        self.assertIn("claude", result["route"])
        self.assertEqual(self.calls, [])

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


# The whole tracked Claude-on-Copilot tree, not just plugins/kanban/:
# marketplace.json and claude-copilot-plugin/README.md live outside that inner
# prefix and still ship.
BUNDLE_PREFIX = "claude-copilot-plugin"
ORIGINAL_BUNDLE_VERSION = "1.0.0"
BUNDLE_README_PATH = "claude-copilot-plugin/README.md"


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
                    "name": "kanban-claude",
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
        # marketplace.json lives under claude-copilot-plugin/.github/plugin/, outside
        # plugins/kanban/. A prefix that stopped at the inner plugin directory
        # would miss this edit and leave the gate green.
        self.marketplace.write_text(
            json.dumps(
                {
                    "name": "kanban-claude",
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
                    "name": "kanban-claude",
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
