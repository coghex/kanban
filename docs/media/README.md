# Media

One tracked asset lives here, and this is the procedure that produces it.

| Asset | What it shows |
| --- | --- |
| `board-wide.png` | The board at 200x64 cells: the usage sidebar, all four columns, standalone and tracked cards, the three pull-request readiness colours, and the selected card. |

The image is **derived, not captured**. Its source is the golden frame the test
suite already checks in, so it carries the repository's invented fixture board
and no live issue, account, usage, or path data, and it can be produced again
from a clean checkout with no terminal, no network, no GitHub account, no
provider login, and no board cache.

## What it is made of

| Input | Path |
| --- | --- |
| Characters, one per cell | `test/golden/board-wide.txt` |
| Vty attribute, one per cell | `test/golden/board-wide.attrs` |
| Renderer | `tools/render_board_screenshot.py` |
| Output | `docs/media/board-wide.png` |

Both inputs are written by the golden-frame suite's `board-wide` case
(`test/Spec/UI/Golden.hs`), which draws the whole application at a fixed
200x64 terminal size from `Kanban.Fixture`'s board and a pinned clock. Nothing
in that path reads a terminal, the network, or a GitHub account.

Geometry is fixed: each cell is 16x31 pixels with the text baseline 25 pixels
down, at font size 26. A 200x64 frame is therefore **3200x1984** pixels.

Those three numbers are one choice, not three. At size 26 the pinned font draws
`│` over exactly 31 pixel rows and `─` one pixel past each side of a 16-pixel
cell, so a rule drawn in adjacent cells meets rather than breaking. The
renderer re-derives both properties from the font it loaded on every run and
refuses to write an image if they no longer hold.

## Prerequisites

Installing these is a one-time step and the only part of this procedure that
touches the network. The regeneration run itself does not.

- **Python 3** with **Pillow**. The checked-in asset was produced with Pillow
  **12.2.0**. Pillow and its bundled FreeType are the one input this repository
  cannot pin from inside: they decide how a glyph outline becomes pixels. A
  different build can legitimately produce different bytes, which is what the
  comparison step below is for.
- **DejaVu Sans Mono 2.37**, the only font consulted. It is the monospace
  family in wide distribution that covers every glyph the frame draws — box
  drawing, block elements, arrows, and the geometric shapes the board uses for
  tracker and CI state — so nothing is ever resolved through a fallback font.

  Download `dejavu-fonts-ttf-2.37.tar.bz2` from the DejaVu project's
  [`version_2_37` release](https://github.com/dejavu-fonts/dejavu-fonts/releases/tag/version_2_37)
  and unpack these two files somewhere:

  | File | SHA-256 |
  | --- | --- |
  | `DejaVuSansMono.ttf` | `b4a6c3e4faab8773f4ff761d56451646409f29abedd68f05d38c2df667d3c582` |
  | `DejaVuSansMono-Bold.ttf` | `bce60f1b4421acd9ea51ba6623d7024ecbe6817a953e3654df62a5e6bdf8f769` |

  The renderer locates them by path and never by family name, and checks both
  digests before drawing anything. A differently-versioned DejaVu, or a
  same-named substitute, is an error rather than a quietly different image.

The fonts are looked for in `~/.local/share/fonts/dejavu`,
`~/Library/Fonts/dejavu`, `/usr/share/fonts/truetype/dejavu`, and
`/opt/homebrew/share/fonts/dejavu`. Anywhere else, name the directory with
`--font-dir` or `KANBAN_SCREENSHOT_FONT_DIR`.

## Regenerating

From the repository root, or from an unpacked release archive:

```console
python3 tools/render_board_screenshot.py
```

To see what the run would be pinned to without drawing anything:

```console
python3 tools/render_board_screenshot.py --print-environment
```

## Comparing a regenerated image with the checked-in one

In a checkout, Git is the comparison:

```console
python3 tools/render_board_screenshot.py
git diff --exit-code -- README.md docs/media/
```

An unchanged checkout and the documented environment leave no diff. Outside a
checkout — from an unpacked release, for instance — compare without writing:

```console
python3 tools/render_board_screenshot.py --check
```

`--check` exits 0 when the rendered bytes match the tracked file, and 1 with
the pinned environment printed when they do not.

`python3 -m unittest tools.test_board_screenshot` covers the same ground as
part of the ordinary test run. Its frame-parsing and asset cases run
everywhere; its rendering cases name the missing prerequisite and skip when
Pillow or the pinned fonts are absent, which is the case in the required CI
job.

## Reviewing an intentional change

A UI change reaches this image through the golden frame, so regenerate in that
order:

1. Land the UI change and refresh the golden frames from the suite, reading
   that diff first — it is the reviewable, line-oriented statement of what
   changed:

   ```console
   KANBAN_UPDATE_GOLDENS=1 cabal test kanban-test --test-show-details=direct
   cabal test kanban-test --test-show-details=direct
   ```

2. Regenerate the image from the refreshed frame and confirm the diff is only
   the image and only where the frame changed:

   ```console
   python3 tools/render_board_screenshot.py
   git diff --stat -- docs/media/
   ```

3. Look at the result at both sizes before committing it: at the width GitHub
   renders the project README at, where all four columns, the sidebar,
   representative cards, and the status colours have to stay recognisable; and
   at full size, where the text has to stay legible and nothing may be clipped
   by the image boundary.

An image diff with no golden-frame diff behind it is the signal to stop and
find out what else changed — a different Pillow or FreeType build, or a font
that is not the pinned one. The renderer's own checks catch the font; the
rasteriser is what is left.

A diff in the palette needs the same treatment. The renderer pins one RGB value
per terminal palette slot the frame uses, because a Vty attribute names a slot
rather than a colour: the sixteen ANSI slots and the 6x6x6 colour cube behind
`Color240` are at their xterm values, and the two defaults are the palette's own
black and white, because Kanban's themes are drawn for a dark terminal. Those
values live in `tools/render_board_screenshot.py`; changing one changes every
regenerated image.
