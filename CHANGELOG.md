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

- A new packaged workflow, `/finalize` (Codex: `$finalize`), is the manual
  fallback for merging one reviewed pull request when the service-managed PR
  drainer cannot be used. It is not the ordinary merge path and is never taken
  on an agent's own initiative: `tools/drain_prs.py` keeps owning eligible
  merges, and every other packaged workflow still stops at the open pull
  request. `finalize` runs on the pull request the user names, in the turn the
  user asks for it.

  It takes one positive pull request number and checks that it is one before
  reading anything: `gh` accepts a branch name or a URL wherever a number goes,
  so an unvalidated target would let `/finalize some-branch` merge whatever pull
  request that branch has open.

  It finalizes a pull request onto the repository's **default branch** only. A
  pull request can be retargeted to a different base without its head moving,
  which leaves the approval label and the head-bound marker both current while
  the reviewed code would land on a base nobody reviewed it against — the
  review gate workflow strips the label on a push and never on a retarget, and
  the marker records no base to compare with. A stacked pull request onto a
  feature base is deliberately out of scope.

  Its gate fails closed and is evaluated twice — once to decide, and again
  immediately before the merge, because labels, the head, and the check set are
  all mutable. It resolves the authenticated GitHub login, reads the whole
  paginated comment feed rather than a bounded window — through a temporary
  file outside the checkout, since that feed is the one unbounded input and an
  argument long enough to carry it exceeds the system limit on exactly the long
  pull requests the pagination exists to read — and requires the
  globally newest marker that login published to name the pull request's
  current head with `verdict=APPROVE`. That marker is the `pr-review:v2` shape
  the review coordinator publishes today, comma-joined `reviewers=` and
  `models=` fields included, with the legacy `pr-review:v1` spelling still
  honoured; a marker authored by anyone else, a malformed one, a stale head,
  and a non-`APPROVE` verdict each refuse. The marker's reviewers must also
  exclude the pull request's own brand — read off the body by exactly
  `originFromBody`'s rules — because an approval published by the brand that
  wrote the code is a self-review that the marker alone cannot reveal; a body
  declaring no origin is the coordinator's dual route, where only a marker
  naming both brands is known to be independent. Beyond the marker, the pull
  request must be approved under the repository's *own* configured
  `approval_mode`, by its own configured `approval_label` or GitHub's
  `reviewDecision`, with the configured changes-requested and blocking labels
  absent — the same global-then-per-repository resolution the coordinator, the
  drainer and the board make, so a repository that renamed its verdict labels
  is read correctly rather than having every approval refused. A `mergeable`
  that is not exactly `MERGEABLE`, a merge state that is not ready, and any
  check that is not successful refuse too. Readiness mirrors Kanban's own
  `mergeStateReady`: `CLEAN`, and a `BLOCKED` state on a `MERGEABLE` pull
  request, which is the branch-protection requirement `--admin` clears.
  `BEHIND` and `UNSTABLE` refuse — `mergeable` says whether a merge would be
  clean, not whether it should happen now, and a head that has not seen its
  base tip belongs in `/fix` and the drainer's branch-update-and-rereview path
  rather than here. A refusal merges nothing, closes nothing, removes no
  worktree, and deletes no branch.

  It merges with `--admin --merge --match-head-commit`, the same call the
  drainer makes, and never `--squash`, `--rebase`, or GitHub auto-merge —
  arming a merge on a head whose checks have not passed is a mutation the gate
  forbids. The linked issue, the pull request's worktree, its branch, and the
  local default branch are only touched after GitHub confirms the pull request
  as `MERGED`.

  It deletes no **remote** branch, and writes to no git remote at all. A
  repository with `delete_branch_on_merge` has GitHub remove the head branch as
  part of the merge, and `tools/drain_prs.py` removes it after its own merges,
  so what a remote deletion here would have added is tidiness — against several
  ways to delete the wrong branch, since the repository identity comes from the
  remote's fetch URL while `git push` follows the multi-valued
  `remote.origin.pushurl`, every one of those URLs receives the push, and a URL
  reduced to an `owner/name` has lost the host it was going to. Where neither
  GitHub nor the drainer removes it, the merged branch stays as a visible,
  reversible leftover.

  The local cleanup is one `&&` chain, so a failed worktree removal, fetch, or
  fast-forward ends it rather than being stepped past into the deletion. A
  cross-repository head is never deleted here under a same-named branch of the
  base repository, and the local base branch is advanced only when the primary
  checkout is on it. The local branch deletion is bound to the reviewed head
  rather than to the branch name — `git update-ref -d <ref> <old-value>` — so a
  branch another actor deleted and recreated under the same name is rejected
  rather than removed. The worktree it removes is identified the same way — the one
  whose checked-out branch is the pull request's head branch and whose `HEAD` is
  the reviewed head, read out of `git worktree list --porcelain` rather than
  matched against a path pattern that a stale worktree of the same number style
  would satisfy. The linked issue is selected the same way: closing references
  carry the repository they belong to and issue numbers are repository-local,
  so only a reference naming this repository is closed and one pointing at
  another repository is skipped rather than turned into a same-numbered issue
  here. It is authored once under `tools/command_sources/` and rendered
  into both bundles, and `CLAUDE.md` and `docs/agent-workflow-contract.md`
  §2.10 now record it as the single explicitly-invoked exception to the
  never-merge rule.

- A new packaged workflow, `/fix` (Codex: `$fix`), clears the one remaining
  obstacle in front of an **already-approved** pull request. It refuses a pull
  request that is not approved under the configured `approval_mode`, and one
  whose `pr-origin` marker names the other brand — the rereview is routed from
  that same marker, so fixing another brand's pull request would end in a
  same-brand review of one's own change. It then resolves a merge conflict,
  updates a branch that is behind its base, or fixes a failed check, pushing at
  most one focused commit and handing off exactly one canonical rereview.

  Everything else fails closed rather than guessing. A check rollup that cannot
  be read completely — GitHub truncates its context list, or an entry will not
  decode, both `ChecksUnknown` to Kanban — stops the run ahead of every branch
  that reads it, since not seeing a failure is not the same as there being
  none. A merge conflict is decided without any check state and so precedes it,
  and resolving one replaces the head that the checks then re-run against. A `BLOCKED` or `UNSTABLE` merge state is reported rather
  than "fixed" by a branch update that cannot clear it, and a still-running
  check stops the run rather than replacing an approved head mid-CI.

  It never retries a check. `tools/drain_prs.py` already reruns a failed
  required check on an approved pull request, keyed to the approved head and
  quarantining it once the allowance is spent; a second rerunner with its own
  ceiling would mean two components disagreeing about the same pull request.

  It runs only on an explicit request to fix or unblock: asking why a pull
  request cannot merge is answered by reporting the obstacle and stopping,
  since a diagnostic question authorises none of the pushes or rereview it
  would otherwise perform. It is authored once under `tools/command_sources/`
  and rendered into both bundles.

## 1.1.0.0

Kanban gains a card filter panel, a settings overlay that edits its model
roster, an operating mode derived from the providers that roster loads, Linux
support for both background services, an issue approval service, and a
documented upgrade path. Two changes affect anyone moving from 1.0.0.0, and
they come first.

### Upgrading from 1.0.0.0

- Kanban publishes no Haskell library. The implementation modules are a
  private `kanban-internal` component, so a package that depended on `kanban`
  and imported `Kanban.*` no longer resolves against this version. Kanban's
  supported interfaces are the `kanban` executable and its command line, the
  documented configuration files, the on-disk compatibility surface, the
  installers under `tools/`, and the workflow contracts under `docs/`;
  importing the implementation was never among them.
- `Kanban.CLI.Options` gained an `optionPing :: [String]` field, positioned
  between `optionJson` and `optionAscii`. Code that constructed that record
  positionally, or matched it exhaustively, no longer compiles. Together with
  the withdrawn library above, that is why this release is a major bump.
- Nothing a user installs changes shape. [Upgrade to a new
  release](README.md#upgrade-to-a-new-release) is the ordered procedure: what
  to stop, what to re-run from the new archive, what to verify with the check
  that can actually observe it, and what is preserved across the move.

### The board

- Press `F` for a card filter panel. `j`/`k` or `Up`/`Down` move between its
  boxes, `Left`/`Right` between groups, `Space` toggles the focused box, and
  `d` restores the defaults. Its criteria combine with the `s` column search
  rather than replacing it.
- A live-agent overlay's sessions take the keyboard the way vim does. Each
  session opens in normal mode, where `i` starts insert, `j`/`k`, `g`/`G`, and
  `Ctrl-D`/`Ctrl-U` scroll its transcript, `1`-`9` answer a pending numbered
  choice, and `q` hides the overlay without interrupting its work. Insert mode
  edits the draft; `Enter` sends it and returns to normal, and `Esc` returns to
  normal without sending. `Esc` stages one step at a time — insert to normal,
  normal to hidden — and never reaches the dashboard's guarded quit. `Tab`
  moves between sessions and leaves each in the mode you left it in.
- The footer's hint line names the keys of whatever surface currently holds
  the keyboard, including every open overlay, rather than always listing the
  board's. It is the dashboard's one context-aware hotkey row.
- A card's top and bottom border runs are drawn in color rather than the
  terminal's default, so the whole border now follows the rule its corners
  already did: an unselected card's border is its status color throughout,
  and on the selected card the left, top, and bottom edges take the selection
  color while the right edge and the corners on it keep the status color.
- One board per repository. A second dashboard on the same GitHub repository
  is refused before it draws a frame, naming the repository and the process
  already holding it. The claim is keyed by the repository rather than by the
  checkout path, so two clones of one repository contend and two spellings of
  its name — `Coghex/Kanban` and `coghex/kanban` — are recognized as the same
  one. The cached `gh` record is now keyed the same way; a record an earlier
  version left under the old case-sensitive name is carried across on the
  first run that can claim it. Only the dashboard takes the claim: `--doctor`,
  `--usage`, `--ping`, and `--glyph-test` are unaffected.

### Agent actions and models

- Kanban's operating mode follows the providers `models.toml` actually loads:
  two is dual, one is single-agent, and none — an empty `agents` list, or a
  file that will not load at all — is no-agent. In no-agent mode the four
  bindings that start agent work, `r`, `S`, `A`, and `a`, leave the footer,
  the card details footer, and the help overlay, and pressing one says which
  mode is in effect instead of starting anything. `p` and `x` stay on all
  three surfaces in every mode, so work an earlier run left running is still
  visible in the process inspector and terminable there, and `u` still updates
  the board while spawning no usage provider. The settings overlay names the
  derived mode on a read-only line.
- The settings overlay `o` opens now edits the model roster as well as
  chat-output verbosity: `j`/`k` or Up/Down pick an assignment, `h`/`l` or
  Left/Right cycle its model, `[`/`]` cycle its effort, and `d` restores the
  picked assignment's default — or repairs a roster too broken to launch
  anything. An edit is saved to `models.toml` under Kanban's XDG
  configuration directory — `~/.config/kanban/models.toml` unless
  `XDG_CONFIG_HOME` names another root — and the running board moves to what
  was saved only once that write succeeds.
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

### Usage

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
- The Claude usage probe no longer leaves a `claude` process behind when the
  probe fails partway through. The recursive process-group cleanup that
  already covered the timeout and missing-pipe paths now also covers the
  exception path between them.
- Two Kanban processes on one machine no longer lose each other's usage
  numbers. A cached refresh is merged into whatever the snapshot file already
  holds, under a lock taken for that read-merge-write alone, so a slow probe
  in one process cannot roll back a window another process just recorded, and
  an older reading never replaces a newer one.
- The usage sidebar's percentage row stays inside the sidebar whatever it has
  to show: a provider label too wide for its field is cut with the same
  ellipsis a card's elided line carries, rather than pushing the bar and the
  percentage off the edge, and the percentage is right-aligned so one, two,
  and three digits share a column and `100%` still reads in full.

### Installing, upgrading, and configuring

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

- A `[repositories."owner/name"]` table may now carry `path`, the absolute
  path to where that repository is checked out on this machine, which puts it
  in the repository roster Kanban resolves at startup. It is not an override:
  a table without it is an override table and nothing more, so an existing
  configuration gains no roster entry by upgrading. A relative value fails
  startup — nothing expands `~` — while a path that is missing, unusable, not
  a Git checkout, or a checkout of some other repository is reported in the
  dashboard's startup notice and never blocks the launch.

### The project

- The repository carries a public contributor baseline: `CONTRIBUTING.md`,
  `SUPPORT.md`, `SECURITY.md`, and `CODE_OF_CONDUCT.md` at the root, GitHub
  issue templates for bug reports, feature requests, support questions, and
  the tracker's own shapes, and a pull-request template. `README.md` names
  where to ask a question, where to report a vulnerability, and which platform
  each installable component is supported on.
- [Releasing and maintenance](docs/releasing.md) documents how a release is
  cut, verified, and published, and `docs/issue-approval.md` documents the
  issue approval service.
- The tracked workflow bundles that `tools/setup_workflows.py` installs carry
  eight more commands: `triage`, `retriage`, `backlog-review`, `draft-report`,
  `note-problem`, `project-review`, `drain-prs`, and `push-docs`.

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
