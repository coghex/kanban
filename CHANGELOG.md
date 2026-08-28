# Changelog

Releases appear newest first. Each release is a `##` heading whose text is
exactly that release's package version, and the release's notes run from that
heading to the next `##` heading or the end of the file. That is the whole
boundary rule: a release section can be extracted by its version string alone,
with no trailing marker and no other convention to remember.

A change that has merged but not yet shipped gets its entry in the
`### Unreleased` section above the newest release. Its level-three heading
keeps it invisible to the release machinery, which reads only `##` headings.
Cutting a release is what promotes it: the `### Unreleased` heading is
replaced by `## <version>`, and a fresh empty `### Unreleased` section is
created above it.

### Unreleased

- A new packaged workflow, `/fix` (Codex: `$fix`), clears the one remaining
  obstacle in front of an **already-approved** pull request. It refuses any pull
  request that is not approved under the configured `approval_mode`, resolves a
  merge conflict, and otherwise triages the failing check: a failure where no
  job actually executed the pull request's code — a cancelled setup job, a
  concurrency-group eviction, an aggregator reporting on a dependency that never
  ran — is rerun exactly once and never a second time, while a failure that did
  execute the code is fixed and handed to one canonical rereview. A rerun pushes
  no commit, so the approval it ran under still stands and no rereview is
  invoked; a code fix replaces the reviewed head, so one always is. It is
  authored once under `tools/command_sources/` and rendered into both bundles,
  and it deliberately does not relax `/repair`'s own "no retry loops" rule,
  which still governs the unapproved work `/repair` runs on.

- The documentation carries an ordered release-to-release upgrade path. The
  README's new upgrade section unpacks the new archive beside the old one,
  installs the executable, inventories what is installed and which service jobs
  are running, stops those jobs, moves a provider marketplace off the old
  archive, re-runs each installed component's setup from the new one, verifies
  every advertised component with the check that can actually observe it,
  restarts only what was running, confirms nothing still resolves through the
  old archive, and removes it last — with the reason each step sits where it
  does and a statement of what is preserved and what is deliberately rewritten.
  Every support-table row now has named install, upgrade, verification, and
  removal guidance, including a removal path for the PR drainer and for the
  executable itself.

- The optional setup commands run from an unpacked release archive. None of
  them asks that tree for Git metadata, which a `cabal sdist` archive
  deliberately does not carry. The two that install a background service take
  `--repo` for the checkout the service is for and a new `--asset-root` for
  the tree their links point at; run from an archive with no `--repo`, they
  refuse and say so rather than installing a job against the archive.
  `tools/setup_workflows.py` likewise needs `--target` for a project-scoped
  provider registration when its asset root is not itself a checkout.
  Re-running any of them from a newer archive re-points the links a previous
  archive left, while still refusing to touch a file that is not Kanban's own.

- Press `F` for a card filter panel. `j`/`k` or `Up`/`Down` move between its
  boxes, `Left`/`Right` between groups, `Space` toggles the focused box, and
  `d` restores the defaults. Its criteria combine with the `s` column search
  rather than replacing it.
- Each usage window in the sidebar now shows how long until it resets and the
  wall-clock time it resets at, and each provider's name carries the age of
  the numbers under it, so a snapshot restored from a previous session is
  distinguishable from a fresh one.
- A clickable `↻` control in the sidebar starts the same board-and-usage
  update `u` does.
- Tell Kanban roughly what one solve round costs a provider — the
  `estimated_percent_per_solve_round` key in `config.toml` — and the sidebar
  converts each usage window's percentage left into the number of solve
  rounds it still buys.
- `kanban --ping codex` (or `claude`) deliberately starts that provider's
  usage window with one minimal paid request, so a window you are about to
  spend has its full duration ahead of it. Nothing else ever starts a ping,
  and a failed ping is not retried.
- The Claude usage probe and the process census are now correct with the
  util-linux `script` and procps `ps` that Linux ships as well as the BSD
  flavors on macOS, so the usage sidebar reads right on both platforms.
- The PR drainer runs on Linux: a systemd user-unit backend joins the macOS
  launchd one. Its install directory, discovery record, runtime state, and
  logs follow each platform's own convention — `~/Library` on macOS, the XDG
  data and state directories on Linux — and an older Linux installation made
  under the `~/Library` shape is relocated to the XDG locations by the next
  default operation.
- An issue approval service keeps the canonical issue reviews moving without
  a terminal left open: installed per repository with
  `python3 tools/install_issue_approval.py` as its own managed job — launchd
  on macOS, a systemd user unit on Linux — it repeatedly advances the open
  backlog one bounded pass at a time, and Kanban discovers and monitors the
  installation beside the drainer's.
- Press `a`, or click the `approve_issues.py` control the sidebar draws beside
  the drainer's, to start or stop that approval service from the board, the
  same way `d` starts and stops the PR drainer.
- Two Kanban processes on one machine no longer lose each other's usage
  numbers. A cached refresh is merged into whatever the snapshot file already
  holds, under a lock taken for that read-merge-write alone, so a slow probe
  in one process cannot roll back a window another process just recorded, and
  an older reading never replaces a newer one.
- The settings overlay `o` opens now edits the model roster as well as
  chat-output verbosity: `j`/`k` or Up/Down pick an assignment, `h`/`l` or
  Left/Right cycle its model, `[`/`]` cycle its effort, and `d` restores the
  picked assignment's default — or repairs a roster too broken to launch
  anything. An edit is saved to `models.toml` under Kanban's XDG
  configuration directory — `~/.config/kanban/models.toml` unless
  `XDG_CONFIG_HOME` names another root — and the running board moves to what
  was saved only once that write succeeds.
- The usage sidebar's percentage row stays inside the sidebar whatever it has
  to show: a provider label too wide for its field is cut with the same
  ellipsis a card's elided line carries, rather than pushing the bar and the
  percentage off the edge, and the percentage is right-aligned so one, two,
  and three digits share a column and `100%` still reads in full.
- A card's top and bottom border runs are drawn in color rather than the
  terminal's default, so the whole border now follows the rule its corners
  already did: an unselected card's border is its status color throughout,
  and on the selected card the left, top, and bottom edges take the selection
  color while the right edge and the corners on it keep the status color.

## 1.0.0.0

Kanban is a terminal board for a GitHub repository. It sorts that repository's
issues and pull requests into four columns — Issues, Active, Reviewing, and
Done — and lets you work them with the keyboard or the mouse without leaving
the terminal.

Version 1.0.0.0 is Kanban's first release, so the notes below are a curated
overview of what it does rather than a list of changes. Per-change entries
begin with the next release. Written 2026-08-13.

### The board

- Four columns: **Issues** (open and unassigned), **Active** (assigned),
  **Reviewing** (draft or unapproved pull requests), and **Done** (approved
  pull requests still open). Issues and pull requests stay separate cards, so
  an issue does not vanish because a pull request exists for it.
- Epics group related work and expand or collapse with `e`. Membership comes
  from a `Children` or `Phase` checklist in the epic body when there is one,
  and otherwise from GitHub's native sub-issues, so a repository that uses the
  Add sub-issue button needs no Markdown conventions. An epic with neither is
  shown with a warning that says what is missing.
- `s` searches a column by number and title, and the search can be moved
  between columns without retyping.
- `Enter` opens card details; `j`/`k` and `h`/`l` move between cards and
  columns; `?` lists every control. Mouse selection, scrolling, and details
  work throughout.
- Kanban loads its last saved board at startup and then requests fresh data.
  It does not poll: `u` is how you ask for an update.
- The layout responds to the terminal size, and color and border treatment can
  be set for terminals that need it.

### Agent actions

Optional, and inert until you install their components:

- `S` works an issue and opens a pull request. `r` reviews the selected item,
  starts the revision or rereview when changes were requested, and repairs an
  approved pull request in Done that has a merge conflict, a failed check, or a
  blocking label. `A` runs work, review, and revision as one loop. None of
  these merges anything.
- Reviews are cross-brand: work produced by one provider is reviewed by the
  other, against a canonical readiness gate rather than an ad-hoc opinion.
- Jobs run beside the board. `p` opens the job window, `Esc` hides it, `x`
  stops a job, and a job that asks a question can be answered in place. Most
  jobs survive closing Kanban and are reconnected when you reopen the same
  repository.
- `cabal run kanban -- --doctor` reports whether each action is ready and names
  the command that installs whatever is missing.
  `python3 tools/setup_workflows.py --all --scope user` installs the
  components, and reports exactly what it would do before changing anything.

### Attention and usage

- `i` lists everything waiting on you — open drainer incidents and every job
  that failed, was stopped, or is waiting for an answer — and `Enter` goes to
  the work. The list only reads; nothing in it resolves or retries anything.
- A sidebar shows the available Codex and Claude usage windows, refreshed on
  `u` and hidden with `c`. One provider failing does not stop the other or the
  GitHub board from updating.

### Optional PR drainer

- A per-repository background job that merges pull requests once they are
  approved and their required checks pass, and updates branches that are
  behind. It never resolves a merge conflict: a conflicted pull request is
  reported and left alone.
- Installed as its own macOS LaunchAgent with
  `python3 tools/install_drainer.py`, which previews the installation first.
  Installing does not start it — press `d` in Kanban when you are ready.
- `m` merges a single approved pull request from Done without the drainer.

### Installing and configuring

- Build and install from a source checkout with `cabal build all` and
  `cabal install exe:kanban`. The executable runs the board on its own; keep
  the checkout if you want the agent workflows or the drainer, whose setup
  commands install from it.
- `--path` opens another local repository, `--repo` names a GitHub repository
  explicitly, and `--no-cache` stops Kanban from reading or writing board and
  usage snapshots.
- Display settings live in `~/.config/kanban/settings.json`, workflow and
  provider configuration in `~/.config/kanban/config.toml`, and cached board
  data, logs, and job records under `~/.cache/kanban/`.
- Requirements: Git, the GitHub CLI signed in via `gh auth login`, and GHC and
  Cabal to build. Codex or Claude is needed only for the agent actions.

### Documentation

- [README](README.md) — install and first run.
- [User guide](docs/user-guide.md) — every control and behavior.
- [Workflow setup and preflight](docs/workflow-setup.md) — the agent
  components and how to install or remove them.
- [PR drainer](docs/pr-drainer.md) — the optional merge job.
- [Agent-workflow contract](docs/agent-workflow-contract.md) — what each
  action depends on.
- [Development](docs/development.md) — building, testing, and layout.

Kanban is distributed under the [MIT license](LICENSE).
