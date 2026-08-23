#!/usr/bin/env python3

"""Install Kanban's canonical issue-review backend and migrate its legacy launcher.

This installer never starts a daemon. It only installs a stable
Kanban-managed link to the tracked `tools/approve_issues.py` backend, in the
same manner as `tools/install_drainer.py`, and optionally migrates the
pre-Kanban compatibility launcher at `~/work/approve-issues.py` to a symlink
that points at it. An optional --config path is persisted alongside the
installed backend for whatever launches it to forward.

Every successful install also records the absolute path of the backend it
linked, in a document whose own location --install-dir cannot move, so a
dashboard that never inherits KANBAN_ISSUE_REVIEW_INSTALL_DIR still finds an
installation made anywhere. Re-running this installer therefore repairs a
missing or stale discovery record in place, with no uninstall first.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

import kanban_config


# The backend and this installer share one spelling of the install location,
# imported from the only module installed beside the backend. This installer
# is the sole writer of the discovery record at that fixed path. Both are
# resolved per call, never frozen at import, so a redirected $HOME is honored.
default_install_dir = kanban_config.default_issue_review_install_dir
discovery_record_path = kanban_config.issue_review_record_path
selected_install_dir = kanban_config.issue_review_install_dir
DEFAULT_LEGACY_PATH = Path.home() / "work" / "approve-issues.py"

# Every tracked file this installer links into the install directory, keyed by
# the field its result document reports each under. `approve_issues.py` imports
# both companions at module scope, so a directory holding fewer than all three
# is a backend that fails at import rather than a partial installation that
# runs: `tools/setup_workflows.py` converges on the same set and
# `Kanban.Preflight` counts an install as ready only when every one of them is
# a marker-bearing managed link.
BACKEND_MODULES = {
    "kanban_link": "approve_issues.py",
    "config_module_link": "kanban_config.py",
    "models_module_link": "kanban_models.py",
}


class InstallError(RuntimeError):
    pass


def run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(args, text=True, capture_output=True)
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
    required = [root / "tools" / name for name in BACKEND_MODULES.values()]
    missing = [str(item) for item in required if not item.is_file()]
    if missing:
        raise InstallError(
            "Repository does not contain the required backend file(s): "
            + ", ".join(missing)
        )
    return root


MANAGED_ASSET_MARKER_PREFIX = "kanban-managed-asset:issue-review/"


def resolved_link_target(link: Path, target: Path) -> Path:
    """A symlink's target as this process can reach it.

    `os.readlink` returns the target exactly as written, and a relative one
    is resolved by the kernel against the *link's own directory* -- not
    against this process's working directory. Checking a raw relative
    target directly would report a perfectly working link as broken, and
    this installer replaces broken links, so that mistake would silently
    destroy someone else's working installation.
    """
    return target if target.is_absolute() else link.parent / target


def managed_asset_marker(name: str) -> str:
    """The identity marker the tracked asset `name` carries."""
    return MANAGED_ASSET_MARKER_PREFIX + name


def is_managed_asset(path: Path, name: str) -> bool:
    """Whether `path` resolves to this repository's own tracked asset.

    Verified by reading the identity marker the tracked file itself carries,
    not by where the path happens to point: a symlink to some unrelated
    `.../tools/approve_issues.py` matches every shape test one could write
    while being someone else's file, and only its content can tell the two
    apart. An unreadable target is never treated as recognized.
    """
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False
    return managed_asset_marker(name) in content


def is_prior_managed_backend_link(current_target: Path, source: Path) -> bool:
    """Whether an existing symlink may be re-pointed at `source`.

    Two cases qualify, and refusal protects content in both. A link already
    resolving to this same tracked asset is a duplicate install this
    installer owns. A link whose target no longer exists at all is what a
    moved or deleted checkout leaves behind: broken, holding nothing to
    preserve, and exactly the state a re-run has to converge. A link
    resolving to any other real file is someone else's installation, and is
    preserved and refused rather than silently replaced.
    """
    if current_target.name != source.name:
        return False
    if not os.path.exists(current_target):
        return True
    return is_managed_asset(current_target, source.name)


def plan_symlink(source: Path, destination: Path) -> str:
    """What install_symlink would do to point destination at source (already
    resolved to its intended literal target), without writing anything."""
    if os.path.lexists(destination):
        if not destination.is_symlink():
            return "refused"
        current_target = Path(os.readlink(destination))
        if current_target == source:
            return "unchanged"
        if is_prior_managed_backend_link(
            resolved_link_target(destination, current_target), source
        ):
            return "updated"
        return "refused"
    return "created"


def symlink_refusal_reason(destination: Path) -> str:
    """Why plan_symlink refused this destination, phrased as the recovery
    step. Read alongside a "refused" plan, so the two never disagree."""
    if not destination.is_symlink():
        return (
            f"{destination} already exists and is not a symlink. It is left untouched; "
            "move or remove it yourself, then re-run."
        )
    return (
        f"{destination} is a symlink to {os.readlink(destination)}, which does not "
        "resolve to Kanban's own tracked backend file. It is left untouched; remove it "
        "yourself, then re-run."
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
    source = source.resolve(strict=True)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    plan = plan_symlink(source, destination)
    if plan == "refused":
        raise InstallError(f"Refusing to replace an existing installation: {symlink_refusal_reason(destination)}")
    if plan == "created":
        destination.symlink_to(source)
    elif plan == "updated":
        replace_symlink_atomically(source, destination)
    return plan


def plan_legacy_launcher(
    legacy_path: Path, kanban_link: Path, *, allow_migration: bool
) -> dict[str, Any]:
    """What migrate_legacy_launcher would do, without writing anything.

    The legacy launcher always points at the Kanban-managed link itself
    (never resolved through it), so repository moves only ever require
    re-running the kanban_link half of `install`, not this one.
    """
    if os.path.lexists(legacy_path):
        if legacy_path.is_symlink():
            current_target = Path(os.readlink(legacy_path))
            if current_target == kanban_link:
                return {"path": str(legacy_path), "status": "unchanged", "backup_path": None}
            resolved_target = resolved_link_target(legacy_path, current_target)
            if not os.path.exists(resolved_target) or is_managed_asset(
                resolved_target, kanban_link.name
            ):
                # Already a launcher for this same tracked backend reached
                # through another install directory, or a link left broken
                # by one that went away: re-pointing it at the current
                # install location is this installer's own migration and
                # destroys nothing. See is_prior_managed_backend_link.
                return {"path": str(legacy_path), "status": "updated", "backup_path": None}
            return {
                "path": str(legacy_path),
                "status": "refused",
                "backup_path": None,
                "message": (
                    f"{legacy_path} is a symlink to {current_target}, which does not "
                    "resolve to Kanban's own tracked issue-review backend. It is left "
                    "untouched; remove it yourself if you want the compatibility "
                    "launcher installed here."
                ),
            }
        if allow_migration:
            backup_path = legacy_path.with_name(legacy_path.name + ".pre-kanban-backup")
            if os.path.lexists(backup_path):
                raise InstallError(
                    f"Refusing to migrate: a backup already exists at {backup_path}. "
                    "Resolve or remove it before retrying."
                )
            return {
                "path": str(legacy_path),
                "status": "migrated",
                "backup_path": str(backup_path),
            }
        return {
            "path": str(legacy_path),
            "status": "refused",
            "backup_path": None,
            "message": (
                "An ordinary file already exists at the legacy launcher path. "
                "Rerun with --migrate-legacy-launcher to back it up and replace "
                "it with a symlink."
            ),
        }
    return {"path": str(legacy_path), "status": "created", "backup_path": None}


def migrate_legacy_launcher(
    legacy_path: Path, kanban_link: Path, *, allow_migration: bool
) -> dict[str, Any]:
    """Point the compatibility launcher at the Kanban-managed link.

    A missing path, or a symlink that already resolves to this same tracked
    backend, is safe to (re)point without the opt-in, so reinstalls and
    repository moves stay idempotent. An ordinary pre-Kanban file is left
    untouched unless the caller explicitly opts in, in which case its
    content is preserved as a reported backup before the symlink replaces
    it. A symlink resolving to anything else is someone else's
    installation: it is preserved and refused outright, with or without the
    opt-in, since there is no content to back up and no way to tell what
    depends on it.
    """
    plan = plan_legacy_launcher(legacy_path, kanban_link, allow_migration=allow_migration)
    status = plan["status"]
    if status in ("refused", "unchanged"):
        return plan
    if status == "migrated":
        backup_path = Path(plan["backup_path"])
        legacy_path.rename(backup_path)
        legacy_path.symlink_to(kanban_link)
        return plan
    if status == "updated":
        replace_symlink_atomically(kanban_link, legacy_path)
        return plan
    # status == "created"
    legacy_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    legacy_path.symlink_to(kanban_link)
    return plan


def merge_json_document(path: Path, updates: dict[str, Any]) -> Path:
    """Merge `updates` into the private JSON object at `path` rather than
    overwriting it, so a writer that sets one key does not delete a key
    persisted by another. The discovery record and the --config reference are
    the same document whenever the backend is installed to its default
    directory, and either may be written without the other."""
    if os.path.lexists(path) and (path.is_symlink() or not path.is_file()):
        raise InstallError(f"Refusing unsafe private configuration path: {path}")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    existing = read_json_document(path) or {}
    existing.update(updates)
    fd, temporary_name = tempfile.mkstemp(prefix=".config.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(existing, handle, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        temporary.chmod(0o600)
        os.replace(temporary, path)
    finally:
        if os.path.lexists(temporary):
            temporary.unlink()
    return path


def read_json_document(path: Path) -> dict[str, Any] | None:
    """The JSON object at `path`, or None when it is absent, unreadable, or
    not an object. A document this installer cannot parse is one it will
    replace wholesale rather than merge into."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def stored_config_reference(install_dir: Path) -> str | None:
    """The kanban config.toml path a previous install persisted in
    `install_dir`. Read so that reinstalling a custom installation carries
    that reference into the discovery record instead of leaving it in a
    directory only an environment override would ever look at again --
    approve_issues.py resolves it (installed_config_reference) to pick up the
    configured workflow labels and repository overrides."""
    document = read_json_document(install_dir / "config.json")
    if document is None:
        return None
    configured = document.get("config_path")
    return configured if isinstance(configured, str) and configured else None


def write_config_reference(install_dir: Path, config_path: str) -> Path:
    """Persist the kanban config.toml path beside the installed backend.
    approve_issues.py itself reads this reference (installed_config_reference/
    resolve_effective_config_path) when invoked without an explicit --config,
    so any launcher (a launchd job, the review-issues skill, or a bare
    invocation) resolves the same configured labels/remote without needing
    to forward --config itself."""
    return merge_json_document(install_dir / "config.json", {"config_path": config_path})


def discovery_record_updates(install_dir: Path, config_path: str | None) -> dict[str, Any]:
    """What a successful install has to record. The backend path is absolute
    and points at the Kanban-managed link, never at the tracked source: the
    link is the stable name, and re-pointing it is how a moved checkout is
    repaired without touching this record at all.

    The --config reference rides along in the same document, so a custom
    installation's configured labels survive an install that does not repeat
    --config and are resolvable without the environment override that
    directory would otherwise require."""
    updates: dict[str, Any] = {"backend_path": str(install_dir / "approve_issues.py")}
    reference = config_path or stored_config_reference(install_dir)
    if reference:
        updates["config_path"] = reference
    return updates


def plan_discovery_record(install_dir: Path, config_path: str | None) -> str:
    """What write_discovery_record would do, without writing anything.

    "unchanged" only when every key it would write is already there with that
    value, so an installation predating the record -- or one whose backend has
    moved -- is reported as work to do rather than as converged."""
    record = discovery_record_path()
    updates = discovery_record_updates(install_dir, config_path)
    existing = read_json_document(record)
    if existing is None:
        return "created" if not record.is_file() else "updated"
    if all(existing.get(key) == value for key, value in updates.items()):
        return "unchanged"
    return "updated"


def write_discovery_record(install_dir: Path, config_path: str | None) -> Path:
    """Record where the backend this installer just linked actually lives, at
    the fixed path every consumer consults. Written from `install_dir` itself
    -- the same value the links were created under -- so the record cannot
    disagree with what was installed."""
    return merge_json_document(
        discovery_record_path(), discovery_record_updates(install_dir, config_path)
    )


def install(
    repo: Path,
    install_dir: Path,
    legacy_path: Path,
    *,
    migrate_legacy_launcher_flag: bool,
    config_path: str | None = None,
    dry_run: bool,
) -> dict[str, Any]:
    sources = {field: repo / "tools" / name for field, name in BACKEND_MODULES.items()}
    missing = [str(item) for item in sources.values() if not item.is_file()]
    if missing:
        raise InstallError(
            "Repository does not contain the required backend file(s): "
            + ", ".join(missing)
        )
    install_dir = install_dir.resolve()
    destinations = {
        field: install_dir / name for field, name in BACKEND_MODULES.items()
    }
    kanban_link = destinations["kanban_link"]
    resolved_config_path = (
        str(Path(config_path).expanduser().resolve()) if config_path else None
    )

    if dry_run:
        links = {
            field: {
                "source": str(sources[field]),
                "destination": str(destination),
                "result": plan_symlink(
                    sources[field].resolve(strict=True), destination
                ),
            }
            for field, destination in destinations.items()
        }
        return {
            "installed": False,
            "dry_run": True,
            "repo": str(repo),
            "install_dir": str(install_dir),
            **links,
            "legacy_launcher": plan_legacy_launcher(
                legacy_path, kanban_link, allow_migration=migrate_legacy_launcher_flag
            ),
            "record": {
                "path": str(discovery_record_path()),
                "backend_path": str(kanban_link),
                "result": plan_discovery_record(install_dir, resolved_config_path),
            },
            "config_path": resolved_config_path,
        }

    links = {
        field: {
            "source": str(sources[field]),
            "destination": str(destination),
            "result": install_symlink(sources[field], destination),
        }
        for field, destination in destinations.items()
    }
    legacy_result = migrate_legacy_launcher(
        legacy_path, kanban_link, allow_migration=migrate_legacy_launcher_flag
    )
    if resolved_config_path:
        write_config_reference(install_dir, resolved_config_path)
    # Written last, and only once both links exist: the record's whole job is
    # to name a backend that is really there, so publishing it ahead of the
    # links would advertise an installation a consumer could not run.
    record_path = write_discovery_record(install_dir, resolved_config_path)
    return {
        "installed": True,
        "repo": str(repo),
        "install_dir": str(install_dir),
        **links,
        "legacy_launcher": legacy_result,
        "record": {"path": str(record_path), "backend_path": str(kanban_link)},
        "config_path": resolved_config_path,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Install Kanban's canonical issue-review backend and, optionally, "
            "migrate its legacy ~/work/approve-issues.py launcher."
        )
    )
    parser.add_argument(
        "--repo",
        default=str(Path(__file__).resolve().parent.parent),
        help="Kanban checkout containing tools/approve_issues.py (default: this checkout).",
    )
    parser.add_argument(
        "--install-dir",
        default=str(selected_install_dir()),
        help="Stable per-user script-link directory.",
    )
    parser.add_argument(
        "--legacy-path",
        default=str(DEFAULT_LEGACY_PATH),
        help="Compatibility launcher path existing automation invokes.",
    )
    parser.add_argument(
        "--migrate-legacy-launcher",
        action="store_true",
        help=(
            "Back up and replace an ordinary pre-Kanban file at --legacy-path "
            "with a symlink. Without this, an ordinary file there is left untouched."
        ),
    )
    parser.add_argument(
        "--config",
        default=os.environ.get("KANBAN_ISSUE_REVIEW_CONFIG_PATH"),
        help="Optional kanban config.toml path persisted for the installed backend.",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="Validate and describe without writing."
    )
    parser.add_argument("--json", action="store_true", help="Print JSON output.")
    return parser.parse_args()


def print_plan(result: dict[str, Any], *, repo: Path) -> None:
    dry_run = result.get("dry_run", False)
    kanban_link = result["kanban_link"]
    legacy = result["legacy_launcher"]
    if dry_run:
        print(f"Dry run for {repo}; no files will be changed.")
    else:
        print(f"Installed the canonical issue-review backend for {repo}")
    print(f"Kanban-managed launcher {kanban_link['destination']}: {kanban_link['result']}")
    if legacy["status"] == "refused":
        print(
            f"Legacy launcher at {legacy['path']}: refused (an ordinary file is "
            "there; rerun with --migrate-legacy-launcher to replace it)"
        )
    else:
        print(f"Legacy launcher at {legacy['path']}: {legacy['status']}")
        if legacy.get("backup_path"):
            note = "would back up" if dry_run else "backed up"
            print(f"  ({note} the previous file to {legacy['backup_path']})")
    record = result["record"]
    if dry_run:
        print(f"Discovery record {record['path']}: {record['result']} ({record['backend_path']})")
    else:
        print(f"Discovery record {record['path']} names {record['backend_path']}")
    if result.get("config_path"):
        print(f"Config reference: {result['config_path']}")


def main() -> int:
    args = parse_args()
    try:
        repo = repository_root(Path(args.repo))
        install_dir = Path(args.install_dir).expanduser().resolve()
        legacy_path = Path(args.legacy_path).expanduser()
        result = install(
            repo,
            install_dir,
            legacy_path,
            migrate_legacy_launcher_flag=args.migrate_legacy_launcher,
            config_path=args.config,
            dry_run=args.dry_run,
        )
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        else:
            print_plan(result, repo=repo)
        return 0
    except (InstallError, OSError) as exc:
        if args.json:
            print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        else:
            print(f"install_issue_review.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
