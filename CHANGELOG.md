# Changelog

Releases appear newest first. Each release is a `##` heading whose text is
exactly that release's package version, and the release's notes run from that
heading to the next `##` heading or the end of the file. That is the whole
boundary rule: a release section can be extracted by its version string alone,
with no trailing marker and no other convention to remember.

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
