"""Integration tests for drain_prs.fast_forward_default_branch()'s stash
safety: a failed stash must abort without popping, and restoration must
target only the stash entry this run created -- never a pre-existing or
concurrently created one -- against a real temporary Git repository.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

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


class StashCommandFailsTest(_FastForwardStashFixture):
    def test_failed_stash_command_aborts_with_detail_and_no_pop(self):
        user_stash_sha = self._seed_unrelated_stash()
        self._advance_origin_line1("line1-updated")
        original_head = run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip()

        lock_path = self.main / ".git" / "index.lock"
        lock_path.write_text("", encoding="utf-8")
        self.addCleanup(lambda: lock_path.unlink(missing_ok=True))

        with self.assertRaises(drain_prs.DrainError) as cm:
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
        message = str(cm.exception)
        self.assertIn("stashing them failed", message)
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


class ConflictingPopTest(_FastForwardStashFixture):
    def test_conflicting_restore_names_entry_and_preserves_other_stashes(self):
        user_stash_sha = self._seed_unrelated_stash()

        (self.main / "shared.txt").write_text(
            "line1-local\nline2\nline3\n", encoding="utf-8"
        )
        self._advance_origin_line1("line1-remote")

        with self.assertRaises(drain_prs.DrainError) as cm:
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
        message = str(cm.exception)
        self.assertIn("restoring stashed local changes", message)
        self.assertIn("stash@{", message)

        shas_after = stash_shas(self.main)
        self.assertEqual(len(shas_after), 2)
        self.assertIn(user_stash_sha, shas_after)


class ConcurrentStashPushedBeforeRestorationTest(_FastForwardStashFixture):
    """A user stash lands after this run's own stash was created but before
    restoration begins -- e.g. between the second fast-forward attempt and
    the `finally` block that restores it.
    """

    def test_restoration_targets_drainer_entry_despite_concurrent_user_stash(self):
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


class ConcurrentStashPushedDuringDropTest(_FastForwardStashFixture):
    """The narrowest window: a user stash lands after this run has already
    resolved its own entry's reflog position but before the drop of that
    position executes -- git's stash storage offers no atomic
    resolve-and-remove-by-content primitive, so this can shift which entry
    a positional drop actually removes. Content restoration (`apply` by
    commit SHA) must still be correct regardless, and the drop must fail
    loudly -- never silently report success -- when this happens.
    """

    def test_content_restored_and_drop_failure_reported_when_position_shifts(self):
        lines = (self.main / "shared.txt").read_text(encoding="utf-8").splitlines()
        lines[2] = "line3-local"
        (self.main / "shared.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        self._advance_origin_line1("line1-updated")

        real_run = drain_prs.run
        state = {"concurrent_sha": None}

        def fake_run(args, **kwargs):
            if args[:3] == ["git", "stash", "drop"]:
                cwd = kwargs["cwd"]
                (Path(cwd) / "concurrent.txt").write_text(
                    "concurrent\n", encoding="utf-8"
                )
                subprocess.run(
                    ["git", "add", "concurrent.txt"], cwd=str(cwd), check=True
                )
                # Pathspec-limited so this concurrent push -- modeling another
                # process entirely -- can't also scoop up this run's own
                # already-applied-but-uncommitted restoration of shared.txt.
                subprocess.run(
                    [
                        "git",
                        "stash",
                        "push",
                        "-q",
                        "-m",
                        "user-concurrent",
                        "--",
                        "concurrent.txt",
                    ],
                    cwd=str(cwd),
                    check=True,
                )
                state["concurrent_sha"] = stash_shas(cwd)[0]
            return real_run(args, **kwargs)

        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            with self.assertRaises(drain_prs.DrainError) as cm:
                drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
        message = str(cm.exception)
        self.assertIn("automatically dropping the stash entry", message)
        self.assertIn("remove it manually", message)

        # The restore itself (apply by commit SHA) is unaffected by the race:
        # the working tree is correctly restored either way.
        self.assertEqual(
            (self.main / "shared.txt").read_text(encoding="utf-8"),
            "line1-updated\nline2\nline3-local\n",
        )
        # The drop, resolved by stale position, removed the concurrently
        # pushed entry instead of this run's own -- which is exactly the
        # failure this test proves gets surfaced, not swallowed.
        remaining = stash_shas(self.main)
        self.assertEqual(len(remaining), 1)
        self.assertNotIn(state["concurrent_sha"], remaining)


if __name__ == "__main__":
    unittest.main()
