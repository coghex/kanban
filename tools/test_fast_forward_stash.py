"""Integration tests for drain_prs.fast_forward_default_branch()'s stash
safety: a failed snapshot attempt must abort cleanly, restoring local
changes afterward must never read or write the shared `refs/stash` reflog
that a concurrent `git stash` in another terminal also uses, and the
unmerged index a conflicted restore leaves behind must stop the next pass
rather than wedge it -- against a real temporary Git repository.

The startup anchor sweep is here too, because it is the other half of the
same lifecycle: an anchor a killed or conflicted pass left under
`refs/drain-prs/autostash/` is reaped by a later run once its snapshot is
provably in `git stash list`, and reported for recovery while it is not.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# `python3 -m unittest tools.test_fast_forward_stash` imports this module by
# package path, which puts the repository root on sys.path rather than tools/
# -- unlike `-m unittest discover -s tools`. Both invocations have to reach
# the sibling module, so name the directory outright.
sys.path.insert(0, str(Path(__file__).resolve().parent))

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


def index_entries(cwd):
    return run_git(["ls-files", "--stage"], cwd=cwd).stdout


def unmerged_entries(cwd):
    return run_git(["ls-files", "--unmerged"], cwd=cwd).stdout


def anchor_refs(cwd):
    return run_git(["for-each-ref", "refs/drain-prs/autostash"], cwd=cwd).stdout


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

    def _advance_origin_new_file(self, name, contents):
        clone_dir = Path(tempfile.mkdtemp(dir=str(self.root)))
        run_git(["clone", "-q", str(self.bare), str(clone_dir)], cwd=self.root)
        run_git(["config", "user.email", "test@example.com"], cwd=clone_dir)
        run_git(["config", "user.name", "Test"], cwd=clone_dir)
        (clone_dir / name).write_text(contents, encoding="utf-8")
        run_git(["add", name], cwd=clone_dir)
        run_git(["commit", "-q", "-m", f"add {name}"], cwd=clone_dir)
        run_git(["push", "-q", "origin", "master"], cwd=clone_dir)

    def _seed_unrelated_stash(self):
        (self.main / "other.txt").write_text("other\n", encoding="utf-8")
        run_git(["add", "other.txt"], cwd=self.main)
        run_git(["commit", "-q", "-m", "add other.txt"], cwd=self.main)
        run_git(["push", "-q", "origin", "master"], cwd=self.main)
        (self.main / "other.txt").write_text("other-user-edit\n", encoding="utf-8")
        run_git(["stash", "push", "-q", "-m", "user-manual-stash"], cwd=self.main)
        return stash_shas(self.main)[0]

    def _snapshot_commit(self, line3):
        """A real `git stash create` commit, with the working tree put back.

        Exactly what the drainer anchors before its `reset --hard`, built
        here without a fast-forward so a test can stage the leftovers a
        killed pass would have left behind.
        """
        lines = (self.main / "shared.txt").read_text(encoding="utf-8").splitlines()
        lines[2] = line3
        (self.main / "shared.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        sha = run_git(
            ["stash", "create", f"drain-prs-autostash-{line3}"], cwd=self.main
        ).stdout.strip()
        run_git(["checkout", "--", "shared.txt"], cwd=self.main)
        self.assertTrue(sha)
        return sha

    def _anchor_ref_names(self):
        proc = run_git(
            ["for-each-ref", "--format=%(refname)", "refs/drain-prs/autostash"],
            cwd=self.main,
        )
        return sorted(line for line in proc.stdout.splitlines() if line)

    def _commit_date(self, sha):
        return run_git(
            ["log", "-1", "--format=%cd", "--date=iso-strict", sha], cwd=self.main
        ).stdout.strip()


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


class SnapshotAnchoredBeforeResetTest(_FastForwardStashFixture):
    """The snapshot must be anchored under a private ref *before* the
    destructive `git reset --hard` -- otherwise a crash in that exact
    window would leave the user's changes reachable from no ref at all --
    and released once restoration actually succeeds.
    """

    def test_anchor_ref_exists_before_reset_and_is_released_after_restore(self):
        lines = (self.main / "shared.txt").read_text(encoding="utf-8").splitlines()
        lines[2] = "line3-local"
        (self.main / "shared.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        self._advance_origin_line1("line1-updated")

        real_run = drain_prs.run
        state = {"anchor_seen_before_reset": False}

        def fake_run(args, **kwargs):
            if args[:3] == ["git", "reset", "--hard"]:
                refs = run_git(
                    ["for-each-ref", "refs/drain-prs/autostash"], cwd=self.main
                ).stdout
                state["anchor_seen_before_reset"] = bool(refs.strip())
            return real_run(args, **kwargs)

        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        self.assertTrue(state["anchor_seen_before_reset"])
        refs_after = run_git(["for-each-ref", "refs/drain-prs/autostash"], cwd=self.main).stdout
        self.assertEqual(refs_after.strip(), "")


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

        # The private anchor ref created before the reset must survive a
        # failed restore too -- it's the recovery path if `git stash list`
        # itself is ever unavailable.
        anchor_refs = run_git(["for-each-ref", "refs/drain-prs/autostash"], cwd=self.main).stdout
        self.assertTrue(anchor_refs.strip())


class UnmergedIndexRefusalTest(_FastForwardStashFixture):
    """A conflicted restore leaves unmerged entries in the index, and
    `git stash create` cannot snapshot one. Undetected, that wedges every
    later pass at the snapshot step -- blaming local changes for a state
    only a human can clear -- so the fast-forward refuses first instead.
    """

    def _wedge_on_conflicted_restore(self):
        (self.main / "shared.txt").write_text(
            "line1-local\nline2\nline3\n", encoding="utf-8"
        )
        self._advance_origin_line1("line1-remote")

        with self.assertRaises(drain_prs.DrainError) as cm:
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
        self.assertIn("restoring local changes failed", str(cm.exception))
        self.assertTrue(unmerged_entries(self.main))

    def test_second_pass_refuses_naming_the_unmerged_index_and_changes_nothing(self):
        user_stash_sha = self._seed_unrelated_stash()
        self._wedge_on_conflicted_restore()

        head_before = run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip()
        index_before = index_entries(self.main)
        tree_before = (self.main / "shared.txt").read_text(encoding="utf-8")
        stashes_before = stash_shas(self.main)
        anchors_before = anchor_refs(self.main)
        self.assertIn(user_stash_sha, stashes_before)
        self.assertTrue(anchors_before.strip())

        real_run = drain_prs.run
        calls = []

        def fake_run(args, **kwargs):
            calls.append(list(args))
            return real_run(args, **kwargs)

        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            with self.assertRaises(drain_prs.DrainError) as cm:
                drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        message = str(cm.exception)
        self.assertIn("unmerged", message)
        self.assertIn("shared.txt", message)
        # The old diagnosis named the wrong cause; it must not be what an
        # operator reads here.
        self.assertNotIn("Local changes blocked fast-forward", message)

        # Refused before every step that could move a ref or touch the tree,
        # the fetch and the first --ff-only included.
        self.assertEqual([c for c in calls if c[:2] == ["git", "fetch"]], [])
        self.assertEqual([c for c in calls if c[:3] == ["git", "merge", "--ff-only"]], [])
        self.assertEqual([c for c in calls if c[:3] == ["git", "stash", "create"]], [])

        self.assertEqual(run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip(), head_before)
        self.assertEqual(index_entries(self.main), index_before)
        self.assertEqual(
            (self.main / "shared.txt").read_text(encoding="utf-8"), tree_before
        )
        # The preserved snapshot stays reachable both ways it was left.
        self.assertEqual(stash_shas(self.main), stashes_before)
        self.assertEqual(anchor_refs(self.main), anchors_before)

    def test_resolved_and_staged_paths_let_the_next_pass_fast_forward(self):
        self._wedge_on_conflicted_restore()

        # Exactly the recovery the observed incident used: resolve the
        # conflicted path, `git add` it, and let the next ordinary pass run.
        (self.main / "shared.txt").write_text(
            "line1-resolved\nline2\nline3\n", encoding="utf-8"
        )
        run_git(["add", "shared.txt"], cwd=self.main)
        self.assertEqual(unmerged_entries(self.main), "")

        self._advance_origin_new_file("advanced.txt", "advanced\n")

        drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        self.assertEqual(
            run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip(),
            run_git(["rev-parse", "origin/master"], cwd=self.main).stdout.strip(),
        )
        self.assertEqual(
            (self.main / "advanced.txt").read_text(encoding="utf-8"), "advanced\n"
        )
        # The human's resolution survives the pass that discharged the debt.
        self.assertEqual(
            (self.main / "shared.txt").read_text(encoding="utf-8"),
            "line1-resolved\nline2\nline3\n",
        )


class DirtyButMergedIndexStillAutostashesTest(_FastForwardStashFixture):
    """The refusal reads unmerged *stages*, not dirtiness. Ordinary staged
    and unstaged work -- the common path, and the whole point of the
    autostash -- must still be set aside, fast-forwarded through, and
    restored exactly as before.
    """

    def test_dirty_checkout_with_no_unmerged_entries_is_unaffected(self):
        user_stash_sha = self._seed_unrelated_stash()

        (self.main / "staged.txt").write_text("alpha\n", encoding="utf-8")
        run_git(["add", "staged.txt"], cwd=self.main)
        run_git(["commit", "-q", "-m", "add staged.txt"], cwd=self.main)
        run_git(["push", "-q", "origin", "master"], cwd=self.main)

        (self.main / "staged.txt").write_text("alpha-staged\n", encoding="utf-8")
        run_git(["add", "staged.txt"], cwd=self.main)
        lines = (self.main / "shared.txt").read_text(encoding="utf-8").splitlines()
        lines[2] = "line3-local"
        (self.main / "shared.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        (self.main / "new-untracked.txt").write_text("untracked\n", encoding="utf-8")

        self._advance_origin_line1("line1-updated")
        # Dirty in every way that matters, yet nothing is unmerged.
        self.assertEqual(unmerged_entries(self.main), "")

        drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        self.assertEqual(
            (self.main / "shared.txt").read_text(encoding="utf-8"),
            "line1-updated\nline2\nline3-local\n",
        )
        self.assertEqual(
            (self.main / "staged.txt").read_text(encoding="utf-8"), "alpha-staged\n"
        )
        self.assertIn(
            "alpha-staged",
            run_git(["diff", "--cached", "--", "staged.txt"], cwd=self.main).stdout,
        )
        self.assertEqual(
            (self.main / "new-untracked.txt").read_text(encoding="utf-8"), "untracked\n"
        )
        self.assertEqual(stash_shas(self.main), [user_stash_sha])


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


class LinkedWorktreeGitDirTest(_FastForwardStashFixture):
    """`<worktree>/.git` is a gitdir *file* (a pointer to
    `.git/worktrees/<name>`), not a directory, in a linked worktree --
    creating the holding directory under it outright must not assume
    otherwise.
    """

    def test_untracked_relocation_works_in_a_linked_worktree(self):
        # Free up `master` so the worktree can check it out.
        run_git(["checkout", "-q", "--detach", "HEAD"], cwd=self.main)
        worktree_dir = self.root / "linked-worktree"
        run_git(["worktree", "add", "-q", str(worktree_dir), "master"], cwd=self.main)
        self.assertFalse((worktree_dir / ".git").is_dir())
        wt_ctx = drain_prs.RepoContext(worktree_dir, "example/project", "project", "master")

        (worktree_dir / "shared.txt").write_text(
            "line1\nline2\nline3-wt\n", encoding="utf-8"
        )
        (worktree_dir / "untracked.txt").write_text("wt-untracked\n", encoding="utf-8")

        self._advance_origin_line1("line1-wt-updated")

        drain_prs.fast_forward_default_branch(wt_ctx, dry_run=False)

        self.assertEqual(
            (worktree_dir / "shared.txt").read_text(encoding="utf-8"),
            "line1-wt-updated\nline2\nline3-wt\n",
        )
        self.assertEqual(
            (worktree_dir / "untracked.txt").read_text(encoding="utf-8"), "wt-untracked\n"
        )


class _AnchorSweepFixture(_FastForwardStashFixture):
    """The sweep driven directly, with `log()` captured.

    Everything the sweep says is a log line -- never stdout, never an
    exception -- so what it reports is asserted from there.
    """

    def setUp(self):
        super().setUp()
        self.logged = []
        patcher = mock.patch.object(drain_prs, "log", self.logged.append)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _redundant_anchor(self, line3):
        """An anchor whose snapshot is also a `git stash list` entry.

        The shape a conflicted restore leaves behind: `_preserve_unreachable_snapshot`
        stores the snapshot commit itself, so the entry's commit *is* the
        anchor's object ID.
        """
        sha = self._snapshot_commit(line3)
        ref = drain_prs._anchor_snapshot(self.ctx, sha)
        run_git(
            ["stash", "store", "-m", f"drain-prs-autostash-recovery {sha}", sha],
            cwd=self.main,
        )
        return ref, sha

    def _logged_containing(self, needle):
        return [line for line in self.logged if needle in line]


class AnchorReapedWhenSnapshotIsInStashTest(_AnchorSweepFixture):
    def test_matching_entry_below_the_tip_is_reaped_without_touching_the_stash(self):
        ref, sha = self._redundant_anchor("line3-recovered")
        # A newer, unrelated user stash pushed on top: the entry proving this
        # anchor redundant is stash@{1}, which only reading the whole list
        # finds -- ancestry from the refs/stash tip would not.
        user_stash_sha = self._seed_unrelated_stash()
        stashes_before = stash_shas(self.main)
        self.assertEqual(stashes_before, [user_stash_sha, sha])

        drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=False)

        self.assertEqual(self._anchor_ref_names(), [])
        # Neither entry reaped, reordered, nor rewritten -- the stash is the
        # user's, and deleting an anchor is all this may ever do.
        self.assertEqual(stash_shas(self.main), stashes_before)
        reported = self._logged_containing("Deleted redundant autostash anchor")
        self.assertEqual(len(reported), 1)
        self.assertIn(ref, reported[0])


class AnchorKeptWhenSnapshotIsNotInStashTest(_AnchorSweepFixture):
    def test_unmatched_anchor_survives_and_is_reported_with_its_restore_command(self):
        user_stash_sha = self._seed_unrelated_stash()
        sha = self._snapshot_commit("line3-orphaned")
        ref = drain_prs._anchor_snapshot(self.ctx, sha)

        drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=False)

        self.assertEqual(self._anchor_ref_names(), [ref])
        self.assertEqual(stash_shas(self.main), [user_stash_sha])
        reported = self._logged_containing("Keeping autostash anchor")
        self.assertEqual(len(reported), 1)
        # Recovery has to be a supported operation, not archaeology: the ref,
        # its commit, that commit's date, and the command that restores it.
        self.assertIn(ref, reported[0])
        self.assertIn(sha, reported[0])
        self.assertIn(self._commit_date(sha), reported[0])
        self.assertIn(f"git stash apply --index {sha}", reported[0])
        # A user stash entry exists throughout: an anchor is redundant only
        # when *its own* commit is one of them.
        self.assertNotIn(sha, [user_stash_sha])


class AnchorDeletionRevalidatedAcrossTheStashTest(_AnchorSweepFixture):
    """The stash is the user's: `git stash drop` can land in the window
    between the membership read and the deletion, and then the anchor would
    be the last ref to a commit nothing else holds. What binds is the read
    *after* the anchor is gone; anything short of a confirmation puts it back.
    """

    def test_a_stash_dropped_under_the_deletion_puts_the_anchor_back(self):
        ref, sha = self._redundant_anchor("line3-recovered")
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            proc = real_run(args, **kwargs)
            if args[:3] == ["git", "update-ref", "-d"] and args[3] == ref:
                # Exactly the losing window: the anchor is gone, and the
                # user's `git stash drop` has already taken the other copy.
                run_git(["stash", "drop", "-q"], cwd=self.main)
            return proc

        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=False)

        self.assertEqual(self._anchor_ref_names(), [ref])
        self.assertEqual(run_git(["rev-parse", ref], cwd=self.main).stdout.strip(), sha)
        self.assertEqual(stash_shas(self.main), [])
        restored = self._logged_containing("Restored autostash anchor")
        self.assertEqual(len(restored), 1)
        self.assertIn(ref, restored[0])
        self.assertEqual(self._logged_containing("Deleted redundant"), [])

    def test_an_unreadable_stash_after_the_deletion_puts_the_anchor_back(self):
        ref, sha = self._redundant_anchor("line3-recovered")
        stashes_before = stash_shas(self.main)
        real_run = drain_prs.run
        reads = []

        def fake_run(args, **kwargs):
            if args[:3] == ["git", "stash", "list"]:
                reads.append(args)
                # The classifying read succeeds; the one that would confirm
                # the deletion does not.
                if len(reads) > 1:
                    raise drain_prs.DrainError("stash list is unavailable")
            return real_run(args, **kwargs)

        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=False)

        # Unprovable is not the same as proven redundant.
        self.assertEqual(self._anchor_ref_names(), [ref])
        self.assertEqual(run_git(["rev-parse", ref], cwd=self.main).stdout.strip(), sha)
        self.assertEqual(stash_shas(self.main), stashes_before)
        restored = self._logged_containing("Restored autostash anchor")
        self.assertEqual(len(restored), 1)
        self.assertIn("could not be read", restored[0])

    def test_a_snapshot_still_in_the_stash_confirms_the_deletion(self):
        ref, sha = self._redundant_anchor("line3-recovered")

        drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=False)

        self.assertEqual(self._anchor_ref_names(), [])
        self.assertEqual(stash_shas(self.main), [sha])
        self.assertEqual(self._logged_containing("Restored autostash anchor"), [])
        deleted = self._logged_containing("Deleted redundant autostash anchor")
        self.assertEqual(len(deleted), 1)
        self.assertIn(ref, deleted[0])


class AnchorSweepDryRunTest(_AnchorSweepFixture):
    def test_dry_run_reports_a_redundant_anchor_and_deletes_nothing(self):
        ref, sha = self._redundant_anchor("line3-recovered")
        stashes_before = stash_shas(self.main)

        drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=True)

        self.assertEqual(self._anchor_ref_names(), [ref])
        self.assertEqual(stash_shas(self.main), stashes_before)
        reported = self._logged_containing("Would delete redundant autostash anchor")
        self.assertEqual(len(reported), 1)
        self.assertIn(ref, reported[0])


class AnchorSweepFailuresAreNonFatalTest(_AnchorSweepFixture):
    """A ref sweep must never be what stops a pull request from merging, so
    every way it can fail is logged and stepped over.
    """

    def _sweep_with(self, fake_run):
        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=False)

    def test_enumeration_failure_leaves_every_ref_unchanged(self):
        ref, _ = self._redundant_anchor("line3-recovered")
        stashes_before = stash_shas(self.main)
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            if args[:2] == ["git", "for-each-ref"]:
                raise drain_prs.DrainError("for-each-ref is unavailable")
            return real_run(args, **kwargs)

        self._sweep_with(fake_run)

        self.assertEqual(self._anchor_ref_names(), [ref])
        self.assertEqual(stash_shas(self.main), stashes_before)
        self.assertEqual(len(self._logged_containing("Could not enumerate")), 1)

    def test_stash_read_failure_keeps_and_reports_every_anchor(self):
        ref, _ = self._redundant_anchor("line3-recovered")
        stashes_before = stash_shas(self.main)
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            if args[:3] == ["git", "stash", "list"]:
                raise drain_prs.DrainError("stash list is unavailable")
            return real_run(args, **kwargs)

        self._sweep_with(fake_run)

        # Nothing is provably redundant without the stash list, so this
        # anchor -- redundant in fact -- is still kept rather than guessed at.
        self.assertEqual(self._anchor_ref_names(), [ref])
        self.assertEqual(stash_shas(self.main), stashes_before)
        self.assertEqual(len(self._logged_containing("Could not read")), 1)
        self.assertEqual(len(self._logged_containing("Keeping autostash anchor")), 1)

    def test_deletion_failure_leaves_its_own_anchor_and_reaps_the_others(self):
        doomed_ref, _ = self._redundant_anchor("line3-first")
        other_ref, _ = self._redundant_anchor("line3-second")
        stashes_before = stash_shas(self.main)
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            if args[:3] == ["git", "update-ref", "-d"] and args[3] == doomed_ref:
                return subprocess.CompletedProcess(
                    args, 1, "", "fatal: cannot lock ref\n"
                )
            return real_run(args, **kwargs)

        self._sweep_with(fake_run)

        self.assertEqual(self._anchor_ref_names(), [doomed_ref])
        self.assertEqual(stash_shas(self.main), stashes_before)
        failed = self._logged_containing("Could not delete redundant autostash anchor")
        self.assertEqual(len(failed), 1)
        self.assertIn(doomed_ref, failed[0])
        self.assertIn("cannot lock ref", failed[0])
        deleted = self._logged_containing("Deleted redundant autostash anchor")
        self.assertEqual(len(deleted), 1)
        self.assertIn(other_ref, deleted[0])


class FastForwardNeverSweepsAnchorsTest(_FastForwardStashFixture):
    """The sweep is a startup step and nothing else. Running one from inside
    a fast-forward would put a ref reaper inside the very window where the
    anchor is the only copy of the user's changes.
    """

    def _fast_forward_recording_git(self):
        calls = []
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            calls.append(list(args))
            return real_run(args, **kwargs)

        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            with mock.patch.object(
                drain_prs, "sweep_snapshot_anchors", side_effect=AssertionError
            ):
                try:
                    drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
                    error = None
                except drain_prs.DrainError as exc:
                    error = exc
        self.assertEqual([c for c in calls if c[:2] == ["git", "for-each-ref"]], [])
        return error

    def test_clean_restore_releases_only_its_own_anchor(self):
        stale_sha = self._snapshot_commit("line3-stale-anchor")
        stale_ref = drain_prs._anchor_snapshot(self.ctx, stale_sha)

        lines = (self.main / "shared.txt").read_text(encoding="utf-8").splitlines()
        lines[2] = "line3-local"
        (self.main / "shared.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
        self._advance_origin_line1("line1-updated")

        self.assertIsNone(self._fast_forward_recording_git())

        # Its own anchor released within the pass, exactly as before; the
        # older one left for the next startup sweep to judge.
        self.assertEqual(self._anchor_ref_names(), [stale_ref])
        self.assertEqual(
            (self.main / "shared.txt").read_text(encoding="utf-8"),
            "line1-updated\nline2\nline3-local\n",
        )

    def test_conflicted_restore_still_keeps_both_copies(self):
        (self.main / "shared.txt").write_text(
            "line1-local\nline2\nline3\n", encoding="utf-8"
        )
        self._advance_origin_line1("line1-remote")

        error = self._fast_forward_recording_git()

        self.assertIsNotNone(error)
        self.assertIn("restoring local changes failed", str(error))
        anchors = self._anchor_ref_names()
        self.assertEqual(len(anchors), 1)
        # Belt and braces, both still fastened: the pass that hits this keeps
        # the anchor *and* the stash entry. Only a later run reaps.
        self.assertIn(anchors[0].rsplit("/", 1)[1], stash_shas(self.main))


class StartupSweepSeamTest(_FastForwardStashFixture):
    """The sweep runs exactly once per process, on the seam both modes pass
    through, before either can merge or fast-forward anything.
    """

    def setUp(self):
        super().setUp()
        for name in ("LOG_DIR", "LOG_TO_STDERR", "APPROVE_LABEL", "CHANGES_LABEL"):
            self.addCleanup(setattr, drain_prs, name, getattr(drain_prs, name))
        self.log_dir = self.root / "logs"
        # An absent path, so main() loads pure defaults rather than the
        # developer's own ~/.config/kanban/config.toml.
        self.absent_config = self.root / "no-such-config.toml"

    def _run_main(self, *mode_argv):
        events = []
        real_sweep = drain_prs.sweep_snapshot_anchors

        def fake_sweep(ctx, *, dry_run):
            events.append("sweep")
            return real_sweep(ctx, dry_run=dry_run)

        def fake_loop(ctx, **kwargs):
            events.append("loop")

        def fake_drain_one_pr(ctx, number, **kwargs):
            events.append("drain_one_pr")
            return drain_prs.single_pr_result(number, "not_approved", "fixture")

        argv = [
            "drain_prs.py",
            "--path",
            str(self.main),
            "--log-dir",
            str(self.log_dir),
            "--config",
            str(self.absent_config),
            *mode_argv,
        ]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(sys, "argv", argv))
            stack.enter_context(
                mock.patch.object(
                    drain_prs, "sweep_snapshot_anchors", side_effect=fake_sweep
                )
            )
            stack.enter_context(mock.patch.object(drain_prs, "loop", side_effect=fake_loop))
            stack.enter_context(
                mock.patch.object(drain_prs, "drain_one_pr", side_effect=fake_drain_one_pr)
            )
            stack.enter_context(
                mock.patch.object(drain_prs, "get_repo_context", return_value=self.ctx)
            )
            stack.enter_context(contextlib.redirect_stdout(out))
            stack.enter_context(contextlib.redirect_stderr(err))
            with contextlib.suppress(SystemExit):
                drain_prs.main()
        return events, out.getvalue()

    def test_polling_run_sweeps_once_before_the_queue_loop(self):
        sha = self._snapshot_commit("line3-orphaned")
        ref = drain_prs._anchor_snapshot(self.ctx, sha)

        events, _stdout = self._run_main("--once")

        self.assertEqual(events, ["sweep", "loop"])
        # A real sweep ran, not just the seam: the unmatched anchor survives.
        self.assertEqual(self._anchor_ref_names(), [ref])

    def test_single_pr_run_sweeps_once_and_still_emits_one_json_document(self):
        sha = self._snapshot_commit("line3-orphaned")
        drain_prs._anchor_snapshot(self.ctx, sha)

        events, stdout = self._run_main("--pr", "42")

        self.assertEqual(events, ["sweep", "drain_one_pr"])
        # Everything the sweep reported went to the log; stdout carries the
        # one result document and nothing else.
        documents = [line for line in stdout.splitlines() if line.strip()]
        self.assertEqual(len(documents), 1)
        self.assertEqual(json.loads(documents[0])["pull_request"], 42)

    def test_dry_run_sweeps_without_deleting_a_redundant_anchor(self):
        sha = self._snapshot_commit("line3-recovered")
        ref = drain_prs._anchor_snapshot(self.ctx, sha)
        run_git(
            ["stash", "store", "-m", f"drain-prs-autostash-recovery {sha}", sha],
            cwd=self.main,
        )

        events, _stdout = self._run_main("--once", "--dry-run")

        self.assertEqual(events, ["sweep", "loop"])
        self.assertEqual(self._anchor_ref_names(), [ref])
        self.assertEqual(stash_shas(self.main), [sha])


if __name__ == "__main__":
    unittest.main()
