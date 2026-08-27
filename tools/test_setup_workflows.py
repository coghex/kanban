"""Hermetic fresh-machine tests for the opt-in workflow setup command.

Every case runs against a temporary home, a temporary git checkout, and a
PATH holding only the executables that case installs — scriptable fake
`codex`/`claude` shims from `fake_cli.py`, plus `git` because a checkout's
own bundle inventory and ignore rules are read with it and an explicit
project `--target` is validated with it. No credentials, network access,
model call, launchd interaction, or real provider installation is involved,
so these run under the same
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
import install_issue_review
import kanban_config
import setup_workflows


REPO_ROOT = Path(__file__).resolve().parent.parent

# The version the fixture bundle declares for itself, and therefore the cache
# directory the provider would install it into.
BUNDLE_VERSION = "1.0.0"

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
        # macOS, simulated rather than read: since issue #357 the managed
        # install and record locations differ per platform, and this fixture's
        # expectations are the macOS ones -- unchanged, and asserted on the
        # Linux CI runner too. `platform_is` also redirects both XDG base
        # directories in run_setup below, so an ambient one cannot decide the
        # answer either. IssueReviewDiscoveryRecordTests covers the XDG host.
        self.platform_is("darwin")
        self.install_dir = (
            self.home / "Library" / "Application Support" / "kanban" / "issue-review"
        )
        self.legacy_path = self.home / "work" / "approve-issues.py"
        # The documented default location, so most cases exercise the
        # `~/.codex` fallback rather than the override.
        self.codex_home = self.home / ".codex"
        self.fake = fake_cli.FakeCli(self.root / "fake")
        self._make_checkout()
        # The hermetic PATH holds only git (which reads a *checkout's* tracked
        # bundle inventory and ignore rules, and validates an explicit project
        # `--target`; an archive asset root is never asked anything with it)
        # and python3 (which the fake shims are written in) until a case
        # installs a provider shim, so "executable absent" is a real
        # absence rather than a mocked one.
        for required in ("git", "python3"):
            (self.fake.bin_dir / required).symlink_to(shutil.which(required))

    def platform_is(self, platform):
        """Which convention kanban_config resolves the managed locations by,
        for the rest of this case."""
        patcher = mock.patch.object(kanban_config.sys, "platform", platform)
        patcher.start()
        self.addCleanup(patcher.stop)

    def _make_checkout(self):
        (self.repo / "tools").mkdir(parents=True)
        for name in install_issue_review.BACKEND_MODULES.values():
            shutil.copy(REPO_ROOT / "tools" / name, self.repo / "tools" / name)
        # Both marketplace manifests, because setup validates an asset root by
        # the tracked files each selected component is installed *from* — a
        # bundle directory holding no manifest publishes nothing.
        self.claude_bundle = self.repo / "claude-plugin" / "plugins" / "kanban"
        (self.claude_bundle / ".claude-plugin").mkdir(parents=True)
        (self.claude_bundle / ".claude-plugin" / "plugin.json").write_text(
            json.dumps({"name": "kanban", "version": BUNDLE_VERSION}) + "\n",
            encoding="utf-8",
        )
        (self.repo / "claude-plugin" / ".claude-plugin").mkdir(parents=True)
        (self.repo / "claude-plugin" / ".claude-plugin" / "marketplace.json").write_text(
            json.dumps({"name": "kanban", "plugins": [{"name": "kanban"}]}) + "\n",
            encoding="utf-8",
        )
        # A miniature but structurally real tracked Codex bundle: a manifest
        # declaring the version its cache directory is named for, skills at
        # the tracked depth, and a vendored script — the shapes the installed
        # bundle is compared against.
        self.bundle = self.repo / "codex-plugin" / "plugins" / "kanban"
        (self.bundle / ".codex-plugin").mkdir(parents=True)
        (self.bundle / ".codex-plugin" / "plugin.json").write_text(
            json.dumps({"name": "kanban", "version": BUNDLE_VERSION}) + "\n",
            encoding="utf-8",
        )
        (self.repo / "codex-plugin" / ".agents" / "plugins").mkdir(parents=True)
        (
            self.repo / "codex-plugin" / ".agents" / "plugins" / "marketplace.json"
        ).write_text(
            json.dumps({"name": "kanban", "plugins": [{"name": "kanban"}]}) + "\n",
            encoding="utf-8",
        )
        for skill in ("solve", "pr-review"):
            (self.bundle / "skills" / skill).mkdir(parents=True)
            (self.bundle / "skills" / skill / "SKILL.md").write_text(
                f"# {skill}\n", encoding="utf-8"
            )
        (self.bundle / "skills" / "pr-review" / "scripts").mkdir()
        (self.bundle / "skills" / "pr-review" / "scripts" / "review_pr.py").write_text(
            "print('review')\n", encoding="utf-8"
        )
        # The same rule the real checkout carries, and the reason an
        # interpreter artefact is not bundle content on either side.
        (self.repo / ".gitignore").write_text("__pycache__/\n", encoding="utf-8")
        subprocess.run(
            ["git", "init", "-q", str(self.repo)],
            check=True,
            capture_output=True,
            text=True,
        )
        # A GitHub remote, because a project-scoped registration may only be
        # declared in a checkout of a supported GitHub repository — and that
        # holds for the target this checkout supplies by default just as it
        # does for one named with --target. No network: `git remote add` only
        # writes the URL into .git/config.
        subprocess.run(
            [
                "git",
                "-C",
                str(self.repo),
                "remote",
                "add",
                "origin",
                "git@github.com:acme/widgets.git",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        # Added, not committed: `git ls-files` reads the index, and a commit
        # would need an identity this hermetic checkout deliberately has not
        # configured.
        subprocess.run(
            ["git", "-C", str(self.repo), "add", "-A"],
            check=True,
            capture_output=True,
            text=True,
        )

    def cache_dir(self, codex_home=None):
        """Where the provider caches this bundle, under a given Codex home."""
        return (
            Path(codex_home or self.codex_home)
            / "plugins"
            / "cache"
            / "kanban"
            / "kanban"
            / BUNDLE_VERSION
        )

    def install_codex_cache(self, codex_home=None):
        """Copy the tracked bundle into the provider cache exactly the way
        `codex plugin add` does, so the installed side is a real copy rather
        than a hand-listed inventory."""
        cache = self.cache_dir(codex_home)
        shutil.copytree(self.bundle, cache, dirs_exist_ok=True)
        return cache

    def refresh_side_effects(self, codex_home=None):
        """The filesystem consequences of a real `codex plugin remove` and
        `codex plugin add`: the cached bundle is dropped, then recopied from
        the marketplace."""
        cache = str(self.cache_dir(codex_home))
        return (
            [{"remove_tree": cache}],
            [{"copy_tree": [str(self.bundle), cache]}],
        )

    def install_provider(
        self, binary, *, marketplaces="[]", plugins=("[]",), remove_effects=(), add_effects=()
    ):
        self.fake.install(binary)
        self.fake.script(
            binary, ["plugin", "marketplace", "list", "--json"], stdout=marketplaces
        )
        for listing in plugins:
            self.fake.script(binary, ["plugin", "list", "--json"], stdout=listing)
        self.fake.script(binary, ["plugin", "marketplace", "add"], stdout="added\n")
        self.fake.script(
            binary,
            ["plugin", "remove"],
            stdout="removed\n",
            side_effects=list(remove_effects),
        )
        self.fake.script(
            binary, ["plugin", "add"], stdout="installed\n", side_effects=list(add_effects)
        )
        self.fake.script(binary, ["plugin", "install"], stdout="installed\n")

    def run_setup(self, *argv, codex_home=None, repo=None):
        environment = {
            "PATH": str(self.fake.bin_dir),
            "FAKE_CLI_STATE_DIR": str(self.fake.state_dir),
            "HOME": str(self.home),
            # Redirected rather than left to the host: kanban_config reads
            # these when it resolves the managed locations and the shared
            # configuration, so an ambient one would point these cases at a
            # real install or at the developer's own `remote_name`.
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_DATA_HOME": str(self.home / ".local" / "share"),
            "XDG_STATE_HOME": str(self.home / ".local" / "state"),
        }
        if codex_home is not None:
            environment["CODEX_HOME"] = str(codex_home)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, environment):
            if codex_home is None:
                # Not merely unset in the fixture: an ambient CODEX_HOME on
                # the developer's own machine would otherwise point these
                # cases at a real install.
                os.environ.pop("CODEX_HOME", None)
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = setup_workflows.main(
                    [
                        *argv,
                        "--repo",
                        str(self.repo if repo is None else repo),
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
        for name in install_issue_review.BACKEND_MODULES.values():
            with self.subTest(module=name):
                self.assertEqual(
                    (self.install_dir / name).resolve(),
                    (self.repo / "tools" / name).resolve(),
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
        self.install_codex_cache()
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


class CodexBundleStalenessTests(HermeticSetupTests):
    """`codex plugin list --json` answers "registered and enabled", never
    "still the bundle this checkout tracks". Codex installs the bundle by
    copying it into its own cache and offers no update command for a
    local-source marketplace, so a checkout that moves ahead leaves every
    Codex session running the bundle as it was when it was last added. These
    cases pin the state being detected, named, and repaired (issue #234)."""

    def configure_codex(self, *, plugins=(INSTALLED_AND_ENABLED,), refresh=True, codex_home=None):
        remove_effects, add_effects = self.refresh_side_effects(codex_home) if refresh else ((), ())
        self.install_provider(
            "codex",
            marketplaces=json.dumps([{"name": "kanban", "path": str(self.repo / "codex-plugin")}]),
            plugins=plugins,
            remove_effects=remove_effects,
            add_effects=add_effects,
        )

    def codex(self, *argv, **kwargs):
        code, payload = self.run_setup("--component", "codex-plugin", "--scope", "user", *argv, **kwargs)
        return code, self.component(payload, "codex-plugin")

    def command_tails(self):
        return [call["args"] for call in self.mutating_calls("codex")]

    # -- detection ------------------------------------------------------------

    def test_the_tracked_inventory_is_the_bundles_git_tracked_content(self):
        # Guards the whole comparison against passing vacuously: every case
        # below is only meaningful if this inventory is really populated.
        self.assertEqual(
            setup_workflows.tracked_bundle_files(self.repo.resolve()),
            [
                ".codex-plugin/plugin.json",
                "skills/pr-review/SKILL.md",
                "skills/pr-review/scripts/review_pr.py",
                "skills/solve/SKILL.md",
            ],
        )

    def test_a_missing_skill_is_reported_for_repair_rather_than_unchanged(self):
        cache = self.install_codex_cache()
        (cache / "skills" / "solve" / "SKILL.md").unlink()
        self.configure_codex()

        code, entry = self.codex()

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "repair")
        self.assertEqual(entry["divergence"]["missing"], ["skills/solve/SKILL.md"])
        self.assertEqual(entry["divergence"]["different"], [])
        self.assertEqual(entry["divergence"]["extra"], [])
        self.assertIn("skills/solve/SKILL.md", entry["message"])
        self.assertIn(str(cache), entry["message"])
        # A dry run inspects and reports; it never touches the provider.
        self.assertEqual(self.mutating_calls("codex"), [])

    def test_an_outdated_file_is_reported_as_different(self):
        cache = self.install_codex_cache()
        (cache / "skills" / "pr-review" / "scripts" / "review_pr.py").write_text(
            "print('three weeks ago')\n", encoding="utf-8"
        )
        self.configure_codex()

        code, entry = self.codex()

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "repair")
        self.assertEqual(
            entry["divergence"]["different"], ["skills/pr-review/scripts/review_pr.py"]
        )
        self.assertIn("skills/pr-review/scripts/review_pr.py", entry["message"])

    def test_a_skill_the_tracked_bundle_no_longer_has_is_reported_as_extra(self):
        cache = self.install_codex_cache()
        (cache / "skills" / "retired").mkdir()
        (cache / "skills" / "retired" / "SKILL.md").write_text("# retired\n", encoding="utf-8")
        self.configure_codex()

        code, entry = self.codex()

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "repair")
        self.assertEqual(entry["divergence"]["extra"], ["skills/retired/SKILL.md"])
        self.assertIn("skills/retired/SKILL.md", entry["message"])

    def test_an_extra_directory_holding_no_file_is_still_reported(self):
        # A file-only inventory cannot see this: the skill's files are gone
        # but its directory remains, so the cache still offers Codex a skill
        # the tracked bundle does not define.
        cache = self.install_codex_cache()
        (cache / "skills" / "retired").mkdir()
        self.configure_codex()

        code, entry = self.codex()

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "repair")
        self.assertEqual(entry["divergence"]["extra"], ["skills/retired/"])
        self.assertIn("skills/retired/", entry["message"])

    def test_a_nested_extra_directory_run_is_named_once_at_its_root(self):
        cache = self.install_codex_cache()
        (cache / "skills" / "retired" / "scripts" / "helpers").mkdir(parents=True)
        self.configure_codex()

        code, entry = self.codex()

        self.assertEqual(code, 1)
        self.assertEqual(entry["divergence"]["extra"], ["skills/retired/"])

    def test_an_ignored_file_does_not_mask_the_extra_directory_holding_it(self):
        # The retired skill's own files are gone and all that is left inside
        # it is an interpreter artefact. The artefact is not content, so it
        # cannot stand in for the directory: `skills/retired/` is still an
        # installed path the tracked bundle does not define.
        cache = self.install_codex_cache()
        artefact = cache / "skills" / "retired" / "__pycache__"
        artefact.mkdir(parents=True)
        (artefact / "helper.cpython-314.pyc").write_bytes(b"\x00compiled")
        self.configure_codex()

        code, entry = self.codex()

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "repair")
        self.assertEqual(entry["divergence"]["extra"], ["skills/retired/"])

    def test_an_ignored_directory_holding_no_file_is_never_divergence(self):
        # The emptied form of the artefact the packaged coordinator leaves
        # behind: still ignored, so still not bundle content.
        self.install_codex_cache()
        (self.cache_dir() / "skills" / "pr-review" / "scripts" / "__pycache__").mkdir()
        self.configure_codex()

        code, entry = self.codex("--apply")

        self.assertEqual(code, 0, entry)
        self.assertEqual(entry["status"], "unchanged")
        self.assertEqual(self.mutating_calls("codex"), [])

    def test_an_absent_cache_for_an_enabled_plugin_is_repairable_divergence(self):
        self.configure_codex()

        code, entry = self.codex()

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "repair")
        self.assertFalse(entry["divergence"]["installed"])
        self.assertIn(str(self.cache_dir()), entry["message"])
        self.assertEqual(self.mutating_calls("codex"), [])

    def test_the_cache_is_resolved_under_a_non_default_codex_home(self):
        elsewhere = self.root / "elsewhere" / "codex"
        self.install_codex_cache(elsewhere)
        self.configure_codex(codex_home=elsewhere)

        code, entry = self.codex(codex_home=elsewhere)

        self.assertEqual(code, 0, entry)
        self.assertEqual(entry["status"], "unchanged")
        # The fallback location is not consulted at all when the override is
        # set: a cache there must not stand in for the selected one.
        (self.cache_dir(elsewhere) / "skills" / "solve" / "SKILL.md").unlink()
        self.install_codex_cache()

        code, entry = self.codex(codex_home=elsewhere)

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "repair")
        self.assertEqual(entry["divergence"]["cache"], str(self.cache_dir(elsewhere)))

    # -- convergence ----------------------------------------------------------

    def test_a_matching_cache_reports_unchanged_and_runs_no_mutating_command(self):
        self.install_codex_cache()
        self.configure_codex()

        code, entry = self.codex("--apply")

        self.assertEqual(code, 0, entry)
        self.assertEqual(entry["status"], "unchanged")
        self.assertIsNone(entry["divergence"])
        self.assertEqual(self.mutating_calls("codex"), [])

    def test_an_ignored_checkout_artefact_is_never_divergence(self):
        # `__pycache__/` lands on both sides — the checkout grows one from
        # running the packaged coordinator, and the provider copies the
        # directory as it finds it — so counting either as content would make
        # the component report a repair it can never converge.
        self.install_codex_cache()
        for root in (self.bundle, self.cache_dir()):
            artefact = root / "skills" / "pr-review" / "scripts" / "__pycache__"
            artefact.mkdir()
            (artefact / "review_pr.cpython-314.pyc").write_bytes(b"\x00compiled")
        self.configure_codex()

        code, entry = self.codex("--apply")

        self.assertEqual(code, 0, entry)
        self.assertEqual(entry["status"], "unchanged")
        self.assertEqual(self.mutating_calls("codex"), [])

    def test_an_untracked_checkout_file_is_never_divergence(self):
        # Never added to the index, so it was never part of the bundle the
        # provider was asked to install, and its absence from the cache is
        # not staleness.
        self.install_codex_cache()
        (self.bundle / "skills" / "draft").mkdir(parents=True)
        (self.bundle / "skills" / "draft" / "SKILL.md").write_text("# wip\n", encoding="utf-8")
        self.configure_codex()

        code, entry = self.codex("--apply")

        self.assertEqual(code, 0, entry)
        self.assertEqual(entry["status"], "unchanged")
        self.assertEqual(self.mutating_calls("codex"), [])

    def test_apply_refreshes_through_remove_then_add_and_verifies_convergence(self):
        cache = self.install_codex_cache()
        (cache / "skills" / "solve" / "SKILL.md").unlink()
        (cache / "skills" / "retired").mkdir()
        (cache / "skills" / "retired" / "SKILL.md").write_text("# retired\n", encoding="utf-8")
        self.configure_codex()

        code, entry = self.codex("--apply")

        self.assertEqual(code, 0, entry)
        self.assertEqual(entry["status"], "repair")
        self.assertTrue(entry["applied"])
        self.assertIsNone(entry["divergence"])
        # The provider's own mechanism, in the only order that refreshes a
        # local-source bundle, and nothing that writes the cache directly.
        self.assertEqual(
            self.command_tails(),
            [
                ["plugin", "remove", "kanban@kanban"],
                ["plugin", "add", "kanban@kanban"],
            ],
        )
        self.assertTrue((cache / "skills" / "solve" / "SKILL.md").is_file())
        self.assertFalse((cache / "skills" / "retired").exists())

    def test_a_refresh_that_did_not_converge_is_reported_rather_than_claimed(self):
        # Both commands report success, but the cache they leave behind is
        # still stale: the provider's exit status is not evidence.
        cache = self.install_codex_cache()
        (cache / "skills" / "solve" / "SKILL.md").unlink()
        self.configure_codex(refresh=False)

        code, entry = self.codex("--apply")

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "failed")
        self.assertFalse(entry["applied"])
        self.assertIn("still does not match", entry["message"])

    def test_a_repaired_run_reports_the_same_installation_as_converged_afterwards(self):
        cache = self.install_codex_cache()
        (cache / "skills" / "solve" / "SKILL.md").unlink()
        self.configure_codex()
        first, _ = self.codex("--apply")
        self.assertEqual(first, 0)

        code, entry = self.codex("--apply")

        self.assertEqual(code, 0, entry)
        self.assertEqual(entry["status"], "unchanged")

    # -- unusable rather than diverged ---------------------------------------

    def test_a_cache_path_that_is_not_a_directory_is_unavailable_and_untouched(self):
        cache = self.cache_dir()
        cache.parent.mkdir(parents=True)
        cache.write_text("not a bundle\n", encoding="utf-8")
        self.configure_codex()

        code, entry = self.codex("--apply")

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "unavailable")
        self.assertIn(str(cache), entry["message"])
        self.assertEqual(self.mutating_calls("codex"), [])
        self.assertEqual(cache.read_text(encoding="utf-8"), "not a bundle\n")

    @unittest.skipIf(os.geteuid() == 0, "root can read a directory with no permissions")
    def test_an_unreadable_cache_is_unavailable_rather_than_read_as_empty(self):
        cache = self.install_codex_cache()
        skills = cache / "skills"
        skills.chmod(0o000)
        self.addCleanup(skills.chmod, 0o755)
        self.configure_codex()

        code, entry = self.codex("--apply")

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "unavailable")
        self.assertEqual(self.mutating_calls("codex"), [])

    def test_a_manifest_without_a_version_cannot_name_a_cache_to_compare(self):
        (self.bundle / ".codex-plugin" / "plugin.json").write_text(
            json.dumps({"name": "kanban"}) + "\n", encoding="utf-8"
        )
        self.install_codex_cache()
        self.configure_codex()

        code, entry = self.codex("--apply")

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "unavailable")
        self.assertIn("declares no usable version", entry["message"])
        self.assertEqual(self.mutating_calls("codex"), [])

    # -- the refusal states keep precedence ----------------------------------

    def test_a_marketplace_from_another_checkout_still_refuses_before_any_repair(self):
        other = self.root / "other-checkout" / "codex-plugin"
        self.install_provider(
            "codex",
            marketplaces=json.dumps([{"name": "kanban", "path": str(other)}]),
            plugins=(INSTALLED_AND_ENABLED,),
        )

        code, entry = self.codex("--apply")

        self.assertEqual(code, 1)
        self.assertEqual(entry["status"], "refused")
        self.assertIn(str(other), entry["message"])
        self.assertIn("codex plugin marketplace remove kanban", entry["message"])
        self.assertEqual(self.mutating_calls("codex"), [])

    def test_a_disabled_bundle_still_refuses_even_with_a_stale_cache(self):
        cache = self.install_codex_cache()
        (cache / "skills" / "solve" / "SKILL.md").unlink()
        self.configure_codex(plugins=(INSTALLED_BUT_DISABLED,))

        code, entry = self.codex("--apply")

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
        for name in install_issue_review.BACKEND_MODULES.values():
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
        for name in install_issue_review.BACKEND_MODULES.values():
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


class IssueReviewDiscoveryRecordTests(HermeticSetupTests):
    """Setup is the other supported way to install this backend, so it must
    publish the same discovery record `tools/install_issue_review.py` does --
    otherwise a custom installation made here would be undiscoverable
    (issue #155)."""

    def setUp(self):
        super().setUp()
        self.record_path = (
            self.home / "Library" / "Application Support" / "kanban" / "issue-review" / "config.json"
        )

    def record(self):
        return json.loads(self.record_path.read_text(encoding="utf-8"))

    def test_applying_publishes_the_record_for_a_custom_install_directory(self):
        self.install_dir = self.root / "opt" / "kanban-review"

        code, payload = self.run_setup("--component", "issue-review", "--apply")

        self.assertEqual(code, 0, payload)
        entry = self.component(payload, "issue-review")
        self.assertEqual(entry["status"], "install")
        self.assertEqual(entry["record"]["path"], str(self.record_path))
        self.assertEqual(
            self.record()["backend_path"],
            str(self.install_dir.resolve() / "approve_issues.py"),
        )

    def test_a_dry_run_reports_the_planned_record_and_writes_nothing(self):
        self.install_dir = self.root / "opt" / "kanban-review"

        code, payload = self.run_setup("--component", "issue-review")

        self.assertEqual(code, 0, payload)
        entry = self.component(payload, "issue-review")
        self.assertEqual(entry["record"]["result"], "created")
        self.assertFalse(self.record_path.exists())

    def test_an_installation_predating_the_record_is_repaired_rather_than_reported_converged(self):
        self.install_dir = self.root / "opt" / "kanban-review"
        self.run_setup("--component", "issue-review", "--apply")
        # Exactly the state an upgrade finds: correct links, no record.
        self.record_path.unlink()

        code, payload = self.run_setup("--component", "issue-review", "--apply")

        self.assertEqual(code, 0, payload)
        entry = self.component(payload, "issue-review")
        self.assertEqual(entry["status"], "install")
        self.assertEqual(
            self.record()["backend_path"],
            str(self.install_dir.resolve() / "approve_issues.py"),
        )

    def test_re_running_a_complete_installation_converges(self):
        self.install_dir = self.root / "opt" / "kanban-review"
        self.run_setup("--component", "issue-review", "--apply")

        _, payload = self.run_setup("--component", "issue-review", "--apply")

        entry = self.component(payload, "issue-review")
        self.assertEqual(entry["status"], "unchanged")
        self.assertEqual(entry["record"]["result"], "unchanged")

    def test_an_xdg_host_records_through_its_own_platforms_location(self):
        # Setup shares one resolver with the installer, so the platform's
        # answer has to reach it rather than only the installer (issue #357).
        # Driven end to end rather than by calling the resolver again: the
        # record this writes is what a dashboard later reads.
        self.platform_is("linux")
        self.record_path = (
            self.home / ".local" / "share" / "kanban" / "issue-review" / "config.json"
        )
        self.install_dir = self.root / "opt" / "kanban-review"

        code, payload = self.run_setup("--component", "issue-review", "--apply")

        self.assertEqual(code, 0, payload)
        entry = self.component(payload, "issue-review")
        self.assertEqual(entry["record"]["path"], str(self.record_path))
        self.assertEqual(
            self.record()["backend_path"],
            str(self.install_dir.resolve() / "approve_issues.py"),
        )
        # And nothing is written to the other platform's location.
        self.assertFalse(
            (
                self.home / "Library" / "Application Support" / "kanban" / "issue-review"
            ).exists()
        )


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


class ArchiveAssetRootTests(HermeticSetupTests):
    """Setup run the way a release recipient runs it.

    The asset root is an unpacked archive -- a tree of the same tracked files
    with no `.git` anywhere -- and the repository a project-scoped
    registration would be declared in is a separate checkout. The real
    `cabal sdist` archive is exercised as a subprocess by
    `tools/test_source_distribution.py`; what these cases pin is the behavior
    that archive shape produces, which needs no toolchain to reach.
    """

    def setUp(self):
        super().setUp()
        # Resolved, because setup resolves both roots before it reports or
        # uses them and macOS's temporary directory is itself a symlink.
        self.archive = self.unpacked_archive("kanban-1.1.0.0").resolve()
        self.target = self.make_target("project").resolve()

    def unpacked_archive(self, name):
        """A copy of the tracked tree with every trace of Git removed."""
        archive = self.root / name
        shutil.copytree(self.repo, archive)
        shutil.rmtree(archive / ".git")
        self.assertFalse(
            list(archive.rglob(".git")), f"{archive} still carries Git metadata"
        )
        return archive

    def make_target(self, name):
        """A repository a project-scoped registration could be declared in:
        its own main checkout, with a remote naming a repository on
        github.com."""
        target = self.root / name
        target.mkdir()
        for command in (
            ["git", "init", "-q", str(target)],
            [
                "git",
                "-C",
                str(target),
                "remote",
                "add",
                "origin",
                "git@github.com:acme/widgets.git",
            ],
        ):
            subprocess.run(command, check=True, capture_output=True, text=True)
        return target

    def test_every_component_plans_and_applies_from_the_archive(self):
        self.install_provider("codex")
        self.install_provider("claude")

        code, plan = self.run_setup(
            "--all", "--scope", "user", repo=self.archive
        )
        self.assertEqual(code, 0, plan)
        for name in setup_workflows.COMPONENTS:
            self.assertEqual(self.component(plan, name)["status"], "install", name)

        code, applied = self.run_setup(
            "--all", "--scope", "user", "--apply", repo=self.archive
        )
        self.assertEqual(code, 0, applied)
        # Every managed link resolves into the archive, never into the target
        # checkout and never into the source tree these tests were run from.
        for name in install_issue_review.BACKEND_MODULES.values():
            with self.subTest(module=name):
                self.assertEqual(
                    (self.install_dir / name).resolve(),
                    (self.archive / "tools" / name).resolve(),
                )
        self.assertEqual(
            self.legacy_path.resolve(),
            (self.install_dir / "approve_issues.py").resolve(),
        )
        for binary in ("codex", "claude"):
            with self.subTest(provider=binary):
                added = [
                    call
                    for call in self.mutating_calls(binary)
                    if call["args"][:3] == ["plugin", "marketplace", "add"]
                ]
                self.assertEqual(len(added), 1, added)
                self.assertTrue(
                    added[0]["args"][3].startswith(str(self.archive)), added
                )

    def test_a_project_scoped_run_with_no_target_refuses_before_probing(self):
        self.install_provider("codex")
        self.install_provider("claude")

        code, payload = self.run_setup("--all", repo=self.archive)

        self.assertEqual(code, 1, payload)
        claude = self.component(payload, "claude-plugin")
        self.assertEqual(claude["status"], "refused")
        self.assertIn("--target", claude["message"])
        self.assertIsNone(claude["target"])
        self.assertIsNone(payload["target"])
        # Nothing was probed for it, and no project state was declared in the
        # archive -- which is the directory #538 goes on to have the user
        # delete, and the reason silently defaulting the target there would be
        # worse than refusing.
        self.assertEqual(self.fake.calls("claude"), [])
        self.assertFalse((self.archive / ".claude").exists())
        self.assertFalse((self.archive / ".claude.json").exists())
        # And it did not silently become a user-scoped registration either.
        self.assertEqual(payload["scope"], "project")

    def test_the_target_free_components_run_alone_under_the_default_scope(self):
        # The other half of the case above, and the pair a release upgrade
        # documents selecting on their own from the new archive. Neither
        # declares a project-scoped registration, so neither consumes
        # --target -- and the default scope must not refuse them on an archive
        # that could never supply one. Without this, the refusal above would
        # be free to widen to every component and still pass.
        code, plan = self.run_setup(
            "--component",
            "issue-review",
            "--component",
            "legacy-launcher",
            repo=self.archive,
        )

        self.assertEqual(code, 0, plan)
        self.assertEqual(plan["scope"], "project")
        self.assertIsNone(plan["target"])
        for name in ("issue-review", "legacy-launcher"):
            with self.subTest(component=name):
                self.assertEqual(self.component(plan, name)["status"], "install", plan)

        code, applied = self.run_setup(
            "--component",
            "issue-review",
            "--component",
            "legacy-launcher",
            "--apply",
            repo=self.archive,
        )

        self.assertEqual(code, 0, applied)
        for name in install_issue_review.BACKEND_MODULES.values():
            with self.subTest(module=name):
                self.assertEqual(
                    (self.install_dir / name).resolve(),
                    (self.archive / "tools" / name).resolve(),
                )
        self.assertEqual(
            self.legacy_path.resolve(),
            (self.install_dir / "approve_issues.py").resolve(),
        )

    def test_a_project_scoped_run_with_a_valid_target_installs(self):
        self.install_provider("claude")

        code, payload = self.run_setup(
            "--component",
            "claude-plugin",
            "--target",
            str(self.target),
            "--apply",
            repo=self.archive,
        )

        self.assertEqual(code, 0, payload)
        component = self.component(payload, "claude-plugin")
        self.assertEqual(component["status"], "install")
        self.assertEqual(payload["target"], str(self.target))
        self.assertEqual(payload["repo"], str(self.archive))
        # The marketplace is added from the archive, and the command runs in
        # the target -- the repository the project registration belongs to.
        for call in self.mutating_calls("claude"):
            with self.subTest(call=call["args"]):
                self.assertEqual(call["cwd"], str(self.target))
        added = next(
            call
            for call in self.mutating_calls("claude")
            if call["args"][:3] == ["plugin", "marketplace", "add"]
        )
        self.assertEqual(added["args"][3], str(self.archive / "claude-plugin"))

    def test_a_target_that_is_not_a_checkout_is_refused(self):
        self.install_provider("claude")
        outsider = self.root / "not-a-repo"
        outsider.mkdir()

        code, payload = self.run_setup(
            "--component",
            "claude-plugin",
            "--target",
            str(outsider),
            repo=self.archive,
        )

        self.assertEqual(code, 1)
        self.assertIn("--target", payload["error"])
        self.assertEqual(self.fake.calls("claude"), [])

    def test_a_target_with_no_supported_github_remote_is_refused(self):
        self.install_provider("claude")
        local = self.root / "local-only"
        local.mkdir()
        subprocess.run(
            ["git", "init", "-q", str(local)], check=True, capture_output=True
        )

        code, payload = self.run_setup(
            "--component",
            "claude-plugin",
            "--target",
            str(local),
            repo=self.archive,
        )

        self.assertEqual(code, 1)
        self.assertIn("--target", payload["error"])
        self.assertEqual(self.fake.calls("claude"), [])

    def test_a_user_scoped_target_that_does_not_exist_is_refused(self):
        # User scope declares nothing in the target, so it is not required to
        # be a repository -- but it is still where every provider command
        # runs, so a path that is not there is the mistake it looks like.
        self.install_provider("claude")

        code, payload = self.run_setup(
            "--component",
            "claude-plugin",
            "--scope",
            "user",
            "--target",
            str(self.root / "absent"),
            repo=self.archive,
        )

        self.assertEqual(code, 1)
        self.assertIn("--target", payload["error"])
        self.assertEqual(self.fake.calls("claude"), [])

    def test_an_explicit_user_scope_needs_no_target_and_runs_in_the_archive(self):
        self.install_provider("claude")

        code, payload = self.run_setup(
            "--component",
            "claude-plugin",
            "--scope",
            "user",
            "--apply",
            repo=self.archive,
        )

        self.assertEqual(code, 0, payload)
        self.assertIsNone(payload["target"])
        for call in self.fake.calls("claude"):
            with self.subTest(call=call["args"]):
                self.assertEqual(call["cwd"], str(self.archive))
                # Unambiguously user-scoped, so nothing it ran could have
                # declared project state in the archive it ran in.
                if call["args"][:1] == ["plugin"] and "--scope" in call["args"]:
                    self.assertEqual(
                        call["args"][call["args"].index("--scope") + 1], "user"
                    )
        self.assertFalse((self.archive / ".claude").exists())

    def test_the_codex_bundle_comparison_asks_the_archive_no_git_question(self):
        # The second convergence pass a released install reaches: the bundle
        # is registered and enabled, so setup compares the installed copy
        # against the tracked one -- an inventory the checkout path answers
        # with `git ls-files` and `git check-ignore`, and the archive must
        # answer without either.
        self.install_provider(
            "codex",
            marketplaces=json.dumps(
                [{"name": "kanban", "path": str(self.archive / "codex-plugin")}]
            ),
            plugins=(INSTALLED_AND_ENABLED,),
        )
        cache = self.cache_dir()
        shutil.copytree(self.archive / "codex-plugin" / "plugins" / "kanban", cache)
        # The artefact a packaged coordinator leaves in its own installed
        # copy. It is not bundle content on either side, and the archive has
        # no ignore rules to say so.
        (cache / "skills" / "pr-review" / "scripts" / "__pycache__").mkdir()
        (
            cache
            / "skills"
            / "pr-review"
            / "scripts"
            / "__pycache__"
            / "review_pr.cpython-312.pyc"
        ).write_bytes(b"\x00")

        code, payload = self.run_setup(
            "--component", "codex-plugin", "--scope", "user", repo=self.archive
        )

        self.assertEqual(code, 0, payload)
        component = self.component(payload, "codex-plugin")
        self.assertEqual(component["status"], "unchanged", component)
        self.assertIsNone(component["divergence"])
        self.assertEqual(component["commands"], [])

    def test_a_stale_archive_bundle_is_still_reported_as_a_repair(self):
        # The same comparison, with the teeth left in: an inventory that
        # reported nothing would report `unchanged` for a genuinely stale
        # cache too.
        self.install_provider(
            "codex",
            marketplaces=json.dumps(
                [{"name": "kanban", "path": str(self.archive / "codex-plugin")}]
            ),
            plugins=(INSTALLED_AND_ENABLED,),
        )
        cache = self.cache_dir()
        shutil.copytree(self.archive / "codex-plugin" / "plugins" / "kanban", cache)
        (cache / "skills" / "solve" / "SKILL.md").write_text(
            "# stale\n", encoding="utf-8"
        )

        code, payload = self.run_setup(
            "--component", "codex-plugin", "--scope", "user", repo=self.archive
        )

        self.assertEqual(code, 1, payload)
        component = self.component(payload, "codex-plugin")
        self.assertEqual(component["status"], "repair")
        self.assertEqual(
            component["divergence"]["different"], ["skills/solve/SKILL.md"]
        )

    def test_a_marketplace_from_the_previous_archive_is_refused_untouched(self):
        # No provenance marker can recognize a directory registration, so a
        # marketplace added from the previous archive is a path mismatch like
        # any other. It is reported and left alone; #538 owns the manual
        # removal that clears it.
        previous = self.unpacked_archive("kanban-1.0.0.0").resolve()
        self.install_provider(
            "claude",
            marketplaces=json.dumps(
                [{"name": "kanban", "path": str(previous / "claude-plugin")}]
            ),
        )

        code, payload = self.run_setup(
            "--component",
            "claude-plugin",
            "--scope",
            "user",
            "--apply",
            repo=self.archive,
        )

        self.assertEqual(code, 1, payload)
        component = self.component(payload, "claude-plugin")
        self.assertEqual(component["status"], "refused")
        self.assertIn(str(previous / "claude-plugin"), component["message"])
        self.assertEqual(self.mutating_calls("claude"), [])

    def test_setup_removed_from_the_archive_after_manual_removal_converges(self):
        # The other half of the sequence above: once the user has removed the
        # plugin and the marketplace themselves, the same command registers
        # the new archive and converges.
        self.install_provider("claude", marketplaces="[]")

        code, payload = self.run_setup(
            "--component",
            "claude-plugin",
            "--scope",
            "user",
            "--apply",
            repo=self.archive,
        )

        self.assertEqual(code, 0, payload)
        added = next(
            call
            for call in self.mutating_calls("claude")
            if call["args"][:3] == ["plugin", "marketplace", "add"]
        )
        self.assertEqual(added["args"][3], str(self.archive / "claude-plugin"))

    def test_a_dry_run_from_the_archive_writes_nothing_anywhere(self):
        self.install_provider("codex")
        self.install_provider("claude")
        before = self.tree_snapshot(self.archive) | self.tree_snapshot(self.target)

        code, payload = self.run_setup(
            "--all", "--scope", "user", repo=self.archive
        )

        self.assertEqual(code, 0, payload)
        self.assertEqual(
            self.tree_snapshot(self.archive) | self.tree_snapshot(self.target), before
        )
        self.assertFalse(self.install_dir.exists())
        self.assertFalse(self.legacy_path.exists())

    def tree_snapshot(self, root):
        return {
            path.relative_to(root).as_posix(): path.stat().st_mtime_ns
            for path in sorted(root.rglob("*"))
            if path.is_file()
        }

    def test_an_asset_root_missing_a_selected_components_files_is_refused(self):
        (self.archive / "claude-plugin" / ".claude-plugin" / "marketplace.json").unlink()

        code, payload = self.run_setup(
            "--component", "claude-plugin", "--scope", "user", repo=self.archive
        )

        self.assertEqual(code, 1)
        self.assertIn("marketplace.json", payload["error"])

    def test_an_unselected_components_assets_are_not_required(self):
        # Validation is per selected component: setting up the Codex bundle
        # from a tree with no backend modules is a supported archive, not a
        # broken one.
        shutil.rmtree(self.archive / "tools")
        self.install_provider("codex")

        code, payload = self.run_setup(
            "--component", "codex-plugin", "--scope", "user", repo=self.archive
        )

        self.assertEqual(code, 0, payload)
        self.assertEqual(
            self.component(payload, "codex-plugin")["status"], "install"
        )


class CheckoutDefaultTests(HermeticSetupTests):
    """The established checkout behavior, held where the two roots meet."""

    def test_the_target_still_defaults_to_the_asset_checkout(self):
        self.install_provider("claude")

        code, payload = self.run_setup("--component", "claude-plugin")

        self.assertEqual(code, 0, payload)
        self.assertEqual(payload["repo"], str(self.repo.resolve()))
        self.assertEqual(payload["target"], str(self.repo.resolve()))
        self.assertEqual(
            self.component(payload, "claude-plugin")["target"],
            str(self.repo.resolve()),
        )

    def unsupport_the_remote(self, url):
        """Point the fixture checkout's `origin` somewhere that is not a
        repository on github.com."""
        for command in (
            ["git", "-C", str(self.repo), "remote", "remove", "origin"],
            ["git", "-C", str(self.repo), "remote", "add", "origin", url],
        ):
            subprocess.run(command, check=True, capture_output=True, text=True)

    def test_a_defaulted_target_with_no_supported_remote_is_refused(self):
        # The default is validated exactly as an explicit --target is: the
        # registration lands in that repository either way, so how the path
        # was chosen cannot decide whether the rule applies.
        self.install_provider("claude")
        self.unsupport_the_remote(str(self.root / "bare.git"))

        code, payload = self.run_setup("--component", "claude-plugin")

        self.assertEqual(code, 1)
        self.assertIn("--target", payload["error"])
        self.assertEqual(self.fake.calls("claude"), [])

    def test_a_defaulted_target_with_no_remote_at_all_is_refused(self):
        self.install_provider("claude")
        subprocess.run(
            ["git", "-C", str(self.repo), "remote", "remove", "origin"],
            check=True,
            capture_output=True,
            text=True,
        )

        code, payload = self.run_setup("--component", "claude-plugin")

        self.assertEqual(code, 1)
        self.assertIn("--target", payload["error"])
        self.assertEqual(self.fake.calls("claude"), [])

    def test_an_unsupported_default_still_serves_a_user_scoped_run(self):
        # Nothing is declared in the target under user scope, so there is no
        # project registration to refuse — the checkout is still where the
        # provider commands run.
        self.install_provider("claude")
        self.unsupport_the_remote(str(self.root / "bare.git"))

        code, payload = self.run_setup(
            "--component", "claude-plugin", "--scope", "user"
        )

        self.assertEqual(code, 0, payload)
        self.assertEqual(payload["target"], str(self.repo.resolve()))

    def test_an_unsupported_default_still_serves_the_issue_review_components(self):
        # They write nothing outside --install-dir, so a target they never
        # consume must not be able to refuse them.
        self.unsupport_the_remote(str(self.root / "bare.git"))

        code, payload = self.run_setup("--component", "issue-review", "--apply")

        self.assertEqual(code, 0, payload)
        self.assertEqual(
            self.component(payload, "issue-review")["status"], "install"
        )

    def test_provider_probes_run_in_the_defaulted_target(self):
        self.install_provider("codex")
        self.install_provider("claude")

        self.run_setup("--all", "--scope", "user")

        for binary in ("codex", "claude"):
            for call in self.fake.calls(binary):
                with self.subTest(provider=binary, call=call["args"]):
                    self.assertEqual(call["cwd"], str(self.repo.resolve()))


if __name__ == "__main__":
    unittest.main()
