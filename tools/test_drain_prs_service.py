"""Unit tests for the tracked LaunchAgent controller.

Every test that touches a path redirects it: nothing here may write to the
real ~/Library/LaunchAgents or ~/Library/Application Support/kanban, and no
test invokes launchctl, git against a real remote, or a network.
"""

import fcntl
import json
import os
import plistlib
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

import drain_prs
import drain_prs_service


def _completed(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


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
            ("LAUNCH_AGENTS_DIR", self.launch_agents),
            (
                "LEGACY_PLIST_PATH",
                self.launch_agents / f"{drain_prs_service.LEGACY_LABEL}.plist",
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
        self.loaded.add(drain_prs_service.launch_target(job))
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
                label = f"{drain_prs_service.LABEL_PREFIX}.{slug}"
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
                f"{drain_prs_service.LABEL_PREFIX}.{slug}",
                drain_prs_service.LEGACY_LABEL,
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
            drain_prs_service.launch_target(job).endswith(f"/{job.label}"),
            drain_prs_service.launch_target(job),
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
        self.assertEqual(drain_prs_service.LEGACY_LABEL, "com.coghex.drain-prs")
        self.assertEqual(
            drain_prs_service.LEGACY_PLIST_PATH,
            Path.home() / "Library" / "LaunchAgents" / "com.coghex.drain-prs.plist",
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
            value = plistlib.loads(drain_prs_service.render_plist(job))
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
            value = plistlib.loads(drain_prs_service.render_plist(job))
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
                drain_prs_service.launch_domain(),
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
        widgets_target = drain_prs_service.launch_target(self.widgets_job)

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
            drain_prs_service.LEGACY_LABEL + ".plist"
        )
        self.legacy_target = drain_prs_service.launch_target_for(
            drain_prs_service.LEGACY_LABEL
        )

    def write_legacy_plist(self, repo):
        self.legacy_plist.write_bytes(
            plistlib.dumps(
                {
                    "Label": drain_prs_service.LEGACY_LABEL,
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
                drain_prs_service.launch_domain(),
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

    def test_intentional_stop_resolves_all_open_incidents_for_its_repository(self):
        first = self.write_incident(
            "incident-3.json", repository="acme/widgets", status="open"
        )
        second = self.write_incident(
            "incident-2.json", repository="acme/widgets", status="open"
        )
        other = self.write_incident(
            "incident-1.json", repository="acme/gadgets", status="open"
        )
        already = self.write_incident(
            "incident-0.json", repository="acme/widgets", status="resolved"
        )
        resolved = drain_prs_service.resolve_open_incidents(
            self.job, "Cleared when the PR drainer was intentionally stopped."
        )
        self.assertEqual(set(resolved), {first, second})
        for path in (first, second):
            incident = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(incident["status"], "resolved")
            self.assertIn("resolved_at", incident)
            self.assertEqual(
                incident["resolution"],
                "Cleared when the PR drainer was intentionally stopped.",
            )
        self.assertEqual(
            json.loads(other.read_text(encoding="utf-8"))["status"], "open"
        )
        self.assertEqual(
            json.loads(already.read_text(encoding="utf-8"))["status"], "resolved"
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
            mock.patch.object(drain_prs_service, "launchd_loaded", return_value=False),
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

    def test_stop_clears_incidents_after_the_drainer_has_stopped(self):
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
                "resolve_open_incidents",
                return_value=[Path("incident-1.json"), Path("incident-2.json")],
            ) as resolve_open_incidents,
        ):
            result = drain_prs_service.stop_service(self.job)
        self.assertIn(
            ["launchctl", "kill", "SIGTERM", drain_prs_service.launch_target(self.job)],
            self.commands,
        )
        resolve_open_incidents.assert_called_once_with(
            self.job, "Cleared when the PR drainer was intentionally stopped."
        )
        self.assertEqual(result, {"stopped": True, "cleared_incidents": 2, **stopped})


class CleanupObligationTests(RedirectedControllerTestCase):
    """The post-merge debt `status` projects out of the drainer's queue state.

    Obligations are worked only from inside the polling loop, so a stopped
    drainer neither discharges nor mentions them, and debt under
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
        for why, prs in (
            ("a non-dict entry", {"12": "merged"}),
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
        ):
            with self.subTest(why=why):
                self.assert_unknown(json.dumps({"version": 3, "prs": prs}), why)

    def test_an_unreadable_state_file_reports_unknown(self):
        # Stands for every OSError the read can raise: status is the
        # diagnostic used when the repository is already in a bad state, so it
        # answers unknown rather than failing.
        self.state_path.mkdir()
        self.assertIsNone(drain_prs_service.cleanup_obligations(self.repo))

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


class MirroredCleanupVocabularyTests(unittest.TestCase):
    """The controller restates the drainer's state version and step wording
    rather than importing them, exactly as `in_progress_operation` restates
    its checkout check. These hold the two sides equal."""

    def test_the_state_version_matches_the_drainers(self):
        self.assertEqual(
            drain_prs_service.DRAIN_STATE_VERSION, drain_prs.STATE_VERSION
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


if __name__ == "__main__":
    unittest.main()
