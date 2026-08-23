"""Issues #367, #369 and #390: relocating a pre-XDG `~/Library` drainer
installation, carrying across whatever a writer puts back at the location it
emptied, and closing that location against a writer that arrives later still.

A host that installed before `tools/kanban_config.py` resolved the drainer's
managed paths per platform has its installation at the macOS-shaped locations,
and discovery keeps finding it there forever. These are the tests for the one
thing that moves it, and for the reconciliation that follows the removal: the
transition's locks serialize every writer queued on them, and a writer that
arrives afterwards contends with nothing, so what it recorded is carried across
and what cannot be carried is reported rather than chosen between. What no lock
and no sweep can reach — a controller predating every gate here that starts
after the run has finished looking — is answered by leaving it nothing to
write: the emptied record path and the emptied runtime root are both occupied
by objects the writers in that old copy fail on.

Hermetic throughout. The platform is simulated rather than read, `$HOME` and
both XDG base directories are redirected into a temporary tree, and no
`launchctl`, `systemctl`, GitHub or network call is ever made — the service
manager is a real backend driven through a runner that records instead of
spawning, so the definitions under test are the bytes that backend really
writes.

Every fixture produces its legacy installation through the *controller's own*
writers, under the resolution a pre-XDG host ran with: `install_job` writes the
definition and the record, `atomic_write_json` the status file, `write_incident`
the incident, and `service_log` the log. A hand-built directory tree would prove
the assertions and nothing about the thing being relocated, and empty
directories cannot show state loss.
"""

import contextlib
import dataclasses
import fcntl
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import drain_prs
import drain_prs_service
import install_drainer
import kanban_config
import service_manager


# Captured before any patching, so a fixture's own runner can still delegate
# the commands it is not standing in for — `git`, above all, which every
# checkout, identity and liveness probe below goes through for real.
REAL_INSTALLER_RUN = install_drainer.run
REAL_CONTROLLER_RUN = drain_prs_service.run_command
# The two the fixtures stand in for. Nothing here may reach a real service
# manager, and a command that escaped this set would be visible as an argument
# vector this suite never recorded.
MANAGED_COMMANDS = frozenset({"launchctl", "systemctl"})


def _completed(args):
    return subprocess.CompletedProcess(list(args), 0, "", "")


class RelocationFixture(unittest.TestCase):
    MACOS_INSTALL = "Library/Application Support/kanban/pr-drainer"
    MACOS_LOGS = "Library/Logs/kanban/pr-drainer"
    XDG_INSTALL = ".local/share/kanban/pr-drainer"
    XDG_LOGS = ".local/state/kanban/pr-drainer"

    def setUp(self):
        # Registered first so it runs last. The controller's managed paths are
        # module-level constants, and a suite that left them bound to this
        # fixture's temporary home would follow every later test in the
        # process.
        self.addCleanup(drain_prs_service.bind_managed_paths)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.units = self.root / "systemd" / "user"
        self.units.mkdir(parents=True)
        self.launch_agents = self.root / "LaunchAgents"
        self.launch_agents.mkdir()
        self.commands = []
        # What this host would answer about processes holding the retained lock
        # open. Simulated for the reason the service manager is: whether a
        # given host can read another process's descriptors, and what it finds,
        # is settled by `ProcessDescriptorTests` below, and pinning is what
        # makes every case here answer identically on a macOS laptop with no
        # `/proc` and on a Linux runner with one. `()` is "nobody else has it
        # open", which is what an ordinary host answers.
        self.lock_holders = ()
        self.lock_holders_reason = None
        self._platform = None
        self.addCleanup(self._release_platform)
        self._redirect_environment()
        self._redirect_modules()
        self.sources = self._make_source_checkout()

    # -- fixture wiring -----------------------------------------------------

    def _redirect_environment(self):
        # `PATH` survives because `git` has to be found; nothing else does, so
        # an ambient XDG_DATA_HOME, XDG_STATE_HOME or
        # KANBAN_DRAINER_INSTALL_DIR on the developer's own machine cannot
        # reach a case that never set one.
        patcher = mock.patch.dict(
            os.environ,
            {"HOME": str(self.home), "PATH": os.environ.get("PATH", "")},
            clear=True,
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def _redirect_modules(self):
        for module, name, value in (
            (service_manager, "HOME", self.home),
            (service_manager, "SYSTEMD_USER_DIR", self.units),
            (service_manager, "LAUNCH_AGENTS_DIR", self.launch_agents),
            (
                service_manager,
                "LEGACY_PLIST_PATH",
                self.launch_agents / f"{service_manager.LEGACY_LABEL}.plist",
            ),
            (drain_prs_service, "HOME", self.home),
            # The service's own startup snapshot of a value no fixture here
            # configures; left set, an incident write would try to deliver a
            # notification.
            (drain_prs_service, "NTFY_URL", None),
            (install_drainer, "run", self._installer_run),
            (drain_prs_service, "run_command", self._controller_run),
        ):
            patcher = mock.patch.object(module, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        # Pinned rather than probed: which manager a host has is settled by
        # `tools/test_service_manager.py`, and pinning is what makes these
        # cases answer identically on a macOS laptop and a Linux runner.
        patcher = mock.patch.object(
            service_manager,
            "detect_service_manager",
            return_value=service_manager.SYSTEMD,
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = mock.patch.object(
            install_drainer,
            "_processes_holding_open",
            lambda path: (self.lock_holders, self.lock_holders_reason),
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def _installer_run(self, args, *, check=True, env=None):
        if args and Path(args[0]).name in MANAGED_COMMANDS:
            self.commands.append(list(args))
            return _completed(args)
        return REAL_INSTALLER_RUN(args, check=check, env=env)

    def _controller_run(self, args, *, check=True):
        if args and Path(args[0]).name in MANAGED_COMMANDS:
            self.commands.append(list(args))
            return _completed(args)
        return REAL_CONTROLLER_RUN(args, check=check)

    def _release_platform(self):
        if self._platform is not None:
            self._platform.stop()
            self._platform = None

    def set_platform(self, name):
        """Resolve every managed path as `name` resolves it, from here on.

        The platform question is simulated because it is the question the
        relocation asks, and because a pre-XDG host is exactly a host whose
        resolution said one thing when it installed and says another now.
        """
        self._release_platform()
        self._platform = mock.patch.object(kanban_config.sys, "platform", name)
        self._platform.start()
        drain_prs_service.bind_managed_paths()

    def _make_source_checkout(self):
        """The tracked modules an install links. Stand-ins, because what a
        link points at is never executed here."""
        tools = self.root / "kanban" / "tools"
        tools.mkdir(parents=True)
        sources = {}
        for key, name in (
            ("drainer", "drain_prs.py"),
            ("controller", "drain_prs_service.py"),
            ("config_module", "kanban_config.py"),
            ("models_module", "kanban_models.py"),
            ("service_manager", "service_manager.py"),
        ):
            path = tools / name
            path.write_text(f"# stand-in for {name}\n", encoding="utf-8")
            sources[key] = path
        return sources

    # -- fixture construction ----------------------------------------------

    def make_checkout(self, name, remote_url):
        """A real git checkout of a GitHub repository. No network: `git remote
        add` only writes the URL into `.git/config`, which is all the identity
        resolution and the liveness probe read."""
        repo = self.root / "checkouts" / name
        repo.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(repo)], check=True, capture_output=True)
        subprocess.run(
            ["git", "-C", str(repo), "remote", "add", "origin", remote_url],
            check=True,
            capture_output=True,
        )
        return repo

    def seed_repository(self, checkout, *, install_dir=None):
        """One installed repository, written by the controller's own writers.

        `install_dir` is the `--install-dir` that repository was installed
        with, which is what puts its runtime tree somewhere other than beside
        the shared record — the case the relocation has to find through the
        definition rather than through the record.
        """
        variable = kanban_config.DRAINER_INSTALL_DIR_ENV
        previous = os.environ.get(variable)
        if install_dir is None:
            os.environ.pop(variable, None)
        else:
            os.environ[variable] = str(install_dir)
        try:
            drain_prs_service.bind_managed_paths()
            job = drain_prs_service.resolve_job(checkout)
            # The controller's own log writer also prints, which is its job
            # and not this suite's output.
            with contextlib.redirect_stdout(io.StringIO()):
                drain_prs_service.install_job(job)
                drain_prs_service.atomic_write_json(
                    job.status_path, {"state": "stopped", "repository": job.identity}
                )
                drain_prs_service.write_incident(
                    job=job,
                    exit_code=3,
                    command=["drain_prs.py", "--path", str(checkout)],
                )
                drain_prs_service.service_log(job, f"seeded {job.identity}")
                for source in self.sources.values():
                    install_drainer.install_symlink(
                        source, drain_prs_service.INSTALL_DIR / source.name
                    )
        finally:
            if previous is None:
                os.environ.pop(variable, None)
            else:
                os.environ[variable] = previous
            drain_prs_service.bind_managed_paths()
        return job

    def seed_legacy_installation(self, *, custom_install_dir=None):
        """A whole pre-XDG installation: one repository beside the shared
        record, and optionally a second installed with `--install-dir`."""
        self.set_platform("darwin")
        self.widgets = self.make_checkout("widgets", "git@github.com:acme/widgets.git")
        jobs = [self.seed_repository(self.widgets)]
        if custom_install_dir is not None:
            self.gadgets = self.make_checkout(
                "gadgets", "git@github.com:acme/gadgets.git"
            )
            jobs.append(
                self.seed_repository(self.gadgets, install_dir=custom_install_dir)
            )
        # Captured while this resolution is still in force, because it is
        # exactly what a process that resolved before this arc holds: the
        # `~/Library` spellings, the log root among them. That log root is
        # single-valued per platform rather than probed, so a process bound
        # after the platform question changed already writes its logs at the
        # destination — and a late writer whose logs land at the *legacy* root
        # is a pre-XDG process, which is the population this whole transition
        # is about.
        self.legacy_bindings = self.stale_bindings()
        self.set_platform("linux")
        return jobs

    # -- the writer that arrives after the removal --------------------------

    def stale_bindings(self):
        """Every managed path this process currently has bound.

        Captured before a relocation, it is exactly what a controller launched
        before that relocation still holds: a separate process's constants are
        frozen at its own import, so restoring these *is* that process's state
        and there is nothing left for a scheduler to decide.
        """
        return {
            name: getattr(drain_prs_service, name)
            for name in (
                "INSTALL_DIR",
                "DISCOVERY_RECORD_PATH",
                "CONFIG_PATH",
                "LEGACY_CONFIG_PATH",
                "CONTROLLER_PATH",
                "DRAINER_PATH",
                "RUNTIME_ROOT",
                "LOG_ROOT",
            )
        }

    def as_bound(self, bindings):
        stack = contextlib.ExitStack()
        for name, value in bindings.items():
            stack.enter_context(mock.patch.object(drain_prs_service, name, value))
        return stack

    def racing(self, write):
        """Run `write` in the instant after the removal.

        That is the window the reconciliation exists for: every writer queued
        on the legacy record's lock is still blocked on it, and one arriving
        here finds the record gone and recreates what it needs. Reproduced by
        hooking the removal rather than raced, so the interleaving is the one
        under test rather than one a scheduler happened to produce.
        """
        real = install_drainer._remove_legacy_installation

        def hook(transition, relocation_plan):
            outcome = real(transition, relocation_plan)
            write()
            return outcome

        return mock.patch.object(install_drainer, "_remove_legacy_installation", hook)

    def write_late(self, checkout, bindings, *, stamp="late", record=True):
        """One repository recorded at the legacy location, after the removal.

        Driven through the controller's own writers under the constants a
        process that resolved before the relocation still holds, and leaving
        real durable content in both its trees: a definition, a record entry, a
        status file, an incident and a log.

        The process that can actually do this is the *installed* controller a
        pre-XDG host is running, which is an older copy of this module — that
        is the premise of the whole relocation — and predates the staleness
        refusal every discovery-record write in this copy now carries. Standing
        exactly that one refusal down for the writer is what makes this fixture
        that process rather than this one; every other step is this module's
        own writer, unmodified, and the runtime, log and definition writers are
        not gated in either copy. `QueuedRecordWriterTests` below is the other
        half: a writer running *this* copy, in another process, is refused.

        `record=False` is the same writer with only its discovery-record write
        left out, which is exactly what such a controller leaves when that one
        write is refused: every directory, document, log line and definition it
        lays down first, and no entry anywhere naming any of it.
        """
        with self.as_bound(bindings):
            job = drain_prs_service.resolve_job(checkout)
            backend = install_drainer.service_backend()
            # The controller's own log writer also prints, which is its job and
            # not this suite's output.
            with contextlib.redirect_stdout(io.StringIO()):
                drain_prs_service.ensure_dirs(job)
                backend.write_definition(drain_prs_service.service_definition(job))
                if record:
                    with mock.patch.object(
                        drain_prs_service, "require_current_installation", lambda: None
                    ):
                        drain_prs_service.write_discovery_record(job)
                drain_prs_service.atomic_write_json(
                    job.status_path,
                    {"state": "stopped", "repository": job.identity, "stamp": stamp},
                )
                drain_prs_service.write_incident(
                    job=job,
                    exit_code=7,
                    command=["drain_prs.py", "--path", str(checkout)],
                )
                drain_prs_service.service_log(job, f"{stamp} write for {job.identity}")
                for source in self.sources.values():
                    install_drainer.install_symlink(
                        source, drain_prs_service.INSTALL_DIR / source.name
                    )
        return job

    # -- locations ----------------------------------------------------------

    @property
    def legacy_dir(self):
        return self.home / self.MACOS_INSTALL

    @property
    def legacy_logs(self):
        return self.home / self.MACOS_LOGS

    @property
    def destination(self):
        return self.home / self.XDG_INSTALL

    @property
    def destination_logs(self):
        return self.home / self.XDG_LOGS

    @property
    def legacy_record(self):
        return self.legacy_dir / "config.json"

    @property
    def legacy_guard(self):
        """The runtime root at the legacy location, which a finished
        relocation seals exactly as it seals the record path."""
        return self.legacy_dir / "runtime"

    @property
    def legacy_lock(self):
        """The retained lock beside the legacy record, which a finished
        relocation closes by making it unopenable rather than by occupying
        it: a lock file may never be unlinked."""
        return self.legacy_dir / "config.json.lock"

    @property
    def destination_record(self):
        return self.destination / "config.json"

    # -- assertions ---------------------------------------------------------

    def host_state(self):
        """Every durable thing this fixture can change, by identity and
        content, so "left exactly as found" is a comparison rather than a
        sample."""
        state = {}
        for base in (self.home, self.units, self.launch_agents, self.root / "custom"):
            if not base.exists():
                continue
            for path in sorted(base.rglob("*")):
                if path.is_symlink():
                    state[str(path)] = ("link", os.readlink(path))
                elif path.is_dir():
                    state[str(path)] = ("dir", path.stat().st_mode & 0o777)
                else:
                    # Contents *and* mode: a rollback that restored the bytes
                    # of a definition or a record while leaving its
                    # permissions changed has not put it back.
                    state[str(path)] = (
                        "file",
                        path.read_bytes(),
                        path.stat().st_mode & 0o777,
                    )
        return state

    def lock_is_held(self, record=None):
        """Whether another opener would be excluded from one record's lock.

        `flock` is per open file description, so a second descriptor in this
        same process contends exactly as another process's would — which is
        what makes this an observation of the lock rather than of the code
        that takes it.

        A relocation additionally closes the legacy record's lock against every
        opener but its own, for the span it holds that lock. A file another
        process cannot open is one it cannot take, so that answers this
        question too — and more strongly than blocking does, since a process
        that blocks eventually gets its turn.
        """
        lock_path = Path(str(record or self.legacy_record) + ".lock")
        if not lock_path.parent.is_dir():
            return False
        try:
            descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        except PermissionError:
            return True
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        else:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            return False
        finally:
            os.close(descriptor)

    def outside_the_destination(self, state):
        """`state` without the XDG roots this transition writes under.

        A rollback puts back everything it changed except one thing it may
        never take away: the destination record's lock file, and the directory
        that has to exist to contain it. `assert_destination_holds_only_its_lock`
        below is what asserts that residue is all that is left.
        """
        excluded = str(self.home / ".local")
        return {
            path: value for path, value in state.items() if not path.startswith(excluded)
        }

    def assert_destination_holds_only_its_lock(self):
        self.assertEqual(
            sorted(path.name for path in self.destination.iterdir()),
            ["config.json.lock"],
        )
        self.assertFalse(self.destination_logs.exists())

    def assert_location_is_sealed(self):
        """Every path a finished relocation closes, and nothing that can put
        state back at one of them.

        Asserted as what a seal is rather than as the path being absent:
        `Path.exists` follows the symlink to the marker beside it, and the
        point of leaving a symlink is precisely that the path is occupied by
        something no writer will replace.
        """
        for path in (self.legacy_record, self.legacy_guard):
            self.assertTrue(install_drainer._is_relocation_seal(path), path)
            self.assertEqual(
                os.readlink(path), drain_prs_service.RELOCATION_MARKER_NAME
            )
        self.assertNotIn(
            "repositories",
            drain_prs_service._read_json_object(self.legacy_record),
        )
        # And the lock, which is closed by mode rather than by an object: it
        # may never be unlinked, so what a transition meets there is an open
        # that fails.
        self.assertTrue(_plain_file_at(self.legacy_lock))
        self.assertFalse(os.access(self.legacy_lock, os.W_OK))

    def assert_relocate_refuses_and_changes_nothing(self, expected_fragment):
        """For a refusal the transition raises rather than the plan: the
        fences are taken by `relocate` once the plan is settled, so the plan
        itself has nothing to say about them."""
        before = self.host_state()
        with self.assertRaises(install_drainer.InstallError) as raised:
            install_drainer.relocate(self.destination, self.sources)
        self.assertIn(expected_fragment, str(raised.exception))
        self.assertEqual(self.host_state(), before)

    def assert_refuses_and_changes_nothing(self, expected_fragment):
        """Both halves of every refusal: it fails the run, and it fails it
        before anything was mutated — for a real run and for a dry run, since
        a dry run that mutated would be the worse of the two."""
        before = self.host_state()
        with self.assertRaises(install_drainer.InstallError) as raised:
            install_drainer.plan_relocation(self.destination)
        self.assertIn(expected_fragment, str(raised.exception))
        self.assertEqual(self.host_state(), before)
        with self.assertRaises(install_drainer.InstallError) as raised:
            install_drainer.relocate(self.destination, self.sources)
        self.assertIn(expected_fragment, str(raised.exception))
        self.assertEqual(self.host_state(), before)

    def fake_service_manager(self):
        """A `systemctl` on a subprocess's PATH which records instead of
        running, so "it never asked the manager to load or unload anything" is
        an observation rather than an absence of evidence — and so a
        subprocess that *does* ask reaches a manager this suite controls
        rather than the host's."""
        directory = self.root / "bin"
        directory.mkdir(exist_ok=True)
        script = directory / "systemctl"
        script.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$*" >> "$KANBAN_FAKE_MANAGER_LOG"\n',
            encoding="utf-8",
        )
        script.chmod(0o755)
        return directory

    def relocate(self):
        return install_drainer.relocate(self.destination, self.sources)

    def record_document(self, path):
        return json.loads(path.read_text(encoding="utf-8"))


class SeededInstallationTests(RelocationFixture):
    """What the fixture itself produced, asserted before anything moves it.

    A relocation test whose "before" state was never checked could pass by
    moving nothing, so this is the group that makes every group below mean
    something.
    """

    def test_the_seeded_installation_is_where_a_pre_xdg_host_put_it(self):
        job = self.seed_legacy_installation()[0]
        self.assertTrue(self.legacy_record.is_file())
        self.assertTrue((self.legacy_dir / "drain_prs_service.py").is_symlink())
        self.assertTrue((self.legacy_dir / "runtime" / job.slug / "status.json").is_file())
        self.assertTrue(any((self.legacy_dir / "runtime" / job.slug / "incidents").iterdir()))
        self.assertTrue((self.legacy_logs / job.slug / "service.log").is_file())
        self.assertEqual(
            self.record_document(self.legacy_record)["repositories"]["acme/widgets"][
                "repository"
            ],
            str(self.widgets),
        )

    def test_the_seeded_definition_names_the_legacy_installation(self):
        job = self.seed_legacy_installation()[0]
        backend = install_drainer.service_backend()
        self.assertEqual(
            backend.definition_environment(job.label)[
                kanban_config.DRAINER_INSTALL_DIR_ENV
            ],
            str(self.legacy_dir),
        )


class DispositionTests(RelocationFixture):
    """When the relocation does not run at all, and why.

    The platform is asked as the platform question. Two directories differing
    is never the test, which is what keeps a macOS host whose XDG variables
    happen to point elsewhere from being migrated.
    """

    def test_a_macos_host_relocates_nothing(self):
        self.seed_legacy_installation()
        self.set_platform("darwin")
        before = self.host_state()
        result = self.relocate()
        self.assertFalse(result["relocated"])
        self.assertIn("installs where its installation already is", result["reason"])
        self.assertEqual(self.host_state(), before)

    def test_a_custom_destination_installs_there_and_relocates_nothing(self):
        self.seed_legacy_installation()
        before = self.host_state()
        result = install_drainer.relocate(self.root / "elsewhere", self.sources)
        self.assertFalse(result["relocated"])
        self.assertIn("custom --install-dir destination", result["reason"])
        self.assertEqual(self.host_state(), before)

    def test_an_inherited_install_dir_environment_never_decides_the_destination(self):
        # `--install-dir` is the only thing that selects a custom destination.
        # A variable this process merely inherited must not turn an ordinary
        # run on a host that exports it into a custom one, because that is
        # exactly the run that would otherwise relocate the installation.
        self.seed_legacy_installation()
        inherited = self.root / "inherited"
        with mock.patch.dict(
            os.environ, {kanban_config.DRAINER_INSTALL_DIR_ENV: str(inherited)}
        ):
            self.assertEqual(install_drainer.default_install_dir(), self.destination)
            # At the command line too, which is the level an operator meets it
            # at: `--install-dir` defaults to the destination, not to the
            # variable.
            with mock.patch.object(
                install_drainer.sys, "argv", ["install_drainer.py"]
            ):
                arguments = install_drainer.parse_args()
            self.assertEqual(Path(arguments.install_dir), self.destination)
            result = self.relocate()
        self.assertTrue(result["relocated"])
        self.assertEqual(result["destination"], str(self.destination))
        self.assertFalse(inherited.exists())

    def test_a_platform_default_that_aliases_the_legacy_directory_is_migrated(self):
        # An absolute XDG root naming `~/Library/Application Support` makes
        # this platform's own default the legacy directory itself. Deciding
        # whether this platform migrates by comparing the two directories
        # reads such a host as macOS and skips it forever, so the disposition
        # asks only the platform question and leaves the shape of the
        # migration to `EqualLocationDispositionTests` below.
        self.seed_legacy_installation()
        with mock.patch.dict(
            os.environ, {"XDG_DATA_HOME": str(self.home / "Library/Application Support")}
        ):
            self.assertIsNone(install_drainer.relocation_disposition(self.legacy_dir))

    def test_a_resolved_destination_is_still_this_platforms_own_convention(self):
        # `main` resolves `--install-dir` before it reaches the disposition
        # while the resolvers answer with the home-relative spelling they
        # declare, so a home reached through a symlink must not read as a
        # custom destination and relocate nothing.
        self.seed_legacy_installation()
        for destination in (self.destination, self.destination.resolve()):
            with self.subTest(destination=destination):
                self.assertIsNone(install_drainer.relocation_disposition(destination))

    def test_a_host_with_no_legacy_installation_relocates_nothing(self):
        self.set_platform("linux")
        before = self.host_state()
        result = self.relocate()
        self.assertFalse(result["relocated"])
        self.assertIn("no installation at the legacy location", result["reason"])
        self.assertEqual(self.host_state(), before)

    def test_the_default_destination_is_this_platforms_own_convention(self):
        # The change that makes a *default* run relocate at all: discovery
        # keeps answering `~/Library` while the installation is there, and a
        # default install that followed discovery could never move it.
        self.seed_legacy_installation()
        self.assertEqual(kanban_config.installed_drainer_dir(), self.legacy_dir)
        self.assertEqual(install_drainer.default_install_dir(), self.destination)
        self.set_platform("darwin")
        self.assertEqual(install_drainer.default_install_dir(), self.legacy_dir)


class TwoRepositoryRelocationTests(RelocationFixture):
    """The whole transition, over an installation serving two repositories."""

    def setUp(self):
        super().setUp()
        self.custom = self.root / "custom"
        self.jobs = self.seed_legacy_installation(custom_install_dir=self.custom)
        self.before = self.host_state()
        self.result = self.relocate()

    def test_every_repository_is_recorded_at_the_destination(self):
        self.assertTrue(self.result["relocated"])
        document = self.record_document(self.destination_record)
        self.assertEqual(
            sorted(document["repositories"]), ["acme/gadgets", "acme/widgets"]
        )
        for identity, checkout in (
            ("acme/widgets", self.widgets),
            ("acme/gadgets", self.gadgets),
        ):
            self.assertEqual(
                document["repositories"][identity]["repository"], str(checkout)
            )

    def test_every_runtime_tree_and_its_incidents_arrive_whole(self):
        for job in self.jobs:
            with self.subTest(repository=job.identity):
                runtime = self.destination / "runtime" / job.slug
                self.assertEqual(
                    json.loads((runtime / "status.json").read_text(encoding="utf-8"))[
                        "repository"
                    ],
                    job.identity,
                )
                incidents = sorted(path.name for path in (runtime / "incidents").iterdir())
                self.assertEqual(len(incidents), 1)

    def test_a_custom_install_dir_repositorys_runtime_tree_is_carried(self):
        # Found through the install directory its own definition names, since
        # `--install-dir` moved that state without moving the record.
        gadgets = self.jobs[1]
        self.assertFalse((self.custom / "runtime" / gadgets.slug).exists())
        self.assertTrue(
            (self.destination / "runtime" / gadgets.slug / "status.json").is_file()
        )

    def test_every_log_tree_is_carried_and_the_old_root_goes(self):
        for job in self.jobs:
            with self.subTest(repository=job.identity):
                self.assertTrue(
                    (self.destination_logs / job.slug / "service.log").is_file()
                )
                self.assertFalse((self.legacy_logs / job.slug).exists())
        self.assertFalse(self.legacy_logs.exists())

    def test_both_definitions_are_rewritten_and_reloaded(self):
        backend = install_drainer.service_backend()
        for job in self.jobs:
            with self.subTest(repository=job.identity):
                environment = backend.definition_environment(job.label)
                self.assertEqual(
                    environment[kanban_config.DRAINER_INSTALL_DIR_ENV],
                    str(self.destination),
                )
                unit = backend.definition_path(job.label).read_text(encoding="utf-8")
                self.assertIn(str(self.destination / "drain_prs_service.py"), unit)
                self.assertIn(str(self.destination_logs / job.slug), unit)
        reloads = [command for command in self.commands if "daemon-reload" in command]
        self.assertGreaterEqual(len(reloads), len(self.jobs))

    def test_the_shared_installation_is_removed_but_its_lock_is_not(self):
        # A writer may be queued on the lock's inode, so unlinking it would
        # hand the next writer a different lock from the one it is waiting on
        # — which is why the directory containing it survives too, and with it
        # the marker that tells a process still bound here that it is stale.
        self.assert_location_is_sealed()
        self.assertEqual(
            sorted(path.name for path in self.legacy_dir.iterdir()),
            ["config.json", "config.json.lock", "relocated.json", "runtime"],
        )
        self.assert_location_is_sealed()
        self.assertIn(str(self.legacy_record) + ".lock", self.result["retained"])
        self.assertIn(
            str(self.legacy_dir / "relocated.json"), self.result["retained"]
        )

    def test_the_marker_names_where_the_installation_went(self):
        marker = json.loads(
            (self.legacy_dir / "relocated.json").read_text(encoding="utf-8")
        )
        self.assertEqual(marker["install_dir"], str(self.destination))
        self.assertEqual(marker["record"], str(self.destination_record))
        self.assertEqual(marker["log_root"], str(self.destination_logs))

    def test_the_links_are_installed_at_the_destination(self):
        for source in self.sources.values():
            with self.subTest(link=source.name):
                link = self.destination / source.name
                self.assertTrue(link.is_symlink())
                self.assertEqual(link.resolve(), source.resolve())

    def test_the_run_reports_whether_the_legacy_record_reappeared(self):
        self.assertFalse(self.result["legacy_record_reappeared"])
        self.assertIn("Nothing to repair", self.result["repair"])

    def test_the_process_now_describes_the_destination_installation(self):
        self.assertEqual(drain_prs_service.INSTALL_DIR, self.destination)
        self.assertEqual(drain_prs_service.DISCOVERY_RECORD_PATH, self.destination_record)
        self.assertEqual(drain_prs_service.RUNTIME_ROOT, self.destination / "runtime")
        self.assertEqual(drain_prs_service.LOG_ROOT, self.destination_logs)


class StaleControllerTests(RelocationFixture):
    """A controller that was already running when the relocation ran.

    Its managed paths were bound when *it* started and it cannot re-derive
    them, so after the relocation it still points at the location that was
    taken apart. The interleaving is reproduced rather than raced: a separate
    process's bindings are frozen at its own import, so restoring this module's
    constants to what they were before the relocation *is* that process's
    state, and there is nothing left for a scheduler to decide.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        # Exactly what a controller launched before the relocation holds.
        self.bindings = {
            name: getattr(drain_prs_service, name)
            for name in (
                "INSTALL_DIR",
                "DISCOVERY_RECORD_PATH",
                "CONFIG_PATH",
                "CONTROLLER_PATH",
                "DRAINER_PATH",
                "RUNTIME_ROOT",
                "LOG_ROOT",
            )
        }
        self.assertEqual(self.bindings["INSTALL_DIR"], self.legacy_dir)
        self.assertTrue(self.relocate()["relocated"])
        # The relocation's own service-manager traffic, so what the stale
        # controller does or does not ask for below stands alone.
        self.commands.clear()

    def as_the_stale_controller(self):
        """This module bound as that process still has it."""
        stack = contextlib.ExitStack()
        for name, value in self.bindings.items():
            stack.enter_context(mock.patch.object(drain_prs_service, name, value))
        return stack

    def test_it_refuses_to_start_and_rebuilds_nothing(self):
        with self.as_the_stale_controller():
            before = self.host_state()
            with mock.patch.object(
                drain_prs_service, "require_no_operation_in_progress"
            ):
                with mock.patch.object(drain_prs_service, "require_default_branch"):
                    with self.assertRaises(drain_prs_service.ServiceError) as raised:
                        drain_prs_service.start_service(self.job)
            message = str(raised.exception)
            after = self.host_state()
        self.assertIn("was relocated to", message)
        self.assertIn(str(self.destination), message)
        # The record it would have recreated, the definition it would have
        # rewritten, and the runtime directories `ensure_dirs` would have
        # rebuilt are all still as the relocation left them.
        self.assert_location_is_sealed()
        self.assertTrue(install_drainer._is_relocation_seal(self.legacy_guard))
        self.assertEqual(after, before)
        # And it never asked the service manager for anything.
        self.assertEqual(self.commands, [])

    def test_installing_from_a_stale_controller_refuses_too(self):
        # The shared mutator every write goes through, so no other route can
        # rebuild what the relocation removed either.
        with self.as_the_stale_controller():
            before = self.host_state()
            with self.assertRaises(drain_prs_service.ServiceError):
                drain_prs_service.install_job(self.job)
            self.assertEqual(self.host_state(), before)

    def test_uninstalling_from_a_stale_controller_refuses_too(self):
        # Removing the definition would delete the one the relocation just
        # rewrote, and removing the record entry would write a fresh record at
        # the location it emptied. Neither is an uninstall.
        with self.as_the_stale_controller():
            before = self.host_state()
            with self.assertRaises(drain_prs_service.ServiceError):
                drain_prs_service.uninstall_job(self.job)
            self.assertEqual(self.host_state(), before)
        self.assertTrue(
            install_drainer.service_backend()
            .definition_path(self.job.label)
            .is_file()
        )
        self.assert_location_is_sealed()

    def test_stopping_from_a_stale_controller_refuses_too(self):
        # The transition whose own exclusion disappears while it runs, which is
        # why this copy asks the gate up front: signalling the runner is what
        # frees a mover to act, and a stale stop that signalled would do it
        # against a drainer this installation no longer describes. A copy
        # predating that gate reads its snapshot and returns instead, which
        # `StaleInvocationBoundTests` is where the terms of are asserted.
        with self.as_the_stale_controller():
            before = self.host_state()
            with self.assertRaises(drain_prs_service.ServiceError) as raised:
                drain_prs_service.stop_service(self.job)
            self.assertEqual(self.host_state(), before)
        self.assertIn("was relocated to", str(raised.exception))
        self.assertIn(str(self.destination), str(raised.exception))
        self.assertEqual(self.commands, [])

    def test_a_queued_run_refuses_before_it_writes_anything(self):
        # The service-manager `run` path: a runner launched before the
        # relocation, or started by hand while the record showed nothing live,
        # begins afterwards. Its own first act is to log, and logging creates
        # the directories it logs into.
        with self.as_the_stale_controller():
            before = self.host_state()
            # Non-success: a run that reported success would be telling the
            # service manager a drainer ran for an installation that moved.
            self.assertEqual(
                drain_prs_service.run_service(self.job, self.job.identity), 1
            )
            self.assertEqual(self.host_state(), before)
        self.assertFalse((self.legacy_logs / self.job.slug).exists())
        self.assertTrue(install_drainer._is_relocation_seal(self.legacy_guard))

    def test_a_controller_bound_to_the_destination_is_unaffected(self):
        # The gate is about *this* installation having moved, not about a
        # marker existing anywhere on the host: the relocated installation has
        # no marker of its own, so the current controller proceeds.
        self.assertIsNone(drain_prs_service.relocation_marker())
        drain_prs_service.require_current_installation()


class StaleCustomInstallControllerTests(RelocationFixture):
    """`--install-dir` splits the two locations a controller is bound to.

    Such a controller's install directory is one the relocation never touches,
    while its discovery record is one the relocation removes — so the marker it
    has to see is the one in the *record's* directory, and a gate that looked
    only where the scripts are would miss it entirely.
    """

    def setUp(self):
        super().setUp()
        self.custom = self.root / "custom"
        self.set_platform("darwin")
        self.widgets = self.make_checkout("widgets", "git@github.com:acme/widgets.git")
        self.job = self.seed_repository(self.widgets, install_dir=self.custom)
        self.set_platform("linux")
        self.bindings = {
            "INSTALL_DIR": self.custom,
            "DISCOVERY_RECORD_PATH": self.legacy_record,
            "CONFIG_PATH": self.legacy_record,
            "RUNTIME_ROOT": self.custom / "runtime",
            "LOG_ROOT": self.legacy_logs,
        }
        self.assertTrue(self.relocate()["relocated"])
        self.commands.clear()

    def test_the_marker_is_found_through_the_bound_record_rather_than_the_scripts(self):
        # The install directory it is bound to still exists and holds no
        # marker; the record's directory is where the relocation left one.
        self.assertTrue((self.custom / "drain_prs_service.py").is_symlink())
        self.assertFalse((self.custom / "relocated.json").exists())
        self.assertTrue((self.legacy_dir / "relocated.json").is_file())
        stack = contextlib.ExitStack()
        for name, value in self.bindings.items():
            stack.enter_context(mock.patch.object(drain_prs_service, name, value))
        with stack:
            notice = drain_prs_service.relocation_marker()
            self.assertIsNotNone(notice)
            self.assertEqual(notice.destination, str(self.destination))
            self.assertEqual(notice.path, self.legacy_dir / "relocated.json")
            before = self.host_state()
            with self.assertRaises(drain_prs_service.ServiceError):
                drain_prs_service.install_job(self.job)
            self.assertEqual(self.host_state(), before)
        self.assert_location_is_sealed()


class TransientDestinationControllerTests(RelocationFixture):
    """A controller that bound itself while a relocation was in flight.

    Its bindings name a destination that existed only for the length of that
    transition: the record was written, the controller resolved it, and the
    rollback then took the record, the links and the marker away together. No
    marker survives to warn it and nothing is wrong at the legacy location, so
    the only thing left that can tell it is that what it bound is no longer
    what this host resolves.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.bindings = {}
        real = install_drainer._rewrite_definition

        def capture_and_fail(transition, entry, backend):
            # Exactly what a controller starting at this instant would bind:
            # the destination record is on disk and discovery prefers it.
            self.bindings.update(
                {
                    name: getattr(drain_prs_service, name)
                    for name in ("INSTALL_DIR", "DISCOVERY_RECORD_PATH", "CONFIG_PATH")
                }
            )
            raise OSError("no room")

        with mock.patch.object(install_drainer, "_rewrite_definition", capture_and_fail):
            with self.assertRaises(install_drainer.RelocationFailed):
                self.relocate()
        self.assertEqual(self.bindings["INSTALL_DIR"], self.destination)
        self.assertEqual(self.bindings["DISCOVERY_RECORD_PATH"], self.destination_record)
        self.commands.clear()

    def test_the_rollback_left_nothing_at_the_destination_to_warn_it(self):
        self.assertFalse(self.destination_record.exists())
        self.assertFalse((self.destination / "relocated.json").exists())
        self.assertFalse((self.legacy_dir / "relocated.json").exists())
        self.assertTrue(self.legacy_record.is_file())

    def test_it_refuses_and_rebuilds_nothing_at_that_destination(self):
        stack = contextlib.ExitStack()
        for name, value in self.bindings.items():
            stack.enter_context(mock.patch.object(drain_prs_service, name, value))
        with stack:
            self.assertIsNone(drain_prs_service.relocation_marker())
            before = self.host_state()
            with self.assertRaises(drain_prs_service.ServiceError) as raised:
                drain_prs_service.install_job(self.job)
            self.assertEqual(self.host_state(), before)
        self.assertIn("no longer the one this host resolves", str(raised.exception))
        self.assertFalse(self.destination_record.exists())


class UnaccountedTreeTests(RelocationFixture):
    """A repository's durable state that no record names.

    An uninstall deliberately leaves a repository's runtime state, logs and
    incidents behind, so a repository removed long ago has trees under these
    roots and an entry nowhere. Neither the removal nor the plan can recover it
    *as* a repository — there is no entry to read a checkout or a definition out
    of — but leaving it where it is would orphan it at a location nothing looks
    at again. It is carried by the one name it has.
    """

    def test_a_log_tree_no_record_names_is_carried_rather_than_orphaned(self):
        self.seed_legacy_installation()
        stray = self.legacy_logs / "someone.else"
        stray.mkdir(parents=True)
        (stray / "service.log").write_text("kept\n", encoding="utf-8")
        result = self.relocate()
        # The removal itself keeps it, because it never accounted for it and
        # deleting durable state is not its to do...
        self.assertIn(str(self.legacy_logs), result["retained"])
        # ...and the reconciliation then carries it to the root the
        # installation now uses, whole.
        carried = self.destination_logs / "someone.else" / "service.log"
        self.assertEqual(carried.read_text(encoding="utf-8"), "kept\n")
        self.assertFalse(stray.exists())
        self.assertTrue(result["late_writes"]["resolved"])

    def test_a_runtime_tree_no_record_names_is_carried_too(self):
        job = self.seed_legacy_installation()[0]
        stray = self.legacy_dir / "runtime" / "someone.else"
        stray.mkdir(parents=True)
        (stray / "status.json").write_text("{}", encoding="utf-8")
        result = self.relocate()
        self.assertIn(str(self.legacy_dir / "runtime"), result["retained"])
        self.assertTrue(
            (self.destination / "runtime" / "someone.else" / "status.json").is_file()
        )
        self.assertFalse(stray.exists())
        # And what the run *did* account for still moved.
        self.assertTrue(
            (self.destination / "runtime" / job.slug / "status.json").is_file()
        )
        self.assertTrue(result["late_writes"]["resolved"])

    def test_one_already_at_the_destination_is_kept_and_named(self):
        # The judgement nothing here makes, asked of a tree with no repository
        # to name it: both copies stay and both are reported.
        self.seed_legacy_installation()
        for root in (self.legacy_logs, self.destination_logs):
            tree = root / "someone.else"
            tree.mkdir(parents=True)
            (tree / "service.log").write_text(f"{root.name}\n", encoding="utf-8")
        result = self.relocate()
        late = result["late_writes"]
        self.assertFalse(late["resolved"])
        self.assertEqual(
            [
                (item["repository"], item["slug"], item["kind"])
                for item in late["collisions"]
            ],
            [("someone/else", "someone.else", "log")],
        )
        self.assertTrue((self.legacy_logs / "someone.else").is_dir())
        self.assertTrue((self.destination_logs / "someone.else").is_dir())


class DirectoryModeTests(RelocationFixture):
    """Acquiring a document lock is itself a change to the directory holding
    the record.

    `document_lock` chmods that parent to 0700 before this transition has
    recorded anything it could undo, so a directory this run only ever locked
    has to come back as restrictive as it was found — on a refusal raised once
    a lock is held, on a rollback, and on the success path too, where the
    legacy directory survives to contain its lock.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.legacy_dir.chmod(0o755)
        self.before = self.host_state()

    def test_a_successful_relocation_leaves_the_legacy_directory_as_found(self):
        self.assertTrue(self.relocate()["relocated"])
        self.assertEqual(self.legacy_dir.stat().st_mode & 0o777, 0o755)

    def test_a_rolled_back_failure_leaves_the_legacy_directory_as_found(self):
        with mock.patch.object(
            install_drainer,
            "_rewrite_definition",
            mock.Mock(side_effect=OSError("no room")),
        ):
            with self.assertRaises(install_drainer.RelocationFailed):
                self.relocate()
        self.assertEqual(self.legacy_dir.stat().st_mode & 0o777, 0o755)
        self.assertEqual(
            self.outside_the_destination(self.host_state()),
            self.outside_the_destination(self.before),
        )

    def test_a_refusal_raised_once_a_lock_is_held_leaves_both_as_found(self):
        # The authoritative plan runs after the legacy lock has been taken, so
        # a refusal it raises is the one case where a lock's own chmod has
        # already landed. An existing destination record puts that directory
        # in the same position.
        self.destination.mkdir(parents=True)
        self.destination_record.write_text("{}", encoding="utf-8")
        self.destination.chmod(0o755)
        before = self.host_state()
        real = install_drainer.plan_relocation
        calls = []

        def plan(install_dir):
            calls.append(install_dir)
            if len(calls) > 1:
                raise install_drainer.InstallError("Refusing to relocate: raced")
            return real(install_dir)

        with mock.patch.object(install_drainer, "plan_relocation", plan):
            with self.assertRaises(install_drainer.InstallError):
                self.relocate()
        self.assertEqual(self.legacy_dir.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o755)
        # The lock files those acquisitions created are the only difference,
        # and they are the one thing that may never be unlinked.
        after = self.host_state()
        introduced = set(after) - set(before)
        self.assertEqual(
            sorted(Path(path).name for path in introduced), ["config.json.lock"]
        )
        self.assertEqual(
            {path: value for path, value in after.items() if path not in introduced},
            before,
        )


class RecordMergeTests(RelocationFixture):
    """Requirement 6: the destination wins per key at both levels."""

    def seed_destination_record(self, document):
        self.destination.mkdir(parents=True, exist_ok=True)
        self.destination_record.write_text(json.dumps(document), encoding="utf-8")

    def test_a_destination_key_survives_and_a_legacy_only_key_is_carried(self):
        self.seed_legacy_installation()
        drain_prs_service.merge_json_document(
            self.legacy_record, {"ntfy_url": "https://notify.example.test/legacy"}
        )
        self.seed_destination_record(
            {"ntfy_url": "https://notify.example.test/current"}
        )
        self.relocate()
        document = self.record_document(self.destination_record)
        self.assertEqual(document["ntfy_url"], "https://notify.example.test/current")
        self.assertIn("acme/widgets", document["repositories"])

    def test_stale_manager_metadata_is_restated_from_this_hosts_own_derivation(self):
        # Carried forward, the merge would preserve an identifier and a
        # definition path that name no job on this host — a record Kanban can
        # neither discover nor control this repository through.
        job = self.seed_legacy_installation()[0]
        document = self.record_document(self.legacy_record)
        entry = document["repositories"]["acme/widgets"]
        entry.update(
            {
                "backend": "launchd",
                "launchd_label": "com.example.stale",
                "plist_path": "/nowhere/stale.plist",
                "systemd_unit": "stale.service",
                "unit_path": "/nowhere/stale.service",
                "config_path": "/home/user/widgets.toml",
            }
        )
        self.legacy_record.write_text(json.dumps(document), encoding="utf-8")
        self.assertTrue(self.relocate()["relocated"])
        backend = install_drainer.service_backend()
        recorded = self.record_document(self.destination_record)["repositories"][
            "acme/widgets"
        ]
        self.assertEqual(
            {key: recorded.get(key) for key in service_manager.RECORD_KEYS if key in recorded},
            backend.record_entry(job.label, backend.definition_path(job.label)),
        )
        self.assertEqual(recorded["repository"], str(self.widgets))
        # And every key the entry carried beside them survives.
        self.assertEqual(recorded["config_path"], "/home/user/widgets.toml")

    def test_a_destination_record_that_does_not_describe_the_job_blocks_removal(self):
        self.seed_legacy_installation()
        real = install_drainer.plan_relocation

        def tampered(install_dir):
            plan = real(install_dir)
            record = json.loads(json.dumps(plan.merged_record))
            record["repositories"]["acme/widgets"]["repository"] = "/somewhere/else"
            return dataclasses.replace(plan, merged_record=record)

        with mock.patch.object(install_drainer, "plan_relocation", tampered):
            with self.assertRaises(install_drainer.RelocationFailed) as raised:
                self.relocate()
        self.assertIn("does not describe", str(raised.exception))
        self.assertTrue(self.legacy_record.is_file())

    def test_a_destination_only_repository_is_proven_before_removal(self):
        # Built from the destination-winning merge rather than from the legacy
        # table alone: removal is gated on *every* recorded repository working
        # through the destination, and one recorded only there is still one of
        # them.
        self.seed_legacy_installation()
        gadgets = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        legacy = self.record_document(self.legacy_record)
        self.set_platform("darwin")
        second = self.seed_repository(gadgets)
        self.set_platform("linux")
        promoted = self.record_document(self.legacy_record)
        self.seed_destination_record(
            {
                "repositories": {
                    "acme/gadgets": promoted["repositories"]["acme/gadgets"]
                }
            }
        )
        self.legacy_record.write_text(json.dumps(legacy), encoding="utf-8")
        result = self.relocate()
        self.assertEqual(
            sorted(entry["repository"] for entry in result["repositories"]),
            ["acme/gadgets", "acme/widgets"],
        )
        backend = install_drainer.service_backend()
        self.assertEqual(
            backend.definition_environment(second.label)[
                kanban_config.DRAINER_INSTALL_DIR_ENV
            ],
            str(self.destination),
        )


class RefusalTests(RelocationFixture):
    """Requirement 4: every refusal fails the run, before anything is
    mutated, and leaves the host exactly as it was found."""

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]

    def test_a_live_managed_job_refuses(self):
        backend = install_drainer.service_backend()
        with mock.patch.object(
            type(backend), "is_running", autospec=True, return_value=True
        ):
            self.assert_refuses_and_changes_nothing("is running")

    def test_a_live_checkout_drainer_refuses(self):
        (self.widgets / ".git" / "drain_prs.lock").write_text(
            str(os.getpid()), encoding="utf-8"
        )
        self.assert_refuses_and_changes_nothing("a drainer is running in")

    def test_an_entry_whose_checkout_is_gone_refuses(self):
        drain_prs_service.merge_repository_record(
            "acme/widgets", {"repository": str(self.root / "vanished")}
        )
        self.assert_refuses_and_changes_nothing("which is not a directory")

    def test_an_entry_naming_another_repositorys_checkout_refuses(self):
        # A directory is not enough: an entry pointing one identity at another
        # repository's clone would produce a definition whose `--path` and
        # `--repo` disagree, which is a job that starts and refuses itself.
        other = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        drain_prs_service.merge_repository_record(
            "acme/widgets", {"repository": str(other)}
        )
        self.assert_refuses_and_changes_nothing("rather than of acme/widgets")

    def test_an_entry_naming_a_checkout_with_no_identity_refuses(self):
        plain = self.root / "checkouts" / "plain"
        plain.mkdir(parents=True)
        drain_prs_service.merge_repository_record(
            "acme/widgets", {"repository": str(plain)}
        )
        self.assert_refuses_and_changes_nothing("cannot be read")

    def test_an_entry_naming_no_checkout_refuses(self):
        document = self.record_document(self.legacy_record)
        del document["repositories"]["acme/widgets"]["repository"]
        self.legacy_record.write_text(json.dumps(document), encoding="utf-8")
        self.assert_refuses_and_changes_nothing("names no checkout")

    def test_an_entry_filed_under_a_non_canonical_key_refuses(self):
        document = self.record_document(self.legacy_record)
        document["repositories"]["not a repository"] = {"repository": str(self.widgets)}
        self.legacy_record.write_text(json.dumps(document), encoding="utf-8")
        self.assert_refuses_and_changes_nothing("canonical GitHub repository")

    def test_an_entry_with_no_definition_on_this_host_refuses(self):
        install_drainer.service_backend().definition_path(self.job.label).unlink()
        self.assert_refuses_and_changes_nothing("not a regular file on this host")

    def test_a_definition_naming_no_install_directory_refuses(self):
        path = install_drainer.service_backend().definition_path(self.job.label)
        path.write_text("[Service]\nRestart=no\n", encoding="utf-8")
        self.assert_refuses_and_changes_nothing("names no absolute")

    def test_an_unreadable_legacy_record_refuses(self):
        self.legacy_record.write_text("{not json", encoding="utf-8")
        self.assert_refuses_and_changes_nothing("legacy discovery record")

    def test_a_legacy_record_that_is_not_an_object_refuses(self):
        self.legacy_record.write_text("[1, 2]", encoding="utf-8")
        self.assert_refuses_and_changes_nothing("is not a JSON object")

    def test_a_legacy_record_with_a_non_table_repositories_refuses(self):
        # Present and not a table, `null` included: absent is the ordinary
        # shape of a record nothing has been installed into, but a key that is
        # there holding something else is a document this cannot merge.
        for payload in ('{"repositories": []}', '{"repositories": null}',
                        '{"repositories": 0}', '{"repositories": "none"}'):
            with self.subTest(payload=payload):
                self.legacy_record.write_text(payload, encoding="utf-8")
                self.assert_refuses_and_changes_nothing("non-table")

    def test_a_destination_record_with_a_non_table_repositories_refuses(self):
        self.destination.mkdir(parents=True)
        self.destination_record.write_text('{"repositories": null}', encoding="utf-8")
        self.assert_refuses_and_changes_nothing("non-table")

    def test_a_malformed_destination_record_refuses(self):
        # Preflighted on the same terms as the legacy one, because the merge
        # cannot preserve destination-winning keys out of a document that will
        # not parse.
        self.destination.mkdir(parents=True)
        self.destination_record.write_text("{not json", encoding="utf-8")
        self.assert_refuses_and_changes_nothing("destination discovery record")

    def test_a_destination_record_that_is_not_a_regular_file_refuses(self):
        self.destination_record.mkdir(parents=True)
        self.assert_refuses_and_changes_nothing("not a regular file")

    def test_a_distinct_runtime_tree_at_the_destination_refuses(self):
        (self.destination / "runtime" / self.job.slug).mkdir(parents=True)
        (self.destination / "runtime" / self.job.slug / "status.json").write_text(
            "{}", encoding="utf-8"
        )
        self.assert_refuses_and_changes_nothing("runtime tree")

    def test_a_distinct_log_tree_at_the_destination_refuses(self):
        (self.destination_logs / self.job.slug).mkdir(parents=True)
        (self.destination_logs / self.job.slug / "service.log").write_text(
            "other\n", encoding="utf-8"
        )
        self.assert_refuses_and_changes_nothing("log tree")

    def test_an_entry_the_installer_never_created_refuses(self):
        (self.legacy_dir / "notes.txt").write_text("mine\n", encoding="utf-8")
        self.assert_refuses_and_changes_nothing("not something this installer created")

    def test_a_managed_name_holding_the_wrong_kind_of_object_refuses(self):
        # Ownership is what an entry *is*: the expected name selects the slot,
        # and the object type is what proves the entry belongs to it.
        (self.legacy_dir / "drain_prs.py").unlink()
        (self.legacy_dir / "drain_prs.py").write_text("not a link\n", encoding="utf-8")
        self.assert_refuses_and_changes_nothing("not something this installer created")

    def test_a_runtime_name_that_is_not_a_directory_refuses(self):
        pycache = self.legacy_dir / "__pycache__"
        pycache.mkdir()
        (pycache / "notes.txt").write_text("not bytecode\n", encoding="utf-8")
        self.assert_refuses_and_changes_nothing("not something this installer created")

    def test_a_bytecode_cache_of_plain_pyc_files_is_recognised(self):
        pycache = self.legacy_dir / "__pycache__"
        pycache.mkdir()
        (pycache / "kanban_config.cpython-312.pyc").write_bytes(b"\x00")
        self.assertTrue(self.relocate()["relocated"])
        self.assertFalse(pycache.exists())


class LockingTests(RelocationFixture):
    """Requirement 3: one lock, over the whole transition, and only when
    something is removed."""

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]

    def test_the_removal_and_the_read_before_it_are_under_one_lock(self):
        observed = []
        real_plan = install_drainer.plan_relocation
        real_remove = install_drainer._remove_legacy_installation

        def plan(install_dir):
            observed.append(("plan", self.lock_is_held()))
            return real_plan(install_dir)

        def remove(transition, relocation_plan):
            observed.append(("remove", self.lock_is_held()))
            return real_remove(transition, relocation_plan)

        with mock.patch.object(install_drainer, "plan_relocation", plan):
            with mock.patch.object(
                install_drainer, "_remove_legacy_installation", remove
            ):
                self.assertTrue(self.relocate()["relocated"])
        # The first plan is the lock-free one that refuses; everything from the
        # authoritative read through the removal is inside.
        self.assertEqual(observed, [("plan", False), ("plan", True), ("remove", True)])

    def test_the_destination_record_is_written_and_undone_under_its_own_lock(self):
        # From the instant the destination record exists, discovery probes it
        # first and every other writer on the host resolves it rather than the
        # legacy one — including during the rollback whose undo unlinks it.
        observed = []
        real_write = install_drainer._write_destination_record
        real_roll_back = install_drainer._Transition.roll_back

        def write(transition, record_path, document):
            observed.append(("write", self.lock_is_held(self.destination_record)))
            return real_write(transition, record_path, document)

        def roll_back(transition):
            observed.append(("roll_back", self.lock_is_held(self.destination_record)))
            return real_roll_back(transition)

        with mock.patch.object(install_drainer, "_write_destination_record", write):
            with mock.patch.object(
                install_drainer._Transition, "roll_back", roll_back
            ):
                with mock.patch.object(
                    install_drainer,
                    "_rewrite_definition",
                    mock.Mock(side_effect=OSError("no room")),
                ):
                    with self.assertRaises(install_drainer.RelocationFailed):
                        self.relocate()
        self.assertEqual(observed, [("write", True), ("roll_back", True)])

    def observed_plan_locks(self):
        """Which locks each `plan_relocation` call ran under."""
        observed = []
        real = install_drainer.plan_relocation

        def plan(install_dir):
            observed.append(
                (
                    self.lock_is_held(self.legacy_record),
                    self.lock_is_held(self.destination_record),
                )
            )
            return real(install_dir)

        return observed, plan

    def test_an_existing_destination_record_is_read_under_its_own_lock(self):
        # That record has writers the legacy lock does not exclude: discovery
        # probes the XDG location first, so they resolve it rather than the
        # legacy record and never block. Reading it for the merge outside its
        # lock is what would let one of their entries be silently replaced by
        # the document this run had already computed.
        self.destination.mkdir(parents=True)
        self.destination_record.write_text("{}", encoding="utf-8")
        observed, plan = self.observed_plan_locks()
        with mock.patch.object(install_drainer, "plan_relocation", plan):
            self.assertTrue(self.relocate()["relocated"])
        self.assertEqual(observed, [(False, False), (True, True)])

    def test_an_absent_destination_record_is_locked_only_once_it_can_be_reached(self):
        # Until this run creates it, every writer on the host resolves the
        # legacy record and is blocked on the lock already held — so there is
        # nothing to serialize against yet, and taking the lock early would
        # only create a lock file that a refusal could never take back.
        observed, plan = self.observed_plan_locks()
        with mock.patch.object(install_drainer, "plan_relocation", plan):
            self.assertTrue(self.relocate()["relocated"])
        self.assertEqual(observed, [(False, False), (True, False)])

    def test_a_refusal_never_creates_the_destination_or_its_lock(self):
        # Including a refusal raised after the legacy lock was taken: the
        # destination's lock is taken only once the last refusal has passed,
        # because taking it creates a file no rollback may unlink.
        (self.legacy_dir / "notes.txt").write_text("mine\n", encoding="utf-8")
        self.assert_refuses_and_changes_nothing("not something this installer created")
        self.assertFalse(self.destination.exists())

    def test_a_dry_run_takes_no_lock_at_all(self):
        with mock.patch.object(
            drain_prs_service,
            "document_lock",
            side_effect=AssertionError("a dry run took a lock"),
        ):
            plan = install_drainer.plan_relocation(self.destination)
        self.assertEqual(
            [entry.identity for entry in plan.repositories], ["acme/widgets"]
        )

    def test_a_legacy_record_that_reappears_is_carried_across_and_cleared(self):
        # An empty record is the smallest thing a late writer can leave: there
        # is nothing in it to carry, so the whole repair is taking it away
        # again, and the run says so rather than advising a re-run that would
        # have nothing left to do.
        with self.racing(lambda: self.legacy_record.write_text("{}", encoding="utf-8")):
            result = self.relocate()
        self.assertTrue(result["legacy_record_reappeared"])
        self.assertTrue(result["late_writes"]["resolved"])
        self.assertEqual(result["late_writes"]["passes"], 1)
        self.assertIn("cleared again", result["repair"])
        self.assert_location_is_sealed()


class CheckoutFenceTests(RelocationFixture):
    """The run lock every recorded checkout is held under for the transition.

    Reading a PID file is a snapshot, and the record locks do not exclude a
    drainer at all — it never takes them. So the relocation takes the lock the
    drainer itself takes, and a run starting after the preflight fails where it
    stands rather than draining a checkout whose installation is being moved
    out from under it.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]

    def a_drainer_starts(self, mode="single-pr", pull_request=1):
        """Exactly what `drain_prs.py` does when a run begins."""
        return drain_prs.acquire_lock(
            self.widgets, mode=mode, pull_request=pull_request
        )

    def test_a_drainer_starting_after_the_preflight_is_fenced_out(self):
        # The interleaving the reviewer named, at the instant it matters: the
        # preflight has passed, the transition is under way, and a foreground
        # run tries to take the checkout.
        observed = {}
        real = install_drainer._apply_relocation

        def during(transition, plan, sources):
            with self.assertRaises(drain_prs.RunLockedError):
                self.a_drainer_starts()
            observed["fenced"] = True
            return real(transition, plan, sources)

        with mock.patch.object(install_drainer, "_apply_relocation", during):
            self.assertTrue(self.relocate()["relocated"])
        self.assertTrue(observed["fenced"])

    def test_a_dry_run_drainer_is_fenced_out_too(self):
        # A dry run takes the `.git` rendezvous alone, which is the lock this
        # fence holds, so it is excluded on the same terms.
        observed = {}
        real = install_drainer._apply_relocation

        def during(transition, plan, sources):
            with self.assertRaises(drain_prs.RunLockedError):
                drain_prs.acquire_lock(self.widgets, dry_run=True)
            observed["fenced"] = True
            return real(transition, plan, sources)

        with mock.patch.object(install_drainer, "_apply_relocation", during):
            self.assertTrue(self.relocate()["relocated"])
        self.assertTrue(observed["fenced"])

    def test_the_fence_is_released_once_the_relocation_is_done(self):
        self.assertTrue(self.relocate()["relocated"])
        lock = self.a_drainer_starts()
        self.addCleanup(lock.close)

    def test_the_fence_is_released_after_a_rollback(self):
        with mock.patch.object(
            install_drainer,
            "_rewrite_definition",
            mock.Mock(side_effect=OSError("no room")),
        ):
            with self.assertRaises(install_drainer.RelocationFailed):
                self.relocate()
        lock = self.a_drainer_starts()
        self.addCleanup(lock.close)

    def test_a_checkout_already_being_drained_refuses_before_anything_moves(self):
        lock = self.a_drainer_starts(mode="polling", pull_request=None)
        self.addCleanup(lock.close)
        self.assert_refuses_and_changes_nothing("a drainer is running in")

    def a_controller_starts(self, runtime_dir=None):
        """A controller taking the lock `run_service` holds for its life."""
        runtime = runtime_dir or (self.legacy_dir / "runtime" / self.job.slug)
        descriptor = drain_prs_service.acquire_controller_lock(runtime)
        self.addCleanup(lambda: os.close(descriptor))
        return descriptor

    def test_a_running_controller_refuses_the_relocation(self):
        # The signal neither liveness check can see: `run_service` takes this
        # lock inside its record-locked startup transaction and keeps it for
        # the process's life, before it has spawned any drainer — so it is
        # neither a managed running job nor a holder of the checkout's run
        # lock, and its supervision would resume against paths this run
        # removed.
        self.a_controller_starts()
        self.assert_relocate_refuses_and_changes_nothing("controller is running")

    def test_a_controller_at_the_destination_refuses_it_too(self):
        # Both ends, because both are locations this run writes into. Arranged
        # so the fence is the only thing that can refuse: with no source tree
        # nothing would be moved onto the destination, so the collision check
        # has nothing to say and a live controller there is the whole reason
        # to stop.
        shutil.rmtree(self.legacy_dir / "runtime" / self.job.slug)
        destination = self.destination / "runtime" / self.job.slug
        destination.mkdir(parents=True)
        self.a_controller_starts(destination)
        self.assert_relocate_refuses_and_changes_nothing("controller is running")

    def test_a_controller_starting_mid_transition_blocks_on_the_record_lock(self):
        # A controller that has not taken its lock yet is not fenced by that
        # lock -- there is no file to hold. It is fenced by the record's,
        # because `run_service` acquires the controller lock inside its own
        # record-locked transaction, and this run holds that record lock for
        # its whole span.
        observed = {}
        real = install_drainer._apply_relocation

        def during(transition, plan, sources):
            observed["record held"] = self.lock_is_held(self.legacy_record)
            return real(transition, plan, sources)

        with mock.patch.object(install_drainer, "_apply_relocation", during):
            self.assertTrue(self.relocate()["relocated"])
        self.assertTrue(observed["record held"])

    def test_a_runtime_directory_with_no_lock_file_is_not_fenced(self):
        # A controller creates that file when it takes the lock, so its
        # absence means none ever has — and creating one to fence it would be
        # this run mutating an installation it may yet refuse.
        runtime = self.legacy_dir / "runtime" / self.job.slug
        lock = drain_prs_service.controller_lock_path(runtime)
        self.assertFalse(lock.exists())
        self.assertTrue(self.relocate()["relocated"])
        self.assertTrue(install_drainer._is_relocation_seal(self.legacy_guard))

    def test_a_repository_the_fence_does_not_cover_refuses(self):
        # Fail closed on the one thing the preflight-derived fence cannot
        # cover: a repository that appears only in the authoritative plan.
        real = install_drainer.plan_relocation
        calls = []

        def plan(install_dir):
            result = real(install_dir)
            calls.append(result)
            if len(calls) == 1:
                return dataclasses.replace(result, repositories=())
            return result

        with mock.patch.object(install_drainer, "plan_relocation", plan):
            before = self.host_state()
            with self.assertRaises(install_drainer.InstallError) as raised:
                self.relocate()
        self.assertIn("no run lock is held for it", str(raised.exception))
        self.assertEqual(self.host_state(), before)


class MalformedTreeTests(RelocationFixture):
    """A runtime or log path that is not a directory is refused, not carried.

    Moved, it would satisfy "the tree arrived" and the legacy installation
    would be removed around it; the next controller is the one that finds out,
    when it tries to create a directory at a path a file already occupies.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]

    def replace_with_a_file(self, path):
        shutil.rmtree(path)
        path.write_text("not a tree\n", encoding="utf-8")

    def test_a_runtime_path_that_is_a_regular_file_refuses(self):
        self.replace_with_a_file(self.legacy_dir / "runtime" / self.job.slug)
        self.assert_refuses_and_changes_nothing("runtime path")

    def test_a_log_path_that_is_a_regular_file_refuses(self):
        self.replace_with_a_file(self.legacy_logs / self.job.slug)
        self.assert_refuses_and_changes_nothing("log path")

    def test_a_destination_path_that_is_a_regular_file_refuses(self):
        destination = self.destination / "runtime" / self.job.slug
        destination.parent.mkdir(parents=True)
        destination.write_text("not a tree\n", encoding="utf-8")
        self.assert_refuses_and_changes_nothing("is not a directory")


class RollbackTests(RelocationFixture):
    """Requirement 8: any failure runs every registered undo in reverse."""

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.before = self.host_state()

    def failing_relocate(self, step, error):
        """A relocation whose `step` fails, and the `RelocationFailed` it
        raises. Every case below fails at a different depth, because what a
        rollback has to undo is exactly what had already been done."""
        replacement = (
            mock.Mock(return_value=None)
            if error is None
            else mock.Mock(side_effect=error)
        )
        with mock.patch.object(install_drainer, step, replacement):
            with self.assertRaises(install_drainer.RelocationFailed) as raised:
                self.relocate()
        return raised.exception

    def assert_rolled_back(self):
        self.assertEqual(
            self.outside_the_destination(self.host_state()),
            self.outside_the_destination(self.before),
        )
        self.assert_destination_holds_only_its_lock()

    def test_a_failure_rewriting_a_definition_is_rolled_back_whole(self):
        self.failing_relocate("_rewrite_definition", OSError("no room"))
        self.assert_rolled_back()

    def test_a_failure_after_the_moves_puts_every_tree_back(self):
        self.failing_relocate(
            "_require_usable_through_destination",
            install_drainer.InstallError("not usable"),
        )
        self.assert_rolled_back()

    def test_a_failure_removing_the_legacy_installation_is_rolled_back(self):
        self.failing_relocate("_remove_legacy_installation", OSError("read-only"))
        self.assert_rolled_back()

    def test_a_destination_without_the_controller_blocks_removal(self):
        # The gate is read back off disk rather than inferred from the steps
        # reporting success: removal is safe only if every repository really
        # is runnable through the destination now.
        self.failing_relocate("_install_links", None)
        self.assert_rolled_back()

    def test_a_definition_keeps_its_own_mode_through_a_rollback(self):
        # `write_definition_file` installs every definition at the mode its
        # manager reads it with, so a rollback that restored through it alone
        # would hand back the original bytes at a mode the host never had.
        path = install_drainer.service_backend().definition_path(self.job.label)
        path.chmod(0o600)
        before = path.read_bytes()
        self.before = self.host_state()
        self.failing_relocate(
            "_require_usable_through_destination",
            install_drainer.InstallError("not usable"),
        )
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assert_rolled_back()

    def failing_after_removal(self, error):
        """A relocation that fails *after* the legacy installation was taken
        apart, which is the only point at which the removals' own undos are
        the ones under test."""
        real = install_drainer._remove_legacy_installation

        def removing(transition, plan):
            outcome = real(transition, plan)
            raise error

        with mock.patch.object(
            install_drainer, "_remove_legacy_installation", removing
        ):
            with self.assertRaises(install_drainer.RelocationFailed):
                self.relocate()

    def test_a_removed_bytecode_cache_comes_back(self):
        # Regenerating it later is not an undo: the rollback is not entitled
        # to leave anything it deleted deleted.
        cache = self.legacy_dir / "__pycache__"
        cache.mkdir()
        (cache / "kanban_config.cpython-312.pyc").write_bytes(b"\x00cached")
        self.before = self.host_state()
        self.failing_after_removal(OSError("read-only"))
        self.assert_rolled_back()
        self.assertEqual(
            (cache / "kanban_config.cpython-312.pyc").read_bytes(), b"\x00cached"
        )

    def test_a_removed_legacy_directory_comes_back_at_its_own_mode(self):
        # Recreated as it was, not at this installer's own default: a mode it
        # never had is a change the rollback did not undo.
        runtime = self.legacy_dir / "runtime"
        runtime.chmod(0o750)
        self.legacy_logs.chmod(0o750)
        self.before = self.host_state()
        self.failing_after_removal(OSError("read-only"))
        self.assert_rolled_back()
        self.assertEqual(runtime.stat().st_mode & 0o777, 0o750)
        self.assertEqual(self.legacy_logs.stat().st_mode & 0o777, 0o750)

    def test_an_earlier_relocation_marker_keeps_its_own_mode_through_a_rollback(self):
        # A managed entry this run is entitled to rewrite and not entitled to
        # leave more restrictive than it found it.
        marker = self.legacy_dir / "relocated.json"
        marker.write_text('{"install_dir": "/somewhere/older"}', encoding="utf-8")
        marker.chmod(0o644)
        before = marker.read_bytes()
        self.before = self.host_state()
        self.failing_after_removal(OSError("read-only"))
        self.assertEqual(marker.read_bytes(), before)
        self.assertEqual(marker.stat().st_mode & 0o777, 0o644)
        self.assert_rolled_back()

    def test_a_destination_record_keeps_its_own_mode_through_a_rollback(self):
        # The bytes and the mode: this transition replaces the record with a
        # private one, and a rollback that left a previously accepted document
        # more restrictive than it was found has not put it back.
        self.destination.mkdir(parents=True)
        self.destination_record.write_text('{"ntfy_url": "https://n.test/t"}', encoding="utf-8")
        self.destination_record.chmod(0o644)
        before = self.destination_record.read_bytes()
        self.failing_relocate("_rewrite_definition", OSError("no room"))
        self.assertEqual(self.destination_record.read_bytes(), before)
        self.assertEqual(self.destination_record.stat().st_mode & 0o777, 0o644)

    def test_a_runtime_tree_that_did_not_arrive_blocks_removal(self):
        real = install_drainer._move_tree

        def losing(transition, move):
            real(transition, move)
            if move.outcome != "unstarted" and move.destination.parent.name == "runtime":
                shutil.rmtree(move.destination)

        with mock.patch.object(install_drainer, "_move_tree", losing):
            with self.assertRaises(install_drainer.RelocationFailed) as raised:
                self.relocate()
        self.assertIn("runtime state is not a directory at", str(raised.exception))
        self.assertTrue(self.legacy_record.is_file())

    def test_a_rolled_back_failure_leaves_no_installation_at_the_destination(self):
        self.failing_relocate("_rewrite_definition", OSError("no room"))
        self.assert_destination_holds_only_its_lock()
        self.assertFalse(self.destination_record.exists())

    def test_the_process_stops_describing_the_destination_it_did_not_reach(self):
        self.failing_relocate("_rewrite_definition", OSError("no room"))
        self.assertEqual(drain_prs_service.INSTALL_DIR, self.legacy_dir)
        self.assertEqual(drain_prs_service.DISCOVERY_RECORD_PATH, self.legacy_record)

    def test_an_undo_that_cannot_complete_is_reported_beside_the_failure(self):
        # Total over exception types, and it never abandons the remaining
        # actions: a rollback that stopped at its first failure would leave
        # the earliest and most load-bearing ones applied.
        original = install_drainer._Transition.register
        state = {"poisoned": False}

        def register(transition, description, undo):
            if "definition" in description and not state["poisoned"]:
                state["poisoned"] = True
                original(transition, description, mock.Mock(side_effect=OSError("stuck")))
                return
            original(transition, description, undo)

        with mock.patch.object(install_drainer._Transition, "register", register):
            failure = self.failing_relocate(
                "_require_usable_through_destination",
                install_drainer.InstallError("not usable"),
            )
        self.assertTrue(failure.residue)
        self.assertIn("stuck", str(failure))
        self.assertFalse(self.destination_record.exists())


class PreservedInPlaceTests(RelocationFixture):
    """Requirement 7 read through the review's correction: a tree already at
    its destination is preserved rather than moved onto itself."""

    def test_a_log_tree_already_at_the_destination_is_kept(self):
        # The ordinary shape after #358 on a host whose record is still at
        # `~/Library`: the log root is single-valued per platform, so a
        # repository installed after that lands its logs under the XDG state
        # home while the record it is filed in is still the legacy one.
        self.seed_legacy_installation()
        gadgets = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        second = self.seed_repository(gadgets)
        self.assertEqual(drain_prs_service.DISCOVERY_RECORD_PATH, self.legacy_record)
        log = self.destination_logs / second.slug / "service.log"
        self.assertTrue(log.is_file())
        contents = log.read_bytes()
        self.assertTrue(self.relocate()["relocated"])
        self.assertEqual(log.read_bytes(), contents)

    def test_a_runtime_tree_already_at_the_destination_is_kept(self):
        # A repository installed with `--install-dir` naming what turns out to
        # be the destination: its runtime tree is already exactly where this
        # run would put it, so it is preserved in place rather than moved onto
        # itself. The sibling installed the ordinary way still moves.
        self.seed_legacy_installation(custom_install_dir=self.destination)
        placed = drain_prs_service.job_for_identity(self.gadgets, "acme/gadgets")
        moved = drain_prs_service.job_for_identity(self.widgets, "acme/widgets")
        destination = self.destination / "runtime" / placed.slug
        contents = (destination / "status.json").read_bytes()
        self.assertTrue(self.relocate()["relocated"])
        self.assertEqual((destination / "status.json").read_bytes(), contents)
        self.assertTrue(
            (self.destination / "runtime" / moved.slug / "status.json").is_file()
        )


class CrossFilesystemMoveTests(RelocationFixture):
    """Requirement 9: a tree move is safe to fail on either half."""

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.before = self.host_state()

    def cross_filesystem(self):
        """Both trees on different filesystems, which is what turns every move
        below into a copy and a removal. Answered at the rename seam rather
        than by replacing `os.replace`, so the record writes this transition
        also performs stay real."""
        return mock.patch.object(
            install_drainer, "_rename_tree", return_value=False
        )

    def test_a_copy_that_lands_relocates_exactly_as_a_rename_would(self):
        with self.cross_filesystem():
            result = self.relocate()
        self.assertTrue(result["relocated"])
        self.assertEqual(
            sorted({move["how"] for move in result["moved"]}), ["copied"]
        )
        self.assertTrue(
            (self.destination / "runtime" / self.job.slug / "status.json").is_file()
        )
        self.assertFalse((self.legacy_dir / "runtime" / self.job.slug).exists())

    def test_a_copy_that_fails_takes_its_incomplete_destination_with_it(self):
        with self.cross_filesystem():
            with mock.patch.object(
                install_drainer.shutil, "copytree", side_effect=OSError("no room")
            ):
                with self.assertRaises(install_drainer.RelocationFailed):
                    self.relocate()
        self.assertEqual(
            self.outside_the_destination(self.host_state()),
            self.outside_the_destination(self.before),
        )
        self.assert_destination_holds_only_its_lock()

    def test_a_cleanup_that_cannot_remove_the_partial_copy_reports_it(self):
        # An ignored cleanup error is exactly a partial destination nothing
        # ever mentions: the undo has nothing to reverse, so without this the
        # run would report a clean rollback over a half-copied tree.
        def half_copy(source, destination, symlinks=False):
            Path(destination).mkdir(parents=True)
            (Path(destination) / "partial").write_text("half\n", encoding="utf-8")
            raise OSError("no room")

        with self.cross_filesystem():
            with mock.patch.object(
                install_drainer.shutil, "copytree", side_effect=half_copy
            ):
                with mock.patch.object(
                    install_drainer.shutil, "rmtree", side_effect=OSError("busy")
                ):
                    with self.assertRaises(install_drainer.RelocationFailed) as raised:
                        self.relocate()
        self.assertTrue(
            any("incomplete copy" in note for note in raised.exception.residue)
        )
        # The source is untouched and stays authoritative.
        self.assertTrue(
            (self.legacy_dir / "runtime" / self.job.slug / "status.json").is_file()
        )

    def test_a_source_that_survives_the_copy_keeps_both_and_reports_them(self):
        # Neither tree may be chosen between: the destination is authoritative
        # and the source still exists, and deleting or restoring either would
        # be this installer deciding which copy of a repository's incidents is
        # the real one.
        with self.cross_filesystem():
            with mock.patch.object(
                install_drainer.shutil, "rmtree", side_effect=OSError("busy")
            ):
                with self.assertRaises(install_drainer.RelocationFailed) as raised:
                    self.relocate()
        source = self.legacy_dir / "runtime" / self.job.slug
        destination = self.destination / "runtime" / self.job.slug
        self.assertTrue((source / "status.json").is_file())
        self.assertTrue((destination / "status.json").is_file())
        self.assertTrue(
            any("both trees are kept" in note for note in raised.exception.residue)
        )


class InstallerIntegrationTests(RelocationFixture):
    """The installer's own run: what a dry run reports, and what an install
    does before it links anything."""

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.kanban = self.make_checkout("kanban", "git@github.com:acme/widgets.git")
        tools = self.kanban / "tools"
        tools.mkdir()
        for source in self.sources.values():
            (tools / source.name).write_text(
                source.read_text(encoding="utf-8"), encoding="utf-8"
            )

    def install(self, **options):
        return install_drainer.install(
            self.kanban, self.destination, ntfy_url=None, **options
        )

    def test_a_dry_run_reports_the_plan_and_writes_nothing(self):
        before = self.host_state()
        result = self.install(dry_run=True)
        relocation = result["relocation"]
        self.assertTrue(relocation["dry_run"])
        self.assertEqual(relocation["source"], str(self.legacy_dir))
        self.assertEqual(relocation["destination"], str(self.destination))
        self.assertEqual(
            [entry["repository"] for entry in relocation["repositories"]],
            ["acme/widgets"],
        )
        self.assertIn(str(self.legacy_record), relocation["removes"])
        self.assertEqual(self.host_state(), before)

    def test_a_dry_run_takes_no_lock_at_the_destination(self):
        self.install(dry_run=True)
        self.assertFalse(self.destination.exists())

    def test_a_refusal_fails_the_run_rather_than_installing_at_the_destination(self):
        (self.legacy_dir / "notes.txt").write_text("mine\n", encoding="utf-8")
        before = self.host_state()
        with self.assertRaises(install_drainer.InstallError):
            self.install(dry_run=False)
        self.assertEqual(self.host_state(), before)


class LateWriteCarryTests(RelocationFixture):
    """Issue #369 requirement 1: whatever a writer put back after the removal
    is carried across, and the location is taken away again.

    The writer lands in the one instant the transition's locks cannot reach —
    after the removal, when the record it would have queued on is gone — and it
    writes through the controller's own ungated writers, which is exactly the
    hole this closes.
    """

    def setUp(self):
        super().setUp()
        self.seeded = self.seed_legacy_installation()[0]
        self.bindings = self.legacy_bindings
        self.gadgets = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.slug = drain_prs_service.repository_slug("acme/gadgets")

    def relocate_with_late_write(self):
        with self.racing(lambda: self.write_late(self.gadgets, self.bindings)):
            return self.relocate()

    def test_a_repository_recorded_after_the_removal_is_carried_across(self):
        result = self.relocate_with_late_write()
        late = result["late_writes"]
        self.assertTrue(late["resolved"])
        self.assertEqual(late["passes"], 1)
        self.assertEqual(late["repositories"], ["acme/gadgets"])
        document = self.record_document(self.destination_record)
        self.assertEqual(
            sorted(document["repositories"]), ["acme/gadgets", "acme/widgets"]
        )
        self.assertEqual(
            document["repositories"]["acme/gadgets"]["repository"], str(self.gadgets)
        )

    def test_its_runtime_tree_and_its_logs_arrive_whole(self):
        self.relocate_with_late_write()
        runtime = self.destination / "runtime" / self.slug
        self.assertEqual(
            json.loads(runtime.joinpath("status.json").read_text(encoding="utf-8"))[
                "stamp"
            ],
            "late",
        )
        self.assertTrue(any((runtime / "incidents").iterdir()))
        self.assertIn(
            "late write for acme/gadgets",
            (self.destination_logs / self.slug / "service.log").read_text(
                encoding="utf-8"
            ),
        )

    def test_its_definition_names_this_installation_and_is_reloaded(self):
        self.commands.clear()
        self.relocate_with_late_write()
        backend = install_drainer.service_backend()
        identifier = backend.service_identifier(self.slug)
        self.assertEqual(
            backend.definition_environment(identifier)[
                kanban_config.DRAINER_INSTALL_DIR_ENV
            ],
            str(self.destination),
        )
        self.assertTrue(
            any(identifier in " ".join(command) for command in self.commands),
            self.commands,
        )

    def test_the_recreated_location_is_taken_away_again(self):
        result = self.relocate_with_late_write()
        self.assertEqual(
            sorted(path.name for path in self.legacy_dir.iterdir()),
            ["config.json", "config.json.lock", "relocated.json", "runtime"],
        )
        self.assert_location_is_sealed()
        self.assertFalse(self.legacy_logs.exists())
        self.assertIn(str(self.legacy_record), result["late_writes"]["removed"])
        self.assertEqual(result["late_writes"]["retained"], [])
        self.assertTrue(result["late_writes"]["sealed"])

    def test_a_writer_that_keeps_winning_is_reported_rather_than_looped_on(self):
        # Bounded rather than looped: this writer recreates the record after
        # every clear, so a run that kept going would never return.
        real = install_drainer._clear_recreated_location

        def relentless(transition, relocation_plan, outcome):
            real(transition, relocation_plan, outcome)
            relocation_plan.legacy_record.write_text("{}", encoding="utf-8")

        with mock.patch.object(
            install_drainer, "_clear_recreated_location", relentless
        ):
            with self.racing(
                lambda: self.legacy_record.write_text("{}", encoding="utf-8")
            ):
                result = self.relocate()
        late = result["late_writes"]
        self.assertEqual(late["passes"], install_drainer._LATE_WRITER_PASSES)
        self.assertFalse(late["resolved"])
        self.assertEqual(late["collisions"], [])
        self.assertIn(str(self.legacy_record), late["retained"])
        self.assertIn("kept recreating", late["repair"])
        # Nothing is in two places, so a re-run really is the repair here.
        self.assertIn("re-run this installer", late["repair"])

    def test_a_queued_writer_fails_without_recording_anything(self):
        # The other half of the same race, and the half a lock does close: a
        # writer that queued on the legacy record's lock resumes into a
        # location whose record is gone, reads the marker left beside that
        # lock, and refuses before it writes.
        self.relocate()
        with self.as_bound(self.bindings):
            before = self.host_state()
            with self.assertRaises(drain_prs_service.ServiceError):
                drain_prs_service.install_job(
                    drain_prs_service.resolve_job(self.widgets)
                )
            self.assertEqual(self.host_state(), before)
        self.assert_location_is_sealed()


class SealedRecordPathTests(RelocationFixture):
    """What a finished relocation leaves at the record path it emptied.

    The reconciliation can carry across what a writer put back while the run is
    still looking, and nothing can carry what one puts back afterwards: `flock`
    cannot be asked whether anyone is waiting on it, and a process that has
    returned cannot look again. So the emptied path is left occupied by a
    symlink to the marker beside it, which every copy of the controller old
    enough to write a discovery record refuses to write over.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.result = self.relocate()

    def test_the_emptied_record_path_is_sealed(self):
        self.assertTrue(self.result["late_writes"]["sealed"])
        self.assert_location_is_sealed()

    def test_the_closed_lock_refuses_a_writer_before_it_reaches_the_record(self):
        # `document_lock` is the first thing every transition and every record
        # write enters, and the lock it opens is closed — so this is what a
        # writer at this location meets now, whatever it came to do.
        with self.assertRaises(drain_prs_service.ServiceError) as raised:
            drain_prs_service.update_json_document(
                self.legacy_record, lambda document: {"repositories": {}}
            )
        self.assertIn("Refusing unsafe config lock path", str(raised.exception))
        self.assertIn(str(self.legacy_lock), str(raised.exception))
        self.assert_location_is_sealed()

    def test_every_record_writer_still_refuses_the_seal_underneath_it(self):
        """#369's own bound, asked with the lock out of the way.

        The two are independent, and this is what keeps that true: the shared
        mutator each of `write_discovery_record`, `merge_repository_record` and
        `remove_discovery_record` goes through refuses the sealed record path
        itself, in this copy and in every copy back to the one that introduced
        the record — not because the lock beside it happens to be closed.
        """
        self.legacy_lock.chmod(0o600)
        with self.assertRaises(drain_prs_service.ServiceError) as raised:
            drain_prs_service.update_json_document(
                self.legacy_record, lambda document: {"repositories": {}}
            )
        self.assertIn("Refusing unsafe config path", str(raised.exception))
        self.assertTrue(install_drainer._is_relocation_seal(self.legacy_record))

    def test_it_reads_as_the_relocation_notice_rather_than_as_a_record(self):
        # Following it finds the marker, which names where the installation
        # went and has no `repositories` table — so a reader bound here learns
        # the truth rather than an empty installation.
        document = drain_prs_service._read_json_object(self.legacy_record)
        self.assertEqual(
            document[drain_prs_service.RELOCATION_MARKER_DESTINATION],
            str(self.destination),
        )
        self.assertNotIn("repositories", document)

    def test_a_later_run_relocates_nothing_and_changes_nothing(self):
        before = self.host_state()
        again = self.relocate()
        self.assertFalse(again["relocated"])
        self.assertIn("emptied and sealed", again["reason"])
        self.assertEqual(self.host_state(), before)

    def test_a_later_run_over_residue_keeps_the_guard_rather_than_clearing_it(self):
        """The guard has to be admitted by this installer's own ownership and
        emptiness vocabulary, or it would break the sweep it sits inside.

        A sealed location that acquires state again is planned and reconciled
        exactly as an unsealed one is, so that run meets the guard while
        deciding what is a stray, what a writer put back, and what may be
        removed with the installation. It has to answer "mine, and not to be
        taken away" to all three — and a run that removed it, even to write it
        again at the end, would reopen for its own length exactly the window
        the guard exists to close.
        """
        stray = self.legacy_logs / "someone.else"
        stray.mkdir(parents=True)
        (stray / "service.log").write_text("kept\n", encoding="utf-8")
        # No longer finished business, so this run really does plan the
        # location rather than skipping it.
        self.assertIsNone(install_drainer.relocation_disposition(self.destination))
        again = self.relocate()
        self.assertTrue(again["relocated"])
        late = again["late_writes"]
        self.assertTrue(late["resolved"], late["repair"])
        self.assertEqual(late["strays"], [])
        self.assertEqual(late["unattributed"], [])
        self.assertIn(str(self.legacy_guard), again["retained"])
        self.assertNotIn(str(self.legacy_guard), again["removed"])
        self.assertNotIn(str(self.legacy_guard), late["removed"])
        # What was there is carried, the guard is the same object it was, and
        # the location reads as finished business again.
        self.assertTrue(
            (self.destination_logs / "someone.else" / "service.log").is_file()
        )
        self.assert_location_is_sealed()
        self.assertIn(
            "emptied and sealed",
            install_drainer.relocation_disposition(self.destination),
        )

    def test_a_location_missing_one_seal_is_not_finished_business(self):
        """Being sealed is an answer only when every path sealing closes is
        closed: a run that emptied this location and could not write one of
        them left a path a controller still bound here writes through, and
        reading the other seal as an answer would make it invisible forever.
        """
        self.legacy_guard.unlink()
        self.assertIsNone(install_drainer.relocation_disposition(self.destination))
        again = self.relocate()
        self.assertTrue(again["relocated"])
        self.assertTrue(again["late_writes"]["sealed"])
        self.assert_location_is_sealed()

    def test_the_lock_beside_it_is_still_never_unlinked(self):
        self.assertTrue((self.legacy_dir / "config.json.lock").is_file())
        self.assertTrue(
            (self.legacy_dir / drain_prs_service.RELOCATION_MARKER_NAME).is_file()
        )


class UnsealedResidueTests(RelocationFixture):
    """A location this run could not finish reconciling is left as it stands.

    Sealing one would close the path the operator has to reconcile through, and
    would claim an answer this run does not have.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.bindings = self.legacy_bindings

    def test_a_collision_leaves_the_record_path_unsealed(self):
        with self.racing(lambda: self.write_late(self.widgets, self.bindings)):
            result = self.relocate()
        self.assertFalse(result["late_writes"]["resolved"])
        self.assertFalse(result["late_writes"]["sealed"])
        self.assertFalse(install_drainer._is_relocation_seal(self.legacy_record))
        self.assertTrue(_plain_file_at(self.legacy_record))

    def test_a_stray_leaves_it_unsealed_too(self):
        def late():
            self.legacy_record.write_text("{}", encoding="utf-8")
            (self.legacy_dir / "notes.txt").write_text("mine\n", encoding="utf-8")

        with self.racing(late):
            result = self.relocate()
        self.assertFalse(result["late_writes"]["sealed"])
        self.assertFalse(install_drainer._is_relocation_seal(self.legacy_record))

    def test_a_seal_that_cannot_be_written_is_reported_rather_than_raised(self):
        # Total on the same terms as the rest of the reconciliation: this runs
        # after the removal, so a relocation that already succeeded is not
        # rolled back over a seal that could not be written, and the run says
        # the one thing an operator can act on — re-run it.
        patcher = mock.patch.object(
            install_drainer.Path, "symlink_to", side_effect=OSError("read-only")
        )
        self.addCleanup(patcher.stop)
        # Armed after the links are installed, so what fails is the seal rather
        # than the installation this run is making.
        with self.racing(patcher.start):
            result = self.relocate()
        patcher.stop()
        self.assertTrue(result["relocated"])
        self.assertTrue(result["late_writes"]["resolved"])
        self.assertFalse(result["late_writes"]["sealed"])
        self.assertFalse(os.path.lexists(self.legacy_record))
        self.assertIn("could not be sealed", result["repair"])
        self.assertIn("re-run this installer", result["repair"])
        # And the install does not report success over it: a record path left
        # open to a controller still bound there is the one thing this run
        # could not finish, whatever else it did.
        with self.assertRaises(install_drainer.RelocationUnresolved) as raised:
            install_drainer._require_relocation_resolved(result)
        self.assertIn("was left open", str(raised.exception))
        self.assertIn(str(self.legacy_record), str(raised.exception))

    def test_reconciling_and_re_running_then_seals_it(self):
        # What the remediation tells the operator to do, and what it gets them.
        with self.racing(lambda: self.write_late(self.widgets, self.bindings)):
            self.relocate()
        shutil.rmtree(self.legacy_dir / "runtime" / self.job.slug)
        shutil.rmtree(self.legacy_logs / self.job.slug)
        again = self.relocate()
        self.assertTrue(again["relocated"])
        self.assertTrue(again["late_writes"]["sealed"])
        self.assert_location_is_sealed()


def _plain_file_at(path):
    return path.is_file() and not path.is_symlink()


class LateWriteCollisionTests(RelocationFixture):
    """Requirements 2 and 3: durable state in both places is kept and named,
    and the repair is the one that works."""

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.slug = self.job.slug
        self.bindings = self.legacy_bindings

    def relocate_with_late_write(self, prepare=None):
        def late():
            if prepare is not None:
                prepare()
            self.write_late(self.widgets, self.bindings)

        with self.racing(late):
            return self.relocate()

    def test_a_late_write_for_an_already_migrated_repository_keeps_both_trees(self):
        result = self.relocate_with_late_write()
        late = result["late_writes"]
        self.assertFalse(late["resolved"])
        self.assertEqual(late["repositories"], ["acme/widgets"])
        self.assertEqual(
            sorted(
                (item["kind"], item["source"], item["destination"])
                for item in late["collisions"]
            ),
            sorted(
                [
                    (
                        "log",
                        str(self.legacy_logs / self.slug),
                        str(self.destination_logs / self.slug),
                    ),
                    (
                        "runtime",
                        str(self.legacy_dir / "runtime" / self.slug),
                        str(self.destination / "runtime" / self.slug),
                    ),
                ]
            ),
        )

    def test_nothing_chooses_which_status_incidents_or_logs_survive(self):
        self.relocate_with_late_write()
        late_runtime = self.legacy_dir / "runtime" / self.slug
        carried_runtime = self.destination / "runtime" / self.slug
        self.assertEqual(
            json.loads(late_runtime.joinpath("status.json").read_text(encoding="utf-8"))[
                "stamp"
            ],
            "late",
        )
        self.assertNotIn(
            "stamp",
            json.loads(
                carried_runtime.joinpath("status.json").read_text(encoding="utf-8")
            ),
        )
        self.assertTrue(any((late_runtime / "incidents").iterdir()))
        self.assertTrue(any((carried_runtime / "incidents").iterdir()))
        self.assertIn(
            "late write for acme/widgets",
            (self.legacy_logs / self.slug / "service.log").read_text(encoding="utf-8"),
        )
        self.assertIn(
            "seeded acme/widgets",
            (self.destination_logs / self.slug / "service.log").read_text(
                encoding="utf-8"
            ),
        )

    def test_the_unresolved_location_is_preserved_rather_than_cleared(self):
        result = self.relocate_with_late_write()
        retained = result["late_writes"]["retained"]
        self.assertTrue(self.legacy_record.is_file())
        self.assertIn(str(self.legacy_record), retained)
        self.assertIn(str(self.legacy_dir / "runtime"), retained)
        self.assertIn(str(self.legacy_logs / self.slug), retained)
        self.assertEqual(result["late_writes"]["removed"], [])

    def test_the_repair_is_reconciliation_rather_than_a_re_run(self):
        repair = self.relocate_with_late_write()["repair"]
        self.assertIn("Both copies are kept", repair)
        self.assertIn("A re-run alone is not the repair", repair)
        self.assertIn(str(self.legacy_logs / self.slug), repair)
        self.assertIn(str(self.destination_logs / self.slug), repair)

    def test_the_install_fails_rather_than_reporting_success(self):
        # The relocation itself succeeded and is not rolled back — rolling it
        # back is the one action that could lose what the late writer recorded
        # — but an install that returned success would be telling automation
        # that a host with a repository's state in two places is finished.
        result = self.relocate_with_late_write()
        with self.assertRaises(install_drainer.RelocationUnresolved) as raised:
            install_drainer._require_relocation_resolved(result)
        self.assertEqual(raised.exception.report, result["late_writes"])
        self.assertIn("acme/widgets", str(raised.exception))

    def assert_re_run_refuses_naming(self, *roots):
        """The remediation's own claim, asked of the re-run it names: it
        refuses, it names both roots of a tree that was kept, and it does that
        before anything is mutated."""
        before = self.host_state()
        with self.assertRaises(install_drainer.InstallError) as raised:
            install_drainer.plan_relocation(self.destination)
        message = str(raised.exception)
        for root in roots:
            self.assertIn(str(root), message)
        self.assertEqual(self.host_state(), before)

    def test_a_re_run_then_refuses_naming_both_roots_and_changes_nothing(self):
        self.relocate_with_late_write()
        # The runtime pair is what it reaches first, and naming it is what
        # makes the re-run the repair the report says it is not.
        self.assert_re_run_refuses_naming(
            self.legacy_dir / "runtime" / self.slug,
            self.destination / "runtime" / self.slug,
        )

    def test_only_the_colliding_runtime_tree_is_kept_and_the_logs_are_carried(self):
        # Asymmetric: the destination already holds this repository's runtime
        # tree and no longer holds its logs, so exactly one of the two is in
        # two places.
        result = self.relocate_with_late_write(
            prepare=lambda: shutil.rmtree(self.destination_logs / self.slug)
        )
        late = result["late_writes"]
        self.assertEqual([item["kind"] for item in late["collisions"]], ["runtime"])
        self.assertIn(
            "late write for acme/widgets",
            (self.destination_logs / self.slug / "service.log").read_text(
                encoding="utf-8"
            ),
        )
        self.assertFalse((self.legacy_logs / self.slug).exists())
        self.assertTrue((self.legacy_dir / "runtime" / self.slug / "status.json").is_file())
        self.assertIn(str(self.legacy_dir / "runtime"), late["retained"])
        # And the re-run the report tells the operator not to rely on refuses
        # over exactly the tree that was kept — which it can only do because
        # the legacy location's own runtime tree is a source in its own right,
        # the definition having been rewritten to the destination.
        self.assert_re_run_refuses_naming(
            self.legacy_dir / "runtime" / self.slug,
            self.destination / "runtime" / self.slug,
        )

    def test_only_the_colliding_log_tree_is_kept_and_the_runtime_is_carried(self):
        result = self.relocate_with_late_write(
            prepare=lambda: shutil.rmtree(self.destination / "runtime" / self.slug)
        )
        late = result["late_writes"]
        self.assertEqual([item["kind"] for item in late["collisions"]], ["log"])
        self.assertEqual(
            json.loads(
                (self.destination / "runtime" / self.slug / "status.json").read_text(
                    encoding="utf-8"
                )
            )["stamp"],
            "late",
        )
        self.assertFalse((self.legacy_dir / "runtime" / self.slug).exists())
        self.assertIn(str(self.legacy_logs / self.slug), late["retained"])
        self.assert_re_run_refuses_naming(
            self.legacy_logs / self.slug, self.destination_logs / self.slug
        )


class LateWriteMergeTests(RelocationFixture):
    """The late record merges on exactly the relocation's own terms: the
    destination wins per key at both levels, and what only the recreated record
    names survives."""

    def setUp(self):
        super().setUp()
        self.seed_legacy_installation()
        # While the legacy record is still the one this host resolves, so this
        # is the installation's own selection rather than a stale process's.
        install_drainer.write_installed_config_path(
            "acme/widgets", "/destination/widgets.toml"
        )
        self.bindings = self.legacy_bindings
        self.gadgets = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        # An unrelated repository already recorded at the destination, seeded
        # through the controller's own install so its entry and its definition
        # are the ones this host really derives.
        self.gizmos = self.make_checkout("gizmos", "git@github.com:acme/gizmos.git")
        legacy = self.record_document(self.legacy_record)
        self.set_platform("darwin")
        self.seed_repository(self.gizmos)
        self.set_platform("linux")
        promoted = self.record_document(self.legacy_record)
        self.destination.mkdir(parents=True, exist_ok=True)
        self.destination_record.write_text(
            json.dumps(
                {
                    "ntfy_url": "https://notify.example.test/current",
                    "repositories": {
                        "acme/gizmos": promoted["repositories"]["acme/gizmos"]
                    },
                }
            ),
            encoding="utf-8",
        )
        self.legacy_record.write_text(json.dumps(legacy), encoding="utf-8")

    def test_the_destination_wins_and_legacy_only_values_survive(self):
        def late():
            self.write_late(self.gadgets, self.bindings)
            with self.as_bound(self.bindings):
                drain_prs_service.merge_json_document(
                    self.legacy_record,
                    {
                        "ntfy_url": "https://notify.example.test/late",
                        "late_only": "kept",
                    },
                )

        with self.racing(late):
            result = self.relocate()
        self.assertTrue(result["late_writes"]["resolved"])
        document = self.record_document(self.destination_record)
        self.assertEqual(document["ntfy_url"], "https://notify.example.test/current")
        self.assertEqual(document["late_only"], "kept")
        self.assertEqual(
            sorted(document["repositories"]),
            ["acme/gadgets", "acme/gizmos", "acme/widgets"],
        )

    def test_a_repository_recorded_at_both_keeps_the_destinations_entry(self):
        def late():
            # Through the pre-gate installed copy `write_late` above explains:
            # a writer running *this* copy is refused rather than recorded.
            with self.as_bound(self.bindings):
                with mock.patch.object(
                    drain_prs_service, "require_current_installation", lambda: None
                ):
                    drain_prs_service.merge_repository_record(
                        "acme/widgets", {"config_path": "/late/widgets.toml"}
                    )

        with self.racing(late):
            result = self.relocate()
        self.assertTrue(result["late_writes"]["resolved"])
        entry = self.record_document(self.destination_record)["repositories"][
            "acme/widgets"
        ]
        self.assertEqual(entry["config_path"], "/destination/widgets.toml")


class LateWriteOwnershipTests(RelocationFixture):
    """Requirement 4: clearing the recreated location asks the same ownership
    question the relocation's own removal asks."""

    def setUp(self):
        super().setUp()
        self.seed_legacy_installation()
        self.bindings = self.legacy_bindings

    def relocate_with(self, write):
        with self.racing(write):
            return self.relocate()

    def test_a_file_this_installer_did_not_create_is_kept_and_named(self):
        def late():
            self.legacy_record.write_text("{}", encoding="utf-8")
            (self.legacy_dir / "notes.txt").write_text("mine\n", encoding="utf-8")

        result = self.relocate_with(late)
        late_writes = result["late_writes"]
        self.assertFalse(late_writes["resolved"])
        self.assertEqual(late_writes["strays"], [str(self.legacy_dir / "notes.txt")])
        self.assertEqual(
            (self.legacy_dir / "notes.txt").read_text(encoding="utf-8"), "mine\n"
        )
        # And nothing at that location is removed — including the record this
        # run would otherwise have taken away.
        self.assertTrue(self.legacy_record.is_file())
        self.assertEqual(late_writes["removed"], [])
        self.assertIn("Move it aside", late_writes["repair"])
        self.assertIn("re-run this installer", late_writes["repair"])

    def test_a_managed_name_holding_the_wrong_kind_of_object_is_one_too(self):
        # The name selects the slot; the object type is what proves the entry
        # is this installer's, exactly as the removal decides it.
        result = self.relocate_with(lambda: (self.legacy_dir / "drain_prs.py").mkdir())
        late_writes = result["late_writes"]
        self.assertEqual(
            late_writes["strays"], [str(self.legacy_dir / "drain_prs.py")]
        )
        self.assertTrue((self.legacy_dir / "drain_prs.py").is_dir())
        self.assertEqual(late_writes["removed"], [])


class StaleInstallRefusalTests(RelocationFixture):
    """Requirement 5: an install refuses outright when the installation it
    resolved at import is no longer the one this host has, rather than writing
    a definition naming a controller that is gone."""

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.bindings = self.legacy_bindings
        self.kanban = self.make_checkout("kanban", "git@github.com:acme/widgets.git")
        tools = self.kanban / "tools"
        tools.mkdir()
        for source in self.sources.values():
            (tools / source.name).write_text(
                source.read_text(encoding="utf-8"), encoding="utf-8"
            )
        self.assertTrue(self.relocate()["relocated"])
        self.commands.clear()

    def test_the_controllers_install_refuses_and_writes_nothing(self):
        with self.as_bound(self.bindings):
            before = self.host_state()
            with self.assertRaises(drain_prs_service.ServiceError) as raised:
                drain_prs_service.install_job(self.job)
            self.assertEqual(self.host_state(), before)
        self.assertIn("was relocated to", str(raised.exception))
        self.assertEqual(self.commands, [])

    def test_the_installer_refuses_before_it_links_or_records_anything(self):
        # Managed links, the shared configuration, the discovery record, the
        # runtime and log trees and the service definition: every one of them
        # is downstream of this gate, so the whole host is unchanged.
        with self.as_bound(self.bindings):
            before = self.host_state()
            with self.assertRaises(install_drainer.InstallError) as raised:
                install_drainer.install(
                    self.kanban,
                    self.destination,
                    ntfy_url="https://notify.example.test/new",
                    config_path=str(self.kanban / "config.toml"),
                    dry_run=False,
                )
            self.assertEqual(self.host_state(), before)
        self.assertIn("Refusing to install", str(raised.exception))
        self.assertIn(str(self.destination), str(raised.exception))

    def test_the_check_is_taken_under_the_discovery_records_lock(self):
        # So a relocation has either not started or finished by the time it is
        # answered: the unlocked check refuses cheaply, and the locked one is
        # the authoritative answer.
        observed = []
        real = drain_prs_service.require_current_installation

        def watched():
            observed.append(self.lock_is_held(self.destination_record))
            return real()

        with mock.patch.object(
            drain_prs_service, "require_current_installation", watched
        ):
            with self.assertRaises(install_drainer.InstallError):
                install_drainer.install(
                    self.kanban, self.destination, ntfy_url=None, dry_run=False
                )
        self.assertIn(True, observed)


class LateWriteReportingTests(RelocationFixture):
    """Unresolved retained state says the same actionable thing through both
    of the installer's command modes."""

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.bindings = self.legacy_bindings
        self.kanban = self.make_checkout("kanban", "git@github.com:acme/widgets.git")
        tools = self.kanban / "tools"
        tools.mkdir()
        for source in self.sources.values():
            (tools / source.name).write_text(
                source.read_text(encoding="utf-8"), encoding="utf-8"
            )

    def run_main(self, *extra):
        argv = [
            "install_drainer.py",
            "--repo",
            str(self.kanban),
            "--install-dir",
            str(self.destination),
            *extra,
        ]
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(install_drainer.sys, "argv", argv):
            with contextlib.redirect_stdout(stdout):
                with contextlib.redirect_stderr(stderr):
                    with self.racing(
                        lambda: self.write_late(self.widgets, self.bindings)
                    ):
                        code = install_drainer.main()
        return code, stderr.getvalue()

    def test_the_default_mode_names_the_repository_the_trees_and_the_repair(self):
        code, stderr = self.run_main()
        self.assertEqual(code, 1)
        self.assertIn("acme/widgets", stderr)
        self.assertIn(str(self.legacy_logs / self.job.slug), stderr)
        self.assertIn(str(self.destination_logs / self.job.slug), stderr)
        self.assertIn("A re-run alone is not the repair", stderr)

    def test_the_json_mode_names_them_as_data(self):
        code, stderr = self.run_main("--json")
        self.assertEqual(code, 1)
        payload = json.loads(stderr)
        self.assertIn("acme/widgets", payload["error"])
        report = payload["late_writes"]
        self.assertFalse(report["resolved"])
        self.assertEqual(report["repositories"], ["acme/widgets"])
        self.assertEqual(
            sorted(item["kind"] for item in report["collisions"]), ["log", "runtime"]
        )
        self.assertIn(
            str(self.legacy_dir / "runtime"), report["retained"]
        )
        self.assertIn("A re-run alone is not the repair", report["repair"])


# What the queued writer below runs. A real second process, because
# `document_lock` re-enters within one thread: a writer driven from the
# relocating thread takes that bypass and never contends at all, so nothing
# run there can stand in for interprocess contention. It resolves its own
# managed paths at its own import, exactly as any controller does, and then
# writes the discovery record the way a start or an install does.
_QUEUED_WRITER = """
import contextlib, fcntl, io, json, os, sys, time
from pathlib import Path

for entry in reversed(sys.argv[1].split(os.pathsep)):
    sys.path.insert(0, entry)
ready, go, queued, acquired, result = (
    Path(argument) for argument in sys.argv[2:7]
)
identity, checkout = sys.argv[7], sys.argv[8]
flock_go = Path(sys.argv[12])

import drain_prs_service
import service_manager

# Fixture wiring rather than a protection. Which manager this host has is
# settled by `tools/test_service_manager.py`, and where that manager keeps its
# definitions has to be the directory the parent process reads, or the two
# would name different files. The backend is pinned rather than probed because
# this process cannot count on the host it runs on having a live user manager.
service_manager._DETECTED = service_manager.SYSTEMD
service_manager.SYSTEMD_USER_DIR = Path(sys.argv[11])

# Bound here, while the legacy record is still the one this host resolves.
ready.write_text(str(drain_prs_service.DISCOVERY_RECORD_PATH), encoding="utf-8")
while not go.exists():
    time.sleep(0.01)
outcome = {"bound_record": str(drain_prs_service.DISCOVERY_RECORD_PATH)}
if sys.argv[10] == "trees":
    # Everything a controller puts down before it ever reaches the record, and
    # every bit of it under no record lock at all: the directories, the status
    # file, an incident, a log line and the service definition.
    job = drain_prs_service.resolve_job(Path(checkout))
    outcome["runtime"] = str(job.runtime_dir)
    outcome["logs"] = str(job.log_dir)
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            drain_prs_service.ensure_dirs(job)
            drain_prs_service.atomic_write_json(
                job.status_path, {"state": "starting", "repository": identity}
            )
            drain_prs_service.write_incident(
                job=job, exit_code=9, command=["drain_prs.py", "--path", checkout]
            )
            drain_prs_service.service_log(job, f"pre-gate start for {identity}")
            drain_prs_service.service_backend().write_definition(
                drain_prs_service.service_definition(job)
            )
    except OSError as error:
        # Reported rather than fatal: a location whose runtime root a
        # relocation has sealed refuses the first of these, and what this
        # process did and did not manage to write is the whole observation.
        outcome["trees_refused"] = f"{type(error).__name__}: {error}"
def act():
    try:
        if sys.argv[10].startswith("uninstall"):
            # The one transition that creates no directory: it unloads the job
            # and unlinks the definition before it ever reaches the record
            # write the seal refuses.
            with contextlib.redirect_stdout(io.StringIO()):
                outcome["uninstalled"] = drain_prs_service.uninstall_job(
                    drain_prs_service.resolve_job(Path(checkout))
                )
        else:
            drain_prs_service.merge_repository_record(
                identity, {"repository": checkout}
            )
            outcome["recorded"] = True
    except drain_prs_service.ServiceError as error:
        outcome["refused"] = str(error)
    # Held across the write and a moment past it, so a reader that asks for
    # this lock after the handoff blocks on this process rather than reading a
    # record it is halfway through replacing.
    time.sleep(float(sys.argv[9]))


if sys.argv[10] == "uninstall-delayed":
    # `document_lock` opens the lock file and takes its flock together, and the
    # interleaving under test is exactly the gap between those two: a
    # descriptor opened before the relocation whose flock lands while the run's
    # final pass is holding the lock, so that pass cannot see it. The two
    # halves are therefore performed here with a gate between them, and the
    # re-entrancy bookkeeping that helper keeps for its outermost holder is
    # primed with the same entry it would have recorded — which is what makes
    # the nested acquisition inside `uninstall_job` the pass-through it is in a
    # real invocation rather than a deadlock against this process's own
    # descriptor.
    lock_path = drain_prs_service.DISCOVERY_RECORD_PATH.with_name(
        drain_prs_service.DISCOVERY_RECORD_PATH.name + ".lock"
    )
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    resolved = drain_prs_service.DISCOVERY_RECORD_PATH.absolute()
    queued.write_text("", encoding="utf-8")
    while not flock_go.exists():
        time.sleep(0.01)
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    acquired.write_text("", encoding="utf-8")
    held = getattr(drain_prs_service._HELD_DOCUMENT_LOCKS, "paths", None)
    if held is None:
        held = drain_prs_service._HELD_DOCUMENT_LOCKS.paths = set()
    held.add(resolved)
    try:
        act()
    finally:
        held.discard(resolved)
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)
else:
    queued.write_text("", encoding="utf-8")
    # The record's own lock, taken the way every transition in the controller
    # takes it and before anything is asked about the installation, so where
    # this process waits is settled rather than raced. The write below asks for
    # the same lock again, which re-enters within this one thread exactly as it
    # does inside `install_job`.
    try:
        with drain_prs_service.document_lock(
            drain_prs_service.DISCOVERY_RECORD_PATH
        ):
            acquired.write_text("", encoding="utf-8")
            act()
    except drain_prs_service.ServiceError as error:
        # A location a relocation has finished closing refuses this writer
        # before it ever holds the lock: `document_lock` opens that file
        # `O_RDWR`, and a run that emptied this location left it unopenable.
        outcome["refused"] = str(error)
result.write_text(json.dumps(outcome), encoding="utf-8")
"""


class QueuedRecordWriterTests(RelocationFixture):
    """A writer in another OS process, reaching for the legacy record's lock
    while a relocation holds it.

    It never gets it, and never queues for it either. The run closes that lock
    file against every opener but its own the instant it takes it, and
    `document_lock` opens it `O_RDWR` before any transition reads or writes a
    thing — so this writer is refused where it stands. Queuing is what it did
    before that closure existed, and what made a bounded sweep necessary: a
    writer that waits gets its turn eventually, on a location that moved while
    it waited.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.ready = self.root / "writer.ready"
        self.go = self.root / "writer.go"
        self.queued = self.root / "writer.queued"
        self.acquired = self.root / "writer.acquired"
        self.result = self.root / "writer.result"
        self.writer_script = self.root / "queued_writer.py"
        self.writer_script.write_text(_QUEUED_WRITER, encoding="utf-8")

    def start_writer(self):
        """Spawn it and wait until it has bound its managed paths, which has to
        happen before this run writes a record at the destination: from that
        instant a fresh process resolves the destination instead."""
        process = subprocess.Popen(
            [
                sys.executable,
                str(self.writer_script),
                str(Path(drain_prs_service.__file__).parent),
                str(self.ready),
                str(self.go),
                str(self.queued),
                str(self.acquired),
                str(self.result),
                "acme/widgets",
                str(self.widgets),
                "0",
                "record-only",
                str(self.units),
                str(self.root / "queued.flock"),
            ],
            env={
                "HOME": str(self.home),
                "PATH": os.pathsep.join(
                    [str(self.fake_service_manager()), os.environ.get("PATH", "")]
                ),
                "KANBAN_FAKE_MANAGER_LOG": str(self.root / "queued.manager"),
            },
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(process.kill)
        self.process = process
        self.wait_for(self.ready, "the queued writer never bound its paths")
        return process

    def wait_for(self, path, message):
        deadline = time.monotonic() + 30
        while not path.exists() and time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.fail(f"{message}: {self.process.communicate()}")
            time.sleep(0.02)
        self.assertTrue(path.exists(), message)

    def relocate_with_queued_writer(self):
        """Release it at the very start of the transition and observe it near
        the end.

        Released before the destination record is written, because from the
        instant that file exists the writer's own resolver already answers the
        destination and it refuses where it stands instead of queuing — a
        narrower window than the lock alone, and not the one under test here.
        Observed inside the removal, by which point the lock has been held
        across the moves and the definition rewrites.
        """
        process = self.start_writer()
        real_apply = install_drainer._apply_relocation
        real_remove = install_drainer._remove_legacy_installation

        def apply_hook(transition, relocation_plan, sources):
            self.go.write_text("", encoding="utf-8")
            self.wait_for(self.queued, "the queued writer never reached the lock")
            # It is between writing that file and blocking in `flock`; a
            # moment here is what puts it there rather than racing it.
            time.sleep(0.25)
            return real_apply(transition, relocation_plan, sources)

        def remove_hook(transition, relocation_plan):
            # It cannot have the lock: this run holds it, never unlinks it, and
            # has closed it against every other opener. If it does, neither the
            # closure nor `flock` excluded this writer at all.
            self.excluded = not self.acquired.exists()
            return real_remove(transition, relocation_plan)

        with mock.patch.object(install_drainer, "_apply_relocation", apply_hook):
            with mock.patch.object(
                install_drainer, "_remove_legacy_installation", remove_hook
            ):
                result = self.relocate()
        self.assertEqual(process.wait(timeout=60), 0, process.communicate())
        return result, json.loads(self.result.read_text(encoding="utf-8"))

    def test_it_never_takes_the_lock_and_records_nothing(self):
        before_record = self.legacy_record
        _, outcome = self.relocate_with_queued_writer()
        # It really was the stale, legacy-bound process this is about...
        self.assertEqual(outcome["bound_record"], str(before_record))
        # ...it never held the lock while this run was inside the transition...
        self.assertTrue(self.excluded, outcome)
        # ...and it was refused by the file rather than by anything in it, so
        # it never queued and never woke into a location that had moved.
        self.assertFalse(self.acquired.exists())
        self.assertNotIn("recorded", outcome)
        self.assertIn("Refusing unsafe config lock path", outcome["refused"])
        self.assertIn(str(self.legacy_lock), outcome["refused"])
        self.assert_location_is_sealed()

    def test_the_run_it_woke_into_needed_no_reconciliation(self):
        result, _ = self.relocate_with_queued_writer()
        # Nothing came back, so nothing was carried and nothing is retained:
        # the refusal is what kept the sweep from having anything to do.
        self.assertTrue(result["late_writes"]["resolved"])
        self.assertEqual(result["late_writes"]["passes"], 0)
        self.assertEqual(
            sorted(path.name for path in self.legacy_dir.iterdir()),
            ["config.json", "config.json.lock", "relocated.json", "runtime"],
        )


def _function_source(source, name):
    """The whole `def <name>(...)` block, from its own line to the blank lines
    that end it.

    Sliced by name rather than parsed, so a rename fails here loudly instead of
    quietly leaving the definition this fixture is about in place.
    """
    start = source.index(f"\ndef {name}(") + 1
    return source[start : source.index("\n\n\n", start) + 1]


# Every protection this arc put *inside* the controller, by the issue that
# added it and the definition an installed copy predating that issue has
# instead. Whole definitions rather than fragments, because a copy that had
# only the two write-level wrappers taken out still contains the refusal those
# wrappers raise and the gate every other transition enters — so it is not a
# controller predating #367 at all, and any protection added beside them would
# survive inside the copy this fixture calls old.
_PRE_GATE_STUBS = (
    (
        "#367",
        "the refusal that answers an installation this process's paths no "
        "longer describe",
        "require_current_installation",
        "def require_current_installation() -> None:\n    return None\n",
    ),
    (
        "#367",
        "the gate every transition enters, which asks that refusal on either "
        "side of the discovery record's lock",
        "installation_transaction",
        "def installation_transaction() -> Iterator[None]:\n"
        "    with document_lock(DISCOVERY_RECORD_PATH):\n"
        "        yield\n",
    ),
)

# What this arc changed *inside* existing definitions rather than by adding
# one, by the issue that changed it and what stood there before. Fragments
# rather than whole definitions, because that is what these are.
_PRE_GATE_FRAGMENTS = (
    (
        "#367",
        "the staleness gate held across each of the two discovery-record writes",
        "    with installation_transaction():\n        return update_json_document(",
        "    return update_json_document(",
        2,
    ),
    (
        "#367",
        "the up-front gate it gave a stop, which a copy predating it does not "
        "enter at all before reading its snapshot",
        "    with installation_transaction():\n        pass\n"
        "    snapshot = status_snapshot(job)",
        "    snapshot = status_snapshot(job)",
        1,
    ),
    (
        "#390",
        "the exit code a refused run answers with, which this arc changed from "
        "a clean one to a failure",
        '        print(f"PR drainer did not start: {exc}", flush=True)\n'
        "        return 1",
        '        print(f"PR drainer did not start: {exc}", flush=True)\n'
        "        return 0",
        1,
    ),
)

# The bounds this arc did *not* put inside the controller, by the issue that
# established each and the code an old copy meets it at. #369 seals the
# discovery record path and #390 seals the runtime root, and both are
# filesystem objects the installer leaves: what refuses them is code that
# predates this repository's whole relocation arc. Each function below is
# asserted to come out of the transformation byte-identical to the shipped one
# and to mention nothing relocation-aware, so "this copy lacks that issue's
# protection" is checked rather than assumed — and a controller-resident gate
# added at one of them later fails here instead of silently reappearing inside
# the copy this fixture calls old.
_PRE_GATE_EXTERNAL = (
    (
        "#369",
        "the discovery record's seal is an installer artifact; what refuses it "
        "is the historical check on the record path's own object type",
        "update_json_document",
        ("Refusing unsafe config path",),
    ),
    (
        "#390",
        "the runtime root's guard is an installer artifact too; what refuses it "
        "is a directory creation that cannot succeed beneath a path that is "
        "not a directory",
        "ensure_dirs",
        (),
    ),
)

# What none of the code above may mention. Every one of those functions
# predates this arc, so a relocation-aware refusal appearing in one is a
# controller-resident bound this fixture would have to account for.
_PRE_GATE_FORBIDDEN = (
    "relocation_marker",
    "require_current_installation",
    "installation_transaction",
    "resolved_installation_drift",
    "RELOCATION_MARKER",
)


class PreGateControllerFixture(RelocationFixture):
    """A copy of the controller predating every gate in this repository.

    A host with a `~/Library` installation is running the controller it
    installed, from before this arc — that is the premise of the relocation
    itself — so no edit to *this* copy makes that process refuse anything. The
    copy is built from the current source by a transformation that is accounted
    for per issue, rather than checked in, so it cannot drift away from what
    the controller actually is; what it may not do is leave a protection in
    place and still be called old.
    """

    def setUp(self):
        super().setUp()
        self.pre_gate = self.build_pre_gate_controller()

    def build_pre_gate_controller(self):
        current = Path(drain_prs_service.__file__).read_text(encoding="utf-8")
        source = current
        for issue, described, name, stub in _PRE_GATE_STUBS:
            existing = _function_source(source, name)
            self.assertNotEqual(
                existing, stub, f"{issue}: {described} is already a stub"
            )
            source = source.replace(existing, stub)
            self.assertNotIn(existing, source, f"{issue}: {described} survived")
        for issue, described, before, after, count in _PRE_GATE_FRAGMENTS:
            self.assertEqual(
                source.count(before), count, f"{issue}: {described} moved"
            )
            source = source.replace(before, after)
        for issue, described, name, required in _PRE_GATE_EXTERNAL:
            shipped = _function_source(current, name)
            self.assertEqual(
                _function_source(source, name), shipped, f"{issue}: {described}"
            )
            for fragment in required:
                self.assertIn(fragment, shipped, f"{issue}: {described}")
            for fragment in _PRE_GATE_FORBIDDEN:
                self.assertNotIn(fragment, shipped, f"{issue}: {described}")
        directory = self.root / "pre-gate-controller"
        directory.mkdir()
        (directory / "drain_prs_service.py").write_text(source, encoding="utf-8")
        return directory

    def controller_path(self):
        """Its own copy first and the tracked modules behind it, so a
        subprocess really runs the older controller while resolving paths
        through the same `kanban_config` every other component does."""
        return os.pathsep.join(
            [str(self.pre_gate), str(Path(drain_prs_service.__file__).parent)]
        )

    def wait_for(self, path, message):
        deadline = time.monotonic() + 30
        while not path.exists() and time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.fail(f"{message}: {self.process.communicate()}")
            time.sleep(0.02)
        self.assertTrue(path.exists(), message)


# What the pre-gate writer below runs. Identical to the queued writer above
# except for the copy of the controller it imports, so the only thing that
# differs between the two cases is whether that copy refuses.
_PRE_GATE_WRITER = _QUEUED_WRITER


class PreGateWriterTests(PreGateControllerFixture):
    """The writer no gate in this copy can refuse: an older installed
    controller.

    Nothing in that copy refuses anything, so what refuses it has to be
    something it cannot argue with. While a relocation is under way that is the
    lock file itself, closed against every opener but the run's, which
    `document_lock` meets before any transition reads or writes a thing. Once
    the run is over it is the seals at the record path and the runtime root,
    which `update_json_document` and `ensure_dirs` meet on exactly the same
    terms.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.ready = self.root / "pre-gate.ready"
        self.go = self.root / "pre-gate.go"
        self.queued = self.root / "pre-gate.queued"
        self.acquired = self.root / "pre-gate.acquired"
        self.result = self.root / "pre-gate.result"
        self.flock_go = self.root / "pre-gate.flock"
        self.manager_log = self.root / "pre-gate.manager"
        self.writer_script = self.root / "pre_gate_writer.py"
        self.writer_script.write_text(_PRE_GATE_WRITER, encoding="utf-8")
        self.writes = "record-only"
        self.repository = "acme/widgets"
        self.checkout = self.widgets

    def start_writer(self):
        process = subprocess.Popen(
            [
                sys.executable,
                str(self.writer_script),
                self.controller_path(),
                str(self.ready),
                str(self.go),
                str(self.queued),
                str(self.acquired),
                str(self.result),
                self.repository,
                str(self.checkout),
                # Held past the write, so the reconciliation's first pass
                # blocks on this process once the handoff gives it the lock.
                "0.4",
                self.writes,
                str(self.units),
                str(self.flock_go),
            ],
            env={
                "HOME": str(self.home),
                "PATH": os.pathsep.join(
                    [str(self.fake_service_manager()), os.environ.get("PATH", "")]
                ),
                "KANBAN_FAKE_MANAGER_LOG": str(self.manager_log),
                # The install directory and the discovery record are *probed*,
                # so this process resolves the `~/Library` ones on any host
                # simply by importing before the destination record exists. The
                # log root is not: it is single-valued per platform, so a
                # subprocess on a Linux host would resolve the XDG one and
                # write its logs at the destination rather than at the location
                # a pre-XDG controller wrote them. Pointing `$XDG_STATE_HOME`
                # at the `~/Library` log root is what makes this process
                # resolve what such a controller hardcoded, identically on
                # either platform.
                "XDG_STATE_HOME": str(self.legacy_logs.parent.parent),
            },
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(process.kill)
        self.process = process
        self.wait_for(self.ready, "the pre-gate writer never bound its paths")
        return process

    def relocate_with_pre_gate_writer(self):
        """Nothing here sequences the writer against the reconciliation.

        The only thing this arranges is that the writer is queued on the lock
        before the transition takes it, which is the interleaving under test;
        which of the two gets that lock afterwards is left to the handoff the
        reconciliation performs, exactly as it is on a real host.
        """
        process = self.start_writer()
        real_apply = install_drainer._apply_relocation

        def apply_hook(transition, relocation_plan, sources):
            self.go.write_text("", encoding="utf-8")
            self.wait_for(self.queued, "the pre-gate writer never reached the lock")
            time.sleep(0.25)
            return real_apply(transition, relocation_plan, sources)

        with mock.patch.object(install_drainer, "_apply_relocation", apply_hook):
            result = self.relocate()
        self.assertEqual(process.wait(timeout=60), 0, process.communicate())
        return result, json.loads(self.result.read_text(encoding="utf-8"))

    def test_it_never_gets_the_lock_and_records_nothing(self):
        """What the closed lock does to the writer no gate can refuse.

        It is refused where it stands, before it queues — so it never wakes
        into a location that moved while it waited, which is the whole state a
        bounded sweep used to have to answer for.
        """
        result, outcome = self.relocate_with_pre_gate_writer()
        self.assertEqual(outcome["bound_record"], str(self.legacy_record))
        self.assertFalse(self.acquired.exists())
        self.assertNotIn("recorded", outcome)
        self.assertIn("Refusing unsafe config lock path", outcome["refused"])
        self.assertIn(str(self.legacy_lock), outcome["refused"])
        self.assertEqual(result["late_writes"]["passes"], 0)

    def test_the_location_is_never_recreated_so_nothing_is_carried(self):
        result, _ = self.relocate_with_pre_gate_writer()
        late = result["late_writes"]
        self.assertTrue(late["resolved"])
        self.assertEqual(late["passes"], 0)
        self.assertEqual(late["repositories"], [])
        self.assert_location_is_sealed()
        self.assertEqual(
            sorted(path.name for path in self.legacy_dir.iterdir()),
            ["config.json", "config.json.lock", "relocated.json", "runtime"],
        )
        # And the record this run wrote is the destination's, describing the
        # repository it moved rather than anything a writer put back.
        entry = self.record_document(self.destination_record)["repositories"][
            "acme/widgets"
        ]
        self.assertEqual(entry["repository"], str(self.widgets))

    def test_the_install_reports_success_because_nothing_was_left_behind(self):
        result, _ = self.relocate_with_pre_gate_writer()
        install_drainer._require_relocation_resolved(result)
        self.assertIn("Nothing to repair", result["repair"])

    def test_a_writer_that_beats_the_final_look_is_refused_where_it_stands(self):
        """The case no lock can reach, answered by leaving nothing to write.

        This writer asks for the lock only once the run is over — past the
        final scan, past the pause, past the bound, and past anything a process
        that has returned could observe. What stops it is not timing: the run
        that emptied this location left the lock unopenable and the record path
        occupied by a seal, and `document_lock` and `update_json_document` have
        refused an unopenable lock and a present-but-not-a-regular-file record
        path respectively since the commit that introduced the record. So every
        copy of the controller old enough to write one refuses this, and this
        one never even acquires the lock.
        """
        process = self.start_writer()
        first = self.relocate()
        self.assertTrue(first["late_writes"]["resolved"])
        self.assertEqual(first["late_writes"]["passes"], 0)
        self.assertTrue(first["late_writes"]["sealed"])
        # Only now, with nothing holding the lock and the run over.
        self.go.write_text("", encoding="utf-8")
        self.assertEqual(process.wait(timeout=60), 0, process.communicate())
        outcome = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertFalse(self.acquired.exists())
        self.assertNotIn("recorded", outcome)
        self.assertIn("Refusing unsafe config lock path", outcome["refused"])
        self.assertIn(str(self.legacy_lock), outcome["refused"])
        self.assert_location_is_sealed()

    def test_the_trees_it_would_lay_down_first_are_refused_too(self):
        """What the record seal alone does not close, and what does close it.

        A controller bound to the old location writes its directories, its
        status file, its incidents, its logs and its definition before it ever
        reaches the record — every one of them under no record lock at all — so
        the record seal refuses only the last of those. The guard the same run
        leaves at the runtime root refuses the first: `ensure_dirs` is the one
        helper all of them go through, and it cannot make a directory beneath a
        path that is not one. `StaleInvocationBoundTests` below asks this of
        every writer separately; this asks it of the writer that also holds the
        record's lock, so nothing about the ordering of the two seals is
        assumed.
        """
        self.writes = "trees"
        process = self.start_writer()
        first = self.relocate()
        self.assertTrue(first["late_writes"]["sealed"])
        self.go.write_text("", encoding="utf-8")
        before = self.host_state()
        self.assertEqual(process.wait(timeout=60), 0, process.communicate())
        outcome = json.loads(self.result.read_text(encoding="utf-8"))
        runtime = self.legacy_dir / "runtime" / self.job.slug
        logs = self.legacy_logs / self.job.slug
        # Named by the writer itself, so a host that resolved either of them
        # somewhere else fails here rather than through a missing file.
        self.assertEqual(outcome["runtime"], str(runtime))
        self.assertEqual(outcome["logs"], str(logs))
        # It got no further than the runtime root, and it says so by naming it.
        self.assertIn(str(self.legacy_guard), outcome["trees_refused"])
        self.assertFalse(runtime.exists())
        self.assertFalse(logs.exists())
        # The record it could not reach either, and nothing at all changed.
        self.assertIn("Refusing unsafe config lock path", outcome["refused"])
        self.assert_location_is_sealed()
        self.assertEqual(self.host_state(), before)
        # A later run therefore has nothing to find: the location really is
        # finished business rather than merely sealed.
        self.assertIn(
            "emptied and sealed",
            install_drainer.relocation_disposition(self.destination),
        )

    def test_a_queued_uninstall_never_reaches_the_definition_at_all(self):
        """The transition no seal can stand in front of, prevented anyway.

        An uninstall creates no directory: it reads the status file, unloads
        the job and unlinks the definition, and only then reaches the record
        the seal refuses. Neither the runtime guard nor the record seal is in
        front of that definition, and nothing can be — a service manager's
        definition directory is the installation's own, shared with the job
        this run has just relocated, so closing it would close the
        installation.

        What is in front of it is the lock. Every transition enters
        `document_lock` before it reads or writes a thing, and while this run
        is under way that file is closed against every opener but its own — so
        the uninstall never begins, and the definition it would have taken is
        never reached rather than put back afterwards.
        """
        self.writes = "uninstall"
        self.commands.clear()
        result, outcome = self.relocate_with_pre_gate_writer()
        self.assertFalse(self.acquired.exists())
        self.assertNotIn("uninstalled", outcome)
        self.assertIn("Refusing unsafe config lock path", outcome["refused"])
        # Untouched rather than restored: nothing was put back because nothing
        # took it, and the manager was never asked to forget it.
        backend = install_drainer.service_backend()
        self.assertTrue(backend.definition_path(self.job.label).is_file())
        self.assertEqual(result["late_writes"]["restored_definitions"], [])
        self.assertEqual(
            backend.definition_environment(self.job.label)[
                kanban_config.DRAINER_INSTALL_DIR_ENV
            ],
            str(self.destination),
        )
        self.assertTrue(result["late_writes"]["sealed"])
        self.assert_location_is_sealed()
        install_drainer._require_relocation_resolved(result)

    def test_a_sealed_location_holding_nothing_is_left_alone(self):
        self.relocate()
        self.assertIn(
            "emptied and sealed",
            install_drainer.relocation_disposition(self.destination),
        )

    def test_the_copy_it_runs_lacks_every_protection_this_arc_added(self):
        """Issue #390 requirement 8, asked of the copy from outside.

        `build_pre_gate_controller` asserts all of this while it builds that
        copy — that #367's controller-resident gates really came out, that
        #369's and #390's bounds are not in the controller at all, and that the
        code an old copy meets those two at is byte-identical here. This asks
        the built copy the same questions afterwards, so a transformation that
        quietly stopped transforming shows up as a failing test rather than as
        a second test of the gated path.
        """
        source = (self.pre_gate / "drain_prs_service.py").read_text(encoding="utf-8")
        for issue, described, _name, stub in _PRE_GATE_STUBS:
            self.assertIn(stub, source, f"{issue}: {described}")
        for issue, described, before, after, _count in _PRE_GATE_FRAGMENTS:
            self.assertNotIn(before, source, f"{issue}: {described}")
            self.assertIn(after, source, f"{issue}: {described}")
        for issue, described, name, required in _PRE_GATE_EXTERNAL:
            body = _function_source(source, name)
            self.assertEqual(
                body,
                _function_source(
                    Path(drain_prs_service.__file__).read_text(encoding="utf-8"), name
                ),
                f"{issue}: {described}",
            )
            for fragment in required:
                self.assertIn(fragment, body, f"{issue}: {described}")
            for fragment in _PRE_GATE_FORBIDDEN:
                self.assertNotIn(fragment, body, f"{issue}: {described}")


# What the stale invocation below runs: the same pre-gate controller, bound to
# the legacy installation before the relocation and released only once that run
# has sealed the location it emptied. A real second process, because a
# controller's managed paths are constants frozen at its own import and nothing
# driven from the relocating thread can be that process.
#
# It drives each writer separately and records what each one did, because they
# do not all reach the installation the same way: `install`, `start`, `stop`
# and `uninstall` enter a transaction, and `uninstall` in particular unloads
# and unlinks the definition without ever creating a directory; `service_log`
# and `write_incident` reach the runtime, incident and log trees through
# `ensure_dirs` on their own; and `atomic_write_json` creates a missing parent
# without either. A bound proven only through the install path would leave
# every one of the others unproven. Then it runs the controller's own entry
# point, which is what an operator really invokes and what renders the failure
# they really see.
#
# Twice, in one process. `ensure_dirs` chmods the install directory on every
# attempt before it touches anything else, so a bound that lived in that
# directory's mode would be reset by the very invocation it stops; and a
# *fresh* process is not the case under test at all, since discovery probes the
# XDG location first and one started after the relocation resolves the
# destination.
_STALE_INVOCATION = """
import contextlib, io, json, os, sys, time
from pathlib import Path

# Before anything resolves a managed path. The platform decides the log root,
# which is single-valued rather than probed, so a subprocess that read the real
# host's answer would resolve a different root on a macOS laptop than on a
# Linux runner. This is the platform the fixture relocates on.
sys.platform = "linux"

for entry in reversed(sys.argv[1].split(os.pathsep)):
    sys.path.insert(0, entry)
ready, go, result = (Path(argument) for argument in sys.argv[2:5])
checkout = Path(sys.argv[5])
units = Path(sys.argv[6])

import drain_prs_service
import service_manager

# Fixture wiring rather than a protection. Which manager this host has is
# settled by `tools/test_service_manager.py`, and where that manager keeps its
# definitions has to be the directory the parent process reads, or the two
# would compare different files.
service_manager._DETECTED = service_manager.SYSTEMD
service_manager.SYSTEMD_USER_DIR = units

# The two checkout preflights `start_service` runs before it reaches the
# installation at all. Neither is anything this arc added, and this fixture's
# checkouts have no commits, so leaving them in would fail that start for a
# reason with nothing to do with the bound under test.
drain_prs_service.require_no_operation_in_progress = lambda repo: None
drain_prs_service.require_default_branch = lambda repo, remote: None

# Bound here, while the legacy record is still the one this host resolves.
ready.write_text(str(drain_prs_service.DISCOVERY_RECORD_PATH), encoding="utf-8")
while not go.exists():
    time.sleep(0.01)

job = drain_prs_service.resolve_job(checkout)


def battery():
    attempts = {}
    for name, action in (
        ("install", lambda: drain_prs_service.install_job(job)),
        ("start", lambda: drain_prs_service.start_service(job)),
        # The one no directory creation reaches: `uninstall_job` never calls
        # `ensure_dirs`, and it unloads and unlinks the definition before its
        # record write is refused. Only the closed lock stops it.
        ("uninstall", lambda: drain_prs_service.uninstall_job(job)),
        ("stop", lambda: drain_prs_service.stop_service(job)),
        ("service_log", lambda: drain_prs_service.service_log(job, "stale start")),
        (
            "write_incident",
            lambda: drain_prs_service.write_incident(
                job=job,
                exit_code=9,
                command=["drain_prs.py", "--path", str(checkout)],
            ),
        ),
        (
            "atomic_write_json",
            lambda: drain_prs_service.atomic_write_json(
                job.status_path, {"state": "starting", "repository": job.identity}
            ),
        ),
        # The one that reports rather than raises: the service manager's own
        # entry point catches its refusal and answers with an exit code, so
        # what this records for it is that code.
        ("run", lambda: drain_prs_service.run_service(job, job.identity)),
    ):
        printed = io.StringIO()
        try:
            with contextlib.redirect_stdout(printed):
                returned = action()
        except BaseException as error:
            attempts[name] = {
                "failed": f"{type(error).__name__}: {error}",
                "returned": None,
                "printed": printed.getvalue(),
            }
        else:
            attempts[name] = {
                "failed": None,
                "returned": returned,
                "printed": printed.getvalue(),
            }
    argv = ["drain_prs_service.py", "--path", str(checkout), "install"]
    stderr = io.StringIO()
    saved = sys.argv
    sys.argv = argv
    try:
        with contextlib.redirect_stderr(stderr):
            with contextlib.redirect_stdout(io.StringIO()):
                code = drain_prs_service.main()
    finally:
        sys.argv = saved
    return {"writers": attempts, "exit_code": code, "stderr": stderr.getvalue()}


result.write_text(
    json.dumps(
        {
            "bound_record": str(drain_prs_service.DISCOVERY_RECORD_PATH),
            "install_dir": str(drain_prs_service.INSTALL_DIR),
            "runtime": str(job.runtime_dir),
            "logs": str(job.log_dir),
            "definition": str(job.definition_path),
            "attempts": [battery(), battery()],
        }
    ),
    encoding="utf-8",
)
"""


class StaleInvocationFixture(PreGateControllerFixture):
    """A stale invocation of that controller, after the relocation sealed the
    location it was bound to.

    The ordering is the load-bearing part and is arranged rather than raced:
    the process binds its managed paths before anything moves, and is released
    only once `relocate` has returned and the emptied location is sealed. That
    is precisely the writer no lock and no pause can reach — past the final
    scan, past the handoff, past the bound, and past anything a process that
    has returned could observe.
    """

    # Whether this process's log root is the `~/Library` one a pre-XDG copy
    # hardcoded, or the single-valued one this platform resolves — which after
    # the relocation is the destination's. Requirement 3 of #390 names both.
    legacy_log_binding = True

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.ready = self.root / "stale.ready"
        self.go = self.root / "stale.go"
        self.result = self.root / "stale.result"
        self.manager_log = self.root / "stale.manager"
        script = self.root / "stale_invocation.py"
        script.write_text(_STALE_INVOCATION, encoding="utf-8")
        environment = {
            "HOME": str(self.home),
            "PATH": os.pathsep.join(
                [str(self.fake_service_manager()), os.environ.get("PATH", "")]
            ),
            "KANBAN_FAKE_MANAGER_LOG": str(self.manager_log),
        }
        if self.legacy_log_binding:
            environment["XDG_STATE_HOME"] = str(self.legacy_logs.parent.parent)
        self.process = subprocess.Popen(
            [
                sys.executable,
                str(script),
                self.controller_path(),
                str(self.ready),
                str(self.go),
                str(self.result),
                str(self.widgets),
                str(self.units),
            ],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.process.kill)
        self.wait_for(self.ready, "the stale controller never bound its paths")
        self.assertEqual(
            self.ready.read_text(encoding="utf-8"), str(self.legacy_record)
        )
        self.assertTrue(self.relocate()["relocated"])
        self.assert_location_is_sealed()
        # Taken with the relocation finished and that process still holding the
        # bindings it started with: this is the "immediately before the stale
        # invocation" every comparison below is against.
        self.before = self.host_state()
        self.go.write_text("", encoding="utf-8")
        self.assertEqual(
            self.process.wait(timeout=120), 0, self.process.communicate()
        )
        self.outcome = json.loads(self.result.read_text(encoding="utf-8"))

    def state_under(self, state, root):
        return {
            path: value for path, value in state.items() if path.startswith(str(root))
        }

    # Which closed path each writer meets. A transition enters `document_lock`
    # before it reads or writes anything at all, so it meets the retained lock;
    # a writer that creates its own directories meets the runtime guard.
    TRANSACTIONAL = frozenset({"install", "start", "uninstall", "run"})

    def closed_path(self, writer):
        return self.legacy_lock if writer in self.TRANSACTIONAL else self.legacy_guard

    # The writers that do not raise, and why each does not.
    #
    # `run_service` is what a service manager launches, so it catches its own
    # startup refusals and answers with an exit code — and a copy predating
    # this arc answers a clean one, which is its own handling of an exception
    # it already caught and not something any bound outside that process
    # reaches.
    #
    # `stop_service` in a copy predating #367 enters no transaction at all: it
    # reads its snapshot and returns straight away when nothing is running.
    # Nothing it does on that branch touches a bound, and nothing may: it is a
    # read that changes no protected artifact and asks the service manager for
    # nothing. What makes that branch the only one it can take here is the
    # runtime guard — the status file it would have read is under a path that
    # is not a directory, so the snapshot is `stopped` however the drainer
    # ended.
    REPORTING = frozenset({"run", "stop"})

    # What a stale invocation may ask the service manager for. Reading is
    # allowed and unavoidable — `status_snapshot` asks whether a unit is
    # loaded, which reaches nothing this run protects — while loading,
    # unloading and signalling are exactly what may not happen, because those
    # change what the manager holds.
    MANAGER_READS = frozenset({"show", "is-enabled", "is-active", "list-unit-files"})

    def manager_commands(self):
        if not self.manager_log.exists():
            return []
        return [
            line.strip()
            for line in self.manager_log.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def assert_the_manager_was_only_read(self):
        """Nothing this invocation sent the manager changes what it holds.

        Asked as an allowlist rather than a list of forbidden verbs: a
        subcommand nobody here anticipated is one this cannot vouch for, and
        `is-enabled` contains `enable`, so matching on fragments would answer
        the wrong question in both directions.
        """
        for line in self.manager_commands():
            verb = next((word for word in line.split() if not word.startswith("-")), "")
            self.assertIn(verb, self.MANAGER_READS, line)

    def refusal(self, writer):
        """What one writer said about refusing, however it said it."""
        return writer["failed"] or writer["printed"]

    def assert_every_writer_failed(self):
        for index, attempt in enumerate(self.outcome["attempts"]):
            for name, writer in attempt["writers"].items():
                if name in self.REPORTING:
                    continue
                self.assertIsNotNone(writer["failed"], (index, name))
            self.assertEqual(attempt["exit_code"], 1, index)


class StaleInvocationBoundTests(StaleInvocationFixture):
    """Issue #390 requirement 3: what such an invocation may leave behind.

    Nothing. Every writer it reaches goes through `ensure_dirs`, which reaches
    the runtime root before the log tree and before the definition is written
    or the record is touched, and the guard the relocation left there is not a
    directory — so the invocation returns non-success before it creates,
    removes or modifies any of them.
    """

    def test_it_really_is_bound_to_the_legacy_installation(self):
        self.assertEqual(self.outcome["bound_record"], str(self.legacy_record))
        self.assertEqual(self.outcome["install_dir"], str(self.legacy_dir))
        self.assertEqual(
            self.outcome["runtime"], str(self.legacy_dir / "runtime" / self.job.slug)
        )
        self.assertEqual(self.outcome["logs"], str(self.legacy_logs / self.job.slug))
        # And at the same definition file the relocation just rewrote, so
        # "unchanged" below is a comparison of the same bytes rather than of
        # two files that never met.
        self.assertEqual(
            self.outcome["definition"],
            str(
                install_drainer.service_backend().definition_path(self.job.label)
            ),
        )

    def test_every_writer_it_reaches_returns_non_success(self):
        self.assert_every_writer_failed()
        # Each of them stopped at a closed path rather than somewhere later,
        # and says which one by naming it.
        for attempt in self.outcome["attempts"]:
            for name, writer in attempt["writers"].items():
                if name == "stop":
                    # The one that meets no bound at all, by taking a branch
                    # that reads and returns; `test_the_stop_...` below is
                    # where that is asserted.
                    continue
                self.assertIn(str(self.closed_path(name)), self.refusal(writer), name)

    def test_the_uninstall_no_directory_creation_reaches_is_bounded_too(self):
        """The path the runtime guard alone leaves open.

        `uninstall_job` never calls `ensure_dirs`: it reads the status file,
        unloads the job from the service manager and unlinks the definition,
        and only then reaches the record write the seal refuses. What stops it
        before any of that is the retained lock its transaction opens first.
        """
        definition = install_drainer.service_backend().definition_path(self.job.label)
        for attempt in self.outcome["attempts"]:
            failure = attempt["writers"]["uninstall"]["failed"]
            self.assertIn("Refusing unsafe config lock path", failure)
            self.assertIn(str(self.legacy_lock), failure)
        self.assertTrue(definition.is_file())
        self.assertEqual(definition.read_bytes(), self.before[str(definition)][1])
        self.assert_the_manager_was_only_read()

    def test_the_stop_a_copy_predating_this_arc_runs_is_an_unchanged_no_op(self):
        """The one transition that meets no bound, and may not have to.

        A `stop_service` predating #367 enters no transaction: it reads its
        snapshot and, finding nothing running, returns its "already stopped"
        result. That branch reaches no closed path because it asks for nothing
        — no lock, no directory, no record — so there is nothing for a bound to
        refuse, and requiring non-success of it would be requiring a filesystem
        object to change what a read does.

        It is also the only branch such a stop can take here. The status file
        it reads is under the sealed runtime root, so the snapshot is `stopped`
        whatever the drainer was doing, and a relocation refuses outright while
        any managed job or checkout drainer is running — so the signalling
        branch, which would ask the service manager for something, is not
        reachable from a location a run has emptied.
        """
        for index, attempt in enumerate(self.outcome["attempts"]):
            stop = attempt["writers"]["stop"]
            self.assertIsNone(stop["failed"], index)
            self.assertEqual(stop["returned"]["stopped"], False, index)
            self.assertIn("already stopped", stop["returned"]["message"])
        # And the whole of what that permits: it changed nothing anywhere, and
        # asked the service manager nothing that changes what it holds.
        self.assertEqual(self.host_state(), self.before)
        self.assert_the_manager_was_only_read()

    def test_the_run_a_copy_predating_this_arc_reports_but_cannot_fail(self):
        """The one invocation whose non-success no bound can produce.

        `run_service` is what a service manager launches, so it catches its own
        startup refusals and answers with an exit code rather than raising. A
        controller predating this arc answers a clean one there, and nothing
        outside that process changes what it does with an exception it already
        caught — the same limit requirement 4 is stated around, where the prose
        an operator needs cannot come from the stale process either. This
        fixture restores that answer rather than inheriting the failing exit
        this arc added, or the copy it calls old would be proving something
        only a current controller does.

        What is reachable is everything else, and it is the substance: this run
        refuses at the closed lock, names it, and writes nothing at all.
        `StaleControllerTests` asserts the failing exit a controller from here
        on gives instead.
        """
        for index, attempt in enumerate(self.outcome["attempts"]):
            run = attempt["writers"]["run"]
            self.assertIsNone(run["failed"], index)
            self.assertEqual(run["returned"], 0, index)
            self.assertIn("PR drainer did not start", run["printed"])
            self.assertIn("Refusing unsafe config lock path", run["printed"])
            self.assertIn(str(self.legacy_lock), run["printed"])
        # And nothing it would have written exists, which is the whole of what
        # its exit code cannot carry.
        self.assertEqual(self.host_state(), self.before)

    def test_the_trees_on_both_sides_are_exactly_what_they_were(self):
        after = self.host_state()
        for root in (
            self.legacy_dir / "runtime",
            self.legacy_logs,
            self.destination / "runtime",
            self.destination_logs,
        ):
            self.assertEqual(
                self.state_under(after, root), self.state_under(self.before, root), root
            )
        # And nothing anywhere else moved either.
        self.assertEqual(after, self.before)

    def test_the_definition_and_the_manager_still_hold_the_relocated_one(self):
        definition = install_drainer.service_backend().definition_path(self.job.label)
        self.assertEqual(
            definition.read_bytes(), self.before[str(definition)][1]
        )
        self.assertIn(str(self.destination), definition.read_text(encoding="utf-8"))
        # It never asked the manager to change anything, so what the manager
        # holds is still the definition the relocation loaded.
        self.assert_the_manager_was_only_read()

    def test_the_seals_and_the_notice_beside_them_are_unchanged(self):
        self.assert_location_is_sealed()
        self.assertEqual(
            self.state_under(self.host_state(), self.legacy_dir),
            self.state_under(self.before, self.legacy_dir),
        )
        # Including the mode of the directory itself: `ensure_dirs` chmods it
        # on every attempt, which is exactly why the bound is an object at a
        # path rather than a permission on one.
        self.assertEqual(
            self.legacy_dir.stat().st_mode & 0o777,
            self.before[str(self.legacy_dir)][1],
        )

    def test_the_failure_names_the_guard_and_the_notice_says_what_to_do(self):
        """Requirement 4, met where it can be met.

        The stale process runs bytes predating every gate here, so nothing in
        this repository can put prose in its output: what it prints is its own
        rendering of the fault, which names the path it could not use. That
        path is an artifact this installer owns, and following it is what
        carries the rest — that the installation was relocated, both locations,
        and the action that resolves it.
        """
        for attempt in self.outcome["attempts"]:
            self.assertEqual(attempt["exit_code"], 1)
            self.assertIn("drain_prs_service.py:", attempt["stderr"])
            self.assertIn(str(self.legacy_lock), attempt["stderr"])
        # The lock is the artifact that invocation names, and it is readable:
        # what a transition may not do is open it for writing.
        held = self.legacy_lock.read_text(encoding="utf-8")
        self.assertIn("was relocated to", held)
        self.assertIn(str(self.legacy_dir), held)
        self.assertIn(str(self.destination), held)
        self.assertIn("Run the command again", held)
        self.assertIn("install_drainer.py", held)
        self.assertIn(
            str(self.legacy_dir / drain_prs_service.RELOCATION_MARKER_NAME), held
        )
        # And the runtime guard, which is what the writers no transaction
        # covers name, leads to the same notice through the marker.
        notice = drain_prs_service._read_json_object(self.legacy_guard)
        self.assertEqual(
            notice[drain_prs_service.RELOCATION_MARKER_SOURCE], str(self.legacy_dir)
        )
        self.assertEqual(
            notice[drain_prs_service.RELOCATION_MARKER_DESTINATION],
            str(self.destination),
        )
        prose = " ".join(
            (
                notice[drain_prs_service.RELOCATION_MARKER_NOTICE],
                notice[drain_prs_service.RELOCATION_MARKER_REPAIR],
            )
        )
        self.assertIn("was relocated to", prose)
        self.assertIn(str(self.legacy_dir), prose)
        self.assertIn(str(self.destination), prose)
        self.assertIn("Run the command again", prose)
        self.assertIn("install_drainer.py", prose)

    def test_a_second_invocation_is_refused_identically(self):
        first, second = self.outcome["attempts"]
        self.assertEqual(second, first)


class StaleInvocationDestinationLogTests(StaleInvocationFixture):
    """The same invocation on a process whose log root is the destination's.

    The log root is single-valued per platform rather than probed, so a process
    that resolved it after the platform question changed writes its logs where
    the relocation put them. Requirement 3 names those trees too, and what
    protects them is ordering: `ensure_dirs` reaches the runtime root before
    the log tree, so a guard at the *legacy* runtime root stops a write whose
    log tree is at the destination exactly as it stops one whose log tree is
    beside it.
    """

    legacy_log_binding = False

    def test_its_log_tree_is_the_destinations_and_is_left_alone(self):
        self.assertEqual(
            self.outcome["logs"], str(self.destination_logs / self.job.slug)
        )
        self.assert_every_writer_failed()
        self.assertEqual(
            self.state_under(self.host_state(), self.destination_logs),
            self.state_under(self.before, self.destination_logs),
        )
        self.assertEqual(self.host_state(), self.before)


class UnaccountedIdentityTests(RelocationFixture):
    """Issue #390 requirements 5 to 7: which repository an unrecorded tree
    belongs to, recovered from validated evidence or not claimed at all.

    A tree under the runtime or log root is filed by a slug, and a slug is not
    an identity: `repository_slug` escapes the identity reversibly only while
    the escaped spelling is one this host's service manager can carry as an
    identifier, and falls back to a hash of the whole identity when it is not.
    So the directory name answers "which repository is this?" some of the time
    and the documents the controller wrote inside the tree answer it the rest
    of the time — and where nothing does, the state is kept where it was
    written and named by its slug rather than filed under a guess.

    Every tree here is laid down by the controller's own writers under the
    bindings a process that resolved before the relocation still holds, with
    only its discovery-record write left out. That is exactly what such a
    controller leaves when that one write is refused, and it is what makes
    these trees ones no record names.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.bindings = self.legacy_bindings

    def lay_down_trees(self, checkout):
        return self.write_late(checkout, self.bindings, record=False)

    def relocate_with(self, write):
        with self.racing(write):
            return self.relocate()

    def hashed_repository(self):
        """A repository this host files under a hash rather than a reversible
        slug: the escaped spelling outgrows what the service manager can carry
        as an identifier, so `repository_slug` falls back to a SHA-256 of the
        whole identity and the directory name reverses to nothing at all."""
        identity = "acme/widgets" + "-x" * 100
        checkout = self.make_checkout("hashed", f"git@github.com:{identity}.git")
        slug = drain_prs_service.repository_slug(identity)
        self.assertTrue(slug.startswith("h"), slug)
        return checkout, identity, slug

    def unattributed(self, result):
        return [
            (item["repository"], item["slug"], item["kind"])
            for item in result["late_writes"]["unattributed"]
        ]

    def test_a_reversible_slug_is_reported_as_its_canonical_identity(self):
        gadgets = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        result = self.relocate_with(lambda: self.lay_down_trees(gadgets))
        late = result["late_writes"]
        self.assertTrue(late["resolved"])
        self.assertEqual(late["unattributed"], [])
        # The identity, not the directory the state is filed under.
        self.assertEqual(late["repositories"], ["acme/gadgets"])
        slug = drain_prs_service.repository_slug("acme/gadgets")
        self.assertEqual(slug, "acme.gadgets")
        self.assertTrue(
            (self.destination / "runtime" / slug / "status.json").is_file()
        )
        self.assertTrue((self.destination_logs / slug / "service.log").is_file())
        self.assertFalse((self.legacy_dir / "runtime" / slug).exists())
        # Recovered for the report and the move rather than filed as a job:
        # nothing records where its checkout is or what its definition is
        # called, so the destination record still does not name it.
        self.assertNotIn(
            "acme/gadgets",
            self.record_document(self.destination_record)["repositories"],
        )

    def test_a_hash_only_slug_is_attributed_from_agreeing_evidence(self):
        checkout, identity, slug = self.hashed_repository()
        result = self.relocate_with(lambda: self.lay_down_trees(checkout))
        late = result["late_writes"]
        self.assertTrue(late["resolved"], late["repair"])
        self.assertEqual(late["repositories"], [identity])
        self.assertTrue(
            (self.destination / "runtime" / slug / "status.json").is_file()
        )
        # The log tree carries no document of its own; it is attributed through
        # the runtime tree filed under the exact same slug.
        self.assertTrue((self.destination_logs / slug / "service.log").is_file())

    def test_a_hash_only_slug_with_no_identity_evidence_is_kept_and_named(self):
        checkout, _identity, slug = self.hashed_repository()

        def late():
            self.lay_down_trees(checkout)
            # Its runtime tree is what carried the identity. A log tree that
            # outlived it is filed under a name nothing reverses and says
            # nothing about itself.
            shutil.rmtree(self.legacy_dir / "runtime" / slug)

        result = self.relocate_with(late)
        self.assertFalse(result["late_writes"]["resolved"])
        self.assertEqual(result["late_writes"]["repositories"], [])
        self.assertEqual(self.unattributed(result), [(None, slug, "log")])
        self.assertIn(
            "nothing reverses it", result["late_writes"]["unattributed"][0]["reason"]
        )
        self.assertTrue((self.legacy_logs / slug / "service.log").is_file())

    def test_a_slug_that_does_not_re_encode_to_itself_is_not_authoritative(self):
        # `Other.Repo` decodes to a repository GitHub could name, and this host
        # files that repository under `other.repo` instead — identities are
        # case-folded and the encoding is this host's own — so the name on disk
        # is not this host's name for it and nothing here may claim the state
        # under it.
        def late():
            tree = self.legacy_logs / "Other.Repo"
            tree.mkdir(parents=True)
            (tree / "service.log").write_text("kept\n", encoding="utf-8")

        result = self.relocate_with(late)
        self.assertFalse(result["late_writes"]["resolved"])
        self.assertEqual(self.unattributed(result), [(None, "Other.Repo", "log")])
        self.assertEqual(
            result["late_writes"]["unattributed"][0]["reason"],
            "Other.Repo decodes to other/repo, which this host files under "
            "other.repo, and no status document or incident filed under it "
            "names a repository",
        )
        self.assertTrue((self.legacy_logs / "Other.Repo" / "service.log").is_file())

    def test_conflicting_identities_are_kept_and_named(self):
        gadgets = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        slug = drain_prs_service.repository_slug("acme/gadgets")

        def late():
            self.lay_down_trees(gadgets)
            # Evidence that is present and disagrees, which is the case nothing
            # here may skip past on its way to trusting the directory name.
            (self.legacy_dir / "runtime" / slug / "status.json").write_text(
                json.dumps({"repository": "acme/widgets"}), encoding="utf-8"
            )

        result = self.relocate_with(late)
        self.assertFalse(result["late_writes"]["resolved"])
        self.assertEqual(
            self.unattributed(result),
            [(None, slug, "runtime"), (None, slug, "log")],
        )
        reason = result["late_writes"]["unattributed"][0]["reason"]
        self.assertIn("more than one repository", reason)
        self.assertIn("acme/gadgets", reason)
        self.assertIn("acme/widgets", reason)
        self.assertTrue((self.legacy_dir / "runtime" / slug).is_dir())
        self.assertTrue((self.legacy_logs / slug).is_dir())

    def malformed(self, corrupt):
        """One repository's trees, with its status document corrupted."""
        gadgets = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        slug = drain_prs_service.repository_slug("acme/gadgets")
        status = self.legacy_dir / "runtime" / slug / "status.json"

        def late():
            self.lay_down_trees(gadgets)
            corrupt(status)

        return slug, self.relocate_with(late)

    def assert_malformed(self, corrupt, expected):
        """One shape of "present and broken", told apart from absent.

        The general readers this repository uses answer `None` for a document
        that is missing, unreadable, not an object or not what it should hold,
        which is exactly the collapse requirements 5 and 6 forbid here: absent
        evidence may be supplied by another permitted source, while evidence
        that is there and wrong may not be skipped past.
        """
        slug, result = self.malformed(corrupt)
        self.assertFalse(result["late_writes"]["resolved"])
        self.assertEqual(
            self.unattributed(result),
            [(None, slug, "runtime"), (None, slug, "log")],
        )
        reason = result["late_writes"]["unattributed"][0]["reason"]
        self.assertIn("is malformed", reason)
        self.assertIn(expected, reason)
        # And the tree is where it was written rather than filed anywhere
        # under a guess.
        self.assertTrue((self.legacy_dir / "runtime" / slug).is_dir())

    def test_evidence_that_is_not_a_regular_file_is_malformed(self):
        def corrupt(status):
            status.unlink()
            status.mkdir()

        self.assert_malformed(corrupt, "is not a regular file")

    def test_evidence_that_is_not_a_json_object_is_malformed(self):
        self.assert_malformed(
            lambda status: status.write_text("[]", encoding="utf-8"),
            "is not a JSON object",
        )

    def test_evidence_naming_something_that_is_not_a_repository_is_malformed(self):
        self.assert_malformed(
            lambda status: status.write_text(
                json.dumps({"repository": "not a github repository"}),
                encoding="utf-8",
            ),
            "which is not a GitHub repository",
        )

    def test_evidence_that_cannot_be_read_is_malformed(self):
        self.assert_malformed(
            lambda status: status.write_text("{not a document", encoding="utf-8"),
            "could not be read",
        )

    def test_absent_evidence_is_not_malformed_and_the_slug_carries_it(self):
        """The other half of the same distinction.

        A status document with no `repository` field is one the controller
        wrote before that field existed, or one a fixture left empty. It says
        nothing, which is not the same as saying something wrong: the
        reversible slug beside it is allowed to answer.
        """
        gadgets = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        slug = drain_prs_service.repository_slug("acme/gadgets")

        def late():
            self.lay_down_trees(gadgets)
            (self.legacy_dir / "runtime" / slug / "status.json").write_text(
                "{}", encoding="utf-8"
            )

        result = self.relocate_with(late)
        late_writes = result["late_writes"]
        self.assertTrue(late_writes["resolved"], late_writes["repair"])
        self.assertEqual(late_writes["unattributed"], [])
        self.assertEqual(late_writes["repositories"], ["acme/gadgets"])

    def test_the_repair_and_the_failure_name_the_slug_and_the_reason(self):
        # Requirement 7 as amended: an unattributed entry carries a null
        # repository beside its own slug in the data, and neither the repair
        # nor the failure an operator reads ever renders that null.
        checkout, _identity, slug = self.hashed_repository()

        def late():
            self.lay_down_trees(checkout)
            shutil.rmtree(self.legacy_dir / "runtime" / slug)

        result = self.relocate_with(late)
        repair = result["repair"]
        self.assertIn(slug, repair)
        self.assertIn("nothing reverses it", repair)
        self.assertIn("re-run this installer", repair)
        self.assertNotIn("None", repair)
        with self.assertRaises(install_drainer.RelocationUnresolved) as raised:
            install_drainer._require_relocation_resolved(result)
        message = str(raised.exception)
        self.assertIn(slug, message)
        self.assertIn("could not be attributed to a repository", message)
        self.assertNotIn("None", message)
        # And the structured half keeps them apart.
        entry = result["late_writes"]["unattributed"][0]
        self.assertIsNone(entry["repository"])
        self.assertEqual(entry["slug"], slug)


class LockDescriptorTests(PreGateControllerFixture):
    """The descriptor a lock's mode does not reach, and the two populations it
    comes in.

    `document_lock` opens the lock file and takes its flock together; a process
    that has done the first and not yet the second holds something no later
    mode change revokes. One that holds it when a relocation starts is refused
    before anything moves, which is the only prevention available: with the
    installation still where it was, that process goes on to perform an
    ordinary transition against it. One that opens the lock while the run is
    already under way cannot be refused — the plan is long past — and is
    answered by the settle cycle instead, which reads the set once the mode is
    closed and reports what it cannot prove empty.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.ready = self.root / "pre-gate.ready"
        self.go = self.root / "pre-gate.go"
        self.queued = self.root / "pre-gate.queued"
        self.acquired = self.root / "pre-gate.acquired"
        self.result = self.root / "pre-gate.result"
        self.flock_go = self.root / "pre-gate.flock"
        self.manager_log = self.root / "pre-gate.manager"
        self.writer_script = self.root / "pre_gate_writer.py"
        self.writer_script.write_text(_PRE_GATE_WRITER, encoding="utf-8")

    def start_holder(self, *, visible=True, open_now=True):
        """A pre-gate controller that opens the lock and stops there.

        `document_lock` opens the file and takes its flock together; this
        performs the two halves with a gate between them, which is the only way
        to hold the state under test — a descriptor open, and its flock not
        landed yet.

        `open_now=False` stops it one step earlier, with its managed paths
        bound and the lock not yet open. That is what makes it *stale* for a
        case that has to relocate first: a process started after the
        destination record exists resolves the destination and is an ordinary
        controller, so one that must be bound to the location a later run is
        finishing has to have started before that record did.
        """
        process = subprocess.Popen(
            [
                sys.executable,
                str(self.writer_script),
                self.controller_path(),
                str(self.ready),
                str(self.go),
                str(self.queued),
                str(self.acquired),
                str(self.result),
                "acme/widgets",
                str(self.widgets),
                "0",
                "uninstall-delayed",
                str(self.units),
                str(self.flock_go),
            ],
            env={
                "HOME": str(self.home),
                "PATH": os.pathsep.join(
                    [str(self.fake_service_manager()), os.environ.get("PATH", "")]
                ),
                "KANBAN_FAKE_MANAGER_LOG": str(self.manager_log),
                "XDG_STATE_HOME": str(self.legacy_logs.parent.parent),
            },
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(process.kill)
        self.process = process
        self.wait_for(self.ready, "the holder never bound its paths")
        self.assertEqual(
            self.ready.read_text(encoding="utf-8"), str(self.legacy_record)
        )
        if open_now:
            self.open_lock(process, visible=visible)
        return process

    def open_lock(self, process, *, visible=True):
        """Let it perform the first half of `document_lock` and stop."""
        self.go.write_text("", encoding="utf-8")
        self.wait_for(self.queued, "the holder never opened the lock")
        if visible:
            # It is holding a descriptor now, and this is what a host that can
            # read descriptors answers about it.
            self.lock_holders = (process.pid,)

    def release(self, process):
        self.flock_go.write_text("", encoding="utf-8")
        self.assertEqual(process.wait(timeout=60), 0, process.communicate())

    # -- the population a refusal reaches ----------------------------------

    def test_a_descriptor_open_before_the_run_refuses_it_and_changes_nothing(self):
        """The prevention this issue selects, available in exactly one place.

        Once the installation has moved, every answer left is a repair: nothing
        on the filesystem stops an uninstall from unlinking a definition, since
        a service manager's definition directory is the installation's own. So
        the run does not move it. It refuses, changes nothing, and names what
        to wait for.
        """
        process = self.start_holder()
        before = self.host_state()
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.relocate()
        message = str(raised.exception)
        self.assertIn(str(self.legacy_lock), message)
        self.assertIn(f"process {process.pid}", message)
        self.assertIn("Wait for it to finish or stop it", message)
        self.assertEqual(self.host_state(), before)
        # And because nothing moved, what that process goes on to do is an
        # ordinary uninstall of the installation it was invoked against,
        # serialized by this very lock exactly as it always was — rather than a
        # stale one acting on a location that moved while it waited.
        self.release(process)
        outcome = json.loads(self.result.read_text(encoding="utf-8"))
        self.assertNotIn("refused", outcome)
        self.assertTrue(outcome["uninstalled"]["uninstalled"])

    def test_a_dry_run_refuses_over_it_too(self):
        process = self.start_holder()
        before = self.host_state()
        with self.assertRaises(install_drainer.InstallError) as raised:
            install_drainer.relocation_preview(self.destination)
        self.assertIn(f"process {process.pid}", str(raised.exception))
        self.assertEqual(self.host_state(), before)
        self.release(process)

    def test_a_host_that_cannot_be_asked_refuses_too(self):
        """Absent evidence is not evidence of absence.

        Relocating on an unanswered precondition is worse than not relocating:
        it leaves the host moved and the question still open, which is the one
        state no later run can undo.
        """
        self.lock_holders = None
        self.lock_holders_reason = "open descriptors cannot be read on this host"
        before = self.host_state()
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.relocate()
        message = str(raised.exception)
        self.assertIn("cannot be ruled out", message)
        self.assertIn(str(self.legacy_lock), message)
        self.assertEqual(self.host_state(), before)

    # -- the population no refusal can reach --------------------------------

    def test_nothing_can_open_that_lock_while_the_run_is_under_way(self):
        """The other half, and the half no refusal covers.

        A controller invoked while the relocation is already running is one no
        plan could have seen. What stops it is the file: from the instant this
        run holds that lock it is closed against every other opener, so such a
        process never queues on it and never gets a turn on a location that
        moved while it waited. That is what makes the prevention total rather
        than a race won — and it is why the run may not reopen the file for its
        own later acquisitions, and holds one instead.
        """
        observed = {}
        real = install_drainer._apply_relocation

        def during(transition, relocation_plan, sources):
            # A second descriptor in this process is another opener exactly as
            # a second process's is: the mode is the whole mechanism.
            try:
                descriptor = os.open(self.legacy_lock, os.O_RDWR | os.O_CREAT, 0o600)
            except OSError as error:
                observed["refused"] = f"{type(error).__name__}: {error}"
            else:
                os.close(descriptor)
                observed["refused"] = None
            return real(transition, relocation_plan, sources)

        with mock.patch.object(install_drainer, "_apply_relocation", during):
            self.assertTrue(self.relocate()["relocated"])
        self.assertIsNotNone(observed["refused"])
        self.assertIn(str(self.legacy_lock), observed["refused"])
        # Closed afterwards too, now with the notice in it.
        self.assertFalse(os.access(self.legacy_lock, os.W_OK))
        self.assert_location_is_sealed()

    def test_a_refusal_after_the_closure_leaves_the_lock_as_it_was_found(self):
        """The closure is taken before the run has decided anything, so a
        refusal raised after it has to put the file back — a run that refuses
        changes nothing at all, and a lock left closed by a run that did
        nothing else is a lock nothing can ever take again."""
        before = self.host_state()
        with mock.patch.object(
            install_drainer,
            "_apply_relocation",
            side_effect=install_drainer.InstallError("refused mid-run"),
        ):
            with self.assertRaises(install_drainer.InstallError):
                self.relocate()
        self.assertTrue(os.access(self.legacy_lock, os.W_OK))
        # Everything except the residue a run that got as far as taking a lock
        # always leaves: the destination's own lock file and the directories
        # holding it, which are never unlinked.
        self.assertEqual(
            self.outside_the_destination(self.host_state()),
            self.outside_the_destination(before),
        )
        self.assert_destination_holds_only_its_lock()

    # -- finishing a location an earlier run left open -----------------------

    def test_an_ordinary_host_with_nothing_queued_closes_it(self):
        # Nothing else has this file open, nothing could have opened it while
        # the run held it, so nothing can ever take this lock.
        result = self.relocate()
        self.assertTrue(result["late_writes"]["sealed"])
        self.assertEqual(result["late_writes"]["lock_holders"], [])
        self.assert_location_is_sealed()
        install_drainer._require_relocation_resolved(result)

    def test_the_marker_records_that_closing_finished(self):
        """The durable half of the answer.

        Both seals are objects a later run can see and the lock's mode is a bit
        it can read, but whether this run was in a position to prove nothing
        could still take that lock is a question only this run could ask. So it
        writes its answer down beside the location, in the notice every seal
        already points at.
        """
        marker = self.legacy_dir / drain_prs_service.RELOCATION_MARKER_NAME
        self.assertTrue(self.relocate()["late_writes"]["sealed"])
        document = drain_prs_service._read_json_object(marker)
        self.assertIs(document[drain_prs_service.RELOCATION_MARKER_CLOSED], True)
        self.assertEqual(
            document[drain_prs_service.RELOCATION_MARKER_DESTINATION],
            str(self.destination),
        )
        self.assertIn(
            "was relocated to",
            document[drain_prs_service.RELOCATION_MARKER_NOTICE],
        )

    def unfinished(self):
        """A location an earlier run emptied and sealed without finishing.

        What an installer predating this bound leaves: the seals are down, the
        lock is open because that installer never closed it, and the marker
        says nothing about whether anything could still take it.
        """
        self.assertTrue(self.relocate()["late_writes"]["sealed"])
        marker = self.legacy_dir / drain_prs_service.RELOCATION_MARKER_NAME
        document = drain_prs_service._read_json_object(marker)
        document.pop(drain_prs_service.RELOCATION_MARKER_CLOSED)
        drain_prs_service.atomic_write_json(marker, document)
        self.legacy_lock.chmod(0o600)
        self.assertIsNone(install_drainer.relocation_disposition(self.destination))

    def test_a_marker_that_predates_this_bound_is_not_finished(self):
        self.unfinished()
        again = self.relocate()
        self.assertFalse(again["relocated"])
        self.assertIn("closed it", again["reason"])
        self.assertTrue(again["late_writes"]["sealed"])
        self.assert_location_is_sealed()
        self.assertIn(
            "emptied and sealed",
            install_drainer.relocation_disposition(self.destination),
        )

    def test_finishing_a_location_puts_back_a_definition_that_went_missing(self):
        """Why the finishing run checks definitions at all.

        A location an earlier run could not finish closing is one something may
        have acted on in between: that run left the lock open, so a controller
        bound there could still have taken it and uninstalled. The run that
        finishes the location is the one that puts back what it finds missing.
        """
        self.unfinished()
        backend = install_drainer.service_backend()
        definition = backend.definition_path(self.job.label)
        definition.unlink()
        self.commands.clear()
        again = self.relocate()
        late = again["late_writes"]
        self.assertTrue(late["sealed"])
        self.assertEqual(late["restored_definitions"], ["acme/widgets"])
        self.assertTrue(definition.is_file())
        self.assertEqual(
            backend.definition_environment(self.job.label)[
                kanban_config.DRAINER_INSTALL_DIR_ENV
            ],
            str(self.destination),
        )
        self.assertTrue(
            any(self.job.label in " ".join(command) for command in self.commands),
            self.commands,
        )
        self.assertIn("put it back and reloaded it", again["repair"])
        install_drainer._require_relocation_resolved(again)

    def watch_lock_mode(self):
        """Every change to the legacy lock's mode, beside whether this run held
        the lock when it made it.

        The instrument is a descriptor opened before the run and kept: `flock`
        is per open file description, so asking for it non-blocking on that one
        answers whether anything — this process included — holds the lock right
        now, which is exactly the question a mode change has to be measured
        against.
        """
        probe = os.open(self.legacy_lock, os.O_RDONLY)
        self.addCleanup(os.close, probe)

        def held():
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(probe, fcntl.LOCK_UN)
            return False

        observed = []
        real = Path.chmod

        def watched(target, mode, **rest):
            if Path(target) == self.legacy_lock:
                observed.append((mode, held()))
            return real(target, mode, **rest)

        return observed, mock.patch.object(Path, "chmod", watched)

    def test_the_lock_is_never_loosened_by_a_run_that_does_not_hold_it(self):
        """The ordering that makes the closure real, rather than a window.

        A run that made this file writable so it could open it the ordinary way
        would be handing a stale transition the lock in exactly that window —
        `document_lock` opens `O_RDWR`, so a controller reaching for the lock
        while the mode is loose takes it. The rule is therefore that the mode is
        only ever loosened by a run that already holds the lock, and this
        watches every change to it on the path where the temptation is
        strongest: a location whose lock an earlier run left closed.
        """
        self.unfinished()
        # Closed again, so this run has to deal with a lock it cannot open the
        # ordinary way — which is the state that invites reopening it first.
        self.legacy_lock.chmod(0o400)
        observed, watcher = self.watch_lock_mode()
        with watcher:
            self.assertTrue(self.relocate()["late_writes"]["sealed"])
        self.assertTrue(observed, "nothing changed the lock's mode at all")
        # Not loosening it at all is the strongest outcome and the one this
        # takes: a closed lock is opened read-only, which needs no change. What
        # may never happen is a mode that grants write while this run does not
        # hold the lock.
        for mode, was_held in observed:
            if mode & 0o200:
                self.assertTrue(was_held, (oct(mode), observed))

    def test_a_contender_never_takes_the_lock_while_a_location_is_finished(self):
        """The retry path takes the lock the same way a relocation does.

        A location an earlier run left open has a *writable* lock — that is
        what "left open" means — so this is the run that could most easily hand
        a stale transition the lock, by making the file writable in order to
        open it the ordinary way. It does not: it opens the file, takes the
        lock, and only then closes the mode, so a controller reaching for that
        lock while this run works neither takes it nor opens one.
        """
        # Started before anything moves, so it is bound to the location this
        # run finishes rather than to the destination a later process resolves.
        process = self.start_holder(visible=False, open_now=False)
        self.unfinished()
        self.open_lock(process, visible=False)
        observed = {}
        real = install_drainer._settle_and_close

        def during(transition, relocation_plan, backend, outcome, descriptor):
            observed["acquired"] = self.acquired.exists()
            try:
                handle = os.open(self.legacy_lock, os.O_RDWR | os.O_CREAT, 0o600)
            except OSError as error:
                observed["open"] = f"{type(error).__name__}: {error}"
            else:
                os.close(handle)
                observed["open"] = None
            self.lock_holders = (process.pid,)
            return real(transition, relocation_plan, backend, outcome, descriptor)

        with mock.patch.object(install_drainer, "_settle_and_close", during):
            unfinished = self.relocate()
        # It never took the lock while this run held it, and could not have
        # opened one either.
        self.assertFalse(observed["acquired"])
        self.assertIsNotNone(observed["open"])
        self.assertIn(str(self.legacy_lock), observed["open"])
        # This run reports it rather than declaring the location closed...
        self.assertFalse(unfinished["late_writes"]["sealed"])
        self.assertEqual(unfinished["late_writes"]["lock_holders"], [process.pid])
        with self.assertRaises(install_drainer.RelocationUnresolved):
            install_drainer._require_relocation_resolved(unfinished)
        # ...and the run after it, once that process has had the turn it was
        # always going to get and gone, puts back what it took and closes.
        self.release(process)
        backend = install_drainer.service_backend()
        self.assertFalse(backend.definition_path(self.job.label).is_file())
        self.lock_holders = ()
        again = self.relocate()
        late = again["late_writes"]
        self.assertTrue(late["sealed"])
        self.assertEqual(late["restored_definitions"], ["acme/widgets"])
        self.assertTrue(backend.definition_path(self.job.label).is_file())
        install_drainer._require_relocation_resolved(again)
        self.assert_location_is_sealed()

    def test_finishing_a_location_reports_a_host_it_cannot_ask(self):
        """The refusal above is not available here: this location is already
        emptied, so there is nothing to decline to move. What a run that cannot
        ask does instead is leave the lock closed and say so."""
        self.unfinished()
        self.lock_holders = None
        self.lock_holders_reason = "open descriptors cannot be read on this host"
        unfinished = self.relocate()
        self.assertFalse(unfinished["late_writes"]["sealed"])
        self.assertIn("cannot be ruled out", unfinished["repair"])
        with self.assertRaises(install_drainer.RelocationUnresolved):
            install_drainer._require_relocation_resolved(unfinished)
        # And once it can be asked, the same re-run finishes it.
        self.lock_holders = ()
        self.lock_holders_reason = None
        again = self.relocate()
        self.assertTrue(again["late_writes"]["sealed"])
        install_drainer._require_relocation_resolved(again)
        self.assert_location_is_sealed()


class DestinationLifecycleTests(RelocationFixture):
    """What the bound must not reach: the installation the run just made.

    Everything closed here belongs to the location a run emptied — that
    location's own record path, its own runtime root, its own lock. Nothing
    else could be: every definition on this host lives in one directory the
    service manager owns, shared by both namespaces this repository installs
    and by every unrelated job the user has, so a bound that reached
    definitions would freeze the installation it had just made along with all
    of them.

    So this is the other half of the guarantee, asked of a host where the bound
    is in place: the destination goes on working exactly as it did, and the
    bound is still in place afterwards.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.assertTrue(self.relocate()["late_writes"]["sealed"])
        self.assert_location_is_sealed()
        # The relocation rebound this process to the destination, which is what
        # a controller invoked now resolves for itself.
        self.assertEqual(drain_prs_service.INSTALL_DIR, self.destination)
        self.destination_job = drain_prs_service.resolve_job(self.widgets)
        self.backend = install_drainer.service_backend()
        self.commands.clear()

    def definition(self):
        return self.backend.definition_path(self.destination_job.label)

    def assert_the_bound_is_still_in_place(self):
        """The location a run emptied is still closed, and a transition there
        still cannot begin."""
        self.assert_location_is_sealed()
        self.assertFalse(os.access(self.legacy_lock, os.W_OK))
        with self.assertRaises(drain_prs_service.ServiceError) as raised:
            with drain_prs_service.document_lock(self.legacy_record):
                pass
        self.assertIn("Refusing unsafe config lock path", str(raised.exception))

    def test_the_destination_controller_can_refresh_its_own_job(self):
        # The supported way a repository's installation is repaired or updated,
        # which writes the definition, the record entry and asks the manager to
        # load it — all at the destination, and none of it through anything
        # this run closed.
        with contextlib.redirect_stdout(io.StringIO()):
            result = drain_prs_service.install_job(self.destination_job)
        self.assertTrue(result["installed"])
        self.assertEqual(
            self.backend.definition_environment(self.destination_job.label)[
                kanban_config.DRAINER_INSTALL_DIR_ENV
            ],
            str(self.destination),
        )
        self.assertIn(
            "acme/widgets",
            self.record_document(self.destination_record)["repositories"],
        )
        self.assertTrue(
            any(
                self.destination_job.label in " ".join(command)
                for command in self.commands
            ),
            self.commands,
        )
        self.assert_the_bound_is_still_in_place()

    def test_the_destination_controller_can_uninstall_and_reinstall(self):
        with contextlib.redirect_stdout(io.StringIO()):
            removed = drain_prs_service.uninstall_job(self.destination_job)
        self.assertTrue(removed["uninstalled"])
        self.assertFalse(self.definition().is_file())
        self.assertNotIn(
            "acme/widgets",
            self.record_document(self.destination_record).get("repositories", {}),
        )
        with contextlib.redirect_stdout(io.StringIO()):
            drain_prs_service.install_job(self.destination_job)
        self.assertTrue(self.definition().is_file())
        self.assertIn(
            "acme/widgets",
            self.record_document(self.destination_record)["repositories"],
        )
        self.assert_the_bound_is_still_in_place()

    def test_an_unrelated_definition_in_the_same_directory_is_untouched(self):
        # The directory a definition lives in is the manager's, not this
        # installation's: this repository installs an issue-approval namespace
        # beside the drainer's, and a user has whatever else they have. A bound
        # that reached it would reach all of them.
        neighbour = service_manager.SYSTEMD_USER_DIR / (
            service_manager.ISSUE_APPROVAL_LABEL_PREFIX + ".acme.widgets.service"
        )
        service_manager.write_definition_file(neighbour, b"[Unit]\n")
        self.assertTrue(neighbour.is_file())
        self.assertTrue(service_manager.remove_definition_file(neighbour))
        self.assertFalse(neighbour.exists())
        # And the drainer's own definition beside it never moved.
        self.assertTrue(self.definition().is_file())
        self.assert_the_bound_is_still_in_place()


class ProcessDescriptorTests(unittest.TestCase):
    """The reader every fixture above pins.

    Pinned there because whether a host can read another process's descriptors
    is a property of the host rather than of the relocation, and a suite that
    probed it would answer differently on a macOS laptop and a Linux runner.
    Asked for real here, on the hosts that can answer.
    """

    def test_a_host_with_no_procfs_cannot_be_asked(self):
        with tempfile.TemporaryDirectory() as root:
            absent = Path(root) / "no-procfs"
            held = Path(root) / "held"
            held.write_text("", encoding="utf-8")
            with mock.patch.object(install_drainer, "_PROCFS", absent):
                holders, reason = install_drainer._processes_holding_open(held)
        # None rather than an empty tuple: the two are different answers, and
        # only one of them closes anything.
        self.assertIsNone(holders)
        self.assertIn(str(absent), reason)

    @unittest.skipUnless(Path("/proc").is_dir(), "this host has no /proc to read")
    def test_another_process_holding_it_open_is_found_and_this_one_is_not(self):
        with tempfile.TemporaryDirectory() as root:
            held = Path(root) / "held"
            held.write_text("", encoding="utf-8")
            self.assertEqual(
                install_drainer._processes_holding_open(held), ((), None)
            )
            process = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    "import sys, time\n"
                    "handle = open(sys.argv[1])\n"
                    "sys.stdout.write('open')\n"
                    "sys.stdout.flush()\n"
                    "time.sleep(60)\n",
                    str(held),
                ],
                stdout=subprocess.PIPE,
                text=True,
            )
            self.addCleanup(process.kill)
            self.assertEqual(process.stdout.read(4), "open")
            holders, reason = install_drainer._processes_holding_open(held)
            self.assertIsNone(reason)
            self.assertIn(process.pid, holders)
            # This process's own descriptor is not another process's, or every
            # run would find itself.
            own = held.open(encoding="utf-8")
            self.addCleanup(own.close)
            holders, _ = install_drainer._processes_holding_open(held)
            self.assertNotIn(os.getpid(), holders)


class TakeoverFixture(RelocationFixture):
    """Issue #368: a host whose own default install directory *is* the
    `~/Library` one.

    An absolute `$XDG_DATA_HOME` naming `~/Library/Application Support` makes
    this platform's default the legacy directory itself, so a default run's
    destination is the location the installation is already at. Nothing has to
    move — and the definitions there still name the log root the pre-XDG
    resolution answered with and carry none of the XDG context this host's own
    resolution puts in them.

    Seeded exactly as every other group here is, through the controller's own
    writers under the resolution a pre-XDG host ran with, and only then told
    that this platform's default resolves to that same directory.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.alias_data_home()

    def alias_data_home(self):
        """Make this platform's own default install directory the `~/Library`
        one, the way an operator who exported an absolute `$XDG_DATA_HOME`
        already has."""
        patcher = mock.patch.dict(
            os.environ,
            {"XDG_DATA_HOME": str(self.home / "Library" / "Application Support")},
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        drain_prs_service.bind_managed_paths()

    # -- driving ------------------------------------------------------------

    def take_over(self):
        """The run an operator performs: a default install, whose destination
        happens to be where the installation already is."""
        return install_drainer.relocate(self.legacy_dir, self.sources)

    def desired_definition(self, job):
        """The bytes this host would write for that job right now, through the
        same `render_definition` boundary the installer compares against."""
        backend = install_drainer.service_backend()
        return backend.render_definition(
            drain_prs_service.service_definition(
                drain_prs_service.job_for_identity(job.repo_path, job.identity)
            )
        )

    def definition_environment(self, job):
        return install_drainer.service_backend().definition_environment(job.label)

    def recorded_locks(self):
        """Every discovery-record lock taken from here on, by path.

        The real lock is still taken, so what this observes is the run's own
        behaviour rather than a stand-in for it.
        """
        taken = []
        real = drain_prs_service.document_lock

        @contextlib.contextmanager
        def recording(path):
            taken.append(Path(path))
            with real(path):
                yield

        patcher = mock.patch.object(drain_prs_service, "document_lock", recording)
        patcher.start()
        self.addCleanup(patcher.stop)
        return taken

    def no_relocation_machinery(self):
        """Neither of the two things a relocation does that a takeover has no
        second location for: merging one record into another, and holding the
        pair of locks between them."""
        stack = contextlib.ExitStack()
        for name in ("_merge_records", "_record_locks"):
            stack.enter_context(
                mock.patch.object(
                    install_drainer,
                    name,
                    mock.Mock(side_effect=AssertionError(f"{name} was reached")),
                )
            )
        return stack

    def tree_contents(self, root):
        return {
            str(path.relative_to(root)): path.read_bytes()
            for path in sorted(root.rglob("*"))
            if path.is_file() and not path.is_symlink()
        }

    def reset_failed_identifiers(self):
        """Which definitions the service manager was asked to re-read.

        `load_definition` ends in a `reset-failed` naming the one identifier it
        reloaded, so this counts reloads per repository rather than in total.
        """
        return [
            command[-1]
            for command in self.commands
            if command[:3] == ["systemctl", "--user", "reset-failed"]
        ]


class EqualLocationDispositionTests(TakeoverFixture):
    """Requirement 1: such a run takes the installation over, and every other
    reason to migrate nothing still holds."""

    def test_this_platform_takes_over_a_location_that_is_also_its_own_default(self):
        self.assertEqual(
            install_drainer.default_install_dir(), self.legacy_dir
        )
        self.assertIsNone(install_drainer.relocation_disposition(self.legacy_dir))

    def test_macos_still_takes_nothing_over(self):
        # The platform question, still asked as the platform question: a macOS
        # host whose XDG variables happen to point at its own install
        # directory is still a host nothing may migrate.
        self.set_platform("darwin")
        before = self.host_state()
        result = self.take_over()
        self.assertFalse(result["relocated"])
        self.assertIn("installs where its installation already is", result["reason"])
        self.assertEqual(self.host_state(), before)

    def test_a_custom_destination_elsewhere_still_migrates_nothing(self):
        before = self.host_state()
        result = install_drainer.relocate(self.root / "elsewhere", self.sources)
        self.assertFalse(result["relocated"])
        self.assertIn("custom --install-dir destination", result["reason"])
        self.assertEqual(self.host_state(), before)

    def test_a_location_holding_no_record_is_nothing_to_take_over(self):
        shutil.rmtree(self.legacy_dir)
        result = self.take_over()
        self.assertFalse(result["relocated"])
        self.assertIn("no installation at the legacy location", result["reason"])


class TakeoverTests(TakeoverFixture):
    """Requirements 1, 2 and 3 for one stale repository: what such a run
    rewrites, what it moves, and everything it leaves exactly as it stands."""

    def test_the_definition_becomes_the_bytes_this_host_would_write(self):
        before = self.job.definition_path.read_bytes()
        self.assertNotEqual(before, self.desired_definition(self.job))
        self.take_over()
        self.assertEqual(
            self.job.definition_path.read_bytes(), self.desired_definition(self.job)
        )

    def test_the_rewritten_definition_names_this_hosts_log_root_and_context(self):
        self.take_over()
        environment = self.definition_environment(self.job)
        self.assertEqual(
            environment["XDG_DATA_HOME"],
            str(self.home / "Library" / "Application Support"),
        )
        # The install directory did not move, so the one thing pinned by
        # `KANBAN_DRAINER_INSTALL_DIR` is the one thing unchanged.
        self.assertEqual(
            environment[kanban_config.DRAINER_INSTALL_DIR_ENV], str(self.legacy_dir)
        )
        text = self.job.definition_path.read_text(encoding="utf-8")
        self.assertIn(str(self.destination_logs / self.job.slug), text)
        self.assertNotIn(str(self.legacy_logs / self.job.slug), text)

    def test_the_log_tree_moves_to_the_root_this_host_uses(self):
        source = self.legacy_logs / self.job.slug
        contents = self.tree_contents(source)
        self.assertTrue(contents)
        self.take_over()
        self.assertFalse(source.exists())
        self.assertEqual(
            self.tree_contents(self.destination_logs / self.job.slug), contents
        )

    def test_the_runtime_tree_is_preserved_where_it_already_is(self):
        runtime = self.legacy_dir / "runtime" / self.job.slug
        contents = self.tree_contents(runtime)
        self.assertTrue(contents)
        result = self.take_over()
        self.assertEqual(self.tree_contents(runtime), contents)
        self.assertEqual(
            [move for move in result["moved"] if "runtime" in move["source"]], []
        )

    def test_nothing_at_that_location_is_taken_apart(self):
        entries = sorted(path.name for path in self.legacy_dir.iterdir())
        record = self.legacy_record.read_bytes()
        self.take_over()
        self.assertEqual(
            sorted(path.name for path in self.legacy_dir.iterdir()), entries
        )
        # The one document, untouched: this run never writes it, so it is not
        # merged with itself either.
        self.assertEqual(self.legacy_record.read_bytes(), record)
        self.assertFalse(install_drainer._is_relocation_seal(self.legacy_record))
        self.assertFalse(
            (self.legacy_dir / drain_prs_service.RELOCATION_MARKER_NAME).exists()
        )

    def test_the_result_reports_a_takeover_rather_than_a_relocation(self):
        result = self.take_over()
        self.assertFalse(result["relocated"])
        self.assertTrue(result["takeover"])
        self.assertEqual(result["location"], str(self.legacy_dir))
        self.assertEqual(result["record"], str(self.legacy_record))
        self.assertEqual(result["log_root"], str(self.destination_logs))
        self.assertEqual(result["rewritten"], [str(self.job.definition_path)])
        self.assertEqual(result["settled"], [])
        self.assertEqual(result["unrecoverable"], [])
        self.assertEqual(
            [entry["repository"] for entry in result["repositories"]], ["acme/widgets"]
        )

    def test_the_stale_definition_is_reloaded_exactly_once(self):
        self.commands.clear()
        self.take_over()
        self.assertEqual(self.reset_failed_identifiers(), [self.job.label])

    def test_a_settled_installation_reports_no_migration(self):
        self.assertTrue(self.take_over()["takeover"])
        before = self.host_state()
        result = self.take_over()
        self.assertFalse(result["relocated"])
        self.assertNotIn("takeover", result)
        self.assertIn("already what this host would write", result["reason"])
        self.assertEqual(self.host_state(), before)

    def test_a_settled_run_reloads_nothing(self):
        self.take_over()
        self.commands.clear()
        self.take_over()
        self.assertEqual(self.reset_failed_identifiers(), [])

    def test_the_settled_answer_carries_what_the_plan_accounted_for(self):
        self.take_over()
        result = self.take_over()
        self.assertEqual(result["settled"], ["acme/widgets"])
        self.assertEqual(result["unrecoverable"], [])

    def test_a_record_holding_only_an_unrecoverable_entry_says_so(self):
        # Nothing stale, because nothing could be recovered to compare. An
        # answer of "every definition here is already what this host would
        # write" would be claiming to have compared one it never read.
        drain_prs_service.merge_repository_record(
            "acme/widgets", {"repository": str(self.root / "vanished")}
        )
        before = self.host_state()
        result = self.take_over()
        self.assertFalse(result["relocated"])
        self.assertNotIn("takeover", result)
        self.assertEqual(result["settled"], [])
        self.assertEqual(len(result["unrecoverable"]), 1)
        self.assertIn("which is not a directory", result["unrecoverable"][0])
        self.assertIn("could not be recovered", result["reason"])
        self.assertNotIn(
            "every definition at this location is already", result["reason"]
        )
        self.assertEqual(self.host_state(), before)


class TakeoverLockingTests(TakeoverFixture):
    """Requirement 2: with one document rather than two there is nothing to
    merge and no lock to hold between two records — and the record write that
    follows keeps the lock it has always taken."""

    def test_a_settled_run_takes_no_lock_and_merges_no_document(self):
        self.take_over()
        locks = self.recorded_locks()
        with self.no_relocation_machinery():
            result = self.take_over()
        self.assertIn("already what this host would write", result["reason"])
        self.assertEqual(locks, [])

    def test_an_acting_run_merges_nothing_and_locks_only_that_one_record(self):
        locks = self.recorded_locks()
        with self.no_relocation_machinery():
            self.assertTrue(self.take_over()["takeover"])
        self.assertEqual(set(locks), {self.legacy_record})

    def test_the_installers_own_record_write_is_still_locked(self):
        # The other half of the same requirement, and the reason the takeover
        # needs no lock of its own: the lock it would hold is the one this
        # write goes on to ask for.
        self.take_over()
        locks = self.recorded_locks()
        install_drainer.write_installed_config_path(
            self.job.identity, str(self.root / "config.toml")
        )
        self.assertIn(self.legacy_record, locks)

    def test_a_drainer_starting_mid_run_is_fenced_out(self):
        # The same fence the relocation takes, over the shorter transition:
        # the definitions being rewritten belong to jobs whose checkouts a
        # drainer could take one instant after the preflight looked.
        observed = {}
        real = install_drainer._apply_takeover

        def during(transition, plan):
            with self.assertRaises(drain_prs.RunLockedError):
                drain_prs.acquire_lock(self.widgets, mode="single-pr", pull_request=1)
            observed["fenced"] = True
            return real(transition, plan)

        with mock.patch.object(install_drainer, "_apply_takeover", during):
            self.assertTrue(self.take_over()["takeover"])
        self.assertTrue(observed["fenced"])

    def test_a_running_controller_refuses_the_run(self):
        descriptor = drain_prs_service.acquire_controller_lock(
            self.legacy_dir / "runtime" / self.job.slug
        )
        self.addCleanup(lambda: os.close(descriptor))
        before = self.host_state()
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.take_over()
        self.assertIn("controller is running", str(raised.exception))
        self.assertEqual(self.host_state(), before)

    def test_a_failure_puts_every_definition_back(self):
        before = self.host_state()
        with mock.patch.object(
            install_drainer,
            "_rewrite_definition",
            mock.Mock(side_effect=OSError("no room")),
        ):
            with self.assertRaises(install_drainer.RelocationFailed):
                self.take_over()
        self.assertEqual(self.host_state(), before)


class TakeoverScopeTests(TakeoverFixture):
    """Requirements 3 and 4: exactly the stale definitions, and guards that
    see only them.

    The settled repository is installed under *this* host's own resolution, by
    the same installer that would otherwise rewrite it, so its definition is
    already the bytes this host would write rather than a hand-made copy of
    them.
    """

    def setUp(self):
        super().setUp()
        self.gadgets = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.settled = self.seed_repository(self.gadgets)

    def test_the_settled_repository_starts_out_current(self):
        # The premise of every case below, asserted rather than assumed: a
        # group that seeded two stale definitions would prove nothing about
        # scoping.
        self.assertEqual(
            self.settled.definition_path.read_bytes(),
            self.desired_definition(self.settled),
        )
        self.assertNotEqual(
            self.job.definition_path.read_bytes(), self.desired_definition(self.job)
        )

    def test_only_the_stale_definition_is_rewritten(self):
        settled = self.settled.definition_path.read_bytes()
        result = self.take_over()
        self.assertEqual(result["rewritten"], [str(self.job.definition_path)])
        self.assertEqual(result["settled"], ["acme/gadgets"])
        self.assertEqual(self.settled.definition_path.read_bytes(), settled)
        self.assertEqual(
            self.job.definition_path.read_bytes(), self.desired_definition(self.job)
        )

    def test_only_the_stale_definition_is_reloaded(self):
        self.commands.clear()
        self.take_over()
        self.assertEqual(self.reset_failed_identifiers(), [self.job.label])

    def test_a_settled_repositorys_own_trees_are_left_alone(self):
        logs = self.tree_contents(self.destination_logs / self.settled.slug)
        runtime = self.tree_contents(self.legacy_dir / "runtime" / self.settled.slug)
        self.assertTrue(logs)
        self.assertTrue(runtime)
        self.take_over()
        self.assertEqual(
            self.tree_contents(self.destination_logs / self.settled.slug), logs
        )
        self.assertEqual(
            self.tree_contents(self.legacy_dir / "runtime" / self.settled.slug), runtime
        )

    def test_a_settled_siblings_live_drainer_does_not_refuse_the_run(self):
        # Requirement 4, at the shape it matters in: the preflight's guards
        # are refusals, so a run that treated every recorded repository as
        # affected would refuse an ordinary install whenever any other
        # repository's drainer happened to be running.
        (self.gadgets / ".git" / "drain_prs.lock").write_text(
            str(os.getpid()), encoding="utf-8"
        )
        result = self.take_over()
        self.assertEqual(result["rewritten"], [str(self.job.definition_path)])

    def test_a_settled_siblings_live_managed_job_does_not_refuse_it_either(self):
        # The other liveness signal, on the same terms: a settled sibling's
        # job being up is not this run's business, because this run does not
        # touch it.
        settled = self.settled.label

        def is_running(backend, identifier):
            return identifier == settled

        with mock.patch.object(
            type(install_drainer.service_backend()), "is_running", is_running
        ):
            result = self.take_over()
        self.assertEqual(result["rewritten"], [str(self.job.definition_path)])

    def test_the_stale_repositorys_own_live_drainer_still_refuses(self):
        (self.widgets / ".git" / "drain_prs.lock").write_text(
            str(os.getpid()), encoding="utf-8"
        )
        before = self.host_state()
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.take_over()
        self.assertIn("a drainer is running in", str(raised.exception))
        self.assertEqual(self.host_state(), before)

    def test_a_settled_run_still_names_an_entry_it_could_not_recover(self):
        # Every recoverable definition current, one entry unreadable: the run
        # migrates nothing, and reporting that as a settled installation would
        # lose the only mention the untouched repository gets.
        self.take_over()
        drain_prs_service.merge_repository_record(
            "acme/gadgets", {"repository": str(self.root / "vanished")}
        )
        result = self.take_over()
        self.assertFalse(result["relocated"])
        self.assertNotIn("takeover", result)
        self.assertEqual(result["settled"], ["acme/widgets"])
        self.assertEqual(len(result["unrecoverable"]), 1)
        self.assertIn("could not be recovered", result["reason"])

    def test_an_entry_that_cannot_be_recovered_is_left_alone_and_named(self):
        # This run takes nothing apart, so an entry it cannot recover is one
        # it cannot show to be affected and does not touch. Refusing over it
        # would be the same over-wide refusal requirement 4 rejects.
        definition = self.settled.definition_path.read_bytes()
        drain_prs_service.merge_repository_record(
            "acme/gadgets", {"repository": str(self.root / "vanished")}
        )
        result = self.take_over()
        self.assertEqual(result["rewritten"], [str(self.job.definition_path)])
        self.assertEqual(result["settled"], [])
        self.assertEqual(len(result["unrecoverable"]), 1)
        self.assertIn("which is not a directory", result["unrecoverable"][0])
        self.assertEqual(self.settled.definition_path.read_bytes(), definition)


class TakeoverSelectionTests(TakeoverFixture):
    """The review's amendment: staleness is decided against the final
    effective install-directory selection, so an explicit `--install-dir`
    beats an inherited `KANBAN_DRAINER_INSTALL_DIR`."""

    def inherited(self):
        return mock.patch.dict(
            os.environ,
            {kanban_config.DRAINER_INSTALL_DIR_ENV: str(self.root / "inherited")},
        )

    def test_the_selection_decides_the_bytes_that_are_written(self):
        with self.inherited():
            result = self.take_over()
        self.assertTrue(result["takeover"])
        self.assertFalse((self.root / "inherited").exists())
        self.assertEqual(
            self.definition_environment(self.job)[
                kanban_config.DRAINER_INSTALL_DIR_ENV
            ],
            str(self.legacy_dir),
        )

    def test_the_selection_decides_which_definitions_are_stale(self):
        # Judged against the inherited directory instead, a settled
        # installation would read as stale for as long as that variable was
        # exported, and every run would rewrite every definition.
        self.assertTrue(self.take_over()["takeover"])
        before = self.host_state()
        with self.inherited():
            result = self.take_over()
        self.assertIn("already what this host would write", result["reason"])
        self.assertEqual(self.host_state(), before)

    def test_the_process_still_describes_what_it_described_before(self):
        # A takeover moves nothing, so unlike a relocation it has no reason to
        # leave this process bound anywhere else.
        with self.inherited():
            # Bound under that variable, which is what a process launched with
            # it exported holds from its own import onwards.
            drain_prs_service.bind_managed_paths()
            before = self.stale_bindings()
            self.take_over()
            self.assertEqual(self.stale_bindings(), before)
            self.assertEqual(
                os.environ[kanban_config.DRAINER_INSTALL_DIR_ENV],
                str(self.root / "inherited"),
            )

    def test_an_override_that_was_absent_is_still_absent(self):
        self.assertNotIn(kanban_config.DRAINER_INSTALL_DIR_ENV, os.environ)
        before = self.stale_bindings()
        self.take_over()
        self.assertNotIn(kanban_config.DRAINER_INSTALL_DIR_ENV, os.environ)
        self.assertEqual(self.stale_bindings(), before)


class TakeoverLogRootTests(TakeoverFixture):
    """Requirement 5: a log root that is its own destination is preserved in
    place rather than refused as an occupied one."""

    def setUp(self):
        super().setUp()
        patcher = mock.patch.dict(
            os.environ, {"XDG_STATE_HOME": str(self.home / "Library" / "Logs")}
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        drain_prs_service.bind_managed_paths()

    def test_this_hosts_log_root_is_the_one_the_logs_are_already_under(self):
        self.assertEqual(kanban_config.default_drainer_log_dir(), self.legacy_logs)

    def test_the_log_tree_is_preserved_rather_than_moved_onto_itself(self):
        logs = self.legacy_logs / self.job.slug
        contents = self.tree_contents(logs)
        self.assertTrue(contents)
        result = self.take_over()
        self.assertTrue(result["takeover"])
        self.assertEqual(result["moved"], [])
        self.assertEqual(self.tree_contents(logs), contents)

    def test_the_definition_is_still_brought_up_to_this_hosts_context(self):
        # Stale for a reason the log root cannot show: the definition carries
        # neither XDG variable, and this host resolves both.
        self.take_over()
        environment = self.definition_environment(self.job)
        self.assertEqual(
            environment["XDG_STATE_HOME"], str(self.home / "Library" / "Logs")
        )
        self.assertEqual(
            self.job.definition_path.read_bytes(), self.desired_definition(self.job)
        )


class TakeoverPreviewTests(TakeoverFixture):
    """What `--dry-run` reports, and that reporting it changes nothing."""

    def setUp(self):
        super().setUp()
        self.kanban = self.make_checkout("kanban", "git@github.com:acme/widgets.git")
        tools = self.kanban / "tools"
        tools.mkdir()
        for source in self.sources.values():
            (tools / source.name).write_text(
                source.read_text(encoding="utf-8"), encoding="utf-8"
            )

    def install(self, **options):
        return install_drainer.install(
            self.kanban, self.legacy_dir, ntfy_url=None, **options
        )

    def test_a_dry_run_reports_the_takeover_and_takes_no_lock(self):
        locks = self.recorded_locks()
        before = self.host_state()
        relocation = self.install(dry_run=True)["relocation"]
        self.assertTrue(relocation["dry_run"])
        self.assertTrue(relocation["takeover"])
        self.assertFalse(relocation["relocated"])
        self.assertEqual(relocation["location"], str(self.legacy_dir))
        self.assertEqual(
            [entry["repository"] for entry in relocation["repositories"]],
            ["acme/widgets"],
        )
        self.assertEqual(locks, [])
        self.assertEqual(self.host_state(), before)

    def test_a_settled_dry_run_reports_no_migration(self):
        self.take_over()
        before = self.host_state()
        relocation = self.install(dry_run=True)["relocation"]
        self.assertNotIn("takeover", relocation)
        self.assertIn("already what this host would write", relocation["reason"])
        self.assertEqual(relocation["settled"], ["acme/widgets"])
        self.assertEqual(relocation["unrecoverable"], [])
        self.assertEqual(self.host_state(), before)

    def test_a_settled_dry_run_names_an_entry_it_could_not_recover_too(self):
        self.take_over()
        drain_prs_service.merge_repository_record(
            "acme/widgets", {"repository": str(self.root / "vanished")}
        )
        before = self.host_state()
        relocation = self.install(dry_run=True)["relocation"]
        self.assertNotIn("takeover", relocation)
        self.assertEqual(len(relocation["unrecoverable"]), 1)
        self.assertIn("could not be recovered", relocation["reason"])
        self.assertEqual(self.host_state(), before)

if __name__ == "__main__":
    unittest.main()
