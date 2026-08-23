"""Regression coverage for canonical PR approval clearing draft state.

Both packaged coordinators publish through their own copy of review_pr.py, so
the same behavioral contract is exercised against each copy. An approval must
mark a draft ready for review and verify the new state; changes requested must
leave draft state alone. Publication never restores the draft on its failure
path: rollback would need positive evidence that this invocation created the
ready transition, and no such evidence exists. The ready command's own draft
check and its mutation are not atomic, so neither a normal return nor a failed
one separates "ours applied" from "another actor marked it ready" -- both act
through the same credentials. Every failure after the ready command therefore
leaves the pull request's draft state exactly as it stands, clears only the
verdict labels, and says so without claiming anything was restored.

Each ready-command outcome -- a normal return, and a failure -- is staged twice
over world states the coordinator cannot tell apart, and both stagings assert
the same result.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parent.parent
COORDINATORS = {
    "codex": REPO_ROOT
    / "codex-plugin"
    / "plugins"
    / "kanban"
    / "skills"
    / "pr-review"
    / "scripts"
    / "review_pr.py",
    "claude": REPO_ROOT
    / "claude-plugin"
    / "plugins"
    / "kanban"
    / "scripts"
    / "review_pr.py",
}


def load_coordinator(brand: str):
    spec = importlib.util.spec_from_file_location(
        f"kanban_{brand}_draft_transition_review_pr", COORDINATORS[brand]
    )
    if spec is None or spec.loader is None:
        raise AssertionError(f"could not import {COORDINATORS[brand]}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ApprovedDraftTransitionTests(unittest.TestCase):
    def setUp(self):
        self.modules = {brand: load_coordinator(brand) for brand in COORDINATORS}

    @staticmethod
    def pr(*, draft: bool) -> dict:
        return {
            "number": 89,
            "url": "https://github.com/coghex/kanban/pull/89",
            "state": "OPEN",
            "headRefOid": "a" * 40,
            "body": "<!-- pr-origin:claude -->",
            "isCrossRepository": False,
            "isDraft": draft,
            "labels": [],
            "closingIssuesReferences": [],
        }

    @staticmethod
    def gate() -> dict:
        return {
            "approved": True,
            "allow_no_issue": False,
            "issues": [],
            "invalid_links": [],
            "checks": [],
            "key": "k1",
        }

    @staticmethod
    def review_result(verdict: str) -> dict:
        return {
            "reviewer": "codex",
            "display_name": "Codex",
            "verdict": verdict,
            "summary": "reviewed",
            "blocking_concerns": [],
            # Claude's coordinator binds nested-reviewer model claims; the
            # Codex copy harmlessly ignores this extra result member here.
            "model": "unspecified",
        }

    def publication_context(self, module, pr: dict, verdict: str, verified_states):
        stack = ExitStack()
        stack.enter_context(
            mock.patch.object(
                module,
                "resolve_workflow_labels",
                return_value=("reviewed:approve", "reviewed:changes"),
            )
        )
        stack.enter_context(mock.patch.object(module, "pr_view", return_value=pr))
        stack.enter_context(mock.patch.object(module, "gate_status", return_value=self.gate()))
        stack.enter_context(
            mock.patch.object(module, "render_review", return_value=(verdict, f"{verdict}\n"))
        )
        stack.enter_context(mock.patch.object(module, "require_current_review_state", return_value=self.gate()))
        stack.enter_context(mock.patch.object(module, "post_comment"))
        stack.enter_context(mock.patch.object(module, "set_verdict_label"))
        verify = stack.enter_context(
            mock.patch.object(module, "verify_publication", side_effect=verified_states)
        )
        ready = stack.enter_context(mock.patch.object(module, "mark_ready_for_review"))
        restore = stack.enter_context(mock.patch.object(module, "restore_draft"))
        clear = stack.enter_context(mock.patch.object(module, "clear_verdict_labels"))
        return stack, verify, ready, restore, clear

    def publish(self, module, pr: dict, verdict: str):
        return module.publish_results(
            Path("/fake-repo"),
            "coghex/kanban",
            89,
            pr,
            self.gate(),
            [module.CODEX_REVIEWER],
            [self.review_result(verdict)],
            {"pr": 89},
            allow_no_issue=False,
        )

    def test_pr_view_requests_draft_state(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand), mock.patch.object(
                module, "gh_json", return_value=self.pr(draft=True)
            ) as gh_json:
                module.pr_view(Path("/fake-repo"), "coghex/kanban", 89)
                fields = gh_json.call_args.args[1][-1]
                self.assertIn("isDraft", fields.split(","))

    def test_approval_marks_a_draft_ready_and_verifies_the_transition(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                pr = self.pr(draft=True)
                before = {
                    "comment_url": "https://example.test/comment",
                    "labels": ["reviewed:approve"],
                    "ready_for_review": False,
                }
                after = {**before, "ready_for_review": True}
                stack, verify, ready, restore, clear = self.publication_context(
                    module, pr, "APPROVE", [before, after]
                )
                with stack:
                    code, result = self.publish(module, pr, "APPROVE")

                self.assertEqual(code, 0)
                self.assertTrue(result["ready_for_review"])
                ready.assert_called_once_with(Path("/fake-repo"), "coghex/kanban", 89)
                self.assertEqual(verify.call_count, 2)
                restore.assert_not_called()
                clear.assert_not_called()

    def test_changes_requested_leaves_a_draft_untouched(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                pr = self.pr(draft=True)
                verified = {
                    "comment_url": "https://example.test/comment",
                    "labels": ["reviewed:changes"],
                    "ready_for_review": False,
                }
                stack, verify, ready, restore, clear = self.publication_context(
                    module, pr, "CHANGES_REQUESTED", [verified]
                )
                with stack:
                    code, result = self.publish(module, pr, "CHANGES_REQUESTED")

                self.assertEqual(code, 0)
                self.assertFalse(result["ready_for_review"])
                self.assertEqual(verify.call_count, 1)
                ready.assert_not_called()
                restore.assert_not_called()
                clear.assert_not_called()

    def test_stale_publication_after_ready_leaves_the_ready_state_alone(self):
        """A ready transition outlives the publication that went stale after it.

        This is the owned half of the successful-command pair: the
        coordinator's own ready command made the transition, and the
        verification that followed it went stale. The coordinator still has no
        evidence that the transition was its own -- the concurrent case below
        stages the identical observable sequence with another actor as the
        author -- so it leaves the pull request ready for review and clears
        only the verdict labels.
        """
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                pr = self.pr(draft=True)
                before = {
                    "comment_url": "https://example.test/comment",
                    "labels": ["reviewed:approve"],
                    "ready_for_review": False,
                }
                stack, verify, ready, restore, clear = self.publication_context(
                    module,
                    pr,
                    "APPROVE",
                    [before, module.WorkflowError("PR head changed after publication")],
                )

                def owned_transition(*_args, **_kwargs):
                    # This invocation's own command applies the transition,
                    # which is the one case a rollback would be entitled to
                    # undo -- and it is indistinguishable from the concurrent
                    # case below by anything the coordinator reads.
                    pr["isDraft"] = False

                ready.side_effect = owned_transition

                with stack, self.assertRaises(module.WorkflowError) as excinfo:
                    self.publish(module, pr, "APPROVE")

                ready.assert_called_once_with(Path("/fake-repo"), "coghex/kanban", 89)
                self.assertEqual(verify.call_count, 2)
                clear.assert_called_once_with(
                    Path("/fake-repo"),
                    "coghex/kanban",
                    89,
                    "reviewed:approve",
                    "reviewed:changes",
                )
                restore.assert_not_called()
                self.assertFalse(pr["isDraft"])
                self.assertNotIn("draft state was restored", str(excinfo.exception))

    def test_successful_ready_command_leaves_a_concurrent_transition_alone(self):
        """A ready command that succeeded as a no-op undoes nothing.

        Another actor marks the pull request ready after the first
        verification read a draft, so the coordinator's own ready command
        returns successfully having changed nothing, and the verification
        after it goes stale. That is the same sequence the owned case above
        presents -- normal return, then a failure -- and `gh pr ready` cannot
        close the gap, because its draft check and its mutation are not atomic
        either. So publication leaves the external ready state standing.
        """
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                pr = self.pr(draft=True)
                before = {
                    "comment_url": "https://example.test/comment",
                    "labels": ["reviewed:approve"],
                    "ready_for_review": False,
                }
                stack, verify, ready, restore, clear = self.publication_context(
                    module,
                    pr,
                    "APPROVE",
                    [before, module.WorkflowError("PR head changed after publication")],
                )

                def external_transition_then_no_op(*_args, **_kwargs):
                    # The concurrency window itself: the verification above
                    # observed a draft, then someone else marked the pull
                    # request ready, so this command succeeds without applying
                    # anything. Staged here and asserted below, so the fixture
                    # proves the external ready state survives publication.
                    pr["isDraft"] = False

                ready.side_effect = external_transition_then_no_op

                with stack, self.assertRaises(module.WorkflowError) as excinfo:
                    self.publish(module, pr, "APPROVE")

                ready.assert_called_once_with(Path("/fake-repo"), "coghex/kanban", 89)
                self.assertEqual(verify.call_count, 2)
                clear.assert_called_once_with(
                    Path("/fake-repo"),
                    "coghex/kanban",
                    89,
                    "reviewed:approve",
                    "reviewed:changes",
                )
                restore.assert_not_called()
                self.assertFalse(pr["isDraft"])
                self.assertNotIn("draft state was restored", str(excinfo.exception))

    def test_failed_ready_command_leaves_a_concurrent_transition_alone(self):
        """A ready state the coordinator cannot prove it created stays put.

        Another actor marks the PR ready after the initial verification read a
        draft, and the coordinator's own ready command then fails without
        applying anything. Nothing observable separates that from the command
        having applied before reporting failure -- both act through the same
        credentials -- so publication must not undo it. That is the trade this
        test buys: in the mirror case, a command that did apply before failing
        leaves the PR ready for review with both verdict labels cleared, which
        the board classifies Reviewing and the drainer will not merge.
        """
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                pr = self.pr(draft=True)
                before = {
                    "comment_url": "https://example.test/comment",
                    "labels": ["reviewed:approve"],
                    "ready_for_review": False,
                }
                stack, verify, ready, restore, clear = self.publication_context(
                    module, pr, "APPROVE", [before]
                )

                def verify_then_external_transition(*_args, **_kwargs):
                    # The concurrency window itself: this read observes the
                    # draft, and only afterwards does someone else mark the PR
                    # ready. pr_view returns this same dict, so a coordinator
                    # that re-read isDraft to reconcile the failure below would
                    # see non-draft and restore a transition that is not its.
                    pr["isDraft"] = False
                    return before

                verify.side_effect = verify_then_external_transition
                ready.side_effect = module.WorkflowError("gh pr ready failed")

                with stack, self.assertRaises(module.WorkflowError) as excinfo:
                    self.publish(module, pr, "APPROVE")

                ready.assert_called_once_with(Path("/fake-repo"), "coghex/kanban", 89)
                self.assertEqual(verify.call_count, 1)
                clear.assert_called_once_with(
                    Path("/fake-repo"),
                    "coghex/kanban",
                    89,
                    "reviewed:approve",
                    "reviewed:changes",
                )
                restore.assert_not_called()
                self.assertFalse(pr["isDraft"])
                self.assertNotIn("draft state was restored", str(excinfo.exception))

    def test_failed_ready_command_does_not_restore_when_the_pr_remains_a_draft(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                pr = self.pr(draft=True)
                before = {
                    "comment_url": "https://example.test/comment",
                    "labels": ["reviewed:approve"],
                    "ready_for_review": False,
                }
                stack, verify, ready, restore, clear = self.publication_context(
                    module, pr, "APPROVE", [before]
                )
                ready.side_effect = module.WorkflowError("gh pr ready failed before the transition")

                with stack, self.assertRaises(module.WorkflowError) as excinfo:
                    self.publish(module, pr, "APPROVE")

                ready.assert_called_once_with(Path("/fake-repo"), "coghex/kanban", 89)
                self.assertEqual(verify.call_count, 1)
                clear.assert_called_once_with(
                    Path("/fake-repo"),
                    "coghex/kanban",
                    89,
                    "reviewed:approve",
                    "reviewed:changes",
                )
                restore.assert_not_called()
                self.assertNotIn("draft state was restored", str(excinfo.exception))

    def test_ready_and_restore_use_github_draft_commands(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand), mock.patch.object(module, "run") as run:
                module.mark_ready_for_review(Path("/fake-repo"), "coghex/kanban", 89)
                module.restore_draft(Path("/fake-repo"), "coghex/kanban", 89)

                self.assertEqual(
                    run.call_args_list,
                    [
                        mock.call(
                            ["gh", "pr", "ready", "89", "-R", "coghex/kanban"],
                            cwd=Path("/fake-repo"),
                        ),
                        mock.call(
                            [
                                "gh",
                                "pr",
                                "ready",
                                "89",
                                "-R",
                                "coghex/kanban",
                                "--undo",
                            ],
                            cwd=Path("/fake-repo"),
                        ),
                    ],
                )


if __name__ == "__main__":
    unittest.main()
