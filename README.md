# kanban

`kanban` is an event-driven Haskell terminal dashboard for GitHub work and
on-demand Codex and Claude usage limits. It is designed for macOS terminals,
tmux, and SSH. GitHub and usage providers never poll in the background; the
local launchd status of the PR drainer is checked every ten seconds.

The current implementation resolves the local Git repository, renders its last
cached snapshot immediately, and starts one asynchronous board-and-usage
update. Later updates happen only when `u` is pressed; there is no polling. It renders
standalone and tracker-grouped issues plus open pull requests across the four
workflow columns, preserves the last good board after refresh failures, and
supports keyboard navigation plus details/help overlays. Press `u` to refresh
Codex through the local app-server and Claude through the official client's
interactive `/usage` screen. Each provider refreshes and fails independently.
GitHub pagination limits and nested connection caps are surfaced with `+`/`+N`
markers and amber warnings rather than silently dropping data.
Malformed epic checklists retain every valid child, leave unparsed children
standalone, and show line-specific amber diagnostics.

The bottom of the sidebar contains an ASCII `drain_prs.py` button backed by the
installed `com.coghex.drain-prs` LaunchAgent. White means stopped, green means
running, yellow means a transition or warning, and red means an error. Click it
or press `d` to start or stop the managed drainer. Status checks are local and
make no network request. Kanban passes the current repository root to every
controller operation. The singleton service refuses to start or stop through a
dashboard for a different repository while another repository's drainer is
active.

The canonical drainer, LaunchAgent controller, and installer are tracked at
`tools/drain_prs.py`, `tools/drain_prs_service.py`, and
`tools/install_drainer.py`.

Each repository may override the drainer's required status-check names with a
tracked `.drain-prs.json` file. `required_ci_check` and
`required_review_check` accept a check name or `null` to disable that status
gate. Repositories without the file retain the `build-test` and
`review-approved` defaults. The `reviewed:approve` label remains mandatory
regardless of these settings.

### Install the PR drainer

Installation is per-user on macOS and never requires `sudo`. Preview every
target first, then install the stopped LaunchAgent:

```console
python3 tools/install_drainer.py --dry-run --json
python3 tools/install_drainer.py
```

The installer creates only two symlinks beneath
`~/Library/Application Support/kanban/pr-drainer/` and installs
`~/Library/LaunchAgents/com.coghex.drain-prs.plist`. It refuses to run while a
drainer is active and refuses to overwrite an ordinary file at either link
target. Installation loads the job but does not start it or merge anything;
press `d` in Kanban when ready. Rerun the installer after moving the checkout.

Crash notifications are disabled by default. To opt in, provide a private ntfy
endpoint with `--ntfy-url https://your-server.example/topic` or the
`KANBAN_DRAINER_NTFY_URL` environment variable. Logs and incident state live
under the user's `~/Library/Logs/kanban/pr-drainer/` and Application Support
directories.

Cards support a deliberately small mouse contract: click once to select, click
the selected card to open its details, click outside the details panel to close
it, click an epic title to expand or collapse it, or right-click a board card to open its live review, solve, or PR agent
session. A right-click on a card with no live session only selects it.
Right-click anywhere while details are open to close them, or use the mouse
wheel to scroll the column under the pointer or the open review transcript.
Every action also remains available from the keyboard.

Press `x` on a selected working issue or PR to terminate its owned process
group, including ordinary child processes. Kanban first sends TERM and then
escalates to KILL if the tree does not stop. Inside an open live agent overlay,
Ctrl-C instead interrupts only the current turn and leaves the returned session
id resumable: type corrective guidance and press Enter to continue it.

Press `r` on a selected issue or PR, including from its details, as the unified
review/revise key. A normal issue receives an opposite-brand review;
`reviewed:changes` switches back to the author brand for a canonical
specification-amendment comment; `reviewed:revised` switches back to the
opposite brand for rereview. A passing rereview applies `reviewed:approve`.
PRs use the same durable rhythm: initial opposite-brand review, origin-brand
implementation revision when `reviewed:changes` is present, then
opposite-brand rereview when `reviewed:revised` is present. PR revisions work in
the existing issue worktree, run targeted checks, commit, and push without
merging.
Review and revision jobs run independently while the dashboard remains usable;
interactive revisions use app-server threads over JSONL. Their overlays can be
hidden with Escape and reopened with `r`;
Tab switches between sessions. Structured questions and command approvals are
answered inside the overlay, and running cards carry an animated Braille status
marker. Initial issue review and rereview run `approve-issues.py` synchronously
as the canonical v2 fingerprint publisher; Kanban never starts its background
daemon. Interactive specification revision remains embedded and uses the
original solver family. Sonnet work runs through Kanban's authenticated Claude
client tool rather than a shell command inside Codex's sandbox, so it uses the
same Claude login as the terminal session while remaining in plan mode.
Issue reads, review comments, and review-label transitions similarly use a
narrow authenticated Kanban tool instead of approval-gated `gh` shell commands.
It cannot edit arbitrary labels or other GitHub resources.

Press capital `S` on an issue to run the existing solve contract through PR
creation, or capital `A` to start Kanban's owned autosolve review/fix loop. `A`
first invokes that same ordinary solve contract and stops the solver at PR
creation. Kanban then discovers the newly linked PR, starts a fresh canonical
opposite-brand reviewer, and resumes the original solver session only when the
review publishes requested changes. Revised heads receive fresh rereview
sessions; the loop stops after approval or five review rounds. Either
key opens the centered solver chooser: `1` starts Codex with GPT-5.4 high and
`2` starts Claude with Sonnet 5 high; Escape cancels. Autosolving cards are blue
while active. Codex-origin PRs are reviewed by Opus 4.8 xhigh and Claude-origin
PRs by GPT-5.6-Terra xhigh. Output is streamed into a hideable, resumable
background-session overlay. If either workflow stops with
`KANBAN_NEEDS_INPUT`, the issue turns orange and the answer entered in the
overlay resumes that same session. Failures are red and completed sessions
return to white. Kanban refreshes GitHub at workflow handoff points; it does
not poll the solver or GitHub continuously. The issue remains as its own
Active card after a PR appears, while the PR is shown independently in
Reviewing or Done.

Solve, autosolve, and PR review/revision invocations run under detached,
repository-scoped Kanban workers. It is safe to quit and restart the dashboard
while one of these agents is active: the worker retains its full event stream,
session id, log path, autosolve parent identity, and heartbeat under
`~/.cache/kanban/workers/`, and the next Kanban process for that repository
reattaches automatically. Completed work that finished while the TUI was down
is replayed without rerunning the model so its handoff still advances; its
journal remains recoverable until a newer worker proves that workflow step was
superseded. An atomic per-issue or per-PR lease prevents a second Kanban worker
from starting the same workflow concurrently. Workers census provider
descendants every 250 ms and persist their PID, process group, start identity,
and command. If a provider exits while a recorded child remains, the workflow
turns red and stays explicitly `orphaned` in the process inspector until the
child exits or `x` terminates and verifies the process tree. Workers have a
four-hour hard runtime limit. If a worker supervisor disappears unexpectedly,
Kanban fails closed by terminating both its recorded provider group and any
still-matching descendants instead of allowing invisible work to continue.

The app-server-backed interactive issue-revision flow and canonical issue gate
are not detached yet. Kanban refuses to quit while one of those issue-review
turns is live; finish it or kill it explicitly first. This guard does not apply
to persistent solve or PR workers.

While an agent process is live, its overlay shows an animated Braille activity
pip, a provider-independent one-line activity, and the elapsed time for that
activity. Shell tools from both Codex and Claude display the actual sanitized
command, so a quiet build remains visibly active as, for example,
`⠹ running cabal build … · 1m 12s` until its next event arrives.

Press `p` for the Processes overlay. It lists retained issue-review, solve,
PR-review, and revision sessions with their provider, lifecycle state, current
activity (for example thinking, running a command, or waiting for input), and a
short session identifier. Live rows also show the current activity timer.
Detached rows are marked `persistent` and show the remaining hard runtime
limit; they are visible even while the provider is starting. The list scrolls
by keyboard or wheel. Enter opens
the selected session's existing interactive transcript, and `x` terminates the
selected worker supervisor, provider process group, and descendants. The latest finished or
failed session for each item remains visible for debugging until it is replaced
or Kanban exits.

Every managed agent workflow writes the provider's complete JSONL/stdout and
stderr stream to a private repository-scoped directory under
`~/.cache/kanban/logs/`. These logs are recorded before display filtering and
remain full regardless of the on-screen setting. Press `s` for Settings and
choose Compact, Standard, or Full chat output; Standard is the default and
shows reasoning summaries, commands, tool inputs, and concise tool results.
Press `c` to collapse or restore the usage sidebar. The preference is saved in
`~/.config/kanban/settings.json` with user-only permissions.

Epics are purple and collapsed by default. Focus one with `j`/`k` or the arrow
keys and press `e` to expand or collapse it, or click its title directly.

```console
cabal run kanban
cabal run kanban -- --path ~/work/project
cabal run kanban -- --border open # optional borderless column gutters
cabal run kanban -- --glyph-test  # compare line glyphs in this terminal/font
```

The three drainer tools have a Python test suite covering installer safety,
controller configuration, and the drainer's pure decision logic
(check classification, PR selection, backoff arithmetic, review-marker
parsing, worktree scoring, drain-state migration) and one full happy-path
integration cycle against a real temporary Git repository with a scriptable
fake `gh`. Run it with:

```console
python3 -m unittest discover -s tools -p 'test_*.py'
```

It requires no network access, modifies no LaunchAgent, and needs no `gh`
login. This is independent of the
Haskell `cabal test` suite.

Board refresh uses the authenticated GitHub CLI. Run `gh auth login` first if
`gh` is not already authenticated. Cache files live under
`~/.cache/kanban/repos/`; the global usage snapshot lives at
`~/.cache/kanban/usage.json`. Both are written with user-only permissions;
pass `--no-cache` to disable both snapshot reads and writes. Agent logs and UI
settings are independent of the snapshot-cache switch.

See [DESIGN.md](DESIGN.md) for the complete design and implementation roadmap.
