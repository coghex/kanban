#!/usr/bin/env python3
"""Behavioral coverage for the vendored janitor census (issue #574).

The census is the janitor workflow's whole read side, and until this issue it
was an untracked personal script: nothing in a pull request could change it and
nothing could verify it. The two shipped copies are what this module drives.

Three properties get the weight here, because each is a place where a wrong
answer reads as a *clean* one and the workflow's next step is a deletion:

- The drainer controller is resolved through `kanban_config.drainer_install_dir()`
  rather than spelled. The retired spelling found nothing on a Linux host and
  ignored both `KANBAN_DRAINER_INSTALL_DIR` and an `--install-dir` install, so a
  relocated drainer looked like no drainer.
- The retain ledger is read from the repository's *common* directory, so every
  linked worktree reads the one ledger, and an unreadable ledger reports `null`
  rather than an empty list. Reporting it empty would tell the janitor that
  nothing is retained.
- The optional test-coordinator probe stays fail-soft: a host with no
  coordinator is the ordinary case, not an error.
- Issue #706's project-review attempt inventory asks the liveness adapter for
  every attempt's state and keeps two answers apart: whether the attempt is
  *over*, which is what keeps a running invocation's directory out of the
  report, and whether it is provably *idle*, which is the only answer a
  removal may be offered for. An attempt the adapter no longer knows is over
  and never idle, and the whole hazard is that collapsing the two reads as a
  green light to delete a checkout.

Only the Claude copy is imported for behavior; `tools/test_document_workflow_contract.py`
and the byte-equality check below are what make one execution cover both.
"""

from __future__ import annotations

import contextlib
import importlib.util
import json
import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
CENSUS_COPIES = (
    REPO_ROOT / "claude-plugin" / "plugins" / "kanban" / "scripts" / "census.py",
    REPO_ROOT
    / "codex-plugin"
    / "plugins"
    / "kanban"
    / "skills"
    / "janitor"
    / "scripts"
    / "census.py",
)
CENSUS_PATH = CENSUS_COPIES[0]
CONTROLLER_NAME = "drain_prs_service.py"
SUBPROCESS_TIMEOUT_SECONDS = 120

# What a repository census always reports. Pinned as an exact set rather than a
# handful of `assertIn`s: a collection that silently stopped being produced is
# the failure this document shape exists to prevent, and the janitor reads the
# absence of a signal as the absence of the problem it names.
CENSUS_KEYS = {
    "schema",
    "repo_root",
    "default_branch",
    "default_head",
    "remote_default_head",
    "default_divergence",
    "worktrees",
    "local_branches",
    "remote_heads",
    "stale_tracking_refs",
    "stashes",
    "configured_remotes",
    "tracking_refs_for_missing_remotes",
    "other_remote_tracking_refs",
    "retain_ledger",
    "drainer",
    "drainer_untracked_holdings",
    "test_coordinator",
    "project_review_attempts",
    "github",
    "signals",
    "warnings",
    "counts",
}

# A controller that answers `--json status` with a document shaped like the
# real one's, tagged so a test can tell which install answered.
FAKE_CONTROLLER = """\
import json
print(json.dumps({
    "state": %(tag)r, "launchd_loaded": True, "operation": None,
    "last_activity": None, "open_incidents": [], "cleanup_obligations": [],
    "kept_autostash_anchors": [], "drainer_stashes": [],
}))
"""

FAKE_COORDINATOR = """\
import json, sys
if "proposal-list" in sys.argv:
    print(json.dumps({"proposals": [
        {"proposal_id": "p1", "test_id": "t1", "status": "open",
         "created_at": "2026-01-01T00:00:00Z"}]}))
else:
    print(json.dumps({"paths": {"base_worktree": "/nowhere"}, "runs": [
        {"run_id": "r1", "test_id": "t1", "status": "running",
         "heartbeat_at": "2026-01-01T00:00:00Z", "worktree_path": "/nowhere"}]}))
"""

LEDGER_ITEM = {
    "id": "keep-docs-wip",
    "target": "branch docs-wip",
    "disposition": "retain",
    "reason": "durable authoring worktree",
    "review_when": "the docs arc completes",
}


def load_census():
    """The shipped Claude copy, imported by path.

    It lives under `claude-plugin/`, never on `sys.path`, and it loads
    `kanban_config.py` from beside itself -- so importing the tracked bundle
    file is what proves the bundle is self-contained.
    """
    name = "_kanban_janitor_census_under_test"
    spec = importlib.util.spec_from_file_location(name, CENSUS_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


census = load_census()


def git(cwd: Path, *args: str) -> str:
    done = subprocess.run(
        ["git", *args],
        cwd=cwd,
        text=True,
        capture_output=True,
        timeout=SUBPROCESS_TIMEOUT_SECONDS,
    )
    if done.returncode != 0:
        raise AssertionError(f"git {' '.join(args)}: {done.stderr or done.stdout}")
    return done.stdout


class CensusFixture(unittest.TestCase):
    """A real repository with an `origin`, because the census reads both."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        origin = self.root / "origin.git"
        git(self.root, "init", "--bare", "--initial-branch=master", str(origin))
        self.repo = self.root / "work"
        git(self.root, "clone", str(origin), str(self.repo))
        git(self.repo, "config", "user.email", "census@example.invalid")
        git(self.repo, "config", "user.name", "Census Fixture")
        (self.repo / "README.md").write_text("fixture\n", encoding="utf-8")
        git(self.repo, "add", "README.md")
        git(self.repo, "commit", "-m", "initial")
        git(self.repo, "push", "-u", "origin", "master")
        self.common_dir = Path(
            git(
                self.repo, "rev-parse", "--path-format=absolute", "--git-common-dir"
            ).strip()
        )

    @contextlib.contextmanager
    def pinned_environment(self, **overrides):
        """Every input the census's resolvers read, pinned for one block.

        `HOME` is redirected so nothing can reach the developer's own install,
        and `KANBAN_DRAINER_INSTALL_DIR` is removed unless a test names it, so
        a test that does not set an override is testing the unset case rather
        than whatever the ambient environment happened to hold.
        `mock.patch.dict` restores the whole mapping on exit, the removal
        included.
        """
        environment = {
            "HOME": str(self.home),
            "XDG_DATA_HOME": str(self.root / "unoccupied-xdg"),
            "CODEX_HOME": str(self.root / "absent-codex"),
        }
        environment.update(overrides)
        with mock.patch.dict(os.environ, environment):
            if "KANBAN_DRAINER_INSTALL_DIR" not in overrides:
                os.environ.pop("KANBAN_DRAINER_INSTALL_DIR", None)
            yield

    def run_census(self, cwd=None, **overrides):
        with self.pinned_environment(**overrides):
            return census.census(cwd or self.repo, fetch=False, local_only=True)

    def install_controller(self, directory: Path, tag: str, *, record: bool = True):
        directory.mkdir(parents=True, exist_ok=True)
        (directory / CONTROLLER_NAME).write_text(
            FAKE_CONTROLLER % {"tag": tag}, encoding="utf-8"
        )
        if record:
            (directory / "config.json").write_text("{}\n", encoding="utf-8")
        return directory

    def write_ledger(self, document):
        path = self.common_dir / census.RETAIN_LEDGER
        if isinstance(document, str):
            path.write_text(document, encoding="utf-8")
        else:
            path.write_text(json.dumps(document), encoding="utf-8")
        self.addCleanup(path.unlink, missing_ok=True)
        return path


class ShippedCopyTests(unittest.TestCase):
    def test_both_shipped_copies_are_byte_identical(self):
        claude, codex = (path.read_bytes() for path in CENSUS_COPIES)
        self.assertEqual(
            claude,
            codex,
            "the two bundled censuses have diverged; they are one program, "
            f"not a fork. Repair: cp {CENSUS_COPIES[0].relative_to(REPO_ROOT)} "
            f"{CENSUS_COPIES[1].relative_to(REPO_ROOT)}",
        )

    def test_the_self_test_passes_from_both_shipped_locations(self):
        # Run from each bundle rather than once from a chosen one: the
        # self-test resolves `kanban_config.py` from beside itself, so passing
        # is also the assertion that each bundle shipped that sibling.
        for path in CENSUS_COPIES:
            with self.subTest(copy=str(path.relative_to(REPO_ROOT))):
                done = subprocess.run(
                    [sys.executable, str(path), "--self-test"],
                    text=True,
                    capture_output=True,
                    timeout=SUBPROCESS_TIMEOUT_SECONDS,
                )
                self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
                self.assertIn("census self-test: PASS", done.stdout)


class CensusDocumentTests(CensusFixture):
    def test_the_document_is_a_janitor_census_v1_with_every_collection(self):
        document = self.run_census()
        self.assertEqual(document["schema"], "janitor-census/v1")
        self.assertEqual(set(document), CENSUS_KEYS)
        self.assertEqual(document["repo_root"], str(self.repo.resolve()))
        self.assertEqual(document["default_branch"], "master")
        self.assertEqual(document["warnings"], [])
        self.assertEqual([row["path"] for row in document["worktrees"]],
                         [str(self.repo.resolve())])
        self.assertEqual([row["name"] for row in document["local_branches"]],
                         ["master"])
        self.assertEqual(document["stashes"], [])
        self.assertEqual(document["configured_remotes"], ["origin"])
        self.assertEqual(document["counts"]["worktrees"], 1)
        self.assertEqual(document["counts"]["stashes"], 0)

    def test_the_collections_track_what_git_independently_reports(self):
        # The demonstration the issue asks for, as an assertion: each
        # collection is compared against the plumbing that owns it, so a
        # collection that silently stopped being read fails here.
        (self.repo / "scratch.txt").write_text("dirty\n", encoding="utf-8")
        git(self.repo, "stash", "push", "--include-untracked", "-m", "fixture")
        git(self.repo, "branch", "issue-1-example")
        document = self.run_census()
        self.assertEqual(
            {row["path"] for row in document["worktrees"]},
            {line.split()[0] for line in git(self.repo, "worktree", "list").splitlines()},
        )
        self.assertEqual(
            {row["name"] for row in document["local_branches"]},
            set(git(self.repo, "branch", "--format=%(refname:short)").split()),
        )
        self.assertEqual(
            len(document["stashes"]), len(git(self.repo, "stash", "list").splitlines())
        )
        self.assertEqual(document["counts"]["stashes"], 1)


class DrainerResolutionTests(CensusFixture):
    def test_an_override_at_an_absent_install_reports_no_drainer(self):
        document = self.run_census(
            KANBAN_DRAINER_INSTALL_DIR=str(self.root / "absent-drainer")
        )
        self.assertEqual(document["drainer"], {"available": False})

    def test_an_override_at_a_relocated_install_reports_that_install(self):
        install = self.install_controller(self.root / "relocated", "relocated")
        document = self.run_census(KANBAN_DRAINER_INSTALL_DIR=str(install))
        self.assertEqual(document["drainer"]["available"], True)
        self.assertEqual(document["drainer"].get("state"), "relocated")
        self.assertEqual(document["drainer"]["open_incidents"], [])

    def test_an_xdg_install_is_found_on_a_host_with_no_library_tree(self):
        # The Linux shape the retired hardcoded path could not reach at all.
        xdg = self.root / "xdg"
        self.install_controller(xdg / "kanban" / "pr-drainer", "xdg")
        document = self.run_census(XDG_DATA_HOME=str(xdg))
        self.assertEqual(document["drainer"].get("state"), "xdg")

    def test_the_resolver_wins_over_the_retired_hardcoded_macos_path(self):
        # The discriminating case: BOTH locations hold an installation, and
        # `installed_drainer_dir()` prefers the XDG one. A census that still
        # spelled `~/Library/Application Support/kanban/pr-drainer` would
        # report the other install, so this fails against the retired code and
        # passes against the resolver.
        xdg = self.root / "xdg"
        self.install_controller(xdg / "kanban" / "pr-drainer", "xdg")
        self.install_controller(
            self.home / "Library" / "Application Support" / "kanban" / "pr-drainer",
            "macos",
        )
        document = self.run_census(XDG_DATA_HOME=str(xdg))
        self.assertEqual(document["drainer"].get("state"), "xdg")

    def test_an_unloadable_configuration_module_is_reported_not_raised(self):
        # The bundle-incomplete case. A census is a read, so it reports what it
        # could not resolve instead of exiting; the `error` key is what keeps
        # that distinguishable from "this host has no drainer", which is the
        # collapse a janitor would act on.
        def unloadable():
            raise census.CensusError("the configuration module ... vanished")

        with mock.patch.object(census, "kanban_config_module", unloadable):
            document = self.run_census()
        self.assertEqual(document["drainer"]["available"], False)
        self.assertIn("configuration module", document["drainer"]["error"])

    def test_the_controller_is_whatever_kanban_config_resolves(self):
        # Bound to the call site rather than restating the precedence: the one
        # spelling of "where is the drainer" is that function, and this is what
        # keeps the census from growing a second one.
        configuration = census.kanban_config_module()
        install = self.install_controller(self.root / "relocated", "relocated")
        for label, overrides in (
            ("override", {"KANBAN_DRAINER_INSTALL_DIR": str(install)}),
            ("no override", {}),
        ):
            with self.subTest(shape=label):
                with self.pinned_environment(**overrides):
                    self.assertEqual(
                        census.drainer_controller(),
                        configuration.drainer_install_dir() / CONTROLLER_NAME,
                    )


class TestCoordinatorProbeTests(CensusFixture):
    def test_an_absent_coordinator_is_reported_rather_than_raised(self):
        document = self.run_census(CODEX_HOME=str(self.root / "no-such-codex"))
        self.assertEqual(document["test_coordinator"], {"available": False})
        self.assertEqual(document["warnings"], [])

    def test_a_present_coordinator_is_actually_consulted(self):
        # The control the absent case cannot be: `available: False` would also
        # be what a deleted probe reported.
        codex_home = self.root / "codex"
        scripts = codex_home / "skills" / "test" / "scripts"
        scripts.mkdir(parents=True)
        (scripts / "test_coordinator.py").write_text(FAKE_COORDINATOR, encoding="utf-8")
        registry = self.common_dir / "codex-test" / "registry.json"
        registry.parent.mkdir(parents=True, exist_ok=True)
        registry.write_text("{}\n", encoding="utf-8")
        self.addCleanup(registry.unlink, missing_ok=True)

        document = self.run_census(CODEX_HOME=str(codex_home))
        state = document["test_coordinator"]
        self.assertEqual(state["available"], True)
        self.assertEqual(state["initialized"], True)
        self.assertEqual([run["run_id"] for run in state["active_runs"]], ["r1"])
        self.assertEqual(
            [row["proposal_id"] for row in state["active_proposals"]], ["p1"]
        )


class RetainLedgerTests(CensusFixture):
    def test_a_repository_with_no_ledger_reports_an_empty_list(self):
        document = self.run_census()
        self.assertEqual(document["retain_ledger"], {"present": False, "items": []})
        self.assertEqual(document["counts"]["retained_items"], 0)

    def test_a_valid_ledger_with_no_entries_reports_an_empty_list(self):
        self.write_ledger({"schema": "janitor-retain/v1", "items": []})
        document = self.run_census()
        self.assertEqual(document["retain_ledger"]["present"], True)
        self.assertEqual(document["retain_ledger"]["items"], [])
        self.assertEqual(document["counts"]["retained_items"], 0)
        self.assertEqual(document["warnings"], [])

    def test_an_unreadable_ledger_reports_null_rather_than_empty(self):
        # The regression that matters: a ledger the census could not read is
        # not a ledger with nothing in it. Reported as empty, the janitor would
        # propose deleting everything the ledger was protecting.
        self.write_ledger("this is not JSON")
        document = self.run_census()
        self.assertIsNone(document["retain_ledger"]["items"])
        self.assertIsNone(document["counts"]["retained_items"])
        self.assertIn("error", document["retain_ledger"])
        self.assertEqual(len(document["warnings"]), 1)
        self.assertIn("retain ledger unreadable", document["warnings"][0])

    def test_a_ledger_failing_validation_is_unreadable_too(self):
        # Not only malformed JSON: a well-formed document that is not a
        # `janitor-retain/v1` ledger is equally undetermined.
        self.write_ledger({"schema": "janitor-retain/v2", "items": []})
        document = self.run_census()
        self.assertIsNone(document["retain_ledger"]["items"])
        self.assertIsNone(document["counts"]["retained_items"])

    def test_a_ledger_symlink_is_unreadable_rather_than_absent(self):
        # `Path.exists()` follows the link, so a dangling `janitor-retain.json`
        # answered "absent" -- `items: []` -- for an entry the operator can see
        # in the directory listing. Presence is a question about the directory
        # entry, and an entry that cannot be followed is the unreadable case.
        # The resolvable link is here too, because the rule this file has
        # always applied is that a ledger must be a regular, non-symlink file:
        # both spellings must land on `None`, and the second is what proves the
        # first is not passing merely because the target was missing.
        ledger = self.common_dir / census.RETAIN_LEDGER
        target = self.root / "elsewhere.json"
        target.write_text(
            json.dumps({"schema": "janitor-retain/v1", "items": [LEDGER_ITEM]}),
            encoding="utf-8",
        )
        for label, destination in (
            ("dangling", self.root / "no-such-ledger.json"),
            ("resolvable", target),
        ):
            with self.subTest(link=label):
                ledger.symlink_to(destination)
                self.addCleanup(ledger.unlink, missing_ok=True)
                try:
                    document = self.run_census()
                finally:
                    ledger.unlink()
                self.assertEqual(document["retain_ledger"]["present"], True)
                self.assertIsNone(document["retain_ledger"]["items"])
                self.assertIsNone(document["counts"]["retained_items"])
                self.assertEqual(len(document["warnings"]), 1)
                self.assertIn("retain ledger unreadable", document["warnings"][0])

    def test_the_ledger_is_read_from_the_common_directory(self):
        # Written once, read from a *different* linked worktree of the same
        # repository. A `--git-dir` read would find nothing there.
        path = self.write_ledger(
            {"schema": "janitor-retain/v1", "items": [LEDGER_ITEM]}
        )
        linked = self.root / "linked"
        git(self.repo, "worktree", "add", "-b", "issue-9-linked", str(linked))
        self.addCleanup(
            git, self.repo, "worktree", "remove", "--force", str(linked)
        )
        self.assertNotEqual(
            Path(git(linked, "rev-parse", "--path-format=absolute", "--git-dir").strip()),
            self.common_dir,
            "the fixture's linked worktree shares the primary git directory, "
            "so this proves nothing",
        )

        document = self.run_census(cwd=linked)
        self.assertEqual(document["retain_ledger"].get("path"), str(path))
        self.assertEqual(document["retain_ledger"]["items"], [LEDGER_ITEM])
        self.assertEqual(document["counts"]["retained_items"], 1)


class FetchDoesNotPruneTests(CensusFixture):
    """`--fetch` refreshes `origin` and removes nothing.

    The janitor workflow this program feeds treats a stale origin-tracking ref
    as an anomaly the user approves individually, and deletes it one ref at a
    time with the value the report recorded. A refresh that pruned would delete
    every one of them during the read-only pass, before any was reported --
    which `fetch.prune=true` is enough to cause, since it is an ordinary
    configuration and not an exotic one. The program therefore passes
    `--no-prune` rather than leaving the behavior to the host.
    """

    def stale_tracking_refs(self):
        listing = git(self.repo, "for-each-ref", "--format=%(refname)", "refs/remotes")
        return sorted(line for line in listing.splitlines() if line.strip())

    def make_a_stale_tracking_ref(self) -> str:
        """A `refs/remotes/origin/*` ref whose branch is gone from origin.

        The branch is removed in the origin repository rather than through a
        `push --delete` from this clone, because that is how a tracking ref
        actually goes stale: somebody else deleted the branch, and this clone
        still carries the ref. Deleting it through this clone's own push would
        remove the tracking ref along with it and leave nothing to test.
        """
        git(self.repo, "checkout", "-q", "-b", "issue-4-gone")
        git(self.repo, "push", "-q", "-u", "origin", "issue-4-gone")
        git(self.repo, "checkout", "-q", "master")
        git(self.root / "origin.git", "branch", "-D", "issue-4-gone")
        ref = "refs/remotes/origin/issue-4-gone"
        self.assertIn(ref, self.stale_tracking_refs())
        return ref

    def fetch(self, **config):
        for key, value in config.items():
            git(self.repo, "config", key, value)
        with self.pinned_environment():
            return census.census(self.repo, fetch=True, local_only=True)

    def test_a_pruning_configuration_does_not_delete_a_stale_ref(self):
        ref = self.make_a_stale_tracking_ref()
        document = self.fetch(**{"fetch.prune": "true"})
        self.assertIn(ref, self.stale_tracking_refs())
        # And it is still reported, which is the point: the workflow's
        # per-item deletion gate has something to approve.
        self.assertIn(
            ref, [row["ref"] for row in document["stale_tracking_refs"]]
        )

    def test_the_control_shows_git_would_have_pruned_it(self):
        # Non-vacuity: without `--no-prune`, this exact configuration removes
        # the ref. Driven through git rather than through a second census, so
        # the control measures the tool's behavior and not this module's.
        ref = self.make_a_stale_tracking_ref()
        git(self.repo, "config", "fetch.prune", "true")
        git(self.repo, "fetch", "origin")
        self.assertNotIn(ref, self.stale_tracking_refs())

    def test_the_fetch_is_spelled_with_no_prune_in_both_shipped_copies(self):
        for path in CENSUS_COPIES:
            with self.subTest(copy=str(path)):
                source = path.read_text(encoding="utf-8")
                self.assertIn('"fetch", "--no-prune", "origin"', source)
                self.assertNotIn('"fetch", "origin"', source)


# Issue #706's attempt census. `project-review` (issue #684) gives every
# invocation one directory named for the liveness attempt that owns it, and a
# cancellation is the exit that cannot remove its own; the adapter issue #687
# ships is the only thing entitled to say whether one of those directories is
# still in use.
LIVENESS_ADAPTER = "project_review_liveness.py"
LIVENESS_LEDGER = "project_review_ledger.py"
CENSUS_CONFIG_MODULE = "kanban_config.py"
BUNDLE_SOURCE = CENSUS_PATH.parent
ATTEMPT_RECORD_KEYS = (
    "attempt", "runtime", "runtime_version", "session_id", "invocation_id",
    "repo", "silence_seconds", "registered_at", "keeper",
)

# Four attempt ids for the acceptance scenario, plus the fifth that is over and
# still has a command running in it. Valid 32-hex tokens, because the adapter
# refuses anything else before it reads a record.
ATTEMPTS = {
    "live": "a" * 32,
    "ended": "b" * 32,
    "killed": "c" * 32,
    "pruned": "d" * 32,
    "busy": "e" * 32,
}

# A stand-in adapter, for the malformed answers the real one never gives. The
# real adapter drives every state below that it can actually produce; this
# drives the ones that are about the census's own reading of a `status`
# document -- a body that is not JSON, a state outside the vocabulary, a
# keeper standing outside it, a missing launch inventory, and a refusal that is
# not `attempt-unknown`.
STUB_ADAPTER = """\
import sys
mode = %(mode)r
if mode == "not-json":
    print("this is not a document")
elif mode == "not-an-object":
    print("[]")
elif mode == "unknown-state":
    print('{"status": "winding-down", "keeper_standing": "gone", '
          '"unfinished_launches": []}')
elif mode == "unknown-standing":
    print('{"status": "active", "keeper_standing": "probably-fine", '
          '"unfinished_launches": []}')
elif mode == "no-launch-inventory":
    print('{"status": "ended", "keeper_standing": "gone"}')
elif mode == "other-refusal":
    print("project-review liveness: refused (attempt-invalid): no", file=sys.stderr)
    raise SystemExit(2)
elif mode == "bare-failure":
    raise SystemExit(3)
"""


def reaped_pid() -> int:
    """A pid whose process has exited and been waited on, so it is `gone`.

    Reaped rather than merely exited: the ledger's own standing test reports an
    unreaped zombie as gone too, and a fixture that relied on that would be
    asserting the platform's zombie reading rather than this census's.
    """
    child = subprocess.Popen([sys.executable, "-c", ""])
    child.wait()
    return child.pid


class AttemptFixture(CensusFixture):
    """A repository with real `project-review` attempt records in it.

    The records are the adapter's own -- `attempt.json`, `ended.json`, and the
    launch records under `launches/` -- and every classification below is read
    back through `project_review_liveness.py status`, which is the one
    interface issue #706 is entitled to read. Nothing here reimplements the
    adapter's judgement.
    """

    def setUp(self):
        super().setUp()
        self.host = socket.gethostname()
        self.live_pid = os.getpid()
        self.gone_pid = reaped_pid()
        self.runtime = self.common_dir / census.PROJECT_REVIEW_RUNTIME
        self.records = (
            self.common_dir / "kanban-project-review" / "liveness" / "attempts"
        )

    def write_json(self, path: Path, value) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")

    def attempt_directory(self, attempt: str) -> Path:
        directory = self.runtime / attempt
        directory.mkdir(parents=True, exist_ok=True)
        # The inventory step 1 of that workflow assembles, so the directory has
        # a measurable footprint that is not the pinned checkout's.
        (directory / "inventory.json").write_text("[]\n", encoding="utf-8")
        return directory

    def register(self, attempt: str, keeper_pid: int | None) -> Path:
        self.write_json(
            self.records / attempt / "attempt.json",
            {
                "attempt": attempt,
                "runtime": "claude",
                "runtime_version": "2.1.276",
                "session_id": "session",
                "invocation_id": "invocation",
                "repo": "owner/name",
                "silence_seconds": 600,
                "registered_at": 0,
                "keeper": (
                    None if keeper_pid is None
                    else {"host": self.host, "pid": keeper_pid}
                ),
            },
        )
        return self.attempt_directory(attempt)

    def end(self, attempt: str) -> None:
        self.write_json(
            self.records / attempt / "ended.json",
            {"attempt": attempt, "reason": "completed", "at": 1},
        )

    def launch(self, attempt: str, label: str, command_pid: int) -> None:
        self.write_json(
            self.records / attempt / "launches" / f"{label}.wrapper.json",
            {"label": label, "host": self.host, "pid": self.gone_pid,
             "command_pid": command_pid},
        )

    def pin_a_worktree(self, attempt: str) -> Path:
        tree = self.runtime / attempt / "tree"
        git(self.repo, "worktree", "add", "--detach", str(tree), "HEAD")
        return tree

    def plant_the_acceptance_scenario(self) -> None:
        """The four the issue names, plus the fifth its acceptance adds."""
        self.register(ATTEMPTS["live"], self.live_pid)
        self.register(ATTEMPTS["ended"], self.gone_pid)
        self.end(ATTEMPTS["ended"])
        # A keeper killed outright writes no ended record, so this one still
        # reads `active` -- the case that reading `active` alone would strand.
        self.register(ATTEMPTS["killed"], self.gone_pid)
        # And this one has no records at all, which is what an attempt pruned
        # after seven days looks like to the adapter.
        self.attempt_directory(ATTEMPTS["pruned"])
        self.register(ATTEMPTS["busy"], self.gone_pid)
        self.end(ATTEMPTS["busy"])
        self.launch(ATTEMPTS["busy"], "cabal-test", self.live_pid)

    def attempts(self, **overrides) -> dict[str, dict]:
        document = self.run_census(**overrides)
        self.document = document
        rows = document["project_review_attempts"]["attempts"]
        self.assertIsNotNone(rows, document["warnings"])
        by_id = {ATTEMPTS.get(name, name): name for name in ATTEMPTS}
        return {by_id.get(row["attempt"], row["attempt"]): row for row in rows}

    def synthetic_bundle(self, layout: str, *, adapter: str | None = None) -> Path:
        """A copy of this census in one of the two shipped bundle layouts.

        Copied rather than imported in place, because the whole question is
        where the census looks for the adapter *relative to itself*: the Claude
        bundle has one shared `scripts/` directory and the Codex bundle gives
        every skill its own, so the tracked tree can only ever exercise one of
        the two candidate paths per copy.
        """
        bundle = self.root / f"bundle-{layout}-{secrets.token_hex(4)}"
        if layout == "codex":
            scripts = bundle / "skills" / "janitor" / "scripts"
            adapter_dir = bundle / "skills" / "project-review" / "scripts"
        else:
            scripts = bundle / "scripts"
            adapter_dir = scripts
        scripts.mkdir(parents=True)
        for name in ("census.py", CENSUS_CONFIG_MODULE):
            shutil.copy(BUNDLE_SOURCE / name, scripts / name)
        if adapter is None:
            adapter_dir.mkdir(parents=True, exist_ok=True)
            for name in (LIVENESS_ADAPTER, LIVENESS_LEDGER):
                shutil.copy(BUNDLE_SOURCE / name, adapter_dir / name)
        elif adapter != "absent":
            adapter_dir.mkdir(parents=True, exist_ok=True)
            (adapter_dir / LIVENESS_ADAPTER).write_text(
                STUB_ADAPTER % {"mode": adapter}, encoding="utf-8"
            )
        return scripts / "census.py"

    def census_through(self, program: Path) -> dict:
        with self.pinned_environment():
            done = subprocess.run(
                [sys.executable, str(program), "--repo", str(self.repo),
                 "--local-only"],
                text=True,
                capture_output=True,
                timeout=SUBPROCESS_TIMEOUT_SECONDS,
            )
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return json.loads(done.stdout)


class AttemptInventoryTests(AttemptFixture):
    def test_a_repository_that_never_ran_project_review_reports_nothing(self):
        # Requirement 6. Absent is an empty list, never an anomaly and never a
        # `null`: there is nothing to diagnose about a directory that was never
        # created.
        document = self.run_census()
        self.assertEqual(
            document["project_review_attempts"],
            {"root": str(self.runtime), "present": False, "adapter": None,
             "attempts": []},
        )
        self.assertEqual(document["warnings"], [])
        self.assertEqual(document["counts"]["project_review_attempts"], 0)
        self.assertEqual(
            document["counts"]["cleanable_project_review_attempts"], 0
        )

    def test_an_empty_attempt_root_reports_nothing(self):
        self.runtime.mkdir(parents=True)
        document = self.run_census()
        self.assertEqual(document["project_review_attempts"]["present"], True)
        self.assertEqual(document["project_review_attempts"]["attempts"], [])
        self.assertEqual(document["warnings"], [])

    def test_exactly_the_three_over_attempts_are_reported_over(self):
        # The acceptance scenario. Three of the four are over; the fourth is a
        # running invocation and is left alone however old its directory is.
        self.plant_the_acceptance_scenario()
        rows = self.attempts()
        self.assertEqual(set(rows), set(ATTEMPTS))
        self.assertEqual(
            {name for name, row in rows.items() if row["over"]},
            {"ended", "killed", "pruned", "busy"},
        )
        self.assertIs(rows["live"]["over"], False)
        self.assertEqual(rows["live"]["state"], "active")
        self.assertEqual(rows["live"]["keeper_standing"], "live")
        self.assertEqual(
            rows["live"]["retention_reasons"],
            ["a live keeper is holding this attempt"],
        )

    def test_only_the_provably_idle_attempts_are_cleanable(self):
        # The distinction issue #706's review insists on. `ended` and the
        # killed keeper are established; the pruned attempt and the busy one
        # are over and are offered nothing.
        self.plant_the_acceptance_scenario()
        rows = self.attempts()
        self.assertEqual(
            {name for name, row in rows.items() if row["cleanable"]},
            {"ended", "killed"},
        )
        self.assertEqual(rows["ended"]["state"], "ended")
        self.assertEqual(rows["killed"]["state"], "active")
        self.assertEqual(rows["killed"]["keeper_standing"], "gone")
        self.assertEqual(rows["ended"]["retention_reasons"], [])
        self.assertEqual(self.document["counts"]["project_review_attempts"], 5)
        self.assertEqual(
            self.document["counts"]["cleanable_project_review_attempts"], 2
        )

    def test_a_pruned_attempt_is_over_and_never_cleanable(self):
        self.plant_the_acceptance_scenario()
        row = self.attempts()["pruned"]
        self.assertEqual(row["state"], "unknown")
        self.assertEqual(row["refusal"], "attempt-unknown")
        self.assertIs(row["over"], True)
        self.assertIs(row["cleanable"], False)
        self.assertEqual(
            row["retention_reasons"],
            ["the adapter no longer knows this attempt, so neither its keeper "
             "nor its launches can be established"],
        )

    def test_a_surviving_command_names_itself_and_blocks_the_removal(self):
        # Requirement 3, and the labels the report has to carry. The wrapper is
        # gone and its command is not, which is exactly what a `SIGKILL`ed
        # wrapper leaves behind.
        self.plant_the_acceptance_scenario()
        row = self.attempts()["busy"]
        self.assertEqual(row["state"], "ended")
        self.assertEqual(row["unfinished_launches"], ["cabal-test"])
        self.assertIs(row["over"], True)
        self.assertIs(row["cleanable"], False)
        self.assertEqual(
            row["retention_reasons"],
            ["wrapped launches are still running: cabal-test"],
        )

    def test_a_keeper_that_cannot_be_verified_is_not_gone(self):
        # A keeper recorded on another host cannot be looked up from here, so
        # the adapter answers `unverifiable`. Over, because it is not live;
        # never cleanable, because that is not proof of anything.
        attempt = ATTEMPTS["killed"]
        self.write_json(
            self.records / attempt / "attempt.json",
            {
                "attempt": attempt, "runtime": "claude",
                "runtime_version": "2.1.276", "session_id": "session",
                "invocation_id": "invocation", "repo": "owner/name",
                "silence_seconds": 600, "registered_at": 0,
                "keeper": {"host": self.host + "-elsewhere", "pid": 1},
            },
        )
        self.attempt_directory(attempt)
        row = self.attempts()["killed"]
        self.assertEqual(row["keeper_standing"], "unverifiable")
        self.assertIs(row["over"], True)
        self.assertIs(row["cleanable"], False)
        self.assertEqual(
            row["retention_reasons"],
            ["the keeper's standing is unverifiable rather than gone"],
        )

    def test_every_attempt_carries_its_id_age_and_footprint(self):
        # Requirement 1's four facts. The footprint counts the pinned checkout
        # too, because that is what the directory actually costs.
        self.plant_the_acceptance_scenario()
        self.pin_a_worktree(ATTEMPTS["ended"])
        rows = self.attempts()
        for name, row in sorted(rows.items()):
            with self.subTest(attempt=name):
                self.assertEqual(row["attempt"], ATTEMPTS[name])
                self.assertEqual(row["path"], str(self.runtime / ATTEMPTS[name]))
                self.assertGreaterEqual(row["age_seconds"], 0)
                self.assertIn("+00:00", row["modified"])
                self.assertGreaterEqual(row["files"], 1)
                self.assertGreater(row["bytes"], 0)
                self.assertNotIn("measurement_error", row)
        self.assertGreater(rows["ended"]["files"], rows["killed"]["files"])

    def test_a_pinned_attempt_worktree_is_attributed_to_its_attempt(self):
        # Otherwise a live invocation's detached checkout reads as an
        # unexplained worktree, and the workflow's ordinary worktree-removal
        # gate would be the one applied to it.
        self.plant_the_acceptance_scenario()
        tree = self.pin_a_worktree(ATTEMPTS["live"])
        rows = self.attempts()
        self.assertEqual(rows["live"]["tree"],
                         {"path": str(tree), "present": True, "registered": True})
        self.assertEqual(rows["ended"]["tree"]["present"], False)
        self.assertEqual(rows["ended"]["tree"]["registered"], False)
        attributed = {
            wt["path"]: wt.get("project_review_attempt")
            for wt in self.document["worktrees"]
        }
        self.assertEqual(attributed.get(str(tree)), ATTEMPTS["live"])
        self.assertIsNone(attributed[str(self.repo.resolve())])

    def test_a_state_that_changes_is_reread_rather_than_remembered(self):
        # The revalidation the workflow does immediately before an approved
        # removal: the same directory answers differently once its keeper is
        # gone, because the answer comes from the adapter every time.
        self.register(ATTEMPTS["live"], self.live_pid)
        self.assertIs(self.attempts()["live"]["over"], False)
        self.end(ATTEMPTS["live"])
        after = self.attempts()["live"]
        self.assertIs(after["over"], True)
        self.assertIs(after["cleanable"], True)


class AttemptAdapterResolutionTests(AttemptFixture):
    """The adapter comes from the census's own bundle, in either layout."""

    def test_the_shared_scripts_layout_resolves_the_adapter_beside_it(self):
        self.plant_the_acceptance_scenario()
        document = self.census_through(self.synthetic_bundle("claude"))
        collection = document["project_review_attempts"]
        self.assertEqual(
            collection["adapter"],
            str(Path(collection["adapter"]).parent / LIVENESS_ADAPTER),
        )
        self.assertEqual(Path(collection["adapter"]).parent.name, "scripts")
        self.assertEqual(
            {row["attempt"] for row in collection["attempts"] if row["cleanable"]},
            {ATTEMPTS["ended"], ATTEMPTS["killed"]},
        )

    def test_the_per_skill_layout_resolves_its_sibling_skill_s_adapter(self):
        self.plant_the_acceptance_scenario()
        document = self.census_through(self.synthetic_bundle("codex"))
        collection = document["project_review_attempts"]
        self.assertEqual(
            Path(collection["adapter"]).parent.parent.name, "project-review"
        )
        self.assertEqual(
            {row["attempt"] for row in collection["attempts"] if row["cleanable"]},
            {ATTEMPTS["ended"], ATTEMPTS["killed"]},
        )

    def test_a_bundle_with_no_adapter_reports_unresolved_rather_than_clean(self):
        # The spec addition: a missing helper is a visible error, never an
        # empty or safe result. Every attempt is reported and none is
        # cleanable, so the operator sees five directories and no green light.
        self.plant_the_acceptance_scenario()
        document = self.census_through(
            self.synthetic_bundle("claude", adapter="absent")
        )
        collection = document["project_review_attempts"]
        self.assertIsNone(collection["adapter"])
        self.assertEqual(len(collection["attempts"]), len(ATTEMPTS))
        for row in collection["attempts"]:
            with self.subTest(attempt=row["attempt"]):
                self.assertEqual(row["state"], "error")
                self.assertIsNone(row["over"])
                self.assertIs(row["cleanable"], False)
                self.assertIn("ships no project-review liveness adapter",
                              row["status_error"])
        self.assertTrue(
            any("liveness adapter unavailable" in warning
                for warning in document["warnings"]),
            document["warnings"],
        )
        self.assertEqual(
            document["counts"]["cleanable_project_review_attempts"], 0
        )

    def test_the_audited_checkout_is_never_where_the_adapter_comes_from(self):
        # A repository under audit need not track any Kanban tooling, and one
        # that happens to carry a file of that name is not this bundle's.
        self.plant_the_acceptance_scenario()
        decoy = self.repo / "scripts"
        decoy.mkdir()
        (decoy / LIVENESS_ADAPTER).write_text("raise SystemExit(9)\n", encoding="utf-8")
        document = self.census_through(self.synthetic_bundle("claude"))
        adapter = document["project_review_attempts"]["adapter"]
        self.assertNotIn(str(self.repo), adapter)


class AttemptStatusReadingTests(AttemptFixture):
    """A `status` answer this census cannot use is an error, not a pass."""

    def rows_with(self, mode: str) -> list[dict]:
        self.plant_the_acceptance_scenario()
        document = self.census_through(
            self.synthetic_bundle("claude", adapter=mode)
        )
        self.collection = document["project_review_attempts"]
        self.warnings = document["warnings"]
        return self.collection["attempts"]

    def test_an_unusable_answer_leaves_every_attempt_unresolved(self):
        for mode, expected in (
            ("not-json", "invalid status JSON"),
            ("not-an-object", "did not report a JSON object"),
            ("unknown-state", "unknown state"),
            ("unknown-standing", "unknown keeper standing"),
            ("no-launch-inventory", "unfinished_launches"),
            ("other-refusal", "attempt-invalid"),
            ("bare-failure", "exit 3"),
        ):
            with self.subTest(mode=mode):
                rows = self.rows_with(mode)
                self.assertEqual(len(rows), len(ATTEMPTS))
                for row in rows:
                    self.assertEqual(row["state"], "error", row)
                    self.assertIsNone(row["over"])
                    self.assertIs(row["cleanable"], False)
                    self.assertIn(expected, row["status_error"])
                self.assertTrue(
                    any("state unresolved" in warning for warning in self.warnings),
                    self.warnings,
                )

    def test_a_directory_whose_name_is_no_attempt_id_is_retained(self):
        # The adapter refuses a name that is not one of its tokens, and that
        # refusal is not `attempt-unknown`: it says nothing about whether
        # anything is running, so the directory is reported and kept.
        (self.runtime / "not-an-attempt-id").mkdir(parents=True)
        rows = self.attempts()
        row = rows["not-an-attempt-id"]
        self.assertEqual(row["state"], "error")
        self.assertEqual(row["refusal"], "attempt-invalid")
        self.assertIsNone(row["over"])
        self.assertIs(row["cleanable"], False)

    def test_an_adapter_that_cannot_be_run_loses_one_attempt_not_the_census(self):
        # `run` raises on a spawn failure and on its own timeout, and a wedged
        # adapter call must not take the rest of the document with it: the other
        # collections survive, the remaining attempts are still asked, and the
        # one that failed is a visible error rather than an absence.
        self.plant_the_acceptance_scenario()
        real_run = census.run
        wedged = ATTEMPTS["live"]
        spawns = []

        def wedge_one_attempt(argv, cwd, **kwargs):
            if len(argv) > 1 and argv[1].endswith(LIVENESS_ADAPTER):
                spawns.append(argv[-1])
                if argv[-1] == wedged:
                    raise census.CensusError("status: timed out after 90 seconds")
            return real_run(argv, cwd, **kwargs)

        with mock.patch.object(census, "run", wedge_one_attempt):
            rows = self.attempts()
        # Every attempt was asked, including the four after the one that failed.
        self.assertEqual(sorted(spawns), sorted(ATTEMPTS.values()))
        self.assertEqual(rows["live"]["state"], "error")
        self.assertIn("timed out", rows["live"]["status_error"])
        self.assertIsNone(rows["live"]["over"])
        self.assertIs(rows["live"]["cleanable"], False)
        # And the rest answered exactly as they do without the failure.
        self.assertEqual(
            {name for name, row in rows.items() if row["cleanable"]},
            {"ended", "killed"},
        )
        self.assertEqual(self.document["default_branch"], "master")
        self.assertTrue(
            any("state unresolved" in warning
                for warning in self.document["warnings"]),
            self.document["warnings"],
        )

    def test_an_unreadable_attempt_root_is_null_rather_than_empty(self):
        # The rule the retain ledger follows, on this collection: a directory
        # that exists and cannot be listed is not an empty one.
        self.runtime.mkdir(parents=True)
        self.attempt_directory(ATTEMPTS["ended"])
        self.runtime.chmod(0o000)
        self.addCleanup(self.runtime.chmod, 0o700)
        document = self.run_census()
        collection = document["project_review_attempts"]
        self.assertEqual(collection["present"], True)
        self.assertIsNone(collection["attempts"])
        self.assertIn("Permission denied", collection["error"])
        self.assertIsNone(document["counts"]["project_review_attempts"])
        self.assertIsNone(
            document["counts"]["cleanable_project_review_attempts"]
        )
        self.assertTrue(
            any("attempt directory unreadable" in warning
                for warning in document["warnings"]),
            document["warnings"],
        )


if __name__ == "__main__":
    unittest.main()
