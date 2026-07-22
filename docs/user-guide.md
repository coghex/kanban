# User guide

## Start Kanban

Run Kanban inside a local GitHub repository:

```console
cabal run kanban
```

To open a different checkout:

```console
cabal run kanban -- --path /path/to/project
```

Kanban uses the repository's `origin` remote by default; set `remote_name` in `config.toml` to use another one. Run `gh auth login` first if GitHub CLI is not already signed in.

Use `cabal run kanban -- --help` to see all command-line options.

## Configuration

Kanban reads `~/.config/kanban/config.toml` at startup, or the file named by
`--config FILE`. A missing file uses built-in defaults. Copy
[`config.toml.example`](../config.toml.example) to get started; it documents
every key, its type, and its default.

The file lets you rename the workflow labels Kanban looks for (approval,
changes-requested, blocked, tracker), add extra tracker-section headings,
choose how PR approval is determined, set the blocking-label severity, cap
GitHub fetch sizes and the card excerpt height, tune provider timeouts, and
override the git remote used to resolve `owner/name`. Repository-specific
overrides live under `[repositories."owner/name"]` and replace the matching
global values for that repository only.

The `[usage.codex]`/`[usage.claude]` `command` keys are parsed and validated
today but not yet executed by Kanban — usage refresh still uses the built-in
provider regardless of what `command` names.

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

Kanban loads its last saved board when it starts, then requests fresh data. It does not keep polling GitHub. Press `u` when you want another update.

## Keyboard controls

| Key | Action |
| --- | --- |
| `j` / Down | Next card |
| `k` / Up | Previous card |
| `h` / Left | Previous column |
| `l` / Right | Next column |
| `g` / `G` | First or last visible card |
| `Enter` | Open details |
| `Esc` | Close the current window |
| `e` | Expand or collapse an epic |
| `u` | Refresh GitHub, Codex usage, and Claude usage |
| `c` | Hide or show the sidebar |
| `s` | Change how much agent output is shown |
| `p` | Open the jobs and processes list |
| `x` | Stop the selected running job |
| `d` | Start or stop the optional PR drainer |
| `?` | Open built-in help |
| `q` | Quit |

The footer in the application shows the main controls.

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
`pr-revise` commands). Provider installation alone does not make them ready;
see [the agent-workflow contract](agent-workflow-contract.md) for what each
action depends on.

- Press `r` to review the selected issue or pull request. If changes were requested earlier, the same key starts the appropriate revision or rereview.
- Press `S` to work on an issue and open a pull request.
- Press `A` to work on an issue, review the result, and send requested changes back for another pass.
- Choose `1` for Codex or `2` for Claude when Kanban asks which service to use.

Agent work runs separately from the board. Press `Esc` to hide its window and `p` to reopen it. If a job asks a question, type the answer in its window and press `Enter`.

Most issue and pull-request jobs continue if Kanban is closed. Opening Kanban again for the same repository reconnects to them. Kanban blocks quitting only when an older review type cannot safely continue on its own.

Use `x` to stop a selected job. Inside an open job window, Ctrl-C interrupts the current turn so you can provide new guidance.

## Usage sidebar

The sidebar shows the available Codex and Claude usage windows. Press `u` to refresh them. A failure from one service does not prevent the other service or the GitHub board from updating.

Press `c` to hide or show the sidebar.

## Local files

Kanban stores local state in the following places:

- Board and usage cache: `~/.cache/kanban/`
- Agent logs: `~/.cache/kanban/logs/`
- Background job records: `~/.cache/kanban/workers/`
- Display settings: `~/.config/kanban/settings.json`
- Workflow and provider configuration: `~/.config/kanban/config.toml`

Use `--no-cache` to stop Kanban from reading or writing board and usage snapshots. It does not disable job logs or settings. A global `cache = false` in `config.toml` has the same effect; `--no-cache` always wins if both are set.
