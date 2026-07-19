"""Integration test for tools/drain_prs.py: one full happy-path drain cycle
(approved PR -> gates pass -> merge -> cleanup -> forget) against a real
temporary Git repository and a scriptable fake `gh`.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import drain_prs
import fake_cli


def run_git(args, *, cwd):
    proc = subprocess.run(
        ["git", *args],
        cwd=str(cwd),
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed in {cwd}:\n{proc.stdout}\n{proc.stderr}"
        )
    return proc.stdout.strip()


def git_ref_exists(repo_dir, ref):
    proc = subprocess.run(
        ["git", "show-ref", "--verify", "--quiet", ref],
        cwd=str(repo_dir),
        capture_output=True,
    )
    return proc.returncode == 0


class HappyPathDrainCycleTest(unittest.TestCase):
    """Exercises process_pr() end-to-end: an approved, green PR gets merged,
    its linked issue closed, its worktree/branches removed, and the local
    default branch fast-forwarded to the (simulated) merge commit GitHub
    produced -- with no real network access.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

        self.bare = self.root / "remote.git"
        self.main = self.root / "main"
        self.feature_wt = self.root / "wt-issue-99"
        self.upstream_sim = self.root / "upstream-sim"

        run_git(["init", "--bare", "-q", "-b", "master", str(self.bare)], cwd=self.root)
        run_git(["init", "-q", "-b", "master", str(self.main)], cwd=self.root)
        run_git(["config", "user.email", "test@example.com"], cwd=self.main)
        run_git(["config", "user.name", "Test"], cwd=self.main)
        (self.main / "README").write_text("hello\n", encoding="utf-8")
        run_git(["add", "README"], cwd=self.main)
        run_git(["commit", "-q", "-m", "initial commit"], cwd=self.main)
        run_git(["remote", "add", "origin", str(self.bare)], cwd=self.main)
        run_git(["push", "-q", "-u", "origin", "master"], cwd=self.main)

        run_git(
            ["worktree", "add", "-q", "-b", "issue-99-demo", str(self.feature_wt), "master"],
            cwd=self.main,
        )
        (self.feature_wt / "feature.txt").write_text("new feature\n", encoding="utf-8")
        run_git(["add", "feature.txt"], cwd=self.feature_wt)
        run_git(["commit", "-q", "-m", "add feature"], cwd=self.feature_wt)
        self.head_sha = run_git(["rev-parse", "HEAD"], cwd=self.feature_wt)
        run_git(["push", "-q", "origin", "issue-99-demo"], cwd=self.feature_wt)

        # Simulate GitHub performing the PR merge server-side, landing a new
        # commit on the bare remote's master ahead of what `self.main` has
        # locally -- so fast-forwarding is a real, observable effect.
        run_git(["clone", "-q", str(self.bare), str(self.upstream_sim)], cwd=self.root)
        run_git(["checkout", "-q", "master"], cwd=self.upstream_sim)
        run_git(
            ["merge", "-q", "--no-ff", "origin/issue-99-demo", "-m", "Merge pull request #42"],
            cwd=self.upstream_sim,
        )
        self.merge_commit_sha = run_git(["rev-parse", "HEAD"], cwd=self.upstream_sim)
        run_git(["push", "-q", "origin", "master"], cwd=self.upstream_sim)

        run_git(["remote", "set-head", "origin", "master"], cwd=self.main)

        # Point origin at a GitHub-shaped URL just long enough to exercise
        # the real get_repo_context()/parse_repo_slug() path, then swap back
        # to the local bare remote so the mutating git calls inside
        # process_pr() (fetch/push/ls-remote) never touch the network.
        run_git(
            ["remote", "set-url", "origin", "https://github.com/acme/widgets.git"],
            cwd=self.main,
        )
        self.ctx = drain_prs.get_repo_context(self.main)
        self.assertEqual(self.ctx.repo_slug, "acme/widgets")
        self.assertEqual(self.ctx.repo_name, "widgets")
        self.assertEqual(self.ctx.default_branch, "master")
        run_git(["remote", "set-url", "origin", str(self.bare)], cwd=self.main)

        self.fake = fake_cli.FakeCli(self.root / "fake-cli")
        self.fake.install("gh")

    def _script_pr_view(self):
        pr_json = {
            "number": 42,
            "title": "Add feature",
            "url": "https://github.com/acme/widgets/pull/42",
            "state": "OPEN",
            "isDraft": False,
            "labels": [{"name": drain_prs.APPROVE_LABEL}],
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "CLEAN",
            "headRefOid": self.head_sha,
            "headRefName": "issue-99-demo",
            "baseRefName": "master",
            "statusCheckRollup": [
                {
                    "name": drain_prs.DEFAULT_REQUIRED_CI_CHECK,
                    "status": "COMPLETED",
                    "conclusion": "SUCCESS",
                    "completedAt": "2026-07-18T00:00:00Z",
                },
                {
                    "name": drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
                    "status": "COMPLETED",
                    "conclusion": "SUCCESS",
                    "completedAt": "2026-07-18T00:00:01Z",
                },
            ],
            "closingIssuesReferences": [
                {
                    "number": 99,
                    "repository": {"owner": {"login": "acme"}, "name": "widgets"},
                }
            ],
        }
        self.fake.script("gh", ["pr", "view", "42"], stdout=json.dumps(pr_json))

    def _run_process_pr(self):
        state = {
            "version": drain_prs.STATE_VERSION,
            "attempt_counter": 3,
            "prs": {
                "42": {
                    "approved_head": self.head_sha,
                    "last_rereviewed_head": None,
                    "consecutive_failures": 0,
                    "retry_after_attempt": 0,
                    "last_attempt": 2,
                    "last_error": None,
                }
            },
        }
        env_overrides = self.fake.environ_overrides()
        with mock.patch.dict(os.environ, env_overrides):
            result = drain_prs.process_pr(
                self.ctx,
                42,
                dry_run=False,
                repair_conflicts=True,
                state=state,
                gates=drain_prs.GateConfig(
                    required_ci_check=drain_prs.DEFAULT_REQUIRED_CI_CHECK,
                    required_review_check=drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
                ),
            )
        return result, state

    def test_happy_path_merges_cleans_up_and_forgets(self):
        self._script_pr_view()
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

        result, state = self._run_process_pr()

        self.assertTrue(result)

        merge_calls = [
            call
            for call in self.fake.calls("gh")
            if call["args"][:3] == ["pr", "merge", "42"]
        ]
        self.assertEqual(len(merge_calls), 1)
        self.assertIn("--match-head-commit", merge_calls[0]["args"])
        self.assertIn(self.head_sha, merge_calls[0]["args"])

        close_calls = [
            call
            for call in self.fake.calls("gh")
            if call["args"][:3] == ["issue", "close", "99"]
        ]
        self.assertEqual(len(close_calls), 1)

        self.assertNotIn("42", state["prs"])

        self.assertFalse(self.feature_wt.exists())
        self.assertFalse(git_ref_exists(self.main, "refs/heads/issue-99-demo"))
        self.assertFalse(git_ref_exists(self.bare, "refs/heads/issue-99-demo"))

        self.assertEqual(
            run_git(["rev-parse", "master"], cwd=self.main), self.merge_commit_sha
        )


class WorktreeMatchingSafetyTests(unittest.TestCase):
    """Regression coverage for issue #24: directory-basename scoring alone
    must never positively identify a worktree for deletion or sandbox-
    bypassed reuse -- only an exact branch match, or (for a detached
    worktree, independent of its name) an exact PR-head SHA match, may.
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
        (self.main / "README").write_text("hello\n", encoding="utf-8")
        run_git(["add", "README"], cwd=self.main)
        run_git(["commit", "-q", "-m", "initial commit"], cwd=self.main)
        self.base_sha = run_git(["rev-parse", "HEAD"], cwd=self.main)
        run_git(["remote", "add", "origin", str(self.bare)], cwd=self.main)
        run_git(["push", "-q", "-u", "origin", "master"], cwd=self.main)

        feature_wt = self.root / "wt-issue-42"
        run_git(
            ["worktree", "add", "-q", "-b", "issue-42-feature", str(feature_wt), "master"],
            cwd=self.main,
        )
        (feature_wt / "feature.txt").write_text("new feature\n", encoding="utf-8")
        run_git(["add", "feature.txt"], cwd=feature_wt)
        run_git(["commit", "-q", "-m", "add feature"], cwd=feature_wt)
        self.head_sha = run_git(["rev-parse", "HEAD"], cwd=feature_wt)
        run_git(["push", "-q", "origin", "issue-42-feature"], cwd=feature_wt)
        run_git(["worktree", "remove", str(feature_wt)], cwd=self.main)
        run_git(["remote", "set-head", "origin", "master"], cwd=self.main)

        run_git(
            ["remote", "set-url", "origin", "https://github.com/acme/widgets.git"],
            cwd=self.main,
        )
        self.ctx = drain_prs.get_repo_context(self.main)
        run_git(["remote", "set-url", "origin", str(self.bare)], cwd=self.main)

        self.pr = {
            "number": 42,
            "headRefName": "issue-42-feature",
            "headRefOid": self.head_sha,
            "closingIssuesReferences": [],
        }

    def test_unrelated_named_worktree_not_deleted_or_reused_but_cleanup_continues(self):
        experiment_wt = self.root / "experiment-42"
        run_git(
            ["worktree", "add", "-q", "-b", "experiment-branch", str(experiment_wt), "master"],
            cwd=self.main,
        )

        self.assertIsNone(drain_prs.find_matching_worktree(self.ctx, self.pr))

        reused_path, created_new = drain_prs.prepare_review_worktree(self.ctx, self.pr)

        def _cleanup_reused_path():
            if reused_path.exists():
                run_git(["worktree", "remove", "--force", str(reused_path)], cwd=self.main)

        self.addCleanup(_cleanup_reused_path)
        self.assertTrue(created_new)
        self.assertNotEqual(reused_path.resolve(), experiment_wt.resolve())

        # The temporary review worktree is genuinely at the PR head, so it is
        # itself a legitimate exact-detached-HEAD match and gets swept up by
        # cleanup below -- that is correct, not a leak.
        drain_prs.cleanup_after_merge(self.ctx, self.pr, dry_run=False)

        # Unrelated worktree is left untouched...
        self.assertTrue(experiment_wt.exists())
        # ...but the rest of cleanup still ran despite the skipped match.
        self.assertFalse(git_ref_exists(self.main, "refs/heads/issue-42-feature"))
        self.assertFalse(git_ref_exists(self.bare, "refs/heads/issue-42-feature"))

    def test_detached_worktree_at_pr_head_is_matched_and_deleted(self):
        detached_wt = self.root / "detached-head"
        run_git(
            ["worktree", "add", "-q", "--detach", str(detached_wt), self.head_sha],
            cwd=self.main,
        )

        self.assertEqual(
            drain_prs.find_matching_worktree(self.ctx, self.pr), detached_wt.resolve()
        )

        drain_prs.cleanup_after_merge(self.ctx, self.pr, dry_run=False)

        self.assertFalse(detached_wt.exists())

    def test_detached_worktree_at_common_ancestor_is_not_matched(self):
        detached_wt = self.root / "detached-ancestor"
        run_git(
            ["worktree", "add", "-q", "--detach", str(detached_wt), self.base_sha],
            cwd=self.main,
        )

        self.assertIsNone(drain_prs.find_matching_worktree(self.ctx, self.pr))

        drain_prs.cleanup_after_merge(self.ctx, self.pr, dry_run=False)

        self.assertTrue(detached_wt.exists())


if __name__ == "__main__":
    unittest.main()
