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
leaves a line the walk can neither pair nor account for, so it fails.

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

# Every non-blank line on which the two copies differ, as Codex-only (`-`) and
# Claude-only (`+`) lines grouped into units by a bare `@@`. Line numbers are
# not recorded: they would churn on every shared edit that lands correctly in
# both copies, which is exactly the change this gate must stay quiet about.
# What remains -- the differing lines, their order, and the unit boundaries
# between them -- is the divergence itself, and it is complete: a difference
# anywhere else in either file is a line the reconciliation walk cannot
# account for.
#
# Issue #624 regenerated this constant mechanically, from the same two tracked
# files it already described, when the comparison moved off rendered diff text
# onto the reconciliation walk. Nothing was blessed and nothing was added: the
# 122 lines recorded below are the previous constant's 127 with its 5 blank
# entries dropped -- the same lines, in the same order, re-cut into the unit
# boundaries the walk reads instead of the hunk boundaries a diff rendered.
#
# Update this ONLY together with docs/agent-workflow-contract.md §2.2 and
# claude-plugin/README.md, which is what makes it a record of a reviewed
# exception rather than a snapshot of whatever the two files happen to be.
DOCUMENTED_DIVERGENCE = '''\
@@
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
@@
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
# divergence has to smuggle the new lines past this too, so a unit that has
# nothing to do with model or effort pinning cannot be recorded as though it
# were part of the pinning exception.
PINNING_VOCABULARY = ("model", "effort")

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
    "report below names the exact line that could not be accounted for. Only "
    "a reviewed change to the pinning exception itself may update "
    "DOCUMENTED_DIVERGENCE."
)


def significant_lines(source: str) -> list[tuple[int, str]]:
    """Every non-blank line of `source`, as (1-based line number, text)."""
    return [
        (number, line)
        for number, line in enumerate(source.splitlines(), 1)
        if line.strip()
    ]


def documented_units(record: str) -> list[tuple[tuple[str, ...], tuple[str, ...]]]:
    """A DOCUMENTED_DIVERGENCE record as ordered (Codex-only, Claude-only) runs."""
    units: list[tuple[tuple[str, ...], tuple[str, ...]]] = []
    codex_side: list[str] = []
    claude_side: list[str] = []
    for line in record.splitlines() + ["@@"]:
        if line == "@@":
            if codex_side or claude_side:
                units.append((tuple(codex_side), tuple(claude_side)))
            codex_side = []
            claude_side = []
        elif line.startswith(("-", "+")):
            if not line[1:].strip():
                # The walk drops blank lines from both sources, so a blank
                # recorded line could never be matched by anything and would
                # make the record permanently unsatisfiable.
                raise ValueError(f"blank divergence record line: {line!r}")
            side = codex_side if line.startswith("-") else claude_side
            side.append(line[1:])
        else:
            raise ValueError(f"undecidable divergence record line: {line!r}")
    return units


DOCUMENTED_UNITS = documented_units(DOCUMENTED_DIVERGENCE)


def rendered_unit(unit: tuple[tuple[str, ...], tuple[str, ...]]) -> str:
    """One divergent unit back in the DOCUMENTED_DIVERGENCE spelling."""
    codex_side, claude_side = unit
    return "\n".join(
        [f"-{line}" for line in codex_side] + [f"+{line}" for line in claude_side]
    )


def belongs_to_the_pinning_exception(
    unit: tuple[tuple[str, ...], tuple[str, ...]],
) -> bool:
    return any(word in rendered_unit(unit).lower() for word in PINNING_VOCABULARY)


def _at(lines: list[tuple[int, str]], position: int) -> str:
    if position >= len(lines):
        return "end of file"
    number, text = lines[position]
    return f"line {number}: {text.strip()!r}"


def divergence_report(
    codex_source: str,
    claude_source: str,
    units: list[tuple[tuple[str, ...], tuple[str, ...]]] | None = None,
) -> str | None:
    """None when the two sources differ in exactly `units`, else why they do not.

    No alignment is inferred. The walk consumes lines the two files share in
    lockstep and the recorded units in order, and reconciles them only if it
    can end both files and the record together. A line added identically to
    both copies is therefore a shared line wherever it lands, and cannot move
    the answer; a line added to one copy only can be neither paired nor
    accounted for, and fails.
    """
    units = DOCUMENTED_UNITS if units is None else units
    codex = significant_lines(codex_source)
    claude = significant_lines(claude_source)
    codex_text = [text for _, text in codex]
    claude_text = [text for _, text in claude]

    # Consuming the first `k` units shifts the Claude cursor off the Codex one
    # by a fixed amount, so a walk state is just (Codex index, units consumed).
    offsets = [0]
    for codex_side, claude_side in units:
        offsets.append(offsets[-1] + len(claude_side) - len(codex_side))
    ends_together = len(claude_text) == len(codex_text) + offsets[-1]
    goal = (len(codex_text), len(units))

    reached = (0, 0)
    seen: set[tuple[int, int]] = set()
    pending = [(0, 0)]
    while pending:
        state = pending.pop()
        if state in seen:
            continue
        seen.add(state)
        if ends_together and state == goal:
            return None
        reached = max(reached, state)
        index, consumed = state
        cursor = index + offsets[consumed]
        if (
            index < len(codex_text)
            and 0 <= cursor < len(claude_text)
            and codex_text[index] == claude_text[cursor]
        ):
            pending.append((index + 1, consumed))
        if consumed < len(units):
            codex_side, claude_side = units[consumed]
            if (
                cursor >= 0
                and tuple(codex_text[index : index + len(codex_side)]) == codex_side
                and tuple(claude_text[cursor : cursor + len(claude_side)]) == claude_side
            ):
                pending.append((index + len(codex_side), consumed + 1))

    index, consumed = reached
    cursor = index + offsets[consumed]
    report = [
        f"Reconciled {consumed} of {len(units)} recorded divergent units, "
        "then could not account for:",
        f"  codex-plugin copy, {_at(codex, index)}",
        f"  claude-plugin copy, {_at(claude, cursor)}",
    ]
    if consumed < len(units):
        report.append("The next recorded divergent unit, which did not apply there:")
        report.extend(
            f"  {line}" for line in rendered_unit(units[consumed]).splitlines()
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
        units = [(("x = 0",), ("y = 0",))]
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
                'CODEX_NESTED_REVIEW_MODEL = "gpt-5.6-terra"\n'
                'CODEX_NESTED_REVIEW_EFFORT = "xhigh"\n',
                'CODEX_NESTED_REVIEW_EFFORT = "xhigh"\n'
                'CODEX_NESTED_REVIEW_MODEL = "gpt-5.6-terra"\n',
            ),
            "reordering two lines inside a recorded divergent unit was not caught",
        )


if __name__ == "__main__":
    unittest.main()
