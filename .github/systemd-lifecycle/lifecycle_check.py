#!/usr/bin/env python3

"""Drives the PR drainer's whole lifecycle against a real systemd user session.

`docs/linux_portability_design.md` decision D-1 makes this the evidence for the
Linux claim, which is why it asserts on durable state rather than on generated
files: install, start, status, stop, and uninstall each have to reach the state
they claim, in the user manager and in the discovery record both. A check that
only compared the unit file it had just written would prove the writer and
nothing else.

The sequence is install → start → status → stop → uninstall. `start` is what
exercises the backend's `kick`, because the controller installs and then kicks;
running `kick` on its own would test a path no operator takes.

Only `gh` and the provider executables are faked. Everything else — git,
systemd, the controller, the drainer, the installer — is the real thing running
against a real user manager, because each of those is exactly what this exists
to establish.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
IDENTITY = "acme/widgets"
REMOTE_URL = "https://github.com/acme/widgets.git"
# Long enough for a cold interpreter start plus the controller's own
# stabilization window, short enough that a wedged step fails the job rather
# than hanging it out to the workflow timeout.
SETTLE_SECONDS = 45

# A `gh` that answers the two shapes the polling drainer asks for and nothing
# else. Deliberately not scriptable: this check is about the service manager,
# and an empty queue is the only GitHub state it needs.
FAKE_GH = """#!/usr/bin/env python3
import json, sys

argv = sys.argv[1:]
if "list" in argv:
    print(json.dumps([]))
elif "view" in argv:
    print(json.dumps({"defaultBranchRef": {"name": "master"}}))
elif argv[:1] == ["api"]:
    print(json.dumps({}))
else:
    print(json.dumps({}))
sys.exit(0)
"""

FAKE_PROVIDER = """#!/usr/bin/env python3
import sys
sys.exit(0)
"""


class CheckFailed(RuntimeError):
    pass


def run(command, **kwargs):
    return subprocess.run(command, text=True, capture_output=True, **kwargs)


def require(condition, message):
    if not condition:
        raise CheckFailed(message)


def step(name):
    print(f"== {name}", flush=True)


def systemd_property(unit, name):
    proc = run(["systemctl", "--user", "show", unit, "--property", name, "--value"])
    return (proc.stdout or "").strip() if proc.returncode == 0 else ""


def controller(install_dir, checkout, command):
    """One controller invocation, as JSON, exactly as Kanban makes it."""
    proc = run(
        [
            sys.executable,
            str(install_dir / "drain_prs_service.py"),
            "--path",
            str(checkout),
            "--repo",
            IDENTITY,
            "--json",
            command,
        ]
    )
    print(proc.stdout, proc.stderr, flush=True)
    require(
        proc.returncode == 0,
        f"controller {command} exited {proc.returncode}: {proc.stderr or proc.stdout}",
    )
    return json.loads(proc.stdout)


def await_state(predicate, description):
    deadline = time.monotonic() + SETTLE_SECONDS
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(0.5)
    raise CheckFailed(f"timed out waiting for {description}; last saw {last!r}")


def install_fake_executables(home):
    """The fakes go where the installed unit's own PATH looks first.

    `drain_prs_service.service_definition` puts `~/.local/bin` at the head of
    the PATH it writes into the unit, so a fake placed there is what the
    *managed* drainer resolves — not merely what this process would.
    """
    bin_dir = home / ".local" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    for name, body in (("gh", FAKE_GH), ("codex", FAKE_PROVIDER), ("claude", FAKE_PROVIDER)):
        path = bin_dir / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)
    os.environ["PATH"] = f"{bin_dir}:{os.environ.get('PATH', '')}"
    return bin_dir


def make_checkout(root):
    """A real git checkout of a repository that resolves to `acme/widgets`.

    No network and no GitHub: the remote is a URL and two local refs, which is
    all the identity resolution and the default-branch gate actually read.
    """
    checkout = root / "widgets"
    (checkout / "tools").mkdir(parents=True)
    # Every module `install_drainer.repository_root` requires of a checkout,
    # and therefore every module the installed controller resolves from beside
    # itself. A name added there without being added here fails the install
    # step rather than the lifecycle this check is about.
    for name in (
        "drain_prs.py",
        "drain_prs_service.py",
        "kanban_config.py",
        "kanban_models.py",
        "service_manager.py",
    ):
        shutil.copy2(REPO_ROOT / "tools" / name, checkout / "tools" / name)
    (checkout / "README.md").write_text("fixture\n", encoding="utf-8")
    for command in (
        ["git", "init", "--initial-branch", "master"],
        ["git", "config", "user.email", "lifecycle@example.test"],
        ["git", "config", "user.name", "Lifecycle Check"],
        ["git", "add", "-A"],
        ["git", "commit", "-m", "fixture"],
        ["git", "remote", "add", "origin", REMOTE_URL],
    ):
        proc = run(command, cwd=checkout)
        require(proc.returncode == 0, f"{command} failed: {proc.stderr}")
    head = run(["git", "rev-parse", "HEAD"], cwd=checkout).stdout.strip()
    for command in (
        ["git", "update-ref", "refs/remotes/origin/master", head],
        ["git", "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master"],
    ):
        proc = run(command, cwd=checkout)
        require(proc.returncode == 0, f"{command} failed: {proc.stderr}")
    return checkout


def record_entry(record_path):
    if not record_path.is_file():
        return None
    document = json.loads(record_path.read_text(encoding="utf-8"))
    return document.get("repositories", {}).get(IDENTITY)


def check(home, workspace):
    install_fake_executables(home)
    checkout = make_checkout(workspace)

    sys.path.insert(0, str(REPO_ROOT / "tools"))
    import drain_prs_service

    record_path = drain_prs_service.DISCOVERY_RECORD_PATH

    # Deliberately no --install-dir. The default is what a real install uses,
    # and it is also the only arrangement in which every later invocation
    # resolves the same installation without this check having to thread the
    # installer's own environment into calls Kanban makes without it.
    step("install")
    proc = run(
        [
            sys.executable,
            str(REPO_ROOT / "tools" / "install_drainer.py"),
            "--repo",
            str(checkout),
            "--json",
        ]
    )
    print(proc.stdout, proc.stderr, flush=True)
    require(proc.returncode == 0, f"install failed: {proc.stderr or proc.stdout}")
    installed = json.loads(proc.stdout)
    install_dir = Path(installed["install_dir"])
    unit = installed["label"]
    require(unit.endswith(".service"), f"installed job is not a unit: {unit}")

    entry = record_entry(record_path)
    require(entry is not None, f"no discovery entry for {IDENTITY} at {record_path}")
    require(entry["backend"] == "systemd", f"entry names backend {entry['backend']!r}")
    require(entry["systemd_unit"] == unit, f"entry names unit {entry['systemd_unit']!r}")
    unit_path = Path(entry["unit_path"])
    require(unit_path.is_file(), f"no unit file at {unit_path}")
    require(
        systemd_property(unit, "LoadState") == "loaded",
        f"{unit} is not loaded after install",
    )
    # Loaded and stopped: the installer never starts a drainer, and the unit it
    # writes has no [Install] section, so nothing else will either.
    require(
        systemd_property(unit, "ActiveState") == "inactive",
        f"{unit} is active immediately after install",
    )

    step("start")
    started = controller(install_dir, checkout, "start")
    require(started["started"], f"start reported {started}")
    require(
        started["service_manager"] == "systemd",
        f"start reported manager {started['service_manager']!r}",
    )
    await_state(
        lambda: systemd_property(unit, "ActiveState") == "active",
        f"{unit} to be active",
    )
    main_pid = systemd_property(unit, "MainPID")
    require(main_pid.isdigit() and int(main_pid) > 0, f"{unit} has MainPID {main_pid!r}")

    step("status")
    status = controller(install_dir, checkout, "status")
    require(status["state"] == "running", f"status reported {status['state']!r}")
    require(status["launchd_loaded"] is True, "status reports the job as not loaded")
    require(status["service_manager"] == "systemd", "status names the wrong manager")
    require(status["repository"] == IDENTITY, f"status names {status['repository']!r}")
    # A managed drainer, not merely a live unit: the runner's own child is the
    # process that would do the merging.
    drainer_pid = status["drainer_pid"]
    require(isinstance(drainer_pid, int) and drainer_pid > 0, "no live drainer child")

    step("stop")
    stopped = controller(install_dir, checkout, "stop")
    require(stopped["stopped"], f"stop reported {stopped}")
    require(stopped["state"] == "stopped", f"stop settled at {stopped['state']!r}")
    settled = await_state(
        lambda: systemd_property(unit, "ActiveState") in {"inactive", "failed"}
        and systemd_property(unit, "ActiveState"),
        f"{unit} to settle",
    )
    require(settled == "inactive", f"{unit} settled as {settled!r} rather than inactive")

    step("uninstall")
    removed = controller(install_dir, checkout, "uninstall")
    require(removed["uninstalled"], f"uninstall reported {removed}")
    require(removed["unit_removed"], "uninstall did not remove the unit file")
    require(not unit_path.exists(), f"unit file survives at {unit_path}")
    require(
        systemd_property(unit, "LoadState") == "not-found",
        f"{unit} is still known to the user manager",
    )
    require(
        record_entry(record_path) is None,
        f"discovery entry for {IDENTITY} survives in {record_path}",
    )

    print("systemd drainer lifecycle check passed", flush=True)


def main():
    home = Path(os.environ.get("HOME", "")).expanduser()
    require(home.is_dir(), f"HOME does not name a directory: {home!r}")
    workspace = home / "lifecycle-check"
    shutil.rmtree(workspace, ignore_errors=True)
    workspace.mkdir(parents=True)
    try:
        check(home, workspace)
    except CheckFailed as failure:
        print(f"systemd drainer lifecycle check failed: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
