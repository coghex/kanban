"""The human-requested issue-gate override on the PR review coordinator.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

`--override-issue-gate` lets a review proceed against a pull request whose
linked issue does not carry a current canonical opposite-agent approval. It
exists for one situation: a person has looked at the gate's refusal and decided
to proceed anyway. Everything here is about keeping that narrow.

Four properties, each of which fails independently:

1. Both halves are required, in both directions, and either misuse is refused
   before anything happens. A flag with no reason would bypass the gate leaving
   no record of who decided; a reason with no flag would run an ordinary gated
   review while its caller believed they had overridden, which turns the gate's
   own refusal into something they misread as the verdict.
2. It relaxes the approval clause and nothing else. The other three ways a gate
   can refuse are different defects that "review it anyway" has not spoken to.
3. It is never silent. The bypass reaches the reviewer's prompt, the published
   comment, and the JSON result -- and reaches none of them when the flag was
   passed but nothing was actually bypassed, so an ordinary round's output is
   byte-identical to what it was before this flag existed.
4. The published `pr-review:v2` marker keeps the exact shape
   `tools/drain_prs.py` matches. That is a deliberate decision rather than an
   accident of formatting: an overridden approval merges through the ordinary
   queue like any other, so the marker must stay drainer-readable. A test
   holds it against the drainer's own compiled regex rather than against a
   copy of it, so a change to either side has to face this.

Both vendored copies are exercised, since each bundle ships its own.
"""

from __future__ import annotations

import importlib.util
import sys
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

import drain_prs

REPO_ROOT = Path(__file__).resolve().parent.parent
COORDINATORS = {
    "codex": (
        REPO_ROOT
        / "codex-plugin"
        / "plugins"
        / "kanban"
        / "skills"
        / "pr-review"
        / "scripts"
        / "review_pr.py"
    ),
    "claude": REPO_ROOT / "claude-plugin" / "plugins" / "kanban" / "scripts" / "review_pr.py",
}

REASON = "owner override: the linked issue was approved by a same-brand reviewer"


def load_coordinator(brand: str):
    spec = importlib.util.spec_from_file_location(
        f"kanban_{brand}_issue_gate_override", COORDINATORS[brand]
    )
    if spec is None or spec.loader is None:
        raise AssertionError(f"could not import {COORDINATORS[brand]}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class IssueGateOverrideTests(unittest.TestCase):
    def setUp(self):
        self.modules = {brand: load_coordinator(brand) for brand in COORDINATORS}

    # ------------------------------------------------------------- fixtures

    @staticmethod
    def pr() -> dict:
        return {
            "number": 89,
            "url": "https://github.com/coghex/kanban/pull/89",
            "state": "OPEN",
            "headRefOid": "a" * 40,
            "body": "<!-- pr-origin:claude -->",
            "isCrossRepository": False,
            "isDraft": False,
            "labels": [],
            "closingIssuesReferences": [],
        }

    @staticmethod
    def gate(**overrides) -> dict:
        base = {
            "approved": True,
            "allow_no_issue": False,
            "override_issue_gate": False,
            "override_reason": None,
            "overridden_issues": [],
            "issues": [],
            "invalid_links": [],
            "checks": [],
            "key": "k1",
        }
        base.update(overrides)
        return base

    @staticmethod
    def results(module) -> list[dict]:
        return [
            {
                "reviewer": module.CODEX_REVIEWER,
                "display_name": module.CODEX_REVIEWER.display_name,
                "verdict": "APPROVE",
                "summary": "Looks right.",
                "blocking_concerns": [],
                "model": "some-model",
            }
        ]

    def run_workflow(self, module, *, gate=None, dry_run=True, **kwargs):
        """workflow() with every side effect stubbed, returning the stubs."""
        stack = ExitStack()
        with stack:
            stack.enter_context(
                mock.patch.object(
                    module, "operating_mode", return_value=("dual", ("codex", "claude"))
                )
            )
            stack.enter_context(
                mock.patch.object(module, "resolve_repository", return_value="coghex/kanban")
            )
            stack.enter_context(mock.patch.object(module, "pr_view", return_value=self.pr()))
            gate_status = stack.enter_context(
                mock.patch.object(module, "gate_status", return_value=gate or self.gate())
            )
            stubs = {
                name: stack.enter_context(mock.patch.object(module, name))
                for name in (
                    "collect_context",
                    "run_reviews",
                    "publish_results",
                    "publish_gate_comment",
                    "invoke_reviewer",
                    "extract_source",
                )
            }
            stubs["publish_gate_comment"].return_value = ("posted", "https://example.test/c")
            stubs["publish_results"].return_value = (0, {"status": "reviewed"})
            stubs["collect_context"].return_value = {"diff": "..."}
            code, result = module.workflow(
                Path("/fake-repo"),
                89,
                rereview=False,
                dry_run=dry_run,
                allow_no_issue=False,
                **kwargs,
            )
        stubs["gate_status"] = gate_status
        return code, result, stubs

    # -------------------------------------------------- 1. both halves, both ways

    def assertRefusedBeforeAnything(self, code, result, stubs, *, names):
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "override_refused")
        self.assertIn("Nothing was published and no label changed.", result["error"])
        for fragment in names:
            self.assertIn(fragment, result["error"])
        for name, stub in stubs.items():
            self.assertFalse(stub.called, f"{name} ran despite a refused override")

    def test_the_flag_without_a_reason_is_refused_before_anything_happens(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(module, override_issue_gate=True)
                self.assertRefusedBeforeAnything(
                    code, result, stubs, names=["--override-reason"]
                )

    def test_a_blank_reason_is_no_reason_at_all(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(
                    module, override_issue_gate=True, override_reason="   \n\t "
                )
                self.assertRefusedBeforeAnything(
                    code, result, stubs, names=["--override-reason"]
                )

    def test_a_reason_without_the_flag_is_refused_rather_than_ignored(self):
        # The fail-open direction: silently running a gated review here would
        # hand the caller a gate refusal they would read as the review's own
        # verdict.
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(module, override_reason=REASON)
                self.assertRefusedBeforeAnything(
                    code, result, stubs, names=["--override-issue-gate"]
                )

    def test_neither_half_is_the_ordinary_path(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, _ = self.run_workflow(module)
                self.assertEqual(code, 0)
                self.assertEqual(result["status"], "ready")

    def test_a_complete_override_reaches_the_gate_it_is_meant_to_relax(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(
                    module,
                    override_issue_gate=True,
                    override_reason=REASON,
                    gate=self.gate(
                        approved=True,
                        override_issue_gate=True,
                        override_reason=REASON,
                        overridden_issues=[614],
                        issues=[614],
                    ),
                )
                self.assertEqual(code, 0)
                self.assertEqual(result["status"], "ready")
                # An override does not turn a gated review into a standalone
                # one: the issue is still linked, still read, still the
                # contract -- it is only its approval that was bypassed.
                self.assertEqual(result["review_mode"], "issue-gated")
                self.assertEqual(result["issue_gate"]["overridden_issues"], [614])
                _, kwargs = stubs["gate_status"].call_args
                self.assertIs(kwargs["override_issue_gate"], True)
                self.assertEqual(kwargs["override_reason"], REASON)

    # ------------------------------------- 2. the approval clause and nothing else

    def test_it_relaxes_the_approval_clause_only(self):
        unapproved = [{"issue": 7, "approved": False}]
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                approved = module.gate_approved
                self.assertFalse(approved([7], [], unapproved, allow_no_issue=False))
                self.assertTrue(
                    approved([7], [], unapproved, allow_no_issue=False, override_issue_gate=True)
                )
                # An unparseable or cross-repository link is a scope error.
                self.assertFalse(
                    approved(
                        [7],
                        ["other/repo#3"],
                        unapproved,
                        allow_no_issue=False,
                        override_issue_gate=True,
                    )
                )
                # No linked issue at all is what --allow-no-issue is for.
                self.assertFalse(
                    approved([], [], [], allow_no_issue=False, override_issue_gate=True)
                )
                self.assertTrue(
                    approved(
                        [],
                        [],
                        [],
                        allow_no_issue=True,
                        override_issue_gate=True,
                    )
                )
                # A check list that does not line up with the issue list is
                # this coordinator failing to read its own state.
                self.assertFalse(
                    approved([7], [], [], allow_no_issue=False, override_issue_gate=True)
                )

    def test_the_override_widens_the_gate_key_but_the_reason_does_not(self):
        # The key binds an awaiting_self_review response to its later
        # --publish-verdict, so a run that relaxed the gate must not be able to
        # publish through a key obtained without that relaxation. The stated
        # reason is prose, not scope: retyping it must not invalidate the key.
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                plain = module.gate_key("o/r", [7], [])
                overridden = module.gate_key("o/r", [7], [], override_issue_gate=True)
                self.assertNotEqual(plain, overridden)
                self.assertEqual(
                    overridden, module.gate_key("o/r", [7], [], override_issue_gate=True)
                )
                self.assertNotEqual(
                    overridden,
                    module.gate_key("o/r", [7], [], allow_no_issue=True, override_issue_gate=True),
                )

    def test_only_the_issues_actually_bypassed_are_reported(self):
        # A flag passed against an already-approved gate bypassed nothing, and
        # a report that could not tell that from a real bypass would make every
        # later reader treat a no-op flag as a waived approval.
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                checks = [
                    {"issue": 7, "approved": True},
                    {"issue": 8, "approved": False},
                ]
                with ExitStack() as stack:
                    stack.enter_context(
                        mock.patch.object(
                            module, "linked_issue_numbers", return_value=([7, 8], [])
                        )
                    )
                    stack.enter_context(
                        mock.patch.object(module, "check_issue", side_effect=checks)
                    )
                    gate = module.gate_status(
                        Path("/fake-repo"),
                        self.pr(),
                        "coghex/kanban",
                        override_issue_gate=True,
                        override_reason=REASON,
                    )
                self.assertEqual(gate["overridden_issues"], [8])
                self.assertTrue(gate["approved"])

    # ------------------------------------------------- 3. it is never silent

    def test_the_reviewer_is_told_and_only_when_something_was_bypassed(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                context = {"diff": "...", "linked_issues": []}
                plain = module.review_prompt(context, module.CODEX_REVIEWER, False)
                self.assertNotIn("ISSUE-GATE OVERRIDE", plain)
                overridden = module.review_prompt(
                    {**context, "issue_gate_override": {"issues": [614], "reason": REASON}},
                    module.CODEX_REVIEWER,
                    False,
                )
                self.assertIn("ISSUE-GATE OVERRIDE", overridden)
                self.assertIn("#614", overridden)
                self.assertIn(REASON, overridden)
                # And the self-reviewed prompt, which is a separate template.
                self_reviewed = module.self_review_prompt(
                    {**context, "issue_gate_override": {"issues": [614], "reason": REASON}},
                    module.CODEX_REVIEWER,
                    False,
                    89,
                )
                self.assertIn("ISSUE-GATE OVERRIDE", self_reviewed)

    def test_the_context_carries_the_override_only_when_one_bit(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                with ExitStack() as stack:
                    stack.enter_context(
                        mock.patch.object(
                            module, "run", return_value=mock.Mock(stdout="diff")
                        )
                    )
                    stack.enter_context(
                        mock.patch.object(module, "paginated_api", return_value=[])
                    )
                    stack.enter_context(
                        mock.patch.object(module, "pr_comments", return_value=[])
                    )
                    stack.enter_context(
                        mock.patch.object(module, "issue_context", return_value={})
                    )
                    untouched = module.collect_context(
                        Path("/fake-repo"), "coghex/kanban", self.pr(), [], gate=self.gate()
                    )
                    self.assertNotIn("issue_gate_override", untouched)
                    bypassed = module.collect_context(
                        Path("/fake-repo"),
                        "coghex/kanban",
                        self.pr(),
                        [],
                        gate=self.gate(
                            override_issue_gate=True,
                            override_reason=REASON,
                            overridden_issues=[614],
                        ),
                    )
                self.assertEqual(
                    bypassed["issue_gate_override"], {"issues": [614], "reason": REASON}
                )

    def test_the_published_comment_carries_the_banner_above_the_verdict(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                verdict, body = module.render_review(
                    self.results(module),
                    [module.CODEX_REVIEWER],
                    "a" * 40,
                    self.gate(
                        override_issue_gate=True,
                        override_reason=REASON,
                        overridden_issues=[614],
                    ),
                )
                self.assertEqual(verdict, "APPROVE")
                lines = body.splitlines()
                self.assertIn("Issue gate overridden by human request", lines[0])
                self.assertIn("#614", lines[0])
                self.assertTrue(any(REASON in line for line in lines))
                # Above the verdict, where nobody scrolls past it.
                self.assertLess(
                    next(i for i, line in enumerate(lines) if "overridden" in line),
                    lines.index("APPROVE"),
                )

    def test_an_ordinary_review_comment_is_unchanged(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                _, without = module.render_review(
                    self.results(module), [module.CODEX_REVIEWER], "a" * 40
                )
                _, with_noop = module.render_review(
                    self.results(module),
                    [module.CODEX_REVIEWER],
                    "a" * 40,
                    self.gate(override_issue_gate=True, override_reason=REASON),
                )
                self.assertEqual(without.splitlines()[0], "APPROVE")
                self.assertNotIn("overridden", without)
                # A flag that bypassed nothing announces nothing.
                self.assertEqual(without, with_noop)

    # ------------------------------- 4. the marker stays drainer-readable

    def test_an_overridden_approval_is_still_a_marker_the_drainer_merges(self):
        # The deliberate half of this design: an overridden approval goes
        # through the ordinary merge queue, so the marker must keep the exact
        # four-field shape drain_prs.py matches. Held against the drainer's own
        # compiled regex rather than a copy, so a change to either side fails.
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                _, body = module.render_review(
                    self.results(module),
                    [module.CODEX_REVIEWER],
                    "a" * 40,
                    self.gate(
                        override_issue_gate=True,
                        override_reason=REASON,
                        overridden_issues=[614],
                    ),
                )
                match = drain_prs.PR_REVIEW_V2_RE.search(body)
                self.assertIsNotNone(
                    match,
                    "an overridden approval must stay readable to the drainer; "
                    "the pr-review:v2 marker grew a field or changed shape",
                )
                self.assertEqual(match.group(1).lower(), "codex")
                self.assertEqual(match.group(2).lower(), "a" * 40)
                self.assertEqual(match.group(3).upper(), "APPROVE")


    # -------------------------- 5. the publication path, end to end

    def test_publication_carries_the_override_through_every_recheck(self):
        """The one path no dry run reaches, driven for real.

        `publish_results` re-reads the gate three separate ways -- its own
        staleness check, `require_current_review_state` before and after the
        label, and `verify_publication` -- and every one of them recomputes it
        from scratch. A recomputation that dropped the override would produce
        a different key and a False `approved`, so the review would die at
        publication with "linked issues changed during review" AFTER its
        comment was posted. Only the GitHub calls are stubbed here; the gate
        arithmetic and all three re-checks are the real ones.
        """
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                posted: list[str] = []
                pr = {
                    **self.pr(),
                    "labels": [{"name": "reviewed:approve"}],
                }

                def post_comment(root, repo, number, body, _posted=posted):
                    _posted.append(body)
                    return "https://example.test/comment"

                def comments(root, repo, number, _posted=posted):
                    return [
                        {
                            "user": {"login": "kanban-bot"},
                            "body": _posted[-1] if _posted else "",
                            "html_url": "https://example.test/comment",
                        }
                    ]

                with ExitStack() as stack:
                    stack.enter_context(
                        mock.patch.object(
                            module,
                            "resolve_workflow_labels",
                            return_value=("reviewed:approve", "reviewed:changes"),
                        )
                    )
                    stack.enter_context(mock.patch.object(module, "pr_view", return_value=pr))
                    stack.enter_context(
                        mock.patch.object(
                            module, "linked_issue_numbers", return_value=([614], [])
                        )
                    )
                    # Still unapproved on every re-read, which is the whole
                    # point: the override is what has to carry each one.
                    stack.enter_context(
                        mock.patch.object(
                            module,
                            "check_issue",
                            return_value={"issue": 614, "approved": False},
                        )
                    )
                    stack.enter_context(
                        mock.patch.object(module, "post_comment", side_effect=post_comment)
                    )
                    stack.enter_context(
                        mock.patch.object(module, "pr_comments", side_effect=comments)
                    )
                    stack.enter_context(
                        mock.patch.object(module, "viewer_login", return_value="kanban-bot")
                    )
                    stack.enter_context(mock.patch.object(module, "set_verdict_label"))
                    gate_comment = stack.enter_context(
                        mock.patch.object(module, "publish_gate_comment")
                    )
                    gate_comment.return_value = ("posted", "https://example.test/gate")

                    gate = module.gate_status(
                        Path("/fake-repo"),
                        pr,
                        "coghex/kanban",
                        override_issue_gate=True,
                        override_reason=REASON,
                    )
                    self.assertTrue(gate["approved"])
                    code, result = module.publish_results(
                        Path("/fake-repo"),
                        "coghex/kanban",
                        89,
                        pr,
                        gate,
                        [module.CODEX_REVIEWER],
                        self.results(module),
                        {"pr": 89},
                        allow_no_issue=False,
                    )

                self.assertEqual(code, 0, result)
                self.assertEqual(result["status"], "reviewed")
                self.assertEqual(result["verdict"], "APPROVE")
                # It never fell back to the blocked path.
                self.assertFalse(gate_comment.called)
                # And the comment it published says the gate was overridden.
                self.assertEqual(len(posted), 1)
                self.assertIn("Issue gate overridden by human request", posted[0])
                self.assertIn(REASON, posted[0])
                self.assertIsNotNone(drain_prs.PR_REVIEW_V2_RE.search(posted[0]))


if __name__ == "__main__":
    unittest.main()
