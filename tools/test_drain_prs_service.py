"""Unit tests for the tracked LaunchAgent controller."""

import json
import os
import plistlib
import subprocess
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

    def test_the_plist_path_and_launchd_target_are_derived_from_the_label(self):
        # The property the record exists to extend: one edit to LABEL moves
        # the plist's name and the launchctl target, and — through
        # write_discovery_record — Kanban's discovery, with no other edit
        # anywhere. Nothing else may derive either from a label of its own.
        self.assertEqual(
            drain_prs_service.PLIST_PATH.name, f"{drain_prs_service.LABEL}.plist"
        )
        self.assertTrue(
            drain_prs_service.launch_target().endswith(f"/{drain_prs_service.LABEL}"),
            drain_prs_service.launch_target(),
        )

    def test_the_record_stays_at_a_fixed_path_an_install_dir_cannot_move(self):
        # Kanban never inherits KANBAN_DRAINER_INSTALL_DIR, so an install made
        # with --install-dir has to remain discoverable: the record is the one
        # thing whose location the option must not relocate.
        self.assertEqual(
            drain_prs_service.DISCOVERY_RECORD_PATH,
            Path.home()
            / "Library"
            / "Application Support"
            / "kanban"
            / "pr-drainer"
            / "config.json",
        )
        self.assertEqual(
            drain_prs_service.DEFAULT_INSTALL_DIR,
            drain_prs_service.DISCOVERY_RECORD_PATH.parent,
        )

    def test_the_shared_document_is_read_with_a_legacy_install_dir_copy_under_it(self):
        # A custom install upgraded before its next installer run still has its
        # endpoint beside the script links; losing notifications silently in
        # that window would be worse than reading both.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shared = root / "shared" / "config.json"
            legacy = root / "installed" / "config.json"
            shared.parent.mkdir()
            legacy.parent.mkdir()
            legacy.write_text(
                json.dumps(
                    {
                        "ntfy_url": "https://notify.example.test/legacy",
                        "config_path": "/home/user/legacy.toml",
                    }
                ),
                encoding="utf-8",
            )
            shared.write_text(
                json.dumps({"ntfy_url": "https://notify.example.test/current"}),
                encoding="utf-8",
            )
            with (
                mock.patch.object(drain_prs_service, "CONFIG_PATH", shared),
                mock.patch.object(drain_prs_service, "LEGACY_CONFIG_PATH", legacy),
                mock.patch.dict(os.environ, {}, clear=False),
            ):
                # The environment override outranks both documents, so it must
                # not be what this test is actually reading.
                os.environ.pop("KANBAN_DRAINER_NTFY_URL", None)
                self.assertEqual(
                    drain_prs_service.configured_ntfy_url(),
                    "https://notify.example.test/current",
                )
                self.assertEqual(
                    drain_prs_service.configured_config_path(), "/home/user/legacy.toml"
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

    def test_conflict_incidents_are_keyed_per_pull_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            incident_dir = Path(tmp)
            with (
                mock.patch.object(drain_prs_service, "INCIDENT_DIR", incident_dir),
                mock.patch.object(drain_prs_service, "NTFY_URL", None),
            ):
                first = drain_prs_service.record_conflict_incident(
                    repo_path=Path("/tmp/a"), pull_request=42, files=["README"]
                )
                repeat = drain_prs_service.record_conflict_incident(
                    repo_path=Path("/tmp/a"), pull_request=42, files=["README"]
                )
                other = drain_prs_service.record_conflict_incident(
                    repo_path=Path("/tmp/a"), pull_request=43, files=["docs/x.md"]
                )
                files = sorted(path.name for path in incident_dir.glob("*.json"))

        # A second poll over the same unresolved conflict returns the open
        # incident rather than opening a duplicate.
        self.assertEqual(repeat["incident_id"], first["incident_id"])
        self.assertNotEqual(other["incident_id"], first["incident_id"])
        self.assertEqual(len(files), 2)
        self.assertEqual(first["kind"], drain_prs_service.CONFLICT_INCIDENT_KIND)
        self.assertEqual(first["pull_request"], 42)
        self.assertEqual(first["files"], ["README"])
        self.assertIn("#42", first["summary"])
        self.assertIn("README", first["summary"])
        self.assertNotIn("exit_code", first)

    def test_conflict_resolution_leaves_other_open_incidents_alone(self):
        with tempfile.TemporaryDirectory() as tmp:
            incident_dir = Path(tmp)
            crash = incident_dir / "incident-20260101T000000Z-1.json"
            crash.write_text(
                json.dumps(
                    {
                        "incident_id": crash.stem,
                        "kind": drain_prs_service.CRASH_INCIDENT_KIND,
                        "status": "open",
                        "repo": "/tmp/a",
                        "exit_code": 1,
                    }
                ),
                encoding="utf-8",
            )
            legacy = incident_dir / "incident-20250101T000000Z-1.json"
            legacy.write_text(
                json.dumps(
                    {"incident_id": legacy.stem, "status": "open", "repo": "/tmp/a"}
                ),
                encoding="utf-8",
            )
            with (
                mock.patch.object(drain_prs_service, "INCIDENT_DIR", incident_dir),
                mock.patch.object(drain_prs_service, "NTFY_URL", None),
            ):
                drain_prs_service.record_conflict_incident(
                    repo_path=Path("/tmp/a"), pull_request=42, files=["README"]
                )
                kept = drain_prs_service.record_conflict_incident(
                    repo_path=Path("/tmp/a"), pull_request=43, files=["README"]
                )
                foreign = drain_prs_service.record_conflict_incident(
                    repo_path=Path("/tmp/b"), pull_request=42, files=["README"]
                )
                resolved = drain_prs_service.resolve_conflict_incident(
                    Path("/tmp/a"), 42, "PR #42 merges cleanly again."
                )
                missing = drain_prs_service.resolve_conflict_incident(
                    Path("/tmp/a"), 42, "already resolved"
                )
                open_ids = {
                    json.loads(path.read_text(encoding="utf-8"))["incident_id"]
                    for path in incident_dir.glob("*.json")
                    if json.loads(path.read_text(encoding="utf-8"))["status"] == "open"
                }

        self.assertEqual(resolved["pull_request"], 42)
        self.assertEqual(resolved["resolution"], "PR #42 merges cleanly again.")
        self.assertIn("resolved_at", resolved)
        self.assertIsNone(missing)
        # The other PR's conflict, the other repository's, the crash, and a
        # pre-kind legacy incident all survive.
        self.assertEqual(
            open_ids,
            {kept["incident_id"], foreign["incident_id"], crash.stem, legacy.stem},
        )

    def test_a_running_service_surfaces_the_newest_conflict_incident(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            incident_dir = root / "incidents"
            incident_dir.mkdir()
            status_path = root / "status.json"
            repo = Path("/tmp/a").resolve()
            alive = os.getpid()
            status_path.write_text(
                json.dumps(
                    {
                        "state": "running",
                        "runner_pid": alive,
                        "drainer_pid": alive,
                        "repo": str(repo),
                    }
                ),
                encoding="utf-8",
            )
            with (
                mock.patch.object(drain_prs_service, "INCIDENT_DIR", incident_dir),
                mock.patch.object(drain_prs_service, "STATUS_PATH", status_path),
                mock.patch.object(drain_prs_service, "NTFY_URL", None),
                mock.patch.object(drain_prs_service, "launchd_loaded", return_value=True),
                mock.patch.object(drain_prs_service, "latest_log_path", return_value=None),
                mock.patch.object(drain_prs_service, "lock_pid", return_value=None),
            ):
                drain_prs_service.record_conflict_incident(
                    repo_path=repo, pull_request=42, files=["README"]
                )
                snapshot = drain_prs_service.status_snapshot(repo)

        # Kanban renders `running` + an open incident as a DrainerWarning
        # carrying this summary, so the conflict reaches the board.
        self.assertEqual(snapshot["state"], "running")
        self.assertEqual(snapshot["open_incident"]["pull_request"], 42)
        self.assertIn("#42", snapshot["open_incident"]["summary"])

    def _stopped_snapshot(self, repo, operation):
        with (
            mock.patch.object(drain_prs_service, "read_json", return_value={}),
            mock.patch.object(drain_prs_service, "pid_alive", return_value=False),
            mock.patch.object(drain_prs_service, "lock_pid", return_value=None),
            mock.patch.object(drain_prs_service, "incident_files", return_value=[]),
            mock.patch.object(drain_prs_service, "latest_log_path", return_value=None),
            mock.patch.object(drain_prs_service, "launchd_loaded", return_value=False),
            mock.patch.object(
                drain_prs_service, "in_progress_operation", return_value=operation
            ),
        ):
            return drain_prs_service.status_snapshot(repo)

    def test_status_leaves_a_stopped_dirty_checkout_simply_stopped(self):
        # Inverted from the removed blanket gate: uncommitted work is carried
        # across the post-merge fast-forward by the drainer's own autostash,
        # so a dirty tree reports no repository condition at all.
        result = self._stopped_snapshot(Path("/tmp/a"), None)
        self.assertEqual(result["state"], "stopped")
        self.assertIsNone(result["operation"])

    def test_status_names_each_unfinished_operation_that_blocks_a_start(self):
        for operation in ("merge", "rebase", "cherry-pick", "bisect"):
            with self.subTest(operation=operation):
                result = self._stopped_snapshot(Path("/tmp/a"), operation)
                self.assertEqual(result["state"], "mid_operation")
                self.assertEqual(result["operation"], operation)

    def test_start_no_longer_inspects_the_working_tree_for_uncommitted_work(self):
        # Inverted from the removed blanket gate: with no operation in
        # progress there is nothing left in the tree that can refuse a start,
        # so the run reaches installation however dirty the checkout is.
        repo = Path("/tmp/a")
        with (
            mock.patch.object(
                drain_prs_service, "in_progress_operation", return_value=None
            ),
            mock.patch.object(drain_prs_service, "require_default_branch"),
            mock.patch.object(drain_prs_service, "ensure_dirs"),
            mock.patch.object(
                drain_prs_service,
                "status_snapshot",
                return_value={"state": "stopped", "drainer_pid": None, "active_repo": None},
            ),
            mock.patch.object(
                drain_prs_service,
                "install_job",
                side_effect=drain_prs_service.ServiceError("reached installation"),
            ),
        ):
            with self.assertRaisesRegex(
                drain_prs_service.ServiceError, "reached installation"
            ):
                drain_prs_service.start_service(repo)

    def test_start_refuses_an_unfinished_operation_before_installing_or_launching(self):
        repo = Path("/tmp/a")
        for operation in ("merge", "rebase", "cherry-pick", "bisect"):
            with self.subTest(operation=operation):
                with (
                    mock.patch.object(
                        drain_prs_service, "in_progress_operation", return_value=operation
                    ),
                    mock.patch.object(drain_prs_service, "install_job") as install_job,
                ):
                    with self.assertRaisesRegex(
                        drain_prs_service.ServiceError, f"a {operation} is in progress"
                    ):
                        drain_prs_service.start_service(repo)
                install_job.assert_not_called()

    def test_start_names_the_operation_ahead_of_a_detached_head(self):
        # A rebase or a bisect commonly leaves a detached HEAD, so checking
        # the branch first would report that symptom instead of the operation
        # the user actually has to finish.
        repo = Path("/tmp/a")
        with (
            mock.patch.object(
                drain_prs_service, "in_progress_operation", return_value="rebase"
            ),
            mock.patch.object(
                drain_prs_service,
                "require_default_branch",
                side_effect=drain_prs_service.ServiceError("repository is on branch ''"),
            ),
        ):
            with self.assertRaisesRegex(
                drain_prs_service.ServiceError, "a rebase is in progress"
            ):
                drain_prs_service.start_service(repo)

    def test_start_refuses_a_non_default_branch_before_installing_or_launching(self):
        repo = Path("/tmp/a")
        with (
            mock.patch.object(
                drain_prs_service, "in_progress_operation", return_value=None
            ),
            mock.patch.object(
                drain_prs_service,
                "require_default_branch",
                side_effect=drain_prs_service.ServiceError("repository is on branch 'feature'"),
            ),
            mock.patch.object(drain_prs_service, "install_job") as install_job,
        ):
            with self.assertRaisesRegex(
                drain_prs_service.ServiceError, "repository is on branch 'feature'"
            ):
                drain_prs_service.start_service(repo)
        install_job.assert_not_called()

    def test_runner_exits_without_an_incident_when_not_on_the_default_branch(self):
        repo = Path("/tmp/a")
        with (
            mock.patch.object(
                drain_prs_service,
                "require_default_branch",
                side_effect=drain_prs_service.ServiceError("repository is on branch 'feature'"),
            ),
            mock.patch.object(drain_prs_service, "service_log") as service_log,
            mock.patch.object(drain_prs_service, "write_incident") as write_incident,
        ):
            result = drain_prs_service.run_service(repo)
        self.assertEqual(result, 0)
        service_log.assert_called_once()
        write_incident.assert_not_called()

    def test_default_branch_preflight_honors_a_configured_non_origin_remote(self):
        with tempfile.TemporaryDirectory() as remote_dir, tempfile.TemporaryDirectory() as repo_dir:
            remote = Path(remote_dir)
            repo = Path(repo_dir)
            subprocess.run(["git", "init", "-q", "--bare", str(remote)], check=True)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "config", "user.email", "test@example.test"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "config", "user.name", "Test"], check=True
            )
            (repo / "README.md").write_text("hello\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "README.md"], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "commit", "-q", "-m", "initial"], check=True
            )
            subprocess.run(
                ["git", "-C", str(repo), "branch", "-M", "main"], check=True
            )
            subprocess.run(
                ["git", "-C", str(repo), "remote", "add", "upstream", str(remote)],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "push", "-q", "upstream", "main"], check=True
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(repo),
                    "remote",
                    "set-head",
                    "upstream",
                    "main",
                ],
                check=True,
            )
            with mock.patch.object(
                drain_prs_service, "CONFIGURED_REMOTE_NAME", "upstream"
            ):
                drain_prs_service.require_default_branch(repo)
                with self.assertRaisesRegex(
                    drain_prs_service.ServiceError, "origin/HEAD"
                ):
                    drain_prs_service.require_default_branch(repo, remote_name="origin")


class DiscoveryRecordTests(unittest.TestCase):
    """The record `src/Kanban/Drainer.hs` resolves the LaunchAgent through."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.plist = self.root / "LaunchAgents" / "job.plist"
        self.plist.parent.mkdir(parents=True)
        self.record = self.root / "install" / "config.json"

    def install(self, repo=Path("/tmp/example-project")):
        """Runs install_job against temporary paths, with launchd faked out.

        Nothing here may touch the real ~/Library/LaunchAgents or
        ~/Library/Application Support/kanban, so every path the function
        writes to is redirected and every launchctl call is captured.
        """
        with (
            mock.patch.object(drain_prs_service, "PLIST_PATH", self.plist),
            mock.patch.object(
                drain_prs_service, "DISCOVERY_RECORD_PATH", self.record
            ),
            mock.patch.object(drain_prs_service, "ensure_dirs"),
            mock.patch.object(
                drain_prs_service,
                "status_snapshot",
                return_value={"state": "stopped"},
            ),
            mock.patch.object(drain_prs_service, "launchd_loaded", return_value=False),
            mock.patch.object(drain_prs_service, "run_command") as run_command,
        ):
            result = drain_prs_service.install_job(repo)
        return result, run_command

    def read_record(self):
        return json.loads(self.record.read_text(encoding="utf-8"))

    def test_installing_records_the_label_plist_and_repository(self):
        result, _ = self.install()
        record = self.read_record()
        self.assertEqual(record["launchd_label"], drain_prs_service.LABEL)
        self.assertEqual(record["plist_path"], str(self.plist))
        self.assertEqual(record["repository"], "/tmp/example-project")
        self.assertEqual(result["record"], str(self.record))

    def test_the_record_is_written_from_the_same_values_launchd_is_given(self):
        # The point of the record is that one edit to LABEL moves the plist,
        # the launchctl target, and Kanban's discovery together; a record
        # restating the label independently would defeat that.
        with mock.patch.object(drain_prs_service, "LABEL", "com.example.renamed"):
            _, run_command = self.install()
        record = self.read_record()
        self.assertEqual(record["launchd_label"], "com.example.renamed")
        bootstrapped = [call.args[0] for call in run_command.call_args_list]
        self.assertIn(
            ["launchctl", "bootstrap", drain_prs_service.launch_domain(), str(self.plist)],
            bootstrapped,
        )

    def test_reinstalling_repairs_the_record_in_place(self):
        # An installation predating the record is repaired by re-running the
        # installer, which reaches install_job the same way a first install
        # does — without an uninstall, and without changing the label.
        self.install()
        first = self.read_record()
        self.record.unlink()
        self.install()
        self.assertEqual(self.read_record(), first)

    def test_recording_preserves_the_installer_persisted_keys(self):
        self.record.parent.mkdir(parents=True)
        self.record.write_text(
            json.dumps(
                {
                    "ntfy_url": "https://notify.example.test/topic",
                    "config_path": "/home/user/.config/kanban/config.toml",
                }
            ),
            encoding="utf-8",
        )
        self.install()
        record = self.read_record()
        self.assertEqual(record["ntfy_url"], "https://notify.example.test/topic")
        self.assertEqual(
            record["config_path"], "/home/user/.config/kanban/config.toml"
        )
        self.assertEqual(record["plist_path"], str(self.plist))

    def test_the_record_is_private_and_never_a_symlink_target(self):
        self.install()
        self.assertFalse(self.record.is_symlink())
        self.assertEqual(self.record.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.record.parent.stat().st_mode & 0o777, 0o700)

        outside = self.root / "outside.json"
        outside.write_text("keep\n", encoding="utf-8")
        self.record.unlink()
        self.record.symlink_to(outside)
        with self.assertRaises(drain_prs_service.ServiceError):
            self.install()
        self.assertEqual(outside.read_text(encoding="utf-8"), "keep\n")


if __name__ == "__main__":
    unittest.main()
