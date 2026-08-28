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
    "the-eviction-signature-is-named": (
        "Concurrency-group eviction is the\ncanonical case: a setup job is cancelled "
        "with no steps, the jobs needing it are\nskipped, and a summary job fails "
        "asserting they succeeded, having built nothing."
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
    "rerun-only-when-every-failed-run-is-infrastructure": (
        "**Only when EVERY failed run is an infrastructure failure**, rerun each "
        "of those\nruns exactly once"
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
        "RE-FETCH the whole rollup with the command\nin step 5 and judge the pull "
        "request on what it says now — never on the reruns'\nown outcomes alone."
    ),
    "a-remaining-failed-entry-stops-for-any-reason": (
        "**A failed entry remains** — stop and report it, whatever its kind and\n"
        "  whatever it looks like. Do not rerun a run this invocation already "
        "reran, do\n  not start a fix, and do not invoke a rereview."
    ),
    "only-an-empty-failed-set-clears-the-obstacle": (
        "**No failed entry remains** — the obstacle is cleared and this workflow "
        "is\n  done."
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
        "A failure that survives one\n  rerun is evidence, and burying it under a "
        "third attempt is exactly what this\n  ceiling exists to prevent."
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
        "A rerun changes no file and needs no worktree at all."
    ),
    "never-switches-the-primary-checkout": (
        "Never switch the repository's primary checkout."
    ),
}

# The obstacle branches, in the order the workflow must address them.
DIAGNOSIS_ORDER = ("**Merge conflict**", "**Failed check**", "**Nothing to fix**")

# Requirements that belong to fix alone. The repair pair must carry none of
# them, which is what proves the table above is measuring this workflow rather
# than matching text every packaged workflow happens to contain.
FIX_ONLY_REQUIREMENTS = (
    "a-diagnosis-is-not-authorisation",
    "a-why-question-is-answered-without-mutating",
    "an-ambiguous-request-is-read-as-diagnostic",
    "approval-is-required-before-diagnosis",
    "approval-is-what-makes-the-rerun-safe",
    "approval-is-configured-not-a-fixed-string",
    "approval-modes-are-all-three-honoured",
    "infrastructure-failure-is-defined-by-what-executed",
    "the-eviction-signature-is-named",
    "a-flaky-failure-is-a-real-failure-here",
    "rerun-only-when-every-failed-run-is-infrastructure",
    "a-real-failure-anywhere-reruns-nothing",
    "a-rerun-beside-a-real-failure-clears-nothing",
    "one-rerun-then-stop",
    "the-whole-rollup-is-refetched-after-a-rerun",
    "a-remaining-failed-entry-stops-for-any-reason",
    "only-an-empty-failed-set-clears-the-obstacle",
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
