# Column issue search design

Kanban boards can grow beyond what is practical to scan or traverse one card at
a time. This design adds a lightweight, column-scoped search mode: one key opens
an input above the Issues cards, text filters cards immediately, and the search
can move to another workflow column without becoming a detached overlay.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [ ] EPIC. Add live column-scoped card search to the board
- [ ] SRCH-1. Add the adaptive search bar and safe live card filtering

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
  rerun at readiness with the same result.

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

## Delivery plan

### SRCH-1. Add the adaptive search bar and safe live card filtering

- **Outcome:** `s` opens a visible, wrapped search input on Issues; edits
  filter the target column immediately; search transfers between columns and
  closes cleanly; matching results remain safe to select and activate under
  keyboard and mouse.
- **Scope:** ephemeral state, pure matching/view derivation, selection
  reconciliation, event priority, Settings-key replacement, the additional
  board quit chord, adaptive board layout, column/result counts, mouse
  transfer, key/help/footer/contract/docs updates, and pure/event/golden tests.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-2, D-3, D-4, D-5, D-6, D-7, D-8, D-9
- **Acceptance signals:** the verification matrix passes at wide and narrow
  widths; typing never dispatches a board action; every visible mouse/keyboard
  target resolves to the item shown; result/total counts and the input bound
  are deterministic; exit restores the full target column; no network or
  persistence behavior changes.
- **Out of scope:** cross-column/global queries, fuzzy/regex search, saved
  searches, match highlighting, configurable bindings.
- **Open questions:** None
