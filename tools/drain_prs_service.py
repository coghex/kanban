#!/usr/bin/env python3

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.request
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import kanban_config


# This module writes the plists, so it also owns the labels they are named and
# targeted by. Nothing else may restate one: `tools/install_drainer.py` builds
# them through this module, and `src/Kanban/Drainer.hs` derives none at all —
# it reads an installed job's label and plist path out of the per-repository
# record under DISCOVERY_RECORD_PATH below.
#
# There is one label, and one of every mutable runtime path, per canonical
# GitHub repository: that partitioning is what lets several repositories be
# drained independently on one account. LABEL_PREFIX on its own is the
# machine-wide singleton those replace; it survives only as the legacy job
# `retire_legacy_job` unloads before a derived job for the same repository is
# allowed to start.
LABEL_PREFIX = "com.coghex.drain-prs"
LEGACY_LABEL = LABEL_PREFIX
HOME = Path.home()
LAUNCH_AGENTS_DIR = HOME / "Library" / "LaunchAgents"
LEGACY_PLIST_PATH = LAUNCH_AGENTS_DIR / f"{LEGACY_LABEL}.plist"
# The record Kanban reads to find those jobs. Its location is fixed rather than
# INSTALL_DIR-relative on purpose: a dashboard that never inherits
# KANBAN_DRAINER_INSTALL_DIR still has to discover an install made with
# --install-dir, so the record's own path is the one thing that cannot move.
DISCOVERY_RECORD_PATH = Path(
    f"{HOME}/Library/Application Support/kanban/pr-drainer/config.json"
)
DEFAULT_INSTALL_DIR = DISCOVERY_RECORD_PATH.parent
INSTALL_DIR = Path(
    os.environ.get("KANBAN_DRAINER_INSTALL_DIR", DEFAULT_INSTALL_DIR)
).expanduser()
CONTROLLER_PATH = INSTALL_DIR / "drain_prs_service.py"
DRAINER_PATH = INSTALL_DIR / "drain_prs.py"
# One document, at that same fixed location, carries both the installer's keys
# and every repository's discovery record: --install-dir relocates the script
# links and the runtime state, not the file Kanban and this service both have
# to resolve without an environment override.
CONFIG_PATH = DISCOVERY_RECORD_PATH
# Where a --install-dir install made before that consolidation left them. The
# installer migrates this copy on its next run; until then it is still read.
LEGACY_CONFIG_PATH = INSTALL_DIR / "config.json"
# The roots the per-repository log and runtime directories hang off. The
# singleton wrote its own state directly into these; a derived job never does.
LOG_ROOT = HOME / "Library" / "Logs" / "kanban" / "pr-drainer"
RUNTIME_ROOT = INSTALL_DIR / "runtime"
# The key every repository's record, label, and runtime directory is filed
# under in the shared document.
RECORD_REPOSITORIES_KEY = "repositories"
# Long enough for every GitHub owner/name pair spelled with ordinary
# characters, short enough that `<label>.plist` stays well inside the 255-byte
# filename limit even after escaping. See `repository_slug`.
MAX_LABEL_LENGTH = 180


def _read_json_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _read_service_config() -> dict[str, Any]:
    """The shared document, with any pre-consolidation --install-dir copy read
    underneath it. The installer folds that copy in on its next run, but a
    custom install upgraded before that run must not silently lose its
    notification endpoint in the meantime, so it is still honoured here."""
    configured = _read_json_object(CONFIG_PATH)
    if LEGACY_CONFIG_PATH == CONFIG_PATH:
        return configured
    legacy = _read_json_object(LEGACY_CONFIG_PATH)
    legacy.update(configured)
    return legacy


def configured_ntfy_url() -> str | None:
    environment_url = os.environ.get("KANBAN_DRAINER_NTFY_URL")
    if environment_url:
        return environment_url
    configured = _read_service_config().get("ntfy_url")
    return configured if isinstance(configured, str) and configured else None


def installed_repository_records() -> dict[str, dict[str, Any]]:
    """Every installed repository's record, keyed by normalized identity.

    A separate entry per repository is the whole point: installing or
    refreshing one repository must leave every other repository's label, plist
    metadata, runtime and log locations, and configuration selection exactly as
    they were.
    """
    records = _read_service_config().get(RECORD_REPOSITORIES_KEY)
    if not isinstance(records, dict):
        return {}
    return {
        identity: record
        for identity, record in records.items()
        if isinstance(identity, str) and isinstance(record, dict)
    }


def installed_repository_record(identity: str) -> dict[str, Any]:
    return installed_repository_records().get(identity, {})


def configured_config_path(identity: str) -> str | None:
    """The kanban config.toml this repository's drainer was installed with.

    Read only out of that repository's own record. The pre-#147 installs wrote
    one shared scalar, which is deliberately not consulted as a fallback: it
    would make a later `--config` install for a second repository silently
    change the configuration an earlier repository's drainer restarts with,
    which is exactly the coupling per-repository records exist to break. A
    repository with no override runs on the normal shared Kanban default;
    `docs/pr-drainer.md` documents re-passing `--config` per repository as part
    of the migration.
    """
    configured = installed_repository_record(identity).get("config_path")
    return configured if isinstance(configured, str) and configured else None


def configured_remote_name(config_path: str | None) -> str:
    try:
        raw_config, _ = kanban_config.load_raw_config(config_path)
    except kanban_config.KanbanConfigError:
        return "origin"
    return raw_config.remote_name


NTFY_URL = configured_ntfy_url()
# Incident kinds. A crash incident says the drainer process died; a conflict
# incident says a healthy drainer stopped working one pull request; a cleanup
# incident says a merge landed but its post-merge obligations keep failing.
# They have different payloads and different lifecycles, so every selector
# filters on this field. Incidents written before the field existed are
# crashes. Only the crash kind means the drainer is not running: the other two
# are raised by a healthy drainer that keeps draining every other pull request.
CRASH_INCIDENT_KIND = "drainer-exit"
CONFLICT_INCIDENT_KIND = "merge-conflict"
CLEANUP_INCIDENT_KIND = "cleanup-pending"
CONFLICT_SUMMARY_FILES = 3
CLEANUP_SUMMARY_STEPS = 3
INTERVAL_SECONDS = 60
START_TIMEOUT_SECONDS = 12
START_STABILITY_SECONDS = 1.0
STOP_TIMEOUT_SECONDS = 20
NTFY_ATTEMPTS = 3


class ServiceError(RuntimeError):
    pass


def _escape_identity_segment(segment: str) -> str:
    """Encodes one identity segment into `[A-Za-z0-9_-]`, reversibly.

    `-` is the escape character and always consumes exactly one following
    character, so the encoding is a prefix code and therefore injective: `-`
    encodes as `--` and `.` as `-d`, and nothing else in the GitHub identity
    charset `[A-Za-z0-9._-]` needs escaping. `.` never survives into the
    output, which is what lets the label keep it as the owner/name separator.
    """
    escapes = {"-": "--", ".": "-d"}
    return "".join(escapes.get(character, character) for character in segment)


def repository_slug(identity: str) -> str:
    """A launchd- and filename-safe name for one normalized identity.

    Total, nonempty, and injective across distinct normalized identities:
    each segment is escaped into an alphabet that excludes `.`, so the single
    `.` in the result is unambiguously the owner/name separator, and the escape
    itself is reversible. Case-only spellings never reach here as distinct
    values — `normalize_identity` folded them together first — which is what
    stops two clones of one GitHub repository from naming two drainers.

    Escaping can double a segment's length, so an identity spelled almost
    entirely in separators could outgrow the 255-byte limit on the plist's
    filename. Those fall back to a hash of the whole identity, which cannot
    collide with an escaped slug because it contains no `.` at all.
    """
    owner, _, name = identity.partition("/")
    slug = f"{_escape_identity_segment(owner)}.{_escape_identity_segment(name)}"
    if len(LABEL_PREFIX) + 1 + len(slug) > MAX_LABEL_LENGTH:
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
class DrainerJob:
    """One repository's drainer: its identity, its launchd job, and every
    mutable path that belongs to it alone.

    Built once per invocation and threaded through, so no two code paths can
    derive a different label or status file for the same repository. Every
    field except `repo_path` is a function of `identity`, which is why a second
    checkout of the same GitHub repository resolves to this same job rather
    than to a second one.
    """

    repo_path: Path
    identity: str
    slug: str
    label: str
    plist_path: Path
    runtime_dir: Path
    incident_dir: Path
    status_path: Path
    log_dir: Path
    service_log_path: Path
    service_out_path: Path
    service_err_path: Path
    config_path: str | None
    remote_name: str


def _job(
    repo_path: Path,
    *,
    identity: str,
    slug: str,
    label: str,
    plist_path: Path,
    runtime_dir: Path,
    log_dir: Path,
    config_path: str | None,
    remote_name: str,
) -> DrainerJob:
    return DrainerJob(
        repo_path=repo_path,
        identity=identity,
        slug=slug,
        label=label,
        plist_path=plist_path,
        runtime_dir=runtime_dir,
        incident_dir=runtime_dir / "incidents",
        status_path=runtime_dir / "status.json",
        log_dir=log_dir,
        service_log_path=log_dir / "service.log",
        service_out_path=log_dir / "service.out",
        service_err_path=log_dir / "service.err",
        config_path=config_path,
        remote_name=remote_name,
    )


def discovery_remote_name() -> str:
    """The remote a drainer's *identity* is resolved through.

    Always the shared Kanban configuration's, never a repository's own
    `--config`, and that is load-bearing in two directions. It is the remote
    Kanban itself resolves its repository through, so both sides name the same
    identity and agree on which record describes this repository's job. And it
    breaks a circularity that would otherwise be unresolvable: a repository's
    `--config` lives in the record its identity selects, so a `--config` that
    named a different remote would decide an identity that had already been
    used to find it — the installer and the installed controller would resolve
    two different repositories from one checkout, and the install would abort
    on its own identity assertion.

    A repository's `--config` still decides what its drainer runs with,
    including the remote `require_default_branch` and `drain_prs.py` use. It
    decides which repository the job is *for* only through this shared
    configuration.
    """
    return configured_remote_name(None)


def repository_identity(repo_path: Path, remote_name: str) -> str:
    """The canonical GitHub repository this checkout is a clone of.

    Fails closed. A checkout whose remote does not name a repository on
    github.com has no drainer identity, so it can neither install nor control
    one — deriving a label from an unsupported value would invent an identity
    Kanban's own resolver would never agree with.
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
            f"cannot install or control a PR drainer: {exc}"
        ) from exc


def job_for_identity(
    repo_path: Path,
    identity: str,
    *,
    config_path: str | None = None,
    remote_name: str = "origin",
) -> DrainerJob:
    """The job one normalized identity names, from that identity alone.

    Every label and path below is a function of the identity, which is what
    makes two checkouts of one GitHub repository resolve to the same job — and
    two different repositories to jobs that share nothing.
    """
    slug = repository_slug(identity)
    return _job(
        repo_path,
        identity=identity,
        slug=slug,
        label=f"{LABEL_PREFIX}.{slug}",
        plist_path=LAUNCH_AGENTS_DIR / f"{LABEL_PREFIX}.{slug}.plist",
        runtime_dir=RUNTIME_ROOT / slug,
        log_dir=LOG_ROOT / slug,
        config_path=config_path,
        remote_name=remote_name,
    )


def resolve_job(repo_path: Path) -> DrainerJob:
    """This checkout's drainer job, resolved through its canonical identity.

    One pass, in a fixed order: `discovery_remote_name` decides the identity,
    the identity selects the record, and the record supplies the `--config`
    this repository's drainer runs with — including the remote name that
    configuration names. Nothing later in that order can change anything
    earlier, so every caller resolving the same checkout resolves the same
    job, whatever it has been configured with.
    """
    identity = repository_identity(repo_path, discovery_remote_name())
    config_path = configured_config_path(identity)
    return job_for_identity(
        repo_path,
        identity,
        config_path=config_path,
        remote_name=configured_remote_name(config_path),
    )


def unmanaged_job(repo_path: Path) -> DrainerJob:
    """The singleton's own unpartitioned surface, for a checkout that has no
    canonical GitHub identity.

    Such a checkout cannot install or control a drainer at all, so this never
    names a job launchd runs. It exists because `drain_prs.py` also runs
    standalone — `--pr <number>` against a fixture whose remote is a plain
    local path — and still records conflict and cleanup incidents. Those land
    where the singleton always put them, which by construction can never be any
    repository's partition.
    """
    return _job(
        repo_path,
        identity="",
        slug="",
        label=LEGACY_LABEL,
        plist_path=LEGACY_PLIST_PATH,
        runtime_dir=RUNTIME_ROOT,
        log_dir=LOG_ROOT,
        config_path=None,
        remote_name=discovery_remote_name(),
    )


def incident_job(repo_path: Path) -> DrainerJob:
    """The job whose incident directory this checkout writes to, resolved
    leniently: `drain_prs.py` records incidents in both its managed and its
    standalone mode, and only the managed one is guaranteed an identity."""
    try:
        return resolve_job(repo_path)
    except ServiceError:
        return unmanaged_job(repo_path)


def require_requested_identity(job: DrainerJob, requested: str | None) -> None:
    """Refuses a caller whose repository is not the one this job is for.

    Kanban resolves the board's repository through its own configuration —
    `--repo OWNER/NAME` outright, or the remote a `--config` names — and passes
    the result here. Anything but this job's own identity is refused, including
    another remote of this same checkout: a fork's upstream is a different
    canonical repository, and quietly acting on the origin job while the
    dashboard is for the upstream one is precisely the divergence per-repository
    identities exist to prevent.

    So the two sides have to agree rather than accommodate each other, and the
    message says which configuration to change. Aligning them is a real repair:
    the identity comes from `discovery_remote_name`, so setting `remote_name` in
    the shared Kanban configuration moves the dashboard and this job together.
    """
    if requested is None:
        return
    wanted = normalize_identity(requested)
    if wanted != job.identity:
        raise ServiceError(
            f"--repo {requested} names {wanted}, but {job.repo_path} is a checkout of "
            f"{job.identity}; refusing to control another repository's drainer. "
            "Restore remote_name in the shared Kanban configuration, or re-run "
            "tools/install_drainer.py to install a job for the repository it now names."
        )


def requested_job(repo_path: Path, requested: str | None, fallback: DrainerJob) -> DrainerJob:
    """The job the *caller* believes it is addressing.

    Its paths are a pure function of the identity, so this reconstructs the
    installed job's log directory even when the checkout no longer resolves to
    that identity — which is exactly when a refusal has to be readable, since
    launchd's stdout and stderr, and `logs`, all still point there.
    """
    if requested is None:
        return fallback
    try:
        return job_for_identity(repo_path, normalize_identity(requested))
    except ServiceError:
        return fallback


def utc_stamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def local_stamp() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def ensure_dirs(job: DrainerJob) -> None:
    for path in (INSTALL_DIR, job.runtime_dir, job.incident_dir, job.log_dir):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.chmod(0o700)
    job.plist_path.parent.mkdir(parents=True, exist_ok=True)


def service_log(job: DrainerJob, message: str) -> None:
    ensure_dirs(job)
    line = f"[{local_stamp()}] {message}"
    with job.service_log_path.open("a", encoding="utf-8") as handle:
        handle.write(line + "\n")
    print(line, flush=True)


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
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


@contextlib.contextmanager
def document_lock(path: Path) -> Iterator[None]:
    """Serializes read-modify-write on a shared JSON document.

    The discovery record is the one document several repositories write to, and
    every install *and every start* refreshes an entry in it. Without this,
    two dashboards starting drainers for different repositories can both read
    the table, and whichever replaces it last silently drops the other's
    entry — leaving a repository whose drainer is running with no record for
    Kanban to find it through. The lock lives beside the document rather than
    on it because the document is replaced atomically, which would drop a lock
    held on the old inode.
    """
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    lock_path = path.with_name(path.name + ".lock")
    try:
        descriptor = os.open(
            lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600
        )
    except OSError as exc:
        raise ServiceError(f"Refusing unsafe config lock path: {lock_path}") from exc
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
    cannot lose either party's change."""
    with document_lock(path):
        if os.path.lexists(path) and (path.is_symlink() or not path.is_file()):
            raise ServiceError(f"Refusing unsafe config path: {path}")
        existing: dict[str, Any] = {}
        if path.is_file():
            try:
                loaded = json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                loaded = None
            if isinstance(loaded, dict):
                existing = loaded
        updated = transform(existing)
        fd, temporary_name = tempfile.mkstemp(prefix=".config.", dir=path.parent)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(updated, handle, indent=2)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            temporary.chmod(0o600)
            os.replace(temporary, path)
        finally:
            if os.path.lexists(temporary):
                temporary.unlink()
    return path


def merge_json_document(path: Path, updates: dict[str, Any]) -> Path:
    """Merge `updates` into the private JSON object at `path` rather than
    overwriting it, so a writer that sets one key does not delete a key
    persisted by another. `tools/install_drainer.py` writes `ntfy_url` into the
    same document this module records installed LaunchAgents in, and either may
    run without the other."""

    def merged(document: dict[str, Any]) -> dict[str, Any]:
        return {**document, **updates}

    return update_json_document(path, merged)


def merge_repository_record(identity: str, updates: dict[str, Any]) -> Path:
    """Merge `updates` into one repository's entry under the shared document's
    `repositories` table, leaving every sibling entry and every top-level key
    untouched.

    Two levels of merge, not one: replacing the value of each key given would
    hand over a `repositories` table built from `updates` alone, deleting every
    other installed repository. The entry itself is merged for the same reason
    one level down — the installer writes `config_path` and the controller
    writes the label and plist path, and either may run without the other.

    The read that computes the merge happens inside `update_json_document`'s
    lock, so a repository installed between another writer's read and its write
    cannot be dropped.
    """

    def merged(document: dict[str, Any]) -> dict[str, Any]:
        records = document.get(RECORD_REPOSITORIES_KEY)
        records = dict(records) if isinstance(records, dict) else {}
        existing = records.get(identity)
        entry = dict(existing) if isinstance(existing, dict) else {}
        entry.update(updates)
        records[identity] = entry
        return {**document, RECORD_REPOSITORIES_KEY: records}

    return update_json_document(DISCOVERY_RECORD_PATH, merged)


def write_discovery_record(job: DrainerJob) -> Path:
    """Record where the LaunchAgent this module just wrote actually lives, so
    Kanban resolves it by reading rather than by deriving the label a second
    time. Written from the same label and plist path `render_plist` and
    `launch_target` use, and filed under the identity Kanban selects it by."""
    return merge_repository_record(
        job.identity,
        {
            "launchd_label": job.label,
            "plist_path": str(job.plist_path),
            "repository": str(job.repo_path),
        },
    )


def read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
    return value if isinstance(value, dict) else None


def pid_alive(pid: int | None) -> bool:
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def launch_domain() -> str:
    return f"gui/{os.getuid()}"


def launch_target(job: DrainerJob) -> str:
    return launch_target_for(job.label)


def launch_target_for(label: str) -> str:
    return f"{launch_domain()}/{label}"


def run_command(
    args: list[str], *, check: bool = True
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(args, text=True, capture_output=True)
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise ServiceError(f"Command failed: {' '.join(args)}\n{detail}")
    return proc


def launchd_loaded(job: DrainerJob) -> bool:
    return label_loaded(job.label)


def label_loaded(label: str) -> bool:
    return (
        run_command(["launchctl", "print", launch_target_for(label)], check=False).returncode
        == 0
    )


def lock_pid(repo_path: Path) -> int | None:
    path = repo_path / ".git" / "drain_prs.lock"
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except (FileNotFoundError, OSError, ValueError):
        return None


def in_progress_operation(repo_path: Path) -> str | None:
    """Names the operation the checkout is stopped part-way through, if any.

    Mirrors `drain_prs.in_progress_operation` the way `require_default_branch`
    below mirrors the drainer's own default-branch check: the controller
    decides whether to start before the drainer process exists, so it has to
    read the same repository state independently.
    """
    proc = run_command(
        ["git", "-C", str(repo_path), "rev-parse", "--absolute-git-dir"],
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        raise ServiceError(f"Could not resolve the repository git directory: {detail}")
    git_directory = Path((proc.stdout or "").strip())
    if (git_directory / "rebase-merge").exists():
        return "rebase"
    if (git_directory / "rebase-apply").exists():
        applying = git_directory / "rebase-apply" / "applying"
        return "am" if applying.exists() else "rebase"
    for marker, operation in (
        ("MERGE_HEAD", "merge"),
        ("CHERRY_PICK_HEAD", "cherry-pick"),
        ("REVERT_HEAD", "revert"),
        ("BISECT_LOG", "bisect"),
    ):
        if (git_directory / marker).exists():
            return operation
    return None


def require_no_operation_in_progress(repo_path: Path) -> None:
    operation = in_progress_operation(repo_path)
    if operation is not None:
        raise ServiceError(
            f"Refusing to start PR drainer: a {operation} is in progress in "
            f"{repo_path}. Finish or abort it first."
        )


def require_default_branch(repo_path: Path, remote_name: str) -> None:
    current = run_command(
        ["git", "-C", str(repo_path), "branch", "--show-current"],
        check=False,
    )
    if current.returncode != 0:
        detail = (current.stderr or current.stdout or f"exit code {current.returncode}").strip()
        raise ServiceError(f"Could not inspect repository branch: {detail}")
    current_branch = (current.stdout or "").strip()

    default = run_command(
        ["git", "-C", str(repo_path), "symbolic-ref", "--short", f"refs/remotes/{remote_name}/HEAD"],
        check=False,
    )
    if default.returncode != 0:
        detail = (default.stderr or default.stdout or f"exit code {default.returncode}").strip()
        raise ServiceError(
            f"Could not determine the repository default branch from {remote_name}/HEAD: "
            + detail
        )
    default_ref = (default.stdout or "").strip()
    prefix = f"{remote_name}/"
    if not default_ref.startswith(prefix) or len(default_ref) == len(prefix):
        raise ServiceError(
            f"Could not determine the repository default branch from {remote_name}/HEAD: "
            + default_ref
        )
    default_branch = default_ref.removeprefix(prefix)

    if current_branch != default_branch:
        raise ServiceError(
            f"Refusing to start PR drainer: repository is on branch {current_branch!r}, "
            f"not default branch {default_branch!r}."
        )


def incident_kind(incident: dict[str, Any]) -> str:
    kind = incident.get("kind")
    return kind if isinstance(kind, str) else CRASH_INCIDENT_KIND


def incident_belongs_to(incident: dict[str, Any], job: DrainerJob) -> bool:
    """Attribution keys on the normalized canonical identity, not the checkout
    path that raised the incident: only *running* a drainer is exclusive per
    identity, so an incident raised while one clone held the drainer still has
    to be listed, acknowledged, and cleared from another clone of the same
    repository. An incident predating the identity field — or one raised by a
    checkout that has none — falls back to the path it recorded."""
    recorded = incident.get("repository")
    if isinstance(recorded, str) and recorded:
        return recorded == job.identity
    return incident.get("repo") == str(job.repo_path)


def incident_files(
    job: DrainerJob,
    *,
    all_repositories: bool = False,
    open_only: bool = False,
    kind: str | None = None,
) -> list[Path]:
    if not job.incident_dir.exists():
        return []
    paths = sorted(job.incident_dir.glob("incident-*.json"), reverse=True)
    selected: list[Path] = []
    for path in paths:
        incident = read_json(path) or {}
        if not all_repositories and not incident_belongs_to(incident, job):
            continue
        if open_only and incident.get("status") != "open":
            continue
        if kind is not None and incident_kind(incident) != kind:
            continue
        selected.append(path)
    return selected


def latest_log_path(job: DrainerJob) -> Path | None:
    """The newest dated log `drain_prs.py` wrote for *this* repository. The
    directory is already the repository's own, which is what keeps `logs
    --path <repo>` from reporting another repository's activity."""
    paths = sorted(job.log_dir.glob("20??-??-??.log"), reverse=True)
    return paths[0] if paths else None


def tail_lines(path: Path | None, count: int = 60) -> list[str]:
    if path is None:
        return []
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()[-count:]
    except OSError:
        return []


def infer_last_pr(lines: list[str]) -> int | None:
    for line in reversed(lines):
        match = re.search(r"PR #(\d+)", line)
        if match:
            return int(match.group(1))
    return None


def stored_repo_path(stored: dict[str, Any]) -> Path | None:
    raw_repo = stored.get("repo")
    if isinstance(raw_repo, str):
        return Path(raw_repo).expanduser().resolve()
    command = stored.get("command")
    if isinstance(command, list):
        try:
            index = command.index("--path")
            raw_repo = command[index + 1]
        except (ValueError, IndexError):
            return None
        if isinstance(raw_repo, str):
            return Path(raw_repo).expanduser().resolve()
    return None


def status_snapshot(job: DrainerJob) -> dict[str, Any]:
    """This repository's drainer state, read from this repository's own status
    file.

    There is no cross-repository state left to report. The status file is one
    of the paths partitioned by identity, so another repository's running
    drainer is invisible here rather than an error — which is what retired the
    `foreign` state. A running drainer whose `active_repo` is a *different*
    checkout is therefore never another project: it is a second clone of this
    same GitHub repository, which is genuinely this repository's drainer and
    is reported as running. `active_repo` names which checkout it runs from,
    and `install_job` and `start_service` refuse to add a second one.
    """
    stored = read_json(job.status_path) or {}
    active_repo = stored_repo_path(stored)
    runner_pid = stored.get("runner_pid")
    child_pid = stored.get("drainer_pid")
    runner_alive = pid_alive(runner_pid if isinstance(runner_pid, int) else None)
    child_alive = pid_alive(child_pid if isinstance(child_pid, int) else None)
    locked_pid = lock_pid(job.repo_path)
    locked_alive = pid_alive(locked_pid)

    operation: str | None = None
    if runner_alive and child_alive:
        state = "running"
    elif runner_alive:
        state = "starting"
    elif locked_alive:
        state = "external"
    else:
        # Only probed for a drainer that is not running: this is the one state
        # in which starting is the next question, and an unfinished operation
        # is the one repository condition that still answers it "no".
        operation = in_progress_operation(job.repo_path)
        state = "mid_operation" if operation else "stopped"

    # `incident_files` sorts newest first, so the head of this list is the one
    # the sidebar has always summarised. Both projections are reported: the
    # full set is what Kanban's incidents panel lists, and `open_incident`
    # stays exactly the newest-only summary the sidebar renders, so growing
    # one cannot change the other.
    open_incidents = [
        incident
        for incident in (read_json(path) for path in incident_files(job, open_only=True))
        if incident is not None
    ]
    latest_incident = open_incidents[0] if open_incidents else None
    log_path = latest_log_path(job)
    log_tail = tail_lines(log_path, 1)
    return {
        "state": state,
        "operation": operation,
        "launchd_loaded": launchd_loaded(job),
        "runner_pid": runner_pid if runner_alive else None,
        "drainer_pid": child_pid if child_alive else (locked_pid if locked_alive else None),
        "started_at": stored.get("started_at") if runner_alive else None,
        "repo": str(job.repo_path),
        "repository": job.identity,
        "label": job.label,
        "active_repo": str(active_repo) if runner_alive and active_repo else None,
        "drainer": str(DRAINER_PATH),
        "log": str(log_path) if log_path else None,
        "last_activity": log_tail[0] if log_tail else None,
        "open_incident": latest_incident,
        "open_incidents": open_incidents,
    }


def another_checkout_running(job: DrainerJob, snapshot: dict[str, Any]) -> str | None:
    """The other checkout of this same GitHub repository whose drainer is
    already running, if there is one.

    The per-checkout `.git/drain_prs.lock` cannot see this: two clones have two
    lock files. Their shared canonical identity is what makes them one job, and
    this is the guard that says so — the run lock remains a secondary one for
    everything inside a single checkout.
    """
    active_repo = snapshot.get("active_repo")
    if snapshot.get("state") not in {"running", "starting"}:
        return None
    if not isinstance(active_repo, str) or active_repo == str(job.repo_path):
        return None
    return active_repo


def render_plist(job: DrainerJob) -> bytes:
    python = str(Path(sys.executable).resolve())
    path_entries = [
        str(HOME / ".local" / "bin"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]
    environment = {
        "HOME": str(HOME),
        "PATH": ":".join(path_entries),
        "PYTHONUNBUFFERED": "1",
        "KANBAN_DRAINER_INSTALL_DIR": str(INSTALL_DIR),
    }
    data: dict[str, Any] = {
        "Label": job.label,
        "ProgramArguments": [
            python,
            str(CONTROLLER_PATH),
            "--path",
            str(job.repo_path),
            # The identity this label, and every path beside it, was derived
            # from — recorded here because the plist outlives the configuration
            # it was written from. Without it the runner would re-resolve the
            # identity at launch, and a shared `remote_name` changed after
            # installation would silently point this job at another
            # repository's status file, incidents and logs while the dashboard
            # could neither discover nor control it.
            "--repo",
            job.identity,
            "run",
        ],
        "WorkingDirectory": str(job.repo_path),
        "RunAtLoad": False,
        "KeepAlive": False,
        "ProcessType": "Background",
        "ThrottleInterval": 10,
        "StandardOutPath": str(job.service_out_path),
        "StandardErrorPath": str(job.service_err_path),
        "EnvironmentVariables": environment,
    }
    return plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False)


def legacy_job_repository() -> Path | None:
    """Which checkout the machine-wide singleton's plist still names, if it is
    installed at all. Read out of the plist rather than the discovery record,
    because the plist is what launchd would actually run."""
    try:
        with LEGACY_PLIST_PATH.open("rb") as handle:
            document = plistlib.load(handle)
    except (FileNotFoundError, OSError, plistlib.InvalidFileException, ValueError):
        return None
    if not isinstance(document, dict):
        return None
    arguments = document.get("ProgramArguments")
    if isinstance(arguments, list):
        for index, argument in enumerate(arguments):
            if argument == "--path" and index + 1 < len(arguments):
                candidate = arguments[index + 1]
                if isinstance(candidate, str) and candidate:
                    return Path(candidate).expanduser()
    working_directory = document.get("WorkingDirectory")
    if isinstance(working_directory, str) and working_directory:
        return Path(working_directory).expanduser()
    return None


def retire_legacy_job(job: DrainerJob) -> dict[str, Any] | None:
    """Unload and set aside the singleton `com.coghex.drain-prs` job before a
    derived job for the same repository is enabled.

    The two would otherwise drain one repository concurrently: the singleton's
    plist is still in `~/Library/LaunchAgents`, so login would bootstrap it
    alongside its replacement. A singleton installed for a *different*
    repository is left exactly as it is — that repository migrates on its own
    next install — and so is one whose checkout still resolves to some other
    canonical identity. A singleton whose repository can no longer be
    identified at all is retired: it names a checkout that is gone or is no
    longer a supported GitHub clone, so it can serve no repository, and leaving
    it loadable would leave a job nothing can ever migrate.
    """
    if not LEGACY_PLIST_PATH.exists() or job.label == LEGACY_LABEL:
        return None
    legacy_repository = legacy_job_repository()
    if legacy_repository is not None:
        try:
            # Through the discovery remote, because the answer is compared
            # against `job.identity`, which was resolved through that same
            # remote. Using the repository's own `--config` remote here would
            # resolve this very checkout to a different identity whenever that
            # configuration names a different remote — reading as "the legacy
            # job serves another repository" and leaving it loadable beside the
            # derived job that replaces it.
            legacy_identity = repository_identity(
                legacy_repository, discovery_remote_name()
            )
        except ServiceError:
            legacy_identity = None
        if legacy_identity is not None and legacy_identity != job.identity:
            return {
                "retired": False,
                "label": LEGACY_LABEL,
                "repository": legacy_identity,
                "reason": "the legacy job serves another repository",
            }
    if label_loaded(LEGACY_LABEL):
        run_command(["launchctl", "bootout", launch_target_for(LEGACY_LABEL)])
    retired_path = LEGACY_PLIST_PATH.with_name(LEGACY_PLIST_PATH.name + ".retired")
    os.replace(LEGACY_PLIST_PATH, retired_path)
    return {
        "retired": True,
        "label": LEGACY_LABEL,
        "repository": str(legacy_repository) if legacy_repository else None,
        "plist": str(retired_path),
    }


def install_job(job: DrainerJob) -> dict[str, Any]:
    ensure_dirs(job)
    snapshot = status_snapshot(job)
    conflict = another_checkout_running(job, snapshot)
    if conflict is not None:
        raise ServiceError(
            f"The PR drainer for {job.identity} is already running from {conflict}, "
            f"which is another checkout of the same repository as {job.repo_path}. "
            "Stop it before installing this checkout's launchd job."
        )
    if snapshot["state"] in {"running", "starting", "external"}:
        raise ServiceError("Stop the running drainer before installing its launchd job.")

    # Before the replacement is written, so the singleton can never be loadable
    # at the same instant as the job that supersedes it.
    retired = retire_legacy_job(job)

    payload = render_plist(job)
    fd, tmp_name = tempfile.mkstemp(prefix=job.plist_path.name, dir=job.plist_path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o644)
        os.replace(tmp_name, job.plist_path)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)

    # Written from the plist on disk, before launchd is asked to load it: the
    # record describes where the job is, so it has to be true the moment the
    # job exists. Every install path reaches here — `install`, and the refresh
    # `start_service` performs — so no route can leave the record stale.
    record = write_discovery_record(job)

    if launchd_loaded(job):
        run_command(["launchctl", "bootout", launch_target(job)])
    run_command(["launchctl", "bootstrap", launch_domain(), str(job.plist_path)])
    return {
        "installed": True,
        "repository": job.identity,
        "label": job.label,
        "plist": str(job.plist_path),
        "target": launch_target(job),
        "record": str(record),
        "legacy_job": retired,
    }


def start_service(job: DrainerJob) -> dict[str, Any]:
    # Ahead of the default-branch check: a rebase or a bisect commonly leaves
    # a detached HEAD, so checking the branch first would report the symptom
    # instead of naming the operation the user has to finish.
    require_no_operation_in_progress(job.repo_path)
    require_default_branch(job.repo_path, job.remote_name)
    ensure_dirs(job)
    snapshot = status_snapshot(job)
    conflict = another_checkout_running(job, snapshot)
    if conflict is not None:
        raise ServiceError(
            f"The PR drainer for {job.identity} is already running from {conflict}, "
            f"which is another checkout of the same repository as {job.repo_path}. "
            "One repository drains from one checkout at a time."
        )
    if snapshot["state"] in {"running", "starting"}:
        return {"started": False, "message": "PR drainer is already running", **snapshot}
    if snapshot["state"] == "external":
        raise ServiceError(
            f"A drainer outside launchd is already running as PID {snapshot['drainer_pid']}."
        )
    install_job(job)

    previous_incidents = {path.name for path in incident_files(job, open_only=True)}
    run_command(["launchctl", "kickstart", launch_target(job)])
    deadline = time.monotonic() + START_TIMEOUT_SECONDS
    running_since: float | None = None
    while time.monotonic() < deadline:
        time.sleep(0.25)
        snapshot = status_snapshot(job)
        if snapshot["state"] == "running":
            if running_since is None:
                running_since = time.monotonic()
            elif time.monotonic() - running_since >= START_STABILITY_SECONDS:
                return {"started": True, **snapshot}
        else:
            running_since = None
        new_incidents = [
            path
            for path in incident_files(job, open_only=True)
            if path.name not in previous_incidents
        ]
        if new_incidents:
            incident = read_json(new_incidents[0]) or {}
            raise ServiceError(
                "PR drainer exited during startup: "
                + str(incident.get("summary") or incident.get("incident_id"))
            )
    raise ServiceError("Timed out waiting for the PR drainer to start.")


def stop_service(job: DrainerJob) -> dict[str, Any]:
    snapshot = status_snapshot(job)
    state = snapshot["state"]
    if state == "stopped":
        return {"stopped": False, "message": "PR drainer is already stopped", **snapshot}
    if state == "external":
        pid = snapshot["drainer_pid"]
        if not isinstance(pid, int):
            raise ServiceError("Could not identify the external drainer PID.")
        os.kill(pid, signal.SIGINT)
    else:
        run_command(["launchctl", "kill", "SIGTERM", launch_target(job)])

    deadline = time.monotonic() + STOP_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        time.sleep(0.25)
        current = status_snapshot(job)
        if current["state"] == "stopped":
            cleared_incidents = resolve_open_incidents(
                job,
                "Cleared when the PR drainer was intentionally stopped.",
            )
            return {
                "stopped": True,
                "cleared_incidents": len(cleared_incidents),
                **status_snapshot(job),
            }
    raise ServiceError("Timed out waiting for the PR drainer to stop.")


def publish_ntfy(
    message: str,
    *,
    title: str = "PR drainer stopped",
    priority: str = "urgent",
    tags: str = "warning,octagonal_sign",
) -> dict[str, Any]:
    if not NTFY_URL:
        return {"configured": False, "delivered": False}
    last_error: BaseException | None = None
    for attempt in range(1, NTFY_ATTEMPTS + 1):
        request = urllib.request.Request(
            NTFY_URL,
            data=message.encode("utf-8"),
            method="POST",
            headers={"Title": title, "Priority": priority, "Tags": tags},
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                body = response.read().decode("utf-8", errors="replace")
                try:
                    result = json.loads(body) if body else {}
                except json.JSONDecodeError:
                    result = {}
                return {
                    "delivered": 200 <= response.status < 300,
                    "http_status": response.status,
                    "message_id": result.get("id") if isinstance(result, dict) else None,
                    "attempt": attempt,
                }
        except (urllib.error.URLError, TimeoutError) as exc:
            last_error = exc
            if attempt < NTFY_ATTEMPTS:
                time.sleep(attempt)
    raise ServiceError(
        f"ntfy delivery failed after {NTFY_ATTEMPTS} attempts: {last_error}"
    ) from last_error


def write_incident(
    *,
    job: DrainerJob,
    exit_code: int | None,
    command: list[str],
    exception_text: str | None = None,
) -> dict[str, Any]:
    ensure_dirs(job)
    incident_id = time.strftime("incident-%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{os.getpid()}"
    log_path = latest_log_path(job)
    log_tail = tail_lines(log_path)
    last_line = log_tail[-1] if log_tail else None
    last_pr = infer_last_pr(log_tail)
    if exception_text:
        summary = exception_text.strip().splitlines()[-1]
    elif exit_code is not None and exit_code < 0:
        summary = f"drain_prs.py terminated by signal {-exit_code}"
    else:
        summary = f"drain_prs.py exited unexpectedly with code {exit_code}"
    incident: dict[str, Any] = {
        "incident_id": incident_id,
        "kind": CRASH_INCIDENT_KIND,
        "status": "open",
        "occurred_at": utc_stamp(),
        "summary": summary,
        "exit_code": exit_code,
        "last_pr": last_pr,
        "last_activity": last_line,
        "command": command,
        "repo": str(job.repo_path),
        "repository": job.identity,
        "drainer": str(DRAINER_PATH),
        "drain_state": str(job.repo_path / ".git" / "drain_prs_state.json"),
        "drainer_log": str(log_path) if log_path else None,
        "service_log": str(job.service_log_path),
        "service_stdout": str(job.service_out_path),
        "service_stderr": str(job.service_err_path),
        "exception": exception_text,
        "log_tail": log_tail,
        "notification": {"delivered": False, "pending": True},
    }
    incident_path = job.incident_dir / f"{incident_id}.json"
    incident["path"] = str(incident_path)
    atomic_write_json(incident_path, incident)

    message_parts = [summary, f"Incident: {incident_id}"]
    if last_pr is not None:
        message_parts.append(f"Last PR: #{last_pr}")
    if last_line:
        message_parts.append(f"Last activity: {last_line}")
    message_parts.append("Inspect the incident with the installed drainer controller.")
    try:
        incident["notification"] = publish_ntfy("\n".join(message_parts))
    except ServiceError as exc:
        incident["notification"] = {
            "delivered": False,
            "pending": False,
            "error": str(exc),
        }
        service_log(job, str(exc))
    atomic_write_json(incident_path, incident)
    return incident


def conflict_summary(pull_request: int, files: list[str]) -> str:
    if not files:
        return (
            f"PR #{pull_request} has a merge conflict with the default branch; "
            "the drainer left it unmerged."
        )
    shown = ", ".join(files[:CONFLICT_SUMMARY_FILES])
    remaining = len(files) - CONFLICT_SUMMARY_FILES
    if remaining > 0:
        shown += f" (+{remaining} more)"
    return (
        f"PR #{pull_request} has a merge conflict in {shown}; "
        "the drainer left it unmerged."
    )


def cleanup_summary(pull_request: int, steps: list[str]) -> str:
    if not steps:
        return (
            f"PR #{pull_request} merged, but the drainer could not finish its "
            "post-merge cleanup."
        )
    shown = ", ".join(steps[:CLEANUP_SUMMARY_STEPS])
    remaining = len(steps) - CLEANUP_SUMMARY_STEPS
    if remaining > 0:
        shown += f" (+{remaining} more)"
    return (
        f"PR #{pull_request} merged, but its post-merge cleanup keeps failing: "
        f"{shown}."
    )


def find_open_pr_incident(
    job: DrainerJob, pull_request: int, kind: str
) -> tuple[Path, dict[str, Any]] | None:
    """The one open incident keyed by this repository, kind and PR, if any."""
    for path in incident_files(job, open_only=True, kind=kind):
        incident = read_json(path)
        if incident is not None and incident.get("pull_request") == pull_request:
            return path, incident
    return None


def find_open_conflict_incident(
    repo_path: Path, pull_request: int
) -> tuple[Path, dict[str, Any]] | None:
    return find_open_pr_incident(
        incident_job(repo_path), pull_request, CONFLICT_INCIDENT_KIND
    )


def open_conflict_incidents(repo_path: Path) -> list[dict[str, Any]]:
    incidents: list[dict[str, Any]] = []
    for path in incident_files(
        incident_job(repo_path), open_only=True, kind=CONFLICT_INCIDENT_KIND
    ):
        incident = read_json(path)
        if incident is not None:
            incidents.append(incident)
    return incidents


def record_pr_incident(
    *,
    job: DrainerJob,
    pull_request: int,
    kind: str,
    summary: str,
    payload: dict[str, Any],
    notes: list[str],
    title: str,
    tags: str,
    refresh: bool = False,
) -> dict[str, Any]:
    """Record that a healthy drainer needs help with one pull request.

    Idempotent on (repository, kind, pull request): while an incident for that
    PR and kind is open, repeated polls return it rather than accumulating
    duplicates. A recurrence after resolution opens a new one. With `refresh`,
    an open incident's summary and payload are brought up to date in place --
    for a kind whose detail shrinks as the drainer makes progress, leaving the
    first report standing would show work that is no longer outstanding. The
    incident keeps its id, its opening time and its one notification.
    """
    existing = find_open_pr_incident(job, pull_request, kind)
    if existing is not None:
        path, incident = existing
        if not refresh:
            return incident
        updated = {"summary": summary, **payload}
        if all(incident.get(key) == value for key, value in updated.items()):
            return incident
        incident.update(updated)
        incident["updated_at"] = utc_stamp()
        atomic_write_json(path, incident)
        return incident

    job.incident_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Second-granularity stamps repeat, and the same PR number can belong to
    # two repositories, so disambiguate rather than overwrite a live incident.
    base_id = (
        time.strftime("incident-%Y%m%dT%H%M%SZ", time.gmtime())
        + f"-{os.getpid()}-pr{pull_request}"
    )
    incident_id = base_id
    duplicate = 1
    while (job.incident_dir / f"{incident_id}.json").exists():
        duplicate += 1
        incident_id = f"{base_id}-{duplicate}"
    log_path = latest_log_path(job)
    incident: dict[str, Any] = {
        # Kind-specific detail first, so it can never displace the fields every
        # incident reader relies on.
        **payload,
        "incident_id": incident_id,
        "kind": kind,
        "status": "open",
        "occurred_at": utc_stamp(),
        "summary": summary,
        "pull_request": pull_request,
        "repo": str(job.repo_path),
        "repository": job.identity,
        "drainer": str(DRAINER_PATH),
        "drainer_log": str(log_path) if log_path else None,
        "service_log": str(job.service_log_path),
        "notification": {"delivered": False, "pending": True},
    }
    incident_path = job.incident_dir / f"{incident_id}.json"
    incident["path"] = str(incident_path)
    atomic_write_json(incident_path, incident)

    message_parts = [summary, f"Incident: {incident_id}", *notes]
    try:
        incident["notification"] = publish_ntfy(
            "\n".join(message_parts),
            title=title,
            priority="high",
            tags=tags,
        )
    except ServiceError as exc:
        incident["notification"] = {
            "delivered": False,
            "pending": False,
            "error": str(exc),
        }
    atomic_write_json(incident_path, incident)
    return incident


def record_conflict_incident(
    *,
    repo_path: Path,
    pull_request: int,
    files: list[str],
) -> dict[str, Any]:
    """Record that a healthy drainer stopped merging one conflicted PR."""
    return record_pr_incident(
        job=incident_job(repo_path),
        pull_request=pull_request,
        kind=CONFLICT_INCIDENT_KIND,
        summary=conflict_summary(pull_request, files),
        payload={"files": files},
        notes=[
            "The drainer is still running and keeps draining every other approved PR.",
            "Resolve the conflict on the PR branch; this incident clears itself "
            "once GitHub reports the PR mergeable again.",
        ],
        title="PR drainer blocked on a merge conflict",
        tags="warning,twisted_rightwards_arrows",
    )


def record_cleanup_incident(
    *,
    repo_path: Path,
    pull_request: int,
    steps: list[str],
    error: str | None,
) -> dict[str, Any]:
    """Record that a merged PR's post-merge cleanup keeps failing.

    The merge itself already landed, so this never asks the drainer to exit:
    the obligations stay recorded and retried while every other approved PR
    keeps draining. The incident names what is outstanding *now*, so a pass
    that discharges some of it updates the open incident in place.
    """
    return record_pr_incident(
        job=incident_job(repo_path),
        pull_request=pull_request,
        kind=CLEANUP_INCIDENT_KIND,
        summary=cleanup_summary(pull_request, steps),
        payload={"steps": steps, "last_error": error},
        notes=[
            "The merge already landed; only its cleanup is outstanding.",
            "The drainer is still running, keeps retrying these steps, and "
            "keeps draining every other approved PR.",
            "This incident clears itself once every outstanding step succeeds.",
        ],
        title="PR drainer cannot finish post-merge cleanup",
        tags="warning,broom",
        refresh=True,
    )


def resolve_pr_incident(
    job: DrainerJob, pull_request: int, kind: str, note: str
) -> dict[str, Any] | None:
    """Resolve only this PR's incident of this kind, leaving every other open
    incident -- another PR's, another kind's, or a supervisor crash -- alone."""
    found = find_open_pr_incident(job, pull_request, kind)
    if found is None:
        return None
    path, incident = found
    incident["status"] = "resolved"
    incident["resolved_at"] = utc_stamp()
    incident["resolution"] = note
    atomic_write_json(path, incident)
    return incident


def resolve_conflict_incident(
    repo_path: Path, pull_request: int, note: str
) -> dict[str, Any] | None:
    return resolve_pr_incident(
        incident_job(repo_path), pull_request, CONFLICT_INCIDENT_KIND, note
    )


def resolve_cleanup_incident(
    repo_path: Path, pull_request: int, note: str
) -> dict[str, Any] | None:
    return resolve_pr_incident(
        incident_job(repo_path), pull_request, CLEANUP_INCIDENT_KIND, note
    )


def acknowledge_incident(
    job: DrainerJob, incident_id: str | None, note: str | None
) -> dict[str, Any]:
    paths = incident_files(job, open_only=True)
    if incident_id:
        if not re.fullmatch(r"incident-[A-Za-z0-9TZ-]+", incident_id):
            raise ServiceError(f"Invalid incident ID: {incident_id}")
        # Named incidents are still resolved inside this repository's own
        # directory, so one repository can never acknowledge another's.
        paths = [job.incident_dir / f"{incident_id}.json"]
    if not paths:
        raise ServiceError("There is no open incident to acknowledge.")
    path = paths[0]
    incident = read_json(path)
    if incident is None:
        raise ServiceError(f"Could not read incident: {path}")
    incident["status"] = "resolved"
    incident["resolved_at"] = utc_stamp()
    if note:
        incident["resolution"] = note
    atomic_write_json(path, incident)
    return incident


def resolve_open_incidents(job: DrainerJob, note: str) -> list[Path]:
    resolved: list[Path] = []
    for path in incident_files(job, open_only=True):
        incident = read_json(path)
        if incident is None:
            continue
        incident["status"] = "resolved"
        incident["resolved_at"] = utc_stamp()
        incident["resolution"] = note
        atomic_write_json(path, incident)
        resolved.append(path)
    return resolved


def drainer_command(job: DrainerJob) -> list[str]:
    """What this repository's runner starts.

    Both repository-specific selections are made here: the dated logs go to
    this repository's own log directory, and `--config` is forwarded only when
    this repository has an override of its own. A repository without one runs
    on the shared Kanban default, which is what keeps a later installation for
    a different repository from changing it.
    """
    command = [
        str(DRAINER_PATH),
        "--path",
        str(job.repo_path),
        "--interval",
        str(INTERVAL_SECONDS),
        "--log-dir",
        str(job.log_dir),
    ]
    if job.config_path:
        command.extend(["--config", job.config_path])
    return command


def run_service(job: DrainerJob, requested_identity: str | None = None) -> int:
    """Run the drainer for this job, first proving the job is still the one the
    LaunchAgent was installed for.

    `requested_identity` is what the plist recorded at installation. A checkout
    that no longer resolves to it means the shared configuration's remote
    changed underneath an installed job, so this exits having drained nothing
    rather than writing another repository's status file and logs. It stays
    refused until the installer is re-run, which is what mints the job for
    whichever repository the configuration now names.
    """
    try:
        require_requested_identity(job, requested_identity)
    except ServiceError as exc:
        # Into the installed job's own log directory, not this run's: that is
        # where the plist sends stdout and stderr, and where `logs` looks.
        service_log(
            requested_job(job.repo_path, requested_identity, job),
            f"PR drainer did not start: {exc}",
        )
        return 0
    try:
        require_default_branch(job.repo_path, job.remote_name)
    except ServiceError as exc:
        service_log(job, f"PR drainer did not start: {exc}")
        return 0
    ensure_dirs(job)
    command = drainer_command(job)
    child: subprocess.Popen[str] | None = None
    stop_requested = False
    signal_count = 0

    def handle_stop(_signum: int, _frame: Any) -> None:
        nonlocal stop_requested, signal_count
        stop_requested = True
        signal_count += 1
        if child is None or child.poll() is not None:
            return
        forwarded = signal.SIGINT if signal_count == 1 else signal.SIGKILL
        try:
            os.killpg(child.pid, forwarded)
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    service_log(job, f"Starting PR drainer: {' '.join(command)}")
    try:
        child_env = os.environ.copy()
        child_env["DRAIN_PRS_MANAGED"] = "1"
        child = subprocess.Popen(
            command,
            cwd=str(job.repo_path),
            text=True,
            start_new_session=True,
            env=child_env,
        )
        atomic_write_json(
            job.status_path,
            {
                "state": "running",
                "runner_pid": os.getpid(),
                "drainer_pid": child.pid,
                "started_at": utc_stamp(),
                "command": command,
                "repo": str(job.repo_path),
                "repository": job.identity,
            },
        )
        exit_code = child.wait()
    except BaseException:
        if stop_requested:
            return 0
        exception_text = traceback.format_exc()
        service_log(job, "PR drainer runner failed before a normal child exit")
        write_incident(
            job=job,
            exit_code=None,
            command=command,
            exception_text=exception_text,
        )
        return 1
    finally:
        try:
            job.status_path.unlink()
        except FileNotFoundError:
            pass

    if stop_requested:
        service_log(job, "PR drainer stopped intentionally; no incident notification sent")
        return 0

    incident = write_incident(job=job, exit_code=exit_code, command=command)
    service_log(job, f"PR drainer stopped unexpectedly; wrote {incident['path']}")
    return 1


def print_value(value: Any, *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(value, indent=2, sort_keys=True))
        return
    if isinstance(value, dict):
        for key, item in value.items():
            rendered = json.dumps(item, sort_keys=True) if isinstance(item, (dict, list)) else str(item)
            print(f"{key}: {rendered}")
    else:
        print(value)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Control this repository's launchd-managed PR drainer. Each canonical "
            "GitHub repository has its own job, and a config.toml path installed "
            "via install_drainer.py --config is forwarded to its drain_prs.py."
        )
    )
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON.")
    parser.add_argument(
        "--path",
        default=".",
        help="Repository path controlled by this invocation (default: current directory).",
    )
    parser.add_argument(
        "--repo",
        help=(
            "OWNER/NAME the caller believes --path is a checkout of. Refused when "
            "it names a different repository than the checkout's remote does."
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("install", help="Install or refresh the launchd job.")
    subparsers.add_parser("start", help="Start the PR drainer.")
    subparsers.add_parser(
        "stop", help="Stop the PR drainer and clear its open incidents."
    )
    subparsers.add_parser("status", help="Show live state and the latest open incident.")

    logs_parser = subparsers.add_parser("logs", help="Show the end of the current drainer log.")
    logs_parser.add_argument("--lines", type=int, default=80)

    incident_parser = subparsers.add_parser("incident", help="Show the latest open incident.")
    incident_parser.add_argument("incident_id", nargs="?")

    ack_parser = subparsers.add_parser("ack", help="Mark an incident resolved.")
    ack_parser.add_argument("incident_id", nargs="?")
    ack_parser.add_argument("--note")

    subparsers.add_parser(
        "notify-test", help="Send a test notification when KANBAN_DRAINER_NTFY_URL is set."
    )
    subparsers.add_parser("run", help=argparse.SUPPRESS)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        repo_path = Path(args.path).expanduser().resolve()
        if not (repo_path / ".git").exists():
            raise ServiceError(f"Repository path has no .git entry: {repo_path}")
        job = resolve_job(repo_path)
        # `run` checks the same assertion inside the runner, which can report a
        # mismatch into the installed job's log rather than only onto a stderr
        # stream launchd routes by the plist's own paths.
        if args.command == "run":
            return run_service(job, args.repo)
        require_requested_identity(job, args.repo)
        if args.command == "install":
            value = install_job(job)
        elif args.command == "start":
            value = start_service(job)
        elif args.command == "stop":
            value = stop_service(job)
        elif args.command == "status":
            value = status_snapshot(job)
        elif args.command == "logs":
            path = latest_log_path(job)
            value = {"path": str(path) if path else None, "lines": tail_lines(path, args.lines)}
        elif args.command == "incident":
            if args.incident_id:
                path = job.incident_dir / f"{args.incident_id}.json"
                value = read_json(path)
            else:
                paths = incident_files(job, open_only=True)
                value = read_json(paths[0]) if paths else None
            if value is None:
                raise ServiceError("No matching open incident was found.")
        elif args.command == "ack":
            value = acknowledge_incident(job, args.incident_id, args.note)
        elif args.command == "notify-test":
            value = publish_ntfy(
                "The PR drainer can deliver crash notifications to this topic.",
                title="PR drainer notification test",
                priority="default",
                tags="white_check_mark,test_tube",
            )
        else:
            raise ServiceError(f"Unknown command: {args.command}")
        print_value(value, as_json=args.json)
        return 0
    except (ServiceError, OSError) as exc:
        if args.json:
            print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        else:
            print(f"drain_prs_service.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
