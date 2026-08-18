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
import contextlib
import errno
import json
import os
import secrets
import shutil
import subprocess
import sys
from collections.abc import Callable, Iterator
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
def _is_plain_file(path: Path) -> bool:
    return path.is_file() and not path.is_symlink()


def _is_plain_directory(path: Path) -> bool:
    return path.is_dir() and not path.is_symlink()


def _is_unmanaged(_path: Path) -> bool:
    return False


def _is_bytecode_cache(path: Path) -> bool:
    """The interpreter's own cache of the modules installed beside it.

    Not written by anything here, but produced by running them: importing the
    controller or its siblings out of the install directory leaves a
    `__pycache__` there, and a real installation has one. Refusing it would
    refuse the ordinary migration this exists to perform.

    Verified rather than trusted, on the same rule as every other entry: a
    plain directory holding nothing but plain `.pyc` files is a bytecode
    cache, and anything else wearing the name is not. What that admits is
    regenerable interpreter output rather than a record of anything — which is
    what makes it safe for the removal below to take with the directory, and
    is exactly the distinction a name-only check cannot draw.
    """
    return _is_plain_directory(path) and all(
        _is_plain_file(entry) and entry.suffix == ".pyc" for entry in path.iterdir()
    )


# What a legacy install directory may contain and still be relocated whole:
# each name this installer or the controller creates there, *and what that name
# has to be* for this to have created it. A name alone is not ownership.
# `install_symlink` only ever creates symlinks and refuses to overwrite
# anything else; `update_json_document` and `document_lock` refuse a path that
# is not a plain file. So an ordinary file named `drain_prs.py`, or a symlink
# where `config.json` belongs, is someone else's -- and since a successful
# migration deletes this directory whole, checking the name alone would be a
# spelling that hands a user's own file to `shutil.rmtree`. Anything that fails
# its check refuses the migration instead.
MANAGED_INSTALL_ENTRIES = {
    "drain_prs.py": Path.is_symlink,
    "drain_prs_service.py": Path.is_symlink,
    "kanban_config.py": Path.is_symlink,
    "service_manager.py": Path.is_symlink,
    "config.json": _is_plain_file,
    "config.json.lock": _is_plain_file,
    "runtime": _is_plain_directory,
    "__pycache__": _is_bytecode_cache,
}

def unmanaged_entries(directory: Path) -> list[str]:
    """Everything in an install directory this installer did not put there.

    The one place that question is asked, because both paths that remove such
    a directory have to ask it: the preflight before a relocation, and the
    absorber before it clears a location a late writer recreated. Judged by
    what each entry *is*, never by its name alone -- see
    MANAGED_INSTALL_ENTRIES.
    """
    return sorted(
        str(entry)
        for entry in directory.iterdir()
        if not MANAGED_INSTALL_ENTRIES.get(entry.name, _is_unmanaged)(entry)
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
    """The `~/Library`-spelled install directory this host takes over, or None
    on macOS, where it *is* the platform's own convention.

    Whether the two are the *same* directory is a separate question, and one
    this deliberately does not answer: an absolute `$XDG_DATA_HOME` naming
    `~/Library/Application Support` makes them equal on a host that still owes
    its definitions the rewrite. `LegacyMigration.relocating` draws that
    distinction where it belongs.
    """
    if not kanban_config.drainer_migrates_macos_installs():
        return None
    return kanban_config.macos_drainer_install_dir()


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

    @property
    def relocating(self) -> bool:
        """Whether the installation itself moves.

        False when this host's own convention resolves to the `~/Library`
        spelling — an absolute `$XDG_DATA_HOME` naming it. The installation is
        then already where it belongs and nothing may be removed; what is left
        is the rewrite, because the definitions still carry whatever log paths
        and environment they were written with. Almost everything below is
        conditioned on this: there is no record to merge with itself, no
        directory to delete, and therefore no writer that deleting it could
        strand.
        """
        return self.source != self.destination


@dataclass(frozen=True)
class RecordedJob:
    """One repository the shared record describes, recovered whole.

    A migration must rewrite every one of these, so each is either recovered
    exactly — identity, checkout, identifier, definition path, and the install
    directory that definition actually points its controller at — or the whole
    migration refuses. There is no partial reading: an entry this cannot
    reconstruct is an entry whose definition would be left pointing at an
    install directory that is about to be removed.

    `install_dir` is read back out of the definition rather than assumed to be
    the legacy one, because `--install-dir` and DRAINER_INSTALL_DIR_ENV move a
    job's script links and its runtime root without moving the shared record
    that names it. A repository installed that way keeps its status file and
    its open incidents under its own directory, and a migration that moved
    only the legacy tree would repoint its definition at an empty runtime root
    and leave them unreachable.
    """

    identity: str
    slug: str
    checkout: Path
    identifier: str
    definition_path: Path
    install_dir: Path

    @property
    def runtime_dir(self) -> Path:
        return self.install_dir / "runtime" / self.slug


@dataclass(frozen=True)
class TreeMove:
    """One durable tree the migration relocates whole, and what it holds.

    Moved rather than copied-and-deleted, and only into a destination the
    preflight proved is empty, so nothing here can overwrite, merge into, or
    discard a record of what a drainer did.
    """

    what: str
    source: Path
    destination: Path


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
    if (
        source is None
        # A default-destination run is never "skipped": either it migrated, or
        # there was nothing there to migrate, and reporting a custom
        # destination's reason for it would simply be untrue.
        or install_dir == kanban_config.default_drainer_install_dir()
        or not os.path.lexists(source / "config.json")
    ):
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


def strict_record_document(path: Path) -> dict[str, Any]:
    """The discovery document at `path`, or an InstallError naming why what is
    there is not one.

    `read_config_document` answers `{}` for anything it cannot read, which is
    the right answer for a caller merging optional keys and exactly the wrong
    one for a caller about to delete an installation. "No repositories are
    recorded" and "this file does not say" would become the same answer, and
    the second one would sail through the preflight with nothing to check,
    rewrite no definitions, and then remove the directory every definition
    still names. Absent is a real answer; unreadable is a refusal.
    """
    if not os.path.lexists(path):
        return {}
    detail = None
    document: Any = None
    if not _is_plain_file(path):
        # Ahead of reading it, because reading follows a symlink while
        # `os.replace` writing it would not: this is where the merged document
        # goes, and writing through would destroy whatever it points at.
        raise InstallError(
            f"Refusing to migrate the shared PR drainer installation: {path} is "
            "where this would write, and is not a regular file. Nothing was "
            "changed."
        )
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError) as exc:
        detail = f"could not be read ({exc})"
    except json.JSONDecodeError as exc:
        detail = f"is not valid JSON ({exc})"
    if detail is None and not isinstance(document, dict):
        detail = "does not hold a JSON object"
    if detail is None:
        records = document.get(drain_prs_service.RECORD_REPOSITORIES_KEY)
        if records is not None and not isinstance(records, dict):
            detail = (
                f"has a {drain_prs_service.RECORD_REPOSITORIES_KEY!r} value that is "
                "not a table of repositories"
            )
    if detail is not None:
        raise InstallError(
            f"Refusing to migrate the shared PR drainer installation: {path} "
            f"{detail}, so which repositories it describes cannot be established. "
            "Nothing was changed. Repair or remove that file, then re-run this "
            "installer."
        )
    return document


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
        slug = drain_prs_service.repository_slug(identity)
        identifier = entry[keys[0]]
        jobs.append(
            RecordedJob(
                identity=identity,
                slug=slug,
                checkout=Path(entry["repository"]),
                identifier=identifier,
                definition_path=Path(entry[keys[1]]),
                install_dir=_recorded_install_dir(identifier, backend),
            )
        )
    return jobs


def _recorded_install_dir(identifier: str, backend) -> Path:
    """The install directory that job's own definition points its controller
    at, which is where its runtime state and open incidents are."""
    environment = backend.definition_environment(identifier) or {}
    return Path(environment[kanban_config.DRAINER_INSTALL_DIR_ENV])


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
    # The record names the job; only the definition names the directory that
    # job's runtime state and incidents actually live under, and moving them is
    # what the rewrite below owes it.
    environment = backend.definition_environment(expected)
    if environment is None:
        return "has a definition this host cannot read an environment out of"
    configured = environment.get(kanban_config.DRAINER_INSTALL_DIR_ENV)
    if not isinstance(configured, str) or not Path(configured).is_absolute():
        return (
            "has a definition naming no absolute "
            f"{kanban_config.DRAINER_INSTALL_DIR_ENV}, so the runtime state and "
            "incidents it would carry cannot be located"
        )
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


@contextlib.contextmanager
def _selected_install_dir(install_dir: Path) -> Iterator[None]:
    """Bind this process's managed paths to the directory this run selected.

    `--install-dir` decides where the links go, and it is what the installed
    controller is spawned with -- but `bind_managed_paths` reads the ambient
    environment, where an inherited KANBAN_DRAINER_INSTALL_DIR may name
    somewhere else entirely. The relocation would then move every tree to the
    destination it chose while writing definitions that name the inherited
    directory, leaving each sibling pointed at a runtime root with nothing in
    it. The two have to be one answer, and this run's own selection is it --
    set here exactly as it is passed to the controller below, so the parent
    resolves what the child will.
    """
    previous = os.environ.get(kanban_config.DRAINER_INSTALL_DIR_ENV)
    os.environ[kanban_config.DRAINER_INSTALL_DIR_ENV] = str(install_dir)
    # Immediately, not when the relocation gets there: the preflight resolves
    # jobs through these constants too -- deciding which definitions are stale
    # by rendering them -- so leaving it until later would judge them against
    # the very directory this context exists to overrule, and settle nothing.
    drain_prs_service.bind_managed_paths()
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop(kanban_config.DRAINER_INSTALL_DIR_ENV, None)
        else:
            os.environ[kanban_config.DRAINER_INSTALL_DIR_ENV] = previous
        drain_prs_service.bind_managed_paths()


@contextlib.contextmanager
def _locked_legacy_record(migration: LegacyMigration) -> Iterator[None]:
    """The legacy record's lock, with the marks taking it leaves undone if the
    run does not go through.

    Locking is itself a mutation: `document_lock` chmods the directory holding
    the document to 0700, before the preflight has decided anything. A refusal
    for a live sibling, an unreadable record, or an occupied destination would
    otherwise report that nothing was changed over a mode that was not that,
    so it is recorded before the lock is taken and put back on every way out
    of this but a completed relocation, which has nothing to put back because
    the directory holding it is gone.

    The lock file `document_lock` creates is deliberately *not* removed again.
    Unlinking it would end the serialization it exists for: a writer that
    queued on it holds that inode, and once the path is free the next writer
    creates a different one -- leaving two writers locking different files and
    both updating the shared record, which is the lost entry the lock prevents.
    It is a managed artifact of the protocol, the next write of the document
    creates it again anyway, and an empty lock file is a far smaller thing than
    a dropped repository. A dry run avoids the question rather than answering
    it, by not taking the lock at all.
    """
    mode = (
        migration.source.stat().st_mode & 0o7777
        if _is_plain_directory(migration.source)
        else None
    )
    try:
        with drain_prs_service.document_lock(migration.source_record):
            yield
    finally:
        # Whenever the directory is still there, which is every way out of
        # this that is not a completed relocation: a refusal, and a dry run,
        # which must leave the host exactly as it found it and would otherwise
        # be the one path that reports having changed nothing while having
        # created a file and altered a mode. A relocation that finished has
        # nothing to put back, because what held them is gone.
        if _is_plain_directory(migration.source) and mode is not None:
            migration.source.chmod(mode)


def _rebuilt_job(job: RecordedJob) -> drain_prs_service.DrainerJob:
    """This repository's job as it resolves against the installation the
    module's managed paths currently name."""
    config_path = drain_prs_service.configured_config_path(job.identity)
    return drain_prs_service.job_for_identity(
        job.checkout,
        job.identity,
        config_path=config_path,
        remote_name=drain_prs_service.configured_remote_name(config_path),
    )


def _definition_is_stale(job: RecordedJob, backend) -> bool:
    """Whether this repository's installed definition differs from the one
    this host would write for it now.

    Compared as the bytes the backend renders rather than field by field, so
    every value a definition carries counts -- the log paths it names and the
    environment it passes among them. A definition that cannot be read at all
    is stale by construction: rewriting it is exactly the repair.
    """
    try:
        rendered = backend.render_definition(
            drain_prs_service.service_definition(_rebuilt_job(job))
        )
    except drain_prs_service.ServiceError:
        return True
    try:
        return job.definition_path.read_bytes() != rendered
    except OSError:
        return True


def _destination_runtime(migration: LegacyMigration, job: RecordedJob) -> Path:
    """Where this repository's runtime tree belongs once the installation has
    moved. Equal to `job.runtime_dir` already for a job whose `--install-dir`
    named what is now this platform's own default."""
    return migration.destination / "runtime" / job.slug


def planned_tree_moves(
    migration: LegacyMigration, jobs: list[RecordedJob]
) -> list[TreeMove]:
    """Every durable tree this migration has to carry across.

    Three kinds, because `--install-dir` and DRAINER_INSTALL_DIR_ENV split
    them apart: the legacy install directory's own `runtime/` tree, which holds
    every job installed there and whatever unpartitioned state the machine-wide
    singleton left; each recorded job whose definition points somewhere else,
    whose per-repository runtime tree is under *that* directory instead; and
    the log root, which no option ever relocates and which therefore holds
    every job's logs wherever its scripts are.

    A job installed at a custom directory keeps that directory — its script
    links are the operator's own and are never removed — but its runtime state
    comes along, because the definition being rewritten here is what will look
    for it at the new install directory afterwards.
    """
    moves = [
        TreeMove("runtime", migration.source / "runtime", migration.destination / "runtime")
    ]
    moves.extend(
        TreeMove(
            f"runtime for {job.identity}",
            job.runtime_dir,
            _destination_runtime(migration, job),
        )
        for job in jobs
        if job.install_dir != migration.source
        # A job installed with `--install-dir` naming what is *now* this
        # platform's default is already where this would put it. Planning that
        # as a move would be a move onto itself, and the occupied-destination
        # rule would then refuse the very installation it is there to protect.
        and job.runtime_dir != _destination_runtime(migration, job)
    )
    moves.append(TreeMove("logs", migration.source_logs, migration.destination_logs))
    # A tree already at its destination is preserved in place rather than moved
    # onto itself — which the occupied-destination rule would then refuse,
    # failing the whole migration. That is not only the per-repository runtime
    # case above: an absolute `$XDG_STATE_HOME` naming `~/Library/Logs` makes
    # the log root its own destination too, and either self-move would refuse
    # a migration this host is entitled to.
    return [
        move
        for move in moves
        if os.path.lexists(move.source) and move.source != move.destination
    ]


def _move_conflicts(migration: LegacyMigration, moves: list[TreeMove]) -> list[str]:
    """Every destination a move would land on top of.

    Whole trees rather than file by file: refusing an occupied destination
    outright is what makes a same-relative-path collision impossible, and it is
    the only policy that cannot silently overwrite, discard, or delete a
    durable record — an open incident above all. A per-repository runtime tree
    is checked against the legacy tree's own copy of that slug as well, because
    the whole-tree move above will have put one there by the time it runs.
    """
    legacy_runtime = migration.source / "runtime"
    conflicts = []
    for move in moves:
        occupied = os.path.lexists(move.destination)
        if not occupied and move.destination.parent == migration.destination / "runtime":
            occupied = os.path.lexists(legacy_runtime / move.destination.name)
        if occupied:
            conflicts.append(
                f"the {move.what} tree at {move.source} cannot be moved to "
                f"{move.destination}, which already exists"
            )
    return conflicts


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
            strict_record_document(migration.source_record),
            strict_record_document(migration.destination_record),
        ),
        backend,
    )
    if not migration.relocating:
        # Nothing moves and nothing is removed, so the only repositories this
        # run touches are the ones whose definition is not already what this
        # host would write. On a settled installation that is none of them, and
        # this is then not a migration at all -- which matters, because
        # everything below would otherwise refuse an ordinary install whenever
        # any *other* repository's drainer happened to be running.
        jobs = [job for job in jobs if _definition_is_stale(job, backend)]
        if not jobs:
            return []
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
    moves = planned_tree_moves(migration, jobs)
    conflicts = _move_conflicts(migration, moves)
    # Independently of whether anything is being moved into them. A job that
    # has never run has no tree to move, so nothing above looks at where its
    # tree is *going* -- and `ensure_dirs` would then adopt, and chmod,
    # whatever it found waiting there. Durable state already at a destination
    # is someone's record of what a drainer did, and this refuses rather than
    # absorbing it.
    arriving = {move.destination for move in moves}
    for job in jobs:
        runtime = _destination_runtime(migration, job)
        # `job.runtime_dir` is excluded because a tree already at its
        # destination is this repository's own, preserved in place rather than
        # someone else's state being adopted.
        if (
            runtime not in arriving
            and runtime != job.runtime_dir
            and os.path.lexists(runtime)
        ):
            conflicts.append(f"{runtime} already holds durable state for {job.identity}")
        logs = migration.destination_logs / job.slug
        # Excluded on the same terms as the runtime tree above: a log tree that
        # is already at its destination is this repository's own.
        if (
            logs not in arriving
            and logs != migration.source_logs / job.slug
            and os.path.lexists(logs)
        ):
            conflicts.append(f"{logs} already holds durable state for {job.identity}")
    # Every path this migration writes *through*, as opposed to the trees it
    # moves into place. `update_json_document` refuses one that is not a plain
    # file, and `write_definition_file`'s `os.replace` would silently replace
    # it; either way nothing here created what is there, so nothing here can
    # put it back. Refusing before the first write is the only answer that
    # neither loses it nor writes over it.
    conflicts.extend(
        f"{path} is where this would write, and is not a regular file"
        for path in (job.definition_path for job in jobs)
        if os.path.lexists(path) and not _is_plain_file(path)
    )
    if migration.relocating:
        # Only when the directory is going to be deleted. A run that leaves it
        # in place has no business refusing over what someone else keeps there.
        unexpected = unmanaged_entries(migration.source)
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


class Rollback:
    """The undo for everything one install changes at its destination.

    A refusal has to leave the host as the preflight found it, and the
    preflight cannot rule out a step that *fails* rather than a state it can
    see. So every mutation registers how to undo itself before it runs, and a
    failure runs them in reverse.

    `commit` marks the point of no return: once every repository is usable
    through the destination there is nothing left to strand, and undoing what
    got it there would be the destructive act rather than the safe one.
    """

    def __init__(self) -> None:
        self._actions: list[Callable[[], None]] = []
        self.committed = False

    def add(self, action: Callable[[], None]) -> None:
        self._actions.append(action)

    def commit(self) -> None:
        self._actions.clear()
        self.committed = True

    def undo(self) -> list[str]:
        """Run every action in reverse, returning what could not be undone.

        Total: one action that fails does not abandon the rest, because each
        undoes a different mutation and the ones that can still be undone
        should be. What is left is reported rather than raised — nothing here
        can repair a host whose filesystem stopped cooperating mid-rollback,
        and the operator has to be told exactly what was left where.
        """
        unrepaired = []
        for action in reversed(self._actions):
            try:
                action()
            except Exception as exc:  # noqa: BLE001 - see below
                # Every exception, not a list of the ones an undo is expected
                # to raise. Each action here undoes a different mutation
                # through a different layer -- the filesystem raises `OSError`,
                # the service-manager seam raises `ServiceManagerError`, and
                # reloading a restored definition reaches this module's own
                # `run`, which raises `InstallError` -- so an enumerated list
                # is a list that goes stale, and the one that went stale would
                # abandon every remaining undo at the first surprise. Being
                # total is the whole contract; what could not be undone is
                # reported below instead.
                unrepaired.append(str(exc))
        self._actions.clear()
        return unrepaired


def _restore_file(path: Path) -> Callable[[], None]:
    """An undo that puts `path` back exactly as it is right now.

    What the path *is*, not only what it holds. A snapshot that recorded
    "these bytes, or nothing" would read a symlink or a directory sitting
    there as nothing, and restoring nothing means unlinking it — so the
    rollback would destroy the very thing it was registered to protect.
    `os.replace`, which is how both a definition and this document are
    written, replaces a symlink rather than following it, so that is a path
    this really can reach.

    A shape this did not create and cannot faithfully recreate — a directory,
    a socket, a device — is left alone rather than removed. Refusing it before
    anything is written is the preflight's job; this is the second line.
    """
    if path.is_symlink():
        before: tuple[str, Any] = ("symlink", os.readlink(path))
    elif _is_plain_file(path):
        before = ("file", path.read_bytes())
    elif os.path.lexists(path):
        before = ("other", None)
    else:
        before = ("absent", None)

    def restore() -> None:
        kind, value = before
        if kind == "other":
            return
        if os.path.lexists(path) and not (path.is_dir() and not path.is_symlink()):
            path.unlink()
        if kind == "file":
            path.write_bytes(value)
        elif kind == "symlink":
            path.symlink_to(value)

    return restore


def _restore_document(path: Path) -> Callable[[], None]:
    """An undo for a JSON document.

    The `<name>.lock` `document_lock` puts beside it is deliberately left where
    it is, for the reason `_locked_legacy_record` gives: removing a lock file
    is how two writers end up locking different inodes and losing each other's
    entries, which is a worse thing to leave behind than an empty file the next
    write would create anyway.
    """
    return _restore_file(path)


def _restore_link(destination: Path) -> Callable[[], None]:
    """An undo for one installed script link: the target it pointed at before,
    or nothing at all when it did not exist."""
    before = os.readlink(destination) if destination.is_symlink() else None

    def restore() -> None:
        if os.path.lexists(destination):
            destination.unlink()
        if before is not None:
            destination.symlink_to(before)

    return restore


def _restore_directory(path: Path) -> Callable[[], None]:
    """An undo for `mkdir(parents=True)` and the `chmod` that may follow it.

    Both halves, because a directory tree is created in two ways that have to
    be undone differently. Every ancestor that does not exist yet is recorded,
    so the undo removes exactly the ones this run created — deepest first, and
    only while they are still empty, so a directory something else put back
    into is left alone. And the mode of one that *did* already exist is
    recorded too, since `ensure_dirs` chmods what it finds as well as what it
    makes, and a refusal that reported nothing had changed must not leave a
    directory's permissions altered.
    """
    created = []
    probe = path
    while not probe.exists():
        created.append(probe)
        if probe.parent == probe:
            break
        probe = probe.parent
    mode = path.stat().st_mode & 0o7777 if path.is_dir() else None

    def restore() -> None:
        if mode is not None and path.is_dir():
            path.chmod(mode)
        for directory in created:
            if directory.is_dir() and not any(directory.iterdir()):
                directory.rmdir()

    return restore


def _move_tree(source: Path, destination: Path) -> None:
    """Move one durable tree, leaving no state in between.

    A rename when both ends are on one filesystem. When they are not -- which
    a custom XDG root may well arrange -- the copy is made first and the source
    is dropped only once it has succeeded, so there is exactly one moment at
    which the destination becomes the authoritative copy. A failure before it
    takes the incomplete destination away and leaves the source untouched; a
    failure after it keeps the destination, because by then it is the complete
    one and the source is not.

    `shutil.move` does the same two steps but reports one outcome, which from
    outside cannot say which half failed -- and therefore cannot say which of
    the two trees is the one worth keeping.
    """
    try:
        os.replace(source, destination)
        return
    except OSError as error:
        if error.errno != errno.EXDEV:
            raise
    try:
        shutil.copytree(source, destination, symlinks=True)
    except BaseException:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    shutil.rmtree(source)


def _restore_move(move: TreeMove) -> Callable[[], None]:
    """An undo for a tree move, registered *before* it runs.

    Registering it afterwards would leave a move that failed partway
    unaccounted for, and the directory undo deliberately keeps a non-empty
    directory -- so the run would report having undone everything over a
    destination that is now occupied, and a retry would refuse over it.

    Which way to undo is read from what is there rather than from how far the
    move got. A destination with no source is a completed move and goes back.
    A source with no destination is a move that left nothing. Both at once can
    only mean the copy completed and the source removal did not, and choosing
    between two trees that both exist is what this whole path refuses to do
    anywhere else, so it is reported rather than resolved.
    """

    def restore() -> None:
        if not os.path.lexists(move.destination):
            return
        if os.path.lexists(move.source):
            raise OSError(
                f"the {move.what} tree is at both {move.source} and "
                f"{move.destination}; keep whichever is complete and remove the other"
            )
        move.source.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        _move_tree(move.destination, move.source)

    return restore


def perform_legacy_migration(
    migration: LegacyMigration,
    jobs: list[RecordedJob],
    backend,
    rollback: Rollback,
) -> dict[str, Any]:
    """Relocate the shared installation, registering the undo for every step.

    The order is the one that is safe to be *interrupted* in: the merged record
    is written durably at the destination first, so a run killed outright
    leaves one complete document rather than none; the durable trees move next,
    into destinations the preflight proved are empty; only then are the module's
    own managed paths rebound and every recorded definition rewritten and
    reloaded against them; and only once all of that has happened is the legacy
    directory removed, because a definition still naming it is a repository
    that would stop working the moment it went.

    That order alone is not enough for a step that *fails*, which is the case
    the preflight cannot rule out: a sibling whose definition cannot be
    rewritten or reloaded would otherwise be left naming trees that had already
    moved, while the newly merged record won discovery — a half-migrated
    installation rather than the refusal this owes its caller. `rollback` is
    the caller's, and already carries the script links installed before this
    ran, so undoing covers the whole destination rather than this function's
    own share of it.
    """
    moves = planned_tree_moves(migration, jobs)
    if migration.relocating:
        rollback.add(_restore_document(migration.destination_record))
        drain_prs_service.update_json_document(
            migration.destination_record,
            lambda current: merged_record_document(
                strict_record_document(migration.source_record), current
            ),
        )
    # Skipped entirely when the two are one document. There is nothing to
    # merge with itself, and this run holds that document's lock while
    # `write_discovery_record` below takes it again — which is why the lock is
    # only taken when something is being removed. See `_install_within`.
    # The legacy install directory's own tree first, so a per-repository
    # tree from elsewhere lands beside what it carried rather than under it.
    for move in moves:
        rollback.add(_restore_directory(move.destination.parent))
        move.destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Registered before the move, not after it: a move that fails partway
        # has left something to undo too.
        rollback.add(_restore_move(move))
        _move_tree(move.source, move.destination)
    # From here on every path this process resolves is the destination's.
    drain_prs_service.bind_managed_paths()
    for job in jobs:
        rollback.add(_restore_definition(job, backend))
        _reinstall_recorded_job(job, backend, rollback)
    for job in jobs:
        backend.load_definition(job.identifier)
    # Past the point of return: every repository is usable through the
    # destination, so what is left behind is debris rather than an
    # installation, and nothing that follows can strand a sibling.
    rollback.commit()
    late = LateWrites()
    if migration.relocating:
        shutil.rmtree(migration.source)
        late = _absorb_late_legacy_writes(migration, backend)
    stranded = migration.relocating and os.path.lexists(migration.source_record)
    return {
        "migrated": True,
        "relocated": migration.relocating,
        "source": str(migration.source),
        "source_logs": str(migration.source_logs),
        "destination": str(migration.destination),
        "destination_logs": str(migration.destination_logs),
        "record": str(migration.destination_record),
        "repositories": [job.identity for job in jobs],
        "legacy_record_reappeared": stranded,
        "unresolved_repositories": list(late.unresolved),
        "unmanaged_paths": list(late.unmanaged),
        "moved": [
            {"what": move.what, "from": str(move.source), "to": str(move.destination)}
            for move in moves
        ],
    }


# How many times a reappeared legacy record is absorbed before the run stops
# trying and reports it. Each pass carries whatever came back and removes the
# location again, so a writer has to win the same race repeatedly to survive
# them all; a bound rather than a loop because a pathological writer recreating
# it continuously must not hold an installer open forever.
LATE_WRITER_PASSES = 3


@dataclass(frozen=True)
class LateWrites:
    """What a writer left at the legacy location after it was removed, and
    what of it could not be carried across."""

    unresolved: tuple[str, ...] = ()
    unmanaged: tuple[str, ...] = ()


def _absorb_late_legacy_writes(migration: LegacyMigration, backend) -> LateWrites:
    """Carry across anything written back to the legacy location after it was
    removed, and name the repositories whose state could not be carried.

    The lock this transition holds serializes every writer that queues on the
    legacy record's lock file; one that queues resumes into a directory the
    removal took away and fails without recording anything. It cannot reach a
    writer that arrives *afterwards*: that one creates the directory afresh and
    opens a lock inode this transition never held, so it contends with nothing.
    No lock closes that, because there is no file left to hold one on.

    So what comes back is migrated rather than merely noticed. Each pass is the
    same work the next run of this installer would do -- merge the record it
    finds, rewrite and reload the definitions it names against this
    installation, remove the location again -- which is what turns "installed
    where nothing looks" back into an installed repository. A pass that finds
    nothing is the end of it.

    What it cannot carry is a repository that now has durable state in both
    places. Those are named rather than resolved, because the caller has to
    say so: a later run of this installer will refuse over exactly those
    trees, so telling the operator to re-run and leave it at that would be
    advice that does not work.
    """
    collisions: list[str] = []
    for _ in range(LATE_WRITER_PASSES):
        if not os.path.lexists(migration.source_record):
            return LateWrites(unresolved=tuple(collisions))
        try:
            late = strict_record_document(migration.source_record)
        except InstallError:
            # Unreadable is still "something is there", and the caller reports
            # it. Nothing here can merge a document it cannot parse.
            return LateWrites(unresolved=tuple(collisions))
        drain_prs_service.update_json_document(
            migration.destination_record,
            lambda current, late=late: merged_record_document(late, current),
        )
        for job in recorded_jobs(late, backend):
            # Both of this repository's durable trees, on the same terms. A
            # late writer resolves through paths frozen at the old
            # installation, so it writes a status file and incidents under the
            # old runtime root *and* its service and dated logs under the old
            # log root -- and the log root is not inside the install directory,
            # so the removal below would not even take it, only orphan it.
            for source, destination in (
                (job.runtime_dir, _destination_runtime(migration, job)),
                (
                    migration.source_logs / job.slug,
                    migration.destination_logs / job.slug,
                ),
            ):
                if source == destination or not os.path.lexists(source):
                    continue
                if os.path.lexists(destination):
                    # One repository with a durable tree at both locations,
                    # which is what a late *start* for an already-migrated
                    # repository leaves. Merging them would have to choose
                    # which status, whose incidents and which logs survive, and
                    # none of those answers is this installer's to give -- so
                    # both are kept and the run names the repository, rather
                    # than the removal below quietly taking one side.
                    if job.identity not in collisions:
                        collisions.append(job.identity)
                else:
                    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    _move_tree(source, destination)
            _reinstall_recorded_job(job, backend, Rollback())
            backend.load_definition(job.identifier)
        if collisions:
            return LateWrites(unresolved=tuple(collisions))
        # The same question the preflight asks before it removes this
        # directory, asked again because a writer that recreated it may have
        # put something there that is not this installer's -- and clearing it
        # is no more this run's to do the second time than the first.
        unmanaged = unmanaged_entries(migration.source)
        if unmanaged:
            return LateWrites(unmanaged=tuple(unmanaged))
        shutil.rmtree(migration.source, ignore_errors=True)
        # The log root is its own tree rather than one inside the installation,
        # so what a late writer recreated there is removed only once every
        # repository's logs have been carried out of it and nothing is left.
        _remove_if_empty(migration.source_logs)
    return LateWrites(unresolved=tuple(collisions))


def _remove_if_empty(path: Path) -> None:
    if _is_plain_directory(path) and not any(path.iterdir()):
        path.rmdir()


def _restore_definition(job: RecordedJob, backend) -> Callable[[], None]:
    """An undo that puts one repository's definition back and hands the
    restored bytes to the service manager, so the manager is holding what the
    file says rather than the version this run replaced."""
    restore_file = _restore_file(job.definition_path)

    def restore() -> None:
        restore_file()
        backend.load_definition(job.identifier)

    return restore


def _rolled_back(rollback: Rollback, failure: Exception, source: Path | None) -> str:
    """Undo whatever this install had changed, and describe what happened.

    Past `commit` there is nothing to undo and nothing that could strand a
    repository, so a failure there is reported as the completed relocation it
    is, with the one piece of cleanup the operator has to finish by hand.
    """
    unrepaired = rollback.undo()
    # After the destination record is back to what it was, so this resolves the
    # installation the host actually has again.
    drain_prs_service.bind_managed_paths()
    if rollback.committed:
        return (
            f"The PR drainer installation was relocated, but {source} could not "
            f"then be removed: {failure} Every repository is installed and usable "
            "at the new location; remove that directory by hand."
        )
    message = (
        f"The PR drainer installation could not be completed: {failure} "
        "Every change it had made was undone, and nothing was installed."
    )
    if unrepaired:
        message += " Some of that could not be undone: " + "; ".join(unrepaired)
    return message


def _reinstall_recorded_job(job: RecordedJob, backend, rollback: Rollback) -> None:
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
        rebuilt = _rebuilt_job(job)
        # `ensure_dirs` makes this repository's runtime, incident and log
        # directories -- and chmods whichever of them it finds already there.
        # A legacy job that has never run has none of them, so without this a
        # rolled-back migration would leave a destination installation behind
        # while reporting that every change was undone. Registered before the
        # call, in the order it creates them, so the undo removes them from the
        # deepest first.
        for directory in (
            drain_prs_service.INSTALL_DIR,
            rebuilt.runtime_dir,
            rebuilt.incident_dir,
            rebuilt.log_dir,
            rebuilt.definition_path.parent,
        ):
            rollback.add(_restore_directory(directory))
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

    migration = plan_legacy_migration(install_dir)
    with contextlib.ExitStack() as scope:
        if migration is not None:
            scope.enter_context(_selected_install_dir(install_dir))
        if migration is not None and migration.relocating and not dry_run:
            # Only when something is removed, which is the only thing this
            # lock protects against. A run that leaves the installation in
            # place strands nobody by definition — a writer that adds a
            # repository during it simply is not one of the definitions this
            # rewrites, and its own is already correct. Taking it anyway would
            # deadlock: with one document rather than two, the lock held here
            # is the lock `write_discovery_record` goes on to ask for.
            #
            # Held from before the preflight reads the legacy record until
            # after the legacy installation is gone, because those two are the
            # ends of one transition: the record says which repositories exist,
            # and the removal takes away the controller every one of them still
            # names. A writer that slipped in between — a normal install or a
            # start for another repository, still bound to the legacy
            # controller — would add an entry this run never saw, and that
            # repository would keep a definition pointing into a directory this
            # run then deleted.
            #
            # This is the only place two of these documents are held at once.
            # The order is always source then destination — `perform` takes the
            # destination's inside, through `update_json_document` — so no
            # cycle exists for anything else to deadlock against; every other
            # writer in this repository holds exactly one.
            scope.enter_context(_locked_legacy_record(migration))
        return _install_within(
            repo,
            install_dir,
            job=job,
            backend=backend,
            migration=migration,
            ntfy_url=ntfy_url,
            resolved_config_path=resolved_config_path,
            dry_run=dry_run,
        )


def _install_within(
    repo: Path,
    install_dir: Path,
    *,
    job: drain_prs_service.DrainerJob,
    backend,
    migration: LegacyMigration | None,
    ntfy_url: str | None,
    resolved_config_path: str | None,
    dry_run: bool,
) -> dict[str, Any]:
    """The install itself, with the legacy record's lock already held when one
    is being relocated. Split out only so that lock spans exactly this."""
    # Ahead of every write below, including the script links: a migration this
    # host cannot perform safely must leave it exactly as it was found, and
    # installing at the destination anyway is the one fallback that is never
    # available — a fresh installation standing beside a retained legacy one is
    # the split state the whole relocation exists to close. Read under the lock
    # above, so the repositories it finds are the repositories there are.
    migration_jobs = (
        preflight_legacy_migration(migration, backend) if migration is not None else []
    )
    if migration is not None and not migration.relocating and not migration_jobs:
        # An installation already at this platform's own location with nothing
        # stale left in it is not a migration at all, however it is spelled.
        migration = None

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

    # One undo scope over everything this run changes at the destination. The
    # links belong inside it as much as the relocation does: a refusal that
    # left them behind would report that nothing was installed while having
    # created the destination installation.
    rollback = Rollback()
    migration_report = skipped_legacy_migration(install_dir)
    try:
        rollback.add(_restore_directory(install_dir))
        link_results = {}
        for key, destination in destinations.items():
            rollback.add(_restore_link(destination))
            link_results[key] = install_symlink(sources[key], destination)
        # After the links, because every definition it rewrites names the
        # controller inside the destination directory, and before the record
        # and option writes below, because those go to whichever document this
        # process resolves once the relocation has rebound its managed paths.
        if migration is not None:
            migration_report = perform_legacy_migration(
                migration, migration_jobs, backend, rollback
            )
    except Exception as exc:
        raise InstallError(
            _rolled_back(
                rollback, exc, migration.source if migration is not None else None
            )
        ) from exc
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
                if migration["legacy_record_reappeared"]:
                    print(
                        f"WARNING: {migration['source']} was written again after the "
                        "relocation, so another install or start was running at the "
                        "same time, and what it recorded is where nothing now looks "
                        "for it."
                    )
                    unresolved = migration["unresolved_repositories"]
                    if unresolved:
                        # Naming the repair rather than "re-run", which would
                        # be advice that does not work: a later run refuses
                        # over exactly the trees this could not carry.
                        print(
                            "  " + ", ".join(unresolved) + " now has runtime state "
                            "or logs in both the old and the new location. Nothing "
                            "here can choose which status file, whose incidents and "
                            "which logs survive, so both were kept and a re-run will "
                            "refuse over them. Stop that repository's drainer, keep "
                            "whichever of each pair you want, remove the other, then "
                            "re-run this installer."
                        )
                    elif migration["unmanaged_paths"]:
                        # A re-run refuses over these rather than carrying
                        # anything, so saying "re-run" alone would again be
                        # advice that does not work.
                        print(
                            "  It also left files this installer did not put there: "
                            + ", ".join(migration["unmanaged_paths"])
                            + ". They were not touched, and nothing there was "
                            "removed. Move them elsewhere, then re-run this "
                            "installer."
                        )
                    else:
                        print("  Re-run this installer to carry it across.")
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
