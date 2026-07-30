"""Safety tests for the macOS PR drainer installer."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import install_drainer


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


class InstallerPolicyTests(unittest.TestCase):
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
            ("LAUNCH_AGENTS_DIR", self.root / "LaunchAgents"),
            ("RUNTIME_ROOT", self.root / "runtime"),
            ("LOG_ROOT", self.root / "logs"),
        ):
            patched = mock.patch.object(controller, name, value)
            patched.start()
            self.addCleanup(patched.stop)
        patched = mock.patch.object(
            controller, "configured_remote_name", return_value="origin"
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
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(
            ["git", "-C", str(repo), "remote", "add", "origin", remote_url], check=True
        )
        return repo

    def test_dry_run_makes_no_files_and_never_starts(self):
        with (
            mock.patch.object(install_drainer.sys, "platform", "darwin"),
            mock.patch.object(
                install_drainer, "launchd_job_running", return_value=False
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
                install_drainer, "launchd_job_running", return_value=False
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
                install_drainer, "launchd_job_running", return_value=True
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
                install_drainer, "launchd_job_running", return_value=False
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


if __name__ == "__main__":
    unittest.main()
