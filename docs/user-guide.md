# User guide

## Start Kanban

This guide assumes the `kanban` executable is installed; the
[README quickstart](../README.md#quickstart) covers installing it from a
release archive or a source checkout.

Run Kanban inside a local GitHub repository:

```console
kanban
```

To open a different checkout:

```console
kanban --path /path/to/project
```

Kanban uses the repository's `origin` remote by default; set `remote_name` in `config.toml` to use another one. Run `gh auth login` first if GitHub CLI is not already signed in.

Use `kanban --help` to see all command-line options.

Inside a source checkout, `cabal run kanban`, `cabal run kanban -- --path
/path/to/project`, and `cabal run kanban -- --help` are the development
equivalents, and run the code on the current branch.

## Configuration

Kanban reads `~/.config/kanban/config.toml` at startup, or the file named by
`--config FILE`. A missing file uses built-in defaults. Copy
[`config.toml.example`](../config.toml.example) to get started; it documents
every key, its type, and its default.

The file lets you rename the workflow labels Kanban looks for (approval,
changes-requested, blocked, tracker), add extra tracker-section headings,
choose how PR approval is determined, set the blocking-label severity, cap
GitHub fetch sizes and the card excerpt height, tune provider and `--ping`
timeouts, and
override the git remote used to resolve `owner/name`. Repository-specific
overrides live under `[repositories."owner/name"]` and replace the matching
global values for that repository only. That key must be a canonical lowercase
`owner/name` — stricter than what `--repo` accepts, which still takes the
GitHub URL forms it always has — and anything else fails startup instead of
sitting in the file never applying. The `owner/name` resolved from the remote
or `--repo` is folded to lowercase to select the key, so a `Coghex/Kanban`
clone still picks up a `coghex/kanban` override.

The `[usage.codex]`/`[usage.claude]` `command` keys let a user-supplied
executable replace the built-in Codex or Claude usage probe: when set, Kanban
runs that command instead of the built-in provider on every usage refresh,
under the same provider timeout, and expects it to print the JSON document
`config.toml.example` documents.

`tools/approve_issues.py` and `tools/drain_prs.py` read the same file (with
the same `--config FILE` override) so the canonical issue reviewer and PR
drainer agree with the dashboard on workflow labels and the remote to use.

## The board

Kanban shows four columns:

- **Issues** — open issues with no assignee.
- **Active** — issues that have an assignee.
- **Reviewing** — draft or unapproved pull requests.
- **Done** — approved pull requests that are still open.

Issues and pull requests remain separate cards. An issue does not disappear just because it has a pull request.

Issues labelled as epics can group related work. Press `e` to expand or collapse the selected epic.

An epic's children come from one of two places. A `Children` or `Phase` checklist in the epic's body is authoritative: as long as it lists at least one issue, that list decides membership, order, implementation keys such as `A1`, and the `N/M complete` progress counted from its checked boxes. An epic with no such checklist falls back to GitHub's own sub-issues, so a repository that uses GitHub's Add sub-issue button needs no Markdown conventions at all. Native children have no implementation key, so they appear in the order GitHub lists them and are labelled `step 1`, `step 2`, and so on, and the progress counts are the ones GitHub reports rather than anything Kanban counts itself. Because GitHub counts every sub-issue, an epic can show progress like `2/5 complete` while fewer than five cards appear beneath it: closed sub-issues and sub-issues living in another repository count towards it but are not cards on this board.

An epic that has neither a checklist nor sub-issues still shows as an empty header with an amber warning explaining what is missing. An epic using sub-issues is never warned for having no checklist, but a checklist that is present and malformed is still reported.

Kanban loads its last saved board when it starts, then requests fresh data. It does not keep polling GitHub. Press `u` when you want another update.

## Keyboard controls

| Key | Action |
| --- | --- |
| `j` / Down | Next card |
| `k` / Up | Previous card |
| `h` / Left | Previous column |
| `l` / Right | Next column |
| `g` / `G` | First or last visible card |
| `s` | Search a column, starting with Issues |
| `Enter` | Open details |
| `Esc` | Close the current window |
| `e` | Expand or collapse an epic |
| `u` | Refresh GitHub, Codex usage, and Claude usage |
| `c` | Hide or show the sidebar |
| `o` | Change how much agent output is shown |
| `p` | Open the jobs and processes list |
| `i` | Open the list of everything needing attention |
| `x` | Stop the selected running job |
| `d` | Start or stop the optional PR drainer |
| `m` | Merge the selected approved pull request in Done |
| `?` | Open built-in help |
| `q` / `Ctrl-C` | Quit |

The footer in the application shows the main controls.

## Searching a column

Press `s` to search the Issues column. A search box appears under that column's
heading and the cards move down to make room for it; the column filters as each
character lands, and the heading shows how many cards are left over how many the
column has.

While the box is open, letters and digits are typed into it rather than being
shortcuts — so `r`, `S`, and `u` do nothing but add a character. The exceptions
are `s`, which closes the search, and `q`, which still quits. Chords keep
working too: `Ctrl-C` quits and `Ctrl-L` repaints.

A card matches on the `#number` and title shown on the card, ignoring case.
Nothing else about it is searched. An epic is kept when its own title matches or
any of its children do, and matching children are shown even if that epic was
collapsed — closing the search puts every epic back the way you had it.

Up and Down move between the results, Enter opens the selected card's details
and ends the search, and `Esc` or `s` clears the query and brings the whole
column back with the same card still selected. Nothing is sent to GitHub, and
the query is gone when Kanban restarts.

### Moving the search to another column

The box does not have to stay on Issues. Left and Right move the search one
column over, and clicking anywhere in another column — a card, an epic's header,
or the empty space below them — moves it to that column. Either way the query is
emptied and the whole of the new column comes back into view, ready for a fresh
one; the column you left comes back complete with the card you had selected
still selected. `h` and `l` are typed into the query like every other letter, so
the arrows are what move the search.

A click that moves the search does nothing else — it will not open a card, open
or close an epic, or change which card is selected in the column it lands in, so
picking a card there takes a second click. Left at the leftmost column and Right
at the rightmost do nothing at all and leave what you have typed alone, and the
mouse wheel always just scrolls the column under the pointer.

## Merging one pull request

Press `m` on a card in Done to merge that pull request without waiting for the
PR drainer's next polling pass. It works from the board and from an open details
window, and it hands the work to the drainer itself rather than merging on its
own: the same checks are re-read immediately beforehand, and the linked issue,
the worktree, and the branch are cleaned up afterwards.

This needs the drainer to be installed — `python3 tools/install_drainer.py`,
described in [the PR drainer guide](pr-drainer.md) — but not running. `m` says
why and does nothing if the drainer is running, is starting or stopping, has an
unresolved incident, or if the selected card is anything other than an approved
pull request in Done. If the merge is declined, the message is the drainer's
own reason, such as a required check that has not finished. The board refreshes
by itself once a merge lands.

## Mouse controls

- Click a card to select it.
- Click the selected card again to open details.
- Use the mouse wheel to scroll the column under the pointer.
- Click an epic title to expand or collapse it.
- Right-click a card to open its active job.
- Click outside an open details window to close it.

Every mouse action has a keyboard equivalent.

## Reviews and issue work

These actions require a working Codex or Claude installation and login, plus
the Kanban-owned workflow assets those actions call into (the canonical
issue-review backend and the named `solve`/`pr-review`/`pr-rereview`/
`pr-revise`/`repair` commands). Provider installation alone does not make them ready;
install the components you want with `python3 tools/setup_workflows.py`, and
see [workflow setup and preflight](workflow-setup.md) for the fresh-clone
path and [the agent-workflow contract](agent-workflow-contract.md) for what
each action depends on.

If one of these keys reports that the action cannot start, the message names
the missing component and the command that installs it. To check every
action at once without starting anything, run `kanban --doctor` (or
`cabal run kanban -- --doctor` from a source checkout). It is a read-only
report on AI-action readiness, so a blocked action there does not stop the
board.

- Press `r` to review the selected issue or pull request. If changes were requested earlier, the same key starts the appropriate revision or rereview. On an approved pull request in Done that has a problem — a merge conflict, a failed check, or a blocking label — the same key repairs it instead, then sends it back for a fresh review. It never merges.
- Press `S` to work on an issue and open a pull request.
- Press `A` to work on an issue, review the result, and send requested changes back for another pass.
- Choose `1` for Codex or `2` for Claude when Kanban asks which service to use.

Agent work runs separately from the board. Press `Esc` to hide its window and `p` to reopen it. If a job asks a question, type the answer in its window and press `Enter`.

Most issue and pull-request jobs continue if Kanban is closed. Opening Kanban again for the same repository reconnects to them. Kanban blocks quitting only when an older review type cannot safely continue on its own.

Use `x` to stop a selected job. Inside an open job window, Ctrl-C interrupts the current turn so you can provide new guidance.

## What needs attention

Press `i` for one list of everything waiting on you: every open PR drainer incident, and every Kanban job that failed, was stopped, or is waiting for an answer. Each line says which issue or pull request it is about, what happened, and where it came from.

Move with `j` and `k` or the arrow keys, or click a line. Press `Enter`, or click the selected line again, to close the list and go to that work — the card is selected, and its job window opens if Kanban is running one. If the work is not on the current board, Kanban says so and leaves your place on the board alone.

The list only reads. Nothing in it resolves, retries, or dismisses anything.

If the PR drainer has not answered yet, or could not be asked, the list says so rather than telling you nothing needs attention.

## Usage sidebar

The sidebar shows the available Codex and Claude usage windows. Press `u` to refresh them. A failure from one service does not prevent the other service or the GitHub board from updating.

Press `c` to hide or show the sidebar.

## Checking usage from a shell

`kanban --usage` prints both services' windows and exits without starting the
board. Each line gives the window's label, how much is left, how long until it
resets, and the reset time in your own timezone, followed by how old the
printed information is:

```console
$ kanban --usage
Codex
  5 hour   63% left · resets in 4h 5m (Thu 16:05)
  weekly   41% left · resets in 3d 21h (Mon 09:00)
  snapshot 30m old

Claude
  unavailable: claude is not installed
```

It needs no repository, so it works from any directory, and it honors
`--config`. A service that fails prints its own line and does not hide the
other one. The command exits successfully as long as at least one service
answered.

By default it prints what Kanban already has cached and only asks a service
that has nothing cached, so the usual run costs nothing. Add `--fresh` to ask
both services regardless. `--no-cache` also asks both services, and
additionally neither reads nor updates the stored snapshots — as does a global
`cache = false` in `config.toml`. Combining `--fresh` with `--no-cache` is
accepted and does the same thing as `--no-cache` alone.

Add `--json` for a machine-readable document instead of the text above:

```console
$ kanban --usage --json
{"schema_version":1,"providers":{"codex":{"status":"ok","fetched_at":"2026-07-16T11:30:00Z","windows":[{"label":"5 hour","pct_left":63,"resets_at":"2026-07-16T16:05:00Z"}]},"claude":{"status":"error","error":"claude is not installed"}}}
```

Both services are always present under the lowercase keys `codex` and
`claude`, and `status` says whether that entry carries windows or an error, so
a failing service is reported rather than missing. Times are UTC. Warnings go
to standard error, so the document is the only thing on standard output.

## Starting a usage window on purpose

Everything else Kanban does with a service only *reads* your usage. `--ping` is
the one command that deliberately spends a little of it:

```console
$ kanban --ping codex
Codex
  5 hour   99% left · resets in 5h 0m (Thu 17:00)
  weekly   41% left · resets in 3d 21h (Mon 09:00)
  snapshot 0s old
```

It sends one short request to the named service, which starts that service's
rolling window, then refreshes and prints the window state so you can see when
it now ends. Use it before stepping away, so a window you want to spend has
already started.

Name exactly one service. `kanban --ping` on its own, an unknown name, and
`--ping` given twice — including twice with the same name — are all errors, and
none of them contacts a service.

Some details worth knowing:

- It runs only when you ask for it. Nothing else starts a ping: not the board,
  not `u`, not `kanban --usage`, and not `kanban --doctor`. There is no key for
  it on the board.
- The request cannot change anything. It runs from a private Kanban directory
  under `~/.cache/kanban/`, never your repository, and asks for the most
  restricted permissions the service offers.
- A failed ping is never retried, because a retry would cost you again. If the
  ping fails or times out, Kanban still refreshes and prints the window — a
  request that timed out may already have counted — and still exits non-zero.
- It needs no repository, so it works from any directory, and it honors
  `--config`.
- `--no-cache` and a global `cache = false` stop it from reading or writing the
  stored snapshot. The ping, the refresh, and the printed result happen either
  way.

The wait for that request is bounded by `ping_codex_seconds` and
`ping_claude_seconds` in `config.toml`, both 120 seconds by default. They are
separate from `codex_seconds` and `claude_seconds`, which bound the much
quicker usage reads.

## Local files

Kanban stores local state in the following places:

- Board and usage cache: `~/.cache/kanban/`
- Agent logs: `~/.cache/kanban/logs/`
- Background job records: `~/.cache/kanban/workers/`
- Display settings: `~/.config/kanban/settings.json`
- Workflow and provider configuration: `~/.config/kanban/config.toml`

Use `--no-cache` to stop Kanban from reading or writing board and usage snapshots. It does not disable job logs or settings. A global `cache = false` in `config.toml` has the same effect; `--no-cache` always wins if both are set.
