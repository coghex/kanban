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


if __name__ == "__main__":
    unittest.main()
