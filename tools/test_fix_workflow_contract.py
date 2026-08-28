"""Behavioral contract coverage for the packaged fix workflow.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

`tools/test_claude_plugin.py` and `tools/test_codex_plugin.py` pin that both
plugins *discover* a `fix` workflow and that it sits outside the Haskell
name-parity set, since Kanban's own CLI spawns `repair` for a Done-column card
and never this. Discovery and name parity are not the contract, though: `fix`
may rerun a red required check without changing a line, which is an authority
no other packaged workflow has, so what the packaged text actually instructs an
agent to do is the part that must not drift.

Both assets are rendered from one source by
`tools/render_command_sources.py`, so the two brands cannot diverge by an
unsynchronised hand edit. They can still diverge from their *contract* through
an edit to that single source, which is what this module measures. It asserts
against BOTH rendered outputs rather than the source, because the rendered
files are what an agent actually executes, and because a phrase that survives
rendering is one that survived sigil substitution and brand-block projection.

Three groups of requirement are checked as text the workflow states in terms an
agent will act on: the approval precondition that makes the rerun branch safe,
the triage rule separating an infrastructure failure from a real one together
with its one-rerun ceiling, and the push/rereview authority boundary --
specifically that a rerun pushes no head and therefore invokes no rereview,
while a code fix does both.

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
    "a-diagnosis-is-not-authorisation": (
        "**A diagnosis is not authorisation.** This workflow reruns checks, "
        "commits,\npushes, and hands off a rereview, so it runs only when the "
        "user asked in that\nturn for the pull request to be fixed, unblocked, "
        "or made mergeable."
    ),
    "a-why-question-is-answered-without-mutating": (
        '"Why can\'t\nthis merge?" and "what is blocking this?" ask for none of '
        "that: answer them by\nrunning step 2 and step 3, reporting the obstacle "
        "you found, and stopping there\n— no rerun, no worktree, no push."
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

    # --- The approval precondition, and why it is what licenses the rerun. ---
    "approval-is-required-before-diagnosis": (
        "This workflow acts only on an approved pull request."
    ),
    "approval-is-what-makes-the-rerun-safe": (
        "Approval is the whole\nreason its rerun branch in step 5 is safe: on work a "
        "reviewer has already\naccepted, a red check is far more likely to be "
        "infrastructure than a defect the\nreview missed."
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
    "approval-modes-are-all-three-honoured": (
        "Honour the configured mode: `label` accepts the\n"
        "configured approval label, `review` accepts GitHub's own `reviewDecision ==\n"
        "APPROVED`, and `either` accepts one or both."
    ),
    "an-unapproved-pull-request-stops-having-changed-nothing": (
        "Stop, having changed nothing, when the pull request is not approved under the\n"
        "resolved mode, or when it carries a configured changes-requested or blocking\n"
        "label."
    ),
    "a-blocking-label-is-never-removed-to-proceed": (
        "Never remove a\nblocking label to proceed: a blocking label is a human's "
        "decision."
    ),
    # --- A pull request behind its base is unmergeable, not clear. ---
    "an-untrustworthy-rollup-is-its-own-branch": (
        "3. **A rollup you cannot trust** — before any branch below is allowed "
        "to\n   clear or mutate the pull request, the check rollup must be "
        "COMPLETE and\n   every entry in it classifiable."
    ),
    "completeness-is-established-by-the-same-comparison-kanban-makes": (
        "Compare that `totalCount` against the number of entries the step-5 "
        "rollup\n   command returned. They must be equal — the same comparison\n"
        "   `src/Kanban/GitHub/Decode.hs` makes before it decodes a single "
        "context."
    ),
    "an-untrustworthy-rollup-fails-closed": (
        "**A truncated rollup, or any entry you cannot classify, fails "
        "closed:**\n   report that the check state cannot be read completely "
        "and stop without\n   pushing, rerunning, or invoking a rereview."
    ),
    "why-an-incomplete-rollup-is-not-an-absence": (
        "An incomplete rollup can be\n   hiding exactly the failed or pending "
        "entry the branches below test for, so\n   treating it as absence "
        'would turn "I did not see one" into "there is none".'
    ),
    "a-pending-check-mutates-nothing": (
        "4. **A check still running** — no conflict, no failed check, a rollup "
        "you can\n   trust, and a pending entry in it. This branch MUTATES "
        "NOTHING."
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
        "This branch fails closed: report the exact merge state, say\n   that "
        "this workflow has no remedy for it, and stop without pushing,\n   "
        "rerunning, or invoking a rereview."
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
    "the-ceiling-is-read-from-github-not-memory": (
        "**The ceiling is read from GitHub, not from memory.** Before "
        "rerunning any run,\nask it how many attempts it has already had:"
    ),
    "an-attempt-above-one-is-already-spent": (
        "A first attempt reports `1`. **Anything greater than 1 means this run "
        "has\nalready been rerun** — by an earlier invocation of this "
        "workflow, by the PR\ndrainer, or by a person — so it is not rerun "
        "again"
    ),
    "the-remote-counter-is-what-spans-invocations": (
        'This is what makes "never a\nsecond" hold across invocations rather '
        "than only within one, and it needs no\ndurable state of this "
        "workflow's own"
    ),
    "the-rerun-requires-attempt-one": (
        "**Only when EVERY failed run is an infrastructure failure AND every "
        "one of them\nis still on attempt 1**"
    ),
    "the-whole-diagnosis-is-rerun-afterwards": (
        "Clearing the failure is not the same\nas clearing the obstacle: a "
        "pull request can carry a failed check AND an\nunrelated pending one"
    ),
    "a-post-rerun-obstacle-is-reported-not-acted-on": (
        "* **Branch 1, 2 or 5, another head-moving obstacle** — report it and "
        "stop.\n  Do NOT act on it in this invocation: the rerun already spent "
        "this run's\n  allowance"
    ),

    # --- Triage: what may be rerun, and what may never be. ---
    "triage-precedes-any-edit": (
        "Triage them through step 5 before changing a single file."
    ),
    "infrastructure-failure-is-defined-by-what-executed": (
        "**An infrastructure failure is one where no job that executed the pull\n"
        "request's code reported a failure.**"
    ),
    "infrastructure-failure-is-read-from-the-jobs": (
        "Decide by what executed, never by the check's name and never by how "
        "the\nfailure feels:"
    ),
    "the-governing-test-outranks-its-examples": (
        "That sentence is the whole test, and the\nexamples below are "
        "subordinate to it: an example that turns out to have\nexecuted the "
        "tree is a REAL failure, whatever it is called."
    ),
    "the-eviction-signature-is-named": (
        "Concurrency-group\neviction is the canonical case: a setup job is "
        "cancelled with no steps, the\njobs needing it are skipped, and a "
        "summary job fails asserting they succeeded,\nhaving built nothing."
    ),
    "a-timeout-is-not-automatically-infrastructure": (
        "**A timeout is not automatically infrastructure**, and it is the one "
        "that will\ntempt you."
    ),
    "a-timeout-after-checkout-is-the-code-failing": (
        "A job that checked out the tree and then hung — an infinite loop, a\n"
        "deadlock, a performance regression that pushed a suite past its limit "
        "— timed\nout BECAUSE of the pull request's code"
    ),
    "a-timeout-is-infrastructure-only-before-the-tree-runs": (
        "a timeout counts as infrastructure only where the evidence\nshows no "
        "step had begun executing the tree"
    ),
    "a-flaky-failure-is-a-real-failure-here": (
        "A failure you\n"
        "believe is flaky is a real failure for this workflow's purposes: it "
        "executed the\ncode and it reported a result."
    ),
    "a-real-failure-is-never-rerun": (
        "never rerun a real\nfailure to see whether it passes the second time."
    ),
    "a-real-failure-is-never-papered-over": (
        "Never delete or skip a test, never weaken an assertion"
    ),
    "a-pre-existing-failure-stops-the-run": (
        "A failure you judge to be\npre-existing on the recorded base branch "
        "must be reported to the user and stop\nthe run rather than papered over."
    ),
    # --- The ceiling. ---
    "a-real-failure-anywhere-still-reruns-nothing": (
        "**If ANY failed run is a real failure**, take the fix path for all of "
        "them"
    ),
    "the-rerun-is-the-whole-run-never-failed-only": (
        '**Never `--failed` here.** That flag reruns "only failed jobs, '
        'including\ndependencies", and a CANCELLED job is not a failed one — '
        "which is precisely the\nsignature 5b defines this branch by."
    ),
    "failed-only-would-silently-accomplish-nothing": (
        "A run whose bad jobs are all cancellations\noffers `--failed` nothing "
        "to act on, so the retry silently accomplishes nothing\nand the run "
        "stays red; the allowance is spent on a rerun that never happened."
    ),
    "a-real-failure-anywhere-reruns-nothing": (
        "**If ANY failed run is a real failure**, take the fix path for all of "
        "them"
    ),
    "a-rerun-beside-a-real-failure-clears-nothing": (
        "Rerun nothing — a rerun that ran beside a real failure would clear one "
        "red check\nand leave the pull request just as unmergeable, having spent "
        "the allowance."
    ),
    "one-rerun-then-stop": (
        "**One rerun per run, then stop. There is never a second for the same "
        "run.**"
    ),
    "the-whole-rollup-is-refetched-after-a-rerun": (
        "Wait for every rerun to finish, then RE-FETCH the pull request and "
        "run **step\n3's whole diagnosis again** against what it says now — "
        "never the reruns' own\noutcomes, and never the failed set alone."
    ),
    "a-post-rerun-non-mutating-stop-is-honoured": (
        "* **Branch 3, 4 or 6, a non-mutating stop** — report what it now says "
        "and stop,\n  exactly as those branches specify."
    ),
    "only-the-nothing-to-fix-branch-clears-the-obstacle": (
        "* **Branch 7, nothing to fix** — the obstacle really is cleared and "
        "this\n  workflow is done."
    ),
    "a-non-actions-check-fails-closed": (
        "**A failed entry of the second kind fails closed.** Report it by name, "
        "say that\nthis workflow cannot classify or rerun an external check, and "
        "stop"
    ),
    "a-non-actions-check-is-never-given-a-run-command": (
        "Never issue `gh run view` or\n  `gh run rerun` against it, and never "
        "guess a run id for it."
    ),
    "the-run-id-comes-from-the-details-url": (
        "A **`CheckRun` whose `detailsUrl` names this repository's own\n  "
        "`/actions/runs/<run-id>`** is a GitHub Actions job."
    ),
    "the-run-not-the-entry-is-the-unit": (
        "several failed entries commonly share ONE run id, and the run — not\n  "
        "the entry — is the unit everything below acts on."
    ),
    "the-ceiling-differs-from-the-drainers-on-purpose": (
        "This ceiling is deliberately tighter than the PR drainer's. "
        "`tools/drain_prs.py`\nretries a failed required check up to its own "
        "`MAX_CI_RERUN_ATTEMPTS`"
    ),
    "neither-ceiling-may-be-changed-to-match-the-other": (
        "Neither\nceiling is the other's bug. Do not raise this one to match "
        "the drainer's, and do\nnot lower the drainer's to match this one."
    ),
    "the-ceiling-exists-to-surface-evidence": (
        "A failure that survives one rerun is evidence, and burying it under a "
        "third\nattempt is exactly what this ceiling exists to prevent."
    ),
    # --- Authority: what a rerun does and does not invalidate. ---
    "a-rerun-pushes-nothing-so-approval-stands": (
        "Rerunning changes no file and pushes no commit, so the head SHA the approval "
        "was\ngranted against is unchanged and that approval still stands."
    ),
    "a-rerun-invokes-no-rereview-and-no-label": (
        "A rerun therefore\nnever invokes a rereview and never touches a label."
    ),
    "a-push-invalidates-the-approval": (
        "Do not assume\nthe pull request is still approved after you push — it is "
        "not, because the\napproval named the SHA you replaced."
    ),
    "exactly-one-rereview-after-a-push": (
        "When you pushed a new head, finish by invoking exactly one canonical rereview"
    ),
    "no-push-means-no-rereview": (
        "When you pushed nothing — the rerun branch, the nothing-to-fix branch, or a "
        "stop\nin step 2 or step 5 — there is no new head, so invoke no rereview and "
        "simply\nreport what you found."
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
    "verifies-the-push-actually-advanced-the-head": (
        "a push that left the head unchanged\ntransferred no fix, so treat it as "
        "having pushed nothing, invoke no rereview,\nand report it."
    ),
    "a-rerun-needs-no-worktree": (
        "A\nrerun changes no file and needs no worktree at all,"
    ),
    "the-worktree-step-covers-all-three-head-moving-obstacles": (
        "This step applies only when step 3 or step 5 concluded that the head "
        "must\nmove — a merge conflict, a base the head is behind, or a real "
        "check failure."
    ),
    "a-pending-check-needs-no-worktree-either": (
        "neither does a pending\ncheck, which mutates nothing at all."
    ),
    "never-switches-the-primary-checkout": (
        "Never switch the repository's primary checkout."
    ),
}

# The obstacle branches, in the order the workflow must address them.
DIAGNOSIS_ORDER = (
    "**Merge conflict**",
    "**Failed check**",
    "**A rollup you cannot trust**",
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
    "an-untrustworthy-rollup-fails-closed",
    "completeness-is-established-by-the-same-comparison-kanban-makes",
    "why-an-incomplete-rollup-is-not-an-absence",
    "a-pending-check-mutates-nothing",
    "pending-outranks-behind-as-it-does-in-the-haskell",
    "why-pending-outranks-behind",
    "a-pending-check-needs-no-worktree-either",
    "behind-the-base-is-its-own-obstacle",
    "a-post-rerun-obstacle-is-reported-not-acted-on",
    "the-whole-diagnosis-is-rerun-afterwards",
    "the-rerun-requires-attempt-one",
    "the-remote-counter-is-what-spans-invocations",
    "an-attempt-above-one-is-already-spent",
    "the-ceiling-is-read-from-github-not-memory",
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
    "a-diagnosis-is-not-authorisation",
    "a-why-question-is-answered-without-mutating",
    "an-ambiguous-request-is-read-as-diagnostic",
    "approval-is-required-before-diagnosis",
    "approval-is-what-makes-the-rerun-safe",
    "approval-is-configured-not-a-fixed-string",
    "approval-modes-are-all-three-honoured",
    "infrastructure-failure-is-defined-by-what-executed",
    "the-eviction-signature-is-named",
    "the-governing-test-outranks-its-examples",
    "a-timeout-is-not-automatically-infrastructure",
    "a-timeout-after-checkout-is-the-code-failing",
    "a-timeout-is-infrastructure-only-before-the-tree-runs",
    "a-flaky-failure-is-a-real-failure-here",
    "the-rerun-is-the-whole-run-never-failed-only",
    "failed-only-would-silently-accomplish-nothing",
    "a-real-failure-anywhere-reruns-nothing",
    "a-rerun-beside-a-real-failure-clears-nothing",
    "one-rerun-then-stop",
    "the-whole-rollup-is-refetched-after-a-rerun",
    "a-post-rerun-non-mutating-stop-is-honoured",
    "only-the-nothing-to-fix-branch-clears-the-obstacle",
    "a-non-actions-check-fails-closed",
    "a-non-actions-check-is-never-given-a-run-command",
    "the-run-id-comes-from-the-details-url",
    "the-run-not-the-entry-is-the-unit",
    "the-ceiling-exists-to-surface-evidence",
    "the-ceiling-differs-from-the-drainers-on-purpose",
    "neither-ceiling-may-be-changed-to-match-the-other",
    "a-rerun-pushes-nothing-so-approval-stands",
    "a-rerun-invokes-no-rereview-and-no-label",
    "a-rerun-needs-no-worktree",
    "the-worktree-step-covers-all-three-head-moving-obstacles",
)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


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
            for requirement, phrase in REQUIRED_PHRASES.items():
                if phrase not in text:
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


class InfrastructureDefinitionTests(unittest.TestCase):
    """The example list may never widen the governing test.

    "No job that executed the pull request's code reported a failure" is the
    rule; the categories beside it are illustrations. A bare "timeout" in that
    list contradicted the rule outright -- a job that runs the suite and then
    hangs times out BECAUSE of the code -- so the list is checked for
    unqualified entries that would readmit a real failure.
    """

    def test_the_bare_category_list_no_longer_contains_timeout(self):
        # The sentence that enumerates always-infrastructure categories must
        # not name a timeout, because a timeout is only sometimes one.
        for path in FIX_ASSETS:
            text = read(path)
            self.assertNotIn(
                "is a\ncancellation, a timeout, a runner or registry error",
                text,
                f"{path} lists a bare timeout as always infrastructure",
            )
            self.assertIn(
                "Every failure in such a run is a cancellation, a runner or "
                "registry error, or",
                text,
                f"{path} no longer states the always-infrastructure categories",
            )

    def test_the_timeout_qualification_names_both_directions(self):
        for path in FIX_ASSETS:
            text = read(path)
            # The unsafe direction, and the narrow safe one.
            self.assertIn("timed\nout BECAUSE of the pull request's code", text, path)
            self.assertIn("a runner that never picked the job\nup", text, path)



class DurableCeilingTests(unittest.TestCase):
    """The one-rerun ceiling survives a fresh invocation.

    Nothing in this workflow persists state of its own, so a ceiling enforced
    from memory would bound only one invocation and a second `fix` could retry
    the same run. GitHub's own per-run attempt counter is the durable guard,
    and it is strictly better than a local one: it also counts reruns made by
    the PR drainer or by a person.
    """

    def test_the_attempt_counter_is_consulted_before_any_rerun(self):
        for path in FIX_ASSETS:
            text = read(path)
            self.assertIn("--json attempt", text, path)
            self.assertIn("is still on attempt 1", text, path)

    def test_the_attempt_field_gh_is_asked_for_really_exists(self):
        # Non-vacuous anchor: `gh run view --json attempt` must be a real
        # field, or the guard reads nothing and the ceiling silently reverts
        # to per-invocation. Checked against gh's own field list rather than
        # by making a network call.
        import shutil
        import subprocess

        if shutil.which("gh") is None:
            self.skipTest("gh is not installed")
        result = subprocess.run(
            ["gh", "run", "view", "--json"],
            capture_output=True,
            text=True,
        )
        # `--json` with no value makes gh print the supported field list.
        self.assertIn("attempt", result.stdout + result.stderr)


class RerunCommandShapeTests(unittest.TestCase):
    """The rerun command must be applicable to the failures it is defined by.

    `gh run rerun --failed` reruns "only failed jobs, including dependencies".
    A CANCELLED job is not a failed job, and a cancellation is the canonical
    infrastructure failure this workflow exists to retry -- so on a
    cancellation-only run `--failed` has nothing to act on, spends the single
    allowance, and leaves the run red. The whole-run form is the one that is
    always applicable.
    """

    RERUN_LINE = "gh run rerun <run-id> -R <owner/name>"

    def test_the_rerun_command_is_the_whole_run(self):
        for path in FIX_ASSETS:
            text = read(path)
            self.assertIn(self.RERUN_LINE, text, path)

    def test_no_asset_reruns_only_failed_jobs(self):
        # The flag may be NAMED -- the prose explains why it is wrong -- but it
        # must never appear on the command line the workflow tells an agent to
        # run.
        for path in FIX_ASSETS:
            for line in read(path).splitlines():
                stripped = line.strip()
                if stripped.startswith("gh run rerun"):
                    self.assertNotIn(
                        "--failed",
                        stripped,
                        f"{path} instructs a --failed rerun: {stripped!r}",
                    )

    def test_the_prose_explains_why_failed_only_is_refused(self):
        for path in FIX_ASSETS:
            text = read(path)
            self.assertIn("**Never `--failed` here.**", text, path)
            self.assertIn("a CANCELLED job is not a failed one", text, path)


class ContractDocumentationTests(unittest.TestCase):
    """The authoritative action contract documents this workflow.

    Manifest rows declare what it *reaches*; they are not a statement of its
    invocation, authority, or durable state. A workflow that reruns GitHub
    Actions, may push a reviewed head, and spawns a nested canonical review
    owes docs/agent-workflow-contract.md its own section, the way §2.7 gives
    repair one.
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
            "**Rerun authority, and its ceiling:**",
            "**Failure semantics:**",
            "**Required authority:**",
            "**Durable state:**",
            "**Mandatory/optional:**",
        ):
            self.assertIn(heading, section, f"§2.9 omits {heading}")
        # The two properties that make this action different from repair.
        self.assertIn("approvedPullRequest", section)
        self.assertIn("MergeBehind", section)
        self.assertIn("MAX_CI_RERUN_ATTEMPTS", section)
        self.assertIn("`--self-review`", section)
        self.assertIn("rather than reviewing itself", section)

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
            for requirement in FIX_ONLY_REQUIREMENTS:
                if REQUIRED_PHRASES[requirement] in text:
                    leaked.append(f"{path.relative_to(REPO_ROOT)}: {requirement}")
        self.assertEqual(
            leaked,
            [],
            "repair must not carry fix's approval gate or rerun authority:\n"
            + "\n".join(leaked),
        )

    def test_the_fix_only_set_is_a_real_subset_of_the_required_table(self):
        self.assertTrue(set(FIX_ONLY_REQUIREMENTS) < set(REQUIRED_PHRASES))
        self.assertGreaterEqual(len(FIX_ONLY_REQUIREMENTS), 10)

    def test_repair_still_forbids_the_retry_loop_fix_is_allowed(self):
        # The two workflows deliberately disagree here, and that disagreement
        # is only safe while repair's own prohibition is intact: repair runs on
        # unapproved work, where a red check is far likelier to be real.
        for path in REPAIR_ASSETS:
            self.assertIn("no retry loops", read(path))


# The spelled-out counts each bundle README states about its own inventory, and
# the number word for each. Prose that COUNTS a list is the failure mode
# CLAUDE.md's quality gates name explicitly -- "a module docstring saying 'the
# eleven documents' sat seventy lines above the tuple it described, and stayed
# wrong through several changes that grew it" -- and adding `fix` reproduced it
# across seven sites in two READMEs before a review caught them. This turns the
# whole-file audit into a gate.
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
    names = set()
    for path in listed:
        tail = path[len(prefix) :].lstrip("/")
        if not tail:
            continue
        # Claude ships commands/<name>.md; Codex ships skills/<name>/SKILL.md.
        names.add(tail.split("/")[0].removesuffix(".md"))
    return names


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
