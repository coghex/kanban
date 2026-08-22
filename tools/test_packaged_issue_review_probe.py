"""What the packaged assets actually *do* when they look for the canonical
issue-review backend's discovery record (issue #445).

`tools/test_agent_workflow_contract.py`, `tools/test_claude_plugin.py` and
`tools/test_codex_plugin.py` prove that both record spellings are *present* in
every asset that owes them. Presence is not behavior: an asset could name both
locations and still probe only one, probe them in the wrong order, or read a
dangling symlink as "never installed" and fall through it. These tests drive
each packaged resolver against a redirected `$HOME` and assert which record it
selects, which backend it returns, and what its diagnostic says when it finds
none.

Twelve resolvers owe the same answers -- the ten markdown workflow assets whose
`bash` fence resolves the backend, and both pull-request coordinators -- and
each is exercised through its real surface: the fence by running it in `bash`,
the coordinator by calling its `approver_path()`. Nothing here reimplements the
probe, so these tests cannot agree with a resolver that is wrong.
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

# Every markdown workflow asset whose bash fence resolves the backend. All ten
# carry the same fence, which test_every_markdown_fence_is_the_same_probe pins;
# that is what lets the full case matrix run against one of them.
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
)

REPRESENTATIVE_MARKDOWN_ASSET = "claude-plugin/plugins/kanban/commands/solve.md"

COORDINATORS = (
    ("claude", "claude-plugin/plugins/kanban/scripts/review_pr.py"),
    ("codex", "codex-plugin/plugins/kanban/skills/pr-review/scripts/review_pr.py"),
)

BASH_FENCE_RE = re.compile(r"```bash\n(.*?)\n[ \t]*```", re.DOTALL)


def record_resolver_fence(relative_path):
    """The one bash fence in a packaged markdown asset that resolves the
    backend, recovered from the shipped file rather than restated here."""
    content = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
    fences = [
        match.group(1)
        for match in BASH_FENCE_RE.finditer(content)
        if "KANBAN_ISSUE_REVIEW_INSTALL_DIR" in match.group(1)
    ]
    if len(fences) != 1:
        raise AssertionError(
            f"{relative_path} has {len(fences)} backend-resolving bash fences, "
            "so there is no single probe to exercise"
        )
    return fences[0]


def load_coordinator(name, relative_path):
    """Import a packaged coordinator by file path; neither lives under
    tools/, so neither is importable by name."""
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


# What every asset tells its reader to do with the fence's outcome: "If that
# command fails or leaves `$BACKEND` empty, stop and report exactly the message
# it printed." A shell assignment's own status is the substitution's, but the
# fence is not the last line of a real session, so both halves of that
# condition are checked here rather than only the exit code.
FENCE_EPILOGUE = """
FENCE_STATUS=$?
printf "%s\\n" "$BACKEND"
[ -n "$BACKEND" ] || exit 1
exit "$FENCE_STATUS"
"""


class MarkdownFenceResolver:
    """A packaged markdown asset's fence, run the way a shell runs it."""

    def __init__(self, relative_path):
        self.name = relative_path
        self.script = record_resolver_fence(relative_path) + FENCE_EPILOGUE

    def resolve(self, environment):
        completed = subprocess.run(
            ["bash", "-c", self.script],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
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


def every_resolver():
    """The full twelve."""
    return [
        MarkdownFenceResolver(path) for path in MARKDOWN_RESOLVER_ASSETS
    ] + coordinator_resolvers()


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

    Run against both coordinators and one markdown fence standing in for the
    ten that are byte-identical to it; EveryPackagedResolverProbesTests below
    pins that identity and drives all twelve through the ordering case.
    """

    @classmethod
    def setUpClass(cls):
        cls.resolvers = [
            MarkdownFenceResolver(REPRESENTATIVE_MARKDOWN_ASSET)
        ] + coordinator_resolvers()

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
    """The matrix above runs against one markdown fence. These hold the other
    nine to being the same program, and drive every one of the twelve through
    the ordering case so none is covered by identity alone."""

    def test_every_markdown_fence_is_the_same_probe(self):
        fences = {
            relative_path: record_resolver_fence(relative_path)
            for relative_path in MARKDOWN_RESOLVER_ASSETS
        }
        self.assertEqual(len(fences), 10)
        reference = fences[REPRESENTATIVE_MARKDOWN_ASSET]
        for relative_path, fence in fences.items():
            self.assertEqual(fence, reference, relative_path)

    def test_every_packaged_resolver_prefers_the_xdg_installation(self):
        resolvers = every_resolver()
        self.assertEqual(len(resolvers), 12)
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


if __name__ == "__main__":
    unittest.main()
