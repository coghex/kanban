"""Integration tests for drain_prs.fast_forward_default_branch()'s stash
safety: a failed snapshot attempt must abort cleanly, and restoring local
changes afterward must never read or write the shared `refs/stash` reflog
that a concurrent `git stash` in another terminal also uses -- against a
real temporary Git repository.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import drain_prs


def run_git(args, *, cwd, check=True):
    proc = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        text=True,
        capture_output=True,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed in {cwd}:\n{proc.stdout}\n{proc.stderr}"
        )
    return proc


def stash_shas(cwd):
    proc = run_git(["stash", "list", "--format=%H"], cwd=cwd)
    return [line for line in proc.stdout.strip().splitlines() if line]


class _FastForwardStashFixture(unittest.TestCase):
    """Common repo layout: a bare `origin` and a `main` checkout one commit
    ahead of nothing, with a multi-line tracked file so tests can dirty one
    line locally while `origin` advances a different one.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

        self.bare = self.root / "remote.git"
        self.main = self.root / "main"

        run_git(["init", "--bare", "-q", "-b", "master", str(self.bare)], cwd=self.root)
        run_git(["init", "-q", "-b", "master", str(self.main)], cwd=self.root)
        run_git(["config", "user.email", "test@example.com"], cwd=self.main)
        run_git(["config", "user.name", "Test"], cwd=self.main)

        (self.main / "shared.txt").write_text("line1\nline2\nline3\n", encoding="utf-8")
        run_git(["add", "shared.txt"], cwd=self.main)
        run_git(["commit", "-q", "-m", "initial"], cwd=self.main)
        run_git(["remote", "add", "origin", str(self.bare)], cwd=self.main)
        run_git(["push", "-q", "-u", "origin", "master"], cwd=self.main)

        self.ctx = drain_prs.RepoContext(self.main, "example/project", "project", "master")

    def _advance_origin_line1(self, new_line1):
        clone_dir = Path(tempfile.mkdtemp(dir=str(self.root)))
        run_git(["clone", "-q", str(self.bare), str(clone_dir)], cwd=self.root)
        run_git(["config", "user.email", "test@example.com"], cwd=clone_dir)
        run_git(["config", "user.name", "Test"], cwd=clone_dir)
        lines = (clone_dir / "shared.txt").read_text(encoding="utf-8").splitlines()
        lines[0] = new_line1
        (clone_dir / "shared.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        run_git(["commit", "-q", "-am", "advance shared.txt"], cwd=clone_dir)
        run_git(["push", "-q", "origin", "master"], cwd=clone_dir)

    def _seed_unrelated_stash(self):
        (self.main / "other.txt").write_text("other\n", encoding="utf-8")
        run_git(["add", "other.txt"], cwd=self.main)
        run_git(["commit", "-q", "-m", "add other.txt"], cwd=self.main)
        run_git(["push", "-q", "origin", "master"], cwd=self.main)
        (self.main / "other.txt").write_text("other-user-edit\n", encoding="utf-8")
        run_git(["stash", "push", "-q", "-m", "user-manual-stash"], cwd=self.main)
        return stash_shas(self.main)[0]


class SuccessfulStashRestoreTest(_FastForwardStashFixture):
    def test_stash_restore_roundtrip_preserves_other_stash_entries(self):
        user_stash_sha = self._seed_unrelated_stash()

        lines = (self.main / "shared.txt").read_text(encoding="utf-8").splitlines()
        lines[2] = "line3-local"
        (self.main / "shared.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        self._advance_origin_line1("line1-updated")

        drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        self.assertEqual(
            (self.main / "shared.txt").read_text(encoding="utf-8"),
            "line1-updated\nline2\nline3-local\n",
        )
        # This run never reads or writes the shared stash list on the
        # success path, so the pre-existing user entry is untouched.
        self.assertEqual(stash_shas(self.main), [user_stash_sha])


class StagedAndUnstagedRestoreTest(_FastForwardStashFixture):
    def test_staged_index_and_untracked_file_both_restored(self):
        user_stash_sha = self._seed_unrelated_stash()

        (self.main / "staged.txt").write_text("alpha\nbeta\ngamma\n", encoding="utf-8")
        run_git(["add", "staged.txt"], cwd=self.main)
        run_git(["commit", "-q", "-m", "add staged.txt"], cwd=self.main)
        run_git(["push", "-q", "origin", "master"], cwd=self.main)

        # A *staged* edit to a tracked file origin never touches...
        (self.main / "staged.txt").write_text(
            "alpha\nbeta-staged\ngamma\n", encoding="utf-8"
        )
        run_git(["add", "staged.txt"], cwd=self.main)
        # ...plus a completely untracked new file.
        (self.main / "new-tracked.txt").write_text("untracked-new-file\n", encoding="utf-8")

        self._advance_origin_line1("line1-updated")

        drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        self.assertEqual(
            (self.main / "shared.txt").read_text(encoding="utf-8"),
            "line1-updated\nline2\nline3\n",
        )
        self.assertEqual(
            (self.main / "staged.txt").read_text(encoding="utf-8"),
            "alpha\nbeta-staged\ngamma\n",
        )
        staged_diff = run_git(
            ["diff", "--cached", "--", "staged.txt"], cwd=self.main
        ).stdout
        self.assertIn("beta-staged", staged_diff)
        self.assertEqual(
            (self.main / "new-tracked.txt").read_text(encoding="utf-8"),
            "untracked-new-file\n",
        )
        self.assertEqual(stash_shas(self.main), [user_stash_sha])


class CleanTreeNoEntryTest(_FastForwardStashFixture):
    def test_diverged_clean_tree_reraises_original_error_without_stashing(self):
        # Origin gets its own new commit, and so does local -- neither is an
        # ancestor of the other, so --ff-only can never succeed here.
        self._advance_origin_line1("line1-updated")
        (self.main / "shared.txt").write_text(
            "line1\nline2\nlocal-only\n", encoding="utf-8"
        )
        run_git(["commit", "-q", "-am", "local divergent commit"], cwd=self.main)
        original_head = run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip()

        with self.assertRaises(drain_prs.DrainError) as cm:
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
        self.assertIn("fast-forward", str(cm.exception).lower())

        self.assertEqual(
            run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip(), original_head
        )
        self.assertEqual(stash_shas(self.main), [])


class SnapshotCommandFailsTest(_FastForwardStashFixture):
    def test_failed_snapshot_aborts_with_detail_and_touches_no_stash(self):
        user_stash_sha = self._seed_unrelated_stash()

        # A genuine dirty tracked edit, so `git stash create` actually has
        # something to snapshot (and so hits the lock below) instead of
        # short-circuiting on a clean tree.
        lines = (self.main / "shared.txt").read_text(encoding="utf-8").splitlines()
        lines[2] = "line3-dirty"
        (self.main / "shared.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")

        self._advance_origin_line1("line1-updated")
        original_head = run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip()

        lock_path = self.main / ".git" / "index.lock"
        lock_path.write_text("", encoding="utf-8")
        self.addCleanup(lambda: lock_path.unlink(missing_ok=True))

        with self.assertRaises(drain_prs.DrainError) as cm:
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
        message = str(cm.exception)
        self.assertIn("preparing a temporary snapshot", message)
        self.assertIn("index.lock", message)

        lock_path.unlink()
        self.assertEqual(
            run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip(), original_head
        )
        self.assertEqual(stash_shas(self.main), [user_stash_sha])


class SecondFastForwardStillFailsTest(_FastForwardStashFixture):
    def test_stash_restored_when_second_ff_also_fails(self):
        # Origin and local both gain their own new commit -- diverged history
        # that --ff-only can never resolve, stash outcome notwithstanding.
        self._advance_origin_line1("line1-updated")
        (self.main / "shared.txt").write_text(
            "line1\nline2\nlocal-only\n", encoding="utf-8"
        )
        run_git(["commit", "-q", "-am", "local divergent commit"], cwd=self.main)
        (self.main / "other.txt").write_text("dirty\n", encoding="utf-8")

        with self.assertRaises(drain_prs.DrainError) as cm:
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
        message = str(cm.exception).lower()
        self.assertIn("fast-forward", message)
        self.assertNotIn("stash", message)

        self.assertEqual(stash_shas(self.main), [])
        self.assertEqual((self.main / "other.txt").read_text(encoding="utf-8"), "dirty\n")


class ConflictingRestoreTest(_FastForwardStashFixture):
    def test_conflicting_restore_recovers_snapshot_and_preserves_other_stashes(self):
        user_stash_sha = self._seed_unrelated_stash()

        (self.main / "shared.txt").write_text(
            "line1-local\nline2\nline3\n", encoding="utf-8"
        )
        self._advance_origin_line1("line1-remote")

        with self.assertRaises(drain_prs.DrainError) as cm:
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
        message = str(cm.exception)
        self.assertIn("restoring local changes failed", message)
        self.assertIn("recovered into `git stash list`", message)

        shas_after = stash_shas(self.main)
        self.assertEqual(len(shas_after), 2)
        self.assertIn(user_stash_sha, shas_after)


class ConcurrentStashDuringRestorationTest(_FastForwardStashFixture):
    """This run's own snapshot never touches refs/stash on the success path,
    so a user stash pushed at any point during restoration -- before the
    second fast-forward attempt, or interleaved with the restore itself --
    can't collide with it in either direction.
    """

    def test_restoration_ignores_concurrent_user_stash_entirely(self):
        lines = (self.main / "shared.txt").read_text(encoding="utf-8").splitlines()
        lines[2] = "line3-local"
        (self.main / "shared.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        self._advance_origin_line1("line1-updated")

        real_run = drain_prs.run
        state = {"merge_calls": 0, "concurrent_sha": None}

        def fake_run(args, **kwargs):
            if args[:3] == ["git", "merge", "--ff-only"]:
                state["merge_calls"] += 1
                if state["merge_calls"] == 2:
                    cwd = kwargs["cwd"]
                    (Path(cwd) / "concurrent.txt").write_text(
                        "concurrent\n", encoding="utf-8"
                    )
                    subprocess.run(
                        ["git", "add", "concurrent.txt"], cwd=str(cwd), check=True
                    )
                    subprocess.run(
                        ["git", "stash", "push", "-q", "-m", "user-concurrent"],
                        cwd=str(cwd),
                        check=True,
                    )
                    state["concurrent_sha"] = stash_shas(cwd)[0]
            return real_run(args, **kwargs)

        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        self.assertIsNotNone(state["concurrent_sha"])
        self.assertEqual(stash_shas(self.main), [state["concurrent_sha"]])
        self.assertEqual(
            (self.main / "shared.txt").read_text(encoding="utf-8"),
            "line1-updated\nline2\nline3-local\n",
        )


class UntrackedCollisionOnRestoreTest(_FastForwardStashFixture):
    """An untracked file that shares a path with a file upstream newly adds
    is exactly what makes --ff-only refuse in the first place ("untracked
    working tree files would be overwritten by merge"). Restoring it after
    a successful retry must never blindly rename over whatever the
    fast-forward just checked out there.
    """

    def test_restore_does_not_overwrite_new_file_and_keeps_others_recoverable(self):
        (self.main / "collide.txt").write_text("local-untracked\n", encoding="utf-8")
        (self.main / "safe.txt").write_text("local-safe\n", encoding="utf-8")

        clone_dir = Path(tempfile.mkdtemp(dir=str(self.root)))
        run_git(["clone", "-q", str(self.bare), str(clone_dir)], cwd=self.root)
        run_git(["config", "user.email", "test@example.com"], cwd=clone_dir)
        run_git(["config", "user.name", "Test"], cwd=clone_dir)
        (clone_dir / "collide.txt").write_text("upstream-tracked\n", encoding="utf-8")
        run_git(["add", "collide.txt"], cwd=clone_dir)
        run_git(["commit", "-q", "-m", "add collide.txt"], cwd=clone_dir)
        run_git(["push", "-q", "origin", "master"], cwd=clone_dir)

        with self.assertRaises(drain_prs.DrainError) as cm:
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
        message = str(cm.exception)
        self.assertIn("restoring local changes failed", message)
        self.assertIn("a path now exists there", message)

        # The fast-forward's own file must win -- our stale untracked copy
        # must never silently clobber it.
        self.assertEqual(
            (self.main / "collide.txt").read_text(encoding="utf-8"), "upstream-tracked\n"
        )
        # The file with no collision restores normally...
        self.assertEqual((self.main / "safe.txt").read_text(encoding="utf-8"), "local-safe\n")

        # ...and the one that couldn't be restored is still recoverable --
        # the holding directory must survive, not be deleted alongside it.
        holding_dirs = list((self.main / ".git").glob("autostash-*"))
        self.assertEqual(len(holding_dirs), 1)
        self.assertEqual(
            (holding_dirs[0] / "collide.txt").read_text(encoding="utf-8"), "local-untracked\n"
        )
        self.assertFalse((holding_dirs[0] / "safe.txt").exists())


class UntrackedCollisionWithDanglingSymlinkTest(_FastForwardStashFixture):
    """A dangling symlink upstream just checked out is a real collision too,
    but `Path.exists()` follows the link and reports False for it -- only
    `os.path.lexists()` sees the symlink itself. Restoring must not replace
    it with the stale local file.
    """

    def test_restore_does_not_replace_dangling_symlink(self):
        (self.main / "link.txt").write_text("local-untracked\n", encoding="utf-8")

        clone_dir = Path(tempfile.mkdtemp(dir=str(self.root)))
        run_git(["clone", "-q", str(self.bare), str(clone_dir)], cwd=self.root)
        run_git(["config", "user.email", "test@example.com"], cwd=clone_dir)
        run_git(["config", "user.name", "Test"], cwd=clone_dir)
        (clone_dir / "link.txt").symlink_to("nonexistent-target")
        run_git(["add", "link.txt"], cwd=clone_dir)
        run_git(["commit", "-q", "-m", "add dangling symlink link.txt"], cwd=clone_dir)
        run_git(["push", "-q", "origin", "master"], cwd=clone_dir)

        with self.assertRaises(drain_prs.DrainError) as cm:
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
        message = str(cm.exception)
        self.assertIn("restoring local changes failed", message)
        self.assertIn("a path now exists there", message)

        # The fast-forward's own dangling symlink must survive untouched.
        restored_path = self.main / "link.txt"
        self.assertTrue(restored_path.is_symlink())
        self.assertEqual(os.readlink(restored_path), "nonexistent-target")

        holding_dirs = list((self.main / ".git").glob("autostash-*"))
        self.assertEqual(len(holding_dirs), 1)
        self.assertEqual(
            (holding_dirs[0] / "link.txt").read_text(encoding="utf-8"), "local-untracked\n"
        )


class UntrackedRestoreRejectsSymlinkedParentTest(_FastForwardStashFixture):
    """A parent directory component that has become a symlink -- not just
    the final path -- must never be walked through when restoring a
    relocated untracked file: mkdir(parents=True) plus rename() would
    otherwise happily follow it and write the file outside the worktree.

    This drives _restore_untracked_files() directly with a hand-built
    holding directory rather than through a real fast-forward, since the
    hazard is a pure filesystem property independent of how the symlinked
    parent came to exist.
    """

    def test_restore_refuses_to_write_through_a_symlinked_parent(self):
        escape_target = Path(tempfile.mkdtemp(dir=str(self.root)))

        holding = Path(
            tempfile.mkdtemp(prefix="autostash-", dir=str(self.main / ".git"))
        )
        (holding / "dir").mkdir()
        (holding / "dir" / "file.txt").write_text("local-untracked\n", encoding="utf-8")

        # What a fast-forward replacing a plain `dir` with a symlink would
        # leave behind.
        (self.main / "dir").symlink_to(escape_target, target_is_directory=True)

        failures = drain_prs._restore_untracked_files(self.ctx, holding, ["dir/file.txt"])

        self.assertTrue(failures)
        self.assertFalse((escape_target / "file.txt").exists())
        self.assertTrue((self.main / "dir").is_symlink())
        self.assertEqual(
            (holding / "dir" / "file.txt").read_text(encoding="utf-8"), "local-untracked\n"
        )


if __name__ == "__main__":
    unittest.main()
