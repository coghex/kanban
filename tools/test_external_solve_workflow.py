"""The external bundles' `solve`, rendered from one authored source.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_external_solve_workflow.py

Issue #717, slice EXT-2 of
`docs/coordination/external_workflow_authoring_design.md`. The Grok, Kimi, and
Google bundles shipped `solve` as three hand-maintained copies that stated one
policy three times and that nothing compared, which is how #698's Copilot
helper-discovery defect sat in two of them until a review found it. They are
now the render of `tools/command_sources/external/solve.md`, and
`tools/test_render_command_sources.py` byte-compares every rendered output
against its source. What this module adds is the property that registration
alone does not prove: a shared-policy edit in that source reaches exactly the
three external `solve` assets, and each brand's runtime text reaches only its
own.

The Claude and Codex `solve` pair stays hand-edited (design D-5), so it is the
negative control for the reach test, in the shape
`tools/test_drafting_workflow_contract.py`'s `WriteLocationTests` uses: a
planted edit that reached every asset in the tree would otherwise pass while
proving nothing about where the source's text goes.
"""

from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent

SOURCE = "tools/command_sources/external/solve.md"
ASSETS = {
    "grok": "grok-plugin/plugins/kanban/skills/solve/SKILL.md",
    "kimi": "kimi-plugin/plugins/kanban/skills/solve/SKILL.md",
    "google": "google-plugin/plugins/kanban/skills/solve/SKILL.md",
}
# Hand-edited, and deliberately outside this source's reach.
CANONICAL_SOLVE_ASSETS = (
    "claude-plugin/plugins/kanban/commands/solve.md",
    "codex-plugin/plugins/kanban/skills/solve/SKILL.md",
)

# A line no asset in the tree carries, planted after a heading every brand
# shares and, as the control, inside the block only Grok keeps.
SENTINEL = "PLANTED-SHARED-POLICY-SENTINEL-717"
SHARED_ANCHOR = "## Ship\n"
GROK_ONLY_ANCHOR = "<!-- brand:grok -->\n1. Capture the issue number"


def read(path):
    return (REPO_ROOT / path).read_text(encoding="utf-8")


def entry():
    matching = [item for item in renderer.COMMAND_SOURCES if item.source == SOURCE]
    assert len(matching) == 1, f"{SOURCE} is registered {len(matching)} times"
    return matching[0]


def render_with_source(text):
    """Every registered entry rendered from a tree whose external `solve`
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


def plant(anchor, count=1):
    source = read(SOURCE)
    assert source.count(anchor) == count, f"{anchor!r} appears {source.count(anchor)} times"
    return source.replace(anchor, anchor + f"\n{SENTINEL}\n", 1)


class RegistrationTests(unittest.TestCase):
    """Requirements 1 to 3: one source, three outputs, all current."""

    def test_the_source_renders_exactly_the_three_external_solve_assets(self):
        self.assertEqual(renderer.output_paths(entry()), ASSETS)

    def test_each_asset_is_the_render_of_the_one_source(self):
        rendered = renderer.render_entry(entry(), REPO_ROOT)
        self.assertEqual(set(rendered), set(ASSETS.values()))
        for path, text in rendered.items():
            self.assertEqual(read(path), text, path)

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
            edited = root / ASSETS["kimi"]
            edited.write_text(edited.read_text(encoding="utf-8") + "\n", encoding="utf-8")
            failures = renderer.check_all(root)
            self.assertEqual(len(failures), 1, failures)
            self.assertIn(ASSETS["kimi"], failures[0])


class ReachTests(unittest.TestCase):
    """Requirement 4: a shared edit reaches the three and no other asset."""

    def setUp(self):
        self.baseline = renderer.render_all(REPO_ROOT)

    def changed(self, source_text):
        rendered = render_with_source(source_text)
        self.assertEqual(set(rendered), set(self.baseline))
        return {path for path, text in rendered.items() if text != self.baseline[path]}

    def test_the_sentinel_is_new_to_the_tree(self):
        # Non-vacuous: nothing carries it before it is planted.
        for path in (*ASSETS.values(), *CANONICAL_SOLVE_ASSETS, SOURCE):
            self.assertNotIn(SENTINEL, read(path), path)

    def test_a_shared_policy_edit_reaches_all_three_solve_assets_and_nothing_else(self):
        rendered = render_with_source(plant(SHARED_ANCHOR))
        self.assertEqual(self.changed(plant(SHARED_ANCHOR)), set(ASSETS.values()))
        for path in ASSETS.values():
            self.assertIn(f"{SHARED_ANCHOR}\n{SENTINEL}\n", rendered[path], path)

    def test_the_canonical_solve_pair_is_outside_the_reach(self):
        # The negative control: the Claude and Codex solve are no render of
        # this source -- of any registered source -- so the edit cannot reach
        # them however it is placed.
        rendered = render_with_source(plant(SHARED_ANCHOR))
        for path in CANONICAL_SOLVE_ASSETS:
            self.assertNotIn(path, rendered, path)
            self.assertNotIn(SENTINEL, read(path), path)

    def test_a_grok_only_edit_reaches_grok_alone(self):
        # The control that keeps the shared-edit assertion discriminating: the
        # same comparison reports one path when the edit is scoped to one
        # brand, so three is a property of where the text was planted.
        source = read(SOURCE).replace(
            GROK_ONLY_ANCHOR,
            "<!-- brand:grok -->\n" + SENTINEL + "\n1. Capture the issue number",
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
        self.assert_only("$ARGUMENTS", {"grok"})
        self.assert_only('(Path(grok_home) / "installed-plugins").glob("kanban-*/"', {"grok"})
        self.assert_only("$GROK_HOME/installed-plugins/kanban-<hash>/", {"grok"})

    def test_the_copilot_pair_alone_reads_settings_and_both_install_layouts(self):
        self.assert_only("$COPILOT_HOME/settings.json", {"kimi", "google"})
        self.assert_only('settings = Path(copilot_home) / "settings.json"', {"kimi", "google"})
        self.assert_only('direct = installed / "_direct"', {"kimi", "google"})
        for brand in ("kimi", "google"):
            self.assert_only(f"the marketplace layout `kanban-{brand}/kanban/`", {brand})
            self.assert_only(
                f"_direct/<owner>--<repo>--{brand}-plugin-plugins-kanban/", {brand}
            )
            self.assert_only(f"${brand.upper()}_PLUGIN_ROOT", {brand})

    def test_each_origin_marker_is_its_own_brands(self):
        for brand in ASSETS:
            self.assert_only(f"<!-- pr-origin:{brand} -->", {brand})

    def test_each_brand_refuses_the_brands_that_preceded_it(self):
        expected = {
            "grok": "never follow a Claude or Codex solve skill",
            "kimi": "never follow a Claude, Codex, or Grok solve skill",
            "google": "never follow a Claude, Codex, Grok, or Kimi solve skill",
        }
        for brand, phrase in expected.items():
            self.assert_only(phrase, {brand})
        self.assert_only(
            "never follow a generic solve agent that would leave the pull request unmarked",
            {"kimi", "google"},
        )


if __name__ == "__main__":
    unittest.main()
