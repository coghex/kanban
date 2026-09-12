"""Large nested reviews retain every input without overflowing the first message."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
COORDINATORS = {
    "codex": ROOT / "codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py",
    **{brand: ROOT / f"{brand}-plugin/plugins/kanban/scripts/review_pr.py"
       for brand in ("claude", "grok", "kimi", "google")},
}


def load(name, path):
    spec = importlib.util.spec_from_file_location(f"large_review_{name}", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class LargeReviewInputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.modules = {name: load(name, path) for name, path in COORDINATORS.items()}

    def context(self):
        # A large vendor section sits between two authored changes. Keep a CR
        # inside a line and UTF-8 text to exercise byte offsets and line ranges.
        return {
            "pull_request": {"headRefOid": "a" * 40, "body": "Owner's contract"},
            "linked_issues": [{"body": "Approved specification"}],
            "prior_pr_comments": [{"body": "Prior blocking concern"}],
            "inline_review_comments": [{"body": "Inline concern", "line": 9}],
            "diff": (
                "diff --git a/start.py b/start.py\n+first change\n"
                "diff --git a/vendor.h b/vendor.h\n"
                + "+/* upstream source */\n" * 200000
                + "diff --git a/end.py b/end.py\n+熊\rEND-OF-PATCH"
            ),
        }

    def exercise(self, module, context, inspect, *, rereview=False, dual=False):
        sources = []

        def extract():
            root = Path(tempfile.mkdtemp(prefix="test-large-review-"))
            sources.append(root)
            (root / "authored.py").write_text("original\n")
            # A tracked name sharing the prefix must never be replaced.
            (root / ".kanban-review-existing").write_text("tracked\n")
            module.make_tree_read_only(root)
            return root

        def invoke(reviewer, prompt, source):
            if len(prompt.encode("utf-8")) > 64 * 1024:
                raise module.WorkflowError("Prompt is too long")
            self.assertEqual([p for p in sources if p.exists()], [source])
            self.assertEqual((source / "authored.py").read_text(), "original\n")
            self.assertEqual((source / ".kanban-review-existing").read_text(), "tracked\n")
            for path in [source, *source.rglob("*")]:
                self.assertEqual(path.stat().st_mode & 0o222, 0, str(path))
            inspect(prompt, source)
            return {"reviewer": reviewer.key, "verdict": "APPROVE"}

        reviewers = [module.CODEX_REVIEWER, module.CLAUDE_REVIEWER] if dual else [module.CLAUDE_REVIEWER]
        try:
            with mock.patch.object(module, "invoke_reviewer", side_effect=invoke):
                return module.run_reviews(reviewers, context, extract, rereview)
        finally:
            for source in sources:
                self.assertFalse(source.exists(), "review source and materials must be cleaned up")

    def materials(self, prompt, source):
        payload = json.loads(prompt.split("REVIEW_PAYLOAD:\n", 1)[1])
        paths = {key: source / value for key, value in payload["review_materials"].items()}
        for path in paths.values():
            self.assertTrue(path.is_relative_to(source))
            self.assertTrue(path.is_file())
        return paths

    def test_multimegabyte_diff_is_complete_indexed_and_readable_after_vendor_section(self):
        context = self.context()
        for name, module in self.modules.items():
            with self.subTest(bundle=name):
                self.assertGreater(len(module.review_prompt(context, module.CLAUDE_REVIEWER, False)), 4_000_000)

                def inspect(prompt, source):
                    paths = self.materials(prompt, source)
                    patch = paths["patch"].read_bytes()
                    metadata = paths["metadata"].read_bytes()
                    self.assertEqual(patch, context["diff"].encode("utf-8"))
                    self.assertEqual(json.loads(metadata), {k: v for k, v in context.items() if k != "diff"})
                    index = json.loads(paths["index"].read_text())
                    self.assertEqual(index["head"], "a" * 40)
                    for key, data in (("patch", patch), ("metadata", metadata)):
                        self.assertEqual(index[key]["bytes"], len(data))
                        self.assertEqual(index[key]["sha256"], hashlib.sha256(data).hexdigest())
                    self.assertEqual(len(index["sections"]), 3)
                    lines = patch.split(b"\n")
                    for section in index["sections"]:
                        start = section["byte_offset"]
                        data = patch[start:start + section["byte_length"]]
                        self.assertTrue(data.startswith(section["header"].encode()))
                        self.assertEqual(lines[section["start_line"] - 1], section["header"].encode())
                    last = index["sections"][-1]
                    self.assertEqual(last["end_line"], len(lines))
                    self.assertIn("END-OF-PATCH", patch[last["byte_offset"]:].decode())

                self.exercise(module, context, inspect)

    def test_large_metadata_and_override_reason_are_preserved_without_a_large_prompt(self):
        for name, module in self.modules.items():
            with self.subTest(bundle=name):
                context = {
                    "diff": "",
                    "prior_pr_comments": [{"body": "large comment " * 10000}],
                    "issue_gate_override": {"issues": [7], "reason": "owner reason " * 10000},
                }

                def inspect(prompt, source):
                    self.assertIn("ISSUE-GATE OVERRIDE", prompt)
                    self.assertIn("rereview", prompt)
                    paths = self.materials(prompt, source)
                    self.assertEqual(json.loads(paths["metadata"].read_text()), {k: v for k, v in context.items() if k != "diff"})
                    self.assertEqual(paths["patch"].read_bytes(), b"")
                    self.assertEqual(json.loads(paths["index"].read_text())["sections"], [])

                self.exercise(module, context, inspect, rereview=True)

    def test_small_payload_stays_inline_and_dual_reviews_remain_serial(self):
        for name, module in self.modules.items():
            with self.subTest(bundle=name):
                context = {"diff": "+small change\n"}

                def inspect(prompt, source):
                    self.assertEqual(json.loads(prompt.split("REVIEW_PAYLOAD:\n", 1)[1]), context)
                    self.assertFalse(any(p.is_dir() for p in source.iterdir()))

                self.exercise(module, context, inspect, dual=True)

    def test_large_dual_reviews_have_separate_materials_and_no_peer_tree(self):
        context = self.context()
        for name, module in self.modules.items():
            with self.subTest(bundle=name):
                seen = []

                def inspect(prompt, source):
                    paths = self.materials(prompt, source)
                    self.assertTrue(all(not p.exists() for p in seen))
                    seen.append(paths["patch"])

                self.exercise(module, context, inspect, dual=True)
                self.assertEqual(len(seen), 2)

    def test_preparation_failure_restores_root_permissions(self):
        for name, module in self.modules.items():
            with self.subTest(bundle=name), tempfile.TemporaryDirectory() as temp:
                source = Path(temp) / "source"
                source.mkdir()
                module.make_tree_read_only(source)
                original_mode = source.stat().st_mode
                try:
                    with mock.patch.object(Path, "write_bytes", side_effect=OSError("disk full")):
                        with self.assertRaisesRegex(OSError, "disk full"):
                            module.prepare_review_prompt(self.context(), module.CLAUDE_REVIEWER, False, source)
                    self.assertEqual(source.stat().st_mode, original_mode)
                finally:
                    module.make_tree_writable(source)

    def test_preparation_failure_cleans_up_without_invoking_the_reviewer(self):
        for name, module in self.modules.items():
            with self.subTest(bundle=name):
                def unexpected(prompt, source):
                    self.fail("reviewer must not run with incomplete materials")

                with mock.patch.object(Path, "write_bytes", side_effect=OSError("disk full")):
                    with self.assertRaisesRegex(module.WorkflowError, "disk full"):
                        self.exercise(module, self.context(), unexpected)

    def test_reviewer_failure_cleans_up_the_full_materials(self):
        for name, module in self.modules.items():
            with self.subTest(bundle=name):
                def fail(prompt, source):
                    self.materials(prompt, source)
                    raise RuntimeError("reviewer unavailable")

                with self.assertRaisesRegex(module.WorkflowError, "reviewer unavailable"):
                    self.exercise(module, self.context(), fail)


if __name__ == "__main__":
    unittest.main()
