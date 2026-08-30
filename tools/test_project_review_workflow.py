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

Issue #548 added the vendored cursor mechanism but inverted PR-mode traversal:
it treated the repository's fixed exclusive older boundary as a moving
resume-below frontier. `project_review_cursor.py` still ships in both bundles
and owns the state document and reconciliation, but PR batches now record exact
reviewed and excluded coverage while every fresh invocation starts again at the
newest merged PR and walks toward the same boundary. These tests exercise that
behavior as real state transitions: clean and finding-bearing batches preserve
coverage without moving the boundary, a newly merged PR is selected ahead of
older durable coverage, explicit exclusions persist, legacy prose boundaries
migrate without losing exceptional reviewed PRs, and direct mode retains its
moving older-history frontier. Each transition carries a negative control that
varies the relevant coverage or boundary field, so the assertions prove which
part of the state actually governs selection.

The prose pins stay beside them and neither half stands in for the other: the
rendered asset is the program an agent executes, so what it says about the
cursor is a contract in its own right, while what the mechanism does with the
cursor is one a substring check cannot reach.

The negative control for the prose half is the brand boundary itself:
`BrandBoundaryTests` asserts that stripping the seven declared brand-specific
lines leaves two byte-identical bodies, so a rule that quietly matched
everything could not also pass there.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import re
import shutil
import tempfile
import unittest
from pathlib import Path

import render_command_sources as renderer

REPO_ROOT = Path(__file__).resolve().parent.parent

SOURCE = "tools/command_sources/project-review.md"
CLAUDE_ASSET = "claude-plugin/plugins/kanban/commands/project-review.md"
CODEX_ASSET = "codex-plugin/plugins/kanban/skills/project-review/SKILL.md"
RENDERED_ASSETS = (CLAUDE_ASSET, CODEX_ASSET)

BUNDLE_ROOTS = ("claude-plugin", "codex-plugin")

# Issue #548's cursor mechanism, vendored the way the trusted-comment helper is:
# one module, a copy in each bundle held byte-identical, and no tracked original
# under tools/ because nothing in this repository invokes it. The workflow runs
# in whatever repository it was pointed at, which tracks no copy of anything,
# so the helper has to travel with the command that calls it.
CLAUDE_CURSOR_HELPER = "claude-plugin/plugins/kanban/scripts/project_review_cursor.py"
CODEX_CURSOR_HELPER = (
    "codex-plugin/plugins/kanban/skills/project-review/scripts/"
    "project_review_cursor.py"
)
CURSOR_HELPERS = {"claude": CLAUDE_CURSOR_HELPER, "codex": CODEX_CURSOR_HELPER}

# How each brand's rendered asset names it. Neither spelling is a path into the
# reviewed repository: the helper ships with the bundle, so it is resolved
# against the bundle's own install location.
CURSOR_HELPER_LOOKUP = {
    "claude": 'CURSOR="${CLAUDE_PLUGIN_ROOT}/scripts/project_review_cursor.py"',
    "codex": (
        'CURSOR="$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" -path '
        "'*/kanban/*/skills/project-review/scripts/project_review_cursor.py' "
        '2>/dev/null | head -n1)"'
    ),
}

# The three invocations the workflow makes, in the order it makes them.
CURSOR_INVOCATIONS = (
    'python3 "$CURSOR" select --root "$DOCS_WT" --repo "$REPO" --mode pr',
    'python3 "$CURSOR" select --root "$DOCS_WT" --repo "$REPO" --mode direct',
    '--mode pr --count "${COUNT:-12}" --listing-limit "$LIMIT" --start "$RANGE_START" --end "$RANGE_END"',
    '--mode direct --count "${COUNT:-12}" --start "$RANGE_START" --end "$RANGE_END"',
    'python3 "$CURSOR" record --root "$DOCS_WT" --repo "$REPO" --mode pr',
    'python3 "$CURSOR" read --root "$DOCS_WT" --repo "$REPO"',
)

# The direct-mode walk, which is the whole first-parent history rather than a
# slice beginning at the entry point. A sliced walk would leave the recorded
# endpoint outside the listing the helper positions within, and the helper
# would then refuse it as a foreign cursor on every later batch -- a fail-closed
# stop, but one produced by the caller rather than by any real disagreement.
DIRECT_WALK = 'git -C "$ROOT" log --first-parent --format=%H \\'
REFUSED_SLICED_DIRECT_WALK = "--format=%H <entry-point>"

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

# The merged listing is taken twice and every other read once (issue #548): the
# first fills `select`, and the second orders the endpoint `record` writes after
# the batch is complete. They are deliberately two calls rather than one saved
# listing, because recording happens after the report has been written and
# validated -- possibly a long way after -- and a listing re-taken then is
# re-validated against current merged history rather than trusted from memory.
# A later merge only adds rows above the batch, so it cannot reorder it.
REPEATED_GITHUB_READS = {'pr list -R "$REPO" --state merged': 2}
DECLARED_GITHUB_CALL_COUNT = sum(
    REPEATED_GITHUB_READS.get(read, 1) for read in GITHUB_READS
)

# The listing that opens PR mode has to reach the batch it was asked for. A
# fixed `--limit` silently truncates any request that reaches past it -- a
# count above the constant, or a starting PR older than the newest N merged --
# and the truncation is invisible, because a shorter listing looks exactly like
# a shorter history. So the limit is pinned as a variable, the constant is
# refused by name, and the three conditions that have to hold before selection
# are pinned individually.
LISTING_LIMIT = '--limit "$LIMIT"'
REFUSED_FIXED_LIMIT = "--limit 40 "

# The limit the listing was taken with, declared to the selection. Issue #548's
# round-1 blocker: a count checked against the *page* passes on a page that ends
# at the cursor and selects nothing, and a sweep reading that as the tail enters
# direct mode with merged pull requests still unreviewed behind it. So the count
# is checked against the selection, and a short batch is `truncated` or
# `exhausted` depending on whether the page came back at its own limit.
DECLARED_LISTING_LIMIT = '--listing-limit "$LIMIT"'
LISTING_REACH = {
    "the limit is not a constant": (
        "**`$LIMIT` is not a constant, and `--listing-limit` is how the "
        "selection knows it.**"
    ),
    "the count is checked against the selection": (
        "The question the reach check has to answer is not whether the listing "
        "holds twelve rows; it is whether the listing reaches the recorded "
        "boundary and whether twelve *selectable* rows survive above it once "
        "coverage and exclusions come out."
    ),
    "a page must reach the boundary": (
        "A page that does not contain the boundary cannot prove where the "
        "sweep must stop, even when its first twelve rows are selectable."
    ),
    "the three answers are never collapsed": (
        "its answer to a short batch is one of three things that must never be "
        "collapsed"
    ),
    "truncated means raise and re-list": (
        "**`\"truncated\": true`** — the batch came up short and the listing "
        "came back at its own limit, so the missing pull requests may be on "
        "the next page. Raise `$LIMIT` and list again."
    ),
    "truncation is inherited": (
        "Treating this as the tail leaves merged pull requests unreviewed "
        "behind the sweep for good, and every later `continue` inherits the "
        "gap."
    ),
}

# What an exhausted listing that still fails a condition means. The three do
# not share an answer, and collapsing them was round 2's blocker: a single
# "stop when the request cannot be reached" rule refuses the ordinary tail
# batch, so a sweep with fewer PRs left than the batch size never finishes PR
# history and direct mode is never entered.
EXHAUSTION_DISPOSITIONS = {
    "a real absence is one under the limit": (
        "**Absent from a listing that came back under its limit** is a real "
        "absence."
    ),
    "an absent starting PR is invalid": (
        "A supplied starting PR that is absent is an invalid request: that "
        "PR is not in this repository's merged history at all. Say so and "
        "stop; do not review the nearest number that exists."
    ),
    "an absent boundary is a foreign cursor": (
        "A boundary endpoint that is absent is a cursor that does not "
        "belong to this repository. Say so and stop rather than sweeping past "
        "it."
    ),
    "an absence at the limit is a short page": (
        "**Absent from a listing that came back at its own limit** is a short "
        "page, not a missing unit. Raise `$LIMIT` and list again; the refusal "
        "says so in those words."
    ),
    "a short count is the tail, not an error": (
        "**`\"exhausted\": true`** — the batch came up short and the listing "
        "came back with fewer rows than `$LIMIT`, which is the whole of the "
        "repository's merged history and no PR boundary ended the scan. "
        "**This is not an error at all.** It is the tail of an unbounded "
        "sweep."
    ),
    "a small repository is the same case": (
        "A repository with fewer merged PRs than the batch size meets this on "
        "its first batch and is reviewed the same way."
    ),
    "reaching a boundary is not exhaustion": (
        "**`\"boundary_reached\": true`** — every selectable PR above the "
        "exclusive boundary has been reviewed or skipped. Stop the PR sweep "
        "there."
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
REPOSITORY_RESOLUTION = 'REPO="$(git -C "$ROOT" remote get-url origin'

# `$REPO` names the tracker; `$ROOT` names the checkout. Most of this workflow
# never touches GitHub -- direct mode walks first-parent history, the
# surviving-behavior trace reads the code at HEAD, and the docs worktree holds
# both the cursor and the report -- so a `$REPO` the session's own checkout is
# not a checkout of would audit one repository's pull requests against
# another's code and write its report into another's docs worktree. Neither is
# undone by moving a file afterwards, so the two are required to agree before
# the first call.
CHECKOUT_RESOLUTION = 'ROOT="$(git rev-parse --show-toplevel)"'
CHECKOUT_TARGET = {
    "both are resolved, and neither substitutes": (
        "`$REPO` is the `owner/name` every `gh` call names; `$ROOT` is the "
        "local checkout every other step runs in, and neither substitutes for "
        "the other."
    ),
    "the git steps run under the checkout": (
        'Run them all under `$ROOT` with `git -C "$ROOT"`, never in whatever '
        "directory the session happens to be sitting in."
    ),
    "a named repository does not adopt this checkout": (
        "When the user named a repository, `$ROOT` is a checkout **of that "
        "repository**, and the session's own is not it unless it proves to be."
    ),
    "the two must agree": (
        'run that same `git -C "$ROOT" remote get-url` and **require the two '
        "to agree**. They must name one `owner/name` between them."
    ),
    "a mismatch stops the run": (
        "A mismatch, or no available checkout of `$REPO`, stops the run before "
        "the first `gh` call"
    ),
    "the working directory is never the repair": (
        "Falling back to the working directory is never the repair."
    ),
}

# Every git invocation that reads the repository under review, which is every
# one of them except the `rev-parse` that establishes `$ROOT` itself.
CHECKOUT_SCOPED_GIT = (
    'git -C "$ROOT" remote get-url origin',
    'git -C "$ROOT" worktree list --porcelain',
    'git -C "$ROOT" log --first-parent',
    'git -C "$ROOT" show --stat --summary',
    'git -C "$ROOT" diff',
)

# How `$DOCS_WT` is filled: by branch, never by a hard-coded path. It is
# resolved once and used twice — the sweep cursor is read from it before a
# range is selected, and the finished report is written into it.
DOCS_WORKTREE_RESOLUTION = 'DOCS_WT="$(git -C "$ROOT" worktree list --porcelain'

# The opening report, which is what catches a wrong resolution — and only if it
# lands before the first *read*. A run scoped against the wrong repository has
# already spent itself by the time anything is written.
OPENING_REPORT = (
    "name the resolved `$REPO`, the `$ROOT` it was matched against, and the "
    "batch you are about to take before the first `gh` call below."
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
    "two kinds of default write": (
        "This workflow writes exactly two kinds of file, both in the "
        "branch-resolved `docs-wip` worktree and neither of them a tracker "
        "artifact."
    ),
    "every batch records its cursor": (
        "Every completed batch records its sweep cursor, clean or not."
    ),
    "the report needs a finding": (
        "A batch with at least one confirmed current finding additionally "
        "writes one canonical Markdown findings report."
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
        "**PR history existed.** Continue from the first-parent parent of the "
        "earliest PR-owned commit already reviewed."
    ),
    "a repository with no PR history starts at HEAD": (
        "**There was none.** A repository whose merged-PR listing came back "
        "empty has no earliest PR-owned commit to walk back from, so start at "
        "the default branch's own HEAD and take the first-parent commits from "
        "there."
    ),
    "that is the only entry at HEAD": (
        "This is the only case in which direct mode begins at HEAD, and a "
        "repository that has never used pull requests is otherwise never "
        "audited at all."
    ),
    "twelve older first-parent commits": (
        "Either way, take exactly the next 12 older first-parent commits, "
        "newest-first, unless the user supplied another count."
    ),
    "a merge counts once": "A direct merge counts as one commit.",
    "a commit may be abbreviated": (
        "A commit may be named at any length `git` itself accepts — four "
        "characters up, the seven a direct-mode report filename carries "
        "included. `select` and `record` resolve an abbreviated SHA against "
        "the walk, and refuse a prefix that names more than one commit rather "
        "than choosing between them, so length is never the refusal; ambiguity "
        "is."
    ),
    "the entry point is supplied on the first direct batch": (
        "**`$RANGE_START` carries the entry point on the first direct batch**, "
        "and is empty for every batch after it. Set it to the first-parent "
        "parent of the earliest PR-owned commit already reviewed, and leave it "
        "empty for a repository whose merged-PR listing came back empty, which "
        "begins at HEAD."
    ),
    "an empty start is no start": (
        "An empty `--start` is no start at all, so this one invocation covers "
        "both — but leaving it empty on the *first* batch of a repository that "
        "did have PR history restarts the walk at HEAD and re-reviews PR-owned "
        "commits, because direct state is still empty at that moment and there "
        "is no endpoint to position it."
    ),
    "the direct walk is never sliced": (
        "**Walk the whole first-parent history, not a slice starting at the "
        "entry point.** The recorded endpoint has to be inside the listing the "
        "helper positions within, and a walk that began below it would refuse "
        "it as a cursor belonging to some other history."
    ),
    "the entry point is a start, not a slice": (
        "Pass the entry point as `--start` on the first direct batch only — "
        "the first-parent parent of the earliest PR-owned commit already "
        "reviewed, or nothing at all for a repository whose merged-PR listing "
        "came back empty, which starts at HEAD. Every batch after that is "
        "positioned by the record."
    ),
    "resume from the parent, never HEAD": (
        "Every later `continue` resumes at the parent of the oldest completed "
        "direct commit; never restart from HEAD once a batch has been reviewed."
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

# Requirement 4, capability 2, and requirement 5: the cursor rule ships as
# prose, and names the cursor's location under the reviewed repository's
# branch-resolved docs worktree (design D-11) rather than a bundled asset. What
# issue #548 changed is the second half of it: the entry is written by every
# completed batch instead of only when a user asks, so the rule now has to say
# so, and the clean batch has to be named as the case that records the same
# endpoint a finding-bearing one does.
CURSOR_RULE = {
    "the helper owns the file": (
        "The helper owns `$DOCS_WT/docs/project_review_boundaries.md`, the "
        "sweep cursor for the repository under review."
    ),
    "the cursor belongs to the reviewed repository": (
        "It lives in that repository rather than travelling with this command"
    ),
    "PR batches record coverage, not a moving boundary": (
        "Every completed PR batch instead records the exact PRs reviewed, plus "
        "any exclusions, so the next invocation can start at merged HEAD, skip "
        "durable coverage, and continue toward the same boundary."
    ),
    "direct mode takes no coverage from a report": (
        "In this mode a report contributes no coverage at all. A first-parent "
        "commit inside some report's interval is covered only when the "
        "recorded endpoint says it was reviewed, and is otherwise selected. A "
        "report that states its interval held no direct commits has been wrong "
        "about eight of them, and a commit erased that way is erased for good."
    ),
    "a clean batch records the same coverage": (
        "**A clean batch records reviewed coverage exactly as a finding-bearing "
        "batch does.**"
    ),
    "selection precedes review, not the report": (
        "Selection is the helper's too, and it happens before any unit is "
        "reviewed rather than in the report-writing step."
    ),
    "the helper reconciles record and reports": (
        "`select` reads the candidate history on stdin, reconciles the recorded "
        "coverage with the `docs/project_review_*.md` reports beside it, and "
        "returns the batch."
    ),
}

# The four rules the reconciliation is held to, each of them a mistake the
# sweep has already made rather than a preference. They are pinned as prose
# because they are the contract an agent reads; that the shipped mechanism
# actually implements them is `CursorSelectionTests`' business, and neither
# half stands in for the other.
RECONCILIATION_RULES = {
    "selection starts at merged HEAD": (
        "**PR selection always starts at merged HEAD.** The boundary is the "
        "exclusive stop, never the starting position."
    ),
    "merge order, not numeric order": (
        "**The recorded PR boundary is merge order, not numeric order.** The "
        "helper resolves it in the `mergedAt`-sorted history before deciding "
        "where to stop."
    ),
    "a report covers only what it identifies": (
        "**A report covers only the PRs it explicitly identifies**, which is "
        "what its filename endpoints name — never every number between them."
    ),
    "a report says what to skip, not where to begin or stop": (
        "a report says what to skip and never where to begin or stop."
    ),
    "a report never covers a direct commit": (
        "**A report never establishes direct-commit coverage.** A first-parent "
        "commit inside a reviewed interval is either covered by the recorded "
        "endpoint or selected"
    ),
    "unverifiable state stops the run": (
        "**Unverifiable state stops the run.** A recorded PR is validated "
        "against merged history and a recorded SHA against current first-parent "
        "ancestry, so a malformed, foreign, or ambiguous cursor refuses before "
        "review rather than guessing."
    ),
    "the first run on an unrecorded repository": (
        "A repository holding reports but no record yet — every repository, the "
        "first time this runs — therefore starts at the head of its history and "
        "skips the units its reports name. With no boundary it keeps walking "
        "the complete PR history across batches by recording exact reviewed "
        "units."
    ),
    "an uncovered unit is selected, not reported as a gap": (
        "An uncovered unit above the boundary is selected in newest-first "
        "order, never reduced to a warning while the workflow continues below "
        "it."
    ),
    "the original boundary document migrates": (
        "The helper also migrates the original human-authored `stop before PR "
        "#N` boundary document"
    ),
}

# Round 4's blocker: `--start` is one endpoint, and a range has two. Without
# the second, the count keeps filling downwards past the older endpoint
# whenever coverage or an exclusion thins the middle of the request, so the
# range the user asked for is not the range they get.
RANGE_BOUND = {
    "both endpoints are carried": (
        "`$RANGE_START` and `$RANGE_END` carry a user-supplied range's two "
        "endpoints — its newer and its older — and are empty when the user "
        "supplied none; an empty `--start` or `--end` is no bound at all, so "
        "one invocation covers both cases."
    ),
    "the override stays out until asked for": (
        "Add `--override-boundary` only when the user explicitly overrides the "
        "recorded boundary; unlike the two range flags it has a correct "
        "default and is never implied, so it stays out of the invocation until "
        "a user asks for it."
    ),
    "a start alone is not a range": (
        "**A range needs both of its endpoints.** `$RANGE_START` alone is a "
        "starting point, not a range: the count keeps filling downwards past "
        "the older endpoint whenever coverage or an exclusion thins the middle "
        "of the request, and a user who asked for #466–#461 with three of "
        "those already reviewed is handed three units from below #461 to make "
        "the number up."
    ),
    "the end is a bound, not a target": (
        "`--end` is a bound rather than a target — the batch stops there "
        "whatever the count still had left, and reports `\"bounded\": true` "
        "rather than `truncated` or `exhausted`, because it was the request "
        "that ended and neither the page nor the history."
    ),
    "a direct range uses the same two slots": (
        "A user-supplied range's newer endpoint goes in the same slot, and "
        "`$RANGE_END` bounds it exactly as in PR mode."
    ),
}

# Correction 1 of this issue's review: a count is the batch size and nothing
# else. Without this, "the requested count" reads as a licence to restart the
# sweep wherever the requester happened to be looking.
COUNT_IS_NOT_A_POSITION = (
    "**A count is a batch size, not a position.** An explicit count changes how "
    "many units this batch takes and nothing else. Only an explicit PR number, "
    "commit SHA, or range changes this batch's requested start; a boundary "
    "override changes the exclusive stop for that requested batch, and a unit "
    "the user excluded is never selected again by a later invocation."
)

# Correction 2: the `DOCS_WT="$ROOT"` fallback is gone rather than merely
# discouraged. It contradicted the rule it sat two lines above -- the primary
# checkout is the one place neither cursor nor report may be written.
DOCS_WORKTREE_FAIL_CLOSED = {
    "an empty resolution stops the run": (
        "**An empty `$DOCS_WT` stops the run, and `$ROOT` is not the "
        "fallback.**"
    ),
    "why the primary checkout is refused": (
        "The primary checkout is where the PR drainer's post-merge "
        "fast-forward autostashes whatever it finds, so a cursor or report "
        "written there is not durable state at all — it is the next merge's "
        "wedge."
    ),
}
REFUSED_DOCS_WORKTREE_FALLBACK = '|| DOCS_WT="$ROOT"'

# The recording listing, which is taken later than the selection's and is
# therefore more exposed to it: merges landing during a long review push older
# rows off a bounded page, and a reviewed unit missing from one would otherwise
# be refused as a wrong claim, leaving a completed batch with no endpoint at
# all. Round-1 blocker.
RECORDING_LISTING_REACH = {
    "the same rule, needed more": (
        "**The recording listing is taken under the same rule, and needs it "
        "more.** It is taken after the batch was reviewed and its report "
        "written, which can be a long way after the batch was selected, and "
        "merges landing in between push older rows off a bounded page — so the "
        "`$LIMIT` that reached the batch at selection time need not reach it "
        "now."
    ),
    "raise and re-list on an absent unit": (
        "Declare it, and raise it and list again whenever `record` reports a "
        "reviewed or excluded unit absent from a listing that came back at its "
        "own limit."
    ),
    "recording nothing is the outcome to refuse": (
        "Recording nothing is the one outcome to refuse here: the batch is "
        "already reviewed, and a completed batch with no durable coverage is "
        "exactly the state this cursor exists to prevent."
    ),
}

# The record step, which closes the loop the cursor rule opens. Its ordering
# clause is the review's fifth spec addition: a failed report or a failed
# cursor write is not a completed batch.
RECORD_STEP = {
    "recorded last": (
        "**Record the cursor last.** Record coverage only after every selected "
        "unit has been reviewed and any required report has been written and "
        "validated, so a failed report or a failed cursor write is never "
        "reported as a completed batch"
    ),
    "the batch size carries its own default": (
        "`$COUNT` is the requested count and defaults to the 12 above."
    ),
    "an empty batch records nothing": (
        "A batch that selected nothing records nothing and is not a completed "
        "batch: the helper refuses an empty `--reviewed` with an empty "
        "`--exclude` unless the user explicitly supplied a new PR boundary."
    ),
    "merged, never replaced": (
        "`record` merges rather than replaces: an earlier exclusion survives a "
        "later batch, a PR boundary stays fixed, and the direct endpoint only "
        "ever moves older."
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
        'Check `git -C "$ROOT" log --first-parent` for direct-to-default-branch '
        "commits inside that landing interval and review them as bare commits."
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
    "compaction recovery reads the record": (
        "If context was compacted, recover the cursor with "
        '`python3 "$CURSOR" read --root "$DOCS_WT" --repo "$REPO"` rather than '
        "from the last completed range or a report name"
    ),
    "the completion message names the boundary and progress": (
        "link the report, state its unprocessed finding count, list fixed-later "
        "and already-tracked findings briefly, and name the PR boundary and "
        "durable progress the record now holds."
    ),
    "publication is a separate request": (
        "Do not commit, publish, or push the report or the cursor unless the "
        "user separately requests publication. Both are left in the docs "
        "worktree as uncommitted working files; the cursor is durable because "
        "it is on disk, not because it was landed."
    ),
}

# The clean-batch rule is its own requirement-9 clause because it is the one
# path that ends with no report at all and still has to preserve durable review
# coverage.
CLEAN_BATCH = (
    "If a batch is clean, do not create an empty report unless explicitly "
    "requested. Say the range was clean and record its reviewed units anyway — "
    "a clean batch is a completed batch, and the run that follows starts at "
    "the latest merge, skips that durable coverage, and continues toward the "
    "same boundary without needing anything this session still remembers."
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
    CURSOR_HELPER_LOOKUP["claude"],
    '[ -f "$CURSOR" ]',
)

# The Codex argument convention, and the one caveat that names Codex's default
# read-only sandbox. Requirement 6: the caveat survives for Codex, and the
# Claude rendering gains no invented equivalent.
CODEX_ONLY_LINES = (
    "An explicit count, PR number, commit SHA, or range overrides the default.",
    CURSOR_HELPER_LOOKUP["codex"],
    '[ -n "$CURSOR" ]',
    "   In a read-only sandbox, a complete static trace may be the verification; say so.",
)

CODEX_ONLY_CAVEAT = CODEX_ONLY_LINES[-1]


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

    def test_an_exhausted_listing_is_dispositioned_per_condition(self):
        # Blocker from round 2. Refusal is preserved for the two requests that
        # really are invalid, and the tail batch -- the one case that is not --
        # is reviewed rather than refused, which is what lets PR history
        # actually exhaust and direct mode be reached.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for rule, phrase in sorted(EXHAUSTION_DISPOSITIONS.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)

    def test_the_tail_batch_is_never_refused(self):
        # The negative control for the rule above: the round 2 spelling refused
        # every unreachable request alike, so the phrase that did it must be
        # gone rather than merely supplemented.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertNotIn(
                    "a count larger than the repository's merged history — say "
                    "so and stop",
                    flat(content),
                )

    def test_the_page_is_no_longer_what_the_count_is_checked_against(self):
        # The negative control for the reach rewrite. The retired conditions
        # asked whether the *listing* held the requested count, which a page
        # ending at the cursor satisfies while selecting nothing; the phrase
        # that asked it must be gone rather than merely supplemented.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            with self.subTest(asset=relative_path):
                self.assertNotIn(
                    "- the requested count fits inside the listing;", flattened
                )
                self.assertNotIn(
                    "verify the listing actually reaches the batch you asked "
                    "for, before selecting anything from it",
                    flattened,
                )

    def test_the_reach_check_precedes_the_review_of_the_batch(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            with self.subTest(asset=relative_path):
                self.assertLess(
                    flattened.index(
                        flat(LISTING_REACH["the count is checked against the selection"])
                    ),
                    flattened.index("## Review PRs newest-first"),
                )

    def test_both_listings_declare_the_limit_they_were_taken_with(self):
        # Round-1 blocker, both halves. A limit the helper is not told about
        # leaves it unable to tell a short page from a short history, and it
        # then has to answer the cautious way for every listing or the wrong
        # way for some -- so the declaration is pinned on both calls, and the
        # recording listing's rule is pinned with it because that listing is
        # the later and more exposed of the two.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            flattened = flat(content)
            with self.subTest(asset=relative_path):
                self.assertEqual(content.count(DECLARED_LISTING_LIMIT), 2, content.count(DECLARED_LISTING_LIMIT))
                for rule, phrase in sorted(RECORDING_LISTING_REACH.items()):
                    with self.subTest(rule=rule):
                        self.assertIn(flat(phrase), flattened)

    def test_the_checkout_is_resolved_and_required_to_match_the_repository(self):
        # Blocker from round 2. `$REPO` scoped the `gh` calls and nothing else,
        # so a user-named repository left every git read, the cursor and the
        # report in whatever checkout the session was sitting in.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            flattened = flat(content)
            with self.subTest(asset=relative_path):
                self.assertIn(CHECKOUT_RESOLUTION, content)
                for rule, phrase in sorted(CHECKOUT_TARGET.items()):
                    with self.subTest(rule=rule):
                        self.assertIn(flat(phrase), flattened)

    def test_every_repository_read_runs_under_the_resolved_checkout(self):
        # Non-vacuity for the rule above: requiring the two to agree is worth
        # nothing if the git steps still run in the working directory. Every
        # `git` invocation is pinned as `-C "$ROOT"` except the one that
        # establishes `$ROOT` itself, and the exception is pinned as the only
        # one rather than left implicit.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                for invocation in CHECKOUT_SCOPED_GIT:
                    self.assertIn(invocation, content, invocation)
                unscoped = [
                    line
                    for line in content.splitlines()
                    if re.search(r'(?<![\w-])git (?!-C "\$ROOT")', line)
                ]
                self.assertEqual(
                    unscoped,
                    [CHECKOUT_RESOLUTION],
                    f"{relative_path}: a git invocation reads a checkout other "
                    "than the one $REPO was matched against",
                )

    def test_the_announcement_names_the_checkout_as_well(self):
        # The opening report catches a wrong resolution, and after round 2
        # there are two things to get wrong rather than one.
        for relative_path in RENDERED_ASSETS:
            with self.subTest(asset=relative_path):
                self.assertIn("`$ROOT` it was matched against", OPENING_REPORT)
                self.assertIn(flat(OPENING_REPORT), flat(read(relative_path)))

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
                    resolution, flattened.index(flat(CURSOR_RULE["the helper owns the file"]))
                )
                self.assertLess(resolution, flattened.index(flat(WRITE_DESTINATION)))
                self.assertIn(flat(WRITE_DESTINATION), flattened)

    def test_the_docs_worktree_resolution_has_no_primary_checkout_fallback(self):
        # Correction 2 of issue #548's review. The fallback assigned `$ROOT`
        # two lines above the paragraph forbidding a write to `$ROOT`, so the
        # workflow's own resolution was the one path to the destination it
        # refuses. Absence is the assertion: a paragraph explaining why the
        # primary checkout is wrong reads as advice while the assignment that
        # selects it is still there.
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            flattened = flat(content)
            with self.subTest(asset=relative_path):
                self.assertNotIn(REFUSED_DOCS_WORKTREE_FALLBACK, content)
                for rule, phrase in sorted(DOCS_WORKTREE_FAIL_CLOSED.items()):
                    with self.subTest(rule=rule):
                        self.assertIn(flat(phrase), flattened)


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

    def test_the_two_direct_mode_entry_points_are_distinguished(self):
        # Blocker from round 3. Round 2 made the zero-merged-PR case reachable
        # by allowing the tail batch, and the entry rule it reaches walks back
        # from "the earliest PR-owned commit already reviewed" -- which does
        # not exist when the listing came back empty. Both entry points are
        # pinned, and the ordering between them, so a rewrite cannot keep the
        # general rule and quietly drop the one that makes a
        # never-used-pull-requests repository auditable.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            with self.subTest(asset=relative_path):
                self.assertIn(
                    flat(
                        "the entry point depends on whether there was any"
                    ),
                    flattened,
                )
                self.assertLess(
                    flattened.index(flat(DIRECT_MODE["entered after PR history"])),
                    flattened.index(
                        flat(
                            DIRECT_MODE[
                                "a repository with no PR history starts at HEAD"
                            ]
                        )
                    ),
                )

    def test_the_cursor_rule_reaches_both_brands_as_prose(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for rule, phrase in sorted(CURSOR_RULE.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)

    def test_the_reconciliation_rules_reach_both_brands(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for rule, phrase in sorted(RECONCILIATION_RULES.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)

    def test_an_explicit_range_carries_both_of_its_endpoints(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for rule, phrase in sorted(RANGE_BOUND.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)

    def test_a_count_is_a_batch_size_rather_than_a_position(self):
        # Correction 1 of issue #548's review. "The requested count" appears
        # beside the resume rules, so without this an explicit count reads as
        # permission to restart the sweep wherever the requester was looking.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            with self.subTest(asset=relative_path):
                self.assertIn(flat(COUNT_IS_NOT_A_POSITION), flattened)

    def test_the_record_step_is_stated_and_ordered_last(self):
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            for rule, phrase in sorted(RECORD_STEP.items()):
                with self.subTest(asset=relative_path, rule=rule):
                    self.assertIn(flat(phrase), flattened)
            with self.subTest(asset=relative_path):
                self.assertLess(
                    flattened.index(flat(WRITE_DESTINATION)),
                    flattened.index(flat(RECORD_STEP["recorded last"])),
                )

    def test_the_cursor_is_read_before_a_range_is_selected(self):
        # The rule is only a cursor if it is consulted first: a record read
        # after the listing has been taken cannot stop the sweep from
        # re-reviewing completed history. Both halves are ordered -- the rule
        # that names the file, and the invocation that reads it -- because the
        # prose moving above the listing while the call stayed below it would
        # leave the selection exactly as unreconciled as it was.
        for relative_path in RENDERED_ASSETS:
            flattened = flat(read(relative_path))
            listing = flattened.index(f"gh {GITHUB_READS[0]}")
            with self.subTest(asset=relative_path):
                self.assertLess(
                    flattened.index(flat(CURSOR_RULE["the helper owns the file"])),
                    listing,
                )
                self.assertLess(
                    flattened.index(
                        flat(CURSOR_RULE["selection precedes review, not the report"])
                    ),
                    listing,
                )
                self.assertLess(
                    flattened.index(flat(CURSOR_INVOCATIONS[0])),
                    flattened.index("## Review PRs newest-first"),
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

    Seven lines differ between the two renderings' bodies and no others: the
    argument convention, the two lines of each brand's cursor-helper lookup,
    and the Codex-only sandbox caveat. If a rule asserted here matched
    everything, it would also have to match the stripped bodies, and this
    comparison would fail.
    """

    def stripped(self, relative_path: str, brand: str, drop) -> list[str]:
        lines = neutralize(body_of(read(relative_path)), brand).splitlines()
        for line in drop:
            self.assertIn(line, lines, f"{relative_path}: {line!r}")
        return [line for line in lines if line not in drop]

    def test_the_bodies_differ_only_by_the_declared_brand_lines(self):
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
        # Measured with the renderer's own notion of where an invocation
        # token starts and ends, not with a bare substring: since issue #548
        # the Codex asset resolves its helper through the bundle path
        # `*/skills/project-review/scripts/...`, and a substring check would
        # read that path segment as a Claude invocation and fail on it. The
        # renderer already draws that line -- it is what refuses a literal
        # sigil in an authored source -- so the test reads the line from there
        # rather than drawing a second one that could disagree.
        for brand, relative_path in (("claude", CLAUDE_ASSET), ("codex", CODEX_ASSET)):
            content = read(relative_path)
            own = renderer.SIGILS[brand]
            other = renderer.SIGILS["codex" if brand == "claude" else "claude"]
            with self.subTest(asset=relative_path):
                self.assertIn(f"{own}project-review", content)
                self.assertIn(
                    "project-review",
                    renderer.LITERAL_INVOCATION_PATTERNS[own].findall(content),
                )
                self.assertNotIn(
                    "project-review",
                    renderer.LITERAL_INVOCATION_PATTERNS[other].findall(content),
                )


class BundledCursorHelperTests(unittest.TestCase):
    """The mechanism ships with the command that calls it, in both bundles."""

    def test_both_bundles_carry_the_helper_and_the_copies_are_identical(self):
        # Vendored the way trusted_issue_spec.py is: no tracked tools/ original,
        # because nothing in this repository invokes it -- the workflow runs in
        # whatever repository it was pointed at, and that repository tracks no
        # copy of anything this bundle ships. Two copies then have to be held
        # identical, or the two brands diverge exactly the way the 223 lines
        # this command was vendored to reconcile did.
        claude = (REPO_ROOT / CLAUDE_CURSOR_HELPER).read_bytes()
        codex = (REPO_ROOT / CODEX_CURSOR_HELPER).read_bytes()
        self.assertTrue(claude, CLAUDE_CURSOR_HELPER)
        self.assertEqual(claude, codex)

    def test_each_asset_resolves_the_copy_its_own_bundle_ships(self):
        # A lookup into the reviewed repository, or into the other brand's
        # bundle, resolves nothing wherever this command actually installs.
        for brand, relative_path in (("claude", CLAUDE_ASSET), ("codex", CODEX_ASSET)):
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(CURSOR_HELPER_LOOKUP[brand], content)
                self.assertNotIn("$DOCS_WT/project_review_cursor.py", content)
                self.assertNotIn("$ROOT/tools/project_review_cursor.py", content)

    def test_the_helper_is_invoked_for_selection_in_both_modes_and_for_recording(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            for invocation in CURSOR_INVOCATIONS:
                with self.subTest(asset=relative_path, invocation=invocation):
                    self.assertIn(invocation, content)

    def test_the_direct_walk_is_the_whole_first_parent_history(self):
        for relative_path in RENDERED_ASSETS:
            content = read(relative_path)
            with self.subTest(asset=relative_path):
                self.assertIn(DIRECT_WALK, content)
                self.assertNotIn(REFUSED_SLICED_DIRECT_WALK, content)

    def test_the_helper_spawns_no_external_command(self):
        # The reconciliation is arithmetic over listings the workflow already
        # took, so the helper needs no repository access of its own. Pinned as
        # an absence because a helper that shelled out would need declaring in
        # docs/agent-workflow-contract.md, and would also be reaching a
        # checkout the caller never told it about.
        source = (REPO_ROOT / CLAUDE_CURSOR_HELPER).read_text(encoding="utf-8")
        for forbidden in ("subprocess", "os.system", "os.popen"):
            with self.subTest(spelling=forbidden):
                self.assertNotIn(forbidden, source)


def load_cursor_helper(brand: str):
    """The bundled helper, imported from the copy `brand` actually ships.

    Loaded by path under a private name because it is a bundled asset rather
    than an importable package: `tools/` is not its home, and giving it one
    would make the tests pass against a module the workflow never reaches.
    """
    path = REPO_ROOT / CURSOR_HELPERS[brand]
    spec = importlib.util.spec_from_file_location(
        f"kanban_{brand}_plugin_project_review_cursor", path
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CURSOR_MODULES = {brand: load_cursor_helper(brand) for brand in CURSOR_HELPERS}
CURSOR = CURSOR_MODULES["claude"]

REPO = "coghex/kanban"

# A merged history whose number order is deliberately not its merge order:
# #471 merged before #468 and #470, exactly the way the real batch recorded in
# docs/project_review_466-399.md ran #466, #467, #465, #464, #406 … A cursor
# that kept "the smallest number reviewed" would describe a batch that never
# happened, and would then hand the next invocation a starting point above
# work it had already done.
PR_HISTORY = (
    (470, "2026-08-20T00:00:00Z"),
    (468, "2026-08-19T00:00:00Z"),
    (471, "2026-08-18T00:00:00Z"),
    (466, "2026-08-17T00:00:00Z"),
    (465, "2026-08-16T00:00:00Z"),
    (464, "2026-08-15T00:00:00Z"),
    (463, "2026-08-14T00:00:00Z"),
    (462, "2026-08-13T00:00:00Z"),
    (461, "2026-08-12T00:00:00Z"),
)

# `gh pr list` does not return merge order, so the listing handed to the helper
# is deliberately in some other order: sorting it is the helper's job, and a
# fixture that pre-sorted it would never exercise that.
PR_LISTING = [
    {"number": number, "mergedAt": merged_at}
    for number, merged_at in sorted(PR_HISTORY)
]

# A first-parent walk, newest-first, as `git log --first-parent --format=%H`
# prints it.
DIRECT_HISTORY = (
    "ed90877ac1",
    "6d54e98bb2",
    "3b3c54f0c3",
    "a920f7cd14",
    "b80f628e25",
    "e84f7320f6",
    "65001ff1a7",
    "331d70e2b8",
)


class CursorTransitionCase(unittest.TestCase):
    """A docs worktree, and the helper acting on it across invocations.

    Every assertion below goes through the shipped module's own serialization
    and reconciliation rather than through a selection oracle written here.
    That is the point: the defect this issue reports is invisible to a
    substring check, because the prose already claimed the cursor was
    preserved. What was missing was a mechanism, so what is tested is the
    mechanism.
    """

    def setUp(self):
        self.worktree = Path(tempfile.mkdtemp(prefix="project-review-cursor-"))
        self.addCleanup(shutil.rmtree, self.worktree, ignore_errors=True)
        (self.worktree / "docs").mkdir()
        self.module = CURSOR

    # -- the workflow's own two calls, made the way the asset makes them ----

    def state(self):
        """A fresh read, as a later invocation carrying no context would do."""
        return self.module.state_for(self.module.load_document(self.worktree), REPO)

    def page(self, rows):
        """The newest `rows` merged pull requests, as a bounded `gh` page.

        `gh pr list --limit N` returns a page of the newest N merges, so a
        bounded listing is a prefix of merge order -- and the older units the
        sweep is resuming towards are exactly what falls off it.
        """
        ordered = sorted(PR_HISTORY, key=lambda entry: entry[1], reverse=True)
        return [
            {"number": number, "mergedAt": merged_at}
            for number, merged_at in ordered[:rows]
        ]

    def select(self, mode="pr", count=3, state=None, candidates=None, **kwargs):
        listing = PR_LISTING if mode == "pr" else list(DIRECT_HISTORY)
        return self.module.select(
            self.state() if state is None else state,
            mode,
            self.module.normalize_candidates(
                mode, listing if candidates is None else candidates
            ),
            count,
            reports=self.module.report_coverage(self.worktree),
            **kwargs,
        )

    def record(self, selection, mode="pr", exclude=(), boundary=None):
        listing = PR_LISTING if mode == "pr" else list(DIRECT_HISTORY)
        updated = self.module.record(
            self.state(),
            mode,
            self.module.normalize_candidates(mode, listing),
            [self.units(selection)] if isinstance(selection, (int, str)) else self.units(selection),
            list(exclude),
            boundary=boundary,
        )
        document = self.module.load_document(self.worktree)
        document.setdefault("repositories", {})[REPO] = updated
        self.module.write_document(self.worktree, document)
        return updated

    def units(self, selection):
        if isinstance(selection, dict):
            selection = selection["selected"]
        if isinstance(selection, (int, str)):
            return selection
        return [
            entry["number"] if "number" in entry else entry["sha"] for entry in selection
        ]

    def write_report(self, name, body="# Project Review Findings\n"):
        (self.worktree / "docs" / name).write_text(body, encoding="utf-8")

    def run_cli(self, command, *arguments):
        """One invocation of the surface the rendered assets actually run.

        The library calls above are the same code, but the argument parsing,
        the unit lists, and the stdin/file candidate reading are only exercised
        here — and those are what an asset's fence is made of.
        """
        captured = io.StringIO()
        with contextlib.redirect_stdout(captured):
            self.module.main(
                [command, "--root", str(self.worktree), "--repo", REPO, *arguments]
            )
        return json.loads(captured.getvalue())

    def forget_the_cursor(self):
        """Delete the record, leaving the reports and the history untouched.

        The negative control every transition below owes: if an assertion still
        holds once the record is gone, durable state was not what produced it.
        """
        self.module.document_path(self.worktree).unlink()


class CursorSelectionTests(CursorTransitionCase):
    """Requirement 3 and requirement 9: the transitions, not the prose."""

    def test_a_clean_batch_records_and_the_next_invocation_starts_at_head(self):
        # The defect, end to end. A clean batch writes no report, so before
        # this mechanism it left nothing at all behind and the next invocation
        # re-selected the batch it had just finished.
        first = self.select(count=3)
        self.assertEqual(self.units(first), [470, 468, 471])
        self.assertEqual(first["origin"], "history-head")

        self.record(first)  # clean: no report written, cursor recorded anyway
        self.assertEqual(list((self.worktree / "docs").glob("project_review_*.md")),
                         [self.module.document_path(self.worktree)])

        second = self.select(count=3)
        self.assertEqual(self.units(second), [466, 465, 464])
        self.assertEqual(second["origin"], "history-head")

        # Remove the durable reviewed set and the second invocation repeats the first --
        # which is exactly what was observed twice while
        # docs/project_review_466-399.md was being produced.
        self.forget_the_cursor()
        self.assertEqual(self.units(self.select(count=3)), [470, 468, 471])

    def test_a_finding_bearing_batch_records_the_same_coverage_as_a_clean_one(self):
        # Requirement 1: the two batches differ only in whether a report was
        # also written, so the state they leave has to be identical.
        clean = self.record(self.select(count=3))
        reference = json.dumps(clean, sort_keys=True)

        # The second run differs only in that the batch produced a finding, so
        # a report is written between the selection and the record -- which is
        # the order the workflow uses, and the order that keeps the report from
        # reconciling against the batch that is producing it.
        self.setUp()
        selection = self.select(count=3)
        self.write_report("project_review_471-470.md")
        finding_bearing = self.record(selection)
        self.assertEqual(json.dumps(finding_bearing, sort_keys=True), reference)
        self.assertEqual(self.units(self.select(count=3)), [466, 465, 464])
        self.assertIsNone(finding_bearing["pr"]["endpoint"])
        self.assertEqual(finding_bearing["pr"]["reviewed"], [468, 470, 471])

    def test_the_boundary_is_exclusive_and_resolved_in_merge_order(self):
        self.record([], boundary=471)
        selection = self.select(count=6)
        self.assertEqual(self.units(selection), [470, 468])
        self.assertEqual(selection["origin"], "recorded-boundary")
        self.assertTrue(selection["boundary_reached"])

        numeric = self.module.empty_state()
        numeric["pr"]["endpoint"] = {
            "number": 468,
            "merged_at": "2026-08-19T00:00:00Z",
        }
        self.assertEqual(self.units(self.select(count=6, state=numeric)), [470])

    def test_a_report_whose_coverage_overlaps_the_naive_selection_is_skipped(self):
        # The second correction the real sweep had to make: the batch below
        # the cursor was already covered by a separate report, and nothing
        # noticed until a human read the directory.
        self.record(self.select(count=3))
        self.write_report("project_review_465-464.md")

        selection = self.select(count=3)
        self.assertEqual(self.units(selection), [466, 463, 462])
        self.assertEqual(
            [entry["unit"] for entry in selection["skipped"]],
            [470, 468, 471, 465, 464],
        )

        # Without the report the same invocation takes the two units back, so
        # the skip is the report's doing rather than an artifact of the count.
        self.module.document_path(self.worktree)  # unchanged
        (self.worktree / "docs" / "project_review_465-464.md").unlink()
        self.assertEqual(self.units(self.select(count=3)), [466, 465, 464])

    def test_a_report_does_not_cover_the_numbers_between_its_endpoints(self):
        # Third spec addition. docs/project_review_463-455.md reviewed #463,
        # #456 and #455 and nothing between them, so reading `463-455` as
        # fifteen reviewed pull requests would erase twelve unreviewed ones --
        # silently, and permanently.
        self.write_report("project_review_466-462.md")
        selection = self.select(count=5)
        self.assertEqual(self.units(selection), [470, 468, 471, 465, 464])
        self.assertNotIn(466, self.units(selection))
        self.assertNotIn(462, self.units(selection))

    def test_a_direct_commit_inside_a_reported_interval_is_still_selected(self):
        # Requirement 5. docs/project_review_463-455.md states that no direct
        # first-parent commits landed in its interval while eight did, so a
        # report's account of the commits it covered establishes nothing at
        # all: coverage in direct mode comes from the record or from nowhere.
        self.write_report("project_review_direct_ed90877-331d70e.md")
        self.write_report("project_review_466-461.md")
        selection = self.select(mode="direct", count=3)
        self.assertEqual(self.units(selection), list(DIRECT_HISTORY[:3]))
        self.assertEqual(selection["skipped"], [])

        recorded = self.record(selection, mode="direct")
        self.assertEqual(
            recorded["direct"]["endpoint"], {"sha": DIRECT_HISTORY[2]}
        )
        self.assertEqual(
            self.units(self.select(mode="direct", count=3)),
            list(DIRECT_HISTORY[3:6]),
        )
        self.forget_the_cursor()
        self.assertEqual(
            self.units(self.select(mode="direct", count=3)),
            list(DIRECT_HISTORY[:3]),
        )

    def test_an_explicitly_excluded_unit_is_never_selected_again(self):
        # Requirement 4 and the review's second spec addition: an exclusion is
        # persisted independently of the endpoint, because advancing the
        # endpoint past it would otherwise be indistinguishable from having
        # reviewed it.
        self.record(self.select(count=3), exclude=[466])
        self.assertEqual(self.units(self.select(count=3)), [465, 464, 463])

        self.record(self.select(count=2))
        self.assertEqual(self.units(self.select(count=3)), [463, 462, 461])
        self.assertEqual(self.state()["excluded"]["prs"], [466])

    def test_a_requested_range_is_not_filled_from_beyond_its_older_end(self):
        # Round 4's blocker. Coverage thins the middle of the request, and
        # without an older bound the count makes the number up from below it —
        # so the user who asked for #466–#461 gets units they did not ask for,
        # and the sweep advances past them.
        self.write_report("project_review_471-468.md")
        selection = self.select(count=6, start=470, end=464)
        self.assertEqual(self.units(selection), [470, 466, 465, 464])
        self.assertTrue(selection["short"])
        self.assertTrue(selection["bounded"])
        self.assertFalse(selection["exhausted"])
        self.assertFalse(selection["truncated"])

        # The negative control, and the defect itself: the same request without
        # the older bound makes the count up from below #464, so the user is
        # handed two units they did not ask for and the sweep advances past
        # them.
        unbounded = self.select(count=6, start=470)
        self.assertEqual(self.units(unbounded), [470, 466, 465, 464, 463, 462])
        self.assertFalse(unbounded["bounded"])

    def test_a_range_bound_stops_the_batch_before_the_count_is_met(self):
        # The bound is a bound, not a target: it wins over a count that still
        # had room, in both modes.
        pr = self.select(count=9, start=470, end=466)
        self.assertEqual(self.units(pr), [470, 468, 471, 466])
        direct = self.select(
            mode="direct", count=9, start=DIRECT_HISTORY[1], end=DIRECT_HISTORY[3]
        )
        self.assertEqual(self.units(direct), list(DIRECT_HISTORY[1:4]))

    def test_a_range_end_may_be_abbreviated_and_is_refused_when_absent(self):
        bounded = self.select(mode="direct", count=9, end=DIRECT_HISTORY[2][:5])
        self.assertEqual(self.units(bounded), list(DIRECT_HISTORY[:3]))
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, end=9999)
        self.assertIn("the range ends at pull request #9999", str(caught.exception))

    def test_a_range_cannot_cross_the_boundary_without_an_override(self):
        self.record([], boundary=464)
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=9, start=470, end=463)
        self.assertIn("beyond recorded boundary #464", str(caught.exception))

    def test_a_count_changes_the_batch_size_and_not_the_position(self):
        # Correction 1. Both selections begin at the same unit; only how many
        # follow it differs.
        self.record(self.select(count=3))
        small = self.select(count=1)
        large = self.select(count=5)
        self.assertEqual(self.units(small), [466])
        self.assertEqual(self.units(large)[0], 466)
        self.assertEqual(small["begin_index"], large["begin_index"])
        self.assertEqual(small["origin"], large["origin"])

    def test_only_an_explicit_start_or_override_moves_the_position(self):
        self.record(self.select(count=3))
        started = self.select(count=2, start=465)
        self.assertEqual(self.units(started), [465, 464])
        self.assertEqual(started["origin"], "explicit-start")

        # An override lifts the coverage the position was built from as well
        # as the position itself; otherwise it moves the sweep back to the
        # head and then skips everything it finds there.
        overridden = self.select(count=2, override_boundary=True)
        self.assertEqual(self.units(overridden), [470, 468])
        self.assertEqual(overridden["origin"], "boundary-override")

    def test_an_override_still_honors_an_explicit_exclusion(self):
        # Requirement 4 is unconditional about this: a boundary override says
        # the coverage is wrong, not that the user changed their mind about a
        # unit they removed from the sweep.
        self.record(self.select(count=3), exclude=[466])
        overridden = self.select(count=9, override_boundary=True)
        self.assertNotIn(466, self.units(overridden))
        self.assertEqual(self.units(overridden)[0], 470)

    def test_units_above_an_older_batch_are_selected_from_head_not_reported_as_gaps(self):
        self.record([], boundary=461)
        self.record(self.select(count=2, start=465))
        later = self.select(count=9)
        self.assertEqual(self.units(later), [470, 468, 471, 466, 463, 462])
        self.assertEqual(later["gaps"], [])
        self.assertTrue(later["boundary_reached"])
        self.assertFalse(later["exhausted"])

    def test_a_report_never_moves_the_resume_position(self):
        # The other half of "a report covers only what it identifies": if a
        # report set the position as well as the coverage, everything it
        # skipped inside its own interval would fall above the resume point
        # and never be selected again. Re-reviewing two announced units is the
        # cheaper of the two errors, and the only one that can be noticed.
        self.write_report("project_review_466-461.md")
        selection = self.select(count=9)
        self.assertEqual(selection["origin"], "history-head")
        self.assertEqual(selection["begin_index"], 0)
        self.assertEqual(self.units(selection), [470, 468, 471, 465, 464, 463, 462])

    def test_a_batch_shorter_than_the_count_is_the_tail_rather_than_an_error(self):
        selection = self.select(count=50)
        self.assertEqual(len(selection["selected"]), len(PR_HISTORY))
        self.assertTrue(selection["exhausted"])

    def test_an_absent_recorded_endpoint_stops_the_run(self):
        # Fourth spec addition: a recorded PR is validated against merged
        # history rather than assumed. A cursor naming a pull request this
        # repository never merged belongs to some other repository, and
        # sweeping past it would review history twice.
        foreign = self.module.empty_state()
        foreign["pr"]["endpoint"] = {"number": 9999, "merged_at": "2026-01-01T00:00:00Z"}
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, state=foreign)
        self.assertIn("does not belong to this repository", str(caught.exception))

    def test_an_absent_recorded_sha_stops_the_run(self):
        foreign = self.module.empty_state()
        foreign["direct"]["endpoint"] = {"sha": "0123456"}
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(mode="direct", count=3, state=foreign)
        self.assertIn("first-parent ancestry", str(caught.exception))

    def test_an_absent_supplied_start_is_an_invalid_request(self):
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, start=9999)
        self.assertIn("not in this repository's merged history", str(caught.exception))

    def test_a_candidate_without_a_merge_timestamp_cannot_be_ordered(self):
        with self.assertRaises(self.module.CursorError):
            self.module.normalize_candidates("pr", [{"number": 470}])


class BoundedListingTests(CursorTransitionCase):
    """Round 1's blocker: a page is not a history, and the two must not read
    alike.

    `gh pr list --limit N` returns the newest N merges. A fixed boundary can
    fall beyond that page even when the selectable head rows are all present,
    so the page cannot prove that a short batch has reached the stop rather
    than merely running out of listed candidates. Reading truncation as either
    the boundary or repository tail can leave merged work unreviewed or enter
    direct mode prematurely.
    """

    def test_a_page_ending_at_the_boundary_stops_there(self):
        self.record([], boundary=471)
        boundary = self.state()["pr"]["endpoint"]["number"]

        # The page reaches the boundary and proves the exclusive stop.
        page = self.page(3)
        self.assertEqual(page[-1]["number"], boundary)
        selection = self.select(count=3, candidates=page, listing_limit=3)
        self.assertEqual(self.units(selection), [470, 468])
        self.assertTrue(selection["short"])
        self.assertTrue(selection["boundary_reached"])
        self.assertFalse(selection["truncated"])
        self.assertFalse(selection["exhausted"])

    def test_a_page_under_its_limit_that_comes_up_short_is_the_tail(self):
        # The other half, and the reason the two answers cannot be collapsed
        # into one refusal: a genuine tail must still be reviewed and must
        # still let PR history exhaust so direct mode is reached.
        selection = self.select(count=50, candidates=PR_LISTING, listing_limit=200)
        self.assertEqual(len(selection["selected"]), len(PR_HISTORY))
        self.assertTrue(selection["short"])
        self.assertFalse(selection["truncated"])
        self.assertTrue(selection["exhausted"])

    def test_an_undeclared_limit_is_taken_as_a_complete_listing(self):
        # The unbounded caller is the real one: direct mode hands over a whole
        # `git log --first-parent` walk, so reporting that as possibly
        # truncated would send the workflow raising a limit it never set. PR
        # mode always declares one, which the asset pin above holds it to.
        selection = self.select(count=3, candidates=self.page(2))
        self.assertTrue(selection["short"])
        self.assertTrue(selection["exhausted"])
        self.assertFalse(selection["truncated"])

        walk = self.select(mode="direct", count=50)
        self.assertTrue(walk["exhausted"])
        self.assertFalse(walk["truncated"])

    def test_a_unit_absent_from_a_full_page_asks_for_a_wider_one(self):
        # The refusals split the same way. "Not in this repository's merged
        # history at all" is a claim a bounded page cannot support, and acting
        # on it stops a sweep that only needed a larger number.
        page = self.page(3)
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, candidates=page, listing_limit=3, start=464)
        self.assertIn(self.module.RAISE_LIMIT_INSTRUCTION, str(caught.exception))
        self.assertNotIn(
            "is not in this repository's merged history", str(caught.exception)
        )

        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, candidates=page, listing_limit=99, start=464)
        self.assertIn(
            "is not in this repository's merged history", str(caught.exception)
        )
        self.assertNotIn(self.module.RAISE_LIMIT_INSTRUCTION, str(caught.exception))

    def test_an_endpoint_off_the_page_asks_for_a_wider_one(self):
        self.record([], boundary=464)
        page = self.page(3)
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=3, candidates=page, listing_limit=3)
        self.assertIn(self.module.RAISE_LIMIT_INSTRUCTION, str(caught.exception))
        self.assertNotIn("does not belong to this repository", str(caught.exception))

    def test_a_merge_during_review_does_not_strand_a_completed_batch(self):
        # Round 1's second blocker. The recording listing is taken after the
        # batch was reviewed and its report written; merges landing in between
        # push older rows off a bounded page, so the limit that reached the
        # batch at selection time need not reach it now. Refusing that as a
        # wrong claim leaves an already-reviewed batch with no durable
        # endpoint -- the exact state this cursor exists to prevent.
        selection = self.select(count=3, candidates=self.page(4), listing_limit=4)
        reviewed = self.units(selection)
        self.assertEqual(reviewed, [470, 468, 471])

        # Two newer pull requests merge while the batch is being reviewed, so
        # the same limit now returns a page that stops above the batch.
        later = [
            {"number": 480, "mergedAt": "2026-08-22T00:00:00Z"},
            {"number": 481, "mergedAt": "2026-08-21T00:00:00Z"},
        ] + self.page(2)
        with self.assertRaises(self.module.CursorError) as caught:
            self.module.record(
                self.state(),
                "pr",
                self.module.normalize_candidates("pr", later),
                reviewed,
                listing_limit=4,
            )
        self.assertIn(self.module.RAISE_LIMIT_INSTRUCTION, str(caught.exception))

        # Raising the limit records the batch that was already reviewed.
        widened = self.module.normalize_candidates(
            "pr",
            [
                {"number": 480, "mergedAt": "2026-08-22T00:00:00Z"},
                {"number": 481, "mergedAt": "2026-08-21T00:00:00Z"},
            ]
            + PR_LISTING,
        )
        recorded = self.module.record(
            self.state(), "pr", widened, reviewed, listing_limit=40
        )
        self.assertIsNone(recorded["pr"]["endpoint"])
        self.assertEqual(recorded["pr"]["reviewed"], [468, 470, 471])

    def test_an_absent_unit_in_a_complete_listing_is_still_refused_outright(self):
        # The negative control for the rule above: the softer refusal must be
        # the bounded-page case alone, or a genuinely wrong claim would send
        # the workflow into an unbounded raise-and-retry loop.
        with self.assertRaises(self.module.CursorError) as caught:
            self.module.record(
                self.state(),
                "pr",
                self.module.normalize_candidates("pr", PR_LISTING),
                [9999],
                listing_limit=200,
            )
        self.assertIn("absent from the candidate history", str(caught.exception))
        self.assertNotIn(self.module.RAISE_LIMIT_INSTRUCTION, str(caught.exception))


class AbbreviatedShaTests(CursorTransitionCase):
    """Round 2's blocker: one commit, several spellings.

    `git log --format=%H` prints forty characters. A user naming a commit reads
    the seven a direct-mode report filename carries — `docs/project_review_
    direct_<newest7>-<oldest7>.md` is the shape this workflow writes — and an
    endpoint recorded by an earlier run may be in either. Exact equality
    refuses a correctly-spelled commit as absent, which is a stop the sweep
    cannot be argued out of.
    """

    def test_an_abbreviated_start_names_the_commit_it_identifies(self):
        selection = self.select(mode="direct", count=2, start=DIRECT_HISTORY[2][:7])
        self.assertEqual(
            self.units(selection), list(DIRECT_HISTORY[2:4])
        )
        self.assertEqual(selection["origin"], "explicit-start")
        # The full spelling is the same request, so the two agree.
        self.assertEqual(
            self.units(self.select(mode="direct", count=2, start=DIRECT_HISTORY[2])),
            self.units(selection),
        )

    def test_an_abbreviated_recorded_endpoint_still_positions_the_sweep(self):
        # A cursor written by an earlier run, or by a walk taken with
        # `--format=%h`, holds a short SHA. It has to keep working against a
        # `%H` walk, or the sweep stops on state it wrote itself.
        short = self.module.empty_state()
        short["direct"]["endpoint"] = {"sha": DIRECT_HISTORY[1][:7]}
        selection = self.select(mode="direct", count=2, state=short)
        self.assertEqual(self.units(selection), list(DIRECT_HISTORY[2:4]))
        self.assertEqual(selection["origin"], "recorded-endpoint")

    def test_an_abbreviated_coverage_or_exclusion_entry_still_matches(self):
        short = self.module.empty_state()
        short["direct"]["reviewed"] = [DIRECT_HISTORY[0][:7]]
        short["excluded"]["commits"] = [DIRECT_HISTORY[1][:8]]
        selection = self.select(mode="direct", count=2, state=short)
        self.assertEqual(self.units(selection), list(DIRECT_HISTORY[2:4]))
        self.assertEqual(
            sorted(entry["reason"] for entry in selection["skipped"]),
            ["covered", "excluded"],
        )

    def test_recording_an_abbreviated_unit_stores_the_history_spelling(self):
        # The state converges on one name per commit rather than accumulating
        # a second every time a walk is taken with a different abbreviation.
        recorded = self.module.record(
            self.state(),
            "direct",
            self.module.normalize_candidates("direct", list(DIRECT_HISTORY)),
            [DIRECT_HISTORY[0][:7], DIRECT_HISTORY[1][:7]],
            [DIRECT_HISTORY[2][:7]],
        )
        self.assertEqual(recorded["direct"]["endpoint"], {"sha": DIRECT_HISTORY[1]})
        self.assertEqual(
            recorded["direct"]["reviewed"], sorted(DIRECT_HISTORY[:2])
        )
        self.assertEqual(recorded["excluded"]["commits"], [DIRECT_HISTORY[2]])

    def test_an_ambiguous_prefix_is_refused_rather_than_chosen(self):
        # The other half, and why this is a resolution rather than a loosened
        # comparison: a prefix naming two commits names neither, and picking
        # one would sweep a range nobody asked for.
        history = ["abcdef01aa", "abcdef01bb", "9999999999"]
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(
                mode="direct", count=1, candidates=history, start="abcdef0"
            )
        message = str(caught.exception)
        self.assertIn("names 2 commits", message)
        self.assertIn("abcdef01aa", message)
        self.assertIn("abcdef01bb", message)
        # Enough characters resolves it.
        self.assertEqual(
            self.units(
                self.select(
                    mode="direct", count=1, candidates=history, start="abcdef01a"
                )
            ),
            ["abcdef01aa"],
        )

    def test_a_prefix_shorter_than_seven_is_resolved_rather_than_refused(self):
        # Round 3's blocker. Git's own floor is four characters; a pattern that
        # refused five rejected an abbreviation git resolves, and it rejected
        # it before the ambiguity check that is what actually decides whether a
        # prefix names one commit. Length was doing the refusing, and length is
        # not the question.
        self.assertEqual(
            self.units(self.select(mode="direct", count=1, start="ed908")),
            [DIRECT_HISTORY[0]],
        )
        # Through the command line too, which is the surface the asset uses.
        walk = self.worktree / "walk.txt"
        walk.write_text("\n".join(DIRECT_HISTORY) + "\n", encoding="utf-8")
        selection = self.run_cli(
            "select",
            "--mode",
            "direct",
            "--count",
            "1",
            "--candidates",
            str(walk),
            "--start",
            "3b3c",
        )
        self.assertEqual(
            [entry["sha"] for entry in selection["selected"]], [DIRECT_HISTORY[2]]
        )

    def test_a_short_prefix_is_still_refused_when_it_names_two_commits(self):
        # The negative control for the floor: lowering it must not turn an
        # ambiguous prefix into an accepted one.
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(
                mode="direct",
                count=1,
                candidates=["abcdef01aa", "abcdef01bb"],
                start="abcd",
            )
        self.assertIn("names 2 commits", str(caught.exception))

    def test_a_pull_request_number_takes_the_exact_path(self):
        # Non-vacuity for the prefix rule: it is a SHA rule, and #46 must never
        # resolve to #466 the way `ed90877` resolves to `ed90877ac1`.
        with self.assertRaises(self.module.CursorError) as caught:
            self.select(count=1, start=46)
        self.assertIn("is not in this repository's merged history", str(caught.exception))


class CursorDocumentTests(CursorTransitionCase):
    """Requirement 7 and the fail-closed rule: what the state file may say."""

    def test_a_missing_document_is_the_only_absence_that_is_not_a_refusal(self):
        # A repository that has never been swept has no cursor, and that is
        # what every first invocation looks like. Every other unreadable state
        # is a refusal, because "unreadable" and "absent" select different
        # ranges and merging them is how a sweep loses history.
        self.assertEqual(
            self.module.load_document(self.worktree), self.module.empty_document()
        )
        self.assertEqual(self.state(), self.module.empty_state())

    def test_the_document_round_trips_through_its_own_serialization(self):
        recorded = self.record(self.select(count=3), exclude=[466])
        reread = self.state()
        self.assertEqual(reread, recorded)
        text = self.module.document_path(self.worktree).read_text(encoding="utf-8")
        self.assertIn(self.module.CURSOR_MARKER, text)
        self.assertIn("# Project review sweep cursor", text)

    def test_the_original_stop_before_document_migrates_without_losing_exceptions(self):
        self.module.document_path(self.worktree).write_text(
            "# Project Review Boundaries\n\n"
            "Repository-specific exclusive endpoints.\n\n"
            "- `coghex/kanban` — stop before PR #466 in merge-date order. "
            "PR #471 merged later and was already reviewed, so skip it.\n",
            encoding="utf-8",
        )
        state = self.state()
        self.assertEqual(state["pr"]["endpoint"]["number"], 466)
        self.assertEqual(state["pr"]["reviewed"], [466, 471])
        selection = self.select(count=9)
        self.assertEqual(self.units(selection), [470, 468])
        self.assertTrue(selection["boundary_reached"])

        self.record(selection)
        text = self.module.document_path(self.worktree).read_text(encoding="utf-8")
        self.assertIn(self.module.CURSOR_MARKER, text)
        self.assertEqual(self.state()["pr"]["endpoint"]["merged_at"],
                         "2026-08-17T00:00:00Z")

    def test_a_v1_resume_frontier_migrates_to_coverage_not_a_boundary(self):
        old = {
            "version": self.module.LEGACY_SCHEMA_VERSION,
            "repositories": {
                REPO: {
                    "pr": {
                        "endpoint": {
                            "number": 466,
                            "merged_at": "2026-08-17T00:00:00Z",
                        },
                        "reviewed": [468, 470, 471],
                    },
                    "direct": {"endpoint": None, "reviewed": []},
                    "excluded": {"prs": [], "commits": []},
                }
            },
        }
        self.module.document_path(self.worktree).write_text(
            "# Project review sweep cursor\n\n"
            f"{self.module.LEGACY_CURSOR_MARKER}\n\n"
            f"```json\n{json.dumps(old)}\n```\n",
            encoding="utf-8",
        )

        migrated = self.module.load_document(self.worktree)
        state = self.module.state_for(migrated, REPO)
        self.assertEqual(migrated["version"], self.module.SCHEMA_VERSION)
        self.assertIsNone(state["pr"]["endpoint"])
        self.assertEqual(state["pr"]["reviewed"], [466, 468, 470, 471])
        self.assertEqual(self.units(self.select(count=3)), [465, 464, 463])

        self.record(self.select(count=3))
        text = self.module.document_path(self.worktree).read_text(encoding="utf-8")
        self.assertIn(self.module.CURSOR_MARKER, text)
        self.assertNotIn(self.module.LEGACY_CURSOR_MARKER, text)

    def test_an_unparseable_document_stops_the_run(self):
        for spelling, body in (
            ("no marker", "# Project review sweep cursor\n\nnothing here.\n"),
            (
                "unreadable json",
                f"{self.module.CURSOR_MARKER}\n\n```json\n{{not json}}\n```\n",
            ),
            (
                "wrong schema version",
                f'{self.module.CURSOR_MARKER}\n\n```json\n{{"version": 99}}\n```\n',
            ),
            (
                "a reviewed entry that is not a pull request",
                f'{self.module.CURSOR_MARKER}\n\n```json\n'
                f'{{"version": {self.module.SCHEMA_VERSION}, "repositories": {{"o/r": {{"pr": '
                '{"reviewed": ["nope"]}}}}\n```\n',
            ),
        ):
            with self.subTest(spelling=spelling):
                self.module.document_path(self.worktree).write_text(body, encoding="utf-8")
                with self.assertRaises(self.module.CursorError):
                    self.module.load_document(self.worktree)

    def test_the_document_is_written_where_the_workflow_resolved_it(self):
        self.record(self.select(count=3))
        self.assertEqual(
            self.module.document_path(self.worktree),
            self.worktree / "docs" / "project_review_boundaries.md",
        )
        self.assertEqual(
            self.module.DOCUMENT_RELATIVE_PATH, "docs/project_review_boundaries.md"
        )


class CursorRecordTests(CursorTransitionCase):
    """The review's fifth spec addition: how a completed batch is folded in."""

    def test_the_pr_boundary_never_moves_without_an_explicit_request(self):
        self.record([], boundary=464)
        self.assertEqual(self.state()["pr"]["endpoint"]["number"], 464)
        self.record(self.select(count=2))
        self.assertEqual(self.state()["pr"]["endpoint"]["number"], 464)

        self.record([], boundary=461)
        self.assertEqual(self.state()["pr"]["endpoint"]["number"], 461)

    def test_recording_preserves_an_earlier_exclusion(self):
        self.record(self.select(count=2), exclude=[471])
        self.record(self.select(count=2), exclude=[464])
        self.assertEqual(self.state()["excluded"]["prs"], [464, 471])

    def test_a_reviewed_unit_absent_from_the_candidate_history_is_refused(self):
        with self.assertRaises(self.module.CursorError) as caught:
            self.module.record(
                self.state(),
                "pr",
                self.module.normalize_candidates("pr", PR_LISTING),
                [9999],
            )
        self.assertIn("absent from the candidate history", str(caught.exception))

    def test_a_completed_batch_records_at_least_one_unit(self):
        with self.assertRaises(self.module.CursorError):
            self.module.record(
                self.state(),
                "pr",
                self.module.normalize_candidates("pr", PR_LISTING),
                [],
            )


class CursorCommandLineTests(CursorTransitionCase):
    """The surface the rendered assets actually invoke."""

    def test_select_and_record_round_trip_through_the_command_line(self):
        listing = self.worktree / "listing.json"
        listing.write_text(json.dumps(PR_LISTING), encoding="utf-8")
        first = self.run_cli(
            "select", "--mode", "pr", "--count", "3", "--candidates", str(listing)
        )
        self.assertEqual([entry["number"] for entry in first["selected"]], [470, 468, 471])

        self.run_cli(
            "record",
            "--mode",
            "pr",
            "--candidates",
            str(listing),
            "--reviewed",
            "470,468,471",
        )
        second = self.run_cli(
            "select", "--mode", "pr", "--count", "3", "--candidates", str(listing)
        )
        self.assertEqual([entry["number"] for entry in second["selected"]], [466, 465, 464])
        state = self.run_cli("read")["state"]["pr"]
        self.assertIsNone(state["endpoint"])
        self.assertEqual(state["reviewed"], [468, 470, 471])

    def test_a_range_bound_holds_through_the_command_line(self):
        # The surface the asset invokes, since that is where `--end` is spelled
        # and where an empty one has to mean no bound at all.
        listing = self.worktree / "listing.json"
        listing.write_text(json.dumps(PR_LISTING), encoding="utf-8")
        bounded = self.run_cli(
            "select", "--mode", "pr", "--count", "9",
            "--candidates", str(listing), "--start", "470", "--end", "466",
        )
        self.assertEqual(
            [entry["number"] for entry in bounded["selected"]], [470, 468, 471, 466]
        )
        self.assertTrue(bounded["bounded"])

        # Empty flags are the ordinary case, and must not bound anything.
        unbounded = self.run_cli(
            "select", "--mode", "pr", "--count", "9",
            "--candidates", str(listing), "--start", "", "--end", "",
        )
        self.assertEqual(len(unbounded["selected"]), len(PR_HISTORY))
        self.assertFalse(unbounded["bounded"])

    def test_a_direct_candidate_listing_may_be_the_plain_sha_walk(self):
        # `git log --first-parent --format=%H` prints one SHA per line, which
        # is what the asset pipes in, so the helper reads that shape without a
        # transformation step of its own.
        walk = self.worktree / "walk.txt"
        walk.write_text("\n".join(DIRECT_HISTORY) + "\n", encoding="utf-8")
        selection = self.run_cli(
            "select", "--mode", "direct", "--count", "2", "--candidates", str(walk)
        )
        self.assertEqual(
            [entry["sha"] for entry in selection["selected"]], list(DIRECT_HISTORY[:2])
        )

    def test_the_first_direct_batch_starts_at_the_supplied_entry_point(self):
        # Round 3's other blocker: the shown invocation had no `--start`, so
        # the first direct batch of a repository that did have PR history
        # began at index 0 and re-reviewed PR-owned commits. Direct state is
        # empty at that moment, so nothing else could position it.
        walk = self.worktree / "walk.txt"
        walk.write_text("\n".join(DIRECT_HISTORY) + "\n", encoding="utf-8")
        first = self.run_cli(
            "select",
            "--mode",
            "direct",
            "--count",
            "2",
            "--candidates",
            str(walk),
            "--start",
            DIRECT_HISTORY[3],
        )
        self.assertEqual(
            [entry["sha"] for entry in first["selected"]], list(DIRECT_HISTORY[3:5])
        )
        self.assertEqual(first["origin"], "explicit-start")

        # Recorded, the next batch positions itself and needs no entry point --
        # which is why the same invocation passes an empty one from then on.
        self.run_cli(
            "record",
            "--mode",
            "direct",
            "--candidates",
            str(walk),
            "--reviewed",
            ",".join(DIRECT_HISTORY[3:5]),
        )
        later = self.run_cli(
            "select",
            "--mode",
            "direct",
            "--count",
            "2",
            "--candidates",
            str(walk),
            "--start",
            "",
        )
        self.assertEqual(
            [entry["sha"] for entry in later["selected"]], list(DIRECT_HISTORY[5:7])
        )
        self.assertEqual(later["origin"], "recorded-endpoint")

        # An empty entry point on the *first* batch is the defect itself: with
        # no state to position it, the walk restarts at HEAD.
        self.forget_the_cursor()
        restarted = self.run_cli(
            "select",
            "--mode",
            "direct",
            "--count",
            "2",
            "--candidates",
            str(walk),
            "--start",
            "",
        )
        self.assertEqual(restarted["origin"], "history-head")
        self.assertEqual(
            [entry["sha"] for entry in restarted["selected"]], list(DIRECT_HISTORY[:2])
        )



if __name__ == "__main__":
    unittest.main()
