"""Hermetic tests for `--reconcile-approvals` and the roadmap readiness rule.

Issue #391. A raw `reviewed:approve` label is normally not evidence of a current
approval, and until an issue enters `process_issue` nothing removes a stale one
-- so an unconditional label-only reader advertises readiness against a
specification no reviewer saw. The roadmap contract has one deliberate liveness
exception: when the canonical reconciliation lock is busy, it displays the
configured approval label already present in the complete snapshot -- minus any
issue also carrying the configured changes-requested label, which the gate
refuses regardless -- rather than hiding all readiness. These cover the bounded
backend operation and the two rendered roadmap contracts that consume it:
triage, and since issue #427 the retriage refresh that re-renders triage's
output. Retriage is the harder consumer because it must recompute even the busy
fallback instead of carrying markers from the prior roadmap.

No GitHub account and no model invocation: `get_issue`, `get_comments`, the
label mutation, and the lock are patched, while the decision itself -- the real
`approval_reconciliation_decision`, `review_record_matches`, `marker_matches`,
`spec_fingerprint`, and `current_gate_status` -- is the code under test. Faking
the predicate would leave the one thing this issue is about untested.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import approve_issues  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
BACKEND = REPO_ROOT / "tools" / "approve_issues.py"
TRIAGE_SOURCE = REPO_ROOT / "tools" / "command_sources" / "triage.md"
RENDERED_TRIAGE = (
    REPO_ROOT / "claude-plugin/plugins/kanban/commands/triage.md",
    REPO_ROOT / "codex-plugin/plugins/kanban/skills/triage/SKILL.md",
)
RETRIAGE_SOURCE = REPO_ROOT / "tools" / "command_sources" / "retriage.md"
RENDERED_RETRIAGE = (
    REPO_ROOT / "claude-plugin/plugins/kanban/commands/retriage.md",
    REPO_ROOT / "codex-plugin/plugins/kanban/skills/retriage/SKILL.md",
)

# The one authored token every cross-command reference is written as, and the
# sigil each brand renders it to. Issue #427 requirement 7: the source names
# triage through the token so neither rendered file tells its reader to type
# the other provider's spelling.
TRIAGE_REFERENCE_TOKEN = "{{cmd:triage}}"
BRAND_SIGILS = {
    REPO_ROOT / "claude-plugin/plugins/kanban/commands/retriage.md": "/",
    REPO_ROOT / "codex-plugin/plugins/kanban/skills/retriage/SKILL.md": "$",
}

# The unconditional, default-label readiness rules the retired personal copies
# stated and the vendored commands must not revive. The busy fallback instead
# uses the configured label returned by the backend and is scoped to one
# top-level outcome.
RETIRED_RAW_LABEL_RULES = (
    "every issue carrying the exact `reviewed:approve` label gets `✓`",
    "Confirm every `reviewed:approve` issue has exactly one `✓`",
)

# The complete busy-fallback algorithm, which triage owns and retriage
# delegates. Named once so the positive assertion on triage and the negative
# control on retriage can never drift into testing two different sentences.
TRIAGE_ONLY_BUSY_RULE = (
    "render `✓` for every issue in the verified-complete open-issue "
    "snapshot carrying that exact approval label and not carrying that exact "
    "changes-requested label"
)

ORIGIN_BODY = "Background\n\n<!-- issue-origin:claude -->\n"


def make_issue(number: int, *, labels: list[str], body: str = ORIGIN_BODY, state: str = "OPEN") -> dict:
    return {
        "number": number,
        "title": f"Issue {number}",
        "body": body,
        "url": f"https://github.com/acme/example/issues/{number}",
        "state": state,
        "labels": [{"name": name} for name in labels],
        "author": {"login": "coghex"},
    }


def marker_comment(spec: str, *, verdict: str = "APPROVE", reviewers: str = "codex",
                   models: str | None = None, origin: str = "claude") -> dict:
    if models is None:
        models = approve_issues.reviewer_models([approve_issues.CODEX_REVIEWER])
    return {
        "id": 1,
        "author_association": "OWNER",
        "user": {"login": "coghex"},
        "created_at": "2026-01-01T00:00:00Z",
        "html_url": "https://github.com/acme/example/issues/1#issuecomment-1",
        "body": (
            "## Automated cross-agent issue review\n\n"
            f"<!-- issue-review:v2 spec={spec} origin={origin} "
            f"reviewers={reviewers} models={models} "
            f"base=deadbeef mode=initial verdicts={reviewers}:{verdict} "
            f"verdict={verdict} -->\n"
        ),
    }


def current_marker_for(issue: dict, *, verdict: str = "APPROVE") -> dict:
    """A marker bound to `issue`'s live fingerprint.

    Computed rather than hard-coded, and computed against a comment list that
    already excludes v2 review comments from the fingerprint, so this really is
    the hash the gate will recompute.
    """
    return marker_comment(approve_issues.spec_fingerprint(issue, []), verdict=verdict)


class ReconcileHarness(unittest.TestCase):
    """Drives reconcile_approvals over faked reads and records exact events.

    Follows ReviewQueueHarness: the lock and every GitHub touch append to an
    event list, so ordering claims -- above all "every read happens after the
    lock" -- are proved by the list rather than asserted about the source.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ctx = approve_issues.RepoContext(
            path=Path(self.tmp.name), repo_slug="acme/example", default_branch="main"
        )
        self.lock = object()
        self.events: list[tuple] = []
        # One state per read; the last repeats. Two entries model an issue that
        # changes between reads, which is how the concurrency case is built.
        self.reads: dict[int, list[tuple[dict, list[dict]]]] = {}
        self.incidents: list[dict] = []
        self.removal_error: Exception | None = None
        self.read_counts: dict[int, int] = {}
        self.inventory: list[dict] = []

    def state(self, number: int, issue: dict, comments: list[dict]) -> None:
        self.reads.setdefault(number, []).append((issue, comments))

    def _current(self, number: int) -> tuple[dict, list[dict]]:
        states = self.reads[number]
        index = min(self.read_counts.get(number, 0), len(states) - 1)
        return states[index]

    def run_reconcile(self, numbers, *, contended=False, legacy_policy="dual",
                      approve_label="reviewed:approve",
                      changes_label="reviewed:changes"):
        events = self.events

        def acquire(*args, **kwargs):
            events.append(("acquire", tuple(sorted(kwargs.items()))))
            if contended:
                raise approve_issues.LockContentionError(
                    "Approval queue lock is held by the background approval "
                    "daemon (PID 4321)",
                    "the background approval daemon (PID 4321)",
                )
            return self.lock

        def release(handle):
            self.assertIs(handle, self.lock)
            events.append(("release", None))

        def fake_get_issue(ctx, number):
            events.append(("get_issue", number))
            issue, _ = self._current(number)
            return issue

        def fake_get_comments(ctx, number):
            events.append(("get_comments", number))
            _, comments = self._current(number)
            self.read_counts[number] = self.read_counts.get(number, 0) + 1
            return comments

        def fake_run(args, *, cwd, check=True):
            events.append(("run", tuple(args)))
            if self.removal_error is not None:
                raise self.removal_error
            return subprocess.CompletedProcess(args, 0, "", "")

        def fake_queue_open_issues(ctx):
            events.append(("inventory", None))
            return list(self.inventory)

        with (
            mock.patch.object(approve_issues, "log"),
            mock.patch.object(approve_issues, "APPROVE_LABEL", approve_label),
            mock.patch.object(approve_issues, "CHANGES_LABEL", changes_label),
            mock.patch.object(approve_issues, "acquire_lock", side_effect=acquire),
            mock.patch.object(approve_issues, "release_lock", side_effect=release),
            mock.patch.object(approve_issues, "get_issue", side_effect=fake_get_issue),
            mock.patch.object(
                approve_issues, "get_comments", side_effect=fake_get_comments
            ),
            mock.patch.object(approve_issues, "run", side_effect=fake_run),
            mock.patch.object(
                approve_issues, "queue_open_issues",
                side_effect=fake_queue_open_issues,
            ),
            mock.patch.object(
                approve_issues, "open_pipeline_incidents",
                side_effect=lambda path: list(self.incidents),
            ),
            mock.patch.object(approve_issues, "post_comment") as post,
        ):
            before = approve_issues.model_invocation_count()
            result = approve_issues.reconcile_approvals(
                self.ctx, list(numbers), legacy_policy=legacy_policy
            )
            self.model_calls = approve_issues.model_invocation_count() - before
        self.post_comment = post
        return result

    def kinds(self):
        return [event[0] for event in self.events]

    def edits(self):
        return [event[1] for event in self.events if event[0] == "run"]

    def entry(self, result, number):
        for item in result["issues"]:
            if item["issue"] == number:
                return item
        raise AssertionError(f"no entry for #{number} in {result}")


class StaleApprovalRemovalTests(ReconcileHarness):
    def test_stale_marker_removes_the_label_with_no_model_or_comment(self):
        issue = make_issue(7, labels=["reviewed:approve", "bug"])
        stale = [marker_comment("0" * 64)]
        self.state(7, issue, stale)
        self.state(7, make_issue(7, labels=["bug"]), stale)

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "removed")
        self.assertTrue(entry["label_removed"])
        self.assertFalse(entry["approved"])
        self.assertEqual(result["outcome"], "reconciled")
        self.assertEqual(
            self.edits(),
            [(
                "gh", "issue", "edit", "7", "--repo", "acme/example",
                "--remove-label", "reviewed:approve",
            )],
        )
        # The two mechanical claims requirement 3 makes, asserted rather than
        # inspected: the counter at the single reviewer-model funnel, and the
        # comment publisher.
        self.assertEqual(self.model_calls, 0)
        self.post_comment.assert_not_called()

    def test_every_read_happens_after_the_lock_is_acquired(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        self.state(7, issue, [marker_comment("0" * 64)])
        self.state(7, make_issue(7, labels=[]), [marker_comment("0" * 64)])

        self.run_reconcile([7])

        kinds = self.kinds()
        self.assertEqual(kinds[0], "acquire")
        self.assertEqual(kinds[-1], "release")
        self.assertNotIn("get_issue", kinds[:1])

    def test_removal_drops_only_the_approval_label(self):
        # Not clear_verdict_labels: a reviewed:changes label is a barrier the
        # review queue stops at, not the false-ready signal this mode corrects.
        issue = make_issue(7, labels=["reviewed:approve", "reviewed:changes"])
        self.state(7, issue, [marker_comment("0" * 64)])
        self.state(7, make_issue(7, labels=["reviewed:changes"]), [marker_comment("0" * 64)])

        self.run_reconcile([7])

        self.assertEqual(len(self.edits()), 1)
        self.assertNotIn("--add-label", self.edits()[0])
        self.assertEqual(self.edits()[0].count("--remove-label"), 1)

    def test_configured_non_default_approval_label_behaves_the_same(self):
        issue = make_issue(7, labels=["ready-to-go"])
        self.state(7, issue, [marker_comment("0" * 64)])
        self.state(7, make_issue(7, labels=[]), [marker_comment("0" * 64)])

        result = self.run_reconcile([7], approve_label="ready-to-go")

        self.assertEqual(self.entry(result, 7)["outcome"], "removed")
        self.assertIn("ready-to-go", self.edits()[0])

    def test_the_specification_hash_is_unchanged_by_the_removal(self):
        # spec_fingerprint excludes the three verdict labels, so removing the
        # approval label must leave the hash byte-identical. Asserted directly
        # rather than only through a second run's diff.
        before = make_issue(7, labels=["reviewed:approve", "bug"])
        after = make_issue(7, labels=["bug"])
        self.assertEqual(
            approve_issues.spec_fingerprint(before, []),
            approve_issues.spec_fingerprint(after, []),
        )


class CurrentApprovalTests(ReconcileHarness):
    def test_a_current_approval_keeps_its_label(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        self.state(7, issue, [current_marker_for(issue)])

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "current")
        self.assertFalse(entry["label_removed"])
        self.assertTrue(entry["approved"])
        self.assertEqual(self.edits(), [])

    def test_repeating_a_successful_reconciliation_mutates_nothing(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        stale = [marker_comment("0" * 64)]
        self.state(7, issue, stale)
        self.state(7, make_issue(7, labels=[]), stale)
        self.run_reconcile([7])
        self.assertEqual(len(self.edits()), 1)

        second = ReconcileHarness("run")
        second.setUp()
        second.state(7, make_issue(7, labels=[]), stale)
        result = second.run_reconcile([7])

        self.assertEqual(second.entry(result, 7)["outcome"], "unlabeled")
        self.assertEqual(second.edits(), [])

    def test_a_concurrent_current_approval_is_not_removed(self):
        # The hazard requirement 6 closes: an observation taken before the lock
        # says stale, and by the time the decision runs a concurrent review has
        # made that very approval current. Because every read is taken after
        # acquisition, the locked read is the only one that decides.
        issue = make_issue(7, labels=["reviewed:approve"])
        self.reads[7] = [(issue, [current_marker_for(issue)])]

        result = self.run_reconcile([7])

        self.assertEqual(self.entry(result, 7)["outcome"], "current")
        self.assertEqual(self.edits(), [])


class NotStaleRefusalTests(ReconcileHarness):
    """Non-approved states that are not marker staleness, and mutate nothing."""

    def test_a_blocking_incident_leaves_a_current_marker_alone(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        self.state(7, issue, [current_marker_for(issue)])
        self.incidents = [{
            "incident_id": "abc", "issue": None, "state": "open",
            "reason": "pipeline halted", "opened_at": "2026-01-01T00:00:00Z",
        }]

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "current")
        self.assertFalse(entry["label_removed"])
        self.assertFalse(entry["approved"])
        self.assertTrue(entry["reasons"])
        self.assertEqual(self.edits(), [])

    def test_a_closed_issue_with_a_current_marker_is_not_reconciled(self):
        issue = make_issue(7, labels=["reviewed:approve"], state="CLOSED")
        self.state(7, issue, [current_marker_for(issue)])

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "current")
        self.assertFalse(entry["approved"])
        self.assertIn("issue is not open", entry["reasons"])
        self.assertEqual(self.edits(), [])

    def test_unmarked_legacy_provenance_under_hold_never_removes(self):
        # reviewers_for_origin answers [] here, and marker_matches then answers
        # False for EVERY marker including a current one. Removing on that basis
        # would delete a valid approval.
        issue = make_issue(7, labels=["reviewed:approve"], body="Background\n")
        self.state(7, issue, [marker_comment(
            approve_issues.spec_fingerprint(issue, []), origin="legacy"
        )])

        result = self.run_reconcile([7], legacy_policy="hold")

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "unverified")
        self.assertFalse(entry["label_removed"])
        self.assertIsNone(entry["approved"])
        self.assertIn("legacy", entry["detail"])
        self.assertEqual(self.edits(), [])

    def test_an_invalid_marker_is_reported_not_raised(self):
        # main()'s InvalidIssueError handler opens a repository circuit-breaker
        # incident, so raising here would halt the pipeline as a side effect of
        # rendering a roadmap.
        issue = make_issue(7, labels=["reviewed:approve"])
        self.state(7, issue, [marker_comment("0" * 64, verdict="INVALID")])

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "unverified")
        self.assertIn("INVALID", entry["detail"])
        self.assertIn("issuecomment", entry["detail"])
        self.assertEqual(self.edits(), [])

    def test_an_unresolvable_record_is_unverified_rather_than_stale(self):
        # review_record_matches turns a record it cannot resolve into the same
        # False a specification mismatch produces. The gate refuses both, but
        # only one is evidence the approval went stale: removing a label
        # because a record could not be *read* is a fail-open mutation. Here
        # the marker's spec, origin, route and models all match and only its
        # `mode` is unknown, so a predicate keyed on the collapsed False would
        # delete a valid approval.
        issue = make_issue(7, labels=["reviewed:approve"])
        marker = current_marker_for(issue)
        marker["body"] = marker["body"].replace("mode=initial", "mode=sideways")
        self.state(7, issue, [marker])

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "unverified")
        self.assertFalse(entry["label_removed"])
        self.assertIsNone(entry["approved"])
        self.assertIn("could not be resolved", entry["detail"])
        self.assertEqual(self.edits(), [])

    def test_a_rereview_marker_without_its_parent_is_unverified(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        marker = current_marker_for(issue)
        marker["body"] = marker["body"].replace("mode=initial", "mode=rereview")
        self.state(7, issue, [marker])

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "unverified")
        self.assertFalse(entry["label_removed"])
        self.assertEqual(self.edits(), [])

    def test_no_marker_at_all_is_still_a_removal(self):
        # The fix above must not widen into "anything unresolved is spared": a
        # label backed by nothing is exactly the false-ready signal this mode
        # exists to correct.
        issue = make_issue(7, labels=["reviewed:approve"])
        self.state(7, issue, [])
        self.state(7, make_issue(7, labels=[]), [])

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "removed")
        self.assertTrue(entry["label_removed"])
        self.assertIn("no opposite-agent v2 review marker exists", entry["detail"])

    def test_a_genuine_specification_mismatch_is_still_a_removal(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        self.state(7, issue, [marker_comment("0" * 64)])
        self.state(7, make_issue(7, labels=[]), [marker_comment("0" * 64)])

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "removed")
        self.assertIn("matches this specification", entry["detail"])

    def test_a_wrong_reviewer_route_is_still_a_removal(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        spec = approve_issues.spec_fingerprint(issue, [])
        # A claude-origin issue routes to codex; a marker claiming claude
        # reviewed it is a route mismatch, which is an explicit removal cause.
        self.state(7, issue, [marker_comment(spec, reviewers="claude")])
        self.state(7, make_issue(7, labels=[]), [marker_comment(spec, reviewers="claude")])

        result = self.run_reconcile([7])

        self.assertEqual(self.entry(result, 7)["outcome"], "removed")

    def test_a_current_marker_with_a_non_approve_verdict_is_removed(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        marker = current_marker_for(issue, verdict="CHANGES_REQUESTED")
        self.state(7, issue, [marker])
        self.state(7, make_issue(7, labels=[]), [marker])

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "removed")
        self.assertIn("not APPROVE", entry["detail"])

    def test_an_unlabeled_issue_is_left_alone(self):
        issue = make_issue(7, labels=["bug"])
        self.state(7, issue, [])

        result = self.run_reconcile([7])

        self.assertEqual(self.entry(result, 7)["outcome"], "unlabeled")
        self.assertEqual(self.edits(), [])


class FailClosedTests(ReconcileHarness):
    def test_lock_contention_is_its_own_outcome_and_mutates_nothing(self):
        self.state(7, make_issue(7, labels=["reviewed:approve"]), [])

        result = self.run_reconcile([7], contended=True)

        self.assertEqual(result["outcome"], "busy")
        self.assertIn("the background approval daemon (PID 4321)", result["message"])
        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "unverified")
        self.assertFalse(entry["label_removed"])
        self.assertIsNone(entry["approved"])
        self.assertEqual(self.edits(), [])
        self.assertNotIn("get_issue", self.kinds())

    def test_a_failed_removal_claims_nothing(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        self.state(7, issue, [marker_comment("0" * 64)])
        self.removal_error = approve_issues.ApproveError("gh exploded")

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "unverified")
        self.assertFalse(entry["label_removed"])
        self.assertIsNone(entry["approved"])
        self.assertIn("gh exploded", entry["detail"])

    def test_a_label_still_attached_after_removal_is_unverified(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        stale = [marker_comment("0" * 64)]
        self.state(7, issue, stale)
        self.state(7, issue, stale)

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "unverified")
        self.assertFalse(entry["label_removed"])
        self.assertIn("still attached", entry["detail"])

    def test_a_specification_that_moved_during_removal_is_unverified(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        stale = [marker_comment("0" * 64)]
        self.state(7, issue, stale)
        self.state(7, make_issue(7, labels=[], body="Rewritten\n"), stale)

        result = self.run_reconcile([7])

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "unverified")
        self.assertIsNone(entry["approved"])
        self.assertIn("specification changed", entry["detail"])

    def test_the_lock_is_released_even_when_an_issue_read_explodes(self):
        self.reads[7] = []

        with self.assertRaises(IndexError):
            self.run_reconcile([7])

        self.assertIn("release", self.kinds())


class MultipleIssueTests(ReconcileHarness):
    def test_one_acquisition_covers_every_requested_issue(self):
        for number in (5, 7, 9):
            issue = make_issue(number, labels=["reviewed:approve"])
            self.state(number, issue, [current_marker_for(issue)])

        result = self.run_reconcile([5, 7, 9])

        self.assertEqual(self.kinds().count("acquire"), 1)
        self.assertEqual(self.kinds().count("release"), 1)
        self.assertEqual([item["issue"] for item in result["issues"]], [5, 7, 9])


class ConfiguredLabelSelectionTests(ReconcileHarness):
    """The candidate set is defined by the *configured* approval label, and the
    backend owns choosing it. A consumer that restated `reviewed:approve` would
    reconcile nothing in a repository overriding `workflow.approval_label` and
    would go on rendering exactly the stale readiness this mode exists to stop.
    """

    def _backlog(self, label):
        self.inventory = [
            make_issue(5, labels=[label]),
            make_issue(6, labels=["bug"]),
            make_issue(7, labels=[label, "bug"]),
        ]
        for number in (5, 7):
            issue = make_issue(number, labels=[label])
            self.state(number, issue, [current_marker_for(issue)])

    def test_selection_uses_a_configured_non_default_label(self):
        self._backlog("acme:go")

        result = self.run_reconcile([], approve_label="acme:go")

        self.assertEqual([item["issue"] for item in result["issues"]], [5, 7])
        self.assertEqual(result["approval_label"], "acme:go")
        # #6 carries no approval label, so it is never even read.
        self.assertNotIn(6, [event[1] for event in self.events if event[0] == "get_issue"])

    def test_selection_uses_the_default_label_when_nothing_overrides_it(self):
        self._backlog("reviewed:approve")

        result = self.run_reconcile([])

        self.assertEqual([item["issue"] for item in result["issues"]], [5, 7])
        self.assertEqual(result["approval_label"], "reviewed:approve")

    def test_a_stale_custom_label_is_removed_like_the_default(self):
        self.inventory = [make_issue(7, labels=["acme:go"])]
        self.state(7, make_issue(7, labels=["acme:go"]), [marker_comment("0" * 64)])
        self.state(7, make_issue(7, labels=[]), [marker_comment("0" * 64)])

        result = self.run_reconcile([], approve_label="acme:go")

        entry = self.entry(result, 7)
        self.assertEqual(entry["outcome"], "removed")
        self.assertIn("acme:go", self.edits()[0])
        self.assertNotIn("reviewed:approve", self.edits()[0])

    def test_selection_happens_after_the_lock(self):
        self._backlog("reviewed:approve")

        self.run_reconcile([])

        kinds = self.kinds()
        self.assertEqual(kinds[0], "acquire")
        self.assertLess(kinds.index("acquire"), kinds.index("inventory"))
        self.assertLess(kinds.index("inventory"), kinds.index("get_issue"))

    def test_explicit_numbers_skip_selection_entirely(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        self.state(7, issue, [current_marker_for(issue)])

        self.run_reconcile([7])

        self.assertNotIn("inventory", self.kinds())

    def test_contention_while_selecting_reports_no_issues(self):
        result = self.run_reconcile([], contended=True)

        self.assertEqual(result["outcome"], "busy")
        self.assertEqual(result["issues"], [])
        self.assertNotIn("inventory", self.kinds())


class ReportedLabelTests(ReconcileHarness):
    """Where each configured label is reported, per outcome.

    Issue #557. The busy fallback decides readiness from its own snapshot
    because the backend read nothing, so the labels it matches on have to
    travel in the document -- and the changes-requested label is needed by
    exactly the outcome that carries no entry to read it from. Only the backend
    has resolved either label, so a consumer that restated a default would
    match nothing in a repository configuring its own.
    """

    def test_a_reconciled_document_reports_the_approval_label_alone(self):
        issue = make_issue(7, labels=["reviewed:approve"])
        self.state(7, issue, [current_marker_for(issue)])

        result = self.run_reconcile([7])

        self.assertEqual(result["outcome"], "reconciled")
        self.assertEqual(result["approval_label"], "reviewed:approve")
        # No fallback where no fallback applies: a completed pass renders from
        # each entry's post-reconciliation `approved`.
        self.assertIsNone(result["busy_fallback"])

    def test_a_busy_document_reports_both_labels_in_the_fallback(self):
        # The outcome that needs them: it reconciles nothing, so its consumers
        # decide from their own snapshot with no entry to read.
        self.state(7, make_issue(7, labels=["reviewed:approve"]), [])

        result = self.run_reconcile([7], contended=True)

        self.assertEqual(result["outcome"], "busy")
        self.assertEqual(
            result["busy_fallback"],
            {
                "approval_label": "reviewed:approve",
                "changes_requested_label": "reviewed:changes",
            },
        )

    def test_a_busy_document_reports_non_default_configured_labels(self):
        result = self.run_reconcile(
            [], contended=True, approve_label="acme:go", changes_label="acme:rework"
        )

        self.assertEqual(result["outcome"], "busy")
        self.assertEqual(
            result["busy_fallback"],
            {"approval_label": "acme:go", "changes_requested_label": "acme:rework"},
        )

    def test_reporting_the_labels_costs_no_read_under_contention(self):
        # Requirement 3: the fallback's inputs come from what the caller
        # already holds. A busy pass still touches nothing.
        self.state(7, make_issue(7, labels=["reviewed:approve"]), [])

        self.run_reconcile([7], contended=True)

        self.assertNotIn("get_issue", self.kinds())
        self.assertNotIn("get_comments", self.kinds())
        self.assertNotIn("inventory", self.kinds())
        self.assertEqual(self.edits(), [])


class LegacyReaderSafetyTests(ReconcileHarness):
    """The rollout case the version number cannot cover.

    Issue #557. `approve_issues.py` is installed separately from the plugin
    bundles that consume it, so a backend carrying this change can be read by a
    workflow asset that predates it -- and no asset reads `version`. A version 1
    asset marks a busy document "when `approval_label` is a non-empty string"
    and fails closed on "an invalid or missing `approval_label` in a busy
    document". These pin the shape that lands such a reader in the second rule
    rather than the first, stated as that reader's own predicates so a
    regression is legible as the behavior it breaks.
    """

    LEGACY_MARKS_FROM_BUSY = staticmethod(
        # Verbatim from the version 1 asset: "When `approval_label` is a
        # non-empty string, render a mark for every issue in the snapshot
        # carrying that exact label."
        lambda document: isinstance(document.get("approval_label"), str)
        and bool(document["approval_label"].strip())
    )

    def busy_document(self, **kwargs):
        return self.run_reconcile([], contended=True, **kwargs)

    def test_a_legacy_reader_cannot_mark_from_a_busy_document(self):
        self.assertFalse(self.LEGACY_MARKS_FROM_BUSY(self.busy_document()))

    def test_a_legacy_reader_cannot_mark_from_a_non_default_busy_document(self):
        document = self.busy_document(
            approve_label="acme:go", changes_label="acme:rework"
        )

        self.assertFalse(self.LEGACY_MARKS_FROM_BUSY(document))
        # The label really is reported -- withheld from the legacy spelling,
        # not from the document -- so a current reader still applies it.
        self.assertEqual(document["busy_fallback"]["approval_label"], "acme:go")

    def test_a_legacy_reader_still_marks_from_a_reconciled_document(self):
        # Negative control. The withholding is scoped to the one outcome a
        # legacy reader handles unsafely; a completed pass is untouched, and a
        # check that failed for every outcome would prove nothing about which.
        issue = make_issue(7, labels=["reviewed:approve"])
        self.state(7, issue, [current_marker_for(issue)])

        self.assertTrue(self.LEGACY_MARKS_FROM_BUSY(self.run_reconcile([7])))

    def test_the_producer_cannot_emit_the_shape_a_legacy_reader_marks_from(self):
        # The guard, not just the current output: validation refuses a busy
        # document naming the legacy field, so no later edit can reintroduce it
        # without this failing.
        document = approve_issues.reconcile_result(
            "busy", message="held elsewhere", entries=[]
        )
        document["approval_label"] = approve_issues.APPROVE_LABEL

        self.assertTrue(self.LEGACY_MARKS_FROM_BUSY(document))
        with self.assertRaisesRegex(approve_issues.ApproveError, "legacy reader"):
            approve_issues.validate_reconcile_result(
                document, requested=[], model_ran=False
            )


class ResultValidationTests(unittest.TestCase):
    """The document is refused rather than emitted when it is wrong."""

    def good_entry(self, **overrides):
        entry = {
            "issue": 7, "outcome": "current", "label_removed": False,
            "approved": True, "reasons": [], "detail": None,
        }
        entry.update(overrides)
        return entry

    def validate(self, result, *, requested=(7,), model_ran=False):
        return approve_issues.validate_reconcile_result(
            result, requested=list(requested), model_ran=model_ran
        )

    def test_a_document_naming_another_approval_label_is_refused(self):
        # The document reports the label the run decided against, so a value
        # disagreeing with it is a document about a different question.
        with self.assertRaisesRegex(approve_issues.ApproveError, "approval label"):
            self.validate(self.good(approval_label="something-else"))

    def test_a_document_naming_no_approval_label_is_refused(self):
        with self.assertRaisesRegex(approve_issues.ApproveError, "approval label"):
            self.validate(self.good(approval_label=""))

    def test_a_reconciled_document_carrying_a_busy_fallback_is_refused(self):
        # A fallback offered where no fallback applies is a second,
        # unreconciled source of readiness beside the entries.
        with self.assertRaisesRegex(approve_issues.ApproveError, "no busy fallback"):
            self.validate(
                self.good(
                    busy_fallback={
                        "approval_label": "reviewed:approve",
                        "changes_requested_label": "reviewed:changes",
                    }
                )
            )

    def test_a_busy_document_omitting_the_fallback_is_refused(self):
        for value in (None, "reviewed:approve", []):
            with self.subTest(value=value):
                with self.assertRaisesRegex(
                    approve_issues.ApproveError, "no fallback labels"
                ):
                    self.validate(
                        self.busy(busy_fallback=value), requested=[]
                    )

    def test_a_busy_fallback_with_the_wrong_fields_is_refused(self):
        for fallback, detail in (
            ({"approval_label": "reviewed:approve"}, "missing"),
            (
                {
                    "approval_label": "reviewed:approve",
                    "changes_requested_label": "reviewed:changes",
                    "extra": "x",
                },
                "unexpected",
            ),
        ):
            with self.subTest(detail=detail):
                with self.assertRaisesRegex(
                    approve_issues.ApproveError, "wrong fields"
                ):
                    self.validate(
                        self.busy(busy_fallback=fallback), requested=[]
                    )

    def test_a_busy_fallback_naming_another_label_is_refused(self):
        # Same reasoning as the approval label above: a value disagreeing with
        # the one this run decided against is a document about another
        # repository's vocabulary, and the fallback would exclude on it.
        for field in ("approval_label", "changes_requested_label"):
            with self.subTest(field=field):
                with self.assertRaisesRegex(
                    approve_issues.ApproveError, f"names {field}"
                ):
                    self.validate(
                        self.busy(**{field: "something-else"}), requested=[]
                    )

    def test_a_busy_fallback_naming_no_label_is_refused(self):
        for field in ("approval_label", "changes_requested_label"):
            for value in ("", "   ", None, 7):
                with self.subTest(field=field, value=value):
                    with self.assertRaisesRegex(
                        approve_issues.ApproveError, f"no configured {field}"
                    ):
                        self.validate(
                            self.busy(**{field: value}), requested=[]
                        )

    def test_a_busy_fallback_naming_one_label_as_both_is_refused(self):
        # The one inconsistency neither equality check above can see: each
        # would pass while the fallback -- one exact match minus another --
        # silently marked nothing. Configuration already refuses the collision,
        # so this is the document-level backstop for globals set another way,
        # and the casing proves the check is the casefolded one config uses.
        with mock.patch.object(approve_issues, "CHANGES_LABEL", "REVIEWED:approve"):
            with self.assertRaisesRegex(
                approve_issues.ApproveError, "both the approval and the"
            ):
                self.validate(self.busy(), requested=[])

    def good(self, **overrides):
        result = approve_issues.reconcile_result(
            "reconciled", message="ok", entries=[self.good_entry()]
        )
        result.update(overrides)
        return result

    def busy(self, *, busy_fallback=..., **fallback_overrides):
        """A `busy` document, whose labels live one level down.

        `busy_fallback` replaces the whole object; any other keyword overrides
        one field inside the one the producer built.
        """
        result = approve_issues.reconcile_result(
            "busy", message="held elsewhere", entries=[]
        )
        if busy_fallback is not ...:
            result["busy_fallback"] = busy_fallback
        else:
            result["busy_fallback"].update(fallback_overrides)
        return result

    def test_a_valid_document_passes(self):
        self.assertEqual(self.validate(self.good())["outcome"], "reconciled")

    def test_a_model_invocation_is_refused(self):
        with self.assertRaisesRegex(approve_issues.ApproveError, "reviewer model"):
            self.validate(self.good(), model_ran=True)

    def test_an_unknown_schema_is_refused(self):
        with self.assertRaisesRegex(approve_issues.ApproveError, "unknown schema"):
            self.validate(self.good(schema="something-else"))

    def test_a_boolean_version_is_refused(self):
        # bool is an int in Python with True == 1, so a bare != 1 would pass it.
        with self.assertRaisesRegex(approve_issues.ApproveError, "schema version"):
            self.validate(self.good(version=True))

    def test_a_float_version_is_refused(self):
        with self.assertRaisesRegex(approve_issues.ApproveError, "schema version"):
            self.validate(self.good(version=1.0))

    def test_an_extra_field_is_refused(self):
        with self.assertRaisesRegex(approve_issues.ApproveError, "wrong fields"):
            self.validate(self.good(extra="no"))

    def test_a_missing_field_is_refused(self):
        result = self.good()
        del result["message"]
        with self.assertRaisesRegex(approve_issues.ApproveError, "wrong fields"):
            self.validate(result)

    def test_an_unknown_outcome_is_refused(self):
        with self.assertRaisesRegex(approve_issues.ApproveError, "unknown outcome"):
            self.validate(self.good(outcome="mostly-fine"))

    def test_entries_must_match_the_requested_issues_in_order(self):
        with self.assertRaisesRegex(approve_issues.ApproveError, "one entry per"):
            self.validate(self.good(), requested=(7, 9))

    def test_an_unverified_entry_carrying_approved_is_refused(self):
        result = self.good()
        result["issues"] = [self.good_entry(
            outcome="unverified", approved=True, detail="why"
        )]
        with self.assertRaisesRegex(approve_issues.ApproveError, "no approved Boolean"):
            self.validate(result)

    def test_an_unverified_entry_without_detail_is_refused(self):
        result = self.good()
        result["issues"] = [self.good_entry(outcome="unverified", approved=None)]
        with self.assertRaisesRegex(approve_issues.ApproveError, "could not be verified"):
            self.validate(result)

    def test_a_removed_entry_claiming_approval_is_refused(self):
        result = self.good()
        result["issues"] = [self.good_entry(
            outcome="removed", label_removed=True, approved=True
        )]
        with self.assertRaisesRegex(approve_issues.ApproveError, "cannot report"):
            self.validate(result)

    def test_a_removed_entry_that_removed_nothing_is_refused(self):
        result = self.good()
        result["issues"] = [self.good_entry(
            outcome="removed", label_removed=False, approved=False
        )]
        with self.assertRaisesRegex(approve_issues.ApproveError, "must report label_removed"):
            self.validate(result)

    def test_a_current_entry_claiming_a_removal_is_refused(self):
        result = self.good()
        result["issues"] = [self.good_entry(label_removed=True)]
        with self.assertRaisesRegex(approve_issues.ApproveError, "cannot claim"):
            self.validate(result)

    def test_a_non_positive_issue_number_is_refused(self):
        result = self.good()
        result["issues"] = [self.good_entry(issue=0)]
        with self.assertRaisesRegex(approve_issues.ApproveError, "positive issue number"):
            self.validate(result, requested=(0,))


def run_backend(*args):
    return subprocess.run(
        [sys.executable, str(BACKEND), *args],
        capture_output=True, text=True, stdin=subprocess.DEVNULL,
    )


class ArgumentRefusalTests(unittest.TestCase):
    """Every refusal lands before the repository context, so it costs no
    GitHub call and writes nothing a caller could read as a result."""

    def test_it_requires_json(self):
        proc = run_backend("--reconcile-approvals", "7")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")
        self.assertIn("--reconcile-approvals requires --json", proc.stderr)

    def test_it_is_mutually_exclusive_with_the_other_modes(self):
        for other in (["--check", "5"], ["--review", "5"], ["--rereview", "5"],
                      ["--review-queue"]):
            with self.subTest(other=other[0]):
                proc = run_backend("--reconcile-approvals", "7", "--json", *other)
                self.assertNotEqual(proc.returncode, 0)
                self.assertEqual(proc.stdout, "")
                self.assertIn("mutually exclusive", proc.stderr)
                self.assertIn("--reconcile-approvals", proc.stderr)

    def test_it_is_mutually_exclusive_with_self_test(self):
        proc = run_backend("--reconcile-approvals", "7", "--json", "--self-test")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")
        self.assertIn("--self-test are mutually exclusive", proc.stderr)

    def test_it_refuses_a_non_positive_issue_number(self):
        proc = run_backend("--reconcile-approvals", "0", "--json")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")

    def test_no_path_is_still_required(self):
        proc = run_backend("--reconcile-approvals", "7", "--json")
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, "")
        self.assertIn("--path is required", proc.stderr)


class CheckRemainsReadOnlyTests(unittest.TestCase):
    def test_the_check_branch_performs_no_mutation(self):
        source = BACKEND.read_text(encoding="utf-8")
        start = source.index("if args.check is not None:")
        end = source.index("if args.review is not None:", start)
        branch = source[start:end]
        for forbidden in (
            "remove_approval_label", "clear_verdict_labels", "set_verdict_label",
            "acquire_lock", "post_comment", "--remove-label", "--add-label",
        ):
            self.assertNotIn(forbidden, branch, f"--check must not reach {forbidden}")

    def test_reconciliation_never_calls_the_check_helper_twice(self):
        # The per-issue result carries the post-reconciliation gate status, so a
        # consumer never needs a second read. Two calls would reopen the
        # read-then-decide window the lock closes.
        source = BACKEND.read_text(encoding="utf-8")
        start = source.index("def reconcile_one_locked(")
        end = source.index("def reconcile_result(", start)
        self.assertEqual(source[start:end].count("current_gate_status("), 2)


class TriageAssetTests(unittest.TestCase):
    """The rendered triage contract, held on the authored source and both
    outputs. `render_command_sources.py --check` already proves the two are
    that source's output, so a single assertion on each covers both brands."""

    def assets(self):
        return [TRIAGE_SOURCE, *RENDERED_TRIAGE]

    def test_every_asset_verifies_approval_before_marking_it(self):
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("--reconcile-approvals", text)
                self.assertIn("--legacy-policy dual", text)
                self.assertIn('--repo "$REPO"', text)
                self.assertIn("candidate", text)

    def test_every_asset_refuses_to_mark_an_unverified_issue(self):
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("[approval unverified]", text)
                self.assertIn("[needs canonical review]", text)
                self.assertIn("Fail closed", text)
                self.assertIn("ready to solve", text)

    def test_every_asset_uses_the_reported_label_when_reconciliation_is_busy(self):
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn('top-level `outcome: "busy"`', text)
                self.assertIn("verified-complete open-issue snapshot", text)
                self.assertIn(
                    "render `✓` for every issue in the verified-complete", text
                )
                self.assertIn(
                    "Do not add `[approval unverified]` to those label-backed entries",
                    text,
                )
                self.assertIn(
                    "This is the only case where the current approval label itself earns `✓`",
                    text,
                )
                self.assertIn("The answer must say exactly once", text)
                self.assertIn(
                    "Approval reconciliation was busy; displayed `✓` markers reflect "
                    "current labels rather than verified approvals.",
                    text,
                )
                self.assertIn(
                    "contains the required busy-disclosure sentence exactly once",
                    text,
                )

    def test_every_asset_suppresses_the_busy_mark_for_a_changes_requested_issue(self):
        """Issue #557 requirements 1 and 2, over the three snapshot cases the
        fallback can face: approval label only is marked, both labels is not,
        neither is not. Each case is a separate sentence, so an asset that
        dropped one fails on that case rather than on the paragraph.
        """
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                # Approval label only -> marked; both labels -> not marked.
                self.assertIn(TRIAGE_ONLY_BUSY_RULE, text)
                # Neither label, and the changes-requested label alone -> not
                # marked. The fallback stays live and label-backed.
                self.assertIn(
                    "An issue carrying neither label, or the changes-requested "
                    "label alone, receives no `✓`",
                    text,
                )
                # Requirement 3: both labels come from the document already in
                # hand, and nothing further is read or locked to apply them.
                self.assertIn(
                    "When that is an object whose `approval_label` and "
                    "`changes_requested_label` are both non-empty strings",
                    text,
                )
                self.assertIn("Take both labels from that same object", text)
                # The legacy spelling is null on purpose, and the asset says
                # so, so a reader is not left treating it as a malformed
                # document it should escalate.
                self.assertIn(
                    "A busy document reports its top-level `approval_label` as "
                    "null and puts both configured labels in `busy_fallback` "
                    "instead",
                    text,
                )
                self.assertIn(
                    "no second `--check`, no further GitHub read, no lock", text
                )
                # The step-13 verification counts the same three cases, so a
                # suppressed issue is not re-marked while checking the answer.
                self.assertIn(
                    "confirm every snapshot issue carrying the reported approval "
                    "label without the reported changes-requested label has `✓`, "
                    "no other issue has `✓`",
                    text,
                )
                self.assertIn(
                    "reported in that document's `busy_fallback`", text
                )

    def test_no_asset_names_a_changes_requested_label_of_its_own(self):
        # Requirement 4. The label is whichever one the document reports, so an
        # asset naming the default would exclude nothing in a repository
        # configuring `workflow.changes_requested_label` to something else --
        # the same failure naming the approval label here would cause.
        for path in self.assets():
            with self.subTest(asset=path.name):
                self.assertNotIn(
                    "reviewed:changes", path.read_text(encoding="utf-8")
                )

    def test_busy_fallback_does_not_weaken_other_failure_handling(self):
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("Fail closed outside the busy fallback", text)
                self.assertIn(
                    "invalid or missing `busy_fallback` or either label inside "
                    "it in a busy document",
                    text,
                )
                self.assertIn("guessed or hard-coded approval label", text)

    def test_the_delegating_retriage_assets_do_not_duplicate_the_full_rule(self):
        # Negative control for the rule assertions above: retriage owes the
        # behavior but delegates the complete algorithm back to triage. The
        # constant is asserted present in every triage asset first, so a typo
        # in it cannot make the control pass over a retriage that really did
        # duplicate the rule.
        for path in self.assets():
            with self.subTest(asset=path.name, side="states"):
                self.assertIn(
                    TRIAGE_ONLY_BUSY_RULE, path.read_text(encoding="utf-8")
                )
        for path in [RETRIAGE_SOURCE, *RENDERED_RETRIAGE]:
            with self.subTest(asset=path.name, side="delegates"):
                self.assertNotIn(
                    TRIAGE_ONLY_BUSY_RULE, path.read_text(encoding="utf-8")
                )

    def test_no_asset_hard_codes_the_default_label_as_readiness(self):
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertNotIn(
                    "Append `✓` to every issue labeled `reviewed:approve`", text
                )
                self.assertNotIn(
                    "Mark every issue carrying the exact `reviewed:approve` label "
                    "with `✓`",
                    text,
                )

    def test_every_asset_resolves_the_backend_through_the_install_record(self):
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("KANBAN_ISSUE_REVIEW_INSTALL_DIR", text)
                self.assertIn("kanban/issue-review/config.json", text)

    def test_no_asset_names_a_candidate_approval_label(self):
        # The label belongs to the repository. An asset that named one would
        # reconcile nothing where workflow.approval_label overrides the default.
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                invocation = [
                    line for line in text.splitlines()
                    if "--reconcile-approvals" in line and line.startswith("python3")
                ][0]
                self.assertNotIn("reviewed:approve", invocation)
                # No issue numbers either: selection is the backend's, because
                # only it has resolved the configured label.
                self.assertIn("--reconcile-approvals --legacy-policy", invocation)
                self.assertIn("approval_label", text)

    def test_the_reconcile_invocation_is_one_plain_command_line(self):
        # The manifest extractor parses asset bash fences as shell, so a
        # wrapped or continued invocation fails it with an unhelpful error.
        for path in self.assets():
            with self.subTest(asset=path.name):
                lines = [
                    line for line in path.read_text(encoding="utf-8").splitlines()
                    if "--reconcile-approvals" in line and line.startswith("python3")
                ]
                self.assertEqual(len(lines), 1, path)
                self.assertFalse(lines[0].rstrip().endswith("\\"))


class RetriageAssetTests(unittest.TestCase):
    """Issue #427's behavioral contract for the vendored retriage, held on the
    authored source and both rendered outputs.

    `render_command_sources.py --check` already proves the two outputs are that
    source's, so most assertions run over all three; the two that are *about*
    the rendering — the sigil and the brand-neutral token — necessarily run per
    output, since that is the only place the brands differ."""

    def assets(self):
        return [RETRIAGE_SOURCE, *RENDERED_RETRIAGE]

    def test_the_assets_this_class_pins_are_the_real_tracked_files(self):
        # Non-vacuity for every loop below: each reads a file, so a renamed or
        # unrendered asset would make them all pass over an empty list.
        self.assertEqual(len(self.assets()), 3)
        for path in self.assets():
            with self.subTest(asset=path.name):
                self.assertTrue(path.is_file(), path)
                self.assertGreater(len(path.read_text(encoding="utf-8")), 2000, path)

    def test_the_source_names_triage_through_the_neutral_token(self):
        # Requirement 7. The source must carry no literal sigil spelling of
        # triage at all; the renderer refuses one, and this pins the reason
        # rather than relying on that refusal staying enabled.
        text = RETRIAGE_SOURCE.read_text(encoding="utf-8")
        self.assertIn(TRIAGE_REFERENCE_TOKEN, text)
        for literal in ("/triage", "$triage"):
            self.assertNotIn(literal, text)

    def test_each_rendered_file_names_triage_with_its_own_brand_sigil(self):
        # The point of the token: the Codex skill must never tell its reader to
        # type a Claude invocation, or the reverse.
        for path, sigil in BRAND_SIGILS.items():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                other = "$" if sigil == "/" else "/"
                self.assertNotIn(TRIAGE_REFERENCE_TOKEN, text)
                self.assertIn(f"{sigil}triage", text)
                self.assertNotIn(f"{other}triage", text)

    def test_every_asset_scopes_every_github_call_to_the_resolved_repository(self):
        # Requirement 4. Checked as a property of every `gh` line rather than
        # as the presence of one scoped call, so adding an unscoped read later
        # fails here.
        for path in self.assets():
            with self.subTest(asset=path.name):
                lines = [
                    line
                    for line in path.read_text(encoding="utf-8").splitlines()
                    if line.startswith("gh ")
                ]
                self.assertTrue(lines, path)
                for line in lines:
                    self.assertIn('-R "$REPO"', line, line)

    def test_no_asset_resolves_the_repository_through_an_unscoped_call(self):
        # The review's amendment: triage's `gh repo view "$REPO_REMOTE"` is
        # precedent, not a compliant implementation here, because requirement 4
        # admits no `gh` invocation that precedes the resolution.
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertNotIn("gh repo view", text)
                self.assertIn("git remote get-url origin", text)

    def test_every_asset_reports_the_repository_before_and_after_mutating(self):
        # The review's correction to requirement 4: reconciliation can remove a
        # label, so the resolved identity is echoed before it runs as well as
        # named in the answer's first line.
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("Echo it to the user before step 5 runs", text)
                self.assertIn("name it again in the answer's first", text)

    def test_every_asset_verifies_readiness_through_one_canonical_call(self):
        # Requirement 6, and the same one-invocation shape triage is held to:
        # one plain `python3` line, no issue numbers, no candidate label named.
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("KANBAN_ISSUE_REVIEW_INSTALL_DIR", text)
                self.assertIn("kanban/issue-review/config.json", text)
                lines = [
                    line
                    for line in text.splitlines()
                    if "--reconcile-approvals" in line and line.startswith("python3")
                ]
                self.assertEqual(len(lines), 1, path)
                invocation = lines[0]
                self.assertFalse(invocation.rstrip().endswith("\\"))
                self.assertIn('--repo "$REPO"', invocation)
                self.assertIn("--reconcile-approvals --legacy-policy dual", invocation)
                self.assertNotIn("reviewed:approve", invocation)

    def test_every_asset_defers_the_readiness_rules_to_triage(self):
        # Requirement 5. Retriage states the obligation and points at triage's
        # two sections for the rules, so the vocabulary cannot drift; the
        # section names are asserted because a bare mention of triage would
        # satisfy a looser check while pointing nowhere.
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("**Output Format**", text)
                self.assertIn("**Approval Readiness**", text)
                self.assertIn("renders nothing of its own", text)

    def test_no_asset_restates_the_rules_it_defers(self):
        # The other half of requirement 5: deferring in one paragraph while
        # keeping a second copy elsewhere in the file is the drift this slice
        # exists to remove. The difficulty rubric and the roadmap example the
        # retired copies carried are the two concrete copies.
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertNotIn("## Difficulty Estimates", text)
                self.assertNotIn("**Main Sequence**", text)
                self.assertNotIn("**Anytime List**", text)
                self.assertNotIn("**Tracker Issues**", text)

    def test_no_asset_hard_codes_the_default_label_as_readiness(self):
        # The retired copies named the default label unconditionally. The busy
        # fallback must use the configured label returned by the backend, so no
        # retriage asset may name a candidate label itself.
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                for retired in RETIRED_RAW_LABEL_RULES:
                    self.assertNotIn(retired, text)
                self.assertNotIn("reviewed:approve", text)
                # Issue #557 extends the same rule to the label the busy
                # fallback now excludes on.
                self.assertNotIn("reviewed:changes", text)

    def test_the_retired_rules_are_still_the_ones_the_personal_copies_stated(self):
        # Negative control for the assertion above. It compares against
        # constants, so a typo in one would make it pass against a file that
        # still carried the rule; triage's own retired-rule pin has the same
        # shape and the same risk. Both retired sentences are quoted from the
        # personal copies, and both are still absent from the whole tree.
        tracked = [
            *self.assets(),
            TRIAGE_SOURCE,
            *RENDERED_TRIAGE,
        ]
        for retired in RETIRED_RAW_LABEL_RULES:
            with self.subTest(rule=retired[:40]):
                self.assertIn("reviewed:approve", retired)
                self.assertIn("✓", retired)
                for path in tracked:
                    self.assertNotIn(retired, path.read_text(encoding="utf-8"))

    def test_every_asset_recomputes_busy_markers_from_the_snapshot_label(self):
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                flat = " ".join(text.split())
                self.assertIn("**Busy lock.**", flat)
                self.assertIn("busy-lock fallback", flat)
                self.assertIn("current snapshot's labels", flat)
                self.assertIn("not the previous roadmap's marker", flat)
                self.assertIn(
                    "both the approval label that earns one and the "
                    "changes-requested label that withholds it",
                    flat,
                )
                self.assertIn(
                    "do not add `[approval unverified]` merely because the lock is busy",
                    flat,
                )

    def test_every_asset_delegates_the_busy_exclusion_rather_than_restating_it(self):
        # Issue #557 requirement 6. Retriage owes the suppression but must not
        # carry a second copy of the algorithm -- it points at triage and names
        # only that both configured labels come from the document. The
        # companion negative control lives in TriageAssetTests, which owns the
        # rule string.
        for path in self.assets():
            with self.subTest(asset=path.name):
                flat = " ".join(path.read_text(encoding="utf-8").split())
                self.assertIn(
                    "busy-lock fallback prescribes, over both configured labels "
                    "that document reports",
                    flat,
                )
                self.assertIn(
                    "read off both labels that document reports", flat
                )

    def test_every_asset_discloses_the_busy_fallback_without_a_delta_request(self):
        for path in self.assets():
            with self.subTest(asset=path.name):
                flat = " ".join(path.read_text(encoding="utf-8").split())
                self.assertIn("required one-time busy-disclosure sentence", flat)
                self.assertIn(
                    "regardless of whether the user asked for a delta", flat
                )
                self.assertIn(
                    "mandatory one-time disclosure is part of the fallback", flat
                )
                self.assertIn(
                    "required busy-disclosure sentence exactly once", flat
                )

    def test_every_asset_fails_closed_outside_the_busy_fallback(self):
        # The previous roadmap's marker is not a fallback for an actual
        # verification failure. Busy is handled separately above.
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                flat = " ".join(text.split())
                self.assertIn("**Fail closed outside the busy fallback.**", flat)
                for cause in (
                    "missing or unresolvable backend",
                    "GitHub read or write failure",
                    "malformed document",
                    "invalid or missing `busy_fallback` or either label inside "
                    "it in a busy document",
                    "unverifiable post-mutation state",
                ):
                    self.assertIn(cause, flat)
                self.assertIn("[approval unverified]", flat)
                self.assertIn("[needs canonical review]", flat)
                self.assertIn("is not a fallback", flat)
                self.assertIn("ready to solve", flat)

    def test_every_asset_recomputes_rather_than_carries_a_marker_forward(self):
        # The roadmap being edited already has markers, so even the deliberate
        # busy-label fallback must be recomputed rather than copied.
        for path in self.assets():
            with self.subTest(asset=path.name):
                text = path.read_text(encoding="utf-8")
                self.assertIn("recomputed on this run", text)
                self.assertIn("None is copied", text)
                self.assertIn("Outside", text)
                self.assertIn("none is", text)
                self.assertIn("read off an issue's labels", text)
                self.assertIn("verified-complete issue snapshot", text)
                self.assertIn("no approval marker was carried over", text)
                self.assertIn("an exact current-snapshot", text)


class ManifestCoverageTests(unittest.TestCase):
    """The two rows these changes add to. The surface lists are enumerated, so
    an asset absent from a row is simply never reconciled against it — which is
    why the retriage assets are pinned into the same two rows rather than left
    to the generic grounding check in
    tools/test_agent_workflow_contract.py."""

    def rows(self):
        text = (REPO_ROOT / "docs/agent-workflow-contract.md").read_text(encoding="utf-8")
        rows = {}
        for line in text.splitlines():
            if " | " in line and not line.startswith("|"):
                name = line.split(" | ")[0].strip()
                if name.replace("-", "").isalnum():
                    rows[name] = line
        return rows

    def test_both_rendered_triage_paths_are_declared(self):
        rows = self.rows()
        for row in ("python3-cli", "issue-review-discovery-record"):
            with self.subTest(row=row):
                self.assertIn(row, rows)
                for asset in RENDERED_TRIAGE:
                    self.assertIn(
                        asset.relative_to(REPO_ROOT).as_posix(), rows[row]
                    )

    def test_both_rendered_retriage_paths_are_declared(self):
        # Issue #427 requirement 8. Retriage resolves the discovery record and
        # runs the backend exactly as triage does, so it owes the same two rows.
        rows = self.rows()
        for row in ("python3-cli", "issue-review-discovery-record"):
            with self.subTest(row=row):
                self.assertIn(row, rows)
                for asset in RENDERED_RETRIAGE:
                    self.assertIn(
                        asset.relative_to(REPO_ROOT).as_posix(), rows[row]
                    )

    def test_the_contract_documents_the_reconciliation_authority(self):
        text = (REPO_ROOT / "docs/agent-workflow-contract.md").read_text(encoding="utf-8")
        flat = " ".join(text.split())
        self.assertIn("--reconcile-approvals", text)
        self.assertIn("approve-issues-reconcile-approvals", text)
        for term in ("Locking", "Result", "Failure semantics", "Decision"):
            self.assertIn(term, text)
        for busy_term in (
            "scoped `busy` liveness exception",
            "verified-complete open-issue snapshot",
            "display-only fallback",
            "solve gate remains",
            "invalid or missing `busy_fallback`, or either label inside it, in "
            "a `busy` document",
            "must disclose that label-backed fallback once per answer",
            # Issue #557: 2.3.1 authorized an approval-label-only match, which
            # is the rule the assets no longer follow.
            "a `busy_fallback` object carrying exactly `approval_label` and "
            "`changes_requested_label`, both configured",
            "not its non-empty `changes_requested_label`",
            "that are not also exact matches for that object's validated "
            "`changes_requested_label`",
            # And the reason the split, not the version, is what protects an
            # already-installed reader.
            "never read `version`",
            "refused if a `busy` outcome names `approval_label` at all",
        ):
            self.assertIn(busy_term, flat)


class SchemaConstantTests(unittest.TestCase):
    def test_the_schema_is_distinct_from_the_review_queue_document(self):
        self.assertNotEqual(
            approve_issues.RECONCILE_SCHEMA, approve_issues.REVIEW_QUEUE_SCHEMA
        )

    def test_the_document_serializes(self):
        document = approve_issues.reconcile_result(
            "reconciled", message="ok", entries=[]
        )
        self.assertEqual(json.loads(json.dumps(document))["version"], 2)

    def test_the_version_records_the_reshaped_document(self):
        # The version records the change; LegacyReaderSafetyTests covers what
        # actually enforces it, since no consumer reads `version`.
        self.assertIn("busy_fallback", approve_issues.RECONCILE_RESULT_FIELDS)
        self.assertNotIn(
            "changes_requested_label", approve_issues.RECONCILE_RESULT_FIELDS
        )
        self.assertEqual(
            approve_issues.RECONCILE_BUSY_FALLBACK_FIELDS,
            {"approval_label", "changes_requested_label"},
        )
        self.assertGreater(approve_issues.RECONCILE_SCHEMA_VERSION, 1)


if __name__ == "__main__":
    unittest.main()
