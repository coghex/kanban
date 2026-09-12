#!/usr/bin/env python3

"""The mission runner controller.

`kanban --mission-scheduler` advances this repository's runnable missions for
exactly one bounded pass and then exits, writing one JSON report. Something has
to repeat those passes, decide how long to wait between them, and leave a
durable trace of what happened. This module is that something: a foreground
`run` that supervises repeated passes and a read-only `status` that reports
what the last run left behind.

This is also the managed job's controller. Beside `run` and `status` it owns
the job half — the service definition, the discovery record, and the install,
uninstall, start and stop operations `tools/install_mission_runner.py` calls
rather than spawns — on exactly `tools/approve_issues_service.py`'s shape. The
installer owns installation *safety*: which links may be replaced, which may be
removed, and which asset tree they point into. Everything about the job itself
is here, so the code that plans one is the code that performs it.

Four boundaries are deliberate.

It never imports Haskell, and it never reimplements it. Every exchange with the
scheduler is a child process and one bounded JSON document, whose schema,
version, vocabularies and exit statuses are mirrored below from
`Kanban.Mission.Pass` rather than derived. `tools/test_mission_runner_service.py`
holds every mirrored constant equal to the Haskell declaration, so the two
halves of a pass cannot drift apart silently.

It decides nothing about missions. Which missions are runnable, how many are
admitted, what a disposition means, and whether anybody is notified are all the
scheduler's. This module owns repetition, waiting, exclusion, and the runtime
documents a dashboard will later read.

It never accepts a pass it cannot understand. A report that is absent,
truncated, malformed, of another schema or version, about another repository,
carrying an unknown disposition, or contradicting the status the child exited
with is a failed pass — never a successful one and never an idle one. A
supervisor that guessed at any of those would publish a healthy service over a
scheduler that had stopped working.

And it leaves nothing of a pass behind. Each pass runs in a new session, a stop
signals that session's process group, and a group that has not gone within
`STOP_GRACE_SECONDS` is killed outright — so a stop cannot leave a mission
child of the active pass running.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime
import hashlib
import json
import math
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import kanban_config
import service_manager

# Guarded rather than imported outright so a host without them gets the
# diagnostic `require_supported_host` writes instead of an ImportError
# traceback from module load.
try:  # pragma: no cover - the exception arm needs a non-POSIX host
    import fcntl
except ImportError:  # pragma: no cover - see above
    fcntl = None  # type: ignore[assignment]

try:  # pragma: no cover - the exception arm needs a non-POSIX host
    import pwd
except ImportError:  # pragma: no cover - see above
    pwd = None  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# The pass contract, mirrored from Kanban.Mission.Pass
# ---------------------------------------------------------------------------

# The one document `kanban --mission-scheduler` writes to stdout. Mirrored
# rather than imported, for the reason the module docstring gives;
# `tools/test_mission_runner_service.py` holds each of these equal to the
# Haskell declaration it mirrors.
PASS_SCHEMA = "kanban-mission-scheduler-pass"
PASS_VERSION = 1
PASS_FIELDS = frozenset(
    {
        "schema",
        "version",
        "repository",
        "started_at",
        "finished_at",
        "termination",
        "exit_code",
        "admitted",
        "attention",
        "detail",
    }
)
# Termination reason to exit status. The mirror of
# `Kanban.Mission.Pass.missionPassExitCode`, and the only mapping this module
# has: the consistency check below compares a report's own termination against
# the status its child exited with through this table rather than through a
# rule of its own.
PASS_EXIT_CODES = {"completed": 0, "refused": 2, "failed": 1}
PASS_TERMINATIONS = frozenset(PASS_EXIT_CODES)
# A pass that did no work because a precondition refused it. Distinguished from
# a completed one so a configuration error is visible rather than looking like
# a quiet repository.
PASS_REFUSED = "refused"
PASS_COMPLETED = "completed"
PASS_FAILED = "failed"
# What a report names as its repository when the pass failed before it could
# establish one -- a configuration that would not load, or a checkout that
# resolved to nothing. The mirror of
# `Kanban.Mission.Pass.missionPassUnresolvedRepository`.
#
# This controller hands every pass a `--repo`, so it should never see one. It
# is refused by name anyway, and ahead of the ordinary spelling comparison,
# because the two failures are not the same failure: a pass that named another
# repository read somebody else's store, while a pass that named this one
# never got far enough to read anything, and an operator reading an incident
# needs to be told which happened. The NUL is what makes the marker safe to
# compare against a real identity: no GitHub owner or repository name can
# carry one.
PASS_UNRESOLVED_REPOSITORY = "\x00unresolved"
PASS_DISPOSITIONS = frozenset(
    {"advanced", "settled", "blocked", "lease_refused", "refused", "failed"}
)
# The dispositions that make a pass a failed pass, which the scheduler already
# reflects in its termination. Mirrored so a report whose dispositions and
# termination disagree is caught rather than believed.
#
# `refused` is among them and `lease_refused` is not, and the line is what the
# mission could not be advanced *for*: losing a race for an advancement lease
# is two correct processes meeting, while every other typed refusal is a record
# that cannot be read, attributed, or addressed.
PASS_FAILING_DISPOSITIONS = frozenset({"failed", "refused"})
# The dispositions under which a child actually ran and moved the mission. The
# other three did not: both refusals mean the child declined to start, and a
# failure ends the run. `--interval` is documented as the wait "after a pass
# that advanced nothing", so it is these — not merely a non-empty admitted
# list — that earn the immediate next pass. A pass that admitted two missions
# and was refused the lease for both advanced nothing at all, and treating that
# as progress spins passes back to back for as long as the contention lasts.
PASS_PROGRESS_DISPOSITIONS = frozenset({"advanced", "settled", "blocked"})
PASS_NOTIFICATION_STATES = frozenset(
    {
        "disabled",
        "suppressed",
        "completed",
        "failed",
        "timed_out",
        "launch_failed",
        "uncertain",
        "recording_failed",
        "unresolved",
    }
)
PASS_ADMITTED_FIELDS = frozenset({"mission", "disposition", "detail"})
# The compiled ceiling `Kanban.Mission.Scheduler.missionAdmissionCeiling`
# declares. Mirrored rather than trusted, because "at most two" is a contract a
# report can violate: three otherwise well-formed admitted entries would
# otherwise be published as a healthy pass that quietly ignored the ceiling.
PASS_ADMISSION_CEILING = 2
# What `Kanban.Mission.Paths.safeMissionComponent` admits, mirrored: a mission
# identifier is a single plain path component, so it is non-empty, is neither
# `.` nor `..`, and contains no separator and no NUL. A scheduler cannot name a
# mission this rejects — every path it derives goes through that check — so a
# report that does is malformed rather than merely surprising, and accepting
# one would retain a mission identity nothing in the store could address.
PASS_UNSAFE_MISSION_CHARACTERS = frozenset({"/", "\\", "\0"})
PASS_RESERVED_MISSION_NAMES = frozenset({".", ".."})
# The notification state a scheduler writes when it could not resolve which
# items an episode is about. The writer treats that as indeterminate mission
# state and terminates the pass `failed`, so a successful pass carrying one is
# two halves of a report contradicting each other.
PASS_UNRESOLVED_NOTIFICATION = "unresolved"
PASS_ATTENTION_FIELDS = frozenset(
    {"mission", "attention_id", "targets", "notification", "detail"}
)
# The typed items an attention entry names, mirrored from the `targets` array
# `Kanban.Mission.Pass.encodeMissionPassReport` writes and the two kinds its
# `targetKindTag` spells. A list rather than one value because a mission's
# selector resolves to however many items it matched, and an empty list is the
# ordinary answer for a mission created from a bare request.
PASS_TARGET_FIELDS = frozenset({"kind", "number"})
PASS_TARGET_KINDS = frozenset({"issue", "pull_request"})

# The executable a pass is. Resolved from `PATH` unless `--kanban` names one,
# and refused by name when neither is usable, because a controller that started
# with nothing runnable would publish a failed pass every interval instead of
# saying what is actually wrong.
KANBAN_EXECUTABLE = "kanban"
SCHEDULER_FLAG = "--mission-scheduler"

# Identity marker for this tracked asset, in the same form and for the same
# reason `approve_issues_service.py` carries its own:
# `tools/install_mission_runner.py` recognizes the copy it manages by content
# rather than by path, so a link pointing at somebody else's similarly named
# file is never replaced or removed.
KANBAN_MANAGED_ASSET = "kanban-managed-asset:mission-runner/mission_runner_service.py"
CONTROLLER_NAME = "mission_runner_service.py"

# This service's own namespace under the account's roots. Spelled here for a
# diagnostic to name, and spelled again as a literal path segment inside each
# location below rather than composed from this constant: the home-relative
# path gate in `tools/test_agent_workflow_contract.py` recovers a location by
# following literal segments, and a computed one ends the chain it is
# following -- which would leave every managed location this module builds
# reconciled against nothing.
SERVICE_NAME = "mission-runner"

# Where a custom installation puts the script links. Only ever consulted by a
# process that has it; the durable answer for one that does not is the
# `install_dir` each repository's discovery-record entry carries.
INSTALL_DIR_ENV = "KANBAN_MISSION_RUNNER_INSTALL_DIR"
# The discovery document's own file name, inside whichever service root this
# host's installation is in. Spelled once so the record path and the probe that
# selects it cannot disagree about what occupies a candidate.
RECORD_NAME = "config.json"
# The key every installed repository's record is filed under in that document,
# matching the drainer's and the approval service's shape so one reader
# convention serves all three.
RECORD_REPOSITORIES_KEY = "repositories"
# Every environment variable the locations below read, named once so the job
# definition carries exactly the set that decides them rather than a list of
# its own that can fall behind. `tools/kanban_config.py`'s
# `DRAINER_PATH_VARIABLES` exists for this reason and this component needs its
# own because it resolves its roots here rather than there.
PATH_VARIABLES = ("XDG_DATA_HOME", "XDG_STATE_HOME")
# The variable that decides which *shared* Kanban configuration a process reads,
# and therefore which remote it resolves its own repository identity through.
# Carried into an installed job for a reason the two above do not cover: the
# definition records the identity this installer resolved, and the child
# re-resolves one at launch and refuses to act if the two differ -- so a job
# whose configuration context did not travel would refuse its own `--repo` and
# never start. See `shared_config_root`, which resolves it rather than merely
# forwarding it.
CONFIG_ROOT_VARIABLE = "XDG_CONFIG_HOME"
# What a job started by this controller carries so the status document its run
# publishes can be told from one anybody else wrote. See `_start_locked`.
STARTUP_NONCE_ENV = "KANBAN_MISSION_RUNNER_STARTUP_NONCE"

# How long a start waits for the job it kicked to announce itself, and a stop
# for the run it asked to end. Both are the approval service's, and for its
# reasons: a start that returned before the run existed would report a service
# nobody could see, and a stop that returned before the process was gone would
# make the uninstall that may follow it unsafe.
START_TIMEOUT_SECONDS = 15.0
STOP_TIMEOUT_SECONDS = 30.0
START_POLL_SECONDS = 0.25
STOP_POLL_SECONDS = 0.25

# ---------------------------------------------------------------------------
# The runtime documents this controller owns
# ---------------------------------------------------------------------------

STATUS_SCHEMA = "kanban-mission-runner-status"
STATUS_VERSION = 1
INCIDENT_SCHEMA = "kanban-mission-runner-incident"
INCIDENT_VERSION = 1

# The states a status document distinguishes (requirement 10). The first three
# describe a live run; the last two are terminal and outlive the process that
# wrote them.
STATE_RUNNING = "running"
STATE_IDLE = "idle"
STATE_WAITING = "waiting"
STATE_STOPPED = "stopped"
STATE_FAILED = "failed"
# Never written: synthesized by `status_snapshot` for a document that is
# absent, unreadable, of another schema or version, another repository's, or
# stale -- one whose live state names a runner that is not running.
STATE_UNKNOWN = "unknown"
LIVE_STATES = frozenset({STATE_RUNNING, STATE_IDLE, STATE_WAITING})
TERMINAL_STATES = frozenset({STATE_STOPPED, STATE_FAILED})
STATUS_STATES = LIVE_STATES | TERMINAL_STATES

PASS_INCIDENT_KIND = "mission-pass-failed"
CONTROLLER_INCIDENT_KIND = "mission-runner-error"
SEVERITY_ERROR = "error"

DEFAULT_INTERVAL_SECONDS = 60.0
# A pass that advanced something proceeds promptly: the missions it left
# advanceable are advanceable now, and waiting out a whole interval would make
# a repository with work in it progress one mission per minute.
ADVANCE_DELAY_SECONDS = 0.0
# How finely a wait is sliced, so a stop signal is noticed promptly rather than
# at the end of a poll interval. `time.sleep` resumes after a handler that does
# not raise (PEP 475), so a wait has to be built from slices to be
# interruptible.
SLEEP_SLICE_SECONDS = 0.05
# How long an intentional stop waits for the pass's process group to go away
# before escalating to SIGKILL. The escalation is what makes requirement 11's
# promise keepable against a mission child that ignores SIGTERM.
STOP_GRACE_SECONDS = 10.0
# How much of a failed pass's stderr is kept in its incident.
CAPTURED_STDERR_LINES = 60
# The longest escaped slug a runtime directory name may carry before falling
# back to a digest: the longest every service manager can carry an identifier
# for, which is the boundary's answer rather than a number restated here. One
# slug names the job identifier, the runtime directory and the log directory
# together, so a slug that fit a directory name but not a job label would leave
# an installed job nothing could address. It is also well under the 255-byte
# filename ceiling, leaving room for the file names inside the directory it
# names.
SLUG_LIMIT = service_manager.namespace_slug_limit(
    service_manager.MISSION_RUNNER_NAMESPACE
)

INCIDENT_ID_RE = re.compile(r"\Aincident-[A-Za-z0-9TZ-]+\Z")
# The one timestamp form the scheduler emits: `Data.Time.Format.ISO8601`'s
# `iso8601Show` over a `UTCTime`, which is `YYYY-MM-DDTHH:MM:SSZ` with an
# optional fractional part and always the `Z` zone. Matched structurally and
# then range-checked, because a string that is merely non-blank says nothing —
# and these fields are identity-bearing: an attention episode's name is
# `<owner>/<name>#<mission>@<raised-at>`, so a raised-at nobody validated is a
# name nobody validated.
# Exactly what `iso8601Show` emits for a `UTCTime`, and nothing else.
#
# `[0-9]` rather than `\d`, which in Python matches every Unicode decimal
# digit: `٢٠٢٦-٠٩-١١T٠٠:٠٠:٠٠Z` would otherwise pass the shape check, survive
# `int()`, and be persisted as an instant no Haskell writer can emit.
#
# The fraction is `1` to `12` digits ending in a nonzero one, or absent
# altogether. That is not a guess: the producer renders picosecond precision
# and strips trailing zeros, so `00Z`, `00.1Z` and `00.000000000001Z` are its
# forms while `00.10Z` and a thirteenth digit are not. Admitting those would
# let one instant be spelled several ways — and an attention identity ends in
# one of these, so two spellings of one moment would be two episodes.
PASS_TIMESTAMP_RE = re.compile(
    r"\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})"
    r"(?:\.[0-9]{0,11}[1-9])?Z\Z"
)


class ServiceError(RuntimeError):
    """Something this controller refuses to do, with the reason."""


class PassFailure(ServiceError):
    """A pass that cannot be acted on, and what was wrong with it."""

    def __init__(self, summary: str, detail: str | None = None) -> None:
        super().__init__(summary)
        self.summary = summary
        self.detail = detail


# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------


def account_home() -> Path:
    """The home directory of the account this run's state belongs to.

    The passwd database's rather than `$HOME`'s, exactly as
    `approve_issues_service.account_home` resolves it and for the same reason:
    a location that a caller's environment can move cannot serialize anything.
    """
    if pwd is None or not hasattr(os, "getuid"):  # pragma: no cover - non-POSIX
        raise ServiceError(
            "This host has no passwd database, so the mission runner "
            "controller cannot resolve the account its state belongs to."
        )
    uid = os.getuid()
    try:
        entry = pwd.getpwuid(uid)
    except KeyError as exc:
        raise ServiceError(
            f"No passwd entry describes uid {uid}, so the mission runner "
            "controller cannot resolve the account its state belongs to."
        ) from exc
    home = Path(entry.pw_dir) if entry.pw_dir else None
    if home is None or not home.is_absolute():
        raise ServiceError(
            f"The passwd entry for uid {uid} names no absolute home directory "
            f"({entry.pw_dir!r}), so the mission runner controller cannot "
            "resolve the account its state belongs to."
        )
    return home


def _macos_service_root() -> Path:
    """The `~/Library`-spelled service root, named on every platform.

    macOS's own write path, and on any other host the location an installation
    made under that spelling is at — which is why the probe below keeps looking
    there. Written out so the manifest row that declares it is grounded in the
    module that builds it: ~/Library/Application Support/kanban/mission-runner.
    """
    return account_home() / "Library" / "Application Support" / "kanban" / "mission-runner"


def _xdg_service_root() -> Path:
    """The XDG data location: `$XDG_DATA_HOME` when it names an absolute
    directory, and ~/.local/share/kanban/mission-runner when it does not.

    Absolute-only is the drainer's rule rather than issue-review's, for the
    drainer's stated reason — the systemd unit that runs this job and the
    managed paths that locate it must read the environment identically. A
    relative value would otherwise resolve against whatever working directory
    each of them happened to have, which is not a base directory the two could
    ever agree on.
    """
    configured = os.environ.get("XDG_DATA_HOME")
    if configured and os.path.isabs(configured):
        return Path(configured) / "kanban" / "mission-runner"
    return account_home() / ".local" / "share" / "kanban" / "mission-runner"


def default_service_root() -> Path:
    """Where a *fresh* installation of this service goes on this host: this
    platform's own convention and only that.

    Where an installation that already exists *is* is the different question
    `installed_service_root` answers by probing both. The split is
    `tools/kanban_config.py`'s `default_drainer_install_dir` against
    `installed_drainer_dir`, and this component follows it for the same reason:
    nothing an operator already installed has to move.

    Resolved per call rather than frozen at import, exactly as
    `kanban_config.default_issue_review_install_dir` is and for the same
    reason: freezing it would bind whatever the account resolved to when the
    module first loaded.
    """
    if kanban_config.is_macos():
        return _macos_service_root()
    return _xdg_service_root()


def installed_service_root() -> Path:
    """Where this account's mission runner installation already is.

    The XDG location first and the `~/Library` location second, on both
    platforms, taking the first that is *occupied* — so a macOS host that
    installed under XDG keeps that installation, and a Linux host that
    inherited a `~/Library` one keeps that. Only when neither is occupied is
    the answer this platform's own write path.

    Occupancy is the discovery record's, tested with `os.path.lexists` rather
    than `is_file`, so a candidate that is occupied but *invalid* — a directory
    where the record belongs, a link that cannot be followed — still selects
    that installation. Reading such a candidate as absent and resolving the
    lower-precedence one would silently name an installation the operator did
    not choose and say nothing about the record that is wrong; what is wrong
    with it is for the readers that then open it to report.

    `src/Kanban/ManagedPaths.hs` answers this same question for the dashboard,
    in the same order and by the same occupancy test, which is what keeps the
    two halves of the host from disagreeing about which installation it has.
    """
    for candidate in (_xdg_service_root(), _macos_service_root()):
        if os.path.lexists(candidate / RECORD_NAME):
            return candidate
    return default_service_root()


def service_root() -> Path:
    """This service's one root for this account: the installation this host
    already has, or this platform's write default when it has none.

    There is deliberately no override, and `--install-dir` is not one: it moves
    the script links and the install directory beneath them, never this. A
    configurable runtime cannot serialize anything a configuration can change,
    and a dashboard that inherits no environment has to find the runtime of a
    job installed anywhere.
    """
    return installed_service_root()


def discovery_record_path() -> Path:
    """The one document Kanban reads to find this service's installed jobs.

    Fixed rather than `--install-dir`-relative, exactly as the drainer's, the
    issue-review backend's and the approval service's records are, and for the
    same reason: a dashboard that never inherits `INSTALL_DIR_ENV` still has to
    discover an installation made anywhere, so the record's own path is the one
    thing that cannot move.

    The two home-relative spellings it resolves to, written out so the manifest
    rows that declare them are grounded here as well as in the Haskell
    resolver: ~/Library/Application Support/kanban/mission-runner/config.json
    and ~/.local/share/kanban/mission-runner/config.json.
    """
    return installed_service_root() / RECORD_NAME


def default_install_dir() -> Path:
    """Where the script links go when nothing selects otherwise: beside the
    record, which is the drainer's and the approval service's arrangement too.
    Spelled as the record's own directory rather than a second time, so the two
    cannot drift apart."""
    return installed_service_root()


def install_dir_override() -> Path | None:
    """The install directory `INSTALL_DIR_ENV` names, or None when it names
    none — refusing a value that is not absolute once `~` is expanded.

    Absolute-only, and *refused* rather than resolved or quietly ignored. Two
    processes read this variable with two different working directories: the
    operator's shell when the installer runs, and the repository checkout when
    a service manager launches the job. So a relative value names two different
    directories, and resolving it here would only pick whichever one this
    reader happened to have — the install would report success while the
    definition, the record, and the links named three places. Falling back to
    the default instead would install somewhere the operator did not choose,
    which is worse than refusing; and the same reasoning is why
    `_xdg_service_root` takes an absolute `$XDG_DATA_HOME` and nothing else.

    The one place this variable is read, so the controller's own install
    directory and the installer's default destination cannot disagree about
    whether it was set or about whether it was usable.
    """
    override = os.environ.get(INSTALL_DIR_ENV)
    if not override or not override.strip():
        return None
    selected = Path(override).expanduser()
    if not selected.is_absolute():
        raise ServiceError(
            f"{INSTALL_DIR_ENV} names {override!r}, which is not an absolute "
            "directory. It is read by this installer and by the job a service "
            "manager launches, which have different working directories, so a "
            "relative value names a different installation to each of them. "
            "Give it an absolute path, or unset it and pass --install-dir."
        )
    return selected


def selected_install_dir() -> Path:
    """The install directory this process was pointed at, or the default.

    Only the environment is consulted, because that is all a process starting
    from nothing has. Which directory one *repository's* job was installed into
    is a different and more specific question, answered by `job_install_dir`
    once an identity is known.
    """
    override = install_dir_override()
    return override if override is not None else default_install_dir()


def controller_path(install_dir: Path) -> Path:
    """The installed controller a service definition names.

    Named from the install directory rather than from `__file__`: the
    definition has to name the stable installed link, so that repointing the
    link is how a moved checkout is repaired without rewriting every job.
    """
    return install_dir / CONTROLLER_NAME


def shared_config_root() -> str:
    """The XDG config base directory the shared Kanban configuration this
    process reads lives under, as an absolute path.

    Resolved rather than forwarded, which is the opposite of what
    `service_definition` does with `PATH_VARIABLES`, and deliberately.
    `kanban_config.default_config_path` takes *any* non-empty
    `$XDG_CONFIG_HOME` and otherwise `Path.home()`, so the file it names depends
    on the reader's working directory and on `$HOME` -- neither of which an
    installed job shares with the installer, whose `HOME` the definition
    replaces with the account's own. Forwarding the variable unchanged would
    leave the two reading different files for a relative value, and dropping it
    would do the same whenever `$HOME` is not the passwd home. Resolving it here
    pins the one file this installation actually read.

    The absolute-only rule the data and state roots use is right for them
    because both sides apply that same rule and therefore fall back together;
    there is no such shared rule here to fall back to.
    """
    configured = os.environ.get(CONFIG_ROOT_VARIABLE)
    if configured:
        return str(Path(configured).expanduser().resolve())
    return str((Path.home() / ".config").resolve())


def log_root() -> Path:
    """Where every repository's per-slug log directory hangs off.

    Single-valued per platform rather than probed, exactly as the drainer's log
    root is: `--install-dir` relocates the script links and the install
    directory beneath them, never the logs, so there is no second location for
    a probe to prefer. `$XDG_STATE_HOME` selects the XDG spelling on the same
    absolute-only terms `_xdg_service_root` explains.

    The two home-relative spellings, written out for the manifest rows that
    declare them: ~/Library/Logs/kanban/mission-runner on macOS, and
    ~/.local/state/kanban/mission-runner everywhere else.
    """
    if kanban_config.is_macos():
        return account_home() / "Library" / "Logs" / "kanban" / "mission-runner"
    configured = os.environ.get("XDG_STATE_HOME")
    if configured and os.path.isabs(configured):
        return Path(configured) / "kanban" / "mission-runner"
    return account_home() / ".local" / "state" / "kanban" / "mission-runner"


def runtime_root() -> Path:
    """Where each identity's status and incidents live.

    Independent of any installation directory (requirement 10): a dashboard
    that inherits no environment has to find the runtime of a job installed
    anywhere, so this is the one thing that cannot move.

    Resolves to ~/Library/Application Support/kanban/mission-runner/runtime on
    macOS and ~/.local/share/kanban/mission-runner/runtime everywhere else.
    """
    return service_root() / "runtime"


def lock_root() -> Path:
    """Where each identity's run lock lives.

    Beside the runtime rather than inside it, so a lock is never removed by
    something clearing a repository's runtime documents. Resolves to
    ~/Library/Application Support/kanban/mission-runner/locks on macOS and
    ~/.local/share/kanban/mission-runner/locks everywhere else.
    """
    return service_root() / "locks"


def run_lock_path(slug: str) -> Path:
    """The lock a `run` takes for one canonical identity.

    Named by the identity rather than by the checkout, and anchored to the
    account's service root, so two *clones* of one GitHub repository contend
    here even though they share no Git directory (requirement 11).
    """
    return lock_root() / f"{slug}.lock"


def transition_lock_path(slug: str) -> Path:
    """The lock every transition of one identity's job is performed under.

    Distinct from `run_lock_path` and held for a different span. That one is
    held by a run for its whole life, so a transition could never take it; this
    one is held only while a job is being installed, started, stopped, or
    removed, which is exactly the window in which two transitions could
    otherwise interleave — a start kicking a unit between an uninstall's
    liveness check and its removal, leaving a controller running that nothing
    can discover or stop.
    """
    return lock_root() / f"{slug}.transition.lock"


def installation_lock_path(install_dir: Path) -> Path:
    """The lock every transition touching one installation's shared links is
    performed under.

    Per install directory rather than per identity, because the links are what
    several repositories share: one repository's uninstall decides whether they
    may go by reading which others still depend on them, and an install for a
    different repository writing them in between would leave a job pointing at
    links that were then deleted.

    Named by the install directory's resolved path and kept in the account's
    lock root rather than inside the installation, so it exists before the
    directory does and is not itself something an uninstall has to clean up.
    """
    digest = hashlib.sha256(
        os.path.realpath(install_dir).encode("utf-8")
    ).hexdigest()[:32]
    return lock_root() / f"install-{digest}.lock"


def _escape_identity_segment(segment: str) -> str:
    """Encodes one identity segment into `[A-Za-z0-9_-]`, reversibly.

    `-` is the escape character and always consumes exactly one following
    character, so the encoding is a prefix code and therefore injective: `-`
    encodes as `--` and `.` as `-d`, and nothing else in the GitHub identity
    charset `[A-Za-z0-9._-]` needs escaping. `.` never survives into the
    output, which is what lets the slug keep it as the owner/name separator.
    """
    escapes = {"-": "--", ".": "-d"}
    return "".join(escapes.get(character, character) for character in segment)


def repository_slug(identity: str) -> str:
    """A filename-safe directory name for one normalized identity.

    Total, nonempty, and injective across distinct normalized identities. An
    identity whose escaped slug would outgrow `SLUG_LIMIT` falls back to a hash
    of the whole identity, which cannot collide with an escaped slug because it
    contains no `.` at all.
    """
    owner, _, name = identity.partition("/")
    slug = f"{_escape_identity_segment(owner)}.{_escape_identity_segment(name)}"
    if len(slug) > SLUG_LIMIT:
        return "h" + hashlib.sha256(identity.encode("utf-8")).hexdigest()
    return slug


def normalize_identity(raw_value: str) -> str:
    """The canonical GitHub identity a value names, case-folded, or a
    ServiceError naming the value that could not be one."""
    try:
        return kanban_config.normalize_github_repository(raw_value)
    except kanban_config.KanbanConfigError as exc:
        raise ServiceError(str(exc)) from exc


@dataclass(frozen=True)
class MissionRunnerJob:
    """One repository's mission runner: its identity and every mutable path
    that belongs to it alone."""

    repo_path: Path
    identity: str
    # What a pass is handed as `--repo`. The identity above partitions this
    # service's own state and is folded for it; this is the repository as
    # Kanban spells it, which is what its mission store is keyed on.
    spelling: str
    slug: str
    runtime_dir: Path
    incident_dir: Path
    status_path: Path
    lock_path: Path
    # This repository's own log directory, where the service manager is told to
    # send an installed job's output. Empty and unused by a foreground run,
    # which writes to whatever its caller gave it.
    log_dir: Path
    config_path: str | None


def job_for_identity(
    repo_path: Path,
    identity: str,
    *,
    spelling: str | None = None,
    config_path: str | None = None,
) -> MissionRunnerJob:
    slug = repository_slug(identity)
    runtime_dir = runtime_root() / slug
    return MissionRunnerJob(
        repo_path=repo_path,
        identity=identity,
        # Defaults to the identity, which is right for every caller that knows
        # only a canonical name -- `status` and `ack` never launch a pass.
        spelling=spelling if spelling is not None else identity,
        slug=slug,
        runtime_dir=runtime_dir,
        incident_dir=runtime_dir / "incidents",
        status_path=runtime_dir / "status.json",
        lock_path=run_lock_path(slug),
        log_dir=log_root() / slug,
        config_path=config_path,
    )


def require_supported_host() -> None:
    """Refuse a host this controller cannot supervise a child on.

    Every mechanism `run` depends on is POSIX: an advisory `flock` for the
    per-identity run lock, a new session per pass, and a signal to that
    session's process group. Pure code and the fixtures around it stay
    portable, but a run that cannot terminate its own child has no safe
    degraded mode, so this refuses rather than proceeding.
    """
    missing = [
        name
        for name, present in (
            ("POSIX process semantics", os.name == "posix"),
            ("fcntl.flock", fcntl is not None),
            ("passwd database", pwd is not None and hasattr(os, "getuid")),
            ("os.killpg", hasattr(os, "killpg")),
            ("os.setsid via start_new_session", hasattr(os, "setsid")),
        )
        if not present
    ]
    if missing:
        raise ServiceError(
            "The mission runner controller needs "
            + ", ".join(missing)
            + ", which this host does not provide."
        )


# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------


def run_command(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(args, text=True, capture_output=True)
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise ServiceError(f"Command failed: {' '.join(args)}\n{detail}")
    return proc


def configured_remote_name(config_path: str | None) -> str:
    try:
        raw_config, _ = kanban_config.load_raw_config(config_path)
    except kanban_config.KanbanConfigError:
        return "origin"
    return raw_config.remote_name


@dataclass(frozen=True)
class RepositoryNames:
    """The two spellings of one repository, and what each is for.

    They are not interchangeable, and using one where the other belongs is a
    real defect rather than an aesthetic one.

    `canonical` is case-folded, because GitHub owner and repository names are
    case-insensitive: two clones spelled differently name one repository and
    must contend for one run lock and share one runtime directory.

    `spelling` is what the remote actually says, because Kanban keeps a
    repository's case -- `Kanban.Mission.Paths.missionStoreKey` builds a
    mission store path from it segment by segment, and
    `Kanban.Mission.Types.missionRepositoryMatches` is plain equality. Handing
    a pass the folded spelling for a remote such as `Acme/Widgets` would open a
    *different* store on a case-sensitive filesystem, and on a case-insensitive
    one would find the mixed-case records and refuse them as another
    repository's.
    """

    canonical: str
    spelling: str


def repository_names(repo_path: Path, remote_name: str) -> RepositoryNames:
    """Both spellings, from one read of the remote.

    One read rather than two, so the pair cannot come from two different
    answers if the remote is rewritten between them.

    Fails closed. A checkout whose remote does not name a repository on
    github.com has no mission runner identity, so it can neither run nor be
    observed -- deriving one from an unsupported value would partition state
    under a name Kanban's own resolver would never look for.
    """
    proc = run_command(
        ["git", "-C", str(repo_path), "remote", "get-url", remote_name], check=False
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        raise ServiceError(
            f"Could not read the {remote_name!r} remote of {repo_path}: {detail}"
        )
    try:
        spelling = kanban_config.parse_github_repository(proc.stdout)
    except kanban_config.KanbanConfigError as exc:
        raise ServiceError(
            f"{repo_path} is not a checkout of a supported GitHub repository, so it "
            f"cannot run or report a mission runner service: {exc}"
        ) from exc
    return RepositoryNames(canonical=spelling.lower(), spelling=spelling)


def repository_identity(repo_path: Path, remote_name: str) -> str:
    """The canonical GitHub repository this checkout is a clone of."""
    return repository_names(repo_path, remote_name).canonical


def discovery_remote_name() -> str:
    """The remote this service's *identity* is resolved through.

    Always the shared Kanban configuration's, never a repository's own
    `--config`, exactly as the issue approval controller resolves its own: it
    is the remote Kanban itself resolves its repository through, so both sides
    name the same identity, and it breaks a circularity a per-repository
    `--config` would introduce.
    """
    return configured_remote_name(None)


def resolve_job(repo_path: Path, *, config_path: str | None = None) -> MissionRunnerJob:
    """This checkout's job, with the configuration its installation selected.

    An explicit `--config` wins; otherwise the one recorded for this identity
    at install time is used. That fallback is what makes the selection durable:
    a `start` issued with no flags, or a job relaunched by a service manager
    into an empty environment, has to run with the configuration the operator
    installed rather than silently reverting to the shared default — and a
    start refreshes the definition, so without it the recorded `--config` would
    survive in the record while disappearing from the job that reads it.

    Resolvable only because the identity does not depend on `--config`: the
    record is keyed by identity, and the remote that resolves that identity is
    the shared configuration's rather than this one (see
    `discovery_remote_name`), so a configuration that could move the identity
    could not be found by it.
    """
    names = repository_names(repo_path, discovery_remote_name())
    selected = config_path or installed_config_path(names.canonical)
    return job_for_identity(
        repo_path, names.canonical, spelling=names.spelling, config_path=selected
    )


def require_requested_identity(job: MissionRunnerJob, requested: str | None) -> None:
    """Refuses a caller whose repository is not the one this job is for."""
    if requested is None:
        return
    wanted = normalize_identity(requested)
    if wanted != job.identity:
        raise ServiceError(
            f"--repo {requested} names {wanted}, but {job.repo_path} is a checkout "
            f"of {job.identity}; refusing to act on another repository's mission "
            "runner. Align remote_name in the shared Kanban configuration with "
            "the repository you mean."
        )


def resolve_kanban(explicit: str | None) -> Path:
    """The `kanban` executable a pass runs, or a named configuration refusal.

    An explicit path wins and is required to be executable; otherwise `PATH` is
    asked. Refused here, before the run lock is taken and before anything is
    written, because a controller that started with nothing runnable would
    publish one failed pass per interval rather than the one sentence that says
    what is wrong.

    Whatever is resolved is made absolute before it is stored, and that is not
    tidiness. Every pass runs with the repository checkout as its working
    directory, so a relative path — one a caller typed, and equally one `PATH`
    returned for a relative entry — is resolved against *this* process's
    directory when it is checked here and against the *checkout* when it is
    launched. Those are different files, and the second one usually does not
    exist, so a controller that stored the relative spelling would pass every
    check at startup and then fail every pass.
    """
    if explicit:
        candidate = Path(explicit).expanduser().resolve()
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            raise ServiceError(
                f"--kanban {explicit} does not name an executable file, so no "
                "mission scheduler pass can be run."
            )
        return candidate
    found = shutil.which(KANBAN_EXECUTABLE)
    if not found:
        raise ServiceError(
            f"{KANBAN_EXECUTABLE!r} was not found on PATH, so no mission "
            "scheduler pass can be run. Install it, or pass --kanban with the "
            "path to the executable."
        )
    return Path(found).resolve()


# ---------------------------------------------------------------------------
# Documents
# ---------------------------------------------------------------------------


def _read_json_document(path: Path) -> Any:
    # UnicodeDecodeError alongside the rest: it is a ValueError rather than an
    # OSError, so bytes that are not UTF-8 would otherwise escape a reader
    # every caller expects to answer "nothing readable here".
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, UnicodeDecodeError, json.JSONDecodeError, OSError):
        return None


def read_json(path: Path) -> dict[str, Any] | None:
    value = _read_json_document(path)
    return value if isinstance(value, dict) else None


def utc_stamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def local_stamp() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    """Replace `path` with `value` in one step.

    Every runtime document goes through this: a dashboard will poll them while
    this controller writes them, and a reader that can observe a half-written
    document is a reader that can observe a service in a state it was never in.
    """
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp_name = tempfile.mkstemp(prefix=f"{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def ensure_dirs(job: MissionRunnerJob) -> None:
    for path in (job.runtime_dir, job.incident_dir):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.chmod(0o700)


def service_log(job: MissionRunnerJob, message: str) -> None:
    """Narration, to this process's own stderr.

    Deliberately not a file even now that this service has log directories. An
    installed job's stderr is what the service manager redirects into
    `job.log_dir`, so writing there directly would be this process choosing a
    destination its own manager had already chosen; a controller invoked in the
    foreground writes where its caller can see it. Either way the durable
    account of what happened is the status document and the incidents.
    """
    print(f"[{local_stamp()}] {message}", file=sys.stderr, flush=True)


def process_start_identity(pid: Any) -> str | None:
    """When the process holding this identifier started, or None.

    A process identifier alone does not identify a process: the kernel recycles
    them, so a wrapper that crashed while its status said `running` leaves a
    document whose `runner_pid` may later belong to something else entirely —
    and `os.kill(pid, 0)` would confirm that stranger is alive. The start time
    is what makes the pair unique, which is the same reason
    `Kanban.Process.ProcessIdentity` carries one.

    `ps -o lstart=` rather than anything computed here, because only the kernel
    knows. Anything that is not a single readable line is None, which the
    caller reads as "this cannot be confirmed" rather than as a match.
    """
    if not is_plain_integer(pid) or pid <= 0:
        return None
    proc = run_command(["ps", "-o", "lstart=", "-p", str(pid)], check=False)
    if proc.returncode != 0:
        return None
    started = (proc.stdout or "").strip()
    return started or None


def pid_alive(pid: Any) -> bool:
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return True
    return True


def is_plain_integer(value: Any) -> bool:
    """An integer that is not a Boolean.

    `bool` is a subclass of `int` and `True == 1`, so every numeric check on a
    document another process wrote has to exclude it explicitly or accept
    `true` wherever it accepts `1`.
    """
    return isinstance(value, int) and not isinstance(value, bool)


def pinned_version(value: Any, expected: int) -> bool:
    return is_plain_integer(value) and value == expected


def tail(text: str | None, lines: int = CAPTURED_STDERR_LINES) -> str | None:
    if not text:
        return None
    return "\n".join(text.splitlines()[-lines:]) or None


# ---------------------------------------------------------------------------
# Locks
# ---------------------------------------------------------------------------


def _read_lock_owner(handle: Any) -> dict[str, Any]:
    try:
        handle.seek(0)
        document = json.loads(handle.read() or "{}")
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return {}
    return document if isinstance(document, dict) else {}


def describe_run_owner(owner: dict[str, Any]) -> str:
    pid = owner.get("pid")
    repo = owner.get("repo")
    if isinstance(pid, int) and isinstance(repo, str):
        return f" (PID {pid}, from {repo})"
    if isinstance(pid, int):
        return f" (PID {pid})"
    return ""


@contextlib.contextmanager
def held_exclusively(
    path: Path,
    job: MissionRunnerJob,
    refusal: Callable[[str], str],
    *,
    mode: str = "run",
) -> Iterator[None]:
    """Hold one non-blocking exclusive lock, or refuse with `refusal`.

    `refusal` is called with a description of the owner rather than
    interpolated into, so no repository path can be read as a format field.

    `mode` is what the holder is doing, recorded so a contender can say which
    it lost to. A `run` and a transition that must exclude one take the very
    same lock — that is how they are made mutually exclusive — and "a mission
    runner is already running" would be the wrong sentence for half of those
    encounters.

    The losing contender closes without truncating, so it cannot erase the
    owner's own diagnostic metadata.
    """
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        handle = open(path, "a+", encoding="utf-8")
    except OSError as exc:
        raise ServiceError(f"Could not open the run lock at {path}: {exc}") from exc
    if fcntl is None:  # pragma: no cover - require_supported_host refused first
        handle.close()
        raise ServiceError("This host provides no fcntl.flock.")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        owner = _read_lock_owner(handle)
        handle.close()
        raise ServiceError(refusal(describe_run_owner(owner))) from exc
    except OSError:
        handle.close()
        raise
    try:
        handle.seek(0)
        handle.truncate()
        handle.write(
            json.dumps(
                {
                    "pid": os.getpid(),
                    "repo": str(job.repo_path),
                    "repository": job.identity,
                    "mode": mode,
                    "started_at": utc_stamp(),
                },
                sort_keys=True,
            )
        )
        handle.flush()
        os.fsync(handle.fileno())
        yield
    finally:
        with contextlib.suppress(OSError):
            handle.seek(0)
            handle.truncate()
            handle.flush()
        handle.close()


@contextlib.contextmanager
def run_lock(job: MissionRunnerJob) -> Iterator[None]:
    """Hold this identity's exclusive run lock, or refuse.

    Requirement 11's "a second wrapper for the same repository refuses and
    starts no scheduler": non-blocking, so a contended start fails immediately
    rather than queueing behind a run that may last for hours, and taken before
    any status or incident is written, so a refused second run changes nothing
    the first one owns.
    """
    with held_exclusively(
        job.lock_path,
        job,
        lambda owner: (
            f"A mission runner for {job.identity} is already running{owner}. "
            "One repository runs one mission runner at a time."
        ),
    ):
        yield


# ---------------------------------------------------------------------------
# Incidents
# ---------------------------------------------------------------------------


def incident_documents(
    job: MissionRunnerJob, *, open_only: bool = False, kind: str | None = None
) -> list[tuple[Path, dict[str, Any]]]:
    """This repository's incidents, newest first.

    Filtered on the recorded canonical identity rather than on the checkout
    path that raised them, so a second clone of one GitHub repository observes
    and acknowledges the same incidents. A document of another schema or
    version is not this controller's and is left alone.
    """
    if not job.incident_dir.is_dir():
        return []
    found: list[tuple[Path, dict[str, Any]]] = []
    for path in sorted(job.incident_dir.glob("incident-*.json"), reverse=True):
        document = read_json(path)
        if document is None:
            continue
        if document.get("schema") != INCIDENT_SCHEMA:
            continue
        if not pinned_version(document.get("version"), INCIDENT_VERSION):
            continue
        if document.get("repository") != job.identity:
            continue
        if open_only and document.get("status") != "open":
            continue
        if kind is not None and document.get("kind") != kind:
            continue
        found.append((path, document))
    return found


def _new_incident_path(job: MissionRunnerJob, suffix: str) -> tuple[Path, str]:
    job.incident_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    base = time.strftime("incident-%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{os.getpid()}{suffix}"
    incident_id = base
    duplicate = 1
    while (job.incident_dir / f"{incident_id}.json").exists():
        duplicate += 1
        incident_id = f"{base}-{duplicate}"
    return job.incident_dir / f"{incident_id}.json", incident_id


def record_incident(
    job: MissionRunnerJob, *, kind: str, summary: str, detail: str | None
) -> dict[str, Any]:
    """Record that a pass, or this controller around one, failed."""
    path, incident_id = _new_incident_path(job, "-error")
    document = {
        "schema": INCIDENT_SCHEMA,
        "version": INCIDENT_VERSION,
        "incident_id": incident_id,
        "kind": kind,
        "severity": SEVERITY_ERROR,
        "status": "open",
        "repository": job.identity,
        "repo": str(job.repo_path),
        "summary": summary,
        "detail": detail,
        "occurred_at": utc_stamp(),
        "path": str(path),
    }
    atomic_write_json(path, document)
    return document


def acknowledge_incident(
    job: MissionRunnerJob, incident_id: str | None, note: str | None
) -> dict[str, Any]:
    """Dismiss one incident record for bookkeeping.

    Deliberately powerless over the service: acknowledging the incident a
    failed pass opened does not make the next pass succeed.
    """
    if incident_id is not None and not INCIDENT_ID_RE.fullmatch(incident_id):
        raise ServiceError(f"{incident_id!r} is not an incident identifier.")
    for path, document in incident_documents(job, open_only=True):
        if incident_id is not None and document.get("incident_id") != incident_id:
            continue
        document["status"] = "resolved"
        document["resolved_at"] = utc_stamp()
        document["resolution"] = note or "acknowledged"
        atomic_write_json(path, document)
        return document
    raise ServiceError(
        f"No open mission runner incident for {job.identity}"
        + (f" matches {incident_id}." if incident_id else ".")
    )


# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------


def _classify_status(
    job: MissionRunnerJob, stored: dict[str, Any] | None, present: bool
) -> tuple[str, str | None]:
    """The state a reader may believe, and why it is not the recorded one.

    Every way a stored document can fail to describe this service now --
    absent, unreadable, another schema or version, another repository's, a
    state this reader does not know, or a live state whose runner is gone --
    collapses to `unknown` with the reason named, because a reader that cannot
    tell those apart from "healthy" is a reader that reports a dead service as
    running.
    """
    if stored is None:
        if not present:
            return STATE_UNKNOWN, "no status document has been written yet"
        return STATE_UNKNOWN, f"the status document at {job.status_path} could not be read"
    if stored.get("schema") != STATUS_SCHEMA:
        return STATE_UNKNOWN, (
            f"the status document at {job.status_path} has schema "
            f"{stored.get('schema')!r}, not {STATUS_SCHEMA!r}"
        )
    if not pinned_version(stored.get("version"), STATUS_VERSION):
        return STATE_UNKNOWN, (
            f"the status document at {job.status_path} has version "
            f"{stored.get('version')!r}, not {STATUS_VERSION}"
        )
    recorded = stored.get("repository")
    if recorded != job.identity:
        return STATE_UNKNOWN, (
            f"the status document at {job.status_path} records repository "
            f"{recorded!r}, not {job.identity!r}"
        )
    state = stored.get("state")
    # Type before membership, for the reason `_require_vocabulary` gives: a
    # JSON array or object is unhashable, so `state in STATUS_STATES` would
    # raise rather than answer — and this is the read-only diagnostic somebody
    # reaches for when the runtime is already in a bad state. It has to report
    # `unknown` with a reason, not crash.
    if not isinstance(state, str) or state not in STATUS_STATES:
        return STATE_UNKNOWN, (
            f"the status document at {job.status_path} records unknown state {state!r}"
        )
    if state in LIVE_STATES:
        runner_pid = stored.get("runner_pid")
        if not pid_alive(runner_pid):
            return STATE_UNKNOWN, (
                f"the status document at {job.status_path} records {state} under runner "
                f"PID {runner_pid!r}, which is not running"
            )
        # Alive is not enough. The kernel recycles identifiers, so a wrapper
        # that crashed leaves a document whose PID may since have been handed
        # to something else — and that stranger being alive would otherwise
        # authenticate a state nobody is in. The start time the runner recorded
        # is what pairs the identifier with the process that really wrote it.
        recorded = stored.get("runner_identity")
        if not isinstance(recorded, str) or not recorded.strip():
            return STATE_UNKNOWN, (
                f"the status document at {job.status_path} records {state} and no "
                "runner identity, so the process it names cannot be confirmed"
            )
        running = process_start_identity(runner_pid)
        if running != recorded:
            return STATE_UNKNOWN, (
                f"the status document at {job.status_path} records {state} under runner "
                f"PID {runner_pid!r}, which now belongs to a different process"
            )
    return state, None


def status_snapshot(job: MissionRunnerJob) -> dict[str, Any]:
    """This repository's mission runner state, read and never repaired.

    Strictly read-only: no directory is created, no document is rewritten, and
    no incident is opened or resolved, because status is the diagnostic reached
    for when the runtime is already in a bad state and a reader that repairs
    what it reads destroys the evidence it was called to show.
    """
    present = os.path.lexists(job.status_path)
    stored = read_json(job.status_path) if present else None
    state, reason = _classify_status(job, stored, present)
    stored = stored or {}
    open_incidents = [document for _path, document in incident_documents(job, open_only=True)]
    return {
        "schema": STATUS_SCHEMA,
        "version": STATUS_VERSION,
        "state": state,
        # Null on a clean read; otherwise why the recorded state was not
        # believed, which is the difference between "stopped" and "cannot say".
        "reason": reason,
        "repository": job.identity,
        "repo": str(job.repo_path),
        # The checkout a *live* run is actually being supervised from, which is
        # not necessarily this job's: two clones of one GitHub repository
        # resolve to one identity and one runtime.
        "active_repo": stored.get("repo") if state in LIVE_STATES else None,
        "runner_pid": stored.get("runner_pid") if state in LIVE_STATES else None,
        # Only while it is really there: a pass that has finished leaves its
        # PID recorded until the next write, and reporting that as a live child
        # would describe work nobody is doing.
        "pass_pid": (
            stored.get("pass_pid")
            if state in LIVE_STATES and pid_alive(stored.get("pass_pid"))
            else None
        ),
        "started_at": stored.get("started_at"),
        "updated_at": stored.get("updated_at"),
        "message": stored.get("message"),
        "last_pass": stored.get("last_pass"),
        "passes": stored.get("passes"),
        "attention": stored.get("attention"),
        "open_incident": open_incidents[0] if open_incidents else None,
        "open_incidents": open_incidents,
        "status_path": str(job.status_path),
    }


# ---------------------------------------------------------------------------
# Pass results
# ---------------------------------------------------------------------------


def parse_pass_report(stdout: str, returncode: int) -> dict[str, Any]:
    """The one report document a scheduler pass wrote, or a `PassFailure`
    naming what was wrong with it.

    Every refusal below is a refusal to guess, and each one is a shape that
    would otherwise be read as a healthy quiet repository:

    * no output at all, or output that will not parse, from a pass that exited
      zero;
    * a schema or version this controller was not built to read;
    * a field missing, or one this controller does not know about;
    * a report about a repository this job is not for;
    * a disposition, notification state, or termination outside the vocabulary
      the scheduler declares;
    * a report whose termination does not match the status the child exited
      with.

    The exit status is checked against the report's own termination through
    `PASS_EXIT_CODES`, which is the mirror of the scheduler's own mapping, so
    the two halves of one pass are held against each other rather than each
    being believed on its own.
    """
    text = stdout.strip()
    if not text:
        raise PassFailure("The mission scheduler pass produced no report document.")
    try:
        document = json.loads(text)
    except json.JSONDecodeError as exc:
        raise PassFailure(
            f"The mission scheduler pass produced no readable report document: {exc}"
        ) from exc
    if not isinstance(document, dict):
        raise PassFailure(
            f"The mission scheduler report is not a JSON object: {type(document).__name__}."
        )
    if document.get("schema") != PASS_SCHEMA:
        raise PassFailure(
            f"The mission scheduler report has unknown schema {document.get('schema')!r}; "
            f"this controller reads {PASS_SCHEMA!r} only."
        )
    version = document.get("version")
    if not pinned_version(version, PASS_VERSION):
        raise PassFailure(
            f"The mission scheduler report has unknown schema version {version!r}; this "
            f"controller reads version {PASS_VERSION} only."
        )
    keys = set(document)
    missing = sorted(PASS_FIELDS - keys)
    unexpected = sorted(keys - PASS_FIELDS)
    if missing or unexpected:
        detail = "; ".join(
            part
            for part in (
                f"missing {', '.join(missing)}" if missing else "",
                f"unexpected {', '.join(unexpected)}" if unexpected else "",
            )
            if part
        )
        raise PassFailure(f"The mission scheduler report has the wrong fields: {detail}.")
    repository = document["repository"]
    if not isinstance(repository, str) or not repository.strip():
        raise PassFailure(
            f"The mission scheduler report names no repository: {repository!r}."
        )
    termination = _require_vocabulary(
        document["termination"],
        PASS_TERMINATIONS,
        "The mission scheduler report's termination",
    )
    expected_exit = PASS_EXIT_CODES[termination]
    # `is_plain_integer` rather than `==`, because `True == 1` and `False == 0`:
    # a report carrying a Boolean where its exit status belongs would otherwise
    # agree with two of the three terminations and be believed.
    if not is_plain_integer(document["exit_code"]) or document["exit_code"] != expected_exit:
        raise PassFailure(
            f"The mission scheduler report says it terminated {termination!r} and "
            f"names exit status {document['exit_code']!r}, not {expected_exit}."
        )
    if returncode != expected_exit:
        raise PassFailure(
            f"The mission scheduler report says it terminated {termination!r}, which "
            f"exits {expected_exit}, but the pass exited with status {returncode}."
        )
    _require_admitted(document["admitted"], termination)
    _require_attention(document["attention"], termination, repository)
    if termination == PASS_REFUSED:
        _require_refused_observed_nothing(document["attention"])
    detail = document["detail"]
    if not isinstance(detail, str):
        raise PassFailure(f"The mission scheduler report carries no detail: {detail!r}.")
    for field in ("started_at", "finished_at"):
        _require_timestamp(document[field], f"The mission scheduler report's {field}")
    return document


def _require_mission_identifier(value: Any, what: str) -> str:
    """One mission identifier, held to what a mission store can address."""
    if not isinstance(value, str) or not value.strip():
        raise PassFailure(f"{what} names no mission: {value!r}.")
    if value in PASS_RESERVED_MISSION_NAMES or any(
        character in PASS_UNSAFE_MISSION_CHARACTERS for character in value
    ):
        raise PassFailure(
            f"{what} is not a single plain mission identifier: {value!r}."
        )
    return value


def _require_vocabulary(value: Any, allowed: frozenset[str], what: str) -> str:
    """One value from a closed vocabulary, type-checked before it is looked up.

    `value in frozenset` is not a safe question to ask of a document another
    process wrote: a JSON array or object is unhashable, so the membership test
    raises `TypeError` rather than answering. That escapes `PassFailure` and is
    recorded as an unexpected controller failure — the service stops with a
    traceback about a set lookup instead of the sentence saying the report was
    malformed.
    """
    if not isinstance(value, str):
        raise PassFailure(f"{what} is not text: {value!r}.")
    if value not in allowed:
        raise PassFailure(f"{what} is not one of {sorted(allowed)}: {value!r}.")
    return value


def _require_timestamp(value: Any, what: str) -> None:
    """One instant, in the only form the scheduler can write it.

    Structure and then range: `2026-13-45T99:99:99Z` matches the shape and is
    not a time, and a reader that accepted it would persist it into the status
    document a dashboard renders.
    """
    if not isinstance(value, str):
        raise PassFailure(f"{what} is not text: {value!r}.")
    match = PASS_TIMESTAMP_RE.fullmatch(value)
    if match is None:
        raise PassFailure(
            f"{what} is not an ISO-8601 UTC instant: {value!r}."
        )
    year, month, day, hour, minute, second = (int(part) for part in match.groups())
    try:
        datetime.datetime(year, month, day, hour, minute, second)
    except ValueError as exc:
        raise PassFailure(f"{what} names no real instant: {value!r} ({exc}).") from exc


def _require_admitted(admitted: Any, termination: str) -> None:
    if not isinstance(admitted, list):
        raise PassFailure(
            f"The mission scheduler report's admitted missions are not a list: "
            f"{type(admitted).__name__}."
        )
    # The ceiling is a contract about what a pass may do, not merely about what
    # it happens to do, so it is checked here rather than assumed: a report
    # naming more missions than one pass may admit describes a scheduler this
    # controller was not built to supervise, and publishing it as healthy would
    # hide exactly that.
    if len(admitted) > PASS_ADMISSION_CEILING:
        raise PassFailure(
            f"The mission scheduler report names {len(admitted)} admitted missions; "
            f"one pass admits at most {PASS_ADMISSION_CEILING}."
        )
    failing = False
    for entry in admitted:
        if not isinstance(entry, dict):
            raise PassFailure(
                f"A mission scheduler report's admitted entry is not an object: "
                f"{type(entry).__name__}."
            )
        keys = set(entry)
        if keys != PASS_ADMITTED_FIELDS:
            raise PassFailure(
                "A mission scheduler report's admitted entry has the wrong fields: "
                f"{sorted(keys)}."
            )
        _require_mission_identifier(
            entry["mission"], "A mission scheduler report's admitted entry"
        )
        disposition = _require_vocabulary(
            entry["disposition"],
            PASS_DISPOSITIONS,
            "A mission scheduler report's disposition",
        )
        if not isinstance(entry["detail"], str):
            raise PassFailure(
                f"A mission scheduler report's admitted entry carries no detail: "
                f"{entry['detail']!r}."
            )
        failing = failing or disposition in PASS_FAILING_DISPOSITIONS
    # One child per admitted mission, so one disposition per admitted mission.
    # A report naming a mission twice carries two answers to one question, and
    # nothing downstream could say which of them describes the mission's state.
    missions = [entry["mission"] for entry in admitted]
    if len(set(missions)) != len(missions):
        raise PassFailure(
            f"The mission scheduler report admits a mission more than once: "
            f"{sorted(missions)}."
        )
    # The two halves of one report held against each other. A pass that
    # reported a failed mission and called itself completed is telling a
    # supervisor two different things, and believing the cheerful half is how a
    # broken mission goes unnoticed.
    #
    # The converse is NOT a contradiction, and asserting it was a bug: a pass
    # fails for reasons that belong to the pass rather than to any one mission
    # — a scratch directory it could not prepare, a snapshot it could not read
    # — and the scheduler emits exactly that shape, `failed` with nothing
    # admitted. A controller that refused it would call its own writer
    # malformed and drop the one report that said what went wrong.
    if failing and termination != PASS_FAILED:
        raise PassFailure(
            f"The mission scheduler report terminated {termination!r} while naming a "
            "failed mission."
        )
    if termination == PASS_REFUSED and admitted:
        raise PassFailure(
            "The mission scheduler report terminated 'refused' while naming admitted "
            "missions."
        )


def _require_refused_observed_nothing(attention: Any) -> None:
    """A refused pass looked at nothing, so it can have seen nothing.

    The refusal happens before the inventory is read and before any attention
    is observed, and returns with both lists empty. A refused report naming
    attention is therefore describing a pass that cannot have happened — and it
    would be retained as `last_pass` and rendered as this repository's waiting
    state before the incident that follows ever says otherwise.
    """
    if attention:
        raise PassFailure(
            "The mission scheduler report terminated 'refused' while naming attention; "
            "a refused pass observes nothing."
        )


def _require_attention(attention: Any, termination: str, repository: str) -> None:
    if not isinstance(attention, list):
        raise PassFailure(
            f"The mission scheduler report's attention is not a list: "
            f"{type(attention).__name__}."
        )
    for entry in attention:
        if not isinstance(entry, dict):
            raise PassFailure(
                f"A mission scheduler report's attention entry is not an object: "
                f"{type(entry).__name__}."
            )
        keys = set(entry)
        if keys != PASS_ATTENTION_FIELDS:
            raise PassFailure(
                "A mission scheduler report's attention entry has the wrong fields: "
                f"{sorted(keys)}."
            )
        _require_mission_identifier(
            entry["mission"], "A mission scheduler report's attention entry"
        )
        if not isinstance(entry["attention_id"], str) or not entry["attention_id"].strip():
            raise PassFailure(
                f"A mission scheduler report's attention entry names no attention_id: "
                f"{entry['attention_id']!r}."
            )
        state = _require_vocabulary(
            entry["notification"],
            PASS_NOTIFICATION_STATES,
            "A mission scheduler report's notification state",
        )
        _require_targets(entry["targets"])
        if entry["detail"] is not None and not isinstance(entry["detail"], str):
            raise PassFailure(
                f"A mission scheduler report's attention detail is neither absent nor "
                f"text: {entry['detail']!r}."
            )
        # The writer reaches `unresolved` only when a mission's own
        # specification could not be read, which it treats as indeterminate
        # state and terminates `failed` for. A report that carries one and
        # calls itself completed is contradicting itself, and believing the
        # cheerful half publishes a healthy waiting state over a mission
        # nobody can account for.
        if state == PASS_UNRESOLVED_NOTIFICATION:
            if termination != PASS_FAILED:
                raise PassFailure(
                    f"The mission scheduler report terminated {termination!r} while naming "
                    "attention whose targets it could not resolve."
                )
            # `unresolved` means the mission's own specification could not be
            # read, so there was nothing to resolve targets *from*. A report
            # that names some anyway is describing a resolution that cannot
            # have happened, and those targets would be persisted into the
            # status document a dashboard renders.
            if entry["targets"]:
                raise PassFailure(
                    "The mission scheduler report names attention it could not resolve "
                    f"and gives it targets anyway: {entry['targets']!r}."
                )
            # And it always says why, because that reason is the only account
            # of what went wrong with the record.
            if not isinstance(entry["detail"], str) or not entry["detail"].strip():
                raise PassFailure(
                    "The mission scheduler report names attention it could not resolve "
                    "and gives no reason."
                )
        # The identity is repository-qualified by construction:
        # `Kanban.Mission.Types.missionAttentionIdentity` spells it
        # `<owner>/<name>#<mission>@<raised-at>`. An entry whose identity is
        # qualified for another repository or another mission is an episode
        # belonging to something else, and delivery is suppressed per identity
        # for ever — so accepting one would let a foreign episode consume an
        # attempt and be published as this repository's waiting state.
        expected_prefix = f"{repository}#{entry['mission']}@"
        if not entry["attention_id"].startswith(expected_prefix):
            raise PassFailure(
                f"The mission scheduler report names attention "
                f"{entry['attention_id']!r}, which is not qualified for "
                f"{expected_prefix!r}."
            )
        # The tail is the moment the episode began, and it is what makes two
        # visits to `waiting_input` two episodes rather than one. An empty or
        # malformed tail is an identity that cannot distinguish them, and
        # delivery is suppressed per identity for ever.
        _require_timestamp(
            entry["attention_id"][len(expected_prefix) :],
            f"The mission scheduler report's attention {entry['attention_id']!r} raised-at",
        )
    # One outstanding episode per mission: a mission is waiting for one thing
    # at a time, and two entries naming one identity would be counted twice by
    # anything that reads the status document.
    identities = [entry["attention_id"] for entry in attention]
    if len(set(identities)) != len(identities):
        raise PassFailure(
            f"The mission scheduler report names an attention episode more than "
            f"once: {sorted(identities)}."
        )
    missions = [entry["mission"] for entry in attention]
    if len(set(missions)) != len(missions):
        raise PassFailure(
            f"The mission scheduler report names attention for a mission more than "
            f"once: {sorted(missions)}."
        )


def _require_targets(targets: Any) -> None:
    """The typed items an attention entry is about, however many.

    Checked to the same depth as everything else this controller reads, because
    this is the part a reader is most tempted to pass straight through: it is
    reproduced in the status document a dashboard will render, so a `kind` that
    is not one of the two, or a `number` that is a string, a Boolean, or
    negative, would travel from a malformed report into a durable document
    describing a repository's state.
    """
    if not isinstance(targets, list):
        raise PassFailure(
            f"A mission scheduler report's attention targets are not a list: "
            f"{type(targets).__name__}."
        )
    for target in targets:
        _require_target(target)


def _require_target(target: Any) -> None:
    if not isinstance(target, dict):
        raise PassFailure(
            f"A mission scheduler report's attention target is not an object: "
            f"{type(target).__name__}."
        )
    keys = set(target)
    if keys != PASS_TARGET_FIELDS:
        raise PassFailure(
            f"A mission scheduler report's attention target has the wrong fields: "
            f"{sorted(keys)}."
        )
    _require_vocabulary(
        target["kind"],
        PASS_TARGET_KINDS,
        "A mission scheduler report's attention target kind",
    )
    if not is_plain_integer(target["number"]) or target["number"] <= 0:
        raise PassFailure(
            f"A mission scheduler report's attention target names no positive number: "
            f"{target['number']!r}."
        )


def pass_advanced(document: dict[str, Any]) -> bool:
    """Whether this pass moved any mission.

    Not "did it admit anything": admission is what the scheduler *tried*, and a
    mission whose advancement lease was taken by somebody else between
    selection and launch is admitted and then declines. A run that read
    admission as progress would poll flat out for as long as another process
    held that lease.
    """
    return any(
        entry["disposition"] in PASS_PROGRESS_DISPOSITIONS
        for entry in document["admitted"]
    )


def pass_state(document: dict[str, Any]) -> str:
    """The status state one accepted report leaves behind.

    `waiting` wins over `idle`, because a repository with a mission waiting on
    a person is not quiet -- it is stuck, and that is the state an operator
    needs to see. A pass that *moved* something leaves `running`: the next pass
    starts immediately, so the service is advancing work rather than sitting
    between polls. A pass that admitted a mission and was refused its lease
    moved nothing, and reads `idle` like any other quiet pass -- which is the
    honest answer, because whatever is holding that lease is the thing making
    progress.
    """
    if document["attention"]:
        return STATE_WAITING
    if pass_advanced(document):
        return STATE_RUNNING
    return STATE_IDLE


# ---------------------------------------------------------------------------
# The controller
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class PassCommand:
    """What one scheduler invocation produced: its argument vector, both
    captured streams, and its exit status."""

    argv: list[str]
    stdout: str
    stderr: str
    returncode: int


class Controller:
    """One `run`: repeated bounded scheduler passes and the durable trace of
    them.

    Strictly sequential. One pass is started, waited for, and classified before
    the next is considered, so two passes can never overlap and no mission can
    be admitted by two of them at once.
    """

    def __init__(
        self,
        job: MissionRunnerJob,
        *,
        kanban: Path,
        interval: float,
        passes: int | None = None,
    ) -> None:
        self.job = job
        self.kanban = kanban
        self.interval = interval
        # How many passes this run performs before stopping on its own. `None`
        # is the service: it runs until it is stopped. A finite count is what a
        # fixture asks for, and what an operator uses to make one pass happen.
        self.remaining = passes
        self.started_at = utc_stamp()
        # Recorded once, from this process, so a reader can tell this runner
        # from whatever later inherits its identifier. `None` on a host that
        # will not answer, which a reader treats as unconfirmable rather than
        # as a match.
        self.runner_identity = process_start_identity(os.getpid())
        # The startup token the definition this run was launched from carried,
        # if it was launched from one at all. Read from the environment rather
        # than passed in, because the only thing that can supply it is the
        # service manager executing the definition a `start` wrote; a
        # foreground run has none, which is exactly what makes the two
        # distinguishable. Never written anywhere but the status document.
        self.startup_nonce = os.environ.get(STARTUP_NONCE_ENV) or None
        self._child: subprocess.Popen[str] | None = None
        self._stop_requested = False
        self._signals = 0
        self._passes = 0
        self._last_pass: dict[str, Any] | None = None

    # -- lifecycle ---------------------------------------------------------

    def log(self, message: str) -> None:
        service_log(self.job, message)

    def handle_stop(self, _signum: int, _frame: Any) -> None:
        """Record the stop and pass it straight to the pass's process group.

        Forwarded to the group rather than to the child alone: the scheduler
        spawns a `kanban --mission` child per admitted mission, and signalling
        only the process this controller knows about is what leaves those
        orphaned (requirement 11). A second signal escalates, so an operator
        who asks twice is obeyed twice.
        """
        self._stop_requested = True
        self._signals += 1
        forwarded = signal.SIGTERM if self._signals == 1 else signal.SIGKILL
        self.signal_child_group(self._child, forwarded)

    def signal_child_group(
        self, child: subprocess.Popen[str] | None, forwarded: int
    ) -> None:
        """Signal one pass's whole session, or nothing.

        A group whose last member is already gone raises ProcessLookupError,
        which is the ordinary case rather than a failure. Signalling a child
        this controller has already reaped is refused outright, since its PID
        may by then name something else entirely.
        """
        if child is None or child.poll() is not None:
            return
        with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
            os.killpg(child.pid, forwarded)

    def terminate_process_group(self, child: subprocess.Popen[str]) -> None:
        """Leave nothing of this pass's session behind.

        The child has been waited for by every caller, so this is about what it
        left: the scheduler spawns mission children, and one still running in
        that session outlives the stop requirement 11 promises will leave none.

        Signalling a group whose last member is already gone raises
        ProcessLookupError, which is the ordinary case rather than a failure.
        """
        with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
            os.killpg(child.pid, signal.SIGKILL)

    def sleep(self, seconds: float) -> None:
        """Wait, but never past a stop.

        Built from slices because a handler that does not raise leaves
        `time.sleep` to resume the remainder (PEP 475), which would make an
        intentional stop wait out a whole poll interval before being noticed.
        """
        deadline = time.monotonic() + max(0.0, seconds)
        while not self._stop_requested:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            time.sleep(min(SLEEP_SLICE_SECONDS, remaining))

    def run(self) -> int:
        previous = [
            (number, signal.signal(number, self.handle_stop))
            for number in (signal.SIGTERM, signal.SIGINT)
        ]
        try:
            return self._run()
        finally:
            for number, handler in previous:
                with contextlib.suppress(ValueError, OSError, TypeError):
                    signal.signal(number, handler)

    def _run(self) -> int:
        ensure_dirs(self.job)
        self.log(
            f"Starting the mission runner for {self.job.identity} from "
            f"{self.job.repo_path} using {self.kanban}"
        )
        self.write_status(STATE_RUNNING, message="Starting a mission scheduler pass.")
        try:
            while not self._stop_requested and self.passes_remain():
                self.one_pass()
        except PassFailure as failure:
            return self.record_failure(PASS_INCIDENT_KIND, failure.summary, failure.detail)
        except ServiceError as failure:
            return self.record_failure(CONTROLLER_INCIDENT_KIND, str(failure), None)
        except Exception:
            return self.record_failure(
                CONTROLLER_INCIDENT_KIND,
                "The mission runner failed unexpectedly.",
                traceback.format_exc(),
            )
        self.log("The mission runner stopped intentionally.")
        self.write_status(STATE_STOPPED, message="Stopped intentionally.")
        return 0

    def passes_remain(self) -> bool:
        return self.remaining is None or self._passes < self.remaining

    def record_failure(self, kind: str, summary: str, detail: str | None) -> int:
        self.log(f"The mission runner stopped: {summary}")
        try:
            incident = record_incident(self.job, kind=kind, summary=summary, detail=detail)
            self.log(f"Recorded incident {incident['incident_id']} at {incident['path']}")
        except OSError as exc:
            self.log(f"Additionally failed to record the incident: {exc}")
        self.write_status(STATE_FAILED, message=summary)
        return 1

    # -- durable state -----------------------------------------------------

    def write_status(
        self, state: str, *, message: str, pass_pid: int | None = None
    ) -> None:
        atomic_write_json(
            self.job.status_path,
            {
                "schema": STATUS_SCHEMA,
                "version": STATUS_VERSION,
                "state": state,
                # The token the definition this run was launched from carried,
                # or null for a foreground run launched from nothing. It is
                # what lets the `start` that wrote that definition tell this
                # run's status from one another process published in the same
                # window; no reader of the service's state consults it.
                "startup_nonce": self.startup_nonce,
                "repository": self.job.identity,
                "repo": str(self.job.repo_path),
                # The ownership a reader needs to reject a stale observation: a
                # live state recorded under a runner that is gone is not a
                # running service.
                "runner_pid": os.getpid(),
                "runner_identity": self.runner_identity,
                "pass_pid": pass_pid,
                "message": message,
                "last_pass": self._last_pass,
                "passes": self._passes,
                "attention": (self._last_pass or {}).get("attention", []),
                "started_at": self.started_at,
                "updated_at": utc_stamp(),
                "kanban": str(self.kanban),
            },
        )

    # -- passes ------------------------------------------------------------

    def pass_argv(self) -> list[str]:
        argv = [
            str(self.kanban),
            SCHEDULER_FLAG,
            # The repository as Kanban spells it, not this service's folded
            # partition key: a mission store path is built from this value
            # segment by segment and its records are compared by equality.
            "--repo",
            self.job.spelling,
        ]
        if self.job.config_path:
            argv.extend(["--config", self.job.config_path])
        return argv

    def start_child(self, argv: list[str]) -> subprocess.Popen[str] | None:
        """Spawn one scheduler pass, or nothing at all when a stop is already
        pending.

        A stop must never leave a live pass — mission children, model calls and
        GitHub mutations and all — running behind a controller that has already
        recorded an intentional stop. Two reads of the flag around the spawn are
        what guarantee that, and between them they leave no window:

        * the read before the spawn means an already-requested stop starts
          nothing at all;
        * a stop arriving from there until the child is registered finds
          `_child` unset, so the handler signals nothing -- and the read after
          the registration sees the flag and signals the group itself;
        * a stop arriving after that read finds `_child` set, so the handler
          signals the group.

        Nothing is masked to achieve that, deliberately. A signal mask held
        across `Popen` is inherited by the child and survives its `exec`, which
        would leave every pass running with the very signals its process group
        is stopped with blocked.

        `start_new_session` is what makes any of this able to end the whole tree
        rather than the one process this controller can see: the scheduler
        keeps its mission children in its own process group precisely so a
        signal to that session reaches them.

        The working directory is the checkout, and the repository identity
        travels as `--repo`, so the pass acts on the repository this runtime
        describes rather than re-deriving one.

        The environment is inherited whole rather than replaced. A service
        manager may hand this controller an otherwise empty environment, and
        `$XDG_DATA_HOME` and `$XDG_STATE_HOME` are exactly what decide where
        the mission store and this runtime live — so whatever this process
        resolved them to has to reach the pass unchanged, or the pass would
        advance missions in a store the status document does not describe.
        """
        if self._stop_requested:
            self.log("A stop arrived before this pass began; nothing was started.")
            return None
        child = subprocess.Popen(
            argv,
            cwd=str(self.job.repo_path),
            text=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            # Registered before the flag is read again, so the two reads
            # overlap rather than leaving a gap between them.
            self._child = child
            if self._stop_requested:
                self.log("A stop raced this pass's start; signalling the pass it spawned.")
                self.signal_child_group(child, signal.SIGTERM)
        except BaseException:
            self._child = None
            self.abandon_child(child)
            raise
        return child

    def abandon_child(self, child: subprocess.Popen[str]) -> None:
        """End a pass nothing will be left to supervise.

        Reached when a step after the spawn fails. The run is about to record a
        failure and release the per-identity run lock, and a pass still alive
        past that point keeps advancing missions with nothing watching it — and
        can then be overlapped by the very next controller the released lock
        admits, which is the one thing that lock exists to prevent.
        """
        self.signal_child_group(child, signal.SIGTERM)
        try:
            child.wait(timeout=STOP_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            self.terminate_process_group(child)
            with contextlib.suppress(subprocess.TimeoutExpired):
                child.wait(timeout=STOP_GRACE_SECONDS)
        self.terminate_process_group(child)

    def spawn(self) -> PassCommand | None:
        """One scheduler invocation and what it produced, or None when a
        pending stop meant none was started.

        Both streams are captured rather than inherited: stdout carries the one
        report document this controller parses, and stderr carries the pass's
        own narration, which belongs in an incident when the pass fails rather
        than interleaved with this controller's.
        """
        argv = self.pass_argv()
        child = self.start_child(argv)
        if child is None:
            return None
        try:
            self.write_status(
                STATE_RUNNING,
                message="A mission scheduler pass is running.",
                pass_pid=child.pid,
            )
            stdout, stderr = self.wait_for(child)
        except BaseException:
            # Every exceptional exit from here, not only an intentional stop: a
            # status write that fails and a wait that raises both end this run,
            # and neither may leave the pass running behind it.
            self._child = None
            self.abandon_child(child)
            raise
        finally:
            self._child = None
            # Unconditionally, not only on a stop. Reading the flag here would
            # be one more window: a stop landing after that read finds no
            # registered child to signal and no later sweep, so a scheduler
            # that exited leaving a mission child in its session would outlive
            # the intentional stop that follows.
            self.terminate_process_group(child)
        return PassCommand(argv, stdout or "", stderr or "", child.returncode)

    def wait_for(self, child: subprocess.Popen[str]) -> tuple[str, str]:
        """Collect the pass's output, escalating a stop it does not obey.

        Waited for in bounded slices rather than in one unbounded call, because
        a signal handler that does not raise leaves the wait to resume (PEP
        475): once a stop has been requested, this needs to come back and decide
        whether the group is taking too long. Retrying `communicate` after a
        timeout is the documented way to do that and loses no output.

        The escalation is what makes requirement 11 keepable against a mission
        child that ignores SIGTERM: the handler asks the group politely, and a
        group that has not gone in `STOP_GRACE_SECONDS` is killed outright.
        """
        deadline: float | None = None
        while True:
            try:
                return child.communicate(timeout=SLEEP_SLICE_SECONDS * 20)
            except subprocess.TimeoutExpired:
                if not self._stop_requested:
                    continue
                if deadline is None:
                    deadline = time.monotonic() + STOP_GRACE_SECONDS
                elif time.monotonic() >= deadline:
                    self.log(
                        f"The mission scheduler pass did not stop within "
                        f"{STOP_GRACE_SECONDS:g}s; killing its process group."
                    )
                    self.terminate_process_group(child)
                    deadline = time.monotonic() + STOP_GRACE_SECONDS

    def one_pass(self) -> None:
        command = self.spawn()
        if command is None:
            return
        try:
            document = parse_pass_report(command.stdout, command.returncode)
        except PassFailure as failure:
            # A pass this controller signalled decided nothing, so treating
            # what it managed to write as a failure would record an intentional
            # stop as one. Emptiness is not the test: a report is written in
            # one `write`, but the pipe need not carry it in one piece, and its
            # attention list is unbounded — so a stop can land after a nonempty
            # prefix and leave exactly this, output that parses as nothing.
            #
            # A pass that *completed* is never suppressed, which is why this
            # sits after the parse rather than before it: a whole, valid report
            # is acted on however the run ended, because work that really
            # happened must not be reported as work that did not.
            if self._stop_requested:
                self.log(
                    "A pass was interrupted by the stop and left no readable result; "
                    "recording no verdict for it."
                )
                return
            raise PassFailure(failure.summary, failure.detail or tail(command.stderr)) from failure
        # Compared against the spelling the pass was handed, not this service's
        # folded partition key: the scheduler reports the repository it
        # resolved, and for a mixed-case remote those differ.
        if document["repository"] == PASS_UNRESOLVED_REPOSITORY:
            raise PassFailure(
                "The mission scheduler could not establish which repository it was "
                f"run for: {document['detail']}",
                tail(command.stderr),
            )
        if document["repository"] != self.job.spelling:
            raise PassFailure(
                f"The mission scheduler report describes {document['repository']!r}, "
                f"not {self.job.spelling!r}.",
                tail(command.stderr),
            )
        self._passes += 1
        self._last_pass = {
            "termination": document["termination"],
            "detail": document["detail"],
            "admitted": document["admitted"],
            "attention": document["attention"],
            "finished_at": document["finished_at"],
        }
        if document["termination"] == PASS_REFUSED:
            raise PassFailure(
                f"The mission scheduler refused to run a pass: {document['detail']}",
                tail(command.stderr),
            )
        if document["termination"] == PASS_FAILED:
            raise PassFailure(
                f"A mission scheduler pass failed: {document['detail']}",
                tail(command.stderr),
            )
        state = pass_state(document)
        self.write_status(state, message=document["detail"])
        self.log(f"Pass {self._passes}: {document['detail']}")
        if not self.passes_remain():
            return
        self.sleep(ADVANCE_DELAY_SECONDS if pass_advanced(document) else self.interval)


# ---------------------------------------------------------------------------
# Transition locks
# ---------------------------------------------------------------------------


# Which transition locks this *thread* already holds, and how deeply. Held per
# thread rather than per process on purpose: a nested acquire by one thread is
# the same transition reached through a public entry point that must also work
# when reached directly, while two threads are two transitions and have to
# contend exactly as two processes do.
_HELD_LOCKS = threading.local()


def _held_depths() -> dict[str, int]:
    depths = getattr(_HELD_LOCKS, "depths", None)
    if depths is None:
        depths = {}
        _HELD_LOCKS.depths = depths
    return depths


@contextlib.contextmanager
def held_blocking(path: Path) -> Iterator[None]:
    """Hold one exclusive lock, waiting for whoever already has it.

    Blocking rather than refusing, unlike the run lock: these are held only for
    the length of one transition, so a caller that finds one taken has not lost
    a race to a service that is already running — it has arrived while the
    previous transition is still finishing, and waiting is what makes the two
    orderly instead of interleaved. The kernel releases the lock if its holder
    dies, so a wedged transition cannot strand the next one forever.

    Re-entrant within one thread, because every operation here is both a step
    of a larger one and an entry point of its own: an installer holding an
    installation's lock calls the controller operation that takes the same
    lock, and a start refreshes an install inside the lock it already took.
    Without re-entrancy each of those would wait on itself.
    """
    key = str(path)
    depths = _held_depths()
    if depths.get(key):
        depths[key] += 1
        try:
            yield
        finally:
            depths[key] -= 1
        return
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError as exc:
        raise ServiceError(f"Refusing unsafe lock path: {path}") from exc
    depths[key] = 1
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        depths.pop(key, None)
        os.close(descriptor)


def transition_lock(job: MissionRunnerJob) -> Any:
    """Serialize this identity's install, start, stop, and uninstall.

    Every one of those reads what the manager and the runtime currently say and
    then acts on the answer, so two running concurrently can each act on a
    state the other has already left.
    """
    return held_blocking(transition_lock_path(job.slug))


def installation_lock(install_dir: Path) -> Any:
    """Serialize whatever touches one installation's shared links.

    Held by the installer around installing or removing links together with the
    record entry that says who depends on them, and by every job transition
    that writes such an entry, so the set of repositories running from a
    directory cannot change between an uninstall reading it and acting on it.

    Always taken *before* `transition_lock`, never after, so the two can never
    deadlock: every caller that holds both acquires them in that one order.
    """
    return held_blocking(installation_lock_path(install_dir))


@contextlib.contextmanager
def job_transition(job: MissionRunnerJob, install_dir: Path) -> Iterator[None]:
    """Both locks a transition that writes a record entry must hold, in the one
    order every caller takes them."""
    with installation_lock(install_dir):
        with transition_lock(job):
            yield


@contextlib.contextmanager
def exclusive_of_runs(job: MissionRunnerJob, action: str) -> Iterator[None]:
    """Hold this identity's run lock for the length of a destructive step.

    The check-then-act window no ordering of read-only checks can close: a
    foreground `run` takes this lock as the very first thing it does, so a
    transition that only *asked* about it could always be overtaken between the
    asking and the acting, and would then remove a job, its record entry, and
    its links out from under a controller that had just come into existence.

    Taking the same lock makes the two mutually exclusive rather than merely
    ordered. Whoever gets it wins: a run beginning inside an uninstall is
    refused with the uninstall named, and an uninstall beginning inside a run
    is refused with the run named.

    Non-blocking, unlike the transition locks, because a run is not a step that
    finishes on its own — waiting for one would be waiting for an operator.

    Deliberately not held across a `start`'s kick and wait: the run being
    started needs this very lock to establish itself, so a start that held it
    would be waiting for something it was itself preventing.

    Re-entrant within one thread, for the reason `held_blocking` is:
    `tools/install_mission_runner.py` holds this exclusion across the whole of a
    transition — the shared links as well as the job — and calls the controller
    operations that take it again as steps of that transition. `flock` is held
    per open file description rather than per process, so without this the inner
    acquisition would be refused by the outer one's own hold. Two *threads* are
    two transitions and go on contending exactly as two processes do.
    """
    depths = _held_depths()
    key = str(job.lock_path)
    if depths.get(key):
        depths[key] += 1
        try:
            yield
        finally:
            depths[key] -= 1
        return
    with held_exclusively(
        job.lock_path,
        job,
        lambda owner: (
            f"A mission runner for {job.identity} is running{owner}. "
            f"Stop it before {action}."
        ),
        mode="transition",
    ):
        # Recorded so this thread's own advisory probes do not report the lock
        # back to it: `require_no_live_run` runs inside these sections too, and
        # a check that saw its own hold would refuse every transition.
        depths[key] = depths.get(key, 0) + 1
        try:
            yield
        finally:
            depths[key] -= 1


# ---------------------------------------------------------------------------
# The discovery record
# ---------------------------------------------------------------------------


@contextlib.contextmanager
def document_lock(path: Path) -> Iterator[None]:
    """Serialize read-modify-write on the shared discovery document.

    One document carries every installed repository's entry, and an install for
    one repository must never drop another's. Without this, two installs can
    both read the table and whichever writes last silently deletes the other's
    entry — leaving a repository whose job is loaded with no record for Kanban
    to find it through. The lock lives beside the document rather than on it,
    because the document is replaced atomically and a lock held on the old
    inode would guard nothing.
    """
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_path = path.with_name(path.name + ".lock")
    try:
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    except OSError as exc:
        raise ServiceError(f"Refusing unsafe discovery lock path: {lock_path}") from exc
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def update_json_document(
    path: Path, transform: Callable[[dict[str, Any]], dict[str, Any]]
) -> Path:
    """Replace the private JSON object at `path` with `transform` applied to
    it, reading and writing under one exclusive lock so a concurrent writer
    cannot lose either party's change.

    An occupant that is not a plain file — a directory, a symlink — is refused
    rather than replaced, and the refusal names the path, because a record this
    installer cannot safely write is a record it must not silently move
    somewhere else.
    """
    with document_lock(path):
        if os.path.lexists(path) and (path.is_symlink() or not path.is_file()):
            raise ServiceError(f"Refusing unsafe discovery record path: {path}")
        existing: dict[str, Any] = {}
        if path.is_file():
            loaded = _read_json_document(path)
            if isinstance(loaded, dict):
                existing = loaded
        updated = transform(existing)
        fd, temporary_name = tempfile.mkstemp(prefix=".config.", dir=path.parent)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(updated, handle, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            temporary.chmod(0o600)
            os.replace(temporary, path)
        finally:
            if os.path.lexists(temporary):
                temporary.unlink()
    return path


def merge_repository_record(
    identity: str,
    updates: dict[str, Any],
    *,
    discard: frozenset[str] | tuple[str, ...] = (),
    observed: Callable[[dict[str, Any]], None] | None = None,
) -> Path:
    """Merge `updates` into one repository's entry, leaving every sibling entry
    and every top-level key untouched.

    Two levels of merge, not one: replacing the value of each key given would
    hand over a `repositories` table built from `updates` alone, deleting every
    other installed repository. The entry itself is merged one level down for
    the same reason — the install performs the service-manager keys while
    `config_path` and `install_dir` outlive any one of them.

    `discard` is the exception a merge alone cannot express: keys the writer
    owns outright and must therefore replace rather than add to. Only the
    service-manager keys are ever discarded, and only by the writer about to
    restate them, so everything else in the entry survives. Without it,
    reinstalling a repository under the other service manager would leave the
    first manager's keys beside the second's — the mixed shape a reader is
    required to fail closed on, arrived at by reinstalling rather than by
    hand-editing.

    An unreadable or non-object document is rebuilt around this entry rather
    than refused, which is what makes reinstalling the repair for a damaged
    record; a *path* that cannot be safely written is still refused above.
    Sibling entries of a readable document always survive.

    `observed`, when given, is handed the entry exactly as this merge found it,
    inside that same lock. It is how a writer learns what it replaced without a
    separate read another writer could slip between — which is what tells an
    install whether it has just moved this repository out of some other
    installation, and is therefore answerable for the links it left there.
    """

    def merged(document: dict[str, Any]) -> dict[str, Any]:
        records = document.get(RECORD_REPOSITORIES_KEY)
        records = dict(records) if isinstance(records, dict) else {}
        existing = records.get(identity)
        entry = dict(existing) if isinstance(existing, dict) else {}
        if observed is not None:
            observed(dict(entry))
        entry = {key: value for key, value in entry.items() if key not in discard}
        entry.update(updates)
        records[identity] = entry
        return {**document, RECORD_REPOSITORIES_KEY: records}

    return update_json_document(discovery_record_path(), merged)


def remove_repository_record(identity: str) -> Path:
    """Drop one repository's entry, leaving every sibling entry and every
    top-level key exactly as they are — the same two-level discipline in the
    other direction, under the same lock."""

    def without(document: dict[str, Any]) -> dict[str, Any]:
        records = document.get(RECORD_REPOSITORIES_KEY)
        if not isinstance(records, dict) or identity not in records:
            return document
        remaining = {key: value for key, value in records.items() if key != identity}
        return {**document, RECORD_REPOSITORIES_KEY: remaining}

    return update_json_document(discovery_record_path(), without)


def installed_repository_records() -> dict[str, dict[str, Any]]:
    """Every installed repository's record, keyed by normalized identity.

    Read without the lock: a reader that observes the document either before or
    after a writer's atomic replacement observes a complete document either
    way, and holding the lock to read would let a status poll block an install.
    """
    document = _read_json_document(discovery_record_path())
    if not isinstance(document, dict):
        return {}
    records = document.get(RECORD_REPOSITORIES_KEY)
    if not isinstance(records, dict):
        return {}
    return {
        identity: record
        for identity, record in records.items()
        if isinstance(identity, str) and isinstance(record, dict)
    }


def installed_jobs_are_knowable() -> bool:
    """Whether the set of installed jobs can be read off the discovery record.

    Not the same question as "is this repository installed?", which
    `installed_repository_records` answers by reporting an unreadable or absent
    document as no repositories. That is the right answer for a reader and a
    dangerous one for a writer deciding whether shared script links may go: the
    links are what *every* job installed into a directory runs from, and a
    record that cannot be read may name all of them.

    Absence is unknown for the same reason an undecodable document is, and not
    for a weaker one. A record can be deleted while every job it named is still
    loaded in the service manager, and nothing here can enumerate a manager's
    jobs to find out — that boundary is deliberately total and has no verb for
    it. An empty `repositories` table is different: something wrote it, and what
    it says is that nothing is installed.

    So a caller that cannot account for a directory's dependants keeps its
    links. Keeping a link nothing needs is recoverable by a later uninstall;
    removing one a live job runs from is not.
    """
    path = discovery_record_path()
    if not os.path.lexists(path):
        return False
    document = _read_json_document(path)
    if not isinstance(document, dict):
        return False
    records = document.get(RECORD_REPOSITORIES_KEY)
    return records is None or isinstance(records, dict)


def installed_repository_record(identity: str) -> dict[str, Any]:
    return installed_repository_records().get(identity, {})


def _recorded_string(identity: str, key: str) -> str | None:
    value = installed_repository_record(identity).get(key)
    return value if isinstance(value, str) and value else None


def installed_install_dir(identity: str) -> str | None:
    """Where this repository's job was installed from, as recorded.

    A later process that inherits no environment — Kanban, or a second
    installer run — rediscovers a custom `--install-dir` by reading it rather
    than by being told.
    """
    return _recorded_string(identity, "install_dir")


def installed_config_path(identity: str) -> str | None:
    """The kanban `config.toml` this repository's job was installed with.

    Read only out of that repository's own entry. A second repository's
    `--config` must never change what the first one's controller runs with,
    which is why there is no shared scalar to fall back to.
    """
    return _recorded_string(identity, "config_path")


def job_install_dir(job: MissionRunnerJob) -> Path:
    """Which installation this repository's job belongs to.

    The environment override first, so a controller launched out of a custom
    installation acts on that one. Then what this repository's own record says,
    which is how a reinstall or a start from a process holding no environment
    converges on the installation the job is already in rather than silently
    moving it to the default. The default last, for a repository that has never
    been installed.
    """
    override = install_dir_override()
    if override is not None:
        return override
    recorded = installed_install_dir(job.identity)
    if recorded:
        return Path(recorded)
    return default_install_dir()


# ---------------------------------------------------------------------------
# The managed job
# ---------------------------------------------------------------------------


def python_executable() -> str:
    """The interpreter an installed job runs under.

    This process's own, so the controller runs on the Python the service was
    installed with rather than on whatever `python3` a service manager's PATH
    resolves to. The documented spelling remains the fallback for an embedded
    interpreter that reports none.
    """
    return sys.executable or "python3"


def service_backend() -> service_manager.ServiceManagerBackend:
    """The service manager this host's mission runner jobs are managed by.

    Resolved for this service's own namespace, so every identifier derived
    through it belongs to `mission-runner` and none of them can name a
    drainer's or an approval service's job. Resolved per call rather than held,
    so a test may replace either this function or the selection under it.

    This is also where a host with no service manager is refused, which is the
    only platform question installation asks: `sys.platform` decides nothing,
    since a Linux host with a live user session installs here as a macOS host
    does. `run` and `status` deliberately never reach it — a foreground run and
    a read of what it left behind need no manager at all.
    """
    try:
        return service_manager.select_backend(
            run_command, service_manager.MISSION_RUNNER_NAMESPACE
        )
    except service_manager.NoServiceManagerError as exc:
        raise ServiceError(str(exc)) from exc


def service_label(job: MissionRunnerJob) -> str:
    """This repository's one job identifier, derived through the backend.

    A function of the identity alone, by way of the slug every runtime path is
    partitioned by, so the job, its runtime directory, and its logs can never
    name different repositories.
    """
    return service_backend().service_identifier(job.slug)


def service_definition(
    job: MissionRunnerJob, install_dir: Path, *, startup_nonce: str | None = None
) -> service_manager.ServiceDefinition:
    """What the service manager must run for this job.

    Every value here is this controller's own — which interpreter runs which
    installed script against which checkout, where its output goes, and what
    environment it needs — and none of it is any service manager's spelling of
    that. Rendering it into a definition on disk is the backend's work.
    """
    # Absolute, so the job runs on the interpreter this installation was made
    # with rather than on whatever `python3` a service manager's PATH resolves
    # to. A bare name — what an embedded interpreter reporting none falls back
    # to — is left for that PATH to resolve, because anchoring it to this
    # process's working directory would name nothing at all.
    interpreter = python_executable()
    python = (
        str(Path(interpreter).resolve()) if os.path.isabs(interpreter) else interpreter
    )
    environment = {
        "HOME": str(account_home()),
        "PATH": ":".join(
            [
                str(account_home() / ".local" / "bin"),
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
            ]
        ),
        "PYTHONUNBUFFERED": "1",
        INSTALL_DIR_ENV: str(install_dir),
    }
    # The rest of the context this installation's managed paths were resolved
    # under. INSTALL_DIR_ENV alone pins the install directory, but not the
    # discovery record, the runtime tree, or the log root: those follow the XDG
    # base directories, and a systemd user manager does not necessarily export
    # the ones the operator installed under. A job started without them would
    # resolve `~/.local` instead — writing a status document nothing reads, and
    # logs somewhere its own unit does not point. Carried only when absolute,
    # which is the same rule the resolvers themselves apply, so an unusable
    # value is left to fall back on both sides rather than pinned on one.
    environment.update(
        {
            name: os.environ[name]
            for name in PATH_VARIABLES
            if os.path.isabs(os.environ.get(name, ""))
        }
    )
    # And the configuration context the identity below was resolved through,
    # for the reason `shared_config_root` gives: the child re-resolves an
    # identity at launch and refuses to act when it disagrees with the `--repo`
    # this definition records, so a job that read a different configuration
    # would refuse itself and never start.
    environment[CONFIG_ROOT_VARIABLE] = shared_config_root()
    # Only ever set by a `start`, and different every time. It is what lets that
    # start tell the status document its own run published from one anybody else
    # wrote; an ordinary install writes a definition without it.
    if startup_nonce:
        environment[STARTUP_NONCE_ENV] = startup_nonce
    arguments = [
        python,
        str(controller_path(install_dir)),
        "run",
        "--path",
        str(job.repo_path),
        # The identity every path beside this job was derived from, recorded
        # here because the definition outlives the configuration it was written
        # from. Without it the runner would re-resolve the identity at launch,
        # and a `remote_name` changed after installation would silently point
        # this job at another repository's status, incidents, and logs.
        "--repo",
        job.identity,
    ]
    if job.config_path:
        # In the definition rather than only in the record: the definition is
        # what a service manager actually executes, and a job launched from a
        # cold manager inherits nothing else.
        arguments.extend(["--config", job.config_path])
    # `--interval`, `--passes` and `--kanban` are deliberately absent. The
    # definition carries what the job *is*; those three are the run's own
    # defaults, which a later release may change without every installed job
    # having to be rewritten first.
    return service_manager.ServiceDefinition(
        identifier=service_label(job),
        program_arguments=arguments,
        working_directory=str(job.repo_path),
        environment=environment,
        stdout_path=str(job.log_dir / "service.out"),
        stderr_path=str(job.log_dir / "service.err"),
    )


def same_checkout(left: str, right: str) -> bool:
    """Whether two recorded paths name one checkout.

    Compared after resolution rather than as strings: one directory has many
    spellings — a symlinked parent, a relative path, a trailing slash — and
    reporting the checkout that is running as a *different* one would refuse a
    transition nothing is actually conflicting with.
    """
    return os.path.realpath(left) == os.path.realpath(right)


def another_checkout_running(
    job: MissionRunnerJob, snapshot: dict[str, Any]
) -> str | None:
    """The other checkout of this same GitHub repository whose runner is
    already running, if there is one.

    The run lock cannot answer this from here: it is held by the running
    process, and this is a different process asking. The status document is
    what it left behind, and the checkout it recorded is the one thing that
    distinguishes two clones of one identity.
    """
    active_repo = snapshot.get("active_repo")
    if snapshot.get("state") not in LIVE_STATES:
        return None
    if not isinstance(active_repo, str) or same_checkout(
        active_repo, str(job.repo_path)
    ):
        return None
    return active_repo


def job_is_running(job: MissionRunnerJob) -> bool:
    """Whether the service manager holds a live process for this job.

    Asked of the manager rather than inferred from the status document, because
    that document is written by the run itself: one that has not written its
    first status yet, one whose write failed, and one that was damaged or
    removed all read as unknown while the process they describe keeps running
    passes. The document says what a run is *doing*; only the manager says
    whether there is one.
    """
    return service_backend().is_running(service_label(job))


def run_lock_owner(job: MissionRunnerJob) -> dict[str, Any] | None:
    """Whoever is inside a `run` for this identity, or None when nobody is.

    Read by trying the same non-blocking exclusive lock a run takes and
    dropping it immediately on success, so a check never becomes a hold; the
    losing path never truncates, so it cannot erase the owner's own metadata.

    This is the *earliest* signal that a run exists. `run_lock` is taken before
    the first status document is written and before any scheduler pass, so a
    run that has only just begun — or one whose announcement failed — is
    visible here and nowhere else. It is also the only signal that sees a
    foreground run, which no service manager started and therefore no manager
    can report.

    Answers None for a lock file that has never existed, without creating one,
    and None for one this thread is itself holding through `exclusive_of_runs`,
    since a transition asking whether a run exists must not be answered with
    its own exclusion of one.
    """
    path = run_lock_path(job.slug)
    if _held_depths().get(str(path)):
        return None
    if not os.path.lexists(path):
        return None
    try:
        handle = open(path, "a+", encoding="utf-8")
    except OSError as exc:
        raise ServiceError(f"Could not inspect the run lock at {path}: {exc}") from exc
    try:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return _read_lock_owner(handle)
        except OSError as exc:
            raise ServiceError(
                f"Could not inspect the run lock at {path}: {exc}"
            ) from exc
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        return None
    finally:
        handle.close()


def require_no_live_run(job: MissionRunnerJob, action: str) -> None:
    """Refuse `action` while a run of this identity is visible.

    Three questions, because no one of them sees every run: the manager cannot
    see a foreground run it never started, the status document cannot see a run
    that has not written one yet, and the run lock cannot see a process that
    took no lock.

    Advisory rather than authoritative. A run can still begin the instant after
    every one of these answers "no", which is why the transitions that act on
    them go on to *take* the run lock — see `exclusive_of_runs`. This is what a
    plan reports and what a dry run refuses on, so neither describes work that
    would then be refused.
    """
    owner = run_lock_owner(job)
    if owner is not None:
        raise ServiceError(
            f"A mission runner for {job.identity} is already "
            f"running{describe_run_owner(owner)}. Stop it before {action}."
        )
    if job_is_running(job):
        raise ServiceError(
            f"The {service_backend().backend_name()} manager still holds a live "
            f"process for {service_label(job)}. Stop it before {action}."
        )


def require_absolute_install_dir(install_dir: Path) -> None:
    """Refuse to plan a job around an install directory that is not absolute.

    The last line of the defence `install_dir_override` opens: every caller
    that reaches here resolves the directory through this module or through
    `--install-dir`, both of which produce an absolute path, but the argument
    itself is one anybody can pass. What it protects is the same thing — the
    definition names the installed controller and the record is read by
    processes with a working directory of their own, so a relative spelling
    would name a different installation to each of them.
    """
    if not install_dir.is_absolute():
        raise ServiceError(
            f"Refusing to install into {install_dir}, which is not an absolute "
            "directory: the service definition names the controller inside it, "
            "and the job a service manager launches resolves that name from the "
            "repository checkout rather than from here."
        )


def require_usable_record() -> None:
    """Refuse a transition whose discovery record cannot be written.

    Read-only and raised before anything is written, so an occupant this
    installer must not replace — a directory where the record belongs, a
    symlink pointing anywhere at all — leaves the installation exactly as it
    was rather than half made. `update_json_document` refuses the same thing at
    the moment of writing, which is the guard that cannot be raced; this one is
    what makes the refusal a *plan's* answer, so a dry run reports it and a real
    run has written no definition by the time it arrives.

    The refusal names the path, because the probe selected this location
    precisely *because* it is occupied and will never fall through to the
    lower-precedence one: an operator who is not told which of the two
    locations is in the way cannot clear it.
    """
    path = discovery_record_path()
    if os.path.lexists(path) and (path.is_symlink() or not path.is_file()):
        raise ServiceError(
            f"Refusing unsafe discovery record path: {path}. Whatever is there "
            "is left untouched; move or remove it yourself, then re-run. "
            "Discovery selects this location because it is occupied and never "
            "falls through to the other one."
        )


def require_installable(job: MissionRunnerJob) -> None:
    """Every reason this repository's job must not be written right now.

    Ordered by what each protects, and all of them read-only, so a refusal
    leaves the installation exactly as it was: the manager's own answer about
    this job and this checkout's own live run first — a manager asked to
    replace a definition under a live job leaves a runner nothing can see or
    stop — then a second checkout of this identity.
    """
    require_no_live_run(job, "installing this repository's job")
    snapshot = status_snapshot(job)
    conflict = another_checkout_running(job, snapshot)
    if conflict is not None:
        raise ServiceError(
            f"The mission runner for {job.identity} is already running from "
            f"{conflict}, which is another checkout of the same repository as "
            f"{job.repo_path}. Stop it before installing this checkout's job."
        )
    if snapshot["state"] in LIVE_STATES:
        raise ServiceError(
            "Stop the running mission runner before installing its "
            f"{service_backend().backend_name()} job."
        )


def install_plan(job: MissionRunnerJob, install_dir: Path) -> dict[str, Any]:
    """Exactly what `install_job` would do, without writing anything.

    Reported from the same derivations the install itself uses, so a dry run
    cannot describe a job the install would not produce. Every refusal
    `require_installable` raises is raised here too: a plan that ignored them
    would report an installation that could not actually happen.

    The host check leads, ahead of the service-manager selection and ahead of
    every write on every path that reaches here — installing, planning, and the
    refresh a start performs. A host that cannot supervise a process group
    cannot run this service at all, so a job loaded there could only ever fail
    at start.
    """
    require_supported_host()
    backend = service_backend()
    require_absolute_install_dir(install_dir)
    require_usable_record()
    require_installable(job)
    label = service_label(job)
    definition_path = backend.definition_path(label)
    return {
        "repository": job.identity,
        "repo": str(job.repo_path),
        "label": label,
        "service_manager": backend.backend_name(),
        backend.definition_label(): str(definition_path),
        "target": backend.manager_target(label),
        "record": str(discovery_record_path()),
        "install_dir": str(install_dir),
        "controller": str(controller_path(install_dir)),
        "config_path": job.config_path,
        "runtime_dir": str(job.runtime_dir),
        "log_dir": str(job.log_dir),
        # Installation loads a stopped job and nothing else. The definition
        # itself carries no login trigger, so this is a statement about the
        # whole operation rather than about this one step.
        "started": False,
    }


def write_discovery_record(
    job: MissionRunnerJob, label: str, definition_path: Path, install_dir: Path
) -> tuple[Path, str | None]:
    """Record where the definition just written for this job actually lives, so
    Kanban resolves it by reading rather than by deriving the label a second
    time.

    Which keys name the job is the backend's answer, because the entry is a
    discriminated union exactly as the drainer's and the approval service's
    are. `install_dir` rides along because a custom installation is otherwise
    discoverable only through an environment variable a dashboard never
    inherits.

    Reports the install directory this entry named before, read in the same
    locked read-modify-write that replaced it. That is the only reading of it
    nothing can race: two installs of one repository into two directories both
    find "no previous installation" if they look before they write, and the one
    that writes second would then leave the other's links behind forever.
    """
    replaced: str | None = None

    def observe(entry: dict[str, Any]) -> None:
        nonlocal replaced
        recorded = entry.get("install_dir")
        replaced = recorded if isinstance(recorded, str) and recorded else None

    backend = service_backend()
    updates: dict[str, Any] = {
        **backend.record_entry(label, definition_path),
        "repository": str(job.repo_path),
        "install_dir": str(install_dir),
    }
    if job.config_path:
        updates["config_path"] = job.config_path
    record = merge_repository_record(
        job.identity,
        updates,
        observed=observe,
        # Every service-manager key, not just this backend's: reinstalling a
        # repository under the other manager must leave the entry naming one
        # backend rather than carrying both, and the merge that keeps
        # `config_path` and `install_dir` alive would otherwise keep the
        # superseded manager's keys alive with them.
        discard=service_manager.RECORD_KEYS,
    )
    return record, replaced


def require_installed_controller(install_dir: Path) -> None:
    """Refuse to write a definition naming a controller that is not there.

    The definition names the installed link, and a manager asked to run a path
    that does not exist fails at launch with nothing for anyone to read. Absent
    and present-but-broken are one answer here — a dangling link resolves to
    nothing either way — and both are repaired by the installer that creates
    the link rather than by anything this controller can do.
    """
    controller = controller_path(install_dir)
    if not controller.is_file():
        raise ServiceError(
            f"There is no installed controller at {controller}, so a job written "
            "now could never be started. Run `python3 "
            "tools/install_mission_runner.py` from the checkout first."
        )


def install_job(
    job: MissionRunnerJob, install_dir: Path, *, startup_nonce: str | None = None
) -> dict[str, Any]:
    """Load one stopped job for this repository, and record where it is.

    Nothing is started here and nothing starts at login: the definition the
    backend writes is non-resident by construction, so only an explicit `start`
    ever produces a run -- which is also the only caller that supplies a
    `startup_nonce`.
    """
    with job_transition(job, install_dir):
        return _install_locked(job, install_dir, startup_nonce=startup_nonce)


def _install_locked(
    job: MissionRunnerJob, install_dir: Path, *, startup_nonce: str | None = None
) -> dict[str, Any]:
    """`install_job`'s body, with this identity's transition lock already held.

    Separate so a start can refresh the definition inside the one lock it took
    for the whole start, rather than taking it a second time and waiting on
    itself.
    """
    plan = install_plan(job, install_dir)
    with exclusive_of_runs(job, "installing this repository's job"):
        return _install_write(job, install_dir, plan, startup_nonce=startup_nonce)


def _install_write(
    job: MissionRunnerJob,
    install_dir: Path,
    plan: dict[str, Any],
    *,
    startup_nonce: str | None = None,
) -> dict[str, Any]:
    """The writes themselves, with every lock this install needs held."""
    require_installed_controller(install_dir)
    backend = service_backend()
    ensure_dirs(job)
    job.log_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    label = plan["label"]
    definition_path = backend.write_definition(
        service_definition(job, install_dir, startup_nonce=startup_nonce)
    )
    # Written from the definition on disk and before the manager is asked to
    # load it: the record describes where the job is, so it has to be true from
    # the moment the job exists. Every install path reaches here, including the
    # refresh `start_service` performs, so no route can leave it stale.
    record, previous_install_dir = write_discovery_record(
        job, label, definition_path, install_dir
    )
    backend.load_definition(label)
    return {
        **plan,
        "installed": True,
        "record": str(record),
        # Where this repository's job was installed *before* this write, as the
        # write itself found it. Null unless it has moved, and the installer's
        # authority for taking back the links it left behind.
        "previous_install_dir": previous_install_dir,
    }


def require_stopped_for_uninstall(job: MissionRunnerJob) -> None:
    """Refuse to remove a job whose runner is still running.

    A manager asked to forget a live job leaves a runner advancing missions
    with nothing able to see or stop it, so the remediation is named rather
    than performed: stopping somebody's run is an explicit operator decision,
    and an uninstall that stopped it silently would take that decision away.

    The manager is asked first and believed on its own account, because removal
    is the one transition that destroys the means of recovery. A job whose
    status document is absent, damaged, or simply not written yet would
    otherwise read as unknown, and the definition and record entry would be
    gone before the live process was ever noticed.
    """
    require_no_live_run(
        job,
        "uninstalling this job; removing it under a live runner would leave one "
        "running that nothing can see or stop",
    )
    snapshot = status_snapshot(job)
    conflict = another_checkout_running(job, snapshot)
    if conflict is not None:
        raise ServiceError(
            f"The mission runner for {job.identity} is running from {conflict}, "
            "another checkout of the same repository. Stop it there before "
            "uninstalling this job."
        )
    if snapshot["state"] in LIVE_STATES:
        raise ServiceError(
            f"The mission runner for {job.identity} is running. Stop it first: "
            "uninstalling a live job would leave a runner nothing can see or stop."
        )


def uninstall_plan(job: MissionRunnerJob) -> dict[str, Any]:
    """Exactly what `uninstall_job` would do, without writing anything.

    Led by the same host check, for the same reason: a removal is a mutation
    too, and a host this service cannot run on is one whose job nothing here
    should be reasoning about.
    """
    require_supported_host()
    backend = service_backend()
    require_usable_record()
    require_stopped_for_uninstall(job)
    label = service_label(job)
    return {
        "repository": job.identity,
        "repo": str(job.repo_path),
        "label": label,
        "service_manager": backend.backend_name(),
        backend.definition_label(): str(backend.definition_path(label)),
        "record": str(discovery_record_path()),
        "record_entry_removed": job.identity in installed_repository_records(),
        # Runtime state, logs, and open incidents are deliberately left behind:
        # they are the record of what this service did, and an uninstall is not
        # an acknowledgement.
        "runtime_dir": str(job.runtime_dir),
        "log_dir": str(job.log_dir),
    }


def uninstall_job(
    job: MissionRunnerJob, install_dir: Path | None = None
) -> dict[str, Any]:
    """Remove this repository's job: its definition, the manager's hold on it,
    and its entry in the discovery record.

    Scoped to one repository throughout — the definition is this job's alone
    and the record edit removes one entry — so a second installed repository's
    job, and the shared script links every installed job runs from, are
    untouched. Removing those links is the installer's decision, and only once
    no installed job is left to depend on them.

    `install_dir` names the installation whose lock is held with it: the
    caller's own, when the installer is removing links in the same breath, so
    the two never take two different locks for one directory; this repository's
    recorded one otherwise.
    """
    with job_transition(job, install_dir or job_install_dir(job)):
        return _uninstall_locked(job)


def _uninstall_locked(job: MissionRunnerJob) -> dict[str, Any]:
    plan = uninstall_plan(job)
    with exclusive_of_runs(
        job,
        "uninstalling this job; removing it under a live runner would leave one "
        "running that nothing can see or stop",
    ):
        # Re-asked with the lock held, so the manager's answer is one no run can
        # invalidate while the removal below acts on it.
        require_stopped_for_uninstall(job)
        return _uninstall_write(job, plan)


def _uninstall_write(job: MissionRunnerJob, plan: dict[str, Any]) -> dict[str, Any]:
    """The removal itself, with every lock this uninstall needs held."""
    backend = service_backend()
    label = plan["label"]
    outcome = backend.uninstall_definition(label)
    record = remove_repository_record(job.identity)
    # Asserted rather than assumed: a successful uninstall must leave nothing
    # loaded and nothing running, and a manager that still holds the job after
    # being asked to forget it is a half-finished removal the caller has to hear
    # about rather than discover later.
    if backend.is_loaded(label) or backend.is_running(label):
        raise ServiceError(
            f"The {backend.backend_name()} job {label} is still present after "
            "being removed. Uninstall did not complete; stop the service and "
            "retry."
        )
    return {
        **plan,
        "uninstalled": True,
        "unloaded": outcome.unloaded,
        backend.definition_label() + "_removed": outcome.definition_removed,
        "record": str(record),
    }


def start_service(job: MissionRunnerJob, install_dir: Path) -> dict[str, Any]:
    """Start this repository's job, and confirm it is really running.

    The install is refreshed first, on the drainer's precedent: a start is the
    moment a stale definition or a missing record would matter, and repairing
    both costs one write nobody notices. What the manager then starts outlives
    this process by construction — it is the manager's child, not this one's.

    Held under both locks from the first check to the confirmed start, so a
    start and a removal can never interleave in either direction — neither in
    the job the manager holds, nor in the record entry and shared links an
    uninstall reads to decide what it may take away.
    """
    with job_transition(job, install_dir):
        return _start_locked(job, install_dir)


def _start_locked(job: MissionRunnerJob, install_dir: Path) -> dict[str, Any]:
    snapshot = status_snapshot(job)
    conflict = another_checkout_running(job, snapshot)
    if conflict is not None:
        raise ServiceError(
            f"The mission runner for {job.identity} is already running from "
            f"{conflict}, which is another checkout of the same repository as "
            f"{job.repo_path}. One repository runs one mission runner at a time."
        )
    # A no-op rather than a refusal, unlike the destructive transitions:
    # starting something already started is nothing to do. All three signals
    # count, so a run that has taken its lock but not yet written a status — or
    # a foreground run no manager knows about — is not started a second time.
    if (
        snapshot["state"] in LIVE_STATES
        or job_is_running(job)
        or run_lock_owner(job) is not None
    ):
        return {"started": False, "message": "Already running.", **snapshot}
    # The handshake. `_install_locked` releases this identity's run lock before
    # the kick, because the run being started needs that lock to establish
    # itself — so a foreground run can take it in that window, publish a live
    # status of its own, and leave the kicked process to lose the lock and exit.
    # Neither "a live status exists" nor "the manager holds something" nor both
    # together can tell that apart: they are two independent observations, and
    # the window is as wide as the kicked process happens to live for. Only the
    # document saying which run wrote it can, so this start writes a fresh token
    # into the definition it is about to kick and accepts no status without it.
    nonce = secrets.token_hex(16)
    installed = _install_locked(job, install_dir, startup_nonce=nonce)
    label = installed["label"]
    previous_incidents = {
        path.name for path, _document in incident_documents(job, open_only=True)
    }
    service_backend().kick(label)
    deadline = time.monotonic() + START_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        time.sleep(START_POLL_SECONDS)
        current = status_snapshot(job)
        # The manager as well as the document, because the token proves who
        # wrote the status and not that the job is still there: a run that
        # announced itself and then died would otherwise be reported as started.
        if (
            current["state"] in LIVE_STATES
            and published_startup_nonce(job) == nonce
            and job_is_running(job)
        ):
            return {"started": True, "label": label, **current}
        new_incidents = [
            document
            for path, document in incident_documents(job, open_only=True)
            if path.name not in previous_incidents
        ]
        if new_incidents:
            raise ServiceError(
                "The mission runner exited during startup: "
                + str(
                    new_incidents[0].get("summary")
                    or new_incidents[0].get("incident_id")
                )
            )
    raise ServiceError(startup_timeout_message(job, label, nonce))


def published_startup_nonce(job: MissionRunnerJob) -> str | None:
    """The startup token the status document at hand carries, or None.

    Read straight off the document rather than through `status_snapshot`,
    because it is this start's own handshake rather than anything a reader of
    the service's state is owed.
    """
    stored = read_json(job.status_path) or {}
    value = stored.get("startup_nonce")
    return value if isinstance(value, str) and value else None


def startup_timeout_message(
    job: MissionRunnerJob, label: str, nonce: str
) -> str:
    """Why a start gave up, in the terms of whichever signal is missing.

    "Timed out" alone leaves an operator three very different situations to tell
    apart by hand, and they have three different repairs: a job that is not
    there at all, a job that is there and has written nothing, and a job that is
    there beside a live status some *other* run published — which is what a
    foreground run holding this identity's run lock produces.
    """
    if not job_is_running(job):
        return (
            "Timed out waiting for the mission runner to start: the "
            f"{service_backend().backend_name()} manager holds no live process "
            f"for {label}. A foreground run of {job.identity} that took this "
            "identity's run lock is the usual reason a started job exits at "
            "once; check `status` and stop whatever is running."
        )
    if (
        status_snapshot(job)["state"] in LIVE_STATES
        and published_startup_nonce(job) != nonce
    ):
        # A live status that carries no token at all was written by a run
        # nothing launched from a definition — a foreground one; a token that
        # is merely different belongs to an earlier start's run. Both are the
        # same situation for an operator, and the same repair.
        return (
            f"Timed out waiting for the mission runner to start: {label} is "
            f"running, but the live status document for {job.identity} was "
            "written by a different run — a foreground one holding this "
            "identity's run lock, which is what makes the job just started exit "
            "again. Stop it, then start the job."
        )
    return (
        f"Timed out waiting for the mission runner to start: {label} is running "
        "but has published no status document this reader can believe. Its "
        f"service log under {job.log_dir} is where it said why."
    )


def stop_service(job: MissionRunnerJob) -> dict[str, Any]:
    """Ask this repository's job to stop, and wait for it to really be gone.

    The manager's own polite stop, so the controller runs its intentional
    shutdown — finishing or terminating the pass it is in and recording that it
    stopped on purpose. The job stays installed and loaded: stopping is not
    uninstalling, and a stopped job is exactly what the next start needs to
    find.

    Under the same transition lock as the rest, held until the exit is
    confirmed, so an uninstall that follows a stop cannot begin while the run is
    still on its way out.
    """
    with transition_lock(job):
        return _stop_locked(job)


def _stop_locked(job: MissionRunnerJob) -> dict[str, Any]:
    snapshot = status_snapshot(job)
    # Both answers again, and for the same reason: a run whose status is missing
    # or damaged is still a run, and reporting it as already stopped would leave
    # it going while claiming otherwise.
    if snapshot["state"] not in LIVE_STATES and not job_is_running(job):
        return {"stopped": False, "message": "Already stopped.", **snapshot}
    label = service_label(job)
    service_backend().request_stop(label)
    deadline = time.monotonic() + STOP_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        time.sleep(STOP_POLL_SECONDS)
        current = status_snapshot(job)
        # Confirmed by the manager as well as by the document, so a stop only
        # reports success once there is really no process left — which is what
        # makes the uninstall that may follow it safe.
        if current["state"] not in LIVE_STATES and not job_is_running(job):
            return {"stopped": True, "label": label, **current}
    raise ServiceError("Timed out waiting for the mission runner to stop.")


# ---------------------------------------------------------------------------
# Operations
# ---------------------------------------------------------------------------


def run_service(
    job: MissionRunnerJob, *, kanban: Path, interval: float, passes: int | None = None
) -> int:
    require_supported_host()
    with run_lock(job):
        return Controller(job, kanban=kanban, interval=interval, passes=passes).run()


def print_value(value: Any, *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(value, indent=2, sort_keys=True))
        return
    if isinstance(value, dict):
        for key in sorted(value):
            print(f"{key}: {value[key]}")
        return
    print(value)


def poll_interval(value: str) -> float:
    """One wait between passes, as a real positive number of seconds.

    `float()` accepts `nan` and `inf`, and neither comparison a range check
    makes is true of a NaN — so `nan <= 0` is `False` and it passes. What it
    then does is not a long wait but no wait at all: `Controller.sleep`
    computes `max(0.0, nan)`, which is `0.0`, so an otherwise idle service
    would run scheduler passes back to back for ever. An infinity passes the
    same check and waits for ever instead. Both are refused here, where the
    value is still a string the operator typed.
    """
    try:
        seconds = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{value!r} is not a number of seconds.") from exc
    if not math.isfinite(seconds):
        raise argparse.ArgumentTypeError(
            f"{value!r} is not a finite number of seconds."
        )
    if seconds <= 0:
        raise argparse.ArgumentTypeError("The interval must be a positive number of seconds.")
    return seconds


def positive_count(value: str) -> int:
    try:
        count = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{value!r} is not a whole number.") from exc
    if count <= 0:
        raise argparse.ArgumentTypeError("The pass count must be positive.")
    return count


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog=CONTROLLER_NAME,
        description=(
            "Supervise repeated bounded `kanban --mission-scheduler` passes for one "
            "repository, report what the last run left behind, and install, start, "
            "stop, or remove the managed job that supervises them."
        ),
    )
    subparsers = parser.add_subparsers(dest="operation", required=True)

    runner = subparsers.add_parser(
        "run", help="Supervise scheduler passes in the foreground until stopped."
    )
    runner.add_argument("--path", default=".", help="The repository checkout to run for.")
    runner.add_argument("--repo", default=None, help="Refuse unless the checkout is this repository.")
    runner.add_argument("--config", default=None, help="The configuration every pass runs with.")
    runner.add_argument(
        "--interval",
        type=poll_interval,
        default=DEFAULT_INTERVAL_SECONDS,
        help=(
            "Seconds to wait after a pass that advanced nothing -- which "
            "includes a pass whose admitted missions all declined."
        ),
    )
    runner.add_argument(
        "--passes",
        type=positive_count,
        default=None,
        help="Stop after this many accepted passes instead of running until stopped.",
    )
    runner.add_argument(
        "--kanban",
        default=None,
        help="The kanban executable to run; resolved from PATH when absent.",
    )

    reporter = subparsers.add_parser(
        "status", help="Report this repository's mission runner state, read-only."
    )
    reporter.add_argument("--path", default=".", help="The repository checkout to report on.")
    reporter.add_argument("--repo", default=None, help="Refuse unless the checkout is this repository.")
    reporter.add_argument("--json", action="store_true", help="Write the document rather than lines.")

    acknowledger = subparsers.add_parser(
        "ack", help="Mark one open incident resolved for bookkeeping."
    )
    acknowledger.add_argument("--path", default=".", help="The repository checkout to act on.")
    acknowledger.add_argument("--repo", default=None, help="Refuse unless the checkout is this repository.")
    acknowledger.add_argument("--incident", default=None, help="The incident identifier.")
    acknowledger.add_argument("--note", default=None, help="Why it was acknowledged.")
    acknowledger.add_argument("--json", action="store_true", help="Write the document rather than lines.")

    # The four managed-job operations. Each is reached by
    # `tools/install_mission_runner.py` through the *installed* copy of this
    # module, which is why none takes an install-directory option: the copy
    # that runs them is the installation they are about, and it reads its own
    # location from the environment that launched it.
    installer = subparsers.add_parser(
        "install", help="Load a stopped job for this repository. Starts nothing."
    )
    installer.add_argument("--path", default=".", help="The repository checkout to install for.")
    installer.add_argument("--repo", default=None, help="Refuse unless the checkout is this repository.")
    installer.add_argument("--config", default=None, help="The configuration every pass runs with.")
    installer.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would change without writing anything.",
    )
    installer.add_argument("--json", action="store_true", help="Write the document rather than lines.")

    remover = subparsers.add_parser(
        "uninstall", help="Unload this repository's job and drop its record entry."
    )
    remover.add_argument("--path", default=".", help="The repository checkout to remove the job of.")
    remover.add_argument("--repo", default=None, help="Refuse unless the checkout is this repository.")
    remover.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would change without writing anything.",
    )
    remover.add_argument("--json", action="store_true", help="Write the document rather than lines.")

    starter = subparsers.add_parser(
        "start", help="Start the installed job; the run outlives this process."
    )
    starter.add_argument("--path", default=".", help="The repository checkout to start for.")
    starter.add_argument("--repo", default=None, help="Refuse unless the checkout is this repository.")
    starter.add_argument("--config", default=None, help="The configuration every pass runs with.")
    starter.add_argument("--json", action="store_true", help="Write the document rather than lines.")

    stopper = subparsers.add_parser(
        "stop", help="Stop the run, leaving the job installed."
    )
    stopper.add_argument("--path", default=".", help="The repository checkout to stop for.")
    stopper.add_argument("--repo", default=None, help="Refuse unless the checkout is this repository.")
    stopper.add_argument("--json", action="store_true", help="Write the document rather than lines.")

    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_args(argv)
    try:
        repo_path = Path(arguments.path).expanduser().resolve()
        config_path = (
            str(Path(arguments.config).expanduser().resolve())
            if getattr(arguments, "config", None)
            else None
        )
        job = resolve_job(repo_path, config_path=config_path)
        require_requested_identity(job, arguments.repo)
        if arguments.operation == "run":
            kanban = resolve_kanban(arguments.kanban)
            return run_service(
                job,
                kanban=kanban,
                interval=arguments.interval,
                passes=arguments.passes,
            )
        if arguments.operation == "status":
            print_value(status_snapshot(job), as_json=arguments.json)
            return 0
        if arguments.operation == "ack":
            print_value(
                acknowledge_incident(job, arguments.incident, arguments.note),
                as_json=arguments.json,
            )
            return 0
        if arguments.operation == "install":
            selected = job_install_dir(job)
            value = (
                install_plan(job, selected)
                if arguments.dry_run
                else install_job(job, selected)
            )
            print_value({**value, "dry_run": arguments.dry_run}, as_json=arguments.json)
            return 0
        if arguments.operation == "uninstall":
            value = (
                uninstall_plan(job) if arguments.dry_run else uninstall_job(job)
            )
            print_value({**value, "dry_run": arguments.dry_run}, as_json=arguments.json)
            return 0
        if arguments.operation == "start":
            print_value(
                start_service(job, job_install_dir(job)), as_json=arguments.json
            )
            return 0
        if arguments.operation == "stop":
            print_value(stop_service(job), as_json=arguments.json)
            return 0
    except (ServiceError, kanban_config.KanbanConfigError, OSError) as exc:
        print(f"{CONTROLLER_NAME}: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:  # pragma: no cover - an interactive interrupt
        return 130
    return 1


if __name__ == "__main__":  # pragma: no cover - the entry point
    raise SystemExit(main())
