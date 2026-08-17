#!/usr/bin/env python3

"""Safely install Kanban's user-scoped issue approval job.

The installer never starts the service. It installs stable Kanban-managed
script links and, through `tools/approve_issues_service.py`, loads a stopped
job for the selected repository -- a LaunchAgent on macOS, a systemd user unit
on Linux, whichever `tools/service_manager.select_backend` says this host is
managed by. An optional --config path is persisted against that repository and
carried into the job it installs.

One job per canonical GitHub repository, in an `issue-approval` namespace of
its own. The script links are shared -- one installed copy of the controller,
the configuration parser, and the service-manager backend serves every
repository -- while the job, its runtime state, its logs, and its `--config`
selection are the repository's own. Installing a second repository therefore
adds an entry beside the first rather than replacing it, and uninstalling one
removes that entry and that job alone: the shared links go only when no
installed job is left to run from them.

The canonical issue-review backend is *not* installed here and never linked
here. It is one global installation shared by every ordinary review workflow,
so this installer only resolves it -- through the record
`docs/agent-workflow-contract.md` fixes, in the order
`Kanban.Review.resolveCanonicalIssueReviewer` implements -- and refuses with
`tools/install_issue_review.py`'s own remediation when it is absent. Making a
second reviewer installation here would give this service a backend the rest of
the workflow does not use.

The job half is reached by calling the controller's own operations rather than
by spawning the installed copy of it, so the code that plans a job is the code
that performs it and no environment has to be handed across a process boundary
for that to hold. What the *job* runs is the installed link, which points at
the worked checkout's copy of the controller; `require_matching_controller`
below is what keeps those from being two different versions.

This installer is also the sole platform refusal for the approval service, and
the refusal is the service-manager selection's rather than this module's:
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

import approve_issues_service
import service_manager


class InstallError(RuntimeError):
    pass


# Every module the installed controller imports, linked beside it because it is
# executed out of the install directory and resolves its siblings from there.
# An unlinked one makes every real install fail at import rather than here.
# `approve_issues.py` is deliberately absent: that backend is the global
# issue-review installation this service resolves, never one it makes.
LINKED_MODULES = (
    approve_issues_service.CONTROLLER_NAME,
    "kanban_config.py",
    "service_manager.py",
)

# How a tracked asset says it is one of Kanban's own. The namespace segment is
# matched rather than fixed, because one tracked file can serve several
# installed namespaces -- `kanban_config.py` carries the issue-review marker and
# is linked here too -- and what this check has to establish is that the file at
# the end of a link is Kanban's own module of that name, not whose installer
# first claimed it.
MANAGED_ASSET_PREFIX = "kanban-managed-asset:"


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
    missing = [
        str(root / "tools" / name)
        for name in LINKED_MODULES
        if not (root / "tools" / name).is_file()
    ]
    if missing:
        raise InstallError(
            "Repository does not contain the required approval service files: "
            + ", ".join(missing)
        )
    return root


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
            run, service_manager.ISSUE_APPROVAL_NAMESPACE
        )
    except service_manager.NoServiceManagerError as exc:
        raise InstallError(str(exc)) from exc


def repository_job(
    repo: Path, config_path: str | None
) -> approve_issues_service.ApprovalJob:
    """This checkout's approval job, or an InstallError naming why it has none.

    A checkout whose remote does not resolve to a repository on github.com
    cannot be given this service at all: its identity is what names the job,
    every runtime path beside it, and its record entry, and inventing one from
    an unsupported value would install a job Kanban could never find.
    """
    try:
        return approve_issues_service.resolve_job(repo, config_path=config_path)
    except approve_issues_service.ServiceError as exc:
        raise InstallError(str(exc)) from exc


# What every canonical-backend failure has to end with, whatever went wrong.
BACKEND_REMEDIATION = (
    "Run `python3 tools/install_issue_review.py` from the Kanban checkout, "
    "adding --install-dir if it belongs elsewhere."
)


def canonical_backend(job: approve_issues_service.ApprovalJob) -> Path:
    """The installed canonical issue-review backend this job will run.

    Resolved, never installed, and resolved for *this job's* selection rather
    than for this shell's: a reinstall from an empty environment must verify
    the reviewer installation the definition it is about to write will name,
    which is the one the previous install recorded.

    The order is the controller's, which is the one
    `docs/agent-workflow-contract.md` sections 2.3 and 3 fix and
    `Kanban.Review.resolveCanonicalIssueReviewer` implements: a non-empty
    `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, then the absolute `backend_path` the
    issue-review installer recorded, then -- only when the record is absent or
    names none -- the directory holding the record.

    Every failure is closed and every one of them is remediated the same way. A
    selected override that is missing does not fall through to the record, a
    record that will not parse is not treated as an absent one, and neither is
    repaired by installing a second backend here: an install made against a
    reviewer the operator did not choose is worse than an install refused.
    """
    try:
        resolved = approve_issues_service.resolve_backend(
            approve_issues_service.selected_backend_install_dir(job)
        )
        # Absolute in what this installer reports, for the same reason the
        # definition records an absolute override: a relative answer names a
        # different file to every process that reads it, and the one a job
        # would read is not the one verified here. An already-absolute path is
        # reported exactly as recorded, symlinks and all, because the managed
        # link is the stable name the record deliberately holds.
        return resolved if resolved.is_absolute() else resolved.resolve()
    except approve_issues_service.ServiceError as exc:
        message = str(exc)
        if "install_issue_review.py" not in message:
            message = f"{message} {BACKEND_REMEDIATION}"
        raise InstallError(message) from exc


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

    Two cases qualify, and refusal protects content in both. A link already
    resolving to Kanban's own tracked module of this name is an installation
    this installer owns. A link whose target no longer exists at all is what a
    moved or deleted checkout leaves behind: broken, holding nothing to
    preserve, and exactly the state a re-run has to converge. A link resolving
    to any other real file is someone else's, and is preserved and refused.
    """
    if current_target.name != source.name:
        return False
    if not os.path.exists(current_target):
        return True
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
    return (
        f"{destination} is a symlink to {os.readlink(destination)}, which does not "
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
        # A broken link this installer's own name and shape: it points nowhere,
        # so nothing is lost with it, and leaving it behind would leave the
        # next install to converge a link no installation stands behind.
        return "removed" if target.name == name else "kept"
    return "removed" if is_managed_asset(target, name) else "kept"


def remove_symlink(destination: Path, name: str) -> str:
    plan = plan_link_removal(destination, name)
    if plan == "removed":
        destination.unlink()
    return plan


# ---------------------------------------------------------------------------
# Install and uninstall
# ---------------------------------------------------------------------------


def link_sources(repo: Path, install_dir: Path) -> dict[str, tuple[Path, Path]]:
    """Each managed link, as (source, destination), keyed by module name."""
    return {
        name: (repo / "tools" / name, install_dir / name) for name in LINKED_MODULES
    }


def dependent_repositories(identity: str, install_dir: Path) -> list[str]:
    """Every other repository whose job runs from *these* links.

    The links are shared, so this is what decides whether any of them may go —
    but they are shared only within one install directory. A repository
    installed into a different one runs its own copies, and treating it as a
    dependant would strand this directory's links forever.

    Fails closed on an entry that names no install directory it can be read
    from: such a record could have been written by this installation, and
    keeping a link nothing needs is recoverable while removing one a live job
    runs from is not.

    Computed from the record before the uninstall rather than after it, so the
    plan a dry run reports and the decision the uninstall makes are one
    computation over one document.
    """
    here = os.path.realpath(install_dir)
    dependants = []
    for other, record in approve_issues_service.installed_repository_records().items():
        if other == identity:
            continue
        recorded = record.get("install_dir")
        if not isinstance(recorded, str) or not recorded:
            dependants.append(other)
            continue
        if os.path.realpath(recorded) == here:
            dependants.append(other)
    return sorted(dependants)


def require_matching_controller(repo: Path) -> None:
    """Refuse to plan a job with one copy of the controller and install another.

    This installer resolves the job -- its identity, its label, its definition,
    its record entry -- through the controller module it imported, while the
    link it installs points at the *worked* checkout's copy, which is what a
    started job actually runs. Those are one file whenever the installer is run
    from the checkout it is installing, which is what `--repo` defaults to.
    When they are two files that differ, the definition would have been written
    by code that will never run it, so the install is refused rather than made.
    """
    ours = Path(approve_issues_service.__file__).resolve()
    theirs = (repo / "tools" / approve_issues_service.CONTROLLER_NAME).resolve()
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
        f"other. Run `python3 tools/install_issue_approval.py` from {repo} instead."
    )


def same_directory(left: str | Path, right: str | Path) -> bool:
    """Whether two spellings name one installation. Compared after resolution,
    because one directory has many names and a reinstall that read them as two
    would relocate a job that never moved."""
    return os.path.realpath(left) == os.path.realpath(right)


def installation_lock(install_dir: Path) -> Any:
    return approve_issues_service.installation_lock(install_dir)


def plan_released_links(
    repo: Path, install_dir: Path, identity: str
) -> dict[str, dict[str, str]]:
    """What `release_links` would do to the directory this repository is
    leaving, without writing anything."""
    if dependent_repositories(identity, install_dir):
        return {
            name: {"destination": str(destination), "result": "kept"}
            for name, (_source, destination) in link_sources(repo, install_dir).items()
        }
    return {
        name: {
            "destination": str(destination),
            "result": plan_link_removal(destination, name),
        }
        for name, (_source, destination) in link_sources(repo, install_dir).items()
    }


def release_links(
    repo: Path, install_dir: Path, identity: str
) -> dict[str, dict[str, str]]:
    """Take back the links of an installation this repository has left.

    A reinstall pointed at another directory moves the job's definition and its
    record entry there, and the directory it came from is then running nothing
    — so leaving its links behind would strand Kanban-managed files no later
    uninstall would ever look for. Removed on exactly the uninstall rule: only
    when no remaining job depends on that directory, and only for a link
    positively recognized as Kanban's own.
    """
    with installation_lock(install_dir):
        if dependent_repositories(identity, install_dir):
            return plan_released_links(repo, install_dir, identity)
        return {
            name: {
                "destination": str(destination),
                "result": remove_symlink(destination, name),
            }
            for name, (_source, destination) in link_sources(repo, install_dir).items()
        }


def controller_operation(
    operation: str, job: approve_issues_service.ApprovalJob, *arguments: Any
) -> dict[str, Any]:
    """One of the controller's own job operations, in this module's failure
    vocabulary.

    Called rather than spawned. The controller owns the job -- its identifier,
    its definition, its discovery entry, and every service-manager interaction
    behind them -- and this installer owns nothing about it except when to ask.
    """
    action = getattr(approve_issues_service, operation)
    try:
        return action(job, *arguments)
    except approve_issues_service.ServiceError as exc:
        raise InstallError(str(exc)) from exc


def install(
    repo: Path,
    install_dir: Path,
    *,
    config_path: str | None = None,
    dry_run: bool,
) -> dict[str, Any]:
    """Install one repository's stopped approval job.

    Every refusal happens before the first write, in the order of what it
    protects: the host, because an installation that could never be completed
    or controlled must not leave half of itself behind; the identity, because
    it is what names everything else; the controller copy, because the job must
    be planned by the code that will run it; the canonical backend, because a
    service with no reviewer to run is not an installation; then the
    controller's own `install_plan`, which refuses the untracked approval
    daemon and any live run of this repository's controller; and finally each
    managed link, because an ordinary user file in the way is preserved rather
    than replaced.
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
    require_matching_controller(repo)
    canonical = canonical_backend(job)
    # Read before the record is updated, because the update is what forgets it:
    # an install that moves this repository to another directory has to leave
    # the one it came from without the links it is no longer run from.
    previous = approve_issues_service.installed_install_dir(job.identity)
    relocating = previous is not None and not same_directory(previous, install_dir)
    plan = controller_operation("install_plan", job, install_dir)
    sources = link_sources(repo, install_dir)
    resolved_sources = {
        name: (source.resolve(strict=True), destination)
        for name, (source, destination) in sources.items()
    }
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
        "install_dir": str(install_dir),
        "backend_path": str(canonical),
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
        "relocated_from": str(previous) if relocating else None,
        "released_links": (
            plan_released_links(repo, Path(previous), job.identity)
            if relocating
            else {}
        ),
    }
    if dry_run:
        return {**document, "installed": False, "dry_run": True}

    # Under this installation's lock, so the record entry that says this
    # repository depends on these links is written in the same breath as the
    # links themselves. An uninstall for another repository reading the
    # dependants in between would otherwise decide they were unneeded and
    # delete what this install had just created.
    with installation_lock(install_dir):
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

    if relocating:
        # Sequentially, never nested: two installation locks held at once
        # could be taken in two orders by two relocations and deadlock. By
        # here the record already names the new directory, so this repository
        # is no longer among the old one's dependants.
        document["released_links"] = release_links(
            repo, Path(previous), job.identity
        )
    return {**document, "installed": True, "dry_run": False}


def uninstall(repo: Path, install_dir: Path, *, dry_run: bool) -> dict[str, Any]:
    """Remove one repository's job, and the shared links if nothing is left.

    The job, its definition, and its record entry are this repository's alone.
    The links are not: they are what every job installed into *this* directory
    runs from, so they may go only once no such job is left, and only for a
    link positively recognized as Kanban's own.
    """
    backend = service_backend()
    job = repository_job(repo, None)
    plan = controller_operation("uninstall_plan", job)
    dependants = dependent_repositories(job.identity, install_dir)
    sources = link_sources(repo, install_dir)
    if dependants:
        link_plans = {name: "kept" for name in sources}
    else:
        link_plans = {
            name: plan_link_removal(destination, name)
            for name, (_source, destination) in sources.items()
        }
    document = {
        "repo": str(repo),
        "install_dir": str(install_dir),
        "service_manager": backend.backend_name(),
        "dependent_repositories": dependants,
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
    with installation_lock(install_dir):
        # The job first: the links are what it runs from, so removing them
        # while it was still loaded would leave a job the manager could start
        # and nothing could satisfy.
        document["job"] = controller_operation("uninstall_job", job)
        dependants = dependent_repositories(job.identity, install_dir)
        document["dependent_repositories"] = dependants
        if not dependants:
            for name, (_source, destination) in sources.items():
                document["links"][name]["result"] = remove_symlink(destination, name)
        else:
            for name in sources:
                document["links"][name]["result"] = "kept"
    return {**document, "uninstalled": True, "dry_run": False}


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Install, or remove, Kanban's stopped user-scoped issue approval "
            "job for one repository."
        )
    )
    parser.add_argument(
        "--repo",
        default=str(Path(__file__).resolve().parent.parent),
        help="Repository checkout to review issues for (default: this checkout).",
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
        default=os.environ.get("KANBAN_ISSUE_APPROVAL_CONFIG_PATH"),
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


def selected_install_dir(repo: Path, requested: str | None) -> Path:
    """Where this run's links go.

    An explicit `--install-dir` wins. Otherwise the controller's own
    resolution for this repository decides, so a re-run with no options
    converges on the installation the job is already in rather than silently
    moving it to the default.
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
        return approve_issues_service.selected_install_dir()
    return approve_issues_service.job_install_dir(job)


def print_plan(result: dict[str, Any], *, uninstalling: bool) -> None:
    """The same plan the --json document carries, in sentences.

    Both are printed from one `result`, so a dry run and the mutation it
    predicted can never describe different work in the two forms.
    """
    dry_run = result["dry_run"]
    job = result["job"]
    if uninstalling:
        verb = "Would remove" if dry_run else "Removed"
        print(f"{verb} the issue approval job for {job['repository']}")
    else:
        verb = "Would install" if dry_run else "Installed"
        print(f"{verb} the issue approval job for {job['repository']} at {result['repo']}")
        print(f"Canonical backend: {result['backend_path']}")
    print(f"Service: {job['label']} ({result['service_manager']})")
    for _name, link in sorted(result["links"].items()):
        print(f"Link {link['destination']}: {link['result']}")
    print(f"Record: {job['record']}")
    if uninstalling and result["dependent_repositories"]:
        print(
            "Shared links kept for still-installed "
            + ", ".join(result["dependent_repositories"])
        )
    if dry_run:
        print("Dry run; nothing was changed.")
    elif not uninstalling:
        print("The job is loaded but stopped; start it from Kanban when ready.")


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        repo = repository_root(Path(args.repo))
        install_dir = selected_install_dir(repo, args.install_dir)
        if args.uninstall:
            result = uninstall(repo, install_dir, dry_run=args.dry_run)
        else:
            result = install(
                repo, install_dir, config_path=args.config, dry_run=args.dry_run
            )
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print_plan(result, uninstalling=args.uninstall)
        return 0
    # `ServiceManagerError` is the seam's own vocabulary for a fault no
    # injected runner can carry, and reaches here whenever it was raised past
    # the point `service_backend` translates the selection itself.
    except (
        InstallError,
        approve_issues_service.ServiceError,
        service_manager.ServiceManagerError,
        OSError,
    ) as exc:
        if args.json:
            print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        else:
            print(f"install_issue_approval.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
