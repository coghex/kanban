"""Unit tests for the tracked LaunchAgent controller.

Every test that touches a path redirects it: nothing here may write to the
real ~/Library/LaunchAgents or ~/Library/Application Support/kanban, and no
test invokes launchctl, git against a real remote, or a network.
"""

import contextlib
import fcntl
import json
import os
import plistlib
import re
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

import drain_prs
import drain_prs_service
import service_manager


def _completed(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


def rendered_definition(job):
    """The bytes the selected backend writes for `job`, through the same seam
    `install_job` writes them through."""
    return drain_prs_service.service_backend().render_definition(
        drain_prs_service.service_definition(job)
    )


class RecordingBackend(service_manager.ServiceManagerBackend):
    """A stand-in service manager that records what it was asked to do.

    It spawns nothing, so a lifecycle driven through it proves the controller
    reaches its service manager only through this boundary — anything left
    behind would still show up as a `launchctl` argument vector in the
    fixture's own command log. Its identifiers deliberately do not look like
    launchd's, so a job named by the real derivation could not pass for one
    named through the seam.
    """

    def __init__(self, definitions_dir, *, loaded=False, running=False):
        self.calls = []
        self.definitions_dir = definitions_dir
        self.loaded = loaded
        self.running = running
        self.legacy_installed = False
        self.legacy_repository = None
        self.written = []

    def _record(self, name, *arguments):
        self.calls.append((name, *arguments))

    def names(self):
        return [call[0] for call in self.calls]

    def service_identifier(self, slug):
        return f"fake-service.{slug}"

    def identifier_fits(self, slug):
        return len(slug) <= 40

    def legacy_identifier(self):
        return "fake-service.legacy"

    def definition_path(self, identifier):
        return self.definitions_dir / f"{identifier}.definition"

    def legacy_definition_path(self):
        return self.definitions_dir / "legacy.definition"

    def manager_target(self, identifier):
        return f"fake-manager/{identifier}"

    def render_definition(self, definition):
        return f"definition for {definition.identifier}".encode("utf-8")

    def write_definition(self, definition):
        self._record("write_definition", definition.identifier)
        path = self.definition_path(definition.identifier)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(self.render_definition(definition))
        self.written.append(definition)
        return path

    def load_definition(self, identifier):
        self._record("load_definition", identifier)
        self.loaded = True

    def is_loaded(self, identifier):
        return self.loaded

    def is_running(self, identifier):
        self._record("is_running", identifier)
        return self.running

    def kick(self, identifier):
        self._record("kick", identifier)

    def request_stop(self, identifier):
        self._record("request_stop", identifier)

    def legacy_definition_exists(self):
        return self.legacy_installed

    def legacy_service_repository(self):
        return self.legacy_repository

    def retire_legacy(self):
        self._record("retire_legacy")
        self.legacy_installed = False
        return self.definitions_dir / "legacy.definition.retired"


class RedirectedControllerTestCase(unittest.TestCase):
    """Points every root the controller writes under at a temporary directory,
    and answers `launchctl` and `git` from a scripted fake."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.launch_agents = self.root / "LaunchAgents"
        self.launch_agents.mkdir()
        self.install_dir = self.root / "install"
        self.record = self.install_dir / "config.json"
        self.runtime_root = self.root / "runtime"
        self.log_root = self.root / "logs"
        for name, value in (
            ("INSTALL_DIR", self.install_dir),
            ("CONTROLLER_PATH", self.install_dir / "drain_prs_service.py"),
            ("DRAINER_PATH", self.install_dir / "drain_prs.py"),
            ("CONFIG_MODULE_PATH", self.install_dir / "kanban_config.py"),
            (
                "SERVICE_MANAGER_MODULE_PATH",
                self.install_dir / "service_manager.py",
            ),
            ("RUNTIME_ROOT", self.runtime_root),
            ("LOG_ROOT", self.log_root),
            ("DISCOVERY_RECORD_PATH", self.record),
            ("CONFIG_PATH", self.record),
            ("LEGACY_CONFIG_PATH", self.root / "elsewhere" / "config.json"),
            ("NTFY_URL", None),
        ):
            patched = mock.patch.object(drain_prs_service, name, value)
            patched.start()
            self.addCleanup(patched.stop)

        # The launchd artifacts belong to the backend, so they are redirected
        # on the module that owns them rather than on the controller.
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

        # Scripted external state: which labels launchd has loaded, what each
        # checkout's remote answers, and which git directory a checkout shares
        # — the last of which is a linked worktree's primary checkout.
        self.loaded = set()
        self.remotes = {}
        self.common_dirs = {}
        self.commands = []
        patched = mock.patch.object(
            drain_prs_service, "run_command", side_effect=self._run_command
        )
        patched.start()
        self.addCleanup(patched.stop)

        # The installed-source audit reads real git in a real checkout, which
        # no test here may depend on. It is stubbed silent by default and kept
        # reachable for the tests that are actually about it.
        self.real_audit_installed_sources = drain_prs_service.audit_installed_sources
        patched = mock.patch.object(
            drain_prs_service,
            "audit_installed_sources",
            return_value=drain_prs_service.SourceAudit(),
        )
        patched.start()
        self.addCleanup(patched.stop)

    def _run_command(self, args, *, check=True):
        self.commands.append(list(args))
        if args[:2] == ["launchctl", "print"]:
            return _completed(0 if args[2] in self.loaded else 1)
        if args[:2] == ["launchctl", "bootout"]:
            self.loaded.discard(args[2])
            return _completed(0)
        if args[:2] == ["launchctl", "bootstrap"]:
            return _completed(0)
        if args[0] == "git" and args[3:5] == ["remote", "get-url"]:
            url = self.remotes.get((args[2], args[5]))
            if url is None:
                return _completed(1, stderr=f"error: No such remote '{args[5]}'")
            return _completed(0, stdout=url + "\n")
        if args[0] == "git" and args[3:] == ["rev-parse", "--absolute-git-dir"]:
            return _completed(0, stdout=str(Path(args[2]) / ".git") + "\n")
        if args[0] == "git" and args[3:] == ["rev-parse", "--git-common-dir"]:
            shared = self.common_dirs.get(args[2], str(Path(args[2]) / ".git"))
            return _completed(0, stdout=shared + "\n")
        return _completed(0)

    def checkout(self, name, remote_url, **other_remotes):
        """A checkout directory whose `origin` answers `remote_url`, plus any
        further named remotes given as keyword arguments."""
        path = self.root / name
        (path / ".git").mkdir(parents=True)
        self.remotes[(str(path), "origin")] = remote_url
        for remote_name, url in other_remotes.items():
            self.remotes[(str(path), remote_name)] = url
        return path

    def install(self, job):
        with (
            mock.patch.object(
                drain_prs_service, "status_snapshot", return_value={"state": "stopped"}
            ),
        ):
            result = drain_prs_service.install_job(job)
        self.loaded.add(service_manager.launch_target_for(job.label))
        return result

    def read_record(self):
        return json.loads(self.record.read_text(encoding="utf-8"))

    def write_status(self, job, repo_path, pid=None):
        job.runtime_dir.mkdir(parents=True, exist_ok=True)
        job.status_path.write_text(
            json.dumps(
                {
                    "state": "running",
                    "runner_pid": pid or os.getpid(),
                    "drainer_pid": pid or os.getpid(),
                    "repo": str(repo_path),
                }
            ),
            encoding="utf-8",
        )


class RepositoryIdentityTests(unittest.TestCase):
    """A drainer is named by the canonical GitHub repository its checkout is a
    clone of, so what counts as one has to match Kanban's own resolver."""

    def test_accepts_every_supported_github_form(self):
        for value in (
            "coghex/kanban",
            "coghex/kanban.git",
            "https://github.com/coghex/kanban",
            "https://github.com/coghex/kanban.git",
            "https://www.github.com/coghex/kanban",
            "https://github.com:443/coghex/kanban",
            "ssh://git@github.com/coghex/kanban.git",
            "git://github.com/coghex/kanban.git",
            "git@github.com:coghex/kanban.git",
            "  git@github.com:coghex/kanban  ",
        ):
            with self.subTest(value=value):
                self.assertEqual(
                    drain_prs_service.normalize_identity(value), "coghex/kanban"
                )

    def test_rejects_what_kanban_would_not_resolve_either(self):
        # Each of these either names no repository on github.com or names one
        # ambiguously. Deriving a label from any of them would install a job
        # under a name Kanban's own resolver would never look for.
        for value in (
            "git@gitlab.com:coghex/kanban.git",
            "https://gitlab.com/coghex/kanban.git",
            "http://github.com/coghex/kanban",
            "https://github.com/coghex/kanban/tree/master",
            "git@github.com:22/coghex/kanban",
            "/tmp/acme/widgets.git",
            "file:///tmp/acme/widgets.git",
            "coghex",
            "coghex/",
            "coghex/kan ban",
            "coghex/kan~ban",
            "",
        ):
            with self.subTest(value=value):
                with self.assertRaises(drain_prs_service.ServiceError):
                    drain_prs_service.normalize_identity(value)

    def test_case_only_spellings_name_one_drainer(self):
        # Two clones of one GitHub repository must not be able to drain it
        # concurrently by spelling its name differently.
        spellings = [
            "coghex/kanban",
            "CogHex/Kanban",
            "COGHEX/KANBAN",
            "git@github.com:CogHex/Kanban.git",
        ]
        identities = {drain_prs_service.normalize_identity(v) for v in spellings}
        self.assertEqual(identities, {"coghex/kanban"})
        slugs = {drain_prs_service.repository_slug(i) for i in identities}
        self.assertEqual(len(slugs), 1)

    def test_every_supported_name_yields_a_valid_nonempty_unique_label(self):
        identities = [
            "coghex/kanban",
            "coghex/kan-ban",
            "coghex/kan.ban",
            "coghex/kan_ban",
            "coghex/kan--ban",
            "coghex/kanban-",
            "coghex/-kanban",
            "coghex/kan-dban",
            "coghex/kan.dban",
            "cog-hex/kanban",
            "cog.hex/kanban",
            "cog_hex/kanban",
            # The documented GitHub maxima: a 39-character owner and a
            # 100-character name.
            "o" * 39 + "/" + "n" * 100,
            "o" * 39 + "/" + "n-" * 50,
            # Past them, where escaping would outgrow the filename limit.
            "o" * 200 + "/" + "-" * 200,
            "o" * 200 + "/" + "." * 200,
        ]
        labels = {}
        for identity in identities:
            with self.subTest(identity=identity):
                slug = drain_prs_service.repository_slug(identity)
                label = f"{service_manager.LABEL_PREFIX}.{slug}"
                self.assertTrue(label)
                self.assertRegex(label, r"\A[A-Za-z0-9._-]+\Z")
                # `<label>.plist` has to stay inside the 255-byte filename
                # limit, or the job cannot be written at all.
                self.assertLess(len(label) + len(".plist"), 255)
                self.assertNotIn(identity, labels.values(), label)
                labels[label] = identity
        # Injective: distinct normalized identities never share a label, so no
        # two repositories can end up controlling one job.
        self.assertEqual(len(labels), len(identities))

    def test_a_derived_label_can_never_be_the_singleton_it_replaces(self):
        for identity in ("coghex/kanban", "a/b", "o" * 300 + "/" + "n" * 300):
            slug = drain_prs_service.repository_slug(identity)
            self.assertNotEqual(
                f"{service_manager.LABEL_PREFIX}.{slug}",
                service_manager.LEGACY_LABEL,
            )


class PerRepositoryPathTests(RedirectedControllerTestCase):
    def test_two_repositories_share_no_mutable_path(self):
        first = drain_prs_service.job_for_identity(self.root / "a", "acme/widgets")
        second = drain_prs_service.job_for_identity(self.root / "b", "acme/gadgets")
        for field in (
            "label",
            "plist_path",
            "runtime_dir",
            "incident_dir",
            "status_path",
            "log_dir",
            "service_log_path",
            "service_out_path",
            "service_err_path",
        ):
            with self.subTest(field=field):
                self.assertNotEqual(getattr(first, field), getattr(second, field))

    def test_two_clones_of_one_repository_share_every_path(self):
        first = drain_prs_service.job_for_identity(self.root / "a", "acme/widgets")
        second = drain_prs_service.job_for_identity(self.root / "b", "ACME/Widgets".lower())
        self.assertEqual(first.label, second.label)
        self.assertEqual(first.status_path, second.status_path)
        self.assertEqual(first.incident_dir, second.incident_dir)
        self.assertNotEqual(first.repo_path, second.repo_path)

    def test_a_checkout_with_no_github_remote_can_have_no_drainer(self):
        checkout = self.checkout("local", "/tmp/acme/widgets.git")
        with self.assertRaises(drain_prs_service.ServiceError) as raised:
            drain_prs_service.resolve_job(checkout)
        self.assertIn("supported GitHub repository", str(raised.exception))
        # It still records incidents, on the unpartitioned surface that by
        # construction is no repository's own.
        job = drain_prs_service.incident_job(checkout)
        self.assertEqual(job.incident_dir, self.runtime_root / "incidents")

    def test_the_plist_path_and_launchd_target_are_derived_from_the_label(self):
        # One derivation moves the plist's name, the launchctl target and —
        # through write_discovery_record — Kanban's discovery together.
        job = drain_prs_service.job_for_identity(self.root / "a", "acme/widgets")
        self.assertEqual(job.plist_path.name, f"{job.label}.plist")
        self.assertTrue(
            service_manager.launch_target_for(job.label).endswith(f"/{job.label}"),
            service_manager.launch_target_for(job.label),
        )


class ModuleDefaultTests(unittest.TestCase):
    """The unredirected module constants, which every other fixture replaces."""

    def test_the_record_stays_at_a_fixed_path_an_install_dir_cannot_move(self):
        # Kanban never inherits KANBAN_DRAINER_INSTALL_DIR, so an install made
        # with --install-dir has to remain discoverable: the record is the one
        # thing whose location the option must not relocate.
        self.assertEqual(
            drain_prs_service.DISCOVERY_RECORD_PATH,
            Path.home()
            / "Library"
            / "Application Support"
            / "kanban"
            / "pr-drainer"
            / "config.json",
        )
        self.assertEqual(
            drain_prs_service.DEFAULT_INSTALL_DIR,
            drain_prs_service.DISCOVERY_RECORD_PATH.parent,
        )

    def test_the_singleton_label_survives_only_as_the_job_to_retire(self):
        self.assertEqual(service_manager.LEGACY_LABEL, "com.coghex.drain-prs")
        self.assertEqual(
            service_manager.LEGACY_PLIST_PATH,
            Path.home() / "Library" / "LaunchAgents" / "com.coghex.drain-prs.plist",
        )


class PinnedServiceDefinitionTests(unittest.TestCase):
    """The generated plist, byte for byte.

    Every input that would otherwise be the developer's own — the interpreter
    running the tests, `HOME`, and the install, runtime and log roots — is
    redirected to a fixed value, so this pin says the same thing on any host
    rather than passing only where it was recorded. The bytes below are the
    ones the controller produced before issue #291 moved plist rendering
    behind the service-manager backend; a difference here is a change to what
    launchd is asked to run, whatever the diff looks like.
    """

    HOME = Path("/Users/pinned")
    INSTALL_DIR = HOME / "Library" / "Application Support" / "kanban" / "pr-drainer"
    GOLDEN = "\n".join(
        [
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
            '<plist version="1.0">',
            "<dict>",
            "\t<key>Label</key>",
            "\t<string>com.coghex.drain-prs.acme.widgets</string>",
            "\t<key>ProgramArguments</key>",
            "\t<array>",
            "\t\t<string>/usr/bin/python3</string>",
            "\t\t<string>/Users/pinned/Library/Application Support/kanban/"
            "pr-drainer/drain_prs_service.py</string>",
            "\t\t<string>--path</string>",
            "\t\t<string>/Users/pinned/work/widgets</string>",
            "\t\t<string>--repo</string>",
            "\t\t<string>acme/widgets</string>",
            "\t\t<string>run</string>",
            "\t</array>",
            "\t<key>WorkingDirectory</key>",
            "\t<string>/Users/pinned/work/widgets</string>",
            "\t<key>RunAtLoad</key>",
            "\t<false/>",
            "\t<key>KeepAlive</key>",
            "\t<false/>",
            "\t<key>ProcessType</key>",
            "\t<string>Background</string>",
            "\t<key>ThrottleInterval</key>",
            "\t<integer>10</integer>",
            "\t<key>StandardOutPath</key>",
            "\t<string>/Users/pinned/Library/Logs/kanban/pr-drainer/acme.widgets/"
            "service.out</string>",
            "\t<key>StandardErrorPath</key>",
            "\t<string>/Users/pinned/Library/Logs/kanban/pr-drainer/acme.widgets/"
            "service.err</string>",
            "\t<key>EnvironmentVariables</key>",
            "\t<dict>",
            "\t\t<key>HOME</key>",
            "\t\t<string>/Users/pinned</string>",
            "\t\t<key>PATH</key>",
            "\t\t<string>/Users/pinned/.local/bin:/opt/homebrew/bin:/usr/local/bin:"
            "/usr/bin:/bin:/usr/sbin:/sbin</string>",
            "\t\t<key>PYTHONUNBUFFERED</key>",
            "\t\t<string>1</string>",
            "\t\t<key>KANBAN_DRAINER_INSTALL_DIR</key>",
            "\t\t<string>/Users/pinned/Library/Application Support/kanban/"
            "pr-drainer</string>",
            "\t</dict>",
            "</dict>",
            "</plist>",
            "",
        ]
    ).encode("utf-8")

    def setUp(self):
        for module, name, value in (
            (drain_prs_service, "HOME", self.HOME),
            (drain_prs_service, "INSTALL_DIR", self.INSTALL_DIR),
            (
                drain_prs_service,
                "CONTROLLER_PATH",
                self.INSTALL_DIR / "drain_prs_service.py",
            ),
            (drain_prs_service, "RUNTIME_ROOT", self.INSTALL_DIR / "runtime"),
            (
                drain_prs_service,
                "LOG_ROOT",
                self.HOME / "Library" / "Logs" / "kanban" / "pr-drainer",
            ),
            (
                service_manager,
                "LAUNCH_AGENTS_DIR",
                self.HOME / "Library" / "LaunchAgents",
            ),
            # The interpreter the definition names is this process's own, which
            # differs between a system python3, a virtualenv, and CI.
            (drain_prs_service.sys, "executable", "/usr/bin/python3"),
        ):
            patched = mock.patch.object(module, name, value)
            patched.start()
            self.addCleanup(patched.stop)

    def test_the_generated_definition_is_byte_identical_to_the_pin(self):
        job = drain_prs_service.job_for_identity(
            self.HOME / "work" / "widgets", "acme/widgets"
        )
        self.assertEqual(rendered_definition(job), self.GOLDEN)


class BackendDelegationTests(RedirectedControllerTestCase):
    """The lifecycle drives whichever backend was selected, and nothing else.

    Issue #291's point: the controller owns identity, records, incidents and
    stabilization, while every service-manager interaction is the backend's.
    Replacing the backend is therefore enough to exercise install, start and
    stop with no service manager present at all.
    """

    def setUp(self):
        super().setUp()
        self.backend = RecordingBackend(self.root / "definitions")
        patched = mock.patch.object(
            drain_prs_service, "service_backend", return_value=self.backend
        )
        patched.start()
        self.addCleanup(patched.stop)
        self.repo = self.checkout("widgets", "git@github.com:acme/widgets.git")
        self.job = drain_prs_service.resolve_job(self.repo)
        self.commands.clear()

    def service_manager_commands(self):
        return [args for args in self.commands if args[0] != "git"]

    def test_the_job_is_named_and_placed_by_the_selected_backend(self):
        self.assertEqual(self.job.label, "fake-service.acme.widgets")
        self.assertEqual(
            self.job.plist_path, self.backend.definition_path(self.job.label)
        )

    def test_the_slug_falls_back_when_the_backend_refuses_the_identifier(self):
        # The limit is the manager's, so the fallback follows whatever it says
        # rather than a length this module restates.
        slug = drain_prs_service.repository_slug("o" * 30 + "/" + "n" * 30)
        self.assertTrue(slug.startswith("h"))
        self.assertNotIn(".", slug)

    def test_installing_writes_the_record_between_the_definition_and_the_load(self):
        # The record describes where the job is, so it has to be true from the
        # moment the definition exists and before the manager is told to load
        # it — an ordering only visible across the boundary.
        real_record = drain_prs_service.write_discovery_record

        def recording(job):
            self.backend.calls.append(("discovery_record",))
            return real_record(job)

        with (
            mock.patch.object(
                drain_prs_service, "status_snapshot", return_value={"state": "stopped"}
            ),
            mock.patch.object(
                drain_prs_service, "write_discovery_record", side_effect=recording
            ),
        ):
            result = drain_prs_service.install_job(self.job)

        self.assertEqual(
            self.backend.names(),
            ["write_definition", "discovery_record", "load_definition"],
        )
        self.assertEqual(result["target"], "fake-manager/fake-service.acme.widgets")
        self.assertEqual(self.service_manager_commands(), [])

    def test_a_legacy_singleton_is_retired_before_the_replacement_is_written(self):
        self.backend.legacy_installed = True
        self.backend.legacy_repository = self.repo
        with mock.patch.object(
            drain_prs_service, "status_snapshot", return_value={"state": "stopped"}
        ):
            result = drain_prs_service.install_job(self.job)
        self.assertEqual(
            self.backend.names(),
            ["retire_legacy", "write_definition", "load_definition"],
        )
        self.assertTrue(result["legacy_job"]["retired"])
        self.assertEqual(result["legacy_job"]["label"], "fake-service.legacy")

    def test_a_legacy_singleton_for_another_repository_is_never_retired(self):
        # The identity comparison stays the controller's: the backend reports
        # which checkout the singleton names and nothing more.
        other = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.backend.legacy_installed = True
        self.backend.legacy_repository = other
        with mock.patch.object(
            drain_prs_service, "status_snapshot", return_value={"state": "stopped"}
        ):
            result = drain_prs_service.install_job(self.job)
        self.assertNotIn("retire_legacy", self.backend.names())
        self.assertFalse(result["legacy_job"]["retired"])
        self.assertEqual(result["legacy_job"]["repository"], "acme/gadgets")

    def test_starting_kicks_the_job_through_the_backend(self):
        stopped = {"state": "stopped", "drainer_pid": None, "active_repo": None}
        running = {"state": "running", "drainer_pid": 4242, "active_repo": str(self.repo)}
        with (
            mock.patch.object(
                drain_prs_service, "in_progress_operation", return_value=None
            ),
            mock.patch.object(drain_prs_service, "require_default_branch"),
            mock.patch.object(drain_prs_service, "install_job"),
            mock.patch.object(drain_prs_service, "START_STABILITY_SECONDS", 0),
            mock.patch.object(drain_prs_service.time, "sleep"),
            mock.patch.object(
                drain_prs_service,
                "status_snapshot",
                side_effect=[stopped, running, running],
            ),
        ):
            result = drain_prs_service.start_service(self.job)
        self.assertTrue(result["started"])
        self.assertEqual(self.backend.names(), ["kick"])
        self.assertEqual(self.service_manager_commands(), [])

    def test_stopping_asks_the_backend_to_terminate_the_job(self):
        running = {
            "state": "running",
            "drainer_pid": 4242,
            "active_repo": str(self.repo),
            "cleanup_obligations": [],
        }
        stopped = {"state": "stopped", "drainer_pid": None, "cleanup_obligations": []}
        with (
            mock.patch.object(drain_prs_service.time, "sleep"),
            mock.patch.object(
                drain_prs_service,
                "status_snapshot",
                side_effect=[running, stopped, stopped],
            ),
        ):
            result = drain_prs_service.stop_service(self.job)
        self.assertTrue(result["stopped"])
        self.assertEqual(self.backend.calls, [("request_stop", self.job.label)])
        self.assertEqual(self.service_manager_commands(), [])

    def test_status_reads_its_loaded_answer_from_the_backend(self):
        self.backend.loaded = True
        self.assertTrue(drain_prs_service.status_snapshot(self.job)["launchd_loaded"])
        self.backend.loaded = False
        self.assertFalse(drain_prs_service.status_snapshot(self.job)["launchd_loaded"])


class BackendFailureVocabularyTests(RedirectedControllerTestCase):
    def test_a_failing_command_reaches_the_caller_as_a_service_error(self):
        # The backend is constructed with this module's own `run_command`, so
        # a failure crossing the boundary is the error every caller here
        # already handles rather than a third exception type.
        with mock.patch.object(
            drain_prs_service,
            "run_command",
            side_effect=drain_prs_service.ServiceError("Command failed: launchctl"),
        ):
            with self.assertRaises(drain_prs_service.ServiceError):
                drain_prs_service.service_backend().kick("com.example.job")

    def test_an_unknown_job_is_reported_as_not_loaded_rather_than_a_failure(self):
        with mock.patch.object(
            drain_prs_service.subprocess,
            "run",
            return_value=_completed(1, stderr="Could not find service"),
        ):
            self.assertFalse(
                drain_prs_service.service_backend().is_loaded("com.example.job")
            )


class ControllerConfigurationTests(RedirectedControllerTestCase):
    def test_plist_uses_stable_installed_controller_and_selected_repo(self):
        repo = self.root / "example-project"
        job = drain_prs_service.job_for_identity(repo, "acme/widgets")
        with mock.patch.object(
            drain_prs_service,
            "CONTROLLER_PATH",
            self.install_dir / "drain_prs_service.py",
        ):
            value = plistlib.loads(rendered_definition(job))
        self.assertEqual(value["Label"], job.label)
        self.assertEqual(
            value["ProgramArguments"][1:],
            [
                str(self.install_dir / "drain_prs_service.py"),
                "--path",
                str(repo),
                "--repo",
                "acme/widgets",
                "run",
            ],
        )
        self.assertEqual(value["WorkingDirectory"], str(repo))
        self.assertEqual(value["StandardOutPath"], str(job.service_out_path))
        self.assertEqual(value["StandardErrorPath"], str(job.service_err_path))
        self.assertNotIn("KANBAN_DRAINER_NTFY_URL", value["EnvironmentVariables"])

    def test_notification_endpoint_is_not_exposed_in_plist(self):
        job = drain_prs_service.job_for_identity(self.root / "a", "acme/widgets")
        with mock.patch.object(
            drain_prs_service, "NTFY_URL", "https://notify.example.test/topic"
        ):
            value = plistlib.loads(rendered_definition(job))
        self.assertNotIn("KANBAN_DRAINER_NTFY_URL", value["EnvironmentVariables"])

    def test_the_shared_document_is_read_with_a_legacy_install_dir_copy_under_it(self):
        # A custom install upgraded before its next installer run still has its
        # endpoint beside the script links; losing notifications silently in
        # that window would be worse than reading both.
        legacy = self.root / "elsewhere" / "config.json"
        legacy.parent.mkdir()
        legacy.write_text(
            json.dumps({"ntfy_url": "https://notify.example.test/legacy"}),
            encoding="utf-8",
        )
        self.record.parent.mkdir(parents=True)
        self.record.write_text(
            json.dumps({"ntfy_url": "https://notify.example.test/current"}),
            encoding="utf-8",
        )
        with mock.patch.dict(os.environ, {}, clear=False):
            # The environment override outranks both documents, so it must not
            # be what this test is actually reading.
            os.environ.pop("KANBAN_DRAINER_NTFY_URL", None)
            self.assertEqual(
                drain_prs_service.configured_ntfy_url(),
                "https://notify.example.test/current",
            )

    def test_notifications_are_disabled_by_default(self):
        self.assertEqual(
            drain_prs_service.publish_ntfy("test"),
            {"configured": False, "delivered": False},
        )

    def test_stored_repository_supports_current_and_legacy_status(self):
        expected = Path("/tmp/example-project").resolve()
        self.assertEqual(
            drain_prs_service.stored_repo_path({"repo": str(expected)}), expected
        )
        self.assertEqual(
            drain_prs_service.stored_repo_path(
                {"command": ["drain_prs.py", "--path", str(expected)]}
            ),
            expected,
        )

    def test_default_branch_preflight_honors_a_configured_non_origin_remote(self):
        with tempfile.TemporaryDirectory() as remote_dir, tempfile.TemporaryDirectory() as repo_dir:
            remote = Path(remote_dir)
            repo = Path(repo_dir)
            subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "config", "user.email", "test@example.test"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "config", "user.name", "Test"], check=True
            )
            (repo / "README.md").write_text("hello\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "README.md"], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "commit", "-q", "-m", "initial"], check=True
            )
            subprocess.run(["git", "-C", str(repo), "branch", "-M", "main"], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "remote", "add", "upstream", str(remote)],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "push", "-q", "upstream", "main"], check=True
            )
            subprocess.run(
                ["git", "-C", str(repo), "remote", "set-head", "upstream", "main"],
                check=True,
            )
            # The real runner, not the scripted fake: this asserts what git
            # actually reports for a non-default remote name.
            with mock.patch.object(
                drain_prs_service, "run_command", side_effect=_real_run_command
            ):
                drain_prs_service.require_default_branch(repo, "upstream")
                with self.assertRaisesRegex(
                    drain_prs_service.ServiceError, "origin/HEAD"
                ):
                    drain_prs_service.require_default_branch(repo, "origin")


def _real_run_command(args, *, check=True):
    proc = subprocess.run(args, text=True, capture_output=True)
    if check and proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        raise drain_prs_service.ServiceError(
            f"Command failed: {' '.join(args)}\n{detail}"
        )
    return proc


class RequestedIdentityTests(RedirectedControllerTestCase):
    """Kanban resolves the board's repository through its own configuration —
    `--repo OWNER/NAME` outright, or the remote a `--config` names — so the
    identity it passes here is asserted rather than believed."""

    def setUp(self):
        super().setUp()
        self.job = drain_prs_service.job_for_identity(
            self.root / "a", "acme/widgets"
        )

    def test_a_matching_identity_is_accepted_however_it_is_spelled(self):
        for requested in (
            "acme/widgets",
            "ACME/Widgets",
            "git@github.com:Acme/Widgets.git",
            "https://github.com/acme/widgets",
        ):
            with self.subTest(requested=requested):
                drain_prs_service.require_requested_identity(self.job, requested)

    def test_no_identity_at_all_still_controls_this_checkout(self):
        drain_prs_service.require_requested_identity(self.job, None)

    def test_another_repository_cannot_be_selected_or_created(self):
        with self.assertRaises(drain_prs_service.ServiceError) as raised:
            drain_prs_service.require_requested_identity(self.job, "acme/gadgets")
        message = str(raised.exception)
        self.assertIn("acme/gadgets", message)
        self.assertIn("acme/widgets", message)

    def test_an_unsupported_identity_is_refused_rather_than_derived_from(self):
        with self.assertRaises(drain_prs_service.ServiceError):
            drain_prs_service.require_requested_identity(self.job, "/tmp/acme/widgets")

    def test_another_remote_of_this_same_checkout_is_refused_too(self):
        # A fork's upstream is a different canonical repository. Accepting it
        # because the checkout happens to have a remote for it would act on the
        # origin job while the dashboard is for the upstream one — the exact
        # divergence per-repository identities exist to prevent — so the two
        # configurations have to be aligned instead.
        checkout = self.checkout(
            "widgets",
            "git@github.com:acme/widgets.git",
            upstream="git@github.com:upstream-owner/widgets.git",
        )
        job = drain_prs_service.resolve_job(checkout)
        self.assertEqual(
            drain_prs_service.repository_identity(checkout, "upstream"),
            "upstream-owner/widgets",
        )
        with self.assertRaises(drain_prs_service.ServiceError) as raised:
            drain_prs_service.require_requested_identity(job, "upstream-owner/widgets")
        message = str(raised.exception)
        self.assertIn("upstream-owner/widgets", message)
        self.assertIn("acme/widgets", message)
        self.assertIn("remote_name", message)


class InstalledJobIdentityTests(RedirectedControllerTestCase):
    """A plist outlives the configuration it was written from, so the identity
    its label was derived from travels in it."""

    def setUp(self):
        super().setUp()
        self.repo = self.checkout(
            "widgets",
            "git@github.com:acme/widgets.git",
            upstream="git@github.com:upstream-owner/widgets.git",
        )
        self.job = drain_prs_service.resolve_job(self.repo)

    def _config_naming(self, remote_name):
        config = self.root / f"{remote_name}.toml"
        config.write_text(f'remote_name = "{remote_name}"\n', encoding="utf-8")
        return mock.patch.object(
            drain_prs_service,
            "discovery_remote_name",
            return_value=remote_name,
        )

    def test_the_installed_plist_names_the_identity_its_label_came_from(self):
        self.install(self.job)
        arguments = plistlib.loads(self.job.plist_path.read_bytes())["ProgramArguments"]
        self.assertEqual(arguments[-3:], ["--repo", "acme/widgets", "run"])
        self.assertIn(drain_prs_service.repository_slug("acme/widgets"), self.job.label)

    def test_the_runner_drains_nothing_once_the_configured_remote_moves(self):
        # The failure this prevents: the shared remote_name changes after
        # installation, the old label re-resolves as the *other* repository,
        # and it drains under that repository's status file, incidents and
        # logs while the dashboard can neither discover nor control it.
        self.install(self.job)
        with self._config_naming("upstream"):
            moved = drain_prs_service.resolve_job(self.repo)
            self.assertEqual(moved.identity, "upstream-owner/widgets")
            with (
                mock.patch.object(drain_prs_service, "require_default_branch") as branch,
                mock.patch.object(drain_prs_service.subprocess, "Popen") as popen,
            ):
                result = drain_prs_service.run_service(moved, "acme/widgets")

        self.assertEqual(result, 0)
        popen.assert_not_called()
        branch.assert_not_called()
        # Nothing was written under the identity the runner would have moved to.
        self.assertFalse(moved.status_path.exists())
        self.assertFalse(moved.log_dir.exists())
        # And the refusal is readable where the plist sends this job's output.
        service_log = self.job.service_log_path.read_text(encoding="utf-8")
        self.assertIn("acme/widgets", service_log)
        self.assertIn("upstream-owner/widgets", service_log)
        self.assertIn("install_drainer.py", service_log)

    def test_the_runner_still_starts_while_the_identity_matches(self):
        with (
            mock.patch.object(drain_prs_service, "require_default_branch"),
            mock.patch.object(
                drain_prs_service, "service_log"
            ),
            mock.patch.object(drain_prs_service.subprocess, "Popen") as popen,
        ):
            popen.return_value.pid = os.getpid()
            popen.return_value.wait.return_value = 0
            with mock.patch.object(drain_prs_service, "write_incident") as incident:
                drain_prs_service.run_service(self.job, "acme/widgets")
        popen.assert_called_once()
        incident.assert_called_once()

    def test_a_reinstall_after_the_change_mints_the_job_now_configured(self):
        self.install(self.job)
        with self._config_naming("upstream"):
            moved = drain_prs_service.resolve_job(self.repo)
            self.install(moved)
            arguments = plistlib.loads(moved.plist_path.read_bytes())["ProgramArguments"]
        self.assertEqual(arguments[-3:], ["--repo", "upstream-owner/widgets", "run"])
        self.assertNotEqual(moved.plist_path, self.job.plist_path)
        self.assertEqual(
            set(self.read_record()["repositories"]),
            {"acme/widgets", "upstream-owner/widgets"},
        )


class DiscoveryRecordTests(RedirectedControllerTestCase):
    """The record `src/Kanban/Drainer.hs` resolves each LaunchAgent through."""

    def setUp(self):
        super().setUp()
        self.widgets = self.checkout("widgets", "git@github.com:acme/widgets.git")
        self.gadgets = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.widgets_job = drain_prs_service.job_for_identity(
            self.widgets, "acme/widgets"
        )
        self.gadgets_job = drain_prs_service.job_for_identity(
            self.gadgets, "acme/gadgets"
        )

    def test_installing_records_the_label_plist_and_repository(self):
        result = self.install(self.widgets_job)
        entry = self.read_record()["repositories"]["acme/widgets"]
        self.assertEqual(entry["launchd_label"], self.widgets_job.label)
        self.assertEqual(entry["plist_path"], str(self.widgets_job.plist_path))
        self.assertEqual(entry["repository"], str(self.widgets))
        self.assertEqual(result["record"], str(self.record))

    def test_the_record_is_written_from_the_same_values_launchd_is_given(self):
        self.install(self.widgets_job)
        entry = self.read_record()["repositories"]["acme/widgets"]
        self.assertIn(
            [
                "launchctl",
                "bootstrap",
                service_manager.launch_domain(),
                entry["plist_path"],
            ],
            self.commands,
        )

    def test_installing_a_second_repository_keeps_the_first_discoverable(self):
        self.install(self.widgets_job)
        self.install(self.gadgets_job)
        records = self.read_record()["repositories"]
        self.assertEqual(set(records), {"acme/widgets", "acme/gadgets"})
        self.assertNotEqual(
            records["acme/widgets"]["launchd_label"],
            records["acme/gadgets"]["launchd_label"],
        )
        self.assertNotEqual(
            records["acme/widgets"]["plist_path"],
            records["acme/gadgets"]["plist_path"],
        )

    def test_refreshing_one_repository_leaves_the_other_untouched(self):
        self.install(self.widgets_job)
        drain_prs_service.merge_repository_record(
            "acme/widgets", {"config_path": "/home/user/widgets.toml"}
        )
        self.install(self.gadgets_job)
        drain_prs_service.merge_repository_record(
            "acme/gadgets", {"config_path": "/home/user/gadgets.toml"}
        )
        before = self.read_record()["repositories"]["acme/gadgets"]

        self.install(self.widgets_job)

        after = self.read_record()["repositories"]
        self.assertEqual(after["acme/gadgets"], before)
        self.assertEqual(
            after["acme/widgets"]["config_path"], "/home/user/widgets.toml"
        )

    def test_reinstalling_repairs_the_record_in_place(self):
        # An installation predating the record is repaired by re-running the
        # installer, which reaches install_job the same way a first install
        # does — without an uninstall, and without changing the label.
        self.install(self.widgets_job)
        first = self.read_record()
        self.record.unlink()
        self.install(self.widgets_job)
        self.assertEqual(self.read_record(), first)

    def test_recording_preserves_the_installer_persisted_keys(self):
        self.record.parent.mkdir(parents=True)
        self.record.write_text(
            json.dumps({"ntfy_url": "https://notify.example.test/topic"}),
            encoding="utf-8",
        )
        self.install(self.widgets_job)
        record = self.read_record()
        self.assertEqual(record["ntfy_url"], "https://notify.example.test/topic")
        self.assertEqual(
            record["repositories"]["acme/widgets"]["plist_path"],
            str(self.widgets_job.plist_path),
        )

    def test_the_record_is_private_and_never_a_symlink_target(self):
        self.install(self.widgets_job)
        self.assertFalse(self.record.is_symlink())
        self.assertEqual(self.record.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.record.parent.stat().st_mode & 0o777, 0o700)

        outside = self.root / "outside.json"
        outside.write_text("keep\n", encoding="utf-8")
        self.record.unlink()
        self.record.symlink_to(outside)
        with self.assertRaises(drain_prs_service.ServiceError):
            self.install(self.widgets_job)
        self.assertEqual(outside.read_text(encoding="utf-8"), "keep\n")


class PerRepositoryConfigurationTests(RedirectedControllerTestCase):
    def test_each_repository_keeps_its_own_config_path(self):
        drain_prs_service.merge_repository_record(
            "acme/widgets", {"config_path": "/home/user/widgets.toml"}
        )
        drain_prs_service.merge_repository_record(
            "acme/gadgets", {"config_path": "/home/user/gadgets.toml"}
        )
        self.assertEqual(
            drain_prs_service.configured_config_path("acme/widgets"),
            "/home/user/widgets.toml",
        )
        self.assertEqual(
            drain_prs_service.configured_config_path("acme/gadgets"),
            "/home/user/gadgets.toml",
        )

    def test_a_repository_without_an_override_uses_the_shared_default(self):
        # Including when the shared document still carries the single scalar a
        # pre-#147 install wrote: reading it would let a later installation
        # silently change what an earlier repository restarts with.
        self.record.parent.mkdir(parents=True)
        self.record.write_text(
            json.dumps({"config_path": "/home/user/legacy.toml"}), encoding="utf-8"
        )
        drain_prs_service.merge_repository_record(
            "acme/widgets", {"config_path": "/home/user/widgets.toml"}
        )
        self.assertIsNone(drain_prs_service.configured_config_path("acme/gadgets"))

    def test_a_config_naming_another_remote_never_moves_the_job_identity(self):
        # The circularity this order exists to break: a repository's --config
        # lives in the record its identity selects, so letting that config
        # decide the identity would decide it from a record already found by
        # it. The installer would store the config under one identity and the
        # installed controller would resolve another from the same checkout,
        # and the install would abort on its own --repo assertion.
        checkout = self.checkout(
            "widgets",
            "git@github.com:acme/widgets.git",
            upstream="git@github.com:upstream-owner/widgets.git",
        )
        config = self.root / "config.toml"
        config.write_text('remote_name = "upstream"\n', encoding="utf-8")

        before = drain_prs_service.resolve_job(checkout)
        drain_prs_service.merge_repository_record(
            before.identity, {"config_path": str(config)}
        )
        after = drain_prs_service.resolve_job(checkout)

        self.assertEqual(before.identity, "acme/widgets")
        self.assertEqual(after.identity, before.identity)
        self.assertEqual(after.label, before.label)
        drain_prs_service.require_requested_identity(after, before.identity)
        # The configuration still decides everything the drainer runs with,
        # including the remote its default-branch check and merges use.
        self.assertEqual(after.config_path, str(config))
        self.assertEqual(after.remote_name, "upstream")
        self.assertEqual(before.remote_name, "origin")
        self.assertIn("--config", drain_prs_service.drainer_command(after))

    def test_the_forwarded_command_carries_only_this_repository_selection(self):
        widgets = drain_prs_service.job_for_identity(
            self.root / "widgets", "acme/widgets", config_path="/home/user/widgets.toml"
        )
        gadgets = drain_prs_service.job_for_identity(self.root / "gadgets", "acme/gadgets")
        widgets_command = drain_prs_service.drainer_command(widgets)
        gadgets_command = drain_prs_service.drainer_command(gadgets)
        self.assertIn("--config", widgets_command)
        self.assertEqual(
            widgets_command[widgets_command.index("--config") + 1],
            "/home/user/widgets.toml",
        )
        self.assertNotIn("--config", gadgets_command)
        # Each repository's dated logs go to its own directory, which is what
        # `logs --path <repo>` later selects from.
        self.assertEqual(
            widgets_command[widgets_command.index("--log-dir") + 1],
            str(widgets.log_dir),
        )
        self.assertNotEqual(
            widgets_command[widgets_command.index("--log-dir") + 1],
            gadgets_command[gadgets_command.index("--log-dir") + 1],
        )


class SharedRecordConcurrencyTests(RedirectedControllerTestCase):
    """The discovery record is the one document several repositories write to,
    and every install *and every start* refreshes an entry in it."""

    def test_a_merge_holds_an_exclusive_lock_across_its_read_and_write(self):
        self.record.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock_path = self.record.with_name(self.record.name + ".lock")
        held = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        self.addCleanup(os.close, held)
        fcntl.flock(held, fcntl.LOCK_EX)

        finished = threading.Event()

        def merge():
            drain_prs_service.merge_repository_record(
                "acme/widgets", {"launchd_label": "held"}
            )
            finished.set()

        worker = threading.Thread(target=merge, daemon=True)
        worker.start()
        # It cannot have completed: the lock it needs is held here.
        self.assertFalse(finished.wait(0.5))
        fcntl.flock(held, fcntl.LOCK_UN)
        self.assertTrue(finished.wait(10))
        worker.join(10)
        self.assertEqual(
            self.read_record()["repositories"]["acme/widgets"]["launchd_label"], "held"
        )

    def test_concurrent_merges_keep_every_repositorys_entry(self):
        # Unserialized, two writers both snapshot the old table and whichever
        # replaces it last drops the other's entry — leaving a repository whose
        # drainer is running with no record for Kanban to find it through.
        identities = [f"acme/repo-{index}" for index in range(8)]
        errors = []

        def install(identity):
            try:
                for round_number in range(12):
                    drain_prs_service.merge_repository_record(
                        identity, {"launchd_label": f"{identity}-{round_number}"}
                    )
            except Exception as error:  # pragma: no cover - surfaced below
                errors.append(error)

        workers = [
            threading.Thread(target=install, args=(identity,))
            for identity in identities
        ]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(30)

        self.assertEqual(errors, [])
        records = self.read_record()["repositories"]
        self.assertEqual(set(records), set(identities))
        for identity in identities:
            self.assertEqual(records[identity]["launchd_label"], f"{identity}-11")

    def test_a_top_level_key_and_a_repository_entry_survive_each_other(self):
        drain_prs_service.merge_json_document(
            self.record, {"ntfy_url": "https://notify.example.test/topic"}
        )
        drain_prs_service.merge_repository_record(
            "acme/widgets", {"launchd_label": "com.example.drain"}
        )
        drain_prs_service.merge_json_document(
            self.record, {"ntfy_url": "https://notify.example.test/other"}
        )
        record = self.read_record()
        self.assertEqual(record["ntfy_url"], "https://notify.example.test/other")
        self.assertEqual(
            record["repositories"]["acme/widgets"]["launchd_label"],
            "com.example.drain",
        )


class IndependentDrainerTests(RedirectedControllerTestCase):
    """Two repositories, installed and running at once, sharing nothing."""

    def setUp(self):
        super().setUp()
        self.widgets = self.checkout("widgets", "git@github.com:acme/widgets.git")
        self.gadgets = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.widgets_job = drain_prs_service.resolve_job(self.widgets)
        self.gadgets_job = drain_prs_service.resolve_job(self.gadgets)

    def _snapshot(self, job):
        with mock.patch.object(
            drain_prs_service, "in_progress_operation", return_value=None
        ):
            return drain_prs_service.status_snapshot(job)

    def test_both_install_and_each_names_only_its_own_repository(self):
        self.install(self.widgets_job)
        self.install(self.gadgets_job)
        self.assertTrue(self.widgets_job.plist_path.is_file())
        self.assertTrue(self.gadgets_job.plist_path.is_file())
        widgets_plist = plistlib.loads(self.widgets_job.plist_path.read_bytes())
        gadgets_plist = plistlib.loads(self.gadgets_job.plist_path.read_bytes())
        self.assertEqual(widgets_plist["WorkingDirectory"], str(self.widgets))
        self.assertEqual(gadgets_plist["WorkingDirectory"], str(self.gadgets))
        self.assertIn(str(self.widgets), widgets_plist["ProgramArguments"])
        self.assertNotIn(str(self.gadgets), widgets_plist["ProgramArguments"])
        self.assertNotEqual(widgets_plist["Label"], gadgets_plist["Label"])
        self.assertNotEqual(
            widgets_plist["StandardOutPath"], gadgets_plist["StandardOutPath"]
        )

    def test_each_reports_only_its_own_status(self):
        self.write_status(self.widgets_job, self.widgets)
        self.assertEqual(self._snapshot(self.widgets_job)["state"], "running")
        self.assertEqual(self._snapshot(self.gadgets_job)["state"], "stopped")
        self.assertEqual(
            self._snapshot(self.widgets_job)["repository"], "acme/widgets"
        )

    def test_stopping_one_leaves_the_other_running_and_correctly_reported(self):
        self.write_status(self.widgets_job, self.widgets)
        self.write_status(self.gadgets_job, self.gadgets)
        widgets_target = service_manager.launch_target_for(self.widgets_job.label)

        def stopping(args, *, check=True):
            if args[:2] == ["launchctl", "kill"] and args[3] == widgets_target:
                self.widgets_job.status_path.unlink()
                self.commands.append(list(args))
                return _completed(0)
            return self._run_command(args, check=check)

        with (
            mock.patch.object(drain_prs_service, "run_command", side_effect=stopping),
            mock.patch.object(
                drain_prs_service, "in_progress_operation", return_value=None
            ),
            mock.patch.object(drain_prs_service.time, "sleep"),
        ):
            result = drain_prs_service.stop_service(self.widgets_job)
            gadgets = drain_prs_service.status_snapshot(self.gadgets_job)

        self.assertTrue(result["stopped"])
        self.assertEqual(result["state"], "stopped")
        self.assertEqual(gadgets["state"], "running")
        self.assertEqual(gadgets["repository"], "acme/gadgets")
        # Only the target repository's job was signalled.
        killed = [args for args in self.commands if args[:2] == ["launchctl", "kill"]]
        self.assertEqual(killed, [["launchctl", "kill", "SIGTERM", widgets_target]])

    def test_each_writes_only_to_its_own_service_and_dated_logs(self):
        drain_prs_service.service_log(self.widgets_job, "widgets started")
        drain_prs_service.service_log(self.gadgets_job, "gadgets started")
        self.assertIn(
            "widgets started",
            self.widgets_job.service_log_path.read_text(encoding="utf-8"),
        )
        self.assertNotIn(
            "gadgets",
            self.widgets_job.service_log_path.read_text(encoding="utf-8"),
        )
        self.assertNotEqual(
            self.widgets_job.service_log_path, self.gadgets_job.service_log_path
        )

    def test_logs_selects_the_target_repositorys_dated_log(self):
        # The failure this prevents: a shared log directory, where the newest
        # file belongs to whichever repository last drained anything.
        self.widgets_job.log_dir.mkdir(parents=True)
        self.gadgets_job.log_dir.mkdir(parents=True)
        (self.widgets_job.log_dir / "2026-01-01.log").write_text(
            "widgets\n", encoding="utf-8"
        )
        (self.gadgets_job.log_dir / "2026-06-01.log").write_text(
            "gadgets\n", encoding="utf-8"
        )
        widgets_log = drain_prs_service.latest_log_path(self.widgets_job)
        gadgets_log = drain_prs_service.latest_log_path(self.gadgets_job)
        self.assertEqual(widgets_log.name, "2026-01-01.log")
        self.assertEqual(gadgets_log.name, "2026-06-01.log")
        self.assertEqual(
            drain_prs_service.tail_lines(widgets_log), ["widgets"]
        )

    def test_incidents_stay_attributed_to_the_repository_that_raised_them(self):
        widgets = drain_prs_service.record_conflict_incident(
            repo_path=self.widgets, pull_request=42, files=["README"]
        )
        gadgets = drain_prs_service.record_conflict_incident(
            repo_path=self.gadgets, pull_request=42, files=["README"]
        )
        self.assertEqual(widgets["repository"], "acme/widgets")
        self.assertEqual(gadgets["repository"], "acme/gadgets")
        widgets_open = drain_prs_service.incident_files(
            self.widgets_job, open_only=True
        )
        gadgets_open = drain_prs_service.incident_files(
            self.gadgets_job, open_only=True
        )
        self.assertEqual(len(widgets_open), 1)
        self.assertEqual(len(gadgets_open), 1)
        self.assertNotEqual(widgets_open[0].parent, gadgets_open[0].parent)

        drain_prs_service.acknowledge_incident(self.widgets_job, None, "handled")
        self.assertEqual(
            drain_prs_service.incident_files(self.widgets_job, open_only=True), []
        )
        self.assertEqual(
            len(drain_prs_service.incident_files(self.gadgets_job, open_only=True)), 1
        )


class SameRepositoryExclusionTests(RedirectedControllerTestCase):
    """Two checkouts of one GitHub repository are one drainer, not two."""

    def setUp(self):
        super().setUp()
        self.first = self.checkout("clone-a", "git@github.com:acme/widgets.git")
        self.second = self.checkout("clone-b", "https://github.com/ACME/Widgets.git")
        self.first_job = drain_prs_service.resolve_job(self.first)
        self.second_job = drain_prs_service.resolve_job(self.second)

    def test_the_two_clones_resolve_to_one_job(self):
        self.assertEqual(self.first_job.identity, self.second_job.identity)
        self.assertEqual(self.first_job.label, self.second_job.label)
        self.assertEqual(self.first_job.status_path, self.second_job.status_path)

    def test_a_second_start_is_refused_by_shared_identity_not_by_the_run_lock(self):
        self.write_status(self.first_job, self.first)
        # The per-checkout run lock cannot see the other clone: the second
        # checkout has its own .git and no lock file at all.
        self.assertIsNone(drain_prs_service.lock_pid(self.second))
        with (
            mock.patch.object(
                drain_prs_service, "require_no_operation_in_progress"
            ),
            mock.patch.object(drain_prs_service, "require_default_branch"),
        ):
            with self.assertRaises(drain_prs_service.ServiceError) as raised:
                drain_prs_service.start_service(self.second_job)
        message = str(raised.exception)
        self.assertIn("acme/widgets", message)
        self.assertIn(str(self.first), message)
        self.assertIn(str(self.second), message)

    def test_a_second_install_is_refused_the_same_way(self):
        self.write_status(self.first_job, self.first)
        with self.assertRaises(drain_prs_service.ServiceError) as raised:
            drain_prs_service.install_job(self.second_job)
        self.assertIn("acme/widgets", str(raised.exception))
        self.assertFalse(self.second_job.plist_path.exists())

    def test_an_incident_raised_from_one_clone_is_listed_from_the_other(self):
        # Only running is exclusive per identity; querying is not, so an
        # incident raised while the first clone held the drainer has to be
        # visible — and clearable — from the second.
        drain_prs_service.record_conflict_incident(
            repo_path=self.first, pull_request=42, files=["README"]
        )
        from_second = drain_prs_service.incident_files(
            self.second_job, open_only=True
        )
        self.assertEqual(len(from_second), 1)
        acknowledged = drain_prs_service.acknowledge_incident(
            self.second_job, None, "handled from the other clone"
        )
        self.assertEqual(acknowledged["status"], "resolved")
        self.assertEqual(
            drain_prs_service.incident_files(self.first_job, open_only=True), []
        )


class LegacyJobMigrationTests(RedirectedControllerTestCase):
    """The machine-wide singleton must never be loadable beside the derived
    job that replaces it."""

    def setUp(self):
        super().setUp()
        self.widgets = self.checkout("widgets", "git@github.com:acme/widgets.git")
        self.gadgets = self.checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.widgets_job = drain_prs_service.resolve_job(self.widgets)
        self.legacy_plist = self.launch_agents / (
            service_manager.LEGACY_LABEL + ".plist"
        )
        self.legacy_target = service_manager.launch_target_for(
            service_manager.LEGACY_LABEL
        )

    def write_legacy_plist(self, repo):
        self.legacy_plist.write_bytes(
            plistlib.dumps(
                {
                    "Label": service_manager.LEGACY_LABEL,
                    "ProgramArguments": [
                        "/usr/bin/python3",
                        "/tmp/drain_prs_service.py",
                        "--path",
                        str(repo),
                        "run",
                    ],
                    "WorkingDirectory": str(repo),
                }
            )
        )
        self.loaded.add(self.legacy_target)

    def test_the_legacy_job_for_this_repository_is_retired_before_its_replacement(self):
        self.write_legacy_plist(self.widgets)
        self.install(self.widgets_job)

        self.assertFalse(self.legacy_plist.exists())
        self.assertTrue(
            self.legacy_plist.with_name(self.legacy_plist.name + ".retired").is_file()
        )
        booted_out = self.commands.index(
            ["launchctl", "bootout", self.legacy_target]
        )
        bootstrapped = self.commands.index(
            [
                "launchctl",
                "bootstrap",
                service_manager.launch_domain(),
                str(self.widgets_job.plist_path),
            ]
        )
        self.assertLess(booted_out, bootstrapped)

    def test_a_legacy_job_for_another_repository_is_left_to_migrate_itself(self):
        self.write_legacy_plist(self.gadgets)
        result = self.install(self.widgets_job)

        self.assertTrue(self.legacy_plist.is_file())
        self.assertNotIn(["launchctl", "bootout", self.legacy_target], self.commands)
        self.assertFalse(result["legacy_job"]["retired"])
        self.assertEqual(result["legacy_job"]["repository"], "acme/gadgets")

    def test_a_repository_config_naming_another_remote_still_retires_its_legacy_job(
        self,
    ):
        # Identities are only ever comparable when both were resolved through
        # the discovery remote. Resolving the legacy job's checkout through
        # this repository's own --config remote instead would make the very
        # checkout being installed look like another repository, and the
        # singleton would stay loadable beside its replacement.
        self.remotes[(str(self.widgets), "upstream")] = (
            "git@github.com:upstream-owner/widgets.git"
        )
        config = self.root / "config.toml"
        config.write_text('remote_name = "upstream"\n', encoding="utf-8")
        drain_prs_service.merge_repository_record(
            "acme/widgets", {"config_path": str(config)}
        )
        job = drain_prs_service.resolve_job(self.widgets)
        self.assertEqual(job.identity, "acme/widgets")
        self.assertEqual(job.remote_name, "upstream")

        self.write_legacy_plist(self.widgets)
        result = self.install(job)

        self.assertTrue(result["legacy_job"]["retired"])
        self.assertFalse(self.legacy_plist.exists())
        self.assertIn(["launchctl", "bootout", self.legacy_target], self.commands)

    def test_a_legacy_job_naming_no_resolvable_repository_is_retired(self):
        # Its checkout is gone or is no longer a supported GitHub clone, so it
        # can serve no repository — and leaving it loadable would leave a job
        # nothing can ever migrate.
        self.write_legacy_plist(self.root / "vanished")
        result = self.install(self.widgets_job)
        self.assertTrue(result["legacy_job"]["retired"])
        self.assertFalse(self.legacy_plist.exists())

    def test_an_install_with_no_legacy_job_reports_nothing_to_retire(self):
        result = self.install(self.widgets_job)
        self.assertIsNone(result["legacy_job"])


class IncidentSelectionTests(RedirectedControllerTestCase):
    def setUp(self):
        super().setUp()
        self.repo = self.checkout("widgets", "git@github.com:acme/widgets.git")
        self.job = drain_prs_service.resolve_job(self.repo)
        self.job.incident_dir.mkdir(parents=True)

    def write_incident(self, name, **fields):
        path = self.job.incident_dir / name
        path.write_text(json.dumps(fields), encoding="utf-8")
        return path

    def test_incidents_are_filtered_by_canonical_identity(self):
        matching = self.write_incident(
            "incident-2.json", repository="acme/widgets", status="open"
        )
        self.write_incident("incident-1.json", repository="acme/gadgets", status="open")
        self.assertEqual(
            drain_prs_service.incident_files(self.job, open_only=True), [matching]
        )

    def test_an_incident_predating_the_identity_field_falls_back_to_its_path(self):
        matching = self.write_incident(
            "incident-2.json", repo=str(self.repo), status="open"
        )
        self.write_incident("incident-1.json", repo="/tmp/elsewhere", status="open")
        self.assertEqual(
            drain_prs_service.incident_files(self.job, open_only=True), [matching]
        )

    def _stop_fixture(self):
        """One open incident of every kind for this repository, plus a foreign
        crash and an already-resolved one, so a stop is judged against the two
        it may clear and the three it may not touch."""
        return {
            "crash": self.write_incident(
                "incident-5.json",
                repository="acme/widgets",
                status="open",
                kind=drain_prs_service.CRASH_INCIDENT_KIND,
            ),
            # No `kind` at all: written before the field existed, and read as a
            # crash by `incident_kind`.
            "legacy": self.write_incident(
                "incident-4.json", repository="acme/widgets", status="open"
            ),
            "conflict": self.write_incident(
                "incident-3.json",
                repository="acme/widgets",
                status="open",
                kind=drain_prs_service.CONFLICT_INCIDENT_KIND,
                pull_request=42,
            ),
            "cleanup": self.write_incident(
                "incident-2.json",
                repository="acme/widgets",
                status="open",
                kind=drain_prs_service.CLEANUP_INCIDENT_KIND,
                pull_request=43,
            ),
            "other": self.write_incident(
                "incident-1.json",
                repository="acme/gadgets",
                status="open",
                kind=drain_prs_service.CRASH_INCIDENT_KIND,
            ),
            "already": self.write_incident(
                "incident-0.json",
                repository="acme/widgets",
                status="resolved",
                kind=drain_prs_service.CRASH_INCIDENT_KIND,
            ),
        }

    def _assert_untouched_by_the_stop(self, incidents):
        for name in ("conflict", "cleanup", "other"):
            incident = json.loads(incidents[name].read_text(encoding="utf-8"))
            self.assertEqual(incident["status"], "open")
            self.assertNotIn("resolved_at", incident)
            self.assertNotIn("resolution", incident)

    def test_intentional_stop_resolves_only_crash_incidents(self):
        # A stop ends the supervisor, so a crash incident is genuinely over. It
        # makes no pull request mergeable and completes no post-merge step, so
        # a conflict or cleanup incident is still owed and stays open for the
        # poll that can actually clear it.
        incidents = self._stop_fixture()
        resolved = drain_prs_service.resolve_crash_incidents(
            self.job, "Cleared when the PR drainer was intentionally stopped."
        )
        self.assertEqual(set(resolved), {incidents["crash"], incidents["legacy"]})
        for name in ("crash", "legacy"):
            incident = json.loads(incidents[name].read_text(encoding="utf-8"))
            self.assertEqual(incident["status"], "resolved")
            self.assertIn("resolved_at", incident)
            self.assertEqual(
                incident["resolution"],
                "Cleared when the PR drainer was intentionally stopped.",
            )
        self._assert_untouched_by_the_stop(incidents)
        self.assertEqual(
            json.loads(incidents["already"].read_text(encoding="utf-8"))["status"],
            "resolved",
        )

    def test_a_stop_reports_the_incidents_it_actually_resolved(self):
        # The count is what the operator is told a stop did, so it has to be
        # the two crashes it cleared rather than the four that were open.
        incidents = self._stop_fixture()
        running = {"state": "running", "active_repo": str(self.repo)}
        stopped = {"state": "stopped", "active_repo": None}
        with (
            mock.patch.object(
                drain_prs_service,
                "status_snapshot",
                side_effect=[running, stopped, stopped],
            ),
            mock.patch.object(drain_prs_service.time, "sleep"),
        ):
            result = drain_prs_service.stop_service(self.job)

        self.assertEqual(result["cleared_incidents"], 2)
        self._assert_untouched_by_the_stop(incidents)

    def test_acknowledgement_still_resolves_an_incident_of_any_kind(self):
        # The stop path became kind-selective; the operator's manual dismissal
        # did not, so `ack` remains the way to clear a conflict or cleanup
        # incident a stop now leaves open.
        kinds = (
            drain_prs_service.CRASH_INCIDENT_KIND,
            drain_prs_service.CONFLICT_INCIDENT_KIND,
            drain_prs_service.CLEANUP_INCIDENT_KIND,
        )
        for index, kind in enumerate(kinds, start=1):
            with self.subTest(kind=kind):
                incident_id = f"incident-2026010{index}T000000Z-1"
                path = self.write_incident(
                    f"{incident_id}.json",
                    incident_id=incident_id,
                    kind=kind,
                    status="open",
                    repository="acme/widgets",
                )
                acknowledged = drain_prs_service.acknowledge_incident(
                    self.job, incident_id, "handled by hand"
                )
                self.assertEqual(acknowledged["status"], "resolved")
                self.assertEqual(acknowledged["resolution"], "handled by hand")
                stored = json.loads(path.read_text(encoding="utf-8"))
                self.assertEqual(stored["status"], "resolved")
                self.assertIn("resolved_at", stored)

        # And the unnamed form, which takes the newest open incident whatever
        # its kind rather than the newest crash.
        newest = self.write_incident(
            "incident-20270101T000000Z-1.json",
            incident_id="incident-20270101T000000Z-1",
            kind=drain_prs_service.CLEANUP_INCIDENT_KIND,
            status="open",
            repository="acme/widgets",
        )
        drain_prs_service.acknowledge_incident(self.job, None, None)
        self.assertEqual(
            json.loads(newest.read_text(encoding="utf-8"))["status"], "resolved"
        )

    def test_incidents_open_before_a_start_neither_gate_it_nor_look_new(self):
        # A conflict or cleanup incident now survives an intentional stop, so
        # the next start routinely finds one already open. Starting stays
        # ungated on incidents, and the startup window must not mistake a
        # survivor for a drainer that died on the way up.
        for name, kind, number in (
            ("incident-2.json", drain_prs_service.CONFLICT_INCIDENT_KIND, 42),
            ("incident-1.json", drain_prs_service.CLEANUP_INCIDENT_KIND, 43),
        ):
            self.write_incident(
                name,
                incident_id=name.removesuffix(".json"),
                repository="acme/widgets",
                status="open",
                kind=kind,
                pull_request=number,
                summary=f"PR #{number} still needs attention",
            )
        stopped = {"state": "stopped", "drainer_pid": None, "active_repo": None}
        running = {
            "state": "running",
            "drainer_pid": 4242,
            "active_repo": str(self.repo),
        }
        with (
            mock.patch.object(
                drain_prs_service, "in_progress_operation", return_value=None
            ),
            mock.patch.object(drain_prs_service, "require_default_branch"),
            mock.patch.object(drain_prs_service, "install_job"),
            mock.patch.object(drain_prs_service, "START_STABILITY_SECONDS", 0),
            mock.patch.object(drain_prs_service.time, "sleep"),
            mock.patch.object(
                drain_prs_service,
                "status_snapshot",
                side_effect=[stopped, running, running],
            ),
        ):
            result = drain_prs_service.start_service(self.job)

        self.assertTrue(result["started"])
        self.assertIn(
            ["launchctl", "kickstart", service_manager.launch_target_for(self.job.label)],
            self.commands,
        )
        # A start resolves nothing either: both survivors are still open.
        self.assertEqual(
            len(drain_prs_service.incident_files(self.job, open_only=True)), 2
        )

    def test_conflict_incidents_are_keyed_per_pull_request(self):
        first = drain_prs_service.record_conflict_incident(
            repo_path=self.repo, pull_request=42, files=["README"]
        )
        repeat = drain_prs_service.record_conflict_incident(
            repo_path=self.repo, pull_request=42, files=["README"]
        )
        other = drain_prs_service.record_conflict_incident(
            repo_path=self.repo, pull_request=43, files=["docs/x.md"]
        )
        files = sorted(path.name for path in self.job.incident_dir.glob("*.json"))

        # A second poll over the same unresolved conflict returns the open
        # incident rather than opening a duplicate.
        self.assertEqual(repeat["incident_id"], first["incident_id"])
        self.assertNotEqual(other["incident_id"], first["incident_id"])
        self.assertEqual(len(files), 2)
        self.assertEqual(first["kind"], drain_prs_service.CONFLICT_INCIDENT_KIND)
        self.assertEqual(first["pull_request"], 42)
        self.assertEqual(first["files"], ["README"])
        self.assertIn("#42", first["summary"])
        self.assertIn("README", first["summary"])
        self.assertNotIn("exit_code", first)

    def _record_cleanup(self, *, pull_request, steps, error):
        """Record one cleanup incident, capturing what it would have pushed."""
        published = []

        def capture(message, **kwargs):
            published.append((message, kwargs))
            return {"configured": False, "delivered": False}

        with mock.patch.object(drain_prs_service, "publish_ntfy", side_effect=capture):
            incident = drain_prs_service.record_cleanup_incident(
                repo_path=self.repo,
                pull_request=pull_request,
                steps=steps,
                error=error,
            )
        return incident, published

    def test_the_cleanup_notification_carries_the_failure_the_drainer_recorded(self):
        # The summary names the failing step; only the recorded error says why
        # it fails and what clears it, so the one push an operator receives
        # must not be purely generic.
        refusal = (
            "Refusing to fast-forward master: the index in /repo holds unmerged "
            "entries, so no snapshot of local changes can be taken. Local changes "
            "are not what blocked this. Resolve these paths and `git add` them, and "
            "the next ordinary pass discharges the fast-forward: src/Kanban/UI.hs"
        )
        incident, published = self._record_cleanup(
            pull_request=1079,
            steps=["fast-forwarding the default branch"],
            error=refusal,
        )
        self.assertEqual(len(published), 1)
        message, kwargs = published[0]

        self.assertEqual(incident["last_error"], refusal)
        self.assertIn(refusal, message)
        self.assertIn(incident["incident_id"], message)
        self.assertIn("fast-forwarding the default branch", message)
        self.assertEqual(kwargs["title"], "PR drainer cannot finish post-merge cleanup")

        # The self-clearing claim is qualified: this failure mode needs a human
        # before any amount of retrying can discharge the step.
        self.assertIn(
            "clears itself once any operator action that failure calls for is "
            "done and every outstanding step succeeds",
            message,
        )
        self.assertNotIn("clears itself once every outstanding step succeeds", message)

    def test_a_cleanup_notification_without_a_recorded_failure_says_nothing_of_one(self):
        # No error to report is not an error reading "None". The absent case
        # sends exactly the notification it sent before the field was carried.
        for error in (None, "", "   "):
            with self.subTest(error=error):
                drain_prs_service.resolve_cleanup_incident(self.repo, 1079, "done")
                _, published = self._record_cleanup(
                    pull_request=1079,
                    steps=["fast-forwarding the default branch"],
                    error=error,
                )
                message = published[0][0]
                self.assertNotIn("Last recorded failure", message)
                self.assertNotIn("None", message)

    def test_refreshing_an_open_cleanup_incident_publishes_no_second_notification(self):
        # Every later pass refreshes the open incident's recorded error in
        # place. The incident keeps its id and its one notification.
        first, published = self._record_cleanup(
            pull_request=1079,
            steps=["fast-forwarding the default branch", "pruning the branch"],
            error="exit code 1",
        )
        refreshed, again = self._record_cleanup(
            pull_request=1079,
            steps=["fast-forwarding the default branch"],
            error="a different failure entirely",
        )

        self.assertEqual(len(published), 1)
        self.assertEqual(again, [])
        self.assertEqual(refreshed["incident_id"], first["incident_id"])
        # The document is up to date even though nothing was pushed again.
        self.assertEqual(refreshed["last_error"], "a different failure entirely")
        self.assertEqual(refreshed["steps"], ["fast-forwarding the default branch"])
        self.assertNotIn("a different failure entirely", published[0][0])

    def test_conflict_resolution_leaves_other_open_incidents_alone(self):
        crash = self.write_incident(
            "incident-20260101T000000Z-1.json",
            incident_id="incident-20260101T000000Z-1",
            kind=drain_prs_service.CRASH_INCIDENT_KIND,
            status="open",
            repository="acme/widgets",
            exit_code=1,
        )
        legacy = self.write_incident(
            "incident-20250101T000000Z-1.json",
            incident_id="incident-20250101T000000Z-1",
            status="open",
            repo=str(self.repo),
        )
        drain_prs_service.record_conflict_incident(
            repo_path=self.repo, pull_request=42, files=["README"]
        )
        kept = drain_prs_service.record_conflict_incident(
            repo_path=self.repo, pull_request=43, files=["README"]
        )
        resolved = drain_prs_service.resolve_conflict_incident(
            self.repo, 42, "PR #42 merges cleanly again."
        )
        missing = drain_prs_service.resolve_conflict_incident(
            self.repo, 42, "already resolved"
        )
        open_ids = {
            json.loads(path.read_text(encoding="utf-8"))["incident_id"]
            for path in self.job.incident_dir.glob("*.json")
            if json.loads(path.read_text(encoding="utf-8"))["status"] == "open"
        }

        self.assertEqual(resolved["pull_request"], 42)
        self.assertEqual(resolved["resolution"], "PR #42 merges cleanly again.")
        self.assertIn("resolved_at", resolved)
        self.assertIsNone(missing)
        # The other PR's conflict, the crash, and a pre-kind legacy incident
        # all survive.
        self.assertEqual(
            open_ids, {kept["incident_id"], crash.stem, legacy.stem}
        )

    def test_a_running_service_surfaces_the_newest_conflict_incident(self):
        self.write_status(self.job, self.repo)
        drain_prs_service.record_conflict_incident(
            repo_path=self.repo, pull_request=42, files=["README"]
        )
        snapshot = drain_prs_service.status_snapshot(self.job)

        # Kanban renders `running` + an open incident as a DrainerWarning
        # carrying this summary, so the conflict reaches the board.
        self.assertEqual(snapshot["state"], "running")
        self.assertEqual(snapshot["open_incident"]["pull_request"], 42)
        self.assertIn("#42", snapshot["open_incident"]["summary"])

    def test_a_running_service_reports_every_open_incident_and_the_newest(self):
        # Kanban's incidents panel lists the whole set while the sidebar keeps
        # summarising only the newest, so both projections have to be present
        # and have to agree about which incident is newest.
        self.write_status(self.job, self.repo)
        self.write_incident(
            "incident-20250101T000000Z-1.json",
            incident_id="incident-20250101T000000Z-1",
            kind="drainer-exit",
            status="open",
            summary="drain_prs.py exited unexpectedly with code 1",
            last_pr=7,
            repository="acme/widgets",
        )
        drain_prs_service.record_conflict_incident(
            repo_path=self.repo, pull_request=42, files=["README"]
        )
        drain_prs_service.record_conflict_incident(
            repo_path=self.repo, pull_request=43, files=["README"]
        )
        # Another repository's incident is not this repository's business.
        self.write_incident(
            "incident-20990101T000000Z-9.json",
            incident_id="incident-20990101T000000Z-9",
            status="open",
            summary="another repository's crash",
            repository="acme/gadgets",
        )
        # Neither is a resolved one.
        self.write_incident(
            "incident-20990102T000000Z-9.json",
            incident_id="incident-20990102T000000Z-9",
            status="resolved",
            summary="already handled",
            repository="acme/widgets",
        )

        snapshot = drain_prs_service.status_snapshot(self.job)
        listed = snapshot["open_incidents"]

        # This repository's three open incidents, and only those: the crash
        # plus both conflicts, with the foreign and the resolved one absent.
        self.assertEqual(len(listed), 3)
        self.assertEqual(
            {incident.get("pull_request") for incident in listed}, {None, 42, 43}
        )
        self.assertNotIn(
            "incident-20990101T000000Z-9",
            {incident["incident_id"] for incident in listed},
        )
        self.assertNotIn(
            "incident-20990102T000000Z-9",
            {incident["incident_id"] for incident in listed},
        )
        # The sidebar's projection is unchanged: the newest incident only,
        # and the same object at the head of the full list.
        self.assertEqual(snapshot["open_incident"], listed[0])
        # A supervisor crash still records more than an exit code, and still
        # carries no authoritative `pull_request` for Kanban to navigate by.
        crash = next(
            incident
            for incident in listed
            if incident["incident_id"] == "incident-20250101T000000Z-1"
        )
        self.assertEqual(crash["last_pr"], 7)
        self.assertNotIn("pull_request", crash)

    def test_a_repository_with_no_open_incidents_reports_an_empty_set(self):
        # Verified-empty, which is what lets Kanban's panel say that nothing
        # needs attention rather than that it could not tell.
        self.write_status(self.job, self.repo)
        snapshot = drain_prs_service.status_snapshot(self.job)
        self.assertEqual(snapshot["open_incidents"], [])
        self.assertIsNone(snapshot["open_incident"])


class StatusAndTransitionTests(RedirectedControllerTestCase):
    def setUp(self):
        super().setUp()
        self.repo = self.checkout("widgets", "git@github.com:acme/widgets.git")
        self.job = drain_prs_service.resolve_job(self.repo)

    def _stopped_snapshot(self, operation):
        with (
            mock.patch.object(drain_prs_service, "read_json", return_value={}),
            mock.patch.object(drain_prs_service, "pid_alive", return_value=False),
            mock.patch.object(drain_prs_service, "lock_pid", return_value=None),
            mock.patch.object(drain_prs_service, "incident_files", return_value=[]),
            mock.patch.object(drain_prs_service, "latest_log_path", return_value=None),
            mock.patch.object(
                drain_prs_service, "in_progress_operation", return_value=operation
            ),
        ):
            return drain_prs_service.status_snapshot(self.job)

    def test_status_leaves_a_stopped_dirty_checkout_simply_stopped(self):
        # Inverted from the removed blanket gate: uncommitted work is carried
        # across the post-merge fast-forward by the drainer's own autostash,
        # so a dirty tree reports no repository condition at all.
        result = self._stopped_snapshot(None)
        self.assertEqual(result["state"], "stopped")
        self.assertIsNone(result["operation"])

    def test_status_names_each_unfinished_operation_that_blocks_a_start(self):
        for operation in ("merge", "rebase", "cherry-pick", "bisect"):
            with self.subTest(operation=operation):
                result = self._stopped_snapshot(operation)
                self.assertEqual(result["state"], "mid_operation")
                self.assertEqual(result["operation"], operation)

    def test_start_no_longer_inspects_the_working_tree_for_uncommitted_work(self):
        # Inverted from the removed blanket gate: with no operation in
        # progress there is nothing left in the tree that can refuse a start,
        # so the run reaches installation however dirty the checkout is.
        with (
            mock.patch.object(
                drain_prs_service, "in_progress_operation", return_value=None
            ),
            mock.patch.object(drain_prs_service, "require_default_branch"),
            mock.patch.object(drain_prs_service, "ensure_dirs"),
            mock.patch.object(
                drain_prs_service,
                "status_snapshot",
                return_value={"state": "stopped", "drainer_pid": None, "active_repo": None},
            ),
            mock.patch.object(
                drain_prs_service,
                "install_job",
                side_effect=drain_prs_service.ServiceError("reached installation"),
            ),
        ):
            with self.assertRaisesRegex(
                drain_prs_service.ServiceError, "reached installation"
            ):
                drain_prs_service.start_service(self.job)

    def test_start_refuses_an_unfinished_operation_before_installing_or_launching(self):
        for operation in ("merge", "rebase", "cherry-pick", "bisect"):
            with self.subTest(operation=operation):
                with (
                    mock.patch.object(
                        drain_prs_service, "in_progress_operation", return_value=operation
                    ),
                    mock.patch.object(drain_prs_service, "install_job") as install_job,
                ):
                    with self.assertRaisesRegex(
                        drain_prs_service.ServiceError, f"a {operation} is in progress"
                    ):
                        drain_prs_service.start_service(self.job)
                install_job.assert_not_called()

    def test_start_names_the_operation_ahead_of_a_detached_head(self):
        # A rebase or a bisect commonly leaves a detached HEAD, so checking
        # the branch first would report that symptom instead of the operation
        # the user actually has to finish.
        with (
            mock.patch.object(
                drain_prs_service, "in_progress_operation", return_value="rebase"
            ),
            mock.patch.object(
                drain_prs_service,
                "require_default_branch",
                side_effect=drain_prs_service.ServiceError("repository is on branch ''"),
            ),
        ):
            with self.assertRaisesRegex(
                drain_prs_service.ServiceError, "a rebase is in progress"
            ):
                drain_prs_service.start_service(self.job)

    def test_start_refuses_a_non_default_branch_before_installing_or_launching(self):
        with (
            mock.patch.object(
                drain_prs_service, "in_progress_operation", return_value=None
            ),
            mock.patch.object(
                drain_prs_service,
                "require_default_branch",
                side_effect=drain_prs_service.ServiceError(
                    "repository is on branch 'feature'"
                ),
            ),
            mock.patch.object(drain_prs_service, "install_job") as install_job,
        ):
            with self.assertRaisesRegex(
                drain_prs_service.ServiceError, "repository is on branch 'feature'"
            ):
                drain_prs_service.start_service(self.job)
        install_job.assert_not_called()

    def test_runner_exits_without_an_incident_when_not_on_the_default_branch(self):
        with (
            mock.patch.object(
                drain_prs_service,
                "require_default_branch",
                side_effect=drain_prs_service.ServiceError(
                    "repository is on branch 'feature'"
                ),
            ),
            mock.patch.object(drain_prs_service, "service_log") as service_log,
            mock.patch.object(drain_prs_service, "write_incident") as write_incident,
        ):
            result = drain_prs_service.run_service(self.job)
        self.assertEqual(result, 0)
        service_log.assert_called_once()
        write_incident.assert_not_called()

    def test_stop_clears_crash_incidents_after_the_drainer_has_stopped(self):
        running = {"state": "running", "active_repo": str(self.repo)}
        stopped = {"state": "stopped", "active_repo": None}
        with (
            mock.patch.object(
                drain_prs_service,
                "status_snapshot",
                side_effect=[running, stopped, stopped],
            ),
            mock.patch.object(drain_prs_service.time, "sleep"),
            mock.patch.object(
                drain_prs_service,
                "resolve_crash_incidents",
                return_value=[Path("incident-1.json"), Path("incident-2.json")],
            ) as resolve_crash_incidents,
        ):
            result = drain_prs_service.stop_service(self.job)
        self.assertIn(
            ["launchctl", "kill", "SIGTERM", service_manager.launch_target_for(self.job.label)],
            self.commands,
        )
        resolve_crash_incidents.assert_called_once_with(
            self.job, "Cleared when the PR drainer was intentionally stopped."
        )
        self.assertEqual(
            result,
            {
                "stopped": True,
                "cleared_incidents": 2,
                # Snapshots carrying no projection at all: unknown debt, which
                # is never reported as nothing owed.
                "cleanup_discharged": None,
                "cleanup_outstanding": None,
                **stopped,
            },
        )

    def _owing(self, *counts):
        """A `cleanup_obligations` projection: one pull request per count,
        owing that many steps."""
        return [
            {
                "pull_request": 40 + index,
                "steps": ["closing acme/widgets#7"] * count,
                "failed_passes": 0,
                "last_error": None,
            }
            for index, count in enumerate(counts)
        ]

    def _stop_reporting(self, before, after):
        """Stop a running drainer whose persisted debt reads `before` at the
        signal and `after` once it has exited."""
        running = {
            "state": "running",
            "active_repo": str(self.repo),
            "cleanup_obligations": before,
        }
        stopped = {
            "state": "stopped",
            "active_repo": None,
            "cleanup_obligations": after,
        }
        with (
            mock.patch.object(
                drain_prs_service,
                "status_snapshot",
                side_effect=[running, stopped, stopped],
            ),
            mock.patch.object(drain_prs_service.time, "sleep"),
            mock.patch.object(
                drain_prs_service, "resolve_crash_incidents", return_value=[]
            ),
        ):
            return drain_prs_service.stop_service(self.job)

    def test_stop_reports_the_obligations_its_final_pass_discharged(self):
        # Two pull requests owing five steps between them at the signal; one
        # step left on disk once the drainer has exited.
        result = self._stop_reporting(self._owing(3, 2), self._owing(1))
        self.assertTrue(result["stopped"])
        self.assertEqual(result["cleanup_discharged"], 4)
        self.assertEqual(result["cleanup_outstanding"], 1)

    def test_a_stop_that_discharged_nothing_still_succeeds_and_says_so(self):
        result = self._stop_reporting(self._owing(2), self._owing(2))
        self.assertTrue(result["stopped"])
        self.assertEqual(result["cleanup_discharged"], 0)
        self.assertEqual(result["cleanup_outstanding"], 2)

    def test_a_stop_owing_nothing_reports_nothing_discharged_or_outstanding(self):
        result = self._stop_reporting([], [])
        self.assertTrue(result["stopped"])
        self.assertEqual(result["cleanup_discharged"], 0)
        self.assertEqual(result["cleanup_outstanding"], 0)

    def test_unreadable_queue_state_reports_unknown_rather_than_nothing_owed(self):
        # Either end being unknown makes the difference unknowable; reporting
        # zero discharged would claim the stop had verified something.
        self.assertIsNone(self._stop_reporting(None, self._owing(1))["cleanup_discharged"])
        result = self._stop_reporting(self._owing(1), None)
        self.assertIsNone(result["cleanup_discharged"])
        self.assertIsNone(result["cleanup_outstanding"])

    def test_debt_recorded_during_the_stop_is_not_counted_against_it(self):
        # A merge that landed between the two reads records new obligations.
        # The stop failed to discharge none of them.
        result = self._stop_reporting(self._owing(1), self._owing(3))
        self.assertEqual(result["cleanup_discharged"], 0)
        self.assertEqual(result["cleanup_outstanding"], 3)


class CleanupObligationTests(RedirectedControllerTestCase):
    """The post-merge debt `status` projects out of the drainer's queue state.

    A merge attempts its own cleanup immediately, but what that leaves
    outstanding is retried only by the polling loop's sweep and by the bounded
    pass a stop makes on its way out, so debt outliving both is owed by a
    drainer no longer working it, and debt under
    `CLEANUP_PASSES_BEFORE_INCIDENT` has raised no incident to be seen
    through. This projection is the only surface that names it.
    """

    def setUp(self):
        super().setUp()
        self.repo = self.checkout("widgets", "git@github.com:acme/widgets.git")
        self.job = drain_prs_service.resolve_job(self.repo)
        self.state_path = self.repo / ".git" / "drain_prs_state.json"

    def write_state(self, document):
        self.state_path.write_text(json.dumps(document), encoding="utf-8")

    def entry(self, cleanup):
        return {"approved_head": "a" * 40, "cleanup": cleanup}

    def cleanup(self, pending, *, failed_passes=0, last_error=None):
        return {
            "pr": {"number": 12, "headRefName": "issue-7", "headRefOid": "b" * 40},
            "pending": pending,
            "failed_passes": failed_passes,
            "last_error": last_error,
            "incident": None,
        }

    def state_with_debt(self):
        # Keys deliberately out of numeric order, and one entry owing nothing.
        return {
            "version": drain_prs_service.DRAIN_STATE_VERSION,
            "attempt_counter": 4,
            "prs": {
                "1079": self.entry(
                    self.cleanup(
                        [{"kind": "fast-forward"}],
                        failed_passes=9,
                        last_error="fast-forwarding the default branch: exit code 1",
                    )
                ),
                "12": self.entry(
                    self.cleanup(
                        [
                            {"kind": "issue", "repo": "acme/widgets", "number": 7},
                            {"kind": "worktree"},
                            {"kind": "local-branch", "branch": "issue-7"},
                            {"kind": "remote-branch", "branch": "issue-7"},
                        ]
                    )
                ),
                "8": self.entry(None),
            },
        }

    def assert_unknown(self, document, why):
        """A state the projection cannot trust reports unknown, not empty."""
        self.state_path.write_text(document, encoding="utf-8")
        self.assertIsNone(drain_prs_service.cleanup_obligations(self.repo), why)

    def test_names_every_outstanding_step_in_pull_request_order(self):
        self.write_state(self.state_with_debt())

        self.assertEqual(
            drain_prs_service.cleanup_obligations(self.repo),
            [
                {
                    "pull_request": 12,
                    # The stored order, which is the order the drainer retries
                    # them in: the worktree before the branch it holds.
                    "steps": [
                        "closing acme/widgets#7",
                        "removing the matching worktree",
                        "deleting local branch issue-7",
                        "deleting remote branch issue-7",
                    ],
                    "failed_passes": 0,
                    "last_error": None,
                },
                {
                    "pull_request": 1079,
                    "steps": ["fast-forwarding the default branch"],
                    "failed_passes": 9,
                    "last_error": "fast-forwarding the default branch: exit code 1",
                },
            ],
        )

    def test_a_state_owing_nothing_is_empty_and_an_absent_one_is_unknown(self):
        # The distinction Kanban's sidebar needs: only the first of these is a
        # verified-empty answer.
        self.write_state(
            {
                "version": drain_prs_service.DRAIN_STATE_VERSION,
                "attempt_counter": 0,
                "prs": {
                    "8": self.entry(None),
                    # Discharged down to its last step and not yet dropped.
                    "9": self.entry(self.cleanup([])),
                },
            }
        )
        self.assertEqual(drain_prs_service.cleanup_obligations(self.repo), [])

        self.state_path.unlink()
        self.assertIsNone(drain_prs_service.cleanup_obligations(self.repo))

    def test_no_state_a_status_call_cannot_trust_reports_anything_but_unknown(self):
        healthy = self.state_with_debt()
        self.assert_unknown("{ not json", "malformed JSON")
        self.assert_unknown(json.dumps([]), "a document that is not an object")
        self.assert_unknown(json.dumps({**healthy, "version": 1}), "version 1")
        self.assert_unknown(json.dumps({**healthy, "version": 2}), "version 2")
        self.assert_unknown(
            json.dumps({**healthy, "version": 99}), "an unknown future version"
        )
        self.assert_unknown(json.dumps({"version": 3}), "no prs table")
        self.assert_unknown(json.dumps({"version": 3, "prs": []}), "a non-dict prs")
        # Everything `migrate_drain_state` refuses for the current version is
        # refused here too, whatever the prs table appears to say about debt.
        self.assert_unknown(
            json.dumps({**healthy, "attempt_counter": True}), "a boolean counter"
        )
        self.assert_unknown(
            json.dumps({**healthy, "attempt_counter": "4"}), "a string counter"
        )
        for why, prs in (
            ("a non-dict entry", {"12": "merged"}),
            (
                "an entry naming no approved head",
                {"12": {"cleanup": self.cleanup([{"kind": "worktree"}])}},
            ),
            (
                "an entry whose approved head is not a string",
                {
                    "12": {
                        "approved_head": 7,
                        "cleanup": self.cleanup([{"kind": "worktree"}]),
                    }
                },
            ),
            (
                # Digits alone, so it passes every cheap check, but past
                # Python's integer-string limit `int()` refuses it — and this
                # read is the one that must never raise.
                "a key too long for Python to convert",
                {"1" * 5000: self.entry(self.cleanup([{"kind": "worktree"}]))},
            ),
            ("a non-dict cleanup record", {"12": self.entry("done")}),
            (
                "a non-list pending",
                {"12": self.entry(self.cleanup({"kind": "worktree"}))},
            ),
            ("a non-dict obligation", {"12": self.entry(self.cleanup(["worktree"]))}),
            (
                "an issue step naming no repository",
                {"12": self.entry(self.cleanup([{"kind": "issue", "number": 7}]))},
            ),
            (
                "a branch step naming no branch",
                {"12": self.entry(self.cleanup([{"kind": "local-branch"}]))},
            ),
            (
                "a non-integer failed_passes",
                {
                    "12": self.entry(
                        self.cleanup([{"kind": "worktree"}], failed_passes="many")
                    )
                },
            ),
            (
                "a non-string last_error",
                {"12": self.entry(self.cleanup([{"kind": "worktree"}], last_error=3))},
            ),
            (
                "a key that is no pull-request number",
                {"PR-12": self.entry(self.cleanup([{"kind": "worktree"}]))},
            ),
            (
                "a key naming no pull request at all",
                {"0": self.entry(self.cleanup([{"kind": "worktree"}]))},
            ),
            (
                # `remember_approved_head` files entries under `str(number)`,
                # so a padded key is not one the drainer wrote — and taking it
                # would let one pull request owe twice in the same projection.
                "a key no drainer would have written",
                {"00012": self.entry(self.cleanup([{"kind": "worktree"}]))},
            ),
            (
                # Discharged down to its last step, so nothing is owed, but
                # the record itself is unreadable — and a record owing nothing
                # is still a record.
                "an unreadable value on a record owing nothing",
                {"12": self.entry(self.cleanup([], failed_passes="many"))},
            ),
            (
                "an unreadable error on a record owing nothing",
                {"12": self.entry(self.cleanup([], last_error=3))},
            ),
        ):
            with self.subTest(why=why):
                self.assert_unknown(json.dumps({"version": 3, "prs": prs}), why)

    def test_an_active_candidate_the_drainer_refuses_reports_unknown(self):
        # Exactly the values pinned for `migrate_drain_state` at
        # test_pure_logic.test_an_unreadable_active_candidate_raises, plus the
        # composites, so the two sides are refused over one shared list rather
        # than over two independently chosen ones.
        healthy = self.state_with_debt()
        for active in ("42", 0, -1, True, 4.5, [42], {"pr": 42}):
            with self.subTest(active=active):
                # Carries real debt, so a lane read as acceptable would report
                # that debt and a lane skipped entirely would report it too:
                # only refusing the document gives unknown.
                self.assert_unknown(
                    json.dumps({**healthy, "active_pr": active}),
                    f"an active lane of {active!r}",
                )

    def test_an_active_candidate_the_drainer_accepts_is_read_normally(self):
        healthy = self.state_with_debt()
        for why, document in (
            ("absent", healthy),
            ("null", {**healthy, "active_pr": None}),
            ("a positive pull-request number", {**healthy, "active_pr": 12}),
            # The lane names a candidate drawn from the eligible pull
            # requests, not an entry of the state's own table, and
            # `migrate_drain_state` performs no membership check either.
            ("a number no entry names", {**healthy, "active_pr": 4242}),
        ):
            with self.subTest(why=why):
                self.write_state(document)
                self.assertEqual(
                    [
                        item["pull_request"]
                        for item in drain_prs_service.cleanup_obligations(self.repo)
                    ],
                    [12, 1079],
                    why,
                )

    def test_a_version_3_lane_is_not_checked_at_all(self):
        # Version 3 predates the lane, and `migrate_drain_state` overwrites
        # whatever one carries with null *before* validating it. Such a file
        # is fully usable by the drainer, so its debt is reported rather than
        # reported unknown -- which validating every cleanup-carrying version
        # would silently break.
        self.write_state(
            {**self.state_with_debt(), "version": 3, "active_pr": "not-a-pr"}
        )

        self.assertEqual(
            [
                item["pull_request"]
                for item in drain_prs_service.cleanup_obligations(self.repo)
            ],
            [12, 1079],
        )

    def test_a_malformed_lane_leaves_every_other_status_field_alone(self):
        self.write_status(self.job, self.repo)
        self.write_state(self.state_with_debt())
        healthy = drain_prs_service.status_snapshot(self.job)
        before = self.state_path.read_bytes()
        listing = sorted(path.name for path in (self.repo / ".git").iterdir())
        self.write_state({**self.state_with_debt(), "active_pr": "not-a-pr"})

        degraded = drain_prs_service.status_snapshot(self.job)

        self.assertIsNotNone(healthy["cleanup_obligations"])
        self.assertIsNone(degraded["cleanup_obligations"])
        self.assertEqual(
            {
                key: value
                for key, value in degraded.items()
                if key != "cleanup_obligations"
            },
            {
                key: value
                for key, value in healthy.items()
                if key != "cleanup_obligations"
            },
        )
        # Read-only about the corrupt document too: nothing is repaired, and
        # no temporary file is left beside it.
        self.assertEqual(
            json.loads(self.state_path.read_text(encoding="utf-8"))["active_pr"],
            "not-a-pr",
        )
        self.assertNotEqual(self.state_path.read_bytes(), before)
        self.assertEqual(
            sorted(path.name for path in (self.repo / ".git").iterdir()), listing
        )

    def test_an_unreadable_state_file_reports_unknown(self):
        # Bytes that are not UTF-8 raise a UnicodeDecodeError, which is a
        # ValueError rather than an OSError and so escapes the obvious guard.
        self.state_path.write_bytes(b'{"version": 3, "prs": {"\xff": {}}}')
        self.assertIsNone(drain_prs_service.cleanup_obligations(self.repo))

        # A directory in the file's place stands for every OSError: status is
        # the diagnostic used when the repository is already in a bad state,
        # so it answers unknown rather than failing.
        self.state_path.unlink()
        self.state_path.mkdir()
        self.assertIsNone(drain_prs_service.cleanup_obligations(self.repo))

    def test_a_status_call_survives_a_state_file_that_is_not_text(self):
        self.write_status(self.job, self.repo)
        self.state_path.write_bytes(b"\xff\xfe\x00")
        self.assertIsNone(
            drain_prs_service.status_snapshot(self.job)["cleanup_obligations"]
        )

    def test_a_checkout_with_no_git_entry_reports_unknown(self):
        self.assertIsNone(drain_prs_service.cleanup_obligations(self.root / "absent"))

    def test_a_linked_worktree_reports_the_primary_checkouts_obligations(self):
        # A linked worktree's `.git` is a *file*, so joining the state file's
        # name onto it raises NotADirectoryError. The two checkouts share one
        # git directory, and that is where the drainer's state lives.
        self.write_state(self.state_with_debt())
        linked = self.root / "linked"
        linked.mkdir()
        (linked / ".git").write_text(
            f"gitdir: {self.repo / '.git' / 'worktrees' / 'issue-7'}\n",
            encoding="utf-8",
        )
        self.common_dirs[str(linked)] = str(self.repo / ".git")

        from_primary = drain_prs_service.cleanup_obligations(self.repo)
        from_linked = drain_prs_service.cleanup_obligations(linked)

        self.assertEqual(from_linked, from_primary)
        # Not a false empty set, which is the other way this could fail.
        self.assertEqual([item["pull_request"] for item in from_linked], [12, 1079])

    def test_the_ordinary_checkout_runs_no_command_to_find_its_state(self):
        # Status is polled every ten seconds, so the common path stays a
        # single read: git is asked only by the linked-worktree case above.
        self.write_state(self.state_with_debt())
        self.commands.clear()
        drain_prs_service.cleanup_obligations(self.repo)
        self.assertEqual(self.commands, [])

    def test_a_status_call_reports_the_projection_and_writes_nothing(self):
        self.write_status(self.job, self.repo)
        self.write_state(self.state_with_debt())
        before = self.state_path.read_bytes()
        listing = sorted(path.name for path in (self.repo / ".git").iterdir())

        snapshot = drain_prs_service.status_snapshot(self.job)

        self.assertEqual(
            [item["pull_request"] for item in snapshot["cleanup_obligations"]],
            [12, 1079],
        )
        # Strictly read-only: no lock is taken, and nothing is migrated or
        # repaired — not the document, and not a temporary file beside it.
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(
            sorted(path.name for path in (self.repo / ".git").iterdir()), listing
        )

    def test_a_malformed_state_leaves_every_other_status_field_alone(self):
        self.write_status(self.job, self.repo)
        self.write_state(self.state_with_debt())
        healthy = drain_prs_service.status_snapshot(self.job)
        self.state_path.write_text("{ not json", encoding="utf-8")

        degraded = drain_prs_service.status_snapshot(self.job)

        self.assertIsNotNone(healthy["cleanup_obligations"])
        self.assertIsNone(degraded["cleanup_obligations"])
        self.assertEqual(
            {key: value for key, value in degraded.items() if key != "cleanup_obligations"},
            {key: value for key, value in healthy.items() if key != "cleanup_obligations"},
        )


class AutostashInventoryTests(RedirectedControllerTestCase):
    """The local copies of work `status` projects out of the repository itself:
    autostash anchors the drainer kept, and the stash entries it wrote.

    Against a real temporary Git repository, because what is being projected is
    live Git state -- refs and a reflog -- rather than a document. Every other
    command stays scripted; only the two read-only inventory queries reach the
    real repository.

    Both are otherwise named in one log line per startup sweep, which repeats
    identically every pass, so a possibly-sole copy of someone's work waits for
    a human to read a service log.
    """

    INVENTORY_READS = frozenset({"for-each-ref", "stash"})

    def setUp(self):
        # Captured before the base class patches the seam: the inventory reads
        # have to reach the real repository underneath the scripted fake.
        self.real_run_command = drain_prs_service.run_command
        super().setUp()
        self.failing = set()
        self.malformed = {}
        self.raising = set()

        self.repo = self.root / "widgets"
        self.repo.mkdir()
        self.remotes[(str(self.repo), "origin")] = "git@github.com:acme/widgets.git"
        self.git("init", "-q", "-b", "master", ".")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "Test")
        (self.repo / "shared.txt").write_text("line1\nline2\nline3\n", encoding="utf-8")
        self.git("add", "shared.txt")
        self.git("commit", "-q", "-m", "initial")
        self.job = drain_prs_service.resolve_job(self.repo)
        self.state_path = self.repo / ".git" / "drain_prs_state.json"

    def _run_command(self, args, *, check=True):
        # The inventory's own reads run for real; a test can still make either
        # of them fail or answer nonsense, which is how the unknown states
        # below are reached without corrupting a repository to produce them.
        if args[:1] == ["git"] and args[3:4] and args[3] in self.INVENTORY_READS:
            self.commands.append(list(args))
            if args[3] in self.raising:
                raise OSError("git could not be executed")
            if args[3] in self.failing:
                return _completed(128, stderr="fatal: injected failure")
            if args[3] in self.malformed:
                return _completed(0, stdout=self.malformed[args[3]])
            return self.real_run_command(args, check=False)
        return super()._run_command(args, check=check)

    def git(self, *args):
        proc = subprocess.run(
            ["git", "-C", str(self.repo), *args], text=True, capture_output=True
        )
        if proc.returncode != 0:
            raise RuntimeError(f"git {' '.join(args)} failed:\n{proc.stderr}")
        return proc

    def anchored_snapshot(self, line3):
        """A real `git stash create` commit under a real anchor ref.

        Exactly the pair the drainer leaves behind when a pass is killed or its
        restore conflicts: the floating snapshot commit, and the private ref
        created before the reset so nothing else has to hold it.
        """
        (self.repo / "shared.txt").write_text(f"line1\nline2\n{line3}\n", encoding="utf-8")
        sha = self.git("stash", "create", f"snapshot-{line3}").stdout.strip()
        self.git("checkout", "--", "shared.txt")
        self.assertTrue(sha)
        self.git("update-ref", f"refs/drain-prs/autostash/{sha}", sha)
        return f"refs/drain-prs/autostash/{sha}", sha

    def store(self, message, sha):
        """A stash entry written the one way the drainer writes one."""
        self.git("stash", "store", "-m", message, sha)

    def push_user_stash(self, message):
        """A stash entry pushed the way a human pushes one, wrapper and all."""
        (self.repo / "shared.txt").write_text(f"{message}\n", encoding="utf-8")
        self.git("stash", "push", "-q", "-m", message)

    def commit_date(self, sha):
        return self.git("log", "-1", "--format=%cI", sha).stdout.strip()

    def repository_state(self):
        """Everything this projection may never disturb: every ref, the stash
        in order with its messages, and the stash reflog itself."""
        return (
            self.git("for-each-ref").stdout,
            self.git("stash", "list", "--format=%H %gs").stdout,
            self.git("reflog", "show", "--format=%H %gs", "stash").stdout,
        )

    def inventory(self):
        return drain_prs_service.autostash_inventory(self.repo)

    def test_a_kept_anchor_reports_every_fact_a_recovery_needs(self):
        ref, sha = self.anchored_snapshot("line3-orphaned")

        anchors = self.inventory()["kept_autostash_anchors"]

        # Recovery has to be a supported operation rather than archaeology, so
        # the projection names the same four facts the kept-anchor log line
        # names -- not a ref the reader then has to research.
        self.assertEqual(
            anchors,
            [
                {
                    "ref": ref,
                    "commit": sha,
                    "date": self.commit_date(sha),
                    "restore": f"git stash apply --index {sha}",
                }
            ],
        )

    def test_an_anchor_the_stash_also_holds_is_not_kept(self):
        ref, sha = self.anchored_snapshot("line3-recovered")
        self.store(f"drain-prs-autostash-recovery {sha}", sha)

        inventory = self.inventory()

        # Verified-empty, not unknown: the anchor was enumerated and its
        # snapshot was found, so nothing here holds a sole copy of anything.
        self.assertEqual(inventory["kept_autostash_anchors"], [])
        self.assertEqual(
            inventory["drainer_stashes"],
            [
                {
                    "stash": "stash@{0}",
                    "message": f"drain-prs-autostash-recovery {sha}",
                    "date": self.commit_date(sha),
                }
            ],
        )
        # The anchor is reported on, never acted on. Reaping stays the
        # startup sweep's, and this ref is still exactly where it was.
        self.assertEqual(self.git("rev-parse", ref).stdout.strip(), sha)

    def test_an_entry_below_the_tip_still_matches_its_anchor(self):
        # The proving entry is stash@{1}, which only reading the whole list
        # finds -- ancestry from the refs/stash tip would not.
        _, sha = self.anchored_snapshot("line3-recovered")
        self.store(f"drain-prs-autostash-recovery {sha}", sha)
        self.push_user_stash("user-manual-stash")
        self.assertEqual(
            self.git("stash", "list", "--format=%H").stdout.split()[1], sha
        )

        self.assertEqual(self.inventory()["kept_autostash_anchors"], [])

    def test_both_drainer_message_forms_are_reported(self):
        _, prepared = self.anchored_snapshot("line3-unprepared")
        _, recovered = self.anchored_snapshot("line3-conflicted")
        self.store("drain-prs-autostash-1700000000-4242", prepared)
        self.store(f"drain-prs-autostash-recovery {recovered}", recovered)

        reported = self.inventory()["drainer_stashes"]

        self.assertEqual(
            reported,
            [
                {
                    "stash": "stash@{0}",
                    "message": f"drain-prs-autostash-recovery {recovered}",
                    "date": self.commit_date(recovered),
                },
                {
                    "stash": "stash@{1}",
                    "message": "drain-prs-autostash-1700000000-4242",
                    "date": self.commit_date(prepared),
                },
            ],
        )

    def test_a_user_entry_is_never_reported(self):
        _, sha = self.anchored_snapshot("line3-conflicted")
        self.store(f"drain-prs-autostash-recovery {sha}", sha)
        self.push_user_stash("user-manual-stash")
        self.push_user_stash("WIP on the drain-prs-autostash-recovery branch")

        reported = self.inventory()["drainer_stashes"]

        # The stash is the user's. Only what the drainer itself stored is
        # named, and the rest is not this report's business.
        self.assertEqual(
            [entry["message"] for entry in reported],
            [f"drain-prs-autostash-recovery {sha}"],
        )

    def test_a_merely_similar_message_is_not_a_drainer_entry(self):
        # Classification is the whole exclusion, so it is a full match rather
        # than a prefix: each of these shares the reserved stem and is still
        # somebody's own entry.
        for message in (
            "drain-prs-autostash-notes",
            "drain-prs-autostash-",
            "drain-prs-autostash-1700000000",
            "drain-prs-autostash-1700000000-4242-extra",
            "before drain-prs-autostash-1700000000-4242",
            "drain-prs-autostash-1700000000-4242 after",
            "drain-prs-autostash-recovery",
            "drain-prs-autostash-recovery " + "z" * 40,
            "drain-prs-autostash-recovery " + "a" * 39,
            "drain-prs-autostash-recovery " + "a" * 41,
        ):
            with self.subTest(message=message):
                self.assertIsNone(drain_prs_service.drainer_stash_message(message))

    def test_a_wrapped_payload_is_unwrapped_before_it_is_matched(self):
        # `git stash push -m` records `On <branch>: <message>`; the drainer's
        # own `git stash store -m` records the payload verbatim. The wrapper is
        # a display detail of the entry, not part of what it says.
        _, sha = self.anchored_snapshot("line3-conflicted")
        self.push_user_stash(f"drain-prs-autostash-recovery {sha}")
        self.assertIn(
            "On master: drain-prs-autostash-recovery",
            self.git("stash", "list").stdout,
        )

        reported = self.inventory()["drainer_stashes"]

        # Git records no creator identity, so an exactly forged payload is
        # indistinguishable from the drainer's own and is reported as one.
        self.assertEqual(
            [entry["message"] for entry in reported],
            [f"drain-prs-autostash-recovery {sha}"],
        )

    def test_a_sha256_recovery_payload_is_a_drainer_entry(self):
        # The payload names whatever `git stash create` returned, which is 64
        # hex digits in a sha256 repository.
        self.assertEqual(
            drain_prs_service.drainer_stash_message(
                "drain-prs-autostash-recovery " + "b" * 64
            ),
            "drain-prs-autostash-recovery " + "b" * 64,
        )

    def test_a_checkout_with_nothing_left_behind_reports_verified_empty(self):
        self.push_user_stash("user-manual-stash")

        self.assertEqual(
            self.inventory(),
            {"kept_autostash_anchors": [], "drainer_stashes": []},
        )

    def test_an_unreadable_stash_keeps_every_anchor(self):
        ref, sha = self.anchored_snapshot("line3-recovered")
        self.store(f"drain-prs-autostash-recovery {sha}", sha)
        self.failing.add("stash")

        inventory = self.inventory()

        # Redundant in fact, and still kept: without the list nothing is
        # provably redundant, which is the rule the sweep itself follows.
        self.assertEqual(
            [entry["ref"] for entry in inventory["kept_autostash_anchors"]], [ref]
        )
        self.assertIsNone(inventory["drainer_stashes"])

    def test_each_collection_fails_alone(self):
        _, sha = self.anchored_snapshot("line3-conflicted")
        self.store(f"drain-prs-autostash-recovery {sha}", sha)

        self.failing.add("for-each-ref")
        anchors_failed = self.inventory()
        self.failing.clear()
        self.failing.add("stash")
        stash_failed = self.inventory()

        self.assertIsNone(anchors_failed["kept_autostash_anchors"])
        self.assertEqual(
            [entry["message"] for entry in anchors_failed["drainer_stashes"]],
            [f"drain-prs-autostash-recovery {sha}"],
        )
        self.assertIsNone(stash_failed["drainer_stashes"])
        self.assertIsNotNone(stash_failed["kept_autostash_anchors"])

    def test_output_the_fixed_format_cannot_have_produced_reports_unknown(self):
        """Malformed is unknown, never verified data.

        Both reads answer whether some copy of someone's work is about to be
        missed, so a row skipped or a field taken on trust would turn output
        nobody could parse into `[]` or into a partial list that reads as a
        complete one -- the one answer this must never give.
        """
        ref, sha = self.anchored_snapshot("line3-orphaned")
        date = self.commit_date(sha)
        good = f"{ref} {sha} {date}"
        for why, read, payload in (
            ("an anchor row with no object ID", "for-each-ref", "broken\n"),
            ("one readable anchor row and one not", "for-each-ref", f"{good}\nbroken\n"),
            ("an object ID that is not one", "for-each-ref", f"{ref} nothex {date}\n"),
            (
                "a ref outside the namespace",
                "for-each-ref",
                f"refs/heads/master {sha} {date}\n",
            ),
            ("a date that is not one", "for-each-ref", f"{ref} {sha} yesterday\n"),
            ("a field the format does not have", "for-each-ref", f"{good} extra\n"),
            # The format prints one row per ref and never a blank, so a blank
            # is output it cannot have produced -- and skipping one is exactly
            # how nothing-was-parsed would come back as nothing-is-there.
            ("nothing but a blank row", "for-each-ref", "\n"),
            ("a readable row beside a blank one", "for-each-ref", f"{good}\n\n"),
            ("a row of only whitespace", "for-each-ref", "   \n"),
            ("a truncated stash record", "stash", "stash@{0}\x00"),
            # `-z` terminates every record, so one trailing empty is the whole
            # expected supply of them.
            ("nothing but a record separator", "stash", "\x00"),
            (
                "a readable record beside an empty one",
                "stash",
                f"stash@{{0}}\x1f{sha}\x1f{date}\x1fmessage\x00\x00",
            ),
            (
                "output that stops mid-record",
                "stash",
                f"stash@{{0}}\x1f{sha}\x1f{date}\x1fmessage",
            ),
            (
                "a stash selector that is not one",
                "stash",
                f"stash@0\x1f{sha}\x1f{date}\x1fmessage\x00",
            ),
            (
                "a stash object ID that is not one",
                "stash",
                f"stash@{{0}}\x1fnothex\x1f{date}\x1fmessage\x00",
            ),
            (
                "a stash date that is not one",
                "stash",
                f"stash@{{0}}\x1f{sha}\x1flast Tuesday\x1fmessage\x00",
            ),
        ):
            with self.subTest(why=why):
                self.malformed.clear()
                self.malformed[read] = payload
                inventory = self.inventory()
                spoiled, intact = (
                    ("kept_autostash_anchors", "drainer_stashes")
                    if read == "for-each-ref"
                    else ("drainer_stashes", "kept_autostash_anchors")
                )
                self.assertIsNone(inventory[spoiled], why)
                # And only its own collection: the other read succeeded.
                self.assertIsNotNone(inventory[intact], why)

    def test_every_way_a_read_can_fail_reports_unknown(self):
        self.anchored_snapshot("line3-orphaned")
        for why, arrange in (
            ("a nonzero exit", lambda: self.failing.update(self.INVENTORY_READS)),
            ("git could not be run", lambda: self.raising.update(self.INVENTORY_READS)),
            (
                # A record the fixed format cannot have produced: a partial
                # list would read as a complete one.
                "output no format explains",
                lambda: self.malformed.update({"stash": "stash@{0}\x00"}),
            ),
        ):
            with self.subTest(why=why):
                self.failing.clear()
                self.raising.clear()
                self.malformed.clear()
                arrange()
                inventory = self.inventory()
                self.assertIsNone(inventory["drainer_stashes"], why)

        # A path that is no repository at all answers the same way.
        self.failing.clear()
        self.assertEqual(
            drain_prs_service.autostash_inventory(self.root / "absent"),
            {"kept_autostash_anchors": None, "drainer_stashes": None},
        )

    def test_a_ref_pointing_at_no_commit_still_names_its_anchor(self):
        # `date unknown` rather than a dropped row, exactly as the drainer's
        # own enumeration answers: a ref that cannot be dated is still a ref
        # somebody has to be told about.
        proc = subprocess.run(
            ["git", "-C", str(self.repo), "hash-object", "-w", "--stdin"],
            input="contents\n",
            text=True,
            capture_output=True,
            check=True,
        )
        sha = proc.stdout.strip()
        self.git("update-ref", f"refs/drain-prs/autostash/{sha}", sha)

        anchors = self.inventory()["kept_autostash_anchors"]

        self.assertEqual(
            anchors,
            [
                {
                    "ref": f"refs/drain-prs/autostash/{sha}",
                    "commit": sha,
                    "date": "date unknown",
                    "restore": f"git stash apply --index {sha}",
                }
            ],
        )

    def test_reading_the_inventory_changes_no_ref_and_no_stash_entry(self):
        _, kept = self.anchored_snapshot("line3-orphaned")
        _, recovered = self.anchored_snapshot("line3-conflicted")
        self.store(f"drain-prs-autostash-recovery {recovered}", recovered)
        self.push_user_stash("user-manual-stash")
        before = self.repository_state()

        for _ in range(3):
            self.inventory()

        # Not one ref deleted or created, and the stash keeps its order, its
        # entries, and its reflog. Reporting is all this may ever do.
        self.assertEqual(self.repository_state(), before)
        self.assertIn(kept, before[0])

    def test_a_status_call_reports_both_collections(self):
        self.write_status(self.job, self.repo)
        _, kept = self.anchored_snapshot("line3-orphaned")
        _, recovered = self.anchored_snapshot("line3-conflicted")
        self.store(f"drain-prs-autostash-recovery {recovered}", recovered)

        snapshot = drain_prs_service.status_snapshot(self.job)

        self.assertEqual(
            [entry["commit"] for entry in snapshot["kept_autostash_anchors"]], [kept]
        )
        self.assertEqual(
            [entry["message"] for entry in snapshot["drainer_stashes"]],
            [f"drain-prs-autostash-recovery {recovered}"],
        )

    def test_the_cleanup_projection_survives_an_inventory_that_fails(self):
        # The queue state is a document and the inventory is live Git state:
        # neither says anything about the other, and version 3 and version 4
        # cleanup records keep reporting through an inventory that is unknown.
        self.write_status(self.job, self.repo)
        self.anchored_snapshot("line3-orphaned")
        for version in sorted(drain_prs_service.DRAIN_STATE_CLEANUP_VERSIONS):
            with self.subTest(version=version):
                self.state_path.write_text(
                    json.dumps(
                        {
                            "version": version,
                            "attempt_counter": 4,
                            "prs": {
                                "12": {
                                    "approved_head": "a" * 40,
                                    "cleanup": {
                                        "pr": {
                                            "number": 12,
                                            "headRefName": "issue-7",
                                            "headRefOid": "b" * 40,
                                        },
                                        "pending": [{"kind": "worktree"}],
                                        "failed_passes": 0,
                                        "last_error": None,
                                        "incident": None,
                                    },
                                }
                            },
                        }
                    ),
                    encoding="utf-8",
                )
                self.failing.clear()
                healthy = drain_prs_service.status_snapshot(self.job)
                self.failing.update(self.INVENTORY_READS)
                degraded = drain_prs_service.status_snapshot(self.job)

                self.assertEqual(
                    [item["pull_request"] for item in healthy["cleanup_obligations"]],
                    [12],
                )
                self.assertIsNotNone(healthy["kept_autostash_anchors"])
                self.assertIsNone(degraded["kept_autostash_anchors"])
                self.assertIsNone(degraded["drainer_stashes"])
                self.assertEqual(
                    degraded["cleanup_obligations"], healthy["cleanup_obligations"]
                )

    def test_an_unknown_inventory_leaves_every_other_status_field_alone(self):
        self.write_status(self.job, self.repo)
        self.anchored_snapshot("line3-orphaned")
        healthy = drain_prs_service.status_snapshot(self.job)
        self.failing.update(self.INVENTORY_READS)

        degraded = drain_prs_service.status_snapshot(self.job)

        inventory_keys = {"kept_autostash_anchors", "drainer_stashes"}
        self.assertEqual(
            {k: v for k, v in degraded.items() if k not in inventory_keys},
            {k: v for k, v in healthy.items() if k not in inventory_keys},
        )

    def test_a_linked_worktree_reports_the_shared_repositorys_inventory(self):
        # Refs and the stash both live in the shared git directory, so a
        # linked worktree is answering for the same repository rather than for
        # one of its own -- which is what "per repository" has to mean here.
        _, sha = self.anchored_snapshot("line3-orphaned")
        linked = self.root / "linked"
        self.git("worktree", "add", "-q", "-b", "issue-7", str(linked))

        from_linked = drain_prs_service.autostash_inventory(linked)

        self.assertEqual(from_linked, self.inventory())
        self.assertEqual(
            [entry["commit"] for entry in from_linked["kept_autostash_anchors"]], [sha]
        )


class MirroredCleanupVocabularyTests(unittest.TestCase):
    """The controller restates the drainer's state version and step wording
    rather than importing them, exactly as `in_progress_operation` restates
    its checkout check. These hold the two sides equal."""

    def test_the_state_version_matches_the_drainers(self):
        self.assertEqual(
            drain_prs_service.DRAIN_STATE_VERSION, drain_prs.STATE_VERSION
        )

    def test_the_active_lane_is_read_exactly_as_the_drainer_reads_it(self):
        # Both sides driven over one list of values: whatever the drainer
        # refuses is unknown to the projection, and whatever it accepts is a
        # document the projection reads.
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        repo = Path(tmp.name) / "repo"
        (repo / ".git").mkdir(parents=True)
        state_path = repo / ".git" / "drain_prs_state.json"

        def document(active):
            # Built fresh for each side: migrate mutates the dict it is handed,
            # defaulting fields and nulling a version 3 lane.
            return {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 0,
                "active_pr": active,
                "prs": {},
            }

        for active in (None, 1, 42, "42", 0, -1, True, 4.5, [42], {"pr": 42}):
            with self.subTest(active=active):
                try:
                    drain_prs.migrate_drain_state(document(active), source="test")
                except drain_prs.DrainError:
                    drainer_accepts = False
                else:
                    drainer_accepts = True
                state_path.write_text(json.dumps(document(active)), encoding="utf-8")

                projection = drain_prs_service.cleanup_obligations(repo)

                self.assertEqual(
                    projection is not None,
                    drainer_accepts,
                    f"the two sides disagree about an active lane of {active!r}",
                )

    def test_every_step_is_worded_exactly_as_the_drainer_words_it(self):
        for obligation in (
            {"kind": "issue", "repo": "acme/widgets", "number": 7},
            {"kind": "worktree"},
            {"kind": "local-branch", "branch": "issue-7"},
            {"kind": "remote-branch", "branch": "issue-7"},
            {"kind": "fast-forward"},
            {"kind": "invented-later"},
        ):
            with self.subTest(kind=obligation["kind"]):
                self.assertEqual(
                    drain_prs_service.cleanup_step_description(obligation),
                    drain_prs.describe_cleanup_obligation(obligation),
                )

    def test_every_step_the_drainer_plans_can_be_described(self):
        # A new obligation kind must reach the status projection as its own
        # wording rather than as "unknown cleanup step".
        planned = drain_prs.plan_cleanup(
            {
                "number": 12,
                "headRefName": "issue-7",
                "headRefOid": "b" * 40,
                "closingIssuesReferences": [
                    {
                        "number": 7,
                        "repository": {"owner": {"login": "acme"}, "name": "widgets"},
                    }
                ],
            }
        )["pending"]

        described = [
            drain_prs_service.cleanup_step_description(item) for item in planned
        ]
        self.assertEqual(
            described,
            [drain_prs.describe_cleanup_obligation(item) for item in planned],
        )
        for step in described:
            self.assertNotIn("unknown cleanup step", step)


SOURCE_NAMES = (
    "drain_prs.py",
    "drain_prs_service.py",
    "kanban_config.py",
    "service_manager.py",
)


def _git(repo, *args):
    proc = subprocess.run(
        ["git", "-C", str(repo), *args], text=True, capture_output=True
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"git {' '.join(args)} failed in {repo}: {proc.stderr or proc.stdout}"
        )
    return proc.stdout.strip()


class InstalledSourceAdvisoryTests(unittest.TestCase):
    """Issue #246: the installed drainer executes from links into a live
    development checkout, so a run's own source state is the only record of
    what it actually behaved as. Real temporary repositories throughout — this
    is a claim about what git reports, not about a fake.

    Everything asserted here is report-only. Nothing in this class may refuse,
    delay, or change a drain, which is why the unavailable cases matter as much
    as the divergent ones.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.remote = self.root / "remote.git"
        self.repo = self.root / "checkout"
        self.install = self.root / "install"
        subprocess.run(["git", "init", "-q", "--bare", str(self.remote)], check=True)
        self._make_checkout(self.repo)
        self.install.mkdir()
        for name in SOURCE_NAMES:
            (self.install / name).symlink_to(self.repo / "tools" / name)
        self.point_at(
            controller=self.install / "drain_prs_service.py",
            drainer=self.install / "drain_prs.py",
            config=self.install / "kanban_config.py",
            backend=self.install / "service_manager.py",
        )

    def _make_checkout(self, path, push=True):
        subprocess.run(["git", "init", "-q", str(path)], check=True)
        _git(path, "config", "user.email", "test@example.test")
        _git(path, "config", "user.name", "Test")
        (path / "tools").mkdir(parents=True)
        for name in SOURCE_NAMES:
            (path / "tools" / name).write_text(f"# {name}\n", encoding="utf-8")
        _git(path, "add", "tools")
        _git(path, "commit", "-q", "-m", "initial")
        _git(path, "branch", "-M", "master")
        if push:
            _git(path, "remote", "add", "origin", str(self.remote))
            _git(path, "push", "-q", "origin", "master")
            _git(path, "fetch", "-q", "origin")
        return path

    def point_at(self, *, controller=None, drainer=None, config=None, backend=None):
        for name, value in (
            ("CONTROLLER_PATH", controller),
            ("DRAINER_PATH", drainer),
            ("CONFIG_MODULE_PATH", config),
            ("SERVICE_MANAGER_MODULE_PATH", backend),
        ):
            if value is None:
                continue
            patched = mock.patch.object(drain_prs_service, name, value)
            patched.start()
            self.addCleanup(patched.stop)

    def commit(self, message, name="drain_prs.py", body=None):
        (self.repo / "tools" / name).write_text(
            body or f"# {name}\n# {message}\n", encoding="utf-8"
        )
        _git(self.repo, "add", f"tools/{name}")
        _git(self.repo, "commit", "-q", "-m", message)

    def advance_the_baseline(self, name="drain_prs.py"):
        """Move `origin/master` ahead of this checkout the way a merged PR
        does, leaving the checkout itself on the older commit."""
        original = _git(self.repo, "rev-parse", "HEAD")
        (self.repo / "tools" / name).write_text("# published\n", encoding="utf-8")
        _git(self.repo, "add", f"tools/{name}")
        _git(self.repo, "commit", "-q", "-m", "published elsewhere")
        _git(self.repo, "push", "-q", "origin", "master")
        _git(self.repo, "reset", "-q", "--hard", original)
        _git(self.repo, "fetch", "-q", "origin")

    def audit(self):
        return drain_prs_service.audit_installed_sources()

    def causes_for(self, path):
        audit = self.audit()
        self.assertEqual(audit.unavailable, ())
        matching = [item for item in audit.diverged if item.path == path]
        self.assertEqual(len(matching), 1, f"{path} not named once in {audit.diverged}")
        return matching[0].causes

    def test_sources_matching_the_baseline_report_nothing(self):
        audit = self.audit()
        self.assertEqual(audit, drain_prs_service.SourceAudit())
        self.assertEqual(drain_prs_service.source_advisory_lines(audit), [])

    def test_a_working_tree_edit_is_named_as_one(self):
        (self.repo / "tools" / "drain_prs.py").write_text(
            "# mid-edit\n", encoding="utf-8"
        )
        self.assertEqual(
            self.causes_for("tools/drain_prs.py"), ("working-tree edit",)
        )

    def test_committed_bytes_on_another_branch_name_that_branch(self):
        _git(self.repo, "checkout", "-q", "-b", "agent/issue-1")
        self.commit("on a feature branch")
        causes = self.causes_for("tools/drain_prs.py")
        self.assertIn("non-master HEAD (agent/issue-1)", causes)
        self.assertIn("unpushed commits", causes)
        # The bytes on disk are the committed ones, so this is not an edit.
        self.assertNotIn("working-tree edit", causes)

    def test_a_detached_head_is_named_as_detached(self):
        self.commit("committed, then detached")
        _git(self.repo, "checkout", "-q", "--detach", "HEAD")
        self.assertIn(
            "non-master HEAD (detached)", self.causes_for("tools/drain_prs.py")
        )

    def test_local_master_ahead_of_the_baseline_names_unpushed_commits(self):
        self.commit("committed but never pushed")
        self.assertEqual(
            self.causes_for("tools/drain_prs.py"), ("unpushed commits",)
        )

    def test_local_master_behind_the_baseline_is_attributed_too(self):
        # A clean checkout of an unmodified `master` still executes bytes the
        # baseline no longer has. Without this, such a run explains itself with
        # none of the working-tree, branch, or unpushed causes.
        self.advance_the_baseline()
        self.assertEqual(
            self.causes_for("tools/drain_prs.py"), ("HEAD behind origin/master",)
        )

    def test_a_diverged_local_master_reports_both_directions(self):
        self.advance_the_baseline()
        self.commit("and a local commit on top")
        causes = self.causes_for("tools/drain_prs.py")
        self.assertIn("unpushed commits", causes)
        self.assertIn("HEAD behind origin/master", causes)

    def test_an_edit_on_a_feature_branch_reports_every_applicable_cause(self):
        _git(self.repo, "checkout", "-q", "-b", "agent/issue-2")
        self.commit("committed on the branch")
        (self.repo / "tools" / "drain_prs.py").write_text(
            "# and edited since\n", encoding="utf-8"
        )
        causes = self.causes_for("tools/drain_prs.py")
        self.assertIn("working-tree edit", causes)
        self.assertIn("non-master HEAD (agent/issue-2)", causes)
        self.assertIn("unpushed commits", causes)

    def test_every_differing_source_shares_one_advisory_line(self):
        for name in ("drain_prs.py", "kanban_config.py"):
            (self.repo / "tools" / name).write_text("# mid-edit\n", encoding="utf-8")
        lines = drain_prs_service.source_advisory_lines(self.audit())
        self.assertEqual(len(lines), 1)
        self.assertIn("tools/drain_prs.py", lines[0])
        self.assertIn("tools/kanban_config.py", lines[0])
        self.assertNotIn("tools/drain_prs_service.py", lines[0])

    def test_a_broken_link_is_unavailable_without_hiding_a_divergence(self):
        # The drainer link, not the controller one: a controller that cannot be
        # resolved is a controller that never ran to report anything.
        link = self.install / "drain_prs.py"
        link.unlink()
        link.symlink_to(self.repo / "tools" / "gone.py")
        (self.repo / "tools" / "kanban_config.py").write_text(
            "# mid-edit\n", encoding="utf-8"
        )
        audit = self.audit()
        self.assertEqual(
            [item.path for item in audit.diverged], ["tools/kanban_config.py"]
        )
        self.assertEqual(len(audit.unavailable), 1)
        self.assertIn("drainer", audit.unavailable[0])
        lines = drain_prs_service.source_advisory_lines(audit)
        self.assertEqual(len(lines), 2)
        self.assertIn("tools/kanban_config.py", lines[0])
        self.assertIn("unavailable", lines[1])

    def test_a_source_outside_a_git_repository_is_unavailable(self):
        loose = self.root / "loose.py"
        loose.write_text("# not tracked anywhere\n", encoding="utf-8")
        self.point_at(config=loose)
        audit = self.audit()
        self.assertEqual(audit.diverged, ())
        self.assertEqual(len(audit.unavailable), 1)
        self.assertIn("not inside a git repository", audit.unavailable[0])

    def test_a_checkout_without_the_baseline_ref_is_unavailable(self):
        remoteless = self._make_checkout(self.root / "remoteless", push=False)
        self.point_at(config=remoteless / "tools" / "kanban_config.py")
        audit = self.audit()
        self.assertEqual(audit.diverged, ())
        self.assertEqual(len(audit.unavailable), 1)
        self.assertIn("refs/remotes/origin/master", audit.unavailable[0])

    def test_a_source_absent_from_the_baseline_is_unavailable(self):
        added = self.repo / "tools" / "added_later.py"
        added.write_text("# newer than the baseline\n", encoding="utf-8")
        self.point_at(config=added)
        audit = self.audit()
        self.assertEqual(audit.diverged, ())
        self.assertEqual(len(audit.unavailable), 1)
        self.assertIn("absent from", audit.unavailable[0])

    def test_git_failing_outright_leaves_one_unavailable_line(self):
        with mock.patch.object(
            drain_prs_service.subprocess, "run", side_effect=OSError("no git")
        ):
            audit = self.audit()
        self.assertEqual(audit.diverged, ())
        self.assertEqual(len(audit.unavailable), 4)
        self.assertEqual(len(drain_prs_service.source_advisory_lines(audit)), 1)

    def test_an_unexpected_comparison_failure_is_contained(self):
        with mock.patch.object(
            drain_prs_service, "_audit_source", side_effect=RuntimeError("boom")
        ):
            audit = self.audit()
        self.assertEqual(audit.diverged, ())
        self.assertEqual(len(drain_prs_service.source_advisory_lines(audit)), 1)

    def test_the_audit_never_writes_to_the_repository(self):
        self.commit("committed but never pushed")
        refs = ["for-each-ref", "--format=%(refname) %(objectname)"]
        before = (_git(self.repo, *refs), _git(self.repo, "status", "--porcelain"))
        self.assertNotEqual(self.audit(), drain_prs_service.SourceAudit())
        after = (_git(self.repo, *refs), _git(self.repo, "status", "--porcelain"))
        # No ref moved, so nothing fetched or updated, and the baseline the
        # comparison read is still the one that was already on disk.
        self.assertEqual(before, after)


def _failing_audit():
    raise RuntimeError("boom")


class SourceAdvisoryRunTests(RedirectedControllerTestCase):
    """The advisory reaches the log stream the plist already writes to, ahead
    of both of `run_service`'s refusals, and changes neither of them."""

    def setUp(self):
        super().setUp()
        self.repo = self.checkout("widgets", "git@github.com:acme/widgets.git")
        self.job = drain_prs_service.resolve_job(self.repo)

    def _spawn_run(self, audit=None):
        """One `run_service` whose child exits under the harness, reporting
        what the run returned and whether it spawned. `audit` replaces the
        silent stub; None keeps it."""
        patches = [
            mock.patch.object(drain_prs_service, "require_default_branch"),
            mock.patch.object(drain_prs_service.subprocess, "Popen"),
            mock.patch.object(drain_prs_service, "write_incident"),
        ]
        if audit is not None:
            patches.append(
                mock.patch.object(drain_prs_service, "audit_installed_sources", audit)
            )
        with contextlib.ExitStack() as stack:
            _branch, spawn, _incident = (
                stack.enter_context(patch) for patch in patches[:3]
            )
            for patch in patches[3:]:
                stack.enter_context(patch)
            spawn.return_value.pid = os.getpid()
            spawn.return_value.wait.return_value = 0
            result = drain_prs_service.run_service(self.job, "acme/widgets")
        return result, spawn.call_count

    def test_the_audit_runs_once_for_the_invocation(self):
        self._spawn_run()
        drain_prs_service.audit_installed_sources.assert_called_once_with()

    def test_the_advisory_never_changes_what_the_run_reports(self):
        # Requirement 2 as an equality rather than a constant: whatever this
        # harness makes a run return, an unavailable audit and an outright
        # broken one have to return the same thing, having spawned the same.
        silent = self._spawn_run()
        self.assertEqual(self._spawn_run(self.real_audit_installed_sources), silent)
        self.assertEqual(self._spawn_run(_failing_audit), silent)

    def test_an_unavailable_advisory_still_lets_the_drainer_spawn(self):
        # The installed links do not exist under the redirected roots, so the
        # real audit can compare nothing at all — and the drain runs anyway.
        _result, spawned = self._spawn_run(self.real_audit_installed_sources)
        self.assertEqual(spawned, 1)
        log = self.job.service_log_path.read_text(encoding="utf-8")
        self.assertIn("source advisory unavailable", log)
        self.assertIn("Starting PR drainer", log)

    def test_an_unavailable_advisory_still_reaches_the_identity_refusal(self):
        with (
            mock.patch.object(
                drain_prs_service,
                "audit_installed_sources",
                self.real_audit_installed_sources,
            ),
            mock.patch.object(drain_prs_service, "require_default_branch") as branch,
            mock.patch.object(drain_prs_service.subprocess, "Popen") as spawn,
        ):
            result = drain_prs_service.run_service(self.job, "acme/gadgets")
        self.assertEqual(result, 0)
        spawn.assert_not_called()
        branch.assert_not_called()
        # Both lines land where the plist sends this job's output, and nothing
        # was written under the identity the checkout actually resolves to.
        installed = drain_prs_service.job_for_identity(self.repo, "acme/gadgets")
        log = installed.service_log_path.read_text(encoding="utf-8")
        self.assertIn("source advisory unavailable", log)
        self.assertIn("PR drainer did not start", log)
        self.assertFalse(self.job.log_dir.exists())

    def test_a_quiet_audit_leaves_the_lifecycle_messages_alone(self):
        self._spawn_run()
        log = self.job.service_log_path.read_text(encoding="utf-8")
        self.assertNotIn("source advisory", log)
        self.assertIn("Starting PR drainer", log)


class StopBudgetFitsTheTransitionTests(unittest.TestCase):
    """Issue #216 requirement 5: signal, final cleanup pass, and confirmed exit
    all have to fit inside the timeout Kanban gives a drainer transition, so
    pressing `d` never reports a timeout for a stop whose pass ran.

    Three separately-declared numbers, in two languages, that only hold
    together as a chain. These pin the chain rather than any one of them.
    """

    def _kanban_transition_timeout(self):
        source = (
            Path(__file__).resolve().parent.parent / "src" / "Kanban" / "Drainer.hs"
        ).read_text(encoding="utf-8")
        match = re.search(
            r"^transitionTimeoutSeconds\s*=\s*(\d+)$", source, re.MULTILINE
        )
        self.assertIsNotNone(match, "Drainer.hs no longer declares this literally")
        return int(match.group(1))

    def test_the_pass_leaves_the_stop_room_to_confirm_the_exit(self):
        # The pass is only part of the stop: the signal still has to reach the
        # drainer and its exit still has to be observed, both inside the same
        # STOP_TIMEOUT_SECONDS window.
        self.assertLess(
            drain_prs.SHUTDOWN_CLEANUP_BUDGET_SECONDS,
            drain_prs_service.STOP_TIMEOUT_SECONDS / 2,
        )

    def test_the_whole_stop_fits_the_timeout_kanban_gives_a_transition(self):
        self.assertLess(
            drain_prs_service.STOP_TIMEOUT_SECONDS, self._kanban_transition_timeout()
        )


if __name__ == "__main__":
    unittest.main()
