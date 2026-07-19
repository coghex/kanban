#!/usr/bin/env python3

"""Install Kanban's canonical issue-review backend and migrate its legacy launcher.

This installer never starts a daemon. It only installs a stable
Kanban-managed link to the tracked `tools/approve_issues.py` backend, in the
same manner as `tools/install_drainer.py`, and optionally migrates the
pre-Kanban compatibility launcher at `~/work/approve-issues.py` to a symlink
that points at it.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


DEFAULT_INSTALL_DIR = (
    Path.home() / "Library" / "Application Support" / "kanban" / "issue-review"
)
DEFAULT_LEGACY_PATH = Path.home() / "work" / "approve-issues.py"


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
    required = root / "tools" / "approve_issues.py"
    if not required.is_file():
        raise InstallError(
            f"Repository does not contain the required backend file: {required}"
        )
    return root


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
        temporary = destination.with_name(f".{destination.name}.tmp")
        try:
            if os.path.lexists(temporary):
                temporary.unlink()
            temporary.symlink_to(source)
            os.replace(temporary, destination)
        finally:
            if os.path.lexists(temporary):
                temporary.unlink()
        return "updated"
    destination.symlink_to(source)
    return "created"


def migrate_legacy_launcher(
    legacy_path: Path, kanban_link: Path, *, allow_migration: bool
) -> dict[str, Any]:
    """Point the compatibility launcher at the Kanban-managed link.

    A missing path or an existing symlink is always safe to (re)point, so
    that case never needs the opt-in and stays idempotent across reinstalls
    and repository moves. An ordinary pre-Kanban file is left untouched
    unless the caller explicitly opts in, in which case its content is
    preserved as a reported backup before the symlink replaces it.
    """
    try:
        status = install_symlink(kanban_link, legacy_path)
        return {"path": str(legacy_path), "status": status, "backup_path": None}
    except InstallError:
        pass
    if not allow_migration:
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
    backup_path = legacy_path.with_name(legacy_path.name + ".pre-kanban-backup")
    if os.path.lexists(backup_path):
        raise InstallError(
            f"Refusing to migrate: a backup already exists at {backup_path}. "
            "Resolve or remove it before retrying."
        )
    legacy_path.rename(backup_path)
    legacy_path.symlink_to(kanban_link)
    return {
        "path": str(legacy_path),
        "status": "migrated",
        "backup_path": str(backup_path),
    }


def install(
    repo: Path,
    install_dir: Path,
    legacy_path: Path,
    *,
    migrate_legacy_launcher_flag: bool,
    dry_run: bool,
) -> dict[str, Any]:
    source = repo / "tools" / "approve_issues.py"
    if not source.is_file():
        raise InstallError(
            f"Repository does not contain the required backend file: {source}"
        )
    kanban_link = install_dir / "approve_issues.py"

    if dry_run:
        legacy_is_ordinary_file = os.path.lexists(legacy_path) and not legacy_path.is_symlink()
        return {
            "installed": False,
            "dry_run": True,
            "repo": str(repo),
            "install_dir": str(install_dir),
            "kanban_link": {"source": str(source), "destination": str(kanban_link)},
            "legacy_launcher": {
                "path": str(legacy_path),
                "would_migrate": legacy_is_ordinary_file and migrate_legacy_launcher_flag,
                "would_refuse": legacy_is_ordinary_file and not migrate_legacy_launcher_flag,
            },
        }

    kanban_result = install_symlink(source, kanban_link)
    legacy_result = migrate_legacy_launcher(
        legacy_path, kanban_link, allow_migration=migrate_legacy_launcher_flag
    )
    return {
        "installed": True,
        "repo": str(repo),
        "install_dir": str(install_dir),
        "kanban_link": {
            "source": str(source),
            "destination": str(kanban_link),
            "result": kanban_result,
        },
        "legacy_launcher": legacy_result,
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
        default=os.environ.get("KANBAN_ISSUE_REVIEW_INSTALL_DIR", str(DEFAULT_INSTALL_DIR)),
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
        "--dry-run", action="store_true", help="Validate and describe without writing."
    )
    parser.add_argument("--json", action="store_true", help="Print JSON output.")
    return parser.parse_args()


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
            dry_run=args.dry_run,
        )
        if args.json:
            print(json.dumps(result, indent=2, sort_keys=True))
        elif result.get("dry_run"):
            print(f"Dry run passed for {repo}; no files were changed.")
        else:
            print(f"Installed the canonical issue-review backend for {repo}")
            print(f"Launcher: {install_dir / 'approve_issues.py'}")
            legacy = result["legacy_launcher"]
            if legacy["status"] == "refused":
                print(
                    f"Left the existing file at {legacy['path']} untouched; "
                    "rerun with --migrate-legacy-launcher to replace it."
                )
            else:
                print(f"Legacy launcher at {legacy['path']}: {legacy['status']}")
                if legacy.get("backup_path"):
                    print(f"Backed up the previous file to {legacy['backup_path']}")
        return 0
    except (InstallError, OSError) as exc:
        if args.json:
            print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        else:
            print(f"install_issue_review.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
