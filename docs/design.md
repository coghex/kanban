# Kanban TUI — Design and Roadmap

Design state: `ready for issue processing`

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Complete Kanban's first-release readiness gate — [#268]
- [x] REL-1. Record real-terminal performance measurements — [#269]
- [x] REL-2. Verify live Codex and Claude usage refreshes — [#270]
- [x] REL-3. Exercise the installed terminal application — [#273]
- [ ] REL-4. Publish the first Kanban release — [deferred]: #269 and #270 have merged with passing records in section 21; #273 is the last of the three

## Epic contract

- **Goal:** Publish a traceable first Kanban release only after its installed
  terminal behavior, idle-resource profile, and live usage-provider behavior
  have been verified in the operator environment.
- **Done when:** The manual evidence is recorded, every release-blocking defect
  found by those checks is resolved or explicitly removed from scope, required
  CI passes on the release commit, and the first-release tag and GitHub Release
  both identify that commit.
- **Users and operators:** People installing Kanban from its source release and
  the maintainers responsible for its terminal and provider behavior.
- **Arc label:** `release` — created 2026-08-12 (`Release readiness gates,
  versioning, packaging, and publication`, `#FBCA04`) and carried by epic #268.
  Also intended for `docs/public_release_design.md`'s packaging epic.

Two reconciliations are owed to epic #268 and belong to the next
`/process-design-doc` run, not here. Its `Done when` still says the record
distinguishes drainer status checks from "continuous visible repainting or
flicker", which D-9 narrows to observable content churn; and its background
predates D-10's process-group rule. Neither changes the arc's shape.

## Release scope

### In scope

- Record startup, idle CPU, resident memory, refresh-count, and content-churn
  behavior from an sdist-built installed executable driven under tmux.
- Verify the built-in Codex and Claude usage providers against authenticated
  live clients without submitting a model prompt.
- Exercise startup, refresh, navigation, shutdown, and visible terminal
  stability for a deliberately chosen observation period.
- Publish the first release only after the recorded gates and required CI pass.

### Out of scope

- The broader provider-version fixture matrices noted in milestones 4, 5, and
  7 unless a live release check exposes a release-blocking incompatibility.
- New features from section 20's deferred-ideas list.
- Performance optimization without evidence that an agreed release threshold
  is missed.
- Package-registry publication and binary installers; the first release is
  distributed through GitHub only.

## Current state and evidence

The warning-clean GHC2024/Cabal foundation,
local repository resolution, event-driven Brick/Vty dashboard, standalone-card
workflow, and explicit GitHub refresh are implemented. Open issues and open
pull requests are fetched live and uncapped on every refresh, with no display
limit and no repository snapshot on disk. Checklist-based tracker hierarchy, inherited PR membership,
tracker progress, and the on-demand Codex and Claude usage providers are also
implemented. Malformed tracker diagnostics now fail visibly while preserving
valid membership and standalone fallbacks. The sidebar also controls and
monitors the local launchd-managed PR drainer. Native GitHub sub-issue membership,
canonical v2 issue-review sessions, embedded revision questions, and
the first resumable issue-solve flow are implemented. The external
usage-command escape hatch is also implemented. Broader provider-version
fixtures remain for subsequent slices.

The automated release foundation is already present: `.github/workflows/ci.yml`
builds and runs both test suites on Linux, `docs/development.md` defines the
source-distribution check, and the clean-install exercise recorded in milestone
9 has passed. As of 2026-08-13, `kanban.cabal` and `src/Kanban/CLI.hs` both
declare version `1.0.0.0` — established by #283 under packaging epic #282,
along with the root `CHANGELOG.md` whose top section is the first release's
notes — while the repository has no tags and the remote no GitHub Releases.
`.github/workflows/release.yml` joins `ci.yml` and `review-gate.yml` as a
tracked workflow: a push of a `v*` tag publishes the verified `cabal sdist`
archive as a GitHub Release, and `workflow_dispatch` rehearses the same path
under a `release-dry-run-*` tag that can produce only a draft. It never creates
a release tag. Open epic #268 now owns this release-readiness arc; closed
issue #203 covers the source distribution rather than these manual gates. The
document classification that gated publication is in place: PR #227 (commit
518a3de) added `docs/document_workflow_findings.md` to
`EXCLUDED_TRACKED_PATHS` in `tools/test_source_distribution.py`, and PR #232
(commit 4146f43) closed #225 by adding the section 7 publication lanes to
`docs/agent-workflow-contract.md`, which classify that document as
`coordination`. The 2026-08-12 readiness run of
`python3 -m unittest tools.test_source_distribution` executed all 11 tests
without skipping and passed.

A 2026-08-12 audit of the measurement surface found the manual gates
underspecified against the code they measure. `startApplication` forks
`monitorDrainer`, which spawns a fresh drainer-controller subprocess every ten
seconds for the whole session (`src/Kanban/UI.hs:202-233`,
`src/Kanban/Drainer.hs:487-533`). That job is loaded on the operator's machine
(`com.coghex.drain-prs.coghex.kanban`), and one `--json status` poll costs about
0.07 s of child CPU, so roughly 0.7% of a core is spent continuously in a
process that `ps -o %cpu -p <kanban-pid>` does not count — about a third of
D-4's 2% mean-CPU budget, attributed to a child. The first frame is drawn from a
cache snapshot loaded synchronously before `customMain`
(`src/Kanban/UI.hs:70-115`), while `startAllRefreshes` dispatches the board and
*both* usage providers asynchronously afterwards
(`src/Kanban/UI/Refresh.hs:43-51`), so "startup" names two very different
instants. Neither `~/.local/bin/kanban` nor `~/.cabal/bin/kanban` exists, so
every manual slice installs first, and the repository documents two different
installs: `cabal install exe:kanban` from the checkout (`README.md`'s "Install
from a source checkout") and the clean sdist unpack exercise
(`docs/development.md:52-58`), which `README.md`'s quickstart now leads with as
the release install path. `Q-4` through
`Q-8` raised these; D-9 through D-13 settle them.

Adding a section to this document is parser-safe. `test/Spec/UI/Keys.hs:198-207`
reads only the table rows between `## 7. Keyboard interaction` and `## 8.`, and
`tools/test_document_classification.py` asserts on this file's row inside
`docs/agent-workflow-contract.md` section 7 rather than on its body.

## 1. Purpose

`kanban` is a fast, keyboard-driven Haskell terminal dashboard for a GitHub
repository. It remains idle without consuming meaningful CPU and makes no
network requests unless the application starts, the user explicitly updates
data, or an explicitly started review/solve workflow performs its bounded work.

The dashboard combines:

- Codex and Claude five-hour and weekly usage limits in a narrow left sidebar.
- A four-column repository workflow board: Issues, Active, Reviewing, and Done.
- Rich issue and pull-request cards with GitHub label colors, body excerpts,
  assignees, linked work, mergeability, and CI state.
- Epic/tracker grouping based on ordered issue checklists such as `A1`, `A2`,
  `B1`, `C1`, and `C2`.
- Local status and start/stop control for the launchd-managed PR drainer, plus
  a direct merge of one approved pull request through that drainer's own
  single-pull-request path.
- Hideable issue-review sessions backed by the canonical v2 reviewer, with
  interactive specification revision backed by Codex app-server.
- Hideable, resumable issue-solve sessions backed by the selected canonical
  Codex or Claude CLI, plus a process/session inspector.

Board observation is read-only. An explicitly started issue review may post its
review comment and switch review labels; an explicitly started solve invokes
the existing solve workflow, which may claim an issue and create a worktree,
branch, and PR. Autosolve invokes the same ordinary solve workflow, then Kanban
owns the bounded review/revision/rereview state machine and its label handoffs.
Ordinary navigation and updates never mutate GitHub.
Starting or stopping the configured PR drainer, and merging one approved
pull request through that drainer's own single-pull-request path, are the
other explicit mutations.

## 2. Goals

- Start with `kanban` in a repository or `kanban --path DIR` from anywhere.
- Default `--path` to the current directory and resolve nested paths to the Git
  repository root.
- Support an arbitrary GitHub repository without repository-specific code.
- Render a polished Unicode interface with truecolor when available and a
  usable 256-color fallback.
- Remain fully keyboard-operable; mouse support is limited to card selection,
  live-session opening, details dismissal, panel/column scrolling, and the PR
  drainer button.
- Perform one asynchronous unified board-and-usage update at startup, then block
  on terminal events while idle and redraw only after input, resize, provider
  completion, or an active review event.
- Keep usage and GitHub refreshes independent so one failing source does not
  hide valid data from another.
- Preserve the last good snapshot when a refresh fails.
- Derive workflow state from GitHub rather than maintaining a second board
  database.

## 3. Non-goals

- A web UI, GUI, Electron application, or permanently resident daemon. An
  explicitly started agent may use a bounded detached worker so it can survive
  a dashboard restart.
- Automatic network polling.
- GitHub webhooks or a local HTTP server.
- Drag-and-drop, hover actions, mouse-driven column navigation, and general
  pointer interaction beyond the deliberately small contract in section 7.
- Drag-and-drop workflow mutation.
- Direct board editing and drag/drop mutation. Review and solve workflows may
  perform their explicitly documented GitHub mutations.
- Implementing a merge. Kanban decides only whether to invoke the PR drainer's
  own single-pull-request path (`tools/drain_prs.py --pr`), which owns every
  gate, the merge itself, and the post-merge cleanup; Kanban holds no second
  copy of any of that, and merges nothing that path would refuse.
- A permanent archive of merged or closed work.
- Multi-repository aggregation in one running board. Each invocation represents
  one repository selected by its path.

## 4. Technology

- Language: Haskell, using GHC2024 and Cabal.
- TUI: `brick` on `vty`/`vty-unix`.
- CLI parsing: `optparse-applicative`.
- JSON: `aeson`.
- Concurrency: lightweight TUI threads plus a bounded Brick `BChan`; explicitly
  started solve and PR jobs run in detached, repository-scoped worker
  supervisors with durable JSONL event journals.
- GitHub access: the authenticated `gh` CLI, preferably through one GraphQL
  query per explicit board refresh.
- Git inspection: local `git -C PATH ...` commands only; these do not contact a
  remote.
- Configuration: TOML via the maintained `toml-parser` package. The format is
  committed now and treated as stable.

Brick supplies declarative layout, connected Unicode borders, scrollable
viewports, resize handling, and an event loop that can receive custom worker
events. Vty minimizes terminal updates and handles Unicode character widths.

References:

- <https://hackage.haskell.org/package/brick>
- <https://hackage.haskell.org/package/vty>
- <https://docs.github.com/en/graphql/reference/pulls>
- <https://docs.github.com/en/graphql/reference/checks>

## 5. Command-line contract

```text
kanban
kanban --path ~/work/project
kanban --path .
```

Initial options:

```text
--path DIR                         repository path; defaults to cwd
--repo OWNER/NAME                  explicit repository; skips remote resolution
--color auto|truecolor|256|never  color policy; defaults to auto
--border box|open                 border renderer; defaults to box
--glyph-test                      print vertical-line candidates and exit
--doctor                          report AI-action readiness read-only and exit
--usage                           print both providers' usage windows and exit
--fresh                           with --usage, probe live instead of reading the cache
--json                            with --usage, write the machine-readable document
--ascii                            emergency non-Unicode border fallback
--no-cache                        do not read or write snapshots
--config FILE                     override the global configuration path
--version
--help
```

`--fresh` and `--json` modify `--usage` and are inert without it.

Startup sequence:

1. Canonicalize `--path`.
2. Resolve the repository root with `git rev-parse --show-toplevel`.
3. Read the configured GitHub remote URL locally.
4. Resolve `owner/name` from the remote, unless `--repo` supplied it directly.
   The flag is the escape hatch for unusual setups: SSH host aliases, multiple
   remotes, and bare mirrors.
5. Load configuration, and the cached usage snapshots if enabled. No
   repository snapshot is loaded: open cards are live-only (section 13).
6. Enter the TUI immediately and asynchronously update GitHub plus both usage
   providers once. The providers remain independent and failure-isolated.

The board body starts as section 17's centered loading panel and draws its
first card only when the first complete open generation publishes. The usage
pane starts from its cache when there is one, and empty otherwise.

`--doctor` short-circuits that sequence after step 1, before configuration
and repository resolution, so a fresh clone with no configured remote can
still ask why an AI action would not start. It prints readiness per
dependency and per AI action, exits non-zero when any action is blocked, and
is strictly read-only: status-only probes, no agent session, no login flow,
no model quota, and no mutation of the filesystem, provider configuration,
launchd, or GitHub. See
[workflow-setup.md](workflow-setup.md) for the setup command it names.

`--usage` short-circuits it after step 5's configuration load and before
step 2's repository resolution. Usage is global (section 14), so this mode
resolves no `owner/name` and applies no repository override: it honors
`--config` and the global usage, timeout, and cache settings, and answers
normally from a directory that is not a checkout or has no configured
remote. It never enters the TUI and never starts a background refresh.

## 6. Layout

The normal wide-screen layout is a 28-column usage sidebar plus a horizontally
scrollable four-column board.

```text
╔═ USAGE ══════════════════╦═ ISSUES ═════╦═ ACTIVE ═════╦═ REVIEWING ══╦═ DONE ═══════╗
║                          ║              ║              ║              ║              ║
║ Codex          3h 0m old ║ cards        ║ cards        ║ cards        ║ cards        ║
║ 5 hour  [██████░░░░] 63% ║              ║              ║              ║              ║
║ in 1h 5m · Thu 16:05     ║              ║              ║              ║              ║
║ week    [████░░░░░░] 41% ║              ║              ║              ║              ║
║ in 4d 18h · Tue 09:00    ║              ║              ║              ║              ║
║                          ║              ║              ║              ║              ║
║ Claude         3h 0m old ║              ║              ║              ║              ║
║ 5 hour  [████████░░] 78% ║              ║              ║              ║              ║
║ in 2h 30m · Thu 17:30    ║              ║              ║              ║              ║
║ week    [██░░░░░░░░] 22% ║              ║              ║              ║              ║
║ in 1d 18h · Sat 09:10    ║              ║              ║              ║              ║
║                          ║              ║              ║              ║              ║
║ ┏━━━━━━━━━━━━━━┓         ║              ║              ║              ║              ║
║ ┃ drain_prs.py ┃         ║              ║              ║              ║              ║
║ ┗━━━━━━━━━━━━━━┛         ║              ║              ║              ║              ║
╚══════════════════════════╩══════════════╩══════════════╩══════════════╩══════════════╝
 j/Down next  k/Up previous  x kill  h/l column  s search  e epic  enter  r review/revise  S solve  A autosolve  p processes  u update  d drainer  c sidebar  o options  ? help  q/Ctrl-C quit
```

Responsive behavior:

- The sidebar is 28 columns by default and toggles with `c`.
- Board columns have a readable minimum width rather than being compressed
  until their contents become useless. The initial minimum is 32 cells per
  column.
- When the open board has at least 134 cells available (four 32-cell columns
  plus three two-cell gutters), all four columns are visible and divide every
  available cell as evenly as possible. With the default 28-cell sidebar and
  two-cell sidebar gutter, this corresponds to a 164-cell terminal.
- Below that threshold, columns retain the 32-cell minimum and the board
  becomes a horizontal viewport.
- Moving with `h`/`l` scrolls the selected column into view.
- Very narrow terminals may show one board column at a time.
- Resize events reflow cards and excerpts without a network refresh.
- An open card search (section 7) draws a labelled box in its column's own
  layout flow, below the column heading and above the first card. The box spans
  the column's inner width, occupies one content line for an empty query, and
  grows by exactly the height its wrapped query needs, moving the cards below it
  down by that amount. It is never an overlay, never leaves its column, and a
  resize rewraps both the box and the cards under it. Moving the search to
  another column moves the box with it, drawn the same way in its new column.
- While a search is open the footer's hint line is replaced by search's own,
  because the board's line names `h`/`l` and the arrows for column movement and
  a search gives both a different meaning:

  ```text
  h/l/any letter type  backspace delete  ←/→ move search  ↑/↓ select  enter details  s/esc close
  ```

## 7. Keyboard interaction

Initial bindings:

| Key | Action |
|---|---|
| `j` / Down | Select next visible card or collapsed epic |
| `k` / Up | Select previous visible card or collapsed epic |
| `x` | Kill the selected working issue/PR process group and its child processes |
| `h` / Left | Select previous column |
| `l` / Right | Select next column |
| `g` | Select first visible item in the column |
| `G` | Select last visible item in the column |
| `s` | Open the card search on the Issues column; printable keys including h and l filter it, Left and Right move it to another column, and Esc or s closes it |
| `e` | Expand or collapse the focused epic |
| `Enter` | Open the selected card's details overlay |
| `Esc` | Close an overlay or dismiss a transient error |
| `r` | Start or reopen the selected issue's review session, or the selected PR's review, rereview, revise, or repair session; a no-op on a collapsed or childless epic header |
| `S` | Choose Codex or Claude and start/reopen an issue solve through PR creation |
| `A` | Choose Codex or Claude and start/reopen the full autosolve review loop |
| `p` | Open the process/session inspector; Enter opens a session and `x` kills its live process tree |
| `i` | Open the incidents panel listing everything needing attention; Enter goes to that work |
| `u` | Update GitHub board data and both usage providers |
| `d` or click | Start or stop the launchd-managed PR drainer |
| `m` | Merge the selected approved pull request in Done through the PR drainer's own single-pull-request path |
| `c` | Collapse or expand the usage sidebar |
| `o` | Open settings, including chat-output verbosity |
| `?` | Open a help overlay listing all bindings |
| `Ctrl-L` | Force a terminal repaint without a network request |
| `Tab` | In an open solve, PR, or review overlay, show the next in-memory session of that kind |
| `Ctrl-C` | Interrupt the current turn in an open live-agent overlay — a resumable session then accepts user guidance; a canonical review stage's process is killed instead, landing the session in its interrupted terminal state, and restarts fresh via `r` |
| `q` / `Ctrl-C` | Quit and restore the terminal |

Refresh keys are ignored for a provider that already has a request in flight.
Keybindings can become configurable later, but the first release should keep a
small fixed set.

Mouse interaction is intentionally complete but narrow:

- Left-clicking an unselected issue or PR card selects it.
- Left-clicking the selected card opens its details panel.
- Left-clicking an epic title expands or collapses that epic.
- Left-clicking outside an open details panel closes it.
- Right-clicking a board card opens its live issue-review, solve,
  autosolve-bound PR review, or direct PR session. With no live session it only
  selects the card and never opens details.
- Right-clicking anywhere while a details panel is open closes it.
- The mouse wheel scrolls the board column under the pointer by three rows per
  wheel event.
- The launchd PR drainer button remains directly clickable.

Cards, columns, and overlays do not otherwise acquire hover, drag, context-menu,
or pointer-only behavior.

### Column card search

`s` opens a card search over the Issues column. It selects that column, brings
it into the board viewport if it was scrolled out, and draws an empty search box
in the column's own layout flow — never an overlay — between the column heading
and its first card, described in section 6.

While the box is open the base board's key table is consulted only for what
search declines:

- A printable character typed without Ctrl, Meta, or Alt appends to the query,
  so `r`, `S`, `u`, `d`, and every other letter is text rather than a shortcut.
  The two exceptions are `s`, which closes search, and `q`, which reaches the
  guarded dashboard quit — so the letter `q` cannot be typed into a query.
- Backspace removes one Unicode code point. The query stops accepting printable
  input at 256 code points and accepts it again once a Backspace makes room.
- Any chord carrying Ctrl, Meta, or Alt keeps its ordinary board meaning, so
  `Ctrl-C` reaches the same guarded quit and `Ctrl-L` repaints.
- Up and Down move the selection among the visible results. Left and Right move
  the search itself one column, described below. `h` and `l` are printable, so
  they type into the query; only the arrows move the search, which is what keeps
  the searched and the selected column from ever disagreeing.
- Enter opens the selected result's details and ends search, keeping that item
  selected on the restored column.
- `s` or `Esc` clears the query, removes the box, and restores the complete
  column, keeping the previously selected result selected by item identity
  rather than by row number.

A card matches when the case-folded query occurs as a substring of the
case-folded `#number` and title shown on the card, with runs of whitespace
normalized. Bodies, labels, assignees, branches, and status text never
contribute. An epic's header is kept when its own identity matches or any of its
children match, and only matching children are shown beneath it — a matching
child renders even under a collapsed epic, and an epic that matches alone shows
its header without leaking a child that does not. Search never writes to the
saved expanded-tracker set, so closing it restores the column's collapsed and
expanded view exactly.

An empty query shows the column complete beneath the empty box. A non-empty
query with no matches shows a `No matches` row, distinct from the `No items` row
an empty column shows. While a non-empty query is live the column heading shows
the visible result count over the column's full total. Both counts are exact: a
board is only ever drawn from a generation that followed both open connections
to their end, so no heading total stands for more than it says.

Every edit, close, and successful refresh re-seats the searched column by the
identity of the row that was selected. A row drawing an ordinary card is kept by
that card's item; a row drawing an epic's header is kept by that epic's issue
number, and resolves back to its group's first row. That covers a populated
epic too: a populated header is synthesized from child rows, so while the group
is collapsed the selected row is its first child even though what is shown and
acted on is the epic. The anchor is kept only while it is still selectable in
the resulting view — an anchor that is gone, and a card the restored column has
collapsed back under its epic, take the first selectable visible entry instead,
and a view with nothing in it leaves nothing selected.

Every insertion and deletion refilters immediately: no GitHub request, no cache
write, and no change to board freshness. Rendering, keyboard selection, mouse
target resolution, card actions, and boundary movement all read the same visible
entries, so a row the user can see or select never dispatches to a different
underlying card. Clicks inside the searched column keep their ordinary meaning
on the cards and epic headers actually displayed, and one that opens details or
a live session ends search the way Enter does.

A search moves to another column by a click or an arrow key, and both reach one
transition, so the state is the same however it was reached. A left or right
click aimed at any column but the searched one moves the search there, and does
nothing else: it does not open details, toggle an epic's expansion, open a live
session's overlay, or change that column's selected row, and the rule is
identical for a card, an epic's header, and the column's whitespace — reaching a
specific card there takes a second click. Left and Right move the search one
column, clamped rather than wrapped like the ordinary board's column movement,
so a press at the leftmost or rightmost column changes nothing at all: the query
survives, the selection survives, and no notice is raised. The wheel never
moves a search — over any column, searched or not, it scrolls that column and
does nothing else — and the middle button keeps its existing no-op. The drainer
button is not a column target at all: a left click on it starts or stops the
drainer exactly as it does with no search open, moving neither the search nor
the query.

A move empties the query and draws the box at the top of the new target, which
therefore shows all of its entries, and both headings return to the ordinary
count form. The column being left is re-seated by the identity of the result
that was selected in it, so restoring it complete cannot leave a row number
selecting a different card; the column being entered keeps exactly the row it
remembered. Closing a moved search restores that column complete, exactly as
closing an unmoved one does.

A successful refresh re-runs the query against the new board and keeps a
still-matching selected item selected, falling back to the first visible result
otherwise; a failed refresh leaves the board and the query untouched. Search
state is presentation state only: never cached, never part of a board snapshot,
and never restored on restart.

### Embedded issue reviews

Pressing `r` on an issue or from its open details starts its label-selected
review stage, or reopens the issue's existing session. Canonical review and
rereview use the synchronous v2 reviewer; interactive revision uses one
persistent Codex app-server. Pressing `r` on an epic header is a no-op that
sets a notice instead: an epic is structure rather than reviewable work, so
neither a collapsed tracker nor a childless header — from the board or from
that header's own details overlay — starts a session, opens the review
overlay, or acquires a review badge. A collapsed tracker's notice names `e`,
because expanding it is what makes its reviewable children selectable. `S`,
`A`, and `x` still resolve both header shapes to the epic issue. On a PR,
`r` is the unified
review/revise/repair key: it starts review, revision, or rereview according to
the durable review labels, except on a card that is both in Done and reporting
a problem status, which starts a repair instead. App-server starts on demand and one process hosts all
interactive revision threads for the running dashboard; PR actions use resumable
canonical-model CLI sessions because their permissions include PR comments,
labels, worktree edits, commits, and pushes.

PR routing mirrors issue routing while keeping implementation and review
separate:

1. With no workflow label, the opposite brand runs `pr-review`.
2. `reviewed:changes` switches to the PR-origin solver brand, which runs the
   canonical `pr-revise` workflow: it acts only on a current canonical
   CHANGES_REQUESTED verdict for the PR head (rerouting stale feedback through
   canonical rereview instead of editing), works in a clean isolated
   worktree, verifies the remote head before pushing, waits for required CI,
   and invokes exactly one canonical `pr-rereview`. Kanban never manually
   adds, removes, or synthesizes `reviewed:approve`, `reviewed:changes`, or
   `reviewed:revised`; the canonical rereview publishes the fresh verdict
   directly, so Kanban never waits on a Kanban-created `reviewed:revised`
   handoff.
3. A PR still carrying a legacy `reviewed:revised` label (from before this
   unification) routes to the opposite brand for `pr-rereview` only, without
   editing the PR again, and removes the stale label once it publishes.
4. A card that is in the Done column *and* whose §9 status is a problem —
   a merge conflict, a failed check, or a blocking label while
   `blocking_severity` is red — overrides all three above and runs the
   packaged `repair` workflow. Both halves of that condition are required:
   `pullRequestStatus` reports the same problems for a draft or unapproved PR,
   and those stay in Reviewing under the routing above; a Done PR with no
   problem status keeps whatever its labels derive, which includes revision.
   Like `pr-revise`, repair works on the PR's own code, so it runs on the PR's
   own origin brand and ends by invoking exactly one canonical rereview on the
   opposite brand rather than reviewing itself. Repair never merges and never
   removes a blocking label: it ends by triggering that rereview, and merging
   stays a separate, explicit action.

This fourth meaning belongs to the user's own `r` alone. Autosolve drives its
pull request through the same session machinery internally, and keeps its
label-derived review/revise progression so a problem status cannot divert a
running loop into a repair.

Codex-origin PRs use Opus 5 xhigh for review and GPT-5.4 high for revision and
repair; Claude-origin PRs use GPT-5.6-Terra xhigh for review and Sonnet 5 xhigh
for revision and repair. A missing or contradictory `pr-origin` marker fails
visibly rather than guessing.

The review is a direct, explicit workflow and never starts an approval daemon.
Initial review and rereview synchronously invoke the vendored
`tools/approve_issues.py` backend (installed with
`tools/install_issue_review.py`; see
[the agent-workflow contract](agent-workflow-contract.md)) as the canonical
`issue-review:v2` fingerprint publisher so the existing solve gate accepts
Kanban-reviewed issues. Kanban does not reconstruct where that backend was
installed: it reads the absolute path out of the record the installer writes
at `~/Library/Application Support/kanban/issue-review/config.json`, whose own
location `--install-dir` cannot move, so an installation made anywhere is
found by a dashboard launched with no special environment. A non-empty
`KANBAN_ISSUE_REVIEW_INSTALL_DIR` still wins, and a record carrying no
recorded path — an installation predating the record — falls back to the
directory holding it. Each way that lookup can fail — an override or recorded
backend that is not there, a record that will not parse, a recorded path that
is not absolute — is reported as its own diagnostic naming the document
consulted and the repair for that case, never as the bare installer command
the user may already have run. Preflight, both packaged PR coordinators, and
the packaged issue-review and solve workflows resolve identically. Interactive revision remains inside Kanban.
Each `r` invocation advances exactly one durable label-driven stage:

1. With neither workflow label, the opposite brand performs the initial review.
   Claude-origin issues route to GPT-5.6-Sol xhigh, Codex-origin issues route
   to Claude Opus 5 xhigh, and unmarked issues require both. GPT-5.6-Terra and
   Claude Fable 5 remain accepted legacy models (`tools/approve_issues.py`) so
   historical review markers keep validating after either default changes.
2. `reviewed:changes` switches back to the author brand for revision:
   GPT-5.4 high for Codex-origin issues and Claude Sonnet 5 high for
   Claude-origin issues. Unmarked issues default to GPT-5.4 high. The
   agent writes one canonical specification
   amendment as an issue comment, then replaces `reviewed:changes` with
   `reviewed:revised` without approving.
3. `reviewed:revised` routes back to the same opposite-brand reviewer set. A
   passing rereview replaces it with `reviewed:approve`; a failing rereview
   returns to `reviewed:changes` for another cycle.

Revision agents resolve mechanical or repository-verifiable omissions directly.
Any product, compatibility, scope, policy, migration, or user-visible decision
with multiple reasonable answers must pause for a structured user question.
Required agents are never silently substituted. No stage edits the checkout,
the issue body, or implements the issue.

Kanban registers a client-side `kanban_prompt_user` dynamic tool on every
thread. Developer instructions require every user-facing question to call this
tool rather than place a question in prose. Choice and free-text requests pause
only their owning turn. Kanban renders the request, returns the selected answer
as the tool result, and lets other sessions and the board remain usable.
Command and file-change approval requests use the same waiting-state UI.

Kanban also registers `kanban_run_claude`. Sonnet-authored revision stages use
this tool instead of launching `claude` through a Codex command: the latter runs
inside Codex's sandbox and cannot reliably reach the macOS keychain-backed
Claude login. The client tool starts the official CLI directly from Kanban with
`--model claude-sonnet-5 --effort high --permission-mode plan --safe-mode`,
streams a standalone prompt over stdin, and returns its output to the coordinator. It has
a ten-minute deadline, terminates its process group on timeout, and cannot edit
the checkout or mutate GitHub directly.

The third client tool, `kanban_github_issue`, owns authenticated issue I/O.
Codex is forbidden from invoking `gh`, `curl`, or GitHub APIs through the generic
command path. The tool can read one issue and its comments, post one issue
comment, and add/remove only `reviewed:approve`, `reviewed:changes`, and
`reviewed:revised`; every other mutation is rejected before `gh` runs. The
review overlay reports when the bounded operation starts and whether it returns
successfully, so normal review transitions never present a generic command
approval prompt.

Review overlays contain a bounded, mouse-wheel-scrollable transcript, one-line
input, structured questions, command approvals, and tabs for all in-memory
sessions. `Esc` or an outside click hides the overlay without interrupting work;
selecting the issue
and pressing `r` reopens it. `Tab` switches sessions, Enter sends feedback or a
follow-up turn, and Ctrl-C interrupts the active turn. Only running turns chain
short spinner ticks; completed, hidden, and idle sessions schedule no redraws.
Quitting terminates the owned app-server process.

Solve, PR, and review overlays are three presentations of one session record.
Everything not specific to the kind of agent behind them — status derivation,
transcript growth and its follow state, the input line and its bound, the
animation tick chain, and the base key table — has a single implementation;
only what a phase is called and looks like, what submitting or interrupting
does, and when a spinner is worth running differ. Consequently all three carry
the tab strip over their own in-memory sessions and answer `Tab`, which moves
to the next session by ascending number with wraparound, preserving each
session's draft and scroll position, and does nothing at all when that kind
holds a single session.

Every kind's animation ticks carry a generation. Repeated triggers for one
running turn coalesce onto the chain already in flight rather than starting a
second, a tick from a superseded chain is dropped rather than rearming, a
session replacing an earlier one for the same number cannot collide with a tick
that one queued, and a chain expires and unarms as soon as its session stops
being worth animating. Which sessions those are is the one condition that
differs: a review spinner runs only while the review overlay is on screen,
since its ticks are the only thing driving review redraws, while solve and PR
spinners also drive the board's own card badges and activity timers and so keep
running with no overlay open.

Feedback sent into a running turn is steered into it against the turn it was
aimed at, so the app-server rejects it when that turn has moved on. A rejection
never discards the message. With the thread now idle it becomes the follow-up
turn the same keypress would have started a moment later — one request, and no
second transcript entry. While any turn is running it is reported undelivered
rather than redirected into a turn the user never addressed: the transcript
entry is marked as not delivered, and the text returns to the input line, or
waits in the session behind whatever is already there. A draft typed after the
send and a second rejected message are both preserved; sending frees the line
and brings the oldest waiting message back.

Review, solve, and PR transcripts follow the live tail only while they are
already at the bottom. Scrolling up during a turn holds the view where it is,
however much output arrives; scrolling back down to the bottom resumes tailing,
as does making the session visible again or starting a new turn. Output only
ever moves the viewport for the session actually on screen, so a hidden overlay
or a background review tab never disturbs what is being read.

## 8. Board state model

The four columns are derived from current GitHub state. Issues carrying a
configured tracker label are never classified as work cards, however many
children their checklist yielded; they appear only as tracker group headers
(section 12), which follow their children's columns or, having none, sit in
Issues.

Which cards reach a column at all is decided first by the filter criteria. They
are four independent facets — state, kind, workflow, and structure — whose
values are ORed inside a facet and ANDed across facets, so an empty facet is a
valid empty result rather than an implicit reset. Every value starts checked
except `Closed`, so the ordinary view is the complete live open board and the
column rules below read exactly as they always have. Criteria are
process-lifetime presentation state: they survive every refresh, overlay and
dismissal, initialize to their defaults at every start, and are never written
to the cache, the settings file, or the configuration.

Lifecycle outranks every other classification rule. A completed item — a closed
issue, or a pull request that merged or was closed unmerged — is settled
history, and the assignees, draft flag, and approval state it carried while it
was worked say nothing about where it belongs now.

### Issues

Open, unassigned issues. A linked pull request does not suppress the issue
card; the issue and PR represent different workflow objects.

Closed issues also appear here when the criteria admit them, regardless of the
assignees they were worked under, each carrying a `CLOSED` badge.

### Active

Open issues with at least one GitHub assignee. Any assignee counts as active;
there is no agent-name allowlist. The issue remains Active after its PR is
created, while the PR appears independently in Reviewing or Done.

### Reviewing

Open pull requests that do not satisfy the approval predicate, including draft
pull requests. A draft has already crossed the issue-to-PR boundary, so it
belongs in Reviewing rather than Active and carries a prominent `DRAFT` badge.
Drafts remain in Reviewing even if an approval label is applied accidentally.
Canonical review approval is not an accidental label application: its
publisher marks the PR ready for review as part of the guarded approval
transaction. A successful approval therefore enters Done immediately even
while CI is pending; changes requested never changes draft state. The PR
drainer retains the same transition as a fallback for approvals published by
older or external tooling.

### Done

Open, non-draft pull requests satisfying the approval predicate, and — when the
criteria admit them — every completed pull request, carrying a `MERGED` badge
when it landed and a `CLOSED` badge when it did not. A completed pull request
reaches Done whatever approval predicate it did or did not satisfy and whether
or not it was a draft, and never appears in Reviewing: it is not under review.

With `Closed` unchecked, which is the default, Done holds only the
ready-to-finalize queue and a card leaves it as soon as its pull request merges
or closes. With `Closed` checked, Done is additionally the history of every
pull request the repository has finished.

The approval predicate is configurable: the approval label (default
`reviewed:approve`), GitHub's native `reviewDecision == APPROVED`, or either.
The default is label-only, matching label-driven review workflows.

### Completed cards are read-only

Every mutating action refuses a completed card with a read-only-history notice
and launches nothing: review, solve, autosolve, rereview, merge, direct merge,
and killing a working process. The refusal outranks the wrong-kind, approval,
drainer-state, structural, reusable-session, and process-presence errors those
actions would otherwise report, and is re-checked at each action's own launch
or termination boundary, so a chooser, details overlay, or session opened
before a refresh cannot act after the item completes. Details and the item URL
remain readable.

Every route reaching those actions is covered, not only the board's own keys:
a session overlay's Enter, numbered choice and Ctrl-C, and every row of the
processes overlay — which is keyed by session rather than by card, and resolves
a persistent worker's subject through the task it was created for. Termination
is refused on the same terms as launch. An agent still running against work
that settled underneath it is therefore stopped the way any other stray agent
process is, rather than through a card that is now history.

Live workflow behavior never observes completed data at all. The autosolve
baseline and worker and session item resolution read the open generation
whatever the criteria say, so checking `Closed` changes nothing about any of
them.

Explicit GitHub closing-issue relationships connect issue and PR cards for
tracker inheritance, but never collapse the two cards into one. Title and
branch-name guessing are not used.

## 9. Pull-request readiness and outline colors

Done cards enter the column with a yellow outline. They become green only when
the current head is cleanly mergeable with the current base and CI has
succeeded.

Priority from strongest to weakest:

1. Red: merge conflict.
2. Red: failed, timed-out, cancelled, action-required, or startup-failed CI.
3. Red or amber: explicit blocking state such as `reviewed:changes`; exact
   severity is configurable, with red as the default.
4. Yellow: approval exists but checks are pending, queued, or in progress.
5. Yellow: approval exists but the branch is behind, non-mergeably blocked, or
   GitHub is still calculating mergeability.
6. Green: approval exists, the PR is cleanly mergeable/current (including a
   `MERGEABLE` head reported `BLOCKED` only by repository policy and handled by
   the configured admin drainer), and the latest unique checks are successful.
7. Green: approval exists and the PR is cleanly mergeable/current when the
   repository has no checks configured.

The implementation uses GitHub's `mergeable`, `mergeStateStatus`, and
`statusCheckRollup` fields. A `CONFLICTING` mergeability result is always red.
`MERGEABLE` plus `BLOCKED` is rendered `protected`, distinguishing an
admin-drainer-ready policy block from a conflict. An `UNKNOWN` result remains
yellow until a later user-requested refresh; the application does not poll for
GitHub's background mergeability calculation.

An open PR without a linked issue remains in Reviewing or Done but receives an
amber `UNLINKED` warning.

## 10. Visual language

### Borders

- The optional `--border open` renderer avoids long vertical glyph runs. It uses
  whitespace gutters between columns and horizontal header/footer rules, so
  terminal font ascent/descent metrics cannot turn the main structure into a
  dashed vertical line.
- The default `--border box` renderer uses a double-line application shell
  (`╔═╗║╚╝`) and a heavy
  connected board frame (`┏━┳━┓┃┗━┻━┛`) when the selected font renders box
  drawing continuously.
- Cards: rounded, `╭─╮│╰─╯`.
- Tracker headers: heavy accent, for example `┏━┓┃┗━┛` or a compact `◆` row.
- A nested sidebar control such as the drainer button draws with its panel's
  inner-border style: heavy Unicode (`┏━┓┃┗━┛`) in the default and open-border
  renderers, ASCII (`+-|`) under `--ascii`. Such a control draws its own box
  rather than wrapping its label in a border widget, so every glyph keeps the
  control's status color.
- Avoid emoji and ambiguous-width decorative characters. Prefer stable
  single-cell symbols such as `✓`, `×`, `!`, `●`, `◐`, and `◆`.

### Selection and status together

An unselected card uses its status color for the full border. A selected card
uses:

- Cyan for its left edge, top edge, bottom edge, title, and selection gutter.
- The original yellow, green, red, or neutral status color for the right edge
  and right-side corners.
- A bright cyan `▌` gutter marker.

This makes selection unmistakable without erasing workflow state.

### Color support

- `auto` uses truecolor when the terminal advertises it and otherwise uses a
  256-color palette.
- GitHub label hex colors are used directly in truecolor mode.
- Label colors are quantized to the nearest xterm color in 256-color mode.
- Label text is black or white based on calculated background luminance.
- Status always includes a glyph and text so color is supplementary rather
  than the only signal.
- `--color never` and `--ascii` remain usable fallbacks.

### Approved issue treatment

An issue carrying the configured approval label is visually distinct from an
ordinary card: its entire interior receives a subdued approval-color
background, its text uses a calculated high-contrast foreground, and its
border uses the approval color unless a stronger problem state overrides it.
This whole-card treatment is in addition to the ordinary colored approval
label chip. In 256-color mode, use the nearest readable dark or light palette
variant rather than an unreadably saturated background. In no-color mode,
prefix the title with `APPROVED` so the state remains explicit.

Selection still follows the split-border rule above: cyan identifies the
selected edges and gutter, the right edge retains the card's status color, and
the approved background remains visible. A red problem state overrides the
approval border but not the approval label or background, allowing an approved
issue with a newly discovered problem to communicate both facts.

## 11. Rich cards

### Issue card

```text
  ╭─ #812  Modal input leaks through overlay ─────────╮
▌ │ approved  bug  ui                                │
  │ Empty modal areas currently allow pointer events │
  │ to reach lower pages. This is visible when…      │
  │ @agent-name · updated 2h ago                     │
  ╰──────────────────────────────────────────────────╯
```

Fields:

- Issue number and title.
- Colored label chips, with status labels ordered first and remaining labels
  alphabetically.
- Up to two label rows; overflow is summarized as `+N`.
- Up to three wrapped excerpt lines.
- Assignees, when present.
- Relative updated time, recomputed on every redraw rather than stored as
  fixed text. Redraws happen only on input, resize, or worker results, so no
  timer is needed to keep it honest.
- Tracker sequence key when the issue is a tracker child.
- A `CLOSED` lifecycle badge when the issue is completed, leading the metadata
  row. It is not part of the heading, which is the identity card search matches
  against, so a completed card is still found by the same `#number title` text
  it always was.

### Pull-request card

```text
  ╭─ PR #823  Fix modal scroll routing ──────────────╮
  │ reviewed:approve  input  ui                      │
  │ #812 · agent-name → master                       │
  │ ✓ CI 14/14 · clean · ready to merge              │
  │ Routes Shift-wheel through the same modal-aware… │
  ╰──────────────────────────────────────────────────╯
```

Fields:

- PR number and title.
- Colored label chips.
- Linked issue numbers; show the first two followed by `+N`.
- Author and base branch.
- Mergeability and aggregate CI summary.
- Up to three wrapped excerpt lines.
- A `MERGED` or `CLOSED` lifecycle badge when the pull request is completed,
  leading the metadata row on the same terms as the issue card's. The two are
  kept apart because they are different outcomes: one landed the work and one
  abandoned it.

### Label chip color

Card and details chips share one rule, applied in this order: the configured
approval label, the reserved `reviewed:revised` label, the configured
changes-requested and blocked labels, the configured problem-styled names, the
configured UI-styled names, then the ordinary default. Every comparison is
case-insensitive. The protocol names come first so no styling configuration
can disguise a workflow state, and problem styling precedes UI styling so a
name listed in both resolves the same way every time.

The last two collections are presentational only — nothing reads them for
status, readiness, or ordering — and both default to empty. No repository's
own label vocabulary is built in: a repository that wants its defect or UI
labels tinted says so in `config.toml`, and one that says nothing gets
ordinary chips rather than an invisible built-in set of names.

### Excerpts

Use GitHub's plain-text body representation where available. Select the first
meaningful non-empty paragraph, collapse whitespace, wrap to card width, show
at most three display lines, and append `…` when truncated. This is more stable
than trying to count natural-language sentences in issue templates, lists, and
code-heavy bodies.

### Card height and truncation

Every element above gets its own budget, measured in terminal display cells at
the card's current inner width, so no element can quietly consume another's
room:

- The title wraps to at most two lines and takes a `…` when truncated, leaving
  the excerpt its three lines however long the title is.
- Label chips are placed whole or not at all. When labels remain after two
  rows — or GitHub reported omitted labels — a whole `+N` chip is always
  placed, evicting a trailing chip if that is the only way to fit it. `N`
  counts both the labels GitHub omitted and the ones that had no room.
- Metadata, tracker context, tracker diagnostics, and pull-request status wrap
  rather than truncate; they are always visible.

The card's height is then the number of rows those budgets produced, so cards
in a column vary in height and no interior row is ever cropped. A resize
re-lays out every card from the new width on the next redraw, with no refresh.

### External text sanitization

Titles, label names, and bodies arrive from GitHub and may contain emoji,
combining marks, zero-width joiners, control characters, tabs, carriage
returns, bidirectional overrides, and raw ANSI escape sequences inside code
blocks. Any of these can corrupt card borders or column alignment if handled
as untrusted terminal output.

All external text passes through a sanitization step before layout:

1. Strip ANSI/OSC escape sequences before the text reaches Vty.
2. Normalize tabs and line-ending controls into ordinary spaces or preserved
   logical line breaks as appropriate.
3. Strip remaining C0/C1 controls and explicit bidirectional override/isolate
   controls.
4. Normalize Unicode text to NFC.
5. Preserve ordinary combining marks; do not remove characters merely because
   their individual terminal width is zero.
6. Wrap and clip using Vty's text-width functions and its active terminal
   Unicode width table. The application does not claim terminal-independent
   grapheme-cluster width, which terminal emulators do not provide reliably.

Application chrome deliberately avoids emoji and ambiguous-width decoration,
but sanitized user-authored emoji may be displayed using Vty's measured width.

### Details overlay

`Enter` opens a scrollable overlay containing:

- Full plain-text body.
- All labels, assignees, and author information.
- Tracker membership and implementation key.
- All linked issues or pull requests.
- Base and head branches.
- Mergeability and merge-state explanation.
- Individual pending and failed checks.
- Creation and update timestamps.
- GitHub URL.

The overlay presents this content without editing any of it. The board actions
that act on the selected card — `r`, `S`, `A`, `x`, and `m` — dispatch from it
as well, against the item it is showing.

### Incidents panel

`i` opens a panel answering one question — what needs me? — from every source
that can raise it, and takes the user to the work. `Esc` closes it. It is
scrollable, keyboard-navigable, and mouse-selectable in the style of the
processes overlay, and it is read-only: opening or activating an entry never
resolves, dismisses, acknowledges, retries, or otherwise mutates an incident,
a session, or GitHub state.

Two sources contribute initially, and the list is written against a set of
sources rather than against those two, so a later one is added by contributing
rows and a label:

- every repository-scoped open incident the PR drainer reports;
- Kanban's own live agent sessions in the phases that need a human. Those are
  exactly `SolveAttention`, `SolveFailedPhase`, `SolveKilledPhase`, and
  `SolveOrphanedPhase` for solve and pull-request sessions, and `ReviewWaiting`,
  `ReviewNeedsChanges`, and `ReviewFailed` for review sessions. Every other
  phase is excluded, including the active and completed ones,
  `ReviewRevised`, and `ReviewInterrupted`. These lists are the contract:
  they are not derived from the narrower sets `reviewPhaseActive` and
  `agentSessionProblem` express, which answer different questions.

Source availability is represented separately from an empty result, so
"nothing needs attention" is never said out of this side's ignorance:

- Only a successful drainer observation reporting no open incidents is a
  verified-empty source.
- The initial checking state, a controller discovery failure, a query or
  decode failure, and a start or stop in flight all leave the source
  unanswered. The panel then says it is being checked or is unavailable, and
  the overall empty state is withheld.
- Session rows stay visible whichever of those the drainer source is in.
- The overall empty state appears only when the drainer has successfully
  reported no incidents and no session qualifies.

The controller's status response therefore reports the complete
repository-scoped set of open incidents alongside the existing newest-only
`open_incident` projection, which the sidebar keeps using unchanged. A
response carrying no set at all is an unanswered source, not an empty one.

Each row states what it concerns — the issue or pull-request number, with its
title where the board knows it — what happened, and which source it came
from. Every title, summary, activity, source label, and recorded failure
passes through the external-text sanitization contract above before it is
rendered or reported.

A drainer row states what happened from the fields its kind is defined to
carry, and from those only:

- a supervisor crash adds the last activity it recorded and the last pull
  request its log mentioned, marked as diagnostic rather than a navigation
  target;
- a post-merge cleanup incident adds the failure the drainer recorded on the
  pass that last kept the cleanup from finishing — the blocker, and the action
  that clears it wherever the recorded refusal names one — so the panel says
  why the step is stuck and not only which step it is. The text comes from the
  incident document the status response already carries, at no extra
  controller invocation or polling cost.

A recorded failure is stated on its own continuation lines beneath the row,
not on the row itself. A cleanup summary already fills the panel's width
alone, so on the row this text would be elided away before its first word,
and a blocker and a remedy the operator can never read are not stated at all.
The continuation is sanitized, collapsed to one logical line, then wrapped to
the width the panel has, indented and marked so it reads as belonging to the
row above. It is part of that row's clickable region, so clicking it selects
the incident it belongs to, and selection and activation still resolve by
incident identity rather than by any line count.

It is bounded in height as well as width — the panel's rows are shared, so a
runaway failure cannot push other incidents out of the panel. What a bound
gives up is the *middle*, never the tail: the recorded value opens by
restating the failing step around the checkout's absolute path and closes
with the blocker, the remedy, and the paths to act on, so trimming the end
would discard exactly what the operator needs and would do so more surely the
deeper the checkout. Both ends are kept and the gap between them carries a
visible ellipsis. A
recorded failure that is absent, empty, whitespace-only, or emptied by
sanitization adds nothing — no line, no separator, no placeholder — and a row
of any other kind is unchanged whatever its document carries.

The panel is a fixed-width overlay, so a row is measured against the width
that overlay gives it rather than the terminal's. A row longer than the panel
is elided with a visible ellipsis at that measured width, never cropped
silently: §11's promise that an ellipsis appears wherever text was dropped
holds for a row whatever made it long — a recorded failure, a long title, or a
summary that already overran the panel on its own.

The one notification the drainer publishes when it opens a cleanup incident
carries that same recorded failure, and says the incident clears once any
operator action the failure calls for is done and every outstanding step
succeeds. Later passes refresh the open incident's recorded failure in place
without publishing a second notification.

Rows carry stable source-qualified identities: the service-provided incident
ID for a drainer row, the existing agent session reference for a session row.
Selection and activation resolve those identities against the current list, so
a refresh that inserts, removes, or reorders rows cannot redirect a keyboard
or mouse action to a different incident. A row whose identity disappears
before activation activates nothing: the highlight may clamp onto a neighbour
so the panel stays usable, but that neighbour is never acted on in its place.

Activating a row closes the panel and:

- selects its connected board work when the entry names authoritative issue or
  pull-request work present on the current board;
- additionally opens that work's session overlay when Kanban holds a session
  for it;
- when the numbered work is absent from the board — closed since, or never on
  it — leaves the current column, row, and tracker expansion unchanged, reports
  that the work is not on the board, and still opens the referenced session
  overlay if there is one.

Number-based selection recognizes every shape the board holds work in:
ordinary issue and pull-request entries; a childless tracker, whose header
entry is its issue; a tracker represented by grouped children, which has no
card of its own and is targeted through its group's header row; and a child
beneath a collapsed tracker, which is selected with its tracker expanded so
the selected work is visible.

A supervisor-crash incident is cardless: it carries no authoritative
`pull_request` field. Its `last_pr` is inferred from a log line and is
diagnostic only, never a navigation target. Activating one reports its
summary and leaves board selection and tracker expansion unchanged. Its row
is rendered from the diagnostic fields the service really records — which are
not just an exit code and a command, but also the last activity, log
metadata, and that non-navigable `last_pr` — so a cardless row still says
enough to act on.

## 12. Epic and tracker grouping

Tracker grouping is a first-class board feature rather than a visual heuristic
based only on child titles.

### Tracker detection

Defaults:

- An issue carrying the `epic` label is a tracker, whether it is open or
  closed. A completed tracker is still a tracker: it keeps its group header,
  carries the `CLOSED` badge on that header line — between the title and the
  progress count, whether the group is populated or empty — and groups its
  children. A header is built from the tracker rather than from a card, so it
  never passes through the card metadata row the badge otherwise leads.
- Additional configurable tracker labels may be added, such as `tracker`.
- A title beginning with `Epic:` or `[epic]` is a fallback hint when the issue
  has no labels; an explicitly labelled issue uses labels as the source of
  truth.

### Membership and order

The tracker's ordered phase/children checklists are authoritative. Recognized
forms include the current repository's conventions:

```text
- [ ] #756 — **A1:** Define the persistence contract.
- [ ] #742 — A1: Modal ownership with debug pass-through
- [x] **#88 — Data-driven location definitions**
```

Parsing rules:

1. Consider issue references in checklist items under headings such as
   `Children`, `Phase`, `Phase plan`, or equivalent configured headings.
2. Do not infer membership from references in `Related`, prose, dependency
   diagrams, or acceptance text.
3. Capture an explicit implementation key such as `A1`, `A2`, `B1`, `C3`, or
   `D1` when present. A key is read only from its position in the forms above:
   immediately after the leading `#N` reference and its separator (`-`, `–`, or
   `—`), or ahead of that reference at the start of the item. In both positions
   it may be wrapped in `*` or `_` emphasis and must be closed by `:`. A
   key-shaped word anywhere else in the title, such as `S3` or `V2`, leaves the
   child keyless.
4. Preserve checklist order as the ultimate fallback.
5. Order explicit keys naturally by letter and number: `A1`, `A2`, `A10`,
   `B1`, `C1`, `C2`.
6. A checklist child appears on the board only when the current filter criteria
   admit it. Under the default criteria that is exactly the currently open
   issues and PRs; with `Closed` checked, completed children join their group
   too. A child the criteria leave off the board cannot be rendered or acted
   on, so it is dropped from the tracker's children and folded into checklist
   progress rather than staying a permanently unreachable pending entry.
7. A child whose own tracker the criteria hide falls back to a standalone
   card, which is exactly what the board renders for a child whose epic is not
   on it, and takes its place behind every group in that column. A tracker the
   criteria keep with none of its children left collapses to a header, so the
   epic is still represented rather than vanishing behind its filtered-out
   group.
8. Both of those, and the progress a header reports, are decided over the whole
   board rather than one column at a time. A group's membership is not confined
   to a single column — an epic can hold an unassigned child in Issues, an
   assigned one in Active, and their pull requests in Reviewing and Done — so a
   child still drawn in one column is never folded into another column's
   progress, and a group that lost its rows in one column but kept them
   elsewhere draws no header there. A group that lost every row board-wide
   draws exactly one header, in the leftmost column its rows appeared in.

Membership resolution is structured as ordered sources feeding one internal
model. The checklist parser above is the first source, and GitHub's native
sub-issue relationships are the second, so a repository using first-class
sub-issues works without checklist conventions.

Precedence between them:

- A tracker whose body parses to at least one valid checklist child keeps the
  checklist authoritative for membership, ordering, implementation keys, and
  progress. That test is made on what the body parsed to, before children that
  are not on the live board are pruned, so a checklist whose every child has
  closed does not silently become a native tracker.
- A tracker with no valid checklist child falls back to the native
  relationships GitHub reported for it.
- A tracker with neither keeps the empty-header diagnostics below. "Neither"
  means GitHub positively reported no sub-issue relationships — a complete
  answer of nothing, both the relationship list and the summary. An answer
  that was absent, null, or incomplete is an unverified absence and follows
  §13's incomplete-item contract instead.

The relationship list and the summary are separate fields, and a
partial-error response nulls exactly the ones that errored, so either can
arrive without the other. Whichever half arrived is kept and used: children
delivered without their summary still group under their tracker rather than
scattering across the board, and a summary delivered without its children
still reports the tracker's progress. The item is marked incomplete for the
rest.

Native membership covers the tracker's immediate children only, up to
GitHub's own limit of 100 per parent, and it never invents an implementation
key from a child's title. A native child is therefore keyless, and its
position in the order GitHub returned becomes the checklist-order fallback the
sort uses — so it renders the same positional `step N` label a keyless
checklist child already gets. Ordering stays subordinate to the
`reviewed:revised` attention tier below.

A sub-issue GitHub reports under another repository is never treated as this
repository's issue of the same number: it contributes to progress through
GitHub's summary and nothing else, and creates no card and no membership. The
comparison uses GitHub's own identity for the queried repository as returned
in the same response, so a repository reached through a rename redirect still
recognizes its own children. A refresh that could not establish that identity
treats the relationships as unreported rather than guessing.

Native membership requires a GitHub deployment whose GraphQL schema exposes
the sub-issue fields. One that does not rejects the query outright, so the
refresh drops the selection, carries on with checklist-only membership, and
says so once in the §17 banner rather than failing every refresh.

### Presentation across columns

Tracker issues are structural group headers rather than ordinary work cards.
Each column containing visible members renders a compact tracker header and
indents that column's children beneath it:

```text
◆ #768  Rebuild save/load                      8/11 complete
  ├─ A1  #756  Define the persistence contract
  ├─ A2  #757  Add a coordinated snapshot barrier
  └─ B1  #759  Introduce the v83 save envelope
```

Epic headers use a purple accent and start collapsed. A collapsed header is a
keyboard focus target; `e` or a left click on its title expands or collapses
that epic everywhere it appears across the board. Child cards rejoin the
ordinary `j`/`k` focus order only while their epic is expanded.

Tracker progress under checklist membership is derived from checklist marks in
the authoritative tracker body: checked entries divided by total recognized
child entries. It is labeled `complete`, not `closed` or `open`, because a
checklist mark is tracker state and may briefly lag the linked issue's GitHub
state. A checklist child that is not on the live board can never be rendered
or interacted with, so it is dropped from the tracker's children and counted
as complete rather than pending forever. The details overlay warns when a
visible open child is checked complete; otherwise the board does not add
network requests solely to reconcile progress text.

Tracker progress under native membership is GitHub's own completed and total
sub-issue counts, used as reported. GitHub already counts every sub-issue the
tracker has, including the closed ones and any in another repository, so those
are never counted again locally and the off-board completion adjustment above
does not apply. Children that cannot be rendered are still dropped from the
tracker's children, so a closed or cross-repository child contributes to the
counts without becoming a card. When GitHub delivered the relationships but
not the summary, progress falls back to counting the relationships that did
arrive, so the header never reads `0/0 complete` above visible children; that
item is marked incomplete and named in the §17 banner, which is what keeps the
derived pair from being mistaken for GitHub's own.

The same tracker header may appear in more than one column when its children
are split across Issues, Active, Reviewing, and Done. This repetition provides
context; it does not duplicate or change the underlying work item. An open
tracker with no children on the live board remains visible as an empty header,
as does a labeled or legacy-title tracker with no recognized child list, which
carries its tracker diagnostic in amber. Such a header has no children whose
column it could follow, and it is structure rather than work in progress, so
it always appears in Issues even when the tracker issue is assigned.

An empty header is the one collapsed header that opens a details overlay:
having no children to expand to, `Enter` on it opens its own tracker issue's
details, including the tracker warnings explaining why the child list is
empty. `Enter` on a collapsed header that does have children still asks for
`e` first.

A tracker whose membership is native is not warned for having no `Children` or
`Phase` checklist, at any of those surfaces — not in the refresh banner's
malformed-tracker count, not in the card's inline diagnostic rows, not in the
details overlay, and not in the amber styling that decides a card's border.
Diagnostics reporting malformed checklist content — a broken checkbox, an item
with no issue reference, a duplicated child — remain visible, because they
describe something genuinely wrong in the body rather than the absence of a
list. When native membership contributes no visible card at all, because every
child is closed or belongs to another repository, the header shows GitHub's
own progress counts and no diagnostic: nothing about the tracker is wrong, and
the counts are the explanation.

A PR inherits tracker membership from its explicitly linked child issues. If a
PR links children from more than one tracker, it receives an amber
`MULTI-TRACKED` warning, appears under the tracker containing the earliest
implementation key, and lists every tracker in its details overlay. Ties are
resolved deterministically by the tuple `(implementation key, tracker issue
number, linked child issue number)`, each in ascending natural order.

Untracked issues and PRs appear under a compact `Standalone` section. An
unlinked PR is necessarily standalone and carries `UNLINKED`.

### Sorting with trackers

Global attention sorting and implementation order interact as follows:

- Issues labeled `reviewed:revised` form the strongest attention tier. A
  standalone revised issue appears before ordinary tracker groups and
  standalone cards. A tracked revised issue promotes its tracker group and
  appears before that group's ordinary children. A tracker issue that is itself
  labeled `reviewed:revised` also promotes its group.
- Tracker groups are ordered by their strongest visible attention state:
  problems first, then groups containing approved work, then oldest tracker
  first.
- Inside a tracker group, implementation order is authoritative after the
  revised-issue tier, even if a later child has a problem. Its red border
  remains visible in place.
- Standalone cards are sorted problems first, then approved, then oldest first
  after the revised-issue tier.
- Collapsed tracker headers participate in keyboard focus for expansion but do
  not open a details overlay. The details overlay for an expanded child includes
  its tracker context.

Completed cards take no part in any of those attention tiers. A completed card
never promotes itself or its group, whatever labels it carries — a closed
blocked issue is not an outstanding problem, and a closed `reviewed:revised`
issue has nothing left to rereview — while keeping the status color and border
its labels and checks earned, so a closed issue that was blocked still reads as
blocked. What they form instead is a settled block at the tail of each
partition:

- Implementation order stays authoritative for every tracked child whatever its
  lifecycle, so a group holding both open and completed children orders all of
  them the same way it always did.
- Standalone completed cards form one block after every open standalone card,
  ordered by newest updated first, with the item's own identity as the
  tie-break so two cards updated in the same second keep a stable order across
  refreshes.
- Wholly completed groups form one block after every group holding open work,
  ordered by the greatest update time among the tracker and its members,
  newest first, with the tracker number as the tie-break. A group is wholly
  completed when its tracker issue and every member grouped under it are
  completed — a property of the whole group across all four columns, not of one
  column's slice of it.
- The existing placement between the group and standalone partitions is
  otherwise unchanged.

## 13. GitHub data acquisition

The GitHub provider uses the user's existing `gh` authentication and requests
only the fields required by the board. Expected data includes:

- Open issues: number, title, plain-text body, URL, labels, assignees, creation
  and update timestamps.
- Open PRs: number, title, plain-text body, URL, labels, author, draft status,
  base/head branches, creation/update timestamps, closing issue references,
  mergeability, merge-state status, review decision, and status-check rollup.
- Open tracker issue bodies so ordered checklist membership can be parsed.
- Every item's own lifecycle state, as GitHub reports it: open or closed for an
  issue, and open, closed, or merged for a pull request. It is decoded from the
  item rather than inferred from the traversal that returned it, because a
  generation restored from the cache has no traversal behind it at all. Both
  enumerations are closed, so a state this build does not recognise fails the
  page: there is no placement for it that would not put a settled item among the
  open ones or the reverse.
- Each page's own rate report under `rateLimit` — what that page cost, what is
  left of the budget, and when the budget resets — as GitHub reports them.
  Every page asks, because only the newest report is worth anything to the
  scheduler in §15. A response that omits the field, or answers it with
  something this build cannot reason about (a missing part, a reset that is not
  a time, a negative cost or remaining), is not a refresh failure: the budget is
  simply unknown, the page counts as it always did, and nothing pauses.
- Each open issue's immediate native sub-issues — number, state, and owning
  repository — and GitHub's completed/total sub-issue summary, plus the
  repository's own `nameWithOwner`, so §12's second membership source can be
  resolved without a request per tracker. Tracker recognition happens after
  decoding, so these are requested for every issue on the page and only the
  tracker ones are consumed.

One explicit refresh follows both open connections to their end. Open issues
and open pull requests paginate independently, each until GitHub reports no
next page, and the refresh publishes only once both have reached their final
page. There are no display caps and nothing to configure: a repository with
several hundred open issues yields every one of them, and no column heading,
banner, or count ever stands for more items than it names.

`timeouts.github_seconds` bounds one page request and its cleanup rather than
the whole traversal. An uncapped refresh of a large repository legitimately
takes many pages, and bounding all of them together by a single page's budget
would fail exactly the repositories pagination exists for; what the deadline is
there to catch is one `gh` that has stopped answering. A page that exceeds it
fails that generation with the timeout vocabulary of section 17, and unwinds
through the same verified `gh` cleanup an interrupted fetch has always used.
Waiting for the coordinator's owner and waiting out a rate limit are not the
fetch being slow and consume none of that budget (section 15).

Completed history is acquired the same way, in the background. A second
traversal follows the closed issues and the closed-or-merged pull requests, each
connection to its final page, asking for the same fields as the open one and for
GitHub's `totalCount` besides. Nothing bounds either connection: every closed
issue and every settled pull request is reachable, and no loading, current, or
failure state ever describes a partial set as a whole one. It runs one page per
scheduled job rather than one traversal per call, so the coordinator in section
15 can take the owner back between pages; each of those pages is bounded by the
same `timeouts.github_seconds`, spawns `gh` under the same durable group record
and re-verifies that record first, unwinds through the same verified cleanup,
and reports its own `rateLimit` figures like any other page.

Every launch and every `u` re-traverses the whole history rather than fetching
what has newly completed. Nothing about a title, label, body, review, check, or
sub-issue relationship changing moves an item into a recently-completed window,
so an incremental fetch would silently never see an edit to an item closed years
ago. The cost is the reason it runs in the background and yields the budget
foreground work is reserved out of.

Open cards live only in the running process. The board reads no open snapshot at
startup and writes none after a successful refresh, so every open card on screen
was fetched by the process showing it. The per-repository snapshot file an
earlier release left behind is inert: the schema version has advanced past it,
so the compatibility gate in section 16 reads it as absent without decoding,
rewriting, or removing it — and the completed generation now stored at that same
path is inert to that gate for the same reason. `--no-cache` and `cache = false`
keep their documented meaning for every cache that remains.

Nested connections that return nodes — labels, assignees, closing-issue
references, and sub-issues — carry explicit `first:` limits and request
`totalCount`; cards and details show a `+N` overflow indicator when GitHub
reports omitted nodes. The sub-issue connection's limit is GitHub's own
100-child maximum, so one page holds every immediate child; a `totalCount`
above what arrived marks that item incomplete rather than presenting the
partial list as the whole relationship.

A tracker renders its native progress verbatim from GitHub's sub-issue
summary, so that summary is held to the same strictness as the connection it
accompanies. A negative count, more completed sub-issues than exist, and a
total below the relationships GitHub itself listed are all responses this
build cannot reason about, and fail the refresh rather than reaching a header
as `3/2 complete` or as `0/0 complete` above visible children. A total
*above* the connection's own count is the one direction that is merely
incomplete — a sub-issue in a repository the token cannot see is counted by
GitHub and absent from the node list — so it is kept and counted among the
children that did not arrive. The
status-check rollup requests up to 100 context nodes and deduplicates reruns by
check app/name (or status creator/context), retaining the newest entry and
breaking a tie in favor of the one GitHub listed last. A check run GitHub has
been asked for but has neither started nor completed carries no timestamp yet
and ranks newest under its key, so a queued rerun supersedes the failure it
replaces immediately rather than once it starts; a status context missing its
`createdAt` says nothing about its age and ranks oldest, so it cannot displace a
timestamped context of the same key. This avoids treating superseded failures as
current and permits real passed/total counts. A rollup beyond that cap fails
closed as unknown. GitHub scores GraphQL cost by requested node count, so these
caps keep the single-query refresh inside rate and node limits.

An anomaly attributable to a single item degrades that item rather than the
refresh. A rollup context the build cannot decode — an unrecognized
`__typename`, or a recognized one missing a field its decode needs — fails
closed to unknown exactly as the cap does. A nested connection GitHub leaves
absent or null, which is how a partial-error response reports a field that
errored, decodes as no nodes and marks that item incomplete. Both cases mark
the card and name it in a snapshot warning (§17). Everything else stays strict:
a `errors` array, a malformed top-level connection or page info, a missing
required scalar, a malformed rollup container, and a nested connection that is
present but malformed — including one whose `totalCount` is below its own node
list — all still fail the refresh, which retains the last good snapshot.

`gh`'s output is read as raw bytes and decoded once as UTF-8, replacing
malformed sequences rather than failing on them. Neither refresh success nor
decoded text depends on the environment's locale, so a board with non-ASCII
titles or bodies behaves identically under a UTF-8 locale and under the
C/POSIX locale an SSH, cron, or launchd session commonly supplies (§1).

No request is retried in a tight loop. A failure GitHub attributes to its own
primary rate limit is classified apart from an ordinary request error, so the
job it refused waits for the reported reset instead of being reissued straight
back into the same refusal (§15). The match is against the phrases GitHub uses
for that limit, never a bare word such as `token` or `limit`; GitHub's
secondary limit reports no reset to wait for and stays an ordinary request
error. Rate limits and transient failures are shown to the user while retaining
the last good snapshot.

## 14. Usage acquisition

Usage is global rather than repository-specific and refreshes once at startup
and when the user presses `u`.

Usage providers are best-effort observers of unstable interfaces. A failed or
unsupported provider never affects the board or another provider, and each can
eventually be replaced by a user-configured external command (below).

### Codex

Spawn the installed `codex app-server` on demand, initialize its JSON-RPC
protocol, request `account/rateLimits/read`, decode the primary and secondary
windows, and terminate the child. The response provides used percentages,
window durations, and reset timestamps.

The app-server interface is currently experimental. The provider decodes
defensively, uses a timeout, and reports an unsupported protocol without
inventing values. Captured protocol fixtures cover known response shapes;
broader version fixtures remain follow-up work.

### Claude

The public Claude CLI documents `/usage` as the interactive view for session
cost and subscription-plan usage bars, but does not currently document a
machine-readable shell command for the same plan limits.

The built-in provider therefore:

1. Starts the official `claude` client through macOS `script` in a private
   pseudo-terminal only after an explicit refresh, in a dedicated scratch
   directory such as `~/.cache/kanban/claude-probe/` rather than the user's
   repository. A fixed scratch directory means the client's folder-trust prompt
   happens at most once, and session history lands outside the user's project.
2. Uses `--safe-mode` and `--ax-screen-reader`, disables the auto-updater,
   telemetry, prompt history, and CLAUDE.md loading, and leaves normal OAuth
   access intact.
3. Recognizes the trust prompt only for its own scratch directory and otherwise
   requires the expected screen-reader prompt; an unrecognized screen is a
   parse failure, never something to answer blindly.
4. Sends `/usage`.
5. Captures and strips terminal control sequences.
6. Parses five-hour and weekly percentages and reset timestamps.
7. Exits immediately. If it does not, termination escalates group-wide —
   INT, then TERM, then KILL, each bounded — so a client that ignores an
   interrupt cannot outlive `script`'s pseudo-terminal wrapper; a client that
   requires SIGKILL to stop is reported as a failed refresh rather than a
   decoded snapshot, even when usage was already captured.
8. Rejects unrecognized output and retains the previous snapshot.

The provider does not read or reuse Claude OAuth credentials directly. It
delegates authentication and network access to the official client. Parsing is
isolated behind a version-aware adapter with captured-output fixtures.

This provider drives an interactive UI that changes on routine client updates,
so it is explicitly experimental and fails closed to `UNSUPPORTED VERSION`
with cached data intact when it breaks. Automated CI uses fixtures and does not
require a live Claude account, but the first-release gate includes a successful
manual refresh against the current supported Claude version because Claude
limits are a core dashboard feature.

References:

- <https://code.claude.com/docs/en/commands>
- <https://code.claude.com/docs/en/costs>

### External command escape hatch

Either provider can be replaced in configuration by a user-supplied command:

```toml
[usage.claude]
command = ["my-claude-usage", "--json"]
```

The array is an executable followed by literal arguments and is launched
directly without a shell. Shell metacharacters, substitutions, and pipelines
are never interpreted. A wrapper script remains available when a user
intentionally needs shell behavior.

The command must print a small JSON document on stdout:

```json
{"windows": [{"label": "5 hour", "pct_left": 78, "resets_at": "2026-07-16T16:05:00Z"}]}
```

When configured, the external command is the provider: it runs with the same
timeout and validation rules, and the built-in integration is not used. This
keeps users unblocked when a client update breaks a built-in parser.

### Sidebar display

```text
Codex          3h 0m old
5 hour  [██████░░░░] 63%
in 1h 5m · Thu 16:05
week    [████░░░░░░] 41%
in 4d 18h · Tue 09:00

Claude         3h 0m old
5 hour  [████████░░] 78%
in 2h 30m · Thu 17:30
week    [██░░░░░░░░] 22%
in 1d 18h · Sat 09:10
```

Each window shows its own reset time; five-hour and weekly windows reset
independently. A window's second row states both how long until that window
resets and the local wall clock it resets at, and the countdown takes that
row's former indent rather than a row of its own: the percentage row above it
already spends the sidebar's whole interior, and a provider's block is a fixed
height.

A provider's name shares its row with the age of the snapshot on screen. That
age is drawn for every snapshot rather than only for a stale one, because a
snapshot restored from the cache at startup is labelled fresh at the instant it
was written -- so a board opened on numbers days old is exactly the case the
age exists to report.

Reset and relative times are recomputed whenever a redraw happens for another
reason, from the instant that redraw carries; the application never wakes on a
timer to maintain a countdown.

### The `--usage` command-line surface

`kanban --usage` answers the same question from a shell without starting the
dashboard. It reports both providers and exits zero when at least one produced
windows, non-zero when none did. A provider that fails prints its own line and
never suppresses or replaces the other's.

```text
Codex
  5 hour   63% left · resets in 4h 5m (Thu 16:05)
  weekly   41% left · resets in 3d 21h (Mon 09:00)
  snapshot 30m old

Claude
  unavailable: claude is not installed
```

Both the window countdowns and the snapshot-age line are computed by one pure
function of the snapshot, an explicitly supplied current time, and the zone
the reset wall clock is stated in. The sidebar states the same countdown and
the same age through those same functions rather than a second copy of the
arithmetic; it only arranges them into its own narrower rows.

Every duration is clamped at zero and bounded above. A snapshot stamped ahead
of the clock reads `0s old` rather than as a negative interval, and a reset
instant already past is named `resets due now` rather than counted down to,
since `resets in 0s` would be a countdown to an instant that has gone. Nothing
restricts how distant a decoded `resets_at` may be, so past 99 days a duration
reports `>99d` instead of counting out days without limit -- which is what
keeps the sidebar's reset row inside its fixed interior for any instant a
provider reports.

Which process a provider runs is decided by the one routing path the board
uses, so a configured `[usage.codex]` or `[usage.claude]` command replaces the
built-in probe here exactly as it does there.

Freshness policy:

- The default is cache-first. A provider with a usable cached snapshot is
  printed from it and is not spawned; a provider the cache has nothing to
  print for is probed live. A cached snapshot carrying no windows is not
  usable — there is nothing to print — so it is probed live too and never
  counts toward the exit status.
- `--fresh` probes both providers live regardless of the cache.
- `--no-cache` and a global `cache = false` probe live and neither read nor
  write the `usage.json` snapshot (section 16). Combining either with
  `--fresh` is accepted and behaves the same. Neither affects the scratch
  directory a configured usage command is launched from; that is not a
  snapshot.
- A live result obtained under an enabled cache is merged into `usage.json`,
  leaving the other provider's stored entry intact. A provider that fails
  never erases its own last-good stored snapshot.
- The printed output always describes the acquisition path that ran. A forced
  live probe that fails reports that failure rather than falling back to the
  older cached snapshot, even though an enabled cache keeps that snapshot on
  disk.
- No background or automatic refresh is introduced. Nothing runs except the
  probes the two rules above call for.

`--usage --json` writes a machine-readable document to standard output instead
of the human rendering, and never both. Its shape is a contract for scripts:

```json
{
  "schema_version": 1,
  "providers": {
    "codex": {
      "status": "ok",
      "fetched_at": "2026-07-16T11:30:00Z",
      "windows": [{"label": "5 hour", "pct_left": 63, "resets_at": "2026-07-16T16:05:00Z"}]
    },
    "claude": {"status": "error", "error": "claude is not installed"}
  }
}
```

Provider keys are lowercase and always both present; `status` discriminates a
successful entry from a failed one, so a failure is represented rather than
omitted. Timestamps are absolute RFC 3339 UTC, needing no knowledge of the
reader's zone. Configuration warnings and cache warnings go to standard error
in both renderings, so a `--json` consumer's standard output carries the
document alone.

## 15. Refresh and event model

- Brick owns the blocking terminal event loop.
- The GitHub and usage providers each run once in short-lived startup workers
  and again only after an explicit unified update.
- One repository-scoped coordinator owns every `gh` a board refresh starts and
  the durable `gh` group record for that repository, and decides the order that
  repository's refresh jobs run in. Every production board-refresh entry point
  goes through it — startup, `u`, and the refreshes a finished review, solve, or
  pull-request action requires — so two requests arriving together resolve to
  one owner, neither can spawn `gh` while the other holds it, and no
  interleaving of the record's read-modify-write updates can lose an entry.
  Scope is one coordinator per repository within one dashboard process. Nothing
  here schedules across processes; the durable record and the restart-time
  reclaim refusal remain what covers that.
- The coordinator schedules typed jobs rather than one anonymous refresh: a
  foreground open job and a background history job. When both are runnable the
  open job runs first; a history job never starts or resumes while an open job
  is pending or running, including one waiting out a rate limit; and a history
  job gives the owner back at every page boundary, so a newly requested open job
  takes it without waiting for the traversal to finish.
- `u` during a running cycle still reports that an update is already running,
  and now also leaves at most one newest follow-up cycle queued. Any number of
  presses leave exactly one follow-up, none of them starts an overlapping
  provider worker, and the follow-up starts once the running cycle publishes its
  outcome — but only when the board can accept work. A cycle ending in an
  unverified cleanup that could not be recorded deliberately leaves the board
  `Loading`, and the follow-up stays queued rather than being spent on a call
  that would only be turned away. The existing guarantee that a refresh required
  by something this dashboard already committed is never dropped is unchanged.
  This is about GitHub board jobs only: Codex and Claude usage refreshes stay
  independent, with their own workers, timeouts, and freshness (§14).
- That coalescing is decided from two answers, because neither alone is
  complete. The coordinator reports every foreground cycle it takes the owner
  for — including one it reissued itself after a rate limit, which no press
  asked for — and the board records it as a refresh in progress; the report
  moves the freshness only, so the notice already on screen, above all the rate
  limit that caused the reissue, still explains the wait. But that report
  travels through the event channel, so a press can land while a cycle is
  running and the board has not heard yet. A press therefore also asks the
  coordinator directly, which has no such window, and either answer is enough to
  turn it into the one queued follow-up.
- Background history yields to a reserve held for foreground work. Before
  starting or resuming a history job the coordinator compares the remaining
  budget against a fixed internal reserve of 200 GraphQL points — a named
  constant in the source with no configuration key, since a value that could be
  lowered to zero would silently retire the guarantee. History pauses when the
  remaining budget is at or below the reserve, which is what makes the reserve a
  balance that survives rather than one the last page may spend, and the board
  reports `History paused · GitHub limit resets <time>` through the existing
  notice line using GitHub's reported reset. It resumes on its own once that
  reset has passed, or once a later foreground page reports sufficient budget —
  a paused history job cannot produce that page itself, which is why the
  foreground's counts.
- Only the newest report counts, and an unknown budget pauses nothing. What is
  *left* of a budget is spent continuously, so a page that reported nothing
  usable replaces an earlier figure rather than leaving it standing, and ends a
  pause that figure caused; history stays paused only while the newest page
  actually says the budget is at or below the reserve. The reset time is the one
  part that outlives its report — it names a fixed moment rather than a balance,
  and the response GitHub refuses a request with carries no report at all, so
  the reset an earlier page named in the same window is what a refused job waits
  out. Neither an unknown report nor a healthy one ends a rate-limit hold.
- A job GitHub refuses against its primary rate limit is reissued, not merely
  delayed: it goes back in the queue under a hold until the reported reset, so
  it is tried again once the budget returns rather than dropped when the hold
  lapses. A foreground refusal is still published when it happens, since §13
  shows a rate limit while retaining the last good snapshot, and a silent
  reissue would leave the board saying nothing for as long as the budget takes.
  A background traversal is reissued the same way, which is what keeps it from
  hot-looping the limit; a history page that failed for any other reason ends
  the traversal rather than being retried.
- The board's open job carries no whole-request deadline. The configured GitHub
  timeout bounds one page of the traversal (section 13), and an uncapped
  refresh of a large repository legitimately takes many pages; waiting for the
  owner and waiting out a rate limit are not that fetch being slow and spend
  none of a page's budget. A refusal is published when it happens, so the board
  is never silent while a reissue waits out the reported reset.
- Quitting goes through the coordinator whenever it has anything to settle, and
  halts immediately otherwise. Queued or running work is one reason to settle;
  so is a job that has already finished and left a group only this process is
  holding back, since the question a quit asks is whether the dashboard may
  stop, not whether work is in flight. Settling cancels the queued work and
  interrupts the running job exactly as a refresh timeout does, so it unwinds
  through the same verified `gh` cleanup, bounded by that cleanup's own budget.
  The board says it is stopping GitHub work while this happens; a cancelled job
  publishes nothing and requeues nothing; and nothing requested afterwards is
  accepted. A cancelled generation leaves no trace at all — no board update, and
  no file, since open cards are never written to disk (section 13). Whatever
  makes work stop being observable also claims the right to answer it, in the
  same step: releasing a finished job, and taking an expiring request out of the
  queue, each claim their publication as they happen. A quit therefore lands on
  one side or the other — before the claim, and nothing is published; after it,
  and the quit waits for the answer already claimed rather than halting while a
  board update is still to land.
- Every open cycle has an identity, and only the newest one may publish. The
  coordinator claims an identity in the same decision that makes a cycle
  answerable — starting it, or spending a request that expired before it could
  start — and every publication carries the identity it was claimed under. The
  board records the newest identity it has been told started, and discards an
  outcome carrying an older one outright: not applied partially, not merged,
  not allowed to move the freshness. "Newest" means the newest cycle the
  coordinator actually started, so a `u` that only managed to queue a follow-up
  does not retroactively suppress the cycle already running; that cycle
  publishes under its own identity, and is superseded only once the successor
  has started. A partial page set, a cancelled generation, and a page that
  timed out publish nothing at all.
- A published generation replaces the board whole. Selection is preserved by
  the item's identity, the details overlay keeps its target, and live worker
  and review session association is reconciled, exactly as every refresh has
  always done — all of it in one step, so nothing on screen is ever half of one
  generation and half of another.
- Every completed generation has an identity too, claimed by the board itself
  before the history job is queued rather than by the coordinator when one
  starts. That is the difference the two kinds of work force: a completed
  generation spans many jobs over many minutes, so what an outcome has to be
  checked against is the newest history the user asked for, which is known the
  moment they ask. Launch and `u` each claim one. A request arriving while a
  page is in flight supersedes that page at the next page boundary — the only
  point the traversal ever stops at — and any number of further requests
  coalesce onto one newest full restart. Nothing accumulated under a superseded
  identity contributes to its replacement, and a page that finishes under one
  publishes nothing at all.
- A completed generation publishes only when it is whole. A partial page set, a
  cancelled traversal, a page that timed out, a failed page, and a completion
  belonging to a superseded identity can none of them become the in-memory
  history or reach the cache. While one is in flight the board records its
  progress as loaded and total counts, kept separately for issues and pull
  requests because the two connections paginate independently; the total is
  GitHub's own count for that connection and is unknown rather than zero until a
  page has reported one. Progress and failure are recorded independently of the
  open generation's freshness: a history still loading says nothing about
  whether the open board is current.
- Background history never delays open work. Launch and `u` publish the open
  board without waiting for any part of the traversal, and a completed
  generation in flight neither postpones nor cancels an open refresh. A newly
  requested open job may wait for the deadline-bounded history page that happens
  to hold the owner, and for its verified cleanup, and for nothing further — not
  another page, and never the rest of the traversal.
- At publication the two generations are reconciled, so no item is ever in both
  sets. Whichever publishes second answers for the items it lists: an item
  GitHub has just reported open leaves the completed set, and one a newer
  completed generation proves settled leaves the open board. That is the one
  way a completed generation may remove an open card, and it removes only a
  card the newer generation has positively contradicted.
- A completed-generation failure keeps the last complete history. It does not
  erase the last complete cached or in-memory generation, and does not disturb
  the open board; with no complete generation behind it, completed history is
  simply absent rather than partial.
- Until the first complete generation publishes there is no board to draw, and
  section 17's two centered panels stand in for one. They replace the columns
  rather than covering them, so no card, heading, or count from any source
  reaches the screen; the sidebar, footer, and every key stay as they are.
- Every foreground request is answered exactly once. A job that produced no
  outcome of its own — its deadline expired, or it gave up — is still answered,
  from what its verified cleanup concluded: an unverified `gh` outranks the
  timeout, since a refresh that ran out of time over a process nobody could
  confirm stopped is not an ordinary timeout and the board must hold off rather
  than age into a failure that lets the next fetch through. Only a job the quit
  cancelled is left unanswered, because nothing is waiting for it. The dashboard halts once the cleanup reaches a verdict
  that leaves nothing ambiguous — the group confirmed gone, or durably recorded
  for a later run to re-check before it spawns anything. A group that is
  neither, possibly live with only this process's in-memory refusal covering it,
  refuses the quit and reports that instead: halting there would drop the one
  thing holding the next `gh` back, so the dashboard says to stop the stray `gh`
  and then end it from outside. A live interactive review still refuses the quit
  exactly as it did, and is asked first.
- That in-memory refusal is the repository's for the rest of the process, not
  the finished job's. Any job may end holding a group back this way — a
  background history page spawns `gh` under the same durable record a
  foreground refresh does — and a refusal recorded only against the guard of
  the job that ended would die with it, leaving the next job to find an absent
  record, reclaim nothing, and spawn straight past a possibly-live group. So
  the refusal is recorded once the job's verdict is final and while it still
  holds the owner, and every later fetch of either kind is turned away by it
  before it spawns anything — reported as the in-memory case it is, since a
  restart cannot know to hold back over a group nothing wrote down.
- Every canonical GitHub repository has its own PR drainer: its own LaunchAgent
  label and plist, its own runtime status, its own service and dated logs, and
  its own `--config` selection. Starting, stopping, querying, logs, status, and
  incidents for one repository do not affect another. One installed copy of the
  controller, the drainer, and the configuration parser serves all of them.
- A drainer's identity is the checkout's canonical GitHub `owner/name`,
  normalized case-insensitively, so two spellings that differ only in case name
  one drainer and two clones of one repository cannot drain it concurrently. A
  checkout whose remote does not resolve to a supported github.com repository
  can neither install nor control a drainer.
- That identity is resolved through the remote the *shared* Kanban
  configuration names — the same remote the dashboard resolves its own
  repository through — never through a repository's installed `--config`. A
  repository's `--config` lives in the record its identity selects, so letting
  it decide the identity would decide it from a record already found by it: the
  installer and the installed controller would resolve two different
  repositories from one checkout. The `--config` still decides everything its
  drainer runs with, including the remote its default-branch check and merges
  use.
- The PR drainer controller discovers the installed LaunchAgent through the
  record its installer writes at
  `~/Library/Application Support/kanban/pr-drainer/config.json`, whose
  `repositories` table holds one entry per installed repository naming that
  job's launchd label, the plist's absolute path, and the installed checkout.
  Kanban derives none of those: it selects the entry by its own normalized
  repository identity, reads the plist path from that entry, and reads the
  controller command from the plist, which stays authoritative for what launchd
  runs. Each way that lookup can fail — a host that is not macOS, no document,
  no entry for this repository, an entry that does not name a job, or a plist
  that cannot be read — is reported as its own status naming the remediation,
  never as a raw exception. Discovery then reads its
  wrapper's JSON status every ten seconds, and never contacts a network. Start
  and stop operations run asynchronously and expose transitional UI state.
  Every controller call includes both the dashboard's resolved repository root
  and its repository identity; the controller resolves the checkout's own
  remote and refuses any identity but that one — including another remote of
  the same checkout, since a fork's upstream is a different canonical
  repository. Neither `--repo OWNER/NAME` nor a `--config` naming another
  remote can therefore select or create another repository's drainer, or make
  the dashboard act on this checkout's job while reporting a different
  repository. The refusal names the shared configuration's `remote_name`, and
  re-running the installer, as what moves the dashboard and the drainer
  together.
- The installed plist records the identity its label was derived from, and the
  launchd runner is held to it by the same check. A plist outlives the
  configuration it was written from, so a runner that re-derived its identity
  at launch would follow a changed `remote_name` into another repository's
  status file, incidents, and logs under a label the dashboard cannot
  discover. Instead the job drains nothing, writes the refusal to its own
  service log, and stays refused until the installer is re-run — which mints
  the job for whichever repository the configuration now names, leaving the
  superseded one inert.
  A second checkout of the same repository is that repository's own drainer,
  not a foreign one: it is reported as running, and a second install or start
  is refused naming the checkout that already holds it.
- The installer links the controller, the drainer, the shared configuration
  module, and the service-manager backend the controller drives launchd
  through out of one live development checkout, so whatever is on disk there —
  a mid-edit file, a checked-out feature branch, a checkout the remote has moved
  past — is what every repository's drain actually runs, and nothing in the run
  says so. Each launchd run therefore compares those four executing sources
  against that checkout's local `origin/master` and reports what it finds to the
  same service log, ahead of both of its refusals: one line naming every
  differing source and every cause the comparison can attribute to it — a
  working-tree edit, a non-master `HEAD`, unpushed commits, or a `HEAD` the
  baseline has moved past — and at most one further line summarizing every
  comparison it could not make. The advisory is a report and nothing else.
  Sources matching the baseline are silent, the comparison only reads and never
  fetches or writes repository state, and no divergence, missing source, absent
  ref, or failure of the comparison itself refuses, delays, or otherwise changes
  what the run does. Gating a drain on a dirty checkout is what this
  deliberately does not do: the drainer has to keep working while a human works
  the same checkout.
- The status response also projects the post-merge cleanup a merged pull
  request still owes, which no other surface reports: a merge attempts its own
  cleanup immediately, but what that attempt leaves outstanding is retried only
  by the polling loop's sweep and by one bounded pass on the way out of an
  intentional stop, so debt that outlives both is owed by a drainer that is no
  longer working it, and debt below the incident threshold has raised no
  incident to be seen through. The projection names each owing pull
  request, its outstanding steps in the wording the drainer uses for an
  incident, its failed-pass count, and its last error, ordered by pull-request
  number so an unchanged state answers identically every poll. It distinguishes
  three answers, on the same rule the open incident set follows: a set, a
  verified-empty set, and unknown for a queue state that is absent, unreadable,
  malformed, or of an unsupported version. Reading it is strictly read-only —
  no lock, no migration, no repair — and can never fail a status call, which is
  the diagnostic used when the repository is already in a bad state.
- The status response also names the local copies of work the drainer's
  autostash lifecycle left behind in the checkout, which are otherwise visible
  only in one log line per startup sweep — a line that repeats identically
  every pass, so a possibly-sole copy of someone's work waits for a human to
  read a service log. Two collections, separate because they fail separately:
  every autostash anchor whose snapshot is in no `git stash list` entry, named
  by the same ref, commit, commit date, and restore command the kept-anchor log
  line names; and every stash entry the drainer itself stored, named by its
  selector, its reserved message, and its date. Classification restates the
  startup sweep's own rule rather than running it — an anchor is kept when its
  commit is absent from a stash list that was read successfully, and every
  anchor is kept when that list could not be read — and an entry counts as the
  drainer's only on a full match against the exact messages the drainer writes,
  so the entries a user pushed are never named and the stash stays theirs. Each
  collection distinguishes the same three answers the projection above
  distinguishes: entries, verified-empty, and unknown for one that could not be
  enumerated or parsed, with one collection's failure leaving the other and
  every other status field intact. Reading both is strictly read-only and
  cannot fail a status call: no ref, stash entry, stash ordering, queue state,
  or sweep behavior changes, and neither does what any caller of status —
  including the polling a start or stop does — goes on to report.
- The sidebar folds that projection into its single drainer detail line as a
  clause counting the pull requests that owe, on every state that can carry
  debt. Unknown renders nothing, so a controller predating the projection looks
  exactly as it did. Debt alone changes neither the drainer's color nor the
  incidents panel: obligations under retry are ordinary behavior, and
  escalating them stays the open incident's job.
- An intentional stop discharges what it can of that debt before it completes.
  The drainer holds the repository run lock for its whole lifetime, so the stop
  is the last moment anything can work these obligations before the next start,
  and it spends a bounded slice of its shutdown doing so — only obligations
  already recorded, never a new merge, branch update, rereview, or
  pull-request read. The budget is small enough that the whole transition —
  signal, final pass, and confirmed exit — still fits inside the timeout `d`
  gives a controller invocation, and an obligation that wedges is left
  outstanding rather than holding the stop open past it. What the pass does not
  discharge stays recorded, stays in the projection above, and stays under
  whatever incident it raised; what the pass finishes resolves that incident on
  the same self-clearing path any other completing pass uses. The stop reports
  how many obligations it discharged and how many remain, both read off the
  persisted state either side of it, and succeeds either way: outstanding debt
  is a debt to retry, not a failed stop.
- A controller invocation runs as its own process group, and ownership of that
  group is established while the controller is known alive rather than at
  cleanup time, so a timeout can terminate what the controller started even
  after the controller itself has exited. Structured status on standard output
  is decoded even when the controller exits nonzero, so a state reported
  through a failing exit keeps its incident detail. An invocation that outlives
  its timeout is terminated as a group and confirmed gone before anything is
  reported; a start or stop killed mid-transition is reported as an unknown
  outcome the next status poll reconciles, and a termination that could not be
  confirmed is reported as such instead.
- A start is issued only from a settled stopped state. A transition already in
  flight — this dashboard's own, or a `starting` state reported by the status
  poll — makes `d` and the drainer button report the transition rather than
  command a second one.
- `m`, on the board and on the details overlay alike, merges the selected
  approved pull request by running the drainer's own single-pull-request path
  (`tools/drain_prs.py --pr`) once. Kanban contains no second implementation of
  the merge, its gates, or its cleanup: the invoked path re-reads every gate
  immediately before merging, matches the head against the approved head,
  performs the admin merge and its post-merge audit, and closes the linked
  issue, removes the worktree, deletes the head branch, and fast-forwards the
  default branch. The invocation carries the dashboard's own resolved checkout,
  its repository identity as `--repo OWNER/NAME`, the selected pull-request
  number, and the active absolute `--config` when one is set; the drainer
  compares that identity against the checkout's remote and refuses a mismatch,
  so neither a `kanban --repo` nor a `kanban --config` override can merge
  another repository's pull request.
- That script is resolved from the Kanban-managed drainer install directory:
  `KANBAN_DRAINER_INSTALL_DIR` first, then the directory the discovered
  LaunchAgent runs its controller from — which is what keeps an install made
  with `--install-dir` usable by a dashboard that inherited no environment from
  the installer — and otherwise the directory holding the discovery record. A
  source that is present but resolves to no directory, such as a relative
  override or a plist that does not name its controller absolutely, fails there
  rather than falling through to the next: falling through would merge with an
  installation other than the configured one and report nothing unusual. A
  missing installation reports a remediation naming
  `tools/install_drainer.py` and the directory that was actually consulted.
- The decision `m` makes is total in the selection and the last reported
  drainer state, and is taken in a fixed order. A selection that is not an
  approved pull request in Done — `classifyPullRequest`'s own verdict, not a
  second reading of the same labels — is refused first, naming what was
  selected. A direct merge this dashboard already started is refused next,
  naming the pull request still running, so a repeated key press starts no
  second process. An unresolved incident then outranks every service state and
  is refused with its summary. Only a service *known* to be stopped may launch:
  running, starting, stopping, a drainer running outside launchd, a checkout
  stopped part-way through a git operation, and a state that could not be
  established at all — including one no status was ever obtained for — all
  refuse without invoking anything.
- A result is believed only once it is established to be the promised
  document for the pull request that was asked about: the `drain-prs-single-pr`
  schema, a version this Kanban reads, that pull-request number, a known
  outcome, and an outcome that does not contradict the merge flag or a dry run.
  Anything else — including a document carrying the outcome fields under
  another schema or version — is refused with a remediation naming the
  installer, because the resolver runs whatever is installed at the selected
  path and a merge is both reported to the user and acted on by refetching the
  board.
- The run is asynchronous and unbounded, since its work is irreversible partway
  through and a deadline that killed it would abandon a merge already committed
  on GitHub. Its result updates only that action's notice and pending state,
  never the drainer status area, which reflects the service this ran instead
  of. The reason the run reported is presented as it wrote it, after the
  external-text sanitization in section 11, rather than replaced by a generic
  message; a merge that landed and then failed its audit or left cleanup
  outstanding is reported as merged *and* as unfinished. Any result that says
  the pull request merged requires a GitHub refresh that begins after that
  result: when a fetch is already in flight the request is queued rather than
  dropped, because that fetch may have read GitHub before the merge landed.
- A landed merge's result stays in front of the user across that refresh
  rather than being replaced by it. The result is the only report an
  irreversible action gets — and the merged-but-unfinished case is reported
  nowhere else — so the refresh the same result requires must not be what
  removes it from the screen. It is carried in front of the refresh's own
  notices and dropped once the required refresh has actually published, not
  once whichever fetch happened to be in flight did. It is carried only while
  what is on screen is still the notice it last wrote, so every way a notice
  ends — either `Esc`, an overlay opening, a moved selection, another action
  reporting — also ends the result behind it, and a dismissed merge report can
  never be recreated by the refresh it required.
- The canonical drainer, controller, and safety-first installer are versioned
  with Kanban under `tools/`. The installer creates stable per-user links under
  `~/Library/Application Support/kanban/pr-drainer/`; rerunning it refreshes
  those links after repository relocation, and repairs a missing or stale
  discovery record in place without an uninstall and without changing the
  LaunchAgent's identity. Installing a second repository adds its entry beside
  the first rather than replacing it. Before enabling a repository's derived
  job, the installer retires the machine-wide `com.coghex.drain-prs` singleton
  that predates per-repository jobs when that singleton served the same
  repository — unloading it and setting its plist aside so the two can never
  run together — and leaves a singleton installed for a different repository to
  migrate on its own next install.
- Worker results enter the UI through a bounded `BChan`.
- The UI redraws after a key event, resize, provider result, active review
  event/spinner tick, or explicit terminal repaint.
- There are no periodic network or Git polls. The sole timer is the ten-second
  local PR drainer status check.
- Board and usage refresh independently.
- Codex and Claude failures are independent of one another.
- A refresh records its completion time and whether displayed data is fresh,
  stale, loading, unavailable, or unsupported.
- Selection survives refreshes by issue or PR number. If the selected item
  disappeared, selection falls back to the nearest card in the same column. A
  details overlay whose item vanished closes with a transient notice.
- Relative timestamps, snapshot age, and reset times are recomputed during any
  redraw rather than stored as fixed strings, so they stay honest without a
  timer.

## 16. Cache and configuration

Suggested paths:

```text
~/.config/kanban/config.toml
~/.config/kanban/settings.json
~/.cache/kanban/repos/<owner>-<repo>.json
~/.cache/kanban/usage.json
~/.cache/kanban/logs/<owner>-<repo>/<workflow>-<number>-<timestamp>.jsonl
~/.cache/kanban/workers/<owner>-<repo>/<worker-id>.{spec,state}.json
~/.cache/kanban/workers/<owner>-<repo>/<worker-id>.events.jsonl
```

Defaults:

- Cache only the latest good snapshot. Open issues and open pull requests are
  not cached at all: nothing writes an open snapshot, and the open reader's
  schema version has advanced past the last one that did, so a file an earlier
  release wrote is read as absent and left exactly as it was found.
- Cache the completed generation, and only a whole one. The per-repository path
  above holds it under a schema version of its own, so the two payloads that
  path has held are alternatives rather than companions and neither reader ever
  decodes the other's: to the open reader a completed generation is another
  unrecognised version, and therefore absent. Only a generation that reached
  both connections' final pages is written, and it replaces the stored one
  atomically, so an interrupted or failed generation leaves whatever was there
  exactly as it was. A stored generation seeds the history at startup without
  waiting for GitHub, and is superseded by the first live generation of that
  process. Publishing does not wait on the cache: with caching switched off, or
  after a write that failed, the complete generation still stands in memory and
  the failure is reported rather than the generation discarded.
- Persist lightweight UI preferences separately from future repository
  semantics. Chat verbosity defaults to Standard and offers Compact, Standard,
  and Full display modes.
- Record every managed agent provider line before parsing or display filtering.
  Raw workflow logs always remain full; changing display verbosity never
  changes their contents. Directories use `0700` and files use `0600`. Every
  directory level Kanban creates below the XDG cache and config roots carries
  `0700`, whatever the umask and whichever writer created it first; the roots
  themselves are shared and keep their own modes.
- Create cache files with user-only permissions (`0600`). A file that is
  appended to rather than rewritten — a worker's event journal — is created
  `0600` whatever the umask, and is tightened to `0600` before each append, so
  one an earlier release left loose self-corrects instead of waiting for a
  rewrite that never comes.
- Never cache an open issue or PR body. Startup renders no open card until the
  first live generation publishes, so nothing about a private repository's open
  work is written to disk. Completed history is the one exception, and carries
  the whole stable payload of a settled item, bodies included: an item that is
  closed or merged has stopped changing in the ways the board reacts to, its
  body is what the details overlay renders from, and rereading every one of them
  from GitHub before anything could be shown would defeat the point of storing
  the generation at all. That exception is protected by permission rather than
  by omission — the file is created `0600` under a `0700` directory like every
  other cache here — and it extends to nothing else: no open item's body reaches
  disk under any circumstances.
- Bound the per-repository worker cache during startup discovery, so neither
  retired leases nor finished workers accumulate for the life of the cache. A
  retired `.stale-*` lease directory is collected once every identity it
  records — its own lease owner and that worker's durable state — is confirmed
  gone. A terminal worker's spec, state, journal, and ack marker are collected
  once it has been acknowledged and a newer durable worker supersedes its
  workflow step, and in any case once it is past a 14-day retention window
  measured from its terminal heartbeat. The pass never touches a live lease, a
  non-terminal worker, a worker that still owns its item's lease or still
  matches a live process, or anything belonging to another repository. It fails
  closed whenever a record will not decode or a process snapshot cannot be
  taken, removes the `.spec.json` discovery anchor last so a partial removal
  stays discoverable and retryable, and is quiet and non-fatal so discovery
  proceeds regardless.
- Include a `schemaVersion` in every snapshot. A snapshot with an unknown
  version is treated as absent rather than as corruption: the version is read
  before the payload, so a file another release wrote is silent even when its
  contents no longer fit the current shape. A file that is unreadable, carries
  no integer version, or fails to decode under a version Kanban does recognise
  is corruption and keeps its warning. Settings follow the same rule, falling
  back to the defaults silently for an unknown version.
- Permit `--no-cache` and a global `cache = false` setting. Either suppresses
  both the read and the write of every cache here, the completed generation
  included: a run with caching off seeds no history and stores none, and leaves
  whatever an earlier cached run wrote exactly where it was. `kanban --usage`
  answers to both identically, and with either in force it probes live for the
  same reason it does under `--fresh`: there is no snapshot it is permitted to
  read.
- The usage snapshot is what `--no-cache` and `cache = false` govern for
  `--usage`. A configured usage command's own scratch directory under the XDG
  cache root is not a snapshot and is unaffected. When the cache is enabled, a
  live usage result is merged into `usage.json` rather than replacing it, so
  one provider's failure never erases the other's stored entry or its own
  last-good one (section 14).
- Key repository settings by `owner/name`; do not require modifying the target
  repository. The key is canonical: two non-empty segments of ASCII lowercase
  letters, digits, `.`, `_`, and `-` around exactly one `/`, with no
  uppercase, surrounding whitespace, URL or SCP remote syntax, `.git` suffix,
  or repeated slashes. A key outside that grammar is a decode-time
  configuration error naming the full offending key path, rather than an
  override that can never be selected. That is deliberately stricter than
  `--repo`, which the user chooses per invocation and which keeps accepting
  the GitHub URL forms section 5 describes. The `owner/name` resolved from the
  remote or `--repo` is folded to lowercase — ASCII only, so the Haskell
  dashboard and the shared Python loader agree on every input — to select an
  override, and only for that selection: the identity used for GitHub queries,
  cache paths, and display keeps the case it resolved with. A canonical key
  naming a different repository stays silent and has no effect.

Configurable repository semantics include:

- Approval label, default `reviewed:approve`.
- Changes-requested label, default `reviewed:changes`.
- Blocked labels, default including `blocked`.
- Tracker labels, default including `epic`.
- Problem-styled and UI-styled label-chip names, both default empty.
- Coordination paths, default empty. Exact, case-sensitive, repository-relative
  paths — no globs, directory prefixes, or extension matching, and a rename
  counts both of its endpoints — whose content coordinates the pipeline rather
  than building it. The PR drainer reads them, and only to decide whether a
  default-branch advance that touches nothing else has to be merged into a
  candidate before that candidate's own gates are evaluated
  (`docs/pr-drainer.md`). Nothing in the dashboard reads them, and the empty
  default leaves every repository behaving as it did before the key existed.
- Additional tracker-section headings.
- GitHub remote name, default `origin`.
- Approval predicate mode: label, review decision, or either; default label.
- Card excerpt line count, default 3.
- Provider timeouts, defaults: GitHub 30 s, Codex 10 s, Claude 45 s. The GitHub
  timeout bounds one page of a traversal — open or completed — rather than the
  whole of either (section 13).
- External usage provider commands (section 14).

## 17. Error presentation

Errors should remain inside the dashboard unless startup cannot identify a
repository at all.

- Authentication failure: named provider shows `AUTH REQUIRED`.
- Missing executable: provider shows `NOT INSTALLED`. Only a launch that failed
  because there was nothing runnable to launch reports this — no such file, or
  a file that cannot be executed. Any other failure to spawn the provider, and
  anything that goes wrong once it is running, is a request error instead, so a
  working installation is never reported as absent.
- Unsupported CLI format or protocol: provider shows `UNSUPPORTED VERSION`.
- Timeout: provider shows `TIMED OUT` and retains cached data.
- Primary rate limit: a refusal GitHub attributes to its own primary rate limit
  shows `RATE LIMITED` and retains cached data. It is held apart from a request
  error because it is the one failure whose remedy is waiting a known length of
  time, which §15's scheduler acts on; GitHub's secondary limit reports no such
  time and stays a request error.
- No open generation yet: the board body is a centered indeterminate loading
  panel that renders no cards from any source and reports no item counts or
  page totals.
- First open generation failed: that panel becomes a centered
  `OPEN DATA UNAVAILABLE` state carrying the classified reason and a `u` retry
  hint. It renders no cards and restores no persisted board, while `u`, `q`,
  `Ctrl-C`, help, and options stay operable. Once one generation has completed,
  a later failure keeps that board instead, with the stale marker below.
- Data after refresh failure: dashed/dim treatment plus snapshot time.
- Malformed tracker checklist: tracker remains visible; unparsed children fall
  back to Standalone and the tracker gets an amber parse warning.
- Partial GraphQL response: a response GitHub answers with both data and
  errors renders the data it did deliver and reports the errors as a refresh
  warning, so long as every requested connection arrived; errors accompanying
  a page the decoder cannot reason about fail the refresh instead. Either way
  the messages GitHub sent are what the dashboard shows, bounded to one line,
  never a generic sentence standing in for them.
- Item-local decode anomaly: the affected card is amber and an amber banner
  names it as `Issue #N`/`PR #N: incomplete data`, naming the first few and
  counting the rest. The card states what is unknown rather than asserting the
  absence — an item whose assignees never arrived is not shown as `unassigned`
  and does not fall into the backlog column, and a pull request whose closing
  references never arrived is not shown as `UNLINKED`.
- Missing Kanban-owned setup: an AI action that preflight finds definitely
  unready never spawns an agent. It reports `cannot start` naming the cause
  and the command that installs it, rather than a generic agent failure, and
  its session activity reads `setup required`. Only a definite local
  observation blocks; an inconclusive probe lets the action run.

No error should clear a previous good snapshot.

## 18. Testing strategy

Favor pure functions and fixtures so most tests run without a terminal,
network, GitHub account, or installed AI client.

### Pure tests

- Issue/PR column classification.
- Pull-request readiness and color priority.
- Rereview-first, problems-next, approved-next, oldest-first sorting.
- Natural implementation-key ordering.
- Tracker checklist parsing across supported formats.
- Multiple trackers, unlinked PRs, and multiple linked issues.
- Body excerpt normalization and wrapping.
- External-text sanitization: control characters, ANSI stripping, NFC,
  bidirectional controls, combining marks, and Vty-measured wide characters.
- Label foreground contrast and 256-color quantization.
- Responsive layout decisions.

### Golden rendering tests

Brick renders a widget tree to a frame without a real terminal. A golden-frame
suite renders fixture boards at several terminal sizes — wide, the four-column
minimum, and narrow single-column — and compares each frame with a checked-in
snapshot. Layout and border regressions become reviewable diffs instead of
manual checks.

Every frame is drawn through the whole-application composition the dashboard
itself hands Brick, so nothing is reconstructed for the test, and every input a
frame can vary over — the fixture snapshot's timestamps, the redraw instant and
time zone, freshness, the notice line, drainer status, and the session, process
and worker maps — is pinned. Beyond the three sizes, the matrix covers the box
and open border renderers, ASCII mode, a selected card, the details overlay,
and the help overlay. Section 17's two blocking board states — the initial
loading panel and `OPEN DATA UNAVAILABLE` — are captured at every one of those
five settings, over the fixture board rather than an empty one, so what the
frames record is that a board no complete generation has published draws none
of it. Characters are the baseline; one frame additionally
records a per-cell attribute grid, because §10's split selected border is a
color contract on glyphs that are identical either way.

The frames live in `test/golden/` and are compared, never rewritten, by an
ordinary `cabal test` run. Regeneration is an explicit switch:

```console
KANBAN_UPDATE_GOLDENS=1 cabal test kanban-test
```

### Fixture tests

- GitHub GraphQL responses, including pagination and null mergeability.
- Codex app-server schemas and rate-limit responses.
- Claude `/usage` output for each supported CLI family.
- ANSI stripping and Unicode-width behavior.
- Cache compatibility and corrupt-cache recovery, including the repository
  snapshot an earlier release left behind, which the version gate reads as
  absent without decoding, rewriting, or removing it.

### Integration tests

- Temporary Git repositories with HTTPS and SSH GitHub remotes.
- Fake `gh`, `codex`, and `claude` executables placed on a temporary `PATH`.
- Worker completion and timeout delivery through `BChan`.
- Terminal resize and narrow-layout behavior.
- Clean terminal restoration after normal exit and exceptions.

### Packaging tests

One check does not fit the categories above, because what it validates is the
build system's own output rather than Kanban's behavior: the source
distribution has to be a complete checkout, and no amount of pure or fixture
testing can observe what `cabal sdist` actually puts in the archive.
`tools/test_source_distribution.py` therefore drives the local Haskell
toolchain — it runs `cabal sdist all` into a temporary directory, unpacks the
archive, and inspects the unpacked tree.

Two properties keep it from becoming a list that rots. The expected inventory
is derived from the repository's tracked file set rather than hand-maintained,
so a tool, workflow asset, or document added later must reach the archive; and
every tracked file outside the trees that ship whole carries a recorded in-or-out
decision, so a new one cannot land without a stated intent. The archive is also
checked for internal consistency: every repository-relative link in a packaged
document resolves inside the archive, and every setup or installer path those
documents name exists there.

It reads `cabal` and Git metadata, both of which the required CI job has and an
unpacked release does not, so it skips with a stated reason rather than failing
when either is absent. It writes only outside the working tree.

### Manual checks

- Common terminal emulators on supported platforms.
- Truecolor and 256-color modes.
- Large and narrow terminal dimensions.
- Real GitHub refresh against a configured repository.
- Real Codex and Claude usage refreshes without submitting a model prompt.

## 19. Implementation roadmap

### Milestone 0 — Project foundation

- Create Cabal package, executable, test suite, warnings policy, formatting, and
  basic CI.
- Add `kanban [--path DIR]` repository resolution.
- Define domain types for issues, PRs, labels, checks, trackers, usage windows,
  freshness, and errors.
- Define provider interfaces before implementing external commands.

Exit criteria: the executable parses options, resolves a repository locally,
and the pure domain/test packages build warning-clean.

### Milestone 1 — Event-driven TUI shell

- Establish Brick/Vty startup and cleanup.
- Implement the sidebar, four-column horizontal viewport, footer, focus model,
  keyboard navigation, resize behavior, and details overlay shell.
- Render fixture cards only.
- Implement Unicode, ASCII, truecolor, 256-color, and no-color themes.
- Implement split cyan/status selected borders.
- Add the golden-frame rendering suite over the fixture boards.

Exit criteria: a fixture board is attractive and fully navigable in a terminal,
with no mouse-dependent navigation, no idle redraw loop, and a passing
golden-frame suite at wide, minimum four-column, and narrow sizes.

### Milestone 2 — GitHub snapshot and workflow board

Implemented, including uncapped open-connection traversal, nested `totalCount`
decoding, amber incomplete-card outlines, and `+N` label/assignee/linked-issue
indicators.

- Implement local remote resolution and authenticated `gh` GraphQL execution.
- Fetch and paginate open issues and PRs to their final page.
- Decode labels, bodies, assignees, links, mergeability, and checks.
- Implement column classification, readiness colors, global sorting, UNLINKED,
  rich cards, details, and the configured issue/PR item guards.
- Draw the centered loading and `OPEN DATA UNAVAILABLE` states until the first
  complete open generation publishes.

Exit criteria: startup and `u` produce a correct standalone-card board for an
arbitrary GitHub repository; idle makes no network requests.

### Milestone 3 — Tracker hierarchy

Checklist hierarchy, explicit malformed-tracker diagnostics, and native GitHub
sub-issue fallback membership are implemented.

- Detect configured epic/tracker issues.
- Structure membership resolution as ordered sources, with GitHub's native
  sub-issues as the second source behind the authoritative checklist.
- Parse ordered phase/children checklists and implementation keys.
- Group children within each workflow column.
- Inherit tracker context through linked issues to PR cards.
- Handle MULTI-TRACKED PRs and malformed trackers.
- Add tracker progress and details context.

Exit criteria: the configured tracker formats render children in their
intended `A1`, `A2`, `B1`, `C1` implementation order across all four columns.

### Milestone 4 — Codex usage

Core built-in provider, cache, and the shared external-command escape hatch
are implemented. Broader version fixtures remain a follow-up slice.

- Implement on-demand app-server startup and JSON-RPC initialization.
- Request and decode account rate limits.
- Render five-hour/weekly percentages and reset timestamps.
- Add timeout, version/protocol diagnostics, fixtures, and cache support.
- Implement the external-command usage provider shared by both usage sources.

Exit criteria: `u` obtains Codex limits once, returns the provider to zero
running processes, and leaves cached data intact on failure.

### Milestone 5 — Claude usage (experimental)

Core built-in provider, independent refresh, cache integration, and live
Claude Code 2.1.211 verification implemented. Broader client-version fixtures
remain follow-up work.

- Implement private pseudo-terminal execution in the dedicated scratch
  directory, with the auto-updater disabled and known interstitials handled.
- Invoke `/usage` without submitting a model prompt.
- Strip terminal sequences and parse supported plan-usage layouts.
- Add strict version-aware fixtures, timeouts, cleanup, and diagnostics.

Exit criteria: the Claude provider obtains five-hour and weekly limits through
the official client, makes no unrelated model request, and fails closed on
unknown output. Automated CI covers fixtures without a live account; the first
release requires a successful manual refresh against the current supported
Claude version.

### Milestone 6 — Local PR drainer control

Implemented for one independently controlled LaunchAgent per canonical GitHub
repository, whose label is derived from that repository's normalized identity.

- Track the canonical drainer and controller implementations under `tools/`.
- Install stable per-user links, shared by every repository, and one
  LaunchAgent per repository through an idempotent installer that refuses
  active services and ordinary-file replacement, and never starts the drainer
  implicitly.
- Discover the controller command from the LaunchAgent plist, located through
  this repository's entry in the installer-written discovery record rather than
  a label Kanban derives.
- Partition the launchd label, plist, runtime status, service logs, dated logs,
  incidents, and `--config` selection by normalized repository identity, so
  several repositories drain independently on one account.
- Bind controller status and start/stop operations to the current repository,
  and refuse a `--repo` identity the checkout's own remote contradicts.
- Reinstall this repository's stopped LaunchAgent with that repository path
  before starting it, refuse a second concurrent drainer for the same canonical
  repository from another checkout, and retire the machine-wide singleton that
  predates per-repository jobs before its replacement starts.
- Record the installed identity in the plist and hold the launchd runner to it,
  so a configuration change after installation stops that job instead of
  re-pointing it at another repository.
- Decode the managed wrapper's structured status and incident data, including
  the complete repository-scoped set of open incidents the incidents panel
  lists alongside the newest-only summary the sidebar renders, and the
  outstanding post-merge cleanup obligations that same response projects out of
  the drainer's queue state.
- Refresh local status every ten seconds without network traffic.
- Render the bottom-left drainer control with the active border style and
  off/on/warning/error colors.
- Support both click and `d` start/stop actions with transition states.
- Merge one selected Done card with `m`, from the board or the details
  overlay, by running that drainer's own single-pull-request path — resolved
  from the Kanban-managed install directory — and refuse without invoking
  anything for an ineligible card, a merge already in flight, an unresolved
  incident, or any service state that is not a settled stop.

### Milestone 7 — Embedded issue reviews

The first direct, one-off review slice is implemented.

- Start one Codex app-server on demand and host one thread per issue.
- Stream agent and command output through the bounded Brick event channel.
- Register `kanban_prompt_user` and return structured choice/text answers.
- Register `kanban_run_claude` so Opus uses the terminal user's authenticated
  CLI outside the Codex command sandbox while remaining read-only.
- Register `kanban_github_issue` for bounded, approval-free issue reads,
  comments, and review-label transitions.
- Render hideable session overlays, status markers, approvals, feedback, and
  turn interruption without terminal emulation.
- Route canonical reviewer families through the synchronous v2 publisher while
  never starting its background daemon, resolving that publisher through the
  installer-written discovery record rather than a default each consumer
  spells out for itself.
- Advance issue review, author-brand revision, and opposite-brand rereview as
  three explicit stages using `reviewed:changes` and `reviewed:revised`
  handoffs. This issue-level handoff is unrelated to PR revision, which does
  not use a Kanban-created `reviewed:revised` handoff (see PR routing above).
- Bound transcript and input memory and stop animation ticks when turns idle.

Follow-up hardening should add broader fake app-server fixtures,
protocol-version diagnostics, and persisted review-session mapping/resume.

### Milestone 8 — Embedded issue solving

The first solve/autosolve-compatible slice is implemented.

- Capital `S` opens the model chooser and invokes the existing solve workflow,
  stopping after PR creation. Capital `A` opens the same chooser and invokes
  that ordinary solve workflow while Kanban owns the subsequent bounded
  review/fix loop. Escape cancels either chooser.
- Canonical solvers are GPT-5.4 high and Sonnet 5 high.
- Canonical opposite-brand PR reviewers are Opus 5 xhigh for Codex-origin
  work and GPT-5.6-Terra xhigh for Claude-origin work.
- Solver processes stream structured CLI output into a bounded, hideable
  overlay, retain their resumable session identifiers, and run as owned process
  groups. Solve and PR providers are owned by detached, repository-scoped
  supervisors, so quitting the TUI leaves explicitly started work visible and
  bounded rather than terminating it.
- Each detached supervisor writes a private specification, atomic heartbeat
  state, and append-only event journal under the XDG cache. A restarted TUI
  discovers only workers for its repository, reconstructs the session and
  autosolve parent state, and replays output without rerunning the provider.
  Terminal journals remain discoverable until a newer worker is durable proof
  that their workflow step was superseded, closing the crash window between a
  terminal event and its GitHub-refresh handoff, and in no case longer than
  section 16's retention window.
- A provider event the parser does not recognize — an unknown top-level type,
  an unknown Codex item, or an unknown Claude content block — contributes at
  most one bounded single-line notice: a normalized, truncated type label and
  a truncated compact payload prefix, whole-notice length included. Only a
  literal JSON string names a recognized type, so a non-string type cannot be
  coerced into a recognized branch and out of the bound. A payload with no
  usable string type, and an `error` payload with no usable string `message`,
  use the same bounded form; only a real textual error message is exempt and
  kept in full. Repeats collapse per invocation: the first few
  occurrences of each `(category, type)` are reported individually, later ones
  only accumulate a count, and one aggregate summary naming the total is
  appended before the terminal event on every path. The supervisor owns that
  aggregator, not the flow: a deadline emits the terminal envelope from its
  watchdog and then cancels the task, so the supervisor seals and reports
  before committing any outcome, and the flow seals the same state on its own
  unforced paths. Sealing is one-shot and refuses every later unknown notice,
  so exactly one side reports and a stream still draining buffered output
  cannot restart counts after the summary or append past the terminal
  envelope. Deciding and writing a notice, and sealing and writing the
  summaries, all happen under one lock, so neither a sample nor a summary can
  be in flight while the other side terminalizes over it.
  Aggregation is invocation-local and append-only, never rewriting an entry or
  carrying counts across invocations, so a chatty unrecognized type costs a
  journal and replayed transcript O(1) rather than O(n). Section 16's raw
  session log is unaffected and still records every provider line in full.
- An atomic repository-scoped lease permits only one live solve worker per
  issue and one live review/revision worker per PR. A live lease refuses the
  duplicate launch; a stale lease is retired so an interrupted worktree can be
  recovered without erasing its commits or uncommitted changes.
- The supervisor snapshots its provider process tree every 250 ms and persists
  each observed PID, process group, start identity, and command. A provider
  cannot reach terminal state while a matching recorded descendant survives,
  or while a process-snapshot failure leaves that survival unverifiable: the
  worker remains alive in an explicit red `orphaned` state, visible after a
  TUI restart, until a successful snapshot confirms the child exited or the
  user kills it. A snapshot failure is always reported as an explicit
  failure, never silently treated as a verified empty survivor list.
- Persistent workers have a four-hour hard deadline on their active task and
  provider execution as a whole, measured from worker creation rather than
  from whenever the watchdog thread happened to start — an already-overdue
  deadline fires immediately. On firing, the watchdog kills the current
  provider group and every still-matching recorded census group, cancels the
  worker's own task execution (so a hang before any provider ever starts
  cannot keep the supervisor and lease alive indefinitely), and commits one
  canonical, externally visible `persistent worker deadline exceeded`
  outcome — shown distinctly from a generic provider failure in worker
  state, the journal, session/card activity, and the process inspector,
  rather than collapsing to it. A provider that registers after the deadline
  has already fired is killed immediately through the same stop guard. The
  process inspector marks persistent workers and shows the remaining bound.
  That kill deadline is distinct from verified terminal state and lease
  release, which require a successful snapshot proving every recorded
  descendant is gone — a persistent process-snapshot failure can keep a
  worker orphaned, with the deadline outcome recorded as pending, and its
  lease held well beyond four hours, since the watchdog is not an outer
  bound on termination verification. If a stale supervisor is confirmed
  dead, Kanban kills its recorded provider process
  group and all still-matching census groups, then publishes a visible
  terminal failure once a snapshot verifies they are gone; an unresolved
  verification leaves it visibly unresolved for a later recovery pass to
  retry. `x` terminates those groups and the supervisor with TERM/KILL
  escalation and verifies the supervisor stopped before writing terminal
  state; if a snapshot failure leaves recorded descendants unverified, it
  reports a visible diagnostic and retains the lease instead, and a later
  successful snapshot completes the pending "killed by user" outcome.
- App-server issue revisions and the synchronous canonical issue gate remain
  TUI-owned for now. Quitting is refused while either has a live turn, avoiding
  accidental invisible work until their protocol state is also durable.
- Live solve and PR overlays render the animated activity pip beside a
  provider-independent activity timer. Codex command events and Claude Bash
  tool calls expose their sanitized one-line command, keeping long silent
  builds and probes visibly distinct from a frozen agent.
- Ctrl-C in a live solve or PR overlay sends INT to the current process group.
  Once it exits, the overlay becomes an input prompt and Enter resumes the same
  returned agent session with the user's corrective guidance.
- Active autosolve cards use a blue outline. A terminal
  `KANBAN_NEEDS_INPUT: <question>` handoff turns either workflow orange; an
  answer in the overlay resumes the same agent session. Process errors are red
  and completed sessions are white.
- Both modes preserve the existing solve contract: readiness gate, worktree
  rules, effective specification, targeted testing, and PR creation. Autosolve
  binds only to a newly linked PR with the selected solver's origin marker,
  launches a fresh opposite-brand reviewer, and resumes the original solver to
  run the canonical `pr-revise` workflow on `reviewed:changes`. Because
  `pr-revise` invokes the canonical rereview itself, Kanban reads the
  resulting verdict directly off the PR's labels rather than waiting on a
  Kanban-created `reviewed:revised` handoff, and loops back into another
  `pr-revise` round on a fresh `reviewed:changes` verdict. Approval or five
  review rounds terminates the loop; Kanban never merges.
- Kanban refreshes the board after startup and at explicit workflow handoffs
  rather than polling the solver or GitHub continuously.
- Linked issue and PR cards remain visible simultaneously so the issue stays
  Active while its new PR advances through Reviewing and Done.
- `p` opens a scrollable process/session inspector. Each retained session has a
  one-line provider, lifecycle state, activity summary, and shortened session
  identifier; live solve and PR rows include the current activity elapsed time.
  Enter opens its existing interactive overlay, while `x`
  terminates the selected worker and provider process groups and descendants. Completed and
  latest failed or completed session for each item remains available for
  debugging until replacement or exit.

### Milestone 9 — Hardening and release

Automated hardening and installation prerequisites were last audited on
2026-08-07. Config loading and per-repository overrides have shared Haskell and
Python coverage for canonical repository selection, inheritance, validation,
and array replacement. Stale caches, missing tools, authentication failures,
signals, and subprocess cleanup have deterministic fixtures and process-group
integration coverage. Installation instructions and a clean temporary
`cabal install exe:kanban` exercise are complete.

The remaining manual checks and release publication are now the canonical
`REL-1` through `REL-4` slices in the processing ledger and delivery plan. This
milestone is implementation history rather than a second status checklist.

Exit criteria: the application is warning-clean, fixture/integration tests pass,
idle CPU is effectively zero apart from the inexpensive local service status
timer, and every network call is attributable to startup or an explicit
refresh key.

## 20. Deferred ideas

- Configurable keybindings.
- OSC 52 URL copy support for remote terminals.
- Optional `gh issue view --web`/`gh pr view --web` local-only action.
- GitHub mutations such as assignment or label changes.
- Automatic refresh intervals, disabled by default if ever added.
- Multi-repository aggregation.
- Forge adapters for non-GitHub repositories.
- A merged-work history view separate from the live Done column.

These are intentionally outside the first release so the core remains a small,
predictable, read-only dashboard.

## 21. Release evidence

Permanent records of the manual release gates D-1 requires, one subsection per
gate (D-13). These outlive the `Epic contract` through `Delivery plan`
scaffolding above.

### REL-1. Installed performance calibration, macOS, 2026-08-13

All six D-4 gates pass. Mean tree CPU over the idle minute was **1.53%**
against a 2% ceiling, peak tree resident memory **69.59 MiB** against 512 MiB,
and all three launches reached the GitHub-populated board in **under 1.3
seconds** against a 10 second ceiling.

The margin is narrower than the headline suggests, and the reason is the one
D-10 anticipated. The PR drainer's ten-second status poll accounted for
**95.6% of all CPU consumed during the idle minute**; Kanban's own steady-state
cost was 0.0673% mean. D-10 estimated the poll at "about 0.07 s of CPU every
ten seconds, roughly 0.7% of a core". The measured cost is **0.1464 s per
poll, 1.46% mean** — roughly twice that estimate, consuming about 73% of D-4's
entire 2% budget. This did not fail the gate and is not treated as one, but it
is the number a later release should tighten, and it is recorded here so that
tightening can start from evidence rather than from the estimate.

#### Scope reconciliation: process group versus process tree

D-10 and the Verification strategy above both say "process group". This record
samples the **PPID process tree** rooted at the Kanban PID instead. The two are
not the same here: Kanban spawns its managed children as their own process
group leaders (`src/Kanban/Drainer.hs`, `src/Kanban/Process.hs`), so a
process-group sample would omit exactly the drainer controller D-10 exists to
capture. The tree reading is therefore the one that satisfies D-10's intent,
and "Kanban and its children" is measured as the tree. Later records under this
section use the same reading.

#### Build provenance

Every measurement below used an executable installed from a `cabal sdist`
archive into a clean temporary directory (D-12). No working-tree installation
was measured.

| Item | Value |
| --- | --- |
| Commit (`git rev-parse HEAD`) | `878f8a2ed6a8d32c4066ead3db9e4d666bbde2bd` |
| Working tree at that commit | `git status --porcelain=v1 --untracked-files=all` returned empty |
| Archive | `kanban-1.0.0.0.tar.gz` |
| Installed `--version` | `kanban 1.0.0.0` |
| Install directory | a temporary directory; neither `~/.local/bin` nor `~/.cabal/bin` was used or written |

```console
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
BUILD_COMMIT="$(git rev-parse HEAD)"
TMP="$(mktemp -d)"
mkdir -p "$TMP/unpacked" "$TMP/bin"
cabal sdist all --builddir "$TMP/dist" --output-directory "$TMP/sdist"
tar -xzf "$TMP"/sdist/kanban-*.tar.gz -C "$TMP/unpacked"
cd "$TMP"/unpacked/kanban-*
cabal install exe:kanban --installdir "$TMP/bin" --install-method=copy
"$TMP/bin/kanban" --version
```

The issue that commissioned this record predicted `kanban 0.1.0.0`. The
recorded output is `kanban 1.0.0.0` because the version bump to 1.0.0.0 landed
on the default branch after that issue was written; D-5 fixes the first release
at 1.0.0.0, so the observed string is the correct one and the issue's expected
string was stale.

#### Measurement environment

| Item | Value |
| --- | --- |
| macOS | 26.6 (build 25G5065a) |
| Architecture | arm64, Apple M3 Max, 16 logical CPUs |
| Host terminal | Ghostty 1.3.2-HEAD-+bb30526 |
| tmux | 3.5a |
| Pane geometry | 200 columns × 50 rows, detached session |
| `TERM` inside the pane | `screen-256color` |
| Monotonic clock | `mach_absolute_time()`, resolution 4.1667e-08 s (41.67 ns) |
| Mach timebase | `numer=125 denom=3`, i.e. 41.6667 ns per absolute-time unit |
| Toolchain | GHC 9.12.2, cabal-install 3.16.1.0 |
| Repository identity | `coghex/kanban` |
| Checkout path | `~/worktrees/coghex/kanban/issue-269-release-evidence`, a linked worktree of that repository, passed as `--path` (home abbreviated per D-8) |
| Worker sessions attached | none — the per-repository worker cache directory did not exist, so `discoverWorkers` found nothing to attach |
| Cache precondition | warm; `~/.cache/kanban` held `claude-probe`, `gh-groups`, `logs`, `repos`, `usage-command`, `usage.json`, with `repos/coghex-kanban.json` present before every launch |
| Config precondition | `~/.config/kanban/settings.json` present |
| launchd drainer job | `com.coghex.drain-prs.coghex.kanban` loaded throughout, before and after the measured window |

The "no worker sessions attached" precondition matters: startup attaches every
discovered worker and forks a 200 ms monitor poll per worker, which would both
add root CPU and produce non-controller child activity that invalidates the
drainer attribution below.

The drainer controller resolved from the loaded job's `ProgramArguments`,
rebased onto this checkout, and invoked with `--json status` appended last, is:

```text
<python3.14 from the launchd job> \
  <Application Support>/kanban/pr-drainer/drain_prs_service.py \
  --path <checkout> --repo coghex/kanban --json status
```

The controller is resolved from the launchd job, not from the measured sdist
artifact; it is not part of the installed archive. One detail matters for
classification: the interpreter the job names is a macOS framework Python whose
live processes report the `Python.app/Contents/MacOS/Python` stub as their
executable, a second spelling of the same installation. Matching the plist's
own path string against a live child therefore never fires, and the classifier
below matches on the interpreter installation directory plus the exact argv
tail instead.

#### Method: the CPU and memory probe

CPU is measured with a temporary, unprivileged `proc_pid_rusage` probe created
outside the checkout. It resolves the live PPID tree rooted at the Kanban PID,
keys every process by PID **and** `ri_proc_start_abstime` so PID reuse cannot
corrupt a delta, reads self user/system and accumulated child user/system CPU
for every live member, converts Mach absolute-time units with
`mach_timebase_info`, and retries a boundary reading until two consecutive
censuses agree on the set of process identities.

Aggregate cumulative tree CPU is the sum of self **and accumulated child** CPU
over the stable live tree. The accumulated child counters are what make the
ten-second drainer poll measurable at all: a controller that starts and exits
between two one-second boundaries is never seen alive, but its CPU folds into
its parent's accumulated-child counters when it is reaped, so summing
self + child over the live tree neither loses it nor counts it twice. In this
run 6 polls occurred and only 1 was ever caught alive by a boundary census;
the other 5 are present in the totals solely through those counters.

The probe's synthetic self-test must pass before any Kanban measurement:

```console
python3 "$TMP/measure_tree.py" --self-test
```

Recorded output:

```text
mach_timebase_info: numer=125 denom=3 (41.6667 ns per unit)
reaped child: burned ~0.40s, retained 0.4198s -> PASS
reaped grandchild: burned ~0.40s, retained 0.4457s -> PASS
timebase conversion: 0.4198s lies in [0.20, 1.20] -> PASS
pid/start identity: pid 34449 start 10593681876078 matches, start 10593681876079 is rejected -> PASS
stable reading: settled after 1 census comparison(s), 1 live process(es)
SELF-TEST PASSED: reaped-child and reaped-grandchild CPU retained, Mach timebase conversion applied, PID/start-identity matching enforced
```

The timebase check has teeth on this host: one absolute-time unit is 41.67 ns,
so an unconverted reading would be about 24× too small and would fall outside
the stated plausibility band.

The probe is recreated exactly by this here-document:

```console
cat > "$TMP/measure_tree.py" <<'PROBE'
#!/usr/bin/env python3
"""REL-1 process-tree CPU/RSS probe for an installed Kanban (macOS, unprivileged).

Measures the PPID tree rooted at a Kanban PID using proc_pid_rusage(2), keying
every process by (pid, ri_proc_start_abstime) so PID reuse cannot corrupt a
delta, and defining aggregate cumulative tree CPU as the sum of self and
accumulated-child CPU over the stable live tree. Accumulated child counters are
required because they retain CPU from descendants reaped between boundaries.

Temporary measurement artifact for issue #269. Not part of the repository.
"""

import argparse
import ctypes
import ctypes.util
import errno
import json
import os
import subprocess
import sys
import time

# ---------------------------------------------------------------- libproc FFI

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)

RUSAGE_INFO_V4 = 4
PROC_PIDPATHINFO_MAXSIZE = 4096
PROC_PIDTBSDINFO = 3


class MachTimebaseInfo(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


class RusageInfoV4(ctypes.Structure):
    """<sys/resource.h> struct rusage_info_v4.

    Only the v0/v1 prefix is read; the tail is declared so the buffer the
    kernel fills for RUSAGE_INFO_V4 is exactly the right size.
    """

    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
        ("ri_cpu_time_qos_default", ctypes.c_uint64),
        ("ri_cpu_time_qos_maintenance", ctypes.c_uint64),
        ("ri_cpu_time_qos_background", ctypes.c_uint64),
        ("ri_cpu_time_qos_utility", ctypes.c_uint64),
        ("ri_cpu_time_qos_legacy", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_initiated", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_interactive", ctypes.c_uint64),
        ("ri_billed_system_time", ctypes.c_uint64),
        ("ri_serviced_system_time", ctypes.c_uint64),
        ("ri_logical_writes", ctypes.c_uint64),
        ("ri_lifetime_max_phys_footprint", ctypes.c_uint64),
        ("ri_instructions", ctypes.c_uint64),
        ("ri_cycles", ctypes.c_uint64),
        ("ri_billed_energy", ctypes.c_uint64),
        ("ri_serviced_energy", ctypes.c_uint64),
        ("ri_interval_max_phys_footprint", ctypes.c_uint64),
        ("ri_runnable_time", ctypes.c_uint64),
    ]


class ProcBsdInfo(ctypes.Structure):
    """<sys/proc_info.h> struct proc_bsdinfo — read only for pbi_ppid."""

    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libc.proc_pid_rusage.restype = ctypes.c_int
libc.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
libc.proc_listallpids.restype = ctypes.c_int
libc.proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.c_void_p,
    ctypes.c_int,
]
libc.proc_pidinfo.restype = ctypes.c_int
libc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libc.proc_pidpath.restype = ctypes.c_int
libc.mach_timebase_info.argtypes = [ctypes.POINTER(MachTimebaseInfo)]
libc.mach_timebase_info.restype = ctypes.c_int


def mach_timebase():
    """Mach absolute-time units -> nanoseconds, as (numer, denom)."""
    info = MachTimebaseInfo()
    if libc.mach_timebase_info(ctypes.byref(info)) != 0:
        raise RuntimeError("mach_timebase_info failed")
    if info.numer == 0 or info.denom == 0:
        raise RuntimeError(f"implausible mach timebase {info.numer}/{info.denom}")
    return info.numer, info.denom


TIMEBASE_NUMER, TIMEBASE_DENOM = mach_timebase()


def abs_to_seconds(units):
    """Convert Mach absolute-time units to seconds via mach_timebase_info."""
    return units * TIMEBASE_NUMER / TIMEBASE_DENOM / 1e9


def rusage(pid):
    """proc_pid_rusage(pid, RUSAGE_INFO_V4). None when the process is gone."""
    buffer = RusageInfoV4()
    result = libc.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(buffer))
    if result != 0:
        code = ctypes.get_errno()
        if code in (errno.ESRCH, errno.EPERM, errno.EINVAL):
            return None
        raise OSError(code, f"proc_pid_rusage({pid}) failed: {os.strerror(code)}")
    return buffer


def proc_path(pid):
    buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    size = libc.proc_pidpath(pid, buffer, PROC_PIDPATHINFO_MAXSIZE)
    if size <= 0:
        return None
    return buffer.value.decode("utf-8", "replace")


def parent_map():
    """{pid: ppid} for every process this user may inspect."""
    count = libc.proc_listallpids(None, 0)
    if count <= 0:
        raise OSError(ctypes.get_errno(), "proc_listallpids failed")
    capacity = count + 512
    buffer = (ctypes.c_int32 * capacity)()
    size = libc.proc_listallpids(buffer, ctypes.sizeof(buffer))
    if size <= 0:
        raise OSError(ctypes.get_errno(), "proc_listallpids failed")
    pids = [buffer[index] for index in range(size // ctypes.sizeof(ctypes.c_int32))]
    parents = {}
    info = ProcBsdInfo()
    for pid in pids:
        if pid <= 0:
            continue
        written = libc.proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info)
        )
        if written == ctypes.sizeof(info):
            parents[pid] = info.pbi_ppid
    return parents


def descendants(root):
    """Live PPID tree rooted at `root`, root included."""
    parents = parent_map()
    children = {}
    for pid, ppid in parents.items():
        children.setdefault(ppid, []).append(pid)
    tree, frontier = [], [root]
    seen = set()
    while frontier:
        pid = frontier.pop()
        if pid in seen:
            continue
        seen.add(pid)
        tree.append(pid)
        frontier.extend(children.get(pid, []))
    return sorted(tree)


def argv_of(pid):
    """Best-effort argv for classifying a child. Empty list when unavailable."""
    try:
        output = subprocess.run(
            ["/bin/ps", "-o", "command=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return output.stdout.strip() if output.returncode == 0 else ""

# ------------------------------------------------------------------- census


def census(root, want_argv=False):
    """One reading of the whole live tree.

    Returns (identities, records). `identities` is the frozenset of
    (pid, ri_proc_start_abstime) pairs — the stability key. `records` carries
    the per-process CPU/RSS values.
    """
    identities, records = set(), {}
    parents = parent_map()
    for pid in descendants(root):
        usage = rusage(pid)
        if usage is None:
            continue
        identity = (pid, usage.ri_proc_start_abstime)
        identities.add(identity)
        records[identity] = {
            "pid": pid,
            "ppid": parents.get(pid),
            "start_abstime": usage.ri_proc_start_abstime,
            "self_cpu_seconds": abs_to_seconds(
                usage.ri_user_time + usage.ri_system_time
            ),
            "child_cpu_seconds": abs_to_seconds(
                usage.ri_child_user_time + usage.ri_child_system_time
            ),
            "resident_bytes": usage.ri_resident_size,
            "command": argv_of(pid) if want_argv else None,
        }
    return frozenset(identities), records


def stable_reading(root, retries=12):
    """A boundary reading whose before/after censuses agree on tree identity.

    Retries until two consecutive censuses expose the same set of
    (pid, start_abstime) identities, so a process that appears or exits across
    the reading cannot land a half-counted value in a delta.
    """
    attempts = 0
    before_ids, before = census(root, want_argv=True)
    while attempts < retries:
        attempts += 1
        after_ids, after = census(root, want_argv=True)
        if before_ids == after_ids:
            aggregate = sum(
                record["self_cpu_seconds"] + record["child_cpu_seconds"]
                for record in after.values()
            )
            resident = sum(record["resident_bytes"] for record in after.values())
            return {
                "monotonic": time.monotonic(),
                "wall_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "attempts": attempts,
                "aggregate_cpu_seconds": aggregate,
                "tree_resident_bytes": resident,
                "tree_resident_mib": resident / 1048576,
                "processes": list(after.values()),
                "identities": sorted((pid, start) for pid, start in after_ids),
            }
        before_ids, before = after_ids, after
    raise RuntimeError(
        f"tree identity did not stabilise for pid {root} after {retries} retries"
    )

# ------------------------------------------------------- drainer attribution


def classify_controller(record, root, interpreter_root, argv_tail):
    """Is this live *direct child* the drainer controller's `--json status` call?

    Identity has three parts, all required:

      * it is a direct child of the Kanban root PID;
      * its executable lies inside the interpreter installation the loaded
        launchd job names. A macOS framework Python execs the
        `Python.app/Contents/MacOS/Python` stub, so the live executable path is
        a second spelling of the interpreter the plist records rather than the
        plist path itself — matching the plist string alone never fires;
      * its command ends with the exact resolved argv tail, which is the
        controller script plus the `--path`/`--repo` pair Kanban rebases onto
        it plus the `--json status` appended last at invocation.
    """
    if record.get("ppid") != root:
        return False
    command = (record.get("command") or "").rstrip()
    if not command:
        return False
    if interpreter_root and not command.startswith(interpreter_root):
        return False
    return command.endswith(argv_tail)

# ----------------------------------------------------------------- self-test


BURN_CHILD = (
    "import time\n"
    "deadline = time.process_time() + {seconds}\n"
    "while time.process_time() < deadline:\n"
    "    pass\n"
)

SPAWN_GRANDCHILD = (
    "import subprocess, sys\n"
    "subprocess.run([sys.executable, '-c', {burn!r}], check=True)\n"
)


def own_child_cpu():
    usage = rusage(os.getpid())
    return abs_to_seconds(usage.ri_child_user_time + usage.ri_child_system_time)


def self_test():
    burn_seconds = 0.40
    tolerance = 0.5  # retained CPU must be at least half the requested burn
    results = {}
    failures = []

    print(f"mach_timebase_info: numer={TIMEBASE_NUMER} denom={TIMEBASE_DENOM} "
          f"({TIMEBASE_NUMER / TIMEBASE_DENOM:.6g} ns per unit)")
    results["timebase"] = {"numer": TIMEBASE_NUMER, "denom": TIMEBASE_DENOM}

    # 1. CPU from a short-lived, reaped CHILD is retained after it is gone.
    before = own_child_cpu()
    child = subprocess.run(
        [sys.executable, "-c", BURN_CHILD.format(seconds=burn_seconds)]
    )
    assert child.returncode == 0
    after = own_child_cpu()
    child_retained = after - before
    results["reaped_child_cpu_seconds"] = child_retained
    ok_child = child_retained >= burn_seconds * tolerance
    failures += [] if ok_child else ["reaped child CPU was not retained"]
    print(f"reaped child: burned ~{burn_seconds:.2f}s, "
          f"retained {child_retained:.4f}s -> {'PASS' if ok_child else 'FAIL'}")

    # 2. CPU from a short-lived, reaped GRANDCHILD is retained too: the child
    #    folds its own accumulated-child counters into ours when it is reaped.
    before = own_child_cpu()
    grandparent = subprocess.run(
        [
            sys.executable,
            "-c",
            SPAWN_GRANDCHILD.format(
                burn=BURN_CHILD.format(seconds=burn_seconds)
            ),
        ]
    )
    assert grandparent.returncode == 0
    after = own_child_cpu()
    grandchild_retained = after - before
    results["reaped_grandchild_cpu_seconds"] = grandchild_retained
    ok_grandchild = grandchild_retained >= burn_seconds * tolerance
    failures += [] if ok_grandchild else ["reaped grandchild CPU was not retained"]
    print(f"reaped grandchild: burned ~{burn_seconds:.2f}s, "
          f"retained {grandchild_retained:.4f}s -> "
          f"{'PASS' if ok_grandchild else 'FAIL'}")

    # 3. Mach timebase conversion is actually applied. On this arm64 host one
    #    unit is 41.67 ns, so an unconverted reading would be ~24x too small;
    #    the plausibility band below is what makes that a real check.
    plausible = burn_seconds * 0.5 <= child_retained <= burn_seconds * 3.0
    results["timebase_conversion_plausible"] = plausible
    failures += [] if plausible else ["converted CPU value is not plausible"]
    print(f"timebase conversion: {child_retained:.4f}s lies in "
          f"[{burn_seconds * 0.5:.2f}, {burn_seconds * 3.0:.2f}] -> "
          f"{'PASS' if plausible else 'FAIL'}")

    # 4. PID/start-identity matching is enforced: a tampered start_abstime for
    #    a live PID must not match the identity the census records for it.
    identities, records = census(os.getpid())
    live = [identity for identity in identities if identity[0] == os.getpid()]
    assert len(live) == 1
    genuine = live[0]
    tampered = (genuine[0], genuine[1] + 1)
    enforced = tampered not in identities and genuine in identities
    results["pid_start_identity_enforced"] = enforced
    failures += [] if enforced else ["PID/start-identity matching is not enforced"]
    print(f"pid/start identity: pid {genuine[0]} start {genuine[1]} matches, "
          f"start {tampered[1]} is rejected -> "
          f"{'PASS' if enforced else 'FAIL'}")

    # 5. The stability retry loop produces a usable reading.
    reading = stable_reading(os.getpid())
    results["stable_reading_attempts"] = reading["attempts"]
    print(f"stable reading: settled after {reading['attempts']} census "
          f"comparison(s), {len(reading['processes'])} live process(es)")

    if failures:
        print("SELF-TEST FAILED: " + "; ".join(failures))
        return 1
    print("SELF-TEST PASSED: reaped-child and reaped-grandchild CPU retained, "
          "Mach timebase conversion applied, PID/start-identity matching enforced")
    return 0

# ---------------------------------------------------------------- measurement


def measure(arguments):
    root = arguments.pid
    path = proc_path(root)
    if arguments.expect_executable:
        if path != arguments.expect_executable:
            print(
                f"root pid {root} runs {path!r}, not the archive-installed "
                f"{arguments.expect_executable!r}; refusing to measure",
                file=sys.stderr,
            )
            return 2
        print(f"root pid {root} verified as {path}")

    interpreter_root = arguments.controller_interpreter_root
    argv_tail = arguments.controller_argv_tail
    boundaries, pane_snapshots = [], []

    def capture_pane():
        if not arguments.tmux_target:
            return None
        try:
            output = subprocess.run(
                ["tmux", "capture-pane", "-p", "-t", arguments.tmux_target],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        return output.stdout if output.returncode == 0 else None

    total = arguments.intervals + 1
    for index in range(total):
        if index:
            target = start_monotonic + index * arguments.interval_seconds
            delay = target - time.monotonic()
            if delay > 0:
                time.sleep(delay)
        reading = stable_reading(root)
        if index == 0:
            start_monotonic = reading["monotonic"]
        boundaries.append(reading)
        pane_snapshots.append(capture_pane())
        print(
            f"boundary {index:2d}/{arguments.intervals}  "
            f"cpu={reading['aggregate_cpu_seconds']:.6f}s  "
            f"rss={reading['tree_resident_mib']:.1f}MiB  "
            f"procs={len(reading['processes'])}  "
            f"attempts={reading['attempts']}",
            flush=True,
        )

    intervals = []
    for index in range(1, len(boundaries)):
        previous, current = boundaries[index - 1], boundaries[index]
        elapsed = current["monotonic"] - previous["monotonic"]
        delta = current["aggregate_cpu_seconds"] - previous["aggregate_cpu_seconds"]
        intervals.append(
            {
                "index": index,
                "elapsed_seconds": elapsed,
                "cpu_delta_seconds": delta,
                "tree_cpu_percent": 100.0 * delta / elapsed if elapsed > 0 else 0.0,
                "tree_resident_mib": current["tree_resident_mib"],
                "process_count": len(current["processes"]),
            }
        )

    total_elapsed = sum(interval["elapsed_seconds"] for interval in intervals)
    total_cpu = sum(interval["cpu_delta_seconds"] for interval in intervals)
    weighted_mean = 100.0 * total_cpu / total_elapsed if total_elapsed > 0 else 0.0

    high_run, worst_run = 0, 0
    for interval in intervals:
        high_run = high_run + 1 if interval["tree_cpu_percent"] > 5.0 else 0
        worst_run = max(worst_run, high_run)

    peak_mib = max(boundary["tree_resident_mib"] for boundary in boundaries)

    # Drainer attribution: the root's accumulated-child CPU baselined at the
    # start of the window, plus any live controller child at each boundary.
    def classified(boundary):
        value, live = 0.0, 0
        for record in boundary["processes"]:
            if record["pid"] == root:
                value += record["child_cpu_seconds"]
            elif classify_controller(record, root, interpreter_root, argv_tail):
                value += record["self_cpu_seconds"] + record["child_cpu_seconds"]
                live += 1
        return value, live

    controller_identities = set()
    first_classified, _ = classified(boundaries[0])
    last_classified, _ = classified(boundaries[-1])
    controller_sightings = []
    non_controller_children = []
    for index, boundary in enumerate(boundaries):
        for record in boundary["processes"]:
            if record["pid"] == root:
                continue
            command = record.get("command") or ""
            if classify_controller(record, root, interpreter_root, argv_tail):
                identity = (record["pid"], record["start_abstime"])
                controller_identities.add(identity)
                controller_sightings.append(
                    {"boundary": index, "pid": record["pid"], "command": command})
            else:
                non_controller_children.append(
                    {"boundary": index, "pid": record["pid"], "command": command}
                )

    diffs = []
    for index in range(1, len(pane_snapshots)):
        previous, current = pane_snapshots[index - 1], pane_snapshots[index]
        if previous is None or current is None:
            continue
        if previous != current:
            previous_lines, current_lines = previous.splitlines(), current.splitlines()
            changed = [
                {
                    "line": line_index + 1,
                    "before": before,
                    "after": after,
                }
                for line_index, (before, after) in enumerate(
                    zip(previous_lines, current_lines)
                )
                if before != after
            ]
            diffs.append({"boundary": index, "changed_lines": changed})

    document = {
        "root_pid": root,
        "root_executable": path,
        "timebase": {"numer": TIMEBASE_NUMER, "denom": TIMEBASE_DENOM},
        "controller_interpreter_root": arguments.controller_interpreter_root,
        "controller_argv_tail": arguments.controller_argv_tail,
        "boundaries": boundaries,
        "intervals": intervals,
        "summary": {
            "boundary_count": len(boundaries),
            "interval_count": len(intervals),
            "total_elapsed_seconds": total_elapsed,
            "total_cpu_seconds": total_cpu,
            "wall_weighted_mean_cpu_percent": weighted_mean,
            "max_interval_cpu_percent": max(
                interval["tree_cpu_percent"] for interval in intervals
            ),
            "longest_run_above_5_percent": worst_run,
            "peak_tree_resident_mib": peak_mib,
            "drainer_classified_cpu_seconds": last_classified - first_classified,
            "drainer_controller_identity": {
                "interpreter_root": interpreter_root,
                "argv_tail": argv_tail,
            },
            "drainer_observed_poll_count": len(controller_identities),
            "drainer_controller_sightings": controller_sightings,
            "non_controller_child_sightings": non_controller_children,
            "pane_diff_count": len(diffs),
        },
        "pane_diffs": diffs,
        "pane_snapshots": pane_snapshots if arguments.keep_snapshots else None,
    }

    if arguments.output:
        with open(arguments.output, "w", encoding="utf-8") as handle:
            json.dump(document, handle, indent=2)
        print(f"wrote {arguments.output}")

    summary = document["summary"]
    print(json.dumps(summary, indent=2, default=str)[:4000])
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--intervals", type=int, default=60)
    parser.add_argument("--interval-seconds", type=float, default=1.0)
    parser.add_argument("--tmux-target")
    parser.add_argument("--output")
    parser.add_argument("--controller-interpreter-root", default="")
    parser.add_argument("--controller-argv-tail", default="")
    parser.add_argument("--expect-executable", default="")
    parser.add_argument("--keep-snapshots", action="store_true")
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test()
    if arguments.pid is None:
        parser.error("--pid is required unless --self-test is given")
    return measure(arguments)


if __name__ == "__main__":
    sys.exit(main())
PROBE
```

The recorded 61-boundary measurement was produced by exactly this invocation,
run after the settling period below completed:

```console
python3 "$TMP/measure_tree.py" \
  --pid "$KANBAN_PID" \
  --intervals 60 \
  --interval-seconds 1 \
  --tmux-target "$SESSION" \
  --expect-executable "$TMP/bin/kanban" \
  --controller-interpreter-root \
    "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/" \
  --controller-argv-tail \
    "$HOME/Library/Application Support/kanban/pr-drainer/drain_prs_service.py --path $ROOT --repo coghex/kanban --json status" \
  --keep-snapshots \
  --output "$TMP/rel1-measurement.json"
```

`$TMP` and `$ROOT` are the build-provenance variables above, `$SESSION` and
`$KANBAN_PID` come from the launch block below; for this record they were the
third launch's session and its pane PID `35969`. `$HOME` is written as the
variable rather than expanded, per D-8.

Two of those arguments are the checks the review method depends on, so their
effect is recorded rather than assumed:

- `--expect-executable` made the probe resolve the root PID's executable with
  `proc_pidpath` and refuse to measure anything else **before** its first
  boundary reading; the run's output records `root_pid` 35969 with
  `root_executable` equal to the archive-installed `$TMP/bin/kanban`. Without
  that check, a pane whose `exec` had failed would have yielded a full set of
  numbers describing `/bin/sh` while still satisfying the build-provenance
  record above.
- `--controller-interpreter-root` and `--controller-argv-tail` together are the
  controller identity described under Measurement environment: the interpreter
  installation the launchd job names, and the exact resolved argv tail. Both
  are required, and a live direct child must match both to be classified as a
  poll rather than as attribution-invalidating child activity.

`--keep-snapshots` retained the 61 pane captures that the content-churn diffs
below were computed from.

#### Startup: three consecutive launches

Each launch started a monotonic clock immediately before `tmux new-session`,
captured the pane every 100 ms, and stopped only at the first capture that
showed **both** the declared known card and `board: updated …`. The declared
known card is issue **#268**, "Epic: Complete Kanban's first-release readiness
gate", matched by the literal pane text `#268  Epic: Complete Kanban's`. A
capture cap of 60 seconds — comfortably beyond the 10 second ceiling — bounded
each launch; a launch reaching the cap, or reaching a terminal non-`updated`
footer such as `board: unavailable`, `board: unsupported`, or `board: stale ·
last updated …`, is recorded as a failed launch and re-run under D-11 rather
than waited on indefinitely. No launch hit either outcome.

```console
SESSION="rel1-$$"
tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  "exec \"$TMP/bin/kanban\" --path \"$ROOT\""
KANBAN_PID="$(tmux display-message -p -t "$SESSION" '#{pane_pid}')"
tmux capture-pane -t "$SESSION" -p
```

| Launch | Outcome | Elapsed to populated board | ≤ 10 s | First non-blank frame | Captures | Cadence mean / max |
| ---: | --- | ---: | :---: | ---: | ---: | --- |
| 1 | populated | 0.9050 s | yes | 0.1025 s | 9 | 0.1003 s / 0.1032 s |
| 2 | populated | 1.2030 s | yes | 0.1010 s | 12 | 0.1002 s / 0.1041 s |
| 3 | populated | 0.9025 s | yes | 0.1051 s | 9 | 0.0997 s / 0.1049 s |

No cache-backed frame stopped the clock, and this is structural rather than
lucky: `startBoardRefresh` sets board freshness to `Loading` synchronously
before forking the fetch, so the first drawn frame shows `board: refreshing…`
even when a warm cache loaded `Fresh`. Every launch above showed
`board: refreshing…` from its first non-blank frame onward — 8, 11 and 8
consecutive frames respectively — and the card itself appeared only in the
final, stopping capture.

All three launches ran back to back under the same declared warm-cache
precondition, re-read before each launch. An earlier orientation launch,
outside this series, was used only to choose the known card. Three earlier
rehearsals of the series were discarded; they are itemised under Conclusions
below.

#### Settling sequence for the measured window

The third launch is the measured one. Requirement ordering here is D-4's plus
the settling rules: confirm terminal states, one explicit `u`, a harmless UI
action while that refresh is still in flight, terminal states again, and only
then the full 30 second settling period. The idle minute begins after that
period, not after the `u`.

| Wall clock (UTC) | t (s) | Event |
| --- | ---: | --- |
| 2026-08-13T22:59:44Z | 1.991 | board `updated now`, Codex and Claude both terminal (pre-refresh check) |
| 2026-08-13T22:59:44Z | 1.996 | explicit `u` sent |
| 2026-08-13T22:59:44Z | 2.112 | refresh observed active (`board: refreshing…`) |
| 2026-08-13T22:59:44Z | 2.478 | Help overlay opened **during** the active refresh and rendered |
| 2026-08-13T22:59:45Z | 2.842 | Help overlay closed with `Esc` |
| 2026-08-13T22:59:50Z | 7.763 | board, Codex and Claude all terminal again |
| 2026-08-13T22:59:50Z | 7.763 | 30 s settling period began |
| 2026-08-13T23:00:20Z | 37.770 | settling complete; idle window permitted to begin |

The Help overlay opened and drew while the board footer still read
`board: refreshing…`, and closed on `Esc`; that is the recorded evidence that
the UI stayed responsive during the explicit refresh.

#### Idle window: CPU

61 boundary readings produced exactly 60 elapsed intervals targeted at one
second each. Every interval uses its own actual monotonic elapsed time:

`tree CPU % = 100 × aggregate CPU-time delta / elapsed wall time`

Total elapsed 60.0098 s; total aggregate tree CPU 0.918990 s. Interval
durations ranged 0.9911–1.0120 s, mean 1.0002 s. Every one of the 61 boundary
readings stabilised on its first census comparison.

| # | elapsed (s) | CPU delta (s) | tree CPU % | # | elapsed (s) | CPU delta (s) | tree CPU % |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 1.0120 | 0.000000 | 0.000 | 31 | 0.9997 | 0.000000 | 0.000 |
| 2 | 1.0015 | 0.000000 | 0.000 | 32 | 1.0047 | 0.000000 | 0.000 |
| 3 | 0.9968 | 0.152767 | 15.326 | 33 | 1.0013 | 0.000000 | 0.000 |
| 4 | 0.9994 | 0.001760 | 0.176 | 34 | 0.9952 | 0.151745 | 15.247 |
| 5 | 1.0010 | 0.000000 | 0.000 | 35 | 1.0009 | 0.000000 | 0.000 |
| 6 | 1.0003 | 0.000000 | 0.000 | 36 | 0.9961 | 0.000000 | 0.000 |
| 7 | 0.9972 | 0.000000 | 0.000 | 37 | 1.0018 | 0.000000 | 0.000 |
| 8 | 1.0040 | 0.000000 | 0.000 | 38 | 1.0007 | 0.000000 | 0.000 |
| 9 | 0.9990 | 0.000000 | 0.000 | 39 | 1.0007 | 0.000000 | 0.000 |
| 10 | 1.0008 | 0.000000 | 0.000 | 40 | 1.0058 | 0.000000 | 0.000 |
| 11 | 0.9981 | 0.000000 | 0.000 | 41 | 0.9945 | 0.000000 | 0.000 |
| 12 | 1.0027 | 0.000000 | 0.000 | 42 | 0.9971 | 0.000000 | 0.000 |
| 13 | 1.0054 | 0.104037 | 10.348 | 43 | 1.0013 | 0.000000 | 0.000 |
| 14 | 0.9911 | 0.050163 | 5.061 | 44 | 1.0032 | 0.151185 | 15.070 |
| 15 | 1.0027 | 0.000000 | 0.000 | 45 | 0.9976 | 0.000000 | 0.000 |
| 16 | 0.9966 | 0.000000 | 0.000 | 46 | 0.9980 | 0.000000 | 0.000 |
| 17 | 1.0029 | 0.000000 | 0.000 | 47 | 1.0020 | 0.000000 | 0.000 |
| 18 | 1.0004 | 0.000000 | 0.000 | 48 | 0.9972 | 0.000000 | 0.000 |
| 19 | 1.0003 | 0.000000 | 0.000 | 49 | 1.0049 | 0.000000 | 0.000 |
| 20 | 1.0010 | 0.000000 | 0.000 | 50 | 0.9955 | 0.000000 | 0.000 |
| 21 | 1.0000 | 0.000000 | 0.000 | 51 | 1.0020 | 0.000000 | 0.000 |
| 22 | 0.9955 | 0.000000 | 0.000 | 52 | 1.0051 | 0.000000 | 0.000 |
| 23 | 1.0020 | 0.000000 | 0.000 | 53 | 0.9929 | 0.000000 | 0.000 |
| 24 | 0.9985 | 0.155209 | 15.544 | 54 | 1.0051 | 0.150653 | 14.989 |
| 25 | 1.0026 | 0.000000 | 0.000 | 55 | 1.0007 | 0.001472 | 0.147 |
| 26 | 0.9975 | 0.000000 | 0.000 | 56 | 1.0010 | 0.000000 | 0.000 |
| 27 | 1.0054 | 0.000000 | 0.000 | 57 | 0.9941 | 0.000000 | 0.000 |
| 28 | 0.9993 | 0.000000 | 0.000 | 58 | 1.0013 | 0.000000 | 0.000 |
| 29 | 0.9985 | 0.000000 | 0.000 | 59 | 1.0039 | 0.000000 | 0.000 |
| 30 | 0.9986 | 0.000000 | 0.000 | 60 | 0.9943 | 0.000000 | 0.000 |

Wall-time-weighted mean tree CPU: **1.5314%** (gate: ≤ 2% — **pass**).

51 of the 60 intervals recorded exactly zero CPU. Intervals above 5% were
3, 13, 14, 24, 34, 44 and 54 — the ten-interval spacing of the drainer poll.
The longest run of consecutive intervals above 5% was **2** (intervals 13 and
14, a single poll straddling a boundary), against a failure condition of five
(**pass**).

#### Idle window: resident memory

At the same 61 boundaries, `ri_resident_size` was summed across the Kanban root
and every live descendant, converted at 1 MiB = 1,048,576 bytes. Peak resident
memory is the maximum of those sampled tree sums, not the maximum RSS of any
single process.

| Item | Value |
| --- | ---: |
| Kanban root alone, typical | 35.34 MiB |
| Peak sampled tree sum | **69.59 MiB** |
| Boundary of peak | 13 (root 35.34 MiB + live controller 34.25 MiB) |
| Gate | ≤ 512 MiB — **pass** |

The peak is a tree sum by construction: it occurs at the one boundary where a
drainer controller happened to be alive, and is nearly double the root-only
figure. A single-process reading would have recorded 35.34 MiB and missed it.

#### Drainer poll attribution

The poll is reported as a classified **subset** of total tree CPU, never added
to it a second time. The classified value at a boundary is the Kanban root's
accumulated-child CPU, baselined at the start of the idle window, plus the self
and child CPU of any live direct child identified as the controller. A live
direct child is classified as the controller when its executable lies inside
the interpreter installation the loaded launchd job names and its command ends
with the exact resolved argv tail — the controller script, the `--path`/`--repo`
pair Kanban rebases onto it, and the `--json status` appended last.

| Item | Value |
| --- | ---: |
| Polls observed via classified CPU deltas | 6 (intervals 3, 13, 24, 34, 44, 54) |
| Polls caught alive by a boundary census | 1 (boundary 13) |
| Classified drainer CPU over the window | 0.878602 s |
| As a share of total tree CPU (0.918990 s) | 95.6% |
| Mean CPU attributable to the poll | 1.4641% |
| Mean CPU attributable to everything else | 0.0673% |
| Cost per poll | 0.1464 s |

Attribution is valid for this window: **no non-controller child activity was
observed at any of the 61 boundaries**, and no GitHub, Codex or Claude refresh
occurred during the window. The observed poll count is non-zero, which is the
check that the window really did run with the launchd job loaded — when
`discoverDrainerController` fails, Kanban never forks the poll at all, and a
quiet tree would otherwise pass the CPU gate without having measured D-10's
configuration. The launchd-managed drainer service itself is outside the
measured tree; only the controller Kanban invokes is inside it.

The 0.1464 s per poll against D-10's 0.07 s estimate is the headline finding of
this record. It is not a gate failure and does not block the release. It does
mean the poll, not the dashboard, is what would consume D-4's budget first.

#### Refresh attribution

Observed separately for the board and both usage providers across all 61
boundary captures of the idle minute:

| Condition | Observation |
| --- | --- |
| `board: refreshing…` reappears | never — 0 of 61 captures |
| Board age resets | no — the footer aged `updated now` → `updated 1m ago` and never reset |
| Codex `refreshing…` reappears | never — 0 usage-panel occurrences |
| Claude `refreshing…` reappears | never — 0 usage-panel occurrences |
| Non-drainer subprocess activity | none — 0 non-controller children at any boundary |
| UI responsive during the explicit `u` | yes — Help drew and closed while the board read `refreshing…` |

All four success conditions hold.

#### Content churn

The pane was captured at every idle boundary and successive snapshots diffed.
Two content changes occurred in the 60 diffs, both explained:

| Boundary | Line | Change | Classification |
| ---: | ---: | --- | --- |
| 24 | 48 | `board: updated now` → `board: updated 1m ago` | expected freshness-age change |
| 44 | 17 | detail panel `@coghex · updated 15m ago` → `16m ago` | expected freshness-age change |

Both are relative-age text, and both landed on drainer-poll boundaries, which
is the only way they can occur: `appNow` advances only when an event is
handled, so with no other activity the age strings can only change on the
~10 second drainer events. There were **no unexplained changes** after the UI
settled (**pass**).

True flicker — repaint volume against unchanged screen content — is **not
measured for 1.0**, because `capture-pane` observes content, not repaint
operations. This record therefore makes no claim about repainting, only about
observable content churn (D-9).

#### Conclusions

| Gate | Threshold | Observed | Result |
| --- | --- | --- | :---: |
| Startup, 3 consecutive launches | usable first frame ≤ 10 s | 0.9050 s, 1.2030 s, 0.9025 s | **pass** |
| Mean tree CPU | ≤ 2% | 1.5314% | **pass** |
| Consecutive high CPU | no 5 consecutive samples > 5% | longest run 2 | **pass** |
| Peak resident memory | ≤ 512 MiB | 69.59 MiB | **pass** |
| Refresh attribution | no further GitHub or usage refresh; `u` stays responsive | none observed; responsive | **pass** |
| Content churn | no unexplained content change once settled | 2 changes, both expected freshness ages | **pass** |

All six gates pass. The drainer poll's reconciled subset, 1.4641% of the
1.5314% mean, did not cause a failure; it is recorded above as the number a
later release should reduce or re-threshold, and it is the reason the remaining
headroom under D-4 belongs to the poll rather than to the dashboard.

Neither the method nor any threshold was altered to obtain these results, and
no discarded run was reinterpreted into a pass. Three rehearsals preceded the
recorded one:

1. A startup-only series, discarded because the harness had not held the final
   session open for the settled window, so there was no measured window at all.
2. A complete series whose idle window was **invalidated** by the rule in
   Drainer poll attribution above: the classifier matched the launchd plist's
   interpreter path literally, so the one live controller sighting was misfiled
   as non-controller child activity and the observed poll count came out zero.
   Both conditions require the window to be repeated rather than reinterpreted,
   and it was.
3. A complete series with the classifier corrected, whose numbers agreed with
   those recorded here (mean 1.5603%, peak 69.34 MiB, six polls, zero
   non-controller children). It was superseded only so that the probe source
   published above is byte-for-byte the source that produced the recorded
   numbers, after unused code left over from developing the probe was removed.

The run recorded here is the fourth.

### REL-2. Live Codex and Claude usage refreshes, macOS, 2026-08-14

Both built-in usage providers **pass**. Each reached a fresh state well inside
its configured timeout, each rendered at least one window with a percentage bar
and a reset time, and no `codex`, `claude`, or `script` process outlived either
refresh.

| Provider | Configured timeout | Startup refresh | Explicit `u` refresh | Result |
| --- | --- | --- | --- | :---: |
| Codex | 10 s | fresh in 0.690 s | fresh in 0.827 s | **pass** |
| Claude | 45 s | fresh in 6.190 s | fresh in 5.827 s | **pass** |

The two outcomes were recorded independently and neither depended on the other
(Requirement 9); had one failed, the other's result would still stand as
written. Requirement 11's "a recorded failure is a correct outcome" was not
exercised: nothing failed, and no threshold, method, or environment was adjusted
to reach that. The one deviation from the issue's expectation is a shape
difference in the Codex response, recorded under Observed states below, which is
a property of the account's rate-limit payload rather than a provider fault.

#### Build provenance

| Item | Value |
| --- | --- |
| Commit (`git rev-parse HEAD`) | `e3e02bb45fd9348055b02c7d55f6e63b95194a2d` |
| Working tree at that commit | `git status --porcelain=v1 --untracked-files=all` returned empty |
| Archive | `kanban-1.0.0.0.tar.gz` |
| Installed `--version` | `kanban 1.0.0.0` |
| Install directory | a temporary directory; neither `~/.local/bin` nor `~/.cabal/bin` was used or written |

```console
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
TMP="$(mktemp -d)"
mkdir -p "$TMP/unpacked" "$TMP/bin"
cabal sdist all --builddir "$TMP/dist" --output-directory "$TMP/sdist"
tar -xzf "$TMP"/sdist/kanban-*.tar.gz -C "$TMP/unpacked"
cd "$TMP"/unpacked/kanban-*
cabal install exe:kanban --installdir "$TMP/bin" --install-method=copy
"$TMP/bin/kanban" --version
```

The commit measured is the branch point of the pull request carrying this
record. Nothing in this slice changes implementation code (Requirement 12), so
the archive built from that commit is the same executable the record describes.

#### Measurement environment

| Item | Value |
| --- | --- |
| macOS | 26.6 (build 25G5065a) |
| Architecture | arm64, Apple M3 Max, 16 logical CPUs |
| tmux | 3.5a |
| Pane geometry | 200 columns × 50 rows, detached session |
| Toolchain | GHC 9.12.2, cabal-install 3.16.1.0 |
| Python (probes) | 3.14.6 |
| Repository identity | `coghex/kanban` |
| Checkout path | `~/worktrees/coghex/kanban/issue-270-live-usage-evidence`, a linked worktree of that repository, passed as `--path` (home abbreviated per D-8) |
| launchd drainer job | `com.coghex.drain-prs.coghex.kanban` loaded but not running; Kanban's own ten-second status poll ran throughout, as in REL-1 |

#### Which configuration file the run actually loaded

Requirement 4 asks whether the escape hatch of section 14 was configured, and
the answer has to be about the file the *measured command* read, not about a
path assumed on its behalf: `app/Main.hs:36-44` resolves an explicit `--config`
first, and `src/Kanban/Config.hs:302-305,318-325` otherwise derives the default
from the XDG configuration root.

The measured command was `kanban --path <checkout>` with **no `--config`
option**, run with `XDG_CONFIG_HOME` unset and `HOME` at the operator's own home
directory, so the loaded path is the XDG-derived default
`~/.config/kanban/config.toml`. That file **does not exist**, so
`loadRawConfig` returns `defaultRawConfig`, whose `usageCodexCommand` and
`usageClaudeCommand` are both `Nothing`, and `Kanban.UI.Refresh.runUsageProvider`
(`src/Kanban/UI/Refresh.hs:349-352`) therefore routes both refreshes to the
built-in integrations. The built-ins are what this record measures.

Rather than assume that resolution, it was demonstrated against the measured
binary itself. A deliberately malformed TOML file makes `loadRawConfig` report
the path it actually read, so three probes pin all three branches:

```console
PROBE="$TMP/configprobe"
mkdir -p "$PROBE/xdg/kanban" "$PROBE/home/.config/kanban"
printf 'this is not toml =\n' > "$PROBE/xdg/kanban/config.toml"
printf 'this is not toml =\n' > "$PROBE/home/.config/kanban/config.toml"
env XDG_CONFIG_HOME="$PROBE/xdg" "$TMP/bin/kanban" --path "$ROOT"
env -u XDG_CONFIG_HOME HOME="$PROBE/home" "$TMP/bin/kanban" --path "$ROOT"
env XDG_CONFIG_HOME="$PROBE/xdg" "$TMP/bin/kanban" \
  --config "$PROBE/home/.config/kanban/config.toml" --path "$ROOT"
```

`$TMP` and `$ROOT` are the variables set in Build provenance above; the probe
directories are created under the same temporary root, and nothing is written
to the operator's own configuration directory.

Each named the file it had read, in the message
`kanban: configuration file <path> is invalid: 1:6: parse error: unexpected bare
key`: the first named `$PROBE/xdg/kanban/config.toml`, confirming
`XDG_CONFIG_HOME` is honoured; the second named
`$PROBE/home/.config/kanban/config.toml`, confirming the `$HOME/.config`
fallback the measured run relies on; the third named the explicit `--config`
file even with `XDG_CONFIG_HOME` pointing elsewhere, confirming the override
precedence. Under the measured run's own environment those rules resolve to
`~/.config/kanban/config.toml`, and `ls` reports it absent.

Because no configuration file loads at all, the provider timeouts are the
defaults of `src/Kanban/Config.hs:98-106` — 10 seconds for Codex and 45 for
Claude — which are the figures the elapsed times below are measured against.

#### Which executables actually answered

On this machine two `cmux-cli-shims` directories precede the operator's clients
on the ambient `PATH` (entries 1 and 15). Acceptance 1 allows either removing
the shim for the run or recording that it delegates; the shim was **removed**,
by launching Kanban through a wrapper that strips every `cmux-cli-shims` entry
from `PATH` before `exec`ing the executable. The inspected shims would have
`exec`ed `/Applications/cmux.app/Contents/Resources/bin/cmux-{codex,claude}-wrapper`,
so leaving them in place would have measured a wrapper rather than the client.

The resolved paths were not taken from `command -v`. They were read off the
**live processes** with `proc_pidpath(2)` while each refresh was in flight,
which is what the client actually executed:

| Role | Executable observed running | Version string |
| --- | --- | --- |
| Codex client | `~/.codex/packages/standalone/releases/0.147.0-aarch64-apple-darwin/bin/codex` | `codex-cli 0.147.0` |
| Claude client | `~/.local/share/claude/versions/2.1.233` | `2.1.233 (Claude Code)` |
| `script` wrapper | `/usr/bin/script` | — |

Those are the canonical targets of the operator's own `~/.local/bin/codex` and
`~/.local/bin/claude` symlinks, so the gate of Requirement 3 is satisfied: the
executables that answered are the operator's authenticated clients, with no
wrapper or shim between Kanban and them. `script` is named because
`src/Kanban/Claude.hs:76-81,116-124` resolves it through `PATH` too and launches
the Claude probe through it.

#### What the providers sent

Requirement 7 forbids an ordinary model prompt (D-2). Neither provider submits
one, and the exact traffic is fixed in source rather than inferred from a
transcript.

**Codex** sends three JSON-RPC messages and no others. `Kanban.Codex.exchange`
(`src/Kanban/Codex.hs:67-78`) writes `initialize`, then the `initialized`
notification, then `account/rateLimits/read`, whose literal texts are
`src/Kanban/Codex.hs:191-195`. The issue that commissioned this record described
only the rate-limit request; the other two are part of the exchange, and none of
the three is a model prompt. Replaying exactly those three messages against
`codex app-server --stdio` independently returned a rate-limit result with no
error, confirming the exchange needs nothing else.

**Claude** writes to the probe's standard input from exactly two functions, and
`sendInput` has no other call site. `respondToScreen`
(`src/Kanban/Claude.hs:181-189`) sends a bare carriage return when the trust
prompt is visible, then `/usage\r` when the prompt is visible;
`requestCleanExit` (`src/Kanban/Claude.hs:214-218`) sends `ESC`, waits 100 ms,
and sends `/exit\r`. The `ESC` is part of the exit sequence and was likewise
absent from the issue's description. None of these is a model prompt.

That reading is corroborated from outside the process. After the run the probe's
scratch directory `~/.cache/kanban/claude-probe` was **empty**, and no Claude
Code project directory existed for that path — a submitted prompt would have
created a session transcript under `~/.claude/projects/`. Nothing was recorded
because nothing was asked.

#### Observed states and elapsed times

Two rounds supply the recorded figures, and the record states which is which
(Requirement 6); a third round, covering the solver-nesting question, is
reported separately below.
The sidebar was sampled every 0.15 s with `capture-pane`, and each provider's
block was classified independently. The classification is unambiguous once a
snapshot exists, because a failed refresh over an existing snapshot renders
`stale · <message>` (`src/Kanban/UI/Reconcile.hs:237-239`) while a successful one
clears the status line entirely (`src/Kanban/UI/Board.hs:152-160`); reaching
`Fresh` is therefore only possible on the `Right snapshot` branch of
`applyUsageRefresh`.

Each round's clock starts at that round's real dispatch instant, and the reading
is taken *before* the dispatching action rather than after it, so no part of the
interval being measured is discounted. Round A's is read immediately before
`tmux new-session` is invoked and handed to the observer; round B's is read
immediately before the keystroke is injected. Both are `time.monotonic()`
readings, which are system-wide and therefore comparable across the processes
that take and use them. The observer is started before the Kanban pid is
resolved and before the census watcher starts, so neither delays the first
sample: it landed 0.048 s after dispatch in round A and 0.006 s in round B.

**Round A — the startup refresh, against a cold usage cache.**
`~/.cache/kanban/usage.json` was moved aside before launch, so Kanban started
with no snapshot for either provider. The first sample caught the pane before
Kanban had drawn; by 0.213 s both blocks showed `refreshing…` with **zero**
windows, and windows appeared only as each provider turned fresh. A rendered
window in this round therefore cannot have come from the cache — it can only
have come from the live refresh. Because the clock starts before tmux is asked
to create the session, this figure includes tmux session creation and Kanban's
own startup, and is an upper bound on dispatch-to-fresh.

**Round B — a later explicit `u`.** Dispatch is the keystroke itself, and the
clock is read immediately before it, so the interval covers tmux's delivery of
the key as well as the refresh. The first sample still showed the previous
round's fresh state; by the second, at 0.167 s, both blocks had returned to
`refreshing…`, and both then reached fresh again.

| Round | Provider | Dispatch instant | Elapsed to fresh | Configured timeout | Margin used |
| --- | --- | --- | --- | --- | --- |
| A (startup) | Codex | immediately before `tmux new-session` | 0.690 s | 10 s | 6.9% |
| A (startup) | Claude | immediately before `tmux new-session` | 6.190 s | 45 s | 13.8% |
| B (explicit `u`) | Codex | immediately before the `u` keystroke | 0.827 s | 10 s | 8.3% |
| B (explicit `u`) | Claude | immediately before the `u` keystroke | 5.827 s | 45 s | 12.9% |

Neither provider came close to its timeout: the largest share of any budget
consumed was 13.8%.

In both rounds the final state of both providers was fresh: no `refreshing…`,
no `stale · `, and no unavailable or unsupported message (Requirement 5). Codex
rendered one window and Claude two, each with a percentage bar and a reset time.
The per-provider notices seen in order — `Refreshing Claude usage…`,
`Codex usage refreshed`, `Claude usage refreshed` — corroborate the sidebar
reading.

Codex rendering **one** window rather than two is worth recording, because the
issue's acceptance sketch anticipated a pair. It is not a truncation and not a
parse failure. `Kanban.Codex.selectRateLimits` prefers the `codex` bucket of
`rateLimitsByLimitId`, and `parseWindows` builds a window from each of that
bucket's `primary` and `secondary` keys. Inspecting the response *shape* — key
presence only, no values — showed `primary` present with its three required
fields and `secondary` absent, in both the bucket and the top-level `rateLimits`
fallback. One complete window is what the account's payload supports, which
satisfies Requirement 5's "at least one window", and the single window is
labelled `week` because that is what its window duration maps to in
`durationLabel`.

#### Process lifecycle

Requirement 8 asks that no `codex`, `claude`, or `script` process survive as a
descendant of the Kanban process once both refreshes have finished. Acceptance 3
proposed `ps -axo pid=,ppid=,command= | awk -v k="<kanban pid>" '$2==k'`, which
cannot establish that: it matches only **immediate** children, and the process
this requirement is most concerned about is not one. `script` gives its `claude`
child its own session and process group through the pty, so when `script` exits
that `claude` is reparented away from Kanban entirely — the case
`src/Kanban/Claude.hs:220-269` exists to handle. Run after the refreshes, that
command printed nothing — but nothing is what it would print either way, whether
no provider process survived or one survived after being reparented out of
view. An empty result from it is therefore not evidence, which is why the check
below was used to decide the requirement.

The check used instead censuses the **full recursive descendant tree** while the
refreshes are active, keys every process by pid **and**
`ri_proc_start_abstime` so pid reuse cannot corrupt the result, and then
verifies those recorded identities are absent from the **entire process table**
afterwards rather than from the tree. A reparented survivor is caught by that
sweep precisely because it is no longer a descendant.

The probe's self-test must pass before any measurement, and it constructs the
reparenting case rather than assuming it:

```text
=== REL-2 census probe self-test ===
reparent case: grandchild pid 98754 ppid 1, in probe's descendant tree = False -> REPARENTED (tree walk alone would miss it)
whole-table identity scan finds the reparented orphan alive: True -> PASS
pid/start identity: pid 98754 start 12697409967157 matches, start 12697409967158 is rejected -> PASS
recursive discovery: child 98808 and grandchild 98809 both in tree -> PASS
absence after exit: all three recorded identities report gone -> PASS
SELF-TEST PASSED: recursive descent reaches grandchildren, pid/start identity rejects reuse, and a reparented orphan is caught by the whole-table scan
```

The orphan's parent really did become pid 1, so the tree walk really did lose
it while it was still running, and the whole-table identity scan really did
still find it. That is the failure mode the method is built to survive.

Across both rounds the census took **933 samples over 150.112 s** at a 0.15 s
interval and recorded **28 distinct descendant identities**, of which seven were
provider-related:

| Round | Process | Parent | Own process group | Observed alive |
| --- | --- | --- | --- | --- |
| A | `/usr/bin/script` | Kanban | yes | 0.002 – 5.762 s |
| A | `claude` 2.1.233 | `script` | yes, separate from `script` | 0.002 – 5.762 s |
| A | `codex` 0.147.0 | Kanban | no, Kanban's group | 0.002 – 0.320 s |
| A | `claude` 2.1.233 helper | the probe's `claude` | shares its parent's group | 0.482 s, one sample |
| B | `/usr/bin/script` | Kanban | yes | 8.160 – 13.764 s |
| B | `claude` 2.1.233 | `script` | yes, separate from `script` | 8.160 – 13.764 s |
| B | `codex` 0.147.0 | Kanban | no, Kanban's group | 8.160 – 8.793 s |

The helper row is the reason recursion is not optional. That process is a
**grandchild** of `script` and a great-grandchild of Kanban, it was alive for a
single 0.15 s sample, and no depth-one enumeration would have seen it. The
remaining twenty-one identities were Kanban's ordinary children and their
descendants — `gh`, `git`, `bash`, `grep`, `node`, and the ten-second drainer
status poll's Python — none of which this requirement is about, though all were
verified absent too.

With Kanban still running, every one of the 28 recorded identities was absent
from the process table, and an independent sweep for any live `codex`, `claude`,
or `script` process in any process group the census had recorded returned zero
hits:

```text
recorded descendant identities: 28
  of which codex/claude/script-related: 7
    pid   22378 start   12709355500730 script           /usr/bin/script -> gone
    pid   22395 start   12709355594702 2.1.233          ~/.local/share/claude/versions/2.1.233 -> gone
    pid   22393 start   12709355578807 codex            ~/.codex/…/0.147.0-aarch64-apple-darwin/bin/codex -> gone
    pid   22449 start   12709370325084 2.1.233          ~/.local/share/claude/versions/2.1.233 -> gone
    pid   22885 start   12709552160982 script           /usr/bin/script -> gone
    pid   22886 start   12709552286148 2.1.233          ~/.local/share/claude/versions/2.1.233 -> gone
    pid   22901 start   12709552308456 codex            ~/.codex/…/0.147.0-aarch64-apple-darwin/bin/codex -> gone
stray sweep over recorded process groups [18 groups]: 0 hit(s)
VERIFY PASSED: every recorded descendant identity is absent from the process table
```

Home directories are abbreviated and the recorded process-group list is
summarised by its length, per D-8; nothing else in that output is altered.

Kanban was then quit with `q` and exited cleanly.

#### Claude's exit classification

`src/Kanban/Claude.hs:136-142` returns a snapshot only when `finishProcess`
reports that SIGKILL was **not** required; a forced kill instead yields the
distinct error `Claude usage probe did not exit cleanly after /exit and required
a forced kill`. Both rounds ended `Fresh`, which is reachable only through the
`Right snapshot` branch, so in both rounds the probe **exited cleanly** and the
forced-kill message was never shown. That is the only classification this record
claims: a clean exit is recorded because the result was fresh, and no
clean-versus-forced claim is made about any other failure path, because
`src/Kanban/Claude.hs:127-145` does not expose one for timeout, authentication,
or unsupported-output failures. Had either round failed, the terminal outcome
would have been recorded alongside the independent process-census result, which
does not depend on how the probe classified its own exit.

The census is consistent with a clean exit: both `script` and its `claude` child
disappeared together inside the two-second window `finishProcess` waits before
it would escalate.

#### Interference from running inside a Claude Code session

The issue notes that a solver already running inside Claude Code should expect
the Claude probe to nest, since the probe inherits its caller's environment. The
measured rounds above removed the nesting variables this session exports —
`CLAUDECODE`, `CLAUDE_PID`, `CLAUDE_EFFORT`, `CLAUDE_CODE_CHILD_SESSION`,
`CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_EXECPATH`, `CLAUDE_CODE_MESSAGING_SOCKET`,
`CLAUDE_CODE_MESSAGING_TOKEN`, and `CLAUDE_CODE_SESSION_ID` — so that the
environment matches an operator launching Kanban from a terminal rather than the
solver's own.

A third round was then run with all of them **inherited**, clocked the same way
as round A, to record whether the nesting interferes. It does not: both
providers reached fresh, Codex in 0.547 s and Claude in 6.191 s, the latter
within a millisecond of round A's figure for the same dispatch instant, and a
separate census over that round found
its `codex`, `script`, and `claude` identities absent afterwards with zero stray
hits. No interference was observed in either direction, and the recorded pass
does not depend on which of the two environments is used.

One caveat on that round, disclosed rather than smoothed over: its **final**
capture caught the pane mid-redraw, with a window's reset row present and its
bar row not yet written. The window count from that frame is therefore not used
as evidence here; rounds A and B, sampled identically, carry the window-shape
evidence. This is the limit D-9 already names — `capture-pane` returns content,
not repaints — and it affects a frame's completeness, not the fresh/stale
classification, which the round reached and held.

#### What this record omits

Per Requirement 10 and D-8, no percentage, no reset time, no account identifier,
no balance, no token, and no raw provider output appears above. The Codex
response was inspected for key presence only. What is recorded is the *shape* of
what rendered — how many windows, whether each carried a bar and a reset time,
and which state the block was in — which is what the gate is about.

#### Suites

Both suites pass at the recorded commit:

```console
cabal test all --test-show-details=direct
python3 -m unittest discover -s tools -p 'test_*.py' < /dev/null
```

The Haskell suite reported `1101 examples, 0 failures` and
`Test suite kanban-test: PASS`; the Python suite ran 1336 tests, `OK`. The
Python suite's stdin is redirected because a fake-CLI call stalls for 60 seconds
per invocation when stdin is a non-tty pipe.

#### Reproducing this record

The measured run is driven by four artifacts kept outside the checkout. They are
given here in dependency order — the three the orchestrator calls, then the
orchestrator — so that following the section top to bottom creates each file
before anything uses it. All four live in the same `$TMP` directory as the
installed executable from Build provenance above, and the orchestrator locates
its siblings from its own path rather than from an inherited variable.

**1. The launcher.** It strips every `cmux-cli-shims` entry from `PATH` so the
operator's own clients are what Kanban resolves, and — unless
`REL2_KEEP_NESTING=1` — unsets the Claude Code nesting variables. It resolves
the installed executable relative to its own location, so no variable has to
survive into the environment tmux gives it:

```console
cat > "$TMP/launch_kanban.sh" <<'LAUNCH'
#!/bin/bash
# REL-2 measured-run launcher. Builds the environment the operator's terminal
# would have, then execs the sdist-installed Kanban.
#
#  * PATH has every cmux-cli-shims entry removed, so `codex` and `claude`
#    resolve to the operator's own installed clients rather than to a session
#    shim (Acceptance 1's "remove it for the run" option).
#  * The Claude Code nesting variables this solver session exports are unset,
#    because Kanban's Claude provider inherits its caller's environment and an
#    operator launching Kanban from a terminal has none of them. Which
#    variables were removed is recorded in the evidence.
#  * XDG_CONFIG_HOME stays unset and HOME stays the operator's, so the config
#    path Kanban resolves is the real default one under test.
set -u

REL="$(cd "$(dirname "$0")" && pwd)"

export PATH="$(python3 -c "
import os
print(':'.join(e for e in os.environ['PATH'].split(':') if 'cmux-cli-shims' not in e))
")"

if [ "${REL2_KEEP_NESTING:-0}" != "1" ]; then
  unset CLAUDECODE CLAUDE_PID CLAUDE_EFFORT
  unset CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_EXECPATH
  unset CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_SESSION_ID
fi

exec "$REL/bin/kanban" --path "$1"
LAUNCH
chmod +x "$TMP/launch_kanban.sh"
```

**2. The process census probe** of Requirement 8. Its `--self-test` must pass
before any measurement:

```console
cat > "$TMP/census_tree.py" <<'CENSUS'
#!/usr/bin/env python3
"""REL-2 recursive descendant process census for an installed Kanban (macOS, unprivileged).

Censuses the FULL recursive PPID descendant tree rooted at a Kanban PID while a
usage refresh is active, keying every process by (pid, ri_proc_start_abstime) so
PID reuse cannot make a dead process look alive or a live one look dead. The
absence check afterwards scans the ENTIRE process table for those recorded
identities, not the descendant tree, because `script` hands its `claude` child a
separate session and process group: once `script` exits, that `claude` is
reparented away from Kanban and a parent-walking check would report it absent
while it is still running (src/Kanban/Claude.hs:220-269 documents exactly this).

Temporary measurement artifact for issue #270. Not part of the repository.
"""

import argparse
import ctypes
import ctypes.util
import json
import os
import subprocess
import sys
import time

# ---------------------------------------------------------------- libproc FFI

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)

RUSAGE_INFO_V4 = 4
PROC_PIDPATHINFO_MAXSIZE = 4096
PROC_PIDTBSDINFO = 3


class RusageInfoV4(ctypes.Structure):
    """<sys/resource.h> struct rusage_info_v4; only the v0 prefix is read."""

    _fields_ = [
        ("ri_uuid", ctypes.c_uint8 * 16),
        ("ri_user_time", ctypes.c_uint64),
        ("ri_system_time", ctypes.c_uint64),
        ("ri_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_interrupt_wkups", ctypes.c_uint64),
        ("ri_pageins", ctypes.c_uint64),
        ("ri_wired_size", ctypes.c_uint64),
        ("ri_resident_size", ctypes.c_uint64),
        ("ri_phys_footprint", ctypes.c_uint64),
        ("ri_proc_start_abstime", ctypes.c_uint64),
        ("ri_proc_exit_abstime", ctypes.c_uint64),
        ("ri_child_user_time", ctypes.c_uint64),
        ("ri_child_system_time", ctypes.c_uint64),
        ("ri_child_pkg_idle_wkups", ctypes.c_uint64),
        ("ri_child_interrupt_wkups", ctypes.c_uint64),
        ("ri_child_pageins", ctypes.c_uint64),
        ("ri_child_elapsed_abstime", ctypes.c_uint64),
        ("ri_diskio_bytesread", ctypes.c_uint64),
        ("ri_diskio_byteswritten", ctypes.c_uint64),
        ("ri_cpu_time_qos_default", ctypes.c_uint64),
        ("ri_cpu_time_qos_maintenance", ctypes.c_uint64),
        ("ri_cpu_time_qos_background", ctypes.c_uint64),
        ("ri_cpu_time_qos_utility", ctypes.c_uint64),
        ("ri_cpu_time_qos_legacy", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_initiated", ctypes.c_uint64),
        ("ri_cpu_time_qos_user_interactive", ctypes.c_uint64),
        ("ri_billed_system_time", ctypes.c_uint64),
        ("ri_serviced_system_time", ctypes.c_uint64),
        ("ri_logical_writes", ctypes.c_uint64),
        ("ri_lifetime_max_phys_footprint", ctypes.c_uint64),
        ("ri_instructions", ctypes.c_uint64),
        ("ri_cycles", ctypes.c_uint64),
        ("ri_billed_energy", ctypes.c_uint64),
        ("ri_serviced_energy", ctypes.c_uint64),
        ("ri_interval_max_phys_footprint", ctypes.c_uint64),
        ("ri_runnable_time", ctypes.c_uint64),
    ]


class ProcBsdInfo(ctypes.Structure):
    """<sys/proc_info.h> struct proc_bsdinfo -- read for pbi_ppid/pbi_status."""

    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


SZOMB = 5

libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libc.proc_pid_rusage.restype = ctypes.c_int
libc.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
libc.proc_listallpids.restype = ctypes.c_int
libc.proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.c_void_p,
    ctypes.c_int,
]
libc.proc_pidinfo.restype = ctypes.c_int
libc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
libc.proc_pidpath.restype = ctypes.c_int


def list_all_pids():
    """Every pid visible to this (unprivileged) user, plus system pids."""
    count = libc.proc_listallpids(None, 0)
    if count <= 0:
        raise RuntimeError("proc_listallpids failed")
    capacity = count + 256
    buffer = (ctypes.c_int * capacity)()
    written = libc.proc_listallpids(ctypes.byref(buffer), ctypes.sizeof(buffer))
    if written <= 0:
        raise RuntimeError("proc_listallpids failed on the sized call")
    return [pid for pid in buffer[: written // ctypes.sizeof(ctypes.c_int)] if pid > 0]


def bsd_info(pid):
    """proc_pidinfo(PROC_PIDTBSDINFO). None when the process is gone."""
    buffer = ProcBsdInfo()
    written = libc.proc_pidinfo(
        pid, PROC_PIDTBSDINFO, 0, ctypes.byref(buffer), ctypes.sizeof(buffer)
    )
    if written != ctypes.sizeof(buffer):
        return None
    return buffer


def start_abstime(pid):
    """ri_proc_start_abstime, the per-process start identity. None when gone."""
    buffer = RusageInfoV4()
    if libc.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(buffer)) != 0:
        return None
    return buffer.ri_proc_start_abstime


def executable_path(pid):
    """proc_pidpath, the on-disk executable actually running. '' when unknown."""
    buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    written = libc.proc_pidpath(pid, buffer, PROC_PIDPATHINFO_MAXSIZE)
    if written <= 0:
        return ""
    return buffer.value.decode("utf-8", "replace")


def snapshot():
    """Whole visible process table as {pid: record}, each with a start identity.

    A record's ``start`` is the Mach absolute-time process start; combined with
    the pid it forms the identity that survives PID reuse. Zombies are marked
    rather than dropped so a process between exit and reap is never mistaken for
    a live one nor lost from the tree walk.
    """
    table = {}
    for pid in list_all_pids():
        info = bsd_info(pid)
        if info is None:
            continue
        start = start_abstime(pid)
        if start is None:
            # Not readable (different user, or raced with exit); fall back to the
            # bsdinfo start time so the entry still carries an identity.
            start = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
            start_source = "bsdinfo"
        else:
            start_source = "rusage"
        table[pid] = {
            "pid": pid,
            "ppid": int(info.pbi_ppid),
            "pgid": int(info.pbi_pgid),
            "comm": info.pbi_comm.decode("utf-8", "replace"),
            "name": info.pbi_name.decode("utf-8", "replace"),
            "start": int(start),
            "start_source": start_source,
            "zombie": int(info.pbi_status) == SZOMB,
            "path": executable_path(pid),
        }
    return table


def descendants(root_pid, table):
    """Every recursive descendant of ``root_pid`` in ``table`` (root excluded)."""
    children = {}
    for record in table.values():
        children.setdefault(record["ppid"], []).append(record["pid"])
    found = []
    seen = set()
    frontier = list(children.get(root_pid, []))
    while frontier:
        pid = frontier.pop()
        if pid in seen or pid == root_pid:
            continue
        seen.add(pid)
        found.append(table[pid])
        frontier.extend(children.get(pid, []))
    return found


def identity(record):
    return (record["pid"], record["start"])


def identity_live(pid, start, table):
    """Whether this exact (pid, start) identity is a live, non-zombie process.

    Scans the whole table rather than a subtree: a `claude` reparented away when
    `script` exited is no longer a Kanban descendant but is still running.
    """
    record = table.get(pid)
    if record is None:
        return False, None
    if record["start"] != start:
        return False, record  # pid reused by a different process
    if record["zombie"]:
        return False, record
    return True, record


PROVIDER_NAMES = ("codex", "claude", "script", "node", "bun")


def provider_like(record):
    haystack = f"{record['comm']} {record['name']} {record['path']}".lower()
    return any(token in haystack for token in ("codex", "claude", "script"))


# ------------------------------------------------------------------ self-test


def self_test():
    """Prove the three properties the census depends on, on this host.

    1. Recursive discovery reaches a grandchild, not just direct children.
    2. (pid, start) identity rejects a wrong start time.
    3. A REPARENTED orphan -- the exact case `script`/`claude` produces -- is
       still found by the whole-table identity scan after it has left the tree,
       and is correctly reported absent once it really exits.
    """
    print("=== REL-2 census probe self-test ===")

    # A child that spawns a long-lived grandchild and then exits, orphaning it.
    # The grandchild is reparented (to launchd, pid 1) exactly as `claude` is
    # when `script` exits, so it leaves the descendant tree while still running.
    child = subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import subprocess,sys,os;"
            "g=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)']);"
            "print(g.pid,flush=True);"
            "os._exit(0)",
        ],
        stdout=subprocess.PIPE,
        text=True,
    )
    grandchild_pid = int(child.stdout.readline().strip())
    time.sleep(0.6)  # let the intermediate exit and the grandchild reparent

    table = snapshot()
    tree = descendants(os.getpid(), table)
    tree_pids = {record["pid"] for record in tree}

    grandchild = table.get(grandchild_pid)
    if grandchild is None:
        raise SystemExit("SELF-TEST FAILED: orphaned grandchild vanished immediately")
    grandchild_identity = identity(grandchild)

    reparented = grandchild_pid not in tree_pids
    print(
        f"reparent case: grandchild pid {grandchild_pid} ppid {grandchild['ppid']}, "
        f"in probe's descendant tree = {grandchild_pid in tree_pids} -> "
        f"{'REPARENTED (tree walk alone would miss it)' if reparented else 'still a descendant'}"
    )

    live, _ = identity_live(*grandchild_identity, table)
    print(
        f"whole-table identity scan finds the reparented orphan alive: {live} -> "
        f"{'PASS' if live else 'FAIL'}"
    )
    if not live:
        raise SystemExit("SELF-TEST FAILED: whole-table scan missed a live orphan")

    bad_identity_live, _ = identity_live(grandchild_pid, grandchild_identity[1] + 1, table)
    print(
        f"pid/start identity: pid {grandchild_pid} start {grandchild_identity[1]} matches, "
        f"start {grandchild_identity[1] + 1} is rejected -> "
        f"{'PASS' if not bad_identity_live else 'FAIL'}"
    )
    if bad_identity_live:
        raise SystemExit("SELF-TEST FAILED: a wrong start time was accepted")

    # Recursive discovery: a direct child that spawns its own live grandchild.
    nested = subprocess.Popen(
        [
            sys.executable,
            "-c",
            "import subprocess,sys,time;"
            "g=subprocess.Popen([sys.executable,'-c','import time;time.sleep(20)']);"
            "print(g.pid,flush=True);"
            "time.sleep(20)",
        ],
        stdout=subprocess.PIPE,
        text=True,
    )
    nested_grandchild_pid = int(nested.stdout.readline().strip())
    time.sleep(0.4)
    table = snapshot()
    tree_pids = {record["pid"] for record in descendants(os.getpid(), table)}
    recursive_ok = nested.pid in tree_pids and nested_grandchild_pid in tree_pids
    print(
        f"recursive discovery: child {nested.pid} and grandchild "
        f"{nested_grandchild_pid} both in tree -> {'PASS' if recursive_ok else 'FAIL'}"
    )
    if not recursive_ok:
        raise SystemExit("SELF-TEST FAILED: recursive descent did not reach a grandchild")

    # Absence: kill both and confirm the recorded identities report gone.
    os.kill(grandchild_pid, 9)
    nested.kill()
    os.kill(nested_grandchild_pid, 9)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            nested.wait(timeout=0.2)
        except Exception:
            pass
        table = snapshot()
        still = [
            pid
            for pid in (grandchild_pid, nested.pid, nested_grandchild_pid)
            if identity_live(pid, table.get(pid, {}).get("start", -1), table)[0]
        ]
        if not still:
            break
        time.sleep(0.2)
    else:
        raise SystemExit("SELF-TEST FAILED: killed identities never reported absent")
    print("absence after exit: all three recorded identities report gone -> PASS")

    print(
        "SELF-TEST PASSED: recursive descent reaches grandchildren, pid/start identity "
        "rejects reuse, and a reparented orphan is caught by the whole-table scan"
    )


# --------------------------------------------------------------------- census


def watch(root_pid, interval, duration, out_path, quiet):
    """Sample the descendant tree of ``root_pid`` and accumulate every identity."""
    seen = {}
    samples = 0
    started = time.monotonic()
    root_start = start_abstime(root_pid)
    if root_start is None:
        raise SystemExit(f"root pid {root_pid} is not readable")
    while time.monotonic() - started < duration:
        table = snapshot()
        live_root, _ = identity_live(root_pid, root_start, table)
        if not live_root:
            break
        for record in descendants(root_pid, table):
            key = f"{record['pid']}:{record['start']}"
            entry = seen.setdefault(
                key,
                {
                    **record,
                    "first_seen_s": round(time.monotonic() - started, 3),
                    "samples": 0,
                },
            )
            entry["samples"] += 1
            entry["last_seen_s"] = round(time.monotonic() - started, 3)
        samples += 1
        if not quiet and samples % 20 == 0:
            print(f"  ... {samples} censuses, {len(seen)} distinct descendants", flush=True)
        time.sleep(interval)
    payload = {
        "root_pid": root_pid,
        "root_start": root_start,
        "censuses": samples,
        "duration_s": round(time.monotonic() - started, 3),
        "interval_s": interval,
        "descendants": list(seen.values()),
    }
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
    print(
        f"census: {samples} censuses over {payload['duration_s']}s, "
        f"{len(seen)} distinct descendant identities -> {out_path}"
    )
    for record in sorted(seen.values(), key=lambda r: r["first_seen_s"]):
        marker = " <-- provider-related" if provider_like(record) else ""
        print(
            f"  pid {record['pid']:>7} start {record['start']:>16} pgid {record['pgid']:>7} "
            f"{record['comm']:<16} {record['path']}{marker}"
        )


def verify(census_path):
    """Whole-table absence check for every recorded identity."""
    with open(census_path, encoding="utf-8") as handle:
        payload = json.load(handle)
    table = snapshot()
    survivors = []
    for record in payload["descendants"]:
        live, current = identity_live(record["pid"], record["start"], table)
        if live:
            survivors.append((record, current))
    provider_records = [r for r in payload["descendants"] if provider_like(r)]
    print(f"recorded descendant identities: {len(payload['descendants'])}")
    print(f"  of which codex/claude/script-related: {len(provider_records)}")
    for record in provider_records:
        live, _ = identity_live(record["pid"], record["start"], table)
        print(
            f"    pid {record['pid']:>7} start {record['start']:>16} {record['comm']:<16} "
            f"{record['path']} -> {'STILL LIVE' if live else 'gone'}"
        )
    # Independent belt-and-braces sweep: any live process anywhere whose
    # executable looks like a provider AND whose pgid matches one the census
    # recorded, which would catch a survivor the identity list somehow missed.
    recorded_groups = {r["pgid"] for r in payload["descendants"]}
    strays = [
        record
        for record in table.values()
        if provider_like(record)
        and not record["zombie"]
        and record["pgid"] in recorded_groups
        and record["pid"] != payload["root_pid"]
    ]
    print(f"stray sweep over recorded process groups {sorted(recorded_groups)}: {len(strays)} hit(s)")
    for record in strays:
        print(f"    pid {record['pid']} {record['comm']} {record['path']}")
    if survivors or strays:
        print("VERIFY FAILED: provider processes outlived the refresh")
        return 1
    print("VERIFY PASSED: every recorded descendant identity is absent from the process table")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--watch", action="store_true")
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--root", type=int)
    parser.add_argument("--interval", type=float, default=0.15)
    parser.add_argument("--duration", type=float, default=60.0)
    parser.add_argument("--census")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0
    if args.watch:
        if args.root is None or args.census is None:
            raise SystemExit("--watch needs --root and --census")
        watch(args.root, args.interval, args.duration, args.census, args.quiet)
        return 0
    if args.verify:
        if args.census is None:
            raise SystemExit("--verify needs --census")
        return verify(args.census)
    parser.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
CENSUS
python3 "$TMP/census_tree.py" --self-test
```

**3. The sidebar observer** that produces the elapsed times. It is an ordinary
`capture-pane` sampler: any sampler implementing the same classification rule —
`refreshing…` means loading, a leading `stale · ` means the refresh failed over
an existing snapshot, and windows with neither status line mean fresh —
reproduces the same figures. It takes each round's dispatch reading before the
dispatching action, never after:

```console
cat > "$TMP/observe_usage.py" <<'OBSERVE'
#!/usr/bin/env python3
"""REL-2 sidebar observer: per-provider usage refresh outcomes and timings.

Samples the detached tmux pane, parses the USAGE panel into an independent
state per provider, and timestamps every transition. Freshness is read off the
panel, which is unambiguous once a snapshot exists: a failed refresh over an
existing snapshot renders `stale · <message>` (src/Kanban/UI/Reconcile.hs:239),
a running one renders `refreshing…`, and windows with neither status line mean
Fresh (src/Kanban/UI/Board.hs:152-160). The notice line is captured alongside as
corroboration.

Temporary measurement artifact for issue #270. Not part of the repository.
"""

import argparse
import json
import re
import subprocess
import sys
import time

WINDOW_RE = re.compile(r"^(?P<label>\S[^\[]*?)\s+\[(?P<bar>[█░]+)\]\s+(?P<pct>\d+)%$")
RESET_RE = re.compile(r"^[A-Z][a-z]{2}\s+\d{1,2}:\d{2}$")
PROVIDERS = ("Codex", "Claude")


def capture(session):
    result = subprocess.run(
        ["tmux", "capture-pane", "-t", session, "-p"],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.splitlines()


def usage_panel(lines):
    """The USAGE panel's interior text lines, in order."""
    panel = []
    for line in lines:
        stripped = line.lstrip("║")
        if not stripped.startswith("┃"):
            continue
        fields = stripped.split("┃")
        if len(fields) < 2:
            continue
        panel.append(fields[1].rstrip())
    return panel


def notice(lines):
    """The bottom notice line, if the frame has one."""
    for line in reversed(lines):
        text = line.strip("║ ").strip()
        if not text or set(text) <= set("═╚╝ "):
            continue
        return text
    return ""


def parse_providers(panel):
    """Split the panel into a block per provider and classify each block."""
    blocks = {}
    current = None
    for raw in panel:
        text = raw.strip()
        if text in PROVIDERS:
            current = text
            blocks[current] = []
            continue
        if current is None or not text:
            continue
        if text.startswith("┏") or text.startswith("┗") or "drain_prs" in text:
            current = None
            continue
        blocks[current].append(text)

    parsed = {}
    for provider in PROVIDERS:
        block = blocks.get(provider, [])
        windows = []
        pending = None
        status = None
        for text in block:
            match = WINDOW_RE.match(text)
            if match:
                pending = {
                    "label": match.group("label").strip(),
                    "percent_left": int(match.group("pct")),
                    "bar": match.group("bar"),
                    "reset": None,
                }
                windows.append(pending)
                continue
            if RESET_RE.match(text) and pending is not None:
                pending["reset"] = text
                pending = None
                continue
            status = text
        if status == "refreshing…":
            state = "Loading"
        elif status and status.startswith("stale · "):
            state = "Stale"
        elif windows:
            state = "Fresh"
        elif status:
            state = "NoSnapshot"
        else:
            state = "Empty"
        parsed[provider] = {
            "state": state,
            "status": status,
            "windows": windows,
            "complete_windows": sum(
                1 for w in windows if w["reset"] is not None and w["bar"]
            ),
        }
    return parsed


def redact(parsed):
    """Requirement 10: shape without values."""
    return {
        provider: {
            "state": info["state"],
            "status": (
                "stale · <message>"
                if info["state"] == "Stale"
                else info["status"]
                if info["state"] in ("Loading", "NoSnapshot")
                else None
            ),
            "windows": [
                {"label": w["label"], "has_bar": bool(w["bar"]), "has_reset": w["reset"] is not None}
                for w in info["windows"]
            ],
        }
        for provider, info in parsed.items()
    }


def not_loaded_status(status):
    """The pre-dispatch 'press <key> to refresh' text of Board.hs's NotLoaded."""
    return bool(status) and status.startswith("press ") and status.endswith(" to refresh")


def observe(session, label, dispatch_at, timeout, interval, out_path, assume_dispatched):
    """Poll until both providers leave Loading, or until ``timeout`` elapses.

    ``dispatch_at`` is a ``time.monotonic()`` reading taken at the round's real
    dispatch instant -- immediately before the launch or the keystroke, never
    after -- so every elapsed figure is measured from that instant. The clock is
    system-wide, so a reading captured by another process is comparable here.

    A provider is only credited with this round's outcome once this round's
    Loading has been seen, so a state left over from an earlier round is never
    mistaken for it. ``assume_dispatched`` relaxes that for the startup round,
    where ``startAllRefreshes`` has provably already set both providers Loading
    before the first frame; the NotLoaded text is still never terminal.
    """
    timeline = []
    last = {}
    terminal_at = {}
    seen_loading = {}
    notices = []
    while time.monotonic() - dispatch_at < timeout:
        now = time.monotonic()
        lines = capture(session)
        parsed = parse_providers(usage_panel(lines))
        current_notice = notice(lines)
        if current_notice and (not notices or notices[-1]["text"] != current_notice):
            notices.append({"t": round(now - dispatch_at, 3), "text": current_notice})
        for provider, info in parsed.items():
            signature = (info["state"], info["status"], len(info["windows"]))
            if last.get(provider) != signature:
                timeline.append(
                    {
                        "t": round(now - dispatch_at, 3),
                        "provider": provider,
                        "state": info["state"],
                        "status": info["status"],
                        "windows": len(info["windows"]),
                        "complete_windows": info["complete_windows"],
                    }
                )
                last[provider] = signature
            if info["state"] == "Loading":
                seen_loading[provider] = True
            elif provider not in terminal_at and info["state"] in ("Fresh", "Stale", "NoSnapshot"):
                dispatched = seen_loading.get(provider) or assume_dispatched
                if dispatched and not not_loaded_status(info["status"]):
                    terminal_at[provider] = round(now - dispatch_at, 3)
        if len(terminal_at) == len(PROVIDERS):
            break
        time.sleep(interval)

    lines = capture(session)
    final = parse_providers(usage_panel(lines))
    payload = {
        "round": label,
        "timeout_s": timeout,
        "interval_s": interval,
        "assume_dispatched": assume_dispatched,
        "first_sample_after_dispatch_s": timeline[0]["t"] if timeline else None,
        "elapsed_to_terminal_s": terminal_at,
        "saw_loading": seen_loading,
        "timeline": timeline,
        "notices": notices,
        "final_redacted": redact(final),
        "final_raw": final,
    }
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, ensure_ascii=False)

    print(f"--- round {label} ---")
    print(f"  first sample landed {payload['first_sample_after_dispatch_s']}s after dispatch")
    for provider in PROVIDERS:
        info = final[provider]
        elapsed = terminal_at.get(provider)
        print(
            f"  {provider:<6} state={info['state']:<10} "
            f"windows={len(info['windows'])} complete={info['complete_windows']} "
            f"saw_loading={seen_loading.get(provider, False)} "
            f"elapsed={elapsed if elapsed is not None else 'NOT REACHED'}s"
        )
        if info["status"]:
            print(f"          status: {info['status']}")
    print("  notices:")
    for entry in notices:
        print(f"    t={entry['t']:>6}s  {entry['text'][:120]}")
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("--interval", type=float, default=0.15)
    parser.add_argument("--out", required=True)
    parser.add_argument("--send-key", help="key to send as this round's dispatch")
    parser.add_argument(
        "--dispatch-at",
        type=float,
        help="a time.monotonic() reading captured at this round's dispatch instant, "
        "for a round dispatched by something other than --send-key (the startup "
        "refresh, whose dispatch is the launch itself)",
    )
    parser.add_argument(
        "--assume-dispatched",
        action="store_true",
        help="startup round only: startAllRefreshes has already set both providers "
        "Loading before the first frame, so a terminal state does not have to wait "
        "on observing Loading first",
    )
    args = parser.parse_args()

    if args.send_key and args.dispatch_at is not None:
        raise SystemExit("--send-key and --dispatch-at are mutually exclusive")

    if args.send_key:
        # The clock starts at the dispatch instant, so it is read immediately
        # BEFORE the keystroke is injected; reading it afterwards would silently
        # discount however long tmux took to deliver the key.
        dispatch_at = time.monotonic()
        subprocess.run(["tmux", "send-keys", "-t", args.session, args.send_key], check=True)
    elif args.dispatch_at is not None:
        dispatch_at = args.dispatch_at
    else:
        dispatch_at = time.monotonic()

    payload = observe(
        args.session,
        args.label,
        dispatch_at,
        args.timeout,
        args.interval,
        args.out,
        args.assume_dispatched,
    )
    reached = all(
        payload["final_raw"][provider]["state"] == "Fresh" for provider in PROVIDERS
    )
    return 0 if reached else 1


if __name__ == "__main__":
    sys.exit(main())
OBSERVE
```

**4. The orchestrator**, which runs both rounds, the census, and the absence
check in order:

```console
cat > "$TMP/run_measurement.sh" <<'RUNNER'
#!/bin/bash
# REL-2 measured run. Round A observes the startup refresh against a cold usage
# cache, so a rendered window can only have come from the live refresh; round B
# observes a later explicit `u`. Each round's clock starts at its own dispatch
# instant: round A's is read immediately before `tmux new-session` and handed to
# the observer, round B's immediately before the keystroke. A recursive
# descendant census runs across both, and its absence check runs after both
# refreshes finish but before Kanban is quit.
set -u

REL="$(cd "$(dirname "$0")" && pwd)"
CHECKOUT="$1"
SESSION=rel2
CENSUS="$REL/census.json"

tmux kill-server 2>/dev/null
sleep 1

echo "=== cache precondition ==="
if [ -f "$HOME/.cache/kanban/usage.json" ]; then
  mv "$HOME/.cache/kanban/usage.json" "$REL/usage.json.backup"
  echo "moved ~/.cache/kanban/usage.json aside -> cold usage cache, no prior snapshot"
else
  echo "no ~/.cache/kanban/usage.json present -> already cold"
fi
rm -rf "$HOME/.cache/kanban/claude-probe"
echo "removed the Claude probe scratch directory so the run recreates it"

echo "=== round A: startup refresh (cold cache) ==="
# The dispatch instant for the startup round is the launch itself, so the clock
# is read here -- before tmux is asked to create the session -- and passed to the
# observer. Reading it after launch, or after the pid discovery below, would
# discount exactly the interval this round is supposed to measure.
LAUNCHED_AT="$(python3 -c 'import time; print(time.monotonic())')"
tmux new-session -d -s "$SESSION" -x 200 -y 50 "$REL/launch_kanban.sh $CHECKOUT"

# The observer starts first and in the background, so sampling begins while the
# pid is still being resolved; Codex turns fresh in well under a second and a
# serialised start would miss its Loading frame entirely.
python3 "$REL/observe_usage.py" --session "$SESSION" --label "A-startup" \
  --dispatch-at "$LAUNCHED_AT" --assume-dispatched \
  --timeout 90 --interval 0.15 --out "$REL/round-a.json" &
OBSERVER_PID=$!

# Resolve the Kanban pid from the pane's own process, not by name matching.
KPID=""
for _ in $(seq 1 100); do
  PANE_PID="$(tmux display-message -p -t "$SESSION" '#{pane_pid}' 2>/dev/null)"
  if [ -n "$PANE_PID" ]; then
    KPID="$(pgrep -P "$PANE_PID" -f 'bin/kanban' | head -1)"
    [ -n "$KPID" ] && break
  fi
  sleep 0.1
done
if [ -z "$KPID" ]; then
  echo "FAILED to resolve the Kanban pid"; kill "$OBSERVER_PID" 2>/dev/null
  tmux capture-pane -t "$SESSION" -p | tail -20; exit 1
fi
echo "kanban pid: $KPID (tmux pane pid $PANE_PID)"

echo "=== census watcher (recursive descendants, pid+start identity) ==="
python3 "$REL/census_tree.py" --watch --root "$KPID" --interval 0.15 --duration 150 \
  --census "$CENSUS" --quiet > "$REL/census.log" 2>&1 &
CENSUS_PID=$!

wait "$OBSERVER_PID"
ROUND_A=$?

echo "=== round B: explicit u refresh ==="
sleep 2
python3 "$REL/observe_usage.py" --session "$SESSION" --label "B-explicit-u" \
  --send-key u --timeout 90 --interval 0.15 --out "$REL/round-b.json"
ROUND_B=$?

echo "=== settle, then stop the census ==="
sleep 5
wait "$CENSUS_PID" 2>/dev/null || kill "$CENSUS_PID" 2>/dev/null
for _ in $(seq 1 200); do [ -f "$CENSUS" ] && break; sleep 1; done
cat "$REL/census.log"

echo "=== requirement 8: absence check, Kanban still running ==="
ps -p "$KPID" -o pid=,command= >/dev/null && echo "kanban pid $KPID still alive: yes"
echo "--- Acceptance 3's immediate-children form, for comparison ---"
ps -axo pid=,ppid=,command= | awk -v k="$KPID" '$2==k' || true
echo "--- the census-based recursive form ---"
python3 "$REL/census_tree.py" --verify --census "$CENSUS"
VERIFY=$?

echo "=== shutdown ==="
tmux send-keys -t "$SESSION" q
sleep 3
if ps -p "$KPID" >/dev/null 2>&1; then echo "kanban still alive after q: UNCLEAN"; else echo "kanban exited after q: clean"; fi
tmux kill-server 2>/dev/null

echo "=== result codes ==="
echo "round A (both Fresh): $ROUND_A   round B (both Fresh): $ROUND_B   census verify: $VERIFY"
RUNNER
chmod +x "$TMP/run_measurement.sh"
"$TMP/run_measurement.sh" "$ROOT"
```

`$ROOT` is the checkout from Build provenance, and is what Kanban is pointed at
with `--path`; any checkout of this repository works in its place.

The usage cache is moved aside rather than deleted, and a successful run
rewrites it; the Claude probe recreates its own scratch directory. The
nesting-inherited round of the previous section is the same sequence with
`REL2_KEEP_NESTING=1` exported and only the startup round observed.

Every `console` block in this record was extracted from this document and run as
published, in a clean directory, to confirm the section is executable top to
bottom: the four artifacts are created in dependency order, the census
self-test passes from the source printed above, and the three configuration
probes emit exactly the three messages quoted earlier.

### REL-3. Installed terminal exercise, macOS, 2026-08-14

D-6's seven-step script **passes** end to end against the sdist-installed
executable. Every step the live board could exercise was exercised, the two
things it could not are named below rather than omitted, shutdown was clean by
three independent checks, and no mutating binding was pressed.

| Step | What it covers | Outcome |
| --- | --- | :---: |
| 1 | Launch and wait for the startup refresh to settle | **pass** |
| 2 | Navigate every column, first/last, card details, expand and collapse an epic | **pass** |
| 3 | Open and close Help, Settings, Processes, Incidents | **pass** |
| 4 | Collapse and restore the sidebar, resize wide → narrow → wide | **pass** |
| 5 | Two explicit `u` refreshes 180 s apart, board navigable during each | **pass** |
| 6 | Five continuous idle minutes, observed as content churn | **pass** |
| 7 | `Ctrl-L` repaint, then quit with `q` | **pass** |

The observation spanned **622.3 s (10 min 22 s)**, of which step 6's untouched
window was **420.2 s (7 min)** — both above the ten-minute total and
five-minute idle floors the issue sets.

#### Build provenance

Two commits matter here and they are deliberately not the same one. The measured
archive was built from a **clean** tree, which by construction cannot already
contain this record; the suites were then run on the tree that **does** contain
it, because `test/Spec/UI/Keys.hs` validates the tracked `docs/design.md`.

| Item | Value |
| --- | --- |
| Commit the archive was built from | `02796721058454c4bc678de9d1f50100a8f91da7` |
| Working tree at that commit | `git status --porcelain=v1 --untracked-files=all` returned empty, so the archive input is exactly that commit |
| Archive | `kanban-1.0.0.0.tar.gz` |
| Installed `--version` | `kanban 1.0.0.0` |
| Install directory | a temporary directory; neither `~/.local/bin` nor `~/.cabal/bin` was used or written |
| Tree the suites ran on | that same commit **plus this record**, i.e. the working tree this pull request commits |

Nothing in this slice changes implementation code, so the record added between
those two points cannot affect the executable that was measured: the archive
built from `0279672` is the binary every number below came from, and the suites
prove the document this pull request adds is the one they validated.

```console
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
test -z "$(git status --porcelain=v1 --untracked-files=all)"
TMP="$(mktemp -d)"
mkdir -p "$TMP/unpacked" "$TMP/bin"
cabal sdist all --builddir "$TMP/dist" --output-directory "$TMP/sdist"
tar -xzf "$TMP"/sdist/kanban-*.tar.gz -C "$TMP/unpacked"
( cd "$TMP"/unpacked/kanban-* && cabal install exe:kanban --installdir "$TMP/bin" --install-method=copy )
"$TMP/bin/kanban" --version
```

The `cd` into the unpacked archive is confined to a subshell deliberately. The
suites below read the *tracked* `docs/design.md` — `test/Spec/UI/Keys.hs` opens
it by relative path — so running them from the unpacked pre-evidence sdist
would validate a copy of this file that does not contain this record.

#### Measurement environment

| Item | Value |
| --- | --- |
| macOS | 26.6 (build 25G5065a) |
| Architecture | arm64, Apple M3 Max, 16 logical CPUs |
| tmux | 3.5a |
| Session | detached, with no client attached; the pane's pty is the terminal under test, which is what D-9's tmux decision contemplates |
| Pane geometry, wide | `200x50`, read back from `#{pane_width}x#{pane_height}` |
| Pane geometry, narrow | `62x40`, read back the same way |
| Toolchain | GHC 9.12.2, cabal-install 3.16.1.0 |
| Python (driver) | 3.14.6 |
| Repository identity | `coghex/kanban` |
| Checkout path | `~/worktrees/coghex/kanban/issue-273-terminal-smoke`, a linked worktree of that repository, passed as `--path` (home abbreviated per D-8) |

#### Safety: nothing was mutated

The script is keyboard-only and sends just the bindings D-6 names. The mutating
ones — `r` review, `S` solve, `A` autosolve, `m` merge, `x` kill, and `d`, which
starts or stops the operator's launchd-managed PR drainer — are refused by the
driver *before* tmux is invoked, so a typo in the step sequence raises rather
than reaching the application. The complete key sequence actually sent was:

```text
l l l h h h  G g G Enter Esc  g e e  ? Esc  o Esc  p Esc  i Esc  c c
g u j  g u j  C-l  q
```

None of `r`, `S`, `A`, `m`, `x`, `d` appears in it.

The drainer's loaded state was read before and after the run with the same
read-only query, `launchctl list | grep drain-prs`, which reports a job's label
and status without altering it:

| When | Result |
| --- | --- |
| Before | `-	0	com.coghex.drain-prs.coghex.kanban` and `-	0	com.coghex.drain-prs.coghex.synarchy` |
| After | byte-identical to the above |

Both jobs stayed loaded and not running (`-` for the pid column, exit status
`0`) across the whole exercise. Kanban's own ten-second drainer poll only
queries status, and the record shows that querying is all that happened.

#### Step 1 — launch and settle

The startup refresh settled **0.98 s** after the driver's first sample, with the
footer reading `board: updated now` and all four column headers present. The
board loaded from the live repository rather than a fixture, so its column
occupancy is whatever the repository held at the time: `ISSUES` 8, `ACTIVE` 1,
`REVIEWING` 1, `DONE` 0. Anyone rerunning this will see different contents, and
the step outcomes below are written to depend on structure rather than on which
particular cards were present.

#### Step 2 — navigation

`l` was pressed three times and `h` three times, walking the focus across all
four columns and back. The selection marker's path was:

| After | Column holding the marker | Selected card |
| --- | --- | --- |
| start | `ISSUES` | `#282` |
| `l` | `ACTIVE` | `#268` |
| `l` | `REVIEWING` | `#268` |
| `l` | none observable | none observable |
| `h` | `REVIEWING` | `#268` |
| `h` | `ACTIVE` | `#268` |
| `h` | `ISSUES` | `#282` |

The one unobservable row is the thing this record must be honest about, and it
is a limitation of the observation method rather than a defect. Focus is drawn
only as the `▌` marker on a selected card, and `DONE` held no cards during the
run, so a focused empty column renders nothing that distinguishes it — the
marker simply disappears on the third `l` and reappears in `REVIEWING` on the
first `h`. That this is genuinely unobservable rather than merely missed was
checked rather than assumed: with two columns empty, captures taken with focus
on each are **byte-identical, including the escape sequences** that
`capture-pane -e` returns, so no attribute change distinguishes them either.
The traversal is evidenced instead by the marker's symmetric return path, which
is only consistent with the focus index having moved across all four columns and
back.

`G` moved the selection to the column's last item, the standalone card `#321`,
and `g` returned it to the first, the epic `#282`. `Enter` on `#321` opened its
details overlay and `Esc` closed it.

Detecting that overlay needs one caveat worth recording, because it is the kind
of thing a rerun on a different board would trip over. Every overlay is drawn
with Brick's `borderWithLabel`, which **centres** its label
(`src/Kanban/UI/Overlay.hs:64-71`), and the details overlay labels itself with
the selected card's own title rather than a fixed word. How much border stroke
sits between the corner and the card number therefore depends on how long that
title is: `#321`'s title nearly fills the panel, so it renders as `┏ #321 …`
with no stroke at all, while a short title would render centred as
`┏━━━━ #99 … ━━━━┓`. The driver anchors on the corner and allows any stroke
between it and the number so both shapes are recognised, and the fixed-label
overlays of step 3 are matched separately by their uppercase names. `e` on `#282` expanded the epic, turning its
`▸` glyph to `▾` and revealing its children, and a second `e` collapsed it
again.

#### Step 3 — overlays

Each overlay opened on its own key and closed with `Esc`:

| Overlay | Key | Opened | Closed | Content |
| --- | --- | --- | --- | --- |
| `HELP` | `?` | yes | yes | populated |
| `SETTINGS` | `o` | yes | yes | populated |
| `PROCESSES` | `p` | yes | yes | empty — `tracked sessions: 0 · live processes: 0` |
| `NEEDS ATTENTION` | `i` | yes | yes | empty — `PR drainer: 0 open incidents` |

Processes and Incidents were **empty, not unavailable**, and are recorded as
exercised: D-6 step 3 asks only that each overlay open and close, and both did
so with their empty-state text rendered. No review, solve, merge, or other
mutation was started from any of them.

#### Step 4 — sidebar and resize

`c` collapsed the 28-column usage sidebar and a second `c` restored it, both
confirmed by the `USAGE` panel leaving and re-entering the frame.

`tmux resize-window` then took the detached session from `200x50` to `62x40` and
back, with both geometries read back from tmux rather than assumed. At `62x40`
exactly one board column, `ISSUES`, was visible; at `200x50` all four were. That
matches section 6: the restored 28-cell sidebar plus a two-cell gutter leaves a
single 32-cell column inside 62 cells, and four columns need 134.

The step's gate names those two counts exactly — one column narrow, four
restored — rather than merely requiring the narrow layout to show fewer than the
wide one, which would also accept a two- or three-column narrow layout that is
not the single-column behaviour D-6 asks for. It also requires both geometries
to read back as the sizes requested and the sidebar to have gone and returned.

#### Step 5 — two refreshes, board navigable during each

Two explicit `u` refreshes were run **180 s apart**, comfortably over the
one-minute separation the script requires.

Responsiveness is evidenced rather than asserted. In each round the driver
recorded the selection, pressed `u`, waited until the footer actually read
`board: refreshing…`, and only then pressed `j` — capturing a frame in which the
footer still reads `board: refreshing…` while the selection has already moved:

| Round | Footer at the captured frame | Selection before `u` | Selection after `j`, same frame |
| --- | --- | --- | --- |
| 1 | `board: refreshing…` | `#282` | `#260` |
| 2 | `board: refreshing…` | `#282` | `#260` |

Both refreshes then settled back to `board: updated now`.

#### Step 6 — five continuous idle minutes

The application was left untouched for **420.2 s**, sampled **1634 times** at a
**0.23 s** cadence. The cadence is deliberately non-commensurate with the
spinner: the spinner advances on a nominal 100 ms minimum delay scheduled after
event processing, so its live period is near one second without being exactly
one, and a 1 Hz sample would return a near-identical glyph every time and make a
running animation look frozen.

Seven of the 1634 frames differed from their predecessor. Every one is
accounted for by a change in underlying state:

| At | Rows changed | What changed | Underlying state |
| --- | --- | --- | --- |
| 4.8 s | 6 | both Claude usage window rows and their reset rows updated, the sidebar's `refreshing…` line cleared, and the notice moved to `Claude usage refreshed` | step 5's second `u` completing its Claude usage refresh |
| 64.0 s | 1 | `board: updated now` → `updated 1m ago` | relative-age text advancing |
| 125.0 s | 1 | `updated 1m ago` → `2m ago` | as above |
| 185.8 s | 1 | `updated 2m ago` → `3m ago` | as above |
| 246.7 s | 1 | `updated 3m ago` → `4m ago` | as above |
| 307.6 s | 1 | `updated 4m ago` → `5m ago` | as above |
| 368.5 s | 1 | `updated 5m ago` → `6m ago` | as above |

**Observable content churn: none.** D-9 defines churn as the screen changing
when no underlying state changed, and no such frame occurred: six changes are
the relative-age footer ticking over one minute at a time, and the seventh is a
provider refresh dispatched before the idle window began finishing inside it.
Every row that changed at any point belongs to the usage sidebar or the two
footer lines; no board row changed once, and after the first 5 s nothing outside
the footer changed for the remaining 415 s.

As D-9 requires this to be said plainly: **true flicker is not measured at
1.0.** `capture-pane` returns content, not repaints, so a redraw that rewrites
identical cells is invisible to this method. What is recorded above is content
churn only, and no human watched the frame.

#### Step 7 — repaint and quit

`Ctrl-L` forced a repaint. The frame before and after is not byte-identical, and
the two rows that differ are both explained state, not churn: the footer's
relative age ticked `6m ago` → `7m ago`, and the notice line became
`Terminal repainted`, which is the repaint's own acknowledgement. No board
content moved.

`q` then quit the application.

#### Shutdown, checked three independent ways

A session whose command *is* Kanban dies with it, which proves the session is
gone but can say nothing about the terminal it left behind. So Kanban was run
inside a shell in the pane, letting the pty outlive it and be inspected:

| Check | Method | Result |
| --- | --- | --- |
| Terminal restored | `stty -g` captured in the same pty before launch and after exit | **identical**, 220 bytes both times — line discipline fully restored |
| Process exited | the wrapping shell echoed Kanban's status, and the captured pid was checked afterwards | `KANBAN_EXIT=0`; `ps -p <pid>` reports it gone |
| Session gone | `tmux -L rel3-smoke-<pid> has-session -t rel3`, against the driver's own server rather than the default one | absent |

The pane after quitting shows the normal screen restored with `KANBAN_EXIT=0`
and the shell's own marker visible, so the alternate screen was exited rather
than merely overwritten.

All three checks are performed **by the driver itself and gate its result**,
which matters because an unrestored terminal is exactly the kind of failure a
record could otherwise report a pass over. The driver waits for the post-exit
`stty -g` to be written, compares it against the pre-launch capture, and marks
step 7 `fail` unless the two match *and* the shell's marker is on screen; its
overall exit status additionally requires the pid to be gone, the session to be
absent, and the drainer state to be unchanged. A run that left the terminal in
raw mode could not produce a passing script here.

#### What could not be exercised

Per Requirement 8, named rather than omitted:

- **The `DONE` column held no cards.** It was navigated through, but with no
  card to mark, focus on it is not observable in `capture-pane` output at all —
  verified byte-identical including escapes, as described under step 2.
  Card-level actions in `DONE` were therefore not exercised, which also means
  the `m` merge binding had nothing to act on; that binding is forbidden by this
  script regardless.
- **The `PROCESSES` and `NEEDS ATTENTION` overlays had no content**, because no
  agent session was running and the drainer had no open incidents. Both still
  opened and closed correctly with their empty-state text, which is what D-6
  step 3 asks for, so they are recorded as exercised rather than unavailable.

Neither gap is a script failure. D-6 explicitly allows a live fixture to lack an
applicable item provided the record says what could not be exercised.

#### Conclusion

**The script passes.** All seven steps completed, the observation spanned
10 min 22 s including 7 continuous idle minutes, no interaction failed or hung,
refresh responsiveness was demonstrated rather than asserted, the safety
invariant was verified by identical before/after drainer queries and by a key
log containing no mutating binding, and shutdown was clean by three independent
checks. Nothing here blocks REL-4.

Six earlier runs were discarded rather than reinterpreted, and none was
discarded for its result — all six passed all seven steps. Each was superseded
because the *driver* had a defect worth fixing before publishing it, and since
every fix changes the artifact this record publishes, the exercise was re-run
rather than the source corrected after the fact. The run recorded here is the
seventh, and the driver printed below is the one that produced its numbers rather
than a tidied variant:

1. **534.1 s** — under the ten-minute floor, because the interactive steps
   finished far faster than budgeted. Repeated with a longer refresh separation
   and a longer idle window rather than the floor being reasoned away.
2. **623.7 s** — the driver reset tmux on the **default** socket. Unsafe to
   publish: an operator reproducing this record would lose whatever unrelated
   tmux sessions they had running.
3. **624.8 s** — moved to a private socket, but a **fixed**-name one, which is
   only safe if nothing else already owns that name; the driver neither created
   nor proved ownership of that server before clearing it. That run also let
   step 7 report a pass without checking that the terminal had actually been
   restored, which is precisely the failure the shutdown requirement exists to
   catch.
4. **621.6 s** and **623.2 s** — the first detected the details overlay by a
   pattern that only matches when the selected card's title is long enough to
   leave no border stroke before its number, and the second still matched only
   the *issue* heading form, so selecting a pull request would have hung step 2
   even though the overlay had opened. Both worked on this board and neither
   would survive a different one. The second of the two also computed whether
   the tracker re-collapsed and then left that out of its pass predicate, so
   step 2 could have passed with a tracker left expanded.
5. **622.0 s** — gated step 4 on the narrow layout showing merely *fewer*
   columns than the wide one, which would also accept a two- or three-column
   narrow layout rather than the single-column one D-6 asks for.

No threshold, step, or method was altered to obtain a pass. The board's column
occupancy did change between those runs and this one — a pull request entered
`REVIEWING` — which is why only `DONE` is empty above; that is live-fixture
drift, not a change to the script.

#### Reproducing this record

Two artifacts drive the exercise, given here before the invocation that uses
them. The first is the session command: it exists so the pty survives Kanban's
exit, which is what makes the terminal-restoration check above possible.

```console
cat > "$TMP/session.sh" <<'SESSION'
#!/bin/bash
# REL-3 session command. Kanban runs inside this shell rather than as the tmux
# session's own command, so the PTY outlives it and the same terminal can be
# inspected for restored line discipline after `q` -- evidence a session that
# died with the application could never produce.
set -u

STTY_BEFORE="$1"
STTY_AFTER="$2"
BIN="$3"
CHECKOUT="$4"

stty -g > "$STTY_BEFORE"
"$BIN" --path "$CHECKOUT"
status=$?
echo "KANBAN_EXIT=$status"
stty -g > "$STTY_AFTER"
echo "TERMINAL_RESTORED_MARKER"
sleep 6
SESSION
chmod +x "$TMP/session.sh"
```

The second is the driver, which sends the keys, classifies each frame, times the
idle window, refuses every mutating binding, and enforces the shutdown checks
described above.

It cannot disturb tmux work that is not its own. Every tmux call goes to a
socket named for the driver's own process, `tmux -L rel3-smoke-<pid>`, so two
runs cannot collide and the name cannot be one the operator already uses; the
driver then **refuses to start at all** if a server is already listening there,
rather than clearing it. `kill-server` appears nowhere in the driver, because no
fixed socket name can be made safe by naming alone — any name might already
belong to someone. The only thing it ever tears down is the single session it
created, with `kill-session`. Both halves were verified rather than assumed: an
unrelated session placed on the driver's own socket survives, and the driver
exits with `REFUSED: a tmux server is already listening on socket …` instead of
touching it.

```console
cat > "$TMP/smoke_script.py" <<'SMOKE'
#!/usr/bin/env python3
"""REL-3 driver for D-6's seven-step installed-terminal smoke script.

Keyboard-only, under a detached tmux session of a stated geometry. The script
sends ONLY the navigation, overlay, sidebar, refresh, repaint and quit keys D-6
names; the mutating keys -- `r` review, `S` solve, `A` autosolve, `m` merge,
`x` kill, and above all `d`, which toggles the operator's launchd-managed PR
drainer -- are rejected by `send` before tmux is ever invoked.

Screen state is read from `capture-pane`, which returns content rather than
repaints (D-9), so this measures observable content churn and not true flicker.
The sampling cadence is deliberately non-commensurate with the spinner: the
spinner advances on a nominal 100 ms minimum delay scheduled after event
processing, so its live period is near one second but not exact, and a 1 Hz
sample would return a near-identical glyph every time.

Temporary measurement artifact for issue #273. Not part of the repository.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

SESSION = "rel3"

# Every tmux call goes to a private server on a socket named for THIS process,
# so two runs cannot collide and the name cannot be one the operator already
# uses. The driver additionally refuses to start if a server is already
# listening on it (see `claim_socket`), so it never destroys a server it did
# not create -- it has no `kill-server` at all, and tears down only the single
# session it made.
SOCKET = f"rel3-smoke-{os.getpid()}"

FORBIDDEN = {"r", "S", "A", "m", "x", "d"}
PANEL_RE = re.compile(r"━ ([A-Z][A-Z ]*[A-Z]) ━")

# Every overlay is drawn with Brick's `borderWithLabel`, which CENTRES its label
# (src/Kanban/UI/Overlay.hs). The details overlay labels itself with the card's
# own heading, so two things vary and both have to be tolerated.
#
# How much border stroke precedes the heading depends on how long it is: a
# heading nearly as wide as the panel leaves none at all (`┏ #321 …`), a short
# one leaves a run of them (`┏━━━━ #99 …`).
#
# The heading itself has three forms, from `Kanban.UI.Util.itemHeading`: an
# issue is `#<n>`, a pull request is `PR #<n>`, and a draft pull request is
# `DRAFT #<n>` -- note the draft prefix replaces `PR ` rather than extending it.
# Selecting a pull request and matching only the issue form would hang step 2
# even though the overlay had opened.
DETAILS_RE = re.compile(r"┏[━]*\s*(?:DRAFT\s+|PR\s+)?#(\d+)")
SELECTION_RE = re.compile(r"▌.*?#(\d+)")

log_lines = []


def log(message):
    stamp = time.strftime("%H:%M:%S")
    line = f"[{stamp}] {message}"
    print(line, flush=True)
    log_lines.append(line)


def tmux(*args, text=True):
    """Run one tmux command against this driver's private socket."""
    return subprocess.run(
        ["tmux", "-L", SOCKET, *args], capture_output=True, text=text, check=False
    )


def capture(escapes=False):
    args = ["capture-pane", "-t", SESSION, "-p"]
    if escapes:
        args.append("-e")
    return tmux(*args).stdout


def send(key, literal=True):
    """Send one key, refusing every mutating binding D-6 forbids."""
    if literal and key in FORBIDDEN:
        raise SystemExit(f"REFUSED: {key!r} is a mutating binding and must never be sent")
    if literal:
        tmux("send-keys", "-t", SESSION, "-l", key)
    else:
        tmux("send-keys", "-t", SESSION, key)
    time.sleep(0.12)


def panels(frame):
    """Titled overlay panels currently on screen, excluding the board chrome."""
    found = set(PANEL_RE.findall(frame))
    found.discard("USAGE")
    for name in list(found):
        if name in {"ISSUES", "ACTIVE", "REVIEWING", "DONE"}:
            found.discard(name)
    if DETAILS_RE.search(frame):
        found.add("DETAILS")
    return found


def selection(frame):
    """The selected card's issue number, or None when nothing is marked.

    Focus is drawn only as the `▌` marker on the selected card, so a column
    holding no cards shows no marker at all.
    """
    lines = frame.splitlines()
    for index, line in enumerate(lines):
        if "▌" in line:
            match = SELECTION_RE.search(line)
            if match:
                return match.group(1)
            # A standalone card's marked row is the box's top border, so the
            # issue number sits on one of the following rows inside the box.
            column = line.find("▌")
            for following in lines[index + 1 : index + 4]:
                found = re.search(r"#(\d+)", following[max(0, column - 2) :])
                if found:
                    return found.group(1)
            return "marked-no-id"
    return None


def selected_column(frame):
    """Which board column the `▌` marker sits in, by its x offset."""
    header = next((l for l in frame.splitlines() if "ISSUES" in l and "DONE" in l), "")
    bounds = []
    for name in ("ISSUES", "ACTIVE", "REVIEWING", "DONE"):
        idx = header.find(name)
        if idx >= 0:
            bounds.append((idx, name))
    bounds.sort()
    for line in frame.splitlines():
        pos = line.find("▌")
        if pos >= 0:
            chosen = None
            for idx, name in bounds:
                if pos >= idx - 20:
                    chosen = name
            return chosen
    return None


def footer(frame):
    for line in frame.splitlines():
        stripped = line.strip("║ ").strip()
        if stripped.startswith("board:"):
            return stripped
    return ""


def sidebar_present(frame):
    return "━ USAGE ━" in frame or " USAGE " in frame


def pane_size():
    out = tmux("display-message", "-p", "-t", SESSION, "#{pane_width}x#{pane_height}").stdout.strip()
    return out


def wait_for(predicate, timeout, poll=0.15, what=""):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        frame = capture()
        if predicate(frame):
            return frame
        time.sleep(poll)
    raise SystemExit(f"TIMEOUT after {timeout}s waiting for {what}")


def claim_socket():
    """Refuse to run against a tmux server this driver did not create.

    `kill-server` appears nowhere in this driver precisely because it cannot be
    made safe by naming alone: any fixed socket name might already belong to
    someone. Instead the socket is per-process and its emptiness is checked, so
    the only thing ever torn down is the one session created below.
    """
    probe = tmux("list-sessions")
    if probe.returncode == 0:
        raise SystemExit(
            f"REFUSED: a tmux server is already listening on socket {SOCKET!r}; "
            "this driver only ever runs against a server it created itself"
        )


def drop_session():
    """Tear down only the session this driver created, if it still exists."""
    if tmux("has-session", "-t", SESSION).returncode == 0:
        tmux("kill-session", "-t", SESSION)


def drainer_state():
    out = subprocess.run(["launchctl", "list"], capture_output=True, text=True).stdout
    return sorted(l for l in out.splitlines() if "drain-prs" in l)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--checkout", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--session-script", required=True)
    parser.add_argument("--stty-before", required=True)
    parser.add_argument("--stty-after", required=True)
    parser.add_argument("--refresh-gap", type=float, default=150.0)
    parser.add_argument("--idle", type=float, default=360.0)
    parser.add_argument("--idle-interval", type=float, default=0.23)
    args = parser.parse_args()

    results = {"steps": {}, "keys_sent": [], "forbidden_keys": sorted(FORBIDDEN)}

    drainer_before = drainer_state()
    log(f"drainer BEFORE (launchctl list | grep drain-prs): {drainer_before}")
    results["drainer_before"] = drainer_before
    results["drainer_query"] = "launchctl list | grep drain-prs"

    claim_socket()
    log(f"claimed a private tmux socket {SOCKET!r} with no server on it")

    # The session command is a script that wraps Kanban in a shell so the PTY
    # outlives it: the same terminal can then be inspected for restored line
    # discipline, which a session that dies with the application could never
    # show.
    shell_command = (
        f"{args.session_script} {args.stty_before} {args.stty_after} "
        f"{args.binary} {args.checkout}"
    )
    tmux("new-session", "-d", "-s", SESSION, "-x", "200", "-y", "50", shell_command)
    started = time.monotonic()

    pane_pid = tmux("display-message", "-p", "-t", SESSION, "#{pane_pid}").stdout.strip()
    kanban_pid = ""
    for _ in range(120):
        out = subprocess.run(
            ["pgrep", "-P", pane_pid, "-f", "bin/kanban"], capture_output=True, text=True
        ).stdout.split()
        if out:
            kanban_pid = out[0]
            break
        time.sleep(0.1)
    if not kanban_pid:
        raise SystemExit("could not resolve the Kanban pid")
    results["kanban_pid"] = kanban_pid
    results["pane_pid"] = pane_pid
    log(f"kanban pid {kanban_pid} in pane {pane_pid}, geometry {pane_size()}")

    def step(name, body):
        t0 = time.monotonic()
        log(f"--- STEP {name} ---")
        outcome = body()
        outcome["elapsed_s"] = round(time.monotonic() - t0, 2)
        results["steps"][name] = outcome
        log(f"    -> {outcome.get('verdict')}  ({outcome['elapsed_s']}s)")

    def keyed(key, literal=True):
        results["keys_sent"].append(key)
        send(key, literal)

    # ---------------------------------------------------------------- step 1
    def step1():
        frame = wait_for(
            lambda f: "board:" in footer(f) and "refreshing" not in footer(f),
            60,
            what="the startup refresh to settle",
        )
        columns = [c for c in ("ISSUES", "ACTIVE", "REVIEWING", "DONE") if c in frame]
        return {
            "verdict": "pass" if len(columns) == 4 and "updated" in footer(frame) else "fail",
            "geometry": pane_size(),
            "footer": footer(frame),
            "columns_seen": columns,
            "initial_selection": selection(frame),
        }

    # ---------------------------------------------------------------- step 2
    def step2():
        detail = {}
        frame = capture()
        detail["start_column"] = selected_column(frame)

        traversal = []
        for _ in range(3):
            keyed("l")
            time.sleep(0.5)
            f = capture()
            traversal.append({"column": selected_column(f), "selection": selection(f)})
        for _ in range(3):
            keyed("h")
            time.sleep(0.5)
            f = capture()
            traversal.append({"column": selected_column(f), "selection": selection(f)})
        detail["traversal"] = traversal
        # The focus must come back to where it started after three `l` and three
        # `h`. A column holding no cards shows no marker at all, so the return
        # path is what evidences having crossed the empty ones.
        detail["columns_traversed"] = (
            traversal[-1]["column"] == detail["start_column"]
            and traversal[-1]["selection"] == selection(frame)
        )

        keyed("G")
        time.sleep(0.6)
        last_sel = selection(capture())
        keyed("g")
        time.sleep(0.6)
        first_sel = selection(capture())
        detail["last_item"] = last_sel
        detail["first_item"] = first_sel
        detail["g_G_moved"] = last_sel != first_sel

        # Details overlay on a real card: G lands on a standalone card, and the
        # overlay's panel header is the card's own title rather than a label.
        keyed("G")
        time.sleep(0.6)
        send("Enter", literal=False)
        results["keys_sent"].append("Enter")
        opened = wait_for(lambda f: "DETAILS" in panels(f), 10, what="the details overlay")
        detail["details_opened"] = True
        detail["details_for"] = DETAILS_RE.search(opened).group(1)
        send("Escape", literal=False)
        results["keys_sent"].append("Escape")
        closed = wait_for(lambda f: "DETAILS" not in panels(f), 10, what="details to close")
        detail["details_closed"] = True

        keyed("g")
        time.sleep(0.6)
        before = capture()
        epic_line_before = next((l for l in before.splitlines() if "▌" in l), "")
        keyed("e")
        time.sleep(1.0)
        after = capture()
        expanded = "▾" in after and "▾" not in before
        keyed("e")
        time.sleep(1.0)
        recollapsed = capture()
        detail["epic_collapsed_glyph_before"] = "▸" if "▸" in epic_line_before else None
        detail["epic_expanded"] = expanded
        detail["epic_recollapsed"] = ("▾" in recollapsed) is False or (
            recollapsed.count("▾") < after.count("▾")
        )
        # Every observation this step makes is required for its verdict. An
        # earlier version computed `epic_recollapsed` and then omitted it, which
        # would have let the step pass with a tracker left expanded -- exactly
        # the half of D-6 step 2 the second `e` exists to cover.
        detail["verdict"] = (
            "pass"
            if all(
                (
                    detail["g_G_moved"],
                    detail["details_opened"],
                    detail["details_closed"],
                    detail["epic_expanded"],
                    detail["epic_recollapsed"],
                    detail["columns_traversed"],
                )
            )
            else "fail"
        )
        return detail

    # ---------------------------------------------------------------- step 3
    def step3():
        overlays = {}
        for key, expect in (("?", "HELP"), ("o", "SETTINGS"), ("p", "PROCESSES"), ("i", "NEEDS ATTENTION")):
            keyed(key)
            frame = wait_for(lambda f, e=expect: e in panels(f), 10, what=f"the {expect} overlay")
            body = [l for l in frame.splitlines() if expect in l]
            send("Escape", literal=False)
            results["keys_sent"].append("Escape")
            wait_for(lambda f, e=expect: e not in panels(f), 10, what=f"{expect} to close")
            overlays[expect] = {"key": key, "opened": True, "closed": True, "header": body[:1]}
            log(f"    {expect}: opened with {key!r}, closed with Esc")
        every_overlay = all(
            o["opened"] and o["closed"] for o in overlays.values()
        ) and len(overlays) == 4
        return {"verdict": "pass" if every_overlay else "fail", "overlays": overlays}

    # ---------------------------------------------------------------- step 4
    def step4():
        wide = pane_size()
        before = capture()
        keyed("c")
        collapsed = wait_for(lambda f: not sidebar_present(f), 10, what="the sidebar to collapse")
        keyed("c")
        restored = wait_for(lambda f: sidebar_present(f), 10, what="the sidebar to restore")

        tmux("resize-window", "-t", SESSION, "-x", "62", "-y", "40")
        time.sleep(2.0)
        narrow_size = pane_size()
        narrow = capture()
        narrow_columns = [c for c in ("ISSUES", "ACTIVE", "REVIEWING", "DONE") if c in narrow]

        tmux("resize-window", "-t", SESSION, "-x", "200", "-y", "50")
        time.sleep(2.0)
        back_size = pane_size()
        back = capture()
        back_columns = [c for c in ("ISSUES", "ACTIVE", "REVIEWING", "DONE") if c in back]

        # D-6 step 4 asks for a *single-column* narrow layout and a restored wide
        # one, so the gate names both counts exactly. Merely requiring the narrow
        # layout to show fewer columns than the wide one would also accept two or
        # three of them, which is not the layout being verified.
        narrow_is_single_column = len(narrow_columns) == 1
        wide_shows_all_columns = len(back_columns) == 4
        return {
            "verdict": "pass"
            if (not sidebar_present(collapsed))
            and sidebar_present(restored)
            and narrow_is_single_column
            and wide_shows_all_columns
            and narrow_size == "62x40"
            and back_size == wide
            else "fail",
            "narrow_is_single_column": narrow_is_single_column,
            "wide_shows_all_columns": wide_shows_all_columns,
            "wide_geometry": wide,
            "narrow_geometry": narrow_size,
            "restored_geometry": back_size,
            "narrow_columns_visible": narrow_columns,
            "wide_columns_visible": back_columns,
            "sidebar_collapsed_ok": not sidebar_present(collapsed),
            "sidebar_restored_ok": sidebar_present(restored),
        }

    # ---------------------------------------------------------------- step 5
    def refresh_round(label):
        # Focus a column with several cards so `j` has somewhere to move.
        keyed("g")
        time.sleep(0.5)
        before_sel = selection(capture())
        keyed("u")
        proof = None
        deadline = time.monotonic() + 20
        moved = False
        while time.monotonic() < deadline:
            frame = capture()
            if "refreshing" in footer(frame):
                if not moved:
                    keyed("j")
                    moved = True
                    continue
                now_sel = selection(frame)
                if now_sel != before_sel:
                    proof = {
                        "footer": footer(frame),
                        "selection_before": before_sel,
                        "selection_during": now_sel,
                    }
                    break
            time.sleep(0.05)
        settled = wait_for(
            lambda f: "refreshing" not in footer(f), 60, what="the refresh to settle"
        )
        return {
            "label": label,
            "responsive_proof": proof,
            "settled_footer": footer(settled),
        }

    def step5():
        first = refresh_round("refresh-1")
        log(f"    refresh 1 proof: {first['responsive_proof']}")
        log(f"    waiting {args.refresh_gap}s before the second refresh")
        time.sleep(args.refresh_gap)
        second = refresh_round("refresh-2")
        log(f"    refresh 2 proof: {second['responsive_proof']}")
        ok = bool(first["responsive_proof"]) and bool(second["responsive_proof"])
        return {
            "verdict": "pass" if ok else "fail",
            "gap_s": args.refresh_gap,
            "rounds": [first, second],
        }

    # ---------------------------------------------------------------- step 6
    def step6():
        log(f"    idle window: {args.idle}s at {args.idle_interval}s cadence")
        frames = []
        t0 = time.monotonic()
        previous = None
        changes = []
        count = 0
        while time.monotonic() - t0 < args.idle:
            frame = capture()
            count += 1
            if previous is not None and frame != previous:
                before_lines = previous.splitlines()
                after_lines = frame.splitlines()
                changed = [
                    {"row": i, "before": b.strip("║ ").rstrip(), "after": a.strip("║ ").rstrip()}
                    for i, (b, a) in enumerate(zip(before_lines, after_lines))
                    if b != a
                ]
                changes.append({"t": round(time.monotonic() - t0, 2), "lines": changed})
            previous = frame
            time.sleep(args.idle_interval)
        return {
            "verdict": "pass",
            "captures": count,
            "cadence_s": args.idle_interval,
            "window_s": round(time.monotonic() - t0, 1),
            "frames_differing_from_predecessor": len(changes),
            "changes": changes,
        }

    # ---------------------------------------------------------------- step 7
    def step7():
        before = capture()
        send("C-l", literal=False)
        results["keys_sent"].append("C-l")
        time.sleep(1.5)
        after = capture()
        repaint_identical = before.strip() == after.strip()
        repaint_diff = [
            {"row": i, "before": b.strip("║ ").rstrip(), "after": a.strip("║ ").rstrip()}
            for i, (b, a) in enumerate(zip(before.splitlines(), after.splitlines()))
            if b != a
        ]
        keyed("q")

        # The wrapping shell writes the post-exit line discipline once Kanban
        # has returned; wait for it rather than assuming 3 seconds was enough.
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if os.path.exists(args.stty_after) and os.path.getsize(args.stty_after) > 0:
                break
            time.sleep(0.2)

        post = capture()
        marker_seen = "TERMINAL_RESTORED_MARKER" in post

        # Terminal restoration is verified HERE, by this driver, and gates the
        # step: a run that leaves the terminal unrestored must not be able to
        # report a passing script.
        try:
            before_state = open(args.stty_before, encoding="utf-8").read().strip()
        except OSError:
            before_state = ""
        try:
            after_state = open(args.stty_after, encoding="utf-8").read().strip()
        except OSError:
            after_state = ""
        restored = bool(before_state) and before_state == after_state

        return {
            "verdict": "pass" if (restored and marker_seen) else "fail",
            "repaint_content_identical": repaint_identical,
            "repaint_diff": repaint_diff,
            "terminal_restored": restored,
            "stty_before_present": bool(before_state),
            "stty_after_present": bool(after_state),
            "stty_bytes": len(before_state),
            "post_quit_pane_has_marker": marker_seen,
            "post_quit_pane_tail": [l for l in post.splitlines() if l.strip()][-6:],
        }

    step("1-launch-and-settle", step1)
    step("2-navigation", step2)
    step("3-overlays", step3)
    step("4-sidebar-and-resize", step4)
    step("5-two-refreshes", step5)
    step("6-idle-five-minutes", step6)
    step("7-repaint-and-quit", step7)

    results["total_elapsed_s"] = round(time.monotonic() - started, 1)
    log(f"total observation: {results['total_elapsed_s']}s")

    # Shutdown, three independent ways.
    time.sleep(6)
    alive = subprocess.run(["ps", "-p", kanban_pid], capture_output=True).returncode == 0
    has_session = subprocess.run(
        ["tmux", "-L", SOCKET, "has-session", "-t", SESSION], capture_output=True
    ).returncode == 0
    restored = results["steps"]["7-repaint-and-quit"].get("terminal_restored", False)
    results["shutdown"] = {
        "kanban_pid_alive": alive,
        "tmux_session_present": has_session,
        "terminal_restored": restored,
    }
    log(
        f"shutdown: pid alive={alive}, session present={has_session}, "
        f"terminal restored={restored}"
    )
    drop_session()

    drainer_after = drainer_state()
    results["drainer_after"] = drainer_after
    results["drainer_unchanged"] = drainer_after == drainer_before
    log(f"drainer AFTER: {drainer_after} (unchanged={results['drainer_unchanged']})")

    results["log"] = log_lines
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(results, handle, indent=2, ensure_ascii=False)
    log(f"wrote {args.out}")

    failed = [n for n, s in results["steps"].items() if s.get("verdict") != "pass"]
    ok = (
        not failed
        and not alive
        and not has_session
        and restored
        and results["drainer_unchanged"]
    )
    if not ok:
        log(
            f"SCRIPT FAILED: failed steps={failed}, pid alive={alive}, "
            f"session present={has_session}, terminal restored={restored}, "
            f"drainer unchanged={results['drainer_unchanged']}"
        )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
SMOKE
```

Running it, from the implementation checkout so the suites afterwards read the
tracked `docs/design.md`:

```console
python3 -u "$TMP/smoke_script.py" \
  --binary "$TMP/bin/kanban" --checkout "$ROOT" \
  --session-script "$TMP/session.sh" \
  --out "$TMP/smoke.json" \
  --stty-before "$TMP/stty_before.txt" --stty-after "$TMP/stty_after.txt" \
  --refresh-gap 180 --idle 420 --idle-interval 0.23
echo "script result: $?"    # 0 only if every gate below held
```

The driver's **exit status is the result of the script**, and it is the only
thing worth checking afterwards. It is zero only when every step passed, the
Kanban pid is gone, the tmux session is gone, the terminal's line discipline was
restored, and the drainer's loaded state was unchanged; on anything else it logs
which of those failed and exits non-zero. Re-checking the session from the shell
afterwards would be worse than redundant — the driver runs on its own
`-L rel3-smoke-<pid>` server, so a `tmux has-session` against the default server
would answer about a different server entirely and print `session gone` no
matter what the tested session was doing. The same applies to the `stty`
comparison, which the driver performs against the pty that actually ran Kanban.

#### Suites

Both suites pass on the tree that carries this record — that is, commit
`0279672` plus this subsection, not `0279672` itself, which predates it — and
were run from the implementation checkout rather than the unpacked archive:

```console
cabal test all --test-show-details=direct
python3 -m unittest discover -s tools -p 'test_*.py' < /dev/null
```

The Haskell suite reported `1101 examples, 0 failures` and
`Test suite kanban-test: PASS`; the Python suite ran 1336 tests, `OK`. The
Python suite's stdin is redirected because a fake-CLI call stalls for 60 seconds
per invocation when stdin is a non-tty pipe.

## Decisions

### D-1. First-release evidence includes a real installed-terminal run

Fixture and integration coverage do not replace the release-gate checks that
depend on an actual terminal, process table, authenticated provider clients, and
operator-visible redraw behavior. The results must be recorded in this design
before the release is published.

Amended 2026-08-12. D-9 settles that a tmux pane is the terminal for these gates
and narrows the redraw clause above to observable content churn. D-12 names the
sdist-built install as the measured artifact, and D-13 puts the results in a new
section 21.

### D-2. Live usage verification must not consume a model prompt

The Codex app-server rate-limit request and Claude `/usage` interaction are
account-status probes. A release check that submits an ordinary prompt would
change user-visible account consumption and would not verify the promised
bounded behavior.

### D-3. Publication follows every manual gate and required CI

The release tag is a final operation. It must identify a commit containing the
accepted manual evidence, and that commit must pass the repository's required
build and test checks.

### D-4. First-release performance gates are generous smoke limits

`REL-1` uses thresholds intended to catch a runaway process or unusable startup,
not to demand optimization before there is field evidence. Test three
consecutive launches of the installed executable; each must present a usable
first frame within 10 seconds. After startup and refresh activity has settled
for 30 seconds, sample the Kanban process once per second for 60 seconds. The
sample passes when mean CPU is no more than 2%, no five consecutive samples are
all above 5%, and peak resident memory is no more than 512 MiB. One explicit
`u` refresh must remain responsive, and the following idle minute must initiate
no further GitHub or usage refresh. The expected ten-second local drainer
status checks may cause isolated event handling, but continuous visible
repainting or flicker fails the gate.

These are release acceptance ceilings rather than performance promises. The
record keeps the observed values so a later release can tighten them from real
evidence without retroactively changing the 1.0 gate.

Amended 2026-08-12. The thresholds above stand unchanged; D-10 and D-11 supply
what the decision never said. Samples cover Kanban's process group with the
drainer loaded, and "usable first frame" means the GitHub-populated board.

### D-5. The first release is version 1.0.0.0 and GitHub-only

Kanban's first release is package version `1.0.0.0`. Since 2026-08-13 that
version is established ahead of publication — #283, under packaging epic #282,
set it in `kanban.cabal` and `src/Kanban/CLI.hs` — so the release commit carries
it rather than updating it. Publication creates a GitHub Release for tag
`v1.0.0.0`. The `v` prefix distinguishes the Git tag from the bare
package-version value; a bare `1.0.0.0` tag was considered but rejected in
favor of that conventional distinction. Hackage or another
package registry, binary installers, and distribution through any channel other
than GitHub are outside the first-release arc.

### D-6. Use a ten-minute installed-terminal exercise

`REL-3` uses a deliberately conservative ten-minute script. It is longer than
the expected time needed to expose obvious terminal churn, but remains a short
release smoke check rather than endurance testing:

1. Launch the installed executable and wait for the startup refresh to settle.
2. Navigate through every board column; use first/last selection, open and
   close card details, and expand and collapse one tracker when available.
3. Open and close Help, Settings, Processes, and Incidents without starting a
   review, solve, merge, or other mutation.
4. Collapse and restore the sidebar, then resize from a wide layout to a narrow
   single-column layout and back.
5. Run two explicit `u` refreshes at least one minute apart and confirm that the
   board remains navigable while each refresh is active.
6. Leave the application untouched for five continuous minutes and observe
   whether the frame flickers, churns, or changes without new underlying state.
7. Force one repaint with `Ctrl-L`, then quit with `q` and confirm that the
   terminal is restored.

The record may mark a tracker or an overlay unavailable when the live fixture
contains no applicable item, but it must say what could not be exercised.

### D-7. Track the four remaining outcomes as separate delivery slices

Performance calibration, authenticated usage-provider verification, sustained
terminal exercise, and release publication have different evidence and failure
modes. Keeping them separate makes a failed gate independently repeatable while
preserving `REL-4` as the single dependency join.

### D-8. Record reproducible summaries rather than sensitive raw transcripts

Each manual slice should record the environment, client versions, commands or
interactions, elapsed observation window, and pass/fail result. It should omit
account identifiers, usage balances, access tokens, and raw provider output not
needed to reproduce the conclusion.

### D-9. The manual gates run under tmux, executed by the agent pipeline

User signoff 2026-08-12, resolving `Q-4`. `REL-1`, `REL-2`, and `REL-3` are
ordinary solvable issues carrying runnable acceptance commands: a detached tmux
session of a fixed size runs the installed executable, `send-keys` drives it,
`capture-pane` reads the screen back, and the process table is sampled from
outside. This keeps every gate repeatable by whoever reruns it and keeps a
failed gate cheap to repeat.

The cost is deliberate and must not be papered over. A tmux pane is a real PTY,
but `capture-pane` returns content, not repaints, so a redraw that rewrites
identical cells is invisible to it. D-1's "operator-visible redraw behavior" is
therefore narrowed for the first release to **observable content churn**: the
screen changing when no underlying state changed, detected by diffing successive
captures. True flicker — repaint volume with a stable screen — is not measured
at 1.0. The records must say so in those words rather than implying a human
watched the frame. Each record still names the host terminal and tmux versions
and the pane geometry, because they bound what was observed.

### D-10. CPU and memory samples cover the process group with the drainer loaded

User signoff 2026-08-12, resolving `Q-5`. D-4's ceilings apply to Kanban **and
its children**, sampled once per second, with the drainer's launchd job loaded
as in normal operation. Single-PID sampling was rejected: the ten-second
controller poll would vanish from the measurement, and a runaway child — close
to the failure D-4 exists to catch — would pass.

Consequence to carry into `REL-1`: the poll alone costs about 0.07 s of CPU
every ten seconds, roughly 0.7% of a core, so the board's own steady-state
behavior has about 1.3% of the 2% mean budget left. If the gate fails on the
poll rather than on Kanban, that is evidence for amending the threshold or
making the poll cheaper — a release-blocking defect to be resolved or explicitly
scoped out under the epic's `Done when`, not an automatic veto on the release.
The record states the group total, and states the poll's contribution separately
so a later release can tighten either number.

### D-11. The startup clock stops at the GitHub-populated board

User signoff 2026-08-12, resolving `Q-6`. D-4's "usable first frame within 10
seconds" means the frame showing real cards from the completed startup board
refresh, not the cache-backed frame that paints before any network work. The
weaker reading was rejected as measuring almost nothing: that frame appears in
well under a second regardless of how the application behaves afterwards.

Consequence: all three launches are network-bound against a 10 s ceiling, and
prior observation of this board put the populated frame near 8 s. The margin is
real but small. The record states the measured time for each of the three
launches and enough network context to tell a slow GitHub day from a regression;
a failure attributable to GitHub latency rather than to Kanban is re-run and
noted, not treated as a silent pass.

### D-12. The gates measure an install built from the sdist archive

User signoff 2026-08-12, resolving `Q-7`. Every recorded pass or fail comes from
an executable installed out of a `cabal sdist` archive unpacked into a clean
temporary directory — the artifact a release consumer actually receives, and the
same archive `tools/test_source_distribution.py` already proves is a complete
checkout. Installing from the working tree was rejected for the record: it
cannot show that the released archive behaves the same, and deferring that risk
to `REL-4` would discover a packaging fault after the manual gates had already
been accepted.

Iterating on a procedure against a checkout install is fine while developing it.
Each record states which install produced the recorded numbers, names the commit
the archive was built from, and gives the `cabal sdist` and install commands
used. A gate that fails because of an sdist packaging fault rather than runtime
behavior is still a release-blocking defect under the epic's `Done when`, and is
recorded as such rather than retried against the checkout.

### D-13. Release evidence lives in a new numbered section 21

User signoff 2026-08-12, resolving `Q-8`. `REL-1` creates `## 21. Release
evidence` between section 20 and the arc scaffolding, with one subsection per
gate; `REL-2` and `REL-3` append their own subsections to it. The records are
permanent contract content and outlive the `Epic contract` through `Delivery
plan` scaffolding, which comes out when the arc closes.

Verified safe: `test/Spec/UI/Keys.hs:198-207` parses only the rows between
`## 7. Keyboard interaction` and `## 8.`, and
`tools/test_document_classification.py` asserts on this file's row inside
`docs/agent-workflow-contract.md` section 7, not on its body. A new section
therefore breaks no parser, but `REL-1` still runs both suites to prove it.

## Open questions

### Q-1. Which numeric performance limits block the first release?

Resolved by D-4. The first release uses generous smoke limits and records the
actual measurements for later calibration.

### Q-2. How long must the installed-terminal exercise run?

Resolved by D-6. The deliberately conservative ten-minute script is accepted as
the first-release terminal exercise.

### Q-3. What tag spelling identifies the first release?

Resolved by D-5. The first release uses tag `v1.0.0.0` and a GitHub Release.

### Q-4. Does a tmux pane satisfy D-1's "actual terminal"?

Resolved by D-9. The gates run under tmux as agent-solvable issues, and D-1's
redraw clause is narrowed to observable content churn for the first release.

Affects `REL-1`, `REL-2`, and `REL-3`, and decided whether they are solvable by
the agent pipeline at all. The repository's only non-interactive way to drive
the live TUI is tmux — `tmux new-session -d -x 200 -y 50 …`, `send-keys`,
`capture-pane` — and the canonical PR reviewer has previously returned
CHANGES_REQUESTED on a correct PR solely because its body said the live-TUI
checks were skipped. A tmux pane is a real PTY with a real process table, so the
CPU, memory, refresh-count, and interaction gates are all mechanizable there,
and screen churn is measurable by diffing successive captures. What tmux cannot
show is flicker: a repaint that rewrites identical content is invisible to
`capture-pane`. Options: agent-executed under tmux with the host terminal
recorded; operator-executed in a real emulator with the issue supplying a
procedure and a record template; or a split where the mechanical samples are
agent-run and only the flicker verdict is the operator's. Resolving this fixes
whether these issues carry runnable acceptance commands.

### Q-5. Which process do D-4's CPU and memory samples cover, and what is the drainer doing?

Resolved by D-10. The ceilings apply to the process group with the drainer
loaded.

Affects `REL-1`. `ps -o %cpu,rss -p <kanban-pid>` reports that PID alone; the
ten-second controller poll runs in a child costing about 0.07 s of CPU each
time, so process-group sampling and single-PID sampling can differ by roughly a
third of the 2% budget. Separately, the drainer being loaded, unloaded, or
merely recorded gives three different idle profiles, and D-4 names none of them.
A 2% mean ceiling is not checkable until both are stated.

### Q-6. Which frame is D-4's "usable first frame"?

Resolved by D-11. The clock stops at the GitHub-populated board.

Affects `REL-1`. A cache-backed frame paints almost immediately, before any
network work; the GitHub-populated frame lands seconds later, and prior
observation of this board put that near 8 s against a 10 s ceiling. The first
reading passes trivially and measures little; the second measures something real
but is network-dependent with roughly 2 s of margin. A third reading — all
startup refreshes settled, including both usage providers — is stricter again
and overlaps `REL-2`.

### Q-7. Which installed artifact does "a clean source-install exercise" mean?

Resolved by D-12. The gates measure an install built from the sdist archive.

Affects all four slices. Neither `~/.local/bin/kanban` nor `~/.cabal/bin/kanban`
exists today. `README.md`'s "Install from a source checkout" documents
`cabal install exe:kanban` from the checkout, which measures the code on the
branch under test.
`docs/development.md:52-58` and milestone 9 describe a clean sdist unpack, which
measures what a release consumer actually receives and matches `REL-4`'s
concern. The two differ, and "the record names the build commit" reads
differently for each.

### Q-8. Where in this document do the evidence records live?

Resolved by D-13. A new `## 21. Release evidence` section, created by `REL-1`.

Affects `REL-1`, `REL-2`, and `REL-3`; whichever slice lands first binds the
others. The numbered contract ends at section 20, and the arc scaffolding —
`Epic contract` through `Delivery plan` — is temporary processing apparatus that
presumably comes out when the arc closes. Options: a new permanent numbered
section holding one subsection per gate; a block under the scaffolding that is
folded away later; or entries in milestone 9 as implementation history. D-1 says
only that results "must be recorded in this design".

## Verification strategy

Run the installed executable, not `cabal run`, installed from a `cabal sdist`
archive unpacked into a clean temporary directory (D-12). Drive it in a detached
tmux session of a stated geometry, reading the screen back with `capture-pane`
(D-9). Record the macOS, terminal, and tmux versions, the pane geometry, the
Kanban version and the commit the archive was built from, the Codex and Claude
client versions, the observation window, and the commands or key sequences used.

Attribute network activity to startup or to an explicit refresh. Apply D-4's
settling period and one-second samples to Kanban's process group with the
drainer's launchd job loaded, reporting the group total and the controller
poll's contribution separately (D-10). Stop the startup clock at the
GitHub-populated board, not the cache-backed frame (D-11). Report redraw
behavior as observable content churn measured by diffing successive captures,
and say plainly that true flicker is not measured at 1.0 (D-9).

Every record lands in section 21 (D-13) and omits account identifiers, usage
balances, and credentials (D-8). Rerun required CI on the exact commit selected
for release and verify the published tag and GitHub Release resolve to it.

## Delivery plan

### REL-1. Record real-terminal performance measurements

- **Outcome:** A committed, reproducible calibration records installed Kanban's
  startup time, settled idle CPU, resident memory, refresh count, and redraw
  behavior against agreed release limits.
- **Scope:** Define the observation environment and sampling method, run the
  installed executable in a real terminal, record summarized measurements, and
  identify any missed threshold as release-blocking evidence.
- **Phase:** 1 — independent manual gates.
- **Depends on:** `none`.
- **Ordering:** `can land first`.
- **Relevant decisions:** `D-1`, `D-4`, `D-7`, `D-8`, `D-9`, `D-10`, `D-11`,
  `D-12`, `D-13`.
- **Acceptance signals:** Section 21 exists and holds this gate's record, naming
  the sdist commit, host/terminal/tmux context and pane geometry, observation
  window, measurement commands, observed values, and a pass/fail conclusion for
  D-4's startup, CPU, memory, refresh, and content-churn gates. The record
  reports the process-group total and the drainer poll's share separately, and
  states that true flicker is unmeasured. Both test suites still pass, showing
  the new section broke no parser.
- **Out of scope:** Optimizing code or changing the runtime architecture in the
  same slice. Measuring repaint volume rather than content churn.
- **Open questions:** `None`. This slice also owns creating section 21, which
  `REL-2` and `REL-3` then append to.

### REL-2. Verify live Codex and Claude usage refreshes

- **Outcome:** A committed manual record confirms both built-in usage providers
  return current account windows through installed Kanban without submitting a
  model prompt.
- **Scope:** Exercise one authenticated live refresh per provider, record client
  versions and bounded lifecycle behavior, and redact account-specific values.
- **Phase:** 1 — independent manual gates.
- **Depends on:** `REL-1`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-1`, `D-2`, `D-7`, `D-8`, `D-9`, `D-12`, `D-13`.
- **Acceptance signals:** Both sidebar providers reach a successful fresh state,
  no ordinary model prompt is submitted, provider processes exit, and one
  provider's behavior does not hide the other's result. The record appends to
  section 21 and names both client versions.
- **Out of scope:** Broad historical client-version compatibility matrices and
  changes to authenticated provider accounts.
- **Open questions:** `None`. The slice must state whether it observes the
  startup refresh — `startAllRefreshes` already dispatches both providers
  (`src/Kanban/UI/Refresh.hs:43-51`) — or a later explicit one; either is
  acceptable, and the record says which.

### REL-3. Exercise the installed terminal application

- **Outcome:** A committed smoke-test record confirms installed Kanban remains
  responsive and visually stable through its agreed real-terminal observation
  path.
- **Scope:** Cover startup, explicit refresh, card and column navigation,
  overlays used without external mutation, resize behavior, and clean shutdown;
  record any visible redraw churn or lifecycle failure through D-6's concrete
  interaction script.
- **Phase:** 1 — independent manual gates.
- **Depends on:** `REL-1`, `REL-2`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-1`, `D-6`, `D-7`, `D-8`, `D-9`, `D-12`, `D-13`.
- **Acceptance signals:** Every required interaction succeeds for the agreed
  duration and refresh count, shutdown restores the terminal, and the record
  appends to section 21 identifying whether observable content churn occurred.
- **Out of scope:** Starting reviews, solves, merges, or other workflows that
  mutate GitHub or launch long-running agent work.
- **Open questions:** `None`. D-6 step 6 asks whether the frame flickers; under
  D-9 this slice answers the content-churn question by diffing captures and
  records that true flicker is unmeasured at 1.0.

### REL-4. Publish the first Kanban release

> **Deferred 2026-08-12.** Precondition: #269, #270, and #273 have merged and
> section 21 records a pass for each gate. Terminal ledger links are not enough.
> Updated 2026-08-14: all three gates have now been run and each records a pass
> in section 21 — REL-1 and REL-2 have merged, and REL-3 lands with this
> record — so the remaining precondition is #273 merging, not the gates being
> performed. A release-blocking defect found by any of them would still change
> this slice's scope before it can start; none was.
>
> Two things to settle when this slice is reprocessed. First, it does not fit one
> pull request at all: #283 established the package version and the changelog
> under packaging epic #282, so no code change remains for a PR to carry, and
> the `v1.0.0.0` tag and the GitHub Release are post-merge operations against
> master, which `tools/drain_prs.py` merges. Second, the user ruled on
> 2026-08-12 that a solver agent may create the tag and Release itself, with
> the issue as its authorization, once every gate has passed and required CI
> (`build-test` and `review-approved`) is green on the release commit. That
> ruling still needs a `/design-epic` pass to become a numbered decision, since
> D-3 and D-5 say what publication is but not who performs it.

- **Outcome:** Kanban version `1.0.0.0` has a GitHub Release whose tag points to
  the exact required-CI-passing commit containing accepted evidence for every
  manual gate.
- **Scope:** Verify that the already-established package version is `1.0.0.0` in
  both places that carry it — `kanban.cabal` and `src/Kanban/CLI.hs`'s
  hard-coded `"kanban 1.0.0.0"`, which #283 set under packaging epic #282 and
  which `tools/test_version_consistency.py` holds to agreeing — apply the chosen
  tag convention, make any required release-metadata or operator-documentation
  update, verify the release commit, and publish its GitHub Release.
- **Phase:** 2 — publication.
- **Depends on:** `REL-1`, `REL-2`, `REL-3`.
- **Ordering:** `critical path`.
- **Relevant decisions:** `D-3`, `D-5`, `D-7`, `D-8`, `D-12`.
- **Acceptance signals:** Every prerequisite slice is terminal, section 21 holds
  all three accepted records, required CI is green on the selected commit, the
  published identifier resolves to that commit, and the installed executable
  reports `1.0.0.0` from both `--version` and `kanban.cabal`.
- **Out of scope:** Package-registry publication, binary installers, and
  non-GitHub distribution. Establishing the package version or the changelog,
  both of which #283 delivered ahead of this slice; deduplicating the two
  version literals into one source, which that issue also left undone.
- **Open questions:** `None`.
