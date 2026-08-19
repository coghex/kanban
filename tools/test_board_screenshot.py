"""Checks for tools/render_board_screenshot.py and the asset it produces.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 -m unittest tools.test_board_screenshot

The screenshot's value is that it is derived, not captured: `docs/media`'s
procedure has to produce the checked-in bytes again from the golden frame. Only
part of that is checkable everywhere. Turning the frame into cells and colours
is pure text handling and is tested here in full; turning cells into pixels
needs Pillow and the pinned DejaVu files, which the CI job that runs this suite
installs neither of, so those cases state the missing prerequisite and skip
rather than pretending to cover it or failing the build.

What the skipping cases would catch is still worth stating: the twice-run
acceptance check in the procedure is a manual gate, so the deterministic half
below is what stands between a frame change and a stale screenshot.
"""

import importlib.util
import re
import struct
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def _renderer():
    """tools/render_board_screenshot.py, loaded by path under a private name.

    Loaded the way tools/test_document_classification.py loads its subject, and
    for the same reason: this module has to import the same file whether
    unittest discovered it as a bare top-level name (`discover -s tools`) or
    inside the `tools.` namespace package.
    """
    source = REPO_ROOT / "tools" / "render_board_screenshot.py"
    spec = importlib.util.spec_from_file_location("_kanban_board_screenshot", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


renderer = _renderer()

# A three-cell-wide, two-row frame in the exact shape Spec.Support.Golden
# writes: legend entries, a bare terminator, then one token per cell.
FIXTURE_ATTRIBUTES = (
    "# .  fore=default back=default style=default\n"
    "# a  fore=brightCyan back=default style=bold\n"
    "#\n"
    "a..\n"
    "..a\n"
)
FIXTURE_CHARACTERS = "x\nyz\n"

# Markdown image syntax, which is what the packaged-link check in
# tools/test_source_distribution.py can actually see.
README_IMAGE = re.compile(r"!\[(?P<alt>[^\]\n]*)\]\((?P<target>[^)\s]+)\)")


def _rendering_gap():
    """Why the pixel-level cases cannot run here, or None when they can."""
    try:
        import PIL  # noqa: F401
    except ImportError:
        return (
            "Pillow is not installed, so the golden frame cannot be "
            "rasterised; the required CI job installs GHC and Cabal only."
        )
    try:
        renderer.load_fonts()
    except renderer.RenderError as error:
        return str(error)
    return None


class FrameParsingTests(unittest.TestCase):
    """The half of the procedure that needs no renderer: the golden frame's
    two files becoming a grid of cells."""

    def setUp(self):
        self.frame = renderer.read_frame()

    def test_the_board_wide_frame_parses_to_a_rectangular_grid(self):
        self.assertEqual(self.frame.height, 64)
        self.assertEqual(self.frame.width, 200)
        self.assertEqual({len(row) for row in self.frame.characters}, {200})
        self.assertEqual({len(row) for row in self.frame.attributes}, {200})

    def test_every_attribute_token_the_grid_uses_has_a_legend_entry(self):
        used = {token for row in self.frame.attributes for token in row}
        self.assertEqual(used - set(self.frame.legend), set())

    def test_a_stripped_character_row_is_padded_rather_than_zipped(self):
        # Spec.UI.Golden writes the character golden through Data.Text.stripEnd,
        # so a row whose frame ends in blanks arrives short. Zipping it against
        # the attribute grid would drop that row's right-hand cells; today every
        # board-wide row happens to end at the shell border, so the bug would
        # stay invisible until some later frame change.
        frame = renderer.parse_frame(FIXTURE_CHARACTERS, FIXTURE_ATTRIBUTES)
        self.assertEqual(frame.characters, ["x  ", "yz "])
        self.assertEqual(frame.width, 3)

    def test_a_character_row_wider_than_the_attribute_grid_is_rejected(self):
        with self.assertRaises(renderer.RenderError) as caught:
            renderer.parse_frame("xxxx\nyz\n", FIXTURE_ATTRIBUTES)
        self.assertIn("past the attribute grid", str(caught.exception))

    def test_frames_that_disagree_on_height_are_rejected(self):
        with self.assertRaises(renderer.RenderError) as caught:
            renderer.parse_frame("x\n", FIXTURE_ATTRIBUTES)
        self.assertIn("disagree on height", str(caught.exception))

    def test_a_token_with_no_legend_entry_is_rejected(self):
        attributes = FIXTURE_ATTRIBUTES.replace("..a\n", "..b\n")
        with self.assertRaises(renderer.RenderError) as caught:
            renderer.parse_frame(FIXTURE_CHARACTERS, attributes)
        self.assertIn("its legend does not define", str(caught.exception))

    def test_a_ragged_attribute_grid_is_rejected(self):
        attributes = FIXTURE_ATTRIBUTES.replace("..a\n", "..a.\n")
        with self.assertRaises(renderer.RenderError) as caught:
            renderer.parse_frame(FIXTURE_CHARACTERS, attributes)
        self.assertIn("ragged", str(caught.exception))

    def test_a_grid_with_no_legend_terminator_is_rejected(self):
        with self.assertRaises(renderer.RenderError) as caught:
            renderer.parse_frame(
                "x\n", "# .  fore=default back=default style=default\n"
            )
        self.assertIn("no legend terminator", str(caught.exception))


class PinnedColourTests(unittest.TestCase):
    """A Vty attribute names a palette slot. These are the cases where an
    unpinned slot would otherwise be drawn in whatever the renderer felt like."""

    def test_every_attribute_the_frame_uses_resolves_to_a_pinned_colour(self):
        # read_frame() resolves as it parses, so reaching here at all is the
        # assertion; the loop states what was resolved.
        frame = renderer.read_frame()
        for token, attribute in sorted(frame.legend.items()):
            for role, colour in (
                ("foreground", attribute.foreground),
                ("background", attribute.background),
            ):
                self.assertEqual(len(colour), 3, f"{token} {role}")
                for channel in colour:
                    self.assertIn(channel, range(256), f"{token} {role}")

    def test_an_unpinned_colour_name_is_refused_rather_than_substituted(self):
        with self.assertRaises(renderer.RenderError) as caught:
            renderer.resolve_colour("chartreuse", "white")
        self.assertIn("no pinned RGB value", str(caught.exception))

    def test_a_style_the_renderer_cannot_draw_is_refused(self):
        attributes = FIXTURE_ATTRIBUTES.replace(
            "style=bold\n", "style=bold+underline\n"
        )
        with self.assertRaises(renderer.RenderError) as caught:
            renderer.parse_frame(FIXTURE_CHARACTERS, attributes)
        self.assertIn("underline", str(caught.exception))

    def test_the_cube_index_the_theme_produces_is_the_tracker_purple(self):
        # Kanban.UI.Theme asks Vty for rgbColor 128 90 213 and Vty quantises it
        # into the 240-colour cube, which is why the attribute grid records
        # color240:82. Turning that index back into a colour has to land on the
        # cube entry the theme meant, not somewhere else in the cube.
        purple = renderer.cube_colour(82)
        self.assertEqual(purple, (0x87, 0x5F, 0xD7))
        for asked, got in zip((128, 90, 213), purple):
            self.assertLess(abs(asked - got), 16)

    def test_the_grey_ramp_and_cube_cover_the_whole_240_range(self):
        self.assertEqual(renderer.cube_colour(0), (0x00, 0x00, 0x00))
        self.assertEqual(renderer.cube_colour(215), (0xFF, 0xFF, 0xFF))
        self.assertEqual(renderer.cube_colour(216), (0x08,) * 3)
        self.assertEqual(renderer.cube_colour(239), (0xEE,) * 3)
        with self.assertRaises(renderer.RenderError):
            renderer.cube_colour(240)

    def test_both_default_slots_are_pinned_palette_entries(self):
        self.assertIn(renderer.DEFAULT_FOREGROUND, renderer.PALETTE)
        self.assertIn(renderer.DEFAULT_BACKGROUND, renderer.PALETTE)


class CheckedInScreenshotTests(unittest.TestCase):
    """The tracked asset, held to the frame it claims to be. Reads the PNG
    header with the standard library, so this runs wherever the tests do."""

    def setUp(self):
        self.path = REPO_ROOT / renderer.SCREENSHOT
        self.assertTrue(
            self.path.is_file(), f"{renderer.SCREENSHOT} is not checked in"
        )
        self.data = self.path.read_bytes()

    def test_the_screenshot_has_the_frame_dimensions_at_the_pinned_cell_size(self):
        frame = renderer.read_frame()
        self.assertEqual(
            renderer.png_dimensions(self.data),
            (
                frame.width * renderer.CELL_WIDTH,
                frame.height * renderer.CELL_HEIGHT,
            ),
        )

    def test_the_screenshot_carries_no_timestamp_or_host_specific_chunk(self):
        # Requirement 7's other half: bytes that vary with when or where the
        # image was made would show up as a diff on every regeneration.
        present = []
        position = 8
        while position + 8 <= len(self.data):
            length, kind = struct.unpack(">I4s", self.data[position : position + 8])
            present.append(kind.decode("ascii", "replace"))
            position += 12 + length
        self.assertEqual(
            sorted(set(present) & {"tIME", "tEXt", "iTXt", "zTXt", "pHYs", "eXIf"}),
            [],
        )
        self.assertEqual(present[0], "IHDR")
        self.assertEqual(present[-1], "IEND")


class ReadmeReferenceTests(unittest.TestCase):
    """The media slot, filled. `tools/test_source_distribution.py` checks that
    the target resolves inside the archive; what it cannot check is that the
    reference is there at all, in a form that check can see."""

    def setUp(self):
        self.readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")

    def test_the_readme_shows_the_screenshot_exactly_once(self):
        references = [
            match
            for match in README_IMAGE.finditer(self.readme)
            if match.group("target") == renderer.SCREENSHOT
        ]
        self.assertEqual(
            len(references),
            1,
            f"README.md must carry exactly one image reference to "
            f"{renderer.SCREENSHOT}",
        )
        alt = references[0].group("alt")
        self.assertNotEqual(alt.strip(), "")
        self.assertNotIn(
            Path(renderer.SCREENSHOT).name,
            alt,
            "the alt text must describe the board, not repeat the filename",
        )

    def test_no_placeholder_is_left_behind(self):
        self.assertNotIn("PUB-3 media slot", self.readme)

    def test_the_reference_is_markdown_rather_than_html(self):
        # The packaged-link check matches bracket-paren links and never an
        # <img src=...>, so an HTML reference would pass that check vacuously.
        self.assertNotIn(renderer.SCREENSHOT, re.sub(README_IMAGE, "", self.readme))


class RegenerationProcedureTests(unittest.TestCase):
    """The procedure document, reconciled with the module it documents. The
    pinned environment is only pinned while both statements of it agree."""

    def setUp(self):
        self.procedure = (REPO_ROOT / "docs/media/README.md").read_text(
            encoding="utf-8"
        )

    def test_the_procedure_names_the_pinned_font(self):
        self.assertIn(renderer.FONT_RELEASE, self.procedure)
        self.assertIn(renderer.FONT_ARCHIVE, self.procedure)
        for filename, digest in renderer.FONT_FILES.values():
            self.assertIn(filename, self.procedure)
            self.assertIn(digest, self.procedure)

    def test_the_procedure_names_the_sources_the_command_and_the_output(self):
        frame = renderer.read_frame()
        for named in (
            renderer.FRAME_CHARACTERS,
            renderer.FRAME_ATTRIBUTES,
            renderer.SCREENSHOT,
            "tools/render_board_screenshot.py",
            f"{frame.width}x{frame.height}",
            f"{frame.width * renderer.CELL_WIDTH}x"
            f"{frame.height * renderer.CELL_HEIGHT}",
        ):
            self.assertIn(named, self.procedure, f"the procedure never names {named}")


class RenderingTests(unittest.TestCase):
    """The pixel half. Skipped, with the missing prerequisite named, wherever
    Pillow or the pinned fonts are not installed."""

    @classmethod
    def setUpClass(cls):
        gap = _rendering_gap()
        if gap is not None:
            raise unittest.SkipTest(gap)
        cls.faces = renderer.load_fonts()

    def test_the_pinned_cell_geometry_still_fits_the_pinned_font(self):
        renderer.verify_cell_geometry(self.faces)

    def test_every_glyph_the_frame_draws_exists_and_fits_its_cell(self):
        # Also the acceptance criterion that no text is clipped by the image
        # boundary: a glyph that fits its cell cannot reach past the frame.
        renderer.verify_glyph_coverage(renderer.read_frame(), self.faces)

    def test_a_glyph_the_font_lacks_is_refused_rather_than_boxed(self):
        frame = renderer.parse_frame(
            "\ue000\n\ue000\n",
            "# .  fore=default back=default style=default\n#\n.\n.\n",
        )
        with self.assertRaises(renderer.RenderError) as caught:
            renderer.verify_glyph_coverage(frame, self.faces)
        self.assertIn("rendered as empty boxes", str(caught.exception))

    def test_rendering_the_frame_reproduces_the_checked_in_screenshot(self):
        rendered = renderer.encode(renderer.render(renderer.read_frame(), self.faces))
        checked_in = (REPO_ROOT / renderer.SCREENSHOT).read_bytes()
        self.assertEqual(
            len(rendered),
            len(checked_in),
            "re-rendering the golden frame no longer reproduces "
            f"{renderer.SCREENSHOT}. Regenerate it with "
            "tools/render_board_screenshot.py and review the diff.",
        )
        self.assertEqual(rendered, checked_in)

    def test_rendering_is_byte_stable_across_runs(self):
        frame = renderer.read_frame()
        first = renderer.encode(renderer.render(frame, self.faces))
        second = renderer.encode(renderer.render(frame, self.faces))
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
