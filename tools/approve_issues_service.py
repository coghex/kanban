#!/usr/bin/env python3

"""The persistent issue approval controller.

`tools/approve_issues.py --review-queue` advances the open backlog by exactly
one issue per invocation and then exits, releasing the canonical approval lock
between issues. Something has to repeat those bounded passes, decide how long
to wait between them, and leave a durable trace of what happened. This module
is that something: a foreground `run` that supervises repeated passes, and a
read-only `status` that reports what the last run left behind.

Three boundaries are deliberate.

It never imports the backend. `tools/approve_issues.py` is *installed* --
resolved through the discovery record described in
`docs/agent-workflow-contract.md` sections 2.3 and 3 -- so the copy this
controller runs is not necessarily the copy in the checkout it was started
from, and could not be imported from here even if it were. Every exchange is a
child process and one bounded JSON document, and the schema and version that
document must carry are mirrored below rather than imported. A test holds the
mirrored constants equal to the backend's.

It never shares `tools/drain_prs_service.py`'s state, and does not import it
either. That module is the pattern for every convention here -- identity
normalization, per-repository runtime and log directories, atomic document
replacement, process-group supervision -- but the two services are distinct
jobs whose incidents mean different things, so this one keeps its own
`issue-approval` namespace, its own lock, and its own status and incident
types. Importing the drainer's controller would also drag in a service-manager
selection this slice deliberately does not need: `run` is a foreground process
and installs no job.

It never decides anything the backend owns. Which issue is next, which
reviewer runs, what a verdict means, and every GitHub mutation stay in the
backend. This module owns repetition, waiting, the ordered barrier's
durability, and the runtime documents a dashboard reads.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import traceback
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import kanban_config

# Guarded rather than imported outright so a host without it gets the
# diagnostic `require_supported_host` writes instead of an ImportError
# traceback from module load, which is the difference between failing clearly
# and failing incomprehensibly (requirement 14).
try:  # pragma: no cover - the exception arm needs a non-POSIX host
    import fcntl
except ImportError:  # pragma: no cover - see above
    fcntl = None  # type: ignore[assignment]


# The one document a `--review-queue` pass writes to stdout. Mirrored from
# `approve_issues.REVIEW_QUEUE_SCHEMA` and its neighbours rather than imported,
# for the reason the module docstring gives; `tools/test_approve_issues_service.py`
# holds every mirrored constant equal to the backend's own.
BACKEND_RESULT_SCHEMA = "approve-issues-review-queue"
BACKEND_RESULT_VERSION = 1
BACKEND_RESULT_FIELDS = frozenset(
    {"schema", "version", "outcome", "issue", "model_called", "message"}
)
BACKEND_OUTCOMES = frozenset(
    {"idle", "advanced", "changes_requested", "retry", "busy"}
)
# The outcomes that name the issue they are about; `idle` and `busy` are about
# the queue and carry no number.
BACKEND_ISSUE_OUTCOMES = frozenset({"advanced", "changes_requested", "retry"})
BACKEND_NAME = "approve_issues.py"
# The canonical approval lock's file name, inside the repository's shared Git
# directory. Mirrored from `approve_issues.APPROVAL_LOCK_NAME` for the reason
# the module docstring gives, and held equal to it by a test -- as is the
# resolution `approval_lock_path` below performs, which is compared against the
# backend's own function rather than restated in prose.
APPROVAL_LOCK_NAME = "approve_issues.lock"
# This controller's own lock, beside it in the same shared Git directory and
# named so it can never be mistaken for the backend's. Kept distinct because
# the two mean different things: the backend's is held for one issue's review,
# this one for a whole run.
RUN_LOCK_NAME = "kanban_issue_approval_run.lock"
# `--check`'s two ordinary exits: approved, and gated. Everything else is a
# failure of the check rather than an answer from it.
GATE_APPROVED_EXIT = 0
GATE_REFUSED_EXIT = 2

# The runtime documents this controller owns. Both carry an explicit schema and
# an integer version because `src/Kanban/Drainer.hs`'s successor for this
# service (IAQ-4) decodes them, and a reader that cannot tell which shape it
# holds is a reader that guesses.
STATUS_SCHEMA = "kanban-issue-approval-status"
STATUS_VERSION = 1
INCIDENT_SCHEMA = "kanban-issue-approval-incident"
INCIDENT_VERSION = 1
BARRIER_SCHEMA = "kanban-issue-approval-barrier"
BARRIER_VERSION = 1

# The states a status document distinguishes. The first three describe a live
# run; the last three are terminal and outlive the process that wrote them.
STATE_STARTING = "starting"
STATE_RUNNING = "running"
STATE_BARRIER = "barrier"
STATE_STOPPED = "stopped"
STATE_CHILD_FAILURE = "child_failure"
STATE_CONTROLLER_FAILURE = "controller_failure"
# Never written: synthesized by `status_snapshot` for a document that is
# absent, unreadable, of another schema or version, another repository's, or
# stale -- one whose live state names a runner that is not running.
STATE_UNKNOWN = "unknown"
LIVE_STATES = frozenset({STATE_STARTING, STATE_RUNNING, STATE_BARRIER})
TERMINAL_STATES = frozenset(
    {STATE_STOPPED, STATE_CHILD_FAILURE, STATE_CONTROLLER_FAILURE}
)
STATUS_STATES = LIVE_STATES | TERMINAL_STATES

# Incident kinds. A barrier is a warning: the service is healthy and waiting
# for a specification repair it must not perform. Everything else this
# controller records is an error that stopped the run.
BARRIER_INCIDENT_KIND = "issue-changes-requested"
ERROR_INCIDENT_KIND = "approval-error"
SEVERITY_WARNING = "warning"
SEVERITY_ERROR = "error"

DEFAULT_INTERVAL_SECONDS = 60.0
# `advanced` proceeds to the next pass promptly: the previous pass has just
# released the canonical lock and the backlog is known to have moved.
ADVANCE_DELAY_SECONDS = 0.0
# `busy` and `retry` are ordinary retryable completions, so they wait longer
# each time rather than hammering a lock someone else holds or a specification
# that is being edited. Bounded: the wait never exceeds the ceiling below,
# which keeps a service that backs off from becoming a service that has
# stopped.
BACKOFF_CEILING_MULTIPLIER = 8
# How finely a wait is sliced, so a stop signal is noticed promptly rather than
# at the end of a poll interval. `time.sleep` resumes after a handler that does
# not raise (PEP 475), so a wait has to be built from slices to be interruptible.
SLEEP_SLICE_SECONDS = 0.05
# How long an intentional stop waits for the backend's process group to go away
# after SIGINT before escalating to SIGKILL.
STOP_GRACE_SECONDS = 10.0
# How much of a failed pass's stderr is kept in its incident.
CAPTURED_STDERR_LINES = 60

INCIDENT_ID_RE = re.compile(r"\Aincident-[A-Za-z0-9TZ-]+\Z")


class ServiceError(RuntimeError):
    pass


class BackendFailure(ServiceError):
    """One backend invocation that produced no result this controller may act
    on: a non-zero exit, an absent document, or one it cannot read.

    Carries the operator-facing summary separately from the diagnostic detail
    because the summary is what an incident and a status message show, while
    the detail is the captured stderr nobody wants in a sidebar.
    """

    def __init__(self, summary: str, detail: str | None = None) -> None:
        super().__init__(summary)
        self.summary = summary
        self.detail = detail


def service_root() -> Path:
    """This service's one root for this account.

    There is deliberately no environment or flag override. The identity lock
    that keeps two clones of one GitHub repository from both running hangs off
    this root, so a root a caller could move is a root that lets two runs both
    start -- each taking its own lock, writing its own status, and alternating
    backend passes as the other releases the canonical approval lock between
    issues. A configurable location cannot serialize anything a configuration
    can change.

    `Path.home()` still reads `$HOME`, which one OS account can be given two
    values of, so this root is not by itself proof of a single run. That is
    what `checkout_lock_path` is for: it is anchored to the repository, and
    `run_lock` holds both.

    Resolved per call rather than frozen at import, exactly as
    `kanban_config.default_issue_review_install_dir` is and for the same
    reason: freezing it would bind whatever `$HOME` held when the module first
    loaded, which any process that changes it would then silently escape.
    """
    return Path.home() / "Library" / "Application Support" / "kanban" / "issue-approval"


def runtime_root() -> Path:
    """Where each identity's status, barrier, and incidents live.

    IAQ-3 owns installation and may one day let an installer relocate this.
    `run_lock_path` is deliberately not written against it, so that a movable
    runtime could never move the lock with it.
    """
    return service_root() / "runtime"


def run_lock_path(slug: str) -> Path:
    """The lock a `run` takes for one canonical identity.

    Anchored to `service_root` rather than to the runtime root, and named by
    the identity rather than by the checkout, so two *clones* of one GitHub
    repository contend here even though they share no Git directory -- and so
    would a second installation, if the runtime ever became relocatable.

    One of the two locks `run_lock` holds, not the whole guarantee: this one
    is under `$HOME`, and `checkout_lock_path` covers the invocations that
    differ in it.
    """
    return service_root() / "locks" / f"{slug}.lock"


def log_root() -> Path:
    return Path.home() / "Library" / "Logs" / "kanban" / "issue-approval"


def require_supported_host() -> None:
    """Refuse a host this controller cannot supervise a child on.

    Every mechanism `run` depends on is POSIX: an advisory `flock` for the
    per-identity run lock, a new session per backend invocation, and a signal
    to that session's process group. Pure code and the fixtures around it stay
    portable, but a run that cannot terminate its own child has no safe
    degraded mode, so this refuses rather than proceeding (requirement 14).
    """
    missing = [
        name
        for name, present in (
            ("POSIX process semantics", os.name == "posix"),
            ("fcntl.flock", fcntl is not None),
            ("os.killpg", hasattr(os, "killpg")),
            ("os.setsid via start_new_session", hasattr(os, "setsid")),
        )
        if not present
    ]
    if missing:
        raise ServiceError(
            "The issue approval controller runs only on POSIX hosts; this one "
            f"provides no {', '.join(missing)}. Run it on macOS or Linux."
        )


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


# Escaping can double a segment's length, so an identity spelled almost
# entirely in separators could outgrow what a directory name may hold. The
# limit is deliberately well under the 255-byte filename ceiling, leaving room
# for the file names inside the directory it names.
SLUG_LIMIT = 180


def repository_slug(identity: str) -> str:
    """A filename-safe directory name for one normalized identity.

    Total, nonempty, and injective across distinct normalized identities: each
    segment is escaped into an alphabet that excludes `.`, so the single `.` in
    the result is unambiguously the owner/name separator, and the escape itself
    is reversible. Case-only spellings never reach here as distinct values --
    `normalize_identity` folded them together first -- which is what keeps two
    clones of one GitHub repository from partitioning two runtimes.

    An identity whose escaped slug would outgrow `SLUG_LIMIT` falls back to a
    hash of the whole identity, which cannot collide with an escaped slug
    because it contains no `.` at all.
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
class ApprovalJob:
    """One repository's approval service: its identity and every mutable path
    that belongs to it alone.

    Built once per invocation and threaded through, so no two code paths can
    derive a different status file for the same repository. Every field except
    `repo_path` and `config_path` is a function of `identity`, which is what
    makes two checkouts of one GitHub repository resolve to the same runtime --
    and two different repositories to runtimes that share nothing.
    """

    repo_path: Path
    identity: str
    slug: str
    runtime_dir: Path
    incident_dir: Path
    status_path: Path
    barrier_path: Path
    lock_path: Path
    log_dir: Path
    service_log_path: Path
    config_path: str | None


def job_for_identity(
    repo_path: Path, identity: str, *, config_path: str | None = None
) -> ApprovalJob:
    slug = repository_slug(identity)
    runtime_dir = runtime_root() / slug
    return ApprovalJob(
        repo_path=repo_path,
        identity=identity,
        slug=slug,
        runtime_dir=runtime_dir,
        incident_dir=runtime_dir / "incidents",
        status_path=runtime_dir / "status.json",
        barrier_path=runtime_dir / "barrier.json",
        lock_path=run_lock_path(slug),
        log_dir=log_root() / slug,
        service_log_path=log_root() / slug / "service.log",
        config_path=config_path,
    )


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
    github.com has no approval-service identity, so it can neither run nor be
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
            f"cannot run or report an issue approval service: {exc}"
        ) from exc


def resolve_job(repo_path: Path, *, config_path: str | None = None) -> ApprovalJob:
    identity = repository_identity(repo_path, configured_remote_name(config_path))
    return job_for_identity(repo_path, identity, config_path=config_path)


def require_requested_identity(job: ApprovalJob, requested: str | None) -> None:
    """Refuses a caller whose repository is not the one this job is for.

    Kanban resolves the board's repository through its own configuration and
    passes the result here. Anything but this job's own identity is refused,
    including another remote of this same checkout: a fork's upstream is a
    different canonical repository, and quietly reporting on the origin
    service while the dashboard is for the upstream one is precisely the
    divergence per-repository identities exist to prevent.
    """
    if requested is None:
        return
    wanted = normalize_identity(requested)
    if wanted != job.identity:
        raise ServiceError(
            f"--repo {requested} names {wanted}, but {job.repo_path} is a checkout "
            f"of {job.identity}; refusing to act on another repository's issue "
            "approval service. Align remote_name in the shared Kanban "
            "configuration with the repository you mean."
        )


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


def resolve_backend() -> Path:
    """The installed canonical issue-review backend this controller invokes.

    The one resolution contract, in the one order
    `docs/agent-workflow-contract.md` sections 2.3 and 3 fix and
    `Kanban.Review.resolveCanonicalIssueReviewer` implements: a non-empty
    `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then the absolute `backend_path` the
    installer recorded, then -- only when that field is absent, which is
    exactly how an installation predating the record reads -- the directory
    holding the record.

    Every failure is closed. A selected override or recorded backend that is
    missing fails here rather than falling through to a lower-precedence
    location, because reviewing with an installation the operator did not
    choose is worse than not reviewing; a record that will not parse, is not an
    object, or whose `backend_path` is wrong-typed or relative is its own
    failure naming that document. All of it happens before a run writes
    anything, so a misresolved backend costs no model work.
    """
    record = kanban_config.issue_review_record_path()
    override = os.environ.get(kanban_config.ISSUE_REVIEW_INSTALL_DIR_ENV)
    if override and override.strip():
        resolved = Path(override).expanduser() / BACKEND_NAME
    else:
        if not os.path.lexists(record):
            document: dict[str, Any] = {}
        else:
            loaded = _read_json_document(record)
            if loaded is None:
                raise ServiceError(
                    f"The issue-review install record at {record} is unreadable."
                )
            if not isinstance(loaded, dict):
                raise ServiceError(
                    f"The issue-review install record at {record} is not a JSON object."
                )
            document = loaded
        if "backend_path" not in document:
            resolved = record.parent / BACKEND_NAME
        else:
            recorded = document["backend_path"]
            if not isinstance(recorded, str) or not Path(recorded).is_absolute():
                raise ServiceError(
                    f"The issue-review install record at {record} does not name an "
                    f"absolute backend_path: {recorded!r}."
                )
            resolved = Path(recorded)
    if not resolved.is_file():
        raise ServiceError(
            f"Canonical issue reviewer was not found at {resolved} (consulted "
            f"{record}). Run `python3 tools/install_issue_review.py` from the "
            "Kanban checkout to install it."
        )
    return resolved


def python_executable() -> str:
    """The interpreter the backend runs under.

    This process's own, so the backend runs on the Python the service was
    started with rather than on whatever `python3` a service manager's PATH
    resolves to. The documented spelling remains the fallback for an embedded
    interpreter that reports none.
    """
    return sys.executable or "python3"


def utc_stamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def local_stamp() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    """Replace `path` with `value` in one step.

    Every runtime document goes through this: a dashboard polls them while the
    controller writes them, and a reader that can observe a half-written
    document is a reader that can observe a service in a state it was never in
    (requirement 9). The temporary file is created in the destination
    directory so the rename stays within one filesystem, which is what makes
    it atomic.
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


def ensure_dirs(job: ApprovalJob) -> None:
    for path in (job.runtime_dir, job.incident_dir, job.log_dir):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.chmod(0o700)


def service_log(job: ApprovalJob, message: str) -> None:
    ensure_dirs(job)
    line = f"[{local_stamp()}] {message}"
    with job.service_log_path.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")
    print(line, flush=True)


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
        return False
    return True


def is_plain_integer(value: Any) -> bool:
    # bool is a subclass of int, and `true` is neither an issue number nor a
    # document version.
    return isinstance(value, int) and not isinstance(value, bool)


def positive_issue(value: Any) -> int | None:
    return value if is_plain_integer(value) and value > 0 else None


def pinned_version(value: Any, expected: int) -> bool:
    """Whether a document declares exactly the integer version pinned here.

    Equality alone does not say that. `bool` is an `int` in Python with
    `True == 1`, and the JSON float `1.0` compares equal to `1` as well, so
    both would pass a bare `== 1` check on a document that is not this one.
    """
    return is_plain_integer(value) and value == expected


# ---------------------------------------------------------------------------
# The canonical approval lock, read but never taken
# ---------------------------------------------------------------------------


def shared_git_dir(repo_path: Path) -> Path:
    """The Git directory every checkout of this repository shares.

    `.git/` in an ordinary checkout, and the primary checkout's `.git/` for a
    linked worktree, whose own `.git` is a regular file. Resolved exactly as
    `approve_issues.approval_lock_path` resolves it, because the canonical
    approval lock below has to be the very file the backend contends for and
    any other answer would name a different one.

    The *common* directory, not `--absolute-git-dir`: the latter answers a
    linked worktree's own private `.git/worktrees/<name>`, which no other
    checkout can see. Git is asked only when `.git` is not a directory, which
    leaves an ordinary checkout's answer free of any subprocess.

    Fails closed. A checkout whose shared directory cannot be resolved has no
    location every checkout of it agrees on, and guessing one would give both
    locks below a file nobody else ever takes.
    """
    entry = repo_path / ".git"
    if entry.is_dir():
        return entry
    proc = run_command(
        ["git", "-C", str(repo_path), "rev-parse", "--git-common-dir"], check=False
    )
    answer = (proc.stdout or "").strip()
    if proc.returncode != 0 or not answer:
        detail = (proc.stderr or "").strip() or (
            f"exit code {proc.returncode}"
            if proc.returncode != 0
            else "it printed nothing"
        )
        raise ServiceError(
            f"Could not resolve the shared Git directory for {repo_path}, so the "
            "canonical approval lock has no location every checkout of this "
            f"repository shares: git rev-parse --git-common-dir {detail}"
        )
    common = Path(answer)
    if not common.is_absolute():
        # Git answers relative to the directory it ran in, which `-C` made this
        # checkout. Left unanchored the lock would move with the calling
        # process's working directory, which is the shared location's point.
        common = repo_path / common
    return common


def approval_lock_path(repo_path: Path) -> Path:
    """Where `approve_issues.acquire_lock` takes the canonical approval lock."""
    return shared_git_dir(repo_path) / APPROVAL_LOCK_NAME


def checkout_lock_path(repo_path: Path) -> Path:
    """This repository's own run lock, in a location no environment can move.

    The per-identity lock under `service_root` is anchored to `Path.home()`,
    which reads `$HOME` -- so two processes under one OS account can be given
    different values for it and each take a lock of its own. This one is
    anchored to the repository instead: every invocation naming this checkout
    resolves the same shared Git directory whatever `$HOME`, install root, or
    working directory it was started with, and a linked worktree resolves the
    primary checkout's.

    The two are complementary rather than redundant, and `run_lock` takes both.
    This one catches one checkout started twice however the environment
    differs; the identity lock catches two *clones* of one GitHub repository,
    which have two Git directories and would never contend here.
    """
    return shared_git_dir(repo_path) / RUN_LOCK_NAME


def approval_lock_owner(repo_path: Path) -> dict[str, Any] | None:
    """The metadata of whoever currently holds the canonical approval lock, or
    None when nobody does.

    Read by trying the same non-blocking exclusive `flock` the backend takes
    and immediately dropping it on success, so a check never becomes a hold.
    Nothing is truncated on the way: a losing contender must not erase the
    owner's diagnostic metadata, which is the same discipline
    `approve_issues.acquire_lock` follows.

    Raises rather than answering when the lock cannot be inspected at all --
    an unresolvable shared Git directory, a path that is not a regular file,
    permissions that refuse it. "Absent" and "unusable" are different answers,
    and reporting the second as the first is how a start-time refusal silently
    stops refusing.
    """
    path = approval_lock_path(repo_path)
    if not os.path.lexists(path):
        # Verifiably nobody: the backend creates this file whenever it runs, so
        # its absence means no owner. Answered without creating it, because a
        # check must leave the checkout exactly as it found it.
        return None
    try:
        handle = open(path, "a+", encoding="utf-8")
    except OSError as exc:
        raise ServiceError(
            f"Could not inspect the canonical approval lock at {path}: {exc}"
        ) from exc
    try:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return _read_lock_owner(handle)
        except OSError as exc:
            raise ServiceError(
                f"Could not inspect the canonical approval lock at {path}: {exc}"
            ) from exc
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        return None
    finally:
        handle.close()


def _read_lock_owner(handle: Any) -> dict[str, Any]:
    """Whatever the owner recorded, or an empty record when it recorded
    nothing readable. A held lock always has an owner, so this never reports
    None -- only an owner it cannot describe in detail."""
    try:
        handle.seek(0)
        raw = handle.read().strip()
    except OSError:
        return {}
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        try:
            return {"pid": int(raw), "mode": "legacy"}
        except ValueError:
            return {}
    return value if isinstance(value, dict) else {}


def describe_lock_owner(owner: dict[str, Any]) -> str:
    """The owner as `approve_issues.describe_lock_owner` words it.

    Only the spellings this controller's refusal quotes are reproduced; every
    other owner is described generically, because the only distinction that
    changes behaviour here is whether the holder is the untracked background
    approval daemon.
    """
    pid = owner.get("pid")
    suffix = f" (PID {pid})" if is_plain_integer(pid) else ""
    if owner.get("mode") == "daemon":
        return f"the background approval daemon{suffix}"
    issue = positive_issue(owner.get("issue"))
    mode = owner.get("mode")
    if mode == "single" and issue is not None:
        return f"single-issue review #{issue}{suffix}"
    if mode == "rereview" and issue is not None:
        return f"single-issue rereview #{issue}{suffix}"
    if mode == "queue" and issue is not None:
        return f"the issue review queue at #{issue}{suffix}"
    return f"another approval process{suffix}"


def is_legacy_daemon(owner: dict[str, Any]) -> bool:
    return owner.get("mode") == "daemon"


def require_no_legacy_daemon(repo_path: Path) -> None:
    """Refuse to start beside the untracked background approval daemon.

    That daemon deliberately skips past a changes-requested issue and keeps
    going, which is precisely the behaviour this service's ordered barrier
    exists to prevent; with both enabled the barrier would appear to hold while
    the other process crossed it. It is never adopted, killed, or treated as
    this service (D-13), so the only safe answer is a diagnostic naming it so
    the operator can stop it.

    Ordinary contention is a different thing entirely and is not refused here:
    an interactive review or another queue pass holding the lock is the normal
    `busy` outcome the poll loop backs off on (requirement 13's last sentence).
    """
    owner = approval_lock_owner(repo_path)
    if owner is not None and is_legacy_daemon(owner):
        raise ServiceError(
            "Refusing to start the issue approval controller: the canonical "
            f"approval lock at {approval_lock_path(repo_path)} is held by "
            f"{describe_lock_owner(owner)}. Stop that daemon yourself; this "
            "service never adopts or terminates it."
        )


def describe_run_owner(owner: dict[str, Any]) -> str:
    """Where and what the controller already holding a run lock is."""
    pid = owner.get("pid")
    where = owner.get("repo")
    detail = f" (PID {pid})" if is_plain_integer(pid) else ""
    from_where = f" from {where}" if isinstance(where, str) and where else ""
    return f"{from_where}{detail}"


@contextlib.contextmanager
def held_exclusively(
    path: Path, job: ApprovalJob, refusal: Callable[[str], str]
) -> Iterator[None]:
    """Hold one non-blocking exclusive lock, or refuse with `refusal`.

    `refusal` is called with a description of the owner rather than
    interpolated into, so no repository path can be read as a format field.

    The losing contender closes without truncating, so it cannot erase the
    owner's own diagnostic metadata -- the discipline
    `approve_issues.acquire_lock` follows for the canonical lock.
    """
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        handle = open(path, "a+", encoding="utf-8")
    except OSError as exc:
        raise ServiceError(f"Could not open the run lock at {path}: {exc}") from exc
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
def run_lock(job: ApprovalJob) -> Iterator[None]:
    """Hold both of this run's exclusivity locks, or refuse.

    Only one `run` may own a canonical identity at a time. The backend's own
    approval lock cannot provide that guarantee, because the whole point of a
    bounded pass is that the lock is released between issues -- two controllers
    would simply take turns, interleaving their passes while both wrote a
    status document and both opened incidents.

    It takes two locks because one location cannot see both ways a second run
    arrives. The checkout lock lives in the repository's shared Git directory,
    so every invocation naming this checkout contends however its environment
    differs -- a different `$HOME`, a different install root, a linked
    worktree. The identity lock lives under this account's service root and is
    named by `owner/name`, so two *clones* of one GitHub repository contend
    even though they have two Git directories and would never meet in the
    first one.

    Both are non-blocking and taken in a fixed order, so a contended start
    fails immediately rather than waiting, and no two runs can deadlock.

    Taken before any status or incident is written, so a refused second run
    changes nothing the first run owns -- including a first run whose runtime
    is somewhere this one would never look.
    """
    with held_exclusively(
        checkout_lock_path(job.repo_path),
        job,
        lambda owner: (
            f"An issue approval controller for {job.identity} is already running "
            f"for the checkout at {job.repo_path}{owner}. One checkout runs one "
            "controller at a time."
        ),
    ):
        with held_exclusively(
            job.lock_path,
            job,
            lambda owner: (
                f"An issue approval controller for {job.identity} is already "
                f"running{owner}. One repository runs one controller at a time."
            ),
        ):
            yield


# ---------------------------------------------------------------------------
# The ordered barrier
# ---------------------------------------------------------------------------


def read_barrier(job: ApprovalJob) -> int | None:
    """The issue this repository's queue is barriered at, or None when it is
    verifiably not barriered.

    The barrier's authority lives in this document rather than in its warning
    incident, because an acknowledgement resolves the incident for
    bookkeeping and must not let the queue cross an issue that still has
    current changes-requested state (requirement 7). Only a current canonical
    approval of that issue removes this record.

    A record that is present but cannot be read as one raises. "Absent" and
    "unreadable" are different answers, and answering the second as the first
    is exactly how a durable barrier would be crossed by a restart.
    """
    if not os.path.lexists(job.barrier_path):
        return None
    document = read_json(job.barrier_path)
    if document is None:
        raise ServiceError(
            f"The barrier record at {job.barrier_path} could not be read; "
            "refusing to treat it as an unbarriered queue."
        )
    if document.get("schema") != BARRIER_SCHEMA or not pinned_version(
        document.get("version"), BARRIER_VERSION
    ):
        raise ServiceError(
            f"The barrier record at {job.barrier_path} has schema "
            f"{document.get('schema')!r} version {document.get('version')!r}, "
            f"not {BARRIER_SCHEMA!r} version {BARRIER_VERSION}."
        )
    if document.get("repository") != job.identity:
        raise ServiceError(
            f"The barrier record at {job.barrier_path} records repository "
            f"{document.get('repository')!r}, not {job.identity!r}."
        )
    issue = positive_issue(document.get("issue"))
    if issue is None:
        raise ServiceError(
            f"The barrier record at {job.barrier_path} names no positive issue "
            f"number: {document.get('issue')!r}."
        )
    return issue


def write_barrier(job: ApprovalJob, issue: int) -> None:
    atomic_write_json(
        job.barrier_path,
        {
            "schema": BARRIER_SCHEMA,
            "version": BARRIER_VERSION,
            "repository": job.identity,
            "repo": str(job.repo_path),
            "issue": issue,
            "opened_at": utc_stamp(),
        },
    )


def clear_barrier(job: ApprovalJob) -> None:
    with contextlib.suppress(FileNotFoundError):
        job.barrier_path.unlink()


# ---------------------------------------------------------------------------
# Incidents
# ---------------------------------------------------------------------------


def incident_documents(job: ApprovalJob, *, open_only: bool = False, kind: str | None = None) -> list[tuple[Path, dict[str, Any]]]:
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


def _new_incident_path(job: ApprovalJob, suffix: str) -> tuple[Path, str]:
    job.incident_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    base = time.strftime("incident-%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{os.getpid()}{suffix}"
    incident_id = base
    duplicate = 1
    while (job.incident_dir / f"{incident_id}.json").exists():
        duplicate += 1
        incident_id = f"{base}-{duplicate}"
    return job.incident_dir / f"{incident_id}.json", incident_id


def _write_incident(job: ApprovalJob, path: Path, document: dict[str, Any]) -> dict[str, Any]:
    document["path"] = str(path)
    atomic_write_json(path, document)
    return document


def barrier_summary(issue: int) -> str:
    """The exact wording the sidebar composes into
    `on · unresolved incident · <summary>` (D-8)."""
    return f"Issue #{issue} requests changes"


def ensure_barrier_incident(job: ApprovalJob, issue: int, message: str) -> dict[str, Any]:
    """The one open warning for this barrier, opened if there is none.

    Idempotent on (repository, kind, issue): a barrier that is polled every
    interval, and one that survives a restart, keep the incident they already
    have rather than accumulating one per poll (the review's incident-document
    addition). An acknowledged barrier that still has current
    changes-requested state gets a fresh warning on the next poll, which is
    what keeps an acknowledgement to bookkeeping.
    """
    for path, document in incident_documents(job, open_only=True, kind=BARRIER_INCIDENT_KIND):
        if positive_issue(document.get("issue")) == issue:
            updated = {"summary": barrier_summary(issue), "detail": message}
            if all(document.get(key) == value for key, value in updated.items()):
                return document
            document.update(updated)
            document["updated_at"] = utc_stamp()
            return _write_incident(job, path, document)
    path, incident_id = _new_incident_path(job, f"-issue{issue}")
    return _write_incident(
        job,
        path,
        {
            "schema": INCIDENT_SCHEMA,
            "version": INCIDENT_VERSION,
            "incident_id": incident_id,
            "kind": BARRIER_INCIDENT_KIND,
            "severity": SEVERITY_WARNING,
            "status": "open",
            "repository": job.identity,
            "repo": str(job.repo_path),
            "issue": issue,
            "summary": barrier_summary(issue),
            "detail": message,
            "occurred_at": utc_stamp(),
            "service_log": str(job.service_log_path),
        },
    )


def resolve_barrier_incidents(job: ApprovalJob, issue: int, note: str) -> list[dict[str, Any]]:
    resolved: list[dict[str, Any]] = []
    for path, document in incident_documents(job, open_only=True, kind=BARRIER_INCIDENT_KIND):
        if positive_issue(document.get("issue")) != issue:
            continue
        document["status"] = "resolved"
        document["resolved_at"] = utc_stamp()
        document["resolution"] = note
        resolved.append(_write_incident(job, path, document))
    return resolved


def record_error_incident(
    job: ApprovalJob,
    *,
    summary: str,
    detail: str | None,
    issue: int | None = None,
) -> dict[str, Any]:
    """Record that this run stopped on something it could not act on.

    Error severity, and never issue-scoped in the barrier's sense: a barrier is
    a healthy service waiting, while this is a run that ended.
    """
    path, incident_id = _new_incident_path(job, "-error")
    return _write_incident(
        job,
        path,
        {
            "schema": INCIDENT_SCHEMA,
            "version": INCIDENT_VERSION,
            "incident_id": incident_id,
            "kind": ERROR_INCIDENT_KIND,
            "severity": SEVERITY_ERROR,
            "status": "open",
            "repository": job.identity,
            "repo": str(job.repo_path),
            "issue": issue,
            "summary": summary,
            "detail": detail,
            "occurred_at": utc_stamp(),
            "service_log": str(job.service_log_path),
        },
    )


def acknowledge_incident(
    job: ApprovalJob, incident_id: str | None, note: str | None
) -> dict[str, Any]:
    """Dismiss one incident record for bookkeeping.

    Deliberately powerless over the queue: resolving a barrier's warning
    leaves the barrier record that actually stops the queue exactly where it
    was, so the next poll recreates the warning until the issue holds a current
    canonical approval (requirement 7).
    """
    if incident_id is not None:
        if not INCIDENT_ID_RE.fullmatch(incident_id):
            raise ServiceError(f"Invalid incident ID: {incident_id}")
        path = job.incident_dir / f"{incident_id}.json"
        document = read_json(path)
        if document is None or document.get("repository") != job.identity:
            raise ServiceError(f"No incident {incident_id} belongs to {job.identity}.")
        found = [(path, document)]
    else:
        found = incident_documents(job, open_only=True)
    if not found:
        raise ServiceError("There is no open incident to acknowledge.")
    path, document = found[0]
    document["status"] = "resolved"
    document["resolved_at"] = utc_stamp()
    if note:
        document["resolution"] = note
    return _write_incident(job, path, document)


# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------


def _classify_status(job: ApprovalJob, stored: dict[str, Any] | None, present: bool) -> tuple[str, str | None]:
    """The state a reader may believe, and why it is not the recorded one.

    Every way a stored document can fail to describe this service now -- absent,
    unreadable, another schema or version, another repository's, a state this
    reader does not know, or a live state whose runner is gone -- collapses to
    `unknown` with the reason named, because a reader that cannot tell those
    apart from "healthy" is a reader that reports a dead service as running.
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


def status_snapshot(job: ApprovalJob) -> dict[str, Any]:
    """This repository's approval service state, read and never repaired.

    Strictly read-only: no directory is created, no document is rewritten, and
    no incident is opened or resolved, because status is the diagnostic reached
    for when the runtime is already in a bad state and a reader that repairs
    what it reads destroys the evidence it was called to show.
    """
    present = os.path.lexists(job.status_path)
    stored = read_json(job.status_path) if present else None
    state, reason = _classify_status(job, stored, present)
    stored = stored or {}
    try:
        barrier: int | None = read_barrier(job)
        barrier_reason: str | None = None
    except ServiceError as exc:
        barrier, barrier_reason = None, str(exc)
        state, reason = STATE_UNKNOWN, str(exc)
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
        "runner_pid": stored.get("runner_pid") if state in LIVE_STATES else None,
        # Only while it is really there: a pass that has finished leaves its
        # PID recorded until the next write, and reporting that as a live
        # child would describe work nobody is doing.
        "backend_pid": (
            stored.get("backend_pid")
            if state in LIVE_STATES and pid_alive(stored.get("backend_pid"))
            else None
        ),
        "started_at": stored.get("started_at"),
        "updated_at": stored.get("updated_at"),
        "message": stored.get("message"),
        "last_outcome": stored.get("last_outcome"),
        # The durable barrier, independent of whether its warning was
        # acknowledged and of whether the service is running at all.
        "barrier_issue": barrier,
        "barrier_unreadable": barrier_reason,
        "open_incident": open_incidents[0] if open_incidents else None,
        "open_incidents": open_incidents,
        "status_path": str(job.status_path),
        "service_log": str(job.service_log_path),
    }


# ---------------------------------------------------------------------------
# Backend results
# ---------------------------------------------------------------------------


def parse_backend_result(stdout: str) -> dict[str, Any]:
    """The one result document a `--review-queue` pass wrote, or a
    `BackendFailure` naming what was wrong with it.

    Refuses a schema or version this controller was not built to read rather
    than guessing at its meaning (requirement 2), and refuses every shape whose
    fields it would go on to act on: an outcome it does not know reads as one
    it does, and a missing issue number on `changes_requested` would open a
    barrier against nothing.
    """
    text = stdout.strip()
    if not text:
        raise BackendFailure("The backend pass produced no result document.")
    try:
        document = json.loads(text)
    except json.JSONDecodeError as exc:
        raise BackendFailure(
            f"The backend pass produced no readable result document: {exc}"
        ) from exc
    if not isinstance(document, dict):
        raise BackendFailure(
            f"The backend result is not a JSON object: {type(document).__name__}."
        )
    if document.get("schema") != BACKEND_RESULT_SCHEMA:
        raise BackendFailure(
            f"The backend result has unknown schema {document.get('schema')!r}; "
            f"this controller reads {BACKEND_RESULT_SCHEMA!r} only."
        )
    version = document.get("version")
    if not pinned_version(version, BACKEND_RESULT_VERSION):
        raise BackendFailure(
            f"The backend result has unknown schema version {version!r}; this "
            f"controller reads version {BACKEND_RESULT_VERSION} only."
        )
    keys = set(document)
    missing = sorted(BACKEND_RESULT_FIELDS - keys)
    unexpected = sorted(keys - BACKEND_RESULT_FIELDS)
    if missing or unexpected:
        detail = "; ".join(
            part
            for part in (
                f"missing {', '.join(missing)}" if missing else "",
                f"unexpected {', '.join(unexpected)}" if unexpected else "",
            )
            if part
        )
        raise BackendFailure(f"The backend result has the wrong fields: {detail}.")
    outcome = document["outcome"]
    if outcome not in BACKEND_OUTCOMES:
        raise BackendFailure(f"The backend result has unknown outcome {outcome!r}.")
    issue = document["issue"]
    if outcome in BACKEND_ISSUE_OUTCOMES:
        if positive_issue(issue) is None:
            raise BackendFailure(
                f"The backend result outcome {outcome!r} names no positive issue "
                f"number: {issue!r}."
            )
    elif issue is not None:
        raise BackendFailure(
            f"The backend result outcome {outcome!r} must carry no issue number, "
            f"got {issue!r}."
        )
    if not isinstance(document["model_called"], bool):
        raise BackendFailure(
            f"The backend result model_called is not a Boolean: "
            f"{document['model_called']!r}."
        )
    message = document["message"]
    if not isinstance(message, str) or not message.strip():
        raise BackendFailure("The backend result carries no displayable message.")
    return document


def parse_gate_result(stdout: str, issue: int, exit_code: int) -> bool:
    """Whether the barrier issue now holds a current canonical approval.

    The gate's own two ordinary exits are the answer, and the document is held
    to agreeing with them: a check that exits approved while its document says
    otherwise is not an answer this controller may resume on.
    """
    try:
        document = json.loads(stdout) if stdout.strip() else None
    except json.JSONDecodeError as exc:
        raise BackendFailure(
            f"The gate check for issue #{issue} produced no readable result "
            f"document: {exc}"
        ) from exc
    if not isinstance(document, dict):
        raise BackendFailure(
            f"The gate check for issue #{issue} produced no readable result document."
        )
    approved = document.get("approved")
    if not isinstance(approved, bool):
        raise BackendFailure(
            f"The gate check for issue #{issue} reports no Boolean approval: "
            f"{approved!r}."
        )
    checked = document.get("issue")
    if checked is not None and checked != issue:
        raise BackendFailure(
            f"The gate check answered for issue #{checked!r}, not #{issue}."
        )
    if approved != (exit_code == GATE_APPROVED_EXIT):
        raise BackendFailure(
            f"The gate check for issue #{issue} exited {exit_code} but reports "
            f"approved={approved}."
        )
    return approved


def classify_exit(code: int) -> str:
    if code < 0:
        return f"{BACKEND_NAME} was terminated by signal {-code}"
    return f"{BACKEND_NAME} exited unexpectedly with code {code}"


def tail(text: str | None, lines: int = CAPTURED_STDERR_LINES) -> str | None:
    if not text:
        return None
    return "\n".join(text.splitlines()[-lines:]) or None


# ---------------------------------------------------------------------------
# The controller
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class PassCommand:
    """What one backend invocation produced: its argument vector, both captured
    streams, and its exit status."""

    argv: list[str]
    stdout: str
    stderr: str
    returncode: int


class Controller:
    """One `run`: repeated bounded backend passes and the durable trace of them.

    Strictly sequential. One pass is started, waited for, and classified before
    the next is considered, so two passes can never overlap and the backend
    keeps advancing at most one issue under each acquisition of the canonical
    lock (requirement 3).
    """

    def __init__(
        self,
        job: ApprovalJob,
        *,
        backend: Path,
        interval: float,
        legacy_policy: str,
    ) -> None:
        self.job = job
        self.backend = backend
        self.interval = interval
        self.legacy_policy = legacy_policy
        self.started_at = utc_stamp()
        self._child: subprocess.Popen[str] | None = None
        self._stop_requested = False
        self._signals = 0
        self._backoff_steps = 0
        self._last_outcome: str | None = None

    # -- lifecycle ---------------------------------------------------------

    def log(self, message: str) -> None:
        service_log(self.job, message)

    def handle_stop(self, _signum: int, _frame: Any) -> None:
        """Record the stop and pass it straight to the backend's process group.

        Forwarded to the group rather than to the child alone: the backend
        spawns `gh` and a reviewer model of its own, and signalling only the
        process this controller knows about is what leaves those orphaned
        (requirement 11). A second signal escalates, so an operator who asks
        twice is obeyed twice.

        A handler that finds no registered child is not a handler that missed
        one: `start_child` holds these signals across the spawn and rechecks
        the flag afterwards, so a stop landing around a `Popen` is delivered to
        that child by one side or the other.
        """
        self._stop_requested = True
        self._signals += 1
        forwarded = signal.SIGINT if self._signals == 1 else signal.SIGKILL
        self.signal_child_group(self._child, forwarded)

    def signal_child_group(
        self, child: subprocess.Popen[str] | None, forwarded: int
    ) -> None:
        """Signal one backend invocation's whole session, or nothing.

        A group whose last member is already gone raises ProcessLookupError,
        which is the ordinary case rather than a failure. Signalling a child
        this controller has already reaped is refused outright, since its PID
        may by then name something else entirely.
        """
        if child is None or child.poll() is not None:
            return
        with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
            os.killpg(child.pid, forwarded)


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

    def backoff_seconds(self) -> float:
        """The bounded wait a retryable completion earns.

        Doubles per consecutive retryable outcome and stops doubling at the
        ceiling, so a service that backs off never becomes a service that has
        quietly stopped polling.
        """
        return min(
            self.interval * (2**self._backoff_steps),
            self.interval * BACKOFF_CEILING_MULTIPLIER,
        )

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
            f"Starting the issue approval controller for {self.job.identity} "
            f"from {self.job.repo_path} using {self.backend}"
        )
        self.write_status(STATE_STARTING, message="Checking the approval queue.")
        try:
            while not self._stop_requested:
                barrier = read_barrier(self.job)
                if barrier is not None:
                    self.poll_barrier(barrier)
                    continue
                self.one_pass()
        except BackendFailure as failure:
            return self.record_failure(
                STATE_CHILD_FAILURE, failure.summary, failure.detail
            )
        except ServiceError as failure:
            return self.record_failure(STATE_CONTROLLER_FAILURE, str(failure), None)
        except Exception:
            return self.record_failure(
                STATE_CONTROLLER_FAILURE,
                "The issue approval controller failed unexpectedly.",
                traceback.format_exc(),
            )
        # Only reachable by the stop flag, and only from between passes or from
        # a pass this controller itself signalled, so nothing here may claim
        # work continued past the stop.
        self.log("The issue approval controller stopped intentionally.")
        self.write_status(
            STATE_STOPPED,
            message="Stopped intentionally.",
            barrier_issue=self.current_barrier_for_status(),
        )
        return 0

    def record_failure(self, state: str, summary: str, detail: str | None) -> int:
        self.log(f"The issue approval controller stopped: {summary}")
        try:
            incident = record_error_incident(
                self.job, summary=summary, detail=detail
            )
            self.log(f"Recorded incident {incident['incident_id']} at {incident['path']}")
        except OSError as exc:
            self.log(f"Additionally failed to record the incident: {exc}")
        self.write_status(
            state, message=summary, barrier_issue=self.current_barrier_for_status()
        )
        return 1

    def current_barrier_for_status(self) -> int | None:
        """The barrier a terminal status document should carry, or None when it
        cannot be read -- a terminal write must never be the thing that fails."""
        try:
            return read_barrier(self.job)
        except ServiceError:
            return None

    # -- durable state -----------------------------------------------------

    def write_status(
        self,
        state: str,
        *,
        message: str,
        barrier_issue: int | None = None,
        backend_pid: int | None = None,
    ) -> None:
        atomic_write_json(
            self.job.status_path,
            {
                "schema": STATUS_SCHEMA,
                "version": STATUS_VERSION,
                "state": state,
                "repository": self.job.identity,
                "repo": str(self.job.repo_path),
                # The ownership a reader needs to reject a stale observation:
                # a live state recorded under a runner that is gone is not a
                # running service.
                "runner_pid": os.getpid(),
                "backend_pid": backend_pid,
                "barrier_issue": barrier_issue,
                "message": message,
                "last_outcome": self._last_outcome,
                "started_at": self.started_at,
                "updated_at": utc_stamp(),
                "backend": str(self.backend),
                "service_log": str(self.job.service_log_path),
            },
        )

    # -- backend invocation ------------------------------------------------

    def backend_argv(self, *arguments: str) -> list[str]:
        """What one backend invocation runs.

        `--repo` carries the identity every path of this service is partitioned
        by, so the backend acts on the repository this runtime describes rather
        than re-deriving one from the checkout. `--log-dir` puts the backend's
        own dated logs in this repository's log directory, beside the
        controller's `service.log`, which is what keeps two repositories' logs
        apart. `--incident-dir` is deliberately left at its default: that
        circuit breaker is shared with Kanban's own `r` action, and redirecting
        it here would let this service cross an incident the dashboard is
        halted by.
        """
        argv = [
            python_executable(),
            str(self.backend),
            "--path",
            str(self.job.repo_path),
            "--repo",
            self.job.identity,
            "--legacy-policy",
            self.legacy_policy,
            "--log-dir",
            str(self.job.log_dir),
            "--json",
            *arguments,
        ]
        if self.job.config_path:
            argv.extend(["--config", self.job.config_path])
        return argv

    def start_child(self, argv: list[str]) -> subprocess.Popen[str] | None:
        """Spawn one backend invocation, or nothing at all when a stop is
        already pending.

        A stop must never leave a live `--review-queue` pass -- model calls,
        GitHub mutations and all -- running behind a controller that has
        already recorded an intentional stop. Two reads of the flag around the
        spawn are what guarantee that, and between them they leave no window:

        * the read before the spawn means an already-requested stop starts
          nothing at all;
        * a stop arriving from there until the child is registered finds
          `_child` unset, so the handler signals nothing -- and the read after
          the registration sees the flag and signals the group itself;
        * a stop arriving after that read finds `_child` set, so the handler
          signals the group.

        Nothing is masked to achieve that, deliberately. A signal mask held
        across `Popen` is inherited by the child and survives its `exec`, which
        would leave every backend pass running with the very signals its
        process group is stopped with blocked.

        `start_new_session` is what makes any of this able to end the whole
        tree rather than the one process this controller can see: the backend
        spawns `gh` and a reviewer model, and a signal delivered to the child
        alone would leave those running (requirement 11).
        """
        if self._stop_requested:
            self.log("A stop arrived before this pass began; nothing was started.")
            return None
        child = subprocess.Popen(
            argv,
            cwd=str(self.job.repo_path),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            # Registered before the flag is read again, so the two reads
            # overlap rather than leaving a gap between them.
            self._child = child
            if self._stop_requested:
                self.log(
                    "A stop raced this pass's start; signalling the backend it spawned."
                )
                self.signal_child_group(child, signal.SIGINT)
        except BaseException:
            self._child = None
            self.abandon_child(child)
            raise
        return child

    def abandon_child(self, child: subprocess.Popen[str]) -> None:
        """End a pass nothing will be left to supervise.

        Reached when a step after the spawn fails. The run is about to record
        a controller failure and release the per-identity run lock, and a
        backend still alive past that point keeps making model calls and
        GitHub mutations with nothing watching it -- and can then be overlapped
        by the very next controller the released lock admits, which is the one
        thing that lock exists to prevent.

        Asked politely first and reaped either way, so the failure this is
        clearing up after cannot be replaced by a wait that never returns.
        Nothing here re-raises: the original failure is the one worth
        reporting.
        """
        self.signal_child_group(child, signal.SIGINT)
        try:
            child.wait(timeout=STOP_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            self.terminate_process_group(child)
            with contextlib.suppress(subprocess.TimeoutExpired):
                child.wait(timeout=STOP_GRACE_SECONDS)
        # Whatever the backend started and did not reap goes with it.
        self.terminate_process_group(child)
        with contextlib.suppress(OSError):
            self.log(
                "A pass could not be supervised to completion; its backend process "
                "group was ended."
            )

    def spawn(
        self,
        argv: list[str],
        *,
        state: str,
        message: str,
        barrier_issue: int | None = None,
    ) -> PassCommand | None:
        """One backend invocation and what it produced, or None when a pending
        stop meant none was started.

        The backend's own diagnostics are captured rather than inherited so a
        failed pass can carry them into its incident; `--json` already keeps
        them off the stdout this parses.
        """
        child = self.start_child(argv)
        if child is None:
            return None
        try:
            self.write_status(
                state,
                message=message,
                barrier_issue=barrier_issue,
                backend_pid=child.pid,
            )
            stdout, stderr = self.wait_for(child)
        except BaseException:
            # Every exceptional exit from here, not only an intentional stop:
            # a status write that fails and a wait that raises both end this
            # run, and neither may leave the pass running behind it.
            self._child = None
            self.abandon_child(child)
            raise
        finally:
            self._child = None
            if self._stop_requested:
                self.terminate_process_group(child)
        return PassCommand(argv, stdout or "", stderr or "", child.returncode)

    def wait_for(self, child: subprocess.Popen[str]) -> tuple[str, str]:
        """Collect the invocation's output, escalating a stop it does not obey.

        Waited for in bounded slices rather than in one unbounded call, because
        a signal handler that does not raise leaves the wait to resume (PEP
        475): once a stop has been requested, this needs to come back and
        decide whether the group is taking too long. Retrying `communicate`
        after a timeout is the documented way to do that and loses no output.

        The escalation exists so an intentional stop really ends: the handler
        asks the group politely, and a group that has not gone in
        `STOP_GRACE_SECONDS` is killed outright rather than left holding the
        canonical approval lock.
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
                        f"The backend did not stop within {STOP_GRACE_SECONDS:g}s; "
                        "killing its process group."
                    )
                    self.terminate_process_group(child)
                    deadline = time.monotonic() + STOP_GRACE_SECONDS

    def terminate_process_group(self, child: subprocess.Popen[str]) -> None:
        """Leave nothing of this invocation's session behind.

        Reached only on an intentional stop, which is the transition
        requirement 11 makes this promise for, and where anything the backend
        started and did not reap would otherwise keep running. Signalling a
        group whose last member is already gone raises ProcessLookupError,
        which is the ordinary case rather than a failure.
        """
        with contextlib.suppress(ProcessLookupError, PermissionError, OSError):
            os.killpg(child.pid, signal.SIGKILL)

    def suppressed_by_stop(self, what: str) -> bool:
        """Whether an unusable pass result is this controller's own doing.

        A pass this controller signalled did not decide anything, so treating
        its exit or its truncated output as a backend failure would record an
        intentional stop as one. A pass that *completed* is never suppressed
        this way -- see `one_pass` -- because work that really happened must
        not be reported as work that did not.
        """
        if not self._stop_requested:
            return False
        self.log(f"{what} was interrupted by the stop; recording no verdict for it.")
        return True

    # -- passes ------------------------------------------------------------

    def one_pass(self) -> None:
        """One `--review-queue` invocation, classified.

        A stop is handled by what the pass actually produced rather than by
        when it arrived. An interrupted pass decided nothing, so it is
        recorded as nothing. A pass that had already exited cleanly with a
        complete result really did what that result says -- it may have
        published a verdict and moved a label -- so it is dispatched even on
        the way out. Discarding it would be the stop claiming that nothing
        happened when something did.
        """
        command = self.spawn(
            self.backend_argv("--review-queue"),
            state=STATE_RUNNING,
            message="Advancing the approval queue.",
        )
        if command is None:
            return
        if command.returncode != 0:
            if self.suppressed_by_stop("The backend pass"):
                return
            raise BackendFailure(classify_exit(command.returncode), tail(command.stderr))
        try:
            result = parse_backend_result(command.stdout)
        except BackendFailure as failure:
            if self.suppressed_by_stop("The backend pass"):
                return
            raise BackendFailure(failure.summary, tail(command.stderr)) from failure
        self.dispatch(result)

    def dispatch(self, result: dict[str, Any]) -> None:
        outcome = result["outcome"]
        message = result["message"]
        self._last_outcome = outcome
        self.log(f"Backend pass returned {outcome}: {message}")
        if outcome == "changes_requested":
            self.open_barrier(result["issue"], message)
            return
        if outcome in {"busy", "retry"}:
            # Ordinary retryable completions, not failures: nothing was left
            # half-done, so this waits longer and asks again rather than
            # recording an error incident. `busy` in particular is the backend
            # reporting normal contention for the canonical lock, and the
            # message it carries names the owner.
            wait = self.backoff_seconds()
            self._backoff_steps += 1
            self.write_status(STATE_RUNNING, message=message)
            self.sleep(wait)
            return
        self._backoff_steps = 0
        self.write_status(STATE_RUNNING, message=message)
        # `advanced` proceeds promptly; `idle` waits the ordinary interval.
        self.sleep(ADVANCE_DELAY_SECONDS if outcome == "advanced" else self.interval)

    def open_barrier(self, issue: int, message: str) -> None:
        write_barrier(self.job, issue)
        self._backoff_steps = 0
        incident = ensure_barrier_incident(self.job, issue, message)
        self.log(
            f"Ordered barrier at issue #{issue}; incident {incident['incident_id']}"
        )
        self.write_status(
            STATE_BARRIER, message=barrier_summary(issue), barrier_issue=issue
        )

    def poll_barrier(self, issue: int) -> None:
        """One read-only check of the barrier issue, and nothing else.

        No model work, no review, and above all no `--review-queue` pass: the
        gate check mutates nothing on GitHub, so a barriered service cannot
        reach any issue at all, let alone a higher-numbered one (requirement 5).

        `last_outcome` is deliberately left alone: it records what the backend
        last decided, and a gate check decides nothing about the queue. The
        barrier itself is already reported by the state and the issue number.
        """
        command = self.spawn(
            self.backend_argv("--check", str(issue)),
            state=STATE_BARRIER,
            message=barrier_summary(issue),
            barrier_issue=issue,
        )
        if command is None:
            return
        if command.returncode not in (GATE_APPROVED_EXIT, GATE_REFUSED_EXIT):
            if self.suppressed_by_stop(f"The gate check for issue #{issue}"):
                return
            raise BackendFailure(
                f"The gate check for issue #{issue} failed with exit code "
                f"{command.returncode}.",
                tail(command.stderr),
            )
        try:
            approved = parse_gate_result(command.stdout, issue, command.returncode)
        except BackendFailure as failure:
            if self.suppressed_by_stop(f"The gate check for issue #{issue}"):
                return
            raise BackendFailure(failure.summary, tail(command.stderr)) from failure
        if not approved:
            # Recreated when an acknowledgement dismissed it: the barrier
            # record is the authority, so the warning follows it rather than
            # the other way round.
            ensure_barrier_incident(self.job, issue, barrier_summary(issue))
            self.write_status(
                STATE_BARRIER, message=barrier_summary(issue), barrier_issue=issue
            )
            self.sleep(self.interval)
            return
        clear_barrier(self.job)
        resolved = resolve_barrier_incidents(
            self.job, issue, f"Issue #{issue} holds a current canonical approval."
        )
        self.log(
            f"Issue #{issue} is approved; cleared the barrier and resolved "
            f"{len(resolved)} incident(s)."
        )
        self.write_status(
            STATE_RUNNING, message=f"Issue #{issue} is approved; resuming the queue."
        )


def run_service(job: ApprovalJob, *, interval: float, legacy_policy: str) -> int:
    """Start one controller for this repository, or refuse before it writes.

    The refusals are ordered by what they protect. The host check comes first
    because a host that cannot supervise a process group cannot run this at
    all. The backend is resolved next, so a misresolved installation fails
    before any durable state exists rather than after. The run lock is third,
    so a second run for one identity is refused without touching the first
    run's status or incidents. The legacy-daemon check is last of the four,
    because it is about the canonical lock rather than about this service's own
    state.
    """
    require_supported_host()
    backend = resolve_backend()
    with run_lock(job):
        require_no_legacy_daemon(job.repo_path)
        return Controller(
            job, backend=backend, interval=interval, legacy_policy=legacy_policy
        ).run()


def print_value(value: Any, *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(value, indent=2, sort_keys=True))
        return
    if isinstance(value, dict):
        for key, item in value.items():
            rendered = (
                json.dumps(item, sort_keys=True) if isinstance(item, (dict, list)) else str(item)
            )
            print(f"{key}: {rendered}")
    else:
        print(value)


def poll_interval(value: str) -> float:
    try:
        seconds = float(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("the interval must be a number of seconds") from exc
    if seconds < 0:
        raise argparse.ArgumentTypeError("the interval must not be negative")
    return seconds


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Supervise repeated bounded passes of the canonical issue-review "
            "backend's queue mode for one repository, with durable per-identity "
            "status, incidents, and logs. This slice installs no service-manager "
            "job: `run` is an ordinary foreground process."
        )
    )
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON.")
    parser.add_argument(
        "--path",
        default=".",
        help="Repository path this invocation is about (default: current directory).",
    )
    parser.add_argument(
        "--repo",
        help=(
            "OWNER/NAME the caller believes --path is a checkout of. Refused when "
            "it names a different repository than the checkout's remote does."
        ),
    )
    parser.add_argument(
        "--config",
        default=None,
        help="Path to kanban's config.toml (default: ~/.config/kanban/config.toml).",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser(
        "run", help="Supervise repeated backend passes in the foreground."
    )
    run_parser.add_argument(
        "--interval",
        type=poll_interval,
        default=DEFAULT_INTERVAL_SECONDS,
        help=(
            "Seconds to wait after an idle pass or a barrier check, and the base "
            f"of the bounded backoff (default: {DEFAULT_INTERVAL_SECONDS:g})."
        ),
    )
    run_parser.add_argument(
        "--legacy-policy",
        choices=["dual", "hold"],
        default="dual",
        help="Forwarded to the backend for issues with no provenance marker.",
    )

    subparsers.add_parser(
        "status", help="Report the durable state without changing it."
    )

    # Requirement 7's bookkeeping dismissal. It is deliberately not a control:
    # resolving a barrier's warning leaves the barrier record that stops the
    # queue exactly where it is.
    ack_parser = subparsers.add_parser(
        "ack", help="Mark one incident record resolved, without moving the queue."
    )
    ack_parser.add_argument("incident_id", nargs="?")
    ack_parser.add_argument("--note")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        repo_path = Path(args.path).expanduser().resolve()
        if not (repo_path / ".git").exists():
            raise ServiceError(f"Repository path has no .git entry: {repo_path}")
        job = resolve_job(repo_path, config_path=args.config)
        require_requested_identity(job, args.repo)
        if args.command == "run":
            return run_service(
                job, interval=args.interval, legacy_policy=args.legacy_policy
            )
        if args.command == "status":
            value: Any = status_snapshot(job)
        elif args.command == "ack":
            value = acknowledge_incident(job, args.incident_id, args.note)
        else:
            raise ServiceError(f"Unknown command: {args.command}")
        print_value(value, as_json=args.json)
        return 0
    except (ServiceError, kanban_config.KanbanConfigError, OSError) as exc:
        if args.json:
            print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        else:
            print(f"approve_issues_service.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
