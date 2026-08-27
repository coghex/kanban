"""Safety tests for the macOS PR drainer installer."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import install_drainer


# The name every case below installs under, and the marker the tracked file of
# that name carries. Both real: a managed link's source and destination always
# share a basename, and ownership is decided by reading the marker rather than
# by the path it happens to be reached through.
LINK_NAME = "drain_prs.py"


def managed_source(directory: Path, note: str) -> Path:
    """A stand-in for one release's tracked copy of that module."""
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / LINK_NAME
    path.write_text(
        f"# {install_drainer.MANAGED_ASSET_PREFIX}pr-drainer/{LINK_NAME}\n{note}\n",
        encoding="utf-8",
    )
    return path


class InstallSymlinkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        # Two releases of one tracked module, and a file of the same name that
        # is nobody's but its owner's.
        self.source_a = managed_source(self.root / "release-a" / "tools", "a")
        self.source_b = managed_source(self.root / "release-b" / "tools", "b")
        self.foreign = self.root / "someone-else" / LINK_NAME
        self.foreign.parent.mkdir(parents=True)
        self.foreign.write_text("not kanban's\n", encoding="utf-8")
        self.destination = self.root / "installed" / LINK_NAME

    def test_creates_link_and_is_idempotent(self):
        self.assertEqual(
            install_drainer.install_symlink(self.source_a, self.destination), "created"
        )
        self.assertEqual(self.destination.resolve(), self.source_a.resolve())
        self.assertEqual(
            install_drainer.install_symlink(self.source_a, self.destination),
            "unchanged",
        )

    def test_atomically_updates_a_link_to_kanbans_own_earlier_copy(self):
        # The upgrade this installer has to converge: the previous release is
        # still on disk, and its link is recognized as Kanban's own by the
        # marker that file carries rather than by where it points.
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.source_a)
        self.assertEqual(
            install_drainer.install_symlink(self.source_b, self.destination), "updated"
        )
        self.assertEqual(self.destination.resolve(), self.source_b.resolve())
        self.assertTrue(self.source_a.is_file(), "the previous release was touched")

    def test_refuses_a_link_to_a_file_that_is_not_kanbans(self):
        # The protection every drainer link used to lack: a same-named file
        # that carries no Kanban marker is someone else's installation, and is
        # preserved rather than silently re-pointed.
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.foreign)
        with self.assertRaises(install_drainer.InstallError) as raised:
            install_drainer.install_symlink(self.source_a, self.destination)
        self.assertIn("not", str(raised.exception).lower())
        self.assertEqual(os.readlink(self.destination), str(self.foreign))
        self.assertEqual(
            self.foreign.read_text(encoding="utf-8"), "not kanban's\n"
        )

    def test_refuses_to_overwrite_an_ordinary_file(self):
        self.destination.parent.mkdir()
        self.destination.write_text("keep me\n", encoding="utf-8")
        with self.assertRaises(install_drainer.InstallError):
            install_drainer.install_symlink(self.source_a, self.destination)
        self.assertEqual(self.destination.read_text(encoding="utf-8"), "keep me\n")

    def test_replaces_a_broken_link_without_following_it(self):
        # Unchanged by the ownership check above, and deliberately so: a
        # target that no longer exists is what a removed checkout leaves
        # behind. It holds nothing to preserve and is exactly the state a
        # re-run has to converge.
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.root / "gone" / LINK_NAME)
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
            ("INSTALL_DIR", self.install_dir),
            ("RUNTIME_ROOT", self.root / "runtime"),
            ("LOG_ROOT", self.root / "logs"),
        ):
            patched = mock.patch.object(controller, name, value)
            patched.start()
            self.addCleanup(patched.stop)
        # Redirected as *answers* as well as as constants. Every discovery
        # record write asks whether the installation this process resolved is
        # still the one this host resolves, and a fixture that pinned only one
        # side of that question would be refused by its own redirection rather
        # than by anything under test.
        for name, value in (
            ("drainer_record_path", self.shared_config),
            ("drainer_install_dir", self.install_dir),
        ):
            patched = mock.patch.object(
                install_drainer.kanban_config, name, return_value=value
            )
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

    def write_asset_tree(self, root, note):
        """The five tracked modules this installer links, each carrying the
        identity marker its real tracked file carries. Written rather than
        copied so a case can tell two releases of the same module apart."""
        tools = root / "tools"
        tools.mkdir(parents=True, exist_ok=True)
        for name in install_drainer._MANAGED_LINK_NAMES:
            (tools / name).write_text(
                f"# {install_drainer.MANAGED_ASSET_PREFIX}pr-drainer/{name}\n"
                f"# {note}\n",
                encoding="utf-8",
            )
        return root

    def make_archive(self, name):
        """An unpacked release archive: the tracked modules, and no `.git`
        anywhere. The real `cabal sdist` archive is exercised as a subprocess
        by `tools/test_source_distribution.py`; this is the shape it has."""
        archive = self.write_asset_tree(self.root / name, name)
        self.assertFalse(list(archive.rglob(".git")), archive)
        return archive.resolve()

    def make_checkout(self, name, remote_url):
        """A real checkout with the drainer files and a GitHub remote. No
        network: `git remote add` only writes the URL into .git/config."""
        repo = self.write_asset_tree(self.root / name, name)
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
                asset_root=self.repo,
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
                    local,
                        self.install_dir,
                        asset_root=local,
                        ntfy_url=None,
                        dry_run=True,
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
                self.repo,
                    self.install_dir,
                    asset_root=self.repo,
                    ntfy_url=None,
                    dry_run=True,
            )
            second = install_drainer.install(
                gadgets,
                    self.install_dir,
                    asset_root=gadgets,
                    ntfy_url=None,
                    dry_run=True,
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
                    asset_root=self.repo,
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
                    asset_root=self.repo,
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
                self.repo,
                    self.install_dir,
                    asset_root=self.repo,
                    ntfy_url=None,
                    dry_run=True,
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
                    self.repo,
                        self.install_dir,
                        asset_root=self.repo,
                        ntfy_url=None,
                        dry_run=False,
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
            [
                "config_module",
                "controller",
                "drainer",
                "models_module",
                "service_manager",
            ],
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

    def test_an_asset_root_missing_the_backend_module_is_not_installable(self):
        (self.repo / "tools" / "service_manager.py").unlink()
        with self.assertRaises(install_drainer.InstallError) as raised:
            install_drainer.asset_root(self.repo)
        self.assertIn("service_manager.py", str(raised.exception))


class ArchiveAssetRootTests(InstallerFixture):
    """Installing from an unpacked release archive against a real checkout.

    The two roots are different trees here: the archive supplies the modules,
    and the checkout is the repository the job drains. Nothing asks the
    archive a Git question, because there is nothing there to answer one.
    """

    def setUp(self):
        super().setUp()
        self.archive = self.make_archive("kanban-1.1.0.0")

    def install(self, *, asset_root=None, dry_run=False, repo=None):
        with (
            mock.patch.object(
                install_drainer, "managed_job_running", return_value=False
            ),
            mock.patch.object(
                install_drainer, "repository_drainer_running", return_value=False
            ),
            mock.patch.object(install_drainer, "run", side_effect=self.record_run),
        ):
            return install_drainer.install(
                repo or self.repo,
                self.install_dir,
                asset_root=self.archive if asset_root is None else asset_root,
                ntfy_url=None,
                dry_run=dry_run,
            )

    def record_run(self, args, *, check=True, env=None):
        """The installed controller, stubbed. Its own installation is
        `tools/test_drain_prs_service.py`'s subject; what is under test here
        is which trees this installer hands it."""
        self.spawned.append(list(args))
        return subprocess.CompletedProcess(
            args, 0, json.dumps({"installed": True}), ""
        )

    def setUpSpawns(self):
        self.spawned = []

    def test_links_resolve_into_the_archive_and_the_job_names_the_checkout(self):
        self.spawned = []
        result = self.install()

        self.assertTrue(result["installed"])
        # The existing field keeps its existing meaning...
        self.assertEqual(result["repo"], str(self.repo))
        self.assertEqual(result["repository"], "acme/widgets")
        # ...and the second root is reported beside it rather than through it.
        self.assertEqual(result["asset_root"], str(self.archive))
        for name in install_drainer._MANAGED_LINK_NAMES:
            with self.subTest(module=name):
                link = self.install_dir / name
                self.assertTrue(link.is_symlink())
                self.assertEqual(
                    link.resolve(), (self.archive / "tools" / name).resolve()
                )
        # The controller is spawned against the checkout, never the archive.
        controller = next(args for args in self.spawned if "install" in args)
        self.assertIn(str(self.repo), controller)
        self.assertNotIn(str(self.archive), controller)

    def test_a_newer_archive_takes_over_the_previous_archives_links(self):
        self.spawned = []
        previous = self.make_archive("kanban-1.0.0.0")
        self.install(asset_root=previous)
        for name in install_drainer._MANAGED_LINK_NAMES:
            self.assertEqual(
                (self.install_dir / name).resolve(),
                (previous / "tools" / name).resolve(),
            )

        self.install(asset_root=self.archive)

        for name in install_drainer._MANAGED_LINK_NAMES:
            with self.subTest(module=name):
                self.assertEqual(
                    (self.install_dir / name).resolve(),
                    (self.archive / "tools" / name).resolve(),
                )
        # The previous archive is still on disk. Recognition is what allowed
        # the takeover, not the old target having gone away.
        self.assertTrue((previous / "tools" / "drain_prs.py").is_file())

    def test_a_link_into_someone_elses_tree_stops_the_install(self):
        self.spawned = []
        foreign = self.root / "someone-else" / "tools"
        foreign.mkdir(parents=True)
        (foreign / "drain_prs.py").write_text("not kanban's\n", encoding="utf-8")
        self.install_dir.mkdir(parents=True)
        (self.install_dir / "drain_prs.py").symlink_to(foreign / "drain_prs.py")

        with self.assertRaises(install_drainer.InstallError) as raised:
            self.install()

        self.assertIn("Refusing to replace", str(raised.exception))
        self.assertEqual(
            (self.install_dir / "drain_prs.py").resolve(),
            (foreign / "drain_prs.py").resolve(),
        )
        self.assertEqual(
            (foreign / "drain_prs.py").read_text(encoding="utf-8"), "not kanban's\n"
        )

    def test_a_dry_run_from_the_archive_writes_nothing(self):
        self.spawned = []
        result = self.install(dry_run=True)

        self.assertTrue(result["dry_run"])
        self.assertEqual(result["asset_root"], str(self.archive))
        self.assertEqual(result["repo"], str(self.repo))
        self.assertFalse(self.install_dir.exists())
        self.assertEqual(self.spawned, [])

    def test_the_default_repo_is_refused_when_it_is_an_archive(self):
        with mock.patch.object(
            install_drainer, "default_asset_root", return_value=self.archive
        ):
            with self.assertRaises(install_drainer.InstallError) as raised:
                install_drainer.selected_target(None)

        message = str(raised.exception)
        self.assertIn("--repo", message)
        self.assertIn(str(self.archive), message)
        self.assertFalse(self.install_dir.exists())

    def test_an_explicit_repo_still_resolves_from_an_archive_default(self):
        with mock.patch.object(
            install_drainer, "default_asset_root", return_value=self.archive
        ):
            self.assertEqual(
                install_drainer.selected_target(str(self.repo)), self.repo.resolve()
            )

    def test_a_checkout_default_is_unchanged(self):
        # The established behavior: run from a checkout with no --repo, the
        # target is that checkout.
        with mock.patch.object(
            install_drainer, "default_asset_root", return_value=self.repo
        ):
            self.assertEqual(install_drainer.selected_target(None), self.repo.resolve())

    def test_an_asset_root_is_not_required_to_be_a_checkout(self):
        self.assertEqual(install_drainer.asset_root(self.archive), self.archive)


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


if __name__ == "__main__":
    unittest.main()
