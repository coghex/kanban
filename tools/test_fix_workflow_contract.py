"""Behavioral contract coverage for the packaged fix workflow.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

`tools/test_claude_plugin.py` and `tools/test_codex_plugin.py` pin that both
plugins *discover* a `fix` workflow and that it sits outside the Haskell
name-parity set: it is a user-invoked workflow, started by neither the board
nor the issue-to-pull-request set. Discovery and name parity are not the contract, though: `fix`
is user-invoked, so nothing upstream establishes the approval, the origin
brand, or the obstacle it acts on — the packaged text is the only place those
decisions are made, and it is the part that must not drift.

Both assets are rendered from one source by
`tools/render_command_sources.py`, so the two brands cannot diverge by an
unsynchronised hand edit. They can still diverge from their *contract* through
an edit to that single source, which is what this module measures. It asserts
against BOTH rendered outputs rather than the source, because the rendered
files are what an agent actually executes, and because a phrase that survives
rendering is one that survived sigil substitution and brand-block projection.

Four groups of requirement are checked as text the workflow states in terms an
agent will act on: the approval and origin-brand preconditions that bound what
it may touch at all, the head binding that turns those mutable approval signals
into authority over one specific commit, the ordered obstacle branches and
which of them mutate anything, and the push/rereview authority boundary -- specifically that a push
invalidates the approval and therefore always invokes exactly one rereview,
while every non-mutating branch invokes none.

`RevisionDelegationTests` is the negative control this module owes under
CLAUDE.md's "Quality gates": the fix-specific rules are asserted absent from the
pr-revise pair, so a phrase table that had degenerated into fragments present in
every packaged workflow would fail here rather than pass everywhere.
"""

from __future__ import annotations

import importlib.util
import inspect
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import fake_cli

REPO_ROOT = Path(__file__).resolve().parent.parent

FIX_SOURCE = REPO_ROOT / "tools/command_sources/fix.md"
CODEX_FIX = REPO_ROOT / "codex-plugin/plugins/kanban/skills/fix/SKILL.md"
CLAUDE_FIX = REPO_ROOT / "claude-plugin/plugins/kanban/commands/fix.md"

FIX_ASSETS = (CODEX_FIX, CLAUDE_FIX)

CODEX_REVISE = REPO_ROOT / "codex-plugin/plugins/kanban/skills/pr-revise/SKILL.md"
CLAUDE_REVISE = REPO_ROOT / "claude-plugin/plugins/kanban/commands/pr-revise.md"

REVISE_ASSETS = (CODEX_REVISE, CLAUDE_REVISE)

WORKFLOW_HS = REPO_ROOT / "src/Kanban/Workflow.hs"
DRAINER = REPO_ROOT / "tools/drain_prs.py"
FINALIZE_SOURCE = REPO_ROOT / "tools/command_sources/finalize.md"

COORDINATORS = (
    REPO_ROOT / "codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py",
    REPO_ROOT / "claude-plugin/plugins/kanban/scripts/review_pr.py",
)

# Every shell variable the assets point a redirect at. The hygiene rules below
# are asserted over this tuple rather than over one hard-coded name, because a
# rule naming only the first scratch file would leave a later one unmeasured.
# The head-binding evidence fences once added two; the bundled approval helper
# reads those feeds in its own process now, so the check rollup is the only
# scratch file the assets still write.
SCRATCH_VARIABLES = ("ROLLUP",)

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
FRONTMATTER_KEY_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*):", re.MULTILINE)

# The same override surface both plugin modules forbid, restated here so a fix
# asset is held to it whichever bundle it lives in.
FORBIDDEN_FRONTMATTER_KEYS = {
    "model",
    "models",
    "effort",
    "reasoning_effort",
    "reasoningeffort",
    "sandbox",
    "approval",
    "approvalpolicy",
    "approval_policy",
    "permission-mode",
    "permissionmode",
    "cwd",
    "workingdirectory",
    "working_directory",
}

FORBIDDEN_PATH_FRAGMENTS = (
    "/Users/",
    "/home/",
    "C:\\Users",
)

# Every phrase below is asserted against both rendered assets. None may contain
# a workflow reference: those are authored as `{{cmd:}}` tokens and render to a
# different sigil per brand, so a phrase carrying one could never match both.
REQUIRED_PHRASES = {
    # --- The trigger: a diagnostic question authorises nothing. ---
    "the-worktree-step-serves-only-head-moving-branches": (
        'This step applies only when step 3 concluded that the head must move — a merge\nconflict, a base the head is behind, or a check failure to fix. Every other\nbranch of step 3 mutates nothing and needs no worktree at all.'
    ),
    "a-diagnosis-is-not-authorisation": (
        "**A diagnosis is not authorisation.** This workflow commits, pushes, "
        "and hands off a rereview, so it runs only when the user asked in that "
        "turn for the pull request to be fixed, unblocked, or made mergeable."
    ),
    "a-why-question-is-answered-without-mutating": (
        '"Why can\'t\nthis merge?" and "what is blocking this?" ask for none of '
        "that: answer them by\nrunning step 2 and step 3, reporting the obstacle "
        "you found, and stopping there\n— no worktree, no push."
    ),
    "an-ambiguous-request-is-read-as-diagnostic": (
        "When a request could be read either way, treat it\nas diagnostic and "
        "ask, because the diagnostic reading is the one whose mistake\ncosts "
        "nothing."
    ),

    # --- The origin gate: this brand may only fix its own brand's work. ---
    "the-origin-marker-is-validated-before-any-mutation": (
        "This workflow is user-invoked: the user chose which brand's session "
        "runs it,\nand nothing upstream has checked that the choice matches the "
        "pull request, so it\nchecks here, before any mutation."
    ),
    "the-origin-rules-are-the-coordinators": (
        "apply exactly the\nrules `origin_from_body` applies in the bundled "
        "coordinator's `review_pr.py`:\nthe body must carry exactly ONE "
        "marker, of exactly one kind, as its final\nnon-whitespace content."
    ),
    "every-malformed-origin-is-a-refusal-not-a-default": (
        "Both markers present, the same marker twice, a marker with trailing\n"
        "text after it, and no marker at all are each a refusal — not a default."
    ),
    "a-wrong-brand-origin-stops-with-nothing-changed": (
        "**A missing, malformed, or opposite-brand marker stops the run with "
        "nothing\nchanged.**"
    ),
    "why-the-origin-gate-exists": (
        "the coordinator routes the rereview from\nthat same marker, so "
        "editing a pull request whose origin names the OTHER brand\nwould have "
        "this session author a change and then hand it to its own brand to\n"
        "review"
    ),
    "the-pull-request-body-is-fetched": (
        "--json number,body,baseRefName"
    ),

    # --- The approval precondition, and what it bounds. ---
    "approval-is-required-before-diagnosis": (
        "This workflow acts only on an approved pull request."
    ),
    "approval-is-configured-not-a-fixed-string": (
        "Approval is whatever the effective configuration says it is, never a fixed\n"
        "string and never the label alone: take the configured `approval_label` "
        "(default\n`reviewed:approve`) and `approval_mode` (default `label`) from the "
        "same\nconfiguration the caller supplied"
    ),
    "approval-config-is-per-repository-overridable": (
        "the global `[workflow]` table, overridden\nper repository by "
        '`[repositories."<owner>/<name>".workflow]`'
    ),
    "approval-modes-are-read-never-accepted-on-their-own": (
        "Honour the configured mode: `label` reads the\n"
        "configured approval label, `review` reads GitHub's own `reviewDecision ==\n"
        "APPROVED`, and `either` reads both."
    ),
    "an-unbound-signal-is-never-sufficient": (
        "**None of those signals is approval on its own.** Each is necessary "
        "and none is\nsufficient: a label and a `reviewDecision` are mutable "
        "metadata that name no\ncommit, so neither can say which head a "
        "reviewer accepted."
    ),
    # A verdict label is a decision already taken, so 2b stops on it without
    # reading any further evidence. The absence of a raw approval signal is
    # not that: it is the question 2c answers, and stopping on it here is what
    # sent a stale-approval dismissal to a first review (see the pair below).
    "a-blocking-or-changes-requested-label-stops-having-changed-nothing": (
        "Stop, having changed nothing, when the pull request carries a configured\n"
        "changes-requested or blocking label"
    ),
    "that-label-stop-needs-no-further-evidence": (
        "that stop needs no further evidence,\nsince the label itself is a "
        "human's decision to reverse."
    ),
    "a-blocking-label-is-never-removed-to-proceed": (
        "Never remove a blocking label to proceed."
    ),
    # The defect these rules pin, observed live: review-gate dismissed a stale
    # approval, and 2b could not tell the stripped label apart from a pull
    # request nobody had ever reviewed, so both were sent to a first review.
    "a-missing-raw-approval-signal-is-not-a-stop-at-2b": (
        "A pull request that simply lacks the resolved mode's raw approval signal — no\n"
        "configured label attached, no `reviewDecision == APPROVED` — is not a stop\n"
        "here."
    ),
    "a-stripped-label-and-a-superseded-marker-both-mean-reviewed-before": (
        "A label a legitimate stale-approval dismissal just stripped,\n"
        "and a marker bound to a head this pull request has since moved past, both mean\n"
        "it HAS been reviewed before; only a feed with no marker at all means it has\n"
        "not."
    ),
    "the-remedy-turns-on-the-marker-not-the-surviving-label": (
        "regardless of which\n"
        "head it named, whether a later marker superseded it, or whether the configured\n"
        "label is currently attached"
    ),
    # --- The head binding: a mutable signal is not authority over a commit. ---
    "head-bound-approval-is-required-before-anything-mutates": (
        "**An approval that cannot be bound to the current `headRefOid` is "
        "not an\napproval here.** Establish the binding before step 3 "
        "diagnoses anything. A pull\nrequest whose current head does not "
        "carry head-bound approval gets no worktree,\nno repair, no commit, "
        "no push, and no rereview handoff: the run stops having\nchanged "
        "nothing, exactly as it does for a pull request that was never "
        "approved."
    ),
    "why-an-unbound-approval-is-authority-over-unreviewed-code": (
        "a third party can add a commit while every one of them still reads "
        "green\nover code nobody reviewed. Left there, this workflow would "
        "take that unreviewed\nhead as its authority to create a worktree, "
        "edit it, and push another commit on\ntop of it."
    ),
    "the-drainer-already-keys-on-the-approved-head": (
        "`tools/drain_prs.py` records the approved head with no default — "
        "inventing one\nwould let an unreviewed head through — and refuses "
        "with `approved_head_changed`\nwhen the approval label is attached "
        "to a head that is not the approved one."
    ),
    "carrying-the-approval-forward-is-not-available-here": (
        "Carrying the approval forward instead is not available here: the "
        "drainer's\ncontent-safe carry answers for a branch update the "
        "drainer itself performed and\nobserved, while this workflow faces "
        "an arbitrary third-party push whose\ncontents it can establish "
        "nothing about."
    ),
    "the-two-evidence-paths-are-weighed-independently": (
        "`label` requires the canonical-marker evidence, `review` requires the "
        "native-approval evidence, and `either` is met by whichever of the two "
        "holds — one path failing never vetoes valid evidence from the other."
    ),
    "the-success-test-is-exit-approved-and-recorded-head": (
        "**The success test is all three of these, and nothing weaker.** The "
        "helper must exit 0, its `approved` must be exactly `true`, and its "
        "`head` must equal `RECORDED_HEAD`."
    ),
    "a-refusal-object-is-never-success": (
        "Nonempty output, a refusal object, missing or malformed output, a "
        "nonzero status, and an approval evaluated at any other head are each "
        "a refusal"
    ),
    "the-recorded-head-is-the-approved-head": (
        "Record the `headRefOid` that read returned as `RECORDED_HEAD`. It is "
        "the head this run diagnoses and edits"
    ),
    "the-pre-push-guard-runs-only-behind-the-initial-one": (
        "it can run only behind the initial guard"
    ),
    "the-push-is-reachable-only-through-the-fresh-guard": (
        "The push is reachable only through the fresh guard above"
    ),
    "a-single-path-failure-does-not-veto-the-other-path": (
        "Under `either`, a read or parse failure confined to one evidence path "
        "is that path's unmet outcome and does not veto the other"
    ),
    "the-remedy-is-chosen-from-the-marker-history": (
        "This workflow chooses the command, not the helper"
    ),
    "problem-labels-refuse-under-every-mode": (
        "The\nconfigured changes-requested and blocking labels remain "
        "unconditional refusals\nunder every mode and are weighed against "
        "neither path."
    ),
    "an-unresolved-publisher-fails-closed": (
        "The helper resolves the authenticated login before it reads any "
        "evidence and refuses when it cannot: an unresolved login makes every "
        "ownership test vacuously true."
    ),
    "the-whole-paginated-comment-feed-is-read": (
        "chosen from the COMPLETE paginated feed by creation time with the "
        "comment id breaking ties"
    ),
    "the-marker-is-selected-by-recency-before-it-is-tested": (
        "The helper reads the complete feed because a bounded view can leave "
        "the newest marker outside it, and an older verdict would then speak "
        "for a head nobody reviewed; it selects the newest comment BEFORE it "
        "tests what that comment says, and it accepts the established v2 "
        "shape and the legacy v1 shape."
    ),
    "the-label-path-needs-a-current-head-approve-marker": (
        "the path is met only when that label is attached AND the newest "
        "marker the authenticated publisher wrote"
    ),
    "missing-or-malformed-evidence-never-falls-back": (
        "Missing evidence, an unreadable feed, and a malformed or "
        "multiply-markered newest comment each leave the path unmet rather "
        "than falling back to an older approval, and so does a newer "
        "non-approval over an older approval."
    ),
    "the-aggregate-review-decision-is-necessary-not-sufficient": (
        "`reviewDecision == APPROVED` stays necessary and stops being "
        "sufficient: it is\nan aggregate over the pull request, not a "
        "statement about a commit."
    ),
    "the-effective-review-per-author-is-the-native-evidence": (
        "one author's newest opinionated review (`APPROVED` or "
        "`CHANGES_REQUESTED`, by `submitted_at` with the review id breaking "
        "ties)"
    ),
    "the-review-path-needs-an-approval-naming-the-current-commit": (
        "is an `APPROVED` whose `commit_id` equals the current head."
    ),
    "stale-or-unattributed-native-approval-is-insufficient": (
        "A dismissed, superseded, stale or unattributed approval is "
        "insufficient."
    ),
    "the-refusal-names-both-heads-or-says-there-is-none": (
        "the `head` it evaluated, the `approval_head` the evidence names — or, "
        "when that is null, that the evidence is missing or unreadable rather "
        "than naming any head at all"
    ),
    "the-review-path-is-not-cleared-by-a-canonical-review": (
        "A `review` path left unmet is NOT\ncleared that way: the canonical "
        "coordinator publishes a comment and switches\nverdict labels, and "
        "publishes no native GitHub approval at all, so that path is\n"
        "cleared only by a reviewer approving the current head on GitHub "
        "itself."
    ),
    "neither-a-label-nor-a-review-is-manufactured": (
        "**This workflow manufactures neither.** It synthesizes no verdict "
        "label, and it\ninvokes no review of its own to produce the approval "
        "it is missing. Verdict\nlabels change only as a consequence of the "
        "one canonical rereview step 6 hands\noff to after a real push, "
        "which a run stopping here never reaches."
    ),
    "the-head-binding-is-re-established-before-the-push": (
        "IMMEDIATELY before the push, run the approval helper again. It "
        "re-reads the pull request, the authenticated publisher, and the "
        "evidence itself"
    ),
    "a-cached-initial-reading-cannot-answer-for-the-push": (
        "so nothing cached from step 2c can answer for this moment: a "
        "canonical verdict can be superseded and a native approval dismissed "
        "while the head never moves"
    ),
    "a-pre-push-stop-preserves-the-worktree": (
        "Leave the worktree's existing work exactly as it is: a\nstop here "
        "is a loss of authority to publish, not a reason to discard what "
        "was\nbuilt."
    ),

    # --- A pull request behind its base is unmergeable, not clear. ---
    "the-conflict-branch-precedes-the-rollup-test": (
        "1. **Merge conflict** — resolve it against the recorded "
        "`baseRefName`,\n   preserving the pull request's intent while "
        "incorporating that base branch's\n   current tip. This branch reads "
        "no check state, which is why it precedes the\n   rollup test below."
    ),
    "the-scratch-file-lives-outside-the-checkout": (
        "Argument-free `mktemp` is portable across BSD/macOS and GNU/Linux, "
        "and puts that file OUTSIDE the checkout; the `rm` is not optional."
    ),
    "nothing-may-be-left-in-the-working-tree": (
        "Nothing this workflow does may leave a file in the working tree"
    ),
    "a-rollup-entry-is-not-a-check": (
        "**A rollup entry is not the same thing as a CHECK.** GitHub returns "
        "every context on the commit, including ones a later run superseded, "
        "so the same check can appear twice — an old failure beside the "
        "passing rerun that replaced it."
    ),
    "the-decoders-dedup-key-and-recency-rule-are-restated": (
        "`src/Kanban/GitHub/Decode.hs` keys each context "
        "(`check:<app-slug>:<name>` for a `CheckRun`, "
        "`status:<creator-login>:<context>` for a `StatusContext`), keeps only "
        "the most recent context per key (`startedAt` falling back to "
        "`completedAt` for a check run, `createdAt` for a status), and reads "
        "the verdict off THAT set alone."
    ),
    "a-superseded-failure-is-a-real-state-here": (
        "since the PR drainer reruns required checks on its own schedule, a "
        "superseded failure is a state this repository actually produces, not "
        "a hypothetical."
    ),
    "an-undedupable-entry-fails-closed": (
        "**If any entry lacks the fields that rule needs** — no `__typename` "
        "you recognise, no key, or no timestamp on a context that shares a key "
        "with another — the rollup falls to branch 2 and the run stops."
    ),
    "the-branches-read-the-deduplicated-set": (
        "3. **Failed check** — EVERY failed check in the DEDUPLICATED set "
        "above,"
    ),
    "an-untrustworthy-rollup-is-its-own-branch": (
        "2. **A rollup you cannot trust** — before any branch below draws a "
        "conclusion\n   from the rollup, that rollup must be COMPLETE."
    ),
    "a-null-rollup-is-trusted-checks-none": (
        "when `statusCheckRollup` itself is `null` or absent, treat it as "
        "`ChecksNone`, exactly as `parseChecks` does in "
        "`src/Kanban/GitHub/Decode.hs`"
    ),
    "a-null-rollup-continues-as-no-checks": (
        "There is no `contexts` object to compare in that shape because GitHub "
        "is reporting NO checks; continue through the later branches with no "
        "failed or pending checks."
    ),
    "a-malformed-present-rollup-still-fails-closed": (
        "Do not confuse that with a PRESENT, non-null rollup whose `contexts`, "
        "`totalCount`, or nodes cannot be read — that still fails closed."
    ),
    "a-failed-check-is-fixed-not-retried": (
        "3. **Failed check** — EVERY failed check in the DEDUPLICATED set "
        "above, required or not, not only required checks, and not only the "
        "first one you notice. Fix the causes in the worktree of step 4, push, "
        "and hand off the rereview of step 6."
    ),
    "never-retry-a-failure-instead-of-fixing-it": (
        "Never\n   delete or skip a test, never weaken an assertion, and never "
        "retry a failure\n   instead of fixing it — see step 5, which forbids "
        "that outright."
    ),
    "completeness-is-established-by-the-same-comparison-kanban-makes": (
        "Compare the `totalCount` the query above returned against the number "
        "of nodes it returned beside it. They must be equal — the same "
        "comparison `src/Kanban/GitHub/Decode.hs` makes before it decodes a "
        "single context."
    ),
    "an-untrustworthy-rollup-fails-closed": (
        "**A truncated rollup, or any entry you cannot classify, fails "
        "closed:** report that the check state cannot be read completely and "
        "stop without pushing or invoking a rereview."
    ),
    "why-an-incomplete-rollup-is-not-an-absence": (
        "An incomplete rollup can be\n   hiding exactly the failed or pending "
        "entry the branches below test for, so\n   treating it as absence "
        'would turn "I did not see one" into "there is none".'
    ),
    "a-pending-check-mutates-nothing": (
        "4. **A check still running** — no conflict, a rollup you can trust, "
        "no failed check, and a pending one in that same deduplicated set. "
        "This branch MUTATES NOTHING."
    ),
    "the-workflow-never-retries-a-check": (
        "This workflow does not retry a red check, ever. A failed check is "
        "fixed or it\nis reported; there is no third option and no "
        "circumstance — however plainly\ninfrastructural the failure looks — "
        "under which this workflow reruns one."
    ),
    "retrying-belongs-to-the-drainer": (
        "That is a deliberate boundary, not an oversight. `tools/drain_prs.py` "
        "already\nreruns a failed required check on an approved pull request, "
        "keyed to the\napproved head, with a duplicate-request barrier and a "
        "quarantine once its\n`MAX_CI_RERUN_ATTEMPTS` allowance is spent."
    ),
    "two-rerunners-would-disagree": (
        "a second rerunner\nwith its own ceiling would mean two components "
        "disagreeing about the same\npull request."
    ),
    "no-rerun-command-no-loop-no-just-once": (
        'So: no `gh run rerun`, no "just once to see", and no retry loop.'
    ),
    "a-believed-flaky-failure-is-reported-not-retried": (
        "A failure you\nbelieve is flaky is still a failure this workflow "
        "reports rather than retries"
    ),
    "pending-outranks-behind-as-it-does-in-the-haskell": (
        "`pullRequestStatus` ranks it this way\n   too — `checksPending` is "
        "guarded BEFORE the merge-state test"
    ),
    "why-pending-outranks-behind": (
        "replacing the approved head\n   while CI is still running discards "
        "the very run that would have told you\n   whether there was anything "
        "to fix, and starts the whole thing again on a\n   head nobody has "
        "reviewed."
    ),
    "behind-the-base-is-its-own-obstacle": (
        "5. **Behind its base** — no conflict, no failed check, no pending "
        "check, and\n   the merge state is exactly `BEHIND`"
    ),
    "only-behind-is-fixable-by-a-branch-update": (
        "6. **Any other merge state that is not ready** — `BLOCKED` and "
        "`UNSTABLE` are\n   real states (`MergeBlocked`, `MergeUnstable`)"
    ),
    "blocked-and-unstable-fail-closed": (
        "This branch fails closed: report the exact merge state, say that this "
        "workflow has no remedy for it, and stop without pushing or invoking a "
        "rereview."
    ),
    "only-clean-and-protected-are-ready": (
        "Only `MergeClean` and `MergeProtected`\n   are ready "
        "(`mergeStateReady`); everything else that is not `BEHIND` lands\n   "
        "here."
    ),
    "green-checks-do-not-make-a-behind-pr-mergeable": (
        "Green checks do not make\n   such a pull request mergeable. Update it "
        "from the recorded `baseRefName`\n   through step 4, exactly as the "
        "conflict branch does"
    ),
    "nothing-to-fix-requires-a-ready-merge-state": (
        "7. **Nothing to fix** — no conflict, no failed check, no pending "
        "check, and a\n   merge state that is ready."
    ),
    "an-unknown-merge-state-is-not-a-clearance": (
        "`UNKNOWN` is not a clearance either — GitHub has not\n   finished "
        "computing mergeability, so it lands in branch 6 and stops rather\n   "
        "than being reported ready when it may yet come back `BEHIND` or "
        "`DIRTY`."
    ),

    # --- The retry prohibition. ---
    "a-real-failure-is-never-papered-over": (
        "Never\n   delete or skip a test, never weaken an assertion"
    ),
    "a-pre-existing-failure-stops-the-run": (
        "A failure\n   you judge to be pre-existing on the recorded base "
        "branch is reported to the\n   user and stops the run rather than "
        "being papered over."
    ),
    # --- The ceiling. ---
    # --- Authority: what a push does and does not invalidate. ---
    "a-push-invalidates-the-approval": (
        "Do not assume\nthe pull request is still approved after you push — it is "
        "not, because the\napproval named the SHA you replaced."
    ),
    "exactly-one-rereview-after-a-push": (
        "When you pushed a new head, finish by invoking exactly one canonical rereview"
    ),
    "no-push-means-no-rereview": (
        "When you pushed nothing — any of step 3's non-mutating branches, or a "
        "stop in step 2, 2b, or 2c — there is no new head, so invoke no "
        "rereview and simply report what you found."
    ),
    "never-merges-and-never-closes": (
        "Never merge the pull request, and never close an issue or pull request."
    ),
    "never-mutates-a-verdict-label-directly": (
        "Never add or remove a verdict label directly."
    ),
    "never-compensates-for-an-unavailable-rereview": (
        "Never compensate by\nsetting a label yourself."
    ),
    "does-not-self-review-the-rereview": "Do not pass `--self-review`",
    "ambiguity-goes-to-the-user": (
        "ask the user through the session's question mechanism\nrather than choosing"
    ),
    # --- Head safety. ---
    "a-local-ahead-reused-worktree-stops-the-run": (
        "**But a reused worktree whose HEAD is not the recorded head stops the "
        "run.** Uncommitted work is safe to keep — it reaches the remote only "
        "if you commit it, and the focused commit stages only what you changed. "
        "COMMITTED work is not:"
    ),
    "why-a-local-ahead-push-breaks-the-one-commit-limit": (
        "A push from there is an ordinary fast-forward that publishes every one "
        "of them alongside your fix — no force, no warning, and no way for the "
        '"at most one focused commit" limit to hold.'
    ),
    "publishing-someone-elses-commits-is-not-this-workflows-call": (
        "Those commits are somebody's interrupted work, they have never been "
        "reviewed, and deciding to publish them is not this workflow's call."
    ),
    "cross-repository-heads-are-fail-closed": (
        "A cross-repository pull request is fail-closed."
    ),
    "writability-is-decided-by-the-push-not-maintainer-can-modify": (
        "Decide whether that push is possible from the head repository itself, never "
        "from\n`maintainerCanModify`"
    ),
    "reverifies-the-head-before-a-non-force-push": (
        "Before pushing, re-fetch the pull request branch from the recorded head\n"
        "repository and verify its remote head still equals the recorded SHA."
    ),
    "revalidates-mutable-authority-immediately-before-push": (
        "After that head check and IMMEDIATELY before the push, run the "
        "approval helper again."
    ),
    "reapplies-approval-problem-label-and-origin-gates": (
        "The helper repeats every check of step 2b and step 2c against what it "
        "reads now: the configured approval decision, the changes-requested "
        "and blocking labels, the complete origin-marker parse including that "
        "it still names THIS bundle's active brand, and the selected mode's "
        "head-bound evidence"
    ),
    "lost-pre-push-authority-stops-without-pushing": (
        "If approval was withdrawn, the selected mode's head-bound evidence no "
        "longer holds, any configured problem label appeared, the origin "
        "became missing, malformed, or a different brand, or the head no "
        "longer matches, STOP with no push and no rereview, and leave "
        "`PUSH_APPROVED_HEAD` empty."
    ),
    "an-unchanged-head-does-not-prove-authority": (
        "A pull request's body, labels, `reviewDecision`, canonical marker, and "
        "native reviews can all change without moving its head SHA; the "
        "workflow's authority can therefore disappear while the branch itself "
        "still looks unchanged."
    ),
    "verifies-the-push-actually-advanced-the-head": (
        "a push that left the head unchanged\ntransferred no fix, so treat it as "
        "having pushed nothing, invoke no rereview,\nand report it."
    ),
    "never-switches-the-primary-checkout": (
        "Never switch the repository's primary checkout."
    ),
}

# The obstacle branches, in the order the workflow must address them.
DIAGNOSIS_ORDER = (
    "**Merge conflict**",
    "**A rollup you cannot trust**",
    "**Failed check**",
    "**A check still running**",
    "**Behind its base**",
    "**Any other merge state that is not ready**",
    "**Nothing to fix**",
)

# Requirements that belong to fix alone. The pr-revise pair must carry none of
# them, which is what proves the table above is measuring this workflow rather
# than matching text every packaged workflow happens to contain. The origin
# rules `pr-revise` shares with fix (`ORIGIN_GUARD_RULES`) are deliberately NOT
# in it: `ReviseOriginGuardTests` asserts them present in both and absent from
# the workflows that delegate the origin decision.
FIX_ONLY_REQUIREMENTS = (
    "an-untrustworthy-rollup-is-its-own-branch",
    "the-branches-read-the-deduplicated-set",
    "an-undedupable-entry-fails-closed",
    "a-superseded-failure-is-a-real-state-here",
    "the-decoders-dedup-key-and-recency-rule-are-restated",
    "the-scratch-file-lives-outside-the-checkout",
    "nothing-may-be-left-in-the-working-tree",
    "a-rollup-entry-is-not-a-check",
    "a-believed-flaky-failure-is-reported-not-retried",
    "no-rerun-command-no-loop-no-just-once",
    "two-rerunners-would-disagree",
    "retrying-belongs-to-the-drainer",
    "the-workflow-never-retries-a-check",
    "never-retry-a-failure-instead-of-fixing-it",
    "a-failed-check-is-fixed-not-retried",
    "the-conflict-branch-precedes-the-rollup-test",
    "an-untrustworthy-rollup-fails-closed",
    "completeness-is-established-by-the-same-comparison-kanban-makes",
    "why-an-incomplete-rollup-is-not-an-absence",
    "a-pending-check-mutates-nothing",
    "pending-outranks-behind-as-it-does-in-the-haskell",
    "why-pending-outranks-behind",
    "behind-the-base-is-its-own-obstacle",
    "only-clean-and-protected-are-ready",
    "blocked-and-unstable-fail-closed",
    "only-behind-is-fixable-by-a-branch-update",
    "green-checks-do-not-make-a-behind-pr-mergeable",
    "nothing-to-fix-requires-a-ready-merge-state",
    "an-unknown-merge-state-is-not-a-clearance",
    "the-origin-marker-is-validated-before-any-mutation",
    "why-the-origin-gate-exists",
    "the-worktree-step-serves-only-head-moving-branches",
    "a-diagnosis-is-not-authorisation",
    "a-why-question-is-answered-without-mutating",
    "an-ambiguous-request-is-read-as-diagnostic",
    "approval-is-required-before-diagnosis",
    "approval-is-configured-not-a-fixed-string",
    "approval-modes-are-read-never-accepted-on-their-own",
    "an-unbound-signal-is-never-sufficient",
    "a-missing-raw-approval-signal-is-not-a-stop-at-2b",
    "a-stripped-label-and-a-superseded-marker-both-mean-reviewed-before",
    "the-remedy-turns-on-the-marker-not-the-surviving-label",
    "head-bound-approval-is-required-before-anything-mutates",
    "why-an-unbound-approval-is-authority-over-unreviewed-code",
    "the-drainer-already-keys-on-the-approved-head",
    "carrying-the-approval-forward-is-not-available-here",
    "the-two-evidence-paths-are-weighed-independently",
    "the-success-test-is-exit-approved-and-recorded-head",
    "a-refusal-object-is-never-success",
    "the-recorded-head-is-the-approved-head",
    "the-pre-push-guard-runs-only-behind-the-initial-one",
    "the-push-is-reachable-only-through-the-fresh-guard",
    "a-single-path-failure-does-not-veto-the-other-path",
    "the-remedy-is-chosen-from-the-marker-history",
    "problem-labels-refuse-under-every-mode",
    "an-unresolved-publisher-fails-closed",
    "the-whole-paginated-comment-feed-is-read",
    "the-marker-is-selected-by-recency-before-it-is-tested",
    "the-label-path-needs-a-current-head-approve-marker",
    "missing-or-malformed-evidence-never-falls-back",
    "the-aggregate-review-decision-is-necessary-not-sufficient",
    "the-effective-review-per-author-is-the-native-evidence",
    "the-review-path-needs-an-approval-naming-the-current-commit",
    "stale-or-unattributed-native-approval-is-insufficient",
    "the-refusal-names-both-heads-or-says-there-is-none",
    "the-review-path-is-not-cleared-by-a-canonical-review",
    "neither-a-label-nor-a-review-is-manufactured",
    "the-head-binding-is-re-established-before-the-push",
    "a-cached-initial-reading-cannot-answer-for-the-push",
    "a-pre-push-stop-preserves-the-worktree",
)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def flat(text: str) -> str:
    """Collapse every run of whitespace to one space.

    The contract these phrases pin is the WORDS, not where the renderer
    happened to wrap them. Comparing raw text made every unrelated edit that
    reflowed a paragraph fail this module for no behavioural reason, which
    trains a reader to fix the assertion rather than read it. Normalising both
    sides keeps the phrases exact in substance and indifferent to layout.
    """
    return " ".join(text.split())


def frontmatter_keys(text: str) -> set[str]:
    match = FRONTMATTER_RE.match(text)
    if match is None:
        return set()
    return {key.lower() for key in FRONTMATTER_KEY_RE.findall(match.group(1))}


class FixAssetPackagingTests(unittest.TestCase):
    def test_the_source_and_both_rendered_assets_exist(self):
        self.assertTrue(FIX_SOURCE.is_file(), f"missing {FIX_SOURCE}")
        for path in FIX_ASSETS:
            self.assertTrue(path.is_file(), f"missing {path}")

    def test_codex_skill_frontmatter_name_matches_its_directory(self):
        text = read(CODEX_FIX)
        match = FRONTMATTER_RE.match(text)
        self.assertIsNotNone(match, "fix SKILL.md must open with a --- frontmatter block")
        name = re.search(r"^name:\s*(\S+)\s*$", match.group(1), re.MULTILINE)
        self.assertIsNotNone(name, "fix SKILL.md frontmatter must declare name:")
        self.assertEqual(name.group(1), CODEX_FIX.parent.name)
        self.assertEqual(name.group(1), "fix")

    def test_claude_command_declares_a_description_and_is_named_fix(self):
        keys = frontmatter_keys(read(CLAUDE_FIX))
        self.assertIn("description", keys)
        self.assertEqual(CLAUDE_FIX.stem, "fix")

    def test_neither_description_triggers_on_a_diagnostic_question(self):
        # The frontmatter description is what a provider matches a user's
        # phrasing against, so an over-broad one invites this workflow into a
        # turn that authorised none of what it does. It must name an explicit
        # request and disclaim the "why can't this merge" reading.
        for path in FIX_ASSETS:
            match = FRONTMATTER_RE.match(read(path))
            self.assertIsNotNone(match, path)
            description = match.group(1)
            self.assertIn("Runs only on an explicit request", description)
            self.assertIn(
                "diagnostic request, not this workflow",
                description,
                f"{path} description must disclaim the diagnostic reading",
            )
            self.assertNotIn(
                "or asks why an approved pull request still cannot merge",
                description,
                f"{path} description re-opens the diagnostic trigger",
            )

    def test_neither_asset_sets_forbidden_configuration(self):
        for path in FIX_ASSETS:
            hits = frontmatter_keys(read(path)) & FORBIDDEN_FRONTMATTER_KEYS
            self.assertEqual(
                hits,
                set(),
                f"{path} must not set model/effort/sandbox/permission/approval/cwd "
                f"configuration: {hits}",
            )

    def test_neither_asset_references_a_personal_absolute_path(self):
        for path in FIX_ASSETS:
            text = read(path)
            for fragment in FORBIDDEN_PATH_FRAGMENTS:
                self.assertNotIn(
                    fragment, text, f"{path} contains forbidden path fragment {fragment!r}"
                )


class FixWorkflowContractTests(unittest.TestCase):
    """Every requirement below is asserted against both rendered assets, so an
    edit to the one source cannot drop a rule from the shipped workflows."""

    def test_both_assets_state_every_required_behavior(self):
        missing = []
        for path in FIX_ASSETS:
            text = read(path)
            flattened = flat(text)
            for requirement, phrase in REQUIRED_PHRASES.items():
                if flat(phrase) not in flattened:
                    missing.append(f"{path.relative_to(REPO_ROOT)}: {requirement}")
        self.assertEqual(missing, [], "\n".join(missing))

    def test_the_required_phrase_table_is_not_vacuous(self):
        # Guards the loop above against a table that was emptied or whose
        # phrases were reduced to trivially-present fragments.
        self.assertGreaterEqual(len(REQUIRED_PHRASES), 25)
        for requirement, phrase in REQUIRED_PHRASES.items():
            self.assertGreaterEqual(len(phrase), 20, requirement)

    def test_obstacle_branches_appear_in_the_declared_order(self):
        for path in FIX_ASSETS:
            text = read(path)
            positions = []
            for marker in DIAGNOSIS_ORDER:
                index = text.find(marker)
                self.assertNotEqual(index, -1, f"{path} does not name {marker}")
                positions.append(index)
            self.assertEqual(
                positions,
                sorted(positions),
                f"{path} lists the obstacle branches out of order {DIAGNOSIS_ORDER}",
            )

    def test_the_branch_order_matches_pull_request_status_precedence(self):
        # Non-vacuous anchor for DIAGNOSIS_ORDER: the order the assets state is
        # the order `pullRequestStatus` actually guards in, so a change to the
        # Haskell precedence fails here rather than leaving the packaged text
        # quietly disagreeing with the board.
        source = read(WORKFLOW_HS)
        start = source.index("pullRequestStatus :: WorkflowConfig")
        end = source.index("blockedStatus :: WorkflowConfig", start)
        body = source[start:end]
        guards = [
            body.index("MergeConflicting"),
            body.index("checksFailed"),
            body.index("checksPending"),
            body.index("mergeStateReady"),
        ]
        self.assertEqual(
            guards,
            sorted(guards),
            "pullRequestStatus no longer guards conflict, failed, pending, "
            "merge-ready in that order; DIAGNOSIS_ORDER must follow it",
        )

    def test_the_approval_helper_named_by_both_assets_really_exists(self):
        # Non-vacuous anchor: the assets tell an agent to match approval the way
        # `approvedPullRequest` does, so a rename in the Haskell fails here
        # instead of leaving the packaged text pointing at nothing.
        source = read(WORKFLOW_HS)
        self.assertIn("approvedPullRequest ::", source)
        for mode in ("ApprovalByLabel", "ApprovalByReview", "ApprovalByEither"):
            self.assertIn(mode, source, f"{WORKFLOW_HS} no longer defines {mode}")
        for path in FIX_ASSETS:
            self.assertIn("`approvedPullRequest`", read(path))

    def test_the_drainer_constant_the_ceiling_is_contrasted_with_exists(self):
        # The assets tell a reader the drainer retries up to its own
        # MAX_CI_RERUN_ATTEMPTS. A rename or removal there must fail here
        # rather than leave the packaged text citing nothing.
        drainer = (REPO_ROOT / "tools/drain_prs.py").read_text(encoding="utf-8")
        self.assertIn("MAX_CI_RERUN_ATTEMPTS = ", drainer)
        for path in FIX_ASSETS:
            self.assertIn("`MAX_CI_RERUN_ATTEMPTS`", read(path))

    def test_the_configured_label_defaults_match_the_tracked_example_config(self):
        # The assets quote `reviewed:approve` and `blocked` as defaults; the
        # tracked example config is where those defaults actually live.
        example = read(REPO_ROOT / "config.toml.example")
        self.assertIn('approval_label = "reviewed:approve"', example)
        self.assertIn('approval_mode = "label"', example)
        self.assertIn('blocked_labels = ["blocked"]', example)


class RollupCompletenessTests(unittest.TestCase):
    """An unreadable rollup is never a clearance.

    Kanban models a truncated or undecodable rollup as `ChecksUnknown`, which
    `checksReady` and `checksPending` both reject -- it is neither ready nor
    pending. A workflow that inferred "no failed entry seen" from a partial
    rollup would turn not-looking into not-there, and would do it right before
    updating a branch or declaring the pull request clear.
    """

    def test_the_unknown_state_the_branch_cites_still_behaves_that_way(self):
        # Non-vacuous anchor: both halves of "never a clearance" must hold in
        # the Haskell, or the branch is citing a rule that no longer exists.
        workflow = read(WORKFLOW_HS)
        self.assertIn("checksReady ChecksNone = True", workflow)
        self.assertIn("checksReady (ChecksPassed _) = True", workflow)
        self.assertIn("checksReady _ = False", workflow)
        self.assertIn("checksPending (ChecksPending _ _ _) = True", workflow)
        self.assertIn("checksPending _ = False", workflow)
        domain = read(REPO_ROOT / "src/Kanban/Domain.hs")
        self.assertIn("ChecksUnknown", domain)

    def test_the_decoder_still_produces_it_for_both_causes(self):
        decode = read(REPO_ROOT / "src/Kanban/GitHub/Decode.hs")
        self.assertIn("then pure (ChecksUnknown, [])", decode)
        self.assertIn("Left _ -> pure (ChecksUnknown, [ChecksUndecodable])", decode)

    def test_the_decoder_maps_an_absent_or_null_rollup_to_checks_none(self):
        decode = read(REPO_ROOT / "src/Kanban/GitHub/Decode.hs")
        self.assertIn('rollup <- object .:? "statusCheckRollup"', decode)
        self.assertIn("Nothing -> pure (ChecksNone, [])", decode)

    def test_both_assets_distinguish_null_from_a_malformed_present_rollup(self):
        for path in FIX_ASSETS:
            text = flat(read(path))
            self.assertIn(
                "statusCheckRollup` itself is `null` or absent, treat it as "
                "`ChecksNone`",
                text,
                path,
            )
            self.assertIn("PRESENT, non-null rollup", text, path)

    def test_the_branch_precedes_every_clearing_or_mutating_branch(self):
        for path in FIX_ASSETS:
            text = read(path)
            untrusted = text.index("**A rollup you cannot trust**")
            for later in (
                "**Behind its base**",
                "**Any other merge state that is not ready**",
                "**Nothing to fix**",
            ):
                self.assertLess(
                    untrusted,
                    text.index(later),
                    f"{path}: the untrusted-rollup branch must precede {later}",
                )


class OriginBrandGateTests(unittest.TestCase):
    """Each rendered asset demands ITS OWN brand's origin marker.

    This is the one rule the two assets must state DIFFERENTLY, so a shared
    assertion would be satisfied by an asset that demanded the wrong brand.
    Asserting each side names its own marker and refuses the other is what
    makes the gate real.
    """

    EXPECTED = {
        "claude-plugin/plugins/kanban/commands/fix.md": ("claude", "codex"),
        "codex-plugin/plugins/kanban/skills/fix/SKILL.md": ("codex", "claude"),
    }

    def test_each_asset_requires_its_own_brand_marker(self):
        for relative, (own, other) in self.EXPECTED.items():
            text = read(REPO_ROOT / relative)
            self.assertIn(
                f"so the marker must be `<!-- pr-origin:{own} -->`",
                text,
                f"{relative} does not require its own brand's origin marker",
            )
            self.assertIn(
                f"A `pr-origin:{other}` pull request belongs to",
                text,
                f"{relative} does not refuse the opposite brand's origin",
            )

    def test_neither_asset_requires_the_opposite_brands_marker(self):
        for relative, (own, other) in self.EXPECTED.items():
            text = read(REPO_ROOT / relative)
            self.assertNotIn(
                f"so the marker must be `<!-- pr-origin:{other} -->`",
                text,
                f"{relative} demands the WRONG brand's origin marker",
            )


class ReusedWorktreeSafetyTests(unittest.TestCase):
    """A reused worktree may not smuggle commits onto the reviewed head.

    The worktree is selected by branch and reused dirty on purpose -- that is
    how interrupted work survives. But dirty and AHEAD are different: an
    ordinary non-force push from a worktree carrying extra commits is a
    fast-forward that publishes all of them, so the remote-head check alone
    (which only proves nobody else moved it) cannot hold the one-commit limit.
    """

    def test_both_assets_require_the_reused_head_to_match(self):
        for path in FIX_ASSETS:
            text = flat(read(path))
            self.assertIn(
                "a reused worktree whose HEAD is not the recorded head stops "
                "the run",
                text,
                path,
            )
            self.assertIn("git -C <worktree> rev-parse HEAD", text, path)

    def test_the_distinction_between_dirty_and_ahead_is_stated(self):
        for path in FIX_ASSETS:
            text = flat(read(path))
            # Dirty is preserved...
            self.assertIn("preserve and continue there", text, path)
            self.assertIn("Uncommitted work is safe to keep", text, path)
            # ...ahead is refused, including the diverged case.
            self.assertIn(
                "The same applies when HEAD has diverged rather than merely "
                "advanced.",
                text,
                path,
            )

    def test_the_remote_head_check_is_still_present_too(self):
        # The two checks answer different questions and neither replaces the
        # other: this one proves nobody else moved the remote.
        for path in FIX_ASSETS:
            self.assertIn(
                "verify its remote head still equals the recorded SHA",
                flat(read(path)),
                path,
            )


class PrePushAuthorityRevalidationTests(unittest.TestCase):
    """A stable branch ref does not prove the workflow still has authority.

    Approval, labels, and the PR body are mutable GitHub metadata. The initial
    read bounds diagnosis, while a second, fresh evaluation immediately before
    the push closes the window in which authority can be withdrawn without
    changing the SHA. Since issue #842 that second evaluation is the bundled
    approval helper run again, so the pull request is read once by the workflow
    (for the facts the diagnosis needs) and once more by the helper on each of
    its two runs.
    """

    PR_VIEW_PREFIX = "gh pr view <pr> -R <owner/name> --json "
    HELPER_CALL = "python3 \"$APPROVAL_HELPER\" --policy fix"

    def test_both_assets_read_the_diagnosis_facts_once_and_the_helper_twice(self):
        for path in FIX_ASSETS:
            text = read(path)
            self.assertEqual(
                text.count(self.PR_VIEW_PREFIX),
                1,
                f"{path} reads the pull request for the diagnosis once; the "
                "authority is read by the helper, not by a second workflow read",
            )
            self.assertEqual(
                text.count(self.HELPER_CALL),
                2,
                f"{path} must run the approval helper at step 2c and again "
                "immediately before the push",
            )

    def test_the_diagnosis_read_no_longer_carries_the_authority_fields_twice(self):
        for path in FIX_ASSETS:
            text = read(path)
            command = text[text.index(self.PR_VIEW_PREFIX):]
            command = command[: command.index("\n")]
            self.assertIn("headRefOid", command, path)
            self.assertIn("baseRefName", command, path)

    def test_revalidation_is_after_the_remote_head_check_and_before_push(self):
        for path in FIX_ASSETS:
            text = read(path)
            remote_head_check = text.index(
                "verify its remote head still equals the recorded SHA"
            )
            fresh_gate = text.index("IMMEDIATELY before the push")
            push = text.index("Only after BOTH pre-push checks pass, push", fresh_gate)
            post_push = text.index("After pushing, verify", push)
            self.assertLess(remote_head_check, fresh_gate, path)
            self.assertLess(fresh_gate, push, path)
            self.assertLess(push, post_push, path)

    def test_the_second_helper_run_sits_between_the_head_check_and_the_push(self):
        for path in FIX_ASSETS:
            text = read(path)
            fresh_gate = text.index("IMMEDIATELY before the push")
            second_call = text.index(self.HELPER_CALL, fresh_gate)
            push = text.index("Only after BOTH pre-push checks pass, push", fresh_gate)
            self.assertLess(fresh_gate, second_call, path)
            self.assertLess(second_call, push, path)

    def test_the_problem_label_helper_the_assets_follow_still_exists(self):
        workflow = read(WORKFLOW_HS)
        self.assertIn("hasProblemLabel ::", workflow)


class RollupQueryTests(unittest.TestCase):
    """The shipped GraphQL query must actually be able to run.

    A query is a single quoted argument in a fenced command, so nothing between
    authoring and execution would have caught an unbalanced brace: the renderer
    copies it verbatim, and no test executed it. It shipped one closing brace
    short, which would have made every non-conflict diagnosis fail at the first
    call.
    """

    @staticmethod
    def _query(text: str) -> str:
        for line in text.splitlines():
            if "gh api graphql" in line:
                return line.split("-f query='", 1)[1].rsplit("'", 1)[0]
        raise AssertionError("no gh api graphql line found")

    def test_the_query_braces_balance(self):
        for path in FIX_ASSETS:
            query = self._query(read(path))
            depth = 0
            for index, char in enumerate(query):
                if char == "{":
                    depth += 1
                elif char == "}":
                    depth -= 1
                    self.assertGreaterEqual(
                        depth, 0, f"{path}: closes before it opens at {index}"
                    )
            self.assertEqual(
                depth,
                0,
                f"{path}: query ends at brace depth {depth}, not 0 "
                f"({query.count('{')} open, {query.count('}')} close)",
            )

    def test_the_query_selects_every_field_the_dedup_rule_needs(self):
        for path in FIX_ASSETS:
            query = self._query(read(path))
            for field in (
                "totalCount",
                "__typename",
                "checkSuite{app{slug}}",
                "creator{login}",
                "startedAt",
                "completedAt",
                "createdAt",
                "conclusion",
                "state",
            ):
                self.assertIn(field, query, f"{path}: query omits {field}")

    def test_both_assets_ship_the_same_query(self):
        queries = {self._query(read(path)) for path in FIX_ASSETS}
        self.assertEqual(len(queries), 1, "the two bundles ship different queries")


class WorkingTreeHygieneTests(unittest.TestCase):
    """No packaged asset may write into the repository being worked on.

    CLAUDE.md's Hygiene section forbids scratch files in the tree, and this
    repository has two mechanisms that make one actively harmful:
    `tools/drain_prs.py` must relocate untracked files before a fast-forward,
    and this workflow's own reused-worktree rule tells an agent to PRESERVE
    untracked content it finds -- so an artifact left by a diagnosis could be
    folded into a later focused commit.
    """

    # A shell redirect, as distinct from the `>` that closes a `<placeholder>`:
    # the operator is preceded by whitespace, which `<pr> -R` is not.
    REDIRECT_RE = re.compile(r"(?<=\s)>>?\s*(?P<target>\S+)")

    def _redirect_targets(self, text: str) -> list[tuple[str, str]]:
        found = []
        for line in text.splitlines():
            stripped = line.strip()
            for match in self.REDIRECT_RE.finditer(stripped):
                target = match.group("target")
                if target.startswith(("&", "/dev/null")):
                    continue
                found.append((stripped, target))
        return found

    def test_no_redirect_targets_a_relative_path(self):
        for path in FIX_ASSETS:
            for line, target in self._redirect_targets(read(path)):
                self.assertTrue(
                    target.startswith(('"$', "$", '"/', "/")),
                    f"{path} redirects into the working tree: {line!r}",
                )

    def test_the_redirect_detector_finds_every_redirect_that_exists(self):
        # Non-vacuous anchor: a detector that matched nothing would make the
        # rule above pass on an asset that redirected anywhere it liked. Every
        # scratch variable is named, so a fence added without one fails here
        # rather than going unmeasured.
        for path in FIX_ASSETS:
            targets = [t for _, t in self._redirect_targets(read(path))]
            for variable in SCRATCH_VARIABLES:
                self.assertIn(f'"${variable}"', targets, f"{path}: {variable}")

    def test_every_scratch_path_uses_portable_argument_free_mktemp(self):
        for path in FIX_ASSETS:
            text = read(path)
            for variable in SCRATCH_VARIABLES:
                self.assertIn(f'{variable}="$(mktemp)"', text, f"{path}: {variable}")
            self.assertNotIn(
                "mktemp -t",
                text,
                f"{path} uses BSD -t syntax that GNU mktemp rejects without Xs",
            )

    def test_every_scratch_path_is_assigned_before_it_is_redirected_into(self):
        # A reader executes the fence top to bottom. An assignment that came
        # after the redirect would leave the target empty, which is the shape
        # this ordering assertion exists to refuse.
        for path in FIX_ASSETS:
            text = read(path)
            for variable in SCRATCH_VARIABLES:
                assignment = text.index(f'{variable}="$(mktemp')
                redirect = text.index(f'> "${variable}"')
                self.assertLess(
                    assignment,
                    redirect,
                    f"{path} redirects into ${variable} before assigning it",
                )

    def test_every_scratch_file_is_removed_in_the_same_fence(self):
        for path in FIX_ASSETS:
            text = read(path)
            for variable in SCRATCH_VARIABLES:
                redirect = text.index(f'> "${variable}"')
                self.assertIn(
                    f'rm -f "${variable}"',
                    text[redirect:],
                    f"{path} never removes ${variable}",
                )

    def test_no_other_packaged_asset_redirects_into_the_tree(self):
        # Non-vacuous control: this rule is measured against every rendered
        # bundle asset, so a rule that passed only because `fix` was the only
        # file examined would fail here instead.
        roots = (
            REPO_ROOT / "claude-plugin/plugins/kanban/commands",
            REPO_ROOT / "codex-plugin/plugins/kanban/skills",
        )
        examined = 0
        for root in roots:
            for asset in sorted(root.rglob("*.md")):
                examined += 1
                for line, target in self._redirect_targets(
                    asset.read_text(encoding="utf-8")
                ):
                    self.assertTrue(
                        target.startswith(('"$', "$", '"/', "/")),
                        f"{asset} redirects into the working tree: {line!r}",
                    )
        self.assertGreaterEqual(examined, 20, "no bundle assets were examined")


class ContextDeduplicationTests(unittest.TestCase):
    """The workflow judges checks, not raw contexts.

    GitHub returns every context on the head commit, superseded ones included,
    so an old failure can sit beside the passing rerun that replaced it. Kanban
    never reads that list directly. A workflow that did would edit, push and
    rereview a pull request whose board status is already green -- and because
    the PR drainer reruns required checks on its own schedule, that state is
    one this repository actually produces.
    """

    def test_both_assets_restate_the_decoders_key_and_recency_rule(self):
        for path in FIX_ASSETS:
            text = flat(read(path))
            self.assertIn("check:<app-slug>:<name>", text, path)
            self.assertIn("status:<creator-login>:<context>", text, path)
            self.assertIn("keeps only the most recent context per key", text, path)

    def test_the_rollup_query_fetches_the_fields_that_rule_needs(self):
        # `gh pr view --json statusCheckRollup` omits the app slug and the
        # status creator, so the key cannot be built from it. The assets must
        # ask for the same fields Kanban's own query does.
        for path in FIX_ASSETS:
            text = read(path)
            for field in (
                "checkSuite{app{slug}}",
                "creator{login}",
                "startedAt",
                "completedAt",
                "createdAt",
            ):
                self.assertIn(field, text, f"{path} never fetches {field}")

    def test_the_key_shape_still_matches_the_decoder(self):
        # Non-vacuous anchor: the assets restate a key format that must remain
        # the one Decode.hs builds.
        decode = read(REPO_ROOT / "src/Kanban/GitHub/Decode.hs")
        self.assertIn('checkContextKey = "check:" <> app <> ":" <> name', decode)
        self.assertIn('checkContextKey = "status:" <> creator <> ":" <> name', decode)
        self.assertIn("(startedAt <|> completedAt)", decode)

    def test_the_summary_still_reads_only_the_latest_per_key(self):
        workflow = read(REPO_ROOT / "src/Kanban/GitHub/Decode.hs")
        self.assertIn("latest = Map.elems (Map.fromListWith latestContext", workflow)


class NoRerunTests(unittest.TestCase):
    """The prohibition is enforced as a command line, not only as prose.

    The workflow NAMES `gh run rerun` in the paragraph explaining why it is
    refused -- that paragraph is what stops the capability being reintroduced
    as an optimisation -- so the assertion scans only lines that actually
    invoke a command, and requires none of them to be a rerun.
    """

    def test_no_asset_invokes_gh_run_rerun(self):
        for path in FIX_ASSETS:
            for line in read(path).splitlines():
                stripped = line.strip()
                self.assertFalse(
                    stripped.startswith("gh run rerun"),
                    f"{path} invokes a rerun: {stripped!r}",
                )

    def test_the_prohibition_names_the_drainer_as_the_owner(self):
        for path in FIX_ASSETS:
            text = flat(read(path))
            self.assertIn("This workflow does not retry a red check, ever.", text, path)
            self.assertIn("tools/drain_prs.py", text, path)

    def test_the_drainer_really_is_still_the_rerunner(self):
        # Non-vacuous anchor: the prohibition defers to a capability that must
        # still exist, or the workflow is refusing to do something nothing
        # else does either.
        drainer = read(REPO_ROOT / "tools/drain_prs.py")
        self.assertIn("MAX_CI_RERUN_ATTEMPTS = ", drainer)
        self.assertIn("def rerun_failed_ci(", drainer)


class MergeStateCoverageTests(unittest.TestCase):
    """Every non-ready merge state has a defined branch, and only one of them
    is fixable by updating from the base."""

    def test_every_non_ready_merge_state_kanban_models_is_named(self):
        domain = read(REPO_ROOT / "src/Kanban/Domain.hs")
        workflow = read(WORKFLOW_HS)
        # The two Kanban calls ready; everything else must reach a branch.
        self.assertIn("mergeStateReady MergeClean = True", workflow)
        self.assertIn("mergeStateReady MergeProtected = True", workflow)
        for constructor in ("MergeBehind", "MergeBlocked", "MergeUnstable"):
            self.assertIn(constructor, domain, f"{constructor} is gone")
            for path in FIX_ASSETS:
                self.assertIn(
                    constructor.removeprefix("Merge").upper()
                    if constructor != "MergeBehind"
                    else "BEHIND",
                    read(path),
                    f"{path} never names {constructor}'s GitHub state",
                )

    def test_only_behind_is_remedied_by_a_branch_update(self):
        for path in FIX_ASSETS:
            text = read(path)
            self.assertIn("the merge state is exactly `BEHIND`", text, path)
            self.assertIn(
                "a branch update cannot clear a branch-protection", text, path
            )


class ContractDocumentationTests(unittest.TestCase):
    """The authoritative action contract documents this workflow.

    Manifest rows declare what it *reaches*; they are not a statement of its
    invocation, authority, or durable state. A workflow that may push a
    reviewed head and spawn a nested canonical review owes
    docs/agent-workflow-contract.md its own section.
    """

    CONTRACT = REPO_ROOT / "docs/agent-workflow-contract.md"

    def test_the_contract_has_a_section_for_this_workflow(self):
        text = self.CONTRACT.read_text(encoding="utf-8")
        self.assertIn(
            "### 2.9 Approved-pull-request fix (`$fix` / `/fix`)",
            text,
            "docs/agent-workflow-contract.md has no section for the fix action",
        )

    def test_that_section_states_every_contract_dimension(self):
        text = self.CONTRACT.read_text(encoding="utf-8")
        start = text.index("### 2.9 Approved-pull-request fix")
        end = text.index("## 3. Migration boundary", start)
        section = text[start:end]
        for heading in (
            "**Owning source:**",
            "**Invocation:**",
            "**Inputs:**",
            "**Preconditions:**",
            "**Outputs:**",
            "**No rerun authority:**",
            "**Failure semantics:**",
            "**Required authority:**",
            "**Durable state:**",
            "**Mandatory/optional:**",
        ):
            self.assertIn(heading, section, f"§2.9 omits {heading}")
        # The two properties that make this action different from a revision.
        self.assertIn("approvedPullRequest", section)
        self.assertIn("MergeBehind", section)
        # The precedence the contract states must be the one the assets use:
        # conflict is decided without check state and precedes the rollup test.
        self.assertIn("not ahead of everything that mutates", section)
        self.assertIn("MAX_CI_RERUN_ATTEMPTS", section)
        self.assertIn("never retries a red check", section)
        self.assertIn("`--self-review`", section)
        self.assertIn("rather than reviewing itself", section)

    def test_that_section_states_the_head_binding_precondition(self):
        # The workflow's authority over a commit is a contract dimension of its
        # own: §2.9's Preconditions bullet documents the board's
        # label/reviewDecision predicate, which is deliberately NOT narrowed,
        # so the additional precondition `fix` imposes needs its own statement
        # or the contract reads as though the board predicate were sufficient.
        text = self.CONTRACT.read_text(encoding="utf-8")
        start = text.index("### 2.9 Approved-pull-request fix")
        end = text.index("## 3. Migration boundary", start)
        section = text[start:end]
        self.assertIn(
            "**Head-bound approval, an additional precondition of `fix` alone:**",
            section,
            "§2.9 does not document the head binding as its own precondition",
        )
        flattened = flat(section)
        for claim in (
            "the Done-column classification `docs/design.md` documents as "
            "`classifyPullRequest`'s own verdict is unchanged",
            "that approval must additionally be bound to the CURRENT "
            "`headRefOid`",
            "the two are evaluated independently and either binding suffices",
            "never falls back to an older approval",
            "no worktree, no repair, no commit, no push, no rereview",
            "re-fetched and re-evaluated in the workflow's own pre-push "
            "authority revalidation",
            "`approved_head_changed`",
        ):
            self.assertIn(flat(claim), flattened, f"§2.9 omits: {claim!r}")

    def test_the_board_predicate_the_section_preserves_still_exists(self):
        # Non-vacuous anchor for "the board predicate is unchanged": §2.9 says
        # `fix` adds a precondition rather than narrowing what Kanban itself
        # classifies as approved, so that classification must still be there.
        workflow = read(WORKFLOW_HS)
        self.assertIn("approvedPullRequest ::", workflow)
        self.assertIn("classifyPullRequest ::", workflow)
        design = read(REPO_ROOT / "docs/design.md")
        self.assertIn("`classifyPullRequest`'s own verdict", design)

    def test_the_scope_sentence_names_the_action(self):
        # Prose that enumerates the actions, audited the way the README
        # inventories below are.
        text = self.CONTRACT.read_text(encoding="utf-8")
        self.assertIn("the\napproved-pull-request fix", text)

    def test_the_merge_state_the_section_cites_really_exists(self):
        # Non-vacuous anchor: §2.9 and both assets tell a reader that a
        # not-ready merge state is its own obstacle, naming Kanban's own
        # constructor. A rename must fail here.
        domain = (REPO_ROOT / "src/Kanban/Domain.hs").read_text(encoding="utf-8")
        self.assertIn("MergeBehind", domain)
        workflow = (REPO_ROOT / "src/Kanban/Workflow.hs").read_text(encoding="utf-8")
        self.assertIn("mergeStateReady", workflow)
        self.assertIn('StatusPending "merge pending"', workflow)


class HeadBoundApprovalTests(unittest.TestCase):
    """An approval signal is not authority over a particular commit.

    A configured approval label and GitHub's `reviewDecision` are both mutable
    pull-request metadata that name no SHA, so both survive a third party's
    push and keep reading green over code nobody reviewed. This workflow pushes
    a commit onto the head it accepted, so it must bind that approval to the
    CURRENT `headRefOid` before it may create a worktree at all -- the rule
    `tools/drain_prs.py` already applies when it refuses `approved_head_changed`.

    The phrase table above pins what the assets SAY. This class pins the parts
    a phrase cannot: that the binding is stated before every mutating step,
    that both evidence feeds are actually fetched, and that the components the
    rules cite by name still exist.
    """

    # Every rule the head binding added. Each is asserted present in both
    # rendered assets by the table above and ABSENT from the pr-revise pair by
    # RevisionDelegationTests, so this tuple is the join between the two.
    HEAD_BINDING_RULES = (
        "approval-modes-are-read-never-accepted-on-their-own",
        "an-unbound-signal-is-never-sufficient",
        "head-bound-approval-is-required-before-anything-mutates",
        "why-an-unbound-approval-is-authority-over-unreviewed-code",
        "the-drainer-already-keys-on-the-approved-head",
        "carrying-the-approval-forward-is-not-available-here",
        "the-two-evidence-paths-are-weighed-independently",
        "the-success-test-is-exit-approved-and-recorded-head",
        "a-refusal-object-is-never-success",
        "the-recorded-head-is-the-approved-head",
        "the-pre-push-guard-runs-only-behind-the-initial-one",
        "the-push-is-reachable-only-through-the-fresh-guard",
        "a-single-path-failure-does-not-veto-the-other-path",
        "the-remedy-is-chosen-from-the-marker-history",
        "problem-labels-refuse-under-every-mode",
        "an-unresolved-publisher-fails-closed",
        "the-whole-paginated-comment-feed-is-read",
        "the-marker-is-selected-by-recency-before-it-is-tested",
        "the-label-path-needs-a-current-head-approve-marker",
        "missing-or-malformed-evidence-never-falls-back",
        "the-aggregate-review-decision-is-necessary-not-sufficient",
        "the-effective-review-per-author-is-the-native-evidence",
        "the-review-path-needs-an-approval-naming-the-current-commit",
        "stale-or-unattributed-native-approval-is-insufficient",
        "the-refusal-names-both-heads-or-says-there-is-none",
        "the-review-path-is-not-cleared-by-a-canonical-review",
        "neither-a-label-nor-a-review-is-manufactured",
        "the-head-binding-is-re-established-before-the-push",
        "a-cached-initial-reading-cannot-answer-for-the-push",
        "a-pre-push-stop-preserves-the-worktree",
    )

    def test_every_head_binding_rule_is_asserted_and_is_fix_only(self):
        for requirement in self.HEAD_BINDING_RULES:
            self.assertIn(
                requirement,
                REQUIRED_PHRASES,
                f"{requirement} is not asserted against the rendered assets",
            )
            self.assertIn(
                requirement,
                FIX_ONLY_REQUIREMENTS,
                f"{requirement} is not in the pr-revise negative control",
            )

    def test_the_binding_is_stated_before_every_step_that_can_mutate(self):
        # Requirement 1 is an ordering claim, not a wording one: a section that
        # stated the rule after the diagnosis or the worktree would leave the
        # unreviewed head already acted on.
        for path in FIX_ASSETS:
            text = read(path)
            binding = text.index("## 2c. Bind that approval to the current head")
            diagnosis = text.index("## 3. Diagnose the remaining obstacle")
            worktree = text.index("## 4. Work in the pull request's own worktree")
            self.assertLess(binding, diagnosis, path)
            self.assertLess(diagnosis, worktree, path)

    def test_both_evidence_feeds_are_fetched_in_full(self):
        # An approval bound to a head read off a capped view is not bound at
        # all: the newest marker or review can be the one outside the cap. The
        # feeds are the bundled helper's to read now, so the assertion is on the
        # program the assets run, and `test_pr_head_approval.py` runs it.
        helper = read(REPO_ROOT / "tools/pr_head_approval.py")
        for endpoint in (
            'f"repos/{repo}/issues/{pr}/comments?per_page=100"',
            'f"repos/{repo}/pulls/{pr}/reviews?per_page=100"',
        ):
            self.assertIn(endpoint, helper)
        self.assertEqual(helper.count('"--paginate", "--slurp"'), 2)
        for path in FIX_ASSETS:
            text = read(path)
            self.assertNotIn("gh api --paginate", text, path)
            self.assertIn("COMPLETE paginated feed", text, path)

    def test_the_binding_is_re_established_inside_the_pre_push_gate(self):
        # The fresh evaluation has to sit between the remote-head check and the
        # push, in the same window step 4's other authority checks occupy.
        for path in FIX_ASSETS:
            text = read(path)
            fresh_gate = text.index("IMMEDIATELY before the push")
            rebind = text.index(
                "so nothing cached from step 2c can answer for this moment"
            )
            push = text.index("Only after BOTH pre-push checks pass, push", fresh_gate)
            self.assertLess(fresh_gate, rebind, path)
            self.assertLess(rebind, push, path)

    def test_the_drainer_refusal_the_rules_cite_still_exists(self):
        # Non-vacuous anchor: both assets tell a reader the drainer refuses
        # with `approved_head_changed` when the label names another head. A
        # rename there must fail here rather than leave the assets citing a
        # refusal that no longer exists.
        self.assertIn("approved_head_changed", read(DRAINER))
        for path in FIX_ASSETS:
            self.assertIn("`approved_head_changed`", read(path))

    def test_the_marker_the_label_path_reads_is_the_one_published(self):
        # Non-vacuous anchor: the label path is only head-bound because the
        # coordinator writes a head into its marker and selects the newest one
        # its own login published. Both must still be true in both bundles.
        for coordinator in COORDINATORS:
            source = read(coordinator)
            self.assertIn("REVIEW_MARKER_RE = ", source, coordinator)
            self.assertIn("head=(?P<head>[0-9a-f]{40})", source, coordinator)
            self.assertIn("def latest_owned_review_marker(", source, coordinator)
        # The helper reads the head the same way the coordinator writes it. The
        # coordinator's own selector is NOT the helper's oracle: it takes the
        # last parsable match, where the helper applies finalize's complete
        # selection and malformed-marker rules.
        helper = read(REPO_ROOT / "tools/pr_head_approval.py")
        self.assertIn("head=(?P<head>[0-9a-f]{40})", helper)

    def test_the_selection_rule_is_one_implementation_both_callers_share(self):
        # Non-vacuous anchor for "newest by creation time, comment id breaking
        # ties": the ordering lives in the one helper both callers run, and
        # neither workflow source carries a second copy of it.
        helper = read(REPO_ROOT / "tools/pr_head_approval.py")
        self.assertIn(
            'key=lambda item: (str(item.get("created_at") or ""), '
            'record_id(item)),',
            helper,
            "the helper no longer orders the feed by created_at then id",
        )
        self.assertIn("reverse=True,", helper)
        for source in (FINALIZE_SOURCE, FIX_SOURCE):
            self.assertNotIn(
                'record_id(item)', read(source), f"{source} re-implements it"
            )
            self.assertNotIn(
                'int(item.get("id") or 0)', read(source), f"{source} re-implements it"
            )

    def test_the_approval_modes_the_binding_branches_on_are_the_haskell_ones(self):
        # The binding is per mode, so the three modes must still be the three
        # `approvedPullRequest` resolves.
        source = read(WORKFLOW_HS)
        for mode in ("ApprovalByLabel", "ApprovalByReview", "ApprovalByEither"):
            self.assertIn(mode, source)
        for path in FIX_ASSETS:
            text = read(path)
            for mode in ("`label`", "`review`", "`either`"):
                self.assertIn(mode, text, f"{path} no longer names {mode}")


class ReviewRemedyRoutingTests(unittest.TestCase):
    """Bind each review-history condition to its actual shipped command.

    The descriptive phrases alone survive a wrong command choice. Exercise
    the same assertions against wrong-route mutations and the pr-revise assets,
    which do not own fix's approval-refusal remedy.
    """

    ASSETS = ((CODEX_FIX, CODEX_REVISE, "$"), (CLAUDE_FIX, CLAUDE_REVISE, "/"))
    ROUTES = (
        (
            "pr-rereview",
            "name {sigil}pr-rereview when `marker_history` is `true` — the "
            "authenticated publisher has published a canonical `pr-review` "
            "marker on this pull request at all",
        ),
        (
            "pr-review",
            "and name {sigil}pr-review only when it is `false`.",
        ),
    )

    def assert_remedy_routes(self, text, sigil):
        # Other sections also name these commands; only the refusal's
        # condition-to-command mapping can satisfy this contract.
        section = text.split("Then name the remedy without performing it.", 1)[1]
        section = section.split("**This workflow manufactures neither.**", 1)[0]
        for _, phrase in self.ROUTES:
            self.assertIn(phrase.format(sigil=sigil), flat(section))

    def test_both_assets_route_each_review_history_case(self):
        for path, _, sigil in self.ASSETS:
            with self.subTest(asset=path):
                self.assert_remedy_routes(read(path), sigil)

    def test_wrong_command_for_either_history_case_is_rejected(self):
        for path, _, sigil in self.ASSETS:
            text = flat(read(path))
            for command, phrase in self.ROUTES:
                with self.subTest(asset=path, command=command):
                    expected = phrase.format(sigil=sigil)
                    self.assertEqual(text.count(expected), 1)
                    wrong_command = (
                        "pr-review" if command == "pr-rereview" else "pr-rereview"
                    )
                    mutated = text.replace(
                        expected, expected.replace(sigil + command, sigil + wrong_command)
                    )
                    with self.assertRaises(AssertionError):
                        self.assert_remedy_routes(mutated, sigil)

    def test_revise_assets_do_not_carry_the_fix_remedy_rules(self):
        for _, path, sigil in self.ASSETS:
            for command, phrase in self.ROUTES:
                with self.subTest(asset=path, command=command):
                    self.assertNotIn(phrase.format(sigil=sigil), flat(read(path)))


class VacuousRuleControlTests(unittest.TestCase):
    """The negative control the new rules owe, exercised rather than asserted.

    `RevisionDelegationTests` proves today's table is fix-specific, but it does
    that by passing -- on a table that had decayed into fragments common to
    every packaged workflow it would fail, and nothing demonstrates that it
    still CAN. These two tests run the same predicates over a deliberately
    vacuous phrase and require them to reject it, so "the head-binding rules
    are not vacuous" is a measured property rather than a claim.
    """

    VACUOUS_PHRASE = "the pull request"

    def test_a_phrase_present_in_every_asset_fails_the_fix_only_control(self):
        # The phrase matches every fix asset, so the positive test would pass
        # on it. The pr-revise control is what has to refuse it.
        for path in FIX_ASSETS:
            self.assertIn(self.VACUOUS_PHRASE, flat(read(path)))
        leaked = [
            path.relative_to(REPO_ROOT)
            for path in REVISE_ASSETS
            if self.VACUOUS_PHRASE in flat(read(path))
        ]
        self.assertNotEqual(
            leaked,
            [],
            "a phrase common to every packaged workflow slipped past the "
            "pr-revise negative control, which therefore proves nothing about "
            "the head-binding rules either",
        )

    def test_a_head_binding_rule_is_absent_from_the_revise_pair(self):
        # The other half of the same control: a real rule must NOT match, or
        # the test above would be refusing everything indiscriminately.
        for requirement in HeadBoundApprovalTests.HEAD_BINDING_RULES:
            phrase = flat(REQUIRED_PHRASES[requirement])
            for path in REVISE_ASSETS:
                self.assertNotIn(
                    phrase,
                    flat(read(path)),
                    f"{path.relative_to(REPO_ROOT)} carries {requirement}",
                )


class RevisionDelegationTests(unittest.TestCase):
    """The negative control CLAUDE.md's quality gates require.

    Every rule that belongs to fix alone is asserted ABSENT from the pr-revise
    pair. Without this, a phrase table that had decayed into fragments common
    to every packaged workflow would pass the positive test above while
    asserting nothing about this workflow in particular.
    """

    def test_pr_revise_carries_none_of_the_fix_only_rules(self):
        leaked = []
        for path in REVISE_ASSETS:
            text = read(path)
            flattened = flat(text)
            for requirement in FIX_ONLY_REQUIREMENTS:
                if flat(REQUIRED_PHRASES[requirement]) in flattened:
                    leaked.append(f"{path.relative_to(REPO_ROOT)}: {requirement}")
        self.assertEqual(
            leaked,
            [],
            "pr-revise must not carry fix's approval or origin gates:\n"
            + "\n".join(leaked),
        )

    def test_the_fix_only_set_is_a_real_subset_of_the_required_table(self):
        self.assertTrue(set(FIX_ONLY_REQUIREMENTS) < set(REQUIRED_PHRASES))
        self.assertGreaterEqual(len(FIX_ONLY_REQUIREMENTS), 10)


# The origin rules fix step 2b states and pr-revise step 1 repeats: both author
# a change on a pull request and hand it to a reviewer the coordinator routes
# from the same marker. Each entry is a key of REQUIRED_PHRASES, so fix's own
# wording is the single source and "fix's is unchanged" is the same assertion.
ORIGIN_GUARD_RULES = (
    "the-origin-rules-are-the-coordinators",
    "every-malformed-origin-is-a-refusal-not-a-default",
    "a-wrong-brand-origin-stops-with-nothing-changed",
)

# The negative control, in WriteLocationTests' pattern: assets that never
# author a change on someone else's pull request. pr-review and pr-rereview
# hand the origin decision to the coordinator's route, and finalize only reads
# the marker to exclude a self-review, so none owes the guard, and a rule that
# matched every PR workflow would have to pass here too.
ORIGIN_GUARD_DELEGATING_ASSETS = tuple(
    REPO_ROOT / path
    for path in (
        "claude-plugin/plugins/kanban/commands/pr-review.md",
        "claude-plugin/plugins/kanban/commands/pr-rereview.md",
        "codex-plugin/plugins/kanban/skills/pr-review/SKILL.md",
        "codex-plugin/plugins/kanban/skills/pr-rereview/SKILL.md",
    )
)

# What pr-revise must no longer say: a routing table the coordinator owns, a
# claim about who starts this session, and any instruction to wait on checks.
REVISE_RETIRED_TEXT = (
    "uses both independently",
    "only ever resumes the original solver",
    "route is fixed by brand",
    "Kanban resumes this session",
    # The coordinator collapses routing to the one loaded provider in
    # single-agent mode (docs/agent-workflow-contract.md section 2.2), so a
    # Claude-only roster reviews a Claude-origin pull request with Claude.
    # Any promise of an independent or opposite-brand reviewer is false there.
    "never reaches the brand that authored the revision",
    "opposite brand's canonical reviewer",
    "never to this session's own model",
)

WAITS_FOR_CHECKS_RE = re.compile(
    r"(?i)\b(?:wait(?:s|ing)? for|poll(?:s|ing)?)\b[^.\n]{0,40}\b(?:ci|checks?)\b"
    r"|diagnose and fix only when the failure"
)


def waits_for_checks(text: str) -> bool:
    """True when `text` tells its reader to wait on a pull request's checks.

    The acceptance grep `wait for (the )?(required )?(CI|checks)` misses
    "Wait for the PR's required checks", which is the sentence that actually
    held the instruction, so the rule here allows words between the verb and
    the noun and is proved against that sentence below. A "Do not wait for ..."
    sentence is the one permitted spelling, because it forbids the wait.
    """
    permitted = re.sub(r"Do not wait for[^.\n]*\.", "", text)
    return bool(WAITS_FOR_CHECKS_RE.search(permitted))


class ReviseOriginGuardTests(unittest.TestCase):
    """pr-revise refuses a pull request of another brand, as fix step 2b does.

    Issue #839. Both workflows push a commit and then invoke a rereview the
    coordinator routes from the pull request's `pr-origin` marker, so run on a
    pull request of the other brand either would author a change and hand it
    to its own brand. fix asserts the rule through REQUIRED_PHRASES; this class
    asserts that the same rule, in the same words, guards pr-revise in both
    bundles, that it comes before anything that mutates, and that it is absent
    from the assets that delegate the decision.
    """

    GUARDED = FIX_ASSETS + REVISE_ASSETS

    def test_the_rules_are_fix_step_2b_s_own_phrases(self):
        for rule in ORIGIN_GUARD_RULES:
            self.assertIn(rule, REQUIRED_PHRASES)
            self.assertNotIn(rule, FIX_ONLY_REQUIREMENTS)

    def test_every_guarded_asset_carries_every_rule(self):
        for path in self.GUARDED:
            flattened = flat(read(path))
            for rule in ORIGIN_GUARD_RULES:
                with self.subTest(asset=path.relative_to(REPO_ROOT).as_posix(), rule=rule):
                    self.assertIn(flat(REQUIRED_PHRASES[rule]), flattened)

    def test_each_brand_demands_its_own_marker_and_only_that_one(self):
        for path, brand, other in (
            (CLAUDE_FIX, "claude", "codex"),
            (CLAUDE_REVISE, "claude", "codex"),
            (CODEX_FIX, "codex", "claude"),
            (CODEX_REVISE, "codex", "claude"),
        ):
            flattened = flat(read(path))
            with self.subTest(asset=path.relative_to(REPO_ROOT).as_posix()):
                self.assertIn(
                    f"the marker must be `<!-- pr-origin:{brand} -->`", flattened
                )
                self.assertNotIn(
                    f"the marker must be `<!-- pr-origin:{other} -->`", flattened
                )

    def test_external_and_unknown_origins_stop_pr_revise_too(self):
        for path in REVISE_ASSETS:
            with self.subTest(asset=path.relative_to(REPO_ROOT).as_posix()):
                self.assertIn(
                    "An unknown-origin or external-origin pull request",
                    flat(read(path)),
                )

    def test_the_guard_precedes_every_step_that_can_mutate(self):
        for path in REVISE_ASSETS:
            text = read(path)
            guard = text.index("## 1. Require the pull request's origin to be this brand")
            for later in (
                "## 2. Establish the review contract",
                "## 3. Use an isolated, current worktree",
                "## 5. Rerun canonical review",
            ):
                with self.subTest(asset=path.relative_to(REPO_ROOT).as_posix(), step=later):
                    self.assertLess(guard, text.index(later))

    def test_the_delegating_assets_carry_none_of_the_guard(self):
        for path in ORIGIN_GUARD_DELEGATING_ASSETS:
            flattened = flat(read(path))
            for rule in ORIGIN_GUARD_RULES:
                with self.subTest(asset=path.relative_to(REPO_ROOT).as_posix(), rule=rule):
                    self.assertNotIn(flat(REQUIRED_PHRASES[rule]), flattened)

    def test_pr_revise_states_no_routing_rule_and_names_no_spawner(self):
        for path in REVISE_ASSETS:
            flattened = flat(read(path))
            for retired in REVISE_RETIRED_TEXT:
                with self.subTest(asset=path.relative_to(REPO_ROOT).as_posix(), text=retired):
                    self.assertNotIn(retired, flattened)
            self.assertIn(
                "The bundled coordinator decides which reviewer the rereview goes to",
                flattened,
            )

    def test_the_rereview_follows_the_push_without_waiting_for_checks(self):
        for path in REVISE_ASSETS:
            text = read(path)
            flattened = flat(text)
            with self.subTest(asset=path.relative_to(REPO_ROOT).as_posix()):
                self.assertFalse(waits_for_checks(text))
                self.assertNotIn("Wait for CI", text)
                self.assertIn("## 5. Rerun canonical review", text)
                self.assertIn(
                    "Do not wait for, poll, or diagnose the pull request's checks: "
                    "the rereview follows the push immediately.",
                    flattened,
                )
                self.assertIn(
                    "a statement that the pull request's checks were not awaited",
                    flattened,
                )
                # Local validation is kept: dropping the wait must not drop it.
                self.assertIn("Run the narrowest relevant tests", flattened)
                self.assertLess(
                    text.index("## 4. Implement and validate"),
                    text.index("## 5. Rerun canonical review"),
                )

    def test_the_wait_rule_catches_the_sentence_that_held_the_instruction(self):
        for planted in (
            "Wait for the PR's required checks for the pushed head to complete.",
            "If CI fails, diagnose and fix only when the failure is attributable.",
            "## 4. Wait for CI and rerun canonical review",
            "Poll the pull request's checks until they pass.",
        ):
            with self.subTest(planted=planted):
                self.assertTrue(waits_for_checks(planted))
        self.assertFalse(
            waits_for_checks("Do not wait for, poll, or diagnose the pull request's checks.")
        )

    def test_no_pr_workflow_cites_a_retired_haskell_parser(self):
        scanned = [
            REPO_ROOT / "tools/command_sources" / name
            for name in ("fix.md", "finalize.md", "pr-revise.md", "pr-review.md", "pr-rereview.md", "autosolve.md", "drain-prs.md")
        ]
        scanned += list(FIX_ASSETS) + list(REVISE_ASSETS) + list(ORIGIN_GUARD_DELEGATING_ASSETS)
        scanned += [
            REPO_ROOT / "claude-plugin/plugins/kanban/commands/finalize.md",
            REPO_ROOT / "codex-plugin/plugins/kanban/skills/finalize/SKILL.md",
            REPO_ROOT / "claude-plugin/README.md",
            REPO_ROOT / "codex-plugin/README.md",
        ]
        for path in scanned:
            with self.subTest(asset=path.relative_to(REPO_ROOT).as_posix()):
                text = read(path)
                self.assertNotIn("originFromBody", text)
                self.assertNotIn("PullRequestFlow", text)


# The spelled-out counts each bundle README states about its own inventory, and
# the number word for each. Prose that COUNTS a list is the failure mode
# CLAUDE.md's quality gates name explicitly -- "a module docstring saying 'the
# eleven documents' sat seventy lines above the tuple it described, and stayed
# wrong through several changes that grew it" -- and adding `fix` reproduced it
# across seven sites in two READMEs before a review caught them. This turns the
# whole-file audit into a gate.
#
# It has to stay ahead of the bundles it measures: the lookup below is a direct
# subscript, so a bundle that grows past the last entry raises KeyError rather
# than reporting a mismatched count, and the failure then names the map instead
# of the README that is actually stale. Two spare entries beyond today's
# totals, extended whenever a slice consumes one.

# --------------------------------------------------------------------------
# The approval guards, executed.
#
# Issue #842. Before it, fix's approval derivation was prose and the pre-push
# revalidation was a phrase: no test could run either. The two guard fences now
# run as written, so what follows runs them through each bundled copy of the
# helper against a scripted `gh`, `git` and coordinator, and asserts what the
# recorded logs do and do not contain.
# --------------------------------------------------------------------------

PR_NUMBER = "42"
REPO_SLUG = "coghex/kanban"
RECORDED = "1a2b3c4d5e6f70819293a4b5c6d7e8f900112233"
STALE = "99887766554433221100ffeeddccbbaa99887766"
MOVED = "0f0e0d0c0b0a09080706050403020100ffeeddcc"
WORKTREE = "/tmp/worktrees/coghex/kanban/pr-42-example"
HEAD_BRANCH = "issue-7-example"
HELPER_FIELDS = "number,body,headRefOid,labels,reviewDecision"
CLAUDE_HELPER = "claude-plugin/plugins/kanban/scripts/pr_head_approval.py"
CODEX_HELPER = "codex-plugin/plugins/kanban/skills/fix/scripts/pr_head_approval.py"
CLAUDE_COORDINATOR = "claude-plugin/plugins/kanban/scripts/review_pr.py"

BASH_FENCE_RE = re.compile(r"```bash\n(?P<body>.*?)\n[ \t]*```", re.DOTALL)
AVAILABLE_SHELLS = [
    name for name in ("sh", "bash", "dash", "zsh") if shutil.which(name)
]


def bash_fences(text: str) -> list[str]:
    return [match.group("body") for match in BASH_FENCE_RE.finditer(text)]


def guard_fences(path: Path) -> dict[str, str]:
    """The four fences the approval guards chain, by role, from a rendering.

    Exactly one of each, deliberately: a guard duplicated into a second fence is
    a rendering an executing agent could run half of.
    """
    fences = bash_fences(read(path))
    roles = {
        "initial": lambda f: "--policy fix" in f and "PUSH_APPROVED_HEAD" not in f,
        "pre_push": lambda f: "PUSH_APPROVED_HEAD=\"\"" in f,
        "push": lambda f: 'push "${HEAD_REMOTE:?}"' in f,
        "handoff": lambda f: '--rereview "$PR"' in f,
    }
    found = {}
    for role, test in roles.items():
        matching = [fence for fence in fences if test(fence)]
        assert len(matching) == 1, f"{path}: expected one {role} fence, got {len(matching)}"
        found[role] = matching[0]
    return found


def marker_for(head: str, verdict: str, reviewers: list[str]) -> str:
    spec = importlib.util.spec_from_file_location(
        "kanban_fix_guard_review_pr", REPO_ROOT / CLAUDE_COORDINATOR
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    lookup = {"codex": module.CODEX_REVIEWER, "claude": module.CLAUDE_REVIEWER}
    selected = [lookup[key] for key in reviewers]
    models = [f"model-{key}@xhigh" for key in reviewers]
    if len(inspect.signature(module.review_marker).parameters) == 3:
        return module.review_marker(selected, head, verdict)
    return module.review_marker(selected, models, head, verdict)


def feed(*markers: str) -> list:
    return [
        [
            {
                "id": index + 1,
                "created_at": f"2026-08-0{index + 1}T00:00:00Z",
                "user": {"login": "coghex"},
                "body": marker,
            }
            for index, marker in enumerate(markers)
        ]
    ]


def pull_request(
    *,
    head: str = RECORDED,
    labels: tuple[str, ...] = ("reviewed:approve",),
    origin: str = "claude",
    review_decision: str = "",
) -> dict:
    return {
        "number": int(PR_NUMBER),
        "body": f"Closes #7\n\n<!-- pr-origin:{origin} -->\n",
        "headRefOid": head,
        "labels": [{"name": name} for name in labels],
        "reviewDecision": review_decision,
    }


class GuardHarness:
    """A scripted `gh`/`git` pair, both bundles' layouts, and a coordinator stub."""

    def __init__(self, root: Path):
        self.root = root
        self.fake = fake_cli.FakeCli(root)
        self.fake.install("gh")
        self.fake.install("git")
        self.coordinator_log = root / "coordinator.calls"
        stub = (
            "import json, sys\n"
            f"open({str(self.coordinator_log)!r}, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
        )
        self.claude_plugin_root = root / "claude-plugin-root"
        (self.claude_plugin_root / "scripts").mkdir(parents=True)
        shutil.copy(
            REPO_ROOT / CLAUDE_HELPER,
            self.claude_plugin_root / "scripts" / "pr_head_approval.py",
        )
        (self.claude_plugin_root / "scripts" / "review_pr.py").write_text(stub)
        self.codex_home = root / "codex-home"
        cache = self.codex_home / "plugins" / "cache" / "market" / "kanban" / "1.0.0" / "skills"
        (cache / "fix" / "scripts").mkdir(parents=True)
        (cache / "pr-review" / "scripts").mkdir(parents=True)
        shutil.copy(REPO_ROOT / CODEX_HELPER, cache / "fix" / "scripts" / "pr_head_approval.py")
        (cache / "pr-review" / "scripts" / "review_pr.py").write_text(stub)
        self.config_home = root / "config"
        (self.config_home / "kanban").mkdir(parents=True)

    def configure(self, text: str) -> Path:
        path = self.config_home / "kanban" / "config.toml"
        path.write_text(text, encoding="utf-8")
        return path

    def stub_helper(self, stdout: str, exit_code: int = 0) -> None:
        source = f"import sys\nsys.stdout.write({stdout!r})\nsys.exit({exit_code})\n"
        for target in (
            self.claude_plugin_root / "scripts" / "pr_head_approval.py",
            *self.codex_home.rglob("pr_head_approval.py"),
        ):
            target.write_text(source, encoding="utf-8")

    def script_github(
        self,
        *,
        states,
        runs_of_comments,
        runs_of_reviews=None,
        viewer: str | None = "coghex",
    ) -> None:
        if viewer is None:
            self.fake.script("gh", ["api", "user", "--jq", ".login"], stderr="no\n", exit_code=1)
        else:
            self.fake.script("gh", ["api", "user", "--jq", ".login"], stdout=viewer + "\n")
        for state in states:
            self.fake.script(
                "gh",
                ["pr", "view", PR_NUMBER, "-R", REPO_SLUG, "--json", HELPER_FIELDS],
                stdout=json.dumps(state),
            )
        for pages in runs_of_comments:
            self.fake.script(
                "gh",
                [
                    "api",
                    "--paginate",
                    "--slurp",
                    f"repos/{REPO_SLUG}/issues/{PR_NUMBER}/comments?per_page=100",
                ],
                stdout=json.dumps(pages),
            )
        for pages in runs_of_reviews or [[[]]]:
            self.fake.script(
                "gh",
                [
                    "api",
                    "--paginate",
                    "--slurp",
                    f"repos/{REPO_SLUG}/pulls/{PR_NUMBER}/reviews?per_page=100",
                ],
                stdout=json.dumps(pages),
            )
        self.fake.script("git", ["-C", WORKTREE, "push"], stdout="")
        self.fake.script("git", ["rev-parse", "--show-toplevel"], stdout=WORKTREE + "\n")

    def run(self, script: str, *, recorded: str = RECORDED, config: str = "") -> subprocess.CompletedProcess:
        env = {
            "PATH": os.environ.get("PATH", ""),
            "HOME": str(self.root / "home"),
            "XDG_CONFIG_HOME": str(self.config_home),
            "CLAUDE_PLUGIN_ROOT": str(self.claude_plugin_root),
            "CODEX_HOME": str(self.codex_home),
            "PR": PR_NUMBER,
            "REPO": REPO_SLUG,
            "CONFIG": config,
            "RECORDED_HEAD": recorded,
            "WORKTREE": WORKTREE,
            "HEAD_REMOTE": "origin",
            "HEAD_BRANCH": HEAD_BRANCH,
        }
        env.update(self.fake.environ_overrides())
        return subprocess.run(
            ["sh", "-c", script],
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
        )

    def gh_calls(self) -> list[list[str]]:
        return [call["args"] for call in self.fake.calls("gh")]

    def pushes(self) -> list[list[str]]:
        return [call["args"] for call in self.fake.calls("git") if "push" in call["args"]]

    def handoffs(self) -> list[list[str]]:
        if not self.coordinator_log.exists():
            return []
        return [json.loads(line) for line in self.coordinator_log.read_text().splitlines()]


class Scenario:
    """The pull request a rendering fixes: its own brand's, approved by the
    other brand. The Codex rendering fixes `pr-origin:codex` pull requests, so a
    scenario built for the Claude rendering would be refused on its origin."""

    def __init__(self, path: Path):
        self.brand = "claude" if path == CLAUDE_FIX else "codex"
        self.other = "codex" if self.brand == "claude" else "claude"

    def pr(self, **overrides) -> dict:
        overrides.setdefault("origin", self.brand)
        return pull_request(**overrides)

    def marker(self, head: str = RECORDED, verdict: str = "APPROVE", reviewers=None) -> str:
        return marker_for(head, verdict, reviewers or [self.other])


class ApprovalGuardExecutionTests(unittest.TestCase):
    """Requirement 8: the guards run, refusals reach no mutation, and the
    positive control reaches the authorized mutation with the validated head."""

    FULL_CHAIN = ("initial", "pre_push", "push", "handoff")
    VIEW = ["pr", "view", PR_NUMBER, "-R", REPO_SLUG, "--json", HELPER_FIELDS]

    def chain(self, path: Path, roles) -> str:
        fences = guard_fences(path)
        return "\n".join(fences[role] for role in roles)

    def execute(
        self,
        path: Path,
        build=None,
        *,
        roles=FULL_CHAIN,
        recorded: str = RECORDED,
        config_text: str | None = None,
        config_path: bool = False,
        stub: tuple[str, int] | None = None,
    ):
        """Run the chain of `roles` for `path`'s rendering.

        `build` maps the rendering's `Scenario` to the `script_github`
        arguments; absent, the pull request is the ordinary approved one.
        """
        scenario = Scenario(path)
        scripted = build(scenario) if build is not None else {}
        scripted.setdefault("states", [scenario.pr()])
        scripted.setdefault("runs_of_comments", [feed(scenario.marker())])
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        harness = GuardHarness(Path(directory.name))
        harness.script_github(**scripted)
        config = ""
        if config_text is not None:
            written = harness.configure(config_text)
            config = str(written) if config_path else ""
        if stub is not None:
            harness.stub_helper(*stub)
        completed = harness.run(self.chain(path, roles), recorded=recorded, config=config)
        return completed, harness

    def assertNoMutation(self, harness: GuardHarness):
        self.assertEqual(harness.pushes(), [], harness.gh_calls())
        self.assertEqual(harness.handoffs(), [])

    # -- the positive control ------------------------------------------------

    def test_an_approved_head_reaches_the_push_and_the_handoff_with_it(self):
        for path in FIX_ASSETS:
            with self.subTest(asset=path.name):
                completed, harness = self.execute(path)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(
                    harness.pushes(),
                    [["-C", WORKTREE, "push", "origin", f"HEAD:refs/heads/{HEAD_BRANCH}"]],
                )
                handoffs = harness.handoffs()
                self.assertEqual(len(handoffs), 1, handoffs)
                self.assertEqual(handoffs[0][handoffs[0].index("--rereview") + 1], PR_NUMBER)

    def test_the_helper_is_run_fresh_before_the_push_not_reused(self):
        # Two guard runs mean two of every read, which is what makes the
        # re-fetch observable rather than assumed.
        feed_path = f"repos/{REPO_SLUG}/issues/{PR_NUMBER}/comments?per_page=100"
        for path in FIX_ASSETS:
            with self.subTest(asset=path.name):
                _, harness = self.execute(path)
                calls = harness.gh_calls()
                self.assertEqual(calls.count(self.VIEW), 2, calls)
                self.assertEqual(sum(1 for call in calls if call[-1] == feed_path), 2, calls)
                self.assertEqual(calls.count(["api", "user", "--jq", ".login"]), 2, calls)

    def test_the_explicit_config_path_is_forwarded_to_the_helper(self):
        text = '[workflow]\napproval_label = "ready:to-land"\n'
        for path in FIX_ASSETS:
            with self.subTest(asset=path.name):
                completed, harness = self.execute(
                    path,
                    lambda s: {"states": [s.pr(labels=("ready:to-land",))]},
                    config_text=text,
                    config_path=True,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(len(harness.pushes()), 1)
                # The default label alone would have refused: the file named
                # by the caller was the one read.
                refused, harness = self.execute(path, config_text=text, config_path=True)
                self.assertNotEqual(refused.returncode, 0)
                self.assertNoMutation(harness)

    # -- an initial refusal reaches nothing ------------------------------------

    def test_an_initial_refusal_prevents_every_later_step(self):
        refusals = {
            "no approval label": lambda s: {"states": [s.pr(labels=())]},
            "a changes-requested label": lambda s: {
                "states": [s.pr(labels=("reviewed:approve", "reviewed:changes"))]
            },
            "a blocking label": lambda s: {
                "states": [s.pr(labels=("reviewed:approve", "blocked"))]
            },
            "a marker for another head": lambda s: {
                "runs_of_comments": [feed(s.marker(STALE))]
            },
            "a changes-requested verdict": lambda s: {
                "runs_of_comments": [feed(s.marker(RECORDED, "CHANGES_REQUESTED"))]
            },
            "a self-review": lambda s: {
                "runs_of_comments": [feed(s.marker(RECORDED, "APPROVE", [s.brand]))]
            },
            "a newer non-approval over an older approval": lambda s: {
                "runs_of_comments": [feed(s.marker(), s.marker(RECORDED, "CHANGES_REQUESTED"))]
            },
            "the other brand's origin": lambda s: {"states": [s.pr(origin=s.other)]},
            "an unresolved publisher": lambda s: {"viewer": None},
        }
        for path in FIX_ASSETS:
            for reason, build in refusals.items():
                with self.subTest(asset=path.name, reason=reason):
                    completed, harness = self.execute(path, build)
                    self.assertNotEqual(completed.returncode, 0, completed.stdout)
                    self.assertIn("no head-bound approval at the recorded head", completed.stderr)
                    self.assertIn("the initial approval guard did not pass", completed.stderr)
                    self.assertNoMutation(harness)
                    # A refusal stops before the second, fresh read.
                    self.assertLessEqual(harness.gh_calls().count(self.VIEW), 1)

    def test_an_approval_evaluated_at_another_head_than_the_recorded_one_refuses(self):
        # The helper approves, and does so at the head IT read; the diagnosis
        # works on the head this run recorded. They must be one value.
        for path in FIX_ASSETS:
            for recorded in (STALE, ""):
                with self.subTest(asset=path.name, recorded=recorded or "unset"):
                    completed, harness = self.execute(path, recorded=recorded)
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertIn("no head-bound approval at the recorded head", completed.stderr)
                    self.assertNoMutation(harness)

    def test_the_guard_accepts_only_exit_zero_with_an_approved_true_result(self):
        refusal = json.dumps({"approved": False, "head": RECORDED, "reason": "scripted refusal"})
        approved = json.dumps({"approved": True, "head": RECORDED})
        cases = {
            "a nonempty refusal object with a nonzero status": (refusal, 1),
            "a refusal object with a zero status": (refusal, 0),
            "an approved result with a nonzero status": (approved, 1),
            "malformed output with a zero status": ("approved", 0),
            "an empty result with a zero status": ("", 0),
            "approved as a string": (json.dumps({"approved": "true", "head": RECORDED}), 0),
            "an approval naming no head": (json.dumps({"approved": True}), 0),
            "an approval naming another head": (json.dumps({"approved": True, "head": STALE}), 0),
            "a failed helper": ("", 2),
        }
        for path in FIX_ASSETS:
            for label, stub in cases.items():
                with self.subTest(asset=path.name, case=label):
                    completed, harness = self.execute(path, stub=stub)
                    self.assertNotEqual(completed.returncode, 0, completed.stdout)
                    self.assertNoMutation(harness)
        # The positive control for the table: the same stub with a real
        # approval of the recorded head reaches the push and the handoff.
        for path in FIX_ASSETS:
            with self.subTest(asset=path.name, case="the positive control"):
                completed, harness = self.execute(path, stub=(approved, 0))
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(len(harness.pushes()), 1)
                self.assertEqual(len(harness.handoffs()), 1)

    # -- authority withdrawn after the initial pass ------------------------------

    def test_approval_withdrawn_without_head_movement_stops_the_push(self):
        review_mode = '[workflow]\napproval_mode = "review"\n'

        def native(commit=RECORDED, state="APPROVED", identifier=1, when="2026-08-01T00:00:00Z"):
            return {
                "id": identifier,
                "submitted_at": when,
                "state": state,
                "user": {"login": "alice"},
                "commit_id": commit,
            }

        cases = {
            "the approval label removed": (None, lambda s: {
                "states": [s.pr(), s.pr(labels=())],
            }),
            "a newer non-approval marker": (None, lambda s: {
                "runs_of_comments": [
                    feed(s.marker()),
                    feed(s.marker(), s.marker(RECORDED, "CHANGES_REQUESTED")),
                ],
            }),
            "the marker gone from the feed": (None, lambda s: {
                "runs_of_comments": [feed(s.marker()), [[]]],
            }),
            "a changes-requested label": (None, lambda s: {
                "states": [s.pr(), s.pr(labels=("reviewed:approve", "reviewed:changes"))],
            }),
            "a blocking label": (None, lambda s: {
                "states": [s.pr(), s.pr(labels=("reviewed:approve", "blocked"))],
            }),
            "the origin becoming the other brand": (None, lambda s: {
                "states": [s.pr(), s.pr(origin=s.other)],
            }),
            "the origin marker removed": (None, lambda s: {
                "states": [s.pr(), {**s.pr(), "body": "Closes #7\n"}],
            }),
            "a native approval superseded": (review_mode, lambda s: {
                "states": [s.pr(labels=(), review_decision="APPROVED")] * 2,
                "runs_of_reviews": [
                    [[native()]],
                    [[native(), native(state="CHANGES_REQUESTED", identifier=2, when="2026-08-02T00:00:00Z")]],
                ],
            }),
            "a native approval dismissed": (review_mode, lambda s: {
                "states": [s.pr(labels=(), review_decision="APPROVED")] * 2,
                "runs_of_reviews": [[[native()]], [[native(state="DISMISSED")]]],
            }),
            "the aggregate review decision withdrawn": (review_mode, lambda s: {
                "states": [
                    s.pr(labels=(), review_decision="APPROVED"),
                    s.pr(labels=(), review_decision=""),
                ],
                "runs_of_reviews": [[[native()]], [[native()]]],
            }),
        }
        for path in FIX_ASSETS:
            for label, (config_text, build) in cases.items():
                with self.subTest(asset=path.name, withdrawal=label):
                    completed, harness = self.execute(path, build, config_text=config_text)
                    self.assertNotEqual(completed.returncode, 0, completed.stdout)
                    # It passed the initial guard and stopped at the fresh one.
                    self.assertIn("authority to push was lost", completed.stderr)
                    self.assertNoMutation(harness)
                    self.assertEqual(harness.gh_calls().count(self.VIEW), 2)

    def test_the_head_moving_before_the_push_stops_it_both_ways(self):
        cases = {
            # The new head carries no approval of its own.
            "an unapproved new head": lambda s: {
                "states": [s.pr(), s.pr(head=MOVED)],
                "runs_of_comments": [feed(s.marker()), feed(s.marker())],
            },
            # The new head IS approved -- and that is still not the head this
            # run diagnosed and edited, so the guard refuses on the mismatch.
            "an approved new head that is not the recorded one": lambda s: {
                "states": [s.pr(), s.pr(head=MOVED)],
                "runs_of_comments": [feed(s.marker()), feed(s.marker(MOVED))],
            },
        }
        for path in FIX_ASSETS:
            for label, build in cases.items():
                with self.subTest(asset=path.name, case=label):
                    completed, harness = self.execute(path, build)
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertIn("authority to push was lost", completed.stderr)
                    self.assertNoMutation(harness)

    def test_an_approval_of_a_moved_head_names_it_in_the_helper_result(self):
        # The mismatch case above is refused by the GUARD, not by the helper:
        # the helper approves the head it read, and says which one.
        path = CLAUDE_FIX
        scenario = Scenario(path)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        harness = GuardHarness(Path(directory.name))
        harness.script_github(
            states=[scenario.pr(head=MOVED)],
            runs_of_comments=[feed(scenario.marker(MOVED))],
        )
        completed = harness.run(
            'python3 "$CLAUDE_PLUGIN_ROOT/scripts/pr_head_approval.py" --policy fix '
            '--brand claude --repo "$REPO" --pr "$PR" --config ""'
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)["head"], MOVED)

    # -- the order the chain enforces --------------------------------------------

    def test_neither_the_push_nor_the_handoff_is_reachable_around_the_guards(self):
        skips = {
            "the pre-push guard skipped before the push": ("initial", "push"),
            "the pre-push guard skipped before the handoff": ("initial", "handoff"),
            "the pre-push guard run with no initial guard": ("pre_push",),
            "the push run with no guard at all": ("push",),
            "the handoff run with no guard at all": ("handoff",),
        }
        for path in FIX_ASSETS:
            for label, roles in skips.items():
                with self.subTest(asset=path.name, skipped=label):
                    completed, harness = self.execute(path, roles=roles)
                    self.assertNotEqual(completed.returncode, 0, completed.stdout)
                    self.assertNoMutation(harness)

    def test_every_guard_fence_parses_under_every_shell(self):
        for path in FIX_ASSETS:
            for role, fence in guard_fences(path).items():
                for shell in AVAILABLE_SHELLS:
                    with self.subTest(asset=path.name, fence=role, shell=shell):
                        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as handle:
                            handle.write(fence + "\n")
                        self.addCleanup(os.unlink, handle.name)
                        completed = subprocess.run(
                            [shell, "-n", handle.name],
                            stdin=subprocess.DEVNULL,
                            capture_output=True,
                            text=True,
                        )
                        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_the_fence_finder_is_not_vacuous(self):
        # The control for every `assertNoMutation` above: the chain really does
        # contain a push and a coordinator call, so an absence in the logs is
        # an absence the harness could have observed.
        for path in FIX_ASSETS:
            fences = guard_fences(path)
            self.assertEqual(len(fences), 4)
            self.assertIn("push", fences["push"])
            self.assertIn("review_pr.py", fences["handoff"] + read(path))


NUMBER_WORDS = {
    15: "fifteen",
    16: "sixteen",
    17: "seventeen",
    18: "eighteen",
    19: "nineteen",
    20: "twenty",
    21: "twenty-one",
    22: "twenty-two",
    23: "twenty-three",
    24: "twenty-four",
    25: "twenty-five",
    26: "twenty-six",
    27: "twenty-seven",
    28: "twenty-eight",
}

BUNDLE_READMES = {
    "claude": (
        "claude-plugin/README.md",
        "claude-plugin/plugins/kanban/commands",
    ),
    "codex": (
        "codex-plugin/README.md",
        "codex-plugin/plugins/kanban/skills",
    ),
}

# The issue-to-pull-request workflows (the HASKELL_PARITY set), which every README states as the
# complement of its user-invoked count. Restated here rather than imported,
# because the plugin modules that own it are not importable under this
# module's own load path.
HASKELL_SPAWNED = {"solve", "pr-review", "pr-rereview", "pr-revise"}


def workflow_names_from_paths(prefix: str, paths) -> set[str]:
    """The workflows `paths` ships, by each brand's own asset shape.

    Claude ships `commands/<name>.md`; Codex ships `skills/<name>/SKILL.md`.
    Both shapes are matched exactly rather than by taking a path's first
    component, because those are not the same question once a bundle ships
    anything else: a `skills/<name>/` directory carrying scripts and no
    `SKILL.md` ships no workflow at all, and `tools/plugin_bundle_gate.py`
    derives the installable set by the same rule. Issue #574 created the first
    such directory when it vendored the janitor census a slice ahead of the
    body that calls it, and issue #575 added that body, so `skills/janitor/`
    now ships both a `SKILL.md` and a `scripts/` sibling. Neither state is the
    one this rule is written for: a first-component reading counts the helper
    directory as a workflow while no `SKILL.md` is there to justify it, and
    goes on counting `skills/janitor/scripts/census.py` as a second `janitor`
    once one is. The exact-shape match is right in both, and the synthetic
    listing below drives it over a directory of each shape rather than over
    whatever the tree happens to hold today.

    Pure, and separate from the `git ls-files` call, so the rule can be driven
    over a listing that contains such a directory rather than only over
    whatever the tree happens to hold today.
    """
    names = set()
    for path in paths:
        tail = path[len(prefix) :].lstrip("/")
        if not tail:
            continue
        parts = tail.split("/")
        if len(parts) == 1 and parts[0].endswith(".md"):
            names.add(parts[0].removesuffix(".md"))
        elif len(parts) == 2 and parts[1] == "SKILL.md":
            names.add(parts[0])
    return names


def shipped_workflow_names(prefix: str) -> set[str]:
    """Every workflow the tracked bundle at `prefix` actually ships."""
    import subprocess

    listed = subprocess.run(
        ["git", "ls-files", prefix],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return workflow_names_from_paths(prefix, listed)


class BundleReadmeInventoryTests(unittest.TestCase):
    """Each bundle README's counting prose matches what the bundle ships."""

    def test_shipped_names_are_recoverable_and_nonempty(self):
        # Non-vacuous anchor: a helper that recovered nothing would make every
        # assertion below pass while checking nothing at all.
        for brand, (_, prefix) in BUNDLE_READMES.items():
            names = shipped_workflow_names(prefix)
            self.assertGreaterEqual(len(names), 20, brand)
            self.assertIn("fix", names, brand)
            self.assertTrue(HASKELL_SPAWNED < names, brand)

    def test_a_scripts_only_directory_ships_no_workflow(self):
        # The rule the README totals rest on, driven over a listing that holds
        # both shapes plus a helper directory. Taking a path's first component
        # would recover "helper" here, and would inflate every total below.
        prefix = "codex-plugin/plugins/kanban/skills"
        self.assertEqual(
            workflow_names_from_paths(
                prefix,
                [
                    f"{prefix}/solve/SKILL.md",
                    f"{prefix}/solve/scripts/trusted_issue_spec.py",
                    f"{prefix}/helper/scripts/census.py",
                    f"{prefix}/helper/scripts/kanban_config.py",
                ],
            ),
            {"solve"},
        )
        # ...and the Claude shape is still a flat `<name>.md`, so a file one
        # level down is not a command either.
        claude = "claude-plugin/plugins/kanban/commands"
        self.assertEqual(
            workflow_names_from_paths(
                claude, [f"{claude}/solve.md", f"{claude}/scripts/census.py"]
            ),
            {"solve"},
        )

    def test_the_codex_half_agrees_with_the_installable_bundle_gate(self):
        # One rule, one spelling: `tools/plugin_bundle_gate.py` is the
        # authority on what a Codex installation can invoke, so the set these
        # README counts are taken from has to be the set it derives. Bound to
        # the real tree, so a helper directory that started shipping a
        # SKILL.md would move both sides together rather than only one.
        import plugin_bundle_gate

        prefix = BUNDLE_READMES["codex"][1]
        self.assertEqual(
            shipped_workflow_names(prefix),
            plugin_bundle_gate.tracked_skill_names(REPO_ROOT, prefix),
        )

    def test_every_readme_names_every_workflow_it_ships(self):
        missing = []
        for brand, (readme, prefix) in BUNDLE_READMES.items():
            text = (REPO_ROOT / readme).read_text(encoding="utf-8")
            for name in sorted(shipped_workflow_names(prefix)):
                if name not in text:
                    missing.append(f"{readme}: does not name {name!r}")
        self.assertEqual(missing, [], "\n".join(missing))

    def test_every_readme_total_count_matches_what_is_shipped(self):
        for brand, (readme, prefix) in BUNDLE_READMES.items():
            total = len(shipped_workflow_names(prefix))
            word = NUMBER_WORDS[total]
            text = (REPO_ROOT / readme).read_text(encoding="utf-8")
            # Every "<word> ... workflows/commands/skills" claim must be the
            # real total, and no OTHER number word may be used for it.
            for candidate, other in NUMBER_WORDS.items():
                if candidate == total:
                    continue
                for noun in ("workflow", "workflows", "commands", "skills"):
                    self.assertNotIn(
                        f"{other} packaged {noun}",
                        text,
                        f"{readme} states {other} packaged {noun}, but the "
                        f"bundle ships {total}",
                    )
            self.assertIn(
                f"{word} packaged",
                text,
                f"{readme} never states its real packaged total ({word})",
            )

    def test_every_readme_user_invoked_count_is_the_complement(self):
        for brand, (readme, prefix) in BUNDLE_READMES.items():
            shipped = shipped_workflow_names(prefix)
            user_invoked = len(shipped - HASKELL_SPAWNED)
            word = NUMBER_WORDS[user_invoked]
            text = (REPO_ROOT / readme).read_text(encoding="utf-8")
            self.assertIn(
                f"The other {word} are",
                text,
                f"{readme} does not state {word} user-invoked workflows "
                f"({len(shipped)} shipped minus {len(HASKELL_SPAWNED)} spawned)",
            )
            for candidate, other in NUMBER_WORDS.items():
                if candidate == user_invoked:
                    continue
                self.assertNotIn(
                    f"The other {other} are",
                    text,
                    f"{readme} states {other} user-invoked workflows, but the "
                    f"complement is {user_invoked}",
                )



if __name__ == "__main__":
    unittest.main()
