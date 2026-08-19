"""Unit tests for the service-manager backends.

Everything here runs against a scripted runner and a temporary definition
directory: no test invokes `launchctl` or `systemctl`, and none writes under
the real ~/Library/LaunchAgents or ~/.config/systemd/user.

Nothing here asks the host which backend it has, either. Every backend under
test is constructed directly, and the one group that *is* about selection
drives the probes rather than the machine — so this suite answers the same on
a macOS laptop, a Linux CI runner, and a container with no user session.
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
        # Constructed rather than selected: what this group is about is the
        # launchd backend's behavior, and routing through `select_backend`
        # would make every assertion below depend on the host running it.
        self.backend = service_manager.LaunchdBackend(self.runner)

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


class LaunchdDefinitionEnvironmentTests(BackendTestCase):
    """Issue #367: the read-back counterpart of the environment a definition
    carries.

    A relocation has to ask each installed job which installation it names,
    because `KANBAN_DRAINER_INSTALL_DIR` is what decides where that job's
    runtime state lives and `--install-dir` moves that state without moving
    the record it is discovered through. The answer has to be total on the
    same terms `legacy_service_repository` is: it is asked of jobs a
    half-finished install may have left in any state.
    """

    def test_the_environment_written_is_the_environment_read_back(self):
        definition = self.definition()
        self.backend.write_definition(definition)
        self.assertEqual(
            self.backend.definition_environment(definition.identifier),
            dict(definition.environment),
        )

    def test_an_absent_definition_carries_no_variables_rather_than_failing(self):
        self.assertEqual(
            self.backend.definition_environment("com.example.never-installed"), {}
        )

    def test_a_malformed_definition_carries_no_variables_rather_than_failing(self):
        for payload in (b"not a plist at all", plistlib.dumps(["a", "list"])):
            with self.subTest(payload=payload[:12]):
                path = self.backend.definition_path("com.example.job")
                path.write_bytes(payload)
                self.assertEqual(
                    self.backend.definition_environment("com.example.job"), {}
                )

    def test_a_definition_with_no_environment_block_carries_no_variables(self):
        path = self.backend.definition_path("com.example.job")
        path.write_bytes(plistlib.dumps({"Label": "com.example.job"}))
        self.assertEqual(self.backend.definition_environment("com.example.job"), {})

    def test_non_string_entries_are_dropped_rather_than_returned(self):
        path = self.backend.definition_path("com.example.job")
        path.write_bytes(
            plistlib.dumps({"EnvironmentVariables": {"HOME": "/home", "N": 4}})
        )
        self.assertEqual(
            self.backend.definition_environment("com.example.job"), {"HOME": "/home"}
        )


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


class LaunchdUninstallTests(BackendTestCase):
    """Removing one repository's job through the seam.

    The capability issue #329 added: this boundary could install and load a
    job but never take one away, so removing a repository meant hand-editing
    the manager's own directory — the leak the boundary exists to prevent.
    """

    def setUp(self):
        super().setUp()
        self.identifier = "com.coghex.drain-prs.acme.widgets"
        self.target = self.backend.manager_target(self.identifier)

    def test_a_loaded_job_is_booted_out_before_its_plist_is_unlinked(self):
        # Never the other way round: launchd re-bootstraps whatever is still
        # in ~/Library/LaunchAgents at login, so unlinking first would leave a
        # job loaded in this session that nothing on disk describes.
        path = self.backend.write_definition(self.definition(self.identifier))
        self.answer(["launchctl", "print", self.target], _completed(0))
        outcome = self.backend.uninstall_definition(self.identifier)
        self.assertEqual(
            self.runner.commands,
            [
                ["launchctl", "print", self.target],
                ["launchctl", "bootout", self.target],
            ],
        )
        self.assertEqual(outcome, service_manager.UninstallOutcome(True, True))
        self.assertFalse(path.exists())

    def test_an_unloaded_job_is_unlinked_without_a_bootout(self):
        self.backend.write_definition(self.definition(self.identifier))
        self.answer(["launchctl", "print", self.target], _completed(1))
        outcome = self.backend.uninstall_definition(self.identifier)
        self.assertEqual(
            [args[:2] for args in self.runner.commands], [["launchctl", "print"]]
        )
        self.assertEqual(outcome, service_manager.UninstallOutcome(False, True))

    def test_an_already_removed_job_is_reported_rather_than_raised(self):
        # Repairing a half-finished uninstall is at least as common a reason
        # to be here as performing a whole one, and an absent definition is
        # the ordinary shape of that.
        self.answer(["launchctl", "print", self.target], _completed(1))
        self.assertEqual(
            self.backend.uninstall_definition(self.identifier),
            service_manager.UninstallOutcome(False, False),
        )

    def test_removing_one_job_leaves_every_sibling_definition_alone(self):
        other = "com.coghex.drain-prs.acme.gadgets"
        self.backend.write_definition(self.definition(self.identifier))
        self.backend.write_definition(self.definition(other))
        self.answer(["launchctl", "print", self.target], _completed(1))
        self.backend.uninstall_definition(self.identifier)
        self.assertEqual(
            sorted(path.name for path in self.launch_agents.iterdir()),
            [f"{other}.plist"],
        )


class SystemdBackendTestCase(unittest.TestCase):
    """The systemd backend against a temporary unit directory and a scripted
    `systemctl`. Nothing here needs a user session, or a Linux host."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.units = Path(self.tmp.name) / "systemd" / "user"
        self.units.mkdir(parents=True)
        patched = mock.patch.object(service_manager, "SYSTEMD_USER_DIR", self.units)
        patched.start()
        self.addCleanup(patched.stop)
        self.runner = ScriptedRunner(RunnerError)
        self.backend = service_manager.SystemdBackend(self.runner)
        self.unit = self.backend.service_identifier("acme.widgets")

    def definition(self, identifier=None, **overrides):
        fields = {
            "identifier": identifier or self.unit,
            "program_arguments": ["/usr/bin/python3", "/install/controller.py", "run"],
            "working_directory": "/checkout",
            "environment": {"HOME": "/home", "PYTHONUNBUFFERED": "1"},
            "stdout_path": "/logs/service.out",
            "stderr_path": "/logs/service.err",
        }
        fields.update(overrides)
        return service_manager.ServiceDefinition(**fields)

    def answer(self, args, proc):
        self.runner.answers[tuple(args)] = proc

    def show(self, name, value, returncode=0):
        self.answer(
            ["systemctl", "--user", "show", self.unit, "--property", name, "--value"],
            _completed(returncode, stdout=value),
        )

    def directives(self, payload=None):
        rendered = (
            payload
            if payload is not None
            else self.backend.render_definition(self.definition())
        )
        return [line for line in rendered.decode("utf-8").splitlines() if line]


class SystemdNamingTests(SystemdBackendTestCase):
    def test_the_unit_reuses_the_label_prefix_slug_and_length_discipline(self):
        # Same prefix and same slug as the LaunchAgent label, plus the suffix
        # systemd needs to read the name as a service. Re-escaping the slug
        # here would give the unit a name the runtime and log directories are
        # no longer partitioned by.
        self.assertEqual(self.unit, "com.coghex.drain-prs.acme.widgets.service")
        self.assertEqual(self.backend.definition_path(self.unit), self.units / self.unit)
        room = (
            service_manager.MAX_LABEL_LENGTH
            - len(service_manager.LABEL_PREFIX)
            - 1
            - len(service_manager.SYSTEMD_UNIT_SUFFIX)
        )
        self.assertTrue(self.backend.identifier_fits("a" * room))
        self.assertFalse(self.backend.identifier_fits("a" * (room + 1)))

    def test_every_character_a_slug_can_carry_is_valid_in_a_unit_name(self):
        # `repository_slug` escapes each identity segment into `[A-Za-z0-9_-]`
        # and joins them with one `.`, and systemd accepts all of those. A
        # name outside that set would be refused by `daemon-reload` rather
        # than by anything this repository controls.
        allowed = set(
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."
        )
        self.assertLessEqual(set(self.backend.service_identifier("a-b--c-d.w_9")), allowed)

    def test_the_target_names_the_user_manager_holding_the_unit(self):
        self.assertEqual(
            self.backend.manager_target(self.unit),
            service_manager.systemd_target_for(self.unit),
        )
        self.assertTrue(self.backend.manager_target(self.unit).endswith(f"/{self.unit}"))

    def test_the_unit_directory_follows_systemds_own_xdg_rule(self):
        # systemd searches `$XDG_CONFIG_HOME/systemd/user` when that variable
        # names an absolute directory and `~/.config/systemd/user` otherwise,
        # and it searches exactly one of them. Writing to the other leaves a
        # unit the user manager never loads.
        with mock.patch.dict(service_manager.os.environ, {"XDG_CONFIG_HOME": "/xdg"}):
            self.assertEqual(
                service_manager._systemd_user_dir(), Path("/xdg/systemd/user")
            )
        for value in ("", "relative/config"):
            with mock.patch.dict(
                service_manager.os.environ, {"XDG_CONFIG_HOME": value}
            ):
                self.assertEqual(
                    service_manager._systemd_user_dir(),
                    service_manager.HOME / ".config" / "systemd" / "user",
                )


class SystemdDefinitionTests(SystemdBackendTestCase):
    def test_the_unit_carries_every_service_definition_promise(self):
        directives = self.directives()
        self.assertIn("[Service]", directives)
        self.assertIn("Type=exec", directives)
        self.assertIn("WorkingDirectory=/checkout", directives)
        self.assertIn("StandardOutput=append:/logs/service.out", directives)
        self.assertIn("StandardError=append:/logs/service.err", directives)
        self.assertIn('Environment="HOME=/home"', directives)
        self.assertIn('Environment="PYTHONUNBUFFERED=1"', directives)
        # Non-resident and on-demand, which is what RunAtLoad=false plus
        # KeepAlive=false buys on the other backend: nothing restarts it, and
        # with no [Install] section nothing enables it, so no login starts it.
        self.assertIn("Restart=no", directives)
        self.assertNotIn("[Install]", directives)
        self.assertFalse(any(line.startswith("WantedBy=") for line in directives))
        # Only the main process is signalled, so the runner performs its own
        # shutdown and forwards to its child exactly as it does under launchd.
        self.assertIn("KillSignal=SIGTERM", directives)
        self.assertIn("KillMode=mixed", directives)

    def test_the_exec_start_is_the_exact_argv_with_no_shell_between(self):
        rendered = self.backend.render_definition(
            self.definition(
                program_arguments=["/usr/bin/python3", "/a b/c.py", "--repo", "a/b"]
            )
        )
        self.assertIn(
            'ExecStart="/usr/bin/python3" "/a b/c.py" "--repo" "a/b"',
            self.directives(rendered),
        )

    def test_a_value_systemd_would_reinterpret_is_escaped_rather_than_passed(self):
        # `%` introduces a specifier systemd expands, and `"` would end the
        # word: a checkout path is not this module's to choose, so both have
        # to survive as themselves.
        rendered = self.backend.render_definition(
            self.definition(
                program_arguments=["/usr/bin/python3", '/tmp/100%/say "hi"/c.py'],
                working_directory="/tmp/100%",
            )
        )
        directives = self.directives(rendered)
        self.assertIn(
            'ExecStart="/usr/bin/python3" "/tmp/100%%/say \\"hi\\"/c.py"', directives
        )
        self.assertIn("WorkingDirectory=/tmp/100%%", directives)

    def test_a_path_directive_is_percent_escaped_and_never_quoted(self):
        # Established against real systemd (255.9 and 257.9), because guessing
        # gets this wrong in both directions:
        #
        #   * `WorkingDirectory=`, `StandardOutput=` and `StandardError=` are
        #     NOT unquoted or unescaped. A backslash and a double quote in the
        #     value round-trip verbatim, and `systemctl show` reports the path
        #     unchanged — so they need no escaping. Quoting them instead makes
        #     the unit invalid outright: systemd refuses to start it with "has
        #     a bad unit file setting".
        #   * Specifiers ARE expanded, so `%` must still be doubled. A bare
        #     `%n` in a path becomes the unit's own name.
        #
        # `ExecStart` is the opposite on both counts, which is why the two are
        # rendered by different helpers.
        awkward = '/tmp/dir with space and \\ backslash and " quote and %n'
        rendered = self.backend.render_definition(
            self.definition(
                working_directory=awkward,
                stdout_path=awkward + "/out",
                stderr_path=awkward + "/err",
            )
        )
        directives = self.directives(rendered)
        expected = '/tmp/dir with space and \\ backslash and " quote and %%n'
        self.assertIn(f"WorkingDirectory={expected}", directives)
        self.assertIn(f"StandardOutput=append:{expected}/out", directives)
        self.assertIn(f"StandardError=append:{expected}/err", directives)
        # Never quoted: a leading `"` is what makes systemd read the value as
        # a quoted string, and for these three settings that is the rejection
        # above rather than an unquoted path.
        for directive in directives:
            if directive.startswith(("WorkingDirectory=", "StandardOutput=", "StandardError=")):
                self.assertFalse(directive.split("=", 1)[1].startswith('"'), directive)

    def test_a_line_break_is_refused_rather_than_written_into_the_unit(self):
        # The one input that cannot be escaped into safety: it would end the
        # directive and leave the rest of the value being read as unit syntax.
        with self.assertRaises(service_manager.ServiceManagerError):
            self.backend.render_definition(
                self.definition(working_directory="/a\nExecStart=/bin/sh")
            )

    def test_the_written_unit_is_the_rendered_one_and_is_readable(self):
        path = self.backend.write_definition(self.definition())
        self.assertEqual(path, self.units / self.unit)
        self.assertEqual(
            path.read_bytes(), self.backend.render_definition(self.definition())
        )
        self.assertEqual(path.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.runner.commands, [])


class SystemdLifecycleTests(SystemdBackendTestCase):
    def test_loading_reloads_the_manager_and_clears_any_prior_failure(self):
        # `daemon-reload` is systemd's bootstrap; `reset-failed` is the other
        # half of what launchd's bootout/bootstrap pair does, and runs
        # unchecked because a unit that never failed is not an error.
        self.backend.load_definition(self.unit)
        self.assertEqual(
            self.runner.commands,
            [
                ["systemctl", "--user", "daemon-reload"],
                ["systemctl", "--user", "reset-failed", self.unit],
            ],
        )

    def test_loading_never_enables_or_starts_the_unit(self):
        self.backend.load_definition(self.unit)
        self.assertFalse(
            any(
                "enable" in args or "start" in args
                for args in self.runner.commands
            )
        )

    def test_a_failing_reset_is_an_answer_rather_than_a_failure(self):
        self.answer(["systemctl", "--user", "reset-failed", self.unit], _completed(1))
        self.backend.load_definition(self.unit)

    def test_starting_blocks_and_stopping_does_not(self):
        # `Type=exec` returns as soon as the runner is executed, so a checked
        # start reports a unit that could not start at all; a stop must return
        # immediately because the caller's own timeout loop is what confirms
        # the exit, exactly as it does for `launchctl kill`.
        self.backend.kick(self.unit)
        self.backend.request_stop(self.unit)
        self.assertEqual(
            self.runner.commands,
            [
                ["systemctl", "--user", "start", self.unit],
                ["systemctl", "--user", "--no-block", "stop", self.unit],
            ],
        )

    def test_a_failing_start_raises_the_injected_runners_error(self):
        self.answer(
            ["systemctl", "--user", "start", self.unit], _completed(1, stderr="boom")
        )
        with self.assertRaises(RunnerError):
            self.backend.kick(self.unit)


class SystemdLivenessProbeTests(SystemdBackendTestCase):
    def test_a_unit_the_manager_never_heard_of_is_a_normal_answer(self):
        # What `status` asks every ten seconds about a stopped or
        # never-installed drainer. `show` prints this and exits zero.
        self.show("LoadState", "not-found\n")
        self.show("ActiveState", "inactive\n")
        self.show("MainPID", "0\n")
        self.assertFalse(self.backend.is_loaded(self.unit))
        self.assertFalse(self.backend.is_running(self.unit))

    def test_a_loaded_but_idle_unit_is_loaded_and_not_running(self):
        self.show("LoadState", "loaded\n")
        self.show("ActiveState", "inactive\n")
        self.show("MainPID", "0\n")
        self.assertTrue(self.backend.is_loaded(self.unit))
        self.assertFalse(self.backend.is_running(self.unit))

    def test_an_active_state_and_a_live_main_pid_each_report_running(self):
        for state, pid, expected in (
            ("active", "4242", True),
            ("activating", "0", True),
            ("failed", "4242", True),
            ("failed", "0", False),
            ("inactive", "0", False),
        ):
            with self.subTest(state=state, pid=pid):
                self.show("ActiveState", state + "\n")
                self.show("MainPID", pid + "\n")
                self.assertEqual(self.backend.is_running(self.unit), expected)

    def test_a_systemctl_that_could_not_run_is_not_a_job(self):
        self.show("LoadState", "", returncode=1)
        self.show("ActiveState", "", returncode=1)
        self.show("MainPID", "", returncode=1)
        self.assertFalse(self.backend.is_loaded(self.unit))
        self.assertFalse(self.backend.is_running(self.unit))


class SystemdDefinitionEnvironmentTests(SystemdBackendTestCase):
    """Issue #367: the same read-back, off a unit file.

    A unit carries its environment as quoted words rather than as a
    dictionary, so this is the half where the reader has to reverse exactly
    what the writer did — including a value holding whitespace, a quote, a
    backslash, or the `%` systemd would otherwise expand as a specifier.
    """

    def test_the_environment_written_is_the_environment_read_back(self):
        definition = self.definition(
            environment={
                "HOME": "/home",
                "KANBAN_DRAINER_INSTALL_DIR": "/data/kanban/pr-drainer",
                "AWKWARD": 'a b "c" \\ 100%',
            }
        )
        self.backend.write_definition(definition)
        self.assertEqual(
            self.backend.definition_environment(definition.identifier),
            dict(definition.environment),
        )

    def test_an_absent_unit_carries_no_variables_rather_than_failing(self):
        self.assertEqual(self.backend.definition_environment(self.unit), {})

    def test_a_malformed_unit_carries_no_variables_rather_than_failing(self):
        for payload in (b"\xff\xfe not utf-8", b"[Service]\nEnvironment=\nRestart=no\n"):
            with self.subTest(payload=payload[:12]):
                self.backend.definition_path(self.unit).write_bytes(payload)
                self.assertEqual(self.backend.definition_environment(self.unit), {})

    def test_a_directory_where_the_unit_belongs_carries_no_variables(self):
        self.backend.definition_path(self.unit).mkdir()
        self.assertEqual(self.backend.definition_environment(self.unit), {})

    def test_only_the_environment_directives_are_read(self):
        self.backend.write_definition(self.definition())
        self.assertEqual(
            sorted(self.backend.definition_environment(self.unit)),
            ["HOME", "PYTHONUNBUFFERED"],
        )


class SystemdUninstallTests(SystemdBackendTestCase):
    def test_the_unit_file_goes_before_the_reload_that_forgets_it(self):
        # `daemon-reload` is what makes the user manager forget a unit, and it
        # can only forget one whose file is already gone.
        path = self.backend.write_definition(self.definition())
        self.show("LoadState", "loaded\n")
        outcome = self.backend.uninstall_definition(self.unit)
        self.assertFalse(path.exists())
        self.assertEqual(
            self.runner.commands[-2:],
            [
                ["systemctl", "--user", "daemon-reload"],
                ["systemctl", "--user", "reset-failed", self.unit],
            ],
        )
        self.assertEqual(outcome, service_manager.UninstallOutcome(True, True))

    def test_an_already_removed_unit_is_reported_rather_than_raised(self):
        self.show("LoadState", "not-found\n")
        self.assertEqual(
            self.backend.uninstall_definition(self.unit),
            service_manager.UninstallOutcome(False, False),
        )

    def test_removing_one_unit_leaves_every_sibling_alone(self):
        other = self.backend.service_identifier("acme.gadgets")
        self.backend.write_definition(self.definition())
        self.backend.write_definition(self.definition(other))
        self.show("LoadState", "loaded\n")
        self.backend.uninstall_definition(self.unit)
        self.assertEqual(sorted(path.name for path in self.units.iterdir()), [other])


class SystemdLegacySingletonTests(SystemdBackendTestCase):
    """There has never been a systemd singleton.

    The machine-wide job predates per-repository units and only ever existed
    under launchd, so these operations must answer "nothing to retire" — and
    must not reach for a launchd artifact on a host that has none.
    """

    def test_no_singleton_is_ever_reported_or_read(self):
        self.assertFalse(self.backend.legacy_definition_exists())
        self.assertIsNone(self.backend.legacy_service_repository())
        self.assertEqual(self.runner.commands, [])

    def test_the_singleton_names_a_unit_rather_than_a_plist(self):
        self.assertEqual(
            self.backend.legacy_identifier(), service_manager.LEGACY_UNIT_NAME
        )
        self.assertEqual(
            self.backend.legacy_definition_path(),
            self.units / service_manager.LEGACY_UNIT_NAME,
        )

    def test_retiring_refuses_rather_than_touching_a_launchd_artifact(self):
        with self.assertRaises(service_manager.ServiceManagerError):
            self.backend.retire_legacy()


class RecordEntryTests(SystemdBackendTestCase):
    """The discovery record as a discriminated union, from the writing side."""

    def test_each_backend_names_itself_and_its_own_keys(self):
        launchd = service_manager.LaunchdBackend(self.runner)
        self.assertEqual(
            launchd.record_entry("com.example.drain", Path("/tmp/x.plist")),
            {
                "backend": "launchd",
                "launchd_label": "com.example.drain",
                "plist_path": "/tmp/x.plist",
            },
        )
        self.assertEqual(
            self.backend.record_entry(self.unit, self.units / self.unit),
            {
                "backend": "systemd",
                "systemd_unit": self.unit,
                "unit_path": str(self.units / self.unit),
            },
        )

    def test_neither_backend_writes_the_other_backends_keys(self):
        # The mixed shape Kanban fails closed on. A writer that emitted both
        # would produce a record no reader may resolve.
        launchd = service_manager.LaunchdBackend(self.runner)
        launchd_keys = set(launchd.record_entry("x", Path("/tmp/x.plist")))
        systemd_keys = set(self.backend.record_entry("x.service", Path("/tmp/x.service")))
        self.assertEqual(launchd_keys & systemd_keys, {"backend"})

    def test_the_owned_key_set_covers_every_key_any_backend_writes(self):
        # `RECORD_KEYS` is what a writer clears before restating its own, so a
        # backend whose keys escaped it would leave the superseded manager's
        # keys in the entry — the mixed shape again, arrived at by reinstalling
        # rather than by hand-editing.
        launchd = service_manager.LaunchdBackend(self.runner)
        written = set(launchd.record_entry("x", Path("/tmp/x.plist"))) | set(
            self.backend.record_entry("x.service", Path("/tmp/x.service"))
        )
        self.assertEqual(written, set(service_manager.RECORD_KEYS))
        # And it covers nothing else: clearing a key an installer persisted —
        # `config_path` above all — would make a reinstall lose configuration.
        self.assertNotIn("config_path", service_manager.RECORD_KEYS)
        self.assertNotIn("repository", service_manager.RECORD_KEYS)

    def test_the_backend_name_is_the_discriminator_and_the_wording_noun(self):
        # One string with two jobs, so a record can never be keyed on a name
        # the messages do not use.
        launchd = service_manager.LaunchdBackend(self.runner)
        self.assertEqual(launchd.backend_name(), service_manager.LAUNCHD)
        self.assertEqual(self.backend.backend_name(), service_manager.SYSTEMD)
        self.assertEqual(launchd.definition_label(), "plist")
        self.assertEqual(self.backend.definition_label(), "unit")


class NamespaceTests(unittest.TestCase):
    """Two services share this boundary, and neither may name the other's job.

    Every case is asserted against both backends, because a namespace that
    partitioned launchd's identifiers but not systemd's would let one host
    install two services that collide and another install two that do not.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name, value in (
            ("LAUNCH_AGENTS_DIR", self.root / "LaunchAgents"),
            ("SYSTEMD_USER_DIR", self.root / "units"),
        ):
            patched = mock.patch.object(service_manager, name, value)
            patched.start()
            self.addCleanup(patched.stop)
        self.runner = ScriptedRunner(RunnerError)

    def backends(self, namespace):
        return (
            service_manager.LaunchdBackend(self.runner, namespace),
            service_manager.SystemdBackend(self.runner, namespace),
        )

    def test_the_drainers_identifiers_are_exactly_what_they_were(self):
        # A namespace argument that changed the default would rename every
        # installed drainer job on the next start, orphaning the one launchd or
        # systemd is already holding.
        launchd, systemd = self.backends(service_manager.DRAINER_NAMESPACE)
        self.assertEqual(
            launchd.service_identifier("acme.widgets"), "com.coghex.drain-prs.acme.widgets"
        )
        self.assertEqual(
            systemd.service_identifier("acme.widgets"),
            "com.coghex.drain-prs.acme.widgets.service",
        )
        # And the default is that namespace, so every existing caller is
        # unchanged by the argument's arrival.
        self.assertEqual(
            service_manager.LaunchdBackend(self.runner).service_identifier("acme.widgets"),
            launchd.service_identifier("acme.widgets"),
        )
        self.assertEqual(
            service_manager.SystemdBackend(self.runner).service_identifier("acme.widgets"),
            systemd.service_identifier("acme.widgets"),
        )

    def test_two_services_never_name_one_job_for_one_repository(self):
        for approval, drainer in zip(
            self.backends(service_manager.ISSUE_APPROVAL_NAMESPACE),
            self.backends(service_manager.DRAINER_NAMESPACE),
        ):
            with self.subTest(backend=approval.backend_name()):
                approval_identifier = approval.service_identifier("acme.widgets")
                drainer_identifier = drainer.service_identifier("acme.widgets")
                self.assertNotEqual(approval_identifier, drainer_identifier)
                self.assertNotEqual(
                    approval.definition_path(approval_identifier),
                    drainer.definition_path(drainer_identifier),
                )
                self.assertNotEqual(
                    approval.manager_target(approval_identifier),
                    drainer.manager_target(drainer_identifier),
                )

    def test_a_backend_reports_the_namespace_it_was_built_for(self):
        for backend in self.backends(service_manager.ISSUE_APPROVAL_NAMESPACE):
            with self.subTest(backend=backend.backend_name()):
                self.assertIs(
                    backend.namespace(), service_manager.ISSUE_APPROVAL_NAMESPACE
                )

    def test_a_namespace_with_no_singleton_has_none_to_name_or_retire(self):
        # "No singleton installed" and "this service never had one" are
        # different answers, and only the second may refuse to name an
        # identifier: inventing one would name a job no host has ever carried.
        for backend in self.backends(service_manager.ISSUE_APPROVAL_NAMESPACE):
            with self.subTest(backend=backend.backend_name()):
                self.assertFalse(backend.legacy_definition_exists())
                self.assertIsNone(backend.legacy_service_repository())
                with self.assertRaises(service_manager.ServiceManagerError):
                    backend.legacy_identifier()
                with self.assertRaises(service_manager.ServiceManagerError):
                    backend.retire_legacy()
        self.assertEqual(self.runner.commands, [])

    def test_the_slug_limit_leaves_room_for_every_backends_identifier(self):
        # The limit a caller partitions its runtime by has to be the smallest
        # any backend imposes, or a slug that named a directory perfectly well
        # would name a job label no manager could carry.
        for namespace in (
            service_manager.DRAINER_NAMESPACE,
            service_manager.ISSUE_APPROVAL_NAMESPACE,
        ):
            with self.subTest(namespace=namespace.name):
                limit = service_manager.namespace_slug_limit(namespace)
                backends = self.backends(namespace)
                for backend in backends:
                    self.assertTrue(backend.identifier_fits("a" * limit))
                    self.assertLessEqual(
                        len(backend.service_identifier("a" * limit)),
                        service_manager.MAX_LABEL_LENGTH,
                    )
                # And it is the largest such value: one more character stops
                # fitting somewhere, so the limit is not merely conservative.
                self.assertFalse(
                    all(backend.identifier_fits("a" * (limit + 1)) for backend in backends)
                )

    def test_the_limit_is_a_property_of_the_namespace_rather_than_the_host(self):
        # Asked without selecting a backend and without spawning anything, so a
        # foreground caller that has no service manager still names the same
        # directories as one that does.
        self.assertGreater(
            service_manager.namespace_slug_limit(service_manager.DRAINER_NAMESPACE),
            service_manager.namespace_slug_limit(
                service_manager.ISSUE_APPROVAL_NAMESPACE
            ),
        )
        self.assertEqual(self.runner.commands, [])

    def test_an_approval_definition_describes_the_approval_service(self):
        definition = service_manager.ServiceDefinition(
            identifier="com.coghex.issue-approval.acme.widgets.service",
            program_arguments=["/usr/bin/python3", "/install/controller.py", "run"],
            working_directory="/checkout",
            environment={},
            stdout_path="/logs/out",
            stderr_path="/logs/err",
        )
        unit = (
            service_manager.SystemdBackend(
                self.runner, service_manager.ISSUE_APPROVAL_NAMESPACE
            )
            .render_definition(definition)
            .decode("utf-8")
        )
        self.assertIn("Description=Kanban issue approval", unit)
        self.assertNotIn("PR drainer", unit)


class BackendSelectionTests(unittest.TestCase):
    """Which backend a host gets, decided by probing rather than by naming it.

    Each case drives `sys.platform`, `shutil.which`, and the `systemctl`
    session probe directly, because those three are exactly what the selection
    reads and because the host running the suite must not be able to change
    the answer.
    """

    def setUp(self):
        self.runner = ScriptedRunner(RunnerError)
        service_manager.reset_detection()
        self.addCleanup(service_manager.reset_detection)

    def host(self, platform, executables, *, session=0):
        self.enterContext(mock.patch.object(service_manager.sys, "platform", platform))
        self.enterContext(
            mock.patch.object(
                service_manager.shutil,
                "which",
                lambda name: f"/usr/bin/{name}" if name in executables else None,
            )
        )
        self.answer(
            ["systemctl", "--user", "show", "--property", "Version", "--value"],
            _completed(session, stdout="255\n" if session == 0 else ""),
        )

    def answer(self, args, proc):
        self.runner.answers[tuple(args)] = proc

    def test_a_macos_host_with_launchctl_selects_launchd(self):
        self.host("darwin", {"launchctl"})
        self.assertIsInstance(
            service_manager.select_backend(self.runner), service_manager.LaunchdBackend
        )
        # And it decides without spawning anything: the launchd probe is a
        # platform name and a PATH lookup, so no macOS install pays for the
        # systemd session probe.
        self.assertEqual(self.runner.commands, [])

    def test_a_linux_host_with_a_live_user_session_selects_systemd(self):
        self.host("linux", {"systemctl"})
        self.assertIsInstance(
            service_manager.select_backend(self.runner), service_manager.SystemdBackend
        )

    def test_a_host_with_systemctl_but_no_session_is_refused(self):
        # `systemctl` on PATH manages nothing without a user manager behind it
        # — no XDG_RUNTIME_DIR, no `user@<uid>.service`, a container without
        # one — and installing against it would write a unit nothing loads.
        self.host("linux", {"systemctl"}, session=1)
        with self.assertRaises(service_manager.NoServiceManagerError) as raised:
            service_manager.select_backend(self.runner)
        self.assertIn("No supported service manager found", str(raised.exception))

    def test_a_host_with_neither_executable_is_refused(self):
        self.host("linux", set())
        with self.assertRaises(service_manager.NoServiceManagerError):
            service_manager.select_backend(self.runner)
        # Absent `systemctl` is answered without probing a session at all.
        self.assertEqual(self.runner.commands, [])

    def test_a_macos_host_without_launchctl_falls_through_rather_than_assuming(self):
        # The platform name alone is not the question. A darwin host with no
        # `launchctl` manages nothing through this seam, and is refused with
        # the same message any other unmanageable host gets.
        self.host("darwin", set())
        with self.assertRaises(service_manager.NoServiceManagerError):
            service_manager.select_backend(self.runner)

    def test_an_ambiguous_host_resolves_to_launchd_every_time(self):
        # Both probes answer yes. The order is what makes the selection
        # deterministic: a macOS host that also has `systemctl` installed must
        # not manage its drainer differently from one that does not.
        self.host("darwin", {"launchctl", "systemctl"})
        for _ in range(3):
            service_manager.reset_detection()
            self.assertIsInstance(
                service_manager.select_backend(self.runner),
                service_manager.LaunchdBackend,
            )

    def test_the_host_is_probed_once_and_the_answer_reused(self):
        # `service_backend()` resolves afresh on every use, including inside
        # the quarter-second loops that wait out a start or a stop, so a probe
        # that spawned `systemctl` each time would put a subprocess in each of
        # them.
        self.host("linux", {"systemctl"})
        for _ in range(5):
            service_manager.select_backend(self.runner)
        self.assertEqual(
            self.runner.commands,
            [["systemctl", "--user", "show", "--property", "Version", "--value"]],
        )

    def test_each_detected_name_maps_to_exactly_one_backend(self):
        for name, expected in (
            (service_manager.LAUNCHD, service_manager.LaunchdBackend),
            (service_manager.SYSTEMD, service_manager.SystemdBackend),
        ):
            self.assertIsInstance(
                service_manager.backend_for(name, self.runner), expected
            )
        with self.assertRaises(service_manager.ServiceManagerError):
            service_manager.backend_for("upstart", self.runner)

    def test_every_backend_implements_the_whole_boundary(self):
        # A backend missing a capability would send its caller back to
        # building the command itself, which is what this seam exists to
        # prevent — so the abstract base is what the callers may rely on, and
        # every backend has to satisfy all of it rather than most of it.
        for backend in (
            service_manager.LaunchdBackend(self.runner),
            service_manager.SystemdBackend(self.runner),
        ):
            for name in vars(service_manager.ServiceManagerBackend):
                if name.startswith("_"):
                    continue
                self.assertTrue(callable(getattr(backend, name)), name)


if __name__ == "__main__":
    unittest.main()
