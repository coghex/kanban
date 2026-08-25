# Overlay fullscreen and session focus design

The overlay subwindows — details, review, solve, PR review, incidents,
processes, settings, help — draw as small fixed-size centered boxes (88×32
for most), which Vincent likes on open because the board stays visible
behind them, but which waste most of a large terminal once he is actually
reading a long transcript or issue body. This arc adds a lowercase `f`
fullscreen toggle available only while an overlay is open, gives the three
live-session overlays a vim-style normal/insert focus model so a plain `f`
(and future plain keys) can be commands rather than typed text, and moves
the card filter from `f` to capital `F` so the letter is unambiguous.
Vincent is the sole operator; the pipeline agents never see the TUI.

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Toggle any open overlay fullscreen and make session input modal — [#512]
- [x] OVF-1. Rebind the card filter from `f` to `F` — [#513]
- [x] OVF-2. Give session overlays a vim-style normal/insert focus model — [#515]
- [x] OVF-4. Make the base footer the context-aware hotkey row — [#525]
- [ ] OVF-3. Add the `f` fullscreen toggle for open overlays

## Epic contract

- **Goal:** any open overlay toggles between today's small windowed box and
  a fullscreen layout with one keystroke, the session overlays' input line
  is modal so plain keys are commands until `i` enters insert, and the card
  filter answers `F`.
- **Done when:** all four slices are merged; design.md §6, §7, and §11 are
  amended in the same pull requests as the behavior they gate; the
  multi-repo boards arc carries the fullscreen/tab-row interplay notes;
  every overlay except the solve chooser honors the toggle; and the base
  footer is the single context-aware hotkey row.
- **Users and operators:** Vincent, reading long transcripts, reviews, and
  issue bodies in the TUI. No agent-facing or pipeline behavior changes.
- **Arc label:** None proposed.

## Current state and evidence

- Every layered overlay draws through one shared geometry seam:
  `drawOverlay` (`src/Kanban/UI/Overlay.hs:64-123`) holds the only
  `centerLayer` in `src/` and the only `hLimit`/`vLimit` applied to an
  overlay box. `overlayWidth` (`:84-94`) gives the solve chooser 42,
  settings 68, processes and incidents 100, help its measured width, and
  everything else 88; `overlayHeight` (`:95-103`) gives the chooser 10,
  settings 19, help its measured height, and everything else 32.
- A second, non-shared tier sits inside the panels: interior scroll
  viewports hard-code heights against the outer 32 — processes `vLimit 23`
  (`Overlay.hs:183`), incidents `vLimit 23` (`:226`), solve transcript
  `vLimit 19` (`:369`), PR review transcript `vLimit 19` (`:430`), review
  transcript `vLimit 17` (`:461`). Details is the exception: a bare
  vertical viewport (`:78`) that already fills whatever it is given. The
  incidents and details bodies measure width at render time and adapt.
- Overlay state is `appOverlay :: Maybe Overlay`
  (`src/Kanban/UI/Types.hs:609`) over the sum type at `:139-149`
  (help, settings, processes, incidents, details, review, solve chooser,
  solve, PR review). It is set from roughly fourteen sites across
  `UI/Events.hs`, `UI/Solve.hs`, `UI/Review.hs`, `UI/PullRequest.hs`,
  `UI/Selection.hs`, and `UI/Reconcile.hs`, and closed through
  `closeOverlay` (`src/Kanban/UI/State.hs:49-50`) and the shared Esc arm
  (`UI/Events.hs:182`).
- Key bindings declare through `KeyBinding` rows in
  `src/Kanban/UI/Keys.hs`, each carrying the verbatim §7 action cell as
  `bindingContract`; `test/Spec/UI/Keys.hs:187-200` parses design.md §7 and
  asserts sorted equality plus an exact row count against
  `boardBindings + sessionInputHelp`. `BindingScope` (`Keys.hs:88-96`) is
  only `BoardScope | DetailsScope | HelpScope`; settings, processes,
  incidents, and the session overlays deliberately consume input before the
  table (`:83-87`), so "any overlay open" is not expressible there today.
- `f` is bound three times, all board-side: `ShowFilter`
  (`Keys.hs:187-189`, `BoardScope`), hide-the-open-filter-panel
  (`src/Kanban/UI/Filter.hs:226`), and focus-the-filter-from-search
  (`src/Kanban/UI/Search.hs:449`). The search special-case means the letter
  `f` cannot currently be typed into a search query.
- The session overlays route every plain printable into the agent input
  line: `sessionInputEvent` (`src/Kanban/UI/SessionCore.hs:279-291`) maps
  Tab to session cycling, Ctrl-C to interrupt, Backspace/Enter/printables
  to text entry, digits to a pending agent choice when
  `sessionCapsChoiceDigits` is set, and arrows (plus review-only
  Ctrl-J/Ctrl-K, `:298-303`) to transcript scrolling. Esc closes the
  overlay via the shared fallback arm. `j`/`k` cannot scroll a session
  transcript today because they are text.
- Overlay footers are seven hard-coded literals inside the boxes
  (`Overlay.hs:169,189,232,351,378,436,472`), not projected from
  `Keys.hs`; the help overlay is generated from
  `boardBindings <> sessionInputHelp <> mouseHelpEntries`
  (`Overlay.hs:143-144`).
- Golden frames exist for only two overlays — `overlay-details.txt` and
  `overlay-help.txt` (`test/Spec/UI/Golden.hs:505-518`, 200×48). The
  incidents panel's fixed-width elision contract is asserted by rendering
  the real `drawOverlay` at widths 200/164/36
  (`test/Spec/UI/Incidents.hs:631-660`), and design.md §11 states "The
  panel is a fixed-width overlay, so a row is measured against the width
  that overlay gives it rather than the terminal's."
- Nothing named fullscreen/full-screen/maximize exists anywhere in `src/`
  or `docs/`. The tracker has no overlapping arc: #348 (the `f` filter
  panel) is closed, and epic #354 (multi-repo boards) is adjacent, not
  overlapping.
- Multi-repo interplay: `docs/multi_repo_boards_design.md` D-1/D-14 put a
  single full-width tab row at the very top, above the existing frame,
  rendered only with two or more repositories; D-13 records that arc
  avoided `f` for tab cycling because "open issue #348 claims it for the
  filter panel" — a remark OVF-1 makes stale. MRB-1..MRB-5 are all
  unprocessed, so nothing here changes running code in that arc.

## Desired experience

Vincent opens a review, solve, PR review, details, incidents, processes,
settings, or help overlay and it appears at today's small size, board still
visible behind it. Pressing `f` makes the box fill most of the screen: it
covers the board and the usage sidebar, leaving only a small border on the
left and right, the multi-repo tab row (once it exists) visible above, and
the hotkey footer row visible below. Fullscreen deliberately does not mean
the literal full terminal — the bottom row always shows the hotkeys
available in the current context, and the top row always shows the tabs.
Pressing `f` again returns to the small box. Closing the overlay resets
the state: the next overlay opens small.

In a solve, review, or PR review overlay the session starts in normal
mode, shown by a `[N]` indicator: `f` toggles fullscreen, Tab cycles
sessions, Ctrl-C interrupts, `q` closes the window, and navigation keys
scroll the transcript. Pressing `i` enters insert mode — a green `[I]` —
where typing goes into the agent input line exactly as it does today.
Pressing Enter submits the message and drops back to normal mode, so when
the agent answers with numbered choices they are immediately pickable with
the digit keys. Esc in insert returns to normal; Esc in normal closes the
window. The filter panel, meanwhile, now answers `F` from the board, and
the letter `f` becomes typable in a search query.

## Scope

### In scope

- The `f` fullscreen toggle for every overlay except the solve chooser,
  with the interior scroll viewports growing to use the space.
- A normal/insert focus model for the three live-session overlays,
  including the mode indicator and the amended Esc behavior.
- Rebinding the card filter to `F` in all three of its contexts (board
  toggle, panel hide, focus-from-search).
- Making the base footer the single projected, context-aware hotkey row
  and retiring the overlays' in-box hint literals.
- The design.md §6/§7/§11 amendments those changes require, and the
  interplay notes owed to `docs/multi_repo_boards_design.md`.

### Out of scope

- Vim conventions for board-side surfaces: the card search box and the
  filter panel keep their current non-modal input.
- The multi-repo tab bar itself (epic #354); this arc only records the
  interplay so MRB-3 and OVF-3 stay consistent.
- Fullscreen for the solve chooser (D-2).
- Persisting fullscreen across application restarts, or any settings
  surface for it.
- Configurable keybindings (design.md §7's deferral stands).

## Design

- **State.** One `appOverlayFullscreen :: Bool` on `AppState` beside
  `appOverlay`, mirroring `appSidebarVisible`. Adding a field to the
  `Overlay` constructors was rejected: `appOverlay` is compared and
  pattern-matched in ~30 places. Reset-on-close (D-5) lands naturally in
  `closeOverlay`, but several open-overlay transitions bypass close (e.g.
  incidents-Enter jumping straight into a session overlay), so the slice
  should route overlay opening through one setter seam rather than clearing
  the flag at fourteen sites.
- **Geometry.** `drawOverlay` grows a fullscreen branch: when the flag is
  set and the overlay is not the solve chooser, the box spans the terminal
  width minus a small border on each side, and the height from below the
  multi-repo tab row (once that exists) to above the base footer hint row,
  covering the usage sidebar and the board (D-10). The five interior
  `vLimit` constants stop being literals against 32 and derive from the
  granted height (or the bodies become greedy with the footer pinned),
  otherwise a fullscreen frame would hold a 19-line transcript floating in
  empty space. Details needs nothing.
- **Footer.** The base footer hint row stays visible under a fullscreen
  overlay and becomes the single projected, context-aware hotkey line
  (D-14). Today it only swaps for the board's filter and search contexts
  (`Board.hs:979-983`); under any open overlay it still shows the board's
  keys, while each overlay draws its own hard-coded hint literal inside
  its box. OVF-4 extends the projection to every overlay context — mode-
  aware inside session overlays, so `[N]` and `[I]` show different key
  sets — and retires the seven inner literals. The help overlay's
  generated rows stay the long-form reference.
- **Dispatch.** The non-session overlays (details, incidents, processes,
  settings, help) take `f` in their per-overlay arms or in one shared guard
  arm ahead of them in `UI/Events.hs`; the session overlays take `f` as a
  normal-mode command through the focus model. The binding needs a
  contract-carrying `HelpEntry` (a new `BindingScope` or a
  `sessionInputHelp`-style list) so `Spec.UI.Keys` forces the §7 row and
  the help overlay row into the same PR.
- **Focus model.** A per-session (or per-overlay) mode value, normal by
  default on open, indicated by `[N]` / a green `[I]` (D-9). Normal mode:
  `f`, Tab, Ctrl-C, `r` where it already applies, transcript scrolling
  (`j`/`k` by line, `g`/`G` to the ends, Ctrl-D/Ctrl-U by 16, D-16),
  digit choice-picks when a numbered prompt is pending (D-11), `i` to
  insert, `q` and Esc to close the window (D-7; the chain stops there,
  D-12). Insert mode: printables/Backspace as today, Enter submits and
  returns to normal (D-8), Esc back to normal, Ctrl-C still interrupts.
  Insert stays reachable mid-turn so steers queue as today, and an
  arriving numbered-choice prompt forces normal mode (D-13). Sessions
  without a live text input (a canonical review stage, an interrupted
  terminal state) are treated as Q-4. The `sessionInputHelp` rows change
  with the model, and the in-box footer literals retire under D-14.
- **Mouse.** A fullscreen overlay has no outside-click-to-close: clicks
  on the residual strips do nothing to it, and the exits are `f`, `q`,
  Esc, and right-click per the details precedent (D-17). The windowed
  gesture keeps today's meaning; the §7 mouse policy amendment records
  both.
- **Contracts touched.** design.md §7 key table rows (`f` fullscreen row,
  the amended `F` filter row, the `s` search row's description, the Esc
  row, the session-overlay rows), §6's layout notes if the fullscreen
  geometry is described there, §11's incidents fixed-width sentence
  ("measured against the width that overlay gives it" becomes
  windowed-vs-fullscreen aware), and `docs/user-guide.md`'s filter and
  search passages.

## Decisions

### D-1. Lowercase `f` toggles fullscreen, and only while an overlay is open

User signoff 2026-08-20 (the arc's founding request: the hotkey "should
only show up when a subwindow is open"). `f` is not a board-scope binding;
it exists only inside open overlays, toggling between the small windowed
box and fullscreen. Overlays always open small because Vincent explicitly
values seeing the board behind a freshly opened panel. Rejected
alternatives: a chord (`Ctrl-F`) as the primary binding — superseded by
D-6, which makes plain `f` available in the session overlays; and making
fullscreen a board-level or startup setting, which loses the start-small
behavior.

### D-2. Fullscreen keeps the application frame, and the tab row stays above

User signoff 2026-08-20. The fullscreen box retains its own border and
title, and the application's outer chrome remains: in particular, once the
multi-repo tab row (multi_repo_boards_design.md D-14, one full-width row at
the very top) is implemented, it stays visible above a fullscreen overlay,
and the fullscreen height budget is the terminal minus that row.
Consequence: OVF-3 records this interplay in the multi-repo design document
so MRB-3 implements the tab row knowing fullscreen sits below it.

### D-3. The card filter's key becomes capital `F`

User signoff 2026-08-20 ("the filter is going to need to be capital f
'F'"). All three contexts move together so the filter key is one letter
everywhere: the board-scope toggle (`Keys.hs:187-189`), hiding the open
panel from inside it (`Filter.hs:226`), and focusing the filter from an
open search box (`Search.hs:449`). Side effect worth keeping in the issue:
lowercase `f` becomes typable in a search query for the first time, at the
cost of capital `F`, which is far rarer in issue-title searches.
Consequence: multi_repo_boards_design.md D-13's remark that "#348 claims
`f` for the filter panel" goes stale and gets a correcting note.

### D-4. Every overlay honors fullscreen except the solve chooser

User signoff 2026-08-20 (chose "all except solve chooser"). Details,
review, solve, PR review, incidents, processes, settings, and help all
honor the toggle; the 42×10 Codex/Claude chooser stays a small centered
box, where fullscreen buys nothing. Rejected alternatives: only the four
overlays the founding request named (loses details, the longest-content
panel of all), and uniform coverage including the chooser.

### D-5. Fullscreen resets when the overlay closes

User signoff 2026-08-20. A newly opened overlay always starts windowed;
the flag persists across Tab session cycling while an overlay stays open,
and clears on close. Rejected alternative: sticky-for-the-session, where
later overlays would open fullscreen until toggled back — loses the
start-small behavior D-1 records. Open-overlay transitions that bypass
`closeOverlay` must still reset (see the state seam note in Design).

### D-6. Session overlays adopt a vim-style normal/insert focus model

User signoff 2026-08-20 (user's own formulation: "we shouldnt capture
text until we hit 'i' ... we already adopt vi rules with the navigation,
why not go all the way vim conventions? that is what i am used to anyways
and its a personal project"). The solve, review, and PR review overlays
start in normal mode, where plain keys are commands — enabling `f` for
fullscreen and freeing `j`/`k` for transcript scrolling — and `i` enters
insert mode, where typing feeds the agent input line as it does today.
Rejected alternatives: `Ctrl-F` as the fullscreen chord inside session
overlays (keeps always-capture, adds a chord where a bare key should
work), and excluding session overlays from fullscreen entirely (loses the
feature exactly where transcripts are longest). Costs accepted with the
decision: typing guidance costs an `i` first, and Esc's close behavior is
restaged (D-7, Q-1). The indicator is D-9, digit ownership is D-11, and
mid-turn insert (Q-2) and no-input sessions (Q-4) stay open.

### D-7. `q` and Esc close the window from normal mode; Esc stages through it

User signoff 2026-08-20 ("if we are going full vim, then q is going to
quit the window only, it wont quit the app"; "if i am in insert mode,
escape will bring us to [normal] mode, escape again will close the editor
window"). In a session overlay, `q` in normal mode closes the overlay —
never the application — and Esc stages: insert-Esc drops to normal,
normal-Esc closes the window. Whether the chain has an outermost stage
where Esc (or `q`) at board level closes the application is deliberately
open as Q-1; only the in-overlay stages are decided here. Consequence:
design.md §7's Esc row and the session-overlay rows are rewritten, and
`q`'s row must distinguish the board-level quit from the overlay-level
close.

### D-8. Enter submits and returns to normal mode

User signoff 2026-08-20 ("when the user hits enter on a command, we want
to be dropped out of insert mode back into the default [normal] mode").
Submitting a message from insert mode lands the session back in normal
mode, so an agent reply that presents numbered choices is immediately
pickable without an extra Esc.

### D-9. The mode indicator is `[N]` and a green `[I]`

User signoff 2026-08-20. The session overlay shows the current mode the
way Vincent's vim-mode terminals already do: a green `[I]` for insert, a
`[N]` for normal. This resolves the indicator question (formerly Q-3);
placement (on the input line's label or beside it) is an implementation
detail for the slice, and golden frames pin whatever is drawn.

### D-10. Fullscreen fills most of the screen, never all of it

User signoff 2026-08-20 ("fullscreen doesnt literally mean fullscreen, it
means 'make much bigger so that it fills most of the screen'"). The
fullscreen box covers the board and the usage sidebar (the left column),
leaving a small border on the left and right, the multi-repo tab row
visible above once it exists, and the base footer hint row visible below
— the bottom row of the terminal must keep showing the hotkeys available
in the current context. This resolves the extent half of former Q-5; the
footer's required context-dynamism is Q-7.

### D-11. Numbered choices are picked from normal mode

User signoff 2026-08-20. Agent-offered numbered choices are selected with
the digit keys in normal mode, which D-8's Enter-drop makes the mode the
user is already in when choices appear. In insert mode digits are literal
text. Whether normal mode is *forced* while the agent works — Vincent's
stated instinct, in tension with the review overlay's mid-turn steer
queue — is Q-2, and vim-style count prefixes for normal-mode commands are
the deferred Q-8.

### D-12. The Esc chain stops at closing the window

User signoff 2026-08-20 (chose "Esc stops at the window" over the
originally floated third stage). Esc stages insert → normal → close the
window and goes no further: at board level Esc keeps dismissing a
transient error and otherwise does nothing, matching vim's own
Esc-in-normal-mode behavior. `q` and Ctrl-C remain the only board-level
application quits, so board-level `q` keeps today's meaning while
overlay-level `q` closes only the window (D-7). Rejected alternatives:
the full three-stage chain ending in an app quit (an Esc pressed to
dismiss an error, or one bounce too many, would exit the application) and
a confirmation prompt on board-level Esc.

### D-13. Insert stays reachable mid-turn; a choice prompt forces normal

User signoff 2026-08-20. While the agent is working, `i` still enters
insert so the next steer can be drafted and queued exactly as the review
overlay's NOT DELIVERED mechanism works today (`Overlay.hs:547-554`,
`applyUndeliveredSteer`). The moment the agent presents a numbered-choice
prompt, the session forces normal mode, so the digits are instantly
pickable (D-11) no matter what the user was doing. Rejected alternatives:
forcing normal for the whole turn (kills mid-turn drafting and makes the
steer queue vestigial) and no forcing at all (a choice prompt arriving
during insert would require an Esc first).

### D-14. The base footer becomes the one home for context hotkeys

User signoff 2026-08-20 ("the bottom needs to be the hotkeys … as we
enter the different windows, different commands will become available or
be no longer available"). The base footer hint row becomes the projected,
context-aware hotkey line for every context — board, filter, search, and
each open overlay, mode-aware inside session overlays — and the seven
hard-coded in-box hint literals (`Overlay.hs:169,189,232,351,378,436,472`)
retire in its favor. One source of truth, and fullscreen's visible bottom
row (D-10) is honest rather than stale. This is its own delivery slice
(OVF-4), sequenced before the fullscreen slice so the height arithmetic
lands once. Rejected alternatives: keeping the in-box hints alongside an
overlay-aware footer (redundant), and swapping the footer only in
fullscreen (inconsistent). Resolves former Q-7.

### D-15. Sessions without a live text input sit permanently in normal mode

User signoff 2026-08-20. A canonical review stage (whose process Ctrl-C
kills and only `r` restarts) and an interrupted terminal state show `[N]`
and treat `i` as a no-op, so `f`, `q`, Tab, and scrolling work uniformly
and nothing pretends typed text will be read. Rejected alternative:
hiding the indicator for such sessions — less uniform for no gain.
Resolves former Q-4.

### D-16. Normal mode scrolls vim-style, and the workaround chords retire

User signoff 2026-08-20 (user's own spec: "j/k scrolls one line at a
time, g jumps to top, G jumps to bottom, and a ctrl-D and ctrl-U to
scroll by 16"). Normal mode binds `j`/`k` for single-line transcript
scrolling, `g`/`G` for top and bottom, and Ctrl-D/Ctrl-U for 16-line
jumps; arrows keep working in both modes. The review overlay's
Ctrl-J/Ctrl-K chords — workarounds for printables being eaten — retire
from `transcriptScrollKey` and §7. Resolves former Q-6.

### D-17. Fullscreen has no outside-click; the exits are explicit

User signoff 2026-08-20. In fullscreen, clicks on the residual side
borders, the tab row, or the footer do nothing to the overlay; the exits
are `f` back to windowed, `q`/Esc per D-7/D-12, and right-click where the
details precedent applies. Rejected alternative: letting the strips count
as outside-click-to-close, which invites accidental closes at the screen
edges. The §7 mouse policy amendment records this alongside the windowed
gesture, which keeps today's meaning. Resolves former Q-5.

## Open questions

### Q-1. Does the Esc chain reach an outermost close-the-app stage?

Resolved by D-12.

### Q-2. Is insert mode reachable while the agent is working?

Resolved by D-13.

### Q-3. How is the current mode shown?

Resolved by D-9.

### Q-4. What mode are sessions without a live text input in?

Resolved by D-15.

### Q-5. What still closes a fullscreen overlay by mouse?

Resolved by D-17.

### Q-6. Does normal mode take over transcript scrolling, and what happens to Ctrl-J/Ctrl-K?

Resolved by D-16.

### Q-7. Does the base footer become the context-sensitive hotkey row?

Resolved by D-14.

### Q-8. Do normal-mode digits become vim-style count prefixes?

Deferred at Vincent's own flag ("numbers ideally should repeat commands
like vim macros, but maybe i am getting ahead of myself here"). When no
numbered choice is pending, digits in normal mode could accumulate a
count applied to the next command (`5j` scrolls five lines). No conflict
with D-11 — counts would apply only while no choice prompt is pending —
but it is not needed for this arc and stays a recorded idea unless
promoted.

## Verification strategy

- `Spec.UI.Keys` enforces the §7 coupling: every new or amended binding row
  (the `F` filter row, the `s` search row, the `f` fullscreen row, the Esc
  and session rows) must land with its `bindingContract`/`HelpEntry`
  counterpart in the same PR, in both directions.
- Golden frames: new fullscreen variants beside the seven existing overlay
  frames — `overlay-details`, `overlay-help`, and the five
  `overlay-settings` variants — plus a session overlay frame showing the
  mode indicator; the existing windowed frames must not change.
- The incidents fixed-width elision suite
  (`test/Spec/UI/Incidents.hs:631-660`) extends to the fullscreen width,
  and §11's fixed-width sentence is amended with it.
- `sessionInputEvent` stays a pure function, so mode transitions (normal
  `i` → insert, insert Esc → normal, mode-aware printables and digits) get
  ordinary unit tests without an `EventM` harness.
- Live acceptance passes through the established tmux flow, exercising `f`
  in a details overlay, a session overlay in both modes, and the
  reset-on-close behavior. There is no snapshot-cache fixture board to run
  it against: open cards are live-only (design.md §13), and
  `src/Kanban/Cache.hs:181-183` records that the dashboard neither loads a
  repository snapshot at startup nor persists one afterwards. So the board
  populates from a real refresh, and the run is isolated instead by
  redirecting `HOME` to a scratch directory — through a wrapper script the
  session launches rather than `tmux new-session -e` — which moves the
  config, cache, and managed-component records with it.

## Delivery plan

### OVF-1. Rebind the card filter from `f` to `F`

- **Outcome:** the filter toggle, the panel's hide key, and the
  search-box's focus-filter key all answer `F`; lowercase `f` types into a
  search query; docs and tests agree.
- **Scope:** `Keys.hs` binding and contract text, `Filter.hs:226`,
  `Search.hs:449`, design.md §7 `f`→`F` row and the `s` row's description,
  the §6/§7 filter-panel prose, `docs/user-guide.md`'s five mentions, and
  the affected filter/search/filter-panel specs and any footer-hint golden
  frames.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** can land first
- **Relevant decisions:** D-3
- **Acceptance signals:** `Spec.UI.Keys` passes with the amended rows; a
  search query containing `f` is enterable in a spec; the filter panel
  opens, hides, and is reachable from search via `F` in the existing
  suites.
- **Out of scope:** the fullscreen toggle and the focus model.
- **Open questions:** None

### OVF-2. Give session overlays a vim-style normal/insert focus model

- **Outcome:** solve, review, and PR review overlays open in normal mode
  with the `[N]`/`[I]` indicator; `i` enters insert, Enter submits and
  drops to normal, `q`/Esc close from normal, digits pick pending
  choices; `j`/`k`, `g`/`G`, and Ctrl-D/Ctrl-U scroll the transcript and
  Ctrl-J/Ctrl-K retire.
- **Scope:** the mode value and its lifecycle in
  `SessionCore`/`SessionEvents`, mode-aware `sessionInputEvent`, the mode
  indicator, `sessionInputHelp` and the session footer literals, the §7
  session/Esc/`q` row amendments, and pure-function mode-transition specs
  plus a mode-indicator golden frame.
- **Phase:** 2
- **Depends on:** none
- **Ordering:** independent
- **Relevant decisions:** D-6, D-7, D-8, D-9, D-11, D-12, D-13, D-15,
  D-16
- **Acceptance signals:** pure `sessionInputEvent` specs cover both modes
  and the transitions; `Spec.UI.Keys` passes with the amended session
  rows; a live tmux pass types guidance only after `i`.
- **Out of scope:** the `f` binding itself (OVF-3), the footer projection
  (OVF-4 — this slice only keeps the existing in-box hint literals
  truthful for the new modes), and any board-side modal behavior.
- **Open questions:** None — Q-8 stays a deferred idea and blocks
  nothing.

### OVF-4. Make the base footer the context-aware hotkey row

- **Outcome:** the bottom row of the terminal always shows the hotkeys of
  the current context — board, filter, search, and every open overlay,
  mode-aware in session overlays — and the seven in-box hint literals are
  gone.
- **Scope:** extending the footer projection (`Board.hs:968-1048`) with
  overlay contexts sourced from contract-carrying `HelpEntry` rows rather
  than new literals, removing the overlays' inner footer lines, the §6
  footer prose amendment, and updated or new golden frames for the footer
  under each overlay kind.
- **Phase:** 3
- **Depends on:** OVF-2
- **Ordering:** critical path
- **Relevant decisions:** D-14, D-9
- **Acceptance signals:** a spec in the `Spec.UI.Keys` footer-projection
  family asserting the overlay footer is projected from declared entries;
  golden frames show the footer changing across board, an open details
  overlay, and a session overlay in both modes; no overlay draws an
  in-box hint literal.
- **Out of scope:** the fullscreen geometry (OVF-3) and any new bindings.
- **Open questions:** None

### OVF-3. Add the `f` fullscreen toggle for open overlays

- **Outcome:** `f` toggles every overlay except the solve chooser between
  its windowed box and the most-of-the-screen layout of D-10; interiors
  use the space; the state resets on close; contracts and the multi-repo
  notes are amended.
- **Scope:** `appOverlayFullscreen` and the single overlay-setter seam,
  the `drawOverlay` fullscreen branch and interior height threading, the
  dispatch arms (non-session overlays plus the normal-mode binding from
  OVF-2), the contract-carrying `HelpEntry`, design.md §6/§7/§11
  amendments including the mouse policy, fullscreen golden frames, the
  incidents width-suite extension, and the multi_repo_boards_design.md
  notes (tab-row interplay per D-2, the stale D-13 remark per D-3).
- **Phase:** 4
- **Depends on:** OVF-1, OVF-2, OVF-4
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-2, D-4, D-5, D-10, D-17
- **Acceptance signals:** golden fullscreen frames for a details and a
  session overlay showing the visible footer row and side borders;
  windowed frames unchanged; incidents elision holds at fullscreen width;
  a reset-on-close spec through an incidents-Enter transition that
  bypasses `closeOverlay`; `Spec.UI.Keys` passes with the new row.
- **Out of scope:** the tab row's own implementation (MRB-3).
- **Open questions:** None

## Source notes

- "i like the starting out small so i can see the rest of the board in the
  background. if i want to get in more detail i can hit 'f' nad go to
  fullscreen where i can see the text laid out across most of the app
  screen area. i want to still see the borders of the app, i still want
  any tabs along the top" — founding request, 2026-08-20.
- "the filter is going to need to be capital f 'F'" — 2026-08-20.
- "we shouldnt capture text until we hit 'i' to insert. that way f would
  work, we already adopt vi rules with the navigation, why not go all the
  way vim conventions? that is what i am used to anyways and its a
  personal project" — 2026-08-20.
- "if we are going full vim, then q is going to quit the window only, it
  wont quit the app. escape will be possibly a three stage escape … then
  if you want to close the app escape again will close the app" —
  2026-08-20.
- "a green '[I]' means insert, and a '[N]' means the other mode … i have
  been thinking of this normal mode 'n', not visual, i just have been
  using the wrong language" — 2026-08-20.
- "fullscreen doesnt literally mean fullscreen, it means 'make much
  bigger so that it fills most of the screen'. we can cover the left
  column, the left and right should just be a small border, but on top i
  need to see the tabs if there are any, and on the bottom i need the
  hotkeys" — 2026-08-20.
