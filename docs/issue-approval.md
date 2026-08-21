# Issue approval service

The issue approval service walks one repository's open issue backlog in
ascending number order and runs the canonical issue review on the first issue
that does not already hold a current approval. It advances at most one issue per
pass, and it stops at the first issue whose canonical state is
changes-requested rather than reviewing past it.

The service is optional. Kanban works without it, and installing it starts
nothing.

Each canonical GitHub repository gets its own job, its own runtime state, its
own logs, and its own incidents, in an `issue-approval` namespace that shares
nothing with the [PR drainer](pr-drainer.md)'s. Install as many as you like on
one account: starting or stopping one does not touch another. What a job is
*named* by is the checkout's canonical GitHub `owner/name`, compared without
regard to case, so `Acme/Widgets` and `acme/widgets` are one service and two
clones of one repository cannot run it at the same time. A checkout whose
remote is not a supported github.com URL cannot have one at all.

That name comes from the remote the **shared** Kanban configuration
(`~/.config/kanban/config.toml`, or `$XDG_CONFIG_HOME/kanban/config.toml`)
names — the same remote Kanban resolves the board's repository through — and
never from a `--config` passed to the installer. A repository's own `--config`
decides what its controller *runs with*; it never decides which repository the
service is for. Point the dashboard and the service at one repository by setting
`remote_name` in the shared configuration, which moves both together.

## How it differs from the PR drainer

Both are non-resident per-repository jobs installed by their own installer,
driven through their own controller, and started and stopped from the sidebar.
Beyond that they have nothing in common, and the differences are the ones that
matter when something goes wrong.

| | Issue approval service | PR drainer |
| --- | --- | --- |
| What it acts on | Open **issues**, in ascending number order | Open approved **pull requests** |
| What it does | Runs the canonical issue review and publishes its verdict | Merges eligible pull requests and updates branches |
| Who decides | The canonical backend `tools/approve_issues.py`, which the controller only repeats | `tools/drain_prs.py`, which the controller only supervises |
| Board key | `a` | `d` |
| Job label | `com.coghex.issue-approval.<slug>` | `com.coghex.drain-prs.<slug>` |
| Installer | `python3 tools/install_issue_approval.py` | `python3 tools/install_drainer.py` |
| Controller | `approve_issues_service.py` | `drain_prs_service.py` |
| Stops for | A changes-requested issue (the ordered barrier) | Nothing; a conflicted pull request is reported and skipped |
| Model calls | Yes — every review is model work | Only for automated stale-head rereview rounds |
| State and log roots | macOS-shaped `~/Library` on both platforms | Each platform's own — `~/Library` on macOS, `$XDG_DATA_HOME` and `$XDG_STATE_HOME` on Linux |

What they do share is the account and one seam: both reach this host's service
manager through `tools/service_manager.py`, and each does so for its own
`ServiceNamespace`, so neither can name, load, unload, or acknowledge the
other's job. They do not share a storage convention — see the last row above,
and [Where it runs](#where-it-runs) for why this one keeps the macOS shapes
everywhere.

The service never merges anything, and it never touches a pull request.

## Where it runs

Three questions are answered separately here, and conflating them is the usual
source of confusion on a host that is not macOS.

- **Installation and lifecycle control** — `install`, `start`, `stop`, and
  `uninstall` — need a service manager. `tools/service_manager.select_backend`
  probes for one rather than reading a platform name: launchd on a macOS host
  that has `launchctl`, systemd on a host whose `systemctl --user` reaches a
  live user manager. A host that is neither is refused, and the refusal names
  that condition. `sys.platform` decides nothing, so a Linux host with a
  reachable user session installs exactly as a macOS host does.
- **A foreground `run`** needs no service manager at all, but it does need
  POSIX: an advisory `flock`, a passwd database, `os.killpg`, and a new session
  per backend invocation. A host missing any of them is refused by name, because
  a run that cannot terminate its own child has no safe degraded mode.
- **A read-only `status`** needs neither. It reads what the last run left behind
  and consults no manager, which is why it answers on a host where nothing can
  be installed.

What the manager reads differs — a LaunchAgent plist under
`~/Library/LaunchAgents`, or a user unit under `~/.config/systemd/user`
(`$XDG_CONFIG_HOME/systemd/user` when that variable names an absolute
directory) — and everything else in this document is the same on both.

**The service's own state and logs stay macOS-shaped on every platform.** The
runtime tree under `~/Library/Application Support/kanban/issue-approval` and the
logs under `~/Library/Logs/kanban/issue-approval` are resolved from the account's
passwd home directory with no XDG rule of any kind, on Linux as much as on
macOS. Only the unit location is XDG-aware, and only because that is systemd's
own question about where it searches. Migrating these roots to XDG data and
state locations is future work; unlike the drainer's, they have not been
relocated yet.

## Flag ordering

Every global option comes **before** the subcommand:

```console
python3 tools/approve_issues_service.py --json status
python3 tools/approve_issues_service.py --path /path/to/project --json status
```

The natural ordering is the one that fails. `status --json` is rejected by the
argument parser with `unrecognized arguments: --json`, because `--json`,
`--path`, `--repo`, and `--config` belong to the parser rather than to any
subcommand. Only `run` has options of its own — `--interval` and
`--legacy-policy` — and only `install` and `uninstall` take `--dry-run`; those
four do follow their subcommand.

`tools/install_issue_approval.py` has no subcommands, so its options may appear
in any order.

## Install

The installer does not require `sudo`, and it never starts the service.

Run it once per repository, from that repository's **main checkout** — not a
linked worktree. The installer refuses a checkout whose `.git` is a file rather
than a directory, so a `--dry-run` issued from a worktree returns that refusal
instead of a plan.

Preview the changes:

```console
python3 tools/install_issue_approval.py --dry-run --json
```

Install the stopped job:

```console
python3 tools/install_issue_approval.py
```

The installer:

- refuses a host managed by neither launchd nor a live systemd user session,
  before anything is written;
- refuses a checkout whose remote does not name a repository on github.com,
  because that identity is what names the job and every path beside it;
- refuses when the copy of the controller it imported differs from
  `tools/approve_issues_service.py` in the checkout it is installing, since the
  definition would then be written by one copy and run by the other;
- **resolves** the canonical issue-review backend and refuses if it is absent,
  naming `python3 tools/install_issue_review.py` as the repair. It never installs
  a second reviewer: that backend is one global installation shared with every
  ordinary review workflow;
- refuses beside the untracked background approval daemon
  ([below](#the-legacy-approval-daemon)) and beside any live run of this
  repository's controller;
- refuses to replace an ordinary file, or a link resolving to something that is
  not one of Kanban's own tracked modules;
- creates stable links to `approve_issues_service.py`, `kanban_config.py`, and
  `service_manager.py` under the install directory, shared by every repository
  installed there;
- writes the service definition named for this repository's normalized identity
  — `~/Library/LaunchAgents/com.coghex.issue-approval.<owner>.<name>.plist`
  under launchd, or
  `~/.config/systemd/user/com.coghex.issue-approval.<owner>.<name>.service`
  under systemd;
- records the backend that wrote it, that job's identifier, the definition's
  path, the checkout, the install directory, and any `--config` and
  `KANBAN_ISSUE_REVIEW_INSTALL_DIR` selection under this repository's entry in
  the discovery record;
- loads the job **without starting it**.

Installing a second repository adds its entry beside the first; it never
replaces it.

### Options

| Option | What it does |
| --- | --- |
| `--repo PATH` | The repository checkout to review issues for. Defaults to the checkout this script lives in. |
| `--install-dir DIR` | Where the shared script links go — see the precedence below. It moves the links and nothing else: not the discovery record, not the runtime tree, not the logs. |
| `--config PATH` | A `config.toml` persisted against this repository and carried into the job it installs, so a start from an empty environment still runs with it. Also read from `KANBAN_ISSUE_APPROVAL_CONFIG_PATH`. |
| `--uninstall` | Remove this repository's job instead of installing one. |
| `--dry-run` | Validate and describe without writing. |
| `--json` | Print the plan as JSON instead of sentences. Both forms are printed from one result, so they can never describe different work. |

Where a run's links go is decided in this order: `--install-dir`, then
`KANBAN_ISSUE_APPROVAL_INSTALL_DIR`, then the directory this repository's job is
already recorded in, then
`~/Library/Application Support/kanban/issue-approval`. **The environment
variable therefore moves an install here**, where the PR drainer's installer
ignores its own variable at install time and takes `--install-dir` alone. So
unset it before re-running if you mean the recorded installation.

Either of the first two can disagree with where the job is recorded, and an
uninstall pointed at a directory this repository's job is not recorded in is
refused rather than resolved: the job, its definition, and its record entry are
named by identity alone, so removing them and then deleting links in a directory
the job never ran from would strand the links it actually did.

## Start and stop

Press `a` in Kanban to start or stop this repository's service, or click the
`approve_issues.py` control directly above the drainer's in the sidebar. See
[the user guide](user-guide.md#the-issue-approval-service) for what the control
shows.

Installation never starts the service. **Starting it begins publishing canonical
review verdicts on real issues immediately**, including moving `reviewed:approve`
and `reviewed:changes` labels, so start it when you mean to.

Services for different repositories run independently, and each Kanban window
reports only its own repository's. Two checkouts of *the same* repository share
one service, because they are one repository: whichever starts second is refused,
and the message names the checkout already running it.

### Run lifecycle

The installed job is non-resident by design, under either manager. Every
generated LaunchAgent sets `RunAtLoad` and `KeepAlive` to false and carries no
`StartInterval`; every generated systemd unit sets `Restart=no` and carries no
`[Install]` section, so nothing enables it. Neither manager ever starts the
service on its own — not at login, not after a run ends, not on a timer. A run
begins only when something explicitly asks for one: the `a` key in Kanban, or
the controller's `start`.

Once started, the run outlives whatever asked for it. Quitting Kanban does not
stop it, and the next Kanban window opened on that repository reports it as
still running. Press `a` again, or run the controller's `stop`, to end it.

A `start` refreshes the installation first — the definition and the record entry
are rewritten from the same derivations an install uses — and then waits up to
fifteen seconds for the job to record a live state. A `stop` asks the manager for
its own polite stop, so the controller runs its intentional shutdown: it signals
the whole process group of the backend pass in flight, leaves any barrier exactly
where it was, records that it stopped on purpose, and exits. A pass it
interrupted decided nothing and is recorded as nothing; a pass that had already
exited cleanly with a complete result is still acted on, because it may have
published a verdict and moved a label, and discarding it would be the stop
claiming nothing happened when something did. A group that has not gone within
ten seconds is killed outright rather than left holding the canonical approval
lock, and the whole session is swept on the way out of every pass, so an
intentional stop leaves no orphaned `gh` or reviewer process behind. The job
stays installed and loaded, which is what the next start needs to find, and a
stop waits up to thirty seconds for the exit to be confirmed by the manager as
well as by the status document.

Starting something already started is a no-op rather than a refusal. Stopping
something already stopped is likewise reported as `Already stopped.`

### From the controller

Normal control should happen through Kanban. For diagnosis, drive the
*installed* controller — the copy the job actually runs — rather than the
checkout's:

```console
APPROVAL="$KANBAN_ISSUE_APPROVAL_INSTALL_DIR"
[ -n "$APPROVAL" ] || APPROVAL="$HOME/Library/Application Support/kanban/issue-approval"
CONTROL="$APPROVAL/approve_issues_service.py"
python3 "$CONTROL" --path /path/to/project --json status
python3 "$CONTROL" --path /path/to/project --json start
python3 "$CONTROL" --path /path/to/project --json stop
```

Add `--repo OWNER/NAME` to assert which repository you expect; the controller
resolves the checkout's own remote and refuses any other identity, including
another remote of the same checkout.

`run` is the foreground supervisor a service manager executes, and there is
normally no reason to invoke it yourself. It takes `--interval SECONDS`
(default 60) and `--legacy-policy dual|hold`, which the installed definition
deliberately does not carry: the definition records what the job *is*, while
both of those are the run's own defaults, which a later release may change
without every installed job having to be rewritten.

## The queue and the ordered barrier

Each pass invokes the canonical backend's `--review-queue` mode exactly once.
That pass walks the complete open backlog in ascending issue number and returns
one of five outcomes:

| Outcome | Meaning | What the controller does next |
| --- | --- | --- |
| `advanced` | The selected issue now holds a current canonical approval. | Starts the next pass immediately. |
| `idle` | Every open issue is already approved, or is ungated by the legacy policy. | Waits the poll interval. |
| `changes_requested` | The lowest unapproved issue is in current changes-requested state. | Opens the ordered barrier below. |
| `retry` | The issue's specification changed while it was being reviewed, so no verdict was published. | Waits, with a bounded backoff. |
| `busy` | Another process holds the canonical approval lock — an interactive review, or another queue pass. The message names the owner. | Waits, with a bounded backoff. |

`busy` and `retry` are ordinary completions rather than failures: nothing was
left half-done, so the wait doubles per consecutive retryable outcome and stops
doubling at eight times the interval. A service that backs off never becomes a
service that has quietly stopped polling.

The canonical lock is released between issues rather than held for the backlog,
which is what keeps an interactive review from being locked out for the whole
run.

### The changes-requested barrier

An issue whose canonical state is changes-requested stops the queue at that
issue. Nothing with a higher number is reviewed while it stands. The barrier is
two documents:

- **`barrier.json`** is the authority. It is what actually stops the queue, and
  it survives an intentional stop and a restart.
- **A warning incident** is what shows it. The sidebar composes it as
  `on · unresolved incident · Issue #N requests changes` while the service is on,
  in warning colour rather than as a failure — the service is healthy and
  waiting, not broken.

While barriered, each poll performs one **read-only** gate check of that issue
and nothing else. No model runs, no review is published, and no
`--review-queue` pass happens at all, so a barriered service cannot reach any
issue, let alone a higher-numbered one.

**Repair the named issue with `r` while the service stays on.** That is the
supported path, and it works because a barriered service's only child is that
read-only gate check: the board refuses nothing while the barrier stands, for
that issue or any other. (It is a service that is *running* with a review
actually in flight that refuses a canonical stage started from a card, until
that review finishes — for any issue, since the queue reviews in order and
cannot be asked to skip ahead.) The barrier clears itself on
the next poll after the issue holds a current canonical approval — the warning
is resolved first, then the record is removed, so an interrupted clearance leaves
a barriered queue with a stale warning the next start reconciles, never a resumed
queue with a warning nothing could ever resolve.

Acknowledging the warning is bookkeeping only. `ack` resolves the incident record
and leaves `barrier.json` exactly where it was, so the next poll opens a fresh
warning until the issue is really approved. There is deliberately no way to
dismiss a barrier.

## Reading status

```console
python3 tools/approve_issues_service.py --json status
```

`status` is strictly read-only: it creates no directory, rewrites no document,
and opens or resolves no incident. It is the diagnostic reached for when the
runtime is already in a bad state, and a reader that repaired what it read would
destroy the evidence it was called to show.

The document carries `"schema": "kanban-issue-approval-status"` and
`"version": 1`. A reader that cannot confirm both is holding something else.

### States

| `state` | Meaning |
| --- | --- |
| `starting` | A run has begun and is checking the queue. |
| `running` | A pass is in flight, or the run is waiting between passes. |
| `barrier` | The queue is stopped at a changes-requested issue. |
| `stopped` | The run ended because it was asked to. Terminal; it outlives the process that wrote it. |
| `child_failure` | A backend pass produced no result this controller may act on — a non-zero exit, an absent document, or one it cannot read. Terminal. |
| `controller_failure` | The controller itself failed around a pass. Terminal. |
| `unknown` | Never written. Synthesized when the recorded state cannot be believed, with `reason` naming why. |

`unknown` is not "off". It covers a document that is absent, unreadable, of
another schema or version, another repository's, recording a state this reader
does not know, or recording a live state under a runner PID that is not running
— and an unreadable barrier record. Nothing that may act only against a settled
stop acts on `unknown`.

### Fields

| Field | Meaning |
| --- | --- |
| `state`, `reason` | The state a reader may believe, and — when it is not the recorded one — why. `reason` is `null` on a clean read. |
| `repository`, `repo` | The canonical identity this status is about, and the checkout it was asked from. |
| `active_repo` | The checkout a *live* run is actually being supervised from. Two clones of one repository resolve to one runtime, and this is the only place their difference shows. `null` unless something is running. |
| `runner_pid`, `backend_pid` | The controller process, and the backend pass it currently has in flight. Each is `null` unless it is really there. |
| `started_at`, `updated_at` | When the recorded run began, and when this document was last written. |
| `message`, `last_outcome` | The controller's own summary, and the last `--review-queue` outcome it saw. A gate check at a barrier deliberately leaves `last_outcome` alone: it decides nothing about the queue. |
| `mutations`, `run_id` | How many passes of the recorded run may have changed GitHub, and which run counted them. The count only rises, so a poller can detect a mutation whatever its sampling rate; a fresh run starts it again, which is why the run identity travels beside it. Both are `null` in a document written before these fields existed. |
| `barrier_issue`, `barrier_unreadable` | The durable barrier, read from `barrier.json` rather than from the live state — so it is reported across a stop, a restart, and an acknowledged warning. `barrier_unreadable` names why the record could not be read, which also forces `state` to `unknown`. |
| `open_incident`, `open_incidents` | The newest open incident, and every open incident, for this repository. `[]` when there are none. |
| `status_path`, `service_log` | Where this document and the service log live. |

`status` exits `0` whenever it could answer, including for a service that has
never been installed — that is the `unknown` answer with
`"no status document has been written yet"`. A non-zero exit means the question
itself failed, and the error is printed to standard error as
`{"error": "..."}` under `--json`.

## Incidents

The controller records two kinds, both under this repository's own incident
directory and both attributed to the canonical repository rather than to the
checkout that raised them, so any clone lists and acknowledges the same set.

- **`issue-changes-requested`**, warning severity: the ordered barrier's
  warning. One per open (repository, issue) — a barrier polled every interval,
  and one that survives a restart, keep the warning they already have instead of
  accumulating one per poll.
- **`approval-error`**, error severity: a run that ended on something it could
  not act on. It carries the summary the status message shows and, separately,
  the tail of the failed pass's standard error.

Dismiss one for bookkeeping:

```console
python3 tools/approve_issues_service.py --json ack
python3 tools/approve_issues_service.py --json ack incident-20260821T143154Z-4821-issue425 --note "repaired by hand"
```

With no incident ID, `ack` resolves the newest open incident for this repository,
of any kind; with one, that incident. It is deliberately powerless over the
queue.

## Files and logs

Below, `<slug>` is the repository's normalized `owner/name` encoded for a
filename — `coghex/kanban` becomes `coghex.kanban`. It is the same slug the job
identifier ends with, so the job, the runtime directory, and the log directory of
one repository all carry the same name. An identity whose encoded slug would
outgrow what a service manager can carry falls back to a hash of the whole
identity instead, in all three places at once.

The paths below fall into three groups, and which group a file is in decides
where it actually turns up.

**Fixed, and immovable.** The record, the runtime tree, the locks, and the logs
are resolved from the account's **passwd** home directory, never from `$HOME`,
and no option or environment variable moves them. That is deliberate: the
identity lock that keeps two clones of one repository from both running hangs
off this root, and a root a process-controlled input could move would let two
runs both start. Running an installer or a controller under a different `$HOME`
leaves every one of them exactly where it was.

**The shared script links are the one thing that moves.** They default to that
same passwd-anchored root, but `--install-dir` and
`KANBAN_ISSUE_APPROVAL_INSTALL_DIR` place them at any path you name — and a
leading `~` in either is expanded with `$HOME`, like any path, so a custom
location can depend on `$HOME` even though nothing else here does. They are also
all that moves: the record, the runtime tree, the locks, and the logs stay put.
The layout differs from the PR drainer's here as well as in the roots the table
above compares: the drainer's runtime tree sits *inside* its install directory
and moves with it, while here the runtime root is a sibling of the record, so a
dashboard that inherits no environment can find both without being told where
the links went.

**The service definition is the service manager's, not the controller's.**
`tools/service_manager.py` resolves its directory with `Path.home()` — which
*does* honour `$HOME` — plus, on systemd, `$XDG_CONFIG_HOME`. So a command run
under a different `$HOME` writes and reads the plist or unit somewhere else,
while the record that is supposed to name it stays under the passwd home. That
combination leaves a job the record points at and the manager has never heard
of. Do not install or control this service under a redirected `$HOME` unless you
mean exactly that.

- Install record Kanban discovers each job through:
  `~/Library/Application Support/kanban/issue-approval/config.json`. Its
  `repositories` table holds one entry per installed repository, carrying the
  backend that wrote it, that job's identifier, the definition's path, the
  checkout, the install directory, and any `config_path` and
  `backend_install_dir`. This path is fixed, and `--install-dir` does not move
  it — a dashboard that inherits no environment still has to find an install made
  anywhere.
- Installed script links, shared by every repository installed there:
  `~/Library/Application Support/kanban/issue-approval/` — the passwd home's,
  by default — or wherever `--install-dir` or
  `KANBAN_ISSUE_APPROVAL_INSTALL_DIR` put them, per the second group above.
- Runtime state, one directory per identity:
  `~/Library/Application Support/kanban/issue-approval/runtime/<slug>/`, holding
  `status.json`, an `incidents/` directory of `incident-*.json` documents, and —
  only while the queue is barriered — `barrier.json`. That record's absence is
  what "not barriered" is, so it is created when the barrier opens and unlinked
  when it clears.
- Locks: `~/Library/Application Support/kanban/issue-approval/locks/`, holding
  `<slug>.lock` (the run lock), `<slug>.transition.lock` (held while a job is
  being installed, started, stopped, or removed), and `install-<digest>.lock`
  (held while one installation's shared links are touched).
- Logs: `~/Library/Logs/kanban/issue-approval/<slug>/`, holding the controller's
  own `service.log`, the manager's `service.out` and `service.err`, and the
  backend's dated logs, which the controller points here so two repositories'
  logs stay apart.
- Service definition: `~/Library/LaunchAgents/com.coghex.issue-approval.<slug>.plist`
  under launchd, or
  `~/.config/systemd/user/com.coghex.issue-approval.<slug>.service` under
  systemd. This is the third group above: its `~` is `$HOME`'s rather than the
  passwd home's without anyone asking, and its systemd spelling moves with
  `$XDG_CONFIG_HOME` as well.
- Discovery-record lock: `config.json.lock` beside the record, taken for every
  read-modify-write of that document so one repository's install cannot drop
  another's entry.
- Per checkout, in the repository's shared Git directory:
  `.git/kanban_issue_approval_run.lock`, this checkout's own run lock, beside the
  canonical backend's own `.git/approve_issues.lock`, which the controller
  **reads and never takes**.

Two run locks are taken, not one, because no single location sees both ways a
second run arrives. The identity lock under `locks/` catches two *clones* of one
GitHub repository, which have two Git directories. The checkout lock in the Git
directory catches one checkout started twice under identities that do not match —
two `--config` files naming different remotes — which would never meet at the
identity lock. A linked worktree resolves the primary checkout's file, so the
pair holds for the worktrees solve and review agents actually work in.

The installed job runs with a fixed environment rather than your shell's: `HOME`
set to the account's passwd home, `PYTHONUNBUFFERED=1`,
`KANBAN_ISSUE_APPROVAL_INSTALL_DIR` naming its own installation, and a `PATH` of
`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`,
`/usr/sbin`, and `/sbin`. A `gh`, `codex`, or `claude` reachable only from
somewhere else on your interactive `PATH` is not reachable from the job.

## Recovery

Read `status` first. Every state below is reported there, and the `reason`,
`message`, and open incidents name the specific fault.

| What you see | What happened | What to do |
| --- | --- | --- |
| `state: unknown`, reason `no status document has been written yet` | Nothing has ever run for this repository. | Nothing is wrong. Install if you have not, then start. |
| `state: unknown`, reason names a runner PID that is not running | The controller died without recording a terminal state. | Start again. The stale document is replaced by the new run's own. |
| `state: unknown`, reason names a schema, version, or repository mismatch | The document at that path was not written by this controller for this repository. | Stop the service, move the named file aside, and start again. |
| `state: unknown`, `barrier_unreadable` set | `barrier.json` is present but cannot be read as a barrier record, so the queue must not be treated as unbarriered. | Read the named file. Repair or remove it deliberately — removing it lets the queue cross that issue, so confirm the issue's real state first. |
| `state: child_failure` | A backend pass exited non-zero, produced no result document, or produced one this controller may not act on. | Read the `approval-error` incident's `detail` — it carries the pass's own standard error — and the backend's dated log beside `service.log`. Fix the cause, then start again. |
| `state: controller_failure` | The controller itself failed around a pass. | The incident's `detail` carries the traceback. Start again once the cause is fixed. |
| `state: barrier` | Working as designed: the queue is stopped at a changes-requested issue. | Repair that issue with `r`; the barrier clears itself. |
| `start` reports the controller exited during startup | A run began and immediately recorded an incident — most often an unresolvable canonical backend, or the legacy daemon below. | The reported summary is the incident's. Fix it and start again. |
| `Timed out waiting for the issue approval controller to start` | The manager was asked to start the job, but no live state was recorded within fifteen seconds. | Read `service.err` in the log directory: a job whose definition names a controller that is not there fails at launch with nothing else to show. Re-run the installer. |
| `Timed out waiting for the issue approval controller to stop` | Thirty seconds passed without both the status document leaving a live state *and* the manager reporting the job gone. | Read `service.log`. The controller kills its own backend group after ten seconds, so a timeout here is the controller or the manager rather than the pass; ask the manager directly. |
| `An issue approval controller for <repo> is already running …` | Another run, or a transition, holds a lock. The message says which and from where. | Stop it, or wait for the transition to finish. A message naming an install or removal is a transition, not a run. |
| `… is already running from <path>, which is another checkout of the same repository` | Two clones, one identity. | Stop it in that checkout. One repository runs one controller at a time. |
| `There is no installed controller at <path>` | The definition would name a controller link that is not there. | Re-run `python3 tools/install_issue_approval.py` from the checkout. |
| `Canonical issue reviewer was not found at <path>` | The one global issue-review backend this service resolves is absent, or the record naming it is unreadable. | Run `python3 tools/install_issue_review.py` from the Kanban checkout, adding `--install-dir` if it belongs elsewhere. This installer never installs a second copy. |
| `The <manager> job <label> is still present after being removed` | An uninstall did not complete. | Stop the service and retry the uninstall. |
| `Refusing to replace an existing installation: …` | An ordinary file, or a link resolving to something that is not one of Kanban's own modules, occupies an install path. | Move or remove it yourself, then re-run. The installer never replaces it, and it refuses a link whose target is missing too — an absent target carries no identity, so it cannot be shown to be one this installer left behind. |

### The legacy approval daemon

An untracked personal approval daemon predates this service. It deliberately
skips *past* a changes-requested issue and keeps going, which is exactly what
the ordered barrier exists to prevent: with both enabled the barrier would appear
to hold while the other process crossed it.

The supported installer and controller never adopt, migrate, or terminate it. If
it holds the canonical approval lock, install and start refuse with:

```text
Refusing to start the issue approval controller: the canonical approval lock at
<path> is held by the background approval daemon (PID <n>). Stop that daemon
yourself; this service never adopts or terminates it.
```

**The remedy is manual and yours.** Stop that daemon by whatever means you
installed it — for a LaunchAgent, `launchctl bootout gui/$(id -u)/<its label>`
and then move its plist aside — and only then install or start this service.
Nothing here will do it for you, and nothing here will report the daemon's work
as this service's.

Ordinary contention is a different thing entirely and is not refused: an
interactive review or another queue pass holding the lock is the normal `busy`
outcome the poll loop backs off on.

## Reinstalling and upgrading

Re-running the installer is convergent, and a `start` performs the same refresh
on its own. Re-run it:

- after moving the repository checkout;
- when Kanban reports the service as not installed for this repository, or its
  install record as unreadable;
- after pulling a Kanban revision that changes any of the three linked modules,
  or adds one the controller imports. The installed scripts are links and the
  controller is executed out of the install directory, so it resolves its
  imports there rather than in the checkout: a module the current installation
  has no link for makes the controller fail at import until the installer
  supplies it.

Re-running with a different `--install-dir` — or a different
`KANBAN_ISSUE_APPROVAL_INSTALL_DIR` — moves the job: the definition and the
record entry are rewritten against the new directory, and the links in the
directory it left are taken back — but only when no remaining job depends on
them, and only for a link positively recognized as Kanban's own.

An install refuses while this repository's service is running. Stop it first; a
manager asked to replace a definition under a live job leaves a controller
nothing can see or stop.

## Uninstalling

```console
python3 tools/install_issue_approval.py --uninstall --dry-run --json
python3 tools/install_issue_approval.py --uninstall
```

This unloads the stopped job, deletes its definition, and removes that one entry
from the discovery record. It is scoped to one repository throughout, so every
other installed repository's job is untouched. The shared script links go only
when no installed job is left to run from them.

It refuses while the controller is running — the manager is asked first and
believed on its own account, because removal destroys the means of recovery, and
a job whose status document is absent or damaged would otherwise read as
stopped.

**Runtime state, logs, and open incidents are deliberately left behind.** They are
the record of what this service did, and an uninstall is not an acknowledgement.
`status` therefore keeps answering afterwards, reporting whatever the last run
left — a `stopped` service rather than a missing one. Remove them yourself if you
want them gone:

```console
rm -rf ~/Library/Application\ Support/kanban/issue-approval/runtime/<slug>
rm -rf ~/Library/Logs/kanban/issue-approval/<slug>
```

## An unsupported host

Two different refusals, from two different questions.

A host with no reachable service manager cannot install, start, stop, or
uninstall:

```text
No supported service manager found: a Kanban managed service needs either macOS
launchd or a systemd user session reachable through `systemctl --user`.
```

Kanban reports such a host as its own condition — unsupported, offering no
control — rather than as a missing installation or a stopped service.

A host that is not POSIX cannot run the controller at all, whatever its service
manager:

```text
The issue approval controller runs only on POSIX hosts; this one provides no
<missing facilities>. Run it on macOS or Linux.
```

`status` still answers on both, because reading what a run left behind needs
neither a manager nor a process group.

## What this guide does not cover

**Live per-issue progress does not exist yet, and its absence is deliberate.**
The sidebar reports that the service is on, off, barriered, or failed; it does
not report `reviewing issue #N`, which reviewer is running, or which model. The
persistent service was scoped without it, and a separate extension design for a
progress protocol and a richer in-flight UI is still to be written.
`docs/issue_approval_queue_design.md` records that decision as D-6. Read a
sidebar with no per-issue detail as the current design rather than as a defect.

For the behavior itself — how the dashboard discovers, decodes, polls, and
interlocks this service, and what each status state means to the board — see
[docs/design.md](design.md) section 15. This guide deliberately does not restate
it: two descriptions of one state machine is the drift this repository keeps
paying for. What the review itself does — reviewer routing, models, spec
fingerprints, labels, and the approval lock — belongs to the canonical backend
and is described in
[the agent-workflow contract](agent-workflow-contract.md#23-canonical-issue-review-rereview-and-the-solve-readiness-gate).
