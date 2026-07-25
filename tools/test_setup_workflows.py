"""Hermetic fresh-machine tests for the opt-in workflow setup command.

Every case runs against a temporary home, a temporary git checkout, and a
PATH holding only the executables that case installs — scriptable fake
`codex`/`claude` shims from `fake_cli.py`, plus `git` because
`install_issue_review.repository_root` resolves the checkout with it. No
credentials, network access, model call, launchd interaction, or real
provider installation is involved, so these run under the same
`python3 -m unittest discover -s tools -p 'test_*.py'` CI already runs.
"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import fake_cli
import setup_workflows


REPO_ROOT = Path(__file__).resolve().parent.parent

INSTALLED_AND_ENABLED = json.dumps(
    [{"id": "kanban@kanban", "installed": True, "enabled": True, "scope": "user"}]
)
INSTALLED_BUT_DISABLED = json.dumps(
    [{"id": "kanban@kanban", "installed": True, "enabled": False, "scope": "user"}]
)

# Tokens that would mean setup had started a session, weakened a provider
# safety control, or overridden the user's own model/approval defaults.
FORBIDDEN_ARGUMENTS = {
    "exec",
    "-p",
    "--print",
    "--model",
    "-m",
    "--sandbox",
    "--approval",
    "--approval-policy",
    "--dangerously-skip-permissions",
    "--allow-dangerously-skip-permissions",
    "-c",
    "--config",
}


class HermeticSetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.repo = self.root / "checkout"
        self.install_dir = (
            self.home / "Library" / "Application Support" / "kanban" / "issue-review"
        )
        self.legacy_path = self.home / "work" / "approve-issues.py"
        self.fake = fake_cli.FakeCli(self.root / "fake")
        self._make_checkout()
        # The hermetic PATH holds only git (which
        # install_issue_review.repository_root resolves the checkout with)
        # and python3 (which the fake shims are written in) until a case
        # installs a provider shim, so "executable absent" is a real
        # absence rather than a mocked one.
        for required in ("git", "python3"):
            (self.fake.bin_dir / required).symlink_to(shutil.which(required))

    def _make_checkout(self):
        (self.repo / "tools").mkdir(parents=True)
        for name in ("approve_issues.py", "kanban_config.py"):
            shutil.copy(REPO_ROOT / "tools" / name, self.repo / "tools" / name)
        (self.repo / "codex-plugin").mkdir()
        (self.repo / "claude-plugin").mkdir()
        subprocess.run(
            ["git", "init", "-q", str(self.repo)],
            check=True,
            capture_output=True,
            text=True,
        )

    def install_provider(self, binary, *, marketplaces="[]", plugins=("[]",)):
        self.fake.install(binary)
        self.fake.script(
            binary, ["plugin", "marketplace", "list", "--json"], stdout=marketplaces
        )
        for listing in plugins:
            self.fake.script(binary, ["plugin", "list", "--json"], stdout=listing)
        self.fake.script(binary, ["plugin", "marketplace", "add"], stdout="added\n")
        self.fake.script(binary, ["plugin", "add"], stdout="installed\n")
        self.fake.script(binary, ["plugin", "install"], stdout="installed\n")

    def run_setup(self, *argv):
        environment = {
            "PATH": str(self.fake.bin_dir),
            "FAKE_CLI_STATE_DIR": str(self.fake.state_dir),
            "HOME": str(self.home),
        }
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, environment):
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = setup_workflows.main(
                    [
                        *argv,
                        "--repo",
                        str(self.repo),
                        "--install-dir",
                        str(self.install_dir),
                        "--legacy-path",
                        str(self.legacy_path),
                        "--json",
                    ]
                )
        payload = json.loads(out.getvalue() or err.getvalue())
        return code, payload

    def component(self, payload, name):
        for entry in payload["components"]:
            if entry["component"] == name:
                return entry
        raise AssertionError(f"{name} missing from {payload}")

    def mutating_calls(self, binary):
        return [
            call
            for call in self.fake.calls(binary)
            if call["args"][:2] not in (["plugin", "list"],)
            and call["args"][:3] != ["plugin", "marketplace", "list"]
        ]


class CleanMachineTests(HermeticSetupTests):
    def test_plan_reports_every_component_and_writes_nothing(self):
        self.install_provider("codex")
        self.install_provider("claude")

        code, payload = self.run_setup("--all", "--scope", "user")

        self.assertEqual(code, 0, payload)
        self.assertTrue(payload["dry_run"])
        for name in setup_workflows.COMPONENTS:
            self.assertEqual(self.component(payload, name)["status"], "install", name)
        self.assertFalse(self.install_dir.exists())
        self.assertFalse(self.legacy_path.exists())
        self.assertEqual(self.mutating_calls("codex"), [])
        self.assertEqual(self.mutating_calls("claude"), [])

    def test_plan_names_the_exact_provider_commands_it_would_run(self):
        self.install_provider("codex")
        self.install_provider("claude")

        _, payload = self.run_setup("--all", "--scope", "user")

        codex = [command[1:] for command in self.component(payload, "codex-plugin")["commands"]]
        claude = [command[1:] for command in self.component(payload, "claude-plugin")["commands"]]
        resolved = self.repo.resolve()
        self.assertEqual(
            codex,
            [
                ["plugin", "marketplace", "add", str(resolved / "codex-plugin")],
                ["plugin", "add", "kanban@kanban"],
            ],
        )
        self.assertEqual(
            claude,
            [
                [
                    "plugin",
                    "marketplace",
                    "add",
                    str(resolved / "claude-plugin"),
                    "--scope",
                    "user",
                ],
                ["plugin", "install", "kanban@kanban", "--scope", "user"],
            ],
        )

    def test_apply_installs_every_component(self):
        self.install_provider("codex")
        self.install_provider("claude")

        code, payload = self.run_setup("--all", "--scope", "user", "--apply")

        self.assertEqual(code, 0, payload)
        self.assertEqual(
            (self.install_dir / "approve_issues.py").resolve(),
            (self.repo / "tools" / "approve_issues.py").resolve(),
        )
        self.assertEqual(
            (self.install_dir / "kanban_config.py").resolve(),
            (self.repo / "tools" / "kanban_config.py").resolve(),
        )
        self.assertEqual(
            self.legacy_path.resolve(), (self.install_dir / "approve_issues.py").resolve()
        )
        self.assertEqual(
            [call["args"][:3] for call in self.mutating_calls("codex")],
            [["plugin", "marketplace", "add"], ["plugin", "add", "kanban@kanban"]],
        )
        self.assertEqual(
            [call["args"][:3] for call in self.mutating_calls("claude")],
            [["plugin", "marketplace", "add"], ["plugin", "install", "kanban@kanban"]],
        )

    def test_setup_never_starts_a_daemon_agent_session_or_changes_provider_defaults(self):
        self.install_provider("codex")
        self.install_provider("claude")

        self.run_setup("--all", "--scope", "user", "--apply")

        for binary in ("codex", "claude"):
            for call in self.fake.calls(binary):
                self.assertEqual(call["args"][0], "plugin", call)
                self.assertEqual(call["stdin"], "", call)
                for argument in call["args"]:
                    self.assertNotIn(argument, FORBIDDEN_ARGUMENTS, call)
        # launchctl and the drainer installer are not even on the hermetic
        # PATH, so the LaunchAgent surface cannot have been touched.
        self.assertIsNone(shutil.which("launchctl", path=str(self.fake.bin_dir)))


class AlreadyConfiguredTests(HermeticSetupTests):
    def _configured_marketplace(self, directory):
        return json.dumps([{"name": "kanban", "path": str(self.repo / directory)}])

    def test_rerun_reports_unchanged_and_runs_no_command(self):
        self.install_provider(
            "codex",
            marketplaces=self._configured_marketplace("codex-plugin"),
            plugins=(INSTALLED_AND_ENABLED,),
        )
        self.install_provider(
            "claude",
            marketplaces=self._configured_marketplace("claude-plugin"),
            plugins=(INSTALLED_AND_ENABLED,),
        )
        first, _ = self.run_setup("--all", "--scope", "user", "--apply")
        self.assertEqual(first, 0)

        code, payload = self.run_setup("--all", "--scope", "user", "--apply")

        self.assertEqual(code, 0, payload)
        for name in setup_workflows.COMPONENTS:
            self.assertEqual(self.component(payload, name)["status"], "unchanged", name)
        self.assertEqual(self.mutating_calls("codex"), [])
        self.assertEqual(self.mutating_calls("claude"), [])

    def test_a_disabled_bundle_is_reported_rather_than_reinstalled_over(self):
        self.install_provider(
            "codex",
            marketplaces=self._configured_marketplace("codex-plugin"),
            plugins=(INSTALLED_BUT_DISABLED,),
        )

        code, payload = self.run_setup(
            "--component", "codex-plugin", "--scope", "user", "--apply"
        )

        entry = self.component(payload, "codex-plugin")
        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "refused")
        self.assertIn("disabled", entry["message"])
        self.assertEqual(self.mutating_calls("codex"), [])


class MissingPrerequisiteTests(HermeticSetupTests):
    def test_absent_provider_executables_are_reported_not_installed(self):
        code, payload = self.run_setup(
            "--component", "codex-plugin", "--component", "claude-plugin", "--scope", "user"
        )

        self.assertEqual(code, 1)
        for name, executable in (("codex-plugin", "codex"), ("claude-plugin", "claude")):
            entry = self.component(payload, name)
            self.assertEqual(entry["status"], "unavailable")
            self.assertIn(f"{executable} was not found on PATH", entry["message"])

    def test_an_unreadable_plugin_listing_never_reads_as_nothing_installed(self):
        self.fake.install("codex")
        self.fake.script(
            "codex", ["plugin", "marketplace", "list", "--json"], stdout="not json\n"
        )

        code, payload = self.run_setup("--component", "codex-plugin", "--scope", "user")

        entry = self.component(payload, "codex-plugin")
        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "unavailable")
        self.assertIn("Could not decode", entry["message"])

    def test_project_scope_refuses_the_user_global_codex_registration(self):
        self.install_provider("codex")

        code, payload = self.run_setup("--component", "codex-plugin")

        entry = self.component(payload, "codex-plugin")
        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "refused")
        self.assertIn("--scope user", entry["message"])
        self.assertEqual(self.fake.calls("codex"), [])

    def test_a_component_must_be_selected_explicitly(self):
        code, payload = self.run_setup()

        self.assertEqual(code, 1)
        self.assertIn("Select at least one component", payload["error"])


class ConflictTests(HermeticSetupTests):
    def test_a_marketplace_from_another_checkout_is_preserved_with_a_recovery_instruction(self):
        other = self.root / "other-checkout" / "claude-plugin"
        self.install_provider(
            "claude", marketplaces=json.dumps([{"name": "kanban", "path": str(other)}])
        )

        code, payload = self.run_setup(
            "--component", "claude-plugin", "--scope", "user", "--apply"
        )

        entry = self.component(payload, "claude-plugin")
        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "refused")
        self.assertIn(str(other), entry["message"])
        self.assertIn("claude plugin marketplace remove kanban", entry["message"])
        self.assertEqual(self.mutating_calls("claude"), [])

    def test_the_launcher_is_refused_without_the_backend_it_points_at(self):
        code, payload = self.run_setup("--component", "legacy-launcher", "--apply")

        entry = self.component(payload, "legacy-launcher")
        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "unavailable")
        self.assertIn("--component issue-review", entry["message"])
        self.assertFalse(os.path.lexists(self.legacy_path))

    def test_migration_never_moves_a_user_file_aside_for_a_dangling_launcher(self):
        # The damaging shape: --migrate-legacy-launcher would back the
        # user's own launcher up and replace it with a link to a backend
        # that was never installed.
        self.legacy_path.parent.mkdir(parents=True)
        self.legacy_path.write_text("pre-kanban launcher\n", encoding="utf-8")

        code, payload = self.run_setup(
            "--component", "legacy-launcher", "--migrate-legacy-launcher", "--apply"
        )

        self.assertEqual(code, 1)
        self.assertEqual(self.component(payload, "legacy-launcher")["status"], "unavailable")
        self.assertFalse(self.legacy_path.is_symlink())
        self.assertEqual(
            self.legacy_path.read_text(encoding="utf-8"), "pre-kanban launcher\n"
        )
        self.assertFalse(
            os.path.lexists(
                self.legacy_path.with_name(self.legacy_path.name + ".pre-kanban-backup")
            )
        )

    def test_an_ordinary_backend_copy_does_not_count_as_an_installation(self):
        # Marker-bearing but hand-copied rather than linked: setup refuses to
        # manage that path and preflight calls it a conflicting
        # installation, so the launcher must not be pointed at it either.
        self.install_dir.mkdir(parents=True)
        for name in ("approve_issues.py", "kanban_config.py"):
            (self.install_dir / name).write_text(
                f"# kanban-managed-asset:issue-review/{name}\n", encoding="utf-8"
            )
        self.legacy_path.parent.mkdir(parents=True)
        self.legacy_path.write_text("pre-kanban launcher\n", encoding="utf-8")

        self.assertFalse(setup_workflows.backend_is_installed(self.install_dir))
        code, payload = self.run_setup(
            "--component", "legacy-launcher", "--migrate-legacy-launcher", "--apply"
        )

        self.assertEqual(code, 1)
        self.assertEqual(self.component(payload, "legacy-launcher")["status"], "unavailable")
        self.assertFalse(self.legacy_path.is_symlink())
        self.assertEqual(
            self.legacy_path.read_text(encoding="utf-8"), "pre-kanban launcher\n"
        )

    def test_a_dangling_backend_link_does_not_count_as_an_installation(self):
        self.install_dir.mkdir(parents=True)
        for name in ("approve_issues.py", "kanban_config.py"):
            (self.install_dir / name).symlink_to(self.root / "gone" / name)

        self.assertFalse(setup_workflows.backend_is_installed(self.install_dir))

    def test_the_launcher_is_installed_after_the_backend_in_the_same_run(self):
        # Requested in the damaging order; setup must still install the
        # backend first, and the resulting launcher must resolve.
        code, payload = self.run_setup(
            "--component", "legacy-launcher", "--component", "issue-review", "--apply"
        )

        self.assertEqual(code, 0, payload)
        self.assertEqual(
            [entry["component"] for entry in payload["components"]],
            ["issue-review", "legacy-launcher"],
        )
        self.assertTrue(self.legacy_path.is_symlink())
        self.assertTrue(self.legacy_path.is_file(), "the launcher must actually resolve")

    def test_an_ordinary_legacy_launcher_is_preserved_until_migration_is_opted_into(self):
        self.legacy_path.parent.mkdir(parents=True)
        self.legacy_path.write_text("pre-kanban launcher\n", encoding="utf-8")

        code, payload = self.run_setup(
            "--component", "issue-review", "--component", "legacy-launcher", "--apply"
        )

        entry = self.component(payload, "legacy-launcher")
        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "refused")
        self.assertIn("--migrate-legacy-launcher", entry["message"])
        self.assertFalse(self.legacy_path.is_symlink())
        self.assertEqual(
            self.legacy_path.read_text(encoding="utf-8"), "pre-kanban launcher\n"
        )

    def test_opting_into_migration_backs_the_legacy_launcher_up_before_replacing_it(self):
        self.legacy_path.parent.mkdir(parents=True)
        self.legacy_path.write_text("pre-kanban launcher\n", encoding="utf-8")

        code, payload = self.run_setup(
            "--component",
            "issue-review",
            "--component",
            "legacy-launcher",
            "--migrate-legacy-launcher",
            "--apply",
        )

        backup = self.legacy_path.with_name(self.legacy_path.name + ".pre-kanban-backup")
        self.assertEqual(code, 0, payload)
        self.assertEqual(backup.read_text(encoding="utf-8"), "pre-kanban launcher\n")
        self.assertEqual(
            self.legacy_path.resolve(), (self.install_dir / "approve_issues.py").resolve()
        )

    def test_a_symlink_kanban_did_not_install_is_refused_and_preserved(self):
        # Same name, same tools/ parent shape: only the tracked backend's
        # own identity marker, absent here, tells the two apart.
        unrelated = self.root / "someone-elses-project" / "tools" / "approve_issues.py"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        self.install_dir.mkdir(parents=True)
        occupied = self.install_dir / "approve_issues.py"
        occupied.symlink_to(unrelated)

        code, payload = self.run_setup("--component", "issue-review", "--apply")

        entry = self.component(payload, "issue-review")
        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "refused")
        self.assertIn(str(unrelated), entry["message"])
        self.assertEqual(Path(os.readlink(occupied)), unrelated)

    def test_a_legacy_launcher_symlink_to_something_else_is_refused_and_preserved(self):
        unrelated = self.root / "my-own-install" / "approve_issues.py"
        unrelated.parent.mkdir(parents=True)
        unrelated.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        self.legacy_path.parent.mkdir(parents=True)
        self.legacy_path.symlink_to(unrelated)

        code, payload = self.run_setup(
            "--component",
            "issue-review",
            "--component",
            "legacy-launcher",
            "--migrate-legacy-launcher",
            "--apply",
        )

        entry = self.component(payload, "legacy-launcher")
        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "refused")
        self.assertIn(str(unrelated), entry["message"])
        self.assertEqual(Path(os.readlink(self.legacy_path)), unrelated)

    def test_an_ordinary_file_on_the_install_path_is_refused_and_preserved(self):
        self.install_dir.mkdir(parents=True)
        occupied = self.install_dir / "approve_issues.py"
        occupied.write_text("someone else's file\n", encoding="utf-8")

        code, payload = self.run_setup("--component", "issue-review", "--apply")

        entry = self.component(payload, "issue-review")
        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "refused")
        self.assertIn(str(occupied), entry["message"])
        self.assertEqual(occupied.read_text(encoding="utf-8"), "someone else's file\n")


class DryRunPurityTests(unittest.TestCase):
    """A dry run must write nothing at all, which includes artefacts the
    interpreter itself would leave behind. Driven as a subprocess, because
    an in-process call cannot observe an import that already happened when
    this test module was loaded."""

    def snapshot(self, root: Path) -> list[str]:
        # `.git` is excluded: git's own bookkeeping is not this tool's
        # doing, and reading the checkout may touch it.
        return sorted(
            path.relative_to(root).as_posix()
            for path in root.rglob("*")
            if ".git" not in path.relative_to(root).parts
        )

    def test_a_dry_run_subprocess_leaves_the_checkout_byte_for_byte_alone(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            checkout = root / "checkout"
            (checkout / "tools").mkdir(parents=True)
            for source in (REPO_ROOT / "tools").glob("*.py"):
                shutil.copy(source, checkout / "tools" / source.name)
            subprocess.run(
                ["git", "init", "-q", str(checkout)], check=True, capture_output=True
            )
            install_dir = root / "install"
            legacy_path = root / "legacy" / "approve-issues.py"

            before = self.snapshot(checkout)
            proc = subprocess.run(
                [
                    sys.executable,
                    str(checkout / "tools" / "setup_workflows.py"),
                    "--component",
                    "issue-review",
                    "--repo",
                    str(checkout),
                    "--install-dir",
                    str(install_dir),
                    "--legacy-path",
                    str(legacy_path),
                    "--json",
                ],
                capture_output=True,
                text=True,
                cwd=str(root),
            )

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertTrue(json.loads(proc.stdout)["dry_run"])
            self.assertEqual(self.snapshot(checkout), before)
            self.assertNotIn(
                "tools/__pycache__", " ".join(self.snapshot(checkout))
            )
            self.assertFalse(install_dir.exists())
            self.assertFalse(legacy_path.parent.exists())


class ListingParsingTests(unittest.TestCase):
    """The listing readers are shared with Kanban.Preflight's own parsing,
    so both providers' envelopes are pinned here directly."""

    def test_reads_the_codex_envelope(self):
        payload = {
            "installed": [
                {"pluginId": "other@market", "installed": True, "enabled": True},
                {"pluginId": "kanban@kanban", "installed": True, "enabled": True},
            ]
        }
        entries = setup_workflows.plugin_entries(payload)
        self.assertEqual(len(entries), 1)
        self.assertTrue(setup_workflows.entry_enabled(entries[0]))

    def test_reads_the_claude_envelope(self):
        payload = [{"id": "kanban@kanban", "enabled": False, "scope": "project"}]
        entries = setup_workflows.plugin_entries(payload)
        self.assertTrue(setup_workflows.entry_installed(entries[0]))
        self.assertFalse(setup_workflows.entry_enabled(entries[0]))

    def test_an_uninstalled_marketplace_offering_is_not_an_install(self):
        payload = {"installed": [{"pluginId": "kanban@kanban", "installed": False}]}
        entries = setup_workflows.plugin_entries(payload)
        self.assertFalse(setup_workflows.entry_installed(entries[0]))

    def test_marketplace_source_kinds_are_not_mistaken_for_locations(self):
        entry = {"name": "kanban", "source": "directory", "path": "/tmp/kanban/claude-plugin"}
        self.assertEqual(
            setup_workflows.marketplace_sources(entry), ["/tmp/kanban/claude-plugin"]
        )


if __name__ == "__main__":
    unittest.main()
