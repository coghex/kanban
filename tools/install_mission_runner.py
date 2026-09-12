#!/usr/bin/env python3

"""Safely install Kanban's user-scoped mission runner job.

The installer never starts the service. It installs stable Kanban-managed
script links and, through `tools/mission_runner_service.py`, loads a stopped
job for the selected repository -- a LaunchAgent on macOS, a systemd user unit
on Linux, whichever `tools/service_manager.select_backend` says this host is
managed by. An optional --config path is persisted against that repository and
carried into the job it installs.

One job per canonical GitHub repository, in a `mission-runner` namespace of its
own. The script links are shared -- one installed copy of the controller, the
configuration parser, and the service-manager backend serves every repository
-- while the job, its runtime state, its logs, and its `--config` selection are
the repository's own. Installing a second repository therefore adds an entry
beside the first rather than replacing it, and uninstalling one removes that
entry and that job alone: the shared links go only when no installed job is
left to run from them.

--repo names the target: the repository whose missions this service advances,
whose remote names the job. --asset-root names the tree Kanban's own tracked
modules are linked from, and is never a target. They are one tree in a
development install and two when the modules come from the unpacked release
archive, which carries no Git metadata and is therefore never asked for any.

There is no legacy installation to migrate. `tools/mission_runner_service.py`
shipped as a wrapper invoked directly and wrote no discovery record, so this
component has never had an installation anywhere -- which is why `--install-dir`
is the whole of relocation here, and why none of `tools/install_drainer.py`'s
`~/Library`-to-XDG migration machinery appears below.

The job half is reached by calling the controller's own operations rather than
by spawning the installed copy of it, so the code that plans a job is the code
that performs it and no environment has to be handed across a process boundary
for that to hold. What the *job* runs is the installed link, which points at
the asset root's copy of the controller; `require_matching_controller` below is
what keeps those from being two different versions.

This installer is also the sole platform refusal for the mission runner job,
and the refusal is the service-manager selection's rather than this module's:
`sys.platform` decides nothing here.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
from pathlib import Path
from typing import Any

import mission_runner_service
import service_manager


class InstallError(RuntimeError):
    pass


# Every module the installed controller imports, linked beside it because it is
# executed out of the install directory and resolves its siblings from there.
# An unlinked one makes every real install fail at import rather than here.
LINKED_MODULES = (
    mission_runner_service.CONTROLLER_NAME,
    "kanban_config.py",
    "service_manager.py",
)

# How a tracked asset says it is one of Kanban's own. The namespace segment is
# matched rather than fixed, because one tracked file can serve several
# installed namespaces -- `kanban_config.py` carries the issue-review marker and
# `service_manager.py` the issue-approval one, and both are linked here -- and
# what this check has to establish is that the file at the end of a link is
# Kanban's own module of that name, not whose installer first claimed it.
MANAGED_ASSET_PREFIX = "kanban-managed-asset:"


def run(
    args: list[str], *, check: bool = True, env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(args, text=True, capture_output=True, env=env)
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise InstallError(f"Command failed: {' '.join(args)}\n{detail}")
    return proc


def default_asset_root() -> Path:
    """The tree this script itself was invoked out of.

    The default for --asset-root, and the candidate --repo falls back to. One
    function rather than the same expression in two places, and resolved per
    call rather than frozen at import so a test can answer it for a tree that
    is not this checkout.
    """
    return Path(__file__).resolve().parent.parent


def target_repository_root(requested: Path) -> Path:
    """The main checkout of the repository this job advances missions for.

    The target, never the asset source. Its remote is what names the job and
    every runtime path beside it, so it has to be a real repository with real
    Git metadata. What supplies the modules linked beside the controller is
    `asset_root` below, and the two may be different trees.
    """
    path = requested.expanduser().resolve()
    proc = run(["git", "-C", str(path), "rev-parse", "--show-toplevel"], check=False)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        raise InstallError(
            f"{path} is not a Git repository checkout, so it cannot be the "
            f"repository a mission runner service runs for: {detail}"
        )
    root = Path(proc.stdout.strip()).resolve()
    if not (root / ".git").is_dir():
        raise InstallError(
            f"Install from the repository's main checkout, not a linked worktree: {root}"
        )
    return root


def asset_root(requested: Path) -> Path:
    """The tree the installed script links point into.

    Validated by the files it has to supply, never by Git metadata: the
    supported sources are a development checkout and the unpacked `cabal sdist`
    release archive, and only one of those has a `.git` directory. Requiring
    one would refuse the release exactly where it is documented as runnable.

    Present is not enough. What a link points at is executed by the installed
    controller, so each file has to be recognizable as Kanban's own module of
    that name before it is linked -- see `require_managed_sources`. This is the
    early, named refusal `main` reports; `install` asks again of the files it is
    actually about to link, because it can be called with an asset root that
    never came through here.
    """
    path = requested.expanduser().resolve()
    missing = [
        str(path / "tools" / name)
        for name in LINKED_MODULES
        if not (path / "tools" / name).is_file()
    ]
    if missing:
        raise InstallError(
            "Asset root does not contain the required mission runner files: "
            + ", ".join(missing)
        )
    require_managed_sources({name: path / "tools" / name for name in LINKED_MODULES})
    return path


def service_backend() -> service_manager.ServiceManagerBackend:
    """The same seam the controller reaches its service manager through.

    Constructed with this module's own `run`, so a command that fails here
    fails as an `InstallError` rather than as the controller's `ServiceError`.
    Resolved per call so a test can replace either this function or that
    wrapper.

    This is also the installer's only platform refusal, and it is the
    selection's rather than this module's: `sys.platform` never decides, so a
    Linux host with a live user session installs here exactly as a macOS host
    does, and a host managed by neither is refused before anything is written.
    """
    try:
        return service_manager.select_backend(
            run, service_manager.MISSION_RUNNER_NAMESPACE
        )
    except service_manager.NoServiceManagerError as exc:
        raise InstallError(str(exc)) from exc


def repository_job(
    repo: Path, config_path: str | None
) -> mission_runner_service.MissionRunnerJob:
    """This checkout's mission runner job, or an InstallError naming why it has
    none.

    A checkout whose remote does not resolve to a repository on github.com
    cannot be given this service at all: its identity is what names the job,
    every runtime path beside it, and its record entry, and inventing one from
    an unsupported value would install a job Kanban could never find.
    """
    try:
        return mission_runner_service.resolve_job(repo, config_path=config_path)
    except mission_runner_service.ServiceError as exc:
        raise InstallError(str(exc)) from exc


# ---------------------------------------------------------------------------
# Managed links
# ---------------------------------------------------------------------------


def managed_asset_pattern(name: str) -> re.Pattern[str]:
    return re.compile(re.escape(MANAGED_ASSET_PREFIX) + r"[A-Za-z0-9_-]+/" + re.escape(name))


def is_managed_asset(path: Path, name: str) -> bool:
    """Whether `path` is one of Kanban's own tracked modules called `name`.

    Verified by reading the identity marker the tracked file itself carries,
    not by where the path happens to point: a symlink to some unrelated
    `.../tools/service_manager.py` matches every shape test one could write
    while being someone else's file, and only its content can tell the two
    apart. An unreadable target is never treated as recognized.
    """
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    return bool(managed_asset_pattern(name).search(content))


def require_managed_sources(sources: dict[str, Path]) -> None:
    """Refuse to link a file that is not Kanban's own module of that name.

    Requirement 4's other half. An existing link is only ever replaced when its
    current target carries the marker, but that says nothing about the file the
    new link would point *at*: an asset root holding the genuine controller
    beside an unmarked `kanban_config.py` would otherwise be accepted, and the
    installed controller imports its siblings out of the install directory --
    so the job this installer loaded would execute a file nobody could show was
    Kanban's.

    Verified by content, exactly as `is_managed_asset` verifies a link's target
    and for the same reason: a path proves nothing about who wrote what is at
    the end of it. Raised before any mutation, so an asset root that fails here
    leaves the installation exactly as it was.
    """
    unrecognized = [
        str(path)
        for name, path in sorted(sources.items())
        if not is_managed_asset(path, name)
    ]
    if unrecognized:
        raise InstallError(
            "Refusing to install a link to a file that is not Kanban's own "
            "module of that name: "
            + ", ".join(unrecognized)
            + ". Point --asset-root at a Kanban checkout or an unpacked release "
            "archive."
        )


def resolved_link_target(link: Path, target: Path) -> Path:
    """A symlink's target as this process can reach it.

    `os.readlink` returns the target exactly as written, and a relative one is
    resolved by the kernel against the *link's own directory*, not against this
    process's working directory. Checking a raw relative target directly would
    report a working link as broken, and this installer replaces broken links,
    so that mistake would silently destroy a working installation.
    """
    return target if target.is_absolute() else link.parent / target


def is_replaceable_link(current_target: Path, source: Path) -> bool:
    """Whether an existing symlink may be re-pointed at `source`.

    One case qualifies: a link whose target is provably one of Kanban's own
    tracked modules of this name, recognized by the marker that file carries.

    A link resolving to any other real file is someone else's installation. A
    link resolving to nothing at all is not a weaker version of ours -- it is
    *unknowable*: a missing target carries no marker, and the name of a link
    proves nothing about who made it. Both are preserved and refused, and the
    refusal says how to clear a link this installer can no longer account for.
    """
    if current_target.name != source.name:
        return False
    return is_managed_asset(current_target, source.name)


def plan_symlink(source: Path, destination: Path) -> str:
    """What `install_symlink` would do, without writing anything."""
    if os.path.lexists(destination):
        if not destination.is_symlink():
            return "refused"
        current_target = Path(os.readlink(destination))
        if current_target == source:
            return "unchanged"
        if is_replaceable_link(
            resolved_link_target(destination, current_target), source
        ):
            return "updated"
        return "refused"
    return "created"


def symlink_refusal_reason(destination: Path) -> str:
    """Why `plan_symlink` refused, phrased as the recovery step. Read alongside
    a "refused" plan, so the two never disagree."""
    if not destination.is_symlink():
        return (
            f"{destination} already exists and is not a symlink. It is left untouched; "
            "move or remove it yourself, then re-run."
        )
    target = os.readlink(destination)
    if not os.path.exists(resolved_link_target(destination, Path(target))):
        return (
            f"{destination} is a symlink to {target}, which does not exist — so "
            "there is nothing to show whether it is one of Kanban's own. It is "
            "left untouched; remove it yourself, then re-run."
        )
    return (
        f"{destination} is a symlink to {target}, which does not "
        "resolve to one of Kanban's own tracked modules. It is left untouched; "
        "remove it yourself, then re-run."
    )


def unique_sibling(path: Path) -> Path:
    for _ in range(20):
        candidate = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
        if not os.path.lexists(candidate):
            return candidate
    raise InstallError(f"Could not allocate a temporary link beside {path}")


def replace_symlink_atomically(source: Path, destination: Path) -> None:
    temporary = unique_sibling(destination)
    try:
        temporary.symlink_to(source)
        os.replace(temporary, destination)
    finally:
        if os.path.lexists(temporary):
            temporary.unlink()


def install_symlink(source: Path, destination: Path) -> str:
    """Point `destination` at `source`, replacing only a link this installer
    owns. An upgrade re-points the one link rather than adding another beside
    it, which is what keeps re-running this convergent."""
    source = source.resolve(strict=True)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    plan = plan_symlink(source, destination)
    if plan == "refused":
        raise InstallError(
            "Refusing to replace an existing installation: "
            + symlink_refusal_reason(destination)
        )
    if plan == "created":
        destination.symlink_to(source)
    elif plan == "updated":
        replace_symlink_atomically(source, destination)
    return plan


def plan_link_removal(destination: Path, name: str) -> str:
    """What `remove_symlink` would do, without writing anything.

    Removal is refused far more readily than replacement is. A link this
    installer did not create points at content it cannot account for, and an
    uninstall that deleted it would take away something it never gave.
    """
    if not os.path.lexists(destination):
        return "absent"
    if not destination.is_symlink():
        return "kept"
    target = resolved_link_target(destination, Path(os.readlink(destination)))
    if not os.path.exists(target):
        # Unknowable, so kept. A missing target carries no marker, and the name
        # of a link proves nothing about who made it: deleting one on the
        # strength of its name is exactly the guess this check exists to
        # refuse.
        return "kept"
    return "removed" if is_managed_asset(target, name) else "kept"


def remove_symlink(destination: Path, name: str) -> str:
    plan = plan_link_removal(destination, name)
    if plan == "removed":
        destination.unlink()
    return plan


# ---------------------------------------------------------------------------
# Install and uninstall
# ---------------------------------------------------------------------------


def link_sources(assets: Path, install_dir: Path) -> dict[str, tuple[Path, Path]]:
    """Each managed link, as (source, destination), keyed by module name.

    Taken from the asset root rather than from the target repository: what a
    link points at is Kanban's own tracked module, and the repository this
    service runs for supplies none of them.
    """
    return {
        name: (assets / "tools" / name, install_dir / name) for name in LINKED_MODULES
    }


def dependent_repositories(install_dir: Path, *, excluding: str | None = None) -> list[str]:
    """Every repository whose job runs from *these* links.

    The links are shared, so this is what decides whether any of them may go --
    but they are shared only within one install directory. A repository
    installed into a different one runs its own copies, and treating it as a
    dependant would strand this directory's links forever.

    Fails closed on an entry that names no install directory it can be read
    from: such a record could have been written by this installation, and
    keeping a link nothing needs is recoverable while removing one a live job
    runs from is not.

    `excluding` is for the one caller that is asking about a state it has not
    reached yet: a *plan* describes an uninstall that has not happened, so the
    repository it is about is not yet gone and has to be discounted by hand.
    Everywhere else the question is asked of the record as it actually stands --
    including immediately before links are removed, where a repository that has
    reappeared since the plan is a dependant like any other, whoever it is.
    """
    here = os.path.realpath(install_dir)
    dependants = []
    for other, record in mission_runner_service.installed_repository_records().items():
        if other == excluding:
            continue
        recorded = record.get("install_dir")
        if not isinstance(recorded, str) or not recorded:
            dependants.append(other)
            continue
        if os.path.realpath(recorded) == here:
            dependants.append(other)
    return sorted(dependants)


def may_remove_links(
    install_dir: Path,
    *,
    excluding: str | None = None,
    record_readable: bool | None = None,
) -> bool:
    """Whether this directory's shared links may be taken away.

    Two questions, and the second is the one `dependent_repositories` alone
    cannot answer. That function reads the discovery record, and
    `installed_repository_records` reports an *unreadable* document as no
    repositories -- the right answer for a reader asking whether one repository
    is installed, and a dangerous one here, because a document nobody can decode
    may name every job on this account. Removing on that reading would delete
    the controller and the modules a sibling's loaded job runs from and leave
    the manager holding a job nothing can satisfy.

    So an undecodable record is treated as an unknown dependency set and the
    links stay. Keeping a link nothing needs is recoverable by a later
    uninstall; removing one a live job runs from is not.

    `record_readable` is for the one caller that must not ask *now*: removing a
    repository's entry rebuilds an undecodable document around that removal, so
    a question asked afterwards always answers "readable, and nothing depends on
    these" -- which is exactly the reading this function exists to refuse. That
    caller reads it before the removal and hands the answer back in.
    """
    readable = (
        mission_runner_service.installed_repository_records_readable()
        if record_readable is None
        else record_readable
    )
    if not readable:
        return False
    return not dependent_repositories(install_dir, excluding=excluding)


def require_matching_controller(assets: Path) -> None:
    """Refuse to plan a job with one copy of the controller and install another.

    This installer resolves the job -- its identity, its label, its definition,
    its record entry -- through the controller module it imported, while the
    link it installs points at the *asset root's* copy, which is what a started
    job actually runs. Those are one file whenever the installer is run out of
    the tree it links from, which is what `--asset-root` defaults to. When they
    are two files that differ, the definition would have been written by code
    that will never run it, so the install is refused rather than made.

    Asked of the asset root, not of the target repository: the target supplies
    no controller at all, and a repository that merely happens to carry a file
    of that name is nothing this installer would ever link. A release archive
    carrying identical controller bytes is accepted for the same reason a
    second checkout is -- what matters is the bytes, not the provenance.
    """
    ours = Path(mission_runner_service.__file__).resolve()
    theirs = (assets / "tools" / mission_runner_service.CONTROLLER_NAME).resolve()
    if ours == theirs:
        return
    try:
        matched = ours.read_bytes() == theirs.read_bytes()
    except OSError as exc:
        raise InstallError(f"Could not compare {theirs} against {ours}: {exc}") from exc
    if matched:
        return
    raise InstallError(
        f"{theirs} differs from the controller this installer planned the job with "
        f"({ours}), so the definition would be written by one copy and run by the "
        f"other. Run `python3 tools/install_mission_runner.py` from {assets} instead."
    )


def same_directory(left: str | Path, right: str | Path) -> bool:
    """Whether two spellings name one installation. Compared after resolution,
    because one directory has many names and a reinstall that read them as two
    would relocate a job that never moved."""
    return os.path.realpath(left) == os.path.realpath(right)


def installation_lock(install_dir: Path) -> Any:
    return mission_runner_service.installation_lock(install_dir)


def plan_released_links(
    assets: Path, install_dir: Path, identity: str
) -> dict[str, dict[str, str]]:
    """What `release_links` would do to the directory this repository is
    leaving, without writing anything.

    Asked with this repository discounted, because the plan describes a
    relocation that has not happened yet: it is still recorded in the directory
    it is about to leave.
    """
    if not may_remove_links(install_dir, excluding=identity):
        return {
            name: {"destination": str(destination), "result": "kept"}
            for name, (_source, destination) in link_sources(assets, install_dir).items()
        }
    return {
        name: {
            "destination": str(destination),
            "result": plan_link_removal(destination, name),
        }
        for name, (_source, destination) in link_sources(assets, install_dir).items()
    }


def release_links(
    assets: Path, install_dir: Path, identity: str
) -> dict[str, dict[str, str]]:
    """Take back the links of an installation this repository has left.

    A reinstall pointed at another directory moves the job's definition and its
    record entry there, and the directory it came from is then running nothing
    -- so leaving its links behind would strand Kanban-managed files no later
    uninstall would ever look for. Removed on exactly the uninstall rule: only
    when no remaining job depends on that directory, and only for a link
    positively recognized as Kanban's own.
    """
    with installation_lock(install_dir):
        # Without the exclusion, and inside the lock: by here the record already
        # names the directory this repository moved to, so it can only appear
        # among these dependants by having been reinstalled here since -- which
        # makes it a dependant like any other rather than the one to discount.
        if not may_remove_links(install_dir):
            return plan_released_links(assets, install_dir, identity)
        return {
            name: {
                "destination": str(destination),
                "result": remove_symlink(destination, name),
            }
            for name, (_source, destination) in link_sources(assets, install_dir).items()
        }


def require_recorded_installation(
    job: mission_runner_service.MissionRunnerJob, install_dir: Path
) -> None:
    """Refuse to remove a job from a directory it is not installed in.

    The job, its definition, and its record entry are named by identity alone,
    so an uninstall pointed at the wrong directory would remove all three and
    then delete links in a directory the job never ran from -- stranding the
    links it actually did, with nothing left to find them by. The recorded
    location is the job's own answer, and `--install-dir` is the only way to
    disagree with it, so disagreeing is refused rather than resolved.
    """
    recorded = mission_runner_service.installed_install_dir(job.identity)
    if recorded is None or same_directory(recorded, install_dir):
        return
    raise InstallError(
        f"The mission runner service for {job.identity} is installed in "
        f"{recorded}, not {install_dir}. Re-run without --install-dir, which "
        "resolves the recorded installation, or name that one."
    )


def controller_operation(
    operation: str, job: mission_runner_service.MissionRunnerJob, *arguments: Any
) -> dict[str, Any]:
    """One of the controller's own job operations, in this module's failure
    vocabulary.

    Called rather than spawned. The controller owns the job -- its identifier,
    its definition, its discovery entry, and every service-manager interaction
    behind them -- and this installer owns nothing about it except when to ask.
    """
    action = getattr(mission_runner_service, operation)
    try:
        return action(job, *arguments)
    except mission_runner_service.ServiceError as exc:
        raise InstallError(str(exc)) from exc


def install(
    repo: Path,
    install_dir: Path,
    *,
    asset_root: Path,
    config_path: str | None = None,
    dry_run: bool,
) -> dict[str, Any]:
    """Install one repository's stopped mission runner job.

    `repo` is the target: the checkout whose missions this service advances,
    whose remote names the job. `asset_root` is where Kanban's own tracked
    modules are linked from. They are one tree whenever this installer is run
    from the checkout it is installing for, which is what the defaults produce;
    they differ when the modules come from an unpacked release archive, which
    is not a repository anything can be installed against.

    Every refusal happens before the first write, in the order of what it
    protects: the host, because an installation that could never be completed
    or controlled must not leave half of itself behind; the identity, because
    it is what names everything else; the controller copy, because the job must
    be planned by the code that will run it; then the controller's own
    `install_plan`, which refuses any live run of this repository's runner; and
    finally each managed link, because an ordinary user file in the way is
    preserved rather than replaced.
    """
    backend = service_backend()
    # Absolute before it is recorded or written into a definition: a relative
    # path there would be resolved against whatever working directory the job
    # is eventually launched with, which is the checkout rather than the
    # operator's shell.
    resolved_config_path = (
        str(Path(config_path).expanduser().resolve()) if config_path else None
    )
    job = repository_job(repo, resolved_config_path)
    require_matching_controller(asset_root)
    # A snapshot, and used for nothing but the plan below. What the install
    # actually acts on is the location the record write itself replaced, which
    # is the only reading of it no concurrent install can invalidate.
    snapshot = mission_runner_service.installed_install_dir(job.identity)
    moving = snapshot is not None and not same_directory(snapshot, install_dir)
    plan = controller_operation("install_plan", job, install_dir)
    sources = link_sources(asset_root, install_dir)
    resolved_sources = {
        name: (source.resolve(strict=True), destination)
        for name, (source, destination) in sources.items()
    }
    # Of the files this install is actually about to link, and before the first
    # write. `asset_root` asks the same question of the same tree, but `install`
    # is reachable with an `asset_root` argument that never went through it.
    require_managed_sources(
        {name: source for name, (source, _destination) in resolved_sources.items()}
    )
    link_plans = {
        name: plan_symlink(source, destination)
        for name, (source, destination) in resolved_sources.items()
    }
    refused = [
        symlink_refusal_reason(destination)
        for name, (_source, destination) in resolved_sources.items()
        if link_plans[name] == "refused"
    ]
    if refused:
        raise InstallError(
            "Refusing to replace an existing installation: " + "; ".join(refused)
        )
    document = {
        "repo": str(repo),
        "asset_root": str(asset_root),
        "install_dir": str(install_dir),
        "service_manager": backend.backend_name(),
        "links": {
            name: {
                "source": str(source),
                "destination": str(destination),
                "result": link_plans[name],
            }
            for name, (source, destination) in sources.items()
        },
        "job": plan,
        "relocated_from": str(snapshot) if moving else None,
        "released_links": (
            plan_released_links(asset_root, Path(snapshot), job.identity)
            if moving
            else {}
        ),
    }
    if dry_run:
        return {**document, "installed": False, "dry_run": True}

    # Under both of this transition's locks, so the record entry that says this
    # repository depends on these links is written in the same breath as the
    # links themselves, and so no other transition of this identity can be
    # deciding where it lives at the same time. An uninstall for another
    # repository reading the dependants in between would otherwise decide they
    # were unneeded and delete what this install had just created.
    with mission_runner_service.job_transition(job, install_dir):
        results = {
            name: install_symlink(source, destination)
            for name, (source, destination) in sources.items()
        }
        for name, result in results.items():
            document["links"][name]["result"] = result
        # After the links, so the job's definition can only ever name a
        # controller that is really there, and so a refused link leaves no job
        # behind.
        document["job"] = controller_operation("install_job", job, install_dir)

    previous = document["job"].get("previous_install_dir")
    relocating = previous is not None and not same_directory(previous, install_dir)
    document["relocated_from"] = str(previous) if relocating else None
    if relocating:
        # Sequentially, never nested: two installation locks held at once could
        # be taken in two orders by two relocations and deadlock. By here the
        # record already names the new directory, so this repository is no
        # longer among the old one's dependants -- and if it is again, it was
        # reinstalled there and its links stay.
        document["released_links"] = release_links(
            asset_root, Path(previous), job.identity
        )
    else:
        document["released_links"] = {}
    return {**document, "installed": True, "dry_run": False}


def uninstall(
    repo: Path, install_dir: Path, *, asset_root: Path, dry_run: bool
) -> dict[str, Any]:
    """Remove one repository's job, and the shared links if nothing is left.

    The job, its definition, and its record entry are this repository's alone.
    The links are not: they are what every job installed into *this* directory
    runs from, so they may go only once no such job is left, and only for a
    link positively recognized as Kanban's own.
    """
    backend = service_backend()
    job = repository_job(repo, None)
    require_recorded_installation(job, install_dir)
    plan = controller_operation("uninstall_plan", job)
    # Discounted here because the plan describes an uninstall that has not
    # happened: this repository is still recorded, and still running from these
    # links, until it is removed below.
    dependants = dependent_repositories(install_dir, excluding=job.identity)
    record_readable = mission_runner_service.installed_repository_records_readable()
    sources = link_sources(asset_root, install_dir)
    if not may_remove_links(install_dir, excluding=job.identity):
        link_plans = {name: "kept" for name in sources}
    else:
        link_plans = {
            name: plan_link_removal(destination, name)
            for name, (_source, destination) in sources.items()
        }
    document = {
        "repo": str(repo),
        "asset_root": str(asset_root),
        "install_dir": str(install_dir),
        "service_manager": backend.backend_name(),
        "dependent_repositories": dependants,
        # Reported beside them because an empty dependant list means two
        # different things: nothing else is installed here, or the record that
        # would say so could not be decoded. Only the first lets the links go.
        "record_readable": record_readable,
        "links": {
            name: {"destination": str(destination), "result": link_plans[name]}
            for name, (_source, destination) in sources.items()
        },
        "job": plan,
    }
    if dry_run:
        return {**document, "uninstalled": False, "dry_run": True}

    # Under this installation's lock, and recomputing the dependants inside it:
    # the set read for the plan above is a snapshot, and an install for another
    # repository landing between that read and the removal below would leave
    # its job pointing at links this uninstall had just deleted.
    with mission_runner_service.job_transition(job, install_dir):
        # Re-checked inside the locks: an install could have moved this
        # repository elsewhere since the plan, and removing links here would
        # then strand the ones its job actually runs from.
        require_recorded_installation(job, install_dir)
        # Read before the removal, because the removal rewrites the document:
        # `remove_repository_record` rebuilds an undecodable one around this
        # entry's departure, so asking afterwards would report a readable record
        # naming nobody -- and the links a sibling still runs from would go.
        record_readable = (
            mission_runner_service.installed_repository_records_readable()
        )
        # The job first: the links are what it runs from, so removing them
        # while it was still loaded would leave a job the manager could start
        # and nothing could satisfy. Handed this directory explicitly so the
        # lock it takes with the transition is the one already held here.
        document["job"] = controller_operation("uninstall_job", job, install_dir)
        # Recomputed inside the lock and with nothing discounted. This
        # repository's entry is gone by now, so it can only appear by having
        # been reinstalled -- which no longer happens, because a start takes
        # this same lock, and which would still be honoured if it did.
        document["dependent_repositories"] = dependent_repositories(install_dir)
        document["record_readable"] = record_readable
        if may_remove_links(install_dir, record_readable=record_readable):
            for name, (_source, destination) in sources.items():
                document["links"][name]["result"] = remove_symlink(destination, name)
        else:
            for name in sources:
                document["links"][name]["result"] = "kept"
    return {**document, "uninstalled": True, "dry_run": False}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Install, or remove, Kanban's stopped user-scoped mission runner "
            "job for one repository."
        )
    )
    parser.add_argument(
        "--repo",
        default=None,
        help=(
            "Main checkout of the repository to advance missions for (default: "
            "the tree containing this script, when that tree is itself a "
            "checkout)."
        ),
    )
    parser.add_argument(
        "--asset-root",
        default=None,
        help=(
            "Kanban checkout or unpacked release archive supplying the tracked "
            "modules the installed links point at (default: the tree containing "
            "this script). Never a target: nothing is installed into it."
        ),
    )
    parser.add_argument(
        "--install-dir",
        default=None,
        help=(
            "Stable per-user script-link directory (default: the directory this "
            "repository's job was installed into, or Kanban's own)."
        ),
    )
    parser.add_argument(
        "--config",
        default=os.environ.get("KANBAN_MISSION_RUNNER_CONFIG_PATH"),
        help="Optional kanban config.toml path carried into the installed job.",
    )
    parser.add_argument(
        "--uninstall",
        action="store_true",
        help="Remove this repository's job instead of installing one.",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Validate and describe without writing."
    )
    parser.add_argument("--json", action="store_true", help="Print JSON output.")
    return parser.parse_args(argv)


def selected_target(requested: str | None) -> Path:
    """The repository this run installs a mission runner for, or an InstallError
    saying how to name it.

    An explicit --repo is validated as any target is. The default is the tree
    holding this script, which is a checkout in a development install and an
    unpacked release archive in a released one -- and an archive is not a
    repository, so it is refused here by name rather than reported as a
    puzzling Git failure. Nothing has been written at that point: this runs
    before `install` is even entered.
    """
    if requested is not None:
        return target_repository_root(Path(requested))
    default = default_asset_root()
    if not (default / ".git").is_dir():
        raise InstallError(
            f"{default} is not a repository checkout, so it cannot be the "
            "repository this mission runner service runs for -- an unpacked "
            "release archive carries no Git metadata. Name the checkout with "
            "--repo PATH; its tracked modules still come from --asset-root, "
            "which already defaults to this tree."
        )
    return target_repository_root(default)


def selected_install_dir(repo: Path, requested: str | None) -> Path:
    """Where this run's links go.

    An explicit `--install-dir` wins. Otherwise the controller's own resolution
    for this repository decides, so a re-run with no options converges on the
    installation the job is already in rather than silently moving it to the
    default.
    """
    if requested:
        return Path(requested).expanduser().resolve()
    try:
        job = repository_job(repo, None)
    except InstallError:
        # An identity that cannot be resolved is reported by the operation
        # itself, in the sentence that explains what it means; guessing a
        # directory here just so that failure can happen two lines later would
        # replace it with a worse one.
        return mission_runner_service.selected_install_dir()
    return mission_runner_service.job_install_dir(job)


def print_plan(result: dict[str, Any], *, uninstalling: bool) -> None:
    """The same plan the --json document carries, in sentences.

    Both are printed from one `result`, so a dry run and the mutation it
    predicted can never describe different work in the two forms.
    """
    dry_run = result["dry_run"]
    job = result["job"]
    if uninstalling:
        verb = "Would remove" if dry_run else "Removed"
        print(f"{verb} the mission runner job for {job['repository']}")
    else:
        verb = "Would install" if dry_run else "Installed"
        print(f"{verb} the mission runner job for {job['repository']} at {result['repo']}")
        print(f"Assets: {result['asset_root']}")
    print(f"Service: {job['label']} ({result['service_manager']})")
    for _name, link in sorted(result["links"].items()):
        print(f"Link {link['destination']}: {link['result']}")
    print(f"Record: {job['record']}")
    if uninstalling and result["dependent_repositories"]:
        print(
            "Shared links kept for still-installed "
            + ", ".join(result["dependent_repositories"])
        )
    elif uninstalling and not result["record_readable"]:
        print(
            "Shared links kept: the discovery record could not be read, so "
            "which jobs still run from them is unknown. Reinstall each "
            "repository that should be installed here, then re-run."
        )
    if dry_run:
        print("Dry run; nothing was changed.")
    elif not uninstalling:
        print("The job is loaded but stopped; start it from Kanban when ready.")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        repo = selected_target(args.repo)
        assets = asset_root(
            default_asset_root() if args.asset_root is None else Path(args.asset_root)
        )
        install_dir = selected_install_dir(repo, args.install_dir)
        if args.uninstall:
            result = uninstall(
                repo, install_dir, asset_root=assets, dry_run=args.dry_run
            )
        else:
            result = install(
                repo,
                install_dir,
                asset_root=assets,
                config_path=args.config,
                dry_run=args.dry_run,
            )
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print_plan(result, uninstalling=args.uninstall)
        return 0
    # `ServiceManagerError` is the seam's own vocabulary for a fault no injected
    # runner can carry, and reaches here whenever it was raised past the point
    # `service_backend` translates the selection itself.
    except (
        InstallError,
        mission_runner_service.ServiceError,
        service_manager.ServiceManagerError,
        OSError,
    ) as exc:
        if args.json:
            print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        else:
            print(f"install_mission_runner.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
