"""What the packaged resolvers actually *do* when they look for the canonical
issue-review backend's discovery record (issues #445 and #841).

`tools/test_agent_workflow_contract.py`, `tools/test_claude_plugin.py` and
`tools/test_codex_plugin.py` prove that both record spellings are *present* in
every file that owes them. Presence is not behavior: a resolver could name both
locations and still probe only one, probe them in the wrong order, or read a
dangling symlink as "never installed" and fall through it. These tests drive
each resolver against a redirected `$HOME` and assert which record it selects,
which backend it returns, and what its diagnostic says when it finds none.

Seventeen resolvers owe the same answers -- `tools/resolve_issue_review_backend.py`
and its ten byte-identical bundled copies, and the six pull-request
coordinators' own Python probes -- and each is exercised through its real
surface: the script by running it as a program, the coordinator by calling its
`approver_path()`. Nothing here reimplements the probe, so these tests cannot
agree with a resolver that is wrong.

Since issue #841 the fourteen Markdown workflow assets embed no probe: each calls
the bundled script. The last classes here drive each asset's own call to it, from
a directory that is not the plugin, against an installed-bundle fixture, so a
rewrite that keeps the prose and breaks the lookup fails.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import kanban_config

REPO_ROOT = Path(__file__).resolve().parent.parent

# The two record locations, in probe order, spelled as this fixture builds
# them rather than imported from a resolver: a resolver that changed its mind
# about either one must fail these tests rather than move them with it.
XDG_RECORD_DIR = ".local/share/kanban/issue-review"
LIBRARY_RECORD_DIR = "Library/Application Support/kanban/issue-review"
RECORD_NAME = "config.json"
BACKEND_NAME = "approve_issues.py"

# Every markdown workflow asset that resolves the backend. Fourteen of them
# call the bundled script, which test_every_markdown_asset_calls_the_script pins.
MARKDOWN_RESOLVER_ASSETS = (
    "claude-plugin/plugins/kanban/commands/issue-review.md",
    "codex-plugin/plugins/kanban/skills/issue-review/SKILL.md",
    "claude-plugin/plugins/kanban/commands/solve.md",
    "codex-plugin/plugins/kanban/skills/solve/SKILL.md",
    "claude-plugin/plugins/kanban/commands/issue-rereview.md",
    "codex-plugin/plugins/kanban/skills/issue-rereview/SKILL.md",
    "claude-plugin/plugins/kanban/commands/triage.md",
    "codex-plugin/plugins/kanban/skills/triage/SKILL.md",
    "claude-plugin/plugins/kanban/commands/retriage.md",
    "codex-plugin/plugins/kanban/skills/retriage/SKILL.md",
    "grok-plugin/plugins/kanban/skills/solve/SKILL.md",
    "kimi-plugin/plugins/kanban/skills/solve/SKILL.md",
    "google-plugin/plugins/kanban/skills/solve/SKILL.md",
    "claude-copilot-plugin/plugins/kanban/skills/solve/SKILL.md",
)

HELPER_NAME = "resolve_issue_review_backend.py"
HELPER_SOURCE = "tools/" + HELPER_NAME

# The ten bundled copies: one shared by the Claude commands, one in each Codex
# skill that resolves the backend, and one beside each external solve skill's
# trusted-comment helper.
HELPER_COPIES = (
    "claude-plugin/plugins/kanban/scripts/" + HELPER_NAME,
    "codex-plugin/plugins/kanban/skills/issue-review/scripts/" + HELPER_NAME,
    "codex-plugin/plugins/kanban/skills/issue-rereview/scripts/" + HELPER_NAME,
    "codex-plugin/plugins/kanban/skills/solve/scripts/" + HELPER_NAME,
    "codex-plugin/plugins/kanban/skills/triage/scripts/" + HELPER_NAME,
    "codex-plugin/plugins/kanban/skills/retriage/scripts/" + HELPER_NAME,
    "grok-plugin/plugins/kanban/skills/solve/scripts/" + HELPER_NAME,
    "kimi-plugin/plugins/kanban/skills/solve/scripts/" + HELPER_NAME,
    "google-plugin/plugins/kanban/skills/solve/scripts/" + HELPER_NAME,
    "claude-copilot-plugin/plugins/kanban/skills/solve/scripts/" + HELPER_NAME,
)

COORDINATORS = (
    ("claude", "claude-plugin/plugins/kanban/scripts/review_pr.py"),
    ("codex", "codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py"),
    ("grok", "grok-plugin/plugins/kanban/scripts/review_pr.py"),
    ("kimi", "kimi-plugin/plugins/kanban/scripts/review_pr.py"),
    ("google", "google-plugin/plugins/kanban/scripts/review_pr.py"),
    ("claude-copilot", "claude-copilot-plugin/plugins/kanban/scripts/review_pr.py"),
)

BASH_FENCE_RE = re.compile(r"```bash\n(.*?)\n[ \t]*```", re.DOTALL)


def asset_fences(relative_path):
    """Every bash fence in a packaged markdown asset, recovered from the
    shipped file rather than restated here."""
    content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
    return [match.group(1) for match in BASH_FENCE_RE.finditer(content)]


def helper_call_fence(relative_path):
    """The one bash fence in a packaged asset that calls the bundled script."""
    fences = [fence for fence in asset_fences(relative_path) if HELPER_NAME in fence]
    if len(fences) != 1:
        raise AssertionError(
            f"{relative_path} has {len(fences)} bash fences naming {HELPER_NAME}, "
            "so there is no single call to exercise"
        )
    return fences[0]


def load_coordinator(name, relative_path):
    """Import a packaged coordinator by file path; none of the six live
    under tools/, so none is importable by name."""
    module_name = f"kanban_{name}_plugin_review_pr_probe"
    spec = importlib.util.spec_from_file_location(module_name, REPO_ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    # dataclass field resolution looks the module up in sys.modules by name
    # while exec_module is still running, so it must be registered first.
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


class Resolution:
    """One resolver's answer: the backend it resolved, or the diagnostic it
    refused with. Both surfaces report those same two outcomes, so both are
    compared through this."""

    def __init__(self, backend, message):
        self.backend = backend
        self.message = message

    @property
    def resolved(self):
        return self.backend is not None


class ScriptResolver:
    """The bundled script, run as a program the way an asset runs it: from a
    directory that is not the plugin, with only the environment given."""

    def __init__(self, relative_path):
        self.name = relative_path
        self.script = REPO_ROOT / relative_path

    def run(self, environment):
        return subprocess.run(
            [sys.executable, str(self.script)],
            env=environment,
            cwd=environment.get("HOME") or None,
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )

    def resolve(self, environment):
        completed = self.run(environment)
        if completed.returncode == 0:
            return Resolution(completed.stdout.strip(), completed.stderr)
        return Resolution(None, completed.stderr)


class CoordinatorResolver:
    """A packaged coordinator's approver_path(), called directly."""

    def __init__(self, name, relative_path):
        self.name = relative_path
        self.module = load_coordinator(name, relative_path)

    def resolve(self, environment):
        with mock.patch.dict(os.environ, environment, clear=True):
            try:
                return Resolution(str(self.module.approver_path()), "")
            except self.module.WorkflowError as error:
                return Resolution(None, str(error))


def coordinator_resolvers():
    return [CoordinatorResolver(name, path) for name, path in COORDINATORS]


def script_resolvers():
    """The tools source and every bundled copy."""
    return [ScriptResolver(path) for path in (HELPER_SOURCE,) + HELPER_COPIES]


def every_resolver():
    """The full seventeen."""
    return script_resolvers() + coordinator_resolvers()


def install(directory, backend_path=""):
    """Install a backend and its discovery record in `directory`, the way
    `tools/install_issue_review.py` leaves them. `backend_path=None` writes a
    record naming none, which is what an installation predating the record
    looks like; any other value overrides what the record names."""
    directory.mkdir(parents=True, exist_ok=True)
    backend = directory / BACKEND_NAME
    backend.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
    if backend_path is None:
        document = {}
    else:
        document = {"backend_path": str(backend) if backend_path == "" else backend_path}
    (directory / RECORD_NAME).write_text(json.dumps(document), encoding="utf-8")
    return backend


class PackagedRecordProbeTests(unittest.TestCase):
    """The probe order, the `$XDG_DATA_HOME` rule, occupancy, and the
    not-installed diagnostic.

    Run against the six coordinators and the tools source of the bundled
    script that stands in for its ten byte-identical copies;
    EveryPackagedResolverProbesTests below pins that identity and drives all
    seventeen through the ordering case.
    """

    @classmethod
    def setUpClass(cls):
        cls.resolvers = [ScriptResolver(HELPER_SOURCE)] + coordinator_resolvers()

    def setUp(self):
        # A real temporary $HOME, because every resolver here reads the record
        # through the home directory rather than through an injectable seam.
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name) / "home"
        self.home.mkdir()
        self.xdg_dir = self.home / XDG_RECORD_DIR
        self.library_dir = self.home / LIBRARY_RECORD_DIR

    def env(self, **overrides):
        """A process environment carrying this test's `$HOME`, whatever finds
        `python3`, and nothing else a resolver might read by accident."""
        environment = {
            "HOME": str(self.home),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        }
        for key, value in overrides.items():
            if value is None:
                environment.pop(key, None)
            else:
                environment[key] = value
        return environment

    def resolutions(self, environment):
        return [(resolver.name, resolver.resolve(environment)) for resolver in self.resolvers]

    def assertResolves(self, environment, backend):
        for name, resolution in self.resolutions(environment):
            with self.subTest(resolver=name):
                self.assertEqual(resolution.backend, str(backend), resolution.message)

    # -- probe order -------------------------------------------------------

    def test_an_xdg_only_installation_is_selected(self):
        self.assertResolves(self.env(), install(self.xdg_dir))

    def test_a_library_only_installation_is_selected(self):
        self.assertResolves(self.env(), install(self.library_dir))

    def test_the_xdg_installation_wins_when_both_exist(self):
        xdg_backend = install(self.xdg_dir)
        library_backend = install(self.library_dir)
        for name, resolution in self.resolutions(self.env()):
            with self.subTest(resolver=name):
                self.assertEqual(resolution.backend, str(xdg_backend), resolution.message)
                self.assertNotEqual(resolution.backend, str(library_backend))

    def test_neither_record_names_the_xdg_backend_and_both_locations(self):
        # Requirement 4: no asset decides which platform it is on, so the XDG
        # candidate supplies the answer on every host and the diagnostic names
        # both records rather than the one this platform would have written.
        for name, resolution in self.resolutions(self.env()):
            with self.subTest(resolver=name):
                self.assertFalse(resolution.resolved, resolution.backend)
                self.assertIn(str(self.xdg_dir / BACKEND_NAME), resolution.message)
                self.assertIn(str(self.xdg_dir / RECORD_NAME), resolution.message)
                self.assertIn(str(self.library_dir / RECORD_NAME), resolution.message)
                self.assertIn("python3 tools/install_issue_review.py", resolution.message)

    # -- the $XDG_DATA_HOME rule -------------------------------------------

    def test_a_non_empty_xdg_data_home_moves_the_first_candidate(self):
        base = self.home / "elsewhere"
        backend = install(base / "kanban" / "issue-review")
        # The home-relative candidate is seeded too, so selecting it would be
        # visible rather than indistinguishable from an unset variable.
        install(self.xdg_dir)
        self.assertResolves(self.env(XDG_DATA_HOME=str(base)), backend)

    def test_an_unset_xdg_data_home_uses_the_home_relative_candidate(self):
        self.assertResolves(self.env(XDG_DATA_HOME=None), install(self.xdg_dir))

    def test_an_empty_xdg_data_home_uses_the_home_relative_candidate(self):
        # Requirement 2: the issue-review rule is "set and non-empty", the one
        # `_xdg_issue_review_dir` follows -- not the drainer's absolute-only
        # rule. An empty variable must read as unset rather than as a base
        # directory of "".
        self.assertResolves(self.env(XDG_DATA_HOME=""), install(self.xdg_dir))

    def test_the_python_resolver_agrees_on_the_record_location(self):
        # The same answer tools/kanban_config.py gives for the same
        # environment, in the two environments where the packaged rule and the
        # Python one cannot disagree: a record exists, so no platform write
        # default is involved. With neither record present they deliberately
        # differ on macOS -- requirement 4 -- which is why that case is
        # asserted above against the literal paths instead.
        for variable in (None, str(self.home / "elsewhere")):
            with self.subTest(xdg_data_home=variable):
                directory = (
                    self.home / XDG_RECORD_DIR
                    if variable is None
                    else Path(variable) / "kanban" / "issue-review"
                )
                backend = install(directory)
                environment = self.env(XDG_DATA_HOME=variable)
                with mock.patch.dict(os.environ, environment, clear=True):
                    self.assertEqual(
                        kanban_config.issue_review_record_path(),
                        directory / RECORD_NAME,
                    )
                self.assertResolves(environment, backend)

    # -- occupancy is existence, not readability ---------------------------

    def test_a_dangling_symlink_at_the_xdg_record_still_selects_it(self):
        # Requirement 3: occupancy is `os.path.lexists`. Reading the dangling
        # link as absent and resolving `~/Library` instead would silently run
        # an installation the operator did not select.
        install(self.library_dir)
        self.xdg_dir.mkdir(parents=True)
        (self.xdg_dir / RECORD_NAME).symlink_to(self.xdg_dir / "gone.json")
        for name, resolution in self.resolutions(self.env()):
            with self.subTest(resolver=name):
                self.assertFalse(resolution.resolved, resolution.backend)
                self.assertIn("unreadable", resolution.message)
                self.assertIn(str(self.xdg_dir / RECORD_NAME), resolution.message)
                self.assertNotIn(str(self.library_dir / BACKEND_NAME), resolution.message)

    def test_a_directory_at_the_xdg_record_still_selects_it(self):
        install(self.library_dir)
        (self.xdg_dir / RECORD_NAME).mkdir(parents=True)
        for name, resolution in self.resolutions(self.env()):
            with self.subTest(resolver=name):
                self.assertFalse(resolution.resolved, resolution.backend)
                self.assertIn("unreadable", resolution.message)
                self.assertIn(str(self.xdg_dir / RECORD_NAME), resolution.message)
                self.assertNotIn(str(self.library_dir / BACKEND_NAME), resolution.message)

    # -- the behavior this change must not alter ---------------------------

    def test_a_record_naming_no_backend_still_upgrades_in_place(self):
        # Requirement 13: the compatibility fallback to the record's own
        # directory is unchanged, and its diagnostic still names the one
        # record that was read rather than both candidates.
        backend = install(self.library_dir, backend_path=None)
        self.assertResolves(self.env(), backend)
        backend.unlink()
        for name, resolution in self.resolutions(self.env()):
            with self.subTest(resolver=name):
                self.assertFalse(resolution.resolved, resolution.backend)
                self.assertIn(str(self.library_dir / RECORD_NAME), resolution.message)
                self.assertNotIn(str(self.xdg_dir / RECORD_NAME), resolution.message)
                self.assertIn("python3 tools/install_issue_review.py", resolution.message)

    def test_the_install_dir_override_still_outranks_both_records(self):
        install(self.xdg_dir)
        install(self.library_dir)
        chosen = self.home / "chosen"
        backend = install(chosen)
        self.assertResolves(
            self.env(KANBAN_ISSUE_REVIEW_INSTALL_DIR=str(chosen)), backend
        )

    def test_a_record_naming_a_relative_backend_still_fails_closed(self):
        install(self.xdg_dir, backend_path=BACKEND_NAME)
        for name, resolution in self.resolutions(self.env()):
            with self.subTest(resolver=name):
                self.assertFalse(resolution.resolved, resolution.backend)
                self.assertIn(str(self.xdg_dir / RECORD_NAME), resolution.message)


class EveryPackagedResolverProbesTests(unittest.TestCase):
    """The matrix above runs against the script's tools source. These hold its
    ten bundled copies to being the same program, hold the fourteen assets to
    calling it instead of embedding a probe, and drive every one of the
    seventeen resolvers through the ordering case so none is covered by
    identity alone."""

    def test_every_bundled_copy_is_the_tools_source(self):
        source = (REPO_ROOT / HELPER_SOURCE).read_bytes()
        self.assertEqual(len(HELPER_COPIES), 10)
        for relative_path in HELPER_COPIES:
            with self.subTest(copy=relative_path):
                self.assertEqual(
                    (REPO_ROOT / relative_path).read_bytes(),
                    source,
                    f"{relative_path} has drifted from {HELPER_SOURCE}; "
                    f"cp {HELPER_SOURCE} {relative_path}",
                )

    def test_every_markdown_asset_calls_the_script_and_embeds_no_probe(self):
        self.assertEqual(len(MARKDOWN_RESOLVER_ASSETS), 14)
        for relative_path in MARKDOWN_RESOLVER_ASSETS:
            with self.subTest(asset=relative_path):
                content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
                fence = helper_call_fence(relative_path)
                # The external assets' trusted-helper locator legitimately
                # carries a Python heredoc of its own, so the probe is
                # recognized by what only it says.
                for fragment in (
                    "XDG_RECORD",
                    "does not name an absolute backend_path",
                    "Canonical issue reviewer was not found at {resolved}",
                ):
                    self.assertNotIn(fragment, content)
                self.assertNotIn("KANBAN_ISSUE_REVIEW_INSTALL_DIR", fence)
                self.assertIn('BACKEND="$(', fence)

    def test_every_packaged_resolver_prefers_the_xdg_installation(self):
        resolvers = every_resolver()
        self.assertEqual(len(resolvers), 17)
        with tempfile.TemporaryDirectory() as scratch:
            home = Path(scratch) / "home"
            xdg_backend = install(home / XDG_RECORD_DIR)
            install(home / LIBRARY_RECORD_DIR)
            environment = {
                "HOME": str(home),
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            }
            for resolver in resolvers:
                with self.subTest(resolver=resolver.name):
                    resolution = resolver.resolve(environment)
                    self.assertEqual(
                        resolution.backend, str(xdg_backend), resolution.message
                    )


class ScriptDiagnosticTests(unittest.TestCase):
    """The script's exact diagnostics and exit status.

    The coordinators format their failures through `WorkflowError`, so the
    fragment checks above are all that can hold both surfaces; the script's
    message is the one the assets tell their reader to report "exactly", so it
    is pinned whole here. Run against every bundled copy as well as the source,
    since the copy is what an installed asset runs.
    """

    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name) / "home"
        self.home.mkdir()
        self.xdg_dir = self.home / XDG_RECORD_DIR
        self.library_dir = self.home / LIBRARY_RECORD_DIR
        self.environment = {
            "HOME": str(self.home),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        }
        self.resolvers = script_resolvers()

    def assertRefuses(self, message, environment=None, **fixtures):
        for resolver in self.resolvers:
            with self.subTest(resolver=resolver.name):
                completed = resolver.run(environment or self.environment)
                self.assertEqual(completed.returncode, 1, completed.stderr)
                self.assertEqual(completed.stdout, "")
                self.assertEqual(completed.stderr, message + "\n")

    def test_a_resolved_backend_prints_the_path_alone(self):
        backend = install(self.xdg_dir)
        for resolver in self.resolvers:
            with self.subTest(resolver=resolver.name):
                completed = resolver.run(self.environment)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(completed.stdout, f"{backend}\n")
                self.assertEqual(completed.stderr, "")

    def test_no_install_names_both_records_and_the_repair(self):
        self.assertRefuses(
            f"Canonical issue reviewer was not found at {self.xdg_dir / BACKEND_NAME} "
            f"(consulted {self.xdg_dir / RECORD_NAME} and {self.library_dir / RECORD_NAME}). "
            "Run `python3 tools/install_issue_review.py` from the Kanban checkout, "
            "adding --install-dir if it belongs elsewhere."
        )

    def test_a_record_that_is_not_json_is_unreadable(self):
        self.xdg_dir.mkdir(parents=True)
        (self.xdg_dir / RECORD_NAME).write_text("{not json", encoding="utf-8")
        for resolver in self.resolvers:
            with self.subTest(resolver=resolver.name):
                completed = resolver.run(self.environment)
                self.assertEqual(completed.returncode, 1)
                self.assertEqual(completed.stdout, "")
                prefix = f"The install record at {self.xdg_dir / RECORD_NAME} is unreadable ("
                self.assertTrue(completed.stderr.startswith(prefix), completed.stderr)
                self.assertTrue(completed.stderr.endswith(").\n"), completed.stderr)

    def test_a_directory_at_the_record_is_unreadable(self):
        (self.xdg_dir / RECORD_NAME).mkdir(parents=True)
        for resolver in self.resolvers:
            with self.subTest(resolver=resolver.name):
                completed = resolver.run(self.environment)
                self.assertEqual(completed.returncode, 1)
                self.assertTrue(
                    completed.stderr.startswith(
                        f"The install record at {self.xdg_dir / RECORD_NAME} is unreadable ("
                    ),
                    completed.stderr,
                )

    def test_a_record_that_is_not_an_object_is_refused(self):
        self.xdg_dir.mkdir(parents=True)
        (self.xdg_dir / RECORD_NAME).write_text("[]", encoding="utf-8")
        self.assertRefuses(
            f"The install record at {self.xdg_dir / RECORD_NAME} is not a JSON object."
        )

    def test_a_wrong_typed_or_relative_backend_path_is_refused(self):
        for value in (BACKEND_NAME, 7, None, ["/abs/approve_issues.py"]):
            with self.subTest(backend_path=value):
                self.xdg_dir.mkdir(parents=True, exist_ok=True)
                (self.xdg_dir / RECORD_NAME).write_text(
                    json.dumps({"backend_path": value}), encoding="utf-8"
                )
                self.assertRefuses(
                    f"The install record at {self.xdg_dir / RECORD_NAME} does not name "
                    f"an absolute backend_path: {value!r}."
                )

    def test_a_recorded_backend_that_is_missing_names_only_the_record_read(self):
        backend = install(self.library_dir)
        backend.unlink()
        self.assertRefuses(
            f"Canonical issue reviewer was not found at {backend} "
            f"(consulted {self.library_dir / RECORD_NAME}). "
            "Run `python3 tools/install_issue_review.py` from the Kanban checkout, "
            "adding --install-dir if it belongs elsewhere."
        )

    def test_a_missing_override_is_not_followed_by_a_record(self):
        install(self.xdg_dir)
        missing = self.home / "missing"
        environment = dict(self.environment, KANBAN_ISSUE_REVIEW_INSTALL_DIR=str(missing))
        self.assertRefuses(
            f"Canonical issue reviewer was not found at {missing / BACKEND_NAME} "
            f"(consulted {self.xdg_dir / RECORD_NAME}). "
            "Run `python3 tools/install_issue_review.py` from the Kanban checkout, "
            "adding --install-dir if it belongs elsewhere.",
            environment,
        )

    def test_a_whitespace_only_override_is_ignored(self):
        backend = install(self.xdg_dir)
        environment = dict(self.environment, KANBAN_ISSUE_REVIEW_INSTALL_DIR="  \t ")
        for resolver in self.resolvers:
            with self.subTest(resolver=resolver.name):
                self.assertEqual(resolver.resolve(environment).backend, str(backend))

    def test_an_override_with_a_tilde_expands_through_home(self):
        backend = install(self.home / "chosen")
        environment = dict(self.environment, KANBAN_ISSUE_REVIEW_INSTALL_DIR="~/chosen")
        for resolver in self.resolvers:
            with self.subTest(resolver=resolver.name):
                self.assertEqual(resolver.resolve(environment).backend, str(backend))

    def test_an_argument_is_refused_rather_than_ignored(self):
        completed = subprocess.run(
            [sys.executable, str(REPO_ROOT / HELPER_SOURCE), "--check"],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertEqual(completed.stdout, "")
        self.assertIn("takes no arguments", completed.stderr)


# The shell epilogue every asset's own instruction implies: "If that command
# fails or leaves `$BACKEND` empty, stop and report exactly the message it
# printed." A shell assignment's own status is the substitution's, but the call
# is not the last line of a real session, so both halves of that condition are
# checked here rather than only the exit code.
CALL_EPILOGUE = """
CALL_STATUS=$?
printf "%s\\n" "$BACKEND"
[ -n "$BACKEND" ] || exit 1
exit "$CALL_STATUS"
"""

# The marker a decoy helper prints, so a lookup that wrongly ran a copy inside
# the repository being worked is visible rather than merely failing.
DECOY_OUTPUT = "DECOY-RAN-FROM-THE-WORKED-REPOSITORY"

EXTERNAL_PLUGIN_ROOT_VARIABLES = {
    "grok": "GROK_PLUGIN_ROOT",
    "kimi": "KIMI_PLUGIN_ROOT",
    "google": "GOOGLE_PLUGIN_ROOT",
    "claude-copilot": "CLAUDE_COPILOT_PLUGIN_ROOT",
}


def asset_brand(relative_path):
    prefix = relative_path.split("-plugin/", 1)[0]
    return prefix


def asset_skill(relative_path):
    path = Path(relative_path)
    return path.stem if path.parent.name == "commands" else path.parent.name


class AssetCallsTheBundledScriptTests(unittest.TestCase):
    """Each of the fourteen assets' own call to the script, run from a directory
    that is not the plugin against a fixture of an installed bundle.

    The fence is recovered from the shipped asset, and the fixture holds only
    what that brand's installer would put on disk, so the three properties the
    assets owe are properties of the real lookup: it finds the installed copy,
    it fails when that copy is absent, and a copy sitting in the repository
    being worked never satisfies it.
    """

    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.home = self.root / "home"
        self.worked = self.root / "worked-repository"
        self.worked.mkdir()
        self.backend = install(self.home / XDG_RECORD_DIR)

    def helper_copy(self, relative_path):
        brand = asset_brand(relative_path)
        skill = asset_skill(relative_path)
        if brand == "claude":
            return "claude-plugin/plugins/kanban/scripts/" + HELPER_NAME
        scripts = f"{brand}-plugin/plugins/kanban/skills/{skill}/scripts/"
        return scripts + HELPER_NAME

    def fixture(self, relative_path, *, install_helper=True, install_locator_helper=True):
        """The environment and shell text one asset's call runs with."""
        brand = asset_brand(relative_path)
        skill = asset_skill(relative_path)
        environment = {
            "HOME": str(self.home),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        }
        script = helper_call_fence(relative_path)
        helper = (REPO_ROOT / self.helper_copy(relative_path)).read_bytes()
        if brand == "claude":
            plugin = self.root / "claude-installed"
            scripts = plugin / "scripts"
            environment["CLAUDE_PLUGIN_ROOT"] = str(plugin)
        elif brand == "codex":
            plugin = self.root / "codex-home" / "plugins" / "cache" / "market" / "kanban" / "9.9.9"
            scripts = plugin / "skills" / skill / "scripts"
            environment["CODEX_HOME"] = str(self.root / "codex-home")
        else:
            plugin = self.root / f"{brand}-installed"
            scripts = plugin / "skills" / "solve" / "scripts"
            environment[EXTERNAL_PLUGIN_ROOT_VARIABLES[brand]] = str(plugin)
            locators = [
                fence
                for fence in asset_fences(relative_path)
                if 'TRUSTED_SPEC="$(' in fence
            ]
            self.assertEqual(len(locators), 1, relative_path)
            script = locators[0] + "\n" + script
            if install_locator_helper:
                scripts.mkdir(parents=True)
                (scripts / "trusted_issue_spec.py").write_text("", encoding="utf-8")
        if install_helper:
            scripts.mkdir(parents=True, exist_ok=True)
            (scripts / HELPER_NAME).write_bytes(helper)
        return environment, script + CALL_EPILOGUE

    def plant_decoys(self, relative_path):
        """The helper's name at every place a checkout-relative lookup could
        reach it from the repository being worked."""
        skill = asset_skill(relative_path)
        for directory in (
            self.worked,
            self.worked / "scripts",
            self.worked / "skills" / skill / "scripts",
            self.worked / "skills" / "solve" / "scripts",
            self.worked / "tools",
        ):
            directory.mkdir(parents=True, exist_ok=True)
            (directory / HELPER_NAME).write_text(
                f'print("{DECOY_OUTPUT}")\n', encoding="utf-8"
            )

    def run_call(self, environment, script):
        return subprocess.run(
            ["bash", "-c", script],
            env=environment,
            cwd=self.worked,
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )

    def test_the_installed_script_resolves_the_backend_from_an_unrelated_directory(self):
        for relative_path in MARKDOWN_RESOLVER_ASSETS:
            with self.subTest(asset=relative_path):
                self.plant_decoys(relative_path)
                environment, script = self.fixture(relative_path)
                completed = self.run_call(environment, script)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(completed.stdout.strip(), str(self.backend))
                self.assertNotIn(DECOY_OUTPUT, completed.stdout)

    def test_a_missing_installed_script_fails_and_a_worked_repository_copy_does_not_satisfy_it(self):
        for relative_path in MARKDOWN_RESOLVER_ASSETS:
            with self.subTest(asset=relative_path):
                self.plant_decoys(relative_path)
                environment, script = self.fixture(relative_path, install_helper=False)
                completed = self.run_call(environment, script)
                self.assertNotEqual(completed.returncode, 0, completed.stdout)
                self.assertNotIn(DECOY_OUTPUT, completed.stdout)
                self.assertNotIn(str(self.backend), completed.stdout)
                self.assertIn(HELPER_NAME, completed.stderr)

    def test_an_external_bundle_that_lost_its_trusted_helper_runs_no_resolver(self):
        # The external assets reach the resolver through the lookup that finds
        # the trusted-comment helper beside it. When that lookup finds nothing
        # the call must run nothing, not fall back to the working directory.
        externals = [
            path for path in MARKDOWN_RESOLVER_ASSETS if asset_brand(path) in EXTERNAL_PLUGIN_ROOT_VARIABLES
        ]
        self.assertEqual(len(externals), 4)
        for relative_path in externals:
            with self.subTest(asset=relative_path):
                self.plant_decoys(relative_path)
                environment, script = self.fixture(
                    relative_path, install_helper=False, install_locator_helper=False
                )
                completed = self.run_call(environment, script)
                self.assertNotEqual(completed.returncode, 0, completed.stdout)
                self.assertNotIn(DECOY_OUTPUT, completed.stdout)
                self.assertIn("trusted helper was not found", completed.stderr)


if __name__ == "__main__":
    unittest.main()
