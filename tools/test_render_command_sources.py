"""The shared command source mechanism, and the gate that keeps it applied.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_render_command_sources.py

Issue #375, slice VEND-0 of `docs/designs/workflow_command_vendoring_design.md`. Two
things are under test and they fail for different reasons:

* **The mechanism.** One authored source renders into a Claude
  `commands/<name>.md` and a Codex `skills/<name>/SKILL.md`, reconciling file
  layout, per-brand frontmatter keys, and the invocation sigil throughout the
  body — and rendering twice changes nothing. Since issue #716 an entry
  declares which brands it renders, and each brand declares its layout,
  frontmatter keys, and sigil independently; the fixture proves a third brand,
  grok, that takes Codex's layout with Claude's sigil and a key set of its own.
* **The gate.** Every registered source is re-rendered here and byte-compared
  against its tracked output, so a source edited without re-rendering fails
  `build-test`. Running the renderer once by hand proves it ran once; this is
  what proves it stays run. Each negative case plants its violation in a
  temporary tree, following this suite's convention, so it reports its own
  cause rather than failing again for whatever the live tree is missing.

The mechanism's own subject is a fixture, deliberately.
`tools/plugin_bundle_gate.py` takes shippedness from location, so a source
rendered into either bundle directory becomes an invokable command; VEND-0
vendored none, and `FixtureIsNotShippedTests` still holds `fixture-command` to
that. Since VEND-1 (issue #393) the registry also holds `triage`, since
issue #410 `push-docs`, since VEND-2 (issue #427) `retriage`, since
VEND-3 (issue #430) `backlog-review`, since VEND-4 (issue #462)
`project-review`, since VEND-5 (issue #511) `drain-prs`, since VEND-7
(issue #544) `finalize`, since VEND-9 (issue #575) `janitor`, since VEND-8
(issue #576) `autosolve`, and -- authored
directly against this mechanism rather than vendored from a personal copy --
`fix` and, since LEDGER-7 (issue #685), `auto-project-review`, all eleven of
which do render into both bundles, so the same class pins
the shipped sets at twenty-six and twenty-five and pins which registered
source belongs to which kind. Since EXT-2 (issue #717) it holds a third kind
too, the external `solve` and, since EXT-3 (issue #718), the external
`autosolve`, which render into the Grok, Kimi, and Google bundles and neither
of the other two; `tools/test_external_solve_workflow.py` and
`tools/test_external_autosolve_workflow.py` hold their reach.
"""

from __future__ import annotations

import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

import plugin_bundle_gate
import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent

CLAUDE_COMMANDS_PREFIX = "claude-plugin/plugins/kanban/commands"
CODEX_SKILLS_PREFIX = "codex-plugin/plugins/kanban/skills"

# The shipped sets: Claude's twenty-six names, and Codex's the same set minus
# Claude-only `draft-issues`. Pinned as counts and as the one documented
# difference rather than as a third copy of the name list, which
# tools/test_claude_plugin.py and tools/test_codex_plugin.py already assert.
# Both grew by one in VEND-1, which added the first source that ships, by
# one more when issue #410 vendored `push-docs`, by one more again in
# VEND-2, which vendored `retriage`, by one more in VEND-3, which vendored
# `backlog-review`, by one more in VEND-4, which vendored `project-review`,
# by one more in VEND-5, which vendored `drain-prs`, by one more when
# `fix` was authored directly against this mechanism rather than vendored from
# a personal copy, by one more in VEND-7, which vendored `finalize`, by one
# more in VEND-9, which vendored `janitor` -- whose Codex directory already
# existed, shipping issue #574's census helper and no SKILL.md, so that bundle
# gained a workflow without gaining a directory -- by one more in VEND-8,
# which vendored `autosolve` and closed the arc, and by one more again when
# issue #685 authored `auto-project-review` against this mechanism from
# outside that arc, with no personal copy behind it.
SHIPPED_CLAUDE_COUNT = 26
SHIPPED_CODEX_COUNT = 25
CLAUDE_ONLY_WORKFLOW = "draft-issues"

# The registered sources that render into the two bundles rather than under
# tools/. Stated here so the fixture's unshippedness stays an assertion about
# the fixture, not a blanket rule the first vendored workflow had to relax.
SHIPPING_SOURCE_NAMES = {
    "triage",
    "push-docs",
    "retriage",
    "backlog-review",
    "project-review",
    "drain-prs",
    "fix",
    "finalize",
    "janitor",
    "autosolve",
    "auto-project-review",
}

# The registered sources that render into the three external bundles and
# neither of the two above. Keyed by source path rather than by name, because
# each shares its name with a Claude and Codex pair it deliberately does not
# render: the hand-edited `solve`, and the `autosolve` another source renders.
EXTERNAL_SOURCES = {
    "tools/command_sources/external/solve.md",
    "tools/command_sources/external/autosolve.md",
}
EXTERNAL_PREFIXES = ("grok-plugin/", "kimi-plugin/", "google-plugin/")

FIXTURE_SOURCE = "tools/command_sources/fixture-command.md"
FIXTURE_CLAUDE_OUTPUT = "tools/command_render_fixture/claude/commands/fixture-command.md"
FIXTURE_CODEX_OUTPUT = (
    "tools/command_render_fixture/codex/skills/fixture-command/SKILL.md"
)
FIXTURE_GROK_OUTPUT = "tools/command_render_fixture/grok/skills/fixture-command/SKILL.md"
FIXTURE_OUTPUTS = {
    "claude": FIXTURE_CLAUDE_OUTPUT,
    "codex": FIXTURE_CODEX_OUTPUT,
    "grok": FIXTURE_GROK_OUTPUT,
}

# Every bundle directory prefix in the tree, so the fixture's unshippedness is
# asserted against all of them rather than the two it started with.
PLUGIN_PREFIXES = tuple(
    f"{path.name}/" for path in sorted(REPO_ROOT.glob("*-plugin")) if path.is_dir()
)

# Text that looks sigil-adjacent but is not a workflow invocation. Every one
# must reach both rendered files unchanged, which is the half of the
# transformation boundary a rewrite rule gets wrong.
NON_INVOCATIONS = (
    "<https://github.com/coghex/kanban/issues/375>",
    "`docs/design.md`",
    "`/tmp/kanban-scratch`",
    "`/dev/null`",
    # Round 1 blocker: a path component and a variable prefix that are spelled
    # like a workflow but are not invocations.
    "`/solve/cache`",
    "`/solve.md`",
    "`/pr-review/scripts/review_pr.py`",
    "`$solve_result`",
    "`$REPO`",
    "`$WORKTREES_ROOT`",
    "`$HOME`",
    "and/or",
    "3/4",
)

SYNTHETIC = textwrap.dedent(
    """\
    ---
    name: synthetic
    description: A synthetic source naming {{cmd:synthetic}}.
    argument-hint: "[issue number]"
    ---

    # Synthetic

    Invoke {{cmd:solve}} and then {{cmd:pr-review}}.

    <!-- brand:claude -->
    Claude takes its argument from `$ARGUMENTS`.
    <!-- brand:codex -->
    Codex takes its argument from the prompt.
    <!-- /brand -->

    Trailing paragraph.
    """
)


SYNTHETIC_OUTPUTS = {
    "claude": "tools/out/claude/commands",
    "codex": "tools/out/codex/skills",
    "grok": "tools/out/grok/skills",
    "kimi": "tools/out/kimi/skills",
    "google": "tools/out/google/skills",
}


def synthetic_entry(name="synthetic", source=None, brands=None):
    """A synthetic entry rendering every registered brand, or `brands`."""
    return renderer.CommandSource(
        name=name,
        source=source or f"tools/command_sources/{name}.md",
        outputs={
            brand: SYNTHETIC_OUTPUTS[brand]
            for brand in (renderer.BRANDS if brands is None else brands)
        },
        note="synthetic test entry",
    )


# The workflow vocabulary the text-level cases are measured against: the two
# workflows SYNTHETIC references plus its own name, standing in for what
# workflow_vocabulary() reads off a real checkout.
SYNTHETIC_VOCABULARY = {"synthetic", "solve", "pr-review"}


def render_text(text, brand, name="synthetic", vocabulary=None, brands=None):
    return renderer.render(
        synthetic_entry(name, brands=brands),
        text,
        brand,
        SYNTHETIC_VOCABULARY if vocabulary is None else vocabulary,
    )


def plant_bundles(root):
    """The two bundle directories workflow_vocabulary() reads, with one
    workflow each, so a temporary tree has a real vocabulary rather than an
    empty one."""
    commands = root / renderer.CLAUDE_COMMANDS_DIR
    commands.mkdir(parents=True, exist_ok=True)
    (commands / "solve.md").write_text("---\ndescription: d\n---\n", encoding="utf-8")
    skill = root / renderer.CODEX_SKILLS_DIR / "solve"
    skill.mkdir(parents=True, exist_ok=True)
    (skill / "SKILL.md").write_text(
        "---\nname: solve\ndescription: d\n---\n", encoding="utf-8"
    )


def read(path):
    return (REPO_ROOT / path).read_text(encoding="utf-8")


def frontmatter_lines(text):
    match = renderer.FRONTMATTER_RE.match(text)
    assert match is not None, "rendered file has no frontmatter"
    return match.group("frontmatter").splitlines()


def frontmatter_keys(text):
    return [line.split(":", 1)[0] for line in frontmatter_lines(text)]


def body_of(text):
    match = renderer.FRONTMATTER_RE.match(text)
    assert match is not None, "rendered file has no frontmatter"
    return match.group("body")


class RegistryShapeTests(unittest.TestCase):
    def test_the_registry_is_non_empty_and_unambiguous(self):
        # Guards every gate below: an empty registry would make the staleness
        # check pass by having nothing to check.
        self.assertTrue(renderer.COMMAND_SOURCES)
        sources = [entry.source for entry in renderer.COMMAND_SOURCES]
        self.assertEqual(sorted(sources), sorted(set(sources)))
        # A name may repeat only across the canonical/external split -- the
        # external autosolve beside the Claude and Codex one -- and then only
        # between entries rendering disjoint brand sets, so no bundle ships two.
        brands_by_name = {}
        for entry in renderer.COMMAND_SOURCES:
            claimed = brands_by_name.setdefault(entry.name, set())
            self.assertFalse(claimed & set(entry.outputs), entry.name)
            claimed |= set(entry.outputs)
        outputs = [
            path
            for entry in renderer.COMMAND_SOURCES
            for path in renderer.output_paths(entry).values()
        ]
        self.assertEqual(sorted(outputs), sorted(set(outputs)))

    def test_every_registered_source_exists_and_is_named_by_its_file(self):
        for entry in renderer.COMMAND_SOURCES:
            source = REPO_ROOT / entry.source
            self.assertTrue(source.is_file(), f"missing {entry.source}")
            self.assertEqual(Path(entry.source).stem, entry.name, entry.source)
            self.assertTrue(entry.note.strip(), f"{entry.name} states no note")

    def test_each_brands_frontmatter_projection_is_a_subset_of_the_source_keys(self):
        # A brand key the source cannot declare would render as a missing key
        # in that brand's file and nowhere be reported.
        for brand, keys in renderer.BRAND_FRONTMATTER_KEYS.items():
            self.assertEqual(sorted(set(keys)), sorted(keys), brand)
            for key in keys:
                self.assertIn(key, renderer.SOURCE_FRONTMATTER_KEYS, f"{brand}:{key}")
        self.assertEqual(sorted(renderer.BRAND_FRONTMATTER_KEYS), sorted(renderer.BRANDS))

    def test_a_required_source_key_reaches_the_brands_that_need_it(self):
        # Every loader reads `description`; the skill-directory loaders read
        # `name` as well, which is why `name` is required in the source even
        # though Claude drops it.
        for brand in renderer.BRANDS:
            self.assertIn("description", renderer.BRAND_FRONTMATTER_KEYS[brand], brand)
        self.assertIn("name", renderer.BRAND_FRONTMATTER_KEYS["codex"])
        self.assertIn("name", renderer.BRAND_FRONTMATTER_KEYS["grok"])
        self.assertNotIn("name", renderer.BRAND_FRONTMATTER_KEYS["claude"])

    def test_every_brand_declares_a_known_layout_and_a_patterned_sigil(self):
        for brand, spec in renderer.BRAND_TABLE.items():
            self.assertIn(spec.layout, renderer.LAYOUTS, brand)
            self.assertIn(spec.sigil, renderer.IDENTIFIER_PATTERNS, brand)
        self.assertEqual(renderer.BRANDS, tuple(renderer.BRAND_TABLE))
        self.assertEqual(
            renderer.SIGILS,
            {brand: spec.sigil for brand, spec in renderer.BRAND_TABLE.items()},
        )

    def test_the_three_axes_are_independent(self):
        # Requirement 2: the table can express a brand that is neither
        # existing brand but shares an axis with each -- grok takes codex's
        # layout, claude's sigil, and a key set that is neither's.
        claude, codex, grok = (
            renderer.BRAND_TABLE[brand] for brand in ("claude", "codex", "grok")
        )
        self.assertEqual(grok.layout, codex.layout)
        self.assertEqual(grok.sigil, claude.sigil)
        self.assertNotEqual(grok.frontmatter_keys, claude.frontmatter_keys)
        self.assertNotEqual(grok.frontmatter_keys, codex.frontmatter_keys)
        self.assertEqual(grok.frontmatter_keys, ("name", "description", "argument-hint"))

    def test_every_entry_declares_a_non_empty_set_of_registered_brands(self):
        for entry in renderer.COMMAND_SOURCES:
            self.assertTrue(entry.outputs, entry.name)
            self.assertLessEqual(set(entry.outputs), set(renderer.BRANDS), entry.name)

    def test_the_workflow_token_pattern_matches_the_bundle_gates(self):
        # One notion of where a sigil-prefixed workflow token may start, across
        # the manifest gate and this renderer, reconciled here because the two
        # modules deliberately do not import each other.
        self.assertEqual(
            {sigil: pattern.pattern for sigil, pattern in renderer.IDENTIFIER_PATTERNS.items()},
            {
                sigil: pattern.pattern
                for sigil, pattern in plugin_bundle_gate.IDENTIFIER_PATTERNS.items()
            },
        )
        # Two brands may share a sigil -- claude and grok both use `/` -- so
        # the comparison is over the distinct sigils, not one per brand.
        self.assertEqual(
            set(renderer.SIGILS.values()), set(renderer.IDENTIFIER_PATTERNS)
        )

    def test_the_refusal_pattern_is_the_shared_one_plus_a_trailing_boundary(self):
        # The one documented divergence, stated as a derivation rather than a
        # second hand-written pattern: the manifest gate over-reporting a name
        # costs a spurious listing, while over-reporting here refuses a file.
        self.assertEqual(
            sorted(renderer.LITERAL_INVOCATION_PATTERNS),
            sorted(renderer.IDENTIFIER_PATTERNS),
        )
        for sigil, pattern in renderer.LITERAL_INVOCATION_PATTERNS.items():
            self.assertEqual(
                pattern.pattern,
                renderer.IDENTIFIER_PATTERNS[sigil].pattern + renderer.TOKEN_TAIL,
                sigil,
            )


class RenderedArtifactsAreCurrentTests(unittest.TestCase):
    """The durable gate: the tracked rendered files match their sources."""

    def test_every_registered_source_renders_to_its_tracked_output(self):
        self.assertEqual(
            renderer.check_all(REPO_ROOT),
            [],
            "a rendered command file no longer matches the source it is "
            f"rendered from; {renderer.RENDER_INSTRUCTION}",
        )

    def test_the_gate_has_something_to_compare(self):
        rendered = renderer.render_all(REPO_ROOT)
        self.assertGreaterEqual(len(rendered), 2)
        for path in FIXTURE_OUTPUTS.values():
            self.assertIn(path, rendered)

    def test_the_command_line_check_agrees_with_the_tracked_tree(self):
        self.assertEqual(renderer.main(["--check"]), 0)


class StaleArtifactDetectionTests(unittest.TestCase):
    """The gate is load-bearing rather than decorative: plant drift in an
    isolated tree and it names the file and the repair."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.entry = synthetic_entry()
        source = self.root / self.entry.source
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(SYNTHETIC, encoding="utf-8")
        plant_bundles(self.root)
        patch = mock.patch.object(renderer, "COMMAND_SOURCES", (self.entry,))
        patch.start()
        self.addCleanup(patch.stop)

    def rendered_paths(self):
        return renderer.output_paths(self.entry)

    def test_a_freshly_rendered_tree_reports_nothing(self):
        renderer.write_all(self.root)
        self.assertEqual(renderer.check_all(self.root), [])

    def test_an_edited_rendered_file_is_reported_as_stale(self):
        renderer.write_all(self.root)
        target = self.root / self.rendered_paths()["codex"]
        target.write_text(
            target.read_text(encoding="utf-8") + "hand edit\n", encoding="utf-8"
        )
        failures = renderer.check_all(self.root)
        self.assertEqual(len(failures), 1, failures)
        self.assertIn(self.rendered_paths()["codex"], failures[0])
        self.assertIn(renderer.RENDER_INSTRUCTION, failures[0])

    def test_an_edited_source_makes_every_rendered_file_stale(self):
        # The drift this gate exists for: the single source moves and the
        # generated files do not.
        renderer.write_all(self.root)
        source = self.root / self.entry.source
        source.write_text(
            source.read_text(encoding="utf-8").replace(
                "Trailing paragraph.", "Trailing paragraph, revised."
            ),
            encoding="utf-8",
        )
        failures = renderer.check_all(self.root)
        self.assertEqual(len(failures), len(renderer.BRANDS), failures)
        self.assertEqual(
            sorted(path for path in self.rendered_paths().values()),
            sorted(failure.split(" ", 1)[0] for failure in failures),
        )

    def test_a_missing_rendered_file_is_reported(self):
        renderer.write_all(self.root)
        (self.root / self.rendered_paths()["claude"]).unlink()
        failures = renderer.check_all(self.root)
        self.assertEqual(len(failures), 1, failures)
        self.assertIn(self.rendered_paths()["claude"], failures[0])
        self.assertIn("missing", failures[0])

    def test_the_third_brands_missing_output_is_reported_with_the_repair(self):
        # Requirement 5: the new brand's output is gated exactly as the
        # existing two are.
        renderer.write_all(self.root)
        grok = self.rendered_paths()["grok"]
        (self.root / grok).unlink()
        failures = renderer.check_all(self.root)
        self.assertEqual(len(failures), 1, failures)
        self.assertIn(grok, failures[0])
        self.assertIn("missing", failures[0])
        self.assertIn(renderer.RENDER_INSTRUCTION, failures[0])

    def test_the_third_brands_stale_output_is_reported_with_the_repair(self):
        renderer.write_all(self.root)
        grok = self.rendered_paths()["grok"]
        with (self.root / grok).open("a", encoding="utf-8") as handle:
            handle.write("\n")
        failures = renderer.check_all(self.root)
        self.assertEqual(len(failures), 1, failures)
        self.assertIn(grok, failures[0])
        self.assertIn("stale", failures[0])
        self.assertIn(renderer.RENDER_INSTRUCTION, failures[0])
        self.assertEqual(renderer.write_all(self.root), [grok])
        self.assertEqual(renderer.check_all(self.root), [])

    def test_rendering_repairs_what_the_check_reported(self):
        renderer.write_all(self.root)
        target = self.root / self.rendered_paths()["claude"]
        target.write_text("stale\n", encoding="utf-8")
        self.assertEqual(
            renderer.write_all(self.root), [self.rendered_paths()["claude"]]
        )
        self.assertEqual(renderer.check_all(self.root), [])

    def test_re_running_the_renderer_over_unchanged_input_writes_nothing(self):
        # Requirement 3, on disk: the second run reports no changed file, so
        # `render && git diff --exit-code` is clean.
        self.assertEqual(
            sorted(renderer.write_all(self.root)),
            sorted(self.rendered_paths().values()),
        )
        self.assertEqual(renderer.write_all(self.root), [])
        self.assertEqual(renderer.write_all(self.root), [])


class FixtureIsNotShippedTests(unittest.TestCase):
    """VEND-0's requirements 4 and 5, held against a registry that now also
    carries a shipping entry. The fixture's own unshippedness is what those
    requirements bought and it is asserted directly; a production source
    rendering into both bundles is the mechanism working, not a violation."""

    def test_the_fixture_renders_into_neither_bundle(self):
        entry = {source.name: source for source in renderer.COMMAND_SOURCES}[
            "fixture-command"
        ]
        # Non-vacuous: the prefixes include the two shipping bundles.
        self.assertIn("claude-plugin/", PLUGIN_PREFIXES)
        self.assertIn("codex-plugin/", PLUGIN_PREFIXES)
        for brand, path in renderer.output_paths(entry).items():
            self.assertFalse(
                path.startswith(PLUGIN_PREFIXES),
                f"fixture-command renders {brand} into a bundle ({path}); it "
                "must stay invokable by every provider",
            )

    def test_a_production_source_renders_into_both_bundles(self):
        # The registry's two kinds differ by output directory alone, so the
        # shipping kind is pinned as well as the fixture: an entry that
        # rendered a vendored workflow outside both bundles would ship
        # nothing while every other assertion here still passed.
        shipping = {
            source.name: source
            for source in renderer.COMMAND_SOURCES
            if source.source not in EXTERNAL_SOURCES
        }
        for name in SHIPPING_SOURCE_NAMES:
            entry = shipping[name]
            paths = renderer.output_paths(entry)
            self.assertEqual(sorted(paths), ["claude", "codex"], name)
            self.assertTrue(paths["claude"].startswith(CLAUDE_COMMANDS_PREFIX), paths)
            self.assertTrue(paths["codex"].startswith(CODEX_SKILLS_PREFIX), paths)

    def test_the_fixture_renders_to_the_three_paths_it_declares(self):
        entry = {source.name: source for source in renderer.COMMAND_SOURCES}[
            "fixture-command"
        ]
        self.assertEqual(entry.source, FIXTURE_SOURCE)
        self.assertEqual(renderer.output_paths(entry), FIXTURE_OUTPUTS)
        for path in FIXTURE_OUTPUTS.values():
            self.assertTrue((REPO_ROOT / path).is_file(), f"missing {path}")

    def test_the_shipped_sets_are_the_ones_this_slice_declares(self):
        claude = plugin_bundle_gate.tracked_command_names(
            REPO_ROOT, CLAUDE_COMMANDS_PREFIX
        )
        codex = plugin_bundle_gate.tracked_skill_names(REPO_ROOT, CODEX_SKILLS_PREFIX)
        self.assertEqual(len(claude), SHIPPED_CLAUDE_COUNT)
        self.assertEqual(len(codex), SHIPPED_CODEX_COUNT)
        # The one documented difference between the two sets, so the counts
        # cannot agree by coincidence while the membership drifted.
        self.assertEqual(codex, claude - {CLAUDE_ONLY_WORKFLOW})
        for entry in renderer.COMMAND_SOURCES:
            if entry.source in EXTERNAL_SOURCES:
                # Its name may be one the two bundles ship by hand; what it
                # renders is pinned by the test below.
                continue
            shipped = entry.name in SHIPPING_SOURCE_NAMES
            self.assertEqual(entry.name in claude, shipped, entry.name)
            self.assertEqual(entry.name in codex, shipped, entry.name)


    def test_an_external_source_renders_into_the_external_bundles_alone(self):
        # The third kind: it ships in the grok, kimi and google bundles, and
        # in neither the Claude nor the Codex one.
        external = [
            entry
            for entry in renderer.COMMAND_SOURCES
            if entry.source in EXTERNAL_SOURCES
        ]
        self.assertEqual({entry.source for entry in external}, EXTERNAL_SOURCES)
        for entry in external:
            paths = renderer.output_paths(entry)
            self.assertEqual(sorted(paths), ["google", "grok", "kimi"], entry.source)
            for brand, path in paths.items():
                self.assertTrue(path.startswith(f"{brand}-plugin/"), path)
                self.assertTrue((REPO_ROOT / path).is_file(), f"missing {path}")
        for entry in renderer.COMMAND_SOURCES:
            if entry.source in EXTERNAL_SOURCES:
                continue
            for path in renderer.output_paths(entry).values():
                self.assertFalse(path.startswith(EXTERNAL_PREFIXES), path)


class LayoutAndFrontmatterTests(unittest.TestCase):
    """Requirements 1 and 2, and the review's exact-structure amendment."""

    def setUp(self):
        self.claude = read(FIXTURE_CLAUDE_OUTPUT)
        self.codex = read(FIXTURE_CODEX_OUTPUT)
        self.grok = read(FIXTURE_GROK_OUTPUT)

    def test_each_brand_lands_in_its_own_layout(self):
        self.assertTrue(FIXTURE_CLAUDE_OUTPUT.endswith("/commands/fixture-command.md"))
        self.assertTrue(
            FIXTURE_CODEX_OUTPUT.endswith("/skills/fixture-command/SKILL.md")
        )
        self.assertTrue(FIXTURE_GROK_OUTPUT.endswith("/skills/fixture-command/SKILL.md"))

    def test_the_grok_file_declares_all_three_keys_matching_its_directory(self):
        # The third brand's projection: neither claude's pair nor codex's.
        self.assertEqual(
            frontmatter_keys(self.grok), ["name", "description", "argument-hint"]
        )
        name_line = frontmatter_lines(self.grok)[0]
        self.assertEqual(name_line, "name: fixture-command")
        self.assertEqual(Path(FIXTURE_GROK_OUTPUT).parent.name, "fixture-command")
        self.assertEqual(
            frontmatter_lines(self.grok)[2], frontmatter_lines(self.claude)[1]
        )

    def test_the_grok_description_takes_the_slash_sigil(self):
        # Same sigil as claude, so the description is claude's byte for byte.
        self.assertEqual(
            frontmatter_lines(self.grok)[1], frontmatter_lines(self.claude)[0]
        )
        self.assertIn("/fixture-command", frontmatter_lines(self.grok)[1])

    def test_the_claude_file_declares_claude_frontmatter(self):
        self.assertEqual(frontmatter_keys(self.claude), ["description", "argument-hint"])

    def test_the_codex_file_declares_codex_frontmatter_matching_its_directory(self):
        self.assertEqual(frontmatter_keys(self.codex), ["name", "description"])
        name_line = frontmatter_lines(self.codex)[0]
        self.assertEqual(name_line, "name: fixture-command")
        self.assertEqual(
            Path(FIXTURE_CODEX_OUTPUT).parent.name, name_line.split(": ", 1)[1]
        )

    def test_the_two_files_share_one_description_modulo_the_sigil(self):
        claude_description = frontmatter_lines(self.claude)[0]
        codex_description = frontmatter_lines(self.codex)[1]
        self.assertIn("/fixture-command", claude_description)
        self.assertIn("$fixture-command", codex_description)
        self.assertEqual(
            claude_description.replace("/fixture-command", "<ref>"),
            codex_description.replace("$fixture-command", "<ref>"),
        )

    def test_an_unsupported_frontmatter_key_is_refused(self):
        # The override keys tools/test_claude_plugin.py forbids in a shipped
        # command cannot reach one through the renderer either.
        source = SYNTHETIC.replace(
            'argument-hint: "[issue number]"', "model: claude-opus-5-5"
        )
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn("model", str(raised.exception))

    def test_a_missing_required_key_is_refused(self):
        source = SYNTHETIC.replace(
            "description: A synthetic source naming {{cmd:synthetic}}.\n", ""
        )
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "codex")
        self.assertIn("description", str(raised.exception))

    def test_a_duplicate_key_is_refused(self):
        source = SYNTHETIC.replace(
            "name: synthetic\n", "name: synthetic\nname: synthetic\n"
        )
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn("duplicate", str(raised.exception))

    def test_a_name_disagreeing_with_the_registry_is_refused(self):
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(SYNTHETIC, "claude", name="something-else")
        self.assertIn("something-else", str(raised.exception))

    def test_a_source_without_frontmatter_is_refused(self):
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text("# No frontmatter\n", "claude")
        self.assertIn("frontmatter", str(raised.exception))

    def test_an_unparseable_frontmatter_line_is_refused(self):
        source = SYNTHETIC.replace("name: synthetic\n", "name synthetic\n")
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn("key: value", str(raised.exception))


class WorkflowVocabularyTests(unittest.TestCase):
    """What the literal-sigil refusal is measured against."""

    def test_the_vocabulary_is_read_off_both_shipped_bundles(self):
        vocabulary = renderer.workflow_vocabulary(REPO_ROOT)
        self.assertEqual(
            vocabulary,
            plugin_bundle_gate.tracked_command_names(REPO_ROOT, CLAUDE_COMMANDS_PREFIX)
            | plugin_bundle_gate.tracked_skill_names(REPO_ROOT, CODEX_SKILLS_PREFIX)
            | {entry.name for entry in renderer.COMMAND_SOURCES},
        )
        # Non-vacuous: the names a vendored command will really cross-reference
        # are in it, so a literal /solve in a source is refused rather than
        # rendered into a Codex skill.
        self.assertLessEqual({"solve", "pr-review", "repair"}, vocabulary)

    def test_a_missing_bundle_directory_raises_rather_than_shrinking(self):
        # The fail-closed half: an empty vocabulary would disable the refusal
        # while every render still reported success.
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(renderer.CommandSourceError) as raised:
                renderer.workflow_vocabulary(root)
            self.assertIn(renderer.CLAUDE_COMMANDS_DIR, str(raised.exception))
            (root / renderer.CLAUDE_COMMANDS_DIR).mkdir(parents=True)
            with self.assertRaises(renderer.CommandSourceError) as raised:
                renderer.workflow_vocabulary(root)
            self.assertIn(renderer.CODEX_SKILLS_DIR, str(raised.exception))

    def test_a_shipped_workflow_written_literally_is_refused_without_a_directive(self):
        # The failure a file-local vocabulary could not see: the author never
        # writes the directive at all, so nothing in the source itself hints
        # that `repair` is a workflow.
        source = SYNTHETIC.replace("Trailing paragraph.", "Then hand off to /repair.")
        vocabulary = renderer.workflow_vocabulary(REPO_ROOT)
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude", vocabulary=vocabulary)
        self.assertIn("/repair", str(raised.exception))


class InvocationSigilTests(unittest.TestCase):
    """Requirement 2's substantive half and the review's boundary amendment:
    invocations are rewritten in body prose, and nothing else is."""

    def setUp(self):
        self.claude = read(FIXTURE_CLAUDE_OUTPUT)
        self.codex = read(FIXTURE_CODEX_OUTPUT)
        self.grok = read(FIXTURE_GROK_OUTPUT)
        self.claude_body = body_of(self.claude)
        self.codex_body = body_of(self.codex)
        self.grok_body = body_of(self.grok)

    def test_the_sigil_is_rewritten_in_body_prose_not_frontmatter_alone(self):
        # The failure this guards is a renderer that rewrites keys and paths
        # and ships a Codex skill telling its reader to type /solve.
        self.assertIn("/autosolve drives /solve, /pr-review", self.claude_body)
        self.assertIn("$autosolve drives $solve, $pr-review", self.codex_body)
        self.assertIn("/autosolve drives /solve, /pr-review", self.grok_body)
        self.assertNotIn("/autosolve", self.codex_body)
        self.assertNotIn("$autosolve", self.claude_body)
        self.assertNotIn("$autosolve", self.grok_body)

    def test_cross_command_references_are_rewritten_for_both_brands(self):
        source = read(FIXTURE_SOURCE)
        referenced = renderer.referenced_names(source)
        # Grounded in D-4's list rather than whatever the fixture happens to
        # say, so thinning the fixture fails here.
        self.assertLessEqual(
            {"solve", "pr-review", "pr-rereview", "finalize", "issue", "drain-prs", "triage"},
            referenced,
        )
        for name in sorted(referenced):
            self.assertIn(f"/{name}", self.claude, name)
            self.assertIn(f"${name}", self.codex, name)
            self.assertIn(f"/{name}", self.grok, name)

    def test_neither_file_carries_the_other_brands_sigil_for_a_workflow(self):
        referenced = renderer.referenced_names(read(FIXTURE_SOURCE))
        # Scanned with the boundary-aware pattern, which is what an invocation
        # in body text really looks like: the fixture deliberately carries
        # `$solve_result` and `/solve/cache`, and neither is a leaked sigil.
        for text, wrong in ((self.claude, "$"), (self.codex, "/"), (self.grok, "$")):
            found = {
                match.group(1)
                for match in renderer.LITERAL_INVOCATION_PATTERNS[wrong].finditer(text)
            }
            self.assertEqual(found & referenced, set(), f"{wrong} leaked")

    def test_every_non_invocation_survives_both_renderings_unchanged(self):
        for fragment in NON_INVOCATIONS:
            self.assertIn(fragment, self.claude, fragment)
            self.assertIn(fragment, self.codex, fragment)
            self.assertIn(fragment, self.grok, fragment)

    def test_a_literal_slash_invocation_is_refused(self):
        source = SYNTHETIC.replace("Invoke {{cmd:solve}}", "Invoke /solve")
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn("/solve", str(raised.exception))
        self.assertIn("{{cmd:solve}}", str(raised.exception))

    def test_a_literal_dollar_invocation_is_refused(self):
        source = SYNTHETIC.replace("Invoke {{cmd:solve}}", "Invoke $solve")
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "codex")
        self.assertIn("$solve", str(raised.exception))

    def test_a_literal_reference_to_the_sources_own_name_is_refused(self):
        source = SYNTHETIC.replace("Trailing paragraph.", "Run /synthetic again.")
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn("/synthetic", str(raised.exception))

    def test_the_refusal_is_targeted_rather_than_a_blanket_slash_ban(self):
        # The other half of the boundary: a path, a URL and a shell variable
        # are not invocations, so a source carrying them renders.
        source = SYNTHETIC.replace(
            "Trailing paragraph.",
            "Read /dev/null, /tmp/scratch, https://github.com/coghex/kanban and $REPO.",
        )
        for brand in renderer.BRANDS:
            rendered = render_text(source, brand)
            self.assertIn("/dev/null", rendered)
            self.assertIn("/tmp/scratch", rendered)
            self.assertIn("https://github.com/coghex/kanban", rendered)
            self.assertIn("$REPO", rendered)

    def test_a_workflow_named_path_component_is_not_an_invocation(self):
        # Round 1 blocker: `/solve/cache` is an absolute path whose first
        # component happens to be a workflow name, and the refusal must not
        # fire on it. Asserted for a hyphenated name too, since that is the
        # spelling the name pattern consumes greedily.
        source = SYNTHETIC.replace(
            "Trailing paragraph.",
            "Cache under /solve/cache, read /solve.md, and /pr-review/scripts/x.py.",
        )
        vocabulary = renderer.workflow_vocabulary(REPO_ROOT)
        for brand in renderer.BRANDS:
            rendered = render_text(source, brand, vocabulary=vocabulary)
            self.assertIn("/solve/cache", rendered)
            self.assertIn("/solve.md", rendered)
            self.assertIn("/pr-review/scripts/x.py", rendered)

    def test_a_variable_whose_name_starts_with_a_workflow_is_not_an_invocation(self):
        # The `$` half of the same blocker: `$solve_result` is a shell variable.
        source = SYNTHETIC.replace(
            "Trailing paragraph.", "Read $solve_result and $pr-review2 afterwards."
        )
        vocabulary = renderer.workflow_vocabulary(REPO_ROOT)
        for brand in renderer.BRANDS:
            rendered = render_text(source, brand, vocabulary=vocabulary)
            self.assertIn("$solve_result", rendered)
            self.assertIn("$pr-review2", rendered)

    def test_the_boundary_still_refuses_a_real_literal_invocation(self):
        # The other side of the same boundary: tightening it must not turn the
        # refusal off for the spellings prose actually uses.
        vocabulary = renderer.workflow_vocabulary(REPO_ROOT)
        for phrase in (
            "Run /solve.",
            "Run `/solve`, then stop.",
            "Run /solve",
            "Run $solve first.",
        ):
            source = SYNTHETIC.replace("Trailing paragraph.", phrase)
            with self.assertRaises(renderer.CommandSourceError, msg=phrase):
                render_text(source, "claude", vocabulary=vocabulary)

    def test_an_unsupported_directive_is_refused(self):
        source = SYNTHETIC.replace("{{cmd:solve}}", "{{command:solve}}")
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn("{{command:solve}}", str(raised.exception))

    def test_a_bad_directive_inside_an_elided_block_is_still_refused(self):
        # Validation reads the whole source, not the half one brand keeps:
        # otherwise the Claude render would pass and the Codex one would ship
        # literal braces.
        source = SYNTHETIC.replace(
            "Codex takes its argument from the prompt.",
            "Codex takes its argument from {{cmdsolve}}.",
        )
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn("{{cmdsolve}}", str(raised.exception))


class BrandBlockTests(unittest.TestCase):
    """Deliberate per-brand body adaptations stay in the one source."""

    def test_each_brand_keeps_only_its_own_variant(self):
        claude = render_text(SYNTHETIC, "claude")
        codex = render_text(SYNTHETIC, "codex")
        self.assertIn("Claude takes its argument from `$ARGUMENTS`.", claude)
        self.assertNotIn("Codex takes its argument", claude)
        self.assertIn("Codex takes its argument from the prompt.", codex)
        self.assertNotIn("Claude takes its argument", codex)

    def test_a_brand_the_block_does_not_name_receives_nothing_from_it(self):
        grok = render_text(SYNTHETIC, "grok")
        self.assertNotIn("takes its argument", grok)
        self.assertNotIn("\n\n\n", grok)

    def test_the_fixtures_third_brand_keeps_only_its_own_variants(self):
        grok = read(FIXTURE_GROK_OUTPUT)
        self.assertIn("which Grok substitutes", grok)
        self.assertIn("$GROK_PLUGIN_ROOT", grok)
        # The claude and codex variants of the same block, and the claude-only
        # block, contribute nothing to it.
        self.assertNotIn("CLAUDE_PLUGIN_ROOT", grok)
        self.assertNotIn("CODEX_HOME", grok)
        self.assertNotIn("This one is Claude's.", grok)
        for path in (FIXTURE_CLAUDE_OUTPUT, FIXTURE_CODEX_OUTPUT):
            self.assertNotIn("GROK", read(path), path)

    def test_no_marker_reaches_either_rendered_file(self):
        for path in FIXTURE_OUTPUTS.values():
            text = read(path)
            self.assertNotIn("<!-- brand:", text, path)
            self.assertNotIn("<!-- /brand -->", text, path)

    def test_a_single_brand_block_renders_as_nothing_for_the_other(self):
        source = textwrap.dedent(
            """\
            ---
            name: synthetic
            description: d
            ---

            Above.

            <!-- brand:claude -->
            Claude only.
            <!-- /brand -->

            Below.
            """
        )
        self.assertIn("Claude only.", render_text(source, "claude"))
        self.assertEqual(body_of(render_text(source, "codex")), "\nAbove.\n\nBelow.\n")

    def test_an_elided_block_after_a_paragraph_does_not_join_it_to_the_next(self):
        # The blank line above the block is what makes consuming the one below
        # it safe; without that guard these two paragraphs would run together.
        source = textwrap.dedent(
            """\
            ---
            name: synthetic
            description: d
            ---

            Above.
            <!-- brand:claude -->
            Claude only.
            <!-- /brand -->

            Below.
            """
        )
        self.assertEqual(body_of(render_text(source, "codex")), "\nAbove.\n\nBelow.\n")

    def test_the_fixtures_elided_block_leaves_no_double_blank_line(self):
        for path in FIXTURE_OUTPUTS.values():
            self.assertNotIn("\n\n\n", read(path), path)

    def test_an_unclosed_block_is_refused(self):
        source = SYNTHETIC.replace("<!-- /brand -->\n", "")
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn("never closed", str(raised.exception))

    def test_a_stray_close_is_refused(self):
        source = SYNTHETIC.replace(
            "Trailing paragraph.", "<!-- /brand -->\nTrailing paragraph."
        )
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn("closes no open brand block", str(raised.exception))

    def test_an_unknown_brand_is_refused(self):
        source = SYNTHETIC.replace("<!-- brand:codex -->", "<!-- brand:gemini -->")
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn("gemini", str(raised.exception))

    def test_a_repeated_brand_inside_one_block_is_refused(self):
        source = SYNTHETIC.replace("<!-- brand:codex -->", "<!-- brand:claude -->")
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn("twice", str(raised.exception))

    def test_an_error_names_the_line_it_is_on(self):
        source = SYNTHETIC.replace("<!-- brand:codex -->", "<!-- brand:gemini -->")
        expected = SYNTHETIC.splitlines().index("<!-- brand:codex -->") + 1
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "claude")
        self.assertIn(f":{expected}:", str(raised.exception))


class EntryBrandSetTests(unittest.TestCase):
    """Requirements 1 and 6: an entry renders exactly the brands it declares,
    and authored text for any other brand is an error rather than a no-op."""

    def test_an_entry_declaring_a_subset_renders_exactly_that_subset(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            plant_bundles(root)
            entry = synthetic_entry(brands=("claude", "grok"))
            source = root / entry.source
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(
                SYNTHETIC.replace("<!-- brand:codex -->", "<!-- brand:grok -->"),
                encoding="utf-8",
            )
            rendered = renderer.render_entry(entry, root)
            self.assertEqual(
                sorted(rendered),
                sorted(
                    [
                        "tools/out/claude/commands/synthetic.md",
                        "tools/out/grok/skills/synthetic/SKILL.md",
                    ]
                ),
            )
            with mock.patch.object(renderer, "COMMAND_SOURCES", (entry,)):
                renderer.write_all(root)
            self.assertFalse((root / "tools/out/codex").exists())

    def test_rendering_an_undeclared_brand_is_refused(self):
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(SYNTHETIC.replace(
                "<!-- brand:codex -->\nCodex takes its argument from the prompt.\n", ""
            ), "codex", brands=("claude",))
        self.assertIn("'codex' is not a brand this source renders", str(raised.exception))

    def test_a_block_naming_a_registered_but_undeclared_brand_is_refused(self):
        # codex is in the brand table, so only the entry's own set can refuse
        # it -- and it must, for every brand the entry does render.
        for brand in ("claude", "grok"):
            with self.assertRaises(renderer.CommandSourceError, msg=brand) as raised:
                render_text(SYNTHETIC, brand, brands=("claude", "grok"))
            message = str(raised.exception)
            self.assertIn("'codex' is not one this source renders", message)
            expected = SYNTHETIC.splitlines().index("<!-- brand:codex -->") + 1
            self.assertIn(f":{expected}:", message)

    def test_the_same_block_renders_when_the_brand_is_declared(self):
        # The control for the refusal above: the refusal is the entry's set,
        # not the brand.
        rendered = render_text(SYNTHETIC, "claude", brands=("claude", "codex"))
        self.assertIn("Claude takes its argument", rendered)

    def test_an_entry_naming_an_unregistered_brand_is_refused(self):
        entry = renderer.CommandSource(
            name="synthetic",
            source="tools/command_sources/synthetic.md",
            outputs={"claude": "tools/out/claude/commands", "gemini": "tools/out/gemini"},
            note="synthetic test entry",
        )
        with self.assertRaises(renderer.CommandSourceError) as raised:
            renderer.output_paths(entry)
        self.assertIn("gemini", str(raised.exception))

    def test_two_brands_rendering_to_one_path_are_refused(self):
        # Round 1 blocker: codex and grok share the skill-directory layout, so
        # one directory for both would collapse two declared outputs into one
        # file. The collision is an authoring error, not a lost output.
        entry = renderer.CommandSource(
            name="synthetic",
            source="tools/command_sources/synthetic.md",
            outputs={
                "claude": "tools/out/claude/commands",
                "codex": "tools/out/skills",
                "grok": "tools/out/skills",
            },
            note="synthetic test entry",
        )
        with self.assertRaises(renderer.CommandSourceError) as raised:
            renderer.output_paths(entry)
        message = str(raised.exception)
        self.assertIn("'codex' and 'grok'", message)
        self.assertIn("tools/out/skills/synthetic/SKILL.md", message)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            plant_bundles(root)
            source = root / entry.source
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(SYNTHETIC, encoding="utf-8")
            with self.assertRaises(renderer.CommandSourceError):
                renderer.render_entry(entry, root)
            with mock.patch.object(renderer, "COMMAND_SOURCES", (entry,)):
                with self.assertRaises(renderer.CommandSourceError):
                    renderer.check_all(root)

    def test_brands_sharing_a_layout_in_distinct_directories_render_both(self):
        # The control: sharing a layout is fine, sharing a path is not.
        paths = renderer.output_paths(synthetic_entry(brands=("codex", "grok")))
        self.assertEqual(len(set(paths.values())), 2, paths)

    def test_an_entry_declaring_no_brand_is_refused(self):
        entry = synthetic_entry(brands=())
        with self.assertRaises(renderer.CommandSourceError):
            renderer.output_paths(entry)


EXTERNAL_BRANDS = ("grok", "kimi", "google")


class SharedVariantTests(unittest.TestCase):
    """Issue #717: one variant a block gives several brands at once."""

    SOURCE = textwrap.dedent(
        """\
        ---
        name: synthetic
        description: d
        ---

        <!-- brand:grok -->
        Grok's own text.
        <!-- brand:kimi,google -->
        The Copilot pair's text.
        <!-- /brand -->
        """
    )

    def test_every_named_brand_keeps_the_shared_variant(self):
        for brand in ("kimi", "google"):
            rendered = render_text(self.SOURCE, brand, brands=EXTERNAL_BRANDS)
            self.assertIn("The Copilot pair's text.", rendered, brand)
            self.assertNotIn("Grok's own text.", rendered, brand)
        grok = render_text(self.SOURCE, "grok", brands=EXTERNAL_BRANDS)
        self.assertIn("Grok's own text.", grok)
        self.assertNotIn("Copilot", grok)

    def test_a_brand_repeated_across_variants_is_refused(self):
        source = self.SOURCE.replace("<!-- brand:grok -->", "<!-- brand:grok,kimi -->")
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "grok", brands=EXTERNAL_BRANDS)
        self.assertIn("'kimi' appears twice", str(raised.exception))

    def test_every_name_in_a_shared_marker_is_checked(self):
        # The second name is the one at fault, so a check reading only the
        # first would pass.
        for name, expected in (
            ("gemini", "unknown brand 'gemini'"),
            ("claude", "'claude' is not one this source renders"),
        ):
            source = self.SOURCE.replace("brand:kimi,google", f"brand:kimi,{name}")
            with self.assertRaises(renderer.CommandSourceError, msg=name) as raised:
                render_text(source, "grok", brands=EXTERNAL_BRANDS)
            self.assertIn(expected, str(raised.exception))


class BrandTokenTests(unittest.TestCase):
    """Issue #717: per-brand values a source references by name."""

    SOURCE = textwrap.dedent(
        """\
        ---
        name: synthetic
        description: Opens a {{brand:name}}-origin PR, never imitating a {{brand:predecessors}} one.
        ---

        This session is {{brand:title}}. Prefer `${{brand:upper}}_PLUGIN_ROOT`,
        spelled `"${{{brand:upper}}_PLUGIN_ROOT:-}"` in shell, and stamp
        `<!-- pr-origin:{{brand:name}} -->`.
        """
    )

    def test_each_form_renders_its_brands_value(self):
        kimi = render_text(self.SOURCE, "kimi", brands=EXTERNAL_BRANDS)
        self.assertIn("This session is Kimi.", kimi)
        self.assertIn("`$KIMI_PLUGIN_ROOT`", kimi)
        self.assertIn('`"${KIMI_PLUGIN_ROOT:-}"`', kimi)
        self.assertIn("`<!-- pr-origin:kimi -->`", kimi)
        self.assertNotIn("{{", kimi)

    def test_tokens_render_in_frontmatter_too(self):
        google = render_text(self.SOURCE, "google", brands=EXTERNAL_BRANDS)
        self.assertIn(
            "description: Opens a google-origin PR, never imitating a Claude, "
            "Codex, Grok, or Kimi one.\n",
            google,
        )

    def test_predecessors_are_the_brands_declared_earlier_in_the_table(self):
        # The brands that existed when each was added, in that order -- not
        # every other brand, which would rewrite every external bundle.
        self.assertEqual(
            renderer.BRANDS, ("claude", "codex", "grok", "kimi", "google")
        )
        expected = {
            "codex": "Claude",
            "grok": "Claude or Codex",
            "kimi": "Claude, Codex, or Grok",
            "google": "Claude, Codex, Grok, or Kimi",
        }
        for brand, listed in expected.items():
            self.assertEqual(
                renderer.brand_token_value("predecessors", brand, origin="o"),
                listed,
                brand,
            )

    def test_the_first_brand_has_no_predecessors_to_enumerate(self):
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(self.SOURCE, "claude")
        self.assertIn("nothing to enumerate for 'claude'", str(raised.exception))

    def test_an_unknown_form_is_refused(self):
        source = self.SOURCE.replace("{{brand:title}}", "{{brand:display}}")
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "kimi", brands=EXTERNAL_BRANDS)
        self.assertIn("{{brand:display}}", str(raised.exception))

    def test_a_malformed_token_after_a_brace_is_still_refused(self):
        # The control for the shell-expansion spelling above: a directive
        # opening at the last brace of a run is still validated.
        source = self.SOURCE.replace("${{{brand:upper}}", "${{{brand:UPPER}}")
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "kimi", brands=EXTERNAL_BRANDS)
        self.assertIn("{{brand:UPPER}}", str(raised.exception))


class FrontmatterBrandBlockTests(unittest.TestCase):
    """Issue #717: a frontmatter value only some brands carry."""

    SOURCE = textwrap.dedent(
        """\
        ---
        name: synthetic
        <!-- brand:grok -->
        description: Grok's description.
        <!-- brand:kimi,google -->
        description: The Copilot pair's description.
        <!-- /brand -->
        argument-hint: "[issue number]"
        ---

        Body.
        """
    )

    def test_each_brand_declares_its_own_variant_once(self):
        grok = render_text(self.SOURCE, "grok", brands=EXTERNAL_BRANDS)
        self.assertEqual(
            frontmatter_lines(grok),
            [
                "name: synthetic",
                "description: Grok's description.",
                'argument-hint: "[issue number]"',
            ],
        )
        kimi = render_text(self.SOURCE, "kimi", brands=EXTERNAL_BRANDS)
        self.assertEqual(
            frontmatter_lines(kimi),
            ["name: synthetic", "description: The Copilot pair's description."],
        )

    def test_a_brand_left_without_a_required_key_is_refused(self):
        source = self.SOURCE.replace(
            "<!-- brand:kimi,google -->", "<!-- brand:kimi -->"
        )
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "google", brands=EXTERNAL_BRANDS)
        self.assertIn("must declare description", str(raised.exception))

    def test_a_frontmatter_error_names_its_source_line(self):
        source = self.SOURCE.replace(
            "description: The Copilot pair's description.", "model: opus"
        )
        expected = source.splitlines().index("model: opus") + 1
        with self.assertRaises(renderer.CommandSourceError) as raised:
            render_text(source, "kimi", brands=EXTERNAL_BRANDS)
        message = str(raised.exception)
        self.assertIn("unsupported frontmatter key 'model'", message)
        self.assertIn(f":{expected}:", message)


class IdempotenceTests(unittest.TestCase):
    """Requirement 3: rendering is a function of the source alone."""

    def test_rendering_twice_produces_identical_text(self):
        source = read(FIXTURE_SOURCE)
        entry = {item.name: item for item in renderer.COMMAND_SOURCES}["fixture-command"]
        vocabulary = renderer.workflow_vocabulary(REPO_ROOT)
        for brand in renderer.output_paths(entry):
            first = renderer.render(entry, source, brand, vocabulary)
            self.assertEqual(first, renderer.render(entry, source, brand, vocabulary))

    def test_rendering_a_rendered_tree_again_changes_nothing(self):
        rendered = renderer.render_all(REPO_ROOT)
        self.assertEqual(rendered, renderer.render_all(REPO_ROOT))
        for path, text in rendered.items():
            self.assertEqual(read(path), text, path)

    def test_every_rendered_file_ends_with_exactly_one_newline(self):
        for text in renderer.render_all(REPO_ROOT).values():
            self.assertTrue(text.endswith("\n"))
            self.assertFalse(text.endswith("\n\n"))


if __name__ == "__main__":
    unittest.main()
