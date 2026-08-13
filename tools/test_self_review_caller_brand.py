"""Fail-closed gate on who may self-review a pull request (issue #303).

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

`--self-review` hands the review to the calling session instead of spawning a
nested reviewer, which is correct only when that session is the brand the
route names. The coordinator cannot observe who invoked it, so the caller
declares its own brand and the declaration is checked before anything else
happens.

The session this guards against is concrete: a solver that just opened a
`pr-origin:claude` pull request and then runs `/pr-review` on it. That route
names codex, so an undeclared or claude-declared caller must be refused --
otherwise it reviews its own work and publishes the verdict under codex's
name. Both vendored copies are exercised, since each bundle ships its own.

The refusal is checked at each place work could otherwise begin: ahead of the
blocked-gate comment, ahead of the dry-run response, ahead of context
collection, and ahead of every reviewer spawn.
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
    "claude": REPO_ROOT / "claude-plugin" / "plugins" / "kanban" / "scripts" / "review_pr.py",
}


def load_coordinator(brand: str):
    spec = importlib.util.spec_from_file_location(
        f"kanban_{brand}_caller_brand_review_pr", COORDINATORS[brand]
    )
    if spec is None or spec.loader is None:
        raise AssertionError(f"could not import {COORDINATORS[brand]}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class SelfReviewCallerBrandTests(unittest.TestCase):
    def setUp(self):
        self.modules = {brand: load_coordinator(brand) for brand in COORDINATORS}

    @staticmethod
    def pr(body: str = "<!-- pr-origin:claude -->") -> dict:
        return {
            "number": 89,
            "url": "https://github.com/coghex/kanban/pull/89",
            "state": "OPEN",
            "headRefOid": "a" * 40,
            "body": body,
            "isCrossRepository": False,
            "isDraft": False,
            "labels": [],
            "closingIssuesReferences": [],
        }

    @staticmethod
    def gate(approved: bool = True) -> dict:
        return {
            "approved": approved,
            "allow_no_issue": False,
            "issues": [],
            "invalid_links": [],
            "checks": [],
            "key": "k1",
        }

    def run_workflow(self, module, *, pr: dict, gate: dict, dry_run: bool = False, **kwargs):
        """workflow() with every side effect stubbed, returning the stubs so a
        caller can assert none of them ran."""
        stack = ExitStack()
        with stack:
            stack.enter_context(
                mock.patch.object(module, "resolve_repository", return_value="coghex/kanban")
            )
            stack.enter_context(mock.patch.object(module, "pr_view", return_value=pr))
            stack.enter_context(mock.patch.object(module, "gate_status", return_value=gate))
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
            # Real payload: the accepted path renders it into the prompt.
            stubs["collect_context"].return_value = {"diff": "..."}
            code, result = module.workflow(
                Path("/fake-repo"),
                89,
                rereview=False,
                dry_run=dry_run,
                allow_no_issue=False,
                **kwargs,
            )
        return code, result, stubs

    def assertRefused(self, code: int, result: dict, stubs: dict, *, expect: str):
        self.assertEqual(code, 1)
        self.assertEqual(result["status"], "self_review_refused")
        # The refusal has to say which flag to drop, or a caller cannot act on
        # it without reading this source.
        self.assertIn("omit --self-review", result["error"])
        self.assertIn(expect, result["error"])
        for name, stub in stubs.items():
            self.assertFalse(stub.called, f"{name} ran despite a refused self-review")

    def test_an_undeclared_caller_is_refused(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(
                    module, pr=self.pr(), gate=self.gate(), self_review=True
                )
                self.assertRefused(code, result, stubs, expect="--self-review-as <brand>")

    def test_a_same_brand_caller_is_refused(self):
        # The autosolve case: a claude session reviewing the claude-origin PR
        # it just opened, where the route names codex.
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(
                    module,
                    pr=self.pr(),
                    gate=self.gate(),
                    self_review=True,
                    self_review_as="claude",
                )
                self.assertRefused(code, result, stubs, expect="is not the codex reviewer")

    def test_the_routed_brand_is_accepted(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(
                    module,
                    pr=self.pr(),
                    gate=self.gate(),
                    self_review=True,
                    self_review_as="codex",
                )
                self.assertEqual(code, 0)
                self.assertEqual(result["status"], "awaiting_self_review")
                self.assertEqual(result["reviewer_key"], "codex")
                stubs["run_reviews"].assert_not_called()
                stubs["publish_results"].assert_not_called()

    def test_a_codex_origin_pr_routes_the_other_way(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                pr = self.pr(body="<!-- pr-origin:codex -->")
                code, result, stubs = self.run_workflow(
                    module, pr=pr, gate=self.gate(), self_review=True, self_review_as="codex"
                )
                self.assertRefused(code, result, stubs, expect="is not the claude reviewer")

                code, result, _ = self.run_workflow(
                    module, pr=pr, gate=self.gate(), self_review=True, self_review_as="claude"
                )
                self.assertEqual(result["status"], "awaiting_self_review")
                self.assertEqual(result["reviewer_key"], "claude")

    def test_the_refusal_precedes_the_dry_run_response(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(
                    module, pr=self.pr(), gate=self.gate(), dry_run=True, self_review=True
                )
                self.assertRefused(code, result, stubs, expect="--self-review-as <brand>")
                self.assertNotEqual(result["status"], "ready")

    def test_the_refusal_precedes_the_blocked_gate_comment(self):
        # An unapproved gate would otherwise publish its own comment on the
        # way to returning "blocked". A refused caller must not cause even
        # that write.
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(
                    module, pr=self.pr(), gate=self.gate(approved=False), self_review=True
                )
                self.assertRefused(code, result, stubs, expect="--self-review-as <brand>")
                self.assertNotEqual(result["status"], "blocked")

    def test_an_unknown_origin_still_falls_through_to_the_nested_spawn(self):
        # Both brands review an unknown/external origin, so no single session
        # can self-review it. That route ignores --self-review exactly as it
        # always has; it is not a caller-brand mismatch and must not be
        # refused, declared or not.
        for brand, module in self.modules.items():
            for declared in (None, "codex", "claude"):
                with self.subTest(brand=brand, declared=declared):
                    code, result, stubs = self.run_workflow(
                        module,
                        pr=self.pr(body="no origin marker"),
                        gate=self.gate(),
                        self_review=True,
                        self_review_as=declared,
                    )
                    self.assertNotEqual(result.get("status"), "self_review_refused")
                    stubs["run_reviews"].assert_called_once()
                    stubs["publish_results"].assert_called_once()

    def test_the_declaration_is_inert_without_the_flag(self):
        # --self-review-as alone changes nothing: the nested spawn is still
        # what a caller that did not ask to self-review gets.
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(
                    module, pr=self.pr(), gate=self.gate(), self_review_as="codex"
                )
                self.assertNotEqual(result.get("status"), "self_review_refused")
                stubs["run_reviews"].assert_called_once()

    def test_both_copies_expose_the_declaration_as_a_brand_choice(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                # The parser is built inside parse_args(), so a real argv is
                # the stable surface to assert against.
                with mock.patch.object(
                    sys,
                    "argv",
                    ["review_pr.py", "--review", "89", "--self-review", "--self-review-as", "codex"],
                ):
                    args = module.parse_args()
                self.assertTrue(args.self_review)
                self.assertEqual(args.self_review_as, "codex")

    def test_an_unknown_brand_is_rejected_by_the_parser(self):
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                with mock.patch.object(
                    sys,
                    "argv",
                    ["review_pr.py", "--review", "89", "--self-review", "--self-review-as", "coghex"],
                ), mock.patch.object(sys, "stderr", new=mock.MagicMock()):
                    with self.assertRaises(SystemExit):
                        module.parse_args()


if __name__ == "__main__":
    unittest.main()
