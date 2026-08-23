"""Pure-logic unit tests for tools/drain_prs.py.

Run with: python3 -m unittest discover -s tools -p 'test_*.py'
"""

import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import drain_prs


class GateConfigTests(unittest.TestCase):
    def _context(self, path):
        return drain_prs.RepoContext(path, "example/project", "project", "master")

    def test_missing_config_uses_legacy_defaults(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = drain_prs.load_gate_config(self._context(Path(tmp)))
        self.assertEqual(
            config.required_ci_check, drain_prs.DEFAULT_REQUIRED_CI_CHECK
        )
        self.assertEqual(
            config.required_review_check, drain_prs.DEFAULT_REQUIRED_REVIEW_CHECK
        )

    def test_repository_can_rename_and_disable_gates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / drain_prs.CONFIG_FILENAME).write_text(
                json.dumps(
                    {
                        "required_ci_check": "build",
                        "required_review_check": None,
                    }
                ),
                encoding="utf-8",
            )
            config = drain_prs.load_gate_config(self._context(root))
        self.assertEqual(config.required_ci_check, "build")
        self.assertIsNone(config.required_review_check)

    def test_unknown_config_key_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / drain_prs.CONFIG_FILENAME).write_text(
                json.dumps({"required_build_check": "build"}),
                encoding="utf-8",
            )
            with self.assertRaises(drain_prs.DrainError):
                drain_prs.load_gate_config(self._context(root))


class ClassifyCheckTests(unittest.TestCase):
    def test_missing_when_none(self):
        self.assertEqual(drain_prs.classify_check(None), "missing")

    def test_pending_when_not_completed(self):
        item = {"status": "IN_PROGRESS", "conclusion": None}
        self.assertEqual(drain_prs.classify_check(item), "pending")

    def test_success_when_completed_and_success(self):
        item = {"status": "COMPLETED", "conclusion": "SUCCESS"}
        self.assertEqual(drain_prs.classify_check(item), "success")

    def test_failure_for_any_other_completed_conclusion(self):
        item = {"status": "COMPLETED", "conclusion": "FAILURE"}
        self.assertEqual(drain_prs.classify_check(item), "failure")

    def test_failure_when_completed_with_missing_conclusion(self):
        item = {"status": "COMPLETED", "conclusion": None}
        self.assertEqual(drain_prs.classify_check(item), "failure")


class LatestCheckTests(unittest.TestCase):
    def test_none_when_no_matches(self):
        pr = {"statusCheckRollup": [{"name": "other-check"}]}
        self.assertIsNone(drain_prs.latest_check(pr, "build-test"))

    def test_picks_max_by_sort_key(self):
        pr = {
            "statusCheckRollup": [
                {"name": "build-test", "completedAt": "2026-01-01T00:00:00Z", "conclusion": "FAILURE"},
                {"name": "build-test", "completedAt": "2026-01-02T00:00:00Z", "conclusion": "SUCCESS"},
                {"name": "other-check", "completedAt": "2026-01-03T00:00:00Z"},
            ]
        }
        result = drain_prs.latest_check(pr, "build-test")
        self.assertEqual(result["conclusion"], "SUCCESS")

    def test_missing_status_check_rollup_treated_as_empty(self):
        self.assertIsNone(drain_prs.latest_check({}, "build-test"))


class ActionsRerunTests(unittest.TestCase):
    def test_extracts_run_id_from_actions_details_url(self):
        check = {
            "detailsUrl": "https://github.com/acme/widgets/actions/runs/12345/job/67890"
        }
        self.assertEqual(drain_prs.action_run_id(check), "12345")

    def test_extracts_job_id_from_actions_details_url(self):
        # The run id is stable across every attempt; the job id is not, which
        # is what tells a rerun's result from the failure that triggered it.
        check = {
            "detailsUrl": "https://github.com/acme/widgets/actions/runs/12345/job/67890"
        }
        self.assertEqual(drain_prs.action_job_id(check), "67890")
        self.assertIsNone(
            drain_prs.action_job_id(
                {"detailsUrl": "https://github.com/acme/widgets/actions/runs/12345"}
            )
        )

    def test_only_completed_per_attempt_evidence_names_an_attempt(self):
        complete = {
            "status": "COMPLETED",
            "conclusion": "FAILURE",
            "startedAt": "2026-08-01T00:00:00Z",
            "completedAt": "2026-08-01T00:10:00Z",
            "detailsUrl": "https://github.com/acme/widgets/actions/runs/12345/job/67890",
        }
        identity = drain_prs.ci_attempt_identity(complete)
        self.assertIsNotNone(identity)
        # The run id alone never carries the answer: a second attempt of the
        # same run has to read differently.
        self.assertNotEqual(
            identity,
            drain_prs.ci_attempt_identity(
                {
                    **complete,
                    "detailsUrl": (
                        "https://github.com/acme/widgets/actions/runs/12345/job/67891"
                    ),
                }
            ),
        )
        self.assertIsNone(drain_prs.ci_attempt_identity(None))
        for missing in (
            {**complete, "status": "IN_PROGRESS", "conclusion": None},
            {**complete, "status": None},
            {**complete, "detailsUrl": "https://example.invalid/build/7"},
            # A run id and no job: everything this names is shared by every
            # attempt of the head, so it names no attempt.
            {**complete, "detailsUrl": (
                "https://github.com/acme/widgets/actions/runs/12345"
            )},
        ):
            with self.subTest(check=missing):
                self.assertIsNone(drain_prs.ci_attempt_identity(missing))

    def test_one_attempts_identity_does_not_move_with_its_timestamps(self):
        # The timestamps are per-attempt but not stable per read: `startedAt`
        # can be absent from one snapshot and present in the next, and either
        # value can come back normalized differently. Two reads of one attempt
        # must still agree, or the second buys a duplicate rerun.
        base = {
            "status": "COMPLETED",
            "conclusion": "FAILURE",
            "detailsUrl": "https://github.com/acme/widgets/actions/runs/12345/job/67890",
        }
        identity = drain_prs.ci_attempt_identity(base)
        self.assertIsNotNone(identity)
        for variation in (
            {"startedAt": "2026-08-01T00:00:00Z"},
            {"startedAt": None, "completedAt": "2026-08-01T00:10:00Z"},
            {"startedAt": "2026-08-01T00:00:00.000Z", "completedAt": ""},
            {"completedAt": "2026-08-01T00:10:00+00:00"},
            {"startedAt": 0, "completedAt": None},
            {"detailsUrl": base["detailsUrl"] + "?check_suite_focus=true"},
        ):
            with self.subTest(variation=variation):
                self.assertEqual(
                    drain_prs.ci_attempt_identity({**base, **variation}), identity
                )

    def _rerun_fixture(self, **entry_overrides):
        ctx = drain_prs.RepoContext(
            Path("/fake-repo"), "acme/widgets", "widgets", "master"
        )
        head = "a" * 40
        entry = {
            "approved_head": head,
            "ci_rerun_head": None,
            "ci_rerun_attempts": 0,
            "ci_rerun_active": False,
            "ci_rerun_attempt_identity": None,
            "ci_rerun_exhausted_head": None,
        }
        entry.update(entry_overrides)
        return ctx, head, {"prs": {"42": entry}}

    def _failed_pr(self, head, *, job="67890", completed="2026-08-01T00:00:00Z"):
        return {
            "number": 42,
            "headRefOid": head,
            "statusCheckRollup": [
                {
                    "name": "build-test",
                    "status": "COMPLETED",
                    "conclusion": "FAILURE",
                    "completedAt": completed,
                    "detailsUrl": (
                        "https://github.com/acme/widgets/actions/runs/12345"
                        f"/job/{job}"
                    ),
                }
            ],
        }

    def test_the_first_failure_of_a_head_requests_one_rerun(self):
        ctx, head, state = self._rerun_fixture()
        pr = self._failed_pr(head)

        with mock.patch.object(drain_prs, "run") as run_mock:
            self.assertEqual(
                drain_prs.rerun_failed_ci(
                    ctx, pr, state=state, check_name="build-test", dry_run=False
                ),
                drain_prs.CI_RERUN_REQUESTED,
            )
        run_mock.assert_called_once_with(
            [
                "gh",
                "run",
                "rerun",
                "12345",
                "--failed",
                "--repo",
                "acme/widgets",
            ],
            cwd=Path("/fake-repo"),
        )
        entry = state["prs"]["42"]
        self.assertEqual(entry["ci_rerun_attempts"], 1)
        self.assertTrue(entry["ci_rerun_active"])
        self.assertEqual(
            entry["ci_rerun_attempt_identity"],
            drain_prs.ci_attempt_identity(pr["statusCheckRollup"][0]),
        )

    def test_the_same_failure_seen_again_below_the_cap_requests_nothing(self):
        # Issue #474 acceptance 1. GitHub does not swap the failed rollup out
        # the moment a rerun is accepted, so the next poll normally sees the
        # very failure the request was made against. It is a barrier: no
        # second `gh run rerun`, no second attempt spent.
        ctx, head, state = self._rerun_fixture()
        pr = self._failed_pr(head)

        with mock.patch.object(drain_prs, "run") as run_mock:
            first = drain_prs.rerun_failed_ci(
                ctx, pr, state=state, check_name="build-test", dry_run=False
            )
            second = drain_prs.rerun_failed_ci(
                ctx, pr, state=state, check_name="build-test", dry_run=False
            )

        self.assertEqual(first, drain_prs.CI_RERUN_REQUESTED)
        self.assertEqual(second, drain_prs.CI_RERUN_IN_FLIGHT)
        self.assertEqual(len(run_mock.mock_calls), 1)
        entry = state["prs"]["42"]
        self.assertEqual(entry["ci_rerun_attempts"], 1)
        self.assertTrue(entry["ci_rerun_active"])
        self.assertIsNone(entry["ci_rerun_exhausted_head"])
        # A barrier is not a skip: process_pr maps this reason back to one.
        self.assertEqual(drain_prs.PASS_OUTCOMES["checks_pending"], drain_prs.PASS_BARRIER)

    def test_the_same_attempt_read_with_new_timestamps_requests_nothing(self):
        # The regression behind that stability: a second poll of the very same
        # job, now carrying timestamps the first snapshot did not, is the same
        # attempt and must stay a barrier.
        ctx, head, state = self._rerun_fixture()
        first = self._failed_pr(head)
        del first["statusCheckRollup"][0]["completedAt"]
        later = self._failed_pr(head, completed="2026-08-01T00:40:00Z")
        later["statusCheckRollup"][0]["startedAt"] = "2026-08-01T00:00:00Z"

        with mock.patch.object(drain_prs, "run") as run_mock:
            decisions = [
                drain_prs.rerun_failed_ci(
                    ctx, snapshot, state=state, check_name="build-test", dry_run=False
                )
                for snapshot in (first, later, later)
            ]

        self.assertEqual(
            decisions,
            [
                drain_prs.CI_RERUN_REQUESTED,
                drain_prs.CI_RERUN_IN_FLIGHT,
                drain_prs.CI_RERUN_IN_FLIGHT,
            ],
        )
        self.assertEqual(len(run_mock.mock_calls), 1)
        self.assertEqual(state["prs"]["42"]["ci_rerun_attempts"], 1)

    def test_an_indistinguishable_failure_holds_the_barrier_at_the_cap(self):
        # The capped request is still in flight, so this is neither another
        # request nor grounds to quarantine the head.
        ctx, head, state = self._rerun_fixture()
        pr = self._failed_pr(head)
        identity = drain_prs.ci_attempt_identity(pr["statusCheckRollup"][0])
        state["prs"]["42"].update(
            {
                "ci_rerun_head": head,
                "ci_rerun_attempts": drain_prs.MAX_CI_RERUN_ATTEMPTS,
                "ci_rerun_active": True,
                "ci_rerun_attempt_identity": identity,
            }
        )

        with mock.patch.object(drain_prs, "run") as run_mock:
            self.assertEqual(
                drain_prs.rerun_failed_ci(
                    ctx, pr, state=state, check_name="build-test", dry_run=False
                ),
                drain_prs.CI_RERUN_IN_FLIGHT,
            )

        self.assertEqual(run_mock.mock_calls, [])
        self.assertIsNone(state["prs"]["42"]["ci_rerun_exhausted_head"])
        self.assertEqual(
            state["prs"]["42"]["ci_rerun_attempts"], drain_prs.MAX_CI_RERUN_ATTEMPTS
        )

    def test_a_completed_attempt_below_the_cap_spends_exactly_one_more(self):
        ctx, head, state = self._rerun_fixture()
        first = self._failed_pr(head)
        later = self._failed_pr(head, job="67891", completed="2026-08-01T00:40:00Z")

        with mock.patch.object(drain_prs, "run") as run_mock:
            drain_prs.rerun_failed_ci(
                ctx, first, state=state, check_name="build-test", dry_run=False
            )
            second = drain_prs.rerun_failed_ci(
                ctx, later, state=state, check_name="build-test", dry_run=False
            )

        self.assertEqual(second, drain_prs.CI_RERUN_REQUESTED)
        self.assertEqual(len(run_mock.mock_calls), 2)
        entry = state["prs"]["42"]
        self.assertEqual(entry["ci_rerun_attempts"], 2)
        self.assertEqual(
            entry["ci_rerun_attempt_identity"],
            drain_prs.ci_attempt_identity(later["statusCheckRollup"][0]),
        )

    def test_rerun_is_capped_per_approved_head(self):
        # Exhaustion counts distinct requested attempts that each came back as
        # a completed failure, so the head is quarantined only when the capped
        # request's own result is finally distinguishable.
        ctx, head, state = self._rerun_fixture()
        snapshots = [
            self._failed_pr(head, job=str(67890 + index), completed=f"2026-08-0{index + 1}T00:00:00Z")
            for index in range(drain_prs.MAX_CI_RERUN_ATTEMPTS + 1)
        ]

        with mock.patch.object(drain_prs, "run") as run_mock:
            decisions = [
                drain_prs.rerun_failed_ci(
                    ctx, snapshot, state=state, check_name="build-test", dry_run=False
                )
                for snapshot in snapshots
            ]

        self.assertEqual(
            decisions,
            [drain_prs.CI_RERUN_REQUESTED] * drain_prs.MAX_CI_RERUN_ATTEMPTS
            + [drain_prs.CI_RERUN_REFUSED],
        )
        self.assertEqual(len(run_mock.mock_calls), drain_prs.MAX_CI_RERUN_ATTEMPTS)
        entry = state["prs"]["42"]
        self.assertEqual(entry["ci_rerun_exhausted_head"], head)
        self.assertFalse(entry["ci_rerun_active"])
        self.assertEqual(
            entry["ci_rerun_attempts"], drain_prs.MAX_CI_RERUN_ATTEMPTS
        )

    def test_a_legacy_active_entry_stays_ambiguous_while_nothing_changes(self):
        # A state file written before ci_rerun_attempt_identity existed says a
        # rerun was requested and nothing about which failure provoked it. No
        # observation can be told apart from that failure -- not on the first
        # upgraded pass and not on any later one.
        ctx, head, state = self._rerun_fixture(
            ci_rerun_head="a" * 40,
            ci_rerun_attempts=1,
            ci_rerun_active=True,
        )
        del state["prs"]["42"]["ci_rerun_attempt_identity"]
        pr = self._failed_pr(head)

        with mock.patch.object(drain_prs, "run") as run_mock:
            decisions = [
                drain_prs.rerun_failed_ci(
                    ctx, pr, state=state, check_name="build-test", dry_run=False
                )
                for _ in range(3)
            ]

        self.assertEqual(decisions, [drain_prs.CI_RERUN_IN_FLIGHT] * 3)
        self.assertEqual(run_mock.mock_calls, [])
        self.assertEqual(state["prs"]["42"]["ci_rerun_attempts"], 1)
        self.assertIsNone(state["prs"]["42"]["ci_rerun_exhausted_head"])

    def test_a_legacy_active_entry_releases_on_a_different_attempt(self):
        # The other half of the upgrade. The first pass keeps what it saw as
        # the baseline it had no record of, so once a genuinely different
        # finished attempt shows up the entry is no longer ambiguous and the
        # next request is due -- without which a legacy entry would hold the
        # lane until a new reviewed head arrived.
        ctx, head, state = self._rerun_fixture(
            ci_rerun_head="a" * 40,
            ci_rerun_attempts=1,
            ci_rerun_active=True,
        )
        del state["prs"]["42"]["ci_rerun_attempt_identity"]

        with mock.patch.object(drain_prs, "run") as run_mock:
            first = drain_prs.rerun_failed_ci(
                ctx,
                self._failed_pr(head),
                state=state,
                check_name="build-test",
                dry_run=False,
            )
            second = drain_prs.rerun_failed_ci(
                ctx,
                self._failed_pr(
                    head, job="67891", completed="2026-08-01T00:40:00Z"
                ),
                state=state,
                check_name="build-test",
                dry_run=False,
            )

        self.assertEqual(first, drain_prs.CI_RERUN_IN_FLIGHT)
        self.assertEqual(second, drain_prs.CI_RERUN_REQUESTED)
        self.assertEqual(len(run_mock.mock_calls), 1)
        self.assertEqual(state["prs"]["42"]["ci_rerun_attempts"], 2)

    def test_a_new_head_starts_the_allowance_over(self):
        ctx, head, state = self._rerun_fixture(
            ci_rerun_head="b" * 40,
            ci_rerun_attempts=drain_prs.MAX_CI_RERUN_ATTEMPTS,
            ci_rerun_active=True,
            ci_rerun_attempt_identity="stale",
            ci_rerun_exhausted_head="b" * 40,
        )
        pr = self._failed_pr(head)

        with mock.patch.object(drain_prs, "run") as run_mock:
            self.assertEqual(
                drain_prs.rerun_failed_ci(
                    ctx, pr, state=state, check_name="build-test", dry_run=False
                ),
                drain_prs.CI_RERUN_REQUESTED,
            )

        self.assertEqual(len(run_mock.mock_calls), 1)
        entry = state["prs"]["42"]
        self.assertEqual(entry["ci_rerun_attempts"], 1)
        self.assertIsNone(entry["ci_rerun_exhausted_head"])


class FailureBackoffAttemptsTests(unittest.TestCase):
    def test_below_threshold_has_no_backoff(self):
        self.assertEqual(drain_prs.failure_backoff_attempts(0), 0)
        self.assertEqual(drain_prs.failure_backoff_attempts(1), 0)

    def test_at_threshold_starts_backoff(self):
        self.assertEqual(
            drain_prs.failure_backoff_attempts(drain_prs.FAILURES_BEFORE_BACKOFF), 1
        )

    def test_grows_exponentially(self):
        self.assertEqual(
            drain_prs.failure_backoff_attempts(drain_prs.FAILURES_BEFORE_BACKOFF + 1), 2
        )
        self.assertEqual(
            drain_prs.failure_backoff_attempts(drain_prs.FAILURES_BEFORE_BACKOFF + 2), 4
        )

    def test_caps_at_max_backoff_attempts(self):
        huge = drain_prs.FAILURES_BEFORE_BACKOFF + 20
        self.assertEqual(
            drain_prs.failure_backoff_attempts(huge), drain_prs.MAX_BACKOFF_ATTEMPTS
        )


class PassCandidateOrderTests(unittest.TestCase):
    """Issue #204: the queue is walked lowest pull-request number first, and
    only a candidate already holding the active lane comes before that.
    """

    def test_empty_queue_has_no_candidates(self):
        self.assertEqual(drain_prs.pass_candidate_order([], None), [])

    def test_lowest_number_first_whatever_last_attempt_says(self):
        # Fair rotation picked #2 here, because it had been attempted least
        # recently. Nothing about attempt history may reorder the queue now.
        approved = [
            {"number": 5, "last_attempt": 1},
            {"number": 2, "last_attempt": 9},
            {"number": 3, "last_attempt": 4},
        ]
        self.assertEqual(drain_prs.pass_candidate_order(approved, None), [2, 3, 5])

    def test_the_active_candidate_is_examined_before_a_lower_number(self):
        approved = [{"number": 9}, {"number": 4}, {"number": 6}]
        self.assertEqual(drain_prs.pass_candidate_order(approved, 6), [6, 4, 9])

    def test_each_candidate_appears_exactly_once(self):
        approved = [{"number": 4}, {"number": 4}, {"number": 2}]
        self.assertEqual(drain_prs.pass_candidate_order(approved, 4), [4, 2])

    def test_an_active_candidate_outside_the_queue_is_ignored(self):
        approved = [{"number": 9}, {"number": 4}]
        self.assertEqual(drain_prs.pass_candidate_order(approved, 7), [4, 9])


class CandidateBlockReasonTests(unittest.TestCase):
    """The two durable blocks a pass can see without reading GitHub. Both skip
    that candidate alone, and both are keyed to the head they were recorded
    against.
    """

    def _state(self, entry):
        return {"attempt_counter": 10, "prs": {"7": entry}}

    def _pr(self, head="a" * 40):
        return {"number": 7, "headRefOid": head}

    def test_unknown_pr_is_not_blocked(self):
        self.assertIsNone(
            drain_prs.candidate_block_reason(
                self._pr(), {"attempt_counter": 10, "prs": {}}
            )
        )

    def test_ready_pr_is_not_blocked(self):
        state = self._state({"retry_after_attempt": 10})
        self.assertIsNone(drain_prs.candidate_block_reason(self._pr(), state))

    def test_cooling_down_until_a_later_pass(self):
        state = self._state({"retry_after_attempt": 11})
        self.assertEqual(
            drain_prs.candidate_block_reason(self._pr(), state), "cooling_down"
        )

    def test_exhausted_ci_reruns_block_that_head(self):
        state = self._state(
            {"retry_after_attempt": 0, "ci_rerun_exhausted_head": "a" * 40}
        )
        self.assertEqual(
            drain_prs.candidate_block_reason(self._pr(), state), "ci_rerun_exhausted"
        )

    def test_a_new_head_clears_the_rerun_quarantine(self):
        state = self._state(
            {"retry_after_attempt": 0, "ci_rerun_exhausted_head": "a" * 40}
        )
        self.assertIsNone(
            drain_prs.candidate_block_reason(self._pr(head="b" * 40), state)
        )


class ClassifyPassOutcomeTests(unittest.TestCase):
    """Every outcome process_pr() can record is classified exactly once, and
    anything else ends the pass rather than reaching the next pull request.
    """

    def test_every_single_pr_no_action_reason_is_classified(self):
        # The single-PR vocabulary and the queue's classification table are the
        # same set of decisions; a reason added to one needs a class in the
        # other, or the queue would fail closed on an ordinary refusal.
        self.assertEqual(
            set(drain_prs.NO_ACTION_REASONS) - set(drain_prs.PASS_OUTCOMES), set()
        )

    def test_skips_let_the_pass_continue(self):
        for reason in (
            "not_eligible",
            "not_approved",
            "changes_requested",
            "merge_conflict",
            "checks_failed",
            "approved_head_changed",
        ):
            with self.subTest(reason=reason):
                self.assertEqual(
                    drain_prs.classify_pass_outcome(reason, raised=False),
                    drain_prs.PASS_SKIP,
                )

    def test_a_branch_update_holds_the_lane(self):
        self.assertEqual(
            drain_prs.classify_pass_outcome("behind_base", raised=False),
            drain_prs.PASS_ADVANCE_HOLD,
        )

    def test_pending_work_is_a_barrier(self):
        for reason in ("checks_pending", "mergeability_computing"):
            with self.subTest(reason=reason):
                self.assertEqual(
                    drain_prs.classify_pass_outcome(reason, raised=False),
                    drain_prs.PASS_BARRIER,
                )

    def test_a_merge_releases_the_lane(self):
        for reason in ("merged", "would_merge", "post_merge_cleanup_failed"):
            with self.subTest(reason=reason):
                self.assertEqual(
                    drain_prs.classify_pass_outcome(reason, raised=False),
                    drain_prs.PASS_ADVANCE_DONE,
                )

    def test_a_classified_refusal_still_skips_when_it_was_raised(self):
        # A wrong base branch and an exhausted failed check both leave
        # process_pr() by raising, and both are candidate-specific.
        for reason in ("not_eligible", "checks_failed"):
            with self.subTest(reason=reason):
                self.assertEqual(
                    drain_prs.classify_pass_outcome(reason, raised=True),
                    drain_prs.PASS_SKIP,
                )

    def test_a_raise_past_any_other_reason_ends_the_pass(self):
        # A failed `gh` call inside a branch update or a merge leaves the
        # reason at whatever preceded it; its effect on GitHub is unknown.
        for reason in ("behind_base", "checks_pending", "merged", "operational_error"):
            with self.subTest(reason=reason):
                self.assertEqual(
                    drain_prs.classify_pass_outcome(reason, raised=True),
                    drain_prs.PASS_FAILURE,
                )

    def test_an_unclassified_reason_ends_the_pass(self):
        self.assertEqual(
            drain_prs.classify_pass_outcome("invented_later", raised=False),
            drain_prs.PASS_FAILURE,
        )


class PassClockTests(unittest.TestCase):
    """A failure cooldown is denominated in passes, so an all-blocked queue
    still expires it: no other pull request has to be attempted first.
    """

    def _state(self):
        return {
            "version": drain_prs.STATE_VERSION,
            "attempt_counter": 0,
            "active_pr": None,
            "prs": {
                "7": {
                    "approved_head": "a" * 40,
                    "consecutive_failures": drain_prs.FAILURES_BEFORE_BACKOFF - 1,
                    "retry_after_attempt": 0,
                    "last_attempt": 0,
                    "last_error": None,
                }
            },
        }

    def test_a_pass_advances_the_counter_by_one(self):
        state = self._state()
        self.assertEqual(drain_prs.begin_drain_pass(state), 1)
        self.assertEqual(drain_prs.begin_drain_pass(state), 2)

    def test_an_attempt_records_the_pass_without_advancing_it(self):
        state = self._state()
        drain_prs.begin_drain_pass(state)
        self.assertEqual(drain_prs.begin_pr_attempt(state, 7), 1)
        self.assertEqual(state["attempt_counter"], 1)
        self.assertEqual(state["prs"]["7"]["last_attempt"], 1)

    def test_a_cooldown_expires_over_passes_that_attempt_nothing(self):
        state = self._state()
        drain_prs.begin_drain_pass(state)
        pr = {"number": 7, "headRefOid": "a" * 40}
        cooldown = drain_prs.record_pr_failure(state, 7, "boom")
        self.assertEqual(cooldown, 1)
        # Skipped for exactly `cooldown` passes, and nothing but the passes
        # themselves has to happen for it to come back.
        drain_prs.begin_drain_pass(state)
        self.assertEqual(
            drain_prs.candidate_block_reason(pr, state), "cooling_down"
        )
        drain_prs.begin_drain_pass(state)
        self.assertIsNone(drain_prs.candidate_block_reason(pr, state))


class ParseReviewMarkerDetailsTests(unittest.TestCase):
    def test_v1_marker_parses_reviewer_head_verdict(self):
        body = (
            "Looks good.\n"
            "<!-- pr-review:v1 reviewer=codex "
            "head=abc123abc123abc123abc123abc123abc123abcd "
            "verdict=APPROVE -->"
        )
        details = drain_prs.parse_review_marker_details(body)
        self.assertEqual(
            details,
            ("codex", "abc123abc123abc123abc123abc123abc123abcd", "APPROVE"),
        )

    def test_v2_marker_parses_reviewer_head_verdict(self):
        body = (
            "Looks good.\n"
            "<!-- pr-review:v2 reviewers=codex models=gpt-5.6-terra@xhigh "
            "head=abc123abc123abc123abc123abc123abc123abcd "
            "verdict=APPROVE -->"
        )
        details = drain_prs.parse_review_marker_details(body)
        self.assertEqual(
            details,
            ("codex", "abc123abc123abc123abc123abc123abc123abcd", "APPROVE"),
        )

    def test_legacy_codex_review_marker_parses_as_codex(self):
        body = (
            "<!-- codex-review head=abc123abc123abc123abc123abc123abc123abcd "
            "verdict=CHANGES_REQUESTED -->"
        )
        details = drain_prs.parse_review_marker_details(body)
        self.assertEqual(
            details,
            ("codex", "abc123abc123abc123abc123abc123abc123abcd", "CHANGES_REQUESTED"),
        )

    def test_no_marker_returns_none(self):
        self.assertIsNone(drain_prs.parse_review_marker_details("just a comment"))

    def test_malformed_marker_missing_verdict_returns_none(self):
        body = (
            "<!-- pr-review:v1 reviewer=codex "
            "head=abc123abc123abc123abc123abc123abc123abcd -->"
        )
        self.assertIsNone(drain_prs.parse_review_marker_details(body))

    def test_malformed_marker_short_head_returns_none(self):
        body = "<!-- pr-review:v1 reviewer=codex head=abc123 verdict=APPROVE -->"
        self.assertIsNone(drain_prs.parse_review_marker_details(body))

    def test_wraps_parse_review_marker_head_and_verdict_only(self):
        body = (
            "<!-- pr-review:v1 reviewer=claude "
            "head=abc123abc123abc123abc123abc123abc123abcd "
            "verdict=APPROVE -->"
        )
        self.assertEqual(
            drain_prs.parse_review_marker(body),
            ("abc123abc123abc123abc123abc123abc123abcd", "APPROVE"),
        )


class MigrateDrainStateTests(unittest.TestCase):
    def test_v1_migrates_to_current_version_and_resets_counter(self):
        state = {"version": 1, "attempt_counter": 99, "prs": {}}
        migrated = drain_prs.migrate_drain_state(state, source="test")
        self.assertEqual(migrated["version"], drain_prs.STATE_VERSION)
        self.assertEqual(migrated["attempt_counter"], 0)

    def test_v2_migrates_to_current_version_and_keeps_its_counter(self):
        # Version 2 differs from 3 only by the cleanup slot, so its attempt
        # bookkeeping stays valid across the upgrade.
        state = {
            "version": 2,
            "attempt_counter": 12,
            "prs": {"42": {"approved_head": "deadbeef", "last_attempt": 11}},
        }
        migrated = drain_prs.migrate_drain_state(state, source="test")
        self.assertEqual(migrated["version"], drain_prs.STATE_VERSION)
        self.assertEqual(migrated["attempt_counter"], 12)
        self.assertEqual(migrated["prs"]["42"]["last_attempt"], 11)
        self.assertIsNone(migrated["prs"]["42"]["cleanup"])

    def test_v3_migrates_forward_owning_no_active_candidate(self):
        # Issue #204: version 3 selected by fair rotation and recorded no lane,
        # so the first pass after the upgrade starts at the lowest number --
        # and everything version 3 did record survives the migration.
        state = {
            "version": 3,
            "attempt_counter": 12,
            "prs": {
                "42": {
                    "approved_head": "deadbeef",
                    "consecutive_failures": 2,
                    "retry_after_attempt": 19,
                    "last_attempt": 11,
                    "last_error": "boom",
                    "ci_rerun_head": "deadbeef",
                    "ci_rerun_attempts": 2,
                    "ci_rerun_active": True,
                    "cleanup": {"pending": [{"kind": "worktree"}]},
                }
            },
        }
        migrated = drain_prs.migrate_drain_state(state, source="test")
        self.assertEqual(migrated["version"], drain_prs.STATE_VERSION)
        self.assertIsNone(migrated["active_pr"])
        entry = migrated["prs"]["42"]
        self.assertEqual(entry["approved_head"], "deadbeef")
        self.assertEqual(entry["consecutive_failures"], 2)
        self.assertEqual(entry["retry_after_attempt"], 19)
        self.assertEqual(entry["ci_rerun_attempts"], 2)
        self.assertTrue(entry["ci_rerun_active"])
        self.assertEqual(entry["cleanup"], {"pending": [{"kind": "worktree"}]})

    def test_an_active_rerun_written_before_the_identity_field_upgrades_whole(self):
        # Issue #474 requirement 8. A file carrying ci_rerun_active = True and
        # no attempt identity is the shape this change has to read: everything
        # it records survives, and the missing evidence is named rather than
        # invented. The pass that then runs against it is asserted in
        # test_integration's QueueOrderTests.
        state = {
            "version": drain_prs.STATE_VERSION,
            "attempt_counter": 12,
            "active_pr": 42,
            "prs": {
                "42": {
                    "approved_head": "deadbeef",
                    "last_rereviewed_head": "cafe",
                    "consecutive_failures": 2,
                    "retry_after_attempt": 19,
                    "last_attempt": 11,
                    "last_error": "boom",
                    "ci_rerun_head": "deadbeef",
                    "ci_rerun_attempts": 2,
                    "ci_rerun_active": True,
                    "ci_rerun_exhausted_head": None,
                    "cleanup": {"pending": [{"kind": "worktree"}]},
                }
            },
        }
        migrated = drain_prs.migrate_drain_state(state, source="test")

        self.assertEqual(migrated["active_pr"], 42)
        self.assertEqual(migrated["attempt_counter"], 12)
        entry = migrated["prs"]["42"]
        self.assertEqual(entry["approved_head"], "deadbeef")
        self.assertEqual(entry["last_rereviewed_head"], "cafe")
        self.assertEqual(entry["consecutive_failures"], 2)
        self.assertEqual(entry["retry_after_attempt"], 19)
        self.assertEqual(entry["last_attempt"], 11)
        self.assertEqual(entry["last_error"], "boom")
        self.assertEqual(entry["ci_rerun_head"], "deadbeef")
        self.assertEqual(entry["ci_rerun_attempts"], 2)
        self.assertTrue(entry["ci_rerun_active"])
        self.assertIsNone(entry["ci_rerun_exhausted_head"])
        self.assertEqual(entry["cleanup"], {"pending": [{"kind": "worktree"}]})
        # The upgrade adds nothing: an absent identity already reads as "no
        # attempt this can be told apart from", and defaulting it would
        # rewrite every entry on load -- which a single-PR run must not do to
        # the pull requests it was not asked about.
        self.assertNotIn("ci_rerun_attempt_identity", entry)
        self.assertIsNone(entry.get("ci_rerun_attempt_identity"))

    def test_a_recorded_active_candidate_is_kept(self):
        state = {
            "version": drain_prs.STATE_VERSION,
            "attempt_counter": 3,
            "active_pr": 42,
            "prs": {"42": {"approved_head": "deadbeef"}},
        }
        self.assertEqual(
            drain_prs.migrate_drain_state(state, source="test")["active_pr"], 42
        )

    def test_an_unreadable_active_candidate_raises(self):
        for active in ("42", 0, -1, True, 4.5):
            with self.subTest(active=active):
                state = {
                    "version": drain_prs.STATE_VERSION,
                    "attempt_counter": 0,
                    "active_pr": active,
                    "prs": {},
                }
                with self.assertRaises(drain_prs.DrainError):
                    drain_prs.migrate_drain_state(state, source="test")

    def test_unsupported_version_raises(self):
        state = {"version": 999, "prs": {}}
        with self.assertRaises(drain_prs.DrainError):
            drain_prs.migrate_drain_state(state, source="test")

    def test_missing_prs_dict_raises(self):
        state = {"version": drain_prs.STATE_VERSION, "prs": "not-a-dict"}
        with self.assertRaises(drain_prs.DrainError):
            drain_prs.migrate_drain_state(state, source="test")

    def test_fills_missing_pr_entry_fields(self):
        state = {
            "version": drain_prs.STATE_VERSION,
            "prs": {"42": {"approved_head": "deadbeef"}},
        }
        migrated = drain_prs.migrate_drain_state(state, source="test")
        entry = migrated["prs"]["42"]
        self.assertEqual(entry["consecutive_failures"], 0)
        self.assertEqual(entry["retry_after_attempt"], 0)
        self.assertEqual(entry["last_attempt"], 0)
        self.assertIsNone(entry["last_error"])
        self.assertIsNone(entry["cleanup"])

    def test_preserves_existing_pr_entry_fields(self):
        state = {
            "version": drain_prs.STATE_VERSION,
            "attempt_counter": 3,
            "prs": {
                "42": {
                    "approved_head": "deadbeef",
                    "consecutive_failures": 2,
                    "retry_after_attempt": 7,
                    "last_attempt": 5,
                    "last_error": "boom",
                }
            },
        }
        migrated = drain_prs.migrate_drain_state(state, source="test")
        self.assertEqual(migrated["prs"]["42"]["consecutive_failures"], 2)
        self.assertEqual(migrated["attempt_counter"], 3)


class PlanCleanupTests(unittest.TestCase):
    """The record a merge leaves behind is built from the PR payload alone and
    carries everything a later cycle needs to retry each obligation on its own.
    """

    def _pr(self, **overrides):
        pr = {
            "number": 42,
            "headRefName": "issue-99-demo",
            "headRefOid": "a" * 40,
            "closingIssuesReferences": [
                {
                    "number": 99,
                    "repository": {"owner": {"login": "acme"}, "name": "widgets"},
                },
                {
                    "number": 4,
                    "repository": {"owner": {"login": "other"}, "name": "tracker"},
                },
            ],
        }
        pr.update(overrides)
        return pr

    def test_each_linked_issue_keeps_its_own_repository(self):
        # Issue numbers are only meaningful per repository, so a cross-repo
        # reference must survive as owner/name#number, not as a bare number.
        record = drain_prs.plan_cleanup(self._pr())
        issues = [item for item in record["pending"] if item["kind"] == "issue"]
        self.assertEqual(
            issues,
            [
                {"kind": "issue", "repo": "acme/widgets", "number": 99},
                {"kind": "issue", "repo": "other/tracker", "number": 4},
            ],
        )

    def test_the_worktree_is_removed_before_the_branch_it_holds(self):
        record = drain_prs.plan_cleanup(self._pr())
        kinds = [item["kind"] for item in record["pending"]]
        self.assertEqual(
            kinds[-4:],
            ["worktree", "local-branch", "remote-branch", "fast-forward"],
        )

    def test_a_pr_closing_no_issue_still_owes_the_rest(self):
        record = drain_prs.plan_cleanup(self._pr(closingIssuesReferences=[]))
        self.assertEqual(
            [item["kind"] for item in record["pending"]],
            ["worktree", "local-branch", "remote-branch", "fast-forward"],
        )
        self.assertEqual(record["failed_passes"], 0)
        self.assertIsNone(record["incident"])

    def test_the_record_round_trips_through_json(self):
        # It is written to the state file, so it must hold nothing but data.
        record = drain_prs.plan_cleanup(self._pr())
        self.assertEqual(json.loads(json.dumps(record)), record)
        self.assertEqual(record["pr"]["headRefOid"], "a" * 40)


class ParseWorktreePorcelainTests(unittest.TestCase):
    def test_parses_single_entry(self):
        output = (
            "worktree /repo/main\n"
            "HEAD abc123\n"
            "branch refs/heads/master\n"
        )
        entries = drain_prs.parse_worktree_porcelain(output)
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["worktree"], "/repo/main")
        self.assertEqual(entries[0]["branch"], "refs/heads/master")

    def test_parses_multiple_entries_separated_by_blank_lines(self):
        output = (
            "worktree /repo/main\n"
            "HEAD abc123\n"
            "branch refs/heads/master\n"
            "\n"
            "worktree /repo/issue-9\n"
            "HEAD def456\n"
            "branch refs/heads/issue-9-fix\n"
        )
        entries = drain_prs.parse_worktree_porcelain(output)
        self.assertEqual(len(entries), 2)
        self.assertEqual(entries[1]["worktree"], "/repo/issue-9")

    def test_malformed_entry_missing_branch_key_is_tolerated(self):
        output = "worktree /repo/detached\nHEAD abc123\ndetached\n"
        entries = drain_prs.parse_worktree_porcelain(output)
        self.assertEqual(len(entries), 1)
        self.assertNotIn("branch", entries[0])

    def test_empty_output_returns_no_entries(self):
        self.assertEqual(drain_prs.parse_worktree_porcelain(""), [])


class SelectMatchingWorktreeTests(unittest.TestCase):
    def _entries(self, *pairs):
        return [{"worktree": path, "branch": branch} for path, branch in pairs]

    def test_exact_branch_match_wins_immediately(self):
        entries = self._entries(
            ("/repo/main", "refs/heads/master"),
            ("/repo/issue-9-fix", "refs/heads/issue-9-fix"),
        )
        result = drain_prs.select_matching_worktree(
            entries,
            main_path=Path("/repo/main"),
            repo_name="widgets",
            branch_name="issue-9-fix",
            issue_numbers=[],
            pr_number=1,
            pr_head_oid=None,
        )
        self.assertEqual(result, Path("/repo/issue-9-fix"))

    def test_main_worktree_path_is_skipped(self):
        entries = self._entries(("/repo/main", "refs/heads/master"))
        result = drain_prs.select_matching_worktree(
            entries,
            main_path=Path("/repo/main"),
            repo_name="widgets",
            branch_name="master",
            issue_numbers=[],
            pr_number=1,
            pr_head_oid=None,
        )
        self.assertIsNone(result)

    def test_lone_fuzzy_name_candidate_is_logged_and_skipped_not_matched(self):
        # A worktree with a *different* branch checked out that merely has a
        # matching issue number in its directory name must never be selected
        # -- basename scoring alone is not positive identification.
        entries = self._entries(
            ("/repo/main", "refs/heads/master"),
            ("/work/issue-9-fix", "refs/heads/some-other-branch"),
        )
        with mock.patch.object(drain_prs, "log") as mock_log:
            result = drain_prs.select_matching_worktree(
                entries,
                main_path=Path("/repo/main"),
                repo_name="widgets",
                branch_name="unrelated-branch",
                issue_numbers=[9],
                pr_number=1,
                pr_head_oid=None,
            )
        self.assertIsNone(result)
        mock_log.assert_called_once()
        message = mock_log.call_args[0][0]
        self.assertIn("PR #1", message)
        self.assertIn("/work/issue-9-fix", message)
        self.assertIn("not verified, leaving in place", message)

    def test_no_candidates_returns_none(self):
        entries = self._entries(("/repo/main", "refs/heads/master"))
        result = drain_prs.select_matching_worktree(
            entries,
            main_path=Path("/repo/main"),
            repo_name="widgets",
            branch_name="unrelated-branch",
            issue_numbers=[404],
            pr_number=1,
            pr_head_oid=None,
        )
        self.assertIsNone(result)

    def test_multiple_equal_score_candidates_raise(self):
        entries = self._entries(
            ("/repo/main", "refs/heads/master"),
            ("/work/issue-9-a", "refs/heads/branch-a"),
            ("/work/issue-9-b", "refs/heads/branch-b"),
        )
        with self.assertRaises(drain_prs.DrainError):
            drain_prs.select_matching_worktree(
                entries,
                main_path=Path("/repo/main"),
                repo_name="widgets",
                branch_name="unrelated-branch",
                issue_numbers=[9],
                pr_number=1,
                pr_head_oid=None,
            )

    def test_detached_worktree_with_exact_head_match_is_selected_independent_of_name(
        self,
    ):
        entries = [
            {"worktree": "/repo/main", "branch": "refs/heads/master"},
            {
                "worktree": "/work/totally-unrelated-name",
                "detached": "",
                "HEAD": "deadbeef" * 5,
            },
        ]
        result = drain_prs.select_matching_worktree(
            entries,
            main_path=Path("/repo/main"),
            repo_name="widgets",
            branch_name="issue-9-fix",
            issue_numbers=[],
            pr_number=1,
            pr_head_oid="deadbeef" * 5,
        )
        self.assertEqual(result, Path("/work/totally-unrelated-name"))

    def test_detached_worktree_with_non_matching_head_does_not_match(self):
        entries = [
            {"worktree": "/repo/main", "branch": "refs/heads/master"},
            {"worktree": "/work/detached", "detached": "", "HEAD": "ancestor0" * 5},
        ]
        with mock.patch.object(drain_prs, "log") as mock_log:
            result = drain_prs.select_matching_worktree(
                entries,
                main_path=Path("/repo/main"),
                repo_name="widgets",
                branch_name="issue-9-fix",
                issue_numbers=[],
                pr_number=1,
                pr_head_oid="deadbeef" * 5,
            )
        self.assertIsNone(result)
        mock_log.assert_called_once()
        message = mock_log.call_args[0][0]
        self.assertIn("PR #1", message)
        self.assertIn("/work/detached", message)
        self.assertIn("not verified, leaving in place", message)

    def test_multiple_detached_exact_head_matches_raise(self):
        entries = [
            {"worktree": "/repo/main", "branch": "refs/heads/master"},
            {"worktree": "/work/a", "detached": "", "HEAD": "deadbeef" * 5},
            {"worktree": "/work/b", "detached": "", "HEAD": "deadbeef" * 5},
        ]
        with self.assertRaises(drain_prs.DrainError):
            drain_prs.select_matching_worktree(
                entries,
                main_path=Path("/repo/main"),
                repo_name="widgets",
                branch_name="issue-9-fix",
                issue_numbers=[],
                pr_number=1,
                pr_head_oid="deadbeef" * 5,
            )

    def test_detached_entry_missing_head_field_is_unverified(self):
        entries = [
            {"worktree": "/repo/main", "branch": "refs/heads/master"},
            {"worktree": "/work/detached-unknown", "detached": ""},
        ]
        with mock.patch.object(drain_prs, "log") as mock_log:
            result = drain_prs.select_matching_worktree(
                entries,
                main_path=Path("/repo/main"),
                repo_name="widgets",
                branch_name="issue-9-fix",
                issue_numbers=[9],
                pr_number=1,
                pr_head_oid="deadbeef" * 5,
            )
        self.assertIsNone(result)
        mock_log.assert_called_once()
        message = mock_log.call_args[0][0]
        self.assertIn("PR #1", message)
        self.assertIn("/work/detached-unknown", message)
        self.assertIn("not verified, leaving in place", message)

    def test_missing_pr_head_oid_treats_detached_candidate_as_unverified(self):
        entries = [
            {"worktree": "/repo/main", "branch": "refs/heads/master"},
            {"worktree": "/work/detached", "detached": "", "HEAD": "abc123"},
        ]
        with mock.patch.object(drain_prs, "log") as mock_log:
            result = drain_prs.select_matching_worktree(
                entries,
                main_path=Path("/repo/main"),
                repo_name="widgets",
                branch_name="issue-9-fix",
                issue_numbers=[],
                pr_number=1,
                pr_head_oid=None,
            )
        self.assertIsNone(result)
        mock_log.assert_called_once()
        message = mock_log.call_args[0][0]
        self.assertIn("PR #1", message)
        self.assertIn("/work/detached", message)
        self.assertIn("not verified, leaving in place", message)

    def test_entry_missing_both_branch_and_detached_marker_is_not_matched(self):
        # A permissively parsed / malformed porcelain entry that lacks both
        # "branch" and the explicit "detached" marker must never be treated
        # as a positively identified detached worktree, even if its "HEAD"
        # happens to equal the PR head SHA -- and must still be logged as
        # unverified, like any other undetermined candidate.
        entries = [
            {"worktree": "/repo/main", "branch": "refs/heads/master"},
            {"worktree": "/work/malformed", "HEAD": "deadbeef" * 5},
        ]
        with mock.patch.object(drain_prs, "log") as mock_log:
            result = drain_prs.select_matching_worktree(
                entries,
                main_path=Path("/repo/main"),
                repo_name="widgets",
                branch_name="issue-9-fix",
                issue_numbers=[],
                pr_number=1,
                pr_head_oid="deadbeef" * 5,
            )
        self.assertIsNone(result)
        mock_log.assert_called_once()
        message = mock_log.call_args[0][0]
        self.assertIn("PR #1", message)
        self.assertIn("/work/malformed", message)
        self.assertIn("not verified, leaving in place", message)

    def test_fuzzy_tie_raises_even_when_an_unrelated_detached_match_exists(self):
        # The fuzzy name-score tie check must run before any
        # positive-identification step, including the detached exact-HEAD
        # match -- so a tied fuzzy pair still raises even when some other
        # detached worktree in the same list is a genuine, unambiguous match.
        entries = [
            {"worktree": "/repo/main", "branch": "refs/heads/master"},
            {"worktree": "/work/detached", "detached": "", "HEAD": "deadbeef" * 5},
            {"worktree": "/work/issue-24-a", "branch": "refs/heads/branch-a"},
            {"worktree": "/work/issue-24-b", "branch": "refs/heads/branch-b"},
        ]
        with self.assertRaises(drain_prs.DrainError):
            drain_prs.select_matching_worktree(
                entries,
                main_path=Path("/repo/main"),
                repo_name="widgets",
                branch_name="issue-9-fix",
                issue_numbers=[24],
                pr_number=1,
                pr_head_oid="deadbeef" * 5,
            )


class ExtractIssueNumbersTests(unittest.TestCase):
    def test_combines_closing_issues_and_branch_name(self):
        pr = {
            "closingIssuesReferences": [{"number": 5}, {"number": 9}],
            "headRefName": "issue-9-fix-something",
        }
        self.assertEqual(drain_prs.extract_issue_numbers(pr), [5, 9])

    def test_deduplicates_and_sorts(self):
        pr = {
            "closingIssuesReferences": [{"number": 9}],
            "headRefName": "issue-9-and-issue-3",
        }
        self.assertEqual(drain_prs.extract_issue_numbers(pr), [3, 9])

    def test_no_issue_references_returns_empty_list(self):
        pr = {"headRefName": "chore-cleanup"}
        self.assertEqual(drain_prs.extract_issue_numbers(pr), [])


class ConfiguredLabelsTests(unittest.TestCase):
    """drain_prs.py's main() reassigns APPROVE_LABEL/CHANGES_LABEL from the
    resolved kanban_config.toml at startup (see main()). These tests exercise
    that same reassignment mechanism directly, without any real GitHub calls."""

    def _context(self, path):
        return drain_prs.RepoContext(path, "example/project", "project", "master")

    def test_get_open_approved_prs_honors_a_configured_approval_label(self):
        prs = [
            {
                "number": 1,
                "labels": [{"name": "custom:approve"}],
                "isDraft": False,
                "headRefOid": "a" * 40,
            },
            {
                "number": 2,
                "labels": [{"name": "reviewed:approve"}],
                "isDraft": False,
                "headRefOid": "b" * 40,
            },
        ]
        with (
            mock.patch.object(drain_prs, "APPROVE_LABEL", "custom:approve"),
            mock.patch.object(drain_prs, "CHANGES_LABEL", "custom:changes"),
            mock.patch.object(drain_prs, "run_json", return_value=prs),
        ):
            approved = drain_prs.get_open_approved_prs(
                self._context(Path("/tmp")), dry_run=True
            )
        self.assertEqual([pr["number"] for pr in approved], [1])


if __name__ == "__main__":
    unittest.main()
