"""Render the checked-in board screenshot from the `board-wide` golden frame.

Run with: python3 tools/render_board_screenshot.py
      or: python3 tools/render_board_screenshot.py --check

`docs/media/README.md` is the procedure this module implements; read it for the
prerequisite, the comparison step, and how to review an intentional change.

The screenshot has to be reproducible, carry no live repository data, and stay
versioned with the UI it depicts, so it is derived from the same terminal-free
artifact the golden-frame suite already checks in rather than captured from a
running board. `test/golden/board-wide.txt` holds the 200x64 grid of characters
and `test/golden/board-wide.attrs` holds the Vty attribute of every one of
those cells; between them they are a complete description of the frame, and
they contain only `Kanban.Fixture`'s invented board.

Two things that grid does not fix, this module does:

* A Vty attribute names a terminal palette slot, not a colour. `PALETTE` below
  pins one RGB value per slot the frame uses, so "meaningful colours" is a
  property of this file rather than of whichever terminal last drew the board.
* A terminal snaps box-drawing glyphs to the character cell. Nothing here can,
  so the geometry is chosen instead: at `FONT_SIZE`, DejaVu Sans Mono draws
  `|` from 25 pixels above the baseline to 5 below it, which is exactly
  `CELL_HEIGHT` rows when the baseline sits at `TEXT_BASELINE` inside the cell,
  and draws `-` one pixel past each side of a `CELL_WIDTH` cell. Vertical rules
  therefore meet across rows and horizontal rules across columns.
  `verify_cell_geometry` re-derives both from the loaded font on every run and
  fails rather than emitting a frame drawn with dashed borders.

Determinism is what makes a regenerated image comparable with the checked-in
one, so every input is pinned and every unpinned one is refused:

* The fonts are located by path, never by family name, and checked against
  `FONT_FILES`' SHA-256 digests, so a differently-versioned DejaVu or a
  same-named substitute is an error instead of a silently different image.
* Glyphs are rasterised with antialiasing off, so a cell is one of the pinned
  palette entries and never a blend of two of them.
* The output is a paletted PNG carrying no timestamp, no text chunk, and no
  host path.

The rasteriser itself is the one input that cannot be pinned from here: Pillow
and its bundled FreeType decide how an outline becomes pixels. `docs/media`'s
procedure records the versions the checked-in asset was produced with, and the
comparison step is what reports a rasteriser that disagrees. That divergence
is real -- issue #422's evidence run rendered different bytes on the CI runner
from the same pinned inputs -- which is why the pixel comparison cannot be the
gate that keeps the image fresh in required CI.

What can is the provenance record beside the image:
`docs/media/board-wide.provenance` holds the SHA-256 of both golden files and
of the image itself, one `sha256sum`-format line per file, and every
regeneration run rewrites it. Verifying the record needs no rasteriser, so
`tools/test_board_screenshot.py` holds it against the tracked files everywhere
the suite runs -- the required CI job included -- and a golden-frame change
that does not regenerate the screenshot fails the build instead of going
stale. What the record cannot prove is that the image's pixels are what this
module produces; only a rasteriser can, which is what the local rendering
cases and the comparison step remain for.
"""

import argparse
import hashlib
import io
import os
import re
import struct
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The golden frame this screenshot is derived from. The attribute grid is
# authoritative for the frame's shape: `Spec.UI.Golden` writes the character
# golden through `Data.Text.stripEnd`, so a row of it ending in blanks is
# shorter than the frame is wide, while `attributeGrid` never strips.
FRAME_CHARACTERS = "test/golden/board-wide.txt"
FRAME_ATTRIBUTES = "test/golden/board-wide.attrs"

SCREENSHOT = "docs/media/board-wide.png"

# The record binding the image to what it was rendered from: the two golden
# files and the image itself, each by SHA-256. Rewritten by every regeneration
# run, verified with no rasteriser, so required CI can hold the image fresh
# even though it cannot reproduce the pixels (see the module docstring).
PROVENANCE = "docs/media/board-wide.provenance"
PROVENANCE_SUBJECTS = (FRAME_CHARACTERS, FRAME_ATTRIBUTES, SCREENSHOT)
PROVENANCE_LINE = re.compile(r"^(?P<digest>[0-9a-f]{64})  (?P<path>\S.*)$")

# One character cell, in pixels, and the baseline inside it. See the module
# docstring: these three are a single choice, and `verify_cell_geometry`
# rejects a font that does not honour it.
CELL_WIDTH = 16
CELL_HEIGHT = 31
FONT_SIZE = 26
TEXT_BASELINE = 25

# DejaVu Sans Mono is pinned by release and by content digest. It is the
# monospace family in wide distribution that covers every glyph the frame
# draws -- box drawing, block elements, arrows, and the geometric shapes the
# board uses for tracker and CI state -- so no fallback font is ever consulted.
FONT_RELEASE = "2.37"
FONT_ARCHIVE = "dejavu-fonts-ttf-2.37.tar.bz2"
FONT_DOWNLOAD = (
    "https://github.com/dejavu-fonts/dejavu-fonts/releases/download/"
    "version_2_37/dejavu-fonts-ttf-2.37.tar.bz2"
)
FONT_FILES = {
    "regular": (
        "DejaVuSansMono.ttf",
        "b4a6c3e4faab8773f4ff761d56451646409f29abedd68f05d38c2df667d3c582",
    ),
    "bold": (
        "DejaVuSansMono-Bold.ttf",
        "bce60f1b4421acd9ea51ba6623d7024ecbe6817a953e3654df62a5e6bdf8f769",
    ),
}

# Where the fonts are looked for when `--font-dir` is not given. Every entry is
# a directory that would hold an unpacked DejaVu release; none of them is
# consulted for a family name.
FONT_SEARCH_PATH = (
    "~/.local/share/fonts/dejavu",
    "~/Library/Fonts/dejavu",
    "/usr/share/fonts/truetype/dejavu",
    "/opt/homebrew/share/fonts/dejavu",
)

# The sixteen ANSI slots at xterm's default values. Vty names slots; a slot has
# no colour until something like this says what it is.
PALETTE = {
    "black": (0x00, 0x00, 0x00),
    "red": (0xCD, 0x00, 0x00),
    "green": (0x00, 0xCD, 0x00),
    "yellow": (0xCD, 0xCD, 0x00),
    "blue": (0x00, 0x00, 0xEE),
    "magenta": (0xCD, 0x00, 0xCD),
    "cyan": (0x00, 0xCD, 0xCD),
    "white": (0xE5, 0xE5, 0xE5),
    "brightBlack": (0x7F, 0x7F, 0x7F),
    "brightRed": (0xFF, 0x00, 0x00),
    "brightGreen": (0x00, 0xFF, 0x00),
    "brightYellow": (0xFF, 0xFF, 0x00),
    "brightBlue": (0x5C, 0x5C, 0xFF),
    "brightMagenta": (0xFF, 0x00, 0xFF),
    "brightCyan": (0x00, 0xFF, 0xFF),
    "brightWhite": (0xFF, 0xFF, 0xFF),
}

# The 6x6x6 cube and the 24 greys behind Vty's `Color240`, at the same xterm
# values. `Kanban.UI.Theme` asks for RGB and Vty quantises: the tracker purple
# `rgbColor 128 90 213` arrives in the attribute grid as `color240:82`, which
# these levels turn back into a colour.
CUBE_LEVELS = (0x00, 0x5F, 0x87, 0xAF, 0xD7, 0xFF)
GREY_LEVELS = tuple(0x08 + 10 * step for step in range(24))

# A terminal running the board has a foreground and a background before any
# attribute is applied, and the frame leaves most of its cells at exactly that.
# Kanban's themes are drawn for a dark terminal, so the two defaults are the
# palette's own black and white rather than a colour invented here.
DEFAULT_FOREGROUND = "white"
DEFAULT_BACKGROUND = "black"

# `Spec.Support.Golden.describeStyle` spells a cell's style as `default`,
# `none`, or `+`-joined names. Only boldness reaches a monospace rendering, so
# any other named style is refused rather than dropped.
SUPPORTED_STYLES = frozenset({"default", "none", "bold"})

LEGEND_ENTRY = re.compile(r"^# (?P<token>\S)  (?P<description>.+)$")
ATTRIBUTE_FIELD = re.compile(r"(?P<key>fore|back|style)=(?P<value>\S+)")

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class RenderError(Exception):
    """A pinned input is missing, unreadable, or not what it was pinned to."""


class Attribute:
    """One legend entry: the colours and weight a cell is drawn with."""

    __slots__ = ("foreground", "background", "bold")

    def __init__(self, foreground, background, bold):
        self.foreground = foreground
        self.background = background
        self.bold = bold


class Frame:
    """A golden frame as cells: `characters[row][column]` beside the
    `Attribute` that cell is drawn with."""

    def __init__(self, characters, attributes, legend):
        self.characters = characters
        self.attributes = attributes
        self.legend = legend

    @property
    def height(self):
        return len(self.characters)

    @property
    def width(self):
        return len(self.characters[0]) if self.characters else 0

    @property
    def default_background(self):
        return PALETTE[DEFAULT_BACKGROUND]


def cube_colour(index):
    """The RGB behind a Vty `Color240` index."""
    if not 0 <= index < 240:
        raise RenderError(f"color240:{index} is outside Vty's 240-colour range")
    if index < 216:
        return (
            CUBE_LEVELS[index // 36],
            CUBE_LEVELS[(index // 6) % 6],
            CUBE_LEVELS[index % 6],
        )
    return (GREY_LEVELS[index - 216],) * 3


def resolve_colour(name, default):
    """One `describeColor` spelling as RGB.

    Every spelling that reaches a pinned colour is handled and every other one
    is an error: an unrecognised slot drawn in some substitute colour is the
    failure this whole module exists to prevent.
    """
    if name == "default":
        return PALETTE[default]
    if name.startswith("color240:"):
        digits = name.split(":", 1)[1]
        if not digits.isdigit():
            raise RenderError(f"unreadable 240-colour index in {name!r}")
        return cube_colour(int(digits))
    if name in PALETTE:
        return PALETTE[name]
    raise RenderError(
        f"the attribute grid names the colour {name!r}, which has no pinned RGB "
        f"value in {Path(__file__).name}'s PALETTE. Add one before regenerating."
    )


def parse_attribute_grid(text):
    """`Spec.Support.Golden.attributeGrid`'s output: a legend of one token per
    attribute, a bare `#`, then one token per cell."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    legend = {}
    rows = None
    for index, line in enumerate(lines):
        if line == "#":
            rows = lines[index + 1 :]
            break
        entry = LEGEND_ENTRY.match(line)
        if entry is None:
            raise RenderError(f"unreadable attribute legend entry: {line!r}")
        fields = {
            match.group("key"): match.group("value")
            for match in ATTRIBUTE_FIELD.finditer(entry.group("description"))
        }
        missing = sorted({"fore", "back", "style"} - set(fields))
        if missing:
            raise RenderError(
                f"attribute legend entry {line!r} states no {', '.join(missing)}"
            )
        styles = set(fields["style"].split("+"))
        unsupported = sorted(styles - SUPPORTED_STYLES)
        if unsupported:
            raise RenderError(
                f"the attribute grid uses the text style {', '.join(unsupported)}, "
                "which this renderer does not draw. Teach it that style before "
                "regenerating, so the screenshot does not quietly drop it."
            )
        legend[entry.group("token")] = Attribute(
            foreground=resolve_colour(fields["fore"], DEFAULT_FOREGROUND),
            background=resolve_colour(fields["back"], DEFAULT_BACKGROUND),
            bold="bold" in styles,
        )
    if rows is None:
        raise RenderError("the attribute grid has no legend terminator line")
    if not rows:
        raise RenderError("the attribute grid states no cells")
    widths = {len(row) for row in rows}
    if len(widths) != 1:
        raise RenderError(
            f"the attribute grid is ragged: row widths {sorted(widths)}"
        )
    return legend, rows


def parse_frame(characters_text, attributes_text):
    """A `Frame` from the two golden files.

    The character golden is padded out to the attribute grid rather than zipped
    against it. `Spec.UI.Golden` strips each character row's trailing blanks, so
    zipping would silently drop the right-hand end of any row that ends in
    whitespace -- today no `board-wide` row does, which is exactly why that bug
    would not show up until some later frame change.
    """
    legend, attribute_rows = parse_attribute_grid(attributes_text)
    character_rows = characters_text.split("\n")
    if character_rows and character_rows[-1] == "":
        character_rows.pop()
    if len(character_rows) != len(attribute_rows):
        raise RenderError(
            f"the golden frame's two halves disagree on height: "
            f"{len(character_rows)} character rows against "
            f"{len(attribute_rows)} attribute rows"
        )
    width = len(attribute_rows[0])
    padded = []
    for index, row in enumerate(character_rows):
        if len(row) > width:
            raise RenderError(
                f"character row {index + 1} is {len(row)} cells wide, past the "
                f"attribute grid's {width}"
            )
        padded.append(row.ljust(width))
    unknown = sorted(
        {token for row in attribute_rows for token in row} - set(legend)
    )
    if unknown:
        raise RenderError(
            f"the attribute grid uses tokens its legend does not define: "
            f"{', '.join(unknown)}"
        )
    return Frame(padded, attribute_rows, legend)


def read_frame(repo_root=REPO_ROOT):
    """The checked-in `board-wide` frame."""
    characters = repo_root / FRAME_CHARACTERS
    attributes = repo_root / FRAME_ATTRIBUTES
    for source in (characters, attributes):
        if not source.is_file():
            raise RenderError(
                f"{source} is missing, so there is no golden frame to render. "
                "This command runs from a Kanban checkout or an unpacked "
                "release, both of which carry test/golden/."
            )
    return parse_frame(
        characters.read_text(encoding="utf-8"),
        attributes.read_text(encoding="utf-8"),
    )


def _font_directories(explicit):
    if explicit is not None:
        return [Path(explicit).expanduser()]
    return [Path(entry).expanduser() for entry in FONT_SEARCH_PATH]


def load_fonts(font_dir=None):
    """The two pinned faces, verified by digest.

    A font is never resolved by family name: a system lookup would answer with
    whichever DejaVu-alike is installed, and the whole point of pinning is that
    the answer cannot vary.
    """
    try:
        from PIL import ImageFont
    except ImportError as error:  # pragma: no cover - exercised by the skip path
        raise RenderError(
            f"Pillow is not installed ({error}), so the frame cannot be "
            "rasterised. See docs/media/README.md for the pinned version."
        ) from error

    directories = _font_directories(font_dir)
    faces = {}
    for weight, (filename, digest) in sorted(FONT_FILES.items()):
        found = next(
            (
                directory / filename
                for directory in directories
                if (directory / filename).is_file()
            ),
            None,
        )
        if found is None:
            searched = ", ".join(str(directory) for directory in directories)
            raise RenderError(
                f"{filename} was not found in {searched}. Unpack DejaVu "
                f"{FONT_RELEASE} ({FONT_ARCHIVE}, {FONT_DOWNLOAD}) once and "
                "pass --font-dir, or set KANBAN_SCREENSHOT_FONT_DIR."
            )
        actual = hashlib.sha256(found.read_bytes()).hexdigest()
        if actual != digest:
            raise RenderError(
                f"{found} is not the pinned DejaVu {FONT_RELEASE} file: its "
                f"SHA-256 is {actual}, not {digest}. Rendering with a "
                "different font would change the screenshot for reasons the "
                "repository does not record."
            )
        faces[weight] = ImageFont.truetype(str(found), FONT_SIZE)
    return faces


def _gap_in(inked):
    """The first index missing from an otherwise solid run, or None.

    A box glyph reaches a pixel past the left and top of its own cell, so a
    rule's ink is not aligned to the cell -- only unbroken across it. What
    matters is therefore contiguity, not which cell owns an end pixel.
    """
    if not inked:
        return 0
    missing = sorted(set(range(min(inked), max(inked) + 1)) - set(inked))
    return missing[0] if missing else None


def verify_cell_geometry(faces):
    """Prove the pinned geometry against the loaded font.

    The frame's borders are runs of box-drawing cells, so what has to hold is
    that two adjacent cells' rules meet: a vertical rule drawn in two stacked
    cells inks an unbroken column, and a horizontal rule drawn in two
    side-by-side cells inks an unbroken row. Both are read back off a real
    rasterisation rather than assumed, so a font or size that no longer fits
    the cell fails here instead of shipping a frame with dashed borders.
    """
    from PIL import Image, ImageDraw

    for weight, font in sorted(faces.items()):
        ascent = font.getmetrics()[0]
        if ascent != TEXT_BASELINE:
            raise RenderError(
                f"the {weight} face reports an ascent of {ascent} pixels at "
                f"size {FONT_SIZE}, not the pinned baseline {TEXT_BASELINE}"
            )

        stacked = Image.new("L", (CELL_WIDTH, 2 * CELL_HEIGHT), 0)
        draw = ImageDraw.Draw(stacked)
        draw.fontmode = "1"
        for cell in (0, 1):
            draw.text(
                (0, cell * CELL_HEIGHT + TEXT_BASELINE),
                "│",
                font=font,
                fill=255,
                anchor="ls",
            )
        pixels = stacked.load()
        rows = [
            row
            for row in range(2 * CELL_HEIGHT)
            if any(pixels[column, row] for column in range(CELL_WIDTH))
        ]
        gap = _gap_in(rows)
        if gap is not None:
            raise RenderError(
                f"the {weight} face leaves pixel row {gap} blank between two "
                f"stacked '│' cells, so vertical rules would come out dashed. "
                f"The {CELL_WIDTH}x{CELL_HEIGHT} cell no longer fits the font."
            )

        side_by_side = Image.new("L", (2 * CELL_WIDTH, CELL_HEIGHT), 0)
        draw = ImageDraw.Draw(side_by_side)
        draw.fontmode = "1"
        for cell in (0, 1):
            draw.text(
                (cell * CELL_WIDTH, TEXT_BASELINE),
                "─",
                font=font,
                fill=255,
                anchor="ls",
            )
        pixels = side_by_side.load()
        columns = [
            column
            for column in range(2 * CELL_WIDTH)
            if any(pixels[column, row] for row in range(CELL_HEIGHT))
        ]
        gap = _gap_in(columns)
        if gap is not None:
            raise RenderError(
                f"the {weight} face leaves pixel column {gap} blank between "
                f"two side-by-side '─' cells, so horizontal rules would come "
                f"out broken. The {CELL_WIDTH}x{CELL_HEIGHT} cell no longer "
                "fits the font."
            )


def verify_glyph_coverage(frame, faces):
    """Prove the pinned font draws every glyph the frame uses, inside its cell.

    Two failures this catches are invisible in the finished image unless you go
    looking. A codepoint the font does not carry is drawn as the `.notdef` box
    rather than refused, so a frame that gained a glyph would ship as a row of
    little rectangles. And a glyph taller than the cell is not clipped where it
    would be noticed -- it overlaps its neighbour, except on the frame's last
    row, where the image boundary cuts it off.
    """
    from PIL import Image, ImageDraw

    # Private-use, so no font carries it: whatever this draws is the shape a
    # missing glyph is drawn as.
    probe = "\ue000"
    width, height = 3 * CELL_WIDTH, 3 * CELL_HEIGHT
    baseline = CELL_HEIGHT + TEXT_BASELINE
    characters = sorted({character for row in frame.characters for character in row})

    for weight, font in sorted(faces.items()):
        image = Image.new("L", (width, height), 0)
        draw = ImageDraw.Draw(image)
        draw.fontmode = "1"

        def ink(character):
            image.paste(0, (0, 0, width, height))
            draw.text(
                (CELL_WIDTH, baseline), character, font=font, fill=255, anchor="ls"
            )
            return image.tobytes()

        undefined = ink(probe)
        missing = []
        for character in characters:
            if character == " ":
                continue
            drawn = ink(character)
            if drawn == undefined:
                missing.append(character)
                continue
            pixels = image.load()
            rows = [
                row - CELL_HEIGHT
                for row in range(height)
                if any(pixels[column, row] for column in range(width))
            ]
            if rows and (rows[0] < 0 or rows[-1] >= CELL_HEIGHT):
                raise RenderError(
                    f"the {weight} face draws {character!r} over cell rows "
                    f"{rows[0]}..{rows[-1]}, outside its {CELL_HEIGHT}-row cell. "
                    "It would overlap the row below, and be cut off by the "
                    "image boundary on the frame's last row."
                )
        if missing:
            raise RenderError(
                f"the {weight} face has no glyph for "
                f"{', '.join(repr(character) for character in missing)}, which "
                "the frame draws. They would be rendered as empty boxes."
            )


def render(frame, faces):
    """The frame as a paletted image.

    Backgrounds are laid down for the whole frame before any glyph is drawn: a
    descender reaches a couple of pixels below its own cell, and interleaving
    the two passes would let the next row's background erase it.
    """
    from PIL import Image, ImageDraw

    colours = sorted(
        {frame.default_background}
        | {attribute.foreground for attribute in frame.legend.values()}
        | {attribute.background for attribute in frame.legend.values()}
    )
    index_of = {colour: index for index, colour in enumerate(colours)}
    background = index_of[frame.default_background]

    image = Image.new(
        "P",
        (frame.width * CELL_WIDTH, frame.height * CELL_HEIGHT),
        background,
    )
    image.putpalette([channel for colour in colours for channel in colour])
    draw = ImageDraw.Draw(image)
    draw.fontmode = "1"

    for row, tokens in enumerate(frame.attributes):
        top = row * CELL_HEIGHT
        for column, token in enumerate(tokens):
            attribute = frame.legend[token]
            if attribute.background == frame.default_background:
                continue
            left = column * CELL_WIDTH
            draw.rectangle(
                [left, top, left + CELL_WIDTH - 1, top + CELL_HEIGHT - 1],
                fill=index_of[attribute.background],
            )

    for row, (characters, tokens) in enumerate(
        zip(frame.characters, frame.attributes)
    ):
        baseline = row * CELL_HEIGHT + TEXT_BASELINE
        for column, (character, token) in enumerate(zip(characters, tokens)):
            if character == " ":
                continue
            attribute = frame.legend[token]
            draw.text(
                (column * CELL_WIDTH, baseline),
                character,
                font=faces["bold" if attribute.bold else "regular"],
                fill=index_of[attribute.foreground],
                anchor="ls",
            )
    return image


def encode(image):
    """The image as PNG bytes.

    Pillow writes no timestamp and no text chunk unless asked, and is not asked
    here, so these bytes are a function of the pixels and the palette alone.
    """
    buffer = io.BytesIO()
    image.save(buffer, format="PNG", optimize=True, compress_level=9)
    return buffer.getvalue()


def png_dimensions(data):
    """A PNG's declared width and height, read from its header.

    Stdlib only, so a test can hold the checked-in asset to the frame's
    dimensions on a machine with no imaging library.
    """
    if not data.startswith(PNG_SIGNATURE) or len(data) < 24:
        raise RenderError("not a PNG file")
    length, kind = struct.unpack(">I4s", data[8:16])
    if kind != b"IHDR" or length < 8:
        raise RenderError("PNG file does not open with an IHDR chunk")
    return struct.unpack(">II", data[16:24])


def _subject_digest(repo_root, relative):
    """One bound file's SHA-256, or a refusal naming the file that is gone."""
    source = repo_root / relative
    if not source.is_file():
        raise RenderError(
            f"{source} is missing, so the provenance record has nothing to "
            "hold it against. Restore the file or regenerate with "
            "python3 tools/render_board_screenshot.py."
        )
    return hashlib.sha256(source.read_bytes()).hexdigest()


def provenance_content(repo_root=REPO_ROOT):
    """The record for the bound files as they are on disk, in `sha256sum`
    format so a reader needs nothing beyond the coreutils convention."""
    return "".join(
        f"{_subject_digest(repo_root, relative)}  {relative}\n"
        for relative in PROVENANCE_SUBJECTS
    )


def write_provenance(repo_root=REPO_ROOT):
    """Rewrite the tracked record from the files on disk, returning its path."""
    record = repo_root / PROVENANCE
    record.write_text(provenance_content(repo_root), encoding="utf-8")
    return record


def parse_provenance(text):
    """The record's `{path: digest}` entries.

    Exact by design: the record is three generated lines, so anything else in
    it -- a comment, a reformatted line, a duplicate -- is evidence it was not
    written by a regeneration run, and is refused rather than read around.
    """
    entries = {}
    for number, line in enumerate(text.splitlines(), start=1):
        match = PROVENANCE_LINE.match(line)
        if match is None:
            raise RenderError(
                f"provenance line {number} is not a sha256sum-format entry: "
                f"{line!r}. Regenerate the record with "
                "python3 tools/render_board_screenshot.py."
            )
        path = match.group("path")
        if path in entries:
            raise RenderError(
                f"the provenance record names {path} twice. Regenerate it "
                "with python3 tools/render_board_screenshot.py."
            )
        entries[path] = match.group("digest")
    return entries


def verify_provenance(repo_root=REPO_ROOT):
    """Hold the tracked record against the files it binds.

    This is the check that runs where no rasteriser does, so every way the
    record can be missing or unusable fails here rather than passing as
    vacuously fresh.
    """
    record = repo_root / PROVENANCE
    if not record.is_file():
        raise RenderError(
            f"{record} is missing, so nothing ties {SCREENSHOT} to the golden "
            "frame it was rendered from. Regenerate with "
            "python3 tools/render_board_screenshot.py and commit the record "
            "with the image."
        )
    entries = parse_provenance(record.read_text(encoding="utf-8"))
    expected = set(PROVENANCE_SUBJECTS)
    if set(entries) != expected:
        unexpected = sorted(set(entries) - expected)
        missing = sorted(expected - set(entries))
        detail = []
        if missing:
            detail.append(f"omits {', '.join(missing)}")
        if unexpected:
            detail.append(f"names {', '.join(unexpected)}")
        raise RenderError(
            f"the provenance record {' and '.join(detail)}, so it does not "
            "bind the files it exists for. Regenerate it with "
            "python3 tools/render_board_screenshot.py."
        )
    stale = [
        relative
        for relative in PROVENANCE_SUBJECTS
        if _subject_digest(repo_root, relative) != entries[relative]
    ]
    if stale:
        raise RenderError(
            f"{', '.join(stale)} changed after {PROVENANCE} was last "
            f"written, so {SCREENSHOT} no longer matches the golden frame it "
            "claims to depict. Regenerate with "
            "python3 tools/render_board_screenshot.py and commit the image "
            "and its record together with the frame."
        )


def render_screenshot(repo_root=REPO_ROOT, font_dir=None):
    """The checked-in screenshot's bytes, rendered from the golden frame."""
    frame = read_frame(repo_root)
    faces = load_fonts(font_dir)
    verify_cell_geometry(faces)
    verify_glyph_coverage(frame, faces)
    return encode(render(frame, faces))


def describe_environment():
    """The pinned inputs, for the procedure's own record and for `--check`
    output that has to explain a mismatch."""
    lines = [
        f"golden frame:  {FRAME_CHARACTERS}, {FRAME_ATTRIBUTES}",
        f"output:        {SCREENSHOT}",
        f"cell:          {CELL_WIDTH}x{CELL_HEIGHT} pixels, "
        f"baseline {TEXT_BASELINE}, font size {FONT_SIZE}",
        f"font:          DejaVu Sans Mono {FONT_RELEASE}",
    ]
    for weight, (filename, digest) in sorted(FONT_FILES.items()):
        lines.append(f"  {weight:<8}     {filename}  sha256:{digest}")
    try:
        import PIL

        lines.append(f"Pillow:        {PIL.__version__}")
    except ImportError:
        lines.append("Pillow:        not installed")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=(
            "Render docs/media/board-wide.png from the board-wide golden frame."
        )
    )
    parser.add_argument(
        "--output",
        default=None,
        help=(
            f"where to write the image (default: {SCREENSHOT} in the "
            f"checkout). The tracked {PROVENANCE} is rewritten or verified "
            "only when this is left at the default, so a scratch render "
            "cannot desynchronize the record from the tracked image."
        ),
    )
    parser.add_argument(
        "--font-dir",
        default=None,
        help=(
            "directory holding the pinned DejaVu Sans Mono files (default: the "
            "documented search path, or KANBAN_SCREENSHOT_FONT_DIR)"
        ),
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help=(
            "render and compare with the existing image, and verify the "
            "provenance record, without writing anything; exit 1 when "
            "either differs"
        ),
    )
    parser.add_argument(
        "--print-environment",
        action="store_true",
        help="report the pinned inputs and exit",
    )
    arguments = parser.parse_args(argv)

    if arguments.print_environment:
        print(describe_environment())
        return 0

    font_dir = arguments.font_dir or os.environ.get("KANBAN_SCREENSHOT_FONT_DIR")
    output = Path(arguments.output) if arguments.output else REPO_ROOT / SCREENSHOT

    try:
        rendered = render_screenshot(font_dir=font_dir or None)
    except RenderError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if arguments.check:
        if not output.is_file():
            print(f"error: {output} does not exist", file=sys.stderr)
            return 1
        verdict = 0
        existing = output.read_bytes()
        if existing == rendered:
            print(f"{output} matches the golden frame ({len(rendered)} bytes)")
        else:
            print(
                f"{output} differs from the frame rendered now: "
                f"{len(existing)} bytes on disk against "
                f"{len(rendered)} rendered.\n"
                f"{describe_environment()}",
                file=sys.stderr,
            )
            verdict = 1
        if arguments.output is None:
            try:
                verify_provenance()
            except RenderError as error:
                print(f"error: {error}", file=sys.stderr)
                verdict = 1
            else:
                print(f"{REPO_ROOT / PROVENANCE} matches the files it binds")
        return verdict

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(rendered)
    width, height = png_dimensions(rendered)
    print(f"wrote {output} ({width}x{height}, {len(rendered)} bytes)")
    if arguments.output is None:
        try:
            record = write_provenance()
        except RenderError as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        print(f"wrote {record} ({len(PROVENANCE_SUBJECTS)} digests)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
