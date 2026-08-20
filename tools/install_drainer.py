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
import time
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import drain_prs
import drain_prs_service
import kanban_config
import service_manager


# The controller resolves the repository identity and, through
# `tools/service_manager.py`, the identifier derived from it, the definition's
# path, and the manager target; this installer resolves a job through the
# controller and reaches the service manager through that same backend rather
# than restating any of them. Where the installation *is*, and where a fresh
# one goes, are resolved the same way, through `tools/kanban_config.py`: it is
# the one module that writes each managed location down, for every platform it
# has a convention on, and the only one both this installer and the installed
# controller can import. `default_install_dir` below is where those two
# answers meet, because a host relocating a pre-XDG installation is installing
# somewhere other than where its installation currently is.


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


# --- Relocating a pre-XDG `~/Library` installation -------------------------
#
# A host that installed before `tools/kanban_config.py` resolved these paths
# per platform has its installation at the macOS-shaped `~/Library` locations,
# and discovery keeps finding it there — correctly, and forever. This is the
# one thing that moves it: on a platform that is not macOS, a default install
# run relocates that whole installation to this platform's own convention and
# then takes the old one away.
#
# The installation is shared. Its discovery record and its four script links
# serve every repository at once, while each repository owns its definition,
# its runtime state, its logs, and its incidents. Every definition embeds the
# controller path, the install-directory environment, the working directory
# and the log paths, so a removal that did not first rewrite them would strand
# every sibling repository — which is why this is one transition over the
# whole installation rather than a move of the directory it lives in.


# Every entry this installer puts inside an install directory, by the relative
# name that selects each managed slot and the object each slot must be for
# that entry to be this installer's. The name selects; the type proves; every
# other name refuses, because an install directory holding something nobody
# here created is not one this can safely take apart.
_MANAGED_LINK_NAMES = (
    "drain_prs.py",
    "drain_prs_service.py",
    "kanban_config.py",
    "service_manager.py",
)
_RUNTIME_DIRECTORY_NAME = "runtime"
_BYTECODE_CACHE_NAME = "__pycache__"
_BYTECODE_SUFFIX = ".pyc"

# The managed slots a run leaves standing wherever it finds them, rather than
# taking away with the installation they sit in. The lock, because a writer may
# be queued on its inode and unlinking it would hand the next writer a
# different lock from the one that writer is waiting on. The marker, because it
# is what a process still bound to this location reads to learn that it is
# stale. And the runtime guard, because it is the bound that stops a controller
# still bound here from writing a runtime, incident or log tree at all: a run
# that lifted it, even to put it back at the end, would reopen for the length
# of that run exactly the window it exists to close.
#
# The record path's own seal is deliberately *not* one of these. A run that
# cannot finish reconciling this location leaves that path open, because the
# operator has to see the location as it stands and the re-run that follows
# their reconciliation is what seals it again. The guard answers a different
# question — not "what does this location look like" but "may anything be
# written here" — and the answer to that one does not change while an operator
# is deciding.
_RETAINED_SLOTS = frozenset({"lock", "marker", "guard"})


# How long one run waits, having released the legacy record's lock, before
# taking it again. `flock` has no handoff: releasing a lock does not give it to
# a waiter, it only makes that waiter runnable, and nothing orders a wakeup
# against this process asking for the lock again. So a run that re-took it
# immediately could outrun a writer that had been queued on it for the whole
# transition and report a location that writer is about to write into. This is
# the pause that makes losing that race a scheduling accident rather than the
# ordinary case: a process blocked in `flock` is runnable the instant the lock
# is released, and this is orders of magnitude longer than it takes to be
# scheduled. It is not a proof, because none is available -- `flock` cannot be
# asked whether anyone is waiting, and a writer that acquires after this run's
# last look is past any process that terminates at all. What answers that one
# is not this pause but the seals `_seal_emptied_location` leaves once the last
# look finds the location clear: a writer arriving afterwards finds the record
# path and the runtime root occupied by objects it cannot write through, so it
# fails before it creates anything rather than leaving state a later run has to
# find.
_LOCK_HANDOFF_SECONDS = 0.1

# How many times one run carries a recreated legacy location across before it
# stops and reports what is still there. Bounded rather than looped: a writer
# that keeps recreating that location would otherwise hold an installer open
# for as long as it kept winning, and an installer that never returns is worse
# than one that names the state it could not resolve. Every writer that merely
# queued on the legacy record's lock is already excluded by the transition that
# holds it, so only a writer arriving after each clear can extend this sweep at
# all.
_LATE_WRITER_PASSES = 3


class RelocationFailed(InstallError):
    """A relocation that had already mutated something when it failed.

    Carries what the rollback could not undo beside the failure that stopped
    the transition, because a host left holding residue needs both to know
    what to repair.
    """

    def __init__(self, message: str, residue: list[str]):
        super().__init__(message)
        self.residue = list(residue)


class RelocationUnresolved(InstallError):
    """A relocation that completed and left durable state back at the location
    it emptied.

    The destination is the installation from here on -- this is not a failure
    the relocation is rolled back over, and rolling it back would be the one
    action that could lose what a late writer recorded. What it is instead is
    an install that must not report success: a host with a repository's status,
    incidents or logs in two places has a decision to make that this installer
    may not make for it, and the report carries every repository and every
    retained path that decision is about.
    """

    def __init__(self, message: str, report: dict[str, Any]):
        super().__init__(message)
        self.report = report


def legacy_install_dir() -> Path:
    """The `~/Library`-spelled install directory a pre-XDG host installed to.

    `tools/kanban_config.py`'s answer rather than a spelling of its own: it is
    the one module that writes each managed location down, and naming the
    source of a relocation a second way is exactly how a relocation moves
    something other than what discovery finds.
    """
    return kanban_config.macos_drainer_install_dir()


def legacy_log_root() -> Path:
    """The `~/Library`-spelled log root, on the same terms."""
    return kanban_config.macos_drainer_log_dir()


def record_name() -> str:
    """The discovery record's filename, which is the same at every location it
    can resolve to and is therefore taken from the resolver rather than
    restated."""
    return kanban_config.drainer_record_path().name


def default_install_dir() -> Path:
    """Where a run that passes no `--install-dir` installs.

    Never `KANBAN_DRAINER_INSTALL_DIR`. `--install-dir` is the only thing that
    selects a custom destination, and a variable this process merely inherited
    deciding it would silently turn every ordinary run on a host that exports
    it into a custom one — which is exactly the run that would otherwise have
    relocated a `~/Library` installation, so the installation would stay there
    forever. That variable's job is the other direction: the installed
    controller is *spawned* with the destination this run selected, so it
    resolves the same installation the installer just wrote.

    On macOS that destination is wherever the installation already is, since
    nothing ever relocates a macOS installation. On every other platform it is
    this platform's own convention, which is where a `~/Library` installation
    is relocated to.
    """
    if kanban_config.is_macos():
        return kanban_config.installed_drainer_dir()
    return kanban_config.default_drainer_install_dir()


def _legacy_lock_path(legacy_dir: Path) -> Path:
    """The lock beside the discovery record at the legacy location.

    Spelled the way `drain_prs_service.document_lock` spells it — the record's
    own name with `.lock` after it — because this is the file that helper
    opens, and a second spelling of it would close a path nothing meets.
    """
    return legacy_dir / (record_name() + ".lock")


def _relocation_notice(plan: RelocationPlan) -> tuple[str, str]:
    """What happened at this location, and what to do about it.

    One place, because it is written into two artifacts: the relocation marker
    every seal points at, and the retained lock, which is what the refusal a
    stale transition meets names by path. A copy of the controller predating
    every gate here renders a fault as the path it could not use and nothing
    more, so whatever those paths lead to has to carry the rest.
    """
    return (
        f"The PR drainer installation at {plan.legacy_dir} was relocated to "
        f"{plan.install_dir}. Nothing may be written at {plan.legacy_dir} "
        "again: a controller still bound to this location fails instead of "
        "rebuilding what the relocation moved.",
        "Run the command again. A controller resolves its installation when "
        f"it starts, and this host now resolves {plan.install_dir}. If it "
        f"still resolves {plan.legacy_dir}, the installed copy predates that "
        "resolution — re-run `python3 tools/install_drainer.py --path "
        f"<checkout>` from the Kanban checkout to reinstall it against "
        f"{plan.install_dir}.",
    )


def _plain_file(path: Path) -> bool:
    return not path.is_symlink() and path.is_file()


def _plain_directory(path: Path) -> bool:
    return not path.is_symlink() and path.is_dir()


def _is_bytecode_cache(path: Path) -> bool:
    """Whether this is a `__pycache__` the interpreter left here.

    Recognised only when it holds nothing but plain `.pyc` files, so a
    directory that merely carries the name is not removed with the
    installation.
    """
    if not _plain_directory(path):
        return False
    return all(
        _plain_file(entry) and entry.suffix == _BYTECODE_SUFFIX
        for entry in path.iterdir()
    )


def _is_relocation_seal(path: Path) -> bool:
    """Whether this is a path a relocation sealed.

    A symlink to the relocation marker beside it, which is three things at
    once. It is neither a regular file nor a directory, which is what refuses
    the two writers that could recreate what a relocation removed, in *every*
    copy of the controller including the copies predating every gate in this
    repository — the only thing that reaches them.
    `drain_prs_service.update_json_document` has refused a record path that is
    present and not a regular file since the commit that introduced the
    discovery record, and `ensure_dirs` cannot make a directory underneath a
    path that is not one, so a runtime root sealed like this stops that helper
    before it creates anything at all. It reads as the relocation notice rather
    than as a document, since `_read_json_object` follows it to the marker and
    finds no `repositories` table. And it says, to anyone who lists that
    directory, what happened to the installation that used to be there.

    Recognised by what it points at rather than by being a symlink, because
    this installer only owns the ones it wrote: a symlink to anywhere else is
    an entry it did not create and must not take apart.
    """
    if not path.is_symlink():
        return False
    try:
        return os.readlink(path) == drain_prs_service.RELOCATION_MARKER_NAME
    except OSError:
        return False


def _managed_slot(entry: Path, record: str) -> str | None:
    """Which managed slot `entry` occupies, or None when it is not one.

    Ownership is decided by what an entry *is*: the expected relative name
    selects a slot, and the object type that slot requires is what proves the
    entry was put there by this installer. A name nothing expects, and an
    expected name holding the wrong kind of object, both answer None — which
    is what refuses the whole relocation rather than removing something this
    installer did not create.
    """
    name = entry.name
    if name in _MANAGED_LINK_NAMES:
        return "link" if entry.is_symlink() else None
    if name == record:
        if _plain_file(entry):
            return "record"
        # The seal an earlier run left where the record was. Managed, so a run
        # reconciling what a writer put back beside it recognises this location
        # as one this installer took apart, and removable, unlike the runtime
        # guard below: `_RETAINED_SLOTS` says why the two differ.
        return "tombstone" if _is_relocation_seal(entry) else None
    if name == record + ".lock":
        return "lock" if _plain_file(entry) else None
    if name == drain_prs_service.RELOCATION_MARKER_NAME:
        return "marker" if _plain_file(entry) else None
    if name == _RUNTIME_DIRECTORY_NAME:
        if _plain_directory(entry):
            return "runtime"
        # The guard an earlier run left where the runtime root was. Managed on
        # exactly the terms the record's own seal is: a run reconciling what a
        # writer put back beside it recognises this location as one this
        # installer took apart, and never removes it, because taking it away
        # would reopen the path it closed.
        return "guard" if _is_relocation_seal(entry) else None
    if name == _BYTECODE_CACHE_NAME:
        return "cache" if _is_bytecode_cache(entry) else None
    return None


def _same_location(left: Path, right: Path) -> bool:
    """Whether two paths name the same directory once resolved.

    `main` resolves `--install-dir` before it reaches here while the resolvers
    answer with the unresolved home-relative spelling they declare, so a home
    reached through a symlink would otherwise make a plain default run read as
    a custom destination and relocate nothing.
    """
    return left == right or left.resolve() == right.resolve()


def _same_tree(left: Path, right: Path) -> bool:
    if left == right:
        return True
    try:
        return left.exists() and right.exists() and left.samefile(right)
    except OSError:
        return False


def _read_record(path: Path, description: str) -> dict[str, Any]:
    """One discovery record, or a refusal naming what is wrong with it.

    Both records get this, not only the legacy one: the merge below preserves
    the destination's keys, and it cannot preserve them out of a document that
    will not parse or is not the shape a record has. An absent record is the
    ordinary answer and reads as an empty document.
    """
    if not os.path.lexists(path):
        return {}
    if _is_relocation_seal(path):
        # The absence it stands for. A sealed path holds no document, and
        # reading it as a refusal would make a run reconciling the trees beside
        # it fail over an earlier run's own work.
        return {}
    if not _plain_file(path):
        raise InstallError(
            f"Refusing to relocate: the {description} discovery record at {path} is "
            "not a regular file. Remove or repair it, then re-run the installer."
        )
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, OSError, json.JSONDecodeError) as exc:
        raise InstallError(
            f"Refusing to relocate: the {description} discovery record at {path} is "
            f"unreadable ({exc}). Repair it, then re-run the installer."
        ) from exc
    if not isinstance(document, dict):
        raise InstallError(
            f"Refusing to relocate: the {description} discovery record at {path} is "
            "not a JSON object."
        )
    # Present-and-not-a-table, which includes a present `null`: absent is the
    # ordinary shape of a record no repository has been installed into yet,
    # while a key that is there and holds something other than a table is a
    # document this cannot merge.
    key = drain_prs_service.RECORD_REPOSITORIES_KEY
    if key in document and not isinstance(document[key], dict):
        raise InstallError(
            f"Refusing to relocate: the {description} discovery record at {path} has "
            f"a non-table {key!r}."
        )
    return document


def _merge_records(
    legacy: dict[str, Any], destination: dict[str, Any]
) -> dict[str, Any]:
    """The one document the destination keeps, with the destination winning
    per key at both levels.

    Top level first, so a `ntfy_url` already configured at the destination is
    not replaced by the one the legacy installation carried; then the
    `repositories` table, so a repository installed only under the legacy
    record survives rather than silently vanishing, and one present at both
    keeps the destination's entry.
    """
    key = drain_prs_service.RECORD_REPOSITORIES_KEY
    merged = {**legacy, **destination}
    if key in legacy or key in destination:
        merged[key] = {
            **(legacy.get(key) or {}),
            **(destination.get(key) or {}),
        }
    return merged


@dataclass(frozen=True)
class RelocationRepository:
    """One recorded repository, recovered exactly enough to be moved."""

    identity: str
    slug: str
    checkout: Path
    identifier: str
    definition_path: Path
    source_install_dir: Path
    source_runtime_dir: Path
    legacy_runtime_dir: Path
    destination_runtime_dir: Path
    source_log_dir: Path
    destination_log_dir: Path
    record_entry: dict[str, Any]

    def trees(self) -> tuple[tuple[str, Path, Path], ...]:
        """Every durable tree this repository has, by kind and by where it
        goes. One declaration, because the plan refuses over these, the
        transition moves them, and the reconciliation carries them.

        The runtime tree its own definition names, its log tree, and — only
        when that is somewhere else — the runtime tree at the legacy location
        itself. That last one is what a repository keeps there when a run could
        not carry it: the definition is rewritten to the destination, so a plan
        that asked only what the definition names would never see the tree
        again, and the re-run this installer's own remediation tells the
        operator to perform would report success over exactly the tree it told
        them to reconcile.
        """
        trees = [
            ("runtime", self.source_runtime_dir, self.destination_runtime_dir),
            ("log", self.source_log_dir, self.destination_log_dir),
        ]
        if not _same_tree(self.legacy_runtime_dir, self.source_runtime_dir):
            trees.insert(
                1,
                ("runtime", self.legacy_runtime_dir, self.destination_runtime_dir),
            )
        return tuple(trees)

    def report(self) -> dict[str, Any]:
        return {
            "repository": self.identity,
            "checkout": str(self.checkout),
            "identifier": self.identifier,
            "definition": str(self.definition_path),
            "install_dir": str(self.source_install_dir),
            "runtime": {
                "source": str(self.source_runtime_dir),
                "destination": str(self.destination_runtime_dir),
            },
            "legacy_runtime": str(self.legacy_runtime_dir),
            "logs": {
                "source": str(self.source_log_dir),
                "destination": str(self.destination_log_dir),
            },
        }


@dataclass(frozen=True)
class RelocationPlan:
    """Everything the transition below will do, decided before it does any of
    it. Building this is what refuses; applying it is what mutates."""

    install_dir: Path
    log_root: Path
    legacy_dir: Path
    legacy_record: Path
    destination_record: Path
    legacy_log_root: Path
    merged_record: dict[str, Any]
    repositories: tuple[RelocationRepository, ...]
    removable: tuple[Path, ...]

    def report(self) -> dict[str, Any]:
        return {
            "source": str(self.legacy_dir),
            "destination": str(self.install_dir),
            "record": str(self.destination_record),
            "log_root": str(self.log_root),
            "repositories": [entry.report() for entry in self.repositories],
            "removes": [str(path) for path in self.removable],
        }


def _recover_repository(
    identity_key: Any,
    entry: Any,
    *,
    backend: service_manager.ServiceManagerBackend,
    remote_name: str,
    install_dir: Path,
    log_root: Path,
    legacy_dir: Path,
    legacy_logs: Path,
) -> RelocationRepository:
    """One record entry, recovered exactly, or a refusal naming what could not
    be.

    Exactly means every value the transition has to act on: the canonical
    identity the entry is filed under, the checkout its job runs against, the
    identifier and definition path *this host* derives for it, and the install
    directory its own definition names — which is where its runtime state
    actually is, since `--install-dir` moves that state without moving the
    record. A relocation that guessed any of them would rewrite a definition
    for a job it had not found, or leave a repository's state behind.
    """
    where = f"the discovery record entry for {identity_key!r}"
    if not isinstance(identity_key, str) or not isinstance(entry, dict):
        raise InstallError(f"Refusing to relocate: {where} is not a repository record.")
    try:
        identity = drain_prs_service.normalize_identity(identity_key)
    except drain_prs_service.ServiceError as exc:
        raise InstallError(
            f"Refusing to relocate: {where} is not filed under a canonical GitHub "
            f"repository ({exc})."
        ) from exc
    if identity != identity_key:
        raise InstallError(
            f"Refusing to relocate: {where} is filed under a key that is not its own "
            f"canonical identity {identity!r}."
        )
    checkout = entry.get("repository")
    if not isinstance(checkout, str) or not checkout:
        raise InstallError(f"Refusing to relocate: {where} names no checkout.")
    checkout_path = Path(checkout)
    if not checkout_path.is_dir():
        raise InstallError(
            f"Refusing to relocate: {where} names the checkout {checkout}, which is "
            "not a directory. Re-install or uninstall that repository, then re-run "
            "the installer."
        )
    # The checkout has to be a checkout *of this repository*, not merely a
    # directory. A stale entry pointing one identity at another repository's
    # clone would otherwise produce a definition whose `--path` and `--repo`
    # disagree — a job that starts and immediately refuses itself.
    try:
        checkout_identity = drain_prs_service.repository_identity(
            checkout_path, remote_name
        )
    except drain_prs_service.ServiceError as exc:
        raise InstallError(
            f"Refusing to relocate: {where} names the checkout {checkout}, whose "
            f"canonical identity cannot be read ({exc})."
        ) from exc
    if checkout_identity != identity:
        raise InstallError(
            f"Refusing to relocate: {where} names the checkout {checkout}, which is "
            f"a clone of {checkout_identity} rather than of {identity}. Re-install "
            "or uninstall that repository, then re-run the installer."
        )
    try:
        slug = drain_prs_service.repository_slug(identity)
    except drain_prs_service.ServiceError as exc:
        raise InstallError(f"Refusing to relocate: {where} ({exc}).") from exc
    identifier = backend.service_identifier(slug)
    definition_path = backend.definition_path(identifier)
    if not _plain_file(definition_path):
        raise InstallError(
            f"Refusing to relocate: {where} derives the {backend.definition_label()} "
            f"{definition_path}, which is not a regular file on this host. Re-install "
            "or uninstall that repository, then re-run the installer."
        )
    named = backend.definition_environment(identifier).get(
        kanban_config.DRAINER_INSTALL_DIR_ENV
    )
    if not named or not os.path.isabs(named):
        raise InstallError(
            f"Refusing to relocate: the {backend.definition_label()} at "
            f"{definition_path} names no absolute "
            f"{kanban_config.DRAINER_INSTALL_DIR_ENV}, so the runtime state of "
            f"{identity} cannot be found. Re-install that repository, then re-run "
            "the installer."
        )
    source_install_dir = Path(named)
    return RelocationRepository(
        identity=identity,
        slug=slug,
        checkout=checkout_path,
        identifier=identifier,
        definition_path=definition_path,
        source_install_dir=source_install_dir,
        source_runtime_dir=source_install_dir / _RUNTIME_DIRECTORY_NAME / slug,
        legacy_runtime_dir=legacy_dir / _RUNTIME_DIRECTORY_NAME / slug,
        destination_runtime_dir=install_dir / _RUNTIME_DIRECTORY_NAME / slug,
        source_log_dir=legacy_logs / slug,
        destination_log_dir=log_root / slug,
        # Restated from what this host derives rather than carried across,
        # exactly as `write_discovery_record` restates it on every install: a
        # copied-forward identifier or definition path that disagrees with the
        # job on disk is a record Kanban cannot discover or run this
        # repository through, and the merge alone would preserve it. Every
        # other key the entry carried — `config_path` above all — survives
        # beside them, which is why only the service-manager keys are dropped.
        record_entry={
            **{
                key: value
                for key, value in entry.items()
                if key not in service_manager.RECORD_KEYS
            },
            **backend.record_entry(identifier, definition_path),
            "repository": str(checkout_path),
        },
    )


def _require_nothing_live(
    repositories: tuple[RelocationRepository, ...],
    backend: service_manager.ServiceManagerBackend,
) -> None:
    """Refuse while any recorded repository is draining.

    Every recorded repository, not merely the one being installed: this run
    takes away the controller every one of their definitions names, and a
    drainer that is mid-merge when that happens has nothing left to finish
    with. Both signals, because a checkout can be draining under
    `drain_prs.py --pr` with no managed job running at all.
    """
    for entry in repositories:
        if backend.is_running(entry.identifier):
            raise InstallError(
                f"Refusing to relocate while the PR drainer for {entry.identity} is "
                "running. Stop it first."
            )
        if repository_drainer_running(entry.checkout):
            raise InstallError(
                f"Refusing to relocate while a drainer is running in "
                f"{entry.checkout} for {entry.identity}. Stop it first."
            )


def _require_tree_shape(kind: str, path: Path, identity: str) -> None:
    """Refuse a runtime or log path that exists and is not a directory.

    Moving it would carry the corruption to the destination, where nothing
    would notice: a regular file survives a rename and satisfies "the tree
    arrived", and the legacy installation is then removed around it. The next
    controller is the one that finds out, when `ensure_dirs` tries to create a
    directory at a path already occupied by a file.
    """
    if not os.path.lexists(path):
        return
    if _plain_directory(path):
        return
    raise InstallError(
        f"Refusing to relocate: {identity}'s {kind} path {path} is not a "
        "directory. Move or remove it, then re-run the installer."
    )


def _fence_checkout(entry: RelocationRepository) -> Any:
    """Hold one recorded checkout's own run lock for this transition.

    `_require_nothing_live` above reads a PID file, and a read is a snapshot:
    a `drain_prs.py` run starting one instant later would take that checkout
    and drain it while this run moved its runtime tree and removed the
    controller its own installation names — and whatever it wrote on the way
    would not be in a plan computed before it existed. The record locks cannot
    exclude it, because the drainer does not take them.

    So this takes the lock the drainer itself takes, through
    `drain_prs.acquire_lock` rather than a second spelling of it: one
    implementation, one contract, and a run that starts after this point fails
    where it stands naming the holder instead of proceeding. The dry-run shape
    is the right one — it takes only the `.git` rendezvous every mode takes,
    and writes nothing at all into a checkout this installer has no business
    modifying.
    """
    try:
        return drain_prs.acquire_lock(entry.checkout, dry_run=True)
    except drain_prs.RunLockedError as exc:
        raise InstallError(
            f"Refusing to relocate: a drainer holds the run lock for "
            f"{entry.checkout} ({entry.identity}). {exc} Stop it first."
        ) from exc
    except (drain_prs.DrainError, OSError) as exc:
        raise InstallError(
            f"Refusing to relocate: {entry.identity}'s checkout {entry.checkout} "
            f"could not be locked against a concurrent drainer ({exc})."
        ) from exc


def _fence_controllers(
    entry: RelocationRepository, already: set[Path]
) -> list[int]:
    """Hold every controller lock that could exist for this repository.

    A controller that is neither a managed running job nor holding the
    checkout's run lock is still a writer: `drain_prs_service.run_service`
    takes its own `controller.lock` inside its record-locked startup
    transaction and keeps it for the process's life, before it has spawned any
    drainer. Neither liveness signal sees that, and its `_supervise` would
    resume against paths this run had removed.

    Both ends, source and destination alike, because that is where this run
    writes — and once only when they are the same tree, since `flock` is per
    open file description and a second acquisition of one lock would block
    against this very process.

    A runtime directory that does not exist, or one holding no lock file at
    all, holds no lock: the file is what a controller creates when it takes
    one. None can appear underneath us either, because a controller acquires
    that lock *while holding the discovery record's lock*, which the caller
    holds around this — so one either had it before this started or cannot get
    it at all.

    `already` is every runtime directory this process has taken a lock in, and
    it is consulted rather than optional: the reconciliation recovers
    repositories the transition may already have fenced, and a second
    acquisition of a lock this process holds blocks against this very process.
    """
    taken: list[int] = []
    locked: list[Path] = []
    directories = [entry.source_runtime_dir]
    if not _same_tree(entry.source_runtime_dir, entry.destination_runtime_dir):
        directories.append(entry.destination_runtime_dir)
    for runtime in directories:
        if runtime in already or not _plain_directory(runtime):
            continue
        # Only a lock that already exists is taken. A controller creates that
        # file when it takes the lock, so its absence means none ever has --
        # and creating one here would be this run mutating an installation
        # before it had finished deciding whether it may.
        if not os.path.lexists(drain_prs_service.controller_lock_path(runtime)):
            continue
        try:
            taken.append(drain_prs_service.acquire_controller_lock(runtime))
        except drain_prs_service.ServiceError as exc:
            for descriptor in taken:
                os.close(descriptor)
            raise InstallError(
                f"Refusing to relocate: a PR drainer controller is running for "
                f"{entry.identity} and holds {runtime}. Stop it first. ({exc})"
            ) from exc
        locked.append(runtime)
    # Recorded only once every lock this call takes is held, because the
    # failure path above closes the ones it had: remembering a descriptor that
    # is no longer open would leave that runtime directory fenced by nothing
    # while every later caller believed it was.
    already.update(locked)
    return taken


class _Fences:
    """Every lock this run holds against a live drainer or controller.

    One holder, on one stack, because `flock` is per open file description and
    a second acquisition of a lock this process already holds blocks against
    this very process. The reconciliation recovers repositories the transition
    may already have fenced, and a second pass recovers the ones the first did,
    so what has been taken has to be remembered rather than re-asked.

    The stack it registers on outlives the discovery records' locks, because
    the reconciliation moves trees and rewrites definitions after those locks
    end and needs the same exclusion the transition had.
    """

    def __init__(self, stack: contextlib.ExitStack) -> None:
        self._stack = stack
        self._checkouts: set[Path] = set()
        self._runtimes: set[Path] = set()

    @property
    def checkouts(self) -> frozenset[Path]:
        return frozenset(self._checkouts)

    def hold_checkout(self, entry: RelocationRepository) -> None:
        if entry.checkout in self._checkouts:
            return
        self._stack.callback(_fence_checkout(entry).close)
        self._checkouts.add(entry.checkout)

    def hold_controllers(self, entry: RelocationRepository) -> None:
        for descriptor in _fence_controllers(entry, self._runtimes):
            self._stack.callback(os.close, descriptor)

    def hold(self, entry: RelocationRepository) -> None:
        self.hold_checkout(entry)
        self.hold_controllers(entry)


def _require_every_checkout_fenced(
    repositories: tuple[RelocationRepository, ...], fenced: frozenset[Path]
) -> None:
    """Refuse a repository the fence above does not cover.

    The fence is taken from the lock-free preflight, because it has to be held
    before the authoritative plan's own liveness check. A repository that
    appears only in that later plan is therefore one nothing is holding the
    run lock for, and acting on it is exactly the race this fence exists to
    close.
    """
    for entry in repositories:
        if entry.checkout not in fenced:
            raise InstallError(
                f"Refusing to relocate: {entry.identity}'s checkout "
                f"{entry.checkout} appeared after this run took its locks, so no "
                "run lock is held for it. Re-run the installer."
            )


def _require_no_tree_collision(
    kind: str, source: Path, destination: Path, identity: str
) -> None:
    """Refuse a destination tree a distinct source would be moved onto.

    A destination that already holds this repository's own tree — because
    `--install-dir` already put it there, or because the log root never moved
    — is not a collision: it is the tree, already where it is going, and it is
    preserved in place. Two distinct trees is the case nothing here can
    resolve, because merging them or choosing one is a judgement about
    durable state that belongs to the operator.
    """
    if not (source.exists() and destination.exists()):
        return
    if _same_tree(source, destination):
        return
    raise InstallError(
        f"Refusing to relocate: {identity}'s {kind} tree {source} cannot move onto "
        f"{destination}, which already exists. Merge or remove one of them, then "
        "re-run the installer."
    )


def _require_one_runtime_source(entry: RelocationRepository) -> None:
    """Refuse a repository whose runtime tree is in two places already.

    `--install-dir` puts a repository's runtime state somewhere its record does
    not name, and a run that could not carry a tree keeps one at the legacy
    location; both at once is one repository with two runtime trees and one
    destination, which is the same judgement about durable state
    `_require_no_tree_collision` refuses rather than makes.
    """
    source = entry.source_runtime_dir
    legacy = entry.legacy_runtime_dir
    if _same_tree(source, legacy) or not (source.exists() and legacy.exists()):
        return
    raise InstallError(
        f"Refusing to relocate: {entry.identity}'s runtime tree is in two places, "
        f"{legacy} and {source}. Merge or remove one of them, then re-run the "
        "installer."
    )


def plan_relocation(install_dir: Path) -> RelocationPlan:
    """Everything this relocation would do, and every reason it will not.

    Reads only. Every refusal in the contract is raised from here, so a
    relocation that cannot complete fails the run before anything has been
    written — and fails it rather than installing at the destination, because
    an installation split between two locations is worse than one that stayed
    where it was.
    """
    backend = service_backend()
    legacy_dir = legacy_install_dir()
    record = record_name()
    legacy_record = legacy_dir / record
    destination_record = install_dir / record
    log_root = kanban_config.default_drainer_log_dir()
    legacy_logs = legacy_log_root()

    legacy_document = _read_record(legacy_record, "legacy")
    destination_document = _read_record(destination_record, "destination")
    merged = _merge_records(legacy_document, destination_document)

    # From the merged table rather than the legacy one: a repository recorded
    # only at the destination is one this run also has to prove recoverable
    # and usable, since removal below is gated on every recorded repository
    # working through the destination.
    entries = merged.get(drain_prs_service.RECORD_REPOSITORIES_KEY) or {}
    remote_name = drain_prs_service.discovery_remote_name()
    repositories = tuple(
        _recover_repository(
            identity,
            entry,
            backend=backend,
            remote_name=remote_name,
            install_dir=install_dir,
            log_root=log_root,
            legacy_dir=legacy_dir,
            legacy_logs=legacy_logs,
        )
        for identity, entry in sorted(entries.items(), key=lambda item: str(item[0]))
    )
    # The document that will be written is the merge with every recovered
    # entry restated from this host's own derivation, so the destination
    # record describes the jobs that actually exist rather than whichever
    # metadata happened to win the merge.
    if repositories:
        merged = {
            **merged,
            drain_prs_service.RECORD_REPOSITORIES_KEY: {
                **entries,
                **{entry.identity: entry.record_entry for entry in repositories},
            },
        }
    _require_nothing_live(repositories, backend)
    for entry in repositories:
        _require_one_runtime_source(entry)
        for kind, source, destination in entry.trees():
            # Shape before collision: a path that is not a directory is not a
            # tree this may move, wherever it sits.
            _require_tree_shape(kind, source, entry.identity)
            _require_tree_shape(kind, destination, entry.identity)
            _require_no_tree_collision(kind, source, destination, entry.identity)

    # Every entry in the legacy install directory has to be one this installer
    # put there before any of it is taken away.
    removable = []
    for child in sorted(legacy_dir.iterdir()):
        slot = _managed_slot(child, record)
        if slot is None:
            raise InstallError(
                f"Refusing to relocate: {child} is not something this installer "
                f"created, so {legacy_dir} cannot be taken apart. Move it aside, then "
                "re-run the installer."
            )
        # The lock, the marker and an earlier run's runtime guard stay, for
        # the reasons `_RETAINED_SLOTS` gives.
        if slot not in _RETAINED_SLOTS:
            removable.append(child)
    return RelocationPlan(
        install_dir=install_dir,
        log_root=log_root,
        legacy_dir=legacy_dir,
        legacy_record=legacy_record,
        destination_record=destination_record,
        legacy_log_root=legacy_logs,
        merged_record=merged,
        repositories=repositories,
        removable=tuple(removable),
    )


@dataclass
class _Move:
    """One tree move, and which half of it has happened.

    The outcome is what the registered undo reads: a move that never started
    has nothing to reverse, and one that copied and then could not remove its
    source has two trees no undo may choose between.
    """

    source: Path
    destination: Path
    outcome: str = "unstarted"


class _Transition:
    """The mutating half, with an undo registered before every mutation.

    Each action is registered first and run second, so a failure between the
    two costs at most an undo that finds nothing to reverse — which is always
    safe — rather than a mutation nothing knows about. A failure runs every
    registered undo in reverse and reports whichever ones could not be
    completed, because a partial rollback the caller cannot see is the one
    state a host cannot repair.
    """

    def __init__(self) -> None:
        self._undos: list[tuple[str, Any]] = []
        self.residue: list[str] = []

    def register(self, description: str, undo: Any) -> None:
        self._undos.append((description, undo))

    def note_residue(self, description: str) -> None:
        self.residue.append(description)

    def roll_back(self) -> list[str]:
        """Undo everything, in reverse, and answer what could not be undone.

        Total over exception types and never abandons the remaining actions: a
        rollback that stopped at its first failure would leave the actions
        below it — the earliest and therefore the most load-bearing — applied.
        """
        failures = list(self.residue)
        for description, undo in reversed(self._undos):
            try:
                undo()
            except BaseException as exc:  # noqa: BLE001 - reported, never raised
                failures.append(f"{description}: {exc}")
        return failures


def _captured_modes(*paths: Path) -> dict[Path, int]:
    """The mode each of these managed paths already has.

    Taken before any lock is acquired, because acquiring one is itself a
    change to the directory holding the record: `document_lock` creates that
    parent at 0700 and chmods an existing one to 0700, and it does so before
    this transition has recorded anything it could undo. A directory this run
    only ever locked has to come back as restrictive as it was found, and no
    more — and so does the retained lock at a location an earlier run closed,
    which this run has to be able to open and must not leave open.
    """
    return {
        path: path.stat().st_mode & 0o777
        for path in paths
        if not path.is_symlink() and (path.is_dir() or path.is_file())
    }


def _restore_modes(modes: dict[Path, int]) -> list[str]:
    """Put those modes back, and answer whichever could not be. Idempotent, so
    a rollback that has already run this costs nothing to repeat."""
    failures = []
    for path, mode in modes.items():
        try:
            if os.path.lexists(path) and (path.stat().st_mode & 0o777) != mode:
                path.chmod(mode)
        except OSError as exc:
            failures.append(f"restore the mode of {path}: {exc}")
    return failures


def _directory_restorer(path: Path, mode: int) -> Any:
    """An undo that puts one removed directory back at the mode it had.

    Idempotent, because a removal that raced another writer may have failed
    after this was registered: recreating a directory that is still there must
    leave it as it stands rather than fail the rollback that follows.
    """

    def restore() -> None:
        path.mkdir(mode=mode, parents=True, exist_ok=True)
        path.chmod(mode)

    return restore


def _remove_created_directories(created: list[Path]) -> None:
    for directory in created:
        try:
            directory.rmdir()
        except OSError:
            # Not empty, or already gone: this is as far up as this run
            # created, so stop rather than reaching into anything else.
            return


def _ensure_directory(transition: _Transition, path: Path) -> None:
    """Create `path` at the private mode every managed directory carries,
    registering the undo of exactly what this call changes: the directories it
    creates, removed while empty, and the mode of one it merely found."""
    created = [
        candidate for candidate in (path, *path.parents) if not candidate.exists()
    ]
    if created:
        transition.register(
            f"remove the directories created for {path}",
            lambda: _remove_created_directories(created),
        )
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.chmod(0o700)
        return
    previous = path.stat().st_mode & 0o777
    if previous != 0o700:
        transition.register(
            f"restore the mode of {path}", lambda: path.chmod(previous)
        )
        path.chmod(0o700)


def _write_destination_record(
    transition: _Transition, path: Path, document: dict[str, Any]
) -> None:
    """Put a merged document at the destination, durably, before anything
    legacy is removed — so a run that dies here leaves the whole installation
    still discoverable at the location it came from.

    Takes the document rather than reading it off the plan, because the
    late-writer sweep below merges a *second* record into the destination
    after the removal and has to land it on exactly these terms: one
    registered undo, one atomic replacement, one private mode.
    """
    existed = _plain_file(path)
    previous = path.read_bytes() if existed else None
    previous_mode = path.stat().st_mode & 0o777 if existed else None

    def undo() -> None:
        if previous is None:
            if os.path.lexists(path):
                path.unlink()
            return
        path.write_bytes(previous)
        # The mode too, not only the bytes: this transition replaces the
        # record with a private one, and a rollback that left a previously
        # accepted document more restrictive than it was found is a change
        # the run did not undo.
        if previous_mode is not None:
            path.chmod(previous_mode)

    transition.register(f"restore the discovery record at {path}", undo)
    # Under the destination record's own lock, which `relocate` below holds
    # across this write and the whole rollback that may undo it. From the
    # instant this file exists, discovery probes the XDG location first and
    # every other writer on the host resolves *this* record rather than the
    # legacy one — so without that lock a controller starting beside this run
    # could record itself here and have its entry unlinked by an undo.
    drain_prs_service.atomic_write_json(path, document)
    path.chmod(0o600)


def _register_path_restoration(transition: _Transition) -> None:
    """Put this process's own idea of where the installation is back.

    Registered before anything else, so it runs *after* every other undo: what
    the managed paths resolve to depends on which discovery records exist, and
    rebinding them before the destination record had been removed again would
    leave this process describing an installation the rollback has since taken
    away.
    """
    variable = kanban_config.DRAINER_INSTALL_DIR_ENV
    previous = os.environ.get(variable)

    def undo() -> None:
        if previous is None:
            os.environ.pop(variable, None)
        else:
            os.environ[variable] = previous
        drain_prs_service.bind_managed_paths()

    transition.register("rebind this process's managed paths", undo)


def _rebind_managed_paths(install_dir: Path) -> None:
    """Make this process describe the destination installation.

    The selection `--install-dir` made, pinned into the environment the
    resolvers read, so an inherited `KANBAN_DRAINER_INSTALL_DIR` cannot decide
    where the rest of this transition writes; then the controller's own single
    rule recomputed from it. Everything below — the definitions it renders,
    the runtime root it moves trees into, the record it verifies through —
    reads these, so rebinding is what stops the run that moved an installation
    from continuing to write to where it used to be.
    """
    os.environ[kanban_config.DRAINER_INSTALL_DIR_ENV] = str(install_dir)
    drain_prs_service.bind_managed_paths()


def _install_links(
    transition: _Transition, install_dir: Path, sources: dict[str, Path]
) -> None:
    """The four script links, at the destination, before any definition is
    rewritten to name the controller among them."""
    for name, source in sorted(sources.items()):
        destination = install_dir / source.name
        existing = os.readlink(destination) if destination.is_symlink() else None
        present = os.path.lexists(destination)

        def undo(destination=destination, existing=existing, present=present) -> None:
            if os.path.lexists(destination):
                destination.unlink()
            if present and existing is not None:
                destination.symlink_to(existing)

        transition.register(f"restore the link {destination}", undo)
        install_symlink(source, destination)


def _rename_tree(source: Path, destination: Path) -> bool:
    """Rename one tree within a filesystem, or report that the two are on
    different ones.

    The single place a cross-filesystem move is recognized, so both the move
    and its undo below take the copy path on exactly the same condition rather
    than each spelling it.
    """
    try:
        os.replace(source, destination)
    except OSError as exc:
        if exc.errno != errno.EXDEV:
            raise
        return False
    return True


def _move_is_real(move: _Move) -> bool:
    """Whether moving this tree would move anything.

    A source that does not exist has nothing to move, and a source that is
    already its own destination — because `--install-dir` put it there, or
    because the log root never changed — is the tree, where it is going. One
    predicate rather than two, because the takeover below has to create the
    root a tree lands in through its own transition and must decide that on
    exactly the terms the move itself decides to move at all.
    """
    return move.source.exists() and not _same_tree(move.source, move.destination)


def _move_tree(transition: _Transition, move: _Move) -> None:
    """Move one durable tree, safely at every instant it can be interrupted.

    A rename within one filesystem is atomic and is what happens whenever it
    can. Across filesystems it is a copy and then a removal, and each half
    fails on its own terms: a copy that fails takes its incomplete destination
    with it and leaves the source exactly as it was, while a copy that lands
    makes the destination authoritative. If the source then survives, both
    trees are kept and reported rather than one being chosen — deleting either
    would be this installer deciding which copy of a repository's incidents
    and status is the real one.
    """
    if not _move_is_real(move):
        return
    transition.register(
        f"move {move.destination} back to {move.source}",
        lambda: _undo_move(move),
    )
    move.destination.parent.mkdir(parents=True, exist_ok=True)
    if _rename_tree(move.source, move.destination):
        move.outcome = "renamed"
        return
    try:
        shutil.copytree(move.source, move.destination, symlinks=True)
    except BaseException:
        # The incomplete destination goes with the failure, leaving the source
        # untouched and authoritative. A cleanup that cannot itself complete —
        # a directory the copy created with a mode that forbids it, say — is
        # reported rather than swallowed: an ignored error here is exactly a
        # partial destination nothing ever mentions.
        try:
            if os.path.lexists(move.destination):
                shutil.rmtree(move.destination)
        except OSError as cleanup:
            move.outcome = "residual"
            transition.note_residue(
                f"{move.destination} is an incomplete copy of {move.source} that "
                f"could not be removed ({cleanup}); {move.source} is untouched "
                "and remains the authoritative tree"
            )
        raise
    try:
        shutil.rmtree(move.source)
    except OSError as exc:
        move.outcome = "residual"
        transition.note_residue(
            f"{move.source} was copied to {move.destination} but could not be "
            f"removed ({exc}); both trees are kept and the destination is the "
            "authoritative one"
        )
        raise InstallError(
            f"Could not remove {move.source} after copying it to {move.destination}."
        ) from exc
    move.outcome = "copied"


def _undo_move(move: _Move) -> None:
    if move.outcome in {"unstarted", "residual"}:
        return
    move.source.parent.mkdir(parents=True, exist_ok=True)
    if _rename_tree(move.destination, move.source):
        return
    shutil.copytree(move.destination, move.source, symlinks=True)
    shutil.rmtree(move.destination)


def _rewrite_definition(
    transition: _Transition,
    entry: RelocationRepository,
    backend: service_manager.ServiceManagerBackend,
) -> None:
    """Point one repository's definition at the destination installation.

    Rendered by the controller from the paths this process has just been
    rebound to, so the controller path, the install-directory environment and
    the log paths a service manager will actually run this job with are the
    destination's — and reloaded, because a definition the manager has not
    re-read is still the old one.
    """
    path = entry.definition_path
    previous = path.read_bytes()
    # `write_definition_file` installs every definition at the mode its
    # manager reads it with, so restoring through it would hand back a
    # definition whose bytes are the original ones and whose permissions are
    # not. The mode is part of what this transition changed, so it is part of
    # what the undo puts back.
    previous_mode = path.stat().st_mode & 0o777

    def undo() -> None:
        service_manager.write_definition_file(path, previous)
        path.chmod(previous_mode)
        backend.load_definition(entry.identifier)

    transition.register(f"restore the definition at {path}", undo)
    job = drain_prs_service.job_for_identity(entry.checkout, entry.identity)
    backend.write_definition(drain_prs_service.service_definition(job))
    backend.load_definition(entry.identifier)


def _require_usable_through_destination(
    plan: RelocationPlan,
    entry: RelocationRepository,
    runtime: _Move,
    records: dict[str, Any],
    backend: service_manager.ServiceManagerBackend,
) -> None:
    """Everything removal is gated on, asked of one repository.

    Read back off disk rather than inferred from the writes above: what makes
    removal safe is that this repository really is discoverable, describable
    and runnable through the destination *now*, not that each step reported
    success.
    """
    controller = plan.install_dir / drain_prs_service.CONTROLLER_PATH.name
    if not controller.is_file():
        raise InstallError(f"The relocated controller {controller} is not readable.")
    named = backend.definition_environment(entry.identifier).get(
        kanban_config.DRAINER_INSTALL_DIR_ENV
    )
    if named != str(plan.install_dir):
        raise InstallError(
            f"The {backend.definition_label()} for {entry.identity} names "
            f"{named!r} rather than the destination {plan.install_dir}."
        )
    recorded = records.get(entry.identity)
    if not isinstance(recorded, dict):
        raise InstallError(
            f"The destination discovery record {plan.destination_record} has no entry "
            f"for {entry.identity}."
        )
    # Usable, not merely present: Kanban discovers this job by reading the
    # backend, the identifier, the definition path and the checkout out of
    # this entry, so an entry that names any of them wrongly is one the
    # dashboard can neither find nor control.
    expected = {
        **backend.record_entry(entry.identifier, entry.definition_path),
        "repository": str(entry.checkout),
    }
    wrong = {
        key: recorded.get(key)
        for key, value in expected.items()
        if recorded.get(key) != value
    }
    if wrong:
        raise InstallError(
            f"The destination discovery record {plan.destination_record} does not "
            f"describe {entry.identity}'s job on this host: {wrong!r} rather than "
            f"{expected!r}."
        )
    # Asked of the move rather than of the source, which by now is gone: a
    # repository that had runtime state has to have it at the destination, and
    # one that never had any has nothing to prove.
    if runtime.outcome != "unstarted" and not _plain_directory(
        entry.destination_runtime_dir
    ):
        raise InstallError(
            f"{entry.identity}'s runtime state is not a directory at "
            f"{entry.destination_runtime_dir}."
        )


def _remove_legacy_installation(
    transition: _Transition, plan: RelocationPlan
) -> tuple[list[str], list[str]]:
    """Take the shared installation away, once every repository works without
    it, and answer what went and what stayed.

    The lock file is never among them. Everything else this installer created
    is, including the legacy runtime directory once the trees below it have
    moved — and if anything is still there, it stays and is reported rather
    than being deleted with the installation it happened to sit inside.
    """
    removed: list[str] = []
    retained = [str(plan.legacy_record) + ".lock"]
    # Before anything is taken away, and beside the lock that outlives this
    # directory for the same reason. A controller resolves its managed paths
    # once, when it starts, and cannot re-derive them; one that is waiting on
    # this record's lock right now would resume against an installation that
    # no longer exists and rebuild exactly what this run is about to remove.
    # This is what it reads instead — under the same lock, so it sees the
    # installation intact or this, and never a half-dismantled one.
    marker = plan.legacy_dir / drain_prs_service.RELOCATION_MARKER_NAME
    notice, repair = _relocation_notice(plan)
    existing_marker = _plain_file(marker)
    previous_marker = marker.read_bytes() if existing_marker else None
    # Its mode too, on the same terms as the record and the definitions: an
    # earlier run's marker is a managed entry this one is entitled to rewrite
    # and not entitled to leave more restrictive than it found it.
    previous_marker_mode = marker.stat().st_mode & 0o777 if existing_marker else None

    def restore_marker() -> None:
        if previous_marker is None:
            if os.path.lexists(marker):
                marker.unlink()
            return
        marker.write_bytes(previous_marker)
        if previous_marker_mode is not None:
            marker.chmod(previous_marker_mode)

    transition.register(f"restore {marker}", restore_marker)
    drain_prs_service.atomic_write_json(
        marker,
        {
            # Through the controller's own constants, not literals: the readers
            # are `drain_prs_service.relocation_marker` and the operator a seal
            # sends here, and a writer that spelled a field separately could
            # drift into never meeting either.
            drain_prs_service.RELOCATION_MARKER_DESTINATION: str(plan.install_dir),
            "record": str(plan.destination_record),
            "log_root": str(plan.log_root),
            drain_prs_service.RELOCATION_MARKER_SOURCE: str(plan.legacy_dir),
            # The operator-facing half. Every seal this run leaves is a symlink
            # to this document, so a stale invocation that fails on one of them
            # names a path that leads here — and what a controller predating
            # every gate in this repository prints is at most the path it could
            # not use. Saying what happened, naming both locations, and giving
            # the action that resolves it is therefore this document's job
            # rather than that process's.
            drain_prs_service.RELOCATION_MARKER_NOTICE: notice,
            drain_prs_service.RELOCATION_MARKER_REPAIR: repair,
        },
    )
    marker.chmod(0o600)
    retained.append(str(marker))
    # Every seal an earlier run left is kept by this one, so the scan that ends
    # the reconciliation does not read one of them as something a writer put
    # back.
    for sealed in (plan.legacy_record, plan.legacy_dir / _RUNTIME_DIRECTORY_NAME):
        if _is_relocation_seal(sealed):
            retained.append(str(sealed))
    entries_removed, entries_retained = _remove_managed_entries(
        transition, plan.removable
    )
    removed.extend(entries_removed)
    retained.extend(entries_retained)
    root_removed, root_retained = _remove_log_root(transition, plan.legacy_log_root)
    removed.extend(root_removed)
    retained.extend(root_retained)
    return removed, retained


def _remove_managed_entries(
    transition: _Transition, entries: tuple[Path, ...]
) -> tuple[list[str], list[str]]:
    """Take exactly these managed entries away, and answer what went and what
    stayed.

    Shared by the relocation's own removal and by the sweep that clears a
    location a writer put state back at, because "what this installer is
    entitled to delete, and how it puts each kind back" is one answer and a
    second spelling of it would drift.
    """
    removed: list[str] = []
    retained: list[str] = []
    for path in entries:
        if path.is_symlink():
            target = os.readlink(path)
            transition.register(
                f"restore the link {path}",
                lambda path=path, target=target: path.symlink_to(target),
            )
            path.unlink()
            removed.append(str(path))
            continue
        if _plain_file(path):
            previous = path.read_bytes()
            mode = path.stat().st_mode & 0o777
            def undo(path=path, previous=previous, mode=mode) -> None:
                path.write_bytes(previous)
                path.chmod(mode)
            transition.register(f"restore {path}", undo)
            path.unlink()
            removed.append(str(path))
            continue
        if path.name == _BYTECODE_CACHE_NAME:
            # Captured and put back rather than regenerated: an undo that
            # relied on some later interpreter recreating it would be a
            # mutation this transition performed and cannot reverse, and a
            # rollback is not entitled to leave anything it deleted deleted.
            contents = {
                child.name: (child.read_bytes(), child.stat().st_mode & 0o777)
                for child in path.iterdir()
            }
            mode = path.stat().st_mode & 0o777

            def undo(path=path, contents=contents, mode=mode) -> None:
                path.mkdir(mode=mode, exist_ok=True)
                path.chmod(mode)
                for name, (payload, child_mode) in contents.items():
                    child = path / name
                    child.write_bytes(payload)
                    child.chmod(child_mode)

            transition.register(f"restore {path}", undo)
            shutil.rmtree(path)
            removed.append(str(path))
            continue
        # Emptiness is decided before the undo is registered, because an undo
        # for a removal that never happened must not recreate a directory that
        # is still there — and the mode is captured with it, so what comes
        # back is the directory that was taken away rather than a fresh one at
        # this installer's own default.
        mode = path.stat().st_mode & 0o777
        if any(path.iterdir()):
            retained.append(str(path))
            continue
        transition.register(
            f"recreate {path}", _directory_restorer(path, mode)
        )
        path.rmdir()
        removed.append(str(path))
    return removed, retained


def _remove_log_root(
    transition: _Transition, root: Path
) -> tuple[list[str], list[str]]:
    """The log root the per-repository trees came out of, once nothing is left
    in it. A root still holding something — an unrecorded repository's logs, a
    singleton's own — stays and is reported, because taking it away would be
    deleting durable state this run never accounted for."""
    if not root.is_dir():
        return [], []
    if root.is_symlink():
        # Not a root this may take apart, and not one to fail the transition
        # over either: it is reported exactly as a root still holding
        # something is.
        return [], [str(root)]
    mode = root.stat().st_mode & 0o777
    if any(root.iterdir()):
        return [], [str(root)]
    transition.register(f"recreate {root}", _directory_restorer(root, mode))
    root.rmdir()
    return [str(root)], []


# --- Carrying across what a writer put back afterwards ----------------------
#
# The transition above holds the legacy record's lock from before it reads
# anything through after it has taken the installation apart, which serializes
# every writer that queues on that lock: such a writer resumes into a location
# whose record is gone, reads the marker left beside the lock, and fails
# without recording anything. It cannot reach a writer that arrives *after*
# that removal. That one finds no record, creates what it needs afresh, and
# records itself where the XDG-first probe no longer looks — and no lock closes
# that, because the thing a late writer would contend on is a file the removal
# left in place only for the writers that were already queued on it.
#
# So this is the other half: after the removal, whatever came back is carried
# across on the same terms the relocation itself carries an installation, and
# the location is cleared again on the same ownership terms. Bounded, because
# a writer that keeps winning must not hold an installer open; past the bound,
# and past anything this may not decide, the run reports what is still there
# and the install fails over it.


# Every fault the sweep answers by reporting rather than by raising. It runs
# after the removal, where an exception would roll a completed relocation back
# — and rolling one back is the single action that could lose what the late
# writer recorded. So the sweep is total over the vocabularies its steps fail
# in, and what it could not do travels in the report instead.
_SWEEP_FAULTS = (
    InstallError,
    service_manager.ServiceManagerError,
    drain_prs_service.ServiceError,
    shutil.Error,
    OSError,
)


def _recreated_entries(plan: RelocationPlan, known: frozenset[str]) -> tuple[Path, ...]:
    """Everything at the legacy location that the removal did not leave there.

    `known` is what that removal reported retaining — the lock file, the
    marker beside it, and any tree it accounted for and kept — so this answers
    "what appeared after the installation was taken apart" rather than "what is
    there". Without that distinction the residue a relocation already reported,
    an unrecorded repository's logs above all, would read as a late write on
    every pass and no run could ever come out clear.
    """
    found: list[Path] = []
    for directory in (plan.legacy_dir, plan.legacy_log_root):
        if not _plain_directory(directory):
            continue
        found.extend(_unaccounted_children(directory, known))
    return tuple(found)


def _unaccounted_children(directory: Path, known: frozenset[str]) -> list[Path]:
    """Everything under `directory` this run has not accounted for.

    A path the removal reported retaining is one the run knows about — but a
    *directory* it retained is not, because it was kept precisely for still
    holding something, and what is inside it is exactly the durable state a
    location this installer just emptied must not be left holding in silence.
    So a retained directory is descended into rather than skipped: the runtime
    and log roots are what a controller writing for a repository no record
    names leaves its trees under, and hiding a root hides them with it.
    """
    found: list[Path] = []
    for child in sorted(directory.iterdir()):
        if str(child) not in known:
            found.append(child)
        elif _plain_directory(child):
            found.extend(
                grandchild
                for grandchild in sorted(child.iterdir())
                if str(grandchild) not in known
            )
    return found


# --- Recovering the repository an unrecorded tree belongs to ----------------
#
# A tree under the runtime or log root is filed by its slug, and a slug is not
# an identity. `drain_prs_service.repository_slug` escapes each half of the
# identity into an alphabet that excludes `.`, which is reversible — but only
# when this host's backend accepted the escaped spelling, since one it cannot
# carry falls back to a SHA-256 of the whole identity, which nothing reverses.
# So the directory name answers "which repository is this?" sometimes, and the
# documents the controller wrote inside the tree answer it the rest of the
# time. Neither is trusted without the other agreeing where both are present,
# and where nothing establishes an identity the state is kept and named rather
# than filed under a guess.


# The field a runtime document names its repository in. `status.json` carries
# it and so does every incident, and both are written by the controller from
# `job.identity`, which is the canonical identity itself. The discovery record
# entry's field of the same name is a *checkout path* rather than an identity,
# and mutable besides, so it is never read here.
_STRUCTURED_IDENTITY_KEY = "repository"


@dataclass(frozen=True)
class _SlugAttribution:
    """Which repository a directory slug names, or why nothing here can say."""

    slug: str
    identity: str | None
    reason: str | None


def _decode_identity_segment(segment: str) -> str | None:
    """The identity segment `drain_prs_service._escape_identity_segment`
    encodes as this, or None when nothing it produces spells this.

    The inverse of a prefix code: `-` always consumes exactly one following
    character, `--` spells `-` and `-d` spells `.`, and every other pairing is
    something that encoding never emitted.
    """
    decoded: list[str] = []
    index = 0
    while index < len(segment):
        character = segment[index]
        if character != "-":
            decoded.append(character)
            index += 1
            continue
        if index + 1 >= len(segment):
            return None
        following = segment[index + 1]
        if following == "-":
            decoded.append("-")
        elif following == "d":
            decoded.append(".")
        else:
            return None
        index += 2
    return "".join(decoded) or None


def _identity_from_slug(slug: str) -> tuple[str | None, str | None]:
    """The canonical identity this slug reversibly encodes, and why it does not
    when it does not.

    Decoding is not enough on its own, because a directory name is whatever is
    on disk rather than something this installer wrote: the decoded halves have
    to spell a repository GitHub could name, and re-encoding that repository
    through the resolver the installation itself uses has to reproduce this
    exact slug. That round trip is asked of `repository_slug` rather than
    restated, because the encoding is the backend's: a slug this host's service
    manager could not carry as an identifier is one the installation files
    under a hash instead, so a name that decodes cleanly and would nonetheless
    be spelled differently here is not this host's name for that repository.

    The reason travels with the answer because it is what the operator acts on.
    "This is a hash", "this decodes to something GitHub could not name" and
    "this decodes to a repository this host files elsewhere" are three
    different things to go and look at, and one message covering all three
    would name none of them.
    """
    owner, separator, name = slug.partition(".")
    decoded_owner = _decode_identity_segment(owner) if separator else None
    decoded_name = _decode_identity_segment(name) if separator else None
    if decoded_owner is None or decoded_name is None:
        return None, (
            f"{slug} is not a name this host's own slug encoding produces, so "
            "nothing reverses it"
        )
    decoded = f"{decoded_owner}/{decoded_name}"
    try:
        identity = drain_prs_service.normalize_identity(decoded)
    except drain_prs_service.ServiceError:
        return None, (
            f"{slug} decodes to {decoded}, which is not a GitHub repository"
        )
    derived = drain_prs_service.repository_slug(identity)
    if derived != slug:
        return None, (
            f"{slug} decodes to {identity}, which this host files under {derived}"
        )
    return identity, None


def _structured_identities(tree: Path) -> tuple[set[str], list[str]]:
    """Every canonical identity this runtime tree's own documents name, and
    every reason one of them could not be read as evidence.

    The status file and the incidents, which are the two things the controller
    writes into a runtime tree with the identity in them. A document that does
    not carry the field is silent rather than wrong — the status file a run
    left behind before that field existed, and the empty one a fixture writes,
    are both simply no evidence — while one that cannot be read, is not an
    object, or names something that is not a GitHub repository is evidence that
    is *present and broken*, which is the case nothing here may skip past.
    """
    identities: set[str] = set()
    faults: list[str] = []
    documents = [tree / "status.json"]
    incidents = tree / "incidents"
    if _plain_directory(incidents):
        documents.extend(sorted(incidents.glob("*.json")))
    for document_path in documents:
        if not os.path.lexists(document_path):
            continue
        if not _plain_file(document_path):
            faults.append(f"{document_path} is not a regular file")
            continue
        try:
            document = json.loads(document_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            faults.append(f"{document_path} could not be read: {exc}")
            continue
        if not isinstance(document, dict):
            faults.append(f"{document_path} is not a JSON object")
            continue
        if _STRUCTURED_IDENTITY_KEY not in document:
            continue
        value = document[_STRUCTURED_IDENTITY_KEY]
        if not isinstance(value, str) or not value:
            faults.append(f"{document_path} names no repository")
            continue
        try:
            identities.add(drain_prs_service.normalize_identity(value))
        except drain_prs_service.ServiceError:
            faults.append(
                f"{document_path} names {value!r}, which is not a GitHub repository"
            )
    return identities, faults


def _attribute_slug(slug: str, tree: Path) -> _SlugAttribution:
    """Which repository the state filed under `slug` belongs to.

    `tree` is the runtime tree at the location being reconciled whose documents
    may say so, which is also how a log tree is attributed: it carries no
    documents of its own, so the runtime tree filed under the exact same slug
    beside it is what is read for it.

    Fail-closed at every step. Evidence that is present and broken, evidence
    that disagrees with itself or with the name the state is filed under, and a
    name nothing reverses all answer with a reason rather than a repository,
    because filing durable state under the wrong repository is worse than
    leaving it where the operator can see it.
    """
    decoded, decode_reason = _identity_from_slug(slug)
    identities: set[str] = set()
    faults: list[str] = []
    if _plain_directory(tree):
        identities, faults = _structured_identities(tree)
    if faults:
        return _SlugAttribution(
            slug, None, "its own state is malformed: " + "; ".join(faults)
        )
    candidates = set(identities)
    if decoded is not None:
        candidates.add(decoded)
    if not candidates:
        return _SlugAttribution(
            slug,
            None,
            f"{decode_reason}, and no status document or incident filed under "
            "it names a repository",
        )
    if len(candidates) > 1:
        return _SlugAttribution(
            slug,
            None,
            "the evidence filed under it names more than one repository: "
            + ", ".join(sorted(candidates)),
        )
    identity = candidates.pop()
    derived = drain_prs_service.repository_slug(identity)
    if derived != slug:
        return _SlugAttribution(
            slug,
            None,
            f"the evidence filed under it names {identity}, which this host "
            f"files under {derived} rather than {slug}",
        )
    return _SlugAttribution(slug, identity, None)


def _carry_tree(
    transition: _Transition,
    identity: str,
    slug: str,
    kind: str,
    source: Path,
    destination: Path,
    outcome: dict[str, Any],
) -> bool:
    """One recreated tree, moved to the destination or kept beside the one
    already there.

    Two distinct trees is the case nothing here can resolve. A late write for a
    repository whose tree already moved leaves that repository with a status
    file, incidents or logs in both places, and merging them or choosing one is
    a judgement about durable state that belongs to the operator — so both are
    kept and both are named. Per tree rather than per repository: a repository
    whose runtime collided and whose logs did not still has its logs carried.
    """
    if not os.path.lexists(source):
        return True
    if not _plain_directory(source):
        outcome["failures"].append(
            f"{identity}'s recreated {kind} path {source} is not a directory."
        )
        return False
    if os.path.lexists(destination) and not _plain_directory(destination):
        outcome["failures"].append(
            f"{identity}'s {kind} path {destination} is not a directory."
        )
        return False
    if destination.exists() and not _same_tree(source, destination):
        outcome["collisions"].append(
            {
                "repository": identity,
                # Beside the identity rather than instead of it: the slug is
                # the directory both copies are filed under, and an operator
                # reconciling two trees needs the name on disk as well as the
                # repository it belongs to.
                "slug": slug,
                "kind": kind,
                "source": str(source),
                "destination": str(destination),
            }
        )
        return False
    move = _Move(source, destination)
    try:
        _move_tree(transition, move)
    except _SWEEP_FAULTS as exc:
        outcome["failures"].append(
            f"{identity}'s {kind} tree {source} could not be carried to "
            f"{destination}: {exc}"
        )
        return False
    if move.outcome != "unstarted":
        outcome["moved"].append(
            {
                "source": str(move.source),
                "destination": str(move.destination),
                "how": move.outcome,
            }
        )
    return True


def _carry_unaccounted_trees(
    transition: _Transition, plan: RelocationPlan, outcome: dict[str, Any]
) -> bool:
    """Carry the per-repository trees no record names.

    Two things leave one. A controller whose record write the seal refused
    still wrote its runtime and log trees first, under no record lock at all,
    so the repository it was installing is named by nothing. And an uninstall
    deliberately leaves a repository's runtime state, logs and incidents
    behind, so a repository removed long ago has trees under these roots and no
    entry anywhere.

    Neither can be recovered *as* a repository — there is no entry to read a
    checkout, an identifier or a definition out of. But which repository the
    state belongs to is a different question from what job describes it, and
    that one has an answer on disk: the slug the tree is filed under when this
    host's own resolver reproduces it, and the identity the controller wrote
    into the status file and the incidents otherwise. So each tree is carried
    under the repository that evidence establishes, to the roots the
    installation now uses; a tree already there is the collision every other
    tree's is, kept and named rather than chosen between. A tree nothing
    establishes an identity for is kept where it was written and named by its
    slug and the reason, because the alternative is filing a repository's
    durable state under another repository's name.

    No fence is taken for them, and none is available: a repository no record
    names is one this installation can neither discover nor control, so nothing
    here is running it. Every repository that *is* recorded is fenced by the
    caller before its own trees are touched.
    """
    runtime_root = plan.legacy_dir / _RUNTIME_DIRECTORY_NAME
    roots = (
        ("runtime", runtime_root, plan.install_dir / _RUNTIME_DIRECTORY_NAME),
        ("log", plan.legacy_log_root, plan.log_root),
    )
    # Attributed before anything moves. A log tree is attributed through the
    # runtime tree filed under the same slug, and that runtime tree is gone the
    # instant it is carried — so deciding afterwards would answer differently
    # for the log tree depending on whether its own sibling had moved yet.
    attributions: dict[str, _SlugAttribution] = {}
    for _, source_root, _destination_root in roots:
        if not _plain_directory(source_root):
            continue
        for source in sorted(source_root.iterdir()):
            if source.name in attributions:
                continue
            attributions[source.name] = _attribute_slug(
                source.name, runtime_root / source.name
            )
    carried = True
    for kind, source_root, destination_root in roots:
        if not _plain_directory(source_root):
            continue
        for source in sorted(source_root.iterdir()):
            # A recorded repository's own tree is carried above, with its
            # fences held; one that collided there is still sitting here and
            # has already been named, so naming it a second time would report
            # one pair of trees as two.
            if any(item["source"] == str(source) for item in outcome["collisions"]):
                continue
            attribution = attributions[source.name]
            if attribution.identity is None:
                outcome["unattributed"].append(
                    {
                        # Null rather than the slug, and the slug beside it: a
                        # directory name is not an identity, and a report that
                        # spelled one as the other would hand automation a
                        # repository that does not exist.
                        "repository": None,
                        "slug": attribution.slug,
                        "kind": kind,
                        "source": str(source),
                        "reason": attribution.reason,
                    }
                )
                carried = False
                continue
            if attribution.identity not in outcome["repositories"]:
                outcome["repositories"].append(attribution.identity)
            if not _carry_tree(
                transition,
                attribution.identity,
                attribution.slug,
                kind,
                source,
                destination_root / source.name,
                outcome,
            ):
                carried = False
    return carried


def _carry_recreated_location(
    transition: _Transition,
    plan: RelocationPlan,
    backend: service_manager.ServiceManagerBackend,
    outcome: dict[str, Any],
    fences: _Fences,
) -> bool:
    """Carry one pass of recreated state across to the destination.

    The record that came back merges into the destination's on exactly the
    terms the relocation's own merge uses — the destination wins per key at
    both levels, so a legacy-only top-level key and a legacy-only repository
    entry survive while nothing the destination already says is overwritten.
    Each repository it names then has its trees carried and its definition
    rewritten and reloaded against this installation, because the controller
    the late writer's definition names is the one this run removed.

    What it cannot carry it reports rather than raises, and answers False so
    the caller leaves the location standing for the operator; the sweep's own
    guard catches anything a step raises for the same reason. This runs after
    the removal, where an exception escaping into the transition would roll a
    completed relocation back — which is the one action that could lose what
    the late writer recorded.
    """
    key = drain_prs_service.RECORD_REPOSITORIES_KEY
    try:
        recreated = _read_record(plan.legacy_record, "recreated legacy")
        destination = _read_record(plan.destination_record, "destination")
    except _SWEEP_FAULTS as exc:
        outcome["failures"].append(str(exc))
        return False
    entries = recreated.get(key) or {}
    # Recovered out of the *merged* table rather than the recreated one, so a
    # repository the destination already describes is recovered from the
    # destination's own entry: the merge decides which values win, and this
    # must not be a second place that decides it differently.
    merged = _merge_records(recreated, destination)
    merged_entries = merged.get(key) or {}
    remote_name = drain_prs_service.discovery_remote_name()
    repositories: list[RelocationRepository] = []
    unrecovered: set[str] = set()
    for identity in sorted(entries, key=str):
        try:
            repositories.append(
                _recover_repository(
                    identity,
                    merged_entries.get(identity),
                    backend=backend,
                    remote_name=remote_name,
                    install_dir=plan.install_dir,
                    log_root=plan.log_root,
                    legacy_dir=plan.legacy_dir,
                    legacy_logs=plan.legacy_log_root,
                )
            )
        except _SWEEP_FAULTS as exc:
            # Reported and left where it is. Merging an entry that cannot be
            # recovered into the destination record would file a job Kanban
            # can neither discover nor control beside the ones that work.
            unrecovered.add(str(identity))
            outcome["failures"].append(str(exc))
    carried = not unrecovered
    for entry in repositories:
        if entry.identity not in outcome["repositories"]:
            outcome["repositories"].append(entry.identity)
        # Before its trees are touched, on the terms the transition fences on:
        # a repository the late writer recorded may be one it also started, and
        # this run would otherwise move the runtime tree out from under a live
        # drainer. Taken once per lock and released with the run, so recovering
        # the same repository on a later pass costs nothing.
        try:
            fences.hold(entry)
        except _SWEEP_FAULTS as exc:
            outcome["failures"].append(str(exc))
            carried = False
            continue
        for kind, source, tree_destination in entry.trees():
            if not _carry_tree(
                transition,
                entry.identity,
                entry.slug,
                kind,
                source,
                tree_destination,
                outcome,
            ):
                carried = False
        try:
            _rewrite_definition(transition, entry, backend)
        except _SWEEP_FAULTS as exc:
            outcome["failures"].append(
                f"{entry.identity}'s {backend.definition_label()} could not be "
                f"rewritten against {plan.install_dir}: {exc}"
            )
            carried = False
    # After every recorded repository, so a tree one of them owns is carried
    # under its own fences and named by its own identity rather than by the
    # directory it happens to sit in.
    if not _carry_unaccounted_trees(transition, plan, outcome):
        carried = False
    if recreated:
        # An entry that could not be recovered is dropped from what is merged
        # forward rather than filed at the destination beside the jobs that
        # work; it stays in the record left standing at the location this pass
        # could not clear, which is where the operator is pointed.
        carried_record = dict(recreated)
        if key in carried_record:
            carried_record[key] = {
                identity: value
                for identity, value in entries.items()
                if str(identity) not in unrecovered
            }
        document = _merge_records(carried_record, destination)
        if repositories:
            document = {
                **document,
                key: {
                    **(document.get(key) or {}),
                    **{entry.identity: entry.record_entry for entry in repositories},
                },
            }
        _write_destination_record(transition, plan.destination_record, document)
    return carried


def _clear_recreated_location(
    transition: _Transition, plan: RelocationPlan, outcome: dict[str, Any]
) -> None:
    """Take the recreated location away again, asking the same ownership
    question the relocation's own removal asks.

    The expected relative name selects a managed slot and the object type that
    slot requires proves the entry was put there by this installer, so a file
    nothing here created is kept and named — and nothing at that location is
    removed at all, because a directory holding something this installer did
    not create is not one it may take apart. The lock, the marker and an
    earlier run's runtime guard stay, for the reasons `_RETAINED_SLOTS` gives.
    """
    record = record_name()
    removable: list[Path] = []
    for child in sorted(plan.legacy_dir.iterdir()):
        slot = _managed_slot(child, record)
        if slot is None:
            outcome["strays"].append(str(child))
            continue
        if slot not in _RETAINED_SLOTS:
            removable.append(child)
    if outcome["strays"]:
        return
    removed, retained = _remove_managed_entries(transition, tuple(removable))
    outcome["removed"].extend(removed)
    outcome["retained"].extend(retained)
    root_removed, root_retained = _remove_log_root(transition, plan.legacy_log_root)
    outcome["removed"].extend(root_removed)
    outcome["retained"].extend(root_retained)


@contextlib.contextmanager
def _record_locks(plan: RelocationPlan) -> Iterator[None]:
    """Both discovery records' locks, for the span of one reconciliation pass.

    The same two the transition holds, taken in the same order and released
    together: this pass reads and clears the legacy location and writes the
    destination record, so a writer at either end has to be excluded while it
    does — and let through the instant it stops.

    Preceded by the handoff pause above, because letting one through is the
    whole point of having released it: a writer queued on the legacy record's
    lock becomes runnable when this run lets go, and asking for it again in the
    same instant is how this run would take it back before that writer ever
    ran. Once the writer holds it, `document_lock` below blocks on it, so the
    pass that follows reads what it wrote rather than racing it.
    """
    time.sleep(_LOCK_HANDOFF_SECONDS)
    with drain_prs_service.document_lock(plan.legacy_record):
        with drain_prs_service.document_lock(plan.destination_record):
            yield


def _sealed_paths(plan: RelocationPlan) -> tuple[Path, ...]:
    """The paths a finished relocation occupies with a symlink to the marker.

    Two, because a controller bound here has two ways to put durable state
    back and they are refused by different code in the same old copy. The
    record path is what `update_json_document` refuses, which is the one
    mutator every discovery-record write goes through. The runtime root is what
    `ensure_dirs` refuses, which is the one helper every runtime, incident and
    log write goes through — and it is reached first, before the definition is
    written and before the record is touched at all, so closing it is what
    bounds the writes the record seal alone leaves open.
    """
    return (plan.legacy_record, plan.legacy_dir / _RUNTIME_DIRECTORY_NAME)


def _closed_paths(plan: RelocationPlan) -> tuple[Path, ...]:
    """Every path a finished relocation closes, however it closes it.

    The two above, and the retained lock. That last one is not an object
    occupying a path and cannot be, because a lock file may never be unlinked
    — a writer queued on its inode would be handed a different lock from the
    one it is waiting on — so it is closed by being made unopenable instead.
    It is the only thing that reaches a transition which never creates a
    directory: `uninstall_job` does not call `ensure_dirs` at all, so nothing
    else stops it before it unloads and unlinks the definition a relocation
    had just rewritten. `document_lock` opens this file `O_RDWR` in every copy
    of the controller and refuses with `Refusing unsafe config lock path` when
    that open fails, and every transition — install, start, uninstall, stop,
    ack, run — enters that helper before it reads or writes anything else.
    """
    return _sealed_paths(plan) + (_legacy_lock_path(plan.legacy_dir),)


def _seal_path(transition: _Transition, path: Path) -> bool:
    """Close one emptied path against every writer that could recreate state
    at it, and answer whether it is closed.

    This is what answers the writer no lock can: one queued on the retained
    lock file wakes after this run has finished looking, and neither a pause
    nor a bound reaches it, because `flock` cannot be asked whether anyone is
    waiting and a process that has returned cannot look again. So the answer is
    not to out-wait that writer but to leave it nothing to write: what goes
    down is neither a regular file nor a directory, and the two writers in
    every copy of the controller both fail on the object they find rather than
    on any refusal that copy has to contain.
    """
    if os.path.lexists(path):
        # Already sealed, or holding something this run did not put there and
        # may not replace. Either way there is nothing here to do.
        return _is_relocation_seal(path)

    def undo() -> None:
        if _is_relocation_seal(path):
            path.unlink()

    transition.register(f"unseal {path}", undo)
    try:
        path.symlink_to(drain_prs_service.RELOCATION_MARKER_NAME)
    except OSError:
        # Total on the same terms as everything else after the removal: a
        # relocation that succeeded is not rolled back over a seal that could
        # not be written, and an unsealed location is reported rather than
        # raised, because it is a location the next run can still seal.
        return False
    return True


def _restrict_retained_lock(transition: _Transition, plan: RelocationPlan) -> bool:
    """Make the retained lock unopenable, and answer whether it is.

    The mode is what closes it; the bytes are what an operator finds when the
    refusal sends them here by name. This file is an artifact this installer
    owns at a location it has emptied, `document_lock` never reads its content,
    and an operator pointed at a path has to find something that says what
    happened rather than an empty file — so the same notice the marker carries
    goes in here, and the file is left readable and not writable.

    Owner-write is what is taken away rather than every bit, because taking
    every bit away would close the notice too. A process running as root is
    not bounded by this at all; nothing in a user-scoped installation resolves
    its managed paths as root, and the seals above still refuse one that does.
    """
    lock = _legacy_lock_path(plan.legacy_dir)
    if not _plain_file(lock):
        return False
    previous_mode = lock.stat().st_mode & 0o777
    previous = lock.read_bytes()

    def undo() -> None:
        lock.chmod(0o600)
        lock.write_bytes(previous)
        lock.chmod(previous_mode)

    transition.register(f"reopen {lock}", undo)
    notice, repair = _relocation_notice(plan)
    marker = plan.legacy_dir / drain_prs_service.RELOCATION_MARKER_NAME
    try:
        lock.write_text(f"{notice}\n\n{repair}\n\nSee {marker}.\n", encoding="utf-8")
        lock.chmod(0o400)
    except OSError:
        # Total on the same terms as every other step after the removal: an
        # unclosed path is reported rather than raised, because it is one the
        # next run can still close.
        return False
    return True


def _reopen_retained_lock(lock: Path) -> None:
    """Undo that restriction for the span of one installer run.

    A location an earlier run closed is one this run may still have to
    reconcile — a sealed location that acquires state again is planned and
    swept exactly as an unsealed one is — and every lock this run takes there
    goes through the same `document_lock` a controller does. So the run that
    owns the restriction is the run entitled to lift it, and `_captured_modes`
    below is what puts it back on every failing exit. On a successful one it is
    left as this run leaves it: closed again if this run sealed the location,
    and open if it could not, exactly as the record path is.
    """
    if _plain_file(lock) and not os.access(lock, os.W_OK):
        lock.chmod(0o600)


def _seal_emptied_location(
    transition: _Transition, plan: RelocationPlan
) -> list[str]:
    """Close every path above, and answer which of them are still open.

    Placed under the same lock as the final scan and only when that scan found
    the location clear, so it can never seal over state this run was supposed
    to carry — and never before the reconciliation, which would stop the very
    writers it exists to carry across from recording anything for it to find.

    That placement is also why nothing else here knows about these paths. They
    go down after this run's last look, so no step of this run meets them, and
    `relocation_disposition` stops a later run before that run has a plan, a
    record to read, or a location to take apart. An unresolved location is left
    unsealed on purpose: the operator has to see it as it stands, and the
    re-run that follows their reconciliation is what seals it.

    Answered as a list rather than a flag because a run that closed one path
    and not the other has to name the one still open: it is the path a
    controller still bound here writes through, and the operator cannot act on
    "not sealed".
    """
    open_paths = [
        str(path)
        for path in _sealed_paths(plan)
        if not _seal_path(transition, path)
    ]
    if not _restrict_retained_lock(transition, plan):
        open_paths.append(str(_legacy_lock_path(plan.legacy_dir)))
    return open_paths


def _late_write_repair(plan: RelocationPlan, outcome: dict[str, Any]) -> str:
    """What the repair for this run's outcome actually is.

    Never "re-run the installer" on its own when trees were kept: a re-run
    resolves none of them, refusing over exactly the trees it still finds in
    both places and keeping the rest a second time, and it may not guess which
    repository unattributed state belongs to at all — so it is advice that
    cannot work. A location that merely came back, with nothing in two places
    and nothing unattributed, is the case a re-run does resolve.
    """
    unsealed = (
        f"{', '.join(outcome['unsealed'])} could not be sealed against a "
        "writer bound to that location; re-run this installer."
    )
    if outcome["passes"] == 0:
        if not outcome["sealed"]:
            return unsealed
        return "Nothing to repair; the installation is at the destination."
    if outcome["resolved"]:
        carried = (
            f"A writer recorded state at {plan.legacy_dir} after it was taken "
            f"apart; it was carried across to {plan.install_dir} and that "
            "location was cleared again. "
        )
        return carried + ("Nothing to repair." if outcome["sealed"] else unsealed)
    if outcome["collisions"] or outcome["unattributed"]:
        kept: list[str] = []
        if outcome["collisions"]:
            pairs = "; ".join(
                f"{item['repository']}'s {item['kind']} tree at {item['source']} "
                f"and {item['destination']}"
                for item in outcome["collisions"]
            )
            kept.append(f"Both copies are kept: {pairs}.")
        if outcome["unattributed"]:
            orphans = "; ".join(
                f"the {item['kind']} tree at {item['source']}, because "
                f"{item['reason']}"
                for item in outcome["unattributed"]
            )
            kept.append(
                "State that belongs to no repository this run could name is kept "
                f"where it was written: {orphans}."
            )
        return " ".join(kept) + (
            " A re-run alone is not the repair: it refuses over exactly the trees "
            "it still finds in both places, keeps the rest a second time, and may "
            "not guess which repository unattributed state belongs to. Merge or "
            "remove one copy of each colliding pair; identify each unattributed "
            "tree's repository and move that tree under the slug this host files "
            f"it by, beneath {plan.install_dir / _RUNTIME_DIRECTORY_NAME} for a "
            f"runtime tree and {plan.log_root} for a log tree; then re-run this "
            "installer."
        )
    if outcome["strays"]:
        return (
            f"{', '.join(outcome['strays'])} is not something this installer "
            f"created, so nothing at {plan.legacy_dir} was removed. Move it aside, "
            "then re-run this installer."
        )
    if outcome["failures"]:
        return (
            f"What came back at {plan.legacy_dir} could not be carried across: "
            f"{'; '.join(outcome['failures'])} Repair that, then re-run this "
            "installer."
        )
    return (
        f"A writer kept recreating {plan.legacy_dir} through "
        f"{outcome['passes']} reconciliation passes. Stop every drainer, then "
        "re-run this installer."
    )


def _reconcile_late_writes(
    transition: _Transition,
    plan: RelocationPlan,
    backend: service_manager.ServiceManagerBackend,
    known: frozenset[str],
    fences: _Fences,
) -> dict[str, Any]:
    """Carry across whatever was written back after the removal, bounded.

    Runs *outside* the transition's record locks and re-takes them for each
    pass, which is the whole sequencing. A writer queued on the legacy record's
    lock is guaranteed to wake after everything done while that lock is held,
    so a sweep inside it could never see what such a writer records; a sweep
    that takes and releases the lock hands it to whoever is waiting and finds
    what they left on the next pass. Bounded, so a writer that keeps taking it
    ends the sweep rather than extending it forever, and one that arrives after
    the last look is past any installer that terminates at all — which is the
    other half's job, not this one's.

    Whether the run came out resolved is read back off disk under the lock
    rather than inferred from the passes, because what makes the host resolved
    is that the location really is empty, not that each step reported success.
    """
    outcome: dict[str, Any] = {
        "location": str(plan.legacy_dir),
        "record": str(plan.legacy_record),
        "log_root": str(plan.legacy_log_root),
        "passes": 0,
        "repositories": [],
        "moved": [],
        "removed": [],
        "retained": [],
        "collisions": [],
        "unattributed": [],
        "strays": [],
        "failures": [],
        "sealed": False,
        "unsealed": [],
    }
    remaining: tuple[Path, ...] | None = None
    for _ in range(_LATE_WRITER_PASSES):
        with _record_locks(plan):
            if not _recreated_entries(plan, known):
                # This is the last look, so the seal goes down here rather
                # than under a lock taken again for nothing: the handoff has
                # already happened, and a second pause would hand the lock
                # over a second time only to find what this look just did.
                remaining = ()
                outcome["unsealed"] = _seal_emptied_location(transition, plan)
                outcome["sealed"] = not outcome["unsealed"]
                break
            outcome["passes"] += 1
            # The outer guard, so no fault raised by a step this sweep drives
            # can escape into the transition's rollback. Partly-applied work
            # stays applied and is read back below, which is the state the
            # report and the failing install are about.
            try:
                if not _carry_recreated_location(
                    transition, plan, backend, outcome, fences
                ):
                    break
                _clear_recreated_location(transition, plan, outcome)
            except _SWEEP_FAULTS as exc:
                outcome["failures"].append(str(exc))
                break
            if outcome["strays"]:
                break
        # Outside the lock deliberately: leaving this block is what lets a
        # writer queued on it through, and the next pass is what sees them.
    if remaining is None:
        # The sweep stopped on something it could not carry, or at the bound,
        # so what is there now is not what the pass that stopped saw.
        with _record_locks(plan):
            remaining = _recreated_entries(plan, known)
            # Under the same lock as the look that found it clear, and only
            # then: a location this run could not finish reconciling is one
            # the operator has to see as it stands, so every path sealing would
            # have closed is left open — and named as open, because "not
            # sealed" is not something an operator can act on.
            outcome["unsealed"] = (
                _seal_emptied_location(transition, plan)
                if not remaining
                else [str(path) for path in _closed_paths(plan)]
            )
            outcome["sealed"] = not outcome["unsealed"]
    outcome["retained"] = sorted(
        set(outcome["retained"]) | {str(path) for path in remaining}
    )
    outcome["resolved"] = not remaining
    outcome["repair"] = _late_write_repair(plan, outcome)
    return outcome


def _locked_transition(
    transition: _Transition,
    install_dir: Path,
    preflight: RelocationPlan,
    sources: dict[str, Path],
    modes: dict[Path, int],
    fences: _Fences,
) -> tuple[RelocationPlan, dict[str, Any]]:
    """Everything the relocation does under the two discovery records' locks.

    Its own function because those locks have to end before the run does: the
    reconciliation that follows them cannot be inside them, and a `with` that
    ended in the middle of `relocate` would read as though it could be. The
    checkout and controller fences are registered on `fences`, which `relocate`
    owns and holds across that reconciliation too — they exclude a drainer or a
    controller from the trees this run moves, and the sweep moves trees on
    exactly the same terms.
    """
    legacy_dir = legacy_install_dir()
    destination_record = install_dir / record_name()
    with drain_prs_service.document_lock(legacy_dir / record_name()):
        with contextlib.ExitStack() as locks:
            # A destination record that *already exists* has writers this
            # lock does not exclude: discovery probes the XDG location
            # first, so they resolve that record rather than the legacy
            # one and never block here. Its own lock therefore has to be
            # held across the read that merges it, even at the cost of
            # creating that lock file in the one state no writer of that
            # record ever leaves behind — a record with no lock beside it.
            if os.path.lexists(destination_record):
                locks.enter_context(
                    drain_prs_service.document_lock(destination_record)
                )
            # Before the authoritative plan, because that plan's own
            # liveness check is a read, and a drainer starting one instant
            # after it would be one this run never saw. Held for the whole
            # transition and the rollback, and taken from the preflight's
            # repositories because the fence has to precede the plan that
            # would otherwise name them.
            for entry in preflight.repositories:
                fences.hold_checkout(entry)
            plan = plan_relocation(install_dir)
            _require_every_checkout_fenced(plan.repositories, fences.checkouts)
            # After the plan and before any mutation, on the same terms
            # the destination record's lock is taken: a refusal must not
            # leave a lock file behind, and nothing can acquire one in the
            # meantime because doing so needs the record lock held here.
            for entry in plan.repositories:
                fences.hold_controllers(entry)
            # A destination record that does *not* exist has no such
            # writer: every writer on this host resolves the legacy record
            # and is blocked above. Its lock is therefore taken here,
            # after the last refusal and before the write that creates the
            # record and makes it resolvable — which is what keeps a
            # refusal from ever creating a lock file. Re-entrant, so the
            # branch above is not repeated.
            locks.enter_context(
                drain_prs_service.document_lock(plan.destination_record)
            )
            try:
                result = _apply_relocation(transition, plan, sources)
            except BaseException as exc:
                residue = transition.roll_back() + _restore_modes(modes)
                detail = "; ".join(residue)
                raise RelocationFailed(
                    f"Relocating the PR drainer installation from "
                    f"{plan.legacy_dir} to {plan.install_dir} failed and was "
                    f"rolled back: {exc} The lock file "
                    f"{plan.destination_record}.lock and the directories "
                    "holding it remain, because a lock is never unlinked."
                    + (
                        f" The rollback could not complete: {detail}."
                        if residue
                        else ""
                    ),
                    residue,
                ) from exc
    return plan, result


def _location_is_emptied_and_sealed() -> bool:
    """Whether the legacy location holds nothing but what sealing it left, and
    every path sealing closes is closed.

    Both halves, because either one alone is a reason to keep looking. A
    location holding trees is one a later run reconciles however sealed it is:
    the seals go down after a run's last look, and a controller bound here that
    started before them wrote its runtime tree, its log tree and its definition
    already. And a location whose seals are not all down is one a later run has
    to go back and finish, because a run that emptied it and could not write
    one of them left a path a controller still bound here writes through — so
    reading the other seal as an answer would make that path permanently
    invisible.
    """
    legacy_dir = legacy_install_dir()
    record = record_name()
    lock = _legacy_lock_path(legacy_dir)
    kept = {lock.name, drain_prs_service.RELOCATION_MARKER_NAME}
    sealed = {record, _RUNTIME_DIRECTORY_NAME}
    if _plain_directory(legacy_dir):
        if any(child.name not in kept | sealed for child in legacy_dir.iterdir()):
            return False
        if not all(_is_relocation_seal(legacy_dir / name) for name in sealed):
            return False
        # The lock too, and by the same rule: a location whose lock an earlier
        # run left openable is one a stale transition still enters, so this run
        # has to go back and close it rather than reading the two seals beside
        # it as an answer. An installation sealed before this bound existed is
        # exactly that location, which is how such a host is finished.
        if _plain_file(lock) and os.access(lock, os.W_OK):
            return False
    root = legacy_log_root()
    return not (_plain_directory(root) and any(root.iterdir()))


def relocation_disposition(install_dir: Path) -> str | None:
    """Why this run migrates nothing, or None when it does.

    The first question is the platform's own: whether this host keeps its
    installation where it installs to. It is asked as the platform question
    and never inferred from two directories differing, because a macOS host
    whose XDG variables happen to point elsewhere is still a host nothing may
    move — and because the reverse reading, taking two equal directories for a
    macOS host, is exactly how a Linux host whose XDG root names
    `~/Library/Application Support` would be skipped. Whether this platform
    migrates and whether migrating *moves* anything are two questions;
    `_takes_over_in_place` below answers the second, and only for a run this
    one has already said migrates.
    """
    if kanban_config.is_macos():
        return "this platform installs where its installation already is"
    if not _same_location(install_dir, kanban_config.default_drainer_install_dir()):
        return "a custom --install-dir destination installs there and relocates nothing"
    legacy_record = legacy_install_dir() / record_name()
    if not os.path.lexists(legacy_record):
        return "there is no installation at the legacy location"
    if _location_is_emptied_and_sealed():
        return "the legacy location was emptied and sealed by an earlier run"
    return None


# --- Taking over an installation already at this platform's own location ---
#
# An absolute `$XDG_DATA_HOME` naming `~/Library/Application Support` makes
# this platform's own default the `~/Library` directory itself, so a default
# run's destination is the location the installation is already at. Nothing
# has to move — and the definitions installed there still name the log root a
# pre-XDG resolution answered with and carry none of the XDG context this
# host's own resolution puts in them, and nothing else would ever rewrite
# them.
#
# Whether this platform takes an installation over, and whether taking it over
# *moves* anything, are two questions. Only the first is the platform's, which
# is why the disposition above stops asking the second: two directories being
# equal reads a Linux host as macOS and skips it.
#
# What is left when nothing moves is one document rather than two, so there is
# nothing to merge and no pair of records to hold a lock between; one location
# rather than two, so nothing is taken apart; and, as the only thing that can
# be out of date, each repository's definition — compared as the bytes the
# backend renders and rewritten only where they differ. A log tree still moves
# when the log root itself changed, since that root is the one managed
# location `KANBAN_DRAINER_INSTALL_DIR` does not pin.
#
# That scoping is load-bearing rather than an optimization. Every guard in the
# plan above is refusal-shaped, so a takeover that treated every recorded
# repository as affected would refuse an ordinary install of one repository
# because an unrelated sibling's drainer happened to be running.


# What a run reports when every definition at this location is already the one
# this host would write: not a migration, and therefore the same
# nothing-migrated answer every other such run gives.
_SETTLED_TAKEOVER_REASON = (
    "every definition at this location is already what this host would write"
)


def _settled_takeover(plan: TakeoverPlan) -> dict[str, Any]:
    """The nothing-migrated answer, carrying what the plan accounted for.

    Shaped as every other run that migrates nothing is — `relocated` false and
    one `reason` — because an installation with nothing stale is not a
    migration and must not report as one.

    What travels beside that reason is the bookkeeping this path would
    otherwise lose: which repositories were already current, and which
    recorded entries could not be recovered and were therefore left exactly as
    they stand. The second is why the reason itself narrows when there is one.
    An entry this run could not read is an entry whose definition it cannot
    call current, and answering "every definition here is already what this
    host would write" over it would be claiming to have compared something it
    never could.
    """
    if plan.unrecoverable:
        entries = "entry" if len(plan.unrecoverable) == 1 else "entries"
        reason = (
            "every definition this run could recover is already what this host "
            f"would write; {len(plan.unrecoverable)} recorded {entries} could "
            "not be recovered and were left exactly as they stand"
        )
    else:
        reason = _SETTLED_TAKEOVER_REASON
    return {
        "relocated": False,
        "reason": reason,
        "settled": list(plan.settled),
        "unrecoverable": list(plan.unrecoverable),
    }


def _takes_over_in_place(install_dir: Path) -> bool:
    """Whether this run's destination is the location the `~/Library`
    installation is already at.

    Asked only after `relocation_disposition` above has settled the platform
    question and the destination, so this never decides *that* a host migrates
    — it decides which shape that migration has.
    """
    return _same_location(install_dir, legacy_install_dir())


@contextlib.contextmanager
def _bound_to(install_dir: Path) -> Iterator[None]:
    """This process describing the installation at `install_dir` for one
    block, and describing whatever it described before once that block ends.

    A takeover moves nothing, so where this process thinks the installation is
    is the same before and after. What has to be this run's own is narrower:
    the definitions it renders, compares and rewrites must be the ones *this
    run's selection* would write. `--install-dir` is that selection, and an
    inherited `KANBAN_DRAINER_INSTALL_DIR` naming somewhere else must decide
    neither the bytes staleness is decided against nor which definitions come
    out stale.

    Scoped rather than pinned, which is the whole difference from
    `_rebind_managed_paths` above: that one is how a relocation stops writing
    to where the installation used to be, and a takeover has no used-to-be.
    """
    variable = kanban_config.DRAINER_INSTALL_DIR_ENV
    previous = os.environ.get(variable)
    os.environ[variable] = str(install_dir)
    drain_prs_service.bind_managed_paths()
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop(variable, None)
        else:
            os.environ[variable] = previous
        drain_prs_service.bind_managed_paths()


@dataclass(frozen=True)
class TakeoverPlan:
    """Everything a takeover would do, decided before it does any of it, and
    every recorded repository it accounted for on the way."""

    install_dir: Path
    log_root: Path
    record: Path
    legacy_log_root: Path
    repositories: tuple[RelocationRepository, ...]
    settled: tuple[str, ...]
    unrecoverable: tuple[str, ...]

    def report(self) -> dict[str, Any]:
        return {
            "takeover": True,
            "location": str(self.install_dir),
            "record": str(self.record),
            "log_root": str(self.log_root),
            "legacy_log_root": str(self.legacy_log_root),
            "repositories": [entry.report() for entry in self.repositories],
            "settled": list(self.settled),
            "unrecoverable": list(self.unrecoverable),
        }


def _definition_is_current(
    entry: RelocationRepository, backend: service_manager.ServiceManagerBackend
) -> bool:
    """Whether this repository's installed definition is already the bytes
    this host would write for it.

    Compared as the rendered bytes rather than as any field inside them,
    because the definition is an artifact a service manager reads whole: two
    that differ anywhere differ to the manager, and `render_definition` is the
    boundary the rest of this repository already treats as that contract. A
    definition that cannot be read is not one this run may call settled, so it
    is stale and gets rewritten.
    """
    job = drain_prs_service.job_for_identity(entry.checkout, entry.identity)
    desired = backend.render_definition(drain_prs_service.service_definition(job))
    try:
        return entry.definition_path.read_bytes() == desired
    except OSError:
        return False


def plan_takeover(install_dir: Path) -> TakeoverPlan:
    """Which definitions at this location are not what this host would write,
    and every reason the run that rewrites them will not.

    Reads only, and reads *one* record: the location it would merge from is
    the location it would merge into, so there is no second document and no
    lock to hold between two of them.

    A recorded repository that cannot be recovered exactly is neither refused
    nor rewritten. `plan_relocation` above refuses over one because it goes on
    to take the shared installation away and would strand it; this run takes
    nothing apart, so such a repository is left precisely as it stands — and
    an entry that cannot be recovered cannot be shown to be affected either,
    which is the same reason the guards below see only the stale set. It is
    reported rather than passed over silently.

    Bound to `install_dir` for its whole span, because which definitions are
    stale is decided against this run's own selection and not against an
    inherited `KANBAN_DRAINER_INSTALL_DIR`. Re-entering that binding inside a
    caller that already holds it changes nothing, which is what lets the
    transition ask for the authoritative plan without spelling the selection a
    second time.
    """
    with _bound_to(install_dir):
        return _plan_takeover(install_dir)


def _plan_takeover(install_dir: Path) -> TakeoverPlan:
    backend = service_backend()
    record = install_dir / record_name()
    log_root = kanban_config.default_drainer_log_dir()
    legacy_logs = legacy_log_root()
    document = _read_record(record, "installed")
    entries = document.get(drain_prs_service.RECORD_REPOSITORIES_KEY) or {}
    remote_name = drain_prs_service.discovery_remote_name()
    stale: list[RelocationRepository] = []
    settled: list[str] = []
    unrecoverable: list[str] = []
    for identity, entry in sorted(entries.items(), key=lambda item: str(item[0])):
        try:
            recovered = _recover_repository(
                identity,
                entry,
                backend=backend,
                remote_name=remote_name,
                install_dir=install_dir,
                log_root=log_root,
                legacy_dir=install_dir,
                legacy_logs=legacy_logs,
            )
        except InstallError as exc:
            unrecoverable.append(str(exc))
            continue
        if _definition_is_current(recovered, backend):
            settled.append(recovered.identity)
            continue
        stale.append(recovered)
    repositories = tuple(stale)
    # Only over the stale set, which is what keeps this an ordinary install: a
    # settled sibling is one this run does not touch, and refusing because its
    # drainer is running would make every install on this host conditional on
    # every other repository being idle.
    _require_nothing_live(repositories, backend)
    for entry in repositories:
        _require_one_runtime_source(entry)
        for kind, source, destination in entry.trees():
            # Shape before collision, exactly as the relocation asks it: a
            # path that is not a directory is not a tree this may move,
            # wherever it sits. A log root that is its own destination answers
            # `_same_tree` and is preserved in place rather than refused as an
            # occupied destination.
            _require_tree_shape(kind, source, entry.identity)
            _require_tree_shape(kind, destination, entry.identity)
            _require_no_tree_collision(kind, source, destination, entry.identity)
    return TakeoverPlan(
        install_dir=install_dir,
        log_root=log_root,
        record=record,
        legacy_log_root=legacy_logs,
        repositories=repositories,
        settled=tuple(settled),
        unrecoverable=tuple(unrecoverable),
    )


def _apply_takeover(
    transition: _Transition, plan: TakeoverPlan
) -> dict[str, Any]:
    """Rewrite and reload exactly the stale definitions, carrying whichever
    trees this host's own roots no longer name.

    Nothing is removed and no record is written. The script links are already
    at this location and the install that follows re-links them; the one
    document here is the one that install's own record write locks for
    itself.
    """
    backend = service_backend()
    moves: list[_Move] = []
    for entry in plan.repositories:
        for _kind, source, destination in entry.trees():
            move = _Move(source, destination)
            moves.append(move)
            if _move_is_real(move):
                # The root this tree lands in, created through the transition
                # rather than by the move, so a rollback takes back a root
                # this run brought into existence. A run that moves nothing
                # creates nothing, which is what keeps the settled case from
                # leaving a directory behind.
                _ensure_directory(transition, destination.parent)
            _move_tree(transition, move)
        _rewrite_definition(transition, entry, backend)
    return {
        "relocated": False,
        **plan.report(),
        "moved": [
            {
                "source": str(move.source),
                "destination": str(move.destination),
                "how": move.outcome,
            }
            for move in moves
            if move.outcome != "unstarted"
        ],
        "rewritten": [str(entry.definition_path) for entry in plan.repositories],
    }


def take_over(install_dir: Path) -> dict[str, Any]:
    """Bring an installation already at this platform's own location up to
    what this host would write, or report that it already is.

    The settled case is the ordinary one and is what a second run of this
    installer sees: nothing is stale, so no document is read a second time, no
    tree moves, no lock is taken, and the answer is the same
    nothing-migrated answer a host with no `~/Library` installation gets —
    carrying, as `_settled_takeover` explains, everything the plan accounted
    for on the way there.

    When something is stale, the one record's own lock is held across the
    rewrite. That is not the pair of locks a relocation holds between two
    records — there is only one record here, and this run never writes it —
    but the lock a controller installing or uninstalling one of these very
    definitions holds while it does, and the lock that makes the controller
    fence below sound: a controller takes its own lock inside a record-locked
    startup transaction, so one either held it before this started or cannot
    take it at all.
    """
    with _bound_to(install_dir):
        preflight = plan_takeover(install_dir)
        if not preflight.repositories:
            return _settled_takeover(preflight)
        # Captured before the lock, because taking one chmods the directory
        # holding the record: a refusal raised once it is held must still
        # leave this host as it was found.
        modes = _captured_modes(install_dir)
        transition = _Transition()
        try:
            with drain_prs_service.document_lock(preflight.record):
                with contextlib.ExitStack() as stack:
                    fences = _Fences(stack)
                    # Before the authoritative plan, whose own liveness check
                    # is a read: a drainer starting one instant after it would
                    # be one this run never saw.
                    for entry in preflight.repositories:
                        fences.hold_checkout(entry)
                    plan = plan_takeover(install_dir)
                    _require_every_checkout_fenced(
                        plan.repositories, fences.checkouts
                    )
                    for entry in plan.repositories:
                        fences.hold_controllers(entry)
                    if not plan.repositories:
                        return _settled_takeover(plan)
                    try:
                        return _apply_takeover(transition, plan)
                    except BaseException as exc:
                        residue = transition.roll_back() + _restore_modes(modes)
                        detail = "; ".join(residue)
                        raise RelocationFailed(
                            "Taking over the PR drainer installation at "
                            f"{plan.install_dir} failed and was rolled back: "
                            f"{exc}"
                            + (
                                f" The rollback could not complete: {detail}."
                                if residue
                                else ""
                            ),
                            residue,
                        ) from exc
        except BaseException:
            # A refusal raised once the lock was held leaves the directory
            # holding the record at the mode it was found with. Idempotent, so
            # the rollback above having already done it costs nothing.
            _restore_modes(modes)
            raise


def relocation_preview(install_dir: Path) -> dict[str, Any]:
    """What a run would do about a pre-XDG `~/Library` installation, having
    done none of it.

    One answer for the dry run, resolved through the same disposition and the
    same plans the real run uses, so the two can never describe this host
    differently.
    """
    disposition = relocation_disposition(install_dir)
    if disposition is not None:
        return {"relocated": False, "reason": disposition}
    if _takes_over_in_place(install_dir):
        plan = plan_takeover(install_dir)
        if not plan.repositories:
            return _settled_takeover(plan)
        return {"relocated": False, "dry_run": True, **plan.report()}
    return {
        "relocated": False,
        "dry_run": True,
        **plan_relocation(install_dir).report(),
    }


def relocate(install_dir: Path, sources: dict[str, Path]) -> dict[str, Any]:
    """Move a pre-XDG `~/Library` installation to this platform's own
    convention, whole, or leave the host as it was found.

    The one entry point for both shapes a migration has. A destination that is
    the location the installation is already at has nothing to move, and
    `take_over` above is what such a run does instead; everything below is the
    relocating case.

    Exactly as it was found, in the case that matters: every refusal is raised
    before a lock is taken, so a run that refuses changes nothing at all. A run
    that got as far as taking a lock — the authoritative plan racing a
    concurrent writer, or a failure inside the transition — puts back
    everything it changed except the lock files themselves and the directories
    that have to exist to contain them, because a lock may never be unlinked
    while a writer might be queued on its inode. That residue is named in the
    failure it is reported with.

    The entire transition — from the read that decides which repositories
    exist through the removal that takes away the controller they name, and on
    through a rollback that may undo it — is held under both discovery
    records' locks, because every one of those repositories has installs and
    starts that write to whichever record discovery resolves, and this run
    changes which one that is. They are taken only here, where something is
    actually removed.
    """
    disposition = relocation_disposition(install_dir)
    if disposition is not None:
        return {"relocated": False, "reason": disposition}
    if _takes_over_in_place(install_dir):
        # The destination is the location the installation is already at, so
        # there is no source to move from: what this host takes over is the
        # definitions there, and only the ones it would write differently.
        return take_over(install_dir)
    backend = service_backend()
    # Planned once without either lock, so an ordinary refusal never takes one
    # — the locks are for the transition that removes something, and a run
    # that refuses removes nothing, while taking a lock creates a lock file no
    # rollback may unlink.
    preflight = plan_relocation(install_dir)
    transition = _Transition()
    legacy_dir = legacy_install_dir()
    legacy_lock = _legacy_lock_path(legacy_dir)
    # Captured with the two directories and reopened before anything asks for
    # it, and only once the preflight above has had its chance to refuse, so a
    # run that refuses still changes nothing at all.
    modes = _captured_modes(legacy_dir, install_dir, legacy_lock)
    _reopen_retained_lock(legacy_lock)
    try:
        # The fences outlive the record locks, because the sweep below moves
        # trees and rewrites definitions exactly as the transition does; only
        # the two record locks end early, and only because ending them is the
        # whole point.
        with contextlib.ExitStack() as stack:
            fences = _Fences(stack)
            plan, result = _locked_transition(
                transition, install_dir, preflight, sources, modes, fences
            )
            # Both record locks are released by now, and that sequencing is
            # what the reconciliation depends on. A writer queued on the legacy
            # record's lock cannot be reached while this run holds it: it is
            # guaranteed to wake *after* everything done under that lock, so a
            # sweep inside it could never see what such a writer records.
            # Releasing hands the lock to whoever was waiting; the sweep then
            # re-takes it, pass by pass, and finds what they left.
            late = _reconcile_late_writes(
                transition, plan, backend, frozenset(result["retained"]), fences
            )
            result = {
                **result,
                "late_writes": late,
                "legacy_record_reappeared": late["passes"] > 0,
                "repair": late["repair"],
            }
    except BaseException:
        # Whatever got out — a refusal raised once a lock was already held, or
        # the rolled-back failure above — leaves both directories at the modes
        # they were found with. Idempotent, so the rollback having already
        # done it costs nothing.
        _restore_modes(modes)
        raise
    # From here the destination directory's mode is this run's own: it is the
    # installation this run just made, and `_ensure_directory` set it to the
    # private mode every managed directory carries. The legacy directory is
    # one this run only ever locked, so it goes back as it was found.
    _restore_modes({path: mode for path, mode in modes.items() if path == legacy_dir})
    return result


def _apply_relocation(
    transition: _Transition, plan: RelocationPlan, sources: dict[str, Path]
) -> dict[str, Any]:
    backend = service_backend()
    _register_path_restoration(transition)
    _ensure_directory(transition, plan.install_dir)
    _write_destination_record(transition, plan.destination_record, plan.merged_record)
    _rebind_managed_paths(plan.install_dir)
    _install_links(transition, plan.install_dir, sources)
    _ensure_directory(transition, plan.install_dir / _RUNTIME_DIRECTORY_NAME)
    _ensure_directory(transition, plan.log_root)
    moves: list[_Move] = []
    runtimes: dict[str, _Move] = {}
    for entry in plan.repositories:
        for kind, source, destination in entry.trees():
            move = _Move(source, destination)
            if kind == "runtime" and (
                entry.identity not in runtimes
                or runtimes[entry.identity].outcome == "unstarted"
            ):
                # Whichever runtime tree actually moved is the one removal is
                # gated on having arrived; at most one of them exists, which
                # `_require_one_runtime_source` is what settles.
                runtimes[entry.identity] = move
            moves.append(move)
            _move_tree(transition, move)
        _rewrite_definition(transition, entry, backend)
    records = _read_record(plan.destination_record, "destination").get(
        drain_prs_service.RECORD_REPOSITORIES_KEY
    ) or {}
    for entry in plan.repositories:
        _require_usable_through_destination(
            plan, entry, runtimes[entry.identity], records, backend
        )
    removed, retained = _remove_legacy_installation(transition, plan)
    # Reconciling whatever a writer puts back deliberately does not happen
    # here: it has to run once the record locks this is inside have been
    # released, so `relocate` above owns it.
    return {
        "relocated": True,
        "source": str(plan.legacy_dir),
        "destination": str(plan.install_dir),
        "record": str(plan.destination_record),
        "log_root": str(plan.log_root),
        "repositories": [entry.report() for entry in plan.repositories],
        "moved": [
            {
                "source": str(move.source),
                "destination": str(move.destination),
                "how": move.outcome,
            }
            for move in moves
            if move.outcome != "unstarted"
        ],
        "removed": removed,
        "retained": retained,
    }


@contextlib.contextmanager
def current_installation_transaction() -> Iterator[None]:
    """The controller's own installation gate, held over this installer's own
    writes.

    `tools/drain_prs_service.py` binds every managed path once, at import, and
    this installer imports it — so a run whose installation moved underneath it
    between that import and these writes would merge its configuration into a
    record nothing resolves any more and hand the installed controller a
    directory that is gone. The controller refuses exactly that for its own
    transitions; this is the same refusal, asked by the installer, through the
    same predicate rather than a second spelling of it.

    Under the discovery record's lock, and refused before it is taken as well
    as inside it, so a relocation has either not started or finished by the
    time anything here is written. It ends before the installed controller is
    spawned: that is another process, and one that blocked on a lock this one
    held would never reach its own copy of this gate.
    """
    with contextlib.ExitStack() as stack:
        try:
            stack.enter_context(drain_prs_service.installation_transaction())
        except drain_prs_service.ServiceError as exc:
            raise InstallError(f"Refusing to install: {exc}") from exc
        yield


def _require_relocation_resolved(relocation: dict[str, Any]) -> None:
    """Fail an install whose relocation ended with state back at the location
    it emptied.

    Failed rather than reported, and reported rather than repaired: the
    destination is the installation from here on, so this is not something to
    roll back, but an install that returned success would be telling automation
    that a host with a repository's durable state in two places is finished.
    Every affected repository and every retained path travels with the failure,
    in the message and in the structured report both, because `--json` is a
    real interface here and unresolved state must not become ambiguous to it.
    """
    late = relocation.get("late_writes")
    if not isinstance(late, dict):
        return
    if late.get("resolved", True) and late.get("sealed", True):
        return
    if not late["resolved"]:
        repositories = ", ".join(late["repositories"]) or "none recorded"
        retained = ", ".join(late["retained"]) or "nothing"
        # Named by slug and by why attribution failed, never as a null
        # repository: this sentence is what an operator acts on, and `None`
        # spelled into it names nothing they can look for. Once per slug,
        # because a repository's runtime and log trees fail to attribute for
        # the same reason and reporting it twice reads as two problems.
        seen: dict[str, str] = {}
        for item in late["unattributed"]:
            seen.setdefault(item["slug"], item["reason"])
        unattributed = "".join(
            f" State filed under {slug} could not be attributed to a "
            f"repository, because {reason}."
            for slug, reason in seen.items()
        )
        detail = (
            f"but a writer recorded state at {late['location']} after it was "
            f"taken apart and it is still there. Affected repositories: "
            f"{repositories}. Kept where it was written: {retained}."
            f"{unattributed}"
        )
    else:
        # Clear, and open. The location holds nothing, but a path sealing it
        # closes is not closed against a controller still bound there, so the
        # one thing this run could not do is the one thing that keeps it shut.
        detail = (
            f"but a path at {late['location']} was left open to a controller "
            f"still bound to that location: {', '.join(late['unsealed'])}."
        )
    raise RelocationUnresolved(
        "The PR drainer installation was relocated to "
        f"{relocation['destination']}, {detail} {late['repair']}",
        late,
    )


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
        # Planned rather than performed, and outside the legacy record's lock:
        # a dry run removes nothing, so it takes no lock, and it still reports
        # every refusal because the plan is what refuses.
        relocation = relocation_preview(install_dir)
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
            "relocation": relocation,
            "started": False,
        }

    # Before anything is installed at the destination, because a relocation
    # that cannot complete has to fail the run rather than leave an
    # installation split across two locations. It installs the same four links
    # itself when it does run, so that the definitions it rewrites name a
    # controller that is already there; the idempotent pass below then reports
    # them unchanged. A takeover installs none, because the controller its
    # definitions name is the one already at this location — the same pass
    # below re-links it.
    relocation = relocate(install_dir, sources)
    # Before any of this run's own writes, because a relocation that ended with
    # durable state in two places is not an install that may go on to report
    # success — and after the relocation itself, which is the one thing on this
    # host entitled to move an installation and rebinds this process to it.
    _require_relocation_resolved(relocation)
    if relocation["relocated"]:
        # Through the destination's record now, which is where this
        # repository's own `config_path` and identity are read from.
        job = repository_job(repo)

    # Every mutation this process performs is inside the gate: the managed
    # links, the migrated configuration, the notification endpoint and this
    # repository's `config_path` entry in the discovery record. The definition,
    # the runtime and log trees and the record entry the installed controller
    # writes are inside its own copy of it, in the process that writes them.
    with current_installation_transaction():
        link_results = {
            key: install_symlink(sources[key], destination)
            for key, destination in destinations.items()
        }
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
        "relocation": relocation,
        "links": link_results,
        "config": str(shared_config_path()),
        "migrated_config_keys": migrated_keys,
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
        default=str(default_install_dir()),
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
            print(f"Service: {result['label']}")
            print(f"Controller: {install_dir / 'drain_prs_service.py'}")
            print("The job is loaded but stopped; start it from Kanban when ready.")
        return 0
    # `ServiceManagerError` is the service-manager seam's own vocabulary for a
    # fault no injected runner can carry, and reaches here whenever it was raised
    # past the point `service_backend` translates the selection itself.
    except (InstallError, service_manager.ServiceManagerError, OSError) as exc:
        if args.json:
            # The structured half of the same answer. A failure that names
            # repositories and retained paths says them in both modes, because
            # a caller parsing JSON must not have to read prose to find out
            # which trees are in two places.
            payload: dict[str, Any] = {"error": str(exc)}
            if isinstance(exc, RelocationUnresolved):
                payload["late_writes"] = exc.report
            print(json.dumps(payload, indent=2, sort_keys=True), file=sys.stderr)
        else:
            print(f"install_drainer.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
