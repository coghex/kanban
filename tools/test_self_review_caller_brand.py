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

Issue #572 makes the ROUTE depend on the roster's loaded provider set as well
as on the origin, so every case here pins the operating mode instead of reading
this host's own. The guard itself is unchanged -- a mismatched or absent
declaration is still refused in every mode -- but two things about it are new
and are asserted below: in single-agent mode a declaration naming the sole
loaded provider is ACCEPTED even though it shares the pull request's origin
brand (requirement 13), and the refusal's remedy text stops promising an
opposite-brand reviewer that a one-provider installation cannot spawn. That
second one is prose inside the script, so it gets its own assertion here rather
than relying on the four bundle assets that restate it.
"""

from __future__ import annotations

import importlib.util
import os
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

    def run_workflow(
        self,
        module,
        *,
        pr: dict,
        gate: dict,
        dry_run: bool = False,
        mode: str = "dual",
        loaded: tuple[str, ...] = ("codex", "claude"),
        **kwargs,
    ):
        """workflow() with every side effect stubbed, returning the stubs so a
        caller can assert none of them ran.

        The operating mode is pinned rather than read from whatever roster the
        machine running this suite happens to carry: routing depends on it now,
        so an unpinned mode would make every case here answer a different
        question on a single-agent host.
        """
        stack = ExitStack()
        with stack:
            stack.enter_context(
                mock.patch.object(module, "operating_mode", return_value=(mode, loaded))
            )
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

    def test_single_agent_accepts_the_sole_loaded_provider_as_the_self_reviewer(self):
        # Requirement 13. The pull request's origin and the reviewer share a
        # brand here, which in dual mode is exactly the refused case -- but on
        # a one-provider roster that brand IS the route, and the calling
        # session is the review session Kanban already selected for the
        # pr_review role. Refusing would leave a single-agent install unable
        # to review anything.
        for brand, module in self.modules.items():
            for loaded in ("claude", "codex"):
                for origin_body in (
                    "<!-- pr-origin:claude -->",
                    "<!-- pr-origin:codex -->",
                    "no origin marker",
                ):
                    with self.subTest(brand=brand, loaded=loaded, origin=origin_body):
                        code, result, stubs = self.run_workflow(
                            module,
                            pr=self.pr(body=origin_body),
                            gate=self.gate(),
                            self_review=True,
                            self_review_as=loaded,
                            mode="single-agent",
                            loaded=(loaded,),
                        )
                        self.assertEqual(code, 0)
                        self.assertEqual(result["status"], "awaiting_self_review")
                        self.assertEqual(result["reviewer_key"], loaded)
                        self.assertEqual(result["route"], loaded)
                        stubs["run_reviews"].assert_not_called()
                        stubs["publish_results"].assert_not_called()

    def test_single_agent_still_refuses_a_mismatched_declaration(self):
        # The guard is narrowed by the route, not removed: a session declaring
        # the brand this installation does NOT load is still refused, and
        # nothing is published.
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(
                    module,
                    pr=self.pr(),
                    gate=self.gate(),
                    self_review=True,
                    self_review_as="codex",
                    mode="single-agent",
                    loaded=("claude",),
                )
                self.assertRefused(
                    code, result, stubs, expect="is not the claude reviewer"
                )

    def test_the_single_agent_refusal_promises_no_opposite_brand_reviewer(self):
        # The prose bug this fixes: the dual-mode remedy tells the caller to
        # drop --self-review "instead of publishing a same-brand review", which
        # on a one-provider roster describes exactly what dropping it does.
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                _, single, _ = self.run_workflow(
                    module,
                    pr=self.pr(),
                    gate=self.gate(),
                    self_review=True,
                    self_review_as="codex",
                    mode="single-agent",
                    loaded=("claude",),
                )
                self.assertIn("loads only claude", single["error"])
                self.assertNotIn("same-brand review", single["error"])
                # And the dual-mode wording is untouched, so the fix is a new
                # arm rather than a weakening of the one that was right.
                _, dual, _ = self.run_workflow(
                    module,
                    pr=self.pr(),
                    gate=self.gate(),
                    self_review=True,
                    self_review_as="claude",
                )
                self.assertIn("same-brand review", dual["error"])
                self.assertNotIn("loads only", dual["error"])

    def test_single_agent_routes_an_unknown_origin_to_the_loaded_provider(self):
        # Requirement 12: the dual fallback for an unknown or external origin
        # is replaced, not kept alongside. Without --self-review this spawns
        # exactly one nested reviewer rather than two.
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                code, result, stubs = self.run_workflow(
                    module,
                    pr=self.pr(body="external contribution"),
                    gate=self.gate(),
                    mode="single-agent",
                    loaded=("codex",),
                )
                self.assertEqual(code, 0)
                stubs["run_reviews"].assert_called_once()
                reviewers = stubs["run_reviews"].call_args.args[0]
                self.assertEqual([item.key for item in reviewers], ["codex"])
                # And the published route names that one reviewer too, so the
                # marker cannot claim a review nobody performed.
                published_base = stubs["publish_results"].call_args.args[7]
                self.assertEqual(published_base["route"], "codex")

    def test_no_agent_refuses_the_whole_workflow_without_reading_the_pr(self):
        # Requirement 15. The refusal names the mode, and it lands before the
        # pull request is even read -- which is what makes "publishes nothing,
        # changes no label" structural rather than a claim about branches.
        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                stack = ExitStack()
                with stack:
                    stack.enter_context(
                        mock.patch.object(
                            module, "operating_mode", return_value=("no-agent", ())
                        )
                    )
                    reads = {
                        name: stack.enter_context(mock.patch.object(module, name))
                        for name in (
                            "resolve_repository",
                            "pr_view",
                            "gate_status",
                            "collect_context",
                            "run_reviews",
                            "publish_results",
                            "publish_gate_comment",
                        )
                    }
                    code, result = module.workflow(
                        Path("/fake-repo"),
                        89,
                        rereview=False,
                        dry_run=False,
                        allow_no_issue=False,
                    )
                self.assertEqual(code, 1)
                self.assertEqual(result["status"], module.NO_AGENT_STATUS)
                self.assertIn("no-agent", result["error"])
                for name, stub in reads.items():
                    self.assertFalse(stub.called, f"{name} ran in no-agent mode")

    def test_an_unusable_roster_refuses_in_both_copies(self):
        # Requirement 16, and the distinction it turns on: a file the operator
        # broke is not a deliberate board-only install. It refuses by raising,
        # naming the file and the defect, rather than reporting the no-agent
        # mode.
        import tempfile

        for brand, module in self.modules.items():
            with self.subTest(brand=brand):
                with tempfile.TemporaryDirectory() as tmp:
                    roster = Path(tmp) / "kanban" / "models.toml"
                    roster.parent.mkdir(parents=True)
                    roster.write_text("schema_version = 1\nagents = 7\n", encoding="utf-8")
                    with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": tmp}):
                        with self.assertRaises(module.WorkflowError) as raised:
                            module.operating_mode()
                message = str(raised.exception)
                self.assertIn(str(roster), message)
                self.assertIn("agents", message)
                self.assertNotIn("no-agent", message)

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


# The four bundle assets that document `self_review_refused` recovery, and
# therefore owe the routed-reviewer rule. An asset is the program an agent
# executes top to bottom, so a recovery step that names a reviewer the
# coordinator will not spawn is a wrong instruction, not a stale comment.
SELF_REVIEW_RECOVERY_ASSETS = (
    "claude-plugin/plugins/kanban/commands/pr-review.md",
    "claude-plugin/plugins/kanban/commands/pr-rereview.md",
    "codex-plugin/plugins/kanban/skills/pr-review/SKILL.md",
    "codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md",
)

# The negative control, in WriteLocationTests' pattern: assets that reach the
# same coordinator but DELEGATE the self-review decision rather than
# documenting its recovery. Each tells its session not to pass `--self-review`
# at all, so none owes the rule above -- and a rule that quietly matched every
# asset in both bundles would have to pass here too, which it cannot.
SELF_REVIEW_DELEGATING_ASSETS = (
    "claude-plugin/plugins/kanban/commands/pr-revise.md",
    "claude-plugin/plugins/kanban/commands/repair.md",
    "claude-plugin/plugins/kanban/commands/fix.md",
    "codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md",
    "codex-plugin/plugins/kanban/skills/repair/SKILL.md",
    "codex-plugin/plugins/kanban/skills/fix/SKILL.md",
)

ROUTED_RECOVERY = (
    "so the coordinator spawns the routed reviewer itself — the opposite brand "
    "when the roster loads both providers, and the sole loaded provider when it "
    "loads one"
)
RETIRED_RECOVERY = "so the coordinator spawns the opposite-brand reviewer itself"


def flat(text: str) -> str:
    return " ".join(text.split())


class SelfReviewRecoveryAssetTests(unittest.TestCase):
    """The recovery documented in the bundles matches what the coordinator does.

    Requirement 18 of issue #572. The coordinator's own refusal text is
    asserted above, against the running code; these four assets restate it for
    the agent that has to act on it, and there is no parity gate holding the
    two together, so each is pinned here.

    Deliberately NOT extended to either bundle's `description:` frontmatter,
    which still describes the dual-mode default routing the way
    `docs/design.md` does. That sweep belongs to MODEL-6, which names #572 as
    its precondition; leaving it here is a scope decision, not an omission.
    """

    def read(self, relative_path: str) -> str:
        return flat((REPO_ROOT / relative_path).read_text(encoding="utf-8"))

    def test_every_recovery_asset_names_the_routed_reviewer(self):
        for relative_path in SELF_REVIEW_RECOVERY_ASSETS:
            with self.subTest(asset=relative_path):
                body = self.read(relative_path)
                self.assertIn('`"self_review_refused"`', body)
                self.assertIn(ROUTED_RECOVERY, body)
                self.assertNotIn(RETIRED_RECOVERY, body)

    def test_every_recovery_asset_accepts_a_matching_single_agent_declaration(self):
        for relative_path in SELF_REVIEW_RECOVERY_ASSETS:
            with self.subTest(asset=relative_path):
                body = self.read(relative_path)
                self.assertIn(
                    "A declaration that MATCHES the routed reviewer is not refused: "
                    "on a single-agent roster every pull request routes to the one "
                    "loaded provider, so a matching `--self-review-as` is the normal "
                    'path and returns `"awaiting_self_review"` even where that '
                    "reviewer shares the pull request's own origin brand.",
                    body,
                )

    def test_every_recovery_asset_documents_the_no_agent_refusal(self):
        # The status list in these assets is the agent's whole map of what the
        # coordinator can return, so a status added to the coordinator and not
        # to the list is one the agent meets with no instruction at all.
        for relative_path in SELF_REVIEW_RECOVERY_ASSETS:
            with self.subTest(asset=relative_path):
                body = self.read(relative_path)
                self.assertIn('`"no_agent_mode"`', body)
                self.assertIn(
                    "this installation's model roster loads no provider, so the "
                    "coordinator has no reviewer to route to and refused before "
                    "reading the pull request.",
                    body,
                )
                self.assertIn(
                    "adding a provider to the roster's `agents` list is the "
                    "operator's decision, never this session's.",
                    body,
                )

    def test_the_delegating_assets_owe_and_carry_no_recovery_rule(self):
        # Non-vacuity in both directions: each control really is a delegator
        # (it forbids the flag outright), and none of them carries the rule --
        # so a check that matched every tracked asset would fail here.
        for relative_path in SELF_REVIEW_DELEGATING_ASSETS:
            with self.subTest(asset=relative_path):
                body = self.read(relative_path)
                self.assertIn("Do not pass `--self-review`", body)
                self.assertNotIn('`"self_review_refused"`', body)
                self.assertNotIn(ROUTED_RECOVERY, body)


if __name__ == "__main__":
    unittest.main()
