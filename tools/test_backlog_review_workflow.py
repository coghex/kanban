"""The vendored backlog-review workflow's own behavioral contract.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_backlog_review_workflow.py

Issue #430, slice VEND-3 of `docs/workflow_command_vendoring_design.md`. Every
other vendored slice so far reads the tracker; this one **writes** to it — it
closes issues, rewrites their bodies, adds a label, and posts a comment. Two
consequences follow, and both are asserted here rather than left to review.

* **Every `gh` call names the repository.** Design D-5 requires it of all eight
  vendored commands, but `gh` without `-R` targets whatever repository the
  session's working directory happens to be in, and closing someone else's
  issue is not recoverable by editing a file afterwards. So the calls are
  pinned exactly: six of them, six spellings, `-R "$REPO"` on each. The
  resolution that fills `$REPO` reads the remote with `git` and `sed` — an
  initial `gh repo view` would be a GitHub call made before the identity every
  other call depends on exists, so it is refused by name. The report that names
  what was resolved is pinned ahead of the first *read*, not merely ahead of the
  first write: an echo arriving after the backlog has been pulled from the wrong
  tracker names the wrong repository too late to stop the batch being scoped
  against it.
* **Nothing mutates before the stop.** The workflow's whole safety property is
  that it reports, stops, and waits; the four mutations are pinned to appear
  after that stop in the document an agent reads top to bottom.

The rest is D-2's preserved behavior: the disposition vocabulary, the batch
default, the oldest-first order, the in-flight skip, the evidence bar, and the
no-code prohibition are vendored as the personal copies read them, so each is
pinned rather than merely rendered.

The file-location rules are the one exception. They were vendored verbatim too,
and issue #470 found that what they said contradicted the Apply phase they
shipped beside: the workflow "should not write into the repository at all",
while its own approved updates and needs-decision comments go through two
`--body-file` payloads, and the unscoped rule that followed put any file the
workflow did write inside a repository worktree. `WriteLocationTests` pins the
corrected rule instead — the system temp directory, outside every checkout, and
removal of each payload afterwards — and asserts that neither superseded phrase
came back.

Both rendered assets are checked, because both are what an agent executes, and
a rule that held for one brand and not the other is exactly what the shared
source exists to prevent. Two negative controls keep the assertions from
matching everything: the brand boundary itself, where `BrandBoundaryTests`
asserts that stripping the three declared brand-specific lines leaves two
byte-identical bodies, and the retriage and triage assets, which write no file
and must state none of the write-location rules.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent

SOURCE = "tools/command_sources/backlog-review.md"
CLAUDE_ASSET = "claude-plugin/plugins/kanban/commands/backlog-review.md"
CODEX_ASSET = "codex-plugin/plugins/kanban/skills/backlog-review/SKILL.md"
RENDERED_ASSETS = (CLAUDE_ASSET, CODEX_ASSET)

# A `gh` invocation as the assets actually spell them, in a fenced block or in
# inline code. The lookbehind keeps the `gh` that ends `through` out, and the
# required lowercase subcommand keeps the prose mentions of a "`gh` call" out:
# what is left is only text an agent would run.
GH_INVOCATION_RE = re.compile(r"(?<![\w-])gh (?P<tail>[a-z][^\n`]*)")

# The six tracker calls the workflow makes, by the leading words that identify
# each. Two reads and four mutations, in the order the document introduces
# them; `gh issue edit` appears twice because an approved Update rewrites a
# body and an approved Needs-decision adds a label.
TRACKER_READS = (
    "issue list",
    "pr list",
)
TRACKER_MUTATIONS = (
    "issue edit -R \"$REPO\" <n> --body-file",
    "issue close",
    "issue edit -R \"$REPO\" <n> --add-label",
    "issue comment",
)
DECLARED_TRACKER_CALL_COUNT = len(TRACKER_READS) + len(TRACKER_MUTATIONS)

REPOSITORY_SCOPE = '-R "$REPO"'

# How `$REPO` is filled: from the remote, with no GitHub call of its own.
REPOSITORY_RESOLUTION = 'REPO="$(git remote get-url origin'

# The stop every mutation waits behind.
MANDATORY_STOP = "Then STOP and ask which to apply"

# D-2's preserved behavior, one phrase per rule. Matched against whitespace-
# flattened text, so re-wrapping a paragraph does not fail the assertion while
# deleting the rule still does.
PRESERVED_BEHAVIOR = {
    "no-code prohibition": "Review only — never modify code; the only writes you ever make are tracker writes",
    "oldest-first order": "list the open issues and sort them oldest-first",
    "batch default": "Default is the 15 oldest;",
    "in-flight skip": "Skip issues that are in-flight (assignee, `wip` label, or an open PR closing them)",
    "in-flight issues are reported": "list them as skipped",
    "evidence bar": "every non-Valid disposition needs the same evidence bar as drafting a new issue: a `file:line` trace, a repro, or the resolving PR/commit",
    "one disposition per issue": "**Disposition — exactly one per issue:**",
    "report before applying": "show the full drafted body or comment for anything that would change the tracker",
    "nothing is written until told": "Do NOT edit, close, label, or comment until told.",
    "clean-batch report": "If everything came back Valid, say so",
    "file-location rule": "Put each under the system temporary directory, outside every repository worktree",
    "docs-wip is the in-repository write root": "write it there rather than the primary checkout",
}

# Issue #470's corrected write-location contract, one phrase per rule. The two
# `--body-file` payloads the Apply phase writes are the workflow's only
# filesystem writes, so the rule has to say where they go *and* that they are
# removed again; the older text said the workflow wrote nothing and routed any
# file it did write into a repository worktree, which is the contradiction
# these phrases replace.
#
# Matched case-sensitively against `flat()` output, like PRESERVED_BEHAVIOR
# above: re-wrapping a paragraph does not fail the assertion, while deleting a
# rule or rewording it does.
WRITE_LOCATION_RULES = (
    # What the writes are, so "it writes nothing" cannot come back.
    "Its only filesystem writes are the Apply phase's two transient "
    "`--body-file` payloads",
    # Where they go.
    "Put each under the system temporary directory, outside every repository "
    "worktree",
    # And the two places they must never go, named rather than implied.
    "never in the `docs-wip` worktree, and never in the primary checkout",
    # Cleanup on the consuming call, whichever way it ended.
    "Remove each one as soon as the `gh` call that consumes it returns, "
    "whether it succeeded or failed",
    # Best-effort cleanup on ordinary interruption. A hard kill cannot run
    # cleanup and is deliberately not claimed.
    "clean up whatever is left behind on an ordinary interruption or "
    "cancellation",
    # The retained docs-wip guidance, now scoped to a genuine in-repository
    # write and resolved by branch.
    "write it there rather than the primary checkout",
    "Resolve it by branch, never a hard-coded path",
    # And the repositories that do not use the convention at all.
    "A repository with no `docs-wip` worktree does not use this convention",
)

# The negative control for WRITE_LOCATION_RULES. Both retriage assets and both
# triage assets read the tracker and write no file at all, so they owe none of
# these rules; a rule that matched every rendered asset in the bundles would
# pass the check above while asserting nothing.
# The two phrases that stated the contradiction before issue #470, kept only so
# the regression can assert their absence.
SUPERSEDED_WRITE_LOCATION_PHRASES = (
    "it should not write into the repository at all",
    "put it in the `docs-wip` worktree, never the primary checkout",
)

NON_WRITING_ASSETS = (
    "claude-plugin/plugins/kanban/commands/retriage.md",
    "codex-plugin/plugins/kanban/skills/retriage/SKILL.md",
    "claude-plugin/plugins/kanban/commands/triage.md",
    "codex-plugin/plugins/kanban/skills/triage/SKILL.md",
)

# The disposition vocabulary, which is out of scope to change (issue #430) and
# therefore pinned as the exact five bold labels.
DISPOSITIONS = (
    "**Valid**",
    "**Update**",
    "**Obsolete**",
    "**Duplicate**",
    "**Needs decision**",
)

# The opening report, which is what catches a wrong resolution. It has to land
# before the *first read*, not merely before the first mutation: a report that
# arrived after the backlog had been pulled from the wrong tracker would name
# the wrong repository too late to stop anything, and a batch already scoped
# against it is what the dispositions are then drafted from. Round 1's blocker
# on this pull request was exactly that ordering.
OPENING_REPORT = (
    "name the resolved `$REPO` and the batch you are about to take before the "
    "first `gh` call below."
)

# The batch's concrete issue-number range, which is only knowable once the list
# returns, so it is restated rather than guessed before the read.
BATCH_RANGE_REPORT = (
    "Restate the batch as the concrete issue number range the list yields "
    "before starting the verification below."
)

# The one sentence that differs per brand because the providers really do pass
# arguments differently (design D-2/D-7 keep this, rather than flattening it).
CLAUDE_ONLY_LINES = ("`$ARGUMENTS` may override the count or narrow to a label/area.",)

# The two caveats that name Codex's default read-only sandbox. Requirement 4 of
# issue #430: they survive for Codex, and the Claude rendering gains no invented
# equivalent — it renders without them, exactly as its retired copy read.
CODEX_ONLY_LINES = (
    "if the user gave you a count or a label/area, use that instead.",
    "  (In a read-only sandbox, tracing the code path is the verification — say so in the evidence note.)",
    "(Only possible if the current Codex session has write/network access — the default read-only sandbox can't; if sandboxed, hand the user the exact commands instead.)",
)

CODEX_ONLY_CAVEATS = CODEX_ONLY_LINES[1:]


def read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def body_of(text: str) -> str:
    """`text` with its frontmatter block removed.

    The frontmatter is the one place the two renderings legitimately differ
    beyond the brand blocks — different keys, and the invocation sigil inside
    the description — so the brand-boundary comparison is made over the body.
    """
    match = re.match(r"\A---\n.*?\n---\n(?P<body>.*)\Z", text, re.DOTALL)
    assert match is not None, "a rendered asset always opens with frontmatter"
    return match.group("body")


def flat(text: str) -> str:
    """`text` with every run of whitespace collapsed to one space, so a phrase
    is found whether or not the source wrapped it across lines."""
    return re.sub(r"\s+", " ", text)


class RenderedAssetTests(unittest.TestCase):
    """What both bundles ship is the render of the one authored source."""

    def test_both_assets_are_the_render_of_the_one_authored_source(self):
        # Requirement 2: neither rendered file is hand-edited. The registry
        # gate in tools/test_render_command_sources.py enforces this across
        # every entry; restating it here keeps this module's own assertions
        # about a file whose provenance it has checked, rather than about
        # whatever happens to be on disk.
        entry = next(
            candidate
            for candidate in renderer.COMMAND_SOURCES
            if candidate.name == "backlog-review"
        )
        self.assertEqual(entry.source, SOURCE)
        rendered = renderer.render_entry(entry, REPO_ROOT)
        self.assertEqual(set(rendered), set(RENDERED_ASSETS))
        for relative_path, text in rendered.items():
            self.assertEqual(read(relative_path), text, relative_path)


class RepositoryScopeTests(unittest.TestCase):
    """Requirement 5: no `gh` call in either rendered file omits `-R "$REPO"`."""

    def test_the_tracker_calls_are_exactly_the_six_declared_ones(self):
        # Non-vacuity for the scoping assertion below: a regex that stopped
        # matching would report no unscoped call for the same reason a file
        # with no calls does.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                calls = GH_INVOCATION_RE.findall(read(relative_path))
                self.assertEqual(len(calls), DECLARED_TRACKER_CALL_COUNT, calls)

    def test_every_tracker_call_names_the_resolved_repository(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for match in GH_INVOCATION_RE.finditer(content):
                call = match.group(0)
                with self.subTest(asset=relative_path, call=call):
                    self.assertIn(
                        REPOSITORY_SCOPE,
                        call,
                        f"{relative_path}: {call!r} would target whatever "
                        "repository the session's working directory happens "
                        "to be in",
                    )

    def test_each_declared_read_and_mutation_is_present_and_scoped(self):
        # The count above says six; this says *which* six, so a mutation
        # silently replaced by a second copy of a read still fails.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for leading in TRACKER_READS + TRACKER_MUTATIONS:
                with self.subTest(asset=relative_path, call=leading):
                    self.assertIn(f"gh {leading}", content)
            for leading in TRACKER_READS:
                self.assertIn(f'gh {leading} -R "$REPO"', content, relative_path)
            for leading in TRACKER_MUTATIONS:
                self.assertIn(f"gh {leading}", content, relative_path)

    def test_the_repository_is_resolved_without_a_github_call_of_its_own(self):
        # Requirement 5 is absolute, so the resolution itself may not be a `gh`
        # invocation: at that point `$REPO` does not exist yet, and the call
        # could not carry `-R`. The remote is read with git and sed instead.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(REPOSITORY_RESOLUTION, content)
                self.assertNotIn("gh repo view", content)

    def test_resolution_precedes_every_tracker_call(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            first_call = GH_INVOCATION_RE.search(content)
            self.assertIsNotNone(first_call, relative_path)
            with self.subTest(asset=relative_path):
                self.assertLess(
                    content.index(REPOSITORY_RESOLUTION),
                    first_call.start(),
                    f"{relative_path}: the first tracker call is made before "
                    "$REPO is resolved",
                )

    def test_the_opening_report_precedes_every_tracker_call(self):
        # Every call, reads included -- an echo that lands after the backlog
        # has already been pulled from the wrong tracker catches the wrong
        # resolution too late to stop the batch being scoped against it.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            report = flattened.index(OPENING_REPORT)
            for leading in TRACKER_READS + TRACKER_MUTATIONS:
                with self.subTest(asset=relative_path, call=leading):
                    self.assertLess(
                        report,
                        flattened.index(f"gh {leading}"),
                        f"{relative_path}: gh {leading} runs before the "
                        "opening report names the repository it targets",
                    )

    def test_the_batch_range_is_restated_before_the_verification_begins(self):
        # The other half of the announcement: the issue-number range is not
        # knowable until the list returns, so it follows the read -- but it
        # still precedes every disposition and every mutation drafted from it.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            restatement = flattened.index(BATCH_RANGE_REPORT)
            with self.subTest(asset=relative_path):
                self.assertLess(flattened.index(OPENING_REPORT), restatement)
                self.assertLess(
                    flattened.index(f"gh {TRACKER_READS[0]}"), restatement
                )
                self.assertLess(restatement, flattened.index("**Verify each issue's"))
                for leading in TRACKER_MUTATIONS:
                    self.assertLess(
                        restatement, flattened.index(f"gh {leading}"), leading
                    )


class MandatoryStopTests(unittest.TestCase):
    """Requirement 6: the stop before any tracker write is vendored intact."""

    def test_every_mutation_follows_the_mandatory_stop(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            stop = flattened.index(MANDATORY_STOP)
            with self.subTest(asset=relative_path):
                for leading in TRACKER_MUTATIONS:
                    self.assertLess(
                        stop,
                        flattened.index(f"gh {leading}"),
                        f"{relative_path}: {leading} is reachable before the "
                        "report stops for approval",
                    )

    def test_the_reads_precede_the_stop(self):
        # The other half of the ordering: the workflow must be able to read the
        # backlog before it has anything to report, so a stop moved to the top
        # of the file would satisfy the assertion above and break the workflow.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            stop = flattened.index(MANDATORY_STOP)
            with self.subTest(asset=relative_path):
                for leading in TRACKER_READS:
                    self.assertLess(flattened.index(f"gh {leading}"), stop, leading)


class PreservedBehaviorTests(unittest.TestCase):
    """D-2: the slice reconciles and relocates; it does not redesign."""

    def test_every_preserved_rule_survives_in_both_renderings(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for rule, phrase in sorted(PRESERVED_BEHAVIOR.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)

    def test_the_disposition_vocabulary_is_exactly_the_five(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                for disposition in DISPOSITIONS:
                    self.assertIn(f"- {disposition} —", content)

    def test_the_file_location_section_is_present_for_both_brands(self):
        # Requirement 3: this section existed only in the Codex copy, and the
        # reconciliation gave it to both.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn("## Where files go", read(relative_path))


class WriteLocationTests(unittest.TestCase):
    """Issue #470: where this workflow's transient tracker payloads go, and
    that they are removed again.

    The Apply phase feeds two `--body-file` payloads to the tracker, so the
    section's opening claim that the workflow "should not write into the
    repository at all" was false of its own documented behavior, and the
    unscoped rule that followed sent any file it did write into the `docs-wip`
    worktree — or, in a repository without one, into the primary checkout the
    PR drainer fast-forwards and autostashes after every merge. Neither branch
    said the file was ever removed.

    There is no behavioral prompt-testing harness here, so the reviewable
    property is the asset text itself, exactly as `WriteLocationTests` in
    tools/test_drafting_workflow_contract.py treats the issue-drafting
    workflows' equivalent rules.
    """

    def setUp(self):
        self.assets = {path: flat(read(path)) for path in RENDERED_ASSETS}

    @staticmethod
    def missing_rules(asset: str, text: str) -> list[str]:
        """The write-location rules `text` fails to state, as report lines.

        The one place a rule is looked for, so the mutation check below drives
        the same code path the real assertion does rather than re-implementing
        it and drifting from it.
        """
        return [
            f"{asset}: missing write-location rule {rule!r}"
            for rule in WRITE_LOCATION_RULES
            if flat(rule) not in text
        ]

    def test_both_renderings_state_every_write_location_rule(self):
        missing = []
        for path in RENDERED_ASSETS:
            missing.extend(self.missing_rules(path, self.assets[path]))
        self.assertEqual(missing, [], "\n".join(missing))

    def test_dropping_a_rule_from_a_rendering_is_reported(self):
        # The property under test is that removal *is reported*, not merely
        # that the text happens to be present today. Each rule is deleted in
        # turn from a copy of each asset and `missing_rules` -- the same
        # function the assertion above runs -- must name exactly that rule and
        # no other, so a later edit cannot quietly drop the temp-directory rule
        # or the cleanup rule and stay green.
        for path in RENDERED_ASSETS:
            for rule in WRITE_LOCATION_RULES:
                with self.subTest(asset=path, rule=rule):
                    mutated = self.assets[path].replace(flat(rule), "")
                    self.assertEqual(
                        self.missing_rules(path, mutated),
                        [f"{path}: missing write-location rule {rule!r}"],
                        f"{path}: deleting {rule!r} was not reported as "
                        "exactly that one missing rule",
                    )

    def test_the_rules_are_not_vacuous(self):
        # A rule that matched every rendered asset would pass the check above
        # while asserting nothing. The retriage and triage assets read the
        # tracker and write no file, so they owe none of these rules and are
        # the negative control that keeps the tuple meaningful.
        #
        # Reported as a plain list rather than through assertNotIn: these
        # assets flatten to thousands of characters, and a membership assertion
        # dumps the whole text into the report, burying the one line that says
        # what to do about it.
        offenders = []
        for path in NON_WRITING_ASSETS:
            text = flat(read(path))
            for rule in WRITE_LOCATION_RULES:
                if flat(rule) in text:
                    offenders.append(
                        f"{path} now states {rule!r}; add it to the asserted "
                        "assets so the rule is enforced there rather than "
                        "silently exempt"
                    )
        self.assertEqual(offenders, [], "\n".join(offenders))

    def test_the_superseded_contradiction_is_gone_from_both_renderings(self):
        # The two phrases this module used to pin as preserved behavior.
        # Restoring either one re-opens the defect: the first denies the writes
        # the Apply phase makes, the second routes them into a repository
        # worktree. Reported as a plain list for the same reason as above.
        offenders = []
        for path in RENDERED_ASSETS:
            for phrase in SUPERSEDED_WRITE_LOCATION_PHRASES:
                if flat(phrase) in self.assets[path]:
                    offenders.append(
                        f"{path} states {phrase!r} again; the Apply phase "
                        "writes two --body-file payloads, so this text "
                        "contradicts the workflow it ships beside"
                    )
        self.assertEqual(offenders, [], "\n".join(offenders))


class BrandBoundaryTests(unittest.TestCase):
    """Requirement 4, and the negative control for every rule above.

    Three lines differ between the two renderings' bodies and no others. If a
    rule asserted here matched everything, it would also have to match the
    stripped bodies, and this comparison would fail.
    """

    def stripped(self, relative_path: str, drop) -> list[str]:
        lines = body_of(read(relative_path)).splitlines()
        for line in drop:
            self.assertIn(line, lines, f"{relative_path}: {line!r}")
        return [line for line in lines if line not in drop]

    def test_the_bodies_differ_only_by_the_three_declared_brand_lines(self):
        claude = self.stripped(CLAUDE_ASSET, CLAUDE_ONLY_LINES)
        codex = self.stripped(CODEX_ASSET, CODEX_ONLY_LINES)
        self.assertEqual(claude, codex)

    def test_the_codex_sandbox_caveats_are_absent_from_the_claude_rendering(self):
        claude = read(CLAUDE_ASSET)
        codex = read(CODEX_ASSET)
        for caveat in CODEX_ONLY_CAVEATS:
            with self.subTest(caveat=caveat):
                self.assertIn(caveat.strip(), codex)
                self.assertNotIn(caveat.strip(), claude)
        # No invented Claude equivalent either: the word the two caveats are
        # about does not appear in that rendering at all.
        self.assertNotIn("sandbox", claude)

    def test_the_argument_convention_is_per_brand(self):
        claude = read(CLAUDE_ASSET)
        codex = read(CODEX_ASSET)
        self.assertIn("$ARGUMENTS", claude)
        self.assertNotIn("$ARGUMENTS", codex)
        self.assertIn(CODEX_ONLY_LINES[0], codex)
        self.assertNotIn(CODEX_ONLY_LINES[0], claude)

    def test_each_brand_reads_its_own_invocation_sigil(self):
        self.assertIn("/backlog-review", read(CLAUDE_ASSET))
        self.assertIn("$backlog-review", read(CODEX_ASSET))
        self.assertNotIn("$backlog-review", read(CLAUDE_ASSET))
        self.assertNotIn("/backlog-review", read(CODEX_ASSET))


if __name__ == "__main__":
    unittest.main()
