#!/usr/bin/env python3

"""Proves a stopped or killed mission runner leaves its missions' workers alive.

A mission step hands agent work to a detached worker leading a session of its
own, and the mission runner design (D-2, D-15, D-17) promises that worker
outlives the runner. A new session leaves the process group but not the unit's
cgroup, so on systemd only the unit's kill mode can keep that promise: under
`KillMode=mixed` every process the cgroup still holds is SIGKILLed once the
wrapper is gone, workers included. This check is the Linux evidence that the
mission runner's unit does not do that.

It drives the installed mission runner under a real user manager, with a
`kanban` stand-in whose pass has the real one's shape — the wrapper runs a
pass in a new session, the pass runs a mission child, the mission child starts
a worker in a new session of its own, and the worker starts an agent. Both the
worker and the agent are established as members of the runner unit's cgroup
before anything is stopped, and then have to be the same live, non-zombie
processes once systemd has finished with the wrapper's exit, in two cases:

- `systemctl --user stop` of the unit;
- the wrapper SIGKILLed, which is what a crash looks like to systemd.

It starts by rewriting the installed unit as a release before RUN-9 wrote it,
with `KillMode=mixed`, so the start that follows is also the upgrade path: the
unit the survival cases run under is the one that start refreshed.

Only `kanban` is faked. systemd, git, the installer, and the mission runner
controller are the real ones, because each is part of what this establishes.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
IDENTITY = "acme/widgets"
REMOTE_URL = "https://github.com/acme/widgets.git"
# Long enough for a cold interpreter start plus the controller's own start
# confirmation, short enough that a wedged step fails the job rather than
# hanging it out to the workflow timeout.
SETTLE_SECONDS = 45
# How long survivors are watched after systemd reports the unit settled. The
# kill `mixed` performs is part of settling the unit, so this is margin rather
# than the thing being waited for.
SURVIVAL_SECONDS = 3

# Stands in for `kanban --mission-scheduler`. When the check has left a
# request, the pass runs a mission child in its own process group, which starts
# a worker leading a new session; the worker starts an agent, records both
# PIDs, and waits on the agent for as long as it lives. The mission child exits
# once the worker has registered, and the pass then writes a well-formed report
# of a pass that advanced nothing, so the runner goes on to wait out its
# interval rather than failing or spinning.
FAKE_KANBAN = r'''#!/usr/bin/env python3
import datetime
import json
import os
import subprocess
import sys
import time

WORKSPACE = {workspace!r}
REPORT = {report!r}

WORKER = """
import json, os, subprocess, sys
agent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(3600)"])
path = sys.argv[1]
with open(path + ".tmp", "w", encoding="utf-8") as handle:
    json.dump({{"worker": os.getpid(), "agent": agent.pid}}, handle)
os.replace(path + ".tmp", path)
agent.wait()
"""

MISSION_CHILD = """
import os, subprocess, sys, time
subprocess.Popen([sys.executable, "-c", sys.argv[1], sys.argv[2]], start_new_session=True)
deadline = time.monotonic() + 30
while not os.path.exists(sys.argv[2]) and time.monotonic() < deadline:
    time.sleep(0.05)
"""


def log(entry):
    with open(os.path.join(WORKSPACE, "passes.jsonl"), "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry) + "\n")


def main():
    started = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    log({{"event": "started", "pid": os.getpid(), "argv": sys.argv[1:]}})
    for name in sorted(os.listdir(WORKSPACE)):
        if not name.startswith("request-"):
            continue
        tag = name[len("request-"):]
        claimed = os.path.join(WORKSPACE, "claimed-" + tag)
        os.replace(os.path.join(WORKSPACE, name), claimed)
        marker = os.path.join(WORKSPACE, "worker-" + tag + ".json")
        subprocess.run([sys.executable, "-c", MISSION_CHILD, WORKER, marker], check=True)
    finished = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sys.stdout.write(json.dumps({{**REPORT, "started_at": started, "finished_at": finished}}))
    sys.stdout.flush()
    log({{"event": "finished", "pid": os.getpid()}})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'''


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


def await_state(predicate, description):
    deadline = time.monotonic() + SETTLE_SECONDS
    last = None
    while time.monotonic() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(0.25)
    raise CheckFailed(f"timed out waiting for {description}; last saw {last!r}")


def controller(install_dir, checkout, command):
    """One controller invocation, as JSON, exactly as Kanban makes it."""
    proc = run(
        [
            sys.executable,
            str(install_dir / "mission_runner_service.py"),
            command,
            "--path",
            str(checkout),
            "--repo",
            IDENTITY,
            "--json",
        ]
    )
    print(proc.stdout, proc.stderr, flush=True)
    require(
        proc.returncode == 0,
        f"controller {command} exited {proc.returncode}: {proc.stderr or proc.stdout}",
    )
    return json.loads(proc.stdout)


def pass_report():
    """A pass that advanced nothing, in the shape the controller accepts.

    Its schema and version are the controller's own mirrors of the Haskell
    declaration, read rather than restated, so this stand-in cannot drift from
    what the installed controller checks.
    """
    sys.path.insert(0, str(REPO_ROOT / "tools"))
    import mission_runner_service

    return {
        "schema": mission_runner_service.PASS_SCHEMA,
        "version": mission_runner_service.PASS_VERSION,
        "repository": IDENTITY,
        "termination": "completed",
        "exit_code": 0,
        "admitted": [],
        "attention": [],
        "agents": {"live": 0, "ceiling": 2},
        "detail": "nothing to do",
    }


def install_fake_kanban(home, workspace):
    """Where the installed unit's own PATH looks first.

    `mission_runner_service.service_definition` puts `~/.local/bin` at the head
    of the PATH it writes into the unit, so a stand-in placed there is what the
    *managed* runner's passes resolve.
    """
    bin_dir = home / ".local" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    path = bin_dir / "kanban"
    path.write_text(
        FAKE_KANBAN.format(workspace=str(workspace), report=pass_report()),
        encoding="utf-8",
    )
    path.chmod(0o755)


def make_checkout(root):
    """A real git checkout of a repository that resolves to `acme/widgets`.

    The installer's modules come from this repository's own tree, which is its
    default asset root, so the target needs nothing but an identity.
    """
    checkout = root / "widgets"
    checkout.mkdir(parents=True)
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
    return checkout


def proc_stat(pid):
    """(state, ppid, session, start time) from /proc, or None once it is gone."""
    try:
        text = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    # The command name is parenthesized and may contain anything, so the
    # fields are read after its last closing parenthesis.
    fields = text[text.rindex(")") + 2 :].split()
    return fields[0], int(fields[1]), int(fields[3]), fields[19]


def cgroup_of(pid):
    try:
        text = Path(f"/proc/{pid}/cgroup").read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    for line in text.splitlines():
        if line.startswith("0::"):
            return line[len("0::") :]
    return None


def in_unit_cgroup(pid, control_group):
    # A suffix rather than an equality: `ControlGroup` is relative to the
    # manager's own root, and /proc reports the path in the reader's cgroup
    # namespace, which in a container sharing the host's is a longer one.
    path = cgroup_of(pid)
    return path is not None and (
        path == control_group or path.endswith("/" + control_group.lstrip("/"))
    )


def dispatched_worker(workspace, unit, tag):
    """The worker a pass started for `tag`, proven to be the runner's own.

    Returns the identity every survival assertion is later made against: each
    process's PID and start time, so a PID reused by something else after the
    real one died cannot pass for it.
    """
    marker = workspace / f"worker-{tag}.json"
    await_state(marker.exists, f"the {tag} worker to register")
    await_state(
        lambda: any(
            json.loads(line).get("event") == "finished"
            for line in (workspace / "passes.jsonl").read_text(encoding="utf-8").splitlines()
            if line.strip()
        )
        and not (workspace / f"request-{tag}").exists(),
        f"the pass that started the {tag} worker to finish",
    )
    pids = json.loads(marker.read_text(encoding="utf-8"))
    worker, agent = pids["worker"], pids["agent"]
    control_group = systemd_property(unit, "ControlGroup")
    require(control_group, f"{unit} reports no control group while running")
    identities = {}
    for role, pid in (("worker", worker), ("agent", agent)):
        stat = proc_stat(pid)
        require(stat is not None, f"the {tag} {role} ({pid}) is already gone")
        state, _ppid, _session, started = stat
        require(state != "Z", f"the {tag} {role} ({pid}) is already a zombie")
        require(
            in_unit_cgroup(pid, control_group),
            f"the {tag} {role} ({pid}) is in {cgroup_of(pid)!r}, not {unit}'s "
            f"{control_group!r}, so its survival would prove nothing",
        )
        identities[role] = (pid, started)
    worker_stat, agent_stat = proc_stat(worker), proc_stat(agent)
    # Detached the way `spawnDetachedSupervisor` detaches: the worker leads a
    # session of its own, and its agent is its child in that session.
    require(worker_stat[2] == worker, f"the {tag} worker does not lead its own session")
    require(agent_stat[1] == worker, f"the {tag} agent is not the worker's child")
    require(agent_stat[2] == worker, f"the {tag} agent left the worker's session")
    print(f"{tag} worker {worker} and agent {agent} are in {control_group}", flush=True)
    return identities


def require_alive(identities, tag, after):
    for role, (pid, started) in identities.items():
        stat = proc_stat(pid)
        require(stat is not None, f"the {tag} {role} ({pid}) did not survive {after}")
        state, _ppid, _session, now_started = stat
        require(
            now_started == started,
            f"PID {pid} is no longer the {tag} {role}: it did not survive {after}",
        )
        require(state != "Z", f"the {tag} {role} ({pid}) is a zombie after {after}")


def await_unit_settled(unit):
    # Settled means systemd has finished with the wrapper's exit, including
    # whatever it kills afterwards: that is part of leaving the stop state.
    return await_state(
        lambda: systemd_property(unit, "ActiveState") in {"inactive", "failed"}
        and systemd_property(unit, "ActiveState"),
        f"{unit} to settle",
    )


def check(home, workspace):
    install_fake_kanban(home, workspace)
    checkout = make_checkout(workspace)

    step("install")
    proc = run(
        [
            sys.executable,
            str(REPO_ROOT / "tools" / "install_mission_runner.py"),
            "--repo",
            str(checkout),
            "--json",
        ]
    )
    print(proc.stdout, proc.stderr, flush=True)
    require(proc.returncode == 0, f"install failed: {proc.stderr or proc.stdout}")
    installed = json.loads(proc.stdout)
    install_dir = Path(installed["install_dir"])
    job = installed["job"]
    unit = job["label"]
    unit_path = Path(job["unit"])
    require(unit.endswith(".service"), f"installed job is not a unit: {unit}")
    require(unit_path.is_file(), f"no unit file at {unit_path}")
    require(
        systemd_property(unit, "LoadState") == "loaded",
        f"{unit} is not loaded after install",
    )

    step("downgrade the unit to a release before RUN-9")
    text = unit_path.read_text(encoding="utf-8")
    require("KillMode=process\n" in text, f"{unit_path} was not written KillMode=process")
    unit_path.write_text(text.replace("KillMode=process\n", "KillMode=mixed\n"), encoding="utf-8")
    proc = run(["systemctl", "--user", "daemon-reload"])
    require(proc.returncode == 0, f"daemon-reload failed: {proc.stderr}")
    require(
        systemd_property(unit, "KillMode") == "mixed",
        f"{unit} does not hold the downgraded KillMode=mixed",
    )

    step("start: the upgrade path")
    (workspace / "request-stopped").touch()
    started = controller(install_dir, checkout, "start")
    require(started["started"], f"start reported {started}")
    require(
        "KillMode=process\n" in unit_path.read_text(encoding="utf-8"),
        f"start left {unit_path} without KillMode=process",
    )
    require(
        systemd_property(unit, "KillMode") == "process",
        f"{unit} runs under KillMode={systemd_property(unit, 'KillMode')!r}",
    )
    stopped_case = dispatched_worker(workspace, unit, "stopped")

    step("systemctl --user stop")
    proc = run(["systemctl", "--user", "stop", unit])
    require(proc.returncode == 0, f"systemctl --user stop failed: {proc.stderr}")
    await_unit_settled(unit)
    time.sleep(SURVIVAL_SECONDS)
    require_alive(stopped_case, "stopped", "systemctl --user stop")

    step("start, then SIGKILL the wrapper")
    (workspace / "passes.jsonl").unlink()
    (workspace / "request-killed").touch()
    started = controller(install_dir, checkout, "start")
    require(started["started"], f"start reported {started}")
    killed_case = dispatched_worker(workspace, unit, "killed")
    wrapper = systemd_property(unit, "MainPID")
    require(wrapper.isdigit() and int(wrapper) > 0, f"{unit} has MainPID {wrapper!r}")
    os.kill(int(wrapper), signal.SIGKILL)
    await_unit_settled(unit)
    time.sleep(SURVIVAL_SECONDS)
    require_alive(killed_case, "killed", "the wrapper's SIGKILL")
    require_alive(stopped_case, "stopped", "a later wrapper's SIGKILL")

    step("restart, stop, and uninstall")
    run(["systemctl", "--user", "reset-failed", unit])
    started = controller(install_dir, checkout, "start")
    require(started["started"], f"start after the kill reported {started}")
    stopped = controller(install_dir, checkout, "stop")
    require(stopped["stopped"], f"stop reported {stopped}")
    proc = run(
        [
            sys.executable,
            str(REPO_ROOT / "tools" / "install_mission_runner.py"),
            "--repo",
            str(checkout),
            "--uninstall",
            "--json",
        ]
    )
    print(proc.stdout, proc.stderr, flush=True)
    require(proc.returncode == 0, f"uninstall failed: {proc.stderr or proc.stdout}")
    require(not unit_path.exists(), f"unit file survives at {unit_path}")

    for identities in (stopped_case, killed_case):
        for pid, _started in identities.values():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    print("systemd mission runner worker survival check passed", flush=True)


def main():
    home = Path(os.environ.get("HOME", "")).expanduser()
    require(home.is_dir(), f"HOME does not name a directory: {home!r}")
    workspace = home / "mission-runner-check"
    shutil.rmtree(workspace, ignore_errors=True)
    workspace.mkdir(parents=True)
    try:
        check(home, workspace)
    except CheckFailed as failure:
        print(f"systemd mission runner check failed: {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
