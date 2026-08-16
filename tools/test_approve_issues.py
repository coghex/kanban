"""Focused tests for the vendored canonical issue-review backend.

These cover the relocation-specific behavior added while vendoring
~/work/approve-issues.py into this repository: portable default paths, the
optional/no-op notification and incident-controller integrations, and a
regression guard against the personal-path dependencies the backend used to
have. Unrelated review-semantics logic (spec fingerprints, marker matching,
reviewer routing, ...) is already covered by `approve_issues.py --self-test`.
"""

import argparse
import contextlib
import io
import json
import os
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


def git(*args: str, cwd: Path) -> str:
    """A real git command in a temporary fixture repository."""
    proc = subprocess.run(
        ["git", *args], cwd=str(cwd), capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise AssertionError(f"git {' '.join(args)} failed in {cwd}:\n{proc.stderr}")
    return proc.stdout.strip()


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


ORIGIN_BODY = "Background\n\n<!-- issue-origin:claude -->\n"


def make_issue(number: int, *, created_at: str, body: str = ORIGIN_BODY) -> dict:
    return {
        "number": number,
        "title": f"Issue {number}",
        "body": body,
        "url": f"https://github.com/acme/example/issues/{number}",
        "state": "OPEN",
        "labels": [],
        "createdAt": created_at,
        "updatedAt": created_at,
        "author": {"login": "coghex"},
    }


class QueueOpenIssuesTests(unittest.TestCase):
    """The review queue's inventory: numeric order, and provably complete."""

    def setUp(self):
        self.ctx = make_ctx(Path("/tmp"))

    def _fetch(self, issues):
        with mock.patch.object(approve_issues, "run_json", return_value=issues) as call:
            fetched = approve_issues.queue_open_issues(self.ctx)
        return fetched, call.call_args.args[0]

    def test_orders_by_issue_number_rather_than_creation_date(self):
        issues = [
            make_issue(3, created_at="2026-02-01T00:00:00Z"),
            make_issue(12, created_at="2025-11-01T00:00:00Z"),
            make_issue(7, created_at="2026-01-01T00:00:00Z"),
        ]
        fetched, _ = self._fetch(issues)
        self.assertEqual([item["number"] for item in fetched], [3, 7, 12])
        # The legacy daemon's order is the opposite one, and stays that way.
        legacy = sorted(issues, key=lambda item: (item["createdAt"], item["number"]))
        self.assertEqual([item["number"] for item in legacy], [12, 7, 3])

    def test_returns_every_entry_of_an_inventory_larger_than_the_legacy_cap(self):
        issues = [
            make_issue(number, created_at="2026-01-01T00:00:00Z")
            for number in range(1, 601)
        ]
        fetched, args = self._fetch(issues)
        self.assertEqual(len(fetched), 600)
        self.assertEqual([item["number"] for item in fetched], list(range(1, 601)))
        # The legacy 500-entry cap would have truncated this backlog.
        self.assertIn(str(approve_issues.REVIEW_QUEUE_INVENTORY_LIMIT), args)
        self.assertNotIn("500", args)

    def test_fails_rather_than_report_a_possibly_truncated_inventory(self):
        issues = [
            make_issue(number, created_at="2026-01-01T00:00:00Z")
            for number in range(1, approve_issues.REVIEW_QUEUE_INVENTORY_LIMIT + 1)
        ]
        with self.assertRaisesRegex(approve_issues.ApproveError, "fetch ceiling"):
            self._fetch(issues)

    def test_excludes_a_pull_request_that_reached_the_inventory(self):
        issues = [make_issue(3, created_at="2026-01-01T00:00:00Z")]
        pull = make_issue(4, created_at="2026-01-01T00:00:00Z")
        pull["url"] = "https://github.com/acme/example/pull/4"
        issues.append(pull)
        fetched, _ = self._fetch(issues)
        self.assertEqual([item["number"] for item in fetched], [3])

    def test_rejects_a_response_that_is_not_a_list(self):
        with self.assertRaisesRegex(
            approve_issues.ApproveError, "Unexpected open-issue inventory"
        ):
            self._fetch({"issues": []})


class ReviewQueueHarness(unittest.TestCase):
    """Drives review_queue over a fake backlog and records an exact event list.

    Follows OrderedReviewBatchTests: acquire_lock, release_lock and the locked
    single-issue review are patched to append events, so the event list is what
    proves ordering, the one-review-per-invocation bound, and that nothing
    above a barrier was even read.

    Only the classification inputs are faked. The scan's own control flow --
    inventory ordering, the incident check, the INVALID refusal, the
    approved skip, the barrier, and the candidate choice -- is the real code.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ctx = make_ctx(Path(self.tmp.name))
        self.lock = object()
        self.events: list[tuple] = []
        self.inventory: list[dict] = []
        self.incidents: list[dict] = []
        # One state table per scan; the last one repeats. Two entries model a
        # backlog that changes between the pre-scan and the locked re-scan.
        self.states: list[dict[int, str]] = [{}]
        self.review_results: dict[int, dict] = {}
        self.review_errors: dict[int, Exception] = {}
        self.model_calls: dict[int, bool] = {}
        self.scan = -1

    def _state(self, number: int) -> str:
        table = self.states[min(max(self.scan, 0), len(self.states) - 1)]
        return table.get(number, "needs")

    def status(self, number, *, approved=False, barrier=False, spec_sha=None):
        reasons = []
        marker = None
        if approved:
            marker = {"verdict": "APPROVE"}
        elif barrier:
            marker = {"verdict": "CHANGES_REQUESTED"}
            reasons.append(approve_issues.CURRENT_CHANGES_REASON)
        else:
            reasons.append(
                "no current opposite-agent v2 review marker matches this spec"
            )
        return {
            "approved": approved,
            "issue": number,
            "labels": [],
            "pipeline_incident": None,
            "reasons": reasons,
            "review_marker": marker,
            "spec_sha": spec_sha or f"spec-{number}",
        }

    def run_queue(self, *, contended=False, legacy_policy="dual"):
        events = self.events

        def fake_run_json(args, *, cwd):
            if args[:3] == ["gh", "issue", "list"]:
                self.scan += 1
                events.append(("inventory", None))
                return list(self.inventory)
            raise AssertionError(f"unexpected run_json call: {args}")

        def fake_get_comments(ctx, number):
            events.append(("comments", number))
            return [{"issue": number}]

        def fake_marker(comments):
            state = self._state(comments[0]["issue"])
            if state == "invalid":
                return {"verdict": "INVALID", "comment_url": "https://example/c"}
            if state == "barrier":
                return {"verdict": "CHANGES_REQUESTED"}
            if state == "approved":
                return {"verdict": "APPROVE"}
            return None

        def fake_gate(issue, comments, *, legacy_policy):
            state = self._state(issue["number"])
            return self.status(
                issue["number"],
                approved=state == "approved",
                barrier=state == "barrier",
            )

        def acquire(*args, **kwargs):
            events.append(("acquire", kwargs))
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

        def review(ctx, number, *, legacy_policy):
            events.append(("review", number))
            if self.model_calls.get(number, True):
                approve_issues.note_model_invocation()
            if number in self.review_errors:
                raise self.review_errors[number]
            return self.review_results[number]

        with (
            mock.patch.object(approve_issues, "log"),
            mock.patch.object(approve_issues, "run_json", side_effect=fake_run_json),
            mock.patch.object(
                approve_issues, "open_pipeline_incidents",
                side_effect=lambda path: list(self.incidents),
            ),
            mock.patch.object(
                approve_issues, "get_comments", side_effect=fake_get_comments
            ),
            mock.patch.object(
                approve_issues, "latest_review_marker", side_effect=fake_marker
            ),
            mock.patch.object(
                approve_issues, "current_gate_status", side_effect=fake_gate
            ),
            mock.patch.object(approve_issues, "acquire_lock", side_effect=acquire),
            mock.patch.object(approve_issues, "release_lock", side_effect=release),
            mock.patch.object(approve_issues, "ensure_verdict_labels") as ensure,
            mock.patch.object(
                approve_issues, "_review_one_locked", side_effect=review
            ),
        ):
            result = approve_issues.review_queue(
                self.ctx, legacy_policy=legacy_policy
            )
        self.ensure = ensure
        return result

    def reviewed(self):
        return [event[1] for event in self.events if event[0] == "review"]

    def read(self):
        return [event[1] for event in self.events if event[0] == "comments"]

    def kinds(self):
        return [event[0] for event in self.events]


class ReviewQueueOrderingTests(ReviewQueueHarness):
    def _backlog(self, *numbers):
        # createdAt runs opposite to issue number, so any pass that inherited
        # the legacy (createdAt, number) order would reach them backwards.
        self.inventory = [
            make_issue(number, created_at=f"2026-01-{40 - number:02d}T00:00:00Z")
            for number in numbers
        ]

    def test_reviews_the_lowest_numbered_issue_needing_review(self):
        self._backlog(12, 3, 7)
        self.states = [{3: "approved"}]
        self.review_results = {7: self.status(7, approved=True)}
        result = self.run_queue()
        self.assertEqual(self.read(), [3, 7, 3, 7])
        self.assertEqual(self.reviewed(), [7])
        self.assertEqual(result["outcome"], "advanced")
        self.assertEqual(result["issue"], 7)

    def test_a_current_approval_is_skipped_with_no_model_call(self):
        self._backlog(3, 7)
        self.states = [{3: "approved", 7: "approved"}]
        result = self.run_queue()
        self.assertEqual(self.reviewed(), [])
        self.assertNotIn("acquire", self.kinds())
        self.assertEqual(result["outcome"], "idle")
        self.assertFalse(result["model_called"])

    def test_a_pre_existing_barrier_stops_the_pass_before_any_lock(self):
        self._backlog(3, 7, 12)
        self.states = [{7: "barrier"}]
        # 3 is approved-complete, 7 is the barrier, 12 needs review and must
        # never be read.
        self.states[0][3] = "approved"
        result = self.run_queue()
        self.assertEqual(self.read(), [3, 7])
        self.assertEqual(self.events, [
            ("inventory", None),
            ("comments", 3),
            ("comments", 7),
        ])
        self.assertEqual(result["outcome"], "changes_requested")
        self.assertEqual(result["issue"], 7)
        self.assertFalse(result["model_called"])

    def test_a_newly_published_changes_requested_stops_the_pass(self):
        self._backlog(7, 12)
        self.review_results = {7: self.status(7, barrier=True)}
        result = self.run_queue()
        self.assertEqual(self.reviewed(), [7])
        self.assertEqual(result["outcome"], "changes_requested")
        self.assertEqual(result["issue"], 7)
        self.assertTrue(result["model_called"])
        # Nothing above the new barrier was reviewed.
        self.assertNotIn(12, self.reviewed())

    def test_only_one_issue_receives_model_work_per_invocation(self):
        self._backlog(3, 7, 12)
        self.review_results = {3: self.status(3, approved=True)}
        result = self.run_queue()
        self.assertEqual(self.reviewed(), [3])
        self.assertEqual(result["outcome"], "advanced")

    def test_idle_on_an_empty_queue(self):
        self.inventory = []
        result = self.run_queue()
        self.assertEqual(self.events, [("inventory", None)])
        self.assertEqual(result["outcome"], "idle")
        self.assertIsNone(result["issue"])
        self.assertFalse(result["model_called"])

    def test_skips_an_unmarked_legacy_issue_when_legacy_review_is_disabled(self):
        self.inventory = [
            make_issue(3, created_at="2026-01-01T00:00:00Z", body="no marker"),
            make_issue(7, created_at="2026-01-01T00:00:00Z"),
        ]
        self.review_results = {7: self.status(7, approved=True)}
        result = self.run_queue(legacy_policy="hold")
        self.assertEqual(self.reviewed(), [7])
        self.assertEqual(result["outcome"], "advanced")


class ReviewQueueLockTests(ReviewQueueHarness):
    def test_busy_on_lock_contention_performs_no_work(self):
        self.inventory = [make_issue(7, created_at="2026-01-01T00:00:00Z")]
        result = self.run_queue(contended=True)
        self.assertEqual(self.reviewed(), [])
        self.assertNotIn("release", self.kinds())
        self.ensure.assert_not_called()
        self.assertEqual(result["outcome"], "busy")
        self.assertIsNone(result["issue"])
        self.assertFalse(result["model_called"])
        self.assertIn("the background approval daemon (PID 4321)", result["message"])

    def test_the_lock_names_the_one_issue_it_was_taken_for(self):
        self.inventory = [make_issue(7, created_at="2026-01-01T00:00:00Z")]
        self.review_results = {7: self.status(7, approved=True)}
        self.run_queue()
        acquire = next(event for event in self.events if event[0] == "acquire")
        self.assertEqual(acquire[1], {"mode": "queue", "issue_number": 7})
        self.assertEqual(self.kinds()[-1], "release")

    def test_the_lock_is_released_when_the_review_fails(self):
        self.inventory = [make_issue(7, created_at="2026-01-01T00:00:00Z")]
        self.review_errors = {7: approve_issues.ApproveError("model outage")}
        with self.assertRaisesRegex(approve_issues.ApproveError, "model outage"):
            self.run_queue()
        self.assertEqual(self.kinds()[-1], "release")

    def test_no_label_is_created_before_the_lock_is_held(self):
        self.inventory = [make_issue(7, created_at="2026-01-01T00:00:00Z")]
        self.review_results = {7: self.status(7, approved=True)}
        self.run_queue()
        kinds = self.kinds()
        self.assertLess(kinds.index("acquire"), kinds.index("review"))
        self.ensure.assert_called_once_with(self.ctx)

    def test_the_locked_rescan_replaces_the_pre_scan_candidate(self):
        self.inventory = [
            make_issue(3, created_at="2026-01-01T00:00:00Z"),
            make_issue(7, created_at="2026-01-01T00:00:00Z"),
        ]
        # #3 was the pre-scan candidate; an interactive review approved it in
        # the window before the lock, so the locked pass advances #7 instead.
        self.states = [{}, {3: "approved"}]
        self.review_results = {7: self.status(7, approved=True)}
        result = self.run_queue()
        acquire = next(event for event in self.events if event[0] == "acquire")
        self.assertEqual(acquire[1]["issue_number"], 3)
        self.assertEqual(self.reviewed(), [7])
        self.assertEqual(result["issue"], 7)

    def test_a_barrier_appearing_under_the_lock_stops_the_pass(self):
        self.inventory = [
            make_issue(3, created_at="2026-01-01T00:00:00Z"),
            make_issue(7, created_at="2026-01-01T00:00:00Z"),
        ]
        self.states = [{3: "approved"}, {3: "barrier"}]
        result = self.run_queue()
        self.assertEqual(self.reviewed(), [])
        self.ensure.assert_not_called()
        self.assertEqual(self.kinds()[-1], "release")
        self.assertEqual(result["outcome"], "changes_requested")
        self.assertEqual(result["issue"], 3)


class ReviewQueuePostReviewTests(ReviewQueueHarness):
    def setUp(self):
        super().setUp()
        self.inventory = [make_issue(7, created_at="2026-01-01T00:00:00Z")]

    def test_advanced_only_after_the_reread_confirms_a_current_approval(self):
        self.review_results = {7: self.status(7, approved=True)}
        result = self.run_queue()
        self.assertEqual(result["outcome"], "advanced")
        self.assertEqual(result["issue"], 7)
        self.assertTrue(result["model_called"])

    def test_label_only_reconciliation_advances_without_a_model_call(self):
        # A current APPROVE marker whose approval label had drifted: the
        # locked pass reconciles the label and re-reads, and no model runs.
        self.model_calls = {7: False}
        self.review_results = {7: self.status(7, approved=True)}
        result = self.run_queue()
        self.assertEqual(self.reviewed(), [7])
        self.assertEqual(result["outcome"], "advanced")
        self.assertFalse(result["model_called"])

    def test_retry_when_the_specification_changed_under_review(self):
        self.review_results = {7: self.status(7, spec_sha="spec-7-edited")}
        result = self.run_queue()
        self.assertEqual(result["outcome"], "retry")
        self.assertEqual(result["issue"], 7)
        self.assertTrue(result["model_called"])
        self.assertIn("changed while it was being reviewed", result["message"])

    def test_an_indeterminate_post_review_state_is_a_failure(self):
        # Neither approved, nor a current changes-requested marker, nor
        # verified specification drift.
        self.review_results = {7: self.status(7)}
        with self.assertRaisesRegex(
            approve_issues.ApproveError, "no determinate review-queue state"
        ):
            self.run_queue()

    def test_an_incident_opened_during_the_review_is_a_failure(self):
        status = self.status(7, approved=True)
        status["pipeline_incident"] = {"incident_id": "inc-1", "issue": 7}
        self.review_results = {7: status}
        with self.assertRaisesRegex(approve_issues.ApproveError, "halted for issue #7"):
            self.run_queue()


class ReviewQueueRefusalTests(ReviewQueueHarness):
    def test_an_invalid_marker_stops_the_pass_before_any_lock(self):
        self.inventory = [
            make_issue(3, created_at="2026-01-01T00:00:00Z"),
            make_issue(7, created_at="2026-01-01T00:00:00Z"),
        ]
        self.states = [{3: "invalid"}]
        with self.assertRaises(approve_issues.InvalidIssueError):
            self.run_queue()
        self.assertNotIn("acquire", self.kinds())
        self.assertEqual(self.read(), [3])

    def test_an_issue_scoped_incident_stops_the_pass_when_the_scan_reaches_it(self):
        self.inventory = [make_issue(7, created_at="2026-01-01T00:00:00Z")]
        self.incidents = [{"incident_id": "inc-9", "issue": 7}]
        with self.assertRaisesRegex(approve_issues.ApproveError, "halted for issue #7"):
            self.run_queue()
        self.assertNotIn("acquire", self.kinds())

    def test_a_scoped_incident_above_the_candidate_does_not_block_it(self):
        self.inventory = [
            make_issue(3, created_at="2026-01-01T00:00:00Z"),
            make_issue(7, created_at="2026-01-01T00:00:00Z"),
        ]
        self.incidents = [{"incident_id": "inc-9", "issue": 7}]
        self.review_results = {3: self.status(3, approved=True)}
        result = self.run_queue()
        self.assertEqual(self.reviewed(), [3])
        self.assertEqual(result["outcome"], "advanced")

    def test_a_repository_wide_incident_stops_the_pass_before_the_inventory(self):
        self.inventory = [make_issue(7, created_at="2026-01-01T00:00:00Z")]
        self.incidents = [{"incident_id": "inc-9", "issue": None}]
        with self.assertRaisesRegex(
            approve_issues.ApproveError, "halted for this repository"
        ):
            self.run_queue()
        self.assertEqual(self.events, [])


class ReviewQueueResultValidationTests(unittest.TestCase):
    """The result document is refused rather than printed when malformed.

    A controller reads an outcome it does not recognize as a failure as
    progress, so every one of these is a hard refusal and a non-zero exit.
    """

    def valid(self, **overrides):
        result = approve_issues.review_queue_result(
            "advanced", issue=7, model_called=True, message="Issue #7 is approved."
        )
        result.update(overrides)
        return result

    def check(self, result, *, approved=True, model_ran=True):
        return approve_issues.validate_review_queue_result(
            result, approved=approved, model_ran=model_ran
        )

    def test_a_well_formed_document_survives(self):
        self.assertEqual(self.check(self.valid())["outcome"], "advanced")

    def test_the_document_carries_exactly_the_pinned_fields(self):
        self.assertEqual(
            set(self.valid()),
            {"schema", "version", "outcome", "issue", "model_called", "message"},
        )
        self.assertEqual(self.valid()["schema"], "approve-issues-review-queue")
        self.assertEqual(self.valid()["version"], 1)

    def test_rejects_a_non_object(self):
        with self.assertRaisesRegex(approve_issues.ApproveError, "not a JSON object"):
            self.check(["advanced"])

    def test_rejects_a_missing_field(self):
        result = self.valid()
        del result["message"]
        with self.assertRaisesRegex(approve_issues.ApproveError, "missing message"):
            self.check(result)

    def test_rejects_an_additional_field(self):
        with self.assertRaisesRegex(approve_issues.ApproveError, "unexpected stopped_at"):
            self.check(self.valid(stopped_at=7))

    def test_rejects_an_unknown_schema(self):
        with self.assertRaisesRegex(approve_issues.ApproveError, "unknown schema"):
            self.check(self.valid(schema="drain-prs-single-pr"))

    def test_rejects_an_unknown_version(self):
        with self.assertRaisesRegex(
            approve_issues.ApproveError, "unknown schema version"
        ):
            self.check(self.valid(version=2))

    def test_rejects_a_boolean_masquerading_as_version_one(self):
        with self.assertRaisesRegex(
            approve_issues.ApproveError, "unknown schema version"
        ):
            self.check(self.valid(version=True))

    def test_rejects_a_stringly_typed_version(self):
        with self.assertRaisesRegex(
            approve_issues.ApproveError, "unknown schema version"
        ):
            self.check(self.valid(version="1"))

    def test_rejects_a_json_float_that_compares_equal_to_version_one(self):
        # json.loads("1.0") is a float, and 1.0 == 1 in Python, so equality
        # alone would let a mistyped version through.
        for version in (1.0, json.loads("1.0")):
            with self.subTest(version=version):
                with self.assertRaisesRegex(
                    approve_issues.ApproveError, "unknown schema version"
                ):
                    self.check(self.valid(version=version))

    def test_rejects_an_unknown_outcome(self):
        with self.assertRaisesRegex(approve_issues.ApproveError, "unknown outcome"):
            self.check(self.valid(outcome="stalled"))

    def test_rejects_an_empty_message(self):
        for message in ("", "   ", None):
            with self.subTest(message=message):
                with self.assertRaisesRegex(
                    approve_issues.ApproveError, "no displayable message"
                ):
                    self.check(self.valid(message=message))

    def test_rejects_a_non_boolean_model_call_claim(self):
        with self.assertRaisesRegex(
            approve_issues.ApproveError, "model_called is not a Boolean"
        ):
            self.check(self.valid(model_called=1))

    def test_rejects_a_model_call_claim_that_disagrees_with_what_ran(self):
        with self.assertRaisesRegex(
            approve_issues.ApproveError, "no reviewer model ran"
        ):
            self.check(self.valid(model_called=True), model_ran=False)
        with self.assertRaisesRegex(
            approve_issues.ApproveError, "a reviewer model ran"
        ):
            self.check(self.valid(model_called=False), model_ran=True)

    def test_rejects_an_issue_bearing_idle_or_busy(self):
        for outcome in ("idle", "busy"):
            with self.subTest(outcome=outcome):
                with self.assertRaisesRegex(
                    approve_issues.ApproveError, "must carry no issue number"
                ):
                    self.check(
                        self.valid(outcome=outcome, issue=7, model_called=False),
                        model_ran=False,
                    )

    def test_rejects_a_non_positive_issue_number(self):
        for number, model_ran in ((None, True), (0, True), (-3, True), (True, True)):
            with self.subTest(number=number):
                with self.assertRaisesRegex(
                    approve_issues.ApproveError, "requires a positive issue number"
                ):
                    self.check(self.valid(issue=number), model_ran=model_ran)

    def test_rejects_advanced_without_a_confirmed_current_approval(self):
        for approved in (False, None):
            with self.subTest(approved=approved):
                with self.assertRaisesRegex(
                    approve_issues.ApproveError, "confirmed a current approval"
                ):
                    self.check(self.valid(), approved=approved)

    def test_changes_requested_and_retry_do_not_need_an_approval(self):
        for outcome in ("changes_requested", "retry"):
            with self.subTest(outcome=outcome):
                self.check(self.valid(outcome=outcome), approved=False)


class ReviewQueueArgumentTests(unittest.TestCase):
    """--review-queue refuses before any GitHub call."""

    def _main(self, argv, *, expect_exit=True):
        with (
            mock.patch("sys.argv", ["approve_issues.py", *argv]),
            mock.patch.object(
                approve_issues,
                "get_repo_context",
                side_effect=AssertionError("reached GitHub"),
            ),
            mock.patch.object(approve_issues, "self_test") as self_test,
            mock.patch.object(approve_issues, "append_log_line"),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            if expect_exit:
                with self.assertRaises(SystemExit) as raised:
                    approve_issues.main()
                code = raised.exception.code
            else:
                approve_issues.main()
                code = 0
        self.self_test = self_test
        self.stdout = stdout.getvalue()
        return code, stderr.getvalue()

    def test_the_flag_parses_as_its_own_mode(self):
        with mock.patch("sys.argv", ["approve_issues.py", "--review-queue", "--json"]):
            args = approve_issues.parse_args()
        self.assertTrue(args.review_queue)
        self.assertIsNone(args.check)
        self.assertIsNone(args.review)
        self.assertIsNone(args.rereview)

    def test_it_joins_the_existing_mutual_exclusion_diagnostic(self):
        for other in (["--check", "1"], ["--review", "1"], ["--rereview", "1"]):
            with self.subTest(other=other):
                code, stderr = self._main(
                    ["--path", ".", "--review-queue", "--json", *other]
                )
                self.assertEqual(code, 1)
                self.assertIn("mutually exclusive", stderr)
                # One diagnostic, naming all four modes.
                self.assertEqual(stderr.count("mutually exclusive"), 1)
                self.assertIn("--review-queue", stderr)

    def test_it_requires_json(self):
        code, stderr = self._main(["--path", ".", "--review-queue"])
        self.assertEqual(code, 1)
        self.assertIn("--review-queue requires --json", stderr)
        self.assertEqual(self.stdout, "")

    def test_self_test_cannot_short_circuit_the_json_requirement(self):
        # --self-test returns early and exits zero, so reaching it first would
        # both skip the --json refusal and print non-JSON text on the stdout
        # a controller parses.
        code, stderr = self._main(["--path", ".", "--review-queue", "--self-test"])
        self.assertEqual(code, 1)
        self.assertIn("--review-queue and --self-test are mutually exclusive", stderr)
        self.self_test.assert_not_called()
        self.assertEqual(self.stdout, "")

    def test_self_test_cannot_replace_the_result_document(self):
        code, stderr = self._main(
            ["--path", ".", "--review-queue", "--json", "--self-test"]
        )
        self.assertEqual(code, 1)
        self.assertIn("--review-queue and --self-test are mutually exclusive", stderr)
        self.self_test.assert_not_called()
        self.assertEqual(self.stdout, "")

    def test_another_mode_combined_with_self_test_is_still_refused_first(self):
        code, stderr = self._main(
            ["--path", ".", "--review-queue", "--json", "--check", "1", "--self-test"]
        )
        self.assertEqual(code, 1)
        self.assertIn("mutually exclusive", stderr)
        self.self_test.assert_not_called()
        self.assertEqual(self.stdout, "")

    def test_self_test_alone_is_untouched(self):
        code, _ = self._main(["--self-test"], expect_exit=False)
        self.assertEqual(code, 0)
        self.self_test.assert_called_once_with()


class ReviewQueueMainTests(unittest.TestCase):
    """--review-queue's exit status and stdout, driven through main().

    An interrupt is a failure for this mode wherever in the run it lands, so
    each test injects one at a different seam: configuration, repository
    resolution, the pass, and the write. Guarding a step at a time would leave
    the next one open, which is why the refusal lives at the single handler
    every interrupt inside the run reaches.
    """

    QUEUE_ARGV = ("--path", ".", "--review-queue", "--json")
    DAEMON_ARGV = ("--path", ".", "--once")

    def _main(
        self,
        *,
        argv=QUEUE_ARGV,
        config=None,
        context=None,
        queue=None,
        emit=None,
        daemon=None,
    ):
        raw = mock.MagicMock()
        raw.remote_name = "origin"
        resolved = mock.MagicMock()
        resolved.workflow.approval_label = "reviewed:approve"
        resolved.workflow.changes_requested_label = "reviewed:changes"
        self.document = approve_issues.review_queue_result(
            "idle", issue=None, model_called=False, message="Nothing to review."
        )

        def raise_or(injected, value):
            if injected is not None:
                raise injected
            return value

        with (
            mock.patch("sys.argv", ["approve_issues.py", *argv]),
            # Restored on exit, so main()'s global assignments cannot leak
            # into another test.
            mock.patch.object(approve_issues, "APPROVE_LABEL", "reviewed:approve"),
            mock.patch.object(approve_issues, "CHANGES_LABEL", "reviewed:changes"),
            mock.patch.object(approve_issues, "VERDICT_LABEL_SPECS", {}),
            mock.patch.object(approve_issues, "LOG_DIR", None),
            mock.patch.object(approve_issues, "PIPELINE_INCIDENT_DIR", Path("/tmp")),
            mock.patch.object(approve_issues, "log"),
            mock.patch.object(approve_issues, "append_log_line"),
            mock.patch.object(
                approve_issues, "resolve_effective_config_path", return_value=None
            ),
            mock.patch.object(
                approve_issues.kanban_config,
                "load_raw_config",
                side_effect=lambda path: raise_or(config, (raw, [])),
            ),
            mock.patch.object(
                approve_issues.kanban_config, "resolve_config", return_value=resolved
            ),
            mock.patch.object(
                approve_issues,
                "get_repo_context",
                side_effect=lambda *a, **k: raise_or(context, make_ctx(Path("/tmp"))),
            ),
            mock.patch.object(
                approve_issues,
                "blocking_pipeline_incident",
                return_value=None,
            ),
            mock.patch.object(
                approve_issues,
                "review_queue",
                side_effect=lambda ctx, **k: raise_or(queue, self.document),
            ),
            mock.patch.object(
                approve_issues,
                "daemon_loop",
                side_effect=lambda ctx, **k: raise_or(daemon, None),
            ),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            with contextlib.ExitStack() as stack:
                if emit is not None:
                    stack.enter_context(
                        mock.patch.object(
                            approve_issues,
                            "emit_review_queue_result",
                            side_effect=emit,
                        )
                    )
                try:
                    approve_issues.main()
                    code = 0
                except SystemExit as exit_code:
                    code = exit_code.code
            return code, stdout.getvalue(), stderr.getvalue()

    def assertInterrupted(self, code, stdout, stderr):
        self.assertEqual(code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("interrupted before it produced a complete result", stderr)

    def test_a_completed_pass_prints_one_document_and_exits_zero(self):
        code, stdout, _ = self._main()
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(stdout), self.document)

    def test_an_interrupt_loading_configuration_is_a_failure(self):
        self.assertInterrupted(*self._main(config=KeyboardInterrupt))

    def test_an_interrupt_resolving_the_repository_is_a_failure(self):
        # get_repo_context makes a GitHub call, so this is the longest
        # pre-queue window an operator can actually interrupt.
        self.assertInterrupted(*self._main(context=KeyboardInterrupt))

    def test_an_interrupt_during_the_pass_is_a_failure(self):
        self.assertInterrupted(*self._main(queue=KeyboardInterrupt))

    def test_an_interrupt_reaching_emission_is_a_failure(self):
        self.assertInterrupted(*self._main(emit=KeyboardInterrupt))

    def test_the_daemon_keeps_its_zero_exit_on_interrupt(self):
        # The shared handler still returns for every other mode; only
        # --review-queue converts an interrupt into a failure.
        code, stdout, stderr = self._main(
            argv=self.DAEMON_ARGV, daemon=KeyboardInterrupt
        )
        self.assertEqual(code, 0)
        self.assertEqual(stdout, "")
        self.assertNotIn("interrupted", stderr)

    def test_the_document_reaches_stdout_in_a_single_write(self):
        # A signal cannot land part-way through one write, so this is what
        # makes a truncated document unreachable. print() would write the
        # terminator separately and reopen that window.
        writes: list[str] = []

        class Recorder(io.StringIO):
            def write(self, text):
                writes.append(text)
                return super().write(text)

        document = approve_issues.review_queue_result(
            "idle", issue=None, model_called=False, message="Nothing to review."
        )
        with mock.patch("sys.stdout", new=Recorder()):
            approve_issues.emit_review_queue_result(document)
        self.assertEqual(len(writes), 1)
        self.assertTrue(writes[0].endswith("\n"))
        self.assertEqual(json.loads(writes[0]), document)

    def test_a_failed_pass_exits_non_zero_with_no_document(self):
        code, stdout, stderr = self._main(
            queue=approve_issues.ApproveError("inventory fetch ceiling")
        )
        self.assertEqual(code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("inventory fetch ceiling", stderr)

    def test_an_invalid_issue_exits_non_zero_with_no_document(self):
        with mock.patch.dict(os.environ, {"APPROVE_ISSUES_MANAGED": "1"}):
            code, stdout, stderr = self._main(
                queue=approve_issues.InvalidIssueError(7, "issue #7 remains INVALID")
            )
        self.assertEqual(code, 1)
        self.assertEqual(stdout, "")
        self.assertIn("INVALID", stderr)


class LegacyDaemonUnchangedTests(unittest.TestCase):
    """The review queue adds a mode; it does not retune the legacy daemon."""

    def setUp(self):
        self.ctx = make_ctx(Path("/tmp"))

    def test_get_open_issues_still_orders_by_creation_date_then_number(self):
        issues = [
            make_issue(3, created_at="2026-02-01T00:00:00Z"),
            make_issue(12, created_at="2025-11-01T00:00:00Z"),
            make_issue(7, created_at="2026-01-01T00:00:00Z"),
        ]
        with mock.patch.object(approve_issues, "run_json", return_value=issues) as call:
            ordered = approve_issues.get_open_issues(self.ctx)
        self.assertEqual([item["number"] for item in ordered], [12, 7, 3])
        self.assertIn("500", call.call_args.args[0])

    def test_select_candidate_still_skips_a_changes_requested_issue(self):
        issues = [
            make_issue(7, created_at="2025-11-01T00:00:00Z"),
            make_issue(3, created_at="2026-01-01T00:00:00Z"),
        ]
        markers = {7: {"verdict": "CHANGES_REQUESTED"}, 3: None}

        def fake_record(comments):
            marker = markers[comments[0]["issue"]]
            return None if marker is None else ({}, marker)

        with (
            mock.patch.object(approve_issues, "log"),
            mock.patch.object(approve_issues, "open_pipeline_incidents", return_value=[]),
            mock.patch.object(approve_issues, "get_open_issues", return_value=issues),
            mock.patch.object(
                approve_issues,
                "get_comments",
                side_effect=lambda ctx, number: [{"issue": number}],
            ),
            mock.patch.object(
                approve_issues, "latest_review_record", side_effect=fake_record
            ),
            mock.patch.object(
                approve_issues, "review_record_matches", return_value=False
            ),
        ):
            selected = approve_issues.select_candidate(self.ctx, legacy_policy="dual")
        self.assertIsNotNone(selected)
        self.assertEqual(selected[0]["number"], 3)


class ApprovalLockPathTests(unittest.TestCase):
    """One lock per repository, not one per checkout.

    Solve and review agents work in linked worktrees and both packaged review
    assets pass `git rev-parse --show-toplevel` through `--path`, so a linked
    worktree is the ordinary caller. There `.git` is a regular file, which is
    what made the join raise NotADirectoryError -- and the repair has to keep
    the two checkouts contending, because a per-worktree lock would trade the
    crash for two canonical reviews of one repository running at once.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.primary = self.root / "primary"
        git("init", "-q", "-b", "master", str(self.primary), cwd=self.root)
        git("config", "user.email", "t@example.com", cwd=self.primary)
        git("config", "user.name", "Test", cwd=self.primary)
        (self.primary / "file.txt").write_text("one\n", encoding="utf-8")
        git("add", "-A", cwd=self.primary)
        git("commit", "-qm", "init", cwd=self.primary)

    def add_worktree(self, name: str) -> Path:
        path = self.root / name
        git("worktree", "add", "-q", "-b", name, str(path), "master", cwd=self.primary)
        return path

    def test_a_linked_worktree_resolves_the_lock_without_crashing(self):
        worktree = self.add_worktree("linked")
        # The precondition the defect turned on: a linked worktree's .git is a
        # file, so the old join opened a path under a non-directory.
        self.assertTrue((worktree / ".git").is_file())
        path = approve_issues.approval_lock_path(make_ctx(worktree))
        lock = approve_issues.acquire_lock(make_ctx(worktree), mode="daemon")
        self.addCleanup(approve_issues.release_lock, lock)
        self.assertTrue(path.exists())

    def test_a_worktree_and_the_primary_checkout_resolve_the_same_file(self):
        worktree = self.add_worktree("linked")
        primary_path = approve_issues.approval_lock_path(make_ctx(self.primary))
        worktree_path = approve_issues.approval_lock_path(make_ctx(worktree))
        self.assertEqual(worktree_path.resolve(), primary_path.resolve())
        # Not the worktree's own administrative directory: that is what
        # --absolute-git-dir would have answered, and nothing else can see it.
        self.assertNotIn("worktrees", worktree_path.parts)

    def test_a_second_checkout_contends_rather_than_taking_its_own_lock(self):
        worktree = self.add_worktree("linked")
        held = approve_issues.acquire_lock(
            make_ctx(self.primary), mode="single", issue_number=7
        )
        self.addCleanup(approve_issues.release_lock, held)
        with self.assertRaises(approve_issues.LockContentionError) as caught:
            approve_issues.acquire_lock(make_ctx(worktree), mode="queue", issue_number=9)
        # Contention behavior is unchanged: the owner metadata the first
        # checkout wrote is what the second one reports.
        self.assertEqual(caught.exception.owner_description[:22], "single-issue review #7")
        self.assertIn("single-issue review #7", str(caught.exception))

    def test_a_plain_git_directory_keeps_its_current_lock_location(self):
        # A lock already held by a running process must still be seen by one
        # started after this change, so the ordinary checkout's path cannot
        # move -- and it is answered without asking git anything.
        def refuse(args, **kwargs):
            raise AssertionError(f"ran a subprocess for a plain .git: {args}")

        with mock.patch.object(approve_issues, "run", side_effect=refuse):
            path = approve_issues.approval_lock_path(make_ctx(self.primary))
        self.assertEqual(path, self.primary / ".git" / "approve_issues.lock")

    def test_an_unresolvable_shared_directory_is_a_named_diagnostic(self):
        # A real git failure, from a worktree whose primary checkout is gone.
        stale = self.root / "stale"
        stale.mkdir()
        (stale / ".git").write_text(
            f"gitdir: {self.root / 'deleted' / 'worktrees' / 'stale'}\n",
            encoding="utf-8",
        )
        with self.assertRaises(approve_issues.ApproveError) as caught:
            approve_issues.approval_lock_path(make_ctx(stale))
        self.assertNotIsInstance(caught.exception, approve_issues.LockContentionError)
        message = str(caught.exception)
        self.assertIn("shared Git directory", message)
        self.assertIn(str(stale), message)

    def test_an_empty_answer_is_a_named_diagnostic_rather_than_the_cwd(self):
        # Exit zero with nothing on stdout would otherwise resolve Path("") to
        # the process working directory.
        worktree = self.add_worktree("linked")
        empty = subprocess.CompletedProcess(args=[], returncode=0, stdout="\n", stderr="")
        with mock.patch.object(approve_issues, "run", return_value=empty):
            with self.assertRaises(approve_issues.ApproveError) as caught:
                approve_issues.approval_lock_path(make_ctx(worktree))
        self.assertIn("shared Git directory", str(caught.exception))

    def test_a_relative_answer_is_anchored_to_the_checkout(self):
        # Git answers relative to the directory it ran in, which is the
        # checkout. Left unanchored the lock would follow the calling
        # process's working directory instead of the repository.
        worktree = self.add_worktree("linked")
        relative = subprocess.CompletedProcess(
            args=[], returncode=0, stdout="../primary/.git\n", stderr=""
        )
        with mock.patch.object(approve_issues, "run", return_value=relative):
            path = approve_issues.approval_lock_path(make_ctx(worktree))
        self.assertTrue(path.is_absolute())
        self.assertEqual(
            path.resolve(), (self.primary / ".git" / "approve_issues.lock").resolve()
        )


class ApprovalLockDiagnosticCLITests(unittest.TestCase):
    """The unresolvable case reaches an operator as a diagnostic, not a
    traceback: main() suppresses tracebacks only for handled error classes,
    which is why the lock raises ApproveError rather than the OSError the
    join used to."""

    def test_the_daemon_reports_the_unresolved_shared_directory_and_exits_one(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            stale = root / "stale"
            stale.mkdir()
            (stale / ".git").write_text(
                f"gitdir: {root / 'deleted' / 'worktrees' / 'stale'}\n", encoding="utf-8"
            )
            raw = mock.MagicMock()
            raw.remote_name = "origin"
            resolved = mock.MagicMock()
            resolved.workflow.approval_label = "reviewed:approve"
            resolved.workflow.changes_requested_label = "reviewed:changes"
            with (
                mock.patch(
                    "sys.argv",
                    ["approve_issues.py", "--path", str(stale), "--once"],
                ),
                mock.patch.object(approve_issues, "LOG_DIR", root / "logs"),
                mock.patch.object(approve_issues, "log"),
                mock.patch.object(approve_issues, "append_log_line"),
                mock.patch.object(
                    approve_issues, "resolve_effective_config_path", return_value=None
                ),
                mock.patch.object(
                    approve_issues.kanban_config,
                    "load_raw_config",
                    return_value=(raw, []),
                ),
                mock.patch.object(
                    approve_issues.kanban_config, "resolve_config", return_value=resolved
                ),
                # The repository is resolved before the lock is taken; this
                # test is about what the lock itself reports.
                mock.patch.object(
                    approve_issues, "get_repo_context", return_value=make_ctx(stale)
                ),
                mock.patch.object(
                    approve_issues, "blocking_pipeline_incident", return_value=None
                ),
                mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
                mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
            ):
                with self.assertRaises(SystemExit) as exit_code:
                    approve_issues.main()
            self.assertEqual(exit_code.exception.code, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("approve-issues.py error:", stderr.getvalue())
            self.assertIn("shared Git directory", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
