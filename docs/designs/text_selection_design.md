# In-application text selection and clipboard design

Kanban is feature-complete, but its deliberate use of terminal mouse reporting
means an ordinary left-button drag belongs to the application rather than to
the terminal emulator. Holding Shift lets the terminal recover its native
selection on the maintainer's current Ghostty setup, but that escape hatch is
not the desired experience. This arc gives Kanban a native-feeling selection
model of its own: ordinary dragging selects rendered text anywhere in the
dashboard, highlights the selection, and sends the selected text to the OS
clipboard without giving up the card, overlay, button, and wheel interactions
the mouse already provides.

This is intentionally a long-term, low-pressure project. Its value is partly
the finished interaction and partly the opportunity to build a difficult TUI
feature in small pieces whose invariants can be tested before the next piece
depends on them.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Select Kanban text with native gestures and copy it to the OS clipboard
- [ ] TSEL-1. Model a rendered Vty frame without losing terminal-cell identity
- [ ] TSEL-2. Define pure linear, word, and line selection geometry
- [ ] TSEL-3. Retain the exact frame Vty last displayed
- [ ] TSEL-4. Add a bounded, testable terminal clipboard transport
- [ ] TSEL-5. Arbitrate base-board clicks, drags, and click sequences safely
- [ ] TSEL-6. Deliver visible-screen drag selection on the base board
- [ ] TSEL-7. Add word, line, and clear multi-click selection
- [ ] TSEL-8. Extend visible-screen selection through every mouse surface
- [ ] TSEL-9. Model a frozen autoscrolling selection scene
- [ ] TSEL-10. Add drag autoscroll to the base board
- [ ] TSEL-11. Add drag autoscroll to overlay viewports
- [ ] TSEL-12. Harden lifecycle and terminal compatibility

## Epic contract

- **Goal:** ordinary unmodified drag, double-click, and triple-click gestures
  select Kanban's rendered text, show the selected region, and copy it to the
  OS clipboard; quadruple-click clears the selection; ordinary single clicks,
  the wheel, and other mouse buttons retain their agreed meanings.
- **Done when:** visible-screen selection works first on the base board and
  then every overlay; a required follow-up lets a drag continue through the
  owning board or overlay viewport beyond the initial screen; forward and
  reverse, single-line, multiline, word, and line selections preserve Vty's
  terminal-width behavior; click and multi-click arbitration cannot
  accidentally activate a card or control; release leaves the highlight in
  place and shows a ten-second green `* copied *` status that either expires or
  is dismissed with the selection by the next keyboard or mouse input;
  clipboard delivery has a bounded and documented terminal path; resize,
  focus loss, asynchronous UI events, and unsupported terminals fail safely;
  the relevant `docs/design.md` mouse, text, testing, and deferred-idea
  contracts are amended in the same pull requests as the behavior they gate;
  and automated tests plus a real-terminal matrix cover the supported
  interaction.
- **Users and operators:** primarily Vincent, and any local or remote operator
  who needs to copy text out of the TUI. Agent and pipeline behavior is
  unchanged.
- **Arc label:** None proposed.

## Current state and evidence

- `startApplication` unconditionally asks a supporting Vty output to enable
  mouse mode (`src/Kanban/UI.hs:353-388`). That is why ordinary dragging is
  reported to Kanban while Shift-drag can remain a terminal-emulator escape
  hatch.
- Brick owns drawing and event delivery. `drawApplication` returns the overlay
  and base-board widget layers, topmost first (`src/Kanban/UI.hs:337-351`), and
  the dashboard currently runs through `customMainWithDefaultVty`
  (`UI.hs:271-272`). Kanban therefore does not retain the `Vty.Picture` Brick
  actually wrote.
- Vty is a direct dependency at `>= 6.2 && < 6.6`, and Brick at
  `>= 2.6 && < 2.11` (`kanban.cabal:198-214`). The resolved Vty 6.5 event API
  provides `EvMouseDown` and `EvMouseUp`; vty-unix enables xterm mouse modes
  1000, 1002, and 1006, so held-button motion is delivered as further mouse
  reports and a release carries a terminal coordinate. Brick lifts those into
  `MouseDown` and `MouseUp` for clickable extents.
- Runtime dispatch consumes only presses. The base board's shared arm handles
  `MouseDown` and has no release arm (`src/Kanban/UI/Events.hs:240-252`);
  settings, incidents, process rows, and overlays likewise act on presses in
  their own earlier branches. `boardMouseAction` is already a pure, total
  decision for base-board presses (`UI/Events.hs:261-312`), but some overlay
  surfaces still perform their effects directly.
- The mouse contract is deliberately narrow. `docs/design.md:424-462` lists
  card selection/activation, epic toggling, outside-click dismissal, live
  session opening, wheel scrolling, and the three sidebar controls, then
  `:464-465` says cards, columns, and overlays acquire no other drag behavior.
  Section 3 separately excludes general pointer interaction beyond that list.
- The design witness suite currently treats the complete absence of
  `MouseUp` under `src/` as evidence that drag-and-drop workflow mutation does
  not exist (`test/Spec/Design/Witnesses.hs:380-392`). Text selection will make
  that textual witness false even though selection remains read-only, so it
  must be replaced by a semantic assertion that no selection transition can
  dispatch a workflow mutation.
- Kanban's golden-frame support already flattens a composed `Vty.Picture`
  through `displayOpsForPic` into rows of characters and attributes
  (`test/Spec/Support/Render.hs:100-131`). This proves the useful seam, but its
  current `FrameCell` assumes one character per terminal cell. The golden
  suite explicitly guards that assumption for its present fixtures
  (`test/Spec/UI/Golden.hs:149-169`); production selection must instead retain
  wide-character spans and zero-width continuations correctly.
- External GitHub text is sanitized, NFC-normalized, and measured with Vty's
  active Unicode width table before drawing (`docs/design.md:1206-1229`). A
  rendered-frame selection should copy this safe visible representation, not
  reach around it to the raw issue body.
- `AppState` already owns process-lifetime presentation state such as the card
  selection, search, filter focus, overlay extent, and notices
  (`src/Kanban/UI/Types.hs:681-875`). It has no pointer gesture, captured frame,
  or text-selection state.
- The bottom panel always draws a hint and freshness row, then conditionally
  draws `appNotice` in yellow with `txtWrap`
  (`src/Kanban/UI/Board.hs:1158-1167`; `UI/Theme.hs:235-248`). That notice has
  no expiry or kind, and its variable height participates in fullscreen
  geometry. A copied chip therefore cannot borrow it without either displacing
  operational feedback or reflowing the frozen frame.
- `handleEvent` refreshes `appNow` before dispatch, and `AppEvent` already
  carries generation-stamped animation ticks (`src/Kanban/UI/Events.hs:119-127`;
  `UI/Types.hs:624-677`). A copy-feedback expiry can follow that existing
  queued-event pattern rather than blocking the UI thread or relying on an
  unrelated background event to arrive after ten seconds.
- The theme has no selection-highlight attribute. Under `--color never`, every
  declared attribute currently becomes `Vty.defAttr`
  (`src/Kanban/UI/Theme.hs:235-272`), so a visible no-color selection will need
  an explicit style policy rather than an accidental borrowed card color.
- Vty's `Output` exposes `outputByteBuffer`, which can carry an OSC 52 escape
  without suspending Brick. Kanban has no base64 dependency and emits no OSC 52
  sequence today. `docs/design.md:3763-3767` explicitly defers OSC 52 URL copy
  support, and `test/Spec/Design/Witnesses.hs:462-475` asserts that absence.
- Kanban supports macOS and Linux, and its manual release checks use tmux.
  A macOS-only `pbcopy` implementation would therefore be neither the remote
  clipboard path nor the repository's portability answer.
- The GitHub tracker has no open or closed text-selection/clipboard arc as of
  2026-08-31. Closed issues #29, #40, and #131 concern adjacent mouse handling
  and startup hardening, not selection.

## Desired experience

The operator presses the ordinary left mouse button anywhere text is visible
and drags. Kanban does not activate the card, toggle the control, or dismiss the
overlay under the starting point. Instead, once the pointer moves into another
terminal cell, the rendered text between the anchor and current head is visibly
selected. Dragging backward works identically. Releasing copies immediately,
keeps the highlight visible, and shows a green `* copied *` chip in the bottom
panel. A press and release that remains an ordinary single click performs
exactly the Kanban action agreed for that target, once.

The copy chip disappears after ten seconds, or sooner when a key or mouse
button is pressed. Its timeout does not clear the highlight. The highlight
survives background refreshes, clocks, and transcript events and clears only
when the operator next presses a key or mouse button. Clearing is an
independent presentation transition: the same input continues through the
ordinary application behavior and never becomes a dismissal-only event.
Pointer motion alone clears neither the chip nor the selection.

Double-click selects and copies the word under the pointer. Triple-click
replaces it with and copies the containing line. A fourth click in the same
sequence clears the in-application selection and consumes the gesture; it does
not erase or replace the OS clipboard. These semantics are required, not
optional parity work.

The first usable milestone selects what was actually visible when the gesture
began. The board may be refreshing, a transcript may be receiving events, and
relative ages may be advancing, but the text under a pointer must not move
while the operator is selecting it. Kanban therefore presents a frozen copy of
the captured frame while dragging and while the completed highlight remains,
continuing to accept and apply asynchronous state updates underneath it. The
latest live state is revealed when later keyboard or mouse input dismisses the
selection.

The selected text follows screen order rather than domain structure. If the
gesture crosses card borders, column separators, overlay chrome, or the usage
sidebar, those visible glyphs are eligible just as they are in a terminal's
native selection. Copying never substitutes a hidden raw issue body or an
unwrapped transcript. Later autoscroll extends the selection only by asking
the owning Kanban viewport to render more of its real content; it does not read
around the rendering boundary.

## Scope

### In scope

- Ordinary left-button click-versus-drag recognition without losing current
  card, epic, filter, sidebar, overlay, settings, process, or incident clicks.
- A cell-accurate frozen representation of the last frame Vty displayed.
- Visible highlighting and row-major text extraction over that frame.
- Double-click word selection, triple-click rendered-line selection, and
  quadruple-click clearing, under one explicit click-timing policy.
- Vty-width-aware handling of ASCII, wide characters, combining marks,
  zero-width characters, and clipped glyphs.
- Clipboard delivery to the terminal emulator through a bounded transport,
  with tmux and remote-terminal behavior stated rather than assumed.
- Base board, windowed and fullscreen overlays, live transcripts, details,
  settings, processes, incidents, help, and background content still visible
  around a windowed overlay.
- Follow-up autoscroll for the board's horizontal and per-column vertical
  viewports and for each vertically scrollable overlay, with explicit
  ownership when more than one viewport is visible.
- Persistent completed highlighting plus a dedicated fixed-height green
  `* copied *` footer status that expires after ten seconds without clearing
  the highlight and is dismissed early by keyboard or mouse-button input.
- Safe cancellation and recovery on resize, focus loss, missing or unexpected
  release events, overlay/session replacement, and dashboard exit.
- Updates to the mouse help, behavior contract, deferred-idea witness, and
  golden/pure/manual verification surfaces as their owning behavior lands.

### Out of scope

- Reading the OS clipboard or pasting clipboard content into Kanban. Vty's
  `EvPaste` is a separate input feature and the live-session decoder currently
  does not consume it.
- Selecting terminal-emulator scrollback outside Kanban's current alternate
  screen.
- Copying hidden domain data in place of rendered text.
- Editing issue, PR, board, or workflow state through a drag.
- Removing Shift-drag as a terminal-emulator fallback.
- A GUI clipboard API tied only to macOS.
- Configurable selection keybindings; completion copies on release and does not
  depend on Kanban receiving the terminal emulator's copy shortcut.

## Design

The design below records the approved behavior and ownership boundaries. Each
foundation can land independently, while the decisions and delivery plan below
are the contract that issue drafting and implementation must preserve.

### Exact-frame capture

Kanban should observe the picture Brick really sends instead of re-rendering
`drawApplication` in a mouse handler. Re-rendering can differ from the visible
frame because Brick owns viewport offsets and queued scroll requests, while
`appNow` and asynchronous state can change between draw and press.

`Graphics.Vty.Vty` is an exported record whose `update` field receives every
`Picture`. Replace `customMainWithDefaultVty` with the equivalent
`customMainWithVty` setup and wrap both the initial Vty and its rebuild action.
The wrapper records `(display region, Picture)` in an `IORef` immediately
before delegating to the real `update`. The event loop remains Brick's; the
wrapper neither draws nor reads input. This requires Kanban to depend directly
on the cross-platform Vty builder it already receives transitively.

On drag start, the event handler reads the last recorded picture once and
flattens it into a `FrameSnapshot`. Later selection draws use that immutable
snapshot; they do not reread the observer, because drawing the highlighted
selection will itself become the newest Vty update.

The Vty observer intentionally captures pixels, not Brick interaction metadata:
a `Picture` contains no clickable names or extents. While the initial press is
still being handled against the live widget tree, the gesture boundary therefore
enumerates the current state's visible mouse-target names, obtains each current
`Brick.Extent` through `lookupExtent`, ignores names with no mouse policy, and
converts the remaining rectangles to stable semantic targets. It stores those
targets, the overlay bounds and extent policy, and explicit application dispatch
precedence beside the frame as one `FrozenPointerMap`. Parameterized targets
retain item, tracker, session, incident, filter, or roster identity rather than
only a row number. The map and picture come from the same completed render
generation and remain immutable for the gesture and its completed highlight.

Rejected alternative: give every Kanban widget a parallel text-coordinate
map. It would duplicate wrapping, cropping, padding, dynamic borders, viewport
translation, and overlay composition, and would need permanent reconciliation
against every future drawing change. The composed Vty picture already is the
authoritative answer.

### Frame model

A frame is a fixed display region containing ordered rows of display atoms.
Each atom retains:

- its original `Text` payload;
- the Vty attribute it was rendered with;
- its starting terminal column and positive display width; and
- any zero-width code points attached to the preceding visible atom (or to a
  row-start sentinel when no preceding atom exists).

Background, `Skip`, and `RowEnd` columns become explicit blank atoms so every
terminal coordinate within the captured region resolves deterministically.
A wide atom covers all of its terminal cells but is emitted only once when
copied. A selection endpoint landing on any occupied cell snaps to the whole
atom. Combining characters travel with their base. This follows the same Vty
width table that drew the text and preserves `docs/design.md`'s existing
disclaimer: Kanban does not claim terminal-independent grapheme semantics.

The frame can render itself back into a Brick `raw` widget, either with its
original attributes or with a selection style applied to chosen atoms. A
round-trip property — picture to frame to picture/display operations — is the
foundation's central proof.

### Pure selection model

Selection state is separate from board-card selection and has a distinct name,
for example `TextSelection`. Its pure core contains:

- the frozen frame;
- the frozen coordinate-to-semantic-target pointer map;
- an anchor screen point;
- the current head screen point;
- whether the gesture is still a pending click or has crossed into dragging;
- the stable click intent that would run if it remains a click; and
- the selection mode (`Linear`, `Word`, or `RenderedLine`) and whether the
  result is active, completed, or cleared.

The geometry is conventional linear screen selection:

- a single row selects the columns between anchor and head;
- the first and last rows are partial when the range spans rows;
- intermediate rows select their full width;
- forward and reverse gestures normalize to the same range;
- copied rows preserve internal spaces and remove only display padding to the
  right of the last selected nonblank atom; and
- selected rows are joined with `\n`, with no additional final newline.

Those whitespace rules are the accepted contract and must be tested against
the reference terminal behavior. Word and line ranges use the same atom mask,
highlight, and extraction path as a linear range; only construction of the
range differs. A word is the maximal adjacent run in one of three classes:
Unicode letters/marks/digits plus underscore, whitespace, or punctuation and
symbols. A line is one rendered terminal row with right display padding
removed; Kanban does not reconstruct a pre-wrap source line from pixels that
no longer retain that identity. Rectangular selection and Shift-extension
remain outside this arc.

Brick can deliver a mouse report as a named `MouseDown`/`MouseUp` whose
location is relative to the matching clickable extent, or leave a report over
inert content as a raw Vty event with absolute terminal coordinates. A small
normalization boundary must combine the event with Brick's latest render
extents and produce one absolute `FramePoint` for the initial live press. After
the raw frozen frame replaces the widget tree, the same boundary uses the saved
`FrozenPointerMap` for absolute reports instead. Every later gesture transition
operates on that common form. This is also what makes motion across adjacent
cards, an overlay boundary, or unnamed text one continuous drag rather than a
sequence of unrelated widget events.

### Click-versus-drag arbitration

Today a press immediately performs its action. Drag and multi-click selection
require the left press to become a candidate rather than an effect:

1. Resolve the press to a stable `MouseClickIntent` and capture the frame and
   anchor.
2. A held-button motion at the same screen point changes nothing.
3. The first motion into another selectable cell promotes the candidate to a
   drag and permanently suppresses its click intent.
4. Further motion updates only the selection head.
5. A release while dragging finalizes/copies the text and applies no click.
6. A release while still pending arms the stored single-click intent until one
   short, documented multi-click deadline on every plain-left selectable
   surface.
7. A qualifying second release cancels the single-click intent and
   selects/copies a word, a third replaces it with the containing line, and a
   fourth clears the selection without changing the clipboard.
8. Expiry of a generation-stamped click-sequence timer applies one still-valid
   single-click intent exactly once. A stale timer is a no-op.

The stable intent cannot merely retain a card row number: a refresh can arrive
between press and release and make that row identify different work. Card and
epic intents therefore retain item/tracker identity and re-resolve against the
current visible board on release. Sidebar controls, filter boxes, settings
roster cells, processes, and incidents already have stable names or can be
given them. An intent whose subject disappeared becomes a no-op, never an
action on its replacement.

Right click, middle click, and wheel events are not selection candidates and
keep their current press-time behavior. Modifiers retain the existing per-
surface policy unless a later semantic-selection decision explicitly claims
one.

Vty supplies individual presses and releases, not a native double-click count,
so Kanban owns the maximum interval, same-button, and spatial-continuity rules.
The pure recognizer records a monotonic timestamp, sequence generation, button,
and anchor cell. A different button, a cell outside the accepted tolerance, a
drag, timeout, focus loss, or resize ends the sequence. The range constructors
and recognizer are tested before runtime integration, while their visible
multi-click behavior lands after the simpler drag path is working.

### Frozen interaction layer

While a text drag or completed selection is active, `drawApplication` returns
the selected rendering of the frozen `FrameSnapshot` instead of the live
widget tree. This gives the selection one coherent coordinate system and
prevents transcript ticks, relative-age changes, refreshes, or overlay
transitions from moving text under the pointer. `AppEvent`s still update the
underlying `AppState`; only their presentation is deferred. Copy completion
does not unfreeze or clear the snapshot.

Mouse motion and release remain live. The next key or mouse-button input clears
the completed highlight and the copy chip in a pure pre-dispatch presentation
transition. That transition never claims, delays, replaces, or conditions the
input: the same event continues through the application behavior it would have
reached with no completed text selection. Background `AppEvent`s and copy-
feedback expiry do not clear it. Resize cannot preserve coordinates and
therefore cancels the selection before the new-size redraw. Focus loss cancels
a pending click so a release lost outside the terminal cannot activate it
later.

Rendering a `FrameSnapshot` as one raw widget deliberately registers no Brick
clickable extents, so every pointer event over the frozen presentation arrives
as an absolute raw Vty event. A selection-owned pre-dispatch branch resolves
that coordinate against the saved `FrozenPointerMap`, using the captured
overlay-before-background and row/control-before-viewport-before-panel
precedence, then combines the stable semantic target with the event's button
and modifiers through the same pure mouse policy as the live surface. A
coordinate outside a captured windowed overlay resolves to its ordinary
outside-click intent; the same coordinate at a captured fullscreen overlay
resolves to that surface's no-op policy.

For a completed selection this branch first clears the highlight and feedback,
then dispatches the resolved ordinary intent for the same input. Dismissal
itself performs no extra validation and has no consume branch. Ordinary intent
dispatch still re-resolves identity against current application state, so a
target that vanished remains the existing safe no-op rather than acting on its
replacement. Tests feed absolute raw events here on purpose: a named Brick
`MouseDown` after the widget tree has been replaced would be a false proof.

The selection highlight is reverse video applied as an attribute override while
preserving the glyph and all unrelated URL/style data the terminal needs. It
must remain visible under `--color never`; reverse video is a structural
selection indication rather than a color promise. Exact style is still subject
to visual QA.

Copy feedback is not stored in today's untyped `appNotice`: that field is a
yellow, variable-height operational message and unrelated events freely
replace it. A separate `CopyFeedback` carries a generation and expiry. On a
successful sink write, a ten-second timer posts a generation-stamped
`CopyFeedbackExpired` application event. The current generation alone may
remove the chip, so an old timer cannot erase a newer copy. Keyboard or
mouse-button input removes it early. The exact `* copied *` text is drawn in
bright green as a non-reflowing chip in the existing bottom panel and falls
back to the default attribute under `--color never`; it neither changes the
captured frame geometry nor displaces an ordinary notice.

### Clipboard boundary

The primary transport is OSC 52: UTF-8 selected text, base64
encoded, written through the active Vty output. This reaches the local terminal
emulator's OS clipboard even when Kanban runs through SSH, which a host-local
`pbcopy`, `wl-copy`, or `xclip` cannot do. The encoder and writer should be
separate:

- a pure encoder owns target selection, UTF-8, base64, framing, and a maximum
  payload;
- a small `ClipboardSink` effect writes bytes, so tests never touch a real
  clipboard;
- terminal/multiplexer adaptation decides whether a direct OSC 52 sequence or
  a documented passthrough wrapper is needed; and
- the green `* copied *` feedback appears after Kanban successfully emits the
  complete request. OSC 52 ordinarily cannot prove that terminal policy
  accepted it, so the user documentation states that limitation even though
  the compact success chip uses the user-chosen wording.

No untrusted selected text appears raw in the escape sequence. The frame has
already passed Kanban's sanitization, and base64 confines its bytes further.
The size bound fails without emitting a partial clipboard write and leaves a
concise notice. A configurable external clipboard command is a possible later
fallback, not a reason to make the core path platform-specific.

### Autoscroll extension

Visible-frame selection is the first usable vertical capability, but not the
epic's definition of “complete.” Held-button dwell in an edge band later
posts generation-stamped autoscroll ticks. Each accepted tick scrolls exactly
the owning viewport, obtains the next rendered segment, extends the logical
selection, and redraws without turning the starting click intent back on.
Leaving the edge band, releasing, resizing, changing focus, or superseding the
gesture invalidates the tick generation.

This cannot be implemented by concatenating whole terminal frames. The board
has one horizontal viewport around four independently vertical viewports; a
whole-frame history would duplicate every stationary column each time only one
column moved. TSEL-9 therefore introduces a frozen, surface-specific selection
scene: the starting frame, the absolute rectangle and scroll offset of each
eligible viewport, stable content identity sufficient to render later
segments from the gesture's starting view, and an accumulated logical range.
The visible-frame core stays authoritative outside a scrolled viewport. Q-7
is resolved by latching ownership to the selectable viewport containing the
gesture anchor when edge dwell first triggers. Vertical dwell scrolls that
viewport; horizontal dwell scrolls its nearest horizontal ancestor. Crossing
another surface may extend visible-frame selection but cannot transfer the
active autoscroll owner.

### Persistence and migration

Frame snapshots, gesture and click-sequence state, completed highlights, copy
feedback, timer generations, autoscroll ownership, and accumulated selection
scenes are process-lifetime presentation state only. They live with the other
ephemeral UI state in `AppState`, are cleared on dashboard exit, and are never
written to the GitHub cache, configuration, settings, or another durable file.
Every launch therefore begins with no text selection and no armed timer. The
arc requires no stored-data migration or compatibility reader.

### Contract boundary

Text selection is read-only pointer behavior, not drag-and-drop workflow
mutation. `docs/design.md` section 3 should continue excluding drag/drop board
mutation while dropping the broader statement that no other drag behavior
exists. Section 7 should define selection precedence beside the existing mouse
list. Sections 11 and 18 should connect visible sanitized text, Vty cell width,
and the new pure/golden tests. Section 20's OSC 52 URL-copy deferral should be
removed or narrowed when the clipboard transport lands.

The current absence-of-`MouseUp` witness should be replaced, not deleted: its
successor should enumerate the only release outcomes (one revalidated existing
click, one read-only selection completion, or cancellation) and prove that the
selection branch cannot reach `mutatesSelectedWork` or another workflow
mutation.

## Decisions

### D-1. Kanban will own ordinary drag selection

User decision on 2026-08-31. Shift-drag works in the current terminal but is
not sufficient. The desired project is the complete in-application path, which
means Kanban owns mouse gesture recognition and selection rather than disabling
mouse reporting, documenting a modifier, or adding only targeted “copy URL”
actions.

### D-2. The arc is deliberately incremental and test-led

User decision on 2026-08-31. Kanban is otherwise feature-complete and this is a
long-term project undertaken in part because it is interesting. The work must
be split into discrete reviewable pieces with an independent automated proof at
each step; no issue should need the whole feature to exist before its own
invariant can be verified.

### D-3. Visible-screen selection lands first, and autoscroll remains required for epic completion

User decision on 2026-08-31. The first end-to-end version may select only the
captured visible screen so the exact-frame model can be proven independently.
That milestone is useful but is not called the complete feature. Follow-up
slices must allow dragging beyond an edge to autoscroll the appropriate board
or overlay viewport before the epic is complete.

### D-4. Release copies immediately and leaves a persistent highlight with timed feedback

User decision on 2026-08-31. Completing a drag, word selection, or line
selection sends the selected text to the clipboard immediately and retains the
highlight. A green `* copied *` chip appears in the bottom panel for ten
seconds. The next key or mouse-button input clears both the chip and highlight
early; expiry clears only the chip, and background application events clear
neither. Pointer motion alone is not dismissal input. A new completed copy
replaces the range and restarts the ten-second feedback generation.

### D-5. Double-click word, triple-click line, and quadruple-click clear are required

User decision on 2026-08-31. Word and line selection belong to the epic's core
experience rather than optional parity work. Each completed double- or
triple-click copies the newly selected range and replaces the highlight. A
fourth click in the same sequence clears Kanban's selection and feedback,
consumes the sequence, and leaves the OS clipboard's last copied contents
unchanged. Rectangular selection and Shift-extension remain out of scope.

### D-6. Multi-click foundations precede runtime wiring, but drag is the first vertical interaction

Design decision on 2026-08-31, made under the user's delegated ordering choice.
The pure frame selection core includes word and line ranges, and the gesture
foundation includes a click-sequence recognizer, before either is wired into
the dashboard. Runtime integration then proves ordinary drag first and adds
double/triple/quadruple-click behavior in the next slice. This exposes
architectural mistakes early without making timers and click-count conflicts
the first end-to-end debugging surface.

### D-7. Semantic selection takes one universal plain-left multi-click window

User decision on 2026-08-31, resolving Q-4. Double- and triple-click selection
works on interactive text as well as inert text. Every plain-left selectable
surface therefore holds its stable single-click intent until one short,
documented multi-click interval expires; no card activation, epic/filter
toggle, overlay dismissal, refresh, or service handoff runs early and then
needs to be undone. The interval is one named monotonic-clock constant, covered
by exact simulated-time tests and tuned in the manual terminal pass rather than
copied into multiple surface decoders.

### D-8. Words use rendered character classes and lines use physical terminal rows

User decision on 2026-08-31, resolving Q-5. A word is the maximal adjacent run
under the pointer in one of three classes: Unicode letters, marks, digits, and
underscore; whitespace; or punctuation and symbols. A line is one physical
rendered terminal row with trailing display padding removed. Kanban does not
invent logical pre-wrap boundaries or application-specific URL/path tokens
that the composed Vty frame no longer identifies.

### D-9. Selection dismissal is transparent to application input

User decision on 2026-08-31, resolving Q-6. The next keyboard or mouse-button
input triggers a separate pure transition that clears completed selection and
copy feedback, but that transition does not own the event and cannot consume,
delay, replace, or condition it. The same event continues through ordinary
application dispatch. Pointer input is resolved against the captured extents
the operator can still see and converted to the ordinary stable intent; normal
current-state resolution may still no-op when that visible target vanished,
but dismissal adds no special refusal and never retargets the event.
Thus D-4 still defines *when* the residue clears, while this decision keeps
that presentation lifecycle independent from *what* the triggering input does.

### D-10. Autoscroll ownership latches from the selection anchor

User decision on 2026-08-31, resolving Q-7. When edge dwell first triggers,
the selectable viewport containing the gesture anchor becomes the immutable
autoscroll owner for that gesture. Vertical edge dwell scrolls that viewport;
horizontal edge dwell scrolls its nearest horizontal ancestor. Moving across
another viewport or from a windowed overlay into exposed board content may
extend the visible-frame range but cannot transfer the active owner. Release,
cancellation, resize, or a superseding gesture drops the latch.

## Open questions

### Q-1. Is the selection universe the captured visible frame, or must dragging auto-scroll hidden content?

Resolved by D-3. The exact-frame capability lands first. Surface-specific
autoscroll remains in the same epic as required follow-up work, with its own
frozen-scene foundation and board and overlay delivery slices.

### Q-2. Does release copy immediately, or leave a persistent selection for an explicit copy action?

Resolved by D-4. Release copies immediately, the highlighted frozen frame
persists until keyboard or mouse-button input, and the independent green copy
chip expires after ten seconds or on that same input.

### Q-3. Which native-selection gestures belong to this epic?

Resolved by D-5 and D-6. Word, line, and clear sequences are required. Their
pure geometry and recognition foundations land early, while visible runtime
integration follows the first working drag slice. Rectangular selection and
Shift-extension are deferred outside the epic.

### Q-4. May semantic selection delay single-click actions on interactive text?

Resolved by D-7. Every plain-left selectable surface uses the same short
multi-click window, so semantic selection works over interactive text and no
single-click effect runs before the sequence is known.

### Q-5. What exactly counts as a word and a line in the rendered frame?

Resolved by D-8. Lines are physical rendered rows, and words are maximal
adjacent runs of the accepted rendered character classes.

### Q-6. Does the input that dismisses a persistent frozen selection also perform its ordinary action?

Resolved by D-9. Selection cleanup is an independent pre-dispatch presentation
transition and never claims the event. The input continues through ordinary
application behavior, with pointer identity resolved from the frozen frame the
operator actually saw and then handled by the existing stable-intent rules.

### Q-7. Which viewport owns autoscroll at a shared board or overlay edge?

Resolved by D-10. Edge dwell latches the viewport containing the selection
anchor; vertical movement belongs to that viewport, horizontal movement to its
nearest horizontal ancestor, and crossing another surface does not transfer
ownership.

## Verification strategy

- **Pure frame tests:** flatten composed pictures containing `TextSpan`,
  `Skip`, `RowEnd`, backgrounds, layers, cropped text, ASCII, CJK-wide glyphs,
  combining marks, and zero-width joiners. Assert the display width of every
  row, atom ownership of every terminal column, and picture/frame round trips.
- **Pure selection properties:** normalization is direction-independent;
  reversing anchor/head selects and extracts the same atoms; every selected
  wide atom is emitted exactly once; extraction and highlight choose the same
  atoms; word and line constructors obey the accepted boundary policy;
  quadruple-clear produces no clipboard payload; clipping endpoints always
  stays in bounds; cancellation never returns a click intent.
- **Capture tests:** wrap a fake Vty update and prove the observer records the
  exact delegated picture and display region, preserves update order, and never
  changes the picture delivered downstream. Render representative real
  `drawApplication` states through it and compare with existing golden frames.
- **Clipboard tests:** exact OSC 52 bytes over UTF-8 and base64 fixtures;
  empty, multiline, combining, and maximum-size payloads; one-byte-over-limit
  refusal; direct and chosen multiplexer framing; fake sink assertions proving
  no test writes the real clipboard.
- **Pointer-state tests:** every existing plain-left target produces one stable
  candidate; a single release performs exactly its old action only after the
  D-7 sequence window expires; motion suppresses it; second and third
  clicks select without leaking an action; fourth click clears; stale click
  timers and disappeared or replaced targets refuse rather than retarget; a
  saved extent map resolves absolute raw events to the same stable target under
  explicit overlap precedence; right/middle/wheel paths remain byte-for-byte in
  their existing decision tables.
- **Feedback tests:** a successful sink write creates the exact green
  `* copied *` chip and a fresh expiry generation; a ten-second expiry removes
  the chip but not the highlight; keyboard and mouse-button input remove both;
  motion and background events remove neither; an old timer cannot clear newer
  feedback; color-never retains the text without promising green.
- **Golden selection frames:** forward/reverse and single/multi-row selections
  over the wide/minimum/narrow board, details, help, settings, process,
  incidents, and each live-session overlay; windowed overlay selections that
  cross from overlay into visible background; fullscreen bounds; color-never
  visibility.
- **Lifecycle tests:** transcript and animation events during a drag update the
  underlying state without changing the frozen frame; release copies and
  leaves the highlighted frame; expiry changes only its feedback chip; the
  next key or absolute raw pointer input both dismisses the residue and performs
  its captured target's ordinary action without a selection-owned consume
  branch; windowed-overlay outside clicks and fullscreen no-ops survive that
  raw-event path;
  resize, focus loss, unexpected buttons, quit, and vanished targets cancel
  without an action.
- **Autoscroll tests:** a frozen scene maps each edge band to at most one owner;
  ownership latches from the anchor and never transfers on surface crossing;
  generation-stamped dwell ticks stop on release or owner loss; successive
  vertical and horizontal segments neither duplicate stationary viewports nor
  omit newly revealed text; extraction and highlight still address the same
  accumulated logical range.
- **Manual matrix:** at minimum the maintainer's Ghostty locally, Ghostty
  through the release-check tmux version, and an SSH or equivalent remote-host
  path; one supported Linux terminal; forward/reverse multiline selection;
  double-word, triple-line, and quadruple-clear sequences; selection starting
  on both inert text and clickable controls; vertical and horizontal edge
  dwell; clipboard contents verified outside Kanban; terminal restoration
  verified on quit and failure.

## Delivery plan

The dependency shape is intentionally narrow at the integration point:

```text
TSEL-1 frame model ──┬──> TSEL-2 selection core ──> TSEL-5 gesture safety ──┐
                     └──> TSEL-3 exact-frame capture ───────────────────────┤
TSEL-4 clipboard transport ─────────────────────────────────────────────────┤
                                                                           v
                              TSEL-6 visible drag -> TSEL-7 multi-click
                                                        |
                                                        v
                                              TSEL-8 all surfaces
                                                        |
                                                        v
                                TSEL-9 autoscroll scene ─┬─> TSEL-10 board ──┐
                                                        └─> TSEL-11 overlays┤
                                                                            v
                                                                  TSEL-12 hardening
```

TSEL-2 and TSEL-3 can proceed independently after TSEL-1, and TSEL-4 can be
built at any time. TSEL-6 is the deliberate convergence point and the first
slice that gives an operator useful visible-screen selection. TSEL-8 completes
visible-surface coverage; TSEL-9 through TSEL-11 add the required beyond-edge
capability before TSEL-12 closes the epic.

### TSEL-1. Model a rendered Vty frame without losing terminal-cell identity

- **Outcome:** a production `Kanban.UI` frame module turns a composed
  `Vty.Picture` into a cell-addressable, attribute-preserving snapshot and can
  render/serialize it without losing wide or zero-width text.
- **Scope:** frame/row/atom types; `displayOpsForPic` conversion; blank-column,
  wide-atom, and combining-mark ownership; display-width and round-trip
  invariants; refactor the test-only frame renderer to consume the shared core.
- **Phase:** foundation.
- **Depends on:** `none`.
- **Ordering:** critical path.
- **Relevant decisions:** D-2.
- **Acceptance signals:** the existing golden suite is unchanged through the
  shared frame path; focused fixtures prove wide and combining behavior; every
  produced row covers exactly the requested display width.
- **Out of scope:** mouse events, selection ranges, highlighting, live frame
  capture, clipboard output.
- **Open questions:** None.

### TSEL-2. Define pure linear, word, and line selection geometry

- **Outcome:** pure functions turn frame coordinates and a selection mode into
  one normalized atom mask, highlighted frame, and copied text, including an
  explicit cleared state.
- **Scope:** pending/dragging/completed/cleared selection types; forward and
  reverse linear ranges; word and rendered-line constructors; wide-atom
  snapping; bounds and whitespace policy; extraction; reverse-video rendering;
  property and example tests.
- **Phase:** foundation.
- **Depends on:** `TSEL-1`.
- **Ordering:** critical path.
- **Relevant decisions:** D-2, D-5, D-6, D-8.
- **Acceptance signals:** reverse-direction, multiline, word, line, wide,
  combining, blank-row, and boundary cases pass; extraction and highlight
  provably address the same atoms; clearing yields neither a range nor a
  clipboard payload; color-never selection remains visibly reversed.
- **Out of scope:** runtime mouse dispatch, click timing, clipboard IO, and
  autoscroll across successive frames.
- **Open questions:** None.

### TSEL-3. Retain the exact frame Vty last displayed

- **Outcome:** Kanban retains an observational copy of the actual picture and
  display region handed to Vty, without changing what Brick draws or how it
  runs.
- **Scope:** direct cross-platform Vty builder dependency; update-recording Vty
  wrapper; lifecycle across initial construction and Brick rebuilds; snapshot
  reference seated in application state/environment; fake-update tests.
- **Phase:** foundation.
- **Depends on:** `TSEL-1`.
- **Ordering:** critical path; can proceed in parallel with TSEL-2.
- **Relevant decisions:** D-2.
- **Acceptance signals:** every fake update is delegated once and recorded
  exactly; representative board and overlay pictures flatten to the same frames
  as the golden renderer; normal startup/shutdown behavior is unchanged.
- **Out of scope:** reading the snapshot in event dispatch or drawing it back.
- **Open questions:** None.

### TSEL-4. Add a bounded, testable terminal clipboard transport

- **Outcome:** a clipboard boundary accepts trusted `Text` and either emits one
  complete bounded terminal copy request through an injected sink or returns a
  precise refusal.
- **Scope:** UTF-8/base64 encoding; OSC 52 framing; payload bound; selected
  terminal/multiplexer passthrough; `ClipboardSink`; fake-sink and exact-byte
  tests; documentation of acknowledgement limits.
- **Phase:** foundation.
- **Depends on:** `none`.
- **Ordering:** independent; must precede TSEL-6.
- **Relevant decisions:** D-2, D-4.
- **Acceptance signals:** exact byte fixtures pass across direct and supported
  wrapped paths; over-limit input emits zero bytes; source/text scans prove raw
  selected content cannot enter the control framing; no automated test touches
  the OS clipboard.
- **Out of scope:** mouse gestures, clipboard reading, platform-local external
  commands, targeted URL-copy UI, and presentation of copy feedback.
- **Open questions:** None.

### TSEL-5. Arbitrate base-board clicks, drags, and click sequences safely

- **Outcome:** one testable gesture machine distinguishes an ordinary
  single-click intent, linear drag, double-click, triple-click, quadruple-clear,
  cancellation, and stale timeout without dispatching an action twice.
- **Scope:** screen-coordinate recovery from Brick events; stable base-board
  click intents for cards, epics, filters, and sidebar controls; normalization
  of named target-local and raw absolute mouse reports; enumeration of the
  current base-board names through `lookupExtent`; the immutable ordered
  `FrozenPointerMap` and its pure absolute-coordinate resolver; target
  revalidation; `MouseUp` handling; monotonic click-sequence timing and
  generation-stamped expiry events; pure gesture transitions; replacement of the
  absence-of-release design witness.
- **Phase:** gesture safety.
- **Depends on:** `TSEL-2`.
- **Ordering:** critical path.
- **Relevant decisions:** D-1, D-2, D-5, D-6, D-7.
- **Acceptance signals:** the existing pointer-claim inventory is preserved;
  every prior left-click target gains a sequence assertion; motion permanently
  suppresses its intent; second through fourth clicks never leak a single-click
  action; a saved map resolves a raw absolute event to the same stable target
  under overlapping extents; stale timers and row replacement cannot retarget
  an intent; the new semantic witness proves selection transitions cannot
  mutate workflow.
- **Out of scope:** visible highlight, frame capture at press, clipboard output,
  overlays and their controls.
- **Open questions:** None.

### TSEL-6. Deliver visible-screen drag selection on the base board

- **Outcome:** ordinary dragging anywhere on the base board freezes and
  highlights the visible frame, copies on release, retains the completed
  highlight, and never activates the starting control.
- **Scope:** read the TSEL-3 snapshot at press; seat active selection state;
  capture and seat TSEL-5's live base-board pointer map; draw the TSEL-2 frozen
  highlighted frame; update on held-button motion; invoke TSEL-4 on completion;
  the high-precedence raw-pointer pre-dispatch path; dedicated green
  `* copied *` feedback with a generation-stamped ten-second expiry;
  keyboard/mouse dismissal and frozen frame lifecycle; base-board help and
  `docs/design.md` contract updates; board golden and fake-clipboard tests.
- **Phase:** first vertical capability.
- **Depends on:** `TSEL-2`, `TSEL-3`, `TSEL-4`, `TSEL-5`.
- **Ordering:** critical path.
- **Relevant decisions:** D-1, D-2, D-3, D-4, D-9.
- **Acceptance signals:** a headless event sequence selects known text from the
  real wide/minimum/narrow board frames and hands exactly that text to a fake
  sink; release retains the highlight; expiry removes only the green chip;
  an absolute raw press at every captured card, epic, filter, and sidebar extent
  both dismisses and performs that target's ordinary dispatch for the same
  input; click, right-click, and wheel regressions remain green; one local
  Ghostty probe copies into the OS clipboard.
- **Out of scope:** selection beginning in overlays, viewport autoscroll, and
  visible multi-click selection.
- **Open questions:** None.

### TSEL-7. Add word, line, and clear multi-click selection

- **Outcome:** double-click selects and copies a word, triple-click replaces it
  with and copies its containing line, and quadruple-click clears Kanban's
  selection without changing the OS clipboard.
- **Scope:** connect TSEL-5 click counts to TSEL-2 range constructors on the
  base board; replacement selection and copy-feedback generations; timeout and
  spatial-continuity behavior; conflict tests over inert text, cards, epic
  headers, filter boxes, and sidebar controls; help and contract wording.
- **Phase:** native gesture semantics.
- **Depends on:** `TSEL-6`.
- **Ordering:** critical path.
- **Relevant decisions:** D-4, D-5, D-6, D-7, D-8, D-9.
- **Acceptance signals:** exact two-, three-, and four-click timelines produce
  word-copy, line-copy, and visual clear respectively; neither semantic
  selection leaks a stored click intent; the fourth click emits no clipboard
  write; single-click behavior remains exactly D-7's delayed policy.
- **Out of scope:** overlay surfaces, viewport autoscroll, rectangular
  selection, and Shift-extension.
- **Open questions:** None.

### TSEL-8. Extend visible-screen selection through every mouse surface

- **Outcome:** drag and multi-click selection work over details, live
  transcripts, help, settings, process and incident panels, and the board
  visible around a windowed overlay, without triggering outside-click
  dismissal or a row/control action.
- **Scope:** stable overlay click intents and extent-map entries; selection
  precedence ahead of each overlay decoder; captured panel, viewport, row,
  background, and outside-overlay bounds with explicit overlap precedence;
  windowed/fullscreen coordinate coverage; session normal and insert modes;
  overlay/background crossing; word/line constructors on every surface;
  per-surface golden and dispatch regression tests; help/contract wording.
- **Phase:** visible-surface coverage.
- **Depends on:** `TSEL-7`.
- **Ordering:** critical path.
- **Relevant decisions:** D-1, D-2, D-4, D-5, D-7, D-8, D-9.
- **Acceptance signals:** each overlay family has one click-without-motion and
  one suppressing-drag, one double-word, and one triple-line test; details and
  transcript selections copy wrapped visible text under D-8; a drag across a
  windowed overlay boundary remains one selection; absolute raw presses against
  captured rows and controls reach their stable intents after dismissal;
  windowed outside-click, fullscreen outside-no-op, quadruple-clear, and
  ordinary right-click policies still hold.
- **Out of scope:** content beyond the captured frame and autoscroll.
- **Open questions:** None.

### TSEL-9. Model a frozen autoscrolling selection scene

- **Outcome:** a pure scene model can extend one frozen selection through
  successive viewport segments without duplicating stationary terminal
  regions or mixing refreshed content into the gesture.
- **Scope:** selectable viewport rectangles, nesting, offsets, stable surface
  and content identity, starting-view projection, edge bands, owner latching,
  generation-stamped dwell ticks, accumulated logical ranges, and synthetic
  nested-viewport fixtures.
- **Phase:** autoscroll foundation.
- **Depends on:** `TSEL-8`.
- **Ordering:** critical path for beyond-edge selection.
- **Relevant decisions:** D-2, D-3, D-4, D-10.
- **Acceptance signals:** synthetic four-column and windowed-overlay scenes
  assign every edge to at most one owner; repeated segments deduplicate static
  siblings; refreshed live data cannot enter the frozen scene; reverse motion
  contracts the same logical range it extended; stale dwell ticks are no-ops.
- **Out of scope:** issuing Brick viewport scroll commands and terminal
  clipboard output beyond the already tested boundary.
- **Open questions:** None.

### TSEL-10. Add drag autoscroll to the base board

- **Outcome:** a held drag at a board edge scrolls the latched column
  vertically or the containing board horizontally and extends the selection
  through newly rendered content.
- **Scope:** `BoardViewport` and four `ColumnViewport` geometries; dwell cadence
  and repeated scroll events; scroll-boundary stop; frozen board scene;
  horizontal and vertical accumulation; board goldens and fake-clipboard
  integration tests; interim contract update.
- **Phase:** board autoscroll.
- **Depends on:** `TSEL-9`.
- **Ordering:** critical path; can proceed in parallel with TSEL-11.
- **Relevant decisions:** D-3, D-4, D-10.
- **Acceptance signals:** deterministic tick sequences select exact off-screen
  card text vertically and exact off-screen columns horizontally; stationary
  columns appear once; releasing or leaving the edge stops scrolling; copied
  text and retained highlight agree across the accumulated range.
- **Out of scope:** overlay viewport autoscroll and terminal scrollback.
- **Open questions:** None.

### TSEL-11. Add drag autoscroll to overlay viewports

- **Outcome:** a held drag at an eligible overlay edge scrolls that overlay's
  frozen content and extends the selection without transferring ownership to
  the board visible behind a windowed panel.
- **Scope:** details, settings, process, incident, solve, review, and pull
  request transcript viewports; windowed/fullscreen bounds; transcript updates
  held outside the frozen scene; per-surface tick, range, highlight, and copy
  tests; final autoscroll help/contract wording.
- **Phase:** overlay autoscroll.
- **Depends on:** `TSEL-9`.
- **Ordering:** critical path; can proceed in parallel with TSEL-10.
- **Relevant decisions:** D-3, D-4, D-10.
- **Acceptance signals:** each scrollable overlay selects exact content first
  hidden above and below its initial viewport; windowed background viewports
  never steal an active owner; arriving transcript data remains hidden until
  dismissal; release copies the accumulated overlay range once.
- **Out of scope:** terminal-emulator scrollback and non-scrollable overlays.
- **Open questions:** None.

### TSEL-12. Harden lifecycle and terminal compatibility

- **Outcome:** the completed selection model behaves predictably when the UI,
  gesture timer, or terminal changes mid-selection, with an honest supported-
  terminal statement.
- **Scope:** resize/focus-loss/missing-release cancellation; click, feedback,
  and dwell timer interleavings; asynchronous refresh and transcript events;
  quit/exception restoration; payload and unsupported-output notices;
  Ghostty/tmux/SSH/Linux manual matrix; final contract and user-guide
  reconciliation.
- **Phase:** hardening and compatibility.
- **Depends on:** `TSEL-10`, `TSEL-11`.
- **Ordering:** critical path; completes the epic.
- **Relevant decisions:** D-1, D-2, D-3, D-4, D-5, D-6, D-7, D-8, D-9,
  D-10.
- **Acceptance signals:** lifecycle interleavings cannot move, duplicate, or
  retarget a frozen selection; cancellation leaves no action or armed timer;
  chosen manual terminal paths put exact multiline Unicode text in the
  external clipboard; copied feedback lasts exactly its bounded lifecycle;
  terminal restoration remains clean; final documentation matches every
  resolved question and shipped slice.
- **Out of scope:** rectangular selection, Shift-extension, clipboard reading,
  application-specific semantic tokens, and terminal scrollback.
- **Open questions:** None.
