"""The external bundles' `autosolve`, rendered from one authored source.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_external_autosolve_workflow.py

Issue #718, slice EXT-3 of
`docs/coordination/external_workflow_authoring_design.md`. The Grok, Kimi, and
Google bundles shipped `autosolve` as three hand-maintained copies that stated
one policy three times and that nothing compared, which is how #699's stale
approval-handoff wording sat in all three until a review found it. They are
now the render of `tools/command_sources/external/autosolve.md`, and
`tools/test_render_command_sources.py` byte-compares every rendered output
against its source. What this module adds is the property that registration
alone does not prove: a shared-policy edit in that source reaches exactly the
external `autosolve` assets -- four since issue #722 added the
Claude-on-Copilot bundle -- and each brand's runtime text reaches only its own.

Unlike the external `solve`, the Claude and Codex `autosolve` pair is itself
rendered -- from `tools/command_sources/autosolve.md`, a separate source this
slice deliberately does not merge -- so the negative control is stronger than
"not rendered at all": the pair is in the render set, and the planted edit
must leave it unchanged. That is the shape
`tools/test_drafting_workflow_contract.py`'s `WriteLocationTests` uses, so an
edit that reached every rendered asset cannot pass while proving nothing about
where this source's text goes.
"""

from __future__ import annotations

import re
import shutil
import tempfile
import unittest
from pathlib import Path

import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent

SOURCE = "tools/command_sources/external/autosolve.md"
ASSETS = {
    "grok": "grok-plugin/plugins/kanban/skills/autosolve/SKILL.md",
    "kimi": "kimi-plugin/plugins/kanban/skills/autosolve/SKILL.md",
    "google": "google-plugin/plugins/kanban/skills/autosolve/SKILL.md",
    "claude-copilot": "claude-copilot-plugin/plugins/kanban/skills/autosolve/SKILL.md",
}
# The Copilot-hosted bundles, each keyed by its brand-table entry and the
# origin brand its session stamps.
COPILOT_BUNDLES = {"kimi": "kimi", "google": "google", "claude-copilot": "claude"}
# Rendered from tools/command_sources/autosolve.md, and deliberately outside
# this source's reach.
CANONICAL_SOURCE = "tools/command_sources/autosolve.md"
CANONICAL_AUTOSOLVE_ASSETS = (
    "claude-plugin/plugins/kanban/commands/autosolve.md",
    "codex-plugin/plugins/kanban/skills/autosolve/SKILL.md",
)

# A line no asset in the tree carries, planted after a heading every brand
# shares and, as the control, inside the block only Grok keeps.
SENTINEL = "PLANTED-SHARED-POLICY-SENTINEL-718"
SHARED_ANCHOR = "## 6. Read the verdict after every round\n"
GROK_ONLY_ANCHOR = '<!-- brand:grok -->\n```bash\nISSUE="$ARGUMENTS"'

BRAND_MARKER_RE = re.compile(r"\A<!--\s*/?brand(?::[a-z,-]+)?\s*-->\s*\Z")


def read(path):
    return (REPO_ROOT / path).read_text(encoding="utf-8")


def entry():
    matching = [item for item in renderer.COMMAND_SOURCES if item.source == SOURCE]
    assert len(matching) == 1, f"{SOURCE} is registered {len(matching)} times"
    return matching[0]


def render_with_source(text):
    """Every registered entry rendered from a tree whose external `autosolve`
    source is `text`, keyed by output path."""
    vocabulary = renderer.workflow_vocabulary(REPO_ROOT)
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        shutil.copytree(
            REPO_ROOT / "tools/command_sources", root / "tools/command_sources"
        )
        (root / SOURCE).write_text(text, encoding="utf-8")
        rendered = {}
        for item in renderer.COMMAND_SOURCES:
            rendered.update(renderer.render_entry(item, root, vocabulary))
        return rendered


def plant(anchor):
    source = read(SOURCE)
    assert source.count(anchor) == 1, f"{anchor!r} appears {source.count(anchor)} times"
    return source.replace(anchor, anchor + f"\n{SENTINEL}\n", 1)


def split_lines(source):
    """`(shared, branded)`: the source lines outside every brand block -- the
    text every brand renders -- and the lines inside one."""
    shared, branded, inside = [], [], False
    for line in source.splitlines():
        if BRAND_MARKER_RE.match(line):
            inside = not line.startswith("<!-- /brand")
            continue
        (branded if inside else shared).append(line)
    return shared, branded


class RegistrationTests(unittest.TestCase):
    """Requirements 1 to 3: one source, one output per external bundle, all
    current."""

    def test_the_source_renders_exactly_the_external_autosolve_assets(self):
        self.assertEqual(renderer.output_paths(entry()), ASSETS)

    def test_each_asset_is_the_render_of_the_one_source(self):
        rendered = renderer.render_entry(entry(), REPO_ROOT)
        self.assertEqual(set(rendered), set(ASSETS.values()))
        for path, text in rendered.items():
            self.assertEqual(read(path), text, path)

    def test_the_canonical_pair_keeps_its_own_source(self):
        # Out of scope: the Claude and Codex autosolve keep rendering from
        # their own source, exactly its present two outputs.
        canonical = [
            item for item in renderer.COMMAND_SOURCES if item.source == CANONICAL_SOURCE
        ]
        self.assertEqual(len(canonical), 1)
        self.assertEqual(
            sorted(renderer.output_paths(canonical[0]).values()),
            sorted(CANONICAL_AUTOSOLVE_ASSETS),
        )

    def test_a_hand_edited_asset_is_reported_stale(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            shutil.copytree(REPO_ROOT / "tools/command_sources", root / "tools/command_sources")
            for directory in (renderer.CLAUDE_COMMANDS_DIR, renderer.CODEX_SKILLS_DIR):
                shutil.copytree(REPO_ROOT / directory, root / directory)
            for item in renderer.COMMAND_SOURCES:
                for path, text in renderer.render_entry(item, root).items():
                    (root / path).parent.mkdir(parents=True, exist_ok=True)
                    (root / path).write_text(text, encoding="utf-8")
            self.assertEqual(renderer.check_all(root), [])
            edited = root / ASSETS["google"]
            edited.write_text(edited.read_text(encoding="utf-8") + "\n", encoding="utf-8")
            failures = renderer.check_all(root)
            self.assertEqual(len(failures), 1, failures)
            self.assertIn(ASSETS["google"], failures[0])


class ReachTests(unittest.TestCase):
    """Requirement 4: a shared edit reaches the external assets and no other."""

    def setUp(self):
        self.baseline = renderer.render_all(REPO_ROOT)

    def changed(self, source_text):
        rendered = render_with_source(source_text)
        self.assertEqual(set(rendered), set(self.baseline))
        return {path for path, text in rendered.items() if text != self.baseline[path]}

    def test_the_sentinel_is_new_to_the_tree(self):
        # Non-vacuous: nothing carries it before it is planted.
        for path in (*ASSETS.values(), *CANONICAL_AUTOSOLVE_ASSETS, SOURCE, CANONICAL_SOURCE):
            self.assertNotIn(SENTINEL, read(path), path)

    def test_a_shared_policy_edit_reaches_every_external_autosolve_asset_and_nothing_else(self):
        rendered = render_with_source(plant(SHARED_ANCHOR))
        self.assertEqual(self.changed(plant(SHARED_ANCHOR)), set(ASSETS.values()))
        for path in ASSETS.values():
            self.assertIn(f"{SHARED_ANCHOR}\n{SENTINEL}\n", rendered[path], path)

    def test_the_canonical_autosolve_pair_is_rendered_but_untouched(self):
        # The negative control. The pair is in the render set -- so the
        # comparison above could have reported it -- and the planted edit
        # leaves it byte-identical, because it renders from another source.
        rendered = render_with_source(plant(SHARED_ANCHOR))
        for path in CANONICAL_AUTOSOLVE_ASSETS:
            self.assertIn(path, rendered, path)
            self.assertEqual(rendered[path], self.baseline[path], path)
            self.assertNotIn(SENTINEL, rendered[path], path)

    def test_a_grok_only_edit_reaches_grok_alone(self):
        # The control that keeps the shared-edit assertion discriminating: the
        # same comparison reports one path when the edit is scoped to one
        # brand, so reaching every asset is a property of where the text was
        # planted.
        source = read(SOURCE)
        self.assertEqual(source.count(GROK_ONLY_ANCHOR), 1)
        source = source.replace(
            GROK_ONLY_ANCHOR,
            "<!-- brand:grok -->\n" + SENTINEL + "\n```bash\nISSUE=\"$ARGUMENTS\"",
            1,
        )
        self.assertEqual(self.changed(source), {ASSETS["grok"]})


class BrandIsolationTests(unittest.TestCase):
    """Requirement 5: each brand's runtime text reaches only its own asset."""

    def setUp(self):
        self.assets = {brand: read(path) for brand, path in ASSETS.items()}

    def assert_only(self, text, owners):
        for brand, asset in self.assets.items():
            if brand in owners:
                self.assertIn(text, asset, f"{brand} lacks {text!r}")
            else:
                self.assertNotIn(text, asset, f"{brand} carries {text!r}")

    def test_grok_alone_binds_arguments_and_globs_its_install_root(self):
        self.assert_only('ISSUE="$ARGUMENTS"', {"grok"})
        self.assert_only('(Path(grok_home) / "installed-plugins").glob("kanban-*/"', {"grok"})
        self.assert_only("$GROK_HOME/installed-plugins/kanban-<hash>/", {"grok"})
        self.assert_only('argument-hint: "[issue number]"', {"grok"})

    def test_the_copilot_bundles_alone_read_settings_and_both_install_layouts(self):
        copilot = set(COPILOT_BUNDLES)
        self.assert_only("Copilot skills receive no\nsubstituted arguments", copilot)
        self.assert_only("$COPILOT_HOME/settings.json", copilot)
        self.assert_only('settings = Path(copilot_home) / "settings.json"', copilot)
        self.assert_only('direct = installed / "_direct"', copilot)
        for bundle, origin in COPILOT_BUNDLES.items():
            self.assert_only(f"layout `kanban-{origin}/kanban/`", {bundle})
            self.assert_only(
                f"_direct/<owner>--<repo>--{bundle}-plugin-plugins-kanban/", {bundle}
            )
            variable = bundle.upper().replace("-", "_")
            self.assert_only(f"${variable}_PLUGIN_ROOT", {bundle})

    def test_each_origin_marker_and_dry_run_origin_is_its_own_brands(self):
        for bundle in ASSETS:
            origin = COPILOT_BUNDLES.get(bundle, bundle)
            self.assert_only(f"<!-- pr-origin:{origin} -->", {bundle})
            self.assert_only(f'"origin": "{origin}"', {bundle})
            self.assert_only(f"--expected-origin {origin}", {bundle})

    def test_each_brand_refuses_the_plugin_paths_of_the_brands_before_it(self):
        # The accretion-order enumeration the issue review's correction names.
        # The Claude-on-Copilot bundle names every earlier brand but its own,
        # and names Claude Code's bundle as another host's rather than as a
        # sibling brand.
        expected = {
            "grok": "Claude or Codex plugin path",
            "kimi": "Claude, Codex, or Grok plugin path",
            "google": "Claude, Codex, Grok, or Kimi plugin path",
            "claude-copilot": "Claude Code's plugin path, a Codex, Grok, Kimi, or Google plugin path",
        }
        for brand, phrase in expected.items():
            self.assert_only(phrase, {brand})

    def test_only_the_claude_session_reads_fork_status_and_stops_on_it(self):
        # A claude marker is the one a fork pull request loses: every bundled
        # coordinator keeps only a grok, kimi, or google marker there.
        self.assert_only(
            'gh pr view "$PR" -R "$REPO" --json body,isCrossRepository', {"claude-copilot"}
        )
        self.assert_only(
            'gh pr view "$PR" -R "$REPO" --json body\n', {"grok", "kimi", "google"}
        )
        self.assert_only(
            "the bundled coordinator reads that marker even when GitHub reports",
            {"grok", "kimi", "google"},
        )
        squashed = re.sub(r"\s+", " ", self.assets["claude-copilot"])
        self.assertIn(
            "When the `isCrossRepository` read above is `true`, stop and report that "
            "this fork pull request's claude origin cannot be routed to Codex from "
            "this bundle: do not run step 5",
            squashed,
        )
        self.assertIn(
            "PR #<pr> is a fork pull request whose claude origin this bundle cannot "
            "route to Codex — needs your input.",
            squashed,
        )

    def test_the_claude_session_carries_no_never_invoke_claude_identity(self):
        # The review's correction: adapt the external safety guarantees without
        # the Kimi identity text a Claude session would contradict.
        for phrase in (
            "never invoke Claude.",
            "spawn, invoke, or impersonate Claude",
            "Do not invoke Claude",
            "continuing would invoke Claude",
            "do not ask Claude to revise",
            "A marker\nreading `reviewers=claude` is also a publication failure",
        ):
            self.assert_only(phrase, {"grok", "kimi", "google"})
        for phrase in (
            "never spawn another Claude session, and never review its own pull request.",
            "It must never spawn or invoke another Claude session",
            "never impersonate Codex.",
            "Do not spawn another\nClaude session for any step of this loop.",
            "do not start another Claude session to revise.",
        ):
            self.assert_only(phrase, {"claude-copilot"})


class SharedRouteTests(unittest.TestCase):
    """The reviewer route is shared, not per-brand: every external bundle routes
    to Codex, and only the origin beside the route varies."""

    def test_every_brand_routes_to_codex(self):
        for brand, path in ASSETS.items():
            text = read(path)
            self.assertIn('"route": "codex"', text, brand)
            self.assertIn("reviewed by Codex only.", text, brand)

    def test_the_route_is_authored_outside_every_brand_block(self):
        shared, branded = map("\n".join, split_lines(read(SOURCE)))
        self.assertIn(
            'The dry run must report `"origin": "{{brand:name}}"` and `"route": "codex"`.',
            shared,
        )
        self.assertIn("reviewed by Codex only.", shared)
        # No variant restates the route, so no brand can be given another.
        self.assertNotIn('"route"', branded)
        self.assertNotIn("--review", branded)
        # Non-vacuous: the split does put block text on the branded side.
        self.assertIn('ISSUE="$ARGUMENTS"', branded)
        self.assertNotIn('ISSUE="$ARGUMENTS"', shared)


if __name__ == "__main__":
    unittest.main()
