# Column issue search design

Kanban boards can grow beyond what is practical to scan or traverse one card at
a time. This design adds a lightweight, column-scoped search mode: one key opens
an input above the Issues cards, text filters cards immediately, and the search
can move to another workflow column without becoming a detached overlay.

Design state: `ready for issue processing`

> Decomposition history: `/process-design-doc` stopped on 2026-08-11 before
> creating the umbrella because the delivery plan had collapsed to a single
> slice, which cannot carry an epic. The nine signed-off decisions D-1…D-9 were
> unchanged and not relitigated; D-10 split the arc into three dependency-ordered
> slices and D-11 settled the one behavior question that decomposition created.
> Readiness re-signed off 2026-08-11.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Add live column-scoped card search to the board — [#261]
- [x] SRCH-1. Move Settings to `o options` and add a second board quit chord — [#262]
- [x] SRCH-2. Add the column-scoped search mode on Issues with safe filtering — [#263]
- [x] SRCH-3. Transfer the active search between columns — [#264]

## Epic contract

- **Goal:** a user can press `s`, type part of an issue or pull-request
  identity, and reduce one board column to matching cards without leaving the
  board or waiting for GitHub.
- **Done when:** search opens on Issues by default; its visible input grows as
  text wraps; the target column filters on every edit; transferring search to
  another column clears the query and moves the input there; closing search
  removes the input and restores the complete column; and keyboard, mouse,
  selection, epic, narrow-terminal, refresh, and quit behavior are explicitly
  resolved and covered.
- **Users and operators:** people navigating repositories with enough cards to
  make visual scanning slow; maintainers of the Brick event, selection, and
  rendering model.
- **Arc label:** proposed `ui` (the repository has no dedicated search label).

## Current state and evidence

- **`q` remains the dashboard quit key, and `s` is currently Settings.**
  `QuitDashboard` binds `q` in board, details, and help scopes, while
  `ShowSettings` binds `s` in board scope; both dispatch through the central
  binding table (`src/Kanban/UI/Keys.hs:20-24,212-226`,
  `src/Kanban/UI/Events.hs:144,165-189`). The README, user guide, design
  contract, help overlay, footer, and key-table tests all project or document
  those behaviors (`README.md:93-105`, `docs/design.md:271-308`,
  `docs/user-guide.md:71-101`, `test/Spec/UI/Keys.hs`). Reusing `q` therefore
  was rejected; D-8 moves Settings from `s` to the previously unclaimed `o`
  binding so assigning search to `s` does not remove keyboard access.
- **`Ctrl-C` already has overlay-specific meaning.** In every live-agent
  overlay, `Ctrl-C` interrupts the active turn; that decoder runs before base
  board dispatch and is tested across solve, PR, and review sessions
  (`src/Kanban/UI/SessionCore.hs:259-284`, `test/Spec/UI/SessionCore.hs:133-136`,
  `docs/design.md:299`). Adding `Ctrl-C` as a second quit chord in board scope
  does not need to remove the higher-priority live-agent interrupt behavior.
- **Bindings have a single authoritative registry.** `Kanban.UI.Keys.binding`
  owns physical keys, scopes, footer labels, help descriptions, and verbatim
  §7 contract text; event dispatch, the footer, help, and tests consume that
  registry. Search mode needs its own scope or higher-priority input decoder,
  not independent key arms that would recreate the drift this registry removed
  (`src/Kanban/UI/Keys.hs:1-27,140-234`).
- **The board starts focused on Issues.** Initial state sets
  `appSelectedColumn = Issues` and remembers a row per column
  (`src/Kanban/UI.hs:87-96`). That is a natural anchor for the requested
  default, but opening search from another column must also bring Issues into
  the horizontal viewport on a narrow terminal.
- **Columns own vertical viewports.** Each column header is outside a
  `ColumnViewport`; the viewport currently contains a one-row top pad followed
  by entries (`src/Kanban/UI/Board.hs:177-260`). A search widget placed before
  the cards in the column's layout participates in height calculation and
  moves cards down; it must remain above the card viewport if it is meant to
  stay visible while results scroll.
- **Rendered rows are interaction addresses.** Cards and epic headers are
  clickable by `(column, row)`, and keyboard selection also indexes
  `entriesFor state column` (`src/Kanban/UI/Board.hs:263-302,405-420`,
  `src/Kanban/UI/Events.hs:146-154,655-689`,
  `src/Kanban/UI/Selection.hs:36-197`). Filtering only in the renderer would
  let a visible card invoke an action on a different underlying entry. One
  derived visible-entry model must be shared by rendering, selection, and
  dispatch, with selection reconciled by stable item/tracker identity rather
  than by stale row number.
- **Epics are structure as well as cards.** A column list can contain
  `Standalone`, `Tracked`, and `TrackerHeader` entries. Rendering synthesizes a
  group header from contiguous tracked children and normally hides children of
  collapsed epics (`src/Kanban/Domain.hs:321-328`,
  `src/Kanban/UI/Board.hs:263-280`). D-6 supplies the intentional rule for
  matching a tracker and exposing a matching child beneath a collapsed one.
- **The data already supports a cheap local search.** Every `BoardItem` has a
  number and title; `itemHeading` produces the visible issue/PR identity
  (`src/Kanban/UI/Util.hs:170-176`). No network request, cache mutation, or
  GitHub query is needed.
- **The test suite has the right seams.** Pure tests cover state and layout;
  Brick golden frames cover wide, minimum, narrow, open-border, ASCII, details,
  and help states (`docs/design.md:1607-1640`, `test/Spec/UI/Golden.hs`). The
  key suite verifies registry/contract/help/footer parity
  (`test/Spec/UI/Keys.hs`).
- **No overlapping tracker arc was found.** Three repo-scoped open-and-closed
  searches for board search/filter, hotkey search, and live card filtering
  found no matching issue or epic as of 2026-08-11; the same searches were
  rerun at readiness with the same result, and again during decomposition
  against all twelve open issues.
- **The proposed `ui` arc label does not exist.** `gh label list` reports
  `agent-workflows` and `merge-repair` as the only arc labels beside `epic`,
  `blocked`, and the `reviewed:*` workflow set, so the arc label is still a
  creation, not an adoption.

### Decomposition evidence (2026-08-11)

These facts were gathered to find real slice seams and are recorded whatever
decomposition is chosen.

- **Rendered rows are raw entry indices, not visible positions.** `drawColumn`
  renders `zip [0 ..] (entriesFor state column)` and hands those indices to
  `CardTarget`/`EpicTarget`; mouse dispatch reads them back with `safeIndex row
  (entriesFor state column)` (`src/Kanban/UI/Board.hs:258-260,295-303`,
  `src/Kanban/UI/Events.hs:148-152,662,677`). Collapsed epics are handled by
  skipping rows while drawing and by `visibleSelectionRows` skipping indices,
  never by renumbering (`src/Kanban/UI/Board.hs:263-279`,
  `src/Kanban/UI/Selection.hs:184-194`). A filtered view that renumbers breaks
  every existing mouse address; one that carries each entry's original index
  leaves the address space intact. Which of those an implementation picks is
  the solver's call, but it is exactly where D-1's safety requirement bites, so
  filtering and interaction cannot land in separate pull requests.
- **`entriesFor` is a narrow choke point.** Seven call sites consume it:
  drawing and tracker grouping (`Board.hs:260,469`), selection
  (`Selection.hs:134,182`), mouse dispatch (`Events.hs:662,677`), and the
  column heading count (`Util.hs:236`). The raw accessor `entriesForBoard` is
  separately consumed by selection normalization, `AutoSolve.hs:331`, and
  `Session.hs:491`, all of which must keep seeing the unfiltered board.
- **The heading count already has one owner.** `columnCountText` computes both
  the count and the `+` truncation marker in one function
  (`src/Kanban/UI/Util.hs:234-242`), so D-9's result/total form has a single
  site rather than four per-column ones.
- **Board input has one insertion point.** Base-board keys dispatch from a
  single arm, `(Nothing, VtyEvent keyEvent) | Just action <- boardAction
  BoardScope keyEvent`, placed after every overlay arm
  (`src/Kanban/UI/Events.hs:143-144`). A search decoder immediately before it
  inherits the priority D-5 requires without touching overlay handling.
  `applyBoardAction` is total over `BoardAction` (`Events.hs:165-189`), so a
  new registry action forces an explicit decision there.
- **Multi-chord and Ctrl bindings already exist.** `KeyBinding` holds a chord
  list, `NextCard` renders as `j/↓`, and `RepaintTerminal` is `Ctrl-L`
  (`src/Kanban/UI/Keys.hs:219,299-300,355`), so `q`/`Ctrl-C` needs no new
  registry mechanism. The live-agent interrupt stays ahead of it
  (`src/Kanban/UI/SessionCore.hs:273,282`).
- **`o` is unclaimed.** `KChar 'o'` appears in no file under `src/` or `test/`.
- **The D-8 rename has a small golden blast radius.** The footer is one clipped
  line projected from `scopeBindings BoardScope`
  (`src/Kanban/UI/Board.hs:574-575`). `ShowSettings` sits twentieth of
  twenty-three in the `BoardAction` order (`src/Kanban/UI/Keys.hs:101-122`),
  and the widest golden already clips mid-`d drainer`, so of the eight frames
  in `test/golden/` only `overlay-help.txt:30` carries the `s settings` text.

## Desired experience

From the base board, pressing `s` opens an empty, one-line search box directly
below the Issues header and above its cards. Issues is brought into view and
the box has input focus. Typing visibly appends to the query and the column
immediately retains only matching cards. When the query wraps at the current
column width, the box becomes another line taller and the cards move down by
that same amount; resizing the terminal rewraps both input and cards.

Clicking another column while search is active clears the query, moves the box
to the top of that column, and restores all cards there before a new query is
typed. Search remains a board mode, not a centered overlay. Pressing `s` again
or `Esc` clears the query, removes the box, and restores the target column's
unfiltered entries. Pressing `q`, or `Ctrl-C` from the base board, follows the
existing guarded dashboard-quit path instead. Pressing `o` from the ordinary
board opens Options/Settings.

## Scope

### In scope

- Ephemeral search state containing the target workflow column and query.
- `s` activation/closure, `Esc` closure, printable insertion, and Backspace.
- Case-insensitive number/title matching and settled epic result rules.
- Live filtering through one shared visible-entry model used by drawing and
  interaction.
- Search transfer to another column and a keyboard-equivalent transfer path.
- Dynamic wrapped box layout in closed-border, open-border, ASCII, wide, and
  narrow modes.
- Selection reconciliation across edits, transfer, exit, and board refresh.
- Binding contract, footer/help, README, design.md §6/§7, and user-guide edits.
- `o options` as the replacement board binding and label for Settings.

### Out of scope

- GitHub server-side search or any new network request.
- Searching across every column at once; each query has exactly one target.
- Persisting a query across application restarts or caching search results.
- Fuzzy ranking, regular expressions, saved searches, query syntax, or search
  history.
- A configuration surface for search fields or keybindings.
- Highlighting matching substrings inside cards; filtering and the visible
  input are the first feature.

## Design

- **State ownership.** `AppState` gains an optional `SearchState` with target
  `BoardColumn` and query `Text`. It is presentation state only: it is neither
  serialized nor part of `Board`/`RepoSnapshot`. Entering search creates
  `SearchState Issues ""`, selects Issues as the active column, clears a
  transient notice, and requests visibility so the horizontal board viewport
  reveals it.
- **Input priority.** While search is active and no higher-priority overlay is
  open, a search input decoder runs before `BoardScope`: lowercase `s` and
  `Esc` close, `q` and board-scoped `Ctrl-C` request guarded dashboard quit,
  Backspace removes one Unicode code point, printable characters append, and
  unsupported/control events are ignored or retain their global meaning where
  explicitly decided. This prevents ordinary board actions such as `r`, `S`,
  or `u` from firing while their characters are being typed. Application
  events such as refresh completion continue to reconcile state. In a live
  agent overlay, the existing higher-priority `Ctrl-C` interrupt behavior is
  unchanged.
- **One visible-entry authority.** A pure function derives the entries visible
  for a column from `Board` and optional `SearchState`. Every renderer,
  keyboard selection lookup, mouse target resolution, card action, boundary
  movement, and column count used in search mode consumes that view. Raw
  `Board` remains unchanged. Entry identity (`ItemId`, or the tracker issue
  number for structural headers) remaps selection whenever the query, target,
  expansion state, or refreshed board changes, falling back to the first
  selectable result and then to no item when the result is empty. Exiting
  remaps the selected result into the restored full column, so the same card
  stays selected rather than the same numeric row silently targeting another
  card.
- **Matching (D-6).** Use Unicode case-folded substring matching over
  the visible identity — `#number` plus title — with whitespace normalized.
  Do not search bodies, assignees, branches, or labels whose delivery may be
  truncated. A tracker header is retained when its own identity or any child
  matches. Matching children render under their header even when the epic is
  collapsed, but search does not mutate the persistent expanded-trackers set;
  exit restores the previous collapsed/expanded view.
- **Empty and no-result states.** An empty query shows the target column
  unfiltered beneath the empty box. A non-empty query with no matches shows a
  calm `No matches` row, distinct from the existing `No items` state. The
  column heading states result count versus total (for example, `2/18`) using
  the same entry-count semantics as the existing heading, so filtering is
  never mistaken for GitHub truncation; the existing `+` truncation signal
  remains attached to the total (D-9).
- **Layout.** The target column becomes a vertical composition of (1) an
  always-visible wrapped search box and (2) the existing scrollable card
  viewport. The box uses the column's inner width and existing text-width
  machinery, starts at one content line even for an empty query, and grows by
  exactly the wrapped content height. It is in normal layout flow, never an
  overlay, so every added row reduces the result viewport and shifts its cards
  down. It uses theme attributes and ASCII-compatible borders rather than a new
  image or asset. Input is bounded at 256 Unicode code points—enough to cover
  the complete identity field being matched while preventing unbounded state
  or layout growth. Further printable input is ignored until Backspace makes
  room. The visual box may consume the available column height, but must never
  overrun the footer or neighboring columns (D-9).
- **Column transfer (D-7).** A non-scroll click whose target belongs
  to another column changes the target, clears the query, selects/reveals that
  column, and consumes that first click so it cannot also open details, toggle
  an epic, or launch a session behind the user's focus change. Left/Right
  arrows provide the keyboard-equivalent transfer while search owns printable
  `h`/`l`; transfer clears the query by the same function. Wheel events keep
  scrolling the column under the pointer and do not transfer search.
- **Result interaction (D-7).** In the active target column, matching
  cards and epic headers retain ordinary mouse behavior, and Up/Down move the
  result selection. Enter opens the selected result. Opening an overlay closes
  search after preserving that selected item's identity, avoiding two active
  input owners. Returning from the overlay therefore shows the ordinary,
  unfiltered board at that card.
- **Failure and refresh behavior.** Search is total over empty/loading boards.
  Successful board refreshes re-run the query over the new board and preserve
  a still-present selected identity; failed refreshes leave the previous good
  board and current query untouched. Search never changes freshness or emits a
  network request itself.

## Decisions

### D-1. Search is a column-scoped, local board mode

The query filters exactly one existing workflow column using already-loaded
card data. It is not a GitHub search, global board search, or overlay. This
follows the requested movement of the input between columns and keeps filtering
instant and failure-free.

### D-2. Search opens on Issues and transfers with a cleared query

Pressing the new search key initially targets Issues, regardless of the column
previously selected. Clicking another column while search is active moves the
input there and clears the query before that column is searched. This is a
user-specified workflow rather than an inference from current selection.

### D-3. The input box participates in column layout and wraps vertically

The search input renders above the target column's cards, begins with one
content line, and grows when its visible query wraps. Cards move down by the
box's actual height. A floating overlay or fixed-height one-line prompt is
rejected because either would cover cards or hide the text being typed.

### D-4. Filtering is live, and closing restores the full column

Every text insertion or deletion recomputes visible entries locally. Lowercase
`s` or `Esc` clears/removes the search UI and restores the complete target
column. There is no explicit submit step and no search persistence. This
decision was amended by D-5 when the user moved search from `q` to `s`.

### D-5. Search uses s; q remains quit; Ctrl-C also quits from the board

User signoff 2026-08-11. Inactive `s` opens search and active `s` closes it;
`Esc` also closes search. `q` retains the existing guarded dashboard quit
action, including while search is active, and `Ctrl-C` becomes a second
board-scoped chord for that same action. Moving quit away from `q` was rejected
when the user changed the requested search key. Live-agent overlays keep their
higher-priority `Ctrl-C` interrupt action; this scoped reuse is already how the
central event model distinguishes board and overlay input. Consequence:
Settings moves to `o options` under D-8.

### D-6. Match number and title while preserving epic context

User signoff 2026-08-11. Matching is a Unicode case-insensitive substring over
the visible `#number` and title only. Bodies, labels, assignees, branches, and
status prose are excluded. A tracker header remains when it or a child matches,
and matching children are temporarily shown beneath collapsed epics without
changing the saved expansion state. Broader hidden-field search was rejected
because a result should be explainable from the identity shown on the board.

### D-7. Search results remain actionable, and transfer consumes its first click

User signoff 2026-08-11. The first non-scroll click in another column only
transfers search and clears the query; it does not also activate what was
clicked. Clicks in the target column retain ordinary card/epic behavior,
Up/Down selects results, Enter opens the selected result and ends search, and
Left/Right transfers between columns while clearing the query. Wheel scrolling
does not transfer search. This keeps filtered results useful and supplies a
keyboard equivalent for column transfer without accidental double actions.

### D-8. Settings moves to o options

User signoff 2026-08-11. The Settings overlay moves from `s settings` to
`o options`, freeing lowercase `s` for search while keeping Settings fully
keyboard-accessible. `o` is unclaimed in the current base-board registry and
is more discoverable than the rejected punctuation alternative `,`; uppercase
`S` remains the existing Solve action. The central binding registry, footer,
help overlay, README, user guide, and design.md §7 must all change together.

### D-9. Filtered counts are explicit and search input is bounded

User readiness signoff 2026-08-11. While a non-empty query is active, the
target heading shows visible-result count over the full column count using the
existing entry-count semantics, with GitHub's `+` truncation marker retained
on the total. The query is capped at 256 Unicode code points; additional
printable input is ignored until deletion makes room. These deterministic
defaults replace the exploratory count and input-bound proposals. Omitting the
result/total distinction was rejected because a filtered count could otherwise
look like a complete GitHub column; an unbounded query was rejected because
the input participates directly in board height.

### D-10. Deliver the arc as three dependency-ordered slices

User signoff 2026-08-11. The design's original single slice carried the whole
arc, which both prevented an honest umbrella epic and bundled a keybinding
remap with a new feature against `CLAUDE.md`'s one-concern-per-pull-request
rule. The adopted decomposition, in work order:

1. **SRCH-1 — Move Settings to `o options` and add `Ctrl-C` as a second board
   quit chord.** Decisions D-8 and D-5's quit-chord half. No search code, no
   `s` binding: `s` is simply left unbound and the registry, footer, help,
   README, user guide, and design.md §7 describe only `o options` and the
   second quit chord. Depends on nothing and can land first; everything after
   it needs `s` free. Only `test/golden/overlay-help.txt` changes among the
   golden frames.
2. **SRCH-2 — Add the column-scoped search mode on Issues with safe filtered
   selection.** Decisions D-1, D-3, D-6, D-9, D-2's open-on-Issues half, D-4,
   D-5's input-priority half, and D-7's in-target-column result interaction.
   `s` opens the wrapped box above the Issues cards, editing filters live, the
   heading shows result/total, `s`/`Esc` restores the full column, and Up/Down,
   Enter, and clicks inside the target column all resolve to the item actually
   shown. Depends on SRCH-1; critical path. This is the smallest slice that is
   both useful and safe — per the decomposition evidence, filtering the view
   without simultaneously fixing selection and mouse dispatch would let a
   visible card act on a different underlying entry, so those cannot be
   separated.
3. **SRCH-3 — Transfer the active search between columns.** D-2's transfer half
   and D-7's transfer-click half. Clicking another column, or Left/Right, moves
   the box there and clears the query; the first transferring click is consumed
   so it cannot also open details, toggle an epic, or start a session; wheel
   events keep scrolling without transferring. Depends on SRCH-2; critical
   path.

Rejected decompositions and why: a pure-only slice landing `SearchState`, the
matcher, and the derived view with no consumer would be unreachable code and is
a predictable canonical-review blocker; a rendering-only slice landing the box
before filtering would show an input that does nothing; splitting result
interaction out of SRCH-2 would ship the exact dispatch hazard D-1 exists to
prevent; and folding SRCH-3 back into SRCH-2 was rejected in favor of the
smaller reviewable pull requests, accepting one intermediate release in which
search cannot leave the Issues column.

### D-11. Left/Right are inert while search is active until transfer lands

User signoff 2026-08-11, resolving Q-5. In SRCH-2, Left and Right do nothing
while search is active, so the search target and the selected column can never
disagree. SRCH-3 then gives those keys their D-7 transfer meaning without
changing behavior a user already learned. Letting them keep moving the column
selection was rejected because it would create a searched-column/selected-column
split that no part of this design describes, and would change the same keys'
meaning twice across two releases.

## Open questions

### Q-1. What replaces the existing board-level `q` quit binding?

Resolved by D-5. Search moved to `s`; `q` remains quit and board-scoped
`Ctrl-C` becomes an additional quit chord. Live-agent `Ctrl-C` remains its
higher-priority scoped interrupt action.

### Q-2. Which card fields match, and how should epic structure behave?

Resolved by D-6.

### Q-3. What should a click or navigation key do while results are active?

Resolved by D-7.

### Q-4. Which key should open Settings after search takes `s`?

Resolved by D-8.

### Q-5. What do Left/Right do while search is active, before transfer exists?

Raised during the D-10 decomposition on 2026-08-11: D-7 gives Left/Right the
column-transfer meaning, but transfer lands in SRCH-3, so SRCH-2 had to define
them for one intermediate release. Resolved by D-11.

## Verification strategy

- Pure matching tests cover empty query, case folding, number/title matching,
  no matches, tracker-header retention, collapsed matching children, and
  result/total counts.
- Pure transition tests cover enter, insert, Unicode Backspace, transfer,
  the 256-code-point bound, close, refresh, and identity-based selection
  reconciliation; no visible row may dispatch to a different raw card.
- Event precedence tests prove search consumes printable board keys, `s`, and
  `Esc` while application events still apply; `q` and board-scoped `Ctrl-C`
  reach the guarded quit path; and live-agent `Ctrl-C` still interrupts rather
  than quitting.
- Mouse tests cover a card, epic header, whitespace, right-click, and wheel in
  both target and non-target columns, according to D-7.
- Golden Brick frames add an empty one-line search, a wrapped query, filtered
  results, no results, a collapsed epic match, and narrow/open-border/ASCII
  coverage. Frame assertions verify the box is above the cards, shifts them by
  its rendered height, remains inside the target column, and never covers the
  footer.
- `test/Spec/UI/Keys.hs` and design.md §7 stay in exact parity; README,
  `docs/user-guide.md`, the footer, and help explain search, both quit chords,
  and `o options`.
- Search exercises no GitHub command or cache write; fake/network integration
  coverage is unnecessary.

Distribution across D-10's slices: the key-registry, contract-parity, and
quit-chord families land with SRCH-1; the matching, transition, event-precedence
and layout/golden families land with SRCH-2; the mouse matrix and its transfer
cases land with SRCH-3, which also re-records the frames SRCH-2 established.

## Delivery plan

### SRCH-1. Move Settings to `o options` and add a second board quit chord

- **Outcome:** Settings opens on `o` instead of `s`, board-scoped `Ctrl-C`
  quits through the same guarded path as `q`, and `s` is left unbound and free
  for SRCH-2. Live-agent overlays keep their higher-priority `Ctrl-C`
  interrupt.
- **Scope:** the `ShowSettings` key and label in the central binding registry,
  the added `QuitDashboard` chord, and the footer, help overlay, README,
  `docs/user-guide.md`, and design.md §7 text that projects from or documents
  them, plus `test/Spec/UI/Keys.hs` registry/contract/help/footer parity and
  the one affected golden frame.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** can land first; critical path, because SRCH-2 needs `s` free
- **Relevant decisions:** D-5 (quit-chord half), D-8, D-10
- **Acceptance signals:** `o` opens Settings and `s` does nothing on the base
  board; `q` and `Ctrl-C` both reach the existing guarded dashboard-quit path;
  `Ctrl-C` inside a solve, review, or pull-request overlay still interrupts the
  turn rather than quitting; `test/Spec/UI/Keys.hs` and design.md §7 remain in
  exact parity; the golden suite passes with `overlay-help.txt` re-recorded.
- **Out of scope:** all search behavior, including any `s` binding, search
  state, or search rendering.
- **Open questions:** None

### SRCH-2. Add the column-scoped search mode on Issues with safe filtering

- **Outcome:** `s` opens an empty one-line search box directly below the Issues
  header and above its cards; typing filters the column on every edit; the
  heading shows result count over column total; `s` or `Esc` clears the query,
  removes the box, and restores the full column; and every visible row still
  resolves to the item shown under both keyboard and mouse.
- **Scope:** the ephemeral `SearchState` on `AppState`, the pure case-folded
  matcher over `#number` plus title, the one derived visible-entry authority
  consumed by drawing, tracker grouping, selection, mouse dispatch, and the
  heading count, identity-based selection reconciliation across edit, close,
  and refresh, the search-input decoder ahead of `BoardScope`, the wrapped box
  in normal column layout with its 256-code-point bound, the `No matches` row,
  result/total counts, in-target-column result interaction (Up/Down, Enter,
  clicks), and the pure, event, golden, and documentation updates for all of
  it.
- **Phase:** 2
- **Depends on:** SRCH-1
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-2 (open-on-Issues half), D-3, D-4, D-5
  (input-priority half), D-6, D-7 (in-target-column result interaction), D-9,
  D-10, D-11
- **Acceptance signals:** typing `r`, `S`, `u`, or `d` while search is active
  inserts characters instead of dispatching a board action, while `q` and
  `Ctrl-C` still quit and application events still reconcile; no visible
  mouse or keyboard target dispatches to a different raw entry at any query;
  a collapsed epic's matching children appear without mutating the saved
  expansion set, and exit restores the previous collapsed view; the heading
  reads result/total with the `+` truncation marker still on the total; the
  query stops accepting input at 256 code points; Left and Right do nothing
  while search is active; golden frames cover empty, wrapped, filtered,
  no-result, and collapsed-epic-match states at wide, narrow, open-border, and
  ASCII settings, with the box above the cards, inside its column, and never
  over the footer; no GitHub command, cache write, or freshness change occurs.
- **Out of scope:** moving search to another column by any means, which is
  SRCH-3; cross-column or global queries; fuzzy or regex matching; saved
  searches; match highlighting; configurable bindings.
- **Open questions:** None

### SRCH-3. Transfer the active search between columns

- **Outcome:** clicking another column while search is active, or pressing Left
  or Right, moves the box to that column's top, clears the query, and reveals
  and selects that column; the first transferring click is consumed so it
  cannot also open details, toggle an epic, or start a session; wheel events
  keep scrolling the column under the pointer without transferring.
- **Scope:** the target-column change and shared query-clearing function, the
  first-click consumption rule, the Left/Right transfer binding that replaces
  D-11's inert behavior, wheel-versus-click discrimination, selection
  reconciliation into the newly targeted column, and the pure, event, mouse,
  golden, and documentation updates for the transfer path.
- **Phase:** 3
- **Depends on:** SRCH-2
- **Ordering:** critical path
- **Relevant decisions:** D-2 (transfer half), D-7 (transfer half), D-10, D-11
- **Acceptance signals:** a left click on a card, an epic header, or whitespace
  in a non-target column transfers search and performs no other action, and a
  second click there behaves normally; Left and Right transfer and clear the
  query; a wheel event in either a target or non-target column only scrolls;
  the query is cleared by the same function on every transfer path; golden
  frames show the box in a transferred column; README, `docs/user-guide.md`,
  and design.md §6/§7 describe transfer.
- **Out of scope:** searching more than one column at once, persisting a query
  across transfers or restarts, and any change to the matching rule settled in
  D-6.
- **Open questions:** None
