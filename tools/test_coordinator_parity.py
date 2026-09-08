"""Bounded-divergence gate for the four tracked review coordinators.

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
literals: a copy of `kanban_models.py` ships beside each coordinator and the
Claude copy resolves `roles.pr_review.<provider>` through it, keeping its four
constants as the compiled fallbacks that reader is handed on a host with no
roster file.

Issue #572 narrowed the divergence back down again. Both copies now read the
roster's loaded provider set to route -- so the sibling reader, its
`importlib.util` import, its loader function, and loaded-provider routing are
shared code and are no longer recorded below. What remains is the pinning
exception itself, and only that: the Claude copy resolves an assignment cell
and pins its model and effort onto the nested spawn, publishing them as
verified fact in the `pr-review:v2` marker, while the Codex copy resolves no
cell and still passes no model or effort to anything
(tools/test_codex_plugin.py asserts that directly).

Nothing enforced that description, and the drift it invites is not
hypothetical: commit 4525a35 added the issue-vs-pull-request number guard to
the Codex copy only, and the Claude copy went eight days surfacing gh's raw
GraphQL resolver error for an issue number instead (issue #236, WF-4 of
docs/workflow_audit_findings.md).

This module compares the two files line for line and permits exactly one set
of differences: the ones the §2.2 model-pinning exception requires, recorded
below as DOCUMENTED_DIVERGENCE. Every non-blank line is compared -- not a
function, not a region, not a comment block is excluded -- so a change landing
in only one copy fails here wherever it lands, including inside the pinning
functions themselves. NestedReviewerModelPinningTests in
tools/test_claude_plugin.py separately pins what the exception's values must
be; this module only bounds how far it may spread.

How the comparison works, and why it is not a diff (issue #624). Rendering a
diff and comparing it to a recorded diff makes the gate depend on which of
several equally-good alignments `difflib` happens to choose, and that choice
moves under edits that are *correct*: landing a bare `        )` line in BOTH
copies identically was enough to re-anchor the alignment, move a blank line
across a hunk boundary, and fail the gate with advice -- land it in both
copies -- that the author had already followed. Disabling `autojunk` and
grouping opcodes directly only moved the instability: a blank line inserted
identically before `def kanban_models` in both copies re-anchors that
rendering instead.

So no alignment is inferred here. DOCUMENTED_DIVERGENCE is read as an ordered
list of divergent *units*, each holding the Codex-only lines and the
Claude-only lines of one difference, and `divergence_report` asks a single
question with a yes/no answer: walking both files from the top, can the two be
reconciled by consuming shared lines in lockstep and the recorded units in
order, ending both files and the record together? A change landed identically
in both copies adds shared lines, which the walk consumes in lockstep, so it
cannot change the answer whatever it adds. A change landed in one copy only
that adds, drops, or edits a line leaves text the walk can neither pair nor
account for, so it fails. A change that only MOVES an existing line is a
separate question, and the paragraphs below are about that one.

Order alone was not enough (issue #627). A unit whose Codex side is empty
matches the zero-length slice at any cursor, so nothing stopped its Claude-only
lines from sitting anywhere between the neighbouring recorded units: swapping
`result_models(results),` past `pr["headRefOid"],` in the Claude copy alone
passed this gate, and it passes a list where `verify_publication` expects a head
SHA. Each unit therefore also records the shared lines it sat between, and the
walk requires the unit to follow the first and precede the second.

Those two anchors are order constraints, not adjacency ones, which is what keeps
them from re-creating the false failures above: lines landed identically in both
copies may appear between a unit and either anchor, however many, and an anchor
a shared edit rewrote or deleted outright is dropped rather than enforced. That
tolerance has a price the selected policy of issue #627 accepts. Where a shared
line repeats, one identical insertion can produce a pair that a one-sided move
could also have produced, and both must pass, because this gate is handed two
final sources and a record -- never the edit history that produced them. So a
unit that stays between *some* pair of its recorded neighbours is accepted; what
is rejected is a unit that has moved out from between them.

Blank lines are dropped before the walk. They carry no behavior, and their
grouping is the one thing the superseded renderings churned on; every other
property -- indentation, comments, statement order, and how many times a line
appears -- is compared exactly, and PlantedDivergenceTests holds each of those
with a one-sided control in both directions.
"""

from __future__ import annotations

import difflib
import unittest
from pathlib import Path
from typing import NamedTuple

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
GROK_COORDINATOR = (
    REPO_ROOT / "grok-plugin" / "plugins" / "kanban" / "scripts" / "review_pr.py"
)
KIMI_COORDINATOR = (
    REPO_ROOT / "kimi-plugin" / "plugins" / "kanban" / "scripts" / "review_pr.py"
)

# Every non-blank line on which the two copies differ, as Codex-only (`-`) and
# Claude-only (`+`) lines grouped into units by a bare `@@`, each unit wrapped
# in the shared lines it sits between, written as ` `-prefixed context. Line
# numbers are not recorded: they would churn on every shared edit that lands
# correctly in both copies, which is exactly the change this gate must stay
# quiet about. What remains -- the differing lines, their order, the unit
# boundaries between them, and the neighbours each unit must stay between -- is
# the divergence itself, and it is complete: a difference anywhere else in
# either file is a line the reconciliation walk cannot account for.
#
# A context line is a position anchor and nothing more. It is a line the two
# copies SHARE, it is never counted as part of the divergence, and
# `belongs_to_the_pinning_exception` deliberately does not read it -- otherwise
# an unrelated difference could be recorded here under a neighbour that happens
# to say "model".
#
# Issue #624 regenerated this constant mechanically, from the same two tracked
# files it already described, when the comparison moved off rendered diff text
# onto the reconciliation walk. Issue #627 regenerated it mechanically a second
# time, from that same unchanged tracked pair, to add the context lines above.
# Nothing was blessed and nothing was added either time: the 122 `-`/`+` lines
# recorded below are the ones the first constant already carried, in the same
# order, and every ` ` line beside them is a line both copies already share.
#
# Update this ONLY together with docs/agent-workflow-contract.md §2.2 and
# claude-plugin/README.md, which is what makes it a record of a reviewed
# exception rather than a snapshot of whatever the two files happen to be.
DOCUMENTED_DIVERGENCE = r'''@@
 UNVERIFIED_MODEL_TOKEN = "unspecified"
+# Canonical nested-reviewer model/effort (issue #77 round-2 review). Unlike
+# the self-reviewed known-origin case, invoke_codex/invoke_claude below
+# fully construct the subprocess they spawn, so — for this plugin's
+# bundled coordinator only — they pin it and can therefore verify and
+# publish it, matching the exact gpt-5.6-sol/claude-opus-5 at xhigh
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
+CODEX_NESTED_REVIEW_MODEL = "gpt-5.6-sol"
+CODEX_NESTED_REVIEW_EFFORT = "xhigh"
+CLAUDE_NESTED_REVIEW_MODEL = "claude-opus-5"
+CLAUDE_NESTED_REVIEW_EFFORT = "xhigh"
 _KANBAN_MODELS_MODULE = None
@@
     return module
+def nested_review_assignment(provider: str):
+    """The `roles.pr_review.<provider>` cell this coordinator spawns on.
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
 MAX_REVIEW_SUMMARY_CHARS = 4000
@@
 """
-def validate_review(value: Any, reviewer: Reviewer) -> dict[str, Any]:
+def validate_review(value: Any, reviewer: Reviewer, model: str = UNVERIFIED_MODEL_TOKEN) -> dict[str, Any]:
     if not isinstance(value, dict):
@@
         "blocking_concerns": concerns,
+        "model": model,
     }
@@
         schema_path.write_text(json.dumps(REVIEW_SCHEMA), encoding="utf-8")
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
         # completion under its own non-interactive defaults.
@@
         # completion under its own non-interactive defaults.
+        model_assignment = nested_review_assignment("codex")
         run(
@@
                 str(cwd),
+                "--model",
+                model_assignment.model,
+                "--config",
+                f'model_reasoning_effort="{model_assignment.effort}"',
                 "--output-schema",
@@
             raise WorkflowError(f"{reviewer.display_name} did not return structured JSON") from exc
-    return validate_review(value, reviewer)
+    return validate_review(
+        value, reviewer, f"{model_assignment.model}@{model_assignment.effort}"
+    )
 def parse_claude_output(stdout: str) -> Any:
@@
 def invoke_claude(reviewer: Reviewer, prompt: str, cwd: Path) -> dict[str, Any]:
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
     proc = run(
@@
             "-p",
+            "--model",
+            model_assignment.model,
+            "--effort",
+            model_assignment.effort,
             "--no-session-persistence",
@@
     )
-    return validate_review(parse_claude_output(proc.stdout), reviewer)
+    return validate_review(
+        parse_claude_output(proc.stdout),
+        reviewer,
+        f"{model_assignment.model}@{model_assignment.effort}",
+    )
 def invoke_reviewer(reviewer: Reviewer, prompt: str, cwd: Path) -> dict[str, Any]:
@@
     return "CHANGES_REQUESTED" if any(item["verdict"] == "CHANGES_REQUESTED" for item in results) else "APPROVE"
-def review_marker(reviewers: list[Reviewer], head: str, verdict: str) -> str:
+def review_marker(reviewers: list[Reviewer], models: list[str], head: str, verdict: str) -> str:
     reviewer_keys = ",".join(item.key for item in reviewers)
@@
     reviewer_keys = ",".join(item.key for item in reviewers)
-    models = ",".join(UNVERIFIED_MODEL_TOKEN for _ in reviewers)
+    models_field = ",".join(models)
     return (
@@
     return (
-        f"<!-- pr-review:v2 reviewers={reviewer_keys} models={models} "
+        f"<!-- pr-review:v2 reviewers={reviewer_keys} models={models_field} "
         f"head={head} verdict={verdict} -->"
@@
     )
+def result_models(results: list[dict[str, Any]]) -> list[str]:
+    return [result.get("model", UNVERIFIED_MODEL_TOKEN) for result in results]
 def override_notice_lines(gate: dict[str, Any]) -> list[str]:
@@
             lines.append("")
-    lines.append(review_marker(reviewers, head, verdict))
+    lines.append(review_marker(reviewers, result_models(results), head, verdict))
     body = "\n".join(lines).rstrip() + "\n"
@@
     reviewers: list[Reviewer],
+    models: list[str],
     head: str,
@@
     marker, url = latest
-    expected_models = ",".join(UNVERIFIED_MODEL_TOKEN for _ in reviewers)
+    expected_models = ",".join(models)
     expected_reviewers = ",".join(item.key for item in reviewers)
@@
             reviewers,
+            result_models(results),
             pr["headRefOid"],
@@
                 reviewers,
+                result_models(results),
                 pr["headRefOid"],
@@
     )
-    review = review_marker([CODEX_REVIEWER, CLAUDE_REVIEWER], "a" * 40, "APPROVE")
+    review = review_marker(
+        [CODEX_REVIEWER, CLAUDE_REVIEWER], [UNVERIFIED_MODEL_TOKEN, UNVERIFIED_MODEL_TOKEN], "a" * 40, "APPROVE"
+    )
     match = REVIEW_MARKER_RE.fullmatch(review)
@@
     assert match.group("models") == f"{UNVERIFIED_MODEL_TOKEN},{UNVERIFIED_MODEL_TOKEN}"
+    assert result_models([{"model": "x@y"}, {"verdict": "APPROVE"}]) == ["x@y", UNVERIFIED_MODEL_TOKEN]
+    pinned = review_marker(
+        [CODEX_REVIEWER],
+        [f"{CODEX_NESTED_REVIEW_MODEL}@{CODEX_NESTED_REVIEW_EFFORT}"],
+        "b" * 40,
+        "CHANGES_REQUESTED",
+    )
+    pinned_match = REVIEW_MARKER_RE.fullmatch(pinned)
+    assert pinned_match and pinned_match.group("models") == "gpt-5.6-sol@xhigh"
     print("self-test passed")'''

# Claude vs Grok: the Grok copy is the Claude pinning coordinator plus
# --expected-origin/--expected-route refuse-before-spawn. Compared the same
# way as DOCUMENTED_DIVERGENCE, with Claude as the `-` side and Grok as `+`.
GROK_DOCUMENTED_DIVERGENCE = r'''@@
 def pr_origin(pr: dict[str, Any]) -> str | None:
-    if pr.get("isCrossRepository"):
-        return None
-    return origin_from_body(str(pr.get("body") or ""))
+    origin = origin_from_body(str(pr.get("body") or ""))
+    if pr.get("isCrossRepository"):
+        return origin if origin == "grok" else None
+    return origin
 def linked_issue_numbers(pr: dict[str, Any], repo: str) -> tuple[list[int], list[str]]:
@@
    in docs/agent-workflow-contract.md §4 declaring this file, and that
-    reconciliation matches a literal, not an expression. This bundle vendors a
-    copy of kanban_config.py beside this module and still does not import it:
-    the Codex bundle vendors per skill and has none beside its own copy of this
+    reconciliation matches a literal, not an expression. This bundle does not
+    vendor kanban_config.py beside this module: the Claude bundle does, and
+    the Codex bundle vendors per skill and has none beside its own copy of this
    coordinator, and one probe implemented two ways is the drift both bundles
@@
    return verdict, body
+def expected_route_mismatch(
+    pr: dict[str, Any],
+    expected_origin: str | None,
+    expected_route: str | None,
+    *,
+    unpublished: str,
+) -> dict[str, Any] | None:
+    """Refuse when the live origin/route is no longer what the caller bound.
+    `None` when no binding was requested or the live values still match.
+    The payload is the same `route_mismatch` shape workflow() returns before
+    spawning, so publication can refuse without commenting or labeling.
+    """
+    if expected_origin is None and expected_route is None:
+        return None
+    origin = pr_origin(pr)
+    live_origin = origin or "unknown"
+    live_route = "+".join(item.key for item in route_reviewers(origin))
+    if expected_origin is not None and live_origin != expected_origin:
+        return {
+            "status": "route_mismatch",
+            "origin": live_origin,
+            "route": live_route,
+            "error": (
+                f"live origin {live_origin!r} does not match "
+                f"--expected-origin {expected_origin!r}; {unpublished}"
+            ),
+        }
+    if expected_route is not None and live_route != expected_route:
+        return {
+            "status": "route_mismatch",
+            "origin": live_origin,
+            "route": live_route,
+            "error": (
+                f"live route {live_route!r} does not match "
+                f"--expected-route {expected_route!r}; {unpublished}"
+            ),
+        }
+    return None
 def require_current_review_state(
@@
     expected_gate_key: str,
+    expected_origin: str | None = None,
+    expected_route: str | None = None,
 ) -> dict[str, Any]:
@@
    pr = pr_view(root, repo, number)
+    mismatch = expected_route_mismatch(
+        pr,
+        expected_origin,
+        expected_route,
+        unpublished="nothing was published and no label was applied",
+    )
+    if mismatch is not None:
+        raise WorkflowError(mismatch["error"])
     if pr["headRefOid"] != expected_head:
@@
     changes_requested_label: str,
+    expected_origin: str | None = None,
+    expected_route: str | None = None,
 ) -> dict[str, Any]:
@@
    pr = pr_view(root, repo, number)
+    mismatch = expected_route_mismatch(
+        pr,
+        expected_origin,
+        expected_route,
+        unpublished="nothing was published and no label was applied",
+    )
+    if mismatch is not None:
+        raise WorkflowError(mismatch["error"])
     if pr["headRefOid"] != head:
@@
     config_path: str | None = None,
+    expected_origin: str | None = None,
+    expected_route: str | None = None,
 ) -> tuple[int, dict[str, Any]]:
@@
        raise WorkflowError("linked issues changed during review; no verdict was published")
+    mismatch = expected_route_mismatch(
+        refreshed_pr,
+        expected_origin,
+        expected_route,
+        unpublished="nothing was published and no label was applied",
+    )
+    if mismatch is not None:
+        return 1, {"pr": number, **mismatch}
     if not refreshed_gate["approved"]:
@@
        config_path=config_path,
+        expected_origin=expected_origin,
+        expected_route=expected_route,
     post_comment(root, repo, number, body)
@@
            config_path=config_path,
+            expected_origin=expected_origin,
+            expected_route=expected_route,
        set_verdict_label(root, repo, number, verdict, approval_label, changes_requested_label)
@@
            config_path=config_path,
+            expected_origin=expected_origin,
+            expected_route=expected_route,
        if verdict == "APPROVE" and not verified["ready_for_review"]:
@@
                config_path=config_path,
+                expected_origin=expected_origin,
+                expected_route=expected_route,
            if not verified["ready_for_review"]:
@@
     explicit_repo: str | None = None,
+    expected_origin: str | None = None,
+    expected_route: str | None = None,
 ) -> tuple[int, dict[str, Any]]:
@@
     reviewers = route_reviewers(origin, mode=mode, loaded=loaded)
+    live_origin = origin or "unknown"
+    live_route = "+".join(item.key for item in reviewers)
+    if expected_origin is not None and live_origin != expected_origin:
+        return 1, {
+            "pr": number,
+            "status": "route_mismatch",
+            "origin": live_origin,
+            "route": live_route,
+            "error": (
+                f"live origin {live_origin!r} does not match "
+                f"--expected-origin {expected_origin!r}; nothing was published "
+                "and no reviewer was spawned"
+            ),
+        }
+    if expected_route is not None and live_route != expected_route:
+        return 1, {
+            "pr": number,
+            "status": "route_mismatch",
+            "origin": live_origin,
+            "route": live_route,
+            "error": (
+                f"live route {live_route!r} does not match "
+                f"--expected-route {expected_route!r}; nothing was published "
+                "and no reviewer was spawned"
+            ),
+        }
     base = {
@@
         "head": pr["headRefOid"],
-        "origin": origin or "unknown",
-        "route": "+".join(item.key for item in reviewers),
+        "origin": live_origin,
+        "route": live_route,
         "review_mode": "standalone" if allow_no_issue else "issue-gated",
@@
        allow_no_issue=allow_no_issue, config_path=config_path,
+        expected_origin=expected_origin, expected_route=expected_route,
     )
@@
     assert pr_origin({"isCrossRepository": True, "body": "<!-- pr-origin:claude -->"}) is None
+    assert pr_origin({"isCrossRepository": True, "body": "<!-- pr-origin:grok -->"}) == "grok"
+    assert pr_origin({"isCrossRepository": True, "body": "<!-- pr-origin:codex -->"}) is None
     assert pr_origin({"isCrossRepository": False, "body": "<!-- pr-origin:claude -->"}) == "claude"
@@
         help="Path to kanban's config.toml (default: ~/.config/kanban/config.toml)",
+        "--expected-origin",
+        metavar="ORIGIN",
+        help=(
+            "Refuse before spawning if the live origin is not this value "
+            "(unknown, claude, codex, grok, or kimi). Use with --expected-route to "
+            "fail closed when the pull request drifted after a dry run."
+        ),
+    )
+    parser.add_argument(
+        "--expected-route",
+        metavar="ROUTE",
+        help=(
+            "Refuse before spawning if the live reviewer route is not this "
+            "value (for example codex). Combined with --expected-origin this "
+            "is how a grok-origin autosolve refuses a Claude spawn."
+        ),
+    )
+    parser.add_argument(
         "--repo",
@@
                 explicit_repo=args.repo,
+                expected_origin=args.expected_origin,
+                expected_route=args.expected_route,
             )'''

# Claude vs Kimi: the Kimi copy is the Claude pinning coordinator plus
# the same --expected-origin/--expected-route refuse-before-spawn the Grok
# copy carries, with kimi in the grok arm's place: a kimi marker survives
# isCrossRepository, and the help text names the kimi-origin autosolve.
# Compared the same way, with Claude as the `-` side and Kimi as `+`.
KIMI_DOCUMENTED_DIVERGENCE = r'''@@
 def pr_origin(pr: dict[str, Any]) -> str | None:
-    if pr.get("isCrossRepository"):
-        return None
-    return origin_from_body(str(pr.get("body") or ""))
+    origin = origin_from_body(str(pr.get("body") or ""))
+    if pr.get("isCrossRepository"):
+        return origin if origin == "kimi" else None
+    return origin
 def linked_issue_numbers(pr: dict[str, Any], repo: str) -> tuple[list[int], list[str]]:
@@
    in docs/agent-workflow-contract.md §4 declaring this file, and that
-    reconciliation matches a literal, not an expression. This bundle vendors a
-    copy of kanban_config.py beside this module and still does not import it:
-    the Codex bundle vendors per skill and has none beside its own copy of this
+    reconciliation matches a literal, not an expression. This bundle does not
+    vendor kanban_config.py beside this module: the Claude bundle does, and
+    the Codex bundle vendors per skill and has none beside its own copy of this
    coordinator, and one probe implemented two ways is the drift both bundles
@@
    return verdict, body
+def expected_route_mismatch(
+    pr: dict[str, Any],
+    expected_origin: str | None,
+    expected_route: str | None,
+    *,
+    unpublished: str,
+) -> dict[str, Any] | None:
+    """Refuse when the live origin/route is no longer what the caller bound.
+    `None` when no binding was requested or the live values still match.
+    The payload is the same `route_mismatch` shape workflow() returns before
+    spawning, so publication can refuse without commenting or labeling.
+    """
+    if expected_origin is None and expected_route is None:
+        return None
+    origin = pr_origin(pr)
+    live_origin = origin or "unknown"
+    live_route = "+".join(item.key for item in route_reviewers(origin))
+    if expected_origin is not None and live_origin != expected_origin:
+        return {
+            "status": "route_mismatch",
+            "origin": live_origin,
+            "route": live_route,
+            "error": (
+                f"live origin {live_origin!r} does not match "
+                f"--expected-origin {expected_origin!r}; {unpublished}"
+            ),
+        }
+    if expected_route is not None and live_route != expected_route:
+        return {
+            "status": "route_mismatch",
+            "origin": live_origin,
+            "route": live_route,
+            "error": (
+                f"live route {live_route!r} does not match "
+                f"--expected-route {expected_route!r}; {unpublished}"
+            ),
+        }
+    return None
 def require_current_review_state(
@@
     expected_gate_key: str,
+    expected_origin: str | None = None,
+    expected_route: str | None = None,
 ) -> dict[str, Any]:
@@
    pr = pr_view(root, repo, number)
+    mismatch = expected_route_mismatch(
+        pr,
+        expected_origin,
+        expected_route,
+        unpublished="nothing was published and no label was applied",
+    )
+    if mismatch is not None:
+        raise WorkflowError(mismatch["error"])
     if pr["headRefOid"] != expected_head:
@@
     changes_requested_label: str,
+    expected_origin: str | None = None,
+    expected_route: str | None = None,
 ) -> dict[str, Any]:
@@
    pr = pr_view(root, repo, number)
+    mismatch = expected_route_mismatch(
+        pr,
+        expected_origin,
+        expected_route,
+        unpublished="nothing was published and no label was applied",
+    )
+    if mismatch is not None:
+        raise WorkflowError(mismatch["error"])
     if pr["headRefOid"] != head:
@@
     config_path: str | None = None,
+    expected_origin: str | None = None,
+    expected_route: str | None = None,
 ) -> tuple[int, dict[str, Any]]:
@@
        raise WorkflowError("linked issues changed during review; no verdict was published")
+    mismatch = expected_route_mismatch(
+        refreshed_pr,
+        expected_origin,
+        expected_route,
+        unpublished="nothing was published and no label was applied",
+    )
+    if mismatch is not None:
+        return 1, {"pr": number, **mismatch}
     if not refreshed_gate["approved"]:
@@
        config_path=config_path,
+        expected_origin=expected_origin,
+        expected_route=expected_route,
     post_comment(root, repo, number, body)
@@
            config_path=config_path,
+            expected_origin=expected_origin,
+            expected_route=expected_route,
        set_verdict_label(root, repo, number, verdict, approval_label, changes_requested_label)
@@
            config_path=config_path,
+            expected_origin=expected_origin,
+            expected_route=expected_route,
        if verdict == "APPROVE" and not verified["ready_for_review"]:
@@
                config_path=config_path,
+                expected_origin=expected_origin,
+                expected_route=expected_route,
            if not verified["ready_for_review"]:
@@
     explicit_repo: str | None = None,
+    expected_origin: str | None = None,
+    expected_route: str | None = None,
 ) -> tuple[int, dict[str, Any]]:
@@
     reviewers = route_reviewers(origin, mode=mode, loaded=loaded)
+    live_origin = origin or "unknown"
+    live_route = "+".join(item.key for item in reviewers)
+    if expected_origin is not None and live_origin != expected_origin:
+        return 1, {
+            "pr": number,
+            "status": "route_mismatch",
+            "origin": live_origin,
+            "route": live_route,
+            "error": (
+                f"live origin {live_origin!r} does not match "
+                f"--expected-origin {expected_origin!r}; nothing was published "
+                "and no reviewer was spawned"
+            ),
+        }
+    if expected_route is not None and live_route != expected_route:
+        return 1, {
+            "pr": number,
+            "status": "route_mismatch",
+            "origin": live_origin,
+            "route": live_route,
+            "error": (
+                f"live route {live_route!r} does not match "
+                f"--expected-route {expected_route!r}; nothing was published "
+                "and no reviewer was spawned"
+            ),
+        }
     base = {
@@
         "head": pr["headRefOid"],
-        "origin": origin or "unknown",
-        "route": "+".join(item.key for item in reviewers),
+        "origin": live_origin,
+        "route": live_route,
         "review_mode": "standalone" if allow_no_issue else "issue-gated",
@@
        allow_no_issue=allow_no_issue, config_path=config_path,
+        expected_origin=expected_origin, expected_route=expected_route,
     )
@@
     assert pr_origin({"isCrossRepository": True, "body": "<!-- pr-origin:claude -->"}) is None
+    assert pr_origin({"isCrossRepository": True, "body": "<!-- pr-origin:kimi -->"}) == "kimi"
+    assert pr_origin({"isCrossRepository": True, "body": "<!-- pr-origin:codex -->"}) is None
     assert pr_origin({"isCrossRepository": False, "body": "<!-- pr-origin:claude -->"}) == "claude"
@@
         help="Path to kanban's config.toml (default: ~/.config/kanban/config.toml)",
+        "--expected-origin",
+        metavar="ORIGIN",
+        help=(
+            "Refuse before spawning if the live origin is not this value "
+            "(unknown, claude, codex, grok, or kimi). Use with --expected-route to "
+            "fail closed when the pull request drifted after a dry run."
+        ),
+    )
+    parser.add_argument(
+        "--expected-route",
+        metavar="ROUTE",
+        help=(
+            "Refuse before spawning if the live reviewer route is not this "
+            "value (for example codex). Combined with --expected-origin this "
+            "is how a kimi-origin autosolve refuses a Claude spawn."
+        ),
+    )
+    parser.add_argument(
         "--repo",
@@
                 explicit_repo=args.repo,
+                expected_origin=args.expected_origin,
+                expected_route=args.expected_route,
             )'''

# The vocabulary §2.2's exception is written in. Used only as a backstop on
# DOCUMENTED_DIVERGENCE itself: regenerating that constant to bless a fresh
# divergence has to smuggle the new lines past this too, so a unit that has
# nothing to do with model or effort pinning cannot be recorded as though it
# were part of the pinning exception.
PINNING_VOCABULARY = ("model", "effort")
GROK_ROUTE_VOCABULARY = (
    "expected-origin",
    "expected-route",
    "expected_origin",
    "expected_route",
    "route_mismatch",
    "live_origin",
    "live_route",
    "kanban_config.py",
    "isCrossRepository",
)

# What a failing gate has to tell an author. Issue #624's false failures were
# expensive because the advice named only the one cause it was not -- the
# author had landed the change in both copies already, and the sentence told
# them to go and do that.
DIVERGENCE_GUIDANCE = (
    "The tracked review coordinators diverge outside the nested-reviewer "
    "model-pinning exception of docs/agent-workflow-contract.md §2.2. If the "
    "change reached only one copy, land it in the other. If it is already in "
    "BOTH copies identically, this is a real remaining difference rather than "
    "an alignment artifact -- no alignment is inferred (issue #624), so the "
    "report below names the exact line that could not be accounted for. If "
    "the lines themselves are right, check whether a recorded unit has moved "
    "out from between the shared lines recorded around it. Only a reviewed "
    "change to the pinning exception itself may update DOCUMENTED_DIVERGENCE."
)


def significant_lines(source: str) -> list[tuple[int, str]]:
    """Every non-blank line of `source`, as (1-based line number, text)."""
    return [
        (number, line)
        for number, line in enumerate(source.splitlines(), 1)
        if line.strip()
    ]


class DivergentUnit(NamedTuple):
    """One recorded difference, and the shared lines it sits between.

    `after` and `before` are lines both copies carry. They pin the unit's
    position without pinning its neighbours: the walk requires the unit to be
    applied after `after` has been consumed and before the last `before` in the
    file is passed, so shared lines may be inserted between a unit and either
    anchor. Either may be None for a unit at the very start or end.
    """

    after: str | None
    codex: tuple[str, ...]
    claude: tuple[str, ...]
    before: str | None


def documented_units(record: str) -> list[DivergentUnit]:
    """A DOCUMENTED_DIVERGENCE record as ordered, position-anchored units."""
    units: list[DivergentUnit] = []
    after: str | None = None
    before: str | None = None
    codex_side: list[str] = []
    claude_side: list[str] = []
    for line in record.splitlines() + ["@@"]:
        if line == "@@":
            if codex_side or claude_side:
                units.append(
                    DivergentUnit(after, tuple(codex_side), tuple(claude_side), before)
                )
            elif after is not None or before is not None:
                raise ValueError("divergence record unit has context but no difference")
            after = before = None
            codex_side = []
            claude_side = []
        elif line.startswith((" ", "-", "+")):
            if not line[1:].strip():
                # The walk drops blank lines from both sources, so a blank
                # recorded line could never be matched by anything and would
                # make the record permanently unsatisfiable.
                raise ValueError(f"blank divergence record line: {line!r}")
            if line.startswith(" "):
                # Context before the difference anchors it from the left, after
                # it from the right; a second on either side is unreadable.
                if codex_side or claude_side:
                    if before is not None:
                        raise ValueError(f"second trailing context line: {line!r}")
                    before = line[1:]
                else:
                    if after is not None:
                        raise ValueError(f"second leading context line: {line!r}")
                    after = line[1:]
            elif line.startswith("-"):
                codex_side.append(line[1:])
            else:
                claude_side.append(line[1:])
        else:
            raise ValueError(f"undecidable divergence record line: {line!r}")
    return units


DOCUMENTED_UNITS = documented_units(DOCUMENTED_DIVERGENCE)


def rendered_unit(unit: DivergentUnit) -> str:
    """One divergent unit back in the DOCUMENTED_DIVERGENCE spelling."""
    lines = [] if unit.after is None else [f" {unit.after}"]
    lines.extend(f"-{line}" for line in unit.codex)
    lines.extend(f"+{line}" for line in unit.claude)
    if unit.before is not None:
        lines.append(f" {unit.before}")
    return "\n".join(lines)


def divergent_lines(unit: DivergentUnit) -> str:
    """Only the lines the two copies differ on -- never a context anchor.

    The backstop below reads this rather than the rendered unit: an anchor is a
    line both copies share, so letting one carry the pinning vocabulary would
    let an unrelated difference be recorded beside a neighbour saying "model".
    """
    return "\n".join(unit.codex + unit.claude)


def belongs_to_the_pinning_exception(unit: DivergentUnit) -> bool:
    return any(word in divergent_lines(unit).lower() for word in PINNING_VOCABULARY)


def belongs_to_the_route_binding_exception(unit: DivergentUnit) -> bool:
    text = divergent_lines(unit)
    return any(word in text for word in GROK_ROUTE_VOCABULARY)


def mirror_units(units: list[DivergentUnit]) -> list[DivergentUnit]:
    """The record as it reads with the two sources handed over swapped.

    A unit's anchors are lines the two copies SHARE, so they survive the swap
    untouched; only the two divergent sides trade places. This is the route
    issue #627 requires for the Codex-side regressions: every unit in the
    tracked record that has `-` lines also has `+` lines, and a two-sided unit
    is already held in place by the lockstep walk, so mirroring the real pair
    is the only way to put a floating unit on the Codex side of the comparator.
    """
    return [
        DivergentUnit(unit.after, unit.claude, unit.codex, unit.before)
        for unit in units
    ]


def _at(lines: list[tuple[int, str]], position: int) -> str:
    if position >= len(lines):
        return "end of file"
    number, text = lines[position]
    return f"line {number}: {text.strip()!r}"


def _follows_its_anchor(unit: DivergentUnit, present: dict[str, int], seen: bool) -> bool:
    """Has the unit's left anchor been consumed since the previous unit?

    An anchor a shared edit rewrote or deleted from both copies is gone from
    the sources, and is dropped rather than enforced: that edit is legitimate,
    and issue #627's selected policy is that shared-edit acceptance wins.
    """
    return unit.after is None or unit.after not in present or seen


def _precedes_its_anchor(unit: DivergentUnit, present: dict[str, int], index: int) -> bool:
    """Is the unit's right anchor still ahead of it?

    `present` holds each line's LAST position, so this asks whether some
    occurrence of the anchor remains after the unit -- not whether the anchor
    sits immediately next to it. That is what lets any amount of identically
    landed content separate the two.
    """
    if unit.before is None or unit.before not in present:
        return True
    return present[unit.before] >= index + len(unit.codex)


def divergence_report(
    codex_source: str,
    claude_source: str,
    units: list[DivergentUnit] | None = None,
) -> str | None:
    """None when the two sources differ in exactly `units`, else why they do not.

    No alignment is inferred. The walk consumes lines the two files share in
    lockstep and the recorded units in order, and reconciles them only if it
    can end both files and the record together with every unit still between
    the shared lines recorded around it. A line added identically to both
    copies is therefore a shared line wherever it lands, and cannot move the
    answer; text added, dropped, or edited in one copy only can be neither
    paired nor accounted for; and a recorded unit moved out from between its
    anchors fails too, up to the repeated-line limit the module docstring
    describes.
    """
    units = DOCUMENTED_UNITS if units is None else units
    codex = significant_lines(codex_source)
    claude = significant_lines(claude_source)
    codex_text = [text for _, text in codex]
    claude_text = [text for _, text in claude]
    present = {text: index for index, text in enumerate(codex_text)}

    # Consuming the first `k` units shifts the Claude cursor off the Codex one
    # by a fixed amount, so a walk state is (Codex index, units consumed) plus
    # whether the pending unit's left anchor has been passed.
    offsets = [0]
    for unit in units:
        offsets.append(offsets[-1] + len(unit.claude) - len(unit.codex))
    ends_together = len(claude_text) == len(codex_text) + offsets[-1]
    goal = (len(codex_text), len(units))

    reached = (0, 0)
    seen: set[tuple[int, int, bool]] = set()
    pending = [(0, 0, False)]
    while pending:
        state = pending.pop()
        if state in seen:
            continue
        seen.add(state)
        index, consumed, anchored = state
        if ends_together and (index, consumed) == goal:
            return None
        reached = max(reached, (index, consumed))
        cursor = index + offsets[consumed]
        unit = units[consumed] if consumed < len(units) else None
        if (
            index < len(codex_text)
            and 0 <= cursor < len(claude_text)
            and codex_text[index] == claude_text[cursor]
        ):
            passed = anchored or (unit is not None and unit.after == codex_text[index])
            pending.append((index + 1, consumed, passed))
        if (
            unit is not None
            and _follows_its_anchor(unit, present, anchored)
            and _precedes_its_anchor(unit, present, index)
            and cursor >= 0
            and tuple(codex_text[index : index + len(unit.codex)]) == unit.codex
            and tuple(claude_text[cursor : cursor + len(unit.claude)]) == unit.claude
        ):
            pending.append((index + len(unit.codex), consumed + 1, False))

    index, consumed = reached
    cursor = index + offsets[consumed]
    report = [
        f"Reconciled {consumed} of {len(units)} recorded divergent units, "
        "then could not account for:",
        f"  codex-plugin copy, {_at(codex, index)}",
        f"  claude-plugin copy, {_at(claude, cursor)}",
    ]
    if consumed < len(units):
        unit = units[consumed]
        report.append("The next recorded divergent unit, which did not apply there:")
        report.extend(f"  {line}" for line in rendered_unit(unit).splitlines())
        if not _precedes_its_anchor(unit, present, index):
            report.append(
                f"Its {unit.before.strip()!r} anchor is behind it: the unit has "
                "moved past the shared line it was recorded before."
            )
    else:
        report.append("Every recorded divergent unit was already accounted for.")
    return "\n".join(report)


def superseded_unified_divergence(codex_source: str, claude_source: str) -> str:
    """The rendered-diff comparator this gate shipped with before issue #624.

    Not the gate, and never to be made one again: it is kept so the
    shared-edit fixtures below can show they reproduce a real false failure
    rather than assert green against nothing.
    """
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


def superseded_grouped_divergence(codex_source: str, claude_source: str) -> str:
    """Issue #624's rejected candidate repair, kept for the same reason.

    Disabling `autojunk` and rendering `get_grouped_opcodes(0)` directly
    survives the closing parenthesis that defeated the rendering above, and
    then re-anchors on a blank line landed identically in both copies instead.
    """
    codex = codex_source.splitlines()
    claude = claude_source.splitlines()
    matcher = difflib.SequenceMatcher(a=codex, b=claude, autojunk=False)
    lines = []
    for group in matcher.get_grouped_opcodes(0):
        lines.append("@@")
        for tag, codex_start, codex_stop, claude_start, claude_stop in group:
            if tag in ("replace", "delete"):
                lines.extend(f"-{line}" for line in codex[codex_start:codex_stop])
            if tag in ("replace", "insert"):
                lines.extend(f"+{line}" for line in claude[claude_start:claude_stop])
    return "\n".join(lines)


# Every rendering issue #624 measured and rejected. A shared-edit fixture below
# names the ones it moves, which is what stops it asserting green vacuously.
ALIGNMENT_SENSITIVE_RENDERINGS = {
    "unified-diff hunks": superseded_unified_divergence,
    "autojunk=False grouped opcodes": superseded_grouped_divergence,
}

# Four lines, one of them the bare `        )` that failed the gate three
# times in pull request #622. On this snapshot one copy leaves the superseded
# rendering alone at publish_verdict, gate_status, and route_reviewers alike,
# so the fixture lands two uniquely named copies, which is what reproduces the
# reported blank-line movement rather than assuming one occurrence suffices.
CLOSING_PARENTHESIS_PROBES = "".join(
    f'def probe_{name}():\n    return (\n        "x"\n        )\n\n\n'
    for name in ("one", "two")
)

# (description, anchor the edit lands before, edit, renderings it moves)
SHARED_EDITS = (
    (
        "two closing-parenthesis probes",
        "def publish_verdict(",
        CLOSING_PARENTHESIS_PROBES,
        ("unified-diff hunks",),
    ),
    (
        "one blank line",
        "def kanban_models():",
        "\n",
        ("autojunk=False grouped opcodes",),
    ),
)


# The post-draft `verify_publication` call the issue #627 regressions move a
# recorded unit around. Each of these lines occurs exactly once at sixteen-space
# indentation in the Claude copy, and `result_models(results),` is the argument
# the Claude copy alone passes -- the recorded unit whose Codex side is empty.
CALL_INDENT = " " * 16
CALL_NUMBER = f"{CALL_INDENT}number,\n"
CALL_REVIEWERS = f"{CALL_INDENT}reviewers,\n"
CALL_MODELS = f"{CALL_INDENT}result_models(results),\n"
CALL_HEAD = f'{CALL_INDENT}pr["headRefOid"],\n'
CALL_VERDICT = f"{CALL_INDENT}verdict,\n"

# (description, fragment as tracked, the same lines with the model argument
# moved). Each is one-sided by construction: the Codex copy passes no model
# argument at all, so only the Claude copy carries these fragments.
UNIT_MOVES = (
    (
        "later across one shared line",
        CALL_MODELS + CALL_HEAD,
        CALL_HEAD + CALL_MODELS,
    ),
    (
        "later across two shared lines",
        CALL_MODELS + CALL_HEAD + CALL_VERDICT,
        CALL_HEAD + CALL_VERDICT + CALL_MODELS,
    ),
    (
        "earlier across one shared line",
        CALL_REVIEWERS + CALL_MODELS,
        CALL_MODELS + CALL_REVIEWERS,
    ),
    (
        "earlier across two shared lines",
        CALL_NUMBER + CALL_REVIEWERS + CALL_MODELS,
        CALL_MODELS + CALL_NUMBER + CALL_REVIEWERS,
    ),
)


class CoordinatorBoundedDivergenceTests(unittest.TestCase):
    """The two coordinators differ only where §2.2 says they may."""

    def setUp(self):
        self.codex_source = CODEX_COORDINATOR.read_text(encoding="utf-8")
        self.claude_source = CLAUDE_COORDINATOR.read_text(encoding="utf-8")

    def test_the_two_coordinators_differ_only_in_the_documented_pinning_exception(self):
        report = divergence_report(self.codex_source, self.claude_source)
        if report is not None:
            self.fail(f"{DIVERGENCE_GUIDANCE}\n\n{report}")

    def test_every_recorded_divergent_unit_belongs_to_the_pinning_exception(self):
        self.assertTrue(DOCUMENTED_UNITS, "DOCUMENTED_DIVERGENCE records no units")
        for index, unit in enumerate(DOCUMENTED_UNITS):
            with self.subTest(unit=index):
                self.assertTrue(
                    belongs_to_the_pinning_exception(unit),
                    f"Recorded divergence unit {index} names neither model nor "
                    f"effort, so it is not part of the §2.2 exception:\n"
                    f"{rendered_unit(unit)}",
                )

    def test_a_recorded_unit_outside_the_pinning_vocabulary_is_rejected(self):
        # The backstop above is worth something only if it can fail. Dropping
        # hunk boundaries for unit boundaries kept each recorded difference an
        # independently checked one; recording the whole constant as a single
        # unit would have reduced that test to one model-or-effort word
        # anywhere in the file.
        unrelated = documented_units(
            "@@\n-REVIEW_TIMEOUT_SECONDS = 7200\n+REVIEW_TIMEOUT_SECONDS = 60"
        )
        self.assertEqual(len(unrelated), 1)
        self.assertFalse(belongs_to_the_pinning_exception(unrelated[0]))

    def test_a_context_anchor_cannot_carry_the_pinning_vocabulary(self):
        # A context line is a line both copies share, so it says nothing about
        # what diverges. Reading one would let an unrelated difference be
        # recorded here under a neighbour that happens to mention a model.
        smuggled = documented_units(
            "@@\n CODEX_NESTED_REVIEW_MODEL = \"gpt-5.6-sol\"\n"
            "-REVIEW_TIMEOUT_SECONDS = 7200\n+REVIEW_TIMEOUT_SECONDS = 60"
        )
        self.assertEqual(len(smuggled), 1)
        self.assertIn("model", rendered_unit(smuggled[0]).lower())
        self.assertFalse(belongs_to_the_pinning_exception(smuggled[0]))

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


class GrokCoordinatorBoundedDivergenceTests(unittest.TestCase):
    """The Grok coordinator differs from Claude in expected-origin/route,
    in not vendoring kanban_config.py beside the coordinator, and in
    reading a grok marker on a cross-repository pull request."""

    def setUp(self):
        self.claude_source = CLAUDE_COORDINATOR.read_text(encoding="utf-8")
        self.grok_source = GROK_COORDINATOR.read_text(encoding="utf-8")
        self.units = documented_units(GROK_DOCUMENTED_DIVERGENCE)

    def test_grok_differs_from_claude_only_in_the_route_binding_extension(self):
        report = divergence_report(self.claude_source, self.grok_source, self.units)
        if report is not None:
            self.fail(
                "The Grok coordinator diverges from the Claude copy outside "
                "the --expected-origin/--expected-route extension, the "
                "kanban_config.py vendor claim, and cross-repository grok "
                "provenance.\n\n"
                f"{report}"
            )

    def test_every_recorded_grok_unit_belongs_to_the_route_binding_exception(self):
        self.assertTrue(self.units, "GROK_DOCUMENTED_DIVERGENCE records no units")
        for index, unit in enumerate(self.units):
            with self.subTest(unit=index):
                self.assertTrue(
                    belongs_to_the_route_binding_exception(unit),
                    f"Grok divergence unit {index} is not the route-binding "
                    f"extension:\n{rendered_unit(unit)}",
                )

    def test_an_unrelated_grok_only_line_fails_the_gate(self):
        drifted = self.grok_source.replace(
            "REVIEW_TIMEOUT_SECONDS = 7200",
            "REVIEW_TIMEOUT_SECONDS = 60",
            1,
        )
        report = divergence_report(self.claude_source, drifted, self.units)
        self.assertIsNotNone(report)

class KimiCoordinatorBoundedDivergenceTests(unittest.TestCase):
    """The Kimi coordinator differs from Claude in expected-origin/route,
    in not vendoring kanban_config.py beside the coordinator, and in
    reading a kimi marker on a cross-repository pull request."""

    def setUp(self):
        self.claude_source = CLAUDE_COORDINATOR.read_text(encoding="utf-8")
        self.kimi_source = KIMI_COORDINATOR.read_text(encoding="utf-8")
        self.units = documented_units(KIMI_DOCUMENTED_DIVERGENCE)

    def test_kimi_differs_from_claude_only_in_the_route_binding_extension(self):
        report = divergence_report(self.claude_source, self.kimi_source, self.units)
        if report is not None:
            self.fail(
                "The Kimi coordinator diverges from the Claude copy outside "
                "the --expected-origin/--expected-route extension, the "
                "kanban_config.py vendor claim, and cross-repository kimi "
                "provenance.\n\n"
                f"{report}"
            )

    def test_every_recorded_kimi_unit_belongs_to_the_route_binding_exception(self):
        self.assertTrue(self.units, "KIMI_DOCUMENTED_DIVERGENCE records no units")
        for index, unit in enumerate(self.units):
            with self.subTest(unit=index):
                self.assertTrue(
                    belongs_to_the_route_binding_exception(unit),
                    f"Kimi divergence unit {index} is not the route-binding "
                    f"extension:\n{rendered_unit(unit)}",
                )

    def test_an_unrelated_kimi_only_line_fails_the_gate(self):
        drifted = self.kimi_source.replace(
            "REVIEW_TIMEOUT_SECONDS = 7200",
            "REVIEW_TIMEOUT_SECONDS = 60",
            1,
        )
        report = divergence_report(self.claude_source, drifted, self.units)
        self.assertIsNotNone(report)


class SharedEditStabilityTests(unittest.TestCase):
    """A change landed identically in both copies cannot move the answer.

    Issue #624: it could, and the failure it produced told the author to land
    the change in both copies -- which is what they had just done. Each case
    below lands one edit in BOTH copies and asserts the gate stays green,
    together with the renderings that edit was measured to move, so a fixture
    cannot quietly stop reproducing the false failure it exists for.
    """

    def setUp(self):
        self.codex_source = CODEX_COORDINATOR.read_text(encoding="utf-8")
        self.claude_source = CLAUDE_COORDINATOR.read_text(encoding="utf-8")
        # The unedited pair must reconcile, or every case below passes vacuously.
        self.assertIsNone(divergence_report(self.codex_source, self.claude_source))

    def land_in_both(self, anchor: str, edit: str) -> tuple[str, str]:
        landed = []
        for source in (self.codex_source, self.claude_source):
            self.assertEqual(
                source.count(anchor),
                1,
                f"shared-edit fixture is stale: {anchor!r} is not unique",
            )
            landed.append(source.replace(anchor, edit + anchor, 1))
        return landed[0], landed[1]

    def test_an_edit_landed_in_both_copies_keeps_the_gate_green(self):
        for description, anchor, edit, _ in SHARED_EDITS:
            with self.subTest(edit=description):
                codex_source, claude_source = self.land_in_both(anchor, edit)
                report = divergence_report(codex_source, claude_source)
                self.assertIsNone(
                    report,
                    f"landing {description} before {anchor!r} in BOTH copies was "
                    f"reported as divergence:\n{report}",
                )

    def test_each_shared_edit_still_moves_the_rendering_it_reproduces(self):
        for description, anchor, edit, moved in SHARED_EDITS:
            codex_source, claude_source = self.land_in_both(anchor, edit)
            for name in moved:
                with self.subTest(edit=description, rendering=name):
                    render = ALIGNMENT_SENSITIVE_RENDERINGS[name]
                    self.assertNotEqual(
                        render(codex_source, claude_source),
                        render(self.codex_source, self.claude_source),
                        f"landing {description} before {anchor!r} no longer moves "
                        f"the {name} rendering, so this fixture asserts nothing",
                    )

    def test_every_rejected_rendering_is_reproduced_by_some_shared_edit(self):
        named = {name for _, _, _, moved in SHARED_EDITS for name in moved}
        self.assertEqual(named, set(ALIGNMENT_SENSITIVE_RENDERINGS))

    def test_a_repeated_line_appended_to_both_sources_keeps_the_gate_green(self):
        # The alignment class in the small: with one divergent unit recorded,
        # appending the SAME line to both sources reorders the superseded
        # renderings' `-`/`+` pair, because which occurrence of that line the
        # matcher anchors on changes. The walk pairs the appended lines and
        # applies the recorded unit where it stands.
        # No anchors: this pair has no shared line to record one from, which
        # is also the shape `_follows_its_anchor` and `_precedes_its_anchor`
        # treat as unconstrained.
        units = [DivergentUnit(None, ("x = 0",), ("y = 0",), None)]
        for suffix in ("", "x = 0\n"):
            with self.subTest(appended=suffix):
                self.assertIsNone(
                    divergence_report("x = 0\n" + suffix, "y = 0\n" + suffix, units)
                )
        for name, render in ALIGNMENT_SENSITIVE_RENDERINGS.items():
            with self.subTest(rendering=name):
                self.assertNotEqual(
                    render("x = 0\n", "y = 0\n"),
                    render("x = 0\nx = 0\n", "y = 0\nx = 0\n"),
                    f"the {name} rendering no longer reorders here, so this "
                    "fixture asserts nothing",
                )

    def test_a_one_sided_blank_line_is_not_reported(self):
        # Requirement 3 of issue #624: whitespace-only regrouping is not
        # divergence in either direction. This is the one property the walk
        # gives up, and giving it up is what keeps blank-line grouping -- the
        # thing both superseded renderings churned on -- out of the answer.
        for name in ("codex", "claude"):
            with self.subTest(coordinator=name):
                sources = {
                    "codex": self.codex_source,
                    "claude": self.claude_source,
                }
                anchor = "REVIEW_TIMEOUT_SECONDS = 7200"
                self.assertEqual(sources[name].count(anchor), 1)
                sources[name] = sources[name].replace(anchor, f"\n{anchor}", 1)
                self.assertIsNone(
                    divergence_report(sources["codex"], sources["claude"])
                )


class PlantedDivergenceTests(unittest.TestCase):
    """The comparator has to actually fire.

    Each case takes the real sources and changes ordinary, non-pinning
    behavior in one copy only -- including inside invoke_codex/invoke_claude,
    the functions a comparator built on region exclusions would skip -- then
    asserts the comparator reports divergence.
    """

    # Properties a representation that sorted, deduplicated, re-indented, or
    # dropped comments from its differing lines would silently stop
    # protecting. Blank lines are the only thing normalized away, so each of
    # these is planted one copy at a time, in both directions.
    PROTECTED_PROPERTIES = (
        (
            "indentation",
            "REVIEW_TIMEOUT_SECONDS = 7200",
            "    REVIEW_TIMEOUT_SECONDS = 7200",
        ),
        (
            "a comment's wording",
            "    # loads no provider cannot review this pull request whatever it says, and\n",
            "    # loads no provider is in no position to review it, and\n",
        ),
        (
            "statement order",
            "from dataclasses import dataclass\nfrom pathlib import Path\n",
            "from pathlib import Path\nfrom dataclasses import dataclass\n",
        ),
        (
            "how many times a line appears",
            "from pathlib import Path\n",
            "from pathlib import Path\nfrom pathlib import Path\n",
        ),
    )

    def setUp(self):
        self.codex_source = CODEX_COORDINATOR.read_text(encoding="utf-8")
        self.claude_source = CLAUDE_COORDINATOR.read_text(encoding="utf-8")
        # The unplanted pair must match, or every case below passes vacuously.
        self.assertIsNone(divergence_report(self.codex_source, self.claude_source))

    def plant(self, source: str, original: str, replacement: str) -> str:
        self.assertEqual(
            source.count(original),
            1,
            f"planted-violation fixture is stale: {original!r} is not unique",
        )
        return source.replace(original, replacement, 1)

    def assert_caught(self, codex_source: str, claude_source: str, message: str):
        self.assertIsNotNone(
            divergence_report(codex_source, claude_source), message
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

    def test_a_one_sided_change_to_a_protected_property_is_caught(self):
        for name, original, replacement in self.PROTECTED_PROPERTIES:
            for coordinator in ("claude", "codex"):
                with self.subTest(property=name, coordinator=coordinator):
                    sources = {
                        "codex": self.codex_source,
                        "claude": self.claude_source,
                    }
                    sources[coordinator] = self.plant(
                        sources[coordinator], original, replacement
                    )
                    self.assert_caught(
                        sources["codex"],
                        sources["claude"],
                        f"changing {name} in only the {coordinator.title()} copy "
                        "was not caught",
                    )

    def test_a_reordered_line_inside_a_recorded_unit_is_caught(self):
        # The recorded exception is order-sensitive too: a representation that
        # compared differing lines as a multiset would report these two
        # Claude-only lines as unchanged after the swap.
        self.assert_caught(
            self.codex_source,
            self.plant(
                self.claude_source,
                'CODEX_NESTED_REVIEW_MODEL = "gpt-5.6-sol"\n'
                'CODEX_NESTED_REVIEW_EFFORT = "xhigh"\n',
                'CODEX_NESTED_REVIEW_EFFORT = "xhigh"\n'
                'CODEX_NESTED_REVIEW_MODEL = "gpt-5.6-sol"\n',
            ),
            "reordering two lines inside a recorded divergent unit was not caught",
        )


class UnitPositionTests(unittest.TestCase):
    """A recorded unit may not leave the shared lines recorded around it.

    Issue #627: order alone was not enough. A unit whose Codex side is empty
    matches the zero-length slice at any cursor, so the Claude-only
    `result_models(results),` argument could sit anywhere between its
    neighbouring recorded units and still reconcile -- including on the far
    side of `pr["headRefOid"],`, which hands `verify_publication` a list where
    it expects a head SHA. Every case below changes ONE source.
    """

    def setUp(self):
        self.codex_source = CODEX_COORDINATOR.read_text(encoding="utf-8")
        self.claude_source = CLAUDE_COORDINATOR.read_text(encoding="utf-8")
        # Both orientations of the untouched pair must reconcile, or every case
        # below passes vacuously.
        self.assertIsNone(divergence_report(self.codex_source, self.claude_source))
        self.assertIsNone(
            divergence_report(
                self.claude_source, self.codex_source, mirror_units(DOCUMENTED_UNITS)
            )
        )

    def move(self, fragment: str, moved: str) -> str:
        """The Claude copy with one recorded unit moved and nothing else.

        The multiset assertion is what makes this a pure reposition: a fixture
        that also added, dropped, or edited a line would exercise the ordinary
        content comparison instead of the positional constraint under test.
        """
        self.assertEqual(
            self.claude_source.count(fragment), 1, f"stale fixture: {fragment!r}"
        )
        source = self.claude_source.replace(fragment, moved, 1)
        self.assertNotEqual(source, self.claude_source, "the fixture changed nothing")
        self.assertEqual(
            sorted(source.splitlines()),
            sorted(self.claude_source.splitlines()),
            "the fixture did more than move a line",
        )
        return source

    def assert_codex_untouched(self):
        self.assertEqual(
            self.codex_source, CODEX_COORDINATOR.read_text(encoding="utf-8")
        )

    def test_the_reported_argument_swap_is_caught(self):
        # The exact swap issue #627 reports, in the post-draft call.
        swapped = self.move(CALL_MODELS + CALL_HEAD, CALL_HEAD + CALL_MODELS)
        self.assert_codex_untouched()
        self.assertIsNotNone(
            divergence_report(self.codex_source, swapped),
            "swapping the model and head arguments in only the Claude copy was "
            "not caught",
        )

    def test_the_reported_swap_escapes_a_record_without_position_anchors(self):
        # The comparator as issue #624 left it, reproduced by dropping the
        # anchors this change adds. It accepts the swap, which is the defect.
        # Without this control the regression above could pass under a
        # mechanism that never had teeth for it.
        unanchored = [
            DivergentUnit(None, unit.codex, unit.claude, None)
            for unit in DOCUMENTED_UNITS
        ]
        self.assertIsNone(
            divergence_report(self.codex_source, self.claude_source, unanchored)
        )
        swapped = self.move(CALL_MODELS + CALL_HEAD, CALL_HEAD + CALL_MODELS)
        self.assertIsNone(
            divergence_report(self.codex_source, swapped, unanchored),
            "the unanchored record no longer reproduces issue #627, so the "
            "regression above asserts nothing",
        )

    def test_a_one_sided_move_is_caught_on_either_comparator_side(self):
        # Side x direction x distance. The Codex side goes through the mirror
        # route of `mirror_units`, since the tracked record has no unit whose
        # Claude side is empty to float there otherwise.
        for description, fragment, moved_fragment in UNIT_MOVES:
            moved = self.move(fragment, moved_fragment)
            self.assert_codex_untouched()
            for side in ("claude", "codex"):
                with self.subTest(move=description, side=side):
                    if side == "claude":
                        report = divergence_report(self.codex_source, moved)
                    else:
                        report = divergence_report(
                            moved, self.codex_source, mirror_units(DOCUMENTED_UNITS)
                        )
                    self.assertIsNotNone(
                        report,
                        f"moving the model argument {description}, with the "
                        f"unit on the {side} side, was not caught",
                    )

    def test_identical_content_around_a_one_sided_unit_stays_green(self):
        # Requirement 2: the anchors are order constraints, not adjacency ones,
        # so identically landed lines may separate a unit from either of them.
        # The unit surrounded here is one-sided, so the constraint is really
        # exercised; a two-sided unit is already held in place by the walk.
        filler = f"{CALL_INDENT}# noted\n"
        cases = {
            "immediately before the unit": (
                (CALL_HEAD, filler + CALL_HEAD),
                (CALL_MODELS, filler + CALL_MODELS),
            ),
            "immediately after the unit": (
                (CALL_HEAD, filler + CALL_HEAD),
                (CALL_HEAD, filler + CALL_HEAD),
            ),
            "on both sides of the unit": (
                (CALL_HEAD, filler + filler + CALL_HEAD),
                (CALL_MODELS + CALL_HEAD, filler + CALL_MODELS + filler + CALL_HEAD),
            ),
        }
        for description, (codex_edit, claude_edit) in cases.items():
            with self.subTest(inserted=description):
                codex_source = self.plant(self.codex_source, *codex_edit)
                claude_source = self.plant(self.claude_source, *claude_edit)
                self.assertIn(filler, codex_source)
                self.assertIn(filler, claude_source)
                self.assertIsNone(
                    divergence_report(codex_source, claude_source),
                    f"landing content {description} in BOTH copies was reported "
                    "as divergence",
                )

    def plant(self, source: str, original: str, replacement: str) -> str:
        self.assertEqual(source.count(original), 1, f"stale fixture: {original!r}")
        planted = source.replace(original, replacement, 1)
        self.assertNotEqual(planted, source, "the fixture inserted nothing")
        return planted

    def test_both_repeated_line_pairs_of_the_selected_policy_pass(self):
        """Issue #627's A/B table, built from the tracked call.

        Writing R, M, H and V for the reviewers, model, head and verdict
        arguments, the tracked fragments are Codex `R H V` and Claude `R M H V`.
        Inserting H identically before V gives pair A; inserting H identically
        after R gives pair B. Both come from one identical shared insertion, so
        both must pass -- even though A becomes B by moving only Claude's M
        across one H. The gate is handed final sources and a record, never the
        history that produced them, so that movement is an accepted limit.
        """
        pair_a = (
            self.plant(self.codex_source, CALL_HEAD + CALL_VERDICT, CALL_HEAD + CALL_HEAD + CALL_VERDICT),
            self.plant(self.claude_source, CALL_MODELS + CALL_HEAD + CALL_VERDICT, CALL_MODELS + CALL_HEAD + CALL_HEAD + CALL_VERDICT),
        )
        pair_b = (
            self.plant(self.codex_source, CALL_REVIEWERS + CALL_HEAD, CALL_REVIEWERS + CALL_HEAD + CALL_HEAD),
            self.plant(self.claude_source, CALL_REVIEWERS + CALL_MODELS, CALL_REVIEWERS + CALL_HEAD + CALL_MODELS),
        )
        self.assertEqual(
            pair_a[0], pair_b[0], "A and B must reach the same Codex source"
        )
        self.assertNotEqual(
            pair_a[1], pair_b[1], "A and B must differ only in the Claude source"
        )
        self.assertEqual(
            sorted(pair_a[1].splitlines()),
            sorted(pair_b[1].splitlines()),
            "A becomes B by moving the model argument, not by editing one",
        )
        for name, (codex_source, claude_source) in (("A", pair_a), ("B", pair_b)):
            with self.subTest(pair=name):
                self.assertIsNone(divergence_report(codex_source, claude_source))
                self.assertIsNone(
                    divergence_report(
                        claude_source, codex_source, mirror_units(DOCUMENTED_UNITS)
                    ),
                    f"pair {name} was reported as divergence on the mirrored side",
                )

    def test_a_shared_rewrite_of_both_neighbours_stays_green(self):
        # An anchor a shared edit rewrote away is dropped rather than enforced,
        # so this needs no record change: turning it into a failure would
        # re-create exactly the issue #624 false failure whose advice --
        # land it in the other copy -- the author had already followed.
        renamed = {
            CALL_REVIEWERS: f"{CALL_INDENT}reviewer_set,\n",
            CALL_HEAD: f"{CALL_INDENT}head_sha,\n",
        }
        codex_source, claude_source = self.codex_source, self.claude_source
        for original, replacement in renamed.items():
            codex_source = self.plant(codex_source, original, replacement)
            claude_source = self.plant(claude_source, original, replacement)
        self.assertIsNone(
            divergence_report(codex_source, claude_source),
            "rewriting a recorded unit's neighbouring lines in BOTH copies was "
            "reported as divergence",
        )

    def test_a_context_anchor_keeps_its_source_backslashes(self):
        # DOCUMENTED_DIVERGENCE is a raw string because a context line is
        # ordinary source, and this one carries `\n` inside a string literal.
        # An ordinary triple-quoted constant turns that into a real newline,
        # splitting the record line in two -- which `documented_units` refuses,
        # but only because it checks every line's prefix.
        anchor = '    body = "\\n".join(lines).rstrip() + "\\n"'
        self.assertIn(anchor, self.codex_source.splitlines())
        self.assertIn(anchor, self.claude_source.splitlines())
        self.assertIn(
            anchor,
            [unit.after for unit in DOCUMENTED_UNITS]
            + [unit.before for unit in DOCUMENTED_UNITS],
        )


if __name__ == "__main__":
    unittest.main()
