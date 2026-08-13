"""Unit tests for the service-manager backend.

Everything here runs against a scripted runner and a temporary LaunchAgents
directory: no test invokes `launchctl`, and none writes under the real
~/Library/LaunchAgents.
"""

import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import service_manager


def _completed(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class ScriptedRunner:
    """The injected command runner, recording every argument vector and
    answering from a scripted table.

    `check=True` raises whatever error type the caller's own wrapper would
    raise, which is the property that keeps a backend failure inside the
    caller's failure vocabulary rather than introducing a third one.
    """

    def __init__(self, error, answers=None):
        self.error = error
        self.answers = answers or {}
        self.commands = []

    def __call__(self, args, *, check=True, env=None):
        self.commands.append(list(args))
        proc = self.answers.get(tuple(args), _completed(0))
        if check and proc.returncode != 0:
            raise self.error(f"Command failed: {' '.join(args)}")
        return proc


class RunnerError(RuntimeError):
    """Stands in for the caller's own error type."""


class BackendTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.launch_agents = self.root / "LaunchAgents"
        self.launch_agents.mkdir()
        for name, value in (
            ("LAUNCH_AGENTS_DIR", self.launch_agents),
            (
                "LEGACY_PLIST_PATH",
                self.launch_agents / f"{service_manager.LEGACY_LABEL}.plist",
            ),
        ):
            patched = mock.patch.object(service_manager, name, value)
            patched.start()
            self.addCleanup(patched.stop)
        self.runner = ScriptedRunner(RunnerError)
        self.backend = service_manager.select_backend(self.runner)

    def definition(self, identifier="com.coghex.drain-prs.acme.widgets"):
        return service_manager.ServiceDefinition(
            identifier=identifier,
            program_arguments=["/usr/bin/python3", "/install/controller.py", "run"],
            working_directory="/checkout",
            environment={"HOME": "/home", "PYTHONUNBUFFERED": "1"},
            stdout_path="/logs/service.out",
            stderr_path="/logs/service.err",
        )

    def answer(self, args, proc):
        self.runner.answers[tuple(args)] = proc


class NamingTests(BackendTestCase):
    def test_the_identifier_and_its_definition_path_come_from_one_derivation(self):
        identifier = self.backend.service_identifier("acme.widgets")
        self.assertEqual(identifier, "com.coghex.drain-prs.acme.widgets")
        self.assertEqual(
            self.backend.definition_path(identifier),
            self.launch_agents / f"{identifier}.plist",
        )
        self.assertTrue(
            self.backend.manager_target(identifier).endswith(f"/{identifier}")
        )

    def test_the_target_is_the_domain_and_the_identifier(self):
        self.assertEqual(
            self.backend.manager_target("com.example.job"),
            f"{service_manager.launch_domain()}/com.example.job",
        )

    def test_a_slug_fits_exactly_up_to_the_identifier_limit(self):
        room = service_manager.MAX_LABEL_LENGTH - len(service_manager.LABEL_PREFIX) - 1
        self.assertTrue(self.backend.identifier_fits("a" * room))
        self.assertFalse(self.backend.identifier_fits("a" * (room + 1)))

    def test_the_legacy_singleton_keeps_its_own_identifier_and_path(self):
        self.assertEqual(
            self.backend.legacy_identifier(), service_manager.LEGACY_LABEL
        )
        self.assertEqual(
            self.backend.legacy_definition_path(), service_manager.LEGACY_PLIST_PATH
        )


class DefinitionTests(BackendTestCase):
    def test_the_written_definition_is_the_rendered_one_and_is_readable(self):
        path = self.backend.write_definition(self.definition())
        self.assertEqual(
            path,
            self.launch_agents / "com.coghex.drain-prs.acme.widgets.plist",
        )
        self.assertEqual(
            path.read_bytes(), self.backend.render_definition(self.definition())
        )
        # 0644 rather than the 0700 the runtime state uses: launchd reads it.
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.runner.commands, [])

    def test_writing_replaces_an_existing_definition_in_place(self):
        first = self.backend.write_definition(self.definition())
        second = self.backend.write_definition(
            self.definition(identifier="com.coghex.drain-prs.acme.widgets")
        )
        self.assertEqual(first, second)
        self.assertEqual(
            sorted(path.name for path in self.launch_agents.iterdir()),
            ["com.coghex.drain-prs.acme.widgets.plist"],
        )

    def test_the_rendered_keys_keep_their_order_and_their_types(self):
        rendered = self.backend.render_definition(self.definition())
        value = plistlib.loads(rendered)
        self.assertEqual(
            list(value),
            [
                "Label",
                "ProgramArguments",
                "WorkingDirectory",
                "RunAtLoad",
                "KeepAlive",
                "ProcessType",
                "ThrottleInterval",
                "StandardOutPath",
                "StandardErrorPath",
                "EnvironmentVariables",
            ],
        )
        self.assertIs(value["RunAtLoad"], False)
        self.assertIs(value["KeepAlive"], False)
        self.assertEqual(value["ThrottleInterval"], service_manager.THROTTLE_SECONDS)
        self.assertEqual(value["ProcessType"], "Background")


class LifecycleSequenceTests(BackendTestCase):
    def setUp(self):
        super().setUp()
        self.identifier = "com.coghex.drain-prs.acme.widgets"
        self.target = self.backend.manager_target(self.identifier)

    def test_an_existing_job_is_booted_out_before_its_replacement_is_loaded(self):
        self.answer(["launchctl", "print", self.target], _completed(0))
        self.backend.load_definition(self.identifier)
        self.assertEqual(
            self.runner.commands,
            [
                ["launchctl", "print", self.target],
                ["launchctl", "bootout", self.target],
                [
                    "launchctl",
                    "bootstrap",
                    service_manager.launch_domain(),
                    str(self.backend.definition_path(self.identifier)),
                ],
            ],
        )

    def test_a_job_that_is_not_loaded_is_only_bootstrapped(self):
        self.answer(["launchctl", "print", self.target], _completed(1))
        self.backend.load_definition(self.identifier)
        self.assertNotIn(
            ["launchctl", "bootout", self.target], self.runner.commands
        )
        self.assertEqual(self.runner.commands[-1][:2], ["launchctl", "bootstrap"])

    def test_starting_kicks_the_job_and_stopping_asks_it_to_terminate(self):
        self.backend.kick(self.identifier)
        self.backend.request_stop(self.identifier)
        self.assertEqual(
            self.runner.commands,
            [
                ["launchctl", "kickstart", self.target],
                ["launchctl", "kill", "SIGTERM", self.target],
            ],
        )


class LivenessProbeTests(BackendTestCase):
    def setUp(self):
        super().setUp()
        self.identifier = "com.coghex.drain-prs.acme.widgets"
        self.target = self.backend.manager_target(self.identifier)

    def probe(self, proc):
        self.answer(["launchctl", "print", self.target], proc)
        return (
            self.backend.is_loaded(self.identifier),
            self.backend.is_running(self.identifier),
        )

    def test_an_unknown_job_is_a_normal_answer_rather_than_a_failure(self):
        # The probe runs unchecked: a stopped or never-installed drainer is
        # what `status` reports every ten seconds, and raising here would turn
        # the ordinary case into an error.
        self.assertEqual(self.probe(_completed(1, stderr="Could not find")), (False, False))

    def test_a_loaded_but_idle_job_is_loaded_and_not_running(self):
        self.assertEqual(self.probe(_completed(0, stdout="state = not running\n")), (True, False))

    def test_a_running_state_and_a_live_pid_each_report_running(self):
        self.assertEqual(self.probe(_completed(0, stdout="\tstate = running\n"))[1], True)
        self.assertEqual(self.probe(_completed(0, stdout="\tpid = 4242\n"))[1], True)
        self.assertEqual(self.probe(_completed(0, stdout="\tpid = 0\n"))[1], False)

    def test_the_probe_reads_both_streams(self):
        self.assertEqual(self.probe(_completed(0, stderr="\tstate = running\n"))[1], True)


class LegacySingletonTests(BackendTestCase):
    def write_legacy(self, document):
        service_manager.LEGACY_PLIST_PATH.write_bytes(plistlib.dumps(document))

    def test_no_singleton_is_installed(self):
        self.assertFalse(self.backend.legacy_definition_exists())
        self.assertIsNone(self.backend.legacy_service_repository())

    def test_the_checkout_is_read_out_of_the_definition(self):
        self.write_legacy(
            {
                "Label": service_manager.LEGACY_LABEL,
                "ProgramArguments": ["/usr/bin/python3", "x.py", "--path", "/a/repo"],
                "WorkingDirectory": "/other",
            }
        )
        self.assertTrue(self.backend.legacy_definition_exists())
        self.assertEqual(
            self.backend.legacy_service_repository(), Path("/a/repo")
        )

    def test_the_working_directory_answers_when_no_path_argument_does(self):
        self.write_legacy({"WorkingDirectory": "/other"})
        self.assertEqual(self.backend.legacy_service_repository(), Path("/other"))

    def test_an_unreadable_definition_names_no_checkout(self):
        service_manager.LEGACY_PLIST_PATH.write_bytes(b"not a plist at all")
        self.assertTrue(self.backend.legacy_definition_exists())
        self.assertIsNone(self.backend.legacy_service_repository())

    def test_retiring_unloads_the_singleton_before_setting_it_aside(self):
        self.write_legacy({"WorkingDirectory": "/other"})
        target = self.backend.manager_target(service_manager.LEGACY_LABEL)
        self.answer(["launchctl", "print", target], _completed(0))
        retired = self.backend.retire_legacy()
        self.assertEqual(
            self.runner.commands,
            [
                ["launchctl", "print", target],
                ["launchctl", "bootout", target],
            ],
        )
        self.assertFalse(service_manager.LEGACY_PLIST_PATH.exists())
        self.assertTrue(retired.is_file())
        self.assertEqual(retired.name, f"{service_manager.LEGACY_LABEL}.plist.retired")

    def test_an_unloaded_singleton_is_set_aside_without_a_bootout(self):
        self.write_legacy({"WorkingDirectory": "/other"})
        target = self.backend.manager_target(service_manager.LEGACY_LABEL)
        self.answer(["launchctl", "print", target], _completed(1))
        self.backend.retire_legacy()
        self.assertEqual(
            [args[:2] for args in self.runner.commands], [["launchctl", "print"]]
        )
        self.assertFalse(service_manager.LEGACY_PLIST_PATH.exists())


class FailureVocabularyTests(BackendTestCase):
    """A command that fails crosses this boundary as the *caller's* error.

    The controller reports `ServiceError` and the installer `InstallError`;
    both inject the wrapper that raises theirs, so neither has to translate a
    third exception type at every call site.
    """

    def test_a_failing_command_raises_the_injected_runners_error(self):
        target = self.backend.manager_target("com.example.job")
        self.answer(["launchctl", "kickstart", target], _completed(1, stderr="boom"))
        with self.assertRaises(RunnerError):
            self.backend.kick("com.example.job")


class BackendSelectionTests(BackendTestCase):
    def test_launchd_is_the_only_backend_selected(self):
        self.assertIsInstance(
            service_manager.select_backend(self.runner), service_manager.LaunchdBackend
        )

    def test_the_backend_implements_the_whole_boundary(self):
        # A backend missing a capability would send its caller back to
        # building the command itself, which is what this seam exists to
        # prevent — so the abstract base is what the callers may rely on.
        for name in vars(service_manager.ServiceManagerBackend):
            if name.startswith("_"):
                continue
            self.assertTrue(
                callable(getattr(self.backend, name)), name
            )


if __name__ == "__main__":
    unittest.main()
