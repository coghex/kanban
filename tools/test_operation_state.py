"""In-progress-operation detection for the drainer and its controller.

The drainer coexists with uncommitted local work -- its post-merge
fast-forward stashes and restores it -- so the only repository condition that
still refuses a start is a checkout stopped part-way through a git operation,
which blocks that fast-forward until a human resolves it.

Every case here drives a real temporary repository into a real operation
state rather than mocking one, because the whole point of the check is that it
reads the markers git itself writes. Nothing here touches the network, a model,
or the developer's own drainer installation.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

import hashlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import drain_prs
import drain_prs_service


def run_git(args, *, cwd, check=True):
    proc = subprocess.run(
        ["git", *args], cwd=str(cwd), text=True, capture_output=True
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed in {cwd}:\n{proc.stdout}\n{proc.stderr}"
        )
    return proc


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class _OperationFixture(unittest.TestCase):
    """A repository with two conflicting single-line histories, so every
    operation below can be driven into a genuine unresolved state."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bare = self.root / "remote.git"
        self.repo = self.root / "main"
        self.repo.mkdir()

        run_git(["init", "--bare", "-q", "-b", "master", str(self.bare)], cwd=self.root)
        run_git(["init", "-q", "-b", "master", "."], cwd=self.repo)
        run_git(["config", "user.email", "test@example.com"], cwd=self.repo)
        run_git(["config", "user.name", "Test"], cwd=self.repo)
        (self.repo / "f.txt").write_text("base\n", encoding="utf-8")
        run_git(["add", "f.txt"], cwd=self.repo)
        run_git(["commit", "-q", "-m", "base"], cwd=self.repo)
        self.base_sha = run_git(["rev-parse", "HEAD"], cwd=self.repo).stdout.strip()

        run_git(["checkout", "-q", "-b", "side"], cwd=self.repo)
        (self.repo / "f.txt").write_text("side\n", encoding="utf-8")
        run_git(["commit", "-q", "-am", "side"], cwd=self.repo)
        self.side_sha = run_git(["rev-parse", "HEAD"], cwd=self.repo).stdout.strip()

        run_git(["checkout", "-q", "master"], cwd=self.repo)
        # Enough commits that a bisect actually checks a middle one out and
        # detaches HEAD, rather than concluding on the first answer.
        for step in range(1, 5):
            (self.repo / "f.txt").write_text(f"master-{step}\n", encoding="utf-8")
            run_git(["commit", "-q", "-am", f"master {step}"], cwd=self.repo)

        run_git(["remote", "add", "origin", str(self.bare)], cwd=self.repo)
        run_git(["push", "-q", "-u", "origin", "master"], cwd=self.repo)
        run_git(["remote", "set-head", "origin", "master"], cwd=self.repo)

    # -- driving each operation into an unresolved state ------------------

    def begin_merge(self):
        run_git(["merge", "side"], cwd=self.repo, check=False)

    def begin_rebase(self):
        run_git(["checkout", "-q", "side"], cwd=self.repo)
        run_git(["rebase", "master"], cwd=self.repo, check=False)

    def begin_am(self):
        patch = run_git(
            ["format-patch", "-1", "--stdout", "side"], cwd=self.repo
        ).stdout
        proc = subprocess.run(
            ["git", "am"],
            cwd=str(self.repo),
            input=patch,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(proc.returncode, 0, "the patch was expected to conflict")

    def begin_cherry_pick(self):
        run_git(["cherry-pick", self.side_sha], cwd=self.repo, check=False)

    def begin_revert(self):
        # Reverting the commit that created f.txt means deleting a file whose
        # content has since changed -- a modify/delete conflict.
        run_git(["revert", "--no-edit", self.base_sha], cwd=self.repo, check=False)

    def begin_bisect(self):
        run_git(["bisect", "start"], cwd=self.repo)
        run_git(["bisect", "bad"], cwd=self.repo)
        run_git(["bisect", "good", self.base_sha], cwd=self.repo, check=False)

    def dirty_the_tree(self):
        """Staged, unstaged, and untracked changes -- and nothing else."""
        (self.repo / "staged.txt").write_text("staged\n", encoding="utf-8")
        run_git(["add", "staged.txt"], cwd=self.repo)
        (self.repo / "f.txt").write_text("locally edited\n", encoding="utf-8")
        (self.repo / "scratch.txt").write_text("untracked\n", encoding="utf-8")


# Every operation that leaves a repository needing a human before a
# fast-forward can succeed, with the name the refusal has to report.
OPERATIONS = (
    ("merge", "merge"),
    ("rebase", "rebase"),
    ("am", "am"),
    ("cherry_pick", "cherry-pick"),
    ("revert", "revert"),
    ("bisect", "bisect"),
)

# The four the issue names, for the paths where enumerating all six only
# repeats what the detector above already establishes.
CORE_OPERATIONS = ("merge", "rebase", "cherry_pick", "bisect")


class DrainerOperationDetectionTests(_OperationFixture):
    def test_a_clean_checkout_reports_no_operation(self):
        self.assertIsNone(drain_prs.in_progress_operation(self.repo / ".git"))
        drain_prs.require_no_operation_in_progress(self.repo)

    def test_ordinary_uncommitted_work_is_not_an_operation(self):
        self.dirty_the_tree()

        self.assertIsNone(drain_prs.in_progress_operation(self.repo / ".git"))
        drain_prs.require_no_operation_in_progress(self.repo)

    def test_each_unresolved_operation_is_named(self):
        for starter, expected in OPERATIONS:
            with self.subTest(operation=expected):
                self.setUp()
                getattr(self, f"begin_{starter}")()

                self.assertEqual(
                    drain_prs.in_progress_operation(self.repo / ".git"), expected
                )
                with self.assertRaisesRegex(
                    drain_prs.DrainError, f"a {expected} is in progress"
                ):
                    drain_prs.require_no_operation_in_progress(self.repo)

    def test_the_check_mutates_neither_the_index_nor_the_operation_metadata(self):
        # `git status` refreshes the index's stat cache and rewrites
        # .git/index; reading marker paths does not, which is what keeps a
        # dry run byte for byte pure and an unresolved conflict intact.
        for starter, expected in OPERATIONS:
            with self.subTest(operation=expected):
                self.setUp()
                getattr(self, f"begin_{starter}")()
                git_dir = self.repo / ".git"
                before = {
                    str(path.relative_to(git_dir)): digest(path)
                    for path in sorted(git_dir.rglob("*"))
                    if path.is_file() and not path.is_symlink()
                }
                worktree_before = (self.repo / "f.txt").read_bytes()

                with self.assertRaises(drain_prs.DrainError):
                    drain_prs.require_no_operation_in_progress(self.repo)

                after = {
                    str(path.relative_to(git_dir)): digest(path)
                    for path in sorted(git_dir.rglob("*"))
                    if path.is_file() and not path.is_symlink()
                }
                self.assertEqual(after, before)
                self.assertEqual((self.repo / "f.txt").read_bytes(), worktree_before)

    def test_a_linked_worktree_is_read_through_its_own_git_directory(self):
        # ctx.path / ".git" is a gitdir *file* for a linked worktree, and the
        # per-worktree operation markers live in the directory it points at.
        linked = Path(self.tmp.name) / "linked"
        run_git(["worktree", "add", "-q", str(linked), "side"], cwd=self.repo)
        run_git(["merge", "master"], cwd=linked, check=False)

        self.assertEqual(drain_prs.in_progress_operation(drain_prs.git_dir(linked)), "merge")
        self.assertIsNone(drain_prs.in_progress_operation(drain_prs.git_dir(self.repo)))


class ControllerOperationDetectionTests(_OperationFixture):
    """The controller decides whether to start before the drainer process
    exists, so it reads the same repository state independently."""

    def _job(self):
        # The fixture's remote is a plain local path, so the identity is
        # supplied rather than resolved: what these tests exercise is the
        # repository-state preconditions, which are the same for every job.
        return drain_prs_service.job_for_identity(self.repo, "acme/widgets")

    def _stopped_snapshot(self):
        # Resolved before the backend is replaced, so the job keeps its real
        # identifier and paths; the stand-in only answers whether the service
        # manager holds the job, which no test here may ask a real one.
        job = self._job()
        backend = mock.Mock()
        backend.is_loaded.return_value = False
        with (
            mock.patch.object(drain_prs_service, "read_json", return_value={}),
            mock.patch.object(drain_prs_service, "pid_alive", return_value=False),
            mock.patch.object(drain_prs_service, "lock_pid", return_value=None),
            mock.patch.object(drain_prs_service, "incident_files", return_value=[]),
            mock.patch.object(drain_prs_service, "latest_log_path", return_value=None),
            mock.patch.object(
                drain_prs_service, "service_backend", return_value=backend
            ),
        ):
            return drain_prs_service.status_snapshot(job)

    def _start(self):
        with (
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
            drain_prs_service.start_service(self._job())

    def test_a_dirty_checkout_reports_stopped_and_starts(self):
        self.dirty_the_tree()

        snapshot = self._stopped_snapshot()

        self.assertEqual(snapshot["state"], "stopped")
        self.assertIsNone(snapshot["operation"])
        # Past both preconditions and into installation, dirty tree and all.
        with self.assertRaisesRegex(
            drain_prs_service.ServiceError, "reached installation"
        ):
            self._start()

    def test_each_unresolved_operation_blocks_a_start_by_name(self):
        for starter in CORE_OPERATIONS:
            expected = dict(OPERATIONS)[starter]
            with self.subTest(operation=expected):
                self.setUp()
                getattr(self, f"begin_{starter}")()

                snapshot = self._stopped_snapshot()
                self.assertEqual(snapshot["state"], "mid_operation")
                self.assertEqual(snapshot["operation"], expected)

                with self.assertRaisesRegex(
                    drain_prs_service.ServiceError, f"a {expected} is in progress"
                ):
                    self._start()

    def test_a_detached_head_operation_is_named_rather_than_the_branch(self):
        # A rebase and a bisect both leave a detached HEAD. Checking the
        # default-branch precondition first would report that symptom instead
        # of the operation the user actually has to finish.
        for starter in ("rebase", "bisect"):
            with self.subTest(operation=starter):
                self.setUp()
                getattr(self, f"begin_{starter}")()
                self.assertEqual(
                    run_git(["branch", "--show-current"], cwd=self.repo).stdout.strip(),
                    "",
                )

                with self.assertRaisesRegex(
                    drain_prs_service.ServiceError, "is in progress"
                ):
                    self._start()


if __name__ == "__main__":
    unittest.main()
