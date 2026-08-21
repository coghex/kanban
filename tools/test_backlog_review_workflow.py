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
  other call depends on exists, so it is refused by name.
* **Nothing mutates before the stop.** The workflow's whole safety property is
  that it reports, stops, and waits; the four mutations are pinned to appear
  after that stop in the document an agent reads top to bottom.

The rest is D-2's preserved behavior: the disposition vocabulary, the batch
default, the oldest-first order, the in-flight skip, the evidence bar, the
no-code prohibition, and the file-location rules are vendored as the personal
copies read them, so each is pinned rather than merely rendered.

Both rendered assets are checked, because both are what an agent executes, and
a rule that held for one brand and not the other is exactly what the shared
source exists to prevent. The negative control is the brand boundary itself:
`BrandBoundaryTests` asserts that stripping the three declared brand-specific
lines leaves two byte-identical bodies, so a rule that quietly matched
everything could not also pass there.
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
    "file-location rule": "it should not write into the repository at all",
    "docs-wip is the write root": "put it in the `docs-wip` worktree, never the primary checkout",
}

# The disposition vocabulary, which is out of scope to change (issue #430) and
# therefore pinned as the exact five bold labels.
DISPOSITIONS = (
    "**Valid**",
    "**Update**",
    "**Obsolete**",
    "**Duplicate**",
    "**Needs decision**",
)

# The opening report, which is what catches a wrong resolution before anything
# irreversible happens.
OPENING_REPORT = "Announce the resolved repository and the batch (issue number range) before starting."

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

    def test_the_opening_report_precedes_every_mutation(self):
        # The echo is what catches a resolution that was wrong; an echo after
        # the first close would catch it too late to matter.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            report = flattened.index(OPENING_REPORT)
            with self.subTest(asset=relative_path):
                self.assertLess(report, flattened.index("**Verify each issue's"))
                for leading in TRACKER_MUTATIONS:
                    self.assertLess(
                        report, flattened.index(f"gh {leading}"), leading
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
