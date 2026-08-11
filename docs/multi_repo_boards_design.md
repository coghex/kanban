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

- [ ] EPIC. Run one Kanban session over several repositories
- [ ] MRB-1. Add a configured repository roster with per-repo paths
- [ ] MRB-2. Hold per-repository board state behind an active-board pointer
- [ ] MRB-3. Add the repository tab bar and amend the design contract
- [ ] MRB-4. Show workflow state in the repository tabs
- [ ] MRB-5. Route workflow actions to the active repository

## Epic contract

- **Goal:** one `kanban` invocation shows any configured repository's board
  within a keystroke, cross-repo workflow state (approved PRs, active work)
  is visible without switching, and workflow actions always target the
  board being looked at.
- **Done when:** a session launched in one checkout can switch to every
  configured repository; the overview shows per-repo state sourced from the
  per-repo caches; solve/review/drainer actions operate on the active
  repository exactly as they do single-repo today; and a user with no
  roster configured sees today's behavior unchanged.
- **Users and operators:** Vincent across four repositories; any future
  user with one repo (must see zero change); the drainer and agent pipeline
  (per-repo contracts unchanged — Kanban still never merges).
- **Arc label:** proposed `multi-repo`.

## Current state and evidence

- **One repository per invocation is contractual.** design.md §3 non-goals:
  "Multi-repository aggregation in one running board. Each invocation
  represents one repository selected by its path"
  (`docs/design.md:149-150`); §20 defers "Multi-repository aggregation"
  (`docs/design.md:2006`). §2 goals: start `kanban` in a repository or
  `kanban --path DIR`; nested paths resolve to the Git root
  (`docs/design.md:114-116`).
- **App state holds exactly one repository.**
  `appRepository :: Repository` (`src/Kanban/UI/Types.hs:423`);
  `resolveRepository remoteName requestedPath explicitRepository`
  (`src/Kanban/Repository.hs:22-23`) resolves it from the path and optional
  `--repo` override.
- **The cache is already per-repo.** `repositoryCachePath` stores each
  snapshot at `~/.cache/kanban/repos/<safe-repo-identity>.json`
  (`src/Kanban/Cache.hs:136-139`); usage cache is separate and global
  (`src/Kanban/Cache.hs:141-143`). Multi-repo needs no cache migration.
- **Config already speaks per-repository.**
  `[repositories."owner/name".workflow/limits/timeouts]` override tables
  with only-replace-set-fields merge semantics
  (`src/Kanban/Config.hs:124-137`, `config.toml.example:79-99`). There is
  no repository *roster* — the tables configure whichever repo the session
  opened.
- **Usage is global, not per-repo** (`docs/design.md:1156-1158`) — the
  sidebar carries over to a multi-board session unchanged.
- **Refresh is startup-plus-explicit-key only**; automatic polling is a §3
  non-goal (`docs/design.md:137`, `:1156-1159`). Any multi-repo refresh
  behavior must stay attributable to startup or a user action.
- **Actions are checkout-anchored.** Solve worktrees derive from the
  repository (`${WORKTREES_ROOT:-~/worktrees}/<owner>/<repo>/…`), and the
  drainer is a per-repo LaunchAgent addressed by slug
  (`com.coghex.drain-prs.<owner>.<name>`), path-configured per repository
  (`docs/agent-workflow-contract.md` §5). A board without a local checkout
  path can read GitHub but cannot host actions.
- **No overlapping tracker arc.** Kanban's #25 is a closed drainer bug;
  repo-scoped searches show no multi-repo issue or epic (cross-repo search
  bleed produced the look-alike hits).

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

- A configured repository roster with per-repo checkout paths.
- Per-repo board state, the tab bar, and tab-carried workflow state.
- Action routing to the active repository, including drainer control.
- The design.md §3/§20 amendment and §16 config documentation.

### Out of scope

- Forge adapters for non-GitHub repositories (stays deferred, §20).
- A merged single board interleaving all repositories' cards (see Q-1's
  rejected option if so decided).
- Automatic background refresh of inactive boards (§3 non-goal stands).
- Cross-repo issue relationships or dependencies.
- Changes to the drainer, worktree, or review contracts themselves.

## Design

Proposed shape, pending the open questions:

- **Roster (MRB-1).** The existing `[repositories."owner/name"]` tables
  gain a `path` key naming the local checkout. Repos with a `path` form the
  roster; the launch path's repo is always included (and need not be
  configured). Roster resolution happens at startup through
  `resolveRepository` per entry; a bad entry degrades to a startup notice,
  never a refusal to launch. Path-less entries are view-only boards (D-2).
- **State (MRB-2).** `AppState` moves from `appRepository` +
  board-singletons to a per-repository board-state map plus an
  active-board pointer. Mechanically large but behavior-preserving;
  golden frames should not change in the single-repo configuration.
- **Tab bar (MRB-3, D-1).** With a roster of two or more, a tab row
  renders along the top — one tab per repository, active tab highlighted.
  Keybindings cycle and jump (§7 binding table is test-parsed by
  `test/Spec/UI/Keys.hs`); switching is instant from cache with the D-3
  lazy refresh. With one repository, the row is absent entirely — the
  single-repo layout is untouched. The tab row owns a fixed height and a
  width budget (four-plus tabs must degrade by truncation, not overflow —
  the incidents-panel width-budget lesson applies). design.md §3 and §20
  are amended in this slice (D-4).
- **Tab state (MRB-4, D-5).** Each tab shows the repository name, its
  approved-PR count, its active-work count, and a staleness marker when
  the cache is old — sourced from each repo's cached snapshot only, so
  displaying it costs no network and staleness is shown honestly. Four
  repos with badges must fit the tab row's width budget by truncation.
- **Action routing (MRB-5).** Every action resolves its repository from
  the active board: refresh (`u` refreshes the active board plus usage,
  as today), solve/review sessions and their worktrees, and the drainer
  control panel addressing the active repo's LaunchAgent slug. A
  view-only board (no checkout path, if Q-2 allows one) disables
  checkout-dependent actions with a visible reason rather than hiding
  them.
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

### D-2. The roster is configured, and path-less entries are view-only

User signoff 2026-08-10. `[repositories."owner/name"].path` entries form
the roster (the launch repo is always included); an entry without a
resolvable path degrades to a view-only board — GitHub reads work,
checkout-dependent actions are disabled with a visible reason. CLI-only
rosters and a required-checkout rule were rejected (nothing durable;
needlessly rigid). Consequence: MRB-5 carries the view-only guards.

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

## Open questions

### Q-1. What is the aggregation model?

Resolved by D-1.

### Q-2. What defines roster membership, and is a checkout required?

Resolved by D-2.

### Q-3. When do inactive boards refresh?

Resolved by D-3.

### Q-4. Is overturning the recorded single-repo position approved?

Resolved by D-4.

### Q-5. What state does each repository tab display?

Resolved by D-5.

## Verification strategy

- Single-repo regression: with no roster configured, golden frames and
  fixture tests must be byte-identical to today's — the arc's loudest
  invariant.
- Multi-repo fixtures: the snapshot-cache fixture path already supports
  crafting arbitrary board states per repo (write per-repo cache files,
  fail `gh`); switcher and overview tests build on it without network.
- Per-repo cache isolation is already tested; roster tests add the
  degraded cases (missing path, unresolvable repo, empty roster).
- Action routing is asserted with the existing fake `gh`/provider
  executables: an action fired on board B must invoke tools with B's
  repository and path, never A's.
- design.md §3/§20/§7/§16 updates ride the slices that change the
  corresponding behavior (implementation-coupled).

## Delivery plan

### MRB-1. Add a configured repository roster with per-repo paths

- **Outcome:** `[repositories."owner/name"].path` entries resolve at
  startup into a validated roster (launch repo always included); config
  docs and §16 updated; no UI change yet.
- **Scope:** config schema and merge, roster resolution and validation,
  degraded-entry notices, tests.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** can land first
- **Relevant decisions:** D-2
- **Acceptance signals:** config fixtures cover valid, missing-path,
  unresolvable, and empty-roster cases; single-repo behavior unchanged.
- **Out of scope:** any rendering or switching.
- **Open questions:** None

### MRB-2. Hold per-repository board state behind an active-board pointer

- **Outcome:** `AppState` holds a board-state map keyed by repository
  identity with an active pointer; all reads go through the active board;
  behavior and golden frames unchanged.
- **Scope:** the state refactor, accessor discipline, cache load/store per
  board.
- **Phase:** 1
- **Depends on:** MRB-1
- **Ordering:** critical path
- **Relevant decisions:** none beyond structure
- **Acceptance signals:** full Haskell suite green with unchanged golden
  frames; no new behavior observable.
- **Out of scope:** switching, overview, routing changes.
- **Open questions:** None

### MRB-3. Add the repository tab bar and amend the design contract

- **Outcome:** with two-plus roster repos, the tab bar renders along the
  top with the active tab highlighted; tab keys cycle and jump; switching
  renders from cache with lazy refresh; with one repo, no tab bar and
  byte-identical layout; design.md §3/§20 amended and §7 bindings updated.
- **Scope:** tab-row rendering with its height and width budget,
  keybindings, lazy refresh-on-switch, the contract amendment.
- **Phase:** 2
- **Depends on:** MRB-2
- **Ordering:** critical path
- **Relevant decisions:** D-1, D-3, D-4
- **Acceptance signals:** golden frames for two- and four-repo tab rows
  and for the absent single-repo row; Keys.hs table matches §7; fixture
  boards switch without network.
- **Out of scope:** tab-carried state (MRB-4); action routing guards.
- **Open questions:** None

### MRB-4. Show workflow state in the repository tabs

- **Outcome:** each tab carries its repo name, approved-PR count,
  active-work count, and staleness marker, sourced from that repo's cached
  snapshot only, degrading by truncation inside the tab row's width
  budget.
- **Scope:** tab-state rendering, staleness display, width-budget math.
- **Phase:** 2
- **Depends on:** MRB-3
- **Ordering:** not on the critical path
- **Relevant decisions:** D-1, D-5
- **Acceptance signals:** golden frames cover fresh, stale, and missing
  caches at two and four repos; zero network reads attributable to tab
  state.
- **Out of scope:** acting on another repo from its tab beyond switching
  to it.
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
- **Relevant decisions:** D-2
- **Acceptance signals:** fake `gh`/provider invocations carry the active
  repo's identity and cwd in every routed action; view-only guards render.
- **Out of scope:** new action types; multi-repo batch actions.
- **Open questions:** None
