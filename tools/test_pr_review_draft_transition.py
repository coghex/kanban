"""Regression coverage for canonical PR approval clearing draft state.

Both packaged coordinators publish through their own copy of review_pr.py, so
the same behavioral contract is exercised against each copy. An approval must
mark a draft ready for review and verify the new state; changes requested must
leave draft state alone. If publication becomes stale after the ready
transition, the coordinator restores the draft while clearing verdict labels.
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

    def test_stale_publication_after_ready_restores_the_draft(self):
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
                with stack, self.assertRaises(module.WorkflowError) as excinfo:
                    self.publish(module, pr, "APPROVE")

                ready.assert_called_once_with(Path("/fake-repo"), "coghex/kanban", 89)
                clear.assert_called_once_with(
                    Path("/fake-repo"),
                    "coghex/kanban",
                    89,
                    "reviewed:approve",
                    "reviewed:changes",
                )
                restore.assert_called_once_with(Path("/fake-repo"), "coghex/kanban", 89)
                self.assertIn("draft state was restored", str(excinfo.exception))

    def test_failed_ready_command_reconciles_and_restores_a_server_side_transition(self):
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

                def transition_then_fail(*_args):
                    pr["isDraft"] = False
                    raise module.WorkflowError("gh pr ready failed after applying the transition")

                ready.side_effect = transition_then_fail
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
                restore.assert_called_once_with(Path("/fake-repo"), "coghex/kanban", 89)
                self.assertIn("draft state was restored", str(excinfo.exception))

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
