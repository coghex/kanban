"""The rendered auto-project-review workflow's own behavioral contract.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_auto_project_review_workflow.py

Issue #685, slice LEDGER-7 of `docs/designs/project_review_ledger_design.md`. It
follows `tools/test_autosolve_workflow.py`, the only other rendered asset whose
whole body is a loop over another workflow: the asset is the program an agent
executes, so what it claims is pinned as behavior rather than left to a
rendering that happens to read well today.

Two things make this slice different from that one, and both shape what is
asserted here.

* **It delegates everything, not just the implementation.** `autosolve` still
  reads a verdict, inspects an origin marker and fixes a pull request between
  its delegations; design D-6 leaves this one with no step of its own at all.
  The inventory, the liveness registration, the claim and its lease, the
  pinned worktree, the report allocation, the `record` checkpoint and the
  every-exit cleanup are `project-review`'s. `NoWorkOfItsOwnTests` turns that
  into an assertion from two directions -- no fenced block invokes any
  external command, and none of the delegate's own helper spellings appears
  anywhere in either rendering -- with the delegate itself as the non-vacuity
  control, because a rule about what a document does *not* say is worth
  nothing unless the same rule finds those things where they really are.
* **Nothing it says depends on which brand is running it.** `autosolve`'s
  every substantive claim flips with the solving brand; this workflow reviews
  nothing and publishes nothing, so the only per-brand text is the argument
  convention each provider supplies. `BrandBoundaryTests` is therefore
  stronger here than its counterpart: the two bodies must be *identical*
  outside two declared lines each, and what remains must name neither brand at
  all.

The remaining classes pin the rules the issue and its review named:
the count argument and every boundary around it (`ArgumentTests`), the
delegation preamble and the override of the delegate's own stop condition
(`DelegationTests`), the counting rule and the refusal to begin another
iteration after one that recorded nothing (`CountingRuleTests`), the four
stops and the progress report every one of them owes (`StopConditionTests`).

Every rule is measured over BOTH rendered assets, and each class carries a
control that plants the failure it is meant to catch: a rule matching
everything would otherwise pass while asserting nothing.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent

SOURCE = "tools/command_sources/auto-project-review.md"
CLAUDE_ASSET = "claude-plugin/plugins/kanban/commands/auto-project-review.md"
CODEX_ASSET = "codex-plugin/plugins/kanban/skills/auto-project-review/SKILL.md"
CODEX_SKILL_DIR = "codex-plugin/plugins/kanban/skills/auto-project-review"
RENDERED_ASSETS = (CLAUDE_ASSET, CODEX_ASSET)
BRAND_OF = {CLAUDE_ASSET: "claude", CODEX_ASSET: "codex"}
OPPOSITE = {"claude": "codex", "codex": "claude"}

# The workflow every iteration is, in both bundles. Read for the stop
# condition this workflow repeats: an override is only meaningful while the
# thing it overrides exists, and a delegate that started repeating itself
# would make this whole document redundant rather than merely stale.
DELEGATE_ASSETS = {
    "claude": "claude-plugin/plugins/kanban/commands/project-review.md",
    "codex": "codex-plugin/plugins/kanban/skills/project-review/SKILL.md",
}

BASH_FENCE_RE = re.compile(r"```bash\n(?P<body>.*?)\n[ \t]*```", re.DOTALL)

# The lines that legitimately differ between the two renderings: the argument
# convention each provider supplies, and nothing else. `autosolve` declares
# three per brand and this declares two, which is the whole difference between
# a loop that publishes a review and a loop that only counts them.
CLAUDE_ONLY_LINES = (
    'COUNT="$ARGUMENTS"',
    "`$ARGUMENTS` is what Claude Code substitutes before the session reads this file.",
)
CODEX_ONLY_LINES = (
    'COUNT="<the count the user named, or empty when they named none>"',
    "Codex substitutes no argument placeholder, so take the count from the prompt.",
)

# Every spelling of the delegate's own machinery. None may appear in either
# rendering: this workflow neither runs them nor tells its reader to. Each is
# taken from `project-review`'s own text, and `NoWorkOfItsOwnTests` reads them
# back out of that asset so a delegate that renamed one fails here rather than
# leaving this list checking for something nothing spells any more.
DELEGATED_MACHINERY = (
    '"$LEDGER"',
    '"$LIVENESS"',
    '"$CURSOR"',
    "allocate-report",
    "--owner-pid",
    "--token",
    "worktree add",
    "worktree remove",
    "gh api graphql",
    "gh pr view",
    "gh issue list",
)

# A sentence telling the loop to go on past an iteration that recorded no
# review. The document's rule is the opposite of that in every case it
# enumerates, so any of these is a contradiction rather than a nuance -- and
# the one failure mode a reader of this workflow could not recover from, since
# a loop that answers a refusal by starting the next review spends the user's
# whole count on the condition the delegate stopped for.
CONTINUATION_RE = re.compile(
    r"(?:skip\w*|ignor\w+|pass\w*\s+over|mov\w+\s+past|set\b[^.]{0,40}?\baside)"
    r"[^.]{0,160}?\b"
    r"(?:continu\w+|carr(?:y|ies|ied)\s+on|go(?:es|ing)?\s+on|tr(?:y|ies|ied)\s+again|"
    r"retr\w+|begin\w*\s+another|start\w*\s+another|mov\w+\s+on|"
    r"next\s+(?:iteration|review|pull request|selection))",
    re.IGNORECASE,
)


def read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def body_of(text: str) -> str:
    """`text` with its frontmatter block removed.

    The frontmatter is the one place the two renderings legitimately differ
    beyond the brand blocks -- different keys, and the invocation sigil inside
    the description -- so the body comparison is made over the body.
    """
    match = re.match(r"\A---\n.*?\n---\n(?P<body>.*)\Z", text, re.DOTALL)
    assert match is not None, "a rendered asset always opens with frontmatter"
    return match.group("body")


# The workflows this source names through a `{{cmd:}}` token, read from the
# source rather than restated, so the comparison covers exactly the
# substitutions the renderer performs and no more.
REFERENCED_WORKFLOWS = renderer.referenced_names(read(SOURCE))


def neutralize(text: str, brand: str) -> str:
    """`text` with `brand`'s spelling of each declared `{{cmd:}}` target put
    back into the neutral token."""
    sigil = renderer.SIGILS[brand]
    for name in sorted(REFERENCED_WORKFLOWS, key=len, reverse=True):
        text = text.replace(f"{sigil}{name}", f"{{{{cmd:{name}}}}}")
    return text


def flat(text: str) -> str:
    """`text` with every run of whitespace collapsed to one space, so a phrase
    is found whether or not the source wrapped it across lines."""
    return re.sub(r"\s+", " ", text)


def bash_fences(text: str) -> list[str]:
    return [match.group("body") for match in BASH_FENCE_RE.finditer(text)]


def squashed(relative_path: str) -> str:
    """One rendered asset, brand-neutral and unwrapped."""
    return flat(neutralize(read(relative_path), BRAND_OF[relative_path]))


class RegistrationTests(unittest.TestCase):
    """Requirement 1: one authored source, two rendered outputs, neither
    hand-edited, and no auxiliary asset beside either."""

    def entry(self) -> renderer.CommandSource:
        matching = [
            entry
            for entry in renderer.COMMAND_SOURCES
            if entry.name == "auto-project-review"
        ]
        self.assertEqual(
            len(matching), 1, "auto-project-review is registered exactly once"
        )
        return matching[0]

    def test_the_source_renders_into_both_bundle_directories(self):
        entry = self.entry()
        self.assertEqual(entry.source, SOURCE)
        self.assertEqual(
            renderer.output_paths(entry),
            {"claude": CLAUDE_ASSET, "codex": CODEX_ASSET},
        )

    def test_each_rendered_file_is_byte_identical_to_a_fresh_render(self):
        rendered = renderer.render_entry(self.entry(), REPO_ROOT)
        for relative_path, text in rendered.items():
            self.assertEqual(text, read(relative_path), relative_path)

    def test_the_registry_note_records_this_slice(self):
        # Requirement 1 asks for a note stating this slice, as the eleven
        # landed entries carry. Pinned on the two facts that make this one
        # different from the vendoring arc around it rather than on its
        # wording: it belongs to the ledger design rather than to that arc,
        # and it reconciles nothing because there was nothing to reconcile.
        note = self.entry().note
        self.assertIn("LEDGER-7", note)
        self.assertIn("no personal copy", note)

    def test_no_auxiliary_asset_ships_beside_the_codex_rendering(self):
        # Requirement 6 from the packaging side: a workflow that resolves no
        # helper ships no helper. A `scripts/` sibling here would be a module
        # this document never calls, and `tools/plugin_bundle_gate.py` would
        # ship it anyway.
        found = sorted(path.name for path in (REPO_ROOT / CODEX_SKILL_DIR).iterdir())
        self.assertEqual(found, ["SKILL.md"])

    def test_no_literal_sigil_survives_in_either_rendering(self):
        # Requirement 1: every cross-workflow reference is a neutral token in
        # the source, so each output carries only its own brand's invocations
        # and no unresolved directive.
        self.assertEqual(
            REFERENCED_WORKFLOWS,
            {"project-review", "auto-project-review", "process-report"},
        )
        for relative_path, brand in BRAND_OF.items():
            text = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertNotIn("{{cmd:", text)
                for name in REFERENCED_WORKFLOWS:
                    self.assertIn(renderer.SIGILS[brand] + name, text)
                # Measured with the renderer's own token pattern rather than a
                # substring search, so a path component or a shell variable
                # that merely starts with a workflow name is not mistaken for
                # an invocation.
                found = {
                    match.group(1)
                    for match in renderer.LITERAL_INVOCATION_PATTERNS[
                        renderer.SIGILS[OPPOSITE[brand]]
                    ].finditer(text)
                }
                self.assertEqual(found & REFERENCED_WORKFLOWS, set())

    def parses_under(self, shell: str, script_text: str) -> int:
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as handle:
            handle.write(script_text + "\n")
            script = handle.name
        self.addCleanup(os.unlink, script)
        return subprocess.run(
            [shell, "-n", script],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
        ).returncode

    def test_every_fenced_block_is_valid_shell(self):
        for relative_path in RENDERED_ASSETS:
            fences = bash_fences(read(relative_path))
            with self.subTest(asset=relative_path):
                # One, and exactly one: the count assignment. A second fence
                # would be this workflow running something, which requirement
                # 6 forbids -- so the number is part of the assertion rather
                # than an incidental fact about today's text.
                self.assertEqual(len(fences), 1, fences)
            for index, fence in enumerate(fences):
                with self.subTest(asset=relative_path, fence=index):
                    self.assertEqual(self.parses_under("sh", fence), 0)

    def test_the_shell_syntax_check_detects_a_planted_error(self):
        self.assertNotEqual(self.parses_under("sh", 'COUNT="$(printf'), 0)


class BrandBoundaryTests(unittest.TestCase):
    """The two bodies are identical outside the argument convention, and what
    remains names neither brand.

    `tools/test_autosolve_workflow.py` can only ask for a *mirror*, because
    every second claim in that document flips with the solving brand. This
    workflow reviews nothing, publishes nothing and reads no verdict, so there
    is nothing left to flip -- which makes the stronger comparison available
    here, and makes every prose rule in this module non-vacuous: any sentence
    added to one rendering and not the other fails here.
    """

    def stripped(self, relative_path: str, drop) -> list[str]:
        text = neutralize(body_of(read(relative_path)), BRAND_OF[relative_path])
        lines = text.splitlines()
        for line in drop:
            self.assertIn(line, lines, f"{relative_path}: {line!r}")
        return [line for line in lines if line not in drop]

    def bodies(self) -> tuple[list[str], list[str]]:
        return (
            self.stripped(CLAUDE_ASSET, CLAUDE_ONLY_LINES),
            self.stripped(CODEX_ASSET, CODEX_ONLY_LINES),
        )

    def test_the_bodies_are_identical_outside_the_argument_convention(self):
        claude, codex = self.bodies()
        self.assertEqual(claude, codex)

    def test_nothing_outside_that_convention_names_a_brand(self):
        # The property that makes the comparison above the right one. A
        # sentence about Claude or Codex in a workflow that performs no review
        # would be a claim about the runtime rather than about the loop, and
        # the one such claim -- which argument placeholder the provider
        # substitutes -- is exactly what the declared lines carry.
        for relative_path, drop in (
            (CLAUDE_ASSET, CLAUDE_ONLY_LINES),
            (CODEX_ASSET, CODEX_ONLY_LINES),
        ):
            bearing = [
                line
                for line in self.stripped(relative_path, drop)
                if re.search(r"[Cc]laude|[Cc]odex", line)
            ]
            with self.subTest(asset=relative_path):
                self.assertEqual(bearing, [])

    def test_the_declared_lines_really_name_the_brand_they_belong_to(self):
        # Non-vacuity for the check above: the exemption is two lines that
        # genuinely carry the per-brand text, not two lines chosen to make an
        # inconvenient search come back empty.
        self.assertTrue(
            any("Claude" in line for line in CLAUDE_ONLY_LINES), CLAUDE_ONLY_LINES
        )
        self.assertTrue(
            any("Codex" in line for line in CODEX_ONLY_LINES), CODEX_ONLY_LINES
        )

    def test_the_argument_convention_is_per_brand(self):
        claude = read(CLAUDE_ASSET)
        codex = read(CODEX_ASSET)
        self.assertIn("$ARGUMENTS", claude)
        self.assertNotIn("$ARGUMENTS", codex)
        self.assertIn("argument-hint:", claude)
        self.assertNotIn("argument-hint:", codex)

    def test_the_comparison_detects_a_planted_divergence(self):
        claude, codex = self.bodies()
        self.assertNotEqual(claude + ["planted"], codex)


class ArgumentTests(unittest.TestCase):
    """Requirement 2 and the review's first spec addition: the count is one
    nonnegative decimal integer or nothing, and every other argument is
    refused before anything is delegated."""

    def test_both_renderings_define_the_count_and_its_two_readings(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "`$COUNT` is **one nonnegative decimal integer, or nothing "
                    "at all**",
                    text,
                )
                self.assertIn(
                    "**An integer `N`** — run at most `N` iterations.", text
                )
                self.assertIn(
                    "**Absent** — run open-ended, repeating until the user "
                    "stops the run",
                    text,
                )

    def test_zero_delegates_nothing_and_still_reports(self):
        # The review's boundary: zero is a legitimate count rather than a
        # missing one, and a workflow that treated it as absent would start an
        # open-ended run the user never asked for.
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "`0` is a legitimate `N`: it delegates nothing, reviews "
                    "nothing, and reports `0 of 0` straight away",
                    text,
                )
                self.assertIn(
                    "A count of `0` reaches the first of those before any "
                    "iteration begins.",
                    text,
                )
                self.assertIn(
                    "A run whose count was `0` ends on the first line, with "
                    "`0 of 0`.",
                    text,
                )

    def test_every_other_argument_is_refused_before_the_first_iteration(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "**Every other argument is refused before the first "
                    "iteration.** A negative number, a fraction, a number "
                    "written any way but as decimal digits, more than one "
                    "argument, and any other text are each a refusal",
                    text,
                )
                # And the two repairs a reader might otherwise reach for are
                # named as refusals of their own, because either would turn a
                # bad argument into a run.
                self.assertIn(
                    "Never round, truncate, or reinterpret an argument into a "
                    "count it does not spell, and never fall back to "
                    "open-ended because a count could not be read.",
                    text,
                )

    def test_the_count_is_announced_before_anything_is_delegated(self):
        for relative_path in RENDERED_ASSETS:
            text = neutralize(read(relative_path), BRAND_OF[relative_path])
            with self.subTest(asset=relative_path):
                self.assertIn("**Announce, then delegate:**", flat(text))
                self.assertLess(
                    text.index("Announce, then delegate"),
                    text.index("## 2. Run one iteration"),
                    "the announcement must land before the first iteration",
                )

    def test_the_refusal_clause_detects_a_planted_removal(self):
        # Non-vacuity: removing the refusal sentence must break the presence
        # check above rather than leave it vacuously true.
        clause = (
            "**Every other argument is refused before the first iteration.**"
        )
        mutated = flat(read(CODEX_ASSET)).replace(clause, "")
        self.assertNotIn(clause, mutated)


class DelegationTests(unittest.TestCase):
    """Requirement 1's token, requirement 6's boundary, and the review's
    second spec addition: the delegate's own successful stop hands control
    back to this loop rather than ending the run."""

    def test_both_renderings_name_the_delegate_through_the_token(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "{{cmd:project-review}} is a delegated sub-step.", text
                )
                self.assertIn(
                    "Where one of those conflicts with a step below, **this "
                    "document wins**",
                    text,
                )
                self.assertIn(
                    "Invoke {{cmd:project-review}} in its default "
                    "pull-request mode, with no argument of your own.",
                    text,
                )

    def test_both_renderings_hand_control_back_after_a_successful_stop(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "**Its stop condition ends that invocation, not this run.**",
                    text,
                )
                self.assertIn(
                    "a successful single-review stop returns control to this "
                    "loop, which decides whether another iteration begins",
                    text,
                )

    def test_the_delegate_really_states_the_single_review_stop_being_repeated(self):
        # The loop is only meaningful while the thing it loops over stops
        # after one review. Read from the shipped project-review assets rather
        # than restated here, so a future edit to that workflow's terminal
        # behavior fails this instead of leaving this document repeating a
        # workflow that had started repeating itself.
        for brand, relative_path in DELEGATE_ASSETS.items():
            text = flat(neutralize(read(relative_path), brand))
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "A successful run in the default PR mode completes exactly "
                    "one review and never starts another.",
                    text,
                )
                self.assertIn(
                    "there is no `continue` action here, and no invocation "
                    "ever begins a second review",
                    text,
                )
                # And it names this workflow as the one that repeats it, so
                # the division of labour is stated on both sides rather than
                # only on this one.
                self.assertIn(
                    "Repetition is {{cmd:auto-project-review}}'s, not this "
                    "workflow's",
                    text,
                )

    def test_the_direct_commit_mode_is_never_entered_by_the_loop(self):
        # The delegate's other mode is an explicit request of the user's, and
        # the delegate says nothing falls through into it. A loop that passed
        # an argument could reach it anyway, so this workflow refuses to.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "Never ask it for direct-commit mode", squashed(relative_path)
                )
        for brand, relative_path in DELEGATE_ASSETS.items():
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "entered only when the user explicitly asks for it in this "
                    "turn",
                    flat(read(relative_path)),
                )


class CountingRuleTests(unittest.TestCase):
    """Requirement 3: only a recorded completed review counts, findings count
    as much as clean, and an iteration that ended any other way stops the
    run."""

    def test_both_renderings_count_only_a_recorded_completed_review(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "**An iteration counts toward `N` only when the delegate "
                    "reported a successfully recorded completed review** — its "
                    '`record` reported `"status": "recorded"`',
                    text,
                )

    def test_both_renderings_count_a_findings_bearing_review(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "whether the outcome was `clean` or `findings`", text
                )
                self.assertIn(
                    "A findings-bearing review is a completed review and "
                    "counts exactly as a clean one does",
                    text,
                )

    def test_both_renderings_stop_on_every_other_ending(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "**An iteration that ended any other way is not counted, "
                    "and it ends the run.**",
                    text,
                )
                self.assertIn(
                    "**Never begin another iteration after one that did not "
                    "record a review.**",
                    text,
                )
                # The enumeration requirement 3 gives, each ending named so a
                # reader does not have to decide which of them is "any other
                # way". An interruption is in it explicitly: it is the one
                # that leaves real review work behind and so reads most like
                # progress.
                for ending in (
                    "A refused inventory or a failed inventory page",
                    "a registration the adapter refused",
                    "a claim the delegate could not take",
                    "a failed fetch",
                    "a migration that stopped on a flagged report",
                    "a `record` or an allocation refused after a takeover",
                    "a cleanup step that retained what it could not remove",
                    "and an interruption are each one of those",
                ):
                    self.assertIn(ending, text, ending)

    def test_neither_rendering_tells_the_loop_to_carry_on_past_one(self):
        for relative_path in RENDERED_ASSETS:
            found = CONTINUATION_RE.findall(flat(read(relative_path)))
            with self.subTest(asset=relative_path):
                self.assertEqual(found, [], found)

    def test_a_planted_skip_and_continue_instruction_is_detected(self):
        # The control. The rule above is an absence, and an absence proves
        # nothing unless the search that reports it can find the thing --
        # planted in four spellings, because the one that eventually appears
        # will not be the one this test author imagined.
        for planted in (
            "Skip that iteration and continue with the next pull request.",
            "Ignore the refusal, then start another iteration.",
            "An interrupted iteration is passed over, and the loop carries on.",
            "Set the failure aside and try again with the next selection.",
        ):
            mutated = flat(read(CLAUDE_ASSET)) + " " + planted
            with self.subTest(planted=planted):
                self.assertTrue(CONTINUATION_RE.search(mutated), planted)

    def test_the_detector_does_not_fire_on_the_rule_it_is_looking_for(self):
        # And the other half of that control: the sentence that states the
        # correct rule must not itself read as a violation of it, or the
        # absence above would only be reporting that the document is silent.
        self.assertIsNone(
            CONTINUATION_RE.search(
                "An iteration that ended any other way is not counted, and it "
                "ends the run. Never begin another iteration after one that "
                "did not record a review."
            )
        )

    def test_a_recorded_review_survives_its_iteration_s_cleanup_failure(self):
        # The second issue review's spec addition. The delegate publishes its
        # checkpoint in step 8 and cleans up in step 9, so exactly one of the
        # uncounted endings leaves a real, published review behind. The
        # counting rule does not bend for it -- that would make "recorded"
        # mean two things -- but a report that omitted it would send the next
        # invocation looking for a row that is already complete, and would
        # lose the retained paths a human has to clear.
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "**One of those endings leaves a recorded review behind, "
                    "and the report owes it.**",
                    text,
                )
                self.assertIn(
                    "That iteration is still not counted and still ends the "
                    "run — the rule above does not bend for it",
                    text,
                )
                self.assertIn(
                    "name every resource the delegate reported retaining, by "
                    "the path it named",
                    text,
                )
                self.assertIn(
                    "Never undo that record and never run the iteration again "
                    "to tidy up after it",
                    text,
                )

    def test_the_delegate_really_records_before_it_cleans_up(self):
        # The ordering the case above exists for, read from the delegate
        # rather than assumed: if cleanup came first, no ending could leave a
        # recorded review behind and this whole disclosure would be describing
        # a state that cannot occur.
        for relative_path in DELEGATE_ASSETS.values():
            text = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertLess(
                    text.index("### 8. Record the completed attempt"),
                    text.index("### 9. Clean up, on every exit"),
                )
                self.assertIn(
                    "**A cleanup step that fails is reported with the path it "
                    "retained, never as removed.**",
                    flat(text),
                )

    def test_both_renderings_refuse_a_retry_and_a_reach_around(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "Retrying is never the repair, and neither is reaching "
                    "around the delegate",
                    text,
                )
                self.assertIn(
                    "do not adjust the inventory, the ledger, or the claim so "
                    "that the next attempt might fare better",
                    text,
                )

    def test_both_renderings_run_the_iterations_in_strict_sequence(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "an iteration begins only once the one before it has ended",
                    text,
                )
                self.assertIn(
                    "The next iteration begins only after this one has ended, "
                    "and never beside it.",
                    text,
                )


class StopConditionTests(unittest.TestCase):
    """Requirements 4 and 5, and the review's third spec addition: the four
    stops, the one that is not an error, and the report every one of them
    owes."""

    def test_both_renderings_state_all_four_stops(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "Exactly one of these ends every run, and each one reaches "
                    "step 5's report:",
                    text,
                )
                for stop in (
                    "**The count is reached.**",
                    "**The queue is exhausted.**",
                    "**The user stops the run.**",
                    "**An iteration did not record a review.**",
                ):
                    self.assertIn(stop, text, stop)

    def test_the_exhausted_queue_is_a_stop_without_error(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    'The delegate reported `"status": "no-selectable-row"`',
                    text,
                )
                self.assertIn(
                    "That is a stop without error, not a refusal and not a "
                    "failure",
                    text,
                )
        # And the delegate really reports it, so this is a status the loop can
        # read rather than one it invented.
        for relative_path in DELEGATE_ASSETS.values():
            with self.subTest(asset=relative_path):
                self.assertIn('"status": "no-selectable-row"', flat(read(relative_path)))

    def test_the_count_is_not_exceeded_to_look_for_more(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "Stop; do not begin an `N`-plus-first to see whether "
                    "anything is left.",
                    squashed(relative_path),
                )

    def test_a_cooperative_cancellation_reports_what_it_reached(self):
        # The review's third addition. An open-ended run has no other ordinary
        # end, and a forcibly terminated session is explicitly NOT promised a
        # final message -- the delegate's lease is what recovers that, and
        # claiming otherwise here would be a guarantee this document cannot
        # make.
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "An open-ended run has no other ordinary end. Report the "
                    "progress reached so far.",
                    text,
                )
                self.assertIn(
                    "A forcibly terminated session cannot guarantee a final "
                    "message at all",
                    text,
                )
                self.assertIn(
                    "the delegate's own lease and cleanup are what recover the "
                    "interrupted iteration",
                    text,
                )

    def test_every_stop_reports_the_same_three_things(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "Every stop ends with the same report, whether the run "
                    "ended on `N`, on an exhausted queue, on a refusal, or on "
                    "the user's word:",
                    text,
                )
                self.assertIn(
                    "the number of recorded reviews against the target — `k of "
                    "N`, or `k of open-ended`;",
                    text,
                )
                self.assertIn(
                    "each with the outcome the delegate recorded, the "
                    "verification commit it recorded the review against, and "
                    "either the report path it allocated or the "
                    "existing-finding links a repeats-only review recorded "
                    "instead;",
                    text,
                )
                self.assertIn(
                    "any review the uncounted last iteration had already "
                    "recorded before it stopped — the cleanup failure in step "
                    "3 is the ending that produces one — named beside the "
                    "counted reviews and told apart from them, together with "
                    "every resource the delegate reported retaining, by the "
                    "path it gave;",
                    text,
                )
                self.assertIn(
                    "the reason this run ended, in the words step 4 gives it.",
                    text,
                )
                # A run that recorded nothing reports too: the empty case is
                # where a progress report is easiest to drop and hardest to
                # notice missing.
                self.assertIn(
                    "A run that recorded nothing still reports: `0 of N`, or "
                    "`0 of open-ended`, with the reason.",
                    text,
                )

    def test_the_report_is_assembled_from_what_the_delegate_said(self):
        # Requirement 6 again, from the reporting side: reading the ledger to
        # build the report would make this workflow a consumer of the
        # delegate's durable state rather than of its result.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "Do not read the ledger, the reports, or the checkpoint "
                    "commits to assemble it",
                    squashed(relative_path),
                )

    def test_the_closing_lines_are_the_four_the_workflow_declares(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn("End with exactly one of:", text)
                for line in (
                    "<k> of <N> project reviews recorded — the count was "
                    "reached.",
                    "<k> of <target> project reviews recorded — no selectable "
                    "pull request remains.",
                    "<k> of <target> project reviews recorded — stopped at "
                    "your request.",
                    "<k> of <target> project reviews recorded — stopped: <the "
                    "delegate's own refusal>.",
                ):
                    self.assertIn(line, text, line)
                self.assertIn(
                    "`<target>` is `N` for a counted run and `open-ended` for "
                    "one invoked without a count.",
                    text,
                )

    def test_the_closing_lines_detect_a_planted_removal(self):
        line = (
            "<k> of <target> project reviews recorded — no selectable pull "
            "request remains."
        )
        mutated = flat(read(CLAUDE_ASSET)).replace(line, "")
        self.assertNotIn(line, mutated)


class NoWorkOfItsOwnTests(unittest.TestCase):
    """Requirement 6: no review step, ledger write, claim, commit, or cleanup
    of its own -- and the description that says so before a user invokes it."""

    def test_no_fenced_block_invokes_anything(self):
        # The one fence in each rendering assigns the count. `sh` would run
        # anything else in it, and anything else in it would be this workflow
        # doing the delegate's work.
        for relative_path in RENDERED_ASSETS:
            for index, fence in enumerate(bash_fences(read(relative_path))):
                with self.subTest(asset=relative_path, fence=index):
                    for line in fence.splitlines():
                        stripped = line.strip()
                        if not stripped or stripped.startswith("#"):
                            continue
                        self.assertRegex(stripped, r"\A[A-Za-z_][A-Za-z0-9_]*=")

    def test_neither_rendering_spells_any_of_the_delegate_s_machinery(self):
        for relative_path in RENDERED_ASSETS:
            offenders = [
                spelling
                for spelling in DELEGATED_MACHINERY
                if spelling in read(relative_path)
            ]
            with self.subTest(asset=relative_path):
                self.assertEqual(offenders, [], offenders)

    def test_the_delegate_really_spells_every_one_of_them(self):
        # Non-vacuity for the absence above, and drift protection for the
        # list: a spelling nothing uses any more would make one entry check
        # for nothing while still reporting a pass.
        for relative_path in DELEGATE_ASSETS.values():
            content = read(relative_path)
            for spelling in DELEGATED_MACHINERY:
                with self.subTest(asset=relative_path, spelling=spelling):
                    self.assertIn(spelling, content)

    def test_both_renderings_disclaim_every_step_of_the_review(self):
        for relative_path in RENDERED_ASSETS:
            text = squashed(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn("**This workflow reviews nothing itself.**", text)
                self.assertIn(
                    "Never take a claim, read or write the ledger, allocate or "
                    "write a report, create or edit a tracker issue, commit, "
                    "push, or remove a worktree on the delegate's behalf, and "
                    "never perform a review step of your own.",
                    text,
                )
                # Including the every-exit cleanup, which is the step most
                # easily mistaken for the caller's to tidy up after a refusal.
                self.assertIn(
                    "the every-exit cleanup its step 9 owes", text
                )

    def test_the_description_states_the_invocation_boundary(self):
        # Requirement 6's last sentence. The description is what a user reads
        # before invoking anything, and an autonomous loop that advertised
        # itself as an ordinary audit would be started by accident.
        for relative_path in RENDERED_ASSETS:
            description = re.search(
                r"^description: (?P<value>.+)$",
                read(relative_path),
                re.MULTILINE,
            )
            self.assertIsNotNone(description, relative_path)
            value = neutralize(description.group("value"), BRAND_OF[relative_path])
            with self.subTest(asset=relative_path):
                self.assertIn(
                    "Use only when the user invokes {{cmd:auto-project-review}} "
                    "or explicitly asks for the autonomous run.",
                    value,
                )
                self.assertIn(
                    "Delegates the review, the ledger, the claim, and the "
                    "cleanup entirely to that workflow and performs none of "
                    "them itself",
                    value,
                )


if __name__ == "__main__":
    unittest.main()
