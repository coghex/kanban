# Project Review Findings: PRs #195–#185

This review continued below the completed #196 cursor and covered the next
twelve merged pull requests by merge time: #195, #193, #194, #192, #191,
#190, #189, #188, #187, #184, #186, and #185. There were no direct
first-parent commits interleaved between #196 and #185. The batch was frozen
at `origin/master@ed90877` on 2026-08-22. Its implementation is
`2e2003e`; the two intervening commits edit only
`docs/project_review_456-446.md`, so they do not alter this batch's code or
the finding below. Origin advanced once more to `3215e3d` while validation was
running, through another edit to that same report; the frozen boundary did not
move.

Each pull request was checked against its linked issue, effective reviewed
specification, pull-request body, commits, landed diff, canonical review
history, current implementation, callers, and current tests. Later descendants
were read only to establish whether a mistake still exists. The move-only
Solve, GitHub, Preflight, and UI decompositions retain their compatibility
facades, the shared session core and keybinding table retain their focused
contract tests, and the repository-key, direct-merge, repair, incidents, and
workflow-scanner paths remain covered. The scanner's wrapper and exclusion
gaps, key table's action-text gap, direct merge's result-validation and notice
lifecycle gaps, repair's stale inventories, and incidents panel's stale
selection bug were all corrected before their pull requests were approved.
They are not duplicated here.

The full Haskell suite passed 1,554 examples and the focused workflow-contract
scanner passed 55 tests on the frozen implementation. This report preserves
the one newly confirmed current mistake that still needs one-at-a-time
disposition.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Status

- [x] PRR-1. Card top and bottom border runs discard their selected or status color — [#496]

## 1. Card border attributes

### [#496] PRR-1. Card top and bottom border runs discard their selected or status color

> **Captured note:** Correct the rendering defect PR #185 pinned: draw card
> horizontal border runs without Brick's `hBorderAttr` override so the
> selected card's top and bottom edges are cyan and every unselected card's
> full border carries its status color.

**Verification:** PR #185 added the promised golden-frame suite and made
selected-card attribute coverage mandatory under issue #55's effective
specification. During implementation it exposed a real production defect and
deliberately pinned it rather than repairing it under the testing-only issue:
Brick's `hBorder` applies its own `hBorderAttr` after the surrounding
`withAttr`, while Kanban's theme defines no corresponding border attribute.
The horizontal runs therefore render with `Vty.defAttr`.

That behavior is still current. `drawCardFrame` wraps each `hBorder` in the
intended `topBottomAttribute`, but the current golden test explicitly explains
why that attribute is lost, calls the result a rendering defect, and asserts
the default attribute. The loss affects both halves of the contract: a
selected card lacks cyan across the runs between its corners, and an
unselected card lacks its yellow, green, red, or neutral status color there.
The corners and vertical edges are drawn as text and keep their intended
attributes, making the top and bottom borders visibly split for the wrong
reason.

The current design is unambiguous: an unselected card uses its status color for
the full border, while a selected card uses cyan for its left, top, and bottom
edges and retains status color only on the right edge and right-side corners.
The same module already avoids Brick border widgets for colored sidebar
controls for exactly this reason, drawing their box glyphs explicitly so the
requested attribute survives. PR #185's out-of-scope allowance justified
recording an exposed rendering bug as-is; it did not supersede the product
contract or create an owner for fixing it.

The full suite remains green because the attribute golden asserts
`Vty.defAttr`, not the intended cyan/status values. Character goldens also
cannot reveal the problem because the glyphs themselves are correct.

**Evidence:**

- `src/Kanban/UI/Board.hs:782-809` — `drawCardFrame` computes selected or
  status `topBottomAttribute`, then places Brick `hBorder` under it for both
  horizontal runs; only the explicitly drawn corner and vertical glyphs keep
  their assigned attributes.
- `test/Spec/UI/Golden.hs:176-224` — the selected-border test verifies the
  intended gutter, corners, vertical edges, and title, then documents the
  `hBorderAttr` override as a rendering defect and requires every horizontal
  cell to equal `Vty.defAttr`.
- `docs/design.md:872-882` — the current visual contract requires the full
  unselected border to use status color and the selected top and bottom edges
  to use cyan, reserving status color for the selected card's right side.
- `src/Kanban/UI/Board.hs:165-181` — the sidebar control renderer records the
  same Brick border-attribute behavior and already uses explicit box glyphs to
  keep every edge under its requested status attribute.

**Handoff context:**

- **Current behavior:** Card corner and vertical-edge colors follow selection
  and status, but the horizontal runs between the corners use the terminal's
  default attribute. The defect affects selected and unselected cards.
- **Expected behavior:** For an unselected card, both horizontal runs use the
  card's status attribute. For a selected card, both runs and their left
  corners use the selected cyan attribute; the right corners and right edge
  retain the card's status attribute. Text, gutter, and interior treatment stay
  unchanged.
- **Scope and constraints:** Preserve the exact card width, rounded Unicode
  glyphs, ASCII fallback, box/open application-border modes, no-color
  behavior, right-side status split, and existing title/interior attributes.
  Avoid a global `borderAttr` mapping that would recolor unrelated Brick
  borders; use a card-local rendering technique such as explicitly repeated
  horizontal glyph text, or prove an equally local alternative.
- **Verification target:** Replace the `Vty.defAttr` assertion with intended
  attribute assertions for both selected and unselected cards. Exercise at
  least one status-colored card in Unicode and ASCII modes, retain the
  character and full-frame goldens, and verify no width or corner regression
  at wide, minimum, and narrow layouts.
- **Deduplication:** Searches across open and closed tracker items and every
  findings report found no active owner for the horizontal card-border color
  defect. Closed issue #55 records the observation but expressly leaves
  rendering fixes out of scope; it delivered the test that pins the problem.
  Closed issue #205 concerns a sidebar drainer control's separate border and
  already uses the explicit-glyph workaround. Neither is an issue that owns
  this correction.
- **Remaining uncertainty:** The smallest safe rendering primitive has not
  been selected. Explicit glyph repetition matches the established sidebar
  approach, but the implementation must derive the run from Brick's available
  width without changing the current greedy/fixed sizing behavior.
