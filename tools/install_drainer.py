#!/usr/bin/env python3

"""Safely install Kanban's user-scoped PR drainer job.

The installer never starts the drainer. It only installs stable script links and
loads a stopped service definition for the selected repository — a LaunchAgent
on macOS, a systemd user unit on Linux, whichever
`tools/service_manager.select_backend` says this host is managed by. An optional
--config path is persisted against that repository and forwarded to its
installed drain_prs.py runs.

One job per canonical GitHub repository. The script links are shared —
one installed copy of the drainer, the controller, the configuration parser,
and the service-manager backend serves every repository — while the job, its
runtime state, its logs, and its `--config` selection are the repository's own.
Installing a second repository therefore adds an entry beside the first rather
than replacing it.

Installing runs drain_prs_service.py's own install step, which writes the
definition and records where it put it. Re-running this installer therefore
also repairs a missing or stale discovery record in place.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import drain_prs_service
import kanban_config
import service_manager


# The controller resolves the repository identity and, through
# `tools/service_manager.py`, the identifier derived from it, the definition's
# path, and the manager target; this installer resolves a job through the
# controller and reaches the service manager through that same backend rather
# than restating any of them. Every managed path is `tools/kanban_config.py`'s
# answer, for the same reason: one module writes each location down, for every
# platform it has a convention on.
#
# What a legacy install directory may contain and still be relocated whole.
# Everything here is this installer's or the controller's own: the four script
# links, the shared document and the lock that serializes writes to it, and the
# runtime tree beneath them. Anything else is a file nobody here put there, and
# a migration that moved or deleted it would be discarding a user's file --
# which is why finding one refuses the migration instead.
MANAGED_INSTALL_NAMES = frozenset(
    {
        "drain_prs.py",
        "drain_prs_service.py",
        "kanban_config.py",
        "service_manager.py",
        "config.json",
        "config.json.lock",
        "runtime",
    }
)

# Which keys name a recorded job's identifier and definition, per backend. The
# record is a discriminated union (`tools/service_manager.py`), so an entry is
# read through the backend it names rather than by trying both shapes.
_RECORD_KEYS_BY_BACKEND = {
    service_manager.LAUNCHD: service_manager.LAUNCHD_RECORD_KEYS,
    service_manager.SYSTEMD: service_manager.SYSTEMD_RECORD_KEYS,
}


class InstallError(RuntimeError):
    pass


def run(
    args: list[str], *, check: bool = True, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(args, text=True, capture_output=True, env=env)
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise InstallError(f"Command failed: {' '.join(args)}\n{detail}")
    return proc


def repository_root(requested: Path) -> Path:
    path = requested.expanduser().resolve()
    proc = run(["git", "-C", str(path), "rev-parse", "--show-toplevel"])
    root = Path(proc.stdout.strip()).resolve()
    if not (root / ".git").is_dir():
        raise InstallError(
            f"Install from the repository's main checkout, not a linked worktree: {root}"
        )
    required = [
        root / "tools" / "drain_prs.py",
        root / "tools" / "drain_prs_service.py",
        root / "tools" / "kanban_config.py",
        root / "tools" / "service_manager.py",
    ]
    missing = [str(item) for item in required if not item.is_file()]
    if missing:
        raise InstallError(
            "Repository does not contain the required drainer files: "
            + ", ".join(missing)
        )
    return root


def repository_job(repo: Path) -> drain_prs_service.DrainerJob:
    """This checkout's drainer job, or an InstallError naming why it has none.

    A checkout whose remote does not resolve to a repository on github.com
    cannot be given a drainer at all: its identity is what names the job, and
    inventing one from an unsupported value would install a job Kanban could
    never find.
    """
    try:
        return drain_prs_service.resolve_job(repo)
    except drain_prs_service.ServiceError as exc:
        raise InstallError(str(exc)) from exc


def service_backend() -> service_manager.ServiceManagerBackend:
    """The same seam the controller reaches its service manager through.

    Constructed with this module's own `run`, so a command that fails here
    fails as an `InstallError` rather than as the controller's `ServiceError`;
    resolved per call so a test can replace either this function or that
    wrapper. The installer spawns the *installed* controller as a subprocess,
    which selects its own backend in its own process — there is deliberately
    no flag or environment variable threading a selection between the two,
    because both ask the same host the same question.

    This is also the installer's only platform refusal. A host managed by
    neither launchd nor systemd is rejected by the selection itself, which is
    the condition that actually blocks an install; `sys.platform` never
    decides, so a Linux host with a live user session installs here exactly as
    a macOS host does.
    """
    try:
        return service_manager.select_backend(run)
    except service_manager.NoServiceManagerError as exc:
        raise InstallError(str(exc)) from exc


def managed_job_running(job: drain_prs_service.DrainerJob) -> bool:
    """Whether this repository's managed job already has a live process.

    A job the service manager does not hold at all is not running rather than
    an error: an installer that could not tell those apart would refuse every
    first install.
    """
    return service_backend().is_running(job.label)


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def repository_drainer_running(repo: Path) -> bool:
    git_dir = Path(
        run(["git", "-C", str(repo), "rev-parse", "--absolute-git-dir"])
        .stdout.strip()
    )
    lock_path = git_dir / "drain_prs.lock"
    try:
        pid = int(lock_path.read_text(encoding="utf-8").strip())
    except (FileNotFoundError, OSError, ValueError):
        return False
    return pid > 0 and pid_alive(pid)


def unique_sibling(path: Path) -> Path:
    for _ in range(20):
        candidate = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
        if not os.path.lexists(candidate):
            return candidate
    raise InstallError(f"Could not allocate a temporary link beside {path}")


def install_symlink(source: Path, destination: Path) -> str:
    source = source.resolve(strict=True)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if os.path.lexists(destination):
        if not destination.is_symlink():
            raise InstallError(
                f"Refusing to overwrite non-symlink installation path: {destination}"
            )
        try:
            current = destination.resolve(strict=True)
        except FileNotFoundError:
            current = None
        if current == source:
            return "unchanged"
        temporary = unique_sibling(destination)
        try:
            temporary.symlink_to(source)
            os.replace(temporary, destination)
        finally:
            if os.path.lexists(temporary):
                temporary.unlink()
        return "updated"
    destination.symlink_to(source)
    return "created"


def validate_symlink_destination(destination: Path) -> None:
    if os.path.lexists(destination) and not destination.is_symlink():
        raise InstallError(
            f"Refusing to overwrite non-symlink installation path: {destination}"
        )


def shared_config_path() -> Path:
    """The single document the installer's keys and the controller's discovery
    record share. It is the controller's fixed path, not an --install-dir
    -relative copy: Kanban resolves the record without inheriting
    KANBAN_DRAINER_INSTALL_DIR, so a custom install whose `ntfy_url` and
    `config_path` lived beside its script links would be a second document
    rather than the one merged record the contract describes."""
    return drain_prs_service.DISCOVERY_RECORD_PATH


def merge_installed_config_json(updates: dict[str, Any]) -> Path:
    """Merge `updates` into that document rather than overwriting it, so a
    later installer run that sets one key does not delete a different key
    persisted by an earlier run. The merge itself lives with the controller,
    which records the installed job in the same document and must not
    clobber these keys either."""
    try:
        return drain_prs_service.merge_json_document(shared_config_path(), updates)
    except drain_prs_service.ServiceError as exc:
        raise InstallError(str(exc)) from exc


def read_config_document(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def migrate_legacy_installed_config(install_dir: Path) -> list[str]:
    """Fold the configuration an earlier --install-dir install persisted beside
    its script links into the shared document, and report which keys moved.

    Re-running the installer is already how an installation predating the
    discovery record is repaired; migrating here means that same run also stops
    a custom install's `ntfy_url` and `config_path` from being stranded outside
    the record. Keys already in the shared document win — it is the current
    one — so this can never undo a newer value."""
    legacy_path = install_dir / "config.json"
    if legacy_path == shared_config_path() or not legacy_path.is_file():
        return []
    current = read_config_document(shared_config_path())
    moved = {
        key: value
        for key, value in read_config_document(legacy_path).items()
        if key not in current
    }
    if moved:
        merge_installed_config_json(moved)
    return sorted(moved)


def legacy_install_dir() -> Path | None:
    """The `~/Library`-spelled install directory this host migrates away from,
    or None on macOS, where it *is* the platform's own convention and nothing
    is ever migrated.

    Asked as "are these two directories the same?" rather than as
    `sys.platform`, because that is the condition that actually decides it:
    macOS's write path and the legacy spelling are one directory, so the
    comparison is False there by construction and no platform name has to be
    consulted a second time.
    """
    legacy = kanban_config.macos_drainer_install_dir()
    return None if legacy == kanban_config.default_drainer_install_dir() else legacy


def default_install_destination() -> Path:
    """Where an install with neither `--install-dir` nor the environment
    override goes.

    The installation that already exists, so an operator who installed
    elsewhere keeps it and a reinstall never quietly forks a second copy — with
    exactly one exception, which is the migration's whole trigger: the
    `~/Library` install a non-macOS host inherited resolves to this platform's
    own write path, so the run that finds it is the run that relocates it. On
    macOS `legacy_install_dir` is None and nothing is ever redirected.

    The environment override is read through `kanban_config` rather than here,
    so this and the controller's own `INSTALL_DIR` cannot disagree about
    whether it was set — and a value that names the legacy directory outright
    is honored rather than redirected, because a custom destination installs
    where it says and migrates nothing.
    """
    override = kanban_config.drainer_install_dir_override()
    if override is not None:
        return override
    existing = kanban_config.installed_drainer_dir()
    if existing == legacy_install_dir():
        return kanban_config.default_drainer_install_dir()
    return existing


@dataclass(frozen=True)
class LegacyMigration:
    """One shared `~/Library` installation, and where it is being relocated to.

    Every path a migration reads or writes, resolved once before anything is
    inspected, so the preflight and the mutation cannot disagree about which
    directories they are talking about.
    """

    source: Path
    destination: Path
    source_logs: Path
    destination_logs: Path
    source_record: Path
    destination_record: Path


@dataclass(frozen=True)
class RecordedJob:
    """One repository the shared record describes, recovered whole.

    A migration must rewrite every one of these, so each is either recovered
    exactly — identity, checkout, identifier and definition path — or the whole
    migration refuses. There is no partial reading: an entry this cannot
    reconstruct is an entry whose definition would be left pointing at an
    install directory that is about to be removed.
    """

    identity: str
    checkout: Path
    identifier: str
    definition_path: Path


def plan_legacy_migration(install_dir: Path) -> LegacyMigration | None:
    """The relocation this install would perform, or None when there is none.

    Three conditions, all of them necessary: this host has a legacy spelling
    distinct from its own (`legacy_install_dir`), that legacy location actually
    holds an installation, and this run's destination is this platform's
    default. A custom `--install-dir` or environment override therefore
    installs where it was told and migrates nothing — `install` reports that
    rather than performing a relocation the operator did not ask for.
    """
    source = legacy_install_dir()
    if source is None or install_dir != kanban_config.default_drainer_install_dir():
        return None
    source_record = source / "config.json"
    if not os.path.lexists(source_record):
        return None
    return LegacyMigration(
        source=source,
        destination=install_dir,
        source_logs=kanban_config.macos_drainer_log_dir(),
        destination_logs=kanban_config.default_drainer_log_dir(),
        source_record=source_record,
        destination_record=install_dir / "config.json",
    )


def skipped_legacy_migration(install_dir: Path) -> dict[str, Any] | None:
    """What to report when a legacy installation is present but this run is not
    the one that relocates it, and None when there is nothing to say.

    A custom destination installs where it was told and leaves the legacy
    installation exactly as it is — including its record, its runtime state and
    its logs — so the operator is told the relocation did not happen rather
    than left to infer it from an install that reported success.
    """
    source = legacy_install_dir()
    if source is None or not os.path.lexists(source / "config.json"):
        return None
    return {
        "migrated": False,
        "reason": (
            "the destination is not this platform's default install directory, so "
            "the legacy installation was left exactly as it is"
        ),
        "source": str(source),
        "destination": str(install_dir),
    }


def merged_record_document(
    legacy: dict[str, Any], current: dict[str, Any]
) -> dict[str, Any]:
    """Both discovery documents as one, with the XDG document winning per key.

    The whole document, not only its `repositories` table: the same file
    carries the installer's own keys — `ntfy_url` above all — and the legacy
    copy is about to be removed with the directory it lives in, so a key held
    only there would be silently deleted rather than merged. Per key in both
    directions, mirroring `migrate_legacy_installed_config`'s "keys already in
    the shared document win" rule, so no installed repository is dropped and no
    current value is undone by a stale one.
    """
    merged = {**legacy, **current}
    key = drain_prs_service.RECORD_REPOSITORIES_KEY
    legacy_repositories = legacy.get(key)
    current_repositories = current.get(key)
    if isinstance(legacy_repositories, dict) or isinstance(current_repositories, dict):
        merged[key] = {
            **(legacy_repositories if isinstance(legacy_repositories, dict) else {}),
            **(current_repositories if isinstance(current_repositories, dict) else {}),
        }
    return merged


def recorded_jobs(document: dict[str, Any], backend) -> list[RecordedJob]:
    """Every repository the merged document describes, or an InstallError
    naming the first entry that cannot be recovered exactly.

    "Cannot be safely inspected" is spelled out here rather than left to a
    guess: the key must be a canonical GitHub identity, the entry must name the
    checkout its definition runs against, and the identifier and definition
    path it records must be the ones this host's backend derives for that
    identity. An entry failing any of those describes a job this run could not
    rewrite, and rewriting every one of them is what the removal below depends
    on — so it refuses the migration rather than stranding it.
    """
    records = document.get(drain_prs_service.RECORD_REPOSITORIES_KEY)
    if not isinstance(records, dict):
        return []
    jobs: list[RecordedJob] = []
    for identity, entry in sorted(records.items()):
        detail = _unrecoverable_reason(identity, entry, backend)
        if detail is not None:
            raise InstallError(
                "Refusing to migrate the shared PR drainer installation: the "
                f"discovery record's entry for {identity!r} {detail}. Nothing was "
                "changed. Repair or remove that entry, then re-run this installer."
            )
        keys = _RECORD_KEYS_BY_BACKEND[backend.backend_name()]
        jobs.append(
            RecordedJob(
                identity=identity,
                checkout=Path(entry["repository"]),
                identifier=entry[keys[0]],
                definition_path=Path(entry[keys[1]]),
            )
        )
    return jobs


def _unrecoverable_reason(identity: Any, entry: Any, backend) -> str | None:
    if not isinstance(identity, str) or not isinstance(entry, dict):
        return "is not a repository name mapped to an object"
    try:
        if kanban_config.normalize_github_repository(identity) != identity:
            return "is not filed under a canonical github.com owner/name"
    except kanban_config.KanbanConfigError:
        return "is not filed under a canonical github.com owner/name"
    checkout = entry.get("repository")
    if not isinstance(checkout, str) or not Path(checkout).is_absolute():
        return "names no absolute checkout path for its definition to run against"
    named = entry.get(service_manager.RECORD_BACKEND_KEY)
    # An entry naming no backend predates the discriminator, which
    # `tools/service_manager.py` documents as launchd's shape.
    named = named if isinstance(named, str) and named else service_manager.LAUNCHD
    if named != backend.backend_name():
        return (
            f"was installed under {named}, which is not the {backend.backend_name()} "
            "service manager this host is managed by"
        )
    identifier_key, definition_key = _RECORD_KEYS_BY_BACKEND[named]
    expected = backend.service_identifier(drain_prs_service.repository_slug(identity))
    if entry.get(identifier_key) != expected:
        return f"records an identifier other than the {expected!r} this host derives"
    if entry.get(definition_key) != str(backend.definition_path(expected)):
        return "records a definition path other than the one this host derives"
    return None


def sibling_drainer_running(checkout: Path) -> bool:
    """Whether a drainer is running from that checkout, answered for a sibling
    repository rather than this run's own.

    A checkout that is simply gone can host no running process, so it is not
    running rather than an error — refusing every future install because a
    recorded repository was deleted would be a trap with no repair. A checkout
    that *is* there but cannot be asked is the opposite case: the answer is
    unknown, and an unknown here is a live drainer this migration would mutate
    underneath, so it fails closed.
    """
    if not checkout.is_dir():
        return False
    try:
        return repository_drainer_running(checkout)
    except InstallError as exc:
        raise InstallError(
            f"Refusing to migrate the shared PR drainer installation: {checkout} is "
            f"recorded as an installed repository but could not be inspected ({exc}). "
            "Nothing was changed."
        ) from exc


def preflight_legacy_migration(
    migration: LegacyMigration, backend
) -> list[RecordedJob]:
    """Every reason this migration must not start, checked before it changes
    anything, and the repositories it will have to rewrite if it may.

    The guard is the whole shared installation's rather than this run's own
    repository: the install directory, the discovery document and the log root
    are shared, so one repository's install relocating them is every recorded
    repository's business. A refusal here fails the installer outright and
    installs nothing — falling back to a fresh install at the destination would
    leave it standing beside a retained legacy installation, which is the
    stranding this exists to prevent, and the XDG-first probe would then hide
    the legacy siblings from every consumer.
    """
    jobs = recorded_jobs(
        merged_record_document(
            read_config_document(migration.source_record),
            read_config_document(migration.destination_record),
        ),
        backend,
    )
    live = [
        job.identity
        for job in jobs
        if backend.is_running(job.identifier) or sibling_drainer_running(job.checkout)
    ]
    if live:
        raise InstallError(
            "Refusing to migrate the shared PR drainer installation while a drainer "
            "is running for " + ", ".join(live) + ". Stop it first; nothing was changed."
        )
    conflicts = [
        f"{source} cannot be moved to {destination}, which already exists"
        for source, destination in (
            (migration.source / "runtime", migration.destination / "runtime"),
            (migration.source_logs, migration.destination_logs),
        )
        if os.path.lexists(source) and os.path.lexists(destination)
    ]
    # Whole trees rather than file by file: refusing an occupied destination
    # outright is what makes a same-relative-path collision impossible, and it
    # is the only policy that cannot silently overwrite, discard, or delete a
    # durable record — an open incident above all.
    unexpected = sorted(
        str(entry)
        for entry in migration.source.iterdir()
        if entry.name not in MANAGED_INSTALL_NAMES
    )
    if unexpected:
        conflicts.append(
            f"{migration.source} contains files this installer did not put there: "
            + ", ".join(unexpected)
        )
    if conflicts:
        raise InstallError(
            "Refusing to migrate the shared PR drainer installation: "
            + "; ".join(conflicts)
            + ". Nothing was changed."
        )
    return jobs


def perform_legacy_migration(
    migration: LegacyMigration, jobs: list[RecordedJob], backend
) -> dict[str, Any]:
    """Relocate the shared installation, in the one order that is safe to be
    interrupted in.

    The merged record is written durably at the destination first, so a run cut
    short leaves one complete document rather than none. The durable trees move
    next, into destinations the preflight proved are empty. Only then are the
    module's own managed paths rebound and every recorded definition rewritten
    and reloaded against them — and only once all of that has happened is the
    legacy directory removed, because a definition still naming it is a
    repository that would stop working the moment it went.
    """
    drain_prs_service.update_json_document(
        migration.destination_record,
        lambda current: merged_record_document(
            read_config_document(migration.source_record), current
        ),
    )
    moved = {}
    for name, source, destination in (
        ("runtime", migration.source / "runtime", migration.destination / "runtime"),
        ("logs", migration.source_logs, migration.destination_logs),
    ):
        moved[name] = os.path.lexists(source)
        if moved[name]:
            destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            shutil.move(str(source), str(destination))
    # From here on every path this process resolves is the destination's.
    drain_prs_service.bind_managed_paths()
    for job in jobs:
        _reinstall_recorded_job(job, backend)
    for job in jobs:
        backend.load_definition(job.identifier)
    shutil.rmtree(migration.source)
    return {
        "migrated": True,
        "source": str(migration.source),
        "source_logs": str(migration.source_logs),
        "destination": str(migration.destination),
        "destination_logs": str(migration.destination_logs),
        "record": str(migration.destination_record),
        "repositories": [job.identity for job in jobs],
        "moved": moved,
    }


def _reinstall_recorded_job(job: RecordedJob, backend) -> None:
    """Point one recorded repository's definition at the relocated
    installation, keeping everything else about it.

    Rebuilt from the identity the record files it under, so its identifier, its
    definition path and its `--config` selection are exactly what they were;
    what changes is the install directory the definition names, which is what
    carries its controller, its runtime root and its log paths across. Written
    before any of them is loaded and long before the legacy directory is
    removed, so no repository is ever left naming a directory that is gone.
    """
    try:
        # Read out of the merged record, in the order `resolve_job` reads it:
        # the identity selects the entry, and the entry supplies the `--config`
        # whose own remote this repository's drainer runs with.
        config_path = drain_prs_service.configured_config_path(job.identity)
        rebuilt = drain_prs_service.job_for_identity(
            job.checkout,
            job.identity,
            config_path=config_path,
            remote_name=drain_prs_service.configured_remote_name(config_path),
        )
        drain_prs_service.ensure_dirs(rebuilt)
        backend.write_definition(drain_prs_service.service_definition(rebuilt))
        drain_prs_service.write_discovery_record(rebuilt)
    except drain_prs_service.ServiceError as exc:
        raise InstallError(
            f"Could not rewrite the migrated PR drainer definition for {job.identity}: "
            f"{exc}. The legacy installation was left in place."
        ) from exc


def installed_ntfy_url() -> str | None:
    """The notification endpoint a previous run persisted, if any. Read out of
    the document rather than inferred from its existence: the controller also
    records the installed job there, so the file is present after every
    install whether or not notifications were ever configured."""
    url = read_config_document(shared_config_path()).get("ntfy_url")
    return url if isinstance(url, str) and url else None


def write_notification_config(ntfy_url: str) -> Path:
    return merge_installed_config_json({"ntfy_url": ntfy_url})


def write_installed_config_path(identity: str, config_path: str) -> Path:
    """Persist the kanban config.toml path for drain_prs_service.py's runner to
    forward to *this repository's* drain_prs.py.

    Written into that repository's own discovery record, not the single shared
    scalar earlier versions used: a later `--config` install for a second
    repository must not silently change the configuration the first
    repository's drainer restarts with. Merged rather than overwritten, so it
    lands beside the label and plist path the controller records.
    """
    try:
        return drain_prs_service.merge_repository_record(
            identity, {"config_path": config_path}
        )
    except drain_prs_service.ServiceError as exc:
        raise InstallError(str(exc)) from exc


def install(
    repo: Path,
    install_dir: Path,
    *,
    ntfy_url: str | None,
    config_path: str | None = None,
    dry_run: bool,
) -> dict[str, Any]:
    # First, and before any path below writes or links anything: resolving the
    # backend is what refuses a host with no service manager, and a refusal
    # after the script links were installed would leave an installation that
    # can never be completed or controlled.
    backend = service_backend()
    job = repository_job(repo)
    if managed_job_running(job) or repository_drainer_running(repo):
        raise InstallError(
            "Refusing to install while the PR drainer is running. Stop it first."
        )
    if ntfy_url and not ntfy_url.startswith(("https://", "http://")):
        raise InstallError("--ntfy-url must be an http:// or https:// endpoint.")
    resolved_config_path = (
        str(Path(config_path).expanduser().resolve()) if config_path else None
    )

    # Ahead of every write below, including the script links: a migration this
    # host cannot perform safely must leave it exactly as it was found, and
    # installing at the destination anyway is the one fallback that is never
    # available — a fresh installation standing beside a retained legacy one is
    # the split state the whole relocation exists to close.
    migration = plan_legacy_migration(install_dir)
    migration_jobs = (
        preflight_legacy_migration(migration, backend) if migration is not None else []
    )

    # Every module the installed controller imports has to be linked beside
    # it: it is executed out of the install directory, so it resolves its
    # siblings from there and an unlinked one makes every real install fail at
    # import.
    sources = {
        "drainer": repo / "tools" / "drain_prs.py",
        "controller": repo / "tools" / "drain_prs_service.py",
        "config_module": repo / "tools" / "kanban_config.py",
        "service_manager": repo / "tools" / "service_manager.py",
    }
    destinations = {
        "drainer": install_dir / "drain_prs.py",
        "controller": install_dir / "drain_prs_service.py",
        "config_module": install_dir / "kanban_config.py",
        "service_manager": install_dir / "service_manager.py",
    }
    for destination in destinations.values():
        validate_symlink_destination(destination)
    if dry_run:
        return {
            "installed": False,
            "dry_run": True,
            "repo": str(repo),
            "repository": job.identity,
            "label": job.label,
            "links": {
                key: {"source": str(sources[key]), "destination": str(destination)}
                for key, destination in destinations.items()
            },
            backend.definition_label(): str(job.definition_path),
            "record": str(drain_prs_service.DISCOVERY_RECORD_PATH),
            "config_path": resolved_config_path,
            "legacy_migration": (
                {
                    "migrated": False,
                    "planned": True,
                    "source": str(migration.source),
                    "destination": str(migration.destination),
                    "repositories": [item.identity for item in migration_jobs],
                }
                if migration is not None
                else skipped_legacy_migration(install_dir)
            ),
            "started": False,
        }

    link_results = {
        key: install_symlink(sources[key], destination)
        for key, destination in destinations.items()
    }
    # After the links, because every definition it rewrites names the
    # controller inside the destination directory, and before the record and
    # option writes below, because those go to whichever document this process
    # resolves once the relocation has rebound its managed paths.
    migration_report = skipped_legacy_migration(install_dir)
    if migration is not None:
        migration_report = perform_legacy_migration(
            migration, migration_jobs, backend
        )
    # Ahead of this run's own options, so an explicit --ntfy-url or --config
    # still wins over whatever the migrated copy carried.
    migrated_keys = migrate_legacy_installed_config(install_dir)
    notification_config = None
    if ntfy_url:
        notification_config = str(write_notification_config(ntfy_url))
    if resolved_config_path:
        write_installed_config_path(job.identity, resolved_config_path)
    environment = os.environ.copy()
    environment["KANBAN_DRAINER_INSTALL_DIR"] = str(install_dir)
    environment.pop("KANBAN_DRAINER_NTFY_URL", None)
    proc = run(
        [
            sys.executable,
            str(destinations["controller"]),
            "--path",
            str(repo),
            # The identity this installer resolved, asserted against the one the
            # installed controller resolves for itself. They read the same
            # remote, so a disagreement means the two copies parse identities
            # differently — which must fail here rather than install a job under
            # a label nothing else will look for.
            "--repo",
            job.identity,
            "--json",
            "install",
        ],
        env=environment,
    )
    try:
        controller_result = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise InstallError(
            f"Controller returned invalid installation JSON: {proc.stdout}"
        ) from exc
    return {
        "installed": True,
        "repo": str(repo),
        "repository": job.identity,
        "label": job.label,
        "install_dir": str(install_dir),
        "links": link_results,
        "config": str(shared_config_path()),
        "migrated_config_keys": migrated_keys,
        "legacy_migration": migration_report,
        "notifications_configured": notification_config is not None
        or installed_ntfy_url() is not None,
        "config_path": resolved_config_path,
        "controller": controller_result,
        "started": False,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Install Kanban's stopped, user-scoped PR drainer job."
    )
    parser.add_argument(
        "--repo",
        default=str(Path(__file__).resolve().parent.parent),
        help="Repository checkout to drain (default: checkout containing this script).",
    )
    parser.add_argument(
        "--install-dir",
        default=str(default_install_destination()),
        help="Stable per-user script-link directory.",
    )
    parser.add_argument(
        "--ntfy-url",
        default=os.environ.get("KANBAN_DRAINER_NTFY_URL"),
        help="Optional private ntfy endpoint for crash notifications.",
    )
    parser.add_argument(
        "--config",
        default=os.environ.get("KANBAN_DRAINER_CONFIG_PATH"),
        help="Optional kanban config.toml path forwarded to the installed drainer.",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Validate and describe without writing."
    )
    parser.add_argument("--json", action="store_true", help="Print JSON output.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        repo = repository_root(Path(args.repo))
        install_dir = Path(args.install_dir).expanduser().resolve()
        result = install(
            repo,
            install_dir,
            ntfy_url=args.ntfy_url,
            config_path=args.config,
            dry_run=args.dry_run,
        )
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        elif result.get("dry_run"):
            print(f"Dry run passed for {repo}; no files or services were changed.")
        else:
            print(f"Installed PR drainer for {result['repository']} at {repo}")
            migration = result.get("legacy_migration")
            if migration and migration["migrated"]:
                print(
                    f"Relocated the shared installation from {migration['source']}, "
                    f"carrying {len(migration['repositories'])} repositories."
                )
            elif migration:
                print(f"Left the installation at {migration['source']}: {migration['reason']}.")
            print(f"Service: {result['label']}")
            print(f"Controller: {install_dir / 'drain_prs_service.py'}")
            print("The job is loaded but stopped; start it from Kanban when ready.")
        return 0
    # `ServiceManagerError` is the service-manager seam's own vocabulary for a
    # fault no injected runner can carry, and reaches here whenever it was raised
    # past the point `service_backend` translates the selection itself.
    except (InstallError, service_manager.ServiceManagerError, OSError) as exc:
        if args.json:
            print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        else:
            print(f"install_drainer.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
