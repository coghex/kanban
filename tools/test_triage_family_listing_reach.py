"""The triage family's tracker listings reach the whole open set, or say so.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_triage_family_listing_reach.py

Issue #492. `gh` documents `--limit` as the maximum number of rows to fetch and
returns the newest first, so a fixed number silently discards the *oldest* open
issues -- and a truncated listing is indistinguishable from a shorter tracker.
Triage, retriage, and backlog-review each took a capped listing and then made a
completeness claim about it: triage and retriage classify "every currently open
issue" and verify that they did, retriage computes every delta from that one
snapshot and reads open pull requests to decide what is in flight, and
backlog-review draws an oldest-first batch from a newest-first listing, which
inverts rather than merely truncates the audit it exists to perform.

`project-review` had the same defect corrected first, and
`tools/test_project_review_workflow.py` is the pattern these assertions follow:
refuse the constant, and require the workflow to check that the listing it took
actually reached what it promised, before anything is selected from it. The
triage family was not swept then. `TriageAssetTests` and `RetriageAssetTests`
in `tools/test_reconcile_approvals.py` and the classes in
`tools/test_backlog_review_workflow.py` pin rendering, repository scope, and
approval behavior, and none of them can reject a finite cap.

Three properties are asserted over all nine assets -- the three authored
sources and their six renderings, because a rule that held for one brand and
not the other is exactly what the shared source exists to prevent:

* **No numeric literal reaches a `--limit`.** Refused by regex rather than by
  the two spellings that happened to be there, so renaming `500` to `900` does
  not evade the gate; the retired spellings are named too, so the specific
  regression stays pinned. Every `--limit` value in these assets is one of the
  declared limit variables, which is what makes the blanket refusal exact:
  these three workflows take no bounded listing that would legitimately carry a
  constant.
* **The completeness rule is stated.** A variable limit fixes nothing unless
  the workflow checks the value it used was large enough, refuses to use a
  snapshot that did not pass, and stops visibly when one cannot.
* **Each listing is bound to that rule.** The section could be stated once and
  referenced nowhere; each workflow points its own listings at it by name.

The negative control is the assets that legitimately carry a fixed numeric
limit: the bounded keyword searches in the drafting and document workflows,
which read a page of candidates for deduplication and claim nothing about
having read the tracker whole. They match the refusal regex and state none of
the completeness rules, so neither assertion can be passing by matching
everything.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# The three workflows this sweep covers, each as its authored source plus the
# two bundle renderings an agent actually executes.
WORKFLOW_ASSETS = {
    "triage": (
        "tools/command_sources/triage.md",
        "claude-plugin/plugins/kanban/commands/triage.md",
        "codex-plugin/plugins/kanban/skills/triage/SKILL.md",
    ),
    "retriage": (
        "tools/command_sources/retriage.md",
        "claude-plugin/plugins/kanban/commands/retriage.md",
        "codex-plugin/plugins/kanban/skills/retriage/SKILL.md",
    ),
    "backlog-review": (
        "tools/command_sources/backlog-review.md",
        "claude-plugin/plugins/kanban/commands/backlog-review.md",
        "codex-plugin/plugins/kanban/skills/backlog-review/SKILL.md",
    ),
}
DECLARED_ASSET_COUNT = 9

# A `--limit` whose value is a numeric literal, in any spelling an asset could
# reach it by: a space or an `=`, quoted or bare. The issue review's first
# correction: rejecting only `500` and `100` would let the same defect back in
# under a larger constant, which is a symptom rather than the defect class.
REFUSED_NUMERIC_LIMIT_RE = re.compile(r'--limit(?:=|\s+)"?\d')

# The two spellings that were actually there, named so the regression that
# prompted this issue stays pinned by name and not only by shape.
RETIRED_FIXED_LIMITS = ("--limit 500", "--limit 100")

# Every `--limit` value these assets may carry. One variable per collection,
# raised independently, so verifying the open-issue listing cannot silently
# leave the open-pull-request listing at whatever value that escalation ended
# on.
ISSUE_LIMIT = '--limit "$ISSUE_LIMIT"'
PR_LIMIT = '--limit "$PR_LIMIT"'
PERMITTED_LIMIT_VALUES = {'"$ISSUE_LIMIT"', '"$PR_LIMIT"'}

# Which listings each workflow takes. Backlog-review reads open pull requests
# only through a keyword search for merged work, so it takes no open-PR
# snapshot and owes no `$PR_LIMIT`.
REQUIRED_LIMIT_VARIABLES = {
    "triage": (ISSUE_LIMIT, PR_LIMIT),
    "retriage": (ISSUE_LIMIT, PR_LIMIT),
    "backlog-review": (ISSUE_LIMIT,),
}

# The completeness-or-visible-failure rule, one phrase per clause. Matched
# against whitespace-flattened text, so re-wrapping a paragraph does not fail
# the assertion while deleting a clause still does.
COMPLETENESS_RULES = {
    "the limit is not a constant": "**A listing limit is never a constant.**",
    "each snapshot listing carries its own variable": (
        "Each snapshot listing above — the ones a completeness claim rests on, "
        "not a bounded keyword search for one named issue or pull request — "
        "carries its own limit variable, raised independently of any other"
    ),
    "a short listing is the whole collection": (
        "**Fewer rows than the limit** — that listing is the complete "
        "collection."
    ),
    "a full listing may have been cut off": (
        "**Exactly the limit** — the listing may have been cut off at the cap. "
        "Double that variable, capped at 10000, and take the listing again."
    ),
    "raise until a listing comes back short": (
        "Repeat until a listing comes back short."
    ),
    "the check precedes every use of the snapshot": (
        "**A completeness check succeeds before the snapshot it covers is "
        "used** — for classification, batch selection, approval "
        "reconciliation, or any tracker mutation."
    ),
    "no partial snapshot is presented as complete": (
        "a partial snapshot is never presented as complete"
    ),
    "failure is a visible stop": "**Fail visibly.**",
    "the diagnostic names the repository": (
        "name in the diagnostic the repository `$REPO`"
    ),
    "the diagnostic names the incomplete collection": (
        "which collection is incomplete — the **open issues** or the **open "
        "pull requests**"
    ),
    "the partial snapshot is not a fallback": (
        "Do not fall back to the partial snapshot, do not classify or select "
        "from what was read, and do not present a roadmap or a batch as "
        "covering anything."
    ),
    "it is a stop rather than a warning": "This is a stop, not a warning.",
}

# The section the rules live in, referenced by name from each listing.
SECTION_HEADING = "## Complete Snapshots"

# Each workflow binds its own listings to that section, at the listing rather
# than in a paragraph elsewhere: a rule stated once and pointed at from nowhere
# is a rule an agent reads past on its way to the command it is about to run.
LISTING_BINDINGS = {
    "triage": (
        "Set and verify `$ISSUE_LIMIT` as **Complete Snapshots** below "
        "specifies, before reading a single issue out of it.",
        "Set and verify `$PR_LIMIT` the same way, before deciding that any "
        "issue is not in flight.",
    ),
    "retriage": (
        "Set and verify `$ISSUE_LIMIT` as **Complete Snapshots** below "
        "specifies, before computing a single delta.",
        "Set and verify `$PR_LIMIT` the same way, before deciding that any "
        "issue is not in flight.",
    ),
    "backlog-review": (
        "Set and verify `$ISSUE_LIMIT` as **Complete Snapshots** below "
        "specifies, then apply any label or area restriction the user asked "
        "for, sort what remains by `createdAt` oldest-first, and take the "
        "count off the front of that.",
    ),
}

# Why each workflow owes the rule, in its own terms. Requirement 2, 3 and 4 are
# three different consequences of the same cap, and a sweep that stated the
# generic rule without naming them would leave the next author free to drop the
# one that mattered here.
CONSEQUENCE_STATED = {
    "triage": (
        "Step 7 classifies *every* currently open issue and step 10 verifies "
        "that it did, so this listing has to be the whole open set rather than "
        "its newest page.",
        "an issue whose closing pull request fell outside it reads as "
        "available, and can be chosen as `Start with` for a second agent to "
        "collide with",
    ),
    "retriage": (
        "Step 6 computes every delta from this snapshot's "
        "`current_open_numbers` and step 12 verifies that every current open "
        "issue appears exactly once, so the snapshot has to be the whole open "
        "set rather than its newest page.",
        "An issue whose closing pull request fell outside this listing loses "
        "its `[in-flight: PR #NNN]` note and becomes eligible for `Start "
        "with`, which hands a second agent work already under way.",
    ),
    "backlog-review": (
        "The batch is the *oldest* issues in the tracker, and a capped listing "
        "drops exactly those, so the open set is read whole before it is "
        "narrowed.",
    ),
}

# Requirement 4 and the issue review's second correction: the restated range is
# the batch that was selected, not the range of the exhaustive listing it was
# drawn from. The larger snapshot spans the whole tracker, so restating *its*
# range would report a batch of fifteen as covering every open issue.
BACKLOG_BATCH_RANGE = (
    "Restate the batch as the concrete issue number range it spans — the "
    "issues actually selected, after the restriction, the sort, and the count, "
    "not the range of the complete listing they were drawn from"
)

# The negative control. These read a bounded page of candidates for keyword
# deduplication and claim nothing about having read the tracker whole, so a
# numeric `--limit` is correct in them and none of the rules above applies. If
# the refusal regex stopped matching, or the completeness phrases were generic
# enough to appear anywhere, these would catch it.
BOUNDED_SEARCH_ASSETS = (
    "claude-plugin/plugins/kanban/commands/issue.md",
    "codex-plugin/plugins/kanban/skills/issue/SKILL.md",
    "claude-plugin/plugins/kanban/commands/draft-issues.md",
    "claude-plugin/plugins/kanban/commands/process-report.md",
    "codex-plugin/plugins/kanban/skills/process-report/SKILL.md",
)


def read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def flat(text: str) -> str:
    """`text` with every run of whitespace collapsed to one space, so a phrase
    is found whether or not the source wrapped it across lines."""
    return re.sub(r"\s+", " ", text)


def limit_values(text: str) -> list[str]:
    """Every value passed to `--limit` in `text`, in document order."""
    return re.findall(r"--limit(?:=|\s+)(\S+)", text)


def every_asset():
    for workflow, paths in sorted(WORKFLOW_ASSETS.items()):
        for relative_path in paths:
            yield workflow, relative_path


class DeclaredAssetTests(unittest.TestCase):
    """Non-vacuity for every loop below: each reads a file, so a renamed or
    unrendered asset would make them all pass over nothing."""

    def test_the_assets_this_module_pins_are_the_real_tracked_files(self):
        seen = []
        for _, relative_path in every_asset():
            with self.subTest(asset=relative_path):
                path = REPO_ROOT / relative_path
                self.assertTrue(path.is_file(), relative_path)
                self.assertGreater(
                    len(path.read_text(encoding="utf-8")), 2000, relative_path
                )
            seen.append(relative_path)
        self.assertEqual(len(seen), DECLARED_ASSET_COUNT)
        self.assertEqual(len(set(seen)), DECLARED_ASSET_COUNT)


class RefusedFixedLimitTests(unittest.TestCase):
    """Requirement 1: no fixed numeric `--limit` on a listing whose own
    completeness claim depends on it."""

    def test_no_asset_carries_a_numeric_limit(self):
        for workflow, relative_path in every_asset():
            with self.subTest(workflow=workflow, asset=relative_path):
                found = REFUSED_NUMERIC_LIMIT_RE.findall(read(relative_path))
                self.assertEqual(
                    found,
                    [],
                    f"{relative_path}: a `--limit` with a numeric literal caps "
                    "a listing this workflow then claims is complete",
                )

    def test_the_retired_spellings_are_refused_by_name(self):
        # The regex covers the class; these two are what was actually there,
        # and #492 exists because they survived three vendoring PRs unnoticed.
        for workflow, relative_path in every_asset():
            content = read(relative_path)
            for retired in RETIRED_FIXED_LIMITS:
                with self.subTest(workflow=workflow, asset=relative_path,
                                  spelling=retired):
                    self.assertNotIn(retired, content)

    def test_every_limit_value_is_a_declared_variable(self):
        # What makes the blanket refusal above exact rather than
        # over-broad: these three workflows take no bounded listing, so every
        # `--limit` they carry is one of the two verified ones.
        for workflow, relative_path in every_asset():
            with self.subTest(workflow=workflow, asset=relative_path):
                values = limit_values(read(relative_path))
                self.assertTrue(values, relative_path)
                for value in values:
                    self.assertIn(value, PERMITTED_LIMIT_VALUES, relative_path)

    def test_each_workflow_takes_the_listings_it_declares(self):
        # The positive half: refusing the constant would also pass against an
        # asset that dropped the listing entirely.
        for workflow, relative_path in every_asset():
            content = read(relative_path)
            for spelling in REQUIRED_LIMIT_VARIABLES[workflow]:
                with self.subTest(workflow=workflow, asset=relative_path,
                                  listing=spelling):
                    self.assertIn(spelling, content)


class CompletenessRuleTests(unittest.TestCase):
    """Requirements 2, 3 and 4: read the whole collection, or stop visibly and
    name what could not be read."""

    def test_every_asset_states_the_whole_rule(self):
        for workflow, relative_path in every_asset():
            flattened = flat(read(relative_path))
            self.assertIn(SECTION_HEADING, read(relative_path), relative_path)
            for rule, phrase in sorted(COMPLETENESS_RULES.items()):
                with self.subTest(workflow=workflow, asset=relative_path,
                                  rule=rule):
                    self.assertIn(flat(phrase), flattened)

    def test_every_listing_is_bound_to_the_rule(self):
        for workflow, relative_path in every_asset():
            flattened = flat(read(relative_path))
            for binding in LISTING_BINDINGS[workflow]:
                with self.subTest(workflow=workflow, asset=relative_path,
                                  binding=binding[:40]):
                    self.assertIn(flat(binding), flattened)

    def test_every_workflow_states_what_a_short_listing_would_cost_it(self):
        for workflow, relative_path in every_asset():
            flattened = flat(read(relative_path))
            for consequence in CONSEQUENCE_STATED[workflow]:
                with self.subTest(workflow=workflow, asset=relative_path,
                                  consequence=consequence[:40]):
                    self.assertIn(flat(consequence), flattened)

    def test_the_check_is_stated_before_the_first_listing_uses_it(self):
        # A rule an agent reaches only after it has already classified the
        # snapshot is a rule that fires too late. The binding sits at the
        # listing; the section may follow, but the binding may not.
        for workflow, relative_path in every_asset():
            flattened = flat(read(relative_path))
            first_limit = flattened.index(REQUIRED_LIMIT_VARIABLES[workflow][0])
            binding = flattened.index(flat(LISTING_BINDINGS[workflow][0]))
            with self.subTest(workflow=workflow, asset=relative_path):
                self.assertLess(first_limit, binding, relative_path)


class BacklogBatchRangeTests(unittest.TestCase):
    """Requirement 4: the restated range is the batch that was selected, not
    the exhaustive listing it came out of."""

    def test_the_restated_range_is_the_selected_batch(self):
        for relative_path in WORKFLOW_ASSETS["backlog-review"]:
            with self.subTest(asset=relative_path):
                self.assertIn(flat(BACKLOG_BATCH_RANGE), flat(read(relative_path)))

    def test_the_superseded_restatement_is_gone(self):
        # The phrase it replaces named "the list", which after this change is
        # the exhaustive snapshot spanning the whole tracker -- restating that
        # range would report a batch of fifteen as covering every open issue.
        superseded = (
            "Restate the batch as the concrete issue number range the list "
            "yields"
        )
        for relative_path in WORKFLOW_ASSETS["backlog-review"]:
            with self.subTest(asset=relative_path):
                self.assertNotIn(flat(superseded), flat(read(relative_path)))


class NegativeControlTests(unittest.TestCase):
    """The bounded keyword searches, which owe none of this and must not
    accidentally satisfy it."""

    def test_the_control_assets_exist(self):
        self.assertTrue(BOUNDED_SEARCH_ASSETS)
        for relative_path in BOUNDED_SEARCH_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertTrue((REPO_ROOT / relative_path).is_file(), relative_path)

    def test_the_refusal_regex_still_matches_a_fixed_limit(self):
        # If it stopped matching, every assertion in RefusedFixedLimitTests
        # would pass against assets that had never been corrected.
        for relative_path in BOUNDED_SEARCH_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertTrue(
                    REFUSED_NUMERIC_LIMIT_RE.search(read(relative_path)),
                    relative_path,
                )

    def test_the_control_assets_state_none_of_the_completeness_rules(self):
        # And if the phrases were generic enough to appear in any workflow
        # asset, CompletenessRuleTests would be asserting nothing.
        for relative_path in BOUNDED_SEARCH_ASSETS:
            flattened = flat(read(relative_path))
            self.assertNotIn(SECTION_HEADING, read(relative_path), relative_path)
            for rule, phrase in sorted(COMPLETENESS_RULES.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertNotIn(flat(phrase), flattened)


if __name__ == "__main__":
    unittest.main()
