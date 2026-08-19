"""Issues #367 and #369: relocating a pre-XDG `~/Library` drainer installation,
and carrying across whatever a writer puts back at the location it emptied.

A host that installed before `tools/kanban_config.py` resolved the drainer's
managed paths per platform has its installation at the macOS-shaped locations,
and discovery keeps finding it there forever. These are the tests for the one
thing that moves it, and for the reconciliation that follows the removal: the
transition's locks serialize every writer queued on them, and a writer that
arrives afterwards contends with nothing, so what it recorded is carried across
and what cannot be carried is reported rather than chosen between.

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

    def write_late(self, checkout, bindings, *, stamp="late"):
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
        """
        with self.as_bound(bindings):
            job = drain_prs_service.resolve_job(checkout)
            backend = install_drainer.service_backend()
            # The controller's own log writer also prints, which is its job and
            # not this suite's output.
            with contextlib.redirect_stdout(io.StringIO()):
                drain_prs_service.ensure_dirs(job)
                backend.write_definition(drain_prs_service.service_definition(job))
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
        """Whether another opener would block on one record's lock.

        `flock` is per open file description, so a second descriptor in this
        same process contends exactly as another process's would — which is
        what makes this an observation of the lock rather than of the code
        that takes it.
        """
        lock_path = Path(str(record or self.legacy_record) + ".lock")
        if not lock_path.parent.is_dir():
            return False
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
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

    def test_a_platform_default_that_aliases_the_legacy_directory_installs_in_place(self):
        # An absolute XDG root naming `~/Library/Application Support` makes
        # this platform's own default the legacy directory itself. Taking over
        # an installation already at the destination is #368's, so this
        # installs where it always did.
        self.seed_legacy_installation()
        with mock.patch.dict(
            os.environ, {"XDG_DATA_HOME": str(self.home / "Library/Application Support")}
        ):
            before = self.host_state()
            result = install_drainer.relocate(self.legacy_dir, self.sources)
        self.assertFalse(result["relocated"])
        self.assertIn("already at", result["reason"])
        self.assertEqual(self.host_state(), before)

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
        self.assertFalse(self.legacy_record.exists())
        self.assertEqual(
            sorted(path.name for path in self.legacy_dir.iterdir()),
            ["config.json.lock", "relocated.json"],
        )
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
        self.assertFalse(self.legacy_record.exists())
        self.assertFalse((self.legacy_dir / "runtime").exists())
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
        self.assertFalse(self.legacy_record.exists())

    def test_a_queued_run_refuses_before_it_writes_anything(self):
        # The service-manager `run` path: a runner launched before the
        # relocation, or started by hand while the record showed nothing live,
        # begins afterwards. Its own first act is to log, and logging creates
        # the directories it logs into.
        with self.as_the_stale_controller():
            before = self.host_state()
            self.assertEqual(
                drain_prs_service.run_service(self.job, self.job.identity), 0
            )
            self.assertEqual(self.host_state(), before)
        self.assertFalse((self.legacy_logs / self.job.slug).exists())
        self.assertFalse((self.legacy_dir / "runtime").exists())

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
        self.assertFalse(self.legacy_record.exists())


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


class RetainedResidueTests(RelocationFixture):
    """What the removal deliberately leaves behind, and says it left."""

    def test_a_legacy_log_root_still_holding_something_is_kept_and_reported(self):
        # Not this run's to delete: it never accounted for whatever is in
        # there, and taking a log root away with the installation it happened
        # to sit beside would be discarding durable state.
        self.seed_legacy_installation()
        stray = self.legacy_logs / "someone.else"
        stray.mkdir(parents=True)
        (stray / "service.log").write_text("kept\n", encoding="utf-8")
        result = self.relocate()
        self.assertIn(str(self.legacy_logs), result["retained"])
        self.assertEqual((stray / "service.log").read_text(encoding="utf-8"), "kept\n")

    def test_a_legacy_runtime_directory_still_holding_something_is_kept(self):
        job = self.seed_legacy_installation()[0]
        stray = self.legacy_dir / "runtime" / "someone.else"
        stray.mkdir(parents=True)
        (stray / "status.json").write_text("{}", encoding="utf-8")
        result = self.relocate()
        self.assertIn(str(self.legacy_dir / "runtime"), result["retained"])
        self.assertTrue((stray / "status.json").is_file())
        # And what the run *did* account for still moved.
        self.assertTrue(
            (self.destination / "runtime" / job.slug / "status.json").is_file()
        )


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
        self.assertFalse(self.legacy_record.exists())


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
        self.assertFalse((self.legacy_dir / "runtime").exists())

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
            ["config.json.lock", "relocated.json"],
        )
        self.assertFalse(self.legacy_logs.exists())
        self.assertIn(str(self.legacy_record), result["late_writes"]["removed"])
        self.assertEqual(result["late_writes"]["retained"], [])

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
        self.assertFalse(self.legacy_record.exists())


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

    def test_a_re_run_then_refuses_naming_both_roots_and_changes_nothing(self):
        self.relocate_with_late_write()
        before = self.host_state()
        with self.assertRaises(install_drainer.InstallError) as raised:
            install_drainer.plan_relocation(self.destination)
        message = str(raised.exception)
        self.assertIn(str(self.legacy_logs / self.slug), message)
        self.assertIn(str(self.destination_logs / self.slug), message)
        self.assertEqual(self.host_state(), before)

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
import json, os, sys, time
from pathlib import Path

for entry in reversed(sys.argv[1].split(os.pathsep)):
    sys.path.insert(0, entry)
ready, go, queued, acquired, result = (
    Path(argument) for argument in sys.argv[2:7]
)
identity, checkout = sys.argv[7], sys.argv[8]

import drain_prs_service

# Bound here, while the legacy record is still the one this host resolves.
ready.write_text(str(drain_prs_service.DISCOVERY_RECORD_PATH), encoding="utf-8")
while not go.exists():
    time.sleep(0.01)
outcome = {"bound_record": str(drain_prs_service.DISCOVERY_RECORD_PATH)}
queued.write_text("", encoding="utf-8")
# The record's own lock, taken the way every transition in the controller
# takes it and before anything is asked about the installation, so where this
# process waits is settled rather than raced. `merge_repository_record` below
# asks for the same lock again, which re-enters within this one thread exactly
# as it does inside `install_job`.
with drain_prs_service.document_lock(drain_prs_service.DISCOVERY_RECORD_PATH):
    acquired.write_text("", encoding="utf-8")
    try:
        drain_prs_service.merge_repository_record(identity, {"repository": checkout})
        outcome["recorded"] = True
    except drain_prs_service.ServiceError as error:
        outcome["refused"] = str(error)
    # Held across the write and a moment past it, so a reader that asks for
    # this lock after the handoff blocks on this process rather than reading a
    # record it is halfway through replacing.
    time.sleep(float(sys.argv[9]))
result.write_text(json.dumps(outcome), encoding="utf-8")
"""


class QueuedRecordWriterTests(RelocationFixture):
    """A writer in another OS process, queued on the legacy record's lock.

    The relocation holds that lock across its whole transition and never
    unlinks the lock file, so this writer really does block on the same inode
    and really does wake only after the reconciliation has finished — past
    anything a bounded sweep could have carried across. What it must not be
    able to do is record anything, and that is what the refusal every
    discovery-record write carries is for.
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
            ],
            env={"HOME": str(self.home), "PATH": os.environ.get("PATH", "")},
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
            # It cannot have the lock: this run holds it and never unlinks it.
            # If it does, `flock` did not serialize this writer at all.
            self.blocked = not self.acquired.exists()
            return real_remove(transition, relocation_plan)

        with mock.patch.object(install_drainer, "_apply_relocation", apply_hook):
            with mock.patch.object(
                install_drainer, "_remove_legacy_installation", remove_hook
            ):
                result = self.relocate()
        self.assertEqual(process.wait(timeout=60), 0, process.communicate())
        return result, json.loads(self.result.read_text(encoding="utf-8"))

    def test_it_blocks_on_the_lock_and_then_records_nothing(self):
        before_record = self.legacy_record
        _, outcome = self.relocate_with_queued_writer()
        # It really was the stale, legacy-bound process this is about...
        self.assertEqual(outcome["bound_record"], str(before_record))
        # ...it really did block, rather than refusing before it queued...
        self.assertTrue(self.blocked, outcome)
        # ...and it wrote nothing at the location the relocation emptied.
        self.assertNotIn("recorded", outcome)
        self.assertIn("was relocated to", outcome["refused"])
        self.assertIn(str(self.destination), outcome["refused"])
        self.assertFalse(self.legacy_record.exists())

    def test_the_run_it_woke_into_needed_no_reconciliation(self):
        result, _ = self.relocate_with_queued_writer()
        # Nothing came back, so nothing was carried and nothing is retained:
        # the refusal is what kept the sweep from having anything to do.
        self.assertTrue(result["late_writes"]["resolved"])
        self.assertEqual(result["late_writes"]["passes"], 0)
        self.assertEqual(
            sorted(path.name for path in self.legacy_dir.iterdir()),
            ["config.json.lock", "relocated.json"],
        )


# What the pre-gate writer below runs. Identical to the queued writer above
# except for the copy of the controller it imports, so the only thing that
# differs between the two cases is whether that copy refuses.
_PRE_GATE_WRITER = _QUEUED_WRITER


class PreGateWriterTests(RelocationFixture):
    """The writer no gate in this copy can refuse: an older installed
    controller.

    A host with a `~/Library` installation is running the controller it
    installed, from before this arc — that is the premise of the relocation
    itself — so no edit to *this* copy makes that process refuse. Such a writer
    queued on the retained record lock wakes once the transition releases it and
    records itself at the location the run just emptied. What must happen then
    is that the reconciliation finds it, which is why the reconciliation is
    sequenced outside those locks and re-takes them pass by pass.
    """

    def setUp(self):
        super().setUp()
        self.job = self.seed_legacy_installation()[0]
        self.ready = self.root / "pre-gate.ready"
        self.go = self.root / "pre-gate.go"
        self.queued = self.root / "pre-gate.queued"
        self.acquired = self.root / "pre-gate.acquired"
        self.result = self.root / "pre-gate.result"
        self.writer_script = self.root / "pre_gate_writer.py"
        self.writer_script.write_text(_PRE_GATE_WRITER, encoding="utf-8")
        self.pre_gate = self.build_pre_gate_controller()

    def build_pre_gate_controller(self):
        """This module's own source with exactly the gate this arc added taken
        back out, which is what an older installed copy is.

        Built from the current source rather than checked in, and asserted to
        have really removed something, so a rename or a re-spelling of that
        gate cannot quietly turn this into a second test of the gated path.
        """
        source = Path(drain_prs_service.__file__).read_text(encoding="utf-8")
        gate = (
            "    with installation_transaction():\n"
            "        return update_json_document("
        )
        self.assertEqual(
            source.count(gate), 2, "the discovery record's write-level gate moved"
        )
        directory = self.root / "pre-gate-controller"
        directory.mkdir()
        (directory / "drain_prs_service.py").write_text(
            source.replace(gate, "    return update_json_document("), encoding="utf-8"
        )
        return directory

    def start_writer(self):
        process = subprocess.Popen(
            [
                sys.executable,
                str(self.writer_script),
                # Its own copy first and the tracked modules behind it, so this
                # process really is running the older controller while
                # resolving paths through the same `kanban_config` every other
                # component does.
                os.pathsep.join(
                    [str(self.pre_gate), str(Path(drain_prs_service.__file__).parent)]
                ),
                str(self.ready),
                str(self.go),
                str(self.queued),
                str(self.acquired),
                str(self.result),
                "acme/widgets",
                str(self.widgets),
                # Held past the write, so the reconciliation's first pass
                # blocks on this process once the handoff gives it the lock.
                "0.4",
            ],
            env={"HOME": str(self.home), "PATH": os.environ.get("PATH", "")},
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(process.kill)
        self.process = process
        self.wait_for(self.ready, "the pre-gate writer never bound its paths")
        return process

    def wait_for(self, path, message):
        deadline = time.monotonic() + 30
        while not path.exists() and time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.fail(f"{message}: {self.process.communicate()}")
            time.sleep(0.02)
        self.assertTrue(path.exists(), message)

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

    def test_it_blocks_on_the_lock_and_then_really_does_record(self):
        result, outcome = self.relocate_with_pre_gate_writer()
        self.assertEqual(outcome["bound_record"], str(self.legacy_record))
        # It blocked on the retained lock rather than refusing where it stood...
        self.assertTrue(self.acquired.exists())
        # ...and, being the older copy, it recorded. Nothing in this repository
        # can stop that; the reconciliation is what answers it.
        self.assertTrue(outcome["recorded"])
        self.assertNotIn("refused", outcome)
        self.assertEqual(result["late_writes"]["passes"], 1)

    def test_what_it_recorded_is_carried_across_and_the_location_cleared(self):
        result, _ = self.relocate_with_pre_gate_writer()
        late = result["late_writes"]
        self.assertTrue(late["resolved"])
        self.assertEqual(late["repositories"], ["acme/widgets"])
        self.assertIn(str(self.legacy_record), late["removed"])
        self.assertFalse(self.legacy_record.exists())
        self.assertEqual(
            sorted(path.name for path in self.legacy_dir.iterdir()),
            ["config.json.lock", "relocated.json"],
        )
        entry = self.record_document(self.destination_record)["repositories"][
            "acme/widgets"
        ]
        self.assertEqual(entry["repository"], str(self.widgets))

    def test_the_install_reports_success_because_nothing_was_left_behind(self):
        result, _ = self.relocate_with_pre_gate_writer()
        install_drainer._require_relocation_resolved(result)
        self.assertIn("cleared again", result["repair"])

    def test_a_writer_that_beats_the_final_look_is_carried_by_the_next_run(self):
        """The one case no terminating process can close.

        A writer that takes the lock after this run's last look is past
        anything this run can observe: `flock` cannot be asked whether someone
        is waiting, and a process that has returned cannot look again. What
        answers it is the next run, which finds a discovery record at the
        legacy location again and relocates over it exactly as this one did —
        so the state is late rather than lost.
        """
        process = self.start_writer()
        first = self.relocate()
        self.assertTrue(first["late_writes"]["resolved"])
        self.assertEqual(first["late_writes"]["passes"], 0)
        # Only now, with nothing left holding the lock and the run over.
        self.go.write_text("", encoding="utf-8")
        self.assertEqual(process.wait(timeout=60), 0, process.communicate())
        self.assertTrue(
            json.loads(self.result.read_text(encoding="utf-8"))["recorded"]
        )
        self.assertTrue(self.legacy_record.is_file())
        second = install_drainer.relocate(self.destination, self.sources)
        self.assertTrue(second["relocated"])
        self.assertFalse(self.legacy_record.exists())
        self.assertEqual(
            self.record_document(self.destination_record)["repositories"][
                "acme/widgets"
            ]["repository"],
            str(self.widgets),
        )


if __name__ == "__main__":
    unittest.main()
