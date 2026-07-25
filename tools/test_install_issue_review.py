"""Safety tests for the canonical issue-review backend installer."""

import contextlib
import io
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import install_issue_review


def managed_asset_text(name: str, note: str = "") -> str:
    """Content that identifies a file as this repository's tracked asset,
    exactly as the real tools/ files do."""
    return f"# {install_issue_review.managed_asset_marker(name)}\n{note}"


class InstallSymlinkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        # Two checkouts of the same repository, which is the shape a
        # repository move produces and the only one install_symlink may
        # re-point: a link already naming this component's file inside some
        # checkout's tools/ directory.
        self.source_a = self.root / "checkout-a" / "tools" / "approve_issues.py"
        self.source_b = self.root / "checkout-b" / "tools" / "approve_issues.py"
        self.destination = self.root / "installed" / "approve_issues.py"
        for source, note in ((self.source_a, "a\n"), (self.source_b, "b\n")):
            source.parent.mkdir(parents=True)
            source.write_text(
                managed_asset_text("approve_issues.py", note), encoding="utf-8"
            )

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

    def test_atomically_updates_a_prior_managed_link_after_the_checkout_moves(self):
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.source_a)
        self.assertEqual(
            install_issue_review.install_symlink(self.source_b, self.destination),
            "updated",
        )
        self.assertEqual(self.destination.resolve(), self.source_b.resolve())

    def test_refuses_to_replace_a_symlink_it_did_not_install(self):
        # Same file name, same tools/ parent, readable target: every shape
        # test passes and only the tracked file's identity marker, which
        # this one does not carry, tells it apart from Kanban's backend.
        unrelated = self.root / "someone-elses-project" / "tools" / "approve_issues.py"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text("#!/usr/bin/env python3\nprint('mine')\n", encoding="utf-8")
        self.destination.parent.mkdir()
        self.destination.symlink_to(unrelated)

        self.assertEqual(
            install_issue_review.plan_symlink(self.source_a.resolve(), self.destination),
            "refused",
        )
        with self.assertRaises(install_issue_review.InstallError):
            install_issue_review.install_symlink(self.source_a, self.destination)
        self.assertEqual(Path(os.readlink(self.destination)), unrelated)

    def test_repoints_a_link_left_broken_by_a_vanished_checkout(self):
        # The state a moved or deleted checkout leaves behind. Refusal
        # exists to protect content, and a broken link holds none, so this
        # is the case a re-run has to converge rather than refuse.
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.root / "gone" / "tools" / "approve_issues.py")
        self.assertEqual(
            install_issue_review.plan_symlink(self.source_a.resolve(), self.destination),
            "updated",
        )

    def test_names_the_recovery_step_for_each_kind_of_refusal(self):
        self.destination.parent.mkdir()
        self.destination.write_text("keep me\n", encoding="utf-8")
        self.assertIn(
            "is not a symlink", install_issue_review.symlink_refusal_reason(self.destination)
        )

        self.destination.unlink()
        unrelated = self.root / "someone-elses-backend.py"
        unrelated.write_text("mine\n", encoding="utf-8")
        self.destination.symlink_to(unrelated)
        reason = install_issue_review.symlink_refusal_reason(self.destination)
        self.assertIn(str(unrelated), reason)
        self.assertIn("does not resolve to Kanban's own tracked backend file", reason)

    def test_refuses_to_overwrite_an_ordinary_file(self):
        self.destination.parent.mkdir()
        self.destination.write_text("keep me\n", encoding="utf-8")
        with self.assertRaises(install_issue_review.InstallError):
            install_issue_review.install_symlink(self.source_a, self.destination)
        self.assertEqual(self.destination.read_text(encoding="utf-8"), "keep me\n")

    def test_updating_a_link_does_not_delete_an_unrelated_file_at_the_naive_temp_name(self):
        self.destination.parent.mkdir()
        self.destination.symlink_to(self.source_a)
        naive_temp = self.destination.with_name(f".{self.destination.name}.tmp")
        naive_temp.write_text("unrelated user file\n", encoding="utf-8")

        self.assertEqual(
            install_issue_review.install_symlink(self.source_b, self.destination), "updated"
        )

        self.assertEqual(self.destination.resolve(), self.source_b.resolve())
        self.assertEqual(naive_temp.read_text(encoding="utf-8"), "unrelated user file\n")


class LegacyLauncherMigrationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.kanban_link = self.root / "installed" / "approve_issues.py"
        self.kanban_link.parent.mkdir(parents=True)
        self.kanban_link.write_text(
            managed_asset_text("approve_issues.py", "backend\n"), encoding="utf-8"
        )
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
        repo_backend.write_text(
            managed_asset_text("approve_issues.py", "backend\n"), encoding="utf-8"
        )
        self.kanban_link.unlink()
        self.kanban_link.symlink_to(repo_backend)

        install_issue_review.migrate_legacy_launcher(
            self.legacy_path, self.kanban_link, allow_migration=False
        )

        self.assertEqual(Path(os.readlink(self.legacy_path)), self.kanban_link)
        self.assertNotEqual(Path(os.readlink(self.legacy_path)), repo_backend)

    def test_repoints_a_launcher_for_another_install_directory_without_opt_in(self):
        other_install = self.root / "other-install" / "approve_issues.py"
        other_install.parent.mkdir(parents=True)
        other_install.write_text(
            managed_asset_text("approve_issues.py", "other\n"), encoding="utf-8"
        )
        self.legacy_path.symlink_to(other_install)
        result = install_issue_review.migrate_legacy_launcher(
            self.legacy_path, self.kanban_link, allow_migration=False
        )
        self.assertEqual(result["status"], "updated")
        self.assertEqual(self.legacy_path.resolve(), self.kanban_link.resolve())

    def test_refuses_a_symlink_that_is_not_a_canonical_backend_even_with_opt_in(self):
        # Named exactly like a canonical backend, so only its missing
        # identity marker distinguishes it.
        other_target = self.root / "someone-elses-install" / "approve_issues.py"
        other_target.parent.mkdir(parents=True)
        other_target.write_text("#!/usr/bin/env python3\nprint('mine')\n", encoding="utf-8")
        self.legacy_path.symlink_to(other_target)

        for allow_migration in (False, True):
            result = install_issue_review.migrate_legacy_launcher(
                self.legacy_path, self.kanban_link, allow_migration=allow_migration
            )
            self.assertEqual(result["status"], "refused", allow_migration)
            self.assertIn(str(other_target), result["message"])
        # Preserved exactly, and nothing was backed up: a symlink has no
        # content to preserve, so refusal is the only safe outcome.
        self.assertEqual(Path(os.readlink(self.legacy_path)), other_target)
        self.assertFalse(
            os.path.lexists(self.legacy_path.with_name(self.legacy_path.name + ".pre-kanban-backup"))
        )

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
        (tools / "approve_issues.py").write_text(
            managed_asset_text("approve_issues.py", "backend\n"), encoding="utf-8"
        )
        (tools / "kanban_config.py").write_text(
            managed_asset_text("kanban_config.py", "config module\n"), encoding="utf-8"
        )
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

    def test_dry_run_fails_instead_of_promising_a_migration_a_stale_backup_blocks(self):
        self.legacy_path.parent.mkdir(parents=True)
        self.legacy_path.write_text("pre-kanban\n", encoding="utf-8")
        backup_path = self.legacy_path.with_name(self.legacy_path.name + ".pre-kanban-backup")
        backup_path.write_text("stale backup\n", encoding="utf-8")

        with self.assertRaises(install_issue_review.InstallError):
            install_issue_review.install(
                self.repo,
                self.install_dir,
                self.legacy_path,
                migrate_legacy_launcher_flag=True,
                dry_run=True,
            )

        self.assertEqual(self.legacy_path.read_text(encoding="utf-8"), "pre-kanban\n")
        self.assertEqual(backup_path.read_text(encoding="utf-8"), "stale backup\n")

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


class CLIOutputTests(unittest.TestCase):
    """The plain (non-JSON) CLI output is the default a user actually sees,
    so it must report the exact plan too, not only --json."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        tools = self.repo / "tools"
        tools.mkdir(parents=True)
        (tools / "approve_issues.py").write_text(
            managed_asset_text("approve_issues.py", "backend\n"), encoding="utf-8"
        )
        (tools / "kanban_config.py").write_text(
            managed_asset_text("kanban_config.py", "config module\n"), encoding="utf-8"
        )
        subprocess.run(
            ["git", "init", "-q", str(self.repo)], check=True, capture_output=True
        )
        self.install_dir = self.root / "installed"
        self.legacy_path = self.root / "legacy" / "approve-issues.py"

    def run_cli(self, *extra_args):
        argv = [
            "install_issue_review.py",
            "--repo",
            str(self.repo),
            "--install-dir",
            str(self.install_dir),
            "--legacy-path",
            str(self.legacy_path),
            *extra_args,
        ]
        buffer = io.StringIO()
        with mock.patch.object(sys, "argv", argv):
            with contextlib.redirect_stdout(buffer):
                exit_code = install_issue_review.main()
        return exit_code, buffer.getvalue()

    def test_plain_dry_run_output_reports_the_exact_plan(self):
        exit_code, output = self.run_cli("--dry-run")
        self.assertEqual(exit_code, 0)
        self.assertIn("Dry run for", output)
        self.assertIn("Kanban-managed launcher", output)
        self.assertIn(": created", output)
        self.assertIn("Legacy launcher", output)
        self.assertFalse(self.install_dir.exists())

    def test_plain_dry_run_output_reports_an_update_after_a_repository_move(self):
        self.run_cli()
        moved_repo = self.root / "repo-moved"
        self.repo.rename(moved_repo)
        _, output = self.run_cli("--repo", str(moved_repo), "--dry-run")
        self.assertIn("Kanban-managed launcher", output)
        self.assertIn(": updated", output)
        self.assertIn("Legacy launcher", output)
        self.assertIn(": unchanged", output)

    def test_plain_install_output_reports_the_result(self):
        exit_code, output = self.run_cli()
        self.assertEqual(exit_code, 0)
        self.assertIn("Installed the canonical issue-review backend", output)
        self.assertIn("Kanban-managed launcher", output)
        self.assertIn(": created", output)
        self.assertIn("Legacy launcher", output)


if __name__ == "__main__":
    unittest.main()
