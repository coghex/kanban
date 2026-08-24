---
name: drain-prs
description: Control and recover this repository's service-managed approved-PR drainer through its installed controller — status, install, start, stop, restart, logs, incident, ack, and recover. Runs only on an explicit request: when the user asks to inspect, start, stop, restart, or recover the drainer, when a drainer incident notification arrives, or when the user invokes $drain-prs.
---

# PR drainer control

Use the installed controller for every lifecycle operation. Do not create a
second watcher, scheduled task, recurring goal, or persistent agent process.
This command runs only when the user asks for it in that turn: it is never
invoked implicitly, and it never starts, stops, or acknowledges anything on its
own initiative.

It controls the same managed job Claude controls through `/kanban:drain-prs` —
one drainer per repository, two control surfaces, never a second daemon.

## Resolve the repository and the controller

The drainer is per repository, so every invocation names the checkout it
controls **and** the `owner/name` this session believes that checkout is. Set
both once, from the repository being controlled:

```bash
ROOT="$(git rev-parse --show-toplevel)"
REPO="$(git -C "$ROOT" remote get-url origin | sed -E 's#\.git$##; s#.*(/|:)([^/:]+/[^/:]+)$#\2#')"
```

`--path "$ROOT"` selects the repository; `--repo "$REPO"` asserts which one you
believe it is, and the controller refuses the pair when the checkout's remote
says otherwise. Both go on every invocation below. `$ROOT` is a path and
`$REPO` is an `owner/name`; neither substitutes for the other, and the path
variable is not called `REPO`.

**Announce, then act:** name the resolved `$REPO` and the `$ROOT` it was matched
against before the first invocation. Reporting what was resolved is what catches
a wrong resolution, and it catches it only if it lands before anything has been
installed, started, stopped, or acknowledged.

Resolve the controller the way this repository documents it rather than from a
hardcoded path, which would ignore an `--install-dir` install and find nothing
on a host whose managed job lives under the XDG data root. The order is the
`KANBAN_DRAINER_INSTALL_DIR` override first, then
`~/.local/share/kanban/pr-drainer` as the XDG data root spells it — honouring
`$XDG_DATA_HOME` **only when it is absolute** — probed through the `config.json`
install record it would hold, then
`~/Library/Application Support/kanban/pr-drainer`. If you installed with
`--install-dir` and have not exported `KANBAN_DRAINER_INSTALL_DIR`, set
`DRAINER` yourself: the record stays where this platform resolves it, so nothing
here can find the links from it.

```bash
DRAINER="$KANBAN_DRAINER_INSTALL_DIR"
# $XDG_DATA_HOME is honoured only when it is absolute.
DATA_HOME="$HOME/.local/share"
[ "${XDG_DATA_HOME#/}" = "$XDG_DATA_HOME" ] || DATA_HOME="$XDG_DATA_HOME"
[ -n "$DRAINER" ] || DRAINER="$DATA_HOME/kanban/pr-drainer"
[ -n "$KANBAN_DRAINER_INSTALL_DIR" ] || [ -e "$DRAINER/config.json" ] ||
  [ -L "$DRAINER/config.json" ] ||
  DRAINER="$HOME/Library/Application Support/kanban/pr-drainer"
CONTROL="$DRAINER/drain_prs_service.py"
```

An incident belongs to the repository whose drainer raised it — not to whichever
repository surfaced it. The Kanban board displays every drainer's state, so an
incident seen there may well be another repository's; when the reported `--path`
shows no matching incident, check the other repositories' drainers before
concluding there is nothing wrong.

## What the drainer does

The drainer and the managed job that supervises it consume no model tokens while
idle. Nothing polls on an agent's behalf, and no agent process is held open
between drain cycles.

Its one agent spawn is the stale-approved-head rereview. When an approved pull
request's head changes unexpectedly, the drainer rereviews that exact head as
Codex, in a throwaway detached worktree, at the model and effort the roster's
`drain_rereview` codex cell names — GPT-5.6-Terra at medium by default. That
cell is re-read on each drain cycle, so a roster edit takes effect on the next
pass without restarting the managed service. Do not substitute interactive
defaults during recovery. If the selected model cannot be resolved or run, the
drainer stops where it stands with no retry and no fallback; the managed service
then opens an incident and notifies.

An eligible merge conflict is not repaired. The drainer records one open per-PR
incident naming the conflicting files and stops merging that pull request — it
touches no label, merges nothing, and creates no worktree. That incident clears
by itself once the pull request is no longer conflicted, or through `ack`.

## Operations

Take the operation from the user's prompt; default to `status` when none is given.

Every invocation carries both scoping flags and ends in its operation. These
are the seven the controller answers, exactly as they run:

```bash
python3 "$CONTROL" --path "$ROOT" --repo "$REPO" --json status
python3 "$CONTROL" --path "$ROOT" --repo "$REPO" --json install
python3 "$CONTROL" --path "$ROOT" --repo "$REPO" --json start
python3 "$CONTROL" --path "$ROOT" --repo "$REPO" --json stop
python3 "$CONTROL" --path "$ROOT" --repo "$REPO" --json logs --lines 120
python3 "$CONTROL" --path "$ROOT" --repo "$REPO" --json incident
python3 "$CONTROL" --path "$ROOT" --repo "$REPO" --json ack --note "<note>"
```

`incident` and `ack` take an optional incident ID as a positional argument
before their flags; without one, each acts on the latest open incident.

- `status`: summarize the live state, PIDs, last activity, and any open
  incident.
- `install`: install or refresh this repository's managed job without starting
  the drainer.
- `start`: report whether it started or was already running. Run this only when
  the user explicitly supplied `start` or asked to start or resume the drainer
  in this turn.
- `stop`: an intentional stop. It must raise no incident and send no
  notification.
- `restart`: run `stop`, then `start`, then `status`, and succeed only when the
  status is `running`. The controller has no `restart` subcommand; this
  operation is composed from those three.
- `logs [N]`: the end of this repository's own dated drainer log, `--lines`
  defaulting to 120.
- `incident [id]`: the named incident when an id is supplied, or the latest
  open one when none is.
- `ack [id] [note]`: mark an incident resolved, and only after its underlying
  cause is actually resolved.
- `recover`: follow the recovery procedure below.

Do not invoke the installed drainer at `$DRAINER/drain_prs.py` directly for
normal operation. Do not edit its lock, runtime status, scheduler state, or
incident JSON by hand. Do not expose the controller's `run`, `notify-test`, or
`uninstall` subcommands as ordinary lifecycle operations.

## Recover an incident

1. Run `python3 "$CONTROL" --path "$ROOT" --repo "$REPO" --json incident` and
   read every path and fact in the incident before changing anything.
2. Inspect the referenced drainer log, service log, service stderr, scheduler
   state, repository state, and current GitHub pull-request state. Reconstruct
   live truth rather than assuming the crash-time snapshot is still current.
3. Diagnose whether the cause is the drainer implementation, local repository
   state, GitHub authentication or API state, or a particular pull request. Make
   the smallest in-scope repair that resolves the cause.
4. Validate changed Python with `python3 -m py_compile`. Run focused read-only
   or dry-run checks appropriate to the failure. Never use the production daemon
   as the first test of a speculative fix.
5. Run `python3 "$CONTROL" --path "$ROOT" --repo "$REPO" --json start`, then
   verify with `python3 "$CONTROL" --path "$ROOT" --repo "$REPO" --json status`
   that the state is `running`.
6. Only after successful recovery, acknowledge the incident with
   `python3 "$CONTROL" --path "$ROOT" --repo "$REPO" --json ack --note "<concise resolution>"`,
   supplying the incident ID when more than one is open.
7. Report the cause, the repair, the validation, the restart state, and the
   acknowledged incident ID.

If the cause cannot be repaired autonomously, leave the drainer stopped, leave
the incident open, and state exactly what decision or external change is
required.

## Incident policy

- Expected per-pull-request failures remain inside the fair retry and backoff
  scheduler and raise no incident.
- Repeated global failures and unexpected process exits stop the daemon and send
  one urgent notification to the endpoint `KANBAN_DRAINER_NTFY_URL` configures,
  when one is configured.
- That notification may direct the user to Claude's `/kanban:drain-prs`;
  `$drain-prs recover` controls the same incident and is equivalent from
  Codex.
- One incident is one recovery unit. Never acknowledge it until the repaired
  drainer is running.
