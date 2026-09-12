"""Safety and lifecycle tests for the mission runner installer.

Hermetic throughout. Every root the installer and the controller write under is
redirected into a temporary directory, the `kanban` executable a pass runs is a
fake on the account's own `~/.local/bin`, the repositories are temporary `git
init` checkouts whose remotes name repositories nothing here ever contacts, and
the service manager is a fake whose whole state lives in one temporary
directory. No test invokes `launchctl` or `systemctl`, reaches the network or a
GitHub account, or writes to the real
`~/Library/Application Support/kanban`.

The fake manager is built for one of *two* shapes. A real backend differs from
the other in three things this installer and controller depend on -- what it
calls a definition file, what identifier it derives, and which keys its record
entry carries -- so every lifecycle case here runs against both, which is this
slice's both-backends coverage in place of a second real service manager in
CI.

The lifecycle cases are real. The fake's `kick` spawns the very argument vector
the installed definition carries, in a session of its own, so a start is proved
by a controller process that really runs and really outlives the process that
asked for it -- and a stop by that process really exiting while the job it was
started from stays installed.
"""

import ast
import contextlib
import io
import json
import os
import shlex
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

import install_mission_runner as installer
import mission_runner_service as service
import service_manager


TOOLS_DIR = Path(__file__).resolve().parent

# Captured before any fixture replaces them, so the cases that are *about* the
# real backend selection can reach it again from inside a fixture that has
# pinned a fake one.
REAL_INSTALLER_BACKEND = installer.service_backend
REAL_SERVICE_BACKEND = service.service_backend

# The two shapes a real backend comes in, as the things this installer and
# controller actually read off one: what a definition file is called, whether
# an identifier carries a unit suffix, and which keys go in a record entry.
SHAPES = ("launchd", "systemd")


# The `kanban` a pass is, reduced to what a supervised run needs of it: one
# well-formed report of a completed pass that advanced nothing. It echoes back
# the `--repo` it was handed, so the report can never name a repository other
# than the one the job was installed for.
FAKE_KANBAN = '''#!/usr/bin/env python3
import argparse
import json
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--mission-scheduler", action="store_true")
parser.add_argument("--repo", default="acme/widgets")
parser.add_argument("--config", default=None)
args = parser.parse_args()

print(
    json.dumps(
        {
            "schema": "kanban-mission-scheduler-pass",
            "version": 1,
            "repository": args.repo,
            "started_at": "2026-09-12T00:00:00Z",
            "finished_at": "2026-09-12T00:00:01Z",
            "termination": "completed",
            "exit_code": 0,
            "admitted": [],
            "attention": [],
            "detail": "Nothing was runnable.",
        }
    )
)
raise SystemExit(0)
'''


# How a subprocess runs a tracked module with its account root redirected, and
# with this fixture's fake service manager in place of the host's real one.
#
# The controller resolves the account root from the passwd database precisely
# so that nothing a process is started with can move it, which leaves a test no
# way to redirect it from outside. So the redirection happens inside the
# process, in this fixture-owned wrapper, exactly as `mock.patch.object` does
# for the in-process cases.
#
# The service manager is replaced for the same reason and with more urgency: a
# subprocess reaching the *real* backend would write a LaunchAgent into the
# developer's own home and ask launchd to load it, which is precisely the
# hermeticity this file promises.
WRAPPER = '''#!/usr/bin/env python3
import os
import sys
from pathlib import Path

tools = sys.argv[1]
account = Path(sys.argv[2])
entry = sys.argv[3]
del sys.argv[1:4]

sys.path.insert(0, tools)

import mission_runner_service as service

service.account_home = lambda: account

manager_root = os.environ.get("FIXTURE_SERVICE_MANAGER")
if manager_root:
    # In front of the install directory, so the fixture module resolves from
    # the checkout while `mission_runner_service` stays the installed copy
    # already imported above.
    sys.path.insert(0, os.environ["FIXTURE_TOOLS"])
    import test_install_mission_runner as fixture

    manager = fixture.FakeServiceManager(
        manager_root, os.environ.get("FIXTURE_SHAPE", "launchd")
    )
    service.service_backend = lambda: manager
else:
    # Fails closed. A subprocess that needs a service manager and was not
    # given the fake would otherwise reach the host's real one and load a job
    # into the developer's own launchd, so the absence of the fake is refused
    # rather than filled in.
    def _no_service_manager():
        raise AssertionError(
            "this fixture never lets a subprocess reach a real service manager; "
            "set FIXTURE_SERVICE_MANAGER"
        )

    service.service_backend = _no_service_manager

if entry == "controller":
    raise SystemExit(service.main())

if entry == "record":
    import json

    identity = sys.argv[1]
    print(
        json.dumps(
            {
                "install_dir": service.installed_install_dir(identity),
                "config_path": service.installed_config_path(identity),
                "record": str(service.discovery_record_path()),
                "runtime_dir": str(service.runtime_root()),
                "log_dir": str(service.log_root()),
            }
        )
    )
    raise SystemExit(0)

raise SystemExit(f"unknown wrapper entry point: {entry}")
'''


# How the fake service manager starts a job.
#
# One throwaway process that spawns the run in a session of its own, records
# its PID, and exits immediately. That is what makes the started run nobody's
# child here: the process that spawned it is gone, so the run is re-parented
# and reaped by init exactly as a real service manager's job is, and a test can
# therefore ask whether it is alive and get an answer rather than a zombie.
LAUNCHER = '''#!/usr/bin/env python3
import json
import os
import subprocess
import sys

spec = json.loads(sys.argv[1])
with (
    open(spec["stdout_path"], "a", encoding="utf-8") as out,
    open(spec["stderr_path"], "a", encoding="utf-8") as err,
):
    proc = subprocess.Popen(
        spec["argv"],
        cwd=spec["working_directory"],
        env=spec["environment"],
        stdout=out,
        stderr=err,
        start_new_session=True,
    )
with open(spec["pid_path"], "w", encoding="utf-8") as handle:
    handle.write(str(proc.pid))
os._exit(0)
'''


def wait_until(predicate, *, timeout=20.0, message="condition"):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError(f"timed out waiting for {message}")


def sibling_import_closure(entry):
    """Every tracked `tools/` module reachable from `entry` by module-scope
    imports, including `entry` itself, as file names.

    An installed script is executed out of the install directory and resolves
    its siblings from there, so this is exactly the set that has to be linked
    beside it -- and it is read off the modules rather than written down, so an
    import added to any of them joins the set without anybody remembering to
    say so.
    """
    found = set()
    pending = [entry]
    while pending:
        name = pending.pop()
        if name in found:
            continue
        found.add(name)
        tree = ast.parse((TOOLS_DIR / name).read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            imported = []
            if isinstance(node, ast.Import):
                imported = [alias.name for alias in node.names]
            elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
                imported = [node.module]
            for module in imported:
                candidate = f"{module.split('.')[0]}.py"
                if (TOOLS_DIR / candidate).is_file():
                    pending.append(candidate)
    return found


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class FakeServiceManager(service_manager.ServiceManagerBackend):
    """A stand-in service manager whose whole state is one directory.

    Durable rather than in-memory, because the same job is driven from this
    process and from subprocesses, and an installer that could only be observed
    in-process could not be asked to start something that outlives it. Its
    identifiers deliberately do not look like launchd's or systemd's, so a job
    named by a real derivation could not pass for one named through the seam --
    but the three things a caller *reads* off a backend vary by `shape`
    exactly as they vary between the two real ones.

    It spawns nothing of its own invention: `kick` runs the argument vector the
    definition it was handed actually carries, with only the account-root
    redirection every test in this file applies.
    """

    def __init__(self, root, shape="launchd"):
        self.root = Path(root)
        self.shape = shape
        (self.root / "definitions").mkdir(parents=True, exist_ok=True)

    # -- durable state -----------------------------------------------------

    def configure(self, *, wrapper, account):
        (self.root / "fixture.json").write_text(
            json.dumps({"wrapper": str(wrapper), "account": str(account)}),
            encoding="utf-8",
        )

    def _fixture(self):
        return json.loads((self.root / "fixture.json").read_text(encoding="utf-8"))

    def _record(self, name, *arguments):
        with (self.root / "calls.jsonl").open("a", encoding="utf-8") as handle:
            handle.write(json.dumps([name, *arguments]) + "\n")

    def calls(self):
        path = self.root / "calls.jsonl"
        if not path.exists():
            return []
        return [
            json.loads(line)
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def call_names(self):
        return [call[0] for call in self.calls()]

    def _loaded_path(self, identifier):
        return self.root / f"{identifier}.loaded"

    def _pid_path(self, identifier):
        return self.root / f"{identifier}.pid"

    def started_pid(self, identifier):
        path = self._pid_path(identifier)
        if not path.exists():
            return None
        return int(path.read_text(encoding="utf-8").strip())

    def record_started_pid(self, identifier, pid):
        """Say that this identifier's job is being run by `pid`, without
        starting anything. What a manager holding a live process looks like to
        every caller that asks it."""
        self._pid_path(identifier).write_text(str(pid), encoding="utf-8")

    # -- the boundary ------------------------------------------------------

    def namespace(self):
        return service_manager.MISSION_RUNNER_NAMESPACE

    def backend_name(self):
        return f"fake-{self.shape}"

    def definition_label(self):
        return "plist" if self.shape == "launchd" else "unit"

    def service_identifier(self, slug):
        suffix = "" if self.shape == "launchd" else ".service"
        return f"fake-mission-runner.{slug}{suffix}"

    def identifier_fits(self, slug):
        return len(slug) <= 120

    def definition_environment(self, identifier):
        return {}

    def legacy_identifier(self):
        return service_manager.require_legacy_prefix(self.namespace())

    def definition_path(self, identifier):
        return self.root / "definitions" / f"{identifier}.json"

    def legacy_definition_path(self):
        return self.root / "definitions" / "legacy.json"

    def manager_target(self, identifier):
        return f"{self.backend_name()}/{identifier}"

    def render_definition(self, definition):
        return json.dumps(
            {
                "identifier": definition.identifier,
                "program_arguments": list(definition.program_arguments),
                "working_directory": definition.working_directory,
                "environment": dict(definition.environment),
                "stdout_path": definition.stdout_path,
                "stderr_path": definition.stderr_path,
            },
            indent=2,
            sort_keys=True,
        ).encode("utf-8")

    def write_definition(self, definition):
        self._record("write_definition", definition.identifier)
        path = self.definition_path(definition.identifier)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.render_definition(definition))
        return path

    def record_entry(self, identifier, definition_path):
        if self.shape == "launchd":
            return {
                "backend": self.backend_name(),
                "launchd_label": identifier,
                "plist_path": str(definition_path),
            }
        return {
            "backend": self.backend_name(),
            "systemd_unit": identifier,
            "unit_path": str(definition_path),
        }

    def load_definition(self, identifier):
        self._record("load_definition", identifier)
        self._loaded_path(identifier).write_text("loaded", encoding="utf-8")

    def is_loaded(self, identifier):
        return self._loaded_path(identifier).exists()

    def is_running(self, identifier):
        pid = self.started_pid(identifier)
        return pid is not None and pid_alive(pid)

    def kick(self, identifier):
        self._record("kick", identifier)
        definition = json.loads(
            self.definition_path(identifier).read_text(encoding="utf-8")
        )
        fixture = self._fixture()
        arguments = list(definition["program_arguments"])
        # The definition names the *installed* controller. Running it through
        # the wrapper keeps the account root redirected while still importing
        # that installed copy, because the wrapper puts its directory first on
        # `sys.path`.
        install_dir = str(Path(arguments[1]).parent)
        pid_path = self._pid_path(identifier)
        pid_path.unlink(missing_ok=True)
        Path(definition["stdout_path"]).parent.mkdir(parents=True, exist_ok=True)
        spec = {
            "argv": [
                arguments[0],
                fixture["wrapper"],
                install_dir,
                fixture["account"],
                "controller",
                *arguments[2:],
            ],
            "working_directory": definition["working_directory"],
            "environment": dict(definition["environment"]),
            "stdout_path": definition["stdout_path"],
            "stderr_path": definition["stderr_path"],
            "pid_path": str(pid_path),
        }
        launcher = subprocess.Popen([sys.executable, "-c", LAUNCHER, json.dumps(spec)])
        launcher.wait(timeout=30)
        wait_until(pid_path.exists, message="the started job to record its PID")

    def request_stop(self, identifier):
        self._record("request_stop", identifier)
        pid = self.started_pid(identifier)
        if pid is not None and pid_alive(pid):
            os.kill(pid, signal.SIGTERM)

    def uninstall_definition(self, identifier):
        self._record("uninstall_definition", identifier)
        unloaded = self.is_loaded(identifier)
        self._loaded_path(identifier).unlink(missing_ok=True)
        path = self.definition_path(identifier)
        removed = path.exists()
        path.unlink(missing_ok=True)
        return service_manager.UninstallOutcome(
            unloaded=unloaded, definition_removed=removed
        )

    def legacy_definition_exists(self):
        return False

    def legacy_service_repository(self):
        return None

    def retire_legacy(self):
        raise service_manager.ServiceManagerError(
            service_manager.no_legacy_singleton_message(self.namespace())
        )


class InstallerFixture(unittest.TestCase):
    """A temporary account root, temporary checkouts, a fake `kanban`, and a
    fake service manager.

    Two redirections, because two different kinds of location are read. The
    service's own state hangs off the *account* root, which it resolves from
    the passwd database on purpose and which is therefore redirected in the
    process. What it reads on a caller's behalf -- the shared Kanban
    configuration -- still comes from the environment, so `$HOME` and the XDG
    base directories are redirected too.
    """

    identity = "acme/widgets"
    remote_url = "git@github.com:acme/widgets.git"
    shape = "launchd"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        # Distinct from the redirected `$HOME`, so a path that quietly went
        # back to reading the environment lands somewhere visible rather than
        # somewhere indistinguishable.
        self.account = self.root / "account"
        self.account.mkdir()
        patched = mock.patch.object(service, "account_home", lambda: self.account)
        patched.start()
        self.addCleanup(patched.stop)

        self.wrapper = self.root / "wrapper.py"
        self.wrapper.write_text(WRAPPER, encoding="utf-8")

        # On the fixed PATH an installed job's definition carries, which is
        # where a started run has to find it: the definition names no
        # interpreter for the pass and resolves `kanban` from that PATH alone.
        self.kanban = self.account / ".local" / "bin" / "kanban"
        self.kanban.parent.mkdir(parents=True)
        self.kanban.write_text(FAKE_KANBAN, encoding="utf-8")
        self.kanban.chmod(0o700)

        self.git_config = self.root / "gitconfig"
        self.git_config.write_text("", encoding="utf-8")
        self.environment = {
            **os.environ,
            "HOME": str(self.home),
            "GIT_CONFIG_GLOBAL": str(self.git_config),
            "GIT_CONFIG_NOSYSTEM": "1",
            "PYTHONUNBUFFERED": "1",
            # Redirected rather than dropped: this component resolves its own
            # roots from these, so an ambient one would let the developer's own
            # installation decide what this fixture's installs resolve.
            "XDG_DATA_HOME": str(self.home / ".local" / "share"),
            "XDG_STATE_HOME": str(self.home / ".local" / "state"),
        }
        self.environment.pop("XDG_CONFIG_HOME", None)
        self.environment.pop(service.INSTALL_DIR_ENV, None)
        patched = mock.patch.dict(os.environ, self.environment, clear=True)
        patched.start()
        self.addCleanup(patched.stop)

        self.repo = self.checkout("widgets", self.remote_url)
        self.install_dir = self.root / "installed"
        self.manager = FakeServiceManager(self.root / "manager", self.shape)
        self.manager.configure(wrapper=self.wrapper, account=self.account)
        for module in (service, installer):
            patched = mock.patch.object(
                module, "service_backend", lambda: self.manager
            )
            patched.start()
            self.addCleanup(patched.stop)
        self.addCleanup(self.stop_everything)

    # -- fixture construction ---------------------------------------------

    def checkout(self, name, remote_url):
        """A real checkout carrying real copies of the modules this installer
        links.

        Copies rather than stubs, because two things depend on their content: a
        link is recognized as Kanban's own by the marker the tracked file
        carries, and a started job really imports the installed controller out
        of the install directory. A fixture that faked either would prove
        neither.
        """
        path = self.root / name
        tools = path / "tools"
        tools.mkdir(parents=True)
        for module in installer.LINKED_MODULES:
            shutil.copy(TOOLS_DIR / module, tools / module)
        environment = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": str(self.git_config),
            "GIT_CONFIG_NOSYSTEM": "1",
        }
        subprocess.run(
            ["git", "init", "-q", str(path)],
            check=True,
            capture_output=True,
            env=environment,
        )
        subprocess.run(
            ["git", "-C", str(path), "remote", "add", "origin", remote_url],
            check=True,
            capture_output=True,
            env=environment,
        )
        # Through the installer's own resolution, because that is what `main`
        # hands `install` and what the installed job's definition therefore
        # records.
        return installer.target_repository_root(path)

    def job(self, repo=None, identity=None, config_path=None):
        return service.job_for_identity(
            repo or self.repo, identity or self.identity, config_path=config_path
        )

    def label(self, identity=None):
        return self.manager.service_identifier(
            service.repository_slug(identity or self.identity)
        )

    def record(self):
        path = service.discovery_record_path()
        if not path.exists():
            return {}
        return json.loads(path.read_text(encoding="utf-8"))

    def entries(self):
        return self.record().get("repositories", {})

    def install(self, repo=None, install_dir=None, **kwargs):
        kwargs.setdefault("dry_run", False)
        kwargs.setdefault("config_path", None)
        # The fixture checkout is both roots, exactly as a development install
        # is: the tree the job runs against and the tree its modules are
        # linked from are one directory unless a case says otherwise.
        kwargs.setdefault("asset_root", repo or self.repo)
        return installer.install(
            repo or self.repo, install_dir or self.install_dir, **kwargs
        )

    def uninstall(self, repo=None, install_dir=None, **kwargs):
        kwargs.setdefault("dry_run", False)
        kwargs.setdefault("asset_root", repo or self.repo)
        return installer.uninstall(
            repo or self.repo, install_dir or self.install_dir, **kwargs
        )

    def pretend_running(self, label=None):
        """Make the manager report a live process for this job, with no status
        document behind it.

        This test process's own PID, which is unquestionably alive and needs no
        cleanup. What it stands for is every way a real run exists without a
        readable status: one that has not written its first document yet, one
        whose write failed, and one whose runtime was damaged or removed.
        """
        self.manager.record_started_pid(label or self.label(), os.getpid())

    def controller(self, *arguments, check=True):
        """Run the *installed* controller in a subprocess, the way a service
        manager would, and hand back its parsed JSON."""
        proc = subprocess.run(
            [
                sys.executable,
                str(self.wrapper),
                str(self.install_dir),
                str(self.account),
                "controller",
                *arguments,
            ],
            capture_output=True,
            text=True,
            timeout=90,
            env={
                **os.environ,
                "FIXTURE_SERVICE_MANAGER": str(self.manager.root),
                "FIXTURE_TOOLS": str(TOOLS_DIR),
                "FIXTURE_SHAPE": self.shape,
            },
        )
        if check:
            self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc

    def write_live_status(self, pid, *, state=None, startup_nonce=None):
        """A status document as a live run would have left it, for `pid`.

        Written through the controller's own writer and then read back through
        `status_snapshot`, so a case that depends on the document being
        *believed* fails here rather than passing because the reader quietly
        rejected it.
        """
        job = self.job()
        job.runtime_dir.mkdir(parents=True, exist_ok=True)
        service.atomic_write_json(
            job.status_path,
            {
                "schema": service.STATUS_SCHEMA,
                "version": service.STATUS_VERSION,
                "state": state or service.STATE_RUNNING,
                "repository": job.identity,
                "repo": str(job.repo_path),
                "runner_pid": pid,
                "runner_identity": service.process_start_identity(pid),
                "startup_nonce": startup_nonce,
                "pass_pid": None,
                "message": "Starting a mission scheduler pass.",
                "last_pass": None,
                "passes": 0,
                "attention": [],
                "started_at": "2026-09-12T00:00:00Z",
                "updated_at": "2026-09-12T00:00:00Z",
                "kanban": str(self.kanban),
            },
        )
        self.assertIn(service.status_snapshot(job)["state"], service.LIVE_STATES)

    def detached_process(self, source):
        """A live process in a session of its own, and nobody's child here.

        Spawned through the same launcher the fake manager starts jobs with,
        because a process this fixture waited on would answer a liveness probe
        as alive long after it exited: an unreaped child is a zombie, and
        `os.kill(pid, 0)` finds one.
        """
        handle = tempfile.NamedTemporaryFile(dir=self.root, suffix=".pid", delete=False)
        handle.close()
        pid_path = Path(handle.name)
        spec = {
            "argv": [sys.executable, "-c", source],
            "working_directory": str(self.root),
            "environment": {"PATH": os.defpath},
            "stdout_path": str(self.root / "detached.out"),
            "stderr_path": str(self.root / "detached.err"),
            "pid_path": str(pid_path),
        }
        launcher = subprocess.Popen([sys.executable, "-c", LAUNCHER, json.dumps(spec)])
        launcher.wait(timeout=30)
        wait_until(lambda: pid_path.stat().st_size > 0, message="the detached PID")
        pid = int(pid_path.read_text(encoding="utf-8").strip())
        self.addCleanup(self.kill_if_alive, pid)
        return pid

    def kill_if_alive(self, pid):
        if pid_alive(pid):
            with contextlib.suppress(OSError):
                os.kill(pid, signal.SIGKILL)

    def stop_everything(self):
        for path in self.manager.root.glob("*.pid"):
            try:
                pid = int(path.read_text(encoding="utf-8").strip())
            except (OSError, ValueError):
                continue
            # Never this process: `pretend_running` records it deliberately, to
            # stand for a manager holding a run whose status cannot be read.
            if pid == os.getpid():
                continue
            if pid_alive(pid):
                with contextlib.suppress(OSError):
                    os.kill(pid, signal.SIGKILL)


class SystemdShapeMixin:
    """The same fixture against a backend that names a unit rather than a
    plist and files its record entry under a different pair of keys."""

    shape = "systemd"


# ---------------------------------------------------------------------------
# The namespace
# ---------------------------------------------------------------------------


class NamespaceTests(unittest.TestCase):
    """What the third managed namespace is, and what it is not."""

    def setUp(self):
        self.runner = lambda *arguments, **options: None

    def backends(self, namespace):
        return (
            service_manager.LaunchdBackend(self.runner, namespace),
            service_manager.SystemdBackend(self.runner, namespace),
        )

    def test_the_namespace_is_declared_with_no_legacy_singleton(self):
        namespace = service_manager.MISSION_RUNNER_NAMESPACE
        self.assertEqual(namespace.name, "mission-runner")
        self.assertEqual(namespace.prefix, "com.coghex.mission-runner")
        self.assertIsNone(namespace.legacy_prefix)

    def test_no_service_ever_names_another_services_job(self):
        others = (
            service_manager.DRAINER_NAMESPACE,
            service_manager.ISSUE_APPROVAL_NAMESPACE,
        )
        for other in others:
            for runner, existing in zip(
                self.backends(service_manager.MISSION_RUNNER_NAMESPACE),
                self.backends(other),
            ):
                with self.subTest(other=other.name, backend=runner.backend_name()):
                    mine = runner.service_identifier("acme.widgets")
                    theirs = existing.service_identifier("acme.widgets")
                    self.assertNotEqual(mine, theirs)
                    self.assertNotEqual(
                        runner.definition_path(mine), existing.definition_path(theirs)
                    )
                    self.assertNotEqual(
                        runner.manager_target(mine), existing.manager_target(theirs)
                    )

    def test_the_two_existing_namespaces_are_exactly_what_they_were(self):
        # Requirement 14: a third namespace must rename nothing. A default
        # argument or a prefix that had drifted would rename every installed
        # drainer and approval job on the next start.
        launchd, systemd = self.backends(service_manager.DRAINER_NAMESPACE)
        self.assertEqual(
            launchd.service_identifier("acme.widgets"),
            "com.coghex.drain-prs.acme.widgets",
        )
        self.assertEqual(
            systemd.service_identifier("acme.widgets"),
            "com.coghex.drain-prs.acme.widgets.service",
        )
        launchd, systemd = self.backends(service_manager.ISSUE_APPROVAL_NAMESPACE)
        self.assertEqual(
            launchd.service_identifier("acme.widgets"),
            "com.coghex.issue-approval.acme.widgets",
        )
        self.assertEqual(
            systemd.service_identifier("acme.widgets"),
            "com.coghex.issue-approval.acme.widgets.service",
        )

    def test_a_namespace_with_no_singleton_has_none_to_name_or_retire(self):
        for backend in self.backends(service_manager.MISSION_RUNNER_NAMESPACE):
            with self.subTest(backend=backend.backend_name()):
                self.assertFalse(backend.legacy_definition_exists())
                self.assertIsNone(backend.legacy_service_repository())
                with self.assertRaises(service_manager.ServiceManagerError):
                    backend.legacy_identifier()
                with self.assertRaises(service_manager.ServiceManagerError):
                    backend.retire_legacy()

    def test_the_slug_limit_is_the_namespaces_own(self):
        # One slug names the identifier, the runtime directory, and the log
        # directory together, so the controller has to partition its runtime by
        # the smallest limit any backend imposes rather than by a number of its
        # own.
        limit = service_manager.namespace_slug_limit(
            service_manager.MISSION_RUNNER_NAMESPACE
        )
        self.assertEqual(service.SLUG_LIMIT, limit)
        for backend in self.backends(service_manager.MISSION_RUNNER_NAMESPACE):
            with self.subTest(backend=backend.backend_name()):
                self.assertTrue(backend.identifier_fits("a" * limit))
        self.assertFalse(
            all(
                backend.identifier_fits("a" * (limit + 1))
                for backend in self.backends(service_manager.MISSION_RUNNER_NAMESPACE)
            )
        )

    def test_an_overflowing_identity_still_yields_a_manageable_slug(self):
        identity = "a" * 200 + "/" + "b" * 200
        slug = service.repository_slug(identity)
        limit = service_manager.namespace_slug_limit(
            service_manager.MISSION_RUNNER_NAMESPACE
        )
        self.assertLessEqual(len(slug), limit)
        self.assertNotEqual(slug, service.repository_slug(identity + "x"))


# ---------------------------------------------------------------------------
# Managed links
# ---------------------------------------------------------------------------


class ManagedAssetTests(unittest.TestCase):
    """What the installer will and will not touch."""

    def test_every_linked_module_in_this_checkout_is_recognizable(self):
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertTrue(
                    installer.is_managed_asset(TOOLS_DIR / name, name),
                    f"tools/{name} carries no managed-asset marker, so an "
                    "installed link to it could never be recognized as ours",
                )

    def test_a_marker_for_another_module_is_not_a_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            impostor = Path(tmp) / "service_manager.py"
            impostor.write_text(
                "# kanban-managed-asset:issue-review/kanban_config.py\n",
                encoding="utf-8",
            )
            self.assertFalse(
                installer.is_managed_asset(impostor, "service_manager.py")
            )

    def test_any_kanban_namespace_recognizes_the_module(self):
        # One tracked file serves several installed namespaces, so what this
        # check establishes is that the file is Kanban's own module of that
        # name -- never whose installer first claimed it.
        with tempfile.TemporaryDirectory() as tmp:
            for namespace in ("issue-review", "issue-approval", "mission-runner"):
                path = Path(tmp) / f"{namespace}.py"
                path.write_text(
                    f"# kanban-managed-asset:{namespace}/kanban_config.py\n",
                    encoding="utf-8",
                )
                self.assertTrue(
                    installer.is_managed_asset(path, "kanban_config.py"),
                    namespace,
                )

    def test_an_unmarked_file_is_never_recognized(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "kanban_config.py"
            path.write_text("print('hello')\n", encoding="utf-8")
            self.assertFalse(installer.is_managed_asset(path, "kanban_config.py"))
            self.assertFalse(
                installer.is_managed_asset(Path(tmp) / "absent.py", "absent.py")
            )


class LinkSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "tools" / "service_manager.py"
        self.source.parent.mkdir(parents=True)
        shutil.copy(TOOLS_DIR / "service_manager.py", self.source)
        self.destination = self.root / "installed" / "service_manager.py"
        self.destination.parent.mkdir(parents=True)

    def test_creates_a_link_and_is_idempotent(self):
        self.assertEqual(
            installer.install_symlink(self.source, self.destination), "created"
        )
        self.assertEqual(
            installer.install_symlink(self.source, self.destination), "unchanged"
        )

    def test_an_upgrade_repoints_the_one_link(self):
        other = self.root / "other" / "tools" / "service_manager.py"
        other.parent.mkdir(parents=True)
        shutil.copy(TOOLS_DIR / "service_manager.py", other)
        installer.install_symlink(self.source, self.destination)
        self.assertEqual(
            installer.install_symlink(other, self.destination), "updated"
        )
        self.assertEqual(
            os.path.realpath(self.destination), os.path.realpath(other)
        )
        self.assertEqual(
            sorted(path.name for path in self.destination.parent.iterdir()),
            ["service_manager.py"],
        )

    def test_refuses_to_overwrite_an_ordinary_file(self):
        self.destination.write_text("mine\n", encoding="utf-8")
        with self.assertRaises(installer.InstallError):
            installer.install_symlink(self.source, self.destination)
        self.assertEqual(self.destination.read_text(encoding="utf-8"), "mine\n")

    def test_refuses_to_repoint_a_link_to_somebody_elses_file(self):
        foreign = self.root / "foreign" / "service_manager.py"
        foreign.parent.mkdir(parents=True)
        foreign.write_text("not kanban's\n", encoding="utf-8")
        self.destination.symlink_to(foreign)
        with self.assertRaises(installer.InstallError):
            installer.install_symlink(self.source, self.destination)
        self.assertEqual(os.readlink(self.destination), str(foreign))

    def test_a_broken_link_is_preserved_because_nothing_can_recognize_it(self):
        self.destination.symlink_to(self.root / "gone" / "service_manager.py")
        with self.assertRaises(installer.InstallError) as raised:
            installer.install_symlink(self.source, self.destination)
        self.assertIn("does not exist", str(raised.exception))
        self.assertTrue(self.destination.is_symlink())

    def test_a_broken_link_is_never_removed_either(self):
        self.destination.symlink_to(self.root / "gone" / "service_manager.py")
        self.assertEqual(
            installer.remove_symlink(self.destination, "service_manager.py"), "kept"
        )
        self.assertTrue(self.destination.is_symlink())

    def test_removal_keeps_an_ordinary_file_and_a_foreign_link(self):
        self.destination.write_text("mine\n", encoding="utf-8")
        self.assertEqual(
            installer.remove_symlink(self.destination, "service_manager.py"), "kept"
        )
        self.destination.unlink()
        foreign = self.root / "foreign" / "service_manager.py"
        foreign.parent.mkdir(parents=True)
        foreign.write_text("not kanban's\n", encoding="utf-8")
        self.destination.symlink_to(foreign)
        self.assertEqual(
            installer.remove_symlink(self.destination, "service_manager.py"), "kept"
        )
        self.assertTrue(self.destination.is_symlink())

    def test_removal_takes_its_own_link(self):
        installer.install_symlink(self.source, self.destination)
        self.assertEqual(
            installer.remove_symlink(self.destination, "service_manager.py"), "removed"
        )
        self.assertFalse(os.path.lexists(self.destination))
        self.assertEqual(
            installer.remove_symlink(self.destination, "service_manager.py"), "absent"
        )


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------


class NonResidentTests(InstallerFixture):
    def test_install_loads_a_stopped_job_and_starts_nothing(self):
        result = self.install()
        self.assertTrue(result["installed"])
        self.assertFalse(result["job"]["started"])
        self.assertEqual(
            self.manager.call_names(), ["write_definition", "load_definition"]
        )
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertFalse(self.manager.is_running(self.label()))

    def test_no_real_definition_starts_at_login(self):
        # Rendered by the real backends rather than the fake one: whether a
        # login starts this job is a property of the plist and the unit file,
        # and the fake writes neither.
        definition = service.service_definition(self.job(), self.install_dir)
        runner = lambda *arguments, **options: None  # noqa: E731 - never called
        document = plistlib.loads(
            service_manager.LaunchdBackend(
                runner, service_manager.MISSION_RUNNER_NAMESPACE
            ).render_definition(definition)
        )
        self.assertIs(document["RunAtLoad"], False)
        self.assertIs(document["KeepAlive"], False)
        unit = (
            service_manager.SystemdBackend(
                runner, service_manager.MISSION_RUNNER_NAMESPACE
            )
            .render_definition(definition)
            .decode("utf-8")
        )
        self.assertNotIn("[Install]", unit)
        self.assertIn("Restart=no", unit)
        self.assertIn("Kanban mission runner", unit)


class NonResidentSystemdTests(SystemdShapeMixin, NonResidentTests):
    pass


class LifecycleTests(InstallerFixture):
    """A real controller process, started and stopped through the seam."""

    def controller_status(self):
        return service.status_snapshot(self.job())["state"]

    def test_an_explicit_start_produces_a_run_that_outlives_its_caller(self):
        self.install()
        proc = self.controller(
            "start", "--path", str(self.repo), "--repo", self.identity, "--json"
        )
        started = json.loads(proc.stdout)
        self.assertTrue(started["started"])
        self.assertIn(started["state"], service.LIVE_STATES)

        # The process that asked for the start has exited, and the run it asked
        # for has not: that is the whole difference between a managed job and a
        # foreground command.
        runner_pid = started["runner_pid"]
        self.assertTrue(pid_alive(runner_pid))
        self.assertIn(self.controller_status(), service.LIVE_STATES)
        self.assertNotEqual(os.getpid(), runner_pid)

    def test_the_started_job_runs_the_installed_wrapper_for_this_repository(self):
        self.install(config_path=str(self.root / "kanban.toml"))
        definition = json.loads(
            self.manager.definition_path(self.label()).read_text(encoding="utf-8")
        )
        arguments = definition["program_arguments"]
        self.assertEqual(arguments[1], str(self.install_dir / service.CONTROLLER_NAME))
        self.assertEqual(arguments[2], "run")
        self.assertIn("--repo", arguments)
        self.assertEqual(arguments[arguments.index("--repo") + 1], self.identity)
        self.assertIn("--config", arguments)
        self.assertEqual(
            arguments[arguments.index("--config") + 1],
            str((self.root / "kanban.toml").resolve()),
        )
        self.assertEqual(definition["working_directory"], str(self.repo))

    def test_an_explicit_stop_ends_the_run_and_leaves_the_job_installed(self):
        self.install()
        service.start_service(self.job(), self.install_dir)
        runner_pid = service.status_snapshot(self.job())["runner_pid"]
        self.assertTrue(pid_alive(runner_pid))

        stopped = service.stop_service(self.job())
        self.assertTrue(stopped["stopped"])
        self.assertEqual(stopped["state"], service.STATE_STOPPED)
        wait_until(lambda: not pid_alive(runner_pid), message="the run to exit")
        # Stopped, not uninstalled: the job stays loaded and its record entry
        # stays put, which is exactly what the next start has to find.
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertIn(self.identity, self.entries())
        self.assertIn("request_stop", self.manager.call_names())

    def test_stopping_a_stopped_service_is_not_an_error(self):
        self.install()
        result = service.stop_service(self.job())
        self.assertFalse(result["stopped"])
        self.assertNotIn("request_stop", self.manager.call_names())

    def test_uninstall_refuses_while_the_run_is_live(self):
        self.install()
        service.start_service(self.job(), self.install_dir)
        with self.assertRaises(installer.InstallError) as raised:
            self.uninstall()
        self.assertIn("already running", str(raised.exception))
        # Refused without taking anything away, so the running controller is
        # still discoverable and still controllable.
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertIn(self.identity, self.entries())
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink())


class StartConfirmationTests(InstallerFixture):
    """A start is confirmed by the manager that holds the job, never by a
    status document alone."""

    def test_a_start_is_not_confirmed_by_a_run_the_manager_does_not_hold(self):
        # The window `_install_locked` cannot close: it releases this identity's
        # run lock before the kick, because the run being started needs that
        # lock to establish itself. A foreground run can take it there, publish
        # a live status of its own, and leave the kicked process to lose the
        # lock and exit at once -- so a start confirmed on the document would
        # report somebody else's process as the job it started, and every later
        # stop, uninstall and dashboard reading would address a manager holding
        # nothing.
        self.install()
        foreground = self.detached_process("import time; time.sleep(300)")

        def kick_that_starts_nothing(_identifier):
            # Exactly what that race leaves behind: a believable live status
            # nobody's manager is holding.
            self.write_live_status(foreground)

        with mock.patch.object(self.manager, "kick", kick_that_starts_nothing):
            with mock.patch.object(service, "START_TIMEOUT_SECONDS", 1.0):
                with self.assertRaises(service.ServiceError) as raised:
                    service.start_service(self.job(), self.install_dir)
        message = str(raised.exception)
        self.assertIn("holds no live process", message)
        self.assertIn(self.label(), message)
        # And the foreground run is untouched: a start that could not confirm
        # itself has no business ending somebody else's process.
        self.assertTrue(pid_alive(foreground))

    def held_but_foreign(self, *, startup_nonce=None):
        """A kick that leaves the manager holding a live process for the whole
        startup window beside a live status document some *other* run wrote.

        The shape two independent observations cannot tell from a real start:
        "the manager is running it" and "a live status exists" are both true
        throughout, and for as long as the process the manager holds happens to
        live. Only the token the definition carried separates them.
        """
        foreground = self.detached_process("import time; time.sleep(300)")
        held = self.detached_process("import time; time.sleep(300)")

        def kick(identifier):
            self.manager.record_started_pid(identifier, held)
            self.write_live_status(foreground, startup_nonce=startup_nonce)

        return foreground, kick

    def assert_start_refuses(self, kick, *, expected):
        with mock.patch.object(self.manager, "kick", kick):
            with mock.patch.object(service, "START_TIMEOUT_SECONDS", 1.5):
                with self.assertRaises(service.ServiceError) as raised:
                    service.start_service(self.job(), self.install_dir)
        self.assertIn(expected, str(raised.exception))

    def test_a_start_is_not_confirmed_by_a_status_its_own_run_did_not_write(self):
        self.install()
        foreground, kick = self.held_but_foreign()
        self.assert_start_refuses(kick, expected="written by a different run")
        # Refused without touching it: a start that could not confirm itself
        # has no business ending somebody else's run.
        self.assertTrue(pid_alive(foreground))

    def test_an_earlier_starts_token_does_not_confirm_this_one(self):
        # A token that is merely stale is as foreign as none at all: the run it
        # names is not the run this start launched.
        self.install()
        _foreground, kick = self.held_but_foreign(startup_nonce="an-earlier-start")
        self.assert_start_refuses(kick, expected="written by a different run")

    def test_only_a_start_writes_a_token_into_the_definition(self):
        self.install()
        self.assertNotIn(service.STARTUP_NONCE_ENV, self.definition_environment())
        service.start_service(self.job(), self.install_dir)
        self.assertIn(service.STARTUP_NONCE_ENV, self.definition_environment())

    def test_two_starts_never_reuse_a_token(self):
        self.install()
        service.start_service(self.job(), self.install_dir)
        first = self.definition_environment()[service.STARTUP_NONCE_ENV]
        service.stop_service(self.job())
        service.start_service(self.job(), self.install_dir)
        second = self.definition_environment()[service.STARTUP_NONCE_ENV]
        self.assertNotEqual(first, second)

    def test_the_started_run_publishes_the_token_it_was_launched_with(self):
        self.install()
        service.start_service(self.job(), self.install_dir)
        self.assertEqual(
            service.published_startup_nonce(self.job()),
            self.definition_environment()[service.STARTUP_NONCE_ENV],
        )

    def definition_environment(self, label=None):
        definition = json.loads(
            self.manager.definition_path(label or self.label()).read_text(
                encoding="utf-8"
            )
        )
        return definition["environment"]

    def test_a_genuine_start_is_still_confirmed(self):
        # The positive control the refusal above needs: the same two signals,
        # both really the manager's, report started.
        self.install()
        result = service.start_service(self.job(), self.install_dir)
        self.assertTrue(result["started"])
        self.assertTrue(self.manager.is_running(self.label()))


class StartConfirmationSystemdTests(SystemdShapeMixin, StartConfirmationTests):
    pass


class LifecycleSystemdTests(SystemdShapeMixin, LifecycleTests):
    pass


class ManagerLivenessTests(InstallerFixture):
    """A run the status document cannot describe is still a run."""

    def test_uninstall_refuses_a_live_manager_job_with_no_status(self):
        self.install()
        self.pretend_running()
        self.assertFalse(self.job().status_path.exists())
        with self.assertRaises(installer.InstallError) as raised:
            self.uninstall()
        self.assertIn("still holds a live process", str(raised.exception))
        # Refused before anything was destroyed, so the running controller is
        # still discoverable and still addressable.
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertTrue(self.manager.definition_path(self.label()).exists())
        self.assertIn(self.identity, self.entries())
        self.assertNotIn("uninstall_definition", self.manager.call_names())

    def test_the_uninstall_dry_run_refuses_it_too(self):
        self.install()
        self.pretend_running()
        with self.assertRaises(installer.InstallError):
            self.uninstall(dry_run=True)

    def test_install_refuses_a_live_manager_job_with_no_status(self):
        self.install()
        self.pretend_running()
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn("still holds a live process", str(raised.exception))

    def test_starting_a_live_manager_job_with_no_status_is_a_no_op(self):
        # A start is not a destructive transition, so an already-running job is
        # nothing to do rather than an error -- and nothing is rewritten.
        self.install()
        self.pretend_running()
        before = self.manager.call_names()
        result = service.start_service(self.job(), self.install_dir)
        self.assertFalse(result["started"])
        self.assertEqual(self.manager.call_names(), before)

    def test_stopping_a_live_manager_job_with_no_status_really_stops_it(self):
        # `request_stop` is asked for even though the status document says
        # nothing, because the manager's answer is the one that decides.
        self.install()
        pid = self.detached_process("import time; time.sleep(300)")
        self.manager.record_started_pid(self.label(), pid)
        self.assertFalse(self.job().status_path.exists())

        result = service.stop_service(self.job())
        self.assertTrue(result["stopped"])
        self.assertIn("request_stop", self.manager.call_names())
        self.assertFalse(pid_alive(pid))


class ManagerLivenessSystemdTests(SystemdShapeMixin, ManagerLivenessTests):
    pass


# ---------------------------------------------------------------------------
# Per-repository isolation
# ---------------------------------------------------------------------------


class SideBySideTests(InstallerFixture):
    other_identity = "acme/gadgets"
    other_remote = "git@github.com:acme/gadgets.git"

    def setUp(self):
        super().setUp()
        self.other_repo = self.checkout("gadgets", self.other_remote)

    def other_job(self):
        return self.job(repo=self.other_repo, identity=self.other_identity)

    def test_installing_a_second_repository_adds_an_entry_beside_the_first(self):
        self.install()
        self.install(repo=self.other_repo)
        self.assertEqual(
            sorted(self.entries()), [self.other_identity, self.identity]
        )
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertTrue(self.manager.is_loaded(self.label(self.other_identity)))
        self.assertNotEqual(self.label(), self.label(self.other_identity))
        self.assertNotEqual(
            self.job().runtime_dir, self.other_job().runtime_dir
        )
        self.assertNotEqual(self.job().log_dir, self.other_job().log_dir)

    def test_uninstalling_one_leaves_the_others_job_entry_and_logs(self):
        self.install()
        self.install(repo=self.other_repo)
        other_logs = self.other_job().log_dir
        self.assertTrue(other_logs.is_dir())
        self.uninstall()
        self.assertEqual(sorted(self.entries()), [self.other_identity])
        self.assertFalse(self.manager.is_loaded(self.label()))
        self.assertTrue(self.manager.is_loaded(self.label(self.other_identity)))
        self.assertTrue(other_logs.is_dir())
        # The shared links serve every job installed here, so they survive
        # while one is left to run from them.
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink(), name)

    def test_the_shared_links_go_only_with_the_last_job(self):
        self.install()
        self.install(repo=self.other_repo)
        self.uninstall()
        self.uninstall(repo=self.other_repo)
        self.assertEqual(self.entries(), {})
        for name in installer.LINKED_MODULES:
            self.assertFalse(os.path.lexists(self.install_dir / name), name)

    def test_one_repositorys_config_never_displaces_anothers(self):
        first = self.root / "first.toml"
        second = self.root / "second.toml"
        for path in (first, second):
            path.write_text("", encoding="utf-8")
        self.install(config_path=str(first))
        self.install(repo=self.other_repo, config_path=str(second))
        self.assertEqual(
            service.installed_config_path(self.identity), str(first.resolve())
        )
        self.assertEqual(
            service.installed_config_path(self.other_identity), str(second.resolve())
        )

    def test_uninstalling_a_repository_that_was_never_installed_is_not_an_error(self):
        self.install()
        result = self.uninstall(repo=self.other_repo)
        self.assertTrue(result["uninstalled"])
        self.assertEqual(sorted(self.entries()), [self.identity])
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink(), name)


class SideBySideSystemdTests(SystemdShapeMixin, SideBySideTests):
    pass


# ---------------------------------------------------------------------------
# Relocation and the override boundary
# ---------------------------------------------------------------------------


class RelocationTests(InstallerFixture):
    def test_the_override_moves_the_links_and_leaves_the_record_and_logs(self):
        self.install()
        record_before = service.discovery_record_path()
        log_root_before = service.log_root()
        elsewhere = self.root / "elsewhere"
        result = self.install(install_dir=elsewhere)
        self.assertEqual(result["relocated_from"], str(self.install_dir))
        for name in installer.LINKED_MODULES:
            self.assertTrue((elsewhere / name).is_symlink(), name)
            self.assertFalse(os.path.lexists(self.install_dir / name), name)
        self.assertEqual(service.discovery_record_path(), record_before)
        self.assertEqual(service.log_root(), log_root_before)
        self.assertEqual(
            service.installed_install_dir(self.identity), str(elsewhere)
        )
        # The definition names the relocated controller, so a start really runs
        # out of the directory the override chose.
        definition = json.loads(
            self.manager.definition_path(self.label()).read_text(encoding="utf-8")
        )
        self.assertEqual(
            definition["program_arguments"][1],
            str(elsewhere / service.CONTROLLER_NAME),
        )
        self.assertEqual(
            definition["environment"][service.INSTALL_DIR_ENV], str(elsewhere)
        )

    def test_a_relocation_keeps_links_another_job_still_runs_from(self):
        other_repo = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.install()
        self.install(repo=other_repo)
        elsewhere = self.root / "elsewhere"
        self.install(install_dir=elsewhere)
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink(), name)
            self.assertTrue((elsewhere / name).is_symlink(), name)

    def test_reinstalling_in_place_relocates_nothing(self):
        self.install()
        result = self.install()
        self.assertIsNone(result["relocated_from"])
        self.assertEqual(result["released_links"], {})

    def test_the_relocation_plan_is_what_the_relocation_performs(self):
        self.install()
        elsewhere = self.root / "elsewhere"
        planned = self.install(install_dir=elsewhere, dry_run=True)
        performed = self.install(install_dir=elsewhere)
        self.assertEqual(planned["relocated_from"], performed["relocated_from"])
        self.assertEqual(
            {name: link["destination"] for name, link in planned["links"].items()},
            {name: link["destination"] for name, link in performed["links"].items()},
        )
        self.assertEqual(
            sorted(planned["released_links"]), sorted(performed["released_links"])
        )

    def test_an_uninstall_pointed_at_the_wrong_directory_is_refused(self):
        self.install()
        elsewhere = self.root / "elsewhere"
        with self.assertRaises(installer.InstallError) as raised:
            self.uninstall(install_dir=elsewhere)
        self.assertIn(str(self.install_dir), str(raised.exception))
        self.assertIn(self.identity, self.entries())
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink(), name)

    def test_uninstalling_with_no_directory_finds_the_recorded_one(self):
        elsewhere = self.root / "elsewhere"
        self.install(install_dir=elsewhere)
        resolved = installer.selected_install_dir(self.repo, None)
        self.assertEqual(str(resolved), str(elsewhere))
        result = installer.uninstall(
            self.repo, resolved, asset_root=self.repo, dry_run=False
        )
        self.assertTrue(result["uninstalled"])
        for name in installer.LINKED_MODULES:
            self.assertFalse(os.path.lexists(elsewhere / name), name)


class RelocationSystemdTests(SystemdShapeMixin, RelocationTests):
    pass


class RediscoveryTests(InstallerFixture):
    def test_a_custom_install_dir_and_config_path_are_rediscoverable(self):
        elsewhere = self.root / "elsewhere"
        config = self.root / "kanban.toml"
        config.write_text("", encoding="utf-8")
        self.install(install_dir=elsewhere, config_path=str(config))
        # Asked from a process holding none of this one's environment, which is
        # what a dashboard and a service manager both are.
        proc = subprocess.run(
            [
                sys.executable,
                str(self.wrapper),
                str(elsewhere),
                str(self.account),
                "record",
                self.identity,
            ],
            capture_output=True,
            text=True,
            timeout=60,
            env={
                "PATH": os.defpath,
                "HOME": str(self.home),
                "XDG_DATA_HOME": os.environ["XDG_DATA_HOME"],
                "XDG_STATE_HOME": os.environ["XDG_STATE_HOME"],
            },
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rediscovered = json.loads(proc.stdout)
        self.assertEqual(rediscovered["install_dir"], str(elsewhere))
        self.assertEqual(rediscovered["config_path"], str(config.resolve()))
        self.assertEqual(
            rediscovered["record"], str(service.discovery_record_path())
        )

    def test_a_relative_config_path_is_recorded_absolute(self):
        config = self.root / "kanban.toml"
        config.write_text("", encoding="utf-8")
        previous = os.getcwd()
        os.chdir(self.root)
        try:
            self.install(config_path="kanban.toml")
        finally:
            os.chdir(previous)
        self.assertEqual(
            service.installed_config_path(self.identity), str(config.resolve())
        )

    def test_a_reinstall_with_no_options_converges_on_the_recorded_installation(self):
        elsewhere = self.root / "elsewhere"
        self.install(install_dir=elsewhere)
        self.assertEqual(
            str(installer.selected_install_dir(self.repo, None)), str(elsewhere)
        )

    def configured_argument(self, label=None):
        """The `--config` the installed definition currently carries, or None."""
        definition = json.loads(
            self.manager.definition_path(label or self.label()).read_text(
                encoding="utf-8"
            )
        )
        arguments = definition["program_arguments"]
        if "--config" not in arguments:
            return None
        return arguments[arguments.index("--config") + 1]

    def test_a_start_told_nothing_keeps_the_recorded_config(self):
        # A start refreshes the definition, so a job resolved without the
        # recorded `--config` would rewrite the definition without it while the
        # record went on naming it -- leaving the runner on the shared default
        # and the installation claiming otherwise.
        config = self.root / "kanban.toml"
        config.write_text("", encoding="utf-8")
        self.install(config_path=str(config))
        job = service.resolve_job(self.repo)
        self.assertEqual(job.config_path, str(config.resolve()))

        service.start_service(job, self.install_dir)
        self.assertEqual(self.configured_argument(), str(config.resolve()))
        self.assertEqual(
            service.installed_config_path(self.identity), str(config.resolve())
        )

    def test_a_reinstall_told_nothing_keeps_the_recorded_config(self):
        config = self.root / "kanban.toml"
        config.write_text("", encoding="utf-8")
        self.install(config_path=str(config))
        self.install()
        self.assertEqual(self.configured_argument(), str(config.resolve()))
        self.assertEqual(
            service.installed_config_path(self.identity), str(config.resolve())
        )

    def test_a_process_holding_no_environment_resolves_the_recorded_config(self):
        # The service manager's own case: it reruns the installed controller
        # with nothing but the definition's environment, and the refresh that
        # runs there has to find the same configuration.
        config = self.root / "kanban.toml"
        config.write_text("", encoding="utf-8")
        self.install(config_path=str(config))
        self.controller("install", "--path", str(self.repo), "--json")
        self.assertEqual(self.configured_argument(), str(config.resolve()))

    def test_an_explicit_config_still_overrides_the_recorded_one(self):
        first = self.root / "first.toml"
        second = self.root / "second.toml"
        for path in (first, second):
            path.write_text("", encoding="utf-8")
        self.install(config_path=str(first))
        self.install(config_path=str(second))
        self.assertEqual(self.configured_argument(), str(second.resolve()))
        self.assertEqual(
            service.installed_config_path(self.identity), str(second.resolve())
        )


class RediscoverySystemdTests(SystemdShapeMixin, RediscoveryTests):
    pass


class InstallDirectoryOverrideTests(InstallerFixture):
    """`KANBAN_MISSION_RUNNER_INSTALL_DIR` selects an installation for a
    process that was told nothing else."""

    def test_an_absolute_override_selects_that_installation(self):
        elsewhere = self.root / "elsewhere"
        with mock.patch.dict(os.environ, {service.INSTALL_DIR_ENV: str(elsewhere)}):
            self.assertEqual(service.selected_install_dir(), elsewhere)
            self.assertEqual(service.job_install_dir(self.job()), elsewhere)
            self.assertEqual(
                installer.selected_install_dir(self.repo, None), elsewhere
            )

    def test_a_home_relative_override_is_expanded_and_selected(self):
        with mock.patch.dict(
            os.environ, {service.INSTALL_DIR_ENV: "~/mission-runner"}
        ):
            self.assertEqual(
                service.selected_install_dir(), Path.home() / "mission-runner"
            )

    def test_a_relative_override_is_refused_rather_than_resolved(self):
        # Two processes read this variable with two different working
        # directories -- the operator's shell and the checkout a service
        # manager launches the job in -- so a relative value names a different
        # installation to each of them. Resolving it here would pick this
        # reader's, and the install would report success while the definition,
        # the record and the links named three places.
        for value in ("relative/dir", "./here", ".."):
            with self.subTest(override=value):
                with mock.patch.dict(os.environ, {service.INSTALL_DIR_ENV: value}):
                    with self.assertRaises(service.ServiceError) as raised:
                        service.selected_install_dir()
                    self.assertIn(service.INSTALL_DIR_ENV, str(raised.exception))
                    self.assertIn(repr(value), str(raised.exception))

    def test_an_environment_driven_install_and_start_use_that_directory(self):
        elsewhere = self.root / "elsewhere"
        with mock.patch.dict(os.environ, {service.INSTALL_DIR_ENV: str(elsewhere)}):
            selected = installer.selected_install_dir(self.repo, None)
            installer.install(
                self.repo,
                selected,
                asset_root=self.repo,
                config_path=None,
                dry_run=False,
            )
            for name in installer.LINKED_MODULES:
                self.assertTrue((elsewhere / name).is_symlink(), name)
            self.assertEqual(
                service.installed_install_dir(self.identity), str(elsewhere)
            )
            service.start_service(self.job(), service.job_install_dir(self.job()))
        definition = json.loads(
            self.manager.definition_path(self.label()).read_text(encoding="utf-8")
        )
        self.assertEqual(
            definition["program_arguments"][1],
            str(elsewhere / service.CONTROLLER_NAME),
        )
        self.assertEqual(
            definition["environment"][service.INSTALL_DIR_ENV], str(elsewhere)
        )

    def test_a_relative_override_refuses_an_install_before_anything_is_written(self):
        # Through `main`, because that is the path an operator's environment
        # actually reaches: the refusal has to be this installer's reported
        # failure rather than a traceback, and it has to arrive before the
        # first write.
        errors = io.StringIO()
        with mock.patch.dict(os.environ, {service.INSTALL_DIR_ENV: "relative/dir"}):
            with contextlib.redirect_stderr(errors):
                code = installer.main(["--repo", str(self.repo), "--json"])
        self.assertEqual(code, 1)
        self.assertIn(service.INSTALL_DIR_ENV, errors.getvalue())
        self.assertEqual(self.manager.call_names(), [])
        self.assertEqual(self.entries(), {})

    def test_a_relative_install_directory_is_refused_however_it_arrived(self):
        # The argument itself is one anybody can pass, so the plan refuses it
        # rather than trusting every caller to have resolved it.
        with self.assertRaises(service.ServiceError) as raised:
            service.install_plan(self.job(), Path("relative/dir"))
        self.assertIn("not an absolute", str(raised.exception))


class InstallDirectoryOverrideSystemdTests(
    SystemdShapeMixin, InstallDirectoryOverrideTests
):
    pass


# ---------------------------------------------------------------------------
# Discovery: where the record is, and how the job finds it again
# ---------------------------------------------------------------------------


class ProbeOrderTests(InstallerFixture):
    """Which installation a host has, decided by occupancy rather than by
    platform."""

    def candidates(self):
        return (
            service._xdg_service_root() / service.RECORD_NAME,
            service._macos_service_root() / service.RECORD_NAME,
        )

    def occupy(self, path, *, as_directory=False, dangling=False):
        if as_directory:
            path.mkdir(parents=True, exist_ok=True)
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        if dangling:
            path.symlink_to(path.parent / "gone.json")
            return
        path.write_text("{}\n", encoding="utf-8")

    def test_only_the_xdg_location_occupied_resolves_there(self):
        xdg, library = self.candidates()
        self.occupy(xdg)
        for macos in (True, False):
            with self.subTest(macos=macos):
                with mock.patch.object(
                    service.kanban_config, "is_macos", lambda: macos
                ):
                    self.assertEqual(service.discovery_record_path(), xdg)
                    self.assertFalse(os.path.lexists(library))

    def test_only_the_library_location_occupied_resolves_there(self):
        xdg, library = self.candidates()
        self.occupy(library)
        for macos in (True, False):
            with self.subTest(macos=macos):
                with mock.patch.object(
                    service.kanban_config, "is_macos", lambda: macos
                ):
                    self.assertEqual(service.discovery_record_path(), library)
                    self.assertFalse(os.path.lexists(xdg))

    def test_both_occupied_prefers_the_xdg_location(self):
        xdg, library = self.candidates()
        self.occupy(xdg)
        self.occupy(library)
        for macos in (True, False):
            with self.subTest(macos=macos):
                with mock.patch.object(
                    service.kanban_config, "is_macos", lambda: macos
                ):
                    self.assertEqual(service.discovery_record_path(), xdg)

    def test_neither_occupied_writes_this_platforms_own_default(self):
        xdg, library = self.candidates()
        with mock.patch.object(service.kanban_config, "is_macos", lambda: True):
            self.assertEqual(service.discovery_record_path(), library)
        with mock.patch.object(service.kanban_config, "is_macos", lambda: False):
            self.assertEqual(service.discovery_record_path(), xdg)

    def test_a_directory_and_a_dangling_link_each_count_as_occupied(self):
        xdg, library = self.candidates()
        self.occupy(library)
        for kind in ("directory", "dangling"):
            with self.subTest(kind=kind):
                if os.path.lexists(xdg):
                    shutil.rmtree(xdg, ignore_errors=True)
                    if os.path.lexists(xdg):
                        xdg.unlink()
                self.occupy(
                    xdg,
                    as_directory=kind == "directory",
                    dangling=kind == "dangling",
                )
                for macos in (True, False):
                    with mock.patch.object(
                        service.kanban_config, "is_macos", lambda: macos
                    ):
                        self.assertEqual(service.discovery_record_path(), xdg)

    def test_a_fresh_install_writes_this_platforms_own_default(self):
        _xdg, library = self.candidates()
        with mock.patch.object(service.kanban_config, "is_macos", lambda: True):
            self.install()
            self.assertTrue(library.is_file())
            self.assertIn(self.identity, json.loads(library.read_text())["repositories"])


class EnvironmentRuleTests(InstallerFixture):
    """`$XDG_DATA_HOME` and `$XDG_STATE_HOME` select the XDG location only when
    they name an absolute directory."""

    def test_an_absolute_xdg_data_home_selects_the_xdg_location(self):
        with mock.patch.object(service.kanban_config, "is_macos", lambda: False):
            with mock.patch.dict(os.environ, {"XDG_DATA_HOME": "/data"}):
                self.assertEqual(
                    service.default_service_root(), Path("/data/kanban/mission-runner")
                )

    def test_an_unset_empty_or_relative_xdg_data_home_selects_the_home_spelling(self):
        expected = self.account / ".local" / "share" / "kanban" / "mission-runner"
        with mock.patch.object(service.kanban_config, "is_macos", lambda: False):
            for value in (None, "", "relative/data"):
                with self.subTest(xdg_data_home=value):
                    environment = dict(os.environ)
                    environment.pop("XDG_DATA_HOME", None)
                    if value is not None:
                        environment["XDG_DATA_HOME"] = value
                    with mock.patch.dict(os.environ, environment, clear=True):
                        self.assertEqual(service.default_service_root(), expected)

    def test_an_absolute_xdg_state_home_selects_the_xdg_log_root(self):
        with mock.patch.object(service.kanban_config, "is_macos", lambda: False):
            with mock.patch.dict(os.environ, {"XDG_STATE_HOME": "/state"}):
                self.assertEqual(
                    service.log_root(), Path("/state/kanban/mission-runner")
                )

    def test_an_unset_empty_or_relative_xdg_state_home_selects_the_home_spelling(self):
        expected = self.account / ".local" / "state" / "kanban" / "mission-runner"
        with mock.patch.object(service.kanban_config, "is_macos", lambda: False):
            for value in (None, "", "relative/state"):
                with self.subTest(xdg_state_home=value):
                    environment = dict(os.environ)
                    environment.pop("XDG_STATE_HOME", None)
                    if value is not None:
                        environment["XDG_STATE_HOME"] = value
                    with mock.patch.dict(os.environ, environment, clear=True):
                        self.assertEqual(service.log_root(), expected)

    def test_the_macos_spellings_are_the_application_support_and_logs_trees(self):
        with mock.patch.object(service.kanban_config, "is_macos", lambda: True):
            self.assertEqual(
                service.default_service_root(),
                self.account
                / "Library"
                / "Application Support"
                / "kanban"
                / "mission-runner",
            )
            self.assertEqual(
                service.log_root(),
                self.account / "Library" / "Logs" / "kanban" / "mission-runner",
            )

    def test_the_installed_job_carries_the_context_its_paths_were_resolved_under(self):
        # A systemd user manager does not necessarily export the XDG base
        # directories the operator installed under, and a job started without
        # them would resolve `~/.local` instead -- writing a status document
        # nothing reads, and logs somewhere its own unit does not point.
        self.install()
        definition = json.loads(
            self.manager.definition_path(self.label()).read_text(encoding="utf-8")
        )
        environment = definition["environment"]
        for name in service.PATH_VARIABLES:
            self.assertEqual(environment[name], os.environ[name], name)
        self.assertEqual(environment["HOME"], str(self.account))
        self.assertIn(str(self.account / ".local" / "bin"), environment["PATH"])

    def test_an_unusable_xdg_value_is_left_out_rather_than_pinned(self):
        environment = dict(os.environ)
        environment["XDG_DATA_HOME"] = "relative/data"
        with mock.patch.dict(os.environ, environment, clear=True):
            definition = service.service_definition(self.job(), self.install_dir)
        self.assertNotIn("XDG_DATA_HOME", definition.environment)

    def test_a_run_started_with_a_custom_root_and_an_empty_environment_finds_it(self):
        # The whole point of carrying those variables: the manager's own
        # environment is otherwise empty, and the run still has to resolve the
        # runtime this installation describes.
        self.install()
        service.start_service(self.job(), self.install_dir)
        snapshot = service.status_snapshot(self.job())
        # The child resolved its own runtime from the environment the
        # definition carried, with nothing else to go on, and this process
        # finds the document there: that agreement is the whole point of
        # carrying the variables.
        self.assertIn(snapshot["state"], service.LIVE_STATES)
        self.assertTrue(self.job().status_path.is_file())
        self.assertEqual(snapshot["active_repo"], str(self.repo))
        self.assertTrue(
            str(self.job().status_path).startswith(str(self.root)),
            "the started run wrote outside this fixture's temporary root",
        )


class EnvironmentRuleSystemdTests(SystemdShapeMixin, EnvironmentRuleTests):
    pass


# ---------------------------------------------------------------------------
# Record repair
# ---------------------------------------------------------------------------


class RecordRepairTests(InstallerFixture):
    other_identity = "acme/gadgets"

    def setUp(self):
        super().setUp()
        self.other_repo = self.checkout("gadgets", "git@github.com:acme/gadgets.git")

    def test_a_missing_record_is_repaired_by_reinstalling(self):
        self.install()
        record = service.discovery_record_path()
        record.unlink()
        self.install()
        self.assertIn(self.identity, self.entries())

    def test_a_stale_entry_is_repaired_and_siblings_survive(self):
        self.install()
        self.install(repo=self.other_repo)
        record = service.discovery_record_path()
        document = json.loads(record.read_text(encoding="utf-8"))
        document["repositories"][self.identity]["install_dir"] = str(
            self.root / "gone"
        )
        document["repositories"][self.identity]["plist_path"] = "/nowhere.plist"
        record.write_text(json.dumps(document), encoding="utf-8")
        self.install()
        entries = self.entries()
        self.assertEqual(entries[self.identity]["install_dir"], str(self.install_dir))
        self.assertIn(self.other_identity, entries)
        self.assertEqual(
            entries[self.other_identity]["install_dir"], str(self.install_dir)
        )
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink(), name)

    def test_an_unreadable_record_is_rebuilt_rather_than_left_undiscoverable(self):
        self.install()
        record = service.discovery_record_path()
        record.write_bytes(b"\xff\xfe not json at all")
        self.install()
        self.assertIn(self.identity, self.entries())

    def test_a_reinstall_under_the_other_backend_leaves_one_backends_keys(self):
        self.install()
        other_shape = "systemd" if self.shape == "launchd" else "launchd"
        self.manager.shape = other_shape
        self.install()
        entry = self.entries()[self.identity]
        present = {key for key in service_manager.RECORD_KEYS if key in entry}
        self.assertEqual(entry["backend"], f"fake-{other_shape}")
        if other_shape == "launchd":
            self.assertEqual(
                present, {"backend", "launchd_label", "plist_path"}
            )
        else:
            self.assertEqual(present, {"backend", "systemd_unit", "unit_path"})
        # Everything the install did not restate survives the discard.
        self.assertEqual(entry["install_dir"], str(self.install_dir))

    def test_a_directory_where_the_record_belongs_is_refused_by_name(self):
        record = service.discovery_record_path()
        record.mkdir(parents=True)
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn(str(record), str(raised.exception))
        self.assertTrue(record.is_dir())
        self.assert_no_fallthrough(record)

    def test_a_symlinked_record_is_refused_by_name(self):
        record = service.discovery_record_path()
        record.parent.mkdir(parents=True, exist_ok=True)
        target = self.root / "somewhere-else.json"
        target.write_text("{}", encoding="utf-8")
        record.symlink_to(target)
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn(str(record), str(raised.exception))
        self.assertTrue(record.is_symlink())
        self.assertEqual(target.read_text(encoding="utf-8"), "{}")
        self.assert_no_fallthrough(record)

    def test_the_dry_run_refuses_an_unsafe_record_too(self):
        record = service.discovery_record_path()
        record.mkdir(parents=True)
        with self.assertRaises(installer.InstallError):
            self.install(dry_run=True)
        # Nothing was written, so a refusal reached before the first write
        # leaves the installation exactly as it was.
        for name in installer.LINKED_MODULES:
            self.assertFalse(os.path.lexists(self.install_dir / name), name)
        self.assertEqual(self.manager.call_names(), [])

    def assert_no_fallthrough(self, refused):
        """The probe selected `refused` because it was occupied, so the other
        candidate must not have been written instead."""
        xdg = service._xdg_service_root() / service.RECORD_NAME
        library = service._macos_service_root() / service.RECORD_NAME
        other = library if refused == xdg else xdg
        self.assertFalse(os.path.lexists(other), f"{other} was written instead")


class RecordRepairSystemdTests(SystemdShapeMixin, RecordRepairTests):
    pass


class LinkDependencyTests(InstallerFixture):
    """Which jobs run from an installation's links, from two witnesses.

    The discovery record is a copy of that answer kept somewhere else: it can be
    absent while every job it named is still loaded, it can be corrupt, it can
    decode partially, and repairing it rebuilds it around the one entry the
    repairer knows about. The markers beside the links cannot be lost that way
    -- but the directory holding them can be deleted, and the next install
    rebuilds it around that install alone, which is the same laundering in the
    direction the record survives. Every one of those reads as "nothing depends
    on these" to whichever witness it damages, so neither decides a removal on
    its own.
    """

    other_identity = "acme/gadgets"
    third_identity = "acme/gizmos"

    def setUp(self):
        super().setUp()
        self.other_repo = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.third_repo = self.checkout("gizmos", "git@github.com:acme/gizmos.git")

    def corrupt_record(self):
        service.discovery_record_path().write_bytes(b"\xff\xfe not json at all")

    def delete_record(self):
        record = service.discovery_record_path()
        if record.exists():
            record.unlink()

    def empty_record(self):
        service.discovery_record_path().write_text(
            '{"repositories": {}}', encoding="utf-8"
        )

    def partial_record(self):
        service.discovery_record_path().write_text("{}", encoding="utf-8")

    def assert_links_present(self):
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink(), name)
            self.assertTrue((self.install_dir / name).resolve().is_file(), name)

    def assert_links_absent(self):
        for name in installer.LINKED_MODULES:
            self.assertFalse(os.path.lexists(self.install_dir / name), name)

    # -- the directory is the authority ------------------------------------

    def test_an_install_claims_the_directory_and_an_uninstall_withdraws_it(self):
        self.install()
        self.assertEqual(
            service.link_dependants(self.install_dir), [self.identity]
        )
        self.install(repo=self.other_repo)
        self.assertEqual(
            service.link_dependants(self.install_dir),
            sorted([self.identity, self.other_identity]),
        )
        self.uninstall()
        self.assertEqual(
            service.link_dependants(self.install_dir), [self.other_identity]
        )

    def test_a_directory_that_was_never_installed_into_cannot_say(self):
        # Fail closed, and free: there are no links there to remove either.
        self.assertIsNone(service.link_dependants(self.root / "never"))
        self.assertFalse(installer.may_remove_links(self.root / "never"))

    def test_a_marker_that_cannot_be_read_is_still_a_dependant(self):
        self.install()
        self.install(repo=self.other_repo)
        marker = service.dependant_marker(self.install_dir, self.other_identity)
        marker.write_bytes(b"\xff\xfe")
        # Named by its file name rather than discounted -- and counted once,
        # not twice, beside the identity the record gives for the same
        # repository.
        self.assertEqual(len(service.link_dependants(self.install_dir)), 2)
        self.uninstall()
        self.assert_links_present()

    # -- every shape of record the reviewer's cases reach -------------------

    def test_no_state_of_the_record_lets_a_siblings_links_go(self):
        for damage in (
            self.corrupt_record,
            self.delete_record,
            self.empty_record,
            self.partial_record,
        ):
            with self.subTest(record=damage.__name__):
                self.install()
                self.install(repo=self.other_repo)
                damage()
                result = self.uninstall()
                self.assertTrue(result["uninstalled"])
                self.assert_links_present()
                self.assertTrue(
                    self.manager.is_loaded(self.label(self.other_identity))
                )
                # And the directory still says who is left, whatever the record
                # has to say about it.
                self.assertEqual(
                    service.link_dependants(self.install_dir),
                    [self.other_identity],
                )
                self.uninstall(repo=self.other_repo)
                self.assert_links_absent()

    def test_sequential_uninstalls_after_corruption_keep_the_last_job_running(self):
        # The reviewer's multi-sibling case. Removing one repository rewrites an
        # undecodable record as a small, perfectly readable table -- so a reader
        # that asked the record would keep the links on the first uninstall and
        # take them on the second, while the third job was still loaded.
        for repo in (self.repo, self.other_repo, self.third_repo):
            self.install(repo=repo)
        self.corrupt_record()
        self.uninstall()
        self.assert_links_present()
        self.uninstall(repo=self.other_repo)
        self.assert_links_present()
        self.assertTrue(self.manager.is_loaded(self.label(self.third_identity)))
        self.assertEqual(
            service.link_dependants(self.install_dir), [self.third_identity]
        )
        # And the last one out still takes them.
        self.uninstall(repo=self.third_repo)
        self.assert_links_absent()

    def test_repairing_the_record_does_not_forget_a_sibling(self):
        # Reinstalling rebuilds `repositories` around the repository being
        # repaired, which is the whole of what the record then says. The
        # directory goes on naming both.
        for damage in (self.corrupt_record, self.delete_record):
            with self.subTest(record=damage.__name__):
                self.install()
                self.install(repo=self.other_repo)
                damage()
                self.install()
                self.assertEqual(
                    sorted(self.entries()), [self.identity], "the record forgot it"
                )
                self.assertEqual(
                    service.link_dependants(self.install_dir),
                    sorted([self.identity, self.other_identity]),
                )
                self.uninstall()
                self.assert_links_present()
                self.assertTrue(
                    self.manager.is_loaded(self.label(self.other_identity))
                )
                self.uninstall(repo=self.other_repo)
                self.assert_links_absent()

    def test_the_dry_run_reports_the_same_retention(self):
        self.install()
        self.install(repo=self.other_repo)
        self.corrupt_record()
        planned = self.uninstall(dry_run=True)
        self.assertEqual(
            {name: link["result"] for name, link in planned["links"].items()},
            {name: "kept" for name in installer.LINKED_MODULES},
        )
        self.assertEqual(planned["dependent_repositories"], [self.other_identity])

    def test_the_last_job_out_still_takes_the_links(self):
        # The positive control every retention above needs: "nothing runs from
        # these" has to keep meaning what it says.
        self.install()
        result = self.uninstall()
        self.assertEqual(result["dependent_repositories"], [])
        self.assert_links_absent()

    def test_a_relocation_takes_back_only_what_it_left(self):
        self.install()
        self.install(repo=self.other_repo)
        elsewhere = self.root / "elsewhere"
        self.install(install_dir=elsewhere)
        self.assertEqual(
            service.link_dependants(self.install_dir), [self.other_identity]
        )
        self.assertEqual(service.link_dependants(elsewhere), [self.identity])
        self.assert_links_present()
        for name in installer.LINKED_MODULES:
            self.assertTrue((elsewhere / name).is_symlink(), name)

    def test_a_relocation_out_of_a_directory_nobody_else_needs_clears_it(self):
        self.install()
        elsewhere = self.root / "elsewhere"
        self.install(install_dir=elsewhere)
        self.assertEqual(service.link_dependants(self.install_dir), [])
        self.assert_links_absent()

    def test_a_relocation_proves_the_old_release_before_committing(self):
        # `plan_released_links` does not reach this: it reads which repositories
        # depend on the old directory, which a marker that is a directory
        # answers perfectly well -- only the withdrawal fails, and by then the
        # record names the new directory alone and nothing can find the old one
        # to clean it.
        self.install()
        marker = service.dependant_marker(self.install_dir, self.identity)
        marker.unlink()
        marker.mkdir()

        elsewhere = self.root / "elsewhere"
        with self.assertRaises(
            (installer.InstallError, service.ServiceError)
        ) as raised:
            self.install(install_dir=elsewhere)
        self.assertIn(str(marker), str(raised.exception))
        # Nothing moved: the record, the links and the job are where they were.
        self.assertEqual(
            service.installed_install_dir(self.identity), str(self.install_dir)
        )
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink(), name)
            self.assertFalse(os.path.lexists(elsewhere / name), name)

    def test_the_relocation_dry_run_refuses_it_too(self):
        self.install()
        marker = service.dependant_marker(self.install_dir, self.identity)
        marker.unlink()
        marker.mkdir()
        with self.assertRaises((installer.InstallError, service.ServiceError)):
            self.install(install_dir=self.root / "elsewhere", dry_run=True)

    def test_a_relocation_with_a_clear_old_directory_still_moves(self):
        # The positive control the refusal above needs.
        self.install()
        elsewhere = self.root / "elsewhere"
        result = self.install(install_dir=elsewhere)
        self.assertIsNone(result["retained_install_dir"])
        self.assertEqual(service.marker_dependants(self.install_dir), [])
        self.assertEqual(service.marker_dependants(elsewhere), [self.identity])

    def test_a_release_that_the_filesystem_refuses_reports_what_it_did(self):
        # An ordinary `PermissionError` from one `unlink`, which no preflight
        # can rule out. The move has already happened by then, so reporting a
        # failed install would tell an operator that none of it landed -- while
        # leaving them no name for the directory that still needs clearing.
        self.install()
        elsewhere = self.root / "elsewhere"
        refused = installer.LINKED_MODULES[1]
        original = installer.remove_symlink

        def sometimes_refused(destination, name):
            if name == refused:
                raise PermissionError(13, "Permission denied", str(destination))
            return original(destination, name)

        with mock.patch.object(installer, "remove_symlink", sometimes_refused):
            result = self.install(install_dir=elsewhere)

        # A completed relocation, said plainly.
        self.assertTrue(result["installed"])
        self.assertEqual(result["relocated_from"], str(self.install_dir))
        self.assertEqual(service.installed_install_dir(self.identity), str(elsewhere))
        self.assertEqual(result["retained_install_dir"], str(self.install_dir))
        self.assertIn("Permission denied", result["retained_reason"])

        # And each link says what became of *it*, not what was planned for all
        # of them: the one that was refused is still there, and so is anything
        # after it.
        released = result["released_links"]
        self.assertEqual(released[refused]["result"], "kept")
        for name, link in released.items():
            destination = Path(link["destination"])
            with self.subTest(module=name, result=link["result"]):
                if link["result"] == "removed":
                    self.assertFalse(os.path.lexists(destination))
                else:
                    self.assertTrue(os.path.lexists(destination))

    def test_a_release_that_cannot_account_for_a_link_names_the_directory(self):
        # `remove_symlink` refuses to delete what it cannot show is Kanban's
        # own, which is right -- and leaves the old directory holding something
        # that nothing will look at again, because the claim that made it
        # findable has just been withdrawn. Reported per occupant, because the
        # repair depends on what each one turns out to be.
        foreign = self.root / "not-kanbans.py"
        foreign.write_text("# somebody else's\n", encoding="utf-8")
        cases = {
            "foreign": lambda destination: destination.symlink_to(foreign),
            "dangling": lambda destination: destination.symlink_to(
                self.root / "gone.py"
            ),
            "ordinary file": lambda destination: destination.write_text(
                "mine\n", encoding="utf-8"
            ),
        }
        for label, occupy in cases.items():
            with self.subTest(occupant=label):
                self.install()
                name = installer.LINKED_MODULES[0]
                destination = self.install_dir / name
                destination.unlink()
                occupy(destination)

                elsewhere = self.root / f"elsewhere-{label.replace(' ', '-')}"
                result = self.install(install_dir=elsewhere)

                # A completed relocation that names what it could not clear.
                self.assertTrue(result["installed"])
                self.assertEqual(
                    result["retained_install_dir"], str(self.install_dir)
                )
                self.assertIn(str(destination), result["retained_reason"])
                self.assertEqual(result["released_links"][name]["result"], "kept")
                self.assertTrue(os.path.lexists(destination))
                # And the rest went, so this is the occupant's own problem
                # rather than the whole release failing.
                for other in installer.LINKED_MODULES[1:]:
                    self.assertEqual(
                        result["released_links"][other]["result"], "removed"
                    )

                destination.unlink()
                self.uninstall(install_dir=elsewhere)

    def test_links_kept_for_a_sibling_are_not_reported_as_left_behind(self):
        # The other reason a link says `kept`, and the one that is not a
        # problem: a sibling's own claim kept them, and that sibling's uninstall
        # will find this directory and take them.
        self.install()
        self.install(repo=self.other_repo)
        result = self.install(install_dir=self.root / "elsewhere")
        self.assertEqual(
            {link["result"] for link in result["released_links"].values()},
            {"kept"},
        )
        self.assertIsNone(result["retained_install_dir"])
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            installer.print_plan(result, uninstalling=False)
        self.assertNotIn("Left behind", printed.getvalue())

    def test_a_release_with_nothing_in_the_way_reports_nothing_left(self):
        self.install()
        result = self.install(install_dir=self.root / "elsewhere")
        self.assertEqual(
            {link["result"] for link in result["released_links"].values()},
            {"removed"},
        )
        self.assertIsNone(result["retained_install_dir"])

    def test_the_retained_directory_is_named_in_the_printed_plan(self):
        self.install()
        elsewhere = self.root / "elsewhere"

        def always_refused(destination, name):
            raise PermissionError(13, "Permission denied", str(destination))

        with mock.patch.object(installer, "remove_symlink", always_refused):
            result = self.install(install_dir=elsewhere)
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            installer.print_plan(result, uninstalling=False)
        output = printed.getvalue()
        self.assertIn(str(self.install_dir), output)
        self.assertIn("Permission denied", output)
        for name in installer.LINKED_MODULES:
            self.assertIn(str(self.install_dir / name), output)

    # -- neither witness is trusted on its own ------------------------------

    def test_a_rebuilt_markers_directory_does_not_forget_a_sibling(self):
        # The markers launder the same way the record does: delete the directory
        # and the next install rebuilds it around that install alone. The record
        # still names both, and a claim in either witness is a claim.
        self.install()
        self.install(repo=self.other_repo)
        shutil.rmtree(service.dependants_dir(self.install_dir))
        self.install()
        self.assertEqual(
            service.marker_dependants(self.install_dir), [self.identity]
        )
        self.assertEqual(
            sorted(service.link_dependants(self.install_dir)),
            sorted([self.identity, self.other_identity]),
        )
        self.uninstall()
        self.assert_links_present()
        self.assertTrue(self.manager.is_loaded(self.label(self.other_identity)))
        self.uninstall(repo=self.other_repo)
        self.assert_links_absent()

    def test_an_absent_markers_directory_alone_keeps_the_links(self):
        self.install()
        self.install(repo=self.other_repo)
        shutil.rmtree(service.dependants_dir(self.install_dir))
        self.assertIsNone(service.marker_dependants(self.install_dir))
        self.uninstall()
        self.assert_links_present()

    def test_only_both_witnesses_gone_leaves_nothing_to_be_right_from(self):
        # Stated rather than left implicit: there is no third place this is
        # written, so destroying both is the one case this cannot survive.
        self.install()
        shutil.rmtree(service.dependants_dir(self.install_dir))
        self.corrupt_record()
        self.assertIsNone(service.link_dependants(self.install_dir))
        self.assertFalse(installer.may_remove_links(self.install_dir))

    def test_an_unsafe_marker_occupant_is_a_dependant_rather_than_a_skip(self):
        # A directory, a dangling link, bytes that are not UTF-8: what such an
        # occupant means is unknowable, and the only safe reading of "somebody
        # put something here under a repository's slug" is that the repository
        # is claiming this directory.
        slug = service.repository_slug(self.other_identity)
        for make in (self.unsafe_directory, self.unsafe_dangling_link, self.unsafe_bytes):
            with self.subTest(occupant=make.__name__):
                self.install()
                self.install(repo=self.other_repo)
                # The record is gone too, so the marker is the only witness left
                # and its reading is the whole of the answer.
                self.corrupt_record()
                marker = service.dependant_marker(
                    self.install_dir, self.other_identity
                )
                self.clear(marker)
                make(marker)
                self.assertIn(slug, service.marker_dependants(self.install_dir))
                self.uninstall()
                self.assert_links_present()
                self.assertTrue(
                    self.manager.is_loaded(self.label(self.other_identity))
                )
                self.clear(marker)
                self.uninstall(repo=self.other_repo)

    def clear(self, path):
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        elif os.path.lexists(path):
            path.unlink()

    def unsafe_directory(self, marker):
        marker.mkdir(parents=True)

    def unsafe_dangling_link(self, marker):
        marker.symlink_to(self.root / "gone")

    def unsafe_bytes(self, marker):
        marker.write_bytes(b"\xff\xfe")

    def test_a_job_loaded_through_the_controller_alone_still_claims_it(self):
        # The installer is not the only route that loads a job: the controller
        # exposes the same operation, and a job loaded through it into somebody
        # else's install directory has to be recorded as running from those
        # links or the next uninstall takes them.
        self.install()
        job = service.job_for_identity(self.other_repo, self.other_identity)
        service.install_job(job, self.install_dir)
        self.assertIn(
            self.other_identity, service.marker_dependants(self.install_dir)
        )
        # With the record gone, the marker is the only witness left -- which is
        # exactly the state this claim has to survive.
        self.corrupt_record()
        self.uninstall()
        self.assert_links_present()
        self.assertTrue(self.manager.is_loaded(self.label(self.other_identity)))

    def test_the_controller_withdraws_the_claim_it_made(self):
        self.install()
        job = service.job_for_identity(self.other_repo, self.other_identity)
        service.install_job(job, self.install_dir)
        service.uninstall_job(job, self.install_dir)
        self.assertEqual(
            service.marker_dependants(self.install_dir), [self.identity]
        )
        self.uninstall()
        self.assert_links_absent()

    def test_a_marker_naming_another_repository_is_read_as_its_file_name(self):
        # Trusting the contents alone would be worse than ignoring them: an
        # uninstall discounts its own claim by slug, so a marker holding a
        # second repository's identity would be discounted with it and the
        # directory would look empty.
        self.install()
        self.install(repo=self.other_repo)
        self.corrupt_record()
        service.dependant_marker(self.install_dir, self.other_identity).write_text(
            self.identity + "\n", encoding="utf-8"
        )
        self.assertIn(
            service.repository_slug(self.other_identity),
            service.marker_dependants(self.install_dir),
        )
        self.uninstall()
        self.assert_links_present()
        self.assertTrue(self.manager.is_loaded(self.label(self.other_identity)))

    def test_a_symlinked_markers_directory_is_refused_by_name(self):
        # `mkdir(exist_ok=True)` and an ordinary write both follow a link, so a
        # link standing where this directory belongs would redirect every marker
        # into somebody else's tree.
        victim = self.root / "victim"
        victim.mkdir()
        self.install_dir.mkdir(parents=True)
        service.dependants_dir(self.install_dir).symlink_to(victim)
        with self.assertRaises(
            (installer.InstallError, service.ServiceError)
        ) as raised:
            self.install()
        self.assertIn(
            str(service.dependants_dir(self.install_dir)), str(raised.exception)
        )
        self.assertEqual(list(victim.iterdir()), [])
        self.assertTrue(service.dependants_dir(self.install_dir).is_symlink())

    def test_a_symlinked_marker_is_taken_back_rather_than_written_through(self):
        self.install()
        victim = self.root / "victim.txt"
        victim.write_text("mine\n", encoding="utf-8")
        marker = service.dependant_marker(self.install_dir, self.identity)
        marker.unlink()
        marker.symlink_to(victim)
        self.install()
        self.assertEqual(victim.read_text(encoding="utf-8"), "mine\n")
        self.assertFalse(marker.is_symlink())
        self.assertEqual(marker.read_text(encoding="utf-8").strip(), self.identity)

    def test_a_marker_is_private_to_this_account(self):
        self.install()
        marker = service.dependant_marker(self.install_dir, self.identity)
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)

    def test_a_symlinked_markers_parent_is_refused_before_anything_is_removed(self):
        # `unlink` removes a name rather than following it, but the name is
        # resolved through every directory above -- so a redirected parent would
        # delete a same-named file in somebody else's tree. Through the
        # controller's own uninstall, which is the route that does not pass the
        # installer's earlier reads.
        self.install()
        victim_dir = self.root / "victim"
        victim_dir.mkdir()
        victim = victim_dir / service.repository_slug(self.identity)
        victim.write_text("mine\n", encoding="utf-8")

        markers = service.dependants_dir(self.install_dir)
        shutil.rmtree(markers)
        markers.symlink_to(victim_dir)

        job = service.resolve_job(self.repo)
        with self.assertRaises(service.ServiceError) as raised:
            service.uninstall_job(job, self.install_dir)
        self.assertIn(str(markers), str(raised.exception))
        # Nothing outside the installation was touched, and the job is whole.
        self.assertEqual(victim.read_text(encoding="utf-8"), "mine\n")
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertIn(self.identity, self.entries())

    def test_a_directory_valued_marker_is_refused_before_anything_is_removed(self):
        # `unlink` cannot remove a directory, and discovering that after the
        # manager has forgotten the job leaves a partial uninstall the dry run
        # said would succeed.
        self.install()
        marker = service.dependant_marker(self.install_dir, self.identity)
        marker.unlink()
        marker.mkdir()

        job = service.resolve_job(self.repo)
        with self.assertRaises(service.ServiceError) as raised:
            service.uninstall_job(job, self.install_dir)
        self.assertIn(str(marker), str(raised.exception))
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertIn(self.identity, self.entries())
        # And the dry run agrees, rather than promising a removal that fails.
        with self.assertRaises(service.ServiceError):
            service.uninstall_plan(job, self.install_dir)


class LinkDependencySystemdTests(SystemdShapeMixin, LinkDependencyTests):
    pass


class StartCommandTests(InstallerFixture):
    """What a finished install tells the operator to run next."""

    def install_at(self, repo, install_dir):
        return installer.install(
            repo, install_dir, asset_root=repo, config_path=None, dry_run=False
        )

    def test_the_start_command_survives_spaces_and_names_the_identity(self):
        # This installation's own default path contains a space on macOS --
        # `Library/Application Support` -- and a checkout may contain one
        # anywhere, so a command pasted into a shell has to be quoted.
        repo = self.checkout("spaced repo", "git@github.com:acme/spaced.git")
        install_dir = self.root / "installed dir"
        result = self.install_at(repo, install_dir)

        argv = shlex.split(installer.start_command(result))
        self.assertEqual(argv[0], "env")
        # Bound to this installation's directory, because the controller
        # resolves its own through `job_install_dir`, which gives the
        # environment precedence over the record -- and a `start` refuses to
        # move an installation rather than performing one.
        self.assertEqual(
            argv[1], f"{service.INSTALL_DIR_ENV}={install_dir}"
        )
        self.assertEqual(argv[2], "python3")
        self.assertEqual(argv[3], str(install_dir / service.CONTROLLER_NAME))
        self.assertEqual(argv[4], "start")
        self.assertEqual(argv[argv.index("--path") + 1], str(repo))
        # Bound to the identity this install recorded rather than left to be
        # re-derived: the shared configuration's `remote_name` decides which
        # repository a checkout resolves to, so a command without `--repo`
        # would quietly act on a different job if that setting changed.
        self.assertEqual(argv[argv.index("--repo") + 1], "acme/spaced")

        # And it is a command the controller's own parser accepts.
        parsed = service.parse_args(argv[4:])
        self.assertEqual(parsed.operation, "start")
        self.assertEqual(parsed.path, str(repo))
        self.assertEqual(parsed.repo, "acme/spaced")

    def test_the_printed_plan_carries_that_command(self):
        result = self.install()
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            installer.print_plan(result, uninstalling=False)
        self.assertIn(installer.start_command(result), printed.getvalue())
        self.assertNotIn("from Kanban", printed.getvalue())

    def test_a_start_refuses_to_move_an_installation(self):
        # `job_install_dir` gives the environment precedence over the record,
        # which is right for a controller launched out of a custom installation
        # and wrong as a way to move one: a start refreshes the definition and
        # the record entry, and only the installer releases the marker and the
        # links the old directory is left holding.
        self.install()
        elsewhere = self.root / "elsewhere"
        job = service.resolve_job(self.repo)
        with self.assertRaises(service.ServiceError) as raised:
            service.start_service(job, elsewhere)
        message = str(raised.exception)
        self.assertIn(str(self.install_dir), message)
        self.assertIn(str(elsewhere), message)
        self.assertIn(service.INSTALL_DIR_ENV, message)
        # Refused without moving anything.
        self.assertEqual(
            service.installed_install_dir(self.identity), str(self.install_dir)
        )
        self.assertEqual(
            service.marker_dependants(self.install_dir), [self.identity]
        )
        self.assertIsNone(service.marker_dependants(elsewhere))

    def test_the_printed_command_works_against_a_conflicting_environment(self):
        # An install made with an explicit --install-dir while the variable
        # names somewhere else: the command has to select the installation it
        # was printed for, or the shell it is pasted into refuses it.
        elsewhere = self.root / "elsewhere"
        result = self.install_at(self.repo, self.install_dir)
        argv = shlex.split(installer.start_command(result))
        self.assertEqual(
            argv[1], f"{service.INSTALL_DIR_ENV}={self.install_dir}"
        )
        with mock.patch.dict(os.environ, {service.INSTALL_DIR_ENV: str(elsewhere)}):
            # What the ambient variable alone would have selected.
            job = service.resolve_job(self.repo)
            self.assertEqual(service.job_install_dir(job), elsewhere)
            with self.assertRaises(service.ServiceError):
                service.start_service(job, service.job_install_dir(job))
            # And what the printed command selects instead.
            with mock.patch.dict(
                os.environ, {service.INSTALL_DIR_ENV: argv[1].split("=", 1)[1]}
            ):
                job = service.resolve_job(self.repo)
                self.assertEqual(service.job_install_dir(job), self.install_dir)
                started = service.start_service(job, service.job_install_dir(job))
                self.assertTrue(started["started"])


class StartCommandSystemdTests(SystemdShapeMixin, StartCommandTests):
    pass


class ControllerRouteTests(InstallerFixture):
    """A controller command pointed somewhere the record does not name.

    `job_install_dir` gives `KANBAN_MISSION_RUNNER_INSTALL_DIR` precedence over
    the record, which is right for a controller launched out of a custom
    installation and wrong as a way to move one: only the dedicated installer
    takes back the claim and the links the old directory is left holding.
    """

    def elsewhere(self):
        other = self.root / "elsewhere"
        other.mkdir(exist_ok=True)
        return other

    def assert_installation_intact(self):
        self.assertEqual(
            service.installed_install_dir(self.identity), str(self.install_dir)
        )
        self.assertEqual(
            service.marker_dependants(self.install_dir), [self.identity]
        )
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink(), name)
        self.assertTrue(self.manager.is_loaded(self.label()))

    def test_an_uninstall_through_a_conflicting_override_is_refused(self):
        self.install()
        other = self.elsewhere()
        with mock.patch.dict(os.environ, {service.INSTALL_DIR_ENV: str(other)}):
            job = service.resolve_job(self.repo)
            self.assertEqual(service.job_install_dir(job), other)
            with self.assertRaises(service.ServiceError) as raised:
                service.uninstall_job(job)
        message = str(raised.exception)
        self.assertIn(str(self.install_dir), message)
        self.assertIn(str(other), message)
        self.assert_installation_intact()
        self.assertIsNone(service.marker_dependants(other))

    def test_an_install_through_a_conflicting_override_is_refused(self):
        self.install()
        other = self.elsewhere()
        environment = {
            **os.environ,
            "FIXTURE_SERVICE_MANAGER": str(self.manager.root),
            "FIXTURE_TOOLS": str(TOOLS_DIR),
            "FIXTURE_SHAPE": self.shape,
            service.INSTALL_DIR_ENV: str(other),
        }
        proc = subprocess.run(
            [
                sys.executable,
                str(self.wrapper),
                str(self.install_dir),
                str(self.account),
                "controller",
                "install",
                "--path",
                str(self.repo),
                "--json",
            ],
            capture_output=True,
            text=True,
            timeout=90,
            env=environment,
        )
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn(str(self.install_dir), proc.stderr)
        self.assertIn(str(other), proc.stderr)
        self.assert_installation_intact()

    def test_the_uninstall_dry_run_refuses_the_same_conflict(self):
        # A plan that described a removal the command itself refuses is a plan
        # of work that cannot happen.
        self.install()
        other = self.elsewhere()
        with mock.patch.dict(os.environ, {service.INSTALL_DIR_ENV: str(other)}):
            with self.assertRaises(service.ServiceError) as raised:
                service.uninstall_plan(
                    service.resolve_job(self.repo), service.job_install_dir(
                        service.resolve_job(self.repo)
                    )
                )
        self.assertIn(str(other), str(raised.exception))
        self.assert_installation_intact()

    def test_the_uninstall_dry_run_command_refuses_it_too(self):
        self.install()
        other = self.elsewhere()
        proc = subprocess.run(
            [
                sys.executable,
                str(self.wrapper),
                str(self.install_dir),
                str(self.account),
                "controller",
                "uninstall",
                "--path",
                str(self.repo),
                "--dry-run",
                "--json",
            ],
            capture_output=True,
            text=True,
            timeout=90,
            env={
                **os.environ,
                "FIXTURE_SERVICE_MANAGER": str(self.manager.root),
                "FIXTURE_TOOLS": str(TOOLS_DIR),
                "FIXTURE_SHAPE": self.shape,
                service.INSTALL_DIR_ENV: str(other),
            },
        )
        self.assertEqual(proc.returncode, 1, proc.stdout)
        self.assertIn(str(self.install_dir), proc.stderr)
        self.assertIn(str(other), proc.stderr)
        self.assert_installation_intact()

    def test_the_installer_may_still_relocate_on_purpose(self):
        # The exemption this refusal depends on: the one caller that does take
        # back what it leaves goes on being able to.
        self.install()
        other = self.elsewhere()
        result = self.install(install_dir=other)
        self.assertEqual(result["relocated_from"], str(self.install_dir))
        self.assertEqual(service.installed_install_dir(self.identity), str(other))
        self.assertEqual(service.marker_dependants(self.install_dir), [])
        self.assertEqual(service.marker_dependants(other), [self.identity])


class ControllerRouteSystemdTests(SystemdShapeMixin, ControllerRouteTests):
    pass


class SharedConfigurationContextTests(InstallerFixture):
    """The identity a job re-resolves at launch is the one its installer
    recorded, whatever environment the manager starts it with."""

    upstream_identity = "acme/upstream"

    def setUp(self):
        super().setUp()
        self.config_root = self.root / "xdg-config"
        (self.config_root / "kanban").mkdir(parents=True)
        (self.config_root / "kanban" / "config.toml").write_text(
            'remote_name = "upstream"\n', encoding="utf-8"
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(self.repo),
                "remote",
                "add",
                "upstream",
                "git@github.com:acme/upstream.git",
            ],
            check=True,
            capture_output=True,
            env={
                **os.environ,
                "GIT_CONFIG_GLOBAL": str(self.git_config),
                "GIT_CONFIG_NOSYSTEM": "1",
            },
        )
        patched = mock.patch.dict(
            os.environ, {"XDG_CONFIG_HOME": str(self.config_root)}
        )
        patched.start()
        self.addCleanup(patched.stop)

    def upstream_label(self):
        return self.manager.service_identifier(
            service.repository_slug(self.upstream_identity)
        )

    def test_the_install_records_the_identity_the_shared_config_selects(self):
        self.install()
        self.assertEqual(sorted(self.entries()), [self.upstream_identity])

    def test_the_definition_pins_the_configuration_root(self):
        self.install()
        definition = json.loads(
            self.manager.definition_path(self.upstream_label()).read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(
            definition["environment"][service.CONFIG_ROOT_VARIABLE],
            str(self.config_root.resolve()),
        )

    def test_a_job_started_from_a_cold_manager_resolves_that_same_identity(self):
        # The whole point. The fake manager runs the definition's argument
        # vector with the definition's environment and nothing else, exactly as
        # a real one does -- so a job whose configuration context did not
        # travel would re-resolve `origin`, refuse the `--repo` its own
        # definition records, and never start.
        self.install()
        job = service.resolve_job(self.repo)
        self.assertEqual(job.identity, self.upstream_identity)
        result = service.start_service(job, self.install_dir)
        self.assertTrue(result["started"])
        self.assertIn(result["state"], service.LIVE_STATES)
        self.assertEqual(
            service.status_snapshot(job)["repository"], self.upstream_identity
        )


class SharedConfigurationContextSystemdTests(
    SystemdShapeMixin, SharedConfigurationContextTests
):
    pass


class RecordSerializationTests(InstallerFixture):
    def test_concurrent_installs_keep_every_repositorys_entry(self):
        repositories = [
            self.checkout(f"repo{index}", f"git@github.com:acme/repo{index}.git")
            for index in range(4)
        ]
        errors = []

        def worker(repo):
            try:
                self.install(repo=repo)
            except Exception as exc:  # pragma: no cover - reported below
                errors.append(exc)

        threads = [threading.Thread(target=worker, args=(repo,)) for repo in repositories]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=120)
        self.assertEqual(errors, [])
        self.assertEqual(
            sorted(self.entries()),
            sorted(f"acme/repo{index}" for index in range(4)),
        )

    def test_a_record_written_by_this_service_is_private(self):
        self.install()
        record = service.discovery_record_path()
        self.assertEqual(record.stat().st_mode & 0o777, 0o600)


class RecordSerializationSystemdTests(SystemdShapeMixin, RecordSerializationTests):
    pass


class InstallationSerializationTests(InstallerFixture):
    """An install and an uninstall sharing one directory never interleave.

    The links are shared, so an uninstall decides whether they may go by
    reading which other repositories still depend on them. An install landing
    between that read and the removal would leave its own job pointing at links
    that were then deleted.
    """

    def test_an_install_racing_an_uninstall_never_loses_its_links(self):
        gadgets = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.install()
        failures = []

        original = installer.remove_symlink

        def slow_remove(destination, name):
            time.sleep(0.3)
            return original(destination, name)

        patched = mock.patch.object(installer, "remove_symlink", slow_remove)
        patched.start()
        self.addCleanup(patched.stop)

        def install_later():
            time.sleep(0.05)
            try:
                self.install(repo=gadgets)
            except Exception as error:  # pragma: no cover - reported below
                failures.append(error)

        second = threading.Thread(target=install_later)
        second.start()
        try:
            self.uninstall()
        finally:
            second.join(timeout=60)

        self.assertEqual(failures, [])
        # The invariant, whichever order they settled in: a repository with a
        # record entry has the links its job runs from.
        if "acme/gadgets" in self.entries():
            for name in installer.LINKED_MODULES:
                with self.subTest(module=name):
                    self.assertTrue(
                        (self.install_dir / name).is_symlink(),
                        f"{name} was removed under an installed job",
                    )
                    self.assertTrue((self.install_dir / name).resolve().is_file())


class InstallationSerializationSystemdTests(
    SystemdShapeMixin, InstallationSerializationTests
):
    pass


# How another process asks whether this identity's run lock is free, without
# holding it for any longer than the question takes. `flock` is held per open
# file description rather than per process, so a subprocess contends with this
# one exactly as a real foreground run would -- which is what makes this a
# question about the lock rather than about the asker.
RUN_LOCK_PROBE = """
import fcntl
import sys

handle = open(sys.argv[1], "a+", encoding="utf-8")
try:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit(1)
fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
raise SystemExit(0)
"""

# Another process inside a `run` for one identity, holding the lock the
# controller's own `run_lock` holds and writing the owner metadata a contender
# reports back.
RUN_LOCK_HOLDER = """
import fcntl
import json
import os
import sys
import time

handle = open(sys.argv[1], "a+", encoding="utf-8")
fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
handle.seek(0)
handle.truncate()
handle.write(json.dumps({"pid": os.getpid(), "mode": sys.argv[3]}))
handle.flush()
open(sys.argv[2], "w").write("ready")
time.sleep(300)
"""


class RunExclusionTests(InstallerFixture):
    """No window in a transition lets a foreground run begin beside the links
    it would execute.

    `job_transition` serializes managed transitions against each other, and a
    foreground `run` takes neither of its locks -- so the exclusion that keeps
    the two apart is this identity's run lock, and what matters is that the
    installer holds it for as long as it is mutating anything.
    """

    def lock_path(self):
        return service.run_lock_path(service.repository_slug(self.identity))

    def run_lock_free(self):
        """Whether another process could take this identity's run lock now."""
        path = self.lock_path()
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        proc = subprocess.run(
            [sys.executable, "-c", RUN_LOCK_PROBE, str(path)],
            capture_output=True,
            timeout=60,
        )
        self.assertIn(proc.returncode, (0, 1), proc.stderr)
        return proc.returncode == 0

    def hold_run_lock(self, *, mode="run"):
        path = self.lock_path()
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        ready = self.root / f"run-lock-ready-{mode}"
        proc = subprocess.Popen(
            [sys.executable, "-c", RUN_LOCK_HOLDER, str(path), str(ready), mode]
        )
        self.addCleanup(self.stop_holder, proc)
        wait_until(ready.exists, message="the run lock holder to take the lock")
        return proc

    def stop_holder(self, proc):
        if proc.poll() is None:
            proc.kill()
        proc.wait(timeout=30)

    def test_the_probe_finds_the_lock_free_when_nothing_holds_it(self):
        # The control this whole class rests on: a probe that always answered
        # "taken" would pass every case below while proving nothing.
        self.assertTrue(self.run_lock_free())
        self.install()
        self.assertTrue(self.run_lock_free())

    def test_a_run_cannot_begin_while_an_install_mutates_links(self):
        observed = []
        original = installer.install_symlink

        def observing(source, destination):
            observed.append(self.run_lock_free())
            return original(source, destination)

        with mock.patch.object(installer, "install_symlink", observing):
            self.install()
        self.assertEqual(len(observed), len(installer.LINKED_MODULES))
        self.assertNotIn(
            True,
            observed,
            "a foreground run could have begun while the links were written",
        )

    def test_a_run_cannot_begin_while_an_uninstall_removes_links(self):
        self.install()
        observed = []
        original = installer.remove_symlink

        def observing(destination, name):
            observed.append(self.run_lock_free())
            return original(destination, name)

        with mock.patch.object(installer, "remove_symlink", observing):
            self.uninstall()
        self.assertEqual(len(observed), len(installer.LINKED_MODULES))
        self.assertNotIn(
            True,
            observed,
            "a foreground run could have begun while the links were removed",
        )

    def test_an_install_refused_by_a_live_run_mutates_no_links(self):
        self.hold_run_lock()
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn("already running", str(raised.exception))
        for name in installer.LINKED_MODULES:
            self.assertFalse(os.path.lexists(self.install_dir / name), name)
        self.assertEqual(self.manager.call_names(), [])
        self.assertEqual(self.entries(), {})

    def test_an_uninstall_refused_by_a_live_run_removes_nothing(self):
        self.install()
        before = self.manager.call_names()
        self.hold_run_lock()
        with self.assertRaises(installer.InstallError) as raised:
            self.uninstall()
        self.assertIn("already running", str(raised.exception))
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink(), name)
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertIn(self.identity, self.entries())
        self.assertEqual(self.manager.call_names(), before)

    def test_a_run_cannot_begin_while_a_relocation_releases_links(self):
        # The release is the third mutation, and the one that used to sit
        # outside the exclusion: it runs after the record already names the new
        # directory, so a run beginning in that window would have found the old
        # installation's modules deleted underneath it -- and the install would
        # have reported them removed whether they were or not.
        self.install()
        observed = []
        original = installer.remove_symlink

        def observing(destination, name):
            observed.append(self.run_lock_free())
            return original(destination, name)

        with mock.patch.object(installer, "remove_symlink", observing):
            result = self.install(install_dir=self.root / "elsewhere")
        self.assertEqual(len(observed), len(installer.LINKED_MODULES))
        self.assertNotIn(
            True,
            observed,
            "a foreground run could have begun while the old links were released",
        )
        self.assertEqual(
            {name: link["result"] for name, link in result["released_links"].items()},
            {name: "removed" for name in installer.LINKED_MODULES},
        )

    def test_the_release_reports_only_what_it_really_did(self):
        # Both outcomes, against the filesystem rather than against the plan
        # that predicted them: reporting a link removed while it is still there
        # is how an orphaned installation stops being findable.
        other_repo = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.install()
        self.install(repo=other_repo)
        kept = self.install(install_dir=self.root / "elsewhere")
        self.assert_release_matches(kept)
        self.assertEqual(
            {link["result"] for link in kept["released_links"].values()}, {"kept"}
        )

        moved = installer.install(
            other_repo,
            self.root / "second",
            asset_root=other_repo,
            config_path=None,
            dry_run=False,
        )
        self.assert_release_matches(moved)
        self.assertEqual(
            {link["result"] for link in moved["released_links"].values()}, {"removed"}
        )

    def assert_release_matches(self, result):
        for name, link in result["released_links"].items():
            destination = Path(link["destination"])
            with self.subTest(module=name, result=link["result"]):
                if link["result"] == "removed":
                    self.assertFalse(os.path.lexists(destination))
                else:
                    self.assertTrue(os.path.lexists(destination))

    def test_a_contending_transition_is_named_as_one_rather_than_as_a_run(self):
        # A run and a transition take the very same lock, so the refusal has to
        # say which it lost to: "stop the mission runner" is the wrong repair
        # for an installer that is simply still going.
        self.hold_run_lock(mode="transition")
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        message = str(raised.exception)
        self.assertIn("An install or uninstall of", message)
        self.assertIn(self.identity, message)
        self.assertNotIn("is running", message)


class RunExclusionSystemdTests(SystemdShapeMixin, RunExclusionTests):
    pass


# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------


class DryRunTests(InstallerFixture):
    def test_a_dry_run_writes_nothing(self):
        result = self.install(dry_run=True)
        self.assertFalse(result["installed"])
        self.assertTrue(result["dry_run"])
        for name in installer.LINKED_MODULES:
            self.assertFalse(os.path.lexists(self.install_dir / name), name)
        self.assertEqual(self.manager.call_names(), [])
        self.assertEqual(self.entries(), {})

    def test_the_install_plan_is_what_the_install_performs(self):
        planned = self.install(dry_run=True)
        performed = self.install()
        self.assertEqual(planned["job"]["label"], performed["job"]["label"])
        self.assertEqual(planned["job"]["record"], performed["job"]["record"])
        self.assertEqual(planned["job"]["log_dir"], performed["job"]["log_dir"])
        self.assertEqual(
            {name: link["destination"] for name, link in planned["links"].items()},
            {name: link["destination"] for name, link in performed["links"].items()},
        )
        self.assertEqual(
            {name: link["result"] for name, link in planned["links"].items()},
            {name: link["result"] for name, link in performed["links"].items()},
        )

    def test_the_uninstall_plan_is_what_the_uninstall_performs(self):
        self.install()
        planned = self.uninstall(dry_run=True)
        performed = self.uninstall()
        self.assertEqual(planned["job"]["label"], performed["job"]["label"])
        self.assertEqual(
            planned["dependent_repositories"], performed["dependent_repositories"]
        )
        self.assertEqual(
            {name: link["result"] for name, link in planned["links"].items()},
            {name: link["result"] for name, link in performed["links"].items()},
        )


class DryRunSystemdTests(SystemdShapeMixin, DryRunTests):
    pass


class IdentityTests(InstallerFixture):
    def test_a_checkout_with_no_supported_github_remote_cannot_be_installed(self):
        elsewhere = self.checkout("elsewhere", "git@example.invalid:acme/thing.git")
        with self.assertRaises(installer.InstallError) as raised:
            self.install(repo=elsewhere, asset_root=self.repo)
        self.assertIn("supported GitHub repository", str(raised.exception))

    def test_a_divergent_controller_copy_is_refused(self):
        other = self.checkout("other", "git@github.com:acme/other.git")
        (other / "tools" / service.CONTROLLER_NAME).write_text(
            "# not this controller\n", encoding="utf-8"
        )
        with self.assertRaises(installer.InstallError) as raised:
            self.install(asset_root=other)
        self.assertIn("differs from the controller", str(raised.exception))
        self.assertEqual(self.manager.call_names(), [])

    def test_an_identical_copy_in_another_tree_is_accepted(self):
        archive = self.root / "archive"
        (archive / "tools").mkdir(parents=True)
        for name in installer.LINKED_MODULES:
            shutil.copy(TOOLS_DIR / name, archive / "tools" / name)
        result = self.install(asset_root=archive)
        self.assertTrue(result["installed"])
        self.assertEqual(
            os.path.realpath(self.install_dir / service.CONTROLLER_NAME),
            os.path.realpath(archive / "tools" / service.CONTROLLER_NAME),
        )

    def unmarked_archive(self, unmarked):
        """An asset root with every linked module present, one of which is not
        Kanban's own module of that name."""
        archive = self.root / "archive"
        (archive / "tools").mkdir(parents=True)
        for name in installer.LINKED_MODULES:
            shutil.copy(TOOLS_DIR / name, archive / "tools" / name)
        (archive / "tools" / unmarked).write_text(
            "# somebody else's module of this name\n", encoding="utf-8"
        )
        return archive

    def test_an_asset_root_supplying_an_unmarked_module_is_refused(self):
        # Present is not enough: the installed controller imports its siblings
        # out of the install directory, so an archive holding the genuine
        # controller beside an unmarked `kanban_config.py` would have the job
        # this installer loaded execute a file nobody could show was Kanban's.
        archive = self.unmarked_archive("kanban_config.py")
        with self.assertRaises(installer.InstallError) as raised:
            self.install(asset_root=archive)
        self.assertIn("not Kanban's own module", str(raised.exception))
        self.assertIn("kanban_config.py", str(raised.exception))
        # Refused before the first write.
        for name in installer.LINKED_MODULES:
            self.assertFalse(os.path.lexists(self.install_dir / name), name)
        self.assertEqual(self.manager.call_names(), [])
        self.assertEqual(self.entries(), {})

    def test_every_linked_module_is_checked_rather_than_the_first(self):
        for unmarked in installer.LINKED_MODULES:
            with self.subTest(module=unmarked):
                if unmarked == service.CONTROLLER_NAME:
                    # A controller that is not Kanban's own is caught by the
                    # parity check first, and refused for that reason instead.
                    continue
                archive = self.unmarked_archive(unmarked)
                with self.assertRaises(installer.InstallError) as raised:
                    self.install(asset_root=archive)
                self.assertIn(unmarked, str(raised.exception))
                shutil.rmtree(archive)

    def test_the_named_asset_root_refuses_it_before_anything_is_planned(self):
        # `main` resolves the asset root before `install` is entered, so the
        # refusal an operator sees names the tree rather than a link.
        archive = self.unmarked_archive("service_manager.py")
        with self.assertRaises(installer.InstallError) as raised:
            installer.asset_root(archive)
        self.assertIn("not Kanban's own module", str(raised.exception))

    def test_the_dry_run_refuses_an_unmarked_module_too(self):
        archive = self.unmarked_archive("kanban_config.py")
        with self.assertRaises(installer.InstallError):
            self.install(asset_root=archive, dry_run=True)

    def test_an_asset_root_missing_a_linked_module_is_not_installable(self):
        archive = self.root / "archive"
        (archive / "tools").mkdir(parents=True)
        shutil.copy(
            TOOLS_DIR / service.CONTROLLER_NAME,
            archive / "tools" / service.CONTROLLER_NAME,
        )
        with self.assertRaises(installer.InstallError) as raised:
            installer.asset_root(archive)
        self.assertIn("kanban_config.py", str(raised.exception))

    def test_every_module_the_controller_imports_is_linked(self):
        # Derived from the controller rather than restated beside it. A module
        # it imports and this installer does not link makes every real install
        # fail at import, and a restated list would go on agreeing with itself
        # after the import that broke it was added.
        self.install()
        self.assertEqual(
            set(installer.LINKED_MODULES),
            sibling_import_closure(service.CONTROLLER_NAME),
        )
        for name in installer.LINKED_MODULES:
            link = self.install_dir / name
            self.assertTrue(link.is_symlink(), name)
            self.assertTrue(
                installer.is_managed_asset(Path(os.path.realpath(link)), name), name
            )

    def test_a_job_is_never_written_without_an_installed_controller(self):
        with self.assertRaises(service.ServiceError) as raised:
            service.install_job(self.job(), self.install_dir)
        self.assertIn("install_mission_runner.py", str(raised.exception))

    def test_a_dangling_controller_link_is_refused_like_an_absent_one(self):
        self.install_dir.mkdir(parents=True)
        (self.install_dir / service.CONTROLLER_NAME).symlink_to(
            self.root / "gone.py"
        )
        with self.assertRaises(service.ServiceError):
            service.install_job(self.job(), self.install_dir)

    def test_an_install_refuses_a_users_broken_link_at_a_managed_path(self):
        self.install_dir.mkdir(parents=True)
        (self.install_dir / "kanban_config.py").symlink_to(self.root / "gone.py")
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn("does not exist", str(raised.exception))
        self.assertEqual(self.manager.call_names(), [])


class IdentitySystemdTests(SystemdShapeMixin, IdentityTests):
    pass


class HostRefusalTests(InstallerFixture):
    @contextlib.contextmanager
    def unmanaged_host(self):
        def refuse(*_arguments, **_options):
            raise service_manager.NoServiceManagerError(
                "No supported service manager found: a Kanban managed service "
                "needs either macOS launchd or a systemd user session."
            )

        with mock.patch.object(service_manager, "select_backend", refuse):
            with mock.patch.object(installer, "service_backend", REAL_INSTALLER_BACKEND):
                with mock.patch.object(service, "service_backend", REAL_SERVICE_BACKEND):
                    yield

    def test_an_unsupported_host_is_refused_before_anything_is_written(self):
        with self.unmanaged_host():
            with self.assertRaises(installer.InstallError) as raised:
                self.install()
        self.assertIn("No supported service manager", str(raised.exception))
        for name in installer.LINKED_MODULES:
            self.assertFalse(os.path.lexists(self.install_dir / name), name)
        self.assertEqual(self.entries(), {})

    def test_an_unsupported_host_refuses_an_uninstall_too(self):
        with self.unmanaged_host():
            with self.assertRaises(installer.InstallError):
                self.uninstall()

    def test_a_host_that_cannot_supervise_a_process_group_is_refused_too(self):
        with mock.patch.object(service, "fcntl", None):
            with self.assertRaises(installer.InstallError) as raised:
                self.install()
        self.assertIn("fcntl.flock", str(raised.exception))
        self.assertEqual(self.entries(), {})


# ---------------------------------------------------------------------------
# Collateral
# ---------------------------------------------------------------------------


class NoCollateralChangeTests(InstallerFixture):
    def test_installing_here_writes_under_this_components_root_alone(self):
        self.install()
        service_root = service.installed_service_root()
        written = {
            str(service.discovery_record_path()),
            str(self.job().runtime_dir),
        }
        for path in written:
            self.assertTrue(
                path.startswith(str(service_root)),
                f"{path} is outside {service_root}",
            )
        for other in ("pr-drainer", "issue-approval", "issue-review"):
            for base in (self.account, self.home):
                for root in ("Library/Application Support/kanban", ".local/share/kanban"):
                    candidate = base / root / other
                    self.assertFalse(
                        candidate.exists(), f"{candidate} was created"
                    )


if __name__ == "__main__":
    unittest.main()
