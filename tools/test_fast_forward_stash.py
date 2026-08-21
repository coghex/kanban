"""Integration tests for drain_prs.fast_forward_default_branch()'s stash
safety: a failed snapshot attempt must abort cleanly, restoring local
changes afterward must never read or write the shared `refs/stash` reflog
that a concurrent `git stash` in another terminal also uses, and the
unmerged index a conflicted restore leaves behind must stop the next pass
rather than wedge it -- against a real temporary Git repository.

The two startup passes are here too, because they are the other half of the
same lifecycle. An anchor a killed or conflicted pass left under
`refs/drain-prs/autostash/` is reaped by a later run once its snapshot is
provably in `git stash list`, and reported for recovery while it is not. The
`drain-prs-autostash-recovery <sha>` entry that same conflicted pass stores is
then retired by a later run -- after the anchor sweep, never inside a
fast-forward -- but only while its exact commit stays in the history of some
ref that is neither `refs/stash` nor one of those anchors; anything else keeps
it, and every failure of either pass is logged and stepped over.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

# `python3 -m unittest tools.test_fast_forward_stash` imports this module by
# package path, which puts the repository root on sys.path rather than tools/
# -- unlike `-m unittest discover -s tools`. Both invocations have to reach
# the sibling module, so name the directory outright.
sys.path.insert(0, str(Path(__file__).resolve().parent))

import drain_prs
import drain_prs_service
import git_fixture


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


class _FastForwardStashFixture(git_fixture.GitTemplateMixin, unittest.TestCase):
    """Common repo layout: a bare `origin` and a `main` checkout one commit
    ahead of nothing, with a multi-line tracked file so tests can dirty one
    line locally while `origin` advances a different one.

    Built once by `git` for the whole family and copied per test; see
    `tools/git_fixture.py`.
    """

    @classmethod
    def build_git_template(cls, root, data):
        bare = root / "remote.git"
        main = root / "main"

        run_git(["init", "--bare", "-q", "-b", "master", str(bare)], cwd=root)
        run_git(["init", "-q", "-b", "master", str(main)], cwd=root)
        run_git(["config", "user.email", "test@example.com"], cwd=main)
        run_git(["config", "user.name", "Test"], cwd=main)

        (main / "shared.txt").write_text("line1\nline2\nline3\n", encoding="utf-8")
        run_git(["add", "shared.txt"], cwd=main)
        run_git(["commit", "-q", "-m", "initial"], cwd=main)
        run_git(["remote", "add", "origin", str(bare)], cwd=main)
        run_git(["push", "-q", "-u", "origin", "master"], cwd=main)

    def setUp(self):
        self.root = self.checkout_git_template()

        self.bare = self.root / "remote.git"
        self.main = self.root / "main"

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


class FastForwardStashTemplateIsolationTests(
    git_fixture.SharedTemplateIsolationTests, _FastForwardStashFixture
):
    """Issue #384: the shared template must be unreachable from a copy."""

    def _mutate_the_copy(self):
        (self.main / "shared.txt").write_text("mutated\n", encoding="utf-8")
        run_git(["commit", "-qam", "a test rewrote history"], cwd=self.main)
        run_git(["push", "-q", "origin", "master"], cwd=self.main)
        run_git(["branch", "-f", "sideways", "HEAD"], cwd=self.main)
        scratch = self.root / "scratch-worktree"
        run_git(["worktree", "add", "-q", "--detach", str(scratch)], cwd=self.main)
        run_git(["worktree", "remove", str(scratch)], cwd=self.main)


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


class _LateTrackedEditFixture(_FastForwardStashFixture):
    """Shared setup for the window between the initial tracked snapshot and
    the destructive reset.

    The write is keyed on `_snapshot_tracked_changes` *returning* rather than
    on any later command, because that is the ordering the contract names: the
    later content has to land after the initial snapshot is complete and before
    the final protection operation reads tracked state, so that operation is
    the one that observes it. Injecting it any later would be the
    post-boundary interval the contract puts out of scope, and injecting it
    before the snapshot would be an ordinary dirty checkout.
    """

    def _dirty_the_checkout(self):
        (self.main / "shared.txt").write_text(
            "line1\nline2\nline3-local\n", encoding="utf-8"
        )
        (self.main / "untracked.txt").write_text("local-untracked\n", encoding="utf-8")

    def _edit_after_initial_snapshot(self, contents):
        """Patch `_snapshot_tracked_changes` to write `contents` once it has
        taken the initial snapshot; returns the patcher and the list of
        snapshot commits it observed."""
        real_snapshot = drain_prs._snapshot_tracked_changes
        snapshots = []

        def snapshot_then_edit(ctx, message):
            sha = real_snapshot(ctx, message)
            snapshots.append(sha)
            if len(snapshots) == 1:
                (self.main / "shared.txt").write_text(contents, encoding="utf-8")
            return sha

        patcher = mock.patch.object(
            drain_prs, "_snapshot_tracked_changes", side_effect=snapshot_then_edit
        )
        return patcher, snapshots

    def _recording_run(self, calls, *, fail_later_snapshots_with=None):
        real_run = drain_prs.run
        creates = []

        def fake_run(args, **kwargs):
            calls.append(list(args))
            if args[:3] == ["git", "stash", "create"]:
                creates.append(list(args))
                if fail_later_snapshots_with is not None and len(creates) > 1:
                    # The boundary's own read of tracked state, failing the
                    # way any git command can fail.
                    raise drain_prs.DrainError(fail_later_snapshots_with)
            return real_run(args, **kwargs)

        return mock.patch.object(drain_prs, "run", side_effect=fake_run)


class LateTrackedEditBeforeResetTest(_LateTrackedEditFixture):
    """A tracked edit written after the initial snapshot completes exists in
    the working tree and nowhere else -- not in the snapshot the drainer is
    about to rely on -- so `git reset --hard HEAD` would be the only thing
    that ever saw it. The final pre-reset protection boundary reads tracked
    state one last time and refuses the reset over anything it does not
    recognise.
    """

    def test_content_written_after_the_snapshot_is_never_discarded(self):
        self._dirty_the_checkout()
        self._advance_origin_line1("line1-updated")
        head_before = run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip()

        later = "line1\nline2\nline3-written-after-the-snapshot\n"
        patcher, snapshots = self._edit_after_initial_snapshot(later)
        calls = []

        with self._recording_run(calls), patcher:
            with self.assertRaises(drain_prs.DrainError) as cm:
                drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        # The boundary took a second reading, and what it saw stopped the pass
        # before anything destructive ran.
        self.assertEqual(len(snapshots), 2)
        self.assertEqual([c for c in calls if c[:3] == ["git", "reset", "--hard"]], [])
        self.assertEqual(len([c for c in calls if c[:3] == ["git", "merge", "--ff-only"]]), 1)

        message = str(cm.exception)
        self.assertIn("no longer the ones that were snapshotted", message)

        # The exact later content is what is still in the working tree -- not
        # the "line3-local" the snapshot holds, which is what restoring the
        # snapshot over a completed reset would have left here.
        self.assertEqual((self.main / "shared.txt").read_text(encoding="utf-8"), later)
        self.assertEqual(
            (self.main / "untracked.txt").read_text(encoding="utf-8"), "local-untracked\n"
        )
        self.assertEqual(list((self.main / ".git").glob("autostash-*")), [])

        # The fast-forward did not happen and is still owed.
        self.assertEqual(
            run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip(), head_before
        )
        self.assertNotEqual(
            run_git(["rev-parse", "origin/master"], cwd=self.main).stdout.strip(),
            head_before,
        )

        # The snapshot it had already taken costs nothing: named on the way
        # out, in `git stash list`, and its anchor therefore reapable by a
        # later startup sweep rather than stranded there forever.
        self.assertIn("recovered into `git stash list`", message)
        self.assertEqual(stash_shas(self.main), [snapshots[0]])
        self.assertEqual(
            self._anchor_ref_names(), [f"refs/drain-prs/autostash/{snapshots[0]}"]
        )


class ProtectionBoundaryFailureTest(_LateTrackedEditFixture):
    """A boundary that cannot be read answers the same as one that reads a
    changed state: no reset, no retry, nothing touched. An unverifiable
    tracked state is never a licence to discard it.
    """

    INJECTED = "injected: tracked state could not be read at the boundary"

    def test_a_failing_boundary_after_a_late_edit_leaves_everything_alone(self):
        # A staged edit as well, so "the index is unchanged" has something to
        # be true of.
        (self.main / "staged.txt").write_text("alpha\n", encoding="utf-8")
        run_git(["add", "staged.txt"], cwd=self.main)
        run_git(["commit", "-q", "-m", "add staged.txt"], cwd=self.main)
        run_git(["push", "-q", "origin", "master"], cwd=self.main)
        (self.main / "staged.txt").write_text("alpha-staged\n", encoding="utf-8")
        run_git(["add", "staged.txt"], cwd=self.main)

        self._dirty_the_checkout()
        self._advance_origin_line1("line1-updated")

        head_before = run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip()
        index_before = index_entries(self.main)

        later = "line1\nline2\nline3-written-after-the-snapshot\n"
        patcher, snapshots = self._edit_after_initial_snapshot(later)
        calls = []

        with self._recording_run(calls, fail_later_snapshots_with=self.INJECTED), patcher:
            with self.assertRaises(drain_prs.DrainError) as cm:
                drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        message = str(cm.exception)
        self.assertIn(self.INJECTED, message)

        # Neither destructive step ran, and the fast-forward was not retried.
        self.assertEqual([c for c in calls if c[:3] == ["git", "reset", "--hard"]], [])
        self.assertEqual(len([c for c in calls if c[:3] == ["git", "merge", "--ff-only"]]), 1)

        # HEAD, the index, and tracked working-tree content are exactly the
        # state visible at the failed boundary -- the late edit included.
        self.assertEqual(
            run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip(), head_before
        )
        self.assertEqual(index_entries(self.main), index_before)
        self.assertEqual((self.main / "shared.txt").read_text(encoding="utf-8"), later)
        self.assertEqual(
            (self.main / "staged.txt").read_text(encoding="utf-8"), "alpha-staged\n"
        )

        # Relocated untracked files come back under the existing contract, and
        # the holding directory goes with them.
        self.assertEqual(
            (self.main / "untracked.txt").read_text(encoding="utf-8"), "local-untracked\n"
        )
        self.assertEqual(list((self.main / ".git").glob("autostash-*")), [])

        # The fast-forward is still owed, and the snapshot already taken is
        # named rather than dropped.
        self.assertNotEqual(
            run_git(["rev-parse", "origin/master"], cwd=self.main).stdout.strip(),
            head_before,
        )
        self.assertIn("recovered into `git stash list`", message)
        self.assertEqual(stash_shas(self.main), [snapshots[0]])


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


class KeptAnchorsReachDrainerStatusTest(_AnchorSweepFixture):
    """What the sweep keeps is what `status` reports.

    The kept-anchor log line is otherwise the only place an anchor holding a
    sole copy of someone's work is named, and it repeats identically every
    pass. The controller restates the classification rather than importing the
    sweep -- it may not run a reaper to answer a status call -- so this holds
    the two sides equal on one repository: same anchors, same facts.
    """

    def _kept(self):
        return drain_prs_service.autostash_inventory(self.main)["kept_autostash_anchors"]

    def test_the_anchor_the_sweep_keeps_is_the_anchor_status_names(self):
        self._seed_unrelated_stash()
        sha = self._snapshot_commit("line3-orphaned")
        ref = drain_prs._anchor_snapshot(self.ctx, sha)

        drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=False)
        kept = self._kept()

        self.assertEqual(self._anchor_ref_names(), [ref])
        logged = self._logged_containing("Keeping autostash anchor")
        self.assertEqual(len(logged), 1)
        self.assertEqual(
            kept,
            [
                {
                    "ref": ref,
                    "commit": sha,
                    "date": self._commit_date(sha),
                    "restore": f"git stash apply --index {sha}",
                }
            ],
        )
        # Every fact the projection reports is a fact that log line reports,
        # so a reader moving between them is reading one contract.
        for fact in kept[0].values():
            self.assertIn(fact, logged[0])

    def test_the_anchor_the_sweep_reaps_leaves_status_verified_empty(self):
        self._redundant_anchor("line3-recovered")

        drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=False)

        self.assertEqual(self._logged_containing("Keeping autostash anchor"), [])
        self.assertEqual(self._kept(), [])

    def test_status_keeps_what_a_dry_run_sweep_only_reported(self):
        # A `--dry-run` sweep deletes nothing, so the anchor it would have
        # reaped is still there -- and still redundant, so status does not
        # report it as holding a sole copy of anything.
        ref, sha = self._redundant_anchor("line3-recovered")
        orphan = self._snapshot_commit("line3-orphaned")
        orphan_ref = drain_prs._anchor_snapshot(self.ctx, orphan)

        drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=True)

        self.assertEqual(sorted(self._anchor_ref_names()), sorted([ref, orphan_ref]))
        self.assertEqual([entry["ref"] for entry in self._kept()], [orphan_ref])


class _RecoveryStashRetirementFixture(_AnchorSweepFixture):
    """The startup retirement pass driven directly, with `log()` captured.

    Everything it says is a log line, exactly as the anchor sweep's is. The
    entries it decides about are built with the same `git stash store` the
    conflicted-restore path itself uses, so an eligible entry's message names
    its own object ID because that is what the drainer really writes.
    """

    def _recovery_entry(self, line3, *, message=None):
        """One stash entry in the exact reserved recovery form.

        `message` overrides the payload to build the near misses: the form is
        a reserved convention rather than creator provenance, so what decides
        eligibility is the payload and the object ID it names, never who
        wrote the entry.
        """
        sha = self._snapshot_commit(line3)
        payload = message if message is not None else f"drain-prs-autostash-recovery {sha}"
        run_git(["stash", "store", "-m", payload, sha], cwd=self.main)
        return sha

    def _user_entry(self, tag):
        """One stash entry of the user's own, pushed rather than stored."""
        (self.main / f"{tag}.txt").write_text(f"{tag}\n", encoding="utf-8")
        run_git(["add", f"{tag}.txt"], cwd=self.main)
        run_git(["commit", "-q", "-m", f"add {tag}.txt"], cwd=self.main)
        (self.main / f"{tag}.txt").write_text(f"{tag}-user-edit\n", encoding="utf-8")
        run_git(["stash", "push", "-q", "-m", f"user-{tag}"], cwd=self.main)
        return self._entries()[0]

    def _hold_elsewhere(self, sha, name="refs/snapshots/held"):
        """A ref outside `refs/stash` and the anchor namespace whose history
        holds the exact snapshot commit -- the only proof a retirement takes.
        """
        run_git(["update-ref", name, sha], cwd=self.main)
        return name

    def _entries(self):
        """(commit, raw message) per entry, in `git stash list` order.

        Compared as an ordered sequence of pairs rather than a set of commits:
        `git stash store` happily records two entries naming one commit, so a
        set would let a wrong removal pass unnoticed.
        """
        proc = run_git(["stash", "list", "--format=%H%x1f%gs"], cwd=self.main)
        return [
            tuple(line.split("\x1f", 1)) for line in proc.stdout.splitlines() if line
        ]

    def _reported(self):
        return drain_prs_service.autostash_inventory(self.main)["drainer_stashes"]


class RecoveryStashRetiredWhenHeldElsewhereTest(_RecoveryStashRetirementFixture):
    def test_an_entry_a_qualifying_ref_holds_is_removed_and_the_ref_remains(self):
        sha = self._recovery_entry("line3-recovered")
        held = self._hold_elsewhere(sha)
        user = self._user_entry("later")

        drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

        self.assertEqual(self._entries(), [user])
        # The proof itself is untouched: what a retirement removes is the
        # redundant copy, never the one that made it redundant.
        self.assertEqual(run_git(["rev-parse", held], cwd=self.main).stdout.strip(), sha)
        retired = self._logged_containing("Retired recovery stash entry")
        self.assertEqual(len(retired), 1)
        self.assertIn(sha, retired[0])
        self.assertIn(held, retired[0])
        self.assertEqual(self._reported(), [])


class RecoveryStashKeptWithoutIndependentReachabilityTest(_RecoveryStashRetirementFixture):
    """`refs/stash`, a reflog, and the drainer's own anchor are the three
    things that prove nothing. Counting the anchor would make the lifecycle
    circular, since the startup sweep deletes that anchor on the strength of
    this very entry.
    """

    def test_a_snapshot_only_the_stash_and_its_anchor_hold_is_kept_and_reported(self):
        sha = self._recovery_entry("line3-recovered")
        ref = drain_prs._anchor_snapshot(self.ctx, sha)
        before = self._entries()

        drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

        self.assertEqual(self._entries(), before)
        self.assertEqual(self._anchor_ref_names(), [ref])
        kept = self._logged_containing("Keeping recovery stash entry")
        self.assertEqual(len(kept), 1)
        self.assertIn(sha, kept[0])
        self.assertIn(f"git stash apply --index {sha}", kept[0])
        # Requirement 10: what is not retired is still what status reports.
        self.assertEqual(
            [entry["message"] for entry in self._reported()],
            [f"drain-prs-autostash-recovery {sha}"],
        )

    def test_a_snapshot_below_the_stash_tip_is_still_not_held_elsewhere(self):
        # `refs/stash` names only the newest entry, so an older one is in no
        # ref's history at all -- and must not become eligible for that.
        sha = self._recovery_entry("line3-recovered")
        user = self._user_entry("later")
        before = self._entries()
        self.assertEqual(before[1][0], sha)

        drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

        self.assertEqual(self._entries(), before)
        self.assertEqual(self._entries()[0], user)
        self.assertEqual(len(self._logged_containing("Keeping recovery stash entry")), 1)


class IneligibleStashEntriesAreNeverRetiredTest(_RecoveryStashRetirementFixture):
    """The reserved form is matched in full against the raw `%gs` payload.

    Every entry below is held by a qualifying ref, so its message is the only
    thing standing between it and removal.
    """

    def _survives(self, name, payload_for):
        sha = self._snapshot_commit(f"line3-{name}")
        run_git(["stash", "store", "-m", payload_for(sha), sha], cwd=self.main)
        self._hold_elsewhere(sha, f"refs/snapshots/{name}")
        before = self._entries()

        drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

        self.assertEqual(self._entries(), before)
        self.assertEqual(self._logged_containing("Retired recovery stash entry"), [])
        return sha

    def test_a_message_naming_another_snapshot_is_ineligible(self):
        other = self._snapshot_commit("line3-other")
        self._survives("mismatch", lambda _sha: f"drain-prs-autostash-recovery {other}")

    def test_the_unprepared_snapshot_form_is_ineligible(self):
        self._survives("unprepared", lambda _sha: "drain-prs-autostash-1700000000-4242")

    def test_a_prefixed_message_is_ineligible(self):
        self._survives("prefixed", lambda sha: f"recovered: drain-prs-autostash-recovery {sha}")

    def test_a_message_with_trailing_text_is_ineligible(self):
        self._survives("trailing", lambda sha: f"drain-prs-autostash-recovery {sha} (manual)")

    def test_a_similar_message_is_ineligible(self):
        self._survives("similar", lambda sha: f"drain-prs-autostash-recovered {sha}")

    def test_a_malformed_object_id_is_ineligible(self):
        self._survives("malformed", lambda _sha: "drain-prs-autostash-recovery " + "z" * 40)

    def test_an_abbreviated_object_id_is_ineligible(self):
        self._survives("abbreviated", lambda sha: f"drain-prs-autostash-recovery {sha[:12]}")

    def test_an_uppercase_object_id_is_ineligible(self):
        # The entry's own object ID is lowercase, so an uppercase spelling
        # names it in no sense this may act on.
        self._survives("uppercase", lambda sha: f"drain-prs-autostash-recovery {sha.upper()}")

    def test_a_wrapped_message_is_ineligible_although_status_still_claims_it(self):
        sha = self._survives(
            "wrapped", lambda sha: f"On master: drain-prs-autostash-recovery {sha}"
        )
        # The divergence is deliberate. Reporting unwraps git's `On <branch>: `
        # display prefix and claims this entry (requirement 10 leaves that
        # exactly as it was); retirement matches the payload verbatim and
        # refuses it, because removing an entry is destructive and reporting
        # one is not.
        self.assertEqual(
            [entry["message"] for entry in self._reported()],
            [f"drain-prs-autostash-recovery {sha}"],
        )
        self.assertEqual(len(self._logged_containing("Keeping recovery stash entry")), 0)


class RecoveryStashRetirementIsBoundToTheExpectedEntryTest(_RecoveryStashRetirementFixture):
    """`stash@{n}` is positional and git has no expected-object argument for a
    stash removal, so the binding is a fresh full read immediately before the
    removal: anything that moved aborts without mutating anything.
    """

    def _retire_with(self, at_seam):
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            proc = real_run(args, **kwargs)
            if args[:2] == ["git", "for-each-ref"]:
                at_seam()
            return proc

        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

    def test_an_insertion_before_the_removal_aborts_without_touching_the_stash(self):
        sha = self._recovery_entry("line3-recovered")
        self._hold_elsewhere(sha)
        before = self._entries()

        self._retire_with(lambda: self._user_entry("late"))

        # Every selector moved by one; nothing was removed on the old reading.
        entries = self._entries()
        self.assertEqual(len(entries), 2)
        self.assertEqual(entries[1], before[0])
        aborted = self._logged_containing("the stash changed")
        self.assertEqual(len(aborted), 1)
        self.assertIn(sha, aborted[0])
        self.assertIn(f"git stash apply --index {sha}", aborted[0])
        self.assertEqual(self._logged_containing("Retired recovery stash entry"), [])

    def test_a_concurrent_drop_before_the_removal_aborts_without_touching_the_stash(self):
        sha = self._recovery_entry("line3-recovered")
        self._hold_elsewhere(sha)
        self._user_entry("doomed")

        self._retire_with(
            lambda: run_git(["stash", "drop", "-q", "stash@{0}"], cwd=self.main)
        )

        # Only the user's own drop took effect; the target is where it was.
        self.assertEqual(
            self._entries(), [(sha, f"drain-prs-autostash-recovery {sha}")]
        )
        self.assertEqual(len(self._logged_containing("the stash changed")), 1)
        self.assertEqual(self._logged_containing("Retired recovery stash entry"), [])


class RecoveryStashRetirementPreservesEveryOtherEntryTest(_RecoveryStashRetirementFixture):
    def test_non_target_entries_keep_their_contents_and_relative_order(self):
        self._user_entry("oldest")
        sha = self._recovery_entry("line3-recovered")
        self._hold_elsewhere(sha)
        self._user_entry("newest")
        before = self._entries()
        self.assertEqual(before[1][0], sha)

        drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

        self.assertEqual(self._entries(), [before[0], before[2]])
        self.assertEqual(len(self._logged_containing("Retired recovery stash entry")), 1)


class RecoveryStashRestoredWhenVerificationFailsTest(_RecoveryStashRetirementFixture):
    """The window between the binding read and the removal cannot be closed,
    only covered: whatever the post-removal state is missing goes back.
    """

    def _retire_with(self, fake_run):
        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

    def test_a_qualifying_ref_lost_after_the_removal_puts_the_entry_back(self):
        sha = self._recovery_entry("line3-recovered")
        held = self._hold_elsewhere(sha)
        user = self._user_entry("later")
        message = f"drain-prs-autostash-recovery {sha}"
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            proc = real_run(args, **kwargs)
            if args[:3] == ["git", "stash", "drop"]:
                # Exactly the losing window: the entry is gone, and the ref
                # that proved it redundant went with it.
                run_git(["update-ref", "-d", held], cwd=self.main)
            return proc

        self._retire_with(fake_run)

        # Back, under its own object ID and verbatim message -- at the top,
        # because git offers no positional reinsertion.
        self.assertEqual(self._entries(), [(sha, message), user])
        restored = self._logged_containing("Restored stash entry")
        self.assertEqual(len(restored), 1)
        self.assertIn(sha, restored[0])
        self.assertIn("stash@{0}", restored[0])
        self.assertIn("no longer reachable", restored[0])
        self.assertEqual(self._logged_containing("Retired recovery stash entry"), [])
        self.assertEqual([entry["message"] for entry in self._reported()], [message])

    def test_a_removal_that_took_a_different_entry_restores_that_entry(self):
        oldest = self._user_entry("oldest")
        sha = self._recovery_entry("line3-recovered")
        self._hold_elsewhere(sha)
        newest = self._user_entry("newest")
        message = f"drain-prs-autostash-recovery {sha}"
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            if args[:3] == ["git", "stash", "drop"]:
                # What a concurrent `git stash push` between the binding read
                # and this removal does: every selector shifts, and the drop
                # lands on a neighbour. Putting "the target" back would not
                # put back the entry that actually went.
                return real_run(["git", "stash", "drop", "--quiet", "stash@{2}"], **kwargs)
            return real_run(args, **kwargs)

        self._retire_with(fake_run)

        self.assertEqual(self._entries(), [oldest, newest, (sha, message)])
        restored = self._logged_containing("Restored stash entry")
        self.assertEqual(len(restored), 1)
        self.assertIn(oldest[0], restored[0])
        self.assertEqual(self._logged_containing("Retired recovery stash entry"), [])

    def test_a_wrong_removal_of_an_entry_naming_the_same_commit_is_caught(self):
        # `git stash store` records two entries naming one commit, so a
        # comparison over commits alone cannot tell these two apart and a
        # wrong removal would pass unnoticed. What verification compares is
        # the ordered sequence of (commit, message) pairs.
        sha = self._snapshot_commit("line3-recovered")
        older = self._snapshot_commit("line3-older")
        newest = self._snapshot_commit("line3-newest")
        message = f"drain-prs-autostash-recovery {sha}"
        for payload, commit in (
            ("a copy of my own", sha),
            ("older", older),
            (message, sha),
            ("newest", newest),
        ):
            run_git(["stash", "store", "-m", payload, commit], cwd=self.main)
        self._hold_elsewhere(sha)
        before = self._entries()
        self.assertEqual(
            before,
            [
                (newest, "newest"),
                (sha, message),
                (older, "older"),
                (sha, "a copy of my own"),
            ],
        )
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            if args[:3] == ["git", "stash", "drop"]:
                # The user's own copy of the same snapshot goes instead of the
                # drainer's entry: same commit, different entry. Every commit
                # the stash held is still in it afterwards.
                return real_run(["git", "stash", "drop", "--quiet", "stash@{3}"], **kwargs)
            return real_run(args, **kwargs)

        self._retire_with(fake_run)

        self.assertEqual(
            self._entries(),
            [
                (sha, "a copy of my own"),
                (newest, "newest"),
                (sha, message),
                (older, "older"),
            ],
        )
        restored = self._logged_containing("Restored stash entry")
        self.assertEqual(len(restored), 1)
        self.assertIn(sha, restored[0])
        self.assertEqual(self._logged_containing("Retired recovery stash entry"), [])

    def test_a_failed_restoration_names_the_object_id_and_a_recovery_command(self):
        sha = self._recovery_entry("line3-recovered")
        held = self._hold_elsewhere(sha)
        user = self._user_entry("later")
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            if args[:3] == ["git", "stash", "store"]:
                return subprocess.CompletedProcess(args, 1, "", "fatal: cannot store\n")
            proc = real_run(args, **kwargs)
            if args[:3] == ["git", "stash", "drop"]:
                run_git(["update-ref", "-d", held], cwd=self.main)
            return proc

        self._retire_with(fake_run)

        # The run continues: the other entry is untouched and nothing raised.
        self.assertEqual(self._entries(), [user])
        failed = self._logged_containing("could not put it back")
        self.assertEqual(len(failed), 1)
        self.assertIn(sha, failed[0])
        self.assertIn("cannot store", failed[0])
        self.assertIn(f"git stash apply --index {sha}", failed[0])


class RecoveryStashRetirementFailuresAreNonFatalTest(_RecoveryStashRetirementFixture):
    """A stash sweep must never be what stops a pull request from merging, so
    every way it can fail is logged and stepped over.
    """

    def _retire_with(self, fake_run):
        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

    def _failing_stash_read(self, occurrence):
        real_run = drain_prs.run
        reads = []

        def fake_run(args, **kwargs):
            if args[:3] == ["git", "stash", "list"]:
                reads.append(args)
                if len(reads) == occurrence:
                    raise drain_prs.DrainError("stash list is unavailable")
            return real_run(args, **kwargs)

        return fake_run

    def test_an_unreadable_stash_keeps_every_entry(self):
        sha = self._recovery_entry("line3-recovered")
        self._hold_elsewhere(sha)
        before = self._entries()

        self._retire_with(self._failing_stash_read(1))

        self.assertEqual(self._entries(), before)
        self.assertEqual(len(self._logged_containing("Could not read")), 1)

    def test_an_unreadable_stash_before_the_removal_keeps_the_entry(self):
        sha = self._recovery_entry("line3-recovered")
        self._hold_elsewhere(sha)
        before = self._entries()

        self._retire_with(self._failing_stash_read(2))

        self.assertEqual(self._entries(), before)
        aborted = self._logged_containing("could not be re-read immediately before")
        self.assertEqual(len(aborted), 1)
        self.assertIn(sha, aborted[0])

    def test_an_unreadable_stash_after_the_removal_puts_the_entry_back(self):
        sha = self._recovery_entry("line3-recovered")
        self._hold_elsewhere(sha)
        user = self._user_entry("later")
        message = f"drain-prs-autostash-recovery {sha}"

        self._retire_with(self._failing_stash_read(3))

        self.assertEqual(self._entries(), [(sha, message), user])
        restored = self._logged_containing("Restored stash entry")
        self.assertEqual(len(restored), 1)
        self.assertIn("could not be re-read to confirm the removal", restored[0])

    def test_an_unreadable_ref_state_keeps_the_entry(self):
        sha = self._recovery_entry("line3-recovered")
        self._hold_elsewhere(sha)
        before = self._entries()
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            if args[:2] == ["git", "for-each-ref"]:
                raise drain_prs.DrainError("for-each-ref is unavailable")
            return real_run(args, **kwargs)

        self._retire_with(fake_run)

        self.assertEqual(self._entries(), before)
        kept = self._logged_containing("could not be read")
        self.assertEqual(len(kept), 1)
        self.assertIn(sha, kept[0])

    def test_a_failed_removal_keeps_its_own_entry_and_retires_the_others(self):
        # A removal that never ran leaves the enumeration describing the stash
        # exactly as it still is, so the next candidate is still where it says
        # and does not wait for another startup.
        first = self._recovery_entry("line3-first")
        self._hold_elsewhere(first, "refs/snapshots/first")
        second = self._recovery_entry("line3-second")
        self._hold_elsewhere(second, "refs/snapshots/second")
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            if args[:5] == ["git", "stash", "drop", "--quiet", "stash@{0}"]:
                return subprocess.CompletedProcess(args, 1, "", "fatal: cannot lock\n")
            return real_run(args, **kwargs)

        self._retire_with(fake_run)

        self.assertEqual(
            self._entries(), [(second, f"drain-prs-autostash-recovery {second}")]
        )
        failed = self._logged_containing("Could not retire recovery stash entry")
        self.assertEqual(len(failed), 1)
        self.assertIn(second, failed[0])
        retired = self._logged_containing("Retired recovery stash entry")
        self.assertEqual(len(retired), 1)
        self.assertIn(first, retired[0])

    def test_a_failed_removal_keeps_the_entry(self):
        sha = self._recovery_entry("line3-recovered")
        self._hold_elsewhere(sha)
        before = self._entries()
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            if args[:3] == ["git", "stash", "drop"]:
                return subprocess.CompletedProcess(args, 1, "", "fatal: cannot lock\n")
            return real_run(args, **kwargs)

        self._retire_with(fake_run)

        self.assertEqual(self._entries(), before)
        failed = self._logged_containing("Could not retire recovery stash entry")
        self.assertEqual(len(failed), 1)
        self.assertIn("cannot lock", failed[0])


class RecoveryStashRetirementDryRunTest(_RecoveryStashRetirementFixture):
    def test_dry_run_reports_the_decision_and_changes_nothing(self):
        sha = self._recovery_entry("line3-recovered")
        held = self._hold_elsewhere(sha)
        anchor = drain_prs._anchor_snapshot(self.ctx, sha)
        self._user_entry("later")
        before = self._entries()

        drain_prs.retire_recovery_stashes(self.ctx, dry_run=True)

        self.assertEqual(self._entries(), before)
        self.assertEqual(self._anchor_ref_names(), [anchor])
        self.assertEqual(run_git(["rev-parse", held], cwd=self.main).stdout.strip(), sha)
        would = self._logged_containing("Would retire recovery stash entry")
        self.assertEqual(len(would), 1)
        self.assertIn(sha, would[0])
        self.assertIn(held, would[0])
        self.assertEqual(self._logged_containing("Retired recovery stash entry"), [])

    def test_dry_run_reports_why_an_entry_would_be_kept(self):
        sha = self._recovery_entry("line3-orphaned")
        before = self._entries()

        drain_prs.retire_recovery_stashes(self.ctx, dry_run=True)

        self.assertEqual(self._entries(), before)
        kept = self._logged_containing("Keeping recovery stash entry")
        self.assertEqual(len(kept), 1)
        self.assertIn(sha, kept[0])


class TwoEligibleRecoveryStashesTest(_RecoveryStashRetirementFixture):
    """Each removal invalidates every later selector the same read produced,
    so at most one entry is retired per read.
    """

    def test_both_are_retired_each_through_its_own_fresh_read(self):
        oldest = self._user_entry("oldest")
        first = self._recovery_entry("line3-first")
        self._hold_elsewhere(first, "refs/snapshots/first")
        middle = self._user_entry("middle")
        second = self._recovery_entry("line3-second")
        self._hold_elsewhere(second, "refs/snapshots/second")
        self.assertEqual(
            [sha for sha, _ in self._entries()], [second, middle[0], first, oldest[0]]
        )
        dropped = []
        real_run = drain_prs.run

        def fake_run(args, **kwargs):
            if args[:4] == ["git", "stash", "drop", "--quiet"]:
                dropped.append(args[4])
            return real_run(args, **kwargs)

        with mock.patch.object(drain_prs, "run", side_effect=fake_run):
            drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

        self.assertEqual(self._entries(), [middle, oldest])
        # The second removal used a selector from a read taken after the
        # first: on the enumeration that chose them, `first` was `stash@{2}`.
        self.assertEqual(dropped, ["stash@{0}", "stash@{1}"])
        self.assertEqual(len(self._logged_containing("Retired recovery stash entry")), 2)
        self.assertEqual(self._reported(), [])


class KeptAnchorAndRetirementCoexistTest(_RecoveryStashRetirementFixture):
    """Ordering across the two startup passes is load-bearing, and an anchor
    that outlived its own reap is neither a blocker nor a proof.
    """

    def test_an_anchor_that_outlived_its_reap_neither_blocks_nor_qualifies(self):
        sha = self._recovery_entry("line3-recovered")
        anchor = drain_prs._anchor_snapshot(self.ctx, sha)
        self._hold_elsewhere(sha)

        drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

        # A kept anchor beside a qualifying ref and no stash entry is a fine
        # resting state, not a post-removal verification failure.
        self.assertEqual(self._entries(), [])
        self.assertEqual(self._anchor_ref_names(), [anchor])
        self.assertEqual(len(self._logged_containing("Retired recovery stash entry")), 1)

    def test_the_anchor_sweep_first_leaves_neither_artifact_behind(self):
        sha = self._recovery_entry("line3-recovered")
        drain_prs._anchor_snapshot(self.ctx, sha)
        self._hold_elsewhere(sha)

        drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=False)
        drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

        self.assertEqual(self._anchor_ref_names(), [])
        self.assertEqual(self._entries(), [])
        self.assertEqual(
            drain_prs_service.autostash_inventory(self.main),
            {"kept_autostash_anchors": [], "drainer_stashes": []},
        )

    def test_the_reverse_order_would_strand_the_anchor(self):
        sha = self._recovery_entry("line3-recovered")
        ref = drain_prs._anchor_snapshot(self.ctx, sha)
        self._hold_elsewhere(sha)

        drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)
        drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=False)

        # Why the seam runs the sweep first: the sweep deletes an anchor only
        # while its snapshot is a `git stash list` entry, so retiring the
        # entry first trades one permanent artifact for another.
        self.assertEqual(self._anchor_ref_names(), [ref])
        self.assertEqual(len(self._logged_containing("Keeping autostash anchor")), 1)


class ConflictedRestoreIsRetiredOnlyByALaterRunTest(_RecoveryStashRetirementFixture):
    def test_the_originating_pass_keeps_both_copies_and_a_later_run_decides(self):
        (self.main / "shared.txt").write_text(
            "line1-local\nline2\nline3\n", encoding="utf-8"
        )
        self._advance_origin_line1("line1-remote")

        with self.assertRaises(drain_prs.DrainError):
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        entries = self._entries()
        self.assertEqual(len(entries), 1)
        sha, message = entries[0]
        self.assertEqual(message, f"drain-prs-autostash-recovery {sha}")
        self.assertEqual(
            self._anchor_ref_names(), [drain_prs._snapshot_anchor_ref(sha)]
        )

        # A later run, with the snapshot held nowhere else: still both copies.
        drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)
        self.assertEqual(self._entries(), entries)
        self.assertEqual(len(self._logged_containing("Keeping recovery stash entry")), 1)

        # And once the work is somewhere of the user's own choosing, retired.
        held = self._hold_elsewhere(sha)
        drain_prs.sweep_snapshot_anchors(self.ctx, dry_run=False)
        drain_prs.retire_recovery_stashes(self.ctx, dry_run=False)

        self.assertEqual(self._entries(), [])
        self.assertEqual(self._anchor_ref_names(), [])
        self.assertEqual(run_git(["rev-parse", held], cwd=self.main).stdout.strip(), sha)


class DrainerStashMessagesReachDrainerStatusTest(_FastForwardStashFixture):
    """The controller restates the drainer's own stash messages rather than
    importing them, exactly as it restates the drainer's cleanup vocabulary.
    These drive the real paths that write one and hold the two sides equal.
    """

    def _claimed(self):
        return [
            drain_prs_service.drainer_stash_message(subject)
            for subject in run_git(
                ["stash", "list", "--format=%gs"], cwd=self.main
            ).stdout.splitlines()
        ]

    def test_a_conflicted_restore_writes_an_entry_the_controller_claims(self):
        user_stash_sha = self._seed_unrelated_stash()
        (self.main / "shared.txt").write_text(
            "line1-local\nline2\nline3\n", encoding="utf-8"
        )
        self._advance_origin_line1("line1-remote")

        with self.assertRaises(drain_prs.DrainError):
            drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        shas = stash_shas(self.main)
        self.assertEqual(len(shas), 2)
        recovered = next(sha for sha in shas if sha != user_stash_sha)
        # The drainer's entry is claimed by its exact payload; the user's,
        # which was pushed rather than stored, is not claimed at all.
        self.assertEqual(
            self._claimed(), [f"drain-prs-autostash-recovery {recovered}", None]
        )
        self.assertEqual(
            [
                entry["message"]
                for entry in drain_prs_service.autostash_inventory(self.main)[
                    "drainer_stashes"
                ]
            ],
            [f"drain-prs-autostash-recovery {recovered}"],
        )


class UnpreparedSnapshotReachesDrainerStatusTest(_LateTrackedEditFixture):
    """The drainer's other stash message: a pass whose snapshot could not be
    prepared stores the orphaned commit under the message it had already built
    for `git stash create`, which is the `<epoch>-<pid>` form.
    """

    def test_a_failed_preparation_writes_an_entry_the_controller_claims(self):
        self._dirty_the_checkout()
        self._advance_origin_line1("line1-updated")
        patcher, _ = self._edit_after_initial_snapshot(
            "line1\nline2\nline3-written-after-the-snapshot\n"
        )
        calls = []

        with self._recording_run(calls, fail_later_snapshots_with="injected"), patcher:
            with self.assertRaises(drain_prs.DrainError):
                drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)

        reported = drain_prs_service.autostash_inventory(self.main)["drainer_stashes"]

        self.assertEqual(len(reported), 1)
        self.assertEqual(reported[0]["stash"], "stash@{0}")
        self.assertRegex(
            reported[0]["message"], rf"^drain-prs-autostash-[0-9]+-{os.getpid()}$"
        )


class FastForwardNeverSweepsAnchorsTest(_FastForwardStashFixture):
    """Both startup passes are startup steps and nothing else. Running either
    from inside a fast-forward would put a reaper inside the very window where
    the anchor and the entry it writes are the only copies of the user's
    changes -- so neither is called, and neither one's git commands run.
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
                with mock.patch.object(
                    drain_prs, "retire_recovery_stashes", side_effect=AssertionError
                ):
                    try:
                        drain_prs.fast_forward_default_branch(self.ctx, dry_run=False)
                        error = None
                    except drain_prs.DrainError as exc:
                        error = exc
        self.assertEqual([c for c in calls if c[:2] == ["git", "for-each-ref"]], [])
        # The retirement's own reads and its one mutation, named separately:
        # a pass renamed or inlined elsewhere would otherwise lose this cover.
        self.assertEqual([c for c in calls if c[:3] == ["git", "stash", "list"]], [])
        self.assertEqual([c for c in calls if c[:3] == ["git", "stash", "drop"]], [])
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
    """Both startup passes run exactly once per process, on the seam both
    modes pass through, before either can merge or fast-forward anything --
    and the anchor sweep runs before the retirement, because it can only reap
    an anchor while that anchor's snapshot is still a stash entry.
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
        real_retire = drain_prs.retire_recovery_stashes

        def fake_sweep(ctx, *, dry_run):
            events.append("sweep")
            return real_sweep(ctx, dry_run=dry_run)

        def fake_retire(ctx, *, dry_run):
            events.append("retire")
            return real_retire(ctx, dry_run=dry_run)

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
            stack.enter_context(
                mock.patch.object(
                    drain_prs, "retire_recovery_stashes", side_effect=fake_retire
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

        self.assertEqual(events, ["sweep", "retire", "loop"])
        # A real sweep ran, not just the seam: the unmatched anchor survives.
        self.assertEqual(self._anchor_ref_names(), [ref])

    def test_single_pr_run_sweeps_once_and_still_emits_one_json_document(self):
        sha = self._snapshot_commit("line3-orphaned")
        drain_prs._anchor_snapshot(self.ctx, sha)

        events, stdout = self._run_main("--pr", "42")

        self.assertEqual(events, ["sweep", "retire", "drain_one_pr"])
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
        # Eligible for retirement too, so a dry run that mutated would be
        # visible in the stash below as well as in the anchor.
        run_git(["update-ref", "refs/snapshots/held", sha], cwd=self.main)

        events, _stdout = self._run_main("--once", "--dry-run")

        self.assertEqual(events, ["sweep", "retire", "loop"])
        self.assertEqual(self._anchor_ref_names(), [ref])
        self.assertEqual(stash_shas(self.main), [sha])


class FastForwardUnderStopDeadlineTest(_FastForwardStashFixture):
    """Issue #216: the final cleanup pass of an intentional stop bounds every
    command it runs, and the fast-forward is the obligation with a window in
    which the user's local changes live only in a snapshot commit.

    A command that wedges inside that window ends the obligation, so what has
    to hold is what holds for a crash there: the tracked changes stay
    recoverable through the anchor or the stash, the untracked ones stay in
    their holding directory, and the fast-forward stays owed.
    """

    def _dirty_the_checkout(self):
        (self.main / "shared.txt").write_text(
            "line1\nline2\nline3-local\n", encoding="utf-8"
        )
        (self.main / "untracked.txt").write_text("local-untracked\n", encoding="utf-8")

    def _wedging(self, command, *, occurrence=1):
        """Substitute a command that never returns for the `occurrence`th call
        matching `command`, so only a caller bounding it gets past."""
        real_run = drain_prs.run
        seen = []

        def fake_run(args, **kwargs):
            seen.append(list(args))
            matches = [call for call in seen if call[: len(command)] == list(command)]
            if list(args[: len(command)]) == list(command) and len(matches) == occurrence:
                return real_run(["sh", "-c", "sleep 60"], **kwargs)
            return real_run(args, **kwargs)

        return mock.patch.object(drain_prs, "run", side_effect=fake_run)

    @contextlib.contextmanager
    def _spent_budget(self, seconds=0.5):
        with mock.patch.object(
            drain_prs, "SHUTDOWN_MIN_COMMAND_TIMEOUT_SECONDS", seconds
        ):
            with drain_prs.command_deadline(time.monotonic() + seconds):
                yield

    def _fast_forward_obligation(self):
        return {
            "pr": {"number": 42},
            "pending": [{"kind": "fast-forward"}],
            "failed_passes": 0,
            "last_error": None,
            "incident": None,
        }

    def test_a_wedged_retry_restores_the_changes_and_leaves_the_ff_owed(self):
        head_before = run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip()
        self._dirty_the_checkout()
        self._advance_origin_line1("line1-remote")
        record = self._fast_forward_obligation()

        # The `--ff-only` retry after the reset: the changes exist only in the
        # anchored snapshot at this point.
        with self._spent_budget(), self._wedging(
            ["git", "merge", "--ff-only"], occurrence=2
        ):
            errors = drain_prs.run_cleanup_pass(self.ctx, record, dry_run=False)

        self.assertEqual(len(errors), 1)
        self.assertIn("timed out", errors[0])
        # Restoration still ran, under the per-command floor that exists for
        # exactly this: the changes are back in the working tree.
        self.assertEqual(
            (self.main / "shared.txt").read_text(encoding="utf-8"),
            "line1\nline2\nline3-local\n",
        )
        self.assertEqual(
            (self.main / "untracked.txt").read_text(encoding="utf-8"),
            "local-untracked\n",
        )
        self.assertEqual(anchor_refs(self.main).strip(), "")
        self.assertEqual(list((self.main / ".git").glob("autostash-*")), [])
        # The fast-forward did not happen, and is still owed.
        self.assertEqual(
            run_git(["rev-parse", "HEAD"], cwd=self.main).stdout.strip(), head_before
        )
        self.assertEqual(record["pending"], [{"kind": "fast-forward"}])

    def test_a_wedged_restore_still_leaves_every_change_recoverable(self):
        self._dirty_the_checkout()
        self._advance_origin_line1("line1-remote")
        record = self._fast_forward_obligation()

        # The harshest point of all: the restore itself is what wedges, after
        # `reset --hard` has already cleared the working tree.
        with self._spent_budget(), self._wedging(["git", "stash", "apply"]):
            errors = drain_prs.run_cleanup_pass(self.ctx, record, dry_run=False)

        self.assertEqual(len(errors), 1)
        self.assertIn("timed out", errors[0])
        anchors = [
            line.split()[0] for line in anchor_refs(self.main).strip().splitlines()
        ]
        self.assertEqual(len(anchors), 1)
        # The anchor is a real recovery path, not just a surviving ref.
        run_git(["stash", "apply", "--index", anchors[0]], cwd=self.main)
        self.assertEqual(
            (self.main / "shared.txt").read_text(encoding="utf-8"),
            "line1-remote\nline2\nline3-local\n",
        )
        holding = list((self.main / ".git").glob("autostash-*"))
        self.assertEqual(len(holding), 1)
        self.assertEqual(
            (holding[0] / "untracked.txt").read_text(encoding="utf-8"),
            "local-untracked\n",
        )
        # The ref moved, but the obligation did not complete: it stays owed,
        # and the retry that finds nothing to fast-forward discharges it.
        self.assertEqual(record["pending"], [{"kind": "fast-forward"}])

    def test_the_deadline_does_not_outlive_the_block_that_set_it(self):
        # Every other caller of run() is under the polling loop's own cadence
        # and must keep waiting as long as it takes.
        with self._spent_budget():
            self.assertIsNotNone(drain_prs.effective_timeout(None))
        self.assertIsNone(drain_prs.effective_timeout(None))
        self.assertIsNone(drain_prs.COMMAND_DEADLINE)


if __name__ == "__main__":
    unittest.main()
