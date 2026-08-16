#!/usr/bin/env python3

from __future__ import annotations

import argparse
import contextlib
import fcntl
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
import urllib.error
import urllib.request
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import kanban_config
import service_manager


# This module owns the drainer's lifecycle; `tools/service_manager.py` owns
# every interaction with the service manager that runs it, including the
# identifier each job is named and targeted by and the definition it is
# written from. Nothing here constructs, renders, or parses one — the seam is
# reached through `service_backend` below, and `tools/install_drainer.py`
# reaches the same one rather than restating any of it. `src/Kanban/Drainer.hs`
# derives nothing at all: it reads an installed job's identifier and definition
# path out
# of the per-repository record under DISCOVERY_RECORD_PATH below.
#
# There is one identifier, and one of every mutable runtime path, per canonical
# GitHub repository: that partitioning is what lets several repositories be
# drained independently on one account.
#
# The queue-state document version `cleanup_obligations` below understands,
# mirrored from `drain_prs.STATE_VERSION` because the controller reads that
# state directly rather than importing the drainer. A test holds them equal.
DRAIN_STATE_VERSION = 4
# The versions whose `prs` table carries cleanup records in this exact shape.
# Version 4 only added the queue's active-candidate lane, which says nothing
# about post-merge debt, so a version 3 file the upgraded drainer has not
# rewritten yet still reports its obligations rather than reporting unknown.
DRAIN_STATE_CLEANUP_VERSIONS = frozenset({3, DRAIN_STATE_VERSION})
# The private namespace the drainer anchors an autostash snapshot under, and the
# two stash messages its own writes produce -- mirrored from `drain_prs` for the
# same reason the state version above is, and pinned against the messages the
# drainer really writes by a test. The namespace prefix is used whole rather
# than as `.../*`, exactly as the drainer's own enumeration does, so no anchor
# below it can be missed.
SNAPSHOT_ANCHOR_NAMESPACE = "refs/drain-prs/autostash"
# Matched in full, never as a prefix: `drain-prs-autostash-notes` is a user's
# entry that merely looks like one of these. Git records no creator identity, so
# a hand-forged exact payload is indistinguishable and counts as drainer-named.
# Both object-format widths are accepted because a sha256 repository names the
# same snapshot in 64 hex digits.
DRAINER_STASH_MESSAGES = (
    # From a pass whose snapshot could not be prepared: the message it passed
    # to `git stash create` is the one it stores the orphaned commit under.
    re.compile(r"drain-prs-autostash-[0-9]+-[0-9]+"),
    # From a pass whose `git stash apply --index` restore conflicted.
    re.compile(r"drain-prs-autostash-recovery (?:[0-9a-f]{40}|[0-9a-f]{64})"),
)
# Git's display wrapper on an entry pushed with `git stash push -m`. The drainer
# only ever uses `git stash store -m`, which records the payload verbatim, so
# this is stripped before the payload above is compared. A branch name can hold
# no colon, which is what makes the prefix unambiguous.
STASH_BRANCH_WRAPPER = re.compile(r"On [^:]+: ")
# The fixed fields of both inventory reads below. They are checked rather than
# assumed because those reads answer whether any copy of someone's work is
# about to be missed: output the format cannot have produced makes the whole
# collection unknown, and a field taken on trust would make it look verified.
# An object ID is 40 hex digits in a sha1 repository and 64 in a sha256 one.
OBJECT_ID = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")
STASH_SELECTOR = re.compile(r"stash@\{[0-9]+\}")
# Exactly what git's own `iso-strict` renders, and nothing else.
ISO_STRICT_DATE = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:Z|[+-][0-9]{2}:[0-9]{2})"
)
HOME = Path.home()
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
# The third installed link, named by what this process actually imported rather
# than by INSTALL_DIR: the module already loaded is the one whose bytes ran.
CONFIG_MODULE_PATH = Path(kanban_config.__file__)
# The fourth, named the same way and for the same reason: the installed
# controller imports it out of the install directory, so what it resolved to is
# what this run's service-manager interactions actually behaved as.
SERVICE_MANAGER_MODULE_PATH = Path(service_manager.__file__)
# What `audit_installed_sources` compares those four against. The published
# baseline, read out of the checkout's own local remote-tracking ref — never
# fetched, because the audit may not touch the network or repository state.
SOURCE_BASELINE_REF = "refs/remotes/origin/master"
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
    refreshing one repository must leave every other repository's label, definition
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
    """A service-manager- and filename-safe name for one normalized identity.

    Total, nonempty, and injective across distinct normalized identities:
    each segment is escaped into an alphabet that excludes `.`, so the single
    `.` in the result is unambiguously the owner/name separator, and the escape
    itself is reversible. Case-only spellings never reach here as distinct
    values — `normalize_identity` folded them together first — which is what
    stops two clones of one GitHub repository from naming two drainers.

    Escaping can double a segment's length, so an identity spelled almost
    entirely in separators could outgrow what the backend's identifier may
    hold. Whether it does is the backend's answer, not this function's, because
    the limit is the service manager's; those fall back to a hash of the whole
    identity, which cannot collide with an escaped slug because it contains no
    `.` at all. One slug names the identifier and the runtime and log
    directories together, so the fallback has to be decided here rather than
    inside the backend, or the three would diverge.
    """
    owner, _, name = identity.partition("/")
    slug = f"{_escape_identity_segment(owner)}.{_escape_identity_segment(name)}"
    if not service_backend().identifier_fits(slug):
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
    """One repository's drainer: its identity, its service-manager job, and
    every mutable path that belongs to it alone.

    Built once per invocation and threaded through, so no two code paths can
    derive a different label or status file for the same repository. Every
    field except `repo_path` is a function of `identity`, which is why a second
    checkout of the same GitHub repository resolves to this same job rather
    than to a second one.

    `label` and `definition_path` are the selected backend's answers rather
    than launchd's: a LaunchAgent label and its plist on macOS, a unit name
    and its file under `~/.config/systemd/user` on Linux.
    """

    repo_path: Path
    identity: str
    slug: str
    label: str
    definition_path: Path
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
    definition_path: Path,
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
        definition_path=definition_path,
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
    backend = service_backend()
    label = backend.service_identifier(slug)
    return _job(
        repo_path,
        identity=identity,
        slug=slug,
        label=label,
        definition_path=backend.definition_path(label),
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
    names a job any service manager runs. It exists because `drain_prs.py` also runs
    standalone — `--pr <number>` against a fixture whose remote is a plain
    local path — and still records conflict and cleanup incidents. Those land
    where the singleton always put them, which by construction can never be any
    repository's partition.
    """
    backend = service_backend()
    return _job(
        repo_path,
        identity="",
        slug="",
        label=backend.legacy_identifier(),
        definition_path=backend.legacy_definition_path(),
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
    the service manager's stdout and stderr, and `logs`, all still point there.
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
    job.definition_path.parent.mkdir(parents=True, exist_ok=True)


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
    same document this module records installed jobs in, and either may
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
    writes the identifier and definition path, and either may run without the other.

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
    """Record where the definition just written for this job actually lives, so
    Kanban resolves it by reading rather than by deriving the label a second
    time. Written from the same identifier and definition path the backend
    rendered and loaded the job under, and filed under the identity Kanban
    selects it by.

    Which keys those are is the backend's answer, because the entry is a
    discriminated union: a launchd install keeps writing `launchd_label` and
    `plist_path`, a systemd install writes `systemd_unit` and `unit_path`, and
    both name the backend that wrote them. Only an entry naming no backend at
    all is ambiguous, and that shape can only have been written before this
    existed — which makes it launchd's, and is exactly how a live macOS
    drainer keeps working without a reinstall.
    """
    backend = service_backend()
    return merge_repository_record(
        job.identity,
        {
            **backend.record_entry(job.label, job.definition_path),
            "repository": str(job.repo_path),
        },
    )


def remove_discovery_record(identity: str) -> Path:
    """Drop one repository's entry from the shared document, leaving every
    sibling entry and every top-level key — the global `ntfy_url` above all —
    exactly as they are.

    The same two-level discipline `merge_repository_record` follows, in the
    other direction: rewriting `repositories` from anything but its own current
    value would delete the repositories this uninstall is not about, and the
    read that computes the removal happens inside `update_json_document`'s lock
    so an install racing it cannot be dropped.
    """

    def without(document: dict[str, Any]) -> dict[str, Any]:
        records = document.get(RECORD_REPOSITORIES_KEY)
        if not isinstance(records, dict) or identity not in records:
            return document
        remaining = {key: value for key, value in records.items() if key != identity}
        return {**document, RECORD_REPOSITORIES_KEY: remaining}

    return update_json_document(DISCOVERY_RECORD_PATH, without)


def read_json(path: Path) -> dict[str, Any] | None:
    # UnicodeDecodeError alongside the rest: it is a ValueError, not an
    # OSError, so bytes that are not UTF-8 would otherwise escape a reader
    # every caller expects to answer "nothing readable here".
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, UnicodeDecodeError, json.JSONDecodeError, OSError):
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


def run_command(
    args: list[str], *, check: bool = True
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(args, text=True, capture_output=True)
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise ServiceError(f"Command failed: {' '.join(args)}\n{detail}")
    return proc


def service_backend() -> service_manager.ServiceManagerBackend:
    """The one seam every service-manager interaction in this module goes
    through.

    Resolved per call rather than captured once, for two reasons. It reads
    `run_command` out of this module at call time, so a backend failure raises
    the `ServiceError` every caller here already handles — and a test that
    replaces either this function or that wrapper is honoured by every later
    call, which is how service-manager delegation is exercised without a real
    service manager. Nothing about the selection is operator-visible: there is
    no flag or environment variable to choose a backend, because the host is
    what decides.

    A host managed by neither supported service manager is refused here, in the
    failure vocabulary every caller in this module already handles — and
    refused before anything is written, because every path below has to resolve
    a backend in order to name a job before it can create one.
    """
    try:
        return service_manager.select_backend(run_command)
    except service_manager.NoServiceManagerError as exc:
        raise ServiceError(str(exc)) from exc


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


def drain_state_path(repo_path: Path) -> Path | None:
    """Where `drain_prs.py` keeps this repository's queue state, or None when
    this checkout cannot name it.

    The drainer writes it inside its checkout's git directory. A linked
    worktree's `.git` is a *file* pointing into the primary checkout, so
    joining the name onto it blindly raises NotADirectoryError from a
    dashboard or a shell run out of one. Git is asked for the shared directory
    only in that case, which leaves the ordinary checkout's read free of any
    subprocess -- status is polled every ten seconds.
    """
    entry = repo_path / ".git"
    try:
        if entry.is_dir():
            return entry / "drain_prs_state.json"
        if not entry.exists():
            return None
    except OSError:
        return None
    # The *common* directory, not `--absolute-git-dir`: the latter answers a
    # linked worktree's own `.git/worktrees/<name>`, while the state file the
    # drainer wrote from the primary checkout lives in the directory both
    # share.
    proc = run_command(
        ["git", "-C", str(repo_path), "rev-parse", "--git-common-dir"], check=False
    )
    if proc.returncode != 0:
        return None
    answer = (proc.stdout or "").strip()
    if not answer:
        return None
    common = Path(answer)
    if not common.is_absolute():
        # Git answers relative to the directory it ran in, which `-C` made
        # this checkout.
        common = repo_path / common
    return common / "drain_prs_state.json"


def is_plain_integer(value: Any) -> bool:
    # bool is a subclass of int, and `true` is neither a pull-request number
    # nor a count of passes.
    return isinstance(value, int) and not isinstance(value, bool)


def cleanup_step_description(obligation: Any) -> str | None:
    """One outstanding post-merge cleanup step, worded as the drainer words it
    for an incident, or None when the record cannot be described at all.

    Mirrors `drain_prs.describe_cleanup_obligation` for the same reason
    `in_progress_operation` above mirrors the drainer's own check: the
    controller answers `status` by reading this repository directly, without
    importing or running the drainer. The one difference is that this
    validates where the drainer indexes -- the drainer describes a record it
    has just written, while this describes whatever is on disk, and a
    malformed one has to be reported rather than raised out of a status call.
    A test holds the two wordings equal.
    """
    if not isinstance(obligation, dict):
        return None
    kind = obligation.get("kind")
    if kind == "issue":
        repo = obligation.get("repo")
        number = obligation.get("number")
        if not isinstance(repo, str) or not is_plain_integer(number):
            return None
        return f"closing {repo}#{number}"
    if kind == "worktree":
        return "removing the matching worktree"
    if kind == "local-branch":
        branch = obligation.get("branch")
        if not isinstance(branch, str):
            return None
        return f"deleting local branch {branch}"
    if kind == "remote-branch":
        branch = obligation.get("branch")
        if not isinstance(branch, str):
            return None
        return f"deleting remote branch {branch}"
    if kind == "fast-forward":
        return "fast-forwarding the default branch"
    # Not a failure: the drainer names an unrecognised step this way too, and
    # a step it cannot run is exactly the debt worth showing.
    return f"unknown cleanup step {kind!r}"


def pull_request_key(key: Any) -> int | None:
    """The pull request a queue-state entry is filed under, or None when the
    key names none.

    Canonical and positive, because the projection is keyed by this number
    and ordered on it: `remember_approved_head` files an entry under
    `str(number)`, so `"012"` and `"0"` are not keys the drainer can have
    written -- and accepting them would let one pull request appear twice in
    the projection, inflating the sidebar's count, or appear as PR 0.
    """
    if not isinstance(key, str) or not key.isascii() or not key.isdigit():
        return None
    try:
        number = int(key)
    except ValueError:
        # Python refuses to convert a digit string past its integer-string
        # limit, and this read is the one that must never raise.
        return None
    if number <= 0 or str(number) != key:
        return None
    return number


def cleanup_obligations(repo_path: Path) -> list[dict[str, Any]] | None:
    """The post-merge debt this repository's queue state still records, or
    None when that state could not be read as one.

    Read-only and lock-free by contract. `save_drain_state` writes through a
    temporary file and a rename, so a reader holding no lock sees one whole
    version or the previous one; and nothing here writes, migrates, or repairs
    what it reads, because status is the diagnostic used when the repository
    is already in a bad state.

    None means unknown, never "nothing owed". An absent, unreadable,
    malformed, or wrong-version document reports unknown, and so does one
    carrying a cleanup record that cannot be described: a partial list would
    read as a complete one. Versions 1 and 2 are unknown rather than empty
    because they predate durable cleanup records, so an entry either left
    behind can be a merged pull request whose obligations have not been
    reconstructed yet. Version 3 is read like the current version because the
    two carry the same records; see DRAIN_STATE_CLEANUP_VERSIONS. Their
    active-candidate lanes differ, and only the current version's is checked:
    migration overwrites a version 3 lane with null before validating it, so
    whatever one carries, the drainer can still use the file.

    A document the drainer's own `migrate_drain_state` would refuse is
    unknown too, checked here in the same order and never by calling it: that
    function repairs what it reads, and this must leave the file alone.
    """
    path = drain_state_path(repo_path)
    if path is None:
        return None
    state = read_json(path)
    if state is None or state.get("version") not in DRAIN_STATE_CLEANUP_VERSIONS:
        return None
    entries = state.get("prs")
    if not isinstance(entries, dict):
        return None
    # `migrate_drain_state` defaults an absent counter to 0 and refuses any
    # other non-integer, so a document carrying one is not a drain state at
    # all -- whatever its `prs` table appears to say about debt.
    if not is_plain_integer(state.get("attempt_counter", 0)):
        return None
    # The queue's active-candidate lane, defaulted to null and otherwise
    # required to be a positive pull-request number. A document failing that
    # is one `migrate_drain_state` refuses outright, so its `prs` table says
    # nothing this can report as verified-empty debt. No membership check
    # against that table goes with it: the lane names a candidate drawn from
    # the eligible pull requests, not an entry, and the drainer does not
    # require one -- being stricter here would divide the two sides again in
    # the other direction.
    if state.get("version") == DRAIN_STATE_VERSION:
        active = state.get("active_pr")
        if active is not None and (not is_plain_integer(active) or active <= 0):
            return None
    owed: list[dict[str, Any]] = []
    for key, entry in entries.items():
        number = pull_request_key(key)
        if number is None:
            return None
        if not isinstance(entry, dict) or not isinstance(
            entry.get("approved_head"), str
        ):
            return None
        record = entry.get("cleanup")
        if record is None:
            continue
        if not isinstance(record, dict):
            return None
        # Every value is validated before a record owing nothing is skipped.
        # A discharged record is still a record, and one carrying a value this
        # cannot read is a document that cannot be trusted about the debt of
        # any pull request in it.
        pending = record.get("pending")
        if not isinstance(pending, list):
            return None
        steps = [cleanup_step_description(item) for item in pending]
        if any(step is None for step in steps):
            return None
        failed_passes = record.get("failed_passes", 0)
        last_error = record.get("last_error")
        if not is_plain_integer(failed_passes):
            return None
        if last_error is not None and not isinstance(last_error, str):
            return None
        if not steps:
            continue
        owed.append(
            {
                "pull_request": number,
                "steps": steps,
                "failed_passes": failed_passes,
                "last_error": last_error,
            }
        )
    # Sorted numerically rather than left in the document's key order, so a
    # caller polling unchanged state gets the same answer every time.
    return sorted(owed, key=lambda item: item["pull_request"])


def _read_checkout_git(repo_path: Path, args: list[str]) -> str | None:
    """One read-only git query in a checkout, or None for every way it fails.

    Separate from `_read_git`, which serves the installed-source audit against
    whatever checkout an executing script came from: this one goes through
    `run_command`, the seam every other repository read in this module uses.

    None is the whole failure vocabulary — a path that is no repository, a
    nonzero exit, git missing, and output no locale can decode all answer the
    same way, because every caller here turns any of them into an unknown
    collection rather than into a status failure.
    """
    try:
        proc = run_command(["git", "-C", str(repo_path), *args], check=False)
    except (OSError, UnicodeDecodeError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout or ""


def _snapshot_anchor_rows(repo_path: Path) -> list[tuple[str, str, str]] | None:
    """Every autostash anchor as (ref, commit, commit date), or None when the
    namespace could not be enumerated.

    Mirrors `drain_prs._list_snapshot_anchors` field for field, including its
    `date unknown` fallback for a ref pointing at something that is not a
    commit, so an anchor reads here exactly as the drainer's own kept-anchor
    log line reads it. A ref name can hold no whitespace, so the first two
    fields split unambiguously and the date is whatever remains.

    Where that sweep steps over a line it cannot use, this refuses the whole
    collection: the sweep is deciding what to delete and a line it cannot read
    is simply not a deletion, while this is answering whether any anchor holds
    a sole copy of someone's work, and a skipped line there would read as
    "none does". Every field of the fixed format is therefore checked, and
    anything the format cannot have produced reports unknown.
    """
    out = _read_checkout_git(
        repo_path,
        [
            "for-each-ref",
            "--format=%(refname) %(objectname) %(committerdate:iso-strict)",
            SNAPSHOT_ANCHOR_NAMESPACE,
        ],
    )
    if out is None:
        return None
    rows: list[tuple[str, str, str]] = []
    # No row is skipped, blank ones included: the format emits one row per ref
    # and never a blank, so skipping one is how `"\n"` would become "no anchor
    # holds a sole copy" and a blank beside a real row would become a partial
    # list. An empty output is the only empty answer, and it means no ref.
    for line in out.splitlines():
        ref, _, rest = line.strip().partition(" ")
        sha, _, date = rest.partition(" ")
        date = date.strip()
        if (
            not ref.startswith(f"{SNAPSHOT_ANCHOR_NAMESPACE}/")
            or not OBJECT_ID.fullmatch(sha)
            # Empty is the format's own answer for a ref pointing at something
            # that is not a commit, and the only non-date it can produce.
            or not (date == "" or ISO_STRICT_DATE.fullmatch(date))
        ):
            return None
        rows.append((ref, sha, date or "date unknown"))
    return rows


def _stash_rows(repo_path: Path) -> list[tuple[str, str, str, str]] | None:
    """Every `git stash list` entry as (selector, commit, date, message), or
    None when the stash could not be read or parsed.

    One read serves both collections below, so the anchors they classify and
    the entries they report describe the same moment rather than two.

    `%gd` renders the `stash@{n}` selector a human can act on only while no
    `--date` is in force — passing one turns it into `stash@{<date>}` — so the
    date comes from `%cI`, which is already strict ISO 8601. Records are
    NUL-separated and fields unit-separated, and the message is taken as
    whatever remains, so no entry's own text can be read as a boundary.

    Every field the format fixes is checked, not merely counted: a record with
    four fields but no readable selector, object ID, or date is output this
    format cannot have produced, and reporting part of a stash would read as
    reporting all of it. Only the message is free text, because only the
    message is the entry's own.
    """
    out = _read_checkout_git(
        repo_path, ["stash", "list", "-z", "--format=%gd%x1f%H%x1f%cI%x1f%gs"]
    )
    if out is None:
        return None
    if out == "":
        # The only empty answer: a stash with no entries prints nothing.
        return []
    records = out.split("\0")
    # `-z` terminates every record, so exactly one trailing empty is expected
    # and anything else -- output that stops mid-record, a bare separator, an
    # extra one -- is not this format. Skipping those is how `"\0"` would
    # become verified-empty and a real entry beside one would become a
    # partial list that reads as the whole stash.
    if records.pop() != "":
        return None
    rows: list[tuple[str, str, str, str]] = []
    for record in records:
        if not record:
            return None
        fields = record.split("\x1f", 3)
        if len(fields) != 4:
            # A partial list would read as a complete one, and this collection
            # is read to find possibly-sole copies of work.
            return None
        selector, sha, date, message = fields
        if (
            not STASH_SELECTOR.fullmatch(selector)
            or not OBJECT_ID.fullmatch(sha)
            or not ISO_STRICT_DATE.fullmatch(date)
        ):
            return None
        rows.append((selector, sha, date, message))
    return rows


def drainer_stash_message(message: str) -> str | None:
    """The reserved payload a stash entry carries if the drainer wrote it, or
    None for a user's own entry.

    The stash is the user's; only the entries the drainer itself stored are
    reported, and nothing here is ever a reason to touch one.
    """
    payload = STASH_BRANCH_WRAPPER.sub("", message, count=1)
    if any(pattern.fullmatch(payload) for pattern in DRAINER_STASH_MESSAGES):
        return payload
    return None


def autostash_inventory(repo_path: Path) -> dict[str, list[dict[str, Any]] | None]:
    """The local copies of work this checkout's autostash lifecycle left
    behind: anchors the drainer kept, and the stash entries it created itself.

    Both are otherwise visible only in one log line per startup sweep, which
    repeats identically every pass — so work that exists nowhere else waits for
    a human to read a service log. They are two independent collections
    because they fail independently, and each follows the rule
    `cleanup_obligations` follows: entries, `[]` for verified-empty, and None
    for a collection that could not be enumerated or parsed. None is never
    "nothing there".

    Strictly read-only, and non-fatal by construction — this is polled every
    ten seconds and again through a start or stop, and no reading of it may
    change the controller's exit status, a ref, the stash's order or contents,
    the queue state, or the drainer's own sweep and its logging.

    Scoped to this checkout, including the git directory it shares when it is a
    linked worktree: both refs and the stash live in the common directory, so
    `git -C` answers for the whole shared repository without resolving it.
    """
    anchors = _snapshot_anchor_rows(repo_path)
    stashes = _stash_rows(repo_path)
    kept: list[dict[str, Any]] | None = None
    if anchors is not None:
        # An anchor is kept when its commit is absent from a stash list that
        # was read successfully. Without that list nothing is provably
        # redundant, so every anchor is conservatively kept — the same rule
        # `drain_prs.sweep_snapshot_anchors` follows before it deletes
        # anything, restated here without invoking the sweep.
        recoverable = {sha for _, sha, _, _ in stashes} if stashes is not None else set()
        kept = [
            {
                "ref": ref,
                "commit": sha,
                "date": date,
                "restore": f"git stash apply --index {sha}",
            }
            for ref, sha, date in anchors
            if sha not in recoverable
        ]
    reported: list[dict[str, Any]] | None = None
    if stashes is not None:
        reported = [
            {"stash": selector, "message": payload, "date": date}
            for selector, _, date, message in stashes
            if (payload := drainer_stash_message(message)) is not None
        ]
    return {"kept_autostash_anchors": kept, "drainer_stashes": reported}


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
    inventory = autostash_inventory(job.repo_path)
    backend = service_backend()
    return {
        "state": state,
        "operation": operation,
        # The key name is the contract Kanban reads, so it stays `launchd_`
        # whatever answers it; the answer itself is the backend's.
        "launchd_loaded": backend.is_loaded(job.label),
        # Which manager that answer came from, so a reader can say "outside
        # systemd" on a host where saying "outside launchd" would be false.
        # A reader that predates this field is reading a macOS controller, and
        # launchd is what it correctly assumes.
        "service_manager": backend.backend_name(),
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
        # Debt the drainer still owes a merged pull request, which no other
        # field reports: a merge attempts its own cleanup immediately, but
        # what that leaves outstanding is retried only by the polling loop's
        # sweep, so a stopped drainer neither discharges nor mentions it, and
        # debt under CLEANUP_PASSES_BEFORE_INCIDENT has raised no incident to
        # be seen through. Null is unknown, `[]` is verified-empty.
        "cleanup_obligations": cleanup_obligations(job.repo_path),
        # Local copies of work the autostash lifecycle left behind, which
        # otherwise appear only in one repeating line per startup sweep. Both
        # follow the same null-is-unknown rule, and both are independent of
        # the projection above: a queue state nobody can read says nothing
        # about a ref, and vice versa.
        "kept_autostash_anchors": inventory["kept_autostash_anchors"],
        "drainer_stashes": inventory["drainer_stashes"],
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


def service_definition(job: DrainerJob) -> service_manager.ServiceDefinition:
    """What the service manager must run for this job.

    Every value here is the controller's own — which interpreter runs which
    installed script against which checkout, where its output goes, and what
    environment it needs — and none of it is any service manager's spelling of
    that. Rendering this into a definition on disk is the backend's work.
    """
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
    return service_manager.ServiceDefinition(
        identifier=job.label,
        program_arguments=[
            python,
            str(CONTROLLER_PATH),
            "--path",
            str(job.repo_path),
            # The identity this label, and every path beside it, was derived
            # from — recorded here because the definition outlives the
            # configuration it was written from. Without it the runner would
            # re-resolve the identity at launch, and a shared `remote_name`
            # changed after installation would silently point this job at
            # another repository's status file, incidents and logs while the
            # dashboard could neither discover nor control it.
            "--repo",
            job.identity,
            "run",
        ],
        working_directory=str(job.repo_path),
        environment=environment,
        stdout_path=str(job.service_out_path),
        stderr_path=str(job.service_err_path),
    )


def retire_legacy_job(job: DrainerJob) -> dict[str, Any] | None:
    """Unload and set aside the machine-wide singleton job before a derived job
    for the same repository is enabled.

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
    backend = service_backend()
    legacy_label = backend.legacy_identifier()
    if not backend.legacy_definition_exists() or job.label == legacy_label:
        return None
    legacy_repository = backend.legacy_service_repository()
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
                "label": legacy_label,
                "repository": legacy_identity,
                "reason": "the legacy job serves another repository",
            }
    retired_path = backend.retire_legacy()
    return {
        "retired": True,
        "label": legacy_label,
        "repository": str(legacy_repository) if legacy_repository else None,
        backend.definition_label(): str(retired_path),
    }


def install_job(job: DrainerJob) -> dict[str, Any]:
    ensure_dirs(job)
    manager = service_backend().backend_name()
    snapshot = status_snapshot(job)
    conflict = another_checkout_running(job, snapshot)
    if conflict is not None:
        raise ServiceError(
            f"The PR drainer for {job.identity} is already running from {conflict}, "
            f"which is another checkout of the same repository as {job.repo_path}. "
            f"Stop it before installing this checkout's {manager} job."
        )
    if snapshot["state"] in {"running", "starting", "external"}:
        raise ServiceError(f"Stop the running drainer before installing its {manager} job.")

    # Before the replacement is written, so the singleton can never be loadable
    # at the same instant as the job that supersedes it.
    retired = retire_legacy_job(job)

    backend = service_backend()
    backend.write_definition(service_definition(job))

    # Written from the definition on disk, before the service manager is asked
    # to load it: the record describes where the job is, so it has to be true
    # the moment the job exists. Every install path reaches here — `install`,
    # and the refresh `start_service` performs — so no route can leave the
    # record stale.
    record = write_discovery_record(job)

    backend.load_definition(job.label)
    return {
        "installed": True,
        "repository": job.identity,
        "label": job.label,
        backend.definition_label(): str(job.definition_path),
        "target": backend.manager_target(job.label),
        "record": str(record),
        "legacy_job": retired,
    }


def uninstall_job(job: DrainerJob) -> dict[str, Any]:
    """Remove this repository's drainer job: its definition, the manager's hold
    on it, and its entry in the discovery record.

    Refused while it is running, for the reason every other transition here is:
    a manager asked to forget a live job leaves a drainer draining with nothing
    able to see or stop it. Scoped to one repository throughout — the
    definition is this job's alone, and the record edit removes one entry —
    so a second installed repository, the global `ntfy_url`, and the shared
    script links are all untouched.

    Runtime state, logs, and open incidents are deliberately left behind: they
    are the record of what this drainer did, and an uninstall is not an
    acknowledgement.
    """
    backend = service_backend()
    snapshot = status_snapshot(job)
    if snapshot["state"] in {"running", "starting", "external"}:
        raise ServiceError(
            f"Stop the PR drainer before uninstalling its {backend.backend_name()} job."
        )
    outcome = backend.uninstall_definition(job.label)
    record = remove_discovery_record(job.identity)
    return {
        "uninstalled": True,
        "repository": job.identity,
        "label": job.label,
        "unloaded": outcome.unloaded,
        backend.definition_label() + "_removed": outcome.definition_removed,
        "record": str(record),
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
            f"A drainer outside {snapshot['service_manager']} is already running "
            f"as PID {snapshot['drainer_pid']}."
        )
    install_job(job)

    previous_incidents = {path.name for path in incident_files(job, open_only=True)}
    service_backend().kick(job.label)
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


def obligation_count(obligations: list[dict[str, Any]] | None) -> int | None:
    """How many individual cleanup steps a `cleanup_obligations` projection
    names, or None when the queue state could not be read as one.

    Unknown is never zero, on the same rule the projection itself follows: a
    state nobody could read is not a state owing nothing.
    """
    if obligations is None:
        return None
    return sum(len(entry["steps"]) for entry in obligations)


def discharged_between(before: int | None, after: int | None) -> int | None:
    """What a stop's final cleanup pass discharged, from the debt recorded
    before the signal and the debt recorded after the exit.

    Read off the persisted state at both ends rather than reported by the
    stopping process: the debt the stop is answerable for is the debt on disk,
    and a pass whose own write failed did not discharge what it attempted.
    Never negative -- a merge that landed between the two reads records new
    debt, which is not something this stop failed to discharge.
    """
    if before is None or after is None:
        return None
    return max(0, before - after)


def stop_service(job: DrainerJob) -> dict[str, Any]:
    snapshot = status_snapshot(job)
    state = snapshot["state"]
    if state == "stopped":
        return {"stopped": False, "message": "PR drainer is already stopped", **snapshot}
    # Sampled before the signal, because the drainer discharges what it can on
    # its way out and this is the last reading taken before it does.
    owed_before = obligation_count(snapshot.get("cleanup_obligations"))
    if state == "external":
        pid = snapshot["drainer_pid"]
        if not isinstance(pid, int):
            raise ServiceError("Could not identify the external drainer PID.")
        os.kill(pid, signal.SIGINT)
    else:
        service_backend().request_stop(job.label)

    deadline = time.monotonic() + STOP_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        time.sleep(0.25)
        current = status_snapshot(job)
        if current["state"] == "stopped":
            cleared_incidents = resolve_crash_incidents(
                job,
                "Cleared when the PR drainer was intentionally stopped.",
            )
            final = status_snapshot(job)
            owed_after = obligation_count(final.get("cleanup_obligations"))
            # A stop that could not discharge everything still succeeded: the
            # remainder is reported here and stays recorded, projected, and
            # under whatever incident it raised, for the next start to retry.
            return {
                "stopped": True,
                "cleared_incidents": len(cleared_incidents),
                "cleanup_discharged": discharged_between(owed_before, owed_after),
                "cleanup_outstanding": owed_after,
                **final,
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
            # The summary names the failing step; only the recorded error says
            # why it fails, and whether it is the kind that retrying alone can
            # never clear. `error` is free-form text with no structured
            # human-action flag, so the note is qualified for every cleanup
            # failure rather than by guessing at its wording.
            *(
                [f"Last recorded failure: {error.strip()}"]
                if error and error.strip()
                else []
            ),
            "This incident clears itself once any operator action that failure "
            "calls for is done and every outstanding step succeeds.",
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


def resolve_crash_incidents(job: DrainerJob, note: str) -> list[Path]:
    """Resolve this repository's open crash incidents, and only those.

    An intentional stop ends the supervisor, so a `drainer-exit` incident --
    including a legacy one predating the `kind` field, which `incident_kind`
    reads as that kind -- is genuinely over. It discharges nothing else: a stop
    makes no pull request mergeable and completes no post-merge step, so a
    `merge-conflict` or `cleanup-pending` incident stays open for the poll that
    can actually clear it. `acknowledge_incident` remains the operator's manual
    dismissal, for an incident of any kind.
    """
    resolved: list[Path] = []
    for path in incident_files(job, open_only=True, kind=CRASH_INCIDENT_KIND):
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


@dataclass(frozen=True)
class SourceDivergence:
    """One executing source that does not match the baseline, and every reason
    the comparison could attribute for it."""

    path: str
    causes: tuple[str, ...]


@dataclass(frozen=True)
class SourceAudit:
    diverged: tuple[SourceDivergence, ...] = ()
    unavailable: tuple[str, ...] = ()


def installed_source_paths() -> tuple[tuple[str, Path], ...]:
    """The four files this service actually executes from.

    `tools/install_drainer.py` links all four out of one development checkout,
    so they are read here at call time rather than captured: whatever they
    resolve to now is what this run is about to behave as.
    """
    return (
        ("controller", CONTROLLER_PATH),
        ("drainer", DRAINER_PATH),
        ("config module", CONFIG_MODULE_PATH),
        ("service manager", SERVICE_MANAGER_MODULE_PATH),
    )


def _read_git(repo: Path, args: list[str]) -> str | None:
    """One read-only git query, or None for every way it can fail.

    Every argument list passed here only reads: the audit must not fetch,
    contact a remote, update a ref, or write repository state.
    """
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo), *args], text=True, capture_output=True
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def _baseline_causes(repo: Path) -> list[str]:
    """Why this checkout's committed bytes can differ from the baseline at all.

    Read once per repository: all three sources normally share one. A file
    whose committed bytes differ from `origin/master` always satisfies at least
    one of these, because differing blobs mean HEAD is not the baseline commit.
    """
    causes: list[str] = []
    head_ref = _read_git(repo, ["symbolic-ref", "--quiet", "HEAD"])
    if head_ref != "refs/heads/master":
        branch = head_ref[len("refs/heads/") :] if head_ref else "detached"
        causes.append(f"non-master HEAD ({branch})")
    ahead = _read_git(repo, ["rev-list", "--count", f"{SOURCE_BASELINE_REF}..HEAD"])
    if ahead and ahead != "0":
        causes.append("unpushed commits")
    behind = _read_git(repo, ["rev-list", "--count", f"HEAD..{SOURCE_BASELINE_REF}"])
    if behind and behind != "0":
        causes.append("HEAD behind origin/master")
    return causes


def _audit_source(
    label: str, path: Path, baselines: dict[Path, list[str]]
) -> tuple[SourceDivergence | None, str | None]:
    """Compare one executing source against its own checkout's baseline.

    Returns at most one of a divergence and an unavailability note; a source
    that matches the baseline yields neither, which is what keeps the healthy
    path silent.
    """
    if not os.path.exists(path):
        return None, f"{label} ({path}): missing, or its link has no target"
    resolved = Path(os.path.realpath(path))
    toplevel = _read_git(resolved.parent, ["rev-parse", "--show-toplevel"])
    if not toplevel:
        return None, f"{label} ({resolved}): not inside a git repository"
    repo = Path(os.path.realpath(toplevel))
    relative = os.path.relpath(resolved, repo)
    if relative == os.pardir or relative.startswith(os.pardir + os.sep):
        return None, f"{label} ({resolved}): outside its own repository"
    baseline = ["rev-parse", "--verify", f"{SOURCE_BASELINE_REF}^{{commit}}"]
    if _read_git(repo, baseline) is None:
        return None, f"{label} ({relative}): no local {SOURCE_BASELINE_REF}"
    baseline_blob = _read_git(
        repo, ["rev-parse", "--verify", f"{SOURCE_BASELINE_REF}:{relative}"]
    )
    if baseline_blob is None:
        return None, f"{label} ({relative}): absent from {SOURCE_BASELINE_REF}"
    executing_blob = _read_git(repo, ["hash-object", "--", str(resolved)])
    if executing_blob is None:
        return None, f"{label} ({relative}): unreadable"
    if executing_blob == baseline_blob:
        return None, None

    causes: list[str] = []
    head_blob = _read_git(repo, ["rev-parse", "--verify", f"HEAD:{relative}"])
    if head_blob != executing_blob:
        causes.append("working-tree edit")
    if head_blob != baseline_blob:
        if repo not in baselines:
            baselines[repo] = _baseline_causes(repo)
        causes.extend(baselines[repo])
    if not causes:
        causes.append("content differs")
    return SourceDivergence(relative, tuple(causes)), None


def audit_installed_sources() -> SourceAudit:
    """Compare the executing sources against the checkout's local
    `origin/master`, without ever being able to stop a run.

    The installed drainer executes from links into a live development checkout,
    so a mid-edit file or a checked-out feature branch is production behavior
    for every repository it drains. That is the deliberate install shape and
    manual-workflow compatibility forbids gating on it, so this only reports —
    and every failure of the comparison itself is swallowed into a note.
    """
    diverged: list[SourceDivergence] = []
    unavailable: list[str] = []
    baselines: dict[Path, list[str]] = {}
    for label, path in installed_source_paths():
        try:
            divergence, note = _audit_source(label, path, baselines)
        except Exception:
            divergence, note = None, f"{label}: the comparison did not complete"
        if divergence is not None:
            diverged.append(divergence)
        if note is not None:
            unavailable.append(note)
    return SourceAudit(tuple(diverged), tuple(unavailable))


def source_advisory_lines(audit: SourceAudit) -> list[str]:
    """At most two lines: one naming every comparable differing source, and one
    summarizing every comparison that could not be made."""
    lines: list[str] = []
    if audit.diverged:
        detail = "; ".join(
            f"{item.path} ({', '.join(item.causes)})" for item in audit.diverged
        )
        lines.append(
            "PR drainer source advisory: executing sources differ from "
            f"{SOURCE_BASELINE_REF}: {detail}. Report only; the drain proceeds."
        )
    if audit.unavailable:
        lines.append(
            "PR drainer source advisory unavailable: "
            + "; ".join(audit.unavailable)
            + ". Report only; the drain proceeds."
        )
    return lines


def log_source_advisory(job: DrainerJob) -> None:
    """Report the audit into the log stream the job definition already writes to.

    Nothing here may raise: this runs ahead of `run_service`'s own refusals, so
    a failure would turn an observation into the outage it exists to explain.
    """
    try:
        for line in source_advisory_lines(audit_installed_sources()):
            service_log(job, line)
    except Exception:
        pass


def run_service(job: DrainerJob, requested_identity: str | None = None) -> int:
    """Run the drainer for this job, first proving the job is still the one the
    service-manager job was installed for.

    `requested_identity` is what the definition recorded at installation. A checkout
    that no longer resolves to it means the shared configuration's remote
    changed underneath an installed job, so this exits having drained nothing
    rather than writing another repository's status file and logs. It stays
    refused until the installer is re-run, which is what mints the job for
    whichever repository the configuration now names.
    """
    # Into the installed job's own log directory, not this run's: that is where
    # the definition sends stdout and stderr, and where `logs` looks. Resolved up
    # front because the advisory below precedes both refusals, and a run that
    # refuses is exactly one whose source state is worth having on record.
    installed = requested_job(job.repo_path, requested_identity, job)
    log_source_advisory(installed)
    try:
        require_requested_identity(job, requested_identity)
    except ServiceError as exc:
        service_log(installed, f"PR drainer did not start: {exc}")
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
            "Control this repository's service-managed PR drainer — a launchd job on "
            "macOS, a systemd user unit on Linux. Each canonical GitHub repository "
            "has its own job, and a config.toml path installed via install_drainer.py "
            "--config is forwarded to its drain_prs.py."
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
    subparsers.add_parser("install", help="Install or refresh this repository's job.")
    subparsers.add_parser(
        "uninstall",
        help=(
            "Remove this repository's stopped job and its discovery entry, leaving "
            "every other repository's install alone."
        ),
    )
    subparsers.add_parser("start", help="Start the PR drainer.")
    subparsers.add_parser(
        "stop",
        help=(
            "Stop the PR drainer and clear its crash incidents. A merge-conflict "
            "or cleanup incident stays open; clear it with `ack`."
        ),
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
        # stream the service manager routes by the definition's own paths.
        if args.command == "run":
            return run_service(job, args.repo)
        require_requested_identity(job, args.repo)
        if args.command == "install":
            value = install_job(job)
        elif args.command == "uninstall":
            value = uninstall_job(job)
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
    # `ServiceManagerError` is the seam's own vocabulary for a fault no injected
    # runner can carry — a host with no service manager, a value that cannot be
    # rendered into a definition — and reaches here whenever it was raised past
    # the point `service_backend` translates the selection itself.
    except (ServiceError, service_manager.ServiceManagerError, OSError) as exc:
        if args.json:
            print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        else:
            print(f"drain_prs_service.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
