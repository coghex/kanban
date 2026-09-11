#!/usr/bin/env python3

"""The mission runner controller.

`kanban --mission-scheduler` advances this repository's runnable missions for
exactly one bounded pass and then exits, writing one JSON report. Something has
to repeat those passes, decide how long to wait between them, and leave a
durable trace of what happened. This module is that something: a foreground
`run` that supervises repeated passes and a read-only `status` that reports
what the last run left behind.

Nothing here installs anything. Making this a managed job — a service-manager
namespace, a discovery record, per-repository log directories, and the
installer that writes them — is RUN-2's; this slice is invoked directly, and
`tools/install_issue_approval.py` is the shape RUN-2 will follow.

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
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import kanban_config

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
PASS_DISPOSITIONS = frozenset(
    {"advanced", "settled", "blocked", "lease_refused", "refused", "failed"}
)
# The one disposition that makes a pass a failed pass, which the scheduler
# already reflects in its termination. Mirrored so a report whose dispositions
# and termination disagree is caught rather than believed.
PASS_FAILING_DISPOSITIONS = frozenset({"failed"})
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
# reason `approve_issues_service.py` carries its own: RUN-2's installer will
# recognize the copy it manages by content rather than by path.
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
# back to a digest. Well under the 255-byte filename ceiling, leaving room for
# the file names inside the directory it names. RUN-2 will narrow this to
# whatever a service manager's identifier allows.
SLUG_LIMIT = 160

INCIDENT_ID_RE = re.compile(r"\Aincident-[A-Za-z0-9TZ-]+\Z")


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


def service_root() -> Path:
    """This service's one root for this account.

    Platform-shaped the way `tools/kanban_config.py` shapes every other managed
    location: the macOS application-support tree, or the XDG data root and its
    home-relative spelling everywhere else. `$XDG_DATA_HOME` selects the first
    only when it names an absolute directory, which is the drainer's rule
    rather than issue-review's, for the drainer's stated reason — the unit that
    will eventually run this job and the paths that locate it must read the
    environment identically.

    There is deliberately no override. A configurable runtime cannot serialize
    anything a configuration can change, and RUN-2's `--install-dir` moves the
    script links rather than this.

    Resolved per call rather than frozen at import, exactly as
    `kanban_config.default_issue_review_install_dir` is and for the same
    reason: freezing it would bind whatever the account resolved to when the
    module first loaded.
    """
    # The two home-relative spellings this resolves to, written out so the
    # manifest rows that declare them are grounded in the module that builds
    # them: ~/Library/Application Support/kanban/mission-runner on macOS, and
    # ~/.local/share/kanban/mission-runner everywhere else.
    if kanban_config.is_macos():
        return account_home() / "Library" / "Application Support" / "kanban" / "mission-runner"
    configured = os.environ.get("XDG_DATA_HOME")
    if configured and os.path.isabs(configured):
        return Path(configured) / "kanban" / "mission-runner"
    return account_home() / ".local" / "share" / "kanban" / "mission-runner"


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
    slug: str
    runtime_dir: Path
    incident_dir: Path
    status_path: Path
    lock_path: Path
    config_path: str | None


def job_for_identity(
    repo_path: Path, identity: str, *, config_path: str | None = None
) -> MissionRunnerJob:
    slug = repository_slug(identity)
    runtime_dir = runtime_root() / slug
    return MissionRunnerJob(
        repo_path=repo_path,
        identity=identity,
        slug=slug,
        runtime_dir=runtime_dir,
        incident_dir=runtime_dir / "incidents",
        status_path=runtime_dir / "status.json",
        lock_path=run_lock_path(slug),
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


def repository_identity(repo_path: Path, remote_name: str) -> str:
    """The canonical GitHub repository this checkout is a clone of.

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
        return normalize_identity(proc.stdout)
    except ServiceError as exc:
        raise ServiceError(
            f"{repo_path} is not a checkout of a supported GitHub repository, so it "
            f"cannot run or report a mission runner service: {exc}"
        ) from exc


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
    identity = repository_identity(repo_path, discovery_remote_name())
    return job_for_identity(repo_path, identity, config_path=config_path)


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

    Deliberately not a file. Per-repository service log directories are RUN-2's
    along with the installation that would put a job's output somewhere; a
    controller invoked directly writes where its caller can see it, and the
    durable account of what happened is the status document and the incidents.
    """
    print(f"[{local_stamp()}] {message}", file=sys.stderr, flush=True)


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
def run_lock(job: MissionRunnerJob) -> Iterator[None]:
    """Hold this identity's exclusive run lock, or refuse.

    Requirement 11's "a second wrapper for the same repository refuses and
    starts no scheduler": non-blocking, so a contended start fails immediately
    rather than queueing behind a run that may last for hours, and taken before
    any status or incident is written, so a refused second run changes nothing
    the first one owns.

    The losing contender closes without truncating, so it cannot erase the
    owner's own diagnostic metadata.
    """
    path = job.lock_path
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
        raise ServiceError(
            f"A mission runner for {job.identity} is already running"
            f"{describe_run_owner(owner)}. One repository runs one mission "
            "runner at a time."
        ) from exc
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
    if state not in STATUS_STATES:
        return STATE_UNKNOWN, (
            f"the status document at {job.status_path} records unknown state {state!r}"
        )
    if state in LIVE_STATES and not pid_alive(stored.get("runner_pid")):
        return STATE_UNKNOWN, (
            f"the status document at {job.status_path} records {state} under runner "
            f"PID {stored.get('runner_pid')!r}, which is not running"
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
    termination = document["termination"]
    if termination not in PASS_TERMINATIONS:
        raise PassFailure(
            f"The mission scheduler report has unknown termination {termination!r}."
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
    _require_attention(document["attention"])
    detail = document["detail"]
    if not isinstance(detail, str):
        raise PassFailure(f"The mission scheduler report carries no detail: {detail!r}.")
    for field in ("started_at", "finished_at"):
        if not isinstance(document[field], str) or not document[field].strip():
            raise PassFailure(
                f"The mission scheduler report names no {field}: {document[field]!r}."
            )
    return document


def _require_admitted(admitted: Any, termination: str) -> None:
    if not isinstance(admitted, list):
        raise PassFailure(
            f"The mission scheduler report's admitted missions are not a list: "
            f"{type(admitted).__name__}."
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
        if not isinstance(entry["mission"], str) or not entry["mission"].strip():
            raise PassFailure(
                f"A mission scheduler report's admitted entry names no mission: "
                f"{entry['mission']!r}."
            )
        disposition = entry["disposition"]
        if disposition not in PASS_DISPOSITIONS:
            raise PassFailure(
                f"A mission scheduler report names unknown disposition {disposition!r}."
            )
        if not isinstance(entry["detail"], str):
            raise PassFailure(
                f"A mission scheduler report's admitted entry carries no detail: "
                f"{entry['detail']!r}."
            )
        failing = failing or disposition in PASS_FAILING_DISPOSITIONS
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


def _require_attention(attention: Any) -> None:
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
        for field in ("mission", "attention_id"):
            if not isinstance(entry[field], str) or not entry[field].strip():
                raise PassFailure(
                    f"A mission scheduler report's attention entry names no {field}: "
                    f"{entry[field]!r}."
                )
        state = entry["notification"]
        if state not in PASS_NOTIFICATION_STATES:
            raise PassFailure(
                f"A mission scheduler report names unknown notification state {state!r}."
            )
        _require_targets(entry["targets"])
        if entry["detail"] is not None and not isinstance(entry["detail"], str):
            raise PassFailure(
                f"A mission scheduler report's attention detail is neither absent nor "
                f"text: {entry['detail']!r}."
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
    if target["kind"] not in PASS_TARGET_KINDS:
        raise PassFailure(
            f"A mission scheduler report names unknown target kind {target['kind']!r}."
        )
    if not is_plain_integer(target["number"]) or target["number"] <= 0:
        raise PassFailure(
            f"A mission scheduler report's attention target names no positive number: "
            f"{target['number']!r}."
        )


def pass_state(document: dict[str, Any]) -> str:
    """The status state one accepted report leaves behind.

    `waiting` wins over `idle`, because a repository with a mission waiting on
    a person is not quiet -- it is stuck, and that is the state an operator
    needs to see. A pass that admitted something leaves `running`: the next
    pass starts immediately, so the service is advancing work rather than
    sitting between polls. Only a pass that admitted nothing and saw nobody
    waiting leaves `idle`.
    """
    if document["attention"]:
        return STATE_WAITING
    if document["admitted"]:
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
                "repository": self.job.identity,
                "repo": str(self.job.repo_path),
                # The ownership a reader needs to reject a stale observation: a
                # live state recorded under a runner that is gone is not a
                # running service.
                "runner_pid": os.getpid(),
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
            "--repo",
            self.job.identity,
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
        if self._stop_requested and not command.stdout.strip():
            # A pass this controller signalled decided nothing, so treating its
            # exit or its truncated output as a failure would record an
            # intentional stop as one. A pass that *completed* is never
            # suppressed this way, because work that really happened must not
            # be reported as work that did not.
            self.log("A pass was interrupted by the stop; recording no result for it.")
            return
        try:
            document = parse_pass_report(command.stdout, command.returncode)
        except PassFailure as failure:
            raise PassFailure(failure.summary, failure.detail or tail(command.stderr)) from failure
        if document["repository"] != self.job.identity:
            raise PassFailure(
                f"The mission scheduler report describes {document['repository']!r}, "
                f"not {self.job.identity!r}.",
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
        self.sleep(ADVANCE_DELAY_SECONDS if document["admitted"] else self.interval)


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
    try:
        seconds = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{value!r} is not a number of seconds.") from exc
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
            "repository, and report what the last run left behind."
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
        help="Seconds to wait after a pass that advanced nothing.",
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
    except ServiceError as exc:
        print(f"{CONTROLLER_NAME}: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:  # pragma: no cover - an interactive interrupt
        return 130
    return 1


if __name__ == "__main__":  # pragma: no cover - the entry point
    raise SystemExit(main())
