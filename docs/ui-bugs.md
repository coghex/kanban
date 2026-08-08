# Kanban UI findings

A running collection of observations made while using Kanban, with focused
repository evidence captured for later disposition through `process-report`.

Status legend: `[ ]` unprocessed · `[#N]` filed · `[no-issue]` closed without an issue · `[deferred]` blocked on a concrete precondition

## Status

- [x] UI-1. Drainer control uses ASCII borders beside the Unicode UI — [#205]

---

## Chapter 1 — Visual consistency and layout

### [#205] UI-1. Drainer control uses ASCII borders beside the Unicode UI

> **Captured note:** the button for drain_prs.py uses pipes and dashes, it should be using the unicode border chars that the rest of the program uses

**Verification:** Verified — the drainer control hardcodes an ASCII box in every
rendering mode, including the default Unicode modes.

**Evidence:**

- `src/Kanban/UI/Board.hs:95` — `drawDrainerButton` constructs all three border
  rows with literal `+`, `-`, and `|` characters rather than a Brick border
  widget or the active border style.
- `src/Kanban/UI/Theme.hs:175` — the surrounding interface already selects
  double, heavy Unicode, or ASCII border styles from `optionAscii` and the border
  policy; the drainer control does not consult those choices.
- `test/golden/board-wide.txt:57` and
  `test/golden/board-open-borders.txt:41` — checked-in Unicode-mode frames show
  `| drain_prs.py |` inside otherwise Unicode application chrome.
- `test/golden/board-ascii.txt:41` — the same literals are appropriate in the
  explicit `--ascii` fallback, so ASCII behavior should remain available.
- `docs/design.md:55` and `docs/design.md:503` — the visual contract calls for a
  polished Unicode interface by default and reserves ASCII as the emergency
  fallback.

**Handoff context:**

- **Current behavior:** The clickable drainer control always renders
  `+--------------+`, `| drain_prs.py |`, `+--------------+`.
- **Expected behavior:** Unicode modes should use box-drawing characters
  consistent with the surrounding interface; `--ascii` should retain ASCII.
- **Scope and constraints:** Preserve the existing click target, status color,
  label, and detail line. Golden coverage lives in
  `test/Spec/UI/Golden.hs`; Unicode frames will change while the ASCII frame
  should continue proving the fallback.
- **Remaining uncertainty:** The intended light-versus-heavy Unicode style for
  this nested control is not stated explicitly; the surrounding sidebar uses
  the heavy inner-border style.

## Chapter 2 — Interaction, navigation, and keybindings

No findings yet.

## Chapter 3 — Workflow state and automation

No findings yet.

## Chapter 4 — Feedback, errors, and discoverability

No findings yet.

## Chapter 5 — Configuration and setup

No findings yet.

## Chapter 6 — Reliability and performance

No findings yet.

## Chapter 7 — Other observations

No findings yet.
