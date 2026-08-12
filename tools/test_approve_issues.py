"""Focused tests for the vendored canonical issue-review backend.

These cover the relocation-specific behavior added while vendoring
~/work/approve-issues.py into this repository: portable default paths, the
optional/no-op notification and incident-controller integrations, and a
regression guard against the personal-path dependencies the backend used to
have. Unrelated review-semantics logic (spec fingerprints, marker matching,
reviewer routing, ...) is already covered by `approve_issues.py --self-test`.
"""

import argparse
import json
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

import approve_issues


REPO_ROOT = Path(__file__).resolve().parent.parent
BACKEND_SOURCE = (REPO_ROOT / "tools" / "approve_issues.py").read_text(encoding="utf-8")


class SourceRegressionTests(unittest.TestCase):
    """A fresh clone must not need ~/work or ~/.codex/skills/approve-issues."""

    def test_source_no_longer_references_the_personal_codex_skill_controller(self):
        self.assertNotIn("approve_issues_service.py", BACKEND_SOURCE)

    def test_source_no_longer_hardcodes_the_wrong_repository(self):
        self.assertNotIn("synarchy", BACKEND_SOURCE)

    def test_source_no_longer_hardcodes_a_private_notification_endpoint(self):
        self.assertNotIn("ntfy.sh/coghex", BACKEND_SOURCE)

    def test_source_no_longer_defaults_runtime_state_under_home_work(self):
        self.assertNotIn('Path.home() / "work"', BACKEND_SOURCE)


class ReviewArgumentTests(unittest.TestCase):
    def test_review_accepts_one_issue_as_the_existing_shape(self):
        with mock.patch("sys.argv", ["approve_issues.py", "--review", "7"]):
            args = approve_issues.parse_args()
        self.assertEqual(args.review, [7])

    def test_review_preserves_an_explicit_left_to_right_batch(self):
        with mock.patch(
            "sys.argv",
            ["approve_issues.py", "--review", "7", "3", "12", "4"],
        ):
            args = approve_issues.parse_args()
        self.assertEqual(args.review, [7, 3, 12, 4])

    def test_review_rejects_non_positive_issue_numbers(self):
        for value in ("0", "-4", "not-a-number"):
            with self.subTest(value=value):
                with self.assertRaises(argparse.ArgumentTypeError):
                    approve_issues.positive_issue_number(value)


class PortableDefaultPathTests(unittest.TestCase):
    def test_default_paths_are_kanban_namespaced(self):
        self.assertEqual(approve_issues.INSTALL_DIR.parts[-2:], ("kanban", "issue-review"))
        self.assertEqual(
            approve_issues.DEFAULT_LOG_DIR.parts[-3:], ("Logs", "kanban", "issue-review")
        )
        self.assertEqual(
            approve_issues.DEFAULT_INCIDENT_DIR,
            approve_issues.INSTALL_DIR / "runtime" / "incidents",
        )

    def test_ntfy_url_is_unconfigured_by_default(self):
        # Reflects the module import; explicit configuration is exercised in
        # NotifyModelFailureTests / NotifyIncidentTests via monkeypatching.
        self.assertIsNone(approve_issues.NTFY_URL)


class InstalledConfigReferenceTests(unittest.TestCase):
    """install_issue_review.py persists a --config path beside the installed
    backend (config.json's config_path key) so a backend invoked without an
    explicit --config still resolves the same configured labels/remote
    instead of silently reverting to kanban_config's defaults."""

    def test_returns_none_when_no_reference_file_exists(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "does-not-exist" / "config.json"
            with mock.patch.object(approve_issues, "INSTALLED_CONFIG_REFERENCE_PATH", missing):
                self.assertIsNone(approve_issues.installed_config_reference())

    def test_returns_none_on_corrupt_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            reference = Path(tmp) / "config.json"
            reference.write_text("not json", encoding="utf-8")
            with mock.patch.object(approve_issues, "INSTALLED_CONFIG_REFERENCE_PATH", reference):
                self.assertIsNone(approve_issues.installed_config_reference())

    def test_reads_the_persisted_config_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            reference = Path(tmp) / "config.json"
            reference.write_text(
                json.dumps({"config_path": "/home/user/.config/kanban/config.toml"}),
                encoding="utf-8",
            )
            with mock.patch.object(approve_issues, "INSTALLED_CONFIG_REFERENCE_PATH", reference):
                self.assertEqual(
                    approve_issues.installed_config_reference(),
                    "/home/user/.config/kanban/config.toml",
                )

    def test_explicit_config_always_takes_precedence_over_the_installed_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            reference = Path(tmp) / "config.json"
            reference.write_text(
                json.dumps({"config_path": "/installed/config.toml"}), encoding="utf-8"
            )
            with mock.patch.object(approve_issues, "INSTALLED_CONFIG_REFERENCE_PATH", reference):
                self.assertEqual(
                    approve_issues.resolve_effective_config_path("/explicit/config.toml"),
                    "/explicit/config.toml",
                )
                self.assertEqual(
                    approve_issues.resolve_effective_config_path(None),
                    "/installed/config.toml",
                )


class PullRequestRejectionTests(unittest.TestCase):
    """get_issue refuses a pull-request number.

    GitHub shares one number space, and `gh issue view` resolves a pull
    request into a complete, valid-looking issue document. The guard lives at
    this one fetch funnel because --check, --review and --rereview all pass
    through it, and because it must land before a review reaches
    clear_verdict_labels -- pointed at a pull request, this backend would
    otherwise strip that pull request's approval label and publish an
    issue-review verdict onto it.
    """

    def _context(self, root: Path) -> approve_issues.RepoContext:
        return approve_issues.RepoContext(
            path=root, repo_slug="owner/repo", default_branch="master"
        )

    def _get_issue_returning(self, url: str):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload = {"number": 1080, "title": "t", "body": "", "url": url,
                       "state": "OPEN", "labels": []}
            with mock.patch.object(approve_issues, "run_json", return_value=payload):
                return approve_issues.get_issue(self._context(root), 1080)

    def test_refuses_a_pull_request_url(self):
        with self.assertRaises(SystemExit) as cm:
            self._get_issue_returning("https://github.com/owner/repo/pull/1080")
        self.assertEqual(cm.exception.code, 1)

    def test_accepts_an_ordinary_issue_url(self):
        issue = self._get_issue_returning(
            "https://github.com/owner/repo/issues/1080"
        )
        self.assertEqual(issue["number"], 1080)

    def test_accepts_an_issue_in_a_repository_named_pull(self):
        # `/pull/` appears in this URL, but not as the segment before the
        # number -- a substring test would refuse every issue in that repo.
        issue = self._get_issue_returning("https://github.com/owner/pull/issues/1080")
        self.assertEqual(issue["number"], 1080)


class ParseRepoSlugTests(unittest.TestCase):
    """parse_repo_slug delegates to kanban_config.parse_repository_name, so
    it accepts the same broader remote forms the dashboard's own
    parseRepositoryName does (ssh://, http://, git://, bare owner/name),
    not only git@github.com:/https://github.com/."""

    def test_accepts_the_broader_remote_forms(self):
        self.assertEqual(
            approve_issues.parse_repo_slug("ssh://git@github.com/coghex/kanban.git"),
            "coghex/kanban",
        )
        self.assertEqual(
            approve_issues.parse_repo_slug("coghex/kanban"), "coghex/kanban"
        )

    def test_raises_approve_error_on_an_unparseable_value(self):
        with self.assertRaises(approve_issues.ApproveError):
            approve_issues.parse_repo_slug("not-a-repo")

    def test_get_repo_context_honors_an_explicit_repo_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls: list[list[str]] = []

            def fake_run(args, *, cwd, **kwargs):
                calls.append(args)
                if args[:2] == ["git", "rev-parse"]:
                    return subprocess.CompletedProcess(args, 0, stdout=f"{root}\n", stderr="")
                if args[:2] == ["gh", "repo"]:
                    return subprocess.CompletedProcess(
                        args, 0, stdout=json.dumps({"defaultBranchRef": {"name": "main"}}), stderr=""
                    )
                raise AssertionError(f"unexpected command: {args}")

            with mock.patch.object(approve_issues, "run", side_effect=fake_run):
                ctx = approve_issues.get_repo_context(root, "origin", "upstream-owner/upstream-repo")
        self.assertEqual(ctx.repo_slug, "upstream-owner/upstream-repo")
        self.assertFalse(any(args[:3] == ["git", "remote", "get-url"] for args in calls))


class ResolveFetchSourceTests(unittest.TestCase):
    """--repo changes ctx.repo_slug for GitHub reads/mutations, but the
    review worktree's own git fetch must resolve a source that actually
    matches repo_slug too — otherwise a fork checkout reviewing an
    explicitly selected upstream repository would still fetch the fork's
    default branch for the worktree it reviews from."""

    def test_uses_the_named_remote_when_it_already_points_at_the_repo(self):
        with mock.patch.object(
            approve_issues,
            "run",
            return_value=subprocess.CompletedProcess(
                [], 0, stdout="git@github.com:coghex/kanban.git\n", stderr=""
            ),
        ):
            source = approve_issues.resolve_fetch_source(Path("/fake"), "origin", "coghex/kanban")
        self.assertEqual(source, "origin")

    def test_falls_back_to_an_explicit_url_when_the_remote_points_elsewhere(self):
        with mock.patch.object(
            approve_issues,
            "run",
            return_value=subprocess.CompletedProcess(
                [], 0, stdout="git@github.com:fork-owner/kanban.git\n", stderr=""
            ),
        ):
            source = approve_issues.resolve_fetch_source(Path("/fake"), "origin", "upstream-owner/kanban")
        self.assertEqual(source, "https://github.com/upstream-owner/kanban.git")

    def test_falls_back_to_an_explicit_url_when_the_remote_is_missing(self):
        with mock.patch.object(
            approve_issues,
            "run",
            return_value=subprocess.CompletedProcess([], 1, stdout="", stderr="no such remote"),
        ):
            source = approve_issues.resolve_fetch_source(Path("/fake"), "origin", "coghex/kanban")
        self.assertEqual(source, "https://github.com/coghex/kanban.git")

    def test_make_review_worktree_fetches_from_the_resolved_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            ctx = make_ctx(Path(tmp), repo_slug="upstream-owner/kanban")
            calls: list[list[str]] = []

            def fake_run(args, *, cwd, **kwargs):
                calls.append(args)
                if args[:3] == ["git", "remote", "get-url"]:
                    return subprocess.CompletedProcess(
                        args, 0, stdout="git@github.com:fork-owner/kanban.git\n", stderr=""
                    )
                if args[:2] == ["git", "fetch"]:
                    return subprocess.CompletedProcess(args, 0, stdout="", stderr="")
                if args[:2] == ["git", "rev-parse"]:
                    return subprocess.CompletedProcess(args, 0, stdout="a" * 40 + "\n", stderr="")
                if args[:2] == ["git", "worktree"]:
                    return subprocess.CompletedProcess(args, 0, stdout="", stderr="")
                raise AssertionError(f"unexpected command: {args}")

            with mock.patch.object(approve_issues, "run", side_effect=fake_run):
                approve_issues.make_review_worktree(ctx, 89)
        fetch_call = next(args for args in calls if args[:2] == ["git", "fetch"])
        self.assertEqual(
            fetch_call,
            ["git", "fetch", "--quiet", "https://github.com/upstream-owner/kanban.git", "main"],
        )
        rev_parse_call = next(args for args in calls if args[:2] == ["git", "rev-parse"])
        self.assertEqual(rev_parse_call, ["git", "rev-parse", "FETCH_HEAD"])


def make_ctx(root: Path, repo_slug: str = "acme/example") -> "approve_issues.RepoContext":
    return approve_issues.RepoContext(path=root, repo_slug=repo_slug, default_branch="main")


class NotifyModelFailureTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ctx = make_ctx(Path(self.tmp.name))
        self.reviewer = approve_issues.CODEX_REVIEWER

    def test_is_a_no_op_when_unconfigured(self):
        with mock.patch.object(approve_issues, "NTFY_URL", None):
            with mock.patch("approve_issues.urllib.request.urlopen") as urlopen:
                approve_issues.notify_model_failure(
                    self.ctx, 42, self.reviewer, approve_issues.ApproveError("boom")
                )
                urlopen.assert_not_called()

    def test_links_the_actual_repository_when_configured(self):
        with mock.patch.object(approve_issues, "NTFY_URL", "https://notify.example.test/topic"):
            with mock.patch("approve_issues.urllib.request.urlopen") as urlopen:
                approve_issues.notify_model_failure(
                    self.ctx, 42, self.reviewer, approve_issues.ApproveError("boom")
                )
                urlopen.assert_called_once()
                request = urlopen.call_args[0][0]
        self.assertEqual(request.full_url, "https://notify.example.test/topic")
        body = request.data.decode("utf-8")
        self.assertIn("https://github.com/acme/example/issues/42", body)
        self.assertNotIn("synarchy", body)

    def test_is_a_no_op_when_managed_by_a_daemon(self):
        with mock.patch.object(approve_issues, "NTFY_URL", "https://notify.example.test/topic"):
            with mock.patch.dict("os.environ", {"APPROVE_ISSUES_MANAGED": "1"}):
                with mock.patch("approve_issues.urllib.request.urlopen") as urlopen:
                    approve_issues.notify_model_failure(
                        self.ctx, 42, self.reviewer, approve_issues.ApproveError("boom")
                    )
                    urlopen.assert_not_called()


class OpenInvalidIncidentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.incident_dir = self.root / "incidents"
        self.repo_path = self.root / "repo"
        self.repo_path.mkdir()
        self.ctx = make_ctx(self.repo_path)

    def test_writes_a_self_contained_incident_without_an_external_controller(self):
        with mock.patch.object(approve_issues, "PIPELINE_INCIDENT_DIR", self.incident_dir):
            with mock.patch.object(approve_issues, "NTFY_URL", None):
                incident = approve_issues.open_invalid_incident(self.ctx, 7, "issue #7 is invalid")
        self.assertEqual(incident["status"], "open")
        self.assertEqual(incident["issue"], 7)
        written = json.loads(
            (self.incident_dir / f"{incident['incident_id']}.json").read_text(encoding="utf-8")
        )
        self.assertEqual(written["repo"], str(self.repo_path.resolve()))

    def test_is_idempotent_per_issue_and_does_not_duplicate_its_own_incident(self):
        with mock.patch.object(approve_issues, "PIPELINE_INCIDENT_DIR", self.incident_dir):
            with mock.patch.object(approve_issues, "NTFY_URL", None):
                first = approve_issues.open_invalid_incident(self.ctx, 7, "first")
                second = approve_issues.open_invalid_incident(self.ctx, 7, "second")
        self.assertEqual(first["incident_id"], second["incident_id"])
        self.assertEqual(len(list(self.incident_dir.glob("incident-*.json"))), 1)

    def test_a_second_invalid_issue_gets_its_own_independently_scoped_incident(self):
        # Deduplicating against any repository incident would have handed
        # issue #8 issue #7's record, leaving #8 unblocked once a record only
        # halts the issue it names.
        with mock.patch.object(approve_issues, "PIPELINE_INCIDENT_DIR", self.incident_dir):
            with mock.patch.object(approve_issues, "NTFY_URL", None):
                first = approve_issues.open_invalid_incident(self.ctx, 7, "issue #7")
                second = approve_issues.open_invalid_incident(self.ctx, 8, "issue #8")
                blocked_seven = approve_issues.blocking_pipeline_incident(self.repo_path, 7)
                blocked_eight = approve_issues.blocking_pipeline_incident(self.repo_path, 8)
                unrelated = approve_issues.blocking_pipeline_incident(self.repo_path, 9)
        self.assertNotEqual(first["incident_id"], second["incident_id"])
        self.assertEqual(len(list(self.incident_dir.glob("incident-*.json"))), 2)
        self.assertEqual(blocked_seven["incident_id"], first["incident_id"])
        self.assertEqual(blocked_eight["incident_id"], second["incident_id"])
        self.assertIsNone(unrelated)

    def test_two_issues_recorded_in_one_second_do_not_share_an_id_or_a_path(self):
        # The identifier used to be timestamp-plus-PID alone, so the second
        # record written by one process inside one second overwrote the first.
        frozen = time.gmtime(0)
        with mock.patch.object(approve_issues, "PIPELINE_INCIDENT_DIR", self.incident_dir):
            with mock.patch.object(approve_issues, "NTFY_URL", None):
                with mock.patch.object(approve_issues.time, "gmtime", return_value=frozen):
                    first = approve_issues.open_invalid_incident(self.ctx, 7, "issue #7")
                    second = approve_issues.open_invalid_incident(self.ctx, 8, "issue #8")
        self.assertNotEqual(first["incident_id"], second["incident_id"])
        written = sorted(path.name for path in self.incident_dir.glob("incident-*.json"))
        self.assertEqual(
            written,
            sorted([f"{first['incident_id']}.json", f"{second['incident_id']}.json"]),
        )

    def test_a_resolved_record_is_neither_reused_nor_overwritten(self):
        frozen = time.gmtime(0)
        with mock.patch.object(approve_issues, "PIPELINE_INCIDENT_DIR", self.incident_dir):
            with mock.patch.object(approve_issues, "NTFY_URL", None):
                with mock.patch.object(approve_issues.time, "gmtime", return_value=frozen):
                    first = approve_issues.open_invalid_incident(self.ctx, 7, "first")
                    resolved_path = self.incident_dir / f"{first['incident_id']}.json"
                    record = json.loads(resolved_path.read_text(encoding="utf-8"))
                    record["status"] = "resolved"
                    resolved_path.write_text(json.dumps(record), encoding="utf-8")
                    second = approve_issues.open_invalid_incident(self.ctx, 7, "second")
        self.assertNotEqual(first["incident_id"], second["incident_id"])
        self.assertEqual(
            json.loads(resolved_path.read_text(encoding="utf-8"))["status"], "resolved"
        )
        self.assertEqual(second["summary"], "second")

    def test_notifies_only_when_configured(self):
        with mock.patch.object(approve_issues, "PIPELINE_INCIDENT_DIR", self.incident_dir):
            with mock.patch.object(approve_issues, "NTFY_URL", "https://notify.example.test/topic"):
                with mock.patch("approve_issues.urllib.request.urlopen") as urlopen:
                    approve_issues.open_invalid_incident(self.ctx, 7, "issue #7 is invalid")
                    urlopen.assert_called_once()
                    body = urlopen.call_args[0][0].data.decode("utf-8")
        self.assertIn("https://github.com/acme/example/issues/7", body)

    def test_circuit_breaker_sees_the_incident_it_wrote(self):
        with mock.patch.object(approve_issues, "PIPELINE_INCIDENT_DIR", self.incident_dir):
            with mock.patch.object(approve_issues, "NTFY_URL", None):
                approve_issues.open_invalid_incident(self.ctx, 7, "issue #7 is invalid")
            status = approve_issues.apply_pipeline_circuit_breaker(
                {"approved": True, "reasons": []}, self.repo_path, issue_number=7
            )
        self.assertFalse(status["approved"])
        self.assertIsNotNone(status["pipeline_incident"])


class ReachedWork(Exception):
    """Raised from a patched acquire_lock to prove a gate let a call past it,
    without running any of the GitHub work that follows."""


class OrderedReviewBatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ctx = make_ctx(Path(self.tmp.name))

    def _status(self, number, *, approved):
        verdict = "APPROVE" if approved else "CHANGES_REQUESTED"
        return {
            "approved": approved,
            "issue": number,
            "labels": [
                approve_issues.APPROVE_LABEL
                if approved
                else approve_issues.CHANGES_LABEL
            ],
            "reasons": (
                []
                if approved
                else ["latest current review verdict is CHANGES_REQUESTED"]
            ),
            "review_marker": {"verdict": verdict},
        }

    def _run(self, numbers, statuses):
        lock = object()
        events = []

        def acquire(*args, **kwargs):
            events.append(("acquire", kwargs))
            return lock

        def review(ctx, number, *, legacy_policy):
            events.append(("review", number))
            return statuses[number]

        def release(handle):
            self.assertIs(handle, lock)
            events.append(("release", None))

        with (
            mock.patch.object(approve_issues, "acquire_lock", side_effect=acquire),
            mock.patch.object(approve_issues, "release_lock", side_effect=release),
            mock.patch.object(approve_issues, "ensure_verdict_labels") as ensure,
            mock.patch.object(
                approve_issues, "_review_one_locked", side_effect=review
            ),
        ):
            result = approve_issues.review_batch(
                self.ctx, numbers, legacy_policy="dual"
            )
        ensure.assert_called_once_with(self.ctx)
        return result, events

    def test_holds_one_lock_while_reviewing_every_issue_in_input_order(self):
        numbers = [7, 3, 12, 4]
        statuses = {number: self._status(number, approved=True) for number in numbers}
        result, events = self._run(numbers, statuses)
        self.assertEqual(
            events,
            [
                ("acquire", {"mode": "batch", "issue_numbers": numbers}),
                ("review", 7),
                ("review", 3),
                ("review", 12),
                ("review", 4),
                ("release", None),
            ],
        )
        self.assertTrue(result["approved"])
        self.assertEqual(result["processed_issues"], numbers)
        self.assertEqual(result["remaining_issues"], [])
        self.assertIsNone(result["stopped_at"])

    def test_stops_at_the_first_changes_requested_result(self):
        numbers = [7, 3, 12, 4]
        statuses = {
            7: self._status(7, approved=True),
            3: self._status(3, approved=False),
            12: self._status(12, approved=True),
            4: self._status(4, approved=True),
        }
        result, events = self._run(numbers, statuses)
        self.assertEqual(
            [event for event in events if event[0] == "review"],
            [("review", 7), ("review", 3)],
        )
        self.assertFalse(result["approved"])
        self.assertEqual(result["processed_issues"], [7, 3])
        self.assertEqual(result["remaining_issues"], [12, 4])
        self.assertEqual(result["stopped_at"], 3)
        self.assertEqual(result["stop_reason"], "changes_requested")

    def test_releases_the_lock_and_fails_on_an_indeterminate_nonapproval(self):
        numbers = [7, 3]
        statuses = {
            7: self._status(7, approved=True),
            3: {
                "approved": False,
                "issue": 3,
                "labels": [],
                "reasons": ["spec changed during review"],
                "review_marker": None,
            },
        }
        lock = object()
        with (
            mock.patch.object(
                approve_issues, "blocking_pipeline_incident", return_value=None
            ),
            mock.patch.object(approve_issues, "acquire_lock", return_value=lock),
            mock.patch.object(approve_issues, "release_lock") as release,
            mock.patch.object(approve_issues, "ensure_verdict_labels"),
            mock.patch.object(
                approve_issues,
                "_review_one_locked",
                side_effect=[statuses[7], statuses[3]],
            ),
        ):
            with self.assertRaisesRegex(
                approve_issues.ApproveError,
                "did not reach an approved or changes-requested state",
            ):
                approve_issues.review_batch(self.ctx, numbers, legacy_policy="dual")
        release.assert_called_once_with(lock)

    def test_a_stale_changes_marker_is_a_terminal_nonapproval(self):
        numbers = [7, 3]
        stale = self._status(3, approved=False)
        stale["reasons"] = ["no current opposite-agent v2 review marker matches this spec"]
        lock = object()
        with (
            mock.patch.object(approve_issues, "acquire_lock", return_value=lock),
            mock.patch.object(approve_issues, "release_lock") as release,
            mock.patch.object(approve_issues, "ensure_verdict_labels"),
            mock.patch.object(
                approve_issues,
                "_review_one_locked",
                side_effect=[self._status(7, approved=True), stale],
            ),
        ):
            with self.assertRaisesRegex(
                approve_issues.ApproveError,
                "did not reach an approved or changes-requested state",
            ):
                approve_issues.review_batch(self.ctx, numbers, legacy_policy="dual")
        release.assert_called_once_with(lock)

    def test_lock_owner_names_the_full_ordered_batch(self):
        owner = {
            "pid": 123,
            "mode": "batch",
            "issues": [7, 3, 12, 4],
        }
        self.assertEqual(
            approve_issues.describe_lock_owner(owner),
            "ordered issue-review batch #7, #3, #12, #4 (PID 123)",
        )


class IncidentScopeTests(unittest.TestCase):
    """An open invalid-issue incident blocks the issue it names, not the
    whole repository.

    A verdict about one issue's specification used to stop every --check,
    --review, --rereview and daemon start for the repository until a human
    cleared the record. Scope now comes from the `issue` field
    open_invalid_incident already persisted, and the breaker fails closed --
    repository-wide, exactly as before -- for any record whose scope cannot
    be established.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.incident_dir = self.root / "incidents"
        self.incident_dir.mkdir()
        self.repo_path = self.root / "repo"
        self.repo_path.mkdir()
        self.other_repo = self.root / "other-repo"
        self.other_repo.mkdir()
        self.ctx = make_ctx(self.repo_path)
        patcher = mock.patch.object(
            approve_issues, "PIPELINE_INCIDENT_DIR", self.incident_dir
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def _write_incident(self, incident_id, *, issue="omit", repo=None, status="open"):
        record = {
            "incident_id": incident_id,
            "status": status,
            "kind": "invalid-issue",
            "repo": str((repo or self.repo_path).resolve()),
            "summary": f"{incident_id} summary",
        }
        if issue != "omit":
            record["issue"] = issue
        path = self.incident_dir / f"{incident_id}.json"
        path.write_text(json.dumps(record), encoding="utf-8")
        return path

    def _check(self, issue_number):
        return approve_issues.apply_pipeline_circuit_breaker(
            {"approved": True, "reasons": []},
            self.repo_path,
            issue_number=issue_number,
        )

    # --- scope classification -------------------------------------------

    def test_only_a_positive_integer_is_a_determinate_scope(self):
        self.assertEqual(approve_issues.incident_issue_scope({"issue": 7}), 7)
        for indeterminate in ({}, {"issue": None}, {"issue": "7"}, {"issue": 0},
                              {"issue": -1}, {"issue": True}, {"issue": 7.0}):
            with self.subTest(record=indeterminate):
                self.assertIsNone(approve_issues.incident_issue_scope(indeterminate))

    def test_the_projection_carries_the_scope_the_incident_persisted(self):
        # It used to be dropped, so nothing downstream could read it.
        self._write_incident("incident-a", issue=7)
        latest = approve_issues.latest_open_pipeline_incident(self.repo_path)
        self.assertEqual(latest["issue"], 7)
        self.assertEqual(
            [record["issue"]
             for record in approve_issues.open_pipeline_incidents(self.repo_path)],
            [7],
        )

    # --- --check ---------------------------------------------------------

    def test_check_blocks_the_named_issue_and_names_it_in_the_reason(self):
        self._write_incident("incident-a", issue=7)
        status = self._check(7)
        self.assertFalse(status["approved"])
        self.assertEqual(status["pipeline_incident"]["incident_id"], "incident-a")
        self.assertEqual(
            status["reasons"][0],
            "issue approval pipeline is halted for issue #7 by open incident incident-a",
        )

    def test_check_leaves_an_unrelated_issue_with_its_ordinary_verdict(self):
        self._write_incident("incident-a", issue=7)
        status = self._check(8)
        self.assertTrue(status["approved"])
        self.assertEqual(status["reasons"], [])
        self.assertIsNone(status["pipeline_incident"])

    def test_a_scopeless_record_still_halts_every_issue(self):
        self._write_incident("incident-a")
        for number in (7, 8):
            with self.subTest(issue=number):
                status = self._check(number)
                self.assertFalse(status["approved"])
                self.assertEqual(
                    status["reasons"][0],
                    "issue approval pipeline is halted for this repository "
                    "by open incident incident-a",
                )

    # --- more than one open record ---------------------------------------

    def test_each_scoped_record_keeps_blocking_its_issue_in_either_order(self):
        # Only the newest record used to be consulted, so whichever incident
        # sorted last silently stopped applying.
        for older, newer in (("incident-a", "incident-b"), ("incident-b", "incident-a")):
            with self.subTest(older=older, newer=newer):
                for path in self.incident_dir.glob("incident-*.json"):
                    path.unlink()
                self._write_incident(older, issue=7)
                self._write_incident(newer, issue=8)
                self.assertFalse(self._check(7)["approved"])
                self.assertFalse(self._check(8)["approved"])
                self.assertTrue(self._check(9)["approved"])

    def test_a_scopeless_record_outranks_scoped_ones_whether_older_or_newer(self):
        for scopeless in ("incident-a", "incident-c"):
            with self.subTest(scopeless=scopeless):
                for path in self.incident_dir.glob("incident-*.json"):
                    path.unlink()
                self._write_incident("incident-b", issue=7)
                self._write_incident(scopeless)
                blocked = self._check(9)
                self.assertFalse(blocked["approved"])
                self.assertEqual(
                    blocked["pipeline_incident"]["incident_id"], scopeless
                )

    def test_resolving_one_record_leaves_the_other_effective(self):
        resolved = self._write_incident("incident-a", issue=7)
        self._write_incident("incident-b", issue=8)
        record = json.loads(resolved.read_text(encoding="utf-8"))
        record["status"] = "resolved"
        resolved.write_text(json.dumps(record), encoding="utf-8")
        self.assertTrue(self._check(7)["approved"])
        self.assertFalse(self._check(8)["approved"])

    # --- --review and --rereview -----------------------------------------

    def _run_gated(self, entry_point, issue_number):
        with mock.patch.object(
            approve_issues, "acquire_lock", side_effect=ReachedWork
        ):
            return entry_point(self.ctx, issue_number, legacy_policy="dual")

    def test_review_and_rereview_refuse_the_named_issue(self):
        self._write_incident("incident-a", issue=7)
        for entry_point in (approve_issues.review_one, approve_issues.rereview_one):
            with self.subTest(entry_point=entry_point.__name__):
                with self.assertRaises(approve_issues.ApproveError) as caught:
                    self._run_gated(entry_point, 7)
                self.assertEqual(
                    str(caught.exception),
                    "Issue approval pipeline is halted for issue #7 "
                    "by open incident incident-a",
                )

    def test_review_and_rereview_proceed_for_an_unrelated_issue(self):
        # ReachedWork comes from the patched lock acquisition immediately
        # after the gate: reaching it is what proves the gate let issue #8 by.
        self._write_incident("incident-a", issue=7)
        for entry_point in (approve_issues.review_one, approve_issues.rereview_one):
            with self.subTest(entry_point=entry_point.__name__):
                with self.assertRaises(ReachedWork):
                    self._run_gated(entry_point, 8)

    def test_review_and_rereview_still_refuse_everything_for_a_scopeless_record(self):
        self._write_incident("incident-a")
        for entry_point in (approve_issues.review_one, approve_issues.rereview_one):
            with self.subTest(entry_point=entry_point.__name__):
                with self.assertRaises(approve_issues.ApproveError):
                    self._run_gated(entry_point, 8)

    # --- the polling daemon ----------------------------------------------

    def test_the_daemon_start_gate_admits_a_scoped_record_and_refuses_a_scopeless_one(self):
        # main() asks blocking_pipeline_incident(ctx.path, None) before
        # daemon_loop: the repository-wide question alone.
        self._write_incident("incident-a", issue=7)
        self.assertIsNone(approve_issues.blocking_pipeline_incident(self.repo_path, None))
        self._write_incident("incident-b")
        self.assertEqual(
            approve_issues.blocking_pipeline_incident(self.repo_path, None)["incident_id"],
            "incident-b",
        )

    def _select_candidate_over(self, numbers):
        issues = [
            {
                "number": number,
                "title": f"Issue {number}",
                "body": "<!-- issue-origin:claude -->",
                "labels": [],
            }
            for number in numbers
        ]
        with mock.patch.object(approve_issues, "get_open_issues", return_value=issues):
            with mock.patch.object(approve_issues, "get_comments", return_value=[]):
                with mock.patch.object(approve_issues, "log") as logged:
                    selected = approve_issues.select_candidate(
                        self.ctx, legacy_policy="dual"
                    )
        messages = [call.args[0] for call in logged.call_args_list]
        return selected, messages

    def test_the_daemon_queue_skips_only_the_named_issue_and_logs_the_skip(self):
        self._write_incident("incident-a", issue=7)
        selected, messages = self._select_candidate_over([7, 8])
        self.assertIsNotNone(selected)
        self.assertEqual(selected[0]["number"], 8)
        self.assertEqual(
            messages,
            [
                "Skipping issue #7: issue approval pipeline is halted for issue #7 "
                "by open incident incident-a"
            ],
        )

    def test_the_daemon_queue_skips_every_issue_for_a_scopeless_record(self):
        self._write_incident("incident-a")
        selected, messages = self._select_candidate_over([7, 8])
        self.assertIsNone(selected)
        self.assertEqual(len(messages), 2)

    def test_the_daemon_queue_is_untouched_with_no_open_incident(self):
        selected, messages = self._select_candidate_over([7, 8])
        self.assertEqual(selected[0]["number"], 7)
        self.assertEqual(messages, [])

    # --- repository confinement ------------------------------------------

    def test_a_scoped_incident_never_reaches_another_checkout(self):
        self._write_incident("incident-a", issue=7, repo=self.other_repo)
        self.assertTrue(self._check(7)["approved"])
        self.assertEqual(
            approve_issues.blocking_pipeline_incident(self.other_repo, 7)["incident_id"],
            "incident-a",
        )

    def test_a_scopeless_incident_never_reaches_another_checkout(self):
        self._write_incident("incident-a", repo=self.other_repo)
        self.assertTrue(self._check(7)["approved"])
        self.assertIsNone(approve_issues.blocking_pipeline_incident(self.repo_path, None))


class ConfiguredLabelsTests(unittest.TestCase):
    """approve_issues.py's main() reassigns APPROVE_LABEL/CHANGES_LABEL from
    the resolved kanban_config.toml at startup (see main()). These tests
    exercise that same reassignment mechanism directly against the pure gate
    and label-application logic, without any real GitHub or model calls."""

    def _issue(self, *, labels):
        return {
            "number": 7,
            "title": "Example",
            "body": "Body",
            "labels": [{"name": name} for name in labels],
            "state": "OPEN",
            "url": "https://example.invalid/7",
        }

    def test_gate_reports_the_configured_approval_label_as_missing(self):
        with (
            mock.patch.object(approve_issues, "APPROVE_LABEL", "custom:approve"),
            mock.patch.object(approve_issues, "CHANGES_LABEL", "custom:changes"),
        ):
            status = approve_issues.current_gate_status(
                self._issue(labels=[]), [], legacy_policy="dual"
            )
        self.assertIn("missing custom:approve", status["reasons"])

    def test_the_stock_label_no_longer_satisfies_the_gate_once_reconfigured(self):
        # An issue still wearing the default reviewed:approve label must not
        # satisfy the gate once the configured label has changed underneath it.
        with (
            mock.patch.object(approve_issues, "APPROVE_LABEL", "custom:approve"),
            mock.patch.object(approve_issues, "CHANGES_LABEL", "custom:changes"),
        ):
            status = approve_issues.current_gate_status(
                self._issue(labels=["reviewed:approve"]), [], legacy_policy="dual"
            )
        self.assertIn("missing custom:approve", status["reasons"])

    def test_the_configured_changes_label_blocks_the_gate(self):
        with (
            mock.patch.object(approve_issues, "APPROVE_LABEL", "custom:approve"),
            mock.patch.object(approve_issues, "CHANGES_LABEL", "custom:changes"),
        ):
            status = approve_issues.current_gate_status(
                self._issue(labels=["custom:approve", "custom:changes"]),
                [],
                legacy_policy="dual",
            )
        self.assertIn("has custom:changes", status["reasons"])

    def test_set_verdict_label_applies_the_configured_approval_label(self):
        ctx = make_ctx(Path("/tmp"))
        calls: list[list[str]] = []

        def fake_run(args, *, cwd, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0, "", "")

        before = self._issue(labels=[])
        after = self._issue(labels=["custom:approve"])
        with (
            mock.patch.object(approve_issues, "APPROVE_LABEL", "custom:approve"),
            mock.patch.object(approve_issues, "CHANGES_LABEL", "custom:changes"),
            mock.patch.object(approve_issues, "run", side_effect=fake_run),
            mock.patch.object(approve_issues, "get_issue", side_effect=[before, after]),
        ):
            approve_issues.set_verdict_label(ctx, 7, "APPROVE")
        self.assertIn("custom:approve", calls[0])
        self.assertNotIn("reviewed:approve", calls[0])


if __name__ == "__main__":
    unittest.main()
