# Kanban TUI — Design and Roadmap

Status: implementation in progress. The warning-clean GHC2024/Cabal foundation,
local repository resolution, event-driven Brick/Vty dashboard, standalone-card
workflow, explicit GitHub refresh, and last-good repository cache are
implemented. Checklist-based tracker hierarchy, inherited PR membership,
tracker progress, and the on-demand Codex and Claude usage providers are also
implemented. Malformed tracker diagnostics now fail visibly while preserving
valid membership and standalone fallbacks. The sidebar also controls and
monitors the local launchd-managed PR drainer. Native GitHub sub-issue membership,
canonical v2 issue-review sessions, embedded revision questions, and
the first resumable issue-solve flow are implemented. The external
usage-command escape hatch and broader provider-version fixtures remain for
subsequent slices.

## 1. Purpose

`kanban` is a fast, keyboard-driven Haskell terminal dashboard for a GitHub
repository. It is intended to live comfortably in tmux, work over SSH, remain
idle without consuming meaningful CPU, and make no network requests unless the
application starts, the user explicitly updates data, or an explicitly started
review/solve workflow performs its bounded work.

The dashboard combines:

- Codex and Claude five-hour and weekly usage limits in a narrow left sidebar.
- A four-column repository workflow board: Issues, Active, Reviewing, and Done.
- Rich issue and pull-request cards with GitHub label colors, body excerpts,
  assignees, linked work, mergeability, and CI state.
- Epic/tracker grouping based on ordered issue checklists such as `A1`, `A2`,
  `B1`, `C1`, and `C2`.
- Local status and start/stop control for the launchd-managed PR drainer.
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
Starting or stopping the configured PR drainer is the other explicit mutation.

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
- Merging pull requests.
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
kanban --path ~/work/synarchy
kanban --path .
```

Initial options:

```text
--path DIR                         repository path; defaults to cwd
--repo OWNER/NAME                  explicit repository; skips remote resolution
--color auto|truecolor|256|never  color policy; defaults to auto
--border box|open                 border renderer; defaults to box
--glyph-test                      print vertical-line candidates and exit
--ascii                            emergency non-Unicode border fallback
--no-cache                        do not read or write snapshots
--config FILE                     override the global configuration path
--version
--help
```

Startup sequence:

1. Canonicalize `--path`.
2. Resolve the repository root with `git rev-parse --show-toplevel`.
3. Read the configured GitHub remote URL locally.
4. Resolve `owner/name` from the remote, unless `--repo` supplied it directly.
   The flag is the escape hatch for unusual setups: SSH host aliases, multiple
   remotes, and bare mirrors.
5. Load configuration and the last cached snapshot, if enabled.
6. Enter the TUI immediately and asynchronously update GitHub plus both usage
   providers once. The providers remain independent and failure-isolated.

If there is no cached data, the board and usage panes start empty while the
initial update runs.

## 6. Layout

The normal wide-screen layout is a 28-column usage sidebar plus a horizontally
scrollable four-column board.

```text
╔═ USAGE ═════════════╦═ ISSUES ═════╦═ ACTIVE ═════╦═ REVIEWING ══╦═ DONE ═══════╗
║                     ║              ║              ║              ║              ║
║ Codex               ║ cards        ║ cards        ║ cards        ║ cards        ║
║ 5 hour   63% left   ║              ║              ║              ║              ║
║  resets  14:32      ║              ║              ║              ║              ║
║ week     41% left   ║              ║              ║              ║              ║
║  resets  Tue 09:00  ║              ║              ║              ║              ║
║                     ║              ║              ║              ║              ║
║ Claude              ║              ║              ║              ║              ║
║ 5 hour   78% left   ║              ║              ║              ║              ║
║  resets  16:05      ║              ║              ║              ║              ║
║ week     22% left   ║              ║              ║              ║              ║
║  resets  Fri 09:10  ║              ║              ║              ║              ║
║                     ║              ║              ║              ║              ║
║ +--------------+    ║              ║              ║              ║              ║
║ | drain_prs.py |    ║              ║              ║              ║              ║
║ +--------------+    ║              ║              ║              ║              ║
╚═════════════════════╩══════════════╩══════════════╩══════════════╩══════════════╝
 j/Down next  k/Up previous  x kill  h/l column  e epic  enter  r review/revise  S solve  A autosolve  p processes  u update  d drainer  c sidebar  s settings  ? help  q quit
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
| `e` | Expand or collapse the focused epic |
| `Enter` | Open the selected card's details overlay |
| `Esc` | Close an overlay or dismiss a transient error |
| `r` | Start or reopen the selected issue's review session |
| `S` | Choose Codex or Claude and start/reopen an issue solve through PR creation |
| `A` | Choose Codex or Claude and start/reopen the full autosolve review loop |
| `p` | Open the process/session inspector; Enter opens a session and `x` kills its live process tree |
| `u` | Update GitHub board data and both usage providers |
| `d` or click | Start or stop the launchd-managed PR drainer |
| `c` | Collapse or expand the usage sidebar |
| `s` | Open settings, including chat-output verbosity |
| `?` | Open a help overlay listing all bindings |
| `Ctrl-L` | Force a terminal repaint without a network request |
| `Ctrl-C` | Interrupt the current turn in an open live-agent overlay, then accept user guidance for a resumable session |
| `q` | Quit and restore the terminal |

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

### Embedded issue reviews

Pressing `r` on an issue or from its open details starts its label-selected
review stage, or reopens the issue's existing session. Canonical review and
rereview use the synchronous v2 reviewer; interactive revision uses one
persistent Codex app-server. Pressing `r` on a collapsed epic targets the epic
itself. On a PR, `r` is the unified
review/revise key: it starts review, revision, or rereview according to the
durable review labels. App-server starts on demand and one process hosts all
interactive revision threads for the running dashboard; PR actions use resumable
canonical-model CLI sessions because their permissions include PR comments,
labels, worktree edits, commits, and pushes.

PR routing mirrors issue routing while keeping implementation and review
separate:

1. With no workflow label, the opposite brand runs `pr-review`.
2. `reviewed:changes` switches to the PR-origin solver brand. It locates the
   existing issue worktree, addresses every canonical review blocker, runs
   targeted checks, commits and pushes, then replaces the verdict labels with
   `reviewed:revised` without reviewing its own work.
3. `reviewed:revised` switches back to the opposite brand for `pr-rereview`,
   publishes the new verdict, and removes the transient revised label.

Codex-origin PRs use Opus 4.8 xhigh for review and GPT-5.4 high for revision;
Claude-origin PRs use GPT-5.6-Terra xhigh for review and Sonnet 5 high for
revision. A missing or contradictory `pr-origin` marker fails visibly rather
than guessing.

The review is a direct, explicit workflow and never starts an approval daemon.
Initial review and rereview synchronously invoke `approve-issues.py` as the
canonical `issue-review:v2` fingerprint publisher so the existing solve gate
accepts Kanban-reviewed issues. Interactive revision remains inside Kanban.
Each `r` invocation advances exactly one durable label-driven stage:

1. With neither workflow label, the opposite brand performs the initial review.
   Claude-origin issues route to GPT-5.6-Terra xhigh, Codex-origin issues route
   to Claude Opus 4.8 xhigh, and unmarked issues require both.
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

## 8. Board state model

The four columns are derived from current GitHub state. Issues carrying a
configured tracker label are never classified into a column; they appear only
as tracker group headers (section 12).

### Issues

Open, unassigned issues. A linked pull request does not suppress the issue
card; the issue and PR represent different workflow objects.

### Active

Open issues with at least one GitHub assignee. Any assignee counts as active;
there is no agent-name allowlist. The issue remains Active after its PR is
created, while the PR appears independently in Reviewing or Done.

### Reviewing

Open pull requests that do not satisfy the approval predicate, including draft
pull requests. A draft has already crossed the issue-to-PR boundary, so it
belongs in Reviewing rather than Active and carries a prominent `DRAFT` badge.
Drafts remain in Reviewing even if an approval label is applied accidentally.

### Done

Open, non-draft pull requests satisfying the approval predicate. A Done card
disappears as soon as the pull request is merged or closed. Done is a
ready-to-finalize queue, not a history column.

The approval predicate is configurable: the approval label (default
`reviewed:approve`), GitHub's native `reviewDecision == APPROVED`, or either.
The default is label-only, matching label-driven review workflows.

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

### Excerpts

Use GitHub's plain-text body representation where available. Select the first
meaningful non-empty paragraph, collapse whitespace, wrap to card width, show
at most three display lines, and append `…` when truncated. This is more stable
than trying to count natural-language sentences in issue templates, lists, and
code-heavy bodies.

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

The overlay is read-only.

## 12. Epic and tracker grouping

Tracker grouping is a first-class board feature rather than a visual heuristic
based only on child titles.

### Tracker detection

Defaults:

- An open issue carrying the `epic` label is a tracker.
- Additional configurable tracker labels may be added, such as `tracker`.
- A title beginning with `Epic:` or `[epic]` is a fallback hint, not sufficient
  by itself when an explicit label is available.

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
   `D1` when present.
4. Preserve checklist order as the ultimate fallback.
5. Order explicit keys naturally by letter and number: `A1`, `A2`, `A10`,
   `B1`, `C1`, `C2`.
6. Completed checklist children may still appear elsewhere on GitHub, but only
   currently open issues or PRs appear on this live board.

Membership resolution is structured as ordered sources feeding one internal
model. The checklist parser above is the first source; GitHub's native
sub-issue relationships are a planned second source so repositories using
first-class sub-issues work without checklist conventions. Only the checklist
source ships in the first release.

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

Tracker progress is derived from checklist marks in the authoritative tracker
body: checked entries divided by total recognized child entries. It is labeled
`complete`, not `closed` or `open`, because a checklist mark is tracker state
and may briefly lag the linked issue's GitHub state. The details overlay warns
when a visible open child is checked complete; otherwise the board does not add
network requests solely to reconcile progress text.

The same tracker header may appear in more than one column when its children
are split across Issues, Active, Reviewing, and Done. This repetition provides
context; it does not duplicate or change the underlying work item.

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

- Tracker groups are ordered by their strongest visible attention state:
  problems first, then groups containing approved work, then oldest tracker
  first.
- Inside a tracker group, implementation order is authoritative even if a later
  child has a problem. Its red border remains visible in place.
- Standalone cards are sorted problems first, then approved, then oldest first
  within each group.
- Collapsed tracker headers participate in keyboard focus for expansion but do
  not open a details overlay. The details overlay for an expanded child includes
  its tracker context.

## 13. GitHub data acquisition

The GitHub provider uses the user's existing `gh` authentication and requests
only the fields required by the board. Expected data includes:

- Open issues: number, title, plain-text body, URL, labels, assignees, creation
  and update timestamps.
- Open PRs: number, title, plain-text body, URL, labels, author, draft status,
  base/head branches, creation/update timestamps, closing issue references,
  mergeability, merge-state status, review decision, and status-check rollup.
- Open tracker issue bodies so ordered checklist membership can be parsed.

One explicit refresh should perform one GraphQL operation when practical,
including pagination. The initial display limits are 250 open issues and 100
open pull requests, both configurable. If the repository exceeds a limit, show
the configured cap followed by `+` — by default `250+` for issues and `100+`
for pull requests — and a visible truncation warning rather than silently
presenting an incomplete board.

Nested connections that return nodes — labels, assignees, and closing-issue
references — carry explicit `first:` limits and request `totalCount`; cards and
details show a `+N` overflow indicator when GitHub reports omitted nodes. The
status-check rollup requests up to 100 context nodes and deduplicates reruns by
check app/name (or status creator/context), retaining the newest start time.
This avoids treating superseded failures as current and permits real
passed/total counts. A rollup beyond that cap fails closed as unknown. GitHub
scores GraphQL cost by requested node count, so these caps keep the single-query
refresh inside rate and node limits.

No request is retried in a tight loop. Rate limits and transient failures are
shown to the user while retaining the last good snapshot.

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
7. Exits immediately.
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
Codex
5 hour  [██████░░░░] 63% left
        resets 14:32
week    [████░░░░░░] 41% left
        resets Tue 09:00

Claude
5 hour  [████████░░] 78% left
        resets 16:05
week    [██░░░░░░░░] 22% left
        resets Fri 09:10
```

Each window shows its own reset time; five-hour and weekly windows reset
independently. Reset and relative times are recomputed whenever a redraw
happens for another reason; the application never wakes on a timer to maintain
a countdown.

## 15. Refresh and event model

- Brick owns the blocking terminal event loop.
- The GitHub and usage providers each run once in short-lived startup workers
  and again only after an explicit unified update.
- The PR drainer controller discovers the installed LaunchAgent, reads its
  wrapper's JSON status every ten seconds, and never contacts a network. Start
  and stop operations run asynchronously and expose transitional UI state.
- The canonical drainer implementation is versioned with Kanban at
  `tools/drain_prs.py`; the LaunchAgent wrapper invokes the stable
  `~/work/drain_prs.py` symlink so repository relocation does not change its
  service contract.
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
```

Defaults:

- Cache only the latest good snapshot.
- Persist lightweight UI preferences separately from future repository
  semantics. Chat verbosity defaults to Standard and offers Compact, Standard,
  and Full display modes.
- Record every managed agent provider line before parsing or display filtering.
  Raw workflow logs always remain full; changing display verbosity never
  changes their contents. Directories use `0700` and files use `0600`.
- Create cache files with user-only permissions (`0600`).
- Cache issue and PR bodies regardless of repository visibility so startup can
  render rich cards without network access; user-only permissions protect
  private content.
- Include a `schemaVersion` in every snapshot. A snapshot with an unknown
  version is treated as absent rather than as corruption.
- Permit `--no-cache` and a global `cache = false` setting.
- Key repository settings by `owner/name`; do not require modifying the target
  repository.

Configurable repository semantics include:

- Approval label, default `reviewed:approve`.
- Changes-requested label, default `reviewed:changes`.
- Blocked labels, default including `blocked`.
- Tracker labels, default including `epic`.
- Additional tracker-section headings.
- GitHub remote name, default `origin`.
- Approval predicate mode: label, review decision, or either; default label.
- Maximum open issues, default 250.
- Maximum open pull requests, default 100.
- Card excerpt line count, default 3.
- Provider timeouts, defaults: GitHub 30 s, Codex 10 s, Claude 45 s.
- External usage provider commands (section 14).

## 17. Error presentation

Errors should remain inside the dashboard unless startup cannot identify a
repository at all.

- Authentication failure: named provider shows `AUTH REQUIRED`.
- Missing executable: provider shows `NOT INSTALLED`.
- Unsupported CLI format or protocol: provider shows `UNSUPPORTED VERSION`.
- Timeout: provider shows `TIMED OUT` and retains cached data.
- GitHub truncation: affected count shows its configured cap followed by `+`
  and an amber banner.
- Cached data after refresh failure: dashed/dim treatment plus snapshot time.
- Malformed tracker checklist: tracker remains visible; unparsed children fall
  back to Standalone and the tracker gets an amber parse warning.

No error should clear a previous good snapshot.

## 18. Testing strategy

Favor pure functions and fixtures so most tests run without a terminal,
network, GitHub account, or installed AI client.

### Pure tests

- Issue/PR column classification.
- Pull-request readiness and color priority.
- Problems-first, approved-next, oldest-first sorting.
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

### Fixture tests

- GitHub GraphQL responses, including pagination and null mergeability.
- Codex app-server schemas and rate-limit responses.
- Claude `/usage` output for each supported CLI family.
- ANSI stripping and Unicode-width behavior.
- Cache compatibility and corrupt-cache recovery.

### Integration tests

- Temporary Git repositories with HTTPS and SSH GitHub remotes.
- Fake `gh`, `codex`, and `claude` executables placed on a temporary `PATH`.
- Worker completion and timeout delivery through `BChan`.
- Terminal resize and narrow-layout behavior.
- Clean terminal restoration after normal exit and exceptions.

### Manual checks

- macOS Terminal in a local tmux session.
- SSH attachment to the same tmux session.
- Truecolor and 256-color modes.
- Large and narrow terminal dimensions.
- Real GitHub refresh against Synarchy.
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

Exit criteria: a fixture board is attractive and fully navigable in macOS
Terminal, tmux, and SSH, with no mouse-dependent navigation, no idle redraw
loop, and a passing golden-frame suite at wide, minimum four-column, and narrow
sizes.

### Milestone 2 — GitHub snapshot and workflow board

Implemented, including cached top-level truncation state, `+` column/count
markers, nested `totalCount` decoding, amber incomplete-card outlines, and
`+N` label/assignee/linked-issue indicators.

- Implement local remote resolution and authenticated `gh` GraphQL execution.
- Fetch and paginate open issues and PRs.
- Decode labels, bodies, assignees, links, mergeability, and checks.
- Implement column classification, readiness colors, global sorting, UNLINKED,
  rich cards, details, and the configured issue/PR item guards.
- Add last-good repository caching.

Exit criteria: startup and `u` produce a correct standalone-card board for an
arbitrary GitHub repository; idle makes no network requests.

### Milestone 3 — Tracker hierarchy

Checklist hierarchy and explicit malformed-tracker diagnostics are implemented.
Native GitHub sub-issue membership remains a follow-up slice.

- Detect configured epic/tracker issues.
- Structure membership resolution as ordered sources so native GitHub
  sub-issues can be added later without rework.
- Parse ordered phase/children checklists and implementation keys.
- Group children within each workflow column.
- Inherit tracker context through linked issues to PR cards.
- Handle MULTI-TRACKED PRs and malformed trackers.
- Add tracker progress and details context.

Exit criteria: Synarchy's current tracker formats render children in their
intended `A1`, `A2`, `B1`, `C1` implementation order across all four columns.

### Milestone 4 — Codex usage

Core built-in provider and cache implemented. The external-command escape hatch
and broader version fixtures remain follow-up slices.

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

Implemented for the installed `com.coghex.drain-prs` LaunchAgent.

- Track the canonical implementation at `tools/drain_prs.py` while preserving
  the service-facing `~/work/drain_prs.py` symlink.
- Discover the controller command from the LaunchAgent plist.
- Decode the managed wrapper's structured status and incident data.
- Refresh local status every ten seconds without network traffic.
- Render the bottom-left ASCII button with off/on/warning/error colors.
- Support both click and `d` start/stop actions with transition states.

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
  never starting its background daemon.
- Advance review, author-brand revision, and opposite-brand rereview as three
  explicit stages using `reviewed:changes` and `reviewed:revised` handoffs.
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
- Canonical opposite-brand PR reviewers are Opus 4.8 xhigh for Codex-origin
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
  terminal event and its GitHub-refresh handoff.
- An atomic repository-scoped lease permits only one live solve worker per
  issue and one live review/revision worker per PR. A live lease refuses the
  duplicate launch; a stale lease is retired so an interrupted worktree can be
  recovered without erasing its commits or uncommitted changes.
- The supervisor snapshots its provider process tree every 250 ms and persists
  each observed PID, process group, start identity, and command. A provider
  cannot reach terminal state while a matching recorded descendant survives:
  the worker remains alive in an explicit red `orphaned` state, visible after a
  TUI restart, until the child exits or the user kills it.
- Persistent workers have a four-hour hard deadline. The process inspector
  marks them persistent and shows the remaining bound. If a stale supervisor
  is confirmed dead, Kanban kills its recorded provider process group and all
  still-matching census groups, then publishes a visible terminal failure. `x`
  terminates those groups and the supervisor with TERM/KILL escalation and
  verifies the supervisor stopped before writing terminal state.
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
  launches a fresh opposite-brand reviewer, resumes the original solver on
  `reviewed:changes`, and launches a fresh rereviewer after
  `reviewed:revised`. Approval or five review rounds terminates the loop; Kanban
  never merges.
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

- Complete config loading and per-repository overrides.
- Exercise stale caches, missing tools, auth failures, signals, and subprocess
  cleanup.
- Measure startup time, idle CPU, resident memory, refresh count, and redraw
  behavior.
- Add installation instructions and a `cabal install` workflow.
- Complete the release-gate manual Codex and Claude usage refreshes without
  submitting a model prompt.
- Tag the first release only after real tmux and SSH use.

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
