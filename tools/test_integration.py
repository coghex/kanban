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


class ProcessPrFixture(unittest.TestCase):
    """Shared scaffolding for process_pr()/loop() tests: a real temporary Git
    repository plus a scriptable fake `gh`, with no real network access.
    """

    def setUp(self):
        self._build_fixture()

    def _build_fixture(self):
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
        run_git(["config", "user.email", "test@example.com"], cwd=self.upstream_sim)
        run_git(["config", "user.name", "Test"], cwd=self.upstream_sim)
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

    def _base_pr_json(self):
        return {
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

    def _script_pr_view(self, *overrides):
        # Each positional override scripts one queued `gh pr view 42`
        # response, consumed in order by successive calls (see fake_cli's
        # ordered-response queue) -- this is how a scenario gives different
        # snapshots to process_pr()'s penultimate, final, and (once merged)
        # post-merge audit reads. With no overrides, one default green
        # response is scripted and reused for every call.
        if not overrides:
            overrides = ({},)
        for override in overrides:
            pr_json = self._base_pr_json()
            pr_json.update(override)
            self.fake.script("gh", ["pr", "view", "42"], stdout=json.dumps(pr_json))

    def _pr_view_calls(self):
        return [
            call for call in self.fake.calls("gh") if call["args"][:2] == ["pr", "view"]
        ]

    def _pr_merge_calls(self):
        return [
            call for call in self.fake.calls("gh") if call["args"][:2] == ["pr", "merge"]
        ]

    def _run_process_pr(self, *, dry_run=False, gates=None):
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
        if gates is None:
            gates = drain_prs.GateConfig(
                required_ci_check=drain_prs.DEFAULT_REQUIRED_CI_CHECK,
                required_review_check=drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
            )
        env_overrides = self.fake.environ_overrides()
        with mock.patch.dict(os.environ, env_overrides):
            result = drain_prs.process_pr(
                self.ctx,
                42,
                dry_run=dry_run,
                repair_conflicts=True,
                state=state,
                gates=gates,
            )
        return result, state


class HappyPathDrainCycleTest(ProcessPrFixture):
    """Exercises process_pr() end-to-end: an approved, green PR gets merged,
    its linked issue closed, its worktree/branches removed, and the local
    default branch fast-forwarded to the (simulated) merge commit GitHub
    produced -- with no real network access.
    """

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

        # Penultimate read, final gate re-check, and exactly one post-merge
        # audit read -- a clean merge costs at most one extra `gh pr view`.
        self.assertEqual(len(self._pr_view_calls()), 3)

    def test_dry_run_performs_no_merge_or_post_merge_audit_read(self):
        self._script_pr_view({"closingIssuesReferences": []})

        result, state = self._run_process_pr(dry_run=True)

        self.assertTrue(result)
        self.assertEqual(len(self._pr_merge_calls()), 0)
        # Only the penultimate and final gate reads -- no merge happened, so
        # there is nothing for a post-merge audit to sample.
        self.assertEqual(len(self._pr_view_calls()), 2)
        self.assertIn("42", state["prs"])


class FinalGateAndPostMergeAuditTest(ProcessPrFixture):
    """Covers issue #28: the final pre-merge gate re-check and the
    post-merge audit that catches whatever still slips through the
    read-to-merge gap.
    """

    def test_approval_withdrawn_between_penultimate_and_final_read_defers(self):
        self._script_pr_view({}, {"labels": []})

        result, state = self._run_process_pr()

        self.assertTrue(result)
        self.assertEqual(len(self._pr_merge_calls()), 0)
        self.assertIn("42", state["prs"])

    def test_post_merge_audit_detects_missing_approve_label(self):
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self._script_pr_view({}, {}, {"labels": []})

        with self.assertRaises(drain_prs.PostMergeAuditError) as raised:
            self._run_process_pr()

        message = str(raised.exception)
        self.assertIn("42", message)
        self.assertIn(self.head_sha, message)
        self.assertIn(drain_prs.APPROVE_LABEL, message)
        self.assertEqual(len(self._pr_view_calls()), 3)

    def test_post_merge_audit_detects_changes_requested_label(self):
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self._script_pr_view(
            {},
            {},
            {
                "labels": [
                    {"name": drain_prs.APPROVE_LABEL},
                    {"name": drain_prs.CHANGES_LABEL},
                ]
            },
        )

        with self.assertRaises(drain_prs.PostMergeAuditError) as raised:
            self._run_process_pr()

        self.assertIn(drain_prs.CHANGES_LABEL, str(raised.exception))

    def test_post_merge_audit_detects_head_mismatch(self):
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        other_sha = "f" * 40
        self._script_pr_view({}, {}, {"headRefOid": other_sha})

        with self.assertRaises(drain_prs.PostMergeAuditError) as raised:
            self._run_process_pr()

        message = str(raised.exception)
        self.assertIn(self.head_sha, message)
        self.assertIn(other_sha, message)

    def test_post_merge_audit_detects_required_check_regressions(self):
        # configured_check_state()/classify_check() only ever produce three
        # non-success classes (missing, pending, failure -- the latter also
        # covering SKIPPED/CANCELLED conclusions), so those three cover the
        # space regardless of which of the two configured checks regresses.
        names = {
            "ci": drain_prs.DEFAULT_REQUIRED_CI_CHECK,
            "review": drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
        }
        green = {
            "status": "COMPLETED",
            "conclusion": "SUCCESS",
            "completedAt": "2026-07-18T00:00:01Z",
        }
        violations = {
            "missing": None,
            "pending": {"status": "IN_PROGRESS"},
            "failure": {"status": "COMPLETED", "conclusion": "FAILURE"},
        }
        for kind, check_name in names.items():
            other_kind = "review" if kind == "ci" else "ci"
            other_entry = {"name": names[other_kind], **green}
            for violation, entry_overrides in violations.items():
                with self.subTest(kind=kind, violation=violation):
                    self._build_fixture()
                    rollup = [other_entry]
                    if entry_overrides is not None:
                        rollup.append({"name": check_name, **entry_overrides})
                    self.fake.script("gh", ["pr", "merge", "42"], stdout="")
                    self._script_pr_view(
                        {}, {}, {"statusCheckRollup": rollup}
                    )

                    with self.assertRaises(drain_prs.PostMergeAuditError) as raised:
                        self._run_process_pr()

                    self.assertIn(check_name, str(raised.exception))

    def test_post_merge_audit_allows_a_disabled_check(self):
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")
        self._script_pr_view(
            {},
            {},
            {
                "statusCheckRollup": [
                    {
                        "name": drain_prs.DEFAULT_REQUIRED_CI_CHECK,
                        "status": "COMPLETED",
                        "conclusion": "SUCCESS",
                        "completedAt": "2026-07-18T00:00:00Z",
                    }
                ]
            },
        )
        gates = drain_prs.GateConfig(
            required_ci_check=drain_prs.DEFAULT_REQUIRED_CI_CHECK,
            required_review_check=None,
        )

        result, state = self._run_process_pr(gates=gates)

        self.assertTrue(result)
        self.assertNotIn("42", state["prs"])

    def test_post_merge_audit_read_failure_is_fatal(self):
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self._script_pr_view({}, {})
        self.fake.script(
            "gh", ["pr", "view", "42"], stderr="boom", exit_code=1
        )

        with self.assertRaises(drain_prs.PostMergeAuditError) as raised:
            self._run_process_pr()

        self.assertIn("boom", str(raised.exception))

    def test_post_merge_audit_error_stops_the_loop_instead_of_retrying(self):
        self.fake.script(
            "gh",
            ["pr", "list"],
            stdout=json.dumps(
                [
                    {
                        "number": 42,
                        "labels": [{"name": drain_prs.APPROVE_LABEL}],
                        "isDraft": False,
                        "headRefOid": self.head_sha,
                    }
                ]
            ),
        )
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self._script_pr_view({}, {}, {"labels": []})
        gates = drain_prs.GateConfig(
            required_ci_check=drain_prs.DEFAULT_REQUIRED_CI_CHECK,
            required_review_check=drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
        )

        env_overrides = self.fake.environ_overrides()
        with mock.patch.dict(os.environ, env_overrides):
            with self.assertRaises(drain_prs.PostMergeAuditError):
                drain_prs.loop(
                    self.ctx,
                    interval=0,
                    once=True,
                    dry_run=False,
                    repair_conflicts=True,
                    gates=gates,
                )


class WorktreeFixture(unittest.TestCase):
    """Shared scaffolding for worktree-selection tests: a real temporary Git
    repository whose PR #42 head lives on a pushed `issue-42-feature` branch,
    with no worktree checked out on it.
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


class WorktreeMatchingSafetyTests(WorktreeFixture):
    """Regression coverage for issue #24: directory-basename scoring alone
    must never positively identify a worktree for deletion or sandbox-
    bypassed reuse -- only an exact branch match, or (for a detached
    worktree, independent of its name) an exact PR-head SHA match, may.
    """

    def test_unrelated_named_worktree_not_deleted_or_reused_but_cleanup_continues(self):
        experiment_wt = self.root / "experiment-42"
        run_git(
            ["worktree", "add", "-q", "-b", "experiment-branch", str(experiment_wt), "master"],
            cwd=self.main,
        )

        self.assertIsNone(drain_prs.find_matching_worktree(self.ctx, self.pr))

        review_path = drain_prs.prepare_review_worktree(self.ctx, self.pr)

        def _cleanup_review_path():
            if review_path.exists():
                run_git(["worktree", "remove", "--force", str(review_path)], cwd=self.main)

        self.addCleanup(_cleanup_review_path)
        self.assertNotEqual(review_path.resolve(), experiment_wt.resolve())

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

    def test_commit_exists_locally_true_for_known_commit(self):
        self.assertTrue(drain_prs.commit_exists_locally(self.ctx, self.head_sha))

    def test_commit_exists_locally_false_for_unknown_sha(self):
        self.assertFalse(drain_prs.commit_exists_locally(self.ctx, "f" * 40))

    def test_pr_head_oid_unresolvable_locally_is_not_trusted_for_detached_match(self):
        # A worktree's real HEAD equals the PR's headRefOid exactly, but the
        # PR head commit is (simulated as) unavailable in the local object
        # database -- per the approved amendment this must not be trusted as
        # positive identification, even though the SHA strings match.
        detached_wt = self.root / "detached-head"
        run_git(
            ["worktree", "add", "-q", "--detach", str(detached_wt), self.head_sha],
            cwd=self.main,
        )

        with mock.patch.object(drain_prs, "commit_exists_locally", return_value=False):
            result = drain_prs.find_matching_worktree(self.ctx, self.pr)

        self.assertIsNone(result)


class StaleHeadRereviewIsolationTests(WorktreeFixture):
    """Regression coverage for issue #26: the stale-head rereviewer runs Codex
    with approvals and the sandbox bypassed, so it must always get its own
    temporary worktree, verified clean and at the exact head under review
    before the agent launches, and removed afterwards in every outcome.
    """

    def setUp(self):
        super().setUp()
        self.fake = fake_cli.FakeCli(self.root / "fake-cli")
        self.fake.install("gh")
        self.fake.install("codex")
        self.prepared = []

    def _recording_prepare(self, *, tamper=None):
        real_prepare = drain_prs.prepare_review_worktree

        def prepare(ctx, pr):
            path = real_prepare(ctx, pr)
            self.addCleanup(self._force_remove, path)
            head = run_git(["rev-parse", "HEAD"], cwd=path)
            self.prepared.append((path, head))
            if tamper is not None:
                tamper(path)
            return path

        return mock.patch.object(drain_prs, "prepare_review_worktree", prepare)

    def _force_remove(self, path):
        if path.exists():
            run_git(["worktree", "remove", "--force", str(path)], cwd=self.main)

    def _script_approving_rereview(self):
        pr_json = dict(self.pr, labels=[{"name": drain_prs.APPROVE_LABEL}])
        # Both `gh pr view 42` reads share a match prefix, so they are served
        # in order: get_pr() first, then latest_review_marker()'s comments.
        self.fake.script("gh", ["pr", "view", "42"], stdout=json.dumps(pr_json))
        self.fake.script(
            "gh",
            ["pr", "view", "42"],
            stdout=json.dumps(
                {
                    "comments": [
                        {
                            "createdAt": "2026-07-20T00:00:00Z",
                            "body": (
                                "<!-- pr-review:v1 reviewer=codex "
                                f"head={self.head_sha} verdict=APPROVE -->"
                            ),
                        }
                    ]
                }
            ),
        )
        self.fake.script("codex", ["exec"], stdout="")

    def _codex_calls(self):
        return self.fake.calls("codex")

    def _rereview(self):
        with mock.patch.dict(os.environ, self.fake.environ_overrides()):
            return drain_prs.rereview_pr_with_codex(self.ctx, self.pr, dry_run=False)

    def test_matched_dirty_stale_worktree_is_not_reused_and_is_left_untouched(self):
        # An interrupted solve: a live worktree on the PR's branch, sitting
        # behind the pushed head with uncommitted work in the tree.
        live_wt = self.root / "issue-42-live"
        run_git(["worktree", "add", "-q", str(live_wt), "issue-42-feature"], cwd=self.main)
        run_git(["reset", "--hard", "-q", self.base_sha], cwd=live_wt)
        (live_wt / "README").write_text("half-finished edit\n", encoding="utf-8")
        (live_wt / "scratch.txt").write_text("uncommitted work\n", encoding="utf-8")

        # It is an exact branch match, so the old reuse path would have handed
        # this very worktree to sandbox-bypassed Codex.
        self.assertEqual(
            drain_prs.find_matching_worktree(self.ctx, self.pr), live_wt.resolve()
        )

        self._script_approving_rereview()
        with self._recording_prepare():
            refreshed = self._rereview()

        self.assertEqual(refreshed["headRefOid"], self.head_sha)

        self.assertEqual(len(self.prepared), 1)
        review_path, prepared_head = self.prepared[0]
        self.assertNotEqual(review_path.resolve(), live_wt.resolve())
        self.assertEqual(prepared_head, self.head_sha)

        codex_calls = self._codex_calls()
        self.assertEqual(len(codex_calls), 1)
        args = codex_calls[0]["args"]
        self.assertEqual(args[args.index("-C") + 1], str(review_path))

        # The temporary worktree is gone; the live one is exactly as it was.
        self.assertFalse(review_path.exists())
        self.assertTrue(live_wt.exists())
        self.assertEqual(run_git(["rev-parse", "HEAD"], cwd=live_wt), self.base_sha)
        self.assertEqual(
            (live_wt / "README").read_text(encoding="utf-8"), "half-finished edit\n"
        )
        self.assertEqual(
            (live_wt / "scratch.txt").read_text(encoding="utf-8"), "uncommitted work\n"
        )

    def test_review_worktree_at_wrong_head_fails_before_codex_and_is_removed(self):
        # The remote branch moves after the drainer captured the PR head, so
        # the fresh temporary worktree lands on a commit that is not under
        # review.
        mover = self.root / "mover"
        run_git(
            ["clone", "-q", "-b", "issue-42-feature", str(self.bare), str(mover)],
            cwd=self.root,
        )
        run_git(["config", "user.email", "test@example.com"], cwd=mover)
        run_git(["config", "user.name", "Test"], cwd=mover)
        (mover / "later.txt").write_text("pushed after the PR read\n", encoding="utf-8")
        run_git(["add", "later.txt"], cwd=mover)
        run_git(["commit", "-q", "-m", "later push"], cwd=mover)
        moved_sha = run_git(["rev-parse", "HEAD"], cwd=mover)
        run_git(["push", "-q", "origin", "issue-42-feature"], cwd=mover)
        self.assertNotEqual(moved_sha, self.head_sha)

        self._script_approving_rereview()
        with self._recording_prepare():
            with self.assertRaises(drain_prs.DrainError) as caught:
                self._rereview()

        message = str(caught.exception)
        self.assertIn(moved_sha[:12], message)
        self.assertIn(self.head_sha[:12], message)
        self.assertIn("did not match expected PR head", message)

        self.assertEqual(self._codex_calls(), [])
        self.assertEqual(len(self.prepared), 1)
        review_path, _ = self.prepared[0]
        self.assertFalse(review_path.exists())

    def test_dirty_review_worktree_fails_before_codex_and_is_removed(self):
        def dirty(path):
            (path / "README").write_text("stray edit\n", encoding="utf-8")
            (path / "untracked.txt").write_text("stray file\n", encoding="utf-8")

        self._script_approving_rereview()
        with self._recording_prepare(tamper=dirty):
            with self.assertRaises(drain_prs.DrainError) as caught:
                self._rereview()

        message = str(caught.exception)
        self.assertIn("was dirty", message)
        self.assertIn("README", message)
        self.assertIn("untracked.txt", message)

        self.assertEqual(self._codex_calls(), [])
        self.assertEqual(len(self.prepared), 1)
        review_path, _ = self.prepared[0]
        self.assertFalse(review_path.exists())


if __name__ == "__main__":
    unittest.main()
