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


class ChooseNextPrTests(unittest.TestCase):
    def _state(self, prs):
        return {"attempt_counter": 10, "prs": prs}

    def test_empty_list_returns_none(self):
        result, probing = drain_prs.choose_next_pr([], self._state({}))
        self.assertIsNone(result)
        self.assertFalse(probing)

    def test_picks_ready_pr_with_oldest_last_attempt(self):
        approved = [{"number": 1}, {"number": 2}]
        state = self._state(
            {
                "1": {"retry_after_attempt": 0, "last_attempt": 5},
                "2": {"retry_after_attempt": 0, "last_attempt": 2},
            }
        )
        selected, probing = drain_prs.choose_next_pr(approved, state)
        self.assertEqual(selected["number"], 2)
        self.assertFalse(probing)

    def test_ties_broken_by_pr_number(self):
        approved = [{"number": 5}, {"number": 3}]
        state = self._state(
            {
                "5": {"retry_after_attempt": 0, "last_attempt": 1},
                "3": {"retry_after_attempt": 0, "last_attempt": 1},
            }
        )
        selected, probing = drain_prs.choose_next_pr(approved, state)
        self.assertEqual(selected["number"], 3)

    def test_all_cooling_down_probes_soonest_due(self):
        approved = [{"number": 1}, {"number": 2}]
        state = self._state(
            {
                "1": {"retry_after_attempt": 20, "last_attempt": 1},
                "2": {"retry_after_attempt": 15, "last_attempt": 1},
            }
        )
        selected, probing = drain_prs.choose_next_pr(approved, state)
        self.assertEqual(selected["number"], 2)
        self.assertTrue(probing)


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

    def test_missing_pr_head_oid_treats_detached_candidate_as_unverified(self):
        entries = [
            {"worktree": "/repo/main", "branch": "refs/heads/master"},
            {"worktree": "/work/detached", "detached": "", "HEAD": "abc123"},
        ]
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

    def test_entry_missing_both_branch_and_detached_marker_is_not_matched(self):
        # A permissively parsed / malformed porcelain entry that lacks both
        # "branch" and the explicit "detached" marker must never be treated
        # as a positively identified detached worktree, even if its "HEAD"
        # happens to equal the PR head SHA.
        entries = [
            {"worktree": "/repo/main", "branch": "refs/heads/master"},
            {"worktree": "/work/malformed", "HEAD": "deadbeef" * 5},
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
        self.assertIsNone(result)


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


if __name__ == "__main__":
    unittest.main()
