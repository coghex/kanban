"""Hermetic tests for `--reconcile-approvals` and the triage readiness rule.

Issue #391. A raw `reviewed:approve` label is not evidence of a current
approval, and until an issue enters `process_issue` nothing removes a stale one
-- so a label-only reader advertises readiness against a specification no
reviewer saw. These cover the bounded backend operation that corrects it and the
rendered triage contract that consumes it.

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

    def state(self, number: int, issue: dict, comments: list[dict]) -> None:
        self.reads.setdefault(number, []).append((issue, comments))

    def _current(self, number: int) -> tuple[dict, list[dict]]:
        states = self.reads[number]
        index = min(self.read_counts.get(number, 0), len(states) - 1)
        return states[index]

    def run_reconcile(self, numbers, *, contended=False, legacy_policy="dual",
                      approve_label="reviewed:approve"):
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

        with (
            mock.patch.object(approve_issues, "log"),
            mock.patch.object(approve_issues, "APPROVE_LABEL", approve_label),
            mock.patch.object(approve_issues, "acquire_lock", side_effect=acquire),
            mock.patch.object(approve_issues, "release_lock", side_effect=release),
            mock.patch.object(approve_issues, "get_issue", side_effect=fake_get_issue),
            mock.patch.object(
                approve_issues, "get_comments", side_effect=fake_get_comments
            ),
            mock.patch.object(approve_issues, "run", side_effect=fake_run),
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

    def good(self, **overrides):
        result = approve_issues.reconcile_result(
            "reconciled", message="ok", entries=[self.good_entry()]
        )
        result.update(overrides)
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

    def test_no_asset_still_equates_the_raw_label_with_readiness(self):
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


class ManifestCoverageTests(unittest.TestCase):
    """The two rows this change adds to. The surface lists are enumerated, so
    an asset absent from a row is simply never reconciled against it."""

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

    def test_the_contract_documents_the_reconciliation_authority(self):
        text = (REPO_ROOT / "docs/agent-workflow-contract.md").read_text(encoding="utf-8")
        self.assertIn("--reconcile-approvals", text)
        self.assertIn("approve-issues-reconcile-approvals", text)
        for term in ("Locking", "Result", "Failure semantics", "Decision"):
            self.assertIn(term, text)


class SchemaConstantTests(unittest.TestCase):
    def test_the_schema_is_distinct_from_the_review_queue_document(self):
        self.assertNotEqual(
            approve_issues.RECONCILE_SCHEMA, approve_issues.REVIEW_QUEUE_SCHEMA
        )

    def test_the_document_serializes(self):
        document = approve_issues.reconcile_result(
            "reconciled", message="ok", entries=[]
        )
        self.assertEqual(json.loads(json.dumps(document))["version"], 1)


if __name__ == "__main__":
    unittest.main()
