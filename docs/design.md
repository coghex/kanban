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
usage-command escape hatch is also implemented. Broader provider-version
fixtures remain for subsequent slices.

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

`--doctor` short-circuits that sequence after step 1, before configuration
and repository resolution, so a fresh clone with no configured remote can
still ask why an AI action would not start. It prints readiness per
dependency and per AI action, exits non-zero when any action is blocked, and
is strictly read-only: status-only probes, no agent session, no login flow,
no model quota, and no mutation of the filesystem, provider configuration,
launchd, or GitHub. See
[workflow-setup.md](workflow-setup.md) for the setup command it names.

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
| `r` | Start or reopen the selected issue's review session, or the selected PR's review, rereview, revise, or repair session |
| `S` | Choose Codex or Claude and start/reopen an issue solve through PR creation |
| `A` | Choose Codex or Claude and start/reopen the full autosolve review loop |
| `p` | Open the process/session inspector; Enter opens a session and `x` kills its live process tree |
| `i` | Open the incidents panel listing everything needing attention; Enter goes to that work |
| `u` | Update GitHub board data and both usage providers |
| `d` or click | Start or stop the launchd-managed PR drainer |
| `m` | Merge the selected approved pull request in Done through the PR drainer's own single-pull-request path |
| `c` | Collapse or expand the usage sidebar |
| `s` | Open settings, including chat-output verbosity |
| `?` | Open a help overlay listing all bindings |
| `Ctrl-L` | Force a terminal repaint without a network request |
| `Tab` | In an open solve, PR, or review overlay, show the next in-memory session of that kind |
| `Ctrl-C` | Interrupt the current turn in an open live-agent overlay — a resumable session then accepts user guidance; a canonical review stage's process is killed instead, landing the session in its interrupted terminal state, and restarts fresh via `r` |
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
from. Every title, summary, activity, and source label passes through the
external-text sanitization contract above before it is rendered or reported.

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
- when the numbered work is absent or truncated from the board, leaves the
  current column, row, and tracker expansion unchanged, reports that the work
  is not on the board, and still opens the referenced session overlay if there
  is one.

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

- An open issue carrying the `epic` label is a tracker.
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
6. Completed checklist children may still appear elsewhere on GitHub, but only
   currently open issues or PRs appear on this live board.

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

## 13. GitHub data acquisition

The GitHub provider uses the user's existing `gh` authentication and requests
only the fields required by the board. Expected data includes:

- Open issues: number, title, plain-text body, URL, labels, assignees, creation
  and update timestamps.
- Open PRs: number, title, plain-text body, URL, labels, author, draft status,
  base/head branches, creation/update timestamps, closing issue references,
  mergeability, merge-state status, review decision, and status-check rollup.
- Open tracker issue bodies so ordered checklist membership can be parsed.
- Each open issue's immediate native sub-issues — number, state, and owning
  repository — and GitHub's completed/total sub-issue summary, plus the
  repository's own `nameWithOwner`, so §12's second membership source can be
  resolved without a request per tracker. Tracker recognition happens after
  decoding, so these are requested for every issue on the page and only the
  tracker ones are consumed.

One explicit refresh should perform one GraphQL operation when practical,
including pagination. The initial display limits are 250 open issues and 100
open pull requests, both configurable. If the repository exceeds a limit, show
the configured cap followed by `+` — by default `250+` for issues and `100+`
for pull requests — and a visible truncation warning rather than silently
presenting an incomplete board.

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
- The status response also projects the post-merge cleanup a merged pull
  request still owes, which no other surface reports: a merge attempts its own
  cleanup immediately, but what that attempt leaves outstanding is retried only
  by the polling loop's sweep, so a stopped drainer neither discharges nor
  mentions it, and debt below the incident threshold has raised no incident to
  be seen through. The projection names each owing pull
  request, its outstanding steps in the wording the drainer uses for an
  incident, its failed-pass count, and its last error, ordered by pull-request
  number so an unchanged state answers identically every poll. It distinguishes
  three answers, on the same rule the open incident set follows: a set, a
  verified-empty set, and unknown for a queue state that is absent, unreadable,
  malformed, or of an unsupported version. Reading it is strictly read-only —
  no lock, no migration, no repair — and can never fail a status call, which is
  the diagnostic used when the repository is already in a bad state.
- The sidebar folds that projection into its single drainer detail line as a
  clause counting the pull requests that owe, on every state that can carry
  debt. Unknown renders nothing, so a controller predating the projection looks
  exactly as it did. Debt alone changes neither the drainer's color nor the
  incidents panel: obligations under retry are ordinary behavior, and
  escalating them stays the open incident's job.
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

- Cache only the latest good snapshot.
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
- Cache issue and PR bodies regardless of repository visibility so startup can
  render rich cards without network access; user-only permissions protect
  private content.
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
- Permit `--no-cache` and a global `cache = false` setting.
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
- Missing executable: provider shows `NOT INSTALLED`. Only a launch that failed
  because there was nothing runnable to launch reports this — no such file, or
  a file that cannot be executed. Any other failure to spawn the provider, and
  anything that goes wrong once it is running, is a request error instead, so a
  working installation is never reported as absent.
- Unsupported CLI format or protocol: provider shows `UNSUPPORTED VERSION`.
- Timeout: provider shows `TIMED OUT` and retains cached data.
- GitHub truncation: affected count shows its configured cap followed by `+`
  and an amber banner.
- Cached data after refresh failure: dashed/dim treatment plus snapshot time.
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
and the help overlay. Characters are the baseline; one frame additionally
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
- Cache compatibility and corrupt-cache recovery.

### Integration tests

- Temporary Git repositories with HTTPS and SSH GitHub remotes.
- Fake `gh`, `codex`, and `claude` executables placed on a temporary `PATH`.
- Worker completion and timeout delivery through `BChan`.
- Terminal resize and narrow-layout behavior.
- Clean terminal restoration after normal exit and exceptions.

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
- Render the bottom-left ASCII button with off/on/warning/error colors.
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

- Complete config loading and per-repository overrides.
- Exercise stale caches, missing tools, auth failures, signals, and subprocess
  cleanup.
- Measure startup time, idle CPU, resident memory, refresh count, and redraw
  behavior.
- Add installation instructions and a `cabal install` workflow.
- Complete the release-gate manual Codex and Claude usage refreshes without
  submitting a model prompt.
- Tag the first release only after real terminal use.

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
