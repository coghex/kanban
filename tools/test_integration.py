"""Integration test for tools/drain_prs.py: one full happy-path drain cycle
(approved PR -> gates pass -> merge -> cleanup -> forget) against a real
temporary Git repository and a scriptable fake `gh`.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

import contextlib
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import drain_prs
import drain_prs_service
import fake_cli


# The paginated comment feed drain_prs reads for pr-review markers, for the
# `acme/widgets` slug every fixture here installs.
COMMENTS_ENDPOINT = "repos/acme/widgets/issues/42/comments?per_page=100"


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

    def _run_process_pr(self, *, dry_run=False, gates=None, report=None):
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
                    "cleanup": None,
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
                state=state,
                gates=gates,
                report=report,
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
                    gates=gates,
                )


class CoordinationOnlyBaseAdvanceTests(ProcessPrFixture):
    """Covers issue #224: a candidate that is only BEHIND because the default
    branch gained a configured coordination path is evaluated in the same pass
    instead of being sent through a branch update that rebuilds it on a base
    that cannot change its result.

    Every scenario below asserts one of two things: the exception applied and
    the ordinary gates then decided, or the ordinary branch update was
    requested exactly as it always is. Nothing here may invent a third
    outcome, and nothing here may merge on the strength of the exception
    alone.
    """

    MERGE_BASE = "b" * 40
    MOVED_TIP = "e" * 40
    COORDINATION_PATH = "docs/status.md"

    def setUp(self):
        super().setUp()
        self._configure({self.COORDINATION_PATH})
        # The swap is a real `git fetch` and a real
        # `git push --force-with-lease` against the fixture's own remote, so
        # every commit it names has to be a real one. Rebuild the remote's
        # history as the scenario actually describes it: a default branch that
        # advanced by one coordination-only push, and a merge of this pull
        # request onto exactly that commit, staged but not landed.
        self.ANCESTOR = run_git(
            ["rev-parse", f"{self.merge_commit_sha}^1"], cwd=self.upstream_sim
        )
        run_git(["checkout", "-q", "-B", "staging", self.ANCESTOR], cwd=self.upstream_sim)
        (self.upstream_sim / "docs").mkdir(exist_ok=True)
        (self.upstream_sim / "docs" / "status.md").write_text(
            "coordination\n", encoding="utf-8"
        )
        run_git(["add", self.COORDINATION_PATH], cwd=self.upstream_sim)
        run_git(["commit", "-q", "-m", "a coordination push"], cwd=self.upstream_sim)
        self.TIP = run_git(["rev-parse", "HEAD"], cwd=self.upstream_sim)
        run_git(
            [
                "merge",
                "-q",
                "--no-ff",
                "origin/issue-99-demo",
                "-m",
                "Merge pull request #42",
            ],
            cwd=self.upstream_sim,
        )
        self.MERGE_COMMIT = run_git(["rev-parse", "HEAD"], cwd=self.upstream_sim)
        run_git(
            ["push", "-q", "-f", "origin", f"{self.TIP}:refs/heads/master"],
            cwd=self.upstream_sim,
        )
        run_git(
            [
                "push",
                "-q",
                "-f",
                "origin",
                f"{self.MERGE_COMMIT}:refs/heads/{self.STAGING_REF}",
            ],
            cwd=self.upstream_sim,
        )

    def _remote_default_branch(self):
        return run_git(["rev-parse", "master"], cwd=self.bare)

    def _advance_remote_default_branch(self):
        """A push to the remote's default branch that beats the drainer's."""
        run_git(["checkout", "-q", "-B", "advance", self.TIP], cwd=self.upstream_sim)
        (self.upstream_sim / "unrelated.txt").write_text("later\n", encoding="utf-8")
        run_git(["add", "unrelated.txt"], cwd=self.upstream_sim)
        run_git(["commit", "-q", "-m", "a later push"], cwd=self.upstream_sim)
        run_git(["push", "-q", "-f", "origin", "advance:master"], cwd=self.upstream_sim)
        return run_git(["rev-parse", "master"], cwd=self.bare)

    def _configure(self, paths):
        patch = mock.patch.object(
            drain_prs, "COORDINATION_PATHS", frozenset(paths)
        )
        patch.start()
        self.addCleanup(patch.stop)

    # -- scripting -------------------------------------------------------

    def _script_tip(self, *tips, exit_code=0):
        """One `gh api .../git/ref/heads/master` response per read, in order."""
        for tip in tips:
            self.fake.script(
                "gh",
                ["api", "repos/acme/widgets/git/ref/heads/master"],
                stdout=json.dumps({"object": {"sha": tip}}),
                exit_code=exit_code,
            )

    def _script_compare(self, base, head, payload, *, exit_code=0):
        self.fake.script(
            "gh",
            ["api", f"repos/acme/widgets/compare/{base}...{head}"],
            stdout=json.dumps(payload) if payload is not None else "",
            exit_code=exit_code,
        )

    def _comparison(self, files, merge_base=None):
        return {
            "merge_base_commit": {"sha": merge_base or self.MERGE_BASE},
            "files": files,
        }

    def _script_file_sets(self, *, advanced, own=None, tip=None, merge_base=None):
        """The two comparisons eligibility is computed from: what the default
        branch gained since the merge base, and what the pull request itself
        changes."""
        self._script_compare(
            self.head_sha,
            tip or self.TIP,
            self._comparison(advanced, merge_base=merge_base),
        )
        self._script_compare(
            merge_base or self.MERGE_BASE,
            self.head_sha,
            self._comparison(
                own if own is not None else [{"filename": "feature.txt"}],
                merge_base=merge_base,
            ),
        )

    def _script_update_branch(self):
        self.fake.script(
            "gh",
            ["api", "-X", "PUT", "repos/acme/widgets/pulls/42/update-branch"],
            stdout="",
        )

    STAGING_REF = "kanban-drainer/merge-42"

    def _script_staging_ref(self, *, created=True):
        self.fake.script(
            "gh",
            ["api", "-X", "DELETE", f"repos/acme/widgets/git/refs/heads/{self.STAGING_REF}"],
            stdout="",
        )
        self.fake.script(
            "gh",
            ["api", "-X", "POST", "repos/acme/widgets/git/refs"],
            stdout=json.dumps({"ref": f"refs/heads/{self.STAGING_REF}"}),
            stderr="" if created else "Reference already exists",
            exit_code=0 if created else 1,
        )

    def _script_build_merge(self, *, parents=None, exit_code=0, stdout=None):
        """The merge commit GitHub builds on the staging reference."""
        if stdout is None:
            stdout = json.dumps(
                {
                    "sha": self.MERGE_COMMIT,
                    "parents": (
                        parents
                        if parents is not None
                        else [{"sha": self.TIP}, {"sha": self.head_sha}]
                    ),
                }
            )
        self.fake.script(
            "gh",
            ["api", "-X", "POST", "repos/acme/widgets/merges"],
            stdout=stdout,
            stderr="Merge conflict" if exit_code else "",
            exit_code=exit_code,
        )

    def _script_merge_of_this_pr(self, *, parents=None, build_exit=0):
        # There is nothing to script for the swap itself: it is a real
        # `git fetch` and a real leased `git push` against the fixture's remote.
        self._script_staging_ref()
        self._script_build_merge(parents=parents, exit_code=build_exit)
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

    def _swapped(self):
        """Whether the drainer's own merge commit reached the remote."""
        return self._remote_default_branch() == self.MERGE_COMMIT

    def _staging_ref_deletions(self):
        return [
            call
            for call in self.fake.calls("gh")
            if call["args"][:4]
            == [
                "api",
                "-X",
                "DELETE",
                f"repos/acme/widgets/git/refs/heads/{self.STAGING_REF}",
            ]
        ]

    def _stale_approval_ok(self):
        return self._base_pr_json()["statusCheckRollup"] + [
            {
                "name": drain_prs.STALE_APPROVAL_CHECK,
                "status": "COMPLETED",
                "conclusion": "SUCCESS",
                "completedAt": "2026-07-18T00:00:02Z",
            }
        ]

    def _settled(self):
        """The snapshot the branch update leaves behind: a new head whose
        stale-approval decision has landed."""
        return {
            "headRefOid": "c" * 40,
            "statusCheckRollup": self._stale_approval_ok(),
        }

    def _behind(self, **overrides):
        snapshot = {"mergeStateStatus": "BEHIND"}
        snapshot.update(overrides)
        return snapshot

    # -- inspection ------------------------------------------------------

    def _update_branch_calls(self):
        return [
            call
            for call in self.fake.calls("gh")
            if call["args"][:1] == ["api"]
            and any("update-branch" in arg for arg in call["args"])
        ]

    def _comparison_calls(self):
        return [
            call
            for call in self.fake.calls("gh")
            if call["args"][:1] == ["api"]
            and any("/compare/" in arg for arg in call["args"])
        ]

    def _run(self, *, dry_run=False):
        report = drain_prs.new_single_pr_report(42)
        result, state = self._run_process_pr(dry_run=dry_run, report=report)
        return result, state, report

    def _assert_requested_the_update(self, report, state, *, fragment=None):
        self.assertEqual(len(self._update_branch_calls()), 1)
        self.assertEqual(len(self._pr_merge_calls()), 0)
        self.assertEqual(report["reason"], "behind_base")
        self.assertFalse(report["merged"])
        if fragment is not None:
            self.assertIn(fragment, report["message"])
        # Requirement 6: an update holds the active lane exactly as it always
        # has, so the candidate is examined first once it settles.
        self.assertEqual(
            drain_prs.classify_pass_outcome(report["reason"], raised=False),
            drain_prs.PASS_ADVANCE_HOLD,
        )
        self.assertEqual(state["prs"]["42"]["approved_head"], "c" * 40)

    # -- the exception itself --------------------------------------------

    def test_a_coordination_only_advance_merges_without_a_branch_update(self):
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(), {"state": "MERGED"}
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertEqual(len(self._update_branch_calls()), 0)
        self.assertTrue(self._swapped())
        self.assertEqual(report["reason"], "merged")
        self.assertTrue(report["merged"])
        # The linked issue was closed and the worktree cleaned up, exactly as
        # any other merge cleans up.
        self.assertNotIn("42", state["prs"])
        self.assertFalse(self.feature_wt.exists())

    def test_a_coordination_only_advance_still_waits_on_its_required_checks(self):
        # Requirement 3: reaching the gate evaluation grants nothing.
        self._script_pr_view(
            self._behind(
                statusCheckRollup=[
                    {
                        "name": drain_prs.DEFAULT_REQUIRED_CI_CHECK,
                        "status": "IN_PROGRESS",
                        "conclusion": None,
                        "startedAt": "2026-07-18T00:00:00Z",
                    },
                    {
                        "name": drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
                        "status": "COMPLETED",
                        "conclusion": "SUCCESS",
                        "completedAt": "2026-07-18T00:00:01Z",
                    },
                ]
            )
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertEqual(len(self._pr_merge_calls()), 0)
        self.assertEqual(len(self._update_branch_calls()), 0)
        self.assertEqual(report["reason"], "checks_pending")

    def test_a_dry_run_reports_the_merge_it_would_make(self):
        self._script_pr_view(self._behind(closingIssuesReferences=[]))
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])

        result, state, report = self._run(dry_run=True)

        self.assertTrue(result)
        self.assertEqual(len(self._pr_merge_calls()), 0)
        self.assertEqual(len(self._update_branch_calls()), 0)
        self.assertEqual(report["reason"], "would_merge")
        self.assertIn("42", state["prs"])

    # -- everything else requests the update ------------------------------

    def test_an_unset_key_requests_the_update_without_inspecting_anything(self):
        self._configure(set())
        self._script_pr_view(self._behind(), self._settled())
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self._assert_requested_the_update(report, state)
        # Requirement 4: an empty set is today's drainer, so it costs not one
        # extra GitHub call.
        self.assertEqual(self._comparison_calls(), [])

    def test_a_delta_outside_the_configured_set_requests_the_update(self):
        self._script_pr_view(self._behind(), self._settled())
        self._script_tip(self.TIP)
        self._script_file_sets(
            advanced=[
                {"filename": self.COORDINATION_PATH},
                {"filename": "src/Kanban/UI.hs"},
            ]
        )
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self._assert_requested_the_update(report, state)

    def test_a_delta_overlapping_the_pull_requests_own_files_requests_the_update(self):
        self._script_pr_view(self._behind(), self._settled())
        self._script_tip(self.TIP)
        self._script_file_sets(
            advanced=[{"filename": self.COORDINATION_PATH}],
            own=[{"filename": "feature.txt"}, {"filename": self.COORDINATION_PATH}],
        )
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self._assert_requested_the_update(report, state)

    def test_a_rename_out_of_the_configured_set_requests_the_update(self):
        # Only the destination is configured, so the source is a path nobody
        # declared inert -- both endpoints have to be matched.
        self._script_pr_view(self._behind(), self._settled())
        self._script_tip(self.TIP)
        self._script_file_sets(
            advanced=[
                {
                    "filename": self.COORDINATION_PATH,
                    "previous_filename": "docs/old-status.md",
                    "status": "renamed",
                }
            ]
        )
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self._assert_requested_the_update(report, state)

    def test_a_rename_between_two_configured_paths_still_merges(self):
        self._configure({self.COORDINATION_PATH, "docs/old-status.md"})
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(), {"state": "MERGED"}
        )
        self._script_tip(self.TIP)
        self._script_file_sets(
            advanced=[
                {
                    "filename": self.COORDINATION_PATH,
                    "previous_filename": "docs/old-status.md",
                    "status": "renamed",
                }
            ]
        )
        self._script_merge_of_this_pr()

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertTrue(self._swapped())
        self.assertEqual(report["reason"], "merged")

    def test_an_unreadable_default_tip_requests_the_update(self):
        self._script_pr_view(self._behind(), self._settled())
        self.fake.script(
            "gh",
            ["api", "repos/acme/widgets/git/ref/heads/master"],
            stderr="Not Found",
            exit_code=1,
        )
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self._assert_requested_the_update(report, state)
        self.assertEqual(self._comparison_calls(), [])

    def test_a_truncated_comparison_requests_the_update(self):
        # At GitHub's cap the file list cannot be proven complete, so a path
        # outside the configured set may simply not be in it.
        self._script_pr_view(self._behind(), self._settled())
        self._script_tip(self.TIP)
        self._script_compare(
            self.head_sha,
            self.TIP,
            self._comparison(
                [
                    {"filename": self.COORDINATION_PATH}
                    for _ in range(drain_prs.COMPARE_FILE_LIMIT)
                ]
            ),
        )
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self._assert_requested_the_update(report, state)

    def test_an_unavailable_own_file_list_requests_the_update(self):
        self._script_pr_view(self._behind(), self._settled())
        self._script_tip(self.TIP)
        self._script_compare(
            self.head_sha,
            self.TIP,
            self._comparison([{"filename": self.COORDINATION_PATH}]),
        )
        self._script_compare(
            self.MERGE_BASE, self.head_sha, None, exit_code=1
        )
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self._assert_requested_the_update(report, state)

    def test_a_malformed_comparison_requests_the_update(self):
        self._script_pr_view(self._behind(), self._settled())
        self._script_tip(self.TIP)
        self._script_compare(
            self.head_sha,
            self.TIP,
            {"merge_base_commit": {"sha": self.MERGE_BASE}, "files": "everything"},
        )
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self._assert_requested_the_update(report, state)

    def test_an_indeterminate_merge_base_requests_the_update(self):
        # Two comparisons that disagree about the merge base describe two
        # different histories; neither file set can be trusted against the
        # other.
        self._script_pr_view(self._behind(), self._settled())
        self._script_tip(self.TIP)
        self._script_compare(
            self.head_sha,
            self.TIP,
            self._comparison([{"filename": self.COORDINATION_PATH}]),
        )
        self._script_compare(
            self.MERGE_BASE,
            self.head_sha,
            self._comparison([{"filename": "feature.txt"}], merge_base="d" * 40),
        )
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self._assert_requested_the_update(report, state)

    def test_a_head_that_moved_after_the_inspection_merges_nothing(self):
        # The comparisons answered for one head; the gate re-read replaces the
        # snapshot with another. Merging then would land a head whose own
        # overlap with the base advance -- the whole point of the second
        # comparison -- was never inspected.
        self._script_pr_view(
            self._behind(),
            self._behind(headRefOid="f" * 40),
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertEqual(len(self._pr_merge_calls()), 0)
        self.assertEqual(len(self._update_branch_calls()), 0)
        self.assertEqual(report["reason"], "approved_head_changed")
        self.assertFalse(report["merged"])
        self.assertIn(self.head_sha[:12], report["message"])
        # A second tip read would mean the head pin came after the base pin;
        # the cheaper, more specific check has to come first.
        self.assertEqual(
            len(
                [
                    call
                    for call in self.fake.calls("gh")
                    if call["args"][:2]
                    == ["api", "repos/acme/widgets/git/ref/heads/master"]
                ]
            ),
            1,
        )

    def test_a_default_branch_that_moved_before_the_merge_requests_the_update(self):
        # The delta that was inspected belongs to one tip; an advance that
        # arrived since is one nothing has looked at.
        self._script_pr_view(self._behind(), self._behind(), self._settled())
        self._script_tip(self.TIP, self.MOVED_TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self._assert_requested_the_update(
            report, state, fragment="superseded before the merge"
        )

    # -- the atomic base guard --------------------------------------------

    def test_the_merge_is_built_on_the_inspected_tip_and_swapped_atomically(self):
        # GitHub's pull-request merge takes an expected head and no expected
        # base, so this path does not use it. The merge commit is built against
        # the inspected tip on a staging reference, and an unforced reference
        # update -- a compare-and-swap -- is what lands it.
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(), {"state": "MERGED"}
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertEqual(report["reason"], "merged")
        self.assertTrue(report["merged"])
        self.assertNotIn("42", state["prs"])
        # Nothing went through `gh pr merge`, which cannot express the base pin.
        self.assertEqual(len(self._pr_merge_calls()), 0)
        self.assertEqual(len(self._update_branch_calls()), 0)

        staged = [
            call
            for call in self.fake.calls("gh")
            if call["args"][:3] == ["api", "-X", "POST"]
            and call["args"][3] == "repos/acme/widgets/git/refs"
        ]
        self.assertEqual(len(staged), 1)
        self.assertIn(f"ref=refs/heads/{self.STAGING_REF}", staged[0]["args"])
        self.assertIn(f"sha={self.TIP}", staged[0]["args"])

        built = [
            call
            for call in self.fake.calls("gh")
            if call["args"][:4] == ["api", "-X", "POST", "repos/acme/widgets/merges"]
        ]
        self.assertEqual(len(built), 1)
        self.assertIn(f"base={self.STAGING_REF}", built[0]["args"])
        self.assertIn(f"head={self.head_sha}", built[0]["args"])

        # The swap really happened: the remote's default branch is now the
        # drainer's own merge commit, reached from the inspected tip.
        self.assertTrue(self._swapped())
        self.assertEqual(len(self._staging_ref_deletions()), 2)

    def test_a_default_branch_that_advanced_first_refuses_the_swap(self):
        # The case the whole guard exists for: the tip read said one thing and
        # the default branch moved before the swap. The lease refuses rather
        # than absorbing an advance nothing inspected.
        self._script_pr_view(
            self._behind(),
            self._behind(),
            self._behind(),
            self._behind(),
            self._settled(),
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()
        self._script_update_branch()
        advanced = self._advance_remote_default_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertFalse(self._swapped())
        # Untouched: the advance that beat the drainer is still what the
        # default branch points at.
        self.assertEqual(self._remote_default_branch(), advanced)
        self._assert_requested_the_update(
            report, state, fragment="no longer the inspected"
        )
        # Refused or not, the staging reference does not survive the attempt.
        self.assertEqual(len(self._staging_ref_deletions()), 2)

    def test_a_verdict_withdrawn_while_the_merge_is_staged_lands_nothing(self):
        # Building the staging merge takes two round trips, and the swap writes
        # the reference directly, so the gate re-check has to be on the
        # response read immediately before it rather than the one that
        # preceded the build.
        self._script_pr_view(
            self._behind(),
            self._behind(),
            self._behind(labels=[{"name": drain_prs.CHANGES_LABEL}]),
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertFalse(self._swapped())
        self.assertEqual(len(self._update_branch_calls()), 0)
        self.assertEqual(report["reason"], "changes_requested")
        self.assertIn("42", state["prs"])

    def test_a_check_that_regresses_while_the_merge_is_staged_lands_nothing(self):
        self._script_pr_view(
            self._behind(),
            self._behind(),
            self._behind(
                statusCheckRollup=[
                    {
                        "name": drain_prs.DEFAULT_REQUIRED_CI_CHECK,
                        "status": "IN_PROGRESS",
                        "conclusion": None,
                        "startedAt": "2026-07-18T00:00:05Z",
                    },
                    {
                        "name": drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
                        "status": "COMPLETED",
                        "conclusion": "SUCCESS",
                        "completedAt": "2026-07-18T00:00:01Z",
                    },
                ]
            ),
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertFalse(self._swapped())
        self.assertEqual(len(self._update_branch_calls()), 0)
        self.assertEqual(report["reason"], "checks_pending")

    def test_a_push_that_fails_after_the_update_landed_is_still_a_merge(self):
        # A failed `git push` is not proof of a refused update: the server can
        # accept the reference update and the client still fail. Standing in
        # for that here by having the default branch already hold the merge
        # commit, so the lease refuses while the branch does contain it --
        # which is exactly what the drainer has to be able to tell apart.
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(), {"state": "MERGED"}
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()
        run_git(
            ["update-ref", "refs/heads/master", self.MERGE_COMMIT], cwd=self.bare
        )

        result, state, report = self._run()

        self.assertTrue(result)
        # Reported as the merge it is, cleaned up, and never sent for a branch
        # update it does not need.
        self.assertEqual(report["reason"], "merged")
        self.assertTrue(report["merged"])
        self.assertEqual(len(self._update_branch_calls()), 0)
        self.assertNotIn("42", state["prs"])

    def test_a_push_whose_outcome_cannot_be_established_claims_neither(self):
        self._script_pr_view(self._behind(), self._behind(), self._behind())
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()
        self._advance_remote_default_branch()

        with mock.patch.object(
            drain_prs, "default_branch_contains", return_value=None
        ):
            with self.assertRaises(drain_prs.DrainError) as raised:
                self._run()

        self.assertIn("without establishing whether it landed", str(raised.exception))
        self.assertEqual(len(self._update_branch_calls()), 0)

    def test_a_default_branch_rewound_behind_the_inspected_tip_refuses_the_swap(self):
        # A lease, not a fast-forward test. The staged merge descends from the
        # inspected tip, so it would fast-forward a default branch rewound to
        # an ancestor of it -- restoring commits that rewind removed. The lease
        # names the exact commit instead, so it refuses.
        self._script_pr_view(
            self._behind(),
            self._behind(),
            self._behind(),
            self._behind(),
            self._settled(),
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()
        self._script_update_branch()
        rewound = self.ANCESTOR
        run_git(["update-ref", "refs/heads/master", rewound], cwd=self.bare)

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertFalse(self._swapped())
        self.assertEqual(self._remote_default_branch(), rewound)
        self._assert_requested_the_update(
            report, state, fragment="no longer the inspected"
        )

    def test_a_merge_commit_joining_other_commits_is_never_swapped_in(self):
        # The commit that lands has to be the join of the two commits the
        # authorization was computed from, and nothing else.
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(), self._settled()
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr(
            parents=[{"sha": self.MOVED_TIP}, {"sha": self.head_sha}]
        )
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertFalse(self._swapped())
        self._assert_requested_the_update(report, state)

    def test_a_merge_commit_github_will_not_build_requests_the_update(self):
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(), self._settled()
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr(build_exit=1)
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertFalse(self._swapped())
        self._assert_requested_the_update(report, state)

    def test_a_staging_reference_that_cannot_be_created_requests_the_update(self):
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(), self._settled()
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_staging_ref(created=False)
        self._script_update_branch()

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertFalse(self._swapped())
        self._assert_requested_the_update(report, state)

    def test_a_head_that_moved_before_the_swap_merges_nothing(self):
        # The commit about to land is already fixed, so a head that moved
        # cannot change what merges -- but the pull request it belongs to
        # would not be finished by it, so nothing is swapped in at all.
        self._script_pr_view(
            self._behind(),
            self._behind(),
            self._behind(headRefOid="f" * 40),
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertFalse(self._swapped())
        self.assertEqual(len(self._update_branch_calls()), 0)
        self.assertEqual(report["reason"], "approved_head_changed")
        self.assertEqual(len(self._staging_ref_deletions()), 2)

    def test_a_pull_request_closed_before_the_swap_lands_nothing(self):
        # Approval and checks were re-read before the staging merge was built;
        # the pull request can still be closed while it is being built. Nothing
        # may reach the default branch for a pull request that is not open.
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(state="CLOSED")
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()

        with self.assertRaises(drain_prs.DrainError) as raised:
            self._run()

        self.assertIn("CLOSED", str(raised.exception))
        self.assertFalse(self._swapped())
        self.assertEqual(len(self._update_branch_calls()), 0)
        # Staged and cleaned up, but never swapped in.
        self.assertEqual(len(self._staging_ref_deletions()), 2)

    def test_a_pull_request_retargeted_before_the_swap_lands_nothing(self):
        # Writing the reference directly means the pull-request merge endpoint
        # is not there to refuse this: a pull request retargeted away from the
        # default branch must not be fast-forwarded into it anyway.
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(baseRefName="release-1.x")
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()

        with self.assertRaises(drain_prs.DrainError) as raised:
            self._run()

        self.assertIn("release-1.x", str(raised.exception))
        self.assertFalse(self._swapped())
        self.assertEqual(len(self._staging_ref_deletions()), 2)

    def test_a_pull_request_made_a_draft_before_the_swap_lands_nothing(self):
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(isDraft=True)
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()

        with self.assertRaises(drain_prs.DrainError) as raised:
            self._run()

        self.assertIn("draft", str(raised.exception))
        self.assertFalse(self._swapped())

    def test_a_pull_request_github_closed_without_merging_is_a_fatal_incident(self):
        # The swap landed the commit, but GitHub recorded the pull request as
        # closed rather than merged. Nothing may report a merge, or run a
        # merge's cleanup, on the strength of "no longer open".
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(), {"state": "CLOSED"}
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()

        with self.assertRaises(drain_prs.PostMergeAuditError) as raised:
            self._run()

        message = str(raised.exception)
        self.assertIn("CLOSED", message)
        self.assertIn("MERGED", message)
        self.assertTrue(self._swapped())

    def test_a_refusal_over_a_head_that_moved_defers_for_rereview(self):
        # A refusal is only a reason to request the branch update once the
        # pull request is confirmed to still be at the head it was refused
        # for; a head that moved needs a fresh review instead.
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(headRefOid="f" * 40)
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr(build_exit=1)

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertEqual(report["reason"], "approved_head_changed")
        self.assertEqual(len(self._update_branch_calls()), 0)
        self.assertFalse(self._swapped())

    def test_a_refusal_over_a_pull_request_no_longer_open_fails_closed(self):
        self._script_pr_view(
            self._behind(), self._behind(), self._behind(state="MERGED")
        )
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr(build_exit=1)

        with self.assertRaises(drain_prs.DrainError):
            self._run()

        # Neither outcome may be claimed for a pull request this run can no
        # longer account for.
        self.assertEqual(len(self._update_branch_calls()), 0)
        self.assertFalse(self._swapped())

    def test_a_pull_request_github_never_records_as_merged_is_a_fatal_incident(self):
        # The swap landed, so the merge is durable and reported. A pull request
        # that should have closed and did not is still not left to the next
        # pass to guess at.
        self._script_pr_view(self._behind(), self._behind(), self._behind())
        self._script_tip(self.TIP)
        self._script_file_sets(advanced=[{"filename": self.COORDINATION_PATH}])
        self._script_merge_of_this_pr()

        with mock.patch.object(drain_prs, "MERGED_STATE_WAIT_SECONDS", 0):
            with self.assertRaises(drain_prs.PostMergeAuditError) as raised:
                self._run()

        self.assertIn("still open", str(raised.exception))
        self.assertTrue(self._swapped())

    def test_an_ordinary_merge_never_stages_anything(self):
        # No exception was taken, so the pull request was never behind. The
        # ordinary path keeps using `gh pr merge` exactly as it always has.
        self._script_pr_view()
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

        result, state, report = self._run()

        self.assertTrue(result)
        self.assertEqual(report["reason"], "merged")
        self.assertEqual(len(self._pr_merge_calls()), 1)
        self.assertFalse(self._swapped())
        self.assertEqual(self._staging_ref_deletions(), [])


class MarkerLookupPaginationTests(ProcessPrFixture):
    """Regression coverage for issue #27: the verdict marker must be the
    globally newest one in the comment feed, not the newest inside the
    bounded window `gh pr view --json comments` happens to return.
    """

    def _script_comment_pages(self, pages=None, **kwargs):
        self.fake.script(
            "gh",
            ["api", "--paginate", "--slurp", COMMENTS_ENDPOINT],
            stdout="" if pages is None else json.dumps(pages),
            **kwargs,
        )

    def _ordinary(self, index, created_at):
        return {
            "id": index,
            "created_at": created_at,
            "body": f"ordinary comment {index}",
        }

    def test_newest_marker_outside_the_bounded_window_wins(self):
        old_head = "d" * 40
        # Page one is the slice the old single-view path would have read: it
        # ends with a stale CHANGES_REQUESTED marker. The newest marker lives
        # on a later page, so only a globally ordered scan finds it.
        first_page = [self._ordinary(i, f"2026-07-01T00:{i:02d}:00Z") for i in range(99)]
        first_page.append(
            {
                "id": 99,
                "created_at": "2026-07-01T23:00:00Z",
                "body": (
                    "<!-- pr-review:v1 reviewer=codex "
                    f"head={old_head} verdict=CHANGES_REQUESTED -->"
                ),
            }
        )
        second_page = [
            {
                "id": 100,
                "created_at": "2026-07-20T00:00:00Z",
                "body": (
                    "<!-- pr-review:v1 reviewer=codex "
                    f"head={self.head_sha} verdict=APPROVE -->"
                ),
            }
        ]
        self._script_comment_pages([first_page, second_page])

        with mock.patch.dict(os.environ, self.fake.environ_overrides()):
            details = drain_prs.latest_review_details(self.ctx, 42)

        self.assertEqual(details, ("codex", self.head_sha.lower(), "APPROVE"))
        # The capped `gh pr view --json comments` path is no longer consulted.
        self.assertEqual(self._pr_view_calls(), [])

    def test_exhausted_feed_without_a_marker_returns_none(self):
        self._script_comment_pages(
            [
                [self._ordinary(i, f"2026-07-01T00:{i:02d}:00Z") for i in range(100)],
                [self._ordinary(100, "2026-07-20T00:00:00Z")],
            ]
        )

        with mock.patch.dict(os.environ, self.fake.environ_overrides()):
            details = drain_prs.latest_review_details(self.ctx, 42)

        self.assertIsNone(details)

    def test_fetch_failure_raises_instead_of_reporting_absence(self):
        self._script_comment_pages(stderr="boom", exit_code=1)

        with mock.patch.dict(os.environ, self.fake.environ_overrides()):
            with self.assertRaises(drain_prs.DrainError) as caught:
                drain_prs.latest_review_details(self.ctx, 42)

        self.assertIn("boom", str(caught.exception))

    def test_unexpected_response_shape_raises_instead_of_reporting_absence(self):
        for payload in ({"comments": []}, [{"id": 1, "body": "not a page"}]):
            with self.subTest(payload=payload):
                self._build_fixture()
                self._script_comment_pages(payload)

                with mock.patch.dict(os.environ, self.fake.environ_overrides()):
                    with self.assertRaises(drain_prs.DrainError) as caught:
                        drain_prs.latest_review_details(self.ctx, 42)

                self.assertIn("Unexpected comments", str(caught.exception))


class OneCycleStaleEntryCleanupTests(ProcessPrFixture):
    """Regression coverage for issue #27: forgetting departed PRs must cost
    one cycle in total rather than one cycle per entry, and must not suppress
    the ready PR selected in that same cycle.
    """

    def _entry(self, head):
        return {
            "approved_head": head,
            "last_rereviewed_head": None,
            "consecutive_failures": 0,
            "retry_after_attempt": 0,
            "last_attempt": 0,
            "last_error": None,
        }

    def test_three_closed_entries_are_forgotten_and_the_ready_pr_still_merges(self):
        closed = (7, 8, 9)
        for number in closed:
            self.fake.script(
                "gh",
                ["pr", "view", str(number)],
                stdout=json.dumps(
                    {
                        "number": number,
                        "state": "CLOSED",
                        "headRefOid": "b" * 40,
                        "labels": [],
                    }
                ),
            )
        self._script_pr_view()
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
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

        state_path = drain_prs.drain_state_path(self.ctx)
        state_path.write_text(
            json.dumps(
                {
                    "version": drain_prs.STATE_VERSION,
                    "attempt_counter": 0,
                    "prs": {
                        **{str(number): self._entry("b" * 40) for number in closed},
                        "42": self._entry(self.head_sha),
                    },
                }
            ),
            encoding="utf-8",
        )

        gates = drain_prs.GateConfig(
            required_ci_check=drain_prs.DEFAULT_REQUIRED_CI_CHECK,
            required_review_check=drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
        )
        with mock.patch.dict(os.environ, self.fake.environ_overrides()):
            drain_prs.loop(
                self.ctx,
                interval=0,
                once=True,
                dry_run=False,
                gates=gates,
            )

        final = json.loads(state_path.read_text(encoding="utf-8"))
        # All three departed entries are gone after a single cycle...
        for number in closed:
            self.assertNotIn(str(number), final["prs"])
        # ...and that cleanup did not suppress the ready PR in the same cycle.
        self.assertEqual(len(self._pr_merge_calls()), 1)
        self.assertNotIn("42", final["prs"])


class LockFileIntegrityTests(ProcessPrFixture):
    """Regression coverage for issue #27: a losing contender must not
    truncate the running instance's recorded PID, which is the only record
    of who holds the lock it is reporting.
    """

    def setUp(self):
        super().setUp()
        self.lock_path = self.main / ".git" / "drain_prs.lock"

    def _acquire(self, **kwargs):
        handle = drain_prs.acquire_lock(self.ctx.path, **kwargs)
        self.addCleanup(handle.close)
        return handle

    def test_failed_second_acquisition_leaves_the_holder_pid_intact(self):
        self._acquire()
        recorded = self.lock_path.read_bytes()
        self.assertEqual(recorded, str(os.getpid()).encode())

        with self.assertRaises(drain_prs.DrainError) as caught:
            drain_prs.acquire_lock(self.ctx.path)

        self.assertIn("already running", str(caught.exception))
        self.assertEqual(self.lock_path.read_bytes(), recorded)

    def test_first_run_creates_the_file_holding_exactly_the_pid(self):
        self.assertFalse(self.lock_path.exists())

        self._acquire()

        self.assertEqual(
            self.lock_path.read_text(encoding="utf-8"), str(os.getpid())
        )

    def test_longer_stale_contents_are_replaced_by_exactly_the_pid(self):
        self.lock_path.write_text("9" * 200, encoding="utf-8")

        self._acquire()

        self.assertEqual(
            self.lock_path.read_text(encoding="utf-8"), str(os.getpid())
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

    def _run_cleanup(self):
        """One post-merge cleanup pass for self.pr, asserting it discharged
        every obligation the merge recorded."""
        failures = drain_prs.run_cleanup_pass(
            self.ctx, drain_prs.plan_cleanup(self.pr), dry_run=False
        )
        self.assertEqual(failures, [])


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
        self._run_cleanup()

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

        self._run_cleanup()

        self.assertFalse(detached_wt.exists())

    def test_detached_worktree_at_common_ancestor_is_not_matched(self):
        detached_wt = self.root / "detached-ancestor"
        run_git(
            ["worktree", "add", "-q", "--detach", str(detached_wt), self.base_sha],
            cwd=self.main,
        )

        self.assertIsNone(drain_prs.find_matching_worktree(self.ctx, self.pr))

        self._run_cleanup()

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
        self.fake.script("gh", ["pr", "view", "42"], stdout=json.dumps(pr_json))
        # latest_review_marker() pages the comment feed through the REST API
        # rather than the bounded `gh pr view --json comments` window.
        self.fake.script(
            "gh",
            ["api", "--paginate", "--slurp", COMMENTS_ENDPOINT],
            stdout=json.dumps(
                [
                    [
                        {
                            "id": 1,
                            "created_at": "2026-07-20T00:00:00Z",
                            "body": (
                                "<!-- pr-review:v1 reviewer=codex "
                                f"head={self.head_sha} verdict=APPROVE -->"
                            ),
                        }
                    ]
                ]
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


class MergeConflictIncidentTests(ProcessPrFixture):
    """Issue #123: a conflict is the one artifact in this pipeline no reviewer
    has seen, so the drainer stops working that PR and raises an incident
    instead of repairing it -- touching no label, merging nothing, calling no
    model, and blocking no other PR.
    """

    def setUp(self):
        super().setUp()
        # Installed but never expected to run: an empty call log is the proof
        # that conflict handling reaches no model.
        self.fake.install("codex")
        self.fake.install("claude")
        self.incident_dir = self.root / "incidents"
        self.incident_dir.mkdir()
        self.drainer_log_dir = self.root / "drainer-logs"
        self.drainer_log_dir.mkdir()
        self.conflict_head = self._build_conflicting_branch()

    def _build_conflicting_branch(self):
        # README diverges on both sides of the merge base, so the local
        # inspection has a real conflict to name.
        run_git(["checkout", "-q", "-b", "issue-77-conflict"], cwd=self.upstream_sim)
        (self.upstream_sim / "README").write_text("branch side\n", encoding="utf-8")
        run_git(["commit", "-q", "-am", "branch side"], cwd=self.upstream_sim)
        head = run_git(["rev-parse", "HEAD"], cwd=self.upstream_sim)
        run_git(["push", "-q", "origin", "issue-77-conflict"], cwd=self.upstream_sim)
        run_git(["checkout", "-q", "master"], cwd=self.upstream_sim)
        (self.upstream_sim / "README").write_text("master side\n", encoding="utf-8")
        run_git(["commit", "-q", "-am", "master side"], cwd=self.upstream_sim)
        run_git(["push", "-q", "origin", "master"], cwd=self.upstream_sim)
        return head

    def _build_fork_pull_request(self):
        """A fork PR: its head is published only at refs/pull/78/head, never as
        a branch of this repository, and an unrelated upstream branch happens
        to share its headRefName while conflicting in a different file.
        """
        run_git(["checkout", "-q", "-b", "shared-name", "master"], cwd=self.upstream_sim)
        (self.upstream_sim / "NOTES").write_text("decoy notes\n", encoding="utf-8")
        run_git(["add", "NOTES"], cwd=self.upstream_sim)
        run_git(["commit", "-q", "-m", "decoy notes"], cwd=self.upstream_sim)
        run_git(["push", "-q", "origin", "shared-name"], cwd=self.upstream_sim)

        run_git(["checkout", "-q", "--detach", "master"], cwd=self.upstream_sim)
        (self.upstream_sim / "README").write_text("fork side\n", encoding="utf-8")
        run_git(["add", "README"], cwd=self.upstream_sim)
        run_git(["commit", "-q", "-m", "fork side"], cwd=self.upstream_sim)
        fork_head = run_git(["rev-parse", "HEAD"], cwd=self.upstream_sim)
        # Reachable only from the pull ref, exactly as a fork head is.
        run_git(
            ["push", "-q", "origin", f"{fork_head}:refs/pull/78/head"],
            cwd=self.upstream_sim,
        )

        run_git(["checkout", "-q", "master"], cwd=self.upstream_sim)
        (self.upstream_sim / "README").write_text("master again\n", encoding="utf-8")
        (self.upstream_sim / "NOTES").write_text("master notes\n", encoding="utf-8")
        run_git(["add", "README", "NOTES"], cwd=self.upstream_sim)
        run_git(["commit", "-q", "-m", "master notes"], cwd=self.upstream_sim)
        run_git(["push", "-q", "origin", "master"], cwd=self.upstream_sim)
        return fork_head

    @contextlib.contextmanager
    def _drainer(self):
        with (
            mock.patch.dict(os.environ, self.fake.environ_overrides()),
            mock.patch.object(drain_prs_service, "RUNTIME_ROOT", self.root),
            mock.patch.object(drain_prs_service, "LOG_ROOT", self.drainer_log_dir),
            mock.patch.object(drain_prs_service, "NTFY_URL", None),
        ):
            yield

    def _conflicted_pr_json(self, **overrides):
        pr_json = self._base_pr_json()
        pr_json.update(
            {
                "number": 77,
                "url": "https://github.com/acme/widgets/pull/77",
                "mergeable": "CONFLICTING",
                "mergeStateStatus": "DIRTY",
                "headRefOid": self.conflict_head,
                "headRefName": "issue-77-conflict",
                "closingIssuesReferences": [],
            }
        )
        pr_json.update(overrides)
        return pr_json

    def _script_conflicted_pr(self, *overrides):
        for override in overrides or ({},):
            self.fake.script(
                "gh",
                ["pr", "view", "77"],
                stdout=json.dumps(self._conflicted_pr_json(**override)),
            )

    def _entry(self, head):
        return {
            "approved_head": head,
            "last_rereviewed_head": None,
            "consecutive_failures": 0,
            "retry_after_attempt": 0,
            "last_attempt": 0,
            "last_error": None,
        }

    def _gates(self):
        return drain_prs.GateConfig(
            required_ci_check=drain_prs.DEFAULT_REQUIRED_CI_CHECK,
            required_review_check=drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
        )

    def _incidents(self, *, status="open"):
        found = []
        for path in sorted(self.incident_dir.glob("incident-*.json")):
            incident = json.loads(path.read_text(encoding="utf-8"))
            if incident["status"] == status:
                found.append(incident)
        return found

    def _mutating_gh_calls(self):
        return [
            call
            for call in self.fake.calls("gh")
            if call["args"][:2] in (["pr", "edit"], ["pr", "merge"], ["pr", "ready"])
        ]

    def _write_conflict_incident(self, number, files):
        with self._drainer():
            return drain_prs_service.record_conflict_incident(
                repo_path=self.ctx.path, pull_request=number, files=files
            )

    def _write_crash_incident(self):
        path = self.incident_dir / "incident-20260101T000000Z-9-crash.json"
        path.write_text(
            json.dumps(
                {
                    "incident_id": path.stem,
                    "kind": drain_prs_service.CRASH_INCIDENT_KIND,
                    "status": "open",
                    "summary": "drain_prs.py exited unexpectedly with code 1",
                    "exit_code": 1,
                    "repo": str(self.ctx.path),
                }
            ),
            encoding="utf-8",
        )
        return path

    def test_conflicted_pr_raises_one_incident_and_changes_nothing_else(self):
        self._script_conflicted_pr()
        state = {
            "version": drain_prs.STATE_VERSION,
            "attempt_counter": 0,
            "prs": {"77": self._entry(self.conflict_head)},
        }

        with self._drainer():
            # Two polls over the same unresolved conflict.
            first = drain_prs.process_pr(
                self.ctx, 77, dry_run=False, state=state, gates=self._gates()
            )
            second = drain_prs.process_pr(
                self.ctx, 77, dry_run=False, state=state, gates=self._gates()
            )

        self.assertFalse(first)
        self.assertFalse(second)

        incidents = self._incidents()
        self.assertEqual(len(incidents), 1)
        incident = incidents[0]
        self.assertEqual(incident["kind"], drain_prs_service.CONFLICT_INCIDENT_KIND)
        self.assertEqual(incident["pull_request"], 77)
        self.assertIsInstance(incident["pull_request"], int)
        self.assertEqual(incident["files"], ["README"])
        self.assertIn("#77", incident["summary"])
        self.assertIn("README", incident["summary"])
        self.assertEqual(incident["repo"], str(self.ctx.path))
        # Crash-incident semantics must not leak into a healthy-drainer block.
        self.assertNotIn("exit_code", incident)
        self.assertNotIn("drainer stopped", incident["summary"])
        self.assertNotIn("exited", incident["summary"])

        self.assertEqual(self._mutating_gh_calls(), [])
        self.assertEqual(self.fake.calls("codex"), [])
        self.assertEqual(self.fake.calls("claude"), [])

    def test_a_fork_head_is_named_by_oid_not_by_branch_name(self):
        fork_head = self._build_fork_pull_request()
        self.fake.script(
            "gh",
            ["pr", "view", "78"],
            stdout=json.dumps(
                self._conflicted_pr_json(
                    number=78,
                    headRefOid=fork_head,
                    # An upstream branch of this name exists and conflicts in
                    # NOTES; resolving by name would report the wrong paths.
                    headRefName="shared-name",
                )
            ),
        )

        with self._drainer():
            drain_prs.process_pr(
                self.ctx,
                78,
                dry_run=False,
                state={
                    "version": drain_prs.STATE_VERSION,
                    "attempt_counter": 0,
                    "prs": {"78": self._entry(fork_head)},
                },
                gates=self._gates(),
            )

        incidents = self._incidents()
        self.assertEqual(len(incidents), 1)
        self.assertEqual(incidents[0]["pull_request"], 78)
        self.assertEqual(incidents[0]["files"], ["README"])
        self.assertIn("README", incidents[0]["summary"])
        self.assertEqual(self._mutating_gh_calls(), [])

    def test_an_unavailable_head_still_raises_an_incident(self):
        missing_head = "e" * 40
        self.fake.script(
            "gh",
            ["pr", "view", "79"],
            stdout=json.dumps(
                self._conflicted_pr_json(
                    number=79, headRefOid=missing_head, headRefName="gone"
                )
            ),
        )

        with self._drainer():
            drain_prs.process_pr(
                self.ctx,
                79,
                dry_run=False,
                state={
                    "version": drain_prs.STATE_VERSION,
                    "attempt_counter": 0,
                    "prs": {"79": self._entry(missing_head)},
                },
                gates=self._gates(),
            )

        incidents = self._incidents()
        self.assertEqual(len(incidents), 1)
        self.assertEqual(incidents[0]["pull_request"], 79)
        self.assertEqual(incidents[0]["files"], [])
        self.assertIn("#79", incidents[0]["summary"])
        self.assertEqual(self._mutating_gh_calls(), [])

    def test_a_conflict_blocks_only_its_own_pr(self):
        self._script_pr_view()
        self._script_conflicted_pr()
        for approved in (
            [
                {
                    "number": 42,
                    "labels": [{"name": drain_prs.APPROVE_LABEL}],
                    "isDraft": False,
                    "headRefOid": self.head_sha,
                },
                {
                    "number": 77,
                    "labels": [{"name": drain_prs.APPROVE_LABEL}],
                    "isDraft": False,
                    "headRefOid": self.conflict_head,
                },
            ],
            [
                {
                    "number": 77,
                    "labels": [{"name": drain_prs.APPROVE_LABEL}],
                    "isDraft": False,
                    "headRefOid": self.conflict_head,
                }
            ],
        ):
            self.fake.script("gh", ["pr", "list"], stdout=json.dumps(approved))
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

        with self._drainer():
            for _ in range(2):
                drain_prs.loop(
                    self.ctx,
                    interval=0,
                    once=True,
                    dry_run=False,
                    gates=self._gates(),
                )

        merge_calls = self._pr_merge_calls()
        self.assertEqual(len(merge_calls), 1)
        self.assertEqual(merge_calls[0]["args"][2], "42")

        incidents = self._incidents()
        self.assertEqual([incident["pull_request"] for incident in incidents], [77])

        self.assertEqual(
            [call for call in self._mutating_gh_calls() if "77" in call["args"]], []
        )
        state = json.loads(
            drain_prs.drain_state_path(self.ctx).read_text(encoding="utf-8")
        )
        self.assertNotIn("42", state["prs"])
        # A blocked PR is not a failed attempt, so it earns no cooldown.
        self.assertEqual(state["prs"]["77"]["consecutive_failures"], 0)

    def test_dry_run_reports_the_incident_without_recording_or_fetching(self):
        self._script_conflicted_pr()
        refs_before = run_git(
            ["for-each-ref", "--format=%(refname) %(objectname)"], cwd=self.main
        )

        with self._drainer():
            result = drain_prs.process_pr(
                self.ctx,
                77,
                dry_run=True,
                state={
                    "version": drain_prs.STATE_VERSION,
                    "attempt_counter": 0,
                    "prs": {"77": self._entry(self.conflict_head)},
                },
                gates=self._gates(),
            )

        self.assertFalse(result)
        self.assertEqual(list(self.incident_dir.glob("*.json")), [])
        self.assertEqual(
            run_git(["for-each-ref", "--format=%(refname) %(objectname)"], cwd=self.main),
            refs_before,
        )
        self.assertEqual(self._mutating_gh_calls(), [])
        self.assertEqual(self.fake.calls("codex"), [])

    def test_reconciliation_resolves_only_the_pr_that_is_no_longer_conflicted(self):
        cleared = self._write_conflict_incident(77, ["README"])
        closed = self._write_conflict_incident(55, ["docs/pr-drainer.md"])
        still_conflicted = self._write_conflict_incident(66, ["tools/drain_prs.py"])
        crash = self._write_crash_incident()

        self._script_conflicted_pr(
            {"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN"}
        )
        self.fake.script(
            "gh",
            ["pr", "view", "55"],
            stdout=json.dumps({"number": 55, "state": "CLOSED", "mergeable": "UNKNOWN"}),
        )
        self.fake.script(
            "gh",
            ["pr", "view", "66"],
            stdout=json.dumps(
                {
                    "number": 66,
                    "state": "OPEN",
                    "mergeable": "CONFLICTING",
                    "mergeStateStatus": "DIRTY",
                }
            ),
        )

        with self._drainer():
            drain_prs.reconcile_conflict_incidents(self.ctx, dry_run=False)

        resolved = {
            incident["incident_id"] for incident in self._incidents(status="resolved")
        }
        still_open = {
            incident["incident_id"] for incident in self._incidents(status="open")
        }
        self.assertEqual(resolved, {cleared["incident_id"], closed["incident_id"]})
        self.assertEqual(
            still_open, {still_conflicted["incident_id"], crash.stem}
        )
        self.assertEqual(self._mutating_gh_calls(), [])

    def test_unconfirmed_readings_keep_a_conflict_incident_open(self):
        unknown = self._write_conflict_incident(77, ["README"])
        unreadable = self._write_conflict_incident(55, ["README"])

        self._script_conflicted_pr(
            {"mergeable": "UNKNOWN", "mergeStateStatus": "UNKNOWN"}
        )
        self.fake.script("gh", ["pr", "view", "55"], stderr="boom", exit_code=1)

        with self._drainer():
            drain_prs.reconcile_conflict_incidents(self.ctx, dry_run=False)

        self.assertEqual(
            {incident["incident_id"] for incident in self._incidents(status="open")},
            {unknown["incident_id"], unreadable["incident_id"]},
        )

    def test_dry_run_reconciliation_resolves_nothing(self):
        incident = self._write_conflict_incident(77, ["README"])
        self._script_conflicted_pr(
            {"mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN"}
        )

        with self._drainer():
            drain_prs.reconcile_conflict_incidents(self.ctx, dry_run=True)

        self.assertEqual(
            [entry["incident_id"] for entry in self._incidents(status="open")],
            [incident["incident_id"]],
        )


class PostMergeCleanupFixture(ProcessPrFixture):
    """Scaffolding for the durable post-merge cleanup record: a real temporary
    repository whose queue state can be written and read back, drainer
    incidents redirected into it, and a scriptable fake `gh`.
    """

    def setUp(self):
        super().setUp()
        self.incident_dir = self.root / "incidents"
        self.incident_dir.mkdir()
        self.drainer_log_dir = self.root / "drainer-logs"
        self.drainer_log_dir.mkdir()
        self.state_path = drain_prs.drain_state_path(self.ctx)

    @contextlib.contextmanager
    def _drainer(self):
        with (
            mock.patch.dict(os.environ, self.fake.environ_overrides()),
            mock.patch.object(drain_prs_service, "RUNTIME_ROOT", self.root),
            mock.patch.object(drain_prs_service, "LOG_ROOT", self.drainer_log_dir),
            mock.patch.object(drain_prs_service, "NTFY_URL", None),
        ):
            yield

    def _entry(self, head, **extra):
        entry = {
            "approved_head": head,
            "last_rereviewed_head": None,
            "consecutive_failures": 0,
            "retry_after_attempt": 0,
            "last_attempt": 0,
            "last_error": None,
            "cleanup": None,
        }
        entry.update(extra)
        return entry

    def _gates(self):
        return drain_prs.GateConfig(
            required_ci_check=drain_prs.DEFAULT_REQUIRED_CI_CHECK,
            required_review_check=drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
        )

    def _write_state(self, state):
        self.state_path.write_text(json.dumps(state, indent=2), encoding="utf-8")

    def _read_state(self):
        return json.loads(self.state_path.read_text(encoding="utf-8"))

    def _run_loop(self, *, dry_run=False):
        with self._drainer():
            drain_prs.loop(
                self.ctx,
                interval=0,
                once=True,
                dry_run=dry_run,
                gates=self._gates(),
            )

    def _issue_close_calls(self, number):
        return [
            call
            for call in self.fake.calls("gh")
            if call["args"][:3] == ["issue", "close", str(number)]
        ]

    def _incidents(self):
        return [
            json.loads(path.read_text(encoding="utf-8"))
            for path in sorted(self.incident_dir.glob("incident-*.json"))
        ]

    def _stuck_cleanup_record(self, *issue_numbers):
        """A merged PR #7 owing one issue close per number given and nothing
        else, so an escalation is attributable to those obligations alone."""
        record = drain_prs.plan_cleanup(
            {
                "number": 7,
                "headRefName": "issue-7-departed",
                "headRefOid": "b" * 40,
                "closingIssuesReferences": [
                    {
                        "number": number,
                        "repository": {"owner": {"login": "acme"}, "name": "widgets"},
                    }
                    for number in (issue_numbers or (7,))
                ],
            }
        )
        record["pending"] = [
            item for item in record["pending"] if item["kind"] == "issue"
        ]
        return record

    def _script_merge_with_failing_issue_close(self):
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script(
            "gh", ["issue", "close", "99"], stderr="gh: server error", exit_code=1
        )


class PostMergeCleanupTests(PostMergeCleanupFixture):
    """Issue #23: a successful merge is durably recorded before its cleanup is
    attempted, so a cleanup failure is a debt the queue retries rather than a
    silent leak of the linked issues, the branches and the worktree.
    """

    def test_a_failed_issue_close_does_not_skip_the_rest_of_the_pass(self):
        self._script_pr_view()
        self._script_merge_with_failing_issue_close()

        with self._drainer():
            result, state = self._run_process_pr()

        self.assertTrue(result)
        self.assertEqual(len(self._issue_close_calls(99)), 1)

        # Every obligation after the failing one still ran in the same pass.
        self.assertFalse(self.feature_wt.exists())
        self.assertFalse(git_ref_exists(self.main, "refs/heads/issue-99-demo"))
        self.assertFalse(git_ref_exists(self.bare, "refs/heads/issue-99-demo"))
        self.assertEqual(
            run_git(["rev-parse", "master"], cwd=self.main), self.merge_commit_sha
        )

        # The merge is not forgotten while it still owes the issue close, and
        # the debt is on disk rather than only in this process's memory.
        record = self._read_state()["prs"]["42"]["cleanup"]
        self.assertEqual(
            record["pending"],
            [{"kind": "issue", "repo": "acme/widgets", "number": 99}],
        )
        self.assertEqual(record["failed_passes"], 1)
        self.assertIn("acme/widgets#99", record["last_error"])
        self.assertIsNone(record["incident"])
        self.assertEqual(record["pr"]["headRefName"], "issue-99-demo")
        self.assertIsNotNone(state["prs"]["42"]["cleanup"])

    def test_cleanup_resumes_from_the_state_file_without_a_second_merge(self):
        # The fourth `gh pr view` is the recovery read of a PR that is now
        # merged; the second `gh issue close` is the retry that succeeds.
        self._script_pr_view({}, {}, {}, {"state": "MERGED"})
        self._script_merge_with_failing_issue_close()
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

        with self._drainer():
            self._run_process_pr()
        self.assertIn("42", self._read_state()["prs"])

        # A fresh state object loaded from disk, as a restarted drainer has:
        # nothing about the interrupted cleanup survives in memory.
        resumed = drain_prs.load_drain_state(self.ctx)
        self.assertIsNotNone(resumed["prs"]["42"]["cleanup"])
        with self._drainer():
            recovered = drain_prs.recover_stale_approval(
                self.ctx, resumed, dry_run=False
            )

        self.assertFalse(recovered)
        self.assertEqual(len(self._issue_close_calls(99)), 2)
        self.assertNotIn("42", resumed["prs"])
        # Recovery completed the outstanding obligation; it did not re-merge.
        self.assertEqual(len(self._pr_merge_calls()), 1)

    def test_repeated_cleanup_failure_escalates_without_blocking_another_pr(self):
        stuck = self._stuck_cleanup_record()
        self._write_state(
            {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 0,
                "prs": {
                    "7": self._entry("b" * 40, cleanup=stuck),
                    "42": self._entry(self.head_sha),
                },
            }
        )
        self.fake.script(
            "gh", ["issue", "view", "7"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script(
            "gh", ["issue", "close", "7"], stderr="gh: server error", exit_code=1
        )
        self._script_pr_view()
        # PR 42 is queued for the first cycle only; the later cycles exist to
        # drive the stuck cleanup past its escalation bound.
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
        self.fake.script("gh", ["pr", "list"], stdout=json.dumps([]))
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

        # Three cycles with once=True: a cleanup failure that reached the
        # loop's global stale-recovery handler would raise out of the first.
        for expected_passes in (1, 2, 3):
            self._run_loop()
            record = self._read_state()["prs"]["7"]["cleanup"]
            self.assertEqual(record["failed_passes"], expected_passes)
            self.assertEqual(
                record["pending"],
                [{"kind": "issue", "repo": "acme/widgets", "number": 7}],
            )
            if expected_passes < drain_prs.CLEANUP_PASSES_BEFORE_INCIDENT:
                self.assertEqual(self._incidents(), [])
                self.assertIsNone(record["incident"])

        incidents = self._incidents()
        self.assertEqual(len(incidents), 1)
        self.assertEqual(
            incidents[0]["kind"], drain_prs_service.CLEANUP_INCIDENT_KIND
        )
        self.assertEqual(incidents[0]["status"], "open")
        self.assertEqual(incidents[0]["pull_request"], 7)
        self.assertIn("acme/widgets#7", incidents[0]["steps"][0])
        self.assertEqual(
            self._read_state()["prs"]["7"]["cleanup"]["incident"],
            incidents[0]["incident_id"],
        )

        # The stuck cleanup never wedged the queue: PR 42 merged and finished
        # its own cleanup in the very first cycle.
        self.assertEqual(len(self._pr_merge_calls()), 1)
        self.assertNotIn("42", self._read_state()["prs"])
        self.assertFalse(self.feature_wt.exists())
        # A recorded cleanup is worked from the record alone, so PR 7 is never
        # refetched -- a failing read cannot strand what the merge already owes.
        self.assertEqual(
            [
                call
                for call in self.fake.calls("gh")
                if call["args"][:3] == ["pr", "view", "7"]
            ],
            [],
        )

    def test_an_escalated_cleanup_resolves_its_incident_once_it_finishes(self):
        stuck = self._stuck_cleanup_record()
        stuck["failed_passes"] = drain_prs.CLEANUP_PASSES_BEFORE_INCIDENT - 1
        self._write_state(
            {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 0,
                "prs": {"7": self._entry("b" * 40, cleanup=stuck)},
            }
        )
        self.fake.script(
            "gh", ["issue", "view", "7"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script(
            "gh", ["issue", "close", "7"], stderr="gh: server error", exit_code=1
        )
        self.fake.script("gh", ["issue", "close", "7"], stdout="")
        self.fake.script("gh", ["pr", "list"], stdout=json.dumps([]))

        self._run_loop()
        opened = self._incidents()
        self.assertEqual(len(opened), 1)
        self.assertEqual(opened[0]["status"], "open")

        self._run_loop()

        resolved = self._incidents()
        self.assertEqual(len(resolved), 1)
        self.assertEqual(resolved[0]["status"], "resolved")
        self.assertNotIn("7", self._read_state()["prs"])

    def test_an_open_incident_stops_naming_a_step_that_has_since_succeeded(self):
        # The incident carries what is outstanding now. A pass that discharges
        # part of the debt must update the open incident rather than leave
        # Kanban showing work that is already done -- and must not open a
        # second incident for the same pull request.
        stuck = self._stuck_cleanup_record(7, 5)
        stuck["failed_passes"] = drain_prs.CLEANUP_PASSES_BEFORE_INCIDENT - 1
        self._write_state(
            {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 0,
                "prs": {"7": self._entry("b" * 40, cleanup=stuck)},
            }
        )
        for number in (7, 5):
            self.fake.script(
                "gh",
                ["issue", "view", str(number)],
                stdout=json.dumps({"state": "OPEN"}),
            )
        self.fake.script(
            "gh", ["issue", "close", "7"], stderr="gh: server error", exit_code=1
        )
        self.fake.script(
            "gh", ["issue", "close", "5"], stderr="gh: server error", exit_code=1
        )
        self.fake.script("gh", ["issue", "close", "5"], stdout="")
        self.fake.script("gh", ["pr", "list"], stdout=json.dumps([]))

        self._run_loop()
        opened = self._incidents()
        self.assertEqual(len(opened), 1)
        self.assertEqual(
            opened[0]["steps"],
            ["closing acme/widgets#7", "closing acme/widgets#5"],
        )

        self._run_loop()

        incidents = self._incidents()
        self.assertEqual(len(incidents), 1)
        self.assertEqual(incidents[0]["incident_id"], opened[0]["incident_id"])
        self.assertEqual(incidents[0]["status"], "open")
        self.assertEqual(incidents[0]["steps"], ["closing acme/widgets#7"])
        self.assertIn("acme/widgets#7", incidents[0]["summary"])
        self.assertNotIn("acme/widgets#5", incidents[0]["summary"])
        self.assertEqual(
            [
                item["number"]
                for item in self._read_state()["prs"]["7"]["cleanup"]["pending"]
            ],
            [7],
        )

    def test_an_intentional_stop_leaves_a_still_failing_cleanup_incident_open(self):
        # Stopping the drainer discharges no post-merge obligation, so the
        # incident naming that debt survives the stop unchanged -- as the only
        # incident there ever is for this pull request -- and clears through
        # its own path, on the pass that finally succeeds.
        stuck = self._stuck_cleanup_record()
        stuck["failed_passes"] = drain_prs.CLEANUP_PASSES_BEFORE_INCIDENT - 1
        self._write_state(
            {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 0,
                "prs": {"7": self._entry("b" * 40, cleanup=stuck)},
            }
        )
        self.fake.script(
            "gh", ["issue", "view", "7"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script(
            "gh", ["issue", "close", "7"], stderr="gh: server error", exit_code=1
        )
        self.fake.script("gh", ["issue", "close", "7"], stdout="")
        self.fake.script("gh", ["pr", "list"], stdout=json.dumps([]))

        self._run_loop()
        first = self._incidents()
        self.assertEqual([entry["status"] for entry in first], ["open"])

        with self._drainer():
            drain_prs_service.resolve_crash_incidents(
                drain_prs_service.incident_job(self.ctx.path),
                "Cleared when the PR drainer was intentionally stopped.",
            )
        survived = self._incidents()
        self.assertEqual(len(survived), 1)
        self.assertEqual(survived[0]["incident_id"], first[0]["incident_id"])
        self.assertEqual(survived[0]["status"], "open")
        self.assertNotIn("resolved_at", survived[0])
        self.assertNotIn("resolution", survived[0])
        # The debt itself is untouched too, so the restarted drainer owes it.
        self.assertEqual(
            self._read_state()["prs"]["7"]["cleanup"]["incident"],
            first[0]["incident_id"],
        )

        self._run_loop()

        incidents = self._incidents()
        self.assertEqual(len(incidents), 1)
        self.assertEqual(incidents[0]["incident_id"], first[0]["incident_id"])
        self.assertEqual(incidents[0]["status"], "resolved")
        self.assertNotIn("7", self._read_state()["prs"])

    def test_an_incident_the_record_never_learned_of_is_still_resolved(self):
        # An incident is written atomically before the state that remembers its
        # id, so a crash in between leaves one open against a record naming no
        # incident at all. Finishing the cleanup must still close it, or Kanban
        # shows an open incident for work that is done.
        stuck = self._stuck_cleanup_record()
        stuck["failed_passes"] = drain_prs.CLEANUP_PASSES_BEFORE_INCIDENT - 1
        self._write_state(
            {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 0,
                "prs": {"7": self._entry("b" * 40, cleanup=stuck)},
            }
        )
        self.fake.script(
            "gh", ["issue", "view", "7"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script(
            "gh", ["issue", "close", "7"], stderr="gh: server error", exit_code=1
        )
        self.fake.script("gh", ["issue", "close", "7"], stdout="")
        self.fake.script("gh", ["pr", "list"], stdout=json.dumps([]))

        self._run_loop()
        opened = self._incidents()
        self.assertEqual([entry["status"] for entry in opened], ["open"])

        # The crash: the incident file survives, the state save that would have
        # recorded its id does not.
        crashed = self._read_state()
        crashed["prs"]["7"]["cleanup"]["incident"] = None
        self._write_state(crashed)

        self._run_loop()

        incidents = self._incidents()
        self.assertEqual(len(incidents), 1)
        self.assertEqual(incidents[0]["status"], "resolved")
        self.assertEqual(incidents[0]["incident_id"], opened[0]["incident_id"])
        self.assertNotIn("7", self._read_state()["prs"])

    def test_a_manually_deleted_worktree_counts_as_already_removed(self):
        # `git worktree list` keeps a registration for a directory somebody
        # deleted by hand. That worktree is gone, which is what the obligation
        # wanted, so the pass must discharge it and carry on.
        shutil.rmtree(self.feature_wt)
        record = drain_prs.plan_cleanup(self._base_pr_json())
        record["pending"] = [
            item for item in record["pending"] if item["kind"] != "issue"
        ]

        with self._drainer():
            errors = drain_prs.run_cleanup_pass(self.ctx, record, dry_run=False)

        self.assertEqual(errors, [])
        self.assertEqual(record["pending"], [])
        self.assertNotIn(
            str(self.feature_wt.resolve()),
            [
                entry.get("worktree")
                for entry in drain_prs.parse_worktrees(self.ctx)
            ],
        )
        self.assertFalse(git_ref_exists(self.main, "refs/heads/issue-99-demo"))

    def test_an_undeletable_missing_worktree_stays_outstanding(self):
        # A locked registration whose directory is gone survives both removal
        # and pruning. Inspecting it for uncommitted work would run git with a
        # missing cwd and raise past the pass; it must stay an ordinary
        # outstanding obligation instead.
        run_git(["worktree", "lock", str(self.feature_wt)], cwd=self.main)
        shutil.rmtree(self.feature_wt)
        record = drain_prs.plan_cleanup(self._base_pr_json())
        record["pending"] = [
            item for item in record["pending"] if item["kind"] != "issue"
        ]

        with self._drainer():
            errors = drain_prs.run_cleanup_pass(self.ctx, record, dry_run=False)

        # The surviving registration still holds the branch, so the local
        # delete is blocked with it -- both stay owed, independently.
        self.assertEqual(len(errors), 2)
        self.assertIn("removing the matching worktree", errors[0])
        self.assertIn("deleting local branch issue-99-demo", errors[1])
        self.assertEqual(
            [item["kind"] for item in record["pending"]],
            ["worktree", "local-branch"],
        )
        # The steps after the failing ones still ran.
        self.assertFalse(git_ref_exists(self.bare, "refs/heads/issue-99-demo"))
        self.assertEqual(
            run_git(["rev-parse", "master"], cwd=self.main), self.merge_commit_sha
        )

    def test_an_unreadable_remote_leaves_the_branch_obligation_outstanding(self):
        # `git ls-remote --exit-code` reports a missing branch as exactly 2; a
        # remote it cannot reach at all is 128. Reading the latter as absence
        # would discharge a deletion that never happened.
        record = drain_prs.plan_cleanup(self._base_pr_json())
        record["pending"] = [
            item for item in record["pending"] if item["kind"] == "remote-branch"
        ]
        run_git(
            ["remote", "set-url", "origin", str(self.root / "missing.git")],
            cwd=self.main,
        )

        with self._drainer():
            errors = drain_prs.run_cleanup_pass(self.ctx, record, dry_run=False)

        self.assertEqual(len(errors), 1)
        self.assertIn("deleting remote branch issue-99-demo", errors[0])
        self.assertEqual(
            record["pending"],
            [{"kind": "remote-branch", "branch": "issue-99-demo"}],
        )
        self.assertTrue(git_ref_exists(self.bare, "refs/heads/issue-99-demo"))

    def test_an_unreadable_repository_leaves_the_local_branch_outstanding(self):
        record = drain_prs.plan_cleanup(self._base_pr_json())
        record["pending"] = [
            item for item in record["pending"] if item["kind"] == "local-branch"
        ]
        broken = drain_prs.RepoContext(
            self.root / "not-a-repository",
            self.ctx.repo_slug,
            self.ctx.repo_name,
            self.ctx.default_branch,
        )
        (self.root / "not-a-repository").mkdir()

        with self._drainer():
            errors = drain_prs.run_cleanup_pass(broken, record, dry_run=False)

        self.assertEqual(len(errors), 1)
        self.assertIn("deleting local branch issue-99-demo", errors[0])
        self.assertEqual(
            record["pending"],
            [{"kind": "local-branch", "branch": "issue-99-demo"}],
        )
        self.assertTrue(git_ref_exists(self.main, "refs/heads/issue-99-demo"))

    def test_a_closed_unmerged_pr_is_forgotten_without_running_cleanup(self):
        closed = self._base_pr_json()
        closed.update({"number": 8, "state": "CLOSED"})
        self.fake.script("gh", ["pr", "view", "8"], stdout=json.dumps(closed))
        state = {
            "version": drain_prs.STATE_VERSION,
            "attempt_counter": 0,
            "prs": {"8": self._entry(self.head_sha)},
        }

        with self._drainer():
            recovered = drain_prs.recover_stale_approval(
                self.ctx, state, dry_run=False
            )

        self.assertFalse(recovered)
        self.assertNotIn("8", state["prs"])
        # A PR closed without merging owes nothing: nothing was closed or
        # deleted on its behalf.
        self.assertEqual(self._issue_close_calls(99), [])
        self.assertTrue(self.feature_wt.exists())
        self.assertTrue(git_ref_exists(self.main, "refs/heads/issue-99-demo"))
        self.assertTrue(git_ref_exists(self.bare, "refs/heads/issue-99-demo"))

    def test_a_content_safe_branch_update_reclaims_the_stale_approval(self):
        # The head advanced via a synchronize push that touched none of this
        # PR's own files -- review-gate.yml's dismiss-stale-approval job
        # deliberately keeps reviewed:approve for exactly this case (#801),
        # e.g. a busy base branch repeatedly merging forward into the PR
        # branch. No fresh review runs for that kind of push, so no marker
        # is ever posted at the new head; recovery must fall back to the
        # workflow's own verdict for this head instead of waiting forever
        # for a marker that will never come.
        new_head = "c" * 40
        state = {
            "version": drain_prs.STATE_VERSION,
            "attempt_counter": 0,
            "prs": {"42": self._entry(self.head_sha)},
        }
        pr_json = self._base_pr_json()
        pr_json["headRefOid"] = new_head
        pr_json["statusCheckRollup"].append(
            {
                "name": drain_prs.STALE_APPROVAL_CHECK,
                "status": "COMPLETED",
                "conclusion": "SUCCESS",
                "completedAt": "2026-08-02T00:00:02Z",
            }
        )
        self.fake.script("gh", ["pr", "view", "42"], stdout=json.dumps(pr_json))
        self.fake.script(
            "gh",
            ["api", "--paginate", "--slurp", COMMENTS_ENDPOINT],
            stdout=json.dumps([[]]),
        )

        with self._drainer():
            recovered = drain_prs.recover_stale_approval(
                self.ctx, state, dry_run=False
            )

        self.assertTrue(recovered)
        self.assertEqual(state["prs"]["42"]["approved_head"], new_head)

    def test_a_stale_head_with_no_dismiss_stale_approval_verdict_keeps_waiting(self):
        # Same moved head as above, but nothing has told us yet whether the
        # push was content-safe (check missing/still pending) -- recovery
        # must not guess and must leave the stale approval exactly as it
        # found it.
        new_head = "c" * 40
        state = {
            "version": drain_prs.STATE_VERSION,
            "attempt_counter": 0,
            "prs": {"42": self._entry(self.head_sha)},
        }
        pr_json = self._base_pr_json()
        pr_json["headRefOid"] = new_head
        self.fake.script("gh", ["pr", "view", "42"], stdout=json.dumps(pr_json))
        self.fake.script(
            "gh",
            ["api", "--paginate", "--slurp", COMMENTS_ENDPOINT],
            stdout=json.dumps([[]]),
        )

        with self._drainer():
            recovered = drain_prs.recover_stale_approval(
                self.ctx, state, dry_run=False
            )

        self.assertFalse(recovered)
        self.assertEqual(state["prs"]["42"]["approved_head"], self.head_sha)

    def test_a_version_2_state_file_recovers_an_unfinished_merge(self):
        # Exactly the pre-change shape: version 2, no cleanup slot, and an
        # entry for a PR whose merge landed before the upgrade.
        self._write_state(
            {
                "version": 2,
                "attempt_counter": 4,
                "prs": {
                    "42": {
                        "approved_head": self.head_sha,
                        "last_rereviewed_head": None,
                        "consecutive_failures": 0,
                        "retry_after_attempt": 0,
                        "last_attempt": 4,
                        "last_error": None,
                    }
                },
            }
        )
        merged = self._base_pr_json()
        merged["state"] = "MERGED"
        self.fake.script("gh", ["pr", "view", "42"], stdout=json.dumps(merged))
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")
        self.fake.script("gh", ["pr", "list"], stdout=json.dumps([]))

        self._run_loop()

        final = self._read_state()
        self.assertEqual(final["version"], drain_prs.STATE_VERSION)
        # The counter is the pass clock every cooldown is denominated in, so
        # one pass advances it by exactly one whether or not it selected a PR.
        self.assertEqual(final["attempt_counter"], 5)
        self.assertNotIn("42", final["prs"])
        # The in-flight merge was completed rather than forgotten...
        self.assertEqual(len(self._issue_close_calls(99)), 1)
        self.assertFalse(self.feature_wt.exists())
        self.assertFalse(git_ref_exists(self.main, "refs/heads/issue-99-demo"))
        self.assertFalse(git_ref_exists(self.bare, "refs/heads/issue-99-demo"))
        self.assertEqual(
            run_git(["rev-parse", "master"], cwd=self.main), self.merge_commit_sha
        )
        # ...without merging anything a second time.
        self.assertEqual(len(self._pr_merge_calls()), 0)

    def _assert_nothing_was_cleaned_up(self):
        self.assertEqual(len(self._pr_merge_calls()), 0)
        self.assertEqual(self._issue_close_calls(99), [])
        self.assertTrue(self.feature_wt.exists())
        self.assertTrue(git_ref_exists(self.main, "refs/heads/issue-99-demo"))
        self.assertTrue(git_ref_exists(self.bare, "refs/heads/issue-99-demo"))
        self.assertNotEqual(
            run_git(["rev-parse", "master"], cwd=self.main), self.merge_commit_sha
        )
        self.assertEqual(self._incidents(), [])

    def test_dry_run_writes_no_state_file_and_cleans_up_nothing(self):
        self._script_pr_view()
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.assertFalse(self.state_path.exists())

        with self._drainer():
            _, state = self._run_process_pr(dry_run=True)

        self.assertFalse(self.state_path.exists())
        self.assertIn("42", state["prs"])
        self.assertIsNone(state["prs"]["42"]["cleanup"])
        self._assert_nothing_was_cleaned_up()

    def test_dry_run_leaves_an_existing_state_file_byte_for_byte(self):
        self._write_state(
            {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 0,
                "prs": {"42": self._entry(self.head_sha)},
            }
        )
        before = self.state_path.read_bytes()
        self._script_pr_view()
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["pr", "list"], stdout=json.dumps([]))

        self._run_loop(dry_run=True)

        self.assertEqual(self.state_path.read_bytes(), before)
        self._assert_nothing_was_cleaned_up()


class StopCleanupPassTests(PostMergeCleanupFixture):
    """Issue #216: an intentional stop works the recorded post-merge cleanup
    one last time, under a budget, before it lets the process go.

    The drainer holds the repository run lock for its whole lifetime, so it is
    the only thing that can discharge these obligations while it is alive, and
    nothing discharges them once it exits -- the next start may be days away.
    So the stop spends a bounded slice of its own shutdown on exactly the debt
    already recorded, and leaves whatever it cannot finish recorded, projected
    and escalated exactly as it found it.
    """

    def _full_cleanup_record(self):
        """PR #42 owing all five obligations: the linked issue, the worktree,
        both head branches, and the fast-forward."""
        return drain_prs.plan_cleanup(
            {
                "number": 42,
                "headRefName": "issue-99-demo",
                "headRefOid": self.head_sha,
                "closingIssuesReferences": [
                    {
                        "number": 99,
                        "repository": {"owner": {"login": "acme"}, "name": "widgets"},
                    }
                ],
            }
        )

    def _state_owing(self, **entries):
        self._write_state(
            {
                "version": drain_prs.STATE_VERSION,
                "attempt_counter": 0,
                "prs": entries,
            }
        )

    def _stop(self, **kwargs):
        with self._drainer():
            return drain_prs.discharge_recorded_cleanup(
                self.ctx, dry_run=False, **kwargs
            )

    def _gh_calls(self, *prefix):
        return [
            call
            for call in self.fake.calls("gh")
            if call["args"][: len(prefix)] == list(prefix)
        ]

    def test_a_stop_discharges_the_recorded_debt_and_drops_the_record(self):
        self._state_owing(
            **{"42": self._entry(self.head_sha, cleanup=self._full_cleanup_record())}
        )
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

        discharged = self._stop()

        self.assertEqual(discharged, 5)
        self.assertEqual(len(self._issue_close_calls(99)), 1)
        self.assertFalse(self.feature_wt.exists())
        self.assertFalse(git_ref_exists(self.main, "refs/heads/issue-99-demo"))
        self.assertFalse(git_ref_exists(self.bare, "refs/heads/issue-99-demo"))
        self.assertEqual(
            run_git(["rev-parse", "master"], cwd=self.main), self.merge_commit_sha
        )
        # The record is the only thing that says these are owed, so a fully
        # discharged one is dropped -- durably, before the lock is released.
        self.assertNotIn("42", self._read_state()["prs"])

    def test_the_pass_never_reads_a_pull_request_to_find_work(self):
        self._state_owing(
            **{"42": self._entry(self.head_sha, cleanup=self._full_cleanup_record())}
        )
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

        self._stop()

        # Not `gh pr view`, and not the queue refresh either: a stop discharges
        # what a merge recorded, and starts no new per-pull-request work.
        self.assertEqual(self._gh_calls("pr", "view"), [])
        self.assertEqual(self._gh_calls("pr", "list"), [])
        self.assertEqual(self._gh_calls("pr", "merge"), [])

    def test_an_entry_owing_nothing_is_left_entirely_alone(self):
        # An approved pull request still in the queue with no recorded
        # cleanup: learning anything about it means reading it, which is the
        # per-pull-request work a stop must not start.
        self._state_owing(**{"42": self._entry(self.head_sha)})
        before = self.state_path.read_bytes()

        self.assertEqual(self._stop(), 0)

        self.assertEqual(self.fake.calls("gh"), [])
        self.assertEqual(self.state_path.read_bytes(), before)

    def test_a_stop_owing_nothing_costs_the_repository_nothing(self):
        # No queue state at all, as a repository that has never merged has.
        self.assertFalse(self.state_path.exists())

        self.assertEqual(self._stop(), 0)

        self.assertEqual(self.fake.calls("gh"), [])
        # Not created either: a stop owing nothing leaves the repository
        # exactly as it found it.
        self.assertFalse(self.state_path.exists())

    def test_a_failed_pass_keeps_the_debt_its_incident_and_the_stop(self):
        stuck = self._stuck_cleanup_record()
        stuck["failed_passes"] = drain_prs.CLEANUP_PASSES_BEFORE_INCIDENT
        with self._drainer():
            incident = drain_prs_service.record_cleanup_incident(
                repo_path=self.ctx.path,
                pull_request=7,
                steps=["closing acme/widgets#7"],
                error="gh: server error",
            )
        stuck["incident"] = incident["incident_id"]
        self._state_owing(**{"7": self._entry("b" * 40, cleanup=stuck)})
        self.fake.script(
            "gh", ["issue", "view", "7"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script(
            "gh", ["issue", "close", "7"], stderr="gh: server error", exit_code=1
        )

        # A stop that cannot discharge everything is still a successful stop.
        self.assertEqual(self._stop(), 0)

        record = self._read_state()["prs"]["7"]["cleanup"]
        self.assertEqual(
            record["pending"],
            [{"kind": "issue", "repo": "acme/widgets", "number": 7}],
        )
        self.assertIn("acme/widgets#7", record["last_error"])
        incidents = self._incidents()
        self.assertEqual(len(incidents), 1)
        self.assertEqual(incidents[0]["status"], "open")

    def test_the_pass_that_finishes_the_debt_resolves_its_incident(self):
        stuck = self._stuck_cleanup_record()
        stuck["failed_passes"] = drain_prs.CLEANUP_PASSES_BEFORE_INCIDENT
        with self._drainer():
            incident = drain_prs_service.record_cleanup_incident(
                repo_path=self.ctx.path,
                pull_request=7,
                steps=["closing acme/widgets#7"],
                error="gh: server error",
            )
        stuck["incident"] = incident["incident_id"]
        self._state_owing(**{"7": self._entry("b" * 40, cleanup=stuck)})
        self.fake.script(
            "gh", ["issue", "view", "7"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "7"], stdout="")

        self.assertEqual(self._stop(), 1)

        self.assertNotIn("7", self._read_state()["prs"])
        incidents = self._incidents()
        self.assertEqual(len(incidents), 1)
        # Self-clearing on the same path any other completing pass uses: an
        # incident outliving the debt would be a stop that lied about it.
        self.assertEqual(incidents[0]["status"], "resolved")

    def test_an_already_satisfied_obligation_counts_as_discharged(self):
        # The linked issue is already closed, by GitHub's own closing keyword
        # or by hand. Verifying that is discharging it, and the stop says so.
        record = self._full_cleanup_record()
        record["pending"] = [
            item for item in record["pending"] if item["kind"] == "issue"
        ]
        self._state_owing(**{"42": self._entry(self.head_sha, cleanup=record)})
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "CLOSED"})
        )

        self.assertEqual(self._stop(), 1)

        self.assertEqual(self._issue_close_calls(99), [])
        self.assertNotIn("42", self._read_state()["prs"])

    def test_a_wedged_command_leaves_its_obligation_rather_than_the_stop(self):
        record = self._full_cleanup_record()
        record["pending"] = [
            item for item in record["pending"] if item["kind"] == "issue"
        ]
        self._state_owing(**{"42": self._entry(self.head_sha, cleanup=record)})
        # Far longer than any budget a stop could give it: only a caller that
        # bounds the command itself returns from this.
        self.fake.script(
            "gh",
            ["issue", "view", "99"],
            stdout=json.dumps({"state": "OPEN"}),
            sleep_seconds=60,
        )

        with mock.patch.object(
            drain_prs, "SHUTDOWN_MIN_COMMAND_TIMEOUT_SECONDS", 0.25
        ):
            started = time.monotonic()
            discharged = self._stop(budget_seconds=0.25)
            elapsed = time.monotonic() - started

        self.assertEqual(discharged, 0)
        self.assertLess(elapsed, 20)
        # Outstanding, not lost: the next start retries exactly this.
        self.assertEqual(
            self._read_state()["prs"]["42"]["cleanup"]["pending"],
            [{"kind": "issue", "repo": "acme/widgets", "number": 99}],
        )
        self.assertIn("timed out", self._read_state()["prs"]["42"]["cleanup"]["last_error"])

    def test_a_spent_budget_stops_the_obligations_of_one_pull_request_too(self):
        # The bound is on obligations, not on pull requests: the steps after
        # the one that burned the budget must not be started either, however
        # briefly each would take to time out.
        record = self._stuck_cleanup_record(7, 5)
        self._state_owing(**{"7": self._entry("b" * 40, cleanup=record)})
        self.fake.script(
            "gh",
            ["issue", "view", "7"],
            stdout=json.dumps({"state": "OPEN"}),
            sleep_seconds=60,
        )
        self.fake.script(
            "gh", ["issue", "view", "5"], stdout=json.dumps({"state": "OPEN"})
        )

        with mock.patch.object(
            drain_prs, "SHUTDOWN_MIN_COMMAND_TIMEOUT_SECONDS", 0.25
        ):
            self.assertEqual(self._stop(budget_seconds=0.25), 0)

        self.assertEqual(self._gh_calls("issue", "view", "5"), [])
        # Both are still owed, in their original order.
        self.assertEqual(
            [item["number"] for item in self._read_state()["prs"]["7"]["cleanup"]["pending"]],
            [7, 5],
        )

    def test_an_unattempted_obligation_is_not_counted_as_a_failed_pass(self):
        # A step nothing started has resisted nothing, so it must not push the
        # record toward the incident threshold.
        record = self._stuck_cleanup_record(7, 5)
        record["pending"] = [record["pending"][1]]
        self._state_owing(**{"7": self._entry("b" * 40, cleanup=record)})
        self.fake.script(
            "gh", ["issue", "view", "5"], stdout=json.dumps({"state": "OPEN"})
        )

        with self._drainer():
            with drain_prs.command_deadline(time.monotonic() - 1):
                finished = drain_prs.advance_pending_cleanup(
                    self.ctx, record, dry_run=False
                )

        self.assertFalse(finished)
        self.assertEqual(self.fake.calls("gh"), [])
        self.assertEqual(record["failed_passes"], 0)
        self.assertIsNone(record["last_error"])
        self.assertIsNone(record["incident"])
        self.assertEqual(self._incidents(), [])

    def test_a_spent_budget_starts_no_further_obligation(self):
        first = self._stuck_cleanup_record()
        second = self._full_cleanup_record()
        second["pending"] = [
            item for item in second["pending"] if item["kind"] == "issue"
        ]
        self._state_owing(
            **{
                "7": self._entry("b" * 40, cleanup=first),
                "42": self._entry(self.head_sha, cleanup=second),
            }
        )
        self.fake.script(
            "gh",
            ["issue", "view", "7"],
            stdout=json.dumps({"state": "OPEN"}),
            sleep_seconds=60,
        )
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

        with mock.patch.object(
            drain_prs, "SHUTDOWN_MIN_COMMAND_TIMEOUT_SECONDS", 0.25
        ):
            self.assertEqual(self._stop(budget_seconds=0.25), 0)

        # PR #7 burned the whole budget, so PR #42's obligation was never
        # started -- it stays owed rather than being attempted past the bound.
        self.assertEqual(self._gh_calls("issue", "view", "99"), [])
        self.assertEqual(
            self._read_state()["prs"]["42"]["cleanup"]["pending"],
            [{"kind": "issue", "repo": "acme/widgets", "number": 99}],
        )

    def _owing_one_issue_close(self):
        """PR #7 owing exactly one issue close, scripted to succeed."""
        self._state_owing(
            **{"7": self._entry("b" * 40, cleanup=self._stuck_cleanup_record())}
        )
        self.fake.script(
            "gh", ["issue", "view", "7"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "7"], stdout="")

    def test_an_interrupt_reading_the_state_writes_nothing_and_returns_zero(self):
        # Issue #281: the state read is outside the pass's own handler, so an
        # interrupt landing here escaped the function -- and on a stop, that
        # is a second Ctrl-C escaping from inside the handler containing the
        # first. Nothing was attempted, so nothing is written either.
        self._owing_one_issue_close()
        before = self.state_path.read_bytes()

        with mock.patch.object(
            drain_prs, "load_drain_state", side_effect=KeyboardInterrupt
        ):
            self.assertEqual(self._stop(), 0)

        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(self.fake.calls("gh"), [])

    def test_an_interrupt_choosing_what_is_owed_writes_nothing_either(self):
        # The window between the state read and the first obligation: the
        # selection and the opening log are equally outside the old handler.
        self._owing_one_issue_close()
        before = self.state_path.read_bytes()

        with mock.patch.object(
            drain_prs, "recorded_cleanup_prs", side_effect=KeyboardInterrupt
        ):
            self.assertEqual(self._stop(), 0)

        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(self.fake.calls("gh"), [])

    def test_an_interrupt_inside_the_pass_s_own_diagnostic_is_contained(self):
        # `log` prints and then opens a file, so a second signal can land in
        # the very line reporting the first. A handler that reports with `log`
        # is therefore still a handler an interrupt escapes from.
        self._owing_one_issue_close()
        before = self.state_path.read_bytes()

        with mock.patch.object(drain_prs, "log", side_effect=KeyboardInterrupt):
            self.assertEqual(self._stop(), 0)

        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(self.fake.calls("gh"), [])

    def test_an_interrupt_working_an_obligation_keeps_what_it_finished(self):
        # Contained where it lands: the pass starts nothing further, and what
        # it already discharged is still persisted and still reported.
        second = self._full_cleanup_record()
        second["pending"] = [
            item for item in second["pending"] if item["kind"] == "issue"
        ]
        self._state_owing(
            **{
                "7": self._entry("b" * 40, cleanup=self._stuck_cleanup_record()),
                "42": self._entry(self.head_sha, cleanup=second),
            }
        )
        self.fake.script(
            "gh", ["issue", "view", "7"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "7"], stdout="")
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")
        real_cleanup = drain_prs.complete_pending_cleanup

        def interrupt_the_second_pull_request(ctx, state, number, *, dry_run):
            if number == 42:
                raise KeyboardInterrupt
            return real_cleanup(ctx, state, number, dry_run=dry_run)

        with mock.patch.object(
            drain_prs,
            "complete_pending_cleanup",
            side_effect=interrupt_the_second_pull_request,
        ):
            self.assertEqual(self._stop(), 1)

        state = self._read_state()
        self.assertEqual(len(self._issue_close_calls(7)), 1)
        self.assertNotIn("7", state["prs"])
        # PR #42's obligation was never started, so it stays owed for the
        # next start rather than being lost with the interrupt.
        self.assertEqual(self._issue_close_calls(99), [])
        self.assertEqual(
            state["prs"]["42"]["cleanup"]["pending"],
            [{"kind": "issue", "repo": "acme/widgets", "number": 99}],
        )

    def test_an_interrupt_persisting_leaves_the_prior_state_intact(self):
        self._owing_one_issue_close()
        before = self.state_path.read_bytes()

        with mock.patch.object(
            drain_prs, "save_drain_state", side_effect=KeyboardInterrupt
        ):
            # Still what the pass discharged before the write was interrupted.
            self.assertEqual(self._stop(), 1)

        self.assertEqual(len(self._issue_close_calls(7)), 1)
        # Byte-for-byte, with no temporary beside it: the next start
        # re-verifies exactly the debt this pass could not record discharging.
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(
            [
                path
                for path in self.state_path.parent.glob("drain_prs_state.*")
                if path != self.state_path
            ],
            [],
        )

    def test_a_non_interrupt_failure_persisting_is_contained_too(self):
        # The promise is "never raises", not "never raises KeyboardInterrupt":
        # a TypeError out of the state write loses a `--pr` caller's one
        # result document in exactly the same way.
        self._owing_one_issue_close()
        before = self.state_path.read_bytes()

        with mock.patch.object(
            drain_prs,
            "save_drain_state",
            side_effect=TypeError("Object of type set is not JSON serializable"),
        ):
            self.assertEqual(self._stop(), 1)

        self.assertEqual(self.state_path.read_bytes(), before)

    def test_a_non_interrupt_failure_reading_the_state_is_contained_too(self):
        # `load_drain_state` answers a DrainError itself; anything else its
        # migration raises used to end the stop.
        self._owing_one_issue_close()
        before = self.state_path.read_bytes()

        with mock.patch.object(
            drain_prs, "load_drain_state", side_effect=ValueError("unmigratable")
        ):
            self.assertEqual(self._stop(), 0)

        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(self.fake.calls("gh"), [])


class QueueOrderTests(ProcessPrFixture):
    """Issue #204: one polling pass walks the approved queue lowest number
    first and advances at most one candidate.

    Fair rotation used to pick the least-recently-attempted pull request, so
    every pass updated a different behind branch and started CI across the
    whole queue before the first candidate was ready to merge. Here a durable
    block on one candidate is skipped, and anything still in flight on it is a
    barrier every later pull request waits behind.
    """

    def setUp(self):
        super().setUp()
        self.incident_dir = self.root / "incidents"
        self.incident_dir.mkdir()
        self.drainer_log_dir = self.root / "drainer-logs"
        self.drainer_log_dir.mkdir()
        self.state_path = drain_prs.drain_state_path(self.ctx)

    @contextlib.contextmanager
    def _drainer(self):
        with (
            mock.patch.dict(os.environ, self.fake.environ_overrides()),
            mock.patch.object(drain_prs_service, "RUNTIME_ROOT", self.root),
            mock.patch.object(drain_prs_service, "LOG_ROOT", self.drainer_log_dir),
            mock.patch.object(drain_prs_service, "NTFY_URL", None),
        ):
            yield

    def _gates(self):
        return drain_prs.GateConfig(
            required_ci_check=drain_prs.DEFAULT_REQUIRED_CI_CHECK,
            required_review_check=drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
        )

    def _entry(self, head, **extra):
        entry = {
            "approved_head": head,
            "last_rereviewed_head": None,
            "consecutive_failures": 0,
            "retry_after_attempt": 0,
            "last_attempt": 0,
            "last_error": None,
            "ci_rerun_head": None,
            "ci_rerun_attempts": 0,
            "ci_rerun_active": False,
            "ci_rerun_exhausted_head": None,
            "cleanup": None,
        }
        entry.update(extra)
        return entry

    def _write_state(self, prs, *, attempt_counter=0, active_pr=None):
        self.state_path.write_text(
            json.dumps(
                {
                    "version": drain_prs.STATE_VERSION,
                    "attempt_counter": attempt_counter,
                    "active_pr": active_pr,
                    "prs": prs,
                },
                indent=2,
            ),
            encoding="utf-8",
        )

    def _read_state(self):
        return json.loads(self.state_path.read_text(encoding="utf-8"))

    def _run_loop(self, *, dry_run=False):
        with self._drainer():
            drain_prs.loop(
                self.ctx,
                interval=0,
                once=True,
                dry_run=dry_run,
                gates=self._gates(),
            )

    def _queued(self, number, head):
        return {
            "number": number,
            "labels": [{"name": drain_prs.APPROVE_LABEL}],
            "isDraft": False,
            "headRefOid": head,
        }

    def _script_pr_list(self, *batches):
        """One `gh pr list` response per polling pass, consumed in order."""
        for batch in batches:
            self.fake.script("gh", ["pr", "list"], stdout=json.dumps(batch))

    def _other_pr_json(self, number, head, **overrides):
        """An approved pull request that is not the fixture's mergeable #42.

        It closes no issue, so a scenario that reached a merge here would be
        obvious rather than quietly cleaning up #42's worktree a second time.
        """
        pr_json = self._base_pr_json()
        pr_json.update(
            {
                "number": number,
                "url": f"https://github.com/acme/widgets/pull/{number}",
                "headRefOid": head,
                "headRefName": f"issue-{number}-other",
                "closingIssuesReferences": [],
            }
        )
        pr_json.update(overrides)
        return pr_json

    def _script_pr(self, number, *snapshots):
        for snapshot in snapshots:
            self.fake.script(
                "gh", ["pr", "view", str(number)], stdout=json.dumps(snapshot)
            )

    def _script_merge_of_42(self):
        self._script_pr_view()
        self.fake.script("gh", ["pr", "merge", "42"], stdout="")
        self.fake.script(
            "gh", ["issue", "view", "99"], stdout=json.dumps({"state": "OPEN"})
        )
        self.fake.script("gh", ["issue", "close", "99"], stdout="")

    def _pending_ci(self):
        return [
            {
                "name": drain_prs.DEFAULT_REQUIRED_CI_CHECK,
                "status": "IN_PROGRESS",
                "conclusion": None,
                "startedAt": "2026-07-18T00:00:00Z",
            },
            {
                "name": drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
                "status": "COMPLETED",
                "conclusion": "SUCCESS",
                "completedAt": "2026-07-18T00:00:01Z",
            },
        ]

    def _failed_ci(self):
        return [
            {
                "name": drain_prs.DEFAULT_REQUIRED_CI_CHECK,
                "status": "COMPLETED",
                "conclusion": "FAILURE",
                "completedAt": "2026-07-18T00:00:00Z",
                "detailsUrl": "https://github.com/acme/widgets/actions/runs/9911",
            },
            {
                "name": drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK,
                "status": "COMPLETED",
                "conclusion": "SUCCESS",
                "completedAt": "2026-07-18T00:00:01Z",
            },
        ]

    def _stale_approval_ok(self):
        return self._base_pr_json()["statusCheckRollup"] + [
            {
                "name": drain_prs.STALE_APPROVAL_CHECK,
                "status": "COMPLETED",
                "conclusion": "SUCCESS",
                "completedAt": "2026-07-18T00:00:02Z",
            }
        ]

    def _views_of(self, number):
        return [
            call
            for call in self.fake.calls("gh")
            if call["args"][:3] == ["pr", "view", str(number)]
        ]

    def _advancing_gh_calls(self):
        """Every call that moves a pull request towards merging.

        Requirement 8 bounds a pass to one of these in total; requirement 4
        forbids any of them for a pull request behind a barrier.
        """
        found = []
        for call in self.fake.calls("gh"):
            args = call["args"]
            if args[:2] in (["pr", "merge"], ["pr", "edit"], ["pr", "ready"]):
                found.append(args)
            elif args[:2] == ["run", "rerun"]:
                found.append(args)
            elif args[:1] == ["api"] and any("update-branch" in arg for arg in args):
                found.append(args)
        return found

    def _update_branch_calls(self):
        return [
            args
            for args in self._advancing_gh_calls()
            if args[:1] == ["api"] and any("update-branch" in arg for arg in args)
        ]

    def test_the_lowest_number_goes_first_whatever_last_attempt_says(self):
        # Fair rotation would have taken #42: it was attempted least recently,
        # and it is the one that would merge. Lowest-number-first stops at #7.
        self._script_pr(7, self._other_pr_json(7, "b" * 40, statusCheckRollup=self._pending_ci()))
        self._script_merge_of_42()
        self._script_pr_list([self._queued(7, "b" * 40), self._queued(42, self.head_sha)])
        self._write_state(
            {
                "7": self._entry("b" * 40, last_attempt=9),
                "42": self._entry(self.head_sha, last_attempt=1),
            },
            attempt_counter=9,
        )

        self._run_loop()

        self.assertEqual(self._advancing_gh_calls(), [])
        self.assertEqual(self._read_state()["active_pr"], 7)

    def test_a_pending_candidate_stops_the_pass_before_every_later_one(self):
        self._script_pr(7, self._other_pr_json(7, "b" * 40, statusCheckRollup=self._pending_ci()))
        self._script_merge_of_42()
        self._script_pr_list([self._queued(7, "b" * 40), self._queued(42, self.head_sha)])

        self._run_loop()

        # #42 is green, mergeable, and never read at all: the pass ended at the
        # barrier rather than walking past it.
        self.assertEqual(self._views_of(42), [])
        self.assertEqual(self._advancing_gh_calls(), [])
        self.assertEqual(self._read_state()["active_pr"], 7)

    def test_a_conflicting_lowest_candidate_is_skipped_and_the_next_merges(self):
        self._script_pr(
            7,
            self._other_pr_json(
                7, "b" * 40, mergeable="CONFLICTING", mergeStateStatus="DIRTY"
            ),
        )
        self._script_merge_of_42()
        self._script_pr_list([self._queued(7, "b" * 40), self._queued(42, self.head_sha)])

        self._run_loop()

        merges = [
            call for call in self.fake.calls("gh") if call["args"][:2] == ["pr", "merge"]
        ]
        self.assertEqual([call["args"][2] for call in merges], ["42"])
        incidents = [
            json.loads(path.read_text(encoding="utf-8"))
            for path in sorted(self.incident_dir.glob("incident-*.json"))
        ]
        self.assertEqual([incident["pull_request"] for incident in incidents], [7])
        state = self._read_state()
        self.assertIsNone(state["active_pr"])
        # A skipped candidate is not a failed attempt, so it earns no cooldown.
        self.assertEqual(state["prs"]["7"]["consecutive_failures"], 0)

    def test_an_exhausted_failed_check_candidate_is_skipped_and_the_next_merges(self):
        self._script_pr(
            7, self._other_pr_json(7, "b" * 40, statusCheckRollup=self._failed_ci())
        )
        self._script_merge_of_42()
        self._script_pr_list([self._queued(7, "b" * 40), self._queued(42, self.head_sha)])
        self._write_state(
            {
                "7": self._entry(
                    "b" * 40,
                    ci_rerun_head="b" * 40,
                    ci_rerun_attempts=drain_prs.MAX_CI_RERUN_ATTEMPTS,
                ),
                "42": self._entry(self.head_sha),
            }
        )

        self._run_loop()

        # No rerun was requested for #7, and #42 merged in the same pass.
        self.assertEqual(
            [args for args in self._advancing_gh_calls() if args[:2] == ["run", "rerun"]],
            [],
        )
        merges = [
            call for call in self.fake.calls("gh") if call["args"][:2] == ["pr", "merge"]
        ]
        self.assertEqual([call["args"][2] for call in merges], ["42"])
        self.assertEqual(self._read_state()["prs"]["7"]["ci_rerun_exhausted_head"], "b" * 40)

    def test_an_ineligible_candidate_is_skipped_and_the_next_merges(self):
        self._script_pr(
            7, self._other_pr_json(7, "b" * 40, state="CLOSED")
        )
        self._script_merge_of_42()
        self._script_pr_list([self._queued(7, "b" * 40), self._queued(42, self.head_sha)])

        self._run_loop()

        merges = [
            call for call in self.fake.calls("gh") if call["args"][:2] == ["pr", "merge"]
        ]
        self.assertEqual([call["args"][2] for call in merges], ["42"])

    def test_a_requested_ci_rerun_is_a_barrier_like_a_pending_check(self):
        self._script_pr(
            7, self._other_pr_json(7, "b" * 40, statusCheckRollup=self._failed_ci())
        )
        self.fake.script("gh", ["run", "rerun", "9911"], stdout="")
        self._script_merge_of_42()
        self._script_pr_list([self._queued(7, "b" * 40), self._queued(42, self.head_sha)])

        self._run_loop()

        self.assertEqual(
            [args[:3] for args in self._advancing_gh_calls()],
            [["run", "rerun", "9911"]],
        )
        self.assertEqual(self._views_of(42), [])
        state = self._read_state()
        self.assertEqual(state["active_pr"], 7)
        self.assertTrue(state["prs"]["7"]["ci_rerun_active"])

    def test_the_short_rerun_cadence_follows_the_active_candidate(self):
        # A pass that ends on a requested rerun still polls again quickly. The
        # cadence reads the lane owner rather than whichever candidate the pass
        # happened to stop at, so it survives the queue walking several first.
        self._script_pr(
            7, self._other_pr_json(7, "b" * 40, statusCheckRollup=self._failed_ci())
        )
        self.fake.script("gh", ["run", "rerun", "9911"], stdout="")
        self._script_merge_of_42()
        self._script_pr_list([self._queued(7, "b" * 40), self._queued(42, self.head_sha)])
        slept = []

        def stop_after_one_pass(seconds):
            slept.append(seconds)
            raise KeyboardInterrupt

        with self._drainer(), mock.patch("time.sleep", stop_after_one_pass):
            with self.assertRaises(KeyboardInterrupt):
                drain_prs.loop(
                    self.ctx,
                    interval=3600,
                    once=False,
                    dry_run=False,
                    gates=self._gates(),
                )

        self.assertEqual(slept, [drain_prs.CI_RERUN_INTERVAL_SECONDS])

    def test_a_branch_update_is_the_whole_pass_and_keeps_the_lane(self):
        behind = self._other_pr_json(7, "b" * 40, mergeStateStatus="BEHIND")
        updated = self._other_pr_json(
            7, "c" * 40, statusCheckRollup=self._stale_approval_ok()
        )
        settled = self._other_pr_json(
            7, "c" * 40, statusCheckRollup=self._pending_ci()
        )
        # In order: the pass's own read, then the two reads the update's policy
        # wait makes. The second of those is what records the new approved
        # head -- the payload showing the successful policy run, the retained
        # label, and the head together. Every later read -- this pass's and
        # the next two passes' -- repeats the last entry, a settled head whose
        # replacement CI is still running.
        self._script_pr(7, behind, updated, updated, settled)
        self.fake.script(
            "gh",
            ["api", "-X", "PUT", "repos/acme/widgets/pulls/7/update-branch"],
            stdout="",
        )
        self._script_merge_of_42()
        queue = [self._queued(7, "b" * 40), self._queued(42, self.head_sha)]
        settled_queue = [self._queued(7, "c" * 40), self._queued(42, self.head_sha)]
        self._script_pr_list(queue, settled_queue, settled_queue)

        for _ in range(3):
            self._run_loop()

        # One branch update in three passes, and nothing else advanced.
        self.assertEqual(len(self._update_branch_calls()), 1)
        self.assertEqual(len(self._advancing_gh_calls()), 1)
        state = self._read_state()
        self.assertEqual(state["active_pr"], 7)
        self.assertEqual(state["prs"]["7"]["approved_head"], "c" * 40)

    def test_a_newly_eligible_lower_number_does_not_preempt_the_lane(self):
        self._script_pr(7, self._other_pr_json(7, "b" * 40, statusCheckRollup=self._pending_ci()))
        self._script_merge_of_42()
        self._script_pr_list(
            [self._queued(7, "b" * 40)],
            [self._queued(5, "d" * 40), self._queued(7, "b" * 40)],
        )

        # Each loop() reloads the state file, so the second pass is exactly
        # what a restarted drainer does.
        self._run_loop()
        self.assertEqual(self._read_state()["active_pr"], 7)
        self._run_loop()

        self.assertEqual(self._views_of(5), [])
        self.assertEqual(self._advancing_gh_calls(), [])
        self.assertEqual(self._read_state()["active_pr"], 7)

    def test_releasing_a_blocked_lane_restarts_at_the_lowest_number(self):
        self._script_pr(7, self._other_pr_json(7, "b" * 40, statusCheckRollup=self._pending_ci()))
        self._script_pr(77, self._other_pr_json(77, "e" * 40, state="CLOSED"))
        self._script_merge_of_42()
        self._script_pr_list(
            [
                self._queued(7, "b" * 40),
                self._queued(42, self.head_sha),
                self._queued(77, "e" * 40),
            ]
        )
        self._write_state(
            {
                "7": self._entry("b" * 40),
                "42": self._entry(self.head_sha),
                "77": self._entry("e" * 40),
            },
            active_pr=77,
        )

        self._run_loop()

        # #77 held the lane, lost it by leaving the queue, and selection went
        # back to the lowest number rather than on to #42.
        examined = [
            call["args"][2]
            for call in self.fake.calls("gh")
            if call["args"][:2] == ["pr", "view"]
        ]
        self.assertEqual(examined[-1], "7")
        self.assertEqual(self._advancing_gh_calls(), [])
        self.assertEqual(self._read_state()["active_pr"], 7)

    def test_an_all_blocked_queue_mutates_nothing_and_waits_for_a_later_pass(self):
        self._script_pr(7, self._other_pr_json(7, "b" * 40, statusCheckRollup=self._pending_ci()))
        self._script_merge_of_42()
        queue = [self._queued(7, "b" * 40), self._queued(42, self.head_sha)]
        self._script_pr_list(queue, queue, queue)
        # #7 is cooling down until pass 3 and #42's reruns are exhausted for
        # its current head, so passes 1 and 2 have nothing they may touch.
        self._write_state(
            {
                "7": self._entry("b" * 40, consecutive_failures=2, retry_after_attempt=3),
                "42": self._entry(self.head_sha, ci_rerun_exhausted_head=self.head_sha),
            }
        )

        for _ in range(2):
            self._run_loop()
            state = self._read_state()
            self.assertEqual(self._advancing_gh_calls(), [])
            # `last_attempt` is stamped by the pass on each candidate it gives
            # a turn to, so a zero means the pass gave none to anybody.
            self.assertEqual(state["prs"]["7"]["last_attempt"], 0)
            self.assertEqual(state["prs"]["42"]["last_attempt"], 0)
            self.assertIsNone(state["active_pr"])

        # The cooldown expired on the pass clock alone: no other pull request
        # was attempted in the meantime, and none could have been.
        self._run_loop()

        state = self._read_state()
        self.assertEqual(state["prs"]["7"]["last_attempt"], 3)
        self.assertEqual(state["prs"]["42"]["last_attempt"], 0)
        self.assertEqual(self._advancing_gh_calls(), [])
        self.assertEqual(state["active_pr"], 7)

    def test_a_dry_run_makes_the_same_decisions_and_mutates_nothing(self):
        self._script_pr(
            7,
            self._other_pr_json(
                7, "b" * 40, mergeable="CONFLICTING", mergeStateStatus="DIRTY"
            ),
        )
        self._script_merge_of_42()
        self._script_pr_list([self._queued(7, "b" * 40), self._queued(42, self.head_sha)])

        self._run_loop(dry_run=True)

        # #7 was skipped and #42 was reached and judged mergeable, with no
        # merge, no incident, and no queue-state file written.
        self.assertTrue(self._views_of(42))
        self.assertEqual(self._advancing_gh_calls(), [])
        self.assertEqual(list(self.incident_dir.glob("*.json")), [])
        self.assertFalse(self.state_path.exists())


if __name__ == "__main__":
    unittest.main()
