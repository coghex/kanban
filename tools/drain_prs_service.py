#!/usr/bin/env python3

from __future__ import annotations

import argparse
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
from pathlib import Path
from typing import Any


LABEL = "com.coghex.drain-prs"
HOME = Path.home()
INSTALL_DIR = Path(
    os.environ.get(
        "KANBAN_DRAINER_INSTALL_DIR",
        HOME / "Library" / "Application Support" / "kanban" / "pr-drainer",
    )
).expanduser()
CONTROLLER_PATH = INSTALL_DIR / "drain_prs_service.py"
DRAINER_PATH = INSTALL_DIR / "drain_prs.py"
CONFIG_PATH = INSTALL_DIR / "config.json"
LOG_DIR = HOME / "Library" / "Logs" / "kanban" / "pr-drainer"
RUNTIME_DIR = INSTALL_DIR / "runtime"
INCIDENT_DIR = RUNTIME_DIR / "incidents"
STATUS_PATH = RUNTIME_DIR / "status.json"
SERVICE_LOG_PATH = LOG_DIR / "service.log"
SERVICE_OUT_PATH = LOG_DIR / "service.out"
SERVICE_ERR_PATH = LOG_DIR / "service.err"
PLIST_PATH = HOME / "Library" / "LaunchAgents" / f"{LABEL}.plist"


def configured_ntfy_url() -> str | None:
    environment_url = os.environ.get("KANBAN_DRAINER_NTFY_URL")
    if environment_url:
        return environment_url
    try:
        value = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    configured = value.get("ntfy_url") if isinstance(value, dict) else None
    return configured if isinstance(configured, str) and configured else None


NTFY_URL = configured_ntfy_url()
INTERVAL_SECONDS = 60
START_TIMEOUT_SECONDS = 12
START_STABILITY_SECONDS = 1.0
STOP_TIMEOUT_SECONDS = 20
NTFY_ATTEMPTS = 3


class ServiceError(RuntimeError):
    pass


def utc_stamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def local_stamp() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")


def ensure_dirs() -> None:
    for path in (INSTALL_DIR, RUNTIME_DIR, INCIDENT_DIR, LOG_DIR):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.chmod(0o700)
    PLIST_PATH.parent.mkdir(parents=True, exist_ok=True)


def service_log(message: str) -> None:
    ensure_dirs()
    line = f"[{local_stamp()}] {message}"
    with SERVICE_LOG_PATH.open("a", encoding="utf-8") as handle:
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


def launch_target() -> str:
    return f"{launch_domain()}/{LABEL}"


def run_command(
    args: list[str], *, check: bool = True
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(args, text=True, capture_output=True)
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise ServiceError(f"Command failed: {' '.join(args)}\n{detail}")
    return proc


def launchd_loaded() -> bool:
    return run_command(["launchctl", "print", launch_target()], check=False).returncode == 0


def lock_pid(repo_path: Path) -> int | None:
    path = repo_path / ".git" / "drain_prs.lock"
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except (FileNotFoundError, OSError, ValueError):
        return None


def working_tree_status(repo_path: Path) -> str:
    proc = run_command(
        ["git", "-C", str(repo_path), "status", "--porcelain=v1", "--untracked-files=all"],
        check=False,
    )
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or f"exit code {proc.returncode}").strip()
        raise ServiceError(f"Could not inspect repository status: {detail}")
    return (proc.stdout or "").strip()


def require_default_branch(repo_path: Path) -> None:
    current = run_command(
        ["git", "-C", str(repo_path), "branch", "--show-current"],
        check=False,
    )
    if current.returncode != 0:
        detail = (current.stderr or current.stdout or f"exit code {current.returncode}").strip()
        raise ServiceError(f"Could not inspect repository branch: {detail}")
    current_branch = (current.stdout or "").strip()

    default = run_command(
        ["git", "-C", str(repo_path), "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
        check=False,
    )
    if default.returncode != 0:
        detail = (default.stderr or default.stdout or f"exit code {default.returncode}").strip()
        raise ServiceError(
            "Could not determine the repository default branch from origin/HEAD: "
            + detail
        )
    default_ref = (default.stdout or "").strip()
    if not default_ref.startswith("origin/") or len(default_ref) == len("origin/"):
        raise ServiceError(
            "Could not determine the repository default branch from origin/HEAD: "
            + default_ref
        )
    default_branch = default_ref.removeprefix("origin/")

    if current_branch != default_branch:
        raise ServiceError(
            f"Refusing to start PR drainer: repository is on branch {current_branch!r}, "
            f"not default branch {default_branch!r}."
        )


def incident_files(
    *, repo_path: Path | None = None, open_only: bool = False
) -> list[Path]:
    if not INCIDENT_DIR.exists():
        return []
    paths = sorted(INCIDENT_DIR.glob("incident-*.json"), reverse=True)
    selected: list[Path] = []
    for path in paths:
        incident = read_json(path) or {}
        if repo_path is not None and incident.get("repo") != str(repo_path):
            continue
        if open_only and incident.get("status") != "open":
            continue
        selected.append(path)
    return selected


def latest_log_path() -> Path | None:
    paths = sorted(LOG_DIR.glob("20??-??-??.log"), reverse=True)
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


def status_snapshot(repo_path: Path) -> dict[str, Any]:
    stored = read_json(STATUS_PATH) or {}
    active_repo = stored_repo_path(stored)
    runner_pid = stored.get("runner_pid")
    child_pid = stored.get("drainer_pid")
    runner_alive = pid_alive(runner_pid if isinstance(runner_pid, int) else None)
    child_alive = pid_alive(child_pid if isinstance(child_pid, int) else None)
    locked_pid = lock_pid(repo_path)
    locked_alive = pid_alive(locked_pid)

    if runner_alive and active_repo is not None and active_repo != repo_path:
        state = "foreign"
    elif runner_alive and child_alive:
        state = "running"
    elif runner_alive:
        state = "starting"
    elif locked_alive:
        state = "external"
    else:
        state = "dirty" if working_tree_status(repo_path) else "stopped"

    open_incidents = incident_files(repo_path=repo_path, open_only=True)
    latest_incident = read_json(open_incidents[0]) if open_incidents else None
    log_path = latest_log_path()
    log_tail = tail_lines(log_path, 1)
    return {
        "state": state,
        "launchd_loaded": launchd_loaded(),
        "runner_pid": runner_pid if runner_alive else None,
        "drainer_pid": child_pid if child_alive else (locked_pid if locked_alive else None),
        "started_at": stored.get("started_at") if runner_alive else None,
        "repo": str(repo_path),
        "active_repo": str(active_repo) if runner_alive and active_repo else None,
        "drainer": str(DRAINER_PATH),
        "log": str(log_path) if log_path else None,
        "last_activity": log_tail[0] if log_tail else None,
        "open_incident": latest_incident,
    }


def render_plist(repo_path: Path) -> bytes:
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
        "Label": LABEL,
        "ProgramArguments": [
            python,
            str(CONTROLLER_PATH),
            "--path",
            str(repo_path),
            "run",
        ],
        "WorkingDirectory": str(repo_path),
        "RunAtLoad": False,
        "KeepAlive": False,
        "ProcessType": "Background",
        "ThrottleInterval": 10,
        "StandardOutPath": str(SERVICE_OUT_PATH),
        "StandardErrorPath": str(SERVICE_ERR_PATH),
        "EnvironmentVariables": environment,
    }
    return plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False)


def install_job(repo_path: Path) -> dict[str, Any]:
    ensure_dirs()
    snapshot = status_snapshot(repo_path)
    if snapshot["state"] in {"running", "starting", "external", "foreign"}:
        raise ServiceError("Stop the running drainer before installing its launchd job.")

    payload = render_plist(repo_path)
    fd, tmp_name = tempfile.mkstemp(prefix=PLIST_PATH.name, dir=PLIST_PATH.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_name, 0o644)
        os.replace(tmp_name, PLIST_PATH)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)

    if launchd_loaded():
        run_command(["launchctl", "bootout", launch_target()])
    run_command(["launchctl", "bootstrap", launch_domain(), str(PLIST_PATH)])
    return {"installed": True, "plist": str(PLIST_PATH), "target": launch_target()}


def start_service(repo_path: Path) -> dict[str, Any]:
    dirty_status = working_tree_status(repo_path)
    if dirty_status:
        raise ServiceError(
            "Refusing to start PR drainer: repository has uncommitted changes. "
            "Commit, stash, or discard them first.\n"
            + dirty_status
        )
    require_default_branch(repo_path)
    ensure_dirs()
    snapshot = status_snapshot(repo_path)
    if snapshot["state"] in {"running", "starting"}:
        return {"started": False, "message": "PR drainer is already running", **snapshot}
    if snapshot["state"] == "external":
        raise ServiceError(
            f"A drainer outside launchd is already running as PID {snapshot['drainer_pid']}."
        )
    if snapshot["state"] == "foreign":
        raise ServiceError(
            "The managed drainer is already running for "
            f"{snapshot['active_repo']}; stop it before starting {repo_path}."
        )
    install_job(repo_path)

    previous_incidents = {
        path.name for path in incident_files(repo_path=repo_path, open_only=True)
    }
    run_command(["launchctl", "kickstart", launch_target()])
    deadline = time.monotonic() + START_TIMEOUT_SECONDS
    running_since: float | None = None
    while time.monotonic() < deadline:
        time.sleep(0.25)
        snapshot = status_snapshot(repo_path)
        if snapshot["state"] == "running":
            if running_since is None:
                running_since = time.monotonic()
            elif time.monotonic() - running_since >= START_STABILITY_SECONDS:
                return {"started": True, **snapshot}
        else:
            running_since = None
        new_incidents = [
            path
            for path in incident_files(repo_path=repo_path, open_only=True)
            if path.name not in previous_incidents
        ]
        if new_incidents:
            incident = read_json(new_incidents[0]) or {}
            raise ServiceError(
                "PR drainer exited during startup: "
                + str(incident.get("summary") or incident.get("incident_id"))
            )
    raise ServiceError("Timed out waiting for the PR drainer to start.")


def stop_service(repo_path: Path) -> dict[str, Any]:
    snapshot = status_snapshot(repo_path)
    state = snapshot["state"]
    if state == "stopped":
        return {"stopped": False, "message": "PR drainer is already stopped", **snapshot}
    if state == "external":
        pid = snapshot["drainer_pid"]
        if not isinstance(pid, int):
            raise ServiceError("Could not identify the external drainer PID.")
        os.kill(pid, signal.SIGINT)
    elif state == "foreign":
        raise ServiceError(
            "Refusing to stop the managed drainer for another repository: "
            f"{snapshot['active_repo']}"
        )
    else:
        run_command(["launchctl", "kill", "SIGTERM", launch_target()])

    deadline = time.monotonic() + STOP_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        time.sleep(0.25)
        current = status_snapshot(repo_path)
        if current["state"] == "stopped":
            cleared_incidents = resolve_open_incidents(
                repo_path,
                "Cleared when the PR drainer was intentionally stopped.",
            )
            return {
                "stopped": True,
                "cleared_incidents": len(cleared_incidents),
                **status_snapshot(repo_path),
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
    repo_path: Path,
    exit_code: int | None,
    command: list[str],
    exception_text: str | None = None,
) -> dict[str, Any]:
    ensure_dirs()
    incident_id = time.strftime("incident-%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{os.getpid()}"
    log_path = latest_log_path()
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
        "status": "open",
        "occurred_at": utc_stamp(),
        "summary": summary,
        "exit_code": exit_code,
        "last_pr": last_pr,
        "last_activity": last_line,
        "command": command,
        "repo": str(repo_path),
        "drainer": str(DRAINER_PATH),
        "drain_state": str(repo_path / ".git" / "drain_prs_state.json"),
        "drainer_log": str(log_path) if log_path else None,
        "service_log": str(SERVICE_LOG_PATH),
        "service_stdout": str(SERVICE_OUT_PATH),
        "service_stderr": str(SERVICE_ERR_PATH),
        "exception": exception_text,
        "log_tail": log_tail,
        "notification": {"delivered": False, "pending": True},
    }
    incident_path = INCIDENT_DIR / f"{incident_id}.json"
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
        service_log(str(exc))
    atomic_write_json(incident_path, incident)
    return incident


def acknowledge_incident(
    repo_path: Path, incident_id: str | None, note: str | None
) -> dict[str, Any]:
    paths = incident_files(repo_path=repo_path, open_only=True)
    if incident_id:
        if not re.fullmatch(r"incident-[A-Za-z0-9TZ-]+", incident_id):
            raise ServiceError(f"Invalid incident ID: {incident_id}")
        paths = [INCIDENT_DIR / f"{incident_id}.json"]
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


def resolve_open_incidents(repo_path: Path, note: str) -> list[Path]:
    resolved: list[Path] = []
    for path in incident_files(repo_path=repo_path, open_only=True):
        incident = read_json(path)
        if incident is None:
            continue
        incident["status"] = "resolved"
        incident["resolved_at"] = utc_stamp()
        incident["resolution"] = note
        atomic_write_json(path, incident)
        resolved.append(path)
    return resolved


def run_service(repo_path: Path) -> int:
    try:
        require_default_branch(repo_path)
    except ServiceError as exc:
        service_log(f"PR drainer did not start: {exc}")
        return 0
    ensure_dirs()
    command = [
        str(DRAINER_PATH),
        "--path",
        str(repo_path),
        "--interval",
        str(INTERVAL_SECONDS),
        "--log-dir",
        str(LOG_DIR),
    ]
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
    service_log(f"Starting PR drainer: {' '.join(command)}")
    try:
        child_env = os.environ.copy()
        child_env["DRAIN_PRS_MANAGED"] = "1"
        child = subprocess.Popen(
            command,
            cwd=str(repo_path),
            text=True,
            start_new_session=True,
            env=child_env,
        )
        atomic_write_json(
            STATUS_PATH,
            {
                "state": "running",
                "runner_pid": os.getpid(),
                "drainer_pid": child.pid,
                "started_at": utc_stamp(),
                "command": command,
                "repo": str(repo_path),
            },
        )
        exit_code = child.wait()
    except BaseException:
        if stop_requested:
            return 0
        exception_text = traceback.format_exc()
        service_log("PR drainer runner failed before a normal child exit")
        write_incident(
            repo_path=repo_path,
            exit_code=None,
            command=command,
            exception_text=exception_text,
        )
        return 1
    finally:
        try:
            STATUS_PATH.unlink()
        except FileNotFoundError:
            pass

    if stop_requested:
        service_log("PR drainer stopped intentionally; no incident notification sent")
        return 0

    incident = write_incident(
        repo_path=repo_path, exit_code=exit_code, command=command
    )
    service_log(f"PR drainer stopped unexpectedly; wrote {incident['path']}")
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
    parser = argparse.ArgumentParser(description="Control the launchd-managed PR drainer.")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON.")
    parser.add_argument(
        "--path",
        default=".",
        help="Repository path controlled by this invocation (default: current directory).",
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
        if args.command == "run":
            return run_service(repo_path)
        if args.command == "install":
            value = install_job(repo_path)
        elif args.command == "start":
            value = start_service(repo_path)
        elif args.command == "stop":
            value = stop_service(repo_path)
        elif args.command == "status":
            value = status_snapshot(repo_path)
        elif args.command == "logs":
            path = latest_log_path()
            value = {"path": str(path) if path else None, "lines": tail_lines(path, args.lines)}
        elif args.command == "incident":
            if args.incident_id:
                path = INCIDENT_DIR / f"{args.incident_id}.json"
                value = read_json(path)
            else:
                paths = incident_files(repo_path=repo_path, open_only=True)
                value = read_json(paths[0]) if paths else None
            if value is None:
                raise ServiceError("No matching open incident was found.")
        elif args.command == "ack":
            value = acknowledge_incident(repo_path, args.incident_id, args.note)
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
