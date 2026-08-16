# Card filtering and complete-history design

Kanban's workflow columns answer where work is, but they cannot narrow a busy
board by lifecycle, review outcome, item kind, or tracker structure. This
design adds an `f filter` panel with live checkboxes, process-lifetime criteria,
and a composable visible-card pipeline shared with column search. It also makes
the data model complete: every open issue and pull request comes from a live
uncapped load, while all completed issues and pull requests are cached and
refreshed in the background.

Design state: `ready for issue processing`

`EPIC`, `FILT-4`, and `FILT-3` were processed into tracker items during an
earlier ready period. Processing `FILT-1` exposed unresolved ordering and
tracker-structure choices and a slice-size question, which returned the document
to `exploring`; `Q-10` through `Q-14` were resolved by D-19 through D-23,
`FILT-1` split into a data slice and the new `FILT-5` presentation slice, and
the user signed the design ready again on 2026-08-14. The three linked slices
are unaffected by those decisions.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Add composable board filters and complete issue/PR history — [#298]
- [x] FILT-4. Coordinate GitHub refresh ownership and rate pressure — [#301]
- [x] FILT-3. Make the open board complete, live-only, and atomically refreshable — [#305]
- [x] FILT-1. Load and cache complete issue/PR history in the background — [#316]
- [x] FILT-5. Render completed history read-only behind default-hidden criteria — [#319]
- [x] FILT-2. Add the live filter panel and compose it with column search — [#348]

`FILT-3`, then `FILT-4`, then `FILT-5` were added after the first two stable
slice IDs had been recorded. Their numbers are intentionally out of sequence
while ledger position preserves the actual dependency order.

## Epic contract

- **Goal:** a user can press `f`, toggle understandable card categories, and
  immediately narrow the board—including to completed work only—while any
  active text search independently narrows the filtered result.
- **Done when:** startup and `u update` load every open issue and open pull
  request without using a persistent open-data cache; completed issues and
  closed/merged pull requests load independently in the background from a
  separately versioned cache plus a complete provider reconciliation; one
  repository-scoped, rate-aware coordinator prioritizes open work and safely
  owns every `gh` process; first-launch open failure is recoverable without a
  cached fallback; the panel contains the settled lifecycle, workflow,
  item-kind, and structure
  checkboxes with predictive facet counts and non-blocking history status;
  defaults show every open card and hide completed cards, leaving the rendered
  board identical to the one that preceded completed history; completed cards
  take their settled places without disturbing design.md §12's ordering or
  promoting themselves into its attention tiers, and a completed tracker keeps
  its group while its default-hidden header leaves any open child
  `Standalone`; selecting
  Closed during a completed-history generation replaces all cards with an
  honest centered loading state that can be dismissed immediately by
  unchecking Closed; criteria survive panel dismissal, overlays, refreshes, and
  search changes until the process exits; filter renders above search and
  cards when both are visible; every visible keyboard/mouse target resolves to
  the card shown; and the cache, refresh, keybinding, narrow-layout, and
  workflow-action contracts are updated and covered.
- **Users and operators:** people scanning a large repository board, looking
  for review outcomes or standalone work, or consulting completed issue/PR
  history; maintainers of the GitHub snapshot and Brick view pipeline.
- **Arc label:** proposed `ui` (the repository has no dedicated filter label).

## Current state and evidence

- **`f` is unclaimed.** The centralized `BoardAction` registry currently uses
  `s` for Settings (moving to `o` under SRCH-1), `q` for quit, and no plain
  `f`; footer, help, event dispatch, and design.md §7 project from that table
  (`src/Kanban/UI/Keys.hs:102-226`, `test/Spec/UI/Keys.hs`). The new action
  belongs in that registry rather than a separate event-only shortcut.
- **The implemented snapshot is open-only and capped.** The GraphQL query asks
  for `issues(... states: OPEN)` and `pullRequests(... states: OPEN)` and the
  pagination state has one connection for each. `LimitsConfig` defaults to 250
  open issues and 100 open PRs, and truncation is surfaced in snapshot/app
  state (`src/Kanban/GitHub/Fetch.hs:32-56,193-233,286-356`,
  `src/Kanban/Config.hs:56-73`). The settled requirement to load *all* open
  issues and PRs therefore changes both caps and publication semantics.
- **Neither domain item records its lifecycle.** `Issue` and `PullRequest` have
  no open/closed/merged field (`src/Kanban/Domain.hs:164-179,233-253`). A shared
  State facet and truthful `CLOSED`/`MERGED` badges require explicit issue and
  PR lifecycle types decoded from GitHub, not inference from column placement.
- **Startup currently reads and displays a cached open snapshot.**
  `runDashboard` calls `loadRepositoryCache`, derives the initial board from it,
  and then `startApplication` launches the normal GitHub refresh. A successful
  refresh writes the same `RepoSnapshot` back to schema-version-5 cache
  (`src/Kanban/UI.hs:68-162,196-207`,
  `src/Kanban/UI/Refresh.hs:120-146`, `src/Kanban/Cache.hs:98-130,242-247`). The
  user's live-only open-data decision (D-8) deliberately retires that contract.
- **Refresh already has a useful atomic seam.** While `appBoardFreshness` is
  `Loading`, the old board remains in app state; only a successful complete
  result derives and swaps a new board. Failures keep the last-good board
  (`src/Kanban/UI/Refresh.hs:100-111`,
  `src/Kanban/UI/Reconcile.hs:48-109`). The two new dataset generations should
  retain this atomic property while separating open and completed freshness.
- **The first uncached open-load failure needs an explicit screen contract.**
  The current failure transition can distinguish `Unavailable` when no prior
  fetch exists and `Stale` when one does, but the design only settles the
  initial *loading* screen and later last-good refresh behavior
  (`src/Kanban/UI/Reconcile.hs:202-209`,
  `src/Kanban/UI/Board.hs:578-584`). Once persistent open cache is removed, an
  authentication, timeout, or malformed-response failure on first launch is a
  normal reachable state rather than an edge case (D-16).
- **Two independent fetch workers cannot safely share today's cleanup record.**
  Every `gh` group for a repository is stored in one per-repository JSON file.
  `recordGhGroup` and `dropGhGroup` each perform an unlocked read-modify-write,
  while every current board refresh creates its own in-memory guard
  (`src/Kanban/Cache.hs:151-179`,
  `src/Kanban/GitHub/Guard.hs:217-247`,
  `src/Kanban/UI/Refresh.hs:120-146`). Launching open and completed pagers
  concurrently could lose one group's durable record. A single repository
  refresh coordinator is therefore a safety boundary, not merely an
  optimization (D-17).
- **The current provider traversal has one 30-second deadline.** All sequential
  GitHub pages run inside one configured timeout, but a successful fetch writes
  the cache only after that timed action returns; the timeout does not bound the
  cache write (`src/Kanban/UI/Refresh.hs:115-145`,
  `src/Kanban/Config.hs:95-108`). Uncapping both live and historical
  connections requires per-page/process cleanup and generation cancellation
  rather than putting an unbounded traversal behind one deadline. This
  repository alone has 116 closed issues as of 2026-08-11, already exceeding
  the rejected proposed cap of 100.
- **Uncapped history must cooperate with GitHub's resource budget.** GitHub's
  GraphQL API charges points per query, reports `cost`, `remaining`, and
  `resetAt`, imposes node/resource limits, and warns clients not to retry until
  the reported reset after exhausting the primary limit. The current provider
  classifies rate-limit text only as a generic request failure and has no
  pause/resume state (`src/Kanban/GitHub/Message.hs:22-43`,
  `test/Spec/GitHub/Decoding.hs:486-491,651-656`). A full historical traversal
  on every `u` should not consume the quota needed for the foreground open
  board or hammer a known limit
  ([GitHub GraphQL rate/query limits](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api),
  accessed 2026-08-11; D-17).
- **Completed cards change the existing board contract.** design.md §8 defines
  Issues/Active as open issues, Reviewing/Done as open PRs, and says closed or
  merged PRs disappear because Done is not history (`docs/design.md:495-535`).
  Closed issues and closed/merged PRs now both belong to this feature, so their
  placement, badge, and read-only action behavior must be explicit (D-12,
  D-15).
- **Complete history needs its own durable boundary.** Repository snapshots are
  stored in a versioned envelope and old schemas are discarded rather than
  guessed (`src/Kanban/Cache.hs:98-130`). A separately versioned,
  per-repository completed-history cache can hold only complete generations;
  open cards must never be restored from it. Filter *selections* remain
  process-lifetime state and belong in neither cache nor Settings.
- **Requested review categories already have canonical predicates.**
  `isApproved` uses the configured approval label for issues and the configured
  label/native-review predicate for PRs; `isProblem` and `pullRequestStatus`
  already prioritize changes/blocking labels, failed CI, and merge conflicts
  (`src/Kanban/Workflow.hs:203-240`). The filter must reuse those semantics.
- **Standalone is structural, not a label.** Board entries are `Standalone`,
  `Tracked`, or `TrackerHeader`; sorting and rendering reconstruct contiguous
  epic groups (`src/Kanban/Domain.hs:321-328`,
  `src/Kanban/Workflow.hs:141-188`, `src/Kanban/UI/Board.hs:263-280`). Filtering
  children without retaining needed headers would orphan cards or make row
  targets unsafe.
- **Search has already designed the shared safety seam.** The ready
  `docs/issue_search_design.md` specifies one derived visible-entry authority,
  identity-based selection reconciliation, contextual epic headers, and an
  in-flow search box. Filter must feed that authority rather than layer a
  renderer-only list over raw `(column,row)` targets. SRCH-1 is therefore an
  explicit dependency for tandem behavior.
- **No overlapping tracker arc was found.** Three initial repo-scoped
  open-and-closed searches plus four title-focused readiness searches for board
  filters, closed issues, completed history, and live-only open loading found
  no matching issue or epic as of 2026-08-11. Four additional readiness
  searches for GitHub refresh coordinators, rate-limit refresh handling, and
  queued pagination also found no match before FILT-4 was settled.
- **Manual performance calibration already has an owner.** The release design's
  REL-1 slice measures startup, idle CPU, resident memory, refresh count, and
  redraw behavior in a real terminal (`docs/design.md:2086-2102`). This arc
  should supply large deterministic fixtures and ensure REL-1 is eventually
  exercised with completed history loaded, rather than creating a duplicate
  generic performance issue.
- **Newest-updated history ordering contradicts a tested sorting contract.**
  design.md §12 "Sorting with trackers" states that inside a tracker group
  "implementation order is authoritative after the revised-issue tier, even if a
  later child has a problem", and that standalone cards sort problems first,
  then approved, then oldest. `sortColumnEntries` implements exactly that
  hierarchy — revised groups, revised standalone, ordinary groups, ordinary
  standalone — with `trackedChildKey` deferring to `implementationSortKey`
  (`src/Kanban/Workflow.hs:153-198`), and tests pin it
  (`test/Spec/Board/Workflow.hs:203,342`,
  `test/Spec/Board/Tracker.hs:230,257-267`). This arc's "newest-updated ordering
  within their historical subset" therefore has no settled relationship to that
  hierarchy. The conflict is immediate rather than theoretical: epic #261 is an
  open tracker whose three children — #262, #263, and #264 — are all closed
  issues, so its group holds only historical children the moment completed
  history loads (verified 2026-08-13).
- **Tracker recognition has no lifecycle input.** `trackerFromIssue` classifies
  on the configured tracker label plus the parsed checklist or native
  sub-issues alone (`src/Kanban/Tracker.hs:41-51`), and `deriveBoard` maps it
  over every issue in the snapshot (`src/Kanban/Workflow.hs:38`). Once closed
  issues join that list, this repository's three closed epics — #159, #122, and
  #79 — become tracker group headers with no decision behind it. Nothing in the
  arc says whether a closed tracker is a header, whether a surviving open child
  joins its group, or what a lifecycle-mixed group does under the default
  Closed-off criteria, where the header itself would be hidden. All three of
  those epics currently have only closed children, so no live case exists today,
  but an epic closed ahead of a child, or a reopened child, reaches it.

## Desired experience

On process launch, Kanban requests two logically independent data generations
through one repository-scoped provider coordinator. It loads every open issue
and every open pull request first and publishes them atomically; open cards are
never restored from disk. Any complete completed-history cache loads into
memory without waiting for GitHub, but the provider traversal of all closed
issues and closed/merged PRs starts after the foreground open attempt and then
runs cooperatively in the background. Once the open board is available, normal
use continues while completed history finishes.

Pressing `u update` requests the same coordinated two-generation cycle. The
open generation reloads all open issues and PRs before completed traversal
starts or resumes, so an old completed item whose title, labels, body, reviews,
checks, or tracker relationship changed is eventually reconciled without
spending the quota needed for foreground work. Repeated `u` requests coalesce
to one newest queued cycle and generations cannot publish out of order.

The application defaults every category on except Closed, so the ordinary view
contains the complete live open board. Pressing `f` opens a compact checkbox
panel above the board's cards and, when present, above the search box. Toggling
a checkbox updates cards and counts immediately; there is no Apply button and
no GitHub request per toggle.

State, kind, workflow, and structure are separate groups. Choices are ORed
within a group and ANDed across groups. The visible label `Closed` means
completed lifecycle: GitHub CLOSED issues plus CLOSED or MERGED pull requests.
For example, checking Closed and unchecking Open yields only completed work;
then selecting Pull requests narrows that set to closed and merged PRs. Zero
checked values in a group is a valid empty result, not an implicit reset.

If Closed is checked while the current completed generation is loading—whether
at startup or after `u`—the board body shows one centered, determinate progress
bar when a total is known and an indeterminate bar otherwise. It renders no
cards from any lifecycle, so a stale or mixed generation cannot masquerade as a
coherent result. This is blocking only for the card surface: `f`, filter focus,
footer/help, and the Closed checkbox remain operable. Unchecking Closed
immediately removes the blocker and restores the open-only interface while the
background generation continues.

The panel can be hidden without changing its criteria. Selections govern the
board through details/session overlays, GitHub refreshes, and every search
transition, and reset only when the Kanban process exits. When filter and
search are both visible, filter is the upper box, search is below it, and cards
follow. Filter first determines eligible entries; search then matches
number/title within those entries.

## Scope

### In scope

- An `f filter` binding and live keyboard/mouse-operable checkbox panel.
- Process-lifetime filter criteria, distinct from panel visibility/focus.
- Uncapped, provider-fresh open issue and open PR loading without persistent
  open-data cache reads or writes.
- Complete closed-issue and closed/merged-PR history, background refresh,
  separate complete-generation cache, lifecycle-aware cards, and honest
  loading/completeness/failure states.
- The requested Open, Closed, Approved, Changes, and Standalone options plus
  the kind/workflow/structure values needed to make the facets exhaustive.
- One filter-then-search visible-entry pipeline with structural repair and
  identity-based selection reconciliation.
- Filter/search stacking, responsive wrapping, active-filter indication,
  blocker/no-result states, and wide/narrow/open-border/ASCII verification.
- design.md §6-§8/§13/§16, README, user guide, footer, and help updates.

### Out of scope

- GitHub server-side search syntax, arbitrary label pickers, saved presets,
  custom query languages, or fuzzy matching.
- Persisting filter criteria across restarts or adding filter keys to config.
- Changing approval, changes-requested, problem, tracker, or standalone
  semantics; filters consume the configured/current predicates.
- Mutating GitHub state from the filter panel or from historical cards.
- Adding a fifth Closed/Archive column.
- Rendering a partial completed-history page as though it were a usable board.

## Design

- **Two-generation ownership (D-8, D-17).** App state owns independent `OpenData` and
  `CompletedData` generations, each with generation ID, freshness, progress,
  last complete in-memory value, and failure. Launch and `u` request both
  generations through one coordinator even though each dataset publishes and
  fails independently. Each connection follows `pageInfo.hasNextPage` to false
  and each provider process/page is deadline- and cleanup-bounded. Only the
  newest fully successful generation may publish; cancellation, timeout,
  malformed pages, and stale completion events cannot replace a complete
  value.
- **Complete live open data (D-8, D-13, D-16).** The open generation requests every OPEN
  issue and OPEN PR. The 250/100 configured caps and truncation flags no longer
  define the board contract; either this generation is complete or it is not
  published. No open issue, open PR, or combined board snapshot is read from or
  written to durable cache. At initial process launch the card surface remains
  in an open-loading state until the first complete generation arrives. A
  later `u` keeps the prior complete in-memory open board usable and atomically
  replaces it when the new generation finishes.
- **Complete background history (D-8, D-10, D-11).** The completed generation
  requests every CLOSED issue and every CLOSED or MERGED PR, ordered by newest
  update when supported, and traverses through the final page on every launch
  and `u`. Full traversal—not only fetching new closures—is what detects the
  rare edit to an old completed item. Open and completed identities are
  reconciled at publication so a reopened item cannot remain in both sets.
- **Completed cache (D-10).** A separately versioned, per-repository envelope
  stores only a fully successful completed generation plus its fetch metadata.
  It covers both issues and PRs and respects the existing cache-disable option.
  Schema mismatch or partial/malformed data is absent, never guessed. The
  current schema-5 repository snapshot is migrated/retired rather than reused
  for open data. A successful background generation atomically replaces the
  completed cache; an interrupted one never does. The cache may seed the last
  complete in-memory history and failure fallback, but cannot bypass D-9's
  blocker while a newer generation is active.
- **Blocking completed view (D-9).** If Closed is selected while
  `CompletedData` is Loading, the whole card area is replaced by a centered
  progress panel and contains no open, completed, cached, or search-result
  cards. Filter state and focus remain active above it. Unchecking Closed is a
  synchronous view transition back to the open pipeline and does not cancel
  the history load. Checking Closed again restores the blocker until that
  generation publishes. Card mouse targets/actions are disabled under the
  blocker; footer/help/filter keys remain active.
- **Lifecycle model (D-11).** Add explicit `IssueState = Open | Closed` and
  `PullRequestState = Open | Closed | Merged` (exact constructor spelling is an
  implementation detail) decoded from GitHub. The State facet maps Open to
  both OPEN variants and maps the visible Closed checkbox to closed issues plus
  CLOSED/MERGED PRs. Lifecycle is part of stable card data, cache schema,
  details, badges, filter predicates, and action guards.
- **Historical presentation (D-12, D-15, D-19, D-20, D-22).** Closed issues
  render in Issues, regardless of former assignees, with a `CLOSED` badge.
  Closed/merged PRs render in Done with distinct `CLOSED`/`MERGED` badges.
  Details and URLs remain readable for both, while review, solve, autosolve,
  rereview, merge, direct-merge, and worker mutations refuse them with a
  read-only-history notice. Ordering follows design.md §12 unchanged inside a
  tracker group: implementation order stays authoritative for every tracked
  child whatever its lifecycle. Newest-updated ordering applies only to
  standalone completed cards, which form a block after every open standalone
  card, and to the relative order of wholly completed groups. A completed card
  is attention-neutral — it never promotes itself or its group — but keeps the
  status color and border its labels and checks earned. A completed tracker is
  still a tracker: it keeps its header and groups its children, and when the
  current criteria hide that header a surviving open child falls back to
  `Standalone`, which is what the board renders today. Default Closed-off
  criteria therefore reproduce the live four-column workflow exactly.
- **State ownership (D-23).** App state holds `FilterCriteria` independently
  from panel visibility and checkbox focus. Criteria initialize to defaults at
  every process start, survive every in-process refresh/overlay/dismissal, and
  are never serialized. An edit is a pure transition followed by
  visible-entry/selection reconciliation. The criteria state and the pipeline
  that honors it arrive with `FILT-5`, one slice ahead of any way to edit them,
  so history lands hidden rather than unconditionally visible.
- **Grouped checkbox semantics (D-6).** The settled inventory is
  `State [Open, Closed]`; `Kind [Issues, Pull requests]`; `Workflow [Changes,
  Problems, Approved, Other]`; and `Structure [Epic groups, Standalone]`.
  Every value is checked initially except Closed. Within Workflow, categories
  are exclusive by strongest-state precedence: configured Changes first;
  other red/problem conditions second; Approved third; everything neutral,
  pending, ready-but-not-approved, or draft is Other. Epic groups include
  tracker headers and tracked children; Standalone means the existing
  constructor, not “unassigned.”
- **Composition.** The authoritative view is:
  complete datasets → filter criteria → structural-context repair → optional
  search → structural-context repair → rendered/interactive entries. Filtering
  and search retain a tracker header when a surviving child needs context and
  may temporarily expose a matching child beneath a collapsed epic without
  mutating expansion state. Render, counts, selection, click resolution,
  details/action lookup, refresh reconciliation, and boundary movement all
  consume the final view; raw row indices are never mixed with filtered ones.
- **Counts and hidden-state indication.** Default criteria are the normal
  baseline, so completed history in memory does not turn every heading into a
  ratio. A non-default filter shows `f filter*` in the footer even while hidden
  and filtered/raw counts in the panel. With filter alone, headings show
  eligible/raw counts; with search too, search result/total uses the
  filter-eligible denominator while the filter panel retains raw context.
- **Panel layout (D-5).** Filters apply globally and the panel spans the board
  above column headers, search, and cards. Checkbox chips wrap across the
  current width; the panel participates in vertical layout and shifts the
  board down by its exact height. It never covers the usage sidebar, footer,
  search, or cards.
- **Input/focus (D-5).** From the board, `f` shows/focuses the panel. Up/Down or
  `j`/`k` moves, Left/Right changes group/option, Space toggles, `d` restores
  defaults, and `f` or Esc hides without clearing criteria. Mouse clicks toggle
  a named box. If search exists, `s` from filter focuses it; lowercase `f` from
  search focuses filter without clearing the query. Uppercase `F` remains
  available as a literal query character. `q` and board-scoped Ctrl-C retain
  quit behavior.
- **Refresh and failure (D-13, D-14, D-16, D-17).** A successful open or completed generation swaps only
  its dataset, reapplies criteria/query, and preserves a present stable
  identity. Open and completed failures do not erase their last complete
  in-memory values. While Closed is off, completed failure is a non-blocking
  notice. With Closed on, a failure ends the loading blocker and exposes the
  last complete cache/in-memory history with a persistent stale/error marker;
  without a complete fallback, it shows an error/empty state with no cards. No
  partial generation is ever visible. `u` while a cycle is active reports that
  update as already running and coalesces at most one newest follow-up request
  rather than spawning an overlapping provider worker.
- **First-open failure (D-16).** If the first live open generation
  fails, replace its loading panel with a centered `OPEN DATA UNAVAILABLE`
  state containing the classified reason and `u retry` hint. Render no cards,
  keep `u`, `q`, Ctrl-C, help, and options available, and never fall back to the
  retired open cache. Later open-generation failures retain the last complete
  in-memory board with a stale/error marker as D-13 requires.
- **Cooperative provider (D-17).** One repository-scoped coordinator
  owns the durable `gh` record, process slot, generation ordering, and rate
  metadata. Open work always has priority; completed traversal starts or
  resumes only after the current open attempt finishes and yields between
  pages. Each GraphQL page reports its cost/remaining/reset time. Background
  history pauses before exhausting an open-refresh reserve and reports
  `History paused · GitHub limit resets …`; a known rate-limit response obeys
  reset/retry metadata instead of hot-looping. `u` queues one newest requested
  generation, and quit cancels queued/running work through the existing
  verified process cleanup. This independently reviewable foundation is FILT-4
  and lands before either data-generation slice.
- **Faceted feedback (D-18).** Each checkbox shows an in-memory count
  computed under all *other* selected groups while ignoring its own group's
  current selection, so values explain what toggling them would reveal. Closed
  shows `…` or loaded/total progress until history is current rather than a
  false zero. While Closed is off, a compact footer status still says whether
  completed history is loading, paused, current, stale, or failed; it never
  blocks ordinary use. These behaviors belong in FILT-2 rather than another
  child issue.
- **Empty states.** If complete data and criteria yield no entries, each
  affected column says `No filter matches`; a subsequent search with no result
  says `No search matches` against the eligible set. Zero selected values is
  valid. These are distinct from the centered open/completed loading states.

## Decisions

### D-1. Filtering is live and checkbox-driven

The `f filter` shortcut opens a separate checkbox box, and edits immediately
change visible cards without Apply/submit or a GitHub request per toggle.

### D-2. Filters and search operate independently and together

Filter can be used without search; when both exist, filter is above search and
both are above cards. Filter chooses eligible cards first and search narrows
those results. Neither opening nor editing one clears the other.

### D-3. Defaults show every open card and hide completed cards

At process start all settled category values are enabled except Closed. With
complete uncapped open data, the default reproduces the live board rather than
a cached or truncated approximation. Open-off plus Closed-on produces
completed-only history.

### D-4. Filter criteria persist for exactly one application process

Selections survive hiding, overlays, GitHub updates, and search. They reset on
exit and are not written to cache/settings/config. Completed *data* may use its
own durable cache; choices never do.

### D-5. Filters are global and filter/search focus composes

User signoff 2026-08-11. One filter panel spans the board and affects all
columns. It renders above search/cards; `f`/Esc hide it without reset, Space
toggles, `d` restores defaults, and `s`/`f` transfer focus between filter and
search.

### D-6. Filters use four grouped, exhaustive facets

User signoff 2026-08-11. The groups are State (Open, Closed), Kind (Issues,
Pull requests), Workflow (Changes, Problems, Approved, Other), and Structure
(Epic groups, Standalone). Values are ORed within a group and groups are ANDed;
all values default checked except Closed. Workflow uses strongest-state
precedence so every card has exactly one value.

### D-7. Complete history has no fixed item cap

User signoff 2026-08-11. Every closed issue must be accessible. PR parity now
extends this to every closed or merged PR. The rejected `max_closed_issues =
100` would already omit 16 issues in this repository. Loading, stale, current,
and failure states must never label partial access complete.

### D-8. Launch and `u` start complete open and completed generations

User decision 2026-08-11. Launch loads all open issues and open PRs, then
normal use continues while completed issues and PRs refresh in the background.
`u update` repeats the same lifecycle. Both generations are uncapped and
publish atomically; completed data is held in memory after publication.

### D-9. Selecting Closed during a completed refresh blocks the card surface

User decision 2026-08-11. If completed history has not finished loading, or
`u` starts a new completed refresh while Closed is selected, a centered loading
bar replaces every card. Unchecking Closed immediately removes the blocker and
returns to the regular open interface while loading continues.

### D-10. Completed data may be cached; open data must not be cached

User decision 2026-08-11. A complete completed-issue/PR generation may use a
separate durable cache and remains in memory. Open issues and open PRs are
always provider-fresh and never restored from or written to a persistent board
cache. Background completed refresh revisits old history so rare edits are not
missed.

### D-11. Issues and pull requests have lifecycle parity

User decision 2026-08-11. Open loading, completed loading, caching, filtering,
blocking, update, and completeness rules cover both item kinds. The visible
Closed checkbox includes CLOSED issues and both CLOSED and MERGED PRs.

### D-12. Closed issues remain readable history in Issues

User acceptance of the prior recommendation 2026-08-11. Closed issues render
in Issues with a CLOSED badge and preserve applicable epic context. Details and
URLs work; review, solve, and autosolve mutations refuse the historical card
with a clear notice.

### D-13. Initial open loading blocks, but later open updates retain the last complete board

User signoff 2026-08-11. Because no persistent open cache is allowed, initial
launch shows a centered open-data loading state until the first complete live
generation publishes. A later `u` keeps the last complete in-memory open board
usable until its replacement publishes atomically. If Closed is selected, the
completed-generation blocker from D-9 still takes precedence.

### D-14. Completed refresh failure falls back only to complete stale history

User signoff 2026-08-11. A completed-generation failure ends its loading
blocker and exposes the last complete cached/in-memory generation with a
persistent `STALE · refresh failed` marker, recorded timestamp, and retry
notice. If no complete fallback exists, Closed produces a clear error/empty
state with no cards. Partial pages are never a fallback.

### D-15. Completed pull requests are read-only history in Done

User signoff 2026-08-11. CLOSED and MERGED PRs render in Done, retain distinct
badges, and sort newest-updated within the historical subset. Details and URL
navigation remain available; review, rereview, merge, direct-merge, and worker
mutations refuse the card with a read-only-history notice.

### D-16. First uncached open failure is a recoverable blocking state

User signoff 2026-08-11. If the first live open generation fails, the loading
panel becomes a centered `OPEN DATA UNAVAILABLE` state with the classified
reason and `u retry` hint. It shows no cards and never restores the retired open
cache, while `u`, `q`, Ctrl-C, help, and options remain available. Later open
failures retain the last complete in-memory board with a stale/error marker.

### D-17. One rate-aware coordinator owns all repository GitHub work

User signoff 2026-08-11. Open and completed datasets keep independent
generation/publication state, but one repository-scoped coordinator serializes
their provider pages and owns the durable `gh` cleanup record. Open work has
priority; history yields between pages, preserves quota for a subsequent open
refresh, pauses until reported reset/retry time when necessary, and never
hot-loops a known limit. Overlapping requests coalesce to one newest follow-up,
and quit uses verified cleanup. This is a separate FILT-4 foundation slice.

### D-18. Facet counts predict toggles and history status remains visible

User signoff 2026-08-11. Each checkbox displays the result count computed under
all other selected groups while ignoring its own group's selection. Closed
shows unknown or loaded/total progress until history is current rather than a
false zero. With Closed off, the footer non-blockingly reports completed
history as loading, paused, current, stale, or failed. FILT-2 owns this behavior
without another child issue.

### D-19. Completed cards keep §12's ordering inside tracker groups

User signoff 2026-08-13, resolving `Q-10`. Implementation order remains
authoritative for every tracked child regardless of lifecycle, exactly as
design.md §12 states and `trackedChildKey` implements. Newest-updated ordering
applies only to standalone completed cards and to the relative order of groups
that are wholly completed. This amends the ordering wording in D-12 and D-15;
their placement, badge, and read-only-history substance is unchanged. Rejected:
newest-updated inside a mixed group, which would run two different orders inside
one group; and an ungrouped historical block, which would discard the epic
context D-12 requires.

### D-20. A closed tracker is still a tracker, with a Standalone fallback

User signoff 2026-08-13, resolving `Q-11`. A completed tracker keeps its group
header, carries the `CLOSED` badge, and groups its children. When the current
criteria hide that header — the default, since Closed is off — a surviving open
child falls back to `Standalone`, which is exactly what the board renders today,
so D-3's requirement that the default reproduce the live board continues to
hold. Board structure therefore depends on the visible lifecycle set rather than
on the raw dataset. Rejected: treating a closed tracker as an ordinary card,
which would leave every completed epic ungrouped; and stating the same outcome
purely as a filter-pipeline rule, which would move the work out of this arc's
data slices and into `FILT-2`.

### D-21. `FILT-1` splits into a data slice and a presentation slice

User signoff 2026-08-13, resolving `Q-12`. `FILT-1` keeps the data half:
lifecycle types, uncapped completed pagination, completed generation, progress
and failure state, the versioned completed-history cache, full old-item update
detection, and open/completed identity reconciliation. A new `FILT-5` takes the
presentation half: historical placement under D-19 and D-20, `CLOSED`/`MERGED`
badges, and the read-only refusal of every settled mutating action. `FILT-5`
depends on `FILT-1`, and `FILT-2` depends on both. No existing slice ID is
renumbered. Rejected: one slice, whose roughly sixteen-module reach and six
design.md sections make a single reviewable PR implausible; and splitting only
the action guards, which would leave completed history rendering as actionable
for one merge.

### D-22. Completed cards are attention-neutral but keep their status treatment

User signoff 2026-08-13, resolving `Q-13`. A completed card never promotes
itself or its group into design.md §12's attention tiers. Standalone completed
cards form a newest-updated block after every open standalone card, and a wholly
completed group sorts after open groups. The card keeps the status color and
border its labels and checks earned, so a closed issue that was blocked still
reads as blocked. Rejected: dropping the status treatment as well, which would
discard how an item ended; and keeping full attention weight, which would bury
live work under history whenever Closed is on.

### D-23. `FILT-5` lands the filter criteria state with its D-3 defaults

User signoff 2026-08-13, resolving `Q-14`. `FILT-5` introduces `FilterCriteria`
as application state initialized to the D-3 defaults — every value checked
except Closed — and the visible-entry pipeline honors it, even though nothing
can edit it until `FILT-2`. The board therefore looks exactly as it does today
when `FILT-5` merges, and `FILT-2` adds only the panel, its keyboard and mouse
handling, facet counts, active-filter indication, and the completed-loading
blocker. Rejected: rendering nothing, which would leave `FILT-5` with no
observable outcome of its own; and rendering all history unconditionally, which
would be a visible regression until `FILT-2` landed.

## Open questions

### Q-1. Is the filter global, and how should filter/search focus compose?

Resolved by D-5.

### Q-2. Is the grouped checkbox inventory and boolean logic right?

Resolved by D-6.

### Q-3. How much closed history is loaded, where does it render, and is it actionable?

Resolved by D-7 through D-12 and D-15. History is complete, background loaded,
cached separately, blocked while its active generation is incomplete, rendered
read-only in Issues/Done, and refreshed on every launch/`u`.

### Q-4. What remains visible during the open half of `u update`?

Resolved by D-13.

### Q-5. What should happen after completed refresh failure with a complete cache?

Resolved by D-14.

### Q-6. Where do completed PRs render, and which actions remain available?

Resolved by D-15.

### Q-7. What should first launch show if uncached open loading fails?

Resolved by D-16.

### Q-8. Should one rate-aware coordinator own both GitHub generations?

Resolved by D-17.

### Q-9. Should the filter expose faceted counts and background-history status?

Resolved by D-18.

### Q-10. Where do completed cards sort, given design.md §12's existing hierarchy?

Resolved by D-19. The arc said completed cards take "newest-updated ordering
within their historical subset"; §12 says implementation order is authoritative
inside a tracker group and that standalone cards sort problems, then approved,
then oldest, after the revised-issue tier. Both cannot govern a closed child of
an open epic, and epic #261's group is entirely such children today. Known
options:

- **Grouped, historical children newest-updated after the open ones.** Epic
  context survives and "historical subset" keeps its literal meaning, at the
  cost of one group using two different orders internally.
- **Grouped, §12 unchanged inside every group.** Implementation order governs
  all tracked children regardless of lifecycle; newest-updated then applies only
  to standalone historical cards and to the relative order of wholly historical
  groups. Smallest disturbance to a tested contract; "newest-updated" no longer
  describes tracked history.
- **Ungrouped historical block.** Every completed card leaves its group and
  forms a newest-updated block below the open cards in its column. Simplest
  ordering rule, but it drops the epic context D-12 requires.

D-19 did not settle whether a completed card participates in the attention tiers
at all; that is `Q-13`.

### Q-11. Is a closed tracker issue still a tracker?

Resolved by D-20. `trackerFromIssue` has no lifecycle input, so completed
trackers would have become group headers by default rather than by decision.
Options considered:

- **Still a tracker.** A closed epic keeps its header, carries the `CLOSED`
  badge, and groups its children. This needs a companion rule for the default
  Closed-off view, where the header is hidden: either a surviving open child
  falls back to `Standalone`, or the hidden header is retained as visible
  context. Note that today an open child of a closed epic renders as
  `Standalone` only because closed issues are never loaded, so this option
  changes the default board that D-3 requires to reproduce the live board unless
  the fallback is chosen.
- **Not a tracker.** A closed tracker renders as an ordinary historical issue
  card with a `CLOSED` badge, and its children keep whatever grouping open
  trackers give them. Keeps the default board identical and needs one lifecycle
  guard, but a completed epic reads as a plain card and its completed children
  are ungrouped.
- **A tracker only where the current criteria make it visible.** Grouping is
  computed over the visible lifecycle set, so Closed-off behaves exactly as
  today and Closed-on groups completed epics with completed children. Most
  faithful to both defaults, but it makes board structure depend on filter
  criteria, which is a larger change and lands in `FILT-2` rather than `FILT-1`.

### Q-12. Should `FILT-1` be split?

Resolved by D-21. Its scope spanned data acquisition and presentation together,
unlike every other slice in this arc. Mapped to modules it reaches
`Domain`, `GitHub/Fetch`,
`GitHub/Decode`, `Cache`, `UI/Types`, `UI/Refresh`, `UI/Reconcile`, `Workflow`,
`Tracker`, and `UI/Board`, plus the read-only guard surface in `UI/Events`,
`UI/Solve`, `UI/Review`, `UI/PullRequest`, `UI/AutoSolve`, and `UI/Worker`,
with design.md §8, §11, §12, §13, §16, and §17 to update — §8's "Done is a
ready-to-finalize queue, not a history column" being a contract this work
rewrites. Known options: keep it as one slice; or keep `FILT-1` as the data half
(lifecycle types, uncapped completed pagination, generation and failure state,
the completed cache, identity reconciliation) and add a new `FILT-5` for the
presentation half (historical placement, ordering, badges, read-only action
guards) depending on it, with `FILT-2` then depending on both.

### Q-13. Do completed cards carry attention weight?

Resolved by D-22. design.md §12 promotes `reviewed:revised` cards and the groups
holding them, orders tracker groups by their strongest visible attention state,
and sorts standalone cards problems first, then approved, then oldest. D-19
settled ordering inside a group but not whether a completed card's own labels
still drive those tiers. This repository closes issues with `reviewed:approve`
and `reviewed:changes` still attached, so completed work would otherwise promote
itself — and its whole group — above live work the moment history loads. Known
options:

- **Attention-neutral in sorting and styling.** A completed card never promotes
  itself or a group and renders with a plain completed treatment. Standalone
  completed cards form a newest-updated block after every open standalone card,
  and a wholly completed group sorts after open groups.
- **Attention-neutral in sorting, styled as it was.** Same ordering rule, but
  the card keeps the status colors and border it earned, so a closed issue that
  was blocked still reads as blocked.
- **Fully attention-bearing.** Labels keep their tiers regardless of lifecycle,
  so a completed problem sorts ahead of clean live work.

### Q-14. What does `FILT-5` render before `FILT-2` exists?

Resolved by D-23. D-3 hides completed cards by default, but the criteria that
express that default arrive with the panel in `FILT-2`. The split in D-21 leaves
at least one merge where placement exists and nothing can set criteria. Known
options:

- **`FILT-5` lands the criteria state with its D-3 defaults.** Nothing can edit
  them yet, so the board looks exactly as it does today, and `FILT-2` adds only
  the panel, the editing, the facet counts, and the blocker. Every intermediate
  merge stays shippable and the placement work is proven end to end.
- **`FILT-5` renders all completed history unconditionally.** Every closed issue
  and pull request appears on the board until `FILT-2` lands, which is a visible
  regression for however long that is.
- **`FILT-5` renders nothing.** Placement, ordering, badges, and guards land as
  pure, tested code that only `FILT-2` activates, matching how `FILT-4`'s
  history job kind is exercised. Smallest risk, but the slice has no observable
  outcome of its own.

## Verification strategy

- GraphQL and pagination tests cover uncapped OPEN issue/PR traversal and
  uncapped CLOSED issue plus CLOSED/MERGED PR traversal, per-page deadlines,
  cleanup, total progress, final-page completion, and lifecycle decoding.
- Generation tests cover concurrent launch/`u` starts, generation IDs,
  cancellation/stale events, atomic publication, duplicate identity
  reconciliation, reopen/reclose/merge transitions, and failure isolation.
- Coordinator tests cover a single repository-scoped process owner, open-job
  priority, one queued newest generation, page-boundary history yield,
  rate-budget pause/resume, reset-aware retry, and verified quit cleanup.
- Cache tests prove open data is never read/written, legacy combined snapshots
  cannot seed open state, completed schema round-trips histories larger than
  100 for both kinds, and partial/old/wrong-repository caches are rejected.
- Background-refresh tests edit an old completed issue and an old merged PR,
  then prove a complete traversal and atomic cache replacement expose both
  changes without disturbing the live open board.
- Pure filter tests cover every category, strongest-state precedence,
  OR-within/AND-across truth tables, zero-selection groups, lifecycle/kind
  combinations, defaults, epic repair, and filter-then-search ordering.
- Ordering tests prove design.md §12's implementation order still governs every
  tracked child once completed children join a group, that standalone completed
  cards form a newest-updated block after open standalone cards, that a wholly
  completed group sorts after open groups, and that a completed card carrying
  `reviewed:revised`, a blocking label, or an approval promotes neither itself
  nor its group while keeping its status treatment.
- Tracker-structure tests cover a completed tracker keeping its header and
  children, and an open child of a completed tracker falling back to
  `Standalone` under default criteria, so the default board is byte-identical to
  the one that preceded completed history.
- Transition tests cover panel visibility versus criteria, reset, focus
  transfer, both refresh generations, blocker entry/exit, Closed uncheck during
  loading, first-open failure/retry, fallback/error paths, and stable selection
  reconciliation.
- Binding/help tests cover `f filter`, focused-panel keys, SRCH-1's `s`/`o`
  migration, literal uppercase `F`, and unchanged scoped `q`/Ctrl-C behavior.
- Mouse tests cover direct toggles, blocker-disabled card targets, and card/
  epic/column targets after both filter and search are active.
- Golden Brick frames cover initial open load, background completed progress,
  first-open failure, rate-paused history, `u` with Closed off/on, stale/error
  fallback, predictive facet counts, filter-only, search-only, both boxes
  stacked, hidden active filters, no matches, completed-only issues/PRs, and
  wide/minimum/narrow/open-border/ASCII layouts.
- Workflow tests prove historical details/URLs remain readable and all settled
  mutating actions fail closed without launching a process.
- design.md, README, user guide, footer, and help are updated in the slice that
  changes each contract surface.
- Large synthetic issue/PR histories exercise cache round trips and live
  filter/search derivation without fixed item caps; the existing REL-1 manual
  gate should subsequently measure a real terminal with history loaded.

## Delivery plan

### FILT-4. Coordinate GitHub refresh ownership and rate pressure

- **Outcome:** one repository-scoped provider coordinator safely schedules
  open and completed generations, preserves foreground priority, and pauses
  background history instead of racing cleanup records or exhausting a known
  GitHub budget.
- **Scope:** coordinator/job state, one durable `gh` cleanup owner and process
  slot, open-first scheduling, page-boundary history yield, GraphQL
  cost/remaining/reset decoding, open-refresh reserve, paused/resume/retry
  transitions, one coalesced newest follow-up request, verified quit cleanup,
  documentation, and provider/transition tests.
- **Phase:** 1
- **Depends on:** none
- **Ordering:** foundation; must land before either data-generation slice
- **Relevant decisions:** D-8, D-9, D-13, D-17
- **Acceptance signals:** simultaneous refresh requests never spawn competing
  repository `gh` owners or lose a recorded process group; open jobs run before
  queued history; a low-budget fixture pauses with its reset time and later
  resumes; repeated `u` requests produce at most one newest follow-up; quit
  leaves no owned process or ambiguous cleanup record.
- **Out of scope:** uncapped open/history domain models, completed cache,
  checkbox UI, or text search.
- **Open questions:** None.

### FILT-3. Make the open board complete, live-only, and atomically refreshable

- **Outcome:** launch and `u` obtain every open issue and PR from GitHub and
  publish one coherent live board without reading or writing open-card cache.
- **Scope:** uncapped open pagination, per-page deadline/cleanup, open
  generation/progress state, atomic publication, legacy combined-cache
  retirement, no-open-cache enforcement, refresh selection/session
  reconciliation, documentation, and provider/domain/cache/transition tests.
- **Phase:** 2
- **Depends on:** FILT-4
- **Ordering:** second; supplies the live-data lifecycle used by history
- **Relevant decisions:** D-3, D-7, D-8, D-10, D-11, D-13, D-16, D-17
- **Acceptance signals:** fake connections exceeding both former caps reach
  their final pages; startup never renders a persisted open item; partial or
  stale generation events never replace a complete board; `u` observes all
  open issue/PR changes; first-load failure shows the settled recoverable state;
  cache files contain no open-card snapshot.
- **Out of scope:** completed-history traversal/cache; checkbox UI; search.
- **Open questions:** None.

### FILT-1. Load and cache complete issue/PR history in the background

- **Outcome:** every completed issue and PR is loaded, reconciled, and cached as
  a complete generation on launch and `u`, without delaying ordinary open-only
  board use and without changing what the board renders.
- **Scope:** issue/PR lifecycle types decoded from GitHub, uncapped CLOSED issue
  and CLOSED/MERGED PR pagination, per-page deadline/cleanup, completed
  generation/progress/failure state, versioned per-repository complete-history
  cache, full old-item update detection, open/completed identity reconciliation,
  documentation, and provider/domain/cache tests.
- **Phase:** 3
- **Depends on:** FILT-4, FILT-3
- **Ordering:** third; critical path. Supplies complete history and freshness to
  the presentation slice
- **Relevant decisions:** D-3, D-4, D-7, D-8, D-9, D-10, D-11, D-14, D-17, D-21
- **Acceptance signals:** fake histories exceeding 100 in both item kinds reach
  true final pages; an old completed edit is found after restart and `u`; no
  partial generation overwrites a complete cache; open use does not wait for
  history; the rendered board is unchanged by this slice.
- **Out of scope:** historical placement, badges, and action guards, which are
  `FILT-5`; the checkbox panel and text-search composition, which are `FILT-2`.
- **Open questions:** None.

### FILT-5. Render completed history read-only behind default-hidden criteria

- **Outcome:** completed issues and pull requests take their settled places,
  badges, and read-only action behavior, while the default criteria keep the
  board looking exactly as it does today.
- **Scope:** `FilterCriteria` state initialized to the D-3 defaults and honored
  by the visible-entry pipeline, historical placement in Issues and Done under
  D-19, D-20, and D-22, `CLOSED`/`MERGED` badges, the `Standalone` fallback for
  an open child of a hidden completed tracker, read-only refusal of every
  settled mutating action, documentation, and pure/workflow/golden tests.
- **Phase:** 4
- **Depends on:** FILT-1
- **Ordering:** fourth; critical path
- **Relevant decisions:** D-3, D-4, D-11, D-12, D-15, D-19, D-20, D-21, D-22,
  D-23
- **Acceptance signals:** under default criteria the rendered board matches the
  pre-slice board, including an open child of a completed tracker rendering as
  `Standalone`; with Closed forced on in a test, completed issues appear in
  Issues and completed PRs in Done with correct badges, §12 group ordering, and
  no attention promotion; every settled mutating action refuses a historical
  card without launching a process.
- **Out of scope:** the visible panel, focus, facet counts, active-filter
  indication, and the completed-loading blocker, which are `FILT-2`; history
  acquisition and caching, which are `FILT-1`.
- **Open questions:** None.

### FILT-2. Add the live filter panel and compose it with column search

- **Outcome:** `f` opens the checkbox panel; criteria filter every column live,
  persist until exit, and compose safely with SRCH-1's query/input box and the
  completed-generation blocker.
- **Scope:** filter transitions and editing over `FILT-5`'s criteria state,
  settled checkbox inventory, panel and responsive layout, keyboard/mouse focus,
  active-filter indication, facet counts, the completed-loading blocker,
  filter-then-search composition, selection/count/no-result behavior,
  docs/help/footer, and pure/event/golden tests.
- **Phase:** 5
- **Depends on:** FILT-4, FILT-3, FILT-1, FILT-5, SRCH-1
- **Ordering:** fifth; integrates the two data generations with search/UI
- **Relevant decisions:** D-1 through D-23
- **Acceptance signals:** defaults show the complete live open board; Open-off
  plus Closed-on yields all completed issues and PRs after a complete load;
  Closed-on during load shows no cards and unchecking it immediately restores
  open use; facet counts predict each toggle and the footer exposes background
  history state; filter-plus-search never dispatches to a hidden/raw row;
  criteria survive every D-4 lifecycle and reset in a new app state.
- **Out of scope:** durable presets, arbitrary labels, server-side search, and
  a fifth history column.
- **Open questions:** None.
