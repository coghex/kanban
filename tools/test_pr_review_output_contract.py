"""Regression coverage for the pull-request reviewers' bounded JSON output."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path


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


def load_coordinator(name: str, path: Path):
    module_name = f"kanban_{name}_review_output_contract"
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


class ReviewOutputContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.coordinators = {
            name: load_coordinator(name, path) for name, path in COORDINATORS.items()
        }

    def test_model_facing_schema_declares_every_validator_length_limit(self):
        for name, module in self.coordinators.items():
            with self.subTest(coordinator=name):
                schema = module.REVIEW_SCHEMA
                summary = schema["properties"]["summary"]
                concerns = schema["properties"]["blocking_concerns"]
                body = concerns["items"]["properties"]["body"]

                self.assertEqual(summary["minLength"], 1)
                self.assertEqual(summary["maxLength"], module.MAX_REVIEW_SUMMARY_CHARS)
                self.assertEqual(concerns["maxItems"], module.MAX_REVIEW_BLOCKING_CONCERNS)
                self.assertEqual(body["minLength"], 1)
                self.assertEqual(body["maxLength"], module.MAX_REVIEW_BLOCKER_BODY_CHARS)

    def test_nested_and_self_review_prompts_state_the_same_limits(self):
        for name, module in self.coordinators.items():
            prompts = (
                module.review_prompt({}, module.CLAUDE_REVIEWER, rereview=False),
                module.self_review_prompt(
                    {}, module.CODEX_REVIEWER, rereview=False, number=1
                ),
            )
            for prompt in prompts:
                with self.subTest(coordinator=name, prompt=prompt[:30]):
                    self.assertIn(
                        f"no more than {module.MAX_REVIEW_SUMMARY_CHARS} characters",
                        prompt,
                    )
                    self.assertIn(
                        f"no more than {module.MAX_REVIEW_BLOCKING_CONCERNS} blockers",
                        prompt,
                    )
                    self.assertIn(
                        f"no more than {module.MAX_REVIEW_BLOCKER_BODY_CHARS} characters",
                        prompt,
                    )

    def test_validator_accepts_each_declared_boundary(self):
        for name, module in self.coordinators.items():
            reviewer = module.CLAUDE_REVIEWER
            cases = (
                {
                    "verdict": "APPROVE",
                    "summary": "s" * module.MAX_REVIEW_SUMMARY_CHARS,
                    "blocking_concerns": [],
                },
                {
                    "verdict": "CHANGES_REQUESTED",
                    "summary": "summary",
                    "blocking_concerns": [
                        {
                            "path": "src/Example.hs",
                            "line": "1",
                            "body": "b" * module.MAX_REVIEW_BLOCKER_BODY_CHARS,
                        }
                    ],
                },
                {
                    "verdict": "CHANGES_REQUESTED",
                    "summary": "summary",
                    "blocking_concerns": [
                        {"path": "src/Example.hs", "line": "", "body": "blocker"}
                        for _ in range(module.MAX_REVIEW_BLOCKING_CONCERNS)
                    ],
                },
            )
            for case in cases:
                with self.subTest(coordinator=name, case=case["verdict"]):
                    self.assertEqual(
                        module.validate_review(case, reviewer)["verdict"], case["verdict"]
                    )

    def test_validator_reports_the_measured_overage(self):
        for name, module in self.coordinators.items():
            reviewer = module.CLAUDE_REVIEWER
            cases = (
                (
                    {
                        "verdict": "APPROVE",
                        "summary": "s" * (module.MAX_REVIEW_SUMMARY_CHARS + 1),
                        "blocking_concerns": [],
                    },
                    f"{module.MAX_REVIEW_SUMMARY_CHARS + 1}-character summary; "
                    f"the limit is {module.MAX_REVIEW_SUMMARY_CHARS}",
                ),
                (
                    {
                        "verdict": "CHANGES_REQUESTED",
                        "summary": "summary",
                        "blocking_concerns": [
                            {
                                "path": "src/Example.hs",
                                "line": "1",
                                "body": "b" * (module.MAX_REVIEW_BLOCKER_BODY_CHARS + 1),
                            }
                        ],
                    },
                    f"{module.MAX_REVIEW_BLOCKER_BODY_CHARS + 1}-character blocker body; "
                    f"the limit is {module.MAX_REVIEW_BLOCKER_BODY_CHARS}",
                ),
                (
                    {
                        "verdict": "CHANGES_REQUESTED",
                        "summary": "summary",
                        "blocking_concerns": [
                            {"path": "src/Example.hs", "line": "", "body": "blocker"}
                            for _ in range(module.MAX_REVIEW_BLOCKING_CONCERNS + 1)
                        ],
                    },
                    f"{module.MAX_REVIEW_BLOCKING_CONCERNS + 1} blocking concerns; "
                    f"the limit is {module.MAX_REVIEW_BLOCKING_CONCERNS}",
                ),
            )
            for value, message in cases:
                with self.subTest(coordinator=name, message=message):
                    with self.assertRaisesRegex(module.WorkflowError, message):
                        module.validate_review(value, reviewer)


if __name__ == "__main__":
    unittest.main()
