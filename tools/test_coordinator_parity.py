"""Bounded-divergence gate for the two tracked review coordinators.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

`claude-plugin/plugins/kanban/scripts/review_pr.py` and
`codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py` are two
vendored copies of one coordinator. They are deliberately duplicated rather
than shared (each bundle is a self-contained plugin asset per
docs/agent-workflow-contract.md §3), and §2.2 describes them as
"otherwise-identical" apart from one reviewed exception: the Claude copy pins
and verifies the nested reviewer's model/effort where the Codex copy leaves
both to the host installation.

Since issue #483 that exception is roster-backed rather than two pairs of
literals: the Claude copy loads a bundled `kanban_models.py` from beside itself
and resolves `roles.pr_review.<provider>` through it, keeping its four
constants as the compiled fallbacks that reader is handed on a host with no
roster file. That widened the divergence -- an import, a loader, and a resolver
-- without changing what it is *about*, which is why those lines are recorded
below rather than excluded: the Codex copy still passes no model or effort and
still ships no reader (tools/test_codex_plugin.py asserts both).

Nothing enforced that description, and the drift it invites is not
hypothetical: commit 4525a35 added the issue-vs-pull-request number guard to
the Codex copy only, and the Claude copy went eight days surfacing gh's raw
GraphQL resolver error for an issue number instead (issue #236, WF-4 of
docs/workflow_audit_findings.md).

This module compares the two files line for line and permits exactly one set
of differences: the ones the §2.2 model-pinning exception requires, recorded
below as DOCUMENTED_DIVERGENCE. Nothing is excluded -- not a function, not a
region, not a comment block -- so a change landing in only one copy fails
here wherever it lands, including inside the pinning functions themselves.
NestedReviewerModelPinningTests in tools/test_claude_plugin.py separately pins
what the exception's values must be; this module only bounds how far it may
spread.
"""

from __future__ import annotations

import difflib
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CLAUDE_COORDINATOR = (
    REPO_ROOT / "claude-plugin" / "plugins" / "kanban" / "scripts" / "review_pr.py"
)
CODEX_COORDINATOR = (
    REPO_ROOT
    / "codex-plugin"
    / "plugins"
    / "kanban"
    / "skills"
    / "pr-review"
    / "scripts"
    / "review_pr.py"
)

# Every line on which the two copies differ, as a zero-context unified diff of
# Codex (`-`) against Claude (`+`). Hunk headers are reduced to a bare `@@`:
# line numbers would churn on every shared edit that lands correctly in both
# copies, which is exactly the change this gate must stay quiet about. What
# remains -- the differing lines and the boundaries between the runs they form
# -- is the divergence itself, and it is complete: a difference anywhere else
# in either file appears here as an unexpected hunk.
#
# Update this ONLY together with docs/agent-workflow-contract.md §2.2 and
# claude-plugin/README.md, which is what makes it a record of a reviewed
# exception rather than a snapshot of whatever the two files happen to be.
DOCUMENTED_DIVERGENCE = '''\
@@
+import importlib.util  # loads the model-roster reader beside this file
@@
+
+# Canonical nested-reviewer model/effort (issue #77 round-2 review). Unlike
+# the self-reviewed known-origin case, invoke_codex/invoke_claude below
+# fully construct the subprocess they spawn, so — for this plugin's
+# bundled coordinator only — they pin it and can therefore verify and
+# publish it, matching the exact gpt-5.6-terra/claude-opus-5 at xhigh
+# values the roles.pr_review.codex and roles.pr_review.claude cells of
+# models.toml.example declare -- the cells Kanban's own
+# PullRequestReview/PullRequestRereview spawns resolve from the model
+# roster. This is a deliberate, reviewed divergence from
+# codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py's
+# otherwise-identical copy and from docs/agent-workflow-contract.md §2.2's
+# general "brand only, no pinned model" policy for this nested-spawn path;
+# the self-reviewed path is unaffected and still cannot verify a model,
+# since Kanban's own top-level spawn — outside this coordinator's
+# visibility — is what pins that one.
+CODEX_NESTED_REVIEW_MODEL = "gpt-5.6-terra"
+CODEX_NESTED_REVIEW_EFFORT = "xhigh"
+CLAUDE_NESTED_REVIEW_MODEL = "claude-opus-5"
+CLAUDE_NESTED_REVIEW_EFFORT = "xhigh"
+
+_KANBAN_MODELS_MODULE = None
+
+
+def kanban_models():
+    """The model-roster reader, loaded from beside this coordinator.
+
+    From beside itself and never from `tools/`: an installed bundle has no
+    `tools/` sibling, and a plain `import` would resolve one only when this
+    file happens to run out of a checkout -- silently reading a different
+    copy's compiled defaults there and failing everywhere else. Loaded once and
+    memoized, the way the document mechanism loads its own siblings, and
+    registered in `sys.modules` before execution because that module declares
+    dataclasses, which resolve their own class's `__module__` through
+    `sys.modules` while the class body is still being processed.
+    """
+    global _KANBAN_MODELS_MODULE
+    if _KANBAN_MODELS_MODULE is not None:
+        return _KANBAN_MODELS_MODULE
+    source = Path(__file__).resolve().parent / "kanban_models.py"
+    name = "_kanban_models_for_review_coordinator"
+    try:
+        spec = importlib.util.spec_from_file_location(name, source)
+        if spec is None or spec.loader is None:
+            raise ImportError(f"no loader for {source}")
+        module = importlib.util.module_from_spec(spec)
+        sys.modules[name] = module
+        try:
+            spec.loader.exec_module(module)
+        except BaseException:
+            sys.modules.pop(name, None)
+            raise
+    except Exception as error:  # noqa: BLE001 - reported, never raised bare
+        raise WorkflowError(
+            f"This bundle's model-roster reader at {source} could not be "
+            f"loaded, so no nested review was performed: {error}"
+        ) from error
+    _KANBAN_MODELS_MODULE = module
+    return module
+
+
+def nested_review_assignment(provider: str):
+    """The `roles.pr_review.<provider>` cell this coordinator spawns on.
+
+    The four constants above are what the reader falls back to when the host
+    carries no roster file at all -- equal, cell for cell, to that reader's own
+    compiled defaults, which `tools/test_claude_plugin.py` holds against the
+    tracked `models.toml.example`. A roster file that is present and will not
+    load refuses the nested review instead: an operator who edited it to change
+    a reviewer model must never have this coordinator quietly spawn the old one
+    and then publish that model as verified fact in the `pr-review:v2` marker.
+    """
+    models = kanban_models()
+    fallbacks = {
+        "codex": models.Assignment(
+            CODEX_NESTED_REVIEW_MODEL, CODEX_NESTED_REVIEW_EFFORT, "pr_review codex"
+        ),
+        "claude": models.Assignment(
+            CLAUDE_NESTED_REVIEW_MODEL, CLAUDE_NESTED_REVIEW_EFFORT, "pr_review claude"
+        ),
+    }
+    try:
+        return models.resolve_assignment(
+            "pr_review", provider, fallback=fallbacks[provider]
+        )
+    except models.KanbanModelsError as error:
+        raise WorkflowError(f"{error}; no nested review was performed") from error
@@
-def validate_review(value: Any, reviewer: Reviewer) -> dict[str, Any]:
+def validate_review(value: Any, reviewer: Reviewer, model: str = UNVERIFIED_MODEL_TOKEN) -> dict[str, Any]:
@@
+        "model": model,
@@
-        # No -m/-c model_reasoning_effort/-s/--dangerously-bypass-approvals-and-sandbox:
-        # this coordinator does not pin model, reasoning effort, sandbox, or
-        # approval policy for the reviewer it spawns, and cannot verify
-        # after the fact which model this installation's `codex` defaulted
-        # to (its --json output and session logs carry no model field).
-        # The published comment/marker therefore claims only the reviewer
-        # key (`codex`) as verified fact, via UNVERIFIED_MODEL_TOKEN.
-        # `codex exec` without -s/-a runs a read-only inspection task to
+        # -m/-c model_reasoning_effort pin the canonical nested-reviewer
+        # model (see nested_review_assignment above); no
+        # -s/--dangerously-bypass-approvals-and-sandbox: sandbox/approval
+        # policy is still left to this installation's own default. `codex
+        # exec` without -s/-a runs a read-only inspection task to
@@
+        model_assignment = nested_review_assignment("codex")
@@
+                "--model",
+                model_assignment.model,
+                "--config",
+                f'model_reasoning_effort="{model_assignment.effort}"',
@@
-    return validate_review(value, reviewer)
+    return validate_review(
+        value, reviewer, f"{model_assignment.model}@{model_assignment.effort}"
+    )
@@
-    # No --model/--effort/--permission-mode/--tools: this coordinator does
-    # not pin model, reasoning effort, or permission policy for the
-    # reviewer it spawns. The published comment/marker therefore claims
-    # only the reviewer key (`claude`) as verified fact, via
-    # UNVERIFIED_MODEL_TOKEN, for the same reason as invoke_codex above —
-    # kept symmetric even though Claude's own JSON output happens to expose
-    # a `modelUsage` field, since Codex's does not. `claude -p` without
-    # --permission-mode runs a read-only inspection task to completion
-    # under its own non-interactive defaults.
+    # --model/--effort pin the canonical nested-reviewer model (see
+    # nested_review_assignment above); no --permission-mode/--tools:
+    # permission policy is still left to this installation's own default.
+    # `claude -p` without --permission-mode runs a read-only inspection
+    # task to completion under its own non-interactive defaults.
+    model_assignment = nested_review_assignment("claude")
@@
+            "--model",
+            model_assignment.model,
+            "--effort",
+            model_assignment.effort,
@@
-    return validate_review(parse_claude_output(proc.stdout), reviewer)
+    return validate_review(
+        parse_claude_output(proc.stdout),
+        reviewer,
+        f"{model_assignment.model}@{model_assignment.effort}",
+    )
@@
-def review_marker(reviewers: list[Reviewer], head: str, verdict: str) -> str:
+def review_marker(reviewers: list[Reviewer], models: list[str], head: str, verdict: str) -> str:
@@
-    models = ",".join(UNVERIFIED_MODEL_TOKEN for _ in reviewers)
+    models_field = ",".join(models)
@@
-        f"<!-- pr-review:v2 reviewers={reviewer_keys} models={models} "
+        f"<!-- pr-review:v2 reviewers={reviewer_keys} models={models_field} "
@@
+
+
+def result_models(results: list[dict[str, Any]]) -> list[str]:
+    return [result.get("model", UNVERIFIED_MODEL_TOKEN) for result in results]
@@
-    lines.append(review_marker(reviewers, head, verdict))
+    lines.append(review_marker(reviewers, result_models(results), head, verdict))
@@
+    models: list[str],
@@
-    expected_models = ",".join(UNVERIFIED_MODEL_TOKEN for _ in reviewers)
+    expected_models = ",".join(models)
@@
+            result_models(results),
@@
+                result_models(results),
@@
-    review = review_marker([CODEX_REVIEWER, CLAUDE_REVIEWER], "a" * 40, "APPROVE")
+    review = review_marker(
+        [CODEX_REVIEWER, CLAUDE_REVIEWER], [UNVERIFIED_MODEL_TOKEN, UNVERIFIED_MODEL_TOKEN], "a" * 40, "APPROVE"
+    )
@@
+    assert result_models([{"model": "x@y"}, {"verdict": "APPROVE"}]) == ["x@y", UNVERIFIED_MODEL_TOKEN]
+    pinned = review_marker(
+        [CODEX_REVIEWER],
+        [f"{CODEX_NESTED_REVIEW_MODEL}@{CODEX_NESTED_REVIEW_EFFORT}"],
+        "b" * 40,
+        "CHANGES_REQUESTED",
+    )
+    pinned_match = REVIEW_MARKER_RE.fullmatch(pinned)
+    assert pinned_match and pinned_match.group("models") == "gpt-5.6-terra@xhigh"'''

# The vocabulary §2.2's exception is written in. Used only as a backstop on
# DOCUMENTED_DIVERGENCE itself: regenerating that constant to bless a fresh
# divergence has to smuggle the new lines past this too, so a hunk that has
# nothing to do with model or effort pinning cannot be recorded as though it
# were part of the pinning exception.
PINNING_VOCABULARY = ("model", "effort")


def divergence(codex_source: str, claude_source: str) -> str:
    """The two sources' differing lines, in the DOCUMENTED_DIVERGENCE shape."""
    lines = []
    for line in difflib.unified_diff(
        codex_source.splitlines(keepends=True),
        claude_source.splitlines(keepends=True),
        n=0,
        lineterm="",
    ):
        if line.startswith("--- ") or line.startswith("+++ "):
            continue
        lines.append("@@" if line.startswith("@@") else line.rstrip("\n"))
    return "\n".join(lines)


def hunks(diff_text: str) -> list[str]:
    return [hunk for hunk in diff_text.split("@@\n") if hunk.strip()]


class CoordinatorBoundedDivergenceTests(unittest.TestCase):
    """The two coordinators differ only where §2.2 says they may."""

    def setUp(self):
        self.codex_source = CODEX_COORDINATOR.read_text(encoding="utf-8")
        self.claude_source = CLAUDE_COORDINATOR.read_text(encoding="utf-8")

    def test_the_two_coordinators_differ_only_in_the_documented_pinning_exception(self):
        self.assertEqual(
            divergence(self.codex_source, self.claude_source),
            DOCUMENTED_DIVERGENCE,
            "The tracked review coordinators diverge outside the nested-reviewer "
            "model-pinning exception of docs/agent-workflow-contract.md §2.2. Land "
            "the change in BOTH copies; only a reviewed change to the pinning "
            "exception itself may update DOCUMENTED_DIVERGENCE.",
        )

    def test_every_recorded_divergent_hunk_belongs_to_the_pinning_exception(self):
        for index, hunk in enumerate(hunks(DOCUMENTED_DIVERGENCE)):
            with self.subTest(hunk=index):
                self.assertTrue(
                    any(word in hunk.lower() for word in PINNING_VOCABULARY),
                    f"Recorded divergence hunk {index} names neither model nor "
                    f"effort, so it is not part of the §2.2 exception:\n{hunk}",
                )

    def test_the_number_kind_guard_reached_both_copies(self):
        # The specific one-sided fix that motivated this gate (issue #236).
        # Named rather than left to the diff alone so a future regeneration of
        # DOCUMENTED_DIVERGENCE cannot quietly re-open it.
        for name, source in (
            ("claude", self.claude_source),
            ("codex", self.codex_source),
        ):
            with self.subTest(coordinator=name):
                self.assertIn("def url_names_a_pull_request(", source)
                self.assertIn("def github_number_kind(", source)
                self.assertIn("is an ISSUE, not a pull request", source)


class PlantedDivergenceTests(unittest.TestCase):
    """The comparator has to actually fire.

    Each case takes the real sources and changes ordinary, non-pinning
    behavior in one copy only -- including inside invoke_codex/invoke_claude,
    the functions a comparator built on region exclusions would skip -- then
    asserts the comparator no longer matches DOCUMENTED_DIVERGENCE.
    """

    def setUp(self):
        self.codex_source = CODEX_COORDINATOR.read_text(encoding="utf-8")
        self.claude_source = CLAUDE_COORDINATOR.read_text(encoding="utf-8")
        # The unplanted pair must match, or every case below passes vacuously.
        self.assertEqual(
            divergence(self.codex_source, self.claude_source), DOCUMENTED_DIVERGENCE
        )

    def plant(self, source: str, original: str, replacement: str) -> str:
        self.assertEqual(
            source.count(original),
            1,
            f"planted-violation fixture is stale: {original!r} is not unique",
        )
        return source.replace(original, replacement, 1)

    def assert_caught(self, codex_source: str, claude_source: str, message: str):
        self.assertNotEqual(
            divergence(codex_source, claude_source), DOCUMENTED_DIVERGENCE, message
        )

    def test_a_non_pinning_change_inside_invoke_claude_is_caught(self):
        # Inside a pinning function, but on a line the exception says nothing
        # about: exactly what a whole-function exclusion would let through.
        self.assert_caught(
            self.codex_source,
            self.plant(
                self.claude_source,
                '            "--no-session-persistence",\n',
                "",
            ),
            "dropping --no-session-persistence from only the Claude copy was not caught",
        )

    def test_a_non_pinning_change_inside_invoke_codex_is_caught(self):
        self.assert_caught(
            self.plant(
                self.codex_source,
                '                "--skip-git-repo-check",\n',
                "",
            ),
            self.claude_source,
            "dropping --skip-git-repo-check from only the Codex copy was not caught",
        )

    def test_a_one_sided_change_to_the_number_kind_guard_is_caught(self):
        # The issue #236 drift class itself, replayed: the guard's diagnostic
        # weakened in one copy only.
        self.assert_caught(
            self.codex_source,
            self.plant(
                self.claude_source,
                'f"#{number} is an ISSUE, not a pull request. This workflow "',
                'f"#{number} could not be read. "',
            ),
            "weakening the number-kind guard in only the Claude copy was not caught",
        )

    def test_a_one_sided_module_constant_change_is_caught(self):
        self.assert_caught(
            self.plant(
                self.codex_source,
                "REVIEW_TIMEOUT_SECONDS = 7200",
                "REVIEW_TIMEOUT_SECONDS = 60",
            ),
            self.claude_source,
            "retiming only the Codex copy was not caught",
        )

    def test_a_one_sided_new_helper_is_caught(self):
        self.assert_caught(
            self.codex_source,
            self.plant(
                self.claude_source,
                "def parse_claude_output(stdout: str) -> Any:\n",
                "def unreviewed_helper() -> None:\n    return None\n\n\n"
                "def parse_claude_output(stdout: str) -> Any:\n",
            ),
            "adding a helper to only the Claude copy was not caught",
        )


if __name__ == "__main__":
    unittest.main()
