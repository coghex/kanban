"""Safety tests for the PR drainer installer."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

import drain_prs_service
import install_drainer
import kanban_config
import service_manager


class InstallSymlinkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source_a = self.root / "source-a.py"
        self.source_b = self.root / "source-b.py"
        self.destination = self.root / "installed" / "script.py"
        self.source_a.write_text("a\n", encoding="utf-8")
        self.source_b.write_text("b\n", encoding="utf-8")

    def test_creates_link_and_is_idempotent(self):
        self.assertEqual(
            install_drainer.install_symlink(self.source_a, self.destination), "created"
        )
        self.assertEqual(self.destination.resolve(), self.source_a.resolve())
        self.assertEqual(
            install_drainer.install_symlink(self.source_a, self.destination),
            "unchanged",
        )

    def test_atomically_updates_an_existing_link(self):
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.source_a)
        self.assertEqual(
            install_drainer.install_symlink(self.source_b, self.destination), "updated"
        )
        self.assertEqual(self.destination.resolve(), self.source_b.resolve())

    def test_refuses_to_overwrite_an_ordinary_file(self):
        self.destination.parent.mkdir()
        self.destination.write_text("keep me\n", encoding="utf-8")
        with self.assertRaises(install_drainer.InstallError):
            install_drainer.install_symlink(self.source_a, self.destination)
        self.assertEqual(self.destination.read_text(encoding="utf-8"), "keep me\n")

    def test_replaces_a_broken_link_without_following_it(self):
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.root / "missing.py")
        self.assertTrue(os.path.lexists(self.destination))
        self.assertEqual(
            install_drainer.install_symlink(self.source_a, self.destination), "updated"
        )
        self.assertEqual(self.destination.resolve(), self.source_a.resolve())


class InstallerFixture(unittest.TestCase):
    """A real checkout with the drainer files, every managed path redirected
    under a temporary directory, and no service manager anywhere."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.make_checkout("repo", "git@github.com:acme/widgets.git")
        self.install_dir = self.root / "installed"
        # The installer's keys and every repository's discovery record share
        # one document at the controller's fixed path, so redirect that path
        # rather than writing under the real ~/Library/Application
        # Support/kanban. The remote name is pinned too: resolving an identity
        # reads the shared Kanban configuration, and this must not depend on
        # the developer's own.
        self.shared_config = self.root / "shared" / "config.json"
        controller = install_drainer.drain_prs_service
        for name, value in (
            ("DISCOVERY_RECORD_PATH", self.shared_config),
            ("CONFIG_PATH", self.shared_config),
            ("RUNTIME_ROOT", self.root / "runtime"),
            ("LOG_ROOT", self.root / "logs"),
        ):
            patched = mock.patch.object(controller, name, value)
            patched.start()
            self.addCleanup(patched.stop)
        # The LaunchAgents directory belongs to the backend, so it is
        # redirected on the module that derives paths inside it.
        patched = mock.patch.object(
            install_drainer.service_manager,
            "LAUNCH_AGENTS_DIR",
            self.root / "LaunchAgents",
        )
        patched.start()
        self.addCleanup(patched.stop)
        # Only the remote that decides the *identity* is pinned;
        # configured_remote_name stays real so a repository's own --config
        # still decides what its drainer runs with.
        patched = mock.patch.object(
            controller, "discovery_remote_name", return_value="origin"
        )
        patched.start()
        self.addCleanup(patched.stop)
        # And the backend selection is pinned rather than probed, so these
        # cases answer the same on a macOS laptop and a Linux CI runner. Which
        # manager a host has is settled by `tools/test_service_manager.py`;
        # what is under test here is the installer's own behavior once one has
        # been selected.
        patched = mock.patch.object(
            install_drainer.service_manager,
            "detect_service_manager",
            return_value=install_drainer.service_manager.LAUNCHD,
        )
        patched.start()
        self.addCleanup(patched.stop)

    def make_checkout(self, name, remote_url):
        """A real checkout with the drainer files and a GitHub remote. No
        network: `git remote add` only writes the URL into .git/config."""
        repo = self.root / name
        tools = repo / "tools"
        tools.mkdir(parents=True)
        (tools / "drain_prs.py").write_text("drainer\n", encoding="utf-8")
        (tools / "drain_prs_service.py").write_text("controller\n", encoding="utf-8")
        (tools / "kanban_config.py").write_text("config module\n", encoding="utf-8")
        (tools / "service_manager.py").write_text("backend\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(
            ["git", "-C", str(repo), "remote", "add", "origin", remote_url], check=True
        )
        return repo


class InstallerPolicyTests(InstallerFixture):
    def test_dry_run_makes_no_files_and_never_starts(self):
        with (
            mock.patch.object(install_drainer.sys, "platform", "darwin"),
            mock.patch.object(
                install_drainer, "managed_job_running", return_value=False
            ),
            mock.patch.object(
                install_drainer, "repository_drainer_running", return_value=False
            ),
        ):
            result = install_drainer.install(
                self.repo,
                self.install_dir,
                ntfy_url=None,
                dry_run=True,
            )
        self.assertTrue(result["dry_run"])
        self.assertFalse(result["started"])
        self.assertFalse(self.install_dir.exists())
        # The job it would install is this repository's own, named from the
        # canonical identity its remote resolves to.
        self.assertEqual(result["repository"], "acme/widgets")
        self.assertTrue(result["label"].startswith("com.coghex.drain-prs."))
        self.assertEqual(Path(result["plist"]).name, result["label"] + ".plist")

    def test_a_checkout_with_no_supported_github_remote_cannot_be_installed(self):
        # Its identity is what names the job, so inventing one would install a
        # LaunchAgent Kanban's own resolver would never look for.
        local = self.make_checkout("local", str(self.root / "bare.git"))
        with (
            mock.patch.object(install_drainer.sys, "platform", "darwin"),
            mock.patch.object(
                install_drainer, "repository_drainer_running", return_value=False
            ),
        ):
            with self.assertRaises(install_drainer.InstallError) as raised:
                install_drainer.install(
                    local, self.install_dir, ntfy_url=None, dry_run=True
                )
        self.assertIn("supported GitHub repository", str(raised.exception))

    def test_each_repository_gets_its_own_job_and_record_entry(self):
        gadgets = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        with (
            mock.patch.object(install_drainer.sys, "platform", "darwin"),
            mock.patch.object(
                install_drainer, "managed_job_running", return_value=False
            ),
            mock.patch.object(
                install_drainer, "repository_drainer_running", return_value=False
            ),
        ):
            first = install_drainer.install(
                self.repo, self.install_dir, ntfy_url=None, dry_run=True
            )
            second = install_drainer.install(
                gadgets, self.install_dir, ntfy_url=None, dry_run=True
            )
        self.assertNotEqual(first["repository"], second["repository"])
        self.assertNotEqual(first["label"], second["label"])
        self.assertNotEqual(first["plist"], second["plist"])

    def test_refuses_to_install_while_a_service_is_running(self):
        with (
            mock.patch.object(install_drainer.sys, "platform", "darwin"),
            mock.patch.object(
                install_drainer, "managed_job_running", return_value=True
            ),
        ):
            with self.assertRaises(install_drainer.InstallError):
                install_drainer.install(
                    self.repo,
                    self.install_dir,
                    ntfy_url=None,
                    dry_run=False,
                )
        self.assertFalse(self.install_dir.exists())

    def test_refuses_invalid_notification_url_before_writing(self):
        with (
            mock.patch.object(install_drainer.sys, "platform", "darwin"),
            mock.patch.object(
                install_drainer, "managed_job_running", return_value=False
            ),
            mock.patch.object(
                install_drainer, "repository_drainer_running", return_value=False
            ),
        ):
            with self.assertRaises(install_drainer.InstallError):
                install_drainer.install(
                    self.repo,
                    self.install_dir,
                    ntfy_url="file:///tmp/not-allowed",
                    dry_run=False,
                )
        self.assertFalse(self.install_dir.exists())

    def test_notification_config_is_private_and_not_a_symlink(self):
        path = install_drainer.write_notification_config(
            "https://notify.example.test/topic"
        )
        self.assertEqual(path, self.shared_config)
        self.assertFalse(path.is_symlink())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertIn("notify.example.test", path.read_text(encoding="utf-8"))

    def test_notification_config_refuses_a_symlink_target(self):
        self.shared_config.parent.mkdir()
        outside = self.root / "outside.json"
        outside.write_text("keep\n", encoding="utf-8")
        self.shared_config.symlink_to(outside)
        with self.assertRaises(install_drainer.InstallError):
            install_drainer.write_notification_config(
                "https://notify.example.test/topic"
            )
        self.assertEqual(outside.read_text(encoding="utf-8"), "keep\n")

    def test_a_record_only_config_is_not_a_configured_notification_endpoint(self):
        # The controller records the installed LaunchAgent in this same file,
        # so config.json now exists after every install. Reporting
        # notifications as configured because the file is present would be
        # wrong for every install that never passed --ntfy-url.
        install_drainer.merge_installed_config_json(
            {"launchd_label": "com.example.drain", "plist_path": "/tmp/x.plist"},
        )
        self.assertIsNone(install_drainer.installed_ntfy_url())
        install_drainer.write_notification_config("https://notify.example.test/topic")
        self.assertEqual(
            install_drainer.installed_ntfy_url(),
            "https://notify.example.test/topic",
        )

    def test_writing_the_notification_url_preserves_a_previously_persisted_config_path(
        self,
    ):
        install_drainer.write_installed_config_path(
            "acme/widgets", "/home/user/.config/kanban/config.toml"
        )
        install_drainer.write_notification_config("https://notify.example.test/topic")
        contents = json.loads(self.shared_config.read_text(encoding="utf-8"))
        self.assertEqual(
            contents["repositories"]["acme/widgets"]["config_path"],
            "/home/user/.config/kanban/config.toml",
        )
        self.assertEqual(
            contents["ntfy_url"], "https://notify.example.test/topic"
        )

    def test_writing_the_config_path_preserves_a_previously_persisted_notification_url(
        self,
    ):
        install_drainer.write_notification_config("https://notify.example.test/topic")
        install_drainer.write_installed_config_path(
            "acme/widgets", "/home/user/.config/kanban/config.toml"
        )
        contents = json.loads(self.shared_config.read_text(encoding="utf-8"))
        self.assertEqual(
            contents["ntfy_url"], "https://notify.example.test/topic"
        )
        self.assertEqual(
            contents["repositories"]["acme/widgets"]["config_path"],
            "/home/user/.config/kanban/config.toml",
        )

    def test_a_config_naming_another_remote_still_installs_one_consistent_job(self):
        # The installer resolves the job, stores --config under that identity,
        # and asserts the identity to the installed controller, which resolves
        # it again. A --config whose remote_name differs from the shared
        # configuration's must not move the identity between those two
        # resolutions, or the assertion fails and the install aborts.
        config = self.root / "config.toml"
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
        )

        before = install_drainer.repository_job(self.repo)
        install_drainer.write_installed_config_path(before.identity, str(config))
        after = install_drainer.repository_job(self.repo)

        self.assertEqual(before.identity, "acme/widgets")
        self.assertEqual(after.identity, before.identity)
        self.assertEqual(after.label, before.label)
        # And the configuration still selects what that job runs with.
        self.assertEqual(after.config_path, str(config))
        self.assertEqual(after.remote_name, "upstream")

    def test_one_repositorys_config_path_never_displaces_anothers(self):
        # The endpoint stays global; the configuration each drainer restarts
        # with does not.
        install_drainer.write_notification_config("https://notify.example.test/topic")
        install_drainer.write_installed_config_path(
            "acme/widgets", "/home/user/widgets.toml"
        )
        install_drainer.write_installed_config_path(
            "acme/gadgets", "/home/user/gadgets.toml"
        )
        contents = json.loads(self.shared_config.read_text(encoding="utf-8"))
        self.assertEqual(
            contents["repositories"]["acme/widgets"]["config_path"],
            "/home/user/widgets.toml",
        )
        self.assertEqual(
            contents["repositories"]["acme/gadgets"]["config_path"],
            "/home/user/gadgets.toml",
        )
        self.assertEqual(contents["ntfy_url"], "https://notify.example.test/topic")

    def test_a_custom_install_dir_keeps_its_keys_in_the_one_shared_document(self):
        # --install-dir must not split the configuration from the record: the
        # record's path is fixed because Kanban cannot inherit
        # KANBAN_DRAINER_INSTALL_DIR, so the keys have to live there too.
        install_drainer.write_notification_config("https://notify.example.test/topic")
        install_drainer.write_installed_config_path("acme/widgets", "/home/user/config.toml")
        self.assertFalse((self.install_dir / "config.json").exists())
        contents = json.loads(self.shared_config.read_text(encoding="utf-8"))
        self.assertEqual(contents["ntfy_url"], "https://notify.example.test/topic")
        self.assertEqual(
            contents["repositories"]["acme/widgets"]["config_path"],
            "/home/user/config.toml",
        )

    def test_reinstalling_migrates_a_legacy_install_dir_config(self):
        # What an --install-dir install written before the document's location
        # was fixed left behind. Re-running the installer is already how a
        # pre-record installation is repaired, so it also moves these.
        self.install_dir.mkdir()
        (self.install_dir / "config.json").write_text(
            json.dumps(
                {
                    "ntfy_url": "https://notify.example.test/legacy",
                    "config_path": "/home/user/legacy.toml",
                }
            ),
            encoding="utf-8",
        )
        moved = install_drainer.migrate_legacy_installed_config(self.install_dir)
        self.assertEqual(moved, ["config_path", "ntfy_url"])
        contents = json.loads(self.shared_config.read_text(encoding="utf-8"))
        self.assertEqual(contents["ntfy_url"], "https://notify.example.test/legacy")
        self.assertEqual(contents["config_path"], "/home/user/legacy.toml")

    def test_migration_never_overwrites_the_current_shared_document(self):
        install_drainer.write_notification_config("https://notify.example.test/current")
        self.install_dir.mkdir()
        (self.install_dir / "config.json").write_text(
            json.dumps(
                {
                    "ntfy_url": "https://notify.example.test/stale",
                    "config_path": "/home/user/legacy.toml",
                }
            ),
            encoding="utf-8",
        )
        moved = install_drainer.migrate_legacy_installed_config(self.install_dir)
        self.assertEqual(moved, ["config_path"])
        contents = json.loads(self.shared_config.read_text(encoding="utf-8"))
        self.assertEqual(contents["ntfy_url"], "https://notify.example.test/current")
        self.assertEqual(contents["config_path"], "/home/user/legacy.toml")

    def test_a_default_install_has_no_legacy_document_to_migrate(self):
        default_dir = self.shared_config.parent
        default_dir.mkdir(parents=True)
        install_drainer.write_notification_config("https://notify.example.test/topic")
        self.assertEqual(
            install_drainer.migrate_legacy_installed_config(default_dir), []
        )
        contents = json.loads(self.shared_config.read_text(encoding="utf-8"))
        self.assertEqual(contents["ntfy_url"], "https://notify.example.test/topic")


class InstallerBackendTests(InstallerFixture):
    """The installer reaches the service manager only through the backend.

    Its own responsibilities — symlink safety, the shared document, the
    identity assertion — stay here; deciding whether a job is already running
    is the backend's, and is answered without this process spawning anything.
    Whether this host has a service manager at all is the backend selection's,
    which is the installer's only platform refusal.
    """

    def dry_run(self, backend):
        with (
            mock.patch.object(
                install_drainer, "service_backend", return_value=backend
            ),
            mock.patch.object(
                install_drainer, "repository_drainer_running", return_value=False
            ),
            mock.patch.object(install_drainer, "run", side_effect=self.no_commands),
        ):
            return install_drainer.install(
                self.repo, self.install_dir, ntfy_url=None, dry_run=True
            )

    def no_commands(self, args, *, check=True, env=None):
        raise AssertionError(f"the installer spawned {args!r}")

    def test_the_running_probe_is_the_backends_answer(self):
        job = install_drainer.repository_job(self.repo)
        backend = mock.Mock()
        backend.is_running.return_value = False
        result = self.dry_run(backend)
        backend.is_running.assert_called_once_with(job.label)
        self.assertTrue(result["dry_run"])

    def test_a_backend_reporting_a_running_job_refuses_the_install(self):
        backend = mock.Mock()
        backend.is_running.return_value = True
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.dry_run(backend)
        self.assertIn("Refusing to install", str(raised.exception))

    def test_a_linux_host_with_a_user_session_installs_like_any_other(self):
        # The refusal issue #329 removed. `sys.platform` decides nothing here
        # any more: a host with a usable service manager installs, and the
        # only platform question left is whether it has one.
        backend = mock.Mock()
        backend.is_running.return_value = False
        backend.definition_label.return_value = "unit"
        with mock.patch.object(install_drainer.sys, "platform", "linux"):
            result = self.dry_run(backend)
        self.assertTrue(result["dry_run"])
        self.assertIn("unit", result)
        self.assertNotIn("plist", result)

    def test_a_host_with_no_service_manager_is_refused_before_anything_is_written(self):
        # The one platform refusal that remains, raised by the selection
        # itself and before any link is created: an installation that could
        # never be completed or controlled must not leave half of itself
        # behind.
        with mock.patch.object(
            install_drainer.service_manager, "detect_service_manager", return_value=None
        ):
            with self.assertRaises(install_drainer.InstallError) as raised:
                install_drainer.install(
                    self.repo, self.install_dir, ntfy_url=None, dry_run=False
                )
        self.assertIn("No supported service manager found", str(raised.exception))
        self.assertNotIn("requires macOS", str(raised.exception))
        self.assertFalse(self.install_dir.exists())

    def test_every_module_the_installed_controller_imports_is_linked(self):
        # The controller is executed out of the install directory, so it
        # imports its siblings from there: an unlinked module makes every real
        # install fail at import rather than at install time.
        backend = mock.Mock()
        backend.is_running.return_value = False
        links = self.dry_run(backend)["links"]
        self.assertEqual(
            sorted(links),
            ["config_module", "controller", "drainer", "service_manager"],
        )
        for key, link in links.items():
            with self.subTest(link=key):
                self.assertTrue(Path(link["source"]).is_file(), link["source"])
                self.assertEqual(
                    Path(link["destination"]).parent, self.install_dir
                )
                self.assertEqual(
                    Path(link["source"]).name, Path(link["destination"]).name
                )

    def test_a_checkout_missing_the_backend_module_is_not_installable(self):
        (self.repo / "tools" / "service_manager.py").unlink()
        with self.assertRaises(install_drainer.InstallError) as raised:
            install_drainer.repository_root(self.repo)
        self.assertIn("service_manager.py", str(raised.exception))


class InstallerFailureVocabularyTests(unittest.TestCase):
    """A backend failure reaching the installer is an `InstallError`.

    The installer injects its own `run`, so it never has to translate the
    controller's `ServiceError` — or a third exception type — at the call
    site that reports `{"error": ...}`.
    """

    def setUp(self):
        # Pinned, so that what is under test is the translation rather than
        # the host: an unpinned selection on a runner with no user session
        # would raise before any backend command was reached, and this group
        # would pass without exercising the thing it names.
        patched = mock.patch.object(
            install_drainer.service_manager,
            "detect_service_manager",
            return_value=install_drainer.service_manager.LAUNCHD,
        )
        patched.start()
        self.addCleanup(patched.stop)

    def completed(self, returncode=0, stdout="", stderr=""):
        return subprocess.CompletedProcess([], returncode, stdout, stderr)

    def test_a_host_with_no_service_manager_is_refused_in_that_vocabulary_too(self):
        # The selection's own refusal crosses the same seam as a command
        # failure, so the caller that reports `{"error": ...}` never sees a
        # third exception type.
        with mock.patch.object(
            install_drainer.service_manager, "detect_service_manager", return_value=None
        ):
            with self.assertRaises(install_drainer.InstallError):
                install_drainer.service_backend()

    def test_an_unknown_job_is_not_running_rather_than_an_error(self):
        with mock.patch.object(
            install_drainer.subprocess,
            "run",
            return_value=self.completed(1, stderr="Could not find service"),
        ):
            self.assertFalse(
                install_drainer.service_backend().is_running("com.example.job")
            )

    def test_a_failing_command_is_reported_in_the_installers_vocabulary(self):
        with mock.patch.object(
            install_drainer.subprocess,
            "run",
            return_value=self.completed(1, stderr="boom"),
        ):
            with self.assertRaises(install_drainer.InstallError):
                install_drainer.service_backend().kick("com.example.job")


class FileSnapshotTests(unittest.TestCase):
    """`_restore_file`, which has to put back what a path *is* as well as what
    it holds — a snapshot that only understood bytes would delete anything
    else it found."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_it_restores_a_symlink_rather_than_deleting_it(self):
        target = self.root / "target"
        target.write_text("keep me\n", encoding="utf-8")
        path = self.root / "document"
        path.symlink_to(target)
        restore = install_drainer._restore_file(path)
        # What a write through `os.replace` does to it: the link is gone and a
        # regular file stands where it was.
        path.unlink()
        path.write_text("replaced\n", encoding="utf-8")
        restore()
        self.assertTrue(path.is_symlink())
        self.assertEqual(os.readlink(path), str(target))
        self.assertEqual(target.read_text(encoding="utf-8"), "keep me\n")

    def test_it_restores_bytes_and_absence(self):
        path = self.root / "document"
        path.write_text("before\n", encoding="utf-8")
        restore = install_drainer._restore_file(path)
        path.write_text("after\n", encoding="utf-8")
        restore()
        self.assertEqual(path.read_text(encoding="utf-8"), "before\n")

        missing = self.root / "never-there"
        restore = install_drainer._restore_file(missing)
        missing.write_text("created\n", encoding="utf-8")
        restore()
        self.assertFalse(os.path.lexists(missing))

    def test_it_leaves_alone_a_shape_it_could_not_recreate(self):
        # A directory where a document belongs is not something this put
        # there, so removing it would be the destructive act rather than the
        # safe one.
        path = self.root / "occupied"
        path.mkdir()
        (path / "inside").write_text("mine\n", encoding="utf-8")
        install_drainer._restore_file(path)()
        self.assertTrue(path.is_dir())
        self.assertEqual((path / "inside").read_text(encoding="utf-8"), "mine\n")


class LegacyMigrationFixture(unittest.TestCase):
    """A simulated host with a `~/Library`-spelled drainer installation.

    Hermetic on both counts that matter: `$HOME` and both XDG base directories
    are redirected into a temporary tree and the platform is simulated, so the
    developer's own installation is unreachable and the same cases answer
    identically on a macOS laptop and the Linux CI runner; and the service
    manager is a real `SystemdBackend` driven by a stub runner, so unit files
    are rendered and record entries are shaped for real while no `systemctl`
    is ever spawned.

    The legacy installation is not hand-assembled. It is produced by the
    controller's own writers with the module's managed paths bound under a
    simulated macOS, which is exactly the resolution a pre-XDG Linux install
    ran with — so what these cases migrate is the state that mechanism really
    leaves behind.
    """

    def setUp(self):
        # Registered before every patch below, so it runs after all of them
        # have unwound and the module describes the real host again for
        # whatever runs next in this process.
        self.addCleanup(drain_prs_service.bind_managed_paths)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.start(mock.patch.dict(os.environ, {"HOME": str(self.home)}))
        for variable in (
            "XDG_DATA_HOME",
            "XDG_STATE_HOME",
            "XDG_CONFIG_HOME",
            kanban_config.DRAINER_INSTALL_DIR_ENV,
        ):
            os.environ.pop(variable, None)
        self.start(mock.patch.object(kanban_config.sys, "platform", "linux"))
        self.legacy_install = (
            self.home / "Library" / "Application Support" / "kanban" / "pr-drainer"
        )
        self.legacy_logs = self.home / "Library" / "Logs" / "kanban" / "pr-drainer"
        self.xdg_install = self.home / ".local" / "share" / "kanban" / "pr-drainer"
        self.xdg_logs = self.home / ".local" / "state" / "kanban" / "pr-drainer"
        self.units = self.home / ".config" / "systemd" / "user"
        self.start(mock.patch.object(service_manager, "SYSTEMD_USER_DIR", self.units))
        # A definition renders $HOME into its environment and PATH, so the
        # controller's own frozen copy is redirected too.
        self.start(mock.patch.object(drain_prs_service, "HOME", self.home))
        # Only the remote that decides the *identity* is pinned, so these cases
        # do not depend on the developer's own shared configuration.
        self.start(
            mock.patch.object(
                drain_prs_service, "discovery_remote_name", return_value="origin"
            )
        )
        self.commands = []
        self.controller_calls = []
        self.active = set()
        self.real_run = install_drainer.run
        self.backend = service_manager.SystemdBackend(
            self.fake_run, service_manager.DRAINER_NAMESPACE
        )
        for module in (install_drainer, drain_prs_service):
            self.start(
                mock.patch.object(module, "service_backend", return_value=self.backend)
            )
        self.start(mock.patch.object(install_drainer, "run", self.fake_run))
        drain_prs_service.bind_managed_paths()

    # -- fixture plumbing -------------------------------------------------

    def start(self, patcher):
        patcher.start()
        self.addCleanup(patcher.stop)
        return patcher

    def fake_run(self, args, *, check=True, env=None):
        """Every command the installer or the backend spawns.

        `systemctl` and the installed controller are answered rather than run;
        `git` reaches the real binary against the real temporary checkouts,
        because a repository's identity is what the whole partitioning hangs
        off and faking it would prove nothing.
        """
        self.commands.append(list(args))
        if args and args[0] == "systemctl":
            return subprocess.CompletedProcess(args, 0, self.systemctl_output(args), "")
        if args and args[0] == sys.executable:
            self.controller_calls.append(list(args))
            return subprocess.CompletedProcess(
                args, 0, json.dumps({"installed": True}), ""
            )
        return self.real_run(args, check=check, env=env)

    def systemctl_output(self, args):
        if args[2:3] != ["show"]:
            return ""
        identifier, name = args[3], args[5]
        if name == "ActiveState":
            return "active\n" if identifier in self.active else "inactive\n"
        if name == "LoadState":
            path = self.backend.definition_path(identifier)
            return "loaded\n" if path.is_file() else "not-found\n"
        return "0\n"

    def make_checkout(self, name, remote_url):
        repo = self.root / name
        tools = repo / "tools"
        tools.mkdir(parents=True)
        for module in (
            "drain_prs.py",
            "drain_prs_service.py",
            "kanban_config.py",
            "service_manager.py",
        ):
            (tools / module).write_text(f"# {module}\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(
            ["git", "-C", str(repo), "remote", "add", "origin", remote_url], check=True
        )
        return repo

    def seed_legacy_install(self, *checkouts, install_dir=None, durable=True):
        """The installation a pre-XDG host really has, written by the real
        writers under the resolution that host ran with.

        `install_dir` is the `--install-dir` such a host may have been
        installed with: it moves the script links and the runtime root exactly
        as the option really does, and leaves the discovery record and the log
        root where they are, which is the split the option really produces.
        """
        environment = (
            {kanban_config.DRAINER_INSTALL_DIR_ENV: str(install_dir)}
            if install_dir is not None
            else {}
        )
        patched = mock.patch.object(kanban_config.sys, "platform", "darwin")
        patched.start()
        overridden = mock.patch.dict(os.environ, environment)
        overridden.start()
        try:
            drain_prs_service.bind_managed_paths()
            for checkout in checkouts:
                job = drain_prs_service.resolve_job(checkout)
                drain_prs_service.ensure_dirs(job)
                self.backend.write_definition(drain_prs_service.service_definition(job))
                drain_prs_service.write_discovery_record(job)
                # Durable state the relocation must carry across rather than
                # recreate: an open incident, and a log the operator can still
                # read afterwards.
                (job.incident_dir / "incident.json").write_text(
                    json.dumps({"id": job.slug, "kind": "merge-conflict"}),
                    encoding="utf-8",
                )
                job.service_log_path.write_text(f"log for {job.identity}\n", encoding="utf-8")
            for module in (
                "drain_prs.py",
                "drain_prs_service.py",
                "kanban_config.py",
                "service_manager.py",
            ):
                install_drainer.install_symlink(
                    checkouts[0] / "tools" / module,
                    (install_dir or self.legacy_install) / module,
                )
        finally:
            overridden.stop()
            patched.stop()
        if not durable:
            # A recorded installation whose jobs have never run: the record and
            # the definitions exist, and no runtime or log tree does. That is
            # the shape in which a migration creates every destination
            # directory rather than moving one into place.
            for tree in ((install_dir or self.legacy_install) / "runtime", self.legacy_logs):
                shutil.rmtree(tree, ignore_errors=True)
        # As a fresh process on that host would resolve it: the probe finds the
        # `~/Library` record and nothing under XDG.
        drain_prs_service.bind_managed_paths()

    def record(self, path):
        return json.loads(path.read_text(encoding="utf-8"))

    def install(self, repo, install_dir=None, **options):
        return install_drainer.install(
            repo,
            install_dir if install_dir is not None else Path(
                install_drainer.default_install_destination()
            ),
            ntfy_url=options.pop("ntfy_url", None),
            dry_run=options.pop("dry_run", False),
            **options,
        )


class LegacyMigrationTests(LegacyMigrationFixture):
    def setUp(self):
        super().setUp()
        self.widgets = self.make_checkout("widgets", "git@github.com:acme/widgets.git")
        self.gadgets = self.make_checkout("gadgets", "git@github.com:acme/gadgets.git")
        self.custom = self.root / "custom-install"

    def slug(self, identity):
        return drain_prs_service.repository_slug(identity)

    def unit_text(self, identity):
        return self.backend.definition_path(
            self.backend.service_identifier(self.slug(identity))
        ).read_text(encoding="utf-8")

    def test_a_default_linux_install_relocates_every_recorded_repository(self):
        self.seed_legacy_install(self.widgets, self.gadgets)
        result = self.install(self.widgets)

        migration = result["legacy_migration"]
        self.assertTrue(migration["migrated"])
        self.assertEqual(migration["repositories"], ["acme/gadgets", "acme/widgets"])

        # Both records survive, in the one document at the new location.
        document = self.record(self.xdg_install / "config.json")
        self.assertEqual(
            sorted(document["repositories"]), ["acme/gadgets", "acme/widgets"]
        )
        # Both definitions were rewritten against the destination and reloaded.
        for identity in ("acme/widgets", "acme/gadgets"):
            slug = drain_prs_service.repository_slug(identity)
            unit = self.backend.definition_path(
                self.backend.service_identifier(slug)
            ).read_text(encoding="utf-8")
            self.assertIn(str(self.xdg_install), unit)
            self.assertIn(str(self.xdg_logs / slug), unit)
            self.assertNotIn(str(self.legacy_install), unit)
            # And the durable state came with them, incidents included.
            self.assertTrue(
                (self.xdg_install / "runtime" / slug / "incidents" / "incident.json").is_file()
            )
            self.assertEqual(
                (self.xdg_logs / slug / "service.log").read_text(encoding="utf-8"),
                f"log for {identity}\n",
            )
        self.assertIn(["systemctl", "--user", "daemon-reload"], self.commands)

        # Only then is the legacy installation gone — both of its trees.
        self.assertFalse(self.legacy_install.exists())
        self.assertFalse(self.legacy_logs.exists())

    def test_the_merge_keeps_every_repository_and_installer_key_with_xdg_winning(self):
        self.seed_legacy_install(self.widgets, self.gadgets)
        legacy = self.record(self.legacy_install / "config.json")
        legacy["ntfy_url"] = "https://legacy.example.test/topic"
        legacy["only_legacy"] = "kept"
        (self.legacy_install / "config.json").write_text(
            json.dumps(legacy), encoding="utf-8"
        )
        # A record already at the destination, holding one repository the
        # legacy document also names and one it does not.
        self.xdg_install.mkdir(parents=True)
        (self.xdg_install / "config.json").write_text(
            json.dumps(
                {
                    "ntfy_url": "https://current.example.test/topic",
                    "repositories": {
                        "acme/widgets": dict(
                            legacy["repositories"]["acme/widgets"],
                            config_path="/current/config.toml",
                        )
                    },
                }
            ),
            encoding="utf-8",
        )
        drain_prs_service.bind_managed_paths()

        self.install(self.widgets)

        document = self.record(self.xdg_install / "config.json")
        # No repository dropped, and no installer key silently deleted with the
        # directory the only copy of it lived in.
        self.assertEqual(
            sorted(document["repositories"]), ["acme/gadgets", "acme/widgets"]
        )
        self.assertEqual(document["only_legacy"], "kept")
        # The destination document wins per key, at both levels.
        self.assertEqual(document["ntfy_url"], "https://current.example.test/topic")
        self.assertEqual(
            document["repositories"]["acme/widgets"]["config_path"],
            "/current/config.toml",
        )

    def test_a_custom_destination_installs_there_and_relocates_nothing(self):
        self.seed_legacy_install(self.widgets, self.gadgets)
        elsewhere = self.root / "custom-install"
        result = self.install(self.widgets, elsewhere)

        self.assertFalse(result["legacy_migration"]["migrated"])
        self.assertIn("left exactly as it is", result["legacy_migration"]["reason"])
        self.assertTrue((elsewhere / "drain_prs_service.py").is_symlink())
        # Nothing about the legacy installation moved or was removed.
        self.assertTrue((self.legacy_install / "config.json").is_file())
        self.assertTrue((self.legacy_install / "runtime").is_dir())
        self.assertTrue(self.legacy_logs.is_dir())

    def test_a_macos_host_migrates_nothing_and_removes_nothing(self):
        # Requirement 6 is Linux-only, and this is the invariant it rests on:
        # on macOS the two locations are one directory, so a live install can
        # never be relocated out from under itself.
        self.seed_legacy_install(self.widgets, self.gadgets)
        with mock.patch.object(kanban_config.sys, "platform", "darwin"):
            drain_prs_service.bind_managed_paths()
            self.assertIsNone(install_drainer.legacy_install_dir())
            result = self.install(self.widgets, self.legacy_install)
        self.assertIsNone(result["legacy_migration"])
        self.assertTrue((self.legacy_install / "config.json").is_file())
        self.assertTrue((self.legacy_install / "runtime").is_dir())
        self.assertTrue(self.legacy_logs.is_dir())
        self.assertFalse(self.xdg_install.exists())

    def test_it_carries_the_runtime_state_of_a_custom_install_dir_repository(self):
        # `--install-dir` moves a job's script links and its runtime root while
        # leaving the discovery record under `~/Library`, so its status file
        # and open incidents are not in the legacy tree at all. Repointing its
        # definition at the XDG runtime root without bringing them would make
        # them unreachable, which is exactly the state they exist to survive.
        self.seed_legacy_install(self.widgets, self.gadgets, install_dir=self.custom)
        self.assertTrue(
            (self.custom / "runtime" / self.slug("acme/widgets") / "incidents").is_dir()
        )
        self.assertFalse((self.legacy_install / "runtime").exists())

        result = self.install(self.widgets)
        self.assertTrue(result["legacy_migration"]["migrated"])

        for identity in ("acme/widgets", "acme/gadgets"):
            slug = self.slug(identity)
            self.assertTrue(
                (self.xdg_install / "runtime" / slug / "incidents" / "incident.json").is_file(),
                identity,
            )
            self.assertFalse((self.custom / "runtime" / slug).exists(), identity)
            self.assertIn(str(self.xdg_install), self.unit_text(identity))
        # The operator's own directory is theirs: its script links are left
        # exactly where they were, because nothing here installed them.
        self.assertTrue((self.custom / "drain_prs_service.py").is_symlink())

    def test_it_carries_both_a_legacy_and_a_custom_repositorys_runtime_state(self):
        # The mixed installation, which is the one a single whole-tree move
        # would half-migrate: one repository's state under the legacy install
        # directory and another's under a custom one.
        self.seed_legacy_install(self.widgets)
        self.seed_legacy_install(self.gadgets, install_dir=self.custom)
        self.assertTrue(
            (self.legacy_install / "runtime" / self.slug("acme/widgets")).is_dir()
        )
        self.assertTrue((self.custom / "runtime" / self.slug("acme/gadgets")).is_dir())

        self.install(self.widgets)

        for identity in ("acme/widgets", "acme/gadgets"):
            slug = self.slug(identity)
            self.assertTrue(
                (self.xdg_install / "runtime" / slug / "incidents" / "incident.json").is_file(),
                identity,
            )
        self.assertFalse(self.legacy_install.exists())
        self.assertFalse((self.custom / "runtime" / self.slug("acme/gadgets")).exists())

    def test_the_legacy_record_stays_locked_from_preflight_until_removal(self):
        # The read that decides which repositories exist and the removal that
        # takes away the controller all of them name are the two ends of one
        # transition. A legacy-bound writer slipping in between would add an
        # entry this run never saw, and that repository would keep a definition
        # pointing into a directory this run then deleted.
        self.seed_legacy_install(self.widgets, self.gadgets)
        legacy_record = self.legacy_install / "config.json"
        contended = threading.Event()

        def contender():
            with drain_prs_service.document_lock(legacy_record):
                contended.set()

        observed = []
        real_preflight = install_drainer.preflight_legacy_migration
        real_perform = install_drainer.perform_legacy_migration
        thread = threading.Thread(target=contender, daemon=True)

        def watched_preflight(*args, **kwargs):
            # Started once the lock is already held, so what it reports is
            # whether this transition excludes it rather than whether it
            # happened to run first.
            thread.start()
            observed.append(("before preflight", contended.wait(0.4)))
            return real_preflight(*args, **kwargs)

        def watched_perform(*args, **kwargs):
            observed.append(("before perform", contended.wait(0.1)))
            result = real_perform(*args, **kwargs)
            observed.append(("after removal", contended.wait(0.1)))
            return result

        with (
            mock.patch.object(
                install_drainer, "preflight_legacy_migration", watched_preflight
            ),
            mock.patch.object(
                install_drainer, "perform_legacy_migration", watched_perform
            ),
        ):
            self.install(self.widgets)
        thread.join(5)

        self.assertEqual(
            observed,
            [("before preflight", False), ("before perform", False), ("after removal", False)],
        )
        # And it is released once the run is done, so a waiting writer is
        # serialized behind the transition rather than shut out of it.
        self.assertTrue(contended.wait(5))

    def test_a_sibling_recorded_before_the_lock_is_taken_is_carried_across(self):
        # The other half of the same guarantee: whatever the record holds when
        # the lock is taken is what gets migrated, so a repository another
        # process committed first is never dropped.
        self.seed_legacy_install(self.widgets)
        self.seed_legacy_install(self.gadgets)
        result = self.install(self.widgets)
        self.assertEqual(
            result["legacy_migration"]["repositories"], ["acme/gadgets", "acme/widgets"]
        )
        for identity in ("acme/widgets", "acme/gadgets"):
            self.assertIn(str(self.xdg_install), self.unit_text(identity))
        self.assertEqual(
            sorted(self.record(self.xdg_install / "config.json")["repositories"]),
            ["acme/gadgets", "acme/widgets"],
        )

    # -- refusals, none of which may mutate anything ----------------------

    def assert_nothing_changed(self, message, *, repo=None):
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.install(repo if repo is not None else self.widgets)
        self.assertIn(message, str(raised.exception))
        # Neither the relocation nor a fresh install at the destination: a new
        # installation standing beside a retained legacy one is the split state
        # the refusal exists to prevent, and the XDG-first probe would then
        # hide the legacy siblings.
        self.assertFalse(self.xdg_install.exists())
        self.assertFalse(self.xdg_logs.exists())
        self.assertTrue((self.legacy_install / "config.json").is_file())
        self.assertTrue((self.legacy_install / "runtime").is_dir())
        self.assertTrue(self.legacy_logs.is_dir())

    def test_it_refuses_while_any_recorded_repository_has_a_live_job(self):
        self.seed_legacy_install(self.widgets, self.gadgets)
        # A sibling's job, not this run's own: the shared installation is every
        # recorded repository's, so the guard is broadened to all of them.
        self.active.add(
            self.backend.service_identifier(
                drain_prs_service.repository_slug("acme/gadgets")
            )
        )
        self.assert_nothing_changed("acme/gadgets")

    def test_it_refuses_while_a_sibling_checkout_holds_the_run_lock(self):
        self.seed_legacy_install(self.widgets, self.gadgets)
        git_dir = Path(
            self.real_run(
                ["git", "-C", str(self.gadgets), "rev-parse", "--absolute-git-dir"]
            ).stdout.strip()
        )
        (git_dir / "drain_prs.lock").write_text(f"{os.getpid()}\n", encoding="utf-8")
        self.assert_nothing_changed("acme/gadgets")

    def test_it_refuses_when_a_destination_durable_tree_already_exists(self):
        self.seed_legacy_install(self.widgets, self.gadgets)
        (self.xdg_logs / "acme.widgets").mkdir(parents=True)
        (self.xdg_logs / "acme.widgets" / "service.log").write_text(
            "someone else's\n", encoding="utf-8"
        )
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.install(self.widgets)
        self.assertIn("already exists", str(raised.exception))
        # The refusal names the conflicting paths, and preserves both sides.
        self.assertIn(str(self.legacy_logs), str(raised.exception))
        self.assertEqual(
            (self.xdg_logs / "acme.widgets" / "service.log").read_text(encoding="utf-8"),
            "someone else's\n",
        )
        self.assertTrue((self.legacy_logs / "acme.widgets" / "service.log").is_file())

    def test_it_refuses_when_the_legacy_install_holds_an_unexpected_file(self):
        self.seed_legacy_install(self.widgets, self.gadgets)
        (self.legacy_install / "notes.txt").write_text("mine\n", encoding="utf-8")
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.install(self.widgets)
        self.assertIn("did not put there", str(raised.exception))
        self.assertEqual(
            (self.legacy_install / "notes.txt").read_text(encoding="utf-8"), "mine\n"
        )
        self.assertFalse(self.xdg_install.exists())

    def test_it_refuses_when_a_recorded_sibling_cannot_be_inspected(self):
        # Rewriting a sibling's definition depends on recovering its checkout
        # and its identity exactly. An entry that names neither describes a job
        # this run would leave pointing at a directory it is about to remove.
        self.seed_legacy_install(self.widgets, self.gadgets)
        document = self.record(self.legacy_install / "config.json")
        del document["repositories"]["acme/gadgets"]["repository"]
        (self.legacy_install / "config.json").write_text(
            json.dumps(document), encoding="utf-8"
        )
        self.assert_nothing_changed("no absolute checkout path")

    def test_it_refuses_when_a_definition_names_no_install_directory(self):
        # Without it the runtime state that definition owns cannot be located,
        # so the rewrite would silently orphan it. Recovering it or refusing
        # are the only two answers; this is the refusal.
        self.seed_legacy_install(self.widgets, self.gadgets)
        unit = self.backend.definition_path(
            self.backend.service_identifier(self.slug("acme/gadgets"))
        )
        unit.write_text(
            "\n".join(
                line
                for line in unit.read_text(encoding="utf-8").splitlines()
                if kanban_config.DRAINER_INSTALL_DIR_ENV not in line
            )
            + "\n",
            encoding="utf-8",
        )
        self.assert_nothing_changed(kanban_config.DRAINER_INSTALL_DIR_ENV)

    def test_it_refuses_when_a_definition_cannot_be_read_at_all(self):
        self.seed_legacy_install(self.widgets, self.gadgets)
        self.backend.definition_path(
            self.backend.service_identifier(self.slug("acme/gadgets"))
        ).unlink()
        self.assert_nothing_changed("cannot read an environment out of")

    def test_it_refuses_when_a_custom_runtime_tree_collides_with_the_legacy_one(self):
        # A slug present under both install directories has two candidate
        # trees for one destination. Choosing either would discard the other,
        # so neither is chosen.
        self.seed_legacy_install(self.widgets, install_dir=self.custom)
        stale = self.legacy_install / "runtime" / self.slug("acme/widgets")
        stale.mkdir(parents=True)
        (stale / "status.json").write_text("{}", encoding="utf-8")
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.install(self.widgets)
        self.assertIn("already exists", str(raised.exception))
        self.assertTrue((stale / "status.json").is_file())
        self.assertTrue(
            (self.custom / "runtime" / self.slug("acme/widgets") / "incidents").is_dir()
        )
        self.assertFalse(self.xdg_install.exists())

    def test_it_refuses_an_ordinary_file_wearing_a_managed_name(self):
        # A successful migration deletes the legacy directory whole, so what
        # may be in it is decided by what each entry *is*, not by what it is
        # called. `install_symlink` only ever creates symlinks there; an
        # ordinary file with the same name is a user's, and treating the name
        # as ownership would hand it to `shutil.rmtree`.
        self.seed_legacy_install(self.widgets, self.gadgets)
        impostor = self.legacy_install / "drain_prs.py"
        impostor.unlink()
        impostor.write_text("my own notes, not a link\n", encoding="utf-8")
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.install(self.widgets)
        self.assertIn("did not put there", str(raised.exception))
        self.assertIn(str(impostor), str(raised.exception))
        self.assertEqual(
            impostor.read_text(encoding="utf-8"), "my own notes, not a link\n"
        )
        self.assertFalse(self.xdg_install.exists())

    def test_a_failed_sibling_rewrite_is_rolled_back_whole(self):
        # The one failure the preflight cannot rule out. Without an undo it
        # would leave the trees moved, the merged record winning discovery, and
        # some definitions still naming paths that are gone — a half-migrated
        # installation rather than a refusal.
        self.seed_legacy_install(self.widgets, self.gadgets)
        legacy_record = self.record(self.legacy_install / "config.json")
        units = {
            identity: self.unit_text(identity)
            for identity in ("acme/widgets", "acme/gadgets")
        }
        real = install_drainer._reinstall_recorded_job
        attempted = []

        def failing(job, backend, rollback):
            attempted.append(job.identity)
            if len(attempted) > 1:
                raise install_drainer.InstallError("the second rewrite failed")
            return real(job, backend, rollback)

        with mock.patch.object(install_drainer, "_reinstall_recorded_job", failing):
            with self.assertRaises(install_drainer.InstallError) as raised:
                self.install(self.widgets)
        self.assertIn("Every change it had made was undone", str(raised.exception))
        self.assertNotIn("could not be undone", str(raised.exception))

        # The destination is untouched *whole*, script links included: a
        # refusal that reported nothing was installed while leaving an
        # installation behind would be the split state this all exists to
        # prevent.
        self.assertFalse(self.xdg_install.exists())
        # Every definition is byte-identical to what it was, including the one
        # that had already been rewritten before the failure.
        for identity, before in units.items():
            self.assertEqual(self.unit_text(identity), before, identity)
        # The durable trees are back where they were, with their incidents.
        for identity in ("acme/widgets", "acme/gadgets"):
            slug = self.slug(identity)
            self.assertTrue(
                (self.legacy_install / "runtime" / slug / "incidents" / "incident.json").is_file()
            )
            self.assertTrue((self.legacy_logs / slug / "service.log").is_file())
        self.assertFalse((self.xdg_install / "runtime").exists())
        self.assertFalse(self.xdg_logs.exists())
        # And the record the host resolves is the legacy one again, unchanged.
        self.assertFalse((self.xdg_install / "config.json").exists())
        self.assertEqual(self.record(self.legacy_install / "config.json"), legacy_record)
        self.assertEqual(
            drain_prs_service.DISCOVERY_RECORD_PATH,
            self.legacy_install / "config.json",
        )

    def test_a_rollback_removes_directories_no_tree_was_moved_into(self):
        # The migration that moves nothing still *creates* everything: a
        # legacy install whose jobs have never run has no runtime or log tree,
        # so every destination directory is made rather than moved into place.
        # Those are mutations too, and a refusal that left them behind would
        # report that nothing was installed while having installed exactly
        # that.
        self.seed_legacy_install(self.widgets, self.gadgets, durable=False)
        self.assertFalse((self.legacy_install / "runtime").exists())
        self.assertFalse(self.legacy_logs.exists())

        real = install_drainer._reinstall_recorded_job
        attempted = []

        def failing(job, backend, rollback):
            attempted.append(job.identity)
            if len(attempted) > 1:
                raise install_drainer.InstallError("the second rewrite failed")
            return real(job, backend, rollback)

        with mock.patch.object(install_drainer, "_reinstall_recorded_job", failing):
            with self.assertRaises(install_drainer.InstallError) as raised:
                self.install(self.widgets)
        self.assertIn("Every change it had made was undone", str(raised.exception))
        self.assertNotIn("could not be undone", str(raised.exception))
        # Nothing at either destination root, including the directories the
        # first job's rewrite created before the second one failed.
        self.assertFalse(self.xdg_install.exists())
        self.assertFalse(self.xdg_logs.exists())
        self.assertTrue((self.legacy_install / "config.json").is_file())

    def test_a_rollback_puts_back_a_mode_it_changed_on_an_existing_directory(self):
        # `ensure_dirs` chmods each of this repository's directories to 0700,
        # whether it made them or found them. A refusal must therefore put back
        # the permissions of one that was already there, not only remove the
        # ones it created.
        self.seed_legacy_install(self.widgets, durable=False)
        existing = self.xdg_logs / self.slug("acme/widgets")
        existing.mkdir(parents=True)
        existing.chmod(0o755)
        real = install_drainer._reinstall_recorded_job
        calls = []

        def failing(job, backend, rollback):
            # Let the real rewrite run first, so the chmod actually happens,
            # and fail afterwards.
            calls.append(job.identity)
            real(job, backend, rollback)
            raise install_drainer.InstallError("the rewrite failed after chmod")

        with mock.patch.object(install_drainer, "_reinstall_recorded_job", failing):
            with self.assertRaises(install_drainer.InstallError):
                self.install(self.widgets)
        self.assertEqual(calls, ["acme/widgets"])
        self.assertTrue(existing.is_dir())
        self.assertEqual(existing.stat().st_mode & 0o777, 0o755)

    def test_a_rollback_continues_past_an_undo_that_cannot_reload(self):
        # Restoring a definition hands it back to the service manager, and that
        # reload reaches this module's own `run` — which raises `InstallError`,
        # not `OSError`. An undo loop enumerating the errors it expected would
        # abandon every remaining action at that one, leaving the moved trees
        # and the merged record in place while reporting a clean refusal.
        self.seed_legacy_install(self.widgets, self.gadgets)
        legacy_record = self.record(self.legacy_install / "config.json")

        real_load = self.backend.load_definition
        failed = []

        def load(identifier):
            # Only while undoing: the forward pass must get far enough to have
            # something to roll back.
            if failed:
                raise install_drainer.InstallError(f"{identifier} would not reload")
            return real_load(identifier)

        def failing(job, backend, rollback):
            failed.append(job.identity)
            raise install_drainer.InstallError("the rewrite failed")

        with (
            mock.patch.object(install_drainer, "_reinstall_recorded_job", failing),
            mock.patch.object(self.backend, "load_definition", load),
        ):
            with self.assertRaises(install_drainer.InstallError) as raised:
                self.install(self.widgets)
        self.assertIn("could not be undone", str(raised.exception))
        self.assertIn("would not reload", str(raised.exception))
        # And the actions after the failing one still ran: the trees are back,
        # the merged record is gone, and no destination install remains.
        self.assertTrue((self.legacy_install / "runtime").is_dir())
        self.assertTrue(self.legacy_logs.is_dir())
        self.assertFalse((self.xdg_install / "config.json").exists())
        self.assertFalse(self.xdg_logs.exists())
        self.assertEqual(self.record(self.legacy_install / "config.json"), legacy_record)

    def assert_refuses_a_symlink_at(self, path, contents="someone else's\n"):
        """A path the migration writes *through*, occupied by a symlink.

        `os.replace` replaces one rather than following it, so writing through
        it would destroy it — and a rollback cannot put back what it never
        created. The refusal has to come before the first write.

        `contents` is what the link points at, and for a definition it has to
        be a *usable* one: an unreadable definition is refused a step earlier,
        as un-inspectable, which would leave this check untested.
        """
        target = self.root / f"elsewhere-{path.name}"
        target.write_text(contents, encoding="utf-8")
        path.parent.mkdir(parents=True, exist_ok=True)
        if os.path.lexists(path):
            path.unlink()
        path.symlink_to(target)
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.install(self.widgets)
        self.assertIn("not a regular file", str(raised.exception))
        self.assertTrue(path.is_symlink())
        self.assertEqual(target.read_text(encoding="utf-8"), contents)
        # Refused before the first write, so no destination install exists.
        # Asserted on the links rather than on the directory, which one of
        # these cases has to create in order to occupy a path inside it.
        self.assertFalse(os.path.lexists(self.xdg_install / "drain_prs_service.py"))
        self.assertTrue((self.legacy_install / "config.json").is_file())

    def test_it_refuses_a_symlink_where_the_destination_record_goes(self):
        self.seed_legacy_install(self.widgets, self.gadgets)
        self.assert_refuses_a_symlink_at(self.xdg_install / "config.json")

    def test_it_refuses_a_symlink_where_a_recorded_definition_goes(self):
        self.seed_legacy_install(self.widgets, self.gadgets)
        definition = self.backend.definition_path(
            self.backend.service_identifier(self.slug("acme/gadgets"))
        )
        self.assert_refuses_a_symlink_at(
            definition, contents=definition.read_text(encoding="utf-8")
        )

    def test_a_rollback_that_cannot_finish_is_reported_beside_the_failure(self):
        # Nothing here can repair a host whose filesystem stopped cooperating
        # mid-undo, so the operator is told what was left where rather than
        # given a refusal that reads as if nothing happened.
        self.seed_legacy_install(self.widgets)

        def failing(job, backend, rollback):
            raise install_drainer.InstallError("the rewrite failed")

        def unmovable(move):
            def restore():
                raise OSError(f"{move.destination} could not be moved back")

            return restore

        with (
            mock.patch.object(install_drainer, "_reinstall_recorded_job", failing),
            mock.patch.object(install_drainer, "_restore_move", unmovable),
        ):
            with self.assertRaises(install_drainer.InstallError) as raised:
                self.install(self.widgets)
        self.assertIn("could not be undone", str(raised.exception))
        self.assertIn("could not be moved back", str(raised.exception))
        # The rest of the undo still ran: the destination record it wrote is
        # gone, so a rollback that cannot finish does not also give up.
        self.assertFalse((self.xdg_install / "config.json").exists())

    def test_it_migrates_an_install_directory_holding_a_bytecode_cache(self):
        # A real install directory has one: running the installed modules out
        # of it leaves `__pycache__` there. Refusing it would refuse the
        # ordinary migration, which is the whole default path on Linux.
        self.seed_legacy_install(self.widgets, self.gadgets)
        cache = self.legacy_install / "__pycache__"
        cache.mkdir()
        (cache / "drain_prs_service.cpython-314.pyc").write_bytes(b"\x00bytecode")
        (cache / "kanban_config.cpython-314.pyc").write_bytes(b"\x00bytecode")

        result = self.install(self.widgets)

        self.assertTrue(result["legacy_migration"]["migrated"])
        # Regenerable interpreter output rather than a record of anything, so
        # it goes with the directory rather than being carried across.
        self.assertFalse(self.legacy_install.exists())
        self.assertFalse((self.xdg_install / "__pycache__").exists())

    def test_it_refuses_a_pycache_holding_anything_but_bytecode(self):
        # Verified, not trusted: the name alone must not admit a directory
        # whose contents the removal would then discard.
        self.seed_legacy_install(self.widgets, self.gadgets)
        cache = self.legacy_install / "__pycache__"
        cache.mkdir()
        (cache / "notes.txt").write_text("mine\n", encoding="utf-8")
        with self.assertRaises(install_drainer.InstallError) as raised:
            self.install(self.widgets)
        self.assertIn("did not put there", str(raised.exception))
        self.assertEqual((cache / "notes.txt").read_text(encoding="utf-8"), "mine\n")
        self.assertFalse(self.xdg_install.exists())

    def test_it_refuses_a_sibling_installed_under_the_other_service_manager(self):
        self.seed_legacy_install(self.widgets, self.gadgets)
        document = self.record(self.legacy_install / "config.json")
        document["repositories"]["acme/gadgets"] = {
            "backend": "launchd",
            "launchd_label": "com.coghex.drain-prs.acme.gadgets",
            "plist_path": "/somewhere/com.coghex.drain-prs.acme.gadgets.plist",
            "repository": str(self.gadgets),
        }
        (self.legacy_install / "config.json").write_text(
            json.dumps(document), encoding="utf-8"
        )
        self.assert_nothing_changed("not the systemd service manager")


if __name__ == "__main__":
    unittest.main()
