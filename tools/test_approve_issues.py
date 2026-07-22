"""Focused tests for the vendored canonical issue-review backend.

These cover the relocation-specific behavior added while vendoring
~/work/approve-issues.py into this repository: portable default paths, the
optional/no-op notification and incident-controller integrations, and a
regression guard against the personal-path dependencies the backend used to
have. Unrelated review-semantics logic (spec fingerprints, marker matching,
reviewer routing, ...) is already covered by `approve_issues.py --self-test`.
"""

import json
import subprocess
import tempfile
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

    def test_is_idempotent_and_does_not_duplicate_an_open_incident(self):
        with mock.patch.object(approve_issues, "PIPELINE_INCIDENT_DIR", self.incident_dir):
            with mock.patch.object(approve_issues, "NTFY_URL", None):
                first = approve_issues.open_invalid_incident(self.ctx, 7, "first")
                second = approve_issues.open_invalid_incident(self.ctx, 7, "second")
        self.assertEqual(first["incident_id"], second["incident_id"])
        self.assertEqual(len(list(self.incident_dir.glob("incident-*.json"))), 1)

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
                {"approved": True, "reasons": []}, self.repo_path
            )
        self.assertFalse(status["approved"])
        self.assertIsNotNone(status["pipeline_incident"])


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
