"""Behavioral contract coverage for the packaged repair workflow (issue #125).

Run with: python3 -m unittest discover -s tools -p 'test_*.py'

`tools/test_codex_plugin.py` and `tools/test_claude_plugin.py` pin that both
plugins *discover* a `repair` workflow and that it stays out of the Haskell
name-parity set. Discovery is not the contract, though: `repair` mutates a
pull request's own branch and hands the verdict back to the canonical
coordinator, so what the packaged text actually instructs an agent to do is
the part that must not drift.

This module asserts that contract against BOTH packaged assets at once — the
Codex skill and the Claude command — since a requirement that holds in only
one brand's copy is a silent divergence. Every requirement below is checked as
text the workflow states in terms an agent will act on: the ordered diagnosis
branches matching `pullRequestStatus` (`src/Kanban/Workflow.hs`), worktree
selection and safe-push behavior, the authority prohibitions, and the
exactly-one-rereview handoff with its defined unavailable-rereview stop.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

CODEX_REPAIR = REPO_ROOT / "codex-plugin/plugins/kanban/skills/repair/SKILL.md"
CLAUDE_REPAIR = REPO_ROOT / "claude-plugin/plugins/kanban/commands/repair.md"

REPAIR_ASSETS = (CODEX_REPAIR, CLAUDE_REPAIR)

FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)
FRONTMATTER_KEY_RE = re.compile(r"^([A-Za-z][A-Za-z0-9_-]*):", re.MULTILINE)
BASH_FENCE_RE = re.compile(r"```bash\n(.*?)\n[ \t]*```", re.DOTALL)

# The same override surface tools/test_codex_plugin.py and
# tools/test_claude_plugin.py forbid, restated here so a repair asset is held
# to it whichever plugin it lives in.
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
    "$HOME/work/",
    "~/work/approve-issues",
    "/.codex/skills/",
    "/.claude/commands/",
)

# Requirement -> exact phrase both assets must state. Substring matching is
# deliberate: these are the operative instructions, so a rewrite that drops or
# softens one fails here rather than leaving the behavior to the model's
# discretion.
REQUIRED_PHRASES = {
    # Diagnosis: the three pullRequestStatus causes, with their breadth.
    "diagnosis-is-anchored-to-pullRequestStatus": (
        "in the same order and with the same breadth as `pullRequestStatus` in "
        "`src/Kanban/Workflow.hs`"
    ),
    "cause-1-merge-conflict": (
        "1. **Merge conflict** — resolve it, preserving the pull request's intent "
        "while incorporating the current base branch."
    ),
    "cause-2-any-failed-check-not-only-required": (
        "2. **Failed check** — any failed check in the pull request's status-check "
        "rollup, required or not, not only required checks."
    ),
    "cause-3-blocking-label-whatever-the-check-state": (
        "3. **Blocking label** — with no conflict and no failed check, whatever the "
        "check state, passing, pending, or unknown."
    ),
    # A pre-existing or flaky failure stops the run rather than being worked around.
    "flaky-or-pre-existing-failure-stops-the-run": (
        "A failure you judge to be pre-existing on the base branch or flaky rather "
        "than caused by this pull request must be reported to the user and stop the "
        "run, never papered over: no retry loops, no deleted or skipped tests, no "
        "weakened assertions."
    ),
    # A blocking label is never removed without asking.
    "blocking-label-is-never-removed-without-asking": (
        "Never remove a blocking label: a blocking label is a human's decision. "
        "Report what is blocking, ask the user, and act only on their answer."
    ),
    # Worktree selection, reuse, head recording, and safe push.
    "records-the-head-repository-branch-and-sha-before-editing": (
        "Resolve the pull request's head repository, head branch, and exact head SHA "
        "before editing anything, and record all three."
    ),
    "cross-repository-heads-are-fail-closed": (
        "A cross-repository pull request is fail-closed. When the head repository "
        "differs from the resolved repository, `headRefName` is not a branch of the "
        "resolved repository, so never fetch or push that name there"
    ),
    "pushes-only-to-the-head-repositorys-own-branch": (
        "push only to the head repository's own `headRefName`."
    ),
    "writability-is-decided-by-the-push-not-maintainer-can-modify": (
        "Decide whether that push is possible from the head repository itself, never "
        "from `maintainerCanModify`: that field reports whether the *base* "
        "repository's maintainers may modify the branch, which is neither necessary "
        "nor sufficient for the account running this workflow"
    ),
    "an-unwritable-head-stops-without-changing-the-remote": (
        "When it is rejected for lack of write access, stop and report that the pull "
        "request's head cannot be safely written, having changed nothing on the "
        "remote, and never fall back to pushing anywhere else."
    ),
    "selects-the-worktree-by-head-branch": (
        "Select the worktree by that branch, not by an issue number: reuse any "
        "worktree registered to this repository that is already on the pull "
        "request's exact head branch, and confirm it tracks the recorded head "
        "repository's `headRefName` rather than merely a local branch of the same "
        "name."
    ),
    "head-branch-selection-covers-any-issue-link-count": (
        "whether the pull request links zero, one, or several issues"
    ),
    "a-dirty-worktree-is-recoverable-work": (
        "A dirty or interrupted reused worktree is recoverable work, not a collision"
    ),
    "never-a-second-worktree-on-the-same-branch": (
        "never create a second worktree on the same branch merely because the first "
        "is dirty"
    ),
    "never-switches-the-primary-checkout": (
        "Never switch the repository's primary checkout."
    ),
    "reverifies-the-head-before-a-non-force-push": (
        "Before pushing, re-fetch the pull request branch from the recorded head "
        "repository and verify its remote head still equals the recorded SHA. Push to "
        "that exact branch, in that head repository, without force."
    ),
    "stops-on-a-competing-update": (
        "If the remote head moved, stop and report the competing update rather than "
        "overwriting it."
    ),
    # Authority.
    "never-merges-and-never-closes": (
        "Never merge the pull request, and never close an issue or pull request."
    ),
    "never-mutates-a-verdict-label-directly": (
        "Never add or remove a verdict label directly."
    ),
    "the-rereview-handoff-is-the-only-label-path": (
        "That handoff is the only path by which they may change."
    ),
    "ambiguity-goes-to-the-user": (
        "ask the user through the session's question mechanism rather than choosing"
    ),
    # Inputs.
    "requires-one-positive-pr-number": "Require one positive pull request number.",
    "scopes-github-metadata-to-the-resolved-repository": (
        "Use that resolved repository for the pull request's own GitHub metadata and "
        "for the coordinator handoff: pass it to `gh` as `-R <owner/name>` rather "
        "than letting `gh` infer the repository from the local checkout."
    ),
    "head-operations-do-not-use-the-resolved-repository": (
        "The resolved repository is where the pull request lives, not necessarily "
        "where its head lives. Every fetch and push of the head branch goes to the "
        "head repository recorded in step 3 instead"
    ),
    "forwards-repo-and-config-to-the-coordinator": (
        "Forward the resolved repository and configuration to the canonical "
        "coordinator through the coordinator's own `--repo` and `--config` options"
    ),
    # Rereview handoff.
    "exactly-one-rereview-after-a-push": (
        "When you pushed a new head, finish by invoking exactly one canonical rereview"
    ),
    "no-push-means-no-rereview": (
        "When you pushed nothing — the blocking-label branch, or a diagnosis that "
        "found nothing to repair — there is no new head, so invoke no rereview and "
        "simply report what you found."
    ),
    "stops-with-the-coordinators-reason-when-rereview-is-unavailable": (
        "the coordinator rejects a rereview on a pull request with no prior canonical "
        "review marker, and its issue gate blocks a pull request with no linked issue "
        "unless explicitly allowed — stop and report that exact reason."
    ),
    "never-compensates-for-an-unavailable-rereview": (
        "Never compensate by setting a label yourself."
    ),
    "does-not-self-review-the-rereview": "Do not pass `--self-review`",
}

# The diagnosis branches must appear in pullRequestStatus guard order
# (src/Kanban/Workflow.hs:198-207): merge conflict, then any failed check,
# then a blocking label.
DIAGNOSIS_ORDER = ("**Merge conflict**", "**Failed check**", "**Blocking label**")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def frontmatter_keys(text: str) -> set[str]:
    match = FRONTMATTER_RE.match(text)
    if match is None:
        return set()
    return {key.lower() for key in FRONTMATTER_KEY_RE.findall(match.group(1))}


def bash_fence_bodies(text: str) -> list[str]:
    return [match.group(1) for match in BASH_FENCE_RE.finditer(text)]


class RepairAssetPackagingTests(unittest.TestCase):
    def test_both_repair_assets_exist(self):
        for path in REPAIR_ASSETS:
            self.assertTrue(path.is_file(), f"missing {path}")

    def test_codex_skill_frontmatter_name_matches_its_directory(self):
        text = read(CODEX_REPAIR)
        match = FRONTMATTER_RE.match(text)
        self.assertIsNotNone(match, "repair SKILL.md must open with a --- frontmatter block")
        name = re.search(r"^name:\s*(\S+)\s*$", match.group(1), re.MULTILINE)
        self.assertIsNotNone(name, "repair SKILL.md frontmatter must declare name:")
        self.assertEqual(name.group(1), CODEX_REPAIR.parent.name)
        self.assertEqual(name.group(1), "repair")

    def test_claude_command_declares_a_description_and_is_named_repair(self):
        keys = frontmatter_keys(read(CLAUDE_REPAIR))
        self.assertIn("description", keys)
        self.assertEqual(CLAUDE_REPAIR.stem, "repair")

    def test_neither_asset_sets_forbidden_configuration(self):
        for path in REPAIR_ASSETS:
            hits = frontmatter_keys(read(path)) & FORBIDDEN_FRONTMATTER_KEYS
            self.assertEqual(
                hits,
                set(),
                f"{path} must not set model/effort/sandbox/permission/approval/cwd "
                f"configuration: {hits}",
            )

    def test_neither_asset_references_a_personal_absolute_path(self):
        for path in REPAIR_ASSETS:
            text = read(path)
            for fragment in FORBIDDEN_PATH_FRAGMENTS:
                self.assertNotIn(
                    fragment, text, f"{path} contains forbidden path fragment {fragment!r}"
                )


class RepairWorkflowContractTests(unittest.TestCase):
    """Every requirement below is asserted against both packaged assets, so a
    rewrite of one brand's copy cannot silently diverge from the other."""

    def test_both_assets_state_every_required_behavior(self):
        missing = []
        for path in REPAIR_ASSETS:
            text = read(path)
            for requirement, phrase in REQUIRED_PHRASES.items():
                if phrase not in text:
                    missing.append(f"{path.relative_to(REPO_ROOT)}: {requirement}")
        self.assertEqual(missing, [], "\n".join(missing))

    def test_the_required_phrase_table_is_not_vacuous(self):
        # Guards the loop above against a table that was emptied or whose
        # phrases were reduced to trivially-present fragments.
        self.assertGreaterEqual(len(REQUIRED_PHRASES), 20)
        for requirement, phrase in REQUIRED_PHRASES.items():
            self.assertGreaterEqual(len(phrase), 20, requirement)

    def test_diagnosis_branches_appear_in_pull_request_status_order(self):
        for path in REPAIR_ASSETS:
            text = read(path)
            positions = []
            for marker in DIAGNOSIS_ORDER:
                index = text.find(marker)
                self.assertNotEqual(index, -1, f"{path} does not name {marker}")
                positions.append(index)
            self.assertEqual(
                positions,
                sorted(positions),
                f"{path} lists the diagnosis causes out of pullRequestStatus order "
                f"{DIAGNOSIS_ORDER}",
            )

    def test_the_declared_diagnosis_order_matches_pull_request_status(self):
        # Non-vacuous anchor: the order asserted above is the order
        # pullRequestStatus actually guards in, so a change to the Haskell
        # precedence fails here instead of leaving the packaged text stale.
        source = read(REPO_ROOT / "src/Kanban/Workflow.hs")
        body = re.search(
            r"pullRequestStatus config pullRequest\n(.*?)\n\n", source, re.DOTALL
        )
        self.assertIsNotNone(body, "pullRequestStatus guard block not found")
        guards = body.group(1)
        conflict = guards.find("MergeConflicting")
        checks_failed = guards.find("checksFailed")
        blocking = guards.find("hasProblemLabel")
        self.assertNotEqual(conflict, -1)
        self.assertNotEqual(checks_failed, -1)
        self.assertNotEqual(blocking, -1)
        self.assertLess(conflict, checks_failed)
        self.assertLess(checks_failed, blocking)

    def test_both_assets_hand_off_to_the_coordinator_in_rereview_mode(self):
        for path in REPAIR_ASSETS:
            fences = " ".join(bash_fence_bodies(read(path)))
            self.assertIn("--rereview", fences, f"{path} never invokes the coordinator")
            self.assertNotIn(
                "--review",
                fences.replace("--rereview", ""),
                f"{path} must rereview, not open a fresh canonical review",
            )
            self.assertNotIn(
                "--publish-verdict",
                fences,
                f"{path} must not publish a verdict itself",
            )

    def test_every_gh_invocation_is_scoped_to_the_resolved_repository(self):
        # Round-1 review finding: an unscoped `gh pr view` lets gh infer the
        # repository from the local checkout, so a fork checkout given explicit
        # repository context would diagnose (or fail on) a same-numbered pull
        # request in the wrong repository — before the coordinator ever
        # receives --repo. Every gh call in a fenced block must carry -R.
        for path in REPAIR_ASSETS:
            gh_lines = [
                line.strip()
                for fence in bash_fence_bodies(read(path))
                for line in fence.splitlines()
                if line.strip().startswith("gh ")
            ]
            self.assertTrue(gh_lines, f"{path} has no gh invocation to check")
            for line in gh_lines:
                self.assertIn(
                    "-R <owner/name>",
                    line,
                    f"{path} invokes gh without an explicit repository: {line!r}",
                )

    def test_the_diagnosis_query_requests_the_head_repository_fields(self):
        # Round-2 review finding: -R scopes the query to the base repository but
        # says nothing about where the head lives. Without these fields the
        # workflow cannot tell a same-repository PR from a fork PR, so it would
        # fetch or push headRefName against the base repository — missing the
        # recorded head, or clobbering an unrelated same-named branch there.
        # maintainerCanModify is deliberately absent (round-3 finding): it
        # answers whether BASE-repository maintainers may modify the branch, not
        # whether this workflow's own account can push it, so the workflow must
        # not read it as a writability signal.
        for path in REPAIR_ASSETS:
            fences = " ".join(bash_fence_bodies(read(path)))
            self.assertNotIn(
                "maintainerCanModify",
                fences,
                f"{path} queries maintainerCanModify, which is not a writability "
                "test for the account running this workflow",
            )
            for field in (
                "headRefName",
                "headRefOid",
                "headRepository",
                "headRepositoryOwner",
                "isCrossRepository",
            ):
                self.assertIn(
                    field,
                    fences,
                    f"{path} never reads {field}, so it cannot resolve the head "
                    "repository before fetching or pushing",
                )

    def test_neither_asset_invokes_a_merge_or_a_verdict_label_mutation(self):
        for path in REPAIR_ASSETS:
            fences = " ".join(bash_fence_bodies(read(path)))
            for forbidden in ("gh pr merge", "--add-label", "--remove-label", "gh pr close", "gh issue close"):
                self.assertNotIn(
                    forbidden,
                    fences,
                    f"{path} must never run {forbidden!r}",
                )

    def test_each_asset_locates_its_own_brands_coordinator(self):
        codex_text = read(CODEX_REPAIR)
        self.assertIn("${CODEX_HOME:-$HOME/.codex}/plugins/cache", codex_text)
        self.assertIn("skills/pr-review/scripts/review_pr.py", codex_text)

        claude_text = read(CLAUDE_REPAIR)
        self.assertIn('"${CLAUDE_PLUGIN_ROOT}/scripts/review_pr.py"', claude_text)
        self.assertTrue(
            (REPO_ROOT / "claude-plugin/plugins/kanban/scripts/review_pr.py").is_file()
        )


if __name__ == "__main__":
    unittest.main()
