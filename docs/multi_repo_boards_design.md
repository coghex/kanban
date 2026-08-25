# Multi-repo boards design

Vincent runs four active repositories through this pipeline — synarchy,
kanban, glit, and synarchy-lore — and today each needs its own Kanban
invocation from its own checkout. Cross-repo state (which repos have
approved PRs waiting, where work is active) is invisible without launching
boards one at a time. This arc lets one session hold several boards: switch
between them instantly, see cross-repo workflow state at a glance, and keep
every existing single-repo behavior intact when only one repository is
configured. It deliberately revisits two recorded positions in design.md —
the §3 non-goal ("Multi-repository aggregation in one running board") and
the §20 deferral — which is itself a decision requiring signoff (Q-4).

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Run one Kanban session over several repositories — [#354]
- [x] MRB-1. Add a configured repository roster with per-repo paths — [#524]
- [ ] MRB-2. Hold per-repository board state behind an active-board pointer — [deferred]: D-11 must classify every AppState field and decide board-addressed events
- [ ] MRB-3. Add the repository tab bar and amend the design contract
- [ ] MRB-4. Show workflow state in the repository tabs
- [ ] MRB-5. Route workflow actions to the active repository

## Epic contract

- **Goal:** one `kanban` invocation shows any configured repository's board
  within a keystroke, cross-repo workflow state (approved PRs, active work)
  is visible without switching, and workflow actions always target the
  board being looked at.
- **Done when:** a session launched in one checkout can switch to every
  configured repository; each tab carries per-repo state sourced from the
  per-repo caches (D-1, D-5); solve/review/drainer actions operate on the
  active repository exactly as they do single-repo today; and a user with
  no roster configured sees today's behavior unchanged.
- **Users and operators:** Vincent across four repositories; any future
  user with one repo (must see zero change); the drainer and agent pipeline
  (per-repo contracts unchanged — Kanban still never merges).
- **Arc label:** `multi-repo`, created 2026-08-16 alongside epic #354.

## Current state and evidence

Line citations re-verified against master on 2026-08-16; several had drifted
since this document was first written.

- **One repository per invocation is contractual.** design.md §3 non-goals:
  "Multi-repository aggregation in one running board. Each invocation
  represents one repository selected by its path"
  (`docs/design.md:196-197`); §20 defers "Multi-repository aggregation"
  (`docs/design.md:2929`). §2 goals: start `kanban` in a repository or
  `kanban --path DIR`; nested paths resolve to the Git root
  (`docs/design.md:161-162`).
- **App state holds exactly one repository.**
  `appRepository :: Repository` (`src/Kanban/UI/Types.hs:497`);
  `resolveRepository remoteName requestedPath explicitRepository`
  (`src/Kanban/Repository.hs:22-45`) resolves it from the path and optional
  `--repo` override. It canonicalizes the path, runs
  `git rev-parse --show-toplevel`, and then derives `owner/name` from the
  *remote* — three independently failing steps, which is what D-6 and D-7
  are about.
- **The cache is already per-repo.** `repositoryCachePath` stores each
  snapshot at `~/.cache/kanban/repos/<safe-repo-identity>.json`
  (`src/Kanban/Cache.hs:195-198`); usage cache is separate and global
  (`src/Kanban/Cache.hs:200-202`). Multi-repo needs no cache migration.
- **Config already speaks per-repository.**
  `[repositories."owner/name".workflow/limits/timeouts]` override tables
  with only-replace-set-fields merge semantics
  (`src/Kanban/Config.hs:228-236`, `config.toml.example:93-118`); keys are
  canonical lowercase `owner/name` only (`src/Kanban/Config.hs:560-587`),
  and `cache`, `remote_name`, and `usage` are rejected inside them
  (`:589-608`). There is no repository *roster* — the tables configure
  whichever repo the session opened.
- **The config schema is deliberately one schema in two languages.**
  `tools/kanban_config.py` mirrors the Haskell parser field for field, and
  `_collect_unknown` (`tools/kanban_config.py:636`) warns on any key inside
  a repository table that it does not recognize. The module states the
  invariant twice — "the shared schema stays one schema — a documented key
  must not warn as unknown" (`:88-91`, `:129-132`) — with
  `codex_estimated_percent_per_solve_round` as the standing precedent for a
  field carried but never read. A roster key added on one side only makes
  every Python workflow tool warn about it.
- **Usage is global, not per-repo** (`docs/design.md:1527,1640`) — the
  sidebar carries over to a multi-board session unchanged.
- **Refresh is startup-plus-explicit-key only**; automatic network polling
  is a §3 non-goal (`docs/design.md:184`, `:1527`). Any multi-repo refresh
  behavior must stay attributable to startup or a user action.
- **A startup degradation already has a notice seam.** `loadSettings`
  returns a `settingsNotice` that `runDashboard` turns into the in-app
  `appNotice` (`src/Kanban/UI.hs:83`, `src/Kanban/UI/Types.hs:537`), while
  config warnings go to stderr before Brick starts and are painted over
  immediately (`app/Main.hs:118`). D-9 picks between them.
- **Actions are checkout-anchored.** Solve worktrees derive from the
  repository (`${WORKTREES_ROOT:-~/worktrees}/<owner>/<repo>/…`), and the
  drainer is a per-repo LaunchAgent addressed by slug
  (`com.coghex.drain-prs.<owner>.<name>`), path-configured per repository
  (`docs/agent-workflow-contract.md` section 4, rows at `:824,844`). A
  board without a local checkout path can read GitHub but cannot host
  actions.
- **No overlapping tracker arc.** Kanban's #25 is a closed drainer bug;
  repo-scoped searches show no multi-repo issue or epic (cross-repo search
  bleed produced the look-alike hits). The arc is now tracked as #354.

## Desired experience

Vincent launches `kanban` in any of the four checkouts. With more than one
repository configured, a tab bar appears along the top — one tab per
roster repo, the active one highlighted. Switching tabs renders that
repository's board from its cached snapshot instantly, refreshing lazily
if stale. The tabs themselves carry enough state (per Q-5) that "does
anything need me elsewhere?" is answered at a glance. Every action —
refresh, solve, review, drainer control — applies to the board on screen,
never to a repository that is not visible. With a single repository, no
tab bar renders and nothing about today's session changes.

## Scope

### In scope

- A configured repository roster with per-repo checkout paths, spelled
  once in a schema both the Haskell and the Python config parsers share.
- Per-repo board state, the tab bar, and tab-carried workflow state, with
  a `[limits]` staleness threshold shared by the marker and refresh-on-switch.
- Action routing to the active repository, including drainer control.
- The design.md §3/§20 amendment and §16 config documentation.

### Out of scope

- Forge adapters for non-GitHub repositories (stays deferred, §20).
- A merged single board interleaving all repositories' cards, rejected by
  D-1.
- Automatic background refresh of inactive boards (§3 non-goal stands).
- Cross-repo issue relationships or dependencies.
- Changes to the drainer, worktree, or review contracts themselves.

## Design

Proposed shape, pending the open questions:

- **Roster (MRB-1).** The existing `[repositories."owner/name"]` tables
  gain an absolute `path` key naming the local checkout, added to both the
  Haskell and the Python schema so neither warns about the other's key.
  Exactly the entries that set `path` form the roster, plus the launch
  checkout's repository, which is always included and need not be
  configured (D-2). A table without `path` keeps its present meaning — an
  override table for whichever repository the session opens — so no
  existing configuration gains a board on upgrade. Roster resolution
  happens at startup through `resolveRepository` per entry; an entry whose
  path is absent, unusable, or names a checkout whose remote disagrees with
  the key stays in the roster as a view-only board and is reported through
  the in-app notice (D-2, D-6, D-9), never as a refusal to launch. A
  non-absolute `path` is the one roster mistake that fails at load time
  (D-7), and the launch checkout wins a collision with its own configured
  entry (D-8).
- **State (MRB-2).** `AppState` moves from `appRepository` +
  board-singletons to a per-repository board-state map keyed by the
  ASCII-lowercased identity (D-10) plus an active-board pointer. The record
  holds everything repository-derived — snapshot and cache, selection,
  scroll, search, criteria, drainer controller, transcript root, refresh
  coordinator, sessions, incidents — while usage, settings, theme, and the
  notice stay session-global (D-11). Work on a board keeps running when it
  is not the active one (D-12). Mechanically large but behavior-preserving;
  golden frames should not change in the single-repo configuration.
- **Tab bar (MRB-3, D-1).** With a roster of two or more, one unboxed row
  renders at the very top, spanning sidebar and board alike, one tab per
  repository with the active one highlighted (D-14). `[` and `]` cycle and
  `1`–`9` jump (D-13); a left-click switches (D-18); the §7 binding table
  is test-parsed by `test/Spec/UI/Keys.hs`, and §6's layout diagram and §7's
  mouse list are redrawn here. Switching is instant from cache with the D-3
  lazy refresh, governed by the D-17 threshold this slice introduces. With
  one repository the row is absent entirely — the single-repo layout is
  untouched. Labels truncate as width runs out and the row degrades at its
  floor to the active tab plus a position count, never overflowing (D-15 —
  the incidents-panel width-budget lesson applies). design.md §3 and §20
  are amended in this slice (D-4).
- **Tab state (MRB-4, D-5).** Each tab shows the repository name, its
  approved-PR count, its active-work count, and a staleness marker when the
  cache is older than the D-17 threshold. Both counts are unfiltered
  (D-16) and sourced from that repo's cached snapshot only, so displaying
  them costs no network and staleness is shown honestly. Four repos with
  badges must fit the tab row's width budget by truncation.
- **Action routing (MRB-5).** Every action resolves its repository from
  the active board: refresh (`u` refreshes the active board plus usage,
  as today), solve/review sessions and their worktrees, and the drainer
  control panel addressing the active repo's LaunchAgent slug. A
  view-only board (D-2) disables checkout-dependent actions with a visible
  reason rather than hiding them.
- **Refresh semantics (D-3).** Lazy: startup refreshes the launched
  board, switching refreshes a stale board, `u` refreshes the active one —
  every call attributable to startup or an explicit user action.

## Decisions

### D-1. Multi-repo renders as a tab bar along the top

User signoff 2026-08-10 (user's own formulation: "if there is more than
one repo being used it should show tabs along the top"). One tab per
roster repository, active tab highlighted; with a single repository the
row does not render at all, which preserves today's layout byte-for-byte.
The rejected alternatives — a separate overview strip, a switcher without
any always-visible cross-repo surface, and a merged interleaved board —
lose to tabs on either visibility or layout-churn grounds. Consequence:
MRB-4 becomes tab-state display rather than a separate overview panel;
what the tabs show is Q-5.

### D-2. The roster is configured, and only `path` entries join it

User signoff 2026-08-10, amended 2026-08-16. Exactly the
`[repositories."owner/name"]` tables that set a `path` form the roster, and
the launch checkout's repository is always included whether or not it is
configured. A table that sets no `path` keeps its present meaning — an
override table for whichever repository the session opens — and contributes
no board, so an existing configuration gains no boards on upgrade; the
shipped `config.toml.example` is such a file. An entry whose declared
`path` does not resolve stays in the roster as a view-only board keyed by
its config key: GitHub reads work, and checkout-dependent actions are
disabled with a visible reason. CLI-only rosters and a required-checkout
rule were rejected (nothing durable; needlessly rigid).

The amendment resolves a contradiction found while processing MRB-1: the
original text said both that `path` entries form the roster and that
path-less entries are view-only boards, which cannot both hold. Reading
every override table as a board was rejected because it would turn tables
that exist only to set labels into tabs the user never asked for.
Consequence: MRB-5 carries the view-only guards, and MRB-1's degraded cases
are the ones enumerated in D-6 through D-9.

### D-3. Inactive boards refresh lazily

User signoff 2026-08-10. Startup refreshes the launched board; switching
to a stale board refreshes it then; `u` refreshes the active board.
Eager refresh-all (N× gh cost) and manual-only (empty first render)
were rejected. Every refresh stays attributable to startup or a user
action, preserving the §3 no-polling non-goal.

### D-5. Tabs carry name plus count badges

User signoff 2026-08-10. Each tab shows the repo name, approved-PR count,
active-work count, and a staleness marker for an old cache. The attention
dot (less informative) and plain names (no cross-repo visibility) were
rejected. Consequence: MRB-4's width-budget math covers four repos with
badges; truncation, never overflow.

### D-4. The single-repo contract position is amended

User signoff 2026-08-10. design.md §3's non-goal is narrowed — merged
interleaved boards, automatic background refresh, and forge adapters stay
excluded — and §20's "Multi-repository aggregation" deferral is removed.
The amendment lands in MRB-3's PR with the first visible multi-repo
behavior.

### D-6. A roster entry's identity is its config key

User signoff 2026-08-16. When a declared `path` resolves to a checkout
whose remote yields a different `owner/name` than the key, the key wins and
the entry degrades to a view-only board with a notice naming the mismatch —
the same outcome as an absent or unusable path. No board ever queries
GitHub, keys a cache, or displays under an identity the configuration does
not name. Letting the remote win was rejected: a mistyped key would
silently produce a board for an unnamed repository, whose override table
would then fail to apply. Refusing the entry outright was rejected as an
exception to D-2's stays-as-view-only rule.

### D-7. A roster `path` must be absolute

User signoff 2026-08-16. A non-absolute `path` is a configuration error
reported at load time, naming the full key path like any other invalid
value — the single roster mistake that is loud rather than degraded,
because it has no defensible meaning to degrade into. `config.toml` is read
from a fixed XDG location but consumed by workers that run from other
directories; `resolveConfigPathOption` (`src/Kanban/Config.hs:380-386`)
documents exactly this hazard for `--config`. Resolving against the config
file's own directory was rejected (`~/.config/kanban` is not a plausible
base for a checkout) and resolving against the process working directory
was rejected (the same file would then name different checkouts depending
on where `kanban` was launched).

### D-8. The launch checkout wins a roster collision

User signoff 2026-08-16. When the launch checkout's repository is also
configured with a `path` naming a different checkout, the roster holds one
entry for that repository and it uses the launch checkout, silently. Two
boards for one `owner/name` are never shown, and actions target the
checkout the user is actually sitting in — which matters here because
sessions are routinely launched from linked worktrees. Preferring the
configured path was rejected: a session started inside a worktree would run
its solve and drainer actions against a different checkout than the one on
screen.

### D-9. Degraded roster entries report through the in-app notice

User signoff 2026-08-16. A degraded entry is reported through the same
startup-notice seam `loadSettings`' `settingsNotice` already uses
(`src/Kanban/UI.hs:83` → `appNotice`, `src/Kanban/UI/Types.hs:537`), not
through stderr: a `kanban: warning:` line is painted over the instant Brick
starts, which is a real wart of today's config warnings rather than a
pattern to copy. Deferring the report to MRB-3 was rejected — a mistyped
roster entry would be undiagnosable until the tab bar landed. Consequence:
MRB-1 threads roster state into `runDashboard`, so its outcome is "no new
UI surface" rather than "no UI change"; it adds no widget and no tab row,
but it can set the existing notice.

### D-10. The board map is keyed by ASCII-lowercased identity

User signoff 2026-08-16. Board state is keyed by the `owner/name` identity
folded with the same ASCII lowercasing `resolveConfig` already applies when
selecting an override table (`src/Kanban/Config.hs:291-300`), so a
`Coghex/Kanban` clone and a `coghex/kanban` roster entry are one board —
which is what D-8's collision rule assumes. The identity keeps its original
spelling everywhere it is used: the tab label, the GitHub queries, and the
cache path. A case-sensitive key was rejected because `repositoryCachePath`
keys on the identity verbatim (`src/Kanban/Cache.hs:195-198`), so two
spellings of one repository would refresh over each other's snapshot.

### D-11. Everything repository-derived is per-board

User signoff 2026-08-16. The per-board record holds the snapshot and its
cache, selection, scroll, search, filter criteria, the drainer controller
(`src/Kanban/UI.hs:82`), the transcript root (`:84`), the refresh
coordinator, live sessions, and incidents. Usage, settings, theme, and the
notice line stay session-global. This follows what the code already scopes
per repository — design.md:1930 defines "one coordinator per repository
within one dashboard process" — so the map is where those values belong
rather than a new place to put them. Rebuilding them on each switch was
rejected: it would reintroduce exactly the shared-record hazards they were
made per-repository to avoid. Keeping only the snapshot was rejected
because losing selection on every switch makes tabs feel lossy rather than
instant.

Consequence: the usage sidebar is no longer wholly global, since the
`drain_prs.py` button inside it follows the active board (D-14 places the
tab row accordingly).

### D-12. Background boards keep running, unattended

User signoff 2026-08-16. Switching tabs only changes what is drawn. A solve
or autosolve running on an inactive board keeps running; an unwatched
session is already an existing concept, since sessions are hideable and
resumable. Refusing or confirming a switch while an agent is live was
rejected — it would disable the tab bar precisely when several
repositories are busy, which is the situation the arc exists for.

Consequence: a background board's finished work becomes visible through its
cached snapshot, which under D-3 is refreshed when you switch to it. Tab
badges therefore stay cache-sourced and D-5's "costs no network" holds;
event-driven tab flagging was considered and rejected for that reason.

### D-13. `[` and `]` cycle, digits jump

User signoff 2026-08-16. `[` and `]` select the previous and next
repository; `1` through `9` jump directly to a tab. Both brackets are
unbound today, and the digits are only consumed elsewhere while the card
search is open, which is already a modal context. `Tab`/`Shift-Tab` was
rejected because `Tab` already means "show the next in-memory session of
that kind" inside solve, PR, and review overlays, and one key with two
meanings must still be expressed as a single contract row in
`test/Spec/UI/Keys.hs`. `Ctrl-N`/`Ctrl-P` was rejected as out of character
for a deliberately plain-key binding set. `f` was avoided: open issue #348
claims it for the filter panel.

Correcting note: that last sentence is stale. #513 moved the filter panel
from `f` to capital `F` across the board binding, the panel's own hide key,
and the search box's transfer key, so #348 no longer claims lowercase `f`.
The key is not free either — `overlay_focus_fullscreen_design.md` D-3 records
the rebind and its later slice claims lowercase `f` for the overlay
fullscreen toggle — so the signed-off `[`/`]` and digit bindings above stand
unchanged, and the avoidance still holds for a different reason.

### D-14. One row, full width, at the very top

User signoff 2026-08-16. The tab row is a single unboxed row spanning the
sidebar and the board alike, above the existing frame. Full width is the
honest placement because D-11 makes the sidebar's drainer button follow the
active board, so the sidebar is not outside the tabbed region. Placing tabs
only over the board was additionally rejected for surrendering ~28 cells of
the width budget four badged tabs must fit into; a three-row boxed strip
was rejected as too expensive vertically beside the existing column
headings and footer hint. design.md §6's layout diagram is redrawn in
MRB-3.

### D-15. At its floor the row degrades to the active tab plus a count

User signoff 2026-08-16. Labels truncate progressively as width runs out;
at the floor the row shows only the active repository and its position,
such as `kanban 2/4`. The row never overflows, the user always knows where
they are and how many boards exist, and cycling still works. Shedding
badges while keeping unreadable name stubs was rejected, as was hiding the
row entirely below a threshold — a narrow terminal would silently lose the
arc's headline feature.

### D-16. Tab counts are unfiltered

User signoff 2026-08-16. A tab's approved-PR count is the open, non-draft
pull requests satisfying that repository's approval predicate, and its
active-work count is the open issues carrying an assignee — both computed
from the cached snapshot with no filter criteria applied. A badge therefore
means the same thing on every tab, and a filter left on cannot silently
zero it. Mirroring each board's own criteria was rejected for that reason:
criteria are per-board presentation state under D-11, so a background board
sits at defaults until visited and the badge would change meaning the
moment its filters were touched. A single incidents-derived attention count
was rejected for discarding the approved-versus-active distinction D-5
signed off.

### D-17. One configurable staleness threshold

User signoff 2026-08-16. A single age governs both the tab's staleness
marker and whether switching to a board refreshes it under D-3, so the
marker means exactly "switching here will refetch". It is a `[limits]` key
with a default of 15 minutes, mirrored into `tools/kanban_config.py` like
every other key. Separate display and refresh ages were rejected: the
marker would stop predicting what a switch does. A hard-coded threshold was
rejected as untunable on a slow network or a rate-limited account.

Consequence: the key lands in MRB-3, which is the first slice to consume it
for refresh-on-switch, not in MRB-4, which only reuses it for the marker.

### D-18. Tabs are clickable

User signoff 2026-08-16. Left-clicking a tab switches to it, adding one row
to design.md §7's mouse list. A tab is a control that looks clickable, and
the `drain_prs.py` button already sets the precedent. Right-click, drag,
and hover stay unbound, so the mouse surface stays as narrow as §7 claims.

## Open questions

### Q-1. What is the aggregation model?

Resolved by D-1.

### Q-2. What defines roster membership, and is a checkout required?

Resolved by D-2, amended 2026-08-16 to settle which entries join the
roster.

### Q-3. When do inactive boards refresh?

Resolved by D-3.

### Q-4. Is overturning the recorded single-repo position approved?

Resolved by D-4.

### Q-5. What state does each repository tab display?

Resolved by D-5.

### Q-6. Which identity does a roster entry carry when its checkout disagrees?

Raised while processing MRB-1 on 2026-08-16. Resolved by D-6.

### Q-7. What does a relative roster `path` mean?

Raised while processing MRB-1 on 2026-08-16. Resolved by D-7.

### Q-8. What happens when the launch checkout is also a configured entry?

Raised while processing MRB-1 on 2026-08-16. Resolved by D-8.

### Q-9. Where does a degraded roster entry get reported?

Raised while processing MRB-1 on 2026-08-16. Resolved by D-9.

### Q-10. What keys the per-repository board map?

Raised in the 2026-08-16 pre-processing audit of MRB-2. Resolved by D-10.

### Q-11. What is per-board and what stays session-global?

Raised in the 2026-08-16 pre-processing audit of MRB-2. Resolved by D-11.

### Q-12. What happens to live work on a board you switch away from?

Raised in the 2026-08-16 pre-processing audit of MRB-2. Resolved by D-12.

### Q-13. Which keys cycle and jump between tabs?

Raised in the 2026-08-16 pre-processing audit of MRB-3. Resolved by D-13.

### Q-14. Where does the tab row sit, and how tall is it?

Raised in the 2026-08-16 pre-processing audit of MRB-3. Resolved by D-14.

### Q-15. What does the tab row do when its width budget runs out?

Raised in the 2026-08-16 pre-processing audit of MRB-3. Resolved by D-15.

### Q-16. What do the tab counts count?

Raised in the 2026-08-16 pre-processing audit of MRB-4. Resolved by D-16.

### Q-17. What marks a cached board stale?

Raised in the 2026-08-16 pre-processing audit of MRB-4. Resolved by D-17.

### Q-18. Are repository tabs clickable?

Raised in the 2026-08-16 pre-processing audit of MRB-3. Resolved by D-18.

## Verification strategy

- Single-repo regression: with no roster configured, golden frames and
  fixture tests must be byte-identical to today's — the arc's loudest
  invariant.
- Multi-repo fixtures: the snapshot-cache fixture path already supports
  crafting arbitrary board states per repo (write per-repo cache files,
  fail `gh`); switcher and overview tests build on it without network.
- Per-repo cache isolation is already tested; roster tests add the
  degraded cases enumerated in MRB-1's acceptance signals — no `path`, an
  unresolvable path, a key the checkout's remote disagrees with, a relative
  path, an empty roster, and the launch-checkout collision.
- The two config parsers are checked as one schema: a fixture setting
  `path` must load without an unknown-key warning from either
  `Kanban.Config` or `tools/kanban_config.py`.
- Action routing is asserted with the existing fake `gh`/provider
  executables: an action fired on board B must invoke tools with B's
  repository and path, never A's.
- design.md §3/§6/§7/§16/§20 updates ride the slices that change the
  corresponding behavior (implementation-coupled). §7's binding table is
  parsed by `test/Spec/UI/Keys.hs` and reconciled in both directions, so
  MRB-3's new key rows land in the table and the registry together.
- The tab row's width budget is proven at its floor, not only at its
  comfortable widths: a golden frame asserts the D-15 degradation rather
  than assuming truncation suffices.

## Delivery plan

### MRB-1. Add a configured repository roster with per-repo paths

- **Outcome:** `[repositories."owner/name"].path` entries resolve at
  startup into a validated roster (launch repo always included); config
  docs and §16 updated; no new UI surface — no tab row and no new widget,
  though a degraded entry may set the existing notice (D-9).
- **Scope:** the `path` key in both the Haskell and the Python config
  schema, roster resolution and validation, degraded-entry notices, tests.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** can land first
- **Relevant decisions:** D-2, D-6, D-7, D-8, D-9
- **Acceptance signals:** config fixtures cover the seven cases — a valid
  entry, a table with no `path` (no board, no notice), an unresolvable
  path, a checkout whose remote disagrees with the key, a relative path
  (load-time error), an empty roster, and the launch checkout colliding
  with its own configured entry. `path` is known to both parsers, so
  neither warns about it. Single-repo behavior is unchanged.
- **Out of scope:** any rendering or switching; the tab row; using the
  roster for anything beyond validating it and reporting degradations.
- **Open questions:** None

### MRB-2. Hold per-repository board state behind an active-board pointer

> **Deferred 2026-08-25.** D-11's ten-item enumeration no longer covers
> `AppState`, which carries 61 fields, and this slice's scope is that
> enumeration. Three gaps block a scoped issue.
>
> No `AppEvent` constructor carries a board identity — all 25 address "the"
> board (`src/Kanban/UI/Types.hs:576-600`) — while one `monitorDrainer` and
> one `monitorApprovalService` thread write into the single `appEventChannel`
> (`src/Kanban/UI.hs:348-367`). D-11 puts the drainer controller, refresh
> coordinator, and live sessions per board, and D-12 keeps an inactive board's
> work running, so every event must become board-addressed. Neither decision
> says so, and no reading of D-11 supplies it.
>
> The seven approval-service fields (`appApprovalController` through
> `appApprovalResult`) landed in `81504ae` on 2026-08-17, a day after D-11's
> signoff, and are repository-derived by construction
> (`discoverApprovalController :: Repository -> IO …`,
> `src/Kanban/ApprovalService.hs:1010`). `appConfig :: ResolvedConfig` comes
> from `resolveConfig ownerName rawConfig` (`app/Main.hs:135`) and is unnamed:
> left session-global, every board would run under the launch repository's
> override table. Seven further fields are undetermined either way —
> `appFilterPanel`, `appEnsureSelectionVisible`, `appSidebarVisible`,
> `appProcessSelection`, `appIncidentSelection`, `appOverlay`,
> `appReviewBackend`.
>
> **Precondition:** `/design-epic` amends D-11 to classify every `AppState`
> field and records a decision on board-addressed events. The same pass should
> refresh D-10's and D-11's citations: `Config.hs:291-300` → `:324-338`,
> `Cache.hs:195-198` → `:214-218`, `UI.hs:82`/`:84` → `:112`/`:117`,
> `design.md:1930` → `:2103`.

- **Outcome:** `AppState` holds a board-state map keyed by the
  ASCII-lowercased repository identity with an active pointer; all reads go
  through the active board; behavior and golden frames unchanged.
- **Scope:** the state refactor, accessor discipline, cache load/store per
  board, and moving the repository-derived values named in D-11 into the
  per-board record.
- **Phase:** 1
- **Depends on:** MRB-1
- **Ordering:** critical path
- **Relevant decisions:** D-10, D-11, D-12
- **Acceptance signals:** full Haskell suite green with unchanged golden
  frames; no new behavior observable. A mixed-case clone and its lowercase
  roster entry resolve to one board with one cache file. Nothing
  session-global — usage, settings, theme, notice — moves into the map.
- **Out of scope:** switching, the tab row, routing changes.
- **Open questions:** None

### MRB-3. Add the repository tab bar and amend the design contract

- **Outcome:** with two-plus roster repos, one full-width row renders at the
  very top with the active tab highlighted; `[`/`]` cycle, `1`–`9` jump, and
  a click switches; switching renders from cache with lazy refresh above the
  staleness threshold; with one repo, no tab bar and byte-identical layout;
  design.md §3/§20 amended, §6's diagram redrawn, and §7's bindings and
  mouse list updated.
- **Scope:** tab-row rendering with its one-row height and width budget,
  keybindings and click regions, the `[limits]` staleness threshold and
  lazy refresh-on-switch, the contract amendment.
- **Phase:** 2
- **Depends on:** MRB-2
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-3, D-4, D-13, D-14, D-15, D-17, D-18
- **Acceptance signals:** golden frames for two- and four-repo tab rows,
  for the absent single-repo row, and for the D-15 floor; Keys.hs table
  matches §7 in both directions; a click on a tab switches boards; fixture
  boards switch without network, and a board past the threshold refreshes
  on switch while one inside it does not. The staleness key is known to
  both config parsers.
- **Out of scope:** tab-carried counts and the staleness marker (MRB-4);
  action routing guards.
- **Open questions:** None

### MRB-4. Show workflow state in the repository tabs

- **Outcome:** each tab carries its repo name, unfiltered approved-PR
  count, unfiltered active-work count, and a staleness marker when its
  cache is past the MRB-3 threshold, sourced from that repo's cached
  snapshot only, degrading by truncation inside the tab row's width budget.
- **Scope:** tab-state rendering, staleness display, width-budget math.
- **Phase:** 2
- **Depends on:** MRB-3
- **Ordering:** not on the critical path
- **Relevant decisions:** D-1, D-5, D-16, D-17
- **Acceptance signals:** golden frames cover fresh, stale, and missing
  caches at two and four repos, and the D-15 floor with badges shed; a
  board whose filter criteria are narrowed still reports the same counts;
  zero network reads attributable to tab state.
- **Out of scope:** acting on another repo from its tab beyond switching
  to it; the staleness threshold itself, which lands in MRB-3.
- **Open questions:** None

### MRB-5. Route workflow actions to the active repository

- **Outcome:** refresh, solve, review, and drainer control resolve the
  active board's repository and path; checkout-dependent actions on a
  view-only board (D-2) are disabled with a visible reason.
- **Scope:** action resolution, drainer-slug addressing, guards, fake-tool
  tests proving no cross-repo leakage.
- **Phase:** 3
- **Depends on:** MRB-3
- **Ordering:** critical path
- **Relevant decisions:** D-2, D-6, D-11, D-12
- **Acceptance signals:** fake `gh`/provider invocations carry the active
  repo's identity and cwd in every routed action; view-only guards render;
  an action started on one board and left running while another is active
  still completes against its own repository (D-12).
- **Out of scope:** new action types; multi-repo batch actions; acting on a
  board other than the active one.
- **Open questions:** None
