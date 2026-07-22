#!/usr/bin/env python3

"""Safely install Kanban's user-scoped macOS PR drainer LaunchAgent.

The installer never starts the drainer. It only installs stable script links and
loads a stopped LaunchAgent definition for the selected repository. An optional
--config path is persisted and forwarded to the installed drain_prs.py runs.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


LABEL = "com.coghex.drain-prs"
DEFAULT_INSTALL_DIR = (
    Path.home() / "Library" / "Application Support" / "kanban" / "pr-drainer"
)
PLIST_PATH = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"


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
    ]
    missing = [str(item) for item in required if not item.is_file()]
    if missing:
        raise InstallError(
            "Repository does not contain the required drainer files: "
            + ", ".join(missing)
        )
    return root


def launch_target() -> str:
    return f"gui/{os.getuid()}/{LABEL}"


def launchd_job_running() -> bool:
    proc = run(["launchctl", "print", launch_target()], check=False)
    if proc.returncode != 0:
        return False
    output = proc.stdout + proc.stderr
    return bool(
        re.search(r"^\s*state = running\s*$", output, re.MULTILINE)
        or re.search(r"^\s*pid = [1-9][0-9]*\s*$", output, re.MULTILINE)
    )


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


def merge_installed_config_json(install_dir: Path, updates: dict[str, Any]) -> Path:
    """Merge `updates` into the shared config.json (ntfy_url, config_path)
    rather than overwriting it, so a later installer run that sets one key
    does not delete a different key persisted by an earlier run."""
    path = install_dir / "config.json"
    if os.path.lexists(path) and (path.is_symlink() or not path.is_file()):
        raise InstallError(f"Refusing unsafe notification config path: {path}")
    install_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    install_dir.chmod(0o700)
    existing: dict[str, Any] = {}
    if path.is_file():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            loaded = None
        if isinstance(loaded, dict):
            existing = loaded
    existing.update(updates)
    fd, temporary_name = tempfile.mkstemp(prefix=".config.", dir=install_dir)
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


def write_notification_config(install_dir: Path, ntfy_url: str) -> Path:
    return merge_installed_config_json(install_dir, {"ntfy_url": ntfy_url})


def write_installed_config_path(install_dir: Path, config_path: str) -> Path:
    """Persist the kanban config.toml path for drain_prs_service.py's runner
    to forward to drain_prs.py. Merges into the same config.json used for
    ntfy_url rather than overwriting it."""
    return merge_installed_config_json(install_dir, {"config_path": config_path})


def install(
    repo: Path,
    install_dir: Path,
    *,
    ntfy_url: str | None,
    config_path: str | None = None,
    dry_run: bool,
) -> dict[str, Any]:
    if sys.platform != "darwin":
        raise InstallError("The PR drainer LaunchAgent installer requires macOS.")
    if launchd_job_running() or repository_drainer_running(repo):
        raise InstallError(
            "Refusing to install while the PR drainer is running. Stop it first."
        )
    if ntfy_url and not ntfy_url.startswith(("https://", "http://")):
        raise InstallError("--ntfy-url must be an http:// or https:// endpoint.")
    resolved_config_path = (
        str(Path(config_path).expanduser().resolve()) if config_path else None
    )

    sources = {
        "drainer": repo / "tools" / "drain_prs.py",
        "controller": repo / "tools" / "drain_prs_service.py",
        "config_module": repo / "tools" / "kanban_config.py",
    }
    destinations = {
        "drainer": install_dir / "drain_prs.py",
        "controller": install_dir / "drain_prs_service.py",
        "config_module": install_dir / "kanban_config.py",
    }
    for destination in destinations.values():
        validate_symlink_destination(destination)
    if dry_run:
        return {
            "installed": False,
            "dry_run": True,
            "repo": str(repo),
            "links": {
                key: {"source": str(sources[key]), "destination": str(destination)}
                for key, destination in destinations.items()
            },
            "plist": str(PLIST_PATH),
            "config_path": resolved_config_path,
            "started": False,
        }

    link_results = {
        key: install_symlink(sources[key], destination)
        for key, destination in destinations.items()
    }
    notification_config = None
    if ntfy_url:
        notification_config = str(write_notification_config(install_dir, ntfy_url))
    if resolved_config_path:
        write_installed_config_path(install_dir, resolved_config_path)
    environment = os.environ.copy()
    environment["KANBAN_DRAINER_INSTALL_DIR"] = str(install_dir)
    environment.pop("KANBAN_DRAINER_NTFY_URL", None)
    proc = run(
        [
            sys.executable,
            str(destinations["controller"]),
            "--path",
            str(repo),
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
        "install_dir": str(install_dir),
        "links": link_results,
        "notifications_configured": notification_config is not None
        or (install_dir / "config.json").is_file(),
        "config_path": resolved_config_path,
        "controller": controller_result,
        "started": False,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Install Kanban's stopped, user-scoped PR drainer LaunchAgent."
    )
    parser.add_argument(
        "--repo",
        default=str(Path(__file__).resolve().parent.parent),
        help="Repository checkout to drain (default: checkout containing this script).",
    )
    parser.add_argument(
        "--install-dir",
        default=str(DEFAULT_INSTALL_DIR),
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
            print(f"Dry run passed for {repo}; no files or LaunchAgents were changed.")
        else:
            print(f"Installed PR drainer for {repo}")
            print(f"Controller: {install_dir / 'drain_prs_service.py'}")
            print("The LaunchAgent is loaded but stopped; start it from Kanban when ready.")
        return 0
    except (InstallError, OSError) as exc:
        if args.json:
            print(json.dumps({"error": str(exc)}, indent=2), file=sys.stderr)
        else:
            print(f"install_drainer.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
