"""The vendored project-review workflow's own behavioral contract.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
      or: python3 tools/test_project_review_workflow.py

Issue #462, slice VEND-4 of `docs/workflow_command_vendoring_design.md` — the
heaviest reconciliation in the arc. The two personal copies implemented
*opposite* terminal acts over 223 differing lines: the Claude copy drafted issue
bodies, stopped for approval, and filed them, while the Codex copy forbade
tracker writes outright and wrote a canonical findings report instead. Design
D-9 resolved that in favour of the Codex copy, so what both bundles now ship is
report-only. Three consequences follow, and each is asserted here rather than
left to review.

* **Report-only is a property of the document, not a promise about it.** A
  rendered body that said "never create an issue" while still carrying a
  tracker-creating call would read, to the agent executing it top to bottom, as
  permission. So the prohibition is checked as an absence — no `gh` call outside
  the six declared ones, no issue creation, no origin-routing marker — and the
  terminal act is pinned as the one report write.
* **Every `gh` call names the repository.** Design D-5 requires it of all eight
  vendored commands. This one never mutates a tracker, so a wrong repository
  costs no data — it costs the whole run, which is spent reviewing code the user
  did not ask about and reported as if it were theirs. The calls are pinned
  exactly: six of them, six spellings, `-R "$REPO"` on each. The resolution
  that fills `$REPO` reads the remote with `git` and `sed`, so an initial
  `gh repo view` — a GitHub call made before the identity every other call
  depends on exists — is refused by name.
* **The four Codex-only capabilities reach both brands.** Requirement 4: direct
  commit mode with its cursor rules, the exclusive boundary rule, the five
  ordered report-filename rules, and the `Captured note` / `Verification` /
  `Evidence` / `Handoff context` capture shape existed in one copy only, and
  each is downstream of writing a report rather than an issue body. They are
  pinned per brand, because a capability that survived for one provider and not
  the other is exactly what the shared source exists to prevent.

The rest is D-2's preserved behavior (requirement 9): the 12-unit default, the
newest-first order, the issue-as-proposed-specification judgement, the
nits-are-not-findings bar, the fixed-later and already-tracked one-liner
handling, and the clean-batch rule that writes no report but still preserves its
cursor are vendored as they read today, so each is pinned rather than merely
rendered.

The negative control is the brand boundary itself: `BrandBoundaryTests` asserts
that stripping the three declared brand-specific lines leaves two byte-identical
bodies, so a rule that quietly matched everything could not also pass there.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent

SOURCE = "tools/command_sources/project-review.md"
CLAUDE_ASSET = "claude-plugin/plugins/kanban/commands/project-review.md"
CODEX_ASSET = "codex-plugin/plugins/kanban/skills/project-review/SKILL.md"
RENDERED_ASSETS = (CLAUDE_ASSET, CODEX_ASSET)

BUNDLE_ROOTS = ("claude-plugin", "codex-plugin")

# A `gh` invocation as the assets actually spell them, in a fenced block or in
# inline code. The lookbehind keeps a `gh` that ends a longer word out, and the
# required lowercase subcommand keeps the prose mentions of a "`gh` call" out:
# what is left is only text an agent would run.
GH_INVOCATION_RE = re.compile(r"(?<![\w-])gh (?P<tail>[a-z][^\n`]*)")

# The six GitHub reads the workflow makes, by the leading words that identify
# each, in the order the document introduces them. Every one is a read: this
# workflow performs no tracker mutation at all, which is the whole of D-9.
# `gh issue view` is the linked-issue read, and it is load-bearing rather than
# decorative: the workflow's central judgement is the merged diff against what
# the issue should have required, and `gh pr view` returns the pull request's
# own description, never that specification. `gh issue list` appears twice
# because deduplication lists the open backlog once up front and then searches
# all states per finding.
GITHUB_READS = (
    'pr list -R "$REPO" --state merged',
    'pr view -R "$REPO"',
    'issue view -R "$REPO"',
    'pr diff -R "$REPO"',
    'issue list -R "$REPO" --state open',
    'issue list -R "$REPO" --search',
)
DECLARED_GITHUB_CALL_COUNT = len(GITHUB_READS)

# The listing that opens PR mode has to reach the batch it was asked for. A
# fixed `--limit` silently truncates any request that reaches past it -- a
# count above the constant, or a starting PR older than the newest N merged --
# and the truncation is invisible, because a shorter listing looks exactly like
# a shorter history. So the limit is pinned as a variable, the constant is
# refused by name, and the three conditions that have to hold before selection
# are pinned individually.
LISTING_LIMIT = '--limit "$LIMIT"'
REFUSED_FIXED_LIMIT = "--limit 40 "
LISTING_REACH = {
    "the limit is not a constant": "**`$LIMIT` is not a constant.**",
    "verified before selecting": (
        "verify the listing actually reaches the batch you asked for, before "
        "selecting anything from it"
    ),
    "the count fits": "- the requested count fits inside the listing;",
    "the starting PR appears": "- a supplied starting PR appears in it;",
    "the boundary is covered": (
        "- a boundary endpoint from the cursor is at or above its oldest entry."
    ),
    "raise and re-list": (
        "Raise `$LIMIT` and list again until all three hold; `--limit` "
        "paginates for you, so a larger number is the whole remedy."
    ),
    "truncation is inherited": (
        "A batch selected from a listing that stopped short of its own boundary "
        "is silently truncated to whatever happened to fit, and every later "
        "`continue` inherits the gap."
    ),
    "an unreachable request stops": (
        "If the listing cannot reach the request — a starting PR that does not "
        "exist, a count larger than the repository's merged history — say so "
        "and stop rather than reviewing the nearest thing that fits."
    ),
}

# Why the linked-issue read cannot be folded into `gh pr view`.
LINKED_ISSUE_READ = (
    "Find its linked issue in that description's closing reference and read it "
    'with `gh issue view -R "$REPO" <m>`. Step 1\'s call returns the pull '
    "request's own description, never the specification it claims to satisfy, "
    "so this is a read of its own rather than a second look at the same text."
)

REPOSITORY_SCOPE = '-R "$REPO"'

# How `$REPO` is filled: from the remote, with no GitHub call of its own.
REPOSITORY_RESOLUTION = 'REPO="$(git remote get-url origin'

# How `$DOCS_WT` is filled: by branch, never by a hard-coded path. It is
# resolved once and used twice — the sweep cursor is read from it before a
# range is selected, and the finished report is written into it.
DOCS_WORKTREE_RESOLUTION = 'DOCS_WT="$(git worktree list --porcelain'

# The opening report, which is what catches a wrong resolution — and only if it
# lands before the first *read*. A run scoped against the wrong repository has
# already spent itself by the time anything is written.
OPENING_REPORT = (
    "name the resolved `$REPO` and the batch you are about to take before the "
    "first `gh` call below."
)

# The concrete range, which is not knowable until the listing returns, so it is
# restated after the read rather than guessed before it.
BATCH_RANGE_REPORT = (
    "Restate that concrete range beside the resolved `$REPO` once the listing "
    "returns, before reviewing anything in it."
)

# Requirement 3: the report-only contract, stated in the rendered body for both
# brands rather than only in the pull request that shipped it.
REPORT_ONLY = {
    "no tracker write": (
        "Do not modify code, push, touch merged PRs, or create or edit tracker "
        "issues."
    ),
    "the one default write": (
        "This workflow's only default write is one canonical Markdown findings "
        "report in the branch-resolved `docs-wip` worktree"
    ),
    "written only for a batch with a finding": (
        "written when a completed batch has at least one confirmed current finding"
    ),
    "the report is the handoff": "That report is the durable handoff to",
    "no drafting, no filing": (
        "Do not draft tracker issue bodies, ask which findings to file, open an "
        "issue through `gh`, or append any origin-routing marker"
    ),
    "restated at the write": (
        "this workflow never creates or edits a tracker issue, and the user's "
        "invocation authorizes the report handoff rather than a filing"
    ),
}

# Two spellings that would each turn the report-only contract back into a
# filing workflow, and one that would route the filing. Absence is the
# assertion; issue #462's acceptance greps for exactly these.
FORBIDDEN_SPELLINGS = ("gh issue create", "issue-origin")

# Requirement 4, capability 1: direct-commit mode and its cursor rules, which
# existed only in the Codex copy.
DIRECT_MODE = {
    "entered after PR history": (
        "After PR history is exhausted, continue from the first-parent parent "
        "of the earliest PR-owned commit already reviewed."
    ),
    "twelve older first-parent commits": (
        "Take exactly the next 12 older first-parent commits, newest-first"
    ),
    "a merge counts once": "A direct merge counts as one commit.",
    "resume from the parent, never HEAD": (
        "Every later `continue` resumes at the parent of the oldest completed "
        "direct commit; never restart from HEAD."
    ),
    "inventory is not review": (
        "A broad blame or survivor inventory is triage, not a reviewed "
        "direct-commit batch."
    ),
    "the initial commit has no parent": (
        "Use an empty-tree diff for the initial commit, which has no first "
        "parent to diff against."
    ),
    "stop at the initial commit": (
        "Stop explicitly after reviewing the initial commit."
    ),
    "history exhausted, not restarted": (
        "At the initial commit, report that history is exhausted rather than "
        "restarting or widening the batch."
    ),
}

# Requirement 4, capability 2, and requirement 5: the boundary rule ships as
# prose, and names the cursor's location under the reviewed repository's
# branch-resolved docs worktree (design D-11) rather than a bundled asset.
BOUNDARY_RULE = {
    "read before selecting a range": (
        "Before selecting a range, read "
        "`$DOCS_WT/docs/project_review_boundaries.md` when it exists."
    ),
    "the cursor belongs to the reviewed repository": (
        "That file is the sweep cursor for the repository under review, and it "
        "lives in that repository rather than travelling with this command"
    ),
    "exclusive older endpoint": (
        "treat the recorded PR as an **exclusive older endpoint** for a new "
        "newest-to-oldest sweep: stop before re-reviewing that PR unless the "
        "user explicitly overrides the boundary."
    ),
    "updated only on request": (
        "Update the entry only when the user asks to preserve a new endpoint."
    ),
}

# Requirement 4, capability 3: the five ordered report-filename rules. Pinned as
# an ordered sequence, because "in this order" is the rule — a set of five
# phrases in any arrangement would let rule 4's default outrank rule 1's
# explicit destination.
FILENAME_PRECEDENCE = (
    "An explicit destination from the user wins.",
    "If the user explicitly requests a report keyed to one number `N`, use "
    "`docs/project_review_N.md`",
    "If the user explicitly requests a report keyed to range `A–B`, use "
    "`docs/project_review_A-B.md`.",
    "Otherwise, a PR batch uses `docs/project_review_<newest>-<oldest>.md`.",
    "Direct mode uses `docs/project_review_direct_<newest7>-<oldest7>.md`",
)

# Requirement 4, capability 4: the capture shape that makes a report entry
# sufficient for a later process-report pass.
CAPTURE_SECTIONS = (
    "`Captured note`: the concise correction;",
    "`Verification`: what was proved and how;",
    "`Evidence`: current `file:line` traces and/or reproduction;",
    "`Handoff context`: current behavior, expected behavior, scope and",
)

# The canonical report structure a later process-report pass reads back. The
# legend's literal opening and the one-key-twice rule are what make the
# checklist a durable cursor rather than a summary.
REPORT_STRUCTURE = {
    "the legend is labelled": (
        "The legend line must begin literally `Status legend:`; an unlabeled "
        "list of marker meanings is not canonical."
    ),
    "the legend line itself": (
        "Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · "
        "`[no-issue]`"
    ),
    "the status checklist": "## Status",
    "a checklist entry": "- [ ] PRR-1. <Finding title>",
    "a finding heading": "### PRR-1. <Finding title>",
    "one key, twice, in order": (
        "Each stable `PRR-*` key appears exactly once in the checklist and once "
        "in a finding heading, in the same order and with the same title."
    ),
    "new findings start unmarked": "Keep every new finding unchecked and unmarked.",
}

# Requirement 9: behavior vendored as it reads today, one phrase per rule.
PRESERVED_BEHAVIOR = {
    "review-only prohibition": "**Review only.**",
    "twelve-unit default": "Default to 12 review units.",
    "newest-first PR order": (
        "take the next 12 merged PRs newest-first"
    ),
    "over-fetch because gh order is not merge order": (
        "Over-fetch and sort by `mergedAt` yourself, because `gh`'s own "
        "ordering is not merge order"
    ),
    "direct commits inside the interval": (
        "Check `git log --first-parent` for direct-to-default-branch commits "
        "inside that landing interval and review them as bare commits."
    ),
    "a rebased PR's commits are not direct": (
        "Do not mislabel a rebased PR's individual commits as direct when "
        "GitHub associates them with the PR."
    ),
    "the issue is a proposed specification": (
        "Treat the issue as a proposed specification, not unquestioned authority."
    ),
    "a faithful bad spec is still a finding": (
        "A faithful implementation of a flawed specification is still a finding."
    ),
    "a justified deviation is not": (
        "A PR that deviated from a bad specification to do the right thing is not."
    ),
    "nits are not findings": (
        "Nits are not findings; a finding must require a real correction."
    ),
    "confirm it survives to HEAD": (
        "Confirm it still exists at HEAD — a later merge may already have fixed it."
    ),
    "never report a hunch": "Never report a hunch.",
    "fixed-later is a one-liner": (
        "Record fixed-later mistakes as completion-summary one-liners. Only "
        "current mistakes become unprocessed report entries."
    ),
    "already-tracked is a one-liner": (
        "An already-tracked finding is not a new unprocessed report entry; list "
        "it briefly in the completion summary."
    ),
    "do not stop the sweep": (
        "Keep reviewing the rest of the batch. Do not stop to discuss or file "
        "one finding."
    ),
    "compaction recovery": (
        "If context was compacted, recover the cursor from the last completed "
        "range or an unambiguous report name."
    ),
    "the completion message carries the cursor": (
        "link the report, state its unprocessed finding count, list fixed-later "
        "and already-tracked findings briefly, and preserve the oldest reviewed "
        "landing as the cursor."
    ),
    "publication is a separate request": (
        "Do not commit, publish, or push the report unless the user separately "
        "requests publication."
    ),
}

# The clean-batch rule, which is its own requirement-9 clause because it is the
# one path that ends with no report at all and still has to move the cursor.
CLEAN_BATCH = (
    "If a batch is clean, do not create an empty report unless explicitly "
    "requested. Say the range was clean and preserve its cursor."
)

# The write destination, which is the primary checkout's exclusion as much as
# the docs worktree's selection.
WRITE_DESTINATION = (
    "Write the report under `$DOCS_WT/docs/`, using the docs worktree resolved "
    'in "Scope and cursor" above — never the primary checkout'
)

# The one sentence that differs per brand because the providers really do pass
# arguments differently (design D-2/D-7 keep this rather than flattening it).
CLAUDE_ONLY_LINES = (
    "`$ARGUMENTS` may override the count, or name a PR number, commit SHA, or range.",
)

# The Codex argument convention, and the one caveat that names Codex's default
# read-only sandbox. Requirement 6: the caveat survives for Codex, and the
# Claude rendering gains no invented equivalent.
CODEX_ONLY_LINES = (
    "An explicit count, PR number, commit SHA, or range overrides the default.",
    "   In a read-only sandbox, a complete static trace may be the verification; say so.",
)

CODEX_ONLY_CAVEAT = CODEX_ONLY_LINES[1]


def read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def body_of(text: str) -> str:
    """`text` with its frontmatter block removed.

    The frontmatter is the one place the two renderings legitimately differ
    beyond the brand blocks — different keys, and the invocation sigils inside
    the description — so the brand-boundary comparison is made over the body.
    """
    match = re.match(r"\A---\n.*?\n---\n(?P<body>.*)\Z", text, re.DOTALL)
    assert match is not None, "a rendered asset always opens with frontmatter"
    return match.group("body")


# The workflows this source names through a `{{cmd:}}` token. Read from the
# source rather than restated, so the brand comparison below covers exactly the
# substitutions requirement 8 asks for and no more.
REFERENCED_WORKFLOWS = renderer.referenced_names(
    (REPO_ROOT / SOURCE).read_text(encoding="utf-8")
)


def neutralize(text: str, brand: str) -> str:
    """`text` with `brand`'s spelling of each declared `{{cmd:}}` target put
    back into the neutral token.

    Requirement 8 makes the invocation sigil a per-brand difference by design,
    so the boundary comparison is made over what the one source authored rather
    than over the substitution. Undoing it here loses nothing:
    `test_each_brand_reads_its_own_invocation_sigil` is what asserts the
    substitution actually happened, in each direction.
    """
    sigil = renderer.SIGILS[brand]
    for name in sorted(REFERENCED_WORKFLOWS, key=len, reverse=True):
        text = text.replace(f"{sigil}{name}", f"{{{{cmd:{name}}}}}")
    return text


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
            if candidate.name == "project-review"
        )
        self.assertEqual(entry.source, SOURCE)
        rendered = renderer.render_entry(entry, REPO_ROOT)
        self.assertEqual(set(rendered), set(RENDERED_ASSETS))
        for relative_path, text in rendered.items():
            self.assertEqual(read(relative_path), text, relative_path)

    def test_no_bundle_ships_an_auxiliary_reference_directory(self):
        # Requirement 5 and design D-10: the boundary rule ships as prose, and
        # the file it describes does not ship at all — it is one consuming
        # repository's cursor, and bundling it would put that state in every
        # install. The renderer emits one file per brand and nothing else, so
        # this holds by construction; it is asserted because the construction
        # is what a later slice might be tempted to extend.
        for root in BUNDLE_ROOTS:
            for directory in (REPO_ROOT / root).rglob("references"):
                self.assertFalse(
                    directory.is_dir(),
                    f"{directory} ships an auxiliary asset directory",
                )


class RepositoryScopeTests(unittest.TestCase):
    """Requirement 7: no `gh` call in either rendered file omits `-R "$REPO"`."""

    def test_the_github_calls_are_exactly_the_six_declared_ones(self):
        # Non-vacuity for the scoping assertion below: a regex that stopped
        # matching would report no unscoped call for the same reason a file
        # with no calls does.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                calls = GH_INVOCATION_RE.findall(read(relative_path))
                self.assertEqual(len(calls), DECLARED_GITHUB_CALL_COUNT, calls)

    def test_every_github_call_names_the_resolved_repository(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for match in GH_INVOCATION_RE.finditer(content):
                call = match.group(0)
                with self.subTest(asset=relative_path, call=call):
                    self.assertIn(
                        REPOSITORY_SCOPE,
                        call,
                        f"{relative_path}: {call!r} would read whatever "
                        "repository the session's working directory happens "
                        "to be in",
                    )

    def test_each_declared_read_is_present_and_scoped(self):
        # The count above says five; this says *which* five, so one read
        # silently replaced by a second copy of another still fails.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for leading in GITHUB_READS:
                with self.subTest(asset=relative_path, call=leading):
                    self.assertIn(f"gh {leading}", content)

    def test_the_listing_limit_is_not_a_fixed_constant(self):
        # Blocker from round 1 of this pull request's review. The retired copies
        # both listed `--limit 40`, which cannot honor a requested count above
        # 40 or a starting PR older than the 40 newest merged pull requests --
        # in either case the PR the workflow promises to select is absent from
        # the only listing it takes.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(LISTING_LIMIT, content)
                self.assertNotIn(REFUSED_FIXED_LIMIT, content)

    def test_the_listing_is_verified_to_reach_the_requested_batch(self):
        # The other half: a variable limit fixes nothing unless the workflow
        # checks that the value it used was large enough. All three conditions
        # are pinned individually, because covering only the count would leave
        # a supplied starting PR and a recorded boundary endpoint unreachable
        # for exactly the same reason.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for rule, phrase in sorted(LISTING_REACH.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)

    def test_the_reach_check_precedes_the_review_of_the_batch(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            with self.subTest(asset=relative_path):
                self.assertLess(
                    flattened.index(flat(LISTING_REACH["verified before selecting"])),
                    flattened.index("## Review PRs newest-first"),
                )

    def test_the_linked_issue_has_a_read_of_its_own(self):
        # Blocker from round 1 of this pull request's review. The workflow's
        # central judgement is the merged diff against what the issue should
        # have required, so "read its linked issue" needs a call that returns
        # one -- and `gh pr view` is not it.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            with self.subTest(asset=relative_path):
                self.assertIn(flat(LINKED_ISSUE_READ), flattened)
                self.assertLess(
                    flattened.index('gh issue view -R "$REPO"'),
                    flattened.index(f"gh {GITHUB_READS[3]}"),
                )

    def test_the_repository_is_resolved_without_a_github_call_of_its_own(self):
        # Requirement 7 is absolute, so the resolution itself may not be a `gh`
        # invocation: at that point `$REPO` does not exist yet, and the call
        # could not carry `-R`. The remote is read with git and sed instead.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(REPOSITORY_RESOLUTION, content)
                self.assertNotIn("gh repo view", content)

    def test_resolution_precedes_every_github_call(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            first_call = GH_INVOCATION_RE.search(content)
            self.assertIsNotNone(first_call, relative_path)
            with self.subTest(asset=relative_path):
                self.assertLess(
                    content.index(REPOSITORY_RESOLUTION),
                    first_call.start(),
                    f"{relative_path}: the first GitHub call is made before "
                    "$REPO is resolved",
                )

    def test_the_opening_report_precedes_every_github_call(self):
        # Every call — this workflow's reads are all it has, so a report that
        # landed after them would name the wrong repository only once the whole
        # batch had already been scoped and reviewed against it.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            report = flattened.index(OPENING_REPORT)
            for leading in GITHUB_READS:
                with self.subTest(asset=relative_path, call=leading):
                    self.assertLess(
                        report,
                        flattened.index(f"gh {leading}"),
                        f"{relative_path}: gh {leading} runs before the "
                        "opening report names the repository it targets",
                    )

    def test_the_batch_range_is_restated_before_the_review_begins(self):
        # The other half of the announcement: the PR-number or SHA range is not
        # knowable until the listing returns, so it follows the first read —
        # but it still precedes reviewing anything the listing produced.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            restatement = flattened.index(BATCH_RANGE_REPORT)
            with self.subTest(asset=relative_path):
                self.assertLess(flattened.index(OPENING_REPORT), restatement)
                self.assertLess(
                    flattened.index(f"gh {GITHUB_READS[0]}"), restatement
                )
                self.assertLess(
                    restatement, flattened.index("## Review PRs newest-first")
                )
                self.assertLess(
                    restatement, flattened.index(f"gh {GITHUB_READS[1]}")
                )

    def test_the_docs_worktree_is_resolved_by_branch_before_both_of_its_uses(self):
        # `$DOCS_WT` is resolved once and used twice — the cursor is read from
        # it before a range is selected, and the report is written into it at
        # the end. A hard-coded path is refused by name in the same breath,
        # because the PR drainer autostashes the primary checkout.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            with self.subTest(asset=relative_path):
                resolution = flattened.index(DOCS_WORKTREE_RESOLUTION)
                self.assertLess(
                    resolution, flattened.index(flat(BOUNDARY_RULE["read before selecting a range"]))
                )
                self.assertLess(resolution, flattened.index(flat(WRITE_DESTINATION)))
                self.assertIn(flat(WRITE_DESTINATION), flattened)


class ReportOnlyTests(unittest.TestCase):
    """Requirement 3 and design D-9: the Codex copy's behavior won."""

    def test_the_report_only_contract_is_stated_in_both_renderings(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for rule, phrase in sorted(REPORT_ONLY.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)

    def test_neither_rendering_can_create_or_route_a_tracker_issue(self):
        # The prohibition as an absence rather than a promise. An agent reads
        # the document top to bottom and runs what it finds, so a surviving
        # creation call would read as permission whatever the prose said.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for spelling in FORBIDDEN_SPELLINGS:
                with self.subTest(asset=relative_path, spelling=spelling):
                    self.assertNotIn(spelling, content)
            for match in GH_INVOCATION_RE.finditer(content):
                tail = match.group("tail")
                with self.subTest(asset=relative_path, call=match.group(0)):
                    self.assertTrue(
                        tail.startswith(
                            (
                                "pr list",
                                "pr view",
                                "pr diff",
                                "issue view",
                                "issue list",
                            )
                        ),
                        f"{relative_path}: gh {tail!r} is not one of the six "
                        "declared reads, so this workflow's GitHub surface is "
                        "no longer read-only",
                    )

    def test_the_terminal_act_is_one_report_in_the_docs_worktree(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            with self.subTest(asset=relative_path):
                self.assertIn(
                    flat(
                        "After completing the batch, directly write one report "
                        "when there is at least one new current finding."
                    ),
                    flattened,
                )
                self.assertIn(flat(WRITE_DESTINATION), flattened)

    def test_a_clean_batch_writes_no_report_and_keeps_its_cursor(self):
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn(flat(CLEAN_BATCH), flat(read(relative_path)))

    def test_the_handoff_names_the_disposition_workflow_for_its_own_brand(self):
        # Requirement 8: every cross-command reference is a {{cmd:}} token, so
        # each brand's reader is told to type its own sigil.
        self.assertIn("/process-report", read(CLAUDE_ASSET))
        self.assertNotIn("$process-report", read(CLAUDE_ASSET))
        self.assertIn("$process-report", read(CODEX_ASSET))
        self.assertNotIn("/process-report", read(CODEX_ASSET))


class SweepCursorTests(unittest.TestCase):
    """Requirement 4's first two capabilities, and requirement 5's placement."""

    def test_direct_commit_mode_and_its_cursor_rules_reach_both_brands(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for rule, phrase in sorted(DIRECT_MODE.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)

    def test_the_boundary_rule_reaches_both_brands_as_prose(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for rule, phrase in sorted(BOUNDARY_RULE.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)

    def test_the_boundary_is_read_before_a_range_is_selected(self):
        # The rule is only a boundary if it is consulted first: a cursor read
        # after the listing has been taken cannot stop the sweep from
        # re-reviewing completed history.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            with self.subTest(asset=relative_path):
                self.assertLess(
                    flattened.index(
                        flat(BOUNDARY_RULE["read before selecting a range"])
                    ),
                    flattened.index(f"gh {GITHUB_READS[0]}"),
                )


class ReportShapeTests(unittest.TestCase):
    """Requirement 4's last two capabilities: filenames and the capture shape."""

    def test_the_five_filename_rules_are_present_in_their_declared_order(self):
        # "in this order" is the rule, not decoration: rule 1's explicit
        # destination has to outrank rule 4's default, and a set membership
        # check would pass on any arrangement.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            positions = []
            for rule in FILENAME_PRECEDENCE:
                with self.subTest(asset=relative_path, rule=rule[:40]):
                    self.assertIn(flat(rule), flattened)
                positions.append(flattened.index(flat(rule)))
            self.assertEqual(positions, sorted(positions), relative_path)

    def test_the_capture_shape_reaches_both_brands(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for section in CAPTURE_SECTIONS:
                with self.subTest(asset=relative_path, section=section[:30]):
                    self.assertIn(flat(section), flattened)

    def test_the_canonical_report_structure_reaches_both_brands(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            flattened = flat(content)
            for rule, phrase in sorted(REPORT_STRUCTURE.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)
            # The checklist entry and the finding heading carry the same key,
            # which is what makes the report a resumable cursor rather than a
            # summary; the template shows both spellings of it.
            self.assertEqual(content.count("PRR-1. <Finding title>"), 2, relative_path)


class PreservedBehaviorTests(unittest.TestCase):
    """Requirement 9: the slice reconciles and relocates; it does not redesign."""

    def test_every_preserved_rule_survives_in_both_renderings(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for rule, phrase in sorted(PRESERVED_BEHAVIOR.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)


class BrandBoundaryTests(unittest.TestCase):
    """Requirement 6, and the negative control for every rule above.

    Three lines differ between the two renderings' bodies and no others. If a
    rule asserted here matched everything, it would also have to match the
    stripped bodies, and this comparison would fail.
    """

    def stripped(self, relative_path: str, brand: str, drop) -> list[str]:
        lines = neutralize(body_of(read(relative_path)), brand).splitlines()
        for line in drop:
            self.assertIn(line, lines, f"{relative_path}: {line!r}")
        return [line for line in lines if line not in drop]

    def test_the_bodies_differ_only_by_the_three_declared_brand_lines(self):
        claude = self.stripped(CLAUDE_ASSET, "claude", CLAUDE_ONLY_LINES)
        codex = self.stripped(CODEX_ASSET, "codex", CODEX_ONLY_LINES)
        self.assertEqual(claude, codex)

    def test_the_declared_command_references_are_the_ones_the_source_names(self):
        # Non-vacuity for the neutralization above: an empty referenced set
        # would make it a no-op, and the comparison would then fail on the
        # sigils instead of quietly passing -- but it would also stop covering
        # the substitution at all, so the set is pinned.
        self.assertEqual(REFERENCED_WORKFLOWS, {"project-review", "process-report"})

    def test_the_codex_sandbox_caveat_is_absent_from_the_claude_rendering(self):
        claude = read(CLAUDE_ASSET)
        codex = read(CODEX_ASSET)
        self.assertIn(CODEX_ONLY_CAVEAT.strip(), codex)
        self.assertNotIn(CODEX_ONLY_CAVEAT.strip(), claude)
        # No invented Claude equivalent either: the word the caveat is about
        # does not appear in that rendering at all.
        self.assertNotIn("sandbox", claude)

    def test_the_argument_convention_is_per_brand(self):
        claude = read(CLAUDE_ASSET)
        codex = read(CODEX_ASSET)
        self.assertIn("$ARGUMENTS", claude)
        self.assertNotIn("$ARGUMENTS", codex)
        self.assertIn(CODEX_ONLY_LINES[0], codex)
        self.assertNotIn(CODEX_ONLY_LINES[0], claude)

    def test_each_brand_reads_its_own_invocation_sigil(self):
        self.assertIn("/project-review", read(CLAUDE_ASSET))
        self.assertIn("$project-review", read(CODEX_ASSET))
        self.assertNotIn("$project-review", read(CLAUDE_ASSET))
        self.assertNotIn("/project-review", read(CODEX_ASSET))


if __name__ == "__main__":
    unittest.main()
