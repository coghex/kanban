"""Unit tests for the tracked LaunchAgent controller."""

import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import drain_prs_service


class ControllerConfigurationTests(unittest.TestCase):
    def test_plist_uses_stable_installed_controller_and_selected_repo(self):
        repo = Path("/tmp/example-project")
        install_dir = Path("/tmp/installed-drainer")
        with (
            mock.patch.object(drain_prs_service, "INSTALL_DIR", install_dir),
            mock.patch.object(
                drain_prs_service,
                "CONTROLLER_PATH",
                install_dir / "drain_prs_service.py",
            ),
            mock.patch.object(drain_prs_service, "NTFY_URL", None),
        ):
            value = plistlib.loads(drain_prs_service.render_plist(repo))
        self.assertEqual(
            value["ProgramArguments"][1:],
            [
                str(install_dir / "drain_prs_service.py"),
                "--path",
                str(repo),
                "run",
            ],
        )
        self.assertEqual(value["WorkingDirectory"], str(repo))
        self.assertEqual(
            value["EnvironmentVariables"]["KANBAN_DRAINER_INSTALL_DIR"],
            str(install_dir),
        )
        self.assertNotIn(
            "KANBAN_DRAINER_NTFY_URL", value["EnvironmentVariables"]
        )

    def test_notification_endpoint_is_not_exposed_in_plist(self):
        with mock.patch.object(
            drain_prs_service, "NTFY_URL", "https://notify.example.test/topic"
        ):
            value = plistlib.loads(
                drain_prs_service.render_plist(Path("/tmp/example-project"))
            )
        self.assertNotIn(
            "KANBAN_DRAINER_NTFY_URL", value["EnvironmentVariables"]
        )

    def test_notifications_are_disabled_by_default(self):
        with mock.patch.object(drain_prs_service, "NTFY_URL", None):
            result = drain_prs_service.publish_ntfy("test")
        self.assertEqual(result, {"configured": False, "delivered": False})

    def test_stored_repository_supports_current_and_legacy_status(self):
        expected = Path("/tmp/example-project").resolve()
        self.assertEqual(
            drain_prs_service.stored_repo_path({"repo": str(expected)}), expected
        )
        self.assertEqual(
            drain_prs_service.stored_repo_path(
                {"command": ["drain_prs.py", "--path", str(expected)]}
            ),
            expected,
        )

    def test_incidents_are_filtered_by_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            incident_dir = Path(tmp)
            matching = incident_dir / "incident-2.json"
            other = incident_dir / "incident-1.json"
            matching.write_text(
                json.dumps({"repo": "/tmp/a", "status": "open"}), encoding="utf-8"
            )
            other.write_text(
                json.dumps({"repo": "/tmp/b", "status": "open"}), encoding="utf-8"
            )
            with mock.patch.object(
                drain_prs_service, "INCIDENT_DIR", incident_dir
            ):
                result = drain_prs_service.incident_files(
                    repo_path=Path("/tmp/a"), open_only=True
                )
        self.assertEqual(result, [matching])

    def test_intentional_stop_resolves_all_open_incidents_for_its_repository(self):
        with tempfile.TemporaryDirectory() as tmp:
            incident_dir = Path(tmp)
            matching_one = incident_dir / "incident-3.json"
            matching_two = incident_dir / "incident-2.json"
            other = incident_dir / "incident-1.json"
            already_resolved = incident_dir / "incident-0.json"
            for path, incident in (
                (matching_one, {"repo": "/tmp/a", "status": "open"}),
                (matching_two, {"repo": "/tmp/a", "status": "open"}),
                (other, {"repo": "/tmp/b", "status": "open"}),
                (already_resolved, {"repo": "/tmp/a", "status": "resolved"}),
            ):
                path.write_text(json.dumps(incident), encoding="utf-8")
            with mock.patch.object(drain_prs_service, "INCIDENT_DIR", incident_dir):
                resolved = drain_prs_service.resolve_open_incidents(
                    Path("/tmp/a"), "Cleared when the PR drainer was intentionally stopped."
                )
                matching_one_incident = json.loads(matching_one.read_text(encoding="utf-8"))
                matching_two_incident = json.loads(matching_two.read_text(encoding="utf-8"))
                other_incident = json.loads(other.read_text(encoding="utf-8"))
                already_resolved_incident = json.loads(
                    already_resolved.read_text(encoding="utf-8")
                )
        self.assertEqual(set(resolved), {matching_one, matching_two})
        for incident in (matching_one_incident, matching_two_incident):
            self.assertEqual(incident["status"], "resolved")
            self.assertIn("resolved_at", incident)
            self.assertEqual(
                incident["resolution"],
                "Cleared when the PR drainer was intentionally stopped.",
            )
        self.assertEqual(other_incident["status"], "open")
        self.assertEqual(already_resolved_incident["status"], "resolved")

    def test_stop_clears_incidents_after_the_drainer_has_stopped(self):
        running = {"state": "running"}
        stopped = {"state": "stopped"}
        repo = Path("/tmp/a")
        with (
            mock.patch.object(
                drain_prs_service,
                "status_snapshot",
                side_effect=[running, stopped, stopped],
            ),
            mock.patch.object(drain_prs_service, "run_command") as run_command,
            mock.patch.object(drain_prs_service.time, "sleep"),
            mock.patch.object(
                drain_prs_service,
                "resolve_open_incidents",
                return_value=[Path("incident-1.json"), Path("incident-2.json")],
            ) as resolve_open_incidents,
        ):
            result = drain_prs_service.stop_service(repo)
        run_command.assert_called_once_with(
            ["launchctl", "kill", "SIGTERM", drain_prs_service.launch_target()]
        )
        resolve_open_incidents.assert_called_once_with(
            repo, "Cleared when the PR drainer was intentionally stopped."
        )
        self.assertEqual(result, {"stopped": True, "cleared_incidents": 2, **stopped})

    def test_status_marks_a_stopped_dirty_checkout_as_an_error_state(self):
        repo = Path("/tmp/a")
        with (
            mock.patch.object(drain_prs_service, "read_json", return_value={}),
            mock.patch.object(drain_prs_service, "pid_alive", return_value=False),
            mock.patch.object(drain_prs_service, "lock_pid", return_value=None),
            mock.patch.object(drain_prs_service, "incident_files", return_value=[]),
            mock.patch.object(drain_prs_service, "latest_log_path", return_value=None),
            mock.patch.object(drain_prs_service, "launchd_loaded", return_value=False),
            mock.patch.object(
                drain_prs_service, "working_tree_status", return_value=" M src/Kanban/UI.hs"
            ),
        ):
            result = drain_prs_service.status_snapshot(repo)
        self.assertEqual(result["state"], "dirty")

    def test_start_refuses_a_dirty_checkout_before_installing_or_launching(self):
        repo = Path("/tmp/a")
        with (
            mock.patch.object(drain_prs_service, "working_tree_status", return_value=" M src/Kanban/UI.hs"),
            mock.patch.object(drain_prs_service, "install_job") as install_job,
        ):
            with self.assertRaisesRegex(
                drain_prs_service.ServiceError, "repository has uncommitted changes"
            ):
                drain_prs_service.start_service(repo)
        install_job.assert_not_called()


if __name__ == "__main__":
    unittest.main()
