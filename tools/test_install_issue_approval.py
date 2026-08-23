"""Safety and lifecycle tests for the issue approval service installer.

Hermetic throughout. Every root the installer and the controller write under is
redirected into a temporary directory, the canonical issue-review backend is a
fake script on a temporary `KANBAN_ISSUE_REVIEW_INSTALL_DIR`, the repositories
are temporary `git init` checkouts whose remotes name repositories nothing here
ever contacts, and the service manager is a fake whose whole state lives in one
temporary directory. No test invokes `launchctl` or `systemctl`, reaches the
network or a GitHub account, or writes to the real
`~/Library/Application Support/kanban`.

The lifecycle cases are real. The fake service manager's `kick` spawns the very
argument vector the installed definition carries, in a session of its own, so a
start is proved by a controller process that really runs and really outlives
the process that asked for it -- and a stop by that process really exiting while
the job it was started from stays installed.
"""

import contextlib
import json
import os
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

import approve_issues_service as service
import install_issue_approval as installer
import service_manager


TOOLS_DIR = Path(__file__).resolve().parent

# Captured before any fixture replaces them, so the cases that are *about* the
# real backend selection can reach it again from inside a fixture that has
# pinned a fake one.
REAL_INSTALLER_BACKEND = installer.service_backend
REAL_SERVICE_BACKEND = service.service_backend


# The canonical issue-review backend, reduced to what a controller run needs of
# it: a `--review-queue` pass that reports an idle queue and a `--check` that
# approves. It deliberately reads no environment, because the environment a
# started job has is the one the installed definition carries, and this file is
# about that definition rather than about reviewing.
FAKE_CANONICAL_BACKEND = '''#!/usr/bin/env python3
import argparse
import json
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--path")
parser.add_argument("--repo")
parser.add_argument("--legacy-policy")
parser.add_argument("--log-dir")
parser.add_argument("--config")
parser.add_argument("--json", action="store_true")
parser.add_argument("--review-queue", action="store_true")
parser.add_argument("--check", type=int)
args = parser.parse_args()

if args.check is not None:
    print(json.dumps({"approved": True, "issue": args.check, "reasons": []}))
    raise SystemExit(0)

print(
    json.dumps(
        {
            "schema": "approve-issues-review-queue",
            "version": 1,
            "outcome": "idle",
            "issue": None,
            "model_called": False,
            "message": "No issue is waiting.",
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
# hermeticity this file promises. `FIXTURE_SERVICE_MANAGER` names the fake's
# durable state directory, so the fake a subprocess holds is the very one this
# process holds.
WRAPPER = '''#!/usr/bin/env python3
import os
import sys
from pathlib import Path

tools = sys.argv[1]
account = Path(sys.argv[2])
entry = sys.argv[3]
del sys.argv[1:4]

sys.path.insert(0, tools)

import approve_issues_service as service

service.account_home = lambda: account

manager_root = os.environ.get("FIXTURE_SERVICE_MANAGER")
if manager_root:
    # In front of the install directory, so the fixture module resolves from
    # the checkout while `approve_issues_service` stays the installed copy
    # already imported above.
    sys.path.insert(0, os.environ["FIXTURE_TOOLS"])
    import test_install_issue_approval as fixture

    manager = fixture.FakeServiceManager(manager_root)
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
    named by a real derivation could not pass for one named through the seam.

    It spawns nothing of its own invention: `kick` runs the argument vector the
    definition it was handed actually carries, with only the account-root
    redirection every test in this file applies.
    """

    def __init__(self, root):
        self.root = Path(root)
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
        return service_manager.ISSUE_APPROVAL_NAMESPACE

    def backend_name(self):
        return "fake-manager"

    def definition_label(self):
        return "definition"

    def service_identifier(self, slug):
        return f"fake-approval.{slug}"

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
        return f"fake-manager/{identifier}"

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
        return {
            "backend": self.backend_name(),
            "fake_identifier": identifier,
            "fake_definition_path": str(definition_path),
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
        launcher = subprocess.Popen(
            [sys.executable, "-c", LAUNCHER, json.dumps(spec)]
        )
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


class LockHolder:
    """Another process holding the canonical approval lock, as the untracked
    legacy daemon holds it. Resolved through the same function the controller
    uses, so it really takes the file the refusal inspects."""

    def __init__(self, repo, mode):
        path = service.approval_lock_path(repo)
        ready = path.with_name(f"holder-{mode}-ready")
        source = (
            "import fcntl, json, os, sys, time\n"
            "handle = open(sys.argv[1], 'a+', encoding='utf-8')\n"
            "fcntl.flock(handle.fileno(), fcntl.LOCK_EX)\n"
            "handle.seek(0); handle.truncate()\n"
            "handle.write(json.dumps({'pid': os.getpid(), 'mode': sys.argv[3]}))\n"
            "handle.flush()\n"
            "open(sys.argv[2], 'w').write('ready')\n"
            "time.sleep(300)\n"
        )
        self.proc = subprocess.Popen(
            [sys.executable, "-c", source, str(path), str(ready), mode]
        )
        wait_until(ready.exists, message="the lock holder to take the lock")
        self.path = path

    def alive(self):
        return self.proc.poll() is None

    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=10)


class InstallerFixture(unittest.TestCase):
    """A temporary account root, temporary checkouts, a fake canonical backend,
    and a fake service manager.

    Two redirections, because two different kinds of location are read. The
    service's own state hangs off the *account* root, which it resolves from
    the passwd database on purpose and which is therefore redirected in the
    process. What it reads on a caller's behalf -- the shared Kanban
    configuration and the installed canonical backend -- still comes from the
    environment, so `$HOME` and `KANBAN_ISSUE_REVIEW_INSTALL_DIR` are
    redirected too.
    """

    identity = "acme/widgets"
    remote_url = "git@github.com:acme/widgets.git"

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
        self.backend_dir = self.root / "canonical"
        self.backend_dir.mkdir()
        self.canonical_backend = self.backend_dir / "approve_issues.py"
        self.canonical_backend.write_text(FAKE_CANONICAL_BACKEND, encoding="utf-8")
        self.canonical_backend.chmod(0o700)
        # The modules the real backend imports at startup, which this
        # installer verifies are beside the script it resolved: a directory
        # holding only the script is a reviewer that cannot start, and this
        # installer refuses to give a service one.
        for name in installer.BACKEND_COMPANION_MODULES:
            (self.backend_dir / name).write_text(
                f"# stand-in for {name}\n", encoding="utf-8"
            )

        self.git_config = self.root / "gitconfig"
        self.git_config.write_text("", encoding="utf-8")
        self.environment = {
            **os.environ,
            "HOME": str(self.home),
            "KANBAN_ISSUE_REVIEW_INSTALL_DIR": str(self.backend_dir),
            "GIT_CONFIG_GLOBAL": str(self.git_config),
            "GIT_CONFIG_NOSYSTEM": "1",
            "PYTHONUNBUFFERED": "1",
            # Redirected rather than dropped: since issue #357 `kanban_config`
            # resolves the issue-review locations from both the XDG roots and
            # `~/Library`, so an ambient one would let the developer's own
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
        self.manager = FakeServiceManager(self.root / "manager")
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
        # records: a fixture that skipped it would compare a checkout spelled
        # one way against the same checkout spelled another.
        return installer.repository_root(path)

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

    def install(self, repo=None, **kwargs):
        kwargs.setdefault("dry_run", False)
        kwargs.setdefault("config_path", None)
        return installer.install(repo or self.repo, self.install_dir, **kwargs)

    def uninstall(self, repo=None, **kwargs):
        kwargs.setdefault("dry_run", False)
        return installer.uninstall(repo or self.repo, self.install_dir, **kwargs)

    def write_status(self, job, *, state, repo, runner_pid):
        """A status document as a live run would have left it."""
        job.runtime_dir.mkdir(parents=True, exist_ok=True)
        service.atomic_write_json(
            job.status_path,
            {
                "schema": service.STATUS_SCHEMA,
                "version": service.STATUS_VERSION,
                "state": state,
                "repository": job.identity,
                "repo": str(repo),
                "runner_pid": runner_pid,
                "backend_pid": None,
                "barrier_issue": None,
                "message": "Reviewing.",
                "started_at": "2026-08-16T00:00:00Z",
                "updated_at": "2026-08-16T00:00:00Z",
            },
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


class ManagedAssetTests(unittest.TestCase):
    """What the installer will and will not touch."""

    def test_every_linked_module_in_this_checkout_is_recognizable(self):
        # The recognition is what decides whether a link may be replaced or
        # removed. If a tracked module ever loses its marker, this installer
        # silently stops recognizing its own installation -- refusing every
        # upgrade and leaving every link behind on uninstall -- so the markers
        # are held against the real tree rather than against a fixture.
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertTrue(
                    installer.is_managed_asset(TOOLS_DIR / name, name),
                    f"tools/{name} carries no kanban-managed-asset marker",
                )

    def test_a_marker_for_another_module_is_not_a_match(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "service_manager.py"
            path.write_text(
                "# kanban-managed-asset:issue-review/approve_issues.py\n",
                encoding="utf-8",
            )
            self.assertFalse(installer.is_managed_asset(path, "service_manager.py"))

    def test_any_kanban_namespace_recognizes_the_module(self):
        # One tracked file can serve several installed namespaces --
        # kanban_config.py carries the issue-review marker and is linked here
        # too -- so the namespace segment is matched rather than fixed.
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "kanban_config.py"
            path.write_text(
                "# kanban-managed-asset:issue-review/kanban_config.py\n",
                encoding="utf-8",
            )
            self.assertTrue(installer.is_managed_asset(path, "kanban_config.py"))

    def test_an_unmarked_file_is_never_recognized(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "service_manager.py"
            path.write_text("print('mine')\n", encoding="utf-8")
            self.assertFalse(installer.is_managed_asset(path, "service_manager.py"))


class LinkSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "source" / "service_manager.py"
        self.source.parent.mkdir()
        self.source.write_text(
            "# kanban-managed-asset:issue-approval/service_manager.py\n",
            encoding="utf-8",
        )
        self.destination = self.root / "installed" / "service_manager.py"

    def test_creates_a_link_and_is_idempotent(self):
        self.assertEqual(
            installer.install_symlink(self.source, self.destination), "created"
        )
        self.assertEqual(self.destination.resolve(), self.source.resolve())
        self.assertEqual(
            installer.install_symlink(self.source, self.destination), "unchanged"
        )

    def test_an_upgrade_repoints_the_one_link(self):
        moved = self.root / "moved" / "service_manager.py"
        moved.parent.mkdir()
        shutil.copy(self.source, moved)
        installer.install_symlink(self.source, self.destination)
        self.assertEqual(
            installer.install_symlink(moved, self.destination), "updated"
        )
        self.assertEqual(self.destination.resolve(), moved.resolve())
        self.assertEqual(
            sorted(path.name for path in self.destination.parent.iterdir()),
            ["service_manager.py"],
        )

    def test_refuses_to_overwrite_an_ordinary_file(self):
        self.destination.parent.mkdir()
        self.destination.write_text("keep me\n", encoding="utf-8")
        self.assertEqual(installer.plan_symlink(self.source, self.destination), "refused")
        with self.assertRaises(installer.InstallError):
            installer.install_symlink(self.source, self.destination)
        self.assertEqual(self.destination.read_text(encoding="utf-8"), "keep me\n")

    def test_refuses_to_repoint_a_link_to_somebody_elses_file(self):
        foreign = self.root / "theirs" / "service_manager.py"
        foreign.parent.mkdir()
        foreign.write_text("someone else's installation\n", encoding="utf-8")
        self.destination.parent.mkdir()
        self.destination.symlink_to(foreign)
        with self.assertRaises(installer.InstallError):
            installer.install_symlink(self.source, self.destination)
        self.assertEqual(self.destination.resolve(), foreign.resolve())

    def test_a_broken_link_is_preserved_because_nothing_can_recognize_it(self):
        # A missing target carries no marker, and the name of a link proves
        # nothing about who made it: a user's own broken `service_manager.py`
        # looks exactly like one this installer left behind, so neither is
        # replaced on the strength of its name.
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.root / "gone" / "service_manager.py")
        self.assertTrue(os.path.lexists(self.destination))
        self.assertEqual(
            installer.plan_symlink(self.source, self.destination), "refused"
        )
        with self.assertRaises(installer.InstallError) as raised:
            installer.install_symlink(self.source, self.destination)
        self.assertIn("does not exist", str(raised.exception))
        self.assertEqual(
            os.readlink(self.destination), str(self.root / "gone" / "service_manager.py")
        )

    def test_a_broken_link_is_never_removed_either(self):
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.root / "gone" / "service_manager.py")
        self.assertEqual(
            installer.remove_symlink(self.destination, "service_manager.py"), "kept"
        )
        self.assertTrue(os.path.lexists(self.destination))

    def test_removal_keeps_an_ordinary_file_and_a_foreign_link(self):
        foreign = self.root / "theirs" / "service_manager.py"
        foreign.parent.mkdir()
        foreign.write_text("someone else's installation\n", encoding="utf-8")
        self.destination.parent.mkdir()
        self.destination.symlink_to(foreign)
        self.assertEqual(
            installer.remove_symlink(self.destination, "service_manager.py"), "kept"
        )
        self.assertTrue(self.destination.is_symlink())

        ordinary = self.destination.parent / "kanban_config.py"
        ordinary.write_text("mine\n", encoding="utf-8")
        self.assertEqual(
            installer.remove_symlink(ordinary, "kanban_config.py"), "kept"
        )
        self.assertEqual(ordinary.read_text(encoding="utf-8"), "mine\n")

    def test_removal_takes_its_own_link(self):
        installer.install_symlink(self.source, self.destination)
        self.assertEqual(
            installer.remove_symlink(self.destination, "service_manager.py"), "removed"
        )
        self.assertFalse(os.path.lexists(self.destination))
        self.assertTrue(self.source.exists())


class SlugLimitTests(unittest.TestCase):
    """Every identity this service accepts yields a job a manager can carry.

    The slug names the identifier, the runtime directory, and the log directory
    together, so a limit measured against the directory alone would let a
    perfectly valid identity install a job nothing could address.
    """

    def backends(self):
        runner = lambda *arguments, **options: None  # noqa: E731 - never called
        return (
            service_manager.LaunchdBackend(
                runner, service_manager.ISSUE_APPROVAL_NAMESPACE
            ),
            service_manager.SystemdBackend(
                runner, service_manager.ISSUE_APPROVAL_NAMESPACE
            ),
        )

    def test_a_long_identity_still_yields_a_manageable_identifier(self):
        identities = [
            "acme/widgets",
            "o" * 39 + "/" + "n" * 100,
            # An escaped slug just over the limit, and one far over it: both
            # would have fitted the old directory-shaped limit of 180 while
            # overflowing the identifier this service actually installs.
            "o" * 80 + "/" + "n" * 80,
            "o" * 200 + "/" + "-" * 200,
        ]
        for identity in identities:
            with self.subTest(identity=len(identity)):
                slug = service.repository_slug(identity)
                self.assertTrue(slug)
                for backend in self.backends():
                    self.assertTrue(backend.identifier_fits(slug), backend.backend_name())
                    self.assertLessEqual(
                        len(backend.service_identifier(slug)),
                        service_manager.MAX_LABEL_LENGTH,
                    )

    def test_the_overflow_fallback_is_still_injective(self):
        # Two identities that both overflow must not collapse onto one job.
        first = service.repository_slug("o" * 200 + "/" + "-" * 200)
        second = service.repository_slug("o" * 200 + "/" + "." * 200)
        self.assertNotEqual(first, second)
        self.assertNotIn(".", first)

    def test_naming_a_slug_needs_no_service_manager(self):
        # `run` and `status` name their own directories, and neither may
        # require a host to have a service manager at all.
        with mock.patch.object(
            service_manager, "detect_service_manager", return_value=None
        ):
            self.assertTrue(service.repository_slug("acme/widgets"))


class SideBySideTests(InstallerFixture):
    def test_two_repositories_install_side_by_side(self):
        gadgets = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        first = self.install()
        second = self.install(gadgets)

        self.assertNotEqual(first["job"]["repository"], second["job"]["repository"])
        for key in ("label", "definition", "runtime_dir", "log_dir"):
            with self.subTest(key=key):
                self.assertNotEqual(first["job"][key], second["job"][key])
        records = self.record()["repositories"]
        self.assertEqual(sorted(records), ["acme/gadgets", "acme/widgets"])
        # And each entry names its own job, so neither repository could be
        # controlled through the other's record.
        self.assertNotEqual(
            records["acme/widgets"]["fake_identifier"],
            records["acme/gadgets"]["fake_identifier"],
        )
        # One installation, shared: the second install adds an entry beside the
        # first rather than a second set of links.
        self.assertEqual(
            sorted(path.name for path in self.install_dir.iterdir()),
            sorted(installer.LINKED_MODULES),
        )

    def test_the_drainers_namespace_is_never_this_services(self):
        # Two services can install a job for one repository, so their
        # identifiers must not be able to collide however similar the
        # repositories are.
        slug = service.repository_slug(self.identity)
        runner = lambda *arguments, **options: None  # noqa: E731 - never called
        approval = service_manager.LaunchdBackend(
            runner, service_manager.ISSUE_APPROVAL_NAMESPACE
        )
        drainer = service_manager.LaunchdBackend(
            runner, service_manager.DRAINER_NAMESPACE
        )
        self.assertNotEqual(
            approval.service_identifier(slug), drainer.service_identifier(slug)
        )
        self.assertNotEqual(
            approval.definition_path(approval.service_identifier(slug)),
            drainer.definition_path(drainer.service_identifier(slug)),
        )
        # And the drainer's identifiers are exactly what they were, because a
        # live installation must keep working across this change.
        self.assertEqual(
            drainer.service_identifier(slug), f"com.coghex.drain-prs.{slug}"
        )


class SecondCheckoutTests(InstallerFixture):
    def test_a_second_checkout_of_one_identity_is_refused_while_its_job_runs(self):
        other = self.checkout("widgets-clone", self.remote_url)
        # A live run recorded against the first checkout. Its runner is this
        # test process, which is unquestionably alive, so the status is
        # believed rather than discarded as stale.
        self.write_status(
            self.job(), state=service.STATE_RUNNING, repo=self.repo, runner_pid=os.getpid()
        )
        with self.assertRaises(installer.InstallError) as raised:
            self.install(other)
        self.assertIn(str(self.repo), str(raised.exception))
        self.assertIn("another checkout", str(raised.exception))
        self.assertFalse(self.install_dir.exists())
        self.assertEqual(self.manager.call_names(), [])

    def test_the_same_checkout_is_refused_while_its_own_run_is_live(self):
        self.write_status(
            self.job(), state=service.STATE_RUNNING, repo=self.repo, runner_pid=os.getpid()
        )
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn("Stop the running issue approval controller", str(raised.exception))
        self.assertFalse(self.install_dir.exists())

    def test_a_stale_live_status_does_not_block_an_install(self):
        # A live state recorded under a runner that is gone is not a running
        # service, and refusing on it would leave a repository permanently
        # uninstallable after one crash.
        self.write_status(
            self.job(),
            state=service.STATE_RUNNING,
            repo=self.repo,
            runner_pid=2**31 - 1,
        )
        self.assertTrue(self.install()["installed"])


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
                runner, service_manager.ISSUE_APPROVAL_NAMESPACE
            ).render_definition(definition)
        )
        self.assertIs(document["RunAtLoad"], False)
        self.assertIs(document["KeepAlive"], False)
        unit = (
            service_manager.SystemdBackend(
                runner, service_manager.ISSUE_APPROVAL_NAMESPACE
            )
            .render_definition(definition)
            .decode("utf-8")
        )
        self.assertNotIn("[Install]", unit)
        self.assertIn("Restart=no", unit)
        self.assertIn("Kanban issue approval", unit)


class LifecycleTests(InstallerFixture):
    """A real controller process, started and stopped through the seam."""

    def controller_status(self):
        return service.status_snapshot(self.job())["state"]

    def test_an_explicit_start_produces_a_run_that_outlives_its_caller(self):
        self.install()
        proc = subprocess.run(
            [
                sys.executable,
                str(self.wrapper),
                str(self.install_dir),
                str(self.account),
                "controller",
                "--json",
                "--path",
                str(self.repo),
                "--repo",
                self.identity,
                "start",
            ],
            capture_output=True,
            text=True,
            timeout=60,
            env={
                **os.environ,
                "FIXTURE_SERVICE_MANAGER": str(self.manager.root),
                "FIXTURE_TOOLS": str(TOOLS_DIR),
            },
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        started = json.loads(proc.stdout)
        self.assertTrue(started["started"])
        self.assertIn(started["state"], service.LIVE_STATES)

        # The process that asked for the start has exited, and the run it asked
        # for has not: that is the whole difference between a managed job and a
        # foreground command.
        runner_pid = started["runner_pid"]
        self.assertTrue(pid_alive(runner_pid))
        self.assertIn(self.controller_status(), service.LIVE_STATES)
        # And it is nobody's child here: it was started in a session of its
        # own, so no process in this test's tree is waiting on it.
        self.assertNotEqual(os.getpid(), runner_pid)

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
        self.assertIn("acme/widgets", self.record()["repositories"])
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
        self.assertIn(str(self.repo), str(raised.exception))
        # Refused without taking anything away, so the running controller is
        # still discoverable and still controllable.
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertIn("acme/widgets", self.record()["repositories"])
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink())


class ManagerLivenessTests(InstallerFixture):
    """A run the status document cannot describe is still a run.

    The document is written by the run itself, so one that has not written yet,
    or whose write failed, or that was damaged reads as stopped. Every
    transition that would replace or remove a job therefore asks the manager
    too, and removal — the one transition that destroys the means of recovery —
    asks it first.
    """

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
        self.assertIn("acme/widgets", self.record()["repositories"])
        self.assertNotIn("uninstall_definition", self.manager.call_names())
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink())

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
        self.install()
        pid = self.detached_process("import time; time.sleep(300)")
        self.manager.record_started_pid(self.label(), pid)
        self.assertFalse(self.job().status_path.exists())

        result = service.stop_service(self.job())
        self.assertTrue(result["stopped"])
        self.assertIn("request_stop", self.manager.call_names())
        self.assertFalse(pid_alive(pid))


class TransitionSerializationTests(InstallerFixture):
    """Two transitions of one job never interleave.

    Each of install, start, stop, and uninstall reads what the manager and the
    runtime currently say and then acts on it, so two running at once can each
    act on a state the other has already left. The worst of those is a start
    kicking a job between an uninstall's liveness check and its removal:
    removing a systemd unit and reloading the manager does not stop an active
    process, so the job would keep running with its definition and its record
    entry already gone.
    """

    def timeline_manager(self, hold):
        """This fixture's manager, with removal made slow and every call
        stamped, so an overlap would be visible rather than merely likely."""
        events = []
        guard = threading.Lock()
        manager = self.manager

        def stamp(name):
            with guard:
                events.append((name, time.monotonic()))

        original_uninstall = manager.uninstall_definition
        original_kick = manager.kick

        def slow_uninstall(identifier):
            stamp("removal-start")
            time.sleep(hold)
            outcome = original_uninstall(identifier)
            stamp("removal-end")
            return outcome

        def stamped_kick(identifier):
            stamp("kick")
            return original_kick(identifier)

        manager.uninstall_definition = slow_uninstall
        manager.kick = stamped_kick
        self.addCleanup(setattr, manager, "uninstall_definition", original_uninstall)
        self.addCleanup(setattr, manager, "kick", original_kick)
        return events

    def test_a_start_cannot_kick_a_job_that_is_being_removed(self):
        # A second repository shares the installation, so the uninstall leaves
        # the links behind and the racing start is a start that can really
        # succeed rather than one refused for want of a controller.
        self.install(self.checkout("gadgets", "git@github.com:acme/gadgets.git"))
        self.install()
        events = self.timeline_manager(hold=0.4)
        failures = []

        def start_later():
            # Long enough to be inside the removal's window if nothing
            # serialized the two, and far short of how long it holds.
            time.sleep(0.1)
            try:
                service.start_service(self.job(), self.install_dir)
            except Exception as error:  # pragma: no cover - reported below
                failures.append(error)

        starter = threading.Thread(target=start_later)
        starter.start()
        try:
            self.uninstall()
        finally:
            starter.join(timeout=60)

        self.assertEqual(failures, [])
        stamps = dict(events)
        self.assertIn("removal-start", stamps)
        self.assertIn("kick", stamps)
        # The whole point: no kick landed inside the removal's window.
        self.assertFalse(
            stamps["removal-start"] <= stamps["kick"] <= stamps["removal-end"],
            f"a start kicked the job while it was being removed: {events}",
        )
        self.assertGreater(stamps["kick"], stamps["removal-end"])

    def test_a_start_racing_an_uninstall_leaves_a_job_that_matches_its_record(self):
        # Whichever order the two settle in, the end state has to be coherent:
        # a job the manager is running is a job the record can find.
        self.install(self.checkout("gadgets", "git@github.com:acme/gadgets.git"))
        self.install()
        self.timeline_manager(hold=0.3)

        def uninstall_later():
            time.sleep(0.05)
            with contextlib.suppress(installer.InstallError):
                self.uninstall()

        remover = threading.Thread(target=uninstall_later)
        remover.start()
        try:
            with contextlib.suppress(service.ServiceError):
                service.start_service(self.job(), self.install_dir)
        finally:
            remover.join(timeout=60)

        recorded = "acme/widgets" in self.record().get("repositories", {})
        running = self.manager.is_running(self.label())
        self.assertEqual(
            recorded,
            running,
            "a running job must be discoverable and a removed one must be gone",
        )


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
                self.install(gadgets)
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
        if "acme/gadgets" in self.record().get("repositories", {}):
            for name in installer.LINKED_MODULES:
                with self.subTest(module=name):
                    self.assertTrue(
                        (self.install_dir / name).is_symlink(),
                        f"{name} was removed under an installed job",
                    )
                    self.assertTrue((self.install_dir / name).resolve().is_file())


class LinkRemovalRaceTests(InstallerFixture):
    """A start can never leave a recorded job pointing at deleted links.

    The uninstall removes the job and its record entry, then removes the links
    the job ran from. A start landing in between would reinstate the entry and
    kick the job, and the removal that followed would take away the very files
    that job runs -- reporting success over a live, recorded, unrunnable
    service. There is no second repository here to keep the links alive, which
    is the case where the window is widest.
    """

    def slow_link_removal(self, hold=0.3):
        original = installer.remove_symlink

        def slow_remove(destination, name):
            time.sleep(hold)
            return original(destination, name)

        patched = mock.patch.object(installer, "remove_symlink", slow_remove)
        patched.start()
        self.addCleanup(patched.stop)

    def assert_coherent(self):
        """A recorded job has the links it runs from, and a job the manager is
        running is one the record can find."""
        recorded = "acme/widgets" in self.record().get("repositories", {})
        if recorded:
            for name in installer.LINKED_MODULES:
                with self.subTest(module=name):
                    self.assertTrue(
                        (self.install_dir / name).is_file(),
                        f"{name} was removed under a recorded job",
                    )
        self.assertEqual(recorded, self.manager.is_running(self.label()))

    def test_a_start_racing_an_uninstall_with_no_sibling_stays_coherent(self):
        self.install()
        self.slow_link_removal()
        failures = []

        def start_later():
            time.sleep(0.05)
            try:
                service.start_service(self.job(), self.install_dir)
            except service.ServiceError:
                # A start that arrives after the installation was taken away
                # is refused for want of a controller, which is a coherent
                # outcome and the one this ordering produces.
                pass
            except Exception as error:  # pragma: no cover - reported below
                failures.append(error)

        starter = threading.Thread(target=start_later)
        starter.start()
        try:
            self.uninstall()
        finally:
            starter.join(timeout=60)

        self.assertEqual(failures, [])
        self.assert_coherent()

    def test_an_uninstall_racing_a_start_with_no_sibling_stays_coherent(self):
        # The other ordering: the start commits first, so the uninstall waits
        # and then removes a job it can see is there.
        self.install()
        self.slow_link_removal()
        failures = []

        def uninstall_later():
            time.sleep(0.05)
            try:
                self.uninstall()
            except installer.InstallError:
                # Refused because the start it lost to left a live job, which
                # is exactly the refusal that keeps this coherent.
                pass
            except Exception as error:  # pragma: no cover - reported below
                failures.append(error)

        remover = threading.Thread(target=uninstall_later)
        remover.start()
        try:
            with contextlib.suppress(service.ServiceError):
                service.start_service(self.job(), self.install_dir)
        finally:
            remover.join(timeout=60)

        self.assertEqual(failures, [])
        self.assert_coherent()

    def test_a_start_racing_a_relocation_never_loses_the_links_it_needs(self):
        # The relocation's cleanup of the directory it left is the same window
        # one step over: a repository still installed there must keep its
        # links, whichever order the two settle in.
        gadgets = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.install()
        self.install(gadgets)
        self.slow_link_removal()
        moved = self.root / "moved-installation"
        failures = []

        def start_gadgets():
            time.sleep(0.05)
            try:
                service.start_service(
                    service.resolve_job(gadgets), self.install_dir
                )
            except Exception as error:  # pragma: no cover - reported below
                failures.append(error)

        starter = threading.Thread(target=start_gadgets)
        starter.start()
        try:
            installer.install(self.repo, moved, config_path=None, dry_run=False)
        finally:
            starter.join(timeout=60)

        self.assertEqual(failures, [])
        # gadgets never moved, so its links are still there and its job runs.
        entry = self.record()["repositories"]["acme/gadgets"]
        self.assertEqual(
            Path(entry["install_dir"]).resolve(), self.install_dir.resolve()
        )
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertTrue((self.install_dir / name).is_file())
        self.assertTrue(self.manager.is_running(self.label("acme/gadgets")))


class RelocationTests(InstallerFixture):
    """A job moved to another install directory leaves the old one empty."""

    def test_reinstalling_elsewhere_takes_back_the_links_it_leaves(self):
        self.install()
        moved = self.root / "moved-installation"
        result = installer.install(
            self.repo, moved, config_path=None, dry_run=False
        )
        self.assertEqual(
            Path(result["relocated_from"]).resolve(), self.install_dir.resolve()
        )
        self.assertEqual(
            [link["result"] for link in result["released_links"].values()],
            ["removed"] * len(installer.LINKED_MODULES),
        )
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertFalse(os.path.lexists(self.install_dir / name))
                self.assertTrue((moved / name).is_symlink())
        entry = self.record()["repositories"]["acme/widgets"]
        self.assertEqual(Path(entry["install_dir"]).resolve(), moved.resolve())
        # And the job the manager now holds runs from the new directory.
        definition = json.loads(
            self.manager.definition_path(self.label()).read_text(encoding="utf-8")
        )
        self.assertEqual(Path(definition["program_arguments"][1]).parent, moved)

    def test_a_relocation_keeps_links_another_job_still_runs_from(self):
        gadgets = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.install()
        self.install(gadgets)
        moved = self.root / "moved-installation"
        result = installer.install(
            self.repo, moved, config_path=None, dry_run=False
        )
        self.assertEqual(
            [link["result"] for link in result["released_links"].values()],
            ["kept"] * len(installer.LINKED_MODULES),
        )
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertTrue((self.install_dir / name).is_symlink())

    def test_two_installs_of_one_repository_into_two_directories_leave_one(self):
        # Both would find "no previous installation" if either looked before it
        # wrote, and the one that wrote second would leave the other's links
        # behind with nothing able to find them. The location a record write
        # replaced is read by that write itself, so exactly one directory
        # remains a populated installation and it is the one the record names.
        #
        # Which interleaving happens is not this example's to choose, and the
        # race has two legitimate endings because the running-owner guard is
        # advisory by contract (`require_no_live_run`): a contender whose plan
        # probes while its sibling holds the run lock for its own transition is
        # refused rather than queued. This example accepts that refusal as one
        # outcome instead of serializing the installs, which would trade the
        # guard's documented non-blocking semantics for the example's comfort.
        # So: either both installs succeed -- both plans can pass before either
        # transition takes the run lock -- or exactly one is refused naming the
        # sibling's transition-mode hold. A refusal with any other wording, any
        # other exception, or two refusals is a real failure.
        first = self.root / "installation-a"
        second = self.root / "installation-b"
        outcomes = {}
        ready = threading.Barrier(2)

        def install_into(directory):
            try:
                ready.wait(timeout=30)
                installer.install(
                    self.repo, directory, config_path=None, dry_run=False
                )
            except BaseException as error:
                outcomes[directory] = error
            else:
                outcomes[directory] = None

        threads = [
            threading.Thread(target=install_into, args=(directory,))
            for directory in (first, second)
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=60)

        # Both threads must have reached a terminal outcome: a thread still
        # alive after the join timeout never returned from `install`, and an
        # empty error list alone would read that as success.
        for thread in threads:
            self.assertFalse(thread.is_alive(), "an install call never returned")
        self.assertEqual(set(outcomes), {first, second})
        refused = {
            directory: error
            for directory, error in outcomes.items()
            if error is not None
        }
        for directory, error in refused.items():
            self.assertIsInstance(error, installer.InstallError, repr(error))
            self.assertIn(
                "which is installing or removing this job",
                str(error),
                f"the install into {directory} failed outside the advisory "
                f"running-owner refusal: {error!r}",
            )
        self.assertLessEqual(
            len(refused), 1, f"both installs were refused: {refused!r}"
        )

        recorded = Path(
            self.record()["repositories"]["acme/widgets"]["install_dir"]
        ).resolve()
        self.assertIn(recorded, {first.resolve(), second.resolve()})
        abandoned = second if recorded == first.resolve() else first
        if refused:
            # A refused contender wrote nothing, so the record can only name
            # the directory whose install succeeded.
            (refused_directory,) = refused
            self.assertEqual(refused_directory.resolve(), abandoned.resolve())
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertTrue(
                    (Path(recorded) / name).is_file(),
                    "the recorded installation lost its links",
                )
                self.assertFalse(
                    os.path.lexists(abandoned / name),
                    f"{abandoned} kept links no record can find",
                )

    def test_reinstalling_in_place_relocates_nothing(self):
        self.install()
        result = self.install()
        self.assertIsNone(result["relocated_from"])
        self.assertEqual(result["released_links"], {})

    def test_the_relocation_plan_is_what_the_relocation_performs(self):
        self.install()
        moved = self.root / "moved-installation"
        plan = installer.install(self.repo, moved, config_path=None, dry_run=True)
        self.assertEqual(
            Path(plan["relocated_from"]).resolve(), self.install_dir.resolve()
        )
        self.assertEqual(
            [link["result"] for link in plan["released_links"].values()],
            ["removed"] * len(installer.LINKED_MODULES),
        )
        # And it wrote nothing: the old links are still there.
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink())

        performed = installer.install(self.repo, moved, config_path=None, dry_run=False)
        self.assertEqual(plan["released_links"], performed["released_links"])


class ForegroundRunTests(InstallerFixture):
    """A `run` nobody's service manager started is still a run.

    It takes its run lock before it writes a status document and before it
    invokes the backend, so between those two moments the manager knows nothing
    about it and the runtime says nothing about it. A destructive transition
    that consulted only those two would remove the job, the record entry, and
    the links out from under a controller that keeps reviewing issues.
    """

    def foreground_run(self):
        """A real `run` of this repository, started as a plain process.

        Held at its first backend pass by a canonical backend that blocks, so
        the run is genuinely established -- lock taken -- for as long as the
        test needs, without the test having to guess at timing.
        """
        gate = self.root / "release-backend"
        self.canonical_backend.write_text(
            "#!/usr/bin/env python3\n"
            "import os, sys, time\n"
            f"gate = {str(gate)!r}\n"
            "while not os.path.exists(gate):\n"
            "    time.sleep(0.02)\n"
            "sys.stdout.write('{\"schema\": \"approve-issues-review-queue\", "
            '"version": 1, "outcome": "idle", "issue": null, '
            "\"model_called\": false, \"message\": \"idle\"}')\n",
            encoding="utf-8",
        )
        self.canonical_backend.chmod(0o700)
        proc = subprocess.Popen(
            [
                sys.executable,
                str(self.wrapper),
                str(TOOLS_DIR),
                str(self.account),
                "controller",
                "--path",
                str(self.repo),
                "run",
                "--interval",
                "0.05",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ},
        )
        self.addCleanup(proc.stderr.close)
        self.addCleanup(proc.stdout.close)
        self.addCleanup(proc.wait)
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        self.addCleanup(gate.touch)
        wait_until(
            lambda: service.run_lock_owner(self.job()) is not None,
            message="the foreground run to take its lock",
        )
        return proc

    def test_a_foreground_run_is_seen_before_it_writes_any_status(self):
        # The window the manager and the status document both miss.
        self.install()
        self.foreground_run()
        owner = service.run_lock_owner(self.job())
        self.assertEqual(owner["repository"], self.identity)
        self.assertEqual(Path(owner["repo"]).resolve(), self.repo.resolve())
        self.assertFalse(self.manager.is_running(self.label()))

    def test_uninstall_refuses_a_foreground_run(self):
        self.install()
        self.foreground_run()
        with self.assertRaises(installer.InstallError) as raised:
            self.uninstall()
        self.assertIn("already running", str(raised.exception))
        # Nothing was taken away from under it.
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertIn("acme/widgets", self.record()["repositories"])
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertTrue((self.install_dir / name).is_file())

    def test_install_refuses_a_foreground_run(self):
        self.install()
        self.foreground_run()
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn("already running", str(raised.exception))

    def test_starting_beside_a_foreground_run_is_a_no_op(self):
        # Not a refusal: a start of something already running is nothing to do,
        # and it must not rewrite the definition under it either.
        self.install()
        self.foreground_run()
        before = self.manager.call_names()
        result = service.start_service(self.job(), self.install_dir)
        self.assertFalse(result["started"])
        self.assertEqual(self.manager.call_names(), before)

    def launch_run(self):
        """Start a `run` without waiting for it to establish.

        The companion to `foreground_run` for the case where it is *expected*
        to refuse: waiting for a lock it will never get would hang.
        """
        proc = subprocess.Popen(
            [
                sys.executable,
                str(self.wrapper),
                str(TOOLS_DIR),
                str(self.account),
                "controller",
                "--path",
                str(self.repo),
                "run",
                "--interval",
                "0.05",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env={**os.environ},
        )
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        return proc

    def test_a_run_establishing_inside_the_uninstalls_window_wins_or_is_refused(self):
        # The window a read-only check can never close: the uninstall has
        # already decided nothing is running, and the run begins before it
        # acts. Whichever reaches the lock first must win outright — what must
        # never happen is both succeeding, which is how a controller ends up
        # running with its job, record entry, and links removed.
        self.install()
        decided = threading.Event()
        original = service.uninstall_plan

        def slow_plan(job):
            plan = original(job)
            decided.set()
            # Wide enough that the run below lands squarely inside the window.
            time.sleep(0.6)
            return plan

        patched = mock.patch.object(service, "uninstall_plan", slow_plan)
        patched.start()
        self.addCleanup(patched.stop)

        outcome = {}

        def uninstall_in_thread():
            try:
                outcome["result"] = self.uninstall()
            except installer.InstallError as error:
                outcome["error"] = error

        remover = threading.Thread(target=uninstall_in_thread)
        remover.start()
        try:
            decided.wait(timeout=30)
            proc = self.foreground_run()
        finally:
            remover.join(timeout=60)

        # The run got the lock first, so the uninstall was refused rather than
        # removing anything out from under it.
        self.assertIn("error", outcome, "the uninstall removed a job under a live run")
        self.assertIn("already running", str(outcome["error"]))
        self.assertIsNone(proc.poll(), "the run was left running")
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertIn("acme/widgets", self.record()["repositories"])
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertTrue((self.install_dir / name).is_file())

    def test_a_run_beginning_inside_an_uninstall_that_holds_the_lock_refuses(self):
        # The other direction, and why the uninstall may take the lock at all:
        # once it holds it, a run cannot come into existence beneath it, and
        # the run is told what it lost to rather than that a controller it will
        # never find is running.
        self.install()
        removing = threading.Event()
        original = self.manager.uninstall_definition

        def slow_uninstall(identifier):
            removing.set()
            time.sleep(0.6)
            return original(identifier)

        self.manager.uninstall_definition = slow_uninstall
        self.addCleanup(setattr, self.manager, "uninstall_definition", original)

        outcome = {}

        def uninstall_in_thread():
            try:
                outcome["result"] = self.uninstall()
            except installer.InstallError as error:  # pragma: no cover
                outcome["error"] = error

        remover = threading.Thread(target=uninstall_in_thread)
        remover.start()
        try:
            removing.wait(timeout=30)
            proc = self.launch_run()
            stderr = proc.communicate(timeout=60)[1]
        finally:
            remover.join(timeout=60)

        self.assertNotEqual(proc.returncode, 0, "a run began inside the removal")
        self.assertIn("installing or removing this job", stderr)
        self.assertNotIn("error", outcome)
        self.assertTrue(outcome["result"]["uninstalled"])

    def test_the_lock_probe_neither_creates_nor_takes_anything(self):
        # A check must leave the account exactly as it found it, and must never
        # become a hold that the next run would then contend with.
        job = self.job()
        self.assertIsNone(service.run_lock_owner(job))
        self.assertFalse(os.path.lexists(service.run_lock_path(job.slug)))
        self.install()
        self.assertIsNone(service.run_lock_owner(job))


class ConvergenceTests(InstallerFixture):
    def test_reinstalling_converges(self):
        first = self.install()
        second = self.install()
        self.assertEqual(
            [link["result"] for link in first["links"].values()],
            ["created"] * len(installer.LINKED_MODULES),
        )
        self.assertEqual(
            [link["result"] for link in second["links"].values()],
            ["unchanged"] * len(installer.LINKED_MODULES),
        )
        self.assertEqual(first["job"]["label"], second["job"]["label"])
        self.assertEqual(sorted(self.record()["repositories"]), ["acme/widgets"])
        self.assertEqual(
            sorted(path.name for path in self.install_dir.iterdir()),
            sorted(installer.LINKED_MODULES),
        )
        self.assertEqual(
            sorted(path.name for path in (self.manager.root / "definitions").iterdir()),
            [f"{self.label()}.json"],
        )

    def test_an_upgrade_replaces_its_links_rather_than_accumulating_them(self):
        self.install()
        moved = self.checkout("widgets-moved", self.remote_url)
        upgraded = self.install(moved)
        self.assertEqual(
            [link["result"] for link in upgraded["links"].values()],
            ["updated"] * len(installer.LINKED_MODULES),
        )
        self.assertEqual(
            sorted(path.name for path in self.install_dir.iterdir()),
            sorted(installer.LINKED_MODULES),
        )
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertEqual(
                    (self.install_dir / name).resolve(),
                    (moved / "tools" / name).resolve(),
                )

    def test_a_users_broken_link_at_a_managed_path_stops_the_install(self):
        # End to end, because this is where it matters: an install that
        # replaced it would destroy a link only its owner can account for.
        self.install_dir.mkdir(parents=True)
        guarded = self.install_dir / "service_manager.py"
        guarded.symlink_to(self.root / "their-checkout" / "service_manager.py")
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn("does not exist", str(raised.exception))
        self.assertEqual(
            os.readlink(guarded), str(self.root / "their-checkout" / "service_manager.py")
        )
        self.assertEqual(self.manager.call_names(), [])
        self.assertEqual(self.record(), {})

    def test_an_uninstall_leaves_a_broken_link_it_cannot_account_for(self):
        self.install()
        link = self.install_dir / "service_manager.py"
        link.unlink()
        link.symlink_to(self.root / "gone" / "service_manager.py")
        result = self.uninstall()
        self.assertEqual(result["links"]["service_manager.py"]["result"], "kept")
        self.assertTrue(os.path.lexists(link))
        # The links it can account for still go.
        self.assertFalse(os.path.lexists(self.install_dir / "kanban_config.py"))

    def test_an_ordinary_user_file_at_a_link_path_is_preserved(self):
        self.install_dir.mkdir(parents=True)
        guarded = self.install_dir / "kanban_config.py"
        guarded.write_text("my own script\n", encoding="utf-8")
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn("not a symlink", str(raised.exception))
        self.assertEqual(guarded.read_text(encoding="utf-8"), "my own script\n")
        # Refused before the first write, so no other link and no job were left
        # behind by the attempt.
        self.assertEqual(
            sorted(path.name for path in self.install_dir.iterdir()),
            ["kanban_config.py"],
        )
        self.assertEqual(self.manager.call_names(), [])
        self.assertEqual(self.record(), {})


class CanonicalBackendTests(InstallerFixture):
    def test_the_installer_installs_no_backend_of_its_own(self):
        result = self.install()
        self.assertEqual(
            Path(result["backend_path"]), self.canonical_backend.resolve()
        )
        # The one global reviewer installation is resolved, never copied,
        # linked, or shadowed by one of this installer's own.
        self.assertNotIn(
            "approve_issues.py", [path.name for path in self.install_dir.iterdir()]
        )

    def test_an_absent_record_and_backend_is_refused_with_the_remediation(self):
        # No override and no record at all: the shape a host that has never run
        # `install_issue_review.py` has. It is refused rather than repaired
        # here, because making a second reviewer installation is exactly what
        # this installer must never do.
        os.environ.pop("KANBAN_ISSUE_REVIEW_INSTALL_DIR", None)
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn("install_issue_review.py", str(raised.exception))
        self.assertFalse(self.install_dir.exists())
        # And no reviewer installation was made anywhere this platform would
        # look for one, which is the half of requirement 6 the refusal alone
        # does not establish.
        self.assertFalse(
            service.kanban_config.default_issue_review_install_dir().exists()
        )
        self.assertFalse(service.kanban_config.installed_issue_review_dir().exists())

    def test_a_selected_but_missing_backend_never_falls_through(self):
        # The override is what the operator chose. Falling back to the recorded
        # installation would silently review with a backend they did not pick.
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        os.environ["KANBAN_ISSUE_REVIEW_INSTALL_DIR"] = str(elsewhere)
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn(str(elsewhere / "approve_issues.py"), str(raised.exception))
        self.assertIn("install_issue_review.py", str(raised.exception))
        self.assertFalse(self.install_dir.exists())

    def test_a_recorded_but_missing_backend_is_refused(self):
        os.environ.pop("KANBAN_ISSUE_REVIEW_INSTALL_DIR", None)
        review_root = self.root / "issue-review"
        review_root.mkdir()
        record = review_root / "config.json"
        record.write_text(
            json.dumps({"backend_path": str(review_root / "approve_issues.py")}),
            encoding="utf-8",
        )
        with mock.patch.object(
            service.kanban_config, "issue_review_record_path", lambda: record
        ):
            with self.assertRaises(installer.InstallError) as raised:
                self.install()
        self.assertIn(str(review_root / "approve_issues.py"), str(raised.exception))
        self.assertIn("install_issue_review.py", str(raised.exception))
        self.assertFalse(self.install_dir.exists())

    def test_an_unreadable_record_is_refused_with_the_remediation_too(self):
        os.environ.pop("KANBAN_ISSUE_REVIEW_INSTALL_DIR", None)
        review_root = self.root / "issue-review"
        review_root.mkdir()
        record = review_root / "config.json"
        record.write_text("{not json", encoding="utf-8")
        with mock.patch.object(
            service.kanban_config, "issue_review_record_path", lambda: record
        ):
            with self.assertRaises(installer.InstallError) as raised:
                self.install()
        self.assertIn("unreadable", str(raised.exception))
        self.assertIn("install_issue_review.py", str(raised.exception))
        self.assertFalse(self.install_dir.exists())

    def test_a_relative_override_is_written_into_the_definition_absolute(self):
        # The installer reads a relative override against its own working
        # directory; the job runs with the checkout as its own. Persisting the
        # raw value would point the job at a directory the installer never
        # checked, or at none at all.
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(self.root)
        os.environ["KANBAN_ISSUE_REVIEW_INSTALL_DIR"] = "canonical"
        result = self.install()
        self.assertEqual(
            Path(result["backend_path"]).resolve(), self.canonical_backend.resolve()
        )
        self.assertTrue(Path(result["backend_path"]).is_absolute())

        definition = json.loads(
            self.manager.definition_path(self.label()).read_text(encoding="utf-8")
        )
        recorded = definition["environment"]["KANBAN_ISSUE_REVIEW_INSTALL_DIR"]
        self.assertTrue(Path(recorded).is_absolute())
        self.assertEqual(Path(recorded).resolve(), self.backend_dir.resolve())
        # And it is not the checkout-relative reading the job would otherwise
        # have performed from its own working directory.
        self.assertNotEqual(
            Path(recorded), (Path(definition["working_directory"]) / "canonical")
        )

    def definition_override(self):
        definition = json.loads(
            self.manager.definition_path(self.label()).read_text(encoding="utf-8")
        )
        return definition["environment"].get("KANBAN_ISSUE_REVIEW_INSTALL_DIR")

    def test_a_refresh_from_an_empty_environment_keeps_the_selected_reviewer(self):
        # The definition is rewritten on every start, and a start issued by
        # Kanban or by a service manager carries no environment. Deriving the
        # override from that environment alone would silently rewrite the job
        # to resolve some other reviewer than the one its install verified.
        self.install()
        self.assertEqual(
            self.definition_override(), str(self.backend_dir.resolve())
        )

        os.environ.pop("KANBAN_ISSUE_REVIEW_INSTALL_DIR", None)
        refreshed = service.resolve_job(self.repo)
        service.install_job(refreshed, self.install_dir)
        self.assertEqual(
            self.definition_override(), str(self.backend_dir.resolve())
        )
        self.assertEqual(
            self.record()["repositories"]["acme/widgets"]["backend_install_dir"],
            str(self.backend_dir.resolve()),
        )

    def test_a_start_from_an_empty_environment_keeps_it_too(self):
        self.install()
        os.environ.pop("KANBAN_ISSUE_REVIEW_INSTALL_DIR", None)
        proc = subprocess.run(
            [
                sys.executable,
                str(self.wrapper),
                str(self.install_dir),
                str(self.account),
                "controller",
                "--json",
                "--path",
                str(self.repo),
                "start",
            ],
            capture_output=True,
            text=True,
            timeout=60,
            env={
                "PATH": os.defpath,
                "FIXTURE_SERVICE_MANAGER": str(self.manager.root),
                "FIXTURE_TOOLS": str(TOOLS_DIR),
            },
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(json.loads(proc.stdout)["started"])
        self.assertEqual(
            self.definition_override(), str(self.backend_dir.resolve())
        )

    def test_a_reinstall_from_an_empty_environment_verifies_that_reviewer(self):
        # And the installer checks the backend the definition will name rather
        # than the one its own shell points at, so a missing recorded reviewer
        # is refused instead of quietly replaced by the default.
        self.install()
        os.environ.pop("KANBAN_ISSUE_REVIEW_INSTALL_DIR", None)
        self.canonical_backend.unlink()
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn(str(self.canonical_backend.resolve()), str(raised.exception))
        self.assertIn("install_issue_review.py", str(raised.exception))

    def test_a_half_installed_backend_is_refused_before_a_job_is_made(self):
        # Issue #483 gave the backend a third module; `approve_issues.py`
        # imports both companions at module scope, so a resolvable script
        # beside a missing one is a service with no reviewer it can start --
        # which this module's install contract says is not an installation.
        # Each companion in turn, so neither is covered only by the other.
        for name in installer.BACKEND_COMPANION_MODULES:
            with self.subTest(module=name):
                companion = self.backend_dir / name
                body = companion.read_text(encoding="utf-8")
                companion.unlink()
                try:
                    with self.assertRaises(installer.InstallError) as raised:
                        self.install()
                    message = str(raised.exception)
                    self.assertIn(str(companion), message)
                    self.assertIn("install_issue_review.py", message)
                    # Refused before the first write, like every other
                    # backend refusal: no job definition may exist.
                    self.assertFalse(
                        self.manager.definition_path(self.label()).exists()
                    )
                finally:
                    companion.write_text(body, encoding="utf-8")

    def test_an_install_with_no_selection_records_none(self):
        # The ordinary case: no override anywhere, so the job resolves through
        # the fixed issue-review record and needs no environment at all.
        os.environ.pop("KANBAN_ISSUE_REVIEW_INSTALL_DIR", None)
        # Asked of the resolver rather than spelled here: since issue #357 the
        # location is this platform's own, so a hardcoded one would install
        # somewhere the resolver never looks on every host but the author's.
        review_root = service.kanban_config.default_issue_review_install_dir()
        review_root.mkdir(parents=True, exist_ok=True)
        (review_root / "approve_issues.py").write_text("backend\n", encoding="utf-8")
        for name in installer.BACKEND_COMPANION_MODULES:
            (review_root / name).write_text(f"# {name}\n", encoding="utf-8")
        self.install()
        self.assertIsNone(self.definition_override())
        self.assertNotIn(
            "backend_install_dir", self.record()["repositories"]["acme/widgets"]
        )

    def test_the_installed_job_runs_the_backend_the_installer_verified(self):
        # The override is a process's choice; the job outlives that process, so
        # the selection has to be written into the definition or the job would
        # resolve a different reviewer than the one that was checked.
        self.install()
        definition = json.loads(
            self.manager.definition_path(self.label()).read_text(encoding="utf-8")
        )
        self.assertEqual(
            definition["environment"]["KANBAN_ISSUE_REVIEW_INSTALL_DIR"],
            str(self.backend_dir.resolve()),
        )


class LegacyDaemonTests(InstallerFixture):
    def test_a_daemon_holding_the_canonical_lock_is_refused_by_name(self):
        holder = LockHolder(self.repo, "daemon")
        self.addCleanup(holder.close)
        recorded = holder.path.read_text(encoding="utf-8")
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn("background approval daemon", str(raised.exception))
        self.assertIn("never adopts or terminates it", str(raised.exception))
        # Neither adopted nor killed nor migrated: it is still running, still
        # holding, and its own metadata is untouched.
        self.assertTrue(holder.alive())
        self.assertEqual(holder.path.read_text(encoding="utf-8"), recorded)
        self.assertFalse(self.install_dir.exists())
        self.assertEqual(self.manager.call_names(), [])

    def test_ordinary_contention_does_not_refuse_an_install(self):
        # An interactive review holding the lock is the normal busy outcome the
        # poll loop backs off on, not a conflicting daemon.
        holder = LockHolder(self.repo, "queue")
        self.addCleanup(holder.close)
        self.assertTrue(self.install()["installed"])


class UninstallTests(InstallerFixture):
    def test_uninstall_leaves_no_job_link_or_record_entry(self):
        self.install()
        result = self.uninstall()
        self.assertTrue(result["uninstalled"])
        self.assertTrue(result["job"]["unloaded"])
        self.assertTrue(result["job"]["definition_removed"])
        self.assertFalse(self.manager.is_loaded(self.label()))
        self.assertFalse(self.manager.is_running(self.label()))
        self.assertFalse(self.manager.definition_path(self.label()).exists())
        self.assertEqual(self.record().get("repositories"), {})
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertFalse(os.path.lexists(self.install_dir / name))

    def test_uninstall_keeps_links_another_installed_job_still_runs_from(self):
        gadgets = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.install()
        self.install(gadgets)
        result = self.uninstall()
        self.assertEqual(result["dependent_repositories"], ["acme/gadgets"])
        self.assertEqual(
            [link["result"] for link in result["links"].values()],
            ["kept"] * len(installer.LINKED_MODULES),
        )
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertTrue((self.install_dir / name).is_symlink())
        # And the repository that is still installed keeps its own job.
        self.assertEqual(sorted(self.record()["repositories"]), ["acme/gadgets"])
        self.assertTrue(self.manager.is_loaded(self.label("acme/gadgets")))

    def test_a_job_installed_elsewhere_does_not_keep_these_links(self):
        # The links are shared within one install directory, not across all of
        # them. A second repository installed into its own directory runs its
        # own copies, so keeping this directory's links for its sake would
        # strand them with nothing to remove them.
        gadgets = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        elsewhere = self.root / "elsewhere"
        self.install()
        installer.install(gadgets, elsewhere, config_path=None, dry_run=False)

        result = self.uninstall()
        self.assertEqual(result["dependent_repositories"], [])
        self.assertEqual(
            [link["result"] for link in result["links"].values()],
            ["removed"] * len(installer.LINKED_MODULES),
        )
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertFalse(os.path.lexists(self.install_dir / name))
                # And the other installation is untouched, because it is a
                # different installation.
                self.assertTrue((elsewhere / name).is_symlink())
        self.assertEqual(sorted(self.record()["repositories"]), ["acme/gadgets"])

    def test_an_entry_naming_no_install_directory_keeps_the_links(self):
        # Fails closed: such a record could have been written by this
        # installation, and a kept link nothing needs is recoverable while a
        # removed one a live job runs from is not.
        gadgets = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.install()
        self.install(gadgets)
        service.merge_repository_record(
            "acme/gadgets", {}, discard=("install_dir",)
        )
        result = self.uninstall()
        self.assertEqual(result["dependent_repositories"], ["acme/gadgets"])
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertTrue((self.install_dir / name).is_symlink())

    def test_an_uninstall_pointed_at_the_wrong_directory_is_refused(self):
        # The job and its record entry are named by identity alone, so an
        # uninstall that removed them and then deleted links in a directory the
        # job never ran from would strand the links it actually did.
        elsewhere = self.root / "elsewhere"
        self.install()
        with self.assertRaises(installer.InstallError) as raised:
            installer.uninstall(self.repo, elsewhere, dry_run=False)
        self.assertIn(str(self.install_dir), str(raised.exception))
        self.assertIn(str(elsewhere), str(raised.exception))
        # Nothing was removed anywhere.
        self.assertIn("acme/widgets", self.record()["repositories"])
        self.assertTrue(self.manager.is_loaded(self.label()))
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink())

    def test_the_wrong_directory_is_refused_by_the_dry_run_too(self):
        self.install()
        with self.assertRaises(installer.InstallError):
            installer.uninstall(self.repo, self.root / "elsewhere", dry_run=True)

    def test_uninstalling_with_no_directory_finds_the_recorded_one(self):
        # Which is why the refusal above costs nothing: the default resolves
        # the installation the job is actually in.
        moved = self.root / "moved-installation"
        self.install()
        installer.install(self.repo, moved, config_path=None, dry_run=False)
        self.assertEqual(installer.selected_install_dir(self.repo, None), moved)
        result = installer.uninstall(
            self.repo, installer.selected_install_dir(self.repo, None), dry_run=False
        )
        self.assertTrue(result["uninstalled"])
        for name in installer.LINKED_MODULES:
            with self.subTest(module=name):
                self.assertFalse(os.path.lexists(moved / name))

    def test_uninstall_never_removes_a_link_it_does_not_recognize(self):
        self.install()
        foreign = self.root / "theirs.py"
        foreign.write_text("someone else's file\n", encoding="utf-8")
        link = self.install_dir / "service_manager.py"
        link.unlink()
        link.symlink_to(foreign)
        result = self.uninstall()
        self.assertEqual(result["links"]["service_manager.py"]["result"], "kept")
        self.assertTrue(link.is_symlink())
        self.assertEqual(foreign.read_text(encoding="utf-8"), "someone else's file\n")

    def test_uninstalling_a_repository_that_was_never_installed_is_not_an_error(self):
        result = self.uninstall()
        self.assertTrue(result["uninstalled"])
        self.assertFalse(result["job"]["unloaded"])


class DryRunTests(InstallerFixture):
    def assert_plan_matches(self, plan, performed):
        """Every key the plan reported, reported the same by the mutation.

        The mutation reports strictly more -- what was unloaded, what the
        record path ended up being -- so the plan is checked as a subset rather
        than as an equal document, which is exactly the promise "reports
        exactly what would change" makes.
        """
        for key, value in plan.items():
            if key in {"dry_run", "installed", "uninstalled"}:
                continue
            with self.subTest(key=key):
                self.assertEqual(performed[key], value)

    def test_a_dry_run_writes_nothing(self):
        result = self.install(dry_run=True)
        self.assertTrue(result["dry_run"])
        self.assertFalse(result["installed"])
        self.assertFalse(self.install_dir.exists())
        self.assertFalse(service.discovery_record_path().exists())
        self.assertFalse(self.job().runtime_dir.exists())
        self.assertEqual(self.manager.call_names(), [])

    def test_the_install_plan_is_what_the_install_performs(self):
        plan = self.install(dry_run=True)
        performed = self.install()
        self.assert_plan_matches(plan["links"], performed["links"])
        self.assert_plan_matches(plan["job"], performed["job"])
        self.assertEqual(plan["backend_path"], performed["backend_path"])
        self.assertEqual(plan["install_dir"], performed["install_dir"])

    def test_the_upgrade_plan_is_what_the_upgrade_performs(self):
        self.install()
        moved = self.checkout("widgets-moved", self.remote_url)
        plan = self.install(moved, dry_run=True)
        self.assertEqual(
            [link["result"] for link in plan["links"].values()],
            ["updated"] * len(installer.LINKED_MODULES),
        )
        performed = self.install(moved)
        self.assert_plan_matches(plan["links"], performed["links"])
        self.assert_plan_matches(plan["job"], performed["job"])

    def test_the_uninstall_plan_is_what_the_uninstall_performs(self):
        self.install()
        plan = self.uninstall(dry_run=True)
        self.assertFalse(plan["uninstalled"])
        self.assertTrue(plan["job"]["record_entry_removed"])
        # Still installed: the plan described the removal without doing it.
        self.assertTrue(self.manager.is_loaded(self.label()))
        self.assertIn("acme/widgets", self.record()["repositories"])
        for name in installer.LINKED_MODULES:
            self.assertTrue((self.install_dir / name).is_symlink())

        performed = self.uninstall()
        self.assert_plan_matches(plan["links"], performed["links"])
        self.assert_plan_matches(plan["job"], performed["job"])
        self.assertEqual(
            plan["dependent_repositories"], performed["dependent_repositories"]
        )

    def test_a_refused_install_is_refused_by_the_dry_run_too(self):
        # A plan that ignored the refusals would report an installation that
        # could not actually happen.
        self.write_status(
            self.job(), state=service.STATE_RUNNING, repo=self.repo, runner_pid=os.getpid()
        )
        with self.assertRaises(installer.InstallError):
            self.install(dry_run=True)


class HostRefusalTests(InstallerFixture):
    @contextlib.contextmanager
    def unmanaged_host(self):
        """This fixture with its fake service manager withdrawn and the host
        answering that it has none."""
        with (
            mock.patch.object(
                service_manager, "detect_service_manager", return_value=None
            ),
            mock.patch.object(installer, "service_backend", REAL_INSTALLER_BACKEND),
            mock.patch.object(service, "service_backend", REAL_SERVICE_BACKEND),
        ):
            yield

    def test_an_unsupported_host_is_refused_before_anything_is_written(self):
        # The selection's own refusal, reached before the first link, the first
        # definition, and the first record write: an installation that could
        # never be completed or controlled must not leave half of itself
        # behind.
        with self.unmanaged_host():
            with self.assertRaises(installer.InstallError) as raised:
                installer.install(
                    self.repo, self.install_dir, config_path=None, dry_run=False
                )
        self.assertIn("No supported service manager found", str(raised.exception))
        self.assertFalse(self.install_dir.exists())
        self.assertFalse(service.discovery_record_path().exists())
        self.assertFalse(self.job().runtime_dir.exists())

    def test_an_unsupported_host_refuses_an_uninstall_too(self):
        with self.unmanaged_host():
            with self.assertRaises(installer.InstallError):
                installer.uninstall(self.repo, self.install_dir, dry_run=False)

    def test_a_host_that_cannot_supervise_a_process_group_is_refused_too(self):
        # The other half of requirement 14, and this service's own: a host with
        # a service manager but no POSIX process semantics could load this job
        # and never run it, so the refusal comes before the definition rather
        # than at the first start.
        with mock.patch.object(service, "fcntl", None):
            with self.assertRaises(installer.InstallError) as raised:
                self.install()
        self.assertIn("only on POSIX hosts", str(raised.exception))
        self.assertFalse(self.install_dir.exists())
        self.assertEqual(self.manager.call_names(), [])
        self.assertFalse(service.discovery_record_path().exists())

    def test_the_selection_refusal_arrives_in_the_installers_vocabulary(self):
        # Not a `NoServiceManagerError` and not the controller's
        # `ServiceError`: the caller that reports `{"error": ...}` must never
        # see a third exception type.
        with self.unmanaged_host():
            with self.assertRaises(installer.InstallError):
                installer.service_backend()


class RediscoveryTests(InstallerFixture):
    def test_a_custom_install_dir_and_config_path_are_rediscoverable(self):
        config = self.root / "kanban.toml"
        config.write_text("", encoding="utf-8")
        self.install(config_path=str(config))

        # A process given no environment at all: no $HOME, no
        # KANBAN_ISSUE_APPROVAL_INSTALL_DIR, no KANBAN_ISSUE_REVIEW_INSTALL_DIR.
        # The account root is still redirected, because that is the OS account
        # rather than anything a process is started with -- which is exactly
        # why the record hangs off it.
        proc = subprocess.run(
            [
                sys.executable,
                str(self.wrapper),
                str(TOOLS_DIR),
                str(self.account),
                "record",
                self.identity,
            ],
            capture_output=True,
            text=True,
            env={"PATH": os.defpath},
            timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rediscovered = json.loads(proc.stdout)
        self.assertEqual(rediscovered["install_dir"], str(self.install_dir))
        self.assertEqual(rediscovered["config_path"], str(config.resolve()))

    def test_a_reinstall_with_no_options_converges_on_the_recorded_installation(self):
        self.install()
        self.assertEqual(
            installer.selected_install_dir(self.repo, None), self.install_dir
        )

    def test_the_installed_job_carries_its_config_path(self):
        config = self.root / "kanban.toml"
        config.write_text("", encoding="utf-8")
        self.install(config_path=str(config))
        definition = json.loads(
            self.manager.definition_path(self.label()).read_text(encoding="utf-8")
        )
        arguments = definition["program_arguments"]
        self.assertIn("--config", arguments)
        self.assertEqual(
            arguments[arguments.index("--config") + 1], str(config.resolve())
        )
        self.assertEqual(arguments[-1], "run")

    def test_a_relative_config_path_is_recorded_absolute(self):
        # The definition is launched with the checkout as its working
        # directory, so a relative path recorded as given would name a
        # different file than the operator typed it in front of.
        config = self.root / "kanban.toml"
        config.write_text("", encoding="utf-8")
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(self.root)
        self.install(config_path="kanban.toml")
        recorded = self.record()["repositories"]["acme/widgets"]["config_path"]
        self.assertTrue(Path(recorded).is_absolute())
        self.assertEqual(Path(recorded).resolve(), config.resolve())

    def test_a_later_start_keeps_the_recorded_config_without_being_told(self):
        # The definition is refreshed on every start. A start issued with no
        # flags -- which is what Kanban and a service manager both do -- must
        # therefore rebuild it with the configuration the install selected,
        # rather than silently dropping `--config` from the job.
        config = self.root / "kanban.toml"
        config.write_text("", encoding="utf-8")
        self.install(config_path=str(config))

        refreshed = service.resolve_job(self.repo)
        self.assertEqual(refreshed.config_path, str(config.resolve()))
        service.install_job(refreshed, self.install_dir)
        definition = json.loads(
            self.manager.definition_path(self.label()).read_text(encoding="utf-8")
        )
        arguments = definition["program_arguments"]
        self.assertIn("--config", arguments)
        self.assertEqual(
            arguments[arguments.index("--config") + 1], str(config.resolve())
        )
        self.assertEqual(
            self.record()["repositories"]["acme/widgets"]["config_path"],
            str(config.resolve()),
        )

    def test_a_process_holding_no_environment_resolves_the_recorded_config(self):
        config = self.root / "kanban.toml"
        config.write_text("", encoding="utf-8")
        self.install(config_path=str(config))
        proc = subprocess.run(
            [
                sys.executable,
                str(self.wrapper),
                str(self.install_dir),
                str(self.account),
                "controller",
                "--json",
                "--path",
                str(self.repo),
                "status",
            ],
            capture_output=True,
            text=True,
            env={"PATH": os.defpath},
            timeout=60,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)["repository"], self.identity)
        # And the same process resolves the recorded selection rather than the
        # shared default, which is what a relaunched job depends on.
        reread = subprocess.run(
            [
                sys.executable,
                str(self.wrapper),
                str(TOOLS_DIR),
                str(self.account),
                "record",
                self.identity,
            ],
            capture_output=True,
            text=True,
            env={"PATH": os.defpath},
            timeout=60,
        )
        self.assertEqual(reread.returncode, 0, reread.stderr)
        self.assertEqual(
            json.loads(reread.stdout)["config_path"], str(config.resolve())
        )

    def test_an_explicit_config_still_overrides_the_recorded_one(self):
        installed = self.root / "installed.toml"
        chosen = self.root / "chosen.toml"
        for path in (installed, chosen):
            path.write_text("", encoding="utf-8")
        self.install(config_path=str(installed))
        job = service.resolve_job(self.repo, config_path=str(chosen))
        self.assertEqual(job.config_path, str(chosen))

    def test_one_repositorys_config_path_never_displaces_anothers(self):
        gadgets = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        widgets_config = self.root / "widgets.toml"
        gadgets_config = self.root / "gadgets.toml"
        for path in (widgets_config, gadgets_config):
            path.write_text("", encoding="utf-8")
        self.install(config_path=str(widgets_config))
        self.install(gadgets, config_path=str(gadgets_config))
        records = self.record()["repositories"]
        self.assertEqual(
            records["acme/widgets"]["config_path"], str(widgets_config.resolve())
        )
        self.assertEqual(
            records["acme/gadgets"]["config_path"], str(gadgets_config.resolve())
        )


class RecordSerializationTests(InstallerFixture):
    """Requirement 4: a concurrent writer cannot drop an existing entry."""

    def test_concurrent_updates_are_serialized(self):
        record = service.discovery_record_path()
        record.parent.mkdir(parents=True, exist_ok=True)
        state = {"active": 0, "peak": 0}
        guard = threading.Lock()

        def transform_for(index):
            def transform(document):
                with guard:
                    state["active"] += 1
                    state["peak"] = max(state["peak"], state["active"])
                # Long enough that an unserialized reader would certainly land
                # inside another writer's read-modify-write window.
                time.sleep(0.05)
                with guard:
                    state["active"] -= 1
                return {**document, f"key-{index}": index}

            return transform

        threads = [
            threading.Thread(
                target=service.update_json_document, args=(record, transform_for(index))
            )
            for index in range(6)
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=30)

        self.assertEqual(state["peak"], 1, "two writers were inside the document at once")
        document = json.loads(record.read_text(encoding="utf-8"))
        self.assertEqual(
            sorted(key for key in document if key.startswith("key-")),
            [f"key-{index}" for index in range(6)],
        )

    def test_concurrent_installs_keep_every_repositorys_entry(self):
        identities = [f"acme/repo-{index}" for index in range(8)]
        barrier = threading.Barrier(len(identities))
        failures = []

        def write(identity):
            try:
                # Released together, so the writes really overlap rather than
                # merely following one another.
                barrier.wait(timeout=30)
                service.merge_repository_record(identity, {"fake_identifier": identity})
            except Exception as error:  # pragma: no cover - reported below
                failures.append(error)

        threads = [threading.Thread(target=write, args=(identity,)) for identity in identities]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(timeout=30)

        self.assertEqual(failures, [])
        self.assertEqual(sorted(self.record()["repositories"]), sorted(identities))

    def test_reinstalling_under_another_backend_leaves_one_backends_keys(self):
        # The entry is a discriminated union. A reinstall that added the second
        # manager's keys beside the first's would produce the mixed shape a
        # reader is required to fail closed on -- reached by reinstalling
        # rather than by hand-editing, which is what makes it worth refusing.
        service.merge_repository_record(
            "acme/widgets",
            {
                "backend": "launchd",
                "launchd_label": "com.coghex.issue-approval.acme.widgets",
                "plist_path": "/somewhere/com.coghex.issue-approval.acme.widgets.plist",
                "config_path": "/home/user/kanban.toml",
            },
        )
        self.install()
        entry = self.record()["repositories"]["acme/widgets"]
        self.assertEqual(entry["backend"], "fake-manager")
        for superseded in ("launchd_label", "plist_path", "systemd_unit", "unit_path"):
            with self.subTest(key=superseded):
                self.assertNotIn(superseded, entry)
        # And nothing an installer persisted goes with them.
        self.assertEqual(entry["config_path"], "/home/user/kanban.toml")
        self.assertEqual(entry["install_dir"], str(self.install_dir))

    def test_a_record_written_by_this_service_is_private(self):
        self.install()
        path = service.discovery_record_path()
        self.assertFalse(path.is_symlink())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_a_symlinked_record_is_refused(self):
        record = service.discovery_record_path()
        record.parent.mkdir(parents=True, exist_ok=True)
        outside = self.root / "outside.json"
        outside.write_text("keep\n", encoding="utf-8")
        record.symlink_to(outside)
        with self.assertRaises(service.ServiceError):
            service.merge_repository_record("acme/widgets", {"a": 1})
        self.assertEqual(outside.read_text(encoding="utf-8"), "keep\n")


class IdentityTests(InstallerFixture):
    def test_a_checkout_with_no_supported_github_remote_cannot_be_installed(self):
        local = self.checkout("local", str(self.root / "bare.git"))
        with self.assertRaises(installer.InstallError) as raised:
            self.install(local)
        self.assertIn("supported GitHub repository", str(raised.exception))
        self.assertFalse(self.install_dir.exists())

    def test_a_config_naming_another_remote_does_not_move_the_identity(self):
        # The identity is resolved through the shared Kanban configuration, so
        # a repository's own --config decides what its controller runs with and
        # never which repository the job is for. Otherwise an uninstall would
        # look for an entry the install never wrote.
        config = self.root / "kanban.toml"
        config.write_text('remote_name = "upstream"\n', encoding="utf-8")
        subprocess.run(
            [
                "git",
                "-C",
                str(self.repo),
                "remote",
                "add",
                "upstream",
                "git@github.com:upstream-owner/widgets.git",
            ],
            check=True,
            capture_output=True,
        )
        self.install(config_path=str(config))
        self.assertEqual(sorted(self.record()["repositories"]), ["acme/widgets"])
        removed = self.uninstall()
        self.assertEqual(removed["job"]["repository"], "acme/widgets")
        self.assertEqual(self.record()["repositories"], {})

    def test_a_divergent_controller_copy_is_refused(self):
        # The job is planned by the module this installer imported and run by
        # the copy it links, so two copies that differ would put the definition
        # and its runner at different versions.
        controller = self.repo / "tools" / service.CONTROLLER_NAME
        controller.write_text(
            controller.read_text(encoding="utf-8") + "\n# an older copy\n",
            encoding="utf-8",
        )
        with self.assertRaises(installer.InstallError) as raised:
            self.install()
        self.assertIn(str(controller), str(raised.exception))
        self.assertIn("install_issue_approval.py", str(raised.exception))
        self.assertFalse(self.install_dir.exists())
        self.assertEqual(self.manager.call_names(), [])

    def test_an_identical_copy_in_another_checkout_is_accepted(self):
        # Which is the ordinary case: the installer is a tracked module, so a
        # checkout at the same commit carries the very same controller.
        self.assertNotEqual(
            (self.repo / "tools" / service.CONTROLLER_NAME).resolve(),
            Path(service.__file__).resolve(),
        )
        self.assertTrue(self.install()["installed"])

    def test_a_job_is_never_written_without_an_installed_controller(self):
        # The definition names the installed link, so writing one before that
        # link exists would install a job that fails at launch with nothing for
        # anyone to read.
        job = service.resolve_job(self.repo)
        with self.assertRaises(service.ServiceError) as raised:
            service.install_job(job, self.install_dir)
        self.assertIn("install_issue_approval.py", str(raised.exception))
        self.assertEqual(self.manager.call_names(), [])

    def test_a_dangling_controller_link_is_refused_like_an_absent_one(self):
        self.install()
        link = self.install_dir / service.CONTROLLER_NAME
        target = link.resolve()
        link.unlink()
        link.symlink_to(self.root / "gone" / service.CONTROLLER_NAME)
        self.assertTrue(os.path.lexists(link))
        with self.assertRaises(service.ServiceError) as raised:
            service.install_job(service.resolve_job(self.repo), self.install_dir)
        self.assertIn("install_issue_approval.py", str(raised.exception))
        self.assertTrue(target.is_file())

    def test_a_checkout_missing_a_linked_module_is_not_installable(self):
        (self.repo / "tools" / "service_manager.py").unlink()
        with self.assertRaises(installer.InstallError) as raised:
            installer.repository_root(self.repo)
        self.assertIn("service_manager.py", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
