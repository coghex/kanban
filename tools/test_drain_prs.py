"""Focused tests for tools/drain_prs.py.

Covers the round-10 fix delegating parse_repo_slug to
kanban_config.parse_repository_name, so the drainer accepts the same
broader remote forms (ssh://, http://, git://, bare owner/name) the
dashboard's own parseRepositoryName does, not only
git@github.com:/https://github.com/; the round-13 fix making the spawned
agent prompts pass an explicit --repo to every gh command, instead of
relying on gh's own default-repository inference (which can target the
wrong repository in a checkout with more than one remote, even though
ctx.repo_slug itself was already resolved from the configured
remote_name); issue #123's removal of the automated merge-conflict
repair path; and issue #230's rule that a branch update carries
`reviewed:approve` forward only on a positive content-safe verdict.
"""

import contextlib
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

import drain_prs


class ParseRepoSlugTests(unittest.TestCase):
    def test_accepts_the_broader_remote_forms(self):
        self.assertEqual(
            drain_prs.parse_repo_slug("ssh://git@github.com/coghex/kanban.git"),
            "coghex/kanban",
        )
        self.assertEqual(drain_prs.parse_repo_slug("coghex/kanban"), "coghex/kanban")

    def test_raises_drain_error_on_an_unparseable_value(self):
        with self.assertRaises(drain_prs.DrainError):
            drain_prs.parse_repo_slug("not-a-repo")


def make_ctx(repo_slug="upstream-owner/kanban", remote_name="upstream"):
    return drain_prs.RepoContext(
        path=Path("/fake-repo"),
        repo_slug=repo_slug,
        repo_name="kanban",
        default_branch="main",
        remote_name=remote_name,
    )


class AgentPromptRepoScopingTests(unittest.TestCase):
    """A checkout configured with a non-default remote_name (e.g.
    remote_name=upstream selecting an upstream repo while "origin" still
    points at a fork) must not let gh's own default-repository inference
    silently target the fork inside these spawned-agent prompts."""

    def test_drain_rereview_prompt_requires_repo_on_every_gh_command(self):
        prompt = drain_prs.drain_rereview_prompt(make_ctx(), 89, "a" * 40)
        self.assertIn("--repo upstream-owner/kanban", prompt)
        self.assertIn("gh pr comment 89 --repo upstream-owner/kanban", prompt)
        self.assertIn("gh pr edit 89 --repo upstream-owner/kanban", prompt)


class ConflictRepairRemovalTests(unittest.TestCase):
    """Issue #123: the automated Codex/Claude conflict repair is gone rather
    than parked behind a flag, so nothing can re-enable a path that removed
    the approval label the review gate requires."""

    def test_the_conflict_repair_flag_is_rejected(self):
        argv = ["drain_prs.py", "--path", ".", "--no-conflict-repair"]
        with mock.patch.object(sys, "argv", argv):
            with contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    drain_prs.parse_args()

    def test_the_repair_entry_points_no_longer_exist(self):
        for name in (
            "repair_conflict_with_codex",
            "run_codex_conflict_agent",
            "run_claude_conflict_reviewer",
            "claude_conflict_review_prompt",
            "codex_conflict_prompt",
            "codex_conflict_fix_prompt",
            "verify_codex_conflict_push",
            "inspect_conflict_files",
            "remove_approval_label",
            "remove_approval_label_if_present",
            "mark_changes_requested",
        ):
            with self.subTest(name=name):
                self.assertFalse(hasattr(drain_prs, name))


OLD_HEAD = "a" * 40
MOVED_HEAD = "c" * 40
NEWER_HEAD = "d" * 40


def stale_check(conclusion, *, status="COMPLETED", started="2026-08-01T00:00:00Z"):
    return {
        "name": drain_prs.STALE_APPROVAL_CHECK,
        "status": status,
        "conclusion": conclusion,
        "startedAt": started,
    }


def pr_json(head, *, approved=True, checks=()):
    return {
        "number": 7,
        "headRefOid": head,
        "labels": [{"name": drain_prs.APPROVE_LABEL}] if approved else [],
        "statusCheckRollup": list(checks),
    }


class BranchUpdateCarriedApprovalTests(unittest.TestCase):
    """Issue #230: `dismiss-stale-approval` completing is not a verdict. Only
    the conjunction recover_stale_approval already trusts -- the run succeeded
    AND the label survived it -- says the update was content-safe, and every
    conjunct has to describe the same head."""

    def test_a_successful_run_that_kept_the_label_carries_approval(self):
        settled = pr_json(MOVED_HEAD, checks=[stale_check("SUCCESS")])
        self.assertTrue(
            drain_prs.branch_update_carried_approval(settled, MOVED_HEAD)
        )

    def test_a_successful_run_that_removed_the_label_carries_nothing(self):
        # The removal IS the negative decision: the push touched files this
        # pull request owns, so the reviewed content really did change.
        settled = pr_json(MOVED_HEAD, approved=False, checks=[stale_check("SUCCESS")])
        self.assertFalse(
            drain_prs.branch_update_carried_approval(settled, MOVED_HEAD)
        )

    def test_a_head_that_moved_again_cannot_inherit_the_earlier_verdict(self):
        # The label is attached and the earlier run is still the latest
        # non-skipped result, so only the head comparison separates the
        # commit that was decided about from the one that was pushed after.
        settled = pr_json(NEWER_HEAD, checks=[stale_check("SUCCESS")])
        self.assertFalse(
            drain_prs.branch_update_carried_approval(settled, MOVED_HEAD)
        )

    def test_no_check_and_an_unfinished_or_failed_one_carry_nothing(self):
        for label, checks in (
            ("missing", []),
            ("skipped only", [stale_check("SKIPPED")]),
            ("pending", [stale_check(None, status="IN_PROGRESS")]),
            ("failed", [stale_check("FAILURE")]),
        ):
            with self.subTest(check=label):
                settled = pr_json(MOVED_HEAD, checks=checks)
                self.assertFalse(
                    drain_prs.branch_update_carried_approval(settled, MOVED_HEAD)
                )


class WaitForBranchUpdatePolicyTests(unittest.TestCase):
    """What the wait hands back to update_branch, per settled observation."""

    def wait(self, *reads, timeout_seconds=0):
        ctx = make_ctx()
        with mock.patch.object(drain_prs, "get_pr", side_effect=list(reads)):
            with contextlib.redirect_stderr(io.StringIO()):
                return drain_prs.wait_for_branch_update_policy(
                    ctx,
                    7,
                    OLD_HEAD,
                    timeout_seconds=timeout_seconds,
                    poll_seconds=0,
                )

    def test_a_retained_label_returns_the_payload_that_kept_it(self):
        settled = pr_json(MOVED_HEAD, checks=[stale_check("SUCCESS")])
        self.assertEqual(
            self.wait(pr_json(MOVED_HEAD, checks=[stale_check("SUCCESS")]), settled),
            settled,
        )

    def test_a_removed_label_settles_the_wait_with_nothing_to_carry(self):
        self.assertIsNone(
            self.wait(
                pr_json(MOVED_HEAD, checks=[stale_check("SUCCESS")]),
                pr_json(MOVED_HEAD, approved=False, checks=[stale_check("SUCCESS")]),
            )
        )

    def test_a_head_pushed_between_the_two_reads_carries_nothing(self):
        self.assertIsNone(
            self.wait(
                pr_json(MOVED_HEAD, checks=[stale_check("SUCCESS")]),
                pr_json(NEWER_HEAD, checks=[stale_check("SUCCESS")]),
            )
        )

    def test_a_skipped_later_run_cannot_mask_an_earlier_success(self):
        # The masked sequence: the update-branch merge fired a synchronize the
        # job ran on, a second push fired one it skipped, and the skip leaves
        # the first run as the latest non-skipped result. That success speaks
        # for the merge commit, never for the push that followed it.
        masked = [
            stale_check("SUCCESS", started="2026-08-01T00:00:00Z"),
            stale_check("SKIPPED", started="2026-08-01T00:05:00Z"),
        ]
        self.assertIsNone(
            self.wait(
                pr_json(MOVED_HEAD, approved=False, checks=masked),
                pr_json(NEWER_HEAD, approved=False, checks=masked),
            )
        )

    def test_a_failed_policy_run_is_an_error_rather_than_a_carry(self):
        with self.assertRaises(drain_prs.DrainError):
            self.wait(pr_json(MOVED_HEAD, checks=[stale_check("FAILURE")]))

    def test_an_unsettled_policy_times_out_rather_than_carrying(self):
        for label, checks in (
            ("missing", []),
            ("skipped only", [stale_check("SKIPPED")]),
            ("pending", [stale_check(None, status="IN_PROGRESS")]),
        ):
            with self.subTest(check=label):
                with self.assertRaises(drain_prs.DrainError):
                    self.wait(pr_json(MOVED_HEAD, approved=False, checks=checks))


class ApprovalIsNeverAddedTests(unittest.TestCase):
    """Issue #230: the drainer reads approval verdicts and never writes one.
    No path applies `reviewed:approve`, so no repository can have one restored
    to a head its own review gate declined to keep it on."""

    def test_the_approval_label_adder_no_longer_exists(self):
        self.assertFalse(hasattr(drain_prs, "add_approval_label"))

    def test_no_source_line_adds_the_approval_label(self):
        source = Path(drain_prs.__file__).read_text(encoding="utf-8")
        self.assertNotIn("--add-label", source)


if __name__ == "__main__":
    unittest.main()
