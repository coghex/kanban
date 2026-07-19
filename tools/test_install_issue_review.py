"""Safety tests for the canonical issue-review backend installer."""

import os
import tempfile
import unittest
from pathlib import Path

import install_issue_review


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
            install_issue_review.install_symlink(self.source_a, self.destination),
            "created",
        )
        self.assertEqual(self.destination.resolve(), self.source_a.resolve())
        self.assertEqual(
            install_issue_review.install_symlink(self.source_a, self.destination),
            "unchanged",
        )

    def test_atomically_updates_an_existing_link(self):
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.source_a)
        self.assertEqual(
            install_issue_review.install_symlink(self.source_b, self.destination),
            "updated",
        )
        self.assertEqual(self.destination.resolve(), self.source_b.resolve())

    def test_refuses_to_overwrite_an_ordinary_file(self):
        self.destination.parent.mkdir()
        self.destination.write_text("keep me\n", encoding="utf-8")
        with self.assertRaises(install_issue_review.InstallError):
            install_issue_review.install_symlink(self.source_a, self.destination)
        self.assertEqual(self.destination.read_text(encoding="utf-8"), "keep me\n")


class LegacyLauncherMigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.kanban_link = self.root / "installed" / "approve_issues.py"
        self.kanban_link.parent.mkdir(parents=True)
        self.kanban_link.write_text("backend\n", encoding="utf-8")
        self.legacy_path = self.root / "legacy" / "approve-issues.py"
        self.legacy_path.parent.mkdir(parents=True)

    def test_creates_symlink_when_legacy_path_is_missing(self):
        result = install_issue_review.migrate_legacy_launcher(
            self.legacy_path, self.kanban_link, allow_migration=False
        )
        self.assertEqual(result["status"], "created")
        self.assertIsNone(result["backup_path"])
        self.assertEqual(self.legacy_path.resolve(), self.kanban_link.resolve())

    def test_points_at_the_stable_link_itself_not_through_it(self):
        # kanban_link is itself a symlink here, exactly as it is in real
        # installs (install_symlink makes it point at the repo checkout).
        # The legacy launcher must stop at kanban_link, one hop, so a
        # repository move only ever requires reinstalling kanban_link.
        repo_backend = self.root / "repo-backend.py"
        repo_backend.write_text("backend\n", encoding="utf-8")
        self.kanban_link.unlink()
        self.kanban_link.symlink_to(repo_backend)

        install_issue_review.migrate_legacy_launcher(
            self.legacy_path, self.kanban_link, allow_migration=False
        )

        self.assertEqual(Path(os.readlink(self.legacy_path)), self.kanban_link)
        self.assertNotEqual(Path(os.readlink(self.legacy_path)), repo_backend)

    def test_repoints_an_existing_symlink_without_opt_in(self):
        other_target = self.root / "other.py"
        other_target.write_text("other\n", encoding="utf-8")
        self.legacy_path.symlink_to(other_target)
        result = install_issue_review.migrate_legacy_launcher(
            self.legacy_path, self.kanban_link, allow_migration=False
        )
        self.assertEqual(result["status"], "updated")
        self.assertEqual(self.legacy_path.resolve(), self.kanban_link.resolve())

    def test_refuses_an_ordinary_file_without_opt_in(self):
        self.legacy_path.write_text("pre-kanban\n", encoding="utf-8")
        result = install_issue_review.migrate_legacy_launcher(
            self.legacy_path, self.kanban_link, allow_migration=False
        )
        self.assertEqual(result["status"], "refused")
        self.assertIsNone(result["backup_path"])
        self.assertEqual(self.legacy_path.read_text(encoding="utf-8"), "pre-kanban\n")
        self.assertFalse(self.legacy_path.is_symlink())

    def test_backs_up_and_migrates_an_ordinary_file_with_opt_in(self):
        self.legacy_path.write_text("pre-kanban\n", encoding="utf-8")
        result = install_issue_review.migrate_legacy_launcher(
            self.legacy_path, self.kanban_link, allow_migration=True
        )
        self.assertEqual(result["status"], "migrated")
        backup = Path(result["backup_path"])
        self.assertEqual(backup.read_text(encoding="utf-8"), "pre-kanban\n")
        self.assertTrue(self.legacy_path.is_symlink())
        self.assertEqual(self.legacy_path.resolve(), self.kanban_link.resolve())

    def test_rerun_after_migration_is_idempotent_without_opt_in(self):
        self.legacy_path.write_text("pre-kanban\n", encoding="utf-8")
        install_issue_review.migrate_legacy_launcher(
            self.legacy_path, self.kanban_link, allow_migration=True
        )
        result = install_issue_review.migrate_legacy_launcher(
            self.legacy_path, self.kanban_link, allow_migration=False
        )
        self.assertEqual(result["status"], "unchanged")

    def test_refuses_when_a_backup_already_exists(self):
        self.legacy_path.write_text("pre-kanban\n", encoding="utf-8")
        backup_path = self.legacy_path.with_name(
            self.legacy_path.name + ".pre-kanban-backup"
        )
        backup_path.write_text("stale backup\n", encoding="utf-8")
        with self.assertRaises(install_issue_review.InstallError):
            install_issue_review.migrate_legacy_launcher(
                self.legacy_path, self.kanban_link, allow_migration=True
            )
        self.assertEqual(self.legacy_path.read_text(encoding="utf-8"), "pre-kanban\n")


class InstallerPolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        tools = self.repo / "tools"
        tools.mkdir(parents=True)
        (tools / "approve_issues.py").write_text("backend\n", encoding="utf-8")
        self.install_dir = self.root / "installed"
        self.legacy_path = self.root / "legacy" / "approve-issues.py"

    def test_dry_run_makes_no_files(self):
        result = install_issue_review.install(
            self.repo,
            self.install_dir,
            self.legacy_path,
            migrate_legacy_launcher_flag=False,
            dry_run=True,
        )
        self.assertTrue(result["dry_run"])
        self.assertFalse(self.install_dir.exists())
        self.assertFalse(self.legacy_path.exists())

    def test_dry_run_reports_a_pending_refusal_for_an_ordinary_legacy_file(self):
        self.legacy_path.parent.mkdir(parents=True)
        self.legacy_path.write_text("pre-kanban\n", encoding="utf-8")
        result = install_issue_review.install(
            self.repo,
            self.install_dir,
            self.legacy_path,
            migrate_legacy_launcher_flag=False,
            dry_run=True,
        )
        self.assertEqual(result["legacy_launcher"]["status"], "refused")
        self.assertEqual(self.legacy_path.read_text(encoding="utf-8"), "pre-kanban\n")

    def test_dry_run_reports_a_pending_migration_when_opted_in(self):
        self.legacy_path.parent.mkdir(parents=True)
        self.legacy_path.write_text("pre-kanban\n", encoding="utf-8")
        result = install_issue_review.install(
            self.repo,
            self.install_dir,
            self.legacy_path,
            migrate_legacy_launcher_flag=True,
            dry_run=True,
        )
        self.assertEqual(result["legacy_launcher"]["status"], "migrated")
        self.assertIsNotNone(result["legacy_launcher"]["backup_path"])
        self.assertEqual(self.legacy_path.read_text(encoding="utf-8"), "pre-kanban\n")

    def test_dry_run_reports_exact_kanban_link_and_legacy_link_changes(self):
        result = install_issue_review.install(
            self.repo,
            self.install_dir,
            self.legacy_path,
            migrate_legacy_launcher_flag=False,
            dry_run=True,
        )
        self.assertEqual(result["kanban_link"]["result"], "created")
        self.assertEqual(result["legacy_launcher"]["status"], "created")
        # A rerun after a real install reports both links as already correct.
        install_issue_review.install(
            self.repo,
            self.install_dir,
            self.legacy_path,
            migrate_legacy_launcher_flag=False,
            dry_run=False,
        )
        rerun = install_issue_review.install(
            self.repo,
            self.install_dir,
            self.legacy_path,
            migrate_legacy_launcher_flag=False,
            dry_run=True,
        )
        self.assertEqual(rerun["kanban_link"]["result"], "unchanged")
        self.assertEqual(rerun["legacy_launcher"]["status"], "unchanged")

    def test_dry_run_reports_an_update_after_the_repository_checkout_moves(self):
        install_issue_review.install(
            self.repo,
            self.install_dir,
            self.legacy_path,
            migrate_legacy_launcher_flag=False,
            dry_run=False,
        )
        moved_repo = self.root / "repo-moved"
        self.repo.rename(moved_repo)
        result = install_issue_review.install(
            moved_repo,
            self.install_dir,
            self.legacy_path,
            migrate_legacy_launcher_flag=False,
            dry_run=True,
        )
        self.assertEqual(result["kanban_link"]["result"], "updated")
        # The legacy symlink points at the stable kanban_link, not at the
        # repository, so it never needs to move when the checkout does.
        self.assertEqual(result["legacy_launcher"]["status"], "unchanged")

    def test_install_creates_stable_link_and_legacy_symlink(self):
        result = install_issue_review.install(
            self.repo,
            self.install_dir,
            self.legacy_path,
            migrate_legacy_launcher_flag=False,
            dry_run=False,
        )
        self.assertTrue(result["installed"])
        kanban_link = self.install_dir / "approve_issues.py"
        self.assertEqual(
            kanban_link.resolve(), (self.repo / "tools" / "approve_issues.py").resolve()
        )
        self.assertEqual(self.legacy_path.resolve(), kanban_link.resolve())

    def test_refuses_when_backend_file_is_missing(self):
        (self.repo / "tools" / "approve_issues.py").unlink()
        with self.assertRaises(install_issue_review.InstallError):
            install_issue_review.install(
                self.repo,
                self.install_dir,
                self.legacy_path,
                migrate_legacy_launcher_flag=False,
                dry_run=False,
            )
        self.assertFalse(self.install_dir.exists())


if __name__ == "__main__":
    unittest.main()
