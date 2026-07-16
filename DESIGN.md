# Kanban TUI — Design and Roadmap

Status: implementation in progress. The warning-clean GHC2024/Cabal foundation,
local repository resolution, event-driven Brick/Vty dashboard, standalone-card
workflow, explicit GitHub refresh, and last-good repository cache are
implemented. Checklist-based tracker hierarchy, inherited PR membership, and
tracker progress are also implemented. Native GitHub sub-issue membership,
malformed-tracker diagnostics, and Codex/Claude usage providers remain for
subsequent slices.

## 1. Purpose

`kanban` is a fast, keyboard-driven Haskell terminal dashboard for a GitHub
repository. It is intended to live comfortably in tmux, work over SSH, remain
idle without consuming meaningful CPU, and make no network requests unless the
application starts or the user explicitly refreshes a data source.

The dashboard combines:

- Codex and Claude five-hour and weekly usage limits in a narrow left sidebar.
- A four-column repository workflow board: Issues, Active, Reviewing, and Done.
- Rich issue and pull-request cards with GitHub label colors, body excerpts,
  assignees, linked work, mergeability, and CI state.
- Epic/tracker grouping based on ordered issue checklists such as `A1`, `A2`,
  `B1`, `C1`, and `C2`.

The initial application is read-only. It observes GitHub and the installed
Codex and Claude clients, but does not assign issues, edit labels, update
branches, merge pull requests, or otherwise mutate remote state.

## 2. Goals

- Start with `kanban` in a repository or `kanban --path DIR` from anywhere.
- Default `--path` to the current directory and resolve nested paths to the Git
  repository root.
- Support an arbitrary GitHub repository without repository-specific code.
- Render a polished Unicode interface with truecolor when available and a
  usable 256-color fallback.
- Remain entirely keyboard-driven; mouse handling is out of scope initially.
- Perform one asynchronous GitHub refresh at startup, then block on terminal
  events while idle and redraw only after input, resize, or provider
  completion.
- Keep usage and GitHub refreshes independent so one failing source does not
  hide valid data from another.
- Preserve the last good snapshot when a refresh fails.
- Derive workflow state from GitHub rather than maintaining a second board
  database.

## 3. Non-goals

- A web UI, GUI, Electron application, or background service.
- Automatic network polling.
- GitHub webhooks or a local HTTP server.
- Mouse interaction.
- Drag-and-drop workflow mutation.
- Editing issues, labels, assignments, reviews, or pull requests.
- Merging pull requests.
- A permanent archive of merged or closed work.
- Multi-repository aggregation in one running board. Each invocation represents
  one repository selected by its path.

## 4. Technology

- Language: Haskell, using GHC2024 and Cabal.
- TUI: `brick` on `vty`/`vty-unix`.
- CLI parsing: `optparse-applicative`.
- JSON: `aeson`.
- Concurrency: lightweight worker threads plus a bounded Brick `BChan`.
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

Startup performs only local work:

1. Canonicalize `--path`.
2. Resolve the repository root with `git rev-parse --show-toplevel`.
3. Read the configured GitHub remote URL locally.
4. Resolve `owner/name` from the remote, unless `--repo` supplied it directly.
   The flag is the escape hatch for unusual setups: SSH host aliases, multiple
   remotes, and bare mirrors.
5. Load configuration and the last cached snapshot, if enabled.
6. Enter the TUI immediately and start one asynchronous GitHub refresh. Startup
   never contacts OpenAI or Anthropic.

If there is no cached data, the board starts empty while the initial GitHub
refresh runs. The usage sidebar shows a clear prompt to press its refresh key.

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
╚═════════════════════╩══════════════╩══════════════╩══════════════╩══════════════╝
 j/k item  h/l column  x epic  enter  r board  u usage  R all  s sidebar  ? help  q quit
```

Responsive behavior:

- The sidebar is 28 columns by default and toggles with `s`.
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
| `h` / Left | Select previous column |
| `l` / Right | Select next column |
| `g` | Select first visible item in the column |
| `G` | Select last visible item in the column |
| `x` | Expand or collapse the focused epic |
| `Enter` | Open the selected card's details overlay |
| `Esc` | Close an overlay or dismiss a transient error |
| `r` | Refresh GitHub board data |
| `u` | Refresh Codex and Claude usage |
| `R` | Refresh board and usage |
| `s` | Toggle the usage sidebar |
| `?` | Open a help overlay listing all bindings |
| `Ctrl-L` | Force a terminal repaint without a network request |
| `q` | Quit and restore the terminal |

Refresh keys are ignored for a provider that already has a request in flight.
Keybindings can become configurable later, but the first release should keep a
small fixed set.

## 8. Board state model

The four columns are derived from current GitHub state. Issues carrying a
configured tracker label are never classified into a column; they appear only
as tracker group headers (section 12).

### Issues

Open, unassigned issues with no associated open pull request.

### Active

Open issues with at least one GitHub assignee and no associated open pull
request. Any assignee counts as active; there is no agent-name allowlist.

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

When an issue has an associated open pull request, its issue card is removed
from Issues/Active and the pull request card represents the work. Explicit
GitHub closing-issue relationships are authoritative. Title and branch-name
guessing are not used.

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
5. Yellow: approval exists but the branch is behind, blocked, or GitHub is still
   calculating mergeability.
6. Green: approval exists, the PR is cleanly mergeable/current, and the status
   rollup is successful.
7. Green: approval exists and the PR is cleanly mergeable/current when the
   repository has no checks configured.

The implementation uses GitHub's `mergeable`, `mergeStateStatus`, and
`statusCheckRollup` fields. A `CONFLICTING` mergeability result is always red.
An `UNKNOWN` result remains yellow until a later user-requested refresh; the
application does not poll for GitHub's background mergeability calculation.

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
keyboard focus target; `x` expands or collapses that epic everywhere it appears
across the board. Child cards rejoin the ordinary `j`/`k` focus order only while
their epic is expanded.

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

Nested connections — labels, assignees, closing-issue references, and
status-check contexts — carry explicit `first:` limits sized to the card and
overlay requirements, with a `+N` overflow indicator when a limit is reached.
GitHub scores GraphQL cost by requested node count, so these caps are what
keep the single-query refresh inside rate and node limits.

No request is retried in a tight loop. Rate limits and transient failures are
shown to the user while retaining the last good snapshot.

## 14. Usage acquisition

Usage is global rather than repository-specific and refreshes only when the user
presses `u` or `R`.

Both usage providers are best-effort observers of unstable interfaces. A
failed or unsupported provider never affects the board or the other provider,
and each can be replaced by a user-configured external command (below).

### Codex

Spawn the installed `codex app-server` on demand, initialize its JSON-RPC
protocol, request `account/rateLimits/read`, decode the primary and secondary
windows, and terminate the child. The response provides used percentages,
window durations, and reset timestamps.

The app-server interface is currently experimental. The provider must check
the CLI version, decode defensively, use a timeout, and report an unsupported
protocol without inventing values. Captured protocol fixtures cover supported
versions.

### Claude

The public Claude CLI documents `/usage` as the interactive view for session
cost and subscription-plan usage bars, but does not currently document a
machine-readable shell command for the same plan limits.

The built-in provider therefore:

1. Starts the official `claude` client in a private pseudo-terminal only after
   an explicit refresh, in a dedicated scratch directory such as
   `~/.cache/kanban/claude-probe/` rather than the user's repository. A fixed
   scratch directory means the client's folder-trust prompt happens at most
   once, and session history lands outside the user's project.
2. Sets environment variables that disable the auto-updater and other
   non-essential startup behavior.
3. Recognizes known startup interstitials — trust prompts, first-run theme
   selection, update notices — explicitly; an unrecognized screen is a parse
   failure, never something to answer blindly.
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
- The GitHub provider runs once in a short-lived startup worker and again only
  after an explicit refresh. Usage providers run only after an explicit
  refresh.
- Worker results enter the UI through a bounded `BChan`.
- The UI redraws after a key event, resize, provider result, or explicit
  terminal repaint.
- There are no periodic network, filesystem, Git, or wall-clock polls.
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
~/.cache/kanban/repos/<owner>-<repo>.json
~/.cache/kanban/usage.json
```

Defaults:

- Cache only the latest good snapshot.
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
Terminal, tmux, and SSH, with no mouse support, no idle redraw loop, and a
passing golden-frame suite at wide, minimum four-column, and narrow sizes.

### Milestone 2 — GitHub snapshot and workflow board

Core slice implemented; truncation counters and nested-connection overflow
indicators remain to finish the milestone.

- Implement local remote resolution and authenticated `gh` GraphQL execution.
- Fetch and paginate open issues and PRs.
- Decode labels, bodies, assignees, links, mergeability, and checks.
- Implement column classification, readiness colors, global sorting, UNLINKED,
  rich cards, details, and the configured issue/PR item guards.
- Add last-good repository caching.

Exit criteria: startup and `r` produce a correct standalone-card board for an
arbitrary GitHub repository; idle makes no network requests.

### Milestone 3 — Tracker hierarchy

Core checklist hierarchy implemented. Native GitHub sub-issue membership and
explicit malformed-tracker diagnostics remain follow-up slices.

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

- Implement on-demand app-server startup and JSON-RPC initialization.
- Request and decode account rate limits.
- Render five-hour/weekly percentages and reset timestamps.
- Add timeout, version/protocol diagnostics, fixtures, and cache support.
- Implement the external-command usage provider shared by both usage sources.

Exit criteria: `u` obtains Codex limits once, returns the provider to zero
running processes, and leaves cached data intact on failure.

### Milestone 5 — Claude usage (experimental)

- Implement private pseudo-terminal execution in the dedicated scratch
  directory, with the auto-updater disabled and known interstitials handled.
- Invoke `/usage` without submitting a model prompt.
- Strip terminal sequences and parse supported plan-usage layouts.
- Add strict version-aware fixtures, timeouts, cleanup, and diagnostics.

Exit criteria: `u` obtains Claude five-hour and weekly limits through the
official client, makes no unrelated model request, and fails closed on unknown
output. Automated CI covers fixtures without a live account; the first release
requires a successful manual refresh against the current supported Claude
version.

### Milestone 6 — Hardening and release

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
idle CPU is effectively zero, and every network call is attributable to startup
or an explicit refresh key.

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
