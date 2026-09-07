"""Behavioral contract coverage for the packaged fix workflow.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

`tools/test_claude_plugin.py` and `tools/test_codex_plugin.py` pin that both
plugins *discover* a `fix` workflow and that it sits outside the Haskell
name-parity set, since Kanban's own CLI spawns `repair` for a Done-column card
and never this. Discovery and name parity are not the contract, though: `fix`
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

`RepairDelegationTests` is the negative control this module owes under
CLAUDE.md's "Quality gates": the fix-specific rules are asserted absent from the
repair pair, so a phrase table that had degenerated into fragments present in
every packaged workflow would fail here rather than pass everywhere.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

FIX_SOURCE = REPO_ROOT / "tools/command_sources/fix.md"
CODEX_FIX = REPO_ROOT / "codex-plugin/plugins/kanban/skills/fix/SKILL.md"
CLAUDE_FIX = REPO_ROOT / "claude-plugin/plugins/kanban/commands/fix.md"

FIX_ASSETS = (CODEX_FIX, CLAUDE_FIX)

CODEX_REPAIR = REPO_ROOT / "codex-plugin/plugins/kanban/skills/repair/SKILL.md"
CLAUDE_REPAIR = REPO_ROOT / "claude-plugin/plugins/kanban/commands/repair.md"

REPAIR_ASSETS = (CODEX_REPAIR, CLAUDE_REPAIR)

WORKFLOW_HS = REPO_ROOT / "src/Kanban/Workflow.hs"
DRAINER = REPO_ROOT / "tools/drain_prs.py"
FINALIZE_SOURCE = REPO_ROOT / "tools/command_sources/finalize.md"

COORDINATORS = (
    REPO_ROOT / "codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py",
    REPO_ROOT / "claude-plugin/plugins/kanban/scripts/review_pr.py",
)

# Every shell variable the assets point a redirect at. The hygiene rules below
# are asserted over this tuple rather than over one hard-coded name, because a
# rule naming only the first scratch file would leave a later one unmeasured --
# and the head-binding evidence fences added two.
SCRATCH_VARIABLES = ("ROLLUP", "COMMENTS", "REVIEWS")

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
        "Kanban's own CLI resolves a pull request's origin and spawns the "
        "matching\nbrand's executable"
    ),
    "the-origin-rules-are-the-haskell-ones": (
        "apply exactly the\nrules `originFromBody` applies in "
        "`src/Kanban/PullRequestFlow.hs`: the body must\ncarry exactly ONE "
        "marker, of exactly one kind, as its final non-whitespace\ncontent."
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
    # The defect this pair pins, observed live: review-gate dismissed a stale
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
        "`label` requires the canonical-marker evidence below, `review` "
        "requires the\nnative-approval evidence below, and `either` is met "
        "by whichever of the two\nholds — one path failing never vetoes "
        "valid evidence from the other."
    ),
    "problem-labels-refuse-under-every-mode": (
        "The\nconfigured changes-requested and blocking labels remain "
        "unconditional refusals\nunder every mode and are weighed against "
        "neither path."
    ),
    "an-unresolved-publisher-fails-closed": (
        "Resolve the authenticated publisher first, and fail closed when it "
        "cannot be\nresolved: an unresolved login makes every ownership test "
        "below vacuously true."
    ),
    "the-whole-paginated-comment-feed-is-read": (
        "Read the COMPLETE paginated feed rather than a bounded view — on a "
        "long pull\nrequest the newest marker falls outside a capped one, "
        "and an older verdict\nwould then speak for a head nobody reviewed."
    ),
    "the-marker-is-selected-by-recency-before-it-is-tested": (
        "Among the comments that publisher\nwrote, select the newest "
        "marker-bearing comment by creation time with the\ncomment id "
        "breaking ties, and only THEN test what it says. Accept the\n"
        "established v2 shape and the legacy v1 shape."
    ),
    "the-label-path-needs-a-current-head-approve-marker": (
        "The configured approval label stays necessary and stops being "
        "sufficient, in\n`either` mode exactly as in `label` mode. The "
        "`label` path is met only when\nthat label is still attached, the "
        "selected comment carries `verdict=APPROVE`,\nits `head=` equals the "
        "current `headRefOid`, and its `reviewers=` list does not\nname the "
        "origin brand step 2b validated"
    ),
    "missing-or-malformed-evidence-never-falls-back": (
        "**Missing evidence, an unreadable feed, and\na malformed or "
        "multiply-markered selected comment each leave this path unmet\n"
        "rather than falling back to an older approval**, and so does a "
        "newer\nnon-approval standing over an older approval: the selection "
        "is by recency, not\nby verdict."
    ),
    "the-aggregate-review-decision-is-necessary-not-sufficient": (
        "`reviewDecision == APPROVED` stays necessary and stops being "
        "sufficient: it is\nan aggregate over the pull request, not a "
        "statement about a commit."
    ),
    "the-effective-review-per-author-is-the-native-evidence": (
        "Keep only the opinionated reviews — `APPROVED` and "
        "`CHANGES_REQUESTED` — and\nfor each author keep only their newest "
        "one by `submitted_at`, with the review\nid breaking ties. A "
        "`DISMISSED` review is not evidence, and an author's later\nopinion "
        "supersedes their earlier one."
    ),
    "the-review-path-needs-an-approval-naming-the-current-commit": (
        "**The `review` path is met only when one\nof those surviving "
        "reviews is `APPROVED` and its `commit_id` equals the current\n"
        "`headRefOid`.**"
    ),
    "stale-or-unattributed-native-approval-is-insufficient": (
        "A superseded or dismissed approval, the aggregate\n"
        "`reviewDecision` on its own, and a review whose commit attribution "
        "is absent or\nunreadable are each insufficient rather than assumed "
        "current."
    ),
    "the-refusal-names-both-heads-or-says-there-is-none": (
        "Report the mismatch concretely and stop: the current `headRefOid`, "
        "the head the\napproval actually belongs to when the evidence names "
        "one, and — when it does\nnot — that the evidence is missing or "
        "unreadable rather than naming any head at\nall."
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
        "**Re-run step 2c against freshly fetched evidence as well.** "
        "Re-read the\ncomment feed for the `label` path, or the reviews for "
        "the `review` path,\nwhichever the configured mode selected, and "
        "re-establish the head binding from\nwhat comes back."
    ),
    "a-cached-initial-reading-cannot-answer-for-the-push": (
        "The marker read at step 2c and the reviews read there cannot\n"
        "answer for this moment: a canonical verdict can be superseded and a "
        "native\napproval dismissed while the head never moves, so a cached "
        "initial reading\nwould carry an authority that has since been "
        "withdrawn straight into the push."
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
    # --- Head safety, inherited from the repair contract by construction. ---
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
        "After that head check and IMMEDIATELY before the push, re-read the pull "
        "request from the resolved repository with the same authority-bearing "
        "fields step 2 used"
    ),
    "reapplies-approval-problem-label-and-origin-gates": (
        "Reapply step 2's configured approval decision to that FRESH `labels` "
        "and `reviewDecision`, reapply its configured changes-requested and "
        "blocking-label refusal, and reapply step 2b's complete origin-marker "
        "parse — including that the result still names THIS bundle's active brand."
    ),
    "lost-pre-push-authority-stops-without-pushing": (
        "If approval was withdrawn, the selected mode's head-bound evidence no "
        "longer holds, any configured problem label appeared, the origin "
        "became missing, malformed, or a different brand, or the head no "
        "longer matches, STOP with no push and no rereview."
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

# Requirements that belong to fix alone. The repair pair must carry none of
# them, which is what proves the table above is measuring this workflow rather
# than matching text every packaged workflow happens to contain.
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
    "the-origin-rules-are-the-haskell-ones",
    "every-malformed-origin-is-a-refusal-not-a-default",
    "a-wrong-brand-origin-stops-with-nothing-changed",
    "why-the-origin-gate-exists",
    "the-worktree-step-serves-only-head-moving-branches",
    "a-diagnosis-is-not-authorisation",
    "a-why-question-is-answered-without-mutating",
    "an-ambiguous-request-is-read-as-diagnostic",
    "approval-is-required-before-diagnosis",
    "approval-is-configured-not-a-fixed-string",
    "approval-modes-are-read-never-accepted-on-their-own",
    "an-unbound-signal-is-never-sufficient",
    "head-bound-approval-is-required-before-anything-mutates",
    "why-an-unbound-approval-is-authority-over-unreviewed-code",
    "the-drainer-already-keys-on-the-approved-head",
    "carrying-the-approval-forward-is-not-available-here",
    "the-two-evidence-paths-are-weighed-independently",
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

    def test_the_marker_rules_the_assets_cite_really_exist(self):
        # Non-vacuous anchor: the assets tell an agent to apply
        # `originFromBody`'s rules, so those rules must still be the ones the
        # Haskell enforces.
        flow = read(REPO_ROOT / "src/Kanban/PullRequestFlow.hs")
        self.assertIn("originFromBody :: Text -> Either Text PullRequestOrigin", flow)
        for rejection in (
            "PR body contains both pr-origin markers",
            "PR body contains a duplicate pr-origin marker",
            "PR origin marker must be the final non-whitespace content",
            "PR body has no valid pr-origin marker",
        ):
            self.assertIn(rejection, flow, f"originFromBody no longer rejects: {rejection}")


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
    read bounds diagnosis, while a second read immediately before push closes
    the window in which authority can be withdrawn without changing the SHA.
    """

    PR_VIEW_PREFIX = "gh pr view <pr> -R <owner/name> --json "

    def test_both_assets_fetch_authority_metadata_twice(self):
        for path in FIX_ASSETS:
            text = read(path)
            self.assertEqual(
                text.count(self.PR_VIEW_PREFIX),
                2,
                f"{path} must read the PR once for diagnosis and once before push",
            )

    def test_the_second_read_carries_every_mutable_gate_field(self):
        for path in FIX_ASSETS:
            text = read(path)
            second = text.rindex(self.PR_VIEW_PREFIX)
            command_end = text.index("\n", second)
            command = text[second:command_end]
            for field in ("body", "headRefOid", "labels", "reviewDecision"):
                self.assertIn(field, command, f"{path}: pre-push read omits {field}")

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

    def test_repair_still_holds_the_same_prohibition(self):
        for path in REPAIR_ASSETS:
            self.assertIn("no retry loops", read(path))


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
    docs/agent-workflow-contract.md its own section, the way §2.7 gives repair
    one.
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
        # The two properties that make this action different from repair.
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
    # rendered assets by the table above and ABSENT from the repair pair by
    # RepairDelegationTests, so this tuple is the join between the two.
    HEAD_BINDING_RULES = (
        "approval-modes-are-read-never-accepted-on-their-own",
        "an-unbound-signal-is-never-sufficient",
        "head-bound-approval-is-required-before-anything-mutates",
        "why-an-unbound-approval-is-authority-over-unreviewed-code",
        "the-drainer-already-keys-on-the-approved-head",
        "carrying-the-approval-forward-is-not-available-here",
        "the-two-evidence-paths-are-weighed-independently",
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
                f"{requirement} is not in the repair negative control",
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
        # all: the newest marker or review can be the one outside the cap.
        for path in FIX_ASSETS:
            text = read(path)
            for command in (
                'gh api --paginate --slurp '
                '"repos/<owner>/<name>/issues/<pr>/comments?per_page=100" '
                '> "$COMMENTS"',
                'gh api --paginate --slurp '
                '"repos/<owner>/<name>/pulls/<pr>/reviews?per_page=100" '
                '> "$REVIEWS"',
            ):
                self.assertIn(command, text, f"{path} omits: {command}")

    def test_the_binding_is_re_established_inside_the_pre_push_gate(self):
        # The re-read has to sit between the remote-head check and the push,
        # in the same window step 4's other authority checks occupy.
        for path in FIX_ASSETS:
            text = read(path)
            fresh_gate = text.index("IMMEDIATELY before the push")
            rebind = text.index(
                "**Re-run step 2c against freshly fetched evidence as well.**"
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
        for path in FIX_ASSETS:
            self.assertIn("`latest_owned_review_marker`", read(path))

    def test_the_selection_rule_matches_the_finalize_gate_it_cites(self):
        # Non-vacuous anchor for "newest by creation time, comment id breaking
        # ties": that is the ordering finalize's gate actually implements, and
        # the assets point a reader at it by name.
        gate = read(FINALIZE_SOURCE)
        self.assertIn(
            'key=lambda item: (str(item.get("created_at") or ""), '
            'int(item.get("id") or 0)),',
            gate,
            "finalize's gate no longer orders the feed by created_at then id",
        )
        self.assertIn("reverse=True,", gate)

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


class VacuousRuleControlTests(unittest.TestCase):
    """The negative control the new rules owe, exercised rather than asserted.

    `RepairDelegationTests` proves today's table is fix-specific, but it does
    that by passing -- on a table that had decayed into fragments common to
    every packaged workflow it would fail, and nothing demonstrates that it
    still CAN. These two tests run the same predicates over a deliberately
    vacuous phrase and require them to reject it, so "the head-binding rules
    are not vacuous" is a measured property rather than a claim.
    """

    VACUOUS_PHRASE = "the pull request"

    def test_a_phrase_present_in_every_asset_fails_the_fix_only_control(self):
        # The phrase matches every fix asset, so the positive test would pass
        # on it. The repair control is what has to refuse it.
        for path in FIX_ASSETS:
            self.assertIn(self.VACUOUS_PHRASE, flat(read(path)))
        leaked = [
            path.relative_to(REPO_ROOT)
            for path in REPAIR_ASSETS
            if self.VACUOUS_PHRASE in flat(read(path))
        ]
        self.assertNotEqual(
            leaked,
            [],
            "a phrase common to every packaged workflow slipped past the "
            "repair negative control, which therefore proves nothing about "
            "the head-binding rules either",
        )

    def test_a_head_binding_rule_is_absent_from_the_repair_pair(self):
        # The other half of the same control: a real rule must NOT match, or
        # the test above would be refusing everything indiscriminately.
        for requirement in HeadBoundApprovalTests.HEAD_BINDING_RULES:
            phrase = flat(REQUIRED_PHRASES[requirement])
            for path in REPAIR_ASSETS:
                self.assertNotIn(
                    phrase,
                    flat(read(path)),
                    f"{path.relative_to(REPO_ROOT)} carries {requirement}",
                )


class RepairDelegationTests(unittest.TestCase):
    """The negative control CLAUDE.md's quality gates require.

    Every rule that belongs to fix alone is asserted ABSENT from the repair
    pair. Without this, a phrase table that had decayed into fragments common
    to every packaged workflow would pass the positive test above while
    asserting nothing about this workflow in particular.
    """

    def test_repair_carries_none_of_the_fix_only_rules(self):
        leaked = []
        for path in REPAIR_ASSETS:
            text = read(path)
            flattened = flat(text)
            for requirement in FIX_ONLY_REQUIREMENTS:
                if flat(REQUIRED_PHRASES[requirement]) in flattened:
                    leaked.append(f"{path.relative_to(REPO_ROOT)}: {requirement}")
        self.assertEqual(
            leaked,
            [],
            "repair must not carry fix's approval or origin gates:\n"
            + "\n".join(leaked),
        )

    def test_the_fix_only_set_is_a_real_subset_of_the_required_table(self):
        self.assertTrue(set(FIX_ONLY_REQUIREMENTS) < set(REQUIRED_PHRASES))
        self.assertGreaterEqual(len(FIX_ONLY_REQUIREMENTS), 10)

    def test_both_workflows_now_agree_about_retrying(self):
        # These two once disagreed: fix was going to retry an infrastructure
        # failure that repair refuses. Dropping that capability makes the rule
        # one rule, held in both places, with the drainer as the only
        # rerunner -- so the agreement is asserted rather than left to drift
        # back apart.
        for path in REPAIR_ASSETS:
            self.assertIn("no retry loops", read(path))
        for path in FIX_ASSETS:
            self.assertIn(
                "This workflow does not retry a red check, ever.", read(path)
            )


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

# The workflows Kanban's own Haskell spawns, which every README states as the
# complement of its user-invoked count. Restated here rather than imported,
# because the plugin modules that own it are not importable under this
# module's own load path.
HASKELL_SPAWNED = {"solve", "pr-review", "pr-rereview", "pr-revise", "repair"}


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
